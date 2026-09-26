#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PDTCompatibility.h"

// Number of fleXD sources compiled in, set by the Makefile.
#ifndef PDT_FLEX_SOURCES
#define PDT_FLEX_SOURCES 0
#endif
#import "PDTPreferences.h"

#if PRIMEDIT_DEBUG

BOOL PDTCompatActive;

static NSString *const kPDTCompatRecordingKey = @"kPrimeDitCompatibilityRecording";
static const NSUInteger kPDTCompatMaxDistinct = 40;
static const CFAbsoluteTime kPDTCompatTrafficGrace = 120.0;
static const NSInteger kPDTCompatSentinelMinimum = 10;

static NSObject *gPDCompatLock;
static CFAbsoluteTime gPDCompatStart;
static NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSNumber *> *> *gPDCompatActions;
static NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSNumber *> *> *gPDCompatAnomalies;
static NSMutableDictionary<NSNumber *, NSNumber *> *gPDCompatSentinelSeen;
static NSMutableDictionary<NSNumber *, NSNumber *> *gPDCompatSentinelPresent;
static NSMutableDictionary<NSString *, NSNumber *> *gPDCompatResponses;
static NSMutableDictionary<NSString *, NSNumber *> *gPDCompatUnhandledUnits;

@implementation PDTCompatResult
@end

#pragma mark - Recording

// Distinct entries are capped so a long session cannot grow without bound.
static void PDTCompatBump(NSMutableDictionary<NSString *, NSNumber *> *counts, NSString *key) {
    if (!counts[key] && counts.count >= kPDTCompatMaxDistinct) key = @"other";
    counts[key] = @(counts[key].integerValue + 1);
}

static NSMutableDictionary<NSString *, NSNumber *> *PDTCompatCountsFor(
        NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSNumber *> *> *store, PDTCompatOption option) {
    NSMutableDictionary<NSString *, NSNumber *> *counts = store[@(option)];
    if (!counts) {
        counts = [NSMutableDictionary dictionary];
        store[@(option)] = counts;
    }
    return counts;
}

static void PDTCompatResetLocked(void) {
    gPDCompatStart = CFAbsoluteTimeGetCurrent();
    gPDCompatActions = [NSMutableDictionary dictionary];
    gPDCompatAnomalies = [NSMutableDictionary dictionary];
    gPDCompatSentinelSeen = [NSMutableDictionary dictionary];
    gPDCompatSentinelPresent = [NSMutableDictionary dictionary];
    gPDCompatResponses = [NSMutableDictionary dictionary];
    gPDCompatUnhandledUnits = [NSMutableDictionary dictionary];
}

static BOOL PDTCompatValidOption(PDTCompatOption option) {
    return option > PDTCompatOptionNone && option < PDTCompatOptionCount;
}

void PDTCompatReset(void) {
    @synchronized(gPDCompatLock) {
        PDTCompatResetLocked();
    }
}

void PDTCompatRecordAction(PDTCompatOption option, NSString *detail) {
    if (!PDTCompatValidOption(option)) return;
    @synchronized(gPDCompatLock) {
        PDTCompatBump(PDTCompatCountsFor(gPDCompatActions, option), detail.length ? detail : @"-");
    }
}

void PDTCompatRecordAnomaly(PDTCompatOption option, NSString *detail) {
    if (!PDTCompatValidOption(option)) return;
    @synchronized(gPDCompatLock) {
        PDTCompatBump(PDTCompatCountsFor(gPDCompatAnomalies, option), detail.length ? detail : @"-");
    }
}

void PDTCompatRecordSentinel(PDTCompatOption option, BOOL present) {
    if (!PDTCompatValidOption(option)) return;
    @synchronized(gPDCompatLock) {
        gPDCompatSentinelSeen[@(option)] = @(gPDCompatSentinelSeen[@(option)].integerValue + 1);
        if (present) gPDCompatSentinelPresent[@(option)] = @(gPDCompatSentinelPresent[@(option)].integerValue + 1);
    }
}

void PDTCompatRecordResponse(NSString *operation) {
    @synchronized(gPDCompatLock) {
        PDTCompatBump(gPDCompatResponses, operation.length ? operation : @"Unknown");
    }
}

