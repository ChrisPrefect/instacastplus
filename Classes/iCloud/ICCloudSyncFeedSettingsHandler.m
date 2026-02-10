//
//  ICCloudSyncFeedSettingsHandler.m
//  Instacast
//

#import "ICCloudSyncFeedSettingsHandler.h"

@implementation ICCloudSyncFeedSettingsHandler

- (NSString *)recordType
{
    return @"SyncFeedProperty";
}

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    NSArray *feeds = DMANAGER.visibleFeeds;
    NSMutableArray *records = [NSMutableArray array];

    for (CDFeed *feed in feeds) {
        if (![feed hasCustomProperties]) continue;
        if (!feed.sourceURL) continue;

        NSArray *keys = [feed propertyKeys];
        for (NSString *key in keys) {
            CKRecord *record = [self recordForFeed:feed propertyKey:key];
            if (record) [records addObject:record];
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

- (CKRecord *)recordForFeed:(CDFeed *)feed propertyKey:(NSString *)key
{
    NSString *feedHash = [[feed.sourceURL absoluteString] MD5Hash];
    NSString *recordName = [NSString stringWithFormat:@"fp_%@_%@", feedHash, key];

    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:recordName zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncFeedProperty" recordID:recordID];
    record[@"feedSourceURL"] = [feed.sourceURL absoluteString];
    record[@"propertyKey"] = key;
    record[@"lastModified"] = [NSDate date];

    // Store all value types
    record[@"boolValue"] = @([feed boolForKey:key]);
    record[@"integerValue"] = @([feed integerForKey:key]);
    record[@"doubleValue"] = @([feed doubleForKey:key]);
    NSString *stringVal = [feed stringForKey:key];
    record[@"stringValue"] = stringVal ?: @"";

    return record;
}

- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    for (CKRecord *record in records) {
        NSString *feedURLString = record[@"feedSourceURL"];
        NSString *key = record[@"propertyKey"];
        if (!feedURLString || !key) continue;

        NSURL *feedURL = [NSURL URLWithString:feedURLString];
        CDFeed *feed = [DMANAGER feedWithSourceURL:feedURL];
        if (!feed) continue;

        // Apply property values
        NSNumber *boolVal = record[@"boolValue"];
        NSNumber *intVal = record[@"integerValue"];
        NSNumber *doubleVal = record[@"doubleValue"];
        NSString *strVal = record[@"stringValue"];

        if (doubleVal && [doubleVal doubleValue] != 0.0) {
            [feed setDouble:[doubleVal doubleValue] forKey:key];
        } else if (intVal && [intVal integerValue] != 0) {
            [feed setInteger:[intVal integerValue] forKey:key];
        } else if (strVal && strVal.length > 0) {
            [feed setString:strVal forKey:key];
        } else if (boolVal) {
            [feed setBool:[boolVal boolValue] forKey:key];
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
    [self pushChangesWithCompletion:completion];
}

@end
