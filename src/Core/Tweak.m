#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <OSLog/OSLog.h>

#define TTLog(fmt, ...) NSLog(@"[TidalCore] " fmt, ##__VA_ARGS__)

#ifndef TT_BUILD
#define TT_BUILD @"dev"
#endif
static NSString *const kRepo = @"seomin0610/Perigee";

static NSString *TTL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}
static id TTAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

// dylib, English, Korean, class with +ttSections, icon, can be turned off, what it does (English, Korean), on by default
static NSArray<NSArray *> *TTTweaks(void) {
	return @[
		@[ @"TidalLockLyrics", @"Lock Screen", @"잠금화면", @"LLSettings", @"lock.iphone", @YES,
		   @"Lyrics and moving covers on the lock screen", @"잠금화면 가사와 움직이는 커버", @NO ],
		@[ @"TidalMeanings", @"Lyrics Meanings", @"가사 해설", @"MTSettings", @"quote.bubble", @YES,
		   @"Genius annotations for lyric lines", @"가사 줄별 Genius 해설", @NO ],
		@[ @"TidalHaptics", @"Music Haptics", @"음악 햅틱", @"HTSettings", @"iphone.radiowaves.left.and.right", @YES,
		   @"Apple's haptic tracks while you listen", @"듣는 곡에 맞춘 Apple 햅틱", @NO ],
		@[ @"TidalKoreanSearch", @"Korean Search", @"한글 검색", @"KSSettings", @"magnifyingglass", @YES,
		   @"Find songs by their Korean names", @"한글 이름으로 곡 찾기", @NO ],
		@[ @"TidalLiquidTab", @"Liquid Glass Tab Bar", @"리퀴드 글래스 탭 바", @"", @"dock.rectangle", @YES,
		   @"iOS 26 floating tab bar", @"iOS 26 떠 있는 탭 바", @NO ],
		@[ @"TidalPrivacy", @"Privacy", @"개인정보 보호", @"PVSettings", @"hand.raised", @YES,
		   @"Blocks TIDAL's trackers", @"TIDAL 추적 차단", @YES ],
		@[ @"TidalOffline", @"Offline Download", @"오프라인 다운로드", @"OFSettings", @"arrow.down.circle", @YES,
		   @"Pick v1 or v2 for each download", @"다운로드할 때 v1·v2 선택", @NO ],
		@[ @"TidalSideloadFix", @"Sideload Fix", @"사이드로드 수정", @"", @"key", @NO, // login breaks without it
		   @"Keeps you signed in after sideloading", @"사이드로드해도 로그인 유지", @YES ],
	];
}

static NSString *const kHomePress = @"tt.homePress";
static NSString *const kSeenBuild = @"tt.seenBuild";
static NSString *TTKey(NSString *dylib) { return [NSString stringWithFormat:@"tt.%@.enabled", dylib]; }
static BOOL TTOn(NSArray *t) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:TTKey(t[0])];
	return v ? [v boolValue] : [t[8] boolValue];
}

static NSDictionary<NSString *, NSString *> *gVersions;
static NSArray<NSString *> *gLoaded;
static NSDictionary<NSString *, NSNumber *> *gLaunchOn;

static NSString *TTVersion(const struct mach_header_64 *h) {
	const struct load_command *lc = (const void *)(h + 1);
	for (uint32_t i = 0; i < h->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
		if (lc->cmd != LC_ID_DYLIB) continue;
		uint32_t v = ((const struct dylib_command *)lc)->dylib.current_version;
		return [NSString stringWithFormat:@"%u.%u.%u", v >> 16, (v >> 8) & 0xff, v & 0xff];
	}
	return @"?";
}

