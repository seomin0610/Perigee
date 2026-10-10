#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdatomic.h>
#import "DSP.h"
#import "../Core/TTAudio.h"

static NSString *const kOffset = @"ld.offset";
static NSString *const kBoost = @"ld.boost";
static NSString *const kEQ = @"ld.eq";
static NSString *const kCompare = @"ld.compare";
static const double kTidalPreAmp = 4, kMaxGain = 4, kTargetLufs = -14;
static NSCache<NSString *, NSNumber *> *gBoost;

static void LDLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void LDLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalLoudness] %{public}@", line);
}

static NSString *LDL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}

static id LDAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

static BOOL LDBoostOn(void) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:kBoost];
	return v ? [v boolValue] : YES;
}

// TIDAL's player only reads the album gain, so tracks of one album keep their own loudness: hand it the track gain instead.
// It can only turn down, so DRM-free v1 streams get no gain from TIDAL and the tap below does it all, raising quiet songs too.
static NSData *LDRewrite(NSData *body, BOOL v1) {
	NSMutableDictionary *doc = LDAs(body ? [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:nil] : nil, NSMutableDictionary.class);
	NSMutableDictionary *attrs = LDAs(LDAs(doc[@"data"], NSDictionary.class)[@"attributes"], NSMutableDictionary.class);
	NSDictionary *track = LDAs(attrs[@"trackAudioNormalizationData"], NSDictionary.class);
	NSDictionary *album = LDAs(attrs[@"albumAudioNormalizationData"], NSDictionary.class);
	NSNumber *gain = LDAs(track[@"replayGain"], NSNumber.class);
	NSString *uri = LDAs(attrs[@"uri"], NSString.class);
	if (!gain) return nil;
	BOOL boost = v1 && uri && LDBoostOn();
	double offset = [NSUserDefaults.standardUserDefaults doubleForKey:kOffset];
	double total = MIN(pow(10, (gain.doubleValue + kTidalPreAmp + offset) / 20), kMaxGain);
	if (boost) {
		[gBoost setObject:@(total) forKey:uri];
		[attrs removeObjectForKey:@"albumAudioNormalizationData"];
	} else
		attrs[@"albumAudioNormalizationData"] = @{ @"replayGain": @(gain.doubleValue + offset), @"peakAmplitude": track[@"peakAmplitude"] ?: album[@"peakAmplitude"] ?: @1 };
	LDLog(@"%@%@: album %@ dB -> track %@ %+g dB, peak %@, x%.2f", boost ? @"v1 " : @"", doc[@"data"][@"id"], album[@"replayGain"], gain, offset, track[@"peakAmplitude"],
	      boost ? total : MIN(total, 1));
	return [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
}

#pragma mark - Tap

static _Atomic(float) gVolume = 1;
static _Atomic(bool) gEQ = true, gCompare;
static _Atomic(float) gNowGain = 1, gNowBass, gNowTreble, gNowLift = 1, gSqueeze = 1;
static _Atomic(double) gNowAt;

typedef struct {
	LDDSP dsp;
	float target, eqVolume;
	BOOL logged, compared;
} LDTap;

@interface LDVolume : NSObject
@end
@implementation LDVolume
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
	atomic_store(&gVolume, AVAudioSession.sharedInstance.outputVolume);
}
@end

static void LDFree(void *ctx) {
	LDTap *t = ctx;
	LDDSPFree(&t->dsp);
	free(t);
}

static void *LDPrepare(NSString *uri, double rate, unsigned ch, unsigned maxFrames) {
	NSNumber *gain = [gBoost objectForKey:uri];
	if (!gain) return NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		dispatch_async(dispatch_get_main_queue(), ^{
			static LDVolume *watch;
			watch = [LDVolume new];
			[AVAudioSession.sharedInstance addObserver:watch forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionInitial context:NULL];
		});
	});
	LDTap *t = calloc(1, sizeof *t);
	if (!LDDSPInit(&t->dsp, rate, ch, gain.floatValue)) {
		LDLog(@"tap: can't process %u ch audio", ch);
		LDFree(t);
		return NULL;
	}
	t->target = kTargetLufs + [NSUserDefaults.standardUserDefaults doubleForKey:kOffset];
	t->eqVolume = -1;
	return t;
}

