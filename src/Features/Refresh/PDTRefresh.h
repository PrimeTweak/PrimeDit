// Refresh options, called from the tab bar hooks.

#import <UIKit/UIKit.h>

// Notes a return to the Home tab from another tab.
void PDTNoteHomeTabSelection(UITabBarController *tbc, UIViewController *vc);

// Holds a second tap on Home until the refresh is confirmed; YES when held.
BOOL PDTHoldHomeReselect(UITabBarController *tbc, UIViewController *vc);

// Installs the refresh hooks that the current options need.
void PDTInstallRefreshHooksIfNeeded(void);
