#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "theme/ThemeManager.h"
#import "LauncherNewsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherProfilesViewController.h"
#import "PLProfiles.h"
#import "UIButton+AFNetworking.h"
#import "UIImageView+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#include <dlfcn.h>

@interface LauncherMenuCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation LauncherMenuCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_iconView];
        
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.font = [ThemeManager.sharedManager fontOfSize:14 weight:UIFontWeightMedium];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_titleLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [_iconView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor constant:-10],
            [_iconView.widthAnchor constraintEqualToConstant:40],
            [_iconView.heightAnchor constraintEqualToConstant:40],
            
            [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:8],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4]
        ]];
        
        self.contentView.layer.cornerRadius = [ThemeManager.sharedManager cornerRadius];
        self.contentView.layer.masksToBounds = YES;
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (highlighted) {
        [ThemeManager.sharedManager applyPressAnimationToView:self.contentView];
    } else {
        [UIView animateWithDuration:0.1 animations:^{
            self.contentView.transform = CGAffineTransformIdentity;
        }];
    }
}
@end

@implementation LauncherMenuCustomItem

+ (LauncherMenuCustomItem *)title:(NSString *)title imageName:(NSString *)imageName action:(id)action {
    LauncherMenuCustomItem *item = [[LauncherMenuCustomItem alloc] init];
    item.title = title;
    item.imageName = imageName;
    item.action = action;
    return item;
}

+ (LauncherMenuCustomItem *)vcClass:(Class)class {
    id vc = [class new];
    LauncherMenuCustomItem *item = [[LauncherMenuCustomItem alloc] init];
    item.title = [vc title];
    item.imageName = [vc imageName];
    item.vcArray = @[vc];
    return item;
}

@end

@interface LauncherMenuViewController()
@property(nonatomic) NSMutableArray<LauncherMenuCustomItem*> *options;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) int lastSelectedIndex;
@property(nonatomic, weak) NSLayoutConstraint *announcementContainerHeightConstraint;
@property(nonatomic, weak) UIView *announcementContainer;
@property(nonatomic, weak) UILabel *announcementLabel;
@property(nonatomic, weak) UIButton *downloadButton;
@end

@implementation LauncherMenuViewController

