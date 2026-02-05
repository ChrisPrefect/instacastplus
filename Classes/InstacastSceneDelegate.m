//
//  InstacastSceneDelegate.m
//  Instacast
//
//  Created by Devendra Kamal on 02/11/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import "InstacastSceneDelegate.h"
#import "MainViewController_4.h"
#import "InstacastAppDelegate.h"
#import <CarPlay/CarPlay.h>

#import <StoreKit/StoreKit.h>
#import "SubscriptionManager.h"

#import <Accounts/Accounts.h>


#import "Test.h"
#import "UIManager.h"
#import "CDEpisode+ShowNotes.h"

#import "DirectoryFeedViewController.h"

#import "VDModalInfo.h"
#import "ICFeedParser.h"
#import "JCommand.h"
#import "UtilityFunctions.h"
#import "FeedEpisodeExtraction.h"
#import "XPFF.h"
#import "BookmarksTableViewController.h"
#import "CDModel.h"

#import "SubscriptionsTableViewController.h"
#import "PlaybackViewController.h"
#import "PlayerController.h"
#import "PortraitNavigationController.h"
#import "ICDurationValueTransformer.h"
#import "ICPubdateValueTransformer.h"
#import "Application.h"
#import <MediaPlayer/MPVolumeView.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

#define kDonate1ProductID @"donate_to_developer_1"
#define kDonate5ProductID @"donate_to_developer_5"
#define kDonate15ProductID @"donate_to_developer_15"
#define kDonate20ProductID @"donate_to_developer_20"

@interface InstacastSceneDelegate ()
@property (strong) VDModalInfo* mInfo;
@property (strong) VDModalInfo* loadingInfo;
@property (nonatomic, strong) DirectoryFeedViewController* feedView;

@end

