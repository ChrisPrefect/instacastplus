//
//  ICCloudSyncAppSettingsHandler.m
//  Instacast
//

#import "ICCloudSyncAppSettingsHandler.h"

// Whitelist of settings keys that should be synced
static NSArray *syncableSettingsKeys(void) {
    static NSArray *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"EnableCachingOver3G",
            @"EnableCachingImagesOver3G",
            @"EnableRefreshingOver3G",
            @"AutoCacheNewAudioEpisodes",
            @"AutoCacheNewVideoEpisodes",
            @"AutoCacheStorageLimit",
            @"UISoundEnabled",
            @"PlayerSkipBackPeriod",
            @"PlayerSkipForwardPeriod",
            @"PlayerAutoSkipEndPeriod",
            @"PlayerAutoSkipStartPeriod",
            @"ReplayAfterPause",
            @"FeedSortOrder",
            @"FeedSortKey",
            @"FeedListSortMode",
            @"DefaultPlaybackSpeed",
            @"DefaultIntelligentSleepTimer",
            @"EnableManualRefreshFinishedNotification",
            @"EnableManualDownloadFinishedNotification",
            @"EnableNewEpisodeNotification",
            @"DisableAutoLock",
            @"EnableStreamingOver3G",
            @"ShowApplicationBadgeForUnseen",
            @"ShowUnavailableEpisodes",
            @"PlayerControls",
            @"AppearanceMode",
            @"DontDeleteUpNextWhenChangingEpisode",
            @"OpenLinksInExternalBrowser",
            @"AutoDeleteAfterFinishedPlaying",
            @"AutoDeleteAfterMarkedAsPlayed",
            @"AutoDeleteNewsMode",
            @"ContinuousPlayFromFeed",
            @"AutoDownloadWhileStreaming",
            @"PlayerColorPerPodcastActive",
            @"PlayerThemeColorCode",
            @"PlayerThemeColorHexCode",
            @"InterfaceThemeDefaultActive",
            @"InterfaceThemeColorCode",
            @"InterfaceThemeColorHexCode",
            @"IntelligentSleepTimerAlwaysActive",
            @"ScreenTimerAlwaysActive",
            @"DisableSleepTimerInCarPlay",
            @"ScreenTouchIntelligentSleep",
            @"VolumeChangeIntelligentSleep",
            @"DeviceMovementIntelligentSleep",
            @"LastSelectedSleepTimer",
        ];
    });
    return keys;
}

@implementation ICCloudSyncAppSettingsHandler

- (NSString *)recordType
{
    return @"SyncAppSettings";
}

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:@"appsettings" zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncAppSettings" recordID:recordID];

    NSMutableDictionary *settingsDict = [NSMutableDictionary dictionary];
    for (NSString *key in syncableSettingsKeys()) {
        id value = [USER_DEFAULTS objectForKey:key];
        if (!value) continue;

        // Only include JSON-serializable types (skip NSData, archived objects, etc.)
        if ([value isKindOfClass:[NSString class]] ||
            [value isKindOfClass:[NSNumber class]] ||
            [value isKindOfClass:[NSArray class]] ||
            [value isKindOfClass:[NSDictionary class]]) {
            settingsDict[key] = value;
        }
    }

    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:settingsDict options:0 error:&jsonError];
    if (jsonError) {
        completion(jsonError);
        return;
    }

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    record[@"settingsJSON"] = jsonString;
    record[@"lastModified"] = [NSDate date];

    CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:@[record] recordIDsToDelete:nil];
    op.qualityOfService = NSQualityOfServiceUtility;
    op.savePolicy = CKRecordSaveAllKeys;
    op.modifyRecordsCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    };
    [self.database addOperation:op];
}

- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    for (CKRecord *record in records) {
        NSString *jsonString = record[@"settingsJSON"];
        if (!jsonString) continue;

        NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
        NSError *jsonError;
        NSDictionary *settings = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
        if (jsonError || !settings) continue;

        NSArray *whitelist = syncableSettingsKeys();
        for (NSString *key in settings) {
            if ([whitelist containsObject:key]) {
                [USER_DEFAULTS setObject:settings[key] forKey:key];
            }
        }
        [USER_DEFAULTS synchronize];

        // Notify appearance manager if theme settings changed
        [[ICAppearanceManager sharedManager] updateAppearance];
    }

    completion(nil);
}

- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError *error))completion
{
    completion(nil);
}

- (void)pushAllDataWithCompletion:(void(^)(NSError *error))completion
{
    [self pushChangesWithCompletion:completion];
}

@end