static void TTScan(void) {
	NSMutableDictionary *found = [NSMutableDictionary dictionary];
	NSMutableSet *names = [NSMutableSet set]; // not valueForKey:@"firstObject": KVC on an array of arrays goes into the inner arrays too
	for (NSArray *t in TTTweaks()) [names addObject:t[0]];
	[names addObject:@"RadiantTidal"];
	NSMutableArray *loaded = [NSMutableArray array];
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		NSString *name = [@(_dyld_get_image_name(i)).lastPathComponent stringByDeletingPathExtension];
		name = [name componentsSeparatedByString:@"_"].lastObject;
		if (![names containsObject:name]) continue;
		found[name] = TTVersion((const struct mach_header_64 *)_dyld_get_image_header(i));
		[loaded addObject:name];
	}
	gVersions = found;
	gLoaded = loaded;
}

static NSArray<NSArray *> *TTInstalled(void) {
	if (!gVersions) TTScan();
	return [TTTweaks() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *t, id b) { return gVersions[t[0]] != nil; }]];
}

static UIViewController *TTTop(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
		for (UIWindow *w in ((UIWindowScene *)TTAs(scene, UIWindowScene.class)).windows) {
			if (!w.isKeyWindow) continue;
			UIViewController *vc = w.rootViewController;
			while (vc.presentedViewController) vc = vc.presentedViewController;
			return vc;
		}
	return nil;
}

#pragma mark - Update notice

static void TTAlert(NSString *title, NSString *message, NSArray<UIAlertAction *> *actions) {
	UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	for (UIAlertAction *a in actions) [ac addAction:a];
	if (!actions.count) [ac addAction:[UIAlertAction actionWithTitle:TTL(@"OK", @"확인") style:UIAlertActionStyleCancel handler:nil]];
	[TTTop() presentViewController:ac animated:YES completion:nil];
}

static void TTAskRestart(void) {
	TTAlert(TTL(@"Restart TIDAL to apply this change.", @"이 사항을 적용하려면 앱 재시작이 필요합니다."), nil, @[
		[UIAlertAction actionWithTitle:TTL(@"Later", @"나중에") style:UIAlertActionStyleCancel handler:nil],
		[UIAlertAction actionWithTitle:TTL(@"Restart", @"재시작") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			[NSUserDefaults.standardUserDefaults synchronize];
			[UIApplication.sharedApplication performSelector:@selector(suspend)];
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
		}],
	]);
}

static void TTCheckUpdate(BOOL manual) {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	if (!manual) {
		if ([TT_BUILD isEqualToString:@"dev"]) return;
		if (NSDate.date.timeIntervalSince1970 - [d doubleForKey:@"tt.lastCheck"] < 86400) return;
		[d setDouble:NSDate.date.timeIntervalSince1970 forKey:@"tt.lastCheck"];
	}
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", kRepo]];
	NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
	[req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
	[[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
		NSDictionary *j = data ? TTAs([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], NSDictionary.class) : nil;
		NSString *tag = TTAs(j[@"tag_name"], NSString.class);
		NSString *latest = [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag;
		NSString *notes = TTAs(j[@"body"], NSString.class) ?: @"";
		NSURL *page = [NSURL URLWithString:TTAs(j[@"html_url"], NSString.class) ?: @""];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!latest.length) {
				TTLog(@"update check failed: %@", err ?: @(((NSHTTPURLResponse *)resp).statusCode));
				if (manual) TTAlert(TTL(@"Couldn't check for updates", @"업데이트를 확인하지 못했어요"), nil, nil);
				return;
			}
			BOOL newer = [TT_BUILD isEqualToString:@"dev"] || [latest compare:TT_BUILD options:NSNumericSearch] == NSOrderedDescending;
			if (!newer) {
				if (manual) TTAlert(TTL(@"You're up to date", @"최신 버전이에요"), TT_BUILD, nil);
				return;
			}
			if (!manual && [[d stringForKey:@"tt.skip"] isEqualToString:latest]) return;
			NSString *msg = notes.length > 1500 ? [[notes substringToIndex:1500] stringByAppendingString:@"…"] : notes;
			NSMutableArray *actions = [NSMutableArray array];
			if (page) [actions addObject:[UIAlertAction actionWithTitle:TTL(@"View on GitHub", @"GitHub에서 보기") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
				[UIApplication.sharedApplication openURL:page options:@{} completionHandler:nil];
			}]];
			if (!manual) [actions addObject:[UIAlertAction actionWithTitle:TTL(@"Skip This Version", @"이 버전 건너뛰기") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
				[d setObject:latest forKey:@"tt.skip"];
			}]];
			[actions addObject:[UIAlertAction actionWithTitle:TTL(@"Later", @"나중에") style:UIAlertActionStyleCancel handler:nil]];
			TTAlert([NSString stringWithFormat:TTL(@"New version %@", @"새 버전 %@"), latest], msg, actions);
		});
	}] resume];
}

