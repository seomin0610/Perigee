#include <stddef.h>

#define KR_MAXCH 8

typedef struct {
	unsigned ch, len, pos;
	float level, lp[5], hp[5], zl[2], zh[2];
	float *delay;
} KRDSP;

int KRDSPInit(KRDSP *d, double rate, unsigned ch, unsigned delay);
void KRDSPFree(KRDSP *d);
void KRDSPReset(KRDSP *d);
void KRCenter(KRDSP *d, float **p, unsigned stride, size_t frames, float level);
void KRSubtract(KRDSP *d, float **p, unsigned stride, size_t frames, const float *vocal, float level);
