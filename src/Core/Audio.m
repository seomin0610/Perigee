#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "TTAudio.h"

void TTV1Token(void (^done)(NSString *token));

enum { kMaxStages = 4, kMaxChannels = 8 };
static NSString *const kHandled = @"TTAudioHandled";
static TTAudioStage gStages[kMaxStages];
static unsigned gCount;
// not NSCache: it empties when the screen turns off
static NSMutableDictionary<NSString *, NSDictionary *> *gV1;
static char kURIKey, kTrackKey;

static void TTALog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void TTALog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalCore] audio: %{public}@", line);
}

static id TTAAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static BOOL TTAWantsV1(void) {
	for (unsigned i = 0; i < gCount; i++)
		if (gStages[i].wantsV1 && gStages[i].wantsV1()) return YES;
	return NO;
}

static NSData *TTARewrite(NSData *body, BOOL v1) {
	for (unsigned i = 0; i < gCount; i++) {
		NSData *r = gStages[i].manifest ? gStages[i].manifest(body, v1) : nil;
		if (r) body = r;
	}
	return body;
}

static NSURLSession *TTASession(void) {
	static NSURLSession *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; });
	return s;
}

static BOOL TTAManifest(NSURLRequest *r) {
	NSURL *u = r.URL;
	return [r.HTTPMethod isEqualToString:@"GET"] && [u.host hasSuffix:@"tidal.com"] && [u.path.stringByDeletingLastPathComponent hasSuffix:@"/trackManifests"];
}

static NSString *TTAPlaybackTrack(NSURLRequest *r) {
	NSString *track = r.URL.lastPathComponent;
	return TTAManifest(r) && [r.URL.query containsString:@"usage=PLAYBACK"] && track.length &&
	               [track rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound
	           ? track
	           : nil;
}

// hi-res asks for LOSSLESS: the whole file is downloaded before it plays
static NSString *TTAQuality(NSURL *u) {
	NSMutableArray *formats = [NSMutableArray array];
	for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems)
		if ([q.name hasPrefix:@"formats"] && q.value) [formats addObjectsFromArray:[q.value componentsSeparatedByString:@","]];
	for (NSArray *p in @[ @[ @"FLAC_HIRES", @"LOSSLESS" ], @[ @"FLAC", @"LOSSLESS" ], @[ @"AACLC", @"HIGH" ] ])
		if ([formats containsObject:p[0]]) return p[1];
	return @"LOW";
}

#pragma mark - v1 stream

@interface TTAMPD : NSObject <NSXMLParserDelegate>
@property (nonatomic) NSDictionary<NSString *, NSString *> *tmpl;
@property (nonatomic) NSUInteger count;
@end

@implementation TTAMPD
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary<NSString *, NSString *> *)a {
	if ([e isEqualToString:@"SegmentTemplate"]) _tmpl = a;
	else if ([e isEqualToString:@"S"] && _tmpl) _count += 1 + MAX(0, a[@"r"].integerValue);
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
	if ([e isEqualToString:@"SegmentTemplate"]) [p abortParsing];
}
@end

static NSArray<NSURL *> *TTAParts(NSData *mpd) {
	TTAMPD *m = [TTAMPD new];
	NSXMLParser *p = [[NSXMLParser alloc] initWithData:mpd];
	p.delegate = m;
	[p parse];
	NSString *init = m.tmpl[@"initialization"], *media = m.tmpl[@"media"];
	NSURL *first = init ? [NSURL URLWithString:init] : nil;
	if (!first || !media || !m.count) return nil;
	NSMutableArray<NSURL *> *parts = [NSMutableArray arrayWithObject:first];
	NSInteger n = m.tmpl[@"startNumber"] ? m.tmpl[@"startNumber"].integerValue : 1;
	for (NSUInteger i = 0; i < m.count; i++) {
		NSURL *u = [NSURL URLWithString:[media stringByReplacingOccurrencesOfString:@"$Number$" withString:@(n + i).stringValue]];
		if (!u) return nil;
		[parts addObject:u];
	}
	return parts;
}

