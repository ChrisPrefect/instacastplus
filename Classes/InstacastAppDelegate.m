//
//  InstacastAppDelegate.m
//  Instacast
//
//  Created by Martin Hering on 22.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//


#import <UserNotifications/UserNotifications.h>
#import <CarPlay/CarPlay.h>
#import <BackgroundTasks/BackgroundTasks.h>

#import "InstacastAppDelegate.h"
#import "UIManager.h"
#import "CDEpisode+ShowNotes.h"

#import "DirectoryFeedViewController.h"

#import "VDModalInfo.h"
#import "ICFeedParser.h"
#import "SubscriptionManager.h"
#import "UtilityFunctions.h"
#import "FeedEpisodeExtraction.h"
#import "XPFF.h"
#import "BookmarksTableViewController.h"
#import "CDModel.h"
#import "EpisodeLoadingManager.h"
#import "WidgetDataExporter.h"
#import "InstacastPlus-Swift.h"
#import "AppleWatchSyncManager.h"
#import "ViewFunctions.h"

#import "MainViewController_4.h"
#import "SubscriptionsTableViewController.h"
#import "PlaybackViewController.h"
#import "PlayerController.h"
#import "PortraitNavigationController.h"
#import "ICDurationValueTransformer.h"
#import "ICPubdateValueTransformer.h"
#import "Application.h"
#import "InstacastSceneDelegate.h"
#import "InstacastBackupParser.h"
#import "InstacastBackupImporter.h"
#import <MediaPlayer/MPVolumeView.h>
#import <AVFoundation/AVFoundation.h>

static NSString* const ICTranscriptionProcessingTaskIdentifier = @"com.iteconomy.instacastplus.transcription.processing";
static NSString* const ICTranscriptionContinuedTaskIdentifier = @"com.iteconomy.instacastplus.transcription.continued";
static NSString* const ICTranscriptionContinuedGPUPath = @"continued-gpu";
static NSString* const ICTranscriptionLegacyProcessingPath = @"legacy-processing";
static NSString* const InstacastMainViewControllerDidBecomeReadyNotification = @"InstacastMainViewControllerDidBecomeReadyNotification";

@interface InstacastAppDelegate () <UNUserNotificationCenterDelegate>
@property BOOL resettingContext;
@property (strong) VDModalInfo* mInfo;
@property (strong) VDModalInfo* loadingInfo;
@property (nonatomic, strong) DirectoryFeedViewController* feedView;
@property (nonatomic, strong) NSURL* pendingBackupFileURL;

@end


@implementation InstacastAppDelegate {
    struct {
        unsigned int apnRegisterSuccess:1;
    } _flags;
}
@synthesize window = _window;

+ (void) initialize
{
    NSString* defaultsPlist = [[NSBundle mainBundle] pathForResource:@"Defaults" ofType:@"plist"];
    NSMutableDictionary* defaults = [[NSDictionary dictionaryWithContentsOfFile:defaultsPlist] mutableCopy];

    NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
    defaults[WidgetThemeDefaultActive] = @YES;
    defaults[EpisodeSwipeLeftAction] = @(ICEpisodeSwipeActionAddToPlayNext);
    [defs registerDefaults:defaults];
    if (@available(iOS 17.0, *)) {
        [ICiCloudSyncManager purgeLegacyDefaultsBackedSyncMetadata];
    }

    if (![defs objectForKey:FirstLaunchDate]) {
        [defs setObject:[NSDate date] forKey:FirstLaunchDate];
        [USER_DEFAULTS setDouble:[[NSDate date] timeIntervalSince1970] forKey:LastRefreshSubscriptionDate];
    }

    ICAppearanceManager* aman = [ICAppearanceManager sharedManager];
    [aman updateAppearance];

    [NSValueTransformer setValueTransformer:[[ICDurationValueTransformer alloc] init] forName:kICDurationValueTransformer];
    [NSValueTransformer setValueTransformer:[[ICPubdateValueTransformer alloc] init] forName:kICPubdateValueTransformer];
}

#pragma mark -
#pragma mark Memory management

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application
{
    /*
     Free up as much memory as possible by purging cached data objects that can be recreated (or reloaded from disk) later.
     */
    [[ICDiagnosticLogger shared] logEvent:@"lifecycle" message:@"applicationDidReceiveMemoryWarning" metadata:nil];
}

