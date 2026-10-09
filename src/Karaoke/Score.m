#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import "DSP.h"
#import "KR.h"

static NSString *const kScore = @"kr.score";
static const double kWindow = 0.4, kSettle = 0.8;
static const float kMicGate = 0.003f;
static const NSUInteger kMinSung = 400;
enum { kRing = 2048 };

static KRFrame gMic[kRing];
static _Atomic(unsigned) gMicHead;

static void KRRingPush(KRFrame *ring, _Atomic(unsigned) *head, KRFrame f) {
	unsigned h = atomic_load_explicit(head, memory_order_relaxed);
	ring[h % kRing] = f;
	atomic_store_explicit(head, h + 1, memory_order_release);
}

#pragma mark - Live check

// Diagnostic: the tap's live isolated voice, pitched the same way, compared frame by frame with the file analysis.
static KRFrame gTapRing[kRing];
static _Atomic(unsigned) gTapHead;
static _Atomic(bool) gTapWanted;
static unsigned gTapTail, gCheck[4];

BOOL KRTapCheckWanted(void) { return atomic_load(&gTapWanted); }
void KRTapCheckPush(double time, float note) { KRRingPush(gTapRing, &gTapHead, (KRFrame){ time, note }); }

#pragma mark - Reference

// The singer's pitch for the whole song, worked out ahead of playback from the downloaded file (Core plays v1 from a local
// .m4a) through a second voice isolator run offline, so the pitch bar can show what's coming.
@interface KRTrack : NSObject {
@public
	NSMutableData *frames;
	_Atomic(unsigned) count;
	_Atomic(bool) cancelled;
	unsigned capacity;
	NSUInteger item;
	const float *chunk;
}
@end
@implementation KRTrack
@end

static OSStatus KRTrackFeed(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *io) {
	KRTrack *t = (__bridge KRTrack *)ref;
	for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
		if (io->mBuffers[b].mData) memcpy(io->mBuffers[b].mData, t->chunk, n * sizeof(float));
		else io->mBuffers[b].mData = (void *)t->chunk;
		io->mBuffers[b].mDataByteSize = n * sizeof(float);
	}
	return noErr;
}

