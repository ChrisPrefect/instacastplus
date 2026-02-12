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
#import "PlaybackManager.h"
#import "ImageCacheManager.h"
#import "AudioSession+UpNextPlaylist.h"

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

@end

@implementation InstacastSceneDelegate{
    struct {
        unsigned int apnRegisterSuccess:1;
    } _flags;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {

    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        self.window.backgroundColor = ICBackgroundColor;

#if TARGET_OS_MACCATALYST
        CGSize minSize = CGSizeMake(402, 874); // iPhone 16/17 Pro dimensions
        windowScene.sizeRestrictions.minimumSize = minSize;
        // maximumSize nicht setzen → frei vergrösserbar
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
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
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
    [self showDonatePopupAfterDelay:300];
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    if ([ICAppearanceManager sharedManager].appearanceMode == ICAppearanceModeAutomatic) {
        [[ICAppearanceManager sharedManager] updateAppearance];
    }
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
    self.carPlayRootTemplate = [self carPlayMainMenuTemplate];
    [interfaceController setRootTemplate:self.carPlayRootTemplate animated:YES completion:nil];

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(carPlayFeedsDidUpdate:) name:DatabaseManagerDidUpdateObservedFeedNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayDataDidUpdate:) name:DatabaseManagerDidAddBookmarkNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayDataDidUpdate:) name:MainMenuListUIDsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayDataDidUpdate:) name:CDPlaylistDidChangeEpisodesNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayContextObjectsDidChange:) name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];

    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidStartNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidChangeEpisodeNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidUpdateNotification object:nil];
    [nc addObserver:self selector:@selector(carPlayPlaybackDidUpdate:) name:PlaybackManagerDidEndNotification object:nil];

    if (@available(iOS 14.0, *)) {
        [[CPNowPlayingTemplate sharedTemplate] addObserver:self];
    }

    [self carPlayUpdateNowPlayingTemplateConfiguration];
    [self carPlayApplySleepTimerPolicy];
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene didDisconnectInterfaceController:(CPInterfaceController *)interfaceController {
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:DatabaseManagerDidUpdateObservedFeedNotification object:nil];
    [nc removeObserver:self name:DatabaseManagerDidAddBookmarkNotification object:nil];
    [nc removeObserver:self name:MainMenuListUIDsDidChangeNotification object:nil];
    [nc removeObserver:self name:CDPlaylistDidChangeEpisodesNotification object:nil];
    [nc removeObserver:self name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];
    [nc removeObserver:self name:PlaybackManagerDidStartNotification object:nil];
    [nc removeObserver:self name:PlaybackManagerDidChangeEpisodeNotification object:nil];
    [nc removeObserver:self name:PlaybackManagerDidUpdateNotification object:nil];
    [nc removeObserver:self name:PlaybackManagerDidEndNotification object:nil];

    if (@available(iOS 14.0, *)) {
        [[CPNowPlayingTemplate sharedTemplate] removeObserver:self];
    }

    [self carPlayRestoreSleepTimerAfterDisconnectIfNeeded];
    self.carPlayRootTemplate = nil;
    self.interfaceController = nil;
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
    if (!self.interfaceController) {
        return;
    }

    [self carPlayRefreshRootTemplate];
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

    for (NSString* key in changeKeys) {
        NSSet* objects = userInfo[key];
        for (NSManagedObject* object in objects) {
            if ([object isKindOfClass:[CDBookmark class]]) {
                containsBookmarkChange = YES;
                break;
            }
        }
        if (containsBookmarkChange) {
            break;
        }
    }

    if (containsBookmarkChange) {
        [self carPlayDataDidUpdate:notification];
    }
}

