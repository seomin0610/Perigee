#import "LL.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
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

static NSString *gCardTitle;

void LLArtReset(BOOL files) {
	gCardTitle = nil;
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
	UIImage *img = file ? LLFirstFrame(file) : nil;
	NSData *first = img ? UIImageJPEGRepresentation(img, 0.9) : nil;
	if (!first) return nil;
	return [[NSClassFromString(@"MPMediaItemAnimatedArtwork") alloc] initWithArtworkID:artId
		previewImageRequestHandler:^(CGSize size, void (^completion)(UIImage *)) { completion([UIImage imageWithData:first]); }
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

#pragma mark - Full-screen lyrics

static NSMutableDictionary<NSString *, id> *gCards;
static dispatch_queue_t gCardQueue;
static NSUInteger gCardGen;
static id gCardShown, gCardSquare;
static BOOL gSquareAsked;
static NSString *gTallKey, *gSquareKey;

static void LLKeys(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSArray *supported = [MPNowPlayingInfoCenter respondsToSelector:@selector(supportedAnimatedArtworkKeys)] ? [MPNowPlayingInfoCenter performSelector:@selector(supportedAnimatedArtworkKeys)] : @[];
		NSString *tall = LLArtKey("MPNowPlayingInfoProperty3x4AnimatedArtwork"), *square = LLArtKey("MPNowPlayingInfoProperty1x1AnimatedArtwork");
		gTallKey = tall && [supported containsObject:tall] ? tall : nil;
		gSquareKey = square && [supported containsObject:square] ? square : nil;
	});
}

NSString *LLTallKey(void) {
	LLKeys();
	return gTallKey;
}

// a fixed square artwork per track, or the Dynamic Island redoes its artwork flip on every new card
void LLCardInto(NSMutableDictionary *d, id card) {
	if (!card) return;
	d[gTallKey] = card;
	if (gSquareKey && !d[gSquareKey] && gCardSquare) d[gSquareKey] = gCardSquare;
}

static NSURL *LLCardDir(void) { return [LLCacheDir() URLByAppendingPathComponent:@"cards"]; }

static UIImage *LLBlurred(UIImage *cover) {
	if (!cover.CGImage) return nil;
	static CIContext *ctx;
	if (!ctx) ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @YES }];
	CIImage *img = [CIImage imageWithCGImage:cover.CGImage];
	CIImage *out = [[[[img imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:img.extent.size.width / 5]
		imageByApplyingFilter:@"CIColorControls" withInputParameters:@{ kCIInputSaturationKey: @1.4 }]
		imageByApplyingFilter:@"CIExposureAdjust" withInputParameters:@{ kCIInputEVKey: @-1.2 }];
	CGImageRef cg = [ctx createCGImage:out fromRect:img.extent];
	UIImage *u = cg ? [UIImage imageWithCGImage:cg] : nil;
	CGImageRelease(cg);
	return u;
}

static void LLDrawBackdrop(CGSize size, UIImage *backdrop) {
	[UIColor.blackColor setFill];
	UIRectFill((CGRect){ CGPointZero, size });
	if (!backdrop) return;
	CGFloat s = MAX(size.width / backdrop.size.width, size.height / backdrop.size.height);
	CGSize d = CGSizeMake(backdrop.size.width * s, backdrop.size.height * s);
	[backdrop drawInRect:CGRectMake((size.width - d.width) / 2, (size.height - d.height) / 2, d.width, d.height)];
}