static NSArray<NSURL *> *TTABTS(NSData *raw) {
	NSDictionary *m = TTAAs([NSJSONSerialization JSONObjectWithData:raw options:0 error:nil], NSDictionary.class);
	NSString *enc = TTAAs(m[@"encryptionType"], NSString.class), *file = TTAAs([TTAAs(m[@"urls"], NSArray.class) firstObject], NSString.class);
	NSURL *u = file && (!enc || [enc isEqualToString:@"NONE"]) ? [NSURL URLWithString:file] : nil;
	return u ? @[ u ] : nil;
}

static NSURL *TTAFolder(void) {
	NSURL *u = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"TidalCore/v1" isDirectory:YES];
	[NSFileManager.defaultManager createDirectoryAtURL:u withIntermediateDirectories:YES attributes:nil error:nil];
	return u;
}

static void TTAPrune(NSURL *dir, NSUInteger keep) {
	NSDate * (^date)(NSURL *) = ^NSDate *(NSURL *u) {
		NSDate *d;
		[u getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil];
		return d ?: NSDate.distantPast;
	};
	NSArray<NSURL *> *files = [[NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:@[ NSURLContentModificationDateKey ] options:0 error:nil]
	    sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [date(b) compare:date(a)]; }];
	for (NSUInteger i = keep; i < files.count; i++) [NSFileManager.defaultManager removeItemAtURL:files[i] error:nil];
}

static NSDictionary *TTAGain(id gain, id peak) {
	return TTAAs(gain, NSNumber.class) && TTAAs(peak, NSNumber.class) ? @{ @"replayGain": gain, @"peakAmplitude": peak } : nil;
}

static NSData *TTAV1Manifest(NSString *track, NSDictionary *info, NSString *uri) {
	NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
	attrs[@"uri"] = uri;
	NSString *format = @{ @"HI_RES_LOSSLESS": @"FLAC_HIRES", @"LOSSLESS": @"FLAC", @"HIGH": @"AACLC", @"LOW": @"HEAACV1" }[TTAAs(info[@"audioQuality"], NSString.class) ?: @""];
	if (format) attrs[@"formats"] = @[ format ];
	NSMutableDictionary *meta = [NSMutableDictionary dictionary];
	meta[@"format"] = format;
	meta[@"sampleRate"] = TTAAs(info[@"sampleRate"], NSNumber.class);
	meta[@"bitDepth"] = TTAAs(info[@"bitDepth"], NSNumber.class);
	@synchronized (gV1) {
		gV1[uri] = meta;
	}
	attrs[@"trackPresentation"] = TTAAs(info[@"assetPresentation"], NSString.class);
	attrs[@"hash"] = TTAAs(info[@"manifestHash"], NSString.class);
	attrs[@"trackAudioNormalizationData"] = TTAGain(info[@"trackReplayGain"], info[@"trackPeakAmplitude"]);
	attrs[@"albumAudioNormalizationData"] = TTAGain(info[@"albumReplayGain"], info[@"albumPeakAmplitude"]);
	return [NSJSONSerialization dataWithJSONObject:@{ @"data": @{ @"id": track, @"type": @"trackManifests", @"attributes": attrs },
	                                                  @"links": @{ @"self": [@"/trackManifests/" stringByAppendingString:track] } }
	                                       options:0
	                                         error:nil];
}

#pragma mark - Interception

@interface TTAProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@end

@implementation TTAProtocol {
	NSMutableArray<NSURLSessionTask *> *_tasks;
	id _runLoop;
	NSArray *_modes;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return ![NSURLProtocol propertyForKey:kHandled inRequest:r] && TTAManifest(r); }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }

- (void)startLoading {
	_tasks = [NSMutableArray array];
	_runLoop = (__bridge id)CFRunLoopGetCurrent();
	NSString *mode = CFBridgingRelease(CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()));
	_modes = mode ? @[ mode, NSRunLoopCommonModes ] : @[ NSRunLoopCommonModes ];

	NSMutableURLRequest *req = [self.request mutableCopy];
	[NSURLProtocol setProperty:@YES forKey:kHandled inRequest:req];
	NSString *track = TTAPlaybackTrack(req);
	if (track && TTAWantsV1()) return [self v1:track original:req];
	[self send:req];
}

- (void)run:(NSURLSessionTask *)task {
	@synchronized (self) {
		[_tasks addObject:task];
	}
	[task resume];
}

