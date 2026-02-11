//
//  ICCloudSyncManager.m
//  Instacast
//

#import "ICCloudSyncManager.h"
#import "ICCloudSyncSubscriptionHandler.h"
#import "ICCloudSyncPlaybackHandler.h"
#import "ICCloudSyncNowPlayingHandler.h"
#import "ICCloudSyncFeedSettingsHandler.h"
#import "ICCloudSyncAppSettingsHandler.h"
#import "ICCloudSyncDownloadHandler.h"
#import "ICCloudSyncListHandler.h"
#import "ICCloudSyncUpNextHandler.h"
#import "PlaybackManager.h"

NSString *ICCloudSyncManagerDidSyncNotification = @"ICCloudSyncManagerDidSyncNotification";
NSString *ICCloudSyncManagerDidUpdateDevicesNotification = @"ICCloudSyncManagerDidUpdateDevicesNotification";
NSString *ICCloudSyncManagerDidUpdateProgressNotification = @"ICCloudSyncManagerDidUpdateProgressNotification";
NSString *ICCloudSyncManagerShouldStartNotification = @"ICCloudSyncManagerShouldStartNotification";
NSString *ICCloudSyncManagerShouldStopNotification = @"ICCloudSyncManagerShouldStopNotification";
NSString *ICCloudSyncManagerSyncNowNotification = @"ICCloudSyncManagerSyncNowNotification";
NSString *ICCloudSyncManagerResetNotification = @"ICCloudSyncManagerResetNotification";
NSString *ICDatabaseDidSaveWithSyncNotification = @"ICDatabaseDidSaveWithSyncNotification";

static NSString * const kSyncZoneName = @"InstacastSyncZone";
static NSString * const kSubscriptionID = @"InstacastSyncSubscription";

@interface ICCloudSyncManager ()
@property (nonatomic, strong) CKContainer *container;
@property (nonatomic, strong) CKDatabase *privateDatabase;
@property (nonatomic, strong) CKRecordZoneID *syncZoneID;
@property (nonatomic, assign) BOOL isSyncing;
@property (nonatomic, assign) BOOL isStarted;
@property (nonatomic, assign) NSInteger syncProgressCompleted;
@property (nonatomic, assign) NSInteger syncProgressTotal;
@property (nonatomic, strong) NSMutableArray<id<ICCloudSyncHandler>> *handlers;
@property (nonatomic, strong) NSMutableArray<ICCloudSyncDeviceInfo *> *mutableDevices;
@property (nonatomic, strong) NSTimer *debounceTimer;
@property (nonatomic, assign) BOOL zoneCreated;
@property (nonatomic, assign) BOOL subscriptionCreated;
@property (nonatomic, strong) ICCloudSyncNowPlayingHandler *nowPlayingHandler;
@property (nonatomic, strong) ICCloudSyncUpNextHandler *upNextHandler;
@property (nonatomic, assign) BOOL hasPendingPush;
@property (nonatomic, assign) BOOL hasPendingFetch;
@end

@implementation ICCloudSyncManager

+ (ICCloudSyncManager *)sharedManager
{
    static ICCloudSyncManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[ICCloudSyncManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _container = [CKContainer containerWithIdentifier:@"iCloud.com.vemedio.instacast"];
        _privateDatabase = _container.privateCloudDatabase;
        _syncZoneID = [[CKRecordZoneID alloc] initWithZoneName:kSyncZoneName ownerName:CKCurrentUserDefaultName];
        _handlers = [NSMutableArray array];
        _mutableDevices = [NSMutableArray array];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleShouldStart) name:ICCloudSyncManagerShouldStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleShouldStop) name:ICCloudSyncManagerShouldStopNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleSyncNow) name:ICCloudSyncManagerSyncNowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleReset) name:ICCloudSyncManagerResetNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleDatabaseSave:) name:ICDatabaseDidSaveWithSyncNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAccountChange) name:CKAccountChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAppBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handlePlaybackEnded:) name:PlaybackManagerDidEndNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_debounceTimer invalidate];
}

- (NSArray<ICCloudSyncDeviceInfo *> *)devices
{
    return [self.mutableDevices copy];
}