void PDTCompatRecordFeedUnit(NSString *typeName, BOOL handled) {
    if (handled || !typeName.length) return;
    @synchronized(gPDCompatLock) {
        PDTCompatBump(gPDCompatUnhandledUnits, typeName);
    }
}

#pragma mark - Options

static NSString *PDTCompatTitle(PDTCompatOption option) {
    switch (option) {
        case PDTCompatPromoted: return @"Promoted";
        case PDTCompatRecommended: return @"Recommended";
        case PDTCompatNSFW: return @"NSFW";
        case PDTCompatSpoilers: return @"Spoilers";
        case PDTCompatCommunityRecs: return @"Community recommendations";
        case PDTCompatSuggestionCards: return @"Suggestion cards";
        case PDTCompatAIAnswers: return @"AI answers & summaries";
        case PDTCompatVisitedPosts: return @"Visited posts";
        case PDTCompatKeywords: return @"Keywords";
        case PDTCompatSubreddits: return @"Subreddits";
        case PDTCompatMutedUsers: return @"Muted users";
        case PDTCompatAwards: return @"Awards";
        case PDTCompatVoteCounts: return @"Vote counts";
        case PDTCompatAutoMod: return @"Collapse AutoMod comments";
        case PDTCompatRemovedComments: return @"Deleted & removed comments";
        case PDTCompatChatTab: return @"Chat tab";
        case PDTCompatGamesTab: return @"Games tab";
        case PDTCompatLaunchTab: return @"Launch tab";
        case PDTCompatHoldYou: return @"Account switcher";
        case PDTCompatKeepTabBar: return @"Compact tab bar";
        case PDTCompatKeepHomeFeed: return @"Remember Home position";
        case PDTCompatConfirmHomeRefresh: return @"Confirm Home refresh";
        case PDTCompatConfirmPullRefresh: return @"Confirm pull to refresh";
        case PDTCompatNags: return @"Pop-ups & nudges";
        case PDTCompatThreadLines: return @"Comment thread lines";
        case PDTCompatLeftMenu: return @"Left menu";
        case PDTCompatBackup: return @"Backup & reset";
        default: return @"";
    }
}

// Same sections as the settings page.
static NSString *PDTCompatSection(PDTCompatOption option) {
    switch (option) {
        case PDTCompatKeywords:
        case PDTCompatSubreddits:
        case PDTCompatMutedUsers: return @"Filter lists";
        case PDTCompatAwards:
        case PDTCompatVoteCounts: return @"Posts & comments";
        case PDTCompatRemovedComments:
        case PDTCompatAutoMod:
        case PDTCompatThreadLines: return @"Comments";
        case PDTCompatNags:
        case PDTCompatLeftMenu: return @"Interface";
        case PDTCompatChatTab:
        case PDTCompatGamesTab:
        case PDTCompatLaunchTab:
        case PDTCompatHoldYou:
        case PDTCompatKeepTabBar: return @"Tabs";
        case PDTCompatKeepHomeFeed:
        case PDTCompatConfirmHomeRefresh:
        case PDTCompatConfirmPullRefresh: return @"Refresh";
        case PDTCompatBackup: return @"Tools";
        default: return @"Feed";
    }
}

// Report order: the settings page, top to bottom.
static const PDTCompatOption kPDTCompatDisplayOrder[] = {
    PDTCompatPromoted, PDTCompatRecommended, PDTCompatCommunityRecs, PDTCompatSuggestionCards,
    PDTCompatAIAnswers, PDTCompatNSFW, PDTCompatSpoilers, PDTCompatVisitedPosts,
    PDTCompatKeywords, PDTCompatSubreddits, PDTCompatMutedUsers,
    PDTCompatAwards, PDTCompatVoteCounts,
    PDTCompatRemovedComments, PDTCompatAutoMod, PDTCompatThreadLines,
    PDTCompatNags, PDTCompatLeftMenu,
    PDTCompatChatTab, PDTCompatGamesTab, PDTCompatLaunchTab, PDTCompatHoldYou, PDTCompatKeepTabBar,
    PDTCompatKeepHomeFeed, PDTCompatConfirmHomeRefresh, PDTCompatConfirmPullRefresh,
    PDTCompatBackup,
};
_Static_assert((NSInteger)(sizeof(kPDTCompatDisplayOrder) / sizeof(kPDTCompatDisplayOrder[0])) == PDTCompatOptionCount,
               "every option appears once in the report order");

