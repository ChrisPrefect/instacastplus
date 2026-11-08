// E2E driver and low-frequency telemetry for the real simulator app.
// Calls production APIs; never replaces methods, account state or lifecycle notifications.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CloudKit/CloudKit.h>
#import <CoreData/CoreData.h>
#import <QuartzCore/QuartzCore.h>
#import "InstacastBackupParser.h"
#import "InstacastBackupImporter.h"
#import <mach/mach.h>
#import <sys/resource.h>
#import "PlaybackManager.h"
#import "PlaybackViewController.h"
@class CDEpisodeList;
#import "AudioSession.h"

@interface NSObject (ICStressAPI)
+ (id)sharedDatabaseManager;
+ (id)sharedSubscriptionManager;
+ (id)sharedCacheManager;
+ (id)sharedManager;
+ (id)shared;
- (id)episodeWithObjectHash:(NSString*)hash;
- (id)feedWithSourceURL:(NSURL*)url;
- (NSArray*)sortedEpisodes;
- (id)preferedMedium;
- (void)subscribeFeedWithURL:(NSURL*)url options:(NSInteger)options completion:(void(^)(id,NSError*))completion;
- (void)refreshFeeds:(NSArray*)feeds etagHandling:(BOOL)etag completion:(void(^)(BOOL,NSArray*,NSError*))completion;
- (void)importOPMLData:(NSData*)data completion:(void(^)(NSError*))completion progress:(void(^)(float))progress;
- (void)setBool:(BOOL)value forKey:(NSString*)key;
- (void)save;
- (BOOL)cacheEpisode:(id)episode overwriteCellularLock:(BOOL)cellular reportsFailureToUser:(BOOL)reports;
- (BOOL)episodeIsCached:(id)episode;
- (BOOL)isCachingEpisode:(id)episode;
- (double)cacheProgressForEpisode:(id)episode;
- (NSURL*)URLForCachedEpisode:(id)episode;
- (NSError*)downloadErrorForEpisode:(id)episode;
- (void)cancelCachingEpisode:(id)episode disableAutoDownload:(BOOL)disable;
- (void)pauseCachingEpisode:(id)episode;
- (void)resumeCachingEpisode:(id)episode;
- (void)removeCacheForEpisode:(id)episode automatic:(BOOL)automatic completion:(void(^)(NSError*))completion;
- (void)performManualSyncWithCompletion:(void(^)(NSError*))completion;
- (void)performBackgroundSyncWithCompletion:(void(^)(UIBackgroundFetchResult))completion;
- (void)setEpisodesSyncEnabled:(BOOL)enabled;
- (void)setSubscriptionsSyncEnabled:(BOOL)enabled;
- (NSArray*)crashLogMailAttachments;
- (BOOL)_selectMainSidebarListWithUID:(NSString*)uid;
@end

static NSString *directory, *phase = @"startup";
static NSMutableDictionary *operations;
static NSDictionary *runtimeState;
static NSNumber *accountStatus;
static NSString *accountError;
static double lastHeartbeat, maximumGap;
static UIApplicationState lastApplicationState;

static Class swiftClass(NSString *name) {
    return NSClassFromString(name) ?: NSClassFromString([@"InstacastPlus." stringByAppendingString:name]);
}

static void append(NSString *file, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    if (!data) return;
    NSString *path = [directory stringByAppendingPathComponent:file];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSData data] writeToFile:path atomically:YES];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile]; [handle writeData:data]; [handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [handle closeFile];
}