#pragma mark - Lifecycle

- (void)start
{
    if (self.isStarted) return;
    self.isStarted = YES;

    DebugLog(@"[iCloudSync] Starting...");

    // Register handlers if not yet done
    if (self.handlers.count == 0) {
        [self setupHandlers];
    }

    [self checkAccountStatus:^(BOOL available) {
        if (!available) {
            ErrLog(@"[iCloudSync] iCloud account not available");
            self.isStarted = NO;
            return;
        }

        [self ensureZoneExists:^{
                [self ensureSubscriptionExists:^{
                    [self registerDevice];
                    [self.nowPlayingHandler startObserving];
                    [self.upNextHandler startObserving];
                    if ([PlaybackManager playbackManager].playingEpisode) {
                        self.hasPendingFetch = YES;
                    } else {
                        [self fetchChanges];
                    }
                }];
            }];
        }];
}

- (void)setupHandlers
{
    ICCloudSyncSubscriptionHandler *subHandler = [[ICCloudSyncSubscriptionHandler alloc] init];
    subHandler.database = self.privateDatabase;
    subHandler.zoneID = self.syncZoneID;
    [self registerHandler:subHandler];

    ICCloudSyncPlaybackHandler *pbHandler = [[ICCloudSyncPlaybackHandler alloc] init];
    pbHandler.database = self.privateDatabase;
    pbHandler.zoneID = self.syncZoneID;
    [self registerHandler:pbHandler];

    ICCloudSyncNowPlayingHandler *npHandler = [[ICCloudSyncNowPlayingHandler alloc] init];
    npHandler.database = self.privateDatabase;
    npHandler.zoneID = self.syncZoneID;
    self.nowPlayingHandler = npHandler;
    [self registerHandler:npHandler];

    ICCloudSyncFeedSettingsHandler *fsHandler = [[ICCloudSyncFeedSettingsHandler alloc] init];
    fsHandler.database = self.privateDatabase;
    fsHandler.zoneID = self.syncZoneID;
    [self registerHandler:fsHandler];

    ICCloudSyncAppSettingsHandler *asHandler = [[ICCloudSyncAppSettingsHandler alloc] init];
    asHandler.database = self.privateDatabase;
    asHandler.zoneID = self.syncZoneID;
    [self registerHandler:asHandler];

    ICCloudSyncDownloadHandler *dlHandler = [[ICCloudSyncDownloadHandler alloc] init];
    dlHandler.database = self.privateDatabase;
    dlHandler.zoneID = self.syncZoneID;
    [self registerHandler:dlHandler];

    ICCloudSyncListHandler *listHandler = [[ICCloudSyncListHandler alloc] init];
    listHandler.database = self.privateDatabase;
    listHandler.zoneID = self.syncZoneID;
    [self registerHandler:listHandler];

    ICCloudSyncUpNextHandler *upNextHandler = [[ICCloudSyncUpNextHandler alloc] init];
    upNextHandler.database = self.privateDatabase;
    upNextHandler.zoneID = self.syncZoneID;
    self.upNextHandler = upNextHandler;
    [self registerHandler:upNextHandler];
}

- (void)stop
{
    DebugLog(@"[iCloudSync] Stopping...");
    self.isStarted = NO;
    [self.debounceTimer invalidate];
    self.debounceTimer = nil;
    [self.nowPlayingHandler stopObserving];
    [self.upNextHandler stopObserving];
}

- (void)syncNow
{
    if (!self.isStarted) return;
    if (self.isSyncing) return;
    DebugLog(@"[iCloudSync] Manual sync triggered");
    [self pushAllChangesWithCompletion:^{
        [self fetchChanges];
    }];
}

- (void)registerHandler:(id<ICCloudSyncHandler>)handler
{
    [self.handlers addObject:handler];
}

#pragma mark - Notification Handlers

- (void)handleShouldStart
{
    [self start];
}

- (void)handleShouldStop
{
    [self stop];
}

- (void)handleSyncNow
{
    [self syncNow];
}

