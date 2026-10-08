#import <Foundation/Foundation.h>

// Shared by TidalCore (host) and the tweaks that add stages; keep the layout in sync.
typedef struct {
	BOOL (*wantsV1)(void);
	NSData *(*manifest)(NSData *json, BOOL v1);
	void *(*prepare)(NSString *uri, double rate, unsigned ch, unsigned maxFrames);
	void (*process)(void *ctx, float **p, unsigned stride, size_t frames, BOOL start, double time);
	void (*free)(void *ctx);
} TTAudioStage;

typedef void (*TTAudioAddFn)(const TTAudioStage *stage);
