#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Preferences.h"
#import "Compatibility.h"

// View-level options, ported from MoesReddit 4.3 (Reddit 2026.38): tips and
// prompts, collapsed ad slots and AI summaries, and colored comment thread lines.

static BOOL gHideNags;
static BOOL gHidePromoted;
static BOOL gHideAIBoxes;
static BOOL gThreadLinesEnabled;
static BOOL gThreadRainbow;
static BOOL gThreadDepthCycling;
static CGFloat gThreadThickness;
static NSInteger gThreadThemeIndex;

static NSHashTable<UIView *> *gHiddenNagChildViews;

static char kPDAdSlotStateKey;
static char kPDSummaryStateKey;
static char kPDNagStateKey;
static char kPDThreadLineStateKey;
static char kPDPromptHandledKey;
static char kPDInterfaceObserver;

#if PRIMEDIT_DEBUG
// Compatibility check: the option a collapsed view belongs to.
static PDCompatOption PDCompatOptionForCollapseKey(const void *key) {
  if (key == &kPDAdSlotStateKey) return PDCompatPromoted;
  if (key == &kPDSummaryStateKey) return PDCompatAIAnswers;
  return PDCompatNags;
}
#endif

static void PDLoadInterfacePrefs(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  gHideNags = [defaults boolForKey:kPrimeDitHideNags];
  gHidePromoted = PDPrefBool(kPrimeDitPromoted, YES);
  gHideAIBoxes = [defaults boolForKey:kPrimeDitAIBoxes];
  gThreadLinesEnabled = [defaults boolForKey:kPrimeDitThreadLinesEnabled];
  gThreadRainbow = [defaults boolForKey:kPrimeDitThreadRainbowMode];
  gThreadDepthCycling = PDPrefBool(kPrimeDitThreadDepthCycling, YES);
  gThreadThickness = [defaults objectForKey:kPrimeDitThreadLineThickness]
                         ? [defaults floatForKey:kPrimeDitThreadLineThickness]
                         : 0;
  gThreadThemeIndex = [defaults objectForKey:kPrimeDitThreadThemeIndex]
                          ? [defaults integerForKey:kPrimeDitThreadThemeIndex]
                          : -1;
}

#pragma mark - Class matching

static BOOL PDCstringLooksLikeNag(const char *n) {
  if (!n) return NO;
  if (strstr(n, "RedditAppSettings") || strstr(n, "AccountSettings")) return NO;
  if (strstr(n, "ContributionKickstarting")) return strstr(n, "EntryPoint") && strstr(n, "SliceView");
  if (strstr(n, "NudgeToCrosspost") || strstr(n, "RedditProUpsell")) return strstr(n, "SliceView") != NULL;
  return strstr(n, "RedditTooltips") && strstr(n, "TooltipView");
}

enum {
  kPDFlagComputed = 1 << 0,
  kPDFlagAdSlot = 1 << 1,
  kPDFlagThreadLine = 1 << 2,
  kPDFlagPromptView = 1 << 3,
  kPDFlagSummary = 1 << 4,
  kPDFlagNag = 1 << 5,
};

// Per-class flags, computed once; only called on the main thread.
static NSUInteger PDClassFlags(Class cls) {
  static CFMutableDictionaryRef cache;
  if (!cache) cache = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
  uintptr_t cached = (uintptr_t)CFDictionaryGetValue(cache, (__bridge const void *)cls);
  if (cached) return cached;

  NSUInteger flags = kPDFlagComputed;
  const char *n = class_getName(cls);
  if (n) {
    if (strstr(n, "HiddenAdPostReplacementSliceView") || strstr(n, "AdFeedBlankUnitSliceView"))
      flags |= kPDFlagAdSlot;
    if (strstr(n, "VerticalDivider") || strstr(n, "ThreadLine")) flags |= kPDFlagThreadLine;
    if (strstr(n, "Notifications_NotificationsPrompting") &&
        (strstr(n, "RequestPermission") || strstr(n, "PrePrompt")))
      flags |= kPDFlagPromptView;
    if (strstr(n, "ConversationSummarySliceView")) flags |= kPDFlagSummary;
    if (PDCstringLooksLikeNag(n)) flags |= kPDFlagNag;
  }
  CFDictionarySetValue(cache, (__bridge const void *)cls, (const void *)(uintptr_t)flags);
  return flags;
}

