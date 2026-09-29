#import "LL.h"
#import <objc/runtime.h>

static NSString *LLL(NSString *en, NSString *ko) {
	return [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"] ? ko : en;
}

@interface LLSettings : UITableViewController
@end

@implementation LLSettings

- (instancetype)init {
	if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
		self.title = LLL(@"Lock Screen", @"잠금화면");
		self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
	}
	return self;
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSArray<NSString *> *)keysIn:(NSInteger)section {
	if (section == 0) return @[ @"lyrics" ];
	if (section == 1) return LLOn(@"art") && LLArtAvailable() ? @[ @"art", @"artTidal", @"artApple" ] : @[ @"art" ];
	return @[ @"cache" ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [self keysIn:s].count; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
	if (s == 0) return LLL(@"The line being sung shows in place of the artist on the lock screen and in Control Center. Lyrics from Radiant Lyrics, then TIDAL, then LRCLIB.",
	                       @"부르는 중인 가사 줄이 잠금화면과 제어센터의 아티스트 자리에 떠요. 가사는 Radiant Lyrics → TIDAL → LRCLIB 순서로 찾아요.");
	if (s == 1) return LLArtAvailable() ? LLL(@"The album's moving cover plays on the lock screen. TIDAL's own video cover first, then Apple Music's motion cover.",
	                                          @"앨범의 움직이는 커버가 잠금화면에 재생돼요. TIDAL 영상 커버를 먼저, 없으면 Apple Music 모션 커버를 써요.")
	                                    : LLL(@"Needs iOS 26 or later.", @"iOS 26 이상이 필요해요.");
	return LLL(@"Downloaded cover videos. iOS also clears them when storage runs low.", @"받아 둔 커버 영상이에요. 저장 공간이 부족하면 iOS가 알아서 지우기도 해요.");
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
	NSString *key = [self keysIn:ip.section][ip.row];
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	if ([key isEqualToString:@"cache"]) {
		cell.textLabel.text = LLL(@"Clear Cover Cache", @"커버 캐시 지우기");
		cell.textLabel.textColor = UIColor.systemRedColor;
		cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:(long long)LLArtCacheBytes() countStyle:NSByteCountFormatterCountStyleFile];
		return cell;
	}
	NSDictionary *names = @{
		@"lyrics": LLL(@"Lock Screen Lyrics", @"잠금화면 가사"),
		@"art": LLL(@"Animated Artwork", @"애니메이션 아트워크"),
		@"artTidal": LLL(@"TIDAL Video Covers", @"TIDAL 영상 커버"),
		@"artApple": LLL(@"Apple Music Motion Covers", @"Apple Music 모션 커버"),
	};
	cell.textLabel.text = names[key];
	cell.selectionStyle = UITableViewCellSelectionStyleNone;
	if ([key hasPrefix:@"art"] && ![key isEqualToString:@"art"]) cell.indentationLevel = 1;
	UISwitch *sw = [UISwitch new];
	sw.on = LLOn(key);
	sw.enabled = ![key hasPrefix:@"art"] || LLArtAvailable();
	sw.accessibilityIdentifier = key;
	[sw addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
	cell.accessoryView = sw;
	return cell;
}

- (void)toggled:(UISwitch *)sw {
	NSString *key = sw.accessibilityIdentifier;
	[NSUserDefaults.standardUserDefaults setBool:sw.on forKey:[@"ll." stringByAppendingString:key]];
	if ([key hasPrefix:@"art"]) LLArtReset(NO);
	LLSend(YES);
	if ([key isEqualToString:@"art"]) [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
	[tv deselectRowAtIndexPath:ip animated:YES];
	if (![[self keysIn:ip.section][ip.row] isEqualToString:@"cache"]) return;
	LLArtReset(YES);
	LLSend(YES);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [tv reloadData]; });
}
@end

