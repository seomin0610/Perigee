#import "KS.h"
#import <objc/runtime.h>
#import <dlfcn.h>

static const double kKSBudget = 8;
static const int64_t kKSSettleMs = 300;

void KSLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [@"[TidalKoreanSearch] " stringByAppendingString:[[NSString alloc] initWithFormat:fmt arguments:args]];
	va_end(args);
	static void (*radiant)(NSString *);
	static dispatch_once_t once;
	dispatch_once(&once, ^{ radiant = (void (*)(NSString *))dlsym(RTLD_DEFAULT, "RLLogLine"); });
	if (radiant) radiant(line);
	else NSLog(@"%@", line);
}

static NSURLSession *KSSession(void) {
	static NSURLSession *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; });
	return s;
}

static NSString *KSPhrase(NSURL *url) {
	if (![url.host hasSuffix:@"tidal.com"] || ![url.path hasSuffix:@"/v2/search"]) return nil;
	NSString *phrase;
	for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
		if ([q.name isEqualToString:@"offset"] && q.value.integerValue > 0) return nil;
		if ([q.name isEqualToString:@"query"]) phrase = q.value;
	}
	static NSCharacterSet *syllables, *jamo;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		syllables = [NSCharacterSet characterSetWithRange:NSMakeRange(0xAC00, 0xD7A4 - 0xAC00)];
		jamo = [NSCharacterSet characterSetWithRange:NSMakeRange(0x3131, 0x318F - 0x3131)];
	});
	if (!phrase || [phrase rangeOfCharacterFromSet:syllables].location == NSNotFound || [phrase rangeOfCharacterFromSet:jamo].location != NSNotFound) return nil;
	return [phrase stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

#pragma mark - Cache (plugin's index.ts: 100 phrases, "nothing found" kept a minute)

static NSMutableDictionary<NSString *, NSDictionary *> *gCache;
static NSMutableArray<NSString *> *gCacheOrder;
static NSMutableDictionary<NSString *, NSMutableArray *> *gWaiting;

static dispatch_queue_t KSQueue(void) {
	static dispatch_queue_t q;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		q = dispatch_queue_create("ks.cache", DISPATCH_QUEUE_SERIAL);
		gCache = [NSMutableDictionary dictionary];
		gCacheOrder = [NSMutableArray array];
		gWaiting = [NSMutableDictionary dictionary];
	});
	return q;
}

void KSCacheClear(void) {
	dispatch_async(KSQueue(), ^{
		[gCache removeAllObjects];
		[gCacheOrder removeAllObjects];
	});
}

static void KSTracks(NSString *phrase, NSURLRequest *search, void (^done)(NSArray *tracks)) {
	__block BOOL finished = NO;
	void (^finish)(NSArray *) = ^(NSArray *tracks) {
		if (finished) return;
		finished = YES;
		done(tracks);
	};
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kKSBudget * NSEC_PER_SEC)), KSQueue(), ^{
		if (!finished) KSLog(@"\"%@\" took over %.0fs, showing TIDAL's results only", phrase, kKSBudget);
		finish(nil);
	});

	NSDictionary *hit = gCache[phrase];
	if (hit && ([hit[@"tracks"] count] || NSDate.timeIntervalSinceReferenceDate - [hit[@"at"] doubleValue] < 60)) {
		finish(hit[@"tracks"]);
		return;
	}
	if (gWaiting[phrase]) {
		[gWaiting[phrase] addObject:finish];
		return;
	}
	gWaiting[phrase] = [NSMutableArray arrayWithObject:finish];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray *tracks = KSResolve(phrase, search);
		dispatch_async(KSQueue(), ^{
			[gCacheOrder removeObject:phrase];
			if (gCacheOrder.count >= 100) {
				[gCache removeObjectForKey:gCacheOrder.firstObject];
				[gCacheOrder removeObjectAtIndex:0];
			}
			gCache[phrase] = @{ @"tracks": tracks, @"at": @(NSDate.timeIntervalSinceReferenceDate) };
			[gCacheOrder addObject:phrase];
			for (void (^callback)(NSArray *) in gWaiting[phrase]) callback(tracks);
			[gWaiting removeObjectForKey:phrase];
		});
	});
}

#pragma mark - Interception

@interface KSProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@end

@implementation KSProtocol {
	NSURLSessionDataTask *_task;
	id _runLoop; // NSURLProtocolClient calls must go back to the client thread
	NSArray *_modes;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)r {
	return ![NSURLProtocol propertyForKey:kKSHandled inRequest:r] && [r.HTTPMethod isEqualToString:@"GET"] && KSPhrase(r.URL);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }

- (void)onClient:(dispatch_block_t)block {
	CFRunLoopPerformBlock((__bridge CFRunLoopRef)_runLoop, (__bridge CFTypeRef)_modes, block);
	CFRunLoopWakeUp((__bridge CFRunLoopRef)_runLoop);
}

