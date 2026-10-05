// Load after TidalLockLyrics (it must hook setNowPlayingInfo: first); before or after RL/Meanings is fine.
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreHaptics/CoreHaptics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/log.h>
#import <QuartzCore/QuartzCore.h>
#import "Analyze.h"

static void HTLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void HTLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalHaptics] %{public}@", line);
}

static NSString *kISRCKey;

static void (*orig_setInfo)(MPNowPlayingInfoCenter *, SEL, NSDictionary *);
static NSURLSessionDataTask *(*orig_dataTask)(NSURLSession *, SEL, NSURLRequest *, id);

static NSMutableDictionary<NSString *, NSMutableArray<NSArray *> *> *gByTitle;
static NSMutableSet<NSString *> *gAsked;
static NSURLRequest *gTidalReq;
static NSURLSession *gTidalSession;
static NSDictionary *gInfo;
static double gAt;
static NSString *gChecked;
static NSNumber *gAvailable;

static NSString *const kOnKey = @"ht.enabled";
static NSString *const kAppleKey = @"ht.apple";
static NSString *const kFollowKey = @"ht.follow";
static NSString *const kStrengthKey = @"ht.strength";

static BOOL HTOn(void) { return [NSUserDefaults.standardUserDefaults boolForKey:kOnKey]; }
static BOOL HTHasCore(void) {
	static void *core;
	if (!core) core = dlsym(RTLD_DEFAULT, "TTV1Token");
	return core != NULL;
}
static BOOL HTApple(void) { return !HTHasCore() || [NSUserDefaults.standardUserDefaults boolForKey:kAppleKey]; }
static BOOL HTOwn(void) { return HTOn() && !HTApple(); }

static NSString *HTL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}

static id HTManager(void) {
	Class c = NSClassFromString(@"MAMusicHapticsManager");
	return c ? ((id (*)(id, SEL))objc_msgSend)(c, sel_registerName("sharedManager")) : nil;
}

static BOOL HTSystemOn(void) {
	id m = HTManager();
	return m && ((BOOL (*)(id, SEL))objc_msgSend)(m, sel_registerName("isActive"));
}

static id HTAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static NSString *HTKey(NSString *title) {
	return [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
}

static double HTDuration(id v) {
	if (HTAs(v, NSNumber.class)) return [v doubleValue];
	NSString *s = HTAs(v, NSString.class);
	if (![s hasPrefix:@"PT"]) return 0;
	double total = 0, n = 0;
	NSScanner *sc = [NSScanner scannerWithString:[s substringFromIndex:2]];
	while (!sc.isAtEnd && [sc scanDouble:&n]) {
		NSString *unit = nil;
		if (![sc scanCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"HMS"] intoString:&unit]) break;
		total += n * ([unit isEqualToString:@"H"] ? 3600 : [unit isEqualToString:@"M"] ? 60 : 1);
	}
	return total;
}

static void HTWalk(id o, NSMutableArray *out, int depth) {
	if (depth > 12) return;
	if (HTAs(o, NSArray.class)) {
		for (id x in o) HTWalk(x, out, depth + 1);
		return;
	}
	NSDictionary *d = HTAs(o, NSDictionary.class);
	if (!d) return;
	NSDictionary *a = [d[@"type"] isEqual:@"tracks"] ? HTAs(d[@"attributes"], NSDictionary.class) ?: d : d;
	NSString *isrc = HTAs(a[@"isrc"], NSString.class), *title = HTAs(a[@"title"], NSString.class);
	if (isrc.length && title.length) {
		NSNumber *dur = @(HTDuration(a[@"duration"]));
		NSString *tid = d[@"id"] ? [NSString stringWithFormat:@"%@", d[@"id"]] : @"";
		[out addObject:@[ title, isrc, dur, tid ]];
		NSString *version = HTAs(a[@"version"], NSString.class);
		if (version.length) [out addObject:@[ [NSString stringWithFormat:@"%@ (%@)", title, version], isrc, dur, tid ]];
	}
	for (id x in d.allValues) HTWalk(x, out, depth + 1);
}

#pragma mark - Now playing

static NSArray *HTMatch(NSDictionary *info) {
	NSString *title = HTAs(info[MPMediaItemPropertyTitle], NSString.class);
	if (!title.length) return nil;
	double dur = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
	NSArray *best = nil;
	double bestOff = 3;
	for (NSArray *e in gByTitle[HTKey(title)]) {
		double d = [e[1] doubleValue];
		if (!dur || !d) {
			if (!best) best = e;
			continue;
		}
		if (fabs(d - dur) <= bestOff) {
			bestOff = fabs(d - dur);
			best = e;
		}
	}
	return best;
}

