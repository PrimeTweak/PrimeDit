#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Compatibility.h"
#import "Preferences.h"

#if PRIMEDIT_DEBUG

BOOL PDCompatActive;

static NSString *const kPDCompatRecordingKey = @"kPrimeDitCompatibilityRecording";
static const NSUInteger kPDCompatMaxDistinct = 40;
static const CFAbsoluteTime kPDCompatTrafficGrace = 120.0;
static const NSInteger kPDCompatSentinelMinimum = 10;

static NSObject *gPDCompatLock;
static CFAbsoluteTime gPDCompatStart;
static NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSNumber *> *> *gPDCompatActions;
static NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSNumber *> *> *gPDCompatAnomalies;
static NSMutableDictionary<NSNumber *, NSNumber *> *gPDCompatSentinelSeen;
static NSMutableDictionary<NSNumber *, NSNumber *> *gPDCompatSentinelPresent;
static NSMutableDictionary<NSString *, NSNumber *> *gPDCompatResponses;
static NSMutableDictionary<NSString *, NSNumber *> *gPDCompatUnhandledUnits;

@implementation PDCompatResult
@end

#pragma mark - Recording

// Distinct entries are capped so a long session cannot grow without bound.
static void PDCompatBump(NSMutableDictionary<NSString *, NSNumber *> *counts, NSString *key) {
  if (!counts[key] && counts.count >= kPDCompatMaxDistinct) key = @"other";
  counts[key] = @(counts[key].integerValue + 1);
}

static NSMutableDictionary<NSString *, NSNumber *> *PDCompatCountsFor(
    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSNumber *> *> *store, PDCompatOption option) {
  NSMutableDictionary<NSString *, NSNumber *> *counts = store[@(option)];
  if (!counts) {
    counts = [NSMutableDictionary dictionary];
    store[@(option)] = counts;
  }
  return counts;
}

static void PDCompatResetLocked(void) {
  gPDCompatStart = CFAbsoluteTimeGetCurrent();
  gPDCompatActions = [NSMutableDictionary dictionary];
  gPDCompatAnomalies = [NSMutableDictionary dictionary];
  gPDCompatSentinelSeen = [NSMutableDictionary dictionary];
  gPDCompatSentinelPresent = [NSMutableDictionary dictionary];
  gPDCompatResponses = [NSMutableDictionary dictionary];
  gPDCompatUnhandledUnits = [NSMutableDictionary dictionary];
}

static BOOL PDCompatValidOption(PDCompatOption option) {
  return option > PDCompatOptionNone && option < PDCompatOptionCount;
}

void PDCompatReset(void) {
  @synchronized(gPDCompatLock) {
    PDCompatResetLocked();
  }
}

void PDCompatRecordAction(PDCompatOption option, NSString *detail) {
  if (!PDCompatValidOption(option)) return;
  @synchronized(gPDCompatLock) {
    PDCompatBump(PDCompatCountsFor(gPDCompatActions, option), detail.length ? detail : @"-");
  }
}

void PDCompatRecordAnomaly(PDCompatOption option, NSString *detail) {
  if (!PDCompatValidOption(option)) return;
  @synchronized(gPDCompatLock) {
    PDCompatBump(PDCompatCountsFor(gPDCompatAnomalies, option), detail.length ? detail : @"-");
  }
}

void PDCompatRecordSentinel(PDCompatOption option, BOOL present) {
  if (!PDCompatValidOption(option)) return;
  @synchronized(gPDCompatLock) {
    gPDCompatSentinelSeen[@(option)] = @(gPDCompatSentinelSeen[@(option)].integerValue + 1);
    if (present) gPDCompatSentinelPresent[@(option)] = @(gPDCompatSentinelPresent[@(option)].integerValue + 1);
  }
}

void PDCompatRecordResponse(NSString *operation) {
  @synchronized(gPDCompatLock) {
    PDCompatBump(gPDCompatResponses, operation.length ? operation : @"Unknown");
  }
}

void PDCompatRecordFeedUnit(NSString *typeName, BOOL handled) {
  if (handled || !typeName.length) return;
  @synchronized(gPDCompatLock) {
    PDCompatBump(gPDCompatUnhandledUnits, typeName);
  }
}

#pragma mark - Options

