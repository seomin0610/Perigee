#import "LL.h"
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

@interface NSObject (LLAnimatedArtwork)
- (instancetype)initWithArtworkID:(NSString *)artworkID
       previewImageRequestHandler:(void (^)(CGSize size, void (^completion)(UIImage *image)))preview
  videoAssetFileURLRequestHandler:(void (^)(CGSize size, void (^completion)(NSURL *url)))video;
@end

static NSMutableDictionary<NSString *, id> *gArt;
static NSMutableDictionary<NSString *, NSDate *> *gSeen;
static dispatch_queue_t gQueue;

BOOL LLArtAvailable(void) { return NSClassFromString(@"MPMediaItemAnimatedArtwork") != nil; }

static NSString *LLArtKey(const char *name) {
	NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, name);
	return p ? *p : nil;
}

static NSURL *LLCacheDir(void) {
	NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"TidalLockLyrics"];
	[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return dir;
}

unsigned long long LLArtCacheBytes(void) {
	unsigned long long n = 0;
	for (NSURL *u in [NSFileManager.defaultManager contentsOfDirectoryAtURL:LLCacheDir() includingPropertiesForKeys:@[ NSURLFileSizeKey ] options:0 error:nil]) {
		NSNumber *size;
		[u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
		n += size.unsignedLongLongValue;
	}
	return n;
}

void LLArtReset(BOOL files) {
	[gArt removeAllObjects];
	[gSeen removeAllObjects];
	if (files) dispatch_async(gQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [NSFileManager.defaultManager removeItemAtURL:LLCacheDir() error:nil]; });
}

#pragma mark - Blocking helpers (gQueue only)

static NSData *LLGet(NSURLRequest *req) {
	__block NSData *out;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
		NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
		if (status == 200 || status == 206) out = data;
		else LLLog(@"GET %@: %@", req.URL.host, err.localizedDescription ?: @(status));
		dispatch_semaphore_signal(sem);
	}] resume];
	dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
	return out;
}