#pragma mark - Collapsing

static void PDInvalidateEnclosingList(UIView *view) {
  [view invalidateIntrinsicContentSize];
  UIView *superview = view.superview;
  [superview invalidateIntrinsicContentSize];
  [superview setNeedsLayout];
  for (UIView *v = superview; v; v = v.superview) {
    if ([v isKindOfClass:UITableView.class]) {
      UITableView *table = (UITableView *)v;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!table.window) return;
        [table beginUpdates];
        [table endUpdates];
      });
      return;
    }
    if ([v isKindOfClass:UICollectionView.class]) {
      UICollectionView *collection = (UICollectionView *)v;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!collection.window) return;
        [collection.collectionViewLayout invalidateLayout];
        [collection performBatchUpdates:nil completion:nil];
      });
      return;
    }
  }
}

// Hides a view (hidden, transparent, zero height) and restores it from the
// saved state later. The enclosing list is re-laid out only on the first
// collapse, so a list that resets frames cannot loop.
static void PDSetCollapsed(UIView *view, BOOL collapse, const void *key, BOOL relayoutList) {
  NSMutableDictionary *saved = objc_getAssociatedObject(view, key);
  if (collapse) {
    BOOL first = (saved == nil);
    if (first) saved = [NSMutableDictionary dictionary];
    CGRect frame = view.frame;
    if (first || frame.size.height > 0) saved[@"height"] = @(frame.size.height);
    if (first || !view.hidden) saved[@"hidden"] = @(view.hidden);
    if (first || view.alpha > 0) saved[@"alpha"] = @(view.alpha);
    objc_setAssociatedObject(view, key, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL changed = NO;
    if (!view.hidden) {
      view.hidden = YES;
      changed = YES;
    }
    if (view.alpha > 0) {
      view.alpha = 0;
      changed = YES;
    }
    if (frame.size.height > 0) {
      frame.size.height = 0;
      view.frame = frame;
      changed = YES;
    }
    if (changed && first && relayoutList) PDInvalidateEnclosingList(view);
    PDCOMPAT_ACTION_IF(first, PDCompatOptionForCollapseKey(key), @"%s", object_getClassName(view));
    return;
  }

  if (!saved) return;
  view.hidden = [saved[@"hidden"] boolValue];
  view.alpha = [saved[@"alpha"] doubleValue];
  CGRect frame = view.frame;
  frame.size.height = [saved[@"height"] doubleValue];
  view.frame = frame;
  objc_setAssociatedObject(view, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (relayoutList) {
    PDInvalidateEnclosingList(view);
  } else {
    [view setNeedsLayout];
    [view.superview setNeedsLayout];
  }
}

static void PDApplyNagView(UIView *view) {
  PDSetCollapsed(view, gHideNags, &kPDNagStateKey, YES);
  if (![view respondsToSelector:NSSelectorFromString(@"dismissOverlay")]) return;
  id overlay = nil;
  @try {
    overlay = [view valueForKey:@"dismissOverlay"];
  } @catch (NSException *exception) {
    overlay = nil;
  }
  if ([overlay isKindOfClass:UIView.class]) PDSetCollapsed(overlay, gHideNags, &kPDNagStateKey, YES);
}

#pragma mark - Thread lines

// Palettes in MoesReddit's index order, so exported settings stay compatible;
// the settings page draws them as swatches.
NSArray<UIColor *> *PDPaletteColors(NSInteger index) {
  static NSArray<NSArray<UIColor *> *> *palettes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    static const uint32_t hexes[15][7] = {
        {0xff4500, 0xff8700, 0xffd700, 0xff69b4, 0x9370db, 0x00ced1},
        {0x00ffff, 0xff007f, 0x7928ca, 0xff0055, 0x00ffcc, 0xffe600},
        {0xf72585, 0x7209b7, 0x3a0ca3, 0x4361ee, 0x4cc9f0},
        {0x00ff41, 0x008f11, 0x003b00, 0x0d0208, 0x00ff66},
        {0x88c0d0, 0x81a1c1, 0x5e81ac, 0xbf616a, 0xebcb8b, 0xa3be8c},
        {0xbd93f9, 0x8be9fd, 0x50fa7b, 0xffb86c, 0xff79c6, 0xff5555},
        {0x83a598, 0x8ec07c, 0xfabd2f, 0xfe8019, 0xfb4934, 0xb8bb26},
        {0x7aa2f7, 0xbb9af7, 0x7dcfff, 0x9ece6a, 0xe0af68, 0xf7768e},
        {0xc4a7e7, 0xebbcba, 0xf6c177, 0x31748f, 0x9ccfd8, 0xeb6f92},
        {0x268bd2, 0x2aa198, 0x859900, 0xb58900, 0xcb4b16, 0xdc322f},
        {0xff00ff, 0x00ffff, 0x39ff14, 0xffff00, 0xff0000},
        {0x0074d9, 0x7fdbff, 0x39cccc, 0x001f3f},
        {0xffd1dc, 0xd1ffd1, 0xd1d1ff, 0xfffdd1},
        {0xeeeeee, 0xcccccc, 0x999999, 0x666666},
        {0xff0000, 0xff7f00, 0xffff00, 0x00ff00, 0x0000ff, 0x4b0082, 0x9400d3},
    };
    static const int counts[15] = {6, 6, 5, 5, 6, 6, 6, 6, 6, 6, 5, 4, 4, 4, 7};
    NSMutableArray *all = [NSMutableArray array];
    for (int p = 0; p < 15; p++) {
      NSMutableArray *colors = [NSMutableArray array];
      for (int i = 0; i < counts[p]; i++) {
        uint32_t h = hexes[p][i];
        [colors addObject:[UIColor colorWithRed:((h >> 16) & 0xFF) / 255.0
                                          green:((h >> 8) & 0xFF) / 255.0
                                           blue:(h & 0xFF) / 255.0
                                          alpha:1.0]];
      }
      [all addObject:colors];
    }
    palettes = all;
  });
  return (index >= 0 && index < (NSInteger)palettes.count) ? palettes[index] : nil;
}