#define contentNavigationController ((LauncherNavigationController *)self.splitViewController.viewControllers[1])

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.isInitialVc = YES;
    self.view.backgroundColor = [ThemeManager.sharedManager backgroundColor];
    
    UIImageView *titleView = [[UIImageView alloc] initWithImage:[ThemeManager.sharedManager iconForMenuId:@"AppLogo"] ?: [UIImage imageNamed:@"AppLogo"]];
    [titleView setContentMode:UIViewContentModeScaleAspectFit];
    self.navigationItem.titleView = titleView;
    [titleView sizeToFit];
    
    [self setupCollectionView];
    
    self.options = @[
        [LauncherMenuCustomItem vcClass:LauncherNewsViewController.class],
        [LauncherMenuCustomItem vcClass:LauncherProfilesViewController.class],
        [LauncherMenuCustomItem vcClass:LauncherPreferencesViewController.class],
    ].mutableCopy;
    if (realUIIdiom != UIUserInterfaceIdiomTV) {
        [self.options addObject:(id)[LauncherMenuCustomItem
                                     title:localize(@"launcher.menu.custom_controls", nil)
                                     imageName:@"MenuCustomControls" action:^{
            [contentNavigationController performSelector:@selector(enterCustomControls)];
        }]];
    }
    [self.options addObject:
     (id)[LauncherMenuCustomItem
          title:localize(@"launcher.menu.execute_jar", nil)
          imageName:@"MenuInstallJar" action:^{
        [contentNavigationController performSelector:@selector(enterModInstaller)];
    }]];
    
    // Log uploading
    [self.options addObject:
     (id)[LauncherMenuCustomItem
          title:localize(@"login.menu.sendlogs", nil)
          imageName:@"square.and.arrow.up" action:^{
        NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.old.txt", getenv("POJAV_HOME")];
        UIActivityViewController *activityVC;
        if (realUIIdiom != UIUserInterfaceIdiomTV) {
            activityVC = [[UIActivityViewController alloc]
                          initWithActivityItems:@[[NSURL URLWithString:latestlogPath]]
                          applicationActivities:nil];
        } else {
            dlopen("/System/Library/PrivateFrameworks/SharingUI.framework/SharingUI", RTLD_GLOBAL);
            activityVC =
            [[NSClassFromString(@"SFAirDropSharingViewControllerTV") alloc]
             performSelector:@selector(initWithSharingItems:)
             withObject:@[[NSURL URLWithString:latestlogPath]]];
        }
        activityVC.popoverPresentationController.sourceView = titleView;
        activityVC.popoverPresentationController.sourceRect = titleView.bounds;
        [self presentViewController:activityVC animated:YES completion:nil];
    }]];
    
    // Easter eggs
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"MM-dd";
    NSString* date = [dateFormatter stringFromDate:NSDate.date];
    if([date isEqualToString:@"06-29"] || [date isEqualToString:@"06-30"] || [date isEqualToString:@"07-01"]) {
        [self.options addObject:(id)[LauncherMenuCustomItem
                                     title:@"Technoblade never dies!"
                                     imageName:@"" action:^{
            openLink(self, [NSURL URLWithString:@"https://www.bilibili.com/video/BV1RG411s7fw"]);
        }]];
    }
    
    if([date isEqualToString:@"12-27"] || [date isEqualToString:@"12-28"] || [date isEqualToString:@"12-29"]) {
        [self.options addObject:(id)[LauncherMenuCustomItem
                                     title:@"致那个为方块上色的人"
                                     imageName:@"" action:^{
            NSString *urlString = @"https://wiki.easecation.net/零雾05_Fogg05";
            NSString *encodedUrlString = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
            openLink(self, [NSURL URLWithString:encodedUrlString]);
        }]];
    }
    
    self.navigationController.toolbarHidden = NO;
    UIActivityIndicatorViewStyle indicatorStyle = UIActivityIndicatorViewStyleMedium;
    UIActivityIndicatorView *toolbarIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:indicatorStyle];
    [toolbarIndicator startAnimating];
    self.toolbarItems = @[
        [[UIBarButtonItem alloc] initWithCustomView:toolbarIndicator],
        [[UIBarButtonItem alloc] init]
    ];
    self.toolbarItems[1].tintColor = [ThemeManager.sharedManager textColorPrimary];
    
    self.accountBtnItem = [self drawAccountButton];
    [self updateAccountInfo];
    
    NSUInteger initialIndex = 0;
    UIViewController *currentRoot = contentNavigationController.viewControllers.firstObject;
    for (NSUInteger i = 0; i < self.options.count; i++) {
        LauncherMenuCustomItem *opt = self.options[i];
        if (opt.vcArray.count > 0 && [currentRoot isKindOfClass:[opt.vcArray[0] class]]) {
            initialIndex = i;
            break;
        }
    }
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:initialIndex inSection:0];
    [self.collectionView selectItemAtIndexPath:indexPath animated:YES scrollPosition:UICollectionViewScrollPositionNone];
    [self collectionView:self.collectionView didSelectItemAtIndexPath:indexPath];
    
    // Announcement
    [self setupAnnouncement];
    
    NSString *currentVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    if ([currentVersion rangeOfString:@"Preview" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        self.announcementLabel.text = localize(@"announcement.preview_version", @"欢迎使用Amethyst iOS Remastered测试版！");
    } else {
        [self checkForUpdateWithCurrentVersion:currentVersion announcementLabel:self.announcementLabel announcementContainer:self.announcementContainer retryCount:0];
    }
    
    if (getEntitlementValue(@"get-task-allow")) {
        [self displayProgress:localize(@"login.jit.checking", nil)];
        if (isJITEnabled(false)) {
            [self displayProgress:localize(@"login.jit.enabled", nil)];
            [self displayProgress:nil];
        } else {
            [self enableJITWithAltKit];
        }
    } else if (!NSProcessInfo.processInfo.macCatalystApp && !getenv("SIMULATOR_DEVICE_NAME")) {
        [self displayProgress:localize(@"login.jit.fail", nil)];
        [self displayProgress:nil];
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:localize(@"login.jit.fail.title", nil)
            message:localize(@"login.jit.fail.description_unsupported", nil)
            preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(id action){
            exit(-1);
        }];
        [alert addAction:okAction];
        [self presentViewController:alert animated:YES completion:nil];
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:) name:@"ThemeChangedNotification" object:nil];
}