// What to do in Reddit so the option gets a chance to act.
static NSString *PDTCompatHint(PDTCompatOption option) {
    switch (option) {
        case PDTCompatPromoted: return @"Scroll Home: ads usually show up every few posts";
        case PDTCompatRecommended: return @"Scroll Home to meet a recommended post";
        case PDTCompatNSFW: return @"No NSFW post has come by yet";
        case PDTCompatSpoilers: return @"No spoiler has come by yet";
        case PDTCompatCommunityRecs: return @"No community carousel has come by yet";
        case PDTCompatSuggestionCards: return @"No suggestion card has come by yet";
        case PDTCompatAIAnswers: return @"Open a few posts to meet an AI box";
        case PDTCompatVisitedPosts: return @"Open a post, go back, then pull Home to refresh";
        case PDTCompatKeywords: return @"Nothing matched your keywords yet";
        case PDTCompatSubreddits: return @"Nothing from your subreddits came by yet";
        case PDTCompatMutedUsers: return @"Nothing from your muted users came by yet";
        case PDTCompatAwards: return @"Open a popular thread";
        case PDTCompatVoteCounts: return @"Open a popular thread";
        case PDTCompatAutoMod: return @"Open a thread from a large community";
        case PDTCompatRemovedComments: return @"Open a thread with deleted comments";
        case PDTCompatChatTab: return @"Tap Inbox and Chat";
        case PDTCompatGamesTab: return @"Relaunch Reddit to check the tab bar";
        case PDTCompatLaunchTab: return @"Relaunch Reddit to check";
        case PDTCompatHoldYou: return @"Long-press You";
        case PDTCompatKeepTabBar: return @"Scroll down in Home";
        case PDTCompatKeepHomeFeed: return @"Leave Home for a moment, then come back";
        case PDTCompatConfirmHomeRefresh: return @"Tap Home again while on Home";
        case PDTCompatConfirmPullRefresh: return @"Pull Home down";
        case PDTCompatNags: return @"No tip or prompt has shown up yet";
        case PDTCompatThreadLines: return @"Open the report from the stethoscope while a thread with replies is on screen";
        case PDTCompatLeftMenu: return @"Open the left menu";
        case PDTCompatBackup: return @"Export or import settings, or clear the cache";
        default: return @"";
    }
}

// The field a filter depends on alone; if Reddit stops sending it, the filter goes blind.
static NSString *PDTCompatSentinelField(PDTCompatOption option) {
    switch (option) {
        case PDTCompatNSFW: return @"isNsfw";
        case PDTCompatSpoilers: return @"isSpoiler";
        case PDTCompatVisitedPosts: return @"isVisited";
        case PDTCompatSubreddits: return @"subreddit.name";
        case PDTCompatMutedUsers: return @"authorInfo.displayName";
        case PDTCompatAutoMod: return @"authorInfo.id";
        default: return nil;
    }
}

static BOOL PDTCompatUsesFeedData(PDTCompatOption option) {
    return option > PDTCompatOptionNone && option <= PDTCompatRemovedComments;
}

static NSUInteger PDTCompatListCount(PDTCompatOption option) {
    NSString *key = option == PDTCompatKeywords     ? kPrimeDitKeywords
                    : option == PDTCompatSubreddits ? kPrimeDitSubreddits
                                               : kPrimeDitMutedUsers;
    return [NSUserDefaults.standardUserDefaults arrayForKey:key].count;
}

