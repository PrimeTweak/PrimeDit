#import <CoreFoundation/CoreFoundation.h>
#import "PDTSettingsViewController.h"
#import "PDTDataPaths.h"
#import "PDTCache.h"
#import "PDTCompatibility.h"

#import "PDTIcons.h"
extern NSArray<UIColor *> *PDTPaletteColors(NSInteger index);

// Tells every hook that an option changed.
static void postPrefsUpdatedNotification(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(kPrimeDitPrefsNotification), NULL, NULL, true);
}

// Reddit asset icons are scaled to 20 pt in settings rows.
static const CGFloat kPDTIconSize = 20.0;

#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Native settings styling

// Metrics measured on Reddit 2026.38's own Settings screen (3 px = 1 pt).
static const CGFloat kPDTRowHeight = 48.0;
static const CGFloat kPDTRowHeightWithSubtitle = 64.0;
static const CGFloat kPDTHeaderHeight = 32.0;
static const CGFloat kPDTSectionGap = 16.0;
static const CGFloat kPDTLinkFooterHeight = 44.0;
static const CGFloat kPDTIconCenterX = 32.0;
static const CGFloat kPDTTextInset = 57.0;
static const CGFloat kPDTPlainTextInset = 20.0;
// Right edges measured on settings rows: switches at 12.0 pt, chevrons and checks
// at 20.7 pt. Info buttons and trailing buttons sit on the same columns.
static const CGFloat kPDTSwitchColumnInset = 12.0;
static const CGFloat kPDTChevronColumnInset = 20.7;
// Transparent margin measured on the right of the 17 pt info.circle image.
static const CGFloat kPDTSymbolMargin = 2.0;
// Raises the info circle so its bottom sits on the header's baseline (measured 6.0 pt low).
static const CGFloat kPDTInfoLift = 6.0;
// Added under the last section so the last row ends 42.7 pt above the screen
// bottom, like the last line of native Settings (measured).
static const CGFloat kPDTBottomSpace = 12.4;

static UIFont *PDTSettingsFont(CGFloat size, BOOL bold) {
    UIFont *font = [UIFont fontWithName:(bold ? @"RedditSans-Bold" : @"RedditSans-Regular") size:size];
    return font ?: [UIFont systemFontOfSize:size weight:(bold ? UIFontWeightBold : UIFontWeightRegular)];
}

static UIColor *PDTHexColor(uint32_t hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:1.0];
}

// Light values are measured on Reddit; dark mode falls back to system colors.
static UIColor *PDTDynamicColor(uint32_t lightHex, UIColor *dark) {
    UIColor *light = PDTHexColor(lightHex);
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                   ? [dark resolvedColorWithTraitCollection:traits]
                   : light;
    }];
}

static UIColor *PDTPrimaryColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = PDTDynamicColor(0x181B1E, UIColor.labelColor); });
    return color;
}

static UIColor *PDTSecondaryColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = PDTDynamicColor(0x5F6B73, UIColor.secondaryLabelColor); });
    return color;
}

// Reddit's destructive red, measured on native "Delete account".
static UIColor *PDTDestructiveColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = PDTDynamicColor(0xAC2322, UIColor.systemRedColor); });
    return color;
}

// Info buttons as pale next to their header as Instagram's (measured), in Reddit's cool gray.
static UIColor *PDTInfoColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = PDTDynamicColor(0x9FA9B0, UIColor.systemGray2Color); });
    return color;
}

static UIColor *PDTSwitchOnColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = PDTDynamicColor(0x000000, UIColor.systemGreenColor); });
    return color;
}

static void PDTPresentAlert(UIViewController *presenter, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

typedef NS_ENUM(NSInteger, PDTAccessory) {
    PDTAccessoryNone,
    PDTAccessorySwitch,
    PDTAccessoryChevron,
    PDTAccessoryCheck,
};

// Settings row laid out to the native metrics: 24 pt icon box centered at
// x = 32, text from x = 57. The switch frame sits 14 pt from the trailing
// edge, which puts its track on the measured 12 pt column.
@interface PDTSettingsCell : UITableViewCell
@property(nonatomic, strong, readonly) UISwitch *toggle;
- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                     value:(NSString *)value
                      icon:(UIImage *)icon
                 accessory:(PDTAccessory)accessory;
- (void)showSwatches:(NSArray<UIColor *> *)colors;
- (void)setValueColor:(UIColor *)color;
- (void)setTitleColor:(UIColor *)color;
@end

@implementation PDTSettingsCell {
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UILabel *_valueLabel;
    UIImageView *_markView;
    UIStackView *_swatchStack;
    NSLayoutConstraint *_textLeading;
    NSLayoutConstraint *_trailingInset;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.backgroundColor = UIColor.systemBackgroundColor;

    _iconView = [[UIImageView alloc] init];
    _iconView.contentMode = UIViewContentModeCenter;
    _iconView.tintColor = PDTPrimaryColor();
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = PDTSettingsFont(17.0, NO);
    _titleLabel.textColor = PDTPrimaryColor();

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.font = PDTSettingsFont(12.0, NO);
    _subtitleLabel.textColor = PDTSecondaryColor();

    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _subtitleLabel ]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2.0;
    text.translatesAutoresizingMaskIntoConstraints = NO;

    _valueLabel = [[UILabel alloc] init];
    _valueLabel.font = PDTSettingsFont(16.0, NO);
    _valueLabel.textColor = PDTPrimaryColor();
    [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                 forAxis:UILayoutConstraintAxisHorizontal];

    _toggle = [[UISwitch alloc] init];
    _toggle.onTintColor = PDTSwitchOnColor();

    _markView = [[UIImageView alloc] init];
    _markView.contentMode = UIViewContentModeCenter;

    _swatchStack = [[UIStackView alloc] init];
    _swatchStack.axis = UILayoutConstraintAxisHorizontal;
    _swatchStack.alignment = UIStackViewAlignmentCenter;
    _swatchStack.spacing = 3.0;
    _swatchStack.hidden = YES;

    UIStackView *trailing =
            [[UIStackView alloc] initWithArrangedSubviews:@[ _swatchStack, _valueLabel, _toggle, _markView ]];
    trailing.axis = UILayoutConstraintAxisHorizontal;
    trailing.alignment = UIStackViewAlignmentCenter;
    trailing.spacing = 8.0;
    trailing.translatesAutoresizingMaskIntoConstraints = NO;

    [self.contentView addSubview:_iconView];
    [self.contentView addSubview:text];
    [self.contentView addSubview:trailing];

    _textLeading = [text.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor
                                                      constant:kPDTTextInset];
    _trailingInset = [trailing.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                             constant:-20.0];
    [NSLayoutConstraint activateConstraints:@[
        [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kPDTIconCenterX],
        [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24.0],
        [_iconView.heightAnchor constraintEqualToConstant:24.0],
        _textLeading,
        [text.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [text.trailingAnchor constraintLessThanOrEqualToAnchor:trailing.leadingAnchor constant:-12.0],
        _trailingInset,
        [trailing.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
      ]];
    return self;
}

- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                     value:(NSString *)value
                      icon:(UIImage *)icon
                 accessory:(PDTAccessory)accessory {
    [self showSwatches:nil];
    _titleLabel.text = title;
    _titleLabel.textColor = PDTPrimaryColor();
    _iconView.tintColor = PDTPrimaryColor();
    _subtitleLabel.text = subtitle;
    _subtitleLabel.hidden = subtitle.length == 0;
    _valueLabel.text = value;
    _valueLabel.hidden = value.length == 0;
    _valueLabel.textColor = PDTPrimaryColor();
    _iconView.image = icon;
    _iconView.hidden = icon == nil;
    _textLeading.constant = icon ? kPDTTextInset : kPDTPlainTextInset;

    _toggle.hidden = accessory != PDTAccessorySwitch;
    _markView.hidden = accessory != PDTAccessoryChevron && accessory != PDTAccessoryCheck;
    if (accessory == PDTAccessoryChevron) {
        _markView.image = [UIImage systemImageNamed:@"chevron.right"
                                  withConfiguration:[UIImageSymbolConfiguration
                                                        configurationWithPointSize:14.0
                                                                            weight:UIImageSymbolWeightSemibold]];
        _markView.tintColor = PDTSecondaryColor();
    } else if (accessory == PDTAccessoryCheck) {
        _markView.image = [UIImage systemImageNamed:@"checkmark"
                                  withConfiguration:[UIImageSymbolConfiguration
                                                        configurationWithPointSize:15.0
                                                                            weight:UIImageSymbolWeightSemibold]];
        _markView.tintColor = PDTPrimaryColor();
    }
    _trailingInset.constant = accessory == PDTAccessorySwitch ? -14.0 : -20.0;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
}

- (void)setValueColor:(UIColor *)color {
    _valueLabel.textColor = color;
}

// Title and icon together, as native destructive rows.
- (void)setTitleColor:(UIColor *)color {
    _titleLabel.textColor = color;
    _iconView.tintColor = color;
}

// Palette colors as small dots; a hairline keeps pale colors visible.
- (void)showSwatches:(NSArray<UIColor *> *)colors {
    for (UIView *dot in _swatchStack.arrangedSubviews) {
        [_swatchStack removeArrangedSubview:dot];
        [dot removeFromSuperview];
    }
    UIColor *border = [UIColor.separatorColor resolvedColorWithTraitCollection:self.traitCollection];
    for (UIColor *color in colors) {
        UIView *dot = [[UIView alloc] init];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = 5.0;
        dot.layer.borderWidth = 0.5;
        dot.layer.borderColor = border.CGColor;
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        [dot.widthAnchor constraintEqualToConstant:10.0].active = YES;
        [dot.heightAnchor constraintEqualToConstant:10.0].active = YES;
        [_swatchStack addArrangedSubview:dot];
    }
    _swatchStack.hidden = colors.count == 0;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [_toggle removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    self.accessoryView = nil;
}
@end

// Reddit's Settings headers, measured: Reddit Sans SemiBold 13 pt, 0.35 pt tracking.
static UIFont *PDTHeaderFont(void) {
    return [UIFont fontWithName:@"RedditSans-SemiBold" size:13.0] ?: PDTSettingsFont(13.0, YES);
}

// Section header in caps at x = 20, baseline 4.5 pt above the bottom; when the
// section has help, an info button on the given column, its circle on the baseline.
static UIView *PDTSectionHeaderViewWithInfo(NSString *title, CGFloat column, void (^onInfo)(void)) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] init];
    label.attributedText = [[NSAttributedString alloc] initWithString:title.uppercaseString
                                                           attributes:@{
                                                               NSFontAttributeName : PDTHeaderFont(),
                                                               NSForegroundColorAttributeName : PDTSecondaryColor(),
                                                               NSKernAttributeName : @0.35,
                                                           }];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:label];
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [label.lastBaselineAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4.5],
      ]];
    if (onInfo) {
        UIButton *info = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *symbol =
                [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightRegular];
        [info setImage:[UIImage systemImageNamed:@"info.circle" withConfiguration:symbol] forState:UIControlStateNormal];
        info.tintColor = PDTInfoColor();
        info.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
        info.accessibilityLabel = [@"About " stringByAppendingString:title];
        [info addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            onInfo();
        }]
                forControlEvents:UIControlEventTouchUpInside];
        info.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:info];
        [constraints addObjectsFromArray:@[
            [info.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-(column - kPDTSymbolMargin)],
            [info.centerYAnchor constraintEqualToAnchor:label.centerYAnchor constant:-kPDTInfoLift],
            [info.widthAnchor constraintEqualToConstant:44.0],
            [info.heightAnchor constraintEqualToConstant:44.0],
            [label.trailingAnchor constraintLessThanOrEqualToAnchor:info.leadingAnchor constant:-4.0],
          ]];
    } else {
        [constraints addObject:[label.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor
                                                                               constant:-20.0]];
    }
    [NSLayoutConstraint activateConstraints:constraints];
    return container;
}

