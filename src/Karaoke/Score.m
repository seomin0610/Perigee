#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import "DSP.h"
#import "KR.h"

static NSString *const kScore = @"kr.score";
static const double kWindow = 0.25, kSettle = 0.6;
static const float kMicGate = 0.003f;
static const NSUInteger kMinSung = 400;
enum { kRing = 2048 };

static KRFrame gRef[kRing], gMic[kRing];
static _Atomic(unsigned) gRefHead, gMicHead;
static _Atomic(NSUInteger) gItemHash;
static _Atomic(bool) gActive;

BOOL KRScoreWants(NSUInteger item) { return atomic_load(&gActive) && item == atomic_load(&gItemHash); }

static void KRRingPush(KRFrame *ring, _Atomic(unsigned) *head, double time, float note) {
	unsigned h = atomic_load_explicit(head, memory_order_relaxed);
	ring[h % kRing] = (KRFrame){ time, note };
	atomic_store_explicit(head, h + 1, memory_order_release);
}

void KRScorePush(double time, float note) { KRRingPush(gRef, &gRefHead, time, note); }

static double KRHostNow(void) { return [AVAudioTime secondsForHostTime:mach_absolute_time()]; }

#pragma mark - Mic

static AVAudioEngine *gEngine;
static KRPitch gMicPitch;
static AVAudioSessionCategory gPrevCategory;
static AVAudioSessionMode gPrevMode;
static AVAudioSessionCategoryOptions gPrevOptions;

static void KRMicStop(void) {
	if (!gEngine) return;
	[gEngine.inputNode removeTapOnBus:0];
	[gEngine stop];
	gEngine = nil;
	[AVAudioSession.sharedInstance setCategory:gPrevCategory mode:gPrevMode options:gPrevOptions error:nil];
	KRLog(@"mic off");
}

static BOOL KRMicStart(void) {
	if (gEngine) return YES;
	AVAudioSession *s = AVAudioSession.sharedInstance;
	gPrevCategory = s.category, gPrevMode = s.mode, gPrevOptions = s.categoryOptions;
	NSError *e;
	if (![s setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
	            options:AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionDefaultToSpeaker
	              error:&e]) {
		KRLog(@"mic: category refused: %@", e);
		return NO;
	}
	AVAudioEngine *engine = [AVAudioEngine new];
	AVAudioInputNode *input = engine.inputNode;
	AVAudioFormat *f = [input outputFormatForBus:0];
	if (!f.sampleRate || !f.channelCount) {
		KRLog(@"mic: no input");
		[s setCategory:gPrevCategory mode:gPrevMode options:gPrevOptions error:nil];
		return NO;
	}
	KRPitchInit(&gMicPitch, f.sampleRate);
	double rate = f.sampleRate, delay = KRPitchDelay(&gMicPitch);
	[input installTapOnBus:0 bufferSize:1024 format:f block:^(AVAudioPCMBuffer *b, AVAudioTime *when) {
		const float *x = b.floatChannelData ? b.floatChannelData[0] : NULL;
		if (!x || !when.hostTimeValid) return;
		double at = [AVAudioTime secondsForHostTime:when.hostTime] - delay;
		float note;
		for (AVAudioFrameCount i = 0; i < b.frameLength; i++)
			if (KRPitchPush(&gMicPitch, x[i], kMicGate, &note)) KRRingPush(gMic, &gMicHead, at + (i + 1) / rate, note);
	}];
	[engine prepare];
	if (![engine startAndReturnError:&e]) {
		KRLog(@"mic: start failed: %@", e);
		[input removeTapOnBus:0];
		[s setCategory:gPrevCategory mode:gPrevMode options:gPrevOptions error:nil];
		return NO;
	}
	gEngine = engine;
	KRLog(@"mic on: %@ in, %@ out, %.0f Hz", s.currentRoute.inputs.firstObject.portType, s.currentRoute.outputs.firstObject.portType, rate);
	return YES;
}

#pragma mark - Scoring

