#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <sqlite3.h>

static void OFLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void OFLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalOffline] %{public}@", line);
}

static NSString *const kHandled = @"tt.offline.handled";
static NSString *const kV1 = @"tt.offline.v1";
static NSString *const kScope = @"r_usr w_usr w_sub";
static NSString *const kModePrefix = @"tt.offline.mode.";
static NSString *const kNames = @"tt.offline.names";
static NSString *const kKnown = @"tt.offline.files";
static NSMutableDictionary<NSString *, NSString *> *gTrackCollection;
static NSMutableDictionary<NSString *, NSArray<NSURL *> *> *gDirect;
static char kJob;

static NSString *OFL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}
static id OFAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static NSURLSession *OFSession(void) {
	static NSURLSession *s;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ s = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration]; });
	return s;
}

static BOOL OFRemove(NSURLRequest *r) { return [r.HTTPMethod isEqualToString:@"DELETE"]; }

static BOOL OFInventory(NSURLRequest *r) {
	return ([r.HTTPMethod isEqualToString:@"POST"] || OFRemove(r)) && [r.URL.host hasSuffix:@"tidal.com"] && [r.URL.path hasSuffix:@"/relationships/offlineInventory"];
}

static NSString *OFManifestTrack(NSURLRequest *r) {
	NSURL *u = r.URL;
	if (![r.HTTPMethod isEqualToString:@"GET"] || ![u.host hasSuffix:@"tidal.com"] || ![u.path.stringByDeletingLastPathComponent hasSuffix:@"/trackManifests"] ||
	    ![u.query containsString:@"usage=DOWNLOAD"])
		return nil;
	NSString *track = u.lastPathComponent;
	return track.length && [track rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound ? track : nil;
}

static BOOL OFTasksRequest(NSURLRequest *r) {
	return [r.HTTPMethod isEqualToString:@"GET"] && [r.URL.host hasSuffix:@"tidal.com"] && [r.URL.path hasSuffix:@"/offlineTasks"];
}

static NSString *OFKey(id type, id ident) {
	NSString *t = OFAs(type, NSString.class), *i = OFAs(ident, NSString.class);
	return t && i ? [NSString stringWithFormat:@"%@:%@", t, i] : nil;
}

static id OFMode(NSString *key) {
	return key ? [NSUserDefaults.standardUserDefaults objectForKey:[kModePrefix stringByAppendingString:key]] : nil;
}

static void OFSetMode(NSString *key, BOOL v1) {
	if (key) [NSUserDefaults.standardUserDefaults setBool:v1 forKey:[kModePrefix stringByAppendingString:key]];
}

static BOOL OFUseV1(NSString *track) {
	NSString *key;
	@synchronized (gTrackCollection) { key = gTrackCollection[track]; }
	id mode = OFMode(key ?: OFKey(@"tracks", track));
	return mode ? [mode boolValue] : [NSUserDefaults.standardUserDefaults boolForKey:kV1];
}

static NSString *OFInventoryKey(NSData *body) {
	NSDictionary *doc = OFAs(body ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil, NSDictionary.class);
	NSDictionary *item = OFAs([OFAs(doc[@"data"], NSArray.class) firstObject], NSDictionary.class);
	return OFKey(item[@"type"], item[@"id"]);
}

static sqlite3 *OFOpenStore(int flags) {
	NSURL *db = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Offliner/offline.sqlite"];
	sqlite3 *h;
	if (sqlite3_open_v2(db.path.fileSystemRepresentation, &h, flags, NULL) == SQLITE_OK) {
		sqlite3_busy_timeout(h, 2000);
		return h;
	}
	sqlite3_close(h);
	return NULL;
}

static BOOL OFStored(sqlite3 *h, NSString *key, UIImage **art) {
	NSRange colon = [key rangeOfString:@":"];
	sqlite3_stmt *st;
	*art = nil;
	if (!h || colon.location == NSNotFound || sqlite3_prepare_v2(h, "SELECT artwork_bookmark FROM offline_item WHERE resource_type = ? AND resource_id = ?", -1, &st, NULL) != SQLITE_OK) return YES;
	NSString *type = [key substringToIndex:colon.location];
	sqlite3_bind_text(st, 1, type.UTF8String, -1, SQLITE_TRANSIENT);
	sqlite3_bind_text(st, 2, [type isEqualToString:@"userCollectionTracks"] ? "me" : [key substringFromIndex:NSMaxRange(colon)].UTF8String, -1, SQLITE_TRANSIENT);
	BOOL found = sqlite3_step(st) == SQLITE_ROW;
	NSData *bookmark = found && sqlite3_column_type(st, 0) == SQLITE_BLOB ? [NSData dataWithBytes:sqlite3_column_blob(st, 0) length:sqlite3_column_bytes(st, 0)] : nil;
	sqlite3_finalize(st);
	NSURL *file = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:NULL error:nil] : nil;
	if (file) *art = [[UIImage imageWithContentsOfFile:file.path] imageByPreparingThumbnailOfSize:CGSizeMake(120, 120)];
	return found;
}

static NSString *OFFolder(void) {
	return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"TidalOffline"];
}

