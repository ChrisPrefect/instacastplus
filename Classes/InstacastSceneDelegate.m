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

#import "UIManager.h"
#import "CDEpisode+ShowNotes.h"

#import "DirectoryFeedViewController.h"

#import "VDModalInfo.h"
#import "ICFeedParser.h"
#import "UtilityFunctions.h"
#import "FeedEpisodeExtraction.h"
#import "XPFF.h"
#import "BookmarksTableViewController.h"
#import "CDModel.h"
#import "CDPlaylist.h"
#import "CDFeed+Helper.h"

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
#import "PlaybackManager.h"
#import "ICMetadata.h"
#import "ImageCacheManager.h"
#import "AudioSession+UpNextPlaylist.h"
#import "CacheManager.h"
#import "WidgetDataExporter.h"
#import "InstacastPlus-Swift.h"
#import "ListEpisodesTableViewController.h"
#import "UpNextTableViewController.h"
#import "FeedEpisodesTableViewController.h"
#import "PlayerSpeedButton.h"
#import "Defines.h"

extern NSString* MainMenuListUIDsDidChangeNotification;

#define kDonate1ProductID @"donate_to_developer_1"
#define kDonate5ProductID @"donate_to_developer_5"
#define kDonate15ProductID @"donate_to_developer_15"
#define kDonate20ProductID @"donate_to_developer_20"

@interface InstacastSceneDelegate () <CPNowPlayingTemplateObserver>
@property (strong) VDModalInfo* mInfo;
@property (strong) VDModalInfo* loadingInfo;
@property (nonatomic, strong) DirectoryFeedViewController* feedView;
@property (nonatomic, strong) CPListTemplate* carPlayRootTemplate;
@property (nonatomic, strong) NSDateFormatter* carPlayDateFormatter;
@property (nonatomic, strong) NSMapTable<CPListItem*, id>* carPlayLegacyItemHandlers;
@property (nonatomic) BOOL carPlayLastKnownIsPlaying;

@end

static NSDate* _lastAutoRefreshDate = nil;
static const NSTimeInterval kAutoRefreshCooldown = 30 * 60; // 30 minutes

@implementation InstacastSceneDelegate{
    struct {
        unsigned int apnRegisterSuccess:1;
    } _flags;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {

    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        self.window = [[ICWindow alloc] initWithWindowScene:windowScene];
        self.window.backgroundColor = ICBackgroundColor;

        // Window size restrictions for macOS and iPadOS Stage Manager.
        // iPhone 17 Pro: 402×874pt. Minimum height: -30% + 30px = 662pt.
        BOOL isiOSAppOnMac = NO;
        if (@available(iOS 14.0, *)) {
            isiOSAppOnMac = NSProcessInfo.processInfo.isiOSAppOnMac;
        }

        CGSize startSize = CGSizeMake(402, 874);
        CGSize minSize = CGSizeMake(402, 662);

#if TARGET_OS_MACCATALYST
        {
            // Mac Catalyst Fenstergrösse:
            //
            // Catalyst startet standardmässig bei 1024x768 mit System-Minimum 668x414.
            // Wir wollen: Erster Start = iPhone 17 Pro (402x874), danach gemerkte Grösse.
            //
            // Ablauf:
            // 1. minimumSize = minSize (402x662) — einmalig, wird nie geändert.
            //    Muss VOR dem System-Default gesetzt werden damit 402pt Breite akzeptiert wird.
            // 2. maximumSize = gespeicherte Grösse — erzwingt exakte Startgrösse,
            //    da das 1024x768-Fenster auf max schrumpfen muss.
            // 3. Nach 0.5s: maximumSize auf Bildschirmgrösse erweitern → frei resizebar.
            //    Catalyst wendet sizeRestrictions asynchron an, daher die Verzögerung.
            // 4. sceneWillResignActive: coordinateSpace.bounds.size speichern
            //    (gleiches Koordinatensystem wie sizeRestrictions).

            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            CGFloat savedWidth = [defaults floatForKey:@"MacWindowWidth"];
            CGFloat savedHeight = [defaults floatForKey:@"MacWindowHeight"];
            CGSize windowSize = (savedWidth > 0 && savedHeight > 0)
                ? CGSizeMake(savedWidth, savedHeight)
                : startSize;

            windowScene.sizeRestrictions.minimumSize = minSize;
            windowScene.sizeRestrictions.maximumSize = windowSize;

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                CGSize screenSize = UIScreen.mainScreen.bounds.size;
                CGFloat maxDim = MAX(screenSize.width, screenSize.height);
                windowScene.sizeRestrictions.maximumSize = CGSizeMake(maxDim, maxDim);
            });
        }
#else
        if (isiOSAppOnMac) {
            // macOS ("Designed for iPad"): nur Minimum setzen, frei resizebar
            windowScene.sizeRestrictions.minimumSize = minSize;
        } else if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
            // iPadOS Stage Manager: Start bei iPhone-Grösse, in sceneDidBecomeActive freigegeben
            windowScene.sizeRestrictions.minimumSize = minSize;
            windowScene.sizeRestrictions.maximumSize = startSize;
        }
#endif

        if ([DatabaseManager dataStoreNeedsMigration]) {
            UIViewController* migrationViewController = [[UIViewController alloc] initWithNibName:@"DataMigrationView" bundle:nil];
            self.window.rootViewController = migrationViewController;
            InstacastAppDelegate* appDelegate = (InstacastAppDelegate *)[UIApplication sharedApplication].delegate;
            self.mainViewController = nil;
            appDelegate.mainViewController = nil;
            [UIManager sharedManager].mainViewController = nil;
            appDelegate.window = self.window;
            [appDelegate.window makeKeyAndVisible];
        }
        else
        {
            MainViewController_4* mainViewController = [MainViewController_4 mainViewController];
            InstacastAppDelegate* appDelegate = (InstacastAppDelegate *)[UIApplication sharedApplication].delegate;

            self.mainViewController = mainViewController;
            appDelegate.mainViewController = mainViewController;
            [UIManager sharedManager].mainViewController = mainViewController;
            self.window.rootViewController = mainViewController;
            appDelegate.window = self.window;
            [appDelegate.window makeKeyAndVisible];

            // Re-apply appearance now that window exists
            [[ICAppearanceManager sharedManager] updateAppearance];

            // Auto-refresh feeds on app launch
            [self _autoRefreshFeedsIfNeeded];
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
        NSSet* subscribeSchemes = [NSSet setWithObjects:@"pcast", @"itpc", @"podcast", @"podcast-subscribe", @"instacast-subscribe", @"instacast", nil];
        
        if ([[url scheme] isEqualToString:@"instacastplus"]) {
            [self _handleWidgetDeepLink:url];
        }
        else if ([subscribeSchemes containsObject:[url scheme]]) {
            [self _handlePcastURL:url];
        }
        else if ([url isFileURL] && [[[url path] pathExtension] compare:@"opml" options:NSCaseInsensitiveSearch] == NSOrderedSame)
        {
            self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Importing…".ls];
            [self.mInfo show];

            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                BOOL accessGranted = [url startAccessingSecurityScopedResource];
                if (!accessGranted) {
                    ErrLog(@"Failed to access secure file");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf.mInfo close];
                        weakSelf.mInfo = nil;
                    });
                    return;
                }

                NSData *opmlData = [NSData dataWithContentsOfURL:url];
                [url stopAccessingSecurityScopedResource];

                if (!opmlData || opmlData.length == 0) {
                    ErrLog(@"Invalid OPML data");
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
                        if ((progress * 100) > 3)
                        {
                            [weakSelf.mInfo setProgress:progress];
                        }
                    });
                }];
            });
        }
        else if ([url isFileURL] && [[[url path] pathExtension] compare:@"xpff" options:NSCaseInsensitiveSearch] == NSOrderedSame)
        {
            NSString* filename = [[url path] lastPathComponent];
            
            WEAK_SELF
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Import Bookmarks".ls message:[NSString stringWithFormat:@"Do you want to import bookmarks from '%@'?".ls, filename] preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Import".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                STRONG_SELF
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    BOOL accessGranted = [url startAccessingSecurityScopedResource];
                    if (!accessGranted) {
                        ErrLog(@"Failed to access security-scoped URL: %@", url);
                        return;
                    }

                    NSData* xpffData = [NSData dataWithContentsOfURL:url];
                    [url stopAccessingSecurityScopedResource];

                    if (!xpffData || xpffData.length == 0) {
                        ErrLog(@"XPFF file appears to be empty or unreadable: %@", url);
                        return;
                    }

                    XPFFImportData(xpffData, ^(NSArray *bookmarks, NSError *error) {
                        if (error) {
                            ErrLog(@"Failed to import XPFF: %@", error.localizedDescription);
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
                });
                
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
            
            UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
            UIViewController *rootVC = keyWindow.rootViewController;
            [rootVC presentViewController:alert animated:YES completion:nil];
        }

    }
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity {
    if (![userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
        return;
    }

    NSURL *url = userActivity.webpageURL;
    if (!url || ![url.host isEqualToString:@"instacast.ch"]) {
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *feedURLString = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"url"]) {
            feedURLString = item.value;
            break;
        }
    }

    if (!feedURLString) {
        return;
    }

    NSURL *feedURL = [NSURL URLWithString:feedURLString];
    if (feedURL) {
        [self _handlePcastURL:feedURL];
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
#if !TARGET_OS_MACCATALYST
    // iPadOS Stage Manager: maximumSize freigeben (war startSize für initiale Grösse)
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
            CGSize screenSize = UIScreen.mainScreen.bounds.size;
            CGFloat maxDimension = MAX(screenSize.width, screenSize.height);
            windowScene.sizeRestrictions.maximumSize = CGSizeMake(maxDimension, maxDimension);
        }
    }