static void KRTrackRun(KRTrack *t, NSURL *url) {
	enum { kChunk = 1024 };
	const double rate = 44100;
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
	__block AVAssetTrack *track;
	dispatch_semaphore_t sem = dispatch_semaphore_create(0);
	[asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *e) {
		track = tracks.firstObject;
		dispatch_semaphore_signal(sem);
	}];
	dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
	AVAssetReader *reader = track ? [AVAssetReader assetReaderWithAsset:asset error:nil] : nil;
	AVAssetReaderTrackOutput *out = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
		AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(rate), AVNumberOfChannelsKey: @1, AVLinearPCMBitDepthKey: @32,
		AVLinearPCMIsFloatKey: @YES, AVLinearPCMIsNonInterleaved: @NO, AVLinearPCMIsBigEndianKey: @NO
	}];
	if (!reader || ![reader canAddOutput:out]) return KRLog(@"reference: can't read %@", url.lastPathComponent);
	[reader addOutput:out];
	double latency = 0;
	AudioUnit au = KRIsolatorNew(rate, kChunk, KRTrackFeed, (__bridge void *)t, YES, &latency);
	if (!au || ![reader startReading]) {
		if (au) AudioUnitUninitialize(au), AudioComponentInstanceDispose(au);
		return KRLog(@"reference: no isolator");
	}
	KRPitch pitch;
	KRPitchInit(&pitch, rate);
	pitch.threshold = 0.25f;
	double delay = latency + KRPitchDelay(&pitch), start = CACurrentMediaTime();
	// Layered vocals blur the period, so the dip threshold is looser here; what the isolator lets through of the band in the
	// intro is pitched too, but it comes out far quieter than the song: frames where the voice is 14 dB+ under the mix (both
	// smoothed over ~8 chunks, the mix delayed by the isolator's latency) count as unvoiced.
	enum { kHist = 16 };
	double inHist[kHist] = { 0 }, voiceLevel = 0, mixLevel = 0;
	unsigned lagChunks = MIN(kHist - 1, (unsigned)lround(latency * rate / kChunk)), chunks = 0, leaked = 0;
	float buf[kChunk], vocalCopy[kChunk];
	unsigned fill = 0;
	uint64_t done = 0;
	double origin = NAN, vocalSum = 0, inSum = 0;
	unsigned voiced = 0;
	KRFrame *frames = t->frames.mutableBytes;
	NSMutableData *pcm = [NSMutableData data];
	while (!atomic_load(&t->cancelled)) {
		CMSampleBufferRef sb = [out copyNextSampleBuffer];
		if (!sb) break;
		if (isnan(origin)) {
			CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
			origin = CMTIME_IS_NUMERIC(pts) ? CMTimeGetSeconds(pts) : 0;
		}
		CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
		size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
		pcm.length = len;
		if (len && !CMBlockBufferCopyDataBytes(bb, 0, len, pcm.mutableBytes)) {
			const float *x = pcm.bytes;
			for (size_t i = 0; i < len / sizeof(float) && !atomic_load(&t->cancelled); i++) {
				inSum += x[i] * x[i];
				buf[fill++] = x[i];
				if (fill < kChunk) continue;
				fill = 0;
				t->chunk = buf;
				double eIn = 0;
				for (unsigned j = 0; j < kChunk; j++) eIn += buf[j] * buf[j];
				inHist[chunks % kHist] = eIn / kChunk;
				AudioUnitRenderActionFlags flags = 0;
				AudioTimeStamp ts = { .mSampleTime = done, .mFlags = kAudioTimeStampSampleTimeValid };
				AudioBufferList abl = { 1, { { 1, sizeof vocalCopy, vocalCopy } } };
				if (AudioUnitRender(au, &flags, &ts, 0, kChunk, &abl)) {
					atomic_store(&t->cancelled, true);
					break;
				}
				const float *vocal = abl.mBuffers[0].mData;
				double eVoice = 0;
				for (unsigned j = 0; j < kChunk; j++) eVoice += vocal[j] * vocal[j];
				voiceLevel += (eVoice / kChunk - voiceLevel) * 0.25;
				mixLevel += (inHist[(chunks + kHist - lagChunks) % kHist] - mixLevel) * 0.25;
				chunks++;
				BOOL leak = voiceLevel < mixLevel * 0.04;
				for (unsigned j = 0; j < kChunk; j++) {
					float note, alt[2], dip;
					vocalSum += vocal[j] * vocal[j];
					if (!KRPitchPush(&pitch, vocal[j], 0.01f, &note, alt, &dip)) continue;
					unsigned c = atomic_load_explicit(&t->count, memory_order_relaxed);
					if (c >= t->capacity) continue;
					if (note > 0 && leak) note = 0, alt[0] = alt[1] = 0, leaked++;
					voiced += note > 0;
					frames[c] = (KRFrame){ origin + (done + j + 1) / rate - delay, note, { alt[0], alt[1] }, dip };
					atomic_store_explicit(&t->count, c + 1, memory_order_release);
				}
				done += kChunk;
			}
		}
		CFRelease(sb);
	}
	[reader cancelReading];
	AudioUnitUninitialize(au), AudioComponentInstanceDispose(au);
	unsigned count = atomic_load(&t->count);
	KRLog(@"reference: %.0f s of %@ in %.1f s%@, starts at %.3f s, isolator latency %.1f ms, voiced %.0f%% (%.0f%% dropped as band leaking through), level %.0f dBFS in, %.0f dBFS voice", done / rate,
	      url.lastPathComponent, CACurrentMediaTime() - start, atomic_load(&t->cancelled) ? @" (stopped)" : @"", origin, latency * 1000, count ? 100.0 * voiced / count : 0,
	      count ? 100.0 * leaked / count : 0,
	      10 * log10(inSum / fmax(done, 1) + 1e-12), 10 * log10(vocalSum / fmax(done, 1) + 1e-12));
}

static KRTrack *gTrack;
static unsigned gTrackTail;

static void KRTrackStart(AVPlayerItem *item) {
	if (gTrack) atomic_store(&gTrack->cancelled, true);
	gTrack = nil, gTrackTail = 0;
	NSURL *url = ((AVURLAsset *)item.asset).URL;
	double seconds = CMTimeGetSeconds(item.asset.duration);
	if (!url.isFileURL || !isfinite(seconds) || seconds <= 0) return;
	KRTrack *t = [KRTrack new];
	t->item = url.absoluteString.hash;
	t->capacity = (unsigned)(seconds * 44100 / 1024) + 256;
	t->frames = [NSMutableData dataWithLength:t->capacity * sizeof(KRFrame)];
	gTrack = t;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ KRTrackRun(t, url); });
}

