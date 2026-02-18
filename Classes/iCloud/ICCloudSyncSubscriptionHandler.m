//
//  ICCloudSyncSubscriptionHandler.m
//  Instacast
//

#import "ICCloudSyncSubscriptionHandler.h"

@implementation ICCloudSyncSubscriptionHandler

- (NSString *)recordType
{
    return @"SyncSubscription";
}

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    NSArray *feeds = DMANAGER.feeds;  // include parked feeds so their status is synced
    if (feeds.count == 0) {
        completion(nil);
        return;
    }

    NSMutableArray *records = [NSMutableArray array];
    for (CDFeed *feed in feeds) {
        if (!feed.sourceURL) continue;

        CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"sub_%@", [[feed.sourceURL absoluteString] MD5Hash]] zoneID:self.zoneID];
        CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncSubscription" recordID:recordID];
        record[@"feedSourceURL"] = [feed.sourceURL absoluteString];
        record[@"feedTitle"] = feed.title ?: @"";
        record[@"feedImageURL"] = feed.imageURL ? [feed.imageURL absoluteString] : @"";
        record[@"rank"] = @(feed.rank);
        record[@"subscribed"] = @(feed.subscribed);
        record[@"parked"] = @(feed.parked);
        record[@"feedUsername"] = feed.username ?: @"";
        record[@"feedPassword"] = feed.password ?: @"";
        record[@"lastModified"] = [NSDate date];
        [records addObject:record];
    }

    CKModifyRecordsOperation *op = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:records recordIDsToDelete:nil];
    op.qualityOfService = NSQualityOfServiceUtility;
    op.savePolicy = CKRecordSaveChangedKeys;
    op.modifyRecordsCompletionBlock = ^(NSArray<CKRecord *> *saved, NSArray<CKRecordID *> *deleted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error && error.code == CKErrorPartialFailure) {
                [self handlePartialErrors:error.userInfo[CKPartialErrorsByItemIDKey] records:records completion:completion];
            } else {
                completion(error);
            }
        });
    };
    [self.database addOperation:op];
}

- (void)handlePartialErrors:(NSDictionary *)errors records:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    NSMutableArray *retryRecords = [NSMutableArray array];
    for (CKRecordID *recordID in errors) {
        NSError *itemError = errors[recordID];
        if (itemError.code == CKErrorServerRecordChanged) {
            CKRecord *serverRecord = itemError.userInfo[CKRecordChangedErrorServerRecordKey];
            if (serverRecord) {
                // Last-Write-Wins: check lastModified
                NSDate *serverDate = serverRecord[@"lastModified"];
                for (CKRecord *local in records) {
                    if ([local.recordID isEqual:recordID]) {
                        NSDate *localDate = local[@"lastModified"] ?: [NSDate date];
                        if ([localDate compare:serverDate] == NSOrderedDescending) {
                            // Local is newer, overwrite server
                            for (NSString *key in local.allKeys) {
                                serverRecord[key] = local[key];
                            }
                            [retryRecords addObject:serverRecord];
                        }
                        break;
                    }
                }
            }
        }
    }

    if (retryRecords.count > 0) {
        CKModifyRecordsOperation *retryOp = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:retryRecords recordIDsToDelete:nil];
        retryOp.qualityOfService = NSQualityOfServiceUtility;
        retryOp.savePolicy = CKRecordSaveAllKeys;
        retryOp.modifyRecordsCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(error);
            });
        };
        [self.database addOperation:retryOp];
    } else {
        completion(nil);
    }
}

- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    dispatch_group_t group = dispatch_group_create();

    for (CKRecord *record in records) {
        NSString *feedURLString = record[@"feedSourceURL"];
        if (!feedURLString) continue;

        NSURL *feedURL = [NSURL URLWithString:feedURLString];
        if (!feedURL) continue;

        BOOL subscribed = [record[@"subscribed"] boolValue];
        CDFeed *existingFeed = [DMANAGER feedWithSourceURL:feedURL];

        NSString *username = record[@"feedUsername"];
        NSString *password = record[@"feedPassword"];
        if ([username length] == 0) username = nil;
        if ([password length] == 0) password = nil;

        if (subscribed && !existingFeed) {
            // Subscribe to new feed (async)
            // Build URL with embedded credentials so ICFeedParser can authenticate
            NSURL *subscribeURL = feedURL;
            if (username && password) {
                NSURLComponents *components = [NSURLComponents componentsWithURL:feedURL resolvingAgainstBaseURL:NO];
                components.user = username;
                components.password = password;
                if (components.URL) subscribeURL = components.URL;
            }
            dispatch_group_enter(group);
            [[SubscriptionManager sharedSubscriptionManager] subscribeFeedWithURL:subscribeURL options:0 completion:^(CDFeed *feed, NSError *error) {
                if (feed) {
                    NSNumber *rank = record[@"rank"];
                    if (rank) feed.rank = [rank intValue];
                    NSNumber *parked = record[@"parked"];
                    if (parked) feed.parked = [parked boolValue];
                    // ensure credentials are set (ICFeedParser extracts them from URL
                    // and stores them, but verify)
                    if (username && !feed.username) feed.username = username;
                    if (password && !feed.password) feed.password = password;
                    [DMANAGER saveAndSync:NO];
                }
                dispatch_group_leave(group);
            }];
        } else if (!subscribed && existingFeed) {
            // Unsubscribe
            [DMANAGER unsubscribeFeed:existingFeed];
            [DMANAGER saveAndSync:NO];
        } else if (existingFeed) {
            // Update rank/parked status
            NSNumber *rank = record[@"rank"];
            if (rank) existingFeed.rank = [rank intValue];
            NSNumber *parked = record[@"parked"];
            if (parked) existingFeed.parked = [parked boolValue];
            // restore credentials from iCloud if not already set locally
            if (username && !existingFeed.username) existingFeed.username = username;
            if (password && !existingFeed.password) existingFeed.password = password;
            [DMANAGER saveAndSync:NO];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(nil);
    });
}

- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError *error))completion
{
    // Deletion of SyncSubscription = unsubscribe
    // We don't have the feed URL from just a recordID, so we skip deletion handling
    // (unsubscribes are handled via subscribed=NO in handleReceivedRecords)
    completion(nil);
}

- (void)pushAllDataWithCompletion:(void(^)(NSError *error))completion
{
    [self pushChangesWithCompletion:completion];
}

@end