static UIView *PDTSectionHeaderView(NSString *title) {
    return PDTSectionHeaderViewWithInfo(title, 0, nil);
}

static UIView *PDTSectionFooterView(NSString *text) {
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] init];
    label.font = PDTSettingsFont(12.0, NO);
    label.textColor = PDTSecondaryColor();
    label.numberOfLines = 0;
    label.text = text;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:container.topAnchor constant:6.0],
        [label.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:21.0],
        [label.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0],
      ]];
    return container;
}

static CGFloat PDTFooterHeight(NSString *text, CGFloat width) {
    CGRect bounds = [text boundingRectWithSize:CGSizeMake(MAX(width - 41.0, 1.0), CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin
                                    attributes:@{NSFontAttributeName : PDTSettingsFont(12.0, NO)}
                                       context:nil];
    return ceil(bounds.size.height) + 6.0 + kPDTSectionGap;
}

static void PDTStyleSettingsTable(UITableView *tableView) {
    tableView.backgroundColor = UIColor.systemBackgroundColor;
    tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    tableView.sectionHeaderTopPadding = 0;
    tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kPDTBottomSpace)];
    [tableView registerClass:PDTSettingsCell.class forCellReuseIdentifier:@"PDTSettingsCell"];
}

// Credit under the last section of the main page, in the system's light gray.
static UIView *PDTCreditFooter(void) {
    UILabel *name = [[UILabel alloc] init];
    name.text = @"PrimeDit";
    name.font = PDTSettingsFont(15, YES);
    UILabel *credit = [[UILabel alloc] init];
    credit.text = @"Original work by @level3tjg";
    credit.font = PDTSettingsFont(13, NO);
    credit.numberOfLines = 0;
    for (UILabel *label in @[ name, credit ]) {
        label.textColor = UIColor.systemGray3Color;
        label.textAlignment = NSTextAlignmentCenter;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ name, credit ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = -2;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 100)];
    [footer addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:footer.topAnchor constant:21],
        [stack.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-20],
      ]];
    return footer;
}

// The "How it works" link under the last section, in the footer's gray, its
// icon centered on the row icons.
static UIView *PDTHowItWorksFooter(id target, SEL action) {
    UIImageSymbolConfiguration *size =
            [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightRegular];
    UIImage *glyph = [UIImage systemImageNamed:@"info.circle" withConfiguration:size];
    UIButtonConfiguration *style = [UIButtonConfiguration plainButtonConfiguration];
    style.image = glyph;
    style.imagePadding = 6.0;
    style.contentInsets = NSDirectionalEdgeInsetsMake(8.0, 0.0, 16.0, 12.0);
    style.baseForegroundColor = UIColor.systemGray3Color;
    style.attributedTitle = [[NSAttributedString alloc] initWithString:@"How it works"
                                                            attributes:@{NSFontAttributeName : PDTSettingsFont(15, NO)}];
    UIButton *link = [UIButton buttonWithConfiguration:style primaryAction:nil];
    [link addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    link.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *footer = [[UIView alloc] init];
    [footer addSubview:link];
    [NSLayoutConstraint activateConstraints:@[
        [link.topAnchor constraintEqualToAnchor:footer.topAnchor],
        [link.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:kPDTIconCenterX - glyph.size.width / 2.0],
      ]];
    return footer;
}

// A custom view rather than the system Done item, whose iOS 26 style ignores
// tintColor and draws a washed-out checkmark. Same glyph as PrimeSenger's.
static UIBarButtonItem *PDTDoneItem(id target, SEL action) {
    UIImageSymbolConfiguration *check =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 44, 44);
    button.tintColor = UIColor.labelColor;
    button.accessibilityLabel = @"Done";
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [button setImage:[UIImage systemImageNamed:@"checkmark" withConfiguration:check] forState:UIControlStateNormal];
    return [[UIBarButtonItem alloc] initWithCustomView:button];
}

static UIImage *PDTRowIcon(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        UIImage *image = PDTIconWithName(name);
        if (image)
            return [[image imageScaledToSize:CGSizeMake(kPDTIconSize, kPDTIconSize)]
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

#pragma mark - Help sheet

@interface PDTHelpItem : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) UIImage *icon;
@end

@implementation PDTHelpItem
@end

static PDTHelpItem *PDTHelp(NSString *title, NSString *text, UIImage *icon) {
    PDTHelpItem *item = [[PDTHelpItem alloc] init];
    item.title = title;
    item.text = text;
    item.icon = icon;
    return item;
}

static const CGFloat kPDTHelpTitleTop = 26.0;
static const CGFloat kPDTHelpListGap = 26.0;
static const CGFloat kPDTHelpBottom = 28.0;
static const CGFloat kPDTHelpSideInset = 24.0;

// One option in a help sheet: its icon, its name in bold, then a sentence.
static UIView *PDTHelpRow(PDTHelpItem *item) {
    UILabel *name = [[UILabel alloc] init];
    name.font = PDTSettingsFont(17.0, YES);
    name.textColor = PDTPrimaryColor();
    name.numberOfLines = 0;
    name.text = item.title;
    UILabel *text = [[UILabel alloc] init];
    text.font = PDTSettingsFont(15.0, NO);
    text.textColor = PDTSecondaryColor();
    text.numberOfLines = 0;
    text.text = item.text;
    UIStackView *words = [[UIStackView alloc] initWithArrangedSubviews:@[ name, text ]];
    words.axis = UILayoutConstraintAxisVertical;
    words.spacing = 3.0;
    UIImageView *icon = [[UIImageView alloc] initWithImage:item.icon];
    icon.tintColor = PDTPrimaryColor();
    icon.contentMode = UIViewContentModeCenter;
    icon.hidden = item.icon == nil;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:24.0].active = YES;
    [icon.heightAnchor constraintEqualToConstant:24.0].active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, words ]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 16.0;
    return row;
}

// Sheet behind a section's info button: centered title, close button, then the options
// whose title needs a word of explanation.
@interface PDTHelpSheetViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title items:(NSArray<PDTHelpItem *> *)items;
- (CGFloat)fittingHeightForWidth:(CGFloat)width;
@end

@implementation PDTHelpSheetViewController {
    NSString *_sheetTitle;
    NSArray<PDTHelpItem *> *_items;
    UILabel *_titleLabel;
    UIStackView *_list;
}

- (instancetype)initWithTitle:(NSString *)title items:(NSArray<PDTHelpItem *> *)items {
    self = [super initWithNibName:nil bundle:nil];
    if (!self) return nil;
    _sheetTitle = [title copy];
    _items = [items copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = PDTSettingsFont(17.0, YES);
    _titleLabel.textColor = PDTPrimaryColor();
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.text = _sheetTitle;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *symbol =
            [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
    [close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:symbol] forState:UIControlStateNormal];
    close.tintColor = PDTPrimaryColor();
    close.backgroundColor = UIColor.tertiarySystemFillColor;
    close.layer.cornerRadius = 20.0;
    close.accessibilityLabel = @"Close";
    [close addTarget:self action:@selector(closeSheet) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;

    _list = [[UIStackView alloc] init];
    _list.axis = UILayoutConstraintAxisVertical;
    _list.spacing = 22.0;
    _list.translatesAutoresizingMaskIntoConstraints = NO;
    for (PDTHelpItem *item in _items) [_list addArrangedSubview:PDTHelpRow(item)];

    [self.view addSubview:_titleLabel];
    [self.view addSubview:close];
    [self.view addSubview:_list];
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kPDTHelpTitleTop],
        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:64.0],
        [close.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
        [close.widthAnchor constraintEqualToConstant:40.0],
        [close.heightAnchor constraintEqualToConstant:40.0],
        [_list.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:kPDTHelpListGap],
        [_list.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kPDTHelpSideInset],
        [_list.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kPDTHelpSideInset],
      ]];
}