static void HTCheck(NSString *isrc, NSString *title) {
	if ([isrc isEqualToString:gChecked]) return;
	gChecked = isrc;
	gAvailable = nil;
	id m = HTManager();
	if (!m) return HTLog(@"MAMusicHapticsManager missing (iOS 18+ only)");
	BOOL active = HTSystemOn();
	void (^done)(BOOL) = ^(BOOL available) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if ([gChecked isEqualToString:isrc]) gAvailable = @(available);
		});
		HTLog(@"%@ %@: haptic track %@, Music Haptics setting %@", title, isrc, available ? @"available" : @"not available", active ? @"on" : @"off");
	};
	((void (*)(id, SEL, NSString *, id))objc_msgSend)(m, sel_registerName("checkHapticTrackAvailabilityForMediaMatchingCode:completionHandler:"), isrc, done);
}

static NSDictionary *HTWithISRC(NSDictionary *info) {
	if (!kISRCKey || info[kISRCKey] || !HTOn() || !HTApple()) return info;
	NSString *isrc = HTMatch(info)[0];
	if (!isrc) return info;
	HTCheck(isrc, info[MPMediaItemPropertyTitle]);
	NSMutableDictionary *d = [info mutableCopy];
	d[kISRCKey] = isrc;
	return d;
}

static void HTLearn(NSArray<NSArray *> *found);
static void HTResend(NSDictionary *info);

static void hook_setInfo(MPNowPlayingInfoCenter *self, SEL _cmd, NSDictionary *info) {
	if (!NSThread.isMainThread) {
		orig_setInfo(self, _cmd, info);
		NSDictionary *copy = [info copy];
		double at = CACurrentMediaTime();
		dispatch_async(dispatch_get_main_queue(), ^{
			// a newer info may have been set on the main thread meanwhile
			if (at < gAt) return;
			gInfo = copy;
			gAt = at;
			HTLearn(@[]);
		});
		return;
	}
	gInfo = info ? HTWithISRC(info) : nil;
	gAt = CACurrentMediaTime();
	orig_setInfo(self, _cmd, gInfo);
}

static void HTLearn(NSArray<NSArray *> *found) {
	for (NSArray *f in found) {
		NSString *key = HTKey(f[0]);
		NSMutableArray *list = gByTitle[key] ?: (gByTitle[key] = [NSMutableArray array]);
		NSArray *e = @[ f[1], f[2], f[3] ];
		NSUInteger i = [list indexOfObjectPassingTest:^BOOL(NSArray *x, NSUInteger n, BOOL *stop) { return [x[0] isEqual:e[0]] && [x[1] isEqual:e[1]]; }];
		if (i == NSNotFound) [list addObject:e];
		else if (![list[i][2] length]) list[i] = e;
	}
	if (!gInfo || !kISRCKey || gInfo[kISRCKey]) return;
	NSDictionary *with = HTWithISRC(gInfo);
	if (with != gInfo) HTResend(with);
}

static void HTResend(NSDictionary *info) {
	NSMutableDictionary *d = [info mutableCopy];
	double now = CACurrentMediaTime();
	if (d[MPNowPlayingInfoPropertyElapsedPlaybackTime])
		d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @([d[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] + [(d[MPNowPlayingInfoPropertyPlaybackRate] ?: @1) doubleValue] * (now - gAt));
	gInfo = d;
	gAt = now;
	orig_setInfo(MPNowPlayingInfoCenter.defaultCenter, @selector(setNowPlayingInfo:), d);
}

#pragma mark - TIDAL's replies

static NSString *HTPlaybackTrack(NSURL *url) {
	NSArray<NSString *> *p = url.pathComponents;
	for (NSUInteger i = 0; i + 1 < p.count; i++) {
		if ([p[i] isEqualToString:@"trackManifests"] && [url.query containsString:@"usage=PLAYBACK"]) return p[i + 1];
		if (i + 2 < p.count && [p[i] isEqualToString:@"tracks"] && [p[i + 2] hasPrefix:@"playbackinfo"]) return p[i + 1];
	}
	return nil;
}

static void HTAsk(NSString *tid) {
	if (!gTidalReq || [gAsked containsObject:tid]) return;
	[gAsked addObject:tid];
	NSURLComponents *c = [NSURLComponents componentsWithURL:gTidalReq.URL resolvingAgainstBaseURL:NO];
	NSMutableArray *q = [NSMutableArray array];
	for (NSURLQueryItem *i in c.queryItems)
		if ([i.name isEqualToString:@"countryCode"]) [q addObject:i];
	c.path = [@"/v2/tracks/" stringByAppendingString:tid];
	c.queryItems = q;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
	req.allHTTPHeaderFields = gTidalReq.allHTTPHeaderFields;
	[[gTidalSession ?: NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		if (e) HTLog(@"track %@: %@", tid, e.localizedDescription);
	}] resume];
}

