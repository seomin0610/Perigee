#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdatomic.h>
#import "DSP.h"

static NSString *const kHandled = @"LDHandled";
static NSString *const kOffset = @"ld.offset";
static NSString *const kBoost = @"ld.boost";
static NSString *const kEQ = @"ld.eq";
static const double kTidalPreAmp = 4, kMaxGain = 4, kTargetLufs = -14;
static NSCache<NSString *, NSNumber *> *gBoost;
static char kBoostKey, kTrackKey;

static void LDLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void LDLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalLoudness] %{public}@", line);
}

static NSString *LDL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}

static id LDAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static BOOL LDBoostOn(void) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:kBoost];
	return v ? [v boolValue] : YES;
}

static NSURLSession *LDSession(void) {
	static NSURLSession *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; });
	return s;
}

static BOOL LDManifest(NSURLRequest *r) {
	NSURL *u = r.URL;
	return [r.HTTPMethod isEqualToString:@"GET"] && [u.host hasSuffix:@"tidal.com"] && [u.path.stringByDeletingLastPathComponent hasSuffix:@"/trackManifests"];
}

static NSString *LDPlaybackTrack(NSURLRequest *r) {
	NSString *track = r.URL.lastPathComponent;
	return LDManifest(r) && [r.URL.query containsString:@"usage=PLAYBACK"] && track.length &&
	               [track rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound
	           ? track
	           : nil;
}

static NSString *LDQuality(NSURL *u) {
	NSMutableArray *formats = [NSMutableArray array];
	for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems)
		if ([q.name hasPrefix:@"formats"] && q.value) [formats addObjectsFromArray:[q.value componentsSeparatedByString:@","]];
	for (NSArray *p in @[ @[ @"FLAC_HIRES", @"HI_RES_LOSSLESS" ], @[ @"FLAC", @"LOSSLESS" ], @[ @"AACLC", @"HIGH" ] ])
		if ([formats containsObject:p[0]]) return p[1];
	return @"LOW";
}

// TIDAL's player only reads the album gain, so tracks of one album keep their own loudness: hand it the track gain instead.
// It can only turn down, so DRM-free v1 streams get no gain from TIDAL and the tap below does it all, raising quiet songs too.
static NSData *LDRewrite(NSData *body, BOOL v1) {
	NSMutableDictionary *doc = LDAs(body ? [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:nil] : nil, NSMutableDictionary.class);
	NSMutableDictionary *attrs = LDAs(LDAs(doc[@"data"], NSDictionary.class)[@"attributes"], NSMutableDictionary.class);
	NSDictionary *track = LDAs(attrs[@"trackAudioNormalizationData"], NSDictionary.class);
	NSDictionary *album = LDAs(attrs[@"albumAudioNormalizationData"], NSDictionary.class);
	NSNumber *gain = LDAs(track[@"replayGain"], NSNumber.class);
	NSString *uri = LDAs(attrs[@"uri"], NSString.class);
	if (!gain) return nil;
	double offset = [NSUserDefaults.standardUserDefaults doubleForKey:kOffset];
	double total = MIN(pow(10, (gain.doubleValue + kTidalPreAmp + offset) / 20), kMaxGain);
	if (v1 && uri) {
		[gBoost setObject:@(total) forKey:uri];
		[attrs removeObjectForKey:@"albumAudioNormalizationData"];
	} else
		attrs[@"albumAudioNormalizationData"] = @{ @"replayGain": @(gain.doubleValue + offset), @"peakAmplitude": track[@"peakAmplitude"] ?: album[@"peakAmplitude"] ?: @1 };
	LDLog(@"%@%@: album %@ dB -> track %@ %+g dB, peak %@, x%.2f", v1 ? @"v1 " : @"", doc[@"data"][@"id"], album[@"replayGain"], gain, offset, track[@"peakAmplitude"],
	      v1 ? total : MIN(total, 1));
	return [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
}

#pragma mark - v1 stream

@interface LDMPD : NSObject <NSXMLParserDelegate>
@property (nonatomic) NSDictionary<NSString *, NSString *> *tmpl;
@property (nonatomic) NSMutableArray<NSNumber *> *durations;
@end

@implementation LDMPD
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary<NSString *, NSString *> *)a {
	if ([e isEqualToString:@"SegmentTemplate"]) _tmpl = a;
	else if ([e isEqualToString:@"S"] && _tmpl)
		for (NSInteger i = 0; i <= MAX(0, a[@"r"].integerValue); i++) [_durations addObject:@(a[@"d"].doubleValue)];
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
	if ([e isEqualToString:@"SegmentTemplate"]) [p abortParsing];
}
@end