- (void)closeSheet {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (CGFloat)fittingHeightForWidth:(CGFloat)width {
    [self loadViewIfNeeded];
    CGSize list = [_list systemLayoutSizeFittingSize:CGSizeMake(width - 2.0 * kPDTHelpSideInset,
                                                                UILayoutFittingCompressedSize.height)
                       withHorizontalFittingPriority:UILayoutPriorityRequired
                             verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    return kPDTHelpTitleTop + ceil(_titleLabel.font.lineHeight) + kPDTHelpListGap + ceil(list.height) + kPDTHelpBottom;
}
@end

// Presents the sheet at the height of its content.
static void PDTPresentHelpSheet(UIViewController *presenter, NSString *title, NSArray<PDTHelpItem *> *items) {
    if (!presenter || !items.count) return;
    PDTHelpSheetViewController *sheet = [[PDTHelpSheetViewController alloc] initWithTitle:title items:items];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *controller = sheet.sheetPresentationController;
    CGFloat width = presenter.view.bounds.size.width;
    __weak PDTHelpSheetViewController *weakSheet = sheet;
    controller.detents = @[ [UISheetPresentationControllerDetent
            customDetentWithIdentifier:@"PDTHelpSheet"
                              resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                                  return MIN([weakSheet fittingHeightForWidth:width], context.maximumDetentValue);
                              }] ];
    controller.prefersGrabberVisible = YES;
    [presenter presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Comment thread lines page

// Palette names in stored index order; -1 keeps Reddit's color.
static NSString *const kPDTPaletteNames[15] = {
    @"Sunset", @"Cyberpunk", @"Synthwave", @"Matrix", @"Nord", @"Dracula", @"Gruvbox", @"Tokyo Night",
    @"Rose Pine", @"Solarized", @"Neon", @"Ocean", @"Pastel", @"Mono", @"Rainbow"};
static const NSInteger kPDTPaletteOrder[16] = {-1, 14, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13};
static const CGFloat kPDTThicknesses[6] = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0};

static NSString *PDTPaletteName(NSInteger index) {
    return (index >= 0 && index < 15) ? kPDTPaletteNames[index] : @"Original";
}

static NSInteger PDTCurrentPaletteIndex(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return [defaults objectForKey:kPrimeDitThreadThemeIndex]
               ? [defaults integerForKey:kPrimeDitThreadThemeIndex]
               : -1;
}

static NSString *PDTThicknessLabel(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    float value = [defaults floatForKey:kPrimeDitThreadLineThickness];
    return ([defaults objectForKey:kPrimeDitThreadLineThickness] && value > 0)
               ? [NSString stringWithFormat:@"%.1f pt", value]
               : @"Default";
}

static NSString *PDTThreadLinesSummary(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:kPrimeDitThreadLinesEnabled]) return @"Off";
    if ([defaults boolForKey:kPrimeDitThreadRainbowMode]) return @"Random";
    return PDTPaletteName(PDTCurrentPaletteIndex());
}

// Line coloring, stored as the rainbow and depth-cycling switches.
typedef NS_ENUM(NSInteger, PDTLineColoring) {
    PDTLineColoringByDepth,
    PDTLineColoringSingle,
    PDTLineColoringRandom,
};

static NSString *const kPDTColoringTitles[3] = {@"By depth", @"Single color", @"Random"};
static NSString *const kPDTColoringHelp[3] = {@"Each reply level takes the next color of the palette.",
                                              @"Every line takes the palette\u2019s first color.",
                                              @"Each line gets its own random color. No palette needed."};
static NSString *const kPDTColoringSymbols[3] = {@"list.bullet.indent", @"minus", @"shuffle"};

static PDTLineColoring PDTCurrentColoring(void) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kPrimeDitThreadRainbowMode]) return PDTLineColoringRandom;
    return PDTPrefBool(kPrimeDitThreadDepthCycling, YES) ? PDTLineColoringByDepth : PDTLineColoringSingle;
}

static void PDTSetColoring(PDTLineColoring coloring) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:(coloring == PDTLineColoringRandom) forKey:kPrimeDitThreadRainbowMode];
    if (coloring != PDTLineColoringRandom)
        [defaults setBool:(coloring == PDTLineColoringByDepth) forKey:kPrimeDitThreadDepthCycling];
    postPrefsUpdatedNotification();
}

@interface PDTThreadLinesViewController : UITableViewController
@end

@implementation PDTThreadLinesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Comment thread lines";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
}

// Lines, Coloring and Palette; Random coloring has no use for a palette.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return PDTCurrentColoring() == PDTLineColoringRandom ? 2 : 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : section == 1 ? 3 : 16;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
    if (indexPath.section == 2) {
        NSInteger index = kPDTPaletteOrder[indexPath.row];
        [cell configureWithTitle:PDTPaletteName(index)
                        subtitle:nil
                           value:nil
                            icon:nil
                       accessory:(index == PDTCurrentPaletteIndex() ? PDTAccessoryCheck : PDTAccessoryNone)];
        [cell showSwatches:PDTPaletteColors(index)];
        return cell;
    }
    if (indexPath.section == 1) {
        [cell configureWithTitle:kPDTColoringTitles[indexPath.row]
                        subtitle:nil
                           value:nil
                            icon:nil
                       accessory:(indexPath.row == PDTCurrentColoring() ? PDTAccessoryCheck : PDTAccessoryNone)];
        return cell;
    }
    if (indexPath.row == 1) {
        [cell configureWithTitle:@"Thickness"
                        subtitle:nil
                           value:PDTThicknessLabel()
                            icon:nil
                       accessory:PDTAccessoryChevron];
        return cell;
    }
    [cell configureWithTitle:@"Color lines" subtitle:nil value:nil icon:nil accessory:PDTAccessorySwitch];
    cell.toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:kPrimeDitThreadLinesEnabled];
    [cell.toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:kPrimeDitThreadLinesEnabled];
    postPrefsUpdatedNotification();
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kPDTRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 1) return PDTSectionHeaderView(section == 0 ? @"Lines" : @"Palette");
    __weak PDTThreadLinesViewController *weakSelf = self;
    return PDTSectionHeaderViewWithInfo(@"Coloring", kPDTChevronColumnInset, ^{
        [weakSelf showColoringHelp];
    });
}

- (void)showColoringHelp {
    NSMutableArray<PDTHelpItem *> *items = [NSMutableArray array];
    for (NSInteger i = 0; i < 3; i++) {
        UIImage *icon = [UIImage systemImageNamed:kPDTColoringSymbols[i]
                                withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17.0]];
        [items addObject:PDTHelp(kPDTColoringTitles[i], kPDTColoringHelp[i], icon)];
    }
    PDTPresentHelpSheet(self, @"Coloring", items);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return kPDTSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        [NSUserDefaults.standardUserDefaults setInteger:kPDTPaletteOrder[indexPath.row]
                                                 forKey:kPrimeDitThreadThemeIndex];
        postPrefsUpdatedNotification();
        [tableView reloadData];
    } else if (indexPath.section == 1) {
        [self chooseColoring:(PDTLineColoring)indexPath.row];
    } else if (indexPath.row == 1) {
        [self chooseThicknessFromView:[tableView cellForRowAtIndexPath:indexPath]];
    }
}

// The palette section fades out with Random and back in with the other two.
- (void)chooseColoring:(PDTLineColoring)coloring {
    BOOL hadPalette = PDTCurrentColoring() != PDTLineColoringRandom;
    PDTSetColoring(coloring);
    BOOL hasPalette = coloring != PDTLineColoringRandom;
    UITableView *tableView = self.tableView;
    [tableView performBatchUpdates:^{
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
        if (hadPalette && !hasPalette)
            [tableView deleteSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationFade];
        else if (!hadPalette && hasPalette)
            [tableView insertSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationFade];
    }
                        completion:nil];
}

- (void)chooseThicknessFromView:(UIView *)source {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Thickness"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak PDTThreadLinesViewController *weakSelf = self;
    void (^choose)(CGFloat) = ^(CGFloat value) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if (value > 0)
            [defaults setFloat:value forKey:kPrimeDitThreadLineThickness];
        else
            [defaults removeObjectForKey:kPrimeDitThreadLineThickness];
        postPrefsUpdatedNotification();
        [weakSelf.tableView reloadData];
    };
    [sheet addAction:[UIAlertAction actionWithTitle:@"Default"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) { choose(0); }]];
    for (size_t i = 0; i < sizeof(kPDTThicknesses) / sizeof(kPDTThicknesses[0]); i++) {
        CGFloat value = kPDTThicknesses[i];
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%.1f pt", value]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) { choose(value); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIView *anchor = source ?: self.view;
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end

#pragma mark - Left menu page

static NSString *const kPDTLeftMenuEmpty = @"Open the left menu once to list its sections.";

// Sections the left menu showed last time, then hidden ones it no longer shows.
static NSArray<NSString *> *PDTLeftMenuSections(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray<NSString *> *sections = [NSMutableArray array];
    for (NSString *key in @[ kPrimeDitLeftMenuSections, kPrimeDitLeftMenuHidden ])
        for (id title in [defaults arrayForKey:key])
            if ([title isKindOfClass:NSString.class] && ![sections containsObject:title]) [sections addObject:title];
    return sections;
}

static BOOL PDTLeftMenuSectionHidden(NSString *title) {
    return [[NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitLeftMenuHidden] containsObject:title];
}

static NSString *PDTLeftMenuSummary(void) {
    NSUInteger hidden = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitLeftMenuHidden].count;
    return hidden ? [NSString stringWithFormat:@"%lu hidden", (unsigned long)hidden] : nil;
}

@interface PDTLeftMenuViewController : UITableViewController
@end

@implementation PDTLeftMenuViewController {
    NSArray<NSString *> *_sections;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Left menu";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _sections = PDTLeftMenuSections();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sections.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
    NSString *title = _sections[indexPath.row];
    [cell configureWithTitle:title subtitle:nil value:nil icon:nil accessory:PDTAccessorySwitch];
    cell.toggle.on = !PDTLeftMenuSectionHidden(title);
    cell.toggle.tag = indexPath.row;
    [cell.toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)_sections.count) return;
    NSString *title = _sections[sender.tag];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableArray *hidden = [NSMutableArray arrayWithArray:[defaults arrayForKey:kPrimeDitLeftMenuHidden] ?: @[]];
    [hidden removeObject:title];
    if (!sender.on) [hidden addObject:title];
    [defaults setObject:hidden forKey:kPrimeDitLeftMenuHidden];
    postPrefsUpdatedNotification();
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kPDTRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return PDTSectionHeaderView(@"Sections");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTHeaderHeight;
}