static NSURLSessionDataTask *hook_dataTask(NSURLSession *self, SEL _cmd, NSURLRequest *req, void (^done)(NSData *, NSURLResponse *, NSError *)) {
	NSURL *url = req.URL;
	if (!done || ![url.host hasSuffix:@"tidal.com"]) return orig_dataTask(self, _cmd, req, done);
	NSString *playing = HTPlaybackTrack(url);
	BOOL openapi = [url.host hasSuffix:@"openapi.tidal.com"] && [req valueForHTTPHeaderField:@"Authorization"];
	if (playing || openapi) {
		NSURLRequest *r = [req copy];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (openapi) {
				gTidalReq = r;
				gTidalSession = self;
			}
			if (playing) HTAsk(playing);
		});
	}
	return orig_dataTask(self, _cmd, req, ^(NSData *data, NSURLResponse *resp, NSError *err) {
		if (data.length && data.length < 8 << 20 && [resp isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)resp).statusCode == 200) {
			id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
			NSMutableArray *found = [NSMutableArray array];
			if (json) HTWalk(json, found, 0);
			if (found.count) dispatch_async(dispatch_get_main_queue(), ^{ HTLearn(found); });
		}
		done(data, resp, err);
	});
}

#pragma mark - Song analysis

enum { HTIdle, HTLoading, HTReady, HTFailed };
static const double kRate = 22050;
static const double kLead = 0.02;
static NSHashTable<AVPlayer *> *gPlayers;
static CHHapticEngine *gEngine;
static id<CHHapticAdvancedPatternPlayer> gRumble;
static NSMutableArray<id<CHHapticPatternPlayer>> *gLive;
static dispatch_source_t gTimer;
static NSString *gTrack;
static NSData *gTaps, *gLevels;
static double gSlot, gFailedAt, gUntil = -1;
static NSUInteger gNext;
static NSInteger gLoad;

static NSURLSession *HTSession(void) {
	static NSURLSession *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; });
	return s;
}

@interface HTMPD : NSObject <NSXMLParserDelegate>
@property (nonatomic) NSDictionary<NSString *, NSString *> *tmpl;
@property (nonatomic) NSUInteger count;
@end

@implementation HTMPD
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary<NSString *, NSString *> *)a {
	if ([e isEqualToString:@"SegmentTemplate"]) _tmpl = a;
	else if ([e isEqualToString:@"S"] && _tmpl) _count += 1 + MAX(0, a[@"r"].integerValue);
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
	if ([e isEqualToString:@"SegmentTemplate"]) [p abortParsing];
}
@end

static NSArray<NSURL *> *HTDashParts(NSData *mpd) {
	HTMPD *m = [HTMPD new];
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

static void HTDownload(NSString *track, NSArray<NSURL *> *parts, void (^done)(NSURL *file)) {
	NSMutableArray *chunks = [NSMutableArray array];
	for (NSUInteger i = 0; i < parts.count; i++) [chunks addObject:NSNull.null];
	dispatch_group_t g = dispatch_group_create();
	for (NSUInteger i = 0; i < parts.count; i++) {
		dispatch_group_enter(g);
		[[HTSession() dataTaskWithURL:parts[i] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
			if (d && ((NSHTTPURLResponse *)r).statusCode == 200) @synchronized (chunks) { chunks[i] = d; }
			dispatch_group_leave(g);
		}] resume];
	}
	dispatch_group_notify(g, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSMutableData *all = [NSMutableData data];
		for (id c in chunks) {
			if (c == NSNull.null) {
				HTLog(@"%@: download failed (%lu parts)", track, (unsigned long)parts.count);
				return done(nil);
			}
			[all appendData:c];
		}
		NSString *ext = parts.count > 1 ? @"m4a" : parts[0].pathExtension.length ? parts[0].pathExtension : @"mp4";
		NSURL *dest = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:ext]]];
		done([all writeToURL:dest atomically:NO] ? dest : nil);
	});
}