#pragma mark - Settings

typedef BOOL (^TTCheck)(void);
typedef NSString *(^TTText)(void);

static id TTValue(NSDictionary *item) {
	return [NSUserDefaults.standardUserDefaults objectForKey:item[@"key"]] ?: item[@"default"];
}

static void TTWrite(NSDictionary *item, id value) {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	if (!value || value == NSNull.null) [d removeObjectForKey:item[@"key"]];
	else [d setObject:value forKey:item[@"key"]];
	void (^set)(id) = item[@"set"];
	if (set) set(value == NSNull.null ? nil : value);
}

static NSString *TTString(id textOrBlock) {
	return [textOrBlock isKindOfClass:NSString.class] ? textOrBlock : textOrBlock ? ((TTText)textOrBlock)() : nil;
}

// Colours pinned: in an iOS 26 sheet grouped-table cells sometimes come up the same colour as the sheet
@interface TTGroupedTable : UITableViewController
@end
@implementation TTGroupedTable
- (void)viewDidLoad {
	[super viewDidLoad];
	self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
}
- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
	UIBackgroundConfiguration *b = UIBackgroundConfiguration.listGroupedCellConfiguration;
	b.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
	cell.backgroundConfiguration = b;
}
- (UIView *)headerFooter:(UITableView *)tv text:(NSString *)text footer:(BOOL)footer {
	if (!text) return nil;
	NSString *rid = footer ? @"f" : @"h";
	UITableViewHeaderFooterView *v = [tv dequeueReusableHeaderFooterViewWithIdentifier:rid] ?: [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:rid];
	UIListContentConfiguration *c = footer ? UIListContentConfiguration.groupedFooterConfiguration : UIListContentConfiguration.groupedHeaderConfiguration;
	c.text = text;
	c.textProperties.color = UIColor.secondaryLabelColor;
	v.contentConfiguration = c;
	return v;
}
- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
	return [self headerFooter:tv text:[self respondsToSelector:@selector(tableView:titleForHeaderInSection:)] ? [(id<UITableViewDataSource>)self tableView:tv titleForHeaderInSection:s] : nil footer:NO];
}
- (UIView *)tableView:(UITableView *)tv viewForFooterInSection:(NSInteger)s {
	return [self headerFooter:tv text:[self respondsToSelector:@selector(tableView:titleForFooterInSection:)] ? [(id<UITableViewDataSource>)self tableView:tv titleForFooterInSection:s] : nil footer:YES];
}
@end

@interface TTTweakPage : TTGroupedTable
- (instancetype)initWithTweak:(NSArray *)tweak;
@end

@implementation TTTweakPage {
	NSArray *_tweak;
	NSArray<NSDictionary *> *_sections;
}

- (instancetype)initWithTweak:(NSArray *)tweak {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		_tweak = tweak;
		self.title = TTL(tweak[1], tweak[2]);
		self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	[self rebuild];
}

