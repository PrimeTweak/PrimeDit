#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "PDTPreferences.h"
#import "PDTCompatibility.h"
#import "PDTIcons.h"
#import "PDTTabs.h"
#import "PDTRefresh.h"

// Tab bar options (Reddit 2026.38).
// The Chat tab splits Reddit's Inbox into two tabs that share one Inbox
// instance; a container re-parents it on appear and flips its inner segment.

@interface _TtC10MainTabBar24MainTabBarControllerImpl : UITabBarController
@end

@interface _TtC16MainTabBar_Inbox19InboxViewController : UIViewController
@end

static BOOL gChatTabEnabled;
static BOOL gHideGamesTab;
static BOOL gAllowProfileHold;
static BOOL gKeepTabBarExpanded;
static NSInteger gLaunchTab;

__weak UITabBarController *gMainTabBar;
static NSArray<UIViewController *> *gOriginalTabs;
static UIViewController *gFakeInbox;
static UIViewController *gFakeChat;
static __weak UIViewController *gRealInboxContent;
static BOOL gInitialFeedLoaded;
static BOOL gLaunchTabConsumed;
static char kPDTTabsObserver;

static const NSInteger kPDTInboxTabTag = 9998;
static const NSInteger kPDTChatTabTag = 9999;

static void PDTLoadTabPrefs(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    gChatTabEnabled = !PDTPrefBool(kPrimeDitChatTabDisabled, YES);
    gHideGamesTab = [defaults boolForKey:kPrimeDitGamesTabDisabled];
    gAllowProfileHold = PDTPrefBool(kPrimeDitProfileAccountSwitcher, YES);
    gKeepTabBarExpanded = [defaults boolForKey:kPrimeDitKeepTabBarExpanded];
    gLaunchTab = [defaults integerForKey:kPrimeDitLaunchTab];
}

#pragma mark - Tab identification

static BOOL PDTTabLabelMatches(UIViewController *vc, NSString *word, BOOL contains) {
    UITabBarItem *item = vc.tabBarItem;
    NSString *label = (item.accessibilityLabel.length ? item.accessibilityLabel : item.title).lowercaseString;
    if (!label.length) return NO;
    return contains ? [label containsString:word] : [label isEqualToString:word];
}

static BOOL PDTLooksLikeHomeTab(UIViewController *vc) {
    NSString *name = NSStringFromClass(vc.class);
    if (([name containsString:@"Home_Impl"] && [name containsString:@"HomeScreen"]) ||
            [name containsString:@"InitialHomeFeedController"] || [name containsString:@"MainScreenHomeTab"])
        return YES;
    return PDTTabLabelMatches(vc, @"home", NO);
}

static BOOL PDTLooksLikeGamesTab(UIViewController *vc) {
    NSString *name = NSStringFromClass(vc.class);
    if ([name containsString:@"MainScreenGamesTab"] || [name containsString:@"GamesHub"]) return YES;
    if ([vc.tabBarItem.accessibilityIdentifier.lowercaseString containsString:@"game"]) return YES;
    return PDTTabLabelMatches(vc, @"game", YES);
}

static BOOL PDTLooksLikeInboxTab(UIViewController *vc) {
    if ([NSStringFromClass(vc.class) containsString:@"MainTabBar_Inbox"]) return YES;
    return PDTTabLabelMatches(vc, @"inbox", NO);
}

// A tab matches if it, its navigation root/top, or a child matches.
static BOOL PDTTabTreeMatches(UIViewController *vc, BOOL (*matcher)(UIViewController *), int depth) {
    if (!vc || depth > 4) return NO;
    if (matcher(vc)) return YES;
    if ([vc isKindOfClass:UINavigationController.class]) {
        UINavigationController *nav = (UINavigationController *)vc;
        return PDTTabTreeMatches(nav.topViewController, matcher, depth + 1) ||
               PDTTabTreeMatches(nav.viewControllers.firstObject, matcher, depth + 1);
    }
    for (UIViewController *child in vc.childViewControllers)
        if (PDTTabTreeMatches(child, matcher, depth + 1)) return YES;
    return NO;
}

BOOL PDTIsHomeTab(UIViewController *vc) {
    return PDTTabTreeMatches(vc, PDTLooksLikeHomeTab, 0);
}

static BOOL PDTIsGamesTab(UIViewController *vc) {
    return PDTTabTreeMatches(vc, PDTLooksLikeGamesTab, 0);
}

static BOOL PDTIsInboxTab(UIViewController *vc) {
    return PDTTabTreeMatches(vc, PDTLooksLikeInboxTab, 0);
}

static UIViewController *PDTFirstTab(NSArray<UIViewController *> *tabs, BOOL (*test)(UIViewController *)) {
    for (UIViewController *vc in tabs)
        if (test(vc)) return vc;
    return nil;
}

