#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>

#define MTLog(fmt, ...) NSLog(@"[TidalMeanings] " fmt, ##__VA_ARGS__)

static NSString *MTL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}
static id MTAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static void MTHook(Class c, SEL sel, IMP imp, IMP *orig) {
	Method m = c ? class_getInstanceMethod(c, sel) : NULL;
	if (!m) return;
	if (class_addMethod(c, sel, imp, method_getTypeEncoding(m))) *orig = method_getImplementation(m);
	else *orig = method_setImplementation(m, imp);
}

static NSString *MTFold(NSString *s) {
	s = [s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
	NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
	NSCharacterSet *keep = NSCharacterSet.alphanumericCharacterSet;
	[s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
		if ([keep characterIsMember:[ch characterAtIndex:0]]) [out appendString:ch];
	}];
	return out;
}

static NSString *MTBareTitle(NSString *t) {
	for (NSString *cut in @[ @" (", @" [", @" - " ]) {
		NSRange r = [t rangeOfString:cut];
		if (r.location != NSNotFound && r.location > 0) t = [t substringToIndex:r.location];
	}
	return t;
}

static NSString *MTFirstArtist(NSString *a) {
	for (NSString *cut in @[ @", ", @" & ", @" feat" ]) a = [a componentsSeparatedByString:cut].firstObject;
	return a;
}

static BOOL MTSameLine(NSString *a, NSString *b) {
	if (a.length < 4 || b.length < 4) return [a isEqualToString:b];
	return [a containsString:b] || [b containsString:a];
}

#pragma mark - Now playing

static NSString *gTitle, *gArtist;

#pragma mark - Genius

@interface MTMeaning : NSObject
@property (nonatomic, copy) NSString *fragment, *body, *url;
@property (nonatomic) NSInteger author;
@end
@implementation MTMeaning
@end

static NSArray<MTMeaning *> *gMeanings;
static NSString *gSongURL;
static NSUInteger gFetchId;
static void MTSync(void);
static NSUInteger gMarkGen;
static NSInteger MTMarkStyle(void) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:@"mt.mark"];
	return v ? [v integerValue] : 1;
}

// genius.com web API can hit a Cloudflare JS check (403): retried from a hidden web view on genius.com
static NSString *MTGeniusToken(void) { return [[NSUserDefaults.standardUserDefaults stringForKey:@"mt.geniusToken"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

static NSString *gGeniusStatus;

#pragma mark - Genius through a web view

@interface MTWeb : NSObject <WKNavigationDelegate>
@end

@implementation MTWeb {
	WKWebView *_web;
	NSMutableArray<NSArray *> *_pending;
	NSUInteger _gen;
	UINavigationController *_sheet;
	BOOL _asked;
}

+ (instancetype)shared {
	static MTWeb *w;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ w = [MTWeb new]; w->_pending = [NSMutableArray array]; });
	return w;
}

- (void)get:(NSURL *)url done:(void (^)(NSData *data, NSInteger status))done {
	[_pending addObject:@[ url.absoluteString, [done copy] ]];
	if (_web) { [self drain]; return; }
	NSUInteger gen = ++_gen;
	WKWebViewConfiguration *cfg = [WKWebViewConfiguration new]; // default data store: Cloudflare's cookie outlives the app
	_web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) configuration:cfg];
	_web.navigationDelegate = self;
	_web.alpha = 0.01; // in a window, so the check's timers aren't throttled
	_web.userInteractionEnabled = NO;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
		if ([scene isKindOfClass:UIWindowScene.class]) { [((UIWindowScene *)scene).windows.firstObject addSubview:_web]; break; }
	[_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://genius.com/api/search/song?q="]]];
	MTLog(@"web view: opening genius.com");
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (gen != self->_gen || !self->_pending.count) return;
		MTLog(@"web view: Cloudflare check not passed in 5 s%@", self->_asked ? @"" : @", showing it");
		if (self->_asked) [self finishAll:403];
		else [self showCheck];
	});
}

- (void)showCheck {
	_asked = YES;
	UIViewController *vc = [UIViewController new];
	vc.title = MTL(@"Genius check", @"Genius 확인");
	vc.view.backgroundColor = UIColor.systemBackgroundColor;
	vc.navigationItem.prompt = MTL(@"For lyrics meanings: pass the check once", @"가사 해설을 불러오려면 확인을 한 번 통과해 주세요");
	vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(closeCheck)];
	[_web removeFromSuperview];
	_web.frame = vc.view.bounds;
	_web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_web.alpha = 1;
	_web.userInteractionEnabled = YES;
	[vc.view addSubview:_web];
	_sheet = [[UINavigationController alloc] initWithRootViewController:vc];
	_sheet.modalInPresentation = YES;
	UIViewController *top;
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
		if ([scene isKindOfClass:UIWindowScene.class])
			for (UIWindow *w in ((UIWindowScene *)scene).windows)
				if (w.isKeyWindow) top = w.rootViewController;
	while (top.presentedViewController) top = top.presentedViewController;
	[top presentViewController:_sheet animated:YES completion:nil];
}

- (void)hideCheck {
	[_sheet dismissViewControllerAnimated:YES completion:nil];
	_sheet = nil;
}

- (void)closeCheck {
	MTLog(@"web view: check closed by the user");
	[self hideCheck];
	[self finishAll:403];
}

- (void)finishAll:(NSInteger)status {
	NSArray *all = [_pending copy];
	[_pending removeAllObjects];
	for (NSArray *p in all) ((void (^)(NSData *, NSInteger))p[1])(nil, status);
	[self closeLater];
}

- (void)closeLater {
	NSUInteger gen = _gen;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (gen != self->_gen || self->_pending.count || self->_sheet) return;
		[self->_web removeFromSuperview];
		self->_web = nil;
		self->_gen++;
	});
}

- (void)webView:(WKWebView *)web didFinishNavigation:(WKNavigation *)nav { [self drain]; }

- (void)drain {
	if (!_web || _web.isLoading) return;
	NSArray *batch = [_pending copy];
	[_pending removeAllObjects];
	for (NSArray *p in batch) {
		[_web callAsyncJavaScript:@"const r = await fetch(u, { headers: { Accept: 'application/json' } }); return [r.status, await r.text()];"
		                arguments:@{ @"u": p[0] } inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
			NSArray *a = MTAs(result, NSArray.class);
			NSInteger status = [MTAs(a.firstObject, NSNumber.class) integerValue];
			if (status == 403 || (!a && error)) {
				MTLog(@"web view: %@ -> %ld %@, waiting for the check", p[0], (long)status, error.localizedDescription ?: @"");
				[self->_pending addObject:p];
				return;
			}
			if (self->_sheet) [self hideCheck];
			((void (^)(NSData *, NSInteger))p[1])([MTAs(a.lastObject, NSString.class) dataUsingEncoding:NSUTF8StringEncoding], status);
			if (!self->_pending.count) [self closeLater];
		}];
	}
}
@end