- (void)rebuild {
	NSString *dylib = _tweak[0];
	BOOL ran = gLaunchOn[dylib].boolValue;
	NSMutableArray *sections = [NSMutableArray array];
	NSString *about = dylib;
	if ([_tweak[5] boolValue]) {
		NSString *footer = TTL(@"Takes effect the next time TIDAL starts.", @"TIDAL을 다시 시작하면 적용돼요.");
		if (!ran) footer = [footer stringByAppendingString:TTL(@" Its settings show up once it's running.", @" 켜진 채로 시작하면 설정이 나와요.")];
		[sections addObject:@{ @"items": @[ @{ @"type": @"switch", @"key": TTKey(dylib), @"default": _tweak[8], @"restart": @(ran), @"title": TTL(@"Enabled", @"사용") } ],
		                       @"footer": [NSString stringWithFormat:@"%@\n%@", footer, about] }];
	} else {
		[sections addObject:@{ @"items": @[], @"footer": [NSString stringWithFormat:@"%@\n%@", TTL(@"Always on: TIDAL needs it.", @"항상 켜져 있어요: TIDAL에 필요해요."), about] }];
	}
	Class cls = NSClassFromString(_tweak[3]);
	if (ran && [cls respondsToSelector:@selector(ttSections)])
		for (NSDictionary *s in [cls performSelector:@selector(ttSections)]) {
			NSArray *items = [s[@"items"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *i, id b) {
				TTCheck visible = i[@"visible"];
				return !visible || visible();
			}]];
			NSMutableDictionary *m = [s mutableCopy];
			m[@"items"] = items;
			[sections addObject:m];
		}
	_sections = sections;
	[self.tableView reloadData];
}

- (void)refreshSoon {
	[self rebuild];
	__weak TTTweakPage *ws = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws rebuild]; });
}

- (NSDictionary *)itemAt:(NSIndexPath *)ip { return _sections[ip.section][@"items"][ip.row]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [_sections[s][@"items"] count]; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return TTString(_sections[s][@"header"]); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return TTString(_sections[s][@"footer"]); }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	NSDictionary *item = [self itemAt:ip];
	NSString *type = item[@"type"];
	TTCheck enabled = item[@"enabled"];
	BOOL on = !enabled || enabled();
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	UIListContentConfiguration *c = item[@"detail"] ? UIListContentConfiguration.subtitleCellConfiguration : UIListContentConfiguration.valueCellConfiguration;
	c.text = item[@"title"];
	if (item[@"detail"]) {
		c.secondaryText = item[@"detail"];
		c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
	}
	if ([item[@"indent"] boolValue]) {
		NSDirectionalEdgeInsets m = c.directionalLayoutMargins;
		m.leading += 24;
		c.directionalLayoutMargins = m;
	}
	if (!on) c.textProperties.color = UIColor.secondaryLabelColor;
	cell.selectionStyle = UITableViewCellSelectionStyleNone;

	if ([type isEqualToString:@"switch"]) {
		UISwitch *sw = [UISwitch new];
		sw.on = [TTValue(item) boolValue];
		sw.enabled = on;
		__weak TTTweakPage *ws = self;
		[sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
			UISwitch *s = (UISwitch *)a.sender;
			NSArray *confirm = item[@"confirm"];
			if (!confirm || !s.on) {
				TTWrite(item, @(s.on));
				if (item[@"restart"] && s.on != [item[@"restart"] boolValue]) TTAskRestart();
				// rebuilding now replaces the switch mid-slide and kills its iOS 26 animation
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [ws refreshSoon]; });
				return;
			}
			UIAlertController *ac = [UIAlertController alertControllerWithTitle:confirm[0] message:confirm[1] preferredStyle:UIAlertControllerStyleAlert];
			[ac addAction:[UIAlertAction actionWithTitle:TTL(@"Cancel", @"취소") style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
				[s setOn:NO animated:YES];
			}]];
			[ac addAction:[UIAlertAction actionWithTitle:confirm[2] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
				TTWrite(item, @YES);
				[ws refreshSoon];
			}]];
			[ws presentViewController:ac animated:YES completion:nil];
		}] forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
	} else if ([type isEqualToString:@"choice"]) {
		id current = TTValue(item) ?: NSNull.null;
		NSMutableArray *actions = [NSMutableArray array];
		__weak TTTweakPage *ws = self;
		for (NSArray *o in item[@"options"]) {
			UIAction *a = [UIAction actionWithTitle:o[1] image:nil identifier:nil handler:^(UIAction *a) {
				TTWrite(item, o[0]);
				[ws refreshSoon];
			}];
			a.state = [o[0] isEqual:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
			[actions addObject:a];
		}
		UIButtonConfiguration *bc = UIButtonConfiguration.plainButtonConfiguration;
		bc.indicator = UIButtonConfigurationIndicatorPopup;
		bc.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 0);
		UIButton *b = [UIButton buttonWithConfiguration:bc primaryAction:nil];
		b.menu = [UIMenu menuWithChildren:actions];
		b.showsMenuAsPrimaryAction = YES;
		b.changesSelectionAsPrimaryAction = YES;
		b.enabled = on;
		b.tintColor = UIColor.secondaryLabelColor;
		[b sizeToFit];
		cell.accessoryView = b;
	} else if ([type isEqualToString:@"text"]) {
		NSString *v = TTValue(item);
		c.secondaryText = !v.length ? TTL(@"Not set", @"없음") : [item[@"secure"] boolValue] ? [@"••••" stringByAppendingString:[v substringFromIndex:MAX(0, (NSInteger)v.length - 6)]] : v;
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	} else if ([type isEqualToString:@"action"]) {
		c.textProperties.color = !on ? UIColor.secondaryLabelColor : [item[@"destructive"] boolValue] ? UIColor.systemRedColor : self.view.tintColor;
		TTText value = item[@"value"];
		if (value) c.secondaryText = value();
		cell.selectionStyle = UITableViewCellSelectionStyleDefault;
	}
	cell.contentConfiguration = c;
	return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	NSDictionary *item = [self itemAt:ip];
	TTCheck enabled = item[@"enabled"];
	if (enabled && !enabled()) return;
	if ([item[@"type"] isEqualToString:@"action"]) {
		void (^run)(void) = item[@"set"];
		if (run) run();
		[self refreshSoon];
	} else if ([item[@"type"] isEqualToString:@"text"]) {
		UIAlertController *ac = [UIAlertController alertControllerWithTitle:item[@"title"] message:nil preferredStyle:UIAlertControllerStyleAlert];
		[ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
			tf.text = TTValue(item);
			tf.placeholder = item[@"placeholder"];
			tf.autocorrectionType = UITextAutocorrectionTypeNo;
			tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
			tf.clearButtonMode = UITextFieldViewModeWhileEditing;
		}];
		__weak UIAlertController *wac = ac;
		__weak TTTweakPage *ws = self;
		[ac addAction:[UIAlertAction actionWithTitle:TTL(@"Cancel", @"취소") style:UIAlertActionStyleCancel handler:nil]];
		[ac addAction:[UIAlertAction actionWithTitle:TTL(@"Save", @"저장") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
			NSString *s = [wac.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
			TTWrite(item, s.length ? s : nil);
			[ws refreshSoon];
		}]];
		[self presentViewController:ac animated:YES completion:nil];
	}
}
@end