// Reads each setting exactly as the option itself does.
static BOOL PDTCompatEnabled(PDTCompatOption option) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    switch (option) {
        case PDTCompatPromoted: return PDTPrefBool(kPrimeDitPromoted, YES);
        case PDTCompatRecommended: return [defaults boolForKey:kPrimeDitRecommended];
        case PDTCompatNSFW: return [defaults boolForKey:kPrimeDitNSFW];
        case PDTCompatSpoilers: return [defaults boolForKey:kPrimeDitSpoilers];
        case PDTCompatCommunityRecs: return [defaults boolForKey:kPrimeDitRecommendationCarousels];
        case PDTCompatSuggestionCards: return [defaults boolForKey:kPrimeDitExtraFeedCards];
        case PDTCompatAIAnswers: return [defaults boolForKey:kPrimeDitAIBoxes];
        case PDTCompatVisitedPosts: return [defaults boolForKey:kPrimeDitHideVisitedPosts];
        case PDTCompatKeywords: return [defaults boolForKey:kPrimeDitKeywordsEnabled];
        case PDTCompatSubreddits: return [defaults boolForKey:kPrimeDitSubredditsEnabled];
        case PDTCompatMutedUsers: return [defaults boolForKey:kPrimeDitMutedUsersEnabled];
        case PDTCompatAwards: return [defaults boolForKey:kPrimeDitAwards];
        case PDTCompatVoteCounts: return [defaults boolForKey:kPrimeDitScores];
        case PDTCompatAutoMod: return [defaults boolForKey:kPrimeDitAutoCollapseAutoMod];
        case PDTCompatRemovedComments: return [defaults boolForKey:kPrimeDitRemovedComments];
        case PDTCompatChatTab: return !PDTPrefBool(kPrimeDitChatTabDisabled, YES);
        case PDTCompatGamesTab: return [defaults boolForKey:kPrimeDitGamesTabDisabled];
        case PDTCompatLaunchTab: return [defaults integerForKey:kPrimeDitLaunchTab] > 0;
        case PDTCompatHoldYou: return PDTPrefBool(kPrimeDitProfileAccountSwitcher, YES);
        case PDTCompatKeepTabBar: return PDTPrefBool(kPrimeDitKeepTabBarExpanded, NO);
        case PDTCompatKeepHomeFeed: return [defaults boolForKey:kPrimeDitKeepFeedOnTabReturn];
        case PDTCompatConfirmHomeRefresh: return [defaults boolForKey:kPrimeDitConfirmHomeRefresh];
        case PDTCompatConfirmPullRefresh: return [defaults boolForKey:kPrimeDitConfirmPullToRefresh];
        case PDTCompatNags: return [defaults boolForKey:kPrimeDitHideNags];
        case PDTCompatThreadLines: return [defaults boolForKey:kPrimeDitThreadLinesEnabled];
        case PDTCompatLeftMenu: return [defaults arrayForKey:kPrimeDitLeftMenuHidden].count > 0;
        case PDTCompatBackup: return YES;
        default: return NO;
    }
}

#pragma mark - Static checks

typedef struct {
    PDTCompatOption option;
    const char *className;
    const char *selectorName;
} PDTCompatRequirement;

// Reddit classes and methods the options hook or call (verified on Reddit 2026.38).
static const PDTCompatRequirement kPDTCompatRequirements[] = {
    {PDTCompatChatTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "tabBarController:shouldSelectViewController:"},
    {PDTCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "navigateToChatTab"},
    {PDTCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "navigateToActivityTab"},
    {PDTCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "segmentedControl"},
    {PDTCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "segmentWrapper"},
    {PDTCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "segmentWrapperHeightConstraint"},
    {PDTCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "pageViewController"},
    {PDTCompatChatTab, "_TtC16MainTabBar_Inbox19InboxViewController", "currentOnScreenScrollView"},
    {PDTCompatChatTab, "REDPageViewController", "setScrollEnabled:"},
    {PDTCompatGamesTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "setViewControllers:animated:"},
    {PDTCompatLaunchTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "initialFeedDidLoad"},
    {PDTCompatLaunchTab, "_TtC10MainTabBar24MainTabBarControllerImpl", "switchToProfileTab"},
    {PDTCompatHoldYou, "_TtC30MainTabBar_ProfileTabItem_Impl29ProfileTabItemViewModelImplV2", "handleLongPress:"},
    {PDTCompatKeepTabBar, "UITabBarController", "setTabBarMinimizeBehavior:"},
    {PDTCompatConfirmHomeRefresh, "_TtC10MainTabBar24MainTabBarControllerImpl",
     "tabBarController:shouldSelectViewController:"},
    {PDTCompatConfirmHomeRefresh, "_TtC10MainTabBar24MainTabBarControllerImpl", "isHomeFeedVisible"},
    {PDTCompatNags, "_TtC47Notifications_NotificationsPrompting_ObjCBridge36PushNotificationPromptingManagerObjC",
     "showUpvotePromptIfNeeded"},
    {PDTCompatLeftMenu, "_TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler",
     "tableView:viewForHeaderInSection:"},
    {PDTCompatLeftMenu, "_TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler",
     "tableView:heightForHeaderInSection:"},
    {PDTCompatLeftMenu, "_TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler",
     "tableView:willDisplayCell:forRowAtIndexPath:"},
    {PDTCompatLeftMenu, "_TtC15CommunityDrawer29CommunityDrawerViewController", "viewDidAppear:"},
};

