// FLEX explorer: the FLEX toolbar follows its switch, and is set again one second after
// Reddit returns to the foreground.
#import <UIKit/UIKit.h>
#import "FLEXManager.h"
#import "Preferences.h"

static char kPDFlexObserver;
static BOOL gPDFlexShown;

static void PDApplyFlexExplorer(void) {
  if (PDPrefBool(kPrimeDitFlexExplorer, NO)) {
    [FLEXManager.sharedManager showExplorer];
    gPDFlexShown = YES;
  } else if (gPDFlexShown) {
    [FLEXManager.sharedManager hideExplorer];
    gPDFlexShown = NO;
  }
}

static void PDFlexPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object,
                               CFDictionaryRef userInfo) {
  dispatch_async(dispatch_get_main_queue(), ^{
    PDApplyFlexExplorer();
  });
}

%ctor {
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &kPDFlexObserver, PDFlexPrefsChanged,
                                  CFSTR(kPrimeDitPrefsNotification), NULL, CFNotificationSuspensionBehaviorCoalesce);
  [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                  object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *note) {
                                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                                               dispatch_get_main_queue(), ^{
                                                                 PDApplyFlexExplorer();
                                                               });
                                              }];
}
