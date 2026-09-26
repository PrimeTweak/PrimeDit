// PrimeDit entry point.

#import "PDTIcons.h"
#import "PDTFilterPrefs.h"

%ctor {
    @autoreleasepool {
        PDTLoadIconCatalogs();
        PDTStartFilterPrefs();
    }
}
