#import <Comment.h>
#import <Post.h>
#import "PDTFilterPrefs.h"
#import "PDTClasses.h"

// Reddit's post and comment models: awards and vote counts.
%group AwardsAndScores

%hook Post
- (NSArray *)awardingTotals {
    return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
    return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
    return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
    return globalPrefs.scores ? YES : %orig;
}
%end

%hook Comment
- (NSArray *)awardingTotals {
    return globalPrefs.awards ? nil : %orig;
}
- (NSUInteger)totalAwardsReceived {
    return globalPrefs.awards ? 0 : %orig;
}
- (BOOL)canAward {
    return globalPrefs.awards ? NO : %orig;
}
- (BOOL)isScoreHidden {
    return globalPrefs.scores ? YES : %orig;
}
%end

%end

%ctor {
    %init(AwardsAndScores, Comment = PDTCoreClass(@"Comment"), Post = PDTCoreClass(@"Post"));
}