static void HTFetch(NSString *track, void (^done)(NSURL *file)) {
	void (*token)(void (^)(NSString *)) = dlsym(RTLD_DEFAULT, "TTV1Token");
	if (!token) return done(nil);
	token(^(NSString *t) {
		if (!t) return done(nil);
		NSString *url = [NSString stringWithFormat:@"https://api.tidal.com/v1/tracks/%@/playbackinfo?audioquality=LOW&playbackmode=STREAM&assetpresentation=FULL", track];
		NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
		[req setValue:[@"Bearer " stringByAppendingString:t] forHTTPHeaderField:@"Authorization"];
		[[HTSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
			NSDictionary *info = HTAs(d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil, NSDictionary.class);
			NSString *b64 = HTAs(info[@"manifest"], NSString.class), *type = HTAs(info[@"manifestMimeType"], NSString.class);
			NSData *raw = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
			NSArray<NSURL *> *parts = nil;
			if ([type isEqualToString:@"application/dash+xml"] && raw) parts = HTDashParts(raw);
			else if ([type isEqualToString:@"application/vnd.tidal.bts"]) {
				NSDictionary *m = HTAs(raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil, NSDictionary.class);
				NSString *enc = HTAs(m[@"encryptionType"], NSString.class), *file = HTAs([HTAs(m[@"urls"], NSArray.class) firstObject], NSString.class);
				NSURL *src = file && (!enc || [enc isEqualToString:@"NONE"]) ? [NSURL URLWithString:file] : nil;
				if (src) parts = @[ src ];
			}
			if (!parts.count) {
				HTLog(@"%@: no plain audio (%ld %@ %@)", track, (long)((NSHTTPURLResponse *)r).statusCode, type, e.localizedDescription ?: @"");
				return done(nil);
			}
			HTDownload(track, parts, done);
		}] resume];
	});
}

static NSData *HTDecode(NSURL *file) {
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
	__block AVAssetTrack *track;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *e) {
		track = tracks.firstObject;
		dispatch_semaphore_signal(sem);
	}];
	dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
	if (!track) return nil;
	AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
	AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
		AVFormatIDKey: @(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsBigEndianKey: @NO,
		AVLinearPCMIsNonInterleaved: @NO, AVSampleRateKey: @(kRate), AVNumberOfChannelsKey: @1,
	}];
	if (!reader || ![reader canAddOutput:out]) return nil;
	[reader addOutput:out];
	if (![reader startReading]) return nil;
	NSMutableData *pcm = [NSMutableData data];
	CMSampleBufferRef sb;
	while ((sb = [out copyNextSampleBuffer])) {
		CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
		size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0, at = pcm.length;
		pcm.length += len;
		if (len) CMBlockBufferCopyDataBytes(bb, 0, len, (char *)pcm.mutableBytes + at);
		CFRelease(sb);
		if (pcm.length > 20 * 60 * kRate * sizeof(float)) {
			[reader cancelReading];
			break;
		}
	}
	if (reader.status == AVAssetReaderStatusFailed) HTLog(@"decode failed: %@", reader.error);
	return reader.status == AVAssetReaderStatusFailed ? nil : pcm;
}

static NSDictionary *HTAnalyzeFile(NSURL *file) {
	NSData *pcm = HTDecode(file);
	if (!pcm) return nil;
	HTResult r = HTAnalyze(pcm.bytes, pcm.length / sizeof(float), kRate);
	NSDictionary *d = @{ @"taps": [NSData dataWithBytes:r.taps length:r.count * sizeof(HTTap)], @"levels": [NSData dataWithBytes:r.levels length:r.slots * sizeof(float)], @"slot": @(r.slot) };
	free(r.taps);
	free(r.levels);
	return d;
}

static NSURL *HTCache(NSString *track) {
	NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"TidalHaptics"];
	[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return [dir URLByAppendingPathComponent:[track stringByAppendingString:@".2.plist"]];
}

static void HTUse(NSString *track, NSDictionary *d) {
	if (![track isEqualToString:gTrack]) return;
	gTaps = HTAs(d[@"taps"], NSData.class);
	gLevels = HTAs(d[@"levels"], NSData.class);
	gSlot = [d[@"slot"] doubleValue];
	gLoad = HTReady;
	NSUInteger on = 0, slots = gLevels.length / sizeof(float);
	for (NSUInteger i = 0; i < slots; i++) on += ((const float *)gLevels.bytes)[i] > 0.02f;
	HTLog(@"%@: %lu taps, rumble %lu%% of the song", track, (unsigned long)(gTaps.length / sizeof(HTTap)), (unsigned long)(slots ? on * 100 / slots : 0));
	gUntil = -1;
}

