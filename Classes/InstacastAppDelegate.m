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
static NSString* const ICTranscriptionContinuedTaskIdentifierPattern = @"com.iteconomy.instacastplus.transcription.continued.*";
// Concrete identifier covered by the wildcard entry in BGTaskSchedulerPermittedIdentifiers.
// Used when iOS refuses the wildcard launch-handler registration.
static NSString* const ICTranscriptionContinuedTaskIdentifierFallback = @"com.iteconomy.instacastplus.transcription.continued.session";
static NSString* const ICTranscriptionContinuedGPUPath = @"continued-gpu";
static NSString* const ICTranscriptionContinuedCPUPath = @"continued-cpu";
static NSString* const ICTranscriptionActiveContinuedPath = @"ICTranscriptionActiveContinuedPath";
static NSString* const ICTranscriptionActiveContinuedIdentifier = @"ICTranscriptionActiveContinuedIdentifier";
static NSString* const ICTranscriptionBackgroundTaskRequested = @"TranscriptionBackgroundTaskRequested";
static NSString* const ICTranscriptionLegacyProcessingPath = @"legacy-processing";
static NSString* const InstacastMainViewControllerDidBecomeReadyNotification = @"InstacastMainViewControllerDidBecomeReadyNotification";
NSNotificationName const InstacastDatabaseStartupDidFailNotification = @"InstacastDatabaseStartupDidFailNotification";
static NSString* const ICPendingBackgroundSessionIdentifierKey = @"identifier";
static NSString* const ICPendingBackgroundSessionCompletionKey = @"completion";
static NSString* const ICPendingRemoteNotificationUserInfoKey = @"userInfo";
static NSString* const ICPendingRemoteNotificationCompletionKey = @"completion";
static NSString* const ICPendingNotificationInteractionUserInfoKey = @"userInfo";
static NSString* const ICPendingNotificationInteractionActionKey = @"action";
static NSString* const ICBackgroundFeedRefreshAttemptsKey = @"ICBackgroundFeedRefreshAttempts";
static const NSUInteger ICBackgroundFeedRefreshBatchSize = 10;

@interface InstacastAppDelegate () <UNUserNotificationCenterDelegate>
@property BOOL resettingContext;
@property (strong) VDModalInfo* mInfo;
@property (strong) VDModalInfo* loadingInfo;
@property (nonatomic, strong) DirectoryFeedViewController* feedView;
@property (nonatomic, strong) NSURL* pendingBackupFileURL;
@property (nonatomic, readwrite) ICDatabaseStartupState databaseStartupState;
@property (nonatomic, strong, readwrite) NSError* databasePreparationError;
@property (nonatomic, strong) NSMutableArray<NSDictionary*>* pendingBackgroundURLSessionEvents;
@property (nonatomic, strong) NSMutableArray<NSDictionary*>* pendingApplicationOpenURLs;
@property (nonatomic, strong) NSDictionary* pendingDatabaseLaunchOptions;
@property (nonatomic) BOOL databaseStartupDidBegin;
@property (nonatomic, strong) NSMutableArray<BGTask*>* pendingTranscriptionBackgroundTasks;
@property (nonatomic, strong) NSMapTable<BGTask*, id>* activeTranscriptionTaskExpirationHandlers;
@property (nonatomic, strong) NSMutableArray<NSDictionary*>* pendingDatabaseRemoteNotifications;
@property (nonatomic, strong) NSMutableArray* pendingDatabaseFetchCompletionHandlers;
@property (nonatomic, strong) NSMutableArray<NSDictionary*>* pendingNotificationInteractions;
@property (nonatomic, strong) NSMutableSet<NSString*>* handledNotificationResponseIdentifiers;
@property (nonatomic) BOOL notificationSceneReady;
@property (nonatomic) UIBackgroundTaskIdentifier pendingDatabaseSystemCallbacksBackgroundTask;
@property (nonatomic) NSUInteger pendingDatabaseSystemCallbacksBackgroundTaskGeneration;
/// The identifier form iOS accepted a continued-task launch handler for: either the
/// wildcard pattern (submits append a UUID) or the concrete fallback. nil = unavailable.
@property (nonatomic, copy, nullable) NSString* registeredContinuedTaskIdentifier;

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
                                                         usingQueue:dispatch_get_main_queue()
                                                      launchHandler:^(BGTask * _Nonnull task) {
        [self _handleTranscriptionProcessingTask:(BGProcessingTask*)task];
    }];

    if (@available(iOS 26.0, *)) {
        void (^continuedLaunchHandler)(BGTask*) = ^(BGTask * _Nonnull task) {
            [self _handleTranscriptionContinuedProcessingTask:(BGContinuedProcessingTask*)task];
        };
        // iOS 26.5 rejects the wildcard launch-handler registration on device
        // (registered=NO in every session). A submit against an unregistered
        // identifier throws NSInternalInconsistencyException, so the concrete
        // identifier — also covered by the Info.plist wildcard entry — is
        // registered as soon as the pattern is refused. Registering both forms
        // unconditionally would risk a duplicate-identifier exception.
        BOOL registeredPattern = [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:ICTranscriptionContinuedTaskIdentifierPattern
                                                                                       usingQueue:dispatch_get_main_queue()
                                                                                    launchHandler:continuedLaunchHandler];
        BOOL registeredFallback = NO;
        if (registeredPattern) {
            self.registeredContinuedTaskIdentifier = ICTranscriptionContinuedTaskIdentifierPattern;
        } else {
            registeredFallback = [[BGTaskScheduler sharedScheduler] registerForTaskWithIdentifier:ICTranscriptionContinuedTaskIdentifierFallback
                                                                                       usingQueue:dispatch_get_main_queue()
                                                                                    launchHandler:continuedLaunchHandler];
            self.registeredContinuedTaskIdentifier = registeredFallback ? ICTranscriptionContinuedTaskIdentifierFallback : nil;
        }
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask registriert"
                                     metadata:@{
                                         @"identifier": self.registeredContinuedTaskIdentifier ?: @"",
                                         @"registeredPattern": @(registeredPattern),
                                         @"registeredFallback": @(registeredFallback),
                                         @"gpuSupported": @((BGTaskScheduler.supportedResources & BGContinuedProcessingTaskRequestResourcesGPU) != 0),
                                     }];
    }
}

- (BOOL)transcriptionContinuedTasksAvailable {
    return self.registeredContinuedTaskIdentifier.length > 0;
}

- (NSString*)newTranscriptionContinuedTaskIdentifier {
    NSString* registered = self.registeredContinuedTaskIdentifier;
    if (registered.length == 0) {
        return nil;
    }
    if ([registered hasSuffix:@"*"]) {
        NSString* prefix = [registered substringToIndex:registered.length - 1];
        return [prefix stringByAppendingString:NSUUID.UUID.UUIDString];
    }
    return registered;
}

