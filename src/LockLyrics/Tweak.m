// Hook order matters: RL and TidalMeanings also hook setNowPlayingInfo: and read title/artist from it. This
// dylib must hook first, so theirs wrap ours and see the untouched info, and our re-sends go straight to
// MediaPlayer. If something hooked before us, the feature turns itself off (see LLInit).
#import "LL.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static const NSTimeInterval kTick = 0.25;
static const double kBreak = 4;
static const NSUInteger kMaxChars = 30;

@interface LLLine : NSObject
@property (nonatomic) double start, end;
@property (nonatomic, copy) NSArray<NSString *> *words;
@property (nonatomic, copy) NSArray<NSNumber *> *starts;
@end
@implementation LLLine
@end

static void (*orig_setInfo)(MPNowPlayingInfoCenter *, SEL, NSDictionary *);
static NSDictionary *(*orig_getInfo)(MPNowPlayingInfoCenter *, SEL);

static NSObject *gLock;
static NSDictionary *gInfo;
static double gAt;
static NSString *gShown;
static NSTimer *gTimer;

#pragma mark - Lyrics

static NSArray<LLLine *> *LLFromRL(NSString *title) {
	static __weak NSArray *seen;
	static NSArray<LLLine *> *converted;
	Class c = NSClassFromString(@"RLStore");
	if (!c || ![c respondsToSelector:@selector(shared)]) return @[];
	id store = [c performSelector:@selector(shared)];
	if (![[store valueForKey:@"title"] isEqual:title]) return nil;
	NSInteger status = [[store valueForKey:@"status"] integerValue];
	if (status == 1) return nil;
	NSArray *lines = status == 2 ? [store valueForKey:@"lines"] : nil;
	if (!lines.count) return @[];
	if (lines == seen) return converted;

	NSMutableArray<LLLine *> *out = [NSMutableArray array];
	for (id l in lines) {
		LLLine *line = [LLLine new];
		line.start = [[l valueForKey:@"start"] doubleValue];
		line.end = [[l valueForKey:@"end"] doubleValue];
		NSMutableArray *words = [NSMutableArray array], *starts = [NSMutableArray array];
		NSMutableString *word = nil;
		for (id syl in [l valueForKey:@"main"]) {
			NSString *text = [syl valueForKey:@"text"];
			if (!word) {
				word = [NSMutableString string];
				[starts addObject:[syl valueForKey:@"start"]];
			}
			[word appendString:text ?: @""];
			if ([text hasSuffix:@" "]) {
				[words addObject:word];
				word = nil;
			}
		}
		if (word) [words addObject:word];
		line.words = words;
		line.starts = starts;
		[out addObject:line];
	}
	seen = lines;
	converted = out;
	return out;
}