static NSString *LDHLS(NSData *mpd) {
	LDMPD *m = [LDMPD new];
	m.durations = [NSMutableArray array];
	NSXMLParser *p = [[NSXMLParser alloc] initWithData:mpd];
	p.delegate = m;
	[p parse];
	NSString *init = m.tmpl[@"initialization"], *media = m.tmpl[@"media"];
	if (!init || !media || !m.durations.count) return nil;
	double scale = m.tmpl[@"timescale"].doubleValue ?: 1;
	NSInteger n = m.tmpl[@"startNumber"] ? m.tmpl[@"startNumber"].integerValue : 1;
	double longest = [[m.durations valueForKeyPath:@"@max.doubleValue"] doubleValue] / scale;
	NSMutableString *s = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%d\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
	                                                       @"#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"%@\"\n",
	                                                       (int)ceil(longest), init];
	for (NSNumber *d in m.durations)
		[s appendFormat:@"#EXTINF:%.6f,\n%@\n", d.doubleValue / scale, [media stringByReplacingOccurrencesOfString:@"$Number$" withString:@(n++).stringValue]];
	[s appendString:@"#EXT-X-ENDLIST\n"];
	return s;
}

static NSDictionary *LDGain(id gain, id peak) {
	return LDAs(gain, NSNumber.class) && LDAs(peak, NSNumber.class) ? @{ @"replayGain": gain, @"peakAmplitude": peak } : nil;
}

static NSData *LDV1Manifest(NSString *track, NSData *data) {
	NSDictionary *info = LDAs(data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil, NSDictionary.class);
	NSString *b64 = LDAs(info[@"manifest"], NSString.class);
	BOOL dash = [LDAs(info[@"manifestMimeType"], NSString.class) isEqualToString:@"application/dash+xml"];
	NSData *raw = dash && b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
	NSString *m3u8 = raw ? LDHLS(raw) : nil;
	if (!m3u8) {
		LDLog(@"v1 %@ unusable: %@ %@", track, info[@"audioQuality"], info[@"manifestMimeType"]);
		return nil;
	}
	NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
	attrs[@"uri"] = [@"data:application/vnd.apple.mpegurl;base64," stringByAppendingString:[[m3u8 dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
	NSString *format = @{ @"HI_RES_LOSSLESS": @"FLAC_HIRES", @"LOSSLESS": @"FLAC", @"HIGH": @"AACLC", @"LOW": @"HEAACV1" }[LDAs(info[@"audioQuality"], NSString.class) ?: @""];
	if (format) attrs[@"formats"] = @[ format ];
	attrs[@"trackPresentation"] = LDAs(info[@"assetPresentation"], NSString.class);
	attrs[@"hash"] = LDAs(info[@"manifestHash"], NSString.class);
	attrs[@"trackAudioNormalizationData"] = LDGain(info[@"trackReplayGain"], info[@"trackPeakAmplitude"]);
	attrs[@"albumAudioNormalizationData"] = LDGain(info[@"albumReplayGain"], info[@"albumPeakAmplitude"]);
	return [NSJSONSerialization dataWithJSONObject:@{ @"data": @{ @"id": track, @"type": @"trackManifests", @"attributes": attrs },
	                                                  @"links": @{ @"self": [@"/trackManifests/" stringByAppendingString:track] } }
	                                       options:0
	                                         error:nil];
}

#pragma mark - Interception

@interface LDProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@end

@implementation LDProtocol {
	NSURLSessionDataTask *_task;
	id _runLoop;
	NSArray *_modes;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return ![NSURLProtocol propertyForKey:kHandled inRequest:r] && LDManifest(r); }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }

- (void)startLoading {
	_runLoop = (__bridge id)CFRunLoopGetCurrent();
	NSString *mode = CFBridgingRelease(CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()));
	_modes = mode ? @[ mode, NSRunLoopCommonModes ] : @[ NSRunLoopCommonModes ];

	NSMutableURLRequest *req = [self.request mutableCopy];
	[NSURLProtocol setProperty:@YES forKey:kHandled inRequest:req];
	NSString *track = LDPlaybackTrack(req);
	if (track && LDBoostOn()) return [self v1:track original:req];
	[self send:req];
}

- (void)send:(NSURLRequest *)req {
	if (self.stopped) return;
	_task = [LDSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		NSData *body = LDAs(r, NSHTTPURLResponse.class) && ((NSHTTPURLResponse *)r).statusCode == 200 ? LDRewrite(d, NO) : nil;
		[self reply:body ?: d response:r error:e];
	}];
	[_task resume];
}