#endif
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Export widget snapshot early (before home screen becomes visible) so widgets
    // show fresh data as soon as the user switches away from the app.
    // sceneDidEnterBackground fires AFTER the home screen appears — too late for the
    // first widget render. sceneWillResignActive fires BEFORE, so this is the right place.
    [[WidgetDataExporter sharedExporter] exportNowPlayingSnapshot];
    [WidgetKitHelper reloadAllTimelines];

#if TARGET_OS_MACCATALYST
    // Mac Catalyst: Fenstergrösse in UserDefaults speichern.
    // coordinateSpace.bounds.size = gleiches Koordinatensystem wie sizeRestrictions.
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        CGSize size = windowScene.coordinateSpace.bounds.size;
        if (size.width > 0 && size.height > 0) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setFloat:size.width forKey:@"MacWindowWidth"];
            [defaults setFloat:size.height forKey:@"MacWindowHeight"];
        }
    }
#endif
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    if ([ICAppearanceManager sharedManager].appearanceMode == ICAppearanceModeAutomatic) {
        [[ICAppearanceManager sharedManager] updateAppearance];
    }
    [self _updateAppContentAfterBecomingActive];
    App.applicationIconBadgeNumber = ([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0;

    // Sync Now Playing lockscreen state with actual playback state
    [[PlaybackManager playbackManager] updateNowPlayingInfo];

    // Auto-refresh feeds if last refresh was more than 30 minutes ago
    [self _autoRefreshFeedsIfNeeded];
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

- (void) _autoRefreshFeedsIfNeeded
{
    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];

    // Skip if already refreshing
    if (sman.isRefreshing) {
        return;
    }

    // Skip if last refresh was less than 30 minutes ago
    if (_lastAutoRefreshDate && [[NSDate date] timeIntervalSinceDate:_lastAutoRefreshDate] < kAutoRefreshCooldown) {
        return;
    }

    _lastAutoRefreshDate = [NSDate date];
    [sman refreshAllFeedsForce:NO];
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
    
    // Export all widget snapshots before saving, so widgets have fresh data
    // On macOS ("Designed for iPad"), sharedExporter returns nil (no-op).
    [[WidgetDataExporter sharedExporter] exportAllSnapshots];
    // Immediate timeline reload (bypass 5s debounce that may not fire when suspended)
    [WidgetKitHelper reloadAllTimelines];

    [DMANAGER save];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene didConnectInterfaceController:(CPInterfaceController *)interfaceController {
    (void)templateApplicationScene;
    [self carPlayDidConnectInterfaceController:interfaceController];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene didDisconnectInterfaceController:(CPInterfaceController *)interfaceController {
    (void)templateApplicationScene;
    [self carPlayDidDisconnectInterfaceController:interfaceController];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene didConnectInterfaceController:(CPInterfaceController *)interfaceController toWindow:(CPWindow *)window {
    (void)templateApplicationScene;
    (void)window;
    [self carPlayDidConnectInterfaceController:interfaceController];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene didDisconnectInterfaceController:(CPInterfaceController *)interfaceController fromWindow:(CPWindow *)window {
    (void)templateApplicationScene;
    (void)window;
    [self carPlayDidDisconnectInterfaceController:interfaceController];
}

- (void)templateApplicationDashboardScene:(CPTemplateApplicationDashboardScene *)templateApplicationDashboardScene didConnectDashboardController:(CPDashboardController *)dashboardController toWindow:(UIWindow *)window API_AVAILABLE(ios(13.4))
{
    (void)templateApplicationDashboardScene;
    (void)dashboardController;
    (void)window;
}

- (void)templateApplicationDashboardScene:(CPTemplateApplicationDashboardScene *)templateApplicationDashboardScene didDisconnectDashboardController:(CPDashboardController *)dashboardController fromWindow:(UIWindow *)window API_AVAILABLE(ios(13.4))
{
    (void)templateApplicationDashboardScene;
    (void)dashboardController;
    (void)window;
}

- (void)templateApplicationInstrumentClusterScene:(CPTemplateApplicationInstrumentClusterScene *)templateApplicationInstrumentClusterScene didConnectInstrumentClusterController:(CPInstrumentClusterController *)instrumentClusterController API_AVAILABLE(ios(15.4))
{
    (void)templateApplicationInstrumentClusterScene;
    (void)instrumentClusterController;
}

- (void)templateApplicationInstrumentClusterScene:(CPTemplateApplicationInstrumentClusterScene *)templateApplicationInstrumentClusterScene didDisconnectInstrumentClusterController:(CPInstrumentClusterController *)instrumentClusterController API_AVAILABLE(ios(15.4))
{
    (void)templateApplicationInstrumentClusterScene;
    (void)instrumentClusterController;
}

- (void)carPlayDidConnectInterfaceController:(CPInterfaceController*)interfaceController
{
    if (self.interfaceController == interfaceController && self.carPlayRootTemplate) {
        return;
    }

    self.interfaceController = interfaceController;
    self.carPlayLegacyItemHandlers = [NSMapTable weakToStrongObjectsMapTable];
    PlaybackManager* playbackManager = [PlaybackManager playbackManager];
    self.carPlayLastKnownIsPlaying = (playbackManager.playingEpisode != nil && [playbackManager isPodcastPlaying]);
    __weak typeof(self) weakSelf = self;
    [playbackManager addTaskObserver:self forKeyPath:@"chapters" task:^(id obj, NSDictionary *change) {
        (void)obj;
        (void)change;
        [weakSelf carPlayPlaybackMetadataDidUpdate];
    }];

    self.carPlayRootTemplate = [self carPlayMainMenuTemplate];
    [self carPlaySetRootTemplate:self.carPlayRootTemplate onInterfaceController:interfaceController animated:YES];

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(carPlayFeedsDidUpdate:) name:DatabaseManagerDidUpdateObservedFeedNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayDataDidUpdate:) name:DatabaseManagerDidAddBookmarkNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayDataDidUpdate:) name:MainMenuListUIDsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayDataDidUpdate:) name:CDPlaylistDidChangeEpisodesNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayContextObjectsDidChange:) name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];
    [nc addObserver:self selector:@selector(carPlayCacheDidUpdate:) name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayCacheDidUpdate:) name:CacheManagerDidClearCacheNotification object:nil];

    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidStartNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidChangeEpisodeNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidUpdateNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidEndNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayAudioSessionDidRestorePlayback:) name:AudioSessionDidRestorePlaybackNotification object:nil];

    if (@available(iOS 14.0, *)) {
        [[CPNowPlayingTemplate sharedTemplate] addObserver:self];
    }

    [self carPlayPreloadChapterArtworkData];
    [self carPlayUpdateNowPlayingTemplateConfiguration];
    [self carPlayApplySleepTimerPolicy];
}

- (void)carPlayDidDisconnectInterfaceController:(CPInterfaceController*)interfaceController
{
    if (self.interfaceController && interfaceController && self.interfaceController != interfaceController) {
        return;
    }

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:DatabaseManagerDidUpdateObservedFeedNotification object:nil];
    [nc removeObserver:self name:DatabaseManagerDidAddBookmarkNotification object:nil];
    [nc removeObserver:self name:MainMenuListUIDsDidChangeNotification object:nil];
    [nc removeObserver:self name:CDPlaylistDidChangeEpisodesNotification object:nil];
    [nc removeObserver:self name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];
    [nc removeObserver:self name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
    [nc removeObserver:self name:CacheManagerDidClearCacheNotification object:nil];
    [nc removeObserver:self name:PlaybackManagerDidStartNotification object:nil];
    [nc removeObserver:self name:PlaybackManagerDidChangeEpisodeNotification object:nil];
    [nc removeObserver:self name:PlaybackManagerDidUpdateNotification object:nil];
    [nc removeObserver:self name:PlaybackManagerDidEndNotification object:nil];
    [nc removeObserver:self name:AudioSessionDidRestorePlaybackNotification object:nil];

    if (@available(iOS 14.0, *)) {
        [[CPNowPlayingTemplate sharedTemplate] removeObserver:self];
    }

    [[PlaybackManager playbackManager] removeTaskObserver:self forKeyPath:@"chapters"];

    [self carPlayRestoreSleepTimerAfterDisconnectIfNeeded];
    self.carPlayRootTemplate = nil;
    self.interfaceController = nil;
    self.carPlayLegacyItemHandlers = nil;
    self.carPlayLastKnownIsPlaying = NO;
}

#pragma mark - CarPlay Helpers

