#include <stddef.h>
#include <stdint.h>

#define LD_MAXCH 8

typedef struct {
	float gain, rel, release, ceiling, lift, liftNow, bassDb, trebleDb;
	unsigned ch, len, pos, head, count;
	uint64_t n;
	double rate, sum;
	float *delay, *hold, *dqv;
	uint64_t *dqi;
	float coef[2][5], z[2][LD_MAXCH][2];
} LDDSP;

int LDDSPInit(LDDSP *d, double rate, unsigned ch, float gain);
void LDDSPFree(LDDSP *d);
void LDDSPReset(LDDSP *d);
void LDDSPSetEQ(LDDSP *d, float volume, float target);
void LDDSPRun(LDDSP *d, float **p, unsigned stride, size_t frames, int eq);