static NSString *PDCompatTitle(PDCompatOption option) {
  switch (option) {
    case PDCompatPromoted: return @"Promoted";
    case PDCompatRecommended: return @"Recommended";
    case PDCompatNSFW: return @"NSFW";
    case PDCompatSpoilers: return @"Spoilers";
    case PDCompatCommunityRecs: return @"Community recommendations";
    case PDCompatSuggestionCards: return @"Suggestion cards";
    case PDCompatAIAnswers: return @"AI answers & summaries";
    case PDCompatVisitedPosts: return @"Visited posts";
    case PDCompatKeywords: return @"Keywords";
    case PDCompatSubreddits: return @"Subreddits";
    case PDCompatMutedUsers: return @"Muted users";
    case PDCompatAwards: return @"Awards";
    case PDCompatVoteCounts: return @"Vote counts";
    case PDCompatAutoMod: return @"Collapse AutoMod comments";
    case PDCompatRemovedComments: return @"Deleted & removed comments";
    case PDCompatChatTab: return @"Chat tab";
    case PDCompatGamesTab: return @"Games tab";
    case PDCompatLaunchTab: return @"Launch tab";
    case PDCompatHoldYou: return @"Account switcher";
    case PDCompatKeepTabBar: return @"Compact tab bar";
    case PDCompatKeepHomeFeed: return @"Remember Home position";
    case PDCompatConfirmHomeRefresh: return @"Confirm Home refresh";
    case PDCompatConfirmPullRefresh: return @"Confirm pull to refresh";
    case PDCompatNags: return @"Pop-ups & nudges";
    case PDCompatThreadLines: return @"Comment thread lines";
    case PDCompatLeftMenu: return @"Left menu";
    case PDCompatBackup: return @"Backup & reset";
    default: return @"";
  }
}

// Same sections as the settings page.
static NSString *PDCompatSection(PDCompatOption option) {
  switch (option) {
    case PDCompatKeywords:
    case PDCompatSubreddits:
    case PDCompatMutedUsers: return @"Filter lists";
    case PDCompatAwards:
    case PDCompatVoteCounts: return @"Posts & comments";
    case PDCompatRemovedComments:
    case PDCompatAutoMod:
    case PDCompatThreadLines: return @"Comments";
    case PDCompatNags:
    case PDCompatLeftMenu: return @"Interface";
    case PDCompatChatTab:
    case PDCompatGamesTab:
    case PDCompatLaunchTab:
    case PDCompatHoldYou:
    case PDCompatKeepTabBar: return @"Tabs";
    case PDCompatKeepHomeFeed:
    case PDCompatConfirmHomeRefresh:
    case PDCompatConfirmPullRefresh: return @"Refresh";
    case PDCompatBackup: return @"Tools";
    default: return @"Feed";
  }
}

// Report order: the settings page, top to bottom.
static const PDCompatOption kPDCompatDisplayOrder[] = {
    PDCompatPromoted, PDCompatRecommended, PDCompatCommunityRecs, PDCompatSuggestionCards,
    PDCompatAIAnswers, PDCompatNSFW, PDCompatSpoilers, PDCompatVisitedPosts,
    PDCompatKeywords, PDCompatSubreddits, PDCompatMutedUsers,
    PDCompatAwards, PDCompatVoteCounts,
    PDCompatRemovedComments, PDCompatAutoMod, PDCompatThreadLines,
    PDCompatNags, PDCompatLeftMenu,
    PDCompatChatTab, PDCompatGamesTab, PDCompatLaunchTab, PDCompatHoldYou, PDCompatKeepTabBar,
    PDCompatKeepHomeFeed, PDCompatConfirmHomeRefresh, PDCompatConfirmPullRefresh,
    PDCompatBackup,
};
_Static_assert((NSInteger)(sizeof(kPDCompatDisplayOrder) / sizeof(kPDCompatDisplayOrder[0])) == PDCompatOptionCount,
               "every option appears once in the report order");

// What to do in Reddit so the option gets a chance to act.
static NSString *PDCompatHint(PDCompatOption option) {
  switch (option) {
    case PDCompatPromoted: return @"Scroll Home: ads usually show up every few posts";
    case PDCompatRecommended: return @"Scroll Home to meet a recommended post";
    case PDCompatNSFW: return @"No NSFW post has come by yet";
    case PDCompatSpoilers: return @"No spoiler has come by yet";
    case PDCompatCommunityRecs: return @"No community carousel has come by yet";
    case PDCompatSuggestionCards: return @"No suggestion card has come by yet";
    case PDCompatAIAnswers: return @"Open a few posts to meet an AI box";
    case PDCompatVisitedPosts: return @"Open a post, go back, then pull Home to refresh";
    case PDCompatKeywords: return @"Nothing matched your keywords yet";
    case PDCompatSubreddits: return @"Nothing from your subreddits came by yet";
    case PDCompatMutedUsers: return @"Nothing from your muted users came by yet";
    case PDCompatAwards: return @"Open a popular thread";
    case PDCompatVoteCounts: return @"Open a popular thread";
    case PDCompatAutoMod: return @"Open a thread from a large community";
    case PDCompatRemovedComments: return @"Open a thread with deleted comments";
    case PDCompatChatTab: return @"Tap Inbox and Chat";
    case PDCompatGamesTab: return @"Relaunch Reddit to check the tab bar";
    case PDCompatLaunchTab: return @"Relaunch Reddit to check";
    case PDCompatHoldYou: return @"Long-press You";
    case PDCompatKeepTabBar: return @"Scroll down in Home";
    case PDCompatKeepHomeFeed: return @"Leave Home for a moment, then come back";
    case PDCompatConfirmHomeRefresh: return @"Tap Home again while on Home";
    case PDCompatConfirmPullRefresh: return @"Pull Home down";
    case PDCompatNags: return @"No tip or prompt has shown up yet";
    case PDCompatThreadLines: return @"Open the report from the stethoscope while a thread with replies is on screen";
    case PDCompatLeftMenu: return @"Open the left menu";
    case PDCompatBackup: return @"Export or import settings, or clear the cache";
    default: return @"";
  }
}