- (void)handleReset
{
    [self stop];

    CKRecordZone *zone = [[CKRecordZone alloc] initWithZoneID:self.syncZoneID];
    CKModifyRecordZonesOperation *op = [[CKModifyRecordZonesOperation alloc] initWithRecordZonesToSave:nil recordZoneIDsToDelete:@[zone.zoneID]];
    op.modifyRecordZonesCompletionBlock = ^(NSArray<CKRecordZone *> *savedZones, NSArray<CKRecordZoneID *> *deletedZoneIDs, NSError *error) {
        if (error) {
            ErrLog(@"[iCloudSync] Failed to delete zone: %@", error);
        } else {
            DebugLog(@"[iCloudSync] Zone deleted successfully");
        }
        self.zoneCreated = NO;
        self.subscriptionCreated = NO;
    };
    [self.privateDatabase addOperation:op];
}

- (void)handleDatabaseSave:(NSNotification *)notification
{
    if (!self.isStarted || !_zoneCreated) return;
    self.hasPendingPush = YES;

    // Avoid expensive initial "catch-up" push while startup fetch is still establishing last sync baseline.
    NSDate *lastSync = [USER_DEFAULTS objectForKey:iCloudSyncLastSyncDate];
    if (!lastSync) return;

    // Keep all non-manual pushes off the active UI/player path.
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        return;
    }
    if (self.isSyncing) return;

    // Debounce: wait 2 seconds before pushing
    [self.debounceTimer invalidate];
    self.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(debouncedPush) userInfo:nil repeats:NO];
}

- (void)debouncedPush
{
    if (!self.hasPendingPush) {
        return;
    }

    // Never compete with active player interactions on the main thread.
    if ([PlaybackManager playbackManager].playingEpisode) {
        [self.debounceTimer invalidate];
        self.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:15.0 target:self selector:@selector(debouncedPush) userInfo:nil repeats:NO];
        return;
    }

    self.hasPendingPush = NO;
    [self pushAllChangesWithCompletion:nil];
}

- (void)handleAccountChange
{
    [self checkAccountStatus:^(BOOL available) {
        if (available && [USER_DEFAULTS boolForKey:iCloudSyncEnabled]) {
            if (!self.isStarted) {
                [self start];
            }
        } else {
            [self stop];
        }
    }];
}

- (void)handleAppForeground
{
    if (self.isStarted) {
        if ([PlaybackManager playbackManager].playingEpisode) {
            self.hasPendingFetch = YES;
            return;
        }
        [self fetchChanges];
    }
}

- (void)handleAppBackground
{
    if (!self.isStarted || !self.zoneCreated) {
        return;
    }
    if (!self.hasPendingPush || self.isSyncing) {
        if (self.hasPendingFetch && ![PlaybackManager playbackManager].playingEpisode) {
            self.hasPendingFetch = NO;
            [self fetchChanges];
        }
        return;
    }
    [self.debounceTimer invalidate];
    self.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(debouncedPush) userInfo:nil repeats:NO];

    if (self.hasPendingFetch && ![PlaybackManager playbackManager].playingEpisode) {
        self.hasPendingFetch = NO;
        [self fetchChanges];
    }
}

- (void)handlePlaybackEnded:(NSNotification *)notification
{
    if (!self.isStarted || !self.hasPendingFetch) {
        return;
    }
    self.hasPendingFetch = NO;
    [self fetchChanges];
}

#pragma mark - Account Check

- (void)checkAccountStatus:(void(^)(BOOL available))completion
{
    [self.container accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL available = (status == CKAccountStatusAvailable);
            if (!available && error) {
                ErrLog(@"[iCloudSync] Account check error: %@", error);
            }
            completion(available);
        });
    }];
}

#pragma mark - Zone Setup

