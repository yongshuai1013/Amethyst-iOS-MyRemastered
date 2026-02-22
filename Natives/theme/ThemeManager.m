#import "ThemeManager.h"

@interface UIColor (ThemeHex)
+ (UIColor *)colorWithHexString:(NSString *)hexString;
@end

@implementation UIColor (ThemeHex)

+ (UIColor *)colorWithHexString:(NSString *)hexString {
    unsigned rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexString];
    if ([hexString hasPrefix:@"#"]) {
        [scanner setScanLocation:1]; // bypass '#' character
    }
    [scanner scanHexInt:&rgbValue];
    
    // Check if alpha channel is included (8 digits)
    if (hexString.length > 7) {
        return [UIColor colorWithRed:((rgbValue & 0xFF000000) >> 24)/255.0
                               green:((rgbValue & 0x00FF0000) >> 16)/255.0
                                blue:((rgbValue & 0x0000FF00) >> 8)/255.0
                               alpha:((rgbValue & 0x000000FF))/255.0];
    }
    
    return [UIColor colorWithRed:((rgbValue & 0xFF0000) >> 16)/255.0
                           green:((rgbValue & 0x00FF00) >> 8)/255.0
                            blue:(rgbValue & 0x0000FF)/255.0
                           alpha:1.0];
}

@end

@interface ThemeManager ()
@property (nonatomic, strong, readwrite) NSDictionary *themeData;
@end

@implementation ThemeManager

+ (instancetype)sharedManager {
    static ThemeManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadDefaultTheme];
    }
    return self;
}

- (void)loadDefaultTheme {
    NSString *jsonString = @"{"
    "\"meta\": {\"name\": \"Modern Dark\", \"version\": \"1.0\"},"
    "\"colors\": {"
    "  \"background\": \"#121212\","
    "  \"surface\": \"#1E1E1E\","
    "  \"primary\": \"#BB86FC\","
    "  \"secondary\": \"#03DAC6\","
    "  \"text_primary\": \"#FFFFFF\","
    "  \"text_secondary\": \"#B0B0B0\","
    "  \"accent\": \"#CF6679\""
    "},"
    "\"layout\": {"
    "  \"style\": \"grid\","
    "  \"corner_radius\": 16,"
    "  \"spacing\": 12"
    "}"
    "}";
    
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    self.themeData = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error) {
        NSLog(@"Failed to load default theme: %@", error);
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ThemeChangedNotification" object:nil];
}

- (void)loadTheme fromPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSError *error;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && json) {
            self.themeData = json;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ThemeChangedNotification" object:nil];
        } else {
            NSLog(@"Failed to parse theme JSON: %@", error);
        }
    } else {
        NSLog(@"Failed to read theme file at path: %@", path);
    }
}

#pragma mark - Properties

- (ThemeLayoutStyle)layoutStyle {
    NSString *style = self.themeData[@"layout"][@"style"];
    if ([style isEqualToString:@"list"]) return ThemeLayoutStyleList;
    if ([style isEqualToString:@"card"]) return ThemeLayoutStyleCard;
    return ThemeLayoutStyleGrid; // Default
}

- (CGFloat)cornerRadius {
    NSNumber *val = self.themeData[@"layout"][@"corner_radius"];
    return val ? [val floatValue] : 12.0;
}

- (CGFloat)spacing {
    NSNumber *val = self.themeData[@"layout"][@"spacing"];
    return val ? [val floatValue] : 8.0;
}

#pragma mark - Colors

- (UIColor *)colorForKey:(NSString *)key fallback:(UIColor *)fallback {
    NSString *hex = self.themeData[@"colors"][key];
    if (hex) {
        return [UIColor colorWithHexString:hex];
    }
    return fallback;
}

- (UIColor *)backgroundColor {
    return [self colorForKey:@"background" fallback:[UIColor systemBackgroundColor]];
}

- (UIColor *)surfaceColor {
    return [self colorForKey:@"surface" fallback:[UIColor secondarySystemBackgroundColor]];
}

