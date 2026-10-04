#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define LTLog(fmt, ...) LTLogLine([NSString stringWithFormat:fmt, ##__VA_ARGS__])

static void LTLogLine(NSString *line) {
	NSLog(@"[TidalLiquidTab] %@", line);
	static NSString *path;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"liquidtab.log"];
		[NSFileManager.defaultManager removeItemAtPath:path error:NULL];
	});
	NSString *stamp = [NSString stringWithFormat:@"%.1f %@\n", CACurrentMediaTime(), line];
	NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!h) { [stamp writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL]; return; }
	[h seekToEndOfFile];
	[h writeData:[stamp dataUsingEncoding:NSUTF8StringEncoding]];
	[h closeFile];
}

static __weak UIScrollView *gScroll;
static const CGFloat kDown = 20;
static const CGFloat kUp = 12;

static const CGFloat kMiniScale = 0.85;
static const CGFloat kMiniPad = 8;
static const CGFloat kArtRadius = 7;
static const CGFloat kMiniGrow = 8;

static const NSInteger kExploreTag = 1;

static void LTHook(Class c, SEL sel, IMP imp, IMP *orig) {
	Method m = class_getInstanceMethod(c, sel);
	if (!m) { LTLog(@"missing %@ %@", c, NSStringFromSelector(sel)); return; }
	if (class_addMethod(c, sel, imp, method_getTypeEncoding(m))) *orig = method_getImplementation(m);
	else *orig = method_setImplementation(m, imp);
}

static id LTIvar(id obj, const char *name) {
	Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
	return iv ? object_getIvar(obj, iv) : nil;
}

static BOOL *LTBoolIvar(id obj, const char *name) {
	Ivar iv = obj ? class_getInstanceVariable(object_getClass(obj), name) : NULL;
	return iv ? (BOOL *)((char *)(__bridge void *)obj + ivar_getOffset(iv)) : NULL;
}

static void LTNoEffect(UIView *v) {
	UIVisualEffectView *e = (UIVisualEffectView *)v;
	if ([v isKindOfClass:UIVisualEffectView.class] && e.effect) e.effect = nil;
	for (UIView *s in v.subviews) LTNoEffect(s);
}

// Invisible without touching hidden/alpha, which TIDAL keeps setting (and we mirror)
static void LTHide(UIView *v) {
	if (![v isKindOfClass:UIView.class]) return;
	if (!v.layer.mask) v.layer.mask = [CALayer layer];
	LTNoEffect(v);
}

static void LTCollect(UIView *v, UIView *tb, NSMutableArray *out) {
	for (UIView *s in v.subviews) {
		if (s.hidden || s.alpha < 0.01 || s.bounds.size.width < 1) continue;
		if ([s isKindOfClass:UIButton.class] && [[(UIButton *)s actionsForTarget:tb forControlEvent:UIControlEventTouchUpInside] containsObject:@"tabButtonTapped:"])
			[out addObject:s];
		else
			LTCollect(s, tb, out);
	}
}

static NSArray<UIButton *> *LTTabButtons(UIView *tb) {
	NSMutableArray *a = [NSMutableArray array];
	if (tb) LTCollect(tb, tb, a);
	[a sortUsingComparator:^NSComparisonResult(UIView *x, UIView *y) {
		return [@([x convertPoint:CGPointZero toView:tb].x) compare:@([y convertPoint:CGPointZero toView:tb].x)];
	}];
	return a;
}

static BOOL LTIsSelected(UIButton *b) { return CGColorGetAlpha(b.tintColor.CGColor) > 0.75; }

#pragma mark - Views

@interface LTPage : UIViewController
@end
@implementation LTPage
- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = nil;
}
@end

@interface LTPass : UIView
@end
@implementation LTPass
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
	UIView *v = [super hitTest:p withEvent:e];
	for (UIView *x = v; x && x != self; x = x.superview) {
		if ([x.nextResponder isKindOfClass:LTPage.class] || x.bounds.size.height > self.bounds.size.height / 2) return nil;
		NSString *name = NSStringFromClass(x.class);
		if ([x isKindOfClass:UITabBar.class] || [name containsString:@"TabBar"] || [name containsString:@"Accessory"]) return v;
	}
	return nil;
}
@end

@interface LTAccessory : UIView
@end
@implementation LTAccessory {
	CGRect _grown;
}