- (void)_registerTranscriptionBackgroundTasks {
    [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:ICTranscriptionProcessingTaskIdentifier
                                                         usingQueue:nil
                                                      launchHandler:^(BGTask * _Nonnull task) {
        [self _handleTranscriptionProcessingTask:(BGProcessingTask*)task];
    }];

    if (@available(iOS 26.0, *)) {
        BOOL registered = [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:ICTranscriptionContinuedTaskIdentifier
                                                                                usingQueue:nil
                                                                             launchHandler:^(BGTask * _Nonnull task) {
            [self _handleTranscriptionContinuedProcessingTask:(BGContinuedProcessingTask*)task];
        }];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask registriert"
                                     metadata:@{
                                         @"identifier": ICTranscriptionContinuedTaskIdentifier,
                                         @"registered": @(registered),
                                         @"gpuSupported": @((BGTaskScheduler.supportedResources & BGContinuedProcessingTaskRequestResourcesGPU) != 0),
                                     }];
    }
}

- (void)_handleTranscriptionProcessingTask:(BGProcessingTask*)processingTask {
    __block id queueObserver = nil;
    __block BOOL taskCompleted = NO;
    void (^scheduleNextRequest)(void) = ^{
        BGProcessingTaskRequest* request = [[BGProcessingTaskRequest alloc] initWithIdentifier:ICTranscriptionProcessingTaskIdentifier];
        request.requiresExternalPower = NO;
        request.requiresNetworkConnectivity = NO;
        [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:nil];
    };
    void (^completeTask)(BOOL) = ^(BOOL success) {
        if (taskCompleted) return;
        taskCompleted = YES;
        if (queueObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:queueObserver];
            queueObserver = nil;
        }
        [[TranscriptionQueue shared] completeBackgroundExecutionPathWithSuccess:success reason:@"legacy-processing-completed"];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGProcessingTask abgeschlossen"
                                     metadata:@{
                                         @"path": ICTranscriptionLegacyProcessingPath,
                                         @"success": @(success),
                                     }];
        [processingTask setTaskCompletedWithSuccess:success];
        scheduleNextRequest();
    };
    processingTask.expirationHandler = ^{
        [[ICDiagnosticLogger shared] logEvent:@"background-task" message:@"BGProcessingTask abgelaufen" metadata:@{
            @"path": ICTranscriptionLegacyProcessingPath,
        }];
        completeTask(NO);
    };

    [[TranscriptionQueue shared] activateBackgroundExecutionPathWithPath:ICTranscriptionLegacyProcessingPath
                                                                  detail:@"BGProcessingTask gestartet"];
    [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                  message:@"BGProcessingTask gestartet"
                                 metadata:@{
                                     @"identifier": processingTask.identifier ?: @"",
                                     @"path": ICTranscriptionLegacyProcessingPath,
                                 }];

    queueObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"ICTranscriptionQueueDidChangeNotification"
                                                                      object:nil
                                                                       queue:[NSOperationQueue mainQueue]
                                                                  usingBlock:^(__unused NSNotification *note) {
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        if (!queue.isProcessing && queue.currentItem == nil) {
            completeTask(YES);
        }
    }];

    [[TranscriptionQueue shared] resumeIfNeeded];
    TranscriptionQueue* queue = [TranscriptionQueue shared];
    if (!queue.isProcessing && queue.currentItem == nil) {
        completeTask(YES);
    }
}