// The field a filter depends on alone; if Reddit stops sending it, the filter goes blind.
static NSString *PDCompatSentinelField(PDCompatOption option) {
  switch (option) {
    case PDCompatNSFW: return @"isNsfw";
    case PDCompatSpoilers: return @"isSpoiler";
    case PDCompatVisitedPosts: return @"isVisited";
    case PDCompatSubreddits: return @"subreddit.name";
    case PDCompatMutedUsers: return @"authorInfo.displayName";
    case PDCompatAutoMod: return @"authorInfo.id";
    default: return nil;
  }
}

static BOOL PDCompatUsesFeedData(PDCompatOption option) {
  return option > PDCompatOptionNone && option <= PDCompatRemovedComments;
}

static NSUInteger PDCompatListCount(PDCompatOption option) {
  NSString *key = option == PDCompatKeywords     ? kPrimeDitKeywords
                  : option == PDCompatSubreddits ? kPrimeDitSubreddits
                                             : kPrimeDitMutedUsers;
  return [NSUserDefaults.standardUserDefaults arrayForKey:key].count;
}

// Reads each setting exactly as the option itself does.
static BOOL PDCompatEnabled(PDCompatOption option) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  switch (option) {
    case PDCompatPromoted: return PDPrefBool(kPrimeDitPromoted, YES);
    case PDCompatRecommended: return [defaults boolForKey:kPrimeDitRecommended];
    case PDCompatNSFW: return [defaults boolForKey:kPrimeDitNSFW];
    case PDCompatSpoilers: return [defaults boolForKey:kPrimeDitSpoilers];
    case PDCompatCommunityRecs: return [defaults boolForKey:kPrimeDitRecommendationCarousels];
    case PDCompatSuggestionCards: return [defaults boolForKey:kPrimeDitExtraFeedCards];
    case PDCompatAIAnswers: return [defaults boolForKey:kPrimeDitAIBoxes];
    case PDCompatVisitedPosts: return [defaults boolForKey:kPrimeDitHideVisitedPosts];
    case PDCompatKeywords: return [defaults boolForKey:kPrimeDitKeywordsEnabled];
    case PDCompatSubreddits: return [defaults boolForKey:kPrimeDitSubredditsEnabled];
    case PDCompatMutedUsers: return [defaults boolForKey:kPrimeDitMutedUsersEnabled];
    case PDCompatAwards: return [defaults boolForKey:kPrimeDitAwards];
    case PDCompatVoteCounts: return [defaults boolForKey:kPrimeDitScores];
    case PDCompatAutoMod: return [defaults boolForKey:kPrimeDitAutoCollapseAutoMod];
    case PDCompatRemovedComments: return [defaults boolForKey:kPrimeDitRemovedComments];
    case PDCompatChatTab: return !PDPrefBool(kPrimeDitChatTabDisabled, YES);
    case PDCompatGamesTab: return [defaults boolForKey:kPrimeDitGamesTabDisabled];
    case PDCompatLaunchTab: return [defaults integerForKey:kPrimeDitLaunchTab] > 0;
    case PDCompatHoldYou: return PDPrefBool(kPrimeDitProfileAccountSwitcher, YES);
    case PDCompatKeepTabBar: return PDPrefBool(kPrimeDitKeepTabBarExpanded, NO);
    case PDCompatKeepHomeFeed: return [defaults boolForKey:kPrimeDitKeepFeedOnTabReturn];
    case PDCompatConfirmHomeRefresh: return [defaults boolForKey:kPrimeDitConfirmHomeRefresh];
    case PDCompatConfirmPullRefresh: return [defaults boolForKey:kPrimeDitConfirmPullToRefresh];
    case PDCompatNags: return [defaults boolForKey:kPrimeDitHideNags];
    case PDCompatThreadLines: return [defaults boolForKey:kPrimeDitThreadLinesEnabled];
    case PDCompatLeftMenu: return [defaults arrayForKey:kPrimeDitLeftMenuHidden].count > 0;
    case PDCompatBackup: return YES;
    default: return NO;
  }
}

#pragma mark - Static checks

typedef struct {
  PDCompatOption option;
  const char *className;
  const char *selectorName;
} PDCompatRequirement;

