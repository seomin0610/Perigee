#include "DSP.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static const float kCeiling = 0.891f;
static const double kLookahead = 0.002, kRelease = 0.15;
// Equal-loudness EQ like VIBE's (Gaudio ELEQ): the volume table, the step formula and the +7 dB lift follow VIBE and
// GaudioSolMusicOne's imp_eleq_update; its 80-step EQ table isn't copied, two shelves fitted to its measured response stand in.
static const float kVolumeDb[16] = { 0, -30, -30, -30, -29, -27, -25, -23, -21, -19, -16, -13, -10, -7, -4, 0 };
static const double kBassHz = 974, kBassS = 1.49, kBassMax = 20.5, kTrebleHz = 10133, kTrebleS = 1.04, kTrebleMax = 15.3, kLiftDb = 7;

static void LDShelf(float *c, int high, double f0, double db, double S, double rate) {
	double A = pow(10, db / 40), w = 2 * M_PI * f0 / rate, cs = cos(w), k = high ? -1 : 1;
	double sa = 2 * sqrt(A) * sin(w) / 2 * sqrt((A + 1 / A) * (1 / S - 1) + 2);
	double b0 = A * ((A + 1) - k * (A - 1) * cs + sa), b1 = 2 * k * A * ((A - 1) - k * (A + 1) * cs), b2 = A * ((A + 1) - k * (A - 1) * cs - sa);
	double a0 = (A + 1) + k * (A - 1) * cs + sa, a1 = -2 * k * ((A - 1) + k * (A + 1) * cs), a2 = (A + 1) + k * (A - 1) * cs - sa;
	c[0] = b0 / a0, c[1] = b1 / a0, c[2] = b2 / a0, c[3] = a1 / a0, c[4] = a2 / a0;
}

static inline float LDBiquad(const float *c, float *z, float x) {
	float y = c[0] * x + z[0];
	z[0] = c[1] * x - c[3] * y + z[1];
	z[1] = c[2] * x - c[4] * y;
	return y;
}

int LDDSPInit(LDDSP *d, double rate, unsigned ch, float gain) {
	memset(d, 0, sizeof *d);
	if (!ch || ch > LD_MAXCH || rate <= 0) return 0;
	d->rate = rate, d->ch = ch, d->gain = gain, d->ceiling = kCeiling;
	d->len = rate * kLookahead > 2 ? (unsigned)(rate * kLookahead) : 2;
	d->delay = calloc(d->len * ch, sizeof(float)), d->hold = calloc(d->len, sizeof(float)), d->dqv = calloc(d->len, sizeof(float));
	d->dqi = calloc(d->len, sizeof(uint64_t));
	d->release = 1 - exp(-1 / (kRelease * rate));
	LDDSPSetEQ(d, 1, -14);
	d->liftNow = 1;
	LDDSPReset(d);
	return 1;
}

void LDDSPFree(LDDSP *d) {
	free(d->delay), free(d->hold), free(d->dqv), free(d->dqi);
	d->delay = d->hold = d->dqv = NULL, d->dqi = NULL;
}

void LDDSPReset(LDDSP *d) {
	memset(d->delay, 0, sizeof(float) * d->len * d->ch);
	for (unsigned i = 0; i < d->len; i++) d->hold[i] = 1;
	memset(d->z, 0, sizeof d->z);
	d->sum = d->len, d->rel = 1, d->pos = d->head = d->count = 0, d->n = 0;
}

// volume: iOS output volume 0-1; target: LUFS the songs are brought to
void LDDSPSetEQ(LDDSP *d, float volume, float target) {
	double db = kVolumeDb[(int)fmin(fmax(volume * 16, 0), 15)];
	double step = fmin(fmax(round(-19 - (target + fmin(db + 9, 0))), 1), 80), row = (step - 1) / 79;
	d->bassDb = kBassMax * pow(row, 1.25), d->trebleDb = kTrebleMax * row;
	LDShelf(d->coef[0], 0, kBassHz, d->bassDb, kBassS, d->rate);
	LDShelf(d->coef[1], 1, kTrebleHz, d->trebleDb, kTrebleS, d->rate);
	d->lift = pow(10, kLiftDb * fmin(step * 0.02875, 1) / 20);
}

// Gain, then a look-ahead limiter: the limiter gain is the minimum needed over the last len samples (monotonic deque),
// smoothed by a len-long moving average, and the audio is delayed len - 1 samples, so every output sample stays under the ceiling.
void LDDSPRun(LDDSP *d, float **p, unsigned stride, size_t frames, int eq) {
	float lift = eq ? d->lift : 1, from = d->liftNow;
	d->liftNow = lift;
	for (size_t i = 0; i < frames; i++) {
		float x[LD_MAXCH], peak = 0, g = d->gain * (from + (lift - from) * (i + 1) / frames);
		for (unsigned c = 0; c < d->ch; c++) {
			float v = p[c][i * stride];
			if (eq) v = LDBiquad(d->coef[1], d->z[1][c], LDBiquad(d->coef[0], d->z[0][c], v));
			x[c] = v * g;
			peak = fmaxf(peak, fabsf(x[c]));
		}
		float r = peak > d->ceiling ? d->ceiling / peak : 1;
		if (d->count && d->dqi[d->head] + d->len <= d->n) d->head = (d->head + 1) % d->len, d->count--;
		while (d->count && d->dqv[(d->head + d->count - 1) % d->len] >= r) d->count--;
		unsigned back = (d->head + d->count++) % d->len;
		d->dqv[back] = r, d->dqi[back] = d->n;
		d->rel = fminf(d->dqv[d->head], d->rel + (1 - d->rel) * d->release);
		d->sum += d->rel - d->hold[d->pos];
		d->hold[d->pos] = d->rel;
		float s = d->sum / d->len;
		unsigned next = (d->pos + 1) % d->len;
		for (unsigned c = 0; c < d->ch; c++) {
			d->delay[d->pos * d->ch + c] = x[c];
			p[c][i * stride] = d->delay[next * d->ch + c] * s;
		}
		d->pos = next, d->n++;
	}
}