- (void)ensureZoneExists:(void(^)(void))completion
{
    if (self.zoneCreated) {
        completion();
        return;
    }

    CKRecordZone *zone = [[CKRecordZone alloc] initWithZoneID:self.syncZoneID];
    CKModifyRecordZonesOperation *op = [[CKModifyRecordZonesOperation alloc] initWithRecordZonesToSave:@[zone] recordZoneIDsToDelete:nil];
    op.qualityOfService = NSQualityOfServiceUtility;
    op.modifyRecordZonesCompletionBlock = ^(NSArray<CKRecordZone *> *savedZones, NSArray<CKRecordZoneID *> *deletedZoneIDs, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ErrLog(@"[iCloudSync] Failed to create zone: %@", error);
                NSNumber *retryAfter = error.userInfo[CKErrorRetryAfterKey];
                if (retryAfter.doubleValue > 0) {
                    NSTimeInterval delay = retryAfter.doubleValue;
                    DebugLog(@"[iCloudSync] Retrying zone creation in %.1f seconds", delay);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        if (!self.isStarted) {
                            return;
                        }
                        [self ensureZoneExists:completion];
                    });
                    return;
                }
                self.isStarted = NO;
                return;
            }
            DebugLog(@"[iCloudSync] Zone created/verified");
            self.zoneCreated = YES;
            completion();
        });
    };
    [self.privateDatabase addOperation:op];
}

#pragma mark - Subscription Setup

- (void)ensureSubscriptionExists:(void(^)(void))completion
{
    if (self.subscriptionCreated) {
        completion();
        return;
    }

    CKDatabaseSubscription *subscription = [[CKDatabaseSubscription alloc] initWithSubscriptionID:kSubscriptionID];

    CKNotificationInfo *notifInfo = [[CKNotificationInfo alloc] init];
    notifInfo.shouldSendContentAvailable = YES;
    subscription.notificationInfo = notifInfo;

    CKModifySubscriptionsOperation *op = [[CKModifySubscriptionsOperation alloc] initWithSubscriptionsToSave:@[subscription] subscriptionIDsToDelete:nil];
    op.qualityOfService = NSQualityOfServiceUtility;
    op.modifySubscriptionsCompletionBlock = ^(NSArray<CKSubscription *> *savedSubscriptions, NSArray<NSString *> *deletedSubscriptionIDs, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                // CKErrorServerRejectedRequest with "subscription already exists" is OK
                if (error.code == CKErrorServerRejectedRequest) {
                    DebugLog(@"[iCloudSync] Subscription already exists");
                } else {
                    ErrLog(@"[iCloudSync] Failed to create subscription: %@", error);
                }
            } else {
                DebugLog(@"[iCloudSync] Subscription created/verified");
            }
            self.subscriptionCreated = YES;
            completion();
        });
    };
    [self.privateDatabase addOperation:op];
}

#pragma mark - Device Registration

- (void)registerDevice
{
    ICCloudSyncDeviceInfo *device = [ICCloudSyncDeviceInfo currentDevice];
    CKRecord *record = [device toCKRecordInZone:self.syncZoneID];

    CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[record] recordIDsToDelete:nil];
    op.qualityOfService = NSQualityOfServiceUtility;
    op.savePolicy = CKRecordSaveAllKeys;
    op.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> *savedRecords, NSArray<CKRecordID *> *deletedRecordIDs, NSError *error) {
        if (error) {
            ErrLog(@"[iCloudSync] Device registration failed: %@", error);
        } else {
            DebugLog(@"[iCloudSync] Device registered: %@", device.deviceName);
        }
    };
    [self.privateDatabase addOperation:op];
}

#pragma mark - Push Changes