static void HTLoad(NSString *track) {
	gTrack = track;
	gTaps = gLevels = nil;
	gUntil = -1;
	NSDictionary *cached = [NSDictionary dictionaryWithContentsOfURL:HTCache(track)];
	if (cached) return HTUse(track, cached);
	gLoad = HTLoading;
	HTFetch(track, ^(NSURL *file) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
			NSDictionary *d = file ? HTAnalyzeFile(file) : nil;
			if (file) [NSFileManager.defaultManager removeItemAtURL:file error:nil];
			if (d) [d writeToURL:HTCache(track) error:nil];
			if (!d) HTLog(@"%@: no audio", track);
			dispatch_async(dispatch_get_main_queue(), ^{
				if (d) return HTUse(track, d);
				if (![track isEqualToString:gTrack]) return;
				gLoad = HTFailed;
				gFailedAt = CACurrentMediaTime();
			});
		});
	});
}

static BOOL HTEngine(void) {
	if (gEngine) return YES;
	if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics) return NO;
	NSError *e;
	CHHapticEngine *engine = [[CHHapticEngine alloc] initAndReturnError:&e];
	engine.playsHapticsOnly = YES;
	engine.autoShutdownEnabled = YES;
	engine.resetHandler = ^{
		dispatch_async(dispatch_get_main_queue(), ^{
			gRumble = nil;
			[gLive removeAllObjects];
			[gEngine startAndReturnError:nil];
		});
	};
	engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
		dispatch_async(dispatch_get_main_queue(), ^{
			gRumble = nil;
			[gLive removeAllObjects];
		});
	};
	if (![engine startAndReturnError:&e]) {
		HTLog(@"no haptic engine: %@", e);
		return NO;
	}
	gEngine = engine;
	return YES;
}

static BOOL HTPlay(id<CHHapticPatternPlayer> p) {
	return p && ([p startAtTime:CHHapticTimeImmediate error:nil] || ([gEngine startAndReturnError:nil] && [p startAtTime:CHHapticTimeImmediate error:nil]));
}

static CHHapticEventParameter *HTParam(CHHapticEventParameterID ident, float v) { return [[CHHapticEventParameter alloc] initWithParameterID:ident value:v]; }

static void HTRumble(NSArray<CHHapticParameterCurveControlPoint *> *points) {
	if ([[points valueForKeyPath:@"@max.value"] floatValue] < 0.02f) {
		[gRumble stopAtTime:CHHapticTimeImmediate error:nil];
		gRumble = nil;
		return;
	}
	if (!gRumble) {
		CHHapticEvent *e = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
		                                                 parameters:@[ HTParam(CHHapticEventParameterIDHapticIntensity, 1), HTParam(CHHapticEventParameterIDHapticSharpness, 0.1) ]
		                                               relativeTime:0
		                                                   duration:30];
		CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[ e ] parameters:@[] error:nil];
		id<CHHapticAdvancedPatternPlayer> p = pattern ? [gEngine createAdvancedPlayerWithPattern:pattern error:nil] : nil;
		p.loopEnabled = YES;
		if (!HTPlay(p)) return;
		gRumble = p;
	}
	static BOOL curvesFail;
	NSError *e;
	if (!curvesFail && points.count > 1) {
		CHHapticParameterCurve *curve = [[CHHapticParameterCurve alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl controlPoints:points relativeTime:0];
		if ([gRumble scheduleParameterCurve:curve atTime:CHHapticTimeImmediate error:&e]) return;
		curvesFail = YES;
		HTLog(@"rumble curve refused, sending levels instead: %@", e);
	}
	float level = points.count ? points[0].value : 0;
	if (![gRumble sendParameters:@[ [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level relativeTime:0] ] atTime:CHHapticTimeImmediate error:&e])
		HTLog(@"rumble level refused: %@", e);
}

static AVPlayer *HTPlayer(void) {
	for (AVPlayer *p in gPlayers)
		if (p.rate > 0 && !p.currentItem.presentationSize.width) return p;
	return nil;
}

static void HTStop(void) {
	if (gTimer) dispatch_source_cancel(gTimer);
	gTimer = nil;
	gUntil = -1;
	[gRumble stopAtTime:CHHapticTimeImmediate error:nil];
	gRumble = nil;
	for (id<CHHapticPatternPlayer> p in gLive) [p stopAtTime:CHHapticTimeImmediate error:nil];
	[gLive removeAllObjects];
}

