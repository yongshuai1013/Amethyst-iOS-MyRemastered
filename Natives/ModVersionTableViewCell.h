#import <UIKit/UIKit.h>
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModVersionTableViewCell : UITableViewCell

- (void)configureWithVersion:(ModVersion *)version;
- (void)applyTheme;

@end

NS_ASSUME_NONNULL_END