- (void)carPlayPlaybackDidUpdate:(NSNotification*)notification
{
    if (!self.interfaceController) {
        return;
    }

    [self carPlayUpdateNowPlayingTemplateConfiguration];

    if ([notification.name isEqualToString:PlaybackManagerDidUpdateNotification]) {
        [self carPlayUpdateVisiblePlaybackStateIfNeeded];
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
    BOOL isPaused = [PlaybackManager playbackManager].paused;

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
            BOOL shouldShowPlaying = (isCurrent && !isPaused);

            if (isCurrent) {
                NSString* detailText = [self carPlayEpisodeDetailText:episode];
                if (![(item.detailText ?: @"") isEqualToString:(detailText ?: @"")]) {
                    [item setDetailText:detailText];
                }
            }

            if (@available(iOS 14.0, *)) {
                if (isCurrent) {
                    item.playbackProgress = [self carPlayPlaybackProgressForEpisode:episode];
                }
                if (item.playing != shouldShowPlaying) {
                    item.playing = shouldShowPlaying;
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
            NSInteger index = 0;
            for (id<CPListTemplateItem> listItem in section.items) {
                if (![listItem isKindOfClass:[CPListItem class]]) {
                    index++;
                    continue;
                }
                CPListItem* item = (CPListItem*)listItem;
                BOOL isPlayingChapter = (index == currentChapter);
                if (item.playing != isPlayingChapter) {
                    item.playing = isPlayingChapter;
                }
                index++;
            }
        }
    }
}

- (CPListTemplate*)carPlayMainMenuTemplate
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Instacast" sections:[self carPlayMainMenuSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindRoot source:nil];
    return template;
}

- (NSArray<CPListSection*>*)carPlayMainMenuSections
{
    NSMutableArray* items = [NSMutableArray array];

    WEAK_SELF

    CPListItem* podcastsItem = [[CPListItem alloc] initWithText:@"Podcasts".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)DMANAGER.feeds.count, @"Podcasts".ls]];
    podcastsItem.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
        STRONG_SELF
        [self carPlayShowPodcasts];
        completionHandler();
    };
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
    listsItem.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
        STRONG_SELF
        [self carPlayShowAllLists];
        completionHandler();
    };
    [items addObject:listsItem];

    CPListItem* upNextItem = [[CPListItem alloc] initWithText:@"Play Next".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)[AudioSession sharedAudioSession].playlist.count, @"Episodes".ls]];
    upNextItem.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
        STRONG_SELF
        [self carPlayShowUpNext];
        completionHandler();
    };
    [items addObject:upNextItem];

    CPListItem* bookmarksItem = [[CPListItem alloc] initWithText:@"Bookmarks".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)DMANAGER.bookmarks.count, @"Bookmarks".ls]];
    bookmarksItem.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
        STRONG_SELF
        [self carPlayShowBookmarks];
        completionHandler();
    };
    [items addObject:bookmarksItem];

    if (!downloadedInMainMenu) {
        CDEpisodeList* downloadedList = [self carPlayEpisodeListForUID:@"default.downloaded"];
        CPListItem* downloadsItem = [[CPListItem alloc] initWithText:@"Downloaded".ls detailText:[NSString stringWithFormat:@"%lu %@", (unsigned long)downloadedList.numberOfEpisodes, @"Episodes".ls]];
        downloadsItem.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
            STRONG_SELF
            if (downloadedList) {
                [self carPlayShowEpisodesForList:downloadedList];
            }
            completionHandler();
        };
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

- (CPListItem*)carPlayRootListItemForEpisodeList:(CDEpisodeList*)list
{
    NSString* detail = [NSString stringWithFormat:@"%lu %@", (unsigned long)list.numberOfEpisodes, @"Episodes".ls];
    CPListItem* item = [[CPListItem alloc] initWithText:list.name detailText:detail];

    WEAK_SELF
    item.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
        STRONG_SELF
        [self carPlayShowEpisodesForList:list];
        completionHandler();
    };

    UIImage* rawListImage = (UIImage*)list.image;
    UIImage* listImage = [rawListImage imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    if (listImage) {
        [item setImage:listImage];
    }

    return item;
}

- (void)carPlayShowPodcasts
{
    CPListTemplate* template = [self carPlayPodcastListTemplate];
    [self.interfaceController pushTemplate:template animated:YES completion:nil];
}