// Reply depth = number of sibling thread lines to the left of this one.
static NSUInteger PDDividerDepth(UIView *view) {
  NSUInteger depth = 0;
  CGFloat x = view.frame.origin.x;
  for (UIView *sibling in view.superview.subviews) {
    if (sibling == view) continue;
    if (!(PDClassFlags(object_getClass(sibling)) & kPDFlagThreadLine)) continue;
    if (sibling.frame.origin.x < x) depth++;
  }
  return depth;
}

static void PDApplyThreadLine(UIView *view) {
  NSMutableDictionary *saved = objc_getAssociatedObject(view, &kPDThreadLineStateKey);

  if (!gThreadLinesEnabled) {
    if (!saved) return;
    id original = saved[@"color"];
    view.backgroundColor = [original isKindOfClass:UIColor.class] ? original : nil;
    CGFloat width = [saved[@"width"] doubleValue];
    CGRect frame = view.frame;
    if (width > 0 && fabs(frame.size.width - width) > 0.01) {
      frame.origin.x -= (width - frame.size.width) / 2.0;
      frame.size.width = width;
      view.frame = frame;
    }
    objc_setAssociatedObject(view, &kPDThreadLineStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return;
  }

  if (!saved) {
    saved = [NSMutableDictionary dictionary];
    saved[@"width"] = @(view.frame.size.width);
    saved[@"color"] = view.backgroundColor ?: (id)NSNull.null;
    objc_setAssociatedObject(view, &kPDThreadLineStateKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PDCOMPAT_ACTION(PDCompatThreadLines, @"Depth %lu", (unsigned long)PDDividerDepth(view));
  }

  CGFloat target = gThreadThickness > 0.01 ? gThreadThickness : [saved[@"width"] doubleValue];
  CGRect frame = view.frame;
  if (target > 0 && fabs(frame.size.width - target) > 0.01) {
    frame.origin.x += (frame.size.width - target) / 2.0;
    frame.size.width = target;
    view.frame = frame;
  }

  UIColor *color = nil;
  if (gThreadRainbow) {
    color = [UIColor colorWithHue:(CGFloat)(view.hash % 1000) / 1000.0
                       saturation:0.8
                       brightness:0.9
                            alpha:1.0];
  } else {
    NSArray<UIColor *> *colors = PDPaletteColors(gThreadThemeIndex);
    if (colors.count)
      color = gThreadDepthCycling ? colors[PDDividerDepth(view) % colors.count] : colors[0];
  }
  if (!color) {
    id original = saved[@"color"];
    color = [original isKindOfClass:UIColor.class] ? original : nil;
  }
  if (![view.backgroundColor isEqual:color]) view.backgroundColor = color;
#if PRIMEDIT_DEBUG
  saved[@"applied"] = color ?: (id)NSNull.null;
#endif
}

#pragma mark - Notification prompts and nag controllers

static BOOL PDClassNameLooksLikeNotificationPrompt(NSString *name) {
  if (![name containsString:@"Notifications_NotificationsPrompting"]) return NO;
  for (NSString *needle in @[ @"RequestPermission", @"PrePrompt", @"PromptPresenter", @"FiveSessions",
                              @"RePrompt", @"ReEnablement", @"InitialPush" ])
    if ([name containsString:needle]) return YES;
  return NO;
}

static BOOL PDStringLooksLikeNotificationPrompt(NSString *text) {
  if (![text isKindOfClass:NSString.class] || text.length == 0) return NO;
  NSString *lower = text.lowercaseString;
  for (NSString *needle in @[ @"turn on notification", @"allow reddit notification",
                              @"enable push notification", @"be the first to know",
                              @"get what you need, in a tap", @"stay up to date" ])
    if ([lower containsString:needle]) return YES;
  return NO;
}

static BOOL PDIsNotificationPermissionPrompt(UIViewController *vc) {
  if (!vc) return NO;
  if ([vc isKindOfClass:UINavigationController.class])
    return PDIsNotificationPermissionPrompt(((UINavigationController *)vc).topViewController);
  if (PDClassNameLooksLikeNotificationPrompt(NSStringFromClass(vc.class))) return YES;
  if ([vc isKindOfClass:UIAlertController.class]) {
    UIAlertController *alert = (UIAlertController *)vc;
    return PDStringLooksLikeNotificationPrompt(alert.title) ||
           PDStringLooksLikeNotificationPrompt(alert.message);
  }
  return NO;
}

static BOOL PDObjectLooksLikeNag(id object) {
  return object && PDCstringLooksLikeNag(object_getClassName(object));
}

static BOOL PDShouldSuppressNagController(UIViewController *vc) {
  if (!gHideNags || !vc) return NO;
  if ([vc.tabBarController.viewControllers containsObject:vc]) return NO;
  if (PDObjectLooksLikeNag(vc)) return YES;
  if ([vc isKindOfClass:UINavigationController.class])
    return PDObjectLooksLikeNag(((UINavigationController *)vc).topViewController);
  return NO;
}

static UIViewController *PDOwningViewController(UIView *view) {
  for (UIResponder *r = view.nextResponder; r; r = r.nextResponder)
    if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
  return nil;
}

static void PDHandlePromptView(UIView *view) {
  if (!gHideNags || objc_getAssociatedObject(view, &kPDPromptHandledKey)) return;
  UIViewController *owner = PDOwningViewController(view);
  NSString *name = owner ? NSStringFromClass(owner.class) : @"";
  if (!(PDIsNotificationPermissionPrompt(owner) ||
        [name containsString:@"RPLBottomSheetPanModalWrapperViewController"] ||
        [name containsString:@"Notifications_NotificationsPrompting"]))
    return;
  objc_setAssociatedObject(view, &kPDPromptHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  owner.view.hidden = YES;
  if (owner.presentingViewController) [owner dismissViewControllerAnimated:NO completion:nil];
  view.hidden = YES;
  PDCOMPAT_ACTION(PDCompatNags, @"Notification prompt hidden");
}

#pragma mark - Refresh after a settings change

static void PDRefreshVisibleViews(void) {
  NSMutableArray<UIView *> *stack = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:UIWindowScene.class])
      [stack addObjectsFromArray:((UIWindowScene *)scene).windows];
  }
  NSUInteger visited = 0;
  while (stack.count && visited < 20000) {
    UIView *view = stack.lastObject;
    [stack removeLastObject];
    visited++;
    if (PDClassFlags(object_getClass(view)) != kPDFlagComputed) [view setNeedsLayout];
    [stack addObjectsFromArray:view.subviews];
  }
}

