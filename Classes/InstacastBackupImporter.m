//
//  InstacastBackupImporter.m
//  Instacast
//
//  Completely rewritten: Synchronous import on a dedicated background thread.
//  Cancel kills the operation immediately. All Core Data + UI dispatched to main thread.
//

#import "InstacastBackupImporter.h"
#import "InstacastBackupData.h"
#import "SubscriptionManager.h"
#import "EpisodeLoadingManager.h"
#import "CDPlaylist.h"
#import "CDEpisodeList.h"
#import "CDBookmark.h"
#import "CDFeedProperty.h"
#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"
#import "CacheManager.h"
#import "ImageCacheManager.h"
#import "WidgetDataExporter.h"
#import "AppleWatchSyncManager.h"
#import "AppleWatchEpisodeState.h"
#import "NSString+VMFoundation.h"
#import "InstacastPlus-Swift.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import <stdint.h>

static NSString * const kPendingBackupDownloadsKey = @"PendingBackupDownloads";
static NSString * const kPendingNowPlayingKey = @"PendingBackupNowPlaying";
static NSString * const ICBackupBookmarkStageDirectoryName = @"BackupImportRecovery";
static NSString * const ICBackupBookmarkStageFilename = @"bookmarks.plist";
static NSString * const ICBackupBookmarkInvalidStageFilename = @"bookmarks.invalid.plist";
static NSString * const ICBackupDownloadStageFilename = @"downloads.plist";
static NSString * const ICBackupDownloadCancellationDirectoryName = @"DownloadCancellations";
static NSString * const ICBackupBookmarkStageStateActive = @"active";
static NSString * const ICBackupBookmarkStageStateCancelled = @"cancelled";
static const NSUInteger ICBackupFeedSettingsBatchSize = 100;

static NSDictionary *ICBackupPendingNowPlayingRecord(NSString *guid,
                                                     NSString *feedURL,
                                                     double position,
                                                     uint64_t playbackIntentRevision) {
    return @{
        @"guid": guid ?: @"",
        @"feedURL": feedURL ?: @"",
        @"position": @(position),
        @"playbackIntentRevision": @(playbackIntentRevision),
    };
}

static BOOL ICBackupPendingNowPlayingMatchesPlaybackIntent(NSDictionary *record,
                                                           uint64_t playbackIntentRevision) {
    id storedRevision = record[@"playbackIntentRevision"];
    return [storedRevision isKindOfClass:[NSNumber class]] &&
        [storedRevision unsignedLongLongValue] == playbackIntentRevision;
}

// The currently running import operation — cancel via [_currentOperation cancel]
static NSOperationQueue *_importQueue = nil;
static NSBlockOperation *_currentOperation = nil;
static BOOL _skipCurrentFeed;
static BOOL _bookmarkRecoveryScheduled;
static BOOL _deferredRestoreScheduled;
static BOOL _deferredRestoreAllFeeds;
static NSMutableSet<NSString *> *_deferredRestoreFeedURLs;
static NSMutableSet<NSString *> *_deferredRestoreOwnedObjectHashes;

// GUID index for O(1) episode lookup
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSManagedObjectID *> *> *_guidIndexByFeedURL = nil;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *_episodeTitleByFeedURL = nil;

static dispatch_queue_t ICBackupImportStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.vemedio.instacast.backupImport.state", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSOperationQueue *ICBackupImportQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _importQueue = [[NSOperationQueue alloc] init];
        _importQueue.maxConcurrentOperationCount = 1;
        _importQueue.name = @"com.vemedio.instacast.backupImport";
    });
    return _importQueue;
}

static void ICBackupSetSkipCurrentFeed(BOOL skip) {
    dispatch_sync(ICBackupImportStateQueue(), ^{
        _skipCurrentFeed = skip;
    });
}

static BOOL ICBackupConsumeSkipCurrentFeed(void) {
    __block BOOL skip = NO;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        skip = _skipCurrentFeed;
        _skipCurrentFeed = NO;
    });
    return skip;
}

static BOOL ICBackupSkipCurrentFeedRequested(void) {
    __block BOOL skip = NO;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        skip = _skipCurrentFeed;
    });
    return skip;
}

static void ICBackupSetDeferredDownloadOwnership(NSString *objectHash, BOOL owned) {
    if (objectHash.length == 0) return;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        if (!_deferredRestoreOwnedObjectHashes) _deferredRestoreOwnedObjectHashes = [NSMutableSet set];
        if (owned) {
            [_deferredRestoreOwnedObjectHashes addObject:objectHash];
        } else {
            [_deferredRestoreOwnedObjectHashes removeObject:objectHash];
        }
    });
}

static BOOL ICBackupOwnsDeferredDownload(NSString *objectHash) {
    if (objectHash.length == 0) return NO;
    __block BOOL owned = NO;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        owned = [_deferredRestoreOwnedObjectHashes containsObject:objectHash];
    });
    return owned;
}

static void ICBackupClearDeferredDownloadOwnership(void) {
    dispatch_sync(ICBackupImportStateQueue(), ^{
        [_deferredRestoreOwnedObjectHashes removeAllObjects];
    });
}

static BOOL ICBackupBeginBookmarkRecovery(void) {
    __block BOOL shouldStart = NO;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        if (!_bookmarkRecoveryScheduled) {
            _bookmarkRecoveryScheduled = YES;
            shouldStart = YES;
        }
    });
    return shouldStart;
}

static void ICBackupEndBookmarkRecovery(void) {
    dispatch_sync(ICBackupImportStateQueue(), ^{
        _bookmarkRecoveryScheduled = NO;
    });
}

static void ICBackupApplyColorHex(NSUserDefaults *defaults, NSString *hexString, NSString *hexKey, NSString *colorDataKey) {
    [UIColor ic_setColorHexString:hexString inDefaults:defaults hexKey:hexKey legacyArchiveKey:colorDataKey];
}

static NSString *ICBackupLegacyFeedSettingType(NSString *key, NSString *value) {
    if ([value isEqualToString:@"true"] || [value isEqualToString:@"false"]) {
        return @"bool";
    }
    if ([key isEqualToString:kUserDefinedFeedName] ||
        [key isEqualToString:kFeedPropertyAutoTranscribe] ||
        [key isEqualToString:kFeedPropertyAutoChapters] ||
        [key isEqualToString:kFeedPropertyAutoSkipSponsors] ||
        [key isEqualToString:@"preferredTranscriptLanguage"] ||
        [key isEqualToString:@"preferredTranscriptURL"] ||
        [key isEqualToString:@"cachedPlayerTintColor"] ||
        [key hasSuffix:@"_auto_skip_chapter_name"]) {
        return @"string";
    }
    if ([key hasSuffix:@"_auto_skip_start_period"] ||
        [key hasSuffix:@"_auto_skip_end_period"] ||
        [key rangeOfString:@"_auto_skip_start_chapter_"].location != NSNotFound ||
        [key rangeOfString:@"_auto_skip_end_chapter_"].location != NSNotFound) {
        return @"double";
    }
    if ([key hasSuffix:@"_old_episode_delete_days"] ||
        [key isEqualToString:PlayerNearChapterEndForwardSkipMode] ||
        [key isEqualToString:PlayerNearChapterEndForwardSkipWindow]) {
        return @"integer";
    }

    id defaultValue = [USER_DEFAULTS objectForKey:key];
    if ([defaultValue isKindOfClass:[NSString class]]) return @"string";
    if ([defaultValue isKindOfClass:[NSNumber class]]) {
        NSNumber *number = defaultValue;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return @"bool";
        NSString *objCType = [NSString stringWithUTF8String:number.objCType];
        if ([objCType isEqualToString:[NSString stringWithUTF8String:@encode(double)]] ||
            [objCType isEqualToString:[NSString stringWithUTF8String:@encode(float)]]) {
            return @"double";
        }
        return @"integer";
    }

    // Old backups have no type metadata. Unknown values stay strings so a URL,
    // chapter name, identifier or future setting can never be destroyed by numeric guessing.
    return @"string";
}

static BOOL ICBackupFeedSettingAlreadyMatches(CDFeedProperty *property,
                                              NSString *type,
                                              NSString *stringValue,
                                              BOOL boolValue,
                                              int32_t integerValue,
                                              double doubleValue) {
    BOOL hasDefaultNonBooleanValues = property.stringValue == nil &&
        property.doubleValue == 0 && property.int32Value == 0;
    if ([type isEqualToString:@"string"]) {
        return [property.stringValue isEqualToString:stringValue] &&
            property.doubleValue == 0 && property.int32Value == 0 && !property.boolValue;
    }
    if ([type isEqualToString:@"double"]) {
        return property.doubleValue == doubleValue && property.stringValue == nil &&
            property.int32Value == 0 && !property.boolValue;
    }
    if ([type isEqualToString:@"integer"]) {
        return property.int32Value == integerValue && property.stringValue == nil &&
            property.doubleValue == 0 && !property.boolValue;
    }
    return property.boolValue == boolValue && hasDefaultNonBooleanValues;
}

static BOOL ICBackupApplyFeedSetting(CDFeed *feed, NSString *key, NSString *type, NSString *value) {
    BOOL boolValue = NO;
    int32_t integerValue = 0;
    double doubleValue = 0;

    if ([type isEqualToString:@"bool"]) {
        if (![value isEqualToString:@"true"] && ![value isEqualToString:@"false"]) return NO;
        boolValue = [value isEqualToString:@"true"];
    } else if ([type isEqualToString:@"integer"]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        scanner.charactersToBeSkipped = nil;
        long long parsedValue = 0;
        if (![scanner scanLongLong:&parsedValue] || !scanner.isAtEnd || parsedValue < INT32_MIN || parsedValue > INT32_MAX) return NO;
        integerValue = (int32_t)parsedValue;
    } else if ([type isEqualToString:@"double"]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        scanner.charactersToBeSkipped = nil;
        if (![scanner scanDouble:&doubleValue] || !scanner.isAtEnd || !isfinite(doubleValue)) return NO;
    } else if (![type isEqualToString:@"string"]) {
        return NO;
    }

    CDFeedProperty *property = [feed propertyForKey:key insertOnDemand:YES];
    if (!property) return NO;
    if (ICBackupFeedSettingAlreadyMatches(property, type, value, boolValue,
                                          integerValue, doubleValue)) {
        return YES;
    }
    property.stringValue = nil;
    property.doubleValue = 0;
    property.int32Value = 0;
    property.boolValue = NO;

    if ([type isEqualToString:@"string"]) {
        property.stringValue = value;
    } else if ([type isEqualToString:@"double"]) {
        property.doubleValue = doubleValue;
    } else if ([type isEqualToString:@"integer"]) {
        property.int32Value = integerValue;
    } else {
        property.boolValue = boolValue;
    }
    return YES;
}

static NSString *ICBackupStringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSNumber *ICBackupNumberValue(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSString *ICBackupBookmarkEpisodeKey(NSString *feedURL, NSString *episodeGuid) {
    if (feedURL.length == 0 || episodeGuid.length == 0) return nil;
    return [NSString stringWithFormat:@"%lu:%@%@", (unsigned long)feedURL.length, feedURL, episodeGuid];
}

static void ICBackupIndexBookmarkPosition(NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *> *bookmarkPositionsByEpisode,
                                          NSString *feedURL,
                                          NSString *episodeGuid,
                                          double position) {
    NSString *episodeKey = ICBackupBookmarkEpisodeKey(feedURL, episodeGuid);
    if (!episodeKey) return;
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *buckets = bookmarkPositionsByEpisode[episodeKey];
    if (!buckets) {
        buckets = [NSMutableDictionary dictionary];
        bookmarkPositionsByEpisode[episodeKey] = buckets;
    }
    NSNumber *bucketKey = @((NSInteger)floor(position));
    NSMutableArray<NSNumber *> *positions = buckets[bucketKey];
    if (!positions) {
        positions = [NSMutableArray array];
        buckets[bucketKey] = positions;
    }
    [positions addObject:@(position)];
}

static BOOL ICBackupBookmarkExistsInIndex(NSDictionary<NSString *, NSDictionary<NSNumber *, NSArray<NSNumber *> *> *> *bookmarkPositionsByEpisode,
                                          NSString *feedURL,
                                          NSString *episodeGuid,
                                          double position) {
    NSString *episodeKey = ICBackupBookmarkEpisodeKey(feedURL, episodeGuid);
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *buckets = episodeKey ? bookmarkPositionsByEpisode[episodeKey] : nil;
    NSInteger centerBucket = (NSInteger)floor(position);
    for (NSInteger bucket = centerBucket - 1; bucket <= centerBucket + 1; bucket++) {
        for (NSNumber *existingPosition in buckets[@(bucket)]) {
            if (fabs(existingPosition.doubleValue - position) <= 1.0) return YES;
        }
    }
    return NO;
}

static NSError *ICBackupBookmarkImportPublicError(NSError *underlyingError) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: @"The bookmark import was interrupted. Saved progress will continue automatically the next time InstacastPlus starts or when you retry the same backup.".ls,
    } mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:@"InstacastBackupImporter" code:3 userInfo:userInfo];
}

static NSError *ICBackupBookmarkRecoveryStateError(NSError *underlyingError) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: @"The bookmark import recovery state could not be read or updated. Check the available storage and try again.".ls,
    } mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:@"InstacastBackupImporter" code:5 userInfo:userInfo];
}

static NSError *ICBackupBookmarkPendingConflictError(void) {
    return [NSError errorWithDomain:@"InstacastBackupImporter"
                               code:6
                           userInfo:@{
        NSLocalizedDescriptionKey: @"An earlier bookmark import still needs to finish. Restart InstacastPlus or retry the same backup before importing another backup.".ls,
    }];
}

static NSError *ICBackupBookmarkInvalidStageError(NSError *underlyingError) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: @"The saved bookmark recovery data is damaged or from an unsupported version. It was set aside. Import the original backup again.".ls,
    } mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:@"InstacastBackupImporter" code:7 userInfo:userInfo];
}

static NSURL *ICBackupBookmarkStageURL(void) {
    NSURL *applicationSupportURL = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                          inDomains:NSUserDomainMask].firstObject;
    NSURL *directoryURL = [applicationSupportURL URLByAppendingPathComponent:ICBackupBookmarkStageDirectoryName
                                                                  isDirectory:YES];
    return [directoryURL URLByAppendingPathComponent:ICBackupBookmarkStageFilename isDirectory:NO];
}

static NSError *ICBackupQuarantineBookmarkStage(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *stageURL = ICBackupBookmarkStageURL();
    if (!stageURL || ![fileManager fileExistsAtPath:stageURL.path]) return nil;
    NSURL *invalidURL = [stageURL.URLByDeletingLastPathComponent
                         URLByAppendingPathComponent:ICBackupBookmarkInvalidStageFilename
                         isDirectory:NO];
    NSError *fileError = nil;
    if ([fileManager fileExistsAtPath:invalidURL.path] &&
        ![fileManager removeItemAtURL:invalidURL error:&fileError]) {
        return ICBackupBookmarkRecoveryStateError(fileError);
    }
    if (![fileManager moveItemAtURL:stageURL toURL:invalidURL error:&fileError]) {
        return ICBackupBookmarkRecoveryStateError(fileError);
    }
    return nil;
}

static NSArray<NSDictionary *> *ICBackupBookmarkRecords(NSArray<ICBackupBookmark *> *bookmarks) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray arrayWithCapacity:bookmarks.count];
    for (ICBackupBookmark *bookmark in bookmarks) {
        if (bookmark.feedURL.length == 0 || bookmark.episodeGuid.length == 0) continue;
        [records addObject:@{
            @"feedURL": bookmark.feedURL,
            @"episodeGuid": bookmark.episodeGuid,
            @"position": @(bookmark.position),
            @"title": bookmark.title ?: @"",
        }];
    }
    return records;
}

static NSArray<ICBackupBookmark *> *ICBackupBookmarksFromRecords(NSArray<NSDictionary *> *records, NSError **error) {
    NSMutableArray<ICBackupBookmark *> *bookmarks = [NSMutableArray arrayWithCapacity:records.count];
    for (id value in records) {
        if (![value isKindOfClass:[NSDictionary class]]) {
            if (error) *error = ICBackupBookmarkInvalidStageError(nil);
            return nil;
        }
        NSDictionary *record = value;
        NSString *feedURL = [record[@"feedURL"] isKindOfClass:[NSString class]] ? record[@"feedURL"] : nil;
        NSString *episodeGuid = [record[@"episodeGuid"] isKindOfClass:[NSString class]] ? record[@"episodeGuid"] : nil;
        NSNumber *position = [record[@"position"] isKindOfClass:[NSNumber class]] ? record[@"position"] : nil;
        NSString *title = [record[@"title"] isKindOfClass:[NSString class]] ? record[@"title"] : nil;
        if (feedURL.length == 0 || episodeGuid.length == 0 || !position || !title) {
            if (error) *error = ICBackupBookmarkInvalidStageError(nil);
            return nil;
        }

        ICBackupBookmark *bookmark = [[ICBackupBookmark alloc] init];
        bookmark.feedURL = feedURL;
        bookmark.episodeGuid = episodeGuid;
        bookmark.position = position.doubleValue;
        bookmark.title = title;
        [bookmarks addObject:bookmark];
    }
    return bookmarks;
}

static NSArray<NSDictionary *> *ICBackupReadBookmarkStage(BOOL *stageExists,
                                                           BOOL *stageCancelled,
                                                           BOOL *stageInvalid,
                                                           NSError **error) {
    NSURL *stageURL = ICBackupBookmarkStageURL();
    BOOL exists = stageURL && [[NSFileManager defaultManager] fileExistsAtPath:stageURL.path];
    if (stageExists) *stageExists = exists;
    if (stageCancelled) *stageCancelled = NO;
    if (stageInvalid) *stageInvalid = NO;
    if (!exists) return nil;

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:stageURL options:0 error:&readError];
    if (!data) {
        if (error) *error = ICBackupBookmarkRecoveryStateError(readError);
        return nil;
    }
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id propertyList = [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListImmutable
                                                                  format:&format
                                                                   error:&readError];
    NSDictionary *root = [propertyList isKindOfClass:[NSDictionary class]] ? propertyList : nil;
    NSArray *records = [root[@"bookmarks"] isKindOfClass:[NSArray class]] ? root[@"bookmarks"] : nil;
    NSString *state = [root[@"state"] isKindOfClass:[NSString class]] ? root[@"state"] : nil;
    BOOL validState = [state isEqualToString:ICBackupBookmarkStageStateActive] ||
                      [state isEqualToString:ICBackupBookmarkStageStateCancelled];
    if (!root || ![root[@"version"] isEqual:@1] || !records || !validState) {
        if (stageInvalid) *stageInvalid = YES;
        if (error) *error = ICBackupBookmarkInvalidStageError(readError);
        return nil;
    }
    if (stageCancelled) *stageCancelled = [state isEqualToString:ICBackupBookmarkStageStateCancelled];
    return records;
}