- (void)_handleTranscriptionContinuedProcessingTask:(BGContinuedProcessingTask*)continuedTask API_AVAILABLE(ios(26.0)) {
    __block id queueObserver = nil;
    __block id progressObserver = nil;
    __block BOOL taskCompleted = NO;

    continuedTask.progress.totalUnitCount = 1000;
    continuedTask.progress.completedUnitCount = 0;

    void (^completeTask)(BOOL, NSString*) = ^(BOOL success, NSString* reason) {
        if (taskCompleted) return;
        taskCompleted = YES;
        if (queueObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:queueObserver];
            queueObserver = nil;
        }
        if (progressObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:progressObserver];
            progressObserver = nil;
        }
        [[TranscriptionQueue shared] completeBackgroundExecutionPathWithSuccess:success reason:reason];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask abgeschlossen"
                                     metadata:@{
                                         @"path": ICTranscriptionContinuedGPUPath,
                                         @"reason": reason ?: @"",
                                         @"success": @(success),
                                         @"completedUnitCount": @(continuedTask.progress.completedUnitCount),
                                     }];
        [continuedTask setTaskCompletedWithSuccess:success];
    };

    continuedTask.expirationHandler = ^{
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask abgelaufen"
                                     metadata:@{
                                         @"path": ICTranscriptionContinuedGPUPath,
                                     }];
        [[TranscriptionQueue shared] expireContinuedGPUBackgroundExecutionWithReason:@"continued-gpu-expired"];
        completeTask(NO, @"continued-gpu-expired");
    };

    [[TranscriptionQueue shared] activateBackgroundExecutionPathWithPath:ICTranscriptionContinuedGPUPath
                                                                  detail:@"BGContinuedProcessingTask mit GPU gestartet"];
    [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                  message:@"BGContinuedProcessingTask gestartet"
                                 metadata:@{
                                     @"identifier": continuedTask.identifier ?: @"",
                                     @"path": ICTranscriptionContinuedGPUPath,
                                     @"gpuSupported": @((BGTaskScheduler.supportedResources & BGContinuedProcessingTaskRequestResourcesGPU) != 0),
                                 }];

    progressObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"ICTranscriptionDidProgressNotification"
                                                                         object:nil
                                                                          queue:[NSOperationQueue mainQueue]
                                                                     usingBlock:^(NSNotification *note) {
        NSNumber* progressValue = note.userInfo[@"progress"];
        double fraction = progressValue ? progressValue.doubleValue : 0.0;
        continuedTask.progress.completedUnitCount = (int64_t)llround(MAX(0.0, MIN(1.0, fraction)) * 1000.0);
        NSString* subtitle = [NSString stringWithFormat:NSLocalizedString(@"%.0f %% abgeschlossen", nil), fraction * 100.0];
        [continuedTask updateTitle:NSLocalizedString(@"Transkription läuft", nil) subtitle:subtitle];
    }];

    queueObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"ICTranscriptionQueueDidChangeNotification"
                                                                      object:nil
                                                                       queue:[NSOperationQueue mainQueue]
                                                                  usingBlock:^(__unused NSNotification *note) {
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        if (!queue.isProcessing && queue.currentItem == nil) {
            continuedTask.progress.completedUnitCount = continuedTask.progress.totalUnitCount;
            completeTask(YES, @"queue-completed");
        }
    }];

    [[TranscriptionQueue shared] resumeIfNeeded];
    TranscriptionQueue* queue = [TranscriptionQueue shared];
    if (!queue.isProcessing && queue.currentItem == nil) {
        continuedTask.progress.completedUnitCount = continuedTask.progress.totalUnitCount;
        completeTask(YES, @"queue-empty");
    }
}




#pragma mark -
#pragma mark Application lifecycle


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    if ([USER_DEFAULTS valueForKey:InterfaceThemeDefaultActive] == nil)
    {
        [USER_DEFAULTS setBool:true forKey:InterfaceThemeDefaultActive];
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [App setMinimumBackgroundFetchInterval:900];
    [App setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];
#pragma clang diagnostic pop

    self.window.backgroundColor = ICBackgroundColor;
    ICAppearanceMode mode = [USER_DEFAULTS integerForKey:kDefaultAppearanceMode];
    switch (mode) {
        case ICAppearanceModeDark:
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            break;
        case ICAppearanceModeLight:
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
            break;
        case ICAppearanceModeAutomatic:
        default:
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
            break;
    }

    [App initializeLoggers];
    [[ICDiagnosticLogger shared] start];
    if (@available(iOS 17.0, *)) {
        [ICiCloudSyncManager logSyncMetadataStorageSnapshot:@"launch"];
    }
    [[ICDiagnosticLogger shared] recordLifecycle:@"applicationDidFinishLaunching"
                                        metadata:@{
                                            @"launchOptionsCount": @(launchOptions.count),
                                        }];

    [self _registerTranscriptionBackgroundTasks];

    if ([DatabaseManager dataStoreNeedsMigration]) {
        UIViewController* migrationViewController = [[UIViewController alloc] initWithNibName:@"DataMigrationView" bundle:nil];
        ICLocalizeViewText(migrationViewController.view);
        self.window.rootViewController = migrationViewController;
        [self performSelector:@selector(_startUpApplicationWithLaunchOptions:) withObject:launchOptions afterDelay:0.1];
    }
    else {
        [self _startUpApplicationWithLaunchOptions:launchOptions];
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    // On macOS ("Designed for iPad"), requestAuthorization triggers the
    // TCC dialog "wants to access data from other apps" — skip on Mac.
    BOOL isiOSAppOnMac_notif = NO;
    isiOSAppOnMac_notif = NSProcessInfo.processInfo.isiOSAppOnMac;
    if (!isiOSAppOnMac_notif) {
        __weak typeof(self) weakSelf = self;
        [center requestAuthorizationWithOptions:(UNAuthorizationOptionBadge | UNAuthorizationOptionSound | UNAuthorizationOptionAlert)
                              completionHandler:^(BOOL granted, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:@"DidRegisterUserNotificationSettings" object:weakSelf];
            });
        }];
    }
        
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidTimeout:) name:kApplicationDidTimeoutNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_protectedDataDidBecomeAvailable:)
                                                 name:UIApplicationProtectedDataDidBecomeAvailable
                                               object:nil];
   
