#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

void KRLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *KRL(NSString *en, NSString *ko);
BOOL KROn(void);
int KRUsing(void);
int KRKey(void);
double KRShiftDelay(void);
AudioUnit KRIsolatorNew(double rate, unsigned maxFrames, AURenderCallback feed, void *ref, BOOL offline, double *latency);

void KRScoreInit(void);
BOOL KRTapCheckWanted(void);
void KRTapCheckPush(double time, float note);
void KRScoreSet(BOOL on);
NSString *KRScoreStatus(void);