- (void)setupAnnouncement {
    UILabel *announcementLabel = [[UILabel alloc] init];
    announcementLabel.textAlignment = NSTextAlignmentLeft;
    announcementLabel.textColor = [ThemeManager.sharedManager textColorPrimary];
    announcementLabel.font = [ThemeManager.sharedManager fontOfSize:14 weight:UIFontWeightMedium];
    announcementLabel.translatesAutoresizingMaskIntoConstraints = NO;
    announcementLabel.numberOfLines = 0;
    
    UIView *announcementContainer = [[UIView alloc] init];
    announcementContainer.translatesAutoresizingMaskIntoConstraints = NO;
    announcementContainer.backgroundColor = [[ThemeManager.sharedManager surfaceColor] colorWithAlphaComponent:0.95];
    announcementContainer.layer.cornerRadius = [ThemeManager.sharedManager cornerRadius];
    announcementContainer.layer.masksToBounds = YES;
    announcementContainer.layer.borderWidth = 1.0;
    announcementContainer.layer.borderColor = [[ThemeManager.sharedManager secondaryColor] colorWithAlphaComponent:0.3].CGColor;
    
    // Shadow
    announcementContainer.layer.shadowColor = [UIColor blackColor].CGColor;
    announcementContainer.layer.shadowOffset = CGSizeMake(0, 2);
    announcementContainer.layer.shadowRadius = 4;
    announcementContainer.layer.shadowOpacity = 0.1;
    
    UIImageView *infoIcon = [[UIImageView alloc] init];
    infoIcon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        infoIcon.image = [UIImage systemImageNamed:@"info.circle.fill"];
        infoIcon.tintColor = [ThemeManager.sharedManager primaryColor];
    }
    
    [announcementContainer addSubview:infoIcon];
    [announcementContainer addSubview:announcementLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [infoIcon.leadingAnchor constraintEqualToAnchor:announcementContainer.leadingAnchor constant:8],
        [infoIcon.topAnchor constraintEqualToAnchor:announcementContainer.topAnchor constant:12],
        [infoIcon.widthAnchor constraintEqualToConstant:20],
        [infoIcon.heightAnchor constraintEqualToConstant:20],
        
        [announcementLabel.topAnchor constraintEqualToAnchor:announcementContainer.topAnchor constant:12],
        [announcementLabel.leadingAnchor constraintEqualToAnchor:infoIcon.trailingAnchor constant:8],
        [announcementLabel.trailingAnchor constraintEqualToAnchor:announcementContainer.trailingAnchor constant:-8]
    ]];
    
    [self.view addSubview:announcementContainer];
    
    NSLayoutConstraint *heightConstraint = [announcementContainer.heightAnchor constraintEqualToConstant:60];
    self.announcementContainerHeightConstraint = heightConstraint;
    
    [NSLayoutConstraint activateConstraints:@[
        [announcementContainer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [announcementContainer.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:8],
        [announcementContainer.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-8],
        heightConstraint
    ]];
    
    self.announcementContainer = announcementContainer;
    self.announcementLabel = announcementLabel;
    
    self.collectionView.contentInset = UIEdgeInsetsMake(76, 0, 0, 0);
}

- (void)themeChanged:(NSNotification *)note {
    self.view.backgroundColor = [ThemeManager.sharedManager backgroundColor];
    self.collectionView.collectionViewLayout = [self createLayout];
    [self.collectionView reloadData];
    self.toolbarItems[1].tintColor = [ThemeManager.sharedManager textColorPrimary];
    self.announcementContainer.backgroundColor = [[ThemeManager.sharedManager surfaceColor] colorWithAlphaComponent:0.95];
    self.announcementLabel.textColor = [ThemeManager.sharedManager textColorPrimary];
}

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.delegate = self;
    self.collectionView.dataSource = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.view addSubview:self.collectionView];
    
    [self.collectionView registerClass:[LauncherMenuCell class] forCellWithReuseIdentifier:@"cell"];
}