- (void)v1:(NSString *)track original:(NSURLRequest *)orig {
	void (*token)(void (^)(NSString *)) = dlsym(RTLD_DEFAULT, "TTV1Token");
	if (!token) return [self send:orig];
	token(^(NSString *t) {
		if (!t) {
			LDLog(@"%@: no Secondary Login, TIDAL's stream can only be turned down", track);
			return [self send:orig];
		}
		NSString *url = [NSString stringWithFormat:@"https://api.tidal.com/v1/tracks/%@/playbackinfo?audioquality=%@&playbackmode=STREAM&assetpresentation=FULL", track,
		                                           LDQuality(orig.URL)];
		NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
		[req setValue:[@"Bearer " stringByAppendingString:t] forHTTPHeaderField:@"Authorization"];
		if (self.stopped) return;
		self->_task = [LDSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
			NSInteger status = LDAs(r, NSHTTPURLResponse.class) ? ((NSHTTPURLResponse *)r).statusCode : 0;
			NSData *doc = status == 200 ? LDV1Manifest(track, d) : nil;
			NSData *body = doc ? LDRewrite(doc, YES) ?: doc : nil;
			if (!body) {
				LDLog(@"v1 failed for %@ (%ld %@), using TIDAL's stream", track, (long)status, e.localizedDescription ?: @"");
				return [self send:orig];
			}
			[self reply:body response:[[NSHTTPURLResponse alloc] initWithURL:orig.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"application/vnd.api+json" }] error:nil];
		}];
		[self->_task resume];
	});
}

- (void)reply:(NSData *)body response:(NSURLResponse *)response error:(NSError *)error {
	NSHTTPURLResponse *http = LDAs(response, NSHTTPURLResponse.class);
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
	[_task cancel];
}
@end

#pragma mark - Tap

static _Atomic(float) gVolume = 1;
static _Atomic(bool) gEQ = true;

typedef struct {
	LDDSP dsp;
	float gain, target, eqVolume;
	BOOL ok, logged;
} LDTap;

static void LDTapInit(MTAudioProcessingTapRef tap, void *info, void **storage) {
	LDTap *t = calloc(1, sizeof *t);
	t->gain = (intptr_t)info / 1000.f;
	t->target = kTargetLufs + [NSUserDefaults.standardUserDefaults doubleForKey:kOffset];
	*storage = t;
}

static void LDTapUnprepare(MTAudioProcessingTapRef tap) {
	LDTap *t = MTAudioProcessingTapGetStorage(tap);
	LDDSPFree(&t->dsp);
	t->ok = NO;
}

static void LDTapFinalize(MTAudioProcessingTapRef tap) {
	LDTapUnprepare(tap);
	free(MTAudioProcessingTapGetStorage(tap));
}

static void LDTapPrepare(MTAudioProcessingTapRef tap, CMItemCount max, const AudioStreamBasicDescription *f) {
	LDTap *t = MTAudioProcessingTapGetStorage(tap);
	t->ok = (f->mFormatFlags & kAudioFormatFlagIsFloat) && f->mBitsPerChannel == 32 && LDDSPInit(&t->dsp, f->mSampleRate, f->mChannelsPerFrame, t->gain);
	t->eqVolume = -1;
	if (!t->ok) LDLog(@"tap: can't process %u-bit %u ch audio (flags %x)", (unsigned)f->mBitsPerChannel, (unsigned)f->mChannelsPerFrame, (unsigned)f->mFormatFlags);
}

static void LDTapProcess(MTAudioProcessingTapRef tap, CMItemCount n, MTAudioProcessingTapFlags flags, AudioBufferList *bufs, CMItemCount *outN, MTAudioProcessingTapFlags *outFlags) {
	if (MTAudioProcessingTapGetSourceAudio(tap, n, bufs, outFlags, NULL, outN)) return;
	LDTap *t = MTAudioProcessingTapGetStorage(tap);
	if (!t->ok) return;
	if (*outFlags & kMTAudioProcessingTapFlag_StartOfStream) LDDSPReset(&t->dsp);
	BOOL eq = atomic_load(&gEQ);
	float vol = atomic_load(&gVolume);
	if (eq && vol != t->eqVolume) LDDSPSetEQ(&t->dsp, t->eqVolume = vol, t->target);
	if (!t->logged) {
		t->logged = YES;
		float gain = t->gain;
		float bass = t->dsp.bassDb, treble = t->dsp.trebleDb, lift = 20 * log10f(t->dsp.lift);
		dispatch_async(dispatch_get_main_queue(), ^{
			LDLog(@"tap: x%.2f, EQ %@ at volume %.2f (bass %+.1f, treble %+.1f, lift %+.1f dB)", gain, eq ? @"on" : @"off", vol, bass, treble, lift);
		});
	}
	float *p[LD_MAXCH];
	unsigned ch = t->dsp.ch;
	BOOL split = bufs->mNumberBuffers >= ch;
	for (unsigned c = 0; c < ch; c++) p[c] = split ? bufs->mBuffers[c].mData : (float *)bufs->mBuffers[0].mData + c;
	LDDSPRun(&t->dsp, p, split ? 1 : ch, *outN, eq);
}