static NSArray<LLLine *> *LLParseLRC(NSString *lrc) {
	NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+):(\\d+(?:\\.\\d+)?)\\](.*)$" options:NSRegularExpressionAnchorsMatchLines error:nil];
	NSMutableArray<LLLine *> *lines = [NSMutableArray array];
	for (NSTextCheckingResult *m in [re matchesInString:lrc options:0 range:NSMakeRange(0, lrc.length)]) {
		LLLine *line = [LLLine new];
		line.start = [[lrc substringWithRange:[m rangeAtIndex:1]] doubleValue] * 60 + [[lrc substringWithRange:[m rangeAtIndex:2]] doubleValue];
		NSString *text = [[lrc substringWithRange:[m rangeAtIndex:3]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		NSMutableArray *words = [NSMutableArray array];
		for (NSString *w in [text componentsSeparatedByString:@" "])
			if (w.length) [words addObject:[w stringByAppendingString:@" "]];
		line.words = words;
		[lines.lastObject setEnd:line.start];
		[lines addObject:line];
	}
	LLLine *last = lines.lastObject;
	last.end = last.start + 5;
	for (LLLine *line in lines) {
		NSUInteger total = 0, at = 0;
		for (NSString *w in line.words) total += w.length;
		NSMutableArray *starts = [NSMutableArray array];
		for (NSString *w in line.words) {
			[starts addObject:@(line.start + (line.end - line.start) * at / MAX(total, 1))];
			at += w.length;
		}
		line.starts = starts;
	}
	return lines;
}

static NSArray<LLLine *> *LLFromLRCLIB(NSString *title, NSString *artist, double duration) {
	static NSMutableDictionary<NSString *, NSArray *> *cache;
	if (!cache) cache = [NSMutableDictionary dictionary];
	NSString *key = [NSString stringWithFormat:@"%@\n%@", title, artist];
	if (cache[key]) return [cache[key].firstObject isKindOfClass:LLLine.class] ? cache[key] : nil;
	cache[key] = @[ @"pending" ];
	artist = [artist componentsSeparatedByString:@", "].firstObject;

	NSURLComponents *u = [NSURLComponents componentsWithString:@"https://lrclib.net/api/search"];
	u.queryItems = @[ [NSURLQueryItem queryItemWithName:@"track_name" value:title], [NSURLQueryItem queryItemWithName:@"artist_name" value:artist] ];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u.URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:15];
	[req setValue:@"TidalLockLyrics (TIDAL iOS tweak)" forHTTPHeaderField:@"User-Agent"];
	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
		NSArray *results = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
		NSString *best = nil;
		double bestOff = 1e9;
		if ([results isKindOfClass:NSArray.class]) {
			for (NSDictionary *r in results) {
				if (![r isKindOfClass:NSDictionary.class] || ![r[@"syncedLyrics"] isKindOfClass:NSString.class]) continue;
				double off = duration > 0 ? fabs([r[@"duration"] doubleValue] - duration) : 0;
				if (off < bestOff) { bestOff = off; best = r[@"syncedLyrics"]; }
			}
		}
		if (bestOff > 5) best = nil;
		NSArray *lines = best ? LLParseLRC(best) : @[];
		dispatch_async(dispatch_get_main_queue(), ^{
			cache[key] = lines;
			LLLog(@"LRCLIB %lu lines for %@ — %@%@", (unsigned long)lines.count, title, artist, err ? [@" " stringByAppendingString:err.localizedDescription] : @"");
		});
	}] resume];
	return nil;
}

static NSURLSessionDataTask *(*orig_dataTask)(NSURLSession *, SEL, NSURLRequest *, id);
NSMutableDictionary<NSString *, NSArray<NSString *> *> *gTidalTitles;
static NSMutableDictionary<NSString *, NSString *> *gTidalLRC;
static NSMutableDictionary<NSString *, NSArray<LLLine *> *> *gTidalParsed;
static NSMutableSet<NSString *> *gTidalAsked;
NSURLRequest *gTidalReq;
static NSURLSession *gTidalSession;

static NSArray<NSDictionary *> *LLReadTidal(NSURL *url, NSData *data) {
	NSDictionary *json = LLAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class);
	if (!json) return nil;
	NSMutableArray *objs = [NSMutableArray array];
	id d = json[@"data"];
	if (LLAs(d, NSDictionary.class)) [objs addObject:d];
	if (LLAs(d, NSArray.class)) [objs addObjectsFromArray:d];
	[objs addObjectsFromArray:LLAs(json[@"included"], NSArray.class) ?: @[]];

	NSMutableDictionary *titles = [NSMutableDictionary dictionary], *lrcs = [NSMutableDictionary dictionary], *lyricsById = [NSMutableDictionary dictionary];
	for (NSDictionary *o in objs) {
		NSDictionary *a = LLAs(LLAs(o, NSDictionary.class)[@"attributes"], NSDictionary.class);
		NSString *oid = LLAs(o[@"id"], NSString.class);
		if (!oid) continue;
		if ([o[@"type"] isEqual:@"lyrics"]) lyricsById[oid] = LLAs(a[@"lrcText"], NSString.class) ?: @"";
		NSString *title = LLAs(a[@"title"], NSString.class), *version = LLAs(a[@"version"], NSString.class);
		if ([o[@"type"] isEqual:@"tracks"] && title) titles[oid] = @[ title, version.length ? [NSString stringWithFormat:@"%@ (%@)", title, version] : title ];
	}
	for (NSDictionary *o in objs) {
		if (![LLAs(o, NSDictionary.class)[@"type"] isEqual:@"tracks"] || !LLAs(o[@"id"], NSString.class)) continue;
		NSArray *rel = LLAs(LLAs(LLAs(o[@"relationships"], NSDictionary.class)[@"lyrics"], NSDictionary.class)[@"data"], NSArray.class);
		if (!rel) continue;
		NSString *lid = LLAs(LLAs(rel.firstObject, NSDictionary.class)[@"id"], NSString.class);
		lrcs[o[@"id"]] = (lid ? lyricsById[lid] : nil) ?: @"";
	}
	NSArray<NSString *> *p = url.pathComponents;
	NSUInteger n = p.count;
	if (n >= 4 && [p[n - 1] isEqualToString:@"lyrics"] && [p[n - 2] isEqualToString:@"relationships"] && [p[n - 4] isEqualToString:@"tracks"])
		lrcs[p[n - 3]] = [lyricsById.allValues.firstObject length] ? lyricsById.allValues.firstObject : @"";
	return @[ titles, lrcs ];
}

