#import <Foundation/Foundation.h>
#import "DataPaths.h"

// Compatibility report engine: options record what they actually do, and the report
// checks that Reddit still has the classes, methods and data addresses they rely on.
// Everything but the option list compiles out in release.

typedef NS_ENUM(NSInteger, PDCompatOption) {
  PDCompatOptionNone = -1,
  PDCompatPromoted,
  PDCompatRecommended,
  PDCompatNSFW,
  PDCompatSpoilers,
  PDCompatCommunityRecs,
  PDCompatSuggestionCards,
  PDCompatAIAnswers,
  PDCompatVisitedPosts,
  PDCompatKeywords,
  PDCompatSubreddits,
  PDCompatMutedUsers,
  PDCompatAwards,
  PDCompatVoteCounts,
  PDCompatAutoMod,
  PDCompatRemovedComments,
  PDCompatChatTab,
  PDCompatGamesTab,
  PDCompatLaunchTab,
  PDCompatHoldYou,
  PDCompatKeepTabBar,
  PDCompatKeepHomeFeed,
  PDCompatConfirmHomeRefresh,
  PDCompatConfirmPullRefresh,
  PDCompatNags,
  PDCompatThreadLines,
  PDCompatLeftMenu,
  PDCompatBackup,
  PDCompatOptionCount,
};

#if PRIMEDIT_DEBUG

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PDCompatVerdict) {
  PDCompatVerdictOff,
  PDCompatVerdictNotSeen,
  PDCompatVerdictWorking,
  PDCompatVerdictBroken,
};

// clipboardText is what the row's button copies, under clipboardTitle; reference
// only goes into the copied report.
@interface PDCompatResult : NSObject
@property(nonatomic, copy) NSString *section;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic) PDCompatVerdict verdict;
@property(nonatomic, copy) NSString *clipboardText;
@property(nonatomic, copy) NSString *clipboardTitle;
@property(nonatomic, copy) NSString *reference;
@end

@interface PDCompatibilityReportViewController : UITableViewController
@end

FOUNDATION_EXPORT NSString *const kPDCompatDataSection;

FOUNDATION_EXPORT BOOL PDCompatActive;

FOUNDATION_EXPORT void PDCompatSetRecording(BOOL recording);
FOUNDATION_EXPORT void PDCompatReset(void);
FOUNDATION_EXPORT void PDCompatRecordAction(PDCompatOption option, NSString *detail);
FOUNDATION_EXPORT void PDCompatRecordAnomaly(PDCompatOption option, NSString *detail);
FOUNDATION_EXPORT void PDCompatRecordSentinel(PDCompatOption option, BOOL present);
FOUNDATION_EXPORT void PDCompatRecordResponse(NSString *operation);
FOUNDATION_EXPORT void PDCompatRecordFeedUnit(NSString *typeName, BOOL handled);
FOUNDATION_EXPORT NSArray<PDCompatResult *> *PDCompatResults(void);
FOUNDATION_EXPORT NSString *PDCompatSummary(NSArray<PDCompatResult *> *results);
FOUNDATION_EXPORT NSString *PDCompatRecordingText(void);
FOUNDATION_EXPORT NSString *PDCompatReportText(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *PDCompatThreadLinesOnScreen(void);
FOUNDATION_EXPORT NSString *PDCompatLeftMenuSeen(void);

#define PDCOMPAT_ACTION(option, ...)                                                          \
  do {                                                                                    \
    if (PDCompatActive) PDCompatRecordAction((option), [NSString stringWithFormat:__VA_ARGS__]); \
  } while (0)
#define PDCOMPAT_ACTION_IF(condition, option, ...)                                                           \
  do {                                                                                                   \
    if (PDCompatActive && (condition)) PDCompatRecordAction((option), [NSString stringWithFormat:__VA_ARGS__]); \
  } while (0)
#define PDCOMPAT_ANOMALY(option, ...)                                                          \
  do {                                                                                     \
    if (PDCompatActive) PDCompatRecordAnomaly((option), [NSString stringWithFormat:__VA_ARGS__]); \
  } while (0)
#define PDCOMPAT_SENTINEL(option, present)                        \
  do {                                                        \
    if (PDCompatActive) PDCompatRecordSentinel((option), (present)); \
  } while (0)
#define PDCOMPAT_RESPONSE(operation)                    \
  do {                                              \
    if (PDCompatActive) PDCompatRecordResponse(operation); \
  } while (0)

#else

#define PDCOMPAT_ACTION(option, ...) \
  do {                           \
  } while (0)
#define PDCOMPAT_ACTION_IF(condition, option, ...) \
  do {                                         \
  } while (0)
#define PDCOMPAT_ANOMALY(option, ...) \
  do {                            \
  } while (0)
#define PDCOMPAT_SENTINEL(option, present) \
  do {                                 \
  } while (0)
#define PDCOMPAT_RESPONSE(operation) \
  do {                           \
  } while (0)

#endif