static BOOL ICBackupWriteBookmarkStage(NSArray<NSDictionary *> *records,
                                       NSString *state,
                                       NSError **error) {
    NSURL *stageURL = ICBackupBookmarkStageURL();
    NSURL *directoryURL = stageURL.URLByDeletingLastPathComponent;
    NSError *writeError = nil;
    if (!stageURL || ![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                               withIntermediateDirectories:YES
                                                                attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                                     error:&writeError]) {
        if (error) *error = ICBackupBookmarkRecoveryStateError(writeError);
        return NO;
    }
    [directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{
        @"version": @1,
        @"state": state,
        @"bookmarks": records,
    } format:NSPropertyListBinaryFormat_v1_0 options:0 error:&writeError];
    NSDataWritingOptions options = NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
    if (!data || ![data writeToURL:stageURL options:options error:&writeError]) {
        if (error) *error = ICBackupBookmarkRecoveryStateError(writeError);
        return NO;
    }
    [stageURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return YES;
}

static BOOL ICBackupPrepareBookmarkStage(NSArray<ICBackupBookmark *> *bookmarks, NSError **error) {
    NSArray<NSDictionary *> *records = ICBackupBookmarkRecords(bookmarks);
    BOOL stageExists = NO;
    BOOL stageCancelled = NO;
    BOOL stageInvalid = NO;
    NSError *readError = nil;
    NSArray<NSDictionary *> *pendingRecords = ICBackupReadBookmarkStage(&stageExists,
                                                                         &stageCancelled,
                                                                         &stageInvalid,
                                                                         &readError);
    if (stageExists) {
        if (!pendingRecords) {
            if (stageInvalid) {
                NSError *quarantineError = ICBackupQuarantineBookmarkStage();
                if (quarantineError) {
                    if (error) *error = quarantineError;
                    return NO;
                }
                if (error) *error = readError;
                return NO;
            }
            if (error) *error = readError ?: ICBackupBookmarkRecoveryStateError(nil);
            return NO;
        }
        if (stageCancelled) {
            if (records.count == 0) return YES;
            return ICBackupWriteBookmarkStage(records, ICBackupBookmarkStageStateActive, error);
        }
        if (![pendingRecords isEqualToArray:records]) {
            if (error) *error = ICBackupBookmarkPendingConflictError();
            return NO;
        }
        return YES;
    }
    if (records.count == 0) return YES;
    return ICBackupWriteBookmarkStage(records, ICBackupBookmarkStageStateActive, error);
}

static NSError *ICBackupMarkBookmarkStageCancelled(NSArray<ICBackupBookmark *> *bookmarks) {
    NSURL *stageURL = ICBackupBookmarkStageURL();
    if (!stageURL || ![[NSFileManager defaultManager] fileExistsAtPath:stageURL.path]) return nil;
    NSError *writeError = nil;
    if (!ICBackupWriteBookmarkStage(ICBackupBookmarkRecords(bookmarks),
                                    ICBackupBookmarkStageStateCancelled,
                                    &writeError)) {
        return writeError;
    }
    return nil;
}

static NSError *ICBackupRemoveBookmarkStage(void) {
    NSURL *stageURL = ICBackupBookmarkStageURL();
    if (!stageURL || ![[NSFileManager defaultManager] fileExistsAtPath:stageURL.path]) return nil;
    NSError *removeError = nil;
    if (![[NSFileManager defaultManager] removeItemAtURL:stageURL error:&removeError]) {
        return ICBackupBookmarkRecoveryStateError(removeError);
    }
    return nil;
}

static void ICBackupPresentBookmarkRecoveryError(NSError *error) {
    if (!error) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (App.applicationState != UIApplicationStateActive) return;
        [App showBackgroundErrorWithTitle:@"Bookmark Import Could Not Continue".ls
                                  message:error.localizedDescription
                                 duration:8.0];
    });
}

static NSError *ICBackupDownloadRecoveryStateError(NSError *underlyingError) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: @"The pending episode downloads from the backup could not be read or updated. Check the available storage and try again.".ls,
    } mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:@"InstacastBackupImporter" code:8 userInfo:userInfo];
}

static void ICBackupPresentDeferredRestoreError(NSError *error) {
    if (!error) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (App.applicationState != UIApplicationStateActive) return;
        [App showBackgroundErrorWithTitle:@"Backup Restore Could Not Continue".ls
                                  message:error.localizedDescription
                                 duration:8.0];
    });
}

static NSURL *ICBackupDownloadStageURL(void) {
    NSURL *applicationSupportURL = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                          inDomains:NSUserDomainMask].firstObject;
    NSURL *directoryURL = [applicationSupportURL URLByAppendingPathComponent:ICBackupBookmarkStageDirectoryName
                                                                  isDirectory:YES];
    return [directoryURL URLByAppendingPathComponent:ICBackupDownloadStageFilename isDirectory:NO];
}

static NSArray<NSDictionary *> *ICBackupCanonicalPendingDownloads(id value, NSError **error) {
    if (!value) return @[];
    if (![value isKindOfClass:[NSArray class]]) {
        if (error) *error = ICBackupDownloadRecoveryStateError(nil);
        return nil;
    }

    NSMutableArray<NSDictionary *> *downloads = [NSMutableArray array];
    for (id rawEntry in (NSArray *)value) {
        if (![rawEntry isKindOfClass:[NSDictionary class]]) {
            if (error) *error = ICBackupDownloadRecoveryStateError(nil);
            return nil;
        }
        NSString *feedURL = [rawEntry[@"feedURL"] isKindOfClass:[NSString class]] ? rawEntry[@"feedURL"] : nil;
        NSArray *rawGUIDs = [rawEntry[@"guids"] isKindOfClass:[NSArray class]] ? rawEntry[@"guids"] : nil;
        if (feedURL.length == 0 || !rawGUIDs) {
            if (error) *error = ICBackupDownloadRecoveryStateError(nil);
            return nil;
        }

        NSMutableOrderedSet<NSString *> *guids = [NSMutableOrderedSet orderedSet];
        for (id rawGUID in rawGUIDs) {
            if (![rawGUID isKindOfClass:[NSString class]] || [rawGUID length] == 0) {
                if (error) *error = ICBackupDownloadRecoveryStateError(nil);
                return nil;
            }
            [guids addObject:rawGUID];
        }
        if (guids.count > 0) {
            [downloads addObject:@{ @"feedURL": feedURL, @"guids": guids.array }];
        }
    }
    return downloads;
}

static NSArray<NSDictionary *> *ICBackupMergePendingDownloads(NSArray<NSDictionary *> *first,
                                                               NSArray<NSDictionary *> *second) {
    NSMutableArray<NSString *> *feedOrder = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSString *> *> *guidsByFeed = [NSMutableDictionary dictionary];
    for (NSArray<NSDictionary *> *downloads in @[first ?: @[], second ?: @[]]) {
        for (NSDictionary *entry in downloads) {
            NSString *feedURL = entry[@"feedURL"];
            NSMutableOrderedSet<NSString *> *guids = guidsByFeed[feedURL];
            if (!guids) {
                guids = [NSMutableOrderedSet orderedSet];
                guidsByFeed[feedURL] = guids;
                [feedOrder addObject:feedURL];
            }
            [guids addObjectsFromArray:entry[@"guids"]];
        }
    }

    NSMutableArray<NSDictionary *> *merged = [NSMutableArray arrayWithCapacity:feedOrder.count];
    for (NSString *feedURL in feedOrder) {
        NSArray<NSString *> *guids = guidsByFeed[feedURL].array;
        if (guids.count > 0) {
            [merged addObject:@{ @"feedURL": feedURL, @"guids": guids }];
        }
    }
    return merged;
}

static NSArray<NSDictionary *> *ICBackupReadDownloadStage(BOOL *stageExists, NSError **error) {
    NSURL *stageURL = ICBackupDownloadStageURL();
    BOOL exists = stageURL && [[NSFileManager defaultManager] fileExistsAtPath:stageURL.path];
    if (stageExists) *stageExists = exists;
    if (!exists) return @[];

    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:stageURL options:0 error:&readError];
    if (!data) {
        if (error) *error = ICBackupDownloadRecoveryStateError(readError);
        return nil;
    }
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    id propertyList = [NSPropertyListSerialization propertyListWithData:data
                                                                 options:NSPropertyListImmutable
                                                                  format:&format
                                                                   error:&readError];
    NSDictionary *root = [propertyList isKindOfClass:[NSDictionary class]] ? propertyList : nil;
    if (!root || ![root[@"version"] isEqual:@1]) {
        if (error) *error = ICBackupDownloadRecoveryStateError(readError);
        return nil;
    }
    return ICBackupCanonicalPendingDownloads(root[@"downloads"], error);
}

static BOOL ICBackupWriteDownloadStage(NSArray<NSDictionary *> *downloads, NSError **error) {
    NSURL *stageURL = ICBackupDownloadStageURL();
    if (!stageURL) {
        if (error) *error = ICBackupDownloadRecoveryStateError(nil);
        return NO;
    }

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (downloads.count == 0) {
        if (![fileManager fileExistsAtPath:stageURL.path]) return YES;
        NSError *removeError = nil;
        if (![fileManager removeItemAtURL:stageURL error:&removeError]) {
            if (error) *error = ICBackupDownloadRecoveryStateError(removeError);
            return NO;
        }
        return YES;
    }

    NSURL *directoryURL = stageURL.URLByDeletingLastPathComponent;
    NSError *writeError = nil;
    if (![fileManager createDirectoryAtURL:directoryURL
               withIntermediateDirectories:YES
                                attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                     error:&writeError]) {
        if (error) *error = ICBackupDownloadRecoveryStateError(writeError);
        return NO;
    }
    [directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{
        @"version": @1,
        @"downloads": downloads,
    } format:NSPropertyListBinaryFormat_v1_0 options:0 error:&writeError];
    NSDataWritingOptions options = NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
    if (!data || ![data writeToURL:stageURL options:options error:&writeError]) {
        if (error) *error = ICBackupDownloadRecoveryStateError(writeError);
        return NO;
    }
    [stageURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return YES;
}

static NSURL *ICBackupDownloadCancellationDirectoryURL(void) {
    NSURL *stageURL = ICBackupDownloadStageURL();
    return [stageURL.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:ICBackupDownloadCancellationDirectoryName
            isDirectory:YES];
}

static BOOL ICBackupWriteDownloadCancellationTombstone(NSString *objectHash,
                                                       NSString *feedURL,
                                                       NSString *episodeGUID,
                                                       NSError **error) {
    NSCAssert(![NSThread isMainThread], @"Download cancellation persistence must stay off the main thread");
    if (objectHash.length == 0) return YES;

    NSURL *directoryURL = ICBackupDownloadCancellationDirectoryURL();
    NSError *writeError = nil;
    if (!directoryURL || ![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                                    withIntermediateDirectories:YES
                                                                     attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                                          error:&writeError]) {
        if (error) *error = ICBackupDownloadRecoveryStateError(writeError);
        return NO;
    }
    [directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

    NSString *filename = [[objectHash MD5Hash] stringByAppendingPathExtension:@"cancel"];
    NSURL *tombstoneURL = [directoryURL URLByAppendingPathComponent:filename isDirectory:NO];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:@{
        @"version": @1,
        @"objectHash": objectHash,
        @"feedURL": feedURL ?: @"",
        @"episodeGUID": episodeGUID ?: @"",
    } format:NSPropertyListBinaryFormat_v1_0 options:0 error:&writeError];
    NSDataWritingOptions options = NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication;
    if (!data || ![data writeToURL:tombstoneURL options:options error:&writeError]) {
        if (error) *error = ICBackupDownloadRecoveryStateError(writeError);
        return NO;
    }
    [tombstoneURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return YES;
}

static NSDictionary<NSString *, NSDictionary *> *ICBackupReadDownloadCancellationTombstones(NSError **error) {
    NSURL *directoryURL = ICBackupDownloadCancellationDirectoryURL();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (!directoryURL || ![fileManager fileExistsAtPath:directoryURL.path]) {
        return @{};
    }

    NSError *readError = nil;
    NSArray<NSURL *> *files = [fileManager contentsOfDirectoryAtURL:directoryURL
                                         includingPropertiesForKeys:nil
                                                            options:NSDirectoryEnumerationSkipsHiddenFiles
                                                              error:&readError];
    if (!files) {
        if (error) *error = ICBackupDownloadRecoveryStateError(readError);
        return nil;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *tombstonesByObjectHash = [NSMutableDictionary dictionary];
    for (NSURL *fileURL in files) {
        if (![fileURL.pathExtension isEqualToString:@"cancel"]) continue;
        NSData *data = [NSData dataWithContentsOfURL:fileURL options:0 error:&readError];
        NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
        id propertyList = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                            options:NSPropertyListImmutable
                                                                             format:&format
                                                                              error:&readError] : nil;
        NSDictionary *root = [propertyList isKindOfClass:[NSDictionary class]] ? propertyList : nil;
        NSString *objectHash = [root[@"objectHash"] isKindOfClass:[NSString class]] ? root[@"objectHash"] : nil;
        NSString *feedURL = [root[@"feedURL"] isKindOfClass:[NSString class]] ? root[@"feedURL"] : nil;
        NSString *episodeGUID = [root[@"episodeGUID"] isKindOfClass:[NSString class]] ? root[@"episodeGUID"] : nil;
        if (!root || ![root[@"version"] isEqual:@1] || objectHash.length == 0 || !feedURL || !episodeGUID) {
            if (error) *error = ICBackupDownloadRecoveryStateError(readError);
            return nil;
        }
        tombstonesByObjectHash[objectHash] = @{
            @"URL": fileURL,
            @"feedURL": feedURL,
            @"episodeGUID": episodeGUID,
        };
    }
    return tombstonesByObjectHash;
}

static BOOL ICBackupRemoveDownloadCancellationTombstones(NSArray<NSURL *> *tombstoneURLs, NSError **error) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSURL *fileURL in tombstoneURLs) {
        NSError *removeError = nil;
        if ([fileManager fileExistsAtPath:fileURL.path] && ![fileManager removeItemAtURL:fileURL error:&removeError]) {
            if (error) *error = ICBackupDownloadRecoveryStateError(removeError);
            return NO;
        }
    }
    return YES;
}

static NSArray<NSDictionary *> *ICBackupMigrateLegacyPendingDownloads(NSError **error) {
    id legacyValue = [USER_DEFAULTS objectForKey:kPendingBackupDownloadsKey];
    BOOL stageExists = NO;
    NSArray<NSDictionary *> *stagedDownloads = ICBackupReadDownloadStage(&stageExists, error);
    if (stageExists && !stagedDownloads) return nil;
    if (!legacyValue) return stagedDownloads ?: @[];

    NSError *validationError = nil;
    NSArray<NSDictionary *> *legacyDownloads = ICBackupCanonicalPendingDownloads(legacyValue, &validationError);
    if (!legacyDownloads) {
        if (error) *error = validationError;
        return nil;
    }
    NSArray<NSDictionary *> *merged = ICBackupMergePendingDownloads(stagedDownloads, legacyDownloads);
    NSError *writeError = nil;
    if (!ICBackupWriteDownloadStage(merged, &writeError)) {
        if (error) *error = writeError;
        return nil;
    }
    [USER_DEFAULTS removeObjectForKey:kPendingBackupDownloadsKey];
    return merged;
}

static BOOL ICBackupAppendPendingDownloads(NSArray<NSDictionary *> *downloads, NSError **error) {
    if (downloads.count == 0) return YES;
    NSArray<NSDictionary *> *existing = ICBackupMigrateLegacyPendingDownloads(error);
    if (!existing) return NO;
    return ICBackupWriteDownloadStage(ICBackupMergePendingDownloads(existing, downloads), error);
}

static NSString *ICBackupDeferredEpisodeKey(NSManagedObjectID *feedObjectID, NSString *guid) {
    NSString *feedIdentifier = feedObjectID.URIRepresentation.absoluteString;
    if (feedIdentifier.length == 0 || guid.length == 0) return nil;
    return [NSString stringWithFormat:@"%lu:%@%@", (unsigned long)feedIdentifier.length, feedIdentifier, guid];
}

static NSString *ICBackupPendingDownloadKey(NSString *feedURL, NSString *guid) {
    if (feedURL.length == 0 || guid.length == 0) return nil;
    return [NSString stringWithFormat:@"%lu:%@%@", (unsigned long)feedURL.length, feedURL, guid];
}

static NSArray<NSDictionary *> *ICBackupRemainingDownloadsWithFairInspectionOrder(
    NSArray<NSDictionary *> *untouchedDownloads,
    NSArray<NSDictionary *> *selectedDownloads,
    NSSet<NSString *> *resolvedDownloadKeys,
    NSSet<NSString *> *inspectedDownloadKeys
) {
    NSMutableArray<NSDictionary *> *remainingDownloads = [untouchedDownloads mutableCopy];
    NSMutableArray<NSDictionary *> *inspectedRemainingDownloads = [NSMutableArray array];
    for (NSDictionary *entry in selectedDownloads) {
        NSString *feedURL = entry[@"feedURL"];
        NSMutableArray<NSString *> *uninspectedGUIDs = [NSMutableArray array];
        NSMutableArray<NSString *> *inspectedGUIDs = [NSMutableArray array];
        for (NSString *guid in entry[@"guids"]) {
            NSString *pendingKey = ICBackupPendingDownloadKey(feedURL, guid);
            if ([resolvedDownloadKeys containsObject:pendingKey]) continue;
            if ([inspectedDownloadKeys containsObject:pendingKey]) {
                [inspectedGUIDs addObject:guid];
            } else {
                [uninspectedGUIDs addObject:guid];
            }
        }
        if (uninspectedGUIDs.count > 0) {
            [remainingDownloads addObject:@{ @"feedURL": feedURL, @"guids": uninspectedGUIDs }];
        }
        if (inspectedGUIDs.count > 0) {
            [inspectedRemainingDownloads addObject:@{ @"feedURL": feedURL, @"guids": inspectedGUIDs }];
        }
    }
    [remainingDownloads addObjectsFromArray:inspectedRemainingDownloads];
    return remainingDownloads;
}

