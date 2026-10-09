#import <AudioToolbox/AudioToolbox.h>
#import <dlfcn.h>
#import <os/log.h>
#import <stdatomic.h>
#import "DSP.h"
#import "KR.h"
#import "../Core/TTAudio.h"

static NSString *const kOn = @"kr.on";
static NSString *const kLevel = @"kr.level";
static NSString *const kEngine = @"kr.engine";
static NSString *const kScore = @"kr.score";
static NSString *const kKey = @"kr.key";
static _Atomic(bool) gOn = true;
static _Atomic(int) gKey;
static _Atomic(double) gShiftDelay;
static _Atomic(float) gLevel = 1;
static _Atomic(int) gUsing;

void KRLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalKaraoke] %{public}@", line);
}

NSString *KRL(NSString *en, NSString *ko) {
	NSInteger lang = [NSUserDefaults.standardUserDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}

BOOL KROn(void) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:kOn];
	return v ? [v boolValue] : YES;
}

int KRUsing(void) { return atomic_load(&gUsing); }
int KRKey(void) { return atomic_load(&gKey); }
double KRShiftDelay(void) { return atomic_load(&gShiftDelay); }

static float KRLevel(id v) { return (v ? [v floatValue] : 100) / 100; }

#pragma mark - Stage

enum { kFifo = 16384, kPrefill = 2048, kPull = 8192 };

typedef struct {
	KRDSP dsp;
	KRPitch pitch;
	AudioUnit au, shifter;
	float *mid, *fifo, *out[KR_MAXCH], *in[KR_MAXCH];
	AudioBufferList *abl;
	unsigned max, ch;
	uint64_t fifoIn, fifoOut;
	double rate, latency, shiftDelay;
	Float64 time, shiftTime;
	int key;
	BOOL broken, shiftBroken, starved;
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

AudioUnit KRIsolatorNew(double rate, unsigned maxFrames, AURenderCallback feed, void *ref, BOOL offline, double *latency) {
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
		UInt32 max = maxFrames, off = offline;
		AURenderCallbackStruct cb = { feed, ref };
		const char *step = NULL;
		if (offline) AudioUnitSetProperty(au, kAudioUnitProperty_OfflineRender, kAudioUnitScope_Global, 0, &off, sizeof off);
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

// Key change: Apple's time-pitch unit at rate 1 pulls its input from a FIFO primed with kPrefill frames of silence,
// since it may ask for more than the tap's buffer at once; that costs kPrefill frames of delay while the key is changed.
static OSStatus KRShiftFeed(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *io) {
	KRTap *t = ref;
	if (n > kPull) return kAudioUnitErr_TooManyFramesToProcess;
	for (UInt32 b = 0; b < io->mNumberBuffers && b < t->ch; b++) {
		if (!io->mBuffers[b].mData) io->mBuffers[b].mData = t->in[b];
		io->mBuffers[b].mDataByteSize = n * sizeof(float);
	}
	for (UInt32 i = 0; i < n; i++) {
		BOOL have = t->fifoOut < t->fifoIn;
		for (UInt32 b = 0; b < io->mNumberBuffers && b < t->ch; b++) ((float *)io->mBuffers[b].mData)[i] = have ? t->fifo[b * kFifo + t->fifoOut % kFifo] : 0;
		if (have) t->fifoOut++;
		else t->starved = YES;
	}
	return noErr;
}

static AudioUnit KRShifter(KRTap *t, double rate) {
	AudioComponentDescription desc = { kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch, kAudioUnitManufacturer_Apple, 0, 0 };
	AudioComponent comp = AudioComponentFindNext(NULL, &desc);
	AudioUnit au = NULL;
	OSStatus e = comp ? AudioComponentInstanceNew(comp, &au) : kAudioUnitErr_InvalidElement;
	if (e) {
		KRLog(@"key: no time-pitch unit (%d)", (int)e);
		return NULL;
	}
	AudioStreamBasicDescription f = { rate, kAudioFormatLinearPCM, kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, t->ch, 32, 0 };
	UInt32 max = t->max;
	AURenderCallbackStruct cb = { KRShiftFeed, t };
	if ((e = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f)) ||
	    (e = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof f)) ||
	    (e = AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &max, sizeof max)) ||
	    (e = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb)) || (e = AudioUnitInitialize(au))) {
		KRLog(@"key: time-pitch setup failed (%d)", (int)e);
		AudioComponentInstanceDispose(au);
		return NULL;
	}
	Float64 lat = 0;
	UInt32 size = sizeof lat;
	AudioUnitGetProperty(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &lat, &size);
	t->shiftDelay = kPrefill / rate + lat;
	atomic_store(&gShiftDelay, t->shiftDelay);
	return au;
}