- (void)_scheduleTranscriptionProcessingTask {
    [[TranscriptionQueue shared] scheduleAutomaticBackgroundProcessingIfNeeded];
}

- (BOOL)_clearActiveContinuedRequestMatchingIdentifier:(NSString*)identifier {
    NSString* storedIdentifier = [USER_DEFAULTS stringForKey:ICTranscriptionActiveContinuedIdentifier];
    if (identifier.length == 0 || ![storedIdentifier isEqualToString:identifier]) {
        return NO;
    }
    [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedPath];
    [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedIdentifier];
    [USER_DEFAULTS setBool:NO forKey:ICTranscriptionBackgroundTaskRequested];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ICTranscriptionQueueDidChangeNotification" object:nil];
    return YES;
}

- (void)_retireDeferredTranscriptionTaskOwnership:(BGTask*)task reason:(NSString*)reason {
    BOOL continuedTask = NO;
    if (@available(iOS 26.0, *)) {
        continuedTask = [task isKindOfClass:BGContinuedProcessingTask.class];
    }
    if (continuedTask) {
        [self _clearActiveContinuedRequestMatchingIdentifier:task.identifier];
    } else {
        [USER_DEFAULTS setBool:NO forKey:ICTranscriptionBackgroundTaskRequested];
    }
    [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                  message:@"Zurückgestellte Background-Task-Zuständigkeit beendet"
                                 metadata:@{
                                     @"identifier": task.identifier ?: @"",
                                     @"continued": @(continuedTask),
                                     @"reason": reason ?: @"",
                                 }];
    [self _scheduleTranscriptionProcessingTask];
}

- (void)_installTranscriptionTaskExpirationHandler:(BGTask*)task {
    __weak typeof(self) weakSelf = self;
    __weak BGTask* weakTask = task;
    task.expirationHandler = ^{
        dispatch_block_t expire = ^{
            __strong typeof(weakSelf) self = weakSelf;
            BGTask* task = weakTask;
            if (self && task) {
                [self _expireTranscriptionTask:task];
            }
        };
        if ([NSThread isMainThread]) {
            expire();
        }
        else {
            dispatch_async(dispatch_get_main_queue(), expire);
        }
    };
}

- (void)_expireTranscriptionTask:(BGTask*)task {
    if ([self.pendingTranscriptionBackgroundTasks containsObject:task]) {
        [self.pendingTranscriptionBackgroundTasks removeObjectIdenticalTo:task];
        [task setTaskCompletedWithSuccess:NO];
        [self _retireDeferredTranscriptionTaskOwnership:task reason:@"database-wait-expired"];
        return;
    }

    void (^activeExpirationHandler)(void) = [self.activeTranscriptionTaskExpirationHandlers objectForKey:task];
    if (activeExpirationHandler) {
        [self.activeTranscriptionTaskExpirationHandlers removeObjectForKey:task];
        activeExpirationHandler();
    }
}

- (BOOL)_deferTranscriptionTaskUntilDatabaseReady:(BGTask*)task {
    [self _installTranscriptionTaskExpirationHandler:task];
    if (self.databaseStartupState == ICDatabaseStartupStateReady) {
        return NO;
    }
    if (self.databaseStartupState == ICDatabaseStartupStateFailed) {
        [task setTaskCompletedWithSuccess:NO];
        [self _retireDeferredTranscriptionTaskOwnership:task reason:@"database-already-failed"];
        return YES;
    }

    [self.pendingTranscriptionBackgroundTasks addObject:task];
    return YES;
}

- (void)_handleTranscriptionProcessingTask:(BGProcessingTask*)processingTask {
    if ([self _deferTranscriptionTaskUntilDatabaseReady:processingTask]) {
        return;
    }
    NSString* requestedContinuedPath = [USER_DEFAULTS stringForKey:ICTranscriptionActiveContinuedPath];
    if ([requestedContinuedPath hasPrefix:@"continued-"]) {
        processingTask.expirationHandler = nil;
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGProcessingTask wegen ausstehendem Continued-Lauf abgelehnt"
                                     metadata:@{
                                         @"continuedPath": requestedContinuedPath,
                                     }];
        [processingTask setTaskCompletedWithSuccess:NO];
        return;
    }
    __block id queueObserver = nil;
    __block id cancellationObserver = nil;
    __block BOOL taskCompleted = NO;
    __block BOOL completionRequested = NO;
    __block BOOL requestedSuccess = YES;
    __block NSString* requestedReason = nil;
    __block BOOL executionPathCompleted = NO;
    __block BOOL persistenceWaitLogged = NO;
    __block BOOL persistenceRetryAttempted = NO;
    __block BOOL serverPersistenceRetryAttempted = NO;
    void (^completeTask)(BOOL, NSString*) = ^(BOOL success, NSString* reason) {
        if (taskCompleted) return;
        if (!completionRequested) {
            completionRequested = YES;
            requestedSuccess = success;
            requestedReason = [reason copy];
        }
        else if (!success) {
            requestedSuccess = NO;
            requestedReason = [reason copy];
        }
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        if (!executionPathCompleted) {
            executionPathCompleted = YES;
            [queue completeBackgroundExecutionPathWithSuccess:requestedSuccess reason:requestedReason];
            if (taskCompleted) return;
        }
        if (queue.hasPendingQueuePersistence) {
            if (!persistenceWaitLogged) {
                persistenceWaitLogged = YES;
                [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                              message:@"BGProcessingTask wartet auf Queue-Persistenz"
                                             metadata:@{
                                                 @"path": ICTranscriptionLegacyProcessingPath,
                                                 @"reason": requestedReason ?: @"",
                                             }];
            }
            return;
        }
        NSError* queuePersistenceError = queue.queuePersistenceError;
        if (queuePersistenceError && !persistenceRetryAttempted) {
            persistenceRetryAttempted = YES;
            [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                          message:@"BGProcessingTask wiederholt fehlgeschlagenen Queue-Snapshot"
                                         metadata:@{
                                             @"path": ICTranscriptionLegacyProcessingPath,
                                             @"error": queuePersistenceError.localizedDescription ?: @"",
                                         }];
            [queue retryQueuePersistenceAfterFailure];
            return;
        }
        if (queuePersistenceError) {
            requestedSuccess = NO;
            requestedReason = @"queue-persistence-failed";
        }
        NSError* serverQueuePersistenceError = [ServerTranscriptionManager shared].queuePersistenceError;
        if (serverQueuePersistenceError && !serverPersistenceRetryAttempted) {
            serverPersistenceRetryAttempted = YES;
            [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                          message:@"BGProcessingTask wiederholt fehlgeschlagenen Server-Queue-Snapshot"
                                         metadata:@{
                                             @"path": ICTranscriptionLegacyProcessingPath,
                                             @"error": serverQueuePersistenceError.localizedDescription ?: @"",
                                         }];
            [[ServerTranscriptionManager shared] retryQueuePersistenceAfterFailure];
            return;
        }
        if (serverQueuePersistenceError) {
            requestedSuccess = NO;
            requestedReason = @"server-queue-persistence-failed";
        }
        success = requestedSuccess;
        reason = requestedReason;
        taskCompleted = YES;
        [self.activeTranscriptionTaskExpirationHandlers removeObjectForKey:processingTask];
        if (queueObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:queueObserver];
            queueObserver = nil;
        }
        if (cancellationObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:cancellationObserver];
            cancellationObserver = nil;
        }
        [USER_DEFAULTS setBool:NO forKey:ICTranscriptionBackgroundTaskRequested];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGProcessingTask abgeschlossen"
                                     metadata:@{
                                         @"path": ICTranscriptionLegacyProcessingPath,
                                         @"reason": reason ?: @"",
                                         @"success": @(success),
        }];
        [processingTask setTaskCompletedWithSuccess:success];
        [self _scheduleTranscriptionProcessingTask];
    };
    [self.activeTranscriptionTaskExpirationHandlers setObject:[^{
        [[ICDiagnosticLogger shared] logEvent:@"background-task" message:@"BGProcessingTask abgelaufen" metadata:@{
            @"path": ICTranscriptionLegacyProcessingPath,
        }];
        completeTask(NO, @"legacy-processing-expired");
    } copy] forKey:processingTask];

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
        if (completionRequested) {
            completeTask(requestedSuccess, requestedReason);
            return;
        }
        if (!queue.isProcessing && queue.currentItem == nil &&
            ![ServerTranscriptionManager shared].isProcessing &&
            !ChapterGenerator.shared.hasActiveOpenAIBackgroundCancellationWork) {
            completeTask(YES, @"legacy-processing-completed");
        }
    }];

    cancellationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"ICOpenAIBackgroundCancellationWorkDidChangeNotification"
                                                                               object:nil
                                                                                queue:[NSOperationQueue mainQueue]
                                                                           usingBlock:^(__unused NSNotification *note) {
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        if (!queue.isProcessing && queue.currentItem == nil &&
            ![ServerTranscriptionManager shared].isProcessing &&
            !ChapterGenerator.shared.hasActiveOpenAIBackgroundCancellationWork) {
            completeTask(YES, @"remote-cancellation-reconciled");
        }
    }];

    [[TranscriptionQueue shared] resumeIfNeeded];
    TranscriptionQueue* queue = [TranscriptionQueue shared];
    if (!queue.isProcessing && queue.currentItem == nil &&
        ![ServerTranscriptionManager shared].isProcessing &&
        !ChapterGenerator.shared.hasActiveOpenAIBackgroundCancellationWork) {
        completeTask(YES, @"legacy-processing-empty");
    }
}