static NSHashTable<AVPlayer *> *gPlayers;
static dispatch_source_t gTimer;
static __weak AVPlayerItem *gItem;
static NSString *gTitle;
static NSMutableData *gRefs, *gMics;
static unsigned gRefTail, gMicTail;
static KRTally gTally;
static NSString *gEvent;
static double gEventAt;
static double gLastSong, gLastHost, gLiveAt;
static KRLag gLag;
static int gLive = -1;

static BOOL KRWanted(void) {
	return KROn() && [NSUserDefaults.standardUserDefaults boolForKey:kScore] && AVAudioSession.sharedInstance.recordPermission == AVAudioSessionRecordPermissionGranted;
}

static AVPlayer *KRPlayer(void) {
	for (AVPlayer *p in gPlayers)
		if (p.rate > 0 && !p.currentItem.presentationSize.width) return p;
	return nil;
}

static int KRScore(void) {
	int pitch, rhythm, phrase;
	return KRTallyScore(&gTally, &pitch, &rhythm, &phrase);
}

static void KRClear(void) {
	gRefs.length = gMics.length = 0;
	gLastHost = 0;
	gRefTail = atomic_load(&gRefHead), gMicTail = atomic_load(&gMicHead);
}

static UIViewController *KRTop(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class]) continue;
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (!w.isKeyWindow) continue;
			UIViewController *vc = w.rootViewController;
			while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc = vc.presentedViewController;
			return vc;
		}
	}
	return nil;
}

static UIColor *KRGradeColor(int g) {
	return g == 3 ? UIColor.systemGreenColor : g == 2 ? UIColor.systemBlueColor : g == 1 ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
}

static NSString *KRGradeName(int g) { return @[ @"Bad", @"Good", @"Cool", @"Perfect", @"Miss" ][g]; }

@interface KRResult : UIViewController
@property (nonatomic) int score;
@property (nonatomic, copy) NSString *song;
@property (nonatomic, copy) NSString *parts;
@property (nonatomic, copy) NSString *counts;
@end

@implementation KRResult
- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemBackgroundColor;
	UILabel *caption = [UILabel new], *number = [UILabel new], *song = [UILabel new], *parts = [UILabel new], *counts = [UILabel new];
	caption.text = KRL(@"Karaoke score", @"노래방 점수");
	caption.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
	caption.textColor = UIColor.secondaryLabelColor;
	UIFontDescriptor *round = [[UIFont systemFontOfSize:96 weight:UIFontWeightHeavy].fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
	number.font = [UIFont fontWithDescriptor:round size:96];
	number.text = @(self.score).stringValue;
	song.text = self.song;
	song.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
	parts.text = self.parts;
	parts.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
	counts.text = self.counts;
	counts.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	counts.textColor = UIColor.secondaryLabelColor;
	for (UILabel *l in @[ song, parts, counts ]) l.numberOfLines = 0, l.textAlignment = NSTextAlignmentCenter;
	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ caption, number, song, parts, counts ]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.alignment = UIStackViewAlignmentCenter;
	stack.spacing = 8;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];
	UILayoutGuide *g = self.view.layoutMarginsGuide;
	[NSLayoutConstraint activateConstraints:@[
		[stack.centerYAnchor constraintEqualToAnchor:g.centerYAnchor], [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
		[stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor]
	]];
}
@end

static void KRFinish(void) {
	unsigned sung = KRTallySung(&gTally);
	if (sung >= kMinSung) {
		int pitch, rhythm, phrase, score = KRTallyScore(&gTally, &pitch, &rhythm, &phrase);
		const unsigned *g = gTally.grades;
		NSString *parts = [NSString stringWithFormat:KRL(@"Pitch %d · Rhythm %d · Phrases %u/%u\nVibrato %u · Long tones %u", @"음정 %d · 리듬 %d · 소절 %u/%u\n비브라토 %u · 롱톤 %u"), pitch,
		                                             rhythm, gTally.cleared, gTally.phrases, gTally.vibratos, gTally.longTones];
		NSString *counts = [NSString stringWithFormat:@"Perfect %u · Cool %u · Good %u · Bad %u · Miss %u", g[3], g[2], g[1], g[0], g[4]];
		KRLog(@"score %d for %@ (%@ · %@, you sang %.0f ms behind)", score, gTitle, [parts stringByReplacingOccurrencesOfString:@"\n" withString:@" · "], counts,
		      gLag.lag * 1000);
		UIViewController *top = UIApplication.sharedApplication.applicationState == UIApplicationStateActive ? KRTop() : nil;
		if (top && ![top isKindOfClass:KRResult.class]) {
			KRResult *r = [KRResult new];
			r.score = score, r.song = gTitle, r.parts = parts, r.counts = counts;
			r.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.mediumDetent ];
			r.sheetPresentationController.prefersGrabberVisible = YES;
			[top presentViewController:r animated:YES completion:nil];
		}
	} else if (sung)
		KRLog(@"too little singing to score (%u frames)", sung);
	memset(&gTally, 0, sizeof gTally);
	memset(&gLag, 0, sizeof gLag);
	gLive = -1, gEvent = nil;
	KRClear();
}