static void LDProcess(void *ctx, float **p, unsigned stride, size_t frames, BOOL start, double time) {
	LDTap *t = ctx;
	if (start) LDDSPReset(&t->dsp);
	BOOL eq = atomic_load(&gEQ);
	float vol = atomic_load(&gVolume);
	if (eq && vol != t->eqVolume) LDDSPSetEQ(&t->dsp, t->eqVolume = vol, t->target);
	if (!t->logged) {
		t->logged = YES;
		float gain = t->dsp.gain;
		float bass = t->dsp.bassDb, treble = t->dsp.trebleDb, lift = 20 * log10f(t->dsp.lift);
		dispatch_async(dispatch_get_main_queue(), ^{
			LDLog(@"tap: x%.2f, EQ %@ at volume %.2f (bass %+.1f, treble %+.1f, lift %+.1f dB)", gain, eq ? @"on" : @"off", vol, bass, treble, lift);
		});
	}
	atomic_store(&gNowAt, CFAbsoluteTimeGetCurrent());
	atomic_store(&gNowGain, t->dsp.gain);
	atomic_store(&gNowBass, eq ? t->dsp.bassDb : 0);
	atomic_store(&gNowTreble, eq ? t->dsp.trebleDb : 0);
	atomic_store(&gNowLift, eq ? t->dsp.lift : 1);
	if (atomic_load(&gCompare)) return (void)(t->compared = YES);
	if (t->compared) LDDSPReset(&t->dsp), t->compared = NO;
	LDDSPRun(&t->dsp, p, stride, frames, eq);
	if (t->dsp.squeeze < atomic_load(&gSqueeze)) atomic_store(&gSqueeze, t->dsp.squeeze);
	t->dsp.squeeze = 1;
}

static NSString *LDStatus(void) {
	if (CFAbsoluteTimeGetCurrent() - atomic_load(&gNowAt) > 2)
		return LDL(@"Nothing playing through Perigee's audio. TIDAL's own stream (no Secondary Login) is only turned down.",
		           @"Perigee 오디오로 재생 중인 곡이 없어요. TIDAL 스트림(보조 로그인 없음)은 볼륨을 줄이기만 해요.");
	float squeeze = 20 * log10f(atomic_exchange(&gSqueeze, 1)), bass = atomic_load(&gNowBass), treble = atomic_load(&gNowTreble);
	NSMutableString *s = [NSMutableString stringWithFormat:LDL(@"This song %+.1f dB", @"이 곡 %+.1f dB"), 20 * log10f(atomic_load(&gNowGain))];
	if (squeeze < -0.1f) [s appendFormat:LDL(@" · limiter up to %.1f dB", @" · 리미터 최대 %.1f dB"), squeeze];
	if (bass > 0.05f || treble > 0.05f)
		[s appendFormat:LDL(@" · EQ bass %+.1f, treble %+.1f, lift %+.1f dB", @" · EQ 저음 %+.1f, 고음 %+.1f, 전체 %+.1f dB"), bass, treble, 20 * log10f(atomic_load(&gNowLift))];
	return s;
}

#pragma mark - Hooks

// TIDAL's Normalize volume only sets one AVPlayer volume per song; keep it on so the track gain above is applied
static NSString *const kTidalKey = @"prefs_using_loudness_normalization";

static BOOL LDTidalKey(NSString *key) {
	if (![key isEqualToString:kTidalKey]) return NO;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ LDLog(@"TIDAL asked for Normalize volume: on"); });
	return YES;
}

static BOOL (*orig_boolForKey)(NSUserDefaults *, SEL, NSString *);
static BOOL hook_boolForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
	return LDTidalKey(key) ?: orig_boolForKey(self, _cmd, key);
}

static id (*orig_objectForKey)(NSUserDefaults *, SEL, NSString *);
static id hook_objectForKey(NSUserDefaults *self, SEL _cmd, NSString *key) {
	return LDTidalKey(key) ? @YES : orig_objectForKey(self, _cmd, key);
}

static void LDSwap(Class c, SEL sel, IMP imp, void *orig) {
	*(IMP *)orig = method_setImplementation(class_getInstanceMethod(c, sel), imp);
}