// The only text on this page: what to do while the list is still empty.
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return _sections.count ? nil : PDTSectionFooterView(kPDTLeftMenuEmpty);
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return _sections.count ? kPDTSectionGap : PDTFooterHeight(kPDTLeftMenuEmpty, tableView.bounds.size.width);
}
@end

#pragma mark - Filter list pages

// Keywords, Subreddits and Muted users: one section whose header states the rule, with the
// add field first and the saved entries after it.
@interface PDTListEditorViewController : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithTitle:(NSString *)title
                      listKey:(NSString *)listKey
                   enabledKey:(NSString *)enabledKey
                  placeholder:(NSString *)placeholder
                       header:(NSString *)header;
@end

@implementation PDTListEditorViewController {
    NSString *_listKey;
    NSString *_enabledKey;
    NSString *_placeholder;
    NSString *_header;
    NSMutableArray<NSString *> *_entries;
    UITextField *_field;
    UIButton *_addButton;
}

- (instancetype)initWithTitle:(NSString *)title
                      listKey:(NSString *)listKey
                   enabledKey:(NSString *)enabledKey
                  placeholder:(NSString *)placeholder
                       header:(NSString *)header {
    self = [super initWithStyle:UITableViewStyleGrouped];
    if (!self) return nil;
    self.title = title;
    _listKey = [listKey copy];
    _enabledKey = [enabledKey copy];
    _placeholder = [placeholder copy];
    _header = [header copy];
    _entries = [NSMutableArray array];
    for (id entry in [NSUserDefaults.standardUserDefaults arrayForKey:listKey])
        if ([entry isKindOfClass:NSString.class] && [(NSString *)entry length]) [_entries addObject:entry];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"PDTListFieldCell"];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

    _field = [[UITextField alloc] init];
    _field.font = PDTSettingsFont(17.0, NO);
    _field.textColor = PDTPrimaryColor();
    _field.attributedPlaceholder =
            [[NSAttributedString alloc] initWithString:_placeholder
                                            attributes:@{NSForegroundColorAttributeName : PDTSecondaryColor()}];
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.returnKeyType = UIReturnKeyDone;
    _field.clearButtonMode = UITextFieldViewModeWhileEditing;
    _field.delegate = self;
    _field.translatesAutoresizingMaskIntoConstraints = NO;

    _addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_addButton setImage:[UIImage systemImageNamed:@"plus.circle.fill"
                                 withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22.0]]
                forState:UIControlStateNormal];
    _addButton.tintColor = PDTPrimaryColor();
    _addButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    _addButton.accessibilityLabel = @"Add";
    [_addButton addTarget:self action:@selector(addEntries) forControlEvents:UIControlEventTouchUpInside];
    _addButton.translatesAutoresizingMaskIntoConstraints = NO;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

// Row 0 is the add field; entry i sits on row i + 1.
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1 + (NSInteger)_entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTListFieldCell" forIndexPath:indexPath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = UIColor.systemBackgroundColor;
        if (_field.superview != cell.contentView) {
            [_field removeFromSuperview];
            [_addButton removeFromSuperview];
            [cell.contentView addSubview:_field];
            [cell.contentView addSubview:_addButton];
            [NSLayoutConstraint activateConstraints:@[
                [_field.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:kPDTPlainTextInset],
                [_field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [_field.trailingAnchor constraintEqualToAnchor:_addButton.leadingAnchor constant:-8.0],
                [_addButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                                            constant:-(kPDTSwitchColumnInset - kPDTSymbolMargin)],
                [_addButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
                [_addButton.widthAnchor constraintEqualToConstant:44.0],
                [_addButton.heightAnchor constraintEqualToConstant:44.0],
              ]];
        }
        return cell;
    }
    NSString *entry = _entries[indexPath.row - 1];
    PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
    [cell configureWithTitle:entry subtitle:nil value:nil icon:nil accessory:PDTAccessoryNone];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *symbol =
            [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
    [remove setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:symbol] forState:UIControlStateNormal];
    remove.tintColor = PDTSecondaryColor();
    remove.frame = CGRectMake(0, 0, 44.0, 44.0);
    remove.accessibilityLabel = [@"Remove " stringByAppendingString:entry];
    [remove addTarget:self action:@selector(removeTapped:) forControlEvents:UIControlEventTouchUpInside];
    cell.accessoryView = remove;
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kPDTRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return PDTSectionHeaderView(_header);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return kPDTSectionGap;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row == 0) return nil;
    __weak PDTListEditorViewController *weakSelf = self;
    UIContextualAction *remove =
            [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                    title:@"Remove"
                                                  handler:^(UIContextualAction *action, UIView *sourceView,
                                                            void (^completion)(BOOL)) {
                                                      [weakSelf removeEntryAtIndexPath:indexPath];
                                                      completion(YES);
                                                  }];
    return [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self addEntries];
    return NO;
}

// Commas split a paste into several entries; blanks and duplicates are skipped.
- (void)addEntries {
    NSMutableArray<NSIndexPath *> *inserted = [NSMutableArray array];
    NSString *text = _field.text ?: @"";
    for (NSString *part in [text componentsSeparatedByString:@","]) {
        NSString *entry = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!entry.length || [_entries containsObject:entry]) continue;
        [_entries addObject:entry];
        [inserted addObject:[NSIndexPath indexPathForRow:(NSInteger)_entries.count inSection:0]];
    }
    _field.text = nil;
    if (!inserted.count) return;
    [self saveEntries];
    [self.tableView insertRowsAtIndexPaths:inserted withRowAnimation:UITableViewRowAnimationFade];
}

- (void)removeTapped:(UIButton *)sender {
    UIView *view = sender;
    while (view && ![view isKindOfClass:UITableViewCell.class]) view = view.superview;
    NSIndexPath *indexPath = view ? [self.tableView indexPathForCell:(UITableViewCell *)view] : nil;
    if (indexPath) [self removeEntryAtIndexPath:indexPath];
}

- (void)removeEntryAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row < 1 || indexPath.row > (NSInteger)_entries.count) return;
    [_entries removeObjectAtIndex:indexPath.row - 1];
    [self saveEntries];
    [self.tableView deleteRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationFade];
}

- (void)saveEntries {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:[_entries copy] forKey:_listKey];
    [defaults setBool:(_entries.count > 0) forKey:_enabledKey];
    postPrefsUpdatedNotification();
}
@end

// A filter list's value on the main page: how many entries it holds.
static NSString *PDTListValue(NSString *listKey) {
    NSUInteger count = [NSUserDefaults.standardUserDefaults arrayForKey:listKey].count;
    return count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"None";
}

#pragma mark - Launch tab

// Stored index order; Chat opens Inbox until a Chat tab exists.
static NSString *const kPDTLaunchTabNames[5] = {@"Default", @"Home", @"Inbox", @"Chat", @"You"};

static NSString *PDTLaunchTabName(void) {
    NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:kPrimeDitLaunchTab];
    return kPDTLaunchTabNames[(index >= 0 && index < 5) ? index : 0];
}

#pragma mark - Backup & reset page

static NSArray<NSString *> *PDTConfigKeys(void) {
    return @[
        kPrimeDitPromoted, kPrimeDitRecommended, kPrimeDitNSFW, kPrimeDitAwards,
        kPrimeDitScores, kPrimeDitAutoCollapseAutoMod, kPrimeDitRecommendationCarousels,
        kPrimeDitExtraFeedCards, kPrimeDitAIBoxes, kPrimeDitSpoilers, kPrimeDitHideVisitedPosts,
        kPrimeDitRemovedComments, kPrimeDitKeywordsEnabled, kPrimeDitKeywords,
        kPrimeDitSubredditsEnabled, kPrimeDitSubreddits, kPrimeDitMutedUsersEnabled,
        kPrimeDitMutedUsers, kPrimeDitHideNags, kPrimeDitThreadLinesEnabled,
        kPrimeDitThreadRainbowMode, kPrimeDitThreadDepthCycling, kPrimeDitThreadLineThickness,
        kPrimeDitThreadThemeIndex, kPrimeDitGamesTabDisabled, kPrimeDitLaunchTab,
        kPrimeDitProfileAccountSwitcher, kPrimeDitKeepFeedOnTabReturn, kPrimeDitConfirmHomeRefresh,
        kPrimeDitConfirmPullToRefresh, kPrimeDitChatTabDisabled, kPrimeDitLeftMenuHidden,
        kPrimeDitAutoClearCache, kPrimeDitKeepTabBarExpanded, kPrimeDitFlexExplorer
      ];
}

static BOOL PDTConfigValueIsValid(NSString *key, id value) {
    if ([key isEqualToString:kPrimeDitKeywords] || [key isEqualToString:kPrimeDitSubreddits] ||
            [key isEqualToString:kPrimeDitMutedUsers] || [key isEqualToString:kPrimeDitLeftMenuHidden]) {
        if (![value isKindOfClass:NSArray.class]) return NO;
        for (id entry in (NSArray *)value)
            if (![entry isKindOfClass:NSString.class]) return NO;
        return YES;
    }
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if ([key isEqualToString:kPrimeDitThreadLineThickness])
        return [value doubleValue] >= 0 && [value doubleValue] <= 3.0;
    if ([key isEqualToString:kPrimeDitThreadThemeIndex])
        return [value integerValue] >= -1 && [value integerValue] <= 14;
    if ([key isEqualToString:kPrimeDitLaunchTab]) return [value integerValue] >= 0 && [value integerValue] <= 4;
    if ([key isEqualToString:kPrimeDitAutoClearCache])
        return [value integerValue] >= 0 && [value integerValue] < PDTAutoClearCount;
    return YES;
}

static NSString *const kPDTClearCacheMessage =
        @"Clears cached images, video and feed data. Your login and PrimeDit settings are kept.";

// Auto-clear choices, the current one checked.
@interface PDTAutoClearViewController : UITableViewController
@end

@implementation PDTAutoClearViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Auto-clear";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return PDTAutoClearCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
    NSInteger current = [NSUserDefaults.standardUserDefaults integerForKey:kPrimeDitAutoClearCache];
    [cell configureWithTitle:PDTAutoClearName(indexPath.row)
                    subtitle:nil
                       value:nil
                        icon:nil
                   accessory:(indexPath.row == current ? PDTAccessoryCheck : PDTAccessoryNone)];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kPDTRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UIView *spacer = [[UIView alloc] init];
    spacer.backgroundColor = UIColor.systemBackgroundColor;
    return spacer;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTSectionGap / 2.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return kPDTSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [NSUserDefaults.standardUserDefaults setInteger:indexPath.row forKey:kPrimeDitAutoClearCache];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

