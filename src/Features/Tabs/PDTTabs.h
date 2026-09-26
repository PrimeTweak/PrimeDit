// Tab bar options, called from the refresh options and the feed filter.

#import <UIKit/UIKit.h>

// Reddit's main tab bar controller, once loaded.
extern __weak UITabBarController *gMainTabBar;

// Whether vc is the Home tab or holds it.
BOOL PDTIsHomeTab(UIViewController *vc);

// Whether a tab is at the root of its navigation stack.
BOOL PDTTabIsAtRoot(UIViewController *vc);

// Shows Reddit's badge counts on the split Inbox and Chat tabs.
void PDTApplySplitTabBadges(id indicators);