@implementation InstacastSceneDelegate{
    struct {
        unsigned int apnRegisterSuccess:1;
    } _flags;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
    // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
    // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        self.window.backgroundColor = ICBackgroundColor;

#if TARGET_OS_MACCATALYST
        // Set default window size to iPhone dimensions for Mac Catalyst
        CGSize iPhoneSize = CGSizeMake(390, 844); // iPhone 14 dimensions
        windowScene.sizeRestrictions.minimumSize = iPhoneSize;
        windowScene.sizeRestrictions.maximumSize = iPhoneSize;
#endif
        
        if ([DatabaseManager dataStoreNeedsMigration]) {
            UIViewController* migrationViewController = [[UIViewController alloc] initWithNibName:@"DataMigrationView" bundle:nil];
            self.window.rootViewController = migrationViewController;
            ((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window = self.window;
            [((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window makeKeyAndVisible];
        }
        else
        {
            MainViewController_4* mainViewController = [MainViewController_4 mainViewController];
            [UIManager sharedManager].mainViewController = mainViewController;
            self.window.rootViewController = mainViewController;
            ((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window = self.window;
            [((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window makeKeyAndVisible];

            // Re-apply appearance now that window exists
            [[ICAppearanceManager sharedManager] updateAppearance];
        }
    }
    [self fetchAvailableProducts];
//    if ([scene isKindOfClass:[CPTemplateApplicationScene class]]) {
//        CPTemplateApplicationScene *carPlayScene = (CPTemplateApplicationScene *)scene;
//        carPlayScene.delegate = self;
//        
//        // Create an empty CPListTemplate to act as a placeholder
//        CPListTemplate *placeholderTemplate = [[CPListTemplate alloc] initWithTitle:@"DNow Playing" sections:@[]];
//        
//        // Set the placeholder template as the root
//        [carPlayScene.interfaceController setRootTemplate:placeholderTemplate animated:YES];
//    }
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    for (UIOpenURLContext *context in URLContexts) {
        NSURL *url = context.URL;
        NSLog(@"SceneDelegate opened file: %@", url);
        NSSet* subscribeSchemes = [NSSet setWithObjects:@"pcast", @"itpc", @"podcast", @"podcast-subscribe", @"instacast-subscribe", @"instacast", nil];
        
        if ([subscribeSchemes containsObject:[url scheme]]) {
            [self _handlePcastURL:url];
        }
        else if ([url isFileURL] && [[[url path] pathExtension] compare:@"opml" options:NSCaseInsensitiveSearch] == NSOrderedSame)
        {
            self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Importing…".ls];
            [self.mInfo show];
            
            /*NSData* opmlData = [NSData dataWithContentsOfURL:url];
            [[SubscriptionManager sharedSubscriptionManager] importOPMLData:opmlData completion:^{
                [self.mInfo close];
                self.mInfo = nil;
            }];*/ //OLD to New
            
            /*BOOL access = [url startAccessingSecurityScopedResource];
            if (access) {
                NSData* opmlData = [NSData dataWithContentsOfURL:url];
                if (opmlData) {
                    [[SubscriptionManager sharedSubscriptionManager] importOPMLData:opmlData completion:^{
                        [self.mInfo close];
                        self.mInfo = nil;
                    }];
                } else {
                    NSLog(@"Failed to read OPML data from URL: %@", url);
                    [self.mInfo close];
                    self.mInfo = nil;
                }
                [url stopAccessingSecurityScopedResource];
            } else {
                NSLog(@"Failed to access security-scoped resource for URL: %@", url);
                [self.mInfo close];
                self.mInfo = nil;
            }*/
            
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                BOOL accessGranted = [url startAccessingSecurityScopedResource];
                if (!accessGranted) {
                    NSLog(@"Failed to access secure file");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf.mInfo close];
                        weakSelf.mInfo = nil;
                    });
                    return;
                }

                NSData *opmlData = [NSData dataWithContentsOfURL:url];
                [url stopAccessingSecurityScopedResource];

                if (!opmlData || opmlData.length == 0) {
                    NSLog(@"Invalid OPML data");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf.mInfo close];
                        weakSelf.mInfo = nil;
                    });
                    return;
                }

                [[SubscriptionManager sharedSubscriptionManager] importOPMLData:opmlData completion:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf.mInfo close];
                        weakSelf.mInfo = nil;
                    });
                } progress:^(float progress) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // Update UI here (e.g., progress bar or label)
                        NSLog(@"Import progress: %.2f%%", progress * 100);
                        if ((progress * 100) > 3)
                        {
                            [weakSelf.mInfo setProgress:progress];
                        }
                    });
                }];
            });
            //New End
        }
        
        /*else if ([url isFileURL] && [[[url path] pathExtension] compare:@"xpff" options:NSCaseInsensitiveSearch] == NSOrderedSame)
        {
            NSString* filename = [[url path] lastPathComponent];
            
            WEAK_SELF
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Import Bookmarks".ls message:[NSString stringWithFormat:@"Do you want to import bookmarks from '%@'?".ls, filename] preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Import".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                STRONG_SELF
                [self perform:^(id sender) {
                    
                    NSData* xpffData = [NSData dataWithContentsOfURL:url];
                    
                    XPFFImportData(xpffData, ^(NSArray *bookmarks, NSError *error) {
                        
                        for(CDBookmark* bookmark in bookmarks) {
                            [DMANAGER addBookmark:bookmark];
                        }
                        
                        [DMANAGER save];
                        
                        BookmarksTableViewController* bookmarksController = (BookmarksTableViewController*)((MainViewController_4*)self.mainViewController).contentViewController;
                        if ([bookmarksController isKindOfClass:[BookmarksTableViewController class]]) {
                            [bookmarksController reload];
                        }
                    });
                    
                } afterDelay:0.3];
                self.mainViewController.alertController = nil;
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
                STRONG_SELF
                self.mainViewController.alertController = nil;
            }]];
            
            [alert setModalPresentationStyle:UIModalPresentationPopover];
            UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
            UIViewController* rootViewController = [self getRootViewControllerDev];
            popPresenter.sourceView = [rootViewController view];
            popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
            popPresenter.permittedArrowDirections = 0;
            if ([ICAppearanceManager sharedManager].nightSettingMode)
            {
                alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            }
            else
            {
                alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
            }
            self.mainViewController.alertController = alert;
            [self.mainViewController presentAlertControllerAnimated:YES completion:NULL];
        }*/ //Old to New
        else if ([url isFileURL] && [[[url path] pathExtension] compare:@"xpff" options:NSCaseInsensitiveSearch] == NSOrderedSame)
        {
            NSString* filename = [[url path] lastPathComponent];
            
            WEAK_SELF
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Import Bookmarks".ls message:[NSString stringWithFormat:@"Do you want to import bookmarks from '%@'?".ls, filename] preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Import".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                STRONG_SELF
                [self perform:^(id sender) {
                    
                    BOOL accessGranted = [url startAccessingSecurityScopedResource];
                    if (!accessGranted) {
                        NSLog(@"Failed to access security-scoped URL: %@", url);
                        return;
                    }
                    
                    NSData* xpffData = [NSData dataWithContentsOfURL:url];
                    [url stopAccessingSecurityScopedResource];
                    
                    if (!xpffData || xpffData.length == 0) {
                        NSLog(@"XPFF file appears to be empty or unreadable: %@", url);
                        return;
                    }
                    
                    XPFFImportData(xpffData, ^(NSArray *bookmarks, NSError *error) {
                        if (error) {
                            NSLog(@"Failed to import XPFF: %@", error.localizedDescription);
                            return;
                        }
                        
                        for (CDBookmark* bookmark in bookmarks) {
                            [DMANAGER addBookmark:bookmark];
                        }
                        
                        [DMANAGER save];
                        
                        BookmarksTableViewController* bookmarksController = (BookmarksTableViewController*)((MainViewController_4*)self.mainViewController).contentViewController;
                        if ([bookmarksController isKindOfClass:[BookmarksTableViewController class]]) {
                            [bookmarksController reload];
                        }
                    });
                    
                } afterDelay:0.3];
                
                self.mainViewController.alertController = nil;
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
                STRONG_SELF
                self.mainViewController.alertController = nil;
            }]];
            
            [alert setModalPresentationStyle:UIModalPresentationPopover];
            UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
            UIViewController* rootViewController = [self getRootViewControllerDev];
            popPresenter.sourceView = [rootViewController view];
            popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
            
            if ([ICAppearanceManager sharedManager].nightSettingMode) {
                alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            } else {
                alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
            }
            
            //self.mainViewController.alertController = alert;
            //[self.mainViewController presentAlertControllerAnimated:YES completion:NULL];
            UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
            UIViewController *rootVC = keyWindow.rootViewController;
            [rootVC presentViewController:alert animated:YES completion:nil];
        }

    }
}

