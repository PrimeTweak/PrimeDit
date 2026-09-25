#import "Cache.h"
#import "Compatibility.h"
#import "Preferences.h"

NSString *PDAutoClearName(NSInteger mode) {
    switch (mode) {
        case PDAutoClearEveryLaunch: return @"Every launch";
        case PDAutoClearDaily: return @"Once a day";
        case PDAutoClearWeekly: return @"Once a week";
        default: return @"Off";
    }
}

// Top-level items of Caches and tmp that really live inside those folders.
static NSArray<NSURL *> *PDCacheFolderItems(void) {
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
static NSArray<NSURL *> *PDCacheStores(void) {
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

void PDClearRedditCache(void) {
    [NSURLCache.sharedURLCache removeAllCachedResponses];
    NSFileManager *files = NSFileManager.defaultManager;
    for (NSURL *url in PDCacheFolderItems()) [files removeItemAtURL:url error:nil];
    for (NSURL *url in PDCacheStores()) [files removeItemAtURL:url error:nil];
    [NSUserDefaults.standardUserDefaults setDouble:CFAbsoluteTimeGetCurrent() forKey:kPrimeDitAutoClearLast];
}

static unsigned long long PDItemSize(NSURL *url) {
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

unsigned long long PDRedditCacheSize(void) {
    unsigned long long total = 0;
    for (NSURL *url in PDCacheFolderItems()) total += PDItemSize(url);
    for (NSURL *url in PDCacheStores()) total += PDItemSize(url);
    return total;
}

// Decimal units, as iOS Settings shows storage.
NSString *PDFormattedSize(unsigned long long bytes) {
    if (bytes < 1000000ULL) return [NSString stringWithFormat:@"%llu KB", (bytes + 999ULL) / 1000ULL];
    if (bytes < 1000000000ULL) return [NSString stringWithFormat:@"%llu MB", (bytes + 500000ULL) / 1000000ULL];
    return [NSString stringWithFormat:@"%.1f GB", (double)bytes / 1e9];
}

// Auto-clear runs at launch, before Reddit's own code opens its caches.
__attribute__((constructor)) static void PDAutoClearAtLaunch(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger mode = [defaults integerForKey:kPrimeDitAutoClearCache];
    if (mode <= PDAutoClearOff || mode >= PDAutoClearCount) return;
    CFTimeInterval interval = mode == PDAutoClearDaily ? 86400.0 : mode == PDAutoClearWeekly ? 604800.0 : 0.0;
    if (interval > 0 && CFAbsoluteTimeGetCurrent() - [defaults doubleForKey:kPrimeDitAutoClearLast] < interval)
        return;
    PDClearRedditCache();
#if PRIMEDIT_DEBUG
    // Recorded once the app runs, when the report's recorder is ready.
    dispatch_async(dispatch_get_main_queue(), ^{
        PDCOMPAT_ACTION(PDCompatBackup, @"Cache auto-cleared at launch (%@)", PDAutoClearName(mode));
    });
#endif
}