//    if ([USER_DEFAULTS valueForKey:ScreenTimerAlwaysActive] == nil)
//    {
//        [USER_DEFAULTS setBool:true forKey:ScreenTimerAlwaysActive];
//        NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
//        if (sleepTimer <= 0)
//        {
//            if ([USER_DEFAULTS objectForKey:LastSelectedSleepTimer] == nil)
//            {
//                [USER_DEFAULTS setInteger:PlaybackStopTime5min forKey:LastSelectedSleepTimer];
//                [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
//                [USER_DEFAULTS synchronize];
//            }
//        }
//    }

    if ([USER_DEFAULTS valueForKey:ScreenTouchIntelligentSleep] == nil)
    {
        [USER_DEFAULTS setBool:true forKey:ScreenTouchIntelligentSleep];
    }
    if ([USER_DEFAULTS valueForKey:VolumeChangeIntelligentSleep] == nil)
    {
        [USER_DEFAULTS setBool:true forKey:VolumeChangeIntelligentSleep];
    }
    if ([USER_DEFAULTS valueForKey:DeviceMovementIntelligentSleep] == nil)
    {
        [USER_DEFAULTS setBool:true forKey:DeviceMovementIntelligentSleep];
    }
    {
        double storedSensitivity = [USER_DEFAULTS doubleForKey:DeviceMovementSensitivity];
        if (storedSensitivity <= 0 || storedSensitivity >= 1.0)
        {
            [USER_DEFAULTS setDouble:0.004 forKey:DeviceMovementSensitivity];
        }
    }
    if ([USER_DEFAULTS valueForKey:PlayerColorPerPodcastActive] == nil)
    {
        [USER_DEFAULTS setBool:true forKey:PlayerColorPerPodcastActive];
    }
    if ([USER_DEFAULTS valueForKey:IntelligentSleepTimerAlwaysActive] == nil)
    {
        [USER_DEFAULTS setBool:true forKey:IntelligentSleepTimerAlwaysActive];
    }
    NSString *currentLocalization = [[[NSBundle mainBundle] preferredLocalizations] objectAtIndex:0];
    if ([currentLocalization  isEqual: @"en"])
    {
        [USER_DEFAULTS setInteger:1 forKey:SelectedAppLanguage];
    }
    else
    {
        [USER_DEFAULTS setInteger:2 forKey:SelectedAppLanguage];
    }
    [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];

    return YES;
}

-(void)applicationDidTimeout:(NSNotification *) notif
{
}