#pragma mark - HUD

static UIVisualEffectView *gHUD;
static UILabel *gHUDLabel;

static void KRHUD(BOOL show) {
	if (!show) {
		gHUD.hidden = YES;
		return;
	}
	UIWindow *w = KRTop().view.window;
	if (!w) return;
	if (!gHUD) {
		UIVisualEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
		if (@available(iOS 26.0, *)) effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
		gHUD = [[UIVisualEffectView alloc] initWithEffect:effect];
		gHUD.userInteractionEnabled = NO;
		gHUD.clipsToBounds = YES;
		gHUDLabel = [UILabel new];
		[gHUD.contentView addSubview:gHUDLabel];
	}
	if (gHUD.superview != w) [w addSubview:gHUD];
	[w bringSubviewToFront:gHUD];
	double now = CACurrentMediaTime();
	BOOL fresh = gLive >= 0 && now - gLiveAt < 0.8, event = gEvent && now - gEventAt < 1.5;
	NSMutableAttributedString *s = [NSMutableAttributedString new];
	UIFont *bold = [UIFont systemFontOfSize:15 weight:UIFontWeightBold], *plain = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
	NSString *word = event ? gEvent : fresh ? KRGradeName(gLive) : @"♪";
	UIColor *color = event ? UIColor.systemPinkColor : fresh ? KRGradeColor(gLive) : UIColor.labelColor;
	[s appendAttributedString:[[NSAttributedString alloc] initWithString:word attributes:@{ NSFontAttributeName: bold, NSForegroundColorAttributeName: color }]];
	[s appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %d", KRScore()]
	                                                          attributes:@{ NSFontAttributeName: plain, NSForegroundColorAttributeName: UIColor.labelColor }]];
	gHUDLabel.attributedText = s;
	CGSize size = [gHUDLabel sizeThatFits:CGSizeMake(300, 40)];
	CGFloat h = 32, width = MAX(88, size.width + 28);
	gHUD.frame = CGRectMake((w.bounds.size.width - width) / 2, w.safeAreaInsets.top + 4, width, h);
	gHUD.layer.cornerRadius = h / 2;
	gHUDLabel.frame = CGRectMake((width - size.width) / 2, (h - size.height) / 2, size.width, size.height);
	gHUD.hidden = NO;
}

#pragma mark - Tick

static void KRStop(void) {
	atomic_store(&gActive, false);
	KRMicStop();
	KRHUD(NO);
	if (gTimer) dispatch_source_cancel(gTimer);
	gTimer = nil;
}

static void KRSettle(double song) {
	const KRFrame *refs = gRefs.bytes, *mics = gMics.bytes;
	NSUInteger nr = gRefs.length / sizeof(KRFrame), nm = gMics.length / sizeof(KRFrame), done = 0, old = 0;
	for (; done < nr && refs[done].time < song - kSettle; done++) {
		float user = 0;
		int g = refs[done].note > 0 ? KRMatch(&gLag, mics, nm, refs[done], kWindow, &user) : 4;
		int ev = KRTallyRef(&gTally, refs[done], g, user, gLag.lag);
		if (refs[done].note > 0) gLive = g, gLiveAt = CACurrentMediaTime();
		if (ev & KRVibrato) gEvent = KRL(@"Vibrato", @"비브라토");
		else if (ev & KRLongTone) gEvent = KRL(@"Long tone", @"롱톤");
		else if (ev & KRPhraseEnded) gEvent = [NSString stringWithFormat:KRL(@"Phrase %.0f%%", @"소절 %.0f%%"), gTally.phraseRate * 100];
		if (ev) gEventAt = CACurrentMediaTime();
	}
	[gRefs replaceBytesInRange:NSMakeRange(0, done * sizeof(KRFrame)) withBytes:NULL length:0];
	while (old < nm && mics[old].time < song - kSettle - 4) old++;
	[gMics replaceBytesInRange:NSMakeRange(0, old * sizeof(KRFrame)) withBytes:NULL length:0];
}