- (UICollectionViewLayout *)createLayout {
    ThemeLayoutStyle style = [ThemeManager.sharedManager layoutStyle];
    
    if (style == ThemeLayoutStyleGrid) {
        NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:0.5]
                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:110]];
        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
        item.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 6);
        
        NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                           heightDimension:[NSCollectionLayoutDimension absoluteDimension:110]];
        NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];
        
        NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
        section.contentInsets = NSDirectionalEdgeInsetsMake(16, 16, 16, 16);
        return [[UICollectionViewCompositionalLayout alloc] initWithSection:section];
    } else {
        UICollectionLayoutListConfiguration *config = [[UICollectionLayoutListConfiguration alloc] initWithAppearance:UICollectionLayoutListAppearanceSidebar];
        config.backgroundColor = [UIColor clearColor];
        config.showsSeparators = NO;
        return [UICollectionViewCompositionalLayout layoutWithListConfiguration:config];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self restoreHighlightedSelection];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    if (self.collectionView.contentInset.top < 70) {
        self.collectionView.contentInset = UIEdgeInsetsMake(76, 0, 0, 0);
    }
    
    if (self.announcementContainer && self.announcementLabel) {
        static CGFloat previousWidth = 0;
        CGFloat currentWidth = self.announcementContainer.frame.size.width;
        
        if (fabs(currentWidth - previousWidth) > 1.0 && currentWidth > 50) {
            previousWidth = currentWidth;
            if (self.downloadButton) {
                [self adjustAnnouncementContainerHeight:self.announcementContainer forLabel:self.announcementLabel withButton:self.downloadButton];
            } else {
                [self adjustAnnouncementContainerHeight:self.announcementContainer forLabel:self.announcementLabel];
            }
        }
    }
}

- (UIBarButtonItem *)drawAccountButton {
    if (!self.accountBtnItem) {
        self.accountButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.accountButton addTarget:self action:@selector(selectAccount:) forControlEvents:UIControlEventPrimaryActionTriggered];
        self.accountButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.accountButton.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
        self.accountButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.accountButton.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.accountBtnItem = [[UIBarButtonItem alloc] initWithCustomView:self.accountButton];
    }
    [self updateAccountInfo];
    return self.accountBtnItem;
}

- (void)restoreHighlightedSelection {
    NSIndexPath *indexPath = [NSIndexPath indexPathForItem:self.lastSelectedIndex inSection:0];
    [self.collectionView selectItemAtIndexPath:indexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.options.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    LauncherMenuCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:indexPath];
    LauncherMenuCustomItem *item = self.options[indexPath.item];
    
    cell.titleLabel.text = item.title;
    cell.titleLabel.textColor = [ThemeManager.sharedManager textColorPrimary];
    
    UIImage *origImage = [UIImage systemImageNamed:item.imageName];
    if (!origImage) {
        origImage = [UIImage imageNamed:item.imageName];
    }
    
    if (origImage) {
        cell.iconView.image = [origImage isSymbolImage] ? origImage : [origImage _imageWithSize:CGSizeMake(30, 30)];
        cell.iconView.tintColor = [ThemeManager.sharedManager primaryColor];
    }
    
    cell.contentView.backgroundColor = [ThemeManager.sharedManager surfaceColor];
    
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    LauncherMenuCustomItem *selected = self.options[indexPath.item];
    
    if (selected.action != nil) {
        [self restoreHighlightedSelection];
        selected.action();
    } else {
        if(self.isInitialVc) {
            self.isInitialVc = NO;
            self.lastSelectedIndex = (int)indexPath.item;
        } else {
            self.options[self.lastSelectedIndex].vcArray = contentNavigationController.viewControllers;
            [contentNavigationController setViewControllers:selected.vcArray animated:NO];
            self.lastSelectedIndex = (int)indexPath.item;
        }
        selected.vcArray[0].navigationItem.rightBarButtonItem = self.accountBtnItem;
        selected.vcArray[0].navigationItem.leftBarButtonItem = self.splitViewController.displayModeButtonItem;
        selected.vcArray[0].navigationItem.leftItemsSupplementBackButton = true;
    }
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    [ThemeManager.sharedManager applyEntranceAnimationToView:cell delay:indexPath.item * 0.05];
}

