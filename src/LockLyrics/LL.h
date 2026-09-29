#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>

#define LLLog(fmt, ...) NSLog(@"[TidalLockLyrics] " fmt, ##__VA_ARGS__)

static inline BOOL LLOn(NSString *k) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:[@"ll." stringByAppendingString:k]];
	return v ? [v boolValue] : YES;
}

static inline id LLAs(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

extern NSMutableDictionary<NSString *, NSArray<NSString *> *> *gTidalTitles;
extern NSURLRequest *gTidalReq;
NSMutableURLRequest *LLTidalRequest(NSString *path, NSArray<NSURLQueryItem *> *query);
void LLSend(BOOL force);

NSDictionary *LLArtFor(NSDictionary *info);
BOOL LLArtAvailable(void);
void LLArtReset(BOOL files);
unsigned long long LLArtCacheBytes(void);

void LLSettingsInit(void);
