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