static NSString* const kCarPlayTemplateKindKey = @"kind";
static NSString* const kCarPlayTemplateKindRoot = @"root";
static NSString* const kCarPlayTemplateKindPodcasts = @"podcasts";
static NSString* const kCarPlayTemplateKindFeedEpisodes = @"feedEpisodes";
static NSString* const kCarPlayTemplateKindListEpisodes = @"listEpisodes";
static NSString* const kCarPlayTemplateKindAllLists = @"allLists";
static NSString* const kCarPlayTemplateKindUpNext = @"upNext";
static NSString* const kCarPlayTemplateKindBookmarks = @"bookmarks";
static NSString* const kCarPlayTemplateKindChapters = @"chapters";
static NSString* const kCarPlayTemplateSourceKey = @"source";
static NSUInteger const kCarPlayEpisodeLimit = 100;

- (void)carPlaySetRootTemplate:(CPTemplate*)template onInterfaceController:(CPInterfaceController*)interfaceController animated:(BOOL)animated
{
    if (!interfaceController || !template) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        [interfaceController setRootTemplate:template animated:animated completion:nil];
    }
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [interfaceController setRootTemplate:template animated:animated];
#pragma clang diagnostic pop
    }
}

- (void)carPlayPushTemplate:(CPTemplate*)template animated:(BOOL)animated
{
    if (!self.interfaceController || !template) {
        return;
    }

    NSArray* templateStack = self.interfaceController.templates ?: @[];
    if (self.interfaceController.topTemplate == template) {
        return;
    }
    if ([templateStack containsObject:template]) {
        if (@available(iOS 14.0, *)) {
            [self.interfaceController popToTemplate:template animated:animated completion:nil];
        }
        else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [self.interfaceController popToTemplate:template animated:animated];
#pragma clang diagnostic pop
        }
        return;
    }

    if (@available(iOS 14.0, *)) {
        [self.interfaceController pushTemplate:template animated:animated completion:nil];
    }
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.interfaceController pushTemplate:template animated:animated];
#pragma clang diagnostic pop
    }
}

- (void)carPlayPopTemplateAnimated:(BOOL)animated
{
    if (!self.interfaceController) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        [self.interfaceController popTemplateAnimated:animated completion:nil];
    }
    else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self.interfaceController popTemplateAnimated:animated];
#pragma clang diagnostic pop
    }
}

- (void)carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:(CPListTemplate*)template
{
    if (!template) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    template.delegate = (id)self;
#pragma clang diagnostic pop
}

- (void)carPlayAssignSelectionHandlerForItem:(CPListItem*)item handler:(dispatch_block_t)handler
{
    if (!item || !handler) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        item.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
            handler();
            completionHandler();
        };
    }
    else {
        if (!self.carPlayLegacyItemHandlers) {
            self.carPlayLegacyItemHandlers = [NSMapTable weakToStrongObjectsMapTable];
        }
        [self.carPlayLegacyItemHandlers setObject:[handler copy] forKey:item];
    }
}

- (void)carPlaySetImage:(UIImage*)image forListItem:(CPListItem*)item
{
    if (!image || !item) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        [item setImage:image];
    }
}

- (CPListItem*)carPlayListItemWithText:(NSString*)text detailText:(NSString*)detailText image:(UIImage*)image
{
    if (image) {
        return [[CPListItem alloc] initWithText:text detailText:detailText image:image];
    }
    return [[CPListItem alloc] initWithText:text detailText:detailText];
}

- (UIImage*)carPlayTemplatedImage:(UIImage*)image
{
    if (!image) {
        return nil;
    }
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)carPlaySetTrailingSymbolImage:(UIImage*)image forListItem:(CPListItem*)item
{
    if (!image || !item) {
        return;
    }

    if (@available(iOS 14.0, *)) {
        [item setAccessoryImage:[self carPlayTemplatedImage:image]];
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)listTemplate:(CPListTemplate *)listTemplate didSelectListItem:(CPListItem *)item completionHandler:(void (^)(void))completionHandler
{
    (void)listTemplate;
    dispatch_block_t legacyHandler = (dispatch_block_t)[self.carPlayLegacyItemHandlers objectForKey:item];
    if (legacyHandler) {
        legacyHandler();
    }

    if (completionHandler) {
        completionHandler();
    }
}
#pragma clang diagnostic pop

- (NSDateFormatter*)carPlayDateFormatter
{
    if (!_carPlayDateFormatter) {
        _carPlayDateFormatter = [[NSDateFormatter alloc] init];
        _carPlayDateFormatter.dateStyle = NSDateFormatterShortStyle;
        _carPlayDateFormatter.timeStyle = NSDateFormatterNoStyle;
    }
    return _carPlayDateFormatter;
}

- (NSDictionary*)carPlayTemplateInfoWithKind:(NSString*)kind source:(id)source
{
    NSMutableDictionary* info = [NSMutableDictionary dictionaryWithObject:kind forKey:kCarPlayTemplateKindKey];
    if (source) {
        info[kCarPlayTemplateSourceKey] = source;
    }
    return info;
}

- (void)carPlayApplySleepTimerPolicy
{
    if (![USER_DEFAULTS boolForKey:DisableSleepTimerInCarPlay]) {
        return;
    }

    [AudioSession sharedAudioSession].timerValue = PlaybackStopTimeNoValue;
}

- (void)carPlayRestoreSleepTimerAfterDisconnectIfNeeded
{
    if (![USER_DEFAULTS boolForKey:DisableSleepTimerInCarPlay]) {
        return;
    }

    if (![PlaybackManager playbackManager].isPodcastPlaying) {
        return;
    }

    if (![USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive]) {
        return;
    }

    NSInteger timer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    if (timer == PlaybackStopTimeNoValue) {
        NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
        timer = (lastSleepTimer > 0) ? lastSleepTimer : PlaybackStopTime5min;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [AudioSession sharedAudioSession].timerValue = timer;
    });
}

- (void)carPlayFeedsDidUpdate:(NSNotification*)notification
{
    [self carPlayDataDidUpdate:notification];
}

- (void)carPlayDataDidUpdate:(NSNotification*)notification
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self carPlayDataDidUpdate:notification];
        });
        return;
    }

    if (!self.interfaceController) {
        return;
    }

    [self carPlayUpdateNowPlayingTemplateConfiguration];
    [self carPlayRefreshRootTemplate];
    [self carPlayRefreshVisibleTemplateIfNeeded];
}

- (void)carPlayAudioSessionDidRestorePlayback:(NSNotification*)notification
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self carPlayAudioSessionDidRestorePlayback:notification];
        });
        return;
    }

    if (!self.interfaceController) {
        return;
    }

    [self carPlayUpdateNowPlayingTemplateConfiguration];
    [self carPlayRefreshVisibleTemplateIfNeeded];
}

- (void)carPlayContextObjectsDidChange:(NSNotification*)notification
{
    if (!self.interfaceController) {
        return;
    }

    NSDictionary* userInfo = notification.userInfo;
    NSArray* changeKeys = @[NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey];
    BOOL containsBookmarkChange = NO;
    BOOL containsEpisodeChange = NO;
    BOOL containsPodcastOrListChange = NO;

    for (NSString* key in changeKeys) {
        NSSet* objects = userInfo[key];
        for (NSManagedObject* object in objects) {
            if ([object isKindOfClass:[CDBookmark class]]) {
                containsBookmarkChange = YES;
            }
            else if ([object isKindOfClass:[CDEpisode class]]) {
                containsEpisodeChange = YES;
            }
            else if ([object isKindOfClass:[CDChapter class]]) {
                containsEpisodeChange = YES;
            }
            else if ([object isKindOfClass:[CDFeed class]] ||
                     [object isKindOfClass:[CDEpisodeList class]] ||
                     [object isKindOfClass:[CDPlaylist class]]) {
                containsPodcastOrListChange = YES;
            }
        }
        if (containsBookmarkChange && containsEpisodeChange && containsPodcastOrListChange) {
            break;
        }
    }

    if (containsBookmarkChange || containsEpisodeChange || containsPodcastOrListChange) {
        [self carPlayDataDidUpdate:notification];
    }
}

- (void)carPlayCacheDidUpdate:(NSNotification*)notification
{
    [self carPlayDataDidUpdate:notification];
}

- (void)carPlayPlaybackMetadataDidUpdate
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self carPlayPlaybackMetadataDidUpdate];
        });
        return;
    }

    if (!self.interfaceController) {
        return;
    }

    [self carPlayPreloadChapterArtworkData];
    [self carPlayUpdateNowPlayingTemplateConfiguration];

    CPTemplate* topTemplate = self.interfaceController.topTemplate;
    if ([topTemplate isKindOfClass:[CPListTemplate class]]) {
        CPListTemplate* listTemplate = (CPListTemplate*)topTemplate;
        NSDictionary* info = ([listTemplate.userInfo isKindOfClass:[NSDictionary class]]) ? (NSDictionary*)listTemplate.userInfo : nil;
        NSString* kind = info[kCarPlayTemplateKindKey];
        if ([kind isEqualToString:kCarPlayTemplateKindChapters]) {
            [listTemplate updateSections:[self carPlayChapterSections]];
        }
    }
}

