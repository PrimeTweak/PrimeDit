#import <UIKit/UIKit.h>
#import <BaseTableViewController.h>
#import "PDTPreferences.h"

@interface UIImage ()
- (UIImage *)imageScaledToSize:(CGSize)size;
@end

// PrimeDit's settings page, a runtime subclass of Reddit's table controller.
@interface PDTSettingsViewController : BaseTableViewController
@end