@interface LDSettings : NSObject
@end
@implementation LDSettings
+ (NSArray *)ttSections {
	return @[
		@{ @"header": LDL(@"Now playing", @"지금 곡"),
		   @"items": @[ @{ @"type": @"switch", @"key": kCompare, @"default": @NO, @"title": LDL(@"Play original", @"원음으로 듣기"), @"detail": LDStatus(),
		                   @"set": ^(id v) { atomic_store(&gCompare, [v boolValue]); } } ],
		   @"footer": LDL(@"Turns this tweak off for the song that's playing, right away, so you can hear the difference. Off again when TIDAL restarts.",
		                  @"지금 곡에서 바로 맞춤을 끄고 원래 소리로 들려줘요. 껐다 켜며 차이를 비교해 보세요. TIDAL을 다시 열면 꺼져요.") },
		@{ @"items": @[
			   @{ @"type": @"switch", @"key": kBoost, @"default": @YES, @"title": LDL(@"Raise quiet songs", @"조용한 곡 키우기"),
			      @"detail": LDL(@"Plays the DRM-free stream from Secondary Login", @"보조 로그인으로 DRM 없는 스트림 재생") },
			   @{ @"type": @"switch", @"key": kEQ, @"default": @YES, @"title": LDL(@"Volume-aware EQ", @"볼륨 맞춤 EQ"), @"indent": @YES,
			      @"detail": LDL(@"Keeps bass and treble at low phone volume", @"폰 볼륨을 줄여도 저음·고음 유지"), @"visible": ^BOOL { return LDBoostOn(); },
			      @"set": ^(id v) { atomic_store(&gEQ, [v boolValue]); } },
			   @{ @"type": @"choice", @"key": kOffset, @"default": @0, @"title": LDL(@"Level", @"기준 음량"),
			      @"options": @[ @[ @0, LDL(@"TIDAL default", @"TIDAL 기본") ], @[ @-4, @"−4 dB" ], @[ @-8, @"−8 dB" ] ] },
		   ],
		   @"footer": LDL(@"Each song gets one fixed volume, from the next song on; nothing changes inside a song. "
		                  @"Raising quiet songs needs Secondary Login (Advanced), and a limiter catches only the moments that would clip; without it, loud songs are only turned down. "
		                  @"Volume-aware EQ adds back the bass and treble you hear less at low phone volume.",
		                  @"다음 곡부터 곡마다 볼륨 하나를 정해 같은 크기로 맞춰요. 곡 안에서는 볼륨을 건드리지 않아요. "
		                  @"조용한 곡 키우기는 보조 로그인(고급)이 필요하고, 키우다 넘치는 순간만 리미터가 눌러줘요. 로그인이 없으면 큰 곡을 줄이기만 해요. "
		                  @"볼륨 맞춤 EQ는 폰 볼륨을 낮췄을 때 덜 들리는 저음·고음을 채워줘요.") },
	];
}
@end

__attribute__((constructor)) static void LDInit(void) {
	if (NSClassFromString(@"TTCore") && ![NSUserDefaults.standardUserDefaults boolForKey:@"tt.TidalLoudness.enabled"]) return LDLog(@"turned off in TidalCore's settings");
	[NSUserDefaults.standardUserDefaults removeObjectForKey:kCompare];
	id eq = [NSUserDefaults.standardUserDefaults objectForKey:kEQ];
	atomic_store(&gEQ, eq ? [eq boolValue] : YES);
	gBoost = [NSCache new];
	gBoost.countLimit = 50;
	TTAudioAddFn add = dlsym(RTLD_DEFAULT, "TTAudioAdd");
	if (!add) return LDLog(@"needs TidalCore");
	static const TTAudioStage stage = { LDBoostOn, LDRewrite, LDPrepare, LDProcess, LDFree };
	add(&stage);
	LDSwap(NSUserDefaults.class, @selector(boolForKey:), (IMP)hook_boolForKey, &orig_boolForKey);
	LDSwap(NSUserDefaults.class, @selector(objectForKey:), (IMP)hook_objectForKey, &orig_objectForKey);
	LDLog(@"loaded");
}
