#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "PDTPreferences.h"
#import "PDTCompatibility.h"
#import "PDTTabs.h"
#import "PDTRefresh.h"

// Refresh options (Reddit 2026.38): Home position, Home refresh and pull to refresh.

static BOOL gKeepHomeFeed;
static BOOL gConfirmHomeRefresh;
static BOOL gConfirmPullToRefresh;
static BOOL gHomeRefreshAllowOnce;
static BOOL gHomePromptVisible;
static BOOL gReplayingRefresh;
static CFAbsoluteTime gHomeReturnTime;
static CFAbsoluteTime gProgrammaticRefreshTime;
static NSMutableSet<NSString *> *gInstalledRefreshHooks;
static char kPDTRefreshObserver;

static void PDTLoadRefreshPrefs(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    gKeepHomeFeed = [defaults boolForKey:kPrimeDitKeepFeedOnTabReturn];
    gConfirmHomeRefresh = [defaults boolForKey:kPrimeDitConfirmHomeRefresh];
    gConfirmPullToRefresh = [defaults boolForKey:kPrimeDitConfirmPullToRefresh];
}

#pragma mark - Home refresh and pull to refresh

void PDTNoteHomeTabSelection(UITabBarController *tbc, UIViewController *vc) {
    if (!tbc || !vc || vc == tbc.selectedViewController) return;
    if (PDTIsHomeTab(vc) && !PDTIsHomeTab(tbc.selectedViewController)) gHomeReturnTime = CFAbsoluteTimeGetCurrent();
}

// Reloads fired within 2.5 s of switching back to Home are dropped.
static BOOL PDTKeepHomeFeedWindowOpen(void) {
    if (!gKeepHomeFeed) return NO;
    UITabBarController *tbc = gMainTabBar;
    if (!tbc || !PDTIsHomeTab(tbc.selectedViewController)) return NO;
    return CFAbsoluteTimeGetCurrent() - gHomeReturnTime < 2.5;
}

static BOOL PDTIsHomeReselect(UITabBarController *tbc, UIViewController *vc) {
    if (!tbc || !vc || tbc.selectedViewController != vc) return NO;
    if (!PDTTabIsAtRoot(vc) || !PDTIsHomeTab(vc)) return NO;
    SEL visibleSel = NSSelectorFromString(@"isHomeFeedVisible");
    if ([tbc respondsToSelector:visibleSel]) return ((BOOL (*)(id, SEL))objc_msgSend)(tbc, visibleSel);
    if ([vc respondsToSelector:visibleSel]) return ((BOOL (*)(id, SEL))objc_msgSend)(vc, visibleSel);
    return YES;
}

static UIScrollView *PDTScrollViewFor(id object) {
    if ([object isKindOfClass:UIScrollView.class]) return object;
    SEL scrollSel = NSSelectorFromString(@"scrollView");
    if ([object respondsToSelector:scrollSel]) {
        id scroll = ((id (*)(id, SEL))objc_msgSend)(object, scrollSel);
        if ([scroll isKindOfClass:UIScrollView.class]) return scroll;
    }
    if (![object isKindOfClass:UIView.class]) return nil;
    for (UIView *v = ((UIView *)object).superview; v; v = v.superview)
        if ([v isKindOfClass:UIScrollView.class]) return (UIScrollView *)v;
    return nil;
}

// A user pull: the list is pulled past its top while the finger is on it.
static BOOL PDTIsUserPull(id sender) {
    UIScrollView *scroll = PDTScrollViewFor(sender);
    if (!scroll) return NO;
    CGFloat pull = -(scroll.contentOffset.y + scroll.adjustedContentInset.top);
    UIGestureRecognizerState state = scroll.panGestureRecognizer.state;
    if ((scroll.isDragging || scroll.isTracking) && pull > 8.0) return YES;
    if ((state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) && pull > 8.0) return YES;
    return state == UIGestureRecognizerStateEnded && pull > 20.0;
}

static void PDTEndRefreshing(id sender) {
    if ([sender respondsToSelector:@selector(endRefreshing)]) [sender endRefreshing];
}

static UIViewController *PDTTopPresenter(id sender) {
    UIWindow *window = [sender isKindOfClass:UIView.class] ? ((UIView *)sender).window : nil;
    if (!window) window = gMainTabBar.view.window;
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed)
        top = top.presentedViewController;
    return top;
}

