#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Preferences.h"
#import "Compatibility.h"

// Tab bar and refresh options (Reddit 2026.38).
// The Chat tab splits Reddit's Inbox into two tabs that share one Inbox
// instance; a container re-parents it on appear and flips its inner segment.

extern UIImage *iconWithName(NSString *iconName);

@interface _TtC10MainTabBar24MainTabBarControllerImpl : UITabBarController
@end

@interface _TtC16MainTabBar_Inbox19InboxViewController : UIViewController
@end

static BOOL gChatTabEnabled;
static BOOL gHideGamesTab;
static BOOL gAllowProfileHold;
static BOOL gKeepHomeFeed;
static BOOL gConfirmHomeRefresh;
static BOOL gConfirmPullToRefresh;
static BOOL gKeepTabBarExpanded;
static NSInteger gLaunchTab;

static __weak UITabBarController *gMainTabBar;
static NSArray<UIViewController *> *gOriginalTabs;
static UIViewController *gFakeInbox;
static UIViewController *gFakeChat;
static __weak UIViewController *gRealInboxContent;
static BOOL gInitialFeedLoaded;
static BOOL gLaunchTabConsumed;
static BOOL gHomeRefreshAllowOnce;
static BOOL gHomePromptVisible;
static BOOL gReplayingRefresh;
static CFAbsoluteTime gHomeReturnTime;
static CFAbsoluteTime gProgrammaticRefreshTime;
static NSMutableSet<NSString *> *gInstalledRefreshHooks;
static char kPDTabsObserver;

static const NSInteger kPDInboxTabTag = 9998;
static const NSInteger kPDChatTabTag = 9999;

static void PDLoadTabPrefs(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  gChatTabEnabled = !PDPrefBool(kPrimeDitChatTabDisabled, YES);
  gHideGamesTab = [defaults boolForKey:kPrimeDitGamesTabDisabled];
  gAllowProfileHold = PDPrefBool(kPrimeDitProfileAccountSwitcher, YES);
  gKeepHomeFeed = [defaults boolForKey:kPrimeDitKeepFeedOnTabReturn];
  gConfirmHomeRefresh = [defaults boolForKey:kPrimeDitConfirmHomeRefresh];
  gConfirmPullToRefresh = [defaults boolForKey:kPrimeDitConfirmPullToRefresh];
  gKeepTabBarExpanded = [defaults boolForKey:kPrimeDitKeepTabBarExpanded];
  gLaunchTab = [defaults integerForKey:kPrimeDitLaunchTab];
}

#pragma mark - Tab identification

static BOOL PDTabLabelMatches(UIViewController *vc, NSString *word, BOOL contains) {
  UITabBarItem *item = vc.tabBarItem;
  NSString *label = (item.accessibilityLabel.length ? item.accessibilityLabel : item.title).lowercaseString;
  if (!label.length) return NO;
  return contains ? [label containsString:word] : [label isEqualToString:word];
}

static BOOL PDLooksLikeHomeTab(UIViewController *vc) {
  NSString *name = NSStringFromClass(vc.class);
  if (([name containsString:@"Home_Impl"] && [name containsString:@"HomeScreen"]) ||
      [name containsString:@"InitialHomeFeedController"] || [name containsString:@"MainScreenHomeTab"])
    return YES;
  return PDTabLabelMatches(vc, @"home", NO);
}

static BOOL PDLooksLikeGamesTab(UIViewController *vc) {
  NSString *name = NSStringFromClass(vc.class);
  if ([name containsString:@"MainScreenGamesTab"] || [name containsString:@"GamesHub"]) return YES;
  if ([vc.tabBarItem.accessibilityIdentifier.lowercaseString containsString:@"game"]) return YES;
  return PDTabLabelMatches(vc, @"game", YES);
}

static BOOL PDLooksLikeInboxTab(UIViewController *vc) {
  if ([NSStringFromClass(vc.class) containsString:@"MainTabBar_Inbox"]) return YES;
  return PDTabLabelMatches(vc, @"inbox", NO);
}

// A tab matches if it, its navigation root/top, or a child matches.
static BOOL PDTabTreeMatches(UIViewController *vc, BOOL (*matcher)(UIViewController *), int depth) {
  if (!vc || depth > 4) return NO;
  if (matcher(vc)) return YES;
  if ([vc isKindOfClass:UINavigationController.class]) {
    UINavigationController *nav = (UINavigationController *)vc;
    return PDTabTreeMatches(nav.topViewController, matcher, depth + 1) ||
           PDTabTreeMatches(nav.viewControllers.firstObject, matcher, depth + 1);
  }
  for (UIViewController *child in vc.childViewControllers)
    if (PDTabTreeMatches(child, matcher, depth + 1)) return YES;
  return NO;
}

static BOOL PDIsHomeTab(UIViewController *vc) {
  return PDTabTreeMatches(vc, PDLooksLikeHomeTab, 0);
}

static BOOL PDIsGamesTab(UIViewController *vc) {
  return PDTabTreeMatches(vc, PDLooksLikeGamesTab, 0);
}

static BOOL PDIsInboxTab(UIViewController *vc) {
  return PDTabTreeMatches(vc, PDLooksLikeInboxTab, 0);
}

static UIViewController *PDFirstTab(NSArray<UIViewController *> *tabs, BOOL (*test)(UIViewController *)) {
  for (UIViewController *vc in tabs)
    if (test(vc)) return vc;
  return nil;
}

static BOOL PDTabIsAtRoot(UIViewController *vc) {
  UINavigationController *nav = [vc isKindOfClass:UINavigationController.class] ? (UINavigationController *)vc
                                                                              : vc.navigationController;
  if (!nav) {
    for (UIViewController *child in vc.childViewControllers) {
      if ([child isKindOfClass:UINavigationController.class]) {
        nav = (UINavigationController *)child;
        break;
      }
    }
  }
  SEL currentSel = NSSelectorFromString(@"currentViewController");
  if (!nav && [vc respondsToSelector:currentSel]) {
    id current = ((id (*)(id, SEL))objc_msgSend)(vc, currentSel);
    if ([current isKindOfClass:UINavigationController.class]) nav = current;
  }
  return !nav || nav.viewControllers.count <= 1;
}

static NSArray<UIViewController *> *PDVisibleTabs(NSArray<UIViewController *> *controllers) {
  if (!gHideGamesTab || controllers.count == 0) return controllers;
  NSMutableArray *kept = [NSMutableArray arrayWithCapacity:controllers.count];
  for (UIViewController *vc in controllers)
    if (!PDIsGamesTab(vc)) [kept addObject:vc];
  PDCOMPAT_SENTINEL(PDCompatGamesTab, kept.count < controllers.count);
  PDCOMPAT_ACTION_IF(kept.count < controllers.count, PDCompatGamesTab, @"Games tab removed");
  return kept.count ? kept : controllers;
}

#pragma mark - Inbox content / navigation