NSMutableURLRequest *LLTidalRequest(NSString *path, NSArray<NSURLQueryItem *> *query) {
	NSURLComponents *c = [NSURLComponents componentsWithURL:gTidalReq.URL resolvingAgainstBaseURL:NO];
	NSMutableArray *q = [query mutableCopy];
	for (NSURLQueryItem *i in c.queryItems)
		if ([i.name isEqualToString:@"countryCode"]) [q addObject:i];
	c.path = path;
	c.queryItems = q;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL];
	req.allHTTPHeaderFields = gTidalReq.allHTTPHeaderFields;
	return req;
}

static void LLAskTitle(NSString *tid) {
	if (!gTidalReq || [gTidalAsked containsObject:[@"t" stringByAppendingString:tid]]) return;
	[gTidalAsked addObject:[@"t" stringByAppendingString:tid]];
	[[gTidalSession ?: NSURLSession.sharedSession dataTaskWithRequest:LLTidalRequest([@"/v2/tracks/" stringByAppendingString:tid], @[]) completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {}] resume];
}

static void LLNoteTidal(NSArray<NSDictionary *> *found) {
	[gTidalTitles addEntriesFromDictionary:found[0]];
	[found[1] enumerateKeysAndObjectsUsingBlock:^(NSString *tid, NSString *lrc, BOOL *stop) {
		if (gTidalLRC[tid].length && !lrc.length) return; // RL's stand-in or a later empty reply doesn't erase real lyrics
		gTidalLRC[tid] = lrc;
		[gTidalParsed removeObjectForKey:tid];
		if (lrc.length && !gTidalTitles[tid]) LLAskTitle(tid);
	}];
}

static void LLAskTidal(NSString *tid) {
	if (!gTidalReq || [gTidalAsked containsObject:tid]) return;
	[gTidalAsked addObject:tid];
	NSMutableURLRequest *req = LLTidalRequest([NSString stringWithFormat:@"/v2/tracks/%@/relationships/lyrics", tid], @[ [NSURLQueryItem queryItemWithName:@"include" value:@"lyrics"] ]);
	[[gTidalSession ?: NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!gTidalLRC[tid]) gTidalLRC[tid] = @"";
			LLLog(@"TIDAL lyrics for %@: %@", tid, gTidalLRC[tid].length ? @"found" : err.localizedDescription ?: @"none");
		});
	}] resume];
}

static NSURLSessionDataTask *hook_dataTask(NSURLSession *self, SEL _cmd, NSURLRequest *req, void (^done)(NSData *, NSURLResponse *, NSError *)) {
	NSURL *url = req.URL;
	if (!done || ![url.host hasSuffix:@"openapi.tidal.com"]) return orig_dataTask(self, _cmd, req, done);
	if ([req valueForHTTPHeaderField:@"Authorization"]) {
		NSURLRequest *r = [req copy];
		dispatch_async(dispatch_get_main_queue(), ^{
			gTidalReq = r;
			gTidalSession = self;
		});
	}
	return orig_dataTask(self, _cmd, req, ^(NSData *data, NSURLResponse *resp, NSError *err) {
		if (data && [resp isKindOfClass:NSHTTPURLResponse.class] && ((NSHTTPURLResponse *)resp).statusCode == 200) {
			NSArray *found = LLReadTidal(url, data);
			if (found) dispatch_async(dispatch_get_main_queue(), ^{ LLNoteTidal(found); });
		}
		done(data, resp, err);
	});
}

