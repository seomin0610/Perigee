#include "DSP.c"
#include <assert.h>
#include <stdio.h>

static double gain(double hz, float level) {
	KRDSP d;
	assert(KRDSPInit(&d, 48000, 2, 0));
	size_t n = 48000;
	float *l = malloc(n * sizeof(float)), *r = malloc(n * sizeof(float));
	for (size_t i = 0; i < n; i++) l[i] = r[i] = 0.5f * sinf(2 * M_PI * hz * i / 48000);
	for (size_t i = 0; i < n; i += 512) {
		float *p[2] = { l + i, r + i };
		KRCenter(&d, p, 1, n - i < 512 ? n - i : 512, level);
	}
	double in = 0, out = 0;
	for (size_t i = n / 2; i < n; i++) in += 0.25 * pow(sin(2 * M_PI * hz * i / 48000), 2), out += l[i] * l[i];
	free(l), free(r), KRDSPFree(&d);
	return sqrt(out / in);
}

int main(void) {
	double voice = gain(1000, 1), bass = gain(50, 1), half = gain(1000, 0.5f);
	assert(voice < 0.1 && bass > 0.89 && fabs(half - 0.5) < 0.05);

	KRDSP d;
	assert(KRDSPInit(&d, 44100, 2, 0));
	float l[256], r[256], *p[2] = { l, r };
	for (int i = 0; i < 256; i++) l[i] = sinf(i * 0.3f), r[i] = -l[i];
	KRCenter(&d, p, 1, 256, 1);
	for (int i = 0; i < 256; i++) assert(fabsf(l[i] - sinf(i * 0.3f)) < 1e-6f && fabsf(r[i] + l[i]) < 1e-6f);
	KRDSPFree(&d);

	enum { kLag = 37, kN = 2048 };
	assert(KRDSPInit(&d, 48000, 2, kLag));
	float il[kN], ir[kN], vocal[kN], cen[kN], side[kN];
	for (int i = 0; i < kN; i++) {
		cen[i] = 0.4f * sinf(i * 0.05f), side[i] = 0.3f * sinf(i * 0.011f);
		il[i] = cen[i] + side[i], ir[i] = cen[i] - side[i];
		vocal[i] = i >= kLag ? cen[i - kLag] : 0;
	}
	for (int i = 0; i < kN; i += 256) {
		float *q[2] = { il + i, ir + i };
		KRSubtract(&d, q, 1, 256, vocal + i, 1);
	}
	for (int i = 256; i < kN; i++) assert(fabsf(il[i] - side[i - kLag]) < 1e-5f && fabsf(ir[i] + side[i - kLag]) < 1e-5f);
	KRDSPFree(&d);

	printf("ok: 1 kHz centre x%.3f, 50 Hz centre x%.3f, half x%.3f, side untouched, isolator lag %d removed\n", voice, bass, half, kLag);
	return 0;
}
