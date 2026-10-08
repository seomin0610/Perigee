#include "DSP.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static const double kBassHz = 120, kAirHz = 8000;

static void KRButterworth(float *c, int high, double f0, double rate) {
	double w = 2 * M_PI * f0 / rate, cs = cos(w), al = sin(w) / M_SQRT2, a0 = 1 + al;
	double b = high ? (1 + cs) / 2 : (1 - cs) / 2;
	c[0] = b / a0, c[1] = (high ? -2 * b : 2 * b) / a0, c[2] = b / a0, c[3] = -2 * cs / a0, c[4] = (1 - al) / a0;
}

static inline float KRBiquad(const float *c, float *z, float x) {
	float y = c[0] * x + z[0];
	z[0] = c[1] * x - c[3] * y + z[1];
	z[1] = c[2] * x - c[4] * y;
	return y;
}

int KRDSPInit(KRDSP *d, double rate, unsigned ch, unsigned delay) {
	memset(d, 0, sizeof *d);
	if (!ch || ch > KR_MAXCH || rate <= 2 * kAirHz) return 0;
	d->ch = ch, d->len = delay;
	if (delay && !(d->delay = calloc((size_t)delay * ch, sizeof(float)))) return 0;
	KRButterworth(d->lp, 0, kBassHz, rate);
	KRButterworth(d->hp, 1, kAirHz, rate);
	return 1;
}

void KRDSPFree(KRDSP *d) {
	free(d->delay);
	d->delay = NULL;
}

void KRDSPReset(KRDSP *d) {
	if (d->delay) memset(d->delay, 0, sizeof(float) * d->len * d->ch);
	memset(d->zl, 0, sizeof d->zl), memset(d->zh, 0, sizeof d->zh);
	d->pos = 0;
}

// Mid minus its 120 Hz - 8 kHz part, side untouched: kick, bass and air stay, the centred voice goes.
void KRCenter(KRDSP *d, float **p, unsigned stride, size_t frames, float level) {
	float from = d->level;
	d->level = level;
	if (d->ch != 2 || (from == 0 && level == 0)) return;
	for (size_t i = 0; i < frames; i++) {
		float k = from + (level - from) * (i + 1) / frames;
		float *l = &p[0][i * stride], *r = &p[1][i * stride];
		float m = (*l + *r) / 2, s = (*l - *r) / 2;
		float keep = KRBiquad(d->lp, d->zl, m) + KRBiquad(d->hp, d->zh, m);
		m += k * (keep - m);
		*l = m + s, *r = m - s;
	}
}

// vocal lags the input by len samples (the isolator's latency), so the dry signal is delayed by the same amount.
void KRSubtract(KRDSP *d, float **p, unsigned stride, size_t frames, const float *vocal, float level) {
	float from = d->level;
	d->level = level;
	for (size_t i = 0; i < frames; i++) {
		float k = vocal ? from + (level - from) * (i + 1) / frames : 0;
		for (unsigned c = 0; c < d->ch; c++) {
			float *x = &p[c][i * stride], y = *x;
			if (d->len) y = d->delay[d->pos * d->ch + c], d->delay[d->pos * d->ch + c] = *x;
			*x = y - k * (vocal ? vocal[i] : 0);
		}
		if (d->len) d->pos = (d->pos + 1) % d->len;
	}
}

// YIN on the signal decimated to ~11 kHz: 512-sample window, 65 Hz - 1.1 kHz, one note (MIDI, 0 = unvoiced) per 256 samples.
void KRPitchInit(KRPitch *p, double rate) {
	memset(p, 0, sizeof *p);
	p->decim = rate > 16000 ? (unsigned)lround(rate / 11025) : 1;
	p->rate = rate / p->decim;
	p->tmin = (unsigned)(p->rate / 1100);
	p->tmax = (unsigned)(p->rate / 65);
	if (p->tmax > KR_PITCH_N - KR_PITCH_W - 2) p->tmax = KR_PITCH_N - KR_PITCH_W - 2;
}

double KRPitchDelay(const KRPitch *p) { return (KR_PITCH_W + p->tmax) / 2.0 / p->rate; }