- (void)pushAllChangesWithCompletion:(void(^ _Nullable)(void))pushCompletion
{
    if (self.isSyncing) {
        if (pushCompletion) pushCompletion();
        return;
    }
    self.isSyncing = YES;

    DebugLog(@"[iCloudSync] Pushing changes...");

    // Count active handlers for progress
    NSInteger totalSteps = 1; // +1 for device record
    for (id<ICCloudSyncHandler> handler in self.handlers) {
        NSString *key = [self defaultsKeyForHandler:handler];
        if (key && ![USER_DEFAULTS boolForKey:key]) continue;
        totalSteps++;
    }
    self.syncProgressCompleted = 0;
    self.syncProgressTotal = totalSteps;
    [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidUpdateProgressNotification object:self];
    __block BOOL hadErrors = NO;

    dispatch_group_t group = dispatch_group_create();

    for (id<ICCloudSyncHandler> handler in self.handlers) {
        NSString *key = [self defaultsKeyForHandler:handler];
        if (key && ![USER_DEFAULTS boolForKey:key]) continue;

        dispatch_group_enter(group);
        [handler pushChangesWithCompletion:^(NSError *error) {
            if (error) {
                hadErrors = YES;
                ErrLog(@"[iCloudSync] Push error for %@: %@", [handler recordType], error);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                self.syncProgressCompleted++;
                [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidUpdateProgressNotification object:self];
            });
            dispatch_group_leave(group);
        }];
    }

    // Update device record
    dispatch_group_enter(group);
    ICCloudSyncDeviceInfo *device = [ICCloudSyncDeviceInfo currentDevice];
    CKRecord *deviceRecord = [device toCKRecordInZone:self.syncZoneID];
    CKModifyRecordsOperation *deviceOp = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[deviceRecord] recordIDsToDelete:nil];
    deviceOp.qualityOfService = NSQualityOfServiceUtility;
    deviceOp.savePolicy = CKRecordSaveAllKeys;
    deviceOp.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> *saved, NSArray<CKRecordID *> *deleted, NSError *error) {
        if (error) {
            hadErrors = YES;
            ErrLog(@"[iCloudSync] Device record push error: %@", error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.syncProgressCompleted++;
            [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidUpdateProgressNotification object:self];
        });
        dispatch_group_leave(group);
    };
    [self.privateDatabase addOperation:deviceOp];

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.isSyncing = NO;
        self.syncProgressCompleted = 0;
        self.syncProgressTotal = 0;
        if (!hadErrors) {
            [USER_DEFAULTS setObject:[NSDate date] forKey:iCloudSyncLastSyncDate];
            [USER_DEFAULTS synchronize];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidSyncNotification object:self];
        if (hadErrors) {
            DebugLog(@"[iCloudSync] Push finished with errors");
        } else {
            DebugLog(@"[iCloudSync] Push complete");
        }
        if (pushCompletion) pushCompletion();
    });
}

#pragma mark - Fetch Changes (Pull)

- (void)fetchChanges
{
    if (!self.isStarted || !self.zoneCreated) return;
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive && [PlaybackManager playbackManager].playingEpisode) {
        self.hasPendingFetch = YES;
        return;
    }

    DebugLog(@"[iCloudSync] Fetching changes...");

    // Restore saved server change token
    CKServerChangeToken *previousToken = nil;
    NSData *tokenData = [USER_DEFAULTS objectForKey:iCloudSyncServerChangeToken];
    if (tokenData) {
        previousToken = [NSKeyedUnarchiver unarchivedObjectOfClass:[CKServerChangeToken class] fromData:tokenData error:nil];
    }

    CKFetchRecordZoneChangesConfiguration *config = [[CKFetchRecordZoneChangesConfiguration alloc] init];
    config.previousServerChangeToken = previousToken;

    CKFetchRecordZoneChangesOperation *op = [[CKFetchRecordZoneChangesOperation alloc] initWithRecordZoneIDs:@[self.syncZoneID] configurationsByRecordZoneID:@{self.syncZoneID: config}];
    op.qualityOfService = NSQualityOfServiceUtility;

    NSMutableDictionary<NSString *, NSMutableArray<CKRecord *> *> *recordsByType = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<CKRecordID *> *> *deletionsByType = [NSMutableDictionary dictionary];

    op.recordChangedBlock = ^(CKRecord *record) {
        NSString *type = record.recordType;
        if (!recordsByType[type]) {
            recordsByType[type] = [NSMutableArray array];
        }
        [recordsByType[type] addObject:record];
    };

    op.recordWithIDWasDeletedBlock = ^(CKRecordID *recordID, CKRecordType recordType) {
        if (!deletionsByType[recordType]) {
            deletionsByType[recordType] = [NSMutableArray array];
        }
        [deletionsByType[recordType] addObject:recordID];
    };

    op.recordZoneChangeTokensUpdatedBlock = ^(CKRecordZoneID *zoneID, CKServerChangeToken *token, NSData *clientData) {
        if (token) {
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:token requiringSecureCoding:YES error:nil];
            [USER_DEFAULTS setObject:data forKey:iCloudSyncServerChangeToken];
        }
    };

    op.recordZoneFetchCompletionBlock = ^(CKRecordZoneID *zoneID, CKServerChangeToken *token, NSData *clientData, BOOL moreComing, NSError *error) {
        if (error) {
            if (error.code == CKErrorChangeTokenExpired) {
                DebugLog(@"[iCloudSync] Change token expired, resetting");
                [USER_DEFAULTS removeObjectForKey:iCloudSyncServerChangeToken];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self fetchChanges];
                });
                return;
            }
            ErrLog(@"[iCloudSync] Fetch error: %@", error);
            return;
        }

        if (token) {
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:token requiringSecureCoding:YES error:nil];
            [USER_DEFAULTS setObject:data forKey:iCloudSyncServerChangeToken];
        }
    };

    op.fetchRecordZoneChangesCompletionBlock = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ErrLog(@"[iCloudSync] Fetch completion error: %@", error);
                return;
            }

            // Dispatch received records to handlers
            [self dispatchReceivedRecords:recordsByType deletions:deletionsByType];

            // Handle device records (incremental = merge)
            NSArray<CKRecord *> *deviceRecords = recordsByType[@"SyncDevice"];
            if (deviceRecords.count > 0) {
                [self handleDeviceRecords:deviceRecords fullReplace:NO];
            }

            [USER_DEFAULTS setObject:[NSDate date] forKey:iCloudSyncLastSyncDate];
            [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidSyncNotification object:self];
            DebugLog(@"[iCloudSync] Fetch complete");
        });
    };

    [self.privateDatabase addOperation:op];
}