static void KRShift(KRTap *t, float **p, unsigned stride, size_t n) {
	int key = atomic_load(&gKey);
	if (!t->shifter || t->shiftBroken) return;
	if (key != t->key) {
		AudioUnitSetParameter(t->shifter, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, key * 100, 0);
		if (!key != !t->key) {
			AudioUnitReset(t->shifter, kAudioUnitScope_Global, 0);
			memset(t->fifo, 0, sizeof(float) * kFifo * t->ch);
			t->fifoOut = 0, t->fifoIn = kPrefill;
		}
		t->key = key;
	}
	if (!key || n > t->max) return;
	if (t->fifoIn - t->fifoOut > kFifo - n) t->fifoOut = t->fifoIn - kPrefill;
	for (size_t i = 0; i < n; i++)
		for (unsigned c = 0; c < t->ch; c++) t->fifo[c * kFifo + (t->fifoIn + i) % kFifo] = p[c][i * stride];
	t->fifoIn += n;
	t->abl->mNumberBuffers = t->ch;
	for (unsigned c = 0; c < t->ch; c++) t->abl->mBuffers[c] = (AudioBuffer){ 1, (UInt32)(n * sizeof(float)), t->out[c] };
	AudioUnitRenderActionFlags flags = 0;
	AudioTimeStamp ts = { .mSampleTime = t->shiftTime, .mFlags = kAudioTimeStampSampleTimeValid };
	OSStatus e = AudioUnitRender(t->shifter, &flags, &ts, 0, (UInt32)n, t->abl);
	t->shiftTime += n;
	if (e) {
		t->shiftBroken = YES;
		dispatch_async(dispatch_get_main_queue(), ^{ KRLog(@"key: render failed (%d), original key for this song", (int)e); });
		return;
	}
	for (unsigned c = 0; c < t->ch; c++) {
		const float *o = t->abl->mBuffers[c].mData;
		for (size_t i = 0; i < n; i++) p[c][i * stride] = o[i];
	}
	if (t->starved) {
		t->starved = NO;
		dispatch_async(dispatch_get_main_queue(), ^{ KRLog(@"key: time-pitch ran dry"); });
	}
}

static void KRFree(void *ctx) {
	KRTap *t = ctx;
	if (t->au) AudioUnitUninitialize(t->au), AudioComponentInstanceDispose(t->au);
	if (t->shifter) AudioUnitUninitialize(t->shifter), AudioComponentInstanceDispose(t->shifter);
	KRDSPFree(&t->dsp);
	for (unsigned c = 0; c < KR_MAXCH; c++) free(t->out[c]), free(t->in[c]);
	free(t->mid), free(t->fifo), free(t->abl);
	free(t);
}

static void *KRPrepare(NSString *uri, double rate, unsigned ch, unsigned max) {
	KRTap *t = calloc(1, sizeof *t);
	t->max = max;
	t->mid = calloc(max, sizeof(float));
	t->rate = rate;
	t->ch = ch <= KR_MAXCH ? ch : 0;
	if (t->ch) {
		t->fifo = calloc(kFifo * ch, sizeof(float));
		t->abl = calloc(1, offsetof(AudioBufferList, mBuffers) + ch * sizeof(AudioBuffer));
		for (unsigned c = 0; c < ch; c++) t->out[c] = calloc(max, sizeof(float)), t->in[c] = calloc(kPull, sizeof(float));
		t->shifter = KRShifter(t, rate);
	}
	KRPitchInit(&t->pitch, rate);
	double latency = 0;
	if ([NSUserDefaults.standardUserDefaults integerForKey:kEngine] == 0) t->au = KRIsolatorNew(rate, max, KRFeed, t, NO, &latency);
	t->latency = latency;
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

static void KRVoice(KRTap *t, float **p, unsigned stride, size_t n, double time) {
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
		if (isfinite(time) && KRTapCheckWanted()) {
			double at = time - t->latency - KRPitchDelay(&t->pitch);
			float note;
			for (size_t i = 0; i < n; i++)
				if (KRPitchPush(&t->pitch, vocal[i], 0.01f, &note, NULL, NULL)) KRTapCheckPush(at + (i + 1) / t->rate, note);
		}
	}
	t->time += n;
	KRSubtract(&t->dsp, p, stride, n, vocal, vocal ? target : 0);
}