- (void)_handleTranscriptionContinuedProcessingTask:(BGContinuedProcessingTask*)continuedTask API_AVAILABLE(ios(26.0)) {
    if ([self _deferTranscriptionTaskUntilDatabaseReady:continuedTask]) {
        return;
    }
    NSString* activeIdentifier = [[USER_DEFAULTS stringForKey:ICTranscriptionActiveContinuedIdentifier] copy];
    if (self.activeTranscriptionTaskExpirationHandlers.count > 0) {
        continuedTask.expirationHandler = nil;
        BOOL rejectedCurrentRequest = [self _clearActiveContinuedRequestMatchingIdentifier:continuedTask.identifier];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask wegen aktivem Systemtask abgelehnt"
                                     metadata:@{
                                         @"activeTaskCount": @(self.activeTranscriptionTaskExpirationHandlers.count),
                                         @"rejectedCurrentRequest": @(rejectedCurrentRequest),
                                     }];
        [continuedTask setTaskCompletedWithSuccess:NO];
        [self _scheduleTranscriptionProcessingTask];
        return;
    }
    NSString* continuedPath = [[USER_DEFAULTS stringForKey:ICTranscriptionActiveContinuedPath] copy];
    BOOL validIdentifier = activeIdentifier.length > 0 && [continuedTask.identifier isEqualToString:activeIdentifier];
    BOOL validPath = [continuedPath isEqualToString:ICTranscriptionContinuedGPUPath] ||
                     [continuedPath isEqualToString:ICTranscriptionContinuedCPUPath];
    if (!validIdentifier || !validPath) {
        [self.activeTranscriptionTaskExpirationHandlers removeObjectForKey:continuedTask];
        BOOL rejectedCurrentRequest = [self _clearActiveContinuedRequestMatchingIdentifier:continuedTask.identifier];
        if (rejectedCurrentRequest) {
            [[TranscriptionQueue shared] deactivateBackgroundExecutionPathWithReason:@"continued-path-missing"];
        }
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask ohne gültigen Rechenpfad abgelehnt"
                                     metadata:@{
                                         @"identifier": continuedTask.identifier ?: @"",
                                         @"storedIdentifier": activeIdentifier ?: @"missing",
                                         @"storedPath": continuedPath ?: @"missing",
                                         @"rejectedCurrentRequest": @(rejectedCurrentRequest),
                                     }];
        [continuedTask setTaskCompletedWithSuccess:NO];
        return;
    }
    __block id queueObserver = nil;
    __block id progressObserver = nil;
    __block id cancellationObserver = nil;
    __block BOOL taskCompleted = NO;
    __block BOOL completionRequested = NO;
    __block BOOL requestedSuccess = YES;
    __block NSString* requestedReason = nil;
    __block BOOL executionPathCompleted = NO;
    __block BOOL persistenceWaitLogged = NO;
    __block BOOL persistenceRetryAttempted = NO;
    __block BOOL serverPersistenceRetryAttempted = NO;

    continuedTask.progress.totalUnitCount = 1000;
    continuedTask.progress.completedUnitCount = 0;

    void (^completeTask)(BOOL, NSString*) = ^(BOOL success, NSString* reason) {
        if (taskCompleted) return;
        if (!completionRequested) {
            completionRequested = YES;
            requestedSuccess = success;
            requestedReason = [reason copy];
        }
        else if (!success) {
            requestedSuccess = NO;
            requestedReason = [reason copy];
        }
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        if (!executionPathCompleted) {
            executionPathCompleted = YES;
            [queue completeBackgroundExecutionPathWithSuccess:requestedSuccess reason:requestedReason];
            if (taskCompleted) return;
        }
        if (queue.hasPendingQueuePersistence) {
            if (!persistenceWaitLogged) {
                persistenceWaitLogged = YES;
                [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                              message:@"BGContinuedProcessingTask wartet auf Queue-Persistenz"
                                             metadata:@{
                                                 @"path": continuedPath,
                                                 @"reason": requestedReason ?: @"",
                                             }];
            }
            return;
        }
        NSError* queuePersistenceError = queue.queuePersistenceError;
        if (queuePersistenceError && !persistenceRetryAttempted) {
            persistenceRetryAttempted = YES;
            [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                          message:@"BGContinuedProcessingTask wiederholt fehlgeschlagenen Queue-Snapshot"
                                         metadata:@{
                                             @"path": continuedPath,
                                             @"error": queuePersistenceError.localizedDescription ?: @"",
                                         }];
            [queue retryQueuePersistenceAfterFailure];
            return;
        }
        if (queuePersistenceError) {
            requestedSuccess = NO;
            requestedReason = @"queue-persistence-failed";
        }
        NSError* serverQueuePersistenceError = [ServerTranscriptionManager shared].queuePersistenceError;
        if (serverQueuePersistenceError && !serverPersistenceRetryAttempted) {
            serverPersistenceRetryAttempted = YES;
            [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                          message:@"BGContinuedProcessingTask wiederholt fehlgeschlagenen Server-Queue-Snapshot"
                                         metadata:@{
                                             @"path": continuedPath,
                                             @"error": serverQueuePersistenceError.localizedDescription ?: @"",
                                         }];
            [[ServerTranscriptionManager shared] retryQueuePersistenceAfterFailure];
            return;
        }
        if (serverQueuePersistenceError) {
            requestedSuccess = NO;
            requestedReason = @"server-queue-persistence-failed";
        }
        success = requestedSuccess;
        reason = requestedReason;
        taskCompleted = YES;
        [self.activeTranscriptionTaskExpirationHandlers removeObjectForKey:continuedTask];
        if (queueObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:queueObserver];
            queueObserver = nil;
        }
        if (progressObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:progressObserver];
            progressObserver = nil;
        }
        if (cancellationObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:cancellationObserver];
            cancellationObserver = nil;
        }
        [self _clearActiveContinuedRequestMatchingIdentifier:activeIdentifier];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask abgeschlossen"
                                     metadata:@{
                                         @"path": continuedPath,
                                         @"reason": reason ?: @"",
                                         @"success": @(success),
                                         @"completedUnitCount": @(continuedTask.progress.completedUnitCount),
        }];
        [continuedTask setTaskCompletedWithSuccess:success];
        [self _scheduleTranscriptionProcessingTask];
    };

    [self.activeTranscriptionTaskExpirationHandlers setObject:[^{
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask abgelaufen"
                                     metadata:@{
                                         @"path": continuedPath,
        }];
        NSString* reason = [continuedPath stringByAppendingString:@"-expired"];
        completeTask(NO, reason);
    } copy] forKey:continuedTask];

    NSString* detail = [continuedPath isEqualToString:ICTranscriptionContinuedGPUPath]
        ? @"BGContinuedProcessingTask mit GPU gestartet"
        : @"BGContinuedProcessingTask mit CPU/Neural Engine gestartet";
    [[TranscriptionQueue shared] activateBackgroundExecutionPathWithPath:continuedPath detail:detail];
    [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                  message:@"BGContinuedProcessingTask gestartet"
                                 metadata:@{
                                     @"identifier": continuedTask.identifier ?: @"",
                                     @"path": continuedPath,
                                     @"gpuSupported": @((BGTaskScheduler.supportedResources & BGContinuedProcessingTaskRequestResourcesGPU) != 0),
                                 }];

    void (^updateTaskStatus)(NSNumber*) = ^(NSNumber* progressValue) {
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        ICTranscriptionQueueItem* item = queue.currentItem ?: queue.items.firstObject;
        NSString* title = item.episodeTitle.length > 0
            ? item.episodeTitle
            : NSLocalizedString(@"Podcast-Verarbeitung", nil);
        NSString* stage = item.statusDetail;
        if (stage.length == 0) {
            switch (item.status) {
                case ICTranscriptionStatusAnalyzingMusic:
                    stage = NSLocalizedString(@"Audio wird analysiert.", nil);
                    break;
                case ICTranscriptionStatusDownloadingModel:
                    stage = NSLocalizedString(@"Sprachmodell wird vorbereitet.", nil);
                    break;
                case ICTranscriptionStatusTranscribing:
                    stage = NSLocalizedString(@"Audio wird transkribiert.", nil);
                    break;
                case ICTranscriptionStatusGeneratingChapters:
                    stage = NSLocalizedString(@"Kapitel und Zusammenfassung werden erstellt.", nil);
                    break;
                default:
                    stage = NSLocalizedString(@"Transkription wird vorbereitet.", nil);
                    break;
            }
        }
        if (progressValue) {
            double fraction = MAX(0.0, MIN(1.0, progressValue.doubleValue));
            stage = [NSString stringWithFormat:NSLocalizedString(@"%@ · %.0f %%", nil), stage, fraction * 100.0];
        }
        [continuedTask updateTitle:title subtitle:stage];
    };
    updateTaskStatus(nil);

    progressObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"ICTranscriptionDidProgressNotification"
                                                                         object:nil
                                                                          queue:[NSOperationQueue mainQueue]
                                                                     usingBlock:^(NSNotification *note) {
        NSNumber* progressValue = note.userInfo[@"progress"];
        double fraction = progressValue ? progressValue.doubleValue : 0.0;
        continuedTask.progress.completedUnitCount = (int64_t)llround(MAX(0.0, MIN(1.0, fraction)) * 1000.0);
        updateTaskStatus(@(fraction));
    }];

    queueObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"ICTranscriptionQueueDidChangeNotification"
                                                                      object:nil
                                                                       queue:[NSOperationQueue mainQueue]
                                                                  usingBlock:^(__unused NSNotification *note) {
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        updateTaskStatus(nil);
        if (completionRequested) {
            completeTask(requestedSuccess, requestedReason);
            return;
        }
        if (!queue.isProcessing && queue.currentItem == nil &&
            ![ServerTranscriptionManager shared].isProcessing &&
            !ChapterGenerator.shared.hasActiveOpenAIBackgroundCancellationWork) {
            continuedTask.progress.completedUnitCount = continuedTask.progress.totalUnitCount;
            completeTask(YES, @"queue-completed");
        }
    }];

    cancellationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"ICOpenAIBackgroundCancellationWorkDidChangeNotification"
                                                                               object:nil
                                                                                queue:[NSOperationQueue mainQueue]
                                                                           usingBlock:^(__unused NSNotification *note) {
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        if (!queue.isProcessing && queue.currentItem == nil &&
            ![ServerTranscriptionManager shared].isProcessing &&
            !ChapterGenerator.shared.hasActiveOpenAIBackgroundCancellationWork) {
            continuedTask.progress.completedUnitCount = continuedTask.progress.totalUnitCount;
            completeTask(YES, @"remote-cancellation-reconciled");
        }
    }];

    [[TranscriptionQueue shared] resumeIfNeeded];
    TranscriptionQueue* queue = [TranscriptionQueue shared];
    if (!queue.isProcessing && queue.currentItem == nil &&
        ![ServerTranscriptionManager shared].isProcessing &&
        !ChapterGenerator.shared.hasActiveOpenAIBackgroundCancellationWork) {
        continuedTask.progress.completedUnitCount = continuedTask.progress.totalUnitCount;
        completeTask(YES, @"queue-empty");
    }
}




