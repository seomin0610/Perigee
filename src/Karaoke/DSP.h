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

#define KR_PITCH_N 1024
#define KR_PITCH_W 512
#define KR_PITCH_HOP 256

typedef struct {
	float ring[KR_PITCH_N], acc;
	unsigned pos, count, decim, accn, hop, tmin, tmax;
	float threshold;
	double rate;
} KRPitch;

void KRPitchInit(KRPitch *p, double rate);
int KRPitchPush(KRPitch *p, float x, float gate, float *note, float *alt, float *dip);
double KRPitchDelay(const KRPitch *p);
int KRGrade(float user, float ref);

typedef struct {
	double time;
	float note, alt[2], dip;
} KRFrame;

typedef struct {
	KRFrame run[8];
	unsigned n, open;
	float last;
} KRClean;

size_t KRCleanPush(KRClean *c, KRFrame f, KRFrame *out);

typedef struct {
	KRFrame win[5];
	float hist[16];
	unsigned n, hn, hpos, fixed;
} KRSmooth;

int KRSmoothPush(KRSmooth *s, KRFrame f, KRFrame *out);

typedef struct {
	KRFrame refs[128];
	unsigned count, pos, since;
	double lag, leapAt;
	float prev;
} KRLag;

int KRMatch(KRLag *l, const KRFrame *mic, size_t n, KRFrame ref, double window, float *user);

enum { KRPhraseEnded = 1, KRVibrato = 2, KRLongTone = 4 };

typedef struct {
	unsigned grades[5], phrases, cleared, onsets, vibratos, longTones;
	double rhythm, phraseRate;
	unsigned pFrames, refGap, micGap, micSince, userCount, holdN, holdMiss;
	float micLast;
	double pSum, pLast, userOn[64], holdStart, holdEnd, holdRef;
	float hold[160];
} KRTally;

void KRTallyMic(KRTally *t, KRFrame mic);
int KRTallyRef(KRTally *t, KRFrame ref, int grade, float user, double lag);
int KRTallyScore(const KRTally *t, int *pitch, int *rhythm, int *phrase);
unsigned KRTallySung(const KRTally *t);