- (UIColor *)primaryColor {
    return [self colorForKey:@"primary" fallback:[UIColor systemBlueColor]];
}

- (UIColor *)secondaryColor {
    return [self colorForKey:@"secondary" fallback:[UIColor systemTealColor]];
}

- (UIColor *)textColorPrimary {
    return [self colorForKey:@"text_primary" fallback:[UIColor labelColor]];
}

- (UIColor *)textColorSecondary {
    return [self colorForKey:@"text_secondary" fallback:[UIColor secondaryLabelColor]];
}

- (UIColor *)accentColor {
    return [self colorForKey:@"accent" fallback:[UIColor systemRedColor]];
}

#pragma mark - Images

- (UIImage *)backgroundImage {
    NSString *path = self.themeData[@"images"][@"background_url"];
    if (path) {
        // Check if it's a file URL or path
        if ([path hasPrefix:@"file://"]) {
            path = [path substringFromIndex:7];
        }
        return [UIImage imageWithContentsOfFile:path];
    }
    return nil;
}

- (UIImage *)iconForMenuId:(NSString *)menuId {
    NSString *iconName = self.themeData[@"icons"][menuId];
    if (iconName) {
        // Try to load from bundle first, then file path
        UIImage *img = [UIImage imageNamed:iconName];
        if (!img) {
            img = [UIImage imageWithContentsOfFile:iconName];
        }
        return img;
    }
    return nil; // Should fallback to default icon
}

#pragma mark - Fonts

- (UIFont *)fontOfSize:(CGFloat)size weight:(UIFontWeight)weight {
    // Future: Support custom fonts via theme
    return [UIFont systemFontOfSize:size weight:weight];
}

#pragma mark - Animations

- (void)applyEntranceAnimationToView:(UIView *)view delay:(NSTimeInterval)delay {
    view.transform = CGAffineTransformMakeScale(0.8, 0.8);
    view.alpha = 0.0;
    
    [UIView animateWithDuration:0.6
                          delay:delay
         usingSpringWithDamping:0.6
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        view.transform = CGAffineTransformIdentity;
        view.alpha = 1.0;
    } completion:nil];
}

- (void)applyPressAnimationToView:(UIView *)view {
    [UIView animateWithDuration:0.1 animations:^{
        view.transform = CGAffineTransformMakeScale(0.95, 0.95);
    }];
}

#pragma mark - Components

- (void)applyThemeToTableView:(UITableView *)tableView {
    tableView.backgroundColor = [self backgroundColor];
    tableView.separatorColor = [[self secondaryColor] colorWithAlphaComponent:0.3];
    tableView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
}

- (void)applyThemeToCell:(UITableViewCell *)cell {
    cell.backgroundColor = [self surfaceColor];
    cell.textLabel.textColor = [self textColorPrimary];
    cell.detailTextLabel.textColor = [self textColorSecondary];
    cell.tintColor = [self primaryColor];
    
    // Modernize cell appearance
    UIView *selectedBackgroundView = [[UIView alloc] init];
    selectedBackgroundView.backgroundColor = [[self primaryColor] colorWithAlphaComponent:0.2];
    cell.selectedBackgroundView = selectedBackgroundView;
}

- (void)applyThemeToLabel:(UILabel *)label {
    label.textColor = [self textColorPrimary];
}

- (void)applyThemeToButton:(UIButton *)button {
    button.backgroundColor = [self primaryColor];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.layer.cornerRadius = [self cornerRadius];
    button.layer.masksToBounds = YES;
}

- (void)applyThemeToSwitch:(UISwitch *)switchControl {
    switchControl.onTintColor = [self primaryColor];
}

- (void)applyThemeToTextField:(UITextField *)textField {
    textField.backgroundColor = [self surfaceColor];
    textField.textColor = [self textColorPrimary];
    textField.tintColor = [self primaryColor];
    
    // Add border if needed
    textField.layer.borderColor = [[self secondaryColor] colorWithAlphaComponent:0.3].CGColor;
    textField.layer.borderWidth = 1.0;
    textField.layer.cornerRadius = [self cornerRadius];
}

@end