- (void)_protectedDataDidBecomeAvailable:(NSNotification *)notification
{
    if (self.mainViewController) {
        [InstacastBackupImporter resumePendingBookmarkImportIfNeeded];
        [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
    }
}

- (void) _startUpApplicationWithLaunchOptions:(NSDictionary *)launchOptions
{
    DatabaseManager* databaseManager = [DatabaseManager sharedDatabaseManager];
    if (databaseManager.initializationError) {
        [[ICDiagnosticLogger shared] logEvent:@"database"
                                      message:@"Lokale Datenbank konnte beim Start nicht geöffnet werden"
                                     metadata:@{ @"error": databaseManager.initializationError.description ?: @"" }];
        self.mainViewController = nil;
        [UIManager sharedManager].mainViewController = nil;
        self.window.rootViewController = [InstacastAppDelegate databaseUnavailableViewControllerForError:databaseManager.initializationError];
        [self.window makeKeyAndVisible];
        return;
    }

    MainViewController_4* mainViewController = [MainViewController_4 mainViewController];
    self.mainViewController = mainViewController;
    [UIManager sharedManager].mainViewController = mainViewController;

    self.window.rootViewController = self.mainViewController;

    [self.window makeKeyAndVisible];
    [[NSNotificationCenter defaultCenter] postNotificationName:InstacastMainViewControllerDidBecomeReadyNotification
                                                        object:self.mainViewController];
    [InstacastBackupImporter resumePendingBookmarkImportIfNeeded];
    [InstacastBackupImporter startDeferredRestoreRecovery];
    if (self.pendingBackupFileURL) {
        [self.mainViewController openBackupFileURL:self.pendingBackupFileURL];
        self.pendingBackupFileURL = nil;
    }

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([launchOptions objectForKey:UIApplicationLaunchOptionsLocalNotificationKey]) {
        UILocalNotification* notification = [launchOptions objectForKey:UIApplicationLaunchOptionsLocalNotificationKey];
        [self application:App didReceiveLocalNotification:notification];
    }
    #pragma clang diagnostic pop

    if ([launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey]) {
        NSDictionary* notification = [launchOptions objectForKey:UIApplicationLaunchOptionsRemoteNotificationKey];
        [self application:App didReceiveRemoteNotification:notification fetchCompletionHandler:^(UIBackgroundFetchResult result) {
        }];
    }

    [self _updateAppContentAfterBecomingActive];

    // LazyLoadConsumedFix removed — was too aggressive (reset episodes that were
    // legitimately consumed with position==0). User restored correct state from backup.

    dispatch_async(dispatch_get_main_queue(), ^{
        [[EpisodeLoadingManager sharedManager] restoreLoadingState];
    });

    if ([USER_DEFAULTS boolForKey:SmarthomeMQTTEnabled]) {
        [[SmarthomeManager sharedManager] start];
    }

    // Start widget data exporter — must be in AppDelegate (not SceneDelegate)
    // so it also receives notifications during background fetch.
    // On macOS ("Designed for iPad"), sharedExporter returns nil (no-op)
    // and WidgetKitHelper skips internally — iOS widgets don't work there.
    [[WidgetDataExporter sharedExporter] startObserving];
    [WidgetKitHelper startListeningForWidgetActions];

    [[AppleWatchSyncManager sharedManager] start];
    if (@available(iOS 17.0, *)) {
        [[ICiCloudSyncManager sharedManager] start];
    }

    [ICTranscriptionDebugAutomation startCommandProcessing];
    BOOL handledTranscriptionLaunchArguments = [ICTranscriptionDebugAutomation handleLaunchArguments];
    if (handledTranscriptionLaunchArguments) {
        [[ICDiagnosticLogger shared] logEvent:@"debug-automation" message:@"Launch-Argumente verarbeitet" metadata:nil];
    }
}

+ (UIViewController*)databaseUnavailableViewControllerForError:(NSError*)error
{
    UIViewController* controller = [[UIViewController alloc] initWithNibName:nil bundle:nil];
    controller.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    titleLabel.adjustsFontForContentSizeCategory = YES;
    titleLabel.numberOfLines = 0;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    titleLabel.text = @"Local Data Unavailable".ls;

    UILabel* messageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    messageLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    messageLabel.adjustsFontForContentSizeCategory = YES;
    messageLabel.numberOfLines = 0;
    messageLabel.textAlignment = NSTextAlignmentCenter;
    messageLabel.text = error.localizedDescription ?: @"InstacastPlus could not open the local podcast database. Your data was left unchanged. Check the available storage, restart the device, and open InstacastPlus again.".ls;

    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[titleLabel, messageLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 16;
    [controller.view addSubview:stack];

    UILayoutGuide* safeArea = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:safeArea.leadingAnchor constant:24],
        [safeArea.trailingAnchor constraintGreaterThanOrEqualToAnchor:stack.trailingAnchor constant:24],
        [stack.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:safeArea.centerYAnchor],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:safeArea.topAnchor constant:24],
        [safeArea.bottomAnchor constraintGreaterThanOrEqualToAnchor:stack.bottomAnchor constant:24],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:520],
    ]];
    return controller;
}



