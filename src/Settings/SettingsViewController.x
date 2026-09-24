#import <CoreFoundation/CoreFoundation.h>
#import "SettingsViewController.h"
#import "DataPaths.h"
#import "Cache.h"
#import "Compatibility.h"

extern UIImage *iconWithName(NSString *iconName);
extern NSArray<UIColor *> *PDPaletteColors(NSInteger index);

// Tells every hook that an option changed.
static void postPrefsUpdatedNotification(void) {
  CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                       CFSTR(kPrimeDitPrefsNotification), NULL, NULL, true);
}

// Reddit asset icons are scaled to 20 pt in settings rows.
static const CGFloat kPDIconSize = 20.0;

#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Native settings styling

// Metrics measured on Reddit 2026.38's own Settings screen (3 px = 1 pt).
static const CGFloat kPDRowHeight = 48.0;
static const CGFloat kPDRowHeightWithSubtitle = 64.0;
static const CGFloat kPDHeaderHeight = 32.0;
static const CGFloat kPDSectionGap = 16.0;
static const CGFloat kPDIconCenterX = 32.0;
static const CGFloat kPDTextInset = 57.0;
static const CGFloat kPDPlainTextInset = 20.0;
// Right edges measured on settings rows: switches at 12.0 pt, chevrons and checks
// at 20.7 pt. Info buttons and trailing buttons sit on the same columns.
static const CGFloat kPDSwitchColumnInset = 12.0;
static const CGFloat kPDChevronColumnInset = 20.7;
// Transparent margin measured on the right of the 17 pt info.circle image.
static const CGFloat kPDSymbolMargin = 2.0;
// Raises the info circle so its bottom sits on the header's baseline (measured 6.0 pt low).
static const CGFloat kPDInfoLift = 6.0;
// Added under the last section so the last row ends 42.7 pt above the screen
// bottom, like the last line of native Settings (measured).
static const CGFloat kPDBottomSpace = 12.4;

static UIFont *PDSettingsFont(CGFloat size, BOOL bold) {
  UIFont *font = [UIFont fontWithName:(bold ? @"RedditSans-Bold" : @"RedditSans-Regular") size:size];
  return font ?: [UIFont systemFontOfSize:size weight:(bold ? UIFontWeightBold : UIFontWeightRegular)];
}

static UIColor *PDHexColor(uint32_t hex) {
  return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                         green:((hex >> 8) & 0xFF) / 255.0
                          blue:(hex & 0xFF) / 255.0
                         alpha:1.0];
}

// Light values are measured on Reddit; dark mode falls back to system colors.
static UIColor *PDDynamicColor(uint32_t lightHex, UIColor *dark) {
  UIColor *light = PDHexColor(lightHex);
  return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
    return traits.userInterfaceStyle == UIUserInterfaceStyleDark
               ? [dark resolvedColorWithTraitCollection:traits]
               : light;
  }];
}

static UIColor *PDPrimaryColor(void) {
  static UIColor *color;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ color = PDDynamicColor(0x181B1E, UIColor.labelColor); });
  return color;
}

static UIColor *PDSecondaryColor(void) {
  static UIColor *color;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ color = PDDynamicColor(0x5F6B73, UIColor.secondaryLabelColor); });
  return color;
}

// Reddit's destructive red, measured on native "Delete account".
static UIColor *PDDestructiveColor(void) {
  static UIColor *color;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ color = PDDynamicColor(0xAC2322, UIColor.systemRedColor); });
  return color;
}

// Info buttons as pale next to their header as Instagram's (measured), in Reddit's cool gray.
static UIColor *PDInfoColor(void) {
  static UIColor *color;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ color = PDDynamicColor(0x9FA9B0, UIColor.systemGray2Color); });
  return color;
}

static UIColor *PDSwitchOnColor(void) {
  static UIColor *color;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ color = PDDynamicColor(0x000000, UIColor.systemGreenColor); });
  return color;
}

static void PDPresentAlert(UIViewController *presenter, NSString *title, NSString *message) {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  [presenter presentViewController:alert animated:YES completion:nil];
}

typedef NS_ENUM(NSInteger, PDAccessory) {
  PDAccessoryNone,
  PDAccessorySwitch,
  PDAccessoryChevron,
  PDAccessoryCheck,
};

// Settings row laid out to the native metrics: 24 pt icon box centered at
// x = 32, text from x = 57, switch 14 pt from the trailing edge.
@interface PDSettingsCell : UITableViewCell
@property(nonatomic, strong, readonly) UISwitch *toggle;
- (void)configureWithTitle:(NSString *)title
                  subtitle:(NSString *)subtitle
                     value:(NSString *)value
                      icon:(UIImage *)icon
                 accessory:(PDAccessory)accessory;
- (void)showSwatches:(NSArray<UIColor *> *)colors;
- (void)setValueColor:(UIColor *)color;
- (void)setTitleColor:(UIColor *)color;
@end