static NSSet<NSString *> *ICBackupEquivalentFeedURLSet(NSArray<NSString *> *feedURLs) {
    NSMutableSet<NSString *> *equivalentURLs = [NSMutableSet set];
    for (NSString *feedURL in feedURLs) {
        [equivalentURLs addObjectsFromArray:[DatabaseManager equivalentFeedURLStringsForURLString:feedURL]];
    }
    return equivalentURLs;
}

static BOOL ICBackupFeedURLMatchesScope(NSString *feedURL, NSSet<NSString *> *scope) {
    if (!scope) return YES;
    for (NSString *equivalentURL in [DatabaseManager equivalentFeedURLStringsForURLString:feedURL]) {
        if ([scope containsObject:equivalentURL]) return YES;
    }
    return NO;
}

static NSError *ICBackupImportPersistenceError(NSError *underlyingError) {
    NSMutableDictionary *userInfo = [@{
        NSLocalizedDescriptionKey: @"The imported data could not be saved. The import was stopped and may have been applied only partially. Check the available storage and try again.".ls,
    } mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:@"InstacastBackupImporter" code:4 userInfo:userInfo];
}

static NSError *ICBackupSaveMainContext(void) {
    NSError *saveError = [DMANAGER saveReturningError];
    if (!saveError) return nil;
    if (DMANAGER.objectContext.hasChanges) {
        [DMANAGER.objectContext rollback];
    }
    return ICBackupImportPersistenceError(saveError);
}

#pragma mark - Helper: run block on main thread synchronously (from background)

static void runOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

@interface InstacastBackupImporter ()
+ (NSInteger)_importBookmarks:(NSArray<ICBackupBookmark *> *)bookmarks
                    operation:(NSOperation *)operation
                        error:(NSError **)error;
+ (void)_scheduleDeferredRestoreForFeedURL:(nullable NSString *)feedURL;
+ (void)_processPendingDeferredRestoreForFeedURLs:(nullable NSSet<NSString *> *)feedURLs;
@end

@implementation InstacastBackupImporter

#pragma mark - Cancel

+ (void)cancelImport {
    [_currentOperation cancel];
    // The import loop cancels only its current feed job when it observes this flag.
    // A global cancel here also destroyed unrelated hydration already in progress
    // before the import started.
}

+ (void)skipCurrentFeed {
    ICBackupSetSkipCurrentFeed(YES);
}

+ (void)resumePendingBookmarkImportIfNeeded {
    if (!ICBackupBeginBookmarkRecovery()) return;
    NSBlockOperation *recoveryOperation = [NSBlockOperation blockOperationWithBlock:^{
        void (^finishAttempt)(NSError *) = ^(NSError *visibleError) {
            if (visibleError) ICBackupPresentBookmarkRecoveryError(visibleError);
            ICBackupEndBookmarkRecovery();
        };
        if (!App.protectedDataAvailable) {
            finishAttempt(nil);
            return;
        }

        BOOL stageExists = NO;
        BOOL stageCancelled = NO;
        BOOL stageInvalid = NO;
        NSError *readError = nil;
        NSArray<NSDictionary *> *records = ICBackupReadBookmarkStage(&stageExists,
                                                                      &stageCancelled,
                                                                      &stageInvalid,
                                                                      &readError);
        if (!stageExists) {
            finishAttempt(nil);
            return;
        }
        if (!records) {
            ErrLog(@"Could not read pending bookmark import: %@", readError);
            if (stageInvalid) {
                if (App.applicationState != UIApplicationStateActive) {
                    finishAttempt(nil);
                    return;
                }
                NSError *quarantineError = ICBackupQuarantineBookmarkStage();
                finishAttempt(quarantineError ?: readError);
            } else {
                finishAttempt(readError);
            }
            return;
        }
        if (stageCancelled) {
            NSError *cleanupError = ICBackupRemoveBookmarkStage();
            if (cleanupError) ErrLog(@"Could not delete cancelled bookmark import stage: %@", cleanupError);
            finishAttempt(nil);
            return;
        }

        NSError *decodeError = nil;
        NSArray<ICBackupBookmark *> *bookmarks = ICBackupBookmarksFromRecords(records, &decodeError);
        if (!bookmarks) {
            ErrLog(@"Could not decode pending bookmark import: %@", decodeError);
            if (App.applicationState != UIApplicationStateActive) {
                finishAttempt(nil);
                return;
            }
            NSError *quarantineError = ICBackupQuarantineBookmarkStage();
            finishAttempt(quarantineError ?: decodeError);
            return;
        }

        NSError *importError = nil;
        [self _importBookmarks:bookmarks operation:nil error:&importError];
        if (importError) {
            ErrLog(@"Could not resume pending bookmark import: %@", importError);
            finishAttempt(importError);
            return;
        }

        NSError *cleanupError = ICBackupRemoveBookmarkStage();
        if (cleanupError) {
            ErrLog(@"Could not finish pending bookmark import recovery: %@", cleanupError);
            finishAttempt(cleanupError);
            return;
        }
        DebugLog(@"Resumed pending bookmark import");
        finishAttempt(nil);
    }];
    recoveryOperation.qualityOfService = NSQualityOfServiceUtility;
    [ICBackupImportQueue() addOperation:recoveryOperation];
}

#pragma mark - Deferred Restore Lifecycle

+ (void)startDeferredRestoreRecovery {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSArray<NSString *> *names = @[
            EpisodeLoadingManagerDidLoadBatchNotification,
            EpisodeLoadingManagerDidFinishLoadingNotification,
        ];
        for (NSString *name in names) {
            [center addObserverForName:name
                                object:[EpisodeLoadingManager sharedManager]
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                CDFeed *feed = [note.userInfo[@"feed"] isKindOfClass:[CDFeed class]] ? note.userInfo[@"feed"] : nil;
                NSString *feedURL = feed.sourceURL.absoluteString;
                if (feedURL.length > 0) {
                    [InstacastBackupImporter _scheduleDeferredRestoreForFeedURL:feedURL];
                }
            }];
        }
        [center addObserverForName:CacheManagerDidFinishCachingEpisodeNotification
                            object:[CacheManager sharedCacheManager]
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
            CDEpisode *episode = [note.userInfo[@"episode"] isKindOfClass:[CDEpisode class]] ? note.userInfo[@"episode"] : nil;
            NSString *feedURL = episode.feed.sourceURL.absoluteString;
            if (feedURL.length > 0) {
                [InstacastBackupImporter _scheduleDeferredRestoreForFeedURL:feedURL];
            }
        }];
        [center addObserverForName:CacheManagerDidFinishBuildingCacheIndexNotification
                            object:[CacheManager sharedCacheManager]
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
            [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
        }];
    });
    [self retryPendingDeferredRestoreIfNeeded];
}

+ (void)retryPendingDeferredRestoreIfNeeded {
    [self _scheduleDeferredRestoreForFeedURL:nil];
}

+ (void)_scheduleDeferredRestoreForFeedURL:(NSString *)feedURL {
    __block BOOL shouldStart = NO;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        if (feedURL.length > 0) {
            if (!_deferredRestoreFeedURLs) _deferredRestoreFeedURLs = [NSMutableSet set];
            [_deferredRestoreFeedURLs addObject:feedURL];
        } else {
            _deferredRestoreAllFeeds = YES;
            [_deferredRestoreFeedURLs removeAllObjects];
        }
        if (!_deferredRestoreScheduled) {
            _deferredRestoreScheduled = YES;
            shouldStart = YES;
        }
    });
    if (!shouldStart) return;

    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        while (YES) {
            __block BOOL allFeeds = NO;
            __block NSSet<NSString *> *requestedFeedURLs = nil;
            dispatch_sync(ICBackupImportStateQueue(), ^{
                allFeeds = _deferredRestoreAllFeeds;
                requestedFeedURLs = [_deferredRestoreFeedURLs copy];
                _deferredRestoreAllFeeds = NO;
                [_deferredRestoreFeedURLs removeAllObjects];
            });

            if (App.protectedDataAvailable) {
                [self _processPendingDeferredRestoreForFeedURLs:allFeeds ? nil : requestedFeedURLs];
            }

            __block BOOL needsAnotherPass = NO;
            dispatch_sync(ICBackupImportStateQueue(), ^{
                needsAnotherPass = _deferredRestoreAllFeeds || _deferredRestoreFeedURLs.count > 0;
                if (!needsAnotherPass) _deferredRestoreScheduled = NO;
            });
            if (!needsAnotherPass) break;
        }
    }];
    operation.qualityOfService = NSQualityOfServiceUtility;
    [ICBackupImportQueue() addOperation:operation];
}

+ (void)prepareForDeferredDownloadClearAllWithCompletion:(void (^)(NSError *error))completion {
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        NSError *error = nil;
        NSArray<NSDictionary *> *pendingDownloads = ICBackupMigrateLegacyPendingDownloads(&error);
        if (!pendingDownloads) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(error);
            });
            return;
        }

        NSDictionary<NSString *, NSDictionary *> *cancellationTombstones = ICBackupReadDownloadCancellationTombstones(&error);
        if (!cancellationTombstones) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(error);
            });
            return;
        }

        BOOL stageUpdated = ICBackupWriteDownloadStage(@[], &error);
        if (!stageUpdated) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(error);
            });
            return;
        }
        ICBackupClearDeferredDownloadOwnership();

        NSMutableArray<NSURL *> *tombstoneURLs = [NSMutableArray arrayWithCapacity:cancellationTombstones.count];
        for (NSDictionary *record in cancellationTombstones.allValues) {
            NSURL *URL = record[@"URL"];
            if (URL) [tombstoneURLs addObject:URL];
        }
        if (!ICBackupRemoveDownloadCancellationTombstones(tombstoneURLs, &error)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(error);
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil);
        });
    }];
    operation.qualityOfService = NSQualityOfServiceUtility;
    [ICBackupImportQueue() addOperation:operation];
}

+ (void)prepareForDeferredDownloadCancellation:(NSString *)objectHash
                                       feedURL:(NSString *)feedURL
                                    episodeGUID:(NSString *)episodeGUID
                                     completion:(void(^)(NSError *error))completion {
    NSString *stableObjectHash = [objectHash copy];
    NSString *stableFeedURL = [feedURL copy];
    NSString *stableEpisodeGUID = [episodeGUID copy];
    NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{
        NSError *error = nil;
        NSURL *stageURL = ICBackupDownloadStageURL();
        BOOL hasDownloadStage = [stageURL.path length] > 0 && [[NSFileManager defaultManager] fileExistsAtPath:stageURL.path];
        hasDownloadStage = hasDownloadStage ||
                                [USER_DEFAULTS objectForKey:kPendingBackupDownloadsKey] != nil;
        if (hasDownloadStage) {
            ICBackupWriteDownloadCancellationTombstone(stableObjectHash,
                                                        stableFeedURL,
                                                        stableEpisodeGUID,
                                                        &error);
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(error);
            });
        }
    }];
    operation.qualityOfService = NSQualityOfServiceUtility;
    [ICBackupImportQueue() addOperation:operation];
}

+ (BOOL)ownsDeferredDownloadWithObjectHash:(NSString *)objectHash {
    return ICBackupOwnsDeferredDownload(objectHash);
}

#pragma mark - Main Entry Point