- (CPListTemplate*)carPlayPodcastListTemplate
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Podcasts".ls sections:[self carPlayPodcastSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindPodcasts source:nil];
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
    CPListItem* item = [[CPListItem alloc] initWithText:feed.title detailText:detail];
    item.userInfo = feed;

    WEAK_SELF
    item.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
        STRONG_SELF
        CDFeed* selectedFeed = ((CPListItem*)listItem).userInfo;
        [self carPlayShowEpisodesForFeed:selectedFeed];
        completionHandler();
    };

    if (feed.imageURL) {
        [ImageCacheManager loadImageForURL:feed.imageURL size:80 grayscale:NO completion:^(UIImage *image, NSError *error) {
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [item setImage:image];
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
    [self.interfaceController pushTemplate:template animated:YES completion:nil];
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
    [self.interfaceController pushTemplate:template animated:YES completion:nil];
}

- (void)carPlayShowBookmarks
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Bookmarks".ls sections:[self carPlayBookmarksSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindBookmarks source:nil];
    [self.interfaceController pushTemplate:template animated:YES completion:nil];
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
        item.userInfo = bookmark;

        WEAK_SELF
        item.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
            STRONG_SELF
            CDBookmark* selectedBookmark = ((CPListItem*)listItem).userInfo;
            CDEpisode* selectedEpisode = [DMANAGER episodeWithObjectHash:selectedBookmark.episodeHash];
            if (selectedEpisode) {
                [self carPlayPlayEpisode:selectedEpisode at:MAX(0, selectedBookmark.position)];
            }
            completionHandler();
        };

        NSURL* artURL = bookmark.imageURL ?: episode.imageURL ?: episode.feed.imageURL;
        if (artURL) {
            [ImageCacheManager loadImageForURL:artURL size:80 grayscale:NO completion:^(UIImage *image, NSError *error) {
                if (image) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [item setImage:image];
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
    [self.interfaceController pushTemplate:template animated:YES completion:nil];
}

- (void)carPlayShowEpisodesForList:(CDEpisodeList*)list
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:list.name sections:[self carPlaySectionsForEpisodes:[list sortedEpisodes]]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindListEpisodes source:list];
    [self.interfaceController pushTemplate:template animated:YES completion:nil];
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

- (NSString*)carPlayEpisodeStatusText:(CDEpisode*)episode
{
    if (episode.consumed) {
        return @"Played".ls;
    }
    double progress = [self carPlayPlaybackProgressForEpisode:episode];
    if (progress > 0.0) {
        NSInteger percent = (NSInteger)round(progress * 100.0);
        percent = MAX(0, MIN(100, percent));
        return [NSString stringWithFormat:@"%@ (%ld%%)", @"Started".ls, (long)percent];
    }
    return @"Unplayed".ls;
}

- (NSString*)carPlayEpisodeDetailText:(CDEpisode*)episode
{
    NSMutableArray* parts = [NSMutableArray array];
    [parts addObject:[self carPlayEpisodeStatusText:episode]];

    if (episode.duration > 0) {
        [parts addObject:[self carPlayFormattedDuration:episode.duration]];
    }
    if (episode.pubDate) {
        [parts addObject:[[self carPlayDateFormatter] stringFromDate:episode.pubDate]];
    }

    return [parts componentsJoinedByString:@" • "];
}

- (CPListItem*)carPlayListItemForEpisode:(CDEpisode*)episode
{
    CPListItem* item = [[CPListItem alloc] initWithText:episode.title detailText:[self carPlayEpisodeDetailText:episode]];
    item.userInfo = episode;

    if (@available(iOS 14.0, *)) {
        item.playbackProgress = [self carPlayPlaybackProgressForEpisode:episode];
        item.playing = ([self carPlayEpisodeIsCurrent:episode] && ![PlaybackManager playbackManager].paused);
        item.playingIndicatorLocation = CPListItemPlayingIndicatorLocationTrailing;
    }

    WEAK_SELF
    item.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
        STRONG_SELF
        CDEpisode* selectedEpisode = ((CPListItem*)listItem).userInfo;
        [self carPlayPlayEpisode:selectedEpisode at:MAX(0, selectedEpisode.position)];
        completionHandler();
    };

    NSURL* artURL = episode.imageURL ?: episode.feed.imageURL;
    if (artURL) {
        [ImageCacheManager loadImageForURL:artURL size:80 grayscale:NO completion:^(UIImage *image, NSError *error) {
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [item setImage:image];
                });
            }
        }];
    }

    return item;
}