// Matched by class identity: NSStringFromClass returns "Module.Class" for Swift
// classes, so the mangled name only serves as the runtime lookup key.
static BOOL PDIsInboxContent(UIViewController *vc) {
  static Class inboxClass;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    inboxClass = NSClassFromString(@"_TtC16MainTabBar_Inbox19InboxViewController");
  });
  return inboxClass && [vc isKindOfClass:inboxClass] &&
         [vc respondsToSelector:NSSelectorFromString(@"navigateToActivityTab")] &&
         [vc respondsToSelector:NSSelectorFromString(@"navigateToChatTab")];
}

// The Inbox content is the InboxViewController inside a tab; it exposes the
// activity/chat navigation used to flip the inner segment.
static UIViewController *PDInboxContent(UIViewController *vc, int depth) {
  if (!vc || depth > 4) return nil;
  if (PDIsInboxContent(vc)) return vc;
  if ([vc isKindOfClass:UINavigationController.class]) {
    for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
      UIViewController *found = PDInboxContent(child, depth + 1);
      if (found) return found;
    }
    return nil;
  }
  for (UIViewController *child in vc.childViewControllers) {
    UIViewController *found = PDInboxContent(child, depth + 1);
    if (found) return found;
  }
  return nil;
}

// Calls one of Reddit's object getters, only when it really returns an object.
static id PDGetObject(id target, NSString *name) {
  SEL sel = NSSelectorFromString(name);
  if (![target respondsToSelector:sel]) return nil;
  const char *type = [target methodSignatureForSelector:sel].methodReturnType;
  return (type && type[0] == '@') ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

// Index of the Inbox's inner segment (0 activity, 1 chat), or -1 without one.
static NSInteger PDSegmentIndex(UIViewController *content) {
  id segment = PDGetObject(content, @"segmentedControl");
  SEL indexSel = NSSelectorFromString(@"currentIndex");
  if (![segment respondsToSelector:indexSel]) return -1;
  return ((NSInteger (*)(id, SEL))objc_msgSend)(segment, indexSel);
}

// Flips the Inbox's inner segment to activity (0) or chat (1); a
// just-built Inbox is loaded first so its segment exists before it is shown.
static void PDNavigateInbox(UIViewController *content, NSInteger tag) {
  if (!content) return;
  [content loadViewIfNeeded];
  NSInteger index = PDSegmentIndex(content);
  if (index < 0 || index == tag) return;
  SEL navSel = tag == 1 ? NSSelectorFromString(@"navigateToChatTab") : NSSelectorFromString(@"navigateToActivityTab");
  if (![content respondsToSelector:navSel]) return;
  [UIView performWithoutAnimation:^{ ((void (*)(id, SEL))objc_msgSend)(content, navSel); }];
}

#pragma mark - Container

// Hosts the shared Inbox as its child. Two of these (Inbox, Chat) exist; only
// the visible one holds the Inbox at any time, so containment moves on appear.
@interface PDContainerViewController : UIViewController
@property(nonatomic, strong) UIViewController *inbox;  // the Inbox tab (a navigation controller)
@property(nonatomic) NSInteger targetTag;
- (instancetype)initWithInbox:(UIViewController *)inbox targetTag:(NSInteger)tag;
@end

@implementation PDContainerViewController

- (instancetype)initWithInbox:(UIViewController *)inbox targetTag:(NSInteger)tag {
  self = [super initWithNibName:nil bundle:nil];
  if (self) {
    _inbox = inbox;
    _targetTag = tag;
  }
  return self;
}

- (void)embedInbox {
  UIViewController *inbox = self.inbox;
  if (!inbox) return;
  UITabBarController *tbc = self.tabBarController ?: gMainTabBar;
  if (tbc && tbc.selectedViewController != self) return;

  if (inbox.parentViewController != self) {
    [UIView performWithoutAnimation:^{
      [inbox willMoveToParentViewController:nil];
      [inbox.view removeFromSuperview];
      [inbox removeFromParentViewController];
      [self addChildViewController:inbox];
      [self.view addSubview:inbox.view];
      [inbox didMoveToParentViewController:self];
    }];
  }
  gRealInboxContent = PDInboxContent(inbox, 0);
  inbox.view.frame = self.view.bounds;
  inbox.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  [self embedInbox];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  UITabBarController *tbc = self.tabBarController ?: gMainTabBar;
  if (tbc && tbc.selectedViewController != self) return;
  [self embedInbox];
  PDNavigateInbox(PDInboxContent(self.inbox, 0), self.targetTag);
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  UITabBarController *tbc = self.tabBarController ?: gMainTabBar;
  if (tbc && tbc.selectedViewController != self) return;
  [self embedInbox];
  PDNavigateInbox(PDInboxContent(self.inbox, 0), self.targetTag);
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (self.inbox.parentViewController == self) {
    self.inbox.view.frame = self.view.bounds;
    self.inbox.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  }
}

// Make the container transparent to the tab bar and Reddit: unknown selectors,
// protocol checks and status-bar style all defer to the real Inbox.
- (id)forwardingTargetForSelector:(SEL)selector {
  if ([self.inbox respondsToSelector:selector]) return self.inbox;
  UIViewController *content = gRealInboxContent;
  if ([content respondsToSelector:selector]) return content;
  return [super forwardingTargetForSelector:selector];
}

- (BOOL)respondsToSelector:(SEL)selector {
  if ([super respondsToSelector:selector]) return YES;
  if ([self.inbox respondsToSelector:selector]) return YES;
  return [gRealInboxContent respondsToSelector:selector];
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
  if ([super conformsToProtocol:protocol]) return YES;
  if ([self.inbox conformsToProtocol:protocol]) return YES;
  return [gRealInboxContent conformsToProtocol:protocol];
}

- (UIViewController *)childViewControllerForStatusBarStyle {
  return self.inbox ?: [super childViewControllerForStatusBarStyle];
}

- (UIViewController *)childViewControllerForStatusBarHidden {
  return self.inbox ?: [super childViewControllerForStatusBarHidden];
}
@end

#pragma mark - Chat-tab installation

#pragma mark - Split tab badges

// Reddit's badge goes to its own Inbox tab, hidden while the tabs are split. The split tabs
// take their counts from BadgeCountsV2 instead (measured fields): notifications on Inbox,
// chat on Chat, the number when the style is NUMBERED, a dot for any other style.
static NSString *gSplitInboxBadge;
static NSString *gSplitChatBadge;

static NSString *PDBadgeText(id indicator) {
  if (![indicator isKindOfClass:NSDictionary.class]) return nil;
  id count = indicator[@"count"];
  NSInteger value = [count isKindOfClass:NSNumber.class] ? [count integerValue] : 0;
  if (value <= 0) return nil;
  id style = indicator[@"style"];
  if ([style isKindOfClass:NSString.class] && ![style isEqualToString:@"NUMBERED"]) return @"";
  return value > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)value];
}

