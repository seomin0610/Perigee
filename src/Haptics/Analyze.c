#include "Analyze.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct { double b0, b1, b2, a1, a2, z1, z2; } HTBiquad;

enum { HTLowPass, HTBandPass, HTHighPass };

static HTBiquad HTFilter(int type, double fc, double q, double rate) {
	double w = 2 * M_PI * fc / rate, alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha;
	HTBiquad f = { 0 };
	if (type == HTLowPass) {
		f.b0 = f.b2 = (1 - c) / 2 / a0;
		f.b1 = (1 - c) / a0;
	} else if (type == HTHighPass) {
		f.b0 = f.b2 = (1 + c) / 2 / a0;
		f.b1 = -(1 + c) / a0;
	} else {
		f.b0 = alpha / a0;
		f.b2 = -alpha / a0;
	}
	f.a1 = -2 * c / a0;
	f.a2 = (1 - alpha) / a0;
	return f;
}

static double HTRun(HTBiquad *f, double x) {
	double y = f->b0 * x + f->z1;
	f->z1 = f->b1 * x - f->a1 * y + f->z2;
	f->z2 = f->b2 * x - f->a2 * y;
	return y;
}

static int HTCompare(const void *a, const void *b) {
	float x = *(const float *)a, y = *(const float *)b;
	return (x > y) - (x < y);
}

static float HTPercentile(const float *v, size_t n, double p) {
	float *c = malloc(n * sizeof *c);
	memcpy(c, v, n * sizeof *c);
	qsort(c, n, sizeof *c, HTCompare);
	float r = c[(size_t)(p * (n - 1))];
	free(c);
	return r;
}

static void HTOnsets(const float *amp, size_t n, float *out) {
	float ref = HTPercentile(amp, n, 0.95) + 1e-9f;
	float *c = malloc(n * sizeof *c);
	for (size_t i = 0; i < n; i++) c[i] = log1pf(10 * amp[i] / ref);
	for (size_t i = 0; i < n; i++) out[i] = i < 2 ? 0 : fmaxf(0, c[i] - c[i - 2]);
	free(c);
}

static size_t HTPeaks(const float *o, size_t n, size_t *at, float *strength) {
	float ref = HTPercentile(o, n, 0.99);
	if (ref <= 0) return 0;
	size_t count = 0;
	long last = -100;
	for (long i = 0; i < (long)n; i++) {
		float v = o[i] / ref;
		if (v < 0.2f || i - last < 8) continue;
		int peak = 1;
		for (long j = i - 4; j <= i + 4 && peak; j++)
			if (j >= 0 && j < (long)n && j != i && (o[j] > o[i] || (j < i && o[j] == o[i]))) peak = 0;
		if (!peak) continue;
		double sum = 0;
		int m = 0;
		for (long j = i - 24; j <= i + 8; j++)
			if (j >= 0 && j < (long)n) sum += o[j], m++;
		if (v < sum / m / ref + 0.15) continue;
		at[count] = i;
		strength[count++] = fminf(1, v);
		last = i;
	}
	return count;
}

HTResult HTAnalyze(const float *pcm, size_t n, double rate) {
	HTResult r = { 0 };
	size_t hop = (size_t)lround(rate / 86), frames = n / hop;
	if (frames < 64) return r;
	float *low = malloc(frames * sizeof(float)), *high = malloc(frames * sizeof(float)), *hat = malloc(frames * sizeof(float));
	float *ol = malloc(frames * sizeof(float)), *oh = malloc(frames * sizeof(float));
	HTBiquad l1 = HTFilter(HTLowPass, 150, 0.707, rate), l2 = l1, h = HTFilter(HTBandPass, 2500, 0.8, rate);
	HTBiquad c1 = HTFilter(HTHighPass, fmin(6000, rate * 0.3), 0.707, rate), c2 = c1;
	for (size_t f = 0; f < frames; f++) {
		double el = 0, eh = 0, ec = 0;
		for (size_t k = 0; k < hop; k++) {
			double x = pcm[f * hop + k], y = HTRun(&l2, HTRun(&l1, x)), z = HTRun(&h, x), v = HTRun(&c2, HTRun(&c1, x));
			el += y * y;
			eh += z * z;
			ec += v * v;
		}
		low[f] = sqrt(el / hop);
		high[f] = sqrt(eh / hop);
		hat[f] = sqrt(ec / hop);
	}

	HTOnsets(low, frames, ol);
	HTOnsets(high, frames, oh);
	size_t *ka = malloc(frames * sizeof(size_t)), *sa = malloc(frames * sizeof(size_t));
	float *ks = malloc(frames * sizeof(float)), *ss = malloc(frames * sizeof(float));
	size_t kn = HTPeaks(ol, frames, ka, ks), sn = 0;
	for (size_t i = 0, all = HTPeaks(oh, frames, sa, ss); i < all; i++)
		if (hat[sa[i]] < 2 * high[sa[i]]) sa[sn] = sa[i], ss[sn++] = ss[i];
	r.taps = malloc((kn + sn + 1) * sizeof(HTTap));
	for (size_t i = 0, j = 0; i < kn || j < sn;) {
		if (j < sn && i < kn && sa[j] + 2 >= ka[i] && sa[j] <= ka[i] + 2) {
			ks[i] = fmaxf(ks[i], ss[j]);
			j++;
		} else if (j < sn && (i == kn || sa[j] < ka[i])) {
			size_t f = sa[j];
			r.taps[r.count++] = (HTTap){ (float)(f * hop / rate), ss[j], 0.45f + 0.45f * (high[f] + hat[f]) / (low[f] + high[f] + hat[f] + 1e-9f), HTSnare };
			j++;
		} else {
			size_t f = ka[i];
			r.taps[r.count++] = (HTTap){ (float)(f * hop / rate), ks[i], 0.15f + 0.35f * (high[f] + hat[f]) / (low[f] + high[f] + hat[f] + 1e-9f), HTKick };
			i++;
		}
	}

	for (size_t f = 0; f < frames; f++) ol[f] = 20 * log10f(low[f] + 1e-9f);
	float lo = HTPercentile(ol, frames, 0.3), hi = HTPercentile(ol, frames, 0.98);
	r.slot = 4.0 * hop / rate;
	r.slots = frames / 4;
	r.levels = malloc((r.slots + 1) * sizeof(float));
	for (size_t s = 0; s < r.slots; s++) {
		float sum = 0;
		for (size_t f = s * 4; f < s * 4 + 4; f++) sum += fminf(1, fmaxf(0, (ol[f] - lo) / fmaxf(hi - lo, 1)));
		float v = sum / 4 < 0.5f ? 0 : (sum / 4 - 0.5f) * 2;
		float decay = s ? r.levels[s - 1] * 0.6f : 0;
		r.levels[s] = fmaxf(v, decay < 0.02f ? 0 : decay);
	}
	free(low), free(high), free(hat), free(ol), free(oh), free(ka), free(sa), free(ks), free(ss);
	return r;
}
