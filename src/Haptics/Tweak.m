// Load after TidalLockLyrics (it must hook setNowPlayingInfo: first); before or after RL/Meanings is fine.
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>

#define HTLog(fmt, ...) NSLog(@"[TidalHaptics] " fmt, ##__VA_ARGS__)

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

static BOOL HTOn(void) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:kOnKey];
	return [v boolValue];
}

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
	NSString *isrc = HTAs(d[@"isrc"], NSString.class), *title = HTAs(d[@"title"], NSString.class);
	if (isrc.length && title.length) {
		NSNumber *dur = @(HTDuration(d[@"duration"]));
		[out addObject:@[ title, isrc, dur ]];
		NSString *version = HTAs(d[@"version"], NSString.class);
		if (version.length) [out addObject:@[ [NSString stringWithFormat:@"%@ (%@)", title, version], isrc, dur ]];
	}
	for (id x in d.allValues) HTWalk(x, out, depth + 1);
}

#pragma mark - Now playing

static NSString *HTISRC(NSDictionary *info) {
	NSString *title = HTAs(info[MPMediaItemPropertyTitle], NSString.class);
	if (!title.length) return nil;
	double dur = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
	NSString *best = nil;
	double bestOff = 3;
	for (NSArray *e in gByTitle[HTKey(title)]) {
		double d = [e[1] doubleValue];
		if (!dur || !d) {
			if (!best) best = e[0];
			continue;
		}
		if (fabs(d - dur) <= bestOff) {
			bestOff = fabs(d - dur);
			best = e[0];
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
	if (!kISRCKey || info[kISRCKey] || !HTOn()) return info;
	NSString *isrc = HTISRC(info);
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
		NSArray *e = @[ f[1], f[2] ];
		if (![list containsObject:e]) [list addObject:e];
	}
	if (!gInfo || gInfo[kISRCKey]) return;
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
	for (NSUInteger i = 0; i + 2 < p.count; i++)
		if ([p[i] isEqualToString:@"tracks"] && [p[i + 2] hasPrefix:@"playbackinfo"]) return p[i + 1];
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

#pragma mark - Switch in TIDAL's Settings

static void HTSetOn(BOOL on) {
	[NSUserDefaults.standardUserDefaults setBool:on forKey:kOnKey];
	HTLog(@"switched %@", on ? @"on" : @"off");
	if (!gInfo) return;
	if (on) return HTLearn(@[]);
	if (!gInfo[kISRCKey]) return;
	NSMutableDictionary *d = [gInfo mutableCopy];
	[d removeObjectForKey:kISRCKey];
	HTResend(d);
}

static NSString *HTStatus(void) {
	if (!kISRCKey) return HTL(@"Needs iOS 18", @"iOS 18 이상 필요");
	if (!HTSystemOn()) return HTL(@"Off in iOS: Settings > Accessibility > Music Haptics", @"iOS에서 꺼짐: 설정 > 손쉬운 사용 > 음악 햅틱");
	if (!HTOn()) return nil;
	if (!gInfo) return HTL(@"Nothing playing", @"재생 중인 곡 없음");
	if (!gInfo[kISRCKey]) return HTL(@"This song: not identified (no ISRC)", @"이 곡: 식별 못 함 (ISRC 없음)");
	if (!gAvailable) return HTL(@"This song: checking…", @"이 곡: 확인 중…");
	return gAvailable.boolValue ? HTL(@"This song: haptics available", @"이 곡: 햅틱 있음")
	                            : HTL(@"This song: Apple has no haptics for it", @"이 곡: Apple 햅틱 없음");
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
	return @[ @{ @"items": @[ @{ @"type": @"switch", @"key": kOnKey, @"default": @NO, @"title": HTL(@"Music Haptics", @"음악 햅틱"),
	                           @"set": ^(id v) { HTSetOn([v boolValue]); } } ],
	             @"footer": ^NSString * { return HTStatus(); } } ];
}
@end

static void (*orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void hook_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewDidAppear(self, _cmd, animated);
	if ([self isKindOfClass:objc_getClass("_TtC4WiMP13SettingsScene")] && !NSClassFromString(@"TTCore")) HTAddSettingsEntry(self);
}

__attribute__((constructor)) static void HTInit(void) {
	id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"tt.TidalHaptics.enabled"];
	if (enabled && ![enabled boolValue] && NSClassFromString(@"TTCore")) return HTLog(@"turned off in TidalCore's settings");
	NSString *const *k = (NSString *const *)dlsym(RTLD_DEFAULT, "MPNowPlayingInfoPropertyInternationalStandardRecordingCode");
	if (!k) return HTLog(@"no ISRC now playing key (needs iOS 18), off");
	kISRCKey = *k;
	gByTitle = [NSMutableDictionary dictionary];
	gAsked = [NSMutableSet set];

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