+ (void)importBackup:(InstacastBackupData *)backup
          categories:(ICBackupImportCategory)categories
           callbacks:(ICBackupImportCallbacks)callbacks
          completion:(void(^)(NSInteger importedCount, NSInteger queuedDownloadCount, NSError *error))completion
{
    if (categories == 0) {
        if (completion) completion(0, 0, nil);
        return;
    }

    ICBackupSetSkipCurrentFeed(NO);
    _guidIndexByFeedURL = nil;
    _episodeTitleByFeedURL = nil;

    // Copy all callback blocks (C struct doesn't auto-copy)
    ICBackupImportCallbacks cb = {
        .setCurrentFeed   = [callbacks.setCurrentFeed copy],
        .setFeedProgress  = [callbacks.setFeedProgress copy],
        .setFeedCompleted = [callbacks.setFeedCompleted copy],
        .setFeedError     = [callbacks.setFeedError copy],
        .setFeedSkipped   = [callbacks.setFeedSkipped copy],
        .setTotalProgress = [callbacks.setTotalProgress copy],
        .setStatusText    = [callbacks.setStatusText copy],
        .setMetadataActive    = [callbacks.setMetadataActive copy],
        .setMetadataCompleted = [callbacks.setMetadataCompleted copy],
        .setMetadataQueued    = [callbacks.setMetadataQueued copy],
    };

    // Create import queue (serial, one operation at a time)
    ICBackupImportQueue();

    // Cancel any previous import
    [_currentOperation cancel];

    // Determine which podcasts are new
    __block NSMutableArray<ICBackupPodcast *> *newPodcasts = nil;
    runOnMain(^{
        newPodcasts = [NSMutableArray array];
        if (categories & ICBackupImportNewPodcasts) {
            for (ICBackupPodcast *podcast in backup.podcasts) {
                if (!podcast.feedURL) continue;
                NSURL *url = [NSURL URLWithString:podcast.feedURL];
                if (url && ![DMANAGER feedWithSourceURL:url]) {
                    [newPodcasts addObject:podcast];
                }
            }
        }
    });

    // Create the import operation
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    _currentOperation = operation;

    __weak NSBlockOperation *weakOp = operation;

    [operation addExecutionBlock:^{
        NSBlockOperation *op = weakOp;
        if (!op || op.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:0 queuedDownloadCount:0 wasCancelled:YES terminalError:nil completion:completion];
            });
            return;
        }

        // Suspend ELM during entire import — we do episode loading ourselves
        runOnMain(^{
            [EpisodeLoadingManager sharedManager].suspended = YES;
            if (cb.setStatusText) cb.setStatusText(@"Subscribing podcasts…".ls);
        });

        __block NSInteger totalImported = 0;
        __block NSInteger queuedDownloadCount = 0;
        __block NSError *terminalError = nil;
        NSMutableArray<CDFeed *> *subscribedFeeds = [NSMutableArray array];
        NSInteger feedCount = newPodcasts.count;

        // ═══════════════════════════════════════════════════════
        // PHASE A: Subscribe feeds — ONE AT A TIME, synchronous
        // ═══════════════════════════════════════════════════════

        for (NSInteger i = 0; i < feedCount; i++) {
            if (op.isCancelled) break;

            ICBackupPodcast *podcast = newPodcasts[i];
            NSString *title = podcast.title ?: podcast.feedURL;
            NSURL *url = [NSURL URLWithString:podcast.feedURL];

            // UI: show which feed is being subscribed
            // Phase A uses 0–98% of progress (it's 99% of total time)
            runOnMain(^{
                if (cb.setCurrentFeed) cb.setCurrentFeed(title, i, feedCount);
                float progress = (float)i / (float)MAX(feedCount, 1) * 0.98;
                if (cb.setTotalProgress) cb.setTotalProgress(progress);
            });

            if (!url) {
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, @"Invalid URL");
                });
                continue;
            }

            if (ICBackupConsumeSkipCurrentFeed()) {
                runOnMain(^{
                    if (cb.setFeedSkipped) cb.setFeedSkipped(i);
                });
                continue;
            }

            // Subscribe synchronously using semaphore
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block CDFeed *subscribedFeed = nil;
            __block NSError *subscribeError = nil;

            NSString *username = podcast.username;
            NSString *password = podcast.password;

            runOnMain(^{
                SubscriptionManager *sm = [SubscriptionManager sharedSubscriptionManager];
                [sm subscribeFeedWithURL:url username:username password:password options:kSubscribeOptionDontManageConsumedFlags completion:^(CDFeed *feed, NSError *error) {
                    subscribedFeed = feed;
                    subscribeError = error;
                    dispatch_semaphore_signal(sem);
                }];
            });

            // Wait for subscribe completion (timeout 25s, poll every 200ms for cancel)
            long result = -1;
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:25];
            while (result != 0 && !op.isCancelled && [deadline timeIntervalSinceNow] > 0) {
                result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)));
            }

            if (op.isCancelled) break;

            if (ICBackupConsumeSkipCurrentFeed()) {
                runOnMain(^{
                    if (cb.setFeedSkipped) cb.setFeedSkipped(i);
                });
                continue;
            }

            if (result != 0) {
                // Timeout
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, @"Timeout");
                });
                continue;
            }

            if (subscribeError) {
                NSString *errorMsg = subscribeError.localizedDescription;
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, errorMsg);
                });
                continue;
            }

            if (!subscribedFeed) {
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, @"Unknown error");
                });
                continue;
            }

            // Apply backup metadata on main thread
            runOnMain(^{
                subscribedFeed.parked = podcast.parked;
                subscribedFeed.rank = podcast.rank;
                if (podcast.username.length > 0) subscribedFeed.username = podcast.username;
                if (podcast.password.length > 0) subscribedFeed.password = podcast.password;
                terminalError = ICBackupSaveMainContext();

                // Pre-load podcast theme image so it's available when the subscription list appears
                if (!terminalError && subscribedFeed.imageURL) {
                    [ImageCacheManager loadImageForURL:subscribedFeed.imageURL
                                                 size:88
                                            grayscale:NO
                                           completion:nil];
                }
            });
            if (terminalError) {
                runOnMain(^{
                    [[EpisodeLoadingManager sharedManager] cancelLoadingForFeed:subscribedFeed];
                });
                break;
            }

            [subscribedFeeds addObject:subscribedFeed];
            totalImported++;

            // UI: show initial episode count
            __block NSInteger initialEpCount = 0;
            runOnMain(^{
                initialEpCount = subscribedFeed.episodes.count;
                if (cb.setFeedProgress) cb.setFeedProgress(i, 0.2,
                    [NSString stringWithFormat:@"%ld", (long)initialEpCount]);
            });

            // ═════════════════════════════════════════════════
            // EPISODE LOADING: Load remaining episodes for this feed
            // Resume ELM, observe batch/finish notifications, wait until done
            // ═════════════════════════════════════════════════

            if (op.isCancelled) break;

            EpisodeLoadingManager *elm = [EpisodeLoadingManager sharedManager];
            __block BOOL feedHasPending = NO;
            runOnMain(^{
                feedHasPending = [elm isLoadingFeed:subscribedFeed];
            });

            if (feedHasPending) {
                runOnMain(^{
                    if (cb.setStatusText) cb.setStatusText([NSString stringWithFormat:@"Loading episodes: %@".ls, title]);
                });

                __block NSInteger totalExpected = 0;
                runOnMain(^{
                    totalExpected = [subscribedFeed integerForKey:kFeedPropertyTotalExpectedEpisodes];
                });

                // Set up notifications and resume ELM
                dispatch_semaphore_t finishSem = dispatch_semaphore_create(0);
                __block id batchObserver = nil;
                __block id finishObserver = nil;
                __block BOOL cleanedUp = NO;

                void (^cleanupObservers)(void) = ^{
                    if (cleanedUp) return;
                    cleanedUp = YES;
                    if (batchObserver) [[NSNotificationCenter defaultCenter] removeObserver:batchObserver];
                    if (finishObserver) [[NSNotificationCenter defaultCenter] removeObserver:finishObserver];
                    batchObserver = nil;
                    finishObserver = nil;
                };

                runOnMain(^{
                    // Observe batch progress (UI updates only)
                    batchObserver = [[NSNotificationCenter defaultCenter]
                        addObserverForName:EpisodeLoadingManagerDidLoadBatchNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            CDFeed *noteFeed = note.userInfo[@"feed"];
                            if (![noteFeed isEqual:subscribedFeed]) return;

                            NSInteger loaded = subscribedFeed.episodes.count;
                            float p = totalExpected > 0 ? (float)loaded / (float)totalExpected : 1.0;
                            NSString *detail = [NSString stringWithFormat:@"%ld/%ld", (long)loaded, (long)totalExpected];
                            if (cb.setFeedProgress) cb.setFeedProgress(i, p, detail);
                        }];

                    // Observe finish (signals semaphore so background thread continues)
                    finishObserver = [[NSNotificationCenter defaultCenter]
                        addObserverForName:EpisodeLoadingManagerDidFinishLoadingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            CDFeed *noteFeed = note.userInfo[@"feed"];
                            if (![noteFeed isEqual:subscribedFeed]) return;
                            dispatch_semaphore_signal(finishSem);
                        }];

                    // Resume ELM — it will load this feed's episodes batch by batch
                    elm.suspended = NO;
                });

                // Wait for feed to finish loading.
                // Poll every 0.2s to check cancel/skip. Cancel reacts within 200ms.
                BOOL feedDone = NO;
                while (!feedDone && !op.isCancelled && !ICBackupSkipCurrentFeedRequested()) {
                    long waitResult = dispatch_semaphore_wait(finishSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)));
                    if (waitResult == 0) {
                        feedDone = YES; // finish notification received
                    }
                    // On timeout (200ms), loop re-checks cancel/skip flags
                }

                // Clean up
                runOnMain(^{
                    cleanupObservers();
                    elm.suspended = YES; // Suspend again for next feed
                });

                if (!feedDone) {
                    // Cancelled or skipped while loading
                    runOnMain(^{
                        [elm cancelLoadingForFeed:subscribedFeed];
                    });
                }
            }

            if (op.isCancelled) break;

            if (ICBackupConsumeSkipCurrentFeed()) {
                runOnMain(^{
                    [elm cancelLoadingForFeed:subscribedFeed];
                    if (cb.setFeedSkipped) cb.setFeedSkipped(i);
                });
                continue;
            }

            // Mark feed complete
            runOnMain(^{
                NSInteger finalEpCount = subscribedFeed.episodes.count;
                if (cb.setFeedCompleted) cb.setFeedCompleted(i, finalEpCount);
                float progress = (float)(i + 1) / (float)MAX(feedCount, 1) * 0.98;
                if (cb.setTotalProgress) cb.setTotalProgress(progress);
            });
        }

        if (terminalError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:totalImported queuedDownloadCount:queuedDownloadCount wasCancelled:NO terminalError:terminalError completion:completion];
            });
            return;
        }

        // ═══════════════════════════════════════════════
        // Check cancel before Phase C
        // ═══════════════════════════════════════════════

        if (op.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:totalImported queuedDownloadCount:queuedDownloadCount wasCancelled:YES terminalError:nil completion:completion];
            });
            return;
        }

        // ═══════════════════════════════════════════════
        // PHASE C: Import local data (metadata)
        // ═══════════════════════════════════════════════

        // Build a backup-scoped GUID index for O(1) lookup without scanning the library.
        NSError *guidIndexError = [self _buildGuidIndexForBackup:backup categories:categories];
        if (guidIndexError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:totalImported queuedDownloadCount:queuedDownloadCount wasCancelled:NO terminalError:guidIndexError completion:completion];
            });
            return;
        }
        runOnMain(^{
            if (cb.setStatusText) cb.setStatusText(@"Importing local data…".ls);
        });

        // Define metadata import blocks. Large bookmark/download phases run on this worker;
        // Core Data phases that require the main context are dispatched below.
        NSArray *metadataPhases = @[
            @[@(ICBackupImportEpisodeStatus), ^NSInteger(NSError **error){ return [self importEpisodeStatusFromBackup:backup error:error]; }],
            @[@(ICBackupImportFeedSettings),  ^NSInteger(NSError **error){ return [self importFeedSettingsFromBackup:backup error:error]; }],
            @[@(ICBackupImportBookmarks),     ^NSInteger(NSError **error){ return [self importBookmarksFromBackup:backup operation:op error:error]; }],
            @[@(ICBackupImportUpNext),        ^NSInteger(NSError **error){ (void)error; return [self importUpNextFromBackup:backup]; }],
            @[@(ICBackupImportNowPlaying),    ^NSInteger(NSError **error){ (void)error; return [self importNowPlayingFromBackup:backup]; }],
            @[@(ICBackupImportPlaylists),     ^NSInteger(NSError **error){
                NSInteger c = [self importPlaylistsFromBackup:backup error:error];
                if (error && *error) return c;
                c += [self importEpisodeListsFromBackup:backup error:error];
                return c;
            }],
            @[@(ICBackupImportSettings),      ^NSInteger(NSError **error){ (void)error; return [self importSettingsFromBackup:backup]; }],
            @[@(ICBackupImportSortOrder),     ^NSInteger(NSError **error){ (void)error; return [self importSortOrderFromBackup:backup]; }],
            @[@(ICBackupImportAppleWatch),    ^NSInteger(NSError **error){ return [self importAppleWatchEpisodesFromBackup:backup error:error]; }],
            @[@(ICBackupImportDownloads),     ^NSInteger(NSError **error){ return [self importDownloadsFromBackup:backup queuedCount:&queuedDownloadCount error:error]; }],
        ];

        // Count enabled phases for progress calculation
        NSInteger enabledMetadataCount = 0;
        for (NSArray *phase in metadataPhases) {
            ICBackupImportCategory cat = [phase[0] unsignedIntegerValue];
            if (categories & cat) enabledMetadataCount++;
        }

        NSInteger metadataTotal = metadataPhases.count;
        NSInteger enabledIndex = 0;
        for (NSInteger mi = 0; mi < metadataTotal; mi++) {
            if (op.isCancelled) break;

            NSArray *phase = metadataPhases[mi];
            ICBackupImportCategory cat = [phase[0] unsignedIntegerValue];
            NSInteger (^importBlock)(NSError **) = phase[1];

            if (!(categories & cat)) continue;

            runOnMain(^{
                if (cb.setMetadataActive) cb.setMetadataActive(cat);
            });

            __block NSInteger count = 0;
            __block NSError *phaseError = nil;

            // Episode status import can be very large (thousands of episodes per feed).
            // Run it feed-by-feed with progress updates between feeds so the UI stays responsive.
            if (cat == ICBackupImportEpisodeStatus) {
                NSInteger podcastTotal = backup.podcasts.count;
                for (NSInteger pi = 0; pi < podcastTotal; pi++) {
                    if (op.isCancelled) break;

                    NSInteger podcastIndex = pi;
                    NSInteger feedCount = [self _importEpisodeStatusForPodcastAtIndex:podcastIndex fromBackup:backup error:&phaseError];
                    count += feedCount;
                    if (phaseError) break;

                    // Update progress per feed within the episode status phase
                    float phaseStart = 0.98 + (0.02 * ((float)enabledIndex / (float)MAX(enabledMetadataCount, 1)));
                    float phaseEnd   = 0.98 + (0.02 * ((float)(enabledIndex + 1) / (float)MAX(enabledMetadataCount, 1)));
                    float feedProgress = phaseStart + (phaseEnd - phaseStart) * ((float)(pi + 1) / (float)MAX(podcastTotal, 1));
                    runOnMain(^{
                        if (cb.setTotalProgress) cb.setTotalProgress(feedProgress);
                    });
                }
            } else if (cat == ICBackupImportBookmarks || cat == ICBackupImportDownloads ||
                       cat == ICBackupImportFeedSettings) {
                if (cat == ICBackupImportFeedSettings) {
                    runOnMain(^{
                        [[ICiCloudSyncManager sharedManager] beginLocalOutboxBatch];
                    });
                }
                count = importBlock(&phaseError);
                if (cat == ICBackupImportFeedSettings) {
                    runOnMain(^{
                        [[ICiCloudSyncManager sharedManager] endLocalOutboxBatch];
                    });
                }
            } else {
                runOnMain(^{
                    count = importBlock(&phaseError);
                });
            }

            if (phaseError) {
                totalImported += count;
                terminalError = phaseError;
                break;
            }

            runOnMain(^{
                NSString *detail;
                if (cat == ICBackupImportNowPlaying) {
                    detail = count > 0 ? @"1" : @"—";
                } else if (cat == ICBackupImportSortOrder) {
                    detail = count > 0 ? @"✓" : @"—";
                } else {
                    detail = [NSString stringWithFormat:@"%ld", (long)count];
                }
                if (cat == ICBackupImportDownloads && queuedDownloadCount > 0) {
                    if (cb.setMetadataQueued) cb.setMetadataQueued(cat, queuedDownloadCount);
                } else if (cb.setMetadataCompleted) {
                    cb.setMetadataCompleted(cat, detail);
                }
            });

            totalImported += count;

            // Update total progress (metadata uses 98–100%)
            float metaProgress = 0.98 + (0.02 * ((float)(enabledIndex + 1) / (float)MAX(enabledMetadataCount, 1)));
            runOnMain(^{
                if (cb.setTotalProgress) cb.setTotalProgress(metaProgress);
            });

            enabledIndex++;
        }

        if (terminalError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:totalImported queuedDownloadCount:queuedDownloadCount wasCancelled:NO terminalError:terminalError completion:completion];
            });
            return;
        }

        if (op.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:totalImported queuedDownloadCount:queuedDownloadCount wasCancelled:YES terminalError:nil completion:completion];
            });
            return;
        }

        // ═══════════════════════════════════════════════
        // PHASE D: Downloads + Now Playing
        // ═══════════════════════════════════════════════

        runOnMain(^{
            if (cb.setStatusText) cb.setStatusText(@"Finalizing…".ls);
        });

        // ═══════════════════════════════════════════════
        // FINALIZE
        // ═══════════════════════════════════════════════

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _finalize:backup categories:categories totalImported:totalImported queuedDownloadCount:queuedDownloadCount wasCancelled:NO terminalError:nil completion:completion];
        });
    }];

    [ICBackupImportQueue() addOperation:operation];
}

#pragma mark - Finalize

+ (void)_finalize:(InstacastBackupData *)backup
       categories:(ICBackupImportCategory)categories
    totalImported:(NSInteger)totalImported
queuedDownloadCount:(NSInteger)queuedDownloadCount
     wasCancelled:(BOOL)wasCancelled
    terminalError:(NSError *)terminalError
       completion:(void(^)(NSInteger importedCount, NSInteger queuedDownloadCount, NSError *error))completion
{
    NSError *finalError = terminalError;
    if (!finalError) {
        finalError = ICBackupSaveMainContext();
    }

    // Resume ELM — all feeds should be fully loaded already, but just in case
    [EpisodeLoadingManager sharedManager].suspended = NO;

    BOOL completedSuccessfully = !wasCancelled && !finalError;
    if (completedSuccessfully) {
        [self processPendingNowPlaying];
        [self processPendingDownloads];
    }
    if (completedSuccessfully && (categories & ICBackupImportSettings)) {
        [[ICAppearanceManager sharedManager] updateAppearance];
        [[WidgetDataExporter sharedExporter] exportSettingsSnapshot];
        [WidgetKitHelper reloadAllTimelines];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"OPMLImportDidFinishNotification" object:nil];

    if (completedSuccessfully && (categories & ICBackupImportSettings)) {
        NSString *backupIcon = backup.settings.values[@"appIcon"];
        if (backupIcon.length > 0) {
            NSString *currentIcon = [[UIApplication sharedApplication] alternateIconName];
            if (![backupIcon isEqualToString:currentIcon ?: @""]) {
                [[UIApplication sharedApplication] setAlternateIconName:backupIcon completionHandler:^(NSError *error) {
                    if (error) {
                        ErrLog(@"Failed to set app icon '%@': %@", backupIcon, error.localizedDescription);
                    }
                }];
            }
        }
    }

    // Clean up
    _guidIndexByFeedURL = nil;
    _episodeTitleByFeedURL = nil;
    _feedURLMapping = nil;
    _currentOperation = nil;

    if (completion) {
        if (!finalError && wasCancelled) {
            finalError = [NSError errorWithDomain:@"InstacastBackupImporter" code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Import was cancelled.".ls}];
        }
        completion(totalImported, queuedDownloadCount, finalError);
    }
}

#pragma mark - GUID Index Cache

// Maps backup feedURL → normalized feed sourceURL (handles redirects, trailing slashes)
static NSMutableDictionary<NSString *, NSString *> *_feedURLMapping = nil;

+ (NSError *)_buildGuidIndexForBackup:(InstacastBackupData *)backup
                           categories:(ICBackupImportCategory)categories {
    _guidIndexByFeedURL = [NSMutableDictionary dictionary];
    _episodeTitleByFeedURL = [NSMutableDictionary dictionary];
    _feedURLMapping = [NSMutableDictionary dictionary];
    ICBackupImportCategory episodeLookupCategories = ICBackupImportEpisodeStatus |
                                                       ICBackupImportBookmarks |
                                                       ICBackupImportUpNext |
                                                       ICBackupImportNowPlaying |
                                                       ICBackupImportPlaylists |
                                                       ICBackupImportDownloads |
                                                       ICBackupImportAppleWatch;
    ICBackupImportCategory feedURLMappingCategories = episodeLookupCategories |
                                                       ICBackupImportFeedSettings;
    if (!(categories & feedURLMappingCategories)) return nil;

    NSMutableSet<NSString *> *candidateGUIDs = [NSMutableSet set];
    if (categories & (ICBackupImportEpisodeStatus | ICBackupImportDownloads)) {
        for (ICBackupPodcast *podcast in backup.podcasts) {
            for (ICBackupEpisode *episode in podcast.episodes) {
                if (episode.guid.length == 0) continue;
                if ((categories & ICBackupImportEpisodeStatus) || episode.downloaded) {
                    [candidateGUIDs addObject:episode.guid];
                }
            }
        }
    }
    if (categories & ICBackupImportBookmarks) {
        for (ICBackupBookmark *bookmark in backup.bookmarks) {
            if (bookmark.episodeGuid.length > 0) [candidateGUIDs addObject:bookmark.episodeGuid];
        }
    }
    if (categories & ICBackupImportUpNext) {
        for (ICBackupEpisode *episode in backup.upNextEpisodes) {
            if (episode.guid.length > 0) [candidateGUIDs addObject:episode.guid];
        }
    }
    if ((categories & ICBackupImportNowPlaying) && backup.nowPlaying.guid.length > 0) {
        [candidateGUIDs addObject:backup.nowPlaying.guid];
    }
    if (categories & ICBackupImportPlaylists) {
        for (ICBackupPlaylist *playlist in backup.playlists) {
            for (ICBackupEpisode *episode in playlist.episodes) {
                if (episode.guid.length > 0) [candidateGUIDs addObject:episode.guid];
            }
        }
    }
    if (categories & ICBackupImportAppleWatch) {
        for (ICBackupAppleWatchEpisode *episode in backup.appleWatchEpisodes) {
            if (episode.guid.length > 0) [candidateGUIDs addObject:episode.guid];
        }
    }
    if (candidateGUIDs.count == 0 && !(categories & ICBackupImportFeedSettings)) return nil;

    NSMutableSet<NSString *> *indexedFeedURLs = [NSMutableSet set];

    NSManagedObjectContext *context = [DMANAGER newBackgroundContext];
    if (!context) {
        return [NSError errorWithDomain:@"InstacastBackupImporter"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey: @"The local podcast data could not be read. The import was stopped to prevent incomplete metadata. Please try again.".ls}];
    }
    __block NSError *fetchError = nil;
    [context performBlockAndWait:^{
        if (categories & ICBackupImportFeedSettings) {
            NSFetchRequest<NSDictionary *> *feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
            feedRequest.resultType = NSDictionaryResultType;
            feedRequest.includesSubentities = NO;
            feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND sourceURL_ != nil"];
            feedRequest.propertiesToFetch = @[@"sourceURL_"];
            feedRequest.fetchBatchSize = ICBackupFeedSettingsBatchSize;
            NSArray<NSDictionary *> *feedRows = [context executeFetchRequest:feedRequest error:&fetchError];
            if (!feedRows) return;
            for (NSDictionary *feedRow in feedRows) {
                NSString *feedURL = feedRow[@"sourceURL_"];
                if (feedURL.length > 0) [indexedFeedURLs addObject:feedURL];
            }
        }

        NSArray<NSString *> *GUIDs = candidateGUIDs.allObjects;
        const NSUInteger episodeFetchBatchSize = 400;
        for (NSUInteger offset = 0; offset < GUIDs.count; offset += episodeFetchBatchSize) {
            @autoreleasepool {
                NSArray<NSString *> *GUIDBatch = [GUIDs subarrayWithRange:NSMakeRange(offset, MIN(episodeFetchBatchSize, GUIDs.count - offset))];
                NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                request.includesSubentities = NO;
                request.predicate = [NSPredicate predicateWithFormat:@"guid IN %@ AND feed.sourceURL_ != nil", GUIDBatch];
                request.relationshipKeyPathsForPrefetching = @[@"feed"];
                request.fetchBatchSize = episodeFetchBatchSize;
                NSArray *episodes = [context executeFetchRequest:request error:&fetchError];
                if (!episodes) return;

                for (CDEpisode *ep in episodes) {
                    NSString *feedURL = [ep.feed.sourceURL absoluteString];
                    if (feedURL.length == 0 || ep.guid.length == 0) continue;

                    NSMutableDictionary *index = _guidIndexByFeedURL[feedURL];
                    if (!index) {
                        index = [NSMutableDictionary dictionary];
                        _guidIndexByFeedURL[feedURL] = index;
                    }
                    index[ep.guid] = ep.objectID;
                    if (ep.title.length > 0) {
                        NSMutableDictionary<NSString *, NSString *> *titles = _episodeTitleByFeedURL[feedURL];
                        if (!titles) {
                            titles = [NSMutableDictionary dictionary];
                            _episodeTitleByFeedURL[feedURL] = titles;
                        }
                        titles[ep.guid] = ep.title;
                    }
                    [indexedFeedURLs addObject:feedURL];
                }
            }
        }

        // Exact normalized identities always win. Alternate HTTP/HTTPS identities are only
        // aliases when the database does not contain an exact counterpart.
        for (NSString *feedURL in indexedFeedURLs) {
            NSString *normalizedURL = [DatabaseManager normalizedFeedURLStringForURLString:feedURL];
            if (normalizedURL) _feedURLMapping[normalizedURL] = feedURL;
        }
        for (NSString *feedURL in indexedFeedURLs) {
            NSArray<NSString *> *equivalentURLs = [DatabaseManager equivalentFeedURLStringsForURLString:feedURL];
            for (NSUInteger index = 1; index < equivalentURLs.count; index++) {
                NSString *aliasURL = equivalentURLs[index];
                if (!_feedURLMapping[aliasURL]) _feedURLMapping[aliasURL] = feedURL;
            }
        }
    }];
    if (fetchError) {
        ErrLog(@"Could not build backup episode index: %@", fetchError);
        _guidIndexByFeedURL = nil;
        _episodeTitleByFeedURL = nil;
        _feedURLMapping = nil;
        return [NSError errorWithDomain:@"InstacastBackupImporter"
                                   code:2
                               userInfo:@{
                                   NSLocalizedDescriptionKey: @"The local podcast data could not be read. The import was stopped to prevent incomplete metadata. Please try again.".ls,
                                   NSUnderlyingErrorKey: fetchError,
                               }];
    }
    return nil;
}