static void LLDrawText(CGSize size, NSString *now, NSString *next, NSInteger dots) {
	if (!now && dots < 0) return;
	CGFloat margin = size.width * 0.08;
	CGSize box = CGSizeMake(size.width - 2 * margin, CGFLOAT_MAX);
	NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
	para.lineBreakMode = NSLineBreakByWordWrapping;
	para.lineBreakStrategy = NSLineBreakStrategyStandard;
	NSAttributedString *(^text)(NSString *, CGFloat, UIFontWeight, CGFloat) = ^(NSString *s, CGFloat pt, UIFontWeight weight, CGFloat alpha) {
		return [[NSAttributedString alloc] initWithString:s ?: @"" attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:pt weight:weight], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:alpha], NSKernAttributeName: @(-0.02 * pt), NSParagraphStyleAttributeName: para }];
	};
	NSAttributedString *big, *small;
	CGFloat font = size.width * 0.09, bh, sh, gap;
	for (;; font *= 0.9) {
		big = text(now, font, UIFontWeightBold, 1);
		small = text(next, font * 0.6, UIFontWeightSemibold, 0.45);
		bh = dots >= 0 ? round(font * 1.235) : now.length ? ceil([big boundingRectWithSize:box options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.height) : 0;
		sh = next.length ? ceil([small boundingRectWithSize:box options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.height) : 0;
		gap = bh && sh ? font * 0.5 : 0;
		if (bh + gap + sh <= size.height * 0.7 || font < size.width * 0.04) break;
	}
	// the lock screen fits the clip to its width, clock over the top and controls over the bottom
	CGFloat y = size.height * 0.55 - (bh + gap + sh) / 2;
	if (dots >= 0) {
		CGFloat d = round(font * 0.42), step = d + round(d * 0.6);
		for (NSInteger k = 0; k < 3; k++) {
			[[UIColor colorWithWhite:1 alpha:0.3 + 0.7 * MAX(0, MIN(1, dots / 2.0 - k))] setFill];
			[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(margin + k * step, y + (bh - d) / 2, d, d)] fill];
		}
	} else
		[big drawWithRect:CGRectMake(margin, y, box.width, bh) options:NSStringDrawingUsesLineFragmentOrigin context:nil];
	[small drawWithRect:CGRectMake(margin, y + bh + gap, box.width, sh) options:NSStringDrawingUsesLineFragmentOrigin context:nil];
}

static CGContextRef LLContext(void *data, size_t W, size_t H, size_t row, BOOL opaque) {
	CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
	CGContextRef ctx = CGBitmapContextCreate(data, W, H, 8, row, cs, (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst) | kCGBitmapByteOrder32Little);
	CGColorSpaceRelease(cs);
	CGContextTranslateCTM(ctx, 0, H);
	CGContextScaleCTM(ctx, 1, -1);
	CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
	return ctx;
}

static UIImage *LLBitmap(size_t W, size_t H, BOOL opaque, void (^draw)(CGSize size)) {
	CGContextRef ctx = LLContext(NULL, W, H, 0, opaque);
	UIGraphicsPushContext(ctx);
	draw(CGSizeMake(W, H));
	UIGraphicsPopContext();
	CGImageRef img = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);
	UIImage *u = [UIImage imageWithCGImage:img];
	CGImageRelease(img);
	return u;
}

static const NSInteger kMoveFrames = 90;
static const int32_t kMoveFPS = 15;

static float LLHash(int x, int y) {
	uint32_t h = (uint32_t)x * 374761393u + (uint32_t)y * 668265263u;
	h = (h ^ (h >> 13)) * 1274126177u;
	return (float)(h ^ (h >> 16)) / 2147483647.5f - 1;
}

static float LLNoise(float x, float y) {
	int ix = (int)floorf(x), iy = (int)floorf(y);
	float fx = x - ix, fy = y - iy;
	fx = fx * fx * (3 - 2 * fx);
	fy = fy * fy * (3 - 2 * fy);
	float a = LLHash(ix, iy), b = LLHash(ix + 1, iy), c = LLHash(ix, iy + 1), d = LLHash(ix + 1, iy + 1);
	return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy;
}

