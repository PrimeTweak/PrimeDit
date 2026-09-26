#import <Comment.h>
#import "PDTFilterPrefs.h"
#import "PDTClasses.h"

// Reddit's comment model: AutoMod comments start collapsed.
%group AutoModCollapse

%hook Comment
- (BOOL)shouldAutoCollapse {
    return globalPrefs.automod &&
                   [((Comment *)self).authorPk isEqualToString:@"t2_6l4z3"]
               ? YES
               : %orig;
}
%end

%end

%ctor {
    %init(AutoModCollapse, Comment = PDTCoreClass(@"Comment"));
}