@implementation LLSettings (TTCore)
+ (NSArray *)ttSections {
	void (^art)(id) = ^(id v) {
		LLArtReset(NO);
		LLSend(YES);
	};
	BOOL (^artShown)(void) = ^BOOL { return LLOn(@"art") && LLArtAvailable(); };
	return @[
		@{ @"items": @[ @{ @"type": @"switch", @"key": @"ll.lyrics", @"default": @YES, @"title": LLL(@"Lock Screen Lyrics", @"잠금화면 가사"),
		                   @"set": ^(id v) { LLSend(YES); } } ],
		   @"footer": LLL(@"The line being sung shows in place of the artist on the lock screen and in Control Center. Lyrics from Radiant Lyrics, then TIDAL, then LRCLIB.",
		                  @"부르는 중인 가사 줄이 잠금화면과 제어센터의 아티스트 자리에 떠요. 가사는 Radiant Lyrics → TIDAL → LRCLIB 순서로 찾아요.") },
		@{ @"items": @[
			   @{ @"type": @"switch", @"key": @"ll.art", @"default": @YES, @"title": LLL(@"Animated Artwork", @"애니메이션 아트워크"), @"set": art,
			      @"enabled": ^BOOL { return LLArtAvailable(); } },
			   @{ @"type": @"switch", @"key": @"ll.artTidal", @"default": @YES, @"title": LLL(@"TIDAL Video Covers", @"TIDAL 영상 커버"), @"set": art,
			      @"indent": @YES, @"visible": artShown },
			   @{ @"type": @"switch", @"key": @"ll.artApple", @"default": @YES, @"title": LLL(@"Apple Music Motion Covers", @"Apple Music 모션 커버"), @"set": art,
			      @"indent": @YES, @"visible": artShown },
		   ],
		   @"footer": LLArtAvailable() ? LLL(@"The album's moving cover plays on the lock screen. TIDAL's own video cover first, then Apple Music's motion cover.",
		                                     @"앨범의 움직이는 커버가 잠금화면에 재생돼요. TIDAL 영상 커버를 먼저, 없으면 Apple Music 모션 커버를 써요.")
		                               : LLL(@"Needs iOS 26 or later.", @"iOS 26 이상이 필요해요.") },
		@{ @"items": @[ @{ @"type": @"action", @"destructive": @YES, @"title": LLL(@"Clear Cover Cache", @"커버 캐시 지우기"),
		                   @"value": ^NSString * { return [NSByteCountFormatter stringFromByteCount:(long long)LLArtCacheBytes() countStyle:NSByteCountFormatterCountStyleFile]; },
		                   @"set": ^{
			                   LLArtReset(YES);
			                   LLSend(YES);
		                   } } ],
		   @"footer": LLL(@"Downloaded cover videos. iOS also clears them when storage runs low.", @"받아 둔 커버 영상이에요. 저장 공간이 부족하면 iOS가 알아서 지우기도 해요.") },
	];
}
@end

static void LLOpenSettings(UIViewController *from) {
	while (from.presentedViewController) from = from.presentedViewController;
	[from presentViewController:[[UINavigationController alloc] initWithRootViewController:[LLSettings new]] animated:YES completion:nil];
}

#pragma mark - Entry in TIDAL's Settings

@interface LLSettingsTarget : NSObject
@end
static __weak UIViewController *gSettingsScene;
@implementation LLSettingsTarget
+ (void)llOpen:(id)sender { LLOpenSettings(gSettingsScene); }
@end

static UITableView *LLFindTable(UIView *v) {
	if ([v isKindOfClass:UITableView.class]) return (UITableView *)v;
	for (UIView *s in v.subviews) {
		UITableView *t = LLFindTable(s);
		if (t) return t;
	}
	return nil;
}

static void LLAddSettingsButton(UIViewController *vc) {
	gSettingsScene = vc;
	UINavigationItem *ni = vc.navigationItem;
	BOOL has = NO;
	for (UIBarButtonItem *i in ni.rightBarButtonItems) has |= i.action == @selector(llOpen:);
	if (!has) {
		UIBarButtonItem *b = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"lock.iphone"] style:UIBarButtonItemStylePlain target:LLSettingsTarget.class action:@selector(llOpen:)];
		b.accessibilityLabel = LLL(@"Lock screen settings", @"잠금화면 설정");
		ni.rightBarButtonItems = [ni.rightBarButtonItems ?: @[] arrayByAddingObject:b];
	}
	if (vc.navigationController && !vc.navigationController.navigationBarHidden) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		UITableView *table = LLFindTable(vc.viewIfLoaded);
		UIView *old = table.tableHeaderView;
		if (!table || [old.accessibilityIdentifier isEqualToString:@"ll.settings"]) return;
		CGFloat w = table.bounds.size.width, rowH = 62;
		UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, rowH + old.bounds.size.height)];
		header.accessibilityIdentifier = @"ll.settings";
		UIButtonConfiguration *c = [UIButtonConfiguration tintedButtonConfiguration];
		c.title = LLL(@"Lock Screen", @"잠금화면 설정");
		c.image = [UIImage systemImageNamed:@"lock.iphone"];
		c.imagePadding = 8;
		UIButton *hb = [UIButton buttonWithConfiguration:c primaryAction:[UIAction actionWithHandler:^(UIAction *a) { LLOpenSettings(gSettingsScene); }]];
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

static void (*orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void hook_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
	orig_viewDidAppear(self, _cmd, animated);
	if ([self isKindOfClass:objc_getClass("_TtC4WiMP13SettingsScene")] && !NSClassFromString(@"TTCore")) LLAddSettingsButton(self);
}

void LLSettingsInit(void) {
	Method m = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
	orig_viewDidAppear = (void *)method_setImplementation(m, (IMP)hook_viewDidAppear);
}
