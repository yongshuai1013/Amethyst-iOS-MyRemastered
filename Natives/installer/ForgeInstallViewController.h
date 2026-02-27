#import <UIKit/UIKit.h>

@interface ForgeInstallViewController : UITableViewController

@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, assign) BOOL isNeoForge;
@property (nonatomic, assign) BOOL installOptiFine;
@property (nonatomic, copy) NSString *optiFineVersion;
@property (nonatomic, copy) void (^completionHandler)(BOOL success, NSString *profileName, NSError *error);

@end