static void PDInterfacePrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                    const void *object, CFDictionaryRef userInfo) {
  dispatch_async(dispatch_get_main_queue(), ^{
    PDLoadInterfacePrefs();
    if (!gHideNags) {
      for (UIView *view in gHiddenNagChildViews.allObjects) view.hidden = NO;
      [gHiddenNagChildViews removeAllObjects];
    }
    PDRefreshVisibleViews();
  });
}

#pragma mark - Hooks

#if PRIMEDIT_DEBUG
// Compatibility check: the thread-line views on screen, whether they were styled and
// still show the applied color, plus other thin app views that may be the lines.
static void PDCompatScanLines(UIView *view, int depth, NSCountedSet<NSString *> *lines, NSCountedSet<NSString *> *thin,
                              NSInteger *styled, NSInteger *recolored, CGFloat *minWidth, CGFloat *maxWidth) {
  if (depth > 80 || view.hidden || view.alpha < 0.01) return;
  Class cls = object_getClass(view);
  NSString *name = [NSStringFromClass(cls) componentsSeparatedByString:@"."].lastObject;
  if (PDClassFlags(cls) & kPDFlagThreadLine) {
    [lines addObject:name];
    NSDictionary *saved = objc_getAssociatedObject(view, &kPDThreadLineStateKey);
    if (saved) (*styled)++;
    id applied = saved[@"applied"];
    if ([applied isKindOfClass:UIColor.class] && ![view.backgroundColor isEqual:applied]) (*recolored)++;
    *minWidth = MIN(*minWidth, view.bounds.size.width);
    *maxWidth = MAX(*maxWidth, view.bounds.size.width);
  } else if (view.bounds.size.width <= 3.0 && view.bounds.size.height >= 12.0 && !view.subviews.count) {
    const char *image = class_getImageName(cls);
    if (image && strncmp(image, "/System/", 8) && strncmp(image, "/usr/", 5)) [thin addObject:name];
  }
  for (UIView *subview in view.subviews)
    PDCompatScanLines(subview, depth + 1, lines, thin, styled, recolored, minWidth, maxWidth);
}