/// Map a backup feedURL to the actual feed sourceURL stored in Core Data.
/// Handles URL normalization, redirects, HTTP→HTTPS differences, trailing slashes.
+ (NSString *)_resolvedFeedURLForBackupURL:(NSString *)backupURL {
    if (!backupURL) return nil;

    // Check cache first
    NSString *cached = _feedURLMapping[backupURL];
    if (cached) return cached;

    for (NSString *candidateURL in [DatabaseManager equivalentFeedURLStringsForURLString:backupURL]) {
        NSString *resolvedURL = _feedURLMapping[candidateURL];
        if (resolvedURL) {
            _feedURLMapping[backupURL] = resolvedURL;
            return resolvedURL;
        }
    }

    return nil;
}

#pragma mark - Episode Status

/// Import episode status for a single podcast (called per-feed for responsive UI).
+ (NSInteger)_importEpisodeStatusForPodcastAtIndex:(NSInteger)index
                                        fromBackup:(InstacastBackupData *)backup
                                             error:(NSError **)error {
    if (index < 0 || index >= (NSInteger)backup.podcasts.count) return 0;

    ICBackupPodcast *podcast = backup.podcasts[index];
    if (!podcast.feedURL) return 0;
    NSString *resolvedFeedURL = [self _resolvedFeedURLForBackupURL:podcast.feedURL];
    if (!resolvedFeedURL) return 0;

    // Build backup episode lookup by GUID
    NSMutableDictionary<NSString *, ICBackupEpisode *> *backupEpisodesByGuid = [NSMutableDictionary dictionaryWithCapacity:podcast.episodes.count];
    for (ICBackupEpisode *backupEp in podcast.episodes) {
        if (backupEp.guid) {
            backupEpisodesByGuid[backupEp.guid] = backupEp;
        }
    }

    __block NSInteger count = 0;
    __block NSError *phaseError = nil;
    NSManagedObjectContext *context = [DMANAGER newBackgroundContext];
    if (!context) {
        if (error) *error = ICBackupImportPersistenceError(nil);
        return 0;
    }
    context.mergePolicy = NSErrorMergePolicy;
    [context performBlockAndWait:^{
        NSFetchRequest *feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
        feedRequest.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", resolvedFeedURL];
        feedRequest.fetchLimit = 1;
        CDFeed *feed = [[context executeFetchRequest:feedRequest error:nil] firstObject];
        if (!feed) return;

        for (CDEpisode *episode in feed.episodes) {
            if (!episode.guid) continue;

            ICBackupEpisode *backupEp = backupEpisodesByGuid[episode.guid];

            if (backupEp) {
                if (backupEp.played && !episode.consumed) {
                    episode.consumed = YES;
                    count++;
                }

                if (backupEp.starred && !episode.starred) {
                    episode.starred = YES;
                    count++;
                }

                if (backupEp.archived && !episode.archived) {
                    episode.archived = YES;
                    count++;
                }

                if (backupEp.position > episode.position) {
                    episode.position = backupEp.position;
                    count++;
                }

                if (backupEp.duration > 0 && episode.duration == 0) {
                    episode.duration = backupEp.duration;
                    count++;
                }
            }
        }

        if (context.hasChanges) {
            NSError *journalError = nil;
            if (![ICiCloudSyncManager journalBackgroundEpisodeChangesInContext:context
                                                                          error:&journalError]) {
                [context rollback];
                count = 0;
                phaseError = ICBackupImportPersistenceError(journalError);
                return;
            }
            NSError *commitPreparationError = nil;
            ICBackgroundLocalOutboxCommitPlan *commitPlan =
                [ICiCloudSyncManager prepareBackgroundLocalOutboxCommitInContext:context
                                                                           error:&commitPreparationError];
            if (!commitPlan) {
                [context rollback];
                count = 0;
                phaseError = ICBackupImportPersistenceError(commitPreparationError);
                return;
            }
            NSError *saveError = nil;
            if (![context save:&saveError]) {
                [ICiCloudSyncManager cancelBackgroundLocalOutboxCommit:commitPlan];
                ErrLog(@"could not import episode status for %@: %@", ICRedactedURLStringForLogging(resolvedFeedURL), saveError);
                [context rollback];
                count = 0;
                phaseError = ICBackupImportPersistenceError(saveError);
            } else {
                [ICiCloudSyncManager completeBackgroundLocalOutboxCommit:commitPlan];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[ICiCloudSyncManager sharedManager] backgroundLocalEpisodeChangesDidCommit];
                });
            }
        }
    }];

    if (phaseError && error) *error = phaseError;

    return count;
}

+ (NSInteger)importEpisodeStatusFromBackup:(InstacastBackupData *)backup error:(NSError **)error {
    NSInteger count = 0;
    for (NSInteger i = 0; i < (NSInteger)backup.podcasts.count; i++) {
        NSError *phaseError = nil;
        count += [self _importEpisodeStatusForPodcastAtIndex:i fromBackup:backup error:&phaseError];
        if (phaseError) {
            if (error) *error = phaseError;
            break;
        }
    }
    return count;
}

#pragma mark - Feed Settings

+ (NSInteger)importFeedSettingsFromBackup:(InstacastBackupData *)backup error:(NSError **)error {
    NSInteger count = 0;
    NSSet *internalKeys = [NSSet setWithObjects:@"episodeLoadingComplete", @"loadedEpisodeCount", @"totalExpectedEpisodes", nil];

    for (NSUInteger offset = 0; offset < backup.podcasts.count;
         offset += ICBackupFeedSettingsBatchSize) {
        NSRange range = NSMakeRange(
            offset,
            MIN(ICBackupFeedSettingsBatchSize, backup.podcasts.count - offset)
        );
        NSArray<ICBackupPodcast *> *podcastBatch = [backup.podcasts subarrayWithRange:range];
        NSMutableArray<NSArray *> *resolvedPodcasts = [NSMutableArray arrayWithCapacity:podcastBatch.count];
        NSMutableSet<NSString *> *resolvedFeedURLs = [NSMutableSet setWithCapacity:podcastBatch.count];
        for (ICBackupPodcast *podcast in podcastBatch) {
            NSString *resolvedFeedURL = [self _resolvedFeedURLForBackupURL:podcast.feedURL];
            if (resolvedFeedURL.length == 0) continue;
            [resolvedPodcasts addObject:@[resolvedFeedURL, podcast]];
            [resolvedFeedURLs addObject:resolvedFeedURL];
        }
        if (resolvedPodcasts.count == 0) continue;

        NSManagedObjectContext *context = [DMANAGER newICloudSyncBackgroundContext];
        if (!context) {
            if (error) *error = ICBackupImportPersistenceError(nil);
            return 0;
        }
        context.mergePolicy = NSErrorMergePolicy;

        __block NSInteger batchCount = 0;
        __block NSError *batchError = nil;
        __block NSArray<NSString *> *credentialFeedURLs = @[];
        __block ICBackgroundLocalSubscriptionMergePlan *mergePlan = nil;
        __block ICBackgroundLocalOutboxCommitPlan *outboxCommitPlan = nil;
        __block BOOL committedChanges = NO;
        __block NSError *credentialError = nil;
        BOOL restoresCredentials = NO;
        for (NSArray *resolvedPodcast in resolvedPodcasts) {
            ICBackupPodcast *podcast = resolvedPodcast[1];
            if (podcast.password.length > 0) {
                restoresCredentials = YES;
                break;
            }
        }
        ICLocalCredentialRestoreLease *credentialRestoreLease = restoresCredentials
            ? [ICiCloudSyncManager beginLocalCredentialRestore]
            : nil;
        [context performBlockAndWait:^{
            NSFetchRequest<CDFeed *> *request = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
            request.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ IN %@", resolvedFeedURLs];
            request.includesSubentities = NO;
            request.fetchBatchSize = ICBackupFeedSettingsBatchSize;
            request.relationshipKeyPathsForPrefetching = @[@"properties"];
            NSError *fetchError = nil;
            NSArray<CDFeed *> *feeds = [context executeFetchRequest:request error:&fetchError];
            if (!feeds) {
                batchError = ICBackupImportPersistenceError(fetchError);
                return;
            }
            NSMutableDictionary<NSString *, CDFeed *> *feedsByURL = [NSMutableDictionary dictionaryWithCapacity:feeds.count];
            for (CDFeed *feed in feeds) {
                NSString *feedURL = [feed valueForKey:@"sourceURL_"];
                if (feedURL.length > 0) feedsByURL[feedURL] = feed;
            }

            NSMutableDictionary<NSString *, NSDictionary *> *credentialIntents = [NSMutableDictionary dictionary];
            for (NSArray *resolvedPodcast in resolvedPodcasts) {
                NSString *feedURL = resolvedPodcast[0];
                ICBackupPodcast *podcast = resolvedPodcast[1];
                CDFeed *feed = feedsByURL[feedURL];
                if (!feed) continue;

                if (podcast.rank > 0 && feed.rank != podcast.rank) {
                    feed.rank = podcast.rank;
                }
                if (feed.parked != podcast.parked) {
                    feed.parked = podcast.parked;
                }
                if (podcast.username.length > 0) {
                    if (![feed.username isEqualToString:podcast.username]) {
                        feed.username = podcast.username;
                    }
                    batchCount++;
                }
                if (podcast.password.length > 0) {
                    NSString *expectedPassword = feed.password;
                    if (![expectedPassword isEqualToString:podcast.password]) {
                        credentialIntents[feedURL] = @{
                            @"expectedPassword": expectedPassword ?: @"",
                            @"expectedPasswordPresent": @(expectedPassword != nil),
                            @"desiredUsername": feed.username ?: @"",
                            @"desiredPassword": podcast.password,
                        };
                    }
                    batchCount++;
                }

                for (NSString *originalKey in podcast.settings ?: @{}) {
                    if ([internalKeys containsObject:originalKey]) continue;
                    NSString *value = podcast.settings[originalKey];
                    if (value.length == 0) continue;

                    // Translate UID-prefixed keys: old UID → the current local feed UID.
                    NSString *key = originalKey;
                    if (key.length > 37 && [key characterAtIndex:36] == '_') {
                        NSString *prefix = [key substringToIndex:36];
                        if ([prefix characterAtIndex:8] == '-' && [prefix characterAtIndex:13] == '-' &&
                            [prefix characterAtIndex:18] == '-' && [prefix characterAtIndex:23] == '-') {
                            NSString *suffix = [key substringFromIndex:36];
                            key = [feed.uid stringByAppendingString:suffix];
                        }
                    }

                    NSString *type = podcast.settingTypes[originalKey];
                    if (type.length == 0) {
                        type = ICBackupLegacyFeedSettingType(key, value);
                    }
                    if (ICBackupApplyFeedSetting(feed, key, type, value)) {
                        batchCount++;
                    }
                }
            }

            NSError *journalError = nil;
            if (![ICiCloudSyncManager journalBackgroundSubscriptionChangesInContext:context
                                                                   credentialIntents:credentialIntents
                                                                               error:&journalError]) {
                [context rollback];
                batchError = ICBackupImportPersistenceError(journalError);
                return;
            }

            NSPredicate *userObjectPredicate = [NSPredicate predicateWithBlock:^BOOL(NSManagedObject *object, NSDictionary *bindings) {
                NSString *entityName = object.entity.name;
                return [entityName isEqualToString:@"Feed"] || [entityName isEqualToString:@"FeedProperty"];
            }];
            NSArray<NSManagedObject *> *insertedUserObjects =
                [[context.insertedObjects allObjects] filteredArrayUsingPredicate:userObjectPredicate];
            NSArray<NSManagedObject *> *updatedUserObjects =
                [[context.updatedObjects allObjects] filteredArrayUsingPredicate:userObjectPredicate];

            if (insertedUserObjects.count > 0) {
                NSError *permanentIDError = nil;
                if (![context obtainPermanentIDsForObjects:insertedUserObjects error:&permanentIDError]) {
                    [context rollback];
                    batchError = ICBackupImportPersistenceError(permanentIDError);
                    return;
                }
            }

            NSMutableArray<NSString *> *insertedURIs = [NSMutableArray arrayWithCapacity:insertedUserObjects.count];
            for (NSManagedObject *object in insertedUserObjects) {
                NSString *URIString = object.objectID.URIRepresentation.absoluteString;
                if (URIString.length > 0) [insertedURIs addObject:URIString];
            }
            NSMutableArray<NSString *> *updatedURIs = [NSMutableArray arrayWithCapacity:updatedUserObjects.count];
            for (NSManagedObject *object in updatedUserObjects) {
                NSString *URIString = object.objectID.URIRepresentation.absoluteString;
                if (URIString.length > 0) [updatedURIs addObject:URIString];
            }
            if (insertedURIs.count > 0 || updatedURIs.count > 0) {
                __block NSError *mergePreparationError = nil;
                runOnMain(^{
                    mergePlan = [[ICiCloudSyncManager sharedManager]
                        prepareBackgroundLocalSubscriptionMergeWithInsertedObjectURIStrings:insertedURIs
                        updatedObjectURIStrings:updatedURIs
                        error:&mergePreparationError];
                });
                if (!mergePlan) {
                    [context rollback];
                    batchError = ICBackupImportPersistenceError(mergePreparationError);
                    return;
                }
            }

            if (context.hasChanges) {
                NSError *commitPreparationError = nil;
                outboxCommitPlan =
                    [ICiCloudSyncManager prepareBackgroundLocalOutboxCommitInContext:context
                                                                               error:&commitPreparationError];
                if (!outboxCommitPlan) {
                    [context rollback];
                    batchError = ICBackupImportPersistenceError(commitPreparationError);
                    return;
                }
                NSError *saveError = nil;
                if (![context save:&saveError]) {
                    [ICiCloudSyncManager cancelBackgroundLocalOutboxCommit:outboxCommitPlan];
                    [context rollback];
                    batchError = ICBackupImportPersistenceError(saveError);
                    return;
                }
                [ICiCloudSyncManager completeBackgroundLocalOutboxCommit:outboxCommitPlan];
                committedChanges = YES;
            }

            credentialFeedURLs = credentialIntents.allKeys;
        }];
        if (!batchError && credentialFeedURLs.count > 0) {
            [ICiCloudSyncManager resolvePendingLocalCredentialIntentsWithRestoreLease:credentialRestoreLease
                                                                              feedURLs:credentialFeedURLs
                                                                                  error:&credentialError];
        }
        if (credentialRestoreLease) {
            [ICiCloudSyncManager endLocalCredentialRestore:credentialRestoreLease];
        }

        if (batchError) {
            if (error) *error = batchError;
            return 0;
        }

        if (mergePlan || committedChanges) {
            runOnMain(^{
                if (mergePlan) {
                    [[ICiCloudSyncManager sharedManager]
                        commitBackgroundLocalSubscriptionMergePlan:mergePlan];
                } else {
                    [[ICiCloudSyncManager sharedManager] backgroundLocalOutboxChangesDidCommit];
                }
            });
        }

        if (credentialError) {
            if (error) *error = credentialError;
            return 0;
        }
        count += batchCount;
    }
    return count;
}

#pragma mark - Bookmarks