// Reddit classes and methods the options hook or call (verified on Reddit 2026.38).
static const PDCompatRequirement kPDCompatRequirements[] = {
    {PDCompatChatTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "tabBarController:shouldSelectViewController:"},
    {PDCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "navigateToChatTab"},
    {PDCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "navigateToActivityTab"},
    {PDCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "segmentedControl"},
    {PDCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "segmentWrapper"},
    {PDCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "segmentWrapperHeightConstraint"},
    {PDCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "pageViewController"},
    {PDCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "currentOnScreenScrollView"},
    {PDCompatChatTab, "REDPageViewController", "setScrollEnabled:"},
    {PDCompatGamesTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "setViewControllers:animated:"},
    {PDCompatLaunchTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "initialFeedDidLoad"},
    {PDCompatLaunchTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "switchToProfileTab"},
    {PDCompatHoldYou, "_TtC30MainTabBar_ProfileTabItem_Impl29ProfileTabItemViewModelImplV2", "handleLongPress:"},
    {PDCompatKeepTabBar, "UITabBarController", "setTabBarMinimizeBehavior:"},
    {PDCompatConfirmHomeRefresh, "_TtC10MainTabBar24MainTabBarControllerImpl",
     "tabBarController:shouldSelectViewController:"},
    {PDCompatConfirmHomeRefresh, "_TtC10MainTabBar24MainTabBarControllerImpl", "isHomeFeedVisible"},
    {PDCompatNags, "_TtC47Notifications_NotificationsPrompting_ObjCBridge36PushNotificationPromptingManagerObjC",
     "showUpvotePromptIfNeeded"},
    {PDCompatLeftMenu, "_TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler",
     "tableView:viewForHeaderInSection:"},
    {PDCompatLeftMenu, "_TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler",
     "tableView:heightForHeaderInSection:"},
    {PDCompatLeftMenu, "_TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler",
     "tableView:willDisplayCell:forRowAtIndexPath:"},
    {PDCompatLeftMenu, "_TtC15CommunityDrawer29CommunityDrawerViewController", "viewDidAppear:"},
};

// Remember Home position needs only one of these reload methods.
static const PDCompatRequirement kPDCompatKeepFeedTargets[] = {
    {PDCompatKeepHomeFeed, "FeedPresenter", "fetchData"},
    {PDCompatKeepHomeFeed, "_TtC20FeedKit_LegacyBridge25BridgedFeedViewController", "fetchData"},
    {PDCompatKeepHomeFeed, "_TtC20FeedKit_LegacyBridge25BridgedFeedViewController", "triggerRefreshWithReason:"},
    {PDCompatKeepHomeFeed, "_TtC9Home_Impl24HomeScreenViewController", "refreshActiveFeedWithReason:"},
};

static BOOL PDCompatHasMethod(const char *className, const char *selectorName) {
  Class cls = objc_getClass(className);
  return cls && (!selectorName || [cls instancesRespondToSelector:sel_registerName(selectorName)]);
}

static NSString *PDCompatReadableName(const char *className, const char *selectorName) {
  Class cls = objc_getClass(className);
  NSString *name = cls ? NSStringFromClass(cls) : @(className);
  return selectorName ? [NSString stringWithFormat:@"%@.%s", name, selectorName] : name;
}

static BOOL PDCompatClassNameContains(const char *fragment) {
  unsigned count = 0;
  Class __unsafe_unretained *classes = objc_copyClassList(&count);
  BOOL found = NO;
  for (unsigned i = 0; i < count && !found; i++) {
    const char *name = class_getName(classes[i]);
    found = name && strstr(name, fragment);
  }
  free(classes);
  return found;
}

// Thread lines match views by class-name fragment; the known class is looked
// up first so the full class scan only runs after Reddit renamed it.
static BOOL PDCompatThreadLineClassExists(void) {
  static BOOL exists;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    exists = objc_getClass("_TtC63Components_CommentTreeItem_CommentTreeItemPresentation_"
                           "Internal30CommentTreeItemVerticalDivider") ||
             PDCompatClassNameContains("VerticalDivider") || PDCompatClassNameContains("ThreadLine");
  });
  return exists;
}

static NSArray<NSString *> *PDCompatMissing(PDCompatOption option) {
  NSMutableArray<NSString *> *missing = [NSMutableArray array];
  for (size_t i = 0; i < sizeof(kPDCompatRequirements) / sizeof(kPDCompatRequirements[0]); i++) {
    PDCompatRequirement requirement = kPDCompatRequirements[i];
    if (requirement.option == option && !PDCompatHasMethod(requirement.className, requirement.selectorName))
      [missing addObject:PDCompatReadableName(requirement.className, requirement.selectorName)];
  }
  if (option == PDCompatKeepHomeFeed) {
    BOOL any = NO;
    for (size_t i = 0; i < sizeof(kPDCompatKeepFeedTargets) / sizeof(kPDCompatKeepFeedTargets[0]) && !any; i++)
      any = PDCompatHasMethod(kPDCompatKeepFeedTargets[i].className, kPDCompatKeepFeedTargets[i].selectorName);
    if (!any) [missing addObject:@"every Home reload method"];
  }
  if (option == PDCompatThreadLines && !PDCompatThreadLineClassExists())
    [missing addObject:@"the comment thread line view"];
  return missing;
}