static NSString *PDCompatCountedText(NSCountedSet<NSString *> *set, NSUInteger limit) {
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSString *name in set) {
    if (parts.count == limit) break;
    [parts addObject:[NSString stringWithFormat:@"%@ \u00d7%lu", name, (unsigned long)[set countForObject:name]]];
  }
  return [parts componentsJoinedByString:@", "];
}

NSDictionary<NSString *, id> *PDCompatThreadLinesOnScreen(void) {
  NSCountedSet<NSString *> *lines = [NSCountedSet set];
  NSCountedSet<NSString *> *thin = [NSCountedSet set];
  NSInteger styled = 0, recolored = 0;
  CGFloat minWidth = CGFLOAT_MAX, maxWidth = 0;
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows)
      if (![NSStringFromClass(window.class) isEqualToString:@"PDCompatButtonWindow"])
        PDCompatScanLines(window, 0, lines, thin, &styled, &recolored, &minWidth, &maxWidth);
  }
  NSUInteger total = 0;
  for (NSString *name in lines) total += [lines countForObject:name];
  NSString *text = @"On screen: no thread line view";
  if (total)
    text = [NSString stringWithFormat:@"On screen: %@ \u00b7 %ld styled \u00b7 %ld recolored afterwards \u00b7 "
                                      @"width %.1f-%.1f pt",
                                      PDCompatCountedText(lines, 3), (long)styled, (long)recolored,
                                      minWidth, maxWidth];
  if (thin.count) text = [text stringByAppendingFormat:@" \u00b7 other thin views: %@", PDCompatCountedText(thin, 4)];
  return @{@"lines" : @(total), @"styled" : @(styled), @"recolored" : @(recolored), @"text" : text};
}
#endif