#pragma mark -
#pragma mark Application lifecycle


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    self.databaseStartupState = ICDatabaseStartupStateNotStarted;
    self.databasePreparationError = nil;
    self.pendingBackgroundURLSessionEvents = [NSMutableArray array];
    self.pendingApplicationOpenURLs = [NSMutableArray array];
    self.pendingTranscriptionBackgroundTasks = [NSMutableArray array];
    self.activeTranscriptionTaskExpirationHandlers = [NSMapTable strongToStrongObjectsMapTable];
    self.pendingDatabaseRemoteNotifications = [NSMutableArray array];
    self.pendingDatabaseFetchCompletionHandlers = [NSMutableArray array];
    self.pendingNotificationInteractions = [NSMutableArray array];
    self.handledNotificationResponseIdentifiers = [NSMutableSet set];
    self.pendingDatabaseSystemCallbacksBackgroundTask = UIBackgroundTaskInvalid;
    self.pendingDatabaseLaunchOptions = [launchOptions copy] ?: @{};
    self.databaseStartupDidBegin = NO;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_protectedDataDidBecomeAvailable:)
                                                 name:UIApplicationProtectedDataDidBecomeAvailable
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_automaticDownloadsDidBecomeReady:)
                                                 name:CacheManagerDidBecomeReadyForAutomaticDownloadsNotification
                                               object:nil];

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
    [[ICDiagnosticLogger shared] recordLifecycle:@"applicationDidFinishLaunching"
                                        metadata:@{
                                            @"launchOptionsCount": @(launchOptions.count),
                                        }];

    // One-shot canonicalisation of the stored theme colors. The read accessors are
    // pure, so this migration has to run explicitly.
    [UIColor ic_normalizeStoredColorInDefaults:USER_DEFAULTS hexKey:InterfaceThemeColorHexCode legacyArchiveKey:InterfaceThemeColorCode];
    [UIColor ic_normalizeStoredColorInDefaults:USER_DEFAULTS hexKey:PlayerThemeColorHexCode legacyArchiveKey:PlayerThemeColorCode];
    [UIColor ic_normalizeStoredColorInDefaults:USER_DEFAULTS hexKey:WidgetThemeColorHexCode legacyArchiveKey:WidgetThemeColorCode];

    [self _registerTranscriptionBackgroundTasks];

    if (!application.protectedDataAvailable) {
        self.databaseStartupState = ICDatabaseStartupStatePreparing;
        UIViewController* migrationViewController = [[UIViewController alloc] initWithNibName:@"DataMigrationView" bundle:nil];
        ICLocalizeViewText(migrationViewController.view);
        self.window.rootViewController = migrationViewController;
        [[ICDiagnosticLogger shared] logEvent:@"database"
                                      message:@"Datenbankstart wartet auf geschützte Daten"
                                     metadata:nil];
    }
    else {
        [self _beginDatabaseStartupWithLaunchOptions:self.pendingDatabaseLaunchOptions];
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

- (BOOL)_hasPendingNotificationBackgroundAction {
    for (NSDictionary* interaction in self.pendingNotificationInteractions) {
        if ([interaction[ICPendingNotificationInteractionActionKey] isEqualToString:@"play"]) {
            return YES;
        }
    }
    return NO;
}

- (void)_endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible {
    if (self.pendingBackgroundURLSessionEvents.count > 0 ||
        self.pendingDatabaseRemoteNotifications.count > 0 ||
        self.pendingDatabaseFetchCompletionHandlers.count > 0 ||
        [self _hasPendingNotificationBackgroundAction] ||
        self.pendingDatabaseSystemCallbacksBackgroundTask == UIBackgroundTaskInvalid) {
        return;
    }
    UIBackgroundTaskIdentifier identifier = self.pendingDatabaseSystemCallbacksBackgroundTask;
    self.pendingDatabaseSystemCallbacksBackgroundTask = UIBackgroundTaskInvalid;
    [App endBackgroundTask:identifier];
}

- (void)_completePendingDatabaseSystemCallbacksWithResult:(UIBackgroundFetchResult)result {
    NSArray<NSDictionary*>* sessionEvents = [self.pendingBackgroundURLSessionEvents copy];
    NSArray<NSDictionary*>* notifications = [self.pendingDatabaseRemoteNotifications copy];
    NSArray* fetchCompletionHandlers = [self.pendingDatabaseFetchCompletionHandlers copy];
    [self.pendingBackgroundURLSessionEvents removeAllObjects];
    [self.pendingDatabaseRemoteNotifications removeAllObjects];
    [self.pendingDatabaseFetchCompletionHandlers removeAllObjects];
    NSMutableArray<NSDictionary*>* retainedUIInteractions = [NSMutableArray array];
    for (NSDictionary* interaction in self.pendingNotificationInteractions) {
        if ([interaction[ICPendingNotificationInteractionActionKey] isEqualToString:UNNotificationDefaultActionIdentifier]) {
            [retainedUIInteractions addObject:interaction];
        }
    }
    self.pendingNotificationInteractions = retainedUIInteractions;
    [self _endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible];

    for (NSDictionary* event in sessionEvents) {
        void (^completionHandler)(void) = event[ICPendingBackgroundSessionCompletionKey];
        if (completionHandler) completionHandler();
    }
    for (NSDictionary* event in notifications) {
        void (^completionHandler)(UIBackgroundFetchResult) = event[ICPendingRemoteNotificationCompletionKey];
        if (completionHandler) completionHandler(result);
    }
    for (id storedHandler in fetchCompletionHandlers) {
        void (^completionHandler)(UIBackgroundFetchResult) = storedHandler;
        if (completionHandler) completionHandler(result);
    }
}

- (void)_expirePendingDatabaseSystemCallbacksBackgroundTaskForGeneration:(NSUInteger)generation {
    if (self.pendingDatabaseSystemCallbacksBackgroundTaskGeneration != generation ||
        self.pendingDatabaseSystemCallbacksBackgroundTask == UIBackgroundTaskInvalid) {
        return;
    }
    [self _completePendingDatabaseSystemCallbacksWithResult:UIBackgroundFetchResultFailed];
}

- (void)_beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded {
    if (self.pendingDatabaseSystemCallbacksBackgroundTask != UIBackgroundTaskInvalid) {
        return;
    }
    NSUInteger backgroundTaskGeneration = ++self.pendingDatabaseSystemCallbacksBackgroundTaskGeneration;
    __weak typeof(self) weakSelf = self;
    self.pendingDatabaseSystemCallbacksBackgroundTask = [App beginBackgroundTaskWithName:@"Database startup callbacks"
                                                                        expirationHandler:^{
        [weakSelf _expirePendingDatabaseSystemCallbacksBackgroundTaskForGeneration:backgroundTaskGeneration];
    }];
    if (self.pendingDatabaseSystemCallbacksBackgroundTask == UIBackgroundTaskInvalid) {
        [self _completePendingDatabaseSystemCallbacksWithResult:UIBackgroundFetchResultFailed];
    }
}

- (void)_failPendingDatabaseStartupWork {
    [self _completePendingDatabaseSystemCallbacksWithResult:UIBackgroundFetchResultFailed];
    [self.pendingNotificationInteractions removeAllObjects];

    for (BGTask* task in self.pendingTranscriptionBackgroundTasks) {
        task.expirationHandler = nil;
        [task setTaskCompletedWithSuccess:NO];
        [self _retireDeferredTranscriptionTaskOwnership:task reason:@"database-startup-failed"];
    }
    [self.pendingTranscriptionBackgroundTasks removeAllObjects];

}

- (void)_replayPendingNotificationInteractionsIfPossible
{
    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        return;
    }

    NSArray<NSDictionary*>* interactions = [self.pendingNotificationInteractions copy];
    NSMutableArray<NSDictionary*>* remainingInteractions = [NSMutableArray array];
    BOOL blockedByEarlierInteraction = NO;
    [self.pendingNotificationInteractions removeAllObjects];
    for (NSDictionary* interaction in interactions) {
        NSString* actionIdentifier = interaction[ICPendingNotificationInteractionActionKey];
        BOOL waitsForScene = [actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier] &&
                             !self.notificationSceneReady;
        if (blockedByEarlierInteraction || waitsForScene) {
            blockedByEarlierInteraction = YES;
            [remainingInteractions addObject:interaction];
            continue;
        }
        [self _performNotificationInteractionWithUserInfo:interaction[ICPendingNotificationInteractionUserInfoKey]
                                         actionIdentifier:actionIdentifier];
    }
    [self.pendingNotificationInteractions addObjectsFromArray:remainingInteractions];
    [self _endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible];
}

