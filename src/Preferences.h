#import <Foundation/Foundation.h>

// Posted by the settings pages after any change; every hook reloads its options.
#define kPrimeDitPrefsNotification "com.primetweak.primedit/prefsUpdated"

// A stored switch, or `fallback` when the option was never set.
static inline BOOL PDPrefBool(NSString *key, BOOL fallback) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:key] ? [defaults boolForKey:key] : fallback;
}

#define kPrimeDitPromoted @"kPrimeDitPromoted"
#define kPrimeDitRecommended @"kPrimeDitRecommended"
#define kPrimeDitNSFW @"kPrimeDitNSFW"
#define kPrimeDitAwards @"kPrimeDitAwards"
#define kPrimeDitScores @"kPrimeDitScores"
#define kPrimeDitAutoCollapseAutoMod @"kPrimeDitAutoCollapseAutoMod"

#define kPrimeDitRecommendationCarousels @"kPrimeDitRecommendationCarousels"
#define kPrimeDitExtraFeedCards @"kPrimeDitExtraFeedCards"
#define kPrimeDitAIBoxes @"kPrimeDitAIBoxes"

#define kPrimeDitSpoilers @"kPrimeDitSpoilers"
#define kPrimeDitHideVisitedPosts @"kPrimeDitHideVisitedPosts"
#define kPrimeDitRemovedComments @"kPrimeDitRemovedComments"
#define kPrimeDitKeywordsEnabled @"kPrimeDitKeywordsEnabled"
#define kPrimeDitKeywords @"kPrimeDitKeywords"
#define kPrimeDitSubredditsEnabled @"kPrimeDitSubredditsEnabled"
#define kPrimeDitSubreddits @"kPrimeDitSubreddits"
#define kPrimeDitMutedUsersEnabled @"kPrimeDitMutedUsersEnabled"
#define kPrimeDitMutedUsers @"kPrimeDitMutedUsers"

#define kPrimeDitHideNags @"kPrimeDitHideNags"
#define kPrimeDitThreadLinesEnabled @"kPrimeDitThreadLinesEnabled"
#define kPrimeDitThreadRainbowMode @"kPrimeDitThreadRainbowMode"
#define kPrimeDitThreadDepthCycling @"kPrimeDitThreadDepthCycling"
#define kPrimeDitThreadLineThickness @"kPrimeDitThreadLineThickness"
#define kPrimeDitThreadThemeIndex @"kPrimeDitThreadThemeIndex"
#define kPrimeDitLeftMenuHidden @"kPrimeDitLeftMenuHidden"
#define kPrimeDitLeftMenuSections @"kPrimeDitLeftMenuSections"

#define kPrimeDitGamesTabDisabled @"kPrimeDitGamesTabDisabled"
#define kPrimeDitLaunchTab @"kPrimeDitLaunchTab"
#define kPrimeDitProfileAccountSwitcher @"kPrimeDitProfileAccountSwitcher"
#define kPrimeDitKeepTabBarExpanded @"kPrimeDitKeepTabBarExpanded"
#define kPrimeDitFlexExplorer @"kPrimeDitFlexExplorer"
#define kPrimeDitChatTabDisabled @"kPrimeDitChatTabDisabled"
#define kPrimeDitKeepFeedOnTabReturn @"kPrimeDitKeepFeedOnTabReturn"
#define kPrimeDitConfirmHomeRefresh @"kPrimeDitConfirmHomeRefresh"
#define kPrimeDitConfirmPullToRefresh @"kPrimeDitConfirmPullToRefresh"

#define kPrimeDitAutoClearCache @"kPrimeDitAutoClearCache"
#define kPrimeDitAutoClearLast @"kPrimeDitAutoClearLast"