static void MTGet(NSString *path, NSDictionary *query, void (^done)(NSDictionary *response, NSInteger status)) {
	NSString *token = MTGeniusToken();
	NSString *base = token.length ? [@"https://api.genius.com/" stringByAppendingString:path]
	                              : [@"https://genius.com/api/" stringByAppendingString:[path isEqualToString:@"search"] ? @"search/song" : path];
	NSURLComponents *c = [NSURLComponents componentsWithString:base];
	NSMutableArray *items = [NSMutableArray array];
	for (NSString *k in query) [items addObject:[NSURLQueryItem queryItemWithName:k value:query[k]]];
	c.queryItems = items;
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:c.URL cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:10];
	[req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
	[req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	if (token.length) [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
	static BOOL challenged;
	void (^finish)(NSData *, NSInteger) = ^(NSData *data, NSInteger status) {
		NSDictionary *root = data ? MTAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class) : nil;
		NSDictionary *r = status > 0 && status < 400 ? MTAs(root[@"response"], NSDictionary.class) : nil;
		if (!r) MTLog(@"%@ failed: %ld", c.URL.path, (long)status);
		done(r, status);
	};
	if (!token.length && challenged) { [MTWeb.shared get:c.URL done:finish]; return; }
	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
		NSInteger status = err ? -1 : [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
		dispatch_async(dispatch_get_main_queue(), ^{
			if (status == 403 && !token.length) {
				MTLog(@"%@: 403 from Cloudflare, asking through the web view", c.URL.path);
				challenged = YES;
				[MTWeb.shared get:c.URL done:finish];
				return;
			}
			finish(data, status);
		});
	}] resume];
}

static NSDictionary *MTSong(NSDictionary *response, NSString *title, NSString *artist) {
	NSString *wantT = MTFold(MTBareTitle(title)), *wantA = MTFold(MTFirstArtist(artist));
	NSArray *sections = MTAs(response[@"sections"], NSArray.class) ?: @[ response ?: @{} ];
	for (NSDictionary *section in sections)
		for (NSDictionary *hit in MTAs(MTAs(section, NSDictionary.class)[@"hits"], NSArray.class)) {
			NSDictionary *song = MTAs(MTAs(hit, NSDictionary.class)[@"result"], NSDictionary.class);
			NSString *t = MTFold(MTBareTitle(MTAs(song[@"title"], NSString.class) ?: @""));
			NSString *a = MTFold(MTAs(song[@"artist_names"], NSString.class) ?: MTAs(MTAs(song[@"primary_artist"], NSDictionary.class)[@"name"], NSString.class) ?: @"");
			if (MTAs(song[@"id"], NSNumber.class) && [t isEqualToString:wantT] && a.length && wantA.length && ([a containsString:wantA] || [wantA containsString:a])) return song;
		}
	return nil;
}

