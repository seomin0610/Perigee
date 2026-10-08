#import <Foundation/Foundation.h>

void KRLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *KRL(NSString *en, NSString *ko);
BOOL KROn(void);
int KRUsing(void);

void KRScoreInit(void);
void KRScoreSet(BOOL on);
NSString *KRScoreStatus(void);
BOOL KRScoreWants(NSUInteger item);
void KRScorePush(double time, float note);
