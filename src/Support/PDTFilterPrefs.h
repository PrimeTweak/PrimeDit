// The filter options, shared by the feed filter and the post and comment models.

#import <Foundation/Foundation.h>

typedef struct {
    BOOL promoted;
    BOOL recommended;
    BOOL nsfw;
    BOOL awards;
    BOOL scores;
    BOOL automod;
    BOOL recommendationCarousels;
    BOOL extraFeedCards;
    BOOL aiBoxes;
    BOOL spoilers;
    BOOL hideVisitedPosts;
    BOOL removedComments;
    BOOL keywordsEnabled;
    BOOL subredditsEnabled;
    BOOL mutedUsers;
} PrimeDitPrefs;

// Filter options, reloaded on every settings change notification.
extern PrimeDitPrefs globalPrefs;

// Loads the options and follows settings changes; called once at launch.
void PDTStartFilterPrefs(void);