#pragma mark - Report

static NSInteger PDCompatTotal(NSDictionary<NSString *, NSNumber *> *counts) {
  NSInteger total = 0;
  for (NSNumber *value in counts.allValues) total += value.integerValue;
  return total;
}

// Most frequent entries first: "AdPost x10 . CellGroup x2".
static NSString *PDCompatTop(NSDictionary<NSString *, NSNumber *> *counts, NSUInteger limit) {
  NSArray<NSString *> *keys = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
    return [b compare:a];
  }];
  NSMutableArray<NSString *> *parts = [NSMutableArray array];
  for (NSString *key in keys) {
    if (parts.count == limit) break;
    NSInteger count = counts[key].integerValue;
    [parts addObject:count > 1 ? [NSString stringWithFormat:@"%@ \u00d7%ld", key, (long)count] : key];
  }
  return [parts componentsJoinedByString:@" \u00b7 "];
}

static NSString *PDCompatNotSeenDetail(PDCompatOption option, BOOL recording, NSInteger responses, NSInteger seen,
                                       NSInteger present) {
  if (!recording) return @"Static checks passed \u00b7 turn recording on to see it act";
  if (option == PDCompatGamesTab && seen > 0 && present == 0) return @"No Games tab in your tab bar";
  if (PDCompatUsesFeedData(option) && responses == 0) return @"No Reddit feed data yet \u00b7 scroll Home";
  NSString *hint = PDCompatHint(option);
  if (option == PDCompatKeywords || option == PDCompatSubreddits || option == PDCompatMutedUsers) {
    NSUInteger count = PDCompatListCount(option);
    return count ? [NSString stringWithFormat:@"%@ (%lu in your list)", hint, (unsigned long)count]
                 : @"Your list is empty";
  }
  return hint;
}

NSString *const kPDCompatDataSection = @"Reddit data";

static PDCompatResult *PDCompatFeedDataResult(NSDictionary<NSString *, NSNumber *> *responses, BOOL recording,
                                              BOOL silent) {
  PDCompatResult *result = [[PDCompatResult alloc] init];
  result.section = kPDCompatDataSection;
  result.title = @"Traffic";
  NSInteger total = PDCompatTotal(responses);
  if (silent) {
    result.verdict = PDCompatVerdictBroken;
    result.detail = @"No response intercepted for 2 minutes \u00b7 the network hook may be broken";
  } else if (total) {
    result.verdict = PDCompatVerdictWorking;
    result.detail = [NSString stringWithFormat:@"%ld responses \u00b7 %@", (long)total, PDCompatTop(responses, 4)];
  } else {
    result.verdict = PDCompatVerdictNotSeen;
    result.detail = recording ? @"No response yet \u00b7 scroll Home" : @"Turn recording on to watch the traffic";
  }
  return result;
}

// One row per fixed JSON address of the filter, from the schema tracker.
static NSArray<PDCompatResult *> *PDCompatDataPathResults(void) {
  NSDictionary<NSString *, NSString *> *titles = @{
    @"HomeFeedSdui" : @"Home feed",
    @"PopularFeedSdui" : @"Popular feed",
    @"FeedPostDetailsByIds" : @"Posts in feed",
    @"PostInfoById" : @"Post and comments",
    @"PdpCommentsAds" : @"Post page ads",
  };
  NSDictionary<NSString *, NSString *> *hints = @{
    @"HomeFeedSdui" : @"open Home",
    @"PopularFeedSdui" : @"open Popular",
    @"PostInfoById" : @"open a post",
    @"PdpCommentsAds" : @"open a post",
  };
  NSMutableArray<PDCompatResult *> *results = [NSMutableArray array];
  for (NSDictionary *record in [[PDDataPathTracker shared] snapshot]) {
    NSString *op = record[kPDDataPathOperation];
    NSString *discovered = record[kPDDataPathDiscovered];
    NSString *failedJSON = record[kPDDataPathFailedJSON];
    NSInteger hits = [record[kPDDataPathHits] integerValue];
    NSInteger misses = [record[kPDDataPathMisses] integerValue];
    PDCompatResult *result = [[PDCompatResult alloc] init];
    result.section = kPDCompatDataSection;
    result.title = titles[op] ?: op;
    NSString *moved = discovered.length ? [@" \u00b7 now " stringByAppendingString:discovered] : @"";
    result.reference = [NSString stringWithFormat:@"%@ \u00b7 expected %@%@", op, record[kPDDataPathExpected], moved];
    if (![record[kPDDataPathSeen] boolValue]) {
      result.verdict = PDCompatVerdictNotSeen;
      result.detail = hints[op] ? [@"Not seen yet \u00b7 " stringByAppendingString:hints[op]] : @"Not seen yet";
    } else if ([record[kPDDataPathLastResolved] boolValue]) {
      result.verdict = PDCompatVerdictWorking;
      result.detail =
          [NSString stringWithFormat:@"Address OK \u00b7 %ld response%@", (long)hits, hits == 1 ? @"" : @"s"];
      if (misses)
        result.detail = [result.detail stringByAppendingFormat:@" \u00b7 recovered after %ld miss%@", (long)misses,
                                                               misses == 1 ? @"" : @"es"];
    } else {
      result.verdict = PDCompatVerdictBroken;
      if (discovered.length) {
        result.detail = @"Reddit moved this data \u00b7 still filtering";
        result.clipboardText = discovered;
        result.clipboardTitle = @"Copy address";
      } else {
        result.detail = @"Reddit moved this data \u00b7 new address not found";
        if (failedJSON.length) {
          result.clipboardText = failedJSON;
          result.clipboardTitle = @"Copy data";
        }
      }
    }
    [results addObject:result];
  }
  return results;
}