@end

@interface PDTBackupViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation PDTBackupViewController {
    NSString *_cacheSize;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Backup & reset";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    [self refreshCacheSize];
}

// The size is measured off the main thread, then shown on the Clear cache row.
- (void)refreshCacheSize {
    __weak PDTBackupViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *size = PDTFormattedSize(PDTRedditCacheSize());
        dispatch_async(dispatch_get_main_queue(), ^{
            PDTBackupViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_cacheSize = size;
            [strongSelf.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:1] ]
                                        withRowAnimation:UITableViewRowAnimationNone];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 2 ? 1 : 2;
}

// Backup: import, export. Cache: clear with its size, auto-clear. Reset: defaults, in red.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
    NSInteger item = indexPath.section * 2 + indexPath.row;
    NSString *const titles[5] = {@"Import settings", @"Export settings", @"Clear cache", @"Auto-clear",
                                 @"Reset to defaults"};
    NSString *const icons[5] = {@"rpl3/import", @"rpl3/upload", @"rpl3/delete", @"rpl3/clock", @"rpl3/undo"};
    NSString *value = nil;
    if (item == 2) value = _cacheSize;
    if (item == 3)
        value = PDTAutoClearName([NSUserDefaults.standardUserDefaults integerForKey:kPrimeDitAutoClearCache]);
    [cell configureWithTitle:titles[item]
                    subtitle:nil
                       value:value
                        icon:PDTRowIcon(@[ icons[item] ])
                   accessory:(item == 3 ? PDTAccessoryChevron : PDTAccessoryNone)];
    if (item == 4) [cell setTitleColor:PDTDestructiveColor()];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kPDTRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != 1) return PDTSectionHeaderView(section == 0 ? @"Backup" : @"Reset");
    __weak PDTBackupViewController *weakSelf = self;
    return PDTSectionHeaderViewWithInfo(@"Cache", kPDTChevronColumnInset, ^{
        PDTBackupViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        PDTPresentHelpSheet(strongSelf, @"Cache", @[
            PDTHelp(@"Clear cache",
                    @"Deletes the images, videos and feed data Reddit keeps on the phone; your login and settings stay.",
                    PDTRowIcon(@[ @"rpl3/delete" ])),
            PDTHelp(@"Auto-clear", @"Clears the cache when Reddit starts, at the interval you pick.",
                    PDTRowIcon(@[ @"rpl3/clock" ])),
          ]);
    });
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return kPDTSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section * 2 + indexPath.row) {
        case 0: [self importSettings]; break;
        case 1: [self exportSettings]; break;
        case 2: [self confirmClearCache]; break;
        case 3:
            [self.navigationController
                    pushViewController:[[PDTAutoClearViewController alloc] initWithStyle:UITableViewStyleGrouped]
                              animated:YES];
            break;
        default: [self confirmReset]; break;
    }
}

- (void)importSettings {
    id jsonType = ((id(*)(id, SEL, NSString *))objc_msgSend)(
            NSClassFromString(@"UTType"), NSSelectorFromString(@"typeWithIdentifier:"), @"public.json");
    if (!jsonType) return;
    UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ jsonType ] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSData *data = urls.firstObject ? [NSData dataWithContentsOfURL:urls.firstObject] : nil;
    if (data.length == 0 || data.length > 1024 * 1024) {
        PDTPresentAlert(self, @"Import failed", @"Choose a settings file of 1 MB or less.");
        return;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) {
        PDTPresentAlert(self, @"Import failed", @"This file is not a PrimeDit settings file.");
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSUInteger applied = 0;
    for (NSString *key in PDTConfigKeys()) {
        id value = ((NSDictionary *)json)[key];
        if (value && PDTConfigValueIsValid(key, value)) {
            [defaults setObject:value forKey:key];
            applied++;
        }
    }
    postPrefsUpdatedNotification();
    PDTCOMPAT_ACTION(PDTCompatBackup, @"Imported %lu settings", (unsigned long)applied);
    PDTPresentAlert(self, @"Settings imported",
                    [NSString stringWithFormat:@"%lu settings applied.", (unsigned long)applied]);
}

- (void)exportSettings {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    for (NSString *key in PDTConfigKeys()) {
        id value = [defaults objectForKey:key];
        if (value) config[key] = value;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [dir stringByAppendingPathComponent:@"PrimeDit-Config.json"];
    BOOL written = data &&
                   [NSFileManager.defaultManager createDirectoryAtPath:dir
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:nil] &&
                   [data writeToFile:path atomically:YES];
    if (!written) {
        PDTPresentAlert(self, @"Export failed", @"The settings file could not be written.");
        return;
    }
    PDTCOMPAT_ACTION(PDTCompatBackup, @"Exported %lu settings", (unsigned long)config.count);
    UIActivityViewController *share =
            [[UIActivityViewController alloc] initWithActivityItems:@[ [NSURL fileURLWithPath:path] ]
                                              applicationActivities:nil];
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    };
    share.popoverPresentationController.sourceView = self.view;
    share.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)confirmReset {
    UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Reset to defaults"
                                                message:@"Restore every PrimeDit option to its default?"
                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak PDTBackupViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        for (NSString *key in PDTConfigKeys()) [defaults removeObjectForKey:key];
        [defaults setBool:YES forKey:kPrimeDitPromoted];
        postPrefsUpdatedNotification();
        PDTCOMPAT_ACTION(PDTCompatBackup, @"Reset to defaults");
        if (weakSelf) PDTPresentAlert(weakSelf, @"Settings reset", @"Every option is back to its default.");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearCache {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear cache"
                                                                   message:kPDTClearCacheMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak PDTBackupViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            PDTClearRedditCache();
            dispatch_async(dispatch_get_main_queue(), ^{
                PDTCOMPAT_ACTION(PDTCompatBackup, @"Cache cleared");
                PDTBackupViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf refreshCacheSize];
                PDTPresentAlert(strongSelf, @"Cache cleared", nil);
            });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

#if PRIMEDIT_DEBUG
#pragma mark - Compatibility pages

// SF Symbols at 18 pt read the same size as Reddit's 20 pt asset icons.
static const CGFloat kPDTSymbolSize = 18.0;

static UIImage *PDTSymbol(NSString *name) {
    UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:kPDTSymbolSize weight:UIImageSymbolWeightMedium];
    return [UIImage systemImageNamed:name withConfiguration:config];
}

static UIImage *PDTVerdictSymbol(PDTCompatVerdict verdict) {
    switch (verdict) {
        case PDTCompatVerdictWorking: return PDTSymbol(@"checkmark.circle");
        case PDTCompatVerdictBroken: return PDTSymbol(@"xmark.circle");
        case PDTCompatVerdictNotSeen: return PDTSymbol(@"circle.dashed");
        default: return PDTSymbol(@"minus.circle");
    }
}

static UIColor *PDTVerdictColor(PDTCompatVerdict verdict) {
    switch (verdict) {
        case PDTCompatVerdictWorking: return UIColor.systemGreenColor;
        case PDTCompatVerdictBroken: return UIColor.systemRedColor;
        default: return UIColor.tertiaryLabelColor;
    }
}

static NSInteger PDTBrokenCount(NSArray<PDTCompatResult *> *results) {
    NSInteger broken = 0;
    for (PDTCompatResult *result in results)
        if (result.verdict == PDTCompatVerdictBroken) broken++;
    return broken;
}

// Report row: verdict symbol in the icon column, the name, then what was recorded
// on as many lines as it takes; a button copies an address when there is one.
@interface PDTReportCell : UITableViewCell
- (void)configureWithResult:(PDTCompatResult *)result;
@end

@implementation PDTReportCell {
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_detailLabel;
    UIButton *_button;
    NSLayoutConstraint *_textToButton;
    NSLayoutConstraint *_textToEdge;
    NSString *_clipboardText;
    NSString *_clipboardTitle;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.systemBackgroundColor;

    _iconView = [[UIImageView alloc] init];
    _iconView.contentMode = UIViewContentModeCenter;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.font = PDTSettingsFont(17.0, NO);
    _titleLabel.numberOfLines = 0;
    _detailLabel = [[UILabel alloc] init];
    _detailLabel.font = PDTSettingsFont(12.0, NO);
    _detailLabel.numberOfLines = 0;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _detailLabel ]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2.0;
    text.translatesAutoresizingMaskIntoConstraints = NO;

    UIButtonConfiguration *config = [UIButtonConfiguration grayButtonConfiguration];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.buttonSize = UIButtonConfigurationSizeSmall;
    config.baseForegroundColor = PDTPrimaryColor();
    config.titleTextAttributesTransformer =
            ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
                NSMutableDictionary<NSAttributedStringKey, id> *updated = [attributes mutableCopy];
                updated[NSFontAttributeName] = PDTSettingsFont(13.0, YES);
                return updated;
            };
    _button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    [_button addTarget:self action:@selector(putOnClipboard) forControlEvents:UIControlEventTouchUpInside];
    [_button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _button.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *content = self.contentView;
    [content addSubview:_iconView];
    [content addSubview:text];
    [content addSubview:_button];
    NSLayoutConstraint *minHeight = [content.heightAnchor constraintGreaterThanOrEqualToConstant:kPDTRowHeight];
    minHeight.priority = UILayoutPriorityRequired - 1;
    _textToButton = [text.trailingAnchor constraintLessThanOrEqualToAnchor:_button.leadingAnchor constant:-12.0];
    _textToEdge = [text.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-20.0];
    [NSLayoutConstraint activateConstraints:@[
        minHeight,
        _textToEdge,
        [_iconView.centerXAnchor constraintEqualToAnchor:content.leadingAnchor constant:kPDTIconCenterX],
        [_iconView.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:24.0],
        [_iconView.heightAnchor constraintEqualToConstant:24.0],
        [text.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kPDTTextInset],
        [text.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:11.0],
        [text.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-11.0],
        [text.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
        [_button.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-kPDTChevronColumnInset],
        [_button.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
      ]];
    return self;
}

- (void)configureWithResult:(PDTCompatResult *)result {
    _iconView.image = PDTVerdictSymbol(result.verdict);
    _iconView.tintColor = PDTVerdictColor(result.verdict);
    _titleLabel.text = result.title;
    _titleLabel.textColor = result.verdict == PDTCompatVerdictOff ? PDTSecondaryColor() : PDTPrimaryColor();
    _detailLabel.text = result.detail;
    _detailLabel.hidden = result.detail.length == 0;
    _detailLabel.textColor = result.verdict == PDTCompatVerdictBroken ? UIColor.systemRedColor : PDTSecondaryColor();
    _clipboardText = [result.clipboardText copy];
    _clipboardTitle = [result.clipboardTitle copy];
    BOOL copyable = _clipboardText.length > 0;
    [self setButtonTitle:_clipboardTitle];
    _button.hidden = !copyable;
    _textToButton.active = copyable;
    _textToEdge.active = !copyable;
}

- (void)setButtonTitle:(NSString *)title {
    UIButtonConfiguration *config = _button.configuration;
    config.title = title;
    _button.configuration = config;
}

- (void)putOnClipboard {
    if (!_clipboardText.length) return;
    UIPasteboard.generalPasteboard.string = _clipboardText;
    NSString *title = _clipboardTitle;
    [self setButtonTitle:@"Copied"];
    __weak PDTReportCell *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        PDTReportCell *cell = weakSelf;
        if (cell && [cell->_clipboardTitle isEqualToString:title]) [cell setButtonTitle:title];
    });
}
@end