#pragma mark -

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options
{
    [[ICDiagnosticLogger shared] recordLifecycle:@"applicationOpenURL"
                                        metadata:@{
                                            @"scheme": url.scheme ?: @"",
                                            @"host": url.host ?: @"",
                                            @"path": url.path ?: @"",
                                            @"absoluteString": url.absoluteString ?: @"",
                                        }];

    NSSet* subscribeSchemes = [NSSet setWithObjects:@"pcast", @"itpc", @"podcast", @"podcast-subscribe", @"instacast-subscribe", @"instacast", nil];
    __block BOOL handled = NO;
    
    if ([ICTranscriptionDebugAutomation handle:url]) {
        return YES;
    }
    else if ([subscribeSchemes containsObject:[url scheme]]) {
        [self _handlePcastURL:url];
        handled = YES;
    }
    else if ([url isFileURL] && [[[url path] pathExtension] compare:@"xml" options:NSCaseInsensitiveSearch] == NSOrderedSame)
    {
        if (self.mainViewController) {
            [self.mainViewController openBackupFileURL:url];
        }
        else {
            self.pendingBackupFileURL = url;
        }
        handled = YES;
    }
    else if ([url isFileURL] && [[[url path] pathExtension] compare:@"opml" options:NSCaseInsensitiveSearch] == NSOrderedSame)
    {
        self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Importing…".ls];
        [self.mInfo showInWindow:self.window];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSError* readError = nil;
            NSData *opmlData = [ICXMLImportLimits readDataFromURL:url error:&readError];

            if (!opmlData || opmlData.length == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.mInfo close];
                    self.mInfo = nil;
                    [App showBackgroundErrorWithTitle:@"Import Error".ls
                                              message:readError.localizedDescription ?: @"The OPML file is empty or could not be read.".ls
                                             duration:8.0];
                });
                return;
            }

            [[SubscriptionManager sharedSubscriptionManager] importOPMLData:opmlData completion:^(NSError* error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.mInfo close];
                    self.mInfo = nil;
                    if (error) {
                        [App showBackgroundErrorWithTitle:@"Import Error".ls
                                                  message:error.localizedDescription
                                                 duration:8.0];
                    }
                });
            } progress:^(float progress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ((progress * 100) > 3)
                    {
                        [self.mInfo setProgress:progress];
                    }
                });
            }];
        });
        handled = YES;
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
        popPresenter.permittedArrowDirections = 0;

        if ([ICAppearanceManager sharedManager].nightSettingMode) {
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        } else {
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIWindow *keyWindow = [UIApplication sharedApplication].windows.firstObject;
#pragma clang diagnostic pop
        UIViewController *rootVC = keyWindow.rootViewController;
        [rootVC presentViewController:alert animated:YES completion:nil];
        handled = YES;
    }
    return handled;
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

- (void) _updateAppContentAfterBecomingActive
{
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

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [[ICDiagnosticLogger shared] recordLifecycle:@"applicationWillEnterForeground" metadata:nil];
    [self _updateAppContentAfterBecomingActive];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [[ICDiagnosticLogger shared] recordLifecycle:@"applicationDidEnterBackground"
                                        metadata:@{
                                            @"queuedTranscriptions": @([TranscriptionQueue shared].count),
                                        }];
	[[UNUserNotificationCenter currentNotificationCenter] setBadgeCount:([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0 withCompletionHandler:nil];
	
	if (!self.mainViewController.presentedViewController) {
		[[CacheManager sharedCacheManager] tidyUp];
	}
    
    [DMANAGER save];
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    [[ICDiagnosticLogger shared] recordLifecycle:@"applicationWillTerminate"
                                        metadata:@{
                                            @"queuedTranscriptions": @([TranscriptionQueue shared].count),
                                        }];
}

- (void) setNeedsStatusBarAppearanceUpdate {
    [self.mainViewController setNeedsStatusBarAppearanceUpdate];
}
#pragma mark -
#pragma mark Push Notifications

- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    _flags.apnRegisterSuccess = 1;
}

- (void)application:(UIApplication *)application didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    ErrLog(@"register for remote notifications failed: %@", error);
    _flags.apnRegisterSuccess = 0;
}