static float KRYin(const KRPitch *p, float gate) {
	unsigned span = KR_PITCH_W + p->tmax;
	float x[KR_PITCH_N], d[KR_PITCH_N];
	for (unsigned i = 0; i < span; i++) x[i] = p->ring[(p->pos + KR_PITCH_N - span + i) % KR_PITCH_N];
	double energy = 0, sum = 0;
	for (unsigned i = 0; i < KR_PITCH_W; i++) energy += x[i] * x[i];
	if (sqrt(energy / KR_PITCH_W) < gate) return 0;
	for (unsigned tau = 1; tau <= p->tmax; tau++) {
		double s = 0;
		for (unsigned j = 0; j < KR_PITCH_W; j++) {
			float v = x[j] - x[j + tau];
			s += v * v;
		}
		sum += s;
		d[tau] = sum > 0 ? s * tau / sum : 1;
	}
	for (unsigned tau = p->tmin > 1 ? p->tmin : 2; tau < p->tmax; tau++) {
		if (d[tau] >= 0.15f) continue;
		while (tau + 1 < p->tmax && d[tau + 1] < d[tau]) tau++;
		float a = d[tau - 1], b = d[tau], c = d[tau + 1], den = a - 2 * b + c;
		float f0 = p->rate / (tau + (den != 0 ? 0.5f * (a - c) / den : 0));
		return 69 + 12 * log2f(f0 / 440);
	}
	return 0;
}

int KRPitchPush(KRPitch *p, float x, float gate, float *note) {
	p->acc += x;
	if (++p->accn < p->decim) return 0;
	p->ring[p->pos] = p->acc / p->decim;
	p->pos = (p->pos + 1) % KR_PITCH_N;
	p->acc = 0, p->accn = 0;
	if (p->count < KR_PITCH_N) p->count++;
	if (++p->hop < KR_PITCH_HOP) return 0;
	p->hop = 0;
	*note = p->count >= KR_PITCH_W + p->tmax ? KRYin(p, gate) : 0;
	return 1;
}

// VIBE's grades (0.3 / 0.8 / 1.2 semitones), octave folded so a song can be sung an octave up or down.
int KRGrade(float user, float ref) {
	float d = fmodf(fabsf(user - ref), 12);
	if (d > 6) d = 12 - d;
	return d <= 0.3f ? 3 : d <= 0.8f ? 2 : d <= 1.2f ? 1 : 0;
}

static const KRFrame *KRNearest(const KRFrame *mic, size_t n, double t) {
	size_t lo = 0, hi = n;
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		if (mic[mid].time < t) lo = mid + 1;
		else hi = mid;
	}
	if (lo == n || (lo > 0 && t - mic[lo - 1].time < mic[lo].time - t)) lo--;
	return n ? &mic[lo] : NULL;
}

static int KRCmp(const void *a, const void *b) { return (*(const float *)a > *(const float *)b) - (*(const float *)a < *(const float *)b); }

// The singer's lag behind the record = the 20 ms step within the window where the last 128 sung frames follow the melody's
// shape best (spread of the octave-folded pitch differences around their median, re-fitted every 8 frames), so a singer who
// is steadily sharp or flat isn't pulled onto the wrong beat; each frame is then graded against the one mic frame nearest
// that lag, averaged with its neighbours over ~160 ms so a vibrato around the right note isn't marked down. 4 = nothing sung.
int KRMatch(KRLag *l, const KRFrame *mic, size_t n, KRFrame ref, double window, float *user) {
	const double step = 0.02, near = 0.035;
	l->refs[l->pos] = ref;
	l->pos = (l->pos + 1) % 128;
	if (l->count < 128) l->count++;
	if (l->count >= 16 && ++l->since >= 8) {
		l->since = 0;
		double best = INFINITY;
		for (int k = -(int)(window / step); k <= (int)(window / step); k++) {
			float d[128], s[128];
			unsigned got = 0;
			for (unsigned j = 0; j < l->count; j++) {
				const KRFrame *m = KRNearest(mic, n, l->refs[j].time + k * step);
				if (!m || m->note <= 0 || fabs(m->time - l->refs[j].time - k * step) > near) continue;
				float x = fmodf(m->note - l->refs[j].note, 12);
				d[got++] = x > 6 ? x - 12 : x < -6 ? x + 12 : x;
			}
			if (!got) continue;
			memcpy(s, d, got * sizeof(float));
			qsort(s, got, sizeof(float), KRCmp);
			double cost = 3.0 * (l->count - got);
			for (unsigned j = 0; j < got; j++) cost += fminf(fabsf(d[j] - s[got / 2]), 3);
			if (cost < best) best = cost, l->lag = k * step;
		}
	}
	const KRFrame *m = KRNearest(mic, n, ref.time + l->lag);
	*user = m && m->note > 0 && fabs(m->time - ref.time - l->lag) <= near ? m->note : 0;
	if (*user <= 0) return 4;
	double sum = 0;
	int count = 0;
	for (size_t j = m - mic > 3 ? m - mic - 3 : 0; j < n && j <= (size_t)(m - mic) + 3; j++)
		if (mic[j].note > 0 && fabsf(mic[j].note - m->note) <= 1.5f && fabs(mic[j].time - m->time) <= 0.1) sum += mic[j].note, count++;
	return KRGrade(sum / count, ref.note);
}

static const double kWeight[5] = { 0.2, 0.5, 0.8, 1, 0 };