// Remember Home position needs only one of these reload methods.
static const PDTCompatRequirement kPDTCompatKeepFeedTargets[] = {
    {PDTCompatKeepHomeFeed, "FeedPresenter", "fetchData"},
    {PDTCompatKeepHomeFeed, "_TtC20FeedKit_LegacyBridge25BridgedFeedViewController", "fetchData"},
    {PDTCompatKeepHomeFeed, "_TtC20FeedKit_LegacyBridge25BridgedFeedViewController", "triggerRefreshWithReason:"},
    {PDTCompatKeepHomeFeed, "_TtC9Home_Impl24HomeScreenViewController", "refreshActiveFeedWithReason:"},
};

static BOOL PDTCompatHasMethod(const char *className, const char *selectorName) {
    Class cls = objc_getClass(className);
    return cls && (!selectorName || [cls instancesRespondToSelector:sel_registerName(selectorName)]);
}

static NSString *PDTCompatReadableName(const char *className, const char *selectorName) {
    Class cls = objc_getClass(className);
    NSString *name = cls ? NSStringFromClass(cls) : @(className);
    return selectorName ? [NSString stringWithFormat:@"%@.%s", name, selectorName] : name;
}

static BOOL PDTCompatClassNameContains(const char *fragment) {
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
static BOOL PDTCompatThreadLineClassExists(void) {
    static BOOL exists;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exists = objc_getClass("_TtC63Components_CommentTreeItem_CommentTreeItemPresentation_"
                               "Internal30CommentTreeItemVerticalDivider") ||
                 PDTCompatClassNameContains("VerticalDivider") || PDTCompatClassNameContains("ThreadLine");
    });
    return exists;
}

static NSArray<NSString *> *PDTCompatMissing(PDTCompatOption option) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kPDTCompatRequirements) / sizeof(kPDTCompatRequirements[0]); i++) {
        PDTCompatRequirement requirement = kPDTCompatRequirements[i];
        if (requirement.option == option && !PDTCompatHasMethod(requirement.className, requirement.selectorName))
            [missing addObject:PDTCompatReadableName(requirement.className, requirement.selectorName)];
    }
    if (option == PDTCompatKeepHomeFeed) {
        BOOL any = NO;
        for (size_t i = 0; i < sizeof(kPDTCompatKeepFeedTargets) / sizeof(kPDTCompatKeepFeedTargets[0]) && !any; i++)
            any = PDTCompatHasMethod(kPDTCompatKeepFeedTargets[i].className, kPDTCompatKeepFeedTargets[i].selectorName);
        if (!any) [missing addObject:@"every Home reload method"];
    }
    if (option == PDTCompatThreadLines && !PDTCompatThreadLineClassExists())
        [missing addObject:@"the comment thread line view"];
    return missing;
}

#pragma mark - Report

static NSInteger PDTCompatTotal(NSDictionary<NSString *, NSNumber *> *counts) {
    NSInteger total = 0;
    for (NSNumber *value in counts.allValues) total += value.integerValue;
    return total;
}

