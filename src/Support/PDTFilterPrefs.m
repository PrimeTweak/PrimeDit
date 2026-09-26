#import "PDTFilterPrefs.h"
#import "PDTPreferences.h"

PrimeDitPrefs globalPrefs;

static void loadPreferences() {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    globalPrefs.promoted = PDTPrefBool(kPrimeDitPromoted, YES);
    globalPrefs.recommended = [defaults boolForKey:kPrimeDitRecommended];
    globalPrefs.nsfw = [defaults boolForKey:kPrimeDitNSFW];
    globalPrefs.awards = [defaults boolForKey:kPrimeDitAwards];
    globalPrefs.scores = [defaults boolForKey:kPrimeDitScores];
    globalPrefs.automod = [defaults boolForKey:kPrimeDitAutoCollapseAutoMod];
    globalPrefs.recommendationCarousels = [defaults boolForKey:kPrimeDitRecommendationCarousels];
    globalPrefs.extraFeedCards = [defaults boolForKey:kPrimeDitExtraFeedCards];
    globalPrefs.aiBoxes = [defaults boolForKey:kPrimeDitAIBoxes];
    globalPrefs.spoilers = [defaults boolForKey:kPrimeDitSpoilers];
    globalPrefs.hideVisitedPosts = [defaults boolForKey:kPrimeDitHideVisitedPosts];
    globalPrefs.removedComments = [defaults boolForKey:kPrimeDitRemovedComments];
    globalPrefs.keywordsEnabled = [defaults boolForKey:kPrimeDitKeywordsEnabled];
    globalPrefs.subredditsEnabled = [defaults boolForKey:kPrimeDitSubredditsEnabled];
    globalPrefs.mutedUsers = [defaults boolForKey:kPrimeDitMutedUsersEnabled];
}

static void prefsNotificationCallback(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                      const void *object, CFDictionaryRef userInfo) {
    loadPreferences();
}

void PDTStartFilterPrefs(void) {
    loadPreferences();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsNotificationCallback,
                                    CFSTR(kPrimeDitPrefsNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}
