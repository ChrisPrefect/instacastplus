//
//  ICCloudSyncUpNextHandler.m
//  Instacast
//

#import "ICCloudSyncUpNextHandler.h"

static NSString * const kUpNextLastAppliedTimestamp = @"iCloudSyncUpNextLastApplied";

@interface ICCloudSyncUpNextHandler ()
@property (nonatomic, assign) BOOL observing;
@property (nonatomic, strong) NSString *lastPushedHashSignature;
@end

@implementation ICCloudSyncUpNextHandler

- (NSString *)recordType
{
    return @"SyncUpNext";
}

- (void)dealloc
{
    if (_observing) {
        [AudioSession.sharedAudioSession removeObserver:self forKeyPath:@"playlist"];
    }
}

#pragma mark - Observation

- (void)startObserving
{
    if (self.observing) return;
    self.observing = YES;
    [AudioSession.sharedAudioSession addObserver:self forKeyPath:@"playlist" options:NSKeyValueObservingOptionNew context:NULL];
}

- (void)stopObserving
{
    if (!self.observing) return;
    self.observing = NO;
    [AudioSession.sharedAudioSession removeObserver:self forKeyPath:@"playlist"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"playlist"]) {
        // Check if the queue actually changed (compare hash signatures)
        NSString *currentSignature = [self hashSignatureForCurrentQueue];
        if ([currentSignature isEqualToString:self.lastPushedHashSignature]) {
            return;
        }

        if (![USER_DEFAULTS boolForKey:iCloudSyncUpNext]) return;
        if (![USER_DEFAULTS boolForKey:iCloudSyncEnabled]) return;

        [self pushChangesWithCompletion:^(NSError *error) {
            if (error) {
                ErrLog(@"[iCloudSync] UpNext auto-push error: %@", error);
            }
        }];
    }
}

- (NSString *)hashSignatureForCurrentQueue
{
    NSArray *playlist = AudioSession.sharedAudioSession.playlist;
    NSMutableString *sig = [NSMutableString string];
    for (CDEpisode *ep in playlist) {
        if (ep.objectHash) {
            [sig appendString:ep.objectHash];
            [sig appendString:@","];
        }
    }
    return [sig copy];
}

#pragma mark - Push

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    NSString *deviceID = [USER_DEFAULTS stringForKey:iCloudSyncDeviceID];
    if (!deviceID) {
        completion(nil);
        return;
    }

    NSArray *playlist = AudioSession.sharedAudioSession.playlist;

    NSMutableArray *hashes = [NSMutableArray arrayWithCapacity:playlist.count];
    for (CDEpisode *ep in playlist) {
        if (ep.objectHash) {
            [hashes addObject:ep.objectHash];
        }
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:hashes options:0 error:nil];
    NSString *hashesJSON = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"upnext_%@", deviceID] zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncUpNext" recordID:recordID];
    record[@"deviceID"] = deviceID;
    record[@"episodeHashes"] = hashesJSON;
    record[@"lastModified"] = [NSDate date];

    self.lastPushedHashSignature = [self hashSignatureForCurrentQueue];

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

- (void)pushAllDataWithCompletion:(void(^)(NSError *error))completion
{
    [self pushChangesWithCompletion:completion];
}

#pragma mark - Pull

- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    NSString *myDeviceID = [USER_DEFAULTS stringForKey:iCloudSyncDeviceID];

    // Find the most recent record from another device
    CKRecord *bestRecord = nil;
    NSDate *bestDate = nil;

    for (CKRecord *record in records) {
        NSString *recordDeviceID = record[@"deviceID"];
        if ([recordDeviceID isEqualToString:myDeviceID]) continue;

        NSDate *modified = record[@"lastModified"];
        if (!modified) continue;

        if (!bestDate || [modified compare:bestDate] == NSOrderedDescending) {
            bestDate = modified;
            bestRecord = record;
        }
    }

    if (!bestRecord) {
        completion(nil);
        return;
    }

    // Only apply if remote is newer than last applied
    NSDate *lastApplied = [USER_DEFAULTS objectForKey:kUpNextLastAppliedTimestamp];
    if (lastApplied && [bestDate compare:lastApplied] != NSOrderedDescending) {
        completion(nil);
        return;
    }

    NSString *hashesJSON = bestRecord[@"episodeHashes"];
    if (!hashesJSON) {
        completion(nil);
        return;
    }

    NSArray *hashes = [NSJSONSerialization JSONObjectWithData:[hashesJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![hashes isKindOfClass:[NSArray class]]) {
        completion(nil);
        return;
    }

    // Resolve episodes
    NSMutableArray *episodes = [NSMutableArray arrayWithCapacity:hashes.count];
    for (NSString *hash in hashes) {
        CDEpisode *episode = [DMANAGER episodeWithObjectHash:hash];
        if (episode) {
            [episodes addObject:episode];
        }
    }

    // Replace current Up Next queue
    AudioSession *session = AudioSession.sharedAudioSession;
    [session eraseAllEpisodesFromUpNext];
    if (episodes.count > 0) {
        [session appendToUpNext:episodes];
    }

    // Update the pushed signature to avoid re-pushing what we just received
    self.lastPushedHashSignature = [self hashSignatureForCurrentQueue];

    [USER_DEFAULTS setObject:bestDate forKey:kUpNextLastAppliedTimestamp];
    [USER_DEFAULTS synchronize];

    completion(nil);
}

- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError *error))completion
{
    completion(nil);
}

@end
