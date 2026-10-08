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

// median note of the voiced frames, 0 if under a quarter of them are voiced
static float voiced(double rate, double hz, int harmonics, int noise) {
	KRPitch p;
	KRPitchInit(&p, rate);
	float notes[512];
	int n = 0, frames = 0;
	srand(2);
	for (int i = 0; i < rate * 2; i++) {
		float x = 0, note;
		for (int k = 1; k <= harmonics; k++) x += 0.2f / k * sinf(2 * M_PI * hz * k * i / rate);
		if (noise) x = 0.3f * ((float)rand() / RAND_MAX - 0.5f);
		if (!KRPitchPush(&p, x, 0.01f, &note)) continue;
		frames++;
		if (note > 0 && n < 512) notes[n++] = note;
	}
	if (n * 4 < frames) return 0;
	for (int i = 1; i < n; i++)
		for (int j = i; j > 0 && notes[j - 1] > notes[j]; j--) {
			float s = notes[j];
			notes[j] = notes[j - 1], notes[j - 1] = s;
		}
	return notes[n / 2];
}

// share of frames graded perfect (cool for the sharp singer) for a singer lagging the record by lag
static double sing(double lag, float detune, int random) {
	enum { kN = 2000 };
	static KRFrame ref[kN], mic[kN];
	const double hop = KR_PITCH_HOP / 11025.0;
	srand(3);
	for (int i = 0; i < kN; i++) {
		ref[i] = (KRFrame){ i * hop, 55 + 7 * sinf(i * 0.02f) + (i / 40 % 2) * 2 };
		float wobble = ((float)rand() / RAND_MAX - 0.5f) * 0.2f;
		mic[i] = (KRFrame){ i * hop + lag, random ? 48 + rand() % 24 : ref[i].note + detune + wobble };
	}
	KRLag l = { 0 };
	int hits = 0, want = detune > 0 ? 2 : 3;
	for (int i = 200; i < kN - 20; i++) {
		float user;
		int lo = i - 200, g = KRMatch(&l, mic + lo, 220, ref[i], 0.25, &user);
		if (g == want) hits++;
	}
	return hits / (double)(kN - 220);
}

// a song of 2.4 s phrases (two 1.2 s held notes, 0.5 s rests) sung `lag` behind; style 0 on pitch, 1 with a
// 6 Hz vibrato of ±0.4 on the held notes, 2 random notes, 3 every other phrase 0.25 s late
static int song(double lag, int style, KRTally *t) {
	enum { kN = 3000 };
	static KRFrame ref[kN], mic[kN];
	const double hop = KR_PITCH_HOP / 11025.0;
	srand(4);
	for (int i = 0; i < kN; i++) {
		double s = i * hop, in = fmod(s, 2.9);
		ref[i] = (KRFrame){ s, in < 2.4 ? 57 + (int)(in / 1.2) * 2 : 0 };
		double late = style == 3 && (int)(s / 2.9) % 2 ? 0.25 : 0, ms = s - late, min = fmod(ms, 2.9);
		float note = ms >= 0 && min < 2.4 ? 57 + (int)(min / 1.2) * 2 : 0;
		if (style == 3 && min >= 2.4 - late && min < 2.4) note = 0;
		if (note && style == 1) note += 0.4f * sinf(2 * M_PI * 6 * s);
		if (note && style == 2) note = 48 + rand() % 24;
		mic[i] = (KRFrame){ s + lag, note };
	}
	KRLag l = { 0 };
	memset(t, 0, sizeof *t);
	for (int i = 0; i < 240; i++) KRTallyMic(t, mic[i]);
	for (int i = 200; i < kN - 40; i++) {
		KRTallyMic(t, mic[i + 40]);
		float user;
		int g = KRMatch(&l, mic + i - 200, 220, ref[i], 0.25, &user);
		KRTallyRef(t, ref[i], g, user, l.lag);
	}
	int p, r, ph;
	return KRTallyScore(t, &p, &r, &ph);
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

	float tone = voiced(44100, 220, 1, 0), rich = voiced(44100, 196, 8, 0), mic = voiced(48000, 330, 4, 0), hiss = voiced(44100, 0, 0, 1);
	assert(fabsf(tone - 57) < 0.1f && fabsf(rich - 55) < 0.15f && fabsf(mic - 64) < 0.15f && hiss == 0);
	assert(voiced(44100, 0, 0, 0) == 0);
	assert(KRGrade(60, 60.2f) == 3 && KRGrade(60, 72.5f) == 2 && KRGrade(48, 61) == 1 && KRGrade(60, 63) == 0);

	double steady = sing(0.12, 0, 0), sharp = sing(0.12, 0.5f, 0), random = sing(0.12, 0, 1);
	assert(steady > 0.9 && sharp > 0.85 && random < 0.08);

	KRTally t;
	int good = song(0.1, 0, &t);
	assert(good >= 94 && t.phrases >= 15 && t.cleared == t.phrases && t.rhythm / t.onsets > 0.95 && t.vibratos == 0);
	int vib = song(0.1, 1, &t);
	unsigned vibratos = t.vibratos;
	assert(vibratos >= 10 && vib >= good);
	int late = song(0.1, 3, &t), lp, lr, lph;
	KRTallyScore(&t, &lp, &lr, &lph);
	assert(lr < 70 && late < good);
	int noise = song(0.1, 2, &t);
	assert(noise < 30 && t.cleared == 0);
	printf("tally: on pitch %d, with vibrato %d (%u vibratos), late starts %d (rhythm %d), random %d\n", good, vib, vibratos, late, lr, noise);
	printf("match: in tune %.2f, half a semitone sharp %.2f (cool), random %.2f\n", steady, sharp, random);
	printf("ok: 1 kHz centre x%.3f, 50 Hz centre x%.3f, half x%.3f, side untouched, isolator lag %d removed, pitch %.2f %.2f %.2f (57 55 64)\n", voice, bass, half, kLag, tone, rich, mic);
	return 0;
}