static void PDShowSplitBadges(void) {
  gFakeInbox.tabBarItem.badgeValue = gSplitInboxBadge;
  gFakeChat.tabBarItem.badgeValue = gSplitChatBadge;
}

// Called by the network filter with BadgeCountsV2's data.badgeIndicators.
void PDApplySplitTabBadges(id indicators) {
  if (![indicators isKindOfClass:NSDictionary.class]) return;
  NSString *inbox = PDBadgeText(indicators[@"notificationInboxTab"]);
  NSString *chat = PDBadgeText(indicators[@"chatInboxTab"]);
  dispatch_async(dispatch_get_main_queue(), ^{
    gSplitInboxBadge = inbox;
    gSplitChatBadge = chat;
    PDShowSplitBadges();
    PDCOMPAT_ACTION_IF(inbox != nil, PDCompatChatTab, @"Badge %@ shown on the Inbox tab", inbox);
    PDCOMPAT_ACTION_IF(chat != nil, PDCompatChatTab, @"Badge %@ shown on the Chat tab", chat);
  });
}

static void PDConfigureFakeTabItems(PDContainerViewController *fakeInbox, PDContainerViewController *fakeChat,
                                    UIViewController *inboxNav) {
  UITabBarItem *original = inboxNav.tabBarItem;
  UITabBarItem *inboxItem = [[UITabBarItem alloc] initWithTitle:(original.title ?: @"Inbox")
                                                          image:original.image
                                                  selectedImage:original.selectedImage];
  inboxItem.tag = kPDInboxTabTag;
  inboxItem.accessibilityIdentifier = @"redditTabBarInboxButton";
  fakeInbox.tabBarItem = inboxItem;

  UIImage *chatImage = iconWithName(@"rpl3/chat") ?: iconWithName(@"rpl3/message")
                                                 ?: [UIImage systemImageNamed:@"message"];
  UIImage *chatSelected = iconWithName(@"rpl3/chat-fill") ?: chatImage;
  UITabBarItem *chatItem = [[UITabBarItem alloc] initWithTitle:@"Chat" image:chatImage selectedImage:chatSelected];
  chatItem.tag = kPDChatTabTag;
  chatItem.accessibilityIdentifier = @"redditTabBarChatButton";
  fakeChat.tabBarItem = chatItem;
  PDShowSplitBadges();
}

// viewIfLoaded leaves a never-shown Inbox unbuilt until its tab first appears.
static void PDDetachInbox(UIViewController *inbox) {
  if (!inbox) return;
  [inbox willMoveToParentViewController:nil];
  [inbox.viewIfLoaded removeFromSuperview];
  [inbox removeFromParentViewController];
}

// Reddit builds the Inbox screen on first display, so the tab is also known by
// the identifier Reddit gives its Inbox tab-bar item.
static BOOL PDIsInboxTabRoot(UIViewController *vc) {
  return [vc.tabBarItem.accessibilityIdentifier isEqualToString:@"reddit_tab_bar__inbox_button"] ||
         PDInboxContent(vc, 0) != nil;
}

// Turns Reddit's Inbox tab into Inbox + Chat sharing one Inbox instance.
static NSArray *PDInstallChatTabs(NSArray *tabs) {
  NSInteger inboxIndex = NSNotFound;
  UIViewController *inboxNav = nil;
  for (NSInteger i = 0; i < (NSInteger)tabs.count; i++) {
    if (PDIsInboxTabRoot(tabs[i])) {
      inboxIndex = i;
      inboxNav = tabs[i];
      break;
    }
  }
  if (inboxIndex == NSNotFound) {
    PDCOMPAT_ANOMALY(PDCompatChatTab, @"Inbox tab not found among %lu tabs", (unsigned long)tabs.count);
    return tabs;
  }

  PDContainerViewController *fakeInbox = [[PDContainerViewController alloc] initWithInbox:inboxNav targetTag:0];
  PDContainerViewController *fakeChat = [[PDContainerViewController alloc] initWithInbox:inboxNav targetTag:1];
  PDConfigureFakeTabItems(fakeInbox, fakeChat, inboxNav);
  gFakeInbox = fakeInbox;
  gFakeChat = fakeChat;
  gRealInboxContent = PDInboxContent(inboxNav, 0);
  PDDetachInbox(inboxNav);

  NSMutableArray *result = [tabs mutableCopy];
  result[inboxIndex] = fakeInbox;
  [result insertObject:fakeChat atIndex:inboxIndex + 1];
  PDCOMPAT_ACTION(PDCompatChatTab, @"Inbox split into Inbox and Chat");
  return result;
}

// Returns the real tab array without the split tabs and detaches the shared Inbox,
// so it can be shown or split again: rebuild, account switch or option change.
static NSArray *PDNormalizeToReal(NSArray *controllers) {
  UIViewController *heldInbox = gFakeInbox ? [(PDContainerViewController *)gFakeInbox inbox] : nil;
  if (heldInbox) PDDetachInbox(heldInbox);
  BOOL hasFakes = gFakeInbox &&
                  ([controllers containsObject:gFakeInbox] || [controllers containsObject:gFakeChat]);
  NSArray *result = controllers;
  if (hasFakes) {
    NSMutableArray *rebuilt = [NSMutableArray arrayWithCapacity:controllers.count];
    for (UIViewController *vc in controllers) {
      if (vc == gFakeChat) continue;
      if (vc == gFakeInbox) {
        if (heldInbox) [rebuilt addObject:heldInbox];
        continue;
      }
      [rebuilt addObject:vc];
    }
    result = rebuilt;
  }
  gFakeInbox = nil;
  gFakeChat = nil;
  gRealInboxContent = nil;
  return result;
}

#pragma mark - Split Inbox header

static char kPDInboxHeaderKey;

static PDContainerViewController *PDContainerHolding(UIViewController *content) {
  for (UIViewController *vc = content.parentViewController; vc; vc = vc.parentViewController)
    if ([vc isKindOfClass:PDContainerViewController.class]) return (PDContainerViewController *)vc;
  return nil;
}

static NSString *const kPDMarkReadIdentifier = @"reddit_chat__navigation_bar__mark_read_button";
static NSString *const kPDMarkReadAction = @"tappedMarkAllAsRead";

// Reddit's "mark all as read" envelope, known by the identifier and action it
// carries on Reddit 2026.38, under any control event.
static BOOL PDIsArchiveView(UIView *view) {
  if ([view.accessibilityIdentifier isEqualToString:kPDMarkReadIdentifier]) return YES;
  if (![view isKindOfClass:UIControl.class]) return NO;
  UIControl *control = (UIControl *)view;
  UIControlEvents events = control.allControlEvents;
  for (id target in control.allTargets)
    for (NSUInteger bit = 0; bit < 32; bit++) {
      UIControlEvents event = (UIControlEvents)(1UL << bit);
      if ((events & event) &&
          [[control actionsForTarget:target forControlEvent:event] containsObject:kPDMarkReadAction])
        return YES;
    }
  return NO;
}