- (void)_replayPendingDatabaseStartupWork {
    NSArray<BGTask*>* tasks = [self.pendingTranscriptionBackgroundTasks copy];
    [self.pendingTranscriptionBackgroundTasks removeAllObjects];
    for (BGTask* task in tasks) {
        if ([task isKindOfClass:BGProcessingTask.class]) {
            [self _handleTranscriptionProcessingTask:(BGProcessingTask*)task];
        }
        else if (@available(iOS 26.0, *)) {
            if ([task isKindOfClass:BGContinuedProcessingTask.class]) {
                [self _handleTranscriptionContinuedProcessingTask:(BGContinuedProcessingTask*)task];
            }
            else {
                [task setTaskCompletedWithSuccess:NO];
            }
        }
        else {
            [task setTaskCompletedWithSuccess:NO];
        }
    }

    NSArray<NSDictionary*>* notifications = [self.pendingDatabaseRemoteNotifications copy];
    [self.pendingDatabaseRemoteNotifications removeAllObjects];
    for (NSDictionary* event in notifications) {
        NSDictionary* userInfo = event[ICPendingRemoteNotificationUserInfoKey];
        void (^completionHandler)(UIBackgroundFetchResult) = event[ICPendingRemoteNotificationCompletionKey];
        [self application:App didReceiveRemoteNotification:userInfo fetchCompletionHandler:completionHandler];
    }

    NSArray* fetchCompletionHandlers = [self.pendingDatabaseFetchCompletionHandlers copy];
    [self.pendingDatabaseFetchCompletionHandlers removeAllObjects];
    for (id storedHandler in fetchCompletionHandlers) {
        void (^completionHandler)(UIBackgroundFetchResult) = storedHandler;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [self application:App performFetchWithCompletionHandler:completionHandler];
#pragma clang diagnostic pop
    }

    [self _replayPendingNotificationInteractionsIfPossible];
    [self _endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible];
}