static void MTAddReferents(NSDictionary *response, NSMutableArray<MTMeaning *> *into) {
	for (NSDictionary *ref in MTAs(response[@"referents"], NSArray.class)) {
		NSString *fragment = MTAs(MTAs(ref, NSDictionary.class)[@"fragment"], NSString.class);
		if (!fragment.length || [ref[@"is_description"] boolValue]) continue;
		for (NSDictionary *ann in MTAs(ref[@"annotations"], NSArray.class)) {
			NSString *state = MTAs(MTAs(ann, NSDictionary.class)[@"state"], NSString.class);
			NSString *body = [MTAs(MTAs(ann[@"body"], NSDictionary.class)[@"plain"], NSString.class) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			if (!body.length || [ann[@"deleted"] boolValue] || [state isEqualToString:@"rejected"]) continue;
			if ([[into valueForKey:@"body"] containsObject:body]) continue;
			MTMeaning *m = [MTMeaning new];
			m.fragment = fragment;
			m.body = body;
			m.url = MTAs(ann[@"share_url"], NSString.class) ?: MTAs(ref[@"url"], NSString.class);
			m.author = [ann[@"verified"] boolValue] || [state isEqualToString:@"verified"] ? 0 : [state isEqualToString:@"accepted"] ? 1 : 2;
			[into addObject:m];
		}
	}
}

static void MTReferents(NSNumber *song, NSUInteger page, NSMutableArray *into, void (^done)(void)) {
	MTGet(@"referents", @{ @"song_id": song.stringValue, @"text_format": @"plain", @"per_page": @"50", @"page": @(page).stringValue }, ^(NSDictionary *r, NSInteger status) {
		MTAddReferents(r, into);
		if (MTAs(r[@"next_page"], NSNumber.class) && page < 4) MTReferents(song, page + 1, into, done);
		else done();
	});
}

static void MTFetch(void) {
	NSUInteger fid = ++gFetchId;
	gMeanings = nil;
	gMarkGen++;
	MTSync();
	NSString *title = gTitle, *artist = gArtist;
	NSString *q = [NSString stringWithFormat:@"%@ %@", MTBareTitle(title), MTFirstArtist(artist)];
	gGeniusStatus = MTL(@"Looking up…", @"찾는 중…");
	MTGet(@"search", @{ @"q": q, @"per_page": @"10" }, ^(NSDictionary *r, NSInteger status) {
		NSDictionary *hit = MTSong(r, title, artist);
		NSNumber *song = hit[@"id"];
		if (fid != gFetchId) return;
		gSongURL = MTAs(hit[@"url"], NSString.class);
		if (!song) {
			BOOL token = MTGeniusToken().length > 0;
			gGeniusStatus = r ? [NSString stringWithFormat:MTL(@"Genius has no song “%@” by %@", @"Genius에 “%@” (%@) 곡이 없어요"), title, artist]
			              : status == 401 && token ? MTL(@"Genius token is wrong", @"Genius 토큰이 틀렸어요")
			              : status == 403 && !token ? MTL(@"Genius's Cloudflare check didn't pass (it's asked again after restarting TIDAL). Or add a token above.", @"Genius의 Cloudflare 확인을 통과 못 했어요 (TIDAL을 다시 켜면 다시 떠요). 아니면 위에 토큰을 넣어주세요.")
			              : [NSString stringWithFormat:MTL(@"Genius failed (%ld)", @"Genius 요청 실패 (%ld)"), (long)status];
			MTLog(@"no Genius song for %@ — %@: %@", title, artist, gGeniusStatus);
			return;
		}
		NSMutableArray *meanings = [NSMutableArray array];
		MTReferents(song, 1, meanings, ^{
			if (fid != gFetchId) return;
			MTLog(@"%lu annotations for %@ — %@ (Genius %@)", (unsigned long)meanings.count, title, artist, song);
			gMeanings = meanings.count ? meanings : nil;
			unsigned long n = meanings.count;
			gGeniusStatus = MTL([NSString stringWithFormat:@"%lu annotations for “%@”", n, title], [NSString stringWithFormat:@"“%@” 해설 %lu개", title, n]);
			gMarkGen++;
			MTSync();
		});
	});
}

#pragma mark - DeepL

#define MTDefaults NSUserDefaults.standardUserDefaults
static NSString *MTDeepLKey(void) { return [[MTDefaults stringForKey:@"mt.deeplKey"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
static NSString *MTDeepLLang(void) { return MTDeepLKey().length ? [MTDefaults stringForKey:@"mt.deeplLang"] : nil; }

static NSArray<NSArray<NSString *> *> *MTLanguages(void) {
	return @[ @[ @"KO", @"한국어" ], @[ @"EN-US", @"English" ], @[ @"JA", @"日本語" ], @[ @"ZH-HANS", @"中文(简体)" ], @[ @"ES", @"Español" ], @[ @"FR", @"Français" ], @[ @"DE", @"Deutsch" ] ];
}

static NSMutableDictionary<NSString *, NSString *> *gTranslated;

static NSURL *MTCacheFile(void) {
	return [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"MeaningsTidal-translations.plist"];
}

static void MTLoadTranslations(void) {
	if (gTranslated) return;
	gTranslated = [NSMutableDictionary dictionaryWithContentsOfURL:MTCacheFile()] ?: [NSMutableDictionary dictionary];
}

static void MTSaveTranslations(void) {
	if (gTranslated.count > 5000) [gTranslated removeAllObjects];
	[gTranslated writeToURL:MTCacheFile() error:nil];
}
static NSString *gDeepLError;

static NSString *MTTransKey(NSString *lang, NSString *body) { return [NSString stringWithFormat:@"%@\n%@", lang, body]; }

static void MTTranslate(NSArray<NSString *> *bodies, NSString *lang, void (^done)(void)) {
	MTLoadTranslations();
	NSMutableOrderedSet *todo = [NSMutableOrderedSet orderedSet];
	for (NSString *b in bodies)
		if (!gTranslated[MTTransKey(lang, b)]) [todo addObject:b];
	NSString *key = MTDeepLKey();
	if (!todo.count || !key.length || !lang) return;
	NSString *host = [key hasSuffix:@":fx"] ? @"api-free.deepl.com" : @"api.deepl.com";
	for (NSUInteger i = 0; i < todo.count; i += 50) {
		NSArray *chunk = [todo.array subarrayWithRange:NSMakeRange(i, MIN(50, todo.count - i))];
		NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/v2/translate", host]]];
		req.HTTPMethod = @"POST";
		[req setValue:[@"DeepL-Auth-Key " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
		[req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
		req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"text": chunk, @"target_lang": lang } options:0 error:nil];
		[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
			NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
			NSDictionary *json = data ? MTAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class) : nil;
			NSArray *out = MTAs(json[@"translations"], NSArray.class);
			dispatch_async(dispatch_get_main_queue(), ^{
				if (out.count != chunk.count) {
					gDeepLError = status == 403 ? MTL(@"DeepL: wrong API key", @"DeepL: API 키가 틀렸어요")
					            : status == 456 ? MTL(@"DeepL: monthly quota used up", @"DeepL: 이번 달 사용량을 다 썼어요")
					            : [NSString stringWithFormat:@"DeepL: %@", err.localizedDescription ?: @(status)];
					MTLog(@"DeepL %ld %@", (long)status, err);
				} else {
					gDeepLError = nil;
					for (NSUInteger j = 0; j < chunk.count; j++) {
						NSString *t = MTAs(MTAs(out[j], NSDictionary.class)[@"text"], NSString.class);
						if (t.length) gTranslated[MTTransKey(lang, chunk[j])] = t;
					}
					MTSaveTranslations();
				}
				done();
			});
		}] resume];
	}
}

#pragma mark - Settings

// Colours pinned: in an iOS 26 sheet grouped-table cells sometimes come up the same colour as the sheet
@interface MTGroupedTable : UITableViewController
@end
@implementation MTGroupedTable
- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
}
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
	UIBackgroundConfiguration *b = UIBackgroundConfiguration.listGroupedCellConfiguration;
	b.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
	cell.backgroundConfiguration = b;
}
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
	NSString *text = [self respondsToSelector:@selector(tableView:titleForHeaderInSection:)] ? [(id<UITableViewDataSource>)self tableView:tv titleForHeaderInSection:s] : nil;
	if (!text) return nil;
	UITableViewHeaderFooterView *v = [tv dequeueReusableHeaderFooterViewWithIdentifier:@"h"] ?: [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"h"];
	UIListContentConfiguration *c = UIListContentConfiguration.groupedHeaderConfiguration;
	c.text = text;
	c.textProperties.color = UIColor.secondaryLabelColor;
	v.contentConfiguration = c;
	return v;
}
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
	NSString *text = [self respondsToSelector:@selector(tableView:titleForFooterInSection:)] ? [(id<UITableViewDataSource>)self tableView:tv titleForFooterInSection:s] : nil;
	if (!text) return nil;
	UITableViewHeaderFooterView *v = [tv dequeueReusableHeaderFooterViewWithIdentifier:@"f"] ?: [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"f"];
	UIListContentConfiguration *c = UIListContentConfiguration.groupedFooterConfiguration;
	c.text = text;
	c.textProperties.color = UIColor.secondaryLabelColor;
	v.contentConfiguration = c;
	return v;
}
@end

@interface MTLanguagePicker : MTGroupedTable
@end
@implementation MTLanguagePicker
- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = MTL(@"Translate into", @"번역할 언어");
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MTLanguages().count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"l"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"l"];
	NSString *code = ip.row ? MTLanguages()[ip.row - 1][0] : nil, *lang = [MTDefaults stringForKey:@"mt.deeplLang"];
	UIListContentConfiguration *c = UIListContentConfiguration.cellConfiguration;
	c.text = ip.row ? MTLanguages()[ip.row - 1][1] : MTL(@"Off (original)", @"끄기 (원문)");
	cell.contentConfiguration = c;
	cell.accessoryType = (code ? [code isEqualToString:lang] : !lang) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
	return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[MTDefaults setObject:ip.row ? MTLanguages()[ip.row - 1][0] : nil forKey:@"mt.deeplLang"];
	[self.navigationController popViewControllerAnimated:YES];
}
@end