// Most frequent entries first: "AdPost x10 . CellGroup x2".
static NSString *PDTCompatTop(NSDictionary<NSString *, NSNumber *> *counts, NSUInteger limit) {
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

static NSString *PDTCompatNotSeenDetail(PDTCompatOption option, BOOL recording, NSInteger responses, NSInteger seen,
                                        NSInteger present) {
    if (!recording) return @"Static checks passed \u00b7 turn recording on to see it act";
    if (option == PDTCompatGamesTab && seen > 0 && present == 0) return @"No Games tab in your tab bar";
    if (PDTCompatUsesFeedData(option) && responses == 0) return @"No Reddit feed data yet \u00b7 scroll Home";
    NSString *hint = PDTCompatHint(option);
    if (option == PDTCompatKeywords || option == PDTCompatSubreddits || option == PDTCompatMutedUsers) {
        NSUInteger count = PDTCompatListCount(option);
        return count ? [NSString stringWithFormat:@"%@ (%lu in your list)", hint, (unsigned long)count]
                     : @"Your list is empty";
    }
    return hint;
}

NSString *const kPDTCompatDataSection = @"Reddit data";

static PDTCompatResult *PDTCompatFeedDataResult(NSDictionary<NSString *, NSNumber *> *responses, BOOL recording,
                                                BOOL silent) {
    PDTCompatResult *result = [[PDTCompatResult alloc] init];
    result.section = kPDTCompatDataSection;
    result.title = @"Traffic";
    NSInteger total = PDTCompatTotal(responses);
    if (silent) {
        result.verdict = PDTCompatVerdictBroken;
        result.detail = @"No response intercepted for 2 minutes \u00b7 the network hook may be broken";
    } else if (total) {
        result.verdict = PDTCompatVerdictWorking;
        result.detail = [NSString stringWithFormat:@"%ld responses \u00b7 %@", (long)total, PDTCompatTop(responses, 4)];
    } else {
        result.verdict = PDTCompatVerdictNotSeen;
        result.detail = recording ? @"No response yet \u00b7 scroll Home" : @"Turn recording on to watch the traffic";
    }
    return result;
}

// One row per fixed JSON address of the filter, from the schema tracker.
static NSArray<PDTCompatResult *> *PDTCompatDataPathResults(void) {
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
    NSMutableArray<PDTCompatResult *> *results = [NSMutableArray array];
    for (NSDictionary *record in [[PDTDataPathTracker shared] snapshot]) {
        NSString *op = record[kPDTDataPathOperation];
        NSString *discovered = record[kPDTDataPathDiscovered];
        NSString *failedJSON = record[kPDTDataPathFailedJSON];
        NSInteger hits = [record[kPDTDataPathHits] integerValue];
        NSInteger misses = [record[kPDTDataPathMisses] integerValue];
        PDTCompatResult *result = [[PDTCompatResult alloc] init];
        result.section = kPDTCompatDataSection;
        result.title = titles[op] ?: op;
        NSString *moved = discovered.length ? [@" \u00b7 now " stringByAppendingString:discovered] : @"";
        result.reference = [NSString stringWithFormat:@"%@ \u00b7 expected %@%@", op, record[kPDTDataPathExpected], moved];
        if (![record[kPDTDataPathSeen] boolValue]) {
            result.verdict = PDTCompatVerdictNotSeen;
            result.detail = hints[op] ? [@"Not seen yet \u00b7 " stringByAppendingString:hints[op]] : @"Not seen yet";
        } else if ([record[kPDTDataPathLastResolved] boolValue]) {
            result.verdict = PDTCompatVerdictWorking;
            result.detail =
                    [NSString stringWithFormat:@"Address OK \u00b7 %ld response%@", (long)hits, hits == 1 ? @"" : @"s"];
            if (misses)
                result.detail = [result.detail stringByAppendingFormat:@" \u00b7 recovered after %ld miss%@", (long)misses,
                                                                       misses == 1 ? @"" : @"es"];
        } else {
            result.verdict = PDTCompatVerdictBroken;
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

NSArray<PDTCompatResult *> *PDTCompatResults(void) {
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

    BOOL recording = PDTCompatActive;
    NSInteger responseTotal = PDTCompatTotal(responses);
    BOOL feedSilent = recording && responseTotal == 0 && elapsed >= kPDTCompatTrafficGrace;
    NSMutableArray<PDTCompatResult *> *results = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kPDTCompatDisplayOrder) / sizeof(kPDTCompatDisplayOrder[0]); i++) {
        PDTCompatOption option = kPDTCompatDisplayOrder[i];
        NSDictionary<NSString *, NSNumber *> *done = actions[@(option)];
        NSDictionary<NSString *, NSNumber *> *wrong = anomalies[@(option)];
        NSInteger seenCount = seen[@(option)].integerValue;
        NSInteger presentCount = present[@(option)].integerValue;
        NSString *field = PDTCompatSentinelField(option);

        NSMutableArray<NSString *> *problems = [NSMutableArray array];
        NSArray<NSString *> *missing = PDTCompatMissing(option);
        if (missing.count)
            [problems addObject:[@"Missing in Reddit: " stringByAppendingString:[missing componentsJoinedByString:@", "]]];
        if (field && seenCount >= kPDTCompatSentinelMinimum && presentCount == 0)
            [problems addObject:[NSString stringWithFormat:@"Reddit no longer sends %@ (%ld items checked)", field,
                                                           (long)seenCount]];
        if (feedSilent && PDTCompatUsesFeedData(option))
            [problems addObject:@"No Reddit feed data intercepted for 2 minutes"];
        if (wrong.count) [problems addObject:PDTCompatTop(wrong, 2)];
        NSString *screen = nil;
        if (option == PDTCompatThreadLines) {
            NSDictionary<NSString *, id> *lines = PDTCompatThreadLinesOnScreen();
            NSInteger total = [lines[@"lines"] integerValue];
            NSInteger styled = [lines[@"styled"] integerValue];
            if (PDTCompatEnabled(option) && total && !styled) [problems addObject:@"Lines on screen were never styled"];
            if (PDTCompatEnabled(option) && styled && [lines[@"recolored"] integerValue] == styled)
                [problems addObject:@"Reddit recolors every line after it is styled"];
            screen = lines[@"text"];
        } else if (option == PDTCompatLeftMenu) {
            screen = PDTCompatLeftMenuSeen();
        }

        PDTCompatResult *result = [[PDTCompatResult alloc] init];
        result.section = PDTCompatSection(option);
        result.title = PDTCompatTitle(option);
        NSInteger doneCount = PDTCompatTotal(done);
        if (!PDTCompatEnabled(option)) {
            result.verdict = PDTCompatVerdictOff;
            NSString *failures = [problems componentsJoinedByString:@"; "];
            result.detail = problems.count ? [@"Off \u00b7 would fail: " stringByAppendingString:failures] : @"Off";
            if (doneCount)
                result.detail = [result.detail stringByAppendingFormat:@" \u00b7 while on: %ld\u00d7 \u00b7 %@",
                                                                       (long)doneCount, PDTCompatTop(done, 3)];
        } else if (problems.count) {
            result.verdict = PDTCompatVerdictBroken;
            result.detail = [problems componentsJoinedByString:@"\n"];
            if (doneCount)
                result.detail = [result.detail stringByAppendingFormat:@"\nDone: %ld\u00d7 \u00b7 %@", (long)doneCount,
                                                                       PDTCompatTop(done, 3)];
        } else if (doneCount) {
            result.verdict = PDTCompatVerdictWorking;
            result.detail = [NSString stringWithFormat:@"%ld\u00d7 \u00b7 %@", (long)doneCount, PDTCompatTop(done, 3)];
        } else {
            result.verdict = PDTCompatVerdictNotSeen;
            result.detail = PDTCompatNotSeenDetail(option, recording, responseTotal, seenCount, presentCount);
        }
        if (screen) result.detail = [result.detail stringByAppendingFormat:@"\n%@", screen];
        if (option == PDTCompatSuggestionCards && units.count)
            result.detail = [result.detail stringByAppendingFormat:@"\nNot filtered: %@", PDTCompatTop(units, 3)];
        [results addObject:result];
    }
    [results addObject:PDTCompatFeedDataResult(responses, recording, feedSilent)];
    [results addObjectsFromArray:PDTCompatDataPathResults()];
    return results;
}

NSString *PDTCompatSummary(NSArray<PDTCompatResult *> *results) {
    NSInteger counts[4] = {0, 0, 0, 0};
    for (PDTCompatResult *result in results)
        if (result.verdict >= PDTCompatVerdictOff && result.verdict <= PDTCompatVerdictBroken) counts[result.verdict]++;
    return [NSString stringWithFormat:@"%ld broken \u00b7 %ld working \u00b7 %ld not seen \u00b7 %ld off",
                                      (long)counts[PDTCompatVerdictBroken], (long)counts[PDTCompatVerdictWorking],
                                      (long)counts[PDTCompatVerdictNotSeen], (long)counts[PDTCompatVerdictOff]];
}

NSString *PDTCompatRecordingText(void) {
    if (!PDTCompatActive) return @"Recording off \u00b7 static checks only";
    CFAbsoluteTime elapsed = 0;
    @synchronized(gPDCompatLock) {
        elapsed = CFAbsoluteTimeGetCurrent() - gPDCompatStart;
    }
    NSInteger minutes = (NSInteger)(elapsed / 60.0);
    return minutes < 1 ? @"Recording \u00b7 started less than a minute ago"
                       : [NSString stringWithFormat:@"Recording for %ld min", (long)minutes];
}

static NSString *PDTCompatMark(PDTCompatVerdict verdict) {
    switch (verdict) {
        case PDTCompatVerdictWorking: return @"[OK]";
        case PDTCompatVerdictBroken: return @"[XX]";
        case PDTCompatVerdictNotSeen: return @"[..]";
        default: return @"[--]";
    }
}

NSString *PDTCompatReportText(void) {
    NSArray<PDTCompatResult *> *results = PDTCompatResults();
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSMutableString *text = [NSMutableString
            stringWithFormat:@"PrimeDit Compatibility \u00b7 Reddit %@ (%@) \u00b7 iOS %@ \u00b7 fleXD %d sources\n%@\n%@\n",
                             info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
                             UIDevice.currentDevice.systemVersion, (int)PDT_FLEX_SOURCES, PDTCompatRecordingText(),
                             PDTCompatSummary(results)];
    NSString *section = nil;
    for (PDTCompatResult *result in results) {
        if (![result.section isEqualToString:section]) {
            section = result.section;
            [text appendFormat:@"\n%@\n", section];
        }
        [text appendFormat:@"%@ %@ - %@%@\n", PDTCompatMark(result.verdict), result.title,
                           [result.detail stringByReplacingOccurrencesOfString:@"\n" withString:@" | "],
                           result.reference.length ? [@" | " stringByAppendingString:result.reference] : @""];
    }
    return text;
}

#pragma mark - Floating button

@interface PDTCompatButtonWindow : UIWindow
@end

@implementation PDTCompatButtonWindow

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

static PDTCompatButtonWindow *gPDCompatWindow;
static BOOL gPDCompatButtonScheduled;
static BOOL gPDCompatButtonReady;

@interface PDTCompatButton : NSObject
@end

@implementation PDTCompatButton

+ (UIWindowScene *)activeScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene *)scene;
    return nil;
}