- (void)_protectedDataDidBecomeAvailable:(NSNotification *)notification
{
    if (!self.databaseStartupDidBegin && self.pendingDatabaseLaunchOptions) {
        [self _beginDatabaseStartupWithLaunchOptions:self.pendingDatabaseLaunchOptions];
    }
    if (self.mainViewController) {
        [InstacastBackupImporter resumePendingBookmarkImportIfNeeded];
        [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
    }
}

- (void)_automaticDownloadsDidBecomeReady:(NSNotification*)notification
{
    (void)notification;
    [self _recoverPendingAutoDownloadsIfReady];
}

- (void)_recoverPendingAutoDownloadsIfReady
{
    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        return;
    }
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    if (!cacheManager.isReadyForAutomaticDownloads) {
        return;
    }
    [[SubscriptionManager sharedSubscriptionManager] recoverPendingAutoDownloadsAfterDatabaseStartup];
}

- (void)_beginDatabaseStartupWithLaunchOptions:(NSDictionary *)launchOptions
{
    if (self.databaseStartupDidBegin || !App.protectedDataAvailable) {
        return;
    }
    self.databaseStartupDidBegin = YES;
    self.pendingDatabaseLaunchOptions = nil;

    if ([DatabaseManager dataStoreNeedsMigration]) {
        self.databaseStartupState = ICDatabaseStartupStatePreparing;
        UIViewController* migrationViewController = [[UIViewController alloc] initWithNibName:@"DataMigrationView" bundle:nil];
        ICLocalizeViewText(migrationViewController.view);
        self.window.rootViewController = migrationViewController;
        __weak typeof(self) weakSelf = self;
        [DatabaseManager prepareDataStoreMigrationWithCompletion:^(NSError* error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            if (error) {
                self.databaseStartupState = ICDatabaseStartupStateFailed;
                self.databasePreparationError = error;
                [[NSNotificationCenter defaultCenter] postNotificationName:InstacastDatabaseStartupDidFailNotification
                                                                    object:error];
                [[ICDiagnosticLogger shared] logEvent:@"database"
                                              message:@"Lokale Datenbank konnte nicht vorbereitet werden"
                                             metadata:@{ @"error": error.description ?: @"" }];
                [self _failPendingDatabaseStartupWork];
                if (self.window) {
                    self.window.rootViewController = [InstacastAppDelegate databaseUnavailableViewControllerForError:error];
                    [self.window makeKeyAndVisible];
                }
                return;
            }
            [self _startUpApplicationWithLaunchOptions:launchOptions];
        }];
    }
    else {
        [self _startUpApplicationWithLaunchOptions:launchOptions];
    }
}