static NSSet<NSString *> *OFStoreFiles(void) {
	sqlite3 *h = OFOpenStore(SQLITE_OPEN_READONLY);
	sqlite3_stmt *st;
	if (!h || sqlite3_prepare_v2(h, "SELECT media_bookmark FROM offline_item WHERE media_bookmark IS NOT NULL", -1, &st, NULL) != SQLITE_OK) {
		sqlite3_close(h);
		return nil;
	}
	NSMutableSet *files = [NSMutableSet set];
	int rc;
	while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
		NSData *b = [NSData dataWithBytes:sqlite3_column_blob(st, 0) length:sqlite3_column_bytes(st, 0)];
		NSString *name = [[NSURL resourceValuesForKeys:@[ NSURLPathKey ] fromBookmarkData:b][NSURLPathKey] lastPathComponent];
		if (name) [files addObject:name];
	}
	sqlite3_finalize(st);
	sqlite3_close(h);
	return rc == SQLITE_DONE ? files : nil;
}

static void OFSnapshot(void) {
	@synchronized (kKnown) {
		NSSet *live = OFStoreFiles();
		NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
		if (live) [d setObject:[live setByAddingObjectsFromArray:[d stringArrayForKey:kKnown] ?: @[]].allObjects forKey:kKnown];
	}
}

static void OFCleanup(void) {
	@synchronized (kKnown) {
		NSSet *live = OFStoreFiles();
		if (!live) return OFLog(@"cleanup: can't read store");
		NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
		NSUInteger gone = 0, removed = 0;
		for (NSString *f in [d stringArrayForKey:kKnown])
			if (![live containsObject:f]) {
				gone++;
				removed += [NSFileManager.defaultManager removeItemAtPath:[OFFolder() stringByAppendingPathComponent:f] error:nil];
			}
		[d setObject:live.allObjects forKey:kKnown];
		OFLog(@"cleanup: removed %lu of %lu, store %lu, folder %lu", (unsigned long)removed, (unsigned long)gone, (unsigned long)live.count,
		      (unsigned long)[NSFileManager.defaultManager contentsOfDirectoryAtPath:OFFolder() error:nil].count);
	}
}

static void OFCleanupSoon(void) {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ OFCleanup(); });
}

static void OFLearnTasks(NSData *data) {
	OFSnapshot();
	NSDictionary *doc = OFAs(data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil, NSDictionary.class);
	NSMutableDictionary *seen = [NSMutableDictionary dictionary];
	for (NSDictionary *inc in OFAs(doc[@"included"], NSArray.class)) {
		NSDictionary *a = OFAs(OFAs(inc, NSDictionary.class)[@"attributes"], NSDictionary.class);
		NSString *key = OFKey(inc[@"type"], inc[@"id"]), *name = OFAs(a[@"name"], NSString.class) ?: OFAs(a[@"title"], NSString.class);
		if (key && name) seen[key] = name;
	}
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	NSMutableDictionary *names = [[d dictionaryForKey:kNames] mutableCopy] ?: [NSMutableDictionary dictionary];
	for (NSDictionary *task in OFAs(doc[@"data"], NSArray.class)) {
		NSDictionary *rel = OFAs(OFAs(task, NSDictionary.class)[@"relationships"], NSDictionary.class);
		NSDictionary *item = OFAs(OFAs(rel[@"item"], NSDictionary.class)[@"data"], NSDictionary.class);
		NSDictionary *coll = OFAs(OFAs(rel[@"collection"], NSDictionary.class)[@"data"], NSDictionary.class);
		if ([OFAs(OFAs(task, NSDictionary.class)[@"attributes"], NSDictionary.class)[@"action"] isEqual:@"REMOVE"]) {
			OFCleanupSoon();
			continue;
		}
		NSString *track = [item[@"type"] isEqual:@"tracks"] ? OFAs(item[@"id"], NSString.class) : nil;
		if (!track) continue;
		NSString *key = OFKey(coll[@"type"], coll[@"id"]) ?: OFKey(@"tracks", track);
		@synchronized (gTrackCollection) { gTrackCollection[track] = key; }
		if (!OFMode(key)) OFSetMode(key, [d boolForKey:kV1]);
		if (seen[key]) names[key] = seen[key];
	}
	[d setObject:names forKey:kNames];
}

static NSString *OFQuality(NSURL *u) {
	NSMutableArray *formats = [NSMutableArray array];
	for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems)
		if ([q.name hasPrefix:@"formats"] && q.value) [formats addObjectsFromArray:[q.value componentsSeparatedByString:@","]];
	for (NSArray *p in @[ @[ @"FLAC_HIRES", @"HI_RES_LOSSLESS" ], @[ @"FLAC", @"LOSSLESS" ], @[ @"AACLC", @"HIGH" ] ])
		if ([formats containsObject:p[0]]) return p[1];
	return @"LOW";
}

static NSData *OFBody(NSURLRequest *r) {
	if (r.HTTPBody || !r.HTTPBodyStream) return r.HTTPBody;
	NSMutableData *d = [NSMutableData data];
	NSInputStream *s = r.HTTPBodyStream;
	uint8_t buf[4096];
	NSInteger n;
	[s open];
	while ((n = [s read:buf maxLength:sizeof buf]) > 0) [d appendBytes:buf length:n];
	[s close];
	return d;
}

#pragma mark - v1 manifest

