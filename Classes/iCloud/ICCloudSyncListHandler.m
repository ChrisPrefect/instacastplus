//
//  ICCloudSyncListHandler.m
//  Instacast
//

#import "ICCloudSyncListHandler.h"
#import "CDPlaylist.h"
#import "CDSmartPlaylist.h"
#import "CDPlaylistEpisode.h"

@implementation ICCloudSyncListHandler

- (NSString *)recordType
{
    return @"SyncList";
}

#pragma mark - Push

- (void)pushChangesWithCompletion:(void(^)(NSError *error))completion
{
    NSArray *lists = DMANAGER.lists;
    if (lists.count == 0) {
        completion(nil);
        return;
    }

    NSMutableArray *records = [NSMutableArray array];
    for (CDList *list in lists) {
        CKRecord *record = [self recordForList:list];
        if (record) {
            [records addObject:record];
        }
    }

    if (records.count == 0) {
        completion(nil);
        return;
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

- (void)pushAllDataWithCompletion:(void(^)(NSError *error))completion
{
    [self pushChangesWithCompletion:completion];
}

- (CKRecord *)recordForList:(CDList *)list
{
    if (!list.uid) return nil;

    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"list_%@", list.uid] zoneID:self.zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncList" recordID:recordID];
    record[@"uid"] = list.uid;
    record[@"name"] = list.name ?: @"";
    record[@"rank"] = @(list.rank);
    record[@"lastModified"] = [NSDate date];

    if ([list isKindOfClass:[CDPlaylist class]]) {
        CDPlaylist *playlist = (CDPlaylist *)list;
        record[@"listType"] = @"playlist";

        NSArray *episodes = playlist.sortedEpisodes;
        NSMutableArray *hashes = [NSMutableArray arrayWithCapacity:episodes.count];
        for (CDEpisode *ep in episodes) {
            if (ep.objectHash) {
                [hashes addObject:ep.objectHash];
            }
        }
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:hashes options:0 error:nil];
        record[@"episodeHashes"] = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    } else if ([list isKindOfClass:[CDSmartPlaylist class]]) {
        CDSmartPlaylist *smart = (CDSmartPlaylist *)list;
        record[@"listType"] = @"smart";

        NSDictionary *predicate = smart.smartPredicate;
        if (predicate) {
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:predicate options:0 error:nil];
            record[@"smartPredicateJSON"] = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }

    } else if ([list isKindOfClass:[CDEpisodeList class]]) {
        CDEpisodeList *episodeList = (CDEpisodeList *)list;
        record[@"listType"] = @"episodelist";

        record[@"icon"] = episodeList.icon ?: @"";
        record[@"query"] = episodeList.query ?: @"";
        record[@"audio"] = @(episodeList.audio);
        record[@"video"] = @(episodeList.video);
        record[@"downloaded"] = @(episodeList.downloaded);
        record[@"downloading"] = @(episodeList.downloading);
        record[@"notDownloaded"] = @(episodeList.notDownloaded);
        record[@"starred"] = @(episodeList.starred);
        record[@"notStarred"] = @(episodeList.notStarred);
        record[@"unplayed"] = @(episodeList.unplayed);
        record[@"unfinished"] = @(episodeList.unfinished);
        record[@"played"] = @(episodeList.played);
        record[@"orderBy"] = episodeList.orderBy ?: @"";
        record[@"groupByPodcast"] = @(episodeList.groupByPodcast);
        record[@"descending"] = @(episodeList.descending);
        record[@"continuousPlayback"] = @(episodeList.continuousPlayback);

        NSSet *feeds = episodeList.includedFeeds;
        if (feeds.count > 0) {
            NSMutableArray *feedURLs = [NSMutableArray arrayWithCapacity:feeds.count];
            for (CDFeed *feed in feeds) {
                if (feed.sourceURL) {
                    [feedURLs addObject:[feed.sourceURL absoluteString]];
                }
            }
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:feedURLs options:0 error:nil];
            record[@"includedFeedURLs"] = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        }
    }

    return record;
}

#pragma mark - Pull

- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    for (CKRecord *record in records) {
        NSString *uid = record[@"uid"];
        if (!uid) continue;

        CDList *existingList = [self listWithUID:uid];
        NSString *listType = record[@"listType"];

        if (existingList) {
            [self updateList:existingList fromRecord:record listType:listType];
        } else {
            [self createListFromRecord:record listType:listType uid:uid];
        }
    }

    [DMANAGER saveAndSync:NO];
    completion(nil);
}

- (CDList *)listWithUID:(NSString *)uid
{
    for (CDList *list in DMANAGER.lists) {
        if ([list.uid isEqualToString:uid]) {
            return list;
        }
    }
    return nil;
}

- (void)updateList:(CDList *)list fromRecord:(CKRecord *)record listType:(NSString *)listType
{
    NSString *name = record[@"name"];
    if (name) list.name = name;

    NSNumber *rank = record[@"rank"];
    if (rank) list.rank = [rank intValue];

    if ([listType isEqualToString:@"playlist"] && [list isKindOfClass:[CDPlaylist class]]) {
        [self updatePlaylist:(CDPlaylist *)list fromRecord:record];
    } else if ([listType isEqualToString:@"episodelist"] && [list isKindOfClass:[CDEpisodeList class]]) {
        [self updateEpisodeList:(CDEpisodeList *)list fromRecord:record];
    } else if ([listType isEqualToString:@"smart"] && [list isKindOfClass:[CDSmartPlaylist class]]) {
        [self updateSmartPlaylist:(CDSmartPlaylist *)list fromRecord:record];
    }
}

