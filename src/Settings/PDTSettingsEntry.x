#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PDTSettingsViewController.h"

static const NSInteger kPDTSettingsButtonTag = 1337;

// Adds the PrimeDit sparkles to Reddit's own Settings screen, once per screen.
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass(self.class);
    if (![name containsString:@"RedditSliceKit"] || ![name containsString:@"AppSettingsView"] ||
            ![name containsString:@"HostingController"])
        return;
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems)
        if (item.tag == kPDTSettingsButtonTag) return;
    UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightSemibold];
    UIImage *glyph = [UIImage systemImageNamed:@"sparkles" withConfiguration:configuration];
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithImage:glyph
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(pdOpenSettings)];
    button.tag = kPDTSettingsButtonTag;
    button.tintColor = UIColor.labelColor;
    button.accessibilityLabel = @"PrimeDit";
    NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items insertObject:button atIndex:0];
    self.navigationItem.rightBarButtonItems = items;
}

%new
- (void)pdOpenSettings {
    PDTSettingsViewController *settings =
            [(PDTSettingsViewController *)[objc_getClass("PDTSettingsViewController") alloc]
                    initWithStyle:UITableViewStyleGrouped];
    [self.navigationController pushViewController:settings animated:YES];
}

%end