- (void)dispatchReceivedRecords:(NSDictionary<NSString *, NSMutableArray<CKRecord *> *> *)recordsByType
                     deletions:(NSDictionary<NSString *, NSMutableArray<CKRecordID *> *> *)deletionsByType
{
    for (id<ICCloudSyncHandler> handler in self.handlers) {
        NSString *key = [self defaultsKeyForHandler:handler];
        if (key && ![USER_DEFAULTS boolForKey:key]) continue;

        NSString *type = [handler recordType];
        NSArray<CKRecord *> *records = recordsByType[type];
        NSArray<CKRecordID *> *deletions = deletionsByType[type];

        if (records.count > 0) {
            [handler handleReceivedRecords:records completion:^(NSError *error) {
                if (error) {
                    ErrLog(@"[iCloudSync] Handle records error for %@: %@", type, error);
                }
            }];
        }
        if (deletions.count > 0) {
            [handler handleDeletedRecordIDs:deletions completion:^(NSError *error) {
                if (error) {
                    ErrLog(@"[iCloudSync] Handle deletions error for %@: %@", type, error);
                }
            }];
        }
    }
}

- (void)handleDeviceRecords:(NSArray<CKRecord *> *)records fullReplace:(BOOL)fullReplace
{
    NSString *myDeviceID = [USER_DEFAULTS stringForKey:iCloudSyncDeviceID];

    if (fullReplace) {
        [self.mutableDevices removeAllObjects];
    }

    for (CKRecord *record in records) {
        ICCloudSyncDeviceInfo *device = [ICCloudSyncDeviceInfo fromCKRecord:record];
        if ([device.deviceID isEqualToString:myDeviceID]) continue;

        // Merge: update existing or add new
        NSInteger existingIndex = NSNotFound;
        for (NSInteger i = 0; i < self.mutableDevices.count; i++) {
            if ([self.mutableDevices[i].deviceID isEqualToString:device.deviceID]) {
                existingIndex = i;
                break;
            }
        }
        if (existingIndex != NSNotFound) {
            [self.mutableDevices replaceObjectAtIndex:existingIndex withObject:device];
        } else {
            [self.mutableDevices addObject:device];
        }
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidUpdateDevicesNotification object:self];
}

#pragma mark - Remote Notifications

- (void)handleRemoteNotificationWithUserInfo:(NSDictionary *)userInfo
{
    CKDatabaseNotification *notification = [CKDatabaseNotification notificationFromRemoteNotificationDictionary:userInfo];
    if (notification.databaseScope == CKDatabaseScopePrivate) {
        [self fetchChanges];
    }
}

