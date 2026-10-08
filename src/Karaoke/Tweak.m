#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdatomic.h>
#import "DSP.h"
#import "../Core/TTAudio.h"

static NSString *const kOn = @"kr.on";
static NSString *const kLevel = @"kr.level";
static NSString *const kEngine = @"kr.engine";
static _Atomic(bool) gOn = true;
static _Atomic(float) gLevel = 1;
static _Atomic(int) gUsing;

static void KRLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void KRLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalKaraoke] %{public}@", line);
}

static NSString *KRL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}

static BOOL KROn(void) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:kOn];
	return v ? [v boolValue] : YES;
}

static float KRLevel(id v) { return (v ? [v floatValue] : 100) / 100; }

#pragma mark - Stage

typedef struct {
	KRDSP dsp;
	AudioUnit au;
	float *mid;
	unsigned max;
	Float64 time;
	BOOL broken;
} KRTap;

static OSStatus KRFeed(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *io) {
	KRTap *t = ref;
	if (n > t->max) return kAudioUnitErr_TooManyFramesToProcess;
	for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
		if (io->mBuffers[b].mData) memcpy(io->mBuffers[b].mData, t->mid, n * sizeof(float));
		else io->mBuffers[b].mData = t->mid;
		io->mBuffers[b].mDataByteSize = n * sizeof(float);
	}
	return noErr;
}

static AudioUnit KRIsolator(KRTap *t, double rate, double *latency) {
	if (@available(iOS 16.0, *)) {
		AudioComponentDescription desc = { kAudioUnitType_Effect, kAudioUnitSubType_AUSoundIsolation, kAudioUnitManufacturer_Apple, 0, 0 };
		AudioComponent comp = AudioComponentFindNext(NULL, &desc);
		AudioUnit au = NULL;
		OSStatus e = comp ? AudioComponentInstanceNew(comp, &au) : kAudioUnitErr_InvalidElement;
		if (e) {
			KRLog(@"isolator: not available (%d)", (int)e);
			return NULL;
		}
		AudioStreamBasicDescription f = { rate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 1, 32, 0 };
		UInt32 max = t->max;
		AURenderCallbackStruct cb = { KRFeed, t };
		const char *step = NULL;
		if ((e = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f))) step = "input format";
		else if ((e = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof f))) step = "output format";
		else if ((e = AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max, sizeof max))) step = "max frames";
		else if ((e = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb))) step = "input callback";
		if (!step) {
			if (@available(iOS 18.0, *)) AudioUnitSetParameter(au, kAUSoundIsolationParam_SoundToIsolate, kAudioUnitScope_Global, 0, kAUSoundIsolationSoundType_HighQualityVoice, 0);
			AudioUnitSetParameter(au, kAUSoundIsolationParam_WetDryMixPercent, kAudioUnitScope_Global, 0, 100, 0);
			if ((e = AudioUnitInitialize(au))) step = "initialize";
		}
		if (step) {
			KRLog(@"isolator: %s failed (%d) at %.0f Hz", step, (int)e, rate);
			AudioComponentInstanceDispose(au);
			return NULL;
		}
		Float64 lat = 0;
		UInt32 size = sizeof lat;
		AudioUnitGetProperty(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &lat, &size);
		*latency = lat;
		return au;
	}
	return NULL;
}

static void KRFree(void *ctx) {
	KRTap *t = ctx;
	if (t->au) AudioUnitUninitialize(t->au), AudioComponentInstanceDispose(t->au);
	KRDSPFree(&t->dsp);
	free(t->mid);
	free(t);
}

static void *KRPrepare(NSString *uri, double rate, unsigned ch, unsigned max) {
	KRTap *t = calloc(1, sizeof *t);
	t->max = max;
	t->mid = calloc(max, sizeof(float));
	double latency = 0;
	if ([NSUserDefaults.standardUserDefaults integerForKey:kEngine] == 0) t->au = KRIsolator(t, rate, &latency);
	if (!KRDSPInit(&t->dsp, rate, ch, t->au ? (unsigned)lround(latency * rate) : 0)) {
		KRLog(@"can't process %u ch at %.0f Hz", ch, rate);
		KRFree(t);
		return NULL;
	}
	atomic_store(&gUsing, t->au ? 1 : 2);
	if (t->au) KRLog(@"isolator: latency %.1f ms at %.0f Hz, %u ch", latency * 1000, rate, ch);
	else KRLog(@"center cancel at %.0f Hz, %u ch", rate, ch);
	return t;
}