@interface OFMPD : NSObject <NSXMLParserDelegate>
@property (nonatomic) NSDictionary<NSString *, NSString *> *tmpl;
@property (nonatomic) NSMutableArray<NSNumber *> *durations;
@end

@implementation OFMPD
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary<NSString *, NSString *> *)a {
	if ([e isEqualToString:@"SegmentTemplate"]) _tmpl = a;
	else if ([e isEqualToString:@"S"] && _tmpl)
		for (NSInteger i = 0; i <= MAX(0, a[@"r"].integerValue); i++) [_durations addObject:@(a[@"d"].doubleValue)];
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)e namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
	if ([e isEqualToString:@"SegmentTemplate"]) [p abortParsing];
}
@end

static NSString *OFHLS(NSData *mpd, NSMutableArray<NSURL *> *parts) {
	OFMPD *m = [OFMPD new];
	m.durations = [NSMutableArray array];
	NSXMLParser *p = [[NSXMLParser alloc] initWithData:mpd];
	p.delegate = m;
	[p parse];
	NSString *init = m.tmpl[@"initialization"], *media = m.tmpl[@"media"];
	if (!init || !media || !m.durations.count || ![NSURL URLWithString:init]) return nil;
	[parts addObject:[NSURL URLWithString:init]];
	double scale = m.tmpl[@"timescale"].doubleValue ?: 1;
	NSInteger n = m.tmpl[@"startNumber"] ? m.tmpl[@"startNumber"].integerValue : 1;
	double longest = [[m.durations valueForKeyPath:@"@max.doubleValue"] doubleValue] / scale;
	NSMutableString *s = [NSMutableString stringWithFormat:@"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%d\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
	                                                       @"#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"%@\"\n",
	                                                       (int)ceil(longest), init];
	for (NSNumber *d in m.durations) {
		NSString *segment = [media stringByReplacingOccurrencesOfString:@"$Number$" withString:@(n++).stringValue];
		if (![NSURL URLWithString:segment]) return nil;
		[parts addObject:[NSURL URLWithString:segment]];
		[s appendFormat:@"#EXTINF:%.6f,\n%@\n", d.doubleValue / scale, segment];
	}
	[s appendString:@"#EXT-X-ENDLIST\n"];
	return s;
}

static NSDictionary *OFGain(id gain, id peak) {
	return OFAs(gain, NSNumber.class) && OFAs(peak, NSNumber.class) ? @{ @"replayGain": gain, @"peakAmplitude": peak } : nil;
}

static NSData *OFManifest(NSString *track, NSData *data) {
	NSDictionary *info = OFAs(data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil, NSDictionary.class);
	NSString *b64 = OFAs(info[@"manifest"], NSString.class), *type = OFAs(info[@"manifestMimeType"], NSString.class), *uri;
	NSData *raw = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
	if ([type isEqualToString:@"application/vnd.tidal.bts"] || [type isEqualToString:@"application/vnd.tidal.emu"]) {
		NSDictionary *m = OFAs(raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil, NSDictionary.class);
		NSString *enc = OFAs(m[@"encryptionType"], NSString.class);
		uri = enc && ![enc isEqualToString:@"NONE"] ? nil : OFAs([OFAs(m[@"urls"], NSArray.class) firstObject], NSString.class);
		NSURL *file = uri ? [NSURL URLWithString:uri] : nil;
		if (file && [type hasSuffix:@"bts"]) @synchronized (gDirect) { gDirect[uri] = @[ file ]; }
	} else if ([type isEqualToString:@"application/dash+xml"]) {
		NSMutableArray<NSURL *> *parts = [NSMutableArray array];
		NSString *m3u8 = raw ? OFHLS(raw, parts) : nil;
		if (m3u8) {
			uri = [@"data:application/vnd.apple.mpegurl;base64," stringByAppendingString:[[m3u8 dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]];
			@synchronized (gDirect) { gDirect[uri] = parts; }
		}
	}
	if (!uri) {
		NSString *text = (raw ?: data) ? [[NSString alloc] initWithData:raw ?: data encoding:NSUTF8StringEncoding] : nil;
		OFLog(@"v1 %@ unusable: %@ %@ %@", track, info[@"audioQuality"], type, text.length > 800 ? [text substringToIndex:800] : text);
		return nil;
	}

	NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithObject:uri forKey:@"uri"];
	NSDictionary *formats = @{ @"HI_RES_LOSSLESS": @"FLAC_HIRES", @"LOSSLESS": @"FLAC", @"HIGH": @"AACLC", @"LOW": @"HEAACV1" };
	NSString *format = formats[OFAs(info[@"audioQuality"], NSString.class) ?: @""];
	if (format) attrs[@"formats"] = @[ format ];
	attrs[@"trackPresentation"] = OFAs(info[@"assetPresentation"], NSString.class);
	attrs[@"hash"] = OFAs(info[@"manifestHash"], NSString.class);
	attrs[@"trackAudioNormalizationData"] = OFGain(info[@"trackReplayGain"], info[@"trackPeakAmplitude"]);
	attrs[@"albumAudioNormalizationData"] = OFGain(info[@"albumReplayGain"], info[@"albumPeakAmplitude"]);
	OFLog(@"v1 %@: %@ %@", track, info[@"audioQuality"], type);
	return [NSJSONSerialization dataWithJSONObject:@{ @"data": @{ @"id": track, @"type": @"trackManifests", @"attributes": attrs },
	                                                  @"links": @{ @"self": [@"/trackManifests/" stringByAppendingString:track] } }
	                                       options:0
	                                         error:nil];
}