static void KRProcess(void *ctx, float **p, unsigned stride, size_t n, BOOL start, double time) {
	KRTap *t = ctx;
	if (start) {
		KRDSPReset(&t->dsp);
		if (t->au) AudioUnitReset(t->au, kAudioUnitScope_Global, 0);
		if (t->shifter && t->key) {
			AudioUnitReset(t->shifter, kAudioUnitScope_Global, 0);
			memset(t->fifo, 0, sizeof(float) * kFifo * t->ch);
			t->fifoOut = 0, t->fifoIn = kPrefill;
		}
	}
	KRVoice(t, p, stride, n, time);
	KRShift(t, p, stride, n);
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
	NSMutableArray *keys = [NSMutableArray array];
	for (int k = 6; k >= -6; k--)
		[keys addObject:@[ @(k), k ? [NSString stringWithFormat:@"%@%d", k > 0 ? @"+" : @"−", abs(k)] : KRL(@"Original key", @"원키") ]];
	return @[
		@{ @"items": @[
			   @{ @"type": @"switch", @"key": kOn, @"default": @YES, @"title": KRL(@"Turn vocals down", @"보컬 줄이기"), @"detail": KRStatus(),
			      @"set": ^(id v) {
				      atomic_store(&gOn, v ? [v boolValue] : true);
				      KRScoreSet([NSUserDefaults.standardUserDefaults boolForKey:kScore]);
			      } },
			   @{ @"type": @"choice", @"key": kLevel, @"default": @100, @"title": KRL(@"Amount", @"줄이는 양"), @"indent": @YES, @"visible": ^BOOL { return KROn(); },
			      @"options": @[ @[ @100, @"100%" ], @[ @75, @"75%" ], @[ @50, @"50%" ] ], @"set": ^(id v) { atomic_store(&gLevel, KRLevel(v)); } },
			   @{ @"type": @"switch", @"key": kScore, @"default": @NO, @"title": KRL(@"Scoring", @"채점"), @"indent": @YES, @"visible": ^BOOL { return KROn(); },
			      @"detail": KRScoreStatus(), @"set": ^(id v) { KRScoreSet([v boolValue]); } },
			   @{ @"type": @"switch", @"key": @"kr.bar", @"default": @YES, @"title": KRL(@"Pitch bar", @"음정 바"), @"indent": @YES,
			      @"detail": KRL(@"The singer's notes and your voice at the top of the screen", @"화면 위에 원곡 음과 내 목소리를 보여줘요"),
			      @"visible": ^BOOL { return KROn() && [NSUserDefaults.standardUserDefaults boolForKey:kScore]; } },
			   @{ @"type": @"choice", @"key": kKey, @"default": @0, @"title": KRL(@"Key", @"키"), @"options": keys,
			      @"set": ^(id v) { atomic_store(&gKey, [v intValue]); } },
			   @{ @"type": @"choice", @"key": kEngine, @"default": @0, @"title": KRL(@"Method", @"방식"),
			      @"options": @[ @[ @0, KRL(@"Apple voice isolation", @"Apple 목소리 분리"), KRL(@"Center cancel if it doesn't work", @"안 되면 센터 제거") ],
			                     @[ @1, KRL(@"Center cancel", @"센터 제거"), KRL(@"Classic karaoke: drops what's in the middle", @"가운데 소리를 빼는 옛 노래방 방식") ] ] },
		   ],
		   @"footer": KRL(@"Needs Secondary Login (Advanced). On/off, amount and key change right away, the method from the next song. "
		                  @"Scoring listens through the microphone while a song plays and shows your score when it ends.",
		                  @"보조 로그인(고급)이 필요해요. 켜고 끄기와 양, 키는 바로, 방식은 다음 곡부터 바뀌어요. "
		                  @"채점은 곡이 나오는 동안 마이크로 듣고, 곡이 끝나면 점수를 보여줘요.") },
	];
}
@end

__attribute__((constructor)) static void KRInit(void) {
	NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
	if (NSClassFromString(@"TTCore") && ![d boolForKey:@"tt.TidalKaraoke.enabled"]) return KRLog(@"turned off in TidalCore's settings");
	atomic_store(&gOn, KROn());
	atomic_store(&gLevel, KRLevel([d objectForKey:kLevel]));
	atomic_store(&gKey, (int)[d integerForKey:kKey]);
	TTAudioAddFn add = dlsym(RTLD_DEFAULT, "TTAudioAdd");
	if (!add) return KRLog(@"needs TidalCore");
	static const TTAudioStage stage = { KRWantsV1, NULL, KRPrepare, KRProcess, KRFree };
	add(&stage);
	KRScoreInit();
	KRLog(@"loaded");
}
