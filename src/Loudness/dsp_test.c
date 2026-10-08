#include "DSP.c"
#include <assert.h>
#include <stdio.h>

static float settle(LDDSP *d, float a, int alternate) {
	float l = 0, r = 0, *p[2] = { &l, &r };
	for (int i = 0; i < 48000; i++) {
		l = r = alternate && i % 2 ? -a : a;
		LDDSPRun(d, p, 1, 1, 1);
	}
	return fabsf(l);
}

int main(void) {
	LDDSP d;
	size_t n = 48000 * 4;
	float *pcm = malloc(sizeof(float) * n * 2), *in = malloc(sizeof(float) * n * 2);
	srand(1);
	for (size_t i = 0; i < n * 2; i++) pcm[i] = in[i] = ((float)rand() / RAND_MAX - 0.5f) * (i / 2 % 9600 < 2400 ? 2 : 0.2f) + 0.3f * sinf(i * 0.002f);
	assert(LDDSPInit(&d, 48000, 2, 4));
	LDDSPSetEQ(&d, 0.3f, -14);
	float *p[2] = { pcm, pcm + 1 };
	for (size_t i = 0; i < n; i += 512) LDDSPRun(&d, p, 2, n - i < 512 ? n - i : 512, 1), p[0] += 1024, p[1] += 1024;
	float top = 0;
	for (size_t i = 0; i < n * 2; i++) top = fmaxf(top, fabsf(pcm[i]));
	assert(top <= d.ceiling * 1.00001f);
	LDDSPFree(&d);

	assert(LDDSPInit(&d, 44100, 1, 2));
	float *q = in;
	for (size_t i = 0; i < n; i++) q[i] = 0.1f * sinf(i * 0.05f);
	LDDSPRun(&d, &q, 1, n, 0);
	for (size_t i = d.len - 1; i < n; i++) assert(fabsf(q[i] - 0.2f * sinf((i - d.len + 1) * 0.05f)) < 1e-5f);
	LDDSPFree(&d);

	assert(LDDSPInit(&d, 48000, 2, 1));
	LDDSPSetEQ(&d, 1, -14);
	assert(d.bassDb == 0 && d.trebleDb == 0);
	float full = settle(&d, 0.01f, 0) / 0.01f;
	assert(fabsf(20 * log10f(full) - 7 * 0.02875f) < 0.01f);
	LDDSPSetEQ(&d, 0.1f, -14);
	assert(d.bassDb > 2 && d.bassDb < 3 && d.trebleDb > 2.5f && d.trebleDb < 3.5f);
	float lift = 20 * log10f(d.lift);
	assert(fabsf(lift - 7 * 16 * 0.02875f) < 0.01f);
	LDDSPReset(&d);
	float bass = settle(&d, 0.01f, 0) / 0.01f;
	assert(fabsf(20 * log10f(bass) - d.bassDb - lift) < 0.05f);
	LDDSPReset(&d);
	float treble = settle(&d, 0.01f, 1) / 0.01f;
	assert(fabsf(20 * log10f(treble) - d.trebleDb - lift) < 0.1f);
	LDDSPSetEQ(&d, 0.01f, -14);
	assert(d.bassDb == 0 && d.trebleDb == 0);
	LDDSPFree(&d);

	printf("ok: peak %.3f under %.3f, quiet x2 untouched, lowest step: bass %+.1f treble %+.1f dB incl. lift\n", top, kCeiling, 20 * log10f(bass), 20 * log10f(treble));
	return 0;
}
