#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <os/log.h>

static inline void LLLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static inline void LLLog(NSString *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	NSString *line = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);
	os_log(OS_LOG_DEFAULT, "[TidalLockLyrics] %{public}@", line);
}

static inline BOOL LLOn(NSString *k) {
	id v = [NSUserDefaults.standardUserDefaults objectForKey:[@"ll." stringByAppendingString:k]];
	return v ? [v boolValue] : ![k isEqualToString:@"full"] && ![k isEqualToString:@"moving"];
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
NSString *LLTallKey(void);
id LLCard(NSDictionary *info, NSString *now, NSString *next, NSInteger dots, double at, BOOL shown);
void LLCardInto(NSMutableDictionary *d, id card);

void LLSettingsInit(void);