@implementation PDSettingsCell {
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
  _iconView.tintColor = PDPrimaryColor();
  _iconView.translatesAutoresizingMaskIntoConstraints = NO;

  _titleLabel = [[UILabel alloc] init];
  _titleLabel.font = PDSettingsFont(17.0, NO);
  _titleLabel.textColor = PDPrimaryColor();

  _subtitleLabel = [[UILabel alloc] init];
  _subtitleLabel.font = PDSettingsFont(12.0, NO);
  _subtitleLabel.textColor = PDSecondaryColor();

  UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _subtitleLabel ]];
  text.axis = UILayoutConstraintAxisVertical;
  text.spacing = 2.0;
  text.translatesAutoresizingMaskIntoConstraints = NO;

  _valueLabel = [[UILabel alloc] init];
  _valueLabel.font = PDSettingsFont(16.0, NO);
  _valueLabel.textColor = PDPrimaryColor();
  [_valueLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
  [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];

  _toggle = [[UISwitch alloc] init];
  _toggle.onTintColor = PDSwitchOnColor();

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
                                                    constant:kPDTextInset];
  _trailingInset = [trailing.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor
                                                           constant:-20.0];
  [NSLayoutConstraint activateConstraints:@[
    [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kPDIconCenterX],
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
                 accessory:(PDAccessory)accessory {
  [self showSwatches:nil];
  _titleLabel.text = title;
  _titleLabel.textColor = PDPrimaryColor();
  _iconView.tintColor = PDPrimaryColor();
  _subtitleLabel.text = subtitle;
  _subtitleLabel.hidden = subtitle.length == 0;
  _valueLabel.text = value;
  _valueLabel.hidden = value.length == 0;
  _valueLabel.textColor = PDPrimaryColor();
  _iconView.image = icon;
  _iconView.hidden = icon == nil;
  _textLeading.constant = icon ? kPDTextInset : kPDPlainTextInset;

  _toggle.hidden = accessory != PDAccessorySwitch;
  _markView.hidden = accessory != PDAccessoryChevron && accessory != PDAccessoryCheck;
  if (accessory == PDAccessoryChevron) {
    _markView.image = [UIImage systemImageNamed:@"chevron.right"
                              withConfiguration:[UIImageSymbolConfiguration
                                                    configurationWithPointSize:14.0
                                                                        weight:UIImageSymbolWeightSemibold]];
    _markView.tintColor = PDSecondaryColor();
  } else if (accessory == PDAccessoryCheck) {
    _markView.image = [UIImage systemImageNamed:@"checkmark"
                              withConfiguration:[UIImageSymbolConfiguration
                                                    configurationWithPointSize:15.0
                                                                        weight:UIImageSymbolWeightSemibold]];
    _markView.tintColor = PDPrimaryColor();
  }
  _trailingInset.constant = accessory == PDAccessorySwitch ? -14.0 : -20.0;
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
static UIFont *PDHeaderFont(void) {
  return [UIFont fontWithName:@"RedditSans-SemiBold" size:13.0] ?: PDSettingsFont(13.0, YES);
}

// Section header in caps at x = 20, baseline 4.5 pt above the bottom; when the
// section has help, an info button on the given column, its circle on the baseline.
static UIView *PDSectionHeaderViewWithInfo(NSString *title, CGFloat column, void (^onInfo)(void)) {
  UIView *container = [[UIView alloc] init];
  container.backgroundColor = UIColor.systemBackgroundColor;
  UILabel *label = [[UILabel alloc] init];
  label.attributedText = [[NSAttributedString alloc] initWithString:title.uppercaseString
                                                         attributes:@{
                                                           NSFontAttributeName : PDHeaderFont(),
                                                           NSForegroundColorAttributeName : PDSecondaryColor(),
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
    info.tintColor = PDInfoColor();
    info.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    info.accessibilityLabel = [@"About " stringByAppendingString:title];
    [info addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
      onInfo();
    }]
        forControlEvents:UIControlEventTouchUpInside];
    info.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:info];
    [constraints addObjectsFromArray:@[
      [info.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-(column - kPDSymbolMargin)],
      [info.centerYAnchor constraintEqualToAnchor:label.centerYAnchor constant:-kPDInfoLift],
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

static UIView *PDSectionHeaderView(NSString *title) {
  return PDSectionHeaderViewWithInfo(title, 0, nil);
}

static UIView *PDSectionFooterView(NSString *text) {
  UIView *container = [[UIView alloc] init];
  container.backgroundColor = UIColor.systemBackgroundColor;
  UILabel *label = [[UILabel alloc] init];
  label.font = PDSettingsFont(12.0, NO);
  label.textColor = PDSecondaryColor();
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

static CGFloat PDFooterHeight(NSString *text, CGFloat width) {
  CGRect bounds = [text boundingRectWithSize:CGSizeMake(MAX(width - 41.0, 1.0), CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName : PDSettingsFont(12.0, NO)}
                                     context:nil];
  return ceil(bounds.size.height) + 6.0 + kPDSectionGap;
}

static void PDStyleSettingsTable(UITableView *tableView) {
  tableView.backgroundColor = UIColor.systemBackgroundColor;
  tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
  tableView.sectionHeaderTopPadding = 0;
  tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kPDBottomSpace)];
  [tableView registerClass:PDSettingsCell.class forCellReuseIdentifier:@"PDSettingsCell"];
}

static UIImage *PDRowIcon(NSArray<NSString *> *names) {
  for (NSString *name in names) {
    UIImage *image = iconWithName(name);
    if (image)
      return [[image imageScaledToSize:CGSizeMake(kPDIconSize, kPDIconSize)]
          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  }
  return nil;
}

#pragma mark - Help sheet

@interface PDHelpItem : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) UIImage *icon;
@end

@implementation PDHelpItem
@end

static PDHelpItem *PDHelp(NSString *title, NSString *text, UIImage *icon) {
  PDHelpItem *item = [[PDHelpItem alloc] init];
  item.title = title;
  item.text = text;
  item.icon = icon;
  return item;
}

static const CGFloat kPDHelpTitleTop = 26.0;
static const CGFloat kPDHelpListGap = 26.0;
static const CGFloat kPDHelpBottom = 28.0;
static const CGFloat kPDHelpSideInset = 24.0;

// One option in a help sheet: its icon, its name in bold, then a sentence.
static UIView *PDHelpRow(PDHelpItem *item) {
  UILabel *name = [[UILabel alloc] init];
  name.font = PDSettingsFont(17.0, YES);
  name.textColor = PDPrimaryColor();
  name.numberOfLines = 0;
  name.text = item.title;
  UILabel *text = [[UILabel alloc] init];
  text.font = PDSettingsFont(15.0, NO);
  text.textColor = PDSecondaryColor();
  text.numberOfLines = 0;
  text.text = item.text;
  UIStackView *words = [[UIStackView alloc] initWithArrangedSubviews:@[ name, text ]];
  words.axis = UILayoutConstraintAxisVertical;
  words.spacing = 3.0;
  UIImageView *icon = [[UIImageView alloc] initWithImage:item.icon];
  icon.tintColor = PDPrimaryColor();
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
@interface PDHelpSheetViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title items:(NSArray<PDHelpItem *> *)items;
- (CGFloat)fittingHeightForWidth:(CGFloat)width;
@end

@implementation PDHelpSheetViewController {
  NSString *_sheetTitle;
  NSArray<PDHelpItem *> *_items;
  UILabel *_titleLabel;
  UIStackView *_list;
}

- (instancetype)initWithTitle:(NSString *)title items:(NSArray<PDHelpItem *> *)items {
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
  _titleLabel.font = PDSettingsFont(17.0, YES);
  _titleLabel.textColor = PDPrimaryColor();
  _titleLabel.textAlignment = NSTextAlignmentCenter;
  _titleLabel.text = _sheetTitle;
  _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

  UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
  UIImageSymbolConfiguration *symbol =
      [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightSemibold];
  [close setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:symbol] forState:UIControlStateNormal];
  close.tintColor = PDPrimaryColor();
  close.backgroundColor = UIColor.tertiarySystemFillColor;
  close.layer.cornerRadius = 20.0;
  close.accessibilityLabel = @"Close";
  [close addTarget:self action:@selector(closeSheet) forControlEvents:UIControlEventTouchUpInside];
  close.translatesAutoresizingMaskIntoConstraints = NO;

  _list = [[UIStackView alloc] init];
  _list.axis = UILayoutConstraintAxisVertical;
  _list.spacing = 22.0;
  _list.translatesAutoresizingMaskIntoConstraints = NO;
  for (PDHelpItem *item in _items) [_list addArrangedSubview:PDHelpRow(item)];

  [self.view addSubview:_titleLabel];
  [self.view addSubview:close];
  [self.view addSubview:_list];
  [NSLayoutConstraint activateConstraints:@[
    [_titleLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kPDHelpTitleTop],
    [_titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:64.0],
    [close.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
    [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16.0],
    [close.widthAnchor constraintEqualToConstant:40.0],
    [close.heightAnchor constraintEqualToConstant:40.0],
    [_list.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:kPDHelpListGap],
    [_list.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kPDHelpSideInset],
    [_list.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kPDHelpSideInset],
  ]];
}

- (void)closeSheet {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (CGFloat)fittingHeightForWidth:(CGFloat)width {
  [self loadViewIfNeeded];
  CGSize list = [_list systemLayoutSizeFittingSize:CGSizeMake(width - 2.0 * kPDHelpSideInset,
                                                              UILayoutFittingCompressedSize.height)
                     withHorizontalFittingPriority:UILayoutPriorityRequired
                           verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
  return kPDHelpTitleTop + ceil(_titleLabel.font.lineHeight) + kPDHelpListGap + ceil(list.height) + kPDHelpBottom;
}
@end

// Presents the sheet at the height of its content.
static void PDPresentHelpSheet(UIViewController *presenter, NSString *title, NSArray<PDHelpItem *> *items) {
  if (!presenter || !items.count) return;
  PDHelpSheetViewController *sheet = [[PDHelpSheetViewController alloc] initWithTitle:title items:items];
  sheet.modalPresentationStyle = UIModalPresentationPageSheet;
  UISheetPresentationController *controller = sheet.sheetPresentationController;
  CGFloat width = presenter.view.bounds.size.width;
  __weak PDHelpSheetViewController *weakSheet = sheet;
  controller.detents = @[ [UISheetPresentationControllerDetent
      customDetentWithIdentifier:@"PDHelpSheet"
                        resolver:^CGFloat(id<UISheetPresentationControllerDetentResolutionContext> context) {
                          return MIN([weakSheet fittingHeightForWidth:width], context.maximumDetentValue);
                        }] ];
  controller.prefersGrabberVisible = YES;
  [presenter presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Comment thread lines page

// Palette names in MoesReddit's stored index order; -1 keeps Reddit's color.
static NSString *const kPDPaletteNames[15] = {
    @"Sunset", @"Cyberpunk", @"Synthwave", @"Matrix", @"Nord", @"Dracula", @"Gruvbox", @"Tokyo Night",
    @"Rose Pine", @"Solarized", @"Neon", @"Ocean", @"Pastel", @"Mono", @"Rainbow"};
static const NSInteger kPDPaletteOrder[16] = {-1, 14, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13};
static const CGFloat kPDThicknesses[6] = {0.5, 1.0, 1.5, 2.0, 2.5, 3.0};

static NSString *PDPaletteName(NSInteger index) {
  return (index >= 0 && index < 15) ? kPDPaletteNames[index] : @"Original";
}

static NSInteger PDCurrentPaletteIndex(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  return [defaults objectForKey:kPrimeDitThreadThemeIndex]
             ? [defaults integerForKey:kPrimeDitThreadThemeIndex]
             : -1;
}

static NSString *PDThicknessLabel(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  float value = [defaults floatForKey:kPrimeDitThreadLineThickness];
  return ([defaults objectForKey:kPrimeDitThreadLineThickness] && value > 0)
             ? [NSString stringWithFormat:@"%.1f pt", value]
             : @"Default";
}

static NSString *PDThreadLinesSummary(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  if (![defaults boolForKey:kPrimeDitThreadLinesEnabled]) return @"Off";
  if ([defaults boolForKey:kPrimeDitThreadRainbowMode]) return @"Random";
  return PDPaletteName(PDCurrentPaletteIndex());
}

// Line coloring, stored as MoesReddit's rainbow and depth-cycling switches.
typedef NS_ENUM(NSInteger, PDLineColoring) {
  PDLineColoringByDepth,
  PDLineColoringSingle,
  PDLineColoringRandom,
};

static NSString *const kPDColoringTitles[3] = {@"By depth", @"Single color", @"Random"};
static NSString *const kPDColoringHelp[3] = {@"Each reply level takes the next color of the palette.",
                                             @"Every line takes the palette\u2019s first color.",
                                             @"Each line gets its own random color. No palette needed."};
static NSString *const kPDColoringSymbols[3] = {@"list.bullet.indent", @"minus", @"shuffle"};

static PDLineColoring PDCurrentColoring(void) {
  if ([NSUserDefaults.standardUserDefaults boolForKey:kPrimeDitThreadRainbowMode]) return PDLineColoringRandom;
  return PDPrefBool(kPrimeDitThreadDepthCycling, YES) ? PDLineColoringByDepth : PDLineColoringSingle;
}

static void PDSetColoring(PDLineColoring coloring) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  [defaults setBool:(coloring == PDLineColoringRandom) forKey:kPrimeDitThreadRainbowMode];
  if (coloring != PDLineColoringRandom)
    [defaults setBool:(coloring == PDLineColoringByDepth) forKey:kPrimeDitThreadDepthCycling];
  postPrefsUpdatedNotification();
}

@interface PDThreadLinesViewController : UITableViewController
@end

@implementation PDThreadLinesViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Comment thread lines";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  PDStyleSettingsTable(self.tableView);
}

// Lines, Coloring and Palette; Random coloring has no use for a palette.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return PDCurrentColoring() == PDLineColoringRandom ? 2 : 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 0 ? 2 : section == 1 ? 3 : 16;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
  if (indexPath.section == 2) {
    NSInteger index = kPDPaletteOrder[indexPath.row];
    [cell configureWithTitle:PDPaletteName(index)
                    subtitle:nil
                       value:nil
                        icon:nil
                   accessory:(index == PDCurrentPaletteIndex() ? PDAccessoryCheck : PDAccessoryNone)];
    [cell showSwatches:PDPaletteColors(index)];
    return cell;
  }
  if (indexPath.section == 1) {
    [cell configureWithTitle:kPDColoringTitles[indexPath.row]
                    subtitle:nil
                       value:nil
                        icon:nil
                   accessory:(indexPath.row == PDCurrentColoring() ? PDAccessoryCheck : PDAccessoryNone)];
    return cell;
  }
  if (indexPath.row == 1) {
    [cell configureWithTitle:@"Thickness"
                    subtitle:nil
                       value:PDThicknessLabel()
                        icon:nil
                   accessory:PDAccessoryChevron];
    return cell;
  }
  [cell configureWithTitle:@"Color lines" subtitle:nil value:nil icon:nil accessory:PDAccessorySwitch];
  cell.toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:kPrimeDitThreadLinesEnabled];
  [cell.toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
  return cell;
}

- (void)toggleChanged:(UISwitch *)sender {
  [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:kPrimeDitThreadLinesEnabled];
  postPrefsUpdatedNotification();
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return kPDRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  if (section != 1) return PDSectionHeaderView(section == 0 ? @"Lines" : @"Palette");
  __weak PDThreadLinesViewController *weakSelf = self;
  return PDSectionHeaderViewWithInfo(@"Coloring", kPDChevronColumnInset, ^{
    [weakSelf showColoringHelp];
  });
}

- (void)showColoringHelp {
  NSMutableArray<PDHelpItem *> *items = [NSMutableArray array];
  for (NSInteger i = 0; i < 3; i++) {
    UIImage *icon = [UIImage systemImageNamed:kPDColoringSymbols[i]
                            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17.0]];
    [items addObject:PDHelp(kPDColoringTitles[i], kPDColoringHelp[i], icon)];
  }
  PDPresentHelpSheet(self, @"Coloring", items);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return kPDSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == 2) {
    [NSUserDefaults.standardUserDefaults setInteger:kPDPaletteOrder[indexPath.row]
                                             forKey:kPrimeDitThreadThemeIndex];
    postPrefsUpdatedNotification();
    [tableView reloadData];
  } else if (indexPath.section == 1) {
    [self chooseColoring:(PDLineColoring)indexPath.row];
  } else if (indexPath.row == 1) {
    [self chooseThicknessFromView:[tableView cellForRowAtIndexPath:indexPath]];
  }
}

// The palette section fades out with Random and back in with the other two.
- (void)chooseColoring:(PDLineColoring)coloring {
  BOOL hadPalette = PDCurrentColoring() != PDLineColoringRandom;
  PDSetColoring(coloring);
  BOOL hasPalette = coloring != PDLineColoringRandom;
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
  __weak PDThreadLinesViewController *weakSelf = self;
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
  for (size_t i = 0; i < sizeof(kPDThicknesses) / sizeof(kPDThicknesses[0]); i++) {
    CGFloat value = kPDThicknesses[i];
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

static NSString *const kPDLeftMenuEmpty = @"Open the left menu once to list its sections.";

// Sections the left menu showed last time, then hidden ones it no longer shows.
static NSArray<NSString *> *PDLeftMenuSections(void) {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSMutableArray<NSString *> *sections = [NSMutableArray array];
  for (NSString *key in @[ kPrimeDitLeftMenuSections, kPrimeDitLeftMenuHidden ])
    for (id title in [defaults arrayForKey:key])
      if ([title isKindOfClass:NSString.class] && ![sections containsObject:title]) [sections addObject:title];
  return sections;
}

static BOOL PDLeftMenuSectionHidden(NSString *title) {
  return [[NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitLeftMenuHidden] containsObject:title];
}

static NSString *PDLeftMenuSummary(void) {
  NSUInteger hidden = [NSUserDefaults.standardUserDefaults arrayForKey:kPrimeDitLeftMenuHidden].count;
  return hidden ? [NSString stringWithFormat:@"%lu hidden", (unsigned long)hidden] : nil;
}

@interface PDLeftMenuViewController : UITableViewController
@end

@implementation PDLeftMenuViewController {
  NSArray<NSString *> *_sections;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Left menu";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  PDStyleSettingsTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  _sections = PDLeftMenuSections();
  [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return _sections.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
  NSString *title = _sections[indexPath.row];
  [cell configureWithTitle:title subtitle:nil value:nil icon:nil accessory:PDAccessorySwitch];
  cell.toggle.on = !PDLeftMenuSectionHidden(title);
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
  return kPDRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  return PDSectionHeaderView(@"Sections");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDHeaderHeight;
}

// The only text on this page: what to do while the list is still empty.
- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
  return _sections.count ? nil : PDSectionFooterView(kPDLeftMenuEmpty);
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return _sections.count ? kPDSectionGap : PDFooterHeight(kPDLeftMenuEmpty, tableView.bounds.size.width);
}
@end

#pragma mark - Filter list pages

// Keywords, Subreddits and Muted users: one section whose header states the rule, with the
// add field first and the saved entries after it.
@interface PDListEditorViewController : UITableViewController <UITextFieldDelegate>
- (instancetype)initWithTitle:(NSString *)title
                      listKey:(NSString *)listKey
                   enabledKey:(NSString *)enabledKey
                  placeholder:(NSString *)placeholder
                       header:(NSString *)header;
@end

@implementation PDListEditorViewController {
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
  PDStyleSettingsTable(self.tableView);
  [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"PDListFieldCell"];
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;

  _field = [[UITextField alloc] init];
  _field.font = PDSettingsFont(17.0, NO);
  _field.textColor = PDPrimaryColor();
  _field.attributedPlaceholder =
      [[NSAttributedString alloc] initWithString:_placeholder
                                      attributes:@{NSForegroundColorAttributeName : PDSecondaryColor()}];
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
  _addButton.tintColor = PDPrimaryColor();
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
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDListFieldCell" forIndexPath:indexPath];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = UIColor.systemBackgroundColor;
    if (_field.superview != cell.contentView) {
      [_field removeFromSuperview];
      [_addButton removeFromSuperview];
      [cell.contentView addSubview:_field];
      [cell.contentView addSubview:_addButton];
      [NSLayoutConstraint activateConstraints:@[
        [_field.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:kPDPlainTextInset],
        [_field.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [_field.trailingAnchor constraintEqualToAnchor:_addButton.leadingAnchor constant:-8.0],
        [_addButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor
                                                    constant:-(kPDSwitchColumnInset - kPDSymbolMargin)],
        [_addButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [_addButton.widthAnchor constraintEqualToConstant:44.0],
        [_addButton.heightAnchor constraintEqualToConstant:44.0],
      ]];
    }
    return cell;
  }
  NSString *entry = _entries[indexPath.row - 1];
  PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
  [cell configureWithTitle:entry subtitle:nil value:nil icon:nil accessory:PDAccessoryNone];
  cell.selectionStyle = UITableViewCellSelectionStyleNone;
  UIButton *remove = [UIButton buttonWithType:UIButtonTypeSystem];
  UIImageSymbolConfiguration *symbol =
      [UIImageSymbolConfiguration configurationWithPointSize:14.0 weight:UIImageSymbolWeightSemibold];
  [remove setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:symbol] forState:UIControlStateNormal];
  remove.tintColor = PDSecondaryColor();
  remove.frame = CGRectMake(0, 0, 44.0, 44.0);
  remove.accessibilityLabel = [@"Remove " stringByAppendingString:entry];
  [remove addTarget:self action:@selector(removeTapped:) forControlEvents:UIControlEventTouchUpInside];
  cell.accessoryView = remove;
  return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return kPDRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  return PDSectionHeaderView(_header);
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return kPDSectionGap;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.row == 0) return nil;
  __weak PDListEditorViewController *weakSelf = self;
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
static NSString *PDListValue(NSString *listKey) {
  NSUInteger count = [NSUserDefaults.standardUserDefaults arrayForKey:listKey].count;
  return count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : @"None";
}

#pragma mark - Launch tab

// Stored index order matches MoesReddit; Chat opens Inbox until a Chat tab exists.
static NSString *const kPDLaunchTabNames[5] = {@"Default", @"Home", @"Inbox", @"Chat", @"You"};

static NSString *PDLaunchTabName(void) {
  NSInteger index = [NSUserDefaults.standardUserDefaults integerForKey:kPrimeDitLaunchTab];
  return kPDLaunchTabNames[(index >= 0 && index < 5) ? index : 0];
}

#pragma mark - Backup & reset page

static NSArray<NSString *> *PDConfigKeys(void) {
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
    kPrimeDitAutoClearCache, kPrimeDitKeepTabBarExpanded
  ];
}

static BOOL PDConfigValueIsValid(NSString *key, id value) {
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
    return [value integerValue] >= 0 && [value integerValue] < PDAutoClearCount;
  return YES;
}

static NSString *const kPDClearCacheMessage =
    @"Clears cached images, video and feed data. Your login and PrimeDit settings are kept.";

// Auto-clear choices, the current one checked.
@interface PDAutoClearViewController : UITableViewController
@end

@implementation PDAutoClearViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Auto-clear";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  PDStyleSettingsTable(self.tableView);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return PDAutoClearCount;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
  NSInteger current = [NSUserDefaults.standardUserDefaults integerForKey:kPrimeDitAutoClearCache];
  [cell configureWithTitle:PDAutoClearName(indexPath.row)
                  subtitle:nil
                     value:nil
                      icon:nil
                 accessory:(indexPath.row == current ? PDAccessoryCheck : PDAccessoryNone)];
  return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return kPDRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  UIView *spacer = [[UIView alloc] init];
  spacer.backgroundColor = UIColor.systemBackgroundColor;
  return spacer;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDSectionGap / 2.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return kPDSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [NSUserDefaults.standardUserDefaults setInteger:indexPath.row forKey:kPrimeDitAutoClearCache];
  [tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}

@end

@interface PDBackupViewController : UITableViewController <UIDocumentPickerDelegate>
@end

@implementation PDBackupViewController {
  NSString *_cacheSize;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Backup & reset";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  PDStyleSettingsTable(self.tableView);
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.tableView reloadData];
  [self refreshCacheSize];
}

// The size is measured off the main thread, then shown on the Clear cache row.
- (void)refreshCacheSize {
  __weak PDBackupViewController *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *size = PDFormattedSize(PDRedditCacheSize());
    dispatch_async(dispatch_get_main_queue(), ^{
      PDBackupViewController *strongSelf = weakSelf;
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
  PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
  NSInteger item = indexPath.section * 2 + indexPath.row;
  NSString *const titles[5] = {@"Import settings", @"Export settings", @"Clear cache", @"Auto-clear",
                               @"Reset to defaults"};
  NSString *const icons[5] = {@"rpl3/import", @"rpl3/upload", @"rpl3/delete", @"rpl3/clock", @"rpl3/undo"};
  NSString *value = nil;
  if (item == 2) value = _cacheSize;
  if (item == 3)
    value = PDAutoClearName([NSUserDefaults.standardUserDefaults integerForKey:kPrimeDitAutoClearCache]);
  [cell configureWithTitle:titles[item]
                  subtitle:nil
                     value:value
                      icon:PDRowIcon(@[ icons[item] ])
                 accessory:(item == 3 ? PDAccessoryChevron : PDAccessoryNone)];
  if (item == 4) [cell setTitleColor:PDDestructiveColor()];
  return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return kPDRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  if (section != 1) return PDSectionHeaderView(section == 0 ? @"Backup" : @"Reset");
  __weak PDBackupViewController *weakSelf = self;
  return PDSectionHeaderViewWithInfo(@"Cache", kPDChevronColumnInset, ^{
    PDBackupViewController *strongSelf = weakSelf;
    if (!strongSelf) return;
    PDPresentHelpSheet(strongSelf, @"Cache", @[
      PDHelp(@"Clear cache",
             @"Deletes the images, videos and feed data Reddit keeps on the phone; your login and settings stay.",
             PDRowIcon(@[ @"rpl3/delete" ])),
      PDHelp(@"Auto-clear", @"Clears the cache when Reddit starts, at the interval you pick.",
             PDRowIcon(@[ @"rpl3/clock" ])),
    ]);
  });
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return kPDSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  switch (indexPath.section * 2 + indexPath.row) {
    case 0: [self importSettings]; break;
    case 1: [self exportSettings]; break;
    case 2: [self confirmClearCache]; break;
    case 3:
      [self.navigationController
          pushViewController:[[PDAutoClearViewController alloc] initWithStyle:UITableViewStyleGrouped]
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
    PDPresentAlert(self, @"Import failed", @"Choose a settings file of 1 MB or less.");
    return;
  }
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![json isKindOfClass:NSDictionary.class]) {
    PDPresentAlert(self, @"Import failed", @"This file is not a PrimeDit settings file.");
    return;
  }
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSUInteger applied = 0;
  for (NSString *key in PDConfigKeys()) {
    id value = ((NSDictionary *)json)[key];
    if (value && PDConfigValueIsValid(key, value)) {
      [defaults setObject:value forKey:key];
      applied++;
    }
  }
  postPrefsUpdatedNotification();
  PDCOMPAT_ACTION(PDCompatBackup, @"Imported %lu settings", (unsigned long)applied);
  PDPresentAlert(self, @"Settings imported",
                 [NSString stringWithFormat:@"%lu settings applied.", (unsigned long)applied]);
}

- (void)exportSettings {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  NSMutableDictionary *config = [NSMutableDictionary dictionary];
  for (NSString *key in PDConfigKeys()) {
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
    PDPresentAlert(self, @"Export failed", @"The settings file could not be written.");
    return;
  }
  PDCOMPAT_ACTION(PDCompatBackup, @"Exported %lu settings", (unsigned long)config.count);
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
  __weak PDBackupViewController *weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Reset"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in PDConfigKeys()) [defaults removeObjectForKey:key];
    [defaults setBool:YES forKey:kPrimeDitPromoted];
    postPrefsUpdatedNotification();
    PDCOMPAT_ACTION(PDCompatBackup, @"Reset to defaults");
    if (weakSelf) PDPresentAlert(weakSelf, @"Settings reset", @"Every option is back to its default.");
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClearCache {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear cache"
                                                                 message:kPDClearCacheMessage
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak PDBackupViewController *weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      PDClearRedditCache();
      dispatch_async(dispatch_get_main_queue(), ^{
        PDCOMPAT_ACTION(PDCompatBackup, @"Cache cleared");
        PDBackupViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshCacheSize];
        PDPresentAlert(strongSelf, @"Cache cleared", nil);
      });
    });
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}
@end

#if PRIMEDIT_DEBUG
#pragma mark - Compatibility pages

// SF Symbols at 18 pt read the same size as Reddit's 20 pt asset icons.
static const CGFloat kPDSymbolSize = 18.0;

static UIImage *PDSymbol(NSString *name) {
  UIImageSymbolConfiguration *config =
      [UIImageSymbolConfiguration configurationWithPointSize:kPDSymbolSize weight:UIImageSymbolWeightMedium];
  return [UIImage systemImageNamed:name withConfiguration:config];
}

static UIImage *PDVerdictSymbol(PDCompatVerdict verdict) {
  switch (verdict) {
    case PDCompatVerdictWorking: return PDSymbol(@"checkmark.circle");
    case PDCompatVerdictBroken: return PDSymbol(@"xmark.circle");
    case PDCompatVerdictNotSeen: return PDSymbol(@"circle.dashed");
    default: return PDSymbol(@"minus.circle");
  }
}

static UIColor *PDVerdictColor(PDCompatVerdict verdict) {
  switch (verdict) {
    case PDCompatVerdictWorking: return UIColor.systemGreenColor;
    case PDCompatVerdictBroken: return UIColor.systemRedColor;
    default: return UIColor.tertiaryLabelColor;
  }
}

static NSInteger PDBrokenCount(NSArray<PDCompatResult *> *results) {
  NSInteger broken = 0;
  for (PDCompatResult *result in results)
    if (result.verdict == PDCompatVerdictBroken) broken++;
  return broken;
}

// Report row: verdict symbol in the icon column, the name, then what was recorded
// on as many lines as it takes; a button copies an address when there is one.
@interface PDReportCell : UITableViewCell
- (void)configureWithResult:(PDCompatResult *)result;
@end

@implementation PDReportCell {
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
  _titleLabel.font = PDSettingsFont(17.0, NO);
  _titleLabel.numberOfLines = 0;
  _detailLabel = [[UILabel alloc] init];
  _detailLabel.font = PDSettingsFont(12.0, NO);
  _detailLabel.numberOfLines = 0;
  UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _detailLabel ]];
  text.axis = UILayoutConstraintAxisVertical;
  text.spacing = 2.0;
  text.translatesAutoresizingMaskIntoConstraints = NO;

  UIButtonConfiguration *config = [UIButtonConfiguration grayButtonConfiguration];
  config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  config.buttonSize = UIButtonConfigurationSizeSmall;
  config.baseForegroundColor = PDPrimaryColor();
  config.titleTextAttributesTransformer =
      ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary<NSAttributedStringKey, id> *updated = [attributes mutableCopy];
        updated[NSFontAttributeName] = PDSettingsFont(13.0, YES);
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
  NSLayoutConstraint *minHeight = [content.heightAnchor constraintGreaterThanOrEqualToConstant:kPDRowHeight];
  minHeight.priority = UILayoutPriorityRequired - 1;
  _textToButton = [text.trailingAnchor constraintLessThanOrEqualToAnchor:_button.leadingAnchor constant:-12.0];
  _textToEdge = [text.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-20.0];
  [NSLayoutConstraint activateConstraints:@[
    minHeight,
    _textToEdge,
    [_iconView.centerXAnchor constraintEqualToAnchor:content.leadingAnchor constant:kPDIconCenterX],
    [_iconView.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
    [_iconView.widthAnchor constraintEqualToConstant:24.0],
    [_iconView.heightAnchor constraintEqualToConstant:24.0],
    [text.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:kPDTextInset],
    [text.topAnchor constraintGreaterThanOrEqualToAnchor:content.topAnchor constant:11.0],
    [text.bottomAnchor constraintLessThanOrEqualToAnchor:content.bottomAnchor constant:-11.0],
    [text.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    [_button.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-kPDChevronColumnInset],
    [_button.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
  ]];
  return self;
}

- (void)configureWithResult:(PDCompatResult *)result {
  _iconView.image = PDVerdictSymbol(result.verdict);
  _iconView.tintColor = PDVerdictColor(result.verdict);
  _titleLabel.text = result.title;
  _titleLabel.textColor = result.verdict == PDCompatVerdictOff ? PDSecondaryColor() : PDPrimaryColor();
  _detailLabel.text = result.detail;
  _detailLabel.hidden = result.detail.length == 0;
  _detailLabel.textColor = result.verdict == PDCompatVerdictBroken ? UIColor.systemRedColor : PDSecondaryColor();
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
  __weak PDReportCell *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    PDReportCell *cell = weakSelf;
    if (cell && [cell->_clipboardTitle isEqualToString:title]) [cell setButtonTitle:title];
  });
}
@end

static UIView *PDReportCount(NSInteger count, NSString *label, UIColor *color) {
  UILabel *number = [[UILabel alloc] init];
  number.font = PDSettingsFont(17.0, YES);
  number.textColor = color;
  number.text = [NSString stringWithFormat:@"%ld", (long)count];
  UILabel *caption = [[UILabel alloc] init];
  caption.font = PDSettingsFont(12.0, NO);
  caption.textColor = PDSecondaryColor();
  caption.text = label;
  UIStackView *tile = [[UIStackView alloc] initWithArrangedSubviews:@[ number, caption ]];
  tile.axis = UILayoutConstraintAxisVertical;
  tile.spacing = 1.0;
  tile.layoutMarginsRelativeArrangement = YES;
  tile.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(8.0, 10.0, 8.0, 10.0);
  tile.backgroundColor = UIColor.secondarySystemBackgroundColor;
  tile.layer.cornerRadius = 10.0;
  return tile;
}

// Report summary: verdict disc and headline for this Reddit version, then one
// tile per verdict.
static UIView *PDReportSummaryView(NSArray<PDCompatResult *> *results) {
  NSInteger counts[4] = {0, 0, 0, 0};
  for (PDCompatResult *result in results)
    if (result.verdict >= PDCompatVerdictOff && result.verdict <= PDCompatVerdictBroken) counts[result.verdict]++;
  NSInteger broken = counts[PDCompatVerdictBroken];
  NSInteger working = counts[PDCompatVerdictWorking];
  NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
  UIColor *tone = broken ? UIColor.systemRedColor : UIColor.systemGreenColor;

  UIView *disc = [[UIView alloc] init];
  disc.backgroundColor = [tone colorWithAlphaComponent:0.14];
  disc.layer.cornerRadius = 20.0;
  disc.translatesAutoresizingMaskIntoConstraints = NO;
  UIImageSymbolConfiguration *markSize =
      [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightBold];
  UIImageView *mark =
      [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(broken ? @"xmark" : @"checkmark")
                                                  withConfiguration:markSize]];
  mark.tintColor = tone;
  mark.translatesAutoresizingMaskIntoConstraints = NO;
  [disc addSubview:mark];

  UILabel *headline = [[UILabel alloc] init];
  headline.font = PDSettingsFont(17.0, YES);
  headline.textColor = PDPrimaryColor();
  headline.numberOfLines = 0;
  headline.text = broken ? [NSString stringWithFormat:@"%ld problem%@ with Reddit %@", (long)broken,
                                                      broken == 1 ? @"" : @"s", version]
                         : [NSString stringWithFormat:@"Compatible with Reddit %@", version];
  UILabel *subline = [[UILabel alloc] init];
  subline.font = PDSettingsFont(12.0, NO);
  subline.textColor = PDSecondaryColor();
  subline.numberOfLines = 0;
  subline.text = [NSString stringWithFormat:@"iOS %@ \u00b7 %@", UIDevice.currentDevice.systemVersion,
                                            PDCompatRecordingText()];
  UIStackView *words = [[UIStackView alloc] initWithArrangedSubviews:@[ headline, subline ]];
  words.axis = UILayoutConstraintAxisVertical;
  words.spacing = 2.0;
  UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[ disc, words ]];
  top.alignment = UIStackViewAlignmentCenter;
  top.spacing = 12.0;

  UIStackView *tiles = [[UIStackView alloc] initWithArrangedSubviews:@[
    PDReportCount(broken, @"Broken", broken ? UIColor.systemRedColor : PDSecondaryColor()),
    PDReportCount(working, @"Working", working ? UIColor.systemGreenColor : PDSecondaryColor()),
    PDReportCount(counts[PDCompatVerdictNotSeen], @"Not seen", PDPrimaryColor()),
    PDReportCount(counts[PDCompatVerdictOff], @"Off", UIColor.tertiaryLabelColor),
  ]];
  tiles.distribution = UIStackViewDistributionFillEqually;
  tiles.spacing = 8.0;

  UIStackView *all = [[UIStackView alloc] initWithArrangedSubviews:@[ top, tiles ]];
  all.axis = UILayoutConstraintAxisVertical;
  all.spacing = 16.0;
  all.translatesAutoresizingMaskIntoConstraints = NO;
  UIView *container = [[UIView alloc] init];
  container.backgroundColor = UIColor.systemBackgroundColor;
  [container addSubview:all];
  [NSLayoutConstraint activateConstraints:@[
    [disc.widthAnchor constraintEqualToConstant:40.0],
    [disc.heightAnchor constraintEqualToConstant:40.0],
    [mark.centerXAnchor constraintEqualToAnchor:disc.centerXAnchor],
    [mark.centerYAnchor constraintEqualToAnchor:disc.centerYAnchor],
    [all.topAnchor constraintEqualToAnchor:container.topAnchor constant:12.0],
    [all.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:kPDPlainTextInset],
    [all.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-kPDPlainTextInset],
    [all.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4.0],
  ]];
  return container;
}

// Report: summary, one section per settings section, then Reddit data; Start over,
// under Session, clears the session and the address counters.
@implementation PDCompatibilityReportViewController {
  NSArray<NSString *> *_sections;
  NSArray<NSArray<PDCompatResult *> *> *_rows;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Report";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  PDStyleSettingsTable(self.tableView);
  [self.tableView registerClass:PDReportCell.class forCellReuseIdentifier:@"PDReportCell"];
  self.tableView.estimatedRowHeight = kPDRowHeightWithSubtitle;
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
  NSArray<PDCompatResult *> *results = PDCompatResults();
  NSMutableArray<NSString *> *sections = [NSMutableArray array];
  NSMutableArray<NSMutableArray<PDCompatResult *> *> *rows = [NSMutableArray array];
  for (PDCompatResult *result in results) {
    if (![sections.lastObject isEqualToString:result.section]) {
      [sections addObject:result.section];
      [rows addObject:[NSMutableArray array]];
    }
    [rows.lastObject addObject:result];
  }
  _sections = sections;
  _rows = rows;
  self.tableView.tableHeaderView = PDReportSummaryView(results);
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
    PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
    [cell configureWithTitle:@"Start over"
                    subtitle:nil
                       value:nil
                        icon:PDRowIcon(@[ @"rpl3/refresh" ])
                   accessory:PDAccessoryNone];
    [cell setTitleColor:PDDestructiveColor()];
    return cell;
  }
  PDReportCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDReportCell" forIndexPath:indexPath];
  [cell configureWithResult:_rows[indexPath.section][indexPath.row]];
  return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return indexPath.section < (NSInteger)_sections.count ? UITableViewAutomaticDimension : kPDRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  return PDSectionHeaderView(section < (NSInteger)_sections.count ? _sections[section] : @"Session");
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return kPDSectionGap;
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
  __weak PDCompatibilityReportViewController *weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Start over"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            PDCompatReset();
                                            [[PDDataPathTracker shared] reset];
                                            [weakSelf reloadReport];
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)putReportOnClipboard {
  UIPasteboard.generalPasteboard.string = PDCompatReportText();
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
@interface PDCompatibilityViewController : UITableViewController
@end

@implementation PDCompatibilityViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Compatibility";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  PDStyleSettingsTable(self.tableView);
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
  PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
  if (indexPath.row == 0) {
    [cell configureWithTitle:@"Record activity"
                    subtitle:nil
                       value:nil
                        icon:PDSymbol(@"stethoscope")
                   accessory:PDAccessorySwitch];
    cell.toggle.on = PDCompatActive;
    [cell.toggle addTarget:self action:@selector(toggleRecording:) forControlEvents:UIControlEventValueChanged];
    return cell;
  }
  // Problems first, then whether recording is on.
  NSInteger broken = PDBrokenCount(PDCompatResults());
  NSString *status = broken ? [NSString stringWithFormat:@"%ld broken", (long)broken]
                            : PDCompatActive ? @"Compatible"
                                         : @"Not recording";
  [cell configureWithTitle:@"Report"
                  subtitle:nil
                     value:status
                      icon:PDSymbol(@"list.bullet.rectangle")
                 accessory:PDAccessoryChevron];
  [cell setValueColor:broken ? UIColor.systemRedColor : PDCompatActive ? UIColor.systemGreenColor : PDSecondaryColor()];
  return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return kPDRowHeight;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  __weak PDCompatibilityViewController *weakSelf = self;
  return PDSectionHeaderViewWithInfo(@"Session", kPDSwitchColumnInset, ^{
    [weakSelf showHelp];
  });
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDHeaderHeight;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return kPDSectionGap;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.row != 1) return;
  [self.navigationController
      pushViewController:[[PDCompatibilityReportViewController alloc] initWithStyle:UITableViewStyleGrouped]
                animated:YES];
}

