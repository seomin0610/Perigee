#include <stddef.h>

enum { HTKick, HTSnare };
typedef struct { float time, strength, sharpness; int kind; } HTTap;
typedef struct { HTTap *taps; size_t count; float *levels; size_t slots; double slot; } HTResult;

HTResult HTAnalyze(const float *pcm, size_t n, double rate);