#pragma mark - Choice

static void OFAsk(void (^go)(BOOL v1)) {
	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindowScene *scene;
		for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
			if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:UIWindowScene.class]) scene = (UIWindowScene *)s;
		if (!scene) return go([NSUserDefaults.standardUserDefaults boolForKey:kV1]);
		UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
		w.windowLevel = UIWindowLevelAlert;
		w.rootViewController = [UIViewController new];
		w.hidden = NO;
		UIAlertController *ac = [UIAlertController alertControllerWithTitle:OFL(@"Download from", @"다운로드 방식")
		                                                            message:OFL(@"v1 gets the file itself, without DRM. v2 is TIDAL's own download.",
		                                                                        @"v1은 DRM 없는 원본 파일을, v2는 TIDAL 기본 방식으로 받아요.")
		                                                     preferredStyle:UIAlertControllerStyleAlert];
		for (NSNumber *v1 in @[ @YES, @NO ])
			[ac addAction:[UIAlertAction actionWithTitle:v1.boolValue ? @"v1 (playbackinfo)" : @"v2 (trackManifests)"
			                                       style:UIAlertActionStyleDefault
			                                     handler:^(UIAlertAction *a) {
				                                     w.hidden = YES;
				                                     [NSUserDefaults.standardUserDefaults setBool:v1.boolValue forKey:kV1];
				                                     go(v1.boolValue);
			                                     }]];
		[w.rootViewController presentViewController:ac animated:YES completion:nil];
	});
}

#pragma mark - v1 login

static NSString *const kRedirect = @"https://tidal.com/android/login/auth";

static NSString *OFClient(BOOL secret) {
	NSString *a = secret ? @"ZUdWMVVHMVpOMjVpY0ZvNVNVbGlURUZqVVQ=" : @"TmtKRVUxSmtjRXM=";
	NSString *b = secret ? @"a3pjMmhyWVRGV1RtaGxWVUZ4VGpaSlkzTjZhbFJIT0QwPQ==" : @"NWFIRkZRbFJuVlE9PQ==";
	NSMutableData *m = [[NSData alloc] initWithBase64EncodedString:a options:0].mutableCopy;
	[m appendData:[[NSData alloc] initWithBase64EncodedString:b options:0]];
	return [[NSString alloc] initWithData:[[NSData alloc] initWithBase64EncodedData:m options:0] encoding:NSUTF8StringEncoding];
}

static NSString *OFBase64URL(NSData *d) {
	NSString *s = [d base64EncodedStringWithOptions:0];
	s = [[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
	return [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"="]];
}

static void OFAuth(NSString *path, NSDictionary<NSString *, NSString *> *form, void (^done)(NSDictionary *json, NSInteger status)) {
	NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	NSMutableArray *pairs = [NSMutableArray array];
	[form enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
		[pairs addObject:[NSString stringWithFormat:@"%@=%@", k, [v stringByAddingPercentEncodingWithAllowedCharacters:ok]]];
	}];
	NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://auth.tidal.com/v1/oauth2/" stringByAppendingString:path]]];
	r.HTTPMethod = @"POST";
	[r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	r.HTTPBody = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
	[[OFSession() dataTaskWithRequest:r completionHandler:^(NSData *d, NSURLResponse *resp, NSError *e) {
		done(OFAs(d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil, NSDictionary.class), OFAs(resp, NSHTTPURLResponse.class) ? ((NSHTTPURLResponse *)resp).statusCode : 0);
	}] resume];
}

static NSDictionary *OFKeychainItem(void) {
	return @{ (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService: @"tt.offline", (__bridge id)kSecAttrAccount: @"v1" };
}

static NSDictionary *OFTokens(void) {
	NSMutableDictionary *q = [OFKeychainItem() mutableCopy];
	q[(__bridge id)kSecReturnData] = @YES;
	CFTypeRef data = NULL;
	if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &data) != errSecSuccess) return nil;
	NSDictionary *t = OFAs([NSJSONSerialization JSONObjectWithData:CFBridgingRelease(data) options:0 error:nil], NSDictionary.class);
	return [t[@"pkce"] boolValue] ? t : nil;
}

static void OFSaveTokens(NSDictionary *tokens) {
	SecItemDelete((__bridge CFDictionaryRef)OFKeychainItem());
	if (!tokens) return;
	NSMutableDictionary *q = [OFKeychainItem() mutableCopy];
	q[(__bridge id)kSecValueData] = [NSJSONSerialization dataWithJSONObject:tokens options:0 error:nil];
	q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
	OSStatus status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
	if (status) OFLog(@"keychain save failed: %d", (int)status);
}

static NSDictionary *OFTokenRecord(NSDictionary *j, NSString *refresh) {
	return @{ @"access": j[@"access_token"],
	          @"refresh": OFAs(j[@"refresh_token"], NSString.class) ?: refresh ?: @"",
	          @"expires": @(NSDate.date.timeIntervalSince1970 + [j[@"expires_in"] doubleValue]),
	          @"user": [NSString stringWithFormat:@"%@", j[@"user_id"] ?: @""],
	          @"pkce": @YES };
}