static UIView *PDArchiveViewIn(UIView *view, int depth) {
  if (!view || depth > 4) return nil;
  if (PDIsArchiveView(view)) return view;
  for (UIView *subview in view.subviews) {
    UIView *found = PDArchiveViewIn(subview, depth + 1);
    if (found) return found;
  }
  return nil;
}

static NSArray<UIBarButtonItem *> *PDTrailingItems(UINavigationItem *navigationItem) {
  NSMutableArray<UIBarButtonItem *> *items =
      [NSMutableArray arrayWithArray:navigationItem.rightBarButtonItems ?: @[]];
  for (UIBarButtonItemGroup *group in navigationItem.trailingItemGroups) {
    [items addObjectsFromArray:group.barButtonItems];
    if (group.representativeItem) [items addObject:group.representativeItem];
  }
  return items;
}

// A whole bar item goes to items; a button nested in a shared custom view to views.
static void PDFindArchive(UINavigationItem *navigationItem, NSMutableArray<UIBarButtonItem *> *items,
                          NSMutableArray<UIView *> *views) {
  SEL action = NSSelectorFromString(kPDMarkReadAction);
  for (UIBarButtonItem *item in PDTrailingItems(navigationItem)) {
    UIView *view = PDArchiveViewIn(item.customView, 0);
    if (item.action == action || [item.accessibilityIdentifier isEqualToString:kPDMarkReadIdentifier] ||
        (view && view == item.customView)) {
      if (![items containsObject:item]) [items addObject:item];
    } else if (view && ![views containsObject:view]) {
      [views addObject:view];
    }
  }
}

static void PDSetArchiveHidden(UINavigationItem *navigationItem, BOOL hidden) {
  NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
  NSMutableArray<UIView *> *views = [NSMutableArray array];
  PDFindArchive(navigationItem, items, views);
  for (UIBarButtonItem *item in items) item.hidden = hidden;
  for (UIView *view in views) view.hidden = hidden;
}

static NSNumber *PDPagerScrolling(id pager) {
  SEL getter = NSSelectorFromString(@"scrollEnabled");
  if (![pager respondsToSelector:getter]) return nil;
  const char *type = [pager methodSignatureForSelector:getter].methodReturnType;
  if (!type || (type[0] != 'B' && type[0] != 'c')) return nil;
  return @(((BOOL (*)(id, SEL))objc_msgSend)(pager, getter));
}

static void PDSetPagerScrolling(id pager, BOOL enabled) {
  SEL setter = NSSelectorFromString(@"setScrollEnabled:");
  if ([pager respondsToSelector:setter]) ((void (*)(id, SEL, BOOL))objc_msgSend)(pager, setter, enabled);
}

static char kPDPageTopKey;