@interface TTSettings : TTGroupedTable
@end

@implementation TTSettings {
	NSArray<NSArray *> *_tweaks;
	void (*_rlOpen)(UIViewController *);
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = TTL(@"Settings", @"설정");
	self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
	self.navigationController.navigationBar.prefersLargeTitles = YES;
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
	_tweaks = TTInstalled();
	_rlOpen = dlsym(RTLD_DEFAULT, "RLOpenSettings");
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	[self.tableView reloadData];
}

- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
	if (self.navigationController.isBeingDismissed) [NSNotificationCenter.defaultCenter postNotificationName:@"TTSettingsClosed" object:nil];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)exportLogs:(UIView *)source {
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSError *err;
		OSLogStore *store = [OSLogStore storeWithScope:OSLogStoreCurrentProcessIdentifier error:&err];
		NSMutableString *out = [NSMutableString stringWithFormat:@"Perigee %@, TIDAL %@, iOS %@\n", TT_BUILD,
		                                                       [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"], UIDevice.currentDevice.systemVersion];
		NSDateFormatter *f = [NSDateFormatter new];
		f.dateFormat = @"HH:mm:ss.SSS";
		for (OSLogEntry *e in [store entriesEnumeratorWithOptions:0 position:nil predicate:nil error:&err]) {
			NSString *sub = [e isKindOfClass:OSLogEntryLog.class] ? ((OSLogEntryLog *)e).subsystem : nil;
			if ([e.composedMessage containsString:@"[Tidal"] || [sub hasPrefix:@"com.tidal.sdk.offliner"]) [out appendFormat:@"%@ %@\n", [f stringFromDate:e.date], e.composedMessage];
		}
		if (err) [out appendFormat:@"%@\n", err];
		f.dateFormat = @"yyMMdd-HHmmss";
		NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Perigee-%@.log", [f stringFromDate:NSDate.date]]]];
		[out writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
		dispatch_async(dispatch_get_main_queue(), ^{
			UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ file ] applicationActivities:nil];
			share.popoverPresentationController.sourceView = source;
			[self presentViewController:share animated:YES completion:nil];
		});
	});
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == 0 ? _tweaks.count + (_rlOpen != NULL) : s == 3 ? 2 + gLoaded.count : s == 2 ? 2 : 1; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 2 ? TTL(@"Advanced", @"고급") : s == 3 ? TTL(@"About", @"정보") : nil; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
	UIListContentConfiguration *c;
	if (ip.section == 0 && ip.row == (NSInteger)_tweaks.count) {
		c = UIListContentConfiguration.subtitleCellConfiguration;
		c.text = @"Radiant Lyrics";
		c.secondaryText = TTL(@"Its own settings", @"RL 자체 설정");
		c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
		c.image = [UIImage systemImageNamed:@"music.note.list"];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	} else if (ip.section == 0) {
		NSArray *t = _tweaks[ip.row];
		c = UIListContentConfiguration.subtitleCellConfiguration;
		c.text = TTL(t[1], t[2]);
		c.secondaryText = TTL(t[6], t[7]);
		if (TTOn(t) != gLaunchOn[t[0]].boolValue) c.secondaryText = TTL(@"Restart TIDAL to apply", @"TIDAL을 다시 시작하면 적용돼요");
		else if (!TTOn(t)) c.secondaryText = TTL(@"Off", @"꺼짐");
		c.secondaryTextProperties.color = UIColor.secondaryLabelColor;
		c.image = [UIImage systemImageNamed:t[4]];
		c.imageProperties.tintColor = TTOn(t) ? nil : UIColor.tertiaryLabelColor;
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	} else if (ip.section == 1) {
		c = UIListContentConfiguration.cellConfiguration;
		c.text = TTL(@"Hold Home Tab to Open", @"홈 탭 길게 눌러서 열기");
		UISwitch *sw = [UISwitch new];
		sw.on = [NSUserDefaults.standardUserDefaults boolForKey:kHomePress];
		[sw addAction:[UIAction actionWithHandler:^(UIAction *a) {
			[NSUserDefaults.standardUserDefaults setBool:((UISwitch *)a.sender).on forKey:kHomePress];
		}] forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	} else if (ip.section == 2) {
		c = UIListContentConfiguration.cellConfiguration;
		c.text = ip.row ? TTL(@"Export Logs", @"로그 내보내기") : TTL(@"Reset Onboarding", @"온보딩 상태 재설정");
		c.textProperties.color = self.view.tintColor;
	} else if (ip.row == 0) {
		c = UIListContentConfiguration.valueCellConfiguration;
		c.text = TTL(@"Version", @"버전");
		c.secondaryText = TT_BUILD;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	} else if (ip.row <= (NSInteger)gLoaded.count) {
		NSString *name = gLoaded[ip.row - 1], *v = gVersions[name];
		c = UIListContentConfiguration.valueCellConfiguration;
		c.text = name;
		c.secondaryText = [v isEqualToString:@"0.0.0"] ? nil : v;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	} else {
		c = UIListContentConfiguration.cellConfiguration;
		c.text = TTL(@"Check for Updates", @"업데이트 확인");
		c.textProperties.color = self.view.tintColor;
	}
	cell.contentConfiguration = c;
	return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (ip.section == 0 && ip.row == (NSInteger)_tweaks.count) _rlOpen(self);
	else if (ip.section == 0) [self.navigationController pushViewController:[[TTTweakPage alloc] initWithTweak:_tweaks[ip.row]] animated:YES];
	else if (ip.section == 2 && ip.row) [self exportLogs:[tv cellForRowAtIndexPath:ip]];
	else if (ip.section == 2) {
		[NSUserDefaults.standardUserDefaults removeObjectForKey:kSeenBuild];
		TTAlert(TTL(@"Onboarding reset", @"온보딩 상태를 재설정했어요"), TTL(@"Settings will open the next time TIDAL starts.", @"다음에 TIDAL을 열면 설정이 다시 떠요."), nil);
	} else if (ip.section == 3 && ip.row == (NSInteger)gLoaded.count + 1) TTCheckUpdate(YES);
}
@end