NSArray<PDCompatResult *> *PDCompatResults(void) {
  NSDictionary<NSNumber *, NSDictionary<NSString *, NSNumber *> *> *actions;
  NSDictionary<NSNumber *, NSDictionary<NSString *, NSNumber *> *> *anomalies;
  NSDictionary<NSNumber *, NSNumber *> *seen;
  NSDictionary<NSNumber *, NSNumber *> *present;
  NSDictionary<NSString *, NSNumber *> *responses;
  NSDictionary<NSString *, NSNumber *> *units;
  CFAbsoluteTime elapsed = 0;
  @synchronized(gPDCompatLock) {
    actions = [[NSDictionary alloc] initWithDictionary:gPDCompatActions copyItems:YES];
    anomalies = [[NSDictionary alloc] initWithDictionary:gPDCompatAnomalies copyItems:YES];
    seen = [gPDCompatSentinelSeen copy];
    present = [gPDCompatSentinelPresent copy];
    responses = [gPDCompatResponses copy];
    units = [gPDCompatUnhandledUnits copy];
    elapsed = CFAbsoluteTimeGetCurrent() - gPDCompatStart;
  }

  BOOL recording = PDCompatActive;
  NSInteger responseTotal = PDCompatTotal(responses);
  BOOL feedSilent = recording && responseTotal == 0 && elapsed >= kPDCompatTrafficGrace;
  NSMutableArray<PDCompatResult *> *results = [NSMutableArray array];
  for (size_t i = 0; i < sizeof(kPDCompatDisplayOrder) / sizeof(kPDCompatDisplayOrder[0]); i++) {
    PDCompatOption option = kPDCompatDisplayOrder[i];
    NSDictionary<NSString *, NSNumber *> *done = actions[@(option)];
    NSDictionary<NSString *, NSNumber *> *wrong = anomalies[@(option)];
    NSInteger seenCount = seen[@(option)].integerValue;
    NSInteger presentCount = present[@(option)].integerValue;
    NSString *field = PDCompatSentinelField(option);

    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    NSArray<NSString *> *missing = PDCompatMissing(option);
    if (missing.count)
      [problems addObject:[@"Missing in Reddit: " stringByAppendingString:[missing componentsJoinedByString:@", "]]];
    if (field && seenCount >= kPDCompatSentinelMinimum && presentCount == 0)
      [problems addObject:[NSString stringWithFormat:@"Reddit no longer sends %@ (%ld items checked)", field,
                                                     (long)seenCount]];
    if (feedSilent && PDCompatUsesFeedData(option))
      [problems addObject:@"No Reddit feed data intercepted for 2 minutes"];
    if (wrong.count) [problems addObject:PDCompatTop(wrong, 2)];
    NSString *screen = nil;
    if (option == PDCompatThreadLines) {
      NSDictionary<NSString *, id> *lines = PDCompatThreadLinesOnScreen();
      NSInteger total = [lines[@"lines"] integerValue];
      NSInteger styled = [lines[@"styled"] integerValue];
      if (PDCompatEnabled(option) && total && !styled) [problems addObject:@"Lines on screen were never styled"];
      if (PDCompatEnabled(option) && styled && [lines[@"recolored"] integerValue] == styled)
        [problems addObject:@"Reddit recolors every line after it is styled"];
      screen = lines[@"text"];
    } else if (option == PDCompatLeftMenu) {
      screen = PDCompatLeftMenuSeen();
    }

    PDCompatResult *result = [[PDCompatResult alloc] init];
    result.section = PDCompatSection(option);
    result.title = PDCompatTitle(option);
    NSInteger doneCount = PDCompatTotal(done);
    if (!PDCompatEnabled(option)) {
      result.verdict = PDCompatVerdictOff;
      NSString *failures = [problems componentsJoinedByString:@"; "];
      result.detail = problems.count ? [@"Off \u00b7 would fail: " stringByAppendingString:failures] : @"Off";
      if (doneCount)
        result.detail = [result.detail stringByAppendingFormat:@" \u00b7 while on: %ld\u00d7 \u00b7 %@",
                                                               (long)doneCount, PDCompatTop(done, 3)];
    } else if (problems.count) {
      result.verdict = PDCompatVerdictBroken;
      result.detail = [problems componentsJoinedByString:@"\n"];
      if (doneCount)
        result.detail = [result.detail stringByAppendingFormat:@"\nDone: %ld\u00d7 \u00b7 %@", (long)doneCount,
                                                               PDCompatTop(done, 3)];
    } else if (doneCount) {
      result.verdict = PDCompatVerdictWorking;
      result.detail = [NSString stringWithFormat:@"%ld\u00d7 \u00b7 %@", (long)doneCount, PDCompatTop(done, 3)];
    } else {
      result.verdict = PDCompatVerdictNotSeen;
      result.detail = PDCompatNotSeenDetail(option, recording, responseTotal, seenCount, presentCount);
    }
    if (screen) result.detail = [result.detail stringByAppendingFormat:@"\n%@", screen];
    if (option == PDCompatSuggestionCards && units.count)
      result.detail = [result.detail stringByAppendingFormat:@"\nNot filtered: %@", PDCompatTop(units, 3)];
    [results addObject:result];
  }
  [results addObject:PDCompatFeedDataResult(responses, recording, feedSilent)];
  [results addObjectsFromArray:PDCompatDataPathResults()];
  return results;
}