static void OFToken(void (^done)(NSString *token)) {
	NSDictionary *t = OFTokens();
	if (!t) return done(nil);
	if ([t[@"expires"] doubleValue] > NSDate.date.timeIntervalSince1970 + 60) return done(t[@"access"]);
	OFAuth(@"token", @{ @"grant_type": @"refresh_token", @"refresh_token": OFAs(t[@"refresh"], NSString.class) ?: @"", @"client_id": OFClient(NO), @"client_secret": OFClient(YES), @"scope": kScope },
	       ^(NSDictionary *j, NSInteger status) {
		       if (!OFAs(j[@"access_token"], NSString.class)) {
			       OFLog(@"v1 login refresh failed (%ld %@)", (long)status, j[@"error"] ?: @"");
			       return done(nil);
		       }
		       OFSaveTokens(OFTokenRecord(j, t[@"refresh"]));
		       done(j[@"access_token"]);
	       });
}

static UIViewController *OFTop(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
		for (UIWindow *w in ((UIWindowScene *)OFAs(scene, UIWindowScene.class)).windows) {
			if (!w.isKeyWindow) continue;
			UIViewController *vc = w.rootViewController;
			while (vc.presentedViewController) vc = vc.presentedViewController;
			return vc;
		}
	return nil;
}

static void OFLoginDone(UIViewController *vc, NSString *title, NSString *message) {
	dispatch_async(dispatch_get_main_queue(), ^{
		void (^show)(void) = ^{
			UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
			[ac addAction:[UIAlertAction actionWithTitle:OFL(@"OK", @"확인") style:UIAlertActionStyleCancel handler:nil]];
			[OFTop() presentViewController:ac animated:YES completion:nil];
		};
		if (vc.presentingViewController) [vc dismissViewControllerAnimated:YES completion:show];
		else show();
	});
}

@interface OFLoginPage : UIViewController <WKNavigationDelegate>
@end

@implementation OFLoginPage {
	NSString *_verifier, *_key;
	BOOL _done;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = OFL(@"TIDAL Login", @"TIDAL 로그인");
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(close)];
	uint8_t raw[32], hash[CC_SHA256_DIGEST_LENGTH];
	arc4random_buf(raw, sizeof raw);
	_verifier = OFBase64URL([NSData dataWithBytes:raw length:sizeof raw]);
	NSData *v = [_verifier dataUsingEncoding:NSUTF8StringEncoding];
	CC_SHA256(v.bytes, (CC_LONG)v.length, hash);
	_key = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
	NSURLComponents *c = [NSURLComponents componentsWithString:@"https://login.tidal.com/authorize"];
	c.queryItems = @[
		[NSURLQueryItem queryItemWithName:@"response_type" value:@"code"],
		[NSURLQueryItem queryItemWithName:@"redirect_uri" value:kRedirect],
		[NSURLQueryItem queryItemWithName:@"client_id" value:OFClient(NO)],
		[NSURLQueryItem queryItemWithName:@"lang" value:@"EN"],
		[NSURLQueryItem queryItemWithName:@"appMode" value:@"android"],
		[NSURLQueryItem queryItemWithName:@"client_unique_key" value:_key],
		[NSURLQueryItem queryItemWithName:@"code_challenge" value:OFBase64URL([NSData dataWithBytes:hash length:sizeof hash])],
		[NSURLQueryItem queryItemWithName:@"code_challenge_method" value:@"S256"],
		[NSURLQueryItem queryItemWithName:@"restrict_signup" value:@"true"],
	];
	WKWebView *web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:[WKWebViewConfiguration new]];
	web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	web.navigationDelegate = self;
	[self.view addSubview:web];
	[web loadRequest:[NSURLRequest requestWithURL:c.URL]];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decide {
	NSURL *u = action.request.URL;
	if (![u.absoluteString hasPrefix:kRedirect]) return decide(WKNavigationActionPolicyAllow);
	decide(WKNavigationActionPolicyCancel);
	if (_done) return;
	_done = YES;
	NSString *code;
	for (NSURLQueryItem *q in [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO].queryItems)
		if ([q.name isEqualToString:@"code"]) code = q.value;
	UIViewController *nav = self.navigationController;
	if (!code) return OFLoginDone(nav, OFL(@"Login failed", @"로그인에 실패했어요"), nil);
	OFAuth(@"token",
	       @{ @"code": code, @"client_id": OFClient(NO), @"grant_type": @"authorization_code", @"redirect_uri": kRedirect, @"scope": kScope, @"code_verifier": _verifier,
	          @"client_unique_key": _key },
	       ^(NSDictionary *j, NSInteger status) {
		       if (!OFAs(j[@"access_token"], NSString.class)) {
			       OFLog(@"v1 login failed (%ld %@)", (long)status, j[@"error"] ?: @"");
			       return OFLoginDone(nav, OFL(@"Login failed", @"로그인에 실패했어요"), j[@"error_description"] ?: j[@"error"]);
		       }
		       OFSaveTokens(OFTokenRecord(j, nil));
		       OFLog(@"v1 login ok");
		       OFLoginDone(nav, OFL(@"Logged in", @"로그인했어요"), OFL(@"v1 downloads now use this login.", @"이제 v1 다운로드에 이 로그인을 써요."));
	       });
}
@end