static void KRProcess(void *ctx, float **p, unsigned stride, size_t n, BOOL start) {
	KRTap *t = ctx;
	if (start) {
		KRDSPReset(&t->dsp);
		if (t->au) AudioUnitReset(t->au, kAudioUnitScope_Global, 0);
	}
	float target = atomic_load(&gOn) ? atomic_load(&gLevel) : 0;
	if (!t->au || t->broken) return KRCenter(&t->dsp, p, stride, n, target);
	const float *vocal = NULL;
	if ((target > 0 || t->dsp.level > 0) && n <= t->max) {
		for (size_t i = 0; i < n; i++) {
			float m = 0;
			for (unsigned c = 0; c < t->dsp.ch; c++) m += p[c][i * stride];
			t->mid[i] = m / t->dsp.ch;
		}
		AudioUnitRenderActionFlags flags = 0;
		AudioTimeStamp ts = { .mSampleTime = t->time, .mFlags = kAudioTimeStampSampleTimeValid };
		AudioBufferList out = { 1, { { 1, (UInt32)(n * sizeof(float)), NULL } } };
		OSStatus e = AudioUnitRender(t->au, &flags, &ts, 0, (UInt32)n, &out);
		if (e) {
			t->broken = YES;
			atomic_store(&gUsing, 2);
			dispatch_async(dispatch_get_main_queue(), ^{ KRLog(@"isolator: render failed (%d), center cancel for this song", (int)e); });
			return KRCenter(&t->dsp, p, stride, n, target);
		}
		vocal = out.mBuffers[0].mData;
	}
	t->time += n;
	KRSubtract(&t->dsp, p, stride, n, vocal, vocal ? target : 0);
}

static BOOL KRWantsV1(void) { return YES; }

#pragma mark - Settings

static NSString *KRStatus(void) {
	NSString *(*user)(void) = dlsym(RTLD_DEFAULT, "TTV1User");
	if (!user || !user()) return KRL(@"Needs Secondary Login (Advanced)", @"보조 로그인(고급)이 필요해요");
	switch (atomic_load(&gUsing)) {
		case 1: return KRL(@"Now: Apple voice isolation", @"지금: Apple 목소리 분리");
		case 2: return KRL(@"Now: center cancel", @"지금: 센터 제거");
	}
	return KRL(@"Starts when a song plays", @"곡을 틀면 시작해요");
}

@interface KRSettings : NSObject
@end
@implementation KRSettings
+ (NSArray *)ttSections {
	return @[
		@{ @"items": @[
			   @{ @"type": @"switch", @"key": kOn, @"default": @YES, @"title": KRL(@"Turn vocals down", @"보컬 줄이기"), @"detail": KRStatus(),
			      @"set": ^(id v) { atomic_store(&gOn, v ? [v boolValue] : true); } },
			   @{ @"type": @"choice", @"key": kLevel, @"default": @100, @"title": KRL(@"Amount", @"줄이는 양"), @"indent": @YES, @"visible": ^BOOL { return KROn(); },
			      @"options": @[ @[ @100, @"100%" ], @[ @75, @"75%" ], @[ @50, @"50%" ] ], @"set": ^(id v) { atomic_store(&gLevel, KRLevel(v)); } },
			   @{ @"type": @"choice", @"key": kEngine, @"default": @0, @"title": KRL(@"Method", @"방식"),
			      @"options": @[ @[ @0, KRL(@"Apple voice isolation", @"Apple 목소리 분리"), KRL(@"Center cancel if it doesn't work", @"안 되면 센터 제거") ],
			                     @[ @1, KRL(@"Center cancel", @"센터 제거"), KRL(@"Classic karaoke: drops what's in the middle", @"가운데 소리를 빼는 옛 노래방 방식") ] ] },
		   ],
		   @"footer": KRL(@"Needs Secondary Login (Advanced). On/off and amount change right away, the method from the next song.",
		                  @"보조 로그인(고급)이 필요해요. 켜고 끄기와 양은 바로, 방식은 다음 곡부터 바뀌어요.") },
	];
}
@end

__attribute__((constructor)) static void KRInit(void) {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	if (NSClassFromString(@"TTCore") && ![d boolForKey:@"tt.TidalKaraoke.enabled"]) return KRLog(@"turned off in TidalCore's settings");
	atomic_store(&gOn, KROn());
	atomic_store(&gLevel, KRLevel([d objectForKey:kLevel]));
	TTAudioAddFn add = dlsym(RTLD_DEFAULT, "TTAudioAdd");
	if (!add) return KRLog(@"needs TidalCore");
	static const TTAudioStage stage = { KRWantsV1, NULL, KRPrepare, KRProcess, KRFree };
	add(&stage);
	KRLog(@"loaded");
}