@interface MTSettings : MTGroupedTable
@end
@implementation MTSettings
- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = MTL(@"Lyrics meanings", @"가사 해설");
	if (self.navigationController.viewControllers.firstObject == self)
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
}
- (void)close {
	[self dismissViewControllerAnimated:YES completion:^{ [NSNotificationCenter.defaultCenter postNotificationName:@"MTSettingsClosed" object:nil]; }];
}
- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger[]){ 3, 1, 2 }[s]; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
	return @[ MTL(@"Lines with meanings", @"해설 있는 줄 표시"), @"Genius", MTL(@"DeepL translation", @"DeepL 번역") ][s];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
	if (s == 0) return MTL(@"Hold a line of the lyrics to read what it means.", @"가사 줄을 길게 누르면 해설을 볼 수 있어요.");
	if (s == 1) {
		NSString *help = MTL(@"Optional. Works without one; a token is only needed if Genius keeps blocking (free: genius.com/api-clients → New API Client, any name and website → Generate Access Token).",
		                     @"없어도 돼요. Genius가 계속 막을 때만 필요해요 (무료: genius.com/api-clients → New API Client, 이름·웹사이트 아무거나 → Generate Access Token).");
		return gGeniusStatus ? [NSString stringWithFormat:@"%@\n\n%@", gGeniusStatus, help] : help;
	}
	return MTL(@"Translates Genius's annotations with your own DeepL API key (deepl.com → Account → API keys; free keys ending in :fx work). The key is stored on this iPhone only, unencrypted.",
	           @"Genius 해설을 내 DeepL API 키로 번역해요 (deepl.com → 계정 → API 키, :fx로 끝나는 무료 키도 돼요). 키는 이 아이폰에만 저장되고 암호화되지 않아요.");
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"s"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"s"];
	UIListContentConfiguration *c = UIListContentConfiguration.valueCellConfiguration;
	if (ip.section == 0) {
		c.text = @[ MTL(@"Off", @"표시 안 함"), MTL(@"Dotted underline", @"점선 밑줄"), MTL(@"Bar at the side", @"옆 세로 막대") ][ip.row];
		c.image = @[ [UIImage systemImageNamed:@"nosign"], [UIImage systemImageNamed:@"text.line.last.and.arrowtriangle.forward"], [UIImage systemImageNamed:@"text.alignleft"] ][ip.row];
		cell.contentConfiguration = c;
		cell.accessoryType = ip.row == MTMarkStyle() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
		return cell;
	}
	if (ip.section == 1) {
		NSString *token = MTGeniusToken();
		c.text = MTL(@"Access token", @"액세스 토큰");
		c.secondaryText = token.length ? [@"••••" stringByAppendingString:[token substringFromIndex:MAX(0, (NSInteger)token.length - 6)]] : MTL(@"Not set", @"없음");
	} else if (ip.row == 0) {
		NSString *key = MTDeepLKey();
		c.text = MTL(@"API key", @"API 키");
		c.secondaryText = key.length ? [@"••••" stringByAppendingString:[key substringFromIndex:MAX(0, (NSInteger)key.length - 6)]] : MTL(@"Not set", @"없음");
	} else {
		NSString *lang = MTDeepLLang();
		c.text = MTL(@"Translate into", @"번역할 언어");
		c.secondaryText = MTL(@"Off", @"끄기");
		for (NSArray *l in MTLanguages())
			if ([l[0] isEqualToString:lang]) c.secondaryText = l[1];
		if (!MTDeepLKey().length) c.textProperties.color = UIColor.secondaryLabelColor;
	}
	cell.contentConfiguration = c;
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (ip.section == 0) {
		[NSUserDefaults.standardUserDefaults setInteger:ip.row forKey:@"mt.mark"];
		gMarkGen++;
		MTSync();
		[tv reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
		return;
	}
	if (ip.section == 1) { [self askGeniusToken]; return; }
	if (ip.row == 1) {
		if (MTDeepLKey().length) [self.navigationController pushViewController:[[MTLanguagePicker alloc] initWithStyle:UITableViewStyleInsetGrouped] animated:YES];
		else [self askKey];
		return;
	}
	[self askKey];
}
- (void)askGeniusToken {
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:MTL(@"Genius access token", @"Genius 액세스 토큰") message:nil preferredStyle:UIAlertControllerStyleAlert];
	[ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.text = MTGeniusToken();
		tf.placeholder = @"Client Access Token";
		tf.autocorrectionType = UITextAutocorrectionTypeNo;
		tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
		tf.clearButtonMode = UITextFieldViewModeWhileEditing;
	}];
	__weak MTSettings *ws = self;
	__weak UIAlertController *wac = ac;
	[ac addAction:[UIAlertAction actionWithTitle:MTL(@"Cancel", @"취소") style:UIAlertActionStyleCancel handler:nil]];
	[ac addAction:[UIAlertAction actionWithTitle:MTL(@"Save", @"저장") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		NSString *token = [wac.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		[MTDefaults setObject:token.length ? token : nil forKey:@"mt.geniusToken"];
		if (gTitle) MTFetch();
		[ws.tableView reloadData];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [ws.tableView reloadData]; });
	}]];
	[self presentViewController:ac animated:YES completion:nil];
}
- (void)askKey {
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:MTL(@"DeepL API key", @"DeepL API 키") message:nil preferredStyle:UIAlertControllerStyleAlert];
	[ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.text = MTDeepLKey();
		tf.placeholder = @"xxxxxxxx-xxxx-…:fx";
		tf.autocorrectionType = UITextAutocorrectionTypeNo;
		tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
		tf.clearButtonMode = UITextFieldViewModeWhileEditing;
	}];
	__weak MTSettings *ws = self;
	__weak UIAlertController *wac = ac;
	[ac addAction:[UIAlertAction actionWithTitle:MTL(@"Cancel", @"취소") style:UIAlertActionStyleCancel handler:nil]];
	[ac addAction:[UIAlertAction actionWithTitle:MTL(@"Save", @"저장") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		NSString *key = [wac.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
		[MTDefaults setObject:key.length ? key : nil forKey:@"mt.deeplKey"];
		if (key.length && ![MTDefaults stringForKey:@"mt.deeplLang"]) [MTDefaults setObject:MTL(@"EN-US", @"KO") forKey:@"mt.deeplLang"];
		gDeepLError = nil;
		[ws.tableView reloadData];
	}]];
	[self presentViewController:ac animated:YES completion:nil];
}
@end