@interface TTCore : NSObject
@end
@implementation TTCore
+ (void)openSettings:(id)sender { [self open:nil from:sender]; }
// Called by name from other tweaks
+ (void)openTweak:(NSString *)dylib { [self open:dylib from:nil]; }

+ (void)open:(NSString *)dylib from:(id)source {
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[TTSettings alloc] initWithStyle:UITableViewStyleInsetGrouped]];
	for (NSArray *t in TTInstalled())
		if ([t[0] isEqualToString:dylib]) [nav pushViewController:[[TTTweakPage alloc] initWithTweak:t] animated:NO];
	if (@available(iOS 26.0, *)) {
		__weak id weakSource = source;
		if ([source isKindOfClass:UIBarButtonItem.class])
			nav.preferredTransition = [UIViewControllerTransition zoomWithOptions:nil sourceBarButtonItemProvider:^UIBarButtonItem *(UIZoomTransitionSourceViewProviderContext *c) { return weakSource; }];
		else if ([source isKindOfClass:UIView.class])
			nav.preferredTransition = [UIViewControllerTransition zoomWithOptions:nil sourceViewProvider:^UIView *(UIZoomTransitionSourceViewProviderContext *c) { return weakSource; }];
	}
	[TTTop() presentViewController:nav animated:YES completion:nil];
}
@end