+ (NSInteger)importBookmarksFromBackup:(InstacastBackupData *)backup
                             operation:(NSOperation *)operation
                                 error:(NSError **)error {
    NSError *stageError = nil;
    if (!ICBackupPrepareBookmarkStage(backup.bookmarks, &stageError)) {
        if (error) *error = stageError;
        return 0;
    }

    NSError *bookmarkImportError = nil;
    NSInteger count = [self _importBookmarks:backup.bookmarks operation:operation error:&bookmarkImportError];
    if (operation.isCancelled) {
        NSError *cancelStateError = ICBackupMarkBookmarkStageCancelled(backup.bookmarks);
        if (cancelStateError) {
            if (error) *error = cancelStateError;
            return count;
        }
        NSError *cleanupError = ICBackupRemoveBookmarkStage();
        if (cleanupError) {
            ErrLog(@"Could not delete cancelled bookmark import stage: %@", cleanupError);
        }
        return count;
    }

    if (bookmarkImportError) {
        if (error) *error = bookmarkImportError;
        return count;
    }

    NSError *cleanupError = ICBackupRemoveBookmarkStage();
    if (cleanupError && error) *error = cleanupError;
    return count;
}

+ (NSInteger)_importBookmarks:(NSArray<ICBackupBookmark *> *)bookmarks
                    operation:(NSOperation *)operation
                        error:(NSError **)error {
    NSManagedObjectContext *context = [DMANAGER newBackgroundContext];
    if (!context) {
        if (error) *error = ICBackupBookmarkImportPublicError(nil);
        return 0;
    }

    __block NSInteger savedBookmarkCount = 0;
    __block NSInteger pendingBookmarkCount = 0;
    __block NSError *bookmarkImportError = nil;
    const NSInteger bookmarkSaveBatchSize = 100;

    [context performBlockAndWait:^{
        NSError *fetchError = nil;
        NSFetchRequest<NSDictionary *> *feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
        feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND sourceURL_ != nil"];
        feedRequest.resultType = NSDictionaryResultType;
        feedRequest.propertiesToFetch = @[@"sourceURL_", @"title", @"imageURL_"];
        NSArray<NSDictionary *> *feedRows = [context executeFetchRequest:feedRequest error:&fetchError];
        if (!feedRows) {
            bookmarkImportError = ICBackupBookmarkImportPublicError(fetchError);
            return;
        }

        NSMutableArray<NSDictionary *> *feedInfos = [NSMutableArray arrayWithCapacity:feedRows.count];
        NSMutableDictionary<NSString *, NSDictionary *> *feedInfoByLookupURL = [NSMutableDictionary dictionaryWithCapacity:feedRows.count * 2];
        for (NSDictionary *row in feedRows) {
            NSString *rawURL = ICBackupStringValue(row[@"sourceURL_"]);
            NSString *normalizedURL = [DatabaseManager normalizedFeedURLStringForURLString:rawURL];
            if (!normalizedURL) continue;
            NSDictionary *info = @{
                @"canonicalURL": normalizedURL,
                @"title": ICBackupStringValue(row[@"title"]) ?: @"",
                @"imageURL": ICBackupStringValue(row[@"imageURL_"]) ?: @"",
            };
            feedInfoByLookupURL[normalizedURL] = info;
            [feedInfos addObject:info];
        }
        for (NSDictionary *info in feedInfos) {
            NSArray<NSString *> *equivalentURLs = [DatabaseManager equivalentFeedURLStringsForURLString:info[@"canonicalURL"]];
            for (NSUInteger index = 1; index < equivalentURLs.count; index++) {
                NSString *aliasURL = equivalentURLs[index];
                if (!feedInfoByLookupURL[aliasURL]) feedInfoByLookupURL[aliasURL] = info;
            }
        }

        NSFetchRequest<NSDictionary *> *bookmarkRequest = [[NSFetchRequest alloc] initWithEntityName:@"Bookmark"];
        bookmarkRequest.resultType = NSDictionaryResultType;
        bookmarkRequest.propertiesToFetch = @[@"episodeGuid", @"feedURL_", @"position"];
        NSArray<NSDictionary *> *bookmarkRows = [context executeFetchRequest:bookmarkRequest error:&fetchError];
        if (!bookmarkRows) {
            bookmarkImportError = ICBackupBookmarkImportPublicError(fetchError);
            return;
        }

        NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *> *bookmarkPositionsByEpisode = [NSMutableDictionary dictionaryWithCapacity:bookmarkRows.count];
        for (NSDictionary *row in bookmarkRows) {
            NSString *rawFeedURL = ICBackupStringValue(row[@"feedURL_"]);
            NSString *normalizedFeedURL = [DatabaseManager normalizedFeedURLStringForURLString:rawFeedURL];
            NSString *canonicalFeedURL = ICBackupStringValue(feedInfoByLookupURL[normalizedFeedURL][@"canonicalURL"]) ?: normalizedFeedURL;
            NSNumber *position = ICBackupNumberValue(row[@"position"]);
            ICBackupIndexBookmarkPosition(bookmarkPositionsByEpisode,
                                          canonicalFeedURL,
                                          ICBackupStringValue(row[@"episodeGuid"]),
                                          position ? position.doubleValue : 0);
        }

        BOOL (^savePendingBookmarks)(void) = ^BOOL{
            if (pendingBookmarkCount == 0) return YES;
            NSError *saveError = nil;
            if (![context save:&saveError]) {
                [context rollback];
                pendingBookmarkCount = 0;
                bookmarkImportError = ICBackupBookmarkImportPublicError(saveError);
                return NO;
            }
            savedBookmarkCount += pendingBookmarkCount;
            pendingBookmarkCount = 0;
            [context reset];
            return YES;
        };

        for (ICBackupBookmark *backupBookmark in bookmarks) {
            if (operation.isCancelled) {
                [context rollback];
                pendingBookmarkCount = 0;
                break;
            }
            NSString *normalizedFeedURL = [DatabaseManager normalizedFeedURLStringForURLString:backupBookmark.feedURL];
            NSDictionary *feedInfo = normalizedFeedURL ? feedInfoByLookupURL[normalizedFeedURL] : nil;
            NSString *canonicalFeedURL = ICBackupStringValue(feedInfo[@"canonicalURL"]) ?: normalizedFeedURL;
            NSURL *feedURL = backupBookmark.feedURL.length > 0 ? [NSURL URLWithString:backupBookmark.feedURL] : nil;
            if (canonicalFeedURL.length == 0 || backupBookmark.episodeGuid.length == 0 || !feedURL) continue;
            if (ICBackupBookmarkExistsInIndex(bookmarkPositionsByEpisode,
                                              canonicalFeedURL,
                                              backupBookmark.episodeGuid,
                                              backupBookmark.position)) {
                continue;
            }

            CDBookmark *bookmark = [NSEntityDescription insertNewObjectForEntityForName:@"Bookmark"
                                                                 inManagedObjectContext:context];
            bookmark.title = backupBookmark.title;
            bookmark.position = backupBookmark.position;
            bookmark.episodeGuid = backupBookmark.episodeGuid;
            bookmark.feedURL = feedURL;
            bookmark.episodeHash = [[canonicalFeedURL stringByAppendingString:backupBookmark.episodeGuid] MD5Hash];
            bookmark.feedTitle = ICBackupStringValue(feedInfo[@"title"]);
            NSString *imageURL = ICBackupStringValue(feedInfo[@"imageURL"]);
            if (imageURL.length > 0) bookmark.imageURL = [NSURL URLWithString:imageURL];

            NSString *resolvedFeedURL = [self _resolvedFeedURLForBackupURL:backupBookmark.feedURL];
            bookmark.episodeTitle = _episodeTitleByFeedURL[resolvedFeedURL][backupBookmark.episodeGuid];
            ICBackupIndexBookmarkPosition(bookmarkPositionsByEpisode,
                                          canonicalFeedURL,
                                          backupBookmark.episodeGuid,
                                          backupBookmark.position);
            pendingBookmarkCount++;
            if (pendingBookmarkCount >= bookmarkSaveBatchSize && !savePendingBookmarks()) return;
        }

        if (!bookmarkImportError && !operation.isCancelled) {
            savePendingBookmarks();
        }
    }];

    if (operation.isCancelled) {
        NSError *cancelStateError = ICBackupMarkBookmarkStageCancelled(bookmarks);
        if (cancelStateError && !bookmarkImportError) {
            bookmarkImportError = cancelStateError;
        }
    }

    if (bookmarkImportError) {
        ErrLog(@"Bookmark backup import failed: %@", bookmarkImportError.userInfo[NSUnderlyingErrorKey]);
        if (error) *error = bookmarkImportError;
    }
    if (savedBookmarkCount > 0) {
        runOnMain(^{
            [DMANAGER addBookmark:nil];
        });
    }
    return savedBookmarkCount;
}

#pragma mark - Up Next

+ (NSInteger)importUpNextFromBackup:(InstacastBackupData *)backup {
    NSMutableArray<CDEpisode *> *upNextEpisodes = [NSMutableArray array];
    for (ICBackupEpisode *backupEp in backup.upNextEpisodes) {
        CDEpisode *episode = [self findEpisodeWithGuid:backupEp.guid feedURL:backupEp.feedURL];
        if (episode) {
            [upNextEpisodes addObject:episode];
        }
    }

    if (upNextEpisodes.count > 0) {
        [[AudioSession sharedAudioSession] appendToUpNext:upNextEpisodes];
    }
    return upNextEpisodes.count;
}

#pragma mark - Now Playing

+ (NSInteger)importNowPlayingFromBackup:(InstacastBackupData *)backup {
    ICBackupEpisode *np = backup.nowPlaying;
    if (!np) return 0;

    uint64_t playbackIntentRevision = [AudioSession playbackIntentRevision];

    CDEpisode *episode = [self findEpisodeWithGuid:np.guid feedURL:np.feedURL];
    if (!episode) {
        // Episode not found — save for later (will be retried after episode loading)
        [USER_DEFAULTS setObject:ICBackupPendingNowPlayingRecord(np.guid,
                                                                 np.feedURL,
                                                                 np.position,
                                                                 playbackIntentRevision)
                         forKey:kPendingNowPlayingKey];
        return 1;
    }

    if (np.position > 0) {
        episode.position = np.position;
    }

    if (episode.preferedMedium.fileURL) {
        [[AudioSession sharedAudioSession] restorePlaybackEpisode:episode queueUpCurrent:NO at:(NSTimeInterval)np.position autostart:NO];
        [USER_DEFAULTS removeObjectForKey:kPendingNowPlayingKey];
    } else {
        [USER_DEFAULTS setObject:ICBackupPendingNowPlayingRecord(np.guid,
                                                                 np.feedURL,
                                                                 np.position,
                                                                 playbackIntentRevision)
                         forKey:kPendingNowPlayingKey];
    }
    return 1;
}

