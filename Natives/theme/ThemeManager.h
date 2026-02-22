#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ThemeLayoutStyle) {
    ThemeLayoutStyleList,
    ThemeLayoutStyleGrid,
    ThemeLayoutStyleCard
};

@interface ThemeManager : NSObject

@property (nonatomic, strong, readonly) NSDictionary *themeData;
@property (nonatomic, assign, readonly) ThemeLayoutStyle layoutStyle;
@property (nonatomic, assign, readonly) CGFloat cornerRadius;
@property (nonatomic, assign, readonly) CGFloat spacing;

+ (instancetype)sharedManager;

- (void)loadTheme fromPath:(NSString *)path;
- (void)loadDefaultTheme;

// Colors
- (UIColor *)backgroundColor;
- (UIColor *)surfaceColor;
- (UIColor *)primaryColor;
- (UIColor *)secondaryColor;
- (UIColor *)textColorPrimary;
- (UIColor *)textColorSecondary;
- (UIColor *)accentColor;

// Images
- (UIImage *)backgroundImage;
- (UIImage *)iconForMenuId:(NSString *)menuId;

// Fonts
- (UIFont *)fontOfSize:(CGFloat)size weight:(UIFontWeight)weight;

// Animations
- (void)applyEntranceAnimationToView:(UIView *)view delay:(NSTimeInterval)delay;
- (void)applyPressAnimationToView:(UIView *)view;

// Components
- (void)applyThemeToTableView:(UITableView *)tableView;
- (void)applyThemeToCell:(UITableViewCell *)cell;
- (void)applyThemeToLabel:(UILabel *)label;
- (void)applyThemeToButton:(UIButton *)button;
- (void)applyThemeToSwitch:(UISwitch *)switchControl;
- (void)applyThemeToTextField:(UITextField *)textField;

@end

NS_ASSUME_NONNULL_END
