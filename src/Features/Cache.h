#import <Foundation/Foundation.h>

// Reddit's cache: the URL cache, Caches, tmp, and the named GraphQL, image, video and
// feed stores. Login and settings live elsewhere and are never touched.

typedef NS_ENUM(NSInteger, PDAutoClear) {
    PDAutoClearOff = 0,
    PDAutoClearEveryLaunch,
    PDAutoClearDaily,
    PDAutoClearWeekly,
};

static const NSInteger PDAutoClearCount = 4;

NSString *PDAutoClearName(NSInteger mode);
void PDClearRedditCache(void);
// Walks the app's folders: call it off the main thread.
unsigned long long PDRedditCacheSize(void);
NSString *PDFormattedSize(unsigned long long bytes);