// With the segment bar hidden, the Inbox pages keep no top inset for it; each
// page's own value comes back when the split ends.
static void PDSyncPageInsets(UIViewController *content, id pager, BOOL split) {
  UIViewController *pagerController = [pager isKindOfClass:UIViewController.class] ? pager : nil;
  NSMutableArray<UIViewController *> *pages =
      [NSMutableArray arrayWithArray:pagerController.childViewControllers ?: @[]];
  UIViewController *current = PDGetObject(content, @"currentOnScreenViewController");
  if ([current isKindOfClass:UIViewController.class] && ![pages containsObject:current]) [pages addObject:current];
  for (UIViewController *page in pages) {
    NSNumber *original = objc_getAssociatedObject(page, &kPDPageTopKey);
    UIEdgeInsets insets = page.additionalSafeAreaInsets;
    if (split) {
      if (insets.top < 0.5) continue;
      if (!original) objc_setAssociatedObject(page, &kPDPageTopKey, @(insets.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      insets.top = 0;
    } else {
      if (!original) continue;
      insets.top = original.doubleValue;
      objc_setAssociatedObject(page, &kPDPageTopKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    page.additionalSafeAreaInsets = insets;
  }
}

static char kPDListTopKey;
static char kPDListNeededKey;
static char kPDListObservedKey;
static NSHashTable<UIScrollView *> *gTrimmedLists;

static void PDSetListTop(UIScrollView *scroll, CGFloat top) {
  BOOL atTop = scroll.contentOffset.y <= 0.5 - scroll.adjustedContentInset.top;
  UIEdgeInsets inset = scroll.contentInset;
  inset.top = top;
  scroll.contentInset = inset;
  if (atTop) scroll.contentOffset = CGPointMake(scroll.contentOffset.x, -scroll.adjustedContentInset.top);
}

// The Inbox page's list: Reddit's own getter when it answers (it answers nothing in Reddit
// 2026.38, measured), else the largest visible table or collection view in the page.
static UIScrollView *PDFindInboxList(UIViewController *content) {
  UIScrollView *scroll = PDGetObject(content, @"currentOnScreenScrollView");
  if ([scroll isKindOfClass:UIScrollView.class]) return scroll;
  UIScrollView *best = nil;
  CGFloat bestArea = 0;
  NSMutableArray<UIView *> *stack = [NSMutableArray array];
  if (content.viewIfLoaded) [stack addObject:content.viewIfLoaded];
  for (NSUInteger visited = 0; stack.count && visited < 3000; visited++) {
    UIView *view = stack.lastObject;
    [stack removeLastObject];
    if (view.hidden || view.alpha < 0.01) continue;
    if (view.window && ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class])) {
      CGRect visible = CGRectIntersection([view convertRect:view.bounds toView:nil], view.window.bounds);
      CGFloat area = CGRectIsNull(visible) ? 0 : visible.size.width * visible.size.height;
      if (area > bestArea) {
        bestArea = area;
        best = (UIScrollView *)view;
      }
    }
    [stack addObjectsFromArray:view.subviews];
  }
  return best;
}

// Keeps a watched Inbox list at the inset it needs: Reddit may set its own inset again
// after the page appears. A running refresh is left alone.
@interface PDListInsetKeeper : NSObject
@end

@implementation PDListInsetKeeper
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
  if (context != &kPDListNeededKey) {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    return;
  }
  UIScrollView *scroll = object;
  NSNumber *needed = objc_getAssociatedObject(scroll, &kPDListNeededKey);
  if (!gChatTabEnabled || !needed || scroll.refreshControl.isRefreshing) return;
  if (scroll.contentInset.top <= needed.doubleValue + 0.5) return;
  PDSetListTop(scroll, needed.doubleValue);
  PDCOMPAT_ACTION(PDCompatChatTab, @"Inbox list: inset set again to %.0f pt", needed.doubleValue);
}
@end

static PDListInsetKeeper *gListInsetKeeper;

// With the segment bar hidden, the Inbox list starts right under the header yet keeps a
// top inset (52 pt, measured) with nothing in it. Only what reaches below the header is
// kept, and the list stays watched; the inset comes back when the split ends.
static void PDSyncListInset(UIViewController *content, BOOL split) {
  if (!split) {
    for (UIScrollView *scroll in gTrimmedLists.allObjects) {
      if (objc_getAssociatedObject(scroll, &kPDListObservedKey))
        [scroll removeObserver:gListInsetKeeper forKeyPath:@"contentInset" context:&kPDListNeededKey];
      objc_setAssociatedObject(scroll, &kPDListObservedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      objc_setAssociatedObject(scroll, &kPDListNeededKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      NSNumber *original = objc_getAssociatedObject(scroll, &kPDListTopKey);
      if (original) PDSetListTop(scroll, original.doubleValue);
      objc_setAssociatedObject(scroll, &kPDListTopKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [gTrimmedLists removeAllObjects];
    return;
  }
  UIView *root = content.viewIfLoaded;
  UIScrollView *scroll = root.window ? PDFindInboxList(content) : nil;
  if (!scroll) return;
  CGFloat header = [root convertPoint:CGPointMake(0, root.safeAreaInsets.top) toView:nil].y;
  CGFloat listTop = CGRectGetMinY([scroll.superview convertRect:scroll.frame toView:nil]);
  CGFloat needed = MAX(0.0, header - listTop);
  if (!gTrimmedLists) gTrimmedLists = [NSHashTable weakObjectsHashTable];
  [gTrimmedLists addObject:scroll];
  objc_setAssociatedObject(scroll, &kPDListNeededKey, @(needed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!objc_getAssociatedObject(scroll, &kPDListObservedKey)) {
    if (!gListInsetKeeper) gListInsetKeeper = [[PDListInsetKeeper alloc] init];
    [scroll addObserver:gListInsetKeeper forKeyPath:@"contentInset" options:0 context:&kPDListNeededKey];
    objc_setAssociatedObject(scroll, &kPDListObservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  CGFloat top = scroll.contentInset.top;
  if (top <= needed + 0.5) return;
  if (!objc_getAssociatedObject(scroll, &kPDListTopKey))
    objc_setAssociatedObject(scroll, &kPDListTopKey, @(top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  PDSetListTop(scroll, needed);
  PDCOMPAT_ACTION(PDCompatChatTab, @"Inbox list: top inset %.0f pt set to %.0f pt", top, needed);
}

static void PDSetInboxTitle(UINavigationItem *navigationItem, NSString *title) {
  if (!title.length) return;
  navigationItem.title = title;
  if ([navigationItem.titleView isKindOfClass:UILabel.class]) ((UILabel *)navigationItem.titleView).text = title;
}

// The list can appear after the page does (found 0.8 s after appearance, measured), so the
// check runs on appearance and again a little later while the Inbox tab is shown.
static void PDSyncListInsetSoon(UIViewController *content) {
  PDSyncListInset(content, YES);
  __weak UIViewController *weakContent = content;
  for (NSNumber *delay in @[ @0.4, @0.8, @1.6 ]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      UIViewController *strongContent = weakContent;
      PDContainerViewController *container = gChatTabEnabled ? PDContainerHolding(strongContent) : nil;
      if (container && container.targetTag == 0) PDSyncListInset(strongContent, YES);
    });
  }
}

// Split mode header: no segment bar and no swiping to the other page, the mark-all-read
// envelope on the Inbox tab only, and "Chat" as the Chat tab's title. Reddit rebuilds its
// header on every appearance, so this runs after it each time and undoes itself otherwise.
static void PDApplyInboxHeader(UIViewController *content) {
  PDContainerViewController *container = gChatTabEnabled ? PDContainerHolding(content) : nil;
  NSMutableDictionary *saved = objc_getAssociatedObject(content, &kPDInboxHeaderKey);
  if (!container && !saved) return;
  UIView *wrapper = PDGetObject(content, @"segmentWrapper");
  if (![wrapper isKindOfClass:UIView.class]) wrapper = nil;
  NSLayoutConstraint *height = PDGetObject(content, @"segmentWrapperHeightConstraint");
  if (![height isKindOfClass:NSLayoutConstraint.class]) height = nil;
  id pager = PDGetObject(content, @"pageViewController");
  UINavigationItem *navigationItem = content.navigationItem;

  if (!container) {
    if (height && saved[@"height"]) height.constant = [saved[@"height"] doubleValue];
    if (saved[@"scroll"]) PDSetPagerScrolling(pager, [saved[@"scroll"] boolValue]);
    PDSyncPageInsets(content, pager, NO);
    PDSyncListInset(content, NO);
    PDSetArchiveHidden(navigationItem, NO);
    PDSetInboxTitle(navigationItem, saved[@"title"]);
    objc_setAssociatedObject(content, &kPDInboxHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return;
  }
  if (!saved) {
    saved = [NSMutableDictionary dictionary];
    if (height) saved[@"height"] = @(height.constant);
    NSNumber *scroll = PDPagerScrolling(pager);
    if (scroll) saved[@"scroll"] = scroll;
    objc_setAssociatedObject(content, &kPDInboxHeaderKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  NSString *title = navigationItem.title;
  if (title.length && ![title isEqualToString:@"Chat"]) saved[@"title"] = title;

  wrapper.hidden = YES;
  height.constant = 0;
  PDSetPagerScrolling(pager, NO);
  PDSyncPageInsets(content, pager, YES);
  if (container.targetTag == 0) PDSyncListInsetSoon(content);
  PDSetArchiveHidden(navigationItem, container.targetTag == 1);
  PDSetInboxTitle(navigationItem, container.targetTag == 1 ? @"Chat" : saved[@"title"]);
  [content.viewIfLoaded setNeedsLayout];
}

#if PRIMEDIT_DEBUG
// Compatibility check: controls on the header's right side with their actions, to
// locate a button that could not be found.
static void PDCompatCollectControls(UIView *view, int depth, NSMutableArray<NSString *> *out) {
  if (!view || depth > 4 || out.count >= 8) return;
  if ([view isKindOfClass:UIControl.class]) {
    UIControl *control = (UIControl *)view;
    NSMutableSet<NSString *> *actions = [NSMutableSet set];
    for (id target in control.allTargets)
      for (NSUInteger bit = 0; bit < 32; bit++) {
        NSArray<NSString *> *names = [control actionsForTarget:target forControlEvent:(UIControlEvents)(1UL << bit)];
        if (names) [actions addObjectsFromArray:names];
      }
    NSString *identifier = view.accessibilityIdentifier;
    [out addObject:[NSString stringWithFormat:@"%s(%@)%@", object_getClassName(view),
                                              [actions.allObjects componentsJoinedByString:@","],
                                              identifier.length ? [@"#" stringByAppendingString:identifier] : @""]];
  }
  for (UIView *subview in view.subviews) PDCompatCollectControls(subview, depth + 1, out);
}

static NSString *PDCompatDescribeTrailingItems(UINavigationItem *navigationItem) {
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (UIBarButtonItem *item in PDTrailingItems(navigationItem)) {
    NSMutableArray<NSString *> *controls = [NSMutableArray array];
    PDCompatCollectControls(item.customView, 0, controls);
    [parts addObject:[NSString stringWithFormat:@"[%@ %s %@]", item.action ? NSStringFromSelector(item.action) : @"-",
                                                 item.customView ? object_getClassName(item.customView) : "-",
                                                 [controls componentsJoinedByString:@" "]]];
  }
  return parts.count ? [parts componentsJoinedByString:@" "] : @"no trailing items";
}

// Compatibility check: a gap of more than 22 pt between the header and the first Inbox row.
static NSString *PDCompatListBand(UIViewController *content) {
  UIView *root = content.viewIfLoaded;
  if (!root.window) return nil;
  UIScrollView *scroll = PDFindInboxList(content);
  if (!scroll) return @"Inbox list not found";
  CGFloat header = [root convertPoint:CGPointMake(0, root.safeAreaInsets.top) toView:nil].y;
  CGFloat first = CGFLOAT_MAX;
  for (UIView *view in scroll.subviews)
    if (!view.hidden && view.bounds.size.height >= 1.0 &&
        ([view isKindOfClass:UICollectionViewCell.class] || [view isKindOfClass:UITableViewCell.class]))
      first = MIN(first, CGRectGetMinY([view convertRect:view.bounds toView:nil]));
  if (first == CGFLOAT_MAX || first - header <= 22.0) return nil;
  return [NSString stringWithFormat:@"%.0f pt gap between the header and the first row", first - header];
}

// Compatibility check: confirms the split header once the Inbox screen is on screen.
static void PDCompatVerifyInboxHeader(UIViewController *content) {
  PDContainerViewController *container = gChatTabEnabled ? PDContainerHolding(content) : nil;
  if (!container) return;
  BOOL chat = container.targetTag == 1;
  UIView *wrapper = PDGetObject(content, @"segmentWrapper");
  UINavigationItem *navigationItem = content.navigationItem;
  NSMutableArray<UIBarButtonItem *> *archiveItems = [NSMutableArray array];
  NSMutableArray<UIView *> *archiveViews = [NSMutableArray array];
  PDFindArchive(navigationItem, archiveItems, archiveViews);
  NSMutableArray<NSString *> *problems = [NSMutableArray array];
  if (![wrapper isKindOfClass:UIView.class])
    [problems addObject:@"segment bar not found"];
  else if (!wrapper.hidden && wrapper.bounds.size.height > 0.5)
    [problems addObject:@"segment bar still shown"];
  if (!archiveItems.count && !archiveViews.count)
    [problems addObject:[@"mark-all-read button not found in " stringByAppendingString:
                                                                 PDCompatDescribeTrailingItems(navigationItem)]];
  BOOL archiveShown = NO;
  for (UIBarButtonItem *item in archiveItems) archiveShown = archiveShown || !item.hidden;
  for (UIView *view in archiveViews) archiveShown = archiveShown || !view.hidden;
  if (chat && archiveShown) [problems addObject:@"mark-all-read button shown on the Chat tab"];
  if (!chat && !archiveShown && (archiveItems.count || archiveViews.count))
    [problems addObject:@"mark-all-read button hidden on the Inbox tab"];
  if ([PDPagerScrolling(PDGetObject(content, @"pageViewController")) boolValue])
    [problems addObject:@"swiping to the other page still on"];
  if (PDSegmentIndex(content) != container.targetTag)
    [problems addObject:chat ? @"Notifications page shown" : @"Chat page shown"];
  if (chat && ![navigationItem.title isEqualToString:@"Chat"]) [problems addObject:@"title is not Chat"];
  UIViewController *page = PDGetObject(content, @"currentOnScreenViewController");
  if ([page isKindOfClass:UIViewController.class] && page.additionalSafeAreaInsets.top > 1.0)
    [problems addObject:[NSString stringWithFormat:@"list pushed down %.0f pt", page.additionalSafeAreaInsets.top]];
  UIViewController *pager = PDGetObject(content, @"pageViewController");
  UIView *pagerView = [pager isKindOfClass:UIViewController.class] ? pager.viewIfLoaded : nil;
  if ([wrapper isKindOfClass:UIView.class] && pagerView.window) {
    CGFloat gap = CGRectGetMinY([pagerView convertRect:pagerView.bounds toView:content.view]) -
                  CGRectGetMinY([wrapper convertRect:wrapper.bounds toView:content.view]);
    if (gap > 1.0) [problems addObject:[NSString stringWithFormat:@"%.0f pt empty band above the list", gap]];
  }
  if (chat && navigationItem.titleView && ![navigationItem.titleView isKindOfClass:UILabel.class])
    [problems addObject:@"title drawn by a custom view"];
  NSString *band = chat ? nil : PDCompatListBand(content);
  if (band) [problems addObject:band];
  NSString *tab = chat ? @"Chat" : @"Inbox";
  if (problems.count)
    PDCompatRecordAnomaly(PDCompatChatTab,
                          [NSString stringWithFormat:@"%@ tab: %@", tab, [problems componentsJoinedByString:@", "]]);
  else
    PDCompatRecordAction(PDCompatChatTab, [NSString stringWithFormat:@"%@ tab shown with its own header", tab]);
}

// Runs once Reddit's own layout of the page has settled.
static void PDCompatVerifyInboxHeaderLater(UIViewController *content) {
  __weak UIViewController *weakContent = content;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    UIViewController *strongContent = weakContent;
    if (strongContent.viewIfLoaded.window) PDCompatVerifyInboxHeader(strongContent);
  });
}

#define PDCOMPAT_VERIFY_INBOX_HEADER(content)                \
  do {                                                   \
    if (PDCompatActive) PDCompatVerifyInboxHeaderLater(content); \
  } while (0)
#else
#define PDCOMPAT_VERIFY_INBOX_HEADER(content) \
  do {                                    \
  } while (0)
#endif

#pragma mark - Launch tab

// 0 default, 1 Home, 2 Inbox, 3 Chat, 4 You.
static void PDTryApplyLaunchTab(UITabBarController *tbc) {
  if (!tbc || !gInitialFeedLoaded || gLaunchTabConsumed) return;
  gLaunchTabConsumed = YES;
  if (gLaunchTab <= 0 || gLaunchTab > 4) return;

  if (gLaunchTab == 4) {
    SEL profileSel = NSSelectorFromString(@"switchToProfileTab");
    if ([tbc respondsToSelector:profileSel]) {
      ((void (*)(id, SEL))objc_msgSend)(tbc, profileSel);
      PDCOMPAT_ACTION(PDCompatLaunchTab, @"Opened on You");
      return;
    }
  }
  UIViewController *target = nil;
  if (gLaunchTab == 3)
    target = (gFakeChat && [tbc.viewControllers containsObject:gFakeChat])
                 ? gFakeChat
                 : PDFirstTab(tbc.viewControllers, PDIsInboxTab);
  else if (gLaunchTab == 2)
    target = (gFakeInbox && [tbc.viewControllers containsObject:gFakeInbox])
                 ? gFakeInbox
                 : PDFirstTab(tbc.viewControllers, PDIsInboxTab);
  if (!target && gLaunchTab != 1)
    PDCOMPAT_ANOMALY(PDCompatLaunchTab, @"Launch tab %ld not found, Home shown", (long)gLaunchTab);
  if (!target) target = PDFirstTab(tbc.viewControllers, PDIsHomeTab);
  if (target && target != tbc.selectedViewController) tbc.selectedViewController = target;
  if (target) PDCOMPAT_ACTION(PDCompatLaunchTab, @"Opened on %@", target.tabBarItem.title ?: @"a tab");
}

#pragma mark - Home refresh and pull to refresh

static void PDNoteHomeTabSelection(UITabBarController *tbc, UIViewController *vc) {
  if (!tbc || !vc || vc == tbc.selectedViewController) return;
  if (PDIsHomeTab(vc) && !PDIsHomeTab(tbc.selectedViewController)) gHomeReturnTime = CFAbsoluteTimeGetCurrent();
}

// Reloads fired within 2.5 s of switching back to Home are dropped.
static BOOL PDKeepHomeFeedWindowOpen(void) {
  if (!gKeepHomeFeed) return NO;
  UITabBarController *tbc = gMainTabBar;
  if (!tbc || !PDIsHomeTab(tbc.selectedViewController)) return NO;
  return CFAbsoluteTimeGetCurrent() - gHomeReturnTime < 2.5;
}

static BOOL PDIsHomeReselect(UITabBarController *tbc, UIViewController *vc) {
  if (!tbc || !vc || tbc.selectedViewController != vc) return NO;
  if (!PDTabIsAtRoot(vc) || !PDIsHomeTab(vc)) return NO;
  SEL visibleSel = NSSelectorFromString(@"isHomeFeedVisible");
  if ([tbc respondsToSelector:visibleSel]) return ((BOOL (*)(id, SEL))objc_msgSend)(tbc, visibleSel);
  if ([vc respondsToSelector:visibleSel]) return ((BOOL (*)(id, SEL))objc_msgSend)(vc, visibleSel);
  return YES;
}

static UIScrollView *PDScrollViewFor(id object) {
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
static BOOL PDIsUserPull(id sender) {
  UIScrollView *scroll = PDScrollViewFor(sender);
  if (!scroll) return NO;
  CGFloat pull = -(scroll.contentOffset.y + scroll.adjustedContentInset.top);
  UIGestureRecognizerState state = scroll.panGestureRecognizer.state;
  if ((scroll.isDragging || scroll.isTracking) && pull > 8.0) return YES;
  if ((state == UIGestureRecognizerStateBegan || state == UIGestureRecognizerStateChanged) && pull > 8.0) return YES;
  return state == UIGestureRecognizerStateEnded && pull > 20.0;
}

static void PDEndRefreshing(id sender) {
  if ([sender respondsToSelector:@selector(endRefreshing)]) [sender endRefreshing];
}

static UIViewController *PDTopPresenter(id sender) {
  UIWindow *window = [sender isKindOfClass:UIView.class] ? ((UIView *)sender).window : nil;
  if (!window) window = gMainTabBar.view.window;
  UIViewController *top = window.rootViewController;
  while (top.presentedViewController && !top.presentedViewController.isBeingDismissed)
    top = top.presentedViewController;
  return top;
}

// Holds a user pull behind a confirmation; `proceed` replays the original call.
static BOOL PDInterceptPullToRefresh(id sender, void (^proceed)(void)) {
  if (!gConfirmPullToRefresh) return NO;
  if (CFAbsoluteTimeGetCurrent() - gProgrammaticRefreshTime < 1.0) return NO;
  if (!PDIsUserPull(sender)) return NO;

  PDEndRefreshing(sender);
  UIViewController *presenter = PDTopPresenter(sender);
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
  PDCOMPAT_ACTION(PDCompatConfirmPullRefresh, @"Prompt shown");
  return YES;
}

static void PDPerformHomeRefresh(UITabBarController *tbc, UIViewController *vc) {
  if (!PDIsHomeReselect(tbc, vc)) return;
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

static void PDPresentHomeRefreshPrompt(UITabBarController *tbc, UIViewController *vc) {
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
    PDPerformHomeRefresh(weakTab, weakVC);
  }]];
  [tbc presentViewController:alert animated:YES completion:nil];
  PDCOMPAT_ACTION(PDCompatConfirmHomeRefresh, @"Prompt shown");
}

#pragma mark - Refresh method interception

typedef NS_ENUM(NSInteger, PDRefreshHookKind) {
  PDRefreshHookPull,
  PDRefreshHookKeepFeed,
};

static BOOL PDShouldHoldRefresh(id receiver, id argument, PDRefreshHookKind kind, void (^proceed)(void)) {
  if (kind == PDRefreshHookKeepFeed) {
    BOOL hold = PDKeepHomeFeedWindowOpen() && !PDIsUserPull(receiver);
    PDCOMPAT_ACTION_IF(hold, PDCompatKeepHomeFeed, @"Reload held (%s)", object_getClassName(receiver));
    return hold;
  }
  id subject = (argument && PDScrollViewFor(argument)) ? argument : receiver;
  return PDInterceptPullToRefresh(subject, proceed);
}

// Wraps a void method taking 0-2 object arguments that the class itself
// implements; anything else is left untouched.
static void PDSwizzleRefreshMethod(Class cls, SEL sel, PDRefreshHookKind kind) {
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
      if (!PDShouldHoldRefresh(receiver, nil, kind, call)) call();
    });
  } else if (argc == 3) {
    replacement = imp_implementationWithBlock(^(id receiver, id a) {
      void (^call)(void) = ^{ ((void (*)(id, SEL, id))original)(receiver, sel, a); };
      if (!PDShouldHoldRefresh(receiver, a, kind, call)) call();
    });
  } else {
    replacement = imp_implementationWithBlock(^(id receiver, id a, id b) {
      void (^call)(void) = ^{ ((void (*)(id, SEL, id, id))original)(receiver, sel, a, b); };
      if (!PDShouldHoldRefresh(receiver, a, kind, call)) call();
    });
  }
  method_setImplementation(method, replacement);
}

static void PDInstallKeepFeedHooks(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    SEL fetch = NSSelectorFromString(@"fetchData");
    PDSwizzleRefreshMethod(NSClassFromString(@"FeedPresenter"), fetch, PDRefreshHookKeepFeed);
    Class bridged = NSClassFromString(@"_TtC20FeedKit_LegacyBridge25BridgedFeedViewController");
    PDSwizzleRefreshMethod(bridged, fetch, PDRefreshHookKeepFeed);
    PDSwizzleRefreshMethod(bridged, NSSelectorFromString(@"triggerRefreshWithReason:"), PDRefreshHookKeepFeed);
    PDSwizzleRefreshMethod(NSClassFromString(@"_TtC9Home_Impl24HomeScreenViewController"),
                           NSSelectorFromString(@"refreshActiveFeedWithReason:"), PDRefreshHookKeepFeed);
  });
}

// Reddit's refresh controls first, then every app class implementing a
// pull-to-refresh callback (scanned off the main thread).
static void PDInstallPullToRefreshHooks(void) {
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
        PDSwizzleRefreshMethod(cls, NSSelectorFromString(selector), PDRefreshHookPull);
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
        PDSwizzleRefreshMethod(all[i], didPull, PDRefreshHookPull);
        PDSwizzleRefreshMethod(all[i], valueChanged, PDRefreshHookPull);
        const char *name = class_getName(all[i]);
        if (strstr(name, "Listing") || strstr(name, "Feed") || strstr(name, "Refresh"))
          PDSwizzleRefreshMethod(all[i], listing, PDRefreshHookPull);
      }
      free(all);
    });
  });
}