- (void)carPlayPlayEpisode:(CDEpisode*)episode at:(NSTimeInterval)startTime
{
    [[AudioSession sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:MAX(0, startTime) autostart:YES];
    [self carPlayUpdateNowPlayingTemplateConfiguration];
    [self carPlayShowNowPlayingTemplate];
    [self carPlayPresentiPhonePlayer];
}

- (void)carPlayShowNowPlayingTemplate
{
    if (@available(iOS 14.0, *)) {
        CPNowPlayingTemplate* nowPlayingTemplate = [CPNowPlayingTemplate sharedTemplate];
        if (self.interfaceController.topTemplate == nowPlayingTemplate) {
            return;
        }
        [self.interfaceController pushTemplate:nowPlayingTemplate animated:YES completion:nil];
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
        [playbackController presentFromParentViewController:parentController autostart:NO completion:nil];
    });
}

- (void)carPlayUpdateNowPlayingTemplateConfiguration
{
    if (@available(iOS 14.0, *)) {
        CPNowPlayingTemplate* nowPlayingTemplate = [CPNowPlayingTemplate sharedTemplate];
        nowPlayingTemplate.upNextTitle = @"Chapters".ls;
        nowPlayingTemplate.upNextButtonEnabled = ([PlaybackManager playbackManager].chapters.count > 0);
    }
}

- (void)nowPlayingTemplateUpNextButtonTapped:(CPNowPlayingTemplate *)nowPlayingTemplate
{
    [self carPlayShowChapterList];
}

- (void)carPlayShowChapterList
{
    CPListTemplate* template = [[CPListTemplate alloc] initWithTitle:@"Chapters".ls sections:[self carPlayChapterSections]];
    template.userInfo = [self carPlayTemplateInfoWithKind:kCarPlayTemplateKindChapters source:nil];
    [self.interfaceController pushTemplate:template animated:YES completion:nil];
}

- (NSArray<CPListSection*>*)carPlayChapterSections
{
    PlaybackManager* playbackManager = [PlaybackManager playbackManager];
    NSArray* chapters = playbackManager.chapters;
    NSMutableArray* items = [NSMutableArray arrayWithCapacity:chapters.count];

    for (NSInteger index = 0; index < (NSInteger)chapters.count; index++) {
        ICMetadataChapter* chapter = chapters[index];
        NSString* title = chapter.title.length > 0 ? chapter.title : [NSString stringWithFormat:@"#%ld", (long)index+1];
        NSString* detail = [self carPlayFormattedTimecode:(NSInteger)CMTimeGetSeconds(chapter.start)];
        CPListItem* item = [[CPListItem alloc] initWithText:title detailText:detail];

        if (@available(iOS 14.0, *)) {
            item.playing = (index == playbackManager.currentChapter);
            item.playingIndicatorLocation = CPListItemPlayingIndicatorLocationTrailing;
        }

        item.userInfo = chapter;
        WEAK_SELF
        item.handler = ^(id<CPSelectableListItem> _Nonnull listItem, dispatch_block_t _Nonnull completionHandler) {
            STRONG_SELF
            ICMetadataChapter* selectedChapter = ((CPListItem*)listItem).userInfo;
            [[PlaybackManager playbackManager] seekToChapter:selectedChapter];
            [self.interfaceController popTemplateAnimated:YES completion:nil];
            completionHandler();
        };
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

    UIAlertAction* secondAction = [UIAlertAction actionWithTitle:title2 style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
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

    UIAlertAction* thirdAction = [UIAlertAction actionWithTitle:title3 style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
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

    UIAlertAction* fourthAction = [UIAlertAction actionWithTitle:title4 style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
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