- (CDFeed*) _subscribedFeedForNotification:(NSDictionary*)notification
{
    NSDictionary* aps = notification[@"aps"];
    NSString* feedMd5 = notification[@"feed_hash"];
    
    if (!feedMd5) {
        feedMd5 = aps[@"feed_hash"];
    }
    
    //NSString* guidMd5 = [notification objectForKey:@"episode_hash"];
    
    for(CDFeed* feed in DMANAGER.visibleFeeds) {
        if ([[[feed.sourceURL absoluteString] MD5Hash] isEqualToString:feedMd5]) {
            return feed;
        }
    }
    return nil;
}


- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))handler
{
    if (@available(iOS 17.0, *)) {
        if ([[ICiCloudSyncManager sharedManager] shouldHandleRemoteNotification:userInfo]) {
            [[ICiCloudSyncManager sharedManager] performBackgroundSyncWithCompletion:handler];
            return;
        }
    }

    NSDictionary* notificationContent = userInfo[@"aps"];
    
//    NSDictionary* alert = notificationContent[@"alert"];
//    if (alert && [alert isKindOfClass:[NSDictionary class]])
//    {
//        NSString* body = alert[@"body"];
//        if (body) {
//            [App alertWithTitle:@"Notification".ls message:body];
//        }
//    }
//    
    
    CDFeed* feed = [self _subscribedFeedForNotification:userInfo];
    if (feed)
    {
        NSString* feedEvent = notificationContent[@"feed_event"];
        
        if ([feedEvent isEqualToString:@"reload"])
        {
            [[SubscriptionManager sharedSubscriptionManager] reloadContentOfFeed:feed recoverArchivedEpisodes:NO completion:^(BOOL success, NSArray* newEpisodes, NSError *error) {
                
                if (success) {
                    [self _handleReceivedNewEpisodesAfterRemoteNotification:newEpisodes feed:feed];
                }
                
                UIBackgroundFetchResult result = (success) ? (([newEpisodes count] > 0) ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData) : UIBackgroundFetchResultFailed;
                handler(result);
                
            }];
        }
        else
        {
            [[SubscriptionManager sharedSubscriptionManager] refreshFeeds:@[feed] etagHandling:NO completion:^(BOOL success, NSArray* newEpisodes, NSError* error) {
                
                if (success) {
                    [self _handleReceivedNewEpisodesAfterRemoteNotification:newEpisodes feed:feed];
                }
                
                UIBackgroundFetchResult result = (success) ? (([newEpisodes count] > 0) ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData) : UIBackgroundFetchResultFailed;
                handler(result);
            }];
        }
    }
    else {
        handler(UIBackgroundFetchResultNoData);
    }
}

- (void) _handleReceivedNewEpisodesAfterRemoteNotification:(NSArray*)newEpisodes feed:(CDFeed*)feed
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    if ([newEpisodes count] > 0 && ![cman isCachingFeed:feed])
    {
        for(CDEpisode* episode in newEpisodes)
        {
            if ([episode.feed boolForKey:EnableNewEpisodeNotification] && App.applicationState == UIApplicationStateBackground) {
                // UILocalNotification is deprecated but still functional - keeping for stability
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                UILocalNotification* notification = [[UILocalNotification alloc] init];
                NSString* episodeTitle = [NSString stringWithFormat:@"%@ - %@", episode.feed.title, [episode cleanTitleUsingFeedTitle:episode.feed.title]];
                notification.alertBody = [NSString stringWithFormat:@"'%@' is available to stream.".ls, episodeTitle];
                notification.soundName = @"NewEpisodes";
                notification.userInfo = @{ @"episode_hash" : [episode objectHash]};
                [App presentLocalNotificationNow:notification];
#pragma clang diagnostic pop
            }
        }
    }
}

// UILocalNotification delegate methods are deprecated but kept for backwards compatibility
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)application:(UIApplication *)application didReceiveLocalNotification:(UILocalNotification *)notification
{
    if (!notification) {
        return;
    }

    NSString* episodeHash = notification.userInfo[@"episode_hash"];

    CDEpisode* episode = [DMANAGER episodeWithObjectHash:episodeHash];
    [self.mainViewController showShowNotesOfEpisode:episode animated:NO];

    [application cancelLocalNotification:notification];
}
#pragma clang diagnostic pop

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)application:(UIApplication *)application handleActionWithIdentifier:(NSString *)identifier forLocalNotification:(UILocalNotification *)localNotification completionHandler:(void (^)(void))completionHandler
{
    if ([identifier isEqualToString:@"play"]) {
        NSString* episodeHash = localNotification.userInfo[@"episode_hash"];
        CDEpisode* episode = [DMANAGER episodeWithObjectHash:episodeHash];
        [[AudioSession sharedAudioSession] playEpisode:episode];
    }

    completionHandler();
}
#pragma clang diagnostic pop

