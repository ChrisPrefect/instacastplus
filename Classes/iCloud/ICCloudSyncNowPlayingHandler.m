//
//  ICCloudSyncNowPlayingHandler.m
//  Instacast
//

#import "ICCloudSyncNowPlayingHandler.h"

static NSTimeInterval const kNowPlayingPushInterval = 5.0;

@interface ICCloudSyncNowPlayingHandler ()
@property (nonatomic, strong) NSTimer *positionTimer;
@property (nonatomic, assign) BOOL observing;
@property (nonatomic, assign) BOOL lastKnownPausedState;
@property (nonatomic, strong) NSDate *retryAfterDate;
@end

@implementation ICCloudSyncNowPlayingHandler

- (NSString *)recordType
{
    return @"SyncNowPlaying";
}

- (void)startObserving
{
    if (self.observing) return;
    self.observing = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackDidStart:)
                                                 name:PlaybackManagerDidStartNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackDidStop:)
                                                 name:PlaybackManagerDidEndNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackDidStop:)
                                                 name:PlaybackManagerEpisodeDidFinishNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playbackDidChange:)
                                                 name:PlaybackManagerDidChangeEpisodeNotification
                                               object:nil];
}

- (void)stopObserving
{
    self.observing = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.positionTimer invalidate];
    self.positionTimer = nil;
}

- (void)dealloc
{
    [self stopObserving];
}

#pragma mark - Playback Notifications

- (void)playbackDidStart:(NSNotification *)note
{
    [self pushNowPlayingImmediately];
    [self startPositionTimer];
}

- (void)playbackDidStop:(NSNotification *)note
{
    [self.positionTimer invalidate];
    self.positionTimer = nil;
    [self pushNowPlayingImmediately];
}

- (void)playbackDidChange:(NSNotification *)note
{
    [self pushNowPlayingImmediately];
    [self startPositionTimer];
}

- (void)startPositionTimer
{
    [self.positionTimer invalidate];
    self.positionTimer = [NSTimer scheduledTimerWithTimeInterval:kNowPlayingPushInterval
                                                         target:self
                                                       selector:@selector(positionTimerFired)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)positionTimerFired
{
    PlaybackManager *pm = [PlaybackManager playbackManager];
    BOOL currentPaused = pm.isPaused;

    // Always push if pause state changed
    if (currentPaused != self.lastKnownPausedState) {
        self.lastKnownPausedState = currentPaused;
        if (currentPaused) {
            [self.positionTimer invalidate];
            self.positionTimer = nil;
        }
        [self pushNowPlayingImmediately];
        return;
    }

    // Only push position updates during active playback
    if (!currentPaused && pm.playingEpisode) {
        [self pushNowPlayingImmediately];
    }
}

#pragma mark - Push

- (void)pushNowPlayingImmediately
{
    if (self.retryAfterDate && [self.retryAfterDate timeIntervalSinceNow] > 0) {
        return;
    }

    [self pushChangesWithCompletion:^(NSError *error) {
        if (error) {
            ErrLog(@"[iCloudSync] NowPlaying push error: %@", error);
            NSNumber *retryAfter = error.userInfo[CKErrorRetryAfterKey];
            if (retryAfter.doubleValue > 0) {
                self.retryAfterDate = [NSDate dateWithTimeIntervalSinceNow:retryAfter.doubleValue];
            }
        } else {
            self.retryAfterDate = nil;
            [USER_DEFAULTS setObject:[NSDate date] forKey:iCloudSyncLastSyncDate];
        }
    }];
}

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    NSString *deviceID = [USER_DEFAULTS stringForKey:iCloudSyncDeviceID];
    if (!deviceID) {
        completion(nil);
        return;
    }

    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"np_%@", deviceID] zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncNowPlaying" recordID:recordID];
    record[@"deviceID"] = deviceID;

    PlaybackManager *pm = [PlaybackManager playbackManager];
    CDEpisode *episode = pm.playingEpisode;

    if (episode) {
        record[@"episodeHash"] = episode.objectHash ?: @"";
        record[@"episodeTitle"] = episode.title ?: @"";
        record[@"feedTitle"] = episode.feed.title ?: @"";
        record[@"feedSourceURL"] = episode.feed.sourceURL ? [episode.feed.sourceURL absoluteString] : @"";
        record[@"position"] = @(pm.time);
        record[@"duration"] = @(pm.duration);
        record[@"isPaused"] = @(pm.isPaused);
        record[@"isPlaying"] = @(!pm.isPaused);
    } else {
        record[@"episodeHash"] = @"";
        record[@"isPlaying"] = @NO;
        record[@"isPaused"] = @NO;
    }

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
    // Keep SyncNowPlaying as metadata-only. Remote takeover is handled explicitly in UI flow.
    completion(nil);
}

- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError *error))completion
{
    completion(nil);
}

@end