@implementation MTSettings (TTCore)
+ (NSArray *)ttSections {
	NSMutableArray *langs = [NSMutableArray arrayWithObject:@[ NSNull.null, MTL(@"Off (original)", @"끄기 (원문)") ]];
	[langs addObjectsFromArray:MTLanguages()];
	return @[
		@{ @"header": MTL(@"Lines with meanings", @"해설 있는 줄 표시"),
		   @"items": @[ @{ @"type": @"choice", @"key": @"mt.mark", @"default": @1, @"title": MTL(@"Mark", @"표시"),
		                   @"options": @[ @[ @0, MTL(@"Off", @"표시 안 함") ], @[ @1, MTL(@"Dotted underline", @"점선 밑줄") ], @[ @2, MTL(@"Bar at the side", @"옆 세로 막대") ] ],
		                   @"set": ^(id v) {
			                   gMarkGen++;
			                   MTSync();
		                   } } ],
		   @"footer": MTL(@"Hold a line of the lyrics to read what it means.", @"가사 줄을 길게 누르면 해설을 볼 수 있어요.") },
		@{ @"header": @"Genius",
		   @"items": @[ @{ @"type": @"text", @"key": @"mt.geniusToken", @"secure": @YES, @"placeholder": @"Client Access Token", @"title": MTL(@"Access token", @"액세스 토큰"),
		                   @"set": ^(id v) {
			                   if (gTitle) MTFetch();
		                   } } ],
		   @"footer": ^NSString * {
			   NSString *help = MTL(@"Optional. Works without one; a token is only needed if Genius keeps blocking (free: genius.com/api-clients → New API Client, any name and website → Generate Access Token).",
			                        @"없어도 돼요. Genius가 계속 막을 때만 필요해요 (무료: genius.com/api-clients → New API Client, 이름·웹사이트 아무거나 → Generate Access Token).");
			   return gGeniusStatus ? [NSString stringWithFormat:@"%@\n\n%@", gGeniusStatus, help] : help;
		   } },
		@{ @"header": MTL(@"DeepL translation", @"DeepL 번역"),
		   @"items": @[
			   @{ @"type": @"text", @"key": @"mt.deeplKey", @"secure": @YES, @"placeholder": @"xxxxxxxx-xxxx-…:fx", @"title": MTL(@"API key", @"API 키"),
			      @"set": ^(id v) {
				      if (v && ![MTDefaults stringForKey:@"mt.deeplLang"]) [MTDefaults setObject:MTL(@"EN-US", @"KO") forKey:@"mt.deeplLang"];
				      gDeepLError = nil;
			      } },
			   @{ @"type": @"choice", @"key": @"mt.deeplLang", @"title": MTL(@"Translate into", @"번역할 언어"), @"options": langs,
			      @"enabled": ^BOOL { return MTDeepLKey().length > 0; } },
		   ],
		   @"footer": MTL(@"Translates Genius's annotations with your own DeepL API key (deepl.com → Account → API keys; free keys ending in :fx work). The key is stored on this iPhone only, unencrypted.",
		                  @"Genius 해설을 내 DeepL API 키로 번역해요 (deepl.com → 계정 → API 키, :fx로 끝나는 무료 키도 돼요). 키는 이 아이폰에만 저장되고 암호화되지 않아요.") },
	];
}
@end

static void MTOpenSettings(UIViewController *from) {
	while (from.presentedViewController) from = from.presentedViewController;
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[MTSettings alloc] initWithStyle:UITableViewStyleInsetGrouped]];
	[from presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Card

@interface MTCard : UIViewController
@property (nonatomic, copy) NSArray<MTMeaning *> *items;
@end

@implementation MTCard {
	UIScrollView *_scroll;
	UIStackView *_stack;
	UIStackView *_footer;
	UILabel *_source;
}

static UIView *MTBadge(NSInteger author) {
	NSString *symbol = @[ @"checkmark.seal.fill", @"checkmark.circle", @"person.2" ][author];
	NSString *title = @[ MTL(@"Artist", @"아티스트"), MTL(@"Genius editors", @"Genius 편집자"), MTL(@"Community", @"커뮤니티") ][author];
	UIColor *color = @[ UIColor.systemYellowColor, UIColor.systemGreenColor, UIColor.systemGrayColor ][author];
	UIButtonConfiguration *c = UIButtonConfiguration.tintedButtonConfiguration;
	c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
	c.baseForegroundColor = color;
	c.baseBackgroundColor = color;
	c.image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold]];
	c.imagePadding = 4;
	c.contentInsets = NSDirectionalEdgeInsetsMake(4, 9, 4, 10);
	c.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] }];
	UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
	b.userInteractionEnabled = NO;
	UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ b, [UIView new] ]];
	return row;
}

