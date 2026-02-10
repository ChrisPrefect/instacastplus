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

        // Update existing navigation bars directly (appearance proxy only affects new instances)
        UIImage* navBarImage = [self _navigationBarImageWithSize:CGSizeMake(44, 64) appearance:appearance topToBottom:YES];
        UINavigationBarAppearance* navAppearance = [[UINavigationBarAppearance alloc] init];
        [navAppearance configureWithOpaqueBackground];
        navAppearance.backgroundImage = navBarImage;
        navAppearance.shadowImage = [[UIImage alloc] init];
        navAppearance.shadowColor = nil;
        navAppearance.titleTextAttributes = @{ NSForegroundColorAttributeName : appearance.textColor };
        [self _applyNavigationBarAppearance:navAppearance toViewController:rootWindow.rootViewController];

        UIView* subview = [rootWindow.subviews lastObject];
        [subview removeFromSuperview];
        [rootWindow addSubview:subview];

        // workaround a bug in iOS where presented view controllers don't get appearance methods

        UIViewController* presentedViewController = rootWindow.rootViewController.presentedViewController;
//
//        // xxx: iPad does not update view controller behind a form sheet
//        if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
//            presentedViewController = rootWindow.rootViewController;
//        }

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

- (void) _applyNavigationBarAppearance:(UINavigationBarAppearance*)navAppearance toViewController:(UIViewController*)vc
{
    if (!vc) return;

    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController* nav = (UINavigationController*)vc;
        nav.navigationBar.standardAppearance = navAppearance;
        nav.navigationBar.scrollEdgeAppearance = navAppearance;
        nav.navigationBar.compactAppearance = navAppearance;
    }

    for (UIViewController* child in vc.childViewControllers) {
        [self _applyNavigationBarAppearance:navAppearance toViewController:child];
    }

    if (vc.presentedViewController) {
        [self _applyNavigationBarAppearance:navAppearance toViewController:vc.presentedViewController];
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
        // Note: layoutIfNeeded removed — was forcing a 1s synchronous layout pass.
        // overrideUserInterfaceStyle propagates naturally on the next layout cycle.
        // The appearance decision (shouldUseDarkMode) is already determined independently.
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
    return [UIColor colorWithWhite:0.13f alpha:1.f];
}

-(UIColor*) darkBackgroundColor {
    return [UIColor blackColor];
}


-(UIColor*) lightBackgroundColor {
    return [UIColor colorWithWhite:0.3f alpha:1.f];
}

-(UIColor*) transparentBackdropColor {
    return [UIColor colorWithWhite:0.13f alpha:0.9];
}

-(UIColor*) tableSeparatorColor {
    return [UIColor colorWithWhite:0.2f alpha:1.f];
}

-(UIColor*) tableSelectedBackgroundColor {
    return [UIColor colorWithWhite:0.2f alpha:1.0f];
}

- (UIColor*) groupCellBackgroundColor {
    return [UIColor colorWithWhite:0.2f alpha:1.0f];
}

- (UIColor*) groupCellSelectedBackgroundColor {
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
