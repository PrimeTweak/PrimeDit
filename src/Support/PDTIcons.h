// Reddit's own icons, looked up by name in its asset catalogs.

#import <UIKit/UIKit.h>

// Loads Reddit's asset catalogs; called once at launch.
void PDTLoadIconCatalogs(void);

// A Reddit icon by catalog name, or nil.
UIImage *PDTIconWithName(NSString *iconName);