static NSArray<LLLine *> *LLFromTidal(NSString *title) {
	BOOL asking = NO;
	// ponytail: matched by title alone; two tracks with one title take the first with lyrics
	for (NSString *tid in gTidalTitles) {
		if (![gTidalTitles[tid] containsObject:title]) continue;
		NSString *lrc = gTidalLRC[tid];
		if (lrc.length) {
			if (!gTidalParsed[tid]) gTidalParsed[tid] = LLParseLRC(lrc);
			if (gTidalParsed[tid].count) return gTidalParsed[tid];
		} else if (!lrc) {
			LLAskTidal(tid);
			asking = asking || gTidalReq;
		}
	}
	return asking ? nil : @[];
}

static NSArray<LLLine *> *LLLines(NSDictionary *info) {
	NSString *title = info[MPMediaItemPropertyTitle], *artist = info[MPMediaItemPropertyArtist];
	if (!title.length || !artist.length) return nil;
	NSArray *rl = LLFromRL(title);
	if (!rl || rl.count) return rl;
	NSArray *tidal = LLFromTidal(title);
	if (!tidal || tidal.count) return tidal;
	return LLFromLRCLIB(title, artist, [info[MPMediaItemPropertyPlaybackDuration] doubleValue]);
}

#pragma mark - The line

static NSString *LLJoin(NSArray<NSString *> *words) {
	return [[words componentsJoinedByString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSString *LLPiece(LLLine *line, double t) {
	NSUInteger length = LLJoin(line.words).length;
	NSUInteger count = MAX((length + kMaxChars - 1) / kMaxChars, 1);
	NSUInteger target = (length + count - 1) / count;
	NSString *shown = nil;
	NSMutableArray *piece = [NSMutableArray array];
	NSUInteger pieceLen = 0, pieces = 0;
	for (NSUInteger i = 0; i <= line.words.count; i++) {
		NSString *w = i < line.words.count ? line.words[i] : nil;
		BOOL cut = !w || (pieceLen && (pieceLen + w.length > kMaxChars + 1 || (pieceLen >= target && pieces + 1 < count)));
		if (cut && piece.count) {
			if (!shown || [line.starts[i - piece.count] doubleValue] <= t) shown = LLJoin(piece);
			[piece removeAllObjects];
			pieceLen = 0;
			pieces++;
		}
		if (w) {
			[piece addObject:w];
			pieceLen += w.length;
		}
	}
	return shown.length ? shown : nil;
}

static double LLElapsed(NSDictionary *info, double at, double now) {
	return [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] + [info[MPNowPlayingInfoPropertyPlaybackRate] doubleValue] * (now - at);
}

static NSString *LLLineAt(NSDictionary *info, double t) {
	if (!LLOn(@"lyrics")) return nil;
	NSArray<LLLine *> *lines = LLLines(info);
	NSInteger i = -1;
	for (NSInteger j = 0; j < (NSInteger)lines.count && lines[j].start <= t; j++) i = j;
	if (i < 0) return nil;
	LLLine *line = lines[i];
	BOOL nextFar = i + 1 == (NSInteger)lines.count || lines[i + 1].start - t > kBreak;
	if (t > line.end + kBreak && nextFar) return nil;
	return LLPiece(line, t);
}

static NSDictionary *LLOut(NSDictionary *info, NSString *line, NSDictionary *art, double t) {
	if (!line && !art) return info;
	NSMutableDictionary *d = [info mutableCopy];
	if (line) {
		d[MPMediaItemPropertyArtist] = line;
		d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(t);
	}
	[d addEntriesFromDictionary:art];
	return d;
}

#pragma mark - Hooks

static __weak NSDictionary *gShownArt;

void LLSend(BOOL force) {
	NSDictionary *info;
	double at;
	@synchronized (gLock) {
		info = gInfo;
		at = gAt;
	}
	if (!info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) return;
	double t = LLElapsed(info, at, CACurrentMediaTime());
	NSString *line = LLLineAt(info, t);
	NSDictionary *art = LLArtFor(info);
	if (!force && art == gShownArt && (line == gShown || [line isEqualToString:gShown])) return;
	gShown = line;
	gShownArt = art;
	// straight to MediaPlayer: RL/Meanings wrap us and must not see the line as the artist
	orig_setInfo(MPNowPlayingInfoCenter.defaultCenter, @selector(setNowPlayingInfo:), LLOut(info, line, art, t));
}

static void LLTick(void) { LLSend(NO); }

static void LLSetTicking(BOOL on) {
	if (on == (gTimer != nil)) return;
	[gTimer invalidate];
	gTimer = nil;
	if (!on) return;
	gTimer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *t) { LLTick(); }];
	[NSRunLoop.mainRunLoop addTimer:gTimer forMode:NSRunLoopCommonModes];
}

static void hook_setInfo(MPNowPlayingInfoCenter *self, SEL _cmd, NSDictionary *info) {
	double now = CACurrentMediaTime();
	@synchronized (gLock) {
		gInfo = [info copy];
		gAt = now;
	}
	NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
	BOOL playing = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] && (!rate || rate.doubleValue > 0);
	if (!NSThread.isMainThread || !info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			gShown = nil;
			gShownArt = nil;
			LLSetTicking(playing);
			LLTick();
		});
		orig_setInfo(self, _cmd, info);
		return;
	}
	LLSetTicking(playing);
	double t = LLElapsed(info, now, now);
	gShown = LLLineAt(info, t);
	gShownArt = LLArtFor(info);
	orig_setInfo(self, _cmd, LLOut(info, gShown, gShownArt, t));
}