static void HTTick(void) {
	AVPlayer *p = HTPlayer();
	if (!p || !HTOwn() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return HTStop();
	NSString *track = HTMatch(gInfo)[2];
	if ([track length] && (![track isEqualToString:gTrack] || (gLoad == HTFailed && CACurrentMediaTime() - gFailedAt > 30))) HTLoad(track);
	double now = CMTimeGetSeconds(p.currentTime) + kLead, rate = p.rate;
	if (!gTaps || ![track isEqualToString:gTrack] || p.timeControlStatus != AVPlayerTimeControlStatusPlaying || !isfinite(now)) {
		gUntil = -1;
		return HTRumble(nil);
	}
	const HTTap *taps = gTaps.bytes;
	NSUInteger count = gTaps.length / sizeof(HTTap);
	if (gUntil < 0 || now > gUntil || gUntil - now > 0.3)
		for (gNext = 0; gNext < count && taps[gNext].time < now; gNext++);
	double end = now + 0.15, k = [[NSUserDefaults.standardUserDefaults objectForKey:kStrengthKey] ?: @1 doubleValue];
	NSInteger follow = [NSUserDefaults.standardUserDefaults integerForKey:kFollowKey];
	NSMutableArray<CHHapticEvent *> *events = [NSMutableArray array];
	for (; gNext < count && taps[gNext].time < end; gNext++) {
		HTTap t = taps[gNext];
		if (follow == 2 && t.kind == HTSnare) continue;
		BOOL kick = t.kind == HTKick;
		[events addObject:[[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
		                                                parameters:@[ HTParam(CHHapticEventParameterIDHapticIntensity, fmin(1, t.strength * k * (kick ? 1 : 0.8))),
		                                                              HTParam(CHHapticEventParameterIDHapticSharpness, t.sharpness) ]
		                                              relativeTime:MAX(0, (t.time - now) / rate)]];
	}
	gUntil = end;
	if (events.count) {
		CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:events parameters:@[] error:nil];
		id<CHHapticPatternPlayer> player = pattern ? [gEngine createPlayerWithPattern:pattern error:nil] : nil;
		if (HTPlay(player)) [gLive addObject:player];
		if (gLive.count > 8) [gLive removeObjectAtIndex:0];
	}
	NSMutableArray<CHHapticParameterCurveControlPoint *> *curve = [NSMutableArray array];
	const float *levels = gLevels.bytes;
	NSUInteger slots = gLevels.length / sizeof(float);
	if (follow != 1 && gSlot > 0 && now >= 0)
		for (NSUInteger i = (NSUInteger)(now / gSlot), first = i; curve.count < 16 && (i == first || i * gSlot < end + gSlot); i++)
			[curve addObject:[[CHHapticParameterCurveControlPoint alloc] initWithRelativeTime:i == first ? 0 : (i * gSlot - now) / rate
			                                                                            value:i < slots ? fmin(1, levels[i] * k * 0.6) : 0]];
	HTRumble(curve);
}

static void HTWake(void) {
	if (gTimer || !HTOwn() || !HTPlayer() || UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !HTEngine()) return;
	AVAudioSession *session = AVAudioSession.sharedInstance;
	HTLog(@"playing along: %@, output latency %.0f ms", session.currentRoute.outputs.firstObject.portType, session.outputLatency * 1000);
	gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 20, NSEC_PER_MSEC * 5);
	dispatch_source_set_event_handler(gTimer, ^{ HTTick(); });
	dispatch_resume(gTimer);
}

#pragma mark - Switch in TIDAL's Settings

static void HTApply(void) {
	HTWake();
	if (!gInfo || !kISRCKey) return;
	if (HTOn() && HTApple()) return HTLearn(@[]);
	if (!gInfo[kISRCKey]) return;
	NSMutableDictionary *d = [gInfo mutableCopy];
	[d removeObjectForKey:kISRCKey];
	HTResend(d);
}

static void HTSetOn(BOOL on) {
	[NSUserDefaults.standardUserDefaults setBool:on forKey:kOnKey];
	HTLog(@"switched %@", on ? @"on" : @"off");
	HTApply();
}

static NSString *HTAppleStatus(void) {
	if (!kISRCKey) return HTL(@"Needs iOS 18", @"iOS 18 이상 필요");
	if (!HTSystemOn()) return HTL(@"Off in iOS: Settings > Accessibility > Music Haptics", @"iOS에서 꺼짐: 설정 > 손쉬운 사용 > 음악 햅틱");
	if (!HTOn()) return nil;
	if (!gInfo) return HTL(@"Nothing playing", @"재생 중인 곡 없음");
	if (!gInfo[kISRCKey]) return HTL(@"This song: not identified (no ISRC)", @"이 곡: 식별 못 함 (ISRC 없음)");
	if (!gAvailable) return HTL(@"This song: checking…", @"이 곡: 확인 중…");
	return gAvailable.boolValue ? HTL(@"This song: haptics available", @"이 곡: 햅틱 있음")
	                            : HTL(@"This song: Apple has no haptics for it", @"이 곡: Apple 햅틱 없음");
}