static UIView *PDTReportCount(NSInteger count, NSString *label, UIColor *color) {
    UILabel *number = [[UILabel alloc] init];
    number.font = PDTSettingsFont(20.0, YES);
    number.textColor = color;
    number.textAlignment = NSTextAlignmentCenter;
    number.text = [NSString stringWithFormat:@"%ld", (long)count];
    UILabel *caption = [[UILabel alloc] init];
    caption.font = PDTSettingsFont(11.0, NO);
    caption.textColor = PDTSecondaryColor();
    caption.textAlignment = NSTextAlignmentCenter;
    caption.text = label;
    UIView *tile = [[UIView alloc] init];
    tile.backgroundColor = UIColor.secondarySystemBackgroundColor;
    tile.layer.cornerRadius = 10.0;
    for (UILabel *text in @[ number, caption ]) {
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [tile addSubview:text];
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
            [text.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
          ]];
    }
    [NSLayoutConstraint activateConstraints:@[
        [tile.heightAnchor constraintEqualToConstant:58.0],
        [number.topAnchor constraintEqualToAnchor:tile.topAnchor constant:8.0],
        [number.heightAnchor constraintEqualToConstant:24.0],
        [caption.topAnchor constraintEqualToAnchor:tile.topAnchor constant:34.0],
        [caption.heightAnchor constraintEqualToConstant:14.0],
      ]];
    return tile;
}

// Report summary: a centered verdict disc, headline and recording line, then one tile per verdict.
static UIView *PDTReportSummaryView(NSArray<PDTCompatResult *> *results) {
    NSInteger counts[4] = {0, 0, 0, 0};
    for (PDTCompatResult *result in results)
        if (result.verdict >= PDTCompatVerdictOff && result.verdict <= PDTCompatVerdictBroken) counts[result.verdict]++;
    NSInteger broken = counts[PDTCompatVerdictBroken];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    UIColor *tone = broken ? UIColor.systemRedColor : UIColor.systemGreenColor;

    UIView *disc = [[UIView alloc] init];
    disc.backgroundColor = [tone colorWithAlphaComponent:0.14];
    disc.layer.cornerRadius = 30.0;
    disc.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *markSize =
            [UIImageSymbolConfiguration configurationWithPointSize:26.0 weight:UIImageSymbolWeightBold];
    UIImageView *mark =
            [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(broken ? @"xmark" : @"checkmark")
                                                        withConfiguration:markSize]];
    mark.tintColor = tone;
    mark.translatesAutoresizingMaskIntoConstraints = NO;
    [disc addSubview:mark];

    UILabel *headline = [[UILabel alloc] init];
    headline.font = PDTSettingsFont(17.0, YES);
    headline.textColor = PDTPrimaryColor();
    headline.textAlignment = NSTextAlignmentCenter;
    headline.numberOfLines = 0;
    headline.text = broken ? [NSString stringWithFormat:@"%ld problem%@ with Reddit %@", (long)broken,
                                                        broken == 1 ? @"" : @"s", version]
                           : [NSString stringWithFormat:@"Compatible with Reddit %@", version];
    UILabel *subline = [[UILabel alloc] init];
    subline.font = PDTSettingsFont(12.0, NO);
    subline.textColor = PDTSecondaryColor();
    subline.textAlignment = NSTextAlignmentCenter;
    subline.numberOfLines = 0;
    subline.text = [NSString stringWithFormat:@"iOS %@ \u00b7 %@", UIDevice.currentDevice.systemVersion,
                                              PDTCompatRecordingText()];

    UIStackView *tiles = [[UIStackView alloc] initWithArrangedSubviews:@[
        PDTReportCount(broken, @"Broken", broken ? UIColor.systemRedColor : PDTSecondaryColor()),
        PDTReportCount(counts[PDTCompatVerdictWorking], @"Working", UIColor.systemGreenColor),
        PDTReportCount(counts[PDTCompatVerdictNotSeen], @"Not seen", PDTPrimaryColor()),
        PDTReportCount(counts[PDTCompatVerdictOff], @"Off", UIColor.tertiaryLabelColor),
      ]];
    tiles.distribution = UIStackViewDistributionFillEqually;
    tiles.spacing = 8.0;

    UIStackView *all = [[UIStackView alloc] initWithArrangedSubviews:@[ disc, headline, subline, tiles ]];
    all.axis = UILayoutConstraintAxisVertical;
    all.alignment = UIStackViewAlignmentCenter;
    [all setCustomSpacing:12.0 afterView:disc];
    [all setCustomSpacing:2.0 afterView:headline];
    [all setCustomSpacing:14.0 afterView:subline];
    all.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *container = [[UIView alloc] init];
    container.backgroundColor = UIColor.systemBackgroundColor;
    [container addSubview:all];
    [NSLayoutConstraint activateConstraints:@[
        [disc.widthAnchor constraintEqualToConstant:60.0],
        [disc.heightAnchor constraintEqualToConstant:60.0],
        [mark.centerXAnchor constraintEqualToAnchor:disc.centerXAnchor],
        [mark.centerYAnchor constraintEqualToAnchor:disc.centerYAnchor],
        [headline.widthAnchor constraintEqualToAnchor:all.widthAnchor],
        [subline.widthAnchor constraintEqualToAnchor:all.widthAnchor],
        [tiles.widthAnchor constraintEqualToAnchor:all.widthAnchor],
        [all.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
        [all.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:kPDTPlainTextInset],
        [all.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-kPDTPlainTextInset],
        [all.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12.0],
      ]];
    return container;
}

// Report: summary, one section per settings section, then Reddit data; Start over,
// under Session, clears the session and the address counters.
@implementation PDTCompatibilityReportViewController {
    NSArray<NSString *> *_sections;
    NSArray<NSArray<PDTCompatResult *> *> *_rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Report";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
    [self.tableView registerClass:PDTReportCell.class forCellReuseIdentifier:@"PDTReportCell"];
    self.tableView.estimatedRowHeight = kPDTRowHeightWithSubtitle;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Copy"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(putReportOnClipboard)];
    if (self.navigationController.viewControllers.count <= 1)
        self.navigationItem.leftBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                              target:self
                                                              action:@selector(dismissReport)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadReport];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self sizeSummary];
}

- (void)reloadReport {
    NSArray<PDTCompatResult *> *results = PDTCompatResults();
    NSMutableArray<NSString *> *sections = [NSMutableArray array];
    NSMutableArray<NSMutableArray<PDTCompatResult *> *> *rows = [NSMutableArray array];
    for (PDTCompatResult *result in results) {
        if (![sections.lastObject isEqualToString:result.section]) {
            [sections addObject:result.section];
            [rows addObject:[NSMutableArray array]];
        }
        [rows.lastObject addObject:result];
    }
    _sections = sections;
    _rows = rows;
    self.tableView.tableHeaderView = PDTReportSummaryView(results);
    [self sizeSummary];
    [self.tableView reloadData];
}

// The summary is laid out with constraints; the table needs its height as a frame.
- (void)sizeSummary {
    UIView *summary = self.tableView.tableHeaderView;
    CGFloat width = self.tableView.bounds.size.width;
    if (!summary || width <= 0) return;
    CGSize size = [summary systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                         withHorizontalFittingPriority:UILayoutPriorityRequired
                               verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    if (fabs(summary.frame.size.width - width) < 0.5 && fabs(summary.frame.size.height - size.height) < 0.5) return;
    summary.frame = CGRectMake(0, 0, width, ceil(size.height));
    self.tableView.tableHeaderView = summary;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)_sections.count + 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section < (NSInteger)_sections.count ? (NSInteger)_rows[section].count : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)_sections.count) {
        PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
        [cell configureWithTitle:@"Start over"
                        subtitle:nil
                           value:nil
                            icon:PDTRowIcon(@[ @"rpl3/refresh" ])
                       accessory:PDTAccessoryNone];
        [cell setTitleColor:PDTDestructiveColor()];
        return cell;
    }
    PDTReportCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTReportCell" forIndexPath:indexPath];
    [cell configureWithResult:_rows[indexPath.section][indexPath.row]];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section < (NSInteger)_sections.count ? UITableViewAutomaticDimension : kPDTRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return PDTSectionHeaderView(section < (NSInteger)_sections.count ? _sections[section] : @"Session");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return kPDTSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section >= (NSInteger)_sections.count) [self confirmStartOver];
}