// UIKit places its accessory container at a fixed height; after every placement stretch it upward by kMiniGrow.
- (UIView *)grow {
	UIView *box = nil;
	for (UIView *v = self.superview; v && ![v isKindOfClass:LTPass.class]; v = v.superview)
		if ([NSStringFromClass(v.class) containsString:@"Accessory"]) box = v;
	if (!box || CGRectEqualToRect(box.frame, _grown)) return box;
	if (box.bounds.size.width < box.superview.bounds.size.width * 0.7) return box;
	CGRect f = box.frame;
	f.origin.y -= kMiniGrow;
	f.size.height += kMiniGrow;
	box.frame = _grown = f;
	[box setNeedsLayout];
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		for (UIView *v = self; v && v != box.superview; v = v.superview) LTLog(@"accessory chain %@ %@", v.class, NSStringFromCGRect(v.frame));
	});
	return box;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	UIView *box = [self grow];
	UIView *mini = self.subviews.firstObject;
	CGRect r = self.bounds;
	if (!mini || r.size.height < 1) return;
	if (box && CGRectEqualToRect(box.frame, _grown)) {
		r.size.height += kMiniGrow;
		r.origin.y = CGRectGetMidY([box convertRect:box.bounds toView:self]) - r.size.height / 2;
	}
	CGRect b = CGRectMake(0, 0, (r.size.width - 2 * kMiniPad) / kMiniScale, r.size.height / kMiniScale);
	if (CGRectEqualToRect(mini.bounds, b) && CGPointEqualToPoint(mini.center, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)))) return;
	[UIView performWithoutAnimation:^{
		mini.transform = CGAffineTransformMakeScale(kMiniScale, kMiniScale);
		mini.bounds = b;
		mini.center = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
		[mini layoutIfNeeded];
	}];
}
@end

#pragma mark - Controller

static char kTag;

@interface LTTabs : UITabBarController <UITabBarControllerDelegate>
@property (nonatomic, weak) UIViewController *glass;
@property (nonatomic, readonly) LTPass *pass;
@property (nonatomic, readonly) LTAccessory *accessoryView;
@property (nonatomic, copy) NSArray<NSNumber *> *tags;
@end
static __weak LTTabs *gTabs;

@implementation LTTabs

- (instancetype)initWithGlass:(UIViewController *)glass {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		_glass = glass;
		_pass = [LTPass new];
		_pass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_accessoryView = [LTAccessory new];
		self.delegate = self;
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = nil;
	self.view.tintColor = UIColor.labelColor;
	if ([self respondsToSelector:@selector(setTabBarMinimizeBehavior:)]) self.tabBarMinimizeBehavior = 2;
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	[_accessoryView setNeedsLayout];
}

- (void)install {
	UIViewController *gv = _glass, *owner = nil;
	UIView *host = gv.view.superview;
	for (UIResponder *r = host; r && !owner; r = r.nextResponder)
		if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
	if (!owner) return;
	if (!self.parentViewController) { // child of whoever owns the view we sit in (MainScene), or UIKit throws a hierarchy inconsistency
		[owner addChildViewController:self];
		self.view.frame = _pass.bounds;
		self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[_pass addSubview:self.view];
		[self didMoveToParentViewController:owner];
		for (NSString *k in @[ @"hidden", @"alpha" ]) [gv.view addObserver:self forKeyPath:k options:0 context:NULL];
		LTLog(@"installed over %@ in %@ (%@)", gv, host, owner);
	}
	NSUInteger i = [host.subviews indexOfObject:gv.view];
	if (i + 1 >= host.subviews.count || host.subviews[i + 1] != _pass) [host insertSubview:_pass aboveSubview:gv.view];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	[self follow];
}

- (void)follow {
	UIView *gview = _glass.view, *host = gview.superview, *slab = LTIvar(_glass, "containerView");
	if (!host) return;
	_pass.hidden = gview.hidden || slab.hidden;
	_pass.alpha = gview.alpha * (slab ? slab.alpha : 1);
	CGFloat drop = MAX(0, CGRectGetMaxY(gview.frame) - host.bounds.size.height);
	_pass.frame = CGRectOffset(host.bounds, 0, drop);
}