- (void)startLoading {
	_runLoop = (__bridge id)CFRunLoopGetCurrent();
	NSString *mode = CFBridgingRelease(CFRunLoopCopyCurrentMode(CFRunLoopGetCurrent()));
	_modes = mode ? @[ mode, NSRunLoopCommonModes ] : @[ NSRunLoopCommonModes ];

	NSMutableURLRequest *req = [self.request mutableCopy];
	[NSURLProtocol setProperty:@YES forKey:kKSHandled inRequest:req];
	NSString *phrase = KSPhrase(req.URL);

	dispatch_group_t group = dispatch_group_create();
	__block NSData *data;
	__block NSURLResponse *response;
	__block NSError *error;
	__block NSArray *tracks;

	dispatch_group_enter(group);
	_task = [KSSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
		data = d;
		response = r;
		error = e;
		dispatch_group_leave(group);
	}];
	[_task resume];

	__weak KSProtocol *weakSelf = self;
	dispatch_group_enter(group);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kKSSettleMs * NSEC_PER_MSEC), KSQueue(), ^{
		if (!weakSelf || weakSelf.stopped) return dispatch_group_leave(group);
		KSTracks(phrase, req, ^(NSArray *t) {
			tracks = t;
			dispatch_group_leave(group);
		});
	});

	dispatch_group_notify(group, KSQueue(), ^{
		KSProtocol *me = weakSelf;
		if (!me || me.stopped) return;
		NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
		NSData *body = data;
		if (http) {
			NSData *merged = http.statusCode == 200 ? KSMerge(data, tracks) : nil;
			if (merged) body = merged;
			if (tracks.count) KSLog(@"%@: %@", phrase, merged ? [NSString stringWithFormat:@"%lu added", (unsigned long)tracks.count] : [NSString stringWithFormat:@"nowhere to add (%ld)", (long)http.statusCode]);
			// the body is already decoded (and maybe longer): drop the original encoding/length
			NSMutableDictionary *headers = [NSMutableDictionary dictionary];
			[http.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
				if ([k caseInsensitiveCompare:@"Content-Encoding"] && [k caseInsensitiveCompare:@"Content-Length"]) headers[k] = v;
			}];
			headers[@"Content-Length"] = @(body.length).stringValue;
			response = [[NSHTTPURLResponse alloc] initWithURL:http.URL statusCode:http.statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers];
		}
		[me onClient:^{
			if (me.stopped) return;
			if (error) return [me.client URLProtocol:me didFailWithError:error];
			[me.client URLProtocol:me didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
			if (body.length) [me.client URLProtocol:me didLoadData:body];
			[me.client URLProtocolDidFinishLoading:me];
		}];
	});
}

- (void)stopLoading {
	self.stopped = YES;
	[_task cancel];
}
@end

static NSArray *(*orig_protocolClasses)(NSURLSessionConfiguration *, SEL);
static NSArray *hook_protocolClasses(NSURLSessionConfiguration *self, SEL _cmd) {
	NSArray *a = orig_protocolClasses(self, _cmd) ?: @[];
	return [a containsObject:KSProtocol.class] ? a : [@[ KSProtocol.class ] arrayByAddingObjectsFromArray:a];
}

#pragma mark - Settings (drawn by TidalCore; without it the defaults in KS.h apply)

@interface KSSettings : NSObject
@end
@implementation KSSettings
+ (NSArray *)ttSections {
	void (^again)(id) = ^(id v) { KSCacheClear(); };
	return @[
		@{ @"header": KSL(@"Where to look", @"찾는 곳"),
		   @"items": @[
			   @{ @"type": @"switch", @"key": @"ks.itunes", @"default": @YES, @"title": @"Apple Music", @"set": again,
			      @"detail": KSL(@"US and Korean store titles of the same track", @"같은 곡의 미국·한국 스토어 제목 대조") },
			   @{ @"type": @"switch", @"key": @"ks.musicbrainz", @"default": @YES, @"title": @"MusicBrainz", @"set": again,
			      @"detail": KSL(@"ISRC: exactly the same recording", @"ISRC로 같은 녹음을 정확히 집어냄") },
			   @{ @"type": @"switch", @"key": @"ks.komca", @"default": @YES, @"title": KSL(@"KOMCA", @"한국음악저작권협회"), @"set": again,
			      @"detail": KSL(@"English titles filed with the work, when the others missed", @"앞의 둘이 놓쳤을 때, 저작물에 등록된 영문 제목") },
		   ],
		   @"footer": KSL(@"Turn all three off and nothing gets added.", @"셋 다 끄면 아무것도 안 넣어요.") },
		@{ @"items": @[ @{ @"type": @"choice", @"key": @"ks.maxResults", @"default": @8, @"title": KSL(@"Songs added", @"넣는 곡 수"), @"set": again,
		                   @"options": @[ @[ @3, @"3" ], @[ @5, @"5" ], @[ @8, @"8" ], @[ @12, @"12" ], @[ @20, @"20" ] ] } ],
		   @"footer": KSL(@"Songs found by their Korean name go on top of Tracks, the first three also on top of Top results, marked with the Korean title.",
		                  @"한글 이름으로 찾은 곡을 Tracks 맨 위에, 앞 3곡은 Top results 위에도 넣어요. 한글 제목을 붙여 표시해요.") },
	];
}
@end

__attribute__((constructor)) static void KSInit(void) {
	if (NSClassFromString(@"TTCore") && ![NSUserDefaults.standardUserDefaults boolForKey:@"tt.TidalKoreanSearch.enabled"]) {
		KSLog(@"turned off in TidalCore's settings");
		return;
	}
	[NSURLProtocol registerClass:KSProtocol.class];
	Class cfg = object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration);
	Method m = class_getInstanceMethod(cfg, @selector(protocolClasses));
	if (!m) {
		KSLog(@"no protocolClasses on %s", class_getName(cfg));
		return;
	}
	if (class_addMethod(cfg, @selector(protocolClasses), (IMP)hook_protocolClasses, method_getTypeEncoding(m))) orig_protocolClasses = (void *)method_getImplementation(m);
	else orig_protocolClasses = (void *)method_setImplementation(m, (IMP)hook_protocolClasses);
	KSLog(@"loaded");
}