// one seamless loop of the blurred cover pushed around by slow noise; the noise is walked round a circle so the last frame meets the first
static NSArray<UIImage *> *LLMoving(UIImage *blurred) {
	const size_t W = 120, H = 160, S = 100;
	CGContextRef sc = LLContext(NULL, S, S, 0, YES);
	UIGraphicsPushContext(sc);
	[UIColor.blackColor setFill];
	UIRectFill(CGRectMake(0, 0, S, S));
	[blurred drawInRect:CGRectMake(0, 0, S, S)];
	UIGraphicsPopContext();
	const uint8_t *src = CGBitmapContextGetData(sc);
	size_t srow = CGBitmapContextGetBytesPerRow(sc);

	NSMutableArray<UIImage *> *frames = [NSMutableArray array];
	for (NSInteger f = 0; f < kMoveFrames; f++) {
		float p = 2 * M_PI * f / kMoveFrames, cx = 0.45f * cosf(p), cy = 0.45f * sinf(p);
		CGContextRef ctx = LLContext(NULL, W, H, 0, YES);
		uint8_t *out = CGBitmapContextGetData(ctx);
		size_t orow = CGBitmapContextGetBytesPerRow(ctx);
		for (size_t y = 0; y < H; y++)
			for (size_t x = 0; x < W; x++) {
				float u = (x + 0.5f) / W, v = (y + 0.5f) / H, nu = u * 1.3f, nv = v * 1.7f;
				float dx = LLNoise(nu + cx, nv + cy) + 0.5f * LLNoise(2 * nu - cy + 7.3f, 2 * nv + cx + 1.7f);
				float dy = LLNoise(nu + cy + 31.7f, nv - cx + 11.1f) + 0.5f * LLNoise(2 * nu + cx + 3.1f, 2 * nv - cy + 23.9f);
				float sx = fminf(fmaxf(0.5f + (u - 0.5f + dx * 0.2f) * 0.75f, 0), 1) * (S - 1);
				float sy = fminf(fmaxf(v + dy * 0.2f, 0), 1) * (S - 1);
				size_t x0 = (size_t)sx, y0 = (size_t)sy, x1 = MIN(x0 + 1, S - 1), y1 = MIN(y0 + 1, S - 1);
				float tx = sx - x0, ty = sy - y0;
				uint8_t *o = out + y * orow + x * 4;
				for (int k = 0; k < 3; k++) {
					float top = src[y0 * srow + x0 * 4 + k] * (1 - tx) + src[y0 * srow + x1 * 4 + k] * tx;
					float bottom = src[y1 * srow + x0 * 4 + k] * (1 - tx) + src[y1 * srow + x1 * 4 + k] * tx;
					o[k] = (uint8_t)(top * (1 - ty) + bottom * ty + 0.5f);
				}
				o[3] = 255;
			}
		CGImageRef img = CGBitmapContextCreateImage(ctx);
		CGContextRelease(ctx);
		[frames addObject:[UIImage imageWithCGImage:img]];
		CGImageRelease(img);
	}
	CGContextRelease(sc);
	return frames;
}

static NSURL *LLClip(size_t W, size_t H, NSInteger n, int32_t fps, void (^draw)(CGSize size, NSInteger f)) {
	NSFileManager *fm = NSFileManager.defaultManager;
	[fm createDirectoryAtURL:LLCardDir() withIntermediateDirectories:YES attributes:nil error:nil];
	NSURL *dst = [LLCardDir() URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".mp4"]];
	NSURL *tmp = [dst URLByAppendingPathExtension:@"part.mp4"];
	AVAssetWriter *w = [AVAssetWriter assetWriterWithURL:tmp fileType:AVFileTypeMPEG4 error:nil];
	AVAssetWriterInput *in = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{ AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(W), AVVideoHeightKey: @(H) }];
	NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferWidthKey: @(W), (id)kCVPixelBufferHeightKey: @(H), (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES };
	AVAssetWriterInputPixelBufferAdaptor *ad = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:in sourcePixelBufferAttributes:attrs];
	BOOL ok = [w canAddInput:in];
	if (ok) {
		[w addInput:in];
		ok = [w startWriting];
	}
	if (ok) {
		[w startSessionAtSourceTime:kCMTimeZero];
		NSInteger frames = MAX(n, 2);
		CVPixelBufferRef pb = NULL;
		for (NSInteger f = 0; ok && f < frames; f++) {
			if (f < n) {
				CVPixelBufferRelease(pb);
				pb = NULL;
				ok = ad.pixelBufferPool && CVPixelBufferPoolCreatePixelBuffer(NULL, ad.pixelBufferPool, &pb) == kCVReturnSuccess;
				if (!ok) break;
				CVPixelBufferLockBaseAddress(pb, 0);
				CGContextRef ctx = LLContext(CVPixelBufferGetBaseAddress(pb), W, H, CVPixelBufferGetBytesPerRow(pb), YES);
				UIGraphicsPushContext(ctx);
				draw(CGSizeMake(W, H), f);
				UIGraphicsPopContext();
				CGContextRelease(ctx);
				CVPixelBufferUnlockBaseAddress(pb, 0);
			}
			while (!in.readyForMoreMediaData && w.status == AVAssetWriterStatusWriting) usleep(2000);
			ok = [ad appendPixelBuffer:pb withPresentationTime:CMTimeMake(f, fps)];
		}
		CVPixelBufferRelease(pb);
		if (w.status == AVAssetWriterStatusWriting) {
			[in markAsFinished];
			[w endSessionAtSourceTime:CMTimeMake(frames, fps)];
			dispatch_semaphore_t sem = dispatch_semaphore_create(0);
			[w finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
			dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
		}
		ok = ok && w.status == AVAssetWriterStatusCompleted && [fm moveItemAtURL:tmp toURL:dst error:nil];
	}
	if (!ok) {
		LLLog(@"lyrics card failed: %@", w.error);
		[fm removeItemAtURL:tmp error:nil];
	}
	return ok ? dst : nil;
}

