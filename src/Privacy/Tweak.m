#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdatomic.h>

#define PVLog(fmt, ...) NSLog(@"[TidalPrivacy] " fmt, ##__VA_ARGS__)

static NSString *PVL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}

enum { PVDatadog, PVReplay, PVCrash, PVBraze, PVTidal, PVCount };
static atomic_uint gBlocked[PVCount];

// Settings key, on by default, rules: "host" or ".suffix", optionally followed by a path prefix
static NSArray<NSArray *> *PVGroups(void) {
	static NSArray *groups;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSArray *datadog = @[ @"browser-intake-datadoghq.com", @"browser-intake-us3-datadoghq.com", @"browser-intake-us5-datadoghq.com",
		                      @"browser-intake-datadoghq.eu", @"browser-intake-ap1-datadoghq.com", @"browser-intake-ap2-datadoghq.com",
		                      @"browser-intake-ddog-gov.com" ];
		NSMutableArray *replay = [NSMutableArray array];
		for (NSString *h in datadog) [replay addObject:[h stringByAppendingString:@"/api/v2/replay"]];
		groups = @[
			@[ @"tt.privacy.datadog", @YES, datadog ],
			@[ @"tt.privacy.replay", @YES, replay ],
			@[ @"tt.privacy.crashlytics", @YES, @[ @".crashlytics.com", @"crashlyticsreports-pa.googleapis.com", @"firebaselogging.googleapis.com",
			                                      @"firebaselogging-pa.googleapis.com", @"firebaseinstallations.googleapis.com" ] ],
			@[ @"tt.privacy.braze", @YES, @[ @".braze.com" ] ],
			@[ @"tt.privacy.tidal", @NO, @[ @"ec.tidal.com", @"et.tidal.com", @"api.tidal.com/v1/report/offlineplays" ] ],
		];
	});
	return groups;
}

static BOOL PVOn(NSInteger g) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:PVGroups()[g][0]];
	return v ? [v boolValue] : [PVGroups()[g][1] boolValue];
}

static NSInteger PVGroup(NSURL *url) {
	NSString *host = url.host.lowercaseString, *path = url.path ?: @"";
	if (!host) return -1;
	for (NSInteger g = 0; g < PVCount; g++) {
		if (!PVOn(g)) continue;
		for (NSString *rule in PVGroups()[g][2]) {
			NSRange slash = [rule rangeOfString:@"/"];
			NSString *h = slash.location == NSNotFound ? rule : [rule substringToIndex:slash.location];
			if ([h hasPrefix:@"."] ? ![host hasSuffix:h] : ![host isEqualToString:h]) continue;
			if (slash.location == NSNotFound || [path hasPrefix:[rule substringFromIndex:slash.location]]) return g;
		}
	}
	return -1;
}

@interface PVProtocol : NSURLProtocol
@end

@implementation PVProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return PVGroup(r.URL) >= 0; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
	NSURL *url = self.request.URL;
	NSInteger g = PVGroup(url);
	if (g >= 0 && atomic_fetch_add(&gBlocked[g], 1) == 0) PVLog(@"blocking %@", url.host);
	[self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:@{ NSURLErrorFailingURLErrorKey: url }]];
}
- (void)stopLoading {}
@end

static NSArray *(*orig_protocolClasses)(NSURLSessionConfiguration *, SEL);
static NSArray *hook_protocolClasses(NSURLSessionConfiguration *self, SEL _cmd) {
	NSArray *a = orig_protocolClasses(self, _cmd) ?: @[];
	return [a containsObject:PVProtocol.class] ? a : [@[ PVProtocol.class ] arrayByAddingObjectsFromArray:a];
}

static NSDictionary *PVSwitch(NSInteger g, NSString *title, NSString *detail) {
	return @{ @"type": @"switch", @"key": PVGroups()[g][0], @"default": PVGroups()[g][1], @"title": title, @"detail": detail };
}