static void KRTick(void) {
	AVPlayer *p = KRPlayer();
	if (!KRWanted() || !p) return KRStop();
	AVPlayerItem *item = p.currentItem;
	if (item != gItem) {
		KRFinish();
		gItem = item;
		atomic_store(&gItemHash, ((AVURLAsset *)item.asset).URL.absoluteString.hash);
		gTitle = nil;
	}
	if (!KRMicStart()) return KRStop();
	atomic_store(&gActive, true);
	double song = CMTimeGetSeconds(p.currentTime), host = KRHostNow(), rate = p.rate;
	if (!isfinite(song)) return;
	if (song < 5 || !gTitle) gTitle = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyTitle];
	if (gLastHost > 0 && fabs((song - gLastSong) - (host - gLastHost) * rate) > 0.5) KRClear();
	gLastSong = song, gLastHost = host;
	for (unsigned h = atomic_load_explicit(&gRefHead, memory_order_acquire); gRefTail != h; gRefTail++) {
		if (h - gRefTail > kRing) gRefTail = h - kRing;
		[gRefs appendBytes:&gRef[gRefTail % kRing] length:sizeof(KRFrame)];
	}
	for (unsigned h = atomic_load_explicit(&gMicHead, memory_order_acquire); gMicTail != h; gMicTail++) {
		if (h - gMicTail > kRing) gMicTail = h - kRing;
		KRFrame f = gMic[gMicTail % kRing];
		f.time = song - (host - f.time) * rate;
		[gMics appendBytes:&f length:sizeof(KRFrame)];
		KRTallyMic(&gTally, f);
	}
	KRSettle(song);
	KRHUD(YES);
}

static void KRWake(void) {
	if (gTimer || !KRWanted() || !KRPlayer()) return;
	gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
	dispatch_source_set_timer(gTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 20, NSEC_PER_MSEC * 5);
	dispatch_source_set_event_handler(gTimer, ^{ KRTick(); });
	dispatch_resume(gTimer);
}

void KRScoreSet(BOOL on) {
	dispatch_async(dispatch_get_main_queue(), ^{
		if (!on) return KRStop();
		AVAudioSession *s = AVAudioSession.sharedInstance;
		if (s.recordPermission == AVAudioSessionRecordPermissionUndetermined)
			return [s requestRecordPermission:^(BOOL granted) {
				KRLog(@"mic permission: %@", granted ? @"granted" : @"denied");
				dispatch_async(dispatch_get_main_queue(), ^{ KRWake(); });
			}];
		KRWake();
	});
}

NSString *KRScoreStatus(void) {
	if (AVAudioSession.sharedInstance.recordPermission == AVAudioSessionRecordPermissionDenied)
		return KRL(@"Needs microphone access (Settings > TIDAL)", @"마이크 권한이 필요해요 (설정 > TIDAL)");
	if (KRUsing() == 2) return KRL(@"Only works with Apple voice isolation", @"Apple 목소리 분리일 때만 채점돼요");
	return KRL(@"Compares your pitch with the singer's · earphones recommended", @"부른 음정을 원곡 목소리와 비교해요 · 이어폰 권장");
}

void KRScoreInit(void) {
	gPlayers = [NSHashTable weakObjectsHashTable];
	gRefs = [NSMutableData data];
	gMics = [NSMutableData data];
	[NSNotificationCenter.defaultCenter addObserverForName:AVPlayerRateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		if ([n.object isKindOfClass:AVPlayer.class]) [gPlayers addObject:n.object];
		KRWake();
	}];
	[NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		if (n.object && n.object == gItem) KRFinish(), gItem = nil;
	}];
}
