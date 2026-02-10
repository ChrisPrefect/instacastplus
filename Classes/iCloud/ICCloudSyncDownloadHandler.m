//
//  ICCloudSyncDownloadHandler.m
//  Instacast
//

#import "ICCloudSyncDownloadHandler.h"

@implementation ICCloudSyncDownloadHandler

- (NSString *)recordType
{
    return @"SyncDownloadStatus";
}

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    NSMutableArray *records = [NSMutableArray array];

    NSDate *lastSync = [USER_DEFAULTS objectForKey:iCloudSyncLastSyncDate];
    if (!lastSync) lastSync = [NSDate distantPast];

    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    request.predicate = [NSPredicate predicateWithFormat:@"lastDownloaded != nil AND lastDownloaded > %@", lastSync];
    request.fetchBatchSize = 200;

    NSArray<CDEpisode *> *episodes = [DMANAGER.objectContext executeFetchRequest:request error:nil];
    for (CDEpisode *episode in episodes) {
        CKRecord *record = [self recordForEpisode:episode];
        if (record) [records addObject:record];
    }

    if (records.count == 0) {
        completion(nil);
        return;
    }

    CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:records recordIDsToDelete:nil];
    op.qualityOfService = NSQualityOfServiceUtility;
    op.savePolicy = CKRecordSaveAllKeys;
    op.modifyRecordsCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(error);
        });
    };
    [self.database addOperation:op];
}

- (CKRecord *)recordForEpisode:(CDEpisode *)episode
{
    NSString *hash = episode.objectHash;
    if (!hash) return nil;

    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"dl_%@", hash] zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncDownloadStatus" recordID:recordID];
    record[@"episodeHash"] = hash;
    record[@"downloaded"] = @(episode.downloaded);
    record[@"feedSourceURL"] = episode.feed.sourceURL ? [episode.feed.sourceURL absoluteString] : @"";
    record[@"episodeTitle"] = episode.title ?: @"";
    record[@"lastModified"] = [NSDate date];
    return record;
}

- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    CacheManager *cman = [CacheManager sharedCacheManager];

    for (CKRecord *record in records) {
        NSString *hash = record[@"episodeHash"];
        if (!hash) continue;

        CDEpisode *episode = [DMANAGER episodeWithObjectHash:hash];
        if (!episode) continue;

        BOOL remoteDownloaded = [record[@"downloaded"] boolValue];

        if (remoteDownloaded && !episode.downloaded) {
            // Check network conditions
            BOOL cellularAllowed = [USER_DEFAULTS boolForKey:EnableCachingOver3G];
            BOOL hasWiFi = (App.networkAccessTechnology == kICNetworkAccessTechnlogyWIFI);

            if (!cellularAllowed && !hasWiFi) {
                DebugLog(@"[iCloudSync] Skipping download sync for %@ - no WiFi", episode.title);
                continue;
            }

            // Check storage limit
            NSInteger storageLimit = [USER_DEFAULTS integerForKey:AutoCacheStorageLimit];
            if (storageLimit > 0) {
                // Storage limit check - CacheManager handles this internally
                DebugLog(@"[iCloudSync] Storage limit active (%ld), CacheManager will handle", (long)storageLimit);
            }

            [cman cacheEpisode:episode];
        } else if (!remoteDownloaded && episode.downloaded) {
            [cman removeCacheForEpisode:episode automatic:YES];
        }
    }

    completion(nil);
}

- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError *error))completion
{
    completion(nil);
}

@end