#pragma mark - Entry in TIDAL's Settings

static UITableView *TTFindTable(UIView *v) {
	if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
	for (UIView *s in v.subviews) {
		UITableView *t = TTFindTable(s);
		if (t) return t;
	}
	return nil;
}

// Header only: the footer is RadiantTidal's
static void TTAddSettingsEntry(UIViewController *vc) {
	UINavigationItem *ni = vc.navigationItem;
	BOOL has = NO;
	for (UIBarButtonItem *i in ni.rightBarButtonItems) has |= i.action == @selector(openSettings:);
	if (!has) {
		UIBarButtonItem *b = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"puzzlepiece.extension"] style:UIBarButtonItemStylePlain target:TTCore.class action:@selector(openSettings:)];
		b.accessibilityLabel = TTL(@"Tweaks", @"트윅");
		ni.rightBarButtonItems = [ni.rightBarButtonItems ?: @[] arrayByAddingObject:b];
	}
	if (vc.navigationController && !vc.navigationController.navigationBarHidden) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		UITableView *table = TTFindTable(vc.viewIfLoaded);
		UIView *old = table.tableHeaderView;
		if (!table || [old.accessibilityIdentifier isEqualToString:@"tt.settings"]) return;
		CGFloat w = table.bounds.size.width, rowH = 62;
		UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, rowH + old.bounds.size.height)];
		header.accessibilityIdentifier = @"tt.settings";
		UIButtonConfiguration *c = UIButtonConfiguration.tintedButtonConfiguration;
		if (@available(iOS 26.0, *)) c = UIButtonConfiguration.glassButtonConfiguration;
		c.title = TTL(@"Tweaks", @"트윅 설정");
		c.image = [UIImage systemImageNamed:@"puzzlepiece.extension"];
		c.imagePadding = 8;
		UIButton *hb = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { [TTCore openSettings:a.sender]; }]];
		hb.frame = CGRectMake(16, 14, w - 32, 48);
		hb.autoresizingMask = UIViewAutoresizingFlexibleWidth;
		[header addSubview:hb];
		if (old) {
			old.frame = CGRectMake(0, rowH, w, old.bounds.size.height);
			old.autoresizingMask = UIViewAutoresizingFlexibleWidth;
			[header addSubview:old];
		}
		table.tableHeaderView = header;
	});
}