- (void)send:(NSURLRequest *)req {
	if (self.stopped) return;
	[self run:[TTASession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		BOOL ok = TTAAs(r, NSHTTPURLResponse.class) && ((NSHTTPURLResponse *)r).statusCode == 200;
		[self reply:ok ? TTARewrite(d, NO) : d response:r error:e];
	}]];
}

// ponytail: the whole song is downloaded before it plays, since taps never run on HLS; a progressive resource loader if the wait hurts
- (void)download:(NSArray<NSURL *> *)parts to:(NSURL *)dest done:(void (^)(NSURL *file))done {
	NSFileManager *fm = NSFileManager.defaultManager;
	if ([fm fileExistsAtPath:dest.path]) {
		[fm setAttributes:@{ NSFileModificationDate: NSDate.date } ofItemAtPath:dest.path error:nil];
		return done(dest);
	}
	NSMutableArray *chunks = [NSMutableArray array];
	for (NSUInteger i = 0; i < parts.count; i++) [chunks addObject:NSNull.null];
	CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
	dispatch_group_t g = dispatch_group_create();
	for (NSUInteger i = 0; i < parts.count; i++) {
		dispatch_group_enter(g);
		[self run:[TTASession() dataTaskWithURL:parts[i] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
			if (d && TTAAs(r, NSHTTPURLResponse.class) && ((NSHTTPURLResponse *)r).statusCode == 200) @synchronized (chunks) { chunks[i] = d; }
			dispatch_group_leave(g);
		}]];
	}
	dispatch_group_notify(g, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSMutableData *all = [NSMutableData data];
		for (id c in chunks) {
			if (c == NSNull.null) return done(nil);
			[all appendData:c];
		}
		if (![all writeToURL:dest atomically:YES]) return done(nil);
		TTALog(@"v1 %@: %lu parts, %.1f MB in %.1f s", dest.lastPathComponent, (unsigned long)parts.count, all.length / 1e6, CFAbsoluteTimeGetCurrent() - start);
		TTAPrune(dest.URLByDeletingLastPathComponent, 6);
		done(dest);
	});
}

- (void)v1:(NSString *)track original:(NSURLRequest *)orig {
	TTV1Token(^(NSString *t) {
		if (!t) {
			TTALog(@"%@: no Secondary Login, playing TIDAL's stream", track);
			return [self send:orig];
		}
		NSString *url = [NSString stringWithFormat:@"https://api.tidal.com/v1/tracks/%@/playbackinfo?audioquality=%@&playbackmode=STREAM&assetpresentation=FULL", track,
		                                           TTAQuality(orig.URL)];
		NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
		[req setValue:[@"Bearer " stringByAppendingString:t] forHTTPHeaderField:@"Authorization"];
		if (self.stopped) return;
		[self run:[TTASession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
			NSInteger status = TTAAs(r, NSHTTPURLResponse.class) ? ((NSHTTPURLResponse *)r).statusCode : 0;
			NSDictionary *info = TTAAs(status == 200 && d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil, NSDictionary.class);
			NSString *b64 = TTAAs(info[@"manifest"], NSString.class), *quality = TTAAs(info[@"audioQuality"], NSString.class), *mime = TTAAs(info[@"manifestMimeType"], NSString.class);
			NSData *raw = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
			NSArray<NSURL *> *parts = !raw ? nil : [mime isEqualToString:@"application/dash+xml"] ? TTAParts(raw) : [mime isEqualToString:@"application/vnd.tidal.bts"] ? TTABTS(raw) : nil;
			if (!parts || !quality) {
				TTALog(@"v1 failed for %@ (%ld %@ %@ %@), using TIDAL's stream", track, (long)status, quality, mime, e.localizedDescription ?: @"");
				return [self send:orig];
			}
			NSString *ext = parts.count > 1 ? @"m4a" : parts[0].pathExtension.length ? parts[0].pathExtension : @"mp4";
			NSURL *dest = [TTAFolder() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.%@", track, quality, ext]];
			[self download:parts to:dest done:^(NSURL *file) {
				if (!file) {
					TTALog(@"v1 download failed for %@, using TIDAL's stream", track);
					return [self send:orig];
				}
				[self reply:TTARewrite(TTAV1Manifest(track, info, file.absoluteString), YES)
				    response:[[NSHTTPURLResponse alloc] initWithURL:orig.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"application/vnd.api+json" }]
				       error:nil];
			}];
		}]];
	});
}