@interface LDVolume : NSObject
@end
@implementation LDVolume
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
	atomic_store(&gVolume, AVAudioSession.sharedInstance.outputVolume);
}
@end

static AVAudioMix *LDMix(AVPlayerItem *item, AVAudioMix *mix) {
	NSNumber *gain = objc_getAssociatedObject(item, &kBoostKey);
	AVAssetTrack *track = objc_getAssociatedObject(item, &kTrackKey);
	if (!gain || !track) return mix;
	MTAudioProcessingTapCallbacks cb = { kMTAudioProcessingTapCallbacksVersion_0, (void *)(intptr_t)lround(gain.doubleValue * 1000), LDTapInit, LDTapFinalize, LDTapPrepare, LDTapUnprepare, LDTapProcess };
	MTAudioProcessingTapRef tap;
	if (MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)) return mix;
	AVMutableAudioMixInputParameters *p = [mix.inputParameters.firstObject mutableCopy] ?: [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
	p.trackID = track.trackID;
	p.audioTapProcessor = tap;
	CFRelease(tap);
	AVMutableAudioMix *out = [AVMutableAudioMix audioMix];
	out.inputParameters = @[ p ];
	return out;
}

static void (*orig_setAudioMix)(AVPlayerItem *, SEL, AVAudioMix *);
static void hook_setAudioMix(AVPlayerItem *self, SEL _cmd, AVAudioMix *mix) { orig_setAudioMix(self, _cmd, LDMix(self, mix)); }

static void LDAttach(AVPlayerItem *item, int tries) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		static LDVolume *watch;
		watch = [LDVolume new];
		[AVAudioSession.sharedInstance addObserver:watch forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionInitial context:NULL];
	});
	AVAssetTrack *track;
	for (AVPlayerItemTrack *t in item.tracks)
		if ([t.assetTrack.mediaType isEqualToString:AVMediaTypeAudio]) track = t.assetTrack;
	if (!track) {
		if (tries >= 40) return LDLog(@"tap: no audio track after 10 s (status %ld)", (long)item.status);
		__weak AVPlayerItem *weak = item;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
			if (weak) LDAttach(weak, tries + 1);
		});
		return;
	}
	objc_setAssociatedObject(item, &kTrackKey, track, OBJC_ASSOCIATION_RETAIN);
	item.audioMix = item.audioMix;
	LDLog(@"tap: attached to track %d", track.trackID);
}

static void (*orig_insert)(AVQueuePlayer *, SEL, AVPlayerItem *, AVPlayerItem *);
static void hook_insert(AVQueuePlayer *self, SEL _cmd, AVPlayerItem *item, AVPlayerItem *after) {
	NSString *uri = ((AVURLAsset *)LDAs(item.asset, AVURLAsset.class)).URL.absoluteString;
	NSNumber *gain = uri ? [gBoost objectForKey:uri] : nil;
	if (gain) {
		objc_setAssociatedObject(item, &kBoostKey, gain, OBJC_ASSOCIATION_RETAIN);
		dispatch_async(dispatch_get_main_queue(), ^{ LDAttach(item, 0); });
	}
	orig_insert(self, _cmd, item, after);
}

#pragma mark - Hooks

// TIDAL's Normalize volume only sets one AVPlayer volume per song; keep it on so the track gain above is applied
static NSString *const kTidalKey = @"prefs_using_loudness_normalization";

static BOOL LDTidalKey(NSString *key) {
	if (![key isEqualToString:kTidalKey]) return NO;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ LDLog(@"TIDAL asked for Normalize volume: on"); });
	return YES;
}

static BOOL (*orig_boolForKey)(NSUserDefaults *, SEL, NSString *);
static BOOL hook_boolForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
	return LDTidalKey(key) ?: orig_boolForKey(self, _cmd, key);
}