static NSString *(^PVFooter(NSString *text, NSRange groups))(void) {
	return ^NSString * {
		unsigned n = 0;
		for (NSUInteger g = groups.location; g < NSMaxRange(groups); g++) n += atomic_load(&gBlocked[g]);
		NSString *count = [NSString stringWithFormat:PVL(@"Blocked since TIDAL started: %u", @"TIDAL 시작 후 막은 요청: %u개"), n];
		return text ? [NSString stringWithFormat:@"%@\n%@", text, count] : count;
	};
}

@interface PVSettings : NSObject
@end
@implementation PVSettings
+ (NSArray *)ttSections {
	NSMutableDictionary *replay = [PVSwitch(PVReplay, PVL(@"Session Replay only", @"화면 기록만"),
	                                        PVL(@"Datadog's recording of the screen", @"Datadog 화면 녹화 (와이어프레임)")) mutableCopy];
	replay[@"indent"] = @YES;
	replay[@"visible"] = ^BOOL { return !PVOn(PVDatadog); };
	NSMutableDictionary *tidal = [PVSwitch(PVTidal, PVL(@"Usage and play reports", @"사용·재생 기록"),
	                                       PVL(@"TIDAL's own event collector and offline play reports", @"TIDAL 자체 수집기와 오프라인 재생 보고")) mutableCopy];
	tidal[@"confirm"] = @[ PVL(@"Block play reports?", @"재생 기록을 막을까요?"),
	                       PVL(@"TIDAL pays artists from these reports: your plays may not count toward their payouts. Recently Played and recommendations may also stop following what you listen to.",
	                           @"TIDAL은 이 기록으로 아티스트에게 정산해요. 막으면 내가 들은 곡이 아티스트 정산에 제대로 반영되지 않을 수 있어요. 최근 재생·추천에도 반영이 안 될 수 있어요."),
	                       PVL(@"Block", @"막기") ];
	return @[
		@{ @"header": PVL(@"Trackers", @"추적 서비스"),
		   @"items": @[
			   PVSwitch(PVDatadog, PVL(@"App monitoring", @"앱 모니터링"),
			            PVL(@"Datadog: screens, taps, requests, errors, crashes, Session Replay", @"Datadog: 화면·탭·요청·에러·크래시·화면 기록")),
			   replay,
			   PVSwitch(PVCrash, PVL(@"Crash reports", @"크래시 리포트"),
			            PVL(@"Firebase Crashlytics: with the list of loaded tweaks", @"Firebase Crashlytics: 로드된 트윅 목록 포함")),
			   PVSwitch(PVBraze, PVL(@"Marketing", @"마케팅"),
			            PVL(@"Braze: sessions, events, push token, device info", @"Braze: 세션·이벤트·푸시 토큰·기기 정보")),
		   ],
		   @"footer": PVFooter(PVL(@"Applies right away. With Braze blocked, TIDAL's messages and banners sent through it stop too.",
		                           @"바로 적용돼요. Braze를 막으면 TIDAL이 Braze로 보내는 메시지·배너도 안 와요."), NSMakeRange(PVDatadog, PVTidal)) },
		@{ @"header": @"TIDAL",
		   @"items": @[ tidal ],
		   @"footer": PVFooter(nil, NSMakeRange(PVTidal, 1)) },
	];
}
@end

__attribute__((constructor)) static void PVInit(void) {
	id enabled = [NSUserDefaults.standardUserDefaults objectForKey:@"tt.TidalPrivacy.enabled"];
	if (enabled && ![enabled boolValue] && NSClassFromString(@"TTCore")) return PVLog(@"turned off in TidalCore's settings");
	[NSURLProtocol registerClass:PVProtocol.class];
	Class cfg = object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration);
	Method m = class_getInstanceMethod(cfg, @selector(protocolClasses));
	if (!m) return PVLog(@"no protocolClasses on %s", class_getName(cfg));
	if (class_addMethod(cfg, @selector(protocolClasses), (IMP)hook_protocolClasses, method_getTypeEncoding(m))) orig_protocolClasses = (void *)method_getImplementation(m);
	else orig_protocolClasses = (void *)method_setImplementation(m, (IMP)hook_protocolClasses);
	PVLog(@"loaded");
}