- (void)carPlayPreloadChapterArtworkData
{
    PlaybackManager* playbackManager = [PlaybackManager playbackManager];
    for (id artworkObject in playbackManager.artworks) {
        if (![artworkObject isKindOfClass:[ICMetadataImage class]]) {
            continue;
        }

        ICMetadataImage* artwork = (ICMetadataImage*)artworkObject;
        if (artwork.data.length > 0) {
            continue;
        }

        [artwork loadPlatformImageWithCompletion:^(id platformImage) {
            (void)platformImage;
        }];
    }
}

- (UIImage*)carPlayImageIfAlreadyAvailableForMetadataArtwork:(ICMetadataImage*)artwork
{
    if (![artwork isKindOfClass:[ICMetadataImage class]]) {
        return nil;
    }

    NSData* data = artwork.data;
    if (data.length == 0) {
        if (artwork.url.isFileURL) {
            data = [NSData dataWithContentsOfURL:artwork.url];
            if (data.length > 0) {
                artwork.data = data;
            }
        } else {
            return nil;
        }
    }

    return [UIImage imageWithData:data];
}

- (void)carPlayPlaybackDidUpdate:(NSNotification*)notification
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self carPlayPlaybackDidUpdate:notification];
        });
        return;
    }

    if (!self.interfaceController) {
        return;
    }

    PlaybackManager* playbackManager = [PlaybackManager playbackManager];
    BOOL isPlayingNow = (playbackManager.playingEpisode != nil && [playbackManager isPodcastPlaying]);
    if (isPlayingNow && !self.carPlayLastKnownIsPlaying) {
        [self carPlayShowNowPlayingTemplate];
    }
    self.carPlayLastKnownIsPlaying = isPlayingNow;

    [self carPlayUpdateNowPlayingTemplateConfiguration];

    if ([notification.name isEqualToString:PlaybackManagerDidUpdateNotification]) {
        [self carPlayUpdateVisiblePlaybackStateIfNeeded];
        return;
    }

    if ([notification.name isEqualToString:PlaybackManagerDidStartNotification] ||
        [notification.name isEqualToString:PlaybackManagerDidChangeEpisodeNotification] ||
        [notification.name isEqualToString:PlaybackManagerDidEndNotification])
    {
        [self carPlayUpdateVisiblePlaybackStateIfNeeded];

        CPTemplate* topTemplate = self.interfaceController.topTemplate;
        if ([topTemplate isKindOfClass:[CPListTemplate class]]) {
            CPListTemplate* listTemplate = (CPListTemplate*)topTemplate;
            NSDictionary* info = ([listTemplate.userInfo isKindOfClass:[NSDictionary class]]) ? (NSDictionary*)listTemplate.userInfo : nil;
            NSString* kind = info[kCarPlayTemplateKindKey];
            if ([kind isEqualToString:kCarPlayTemplateKindChapters]) {
                [listTemplate updateSections:[self carPlayChapterSections]];
            }
        }
        return;
    }

    [self carPlayRefreshVisibleTemplateIfNeeded];
}

- (void)carPlayRefreshRootTemplate
{
    if (!self.carPlayRootTemplate) {
        return;
    }

    [self.carPlayRootTemplate updateSections:[self carPlayMainMenuSections]];
}

- (void)carPlayRefreshVisibleTemplateIfNeeded
{
    CPTemplate* topTemplate = self.interfaceController.topTemplate;
    if (![topTemplate isKindOfClass:[CPListTemplate class]]) {
        return;
    }

    CPListTemplate* listTemplate = (CPListTemplate*)topTemplate;
    NSDictionary* info = ([listTemplate.userInfo isKindOfClass:[NSDictionary class]]) ? (NSDictionary*)listTemplate.userInfo : nil;
    NSString* kind = info[kCarPlayTemplateKindKey];

    if ([kind isEqualToString:kCarPlayTemplateKindRoot]) {
        [self carPlayRefreshRootTemplate];
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindPodcasts]) {
        [listTemplate updateSections:[self carPlayPodcastSections]];
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindFeedEpisodes]) {
        CDFeed* feed = info[kCarPlayTemplateSourceKey];
        if ([feed isKindOfClass:[CDFeed class]]) {
            [listTemplate updateSections:[self carPlaySectionsForEpisodes:[[feed sortedEpisodes] copy]]];
        }
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindListEpisodes]) {
        CDEpisodeList* list = info[kCarPlayTemplateSourceKey];
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            [listTemplate updateSections:[self carPlaySectionsForEpisodes:[list sortedEpisodes]]];
        }
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindAllLists]) {
        [listTemplate updateSections:[self carPlayAllListsSections]];
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindUpNext]) {
        [listTemplate updateSections:[self carPlaySectionsForEpisodes:[AudioSession sharedAudioSession].playlist]];
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindBookmarks]) {
        [listTemplate updateSections:[self carPlayBookmarksSections]];
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindChapters]) {
        [listTemplate updateSections:[self carPlayChapterSections]];
    }
}

- (void)carPlayUpdateVisiblePlaybackStateIfNeeded
{
    CPTemplate* topTemplate = self.interfaceController.topTemplate;
    if (![topTemplate isKindOfClass:[CPListTemplate class]]) {
        return;
    }

    CPListTemplate* listTemplate = (CPListTemplate*)topTemplate;
    NSDictionary* info = ([listTemplate.userInfo isKindOfClass:[NSDictionary class]]) ? (NSDictionary*)listTemplate.userInfo : nil;
    NSString* kind = info[kCarPlayTemplateKindKey];

    if ([kind isEqualToString:kCarPlayTemplateKindFeedEpisodes] ||
        [kind isEqualToString:kCarPlayTemplateKindListEpisodes] ||
        [kind isEqualToString:kCarPlayTemplateKindUpNext])
    {
        [self carPlayUpdateEpisodeItemsInTemplate:listTemplate];
    }
    else if ([kind isEqualToString:kCarPlayTemplateKindChapters])
    {
        [self carPlayUpdateChapterItemsInTemplate:listTemplate];
    }
}

- (void)carPlayUpdateEpisodeItemsInTemplate:(CPListTemplate*)listTemplate
{
    for (CPListSection* section in listTemplate.sections) {
        for (id<CPListTemplateItem> listItem in section.items) {
            if (![listItem isKindOfClass:[CPListItem class]]) {
                continue;
            }

            CPListItem* item = (CPListItem*)listItem;
            if (![item.userInfo isKindOfClass:[CDEpisode class]]) {
                continue;
            }

            CDEpisode* episode = (CDEpisode*)item.userInfo;
            BOOL isCurrent = [self carPlayEpisodeIsCurrent:episode];

            if (isCurrent) {
                NSString* detailText = [self carPlayEpisodeDetailText:episode];
                if (@available(iOS 14.0, *)) {
                    if (![(item.detailText ?: @"") isEqualToString:(detailText ?: @"")]) {
                        [item setDetailText:detailText];
                    }
                }
            }

            if (@available(iOS 14.0, *)) {
                if (isCurrent) {
                    item.playbackProgress = [self carPlayPlaybackProgressForEpisode:episode];
                }
                if (item.playing) {
                    item.playing = NO;
                }
            }
        }
    }
}

- (void)carPlayUpdateChapterItemsInTemplate:(CPListTemplate*)listTemplate
{
    if (@available(iOS 14.0, *)) {
        NSInteger currentChapter = [PlaybackManager playbackManager].currentChapter;
        for (CPListSection* section in listTemplate.sections) {
            for (id<CPListTemplateItem> listItem in section.items) {
                if (![listItem isKindOfClass:[CPListItem class]]) {
                    continue;
                }
                CPListItem* item = (CPListItem*)listItem;
                NSNumber* chapterIndex = item.userInfo;
                if (![chapterIndex isKindOfClass:[NSNumber class]]) {
                    continue;
                }
                BOOL isPlayingChapter = (chapterIndex.integerValue == currentChapter);
                if (item.playing != isPlayingChapter) {
                    item.playing = isPlayingChapter;
                }
            }
        }
    }
}

- (CPListTemplate*)carPlayMainMenuTemplate
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"InstacastPlus" sections:[self carPlayMainMenuSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindRoot source:nil];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    return template;
}