static UILabel *MTLabel(NSString *text, UIFont *font, UIColor *color) {
	UILabel *l = [UILabel new];
	l.text = text;
	l.font = font;
	l.textColor = color;
	l.numberOfLines = 0;
	l.adjustsFontForContentSizeCategory = YES;
	return l;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
	self.view.backgroundColor = UIColor.clearColor;
	UIView *cv = self.view;

	UIScrollView *scroll = _scroll = [UIScrollView new];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.showsVerticalScrollIndicator = NO;
	[cv addSubview:scroll];
	_stack = [UIStackView new];
	_stack.axis = UILayoutConstraintAxisVertical;
	_stack.spacing = 12;
	_stack.translatesAutoresizingMaskIntoConstraints = NO;
	[scroll addSubview:_stack];

	_source = MTLabel(nil, [UIFont systemFontOfSize:13 weight:UIFontWeightMedium], UIColor.tertiaryLabelColor);
	[_source setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	UIButton *gear = [UIButton systemButtonWithImage:[UIImage systemImageNamed:@"gearshape"] target:self action:@selector(settings)];
	gear.tintColor = UIColor.secondaryLabelColor;
	UIButtonConfiguration *lc = UIButtonConfiguration.plainButtonConfiguration;
	lc.attributedTitle = [[NSAttributedString alloc] initWithString:MTL(@"View on Genius", @"Genius에서 보기") attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold] }];
	lc.baseForegroundColor = UIColor.systemGreenColor;
	lc.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 0);
	UIButton *link = [UIButton buttonWithConfiguration:lc primaryAction:nil];
	[link addTarget:self action:@selector(openGenius) forControlEvents:UIControlEventTouchUpInside];
	link.hidden = !self.linkURL;
	UIStackView *footer = [[UIStackView alloc] initWithArrangedSubviews:@[ _source, gear, link ]];
	footer.spacing = 12;
	footer.alignment = UIStackViewAlignmentCenter;
	footer.translatesAutoresizingMaskIntoConstraints = NO;
	[cv addSubview:footer];
	_footer = footer;

	[NSLayoutConstraint activateConstraints:@[
		[scroll.topAnchor constraintEqualToAnchor:cv.topAnchor constant:30],
		[scroll.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor],
		[_stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
		[_stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
		[_stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:24],
		[_stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-24],
		[footer.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:14],
		[footer.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:24],
		[footer.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
		[footer.bottomAnchor constraintEqualToAnchor:cv.safeAreaLayoutGuide.bottomAnchor constant:-8],
	]];
	[self fill];
	[self translate];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsClosed) name:@"MTSettingsClosed" object:nil];
	[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsClosed) name:@"TTSettingsClosed" object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (NSString *)linkURL { return self.items.count == 1 ? self.items.firstObject.url : gSongURL ?: self.items.firstObject.url; }

- (void)fill {
	for (UIView *v in _stack.arrangedSubviews) [v removeFromSuperview];
	NSString *lang = MTDeepLLang();
	BOOL translated = NO;
	NSString *lastFragment;
	for (MTMeaning *m in self.items) {
		if (_stack.arrangedSubviews.count) {
			UIView *line = [UIView new];
			line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
			[line.heightAnchor constraintEqualToConstant:1 / UIScreen.mainScreen.scale].active = YES;
			[_stack addArrangedSubview:line];
			[_stack setCustomSpacing:18 afterView:_stack.arrangedSubviews[_stack.arrangedSubviews.count - 2]];
			[_stack setCustomSpacing:18 afterView:line];
		}
		if (![m.fragment isEqualToString:lastFragment]) {
			UIFont *big = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
			[_stack addArrangedSubview:MTLabel([NSString stringWithFormat:@"“%@”", m.fragment], [UIFontMetrics.defaultMetrics scaledFontForFont:big], UIColor.labelColor)];
		}
		lastFragment = m.fragment;
		[_stack addArrangedSubview:MTBadge(m.author)];
		NSString *t = lang ? gTranslated[MTTransKey(lang, m.body)] : nil;
		translated |= t != nil;
		UILabel *body = MTLabel(t ?: m.body, [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline], [UIColor colorWithWhite:1 alpha:0.82]);
		NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
		ps.lineSpacing = 3;
		body.attributedText = [[NSAttributedString alloc] initWithString:body.text attributes:@{ NSParagraphStyleAttributeName: ps, NSFontAttributeName: body.font, NSForegroundColorAttributeName: body.textColor }];
		[_stack addArrangedSubview:body];
	}
	[self.view setNeedsLayout];
	_source.text = gDeepLError ?: translated ? MTL(@"Genius · translated by DeepL", @"Genius · 번역 DeepL") : @"Genius";
}

- (void)translate {
	__weak MTCard *ws = self;
	MTTranslate([self.items valueForKey:@"body"], MTDeepLLang(), ^{ [ws fill]; });
}

- (void)settingsClosed {
	gDeepLError = nil;
	[self fill];
	[self translate];
}

- (CGFloat)fittingHeight {
	CGFloat w = self.view.bounds.size.width ?: UIScreen.mainScreen.bounds.size.width;
	CGFloat stack = [_stack systemLayoutSizeFittingSize:CGSizeMake(w - 48, 0) withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
	return 30 + stack + 14 + 44 + 8;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	static CGFloat last;
	CGFloat h = [self fittingHeight];
	if (fabs(h - last) < 1) return;
	last = h;
	[self.sheetPresentationController animateChanges:^{ [self.sheetPresentationController invalidateDetents]; }];
}

- (void)settings {
	Class core = NSClassFromString(@"TTCore");
	if (core) [core performSelector:@selector(openTweak:) withObject:@"TidalMeanings"];
	else MTOpenSettings(self);
}

- (void)openGenius {
	NSURL *url = [NSURL URLWithString:self.linkURL];
	if (url) [self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
}
@end

#pragma mark - Player

static __weak UIViewController *gHost;
static NSTimer *gPoll;

static void *MTIvar(id obj, const char *name) {
	Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
	return iv ? (char *)(__bridge void *)obj + ivar_getOffset(iv) : NULL;
}

// ivars may not be listed (Swift generic superclass)
static id MTViewModel(UIViewController *host) {
	void **slot = MTIvar(host, "viewModel");
	if (slot) return (__bridge id)*slot;
	Class vmClass = objc_getClass("_TtC10NowPlaying19NowPlayingViewModel");
	void **words = (__bridge void *)host;
	size_t n = class_getInstanceSize(object_getClass(host)) / sizeof(void *);
	for (size_t i = 1; vmClass && i < n; i++)
		if (words[i] && malloc_size(words[i]) >= 16 && object_getClass((__bridge id)words[i]) == vmClass) return (__bridge id)words[i];
	return nil;
}

static BOOL MTLyricsShown(void) {
	UIViewController *h = gHost;
	if (!h.viewIfLoaded.window || h.presentedViewController || h.isBeingDismissed) return NO;
	bool *on = MTIvar(MTViewModel(h), "_isShowingLyrics");
	return on && *on;
}

static void MTPresent(NSArray<MTMeaning *> *items);

static void MTPresent(NSArray<MTMeaning *> *items) {
	MTCard *card = [MTCard new];
	card.items = items;
	__weak MTCard *wc = card;
	UISheetPresentationControllerDetent *fit = [UISheetPresentationControllerDetent customDetentWithIdentifier:@"fit" resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> ctx) {
		return MIN([wc fittingHeight], ctx.maximumDetentValue * 0.5);
	}];
	card.sheetPresentationController.detents = @[ fit, UISheetPresentationControllerDetent.largeDetent ];
	card.sheetPresentationController.prefersGrabberVisible = YES;
	card.sheetPresentationController.prefersScrollingExpandsWhenScrolledToEdge = NO;
	[gHost presentViewController:card animated:YES completion:nil];
}

#pragma mark - Holding a line of RadiantTidal's lyrics

// RadiantTidal's lyrics view, read by its ivar and property names only (no shared code):
// RLLyricsView { UIScrollView *_scroll; NSMutableArray<RLLineView *> *_lineViews; },
// RLLineView.line.main = syllables, each with .text.
static id MTIvarObj(id obj, const char *name) {
	Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
	return iv ? object_getIvar(obj, iv) : nil;
}

static UIView *MTFindRL(UIView *v) {
	static Class rl;
	if (!rl) rl = objc_getClass("RLLyricsView");
	if (!rl || !v) return nil;
	if ([v isKindOfClass:rl]) return v;
	for (UIView *s in v.subviews) {
		UIView *f = MTFindRL(s);
		if (f) return f;
	}
	return nil;
}

static NSArray<MTMeaning *> *MTMeaningsForLine(NSString *line) {
	NSString *want = MTFold(line);
	NSMutableArray *out = [NSMutableArray array];
	for (MTMeaning *m in gMeanings)
		for (NSString *f in [m.fragment componentsSeparatedByString:@"\n"])
			if (MTSameLine(want, MTFold(f))) { [out addObject:m]; break; }
	return [out sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(MTMeaning *a, MTMeaning *b) {
		return a.author < b.author ? NSOrderedAscending : a.author > b.author ? NSOrderedDescending : NSOrderedSame;
	}];
}

@interface MTHold : NSObject
@end
@implementation MTHold
+ (void)held:(UILongPressGestureRecognizer *)g {
	if (g.state != UIGestureRecognizerStateBegan) return;
	UIScrollView *scroll = (UIScrollView *)g.view;
	CGPoint p = [g locationInView:scroll];
	NSString *text;
	for (UIView *lv in MTIvarObj(MTFindRL(gHost.viewIfLoaded), "_lineViews"))
		if (CGRectContainsPoint(CGRectInset(lv.frame, -8, -12), p)) {
			NSArray *syl = [[lv valueForKey:@"line"] valueForKey:@"main"];
			text = [[syl valueForKey:@"text"] componentsJoinedByString:@""];
			break;
		}
	NSArray *items = text.length ? MTMeaningsForLine(text) : nil;
	MTLog(@"held \"%@\": %lu meanings", text, (unsigned long)items.count);
	if (!items.count) return;
	for (UIGestureRecognizer *o in scroll.gestureRecognizers)
		if ([o isKindOfClass:UITapGestureRecognizer.class] && o.enabled) { o.enabled = NO; o.enabled = YES; }
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
	MTPresent(items);
}
@end

static void MTAttachHold(void) {
	UIScrollView *scroll = MTIvarObj(MTFindRL(gHost.viewIfLoaded), "_scroll");
	if (![scroll isKindOfClass:UIScrollView.class] || objc_getAssociatedObject(scroll, @selector(held:))) return;
	UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:MTHold.class action:@selector(held:)];
	[scroll addGestureRecognizer:g];
	objc_setAssociatedObject(scroll, @selector(held:), g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	MTLog(@"long press on RadiantTidal's lyrics");
}

static NSArray<NSValue *> *MTRows(UIView *lv) {
	NSArray *slots = MTIvarObj(MTIvarObj(lv, "_main"), "_slots");
	Ivar rectIvar = class_getInstanceVariable(objc_getClass("RLSlot"), "rect");
	if (![slots isKindOfClass:NSArray.class] || !rectIvar) return nil;
	NSMutableArray<NSValue *> *rows = [NSMutableArray array];
	for (id slot in slots) {
		CGRect r = *(CGRect *)((char *)(__bridge void *)slot + ivar_getOffset(rectIvar));
		if (r.size.width <= 0) continue;
		NSUInteger last = rows.count - 1;
		if (rows.count && fabs(rows[last].CGRectValue.origin.y - r.origin.y) < 1) rows[last] = [NSValue valueWithCGRect:CGRectUnion(rows[last].CGRectValue, r)];
		else [rows addObject:[NSValue valueWithCGRect:r]];
	}
	return rows;
}

// Blurred like RadiantTidal: shape moved out of the clip box, only its shadow lands in place
static const CGFloat kMarkMargin = 24;

static CALayer *MTMarkLayer(UIView *lv, NSInteger style, BOOL byArtist) {
	NSArray<NSValue *> *rows = MTRows(lv);
	if (!rows.count) return nil;
	UIBezierPath *path = [UIBezierPath bezierPath];
	CAShapeLayer *l = [CAShapeLayer layer];
	l.fillColor = nil;
	l.lineCap = kCALineCapRound;
	l.strokeColor = UIColor.clearColor.CGColor;
	l.shadowColor = UIColor.whiteColor.CGColor;
	BOOL right = [[[lv valueForKey:@"line"] valueForKey:@"right"] boolValue];
	if (style == 1) {
		for (NSValue *v in rows) {
			CGRect r = v.CGRectValue;
			[path moveToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r) - 2)];
			[path addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - 2)];
		}
		l.lineWidth = 2;
		l.lineDashPattern = @[ @0.01, @5 ];
	} else {
		CGFloat top = CGRectGetMinY(rows.firstObject.CGRectValue) + 6, bottom = CGRectGetMaxY(rows.lastObject.CGRectValue) - 6;
		CGFloat x = right ? CGRectGetMaxX(lv.bounds) + 10 : -10;
		[path moveToPoint:CGPointMake(x, top)];
		[path addLineToPoint:CGPointMake(x, bottom)];
		l.lineWidth = 3;
	}
	l.path = path.CGPath;
	CALayer *box = [CALayer layer];
	box.frame = CGRectInset(lv.bounds, -kMarkMargin, -kMarkMargin);
	box.masksToBounds = YES;
	l.frame = CGRectOffset(lv.bounds, kMarkMargin, kMarkMargin);
	[box addSublayer:l];
	[box setValue:@(byArtist) forKey:@"mtArtist"];
	return box;
}