static NSDictionary *playerState(void) {
    PlaybackManager *manager = [NSClassFromString(@"PlaybackManager") playbackManager];
    AVPlayer *player = [manager valueForKey:@"player"];
    AudioSession *session = [NSClassFromString(@"AudioSession") sharedAudioSession];
    id sync = [swiftClass(@"ICiCloudSyncManager") sharedManager];
    return @{
        @"timestamp": @(NSDate.date.timeIntervalSince1970), @"phase": phase, @"pid": @(getpid()),
        @"applicationState": @(UIApplication.sharedApplication.applicationState),
        @"backgroundTimeRemaining": @(MIN(10000, UIApplication.sharedApplication.backgroundTimeRemaining)),
        @"ready": @(manager.ready), @"paused": @(manager.paused), @"failed": @(manager.failed),
        @"state": [manager valueForKey:@"state"], @"rate": @(player.rate), @"volume": @(player.volume),
        @"itemStatus": @(player.currentItem.status), @"time": @(manager.time), @"duration": @(manager.duration),
        @"episodeHash": [(id)manager.playingEpisode valueForKey:@"objectHash"] ?: @"",
        @"playbackError": manager.playbackError.description ?: @"",
        @"timer": [session sleepTimerDiagnosticsMetadata] ?: @{},
        @"heartbeatMaximumGapSeconds": @(maximumGap),
        @"iCloudStatus": [sync valueForKey:@"statusText"] ?: @"",
        @"iCloudSyncInProgress": [sync valueForKey:@"syncInProgress"] ?: @NO,
        @"accountStatus": accountStatus ?: @0, @"accountError": accountError ?: @"",
    };
}

static id episode(NSDictionary *request) {
    return [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] episodeWithObjectHash:request[@"hash"]];
}

static NSArray *feeds(NSDictionary *request) {
    id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
    if ([request[@"all"] boolValue]) return [database valueForKey:@"feeds"];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *url in request[@"urls"] ?: @[]) {
        id feed = [database feedWithSourceURL:[NSURL URLWithString:url]];
        if (feed) [result addObject:feed];
    }
    return result;
}