- (UIViewController*)getRootViewControllerDev
{
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
        rootViewController = ((MainViewController_4 *)rootViewController);
    }
    return rootViewController;
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    [self showDonatePopupAfterDelay:300];
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
    [self _updateAppContentAfterBecomingActive];
    App.applicationIconBadgeNumber = ([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0;
}

- (void) _updateAppContentAfterBecomingActive
{
    //DebugLog(@"applicationDidBecomeActive, state: %d", App.applicationState);
    App.idleTimerDisabled = [USER_DEFAULTS boolForKey:DisableAutoLock];
    
    if (_flags.apnRegisterSuccess == 0)
    {
        // iOS 8 remote notifications always work!
        if ([App respondsToSelector:@selector(registerForRemoteNotifications)]) {
            [App registerForRemoteNotifications];
        }
        
        if (![App isRegisteredForRemoteNotifications]) {
            _flags.apnRegisterSuccess = 0;
        }
    }
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
    
    // Save changes in the application's managed object context when the application transitions to the background.
    App.applicationIconBadgeNumber = ([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0;
    if (!self.mainViewController.presentedViewController) {
        [[CacheManager sharedCacheManager] tidyUp];
    }
    
    [DMANAGER saveAndSync:NO];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene  didConnectInterfaceController:(CPInterfaceController *)interfaceController {
    
    self.interfaceController = interfaceController;
    if (@available(iOS 14.0, *)) {
        CPNowPlayingTemplate *nowPlayingTemplate = [CPNowPlayingTemplate sharedTemplate];
        [interfaceController setRootTemplate:nowPlayingTemplate animated:YES];
    } else {
        // Fallback on earlier versions
    }
}



- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene didDisconnectInterfaceController:(CPInterfaceController *)interfaceController {
    self.interfaceController = nil;
}

- (void)showDonatePopupAfterDelay:(NSTimeInterval)delay {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL hasShownPopup = [defaults boolForKey:@"hasShownDonatePopup"];
    
    if (!hasShownPopup) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showPopup];
        });
    }
}

- (void)showPopup {
    UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *rootVC = keyWindow.rootViewController;
    
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Donate for further development".ls message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction* firstAction = [UIAlertAction actionWithTitle:@"$1".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [self perform:^(id sender) {
            if([validProducts valueForKey:@"product_first"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_first"]];
            }
        } afterDelay:0.01];
    }];
    [alert addAction:firstAction];
    
    UIAlertAction* secondAction = [UIAlertAction actionWithTitle:@"$5".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [self perform:^(id sender) {
            if([validProducts valueForKey:@"product_second"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_second"]];
            }
        } afterDelay:0.01];
    }];
    [alert addAction:secondAction];
    
    UIAlertAction* thirdAction = [UIAlertAction actionWithTitle:@"$15".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [self perform:^(id sender) {
          
            if([validProducts valueForKey:@"product_third"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_third"]];
            }
        } afterDelay:0.01];
    }];
    [alert addAction:thirdAction];
    
    UIAlertAction* fourthAction = [UIAlertAction actionWithTitle:@"$20".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [self perform:^(id sender) {
            if([validProducts valueForKey:@"product_fourth"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_fourth"]];
            }
        } afterDelay:0.01];
    }];
    [alert addAction:fourthAction];
    
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        //STRONG_SELF
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

    }];
    [alert addAction:defaultAction];
    
    [alert setModalPresentationStyle:UIModalPresentationPopover];
    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    UIViewController* rootViewController = [(InstacastAppDelegate*)[[UIApplication sharedApplication]delegate] getRootViewControllerDev];
    popPresenter.sourceView = [rootViewController view];
    popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
    popPresenter.permittedArrowDirections = 0;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    [rootVC presentViewController:alert animated:YES completion:nil];
    
}