- (void)updatePlaylist:(CDPlaylist *)playlist fromRecord:(CKRecord *)record
{
    NSString *hashesJSON = record[@"episodeHashes"];
    if (!hashesJSON) return;

    NSArray *hashes = [NSJSONSerialization JSONObjectWithData:[hashesJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![hashes isKindOfClass:[NSArray class]]) return;

    [playlist removeAllEpisodes];
    for (NSString *hash in hashes) {
        CDEpisode *episode = [DMANAGER episodeWithObjectHash:hash];
        if (episode) {
            [playlist addEpisode:episode];
        }
    }
}

- (void)updateSmartPlaylist:(CDSmartPlaylist *)smart fromRecord:(CKRecord *)record
{
    NSString *predicateJSON = record[@"smartPredicateJSON"];
    if (!predicateJSON) return;

    NSDictionary *predicate = [NSJSONSerialization JSONObjectWithData:[predicateJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if ([predicate isKindOfClass:[NSDictionary class]]) {
        smart.smartPredicate = predicate;
    }
}

- (void)updateEpisodeList:(CDEpisodeList *)episodeList fromRecord:(CKRecord *)record
{
    NSString *icon = record[@"icon"];
    if (icon) episodeList.icon = icon;

    NSString *query = record[@"query"];
    if (query) episodeList.query = ([query length] > 0) ? query : nil;

    episodeList.audio = [record[@"audio"] boolValue];
    episodeList.video = [record[@"video"] boolValue];
    episodeList.downloaded = [record[@"downloaded"] boolValue];
    episodeList.downloading = [record[@"downloading"] boolValue];
    episodeList.notDownloaded = [record[@"notDownloaded"] boolValue];
    episodeList.starred = [record[@"starred"] boolValue];
    episodeList.notStarred = [record[@"notStarred"] boolValue];
    episodeList.unplayed = [record[@"unplayed"] boolValue];
    episodeList.unfinished = [record[@"unfinished"] boolValue];
    episodeList.played = [record[@"played"] boolValue];

    NSString *orderBy = record[@"orderBy"];
    if (orderBy) episodeList.orderBy = ([orderBy length] > 0) ? orderBy : nil;

    episodeList.groupByPodcast = [record[@"groupByPodcast"] boolValue];
    episodeList.descending = [record[@"descending"] boolValue];
    episodeList.continuousPlayback = [record[@"continuousPlayback"] boolValue];

    NSString *feedURLsJSON = record[@"includedFeedURLs"];
    if (feedURLsJSON) {
        NSArray *feedURLs = [NSJSONSerialization JSONObjectWithData:[feedURLsJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([feedURLs isKindOfClass:[NSArray class]]) {
            NSMutableSet *feeds = [NSMutableSet set];
            for (NSString *urlString in feedURLs) {
                NSURL *url = [NSURL URLWithString:urlString];
                if (url) {
                    CDFeed *feed = [DMANAGER feedWithSourceURL:url];
                    if (feed) {
                        [feeds addObject:feed];
                    }
                }
            }
            episodeList.includedFeeds = feeds;
        }
    }

    [episodeList invalidateCaches];
}

- (void)createListFromRecord:(CKRecord *)record listType:(NSString *)listType uid:(NSString *)uid
{
    NSManagedObjectContext *ctx = DMANAGER.objectContext;

    if ([listType isEqualToString:@"playlist"]) {
        CDPlaylist *playlist = [NSEntityDescription insertNewObjectForEntityForName:@"Playlist" inManagedObjectContext:ctx];
        playlist.uid = uid;
        playlist.name = record[@"name"] ?: @"";
        playlist.rank = [record[@"rank"] intValue];
        [self updatePlaylist:playlist fromRecord:record];
        [DMANAGER addList:playlist];

    } else if ([listType isEqualToString:@"smart"]) {
        CDSmartPlaylist *smart = [NSEntityDescription insertNewObjectForEntityForName:@"SmartPlaylist" inManagedObjectContext:ctx];
        smart.uid = uid;
        smart.name = record[@"name"] ?: @"";
        smart.rank = [record[@"rank"] intValue];
        [self updateSmartPlaylist:smart fromRecord:record];
        [DMANAGER addList:smart];

    } else if ([listType isEqualToString:@"episodelist"]) {
        CDEpisodeList *episodeList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:ctx];
        episodeList.uid = uid;
        episodeList.name = record[@"name"] ?: @"";
        episodeList.rank = [record[@"rank"] intValue];
        [self updateEpisodeList:episodeList fromRecord:record];
        [DMANAGER addList:episodeList];
    }
}

#pragma mark - Deletion

- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError *error))completion
{
    for (CKRecordID *recordID in recordIDs) {
        // Record name format: "list_{uid}"
        NSString *recordName = recordID.recordName;
        if (![recordName hasPrefix:@"list_"]) continue;

        NSString *uid = [recordName substringFromIndex:5];
        CDList *list = [self listWithUID:uid];
        if (list) {
            [DMANAGER removeList:list];
        }
    }
    completion(nil);
}

#pragma mark - Conflict Resolution

- (void)handlePartialErrors:(NSDictionary *)errors records:(NSArray<CKRecord *> *)records completion:(void(^)(NSError *error))completion
{
    NSMutableArray *retryRecords = [NSMutableArray array];
    for (CKRecordID *recordID in errors) {
        NSError *itemError = errors[recordID];
        if (itemError.code == CKErrorServerRecordChanged) {
            CKRecord *serverRecord = itemError.userInfo[CKRecordChangedErrorServerRecordKey];
            if (serverRecord) {
                NSDate *serverDate = serverRecord[@"lastModified"];
                for (CKRecord *local in records) {
                    if ([local.recordID isEqual:recordID]) {
                        NSDate *localDate = local[@"lastModified"] ?: [NSDate date];
                        if ([localDate compare:serverDate] == NSOrderedDescending) {
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

@end