- (void)reply:(NSData *)body response:(NSURLResponse *)response error:(NSError *)error {
	NSHTTPURLResponse *http = TTAAs(response, NSHTTPURLResponse.class);
	if (http) {
		NSMutableDictionary *headers = [NSMutableDictionary dictionary];
		[http.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
			if ([k caseInsensitiveCompare:@"Content-Encoding"] && [k caseInsensitiveCompare:@"Content-Length"]) headers[k] = v;
		}];
		headers[@"Content-Length"] = @(body.length).stringValue;
		response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:http.statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers];
	}
	CFRunLoopPerformBlock((__bridge CFRunLoopRef)_runLoop, (__bridge CFTypeRef)_modes, ^{
		if (self.stopped) return;
		if (error || !response) return [self.client URLProtocol:self didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
		[self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
		if (body.length) [self.client URLProtocol:self didLoadData:body];
		[self.client URLProtocolDidFinishLoading:self];
	});
	CFRunLoopWakeUp((__bridge CFRunLoopRef)_runLoop);
}

- (void)stopLoading {
	self.stopped = YES;
	@synchronized (self) {
		for (NSURLSessionTask *t in _tasks) [t cancel];
	}
}
@end

#pragma mark - Tap

typedef struct {
	CFStringRef uri;
	void *ctx[kMaxStages];
	unsigned ch;
	BOOL ok;
} TTATap;

static void TTATapInit(MTAudioProcessingTapRef tap, void *info, void **storage) {
	TTATap *t = calloc(1, sizeof *t);
	t->uri = CFRetain(info);
	*storage = t;
}

static void TTATapUnprepare(MTAudioProcessingTapRef tap) {
	TTATap *t = MTAudioProcessingTapGetStorage(tap);
	for (unsigned i = 0; i < gCount; i++)
		if (t->ctx[i]) gStages[i].free(t->ctx[i]), t->ctx[i] = NULL;
	t->ok = NO;
}

static void TTATapFinalize(MTAudioProcessingTapRef tap) {
	TTATapUnprepare(tap);
	TTATap *t = MTAudioProcessingTapGetStorage(tap);
	CFRelease(t->uri);
	free(t);
}

static void TTATapPrepare(MTAudioProcessingTapRef tap, CMItemCount max, const AudioStreamBasicDescription *f) {
	TTATap *t = MTAudioProcessingTapGetStorage(tap);
	t->ch = f->mChannelsPerFrame;
	t->ok = (f->mFormatFlags & kAudioFormatFlagIsFloat) && f->mBitsPerChannel == 32 && t->ch && t->ch <= kMaxChannels;
	if (!t->ok) return TTALog(@"tap: can't process %u-bit %u ch audio (flags %x)", (unsigned)f->mBitsPerChannel, t->ch, (unsigned)f->mFormatFlags);
	for (unsigned i = 0; i < gCount; i++) t->ctx[i] = gStages[i].prepare((__bridge NSString *)t->uri, f->mSampleRate, t->ch, (unsigned)max);
}

static void TTATapProcess(MTAudioProcessingTapRef tap, CMItemCount n, MTAudioProcessingTapFlags flags, AudioBufferList *bufs, CMItemCount *outN, MTAudioProcessingTapFlags *outFlags) {
	CMTimeRange range = kCMTimeRangeInvalid;
	if (MTAudioProcessingTapGetSourceAudio(tap, n, bufs, outFlags, &range, outN)) return;
	TTATap *t = MTAudioProcessingTapGetStorage(tap);
	double time = CMTIME_IS_NUMERIC(range.start) ? CMTimeGetSeconds(range.start) : NAN;
	if (!t->ok) return;
	BOOL start = (*outFlags & kMTAudioProcessingTapFlag_StartOfStream) != 0;
	float *p[kMaxChannels];
	BOOL split = bufs->mNumberBuffers >= t->ch;
	for (unsigned c = 0; c < t->ch; c++) p[c] = split ? bufs->mBuffers[c].mData : (float *)bufs->mBuffers[0].mData + c;
	for (unsigned i = 0; i < gCount; i++)
		if (t->ctx[i]) gStages[i].process(t->ctx[i], p, split ? 1 : t->ch, *outN, start, time);
}

static AVAudioMix *TTAMix(AVPlayerItem *item, AVAudioMix *mix) {
	NSString *uri = objc_getAssociatedObject(item, &kURIKey);
	AVAssetTrack *track = objc_getAssociatedObject(item, &kTrackKey);
	if (!uri || !track) return mix;
	MTAudioProcessingTapCallbacks cb = { kMTAudioProcessingTapCallbacksVersion_0, (__bridge void *)uri, TTATapInit, TTATapFinalize, TTATapPrepare, TTATapUnprepare, TTATapProcess };
	MTAudioProcessingTapRef tap;
	if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)) return mix;
	AVMutableAudioMixInputParameters *p = [mix.inputParameters.firstObject mutableCopy] ?: [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
	p.trackID = track.trackID;
	p.audioTapProcessor = tap;
	CFRelease(tap);
	AVMutableAudioMix *out = [AVMutableAudioMix audioMix];
	out.inputParameters = @[ p ];
	return out;
}