static void PDInstallRefreshHooksIfNeeded(void) {
  if (gKeepHomeFeed) PDInstallKeepFeedHooks();
  if (gConfirmPullToRefresh) PDInstallPullToRefreshHooks();
}

#pragma mark - Tab bar minimizing

// Reddit asks iOS to minimize its tab bar on scroll (setTabBarMinimizeBehavior:, measured in
// Reddit 2026.38). With Compact tab bar off, every request becomes "never" (raw value 1);
// Reddit's last request is kept so the option can be turned off again.
static const NSInteger kPDMinimizeNever = 1;
static NSInteger gRedditMinimizeBehavior = -1;
static BOOL gApplyingMinimize;

static void PDApplyTabBarMinimize(void) {
  UITabBarController *tbc = gMainTabBar;
  SEL setter = NSSelectorFromString(@"setTabBarMinimizeBehavior:");
  if (![tbc respondsToSelector:setter]) return;
  NSInteger behavior = gKeepTabBarExpanded ? kPDMinimizeNever : gRedditMinimizeBehavior;
  if (behavior < 0) return;
  gApplyingMinimize = YES;
  ((void (*)(id, SEL, NSInteger))objc_msgSend)(tbc, setter, behavior);
  gApplyingMinimize = NO;
}

static void PDTabsPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                               const void *object, CFDictionaryRef userInfo) {
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL wasGames = gHideGamesTab;
    BOOL wasChat = gChatTabEnabled;
    PDLoadTabPrefs();
    PDInstallRefreshHooksIfNeeded();
    PDApplyTabBarMinimize();
    UITabBarController *tbc = gMainTabBar;
    if (tbc && gOriginalTabs.count && (wasGames != gHideGamesTab || wasChat != gChatTabEnabled))
      [tbc setViewControllers:gOriginalTabs animated:NO];
  });
}

