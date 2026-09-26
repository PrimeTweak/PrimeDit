#import <Foundation/Foundation.h>

// Reddit's cache: the URL cache, Caches, tmp, and the named GraphQL, image, video and
// feed stores. Login and settings live elsewhere and are never touched.

typedef NS_ENUM(NSInteger, PDTAutoClear) {
    PDTAutoClearOff = 0,
    PDTAutoClearEveryLaunch,
    PDTAutoClearDaily,
    PDTAutoClearWeekly,
};

static const NSInteger PDTAutoClearCount = 4;

NSString *PDTAutoClearName(NSInteger mode);
void PDTClearRedditCache(void);
// Walks the app's folders: call it off the main thread.
unsigned long long PDTRedditCacheSize(void);
NSString *PDTFormattedSize(unsigned long long bytes);