static void OFLogin(void) {
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[OFLoginPage new]];
	[OFTop() presentViewController:nav animated:YES completion:nil];
}

@interface OFSettings : NSObject
@end
@implementation OFSettings
+ (NSArray *)ttSections {
	BOOL (^loggedIn)(void) = ^BOOL { return OFTokens() != nil; };
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	NSDictionary *names = [d dictionaryForKey:kNames];
	NSDictionary *kinds = @{ @"playlists": OFL(@"Playlist", @"플레이리스트"), @"albums": OFL(@"Album", @"앨범"), @"tracks": OFL(@"Track", @"트랙"),
		                     @"userCollectionTracks": OFL(@"My Collection", @"내 컬렉션") };
	NSMutableArray *items = [NSMutableArray array];
	sqlite3 *store = OFOpenStore(SQLITE_OPEN_READONLY);
	for (NSString *full in d.dictionaryRepresentation.allKeys) {
		if (![full hasPrefix:kModePrefix]) continue;
		NSString *key = [full substringFromIndex:kModePrefix.length], *kind = kinds[[key componentsSeparatedByString:@":"].firstObject];
		UIImage *art;
		if (!OFStored(store, key, &art)) continue;
		[items addObject:@{ @"type": @"choice", @"key": full, @"default": @NO, @"title": names[key] ?: kind ?: key, @"detail": kind ?: key,
			                @"image": art ?: [UIImage systemImageNamed:@"music.note.list"], @"options": @[ @[ @YES, @"v1" ], @[ @NO, @"v2" ] ] }];
	}
	sqlite3_close(store);
	[items sortUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES selector:@selector(localizedStandardCompare:)] ]];
	NSDictionary *sources = @{ @"header": OFL(@"Download source", @"다운로드 방식"), @"items": items,
		                       @"footer": OFL(@"Each download asks once; songs added to it later use the same choice. Applies to songs downloaded from now on.",
		                                      @"다운로드마다 한 번만 물어보고, 나중에 추가되는 곡도 같은 방식으로 받아요. 바꾸면 그다음 받는 곡부터 적용돼요.") };
	NSDictionary *login = @{
		@"header": OFL(@"v1 login", @"v1 로그인"),
		@"items": @[
			@{ @"type": @"action", @"title": OFL(@"Log In", @"로그인"), @"set": ^{ OFLogin(); }, @"visible": ^BOOL { return !loggedIn(); } },
			@{ @"type": @"action", @"title": OFL(@"Log Out", @"로그아웃"), @"destructive": @YES, @"set": ^{ OFSaveTokens(nil); }, @"visible": loggedIn,
			   @"value": ^NSString * { return OFTokens()[@"user"]; } },
		],
		@"footer": OFL(@"v1 asks playbackinfo with this login instead of TIDAL's. TIDAL's iOS login only gets FairPlay-encrypted streams; this one gets the file itself, up to Hi-Res. Without it, v1 falls back to v2.",
		               @"v1이 TIDAL 앱 로그인 대신 이 로그인으로 playbackinfo를 요청해요. TIDAL iOS 로그인으로는 FairPlay로 암호화된 것만 와요. 이 로그인은 Hi-Res까지 원본 파일로 받아요. 로그인 안 하면 v1은 v2로 받아요."),
	};
	return items.count ? @[ sources, login ] : @[ login ];
}
@end

#pragma mark - Interception

@interface OFProtocol : NSURLProtocol
@property (atomic) BOOL stopped;
@end

@implementation OFProtocol {
	NSURLSessionDataTask *_task;
	id _runLoop;
	NSArray *_modes;
	NSString *_key;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)r {
	if ([NSURLProtocol propertyForKey:kHandled inRequest:r]) return NO;
	NSString *track = OFManifestTrack(r);
	return OFInventory(r) || OFTasksRequest(r) || (track && OFUseV1(track));
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
	[NSURLProtocol setProperty:@YES forKey:kHandled inRequest:req];
	NSString *track = OFManifestTrack(req);
	if (track) return [self v1:track original:req];
	if (OFTasksRequest(req)) return [self send:req];
	req.HTTPBody = OFBody(self.request);
	NSString *key = _key = OFInventoryKey(req.HTTPBody);
	if (OFRemove(req)) OFSnapshot();
	if (OFRemove(req) || OFMode(key)) return [self send:req];
	OFAsk(^(BOOL v1) {
		OFSetMode(key, v1);
		[self send:req];
	});
}

- (void)send:(NSURLRequest *)req {
	if (self.stopped) return;
	_task = [OFSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) { [self reply:d response:r error:e]; }];
	[_task resume];
}

- (void)v1:(NSString *)track original:(NSURLRequest *)orig {
	OFToken(^(NSString *token) {
		if (self.stopped) return;
		OFLog(@"v1 %@ with %@ login", track, token ? @"own" : @"TIDAL's");
		NSString *url = [NSString stringWithFormat:@"https://api.tidal.com/v1/tracks/%@/playbackinfo?audioquality=%@&playbackmode=STREAM&assetpresentation=FULL", track,
		                                           OFQuality(orig.URL)];
		NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
		[req setValue:token ? [@"Bearer " stringByAppendingString:token] : [orig valueForHTTPHeaderField:@"Authorization"] forHTTPHeaderField:@"Authorization"];
		self->_task = [OFSession() dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
			NSInteger status = OFAs(r, NSHTTPURLResponse.class) ? ((NSHTTPURLResponse *)r).statusCode : 0;
			NSData *body = status == 200 ? OFManifest(track, d) : nil;
			if (!body) {
				OFLog(@"v1 failed for %@ (%ld %@), using v2", track, (long)status, e.localizedDescription ?: @"");
				return [self send:orig];
			}
			[self reply:body response:[[NSHTTPURLResponse alloc] initWithURL:orig.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{ @"Content-Type": @"application/vnd.api+json" }] error:nil];
		}];
		[self->_task resume];
	});
}