static NSString *LLGetText(NSURL *url, NSDictionary *headers) {
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
	req.allHTTPHeaderFields = headers;
	NSData *d = LLGet(req);
	return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

static NSString *LLFirstMatch(NSString *s, NSString *pattern, NSUInteger group) {
	if (!s) return nil;
	NSTextCheckingResult *m = [[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil] firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
	return m ? [s substringWithRange:[m rangeAtIndex:group]] : nil;
}

static NSURL *LLCrop34(NSURL *src, NSURL *dst) {
	if ([dst checkResourceIsReachableAndReturnError:nil]) return dst;
	AVURLAsset *asset = [AVURLAsset assetWithURL:src];
	AVAssetTrack *v = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
	if (!v) return nil;
	CGSize n = v.naturalSize;
	CGFloat w = round(n.height * 3 / 4 / 2) * 2;
	AVMutableVideoComposition *vc = [AVMutableVideoComposition videoComposition];
	vc.renderSize = CGSizeMake(w, n.height);
	vc.frameDuration = CMTimeMake(1, 30);
	AVMutableVideoCompositionInstruction *ins = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
	ins.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
	AVMutableVideoCompositionLayerInstruction *li = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:v];
	[li setTransform:CGAffineTransformMakeTranslation(-(n.width - w) / 2, 0) atTime:kCMTimeZero];
	ins.layerInstructions = @[ li ];
	vc.instructions = @[ ins ];
	AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
	NSURL *tmp = [dst URLByAppendingPathExtension:@"part.mp4"];
	[NSFileManager.defaultManager removeItemAtURL:tmp error:nil];
	ex.videoComposition = vc;
	ex.outputURL = tmp;
	ex.outputFileType = AVFileTypeMPEG4;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[ex exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
	dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
	BOOL ok = ex.status == AVAssetExportSessionStatusCompleted && [NSFileManager.defaultManager moveItemAtURL:tmp toURL:dst error:nil];
	if (!ok) LLLog(@"3:4 crop failed: %@", ex.error);
	return ok ? dst : nil;
}

#pragma mark - TIDAL

static NSURL *LLTidalCover(NSURLRequest *trackReq) {
	NSData *data = LLGet(trackReq);
	NSDictionary *json = data ? LLAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class) : nil;
	NSString *uuid = LLAs(LLAs(json[@"album"], NSDictionary.class)[@"videoCover"], NSString.class);
	LLLog(@"TIDAL video cover for %@: %@", trackReq.URL.lastPathComponent, uuid ?: @"none");
	if (!uuid.length) return nil;
	NSURL *file = [LLCacheDir() URLByAppendingPathComponent:[NSString stringWithFormat:@"tidal-%@.mp4", uuid]];
	if ([file checkResourceIsReachableAndReturnError:nil]) return file;
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://resources.tidal.com/videos/%@/1280x1280.mp4", [uuid stringByReplacingOccurrencesOfString:@"-" withString:@"/"]]];
	NSData *mp4 = LLGet([NSURLRequest requestWithURL:url]);
	return mp4 && [mp4 writeToURL:file atomically:YES] ? file : nil;
}

#pragma mark - Apple Music

static NSString *gToken;
static NSDate *gTokenExp;

static NSString *LLAppleToken(void) {
	if (gToken && gTokenExp.timeIntervalSinceNow > 300) return gToken;
	NSDictionary *ua = @{ @"User-Agent": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15" };
	NSString *html = LLGetText([NSURL URLWithString:@"https://music.apple.com/us/browse"], ua);
	NSArray *scripts = html ? [[NSRegularExpression regularExpressionWithPattern:@"/assets/index[^\"'\\s]*\\.js" options:0 error:nil] matchesInString:html options:0 range:NSMakeRange(0, html.length)] : @[];
	for (NSTextCheckingResult *m in scripts) {
		NSString *js = LLGetText([NSURL URLWithString:[@"https://music.apple.com" stringByAppendingString:[html substringWithRange:m.range]]], ua);
		NSString *jwt = LLFirstMatch(js, @"eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", 0);
		if (!jwt) continue;
		NSString *payload = [[[jwt componentsSeparatedByString:@"."][1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
		while (payload.length % 4) payload = [payload stringByAppendingString:@"="];
		NSData *pd = [[NSData alloc] initWithBase64EncodedString:payload options:0];
		NSDictionary *claims = pd ? LLAs([NSJSONSerialization JSONObjectWithData:pd options:0 error:nil], NSDictionary.class) : nil;
		gToken = jwt;
		gTokenExp = [claims[@"exp"] respondsToSelector:@selector(doubleValue)] ? [NSDate dateWithTimeIntervalSince1970:[claims[@"exp"] doubleValue]] : [NSDate dateWithTimeIntervalSinceNow:3600];
		return jwt;
	}
	LLLog(@"Apple Music token not found (%lu scripts)", (unsigned long)scripts.count);
	return nil;
}

static NSString *LLNorm(NSString *s) {
	s = [s.lowercaseString stringByReplacingOccurrencesOfString:@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
	s = [s stringByReplacingOccurrencesOfString:@" - (single|ep)$" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, s.length)];
	NSMutableString *out = [NSMutableString string];
	[s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *c, NSRange r, NSRange er, BOOL *stop) {
		if ([c rangeOfCharacterFromSet:NSCharacterSet.alphanumericCharacterSet].location != NSNotFound) [out appendString:c];
	}];
	return out;
}

static BOOL LLSame(NSString *a, NSString *b) {
	a = LLNorm(a);
	b = LLNorm(b);
	return a.length && b.length && ([a hasPrefix:b] || [b hasPrefix:a]);
}

static NSURL *LLFetchHLS(NSString *master, NSURL *dst) {
	if ([dst checkResourceIsReachableAndReturnError:nil]) return dst;
	NSURL *base = [NSURL URLWithString:master];
	NSString *text = LLGetText(base, nil);
	NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
	NSURL *variant = nil;
	NSInteger best = NSIntegerMax;
	for (NSUInteger i = 0; i < lines.count; i++) {
		if (![lines[i] hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;
		NSInteger w = [LLFirstMatch(lines[i], @"RESOLUTION=(\\d+)x", 1) integerValue];
		NSUInteger j = i + 1;
		while (j < lines.count && (!lines[j].length || [lines[j] hasPrefix:@"#"])) j++;
		if (j < lines.count && labs(w - 1100) < best) {
			best = labs(w - 1100);
			variant = [NSURL URLWithString:lines[j] relativeToURL:base].absoluteURL;
		}
	}
	if (variant) {
		base = variant;
		lines = [LLGetText(variant, nil) componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
	}
	NSMutableOrderedSet<NSURL *> *parts = [NSMutableOrderedSet orderedSet];
	for (NSString *l in lines) {
		NSString *uri = [l hasPrefix:@"#EXT-X-MAP:"] ? LLFirstMatch(l, @"URI=\"([^\"]+)\"", 1) : l.length && ![l hasPrefix:@"#"] ? l : nil;
		if (uri) [parts addObject:[NSURL URLWithString:uri relativeToURL:base].absoluteURL];
	}
	if (!parts.count) return nil;
	NSMutableData *all = [NSMutableData data];
	for (NSURL *u in parts) {
		NSData *d = LLGet([NSURLRequest requestWithURL:u]);
		if (!d) return nil;
		[all appendData:d];
	}
	return [all writeToURL:dst atomically:YES] ? dst : nil;
}

static NSString *LLVideoURL(NSDictionary *ev, NSArray<NSString *> *keys) {
	for (NSString *k in keys) {
		NSString *v = LLAs(LLAs(ev[k], NSDictionary.class)[@"video"], NSString.class);
		if (v.length) return v;
	}
	return nil;
}

static NSString *LLAppleCover(NSString *album, NSString *artist, NSURL **square, NSURL **tall) {
	NSString *token = LLAppleToken();
	if (!token) return nil;
	NSString *firstArtist = [artist componentsSeparatedByString:@", "].firstObject;
	NSURLComponents *c = [NSURLComponents componentsWithString:@"https://amp-api.music.apple.com/v1/catalog/us/search"];
	c.queryItems = @[
		[NSURLQueryItem queryItemWithName:@"term" value:[NSString stringWithFormat:@"%@ %@", album, firstArtist]],
		[NSURLQueryItem queryItemWithName:@"types" value:@"albums"],
		[NSURLQueryItem queryItemWithName:@"limit" value:@"10"],
		[NSURLQueryItem queryItemWithName:@"extend" value:@"editorialVideo"],
	];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
	[req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
	[req setValue:@"https://music.apple.com" forHTTPHeaderField:@"Origin"];
	NSData *data = LLGet(req);
	if (!data) gToken = nil;
	NSDictionary *json = data ? LLAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class) : nil;
	NSArray *albums = LLAs(LLAs(LLAs(json[@"results"], NSDictionary.class)[@"albums"], NSDictionary.class)[@"data"], NSArray.class);
	for (NSDictionary *a in albums) {
		NSDictionary *attrs = LLAs(LLAs(a, NSDictionary.class)[@"attributes"], NSDictionary.class);
		NSDictionary *ev = LLAs(attrs[@"editorialVideo"], NSDictionary.class);
		if (!ev || !LLSame(attrs[@"name"], album) || !LLSame(attrs[@"artistName"], firstArtist)) continue;
		NSString *aid = LLAs(a[@"id"], NSString.class) ?: @"x";
		NSString *sq = LLVideoURL(ev, @[ @"motionSquareVideo1x1", @"motionDetailSquare" ]);
		NSString *tl = LLVideoURL(ev, @[ @"motionTallVideo3x4", @"motionDetailTall" ]);
		if (sq) *square = LLFetchHLS(sq, [LLCacheDir() URLByAppendingPathComponent:[NSString stringWithFormat:@"am-%@-1x1.mp4", aid]]);
		if (tl) *tall = LLFetchHLS(tl, [LLCacheDir() URLByAppendingPathComponent:[NSString stringWithFormat:@"am-%@-3x4.mp4", aid]]);
		LLLog(@"Apple Music motion cover for %@: %@ (square %@, tall %@)", album, attrs[@"name"], *square ? @"ok" : @"-", *tall ? @"ok" : @"-");
		if (*square || *tall) return [@"am-" stringByAppendingString:aid];
	}
	LLLog(@"Apple Music: no motion cover for %@ — %@ (%lu albums)", album, firstArtist, (unsigned long)albums.count);
	return nil;
}

#pragma mark - Artwork

static UIImage *LLFirstFrame(NSURL *url) {
	AVAssetImageGenerator *g = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset assetWithURL:url]];
	g.appliesPreferredTrackTransform = YES;
	CGImageRef img = [g copyCGImageAtTime:kCMTimeZero actualTime:NULL error:nil];
	UIImage *out = img ? [UIImage imageWithCGImage:img] : nil;
	if (img) CGImageRelease(img);
	return out;
}

static id LLAnimated(NSString *artId, NSURL *file) {
	UIImage *preview = file ? LLFirstFrame(file) : nil;
	if (!preview) return nil;
	return [[NSClassFromString(@"MPMediaItemAnimatedArtwork") alloc] initWithArtworkID:artId
		previewImageRequestHandler:^(CGSize size, void (^completion)(UIImage *)) { completion(preview); }
		videoAssetFileURLRequestHandler:^(CGSize size, void (^completion)(NSURL *)) { completion(file); }];
}

static void LLResolve(NSString *title, NSURLRequest *tidalTrack, NSString *album, NSString *artist) {
	NSString *artId = nil;
	NSURL *square = nil, *tall = nil;
	if (tidalTrack && LLOn(@"artTidal")) {
		square = LLTidalCover(tidalTrack);
		artId = square ? square.lastPathComponent : nil;
	}
	if (!square && album.length && LLOn(@"artApple")) artId = LLAppleCover(album, artist, &square, &tall);

	NSMutableDictionary *art = [NSMutableDictionary dictionary];
	if (artId) {
		NSArray *supported = [MPNowPlayingInfoCenter respondsToSelector:@selector(supportedAnimatedArtworkKeys)] ? [MPNowPlayingInfoCenter performSelector:@selector(supportedAnimatedArtworkKeys)] : @[];
		NSString *k11 = LLArtKey("MPNowPlayingInfoProperty1x1AnimatedArtwork"), *k34 = LLArtKey("MPNowPlayingInfoProperty3x4AnimatedArtwork");
		if (k34 && [supported containsObject:k34] && !tall && square)
			tall = LLCrop34(square, [LLCacheDir() URLByAppendingPathComponent:[artId stringByAppendingString:@"-crop34.mp4"]]);
		if (k11 && [supported containsObject:k11]) art[k11] = LLAnimated(artId, square);
		if (k34 && [supported containsObject:k34]) art[k34] = LLAnimated([artId stringByAppendingString:@"-3x4"], tall);
		LLLog(@"artwork for %@: %@ (keys offered: %@)", title, art.count ? [art.allKeys componentsJoinedByString:@", "] : @"none", supported);
	}
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!gArt[title]) return;
		gArt[title] = art.count ? art : NSNull.null;
		if (art.count) LLSend(YES);
	});
}

NSDictionary *LLArtFor(NSDictionary *info) {
	NSString *title = info[MPMediaItemPropertyTitle];
	if (!title.length || !LLOn(@"art") || !LLArtAvailable()) return nil;
	if (!gArt) {
		gArt = [NSMutableDictionary dictionary];
		gSeen = [NSMutableDictionary dictionary];
		gQueue = dispatch_queue_create("TidalLockLyrics.art", DISPATCH_QUEUE_SERIAL);
	}
	id have = gArt[title];
	if (have) return have == NSNull.null ? nil : have;

	NSString *tid = nil;
	for (NSString *i in gTidalTitles)
		if ([gTidalTitles[i] containsObject:title]) { tid = i; break; }
	if (!gSeen[title]) gSeen[title] = NSDate.date;
	if (LLOn(@"artTidal") && (!tid || !gTidalReq) && -gSeen[title].timeIntervalSinceNow < 4) return nil;

	NSMutableURLRequest *track = nil;
	if (tid && gTidalReq) {
		track = LLTidalRequest(@"", @[]);
		NSURLComponents *c = [NSURLComponents componentsWithURL:track.URL resolvingAgainstBaseURL:NO];
		c.host = @"api.tidal.com";
		c.path = [@"/v1/tracks/" stringByAppendingString:tid];
		track.URL = c.URL;
		track.allHTTPHeaderFields = @{ @"Authorization": [gTidalReq valueForHTTPHeaderField:@"Authorization"] ?: @"" };
	}
	gArt[title] = NSNull.null;
	NSString *album = info[MPMediaItemPropertyAlbumTitle], *artist = info[MPMediaItemPropertyArtist];
	dispatch_async(gQueue, ^{ LLResolve(title, track, album, artist); });
	return nil;
}