NSString *PDCompatSummary(NSArray<PDCompatResult *> *results) {
  NSInteger counts[4] = {0, 0, 0, 0};
  for (PDCompatResult *result in results)
    if (result.verdict >= PDCompatVerdictOff && result.verdict <= PDCompatVerdictBroken) counts[result.verdict]++;
  return [NSString stringWithFormat:@"%ld broken \u00b7 %ld working \u00b7 %ld not seen \u00b7 %ld off",
                                    (long)counts[PDCompatVerdictBroken], (long)counts[PDCompatVerdictWorking],
                                    (long)counts[PDCompatVerdictNotSeen], (long)counts[PDCompatVerdictOff]];
}

NSString *PDCompatRecordingText(void) {
  if (!PDCompatActive) return @"Recording off \u00b7 static checks only";
  CFAbsoluteTime elapsed = 0;
  @synchronized(gPDCompatLock) {
    elapsed = CFAbsoluteTimeGetCurrent() - gPDCompatStart;
  }
  NSInteger minutes = (NSInteger)(elapsed / 60.0);
  return minutes < 1 ? @"Recording \u00b7 started less than a minute ago"
                     : [NSString stringWithFormat:@"Recording for %ld min", (long)minutes];
}

static NSString *PDCompatMark(PDCompatVerdict verdict) {
  switch (verdict) {
    case PDCompatVerdictWorking: return @"[OK]";
    case PDCompatVerdictBroken: return @"[XX]";
    case PDCompatVerdictNotSeen: return @"[..]";
    default: return @"[--]";
  }
}

NSString *PDCompatReportText(void) {
  NSArray<PDCompatResult *> *results = PDCompatResults();
  NSDictionary *info = NSBundle.mainBundle.infoDictionary;
  NSMutableString *text = [NSMutableString
      stringWithFormat:@"PrimeDit Compatibility \u00b7 Reddit %@ (%@) \u00b7 iOS %@\n%@\n%@\n",
                       info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
                       UIDevice.currentDevice.systemVersion, PDCompatRecordingText(), PDCompatSummary(results)];
  NSString *section = nil;
  for (PDCompatResult *result in results) {
    if (![result.section isEqualToString:section]) {
      section = result.section;
      [text appendFormat:@"\n%@\n", section];
    }
    [text appendFormat:@"%@ %@ - %@%@\n", PDCompatMark(result.verdict), result.title,
                       [result.detail stringByReplacingOccurrencesOfString:@"\n" withString:@" | "],
                       result.reference.length ? [@" | " stringByAppendingString:result.reference] : @""];
  }
  return text;
}

#pragma mark - Floating button

@interface PDCompatButtonWindow : UIWindow
@end

@implementation PDCompatButtonWindow

// Only the button and the report take touches; everything else reaches Reddit.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *hit = [super hitTest:point withEvent:event];
  return (hit == self || hit == self.rootViewController.view) ? nil : hit;
}

- (BOOL)canBecomeKeyWindow {
  return NO;
}

- (BOOL)_canAffectStatusBarAppearance {
  return NO;
}