- (NSArray<CPListSection*>*)carPlayMainMenuSections
{
    NSMutableArray* items = [NSMutableArray array];

    CPListItem* podcastsItem = [[CPListItem alloc] initWithText:@"Podcasts".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)DMANAGER.feeds.count, @"Podcasts".ls]];
    [self carPlayAssignSelectionHandlerForItem:podcastsItem handler:^{
        [self carPlayShowPodcasts];
    }];
    [self carPlaySetTrailingSymbolImage:[UIImage imageNamed:@"Menu Subscriptions"] forListItem:podcastsItem];
    [items addObject:podcastsItem];

    NSArray* menuUIDs = [USER_DEFAULTS objectForKey:@"MainMenuListUIDs"];
    BOOL downloadedInMainMenu = NO;
    if ([menuUIDs isKindOfClass:[NSArray class]]) {
        for (NSString* uid in menuUIDs) {
            if ([uid isEqualToString:@"default.downloaded"]) {
                downloadedInMainMenu = YES;
            }
            CDEpisodeList* list = [self carPlayEpisodeListForUID:uid];
            if (list) {
                [items addObject:[self carPlayRootListItemForEpisodeList:list]];
            }
        }
    }

    CPListItem* listsItem = [[CPListItem alloc] initWithText:@"Lists".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)DMANAGER.lists.count, @"Lists".ls]];
    [self carPlayAssignSelectionHandlerForItem:listsItem handler:^{
        [self carPlayShowAllLists];
    }];
    [self carPlaySetTrailingSymbolImage:[UIImage imageNamed:@"Menu Lists"] forListItem:listsItem];
    [items addObject:listsItem];

    CPListItem* upNextItem = [[CPListItem alloc] initWithText:@"Play Next".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)[AudioSession sharedAudioSession].playlist.count, @"Episodes".ls]];
    [self carPlayAssignSelectionHandlerForItem:upNextItem handler:^{
        [self carPlayShowUpNext];
    }];
    [self carPlaySetTrailingSymbolImage:[UIImage systemImageNamed:@"list.bullet.indent"] forListItem:upNextItem];
    [items addObject:upNextItem];

    CPListItem* bookmarksItem = [[CPListItem alloc] initWithText:@"Bookmarks".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)DMANAGER.bookmarks.count, @"Bookmarks".ls]];
    [self carPlayAssignSelectionHandlerForItem:bookmarksItem handler:^{
        [self carPlayShowBookmarks];
    }];
    [self carPlaySetTrailingSymbolImage:[UIImage imageNamed:@"Menu Bookmarks"] forListItem:bookmarksItem];
    [items addObject:bookmarksItem];

    if (!downloadedInMainMenu) {
        CDEpisodeList* downloadedList = [self carPlayEpisodeListForUID:@"default.downloaded"];
        CPListItem* downloadsItem = [[CPListItem alloc] initWithText:@"Downloaded".ls detailText:[self carPlayEpisodeCountDetailTextForList:downloadedList]];
        [self carPlayAssignSelectionHandlerForItem:downloadsItem handler:^{
            if (downloadedList) {
                [self carPlayShowEpisodesForList:downloadedList];
            }
        }];
        [self carPlaySetTrailingSymbolImage:[UIImage imageNamed:@"Menu Downloads"] forListItem:downloadsItem];
        [self carPlayRefreshEpisodeCountForList:downloadedList item:downloadsItem];
        [items addObject:downloadsItem];
    }

    CPListSection* section = [[CPListSection alloc] initWithItems:items];
    return @[section];
}

- (CDEpisodeList*)carPlayEpisodeListForUID:(NSString*)uid
{
    for (CDList* list in DMANAGER.lists) {
        if ([list isKindOfClass:[CDEpisodeList class]] && [list.uid isEqualToString:uid]) {
            return (CDEpisodeList*)list;
        }
    }
    return nil;
}

- (NSString*)carPlayEpisodeCountDetailTextForList:(CDList*)list
{
    if (!list) {
        return [NSString stringWithFormat:@"%lu %@", (unsigned long)0, @"Episodes".ls];
    }

    // CDEpisodeList invalidates cached count aggressively; numberOfEpisodes can transiently be 0.
    // Use sortedEpisodes as a synchronous fallback for immediate display.
    NSUInteger count = [list numberOfEpisodes];
    if (count == 0) {
        NSArray* episodes = [list sortedEpisodes];
        if ([episodes isKindOfClass:[NSArray class]]) {
            count = episodes.count;
        }
    }

    return [NSString stringWithFormat:@"%lu %@", (unsigned long)count, @"Episodes".ls];
}

- (void)carPlayRefreshEpisodeCountForList:(CDList*)list item:(CPListItem*)item
{
    if (!list || !item) {
        return;
    }

    [list calculateNumberOfEpisodesCompletion:^(NSUInteger numberOfEpisodes) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString* detail = [NSString stringWithFormat:@"%lu %@", (unsigned long)numberOfEpisodes, @"Episodes".ls];
            if (@available(iOS 14.0, *)) {
                if (![(item.detailText ?: @"") isEqualToString:(detail ?: @"")]) {
                    [item setDetailText:detail];
                }
            }
        });
    }];
}

- (CPListItem*)carPlayRootListItemForEpisodeList:(CDEpisodeList*)list
{
    NSString* detail = [self carPlayEpisodeCountDetailTextForList:list];
    CPListItem* item = [[CPListItem alloc] initWithText:list.name detailText:detail];

    [self carPlayAssignSelectionHandlerForItem:item handler:^{
        [self carPlayShowEpisodesForList:list];
    }];
    [self carPlaySetTrailingSymbolImage:(UIImage*)list.image forListItem:item];
    [self carPlayRefreshEpisodeCountForList:list item:item];

    return item;
}

- (void)carPlayShowPodcasts
{
    CPListTemplate* template = [self carPlayPodcastListTemplate];
    [self carPlayPushTemplate:template animated:YES];
}

- (CPListTemplate*)carPlayPodcastListTemplate
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Podcasts".ls sections:[self carPlayPodcastSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindPodcasts source:nil];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    return template;
}

- (NSArray<CPListSection*>*)carPlayPodcastSections
{
    NSArray* feeds = DMANAGER.feeds;
    NSMutableArray* items = [NSMutableArray arrayWithCapacity:feeds.count];
    for (CDFeed* feed in feeds) {
        [items addObject:[self carPlayListItemForFeed:feed]];
    }
    return @[[[CPListSection alloc] initWithItems:items]];
}

- (CPListItem*)carPlayListItemForFeed:(CDFeed*)feed
{
    NSString* detail = [NSString stringWithFormat:@"%ld %@", (long)feed.episodesCount, @"Episodes".ls];
    UIImage* cachedImage = nil;
    if (feed.imageURL) {
        cachedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:feed.imageURL size:72 grayscale:NO];
    }
    CPListItem* item = [self carPlayListItemWithText:feed.title detailText:detail image:cachedImage];
    item.userInfo = feed;

    [self carPlayAssignSelectionHandlerForItem:item handler:^{
        [self carPlayShowEpisodesForFeed:feed];
    }];

    if (feed.imageURL) {
        [ImageCacheManager loadImageForURL:feed.imageURL size:72 grayscale:NO completion:^(UIImage *image, NSError *error) {
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self carPlaySetImage:image forListItem:item];
                });
            }
        }];
    }

    return item;
}

- (void)carPlayShowAllLists
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Lists".ls sections:[self carPlayAllListsSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindAllLists source:nil];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    [self carPlayPushTemplate:template animated:YES];
}

- (NSArray<CPListSection*>*)carPlayAllListsSections
{
    NSMutableArray* items = [NSMutableArray array];
    for (CDList* list in DMANAGER.lists) {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            [items addObject:[self carPlayRootListItemForEpisodeList:(CDEpisodeList*)list]];
        }
    }
    return @[[[CPListSection alloc] initWithItems:items]];
}

- (void)carPlayShowUpNext
{
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Play Next".ls sections:[self carPlaySectionsForEpisodes:playlist]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindUpNext source:nil];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    [self carPlayPushTemplate:template animated:YES];
}

- (void)carPlayShowBookmarks
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Bookmarks".ls sections:[self carPlayBookmarksSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindBookmarks source:nil];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    [self carPlayPushTemplate:template animated:YES];
}

- (NSArray<CPListSection*>*)carPlayBookmarksSections
{
    NSMutableDictionary* latestBookmarksByEpisode = [NSMutableDictionary dictionary];
    for (CDBookmark* bookmark in DMANAGER.bookmarks) {
        if (bookmark.episodeHash.length > 0) {
            latestBookmarksByEpisode[bookmark.episodeHash] = bookmark;
        }
    }

    NSArray* uniqueBookmarks = [latestBookmarksByEpisode.allValues sortedArrayUsingComparator:^NSComparisonResult(CDBookmark* obj1, CDBookmark* obj2) {
        NSString* feed1 = obj1.feedTitle ?: @"";
        NSString* feed2 = obj2.feedTitle ?: @"";
        NSComparisonResult feedResult = [feed1 localizedCaseInsensitiveCompare:feed2];
        if (feedResult != NSOrderedSame) {
            return feedResult;
        }
        NSString* episode1 = obj1.episodeTitle ?: @"";
        NSString* episode2 = obj2.episodeTitle ?: @"";
        return [episode1 localizedCaseInsensitiveCompare:episode2];
    }];

    NSMutableArray* items = [NSMutableArray arrayWithCapacity:uniqueBookmarks.count];
    for (CDBookmark* bookmark in uniqueBookmarks) {
        CDEpisode* episode = [DMANAGER episodeWithObjectHash:bookmark.episodeHash];
        if (!episode) {
            continue;
        }

        NSString* title = bookmark.episodeTitle ?: episode.title;
        NSString* feedTitle = bookmark.feedTitle ?: episode.feed.title;
        NSString* detail = [NSString stringWithFormat:@"%@ • %@", feedTitle, [self carPlayFormattedTimecode:(NSInteger)bookmark.position]];
        CPListItem* item = [[CPListItem alloc] initWithText:title detailText:detail];

        [self carPlayAssignSelectionHandlerForItem:item handler:^{
            CDEpisode* selectedEpisode = [DMANAGER episodeWithObjectHash:bookmark.episodeHash];
            if (selectedEpisode) {
                [self carPlayPlayEpisode:selectedEpisode at:MAX(0, bookmark.position)];
            }
        }];

        NSURL* artURL = bookmark.imageURL ?: episode.imageURL ?: episode.feed.imageURL;
        if (artURL) {
            [ImageCacheManager loadImageForURL:artURL size:80 grayscale:NO completion:^(UIImage *image, NSError *error) {
                if (image) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self carPlaySetImage:image forListItem:item];
                    });
                }
            }];
        }

        [items addObject:item];
    }

    return @[[[CPListSection alloc] initWithItems:items]];
}

