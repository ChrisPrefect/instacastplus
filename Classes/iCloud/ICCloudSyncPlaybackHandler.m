//
//  ICCloudSyncPlaybackHandler.m
//  Instacast
//

#import "ICCloudSyncPlaybackHandler.h"
#import "Defines.h"

static NSString * const kPlaybackScrollPositionsRecordName = @"ep_scroll_positions";
static NSString * const kPlaybackScrollPositionsJSONKey = @"listScrollPositionsJSON";

@implementation ICCloudSyncPlaybackHandler

- (NSString *)recordType
{
    return @"SyncEpisodeStatus";
}

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    // Push recently changed episodes (consumed/position/starred)
    NSMutableArray *records = [NSMutableArray array];

    NSDate *lastSync = [USER_DEFAULTS objectForKey:iCloudSyncLastSyncDate];
    if (!lastSync) lastSync = [NSDate distantPast];

    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    request.predicate = [NSPredicate predicateWithFormat:@"lastPlayed != nil AND lastPlayed > %@", lastSync];
    request.fetchBatchSize = 200;

    NSArray<CDEpisode *> *episodes = [DMANAGER.objectContext executeFetchRequest:request error:nil];
    for (CDEpisode *episode in episodes) {
        CKRecord *record = [self recordForEpisode:episode];
        if (record) [records addObject:record];
    }

    NSDate *scrollPositionsLastModified = ICListScrollPositionsLastModifiedDate();
    if (scrollPositionsLastModified && [scrollPositionsLastModified compare:lastSync] == NSOrderedDescending) {
        CKRecord *scrollPositionsRecord = [self recordForScrollPositions];
        if (scrollPositionsRecord) {
            [records addObject:scrollPositionsRecord];
        }
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

    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"ep_%@", hash] zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncEpisodeStatus" recordID:recordID];
    record[@"episodeHash"] = hash;
    record[@"consumed"] = @(episode.consumed);
    record[@"position"] = @(episode.position);
    record[@"starred"] = @(episode.starred);
    record[@"archived"] = @(episode.archived);
    record[@"lastPlayed"] = episode.lastPlayed ?: [NSDate date];
    record[@"feedSourceURL"] = episode.feed.sourceURL ? [episode.feed.sourceURL absoluteString] : @"";
    record[@"episodeTitle"] = episode.title ?: @"";
    record[@"lastModified"] = [NSDate date];
    return record;
}

- (CKRecord *)recordForScrollPositions
{
    NSDate *lastModified = ICListScrollPositionsLastModifiedDate();
    if (!lastModified) {
        return nil;
    }

    NSDictionary<NSString*, NSNumber*> *positions = ICListScrollPositionsSnapshot();
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:positions options:0 error:&jsonError];
    if (jsonError || !jsonData) {
        return nil;
    }

    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (!jsonString) {
        return nil;
    }

    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:kPlaybackScrollPositionsRecordName zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncEpisodeStatus" recordID:recordID];
    record[kPlaybackScrollPositionsJSONKey] = jsonString;
    record[@"lastModified"] = lastModified;
    return record;
}

- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    for (CKRecord *record in records) {
        NSString *positionsJSON = record[kPlaybackScrollPositionsJSONKey];
        if ([positionsJSON isKindOfClass:[NSString class]]) {
            NSData *jsonData = [positionsJSON dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *positions = nil;
            if (jsonData) {
                id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
                if ([parsed isKindOfClass:[NSDictionary class]]) {
                    positions = (NSDictionary*)parsed;
                }
            }
            if (positions) {
                ICApplySyncedListScrollPositions(positions, record[@"lastModified"]);
            }
            continue;
        }

        NSString *hash = record[@"episodeHash"];
        if (!hash) continue;

        CDEpisode *episode = [DMANAGER episodeWithObjectHash:hash];
        if (!episode) continue;

        // Last-Write-Wins
        NSDate *remoteDate = record[@"lastModified"];
        NSDate *localDate = episode.lastPlayed;

        if (!localDate || (remoteDate && [remoteDate compare:localDate] == NSOrderedDescending)) {
            episode.consumed = [record[@"consumed"] boolValue];
            episode.position = [record[@"position"] intValue];
            episode.starred = [record[@"starred"] boolValue];
            episode.archived = [record[@"archived"] boolValue];
            episode.lastPlayed = record[@"lastPlayed"];
        }
    }

    [DMANAGER saveAndSync:NO];
    completion(nil);
}

- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError *error))completion
{
    completion(nil);
}

- (void)pushAllDataWithCompletion:(void(^)(NSError *error))completion
{
    NSArray *feeds = DMANAGER.visibleFeeds;
    NSMutableArray *records = [NSMutableArray array];

    for (CDFeed *feed in feeds) {
        for (CDEpisode *episode in feed.episodes) {
            CKRecord *record = [self recordForEpisode:episode];
            if (record) [records addObject:record];
        }
    }

    CKRecord *scrollPositionsRecord = [self recordForScrollPositions];
    if (scrollPositionsRecord) {
        [records addObject:scrollPositionsRecord];
    }

    if (records.count == 0) {
        completion(nil);
        return;
    }

    // CloudKit max 400 records per operation
    NSInteger batchSize = 400;
    dispatch_group_t group = dispatch_group_create();

    for (NSInteger i = 0; i < records.count; i += batchSize) {
        NSInteger end = MIN(i + batchSize, records.count);
        NSArray *batch = [records subarrayWithRange:NSMakeRange(i, end - i)];

        dispatch_group_enter(group);
        CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:batch recordIDsToDelete:nil];
        op.qualityOfService = NSQualityOfServiceUtility;
        op.savePolicy = CKRecordSaveAllKeys;
        op.modifyRecordsCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *error) {
            if (error) ErrLog(@"[iCloudSync] Batch push error: %@", error);
            dispatch_group_leave(group);
        };
        [self.database addOperation:op];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(nil);
    });
}

@end