static NSString *HTOwnStatus(void) {
	NSString *(*user)(void) = dlsym(RTLD_DEFAULT, "TTV1User");
	if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics) return HTL(@"This iPhone can't play haptics.", @"이 iPhone은 햅틱을 지원하지 않아요.");
	if (!user || !user()) return HTL(@"Needs the secondary login to get the song's audio.", @"곡 오디오를 받으려면 보조 로그인이 필요해요.");
	if (!HTOn()) return nil;
	NSString *track = HTMatch(gInfo)[2];
	NSString *now = !gInfo ? HTL(@"Nothing playing", @"재생 중인 곡 없음")
	                : ![track length] ? HTL(@"This song: not identified", @"이 곡: 식별 못 함")
	                : ![track isEqualToString:gTrack] ? HTL(@"This song: analysed when it plays", @"이 곡: 재생하면 분석해요")
	                : gLoad == HTLoading ? HTL(@"This song: analysing…", @"이 곡: 분석 중…")
	                : gLoad == HTFailed ? HTL(@"This song: couldn't get its audio", @"이 곡: 오디오를 못 받았어요")
	                : [NSString stringWithFormat:HTL(@"This song: %lu taps", @"이 곡: 탭 %lu개"), (unsigned long)(gTaps.length / sizeof(HTTap))];
	return [now stringByAppendingString:HTL(@"\nPlays while TIDAL is on screen.", @"\nTIDAL 화면이 켜져 있을 때만 울려요.")];
}

static NSString *HTStatus(void) {
	if (HTHasCore()) return HTApple() ? HTAppleStatus() : HTOwnStatus();
	NSString *note = HTL(@"Song analysis needs TidalCore; using Apple haptic tracks.", @"곡 분석은 TidalCore가 필요해서 Apple 햅틱 트랙으로 동작해요.");
	NSString *status = HTAppleStatus();
	return status ? [NSString stringWithFormat:@"%@\n%@", status, note] : note;
}

static UIMenu *HTMenu(void) {
	UIAction *toggle = [UIAction actionWithTitle:HTL(@"Music Haptics", @"음악 햅틱") image:nil identifier:nil handler:^(UIAction *a) { HTSetOn(!HTOn()); }];
	toggle.state = HTOn() ? UIMenuElementStateOn : UIMenuElementStateOff;
	toggle.subtitle = HTStatus();
	return [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ toggle ]];
}

static void HTAddSettingsEntry(UIViewController *vc) {
	UINavigationItem *ni = vc.navigationItem;
	for (UIBarButtonItem *i in ni.rightBarButtonItems)
		if ([i.accessibilityIdentifier isEqualToString:@"ht.settings"]) return;
	UIDeferredMenuElement *fresh = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^done)(NSArray<UIMenuElement *> *)) { done(@[ HTMenu() ]); }];
	UIBarButtonItem *b = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"iphone.radiowaves.left.and.right"] menu:[UIMenu menuWithChildren:@[ fresh ]]];
	b.accessibilityIdentifier = @"ht.settings";
	b.accessibilityLabel = HTL(@"Music Haptics", @"음악 햅틱");
	ni.rightBarButtonItems = [ni.rightBarButtonItems ?: @[] arrayByAddingObject:b];
	if (vc.navigationController && !vc.navigationController.navigationBarHidden) return;

	dispatch_async(dispatch_get_main_queue(), ^{
		UITableView *table = nil;
		NSMutableArray<UIView *> *todo = [NSMutableArray arrayWithObject:vc.viewIfLoaded ?: [UIView new]];
		while (todo.count && !table) {
			UIView *v = todo.firstObject;
			[todo removeObjectAtIndex:0];
			if ([v isKindOfClass:UITableView.class]) table = (UITableView *)v;
			else [todo addObjectsFromArray:v.subviews];
		}
		if (!table || table.tableHeaderView) return;
		UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, 60)];
		header.accessibilityIdentifier = @"ht.settings";
		UILabel *label = [UILabel new];
		label.text = HTL(@"Music Haptics", @"음악 햅틱");
		label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
		label.frame = CGRectMake(20, 10, header.bounds.size.width - 110, 40);
		label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
		UISwitch *sw = [UISwitch new];
		sw.on = HTOn();
		sw.frame = CGRectMake(header.bounds.size.width - 20 - sw.bounds.size.width, (60 - sw.bounds.size.height) / 2, sw.bounds.size.width, sw.bounds.size.height);
		sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
		[sw addAction:[UIAction actionWithHandler:^(UIAction *a) { HTSetOn(((UISwitch *)a.sender).on); }] forControlEvents:UIControlEventValueChanged];
		[header addSubview:label];
		[header addSubview:sw];
		table.tableHeaderView = header;
	});
}