- (void)carPlayShowEpisodesForFeed:(CDFeed*)feed
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:feed.title sections:[self carPlaySectionsForEpisodes:[feed sortedEpisodes]]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindFeedEpisodes source:feed];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    [self carPlayPushTemplate:template animated:YES];
}

- (void)carPlayShowEpisodesForList:(CDEpisodeList*)list
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:list.name sections:[self carPlaySectionsForEpisodes:[list sortedEpisodes]]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindListEpisodes source:list];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    [self carPlayPushTemplate:template animated:YES];
}

- (NSArray<CPListSection*>*)carPlaySectionsForEpisodes:(NSArray*)episodes
{
    NSUInteger limit = MIN(episodes.count, kCarPlayEpisodeLimit);
    NSMutableArray* items = [NSMutableArray arrayWithCapacity:limit];

    for (NSUInteger index = 0; index < limit; index++) {
        CDEpisode* episode = episodes[index];
        [items addObject:[self carPlayListItemForEpisode:episode]];
    }

    return @[[[CPListSection alloc] initWithItems:items]];
}

- (BOOL)carPlayEpisodeIsCurrent:(CDEpisode*)episode
{
    CDEpisode* currentEpisode = [AudioSession sharedAudioSession].episode ?: [PlaybackManager playbackManager].playingEpisode;
    if (!currentEpisode || !episode.objectHash.length) {
        return NO;
    }
    return [currentEpisode.objectHash isEqualToString:episode.objectHash];
}

- (double)carPlayPlaybackProgressForEpisode:(CDEpisode*)episode
{
    if (episode.duration <= 0) {
        return 0.0;
    }

    PlaybackManager* playbackManager = [PlaybackManager playbackManager];
    if ([self carPlayEpisodeIsCurrent:episode] && playbackManager.ready) {
        return MIN(MAX(playbackManager.position, 0.0), 1.0);
    }

    double progress = (double)episode.position / (double)episode.duration;
    return MIN(MAX(progress, 0.0), 1.0);
}

- (NSString*)carPlayEpisodeDetailText:(CDEpisode*)episode
{
    NSMutableArray* markers = [NSMutableArray array];
    if (episode.consumed) {
        [markers addObject:@"✓"];
    }
    if (episode.starred) {
        [markers addObject:@"★"];
    }

    NSMutableArray* parts = [NSMutableArray array];

    if (!episode.consumed && episode.duration > 0) {
        [parts addObject:[self carPlayFormattedDuration:episode.duration]];
    }
    if (episode.pubDate) {
        [parts addObject:[[self carPlayDateFormatter] stringFromDate:episode.pubDate]];
    }

    NSString* markersText = (markers.count > 0) ? [markers componentsJoinedByString:@" "] : nil;
    NSString* partsText = (parts.count > 0) ? [parts componentsJoinedByString:@" • "] : nil;

    if (markersText.length > 0 && partsText.length > 0) {
        return [NSString stringWithFormat:@"%@ %@", markersText, partsText];
    }
    if (markersText.length > 0) {
        return markersText;
    }
    return partsText;
}

- (BOOL)carPlayEpisodeIsDownloaded:(CDEpisode*)episode
{
    if (!episode) {
        return NO;
    }
    return [[CacheManager sharedCacheManager] episodeIsCached:episode fastLookup:YES];
}

- (UIImage*)carPlaySymbolImageNamed:(NSString*)symbolName pointSize:(CGFloat)pointSize
{
    if (!symbolName.length) {
        return nil;
    }

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration* configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize];
        UIImage* image = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
        if (image) {
            return image;
        }
        return [UIImage systemImageNamed:symbolName];
    }

    return nil;
}

- (UIImage*)carPlayEpisodeAccessoryImage:(CDEpisode*)episode
{
    if (![self carPlayEpisodeIsDownloaded:episode]) {
        return nil;
    }

    UIImage* downloadedImage = [self carPlaySymbolImageNamed:@"arrow.down.circle.fill" pointSize:16.0f];
    if (!downloadedImage) {
        downloadedImage = [UIImage imageNamed:@"Menu Downloads"];
    }
    return downloadedImage;
}

- (CPListItem*)carPlayListItemForEpisode:(CDEpisode*)episode
{
    CPListItem* item = [self carPlayListItemWithText:episode.title detailText:[self carPlayEpisodeDetailText:episode] image:nil];
    item.userInfo = episode;

    [self carPlaySetTrailingSymbolImage:[self carPlayEpisodeAccessoryImage:episode] forListItem:item];

    if (@available(iOS 14.0, *)) {
        item.playbackProgress = [self carPlayPlaybackProgressForEpisode:episode];
        item.playing = NO;
        item.playingIndicatorLocation = CPListItemPlayingIndicatorLocationTrailing;
    }

    [self carPlayAssignSelectionHandlerForItem:item handler:^{
        [self carPlayPlayEpisode:episode at:MAX(0, episode.position)];
    }];

    return item;
}

- (void)carPlayPlayEpisode:(CDEpisode*)episode at:(NSTimeInterval)startTime
{
    CDEpisode* currentEpisode = [AudioSession sharedAudioSession].episode;

    if (currentEpisode == episode) {
        PlaybackManager* pman = [PlaybackManager playbackManager];
        if (pman.isPaused) {
            [pman play];
        }
        [self carPlayUpdateNowPlayingTemplateConfiguration];
        [self carPlayShowNowPlayingTemplate];
        return;
    }

    [[AudioSession sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:MAX(0, startTime) autostart:YES];
    [self carPlayUpdateNowPlayingTemplateConfiguration];
    [self carPlayShowNowPlayingTemplate];
}

- (void)carPlayShowNowPlayingTemplate
{
    if (@available(iOS 14.0, *)) {
        [self carPlayUpdateNowPlayingTemplateConfiguration];
        CPNowPlayingTemplate* nowPlayingTemplate = [CPNowPlayingTemplate sharedTemplate];
        if (self.interfaceController.topTemplate == nowPlayingTemplate) {
            return;
        }
        [self carPlayPushTemplate:nowPlayingTemplate animated:YES];
    }
}

- (void)carPlayPresentiPhonePlayer
{
    InstacastAppDelegate* appDelegate = (InstacastAppDelegate*)[UIApplication sharedApplication].delegate;
    MainViewController_4* mainViewController = appDelegate.mainViewController;
    if (!mainViewController) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* parentController = mainViewController.presentedViewController ?: mainViewController;
        if ([parentController isKindOfClass:[PlaybackViewController class]]) {
            return;
        }

        PlaybackViewController* playbackController = [PlaybackViewController playbackViewController];
        [playbackController presentFromParentViewController:parentController autostart:YES completion:nil];
    });
}

- (void)carPlayUpdateNowPlayingTemplateConfiguration
{
    if (@available(iOS 14.0, *)) {
        PlaybackManager* playbackManager = [PlaybackManager playbackManager];
        CDEpisode* currentEpisode = [AudioSession sharedAudioSession].episode ?: playbackManager.playingEpisode;
        NSArray* storedChapters = (currentEpisode != nil) ? [currentEpisode sortedChapters] : @[];
        BOOL hasRuntimeChapters = (playbackManager.chapters.count > 0);
        BOOL hasStoredChapters = (!hasRuntimeChapters && storedChapters.count > 0);

        CPNowPlayingTemplate* nowPlayingTemplate = [CPNowPlayingTemplate sharedTemplate];
        NSString* chaptersTitle = @"Chapters".ls;
        BOOL upNextEnabled = (hasRuntimeChapters || hasStoredChapters);
        if (![(nowPlayingTemplate.upNextTitle ?: @"") isEqualToString:(chaptersTitle ?: @"")]) {
            nowPlayingTemplate.upNextTitle = chaptersTitle;
        }
        if (nowPlayingTemplate.isUpNextButtonEnabled != upNextEnabled) {
            nowPlayingTemplate.upNextButtonEnabled = upNextEnabled;
        }
        if (nowPlayingTemplate.isAlbumArtistButtonEnabled) {
            nowPlayingTemplate.albumArtistButtonEnabled = NO;
        }
    }
}

- (void)nowPlayingTemplateUpNextButtonTapped:(CPNowPlayingTemplate *)nowPlayingTemplate API_AVAILABLE(ios(14.0))
{
    [self carPlayShowChapterList];
}