- (void)reply:(NSData *)body response:(NSURLResponse *)response error:(NSError *)error {
	NSHTTPURLResponse *http = OFAs(response, NSHTTPURLResponse.class);
	if (http.statusCode == 200 && OFTasksRequest(self.request)) OFLearnTasks(body);
	if (OFRemove(self.request)) {
		OFLog(@"remove %@: %ld", _key, (long)http.statusCode);
		if (http.statusCode / 100 == 2) {
			NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
			NSMutableDictionary *names = [[d dictionaryForKey:kNames] mutableCopy];
			if (_key) [names removeObjectForKey:_key];
			if (names) [d setObject:names forKey:kNames];
			if (_key) [d removeObjectForKey:[kModePrefix stringByAppendingString:_key]];
			OFCleanupSoon();
		}
	}
	if (http) {
		NSMutableDictionary *headers = [NSMutableDictionary dictionary];
		[http.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
			if ([k caseInsensitiveCompare:@"Content-Encoding"] && [k caseInsensitiveCompare:@"Content-Length"]) headers[k] = v;
		}];
		headers[@"Content-Length"] = @(body.length).stringValue;
		response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:http.statusCode HTTPVersion:@"HTTP/1.1" headerFields:headers];
	}
	[self onClient:^{
		if (self.stopped) return;
		if (error || !response) return [self.client URLProtocol:self didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
		[self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
		if (body.length) [self.client URLProtocol:self didLoadData:body];
		[self.client URLProtocolDidFinishLoading:self];
	}];
}

- (void)stopLoading {
	self.stopped = YES;
	[_task cancel];
}
@end

static NSArray *(*orig_protocolClasses)(NSURLSessionConfiguration *, SEL);
static NSArray *hook_protocolClasses(NSURLSessionConfiguration *self, SEL _cmd) {
	NSArray *a = orig_protocolClasses(self, _cmd) ?: @[];
	return [a containsObject:OFProtocol.class] ? a : [@[ OFProtocol.class ] arrayByAddingObjectsFromArray:a];
}

#pragma mark - v1 file download

static NSURL *OFDestination(NSString *ext) {
	NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
	    URLByAppendingPathComponent:@"TidalOffline"
	                    isDirectory:YES];
	[NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return [dir URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:ext.length ? ext : @"flac"]];
}

static void OFReport(id<AVAssetDownloadDelegate> d, NSURLSession *s, AVAssetDownloadTask *t, double p) {
	if (![d respondsToSelector:@selector(URLSession:assetDownloadTask:didLoadTimeRange:totalTimeRangesLoaded:timeRangeExpectedToLoad:)]) return;
	CMTimeRange loaded = CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(p, 1000));
	[d URLSession:s assetDownloadTask:t didLoadTimeRange:loaded totalTimeRangesLoaded:@[ [NSValue valueWithCMTimeRange:loaded] ]
	    timeRangeExpectedToLoad:CMTimeRangeMake(kCMTimeZero, CMTimeMakeWithSeconds(1, 1000))];
}

static void OFFetchParts(NSArray<NSURL *> *parts, NSUInteger i, NSFileHandle *out, void (^progress)(double), void (^done)(NSError *)) {
	if (i == parts.count) return done(nil);
	[[OFSession() dataTaskWithURL:parts[i] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
		NSError *err = e ?: ((NSHTTPURLResponse *)r).statusCode == 200 ? nil : [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
		if (err) return done(err);
		[out writeData:data];
		progress((double)(i + 1) / parts.count);
		OFFetchParts(parts, i + 1, out, progress, done);
	}] resume];
}