static void (*orig_setAudioMix)(AVPlayerItem *, SEL, AVAudioMix *);
static void hook_setAudioMix(AVPlayerItem *self, SEL _cmd, AVAudioMix *mix) { orig_setAudioMix(self, _cmd, TTAMix(self, mix)); }

// The next song is queued minutes ahead (a local file counts as fully downloaded), long before AVQueuePlayer opens it,
// so its item.tracks stay empty: take the track from the file itself.
static void TTAAttach(AVPlayerItem *item) {
	__weak AVPlayerItem *weak = item;
	[item.asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *e) {
		AVAssetTrack *track = tracks.firstObject;
		dispatch_async(dispatch_get_main_queue(), ^{
			AVPlayerItem *it = weak;
			if (!it) return;
			if (!track) return TTALog(@"tap: no audio track (%@)", e.localizedDescription);
			objc_setAssociatedObject(it, &kTrackKey, track, OBJC_ASSOCIATION_RETAIN);
			it.audioMix = it.audioMix;
			TTALog(@"tap: attached to track %d", track.trackID);
		});
	}];
}

@interface TTAFormatGroup : AVDateRangeMetadataGroup
@end

@implementation TTAFormatGroup
- (NSString *)classifyingLabel { return @"com.tidal.format"; }
@end

static char kCollectorKey, kObserverKey;

static void TTADeliver(AVPlayerItem *item) {
	AVPlayerItemMetadataCollector *mc = objc_getAssociatedObject(item, &kCollectorKey);
	NSString *uri = ((AVURLAsset *)TTAAs(item.asset, AVURLAsset.class)).URL.absoluteString;
	NSDictionary *meta;
	@synchronized (gV1) {
		meta = uri ? gV1[uri] : nil;
	}
	id d = mc.delegate;
	if (!meta[@"format"] || !d) return;
	NSMutableArray *mis = [NSMutableArray array];
	for (NSArray *kv in @[ @[ @"X-COM-TIDAL-FORMAT", meta[@"format"] ], @[ @"X-COM-TIDAL-SAMPLE-RATE", meta[@"sampleRate"] ?: NSNull.null ], @[ @"X-COM-TIDAL-SAMPLE-DEPTH", meta[@"bitDepth"] ?: NSNull.null ] ]) {
		if (kv[1] == NSNull.null) continue;
		AVMutableMetadataItem *mi = [AVMutableMetadataItem metadataItem];
		mi.key = kv[0];
		mi.keySpace = AVMetadataKeySpaceHLSDateRange;
		mi.value = kv[1];
		[mis addObject:mi];
	}
	AVDateRangeMetadataGroup *g = [[TTAFormatGroup alloc] initWithItems:mis startDate:NSDate.date endDate:nil];
	dispatch_async(mc.delegateQueue ?: dispatch_get_main_queue(), ^{
		SEL sel = sel_registerName("metadataCollector:didCollectDateRangeMetadataGroups:indexesOfNewGroups:indexesOfModifiedGroups:");
		if ([d respondsToSelector:sel]) ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(d, sel, mc, @[ g ], [NSIndexSet indexSetWithIndex:0], [NSIndexSet indexSet]);
	});
}

