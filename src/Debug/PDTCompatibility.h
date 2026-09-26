#import <Foundation/Foundation.h>
#import "PDTDataPaths.h"

// Compatibility report engine: options record what they actually do, and the report
// checks that Reddit still has the classes, methods and data addresses they rely on.
// Everything but the option list compiles out in release.

typedef NS_ENUM(NSInteger, PDTCompatOption) {
    PDTCompatOptionNone = -1,
    PDTCompatPromoted,
    PDTCompatRecommended,
    PDTCompatNSFW,
    PDTCompatSpoilers,
    PDTCompatCommunityRecs,
    PDTCompatSuggestionCards,
    PDTCompatAIAnswers,
    PDTCompatVisitedPosts,
    PDTCompatKeywords,
    PDTCompatSubreddits,
    PDTCompatMutedUsers,
    PDTCompatAwards,
    PDTCompatVoteCounts,
    PDTCompatAutoMod,
    PDTCompatRemovedComments,
    PDTCompatChatTab,
    PDTCompatGamesTab,
    PDTCompatLaunchTab,
    PDTCompatHoldYou,
    PDTCompatKeepTabBar,
    PDTCompatKeepHomeFeed,
    PDTCompatConfirmHomeRefresh,
    PDTCompatConfirmPullRefresh,
    PDTCompatNags,
    PDTCompatThreadLines,
    PDTCompatLeftMenu,
    PDTCompatBackup,
    PDTCompatOptionCount,
};

#if PRIMEDIT_DEBUG

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PDTCompatVerdict) {
    PDTCompatVerdictOff,
    PDTCompatVerdictNotSeen,
    PDTCompatVerdictWorking,
    PDTCompatVerdictBroken,
};

// clipboardText is what the row's button copies, under clipboardTitle; reference
// only goes into the copied report.
@interface PDTCompatResult : NSObject
@property(nonatomic, copy) NSString *section;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic) PDTCompatVerdict verdict;
@property(nonatomic, copy) NSString *clipboardText;
@property(nonatomic, copy) NSString *clipboardTitle;
@property(nonatomic, copy) NSString *reference;
@end

@interface PDTCompatibilityReportViewController : UITableViewController
@end

FOUNDATION_EXPORT NSString *const kPDTCompatDataSection;

FOUNDATION_EXPORT BOOL PDTCompatActive;

FOUNDATION_EXPORT void PDTCompatSetRecording(BOOL recording);
FOUNDATION_EXPORT void PDTCompatReset(void);
FOUNDATION_EXPORT void PDTCompatRecordAction(PDTCompatOption option, NSString *detail);
FOUNDATION_EXPORT void PDTCompatRecordAnomaly(PDTCompatOption option, NSString *detail);
FOUNDATION_EXPORT void PDTCompatRecordSentinel(PDTCompatOption option, BOOL present);
FOUNDATION_EXPORT void PDTCompatRecordResponse(NSString *operation);
FOUNDATION_EXPORT void PDTCompatRecordFeedUnit(NSString *typeName, BOOL handled);
FOUNDATION_EXPORT NSArray<PDTCompatResult *> *PDTCompatResults(void);
FOUNDATION_EXPORT NSString *PDTCompatSummary(NSArray<PDTCompatResult *> *results);
FOUNDATION_EXPORT NSString *PDTCompatRecordingText(void);
FOUNDATION_EXPORT NSString *PDTCompatReportText(void);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *PDTCompatThreadLinesOnScreen(void);
FOUNDATION_EXPORT NSString *PDTCompatLeftMenuSeen(void);

#define PDTCOMPAT_ACTION(option, ...)                                                          \
  do {                                                                                    \
    if (PDTCompatActive) PDTCompatRecordAction((option), [NSString stringWithFormat:__VA_ARGS__]); \
  } while (0)
#define PDTCOMPAT_ACTION_IF(condition, option, ...)                                                           \
  do {                                                                                                   \
    if (PDTCompatActive && (condition))                                                                  \
      PDTCompatRecordAction((option), [NSString stringWithFormat:__VA_ARGS__]);                          \
  } while (0)
#define PDTCOMPAT_ANOMALY(option, ...)                                                          \
  do {                                                                                     \
    if (PDTCompatActive) PDTCompatRecordAnomaly((option), [NSString stringWithFormat:__VA_ARGS__]); \
  } while (0)
#define PDTCOMPAT_SENTINEL(option, present)                        \
  do {                                                        \
    if (PDTCompatActive) PDTCompatRecordSentinel((option), (present)); \
  } while (0)
#define PDTCOMPAT_RESPONSE(operation)                    \
  do {                                              \
    if (PDTCompatActive) PDTCompatRecordResponse(operation); \
  } while (0)

#else

#define PDTCOMPAT_ACTION(option, ...) \
  do {                           \
  } while (0)
#define PDTCOMPAT_ACTION_IF(condition, option, ...) \
  do {                                         \
  } while (0)
#define PDTCOMPAT_ANOMALY(option, ...) \
  do {                            \
  } while (0)
#define PDTCOMPAT_SENTINEL(option, present) \
  do {                                 \
  } while (0)
#define PDTCOMPAT_RESPONSE(operation) \
  do {                           \
  } while (0)

#endif