-(void)fetchAvailableProducts {
    NSSet *productIdentifiers = [NSSet setWithObjects:kDonate1ProductID,kDonate5ProductID,kDonate15ProductID,kDonate20ProductID,nil];
    productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:productIdentifiers];
    productsRequest.delegate = self;
    [productsRequest start];
}

- (BOOL)canMakePurchases {
    return [SKPaymentQueue canMakePayments];
}

- (void)purchaseMyProduct:(SKProduct*)product {
    if ([self canMakePurchases]) {
        SKPayment *payment = [SKPayment paymentWithProduct:product];
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
        [[SKPaymentQueue defaultQueue] addPayment:payment];
    } else {
        [self showPurchaseAlertController:@"In app purchase are disabled in your device"];
    }
}

- (void)showPurchaseAlertController:(NSString*)titleStr
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:titleStr.ls message:nil preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Okay".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {}];
    [alert addAction:defaultAction];
    
    [alert setModalPresentationStyle:UIModalPresentationPopover];
    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    UIViewController* rootViewController = [(InstacastAppDelegate*)[[UIApplication sharedApplication]delegate] getRootViewControllerDev];
    popPresenter.sourceView = [rootViewController view];
    popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
    popPresenter.permittedArrowDirections = 0;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    
    UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *rootVC = keyWindow.rootViewController;
    [rootVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark StoreKit Delegate

-(void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStatePurchasing:
                NSLog(@"Purchasing===%@",transaction.payment.productIdentifier);
                break;
            case SKPaymentTransactionStatePurchased:
                NSLog(@"Purchased ");
                if ([transaction.payment.productIdentifier isEqualToString:kDonate1ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                else if ([transaction.payment.productIdentifier isEqualToString:kDonate5ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                else if ([transaction.payment.productIdentifier isEqualToString:kDonate15ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                else if ([transaction.payment.productIdentifier isEqualToString:kDonate20ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStateRestored:
                NSLog(@"Restored ");
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStateFailed:
                NSLog(@"Purchase failed ");
                break;
            default:
                break;
        }
    }
}

-(void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    int count = (int)[response.products count];
    if (count>0) {
        NSArray* products = response.products;
        validProducts = [[NSMutableDictionary alloc] init];
        for (SKProduct* product in products)
        {
            if ([product.productIdentifier  isEqual: kDonate1ProductID])
            {
                [validProducts setObject:product forKey:@"product_first"];
            }
            else if ([product.productIdentifier  isEqual: kDonate5ProductID])
            {
                [validProducts setObject:product forKey:@"product_second"];
            }
            else if ([product.productIdentifier  isEqual: kDonate15ProductID])
            {
                [validProducts setObject:product forKey:@"product_third"];
            }
            else if ([product.productIdentifier  isEqual: kDonate20ProductID])
            {
                [validProducts setObject:product forKey:@"product_fourth"];
            }
        }
    }
}

#pragma mark -
#pragma mark URL Handling

- (void) _handlePcastURL:(NSURL*)url
{
    NSString* urlString = [[url absoluteString] substringFromIndex:[[url scheme] length]];
    if ([urlString hasPrefix:@":http://"] || [urlString hasPrefix:@":https://"]) {
        NSString* newURLString = [urlString substringFromIndex:1];
        url = [NSURL URLWithString:newURLString];
    }
    
    // convert to http url
    if (![[url scheme] isEqualToString:@"http"] && ![[url scheme] isEqualToString:@"https"]) {
        NSString* scheme = [url scheme];
        NSString* urlString = [url absoluteString];
        urlString = [urlString stringByReplacingCharactersInRange:NSMakeRange(0, [scheme length]) withString:@"http"];
        url = [NSURL URLWithString:urlString];
    }
    
    __weak InstacastSceneDelegate* weakSelf = self;
    self.feedView = [DirectoryFeedViewController directoryFeedViewController];
    self.feedView.feedURL = url;
    self.feedView.canBeCanceled = YES;
    self.feedView.didLoadFeed = ^(BOOL success, NSError* error) {
        STRONG_SELF
        if (!success)
        {
            [weakSelf perform:^(id sender) {
                
                if (error) {
                    [self.feedView presentError:error];
                }
                
                [self.mainViewController dismissViewControllerAnimated:YES completion:^{
                    self.feedView = nil;
                }];
            } afterDelay:0.5];
            return;
        }
        
        else {
            weakSelf.feedView = nil;
        }
    };
    
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:weakSelf.feedView];
    navController.modalPresentationStyle = UIModalPresentationFormSheet;
    
    if (self.mainViewController.presentedViewController) {
        [self.mainViewController.presentedViewController presentViewController:navController animated:YES completion:NULL];
    } else {
        [self.mainViewController presentViewController:navController animated:YES completion:NULL];
    }
    
    [self.feedView startLoading];
}



@end