- (void) _startUpApplicationWithLaunchOptions:(NSDictionary *)launchOptions
{
    DatabaseManager* databaseManager = [DatabaseManager sharedDatabaseManager];
    if (databaseManager.initializationError) {
        [[ICDiagnosticLogger shared] logEvent:@"database"
                                      message:@"Lokale Datenbank konnte beim Start nicht geöffnet werden"
                                     metadata:@{ @"error": databaseManager.initializationError.description ?: @"" }];
        self.databaseStartupState = ICDatabaseStartupStateFailed;
        self.databasePreparationError = databaseManager.initializationError;
        [[NSNotificationCenter defaultCenter] postNotificationName:InstacastDatabaseStartupDidFailNotification
                                                            object:databaseManager.initializationError];
        [self _failPendingDatabaseStartupWork];
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
    // The snapshot counts indexed iCloud rows through DatabaseManager on a detached task.
    // Start it only after the main-thread store initialization/migration has completed; doing
    // this from didFinishLaunching raced the lazy persistent container and opened it twice.
    if (@available(iOS 17.0, *)) {
        [ICiCloudSyncManager logSyncMetadataStorageSnapshot:@"launch"];
    }
    [InstacastBackupImporter resumePendingBookmarkImportIfNeeded];
    [InstacastBackupImporter startDeferredRestoreRecovery];
    if (self.pendingBackupFileURL) {
        [self.mainViewController openBackupFileURL:self.pendingBackupFileURL];
        self.pendingBackupFileURL = nil;
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

    self.databasePreparationError = nil;
    self.databaseStartupState = ICDatabaseStartupStateReady;
    [self _recoverPendingAutoDownloadsIfReady];
    [self _replayPendingDatabaseStartupWork];

    NSArray<NSDictionary*>* pendingSessionEvents = [self.pendingBackgroundURLSessionEvents copy];
    [self.pendingBackgroundURLSessionEvents removeAllObjects];
    for (NSDictionary* event in pendingSessionEvents) {
        NSString* identifier = event[ICPendingBackgroundSessionIdentifierKey];
        void (^completionHandler)(void) = event[ICPendingBackgroundSessionCompletionKey];
        [[CacheManager sharedCacheManager] handleEventsForBackgroundURLSession:identifier
                                                             completionHandler:completionHandler];
    }
    [self _endPendingDatabaseSystemCallbacksBackgroundTaskIfPossible];

    NSArray<NSDictionary*>* pendingOpenURLs = [self.pendingApplicationOpenURLs copy];
    [self.pendingApplicationOpenURLs removeAllObjects];
    for (NSDictionary* pendingURL in pendingOpenURLs) {
        [self application:App openURL:pendingURL[@"url"] options:pendingURL[@"options"] ?: @{}];
    }

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([launchOptions objectForKey:UIApplicationLaunchOptionsLocalNotificationKey]) {
        UILocalNotification* notification = [launchOptions objectForKey:UIApplicationLaunchOptionsLocalNotificationKey];
        [self application:App didReceiveLocalNotification:notification];
    }
    #pragma clang diagnostic pop

    [[NSNotificationCenter defaultCenter] postNotificationName:InstacastMainViewControllerDidBecomeReadyNotification
                                                        object:self.mainViewController];
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

    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        if (self.databaseStartupState == ICDatabaseStartupStateFailed) {
            return NO;
        }
        if (!self.pendingApplicationOpenURLs) {
            self.pendingApplicationOpenURLs = [NSMutableArray array];
        }
        [self.pendingApplicationOpenURLs addObject:@{ @"url": url, @"options": options ?: @{} }];
        return YES;
    }

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
    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        [[ICDiagnosticLogger shared] recordLifecycle:@"applicationDidEnterBackground"
                                            metadata:@{ @"databaseStartupState": @(self.databaseStartupState) }];
        return;
    }
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
    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        return;
    }
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
    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        if (self.databaseStartupState == ICDatabaseStartupStateFailed) {
            handler(UIBackgroundFetchResultFailed);
        }
        else {
            [self.pendingDatabaseRemoteNotifications addObject:@{
                ICPendingRemoteNotificationUserInfoKey: userInfo ?: @{},
                ICPendingRemoteNotificationCompletionKey: [handler copy],
            }];
            [self _beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded];
        }
        return;
    }
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

- (void)_performNotificationInteractionWithUserInfo:(NSDictionary*)userInfo
                                   actionIdentifier:(NSString*)actionIdentifier
{
    NSDictionary* aps = [userInfo[@"aps"] isKindOfClass:NSDictionary.class] ? userInfo[@"aps"] : nil;
    id topLevelEpisodeHash = userInfo[@"episode_hash"];
    id nestedEpisodeHash = aps[@"episode_hash"];
    NSString* episodeHash = [topLevelEpisodeHash isKindOfClass:NSString.class]
        ? topLevelEpisodeHash
        : ([nestedEpisodeHash isKindOfClass:NSString.class] ? nestedEpisodeHash : nil);
    if (episodeHash.length == 0) {
        return;
    }

    CDEpisode* episode = [DMANAGER episodeWithObjectHash:episodeHash];
    if (!episode) {
        return;
    }
    if ([actionIdentifier isEqualToString:@"play"]) {
        [[AudioSession sharedAudioSession] playEpisode:episode];
    }
    else if ([actionIdentifier isEqualToString:UNNotificationDefaultActionIdentifier]) {
        [self.mainViewController showShowNotesOfEpisode:episode animated:NO];
    }
}

- (void)_enqueueNotificationInteractionWithUserInfo:(NSDictionary*)userInfo
                                   actionIdentifier:(NSString*)actionIdentifier
{
    NSDictionary* immutableUserInfo = [userInfo copy] ?: @{};
    NSString* immutableAction = [actionIdentifier copy] ?: UNNotificationDefaultActionIdentifier;
    BOOL requiresReadyScene = [immutableAction isEqualToString:UNNotificationDefaultActionIdentifier];
    if (self.databaseStartupState == ICDatabaseStartupStateReady &&
        self.pendingNotificationInteractions.count == 0 &&
        (!requiresReadyScene || self.notificationSceneReady)) {
        [self _performNotificationInteractionWithUserInfo:immutableUserInfo actionIdentifier:immutableAction];
        return;
    }
    if (self.databaseStartupState == ICDatabaseStartupStateFailed) {
        return;
    }
    if (!self.pendingNotificationInteractions) {
        self.pendingNotificationInteractions = [NSMutableArray array];
    }
    [self.pendingNotificationInteractions addObject:@{
        ICPendingNotificationInteractionUserInfoKey: immutableUserInfo,
        ICPendingNotificationInteractionActionKey: immutableAction,
    }];
    if ([immutableAction isEqualToString:@"play"]) {
        [self _beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded];
    }
}