- (void)sync {
	UIViewController *gv = _glass;
	if (!gv.view.window) return;
	[self install];

	for (UIView *s in gv.view.subviews)
		LTHide(s);
	gv.view.userInteractionEnabled = NO;
	BOOL *noCollapse = LTBoolIvar(LTIvar(gv, "viewModel"), "isCollapseDisabled"); // UIKit minimizes now; keep TIDAL from animating the mini player we borrowed
	if (noCollapse) *noCollapse = YES;
	[self follow];
	[self syncTabs];
	[self syncMiniPlayer];
}

- (void)syncTabs {
	NSArray<UIButton *> *buttons = LTTabButtons(LTIvar(_glass, "customTabBar"));
	if (!buttons.count) return;
	NSArray *tags = [buttons valueForKey:@"tag"];
	if (![tags isEqualToArray:_tags]) {
		Class tabClass = NSClassFromString(@"UITab"), searchClass = NSClassFromString(@"UISearchTab");
		if (!tabClass) { LTLog(@"no UITab (iOS < 18)"); return; }
		UIViewController * (^page)(id) = ^UIViewController *(id tab) { return [LTPage new]; };
		NSMutableArray *tabs = [NSMutableArray array];
		for (UIButton *b in buttons) {
			id t = b.tag == kExploreTag && searchClass
				? [[searchClass alloc] initWithViewControllerProvider:page]
				: [[tabClass alloc] initWithTitle:b.accessibilityLabel ?: @"" image:[b imageForState:UIControlStateNormal]
					identifier:[NSString stringWithFormat:@"liquidtab.%ld", (long)b.tag] viewControllerProvider:page];
			objc_setAssociatedObject(t, &kTag, @(b.tag), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			[tabs addObject:t];
		}
		_tags = tags;
		self.tabs = tabs;
		LTLog(@"tabs %@", tags);
	}
	for (UIButton *b in buttons) {
		if (!LTIsSelected(b)) continue;
		for (id t in self.tabs)
			if ([objc_getAssociatedObject(t, &kTag) integerValue] == b.tag && self.selectedTab != t) self.selectedTab = t;
		break;
	}
}

// Fold / unfold the bar the way UIKit does it itself (same morph animation), driven by our own scroll rule:
// UIKit only watches a list inside its own tab, and TIDAL's lists are not.
- (void)minimize:(BOOL)want {
	id provider = LTIvar(self.tabBar, "_visualProvider");
	SEL set = @selector(setMinimized:), target = @selector(currentMorphTarget);
	if (![provider respondsToSelector:set] || ![provider respondsToSelector:target]) {
		static dispatch_once_t once;
		dispatch_once(&once, ^{ LTLog(@"no minimize on %@ (bar %@)", provider ?: @"nil provider", self.tabBar.class); });
		return;
	}
	BOOL now = ((NSInteger (*)(id, SEL))objc_msgSend)(provider, target) == 2;
	if (now == want) return;
	LTLog(@"minimize %d", want);
	((void (*)(id, SEL, BOOL))objc_msgSend)(provider, set, want);
}

- (void)syncMiniPlayer {
	UIView *mini = LTIvar(_glass, "miniPlayer");
	BOOL *visible = LTBoolIvar(LTIvar(_glass, "viewModel"), "isMiniPlayerVisible");
	if (![mini isKindOfClass:UIView.class] || !visible) return;
	if (mini.superview != _accessoryView) {
		[mini removeFromSuperview]; // drops TIDAL's constraints to its glass slab (it only ever sets them up in viewDidLoad)
		mini.translatesAutoresizingMaskIntoConstraints = YES;
		mini.autoresizingMask = UIViewAutoresizingNone;
		[_accessoryView addSubview:mini];
		UIImageView *art = LTIvar(mini, "albumArtImageView");
		if ([art isKindOfClass:UIImageView.class]) {
			art.layer.cornerRadius = kArtRadius / kMiniScale;
			art.layer.cornerCurve = kCACornerCurveContinuous;
			art.clipsToBounds = YES;
		}
		UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openPlayer)];
		for (UIGestureRecognizer *own in mini.gestureRecognizers)
			if ([own isKindOfClass:UITapGestureRecognizer.class]) [tap requireGestureRecognizerToFail:own];
		[_accessoryView addGestureRecognizer:tap];
		LTLog(@"mini player moved into accessory");
	}
	for (NSLayoutConstraint *c in mini.constraints)
		if (c.active && c.firstItem == mini && !c.secondItem && (c.firstAttribute == NSLayoutAttributeHeight || c.firstAttribute == NSLayoutAttributeWidth)) c.active = NO;

	Class accessoryClass = NSClassFromString(@"UITabAccessory");
	if (!accessoryClass || (*visible != 0) == (self.bottomAccessory != nil)) return;
	id accessory = *visible ? [[accessoryClass alloc] initWithContentView:_accessoryView] : nil;
	SEL animated = NSSelectorFromString(@"setBottomAccessory:animated:");
	if ([self respondsToSelector:animated]) ((void (*)(id, SEL, id, BOOL))objc_msgSend)(self, animated, accessory, YES);
	else self.bottomAccessory = accessory;
}