// The stethoscope shows while recording and goes away when recording stops.
+ (void)update {
    if (!PDTCompatActive) {
        gPDCompatWindow.hidden = YES;
        gPDCompatWindow = nil;
        return;
    }
    if (!gPDCompatButtonReady || (gPDCompatWindow.windowScene && !gPDCompatWindow.hidden)) return;
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;
    PDTCompatButtonWindow *window = [[PDTCompatButtonWindow alloc] initWithWindowScene:scene];
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
    button.frame = CGRectMake(0, 0, 50.0, 50.0);
    button.center = CGPointMake(CGRectGetMaxX(bounds) - 44.0, CGRectGetMaxY(bounds) - 180.0);
    button.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.82];
    button.tintColor = UIColor.whiteColor;
    button.layer.cornerRadius = 25.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    UIImageSymbolConfiguration *symbol =
            [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightSemibold];
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
    PDTCompatibilityReportViewController *report =
            [[PDTCompatibilityReportViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:report];
    [root presentViewController:navigation animated:YES completion:nil];
}

@end

void PDTCompatSetRecording(BOOL recording) {
    [NSUserDefaults.standardUserDefaults setBool:recording forKey:kPDTCompatRecordingKey];
    if (recording && !PDTCompatActive) PDTCompatReset();
    PDTCompatActive = recording;
    gPDCompatButtonReady = YES;
    [PDTCompatButton update];
}

// Recording survives relaunches; the button appears 3 s after the first activation.
__attribute__((constructor)) static void PDTCompatInit(void) {
    gPDCompatLock = [[NSObject alloc] init];
    PDTCompatResetLocked();
    PDTCompatActive = [NSUserDefaults.standardUserDefaults boolForKey:kPDTCompatRecordingKey];
    void (^activate)(NSNotification *) = ^(NSNotification *note) {
        if (gPDCompatButtonReady) {
            [PDTCompatButton update];
            return;
        }
        if (gPDCompatButtonScheduled) return;
        gPDCompatButtonScheduled = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gPDCompatButtonReady = YES;
            [PDTCompatButton update];
        });
    };
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    NSOperationQueue *mainQueue = NSOperationQueue.mainQueue;
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:mainQueue usingBlock:activate];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:mainQueue usingBlock:activate];
}

#endif