#pragma mark - Hooks

%hook _TtC10MainTabBar24MainTabBarControllerImpl
- (void)viewDidLoad {
  %orig;
  gMainTabBar = self;
  PDInstallRefreshHooksIfNeeded();
  PDApplyTabBarMinimize();
}

- (void)setTabBarMinimizeBehavior:(NSInteger)behavior {
  if (!gApplyingMinimize) {
    gRedditMinimizeBehavior = behavior;
    if (gKeepTabBarExpanded && behavior != kPDMinimizeNever) {
      PDCOMPAT_ACTION(PDCompatKeepTabBar, @"Minimize behavior %ld kept at never", (long)behavior);
      behavior = kPDMinimizeNever;
    }
  }
  %orig(behavior);
}

- (void)viewDidAppear:(BOOL)animated {
  %orig;
  gMainTabBar = self;
  PDTryApplyLaunchTab(self);
}

- (void)initialFeedDidLoad {
  %orig;
  gInitialFeedLoaded = YES;
  PDTryApplyLaunchTab(self);
}

// A deeplink or notification launch keeps its own destination.
- (void *)showViewControllerForDeeplink:(id)deeplink animated:(BOOL)animated {
  if (deeplink) gLaunchTabConsumed = YES;
  return %orig;
}

- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated {
  gMainTabBar = self;
  UIViewController *previous = self.selectedViewController;
  NSArray *real = PDNormalizeToReal(controllers);
  gOriginalTabs = [real copy];
  NSArray *visible = PDVisibleTabs(real);
  if (gChatTabEnabled) visible = PDInstallChatTabs(visible);
  %orig(visible, animated);
  if (previous && [visible containsObject:previous] && self.selectedViewController != previous)
    self.selectedViewController = previous;
  PDTryApplyLaunchTab(self);
}