- (void)nowPlayingTemplateAlbumArtistButtonTapped:(CPNowPlayingTemplate *)nowPlayingTemplate API_AVAILABLE(ios(14.0))
{
    CDEpisode* currentEpisode = [AudioSession sharedAudioSession].episode ?: [PlaybackManager playbackManager].playingEpisode;
    CDFeed* feed = currentEpisode.feed;
    if (!feed) {
        return;
    }
    [self carPlayShowEpisodesForFeed:feed];
}

- (void)carPlayShowChapterList
{
    [self carPlayPreloadChapterArtworkData];
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Chapters".ls sections:[self carPlayChapterSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindChapters source:nil];
    [self carPlayConfigureLegacySelectionDelegateIfNeededForTemplate:template];
    [self carPlayPushTemplate:template animated:YES];
}

- (ICMetadataImage*)carPlayArtworkForChapterAtIndex:(NSInteger)index
                                            chapters:(NSArray*)chapters
                                            artworks:(NSArray*)artworks
{
    if (index < 0 || index >= (NSInteger)chapters.count || artworks.count == 0) {
        return nil;
    }

    ICMetadataChapter* chapter = chapters[index];
    NSTimeInterval chapterStart = CMTimeGetSeconds(chapter.start);
    NSTimeInterval nextChapterStart = CGFLOAT_MAX;
    if (index + 1 < (NSInteger)chapters.count) {
        ICMetadataChapter* nextChapter = chapters[index + 1];
        nextChapterStart = CMTimeGetSeconds(nextChapter.start);
    }

    ICMetadataImage* latestBeforeChapter = nil;
    for (ICMetadataImage* artwork in artworks) {
        NSTimeInterval artworkStart = CMTimeGetSeconds(artwork.start);
        if (artworkStart >= chapterStart && artworkStart < nextChapterStart) {
            return artwork;
        }
        if (artworkStart <= chapterStart) {
            latestBeforeChapter = artwork;
        }
    }

    return latestBeforeChapter;
}

- (NSArray<CPListSection*>*)carPlayChapterSections
{
    PlaybackManager* playbackManager = [PlaybackManager playbackManager];
    CDEpisode* currentEpisode = [AudioSession sharedAudioSession].episode ?: playbackManager.playingEpisode;
    NSArray* runtimeChapters = playbackManager.chapters ?: @[];
    NSArray* storedChapters = (currentEpisode != nil) ? [currentEpisode sortedChapters] : @[];
    BOOL usingRuntimeChapters = (runtimeChapters.count > 0);
    NSArray* chapters = usingRuntimeChapters ? runtimeChapters : storedChapters;
    NSMutableArray* items = [NSMutableArray arrayWithCapacity:chapters.count];

    NSURL* fallbackArtworkURL = currentEpisode.imageURL ?: currentEpisode.feed.imageURL;
    UIImage* fallbackArtwork = nil;
    if (fallbackArtworkURL) {
        fallbackArtwork = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:fallbackArtworkURL size:80 grayscale:NO];
    }

    NSTimeInterval playerTime = [playbackManager time];
    NSInteger currentChapterIndex = NSNotFound;

    for (NSInteger index = 0; index < (NSInteger)chapters.count; index++) {
        NSString* title = nil;
        double startTime = 0.0;

        if (usingRuntimeChapters) {
            ICMetadataChapter* chapter = chapters[index];
            title = chapter.title;
            startTime = CMTimeGetSeconds(chapter.start);
        } else {
            CDChapter* chapter = chapters[index];
            title = chapter.title;
            startTime = chapter.timecode;
        }

        if (title.length == 0) {
            title = [NSString stringWithFormat:@"#%ld", (long)index+1];
        }

        NSInteger startSeconds = (startTime >= 0) ? (NSInteger)startTime : 0;
        NSString* detail = [self carPlayFormattedTimecode:startSeconds];

        double endTime = -1.0;
        if (index + 1 < (NSInteger)chapters.count) {
            if (usingRuntimeChapters) {
                ICMetadataChapter* nextChapter = chapters[index + 1];
                endTime = CMTimeGetSeconds(nextChapter.start);
            } else {
                CDChapter* nextChapter = chapters[index + 1];
                endTime = nextChapter.timecode;
            }
        } else if (playbackManager.duration > 0.0) {
            endTime = playbackManager.duration;
        } else if (currentEpisode.duration > 0) {
            endTime = currentEpisode.duration;
        }

        if (endTime > startTime && endTime >= 0) {
            NSInteger endSeconds = (NSInteger)endTime;
            detail = [NSString stringWithFormat:@"%@ - %@",
                      [self carPlayFormattedTimecode:startSeconds],
                      [self carPlayFormattedTimecode:endSeconds]];
        }
        CPListItem* item = [self carPlayListItemWithText:title detailText:detail image:fallbackArtwork];
        item.userInfo = @(index);

        if (@available(iOS 14.0, *)) {
            BOOL isCurrentChapter = NO;
            if (usingRuntimeChapters) {
                isCurrentChapter = (index == playbackManager.currentChapter);
            } else {
                isCurrentChapter = (playerTime >= startTime && (endTime < 0.0 || playerTime < endTime));
            }
            item.playing = isCurrentChapter;
            item.playingIndicatorLocation = CPListItemPlayingIndicatorLocationTrailing;
            if (isCurrentChapter) {
                currentChapterIndex = index;
            }
        }

        if (usingRuntimeChapters) {
            ICMetadataChapter* chapter = chapters[index];
            [self carPlayAssignSelectionHandlerForItem:item handler:^{
                PlaybackManager* playbackManager = [PlaybackManager playbackManager];
                CDEpisode* episodeToPlay = [AudioSession sharedAudioSession].episode ?: playbackManager.playingEpisode;
                NSString* loadedEpisodeHash = playbackManager.playingEpisode.objectHash;
                NSString* targetEpisodeHash = episodeToPlay.objectHash;
                BOOL sameEpisodeLoaded = (loadedEpisodeHash.length > 0 && targetEpisodeHash.length > 0 && [loadedEpisodeHash isEqualToString:targetEpisodeHash]);

                if (sameEpisodeLoaded) {
                    [playbackManager seekToChapter:chapter];
                    [playbackManager play];
                } else if (episodeToPlay) {
                    NSTimeInterval chapterTime = CMTimeGetSeconds(chapter.start);
                    [[AudioSession sharedAudioSession] playEpisode:episodeToPlay queueUpCurrent:NO at:MAX(0.0, chapterTime) autostart:YES];
                }
                [self carPlayPopTemplateAnimated:YES];
            }];

            ICMetadataImage* chapterArtwork = [self carPlayArtworkForChapterAtIndex:index chapters:chapters artworks:playbackManager.artworks];
            UIImage* chapterImage = [self carPlayImageIfAlreadyAvailableForMetadataArtwork:chapterArtwork];
            if (chapterImage) {
                [self carPlaySetImage:chapterImage forListItem:item];
            }
        } else {
            CDChapter* chapter = chapters[index];
            [self carPlayAssignSelectionHandlerForItem:item handler:^{
                PlaybackManager* playbackManager = [PlaybackManager playbackManager];
                CDEpisode* episodeToPlay = [AudioSession sharedAudioSession].episode ?: playbackManager.playingEpisode;
                NSString* loadedEpisodeHash = playbackManager.playingEpisode.objectHash;
                NSString* targetEpisodeHash = episodeToPlay.objectHash;
                BOOL sameEpisodeLoaded = (loadedEpisodeHash.length > 0 && targetEpisodeHash.length > 0 && [loadedEpisodeHash isEqualToString:targetEpisodeHash]);
                NSTimeInterval chapterTime = MAX(0.0, chapter.timecode);

                if (sameEpisodeLoaded) {
                    [playbackManager seekToTime:chapterTime tolerance:NO];
                    [playbackManager play];
                } else if (episodeToPlay) {
                    [[AudioSession sharedAudioSession] playEpisode:episodeToPlay queueUpCurrent:NO at:chapterTime autostart:YES];
                }
                [self carPlayPopTemplateAnimated:YES];
            }];
        }

        [items addObject:item];
    }

    return @[[[CPListSection alloc] initWithItems:items]];
}

- (NSString*)carPlayFormattedDuration:(int32_t)seconds
{
    int hours = seconds / 3600;
    int minutes = (seconds % 3600) / 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%dh %02dm", hours, minutes];
    }
    return [NSString stringWithFormat:@"%dm", minutes];
}

