#include "Scene.h"
#include <math.h>
#include <string.h>

typedef struct { double time; float strength; int kind; } HSHit;

static HSHit gHits[64];
static unsigned gHead;
static double gLevelAt = -1;
static float gLevel;

static const float kWave[3][9] = {
	{ 1.15f, 2.9f, 0.07f, 0.16f, 0.075f, 1.5f, 1.0f, 1.35f, 0 },
	{ 2.2f, 2.6f, 0.04f, 0.06f, 0.022f, 3.0f, 0.55f, 2.8f, 0.75f },
	{ 1.6f, 2.7f, 0.05f, 0.1f, 0.05f, 2.0f, 0.9f, 1.9f, 0.3f },
};

void HSAddHit(double time, float strength, int kind) { gHits[gHead++ % 64] = (HSHit){ time, strength, kind }; }

void HSSetLevel(double now, float level) {
	gLevelAt = now;
	gLevel = level;
}

static void HSProject(float x, float y, float z, float *a, float *b, float *depth) {
	const float n = 5.2738f, dy = y - 2.75f, dz = z - 4.5f;
	*depth = (-2.75f * dy - 4.5f * dz) / n;
	*a = x / *depth;
	*b = (4.5f * dy - 2.75f * dz) / n / *depth;
}

void HSInit(HSScene *s, double now) {
	memset(s, 0, sizeof *s);
	s->start = s->last = now;
	s->followed = -10;
	s->amin = s->bmin = INFINITY;
	s->amax = s->bmax = -INFINITY;
	for (int ring = 0; ring < 25; ring++) {
		float r = 0.2f + 0.095f * ring;
		int count = (int)lroundf(2 * (float)M_PI * r / 0.068f);
		for (int k = 0; k < count && s->n < HSMaxDots; k++, s->n++) {
			float th = (k + (ring & 1) * 0.5f) * 2 * (float)M_PI / count, a, b, z;
			s->dots[s->n][0] = r;
			s->dots[s->n][1] = th;
			HSProject(r * cosf(th), 0, r * sinf(th), &a, &b, &z);
			s->amin = fminf(s->amin, a), s->amax = fmaxf(s->amax, a);
			s->bmin = fminf(s->bmin, b), s->bmax = fmaxf(s->bmax, b);
		}
	}
}

size_t HSFrame(HSScene *s, double now, float width, float height, HSDot *out) {
	float dt = (float)fmin(0.05, fmax(0, now - s->last));
	double last = s->last;
	s->last = now;
	int live = gLevelAt >= 0 && now - gLevelAt <= 0.2;
	float target = live ? gLevel : 0.25f + 0.15f * sinf((float)now * 1.7f);
	s->level += (target - s->level) * (1 - expf(-dt / 0.04f));
	if (live && gLevel > 0.02f) s->followed = now;

	HSHit hits[80];
	size_t m = 0;
	for (int i = 0; i < 64; i++)
		if (gHits[i].strength > 0 && gHits[i].time > now - 3 && gHits[i].time <= now) hits[m++] = gHits[i];
	if (!live)
		for (long long k = (long long)floor((now - 3) / 0.3) + 1; k <= (long long)floor(now / 0.3); k++) {
			int step = (int)(((k % 8) + 8) % 8);
			if (step == 0 || step == 5) hits[m++] = (HSHit){ k * 0.3, 0.7f, HSKick };
			if (step == 2 || step == 6) hits[m++] = (HSHit){ k * 0.3, 0.5f, HSSnare };
		}
	for (size_t i = 0; i < m; i++) {
		if (hits[i].time <= last) continue;
		if (hits[i].kind == HSKick) s->punchV -= 3.2f * hits[i].strength;
		if (hits[i].kind == HSSnare) s->flash = fmaxf(s->flash, 0.75f * hits[i].strength);
		if (live && hits[i].kind != HSControl) s->followed = now;
	}
	for (int i = 0; i < 4; i++) {
		s->punchV += (-696.4f * s->punch - 20.06f * s->punchV) * dt / 4;
		s->punch += s->punchV * dt / 4;
	}
	s->flash *= expf(-dt / 0.09f);

	float amp = s->calm ? 0.4f : 1, yaw = s->calm ? 0 : 0.12f * sinf(2 * (float)M_PI * (float)fmod(now, 26) / 26);
	float shown = (float)fmin(1, (now - s->start) / 0.5);
	float k = 0.88f * fminf(width / (s->amax - s->amin), height / (s->bmax - s->bmin));
	float cx = width / 2 - (s->amax + s->amin) / 2 * k, cy = height / 2 + (s->bmax + s->bmin) / 2 * k;
	for (size_t i = 0; i < s->n; i++) {
		float r = s->dots[i][0], th = s->dots[i][1] + yaw;
		float fade = (r < 1.9f ? 1 : fmaxf(0, 1 - (r - 1.9f) / 0.6f)) * shown;
		float y = (0.03f * s->level + s->punch) * expf(-0.9f * r), bright = 0.3f * s->flash, white = bright;
		for (size_t j = 0; j < m; j++) {
			const float *w = kWave[hits[j].kind];
			float age = (float)(now - hits[j].time), A = hits[j].strength;
			float ring = (1 - expf(-w[0] * age)) * w[1], thick = w[2] + w[3] * age, d = r - ring;
			if (fabsf(d) > 3 * thick) continue;
			float g = expf(-d * d / (thick * thick)), b = w[6] * A * expf(-w[7] * age) * g;
			y += w[4] * A * expf(-w[5] * age) * g;
			bright += b;
			white += b * w[8];
		}
		float a, bb, z;
		HSProject(r * cosf(th), y * amp, r * sinf(th), &a, &bb, &z);
		out[i] = (HSDot){ cx + a * k, cy - bb * k, 0.018f * k / z * (1 + 0.5f * fminf(bright, 1)), bright * fade, bright > 0 ? fminf(1, white / bright) : 0, 0.3f * fade };
	}
	return s->n;
}
