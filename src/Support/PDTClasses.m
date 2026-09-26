#import "PDTClasses.h"

Class PDTCoreClass(NSString *name) {
    Class cls = NSClassFromString(name);
    NSArray *prefixes = @[
        @"Reddit.",
        @"RedditCore.",
        @"RedditCoreModels.",
        @"RedditCore_RedditCoreModels.",
        @"RedditUI.",
      ];
    for (NSString *prefix in prefixes) {
        if (cls) break;
        cls = NSClassFromString([prefix stringByAppendingString:name]);
    }
    return cls;
}