@interface HTSettings : NSObject
@end
@implementation HTSettings
+ (NSArray *)ttSections {
	BOOL (^own)(void) = ^BOOL { return !HTApple(); };
	NSString *(*user)(void) = dlsym(RTLD_DEFAULT, "TTV1User");
	void (*login)(void) = dlsym(RTLD_DEFAULT, "TTV1Login");
	return @[ @{ @"items": @[
		@{ @"type": @"switch", @"key": kOnKey, @"default": @NO, @"title": HTL(@"Music Haptics", @"음악 햅틱"), @"set": ^(id v) { HTSetOn([v boolValue]); } },
		@{ @"type": @"choice", @"key": kAppleKey, @"default": @NO, @"title": HTL(@"Source", @"방식"),
		   @"options": @[ @[ @NO, HTL(@"Song Analysis", @"곡 분석") ], @[ @YES, HTL(@"Apple Haptic Tracks", @"Apple 햅틱 트랙") ] ], @"set": ^(id v) { HTApply(); } },
		@{ @"type": @"choice", @"key": kFollowKey, @"default": @0, @"title": HTL(@"Follows", @"따라갈 소리"), @"visible": own,
		   @"options": @[ @[ @0, HTL(@"Everything", @"전부") ], @[ @1, HTL(@"Beat", @"비트") ], @[ @2, HTL(@"Bass", @"베이스") ] ] },
		@{ @"type": @"choice", @"key": kStrengthKey, @"default": @1, @"title": HTL(@"Strength", @"세기"), @"visible": own,
		   @"options": @[ @[ @0.5, @"50%" ], @[ @1, @"100%" ], @[ @1.5, @"150%" ], @[ @2, @"200%" ] ] },
		@{ @"type": @"action", @"title": HTL(@"Secondary Login", @"보조 로그인"), @"set": ^{ if (login) login(); },
		   @"visible": ^BOOL { return own() && login && user && !user(); } },
	],
	             @"footer": ^NSString * { return HTStatus(); } } ];
}
@end

static void (*orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void hook_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewDidAppear(self, _cmd, animated);
	if ([self isKindOfClass:objc_getClass("_TtC4WiMP13SettingsScene")] && !NSClassFromString(@"TTCore")) HTAddSettingsEntry(self);
}

__attribute__((constructor)) static void HTInit(void) {
	if (NSClassFromString(@"TTCore") && ![NSUserDefaults.standardUserDefaults boolForKey:@"tt.TidalHaptics.enabled"]) return HTLog(@"turned off in TidalCore's settings");
	NSString *const *k = (NSString *const *)dlsym(RTLD_DEFAULT, "MPNowPlayingInfoPropertyInternationalStandardRecordingCode");
	kISRCKey = k ? *k : nil;
	gByTitle = [NSMutableDictionary dictionary];
	gAsked = [NSMutableSet set];
	gPlayers = [NSHashTable weakObjectsHashTable];
	gLive = [NSMutableArray array];
	[NSNotificationCenter.defaultCenter addObserverForName:AVPlayerRateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		AVPlayer *p = HTAs(n.object, AVPlayer.class);
		if (p) [gPlayers addObject:p];
		HTWake();
	}];
	[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { HTWake(); }];

	Method set = class_getInstanceMethod(MPNowPlayingInfoCenter.class, @selector(setNowPlayingInfo:));
	if (!set) return HTLog(@"setNowPlayingInfo: missing, off");
	orig_setInfo = (void *)method_setImplementation(set, (IMP)hook_setInfo);

	Class s = NSClassFromString(@"__NSURLSessionLocal") ?: NSURLSession.class;
	SEL sel = @selector(dataTaskWithRequest:completionHandler:);
	Method m = class_getInstanceMethod(s, sel);
	if (m && class_addMethod(s, sel, (IMP)hook_dataTask, method_getTypeEncoding(m))) orig_dataTask = (void *)method_getImplementation(m);
	else if (m) orig_dataTask = (void *)method_setImplementation(m, (IMP)hook_dataTask);

	Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
	orig_viewDidAppear = (void *)method_setImplementation(appear, (IMP)hook_viewDidAppear);

	HTLog(@"loaded, switch %@; Info.plist MusicHapticsSupported = %@", HTOn() ? @"on" : @"off", [NSBundle.mainBundle objectForInfoDictionaryKey:@"MusicHapticsSupported"]);
}