static void OFDownload(AVAssetDownloadTask *t) {
	NSArray *job = objc_getAssociatedObject(t, &kJob);
	if (!job) return;
	objc_setAssociatedObject(t, &kJob, nil, OBJC_ASSOCIATION_RETAIN);
	NSURLSession *s = job[0];
	NSArray<NSURL *> *parts = job[1];
	id<AVAssetDownloadDelegate> d = (id<AVAssetDownloadDelegate>)s.delegate;
	NSOperationQueue *q = s.delegateQueue;
	NSURL *dest = OFDestination(parts.count > 1 ? @"m4a" : parts[0].pathExtension);
	void (^finish)(NSError *) = ^(NSError *err) {
		if (err) [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
		OFLog(@"direct download %@ (%lu parts): %@", t.taskDescription, (unsigned long)parts.count, err ?: dest.lastPathComponent);
		if (!err) OFCleanupSoon();
		[q addOperationWithBlock:^{
			if (!err && [d respondsToSelector:@selector(URLSession:assetDownloadTask:didFinishDownloadingToURL:)]) [d URLSession:s assetDownloadTask:t didFinishDownloadingToURL:dest];
			if ([d respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) [d URLSession:s task:t didCompleteWithError:err];
			t.taskDescription = nil;
			[t cancel];
		}];
	};
	void (^progress)(double) = ^(double p) { [q addOperationWithBlock:^{ OFReport(d, s, t, p); }]; };
	if (parts.count > 1) {
		[NSFileManager.defaultManager createFileAtPath:dest.path contents:nil attributes:nil];
		NSFileHandle *out = [NSFileHandle fileHandleForWritingToURL:dest error:nil];
		return OFFetchParts(parts, 0, out, progress, ^(NSError *err) {
			[out closeFile];
			finish(err);
		});
	}
	dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	NSURLSessionDownloadTask *dl = [OFSession() downloadTaskWithURL:parts[0] completionHandler:^(NSURL *tmp, NSURLResponse *r, NSError *e) {
		dispatch_source_cancel(timer);
		NSError *err = e;
		if (!err && ((NSHTTPURLResponse *)r).statusCode != 200) err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil];
		if (!err) [NSFileManager.defaultManager moveItemAtURL:tmp toURL:dest error:&err];
		finish(err);
	}];
	__weak NSURLSessionDownloadTask *weak = dl;
	dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
	dispatch_source_set_event_handler(timer, ^{
		int64_t total = weak.countOfBytesExpectedToReceive;
		if (total > 0) progress((double)weak.countOfBytesReceived / total);
	});
	dispatch_resume(timer);
	[dl resume];
}

static void OFTrap(AVAssetDownloadTask *t, NSURLSession *s, NSArray<NSURL *> *parts) {
	objc_setAssociatedObject(t, &kJob, @[ s, parts ], OBJC_ASSOCIATION_RETAIN);
	Class base = object_getClass(t);
	NSString *name = [@"OF_" stringByAppendingString:NSStringFromClass(base)];
	Class sub = NSClassFromString(name);
	if (!sub) {
		sub = objc_allocateClassPair(base, name.UTF8String, 0);
		class_addMethod(sub, @selector(resume), imp_implementationWithBlock(^(AVAssetDownloadTask *me) { OFDownload(me); }), "v@:");
		objc_registerClassPair(sub);
	}
	object_setClass(t, sub);
}

typedef AVAssetDownloadTask *(*OFMakeTaskIMP)(id, SEL, AVURLAsset *, NSString *, NSData *, NSDictionary *);
static OFMakeTaskIMP orig_makeTask, orig_baseMakeTask;

static AVAssetDownloadTask *OFMakeTask(OFMakeTaskIMP orig, NSURLSession *self, SEL _cmd, AVURLAsset *asset, NSString *title, NSData *art, NSDictionary *options) {
	AVAssetDownloadTask *t = orig(self, _cmd, asset, title, art, options);
	NSString *url = asset.URL.absoluteString;
	NSArray<NSURL *> *parts;
	@synchronized (gDirect) {
		parts = url ? gDirect[url] : nil;
		if (parts) [gDirect removeObjectForKey:url];
	}
	if (t && parts) OFTrap(t, self, parts);
	return t;
}
static AVAssetDownloadTask *hook_makeTask(id self, SEL _cmd, AVURLAsset *asset, NSString *title, NSData *art, NSDictionary *options) {
	return OFMakeTask(orig_makeTask, self, _cmd, asset, title, art, options);
}
static AVAssetDownloadTask *hook_baseMakeTask(id self, SEL _cmd, AVURLAsset *asset, NSString *title, NSData *art, NSDictionary *options) {
	return OFMakeTask(orig_baseMakeTask, self, _cmd, asset, title, art, options);
}

__attribute__((constructor)) static void OFInit(void) {
	if (NSClassFromString(@"TTCore") && ![NSUserDefaults.standardUserDefaults boolForKey:@"tt.TidalOffline.enabled"]) { OFLog(@"turned off in TidalCore's settings"); return; }
	gDirect = [NSMutableDictionary dictionary];
	gTrackCollection = [NSMutableDictionary dictionary];
	OFCleanupSoon();
	[NSURLProtocol registerClass:OFProtocol.class];
	Class cfg = object_getClass(NSURLSessionConfiguration.defaultSessionConfiguration);
	Method m = class_getInstanceMethod(cfg, @selector(protocolClasses));
	if (!m) { OFLog(@"no protocolClasses on %s", class_getName(cfg)); return; }
	if (class_addMethod(cfg, @selector(protocolClasses), (IMP)hook_protocolClasses, method_getTypeEncoding(m))) orig_protocolClasses = (void *)method_getImplementation(m);
	else orig_protocolClasses = (void *)method_setImplementation(m, (IMP)hook_protocolClasses);
	SEL sel = @selector(assetDownloadTaskWithURLAsset:assetTitle:assetArtworkData:options:);
	Method mk = class_getInstanceMethod(AVAssetDownloadURLSession.class, sel), base = class_getInstanceMethod(NSURLSession.class, sel);
	if (base) orig_baseMakeTask = (OFMakeTaskIMP)method_setImplementation(base, (IMP)hook_baseMakeTask);
	if (mk && mk != base) orig_makeTask = (OFMakeTaskIMP)method_setImplementation(mk, (IMP)hook_makeTask);
	OFLog(@"loaded");
}
