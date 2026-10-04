#import <Foundation/Foundation.h>

#define kKSHandled @"ks.handled"

void KSLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void KSCacheClear(void);

#define KSDefaults NSUserDefaults.standardUserDefaults
static inline BOOL KSBool(NSString *k, BOOL d) { id v = [KSDefaults objectForKey:[@"ks." stringByAppendingString:k]]; return v ? [v boolValue] : d; }
static inline NSInteger KSNum(NSString *k, NSInteger d) { id v = [KSDefaults objectForKey:[@"ks." stringByAppendingString:k]]; return v ? [v integerValue] : d; }
static inline NSString *KSL(NSString *en, NSString *ko) {
	NSInteger lang = [KSDefaults integerForKey:@"rl.lang"];
	return (lang ? lang == 2 : [NSLocale.preferredLanguages.firstObject hasPrefix:@"ko"]) ? ko : en;
}

static inline NSString *KSStr(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }
static inline NSArray *KSArr(id v) { return [v isKindOfClass:NSArray.class] ? v : @[]; }
static inline NSDictionary *KSDict(id v) { return [v isKindOfClass:NSDictionary.class] ? v : @{}; }

BOOL KSHasHangul(NSString *s);
BOOL KSIsLatin(NSString *s);
NSString *KSNorm(NSString *s);
NSString *KSNormKo(NSString *s);
NSArray<NSString *> *KSWords(NSString *s);
NSString *KSKoreanPartOf(NSString *phrase);
BOOL KSTitleMatches(NSString *trackTitle, NSString *latinTitle);
BOOL KSKoreanTitleMatches(NSString *trackTitle, NSString *koreanTitle);
BOOL KSRelatedToKoreanQuery(NSString *koreanPart, NSString *koreanTitle);
BOOL KSQueryMentionsArtist(NSString *phrase, NSArray<NSString *> *names);
NSString *KSUnsortName(NSString *name);
NSString *KSMbLatinTitle(NSDictionary *recording);
NSString *KSMbLatinArtist(NSDictionary *recording);
NSArray<NSString *> *KSMbArtistNames(NSDictionary *recording);
NSArray<NSArray<NSString *> *> *KSMbArtistHints(NSDictionary *recording);
NSArray<NSDictionary *> *KSKomcaParse(NSString *html);
NSData *KSMerge(NSData *body, NSArray<NSDictionary *> *tracks);

// Blocking (network): call off the main thread.
NSArray<NSDictionary *> *KSResolve(NSString *phrase, NSURLRequest *search);