static void LLRender(NSUInteger gen, NSURL *(^make)(void), void (^done)(id art)) {
	dispatch_async(gCardQueue, ^{
		NSURL *file = make();
		id art = LLAnimated([@"card-" stringByAppendingString:file.lastPathComponent ?: @""], file);
		dispatch_async(dispatch_get_main_queue(), ^{
			if (gen == gCardGen) done(art);
		});
	});
}

id LLCard(NSDictionary *info, NSString *now, NSString *next, NSInteger dots, double at, BOOL shown) {
	NSString *title = info[MPMediaItemPropertyTitle];
	MPMediaItemArtwork *artwork = LLAs(info[MPMediaItemPropertyArtwork], MPMediaItemArtwork.class);
	if (!gCards) {
		gCards = [NSMutableDictionary dictionary];
		gCardQueue = dispatch_queue_create("TidalLockLyrics.card", DISPATCH_QUEUE_SERIAL);
	}
	if (![title isEqualToString:gCardTitle]) {
		gCardTitle = title;
		gCardShown = gCardSquare = nil;
		gSquareAsked = NO;
		[gCards removeAllObjects];
		gCardGen++;
		dispatch_async(gCardQueue, ^{ [NSFileManager.defaultManager removeItemAtURL:LLCardDir() error:nil]; });
	}
	NSUInteger gen = gCardGen;
	if (!gSquareAsked && gSquareKey) {
		UIImage *cover = [artwork imageWithSize:CGSizeMake(600, 600)];
		if (cover) {
			gSquareAsked = YES;
			LLRender(gen, ^NSURL * {
				return LLClip(600, 600, 1, 1, ^(CGSize s, NSInteger f) { [cover drawInRect:(CGRect){ CGPointZero, s }]; });
			}, ^(id art) {
				gCardSquare = art;
				if (art) LLSend(YES);
			});
		}
	}
	NSString *key = [NSString stringWithFormat:@"%ld\n%@\n%@", (long)dots, now ?: @"\x01", next];
	id card = gCards[key];
	if (!card) {
		gCards[key] = NSNull.null;
		BOOL plain = !now && dots < 0, moving = !plain && LLOn(@"moving");
		UIImage *cover = [artwork imageWithSize:plain ? CGSizeMake(1280, 1280) : CGSizeMake(200, 200)];
		LLRender(gen, ^NSURL * {
			static NSUInteger blurGen;
			static UIImage *blurred;
			static NSArray<UIImage *> *frames;
			if (!plain && (blurGen != gen || (!blurred && cover))) {
				blurGen = gen;
				blurred = LLBlurred(cover);
				frames = nil;
			}
			if (!moving) return LLClip(960, 1280, 1, 1, ^(CGSize s, NSInteger f) {
				LLDrawBackdrop(s, plain ? cover : blurred);
				LLDrawText(s, now, next, dots);
			});
			if (!frames) frames = LLMoving(blurred);
			NSArray<UIImage *> *loop = frames;
			UIImage *overlay = LLBitmap(960, 1280, NO, ^(CGSize s) { LLDrawText(s, now, next, dots); });
			NSInteger phase = (NSInteger)(fmod(at, (double)kMoveFrames / kMoveFPS) * kMoveFPS) % kMoveFrames;
			return LLClip(960, 1280, kMoveFrames, kMoveFPS, ^(CGSize s, NSInteger f) {
				[loop[(f + phase) % kMoveFrames] drawInRect:(CGRect){ CGPointZero, s }];
				[overlay drawInRect:(CGRect){ CGPointZero, s }];
			});
		}, ^(id art) {
			gCards[key] = art ?: NSNull.null;
			if (art) LLSend(NO);
		});
	}
	if (card == NSNull.null) card = nil;
	if (shown && card) gCardShown = card;
	return shown ? gCardShown : card;
}