static char kMarkGen, kMarkLayer;
static __weak UIView *gRL;

static void MTDimMarks(void) {
	for (UIView *lv in MTIvarObj(gRL, "_lineViews")) {
		CALayer *box = objc_getAssociatedObject(lv, &kMarkLayer);
		CAShapeLayer *l = box.sublayers.firstObject;
		CGFloat *blurp = MTIvar(lv, "_blur");
		BOOL *activep = MTIvar(lv, "_active");
		if (!l || !blurp || !activep) continue;
		CGFloat blur = *blurp;
		BOOL artist = [[box valueForKey:@"mtArtist"] boolValue];
		CGFloat alpha = *activep ? (artist ? 0.9 : 0.55) : (artist ? 0.45 : 0.3);
		NSArray *state = @[ @(alpha), @(blur) ];
		if ([[box valueForKey:@"mtState"] isEqual:state]) continue;
		[box setValue:state forKey:@"mtState"];
		CGFloat shift = blur > 0 ? box.bounds.size.width + 4 * blur + 20 : 0;
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		l.strokeColor = [UIColor colorWithWhite:1 alpha:alpha].CGColor;
		l.transform = CATransform3DMakeTranslation(-shift, 0, 0);
		l.shadowOffset = CGSizeMake(shift, 0);
		l.shadowRadius = blur;
		l.shadowOpacity = blur > 0 ? 1 : 0;
		[CATransaction commit];
	}
}

