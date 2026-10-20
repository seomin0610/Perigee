#include "Scene.c"
#include <assert.h>
#include <stdio.h>

static HSScene s;
static HSDot dots[HSMaxDots];

int main(void) {
	double now = 1000;
	HSInit(&s, now);
	assert(s.n > 3000 && s.n < HSMaxDots);

	float w = 1170, h = 900;
	size_t n = HSFrame(&s, now + 1, w, h, dots);
	for (size_t i = 0; i < n; i++) assert(dots[i].x > 0 && dots[i].x < w && dots[i].y > 0 && dots[i].y < h && dots[i].radius > 1);

	HSInit(&s, now);
	HSSetLevel(now + 1, 0);
	HSAddHit(now + 0.5, 1, HSKick);
	HSFrame(&s, now + 0.98, w, h, dots);
	n = HSFrame(&s, now + 1, w, h, dots);
	float ring = (1 - expf(-1.15f * 0.5f)) * 2.9f, onRing = 0, center = 0;
	for (size_t i = 0; i < n; i++) {
		if (fabsf(s.dots[i][0] - ring) < 0.05f) onRing = fmaxf(onRing, dots[i].bright);
		if (s.dots[i][0] < 0.25f) center = fmaxf(center, dots[i].bright);
	}
	assert(onRing > 0.4f && center < 0.05f);

	HSInit(&s, now);
	HSSetLevel(now + 0.01, 0);
	HSAddHit(now + 0.01, 1, HSKick);
	HSFrame(&s, now + 0.02, w, h, dots);
	assert(s.punchV < 0);
	for (double t = 0.04; t < 2; t += 0.016) HSSetLevel(now + t, 0), HSFrame(&s, now + t, w, h, dots);
	assert(fabsf(s.punch) < 1e-3f);
	printf("ok: %zu dots, ring %.2f lit %.2f\n", s.n, ring, onRing);
	return 0;
}