#pragma mark - Initial Sync

- (void)checkCloudDataExists:(void(^)(BOOL exists))completion
{
    // Check if the sync zone exists — if it does, cloud data exists
    CKFetchRecordZonesOperation *op = [[CKFetchRecordZonesOperation alloc] initWithRecordZoneIDs:@[self.syncZoneID]];
    op.fetchRecordZonesCompletionBlock = ^(NSDictionary<CKRecordZoneID *, CKRecordZone *> *zones, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                // Check partial failures (zone not found is reported per-zone)
                if (error.code == CKErrorPartialFailure) {
                    NSDictionary *partialErrors = error.userInfo[CKPartialErrorsByItemIDKey];
                    for (NSError *partialError in partialErrors.allValues) {
                        if (partialError.code == CKErrorZoneNotFound) {
                            completion(NO);
                            return;
                        }
                    }
                }
                ErrLog(@"[iCloudSync] Cloud data check error: %@", error);
                completion(NO);
                return;
            }
            completion(zones.count > 0);
        });
    };
    [self.privateDatabase addOperation:op];
}

- (void)pushAllDataWithCompletion:(void(^)(NSError *error))completion
{
    if (self.isSyncing) {
        completion(nil);
        return;
    }
    self.isSyncing = YES;

    DebugLog(@"[iCloudSync] Pushing ALL data...");

    dispatch_group_t group = dispatch_group_create();

    for (id<ICCloudSyncHandler> handler in self.handlers) {
        NSString *key = [self defaultsKeyForHandler:handler];
        if (key && ![USER_DEFAULTS boolForKey:key]) continue;

        dispatch_group_enter(group);
        if ([handler respondsToSelector:@selector(pushAllDataWithCompletion:)]) {
            [handler pushAllDataWithCompletion:^(NSError *error) {
                if (error) {
                    ErrLog(@"[iCloudSync] Push all error for %@: %@", [handler recordType], error);
                }
                dispatch_group_leave(group);
            }];
        } else {
            [handler pushChangesWithCompletion:^(NSError *error) {
                if (error) {
                    ErrLog(@"[iCloudSync] Push all error for %@: %@", [handler recordType], error);
                }
                dispatch_group_leave(group);
            }];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.isSyncing = NO;
        [USER_DEFAULTS setObject:[NSDate date] forKey:iCloudSyncLastSyncDate];
        [USER_DEFAULTS setBool:YES forKey:iCloudSyncInitialSyncCompleted];
        [USER_DEFAULTS synchronize];
        [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidSyncNotification object:self];
        DebugLog(@"[iCloudSync] Push all complete");
        completion(nil);
    });
}