static void MTMarkLines(void) {
	NSInteger style = gMeanings.count ? MTMarkStyle() : 0;
	gRL = MTFindRL(gHost.viewIfLoaded);
	for (UIView *lv in MTIvarObj(gRL, "_lineViews")) {
		if ([objc_getAssociatedObject(lv, &kMarkGen) unsignedIntegerValue] == gMarkGen + 1) continue;
		objc_setAssociatedObject(lv, &kMarkGen, @(gMarkGen + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[(CALayer *)objc_getAssociatedObject(lv, &kMarkLayer) removeFromSuperlayer];
		objc_setAssociatedObject(lv, &kMarkLayer, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		if (!style) continue;
		NSString *text = [[[[lv valueForKey:@"line"] valueForKey:@"main"] valueForKey:@"text"] componentsJoinedByString:@""];
		NSArray<MTMeaning *> *items = MTMeaningsForLine(text);
		CALayer *mark = items.count ? MTMarkLayer(lv, style, items.firstObject.author == 0) : nil;
		if (!mark) continue;
		[lv.layer addSublayer:mark];
		objc_setAssociatedObject(lv, &kMarkLayer, mark, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
}

@interface MTButtonTarget : NSObject
@end
@implementation MTButtonTarget
+ (void)open { MTPresent(gMeanings); }
@end

static UIButton *gButton;

static UIButton *MTMakeButton(void) {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	UIImageSymbolConfiguration *sc = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
	[b setImage:[UIImage systemImageNamed:@"quote.bubble" withConfiguration:sc] forState:UIControlStateNormal];
	b.tintColor = UIColor.whiteColor;
	b.accessibilityLabel = MTL(@"Lyrics meanings", @"가사 해설");
	UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
	blur.userInteractionEnabled = NO;
	blur.frame = CGRectMake(0, 0, 40, 40);
	blur.layer.cornerRadius = 20;
	blur.clipsToBounds = YES;
	[b insertSubview:blur atIndex:0];
	[b addTarget:MTButtonTarget.class action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
	return b;
}

static void MTSync(void) {
	BOOL shown = MTLyricsShown();
	if (shown) {
		MTAttachHold();
		MTMarkLines();
	}
	UIView *hv = gHost.viewIfLoaded;
	if (!shown || gRL.window || !gMeanings.count) { [gButton removeFromSuperview]; return; }
	if (!gButton) gButton = MTMakeButton();
	if (gButton.superview != hv) [hv addSubview:gButton];
	gButton.frame = CGRectMake(hv.bounds.size.width - 16 - 40, hv.safeAreaInsets.top + 64, 40, 40);
	[hv bringSubviewToFront:gButton];
}

@interface MTTicker : NSObject
@end
@implementation MTTicker
+ (void)tick { if (gRL.window) MTDimMarks(); }
@end

static CADisplayLink *gLink;

static void MTPollUpdate(void) {
	if (gHost && !gPoll) {
		gPoll = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { MTSync(); }];
		gLink = [CADisplayLink displayLinkWithTarget:MTTicker.class selector:@selector(tick)];
		[gLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	}
	if (!gHost) { [gPoll invalidate]; gPoll = nil; [gLink invalidate]; gLink = nil; }
	MTSync();
}

// Not the footer: RadiantTidal would wrap it again on every visit
@interface MTSettingsTarget : NSObject
@end
static __weak UIViewController *gSettingsScene;
@implementation MTSettingsTarget
+ (void)open:(UIBarButtonItem *)item { MTOpenSettings(gSettingsScene); }
@end

static UITableView *MTFindTable(UIView *v) {
	if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
	for (UIView *s in v.subviews) {
		UITableView *t = MTFindTable(s);
		if (t) return t;
	}
	return nil;
}

static void MTAddSettingsButton(UIViewController *vc) {
	gSettingsScene = vc;
	UINavigationItem *ni = vc.navigationItem;
	for (UIBarButtonItem *i in ni.rightBarButtonItems)
		if (i.action == @selector(open:)) return;
	UIBarButtonItem *b = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"quote.bubble"] style:UIBarButtonItemStylePlain target:MTSettingsTarget.class action:@selector(open:)];
	b.accessibilityLabel = MTL(@"Lyrics meanings settings", @"가사 해설 설정");
	ni.rightBarButtonItems = [ni.rightBarButtonItems ?: @[] arrayByAddingObject:b];
	BOOL barShown = vc.navigationController && !vc.navigationController.navigationBarHidden;
	MTLog(@"settings button in %s, nav bar %@", class_getName(object_getClass(vc)), barShown ? @"shown" : @"HIDDEN");
	if (barShown) return;
	UITableView *table = MTFindTable(vc.viewIfLoaded);
	if (!table || table.tableHeaderView) return;
	UIButtonConfiguration *c = [UIButtonConfiguration tintedButtonConfiguration];
	c.title = MTL(@"Lyrics Meanings Settings", @"가사 해설 설정");
	c.image = [UIImage systemImageNamed:@"quote.bubble"];
	c.imagePadding = 8;
	UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, 76)];
	UIButton *hb = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { MTOpenSettings(gSettingsScene); }]];
	hb.frame = CGRectMake(16, 14, header.bounds.size.width - 32, 48);
	hb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	[header addSubview:hb];
	table.tableHeaderView = header;
}

static void (*orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void hook_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewDidAppear(self, _cmd, animated);
	if ([self isKindOfClass:objc_getClass("_TtC4WiMP13SettingsScene")]) {
		if (!NSClassFromString(@"TTCore")) MTAddSettingsButton(self);
		return;
	}
	if (!strstr(class_getName(object_getClass(self)), "NowPlayingHostingController")) return;
	gHost = self;
	MTLog(@"player shown, lyrics flag %s", MTIvar(MTViewModel(self), "_isShowingLyrics") ? "found" : "MISSING");
	MTPollUpdate();
}

static void (*orig_viewDidDisappear)(UIViewController *, SEL, BOOL);
static void hook_viewDidDisappear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewDidDisappear(self, _cmd, animated);
	if (self != gHost || self.presentedViewController) return;
	gHost = nil;
	MTPollUpdate();
}

static void (*orig_setInfo)(MPNowPlayingInfoCenter *, SEL, NSDictionary *);
static void hook_setInfo(MPNowPlayingInfoCenter *self, SEL _cmd, NSDictionary *info) {
	orig_setInfo(self, _cmd, info);
	NSDictionary *copy = [info copy];
	dispatch_async(dispatch_get_main_queue(), ^{
		NSString *title = copy[MPMediaItemPropertyTitle], *artist = copy[MPMediaItemPropertyArtist];
		if (title.length && artist.length && !([title isEqualToString:gTitle] && [artist isEqualToString:gArtist])) {
			gTitle = title;
			gArtist = artist;
			MTFetch();
		}
	});
}

__attribute__((constructor)) static void MTInit(void) {
	if (NSClassFromString(@"TTCore") && ![NSUserDefaults.standardUserDefaults boolForKey:@"tt.TidalMeanings.enabled"]) return MTLog(@"turned off in TidalCore's settings");
	MTHook(MPNowPlayingInfoCenter.class, @selector(setNowPlayingInfo:), (IMP)hook_setInfo, (IMP *)&orig_setInfo);
	MTHook(UIViewController.class, @selector(viewDidAppear:), (IMP)hook_viewDidAppear, (IMP *)&orig_viewDidAppear);
	MTHook(UIViewController.class, @selector(viewDidDisappear:), (IMP)hook_viewDidDisappear, (IMP *)&orig_viewDidDisappear);
	MTLog(@"loaded");
}