static double KRHostNow(void) { return [AVAudioTime secondsForHostTime:mach_absolute_time()]; }

#pragma mark - Mic

// Switching the session category and starting the input take ~0.5-1 s and make AirPods renegotiate, so they run on their
// own queue (the main thread never waits), and a pause keeps the mic up for kPauseGrace so playing on is instant.
static const double kPauseGrace = 20;
static AVAudioEngine *gEngine;
static KRPitch gMicPitch;
static AVAudioSessionCategory gPrevCategory;
static AVAudioSessionMode gPrevMode;
static AVAudioSessionCategoryOptions gPrevOptions;
static _Atomic(bool) gMicWanted;
static double gMicFailedAt = -100;

static dispatch_queue_t KRMicQueue(void) {
	static dispatch_queue_t q;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ q = dispatch_queue_create("TidalKaraoke.mic", DISPATCH_QUEUE_SERIAL); });
	return q;
}

static void KRMicDown(void) {
	if (!gEngine) return;
	[gEngine.inputNode removeTapOnBus:0];
	[gEngine stop];
	gEngine = nil;
	[AVAudioSession.sharedInstance setCategory:gPrevCategory mode:gPrevMode options:gPrevOptions error:nil];
	KRLog(@"mic off");
}

static BOOL KRMicUp(void) {
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
	gMicPitch.threshold = 0.22f;
	double rate = f.sampleRate, delay = KRPitchDelay(&gMicPitch);
	[input installTapOnBus:0 bufferSize:1024 format:f block:^(AVAudioPCMBuffer *b, AVAudioTime *when) {
		const float *x = b.floatChannelData ? b.floatChannelData[0] : NULL;
		if (!x || !when.hostTimeValid) return;
		double at = [AVAudioTime secondsForHostTime:when.hostTime] - delay;
		float note;
		for (AVAudioFrameCount i = 0; i < b.frameLength; i++)
			if (KRPitchPush(&gMicPitch, x[i], kMicGate, &note, NULL, NULL)) KRRingPush(gMic, &gMicHead, (KRFrame){ at + (i + 1) / rate, note });
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

static void KRMicStart(void) {
	if (CACurrentMediaTime() - gMicFailedAt < 5 || atomic_exchange(&gMicWanted, true)) return;
	dispatch_async(KRMicQueue(), ^{
		if (!atomic_load(&gMicWanted) || KRMicUp()) return;
		atomic_store(&gMicWanted, false);
		dispatch_async(dispatch_get_main_queue(), ^{ gMicFailedAt = CACurrentMediaTime(); });
	});
}

static void KRMicStop(void) {
	if (!atomic_exchange(&gMicWanted, false)) return;
	dispatch_async(KRMicQueue(), ^{
		if (!atomic_load(&gMicWanted)) KRMicDown();
	});
}

#pragma mark - Scoring

static NSHashTable<AVPlayer *> *gPlayers;
static dispatch_source_t gTimer;
static __weak AVPlayerItem *gItem;
static NSString *gTitle;
static NSMutableData *gRefs, *gMics, *gShow;
static unsigned gMicTail;
static KRTally gTally;
static NSString *gEvent;
static double gEventAt;
static double gLastSong, gLastHost, gLiveAt, gRate, gPausedAt;
static KRLag gLag;
static KRClean gClean;
static KRSmooth gSmooth;
static unsigned gFixed;
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
	gRefs.length = gMics.length = gShow.length = 0;
	memset(&gClean, 0, sizeof gClean);
	gFixed += gSmooth.fixed;
	memset(&gSmooth, 0, sizeof gSmooth);
	gLastHost = 0;
	gMicTail = atomic_load(&gMicHead);
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
	unsigned checked = gCheck[0] + gCheck[1] + gCheck[2];
	if (checked > 200)
		KRLog(@"live vs file: both voiced %.0f%% (pitch within 1 st %.0f%%), only file %.0f%%, only live %.0f%% of %u frames", 100.0 * gCheck[0] / checked,
		      gCheck[0] ? 100.0 * gCheck[3] / gCheck[0] : 0, 100.0 * gCheck[1] / checked, 100.0 * gCheck[2] / checked, checked);
	memset(gCheck, 0, sizeof gCheck);
	unsigned sung = KRTallySung(&gTally);
	if (sung >= kMinSung) {
		int pitch, rhythm, phrase, score = KRTallyScore(&gTally, &pitch, &rhythm, &phrase);
		const unsigned *g = gTally.grades;
		NSString *parts = [NSString stringWithFormat:KRL(@"Pitch %d · Rhythm %d · Phrases %u/%u\nVibrato %u · Long tones %u", @"음정 %d · 리듬 %d · 소절 %u/%u\n비브라토 %u · 롱톤 %u"), pitch,
		                                             rhythm, gTally.cleared, gTally.phrases, gTally.vibratos, gTally.longTones];
		NSString *counts = [NSString stringWithFormat:@"Perfect %u · Cool %u · Good %u · Bad %u · Miss %u", g[3], g[2], g[1], g[0], g[4]];
		KRLog(@"score %d for %@ (%@ · %@, you sang %.0f ms behind, %u mic frames moved back an octave and a fifth or so)", score, gTitle,
		      [parts stringByReplacingOccurrencesOfString:@"\n" withString:@" · "], counts, gLag.lag * 1000, gFixed + gSmooth.fixed);
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
	gFixed = 0, gSmooth.fixed = 0;
	gLive = -1, gEvent = nil;
	KRClear();
}

#pragma mark - Pitch bar

static double KRSongNow(void) { return gLastSong + (KRHostNow() - gLastHost) * gRate; }

// At least 17 semitone lanes (VIBE's note view), widened to fit every note of the singer in sight; 1.5 s past, 3.5 s ahead.
// Your voice is drawn in the octave nearest the singer's note at that moment, so singing it an octave off still lines up.
@interface KRBar : UIView
@property (nonatomic) float focus, lanes;
@end

@implementation KRBar
- (void)step:(CADisplayLink *)link {
	[self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
	const double past = 1.5, span = 5;
	double now = KRSongNow(), from = now - past;
	CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
	const KRFrame *refs = gShow.bytes, *mics = gMics.bytes;
	NSUInteger nr = gShow.length / sizeof(KRFrame), nm = gMics.length / sizeof(KRFrame);
	float lo = INFINITY, hi = -INFINITY;
	for (NSUInteger i = 0; i < nr; i++)
		if (refs[i].note > 0 && refs[i].time >= from && refs[i].time <= from + span) lo = fminf(lo, refs[i].note), hi = fmaxf(hi, refs[i].note);
	if (lo <= hi) {
		float mid = (lo + hi) / 2, want = fmaxf(17, hi - lo + 3);
		self.focus = self.focus ? self.focus + (mid - self.focus) * 0.08f : mid;
		self.lanes = self.lanes ? self.lanes + (want - self.lanes) * 0.08f : want;
	}
	if (!self.focus) return;
	float c = self.focus;
	CGFloat lane = h / self.lanes;
	CGFloat (^X)(double) = ^CGFloat(double t) { return (t - from) / span * w; };
	CGFloat (^Y)(float) = ^CGFloat(float note) { return MAX(lane / 2, MIN(h - lane / 2, h / 2 - (note - c) * lane)); };

	[[UIColor.labelColor colorWithAlphaComponent:0.28] setFill];
	for (NSUInteger i = 0; i < nr;) {
		if (refs[i].note <= 0) {
			i++;
			continue;
		}
		NSUInteger j = i;
		double sum = 0;
		while (j < nr && refs[j].note > 0 && fabsf(refs[j].note - refs[i].note) < 0.6f && (j == i || refs[j].time - refs[j - 1].time < 0.06)) sum += refs[j++].note;
		CGFloat x0 = X(refs[i].time), x1 = X(refs[j - 1].time) + 3;
		if (x1 > 0 && x0 < w)
			[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x0, Y(sum / (j - i)) - lane * 0.45, x1 - x0, lane * 0.9) cornerRadius:lane * 0.45] fill];
		i = j;
	}

	[[UIColor.labelColor colorWithAlphaComponent:0.14] setFill];
	for (NSUInteger i = 0; i < nr; i++)
		for (int a = 0; a < 2; a++) {
			if (refs[i].note <= 0 || refs[i].alt[a] <= 0) continue;
			float n = refs[i].alt[a], base = refs[i].note;
			while (n - base > 6) n -= 12;
			while (n - base < -6) n += 12;
			UIRectFill(CGRectMake(X(refs[i].time), Y(n) - lane * 0.3, 3, lane * 0.6));
		}

	UIBezierPath *voice = [UIBezierPath bezierPath];
	BOOL pen = NO;
	float last = 0;
	NSUInteger r = 0;
	for (NSUInteger i = 0; i < nm; i++) {
		double t = mics[i].time - gLag.lag;
		float u = mics[i].note;
		if (u <= 0 || t < from || t > now) {
			pen = NO;
			continue;
		}
		while (r < nr && refs[r].time < t - 0.3) r++;
		float anchor = c;
		double gap = 0.3;
		for (NSUInteger j = r; j < nr && refs[j].time <= t + 0.3; j++)
			if (refs[j].note > 0 && fabs(refs[j].time - t) <= gap) gap = fabs(refs[j].time - t), anchor = refs[j].note;
		while (u - anchor > 6) u -= 12;
		while (u - anchor < -6) u += 12;
		if (pen && (mics[i].time - mics[i - 1].time > 0.06 || fabsf(u - last) > 6)) pen = NO;
		CGPoint pt = CGPointMake(X(t), Y(u));
		pen ? [voice addLineToPoint:pt] : [voice moveToPoint:pt];
		pen = YES, last = u;
	}
	voice.lineWidth = 2.5;
	voice.lineCapStyle = kCGLineCapRound;
	voice.lineJoinStyle = kCGLineJoinRound;
	[UIColor.systemYellowColor setStroke];
	[voice stroke];

	[[UIColor.labelColor colorWithAlphaComponent:0.5] setFill];
	UIRectFill(CGRectMake(X(now) - 0.5, 0, 1, h));
}
@end

static UIVisualEffectView *gBarBox;
static KRBar *gBar;
static CADisplayLink *gBarLink;

static UIVisualEffect *KRGlass(void) {
	if (@available(iOS 26.0, *)) return [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
	return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
}

static void KRBarShow(UIWindow *w, CGFloat top) {
	id on = [NSUserDefaults.standardUserDefaults objectForKey:@"kr.bar"];
	if (!w || (on && ![on boolValue])) {
		gBarBox.hidden = YES;
		[gBarLink invalidate], gBarLink = nil;
		return;
	}
	if (!gBarBox) {
		gBarBox = [[UIVisualEffectView alloc] initWithEffect:KRGlass()];
		gBarBox.userInteractionEnabled = NO;
		gBarBox.clipsToBounds = YES;
		gBarBox.layer.cornerRadius = 16;
		gBar = [KRBar new];
		gBar.opaque = NO;
		gBar.backgroundColor = UIColor.clearColor;
		gBar.contentMode = UIViewContentModeRedraw;
		[gBarBox.contentView addSubview:gBar];
	}
	if (gBarBox.superview != w) [w addSubview:gBarBox];
	[w bringSubviewToFront:gBarBox];
	gBarBox.frame = CGRectMake(16, top, w.bounds.size.width - 32, 64);
	gBar.frame = CGRectInset(gBarBox.bounds, 10, 4);
	gBarBox.hidden = NO;
	if (!gBarLink) {
		gBarLink = [CADisplayLink displayLinkWithTarget:gBar selector:@selector(step:)];
		[gBarLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
	}
}

#pragma mark - HUD

static UIVisualEffectView *gHUD;
static UILabel *gHUDLabel;

static void KRHUD(BOOL show) {
	if (!show) {
		gHUD.hidden = YES;
		KRBarShow(nil, 0);
		return;
	}
	UIWindow *w = KRTop().view.window;
	if (!w) return;
	if (!gHUD) {
		gHUD = [[UIVisualEffectView alloc] initWithEffect:KRGlass()];
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
	KRBarShow(w, CGRectGetMaxY(gHUD.frame) + 6);
}

#pragma mark - Tick

static void KRStop(void) {
	gPausedAt = 0;
	atomic_store(&gTapWanted, false);
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
		if (refs[done].note > 0 && g != 5) gLive = g, gLiveAt = CACurrentMediaTime();
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
	if (!KRWanted()) return KRStop();
	if (!p) {
		if (!gPausedAt) gPausedAt = CACurrentMediaTime();
		KRHUD(NO);
		if (CACurrentMediaTime() - gPausedAt > kPauseGrace) KRStop();
		return;
	}
	gPausedAt = 0;
	AVPlayerItem *item = p.currentItem;
	if (item != gItem) {
		KRFinish();
		gItem = item;
		KRTrackStart(item);
		gTitle = nil;
	}
	KRMicStart();
	double song = CMTimeGetSeconds(p.currentTime), host = KRHostNow(), rate = p.rate;
	if (!isfinite(song)) return;
	if (song < 5 || !gTitle) gTitle = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyTitle];
	if (gLastHost > 0 && fabs((song - gLastSong) - (host - gLastHost) * rate) > 0.5) KRClear(), gTrackTail = 0;
	gLastSong = song, gLastHost = host, gRate = rate;
	if (!gTrack && item) KRTrackStart(item);
	unsigned ready = gTrack ? atomic_load_explicit(&gTrack->count, memory_order_acquire) : 0;
	const KRFrame *track = gTrack ? gTrack->frames.bytes : NULL;
	int key = KRKey();
	double shift = key ? KRShiftDelay() : 0;
	for (; gTrackTail < ready && track[gTrackTail].time + shift < song + 6; gTrackTail++) {
		KRFrame r = track[gTrackTail];
		r.time += shift;
		if (r.time < song - 1) continue;
		if (r.note > 0) r.note += key;
		for (int a = 0; a < 2; a++)
			if (r.alt[a] > 0) r.alt[a] += key;
		KRFrame out[9];
		size_t k = KRCleanPush(&gClean, r, out);
		[gRefs appendBytes:out length:k * sizeof(KRFrame)];
		[gShow appendBytes:out length:k * sizeof(KRFrame)];
	}
	const KRFrame *shown = gShow.bytes;
	NSUInteger stale = 0;
	while (stale < gShow.length / sizeof(KRFrame) && shown[stale].time < song - 2) stale++;
	[gShow replaceBytesInRange:NSMakeRange(0, stale * sizeof(KRFrame)) withBytes:NULL length:0];
	for (unsigned h = atomic_load_explicit(&gMicHead, memory_order_acquire); gMicTail != h; gMicTail++) {
		if (h - gMicTail > kRing) gMicTail = h - kRing;
		KRFrame f = gMic[gMicTail % kRing];
		f.time = song - (host - f.time) * rate;
		KRFrame smooth;
		if (!KRSmoothPush(&gSmooth, f, &smooth)) continue;
		[gMics appendBytes:&smooth length:sizeof(KRFrame)];
		KRTallyMic(&gTally, smooth);
	}
	atomic_store(&gTapWanted, true);
	for (unsigned h = atomic_load_explicit(&gTapHead, memory_order_acquire); gTapTail != h; gTapTail++) {
		if (h - gTapTail > kRing) gTapTail = h - kRing;
		KRFrame live = gTapRing[gTapTail % kRing];
		const KRFrame *file = gShow.bytes;
		NSUInteger nf = gShow.length / sizeof(KRFrame), best = NSNotFound;
		for (NSUInteger i = 0; i < nf; i++)
			if (fabs(file[i].time - live.time - shift) < 0.015 && (best == NSNotFound || fabs(file[i].time - live.time - shift) < fabs(file[best].time - live.time - shift))) best = i;
		if (best == NSNotFound || (live.note <= 0 && file[best].note <= 0)) continue;
		if (live.note > 0 && file[best].note > 0) {
			gCheck[0]++;
			float d = fmodf(fabsf(live.note + key - file[best].note), 12);
			if (fminf(d, 12 - d) <= 1) gCheck[3]++;
		} else gCheck[file[best].note > 0 ? 1 : 2]++;
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
	return KRL(@"Compares your pitch with the singer's · earphones recommended", @"부른 음정을 원곡 목소리와 비교해요 · 이어폰 권장");
}

void KRScoreInit(void) {
	gPlayers = [NSHashTable weakObjectsHashTable];
	gRefs = [NSMutableData data];
	gMics = [NSMutableData data];
	gShow = [NSMutableData data];
	[NSNotificationCenter.defaultCenter addObserverForName:AVPlayerRateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		if ([n.object isKindOfClass:AVPlayer.class]) [gPlayers addObject:n.object];
		KRWake();
	}];
	[NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
		if (n.object && n.object == gItem) KRFinish(), gItem = nil;
	}];
}