@end

static PDCompatButtonWindow *gPDCompatWindow;
static BOOL gPDCompatButtonScheduled;
static BOOL gPDCompatButtonReady;

@interface PDCompatButton : NSObject
@end

@implementation PDCompatButton

+ (UIWindowScene *)activeScene {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
      return (UIWindowScene *)scene;
  return nil;
}

// The stethoscope shows while recording and goes away when recording stops.
+ (void)update {
  if (!PDCompatActive) {
    gPDCompatWindow.hidden = YES;
    gPDCompatWindow = nil;
    return;
  }
  if (!gPDCompatButtonReady || (gPDCompatWindow.windowScene && !gPDCompatWindow.hidden)) return;
  UIWindowScene *scene = [self activeScene];
  if (!scene) return;
  PDCompatButtonWindow *window = [[PDCompatButtonWindow alloc] initWithWindowScene:scene];
  window.frame = scene.coordinateSpace.bounds;
  window.windowLevel = UIWindowLevelAlert + 100.0;
  window.backgroundColor = UIColor.clearColor;
  UIViewController *root = [[UIViewController alloc] init];
  root.view.backgroundColor = UIColor.clearColor;
  window.rootViewController = root;
  [root.view addSubview:[self makeButtonInBounds:window.bounds]];
  window.hidden = NO;
  gPDCompatWindow = window;
}

+ (UIButton *)makeButtonInBounds:(CGRect)bounds {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.frame = CGRectMake(0, 0, 48.0, 48.0);
  button.center = CGPointMake(CGRectGetMaxX(bounds) - 44.0, CGRectGetMaxY(bounds) - 180.0);
  button.backgroundColor = [UIColor.systemGreenColor colorWithAlphaComponent:0.92];
  button.tintColor = UIColor.whiteColor;
  button.layer.cornerRadius = 24.0;
  button.layer.shadowColor = UIColor.blackColor.CGColor;
  button.layer.shadowOpacity = 0.25f;
  button.layer.shadowRadius = 6.0;
  button.layer.shadowOffset = CGSizeMake(0, 2.0);
  UIImageSymbolConfiguration *symbol =
      [UIImageSymbolConfiguration configurationWithPointSize:20.0 weight:UIImageSymbolWeightSemibold];
  [button setImage:[UIImage systemImageNamed:@"stethoscope" withConfiguration:symbol] forState:UIControlStateNormal];
  button.accessibilityLabel = @"Compatibility report";
  [button addTarget:self action:@selector(showReport) forControlEvents:UIControlEventTouchUpInside];
  [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragButton:)]];
  return button;
}

+ (void)dragButton:(UIPanGestureRecognizer *)pan {
  UIView *button = pan.view;
  CGPoint delta = [pan translationInView:button.superview];
  CGRect limits = CGRectInset(button.superview.bounds, 28.0, 28.0);
  button.center = CGPointMake(MIN(MAX(button.center.x + delta.x, CGRectGetMinX(limits)), CGRectGetMaxX(limits)),
                              MIN(MAX(button.center.y + delta.y, CGRectGetMinY(limits)), CGRectGetMaxY(limits)));
  [pan setTranslation:CGPointZero inView:button.superview];
}

+ (void)showReport {
  UIViewController *root = gPDCompatWindow.rootViewController;
  if (!root || root.presentedViewController) return;
  PDCompatibilityReportViewController *report =
      [[PDCompatibilityReportViewController alloc] initWithStyle:UITableViewStyleGrouped];
  UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:report];
  [root presentViewController:navigation animated:YES completion:nil];
}

@end

void PDCompatSetRecording(BOOL recording) {
  [NSUserDefaults.standardUserDefaults setBool:recording forKey:kPDCompatRecordingKey];
  if (recording && !PDCompatActive) PDCompatReset();
  PDCompatActive = recording;
  gPDCompatButtonReady = YES;
  [PDCompatButton update];
}

// Recording survives relaunches; the button appears 3 s after the first activation.
__attribute__((constructor)) static void PDCompatInit(void) {
  gPDCompatLock = [[NSObject alloc] init];
  PDCompatResetLocked();
  PDCompatActive = [NSUserDefaults.standardUserDefaults boolForKey:kPDCompatRecordingKey];
  void (^activate)(NSNotification *) = ^(NSNotification *note) {
    if (gPDCompatButtonReady) {
      [PDCompatButton update];
      return;
    }
    if (gPDCompatButtonScheduled) return;
    gPDCompatButtonScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      gPDCompatButtonReady = YES;
      [PDCompatButton update];
    });
  };
  NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
  NSOperationQueue *mainQueue = NSOperationQueue.mainQueue;
  [center addObserverForName:UISceneDidActivateNotification object:nil queue:mainQueue usingBlock:activate];
  [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:mainQueue usingBlock:activate];
}

#endif
