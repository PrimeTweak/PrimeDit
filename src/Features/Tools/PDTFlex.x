// FLEX explorer: the FLEX toolbar follows its switch, and is set again one second after
// Reddit returns to the foreground.
#import <UIKit/UIKit.h>
#import "FLEXManager.h"
#import "PDTPreferences.h"

static char kPDTFlexObserver;
static BOOL gPDFlexShown;

static void PDTApplyFlexExplorer(void) {
    if (PDTPrefBool(kPrimeDitFlexExplorer, NO)) {
        [FLEXManager.sharedManager showExplorer];
        gPDFlexShown = YES;
    } else if (gPDFlexShown) {
        [FLEXManager.sharedManager hideExplorer];
        gPDFlexShown = NO;
    }
}

static void PDTFlexPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PDTApplyFlexExplorer();
    });
}

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &kPDTFlexObserver,
                                    PDTFlexPrefsChanged, CFSTR(kPrimeDitPrefsNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                                                   dispatch_get_main_queue(), ^{
                                                                       PDTApplyFlexExplorer();
                                                                   });
                                                }];
}