// ponytail: the SDK drops format metadata unless the item is already registered and current, so resend on a short timer and whenever the queue advances
static void TTADeliverSoon(AVPlayerItem *item) {
	TTADeliver(item);
	__weak AVPlayerItem *weak = item;
	for (NSNumber *delay in @[ @0.1, @0.25, @0.5, @1, @2, @4 ])
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			if (weak) TTADeliver(weak);
		});
}

@interface TTACurrent : NSObject
@end

@implementation TTACurrent
- (void)observeValueForKeyPath:(NSString *)path ofObject:(AVQueuePlayer *)player change:(NSDictionary *)change context:(void *)ctx {
	AVPlayerItem *item = TTAAs(change[NSKeyValueChangeNewKey], AVPlayerItem.class);
	if (item) TTADeliverSoon(item);
}
@end

static void (*orig_addCollector)(AVPlayerItem *, SEL, AVPlayerItemMediaDataCollector *);
static void hook_addCollector(AVPlayerItem *self, SEL _cmd, AVPlayerItemMediaDataCollector *collector) {
	orig_addCollector(self, _cmd, collector);
	AVPlayerItemMetadataCollector *mc = TTAAs(collector, AVPlayerItemMetadataCollector.class);
	if (!mc) return;
	objc_setAssociatedObject(self, &kCollectorKey, mc, OBJC_ASSOCIATION_RETAIN);
	TTADeliverSoon(self);
}

static void (*orig_insert)(AVQueuePlayer *, SEL, AVPlayerItem *, AVPlayerItem *);
static void hook_insert(AVQueuePlayer *self, SEL _cmd, AVPlayerItem *item, AVPlayerItem *after) {
	NSString *uri = ((AVURLAsset *)TTAAs(item.asset, AVURLAsset.class)).URL.absoluteString;
	BOOL v1;
	@synchronized (gV1) {
		v1 = uri && gV1[uri];
	}
	if (v1) {
		objc_setAssociatedObject(item, &kURIKey, uri, OBJC_ASSOCIATION_COPY);
		TTAAttach(item);
		if (!objc_getAssociatedObject(self, &kObserverKey)) {
			TTACurrent *o = [TTACurrent new];
			objc_setAssociatedObject(self, &kObserverKey, o, OBJC_ASSOCIATION_RETAIN);
			[self addObserver:o forKeyPath:@"currentItem" options:NSKeyValueObservingOptionNew context:NULL];
		}
	}
	orig_insert(self, _cmd, item, after);
}

#pragma mark - Hooks

static NSArray *(*orig_protocolClasses)(NSURLSessionConfiguration *, SEL);
static NSArray *hook_protocolClasses(NSURLSessionConfiguration *self, SEL _cmd) {
	NSArray *a = orig_protocolClasses(self, _cmd) ?: @[];
	return [a containsObject:TTAProtocol.class] ? a : [@[ TTAProtocol.class ] arrayByAddingObjectsFromArray:a];
}

static void TTASwap(Class c, SEL sel, IMP imp, void *orig) {
	*(IMP *)orig = method_setImplementation(class_getInstanceMethod(c, sel), imp);
}

// Called from other tweaks' constructors, which run before ours: nothing here may rely on TTInit.
void TTAudioAdd(const TTAudioStage *stage) {
	if (!stage || gCount >= kMaxStages) return;
	gStages[gCount++] = *stage;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		gV1 = [NSMutableDictionary dictionary];
		[NSURLProtocol registerClass:TTAProtocol.class];
		Class cfg = object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration);
		Method m = class_getInstanceMethod(cfg, @selector(protocolClasses));
		if (!m) return TTALog(@"no protocolClasses on %s", class_getName(cfg));
		if (class_addMethod(cfg, @selector(protocolClasses), (IMP)hook_protocolClasses, method_getTypeEncoding(m))) orig_protocolClasses = (void *)method_getImplementation(m);
		else orig_protocolClasses = (void *)method_setImplementation(m, (IMP)hook_protocolClasses);
		TTASwap(AVQueuePlayer.class, @selector(insertItem:afterItem:), (IMP)hook_insert, &orig_insert);
		TTASwap(AVPlayerItem.class, @selector(addMediaDataCollector:), (IMP)hook_addCollector, &orig_addCollector);
		TTASwap(AVPlayerItem.class, @selector(setAudioMix:), (IMP)hook_setAudioMix, &orig_setAudioMix);
		TTALog(@"ready");
	});
}
