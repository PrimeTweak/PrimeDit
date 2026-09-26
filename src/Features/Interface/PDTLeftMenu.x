#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "PDTPreferences.h"
#import "PDTCompatibility.h"

// Left menu option: hides whole sections of Reddit's community drawer. A section
// is known by its header title, read from Reddit's own header before layout.

@interface _TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler : NSObject <UITableViewDelegate>
@end

@interface _TtC15CommunityDrawer29CommunityDrawerViewController : UIViewController
@end

static NSSet<NSString *> *gHiddenSections;
static BOOL gReadingHeader;
static char kPDTSectionTitlesKey;
static char kPDTSectionCountKey;
static char kPDTHiddenCellKey;
static char kPDTLeftMenuObserver;

static void PDTLoadLeftMenuPrefs(void) {
    NSArray *hidden = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitLeftMenuHidden];
    gHiddenSections = [NSSet setWithArray:[hidden isKindOfClass:NSArray.class] ? hidden : @[]];
}

static void PDTLeftMenuPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                    const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        PDTLoadLeftMenuPrefs();
    });
}

static BOOL PDTIsNumber(NSString *text) {
    return [text rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound;
}

// Largest-font visible label outside buttons; badge counts are skipped.
static UILabel *PDTTitleLabel(UIView *view, NSInteger depth) {
    if (!view || view.hidden || depth > 6 || [view isKindOfClass:UIButton.class]) return nil;
    UILabel *best = nil;
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = [((UILabel *)view).text
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length && !PDTIsNumber(text)) best = (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *candidate = PDTTitleLabel(subview, depth + 1);
        if (candidate && (!best || candidate.font.pointSize > best.font.pointSize)) best = candidate;
    }
    return best;
}

static NSString *PDTViewTitle(UIView *view) {
    NSString *text = PDTTitleLabel(view, 0).text ?: view.accessibilityLabel;
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

// Section title from Reddit's own header. Header height passes refresh it; a new
// section count clears every title.
static NSString *PDTSectionTitle(id<UITableViewDelegate> handler, UITableView *tableView, NSInteger section,
                                 BOOL refresh) {
    NSMutableDictionary<NSNumber *, NSString *> *titles = objc_getAssociatedObject(tableView, &kPDTSectionTitlesKey);
    NSNumber *count = @(tableView.numberOfSections);
    if (!titles || ![objc_getAssociatedObject(tableView, &kPDTSectionCountKey) isEqual:count]) {
        titles = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(tableView, &kPDTSectionTitlesKey, titles, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(tableView, &kPDTSectionCountKey, count, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString *title = refresh ? nil : titles[@(section)];
    if (!title) {
        UIView *header = nil;
        if ([handler respondsToSelector:@selector(tableView:viewForHeaderInSection:)]) {
            gReadingHeader = YES;
            header = [handler tableView:tableView viewForHeaderInSection:section];
            gReadingHeader = NO;
        }
        title = PDTViewTitle(header) ?: @"";
        titles[@(section)] = title;
    }
    return title.length ? title : nil;
}

static BOOL PDTSectionHidden(id<UITableViewDelegate> handler, UITableView *tableView, NSInteger section,
                             BOOL refresh) {
    if (!gHiddenSections.count || gReadingHeader) return NO;
    NSString *title = PDTSectionTitle(handler, tableView, section, refresh);
    return title && [gHiddenSections containsObject:title];
}

// Grouped tables read 0 as "default height".
static CGFloat PDTNoHeight(UITableView *tableView) {
    return tableView.style == UITableViewStylePlain ? 0.0 : CGFLOAT_MIN;
}

static UITableView *PDTDrawerTable(UIView *view, NSInteger depth) {
    if (!view || depth > 6) return nil;
    if ([view isKindOfClass:UITableView.class] &&
            [((UITableView *)view).delegate
                    isKindOfClass:objc_getClass("_TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler")])
        return (UITableView *)view;
    for (UIView *subview in view.subviews) {
        UITableView *table = PDTDrawerTable(subview, depth + 1);
        if (table) return table;
    }
    return nil;
}

// Section titles the menu shows, kept for the settings page.
static void PDTRecordSections(UITableView *tableView) {
    if (!tableView) return;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        NSString *title = PDTSectionTitle(tableView.delegate, tableView, section, NO);
        if (title && ![titles containsObject:title]) [titles addObject:title];
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (titles.count && ![[defaults arrayForKey:kPrimeDitLeftMenuSections] isEqual:titles])
        [defaults setObject:titles forKey:kPrimeDitLeftMenuSections];
}

#if PRIMEDIT_DEBUG
static NSString *gPDCompatLeftMenuText;

NSString *PDTCompatLeftMenuSeen(void) {
    return gPDCompatLeftMenuText;
}

// Compatibility check: the menu's sections as read, and whether each hidden one takes no room.
static void PDTCompatVerifyLeftMenu(UITableView *tableView) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableSet<NSString *> *present = [NSMutableSet set];
    for (NSInteger section = 0; section < tableView.numberOfSections; section++) {
        NSInteger rows = [tableView numberOfRowsInSection:section];
        NSString *title = PDTSectionTitle(tableView.delegate, tableView, section, NO);
        if (!title) {
            UITableViewCell *cell =
                    rows ? [tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:section]] : nil;
            NSString *first = PDTViewTitle(cell);
            NSString *hint = first ? [@", first row: " stringByAppendingString:first] : @"";
            [parts addObject:[NSString stringWithFormat:@"[no title%@] (%ld)", hint, (long)rows]];
            continue;
        }
        [present addObject:title];
        [parts addObject:[NSString stringWithFormat:@"%@ (%ld)", title, (long)rows]];
        if (![gHiddenSections containsObject:title]) continue;
        CGFloat height = [tableView rectForSection:section].size.height;
        if (height > 1.0)
            PDTCompatRecordAnomaly(PDTCompatLeftMenu,
                                   [NSString stringWithFormat:@"\"%@\" still takes %.0f pt", title, height]);
        else
            PDTCompatRecordAction(PDTCompatLeftMenu, [NSString stringWithFormat:@"Hidden: %@", title]);
    }
    NSMutableArray<NSString *> *absent = [NSMutableArray array];
    for (NSString *title in gHiddenSections)
        if (![present containsObject:title]) [absent addObject:title];
    NSString *text = [@"Menu: " stringByAppendingString:parts.count ? [parts componentsJoinedByString:@" \u00b7 "]
                                                                     : @"no section"];
    if (absent.count)
        text = [text stringByAppendingFormat:@" \u00b7 not in the menu now: %@", [absent componentsJoinedByString:@", "]];
    gPDCompatLeftMenuText = text;
}

// Runs once the menu's content has settled on screen.
static void PDTCompatVerifyLeftMenuLater(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UITableView *tableView = PDTDrawerTable(weakController.viewIfLoaded, 0);
        if (tableView.window) PDTCompatVerifyLeftMenu(tableView);
    });
}

#define PDTCOMPAT_VERIFY_LEFT_MENU(controller)                \
  do {                                                   \
    if (PDTCompatActive) PDTCompatVerifyLeftMenuLater(controller); \
  } while (0)
#else
#define PDTCOMPAT_VERIFY_LEFT_MENU(controller) \
  do {                                    \
  } while (0)
#endif

%hook _TtC15CommunityDrawer39CommunityDrawerTableViewDelegateHandler

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return PDTSectionHidden(self, tableView, section, YES) ? PDTNoHeight(tableView) : %orig;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return PDTSectionHidden(self, tableView, section, NO) ? nil : %orig;
}

- (void)tableView:(UITableView *)tableView
            willDisplayCell:(UITableViewCell *)cell
        forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    BOOL hidden = PDTSectionHidden(self, tableView, indexPath.section, NO);
    if (!hidden && !objc_getAssociatedObject(cell, &kPDTHiddenCellKey)) return;
    cell.hidden = hidden;
    objc_setAssociatedObject(cell, &kPDTHiddenCellKey, hidden ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Without this method the table uses rowHeight; hidden sections get none.
%new
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return PDTSectionHidden(self, tableView, indexPath.section, NO) ? 0.0 : tableView.rowHeight;
}

%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return PDTSectionHidden(self, tableView, section, NO) ? PDTNoHeight(tableView) : tableView.sectionFooterHeight;
}

%end

%hook _TtC15CommunityDrawer29CommunityDrawerViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    PDTCOMPAT_VERIFY_LEFT_MENU(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    PDTRecordSections(PDTDrawerTable(self.viewIfLoaded, 0));
    %orig;
}

%end

%ctor {
    PDTLoadLeftMenuPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), &kPDTLeftMenuObserver,
                                    PDTLeftMenuPrefsChanged, CFSTR(kPrimeDitPrefsNotification), NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
    %init;
}