%hook UIView
- (void)layoutSubviews {
  %orig;
  if (!NSThread.isMainThread) return;
  NSUInteger flags = PDClassFlags(object_getClass(self));
  if (flags == kPDFlagComputed) return;
  if (flags & kPDFlagAdSlot) PDSetCollapsed(self, gHidePromoted, &kPDAdSlotStateKey, NO);
  if (flags & kPDFlagThreadLine) PDApplyThreadLine(self);
  if (flags & kPDFlagPromptView) PDHandlePromptView(self);
  if (flags & kPDFlagSummary) PDSetCollapsed(self, gHideAIBoxes, &kPDSummaryStateKey, YES);
  if (flags & kPDFlagNag) PDApplyNagView(self);
}
%end

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
  if (gHideNags && (PDIsNotificationPermissionPrompt(vc) || PDShouldSuppressNagController(vc))) {
    PDCOMPAT_ACTION(PDCompatNags, @"Blocked %s", object_getClassName(vc));
    if (completion) completion();
    return;
  }
  %orig;
}

- (void)addChildViewController:(UIViewController *)child {
  if (gHideNags && PDIsNotificationPermissionPrompt(child)) {
    PDCOMPAT_ACTION(PDCompatNags, @"Blocked %s", object_getClassName(child));
    return;
  }
  %orig;
  if (gHideNags && ![child isKindOfClass:UINavigationController.class] &&
      PDShouldSuppressNagController(child)) {
    child.view.hidden = YES;
    PDCOMPAT_ACTION(PDCompatNags, @"Hid %s", object_getClassName(child));
    if (!gHiddenNagChildViews) gHiddenNagChildViews = [NSHashTable weakObjectsHashTable];
    [gHiddenNagChildViews addObject:child.view];
  }
}
%end

%hook UIWindow
- (void)setRootViewController:(UIViewController *)root {
  if (gHideNags && PDIsNotificationPermissionPrompt(root)) {
    PDCOMPAT_ACTION(PDCompatNags, @"Blocked %s", object_getClassName(root));
    return;
  }
  %orig;
}
%end

// With Tips & prompts hidden, the system permission request is answered "not
// granted" without showing iOS's dialog, as MoesReddit does.
%hook UNUserNotificationCenter
- (void)requestAuthorizationWithOptions:(NSUInteger)options
                      completionHandler:(void (^)(BOOL granted, NSError *error))completionHandler {
  if (!gHideNags) {
    %orig;
    return;
  }
  PDCOMPAT_ACTION(PDCompatNags, @"Notification permission request declined");
  if (completionHandler) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      completionHandler(NO, nil);
    });
  }
}
%end

%group PromptBridge
%hook PushNotificationPromptingManagerObjC
- (void)showUpvotePromptIfNeeded {
  if (gHideNags) {
    PDCOMPAT_ACTION(PDCompatNags, @"Upvote notification prompt skipped");
    return;
  }
  %orig;
}
%end
%end

%ctor {
  PDLoadInterfacePrefs();
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &kPDInterfaceObserver,
                                  PDInterfacePrefsChanged, CFSTR(kPrimeDitPrefsNotification),
                                  NULL, CFNotificationSuspensionBehaviorCoalesce);
  %init;
  %init(PromptBridge,
        PushNotificationPromptingManagerObjC = objc_getClass(
            "_TtC47Notifications_NotificationsPrompting_ObjCBridge36PushNotificationPromptingManagerObjC"));
}