- (void)toggleRecording:(UISwitch *)sender {
  PDCompatSetRecording(sender.on);
  [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:1 inSection:0] ]
                        withRowAnimation:UITableViewRowAnimationNone];
}

- (void)showHelp {
  PDPresentHelpSheet(self, @"Session", @[
    PDHelp(@"Record activity",
           @"Watches what every option does while you use Reddit. The stethoscope opens the report anytime.",
           PDSymbol(@"stethoscope")),
    PDHelp(@"Report", @"Every option and every Reddit data address, marked Broken, Working, Not seen or Off.",
           PDSymbol(@"list.bullet.rectangle")),
  ]);
}

- (void)dismissPage {
  [self dismissViewControllerAnimated:YES completion:nil];
}
@end
#endif

#pragma mark - Main settings page

@interface PDRow : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, copy) NSString *value;
@property(nonatomic, copy) NSArray<NSString *> *icons;
@property(nonatomic, copy) NSString *key;
@property(nonatomic) BOOL shownWhenOn;
@property(nonatomic) BOOL fallback;
@property(nonatomic) SEL action;
@end

@implementation PDRow
@end

// Filter rows read ON = shown and store the inverse ("hide"); behavior rows
// store what the switch shows. `fallback` is the stored value when unset.
static PDRow *PDToggleRow(NSString *title, NSString *subtitle, NSArray<NSString *> *icons, NSString *key,
                          BOOL shownWhenOn, BOOL fallback) {
  PDRow *row = [[PDRow alloc] init];
  row.title = title;
  row.subtitle = subtitle;
  row.icons = icons;
  row.key = key;
  row.shownWhenOn = shownWhenOn;
  row.fallback = fallback;
  return row;
}