- (void)fetchAllDataWithCompletion:(void(^)(NSError *error))completion
{
    if (self.isSyncing) {
        completion(nil);
        return;
    }
    self.isSyncing = YES;

    DebugLog(@"[iCloudSync] Fetching ALL data (full pull)...");

    // Reset change token so we get everything
    [USER_DEFAULTS removeObjectForKey:iCloudSyncServerChangeToken];
    [USER_DEFAULTS synchronize];

    CKFetchRecordZoneChangesConfiguration *config = [[CKFetchRecordZoneChangesConfiguration alloc] init];
    config.previousServerChangeToken = nil; // fetch everything

    CKFetchRecordZoneChangesOperation *op = [[CKFetchRecordZoneChangesOperation alloc] initWithRecordZoneIDs:@[self.syncZoneID] configurationsByRecordZoneID:@{self.syncZoneID: config}];

    NSMutableDictionary<NSString *, NSMutableArray<CKRecord *> *> *recordsByType = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<CKRecordID *> *> *deletionsByType = [NSMutableDictionary dictionary];

    op.recordChangedBlock = ^(CKRecord *record) {
        NSString *type = record.recordType;
        if (!recordsByType[type]) {
            recordsByType[type] = [NSMutableArray array];
        }
        [recordsByType[type] addObject:record];
    };

    op.recordWithIDWasDeletedBlock = ^(CKRecordID *recordID, CKRecordType recordType) {
        if (!deletionsByType[recordType]) {
            deletionsByType[recordType] = [NSMutableArray array];
        }
        [deletionsByType[recordType] addObject:recordID];
    };

    op.recordZoneFetchCompletionBlock = ^(CKRecordZoneID *zoneID, CKServerChangeToken *token, NSData *clientData, BOOL moreComing, NSError *error) {
        if (token) {
            NSData *data = [NSKeyedArchiver archivedDataWithRootObject:token requiringSecureCoding:YES error:nil];
            [USER_DEFAULTS setObject:data forKey:iCloudSyncServerChangeToken];
            [USER_DEFAULTS synchronize];
        }
    };

    op.fetchRecordZoneChangesCompletionBlock = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isSyncing = NO;

            if (error) {
                ErrLog(@"[iCloudSync] Fetch all error: %@", error);
                completion(error);
                return;
            }

            [self dispatchReceivedRecords:recordsByType deletions:deletionsByType];

            NSArray<CKRecord *> *deviceRecords = recordsByType[@"SyncDevice"];
            if (deviceRecords.count > 0) {
                [self handleDeviceRecords:deviceRecords fullReplace:YES];
            }

            [USER_DEFAULTS setObject:[NSDate date] forKey:iCloudSyncLastSyncDate];
            [USER_DEFAULTS setBool:YES forKey:iCloudSyncInitialSyncCompleted];
            [USER_DEFAULTS synchronize];
            [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerDidSyncNotification object:self];
            DebugLog(@"[iCloudSync] Fetch all complete");
            completion(nil);
        });
    };

    [self.privateDatabase addOperation:op];
}

- (void)fetchDeviceList
{
    // Use zone fetch instead of CKQuery (avoids queryable index requirement)
    CKFetchRecordZoneChangesConfiguration *config = [[CKFetchRecordZoneChangesConfiguration alloc] init];
    config.previousServerChangeToken = nil; // fetch all records

    CKFetchRecordZoneChangesOperation *op = [[CKFetchRecordZoneChangesOperation alloc] initWithRecordZoneIDs:@[self.syncZoneID] configurationsByRecordZoneID:@{self.syncZoneID: config}];

    NSMutableArray<CKRecord *> *deviceRecords = [NSMutableArray array];

    op.recordChangedBlock = ^(CKRecord *record) {
        if ([record.recordType isEqualToString:@"SyncDevice"]) {
            [deviceRecords addObject:record];
        }
    };

    // Don't save change token from this one-off fetch (would interfere with incremental sync)
    op.recordZoneFetchCompletionBlock = ^(CKRecordZoneID *zoneID, CKServerChangeToken *token, NSData *clientData, BOOL moreComing, NSError *error) {
        // intentionally not saving token
    };

    op.fetchRecordZoneChangesCompletionBlock = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                ErrLog(@"[iCloudSync] Fetch devices error: %@", error);
                return;
            }
            [self handleDeviceRecords:deviceRecords fullReplace:YES];
        });
    };

    [self.privateDatabase addOperation:op];
}

#pragma mark - Helper

- (NSString *)defaultsKeyForHandler:(id<ICCloudSyncHandler>)handler
{
    NSString *type = [handler recordType];
    if ([type isEqualToString:@"SyncEpisodeStatus"] || [type isEqualToString:@"SyncBookmark"]) {
        return iCloudSyncPlaybackStatus;
    } else if ([type isEqualToString:@"SyncNowPlaying"]) {
        return iCloudSyncNowPlaying;
    } else if ([type isEqualToString:@"SyncSubscription"]) {
        return iCloudSyncSubscriptions;
    } else if ([type isEqualToString:@"SyncFeedProperty"]) {
        return iCloudSyncFeedSettings;
    } else if ([type isEqualToString:@"SyncAppSettings"]) {
        return iCloudSyncAppSettings;
    } else if ([type isEqualToString:@"SyncDownloadStatus"]) {
        return iCloudSyncDownloadStatus;
    } else if ([type isEqualToString:@"SyncList"]) {
        return iCloudSyncLists;
    } else if ([type isEqualToString:@"SyncUpNext"]) {
        return iCloudSyncUpNext;
    }
    return nil;
}

@end