- (void)confirmStartOver {
    UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:@"Start over"
                                                message:@"Clears what this session recorded. Your settings are kept."
                                         preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak PDTCompatibilityReportViewController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Start over"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                                PDTCompatReset();
                                                [[PDTDataPathTracker shared] reset];
                                                [weakSelf reloadReport];
                                            }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)putReportOnClipboard {
    UIPasteboard.generalPasteboard.string = PDTCompatReportText();
    UIBarButtonItem *button = self.navigationItem.rightBarButtonItem;
    button.title = @"Copied";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        button.title = @"Copy";
    });
}

- (void)dismissReport {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

// Compatibility: record while using Reddit, then read the report.
@interface PDTCompatibilityViewController : UITableViewController
@end

@implementation PDTCompatibilityViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Compatibility";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
    if (self.navigationController.viewControllers.count <= 1)
        self.navigationItem.rightBarButtonItem =
                [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                              target:self
                                                              action:@selector(dismissPage)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
    if (indexPath.row == 0) {
        [cell configureWithTitle:@"Record activity"
                        subtitle:nil
                           value:nil
                            icon:PDTSymbol(@"stethoscope")
                       accessory:PDTAccessorySwitch];
        cell.toggle.on = PDTCompatActive;
        [cell.toggle addTarget:self action:@selector(toggleRecording:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    // Problems first, then whether recording is on.
    NSInteger broken = PDTBrokenCount(PDTCompatResults());
    NSString *status = broken ? [NSString stringWithFormat:@"%ld broken", (long)broken]
                              : PDTCompatActive ? @"Compatible"
                                           : @"Not recording";
    [cell configureWithTitle:@"Report"
                    subtitle:nil
                       value:status
                        icon:PDTSymbol(@"list.bullet.rectangle")
                   accessory:PDTAccessoryChevron];
    [cell setValueColor:broken ? UIColor.systemRedColor : PDTCompatActive ? UIColor.systemGreenColor : PDTSecondaryColor()];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return kPDTRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    __weak PDTCompatibilityViewController *weakSelf = self;
    return PDTSectionHeaderViewWithInfo(@"Session", kPDTSwitchColumnInset, ^{
        [weakSelf showHelp];
    });
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return kPDTSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row != 1) return;
    [self.navigationController
            pushViewController:[[PDTCompatibilityReportViewController alloc] initWithStyle:UITableViewStyleGrouped]
                      animated:YES];
}

- (void)toggleRecording:(UISwitch *)sender {
    PDTCompatSetRecording(sender.on);
    [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:1 inSection:0] ]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)showHelp {
    PDTPresentHelpSheet(self, @"Session", @[
        PDTHelp(@"Record activity",
                @"Watches what every option does while you use Reddit. The stethoscope opens the report anytime.",
                PDTSymbol(@"stethoscope")),
        PDTHelp(@"Report", @"Every option and every Reddit data address, marked Broken, Working, Not seen or Off.",
                PDTSymbol(@"list.bullet.rectangle")),
      ]);
}

- (void)dismissPage {
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end
#endif

#pragma mark - Main settings page

@interface PDTRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSArray<NSString *> *icons;
@property(nonatomic, copy) NSString *key;
@property(nonatomic) BOOL shownWhenOn;
@property(nonatomic) BOOL fallback;
@property(nonatomic) SEL action;
@end

@implementation PDTRow
@end

// Filter rows read ON = shown and store the inverse ("hide"); behavior rows
// store what the switch shows. `fallback` is the stored value when unset.
static PDTRow *PDTToggleRow(NSString *title, NSString *subtitle, NSArray<NSString *> *icons, NSString *key,
                            BOOL shownWhenOn, BOOL fallback) {
    PDTRow *row = [[PDTRow alloc] init];
    row.title = title;
    row.subtitle = subtitle;
    row.icons = icons;
    row.key = key;
    row.shownWhenOn = shownWhenOn;
    row.fallback = fallback;
    return row;
}

static PDTRow *PDTLinkRow(NSString *title, NSString *subtitle, NSString *value, NSArray<NSString *> *icons,
                          SEL action) {
    PDTRow *row = [[PDTRow alloc] init];
    row.title = title;
    row.subtitle = subtitle;
    row.value = value;
    row.icons = icons;
    row.action = action;
    return row;
}

static BOOL PDTRowIsOn(PDTRow *row) {
    BOOL stored = PDTPrefBool(row.key, row.fallback);
    return row.shownWhenOn ? !stored : stored;
}

static char kPDTSectionsKey;

// A %new method reached through [self ...] needs a visible declaration; this
// category provides them.
@interface PDTSettingsViewController (PDTNative)
- (NSArray *)pdSections;
- (void)pdRebuildSections;
- (PDTRow *)pdRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)pdToggleChanged:(UISwitch *)sender;
- (void)pdPushController:(UIViewController *)controller;
- (void)pdShowHelpForSection:(NSInteger)section;
- (void)pdEditKeywords;
- (void)pdEditSubreddits;
- (void)pdEditMutedUsers;
- (void)pdOpenThreadLines;
- (void)pdOpenLeftMenu;
- (void)pdOpenBackup;
- (void)pdOpenCompatibility;
- (void)pdChooseLaunchTab;
@end

// Titles: a noun where the switch shows something, a verb where it makes something
// happen. Help names a row by its key and adds one sentence for the info sheet.
static NSArray *PDTBuildMainSections(void) {
    NSMutableArray *tools = [NSMutableArray
            arrayWithObject:PDTLinkRow(@"Backup & reset", nil, nil, @[ @"rpl3/backup", @"rpl3/archive" ],
                                       @selector(pdOpenBackup))];
#if PRIMEDIT_DEBUG
    [tools addObject:PDTLinkRow(@"Compatibility", nil, nil, @[ @"rpl3/verified" ], @selector(pdOpenCompatibility))];
#endif
    [tools addObject:PDTToggleRow(@"FLEX explorer", nil, @[ @"rpl3/bug" ], kPrimeDitFlexExplorer, NO, NO)];
    return @[
        @{
            @"title" : @"Feed",
            @"rows" : @[
                PDTToggleRow(@"Promoted", nil, @[ @"rpl3/ad" ], kPrimeDitPromoted, YES, YES),
                PDTToggleRow(@"Recommended", nil, @[ @"rpl3/star" ], kPrimeDitRecommended, YES, NO),
                PDTToggleRow(@"Community recommendations", nil, @[ @"rpl3/communities" ],
                             kPrimeDitRecommendationCarousels, YES, NO),
                PDTToggleRow(@"Suggestion cards", nil, @[ @"rpl3/card" ], kPrimeDitExtraFeedCards, YES, NO),
                PDTToggleRow(@"AI answers & summaries", nil, @[ @"rpl3/answers", @"rpl3/ai" ], kPrimeDitAIBoxes, YES,
                             NO),
                PDTToggleRow(@"NSFW", nil, @[ @"rpl3/nsfw" ], kPrimeDitNSFW, YES, NO),
                PDTToggleRow(@"Spoilers", nil, @[ @"rpl3/hide", @"rpl3/caution" ], kPrimeDitSpoilers, YES, NO),
                PDTToggleRow(@"Visited posts", nil, @[ @"rpl3/show", @"rpl3/clock" ], kPrimeDitHideVisitedPosts, YES,
                             NO),
              ],
            @"help" : @[
                @[
                    kPrimeDitRecommended,
                    @"Posts Reddit adds from communities you don\u2019t follow, like \u201CBecause you visited\u2026\u201D."
                  ],
                @[
                    kPrimeDitExtraFeedCards,
                    @"Cards between posts: related posts, trending topics, AMAs and chat channels."
                  ],
                @[ kPrimeDitAIBoxes, @"Reddit Answers boxes and AI-written summaries." ],
                @[ kPrimeDitHideVisitedPosts, @"Posts you\u2019ve already opened. Home feed only." ],
              ],
        },
        @{
            @"title" : @"Filter lists",
            @"rows" : @[
                PDTLinkRow(@"Keywords", nil, PDTListValue(kPrimeDitKeywords), @[ @"rpl3/keyword" ],
                           @selector(pdEditKeywords)),
                PDTLinkRow(@"Subreddits", nil, PDTListValue(kPrimeDitSubreddits), @[ @"rpl3/community" ],
                           @selector(pdEditSubreddits)),
                PDTLinkRow(@"Muted users", nil, PDTListValue(kPrimeDitMutedUsers), @[ @"rpl3/block" ],
                           @selector(pdEditMutedUsers)),
              ]
        },
        @{
            @"title" : @"Posts & comments",
            @"rows" : @[
                PDTToggleRow(@"Awards", nil, @[ @"rpl3/award" ], kPrimeDitAwards, YES, NO),
                PDTToggleRow(@"Vote counts", nil, @[ @"rpl3/upvote" ], kPrimeDitScores, YES, NO),
              ]
        },
        @{
            @"title" : @"Comments",
            @"rows" : @[
                PDTToggleRow(@"Deleted & removed comments", nil, @[ @"rpl3/delete" ], kPrimeDitRemovedComments, YES,
                             NO),
                PDTToggleRow(@"Collapse AutoMod comments", nil, @[ @"rpl3/autoMod" ], kPrimeDitAutoCollapseAutoMod, NO,
                             NO),
                PDTLinkRow(@"Comment thread lines", nil, PDTThreadLinesSummary(), @[ @"rpl3/branch", @"rpl3/comment" ],
                           @selector(pdOpenThreadLines)),
              ],
            @"help" : @[ @[
                kPrimeDitAutoCollapseAutoMod, @"AutoModerator is the bot moderators set up; its comments start folded."
              ] ],
        },
        @{
            @"title" : @"Interface",
            @"rows" : @[
                PDTToggleRow(@"Pop-ups & nudges", nil, @[ @"rpl3/lightbulb" ], kPrimeDitHideNags, YES, NO),
                PDTLinkRow(@"Left menu", nil, PDTLeftMenuSummary(), @[ @"rpl3/menu" ], @selector(pdOpenLeftMenu)),
              ],
            @"help" : @[ @[
                kPrimeDitHideNags,
                @"Tooltips, Reddit Pro offers, nudges to post and prompts to turn on notifications."
              ] ],
        },
        @{
            @"title" : @"Tabs",
            @"rows" : @[
                PDTToggleRow(@"Chat tab", nil, @[ @"rpl3/chat", @"rpl3/message" ], kPrimeDitChatTabDisabled, YES, YES),
                PDTToggleRow(@"Games tab", nil, @[ @"rpl3/gameController" ], kPrimeDitGamesTabDisabled, YES, NO),
                PDTLinkRow(@"Launch tab", nil, PDTLaunchTabName(), @[ @"rpl3/rocket", @"rpl3/home" ],
                           @selector(pdChooseLaunchTab)),
                PDTToggleRow(@"Account switcher", nil, @[ @"rpl3/users", @"rpl3/user" ], kPrimeDitProfileAccountSwitcher, NO,
                             YES),
                PDTToggleRow(@"Compact tab bar", nil, @[ @"rpl3/collapseRight" ], kPrimeDitKeepTabBarExpanded, YES, NO),
              ],
            @"help" : @[
                @[ kPrimeDitChatTabDisabled, @"Chat gets its own tab; Inbox keeps your notifications." ],
                @[ kPrimeDitProfileAccountSwitcher, @"Long-press the You tab to switch accounts." ],
                @[ kPrimeDitKeepTabBarExpanded, @"Reddit shrinks the tab bar as you scroll." ],
              ],
        },
        @{
            @"title" : @"Refresh",
            @"rows" : @[
                PDTToggleRow(@"Remember Home position", nil, @[ @"rpl3/pin", @"rpl3/home" ],
                             kPrimeDitKeepFeedOnTabReturn, NO, NO),
                PDTToggleRow(@"Confirm Home refresh", nil, @[ @"rpl3/refresh" ], kPrimeDitConfirmHomeRefresh, NO, NO),
                PDTToggleRow(@"Confirm pull to refresh", nil, @[ @"rpl3/swipeDown", @"rpl3/refresh" ],
                             kPrimeDitConfirmPullToRefresh, NO, NO),
              ],
            @"help" : @[
                @[ kPrimeDitKeepFeedOnTabReturn, @"Coming back to Home keeps your place instead of reloading the feed." ],
                @[
                    kPrimeDitConfirmHomeRefresh,
                    @"Tapping Home while you\u2019re on it reloads the feed. This asks you first."
                  ],
              ],
        },
        @{@"title" : @"Tools", @"rows" : tools},
      ];
}

%subclass PDTSettingsViewController : BaseTableViewController
%new
- (NSArray *)pdSections {
    NSArray *sections = objc_getAssociatedObject(self, &kPDTSectionsKey);
    if (!sections) {
        sections = PDTBuildMainSections();
        objc_setAssociatedObject(self, &kPDTSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return sections;
}
%new
- (void)pdRebuildSections {
    objc_setAssociatedObject(self, &kPDTSectionsKey, PDTBuildMainSections(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.tableView reloadData];
}
%new
- (PDTRow *)pdRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *sections = [self pdSections];
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)sections.count) return nil;
    NSArray *rows = sections[indexPath.section][@"rows"];
    return (indexPath.row >= 0 && indexPath.row < (NSInteger)rows.count) ? rows[indexPath.row] : nil;
}
%new
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self pdSections].count;
}
%new
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *sections = [self pdSections];
    return (section >= 0 && section < (NSInteger)sections.count) ? [sections[section][@"rows"] count] : 0;
}
%new
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PDTSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDTSettingsCell" forIndexPath:indexPath];
    PDTRow *row = [self pdRowAtIndexPath:indexPath];
    BOOL isToggle = row.key != nil;
    [cell configureWithTitle:row.title
                    subtitle:row.subtitle
                       value:row.value
                        icon:PDTRowIcon(row.icons)
                   accessory:(isToggle ? PDTAccessorySwitch : PDTAccessoryChevron)];
    if (isToggle) {
        cell.toggle.on = PDTRowIsOn(row);
        cell.toggle.tag = indexPath.section * 100 + indexPath.row;
        [cell.toggle addTarget:self action:@selector(pdToggleChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return cell;
}
%new
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self pdRowAtIndexPath:indexPath].subtitle.length ? kPDTRowHeightWithSubtitle : kPDTRowHeight;
}
%new
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSArray *sections = [self pdSections];
    if (section < 0 || section >= (NSInteger)sections.count) return nil;
    NSDictionary *info = sections[section];
    void (^onInfo)(void) = nil;
    if ([info[@"help"] count]) {
        __weak PDTSettingsViewController *weakSelf = self;
        onInfo = ^{
            [weakSelf pdShowHelpForSection:section];
        };
    }
    return PDTSectionHeaderViewWithInfo(info[@"title"], kPDTSwitchColumnInset, onInfo);
}
%new
- (void)pdShowHelpForSection:(NSInteger)section {
    NSArray *sections = [self pdSections];
    if (section < 0 || section >= (NSInteger)sections.count) return;
    NSDictionary *info = sections[section];
    NSMutableArray<PDTHelpItem *> *items = [NSMutableArray array];
    for (NSArray *entry in info[@"help"])
        for (PDTRow *row in info[@"rows"])
            if ([row.key isEqualToString:entry[0]]) [items addObject:PDTHelp(row.title, entry[1], PDTRowIcon(row.icons))];
    PDTPresentHelpSheet(self, info[@"title"], items);
}
%new
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return kPDTHeaderHeight;
}
%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return section == (NSInteger)[self pdSections].count - 1 ? kPDTLinkFooterHeight : kPDTSectionGap;
}
%new
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section != (NSInteger)[self pdSections].count - 1) return nil;
    return PDTHowItWorksFooter(self, @selector(pdShowHowItWorks));
}
%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PDTRow *row = [self pdRowAtIndexPath:indexPath];
    if (!row.action || ![self respondsToSelector:row.action]) return;
    ((void (*)(id, SEL))[self methodForSelector:row.action])(self, row.action);
}
- (void)viewDidLoad {
    %orig;
    self.title = @"PrimeDit";
    self.navigationItem.rightBarButtonItem = PDTDoneItem(self, @selector(pdDone));
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    PDTStyleSettingsTable(self.tableView);
    self.tableView.tableFooterView = PDTCreditFooter();
}
// Closes Reddit's settings when they are a sheet, and steps back otherwise.
%new
- (void)pdDone {
    UINavigationController *navigation = self.navigationController;
    if (navigation.presentingViewController)
        [navigation dismissViewControllerAnimated:YES completion:nil];
    else
        [navigation popViewControllerAnimated:YES];
}
// How the switches and lists read, for anyone who wonders.
%new
- (void)pdShowHowItWorks {
    PDTPresentHelpSheet(self, @"How it works", @[
        PDTHelp(@"Reddit features", @"On: as in Reddit. Off: removed by PrimeDit.", PDTSymbol(@"eye")),
        PDTHelp(@"PrimeDit features", @"On: added by PrimeDit. Off: as in Reddit.", PDTSymbol(@"sparkles")),
        PDTHelp(@"Filter lists", @"Hide what matches a keyword, a subreddit or a muted user.",
                PDTSymbol(@"line.3.horizontal.decrease.circle")),
    ]);
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [self pdRebuildSections];
}
%new
- (void)pdToggleChanged:(UISwitch *)sender {
    PDTRow *row = [self pdRowAtIndexPath:[NSIndexPath indexPathForRow:sender.tag % 100 inSection:sender.tag / 100]];
    if (!row.key) return;
    [NSUserDefaults.standardUserDefaults setBool:(row.shownWhenOn ? !sender.on : sender.on) forKey:row.key];
    postPrefsUpdatedNotification();
}
%new
- (void)pdPushController:(UIViewController *)controller {
    if (self.navigationController) {
        [self.navigationController pushViewController:controller animated:YES];
    } else {
        [self presentViewController:[[UINavigationController alloc] initWithRootViewController:controller]
                           animated:YES
                         completion:nil];
    }
}
%new
- (void)pdOpenThreadLines {
    [self pdPushController:[[PDTThreadLinesViewController alloc] initWithStyle:UITableViewStyleGrouped]];
}
%new
- (void)pdOpenLeftMenu {
    [self pdPushController:[[PDTLeftMenuViewController alloc] initWithStyle:UITableViewStyleGrouped]];
}
%new
- (void)pdOpenBackup {
    [self pdPushController:[[PDTBackupViewController alloc] initWithStyle:UITableViewStyleGrouped]];
}
%new
- (void)pdOpenCompatibility {
#if PRIMEDIT_DEBUG
    [self pdPushController:[[PDTCompatibilityViewController alloc] initWithStyle:UITableViewStyleGrouped]];
#endif
}
%new
- (void)pdChooseLaunchTab {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Launch tab"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak PDTSettingsViewController *weakSelf = self;
    for (NSInteger i = 0; i < 5; i++) {
        [sheet addAction:[UIAlertAction actionWithTitle:kPDTLaunchTabNames[i]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            [NSUserDefaults.standardUserDefaults setInteger:i forKey:kPrimeDitLaunchTab];
            postPrefsUpdatedNotification();
            [weakSelf pdRebuildSections];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
            CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1.0, 1.0);
    [self presentViewController:sheet animated:YES completion:nil];
}
%new
- (void)pdEditKeywords {
    [self pdPushController:[[PDTListEditorViewController alloc]
                               initWithTitle:@"Keywords"
                                     listKey:kPrimeDitKeywords
                                  enabledKey:kPrimeDitKeywordsEnabled
                                 placeholder:@"Add a keyword"
                                      header:@"Hide posts and comments with"]];
}
%new
- (void)pdEditSubreddits {
    [self pdPushController:[[PDTListEditorViewController alloc] initWithTitle:@"Subreddits"
                                                                      listKey:kPrimeDitSubreddits
                                                                   enabledKey:kPrimeDitSubredditsEnabled
                                                                  placeholder:@"Add a subreddit"
                                                                      header:@"Hide posts from"]];
}
%new
- (void)pdEditMutedUsers {
    [self pdPushController:[[PDTListEditorViewController alloc]
                               initWithTitle:@"Muted users"
                                     listKey:kPrimeDitMutedUsers
                                  enabledKey:kPrimeDitMutedUsersEnabled
                                 placeholder:@"Add a username"
                                      header:@"Hide posts and comments from"]];
}
%end