// A held note (the singer stays within 0.7 semitones of its mean) sung along for 1 s or more with at most 3 bad frames is a
// long tone; it is also vibrato when the user's pitch around its 9-frame moving average swings 4 - 8 times a second by
// 0.15 - 1.5 semitones (DAM: vibrato and long tones of a second or more earn points).
static int KRHoldEnd(KRTally *t) {
	int ev = 0;
	if (t->holdN && t->holdEnd - t->holdStart >= 1 && t->holdMiss <= 3) {
		t->longTones++, ev |= KRLongTone;
		unsigned crossings = 0, n = 0;
		double extent = 0;
		int sign = 0;
		for (unsigned i = 4; i + 4 < t->holdN; i++) {
			double avg = 0;
			for (unsigned j = i - 4; j <= i + 4; j++) avg += t->hold[j];
			double dev = t->hold[i] - avg / 9;
			extent += fabs(dev), n++;
			int s = dev > 0 ? 1 : -1;
			if (sign && s != sign) crossings++;
			sign = s;
		}
		double seconds = t->holdEnd - t->holdStart, rate = crossings / 2.0 / seconds;
		extent = n ? extent / n : 0;
		if (rate >= 4 && rate <= 8 && extent >= 0.15 && extent <= 1.5) t->vibratos++, ev |= KRVibrato;
	}
	t->holdN = 0, t->holdMiss = 0;
	return ev;
}

void KRTallyMic(KRTally *t, KRFrame mic) {
	if (mic.note <= 0) {
		t->micGap++;
		return;
	}
	if (t->micGap >= 2) t->userOn[t->userCount++ % 64] = mic.time;
	t->micGap = 0;
}

// One ref frame, in order, with its grade and the user's matched pitch. Phrases are the singer's voiced runs split by 0.35 s
// of silence (not the lyrics' lines, whose timing can be off); one is cleared at 60 % pitch. Rhythm: each place the singer
// starts a sound after 2+ silent frames is matched to the user's nearest start at their lag, full marks within 70 ms,
// none past 300 ms.
int KRTallyRef(KRTally *t, KRFrame ref, int grade, float user, double lag) {
	int ev = 0;
	if (ref.note <= 0) {
		t->refGap++;
		if (t->pFrames && ref.time - t->pLast >= 0.35) {
			if (t->pFrames >= 10) {
				t->phraseRate = t->pSum / t->pFrames;
				t->phrases++, ev |= KRPhraseEnded;
				if (t->phraseRate >= 0.6) t->cleared++;
			}
			t->pFrames = 0, t->pSum = 0;
		}
		if (t->refGap > 2) ev |= KRHoldEnd(t);
		return ev;
	}
	t->grades[grade]++;
	t->pFrames++, t->pSum += kWeight[grade], t->pLast = ref.time;
	if (t->refGap >= 2) {
		double best = 1;
		unsigned n = t->userCount < 64 ? t->userCount : 64;
		for (unsigned i = 0; i < n; i++) best = fmin(best, fabs(t->userOn[i] - lag - ref.time));
		t->onsets++;
		t->rhythm += best <= 0.07 ? 1 : best >= 0.3 ? 0 : 1 - (best - 0.07) / 0.23;
	}
	t->refGap = 0;
	if (!t->holdN || fabs(ref.note - t->holdRef) > 0.7 || t->holdN == 160) {
		ev |= KRHoldEnd(t);
		t->holdRef = ref.note, t->holdStart = ref.time;
	}
	t->holdRef += (ref.note - t->holdRef) / (t->holdN + 1);
	float held = user > 0 ? user : t->holdN ? t->hold[t->holdN - 1] : ref.note;
	t->hold[t->holdN++] = held;
	t->holdEnd = ref.time;
	if (grade == 0 || grade == 4) t->holdMiss++;
	return ev;
}

unsigned KRTallySung(const KRTally *t) { return t->grades[0] + t->grades[1] + t->grades[2] + t->grades[3] + t->grades[4]; }

// Pitch 70 + rhythm 15 + phrases 10, plus up to 5 for vibrato (1 each) and long tones (0.25 each).
int KRTallyScore(const KRTally *t, int *pitch, int *rhythm, int *phrase) {
	unsigned sung = KRTallySung(t);
	double p = 0;
	for (int g = 0; g < 5; g++) p += kWeight[g] * t->grades[g];
	p = sung ? 100 * p / sung : 0;
	double r = t->onsets ? 100 * t->rhythm / t->onsets : p, ph = t->phrases ? 100.0 * t->cleared / t->phrases : p;
	*pitch = (int)lround(p), *rhythm = (int)lround(r), *phrase = (int)lround(ph);
	return (int)lround(fmin(100, 0.7 * p + 0.15 * r + 0.1 * ph + fmin(5, t->vibratos + 0.25 * t->longTones)));
}