- (void)setNotificationSceneReady:(BOOL)ready
{
    _notificationSceneReady = ready;
    if (ready) {
        [self _replayPendingNotificationInteractionsIfPossible];
    }
}

- (void)handleNotificationResponse:(UNNotificationResponse*)response
                 completionHandler:(void (^)(void))completionHandler
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self handleNotificationResponse:response completionHandler:completionHandler];
        });
        return;
    }

    NSString* actionIdentifier = response.actionIdentifier;
    if (!response || [actionIdentifier isEqualToString:UNNotificationDismissActionIdentifier]) {
        if (completionHandler) completionHandler();
        return;
    }

    UNNotificationRequest* request = response.notification.request;
    NSString* requestIdentifier = request.identifier;
    NSString* responseIdentifier = nil;
    if (requestIdentifier.length > 0) {
        responseIdentifier = [NSString stringWithFormat:@"%@|%.6f|%@",
                              requestIdentifier,
                              response.notification.date.timeIntervalSince1970,
                              actionIdentifier ?: @""];
    }
    if (responseIdentifier.length > 0 &&
        [self.handledNotificationResponseIdentifiers containsObject:responseIdentifier]) {
        if (completionHandler) completionHandler();
        return;
    }
    if (responseIdentifier.length > 0) {
        [self.handledNotificationResponseIdentifiers addObject:responseIdentifier];
    }

    [self _enqueueNotificationInteractionWithUserInfo:request.content.userInfo
                                     actionIdentifier:actionIdentifier];
    if (completionHandler) completionHandler();
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler
{
    [self handleNotificationResponse:response completionHandler:completionHandler];
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

    [self _enqueueNotificationInteractionWithUserInfo:notification.userInfo
                                     actionIdentifier:UNNotificationDefaultActionIdentifier];

    [application cancelLocalNotification:notification];
}
#pragma clang diagnostic pop

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)application:(UIApplication *)application handleActionWithIdentifier:(NSString *)identifier forLocalNotification:(UILocalNotification *)localNotification completionHandler:(void (^)(void))completionHandler
{
    [self _enqueueNotificationInteractionWithUserInfo:localNotification.userInfo
                                     actionIdentifier:identifier];

    completionHandler();
}
#pragma clang diagnostic pop

#pragma mark - Background Fetch

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler
{
    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        if (self.databaseStartupState == ICDatabaseStartupStateFailed) {
            completionHandler();
        }
        else {
            if (!self.pendingBackgroundURLSessionEvents) {
                self.pendingBackgroundURLSessionEvents = [NSMutableArray array];
            }
            [self.pendingBackgroundURLSessionEvents addObject:@{
                ICPendingBackgroundSessionIdentifierKey: identifier ?: @"",
                ICPendingBackgroundSessionCompletionKey: [completionHandler copy],
            }];
            [self _beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded];
        }
        return;
    }
    [[CacheManager sharedCacheManager] handleEventsForBackgroundURLSession:identifier completionHandler:completionHandler];
}

- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler
{
    if (self.databaseStartupState != ICDatabaseStartupStateReady) {
        if (self.databaseStartupState == ICDatabaseStartupStateFailed) {
            completionHandler(UIBackgroundFetchResultFailed);
        }
        else {
            [self.pendingDatabaseFetchCompletionHandlers addObject:[completionHandler copy]];
            [self _beginPendingDatabaseSystemCallbacksBackgroundTaskIfNeeded];
        }
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SubscriptionManager* subscriptionManager = [SubscriptionManager sharedSubscriptionManager];
        if (![subscriptionManager canRefreshFeedsOnCurrentNetwork]) {
            completionHandler(UIBackgroundFetchResultFailed);
            return;
        }

        NSArray<CDFeed*>* subscriptions = [DMANAGER visibleFeeds];
        NSDictionary* savedAttempts = [USER_DEFAULTS dictionaryForKey:ICBackgroundFeedRefreshAttemptsKey];
        NSMutableDictionary<NSString*, NSNumber*>* backgroundRefreshAttempts = [savedAttempts mutableCopy] ?: [NSMutableDictionary dictionary];
        NSMutableSet<NSString*>* currentFeedIdentifiers = [NSMutableSet setWithCapacity:subscriptions.count];
        NSMutableArray<CDFeed*>* refreshCandidates = [NSMutableArray arrayWithCapacity:subscriptions.count];
        for (CDFeed* feed in subscriptions) {
            if (feed.parked || feed.uid.length == 0) {
                continue;
            }
            [currentFeedIdentifiers addObject:feed.uid];
            [refreshCandidates addObject:feed];
        }
        for (NSString* feedIdentifier in [backgroundRefreshAttempts.allKeys copy]) {
            if (![currentFeedIdentifiers containsObject:feedIdentifier]) {
                [backgroundRefreshAttempts removeObjectForKey:feedIdentifier];
            }
        }
        [refreshCandidates sortUsingComparator:^NSComparisonResult(CDFeed* left, CDFeed* right) {
            NSNumber* leftAttempt = backgroundRefreshAttempts[left.uid] ?: @0;
            NSNumber* rightAttempt = backgroundRefreshAttempts[right.uid] ?: @0;
            NSComparisonResult attemptOrder = [leftAttempt compare:rightAttempt];
            if (attemptOrder != NSOrderedSame) {
                return attemptOrder;
            }
            NSComparisonResult updateOrder = [(left.lastUpdate ?: [NSDate distantPast]) compare:(right.lastUpdate ?: [NSDate distantPast])];
            if (updateOrder != NSOrderedSame) {
                return updateOrder;
            }
            return [left.uid compare:right.uid];
        }];

        NSUInteger batchCount = MIN(ICBackgroundFeedRefreshBatchSize, refreshCandidates.count);
        NSArray<CDFeed*>* selectedSubscriptions = [refreshCandidates subarrayWithRange:NSMakeRange(0, batchCount)];
        NSNumber* attemptDate = @([NSDate date].timeIntervalSince1970);
        for (CDFeed* feed in selectedSubscriptions) {
            backgroundRefreshAttempts[feed.uid] = attemptDate;
        }
        [USER_DEFAULTS setObject:backgroundRefreshAttempts forKey:ICBackgroundFeedRefreshAttemptsKey];

        if (selectedSubscriptions.count == 0) {
            completionHandler(UIBackgroundFetchResultNoData);
            return;
        }

        NSDate* startDate = [NSDate date];
        [subscriptionManager refreshFeeds:selectedSubscriptions
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