- (void)selectAccount:(UIButton *)sender {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    vc.whenDelete = ^void(NSString* name) {
        if ([name isEqualToString:getPrefObject(@"internal.selected_account")]) {
            BaseAuthenticator.current = nil;
            setPrefObject(@"internal.selected_account", @"");
            [self updateAccountInfo];
        }
    };
    vc.whenItemSelected = ^void() {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        setPrefObject(@"internal.selected_account", currentAuth.authData[@"username"]);
        [self updateAccountInfo];
        if (sender != self.accountButton) {
            [sender sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
        }
    };
    vc.modalPresentationStyle = UIModalPresentationPopover;
    vc.preferredContentSize = CGSizeMake(350, 250);

    UIPopoverPresentationController *popoverController = vc.popoverPresentationController;
    popoverController.sourceView = sender;
    popoverController.sourceRect = sender.bounds;
    popoverController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    popoverController.delegate = vc;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)updateAccountInfo {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSDictionary *selected = currentAuth.authData;
    CGSize size = CGSizeMake(contentNavigationController.view.frame.size.width, contentNavigationController.view.frame.size.height);
    
    if (selected == nil) {
        if((size.width / 3) > 200) {
            [self.accountButton setAttributedTitle:[[NSAttributedString alloc] initWithString:localize(@"login.option.select", nil)] forState:UIControlStateNormal];
        } else {
            [self.accountButton setAttributedTitle:(NSAttributedString *)@"" forState:UIControlStateNormal];
        }
        [self.accountButton setImage:[UIImage imageNamed:@"DefaultAccount"] forState:UIControlStateNormal];
        [self.accountButton sizeToFit];
        return;
    }

    BOOL isDemo = [selected[@"username"] hasPrefix:@"Demo."];
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:[selected[@"username"] substringFromIndex:(isDemo?5:0)]];

    BOOL shouldUpdateProfiles = (getenv("DEMO_LOCK")!=NULL) != isDemo;

    unsetenv("DEMO_LOCK");
    setenv("POJAV_GAME_DIR", [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", getenv("POJAV_HOME")].UTF8String, 1);

    id subtitle;
    if (isDemo) {
        subtitle = localize(@"login.option.demo", nil);
        setenv("DEMO_LOCK", "1", 1);
        setenv("POJAV_GAME_DIR", [NSString stringWithFormat:@"%s/.demo", getenv("POJAV_HOME")].UTF8String, 1);
    } else if (selected[@"clientToken"] != nil) {
        subtitle = localize(@"login.option.3rdparty", nil);
    } else if (selected[@"xboxGamertag"] == nil) {
        subtitle = localize(@"login.option.local", nil);
    } else {
        subtitle = selected[@"xboxGamertag"];
    }

    subtitle = [[NSAttributedString alloc] initWithString:subtitle attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}];
    [title appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:nil]];
    [title appendAttributedString:subtitle];
    
    if((size.width / 3) > 200) {
        [self.accountButton setAttributedTitle:title forState:UIControlStateNormal];
    } else {
        [self.accountButton setAttributedTitle:(NSAttributedString *)@"" forState:UIControlStateNormal];
    }
    
    NSURL *url = [NSURL URLWithString:[selected[@"profilePicURL"] stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"]];
    UIImage *placeholder = [UIImage imageNamed:@"DefaultAccount"];
    [self.accountButton setImageForState:UIControlStateNormal withURL:url placeholderImage:placeholder];
    [self.accountButton.imageView setImageWithURL:url placeholderImage:placeholder];
    [self.accountButton sizeToFit];

    if (shouldUpdateProfiles) {
        [contentNavigationController fetchLocalVersionList];
        [contentNavigationController performSelector:@selector(reloadProfileList)];
    }

    // Update collectionView instead of tableView
    [self.collectionView reloadData];
}

- (void)displayProgress:(NSString *)status {
    if (status == nil) {
        [(UIActivityIndicatorView *)self.toolbarItems[0].customView stopAnimating];
    } else {
        self.toolbarItems[1].title = status;
    }
}

- (void)enableJITWithAltKit {
    [ALTServerManager.sharedManager startDiscovering];
    [ALTServerManager.sharedManager autoconnectWithCompletionHandler:^(ALTServerConnection *connection, NSError *error) {
        if (error) {
            NSLog(@"[AltKit] Could not auto-connect to server. %@", error.localizedRecoverySuggestion);
            [self displayProgress:localize(@"login.jit.fail", nil)];
            [self displayProgress:nil];
        }
        [connection enableUnsignedCodeExecutionWithCompletionHandler:^(BOOL success, NSError *error) {
            if (success) {
                NSLog(@"[AltKit] Successfully enabled JIT compilation!");
                [ALTServerManager.sharedManager stopDiscovering];
                [self displayProgress:localize(@"login.jit.enabled", nil)];
                [self displayProgress:nil];
            } else {
                NSLog(@"[AltKit] Error enabling JIT: %@", error.localizedRecoverySuggestion);
                [self displayProgress:localize(@"login.jit.fail", nil)];
                [self displayProgress:nil];
            }
            [connection disconnect];
        }];
    }];
}

- (NSComparisonResult)compareVersion:(NSString *)version1 withVersion:(NSString *)version2 {
    NSArray *v1Components = [version1 componentsSeparatedByString:@"."];
    NSArray *v2Components = [version2 componentsSeparatedByString:@"."];
    
    NSInteger maxComponents = MAX(v1Components.count, v2Components.count);
    
    for (NSInteger i = 0; i < maxComponents; i++) {
        NSInteger v1 = 0;
        NSInteger v2 = 0;
        
        if (i < v1Components.count) {
            v1 = [v1Components[i] integerValue];
        }
        
        if (i < v2Components.count) {
            v2 = [v2Components[i] integerValue];
        }
        
        if (v1 < v2) {
            return NSOrderedAscending;
        } else if (v1 > v2) {
            return NSOrderedDescending;
        }
    }
    
    return NSOrderedSame;
}

- (void)downloadLatestVersion:(UIButton *)sender {
    NSString *urlString = @"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest";
    NSURL *url = [NSURL URLWithString:urlString];
    
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)adjustAnnouncementContainerHeight:(UIView *)container forLabel:(UILabel *)label {
    if (container.frame.size.width <= 50) {
        [container.superview layoutIfNeeded];
    }
    
    CGFloat containerWidth = container.frame.size.width;
    CGFloat maxWidth = containerWidth - 62;
    
    if (maxWidth <= 0) {
        maxWidth = self.view.frame.size.width - 94;
    }
    if (maxWidth <= 0) {
        maxWidth = 200;
    }
    
    [label setNeedsLayout];
    [label layoutIfNeeded];
    
    CGSize labelSize = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat labelHeight = labelSize.height;
    
    CGFloat containerHeight = MAX(44, labelHeight + 24);
    
    if (self.announcementContainerHeightConstraint) {
        self.announcementContainerHeightConstraint.constant = containerHeight;
    }
    
    CGFloat topInset = containerHeight + 16;
    self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
    
    [container.superview layoutIfNeeded];
}

- (void)adjustAnnouncementContainerHeight:(UIView *)container forLabel:(UILabel *)label withButton:(UIButton *)button {
    if (container.frame.size.width <= 50) {
        [container.superview layoutIfNeeded];
    }
    
    CGFloat containerWidth = container.frame.size.width;
    CGFloat maxWidth = containerWidth - 62;
    
    if (maxWidth <= 0) {
        maxWidth = self.view.frame.size.width - 94;
    }
    if (maxWidth <= 0) {
        maxWidth = 200;
    }
    
    [label setNeedsLayout];
    [label layoutIfNeeded];
    
    CGSize labelSize = [label sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat labelHeight = labelSize.height;
    
    CGFloat containerHeight = MAX(72, labelHeight + 12 + 8 + 30 + 10);
    
    if (self.announcementContainerHeightConstraint) {
        self.announcementContainerHeightConstraint.constant = containerHeight;
    }
    
    CGFloat topInset = containerHeight + 16;
    self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 0, 0);
    
    [container.superview layoutIfNeeded];
}

- (void)checkForUpdateWithCurrentVersion:(NSString *)currentVersion
                        announcementLabel:(UILabel *)announcementLabel
                      announcementContainer:(UIView *)announcementContainer
                                retryCount:(NSInteger)retryCount {
    NSInteger maxRetries = 2;
    
    NSURL *url = [NSURL URLWithString:@"https://github.com/herbrine8403/Amethyst-iOS-MyRemastered/releases/latest"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 15.0;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || ((NSHTTPURLResponse *)response).statusCode != 200 || !data) {
            if (retryCount < maxRetries) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * (retryCount + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self checkForUpdateWithCurrentVersion:currentVersion
                                          announcementLabel:announcementLabel
                                        announcementContainer:announcementContainer
                                                  retryCount:retryCount + 1];
                });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            });
            return;
        }
        
        NSString *htmlString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *pattern = @"/herbrine8403/Amethyst-iOS-MyRemastered/releases/tag/([^\"]+)\"";
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        NSTextCheckingResult *match = [regex firstMatchInString:htmlString options:0 range:NSMakeRange(0, htmlString.length)];
        
        NSString *latestVersion = nil;
        if (match && match.numberOfRanges > 1) {
            latestVersion = [htmlString substringWithRange:[match rangeAtIndex:1]];
        }
        
        if (!latestVersion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            });
            return;
        }
        
        if ([latestVersion hasPrefix:@"v"]) {
            latestVersion = [latestVersion substringFromIndex:1];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSComparisonResult versionComparison = [self compareVersion:currentVersion withVersion:latestVersion];
            
            if (versionComparison == NSOrderedAscending) {
                NSString *localizedText = localize(@"announcement.new_version_available", @"发现新版本：%@");
                announcementLabel.text = [NSString stringWithFormat:localizedText, latestVersion];
                
                UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
                [downloadButton setTitle:localize(@"announcement.download_button", @"前往下载") forState:UIControlStateNormal];
                
                if (@available(iOS 13.0, *)) {
                    downloadButton.backgroundColor = [ThemeManager.sharedManager primaryColor];
                } else {
                    downloadButton.backgroundColor = [UIColor colorWithRed:0/255.0 green:122/255.0 blue:255/255.0 alpha:1.0];
                }
                
                [downloadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                downloadButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
                downloadButton.layer.cornerRadius = 8;
                downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
                
                downloadButton.layer.shadowColor = [UIColor blackColor].CGColor;
                downloadButton.layer.shadowOffset = CGSizeMake(0, 2);
                downloadButton.layer.shadowRadius = 4;
                downloadButton.layer.shadowOpacity = 0.2;
                downloadButton.layer.masksToBounds = NO;
                
                if (@available(iOS 13.0, *)) {
                    UIImage *downloadImage = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
                    [downloadButton setImage:downloadImage forState:UIControlStateNormal];
                    downloadButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
                    downloadButton.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
                    downloadButton.tintColor = [UIColor whiteColor];
                }
                
                [downloadButton addTarget:self action:@selector(downloadLatestVersion:) forControlEvents:UIControlEventTouchUpInside];
                
                [announcementContainer addSubview:downloadButton];
                self.downloadButton = downloadButton;
                
                [NSLayoutConstraint activateConstraints:@[
                    [downloadButton.topAnchor constraintEqualToAnchor:announcementLabel.bottomAnchor constant:8],
                    [downloadButton.leadingAnchor constraintEqualToAnchor:announcementContainer.leadingAnchor constant:8],
                    [downloadButton.trailingAnchor constraintEqualToAnchor:announcementContainer.trailingAnchor constant:-8],
                    [downloadButton.heightAnchor constraintEqualToConstant:30],
                    [downloadButton.bottomAnchor constraintEqualToAnchor:announcementContainer.bottomAnchor constant:-10]
                ]];
                
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel withButton:downloadButton];
            } else {
                announcementLabel.text = localize(@"announcement.latest_version", @"欢迎使用Amethyst iOS Remastered！当前已是最新正式版。");
                [self adjustAnnouncementContainerHeight:announcementContainer forLabel:announcementLabel];
            }
        });
    }];
    
    [task resume];
}

@end