- (NSString*)carPlayFormattedTimecode:(NSInteger)seconds
{
    NSInteger total = MAX(0, seconds);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
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

- (NSString*)formattedPriceForProduct:(SKProduct*)product {
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterCurrencyStyle;
    formatter.locale = product.priceLocale;
    return [formatter stringFromNumber:product.price];
}

- (void)showPopup {
    UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
    UIViewController *rootVC = keyWindow.rootViewController;

    SKProduct *p1 = validProducts[@"product_first"];
    SKProduct *p2 = validProducts[@"product_second"];
    SKProduct *p3 = validProducts[@"product_third"];
    SKProduct *p4 = validProducts[@"product_fourth"];
    NSString *title1 = p1 ? [self formattedPriceForProduct:p1] : @"$1";
    NSString *title2 = p2 ? [self formattedPriceForProduct:p2] : @"$5";
    NSString *title3 = p3 ? [self formattedPriceForProduct:p3] : @"$15";
    NSString *title4 = p4 ? [self formattedPriceForProduct:p4] : @"$20";

    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Donate for further development".ls message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    UIAlertAction* firstAction = [UIAlertAction actionWithTitle:title1 style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        InstacastSceneDelegate* strongSelf = self;
        NSDictionary* products = strongSelf->validProducts;
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [strongSelf perform:^(id sender) {
            if([products valueForKey:@"product_first"] != nil)
            {
                [strongSelf purchaseMyProduct:[products valueForKey:@"product_first"]];
            }
        } afterDelay:0.01];
    }];
    [alert addAction:firstAction];

    UIAlertAction* secondAction = [UIAlertAction actionWithTitle:title2 style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        InstacastSceneDelegate* strongSelf = self;
        NSDictionary* products = strongSelf->validProducts;
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [strongSelf perform:^(id sender) {
            if([products valueForKey:@"product_second"] != nil)
            {
                [strongSelf purchaseMyProduct:[products valueForKey:@"product_second"]];
            }
        } afterDelay:0.01];
    }];
    [alert addAction:secondAction];

    UIAlertAction* thirdAction = [UIAlertAction actionWithTitle:title3 style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        InstacastSceneDelegate* strongSelf = self;
        NSDictionary* products = strongSelf->validProducts;
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [strongSelf perform:^(id sender) {
            if([products valueForKey:@"product_third"] != nil)
            {
                [strongSelf purchaseMyProduct:[products valueForKey:@"product_third"]];
            }
        } afterDelay:0.01];
    }];
    [alert addAction:thirdAction];

    UIAlertAction* fourthAction = [UIAlertAction actionWithTitle:title4 style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        InstacastSceneDelegate* strongSelf = self;
        NSDictionary* products = strongSelf->validProducts;
        // Mark popup as shown
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hasShownDonatePopup"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        [strongSelf perform:^(id sender) {
            if([products valueForKey:@"product_fourth"] != nil)
            {
                [strongSelf purchaseMyProduct:[products valueForKey:@"product_fourth"]];
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
                break;
            case SKPaymentTransactionStatePurchased:
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
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStateFailed:
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

#pragma mark - Widget Deep Link Handling

- (void)_handleWidgetDeepLink:(NSURL *)url {
    DebugLog(@"Widget deep link: %@", url);

    if (!self.mainViewController || !self.mainViewController.contentViewController) {
        DebugLog(@"Widget deep link ignored: mainViewController or contentViewController is nil");
        return;
    }

    NSString *host = [url host];
    NSString *path = [url path];
    NSDictionary *params = [self _queryParametersFromURL:url];
    NSString *action = params[@"action"];

    DebugLog(@"Widget deep link: host=%@, path=%@, action=%@", host, path, action);

    if ([host isEqualToString:@"player"]) {
        // Player actions
        BOOL handledPlayerAction = NO;
        if ([action isEqualToString:@"playpause"]) {
            PlaybackManager *pm = [PlaybackManager playbackManager];
            if (pm.playingEpisode) {
                [pm playPause];
            } else {
                // No episode loaded — resume last played from widget cache
                NSDictionary *lastPlayed = [WidgetDataExporter sharedExporter].lastPlayedEpisodeDict;
                NSString *episodeHash = lastPlayed[@"id"];
                if (episodeHash) {
                    CDEpisode *episode = [DMANAGER episodeWithObjectHash:episodeHash];
                    if (episode) {
                        [[AudioSession sharedAudioSession] playEpisode:episode];
                    }
                }
            }
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"skipforward"]) {
            [[PlaybackManager playbackManager] seekForward];
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"skipbackward"]) {
            [[PlaybackManager playbackManager] seekBackward];
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"nextchapter"]) {
            [[PlaybackManager playbackManager] nextChapter];
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"prevchapter"]) {
            [[PlaybackManager playbackManager] previousChapter];
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"nextepisode"]) {
            AudioSession *audioSession = [AudioSession sharedAudioSession];
            CDEpisode *nextEpisode = [audioSession nextPlayableEpisode];
            if (nextEpisode) {
                [audioSession playEpisode:nextEpisode];
            }
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"previousepisode"]) {
            AudioSession *audioSession = [AudioSession sharedAudioSession];
            NSArray *playlist = audioSession.playlist;
            CDEpisode *currentEpisode = [PlaybackManager playbackManager].playingEpisode;
            NSUInteger index = [playlist indexOfObject:currentEpisode];
            if (index != NSNotFound && index > 0 && index < playlist.count) {
                [audioSession playEpisode:playlist[index - 1]];
            }
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"cyclespeed"]) {
            PlaybackManager *pm = [PlaybackManager playbackManager];
            PlaybackSpeedControl next = [PlayerSpeedButton nextEnabledSpeedAfter:pm.speedControl];
            pm.speedControl = next;
            handledPlayerAction = YES;
        } else if ([action isEqualToString:@"togglesleeptimer"]) {
            AudioSession *audioSession = [AudioSession sharedAudioSession];
            if (audioSession.timerRemainingTime > 0) {
                audioSession.timerValue = PlaybackStopTimeNoValue;
            } else {
                PlaybackStopTimeValue lastTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                if (lastTimer <= 0) lastTimer = PlaybackStopTime15min;
                audioSession.timerValue = lastTimer;
            }
            handledPlayerAction = YES;
        }

        if (handledPlayerAction) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[WidgetDataExporter sharedExporter] exportNowPlayingSnapshot];
                [WidgetKitHelper reloadAllTimelines];
            });
        }

        // Present player ONLY when no action specified (= user tapped widget area, not a control button)
        if (!action && [PlaybackManager playbackManager].playingEpisode) {
            PlaybackViewController *pvc = [PlaybackViewController playbackViewController];
            [pvc presentFromParentViewController:self.mainViewController];
        }
    }
    else if ([host isEqualToString:@"episode"]) {
        NSString *objectHash = (path.length > 1) ? [path substringFromIndex:1] : nil;
        DebugLog(@"Widget episode link: objectHash=%@", objectHash);
        BOOL handledEpisodeAction = NO;
        if (objectHash) {
            CDEpisode *episode = [DMANAGER episodeWithObjectHash:objectHash];
            DebugLog(@"Widget episode link: found episode=%@", episode.title);
            if (episode) {
                if ([action isEqualToString:@"play"]) {
                    // Play in background without presenting the player UI.
                    [[AudioSession sharedAudioSession] playEpisode:episode];
                    handledEpisodeAction = YES;
                } else if ([action isEqualToString:@"openplay"] || [action isEqualToString:@"show"]) {
                    // Open player and autostart playback.
                    [[AudioSession sharedAudioSession] playEpisode:episode];
                    PlaybackViewController *pvc = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:YES];
                    [pvc presentFromParentViewController:self.mainViewController autostart:YES completion:NULL];
                    handledEpisodeAction = YES;
                } else {
                    // Show episode detail / show notes
                    [self.mainViewController showShowNotesOfEpisode:episode animated:YES];
                }
            }
        }

        if (handledEpisodeAction) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[WidgetDataExporter sharedExporter] exportNowPlayingSnapshot];
                [WidgetKitHelper reloadAllTimelines];
            });
        }
    }
    else if ([host isEqualToString:@"feed"]) {
        NSString *feedUID = (path.length > 1) ? [path substringFromIndex:1] : nil;
        if (feedUID) {
            // Find feed by UID
            for (CDFeed *feed in DMANAGER.feeds) {
                if ([feed.uid isEqualToString:feedUID]) {
                    FeedEpisodesTableViewController *vc = [FeedEpisodesTableViewController episodesControllerWithFeed:feed];
                    // contentViewController is a StatusBarFixingViewController wrapping the navController
                    UINavigationController *nav = [self.mainViewController.contentViewController.childViewControllers firstObject];
                    if ([nav isKindOfClass:[UINavigationController class]]) {
                        [nav pushViewController:vc animated:YES];
                    }
                    break;
                }
            }
        }
    }
    else if ([host isEqualToString:@"list"]) {
        NSString *listUID = (path.length > 1) ? [path substringFromIndex:1] : nil;
        if (listUID) {
            for (CDList *list in DMANAGER.lists) {
                if ([list.uid isEqualToString:listUID]) {
                    ListEpisodesTableViewController *vc = [ListEpisodesTableViewController viewControllerWithList:list];
                    UINavigationController *nav = [self.mainViewController.contentViewController.childViewControllers firstObject];
                    if ([nav isKindOfClass:[UINavigationController class]]) {
                        [nav pushViewController:vc animated:YES];
                    }
                    break;
                }
            }
        }
    }
    else if ([host isEqualToString:@"queue"]) {
        UpNextTableViewController *vc = [UpNextTableViewController viewController];
        UINavigationController *nav = [self.mainViewController.contentViewController.childViewControllers firstObject];
        if ([nav isKindOfClass:[UINavigationController class]]) {
            [nav pushViewController:vc animated:YES];
        }
    }
}

- (NSDictionary *)_queryParametersFromURL:(NSURL *)url {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if (item.name && item.value) {
            params[item.name] = item.value;
        }
    }
    return params;
}

@end