@interface ICLifecycleStressProbe : NSObject @end
@implementation ICLifecycleStressProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"LifecycleStress"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        operations = [NSMutableDictionary dictionary];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
        [defaults setBool:NO forKey:@"AutoCacheNewAudioEpisodes"];
        [defaults setBool:NO forKey:@"AutoCacheNewVideoEpisodes"];
        [defaults setBool:NO forKey:@"ScreenTimerAlwaysActive"];
        [defaults setBool:NO forKey:@"IntelligentSleepTimerAlwaysActive"];
        [defaults setBool:YES forKey:@"EnableStreamingOver3G"];
        for (NSString *name in @[@"UIApplicationDidEnterBackgroundNotification", @"UIApplicationDidBecomeActiveNotification", @"UIApplicationWillResignActiveNotification", @"UIApplicationWillEnterForegroundNotification", @"UIApplicationDidReceiveMemoryWarningNotification", @"SubscriptionManagerWillStartRefreshingFeedsNotification", @"SubscriptionManagerDidFinishRefreshingFeedsNotification", @"CacheManagerDidFinishCachingEpisodeNotification", @"CacheManagerDidFailCachingEpisodeNotification", @"AudioSessionSleepTimerDidExpireNotification"]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                append(@"events.jsonl", @{@"timestamp": @(NSDate.date.timeIntervalSince1970), @"phase": phase, @"event": note.name, @"applicationState": @(UIApplication.sharedApplication.applicationState)});
            }];
        }
        [[CKContainer containerWithIdentifier:@"iCloud.com.iteconomy.instacastplus"] accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ accountStatus = @(status); accountError = error.description; });
        }];
        lastHeartbeat = CACurrentMediaTime();
        lastApplicationState = UIApplication.sharedApplication.applicationState;
        NSTimer *heartbeat = [NSTimer timerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer) {
            double now = CACurrentMediaTime();
            UIApplicationState applicationState = UIApplication.sharedApplication.applicationState;
            // Suspension is expected; only continuous foreground gaps measure UI stalls.
            if (applicationState == UIApplicationStateActive && lastApplicationState == UIApplicationStateActive)
                maximumGap = MAX(maximumGap, now-lastHeartbeat);
            lastHeartbeat=now; lastApplicationState=applicationState;
            PlaybackManager *sampleManager=[NSClassFromString(@"PlaybackManager") playbackManager];
            AVPlayer *samplePlayer=[sampleManager valueForKey:@"player"];
            @synchronized (operations) {
                runtimeState=@{@"timestamp":@(NSDate.date.timeIntervalSince1970),@"phase":phase,
                    @"runLoopMode":NSRunLoop.currentRunLoop.currentMode ?: @"",
                    @"applicationState":@(UIApplication.sharedApplication.applicationState),
                    @"ready":@(sampleManager.ready),@"paused":@(sampleManager.paused),
                    @"state":[sampleManager valueForKey:@"state"],@"rate":@(samplePlayer.rate),
                    @"time":@(sampleManager.time),@"heartbeatMaximumGapSeconds":@(maximumGap)};
            }
            NSString *path = [directory stringByAppendingPathComponent:@"command.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data || ![(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:request[@"id"] forKey:@"id"];
            @try {
                NSString *action = request[@"action"];
                id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                id subscriptions = [NSClassFromString(@"SubscriptionManager") sharedSubscriptionManager];
                id cache = [NSClassFromString(@"CacheManager") sharedCacheManager];
                PlaybackManager *manager = [NSClassFromString(@"PlaybackManager") playbackManager];
                AudioSession *session = [NSClassFromString(@"AudioSession") sharedAudioSession];
                NSString *operation = request[@"operation"] ?: request[@"id"];
                if ([action isEqual:@"phase"]) { phase=request[@"name"]; maximumGap=0; lastHeartbeat=now; }
                else if ([action isEqual:@"subscribe"]) {
                    operations[operation]=@{@"done":@NO};
                    [subscriptions subscribeFeedWithURL:[NSURL URLWithString:request[@"url"]] options:0 completion:^(id feed,NSError *error) {
                        operations[operation]=@{@"done":@YES, @"error":error.description ?: @"", @"title":[feed valueForKey:@"title"] ?: @"", @"url":[[feed valueForKey:@"sourceURL"] absoluteString] ?: @""};
                    }];
                } else if ([action isEqual:@"refresh"]) {
                    operations[operation]=@{@"done":@NO};
                    [subscriptions refreshFeeds:feeds(request) etagHandling:[request[@"etag"] boolValue] completion:^(BOOL success,NSArray *added,NSError *error) {
                        operations[operation]=@{@"done":@YES, @"success":@(success), @"added":@(added.count), @"error":error.description ?: @""};
                    }];
                } else if ([action isEqual:@"import"]) {
                    operations[operation]=@{@"done":@NO};
                    NSData *opml=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"subscriptions.opml"]];
                    [subscriptions importOPMLData:opml completion:^(NSError *error) { operations[operation]=@{@"done":@YES,@"error":error.description ?: @""}; } progress:^(float progress) { operations[operation]=@{@"done":@NO,@"progress":@(progress)}; }];
                } else if ([action isEqual:@"episodes"]) {
                    NSMutableArray *result=[NSMutableArray array];
                    for (id feed in feeds(request)) {
                        NSArray *sorted=[feed sortedEpisodes];
                        for (id item in [sorted subarrayWithRange:NSMakeRange(0,MIN(sorted.count,[request[@"limit"] unsignedIntegerValue] ?: 3))]) {
                            [result addObject:@{@"hash":[item valueForKey:@"objectHash"] ?: @"",@"title":[item valueForKey:@"title"] ?: @"",@"feedTitle":[feed valueForKey:@"title"] ?: @"",@"url":[[[item preferedMedium] valueForKey:@"fileURL"] absoluteString] ?: @"",@"duration":[item valueForKey:@"duration"] ?: @0,@"cached":@([cache episodeIsCached:item])}];
                        }
                    }
                    reply[@"episodes"]=result;
                } else if ([action isEqual:@"automaticDownloads"]) {
                    for (id feed in feeds(request)) [feed setBool:[request[@"enabled"] boolValue] forKey:@"AutoCacheNewAudioEpisodes"];
                    [database save];
                } else if ([action isEqual:@"open"]) {
                    id item=episode(request); if (!item) @throw [NSException exceptionWithName:@"MissingEpisode" reason:request.description userInfo:nil];
                    UIViewController *root=[(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    if (!root.presentedViewController) {
                        PlaybackViewController *player=[NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:item];
                        [player presentFromParentViewController:root autostart:[request[@"autostart"] boolValue] completion:nil];
                    } else [session playEpisode:item queueUpCurrent:NO at:[request[@"time"] doubleValue] autostart:[request[@"autostart"] boolValue]];
                } else if ([action isEqual:@"play"]) [manager play];
                else if ([action isEqual:@"pause"]) [manager pause];
                else if ([action isEqual:@"close"]) [manager close];
                else if ([action isEqual:@"seek"]) [manager seekToTime:[request[@"time"] doubleValue]];
                else if ([action isEqual:@"sleep"]) [session setTimerWithDuration:[request[@"seconds"] doubleValue]];
                else if ([action isEqual:@"download"]) reply[@"accepted"]=@([cache cacheEpisode:episode(request) overwriteCellularLock:YES reportsFailureToUser:NO]);
                else if ([action isEqual:@"cancelDownload"]) [cache cancelCachingEpisode:episode(request) disableAutoDownload:NO];
                else if ([action isEqual:@"pauseDownload"]) [cache pauseCachingEpisode:episode(request)];
                else if ([action isEqual:@"resumeDownload"]) [cache resumeCachingEpisode:episode(request)];
                else if ([action isEqual:@"removeDownload"]) [cache removeCacheForEpisode:episode(request) automatic:NO completion:^(NSError *error) { operations[operation]=@{@"done":@YES,@"error":error.description ?: @""}; }];
                else if ([action isEqual:@"cloud"]) {
                    id cloud=[swiftClass(@"ICiCloudSyncManager") sharedManager];
                    operations[operation]=@{@"done":@NO};
                    // The test may exercise the real no-account path, never forge an identity.
                    if (accountStatus.integerValue != CKAccountStatusAvailable) {
                        [cloud setEpisodesSyncEnabled:YES]; [cloud setSubscriptionsSyncEnabled:YES];
                    }
                    if ([request[@"background"] boolValue]) [cloud performBackgroundSyncWithCompletion:^(UIBackgroundFetchResult result) { operations[operation]=@{@"done":@YES,@"result":@(result)}; }];
                    else [cloud performManualSyncWithCompletion:^(NSError *error) { operations[operation]=@{@"done":@YES,@"error":error.description ?: @""}; }];
                } else if ([action isEqual:@"feedOrder"]) {
                    NSMutableArray *ordered=[NSMutableArray array];
                    for (id feed in [database valueForKey:@"feeds"]) {
                        [ordered addObject:@{@"url":[feed valueForKey:@"sourceURL_"] ?: @"",@"rank":[feed valueForKey:@"rank"]}];
                    }
                    reply[@"feedOrder"]=ordered;
                } else if ([action isEqual:@"backupRanks"]) {
                    operations[operation]=@{@"done":@NO};
                    NSData *xml=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"backup-ranks.xml"]];
                    [NSClassFromString(@"InstacastBackupParser") parseData:xml completion:^(InstacastBackupData *backup,NSError *error) {
                        if (error) {operations[operation]=@{@"done":@YES,@"error":error.description};return;}
                        ICBackupImportCallbacks callbacks={0};
                        ICBackupImportCategory categories=ICBackupImportFeedSettings;
                        if ([request[@"newPodcasts"] boolValue]) categories |= ICBackupImportNewPodcasts;
                        [NSClassFromString(@"InstacastBackupImporter") importBackup:backup categories:categories callbacks:callbacks completion:^(NSInteger count,NSInteger downloads,NSError *importError) {
                            operations[operation]=@{@"done":@YES,@"error":importError.description ?: @"",@"count":@(count)};
                        }];
                    }];
                } else if ([action isEqual:@"outbox"]) {
                    NSManagedObjectContext *mainContext=[database valueForKey:@"objectContext"];
                    NSManagedObjectContext *reader=[[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
                    reader.persistentStoreCoordinator=mainContext.persistentStoreCoordinator;
                    NSMutableDictionary *ranks=[NSMutableDictionary dictionary];
                    NSFetchRequest *feedRequest=[NSFetchRequest fetchRequestWithEntityName:@"Feed"];
                    feedRequest.predicate=[NSPredicate predicateWithFormat:@"sourceURL_ IN %@",request[@"urls"]];
                    for (NSManagedObject *feed in [reader executeFetchRequest:feedRequest error:nil]) ranks[[feed valueForKey:@"sourceURL_"]]=[feed valueForKey:@"rank"];
                    NSMutableArray *rows=[NSMutableArray array];
                    NSFetchRequest *fetch=[NSFetchRequest fetchRequestWithEntityName:@"ICCloudSyncOutboxEntry"];
                    fetch.predicate=[NSPredicate predicateWithFormat:@"recordName IN %@",request[@"recordNames"]];
                    NSError *readError=nil;
                    for (NSManagedObject *entry in [reader executeFetchRequest:fetch error:&readError]) {
                        NSDictionary *payload=[NSPropertyListSerialization propertyListWithData:[entry valueForKey:@"payloadData"] options:NSPropertyListImmutable format:nil error:nil];
                        [rows addObject:@{@"recordName":[entry valueForKey:@"recordName"],@"operation":[entry valueForKey:@"operation"],
                            @"category":[entry valueForKey:@"category"],@"revision":[entry valueForKey:@"revision"],
                            @"accountRecordName":[entry valueForKey:@"accountRecordName"],@"acknowledged":[entry valueForKey:@"acknowledged"],
                            @"changedAt":@([[entry valueForKey:@"changedAt"] timeIntervalSince1970]),
                            @"feedURL":payload[@"feedURL"] ?: @"",@"propertiesArrayPresent":@([payload[@"properties"] isKindOfClass:NSArray.class]),
                            @"payloadRank":payload[@"rank"] ?: NSNull.null,@"savedRank":ranks[payload[@"feedURL"]] ?: NSNull.null}];
                    }
                    if (readError) @throw [NSException exceptionWithName:@"OutboxRead" reason:readError.description userInfo:nil];
                    reply[@"outboxEntries"]=rows;
                } else if ([action isEqual:@"openList"]) {
                    id root=[(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    UIViewController *presented=[root presentedViewController];
                    if (presented) [presented dismissViewControllerAnimated:NO completion:nil];
                    reply[@"opened"]=@([root _selectMainSidebarListWithUID:@"default.unplayed"]);
                } else if ([action isEqual:@"exportLogs"]) {
                    NSArray *attachments=[[swiftClass(@"ICDiagnosticLogger") shared] crashLogMailAttachments];
                    [[attachments.firstObject valueForKey:@"data"] writeToFile:[directory stringByAppendingPathComponent:@"export.txt"] atomically:YES];
                }
                id item=request[@"hash"] ? episode(request) : nil;
                if (item) reply[@"download"]=@{@"cached":@([cache episodeIsCached:item]),@"caching":@([cache isCachingEpisode:item]),@"progress":@([cache cacheProgressForEpisode:item]),@"error":[cache downloadErrorForEpisode:item].description ?: @"",@"path":[cache URLForCachedEpisode:item].path ?: @""};
                if ([request[@"details"] boolValue]) {
                    NSManagedObjectContext *context=[database valueForKey:@"objectContext"];
                    reply[@"feedCount"]=@([context countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Feed"] error:nil]);
                    reply[@"episodeCount"]=@([context countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Episode"] error:nil]);
                }
                reply[@"operations"]=[operations copy]; reply[@"state"]=playerState();
                reply[@"refreshing"]=[subscriptions valueForKey:@"refreshing"] ?: @NO;
            } @catch (NSException *exception) { reply[@"error"]=exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
        // Tracking gestures use UITrackingRunLoopMode. A default-mode timer
        // pauses there even when the UI is healthy, falsely reporting a stall.
        [NSRunLoop.mainRunLoop addTimer:heartbeat forMode:NSRunLoopCommonModes];
        dispatch_queue_t telemetry=dispatch_queue_create("ICStressTelemetry",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,telemetry);
        dispatch_source_set_timer(source,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,NSEC_PER_SEC/10);
        dispatch_source_set_event_handler(source, ^{
            struct rusage usage; getrusage(RUSAGE_SELF,&usage);
            task_vm_info_data_t vm={0}; mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
            task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&count);
            NSDictionary *state;
            @synchronized (operations) { state=runtimeState ?: @{}; }
            append(@"telemetry.jsonl", @{@"timestamp":@(NSDate.date.timeIntervalSince1970),@"cpuSeconds":@(usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6),@"footprintBytes":@(vm.phys_footprint),@"residentBytes":@(vm.resident_size),@"thermalState":@(NSProcessInfo.processInfo.thermalState),@"lowPowerMode":@(NSProcessInfo.processInfo.lowPowerModeEnabled),@"state":state});
        });
        dispatch_resume(source);
        // Retain the timer for the injected driver's lifetime.
        static dispatch_source_t retained; retained=source;
    });
}
@end
