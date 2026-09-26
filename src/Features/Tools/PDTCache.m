#import "PDTCache.h"
#import "PDTCompatibility.h"
#import "PDTPreferences.h"

NSString *PDTAutoClearName(NSInteger mode) {
    switch (mode) {
        case PDTAutoClearEveryLaunch: return @"Every launch";
        case PDTAutoClearDaily: return @"Once a day";
        case PDTAutoClearWeekly: return @"Once a week";
        default: return @"Off";
    }
}

// Top-level items of Caches and tmp that really live inside those folders.
static NSArray<NSURL *> *PDTCacheFolderItems(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray<NSURL *> *folders = [NSMutableArray array];
    NSURL *caches = [files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    if (caches) [folders addObject:caches];
    [folders addObject:[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]];
    NSMutableArray<NSURL *> *items = [NSMutableArray array];
    for (NSURL *folder in folders) {
        NSString *root = [folder.URLByResolvingSymlinksInPath.path stringByAppendingString:@"/"];
        for (NSURL *item in [files contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil])
            if ([item.URLByResolvingSymlinksInPath.path hasPrefix:root]) [items addObject:item];
    }
    return items;
}

// Named stores anywhere else in the app's home folder, found by name prefix.
static NSArray<NSURL *> *PDTCacheStores(void) {
    NSArray<NSString *> *prefixes = @[
        @"sqlNormalizedCache.sqlite", @"com.github.kean.Nuke.DataCache", @"com.pinterest.PINDiskCache.",
        @"com.reddit.VideoDataCache", @"com.reddit.HomeFeedCache", @"com.reddit.cache", @"NukeDataCache"
      ];
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *caches = [files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject.path;
    NSString *tmp = [NSTemporaryDirectory() stringByStandardizingPath];
    NSDirectoryEnumerator *enumerator = [files enumeratorAtURL:[NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]
                                    includingPropertiesForKeys:nil
                                                       options:0
                                                  errorHandler:nil];
    NSMutableArray<NSURL *> *stores = [NSMutableArray array];
    for (NSURL *url in enumerator) {
        NSString *path = url.path.stringByStandardizingPath;
        if ((caches && [path isEqualToString:caches]) || [path isEqualToString:tmp]) {
            [enumerator skipDescendants];
            continue;
        }
        for (NSString *prefix in prefixes) {
            if ([url.lastPathComponent hasPrefix:prefix]) {
                [stores addObject:url];
                [enumerator skipDescendants];
                break;
            }
        }
    }
    return stores;
}

void PDTClearRedditCache(void) {
    [NSURLCache.sharedURLCache removeAllCachedResponses];
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSURL *url in PDTCacheFolderItems()) [files removeItemAtURL:url error:nil];
    for (NSURL *url in PDTCacheStores()) [files removeItemAtURL:url error:nil];
    [NSUserDefaults.standardUserDefaults setDouble:CFAbsoluteTimeGetCurrent() forKey:kPrimeDitAutoClearLast];
}

static unsigned long long PDTItemSize(NSURL *url) {
    NSNumber *isFolder = nil;
    [url getResourceValue:&isFolder forKey:NSURLIsDirectoryKey error:nil];
    NSNumber *size = nil;
    if (!isFolder.boolValue) {
        [url getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
        return size.unsignedLongLongValue;
    }
    unsigned long long total = 0;
    for (NSURL *file in [NSFileManager.defaultManager enumeratorAtURL:url
                                            includingPropertiesForKeys:@[ NSURLTotalFileAllocatedSizeKey ]
                                                               options:0
                                                          errorHandler:nil]) {
        size = nil;
        [file getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

unsigned long long PDTRedditCacheSize(void) {
    unsigned long long total = 0;
    for (NSURL *url in PDTCacheFolderItems()) total += PDTItemSize(url);
    for (NSURL *url in PDTCacheStores()) total += PDTItemSize(url);
    return total;
}

// Decimal units, as iOS Settings shows storage.
NSString *PDTFormattedSize(unsigned long long bytes) {
    if (bytes < 1000000ULL) return [NSString stringWithFormat:@"%llu KB", (bytes + 999ULL) / 1000ULL];
    if (bytes < 1000000000ULL) return [NSString stringWithFormat:@"%llu MB", (bytes + 500000ULL) / 1000000ULL];
    return [NSString stringWithFormat:@"%.1f GB", (double)bytes / 1e9];
}

// Auto-clear runs at launch, before Reddit's own code opens its caches.
__attribute__((constructor)) static void PDTAutoClearAtLaunch(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger mode = [defaults integerForKey:kPrimeDitAutoClearCache];
    if (mode <= PDTAutoClearOff || mode >= PDTAutoClearCount) return;
    CFTimeInterval interval = mode == PDTAutoClearDaily ? 86400.0 : mode == PDTAutoClearWeekly ? 604800.0 : 0.0;
    if (interval > 0 && CFAbsoluteTimeGetCurrent() - [defaults doubleForKey:kPrimeDitAutoClearLast] < interval)
        return;
    PDTClearRedditCache();
#if PRIMEDIT_DEBUG
    // Recorded once the app runs, when the report's recorder is ready.
    dispatch_async(dispatch_get_main_queue(), ^{
        PDTCOMPAT_ACTION(PDTCompatBackup, @"Cache auto-cleared at launch (%@)", PDTAutoClearName(mode));
    });
#endif
}
