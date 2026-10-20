#include <stddef.h>

enum { HSKick, HSSnare, HSControl };
enum { HSMaxDots = 3200 };
typedef struct { float x, y, radius, bright, white, base; } HSDot;
typedef struct {
	float dots[HSMaxDots][2];
	size_t n;
	float amin, amax, bmin, bmax;
	double start, last, followed;
	float punch, punchV, flash, level;
	int calm;
} HSScene;

void HSAddHit(double time, float strength, int kind);
void HSSetLevel(double now, float level);
void HSInit(HSScene *s, double now);
size_t HSFrame(HSScene *s, double now, float width, float height, HSDot *out);
void HTShowPreview(void);