+ (void)_processPendingDeferredRestoreForFeedURLs:(NSSet<NSString *> *)feedURLs {
    NSError *stageError = nil;
    NSArray<NSDictionary *> *pendingDownloads = ICBackupMigrateLegacyPendingDownloads(&stageError);
    if (!pendingDownloads) {
        ErrLog(@"Could not read pending backup downloads: %@", stageError);
        ICBackupPresentDeferredRestoreError(stageError);
        return;
    }

    NSError *tombstoneError = nil;
    NSDictionary<NSString *, NSDictionary *> *cancellationTombstones = ICBackupReadDownloadCancellationTombstones(&tombstoneError);
    if (!cancellationTombstones) {
        ErrLog(@"Could not read pending download cancellations: %@", tombstoneError);
        ICBackupPresentDeferredRestoreError(tombstoneError);
        return;
    }
    NSSet<NSString *> *cancelledDownloadHashes = [NSSet setWithArray:cancellationTombstones.allKeys];

    id rawNowPlaying = [USER_DEFAULTS objectForKey:kPendingNowPlayingKey];
    NSDictionary *pendingNowPlaying = [rawNowPlaying isKindOfClass:[NSDictionary class]] ? [rawNowPlaying copy] : nil;
    NSString *nowPlayingGUID = [pendingNowPlaying[@"guid"] isKindOfClass:[NSString class]] ? pendingNowPlaying[@"guid"] : nil;
    NSString *nowPlayingFeedURL = [pendingNowPlaying[@"feedURL"] isKindOfClass:[NSString class]] ? pendingNowPlaying[@"feedURL"] : nil;
    BOOL pendingNowPlayingIsCurrent = pendingNowPlaying &&
        ICBackupPendingNowPlayingMatchesPlaybackIntent(pendingNowPlaying,
                                                       [AudioSession playbackIntentRevision]);
    if (nowPlayingGUID.length == 0 || nowPlayingFeedURL.length == 0 || !pendingNowPlayingIsCurrent) {
        if (pendingNowPlaying) {
            runOnMain(^{
                NSDictionary *currentPending = [USER_DEFAULTS objectForKey:kPendingNowPlayingKey];
                if ([currentPending isEqualToDictionary:pendingNowPlaying]) {
                    [USER_DEFAULTS removeObjectForKey:kPendingNowPlayingKey];
                }
            });
        }
        pendingNowPlaying = nil;
    }

    NSSet<NSString *> *feedURLScope = feedURLs ? ICBackupEquivalentFeedURLSet(feedURLs.allObjects) : nil;
    NSMutableArray<NSDictionary *> *selectedDownloads = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *untouchedDownloads = [NSMutableArray array];
    for (NSDictionary *entry in pendingDownloads) {
        if (ICBackupFeedURLMatchesScope(entry[@"feedURL"], feedURLScope)) {
            [selectedDownloads addObject:entry];
        } else {
            [untouchedDownloads addObject:entry];
        }
    }
    BOOL shouldProcessNowPlaying = pendingNowPlaying && ICBackupFeedURLMatchesScope(nowPlayingFeedURL, feedURLScope);
    BOOL shouldProcessCancellations = cancellationTombstones.count > 0 && feedURLs == nil;
    if (selectedDownloads.count == 0 && !shouldProcessNowPlaying && !shouldProcessCancellations) {
        return;
    }

    NSManagedObjectContext *context = [DMANAGER newBackgroundContext];
    if (!context) {
        NSError *error = ICBackupDownloadRecoveryStateError(DMANAGER.initializationError);
        ErrLog(@"Could not create deferred-restore context: %@", error);
        ICBackupPresentDeferredRestoreError(error);
        return;
    }

    __block NSError *fetchError = nil;
    __block NSMutableDictionary<NSString *, NSManagedObjectID *> *feedIDsByPendingURL = [NSMutableDictionary dictionary];
    __block NSMutableDictionary<NSString *, NSDictionary *> *episodeInfoByKey = [NSMutableDictionary dictionary];
    __block NSMutableDictionary<NSString *, NSManagedObjectID *> *cancellationEpisodeIDsByHash = [NSMutableDictionary dictionary];
    [context performBlockAndWait:^{
        NSMutableOrderedSet<NSString *> *candidateFeedURLs = [NSMutableOrderedSet orderedSet];
        for (NSDictionary *entry in selectedDownloads) {
            NSString *feedURL = entry[@"feedURL"];
            [candidateFeedURLs addObject:feedURL];
            [candidateFeedURLs addObjectsFromArray:[DatabaseManager equivalentFeedURLStringsForURLString:feedURL]];
        }
        if (shouldProcessNowPlaying) {
            [candidateFeedURLs addObject:nowPlayingFeedURL];
            [candidateFeedURLs addObjectsFromArray:[DatabaseManager equivalentFeedURLStringsForURLString:nowPlayingFeedURL]];
        }

        NSMutableDictionary<NSString *, NSManagedObjectID *> *feedIDsByEquivalentURL = [NSMutableDictionary dictionary];
        const NSUInteger feedFetchBatchSize = 100;
        for (NSUInteger offset = 0; offset < candidateFeedURLs.count && !fetchError; offset += feedFetchBatchSize) {
            NSRange range = NSMakeRange(offset, MIN(feedFetchBatchSize, candidateFeedURLs.count - offset));
            NSArray<NSString *> *batch = [candidateFeedURLs.array subarrayWithRange:range];
            NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Feed"];
            request.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ IN %@", batch];
            request.fetchBatchSize = feedFetchBatchSize;
            NSArray<CDFeed *> *feeds = [context executeFetchRequest:request error:&fetchError];
            for (CDFeed *feed in feeds) {
                NSString *storedURL = [feed valueForKey:@"sourceURL_"];
                if (storedURL.length == 0) continue;
                feedIDsByEquivalentURL[storedURL] = feed.objectID;
                for (NSString *equivalentURL in [DatabaseManager equivalentFeedURLStringsForURLString:storedURL]) {
                    if (!feedIDsByEquivalentURL[equivalentURL]) feedIDsByEquivalentURL[equivalentURL] = feed.objectID;
                }
            }
        }
        if (fetchError) return;

        NSMutableSet<NSString *> *candidateGUIDs = [NSMutableSet set];
        NSMutableSet<NSString *> *targetKeys = [NSMutableSet set];
        void (^indexPendingFeed)(NSString *, NSArray<NSString *> *) = ^(NSString *feedURL, NSArray<NSString *> *guids) {
            NSManagedObjectID *feedID = feedIDsByEquivalentURL[feedURL];
            if (!feedID) {
                for (NSString *equivalentURL in [DatabaseManager equivalentFeedURLStringsForURLString:feedURL]) {
                    feedID = feedIDsByEquivalentURL[equivalentURL];
                    if (feedID) break;
                }
            }
            if (!feedID) return;
            feedIDsByPendingURL[feedURL] = feedID;
            for (NSString *guid in guids) {
                [candidateGUIDs addObject:guid];
                NSString *targetKey = ICBackupDeferredEpisodeKey(feedID, guid);
                if (targetKey) [targetKeys addObject:targetKey];
            }
        };
        for (NSDictionary *entry in selectedDownloads) {
            indexPendingFeed(entry[@"feedURL"], entry[@"guids"]);
        }
        if (shouldProcessNowPlaying) {
            indexPendingFeed(nowPlayingFeedURL, @[nowPlayingGUID]);
        }

        NSArray<NSString *> *allGUIDs = candidateGUIDs.allObjects;
        const NSUInteger episodeFetchBatchSize = 200;
        for (NSUInteger offset = 0; offset < allGUIDs.count && !fetchError; offset += episodeFetchBatchSize) {
            @autoreleasepool {
                NSRange range = NSMakeRange(offset, MIN(episodeFetchBatchSize, allGUIDs.count - offset));
                NSArray<NSString *> *batch = [allGUIDs subarrayWithRange:range];
                NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                request.predicate = [NSPredicate predicateWithFormat:@"guid IN %@", batch];
                request.fetchBatchSize = episodeFetchBatchSize;
                NSArray<CDEpisode *> *episodes = [context executeFetchRequest:request error:&fetchError];
                for (CDEpisode *episode in episodes) {
                    NSString *key = ICBackupDeferredEpisodeKey(episode.feed.objectID, episode.guid);
                    if (!key || ![targetKeys containsObject:key]) continue;
                    episodeInfoByKey[key] = @{
                        @"objectID": episode.objectID,
                        @"objectHash": episode.objectHash ?: @"",
                    };
                }
            }
        }
        if (shouldProcessCancellations) {
            NSArray<NSString *> *objectHashes = cancellationTombstones.allKeys;
            for (NSUInteger offset = 0; offset < objectHashes.count && !fetchError; offset += episodeFetchBatchSize) {
                NSRange range = NSMakeRange(offset, MIN(episodeFetchBatchSize, objectHashes.count - offset));
                NSArray<NSString *> *batch = [objectHashes subarrayWithRange:range];
                NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                request.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", batch];
                request.fetchBatchSize = episodeFetchBatchSize;
                NSArray<CDEpisode *> *episodes = [context executeFetchRequest:request error:&fetchError];
                for (CDEpisode *episode in episodes) {
                    if (episode.objectHash.length > 0) {
                        cancellationEpisodeIDsByHash[episode.objectHash] = episode.objectID;
                    }
                }
            }
        }
        [context reset];
    }];
    if (fetchError) {
        NSError *error = ICBackupDownloadRecoveryStateError(fetchError);
        ErrLog(@"Could not resolve deferred backup episodes: %@", error);
        ICBackupPresentDeferredRestoreError(error);
        return;
    }

    NSMutableSet<NSString *> *resolvedDownloadKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *inspectedDownloadKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *deferredOwnershipHashesToRelease = [NSMutableSet set];
    NSMutableSet<NSString *> *consumedCancellationHashes = [NSMutableSet set];
    NSMutableArray<NSDictionary *> *cancellationCandidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *mainCandidates = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *cancellationHashByPendingIdentity = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *pendingKeysByCancellationHash = [NSMutableDictionary dictionary];
    if (shouldProcessCancellations) {
        [cancellationTombstones enumerateKeysAndObjectsUsingBlock:^(NSString *objectHash, NSDictionary *record, BOOL *stop) {
            (void)stop;
            NSString *feedURL = record[@"feedURL"];
            NSString *guid = record[@"episodeGUID"];
            if (feedURL.length == 0 || guid.length == 0) return;
            NSMutableOrderedSet<NSString *> *feedIdentities = [NSMutableOrderedSet orderedSet];
            [feedIdentities addObject:feedURL];
            [feedIdentities addObjectsFromArray:[DatabaseManager equivalentFeedURLStringsForURLString:feedURL]];
            for (NSString *feedIdentity in feedIdentities) {
                cancellationHashByPendingIdentity[ICBackupPendingDownloadKey(feedIdentity, guid)] = objectHash;
            }
        }];
    }
    const NSUInteger deferredMainBatchSize = 20;
    const NSUInteger deferredMainInspectionLimit = deferredMainBatchSize * 2;
    for (NSDictionary *entry in selectedDownloads) {
        NSString *feedURL = entry[@"feedURL"];
        NSManagedObjectID *feedID = feedIDsByPendingURL[feedURL];
        for (NSString *guid in entry[@"guids"]) {
            NSString *pendingKey = ICBackupPendingDownloadKey(feedURL, guid);
            NSString *episodeKey = ICBackupDeferredEpisodeKey(feedID, guid);
            NSDictionary *episodeInfo = episodeKey ? episodeInfoByKey[episodeKey] : nil;
            NSString *objectHash = episodeInfo[@"objectHash"];
            NSString *cancellationHash = shouldProcessCancellations && [cancelledDownloadHashes containsObject:objectHash]
                ? objectHash
                : nil;
            if (!cancellationHash && shouldProcessCancellations) {
                NSMutableOrderedSet<NSString *> *feedIdentities = [NSMutableOrderedSet orderedSet];
                [feedIdentities addObject:feedURL];
                [feedIdentities addObjectsFromArray:[DatabaseManager equivalentFeedURLStringsForURLString:feedURL]];
                for (NSString *feedIdentity in feedIdentities) {
                    cancellationHash = cancellationHashByPendingIdentity[ICBackupPendingDownloadKey(feedIdentity, guid)];
                    if (cancellationHash) break;
                }
            }
            if (cancellationHash) {
                NSMutableArray<NSString *> *pendingKeys = pendingKeysByCancellationHash[cancellationHash];
                if (!pendingKeys) {
                    pendingKeys = [NSMutableArray array];
                    pendingKeysByCancellationHash[cancellationHash] = pendingKeys;
                }
                [pendingKeys addObject:pendingKey];
            } else if (episodeInfo && mainCandidates.count < deferredMainInspectionLimit) {
                [inspectedDownloadKeys addObject:pendingKey];
                [mainCandidates addObject:@{
                    @"pendingKey": pendingKey,
                    @"objectID": episodeInfo[@"objectID"],
                    @"objectHash": objectHash ?: @"",
                }];
            }
        }
    }
    if (shouldProcessCancellations) {
        for (NSString *objectHash in cancellationTombstones) {
            NSManagedObjectID *objectID = cancellationEpisodeIDsByHash[objectHash];
            [cancellationCandidates addObject:@{
                @"pendingKeys": pendingKeysByCancellationHash[objectHash] ?: @[],
                @"objectID": objectID ?: (id)NSNull.null,
                @"objectHash": objectHash,
            }];
        }
    }

    __block NSUInteger newDownloadsStarted = 0;
    for (NSUInteger offset = 0; offset < cancellationCandidates.count; offset += deferredMainBatchSize) {
        NSRange batchRange = NSMakeRange(offset, MIN(deferredMainBatchSize, cancellationCandidates.count - offset));
        NSArray<NSDictionary *> *batch = [cancellationCandidates subarrayWithRange:batchRange];
        dispatch_sync(dispatch_get_main_queue(), ^{
            CacheManager *cacheManager = [CacheManager sharedCacheManager];
            for (NSDictionary *candidate in batch) {
                id rawObjectID = candidate[@"objectID"];
                CDEpisode *episode = nil;
                if ([rawObjectID isKindOfClass:[NSManagedObjectID class]]) {
                    NSError *objectError = nil;
                    episode = (CDEpisode *)[DMANAGER.objectContext existingObjectWithID:rawObjectID error:&objectError];
                    if (objectError) episode = nil;
                }
                BOOL queueOwnerRemoved = [cacheManager completeDeferredRestoreCancellationForObjectHash:candidate[@"objectHash"]
                                                                                                 episode:episode];
                if (!queueOwnerRemoved) continue;
                [resolvedDownloadKeys addObjectsFromArray:candidate[@"pendingKeys"]];
                [consumedCancellationHashes addObject:candidate[@"objectHash"]];
                [deferredOwnershipHashesToRelease addObject:candidate[@"objectHash"]];
            }
        });
    }
    for (NSUInteger offset = 0; offset < mainCandidates.count; offset += deferredMainBatchSize) {
        NSRange batchRange = NSMakeRange(offset, MIN(deferredMainBatchSize, mainCandidates.count - offset));
        NSArray<NSDictionary *> *batch = [mainCandidates subarrayWithRange:batchRange];
        dispatch_sync(dispatch_get_main_queue(), ^{
            CacheManager *cacheManager = [CacheManager sharedCacheManager];
            for (NSDictionary *candidate in batch) {
                NSError *objectError = nil;
                CDEpisode *episode = (CDEpisode *)[DMANAGER.objectContext existingObjectWithID:candidate[@"objectID"] error:&objectError];
                if (!episode || objectError) continue;
                if ([cacheManager episodeIsCached:episode]) {
                    [resolvedDownloadKeys addObject:candidate[@"pendingKey"]];
                    ICBackupSetDeferredDownloadOwnership(candidate[@"objectHash"], YES);
                    [deferredOwnershipHashesToRelease addObject:candidate[@"objectHash"]];
                    continue;
                }
                if ([cacheManager isCachingEpisode:episode]) {
                    ICBackupSetDeferredDownloadOwnership(candidate[@"objectHash"], YES);
                    continue;
                }
                if (newDownloadsStarted >= deferredMainBatchSize) {
                    continue;
                }
                if (!episode.preferedMedium.fileURL) continue;
                BOOL accepted = [cacheManager cacheEpisode:episode
                                       overwriteCellularLock:NO
                                      reportsFailureToUser:NO];
                if (accepted) {
                    ICBackupSetDeferredDownloadOwnership(candidate[@"objectHash"], YES);
                    newDownloadsStarted++;
                }
            }
        });
        (void)NSMaxRange(batchRange);
    }

    NSArray<NSDictionary *> *remainingDownloads = ICBackupRemainingDownloadsWithFairInspectionOrder(
        untouchedDownloads,
        selectedDownloads,
        resolvedDownloadKeys,
        inspectedDownloadKeys
    );

    if (shouldProcessNowPlaying) {
        NSManagedObjectID *feedID = feedIDsByPendingURL[nowPlayingFeedURL];
        NSString *episodeKey = ICBackupDeferredEpisodeKey(feedID, nowPlayingGUID);
        NSDictionary *episodeInfo = episodeKey ? episodeInfoByKey[episodeKey] : nil;
        if (episodeInfo) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSDictionary *currentPending = [USER_DEFAULTS objectForKey:kPendingNowPlayingKey];
                if (![currentPending isEqualToDictionary:pendingNowPlaying] ||
                    !ICBackupPendingNowPlayingMatchesPlaybackIntent(pendingNowPlaying,
                                                                    [AudioSession playbackIntentRevision])) {
                    if ([currentPending isEqualToDictionary:pendingNowPlaying]) {
                        [USER_DEFAULTS removeObjectForKey:kPendingNowPlayingKey];
                    }
                    return;
                }
                NSError *objectError = nil;
                CDEpisode *episode = (CDEpisode *)[DMANAGER.objectContext existingObjectWithID:episodeInfo[@"objectID"] error:&objectError];
                if (!episode || objectError || !episode.preferedMedium.fileURL) return;
                double position = [pendingNowPlaying[@"position"] doubleValue];
                [[AudioSession sharedAudioSession] restorePlaybackEpisode:episode
                                                           queueUpCurrent:NO
                                                                       at:(NSTimeInterval)position
                                                                autostart:NO];
                if ([[USER_DEFAULTS objectForKey:kPendingNowPlayingKey] isEqualToDictionary:pendingNowPlaying]) {
                    [USER_DEFAULTS removeObjectForKey:kPendingNowPlayingKey];
                }
            });
        }
    }

    BOOL stageUpdated = YES;
    if (pendingDownloads.count > 0) {
        NSError *writeError = nil;
        stageUpdated = ICBackupWriteDownloadStage(remainingDownloads, &writeError);
        if (!stageUpdated) {
            ErrLog(@"Could not update pending backup downloads: %@", writeError);
            ICBackupPresentDeferredRestoreError(writeError);
        }
    }
    if (stageUpdated) {
        for (NSString *objectHash in deferredOwnershipHashesToRelease) {
            ICBackupSetDeferredDownloadOwnership(objectHash, NO);
        }
    }
    if (stageUpdated && cancellationTombstones.count > 0) {
        NSMutableArray<NSURL *> *tombstonesToRemove = [NSMutableArray array];
        for (NSString *objectHash in consumedCancellationHashes) {
            NSURL *URL = cancellationTombstones[objectHash][@"URL"];
            if (URL) [tombstonesToRemove addObject:URL];
        }
        NSError *cleanupError = nil;
        if (!ICBackupRemoveDownloadCancellationTombstones(tombstonesToRemove, &cleanupError)) {
            ErrLog(@"Could not remove committed download cancellations: %@", cleanupError);
            ICBackupPresentDeferredRestoreError(cleanupError);
        }
    }
}

+ (void)processPendingNowPlaying {
    [self retryPendingDeferredRestoreIfNeeded];
}

#pragma mark - Apple Watch Episodes

+ (CDEpisode *)_episodeForAppleWatchBackupEpisode:(ICBackupAppleWatchEpisode *)backupEpisode {
    if (backupEpisode.episodeHash.length > 0) {
        CDEpisode *episode = [DMANAGER episodeWithObjectHash:backupEpisode.episodeHash];
        if (episode) return episode;
    }

    return [self findEpisodeWithGuid:backupEpisode.guid feedURL:backupEpisode.feedURL];
}

+ (NSString *)_feedIdentifierForWatchEpisode:(CDEpisode *)episode backupValue:(NSString *)backupValue {
    if (backupValue.length > 0) return backupValue;

    NSString *sourceURL = [episode.feed.sourceURL absoluteString];
    if (sourceURL.length > 0) return sourceURL;

    return episode.feed.uid ?: @"";
}

+ (NSString *)_validAppleWatchSelectionSource:(NSString *)selectionSource {
    if ([selectionSource isEqualToString:ICAppleWatchSelectionSourceManual] ||
        [selectionSource isEqualToString:ICAppleWatchSelectionSourceLatestRule]) {
        return selectionSource;
    }
    return ICAppleWatchSelectionSourceManual;
}

+ (NSInteger)importAppleWatchEpisodesFromBackup:(InstacastBackupData *)backup error:(NSError **)error {
    AppleWatchSyncManager *watchManager = [AppleWatchSyncManager sharedManager];
    NSMutableSet<NSString *> *importedHashes = [NSMutableSet set];
    NSInteger count = 0;

    for (ICBackupAppleWatchEpisode *backupEpisode in backup.appleWatchEpisodes) {
        CDEpisode *episode = [self _episodeForAppleWatchBackupEpisode:backupEpisode];
        if (![watchManager canSendEpisodeToWatch:episode]) continue;

        NSString *episodeHash = episode.objectHash ?: backupEpisode.episodeHash;
        if (episodeHash.length == 0 || [importedHashes containsObject:episodeHash]) continue;
        [importedHashes addObject:episodeHash];

        AppleWatchEpisodeState *state = [watchManager stateForEpisodeHash:episodeHash];
        if (!state) {
            state = [NSEntityDescription insertNewObjectForEntityForName:@"AppleWatchEpisodeState" inManagedObjectContext:DMANAGER.objectContext];
            state.episodeHash = episodeHash;
        }

        BOOL keepLocalDownloadStatus = [state.watchStatus isEqualToString:ICAppleWatchStatusDownloaded] ||
                                       [state.watchStatus isEqualToString:ICAppleWatchStatusDownloading];

        state.feedIdentifier = [self _feedIdentifierForWatchEpisode:episode backupValue:backupEpisode.feedIdentifier];
        state.selectionSource = [self _validAppleWatchSelectionSource:backupEpisode.selectionSource];
        state.watchAddedDate = backupEpisode.watchAddedDate ?: state.watchAddedDate ?: [NSDate date];
        state.lastPhonePosition = backupEpisode.lastPhonePosition;
        state.lastPhonePositionDate = backupEpisode.lastPhonePositionDate;
        state.lastWatchPosition = backupEpisode.lastWatchPosition;
        state.lastWatchPositionDate = backupEpisode.lastWatchPositionDate;
        state.watchConsumed = backupEpisode.watchConsumed;
        state.watchConsumedDate = backupEpisode.watchConsumedDate;
        state.watchLastError = nil;

        if (!keepLocalDownloadStatus) {
            state.watchStatus = ICAppleWatchStatusSelected;
            state.watchDownloadedDate = nil;
            state.watchLastSeenDate = nil;
            state.watchActualDuration = 0;
            state.watchActualFileSize = 0;
        }

        count++;
    }

    if (count > 0) {
        NSError *saveError = ICBackupSaveMainContext();
        if (saveError) {
            if (error) *error = saveError;
            return 0;
        }
        [watchManager syncCurrentSelectionsNow];
    }

    return count;
}

#pragma mark - Playlists

+ (NSInteger)importPlaylistsFromBackup:(InstacastBackupData *)backup error:(NSError **)error {
    NSInteger count = 0;

    for (ICBackupPlaylist *backupList in backup.playlists) {
        if (!backupList.name) continue;

        CDPlaylist *existingPlaylist = nil;
        for (CDList *list in DMANAGER.lists) {
            if ([list isKindOfClass:[CDPlaylist class]] && [list.name isEqualToString:backupList.name]) {
                existingPlaylist = (CDPlaylist *)list;
                break;
            }
        }

        CDPlaylist *playlist = existingPlaylist;
        if (!playlist) {
            playlist = [NSEntityDescription insertNewObjectForEntityForName:@"Playlist"
                                                     inManagedObjectContext:DMANAGER.objectContext];
            playlist.name = backupList.name;
            playlist.rank = backupList.rank;
            [CDList updateRanksOfLists:DMANAGER.lists];
            count++;
        }

        NSSet *existingEpisodes = [NSSet setWithArray:playlist.sortedEpisodes];
        for (ICBackupEpisode *backupEp in backupList.episodes) {
            CDEpisode *episode = [self findEpisodeWithGuid:backupEp.guid feedURL:backupEp.feedURL];
            if (episode && ![existingEpisodes containsObject:episode]) {
                [playlist addEpisode:episode];
                count++;
            }
        }
    }

    NSError *saveError = ICBackupSaveMainContext();
    if (saveError) {
        if (error) *error = saveError;
        return 0;
    }
    return count;
}

#pragma mark - Episode Lists

