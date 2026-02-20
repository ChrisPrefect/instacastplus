//
//  ICAppearanceManager.m
//  Instacast
//
//  Created by Martin Hering on 26.07.14.
//
//

#import "ICAppearanceManager.h"
#import "ImageFunctions.h"
#import "InstacastAppDelegate.h"
#import "MainViewController_4.h"

NSString* ICAppearanceManagerDidUpdateAppearanceNotification = @"ICAppearanceManagerDidUpdateAppearanceNotification";

@interface ICAppearanceManager ()
@end

@implementation ICAppearanceManager

+ (instancetype) sharedManager
{
    static dispatch_once_t once;
    static ICAppearanceManager *sharedManager;
    dispatch_once(&once, ^ {
        sharedManager = [[self alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:sharedManager selector:@selector(_appWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    });
    return sharedManager;
}

- (void)_appWillEnterForeground:(NSNotification*)note
{
    if (self.appearanceMode != ICAppearanceModeAutomatic) return;

    // Check if iOS changed dark mode while app was in background
    BOOL systemIsDark = [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    BOOL currentIsDark = [self.appearance isKindOfClass:[ICNightAppearance class]];
    if (systemIsDark != currentIsDark) {
        [self updateAppearance];
    }
}


- (UIImage*) _navigationBarImageWithSize:(CGSize)size appearance:(id<ICAppearance>)appearance topToBottom:(BOOL)topToBottom
{
    return ICImageFromByDrawingInContext(size, ^(void) {

        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = UIGraphicsGetCurrentContext();

        //// Color Declarations - resolve dynamic color for correct trait collection
        UITraitCollection *traitCollection = self.nightMode
            ? [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark]
            : [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleLight];
        UIColor* topColor = [appearance.backgroundColor resolvedColorWithTraitCollection:traitCollection];
        CGFloat red, green, blue, alpha;
        [topColor getRed:&red green:&green blue:&blue alpha:&alpha];
        
        alpha *= 0.9f;
        UIColor* bottomColor = [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
        
        //// Gradient Declarations
        CGFloat gradientLocations[] = {0, 1};
        CGGradientRef gradient = (topToBottom) ? CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)@[(id)topColor.CGColor, (id)bottomColor.CGColor], gradientLocations) : CGGradientCreateWithColors(colorSpace, (__bridge CFArrayRef)@[(id)bottomColor.CGColor, (id)topColor.CGColor], gradientLocations);
        
        //// Rectangle Drawing
        UIBezierPath* rectanglePath = [UIBezierPath bezierPathWithRect: CGRectMake(0, 0, size.width, size.height)];
        CGContextSaveGState(context);
        [rectanglePath addClip];
        CGContextDrawLinearGradient(context, gradient, CGPointMake(size.width/2, 0), CGPointMake(size.width/2, size.height), 0);
        CGContextRestoreGState(context);
        
        //// Cleanup
        CGGradientRelease(gradient);
        CGColorSpaceRelease(colorSpace);
    });
}

- (void) setAppearance:(id<ICAppearance>)appearance
{
    if (_appearance != appearance) {
        _appearance = appearance;

        // UIAppearance proxies (affect newly created views)
        [[UINavigationBar appearance] setTitleTextAttributes:@{ NSForegroundColorAttributeName : appearance.textColor }];
        [[UINavigationBar appearance] setBackgroundImage:[self _navigationBarImageWithSize:CGSizeMake(44, 64) appearance:appearance topToBottom:YES] forBarMetrics:UIBarMetricsDefault];
        [[UINavigationBar appearance] setBackgroundImage:[self _navigationBarImageWithSize:CGSizeMake(44, 94) appearance:appearance topToBottom:YES] forBarMetrics:UIBarMetricsDefaultPrompt];
        [[UINavigationBar appearance] setShadowImage:[[UIImage alloc] init]];

        [[UIToolbar appearance] setBackgroundImage:[self _navigationBarImageWithSize:CGSizeMake(44, 44) appearance:appearance topToBottom:NO] forToolbarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
        [[UIToolbar appearance] setShadowImage:[[UIImage alloc] init] forToolbarPosition:UIBarPositionAny];

        [[UIScrollView appearance] setIndicatorStyle:appearance.scrollIndicatorStyle];

        [[UITabBar appearance] setShadowImage:[[UIImage alloc] init]];
        [[UITabBar appearance] setBackgroundImage:[self _navigationBarImageWithSize:CGSizeMake(50, 50) appearance:appearance topToBottom:NO]];

        [[UITextField appearance] setKeyboardAppearance:appearance.keyboardAppearance];

        [[UISwitch appearance] setTintColor:ICTintColor];
        [[UISwitch appearance] setOnTintColor:ICTintColor];

        UIWindow* rootWindow = [(InstacastAppDelegate*)App.delegate window];
        rootWindow.tintColor = ICTintColor;

        UIView* subview = [rootWindow.subviews lastObject];
        [subview removeFromSuperview];
        [rootWindow addSubview:subview];

        // Recursively update all existing navigation bars, toolbars, and tab bars
        if (rootWindow.rootViewController) {
            [self _recursivelyUpdateBarsForViewController:rootWindow.rootViewController];
        }

        // workaround a bug in iOS where presented view controllers don't get appearance methods
        UIViewController* presentedViewController = rootWindow.rootViewController.presentedViewController;
        do {
            [presentedViewController beginAppearanceTransition:NO animated:NO];
            [presentedViewController endAppearanceTransition];

            [presentedViewController beginAppearanceTransition:YES animated:NO];
            [presentedViewController endAppearanceTransition];

            presentedViewController = presentedViewController.presentedViewController;
        } while (presentedViewController);

        [[NSNotificationCenter defaultCenter] postNotificationName:ICAppearanceManagerDidUpdateAppearanceNotification object:self];
    }
}

- (void) _recursivelyUpdateBarsForViewController:(UIViewController *)vc
{
    id<ICAppearance> appearance = _appearance;

    // Update navigation bar
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        UIImage *backgroundImage = [self navigationBarBackgroundImage];
        UINavigationBarAppearance *navAppearance = [[UINavigationBarAppearance alloc] init];
        [navAppearance configureWithOpaqueBackground];
        navAppearance.backgroundImage = backgroundImage;
        navAppearance.shadowImage = [[UIImage alloc] init];
        navAppearance.shadowColor = nil;
        navAppearance.titleTextAttributes = @{ NSForegroundColorAttributeName : appearance.textColor };
        nav.navigationBar.standardAppearance = navAppearance;
        nav.navigationBar.scrollEdgeAppearance = navAppearance;
        nav.navigationBar.compactAppearance = navAppearance;

        // Update toolbar
        UIImage *toolbarImage = [self _navigationBarImageWithSize:CGSizeMake(44, 44) appearance:appearance topToBottom:NO];
        UIToolbarAppearance *toolbarAppearance = [[UIToolbarAppearance alloc] init];
        [toolbarAppearance configureWithOpaqueBackground];
        toolbarAppearance.backgroundImage = toolbarImage;
        toolbarAppearance.shadowImage = [[UIImage alloc] init];
        toolbarAppearance.shadowColor = nil;
        nav.toolbar.standardAppearance = toolbarAppearance;
        nav.toolbar.scrollEdgeAppearance = toolbarAppearance;
        nav.toolbar.compactAppearance = toolbarAppearance;
    }

    // Update tab bar
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabVC = (UITabBarController *)vc;
        UIImage *tabBarImage = [self _navigationBarImageWithSize:CGSizeMake(50, 50) appearance:appearance topToBottom:NO];
        UITabBarAppearance *tabAppearance = [[UITabBarAppearance alloc] init];
        [tabAppearance configureWithOpaqueBackground];
        tabAppearance.backgroundImage = tabBarImage;
        tabAppearance.shadowImage = [[UIImage alloc] init];
        tabAppearance.shadowColor = nil;
        tabVC.tabBar.standardAppearance = tabAppearance;
        tabVC.tabBar.scrollEdgeAppearance = tabAppearance;
    }

    // Recurse into child view controllers
    for (UIViewController *child in vc.childViewControllers) {
        [self _recursivelyUpdateBarsForViewController:child];
    }

    // Recurse into presented view controllers
    if (vc.presentedViewController) {
        [self _recursivelyUpdateBarsForViewController:vc.presentedViewController];
    }
}

- (ICAppearanceMode) appearanceMode {
    return [USER_DEFAULTS integerForKey:kDefaultAppearanceMode];
}

- (void) setAppearanceMode:(ICAppearanceMode)appearanceMode {
    [USER_DEFAULTS setInteger:appearanceMode forKey:kDefaultAppearanceMode];
    [self updateAppearance];
}

- (BOOL) nightSettingMode {
    switch (self.appearanceMode) {
        case ICAppearanceModeDark:
            return YES;
        case ICAppearanceModeLight:
            return NO;
        case ICAppearanceModeAutomatic:
        default:
            return [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
}

- (BOOL) nightMode {
    return self.nightSettingMode;
}

- (void) setNightMode:(BOOL)nightMode {
    self.appearanceMode = nightMode ? ICAppearanceModeDark : ICAppearanceModeLight;
}

- (void) updateAppearance
{
    UIWindow* rootWindow = [(InstacastAppDelegate*)App.delegate window];

    // Determine the correct appearance based on mode
    BOOL shouldUseDarkMode;
    switch (self.appearanceMode) {
        case ICAppearanceModeDark:
            shouldUseDarkMode = YES;
            break;
        case ICAppearanceModeLight:
            shouldUseDarkMode = NO;
            break;
        case ICAppearanceModeAutomatic:
        default:
            shouldUseDarkMode = [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
            break;
    }

    // Set overrideUserInterfaceStyle FIRST so trait collection is correct when appearance is created
    if (rootWindow) {
        switch (self.appearanceMode) {
            case ICAppearanceModeDark:
                rootWindow.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
                break;
            case ICAppearanceModeLight:
                rootWindow.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
                break;
            case ICAppearanceModeAutomatic:
            default:
                rootWindow.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
                break;
        }
        // Force layout pass to apply trait collection changes
        [rootWindow layoutIfNeeded];
    }

    if (shouldUseDarkMode) {
        self.appearance = [[ICNightAppearance alloc] init];
    } else {
        self.appearance = [[ICDaylightAppearance alloc] init];
    }
}

- (UIImage*) navigationBarBackgroundImage {
    return [self _navigationBarImageWithSize:CGSizeMake(44, 64) appearance:self.appearance topToBottom:YES];
}

- (void)updateThemeTintColor
{
    UIWindow* rootWindow = [(InstacastAppDelegate*)App.delegate window];
    UIViewController* rootViewController = [UIApplication sharedApplication].delegate.window.rootViewController;
    if([rootViewController isKindOfClass:[UINavigationController class]])
    {
        rootViewController = ((UINavigationController *)rootViewController).viewControllers.firstObject;
    }
    else if([rootViewController isKindOfClass:[UITabBarController class]])
    {
        rootViewController = ((UITabBarController *)rootViewController).selectedViewController;
    }
    else if([rootViewController isKindOfClass:[MainViewController_4 class]])
    {
        rootViewController = ((MainViewController_4 *)rootViewController).presentedViewController;
    }
    
    if ([USER_DEFAULTS boolForKey:InterfaceThemeDefaultActive])
    {
        rootViewController.view.tintColor = [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
        rootWindow.tintColor = [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
    }
    else
    {
        if ([USER_DEFAULTS objectForKey:InterfaceThemeColorCode])
        {
            NSData *colorData = [[NSUserDefaults standardUserDefaults] objectForKey:InterfaceThemeColorCode];
            rootViewController.view.tintColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
            rootWindow.tintColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
        }
        else
        {
            rootViewController.view.tintColor = [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
            rootWindow.tintColor = [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
        }
    }
}

@end


@implementation ICDaylightAppearance

-(UIColor*) tintColor {//DEVD TO DO
    if ([USER_DEFAULTS boolForKey:InterfaceThemeDefaultActive])
    {
        return [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
    }
    else
    {
        if ([USER_DEFAULTS objectForKey:InterfaceThemeColorCode])
        {
            NSData *colorData = [[NSUserDefaults standardUserDefaults] objectForKey:InterfaceThemeColorCode];
            return [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
        }
        else
        {
            return [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
        }
    }
}

-(UIColor*) textColor {
    return [UIColor labelColor];
}

- (UIColor*) mutedTextColor {
    return [UIColor secondaryLabelColor];
}

- (UIColor*) placeholderTextColor {
    return [UIColor placeholderTextColor];
}

-(UIColor*) backgroundColor {
    return [UIColor systemGroupedBackgroundColor];
}

-(UIColor*) darkBackgroundColor {
    return [UIColor colorWithWhite:0.13f alpha:1.f];
}

-(UIColor*) lightBackgroundColor {
    return [UIColor tertiarySystemGroupedBackgroundColor];
}

-(UIColor*) transparentBackdropColor {
    return [[UIColor systemGroupedBackgroundColor] colorWithAlphaComponent:0.9f];
}

-(UIColor*) tableSeparatorColor {
    return [UIColor separatorColor];
}

-(UIColor*) tableSelectedBackgroundColor {
    return [UIColor tertiarySystemGroupedBackgroundColor];
}

- (UIColor*) groupCellBackgroundColor {
    return [UIColor secondarySystemGroupedBackgroundColor];
}

- (UIColor*) groupCellSelectedBackgroundColor {
    return [UIColor tertiarySystemGroupedBackgroundColor];
}

- (UIStatusBarStyle) statusBarStyle {
    return UIStatusBarStyleDefault;
}

- (UIScrollViewIndicatorStyle) scrollIndicatorStyle {
    return UIScrollViewIndicatorStyleDefault;
}

- (NSString*) cssFile {
    return @"ShowNotesDaylightAppearance";
}

- (UIKeyboardAppearance) keyboardAppearance {
    return UIKeyboardAppearanceLight;
}

- (UIActivityIndicatorViewStyle) activityIndicatorStyle {
    return UIActivityIndicatorViewStyleMedium;
}

@end


@implementation ICNightAppearance

-(UIColor*) tintColor {//DEVD TO DO
    if ([USER_DEFAULTS boolForKey:InterfaceThemeDefaultActive])
    {
        return [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
    }
    else
    {
        if ([USER_DEFAULTS objectForKey:InterfaceThemeColorCode])
        {
            NSData *colorData = [[NSUserDefaults standardUserDefaults] objectForKey:InterfaceThemeColorCode];
            return [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
        }
        else
        {
            return [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
        }
    }
}

-(UIColor*) textColor {
    // Use explicit white color for dark mode to avoid dynamic color resolution issues at startup
    return [UIColor whiteColor];
}

- (UIColor*) mutedTextColor {
    // Use explicit light gray for dark mode
    return [UIColor colorWithWhite:0.7f alpha:1.0f];
}

- (UIColor*) placeholderTextColor {
    return [UIColor colorWithWhite:0.5f alpha:1.0f];
}

-(UIColor*) backgroundColor {
    if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        return [UIColor blackColor];
    }
    return [UIColor colorWithWhite:0.13f alpha:1.f];
}

-(UIColor*) darkBackgroundColor {
    return [UIColor blackColor];
}


-(UIColor*) lightBackgroundColor {
    if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        return [UIColor colorWithWhite:0.1f alpha:1.f];
    }
    return [UIColor colorWithWhite:0.3f alpha:1.f];
}

-(UIColor*) transparentBackdropColor {
    if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        return [UIColor colorWithWhite:0.0f alpha:0.9];
    }
    return [UIColor colorWithWhite:0.13f alpha:0.9];
}

-(UIColor*) tableSeparatorColor {
    if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        return [UIColor colorWithWhite:0.15f alpha:1.f];
    }
    return [UIColor colorWithWhite:0.2f alpha:1.f];
}

-(UIColor*) tableSelectedBackgroundColor {
    if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        return [UIColor colorWithWhite:0.1f alpha:1.0f];
    }
    return [UIColor colorWithWhite:0.2f alpha:1.0f];
}

- (UIColor*) groupCellBackgroundColor {
    if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        return [UIColor colorWithWhite:0.1f alpha:1.0f];
    }
    return [UIColor colorWithWhite:0.2f alpha:1.0f];
}

- (UIColor*) groupCellSelectedBackgroundColor {
    if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        return [UIColor colorWithWhite:0.15f alpha:1.0f];
    }
    return [UIColor colorWithWhite:0.3f alpha:1.0f];
}

- (UIStatusBarStyle) statusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (UIScrollViewIndicatorStyle) scrollIndicatorStyle {
    return UIScrollViewIndicatorStyleWhite;
}

- (NSString*) cssFile {
    return @"ShowNotesNightAppearance";
}

- (UIKeyboardAppearance) keyboardAppearance {
    return UIKeyboardAppearanceDark;
}

- (UIActivityIndicatorViewStyle) activityIndicatorStyle {
    return UIActivityIndicatorViewStyleMedium;
}

@end


@implementation ICWindow

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [super traitCollectionDidChange:previousTraitCollection];

    if ([ICAppearanceManager sharedManager].appearanceMode == ICAppearanceModeAutomatic) {
        if (self.traitCollection.userInterfaceStyle != previousTraitCollection.userInterfaceStyle) {
            [[ICAppearanceManager sharedManager] updateAppearance];
        }
    }
}

@end