#pragma mark - Long press on Home in the tab bar

static BOOL TTHasText(UIView *v, NSString *text) {
	if ([v isKindOfClass:UILabel.class] && [((UILabel *)v).text isEqualToString:text]) return YES;
	for (UIView *s in v.subviews) if (TTHasText(s, text)) return YES;
	return NO;
}

static UIView *TTTabButtonAt(UIView *v, UITouch *touch, NSString *title) {
	if (v.hidden || v.alpha < 0.01) return nil;
	if ([v isKindOfClass:NSClassFromString(@"_UITabButton")]) return [v pointInside:[touch locationInView:v] withEvent:nil] && TTHasText(v, title) ? v : nil;
	for (UIView *s in v.subviews) {
		UIView *b = TTTabButtonAt(s, touch, title);
		if (b) return b;
	}
	return nil;
}

// tag 0 = WiMP.Tab.home
static UIView *TTHomeTab(UITouch *touch) {
	for (UIView *v = touch.view; v; v = v.superview) {
		if ([v isKindOfClass:UIButton.class] && v.tag == 0)
			for (id t in ((UIButton *)v).allTargets)
				if ([[(UIButton *)v actionsForTarget:t forControlEvent:UIControlEventTouchUpInside] containsObject:@"tabButtonTapped:"]) return v;
		if (![v isKindOfClass:UITabBar.class]) continue;
		if (@available(iOS 18.0, *)) {
			NSString *title = [TTAs(((UITabBar *)v).delegate, UITabBarController.class) tabForIdentifier:@"liquidtab.0"].title;
			if (title.length) return TTTabButtonAt(v, touch, title);
		}
		return nil;
	}
	return nil;
}

@interface TTHomePress : NSObject <UIGestureRecognizerDelegate>
@end
@implementation TTHomePress
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
	return [NSUserDefaults.standardUserDefaults boolForKey:kHomePress] && TTHomeTab(touch);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other { return YES; }
- (void)pressed:(UILongPressGestureRecognizer *)g {
	if (g.state != UIGestureRecognizerStateBegan) return;
	[[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
	[TTCore open:nil from:nil];
}
@end

static void (*orig_viewWillAppear)(UIViewController *, SEL, BOOL);
static void hook_viewWillAppear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewWillAppear(self, _cmd, animated);
	if ([self isKindOfClass:objc_getClass("_TtC4WiMP13SettingsScene")]) TTAddSettingsEntry(self);
	else if ([self isKindOfClass:objc_getClass("_TtC4WiMP9MainScene")]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
		if ([[d stringForKey:kSeenBuild] isEqualToString:TT_BUILD]) return;
		[d setObject:TT_BUILD forKey:kSeenBuild];
		[TTCore openSettings:nil];
	});
}

__attribute__((constructor)) static void TTInit(void) {
	NSMutableDictionary *on = [NSMutableDictionary dictionary];
	for (NSArray *t in TTTweaks()) on[t[0]] = @(TTOn(t) || ![t[5] boolValue]);
	gLaunchOn = on;

	Method m = class_getInstanceMethod(UIViewController.class, @selector(viewWillAppear:));
	orig_viewWillAppear = (void *)method_setImplementation(m, (IMP)hook_viewWillAppear);

	[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		TTCheckUpdate(NO);
	}];
	TTHomePress *home = [TTHomePress new];
	[NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		UIWindow *w = n.object;
		for (UIGestureRecognizer *g in w.gestureRecognizers) if (g.delegate == home) return;
		UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc] initWithTarget:home action:@selector(pressed:)];
		g.delegate = home;
		[w addGestureRecognizer:g];
	}];
	TTLog(@"loaded, build %@", TT_BUILD);
}