+ (NSInteger)importEpisodeListsFromBackup:(InstacastBackupData *)backup error:(NSError **)error {
    NSInteger count = 0;

    for (ICBackupEpisodeList *backupList in backup.episodeLists) {
        if (!backupList.uid) continue;

        CDEpisodeList *existingList = nil;
        for (CDList *list in DMANAGER.lists) {
            if ([list isKindOfClass:[CDEpisodeList class]] && [list.uid isEqualToString:backupList.uid]) {
                existingList = (CDEpisodeList *)list;
                break;
            }
        }

        if (existingList) {
            existingList.audio = backupList.audio;
            existingList.video = backupList.video;
            existingList.downloaded = backupList.downloaded;
            existingList.downloading = backupList.downloading;
            existingList.notDownloaded = backupList.notDownloaded;
            existingList.unplayed = backupList.unplayed;
            existingList.unfinished = backupList.unfinished;
            existingList.played = backupList.played;
            existingList.starred = backupList.starred;
            existingList.notStarred = backupList.notStarred;
            if (backupList.orderBy) existingList.orderBy = backupList.orderBy;
            existingList.descending = backupList.descending;
            existingList.groupByPodcast = backupList.groupByPodcast;
            existingList.continuousPlayback = backupList.continuousPlayback;

            if (backupList.includedFeedURLs.count > 0) {
                NSMutableSet *feeds = [NSMutableSet set];
                for (NSString *urlStr in backupList.includedFeedURLs) {
                    NSURL *url = [NSURL URLWithString:urlStr];
                    CDFeed *feed = url ? [DMANAGER feedWithSourceURL:url] : nil;
                    if (feed) [feeds addObject:feed];
                }
                existingList.includedFeeds = feeds;
            }

            [existingList invalidateCaches];
            count++;
        } else {
            CDEpisodeList *newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList"
                                                                  inManagedObjectContext:DMANAGER.objectContext];
            newList.uid = backupList.uid;
            newList.name = backupList.name;
            newList.icon = backupList.icon;
            newList.rank = backupList.rank;
            newList.audio = backupList.audio;
            newList.video = backupList.video;
            newList.downloaded = backupList.downloaded;
            newList.downloading = backupList.downloading;
            newList.notDownloaded = backupList.notDownloaded;
            newList.unplayed = backupList.unplayed;
            newList.unfinished = backupList.unfinished;
            newList.played = backupList.played;
            newList.starred = backupList.starred;
            newList.notStarred = backupList.notStarred;
            newList.orderBy = backupList.orderBy;
            newList.descending = backupList.descending;
            newList.groupByPodcast = backupList.groupByPodcast;
            newList.continuousPlayback = backupList.continuousPlayback;

            if (backupList.includedFeedURLs.count > 0) {
                NSMutableSet *feeds = [NSMutableSet set];
                for (NSString *urlStr in backupList.includedFeedURLs) {
                    NSURL *url = [NSURL URLWithString:urlStr];
                    CDFeed *feed = url ? [DMANAGER feedWithSourceURL:url] : nil;
                    if (feed) [feeds addObject:feed];
                }
                newList.includedFeeds = feeds;
            }

            [CDList updateRanksOfLists:DMANAGER.lists];
            count++;
        }
    }

    NSError *saveError = ICBackupSaveMainContext();
    if (saveError) {
        if (error) *error = saveError;
        return 0;
    }
    return count;
}

#pragma mark - App Settings

+ (NSInteger)importSettingsFromBackup:(InstacastBackupData *)backup {
    NSDictionary *settingsMap = @{
        @"playbackSpeed":           DefaultPlaybackSpeed,
        @"skipBack":                PlayerSkipBackPeriod,
        @"skipForward":             PlayerSkipForwardPeriod,
        @"autoSkipStart":           PlayerAutoSkipStartPeriod,
        @"autoSkipEnd":             PlayerAutoSkipEndPeriod,
        @"replayAfterPause":        PlayerReplayAfterPause,
        @"autoCacheAudio":          AutoCacheNewAudioEpisodes,
        @"autoCacheVideo":          AutoCacheNewVideoEpisodes,
        @"autoDeletePlayed":        AutoDeleteAfterFinishedPlaying,
        @"disableAutoLock":         DisableAutoLock,
        @"defaultSleepTimer":       DefaultIntelligentSleepTimer,
        @"appearanceMode":          kDefaultAppearanceMode,
        @"sleepTimerAlways":        ScreenTimerAlwaysActive,
        @"disableSleepTimerCarPlay": DisableSleepTimerInCarPlay,
        @"lastSleepTimer":          LastSelectedSleepTimer,
        @"playerControls":          kDefaultPlayerControls,
        @"autoDeleteMarkedPlayed":  AutoDeleteAfterMarkedAsPlayed,
        @"autoDeleteNews":          AutoDeleteNewsMode,
        @"podcastRefreshOnAppStart": PodcastRefreshOnAppStart,
        @"enableCachingOver3G":     EnableCachingOver3G,
        @"enableRefreshingOver3G":  EnableRefreshingOver3G,
        @"enableStreamingOver3G":   EnableStreamingOver3G,
        @"uiSoundEnabled":          UISoundEnabled,
        @"uiHapticsEnabled":        UIHapticsEnabled,
        @"showBadge":               ShowApplicationBadgeForUnseen,
        @"dontDeleteUpNext":        kDefaultDontDeleteUpNextWhenChangingEpisode,
        @"showUnavailable":         kDefaultShowUnavailableEpisodes,
        @"themeDefaultActive":      InterfaceThemeDefaultActive,
        @"themeColorHex":           InterfaceThemeColorHexCode,
        @"playerPerPodcastColor":   PlayerColorPerPodcastActive,
        @"playerColorHex":          PlayerThemeColorHexCode,
        @"widgetThemeDefaultActive": WidgetThemeDefaultActive,
        @"widgetColorHex":          WidgetThemeColorHexCode,
        @"transcriptHighlightStyle": kDefaultTranscriptHighlightStyle,
        @"smarthomeMQTTEnabled":    SmarthomeMQTTEnabled,
        @"smarthomeMQTTHost":       SmarthomeMQTTHost,
        @"smarthomeMQTTPort":       SmarthomeMQTTPort,
        @"smarthomeMQTTUsername":   SmarthomeMQTTUsername,
        @"smarthomeMQTTPassword":   SmarthomeMQTTPassword,
        @"smarthomeAllowControl":   SmarthomeAllowControl,
        @"smarthomeWiFiOnly":       SmarthomeWiFiOnly,
        @"smarthomeDeviceName":     SmarthomeDeviceName,
        @"deviceMovementIntelligentSleep": DeviceMovementIntelligentSleep,
        @"deviceMovementSensitivity":      DeviceMovementSensitivity,
        @"screenTouchIntelligentSleep":    ScreenTouchIntelligentSleep,
        @"volumeChangeIntelligentSleep":   VolumeChangeIntelligentSleep,
        @"continuousPlay":          ContinuousPlayFromFeed,
        @"autoCacheStorageLimit":   AutoCacheStorageLimit,
        @"autoDownloadWhileStreaming": AutoDownloadWhileStreaming,
        @"enableCachingImagesOver3G": EnableCachingImagesOver3G,
        @"openLinksExternal":       OpenLinksInExternalBrowser,
        @"allowDiagnostics":        AllowSendingDiagnostics,
        @"amazonAffiliateEnabled":  AmazonAffiliateEnabled,
        @"notifyNewEpisode":        EnableNewEpisodeNotification,
        @"notifyRefreshFinished":   EnableManualRefreshFinishedNotification,
        @"notifyRefreshFailure":    EnableRefreshFailureNotification,
        @"notifyDownloadFinished":  EnableManualDownloadFinishedNotification,
        @"intelligentSleepAlways":  IntelligentSleepTimerAlwaysActive,
        @"feedSortOrder":           FeedSortOrder,
        @"selectedAppLanguage":     SelectedAppLanguage,
        @"episodeSwipeRightAction": EpisodeSwipeRightAction,
        @"episodeSwipeLeftAction":  EpisodeSwipeLeftAction,
        @"appleWatchSendLatestCount": AppleWatchSendLatestCount,
        @"appleWatchOnlyUnplayed":  AppleWatchOnlyUnplayed,
        @"iCloudSyncEpisodes":      ICiCloudSyncEpisodesEnabled,
        @"iCloudSyncSubscriptions": ICiCloudSyncSubscriptionsEnabled,
        @"iCloudSyncSettings":      ICiCloudSyncSettingsEnabled,
        @"darkModePureBlack":       kDefaultDarkModePureBlack,
        @"fontSizeLarger":          kDefaultFontSizeLarger,
        @"tapOnEpisodeAction":      TapOnEpisodeAction,
        @"mediaFilesSortMode":      @"MediaFilesSortMode",
        @"localTranscriptionEnabled": kLocalTranscriptionEnabled,
        @"serverTranscriptionEnabled": kServerTranscriptionEnabled,
        @"automaticTranscriptionBackend": kAutomaticTranscriptionBackend,
        @"transcriptionEngine":     kTranscriptionEngine,
        @"transcriptionWhisperModel": kTranscriptionWhisperModel,
        @"chapterGenerationModel":  @"ChapterGenerationModel",
        @"transcriptionAutoDefault": kTranscriptionAutoDefault,
        @"chapterAutoDefault":      kChapterAutoDefault,
        @"autoSkipSponsors":        kAutoSkipSponsors,
        @"transcriptionEverActivated": kTranscriptionEverActivated,
        @"transcriptionFirstRunShown": kTranscriptionFirstRunShown,
        @"transcriptVisiblePreference": @"TranscriptVisiblePreference",
    };

    NSSet *boolKeys = [NSSet setWithArray:@[
        @"autoCacheAudio", @"autoCacheVideo", @"autoDeletePlayed", @"disableAutoLock",
        @"sleepTimerAlways", @"disableSleepTimerCarPlay", @"autoDeleteMarkedPlayed", @"autoDeleteNews",
        @"podcastRefreshOnAppStart",
        @"enableCachingOver3G", @"enableRefreshingOver3G", @"enableStreamingOver3G",
        @"uiSoundEnabled", @"uiHapticsEnabled", @"showBadge", @"dontDeleteUpNext", @"showUnavailable",
        @"themeDefaultActive", @"playerPerPodcastColor", @"widgetThemeDefaultActive",
        @"smarthomeMQTTEnabled", @"smarthomeAllowControl", @"smarthomeWiFiOnly",
        @"deviceMovementIntelligentSleep", @"screenTouchIntelligentSleep", @"volumeChangeIntelligentSleep",
        @"continuousPlay", @"autoDownloadWhileStreaming", @"enableCachingImagesOver3G",
        @"openLinksExternal", @"notifyNewEpisode", @"notifyRefreshFinished", @"notifyRefreshFailure", @"notifyDownloadFinished",
        @"intelligentSleepAlways", @"darkModePureBlack", @"amazonAffiliateEnabled",
        @"appleWatchOnlyUnplayed", @"localTranscriptionEnabled", @"serverTranscriptionEnabled", @"transcriptionAutoDefault", @"chapterAutoDefault",
        @"autoSkipSponsors", @"transcriptionEverActivated", @"transcriptionFirstRunShown",
        @"transcriptVisiblePreference",
    ]];

    NSSet *doubleKeys = [NSSet setWithArray:@[@"deviceMovementSensitivity"]];

    NSSet *stringKeys = [NSSet setWithArray:@[@"themeColorHex", @"playerColorHex", @"widgetColorHex",
        @"smarthomeMQTTHost", @"smarthomeMQTTUsername", @"smarthomeMQTTPassword", @"smarthomeDeviceName",
        @"feedSortOrder", @"selectedAppLanguage", @"transcriptionEngine", @"transcriptionWhisperModel",
        @"chapterGenerationModel", @"automaticTranscriptionBackend"]];

    NSInteger count = 0;
    NSUserDefaults *defaults = USER_DEFAULTS;
    NSNumber *restoredEpisodesSyncEnabled = nil;
    NSNumber *restoredSubscriptionsSyncEnabled = nil;
    NSNumber *restoredSettingsSyncEnabled = nil;

    for (NSString *xmlKey in backup.settings.values) {
        NSString *defaultsKey = settingsMap[xmlKey];
        if (!defaultsKey) continue;

        NSString *value = backup.settings.values[xmlKey];
        if (!value || value.length == 0) continue;

        if ([xmlKey isEqualToString:@"themeColorHex"]) {
            ICBackupApplyColorHex(defaults, value, InterfaceThemeColorHexCode, InterfaceThemeColorCode);
        } else if ([xmlKey isEqualToString:@"playerColorHex"]) {
            ICBackupApplyColorHex(defaults, value, PlayerThemeColorHexCode, PlayerThemeColorCode);
        } else if ([xmlKey isEqualToString:@"widgetColorHex"]) {
            ICBackupApplyColorHex(defaults, value, WidgetThemeColorHexCode, WidgetThemeColorCode);
        } else if ([xmlKey isEqualToString:@"iCloudSyncEpisodes"]) {
            restoredEpisodesSyncEnabled = @([value isEqualToString:@"true"]);
        } else if ([xmlKey isEqualToString:@"iCloudSyncSubscriptions"]) {
            restoredSubscriptionsSyncEnabled = @([value isEqualToString:@"true"]);
        } else if ([xmlKey isEqualToString:@"iCloudSyncSettings"]) {
            restoredSettingsSyncEnabled = @([value isEqualToString:@"true"]);
        } else if ([boolKeys containsObject:xmlKey]) {
            [defaults setBool:[value isEqualToString:@"true"] forKey:defaultsKey];
        } else if ([doubleKeys containsObject:xmlKey]) {
            [defaults setDouble:[value doubleValue] forKey:defaultsKey];
        } else if ([stringKeys containsObject:xmlKey]) {
            [defaults setObject:value forKey:defaultsKey];
        } else {
            [defaults setInteger:[value integerValue] forKey:defaultsKey];
        }
        count++;
    }

    if (restoredEpisodesSyncEnabled || restoredSubscriptionsSyncEnabled || restoredSettingsSyncEnabled) {
        [[ICiCloudSyncManager sharedManager] restoreSyncOptionsWithEpisodes:restoredEpisodesSyncEnabled
                                                              subscriptions:restoredSubscriptionsSyncEnabled
                                                                     settings:restoredSettingsSyncEnabled];
    }

    NSArray *credentialKeys = @[@"openAIAPIKey", @"anthropicAPIKey", @"kimiAPIKey", @"openAIOAuthAccessToken", @"openAIOAuthRefreshToken", @"openAIOAuthIDToken", @"openAIOAuthAccountID", @"openAIOAuthAccountEmail", @"openAIOAuthFedRAMP"];
    NSMutableDictionary *credentialValues = [NSMutableDictionary dictionary];
    for (NSString *key in credentialKeys) {
        NSString *value = backup.settings.values[key];
        if ([value isKindOfClass:[NSString class]] && value.length > 0) {
            credentialValues[key] = value;
        }
    }
    if (credentialValues.count > 0) {
        [ICRemoteChapterCredentialStore restoreBackupCredentialValues:credentialValues];
        count += credentialValues.count;
    }

    if (backup.settings.mainMenuListUIDs.count > 0) {
        [defaults setObject:backup.settings.mainMenuListUIDs forKey:@"MainMenuListUIDs"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MainMenuListUIDsDidChangeNotification" object:nil];
        count++;
    }

    if (backup.settings.enabledPlaybackSpeeds.count > 0) {
        [defaults setObject:backup.settings.enabledPlaybackSpeeds forKey:EnabledPlaybackSpeedsKey];
        count++;
    }

    [defaults synchronize];
    return count;
}

#pragma mark - Sort Order

+ (NSInteger)importSortOrderFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;
    NSUserDefaults *defaults = USER_DEFAULTS;

    if (backup.settings.feedListSortMode) {
        [defaults setObject:backup.settings.feedListSortMode forKey:FeedListSortMode];
        count++;
    }

    if (backup.settings.manualFeedOrder.count > 0) {
        [defaults setObject:backup.settings.manualFeedOrder forKey:@"ManualFeedOrder"];
        [DMANAGER restoreManualFeedOrder];
        count++;
    }

    [defaults synchronize];
    return count;
}

#pragma mark - Re-download Episodes (deferred)

+ (NSInteger)importDownloadsFromBackup:(InstacastBackupData *)backup
                           queuedCount:(NSInteger *)queuedCount
                                 error:(NSError **)error {
    NSMutableArray *pendingDownloads = [NSMutableArray array];
    if (queuedCount) *queuedCount = 0;

    for (ICBackupPodcast *podcast in backup.podcasts) {
        if (!podcast.feedURL || podcast.episodes.count == 0) continue;

        NSMutableArray *guids = [NSMutableArray array];
        for (ICBackupEpisode *backupEp in podcast.episodes) {
            if (!backupEp.downloaded || !backupEp.guid) continue;
            [guids addObject:backupEp.guid];
        }

        if (guids.count > 0) {
            NSString *resolvedFeedURL = [self _resolvedFeedURLForBackupURL:podcast.feedURL] ?: podcast.feedURL;
            [pendingDownloads addObject:@{@"feedURL": resolvedFeedURL, @"guids": guids}];
        }
    }

    NSError *canonicalError = nil;
    NSArray<NSDictionary *> *canonicalDownloads = ICBackupCanonicalPendingDownloads(pendingDownloads, &canonicalError);
    if (!canonicalDownloads) {
        if (error) *error = canonicalError;
        return 0;
    }
    NSArray<NSDictionary *> *uniquePendingDownloads = ICBackupMergePendingDownloads(@[], canonicalDownloads);
    NSInteger count = 0;
    for (NSDictionary *entry in uniquePendingDownloads) {
        count += [entry[@"guids"] count];
    }

    if (uniquePendingDownloads.count > 0) {
        NSError *stageError = nil;
        if (!ICBackupAppendPendingDownloads(uniquePendingDownloads, &stageError)) {
            if (error) *error = stageError;
            return 0;
        }
    }

    if (queuedCount) *queuedCount = count;
    return 0;
}

+ (void)processPendingDownloads {
    [self retryPendingDeferredRestoreIfNeeded];
}

#pragma mark - Helper

+ (CDEpisode *)findEpisodeWithGuid:(NSString *)guid feedURL:(NSString *)feedURLString {
    if (!guid || !feedURLString) return nil;

    // Try GUID index first (O(1)) — resolve backup URL to actual feed URL
    if (_guidIndexByFeedURL) {
        NSString *resolvedURL = [self _resolvedFeedURLForBackupURL:feedURLString];
        if (resolvedURL) {
            NSDictionary *index = _guidIndexByFeedURL[resolvedURL];
            NSManagedObjectID *episodeID = index[guid];
            if (episodeID) {
                return (CDEpisode *)[DMANAGER.objectContext existingObjectWithID:episodeID error:nil];
            }
        }
        return nil;
    }

    // Outside an active import, resolve the feed identity and fetch one indexed GUID.
    NSURL *feedURL = [NSURL URLWithString:feedURLString];
    if (!feedURL) return nil;

    CDFeed *feed = [DMANAGER feedWithSourceURL:feedURL];
    if (!feed) return nil;
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
    request.predicate = [NSPredicate predicateWithFormat:@"guid == %@ AND feed == %@", guid, feed];
    request.fetchLimit = 1;
    request.fetchBatchSize = 1;
    return [[DMANAGER.objectContext executeFetchRequest:request error:nil] firstObject];
}

@end
