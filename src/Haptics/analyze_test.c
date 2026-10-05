#include "Analyze.c"
#include <assert.h>
#include <stdio.h>

int main(void) {
	double rate = 22050;
	size_t n = (size_t)(rate * 8);
	float *pcm = calloc(n, sizeof(float));
	srand(1);
	double p1 = 0, p2 = 0;
	for (size_t i = 0; i < n; i++) {
		double t = i / rate, kick = fmod(t, 0.5), snare = fmod(t + 0.25, 1.0), hat = fmod(t + 0.125, 0.25);
		double w = (double)rand() / RAND_MAX - 0.5, bright = w - 2 * p1 + p2;
		p2 = p1;
		p1 = w;
		pcm[i] = 0.01f * ((float)rand() / RAND_MAX - 0.5f);
		if (hat < 0.05) pcm[i] += 0.35 * bright * exp(-hat * 80);
		if (kick < 0.15) pcm[i] += 0.8 * sin(2 * M_PI * 60 * kick) * exp(-kick * 25);
		if (snare < 0.1) pcm[i] += 0.5 * ((float)rand() / RAND_MAX - 0.5f) * exp(-snare * 40);
	}
	HTResult r = HTAnalyze(pcm, n, rate);
	int kicks = 0, snares = 0;
	for (size_t i = 0; i < r.count; i++) {
		HTTap t = r.taps[i];
		double grid = t.kind == HTKick ? 0.5 : 1.0, off = t.kind == HTKick ? 0 : 0.75;
		double err = fabs(remainder(t.time - off, grid));
		assert(err < 0.03);
		assert(t.kind == HTKick ? t.sharpness < 0.5f : t.sharpness >= 0.45f);
		t.kind == HTKick ? kicks++ : snares++;
	}
	assert(kicks >= 14 && kicks <= 16);
	assert(snares >= 7 && snares <= 8);
	int loud = 0;
	for (size_t s = 0; s < r.slots; s++) loud += r.levels[s] > 0;
	assert(loud > 0 && loud < (int)r.slots);
	printf("ok: %d kicks, %d snares, rumble in %d of %zu slots\n", kicks, snares, loud, r.slots);
	return 0;
}