- (void)setSelectedViewController:(UIViewController *)vc {
  PDNoteHomeTabSelection(self, vc);
  %orig;
}

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)vc {
  PDNoteHomeTabSelection(self, vc);
  // Reddit refuses tabs it did not build, so the split tabs are selected directly.
  if (vc && (vc == gFakeInbox || vc == gFakeChat)) {
    UITabBarController *tbc = self;
    [UIView performWithoutAnimation:^{
      tbc.selectedViewController = vc;
    }];
    return NO;
  }
  if (gHomeRefreshAllowOnce) return %orig;
  if (gConfirmHomeRefresh && PDIsHomeReselect(self, vc)) {
    UITabBarController *tbc = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      PDPresentHomeRefreshPrompt(tbc, vc);
    });
    return NO;
  }
  return %orig;
}
%end

// Reddit's own account switcher on a long press of You; the option lets it through or blocks it.
%hook _TtC30MainTabBar_ProfileTabItem_Impl29ProfileTabItemViewModelImplV2
- (void *)handleLongPress:(id)gesture {
  BOOL longPress = [gesture isKindOfClass:UILongPressGestureRecognizer.class];
  if (!gAllowProfileHold && longPress) return NULL;
  PDCOMPAT_ACTION_IF(longPress && ((UIGestureRecognizer *)gesture).state == UIGestureRecognizerStateBegan,
                     PDCompatHoldYou, @"Long press passed to Reddit");
  return %orig;
}
%end

%hook _TtC16MainTabBar_Inbox19InboxViewController
- (void)viewWillAppear:(BOOL)animated {
  %orig;
  PDApplyInboxHeader(self);
}

- (void)viewDidAppear:(BOOL)animated {
  %orig;
  PDApplyInboxHeader(self);
  PDCOMPAT_VERIFY_INBOX_HEADER(self);
}
%end

%hook UIRefreshControl
- (void)sendActionsForControlEvents:(UIControlEvents)events {
  if (!gReplayingRefresh && (events & UIControlEventValueChanged)) {
    __weak UIRefreshControl *weakSelf = self;
    BOOL held = PDInterceptPullToRefresh(self, ^{
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
  PDLoadTabPrefs();
  CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &kPDTabsObserver, PDTabsPrefsChanged,
                                  CFSTR(kPrimeDitPrefsNotification), NULL,
                                  CFNotificationSuspensionBehaviorCoalesce);
  %init;
}