#pragma mark - Background Fetch

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler
{
    [[CacheManager sharedCacheManager] handleEventsForBackgroundURLSession:identifier completionHandler:completionHandler];
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
        // return immediately if there's no internet
        if (App.networkAccessTechnology < kICNetworkAccessTechnlogyEDGE) {
            completionHandler(UIBackgroundFetchResultFailed);
            return;
        }
        
        // 1 abo rauspicken, biggest last update interval
        NSArray* subscriptions = [DMANAGER visibleFeeds];
        NSSortDescriptor* sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"lastUpdate" ascending:YES];
        NSArray* sortedSubscriptions = [subscriptions sortedArrayUsingDescriptors:@[ sortDescriptor ]];
        
        NSMutableArray* firstSubscriptions = [[NSMutableArray alloc] init];
        NSInteger i=0;
        
#define MAX_SUBSCRIPTIONS_TO_FETCH 1
        
        for(CDFeed* feed in sortedSubscriptions)
        {
            [firstSubscriptions addObject:feed];
            i++;
            if (i>=MAX_SUBSCRIPTIONS_TO_FETCH) {
                break;
            }
        }
        
        
        NSDate* startDate = [NSDate date];
        [[SubscriptionManager sharedSubscriptionManager] refreshFeeds:firstSubscriptions
                                                         etagHandling:YES
                                                           completion:^(BOOL success, NSArray *newEpisodes, NSError* error) {

                                                               ErrLog(@"background fetch interval: %lf sec", [[NSDate date] timeIntervalSinceDate:startDate]);
                                                               
                                                               if (success) {
                                                                   completionHandler(([newEpisodes count] > 0) ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData );
                                                               }
                                                               else {
                                                                   completionHandler(UIBackgroundFetchResultFailed);
                                                               }
                                                           }];
    });
}
#pragma clang diagnostic pop


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
    
    __weak InstacastAppDelegate* weakSelf = self;
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

- (void) _playEpisode:(CDEpisode*)episode atPosition:(NSTimeInterval)position
{
    episode.position = position;
    PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:YES];
    [playbackController presentFromParentViewController:self.mainViewController];
}

#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    (void)application;

    UISceneSessionRole role = connectingSceneSession.role;
    [[ICDiagnosticLogger shared] recordLifecycle:@"configurationForConnectingSceneSession"
                                        metadata:@{
                                            @"role": role ?: @"",
                                            @"urlContextCount": @(options.URLContexts.count),
                                            @"userActivityCount": @(options.userActivities.count),
                                        }];

    if ([role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication]) {
        UISceneConfiguration* configuration = [UISceneConfiguration configurationWithName:@"CarPlay" sessionRole:role];
        if (!configuration.sceneClass) {
            configuration.sceneClass = [CPTemplateApplicationScene class];
        }
        if (!configuration.delegateClass) {
            configuration.delegateClass = [InstacastSceneDelegate class];
        }
        return configuration;
    }

    if ([role isEqualToString:CPTemplateApplicationDashboardSceneSessionRoleApplication]) {
        UISceneConfiguration* configuration = [UISceneConfiguration configurationWithName:nil sessionRole:role];
        configuration.sceneClass = [CPTemplateApplicationDashboardScene class];
        configuration.delegateClass = [InstacastSceneDelegate class];
        return configuration;
    }

    if ([role isEqualToString:CPTemplateApplicationInstrumentClusterSceneSessionRoleApplication]) {
        UISceneConfiguration* configuration = [UISceneConfiguration configurationWithName:nil sessionRole:role];
        configuration.sceneClass = [CPTemplateApplicationInstrumentClusterScene class];
        configuration.delegateClass = [InstacastSceneDelegate class];
        return configuration;
    }

    UISceneConfiguration* configuration = [UISceneConfiguration configurationWithName:@"Default Configuration" sessionRole:role];
    if (!configuration.sceneClass) {
        configuration.sceneClass = [UIWindowScene class];
    }
    if (!configuration.delegateClass) {
        configuration.delegateClass = [InstacastSceneDelegate class];
    }
    return configuration;
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}


@end