- (BOOL)tabBarController:(UITabBarController *)tbc shouldSelectTab:(id)tab {
	NSInteger tag = [objc_getAssociatedObject(tab, &kTag) integerValue];
	for (UIButton *b in LTTabButtons(LTIvar(_glass, "customTabBar")))
		if (b.tag == tag) { [b sendActionsForControlEvents:UIControlEventTouchUpInside]; break; }
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{ [self syncTabs]; });
	return YES;
}

- (void)openPlayer {
	SEL s = NSSelectorFromString(@"miniPlayerTapped");
	if ([_glass respondsToSelector:s]) ((void (*)(id, SEL))objc_msgSend)(_glass, s);
}
@end

#pragma mark - Hooks

static void (*orig_glassLayout)(UIViewController *, SEL);
static void hook_glassLayout(UIViewController *self, SEL _cmd) {
	orig_glassLayout(self, _cmd);
	static char kTabs;
	LTTabs *t = objc_getAssociatedObject(self, &kTabs);
	if (!t) {
		gTabs = t = [[LTTabs alloc] initWithGlass:self];
		objc_setAssociatedObject(self, &kTabs, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	[t sync];
}

static void (*orig_tabLayout)(UIView *, SEL);
static void hook_tabLayout(UIView *self, SEL _cmd) {
	orig_tabLayout(self, _cmd);
	[gTabs syncTabs];
}

static void (*orig_setBounds)(UIScrollView *, SEL, CGRect);
static void hook_setBounds(UIScrollView *self, SEL _cmd, CGRect bounds) {
	CGPoint offset = bounds.origin;
	BOOL moved = fabs(self.bounds.origin.y - offset.y) > 0.01;
	orig_setBounds(self, _cmd, bounds);
	if (!moved) return;
	if (!(self.dragging || self.tracking || self.decelerating)) return;
	if (self.contentSize.height <= self.bounds.size.height + 1) return;
	for (UIView *v = self; v; v = v.superview)
		if ([v isKindOfClass:LTPass.class]) return;
	static CGFloat lastY, run;
	if (self != gScroll) {
		gScroll = self;
		lastY = offset.y;
		run = 0;
		return;
	}
	CGFloat dy = offset.y - lastY;
	lastY = offset.y;
	run = dy * run < 0 ? dy : run + dy;
	if (offset.y <= -self.adjustedContentInset.top + 1 || run < -kUp) [gTabs minimize:NO];
	else if (run > kDown) [gTabs minimize:YES];
}

__attribute__((constructor)) static void LTInit(void) {
	if (NSClassFromString(@"TTCore") && ![NSUserDefaults.standardUserDefaults boolForKey:@"tt.TidalLiquidTab.enabled"]) {
		LTLog(@"turned off in TidalCore's settings");
		return;
	}
	if (!NSClassFromString(@"UITabAccessory")) { // iOS < 26 has no floating glass tab bar: stay out, TIDAL keeps its own
		LTLog(@"iOS < 26, not loading");
		return;
	}
	Class glass = objc_getClass("_TtC4WiMP15GlassTabBarView"), tabs = objc_getClass("_TtC4WiMP16CustomTabBarView");
	if (!glass || !tabs) { LTLog(@"TIDAL classes missing (glass %@, tabs %@)", glass, tabs); return; }
	LTHook(glass, @selector(viewDidLayoutSubviews), (IMP)hook_glassLayout, (IMP *)&orig_glassLayout);
	LTHook(tabs, @selector(layoutSubviews), (IMP)hook_tabLayout, (IMP *)&orig_tabLayout);
	LTHook(UIScrollView.class, @selector(setBounds:), (IMP)hook_setBounds, (IMP *)&orig_setBounds);
	LTLog(@"loaded");
}