BOOL PDTTabIsAtRoot(UIViewController *vc) {
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

static NSArray<UIViewController *> *PDTVisibleTabs(NSArray<UIViewController *> *controllers) {
    if (!gHideGamesTab || controllers.count == 0) return controllers;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:controllers.count];
    for (UIViewController *vc in controllers)
        if (!PDTIsGamesTab(vc)) [kept addObject:vc];
    PDTCOMPAT_SENTINEL(PDTCompatGamesTab, kept.count < controllers.count);
    PDTCOMPAT_ACTION_IF(kept.count < controllers.count, PDTCompatGamesTab, @"Games tab removed");
    return kept.count ? kept : controllers;
}

#pragma mark - Inbox content / navigation

// Matched by class identity: NSStringFromClass returns "Module.Class" for Swift
// classes, so the mangled name only serves as the runtime lookup key.
static BOOL PDTIsInboxContent(UIViewController *vc) {
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
static UIViewController *PDTInboxContent(UIViewController *vc, int depth) {
    if (!vc || depth > 4) return nil;
    if (PDTIsInboxContent(vc)) return vc;
    if ([vc isKindOfClass:UINavigationController.class]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            UIViewController *found = PDTInboxContent(child, depth + 1);
            if (found) return found;
        }
        return nil;
    }
    for (UIViewController *child in vc.childViewControllers) {
        UIViewController *found = PDTInboxContent(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

// Calls one of Reddit's object getters, only when it really returns an object.
static id PDTGetObject(id target, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    if (![target respondsToSelector:sel]) return nil;
    const char *type = [target methodSignatureForSelector:sel].methodReturnType;
    return (type && type[0] == '@') ? ((id (*)(id, SEL))objc_msgSend)(target, sel) : nil;
}

// Index of the Inbox's inner segment (0 activity, 1 chat), or -1 without one.
static NSInteger PDTSegmentIndex(UIViewController *content) {
    id segment = PDTGetObject(content, @"segmentedControl");
    SEL indexSel = NSSelectorFromString(@"currentIndex");
    if (![segment respondsToSelector:indexSel]) return -1;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(segment, indexSel);
}

// Flips the Inbox's inner segment to activity (0) or chat (1); a
// just-built Inbox is loaded first so its segment exists before it is shown.
static void PDTNavigateInbox(UIViewController *content, NSInteger tag) {
    if (!content) return;
    [content loadViewIfNeeded];
    NSInteger index = PDTSegmentIndex(content);
    if (index < 0 || index == tag) return;
    SEL navSel = tag == 1 ? NSSelectorFromString(@"navigateToChatTab") : NSSelectorFromString(@"navigateToActivityTab");
    if (![content respondsToSelector:navSel]) return;
    [UIView performWithoutAnimation:^{ ((void (*)(id, SEL))objc_msgSend)(content, navSel); }];
}

#pragma mark - Container

// Hosts the shared Inbox as its child. Two of these (Inbox, Chat) exist; only
// the visible one holds the Inbox at any time, so containment moves on appear.
@interface PDTContainerViewController : UIViewController
@property(nonatomic, strong) UIViewController *inbox;  // the Inbox tab (a navigation controller)
@property(nonatomic) NSInteger targetTag;
- (instancetype)initWithInbox:(UIViewController *)inbox targetTag:(NSInteger)tag;
@end

@implementation PDTContainerViewController

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
    gRealInboxContent = PDTInboxContent(inbox, 0);
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
    PDTNavigateInbox(PDTInboxContent(self.inbox, 0), self.targetTag);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    UITabBarController *tbc = self.tabBarController ?: gMainTabBar;
    if (tbc && tbc.selectedViewController != self) return;
    [self embedInbox];
    PDTNavigateInbox(PDTInboxContent(self.inbox, 0), self.targetTag);
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

#pragma mark - Split tab badges

// Reddit's badge goes to its own Inbox tab, hidden while the tabs are split. The split tabs
// take their counts from BadgeCountsV2 instead (measured fields): notifications on Inbox,
// chat on Chat, the number when the style is NUMBERED, a dot for any other style.
static NSString *gSplitInboxBadge;
static NSString *gSplitChatBadge;

static NSString *PDTBadgeText(id indicator) {
    if (![indicator isKindOfClass:NSDictionary.class]) return nil;
    id count = indicator[@"count"];
    NSInteger value = [count isKindOfClass:NSNumber.class] ? [count integerValue] : 0;
    if (value <= 0) return nil;
    id style = indicator[@"style"];
    if ([style isKindOfClass:NSString.class] && ![style isEqualToString:@"NUMBERED"]) return @"";
    return value > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)value];
}

static void PDTShowSplitBadges(void) {
    gFakeInbox.tabBarItem.badgeValue = gSplitInboxBadge;
    gFakeChat.tabBarItem.badgeValue = gSplitChatBadge;
}

// Called by the network filter with BadgeCountsV2's data.badgeIndicators.
void PDTApplySplitTabBadges(id indicators) {
    if (![indicators isKindOfClass:NSDictionary.class]) return;
    NSString *inbox = PDTBadgeText(indicators[@"notificationInboxTab"]);
    NSString *chat = PDTBadgeText(indicators[@"chatInboxTab"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        gSplitInboxBadge = inbox;
        gSplitChatBadge = chat;
        PDTShowSplitBadges();
        PDTCOMPAT_ACTION_IF(inbox != nil, PDTCompatChatTab, @"Badge %@ shown on the Inbox tab", inbox);
        PDTCOMPAT_ACTION_IF(chat != nil, PDTCompatChatTab, @"Badge %@ shown on the Chat tab", chat);
    });
}

static void PDTConfigureFakeTabItems(PDTContainerViewController *fakeInbox, PDTContainerViewController *fakeChat,
                                     UIViewController *inboxNav) {
    UITabBarItem *original = inboxNav.tabBarItem;
    UITabBarItem *inboxItem = [[UITabBarItem alloc] initWithTitle:(original.title ?: @"Inbox")
                                                            image:original.image
                                                    selectedImage:original.selectedImage];
    inboxItem.tag = kPDTInboxTabTag;
    inboxItem.accessibilityIdentifier = @"redditTabBarInboxButton";
    fakeInbox.tabBarItem = inboxItem;

    UIImage *chatImage = PDTIconWithName(@"rpl3/chat") ?: PDTIconWithName(@"rpl3/message")
                                                   ?: [UIImage systemImageNamed:@"message"];
    UIImage *chatSelected = PDTIconWithName(@"rpl3/chat-fill") ?: chatImage;
    UITabBarItem *chatItem = [[UITabBarItem alloc] initWithTitle:@"Chat" image:chatImage selectedImage:chatSelected];
    chatItem.tag = kPDTChatTabTag;
    chatItem.accessibilityIdentifier = @"redditTabBarChatButton";
    fakeChat.tabBarItem = chatItem;
    PDTShowSplitBadges();
}

// viewIfLoaded leaves a never-shown Inbox unbuilt until its tab first appears.
static void PDTDetachInbox(UIViewController *inbox) {
    if (!inbox) return;
    [inbox willMoveToParentViewController:nil];
    [inbox.viewIfLoaded removeFromSuperview];
    [inbox removeFromParentViewController];
}

// Reddit builds the Inbox screen on first display, so the tab is also known by
// the identifier Reddit gives its Inbox tab-bar item.
static BOOL PDTIsInboxTabRoot(UIViewController *vc) {
    return [vc.tabBarItem.accessibilityIdentifier isEqualToString:@"reddit_tab_bar__inbox_button"] ||
           PDTInboxContent(vc, 0) != nil;
}

// Turns Reddit's Inbox tab into Inbox + Chat sharing one Inbox instance.
static NSArray *PDTInstallChatTabs(NSArray *tabs) {
    NSInteger inboxIndex = NSNotFound;
    UIViewController *inboxNav = nil;
    for (NSInteger i = 0; i < (NSInteger)tabs.count; i++) {
        if (PDTIsInboxTabRoot(tabs[i])) {
            inboxIndex = i;
            inboxNav = tabs[i];
            break;
        }
    }
    if (inboxIndex == NSNotFound) {
        PDTCOMPAT_ANOMALY(PDTCompatChatTab, @"Inbox tab not found among %lu tabs", (unsigned long)tabs.count);
        return tabs;
    }

    PDTContainerViewController *fakeInbox = [[PDTContainerViewController alloc] initWithInbox:inboxNav targetTag:0];
    PDTContainerViewController *fakeChat = [[PDTContainerViewController alloc] initWithInbox:inboxNav targetTag:1];
    PDTConfigureFakeTabItems(fakeInbox, fakeChat, inboxNav);
    gFakeInbox = fakeInbox;
    gFakeChat = fakeChat;
    gRealInboxContent = PDTInboxContent(inboxNav, 0);
    PDTDetachInbox(inboxNav);

    NSMutableArray *result = [tabs mutableCopy];
    result[inboxIndex] = fakeInbox;
    [result insertObject:fakeChat atIndex:inboxIndex + 1];
    PDTCOMPAT_ACTION(PDTCompatChatTab, @"Inbox split into Inbox and Chat");
    return result;
}

// Returns the real tab array without the split tabs and detaches the shared Inbox,
// so it can be shown or split again: rebuild, account switch or option change.
static NSArray *PDTNormalizeToReal(NSArray *controllers) {
    UIViewController *heldInbox = gFakeInbox ? [(PDTContainerViewController *)gFakeInbox inbox] : nil;
    if (heldInbox) PDTDetachInbox(heldInbox);
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

static char kPDTInboxHeaderKey;

static PDTContainerViewController *PDTContainerHolding(UIViewController *content) {
    for (UIViewController *vc = content.parentViewController; vc; vc = vc.parentViewController)
        if ([vc isKindOfClass:PDTContainerViewController.class]) return (PDTContainerViewController *)vc;
    return nil;
}

static NSString *const kPDTMarkReadIdentifier = @"reddit_chat__navigation_bar__mark_read_button";
static NSString *const kPDTMarkReadAction = @"tappedMarkAllAsRead";

// Reddit's "mark all as read" envelope, known by the identifier and action it
// carries on Reddit 2026.38, under any control event.
static BOOL PDTIsArchiveView(UIView *view) {
    if ([view.accessibilityIdentifier isEqualToString:kPDTMarkReadIdentifier]) return YES;
    if (![view isKindOfClass:UIControl.class]) return NO;
    UIControl *control = (UIControl *)view;
    UIControlEvents events = control.allControlEvents;
    for (id target in control.allTargets)
        for (NSUInteger bit = 0; bit < 32; bit++) {
            UIControlEvents event = (UIControlEvents)(1UL << bit);
            if ((events & event) &&
                    [[control actionsForTarget:target forControlEvent:event] containsObject:kPDTMarkReadAction])
                return YES;
        }
    return NO;
}

static UIView *PDTArchiveViewIn(UIView *view, int depth) {
    if (!view || depth > 4) return nil;
    if (PDTIsArchiveView(view)) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = PDTArchiveViewIn(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static NSArray<UIBarButtonItem *> *PDTTrailingItems(UINavigationItem *navigationItem) {
    NSMutableArray<UIBarButtonItem *> *items =
            [NSMutableArray arrayWithArray:navigationItem.rightBarButtonItems ?: @[]];
    for (UIBarButtonItemGroup *group in navigationItem.trailingItemGroups) {
        [items addObjectsFromArray:group.barButtonItems];
        if (group.representativeItem) [items addObject:group.representativeItem];
    }
    return items;
}

// A whole bar item goes to items; a button nested in a shared custom view to views.
static void PDTFindArchive(UINavigationItem *navigationItem, NSMutableArray<UIBarButtonItem *> *items,
                           NSMutableArray<UIView *> *views) {
    SEL action = NSSelectorFromString(kPDTMarkReadAction);
    for (UIBarButtonItem *item in PDTTrailingItems(navigationItem)) {
        UIView *view = PDTArchiveViewIn(item.customView, 0);
        if (item.action == action || [item.accessibilityIdentifier isEqualToString:kPDTMarkReadIdentifier] ||
                (view && view == item.customView)) {
            if (![items containsObject:item]) [items addObject:item];
        } else if (view && ![views containsObject:view]) {
            [views addObject:view];
        }
    }
}

static void PDTSetArchiveHidden(UINavigationItem *navigationItem, BOOL hidden) {
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    PDTFindArchive(navigationItem, items, views);
    for (UIBarButtonItem *item in items) item.hidden = hidden;
    for (UIView *view in views) view.hidden = hidden;
}

static NSNumber *PDTPagerScrolling(id pager) {
    SEL getter = NSSelectorFromString(@"scrollEnabled");
    if (![pager respondsToSelector:getter]) return nil;
    const char *type = [pager methodSignatureForSelector:getter].methodReturnType;
    if (!type || (type[0] != 'B' && type[0] != 'c')) return nil;
    return @(((BOOL (*)(id, SEL))objc_msgSend)(pager, getter));
}

static void PDTSetPagerScrolling(id pager, BOOL enabled) {
    SEL setter = NSSelectorFromString(@"setScrollEnabled:");
    if ([pager respondsToSelector:setter]) ((void (*)(id, SEL, BOOL))objc_msgSend)(pager, setter, enabled);
}

static char kPDTPageTopKey;

// With the segment bar hidden, the Inbox pages keep no top inset for it; each
// page's own value comes back when the split ends.
static void PDTSyncPageInsets(UIViewController *content, id pager, BOOL split) {
    UIViewController *pagerController = [pager isKindOfClass:UIViewController.class] ? pager : nil;
    NSMutableArray<UIViewController *> *pages =
            [NSMutableArray arrayWithArray:pagerController.childViewControllers ?: @[]];
    UIViewController *current = PDTGetObject(content, @"currentOnScreenViewController");
    if ([current isKindOfClass:UIViewController.class] && ![pages containsObject:current]) [pages addObject:current];
    for (UIViewController *page in pages) {
        NSNumber *original = objc_getAssociatedObject(page, &kPDTPageTopKey);
        UIEdgeInsets insets = page.additionalSafeAreaInsets;
        if (split) {
            if (insets.top < 0.5) continue;
            if (!original) objc_setAssociatedObject(page, &kPDTPageTopKey, @(insets.top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            insets.top = 0;
        } else {
            if (!original) continue;
            insets.top = original.doubleValue;
            objc_setAssociatedObject(page, &kPDTPageTopKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        page.additionalSafeAreaInsets = insets;
    }
}

static char kPDTListTopKey;
static char kPDTListNeededKey;
static char kPDTListObservedKey;
static NSHashTable<UIScrollView *> *gTrimmedLists;

static void PDTSetListTop(UIScrollView *scroll, CGFloat top) {
    BOOL atTop = scroll.contentOffset.y <= 0.5 - scroll.adjustedContentInset.top;
    UIEdgeInsets inset = scroll.contentInset;
    inset.top = top;
    scroll.contentInset = inset;
    if (atTop) scroll.contentOffset = CGPointMake(scroll.contentOffset.x, -scroll.adjustedContentInset.top);
}

// The Inbox page's list: Reddit's own getter when it answers (it answers nothing in Reddit
// 2026.38, measured), else the largest visible table or collection view in the page.
static UIScrollView *PDTFindInboxList(UIViewController *content) {
    UIScrollView *scroll = PDTGetObject(content, @"currentOnScreenScrollView");
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
@interface PDTListInsetKeeper : NSObject
@end

@implementation PDTListInsetKeeper
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (context != &kPDTListNeededKey) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    UIScrollView *scroll = object;
    NSNumber *needed = objc_getAssociatedObject(scroll, &kPDTListNeededKey);
    if (!gChatTabEnabled || !needed || scroll.refreshControl.isRefreshing) return;
    if (scroll.contentInset.top <= needed.doubleValue + 0.5) return;
    PDTSetListTop(scroll, needed.doubleValue);
    PDTCOMPAT_ACTION(PDTCompatChatTab, @"Inbox list: inset set again to %.0f pt", needed.doubleValue);
}
@end

static PDTListInsetKeeper *gListInsetKeeper;

// With the segment bar hidden, the Inbox list starts right under the header yet keeps a
// top inset (52 pt, measured) with nothing in it. Only what reaches below the header is
// kept, and the list stays watched; the inset comes back when the split ends.
static void PDTSyncListInset(UIViewController *content, BOOL split) {
    if (!split) {
        for (UIScrollView *scroll in gTrimmedLists.allObjects) {
            if (objc_getAssociatedObject(scroll, &kPDTListObservedKey))
                [scroll removeObserver:gListInsetKeeper forKeyPath:@"contentInset" context:&kPDTListNeededKey];
            objc_setAssociatedObject(scroll, &kPDTListObservedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(scroll, &kPDTListNeededKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            NSNumber *original = objc_getAssociatedObject(scroll, &kPDTListTopKey);
            if (original) PDTSetListTop(scroll, original.doubleValue);
            objc_setAssociatedObject(scroll, &kPDTListTopKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [gTrimmedLists removeAllObjects];
        return;
    }
    UIView *root = content.viewIfLoaded;
    UIScrollView *scroll = root.window ? PDTFindInboxList(content) : nil;
    if (!scroll) return;
    CGFloat header = [root convertPoint:CGPointMake(0, root.safeAreaInsets.top) toView:nil].y;
    CGFloat listTop = CGRectGetMinY([scroll.superview convertRect:scroll.frame toView:nil]);
    CGFloat needed = MAX(0.0, header - listTop);
    if (!gTrimmedLists) gTrimmedLists = [NSHashTable weakObjectsHashTable];
    [gTrimmedLists addObject:scroll];
    objc_setAssociatedObject(scroll, &kPDTListNeededKey, @(needed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(scroll, &kPDTListObservedKey)) {
        if (!gListInsetKeeper) gListInsetKeeper = [[PDTListInsetKeeper alloc] init];
        [scroll addObserver:gListInsetKeeper forKeyPath:@"contentInset" options:0 context:&kPDTListNeededKey];
        objc_setAssociatedObject(scroll, &kPDTListObservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat top = scroll.contentInset.top;
    if (top <= needed + 0.5) return;
    if (!objc_getAssociatedObject(scroll, &kPDTListTopKey))
        objc_setAssociatedObject(scroll, &kPDTListTopKey, @(top), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    PDTSetListTop(scroll, needed);
    PDTCOMPAT_ACTION(PDTCompatChatTab, @"Inbox list: top inset %.0f pt set to %.0f pt", top, needed);
}

static void PDTSetInboxTitle(UINavigationItem *navigationItem, NSString *title) {
    if (!title.length) return;
    navigationItem.title = title;
    if ([navigationItem.titleView isKindOfClass:UILabel.class]) ((UILabel *)navigationItem.titleView).text = title;
}

// The list can appear after the page does (found 0.8 s after appearance, measured), so the
// check runs on appearance and again a little later while the Inbox tab is shown.
static void PDTSyncListInsetSoon(UIViewController *content) {
    PDTSyncListInset(content, YES);
    __weak UIViewController *weakContent = content;
    for (NSNumber *delay in @[ @0.4, @0.8, @1.6 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strongContent = weakContent;
            PDTContainerViewController *container = gChatTabEnabled ? PDTContainerHolding(strongContent) : nil;
            if (container && container.targetTag == 0) PDTSyncListInset(strongContent, YES);
        });
    }
}

// Split mode header: no segment bar and no swiping to the other page, the mark-all-read
// envelope on the Inbox tab only, and "Chat" as the Chat tab's title. Reddit rebuilds its
// header on every appearance, so this runs after it each time and undoes itself otherwise.
static void PDTApplyInboxHeader(UIViewController *content) {
    PDTContainerViewController *container = gChatTabEnabled ? PDTContainerHolding(content) : nil;
    NSMutableDictionary *saved = objc_getAssociatedObject(content, &kPDTInboxHeaderKey);
    if (!container && !saved) return;
    UIView *wrapper = PDTGetObject(content, @"segmentWrapper");
    if (![wrapper isKindOfClass:UIView.class]) wrapper = nil;
    NSLayoutConstraint *height = PDTGetObject(content, @"segmentWrapperHeightConstraint");
    if (![height isKindOfClass:NSLayoutConstraint.class]) height = nil;
    id pager = PDTGetObject(content, @"pageViewController");
    UINavigationItem *navigationItem = content.navigationItem;

    if (!container) {
        if (height && saved[@"height"]) height.constant = [saved[@"height"] doubleValue];
        if (saved[@"scroll"]) PDTSetPagerScrolling(pager, [saved[@"scroll"] boolValue]);
        PDTSyncPageInsets(content, pager, NO);
        PDTSyncListInset(content, NO);
        PDTSetArchiveHidden(navigationItem, NO);
        PDTSetInboxTitle(navigationItem, saved[@"title"]);
        objc_setAssociatedObject(content, &kPDTInboxHeaderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (!saved) {
        saved = [NSMutableDictionary dictionary];
        if (height) saved[@"height"] = @(height.constant);
        NSNumber *scroll = PDTPagerScrolling(pager);
        if (scroll) saved[@"scroll"] = scroll;
        objc_setAssociatedObject(content, &kPDTInboxHeaderKey, saved, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *title = navigationItem.title;
    if (title.length && ![title isEqualToString:@"Chat"]) saved[@"title"] = title;

    wrapper.hidden = YES;
    height.constant = 0;
    PDTSetPagerScrolling(pager, NO);
    PDTSyncPageInsets(content, pager, YES);
    if (container.targetTag == 0) PDTSyncListInsetSoon(content);
    PDTSetArchiveHidden(navigationItem, container.targetTag == 1);
    PDTSetInboxTitle(navigationItem, container.targetTag == 1 ? @"Chat" : saved[@"title"]);
    [content.viewIfLoaded setNeedsLayout];
}

#if PRIMEDIT_DEBUG
// Compatibility check: controls on the header's right side with their actions, to
// locate a button that could not be found.
static void PDTCompatCollectControls(UIView *view, int depth, NSMutableArray<NSString *> *out) {
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
    for (UIView *subview in view.subviews) PDTCompatCollectControls(subview, depth + 1, out);
}

static NSString *PDTCompatDescribeTrailingItems(UINavigationItem *navigationItem) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (UIBarButtonItem *item in PDTTrailingItems(navigationItem)) {
        NSMutableArray<NSString *> *controls = [NSMutableArray array];
        PDTCompatCollectControls(item.customView, 0, controls);
        [parts addObject:[NSString stringWithFormat:@"[%@ %s %@]", item.action ? NSStringFromSelector(item.action) : @"-",
                                                     item.customView ? object_getClassName(item.customView) : "-",
                                                     [controls componentsJoinedByString:@" "]]];
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : @"no trailing items";
}

// Compatibility check: a gap of more than 22 pt between the header and the first Inbox row.
static NSString *PDTCompatListBand(UIViewController *content) {
    UIView *root = content.viewIfLoaded;
    if (!root.window) return nil;
    UIScrollView *scroll = PDTFindInboxList(content);
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
static void PDTCompatVerifyInboxHeader(UIViewController *content) {
    PDTContainerViewController *container = gChatTabEnabled ? PDTContainerHolding(content) : nil;
    if (!container) return;
    BOOL chat = container.targetTag == 1;
    UIView *wrapper = PDTGetObject(content, @"segmentWrapper");
    UINavigationItem *navigationItem = content.navigationItem;
    NSMutableArray<UIBarButtonItem *> *archiveItems = [NSMutableArray array];
    NSMutableArray<UIView *> *archiveViews = [NSMutableArray array];
    PDTFindArchive(navigationItem, archiveItems, archiveViews);
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    if (![wrapper isKindOfClass:UIView.class])
        [problems addObject:@"segment bar not found"];
    else if (!wrapper.hidden && wrapper.bounds.size.height > 0.5)
        [problems addObject:@"segment bar still shown"];
    if (!archiveItems.count && !archiveViews.count)
        [problems addObject:[@"mark-all-read button not found in " stringByAppendingString:
                                                                     PDTCompatDescribeTrailingItems(navigationItem)]];
    BOOL archiveShown = NO;
    for (UIBarButtonItem *item in archiveItems) archiveShown = archiveShown || !item.hidden;
    for (UIView *view in archiveViews) archiveShown = archiveShown || !view.hidden;
    if (chat && archiveShown) [problems addObject:@"mark-all-read button shown on the Chat tab"];
    if (!chat && !archiveShown && (archiveItems.count || archiveViews.count))
        [problems addObject:@"mark-all-read button hidden on the Inbox tab"];
    if ([PDTPagerScrolling(PDTGetObject(content, @"pageViewController")) boolValue])
        [problems addObject:@"swiping to the other page still on"];
    if (PDTSegmentIndex(content) != container.targetTag)
        [problems addObject:chat ? @"Notifications page shown" : @"Chat page shown"];
    if (chat && ![navigationItem.title isEqualToString:@"Chat"]) [problems addObject:@"title is not Chat"];
    UIViewController *page = PDTGetObject(content, @"currentOnScreenViewController");
    if ([page isKindOfClass:UIViewController.class] && page.additionalSafeAreaInsets.top > 1.0)
        [problems addObject:[NSString stringWithFormat:@"list pushed down %.0f pt", page.additionalSafeAreaInsets.top]];
    UIViewController *pager = PDTGetObject(content, @"pageViewController");
    UIView *pagerView = [pager isKindOfClass:UIViewController.class] ? pager.viewIfLoaded : nil;
    if ([wrapper isKindOfClass:UIView.class] && pagerView.window) {
        CGFloat gap = CGRectGetMinY([pagerView convertRect:pagerView.bounds toView:content.view]) -
                      CGRectGetMinY([wrapper convertRect:wrapper.bounds toView:content.view]);
        if (gap > 1.0) [problems addObject:[NSString stringWithFormat:@"%.0f pt empty band above the list", gap]];
    }
    if (chat && navigationItem.titleView && ![navigationItem.titleView isKindOfClass:UILabel.class])
        [problems addObject:@"title drawn by a custom view"];
    NSString *band = chat ? nil : PDTCompatListBand(content);
    if (band) [problems addObject:band];
    NSString *tab = chat ? @"Chat" : @"Inbox";
    if (problems.count)
        PDTCompatRecordAnomaly(PDTCompatChatTab,
                               [NSString stringWithFormat:@"%@ tab: %@", tab, [problems componentsJoinedByString:@", "]]);
    else
        PDTCompatRecordAction(PDTCompatChatTab, [NSString stringWithFormat:@"%@ tab shown with its own header", tab]);
}

// Runs once Reddit's own layout of the page has settled.
static void PDTCompatVerifyInboxHeaderLater(UIViewController *content) {
    __weak UIViewController *weakContent = content;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *strongContent = weakContent;
        if (strongContent.viewIfLoaded.window) PDTCompatVerifyInboxHeader(strongContent);
    });
}

#define PDTCOMPAT_VERIFY_INBOX_HEADER(content)                \
  do {                                                   \
    if (PDTCompatActive) PDTCompatVerifyInboxHeaderLater(content); \
  } while (0)
#else
#define PDTCOMPAT_VERIFY_INBOX_HEADER(content) \
  do {                                    \
  } while (0)
#endif

#pragma mark - Launch tab

// 0 default, 1 Home, 2 Inbox, 3 Chat, 4 You.
static void PDTTryApplyLaunchTab(UITabBarController *tbc) {
    if (!tbc || !gInitialFeedLoaded || gLaunchTabConsumed) return;
    gLaunchTabConsumed = YES;
    if (gLaunchTab <= 0 || gLaunchTab > 4) return;

    if (gLaunchTab == 4) {
        SEL profileSel = NSSelectorFromString(@"switchToProfileTab");
        if ([tbc respondsToSelector:profileSel]) {
            ((void (*)(id, SEL))objc_msgSend)(tbc, profileSel);
            PDTCOMPAT_ACTION(PDTCompatLaunchTab, @"Opened on You");
            return;
        }
    }
    UIViewController *target = nil;
    if (gLaunchTab == 3)
        target = (gFakeChat && [tbc.viewControllers containsObject:gFakeChat])
                   ? gFakeChat
                   : PDTFirstTab(tbc.viewControllers, PDTIsInboxTab);
    else if (gLaunchTab == 2)
        target = (gFakeInbox && [tbc.viewControllers containsObject:gFakeInbox])
                   ? gFakeInbox
                   : PDTFirstTab(tbc.viewControllers, PDTIsInboxTab);
    if (!target && gLaunchTab != 1)
        PDTCOMPAT_ANOMALY(PDTCompatLaunchTab, @"Launch tab %ld not found, Home shown", (long)gLaunchTab);
    if (!target) target = PDTFirstTab(tbc.viewControllers, PDTIsHomeTab);
    if (target && target != tbc.selectedViewController) tbc.selectedViewController = target;
    if (target) PDTCOMPAT_ACTION(PDTCompatLaunchTab, @"Opened on %@", target.tabBarItem.title ?: @"a tab");
}

#pragma mark - Tab bar minimizing

// Reddit asks iOS to minimize its tab bar on scroll (setTabBarMinimizeBehavior:, measured in
// Reddit 2026.38). With Compact tab bar off, every request becomes "never" (raw value 1);
// Reddit's last request is kept so the option can be turned off again.
static const NSInteger kPDTMinimizeNever = 1;
static NSInteger gRedditMinimizeBehavior = -1;
static BOOL gApplyingMinimize;

static void PDTApplyTabBarMinimize(void) {
    UITabBarController *tbc = gMainTabBar;
    SEL setter = NSSelectorFromString(@"setTabBarMinimizeBehavior:");
    if (![tbc respondsToSelector:setter]) return;
    NSInteger behavior = gKeepTabBarExpanded ? kPDTMinimizeNever : gRedditMinimizeBehavior;
    if (behavior < 0) return;
    gApplyingMinimize = YES;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(tbc, setter, behavior);
    gApplyingMinimize = NO;
}

static void PDTTabsPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL wasGames = gHideGamesTab;
        BOOL wasChat = gChatTabEnabled;
        PDTLoadTabPrefs();
        PDTApplyTabBarMinimize();
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
    PDTInstallRefreshHooksIfNeeded();
    PDTApplyTabBarMinimize();
}

- (void)setTabBarMinimizeBehavior:(NSInteger)behavior {
    if (!gApplyingMinimize) {
        gRedditMinimizeBehavior = behavior;
        if (gKeepTabBarExpanded && behavior != kPDTMinimizeNever) {
            PDTCOMPAT_ACTION(PDTCompatKeepTabBar, @"Minimize behavior %ld kept at never", (long)behavior);
            behavior = kPDTMinimizeNever;
        }
    }
    %orig(behavior);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gMainTabBar = self;
    PDTTryApplyLaunchTab(self);
}

- (void)initialFeedDidLoad {
    %orig;
    gInitialFeedLoaded = YES;
    PDTTryApplyLaunchTab(self);
}

// A deeplink or notification launch keeps its own destination.
- (void *)showViewControllerForDeeplink:(id)deeplink animated:(BOOL)animated {
    if (deeplink) gLaunchTabConsumed = YES;
    return %orig;
}

- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated {
    gMainTabBar = self;
    UIViewController *previous = self.selectedViewController;
    NSArray *real = PDTNormalizeToReal(controllers);
    gOriginalTabs = [real copy];
    NSArray *visible = PDTVisibleTabs(real);
    if (gChatTabEnabled) visible = PDTInstallChatTabs(visible);
    %orig(visible, animated);
    if (previous && [visible containsObject:previous] && self.selectedViewController != previous)
        self.selectedViewController = previous;
    PDTTryApplyLaunchTab(self);
}

- (void)setSelectedViewController:(UIViewController *)vc {
    PDTNoteHomeTabSelection(self, vc);
    %orig;
}

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)vc {
    PDTNoteHomeTabSelection(self, vc);
    // Reddit refuses tabs it did not build, so the split tabs are selected directly.
    if (vc && (vc == gFakeInbox || vc == gFakeChat)) {
        UITabBarController *tbc = self;
        [UIView performWithoutAnimation:^{
            tbc.selectedViewController = vc;
        }];
        return NO;
    }
    if (PDTHoldHomeReselect(self, vc)) return NO;
    return %orig;
}
%end

// Reddit's own account switcher on a long press of You; the option lets it through or blocks it.
%hook _TtC30MainTabBar_ProfileTabItem_Impl29ProfileTabItemViewModelImplV2
- (void *)handleLongPress:(id)gesture {
    BOOL longPress = [gesture isKindOfClass:UILongPressGestureRecognizer.class];
    if (!gAllowProfileHold && longPress) return NULL;
    PDTCOMPAT_ACTION_IF(longPress && ((UIGestureRecognizer *)gesture).state == UIGestureRecognizerStateBegan,
                        PDTCompatHoldYou, @"Long press passed to Reddit");
    return %orig;
}
%end

%hook _TtC16MainTabBar_Inbox19InboxViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    PDTApplyInboxHeader(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PDTApplyInboxHeader(self);
    PDTCOMPAT_VERIFY_INBOX_HEADER(self);
}
%end

%ctor {
    PDTLoadTabPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &kPDTTabsObserver, PDTTabsPrefsChanged,
                                    CFSTR(kPrimeDitPrefsNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    %init;
}
