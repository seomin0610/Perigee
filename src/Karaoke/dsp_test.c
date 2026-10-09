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
		if (!KRPitchPush(&p, x, 0.01f, &note, NULL, NULL)) continue;
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
// 6 Hz vibrato of ±0.4 on the held notes, 2 random notes, 3 every other phrase 0.25 s late, 4 on pitch but holding the last
// note through the rests (linked words)
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
		if (!note && style == 4 && ms > 1) note = 59;
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

	KRPitch dp;
	KRPitchInit(&dp, 44100);
	int frames = 0, lead = 0, soloAlt = 0, solo = 0;
	for (int i = 0; i < 44100 * 2; i++) {
		float x = 0, note, alt[2], dip;
		for (int k = 1; k <= 6; k++) x += 0.2f / k * (sinf(2 * M_PI * 220 * k * i / 44100.) + 0.4f * sinf(2 * M_PI * 277.18 * k * i / 44100.));
		if (!KRPitchPush(&dp, x, 0.01f, &note, alt, &dip) || note <= 0) continue;
		frames++, lead += KRGrade(note, 57) == 3;
	}
	KRPitchInit(&dp, 44100);
	for (int i = 0; i < 44100 * 2; i++) {
		float x = 0, note, alt[2];
		for (int k = 1; k <= 8; k++) x += 0.2f / k * sinf(2 * M_PI * 196 * k * i / 44100.);
		if (!KRPitchPush(&dp, x, 0.01f, &note, alt, NULL) || note <= 0) continue;
		solo++, soloAlt += alt[0] > 0;
	}
	printf("duet: louder part on pitch in %d of %d frames, solo with a second note %d of %d\n", lead, frames, soloAlt, solo);
	assert(frames > 50 && lead * 10 >= frames * 9 && soloAlt * 10 <= solo);
	KRLag sl = { 0 };
	KRFrame sung = { 0, 61, { 0, 0 }, 0 }, unclear = { 0, 54, { 0, 0 }, 0.2f };
	float su;
	assert(KRMatch(&sl, &sung, 1, unclear, 0.25, &su) == 5);
	sl = (KRLag){ 0 };
	sl.leapAt = -1;
	assert(KRMatch(&sl, &sung, 1, (KRFrame){ 0, 54, { 0, 0 }, 0.05f }, 0.25, &su) == 0);
	KRFrame low = { 0.1, 61, { 0, 0 }, 0.05f };
	assert(KRMatch(&sl, &low, 1, (KRFrame){ 0.1, 47, { 0, 0 }, 0.05f }, 0.25, &su) == 5);
	low.time = 0.5;
	assert(KRMatch(&sl, &low, 1, (KRFrame){ 0.5, 47, { 0, 0 }, 0.05f }, 0.25, &su) == 0);

	KRSmooth sm = { 0 };
	float sung2[40];
	for (int i = 0; i < 40; i++) sung2[i] = i < 25 ? 60 : 64;
	sung2[10] = 40, sung2[17] = 48, sung2[18] = 47, sung2[33] = 0;
	sung2[28] = sung2[29] = 0;
	int outs = 0;
	for (int i = 0; i < 40; i++) {
		KRFrame o1;
		if (!KRSmoothPush(&sm, (KRFrame){ i, sung2[i] }, &o1)) continue;
		int at = (int)o1.time;
		assert(at == i - 2);
		float want = at < 25 ? 60 : 64;
		assert(o1.note == want);
		outs++;
	}
	KRSmooth sb = { 0 };
	float blip[9] = { 0, 0, 0, 0, 61, 0, 0, 0, 0 };
	for (int i = 0; i < 9; i++) {
		KRFrame o1;
		if (KRSmoothPush(&sb, (KRFrame){ i, blip[i] }, &o1)) assert(o1.note == 0);
	}
	KRSmooth sh = { 0 };
	int wrong = 0;
	for (int i = 0; i < 80; i++) {
		float n = i < 50 ? 60 : 67;
		if (i >= 20 && i < 33) n = 60 - 19.02f;
		if (i >= 60 && i < 70) n = 67 - 27.86f;
		KRFrame o1;
		if (KRSmoothPush(&sh, (KRFrame){ i, n }, &o1) && fabsf(o1.note - (o1.time < 50 ? 60 : 67)) > 0.05f) wrong++;
	}
	assert(wrong <= 2 && sh.fixed == 23);
	printf("smooth: spikes gone, note change kept (%d frames), 23 harmonic frames moved back, fifth leap kept\n", outs);

	KRClean cl = { 0 };
	KRFrame cleaned[64], o[9];
	int got = 0;
	float raw[40] = { 0, 0, 72, 72, 73, 0, 0, 60, 60.3f, 60.5f, 60.2f, 60, 60.4f, 60.1f, 60, 55, 55, 55, 55, 55, 55, 55, 48, 0, 0, 0 };
	for (int i = 0; i < 40; i++) {
		size_t k = KRCleanPush(&cl, (KRFrame){ i, raw[i] }, o);
		for (size_t j = 0; j < k; j++) cleaned[got++] = o[j];
	}
	assert(got == 40);
	for (int i = 0; i < 40; i++) assert(cleaned[i].time == i && cleaned[i].note == ((i >= 7 && i <= 21) ? raw[i] : 0));

	KRTally t;
	int good = song(0.1, 0, &t);
	assert(good >= 94 && t.phrases >= 15 && t.cleared == t.phrases && t.rhythm / t.onsets > 0.95 && t.vibratos == 0);
	int vib = song(0.1, 1, &t);
	unsigned vibratos = t.vibratos;
	assert(vibratos >= 10 && vib >= good);
	int late = song(0.1, 3, &t), lp, lr, lph;
	KRTallyScore(&t, &lp, &lr, &lph);
	assert(lr < 70 && late < good);
	int linked = song(0.1, 4, &t), kp, kr, kph;
	KRTallyScore(&t, &kp, &kr, &kph);
	assert(kr >= 80);
	int noise = song(0.1, 2, &t);
	assert(noise < 30 && t.cleared == 0);
	printf("tally: on pitch %d, with vibrato %d (%u vibratos), late starts %d (rhythm %d), linked %d (rhythm %d), random %d\n", good, vib, vibratos, late, lr, linked, kr, noise);
	printf("match: in tune %.2f, half a semitone sharp %.2f (cool), random %.2f\n", steady, sharp, random);
	printf("ok: 1 kHz centre x%.3f, 50 Hz centre x%.3f, half x%.3f, side untouched, isolator lag %d removed, pitch %.2f %.2f %.2f (57 55 64)\n", voice, bass, half, kLag, tone, rich, mic);
	return 0;
}