static id (*orig_objectForKey)(NSUserDefaults *, SEL, NSString *);
static id hook_objectForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
	return LDTidalKey(key) ? @YES : orig_objectForKey(self, _cmd, key);
}

static NSArray *(*orig_protocolClasses)(NSURLSessionConfiguration *, SEL);
static NSArray *hook_protocolClasses(NSURLSessionConfiguration *self, SEL _cmd) {
	NSArray *a = orig_protocolClasses(self, _cmd) ?: @[];
	return [a containsObject:LDProtocol.class] ? a : [@[ LDProtocol.class ] arrayByAddingObjectsFromArray:a];
}

static void LDSwap(Class c, SEL sel, IMP imp, void *orig) {
	*(IMP *)orig = method_setImplementation(class_getInstanceMethod(c, sel), imp);
}

@interface LDSettings : NSObject
@end
@implementation LDSettings
+ (NSArray *)ttSections {
	return @[
		@{ @"items": @[
			   @{ @"type": @"switch", @"key": kBoost, @"default": @YES, @"title": LDL(@"Raise quiet songs", @"조용한 곡 키우기"),
			      @"detail": LDL(@"Plays the DRM-free stream from Secondary Login", @"보조 로그인으로 DRM 없는 스트림 재생") },
			   @{ @"type": @"switch", @"key": kEQ, @"default": @YES, @"title": LDL(@"Volume-aware EQ", @"볼륨 맞춤 EQ"), @"indent": @YES,
			      @"detail": LDL(@"Keeps bass and treble at low phone volume", @"폰 볼륨을 줄여도 저음·고음 유지"), @"visible": ^BOOL { return LDBoostOn(); },
			      @"set": ^(id v) { atomic_store(&gEQ, [v boolValue]); } },
			   @{ @"type": @"choice", @"key": kOffset, @"default": @0, @"title": LDL(@"Level", @"기준 음량"),
			      @"options": @[ @[ @0, LDL(@"TIDAL default", @"TIDAL 기본") ], @[ @-4, @"−4 dB" ], @[ @-8, @"−8 dB" ] ] },
		   ],
		   @"footer": LDL(@"Each song gets one fixed volume, from the next song on; nothing changes inside a song. "
		                  @"Raising quiet songs needs Secondary Login (Advanced), and a limiter catches only the moments that would clip; without it, loud songs are only turned down. "
		                  @"Volume-aware EQ adds back the bass and treble you hear less at low phone volume.",
		                  @"다음 곡부터 곡마다 볼륨 하나를 정해 같은 크기로 맞춰요. 곡 안에서는 볼륨을 건드리지 않아요. "
		                  @"조용한 곡 키우기는 보조 로그인(고급)이 필요하고, 키우다 넘치는 순간만 리미터가 눌러줘요. 로그인이 없으면 큰 곡을 줄이기만 해요. "
		                  @"볼륨 맞춤 EQ는 폰 볼륨을 낮췄을 때 덜 들리는 저음·고음을 채워줘요.") },
	];
}
@end

__attribute__((constructor)) static void LDInit(void) {
	if (NSClassFromString(@"TTCore") && ![NSUserDefaults.standardUserDefaults boolForKey:@"tt.TidalLoudness.enabled"]) return LDLog(@"turned off in TidalCore's settings");
	id eq = [NSUserDefaults.standardUserDefaults objectForKey:kEQ];
	atomic_store(&gEQ, eq ? [eq boolValue] : YES);
	gBoost = [NSCache new];
	gBoost.countLimit = 50;
	[NSURLProtocol registerClass:LDProtocol.class];
	Class cfg = object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration);
	Method m = class_getInstanceMethod(cfg, @selector(protocolClasses));
	if (!m) return LDLog(@"no protocolClasses on %s", class_getName(cfg));
	if (class_addMethod(cfg, @selector(protocolClasses), (IMP)hook_protocolClasses, method_getTypeEncoding(m))) orig_protocolClasses = (void *)method_getImplementation(m);
	else orig_protocolClasses = (void *)method_setImplementation(m, (IMP)hook_protocolClasses);
	LDSwap(NSUserDefaults.class, @selector(boolForKey:), (IMP)hook_boolForKey, &orig_boolForKey);
	LDSwap(NSUserDefaults.class, @selector(objectForKey:), (IMP)hook_objectForKey, &orig_objectForKey);
	LDSwap(AVQueuePlayer.class, @selector(insertItem:afterItem:), (IMP)hook_insert, &orig_insert);
	LDSwap(AVPlayerItem.class, @selector(setAudioMix:), (IMP)hook_setAudioMix, &orig_setAudioMix);
	LDLog(@"loaded");
}