// Holds a user pull behind a confirmation; `proceed` replays the original call.
static BOOL PDTInterceptPullToRefresh(id sender, void (^proceed)(void)) {
    if (!gConfirmPullToRefresh) return NO;
    if (CFAbsoluteTimeGetCurrent() - gProgrammaticRefreshTime < 1.0) return NO;
    if (!PDTIsUserPull(sender)) return NO;

    PDTEndRefreshing(sender);
    UIViewController *presenter = PDTTopPresenter(sender);
    if (!presenter || [presenter isKindOfClass:UIAlertController.class]) return YES;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Refresh Feed?"
                                                                   message:@"Pulling down reloads this feed."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now" style:UIAlertActionStyleCancel handler:nil]];
    void (^run)(void) = [proceed copy];
    [alert addAction:[UIAlertAction actionWithTitle:@"Refresh"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        gProgrammaticRefreshTime = CFAbsoluteTimeGetCurrent();
        run();
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
    PDTCOMPAT_ACTION(PDTCompatConfirmPullRefresh, @"Prompt shown");
    return YES;
}

static void PDTPerformHomeRefresh(UITabBarController *tbc, UIViewController *vc) {
    if (!PDTIsHomeReselect(tbc, vc)) return;
    gProgrammaticRefreshTime = CFAbsoluteTimeGetCurrent();
    gHomeRefreshAllowOnce = YES;
    id<UITabBarControllerDelegate> delegate = tbc.delegate;
    BOOL should = YES;
    if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)])
        should = [delegate tabBarController:tbc shouldSelectViewController:vc];
    if (should && [delegate respondsToSelector:@selector(tabBarController:didSelectViewController:)])
        [delegate tabBarController:tbc didSelectViewController:vc];
    gHomeRefreshAllowOnce = NO;
}

static void PDTPresentHomeRefreshPrompt(UITabBarController *tbc, UIViewController *vc) {
    if (!tbc || gHomePromptVisible || tbc.presentedViewController) return;
    gHomePromptVisible = YES;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Refresh Home Feed?"
                                                                   message:@"Tapping Home again reloads your feed."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *action) { gHomePromptVisible = NO; }]];
    __weak UITabBarController *weakTab = tbc;
    __weak UIViewController *weakVC = vc;
    [alert addAction:[UIAlertAction actionWithTitle:@"Refresh"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        gHomePromptVisible = NO;
        PDTPerformHomeRefresh(weakTab, weakVC);
    }]];
    [tbc presentViewController:alert animated:YES completion:nil];
    PDTCOMPAT_ACTION(PDTCompatConfirmHomeRefresh, @"Prompt shown");
}

#pragma mark - Refresh method interception

typedef NS_ENUM(NSInteger, PDTRefreshHookKind) {
    PDTRefreshHookPull,
    PDTRefreshHookKeepFeed,
};

static BOOL PDTShouldHoldRefresh(id receiver, id argument, PDTRefreshHookKind kind, void (^proceed)(void)) {
    if (kind == PDTRefreshHookKeepFeed) {
        BOOL hold = PDTKeepHomeFeedWindowOpen() && !PDTIsUserPull(receiver);
        PDTCOMPAT_ACTION_IF(hold, PDTCompatKeepHomeFeed, @"Reload held (%s)", object_getClassName(receiver));
        return hold;
    }
    id subject = (argument && PDTScrollViewFor(argument)) ? argument : receiver;
    return PDTInterceptPullToRefresh(subject, proceed);
}

// Wraps a void method taking 0-2 object arguments that the class itself
// implements; anything else is left untouched.
static void PDTSwizzleRefreshMethod(Class cls, SEL sel, PDTRefreshHookKind kind) {
    if (!cls || !sel) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    Class superclass = class_getSuperclass(cls);
    Method inherited = superclass ? class_getInstanceMethod(superclass, sel) : NULL;
    if (inherited && method_getImplementation(inherited) == method_getImplementation(method)) return;

    const char *types = method_getTypeEncoding(method);
    unsigned argc = method_getNumberOfArguments(method);
    if (!types || types[0] != 'v' || argc < 2 || argc > 4) return;
    for (unsigned i = 2; i < argc; i++) {
        char *type = method_copyArgumentType(method, i);
        const char *p = type;
        while (p && *p && strchr("rnNoORV", *p)) p++;
        BOOL isObject = p && *p == '@';
        free(type);
        if (!isObject) return;
    }

    NSString *token = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    @synchronized(gInstalledRefreshHooks) {
        if ([gInstalledRefreshHooks containsObject:token]) return;
        [gInstalledRefreshHooks addObject:token];
    }

    IMP original = method_getImplementation(method);
    IMP replacement;
    if (argc == 2) {
        replacement = imp_implementationWithBlock(^(id receiver) {
            void (^call)(void) = ^{ ((void (*)(id, SEL))original)(receiver, sel); };
            if (!PDTShouldHoldRefresh(receiver, nil, kind, call)) call();
        });
    } else if (argc == 3) {
        replacement = imp_implementationWithBlock(^(id receiver, id a) {
            void (^call)(void) = ^{ ((void (*)(id, SEL, id))original)(receiver, sel, a); };
            if (!PDTShouldHoldRefresh(receiver, a, kind, call)) call();
        });
    } else {
        replacement = imp_implementationWithBlock(^(id receiver, id a, id b) {
            void (^call)(void) = ^{ ((void (*)(id, SEL, id, id))original)(receiver, sel, a, b); };
            if (!PDTShouldHoldRefresh(receiver, a, kind, call)) call();
        });
    }
    method_setImplementation(method, replacement);
}

static void PDTInstallKeepFeedHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL fetch = NSSelectorFromString(@"fetchData");
        PDTSwizzleRefreshMethod(NSClassFromString(@"FeedPresenter"), fetch, PDTRefreshHookKeepFeed);
        Class bridged = NSClassFromString(@"_TtC20FeedKit_LegacyBridge25BridgedFeedViewController");
        PDTSwizzleRefreshMethod(bridged, fetch, PDTRefreshHookKeepFeed);
        PDTSwizzleRefreshMethod(bridged, NSSelectorFromString(@"triggerRefreshWithReason:"), PDTRefreshHookKeepFeed);
        PDTSwizzleRefreshMethod(NSClassFromString(@"_TtC9Home_Impl24HomeScreenViewController"),
                                NSSelectorFromString(@"refreshActiveFeedWithReason:"), PDTRefreshHookKeepFeed);
    });
}

// Reddit's refresh controls first, then every app class implementing a
// pull-to-refresh callback (scanned off the main thread).
static void PDTInstallPullToRefreshHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *classes = @[
            @"_TtC21RedditUI_LoadingState17RUIRefreshControl", @"_TtC8SliceKit23BuiltInUIRefreshControl",
            @"_TtC13RPLComponents16RPLPullToRefresh", @"_TtC24RedditSliceKit_RPLSlices23RefreshControlSliceView",
            @"ListingViewController"
          ];
        NSArray<NSString *> *selectors = @[
            @"beginRefreshing", @"forcePullToRefresh", @"refreshControlValueChangedWithSender:",
            @"onRefreshWithSender:", @"forcePullToRefreshWithRefreshHandler:"
          ];
        for (NSString *name in classes) {
            Class cls = NSClassFromString(name);
            for (NSString *selector in selectors)
                PDTSwizzleRefreshMethod(cls, NSSelectorFromString(selector), PDTRefreshHookPull);
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            SEL didPull = NSSelectorFromString(@"refreshControlDidPullToRefresh:");
            SEL valueChanged = NSSelectorFromString(@"refreshControlValueChangedWithSender:");
            SEL listing = NSSelectorFromString(@"listingStateController:didPullToRefresh:");
            unsigned count = 0;
            Class __unsafe_unretained *all = objc_copyClassList(&count);
            for (unsigned i = 0; i < count; i++) {
                const char *image = class_getImageName(all[i]);
                if (!image || !strncmp(image, "/System/", 8) || !strncmp(image, "/usr/", 5)) continue;
                PDTSwizzleRefreshMethod(all[i], didPull, PDTRefreshHookPull);
                PDTSwizzleRefreshMethod(all[i], valueChanged, PDTRefreshHookPull);
                const char *name = class_getName(all[i]);
                if (strstr(name, "Listing") || strstr(name, "Feed") || strstr(name, "Refresh"))
                    PDTSwizzleRefreshMethod(all[i], listing, PDTRefreshHookPull);
            }
            free(all);
        });
    });
}

void PDTInstallRefreshHooksIfNeeded(void) {
    if (gKeepHomeFeed) PDTInstallKeepFeedHooks();
    if (gConfirmPullToRefresh) PDTInstallPullToRefreshHooks();
}

// Holds a second tap on Home until the refresh is confirmed; YES when held.
BOOL PDTHoldHomeReselect(UITabBarController *tbc, UIViewController *vc) {
    if (gHomeRefreshAllowOnce || !gConfirmHomeRefresh || !PDTIsHomeReselect(tbc, vc)) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        PDTPresentHomeRefreshPrompt(tbc, vc);
    });
    return YES;
}

static void PDTRefreshPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PDTLoadRefreshPrefs();
        PDTInstallRefreshHooksIfNeeded();
    });
}

%hook UIRefreshControl
- (void)sendActionsForControlEvents:(UIControlEvents)events {
    if (!gReplayingRefresh && (events & UIControlEventValueChanged)) {
        __weak UIRefreshControl *weakSelf = self;
        BOOL held = PDTInterceptPullToRefresh(self, ^{
            gReplayingRefresh = YES;
            [weakSelf sendActionsForControlEvents:events];
            gReplayingRefresh = NO;
        });
        if (held) return;
    }
    %orig;
}
%end

%ctor {
    gInstalledRefreshHooks = [NSMutableSet set];
    PDTLoadRefreshPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &kPDTRefreshObserver,
                                    PDTRefreshPrefsChanged, CFSTR(kPrimeDitPrefsNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    %init;
}