static NSDictionary *hook_getInfo(MPNowPlayingInfoCenter *self, SEL _cmd) {
	@synchronized (gLock) {
		if (gInfo) return gInfo;
	}
	return orig_getInfo(self, _cmd);
}

__attribute__((constructor)) static void LLInit(void) {
	id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"tt.TidalLockLyrics.enabled"];
	if (enabled && ![enabled boolValue] && NSClassFromString(@"TTCore")) return LLLog(@"turned off in TidalCore's settings");
	gLock = [NSObject new];
	Class c = MPNowPlayingInfoCenter.class;
	Method set = class_getInstanceMethod(c, @selector(setNowPlayingInfo:));
	Method get = class_getInstanceMethod(c, @selector(nowPlayingInfo));
	if (!set || !get) return LLLog(@"MPNowPlayingInfoCenter methods missing, off");

	// Someone hooked the setter before us: they'd see the line as the artist (RL would refetch lyrics for it)
	Dl_info dl;
	if (!dladdr((void *)method_getImplementation(set), &dl) || !strstr(dl.dli_fname, "MediaPlayer"))
		return LLLog(@"setNowPlayingInfo: already hooked by %s — inject TidalLockLyrics before other tweaks. Off.", dl.dli_fname ?: "?");

	orig_setInfo = (void *)method_setImplementation(set, (IMP)hook_setInfo);
	orig_getInfo = (void *)method_setImplementation(get, (IMP)hook_getInfo);

	gTidalTitles = [NSMutableDictionary dictionary];
	gTidalLRC = [NSMutableDictionary dictionary];
	gTidalParsed = [NSMutableDictionary dictionary];
	gTidalAsked = [NSMutableSet set];
	Class s = NSClassFromString(@"__NSURLSessionLocal") ?: NSURLSession.class;
	SEL sel = @selector(dataTaskWithRequest:completionHandler:);
	Method m = class_getInstanceMethod(s, sel);
	if (m && class_addMethod(s, sel, (IMP)hook_dataTask, method_getTypeEncoding(m))) orig_dataTask = (void *)method_getImplementation(m);
	else if (m) orig_dataTask = (void *)method_setImplementation(m, (IMP)hook_dataTask);
	LLSettingsInit();
	LLLog(@"loaded");
}
