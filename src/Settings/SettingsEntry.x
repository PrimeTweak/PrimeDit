#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SettingsViewController.h"

static const NSInteger kPDSettingsButtonTag = 1337;

// Adds the PrimeDit button to Reddit's own Settings screen, once per screen.
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NSString *name = NSStringFromClass(self.class);
    if (![name containsString:@"RedditSliceKit"] || ![name containsString:@"AppSettingsView"] ||
            ![name containsString:@"HostingController"])
        return;
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems)
        if (item.tag == kPDSettingsButtonTag) return;
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"PrimeDit"
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(pdOpenSettings)];
    button.tag = kPDSettingsButtonTag;
    [button setTitlePositionAdjustment:UIOffsetMake(0, 3.5) forBarMetrics:UIBarMetricsDefault];
    NSMutableArray *items = [self.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items insertObject:button atIndex:0];
    self.navigationItem.rightBarButtonItems = items;
}

%new
- (void)pdOpenSettings {
    PDSettingsViewController *settings =
            [(PDSettingsViewController *)[objc_getClass("PDSettingsViewController") alloc]
                    initWithStyle:UITableViewStyleGrouped];
    [self.navigationController pushViewController:settings animated:YES];
}

%end