static PDRow *PDLinkRow(NSString *title, NSString *subtitle, NSString *value, NSArray<NSString *> *icons,
                        SEL action) {
  PDRow *row = [[PDRow alloc] init];
  row.title = title;
  row.subtitle = subtitle;
  row.value = value;
  row.icons = icons;
  row.action = action;
  return row;
}

static BOOL PDRowIsOn(PDRow *row) {
  BOOL stored = PDPrefBool(row.key, row.fallback);
  return row.shownWhenOn ? !stored : stored;
}

static char kPDSectionsKey;

// A %new method reached through [self ...] needs a visible declaration; this
// category provides them.
@interface PDSettingsViewController (PDNative)
- (NSArray *)pdSections;
- (void)pdRebuildSections;
- (PDRow *)pdRowAtIndexPath:(NSIndexPath *)indexPath;
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
static NSArray *PDBuildMainSections(void) {
  NSMutableArray *tools = [NSMutableArray
      arrayWithObject:PDLinkRow(@"Backup & reset", nil, nil, @[ @"rpl3/backup", @"rpl3/archive" ],
                                @selector(pdOpenBackup))];
#if PRIMEDIT_DEBUG
  [tools addObject:PDLinkRow(@"Compatibility", nil, nil, @[ @"rpl3/verified" ], @selector(pdOpenCompatibility))];
#endif
  return @[
    @{
      @"title" : @"Feed",
      @"rows" : @[
        PDToggleRow(@"Promoted", nil, @[ @"rpl3/ad" ], kPrimeDitPromoted, YES, YES),
        PDToggleRow(@"Recommended", nil, @[ @"rpl3/star" ], kPrimeDitRecommended, YES, NO),
        PDToggleRow(@"Community recommendations", nil, @[ @"rpl3/communities" ],
                    kPrimeDitRecommendationCarousels, YES, NO),
        PDToggleRow(@"Suggestion cards", nil, @[ @"rpl3/card" ], kPrimeDitExtraFeedCards, YES, NO),
        PDToggleRow(@"AI answers & summaries", nil, @[ @"rpl3/answers", @"rpl3/ai" ], kPrimeDitAIBoxes, YES,
                    NO),
        PDToggleRow(@"NSFW", nil, @[ @"rpl3/nsfw" ], kPrimeDitNSFW, YES, NO),
        PDToggleRow(@"Spoilers", nil, @[ @"rpl3/hide", @"rpl3/caution" ], kPrimeDitSpoilers, YES, NO),
        PDToggleRow(@"Visited posts", nil, @[ @"rpl3/show", @"rpl3/clock" ], kPrimeDitHideVisitedPosts, YES,
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
        PDLinkRow(@"Keywords", nil, PDListValue(kPrimeDitKeywords), @[ @"rpl3/keyword" ],
                  @selector(pdEditKeywords)),
        PDLinkRow(@"Subreddits", nil, PDListValue(kPrimeDitSubreddits), @[ @"rpl3/community" ],
                  @selector(pdEditSubreddits)),
        PDLinkRow(@"Muted users", nil, PDListValue(kPrimeDitMutedUsers), @[ @"rpl3/block" ],
                  @selector(pdEditMutedUsers)),
      ]
    },
    @{
      @"title" : @"Posts & comments",
      @"rows" : @[
        PDToggleRow(@"Awards", nil, @[ @"rpl3/award" ], kPrimeDitAwards, YES, NO),
        PDToggleRow(@"Vote counts", nil, @[ @"rpl3/upvote" ], kPrimeDitScores, YES, NO),
      ]
    },
    @{
      @"title" : @"Comments",
      @"rows" : @[
        PDToggleRow(@"Deleted & removed comments", nil, @[ @"rpl3/delete" ], kPrimeDitRemovedComments, YES,
                    NO),
        PDToggleRow(@"Collapse AutoMod comments", nil, @[ @"rpl3/autoMod" ], kPrimeDitAutoCollapseAutoMod, NO,
                    NO),
        PDLinkRow(@"Comment thread lines", nil, PDThreadLinesSummary(), @[ @"rpl3/branch", @"rpl3/comment" ],
                  @selector(pdOpenThreadLines)),
      ],
      @"help" : @[ @[
        kPrimeDitAutoCollapseAutoMod, @"AutoModerator is the bot moderators set up; its comments start folded."
      ] ],
    },
    @{
      @"title" : @"Interface",
      @"rows" : @[
        PDToggleRow(@"Tips & prompts", nil, @[ @"rpl3/lightbulb" ], kPrimeDitHideNags, YES, NO),
        PDLinkRow(@"Left menu", nil, PDLeftMenuSummary(), @[ @"rpl3/menu" ], @selector(pdOpenLeftMenu)),
      ],
      @"help" : @[ @[
        kPrimeDitHideNags, @"Tooltips, upgrade offers, nudges and \u201Cturn on notifications\u201D prompts."
      ] ],
    },
    @{
      @"title" : @"Tabs",
      @"rows" : @[
        PDToggleRow(@"Separate Chat from Inbox", nil, @[ @"rpl3/chat", @"rpl3/message" ],
                    kPrimeDitChatTabDisabled, YES, YES),
        PDToggleRow(@"Games tab", nil, @[ @"rpl3/gameController" ], kPrimeDitGamesTabDisabled, YES, NO),
        PDLinkRow(@"Launch tab", nil, PDLaunchTabName(), @[ @"rpl3/rocket", @"rpl3/home" ],
                  @selector(pdChooseLaunchTab)),
        PDToggleRow(@"Hold You to switch accounts", nil, @[ @"rpl3/users", @"rpl3/user" ],
                    kPrimeDitProfileAccountSwitcher, NO, YES),
        PDToggleRow(@"Keep tab bar expanded", nil, @[ @"rpl3/expandRight" ], kPrimeDitKeepTabBarExpanded, NO,
                    NO),
      ],
      @"help" : @[
        @[ kPrimeDitChatTabDisabled, @"Chat gets its own tab; Inbox keeps your notifications." ],
        @[ kPrimeDitKeepTabBarExpanded, @"The tab bar stays full size when you scroll instead of shrinking." ],
      ],
    },
    @{
      @"title" : @"Refresh",
      @"rows" : @[
        PDToggleRow(@"Keep Home where you left it", nil, @[ @"rpl3/pin", @"rpl3/home" ],
                    kPrimeDitKeepFeedOnTabReturn, NO, NO),
        PDToggleRow(@"Confirm Home refresh", nil, @[ @"rpl3/refresh" ], kPrimeDitConfirmHomeRefresh, NO, NO),
        PDToggleRow(@"Confirm pull to refresh", nil, @[ @"rpl3/swipeDown", @"rpl3/refresh" ],
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

%subclass PDSettingsViewController : BaseTableViewController
%new
- (NSArray *)pdSections {
  NSArray *sections = objc_getAssociatedObject(self, &kPDSectionsKey);
  if (!sections) {
    sections = PDBuildMainSections();
    objc_setAssociatedObject(self, &kPDSectionsKey, sections, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return sections;
}
%new
- (void)pdRebuildSections {
  objc_setAssociatedObject(self, &kPDSectionsKey, PDBuildMainSections(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self.tableView reloadData];
}
%new
- (PDRow *)pdRowAtIndexPath:(NSIndexPath *)indexPath {
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
  PDSettingsCell *cell = [tableView dequeueReusableCellWithIdentifier:@"PDSettingsCell" forIndexPath:indexPath];
  PDRow *row = [self pdRowAtIndexPath:indexPath];
  BOOL isToggle = row.key != nil;
  [cell configureWithTitle:row.title
                  subtitle:row.subtitle
                     value:row.value
                      icon:PDRowIcon(row.icons)
                 accessory:(isToggle ? PDAccessorySwitch : PDAccessoryChevron)];
  if (isToggle) {
    cell.toggle.on = PDRowIsOn(row);
    cell.toggle.tag = indexPath.section * 100 + indexPath.row;
    [cell.toggle addTarget:self action:@selector(pdToggleChanged:) forControlEvents:UIControlEventValueChanged];
  }
  return cell;
}
%new
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self pdRowAtIndexPath:indexPath].subtitle.length ? kPDRowHeightWithSubtitle : kPDRowHeight;
}
%new
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
  NSArray *sections = [self pdSections];
  if (section < 0 || section >= (NSInteger)sections.count) return nil;
  NSDictionary *info = sections[section];
  void (^onInfo)(void) = nil;
  if ([info[@"help"] count]) {
    __weak PDSettingsViewController *weakSelf = self;
    onInfo = ^{
      [weakSelf pdShowHelpForSection:section];
    };
  }
  return PDSectionHeaderViewWithInfo(info[@"title"], kPDSwitchColumnInset, onInfo);
}
%new
- (void)pdShowHelpForSection:(NSInteger)section {
  NSArray *sections = [self pdSections];
  if (section < 0 || section >= (NSInteger)sections.count) return;
  NSDictionary *info = sections[section];
  NSMutableArray<PDHelpItem *> *items = [NSMutableArray array];
  for (NSArray *entry in info[@"help"])
    for (PDRow *row in info[@"rows"])
      if ([row.key isEqualToString:entry[0]]) [items addObject:PDHelp(row.title, entry[1], PDRowIcon(row.icons))];
  PDPresentHelpSheet(self, info[@"title"], items);
}
%new
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
  return kPDHeaderHeight;
}
%new
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
  return kPDSectionGap;
}
%new
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  PDRow *row = [self pdRowAtIndexPath:indexPath];
  if (!row.action || ![self respondsToSelector:row.action]) return;
  ((void (*)(id, SEL))[self methodForSelector:row.action])(self, row.action);
}
- (void)viewDidLoad {
  %orig;
  self.title = @"PrimeDit";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  PDStyleSettingsTable(self.tableView);
}
- (void)viewWillAppear:(BOOL)animated {
  %orig;
  [self pdRebuildSections];
}
%new
- (void)pdToggleChanged:(UISwitch *)sender {
  PDRow *row = [self pdRowAtIndexPath:[NSIndexPath indexPathForRow:sender.tag % 100 inSection:sender.tag / 100]];
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
  [self pdPushController:[[PDThreadLinesViewController alloc] initWithStyle:UITableViewStyleGrouped]];
}
%new
- (void)pdOpenLeftMenu {
  [self pdPushController:[[PDLeftMenuViewController alloc] initWithStyle:UITableViewStyleGrouped]];
}
%new
- (void)pdOpenBackup {
  [self pdPushController:[[PDBackupViewController alloc] initWithStyle:UITableViewStyleGrouped]];
}
%new
- (void)pdOpenCompatibility {
#if PRIMEDIT_DEBUG
  [self pdPushController:[[PDCompatibilityViewController alloc] initWithStyle:UITableViewStyleGrouped]];
#endif
}
%new
- (void)pdChooseLaunchTab {
  UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Launch tab"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  __weak PDSettingsViewController *weakSelf = self;
  for (NSInteger i = 0; i < 5; i++) {
    [sheet addAction:[UIAlertAction actionWithTitle:kPDLaunchTabNames[i]
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
  [self pdPushController:[[PDListEditorViewController alloc]
                             initWithTitle:@"Keywords"
                                   listKey:kPrimeDitKeywords
                                enabledKey:kPrimeDitKeywordsEnabled
                               placeholder:@"Add a keyword"
                                    header:@"Hide posts and comments with"]];
}
%new
- (void)pdEditSubreddits {
  [self pdPushController:[[PDListEditorViewController alloc] initWithTitle:@"Subreddits"
                                                                   listKey:kPrimeDitSubreddits
                                                                enabledKey:kPrimeDitSubredditsEnabled
                                                               placeholder:@"Add a subreddit"
                                                                    header:@"Hide posts from"]];
}
%new
- (void)pdEditMutedUsers {
  [self pdPushController:[[PDListEditorViewController alloc]
                             initWithTitle:@"Muted users"
                                   listKey:kPrimeDitMutedUsers
                                enabledKey:kPrimeDitMutedUsersEnabled
                               placeholder:@"Add a username"
                                    header:@"Hide posts and comments from"]];
}
%end
