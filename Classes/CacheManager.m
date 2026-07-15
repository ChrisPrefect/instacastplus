//
//  CacheManager.m
//  Instacast
//
//  Created by Martin Hering on 03.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//


#import "CDEpisode+ShowNotes.h"
#import "CDFeed+Helper.h"
#import "ICCacheHistory.h"
#import "UtilityFunctions.h"
#import "InstacastBackupImporter.h"
#import "SubscriptionManager.h"
#import "InstacastPlus-Swift.h"
#include <limits.h>
#include <time.h>

#if TARGET_OS_IPHONE
#import "CacheOperation_iOS7.h"
#define CACHE_OPERATION_CLASS CacheOperation_iOS7
#else

#import "CacheOperation.h"
#define CACHE_OPERATION_CLASS CacheOperation
#import <IOKit/pwr_mgt/IOPMLib.h>

#endif

static NSString* kUserDefaultsCachingEpisodesKey = @"CachingEpisodesKey";
static NSString* const ICCachingEpisodeJobKeyPrefix = @"CachingEpisodeJob.";
static NSString* const ICSubscriptionCleanupDeferredDownloadJobKeyPrefix = @"SubscriptionCleanupDeferredDownloadJob.";
static NSString* const ICDownloadQueueSuspended = @"DownloadQueueSuspended";
static const long long ICCachingEpisodeRankStep = 1024LL;
static NSString* const ICCacheDeletionHashKey = @"hash";
static NSString* const ICCacheDeletionObjectIDKey = @"objectID";
static NSString* const ICCacheDeletionURLKey = @"url";
static NSString* const ICCacheDeletionLastDownloadedKey = @"lastDownloaded";
static NSString* const ICCacheDeletionDownloadedKey = @"downloaded";
static NSString* const ICCacheDeletionWasCachedKey = @"wasCached";
static NSString* const ICCacheDeletionWasAccountedKey = @"wasAccounted";
static NSString* const ICCacheDeletionSuccessKey = @"success";
static NSString* const ICCacheDeletionRemovedBytesKey = @"removedBytes";
static NSString* const ICCacheDeletionErrorKey = @"error";
static NSString* const ICCacheDeletionNeedsRecalculationKey = @"needsRecalculation";
static NSString* const ICCacheDeletionResolvedURLKey = @"resolvedURL";
static NSString* const ICCacheDeletionFileWasPresentKey = @"fileWasPresent";
static const NSUInteger ICAutomaticDownloadRetryScanBatchSize = 50;
static const NSUInteger ICAutomaticDownloadRetryTrackedCapacity = 3;
static const NSTimeInterval ICAutomaticDownloadRetryInitialBackoff = 60.0;
static const NSTimeInterval ICAutomaticDownloadRetryMaximumBackoff = 6.0 * 60.0 * 60.0;
static NSString* const ICAutomaticDownloadRetryClassificationKey = @"retryClassification";
static NSString* const ICAutomaticDownloadRetryAttemptKey = @"retryAttempt";
static NSString* const ICAutomaticDownloadRetryNextEligibleTimestampKey = @"retryNextEligibleTimestamp";
static NSString* const ICAutomaticDownloadRetryTransient = @"transient";
static NSString* const ICAutomaticDownloadRetryPermanent = @"permanent";

NSString* CacheManagerDidStartCachingNotification = @"CacheManagerDidStartCachingNotification";
NSString* CacheManagerDidEndCachingNotification = @"CacheManagerDidEndCachingNotification";
NSString* CacheManagerDidAddEpisodeToCachingQueueNotification = @"CacheManagerDidAddEpisodeToCachingQueueNotification";

NSString* CacheManagerDidUpdateNotification = @"CacheManagerDidUpdateNotification";
NSString* CacheManagerDidLoadFeedImageNotification = @"CacheManagerDidLoadFeedImageNotification";
NSString* CacheManagerDidStartCachingEpisodeNotification = @"CacheManagerDidStartCachingEpisodeNotification";
NSString* CacheManagerDidFinishCachingEpisodeNotification = @"CacheManagerDidFinishCachingEpisodeNotification";
NSString* CacheManagerDidFailCachingEpisodeNotification = @"CacheManagerDidFailCachingEpisodeNotification";
NSString* CacheManagerDidCancelStreamingCacheEpisodeNotification = @"CacheManagerDidCancelStreamingCacheEpisodeNotification";
NSString* CacheManagerDidClearCacheNotification = @"CacheManagerDidClearCacheNotification";
NSString* CacheManagerWillDeleteCacheFilesNotification = @"CacheManagerWillDeleteCacheFilesNotification";
NSString* CacheManagerWillCommitCacheFileDeletionNotification = @"CacheManagerWillCommitCacheFileDeletionNotification";
NSString* CacheManagerDidDeleteCacheFilesNotification = @"CacheManagerDidDeleteCacheFilesNotification";
NSString* CacheManagerDidRestoreCacheNotification = @"CacheManagerDidRestoreCacheNotification";
NSString* CacheManagerDidFinishBuildingCacheIndexNotification = @"CacheManagerDidFinishBuildingCacheIndexNotification";
NSString* CacheManagerDidBecomeReadyForAutomaticDownloadsNotification = @"CacheManagerDidBecomeReadyForAutomaticDownloadsNotification";

NSString* CacheManagerWiFiDidBecomeAvailableNotification = @"CacheManagerWiFiDidBecomeAvailableNotification";

static CacheManager* gSharedCacheManager = nil;
static NSString* gPathToCache = nil;

static NSString* ICTranscriptArtifactsPath(void)
{
    return [[ICTranscriptionPaths transcriptCacheDirectory] path];
}

static BOOL ICCacheFileErrorMeansMissing(NSError* error)
{
    NSError* currentError = error;
    while (currentError) {
        if ([currentError.domain isEqualToString:NSCocoaErrorDomain] &&
            (currentError.code == NSFileNoSuchFileError || currentError.code == NSFileReadNoSuchFileError)) {
            return YES;
        }
        currentError = currentError.userInfo[NSUnderlyingErrorKey];
    }
    return NO;
}

static NSError* ICCacheDeletionDurabilityError(NSError* underlyingError)
{
    return [NSError errorWithDomain:@"CacheManager"
                               code:36
                           userInfo:@{
                               NSLocalizedDescriptionKey: @"Downloaded files could not be removed because pending transcription jobs could not be saved. Check available storage and try again.".ls,
                               NSUnderlyingErrorKey: underlyingError ?: [NSError errorWithDomain:NSCocoaErrorDomain
                                                                                             code:NSFileWriteUnknownError
                                                                                         userInfo:nil],
                           }];
}

@interface ICCachePhysicalURLSnapshot : NSObject
@property (nonatomic, copy) NSDictionary<NSString*, NSArray<NSURL*>*>* URLsByEpisodeHash;
@property (nonatomic, strong) NSError* error;
@end

@implementation ICCachePhysicalURLSnapshot
@end

@interface ICTranscriptCacheSnapshot : NSObject
@property (nonatomic, copy) NSDictionary<NSString*, NSArray<NSURL*>*>* URLsByEpisodeHash;
@property (nonatomic, strong) NSError* error;
@end

@implementation ICTranscriptCacheSnapshot
@end

static ICTranscriptCacheSnapshot* ICTranscriptCacheURLSnapshot(void)
{
    ICTranscriptCacheSnapshot* snapshot = [[ICTranscriptCacheSnapshot alloc] init];
    NSString* transcriptCachePath = ICTranscriptArtifactsPath();
    if (transcriptCachePath.length == 0) {
        snapshot.URLsByEpisodeHash = @{};
        return snapshot;
    }

    NSFileManager* fileManager = [[NSFileManager alloc] init];
    NSError* directoryError = nil;
    NSArray<NSString*>* fileNames = [fileManager contentsOfDirectoryAtPath:transcriptCachePath error:&directoryError];
    if (ICCacheFileErrorMeansMissing(directoryError)) directoryError = nil;

    NSMutableDictionary<NSString*, NSMutableArray<NSURL*>*>* mutableURLsByHash = [NSMutableDictionary dictionary];
    for (NSString* fileName in fileNames) {
        if (![[fileName pathExtension] isEqualToString:@"trcache"]) continue;
        NSString* baseName = [fileName stringByDeletingPathExtension];
        NSRange separator = [baseName rangeOfString:@"_" options:NSBackwardsSearch];
        if (separator.location == NSNotFound || separator.location == 0) continue;
        NSString* episodeHash = [baseName substringToIndex:separator.location];
        NSMutableArray<NSURL*>* URLs = mutableURLsByHash[episodeHash];
        if (!URLs) {
            URLs = [NSMutableArray array];
            mutableURLsByHash[episodeHash] = URLs;
        }
        [URLs addObject:[NSURL fileURLWithPath:[transcriptCachePath stringByAppendingPathComponent:fileName]]];
    }

    NSMutableDictionary<NSString*, NSArray<NSURL*>*>* URLsByHash = [NSMutableDictionary dictionaryWithCapacity:mutableURLsByHash.count];
    [mutableURLsByHash enumerateKeysAndObjectsUsingBlock:^(NSString* episodeHash,
                                                            NSMutableArray<NSURL*>* URLs,
                                                            BOOL* stop) {
        URLsByHash[episodeHash] = [URLs copy];
    }];
    snapshot.URLsByEpisodeHash = [URLsByHash copy];
    snapshot.error = directoryError;
    return snapshot;
}

static NSError* ICRemoveTranscriptCacheURLsForEpisodeHashes(NSSet<NSString*>* episodeHashes,
                                                             ICTranscriptCacheSnapshot* snapshot)
{
    if (snapshot.error) {
        NSString* transcriptCachePath = ICTranscriptArtifactsPath();
        [[ICDiagnosticLogger shared] logDirectoryEvent:@"cache"
                                               message:@"Transcript-Cache konnte nicht gelesen werden"
                                                  path:transcriptCachePath
                                              metadata:@{ @"error": snapshot.error.localizedDescription ?: @"" }];
        return snapshot.error;
    }
    if (episodeHashes.count == 0) return nil;

    NSFileManager* fileManager = [[NSFileManager alloc] init];
    NSInteger removedFileCount = 0;
    NSInteger failedFileCount = 0;
    NSError* firstRemovalError = nil;
    for (NSString* episodeHash in episodeHashes) {
        for (NSURL* fileURL in snapshot.URLsByEpisodeHash[episodeHash]) {
            NSError* removalError = nil;
            if ([fileManager removeItemAtURL:fileURL error:&removalError] || ICCacheFileErrorMeansMissing(removalError)) {
                removedFileCount += 1;
            } else {
                failedFileCount += 1;
                if (!firstRemovalError) firstRemovalError = removalError;
            }
        }
    }
    if (removedFileCount > 0 || failedFileCount > 0) {
        [[ICDiagnosticLogger shared] logDirectoryEvent:@"cache"
                                               message:(failedFileCount == 0 ? @"Transcript-Artefakte für Episoden entfernt" : @"Transcript-Artefakte konnten nicht vollständig entfernt werden")
                                                  path:ICTranscriptArtifactsPath()
                                              metadata:@{
                                                  @"episodeHashes": @(episodeHashes.count),
                                                  @"removedFiles": @(removedFileCount),
                                                  @"failedFiles": @(failedFileCount),
                                                  @"error": firstRemovalError.localizedDescription ?: @"",
                                              }];
    }
    return firstRemovalError;
}

static NSError* ICRemoveTranscriptCacheForEpisodeHashesReturningError(NSSet<NSString*>* episodeHashes)
{
    if (episodeHashes.count == 0) return nil;
    return ICRemoveTranscriptCacheURLsForEpisodeHashes(episodeHashes, ICTranscriptCacheURLSnapshot());
}

static void ICRemoveTranscriptCacheForEpisodeHashes(NSSet<NSString*>* episodeHashes)
{
    (void)ICRemoveTranscriptCacheForEpisodeHashesReturningError(episodeHashes);
}

static NSError* ICClearAllTranscriptCache(void)
{
    NSString* transcriptCachePath = ICTranscriptArtifactsPath();
    if (transcriptCachePath.length == 0) {
        return nil;
    }

    NSError* error = nil;
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:transcriptCachePath error:&error];
    [[ICDiagnosticLogger shared] logDirectoryEvent:@"cache"
                                           message:(removed ? @"Gesamter Transcript-Artefaktordner entfernt" : @"Transcript-Artefaktordner konnte nicht entfernt werden")
                                              path:transcriptCachePath
                                              metadata:@{
                                                  @"error": error.localizedDescription ?: @"",
                                              }];
    if (removed || ICCacheFileErrorMeansMissing(error)) return nil;
    return error;
}

#if TARGET_OS_IPHONE
@interface CacheManager () <CacheOperationDelegate, NSURLSessionDelegate>
#else
@interface CacheManager () <CacheOperationDelegate>
#endif
@property (readwrite) double rate;
@property (nonatomic, strong) ICCacheHistory* cacheHistory;
@property (nonatomic, strong) NSTimer* timer;
- (NSString*) _streamingCacheKeyForEpisode:(CDEpisode*)episode;
- (BOOL) _hasStreamingCacheForEpisode:(CDEpisode*)episode;
- (void) _restoreFailedDownloads;
- (NSString*) _failedDownloadsStatePath;
- (NSString*) _failedDownloadsStateDirectoryPath;
- (NSString*) _failedDownloadStatePathForIdentifier:(NSString*)identifier;
- (NSError*) _writeFailedDownloadMetadataNow:(NSDictionary*)metadata forIdentifier:(NSString*)identifier;
- (void) _migrateLegacyFailedDownloadsNow;
- (void) _persistFailedDownloadMetadata:(NSDictionary*)metadata
                           forIdentifier:(NSString*)identifier
                              completion:(void (^)(NSError* error))completion;
- (void) _deletePersistedFailedDownloadForIdentifier:(NSString*)identifier
                                           completion:(void (^)(NSError* error))completion;
- (void) _deletePersistedFailedDownloadsForIdentifiers:(NSArray<NSString*>*)identifiers
                                             completion:(void (^)(NSSet<NSString*>* successfulIdentifiers, NSError* error))completion;
- (void) _deletePersistedFailedDownloadFilesForIdentifiers:(NSArray<NSString*>*)identifiers
                                                  completion:(void (^)(NSSet<NSString*>* successfulIdentifiers, NSError* error))completion;
- (void) _clearDownloadErrorsForEpisodeHashes:(NSSet<NSString*>*)episodeHashes
                                     completion:(void (^)(NSError* error))completion;
- (NSDictionary*) savedCachingInfoForIdentifier:(NSString*)identifier;
- (NSString*) _savedCachingKeyForIdentifier:(NSString*)identifier;
- (void) _persistCachingOperation:(CACHE_OPERATION_CLASS*)operation;
- (void) _removeSavedCachingInfoForIdentifier:(NSString*)identifier;
- (void) _removeAllSavedCachingInfos;
- (NSArray<NSDictionary*>*) _savedCachingInfosMigratingLegacyIfNeeded;
- (NSUInteger)_restoreDownloadsDeferredBySubscriptionCleanup;
- (void) _startNextDownloadOperations;
- (BOOL)_subscriptionCleanupBlocksEpisode:(CDEpisode*)episode;
- (BOOL)_deferDownloadUntilSubscriptionCleanupFinishes:(CDEpisode*)episode
                                               autoCache:(BOOL)autoCache
                                 overwriteCellularLock:(BOOL)overwriteCellularLock
                                    reportsFailureToUser:(BOOL)reportsFailureToUser
                                  preservesConsumedState:(BOOL)preservesConsumedState
                                                queueRank:(NSNumber*)queueRank;
- (void)_promoteDownloadsDeferredBySubscriptionCleanup;
- (void)_removeDownloadDeferredBySubscriptionCleanupForIdentifier:(NSString*)identifier
                                              removeNormalDescriptor:(BOOL)removeNormalDescriptor;
- (void)_resumeDownloadsAfterSubscriptionCleanupProtectionChange:(NSNotification*)notification;
- (BOOL) _networkAllowsDownloadOperation:(CACHE_OPERATION_CLASS*)operation;
- (BOOL) _removeTrackedDownloadOperation:(CACHE_OPERATION_CLASS*)operation;
- (BOOL)_requestDownloadOperationYield:(CACHE_OPERATION_CLASS*)operation;
- (BOOL)_replaceYieldedDownloadOperation:(CACHE_OPERATION_CLASS*)operation;
- (void)_removeCachingEpisodeForIdentifierIfUnowned:(NSString*)identifier;
- (void) _ensureDownloadUpdateTimer;
- (void) _finishDownloadBatchAfterOperation:(CACHE_OPERATION_CLASS*)operation;
- (void) _setDownloadedBytes:(unsigned long long)bytes known:(BOOL)known;
- (void) _addDownloadedBytes:(unsigned long long)bytes;
- (void) _subtractDownloadedBytes:(unsigned long long)bytes;
- (void) _invalidateDownloadedBytesAndRecalculate;
- (unsigned long long)_activeStreamingCacheBytes;
- (void)_setStreamingCacheBytes:(unsigned long long)bytes forIdentifier:(NSString*)identifier;
- (void)_removeStreamingCacheBytesForIdentifier:(NSString*)identifier;
- (BOOL)_removeOrphanedStreamingCacheDirectoriesWithFileManager:(NSFileManager*)fileManager
                                                           error:(NSError**)error;
- (ICCachePhysicalURLSnapshot*)_physicalCacheURLSnapshot;
- (void)_removeCacheRequestsForEpisodes:(NSArray<CDEpisode*>*)episodes
                               automatic:(BOOL)automatic
                     physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot
                              completion:(void (^)(NSError* error))completion;
- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes
                       automatic:(BOOL)automatic
                      completion:(void (^)(NSError* error))completion;
- (void)_removeCacheForFeeds:(NSArray<CDFeed*>*)feeds
                    automatic:(BOOL)automatic
preserveSubscriptionCleanupDeferredStarts:(BOOL)preserveDeferredStarts
                   completion:(void (^)(NSError* error))completion;
- (void)_cancelCachingFeeds:(NSArray<CDFeed*>*)feeds
preserveSubscriptionCleanupDeferredStarts:(BOOL)preserveDeferredStarts
                  completion:(void (^)(NSError* error))completion;
- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes
                       automatic:(BOOL)automatic
             physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot
                      completion:(void (^)(NSError* error))completion;
- (void)_performCacheFileDeletionForItems:(NSArray<NSDictionary*>*)items
                                     token:(NSString*)token
                                generation:(NSUInteger)generation
                                 automatic:(BOOL)automatic
                       deletionPreparation:(ICCacheDeletionPreparation*)deletionPreparation
                       physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot;
- (void)_finishCacheFileDeletionForItems:(NSArray<NSDictionary*>*)items
                                  results:(NSArray<NSDictionary*>*)results
                                    token:(NSString*)token
                               generation:(NSUInteger)generation
                                automatic:(BOOL)automatic;
- (void)_presentCacheDeletionError:(NSError*)error automatic:(BOOL)automatic;
- (void)_completeCacheDeletionForIdentifier:(NSString*)identifier error:(NSError*)error;
- (void)_beginRemovalAfterCancellingEpisode:(CDEpisode*)episode
                                  automatic:(BOOL)automatic
                        physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot
                                  completion:(void (^)(NSError* error))completion;
- (void)_finishCancelledDownloadRemovalForIdentifier:(NSString*)identifier;
- (NSArray<NSManagedObjectID*>*)_autoClearSelectionFromItems:(NSArray<NSDictionary*>*)items
                                               bytesToDelete:(unsigned long long)bytesToDelete
                                          needsRecalculation:(BOOL*)needsRecalculation;
- (void)_recordPendingAutoClearBytes:(unsigned long long)bytes automatic:(BOOL)automatic;
- (void)_buildCacheIndexInBackground;
- (void)_retryCacheIndexIfNeeded:(NSNotification*)notification;
- (void)_restoreCachingEpisodesWhenHistoryReady;
- (void)_importFileAtURL:(NSURL*)url
              forEpisode:(CDEpisode*)episode
      streamingLeaseToken:(NSString*)streamingLeaseToken
              movesSource:(BOOL)movesSource
              completion:(void (^)(BOOL success, NSError* error))completion;
- (ICCacheDeletionPreparation*) _prepareForDestructiveCacheClear;
- (void) _commitDestructiveCacheClearPreparation;
- (void) _finalizeDestructiveCacheClearJobState;
- (NSError*) _deleteAllCacheFilesNow;
- (NSError*) _finishDestructiveCacheClear;
- (void)_persistSuccessfulDownloadForOperation:(CACHE_OPERATION_CLASS*)operation
                                    completion:(void (^)(NSError* error))completion;
- (void)_finishCacheOperationDidEnd:(CACHE_OPERATION_CLASS*)operation
                   persistenceError:(NSError*)persistenceError;
- (void)_cancelCachingEpisode:(CDEpisode*)episode
          disableAutoDownload:(BOOL)disableAutodownload
                   completion:(void (^)(BOOL waitsForOperationEnd, NSError* error))completion;
- (void)_cancelTrackedDownloadOperationAfterDurableIntent:(CACHE_OPERATION_CLASS*)operation;
- (void)_cancelDownloadOperationForStreamingTransition:(CACHE_OPERATION_CLASS*)operation;
- (void)_cancelCachingEpisodeAfterDurableIntent:(CDEpisode*)episode
                            disableAutoDownload:(BOOL)disableAutodownload;
- (void)_cancelStreamingCacheForEpisodeAfterDurableIntent:(CDEpisode*)episode
                                       disableAutoDownload:(BOOL)disableAutodownload;
- (BOOL) _cacheEpisode:(CDEpisode*)episode
             autoCache:(BOOL)autoCache
overwriteCellularLock:(BOOL)overwriteCellularLock
reportsFailureToUser:(BOOL)reportsFailureToUser
             queueRank:(NSNumber*)queueRank;
- (BOOL) _cacheEpisode:(CDEpisode*)episode
             autoCache:(BOOL)autoCache
overwriteCellularLock:(BOOL)overwriteCellularLock
reportsFailureToUser:(BOOL)reportsFailureToUser
             queueRank:(NSNumber*)queueRank
preservesConsumedState:(BOOL)preservesConsumedState
deferDuringSubscriptionCleanup:(BOOL)deferDuringSubscriptionCleanup;
- (void) _completeBackgroundSessionForIdentifier:(NSString*)identifier;
- (void) _cancelOrphanedBackgroundSession:(NSString*)identifier;
- (void)_recordDownloadError:(NSError*)error
                  forEpisode:(CDEpisode*)episode
                   automatic:(BOOL)automatic
      overwriteCellularLock:(BOOL)overwriteCellularLock
        reportsFailureToUser:(BOOL)reportsFailureToUser
      preservesConsumedState:(BOOL)preservesConsumedState
                  completion:(void (^)(NSError* error))completion;
- (NSString*)_automaticRetryClassificationForError:(NSError*)error;
- (NSTimeInterval)_automaticRetryBackoffForAttempt:(NSUInteger)attempt;
- (NSDictionary*)_automaticRetryMetadataByAddingMissingState:(NSDictionary*)metadata error:(NSError*)error;
- (BOOL)_automaticRetryFailureIsStaleForEpisode:(CDEpisode*)episode;
- (void)_cancelAutomaticRetryWake;
- (void)_scheduleAutomaticRetryWakeAtTimestamp:(NSTimeInterval)timestamp;
- (void)_processAutomaticRetryScanChunk;
- (void)_drainPendingAutomaticRetries;
- (void)_continueDrainingPendingAutomaticRetries;
- (void)_automaticRetryOperationDidFinishWithIdentifier:(NSString*)identifier;
@end


@implementation CacheManager {
@protected
	NSMutableSet*               _cachedEpisodes;
	NSMutableDictionary*		_cachedURLIndex;
	NSOperationQueue*			_downloadQueue;
	NSInteger					_totalOps;
	BOOL                        _currentQueueHadFailure;
	NSTimer*					_updateTimer;
#if TARGET_OS_IPHONE
#else
    IOPMAssertionID             _noSystemSleepAssertionID;
#endif
    NSMutableArray*             _cachingEpisodes;
    NSMutableSet<NSString*>*    _cachingEpisodeHashes;
    NSMutableDictionary<NSString*, CACHE_OPERATION_CLASS*>* _downloadOperationsByIdentifier;
    NSMutableSet<NSString*>*    _scheduledDownloadOperationIdentifiers;
    NSMutableDictionary<NSString*, NSDictionary*>* _subscriptionCleanupDeferredDownloadInfosByIdentifier;
    NSMutableDictionary<NSString*, CDEpisode*>* _subscriptionCleanupDeferredDownloadEpisodesByIdentifier;
    NSMutableSet<NSString*>*    _subscriptionCleanupBackgroundSessionCancellationIdentifiers;
    BOOL                        _subscriptionCleanupResumeScheduled;
    BOOL                        _subscriptionCleanupPromotionRequested;
    NSArray<NSString*>*         _subscriptionCleanupPromotionIdentifiers;
    NSUInteger                 _subscriptionCleanupPromotionCursor;
    NSMutableSet<NSString*>*    _finalizingDownloadOperationIdentifiers;
    NSMutableDictionary<NSString*, NSString*>* _downloadPauseYieldTokensByIdentifier;
    NSMutableDictionary<NSString*, NSNumber*>* _downloadQueueRanksByIdentifier;
    NSMutableSet<NSString*>*    _manuallySuspendedDownloadIdentifiers;
    NSMutableSet<NSString*>*    _pendingDurableCancellationIdentifiers;
    NSMutableDictionary<NSString*, NSMutableArray*>* _durableCancellationCompletionsByIdentifier;
    long long                   _nextDownloadQueueRank;
    NSMutableArray<CDEpisode*>* _failedDownloadEpisodes;
    NSMutableSet<NSString*>*    _failedDownloadEpisodeHashes;
    NSMutableDictionary<NSString*, NSError*>* _downloadErrorsByEpisodeHash;
    NSMutableDictionary<NSString*, NSDictionary*>* _failedDownloadMetadataByEpisodeHash;
    dispatch_queue_t            _failedDownloadPersistenceQueue;
    NSUInteger                  _failedDownloadRestoreGeneration;
    NSUInteger                  _failedDownloadMutationGeneration;
    NSMutableDictionary<NSString*, NSNumber*>* _failedDownloadMutationGenerationsByEpisodeHash;
    NSMutableOrderedSet<NSString*>* _pendingAutomaticRetryEpisodeHashes;
    NSMutableSet<NSString*>*    _automaticRetryInFlightEpisodeHashes;
    NSMutableDictionary<NSString*, NSNumber*>* _automaticRetryAttemptsByActiveEpisodeHash;
    NSMutableSet<NSString*>*    _automaticRetryMetadataUpdateEpisodeHashes;
    NSMutableSet<NSString*>*    _automaticRetrySuppressedEpisodeHashes;
    dispatch_source_t           _automaticRetryWakeSource;
    NSTimeInterval              _automaticRetryWakeTimestamp;
    NSTimeInterval              _automaticRetryNextWakeTimestamp;
    NSUInteger                  _automaticRetryWakeGeneration;
    NSUInteger                  _automaticRetryScanCursor;
    BOOL                        _automaticRetryScanInProgress;
    BOOL                        _automaticRetryRescanRequested;
    NSUInteger                  _automaticRetryDrainRemainingCount;
    BOOL                        _automaticRetryDrainContinuationScheduled;
    BOOL                        _automaticRetryDrainRescanRequested;
    NSMutableDictionary<NSString*, void (^)(void)>* _backgroundSessionCompletionHandlers;
    NSMutableDictionary<NSString*, NSURLSession*>* _orphanedBackgroundSessionsByIdentifier;
    NSMutableDictionary*        _streamingCacheProgresses;
    NSMutableDictionary<NSString*, NSString*>* _streamingCacheLeaseTokensByIdentifier;
    NSMutableDictionary<NSString*, NSNumber*>* _streamingCacheBytesByIdentifier;
    NSMutableSet<NSString*>*    _streamingCacheRecoveryCandidateTokens;
    unsigned long long          _downloadedBytes;
    BOOL                        _downloadedBytesKnown;
    BOOL                        _downloadedBytesRecalculationInFlight;
    NSUInteger                  _downloadedBytesGeneration;
    NSUInteger                  _cacheIndexGeneration;
    dispatch_queue_t            _cacheDeletionQueue;
    NSMutableDictionary<NSString*, NSString*>* _cacheDeletionTokensByIdentifier;
    NSMutableDictionary<NSString*, NSMutableArray*>* _cacheDeletionCompletionsByIdentifier;
    NSMutableSet<NSString*>*    _cacheDeletionHashesDuringIndexScan;
    NSMutableDictionary<NSString*, NSString*>* _cacheImportTokensByIdentifier;
    NSMutableDictionary<NSString*, NSDictionary*>* _cancelledDownloadRemovalRequestsByIdentifier;
    NSDictionary<NSString*, NSURL*>* _cacheClearRemainingURLsByHash;
    NSSet<NSString*>*          _cacheClearRemovedHashes;
    unsigned long long        _cacheClearRemainingBytes;
    BOOL                       _cacheClearSnapshotValid;
    BOOL                        _cacheIndexReady;
    BOOL                        _cacheIndexScanInFlight;
    BOOL                        _cachingEpisodesRestored;
    BOOL                        _clearingAllCache;
    BOOL                        _hasPendingAutoClear;
    BOOL                        _autoClearSelectionInFlight;
    unsigned long long          _pendingAutoClearBytes;
    BOOL                        _pendingAutoClearAutomatic;
    NSDate*                     _rateDate;
    int64_t                     _rateBytes;

    struct {
        unsigned int supressSendUpdate:1;
        unsigned int supressDidClear:1;
        unsigned int restoringCachingEpisodes:1;
    } _flags;
}

+ (NSString*) _pathToCache
{
	if (gPathToCache) {
		return gPathToCache;
	}
	
	NSArray* paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* path = [[paths lastObject] stringByAppendingPathComponent:@"Episodes"];
	
	NSFileManager* fman = [NSFileManager defaultManager];
	if (![fman fileExistsAtPath:path])
	{
		NSError* error = nil;
		if (![fman createDirectoryAtPath:path withIntermediateDirectories:YES
							  attributes:nil
								   error:&error]) {
			ErrLog(@"error creating directory %@: %@", path, [error description]);
			return nil;
		}
	}
	
	gPathToCache = [path copy];
	return path;
}

+ (NSString*) _pathToStorageLocation
{
#if TARGET_OS_IPHONE
    if ([NSBundle systemVersion] < 0x50001) {
        return [self _pathToCache];
    }
#endif
    return [DMANAGER.fileCacheURL path];
}


+ (CacheManager*) sharedCacheManager
{
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		gSharedCacheManager = [[self alloc] init];
	});
	return gSharedCacheManager;
}

- (id) init
{
	if ((self = [super init]))
	{
		_downloadQueue = [[NSOperationQueue alloc] init];
		[_downloadQueue setMaxConcurrentOperationCount:3];
#if TARGET_OS_IPHONE
        [CACHE_OPERATION_CLASS prepareResumeInfoStore];
#endif

		// build cache index
        _cachedEpisodes = [[NSMutableSet alloc] init];
        _cachedURLIndex = [[NSMutableDictionary alloc] init];
        _cacheDeletionQueue = dispatch_queue_create("com.vemedio.instacast.cacheDeletion", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_cacheDeletionQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        _cacheDeletionTokensByIdentifier = [[NSMutableDictionary alloc] init];
        _cacheDeletionCompletionsByIdentifier = [[NSMutableDictionary alloc] init];
        _cacheDeletionHashesDuringIndexScan = [[NSMutableSet alloc] init];
        _cacheImportTokensByIdentifier = [[NSMutableDictionary alloc] init];
        _cancelledDownloadRemovalRequestsByIdentifier = [[NSMutableDictionary alloc] init];
        _cachingEpisodes = [[NSMutableArray alloc] init];
        _cachingEpisodeHashes = [[NSMutableSet alloc] init];
        _downloadOperationsByIdentifier = [[NSMutableDictionary alloc] init];
        _scheduledDownloadOperationIdentifiers = [[NSMutableSet alloc] init];
        _subscriptionCleanupDeferredDownloadInfosByIdentifier = [[NSMutableDictionary alloc] init];
        _subscriptionCleanupDeferredDownloadEpisodesByIdentifier = [[NSMutableDictionary alloc] init];
        _subscriptionCleanupBackgroundSessionCancellationIdentifiers = [[NSMutableSet alloc] init];
        _finalizingDownloadOperationIdentifiers = [[NSMutableSet alloc] init];
        _downloadPauseYieldTokensByIdentifier = [[NSMutableDictionary alloc] init];
        _downloadQueueRanksByIdentifier = [[NSMutableDictionary alloc] init];
        _manuallySuspendedDownloadIdentifiers = [[NSMutableSet alloc] init];
        _pendingDurableCancellationIdentifiers = [[NSMutableSet alloc] init];
        _durableCancellationCompletionsByIdentifier = [[NSMutableDictionary alloc] init];
        self.suspended = [USER_DEFAULTS boolForKey:ICDownloadQueueSuspended];
        _failedDownloadEpisodes = [[NSMutableArray alloc] init];
        _failedDownloadEpisodeHashes = [[NSMutableSet alloc] init];
        _downloadErrorsByEpisodeHash = [[NSMutableDictionary alloc] init];
        _failedDownloadMetadataByEpisodeHash = [[NSMutableDictionary alloc] init];
        _failedDownloadMutationGenerationsByEpisodeHash = [[NSMutableDictionary alloc] init];
        _pendingAutomaticRetryEpisodeHashes = [[NSMutableOrderedSet alloc] init];
        _automaticRetryInFlightEpisodeHashes = [[NSMutableSet alloc] init];
        _automaticRetryAttemptsByActiveEpisodeHash = [[NSMutableDictionary alloc] init];
        _automaticRetryMetadataUpdateEpisodeHashes = [[NSMutableSet alloc] init];
        _automaticRetrySuppressedEpisodeHashes = [[NSMutableSet alloc] init];
        _failedDownloadPersistenceQueue = dispatch_queue_create("com.vemedio.instacast.failedDownloadPersistence", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_failedDownloadPersistenceQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        _backgroundSessionCompletionHandlers = [[NSMutableDictionary alloc] init];
        _orphanedBackgroundSessionsByIdentifier = [[NSMutableDictionary alloc] init];
        _streamingCacheProgresses = [[NSMutableDictionary alloc] init];
        _streamingCacheLeaseTokensByIdentifier = [[NSMutableDictionary alloc] init];
        _streamingCacheBytesByIdentifier = [[NSMutableDictionary alloc] init];
        _streamingCacheRecoveryCandidateTokens = [[NSMutableSet alloc] init];
        
        NSString* historyFile = [[DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]] stringByAppendingPathComponent:@"CacheHistory.plist"];
        _cacheHistory = [[ICCacheHistory alloc] initWithContentsOfFile:historyFile];

        [App addTaskObserver:self forKeyPath:@"networkAccessTechnology" task:^(id obj, NSDictionary *change) {
            [self _handleNetworkStatusChanged];
        }];

#if TARGET_OS_IPHONE
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_retryCacheIndexIfNeeded:)
                                                     name:UIApplicationProtectedDataDidBecomeAvailable
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_retryCacheIndexIfNeeded:)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
#endif
        [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(_resumeDownloadsAfterSubscriptionCleanupProtectionChange:)
                   name:SubscriptionManagerUnsubscribeCleanupProtectionDidChangeNotification
                 object:nil];
        [self _buildCacheIndexInBackground];
	}

	return self;
}

- (void)prepareCacheIndexIfNeeded
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self prepareCacheIndexIfNeeded];
        });
        return;
    }
    [self _buildCacheIndexInBackground];
}

- (void)_retryCacheIndexIfNeeded:(NSNotification*)notification
{
    (void)notification;
    [self _restoreCachingEpisodesWhenHistoryReady];
    [self prepareCacheIndexIfNeeded];
    if (!_downloadedBytesKnown) {
        [self recalculateDownloadedBytesInBackground];
    }
}

- (void)_restoreCachingEpisodesWhenHistoryReady
{
    if (_cachingEpisodesRestored) {
        [self retryFailedAutomaticDownloadsIfPossible];
        if (self.readyForAutomaticDownloads) {
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidBecomeReadyForAutomaticDownloadsNotification
                                                                object:self];
        }
        return;
    }
    [self.cacheHistory reloadIfNeededWithCompletion:^(NSError* historyError) {
        if (historyError) {
            ErrLog(@"download history is still unavailable: %@", historyError);
            return;
        }
        if (self->_cachingEpisodesRestored || !self->_cacheIndexReady) return;
        self->_cachingEpisodesRestored = YES;
        [self restoreCachingEpisodes];
        [self retryFailedAutomaticDownloadsIfPossible];
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidBecomeReadyForAutomaticDownloadsNotification
                                                            object:self];
    }];
}

- (BOOL)_removeOrphanedStreamingCacheDirectoriesWithFileManager:(NSFileManager*)fileManager
                                                           error:(NSError**)error
{
    NSString* streamingRoot = [[CacheManager _pathToCache] stringByAppendingPathComponent:@"Streaming"];
    NSError* listingError = nil;
    NSArray<NSString*>* candidateNames = [fileManager contentsOfDirectoryAtPath:streamingRoot
                                                                           error:&listingError];
    if (!candidateNames) {
        if (ICCacheFileErrorMeansMissing(listingError)) {
            return YES;
        }
        if (error) *error = listingError;
        return NO;
    }

    __block NSArray<NSString*>* removableCandidateNames = nil;
    void (^reserveInactiveCandidates)(void) = ^{
        NSSet<NSString*>* activeLeaseTokens = [NSSet setWithArray:self->_streamingCacheLeaseTokensByIdentifier.allValues];
        NSMutableArray<NSString*>* removable = [NSMutableArray arrayWithCapacity:candidateNames.count];
        for (NSString* candidateName in candidateNames) {
            if ([activeLeaseTokens containsObject:candidateName]) {
                continue;
            }
            [self->_streamingCacheRecoveryCandidateTokens addObject:candidateName];
            [removable addObject:candidateName];
        }
        removableCandidateNames = [removable copy];
    };
    if ([NSThread isMainThread]) {
        reserveInactiveCandidates();
    } else {
        dispatch_sync(dispatch_get_main_queue(), reserveInactiveCandidates);
    }

    NSError* firstRemovalError = nil;
    for (NSString* candidateName in removableCandidateNames) {
        NSString* candidatePath = [streamingRoot stringByAppendingPathComponent:candidateName];
        NSError* removalError = nil;
        if (![fileManager removeItemAtPath:candidatePath error:&removalError] &&
            !ICCacheFileErrorMeansMissing(removalError) && !firstRemovalError) {
            firstRemovalError = removalError;
        }
    }
    void (^releaseCandidateReservations)(void) = ^{
        [self->_streamingCacheRecoveryCandidateTokens minusSet:[NSSet setWithArray:removableCandidateNames]];
    };
    if ([NSThread isMainThread]) {
        releaseCandidateReservations();
    } else {
        dispatch_sync(dispatch_get_main_queue(), releaseCandidateReservations);
    }
    if (firstRemovalError && error) *error = firstRemovalError;
    return firstRemovalError == nil;
}

- (void)_buildCacheIndexInBackground
{
    NSAssert([NSThread isMainThread], @"Cache index lifecycle must start on the main thread");
    if (_cacheIndexReady || _cacheIndexScanInFlight || _clearingAllCache) {
        return;
    }

    NSString* storagePath = [CacheManager _pathToStorageLocation];
    NSUInteger cacheIndexGeneration = _cacheIndexGeneration;
    NSUInteger downloadedBytesGeneration = _downloadedBytesGeneration;
    _cacheIndexReady = NO;
    _cacheIndexScanInFlight = YES;
    _downloadedBytesRecalculationInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager* fman = [[NSFileManager alloc] init];
        NSError* streamingCleanupError = nil;
        BOOL streamingCleanupSucceeded = [self _removeOrphanedStreamingCacheDirectoriesWithFileManager:fman
                                                                                                  error:&streamingCleanupError];
        NSString* streamingPath = [[CacheManager _pathToCache] stringByAppendingPathComponent:@"Streaming"];
        NSError* directoryError = nil;
        NSArray<NSString*>* directoryContent = [fman contentsOfDirectoryAtPath:storagePath error:&directoryError];
        BOOL cacheIndexSnapshotValid = (directoryContent != nil);
        if (!cacheIndexSnapshotValid && ICCacheFileErrorMeansMissing(directoryError)) {
            directoryContent = @[];
            directoryError = nil;
            cacheIndexSnapshotValid = YES;
        }

        NSMutableArray<NSString*>* episodeHashes = [[NSMutableArray alloc] init];
        NSMutableDictionary<NSString*, NSURL*>* cachedURLsByHash = [[NSMutableDictionary alloc] init];
        unsigned long long indexedBytes = 0;
        __block BOOL downloadedBytesSnapshotValid = cacheIndexSnapshotValid && streamingCleanupSucceeded;
        if (cacheIndexSnapshotValid) {
            for (NSString* filename in directoryContent) {
                NSString* filePath = [storagePath stringByAppendingPathComponent:filename];
                if ([filePath isEqualToString:streamingPath]) {
                    continue;
                }
                NSError* attributesError = nil;
                NSDictionary* attributes = [fman attributesOfItemAtPath:filePath error:&attributesError];
                if (attributes) {
                    indexedBytes += [attributes fileSize];
                } else if (!ICCacheFileErrorMeansMissing(attributesError)) {
                    downloadedBytesSnapshotValid = NO;
                    cacheIndexSnapshotValid = NO;
                }

                NSString* nameWithoutExt = [filename stringByDeletingPathExtension];
                NSRange lastDash = [nameWithoutExt rangeOfString:@" - " options:NSBackwardsSearch];
                NSString* hash = lastDash.location == NSNotFound
                    ? nameWithoutExt
                    : [nameWithoutExt substringFromIndex:NSMaxRange(lastDash)];
                if (hash.length > 0) {
                    [episodeHashes addObject:hash];
                    cachedURLsByHash[hash] = [NSURL fileURLWithPath:filePath];
                }
            }
        }

        NSString* partialDownloadsPath = [CacheManager _pathToCache];
        if (cacheIndexSnapshotValid && ![partialDownloadsPath isEqualToString:storagePath]) {
            NSURL* partialDownloadsURL = [NSURL fileURLWithPath:partialDownloadsPath isDirectory:YES];
            NSDirectoryEnumerator<NSURL*>* partialFiles = [fman enumeratorAtURL:partialDownloadsURL
                                                     includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                                        options:0
                                                                   errorHandler:^BOOL(NSURL* url, NSError* error) {
                (void)url;
                (void)error;
                downloadedBytesSnapshotValid = NO;
                return NO;
            }];
            for (NSURL* fileURL in partialFiles) {
                if ([fileURL.path isEqualToString:streamingPath]) {
                    [partialFiles skipDescendants];
                    continue;
                }
                NSNumber* regularFile = nil;
                NSNumber* fileSize = nil;
                NSError* resourceError = nil;
                if (![fileURL getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:&resourceError] ||
                    ![fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:&resourceError]) {
                    if (!ICCacheFileErrorMeansMissing(resourceError)) downloadedBytesSnapshotValid = NO;
                    continue;
                }
                if (regularFile.boolValue) indexedBytes += fileSize.unsignedLongLongValue;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_downloadedBytesRecalculationInFlight = NO;
            if (!self->_cacheIndexScanInFlight || cacheIndexGeneration != self->_cacheIndexGeneration) {
                self->_cacheIndexScanInFlight = NO;
                return;
            }
            self->_cacheIndexScanInFlight = NO;
            if (!streamingCleanupSucceeded) {
                [[ICDiagnosticLogger shared] logEvent:@"cache"
                                              message:@"Verwaiste Streaming-Dateien konnten nicht entfernt werden"
                                             metadata:@{ @"error": streamingCleanupError.localizedDescription ?: @"" }];
            }
            if (!cacheIndexSnapshotValid) {
                self->_cacheIndexReady = NO;
                [[ICDiagnosticLogger shared] logEvent:@"cache"
                                              message:@"Download-Index konnte nicht gelesen werden"
                                             metadata:@{ @"error": directoryError.localizedDescription ?: @"" }];
                return;
            }

            NSSet<NSString*>* hashesDeletedDuringScan = [self->_cacheDeletionHashesDuringIndexScan copy];
            if (hashesDeletedDuringScan.count > 0) {
                [episodeHashes removeObjectsInArray:hashesDeletedDuringScan.allObjects];
                [cachedURLsByHash removeObjectsForKeys:hashesDeletedDuringScan.allObjects];
                [self->_cacheDeletionHashesDuringIndexScan minusSet:hashesDeletedDuringScan];
            }

            NSMutableDictionary<NSString*, NSURL*>* validScannedURLs = [NSMutableDictionary dictionary];
            for (NSString* hash in cachedURLsByHash) {
                if (self->_cachedURLIndex[hash]) continue;
                NSURL* scannedURL = cachedURLsByHash[hash];
                NSError* reachabilityError = nil;
                if ([scannedURL checkResourceIsReachableAndReturnError:&reachabilityError]) {
                    validScannedURLs[hash] = scannedURL;
                } else if (ICCacheFileErrorMeansMissing(reachabilityError)) {
                    [episodeHashes removeObject:hash];
                } else {
                    self->_cacheIndexReady = NO;
                    [[ICDiagnosticLogger shared] logEvent:@"cache"
                                                  message:@"Download-Datei konnte nicht geprüft werden"
                                                 metadata:@{ @"error": reachabilityError.localizedDescription ?: @"" }];
                    return;
                }
            }

            self->_cacheIndexReady = YES;
            if (downloadedBytesSnapshotValid && self->_downloadedBytesGeneration == downloadedBytesGeneration) {
                unsigned long long activeStreamingBytes = [self _activeStreamingCacheBytes];
                unsigned long long totalBytes = ULLONG_MAX - indexedBytes < activeStreamingBytes
                    ? ULLONG_MAX
                    : indexedBytes + activeStreamingBytes;
                [self _setDownloadedBytes:totalBytes known:YES];
            } else if (!self->_downloadedBytesKnown) {
                [self recalculateDownloadedBytesInBackground];
            }

            NSArray* cachedEpisodes = [DMANAGER episodesWithObjectHashes:episodeHashes];
            [self->_cachedURLIndex addEntriesFromDictionary:validScannedURLs];
            [self willChangeValueForKey:@"cachedEpisodes"];
            [self->_cachedEpisodes addObjectsFromArray:cachedEpisodes];
            [self didChangeValueForKey:@"cachedEpisodes"];

            for (CDEpisode* episode in cachedEpisodes) {
                if (!episode.downloaded) episode.downloaded = YES;
            }

            [self _restoreFailedDownloads];
            [self _restoreCachingEpisodesWhenHistoryReady];
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidFinishBuildingCacheIndexNotification
                                                                object:self];
        });
    });
}

- (BOOL) canDownload
{
    BOOL enabled3G = [USER_DEFAULTS boolForKey:EnableCachingOver3G];
    if (App.networkAccessTechnology == kICNetworkAccessTechnlogyWIFI) {
        return YES;
    }

    if (App.networkAccessTechnology > kICNetworkAccessTechnlogyGPRS && enabled3G) {
        return YES;
    }

    return NO;
}

- (void) _handleNetworkStatusChanged
{
    NSArray* operations = [_downloadOperationsByIdentifier.allValues copy];
    for(CACHE_OPERATION_CLASS* operation in operations) {
        BOOL manuallySuspended = [_manuallySuspendedDownloadIdentifiers containsObject:operation.identifier];
        BOOL networkAllowed = [self _networkAllowsDownloadOperation:operation];
        CDEpisode* episode = [operation.userInfo isKindOfClass:[CDEpisode class]]
            ? operation.userInfo : nil;
        operation.suspended = !networkAllowed || self.suspended || manuallySuspended
            || [self _subscriptionCleanupBlocksEpisode:episode];
        if (!self.suspended && !manuallySuspended && !networkAllowed) {
            [self _requestDownloadOperationYield:operation];
        }
    }
    [self _startNextDownloadOperations];
    [self retryFailedAutomaticDownloadsIfPossible];
    if (![self canDownload]) {
        _rateDate = nil;
        _rateBytes = 0LL;
    }
}

- (BOOL) _networkAllowsDownloadOperation:(CACHE_OPERATION_CLASS*)operation
{
    if ([self canDownload]) {
        return YES;
    }
    return operation.overwriteCellularLock && App.networkAccessTechnology > kICNetworkAccessTechnlogyNone;
}


#pragma mark -

- (NSInteger) totalOperationCount
{
	return _totalOps;
}

- (NSInteger) finishedOperationCount
{
    NSInteger outstandingCount = MIN(_totalOps, (NSInteger)_downloadOperationsByIdentifier.count);
	return MAX(0, _totalOps - outstandingCount);
}

- (void) _postDidUpdateNotification
{
    if (![NSThread isMainThread]) {
        // UI updates are driven by the main-runloop timer.
        return;
    }

#if TARGET_OS_IPHONE
    for (NSString* identifier in _scheduledDownloadOperationIdentifiers) {
        CACHE_OPERATION_CLASS* operation = _downloadOperationsByIdentifier[identifier];
        int64_t loadedBytes = [operation drainLoadedBytesSinceLastUpdate];
        if (loadedBytes > 0) {
            if (!_rateDate) {
                _rateDate = [NSDate date];
                _rateBytes = 0LL;
            }
            _rateBytes += loadedBytes;
        }
    }
#endif

    if (_rateDate) {
        NSTimeInterval since = [[NSDate date] timeIntervalSinceDate:_rateDate];
        if (since >= 0.5) {
            self.rate = (double)_rateBytes / (double)since;
            _rateBytes = 0LL;
            _rateDate = nil;
        }
    }


	if (!_flags.supressSendUpdate) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidUpdateNotification object:self];
    }
}

#pragma mark -
#pragma mark Caching

static NSString* ICStringByTruncatingToUTF8ByteLength(NSString* string, NSUInteger maximumBytes)
{
    if ([string lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximumBytes) {
        return string;
    }
    NSMutableString* result = [NSMutableString string];
    __block NSUInteger usedBytes = 0;
    [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
                               options:NSStringEnumerationByComposedCharacterSequences
                            usingBlock:^(NSString* substring, NSRange substringRange, NSRange enclosingRange, BOOL* stop) {
        (void)substringRange;
        (void)enclosingRange;
        NSUInteger substringBytes = [substring lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (usedBytes + substringBytes > maximumBytes) {
            *stop = YES;
            return;
        }
        [result appendString:substring];
        usedBytes += substringBytes;
    }];
    return result;
}

static NSString* ICSanitizeFilenameComponent(NSString* string)
{
    if (!string || string.length == 0) return @"Untitled";

    // Replace filesystem-unsafe characters with dash
    NSMutableString* safe = [string mutableCopy];
    NSCharacterSet* unsafeChars = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSRange r;
    while ((r = [safe rangeOfCharacterFromSet:unsafeChars]).location != NSNotFound) {
        [safe replaceCharactersInRange:r withString:@"-"];
    }

    // Collapse multiple dashes/spaces
    while ([safe rangeOfString:@"--"].location != NSNotFound) {
        [safe replaceOccurrencesOfString:@"--" withString:@"-" options:0 range:NSMakeRange(0, safe.length)];
    }

    // Trim whitespace and dashes
    NSCharacterSet* trimSet = [NSCharacterSet characterSetWithCharactersInString:@" -"];
    NSString* result = [safe stringByTrimmingCharactersInSet:trimSet];

    // APFS/HFS+ limit one path component by encoded bytes, not UTF-16 characters.
    if ([result lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 80) {
        result = ICStringByTruncatingToUTF8ByteLength(result, 80);
        result = [result stringByTrimmingCharactersInSet:trimSet];
    }

    return result.length > 0 ? result : @"Untitled";
}

static NSString* ICSanitizeFilenameExtension(NSString* extension)
{
    NSString* candidate = extension ?: @"";
    NSCharacterSet* unsafeCharacters = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    candidate = [[candidate componentsSeparatedByCharactersInSet:unsafeCharacters] componentsJoinedByString:@""];
    candidate = ICStringByTruncatingToUTF8ByteLength(candidate, 12);
    return candidate.length > 0 ? candidate : @"mp3";
}

+ (NSString*)fileExtensionForMIMEType:(NSString*)mimeType
{
    NSString* normalized = [mimeType.lowercaseString componentsSeparatedByString:@";"].firstObject;
    normalized = [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDictionary<NSString*, NSString*>* extensions = @{
        @"audio/mpeg": @"mp3",
        @"audio/mp3": @"mp3",
        @"audio/mpeg3": @"mp3",
        @"audio/mpeg4": @"m4a",
        @"audio/mp4": @"m4a",
        @"audio/mp4a": @"m4a",
        @"audio/x-m4a": @"m4a",
        @"audio/m4a": @"m4a",
        @"audio/mp4a-latm": @"m4a",
        @"audio/aac": @"aac",
        @"audio/x-aac": @"aac",
        @"audio/ogg": @"ogg",
        @"application/ogg": @"ogg",
        @"audio/wav": @"wav",
        @"audio/x-wav": @"wav",
        @"audio/flac": @"flac",
        @"video/mpeg4": @"m4v",
        @"video/x-m4v": @"m4v",
        @"video/mp4": @"mp4",
        @"video/quicktime": @"mov",
    };
    return extensions[normalized];
}

- (NSString*) _extensionForEpisode:(CDEpisode*)episode
{
    CDMedium* media = [episode preferedMedium];
    if (!media) return @"mp3";

    NSString* extension = [[media.fileURL path] pathExtension];

    if (extension.length == 0) {
        NSString* urlString = [media.fileURL absoluteString];
        NSRange lastDotRange = [urlString rangeOfString:@"." options:NSBackwardsSearch];
        if (lastDotRange.location != NSNotFound && lastDotRange.location < [urlString length]-1) {
            extension = [urlString substringFromIndex:lastDotRange.location+1];
        }
    }

    NSString* constructedExtension = [CacheManager fileExtensionForMIMEType:media.mimeType];
    NSSet* knownExtensions = [NSSet setWithObjects:@"mp3", @"m4a", @"aac", @"ogg", @"wav", @"flac", @"m4v", @"mp4", @"mov", nil];
    if (![knownExtensions containsObject:[extension lowercaseString]] && constructedExtension) {
        extension = constructedExtension;
    }

    return extension ?: @"mp3";
}

- (NSURL*) URLForCachedEpisode:(CDEpisode*)episode
{
	NSString* identifier = episode.objectHash;
	if (identifier.length == 0 || _cacheDeletionTokensByIdentifier[identifier] || _cacheImportTokensByIdentifier[identifier]) {
		return nil;
	}

	NSURL* cachedURL = [_cachedURLIndex objectForKey:identifier];
	if (cachedURL) {
		return cachedURL;
	}

    NSString* extension = ICSanitizeFilenameExtension([self _extensionForEpisode:episode]);
    NSString* storagePath = [CacheManager _pathToStorageLocation];

    // Check for new-style filename: PodcastName - EpisodeName - UUID.ext
    NSString* podcastName = ICSanitizeFilenameComponent(episode.feed.title);
    NSString* episodeName = ICSanitizeFilenameComponent(episode.title);
    NSString* newFilename = [NSString stringWithFormat:@"%@ - %@ - %@.%@", podcastName, episodeName, episode.objectHash, extension];
    NSString* newPath = [storagePath stringByAppendingPathComponent:newFilename];

    if ([[NSFileManager defaultManager] fileExistsAtPath:newPath]) {
        NSURL* URL = [NSURL fileURLWithPath:newPath];
        [_cachedURLIndex setObject:URL forKey:episode.objectHash];
        return URL;
    }

    // Fallback: check old-style filename (hash.ext)
    NSString* oldFilename = [NSString stringWithFormat:@"%@.%@", episode.objectHash, extension];
    NSString* oldPath = [storagePath stringByAppendingPathComponent:oldFilename];

    if ([[NSFileManager defaultManager] fileExistsAtPath:oldPath]) {
        // Migrate: rename old file to new name
        NSError* error;
        if ([[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error]) {
            NSURL* URL = [NSURL fileURLWithPath:newPath];
            [_cachedURLIndex setObject:URL forKey:episode.objectHash];
            return URL;
        } else {
            // If rename fails (e.g. name collision), keep old name
            NSURL* URL = [NSURL fileURLWithPath:oldPath];
            [_cachedURLIndex setObject:URL forKey:episode.objectHash];
            return URL;
        }
    }

    // Return new-style path (for new downloads this is where the file will be created)
    NSURL* URL = [NSURL fileURLWithPath:newPath];
    return URL;
}

- (NSURL*) tempURLForCachedEpisode:(CDEpisode*)episode
{
    NSURL* cacheURL = [self URLForCachedEpisode:episode];
    if (!cacheURL) return nil;
    NSString* filename = [[cacheURL lastPathComponent] stringByAppendingString:@".part"];
    NSString* path = [[CacheManager _pathToCache] stringByAppendingPathComponent:filename];
	return [NSURL fileURLWithPath:path];
}

- (NSURL*)streamingTempURLForCachedEpisode:(CDEpisode*)episode leaseToken:(NSString*)leaseToken
{
    NSURL* cacheURL = [self URLForCachedEpisode:episode];
    if (!cacheURL || leaseToken.length == 0) return nil;
    NSString* streamingRoot = [[CacheManager _pathToCache] stringByAppendingPathComponent:@"Streaming"];
    NSString* leaseDirectory = [streamingRoot stringByAppendingPathComponent:leaseToken];
    NSString* extension = cacheURL.pathExtension;
    NSString* baseName = [cacheURL.lastPathComponent stringByDeletingPathExtension];
    NSString* filename = [NSString stringWithFormat:@"%@.part.%@", baseName, extension];
    return [NSURL fileURLWithPath:[leaseDirectory stringByAppendingPathComponent:filename]];
}

- (BOOL) episodeIsCached:(CDEpisode*)episode
{
	NSURL* url = [self URLForCachedEpisode:episode];
	if (!url) {
		return NO;
	}
	
	NSFileManager* fman = [NSFileManager defaultManager];
	return [fman fileExistsAtPath:[url path]];
}

- (BOOL) episodeIsCached:(CDEpisode*)episode fastLookup:(BOOL)fastLookup
{
	if (!fastLookup) {
		return [self episodeIsCached:episode];
	}
	
    if (!episode) {
        return NO;
    }
    NSString* targetHash = episode.objectHash;
    if ([targetHash length] == 0) {
        return NO;
    }
    if (_cacheDeletionTokensByIdentifier[targetHash] || _cacheImportTokensByIdentifier[targetHash]) {
        return NO;
    }
    if ([_cachedEpisodes containsObject:episode]) {
        return YES;
    }
    for (CDEpisode* cachedEpisode in [_cachedEpisodes copy]) {
        if ([cachedEpisode.objectHash isEqualToString:targetHash]) {
            return YES;
        }
    }

	return NO;
}

- (NSError*)_downloadStartError:(NSString*)description
{
    return [NSError errorWithDomain:@"ICCacheOperationErrorDomain"
                               code:12
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"The episode download could not be started.".ls}];
}

- (void)_handleDownloadStartError:(NSError*)error
                        forEpisode:(CDEpisode*)episode
                         automatic:(BOOL)automatic
            overwriteCellularLock:(BOOL)overwriteCellularLock
              reportsFailureToUser:(BOOL)reportsFailureToUser
            preservesConsumedState:(BOOL)preservesConsumedState
{
    [self _recordDownloadError:error
                    forEpisode:episode
                     automatic:automatic
        overwriteCellularLock:overwriteCellularLock
          reportsFailureToUser:reportsFailureToUser
        preservesConsumedState:preservesConsumedState
                    completion:nil];
    if (_downloadOperationsByIdentifier.count > 0) {
        _currentQueueHadFailure = YES;
    }
#if TARGET_OS_IPHONE
    if (reportsFailureToUser && App.applicationState == UIApplicationStateActive) {
        NSString* episodeTitle = [episode cleanTitleUsingFeedTitle:episode.feed.title] ?: episode.title ?: @"";
        NSString* message = episodeTitle.length > 0
            ? [NSString stringWithFormat:@"%@\n%@", episodeTitle, error.localizedDescription]
            : error.localizedDescription;
        [App showBackgroundErrorWithTitle:@"Download Failed".ls message:message duration:8.0];
    }
#endif
    if (episode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidFailCachingEpisodeNotification
                                                                object:self
                                                              userInfo:@{
                                                                  @"episode": episode,
                                                                  @"error": error,
                                                                  @"automatic": @(automatic),
                                                                  @"reportsFailureToUser": @(reportsFailureToUser),
                                                              }];
        });
    }
}

- (BOOL)_subscriptionCleanupBlocksEpisode:(CDEpisode*)episode
{
    NSAssert([NSThread isMainThread], @"Download queue ownership must stay on the main thread");
    return [[SubscriptionManager sharedSubscriptionManager]
        downloadsBlockedDuringUnsubscribeCleanupForFeed:episode.feed];
}

- (BOOL)_deferDownloadUntilSubscriptionCleanupFinishes:(CDEpisode*)episode
                                               autoCache:(BOOL)autoCache
                                 overwriteCellularLock:(BOOL)overwriteCellularLock
                                    reportsFailureToUser:(BOOL)reportsFailureToUser
                                  preservesConsumedState:(BOOL)preservesConsumedState
                                                queueRank:(NSNumber*)queueRank
{
    NSAssert([NSThread isMainThread], @"Deferred download ownership must stay on the main thread");
    NSString* identifier = episode.objectHash;
    if (identifier.length == 0 || ![episode preferedMedium].fileURL) return NO;

    NSDictionary* existingInfo = _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier];
    BOOL effectiveAutomatic = existingInfo
        ? [existingInfo[@"automatic"] boolValue] && autoCache : autoCache;
    BOOL effectiveCellular = [existingInfo[@"cellular"] boolValue] || overwriteCellularLock;
    BOOL effectiveReportsFailure = [existingInfo[@"reportsFailureToUser"] boolValue]
        || reportsFailureToUser;
    BOOL existingPreservesConsumedState = [existingInfo[@"automatic"] boolValue]
        || [existingInfo[@"preservesConsumedState"] boolValue];
    BOOL requestedPreservesConsumedState = autoCache || preservesConsumedState;
    BOOL effectivePreservesConsumed = existingInfo
        ? existingPreservesConsumedState && requestedPreservesConsumedState
        : requestedPreservesConsumedState;
    BOOL effectiveSuspended = existingInfo
        ? [existingInfo[@"suspended"] boolValue]
        : [_manuallySuspendedDownloadIdentifiers containsObject:identifier];
    NSNumber* effectiveRank = existingInfo[@"queueRank"] ?: queueRank;
    if (![effectiveRank isKindOfClass:[NSNumber class]]) {
        effectiveRank = @(_nextDownloadQueueRank + ICCachingEpisodeRankStep);
    }
    _nextDownloadQueueRank = MAX(_nextDownloadQueueRank, effectiveRank.longLongValue);

    NSDictionary* info = @{
        @"identifier": identifier,
        @"automatic": @(effectiveAutomatic),
        @"cellular": @(effectiveCellular),
        @"reportsFailureToUser": @(effectiveReportsFailure),
        @"preservesConsumedState": @(effectivePreservesConsumed),
        @"suspended": @(effectiveSuspended),
        @"queueRank": effectiveRank,
    };
    BOOL newOwner = existingInfo == nil;
    BOOL wasCaching = [self isCaching];
    if (newOwner && !_flags.restoringCachingEpisodes) {
        [self willChangeValueForKey:@"cachingEpisodes"];
    }
    _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier] = info;
    _subscriptionCleanupDeferredDownloadEpisodesByIdentifier[identifier] = episode;
    if (newOwner) {
        _subscriptionCleanupPromotionRequested = YES;
    }
    NSString* key = [ICSubscriptionCleanupDeferredDownloadJobKeyPrefix
        stringByAppendingString:identifier];
    [USER_DEFAULTS setObject:info forKey:key];
    if (newOwner && !_flags.restoringCachingEpisodes) {
        [self didChangeValueForKey:@"cachingEpisodes"];
        BOOL alreadyVisible = _downloadOperationsByIdentifier[identifier]
            || _streamingCacheLeaseTokensByIdentifier[identifier];
        if (!alreadyVisible) {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:wasCaching
                    ? CacheManagerDidAddEpisodeToCachingQueueNotification
                    : CacheManagerDidStartCachingNotification
                              object:self];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:CacheManagerDidStartCachingEpisodeNotification
                              object:self
                            userInfo:@{ @"episode": episode }];
        }
        [self _postDidUpdateNotification];
    }
    return YES;
}

- (void)_removeDownloadDeferredBySubscriptionCleanupForIdentifier:(NSString*)identifier
                                              removeNormalDescriptor:(BOOL)removeNormalDescriptor
{
    if (identifier.length == 0) return;
    NSString* key = [ICSubscriptionCleanupDeferredDownloadJobKeyPrefix
        stringByAppendingString:identifier];
    BOOL hasInMemoryOwner =
        _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier] != nil;
    id persistedInfo = [USER_DEFAULTS objectForKey:key];
    if (!hasInMemoryOwner && !persistedInfo) return;
    if (!hasInMemoryOwner) {
        [USER_DEFAULTS removeObjectForKey:key];
        if (removeNormalDescriptor && !_downloadOperationsByIdentifier[identifier]) {
            [self _removeSavedCachingInfoForIdentifier:identifier];
            [_downloadQueueRanksByIdentifier removeObjectForKey:identifier];
            [_manuallySuspendedDownloadIdentifiers removeObject:identifier];
        }
        return;
    }
    BOOL wasCaching = [self isCaching];
    [self willChangeValueForKey:@"cachingEpisodes"];
    [_subscriptionCleanupDeferredDownloadInfosByIdentifier removeObjectForKey:identifier];
    [_subscriptionCleanupDeferredDownloadEpisodesByIdentifier removeObjectForKey:identifier];
    [USER_DEFAULTS removeObjectForKey:key];
    if (removeNormalDescriptor && !_downloadOperationsByIdentifier[identifier]) {
        [self _removeSavedCachingInfoForIdentifier:identifier];
        [_downloadQueueRanksByIdentifier removeObjectForKey:identifier];
        [_manuallySuspendedDownloadIdentifiers removeObject:identifier];
    }
    [self didChangeValueForKey:@"cachingEpisodes"];
    [self _postDidUpdateNotification];
    if (wasCaching && ![self isCaching]) {
        if (_totalOps > 0) {
            [self _finishDownloadBatchAfterOperation:nil];
        } else {
            [[NSNotificationCenter defaultCenter]
                postNotificationName:CacheManagerDidEndCachingNotification
                              object:self];
        }
    }
}

- (void)_promoteDownloadsDeferredBySubscriptionCleanup
{
    NSAssert([NSThread isMainThread], @"Deferred download promotion must stay on the main thread");
    if (!_subscriptionCleanupPromotionIdentifiers) {
        if (!_subscriptionCleanupPromotionRequested) return;
        _subscriptionCleanupPromotionRequested = NO;
        _subscriptionCleanupPromotionIdentifiers =
            [_subscriptionCleanupDeferredDownloadInfosByIdentifier.allKeys
                sortedArrayUsingComparator:^NSComparisonResult(NSString* left, NSString* right) {
                    NSNumber* leftRank = self->_subscriptionCleanupDeferredDownloadInfosByIdentifier[left][@"queueRank"];
                    NSNumber* rightRank = self->_subscriptionCleanupDeferredDownloadInfosByIdentifier[right][@"queueRank"];
                    NSComparisonResult rankOrder = [leftRank compare:rightRank];
                    return rankOrder == NSOrderedSame ? [left compare:right] : rankOrder;
                }];
        _subscriptionCleanupPromotionCursor = 0;
    }

    NSUInteger end = MIN(_subscriptionCleanupPromotionCursor + 32,
                         _subscriptionCleanupPromotionIdentifiers.count);
    for (; _subscriptionCleanupPromotionCursor < end;
         _subscriptionCleanupPromotionCursor += 1) {
        NSString* identifier = _subscriptionCleanupPromotionIdentifiers[
            _subscriptionCleanupPromotionCursor
        ];
        NSDictionary* info = _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier];
        CDEpisode* episode = _subscriptionCleanupDeferredDownloadEpisodesByIdentifier[identifier];
        if (!info || !episode || [self _subscriptionCleanupBlocksEpisode:episode]) continue;

        CDFeed* feed = episode.feed;
        BOOL automatic = [info[@"automatic"] boolValue];
        BOOL valid = !episode.isDeleted && feed && !feed.isDeleted
            && (feed.subscribed || feed.parked)
            && (!automatic || (feed.subscribed && !feed.parked))
            && [episode preferedMedium].fileURL;
        if (!valid) {
            [self cancelCachingEpisode:episode disableAutoDownload:NO];
            continue;
        }
        if (_cacheDeletionTokensByIdentifier[identifier]
            || _cacheImportTokensByIdentifier[identifier]
            || [_subscriptionCleanupBackgroundSessionCancellationIdentifiers
                containsObject:identifier]) {
            continue;
        }
        CACHE_OPERATION_CLASS* existingOperation =
            _downloadOperationsByIdentifier[identifier];
        if ((existingOperation && !existingOperation.cancelled)
            || _streamingCacheLeaseTokensByIdentifier[identifier]
            || [self episodeIsCached:episode]) {
            [self _removeDownloadDeferredBySubscriptionCleanupForIdentifier:identifier
                                                        removeNormalDescriptor:YES];
            continue;
        }
        if ([info[@"suspended"] boolValue]) {
            [_manuallySuspendedDownloadIdentifiers addObject:identifier];
        }

        BOOL accepted = [self _cacheEpisode:episode
                                  autoCache:automatic
                    overwriteCellularLock:[info[@"cellular"] boolValue]
                       reportsFailureToUser:[info[@"reportsFailureToUser"] boolValue]
                                   queueRank:info[@"queueRank"]
                     preservesConsumedState:[info[@"preservesConsumedState"] boolValue]
              deferDuringSubscriptionCleanup:YES];
        if (accepted && _downloadOperationsByIdentifier[identifier]) {
            [self _removeDownloadDeferredBySubscriptionCleanupForIdentifier:identifier
                                                        removeNormalDescriptor:NO];
        }
    }

    if (_subscriptionCleanupPromotionCursor < _subscriptionCleanupPromotionIdentifiers.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _promoteDownloadsDeferredBySubscriptionCleanup];
        });
    } else {
        _subscriptionCleanupPromotionIdentifiers = nil;
        _subscriptionCleanupPromotionCursor = 0;
        if (_subscriptionCleanupPromotionRequested) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _promoteDownloadsDeferredBySubscriptionCleanup];
            });
        }
    }
}

- (void)_resumeDownloadsAfterSubscriptionCleanupProtectionChange:(NSNotification*)notification
{
    (void)notification;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil];
        });
        return;
    }
    _subscriptionCleanupPromotionRequested = YES;
    if (_subscriptionCleanupResumeScheduled) return;
    _subscriptionCleanupResumeScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_subscriptionCleanupResumeScheduled = NO;

        for (CACHE_OPERATION_CLASS* operation in
             [self->_downloadOperationsByIdentifier.allValues copy]) {
            CDEpisode* episode = [operation.userInfo isKindOfClass:[CDEpisode class]]
                ? operation.userInfo : nil;
            BOOL manuallySuspended =
                [self->_manuallySuspendedDownloadIdentifiers containsObject:operation.identifier];
            operation.suspended = self.suspended || manuallySuspended
                || ![self _networkAllowsDownloadOperation:operation]
                || [self _subscriptionCleanupBlocksEpisode:episode];
        }

        NSUInteger waitingManualCount = 0;
        if (!self.suspended) {
            for (NSString* identifier in self->_subscriptionCleanupDeferredDownloadInfosByIdentifier) {
                NSDictionary* info = self->_subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier];
                CDEpisode* episode = self->_subscriptionCleanupDeferredDownloadEpisodesByIdentifier[identifier];
                if ([info[@"automatic"] boolValue] || [info[@"suspended"] boolValue]
                    || !episode || [self _subscriptionCleanupBlocksEpisode:episode]) continue;
                CDFeed* feed = episode.feed;
                BOOL valid = !episode.isDeleted && feed && !feed.isDeleted
                    && (feed.subscribed || feed.parked)
                    && [episode preferedMedium].fileURL;
                if (!valid
                    || self->_cacheDeletionTokensByIdentifier[identifier]
                    || self->_cacheImportTokensByIdentifier[identifier]
                    || [self->_subscriptionCleanupBackgroundSessionCancellationIdentifiers
                        containsObject:identifier]
                    || self->_downloadOperationsByIdentifier[identifier]
                    || self->_streamingCacheLeaseTokensByIdentifier[identifier]
                    || [self episodeIsCached:episode fastLookup:YES]) continue;
                waitingManualCount += 1;
                if (waitingManualCount >= 3) break;
            }
        }
        if (waitingManualCount > 0 && self->_scheduledDownloadOperationIdentifiers.count >= 3) {
            for (CACHE_OPERATION_CLASS* operation in [self->_downloadOperationsByIdentifier.allValues copy]) {
                if (waitingManualCount == 0) break;
                if (operation.automatic && !operation.cancelled && !operation.finished &&
                    ![self->_finalizingDownloadOperationIdentifiers containsObject:operation.identifier] &&
                    [self->_scheduledDownloadOperationIdentifiers containsObject:operation.identifier] &&
                    [self _requestDownloadOperationYield:operation]) {
                    waitingManualCount -= 1;
                }
            }
        }

        [self _promoteDownloadsDeferredBySubscriptionCleanup];
        [self _startNextDownloadOperations];
        [self retryFailedAutomaticDownloadsIfPossible];
        [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
    });
}

- (BOOL) _cacheEpisode:(CDEpisode*)episode autoCache:(BOOL)autoCache overwriteCellularLock:(BOOL)overwriteCellularLock
{
    return [self _cacheEpisode:episode
                    autoCache:autoCache
      overwriteCellularLock:overwriteCellularLock
         reportsFailureToUser:!autoCache];
}

- (BOOL) _cacheEpisode:(CDEpisode*)episode
             autoCache:(BOOL)autoCache
overwriteCellularLock:(BOOL)overwriteCellularLock
reportsFailureToUser:(BOOL)reportsFailureToUser
{
    return [self _cacheEpisode:episode
                     autoCache:autoCache
       overwriteCellularLock:overwriteCellularLock
          reportsFailureToUser:reportsFailureToUser
                      queueRank:nil];
}

- (BOOL) _cacheEpisode:(CDEpisode*)episode
             autoCache:(BOOL)autoCache
overwriteCellularLock:(BOOL)overwriteCellularLock
reportsFailureToUser:(BOOL)reportsFailureToUser
             queueRank:(NSNumber*)queueRank
{
    return [self _cacheEpisode:episode
                     autoCache:autoCache
       overwriteCellularLock:overwriteCellularLock
          reportsFailureToUser:reportsFailureToUser
                      queueRank:queueRank
        preservesConsumedState:NO
 deferDuringSubscriptionCleanup:YES];
}

- (BOOL) _cacheEpisode:(CDEpisode*)episode
             autoCache:(BOOL)autoCache
overwriteCellularLock:(BOOL)overwriteCellularLock
reportsFailureToUser:(BOOL)reportsFailureToUser
             queueRank:(NSNumber*)queueRank
preservesConsumedState:(BOOL)preservesConsumedState
deferDuringSubscriptionCleanup:(BOOL)deferDuringSubscriptionCleanup
{
	if (!episode) {
		return NO;
	}
    if (_clearingAllCache) {
        return NO;
    }

	NSString* identifier = episode.objectHash;
	if (identifier.length == 0) {
		NSError* error = [self _downloadStartError:@"The episode cannot be downloaded because its local identifier is missing.".ls];
		[self _handleDownloadStartError:error forEpisode:episode automatic:autoCache overwriteCellularLock:overwriteCellularLock reportsFailureToUser:reportsFailureToUser preservesConsumedState:preservesConsumedState];
		return NO;
	}
    CDFeed* feed = episode.feed;
    if (autoCache && (!feed || feed.isDeleted || !feed.subscribed || feed.parked)) {
        return NO;
    }
    BOOL subscriptionCleanupBlocked = [self _subscriptionCleanupBlocksEpisode:episode];
    if (subscriptionCleanupBlocked && deferDuringSubscriptionCleanup) {
        return [self _deferDownloadUntilSubscriptionCleanupFinishes:episode
                                                           autoCache:autoCache
                                             overwriteCellularLock:overwriteCellularLock
                                                reportsFailureToUser:reportsFailureToUser
                                              preservesConsumedState:preservesConsumedState
                                                            queueRank:queueRank];
    }
    if (_cacheDeletionTokensByIdentifier[identifier] || _cacheImportTokensByIdentifier[identifier]) {
        return NO;
    }
	// check if it is not already cached
	if ([self episodeIsCached:episode]) {
		return NO;
	}

    CACHE_OPERATION_CLASS* existingOperation = _downloadOperationsByIdentifier[identifier];
    if (existingOperation) {
        if (!existingOperation.cancelled) {
            [self clearDownloadErrorForEpisode:episode];
        }
        return !existingOperation.cancelled;
    }

	if ([self _hasStreamingCacheForEpisode:episode]) {
		[self clearDownloadErrorForEpisode:episode];
		return YES;
	}

	CDMedium* media = [episode preferedMedium];
	if (!media.fileURL) {
		NSError* error = [self _downloadStartError:@"This episode does not provide a downloadable media file.".ls];
		[self _handleDownloadStartError:error forEpisode:episode automatic:autoCache overwriteCellularLock:overwriteCellularLock reportsFailureToUser:reportsFailureToUser preservesConsumedState:preservesConsumedState];
		return NO;
	}

	NSURL* url = [self URLForCachedEpisode:episode];
	if (!url) {
		NSError* error = [self _downloadStartError:@"The download file location could not be created on this device.".ls];
		[self _handleDownloadStartError:error forEpisode:episode automatic:autoCache overwriteCellularLock:overwriteCellularLock reportsFailureToUser:reportsFailureToUser preservesConsumedState:preservesConsumedState];
		return NO;
	}

#if TARGET_OS_IPHONE
	CACHE_OPERATION_CLASS* cacheOperation = [[CACHE_OPERATION_CLASS alloc] initWithURL:media.fileURL
                                                                 localURL:[self URLForCachedEpisode:episode]
                                                                            identifier:episode.objectHash
                                                                 expectedContentLength:media.byteSize];
#else
    CACHE_OPERATION_CLASS* cacheOperation = [[CACHE_OPERATION_CLASS alloc] initWithURL:media.fileURL
                                                                              localURL:[self URLForCachedEpisode:episode]
                                                                               tempURL:[self tempURLForCachedEpisode:episode]
                                                                            identifier:episode.objectHash];
#endif
	if (!cacheOperation) {
		NSError* error = [self _downloadStartError:@"The episode download could not be started.".ls];
		[self _handleDownloadStartError:error forEpisode:episode automatic:autoCache overwriteCellularLock:overwriteCellularLock reportsFailureToUser:reportsFailureToUser preservesConsumedState:preservesConsumedState];
		return NO;
	}
#if TARGET_OS_IPHONE
    cacheOperation.expectedDuration = MAX(0, episode.duration);
#endif
	cacheOperation.delegate = self;
	cacheOperation.userInfo = episode;
	cacheOperation.username = feed.username;
	cacheOperation.password = feed.password;
    cacheOperation.automatic = autoCache;
    cacheOperation.reportsFailureToUser = reportsFailureToUser;
    cacheOperation.overwriteCellularLock = overwriteCellularLock;
    cacheOperation.preservesConsumedState = preservesConsumedState;
    BOOL manuallySuspended = [_manuallySuspendedDownloadIdentifiers containsObject:episode.objectHash];
    cacheOperation.suspended = self.suspended || manuallySuspended
        || ![self _networkAllowsDownloadOperation:cacheOperation]
        || subscriptionCleanupBlocked;
    if ([cacheOperation respondsToSelector:@selector(setQualityOfService:)]) {
        cacheOperation.qualityOfService = autoCache ? NSOperationQualityOfServiceUtility : NSOperationQualityOfServiceUserInitiated;
	}
	[self clearDownloadErrorForEpisode:episode];
    long long rank = queueRank ? queueRank.longLongValue : (_nextDownloadQueueRank + ICCachingEpisodeRankStep);
    _nextDownloadQueueRank = MAX(_nextDownloadQueueRank, rank);
    _downloadOperationsByIdentifier[identifier] = cacheOperation;
    _downloadQueueRanksByIdentifier[identifier] = @(rank);
    [_cachingEpisodeHashes addObject:identifier];

    if (!_flags.restoringCachingEpisodes) {
        [self willChangeValueForKey:@"cachingEpisodes"];
    }
    [_cachingEpisodes addObject:episode];
    if (!_flags.restoringCachingEpisodes) {
        [self didChangeValueForKey:@"cachingEpisodes"];
        [self _persistCachingOperation:cacheOperation];
    }
	
	if (_totalOps == 0 && !_flags.restoringCachingEpisodes) {
		_currentQueueHadFailure = NO;
		[[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidStartCachingNotification object:self];
	} else if (!_flags.restoringCachingEpisodes) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidAddEpisodeToCachingQueueNotification object:self];
    }

	if (!_flags.restoringCachingEpisodes) {
        _flags.supressSendUpdate = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidStartCachingEpisodeNotification
                                                                object:self
                                                              userInfo:@{ @"episode" : episode }];
            self->_flags.supressSendUpdate = NO;
        });
    }

	_totalOps++;
	if (!_flags.restoringCachingEpisodes) {
        [self _startNextDownloadOperations];
        [self _ensureDownloadUpdateTimer];
    }
	
	return YES;
}

- (void) _startNextDownloadOperations
{
    if (_flags.restoringCachingEpisodes) {
        return;
    }

    while (_scheduledDownloadOperationIdentifiers.count < 3) {
        CACHE_OPERATION_CLASS* nextOperation = nil;
        CACHE_OPERATION_CLASS* nextAutomaticOperation = nil;
        for (CDEpisode* episode in [_cachingEpisodes copy]) {
            NSString* identifier = episode.objectHash;
            CACHE_OPERATION_CLASS* operation = identifier.length > 0 ? _downloadOperationsByIdentifier[identifier] : nil;
            if (operation && !operation.cancelled &&
                ![_subscriptionCleanupBackgroundSessionCancellationIdentifiers containsObject:identifier] &&
                ![_scheduledDownloadOperationIdentifiers containsObject:identifier] &&
                ![_finalizingDownloadOperationIdentifiers containsObject:identifier] &&
                !operation.finished &&
                !operation.suspended && ![self _subscriptionCleanupBlocksEpisode:episode]) {
                if (!operation.automatic) {
                    nextOperation = operation;
                    break;
                }
                nextAutomaticOperation = nextAutomaticOperation ?: operation;
            }
        }
        nextOperation = nextOperation ?: nextAutomaticOperation;
        if (!nextOperation) {
            break;
        }
        [_scheduledDownloadOperationIdentifiers addObject:nextOperation.identifier];
        [_downloadQueue addOperation:nextOperation];
    }
    [self _ensureDownloadUpdateTimer];
}

- (BOOL)_requestDownloadOperationYield:(CACHE_OPERATION_CLASS*)operation
{
#if TARGET_OS_IPHONE
    NSString* identifier = operation.identifier;
    if (identifier.length == 0 || _downloadOperationsByIdentifier[identifier] != operation ||
        ![_scheduledDownloadOperationIdentifiers containsObject:identifier] ||
        operation.cancelled || operation.finished ||
        [_finalizingDownloadOperationIdentifiers containsObject:identifier] ||
        _downloadPauseYieldTokensByIdentifier[identifier]) {
        return NO;
    }
    _downloadPauseYieldTokensByIdentifier[identifier] = NSUUID.UUID.UUIDString;
    [operation cancel];
    if (![operation isExecuting]) {
        [self _replaceYieldedDownloadOperation:operation];
    }
    return YES;
#else
    (void)operation;
    return NO;
#endif
}

- (BOOL)_replaceYieldedDownloadOperation:(CACHE_OPERATION_CLASS*)operation
{
#if TARGET_OS_IPHONE
    NSString* identifier = operation.identifier;
    if (identifier.length == 0 || !_downloadPauseYieldTokensByIdentifier[identifier] ||
        _downloadOperationsByIdentifier[identifier] != operation) {
        return NO;
    }

    CACHE_OPERATION_CLASS* replacement = [[CACHE_OPERATION_CLASS alloc] initWithURL:operation.remoteURL
                                                                            localURL:operation.localURL
                                                                          identifier:identifier
                                                               expectedContentLength:operation.expectedContentLength];
    if (!replacement) {
        [_downloadPauseYieldTokensByIdentifier removeObjectForKey:identifier];
        return NO;
    }
    replacement.expectedDuration = operation.expectedDuration;
    replacement.delegate = self;
    replacement.userInfo = operation.userInfo;
    replacement.username = operation.username;
    replacement.password = operation.password;
    replacement.automatic = operation.automatic;
    replacement.reportsFailureToUser = operation.reportsFailureToUser;
    replacement.overwriteCellularLock = operation.overwriteCellularLock;
    replacement.preservesConsumedState = operation.preservesConsumedState;
    replacement.qualityOfService = operation.qualityOfService;
    replacement.suspended = self.suspended ||
        [_manuallySuspendedDownloadIdentifiers containsObject:identifier] ||
        ![self _networkAllowsDownloadOperation:replacement] ||
        [self _subscriptionCleanupBlocksEpisode:
            [replacement.userInfo isKindOfClass:[CDEpisode class]] ? replacement.userInfo : nil];

    [_scheduledDownloadOperationIdentifiers removeObject:identifier];
    _downloadOperationsByIdentifier[identifier] = replacement;
    [_downloadPauseYieldTokensByIdentifier removeObjectForKey:identifier];
    [self _persistCachingOperation:replacement];
    [self _startNextDownloadOperations];
    [self coalescedPerformSelector:@selector(_postDidUpdateNotification) afterDelay:0.1];
    return YES;
#else
    (void)operation;
    return NO;
#endif
}

- (void) _ensureDownloadUpdateTimer
{
    if (_updateTimer || _downloadOperationsByIdentifier.count == 0 ||
        _scheduledDownloadOperationIdentifiers.count == 0) {
        return;
    }

    void (^startUpdateTimer)(void) = ^{
        if (self->_updateTimer || self->_downloadOperationsByIdentifier.count == 0) {
            return;
        }
        self->_updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5f target:self selector:@selector(_postDidUpdateNotification) userInfo:nil repeats:YES];

#if TARGET_OS_IPHONE

#else
        IOReturn success = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,
                                                       kIOPMAssertionLevelOn,
                                                       CFSTR("Currently downloading"),
                                                       &self->_noSystemSleepAssertionID);
        if (success != kIOReturnSuccess) {
            self->_noSystemSleepAssertionID = 0;
        }
#endif
    };

    if ([NSThread isMainThread]) {
        startUpdateTimer();
    } else {
        dispatch_async(dispatch_get_main_queue(), startUpdateTimer);
    }
}

- (BOOL) cacheEpisode:(CDEpisode*)episode
{
	return [self _cacheEpisode:episode autoCache:NO overwriteCellularLock:NO];
}

- (BOOL) cacheEpisode:(CDEpisode*)episode overwriteCellularLock:(BOOL)overwriteCellularLock
{
    return [self _cacheEpisode:episode autoCache:NO overwriteCellularLock:overwriteCellularLock];
}

- (BOOL) cacheEpisode:(CDEpisode*)episode overwriteCellularLock:(BOOL)overwriteCellularLock reportsFailureToUser:(BOOL)reportsFailureToUser
{
    return [self _cacheEpisode:episode
                    autoCache:NO
      overwriteCellularLock:overwriteCellularLock
         reportsFailureToUser:reportsFailureToUser];
}

- (BOOL) autoCacheEpisode:(CDEpisode*)episode enableFilters:(BOOL)filters
{
    // check if it is not already cached
	if ([self episodeIsCached:episode]) {
		return NO;
	}

    if ([self automaticCachingDisabledForEpisode:episode]) {
        return NO;
    }

    if (filters)
    {
        CDFeed* feed = episode.feed;
        BOOL autoCacheAudio = [feed boolForKey:AutoCacheNewAudioEpisodes];
        BOOL autoCacheVideo = [feed boolForKey:AutoCacheNewVideoEpisodes];

        if (!episode.video && !autoCacheAudio) {
            [self retryFailedAutomaticDownloadsIfPossible];
            return NO;
        }
        else if (episode.video && !autoCacheVideo) {
            [self retryFailedAutomaticDownloadsIfPossible];
            return NO;
        }
    }
	
	return [self _cacheEpisode:episode autoCache:YES overwriteCellularLock:NO];
}

- (BOOL) autoCacheFeed:(CDFeed*)feed
{
	for(CDEpisode* episode in feed.sortedEpisodes)
    {
		if (!episode.consumed) {
			[self autoCacheEpisode:episode enableFilters:YES];
		}
	}
	return YES;
}

- (BOOL) automaticCachingDisabledForEpisode:(CDEpisode*)episode
{
    return [self.cacheHistory episodeDidAutoDownload:episode];
}

- (void) resetAutoCacheForFeed:(CDFeed*)feed
{
    if (!feed) return;
    [self resetAutoCacheForFeeds:@[feed] completion:^(NSError* error) {
        if (error) ErrLog(@"could not reset feed auto-download history: %@", error);
    }];
}

- (void)resetAutoCacheForFeeds:(NSArray<CDFeed*>*)feeds
                     completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resetAutoCacheForFeeds:feeds completion:completion];
        });
        return;
    }

    feeds = [NSOrderedSet orderedSetWithArray:feeds ?: @[]].array;
    if (feeds.count == 0) {
        if (completion) completion(nil);
        return;
    }

    [self.cacheHistory reloadIfNeededWithCompletion:^(NSError* historyError) {
        if (historyError) {
            if (completion) completion(historyError);
            return;
        }

        NSMutableArray<NSURL*>* feedObjectURIs = [NSMutableArray arrayWithCapacity:feeds.count];
        for (CDFeed* feed in feeds) {
            if (feed.objectID && !feed.objectID.isTemporaryID) {
                [feedObjectURIs addObject:feed.objectID.URIRepresentation];
            }
        }
        NSError* databaseUnavailableError = [NSError errorWithDomain:@"CacheManager"
                                                                 code:51
                                                             userInfo:@{NSLocalizedDescriptionKey: @"Podcast download data could not be accessed for cleanup. Please restart InstacastPlus and try again.".ls}];
        NSArray<NSURL*>* immutableFeedObjectURIs = [feedObjectURIs copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSManagedObjectContext* selectionContext = [DMANAGER newICloudSyncBackgroundContext];
            if (!selectionContext) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(databaseUnavailableError);
                });
                return;
            }
            [selectionContext performBlock:^{
            NSError* selectionError = nil;
            NSPersistentStoreCoordinator* selectionCoordinator = selectionContext.persistentStoreCoordinator;
            NSMutableArray<CDFeed*>* backgroundFeeds = [NSMutableArray arrayWithCapacity:immutableFeedObjectURIs.count];
            for (NSURL* feedObjectURI in immutableFeedObjectURIs) {
                NSManagedObjectID* feedObjectID = [selectionCoordinator managedObjectIDForURIRepresentation:feedObjectURI];
                if (!feedObjectID) {
                    selectionError = databaseUnavailableError;
                    break;
                }
                CDFeed* feed = (CDFeed*)[selectionContext existingObjectWithID:feedObjectID error:&selectionError];
                if (!feed || selectionError) break;
                [backgroundFeeds addObject:feed];
            }

            NSMutableSet<NSString*>* episodeHashes = [NSMutableSet set];
            if (!selectionError && backgroundFeeds.count > 0) {
                NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                request.predicate = [NSPredicate predicateWithFormat:@"feed IN %@ AND objectHash != nil", backgroundFeeds];
                request.resultType = NSDictionaryResultType;
                request.propertiesToFetch = @[@"objectHash"];
                request.returnsDistinctResults = YES;
                request.fetchBatchSize = 400;
                NSArray<NSDictionary*>* rows = [selectionContext executeFetchRequest:request error:&selectionError];
                for (NSDictionary* row in rows) {
                    NSString* episodeHash = row[@"objectHash"];
                    if (episodeHash.length > 0) [episodeHashes addObject:episodeHash];
                }
            }

            NSSet<NSString*>* immutableEpisodeHashes = [episodeHashes copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (selectionError) {
                    if (completion) completion(selectionError);
                    return;
                }
                [self.cacheHistory resetValuesForEpisodeHashes:immutableEpisodeHashes completion:completion];
            });
            }];
        });
    }];
}

- (void) removeCacheForEpisode:(CDEpisode*)episode automatic:(BOOL)automatic
{
    [self removeCacheForEpisode:episode automatic:automatic completion:nil];
}

- (void) removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes automatic:(BOOL)automatic
{
    [self removeCacheForEpisodes:episodes automatic:automatic completion:nil];
}

- (void) removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes
                       automatic:(BOOL)automatic
                      completion:(void (^)(NSError* error))completion
{
    [self _removeCacheRequestsForEpisodes:episodes
                                automatic:automatic
                      physicalURLSnapshot:nil
                               completion:completion];
}

- (void)_removeCacheRequestsForEpisodes:(NSArray<CDEpisode*>*)episodes
                               automatic:(BOOL)automatic
                     physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot
                              completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _removeCacheRequestsForEpisodes:episodes
                                        automatic:automatic
                              physicalURLSnapshot:physicalURLSnapshot
                                       completion:completion];
        });
        return;
    }

    NSMutableArray<CDEpisode*>* settledEpisodes = [NSMutableArray array];
    NSMutableArray<CDEpisode*>* activeEpisodes = [NSMutableArray array];
    NSMutableSet<NSString*>* seenIdentifiers = [NSMutableSet set];
    for (CDEpisode* episode in episodes) {
        if (![episode isKindOfClass:[CDEpisode class]]) continue;
        NSString* identifier = episode.objectHash;
        if (identifier.length == 0 ||
            [seenIdentifiers containsObject:identifier] ||
            (automatic && episode.starred)) {
            continue;
        }
        [seenIdentifiers addObject:identifier];
        BOOL needsDeferredRestoreCommit = [InstacastBackupImporter ownsDeferredDownloadWithObjectHash:identifier];
        if ([self isCachingEpisode:episode] ||
            _cancelledDownloadRemovalRequestsByIdentifier[identifier] ||
            needsDeferredRestoreCommit) {
            [activeEpisodes addObject:episode];
        } else {
            [settledEpisodes addObject:episode];
        }
    }

    NSUInteger operationCount = activeEpisodes.count + (settledEpisodes.count > 0 ? 1 : 0);
    if (operationCount == 0) {
        if (completion) completion(nil);
        return;
    }

    __block NSUInteger remainingOperations = operationCount;
    __block NSError* firstError = nil;
    void (^operationCompletion)(NSError*) = completion ? ^(NSError* error) {
        if (!firstError && error) firstError = error;
        remainingOperations -= 1;
        if (remainingOperations == 0) completion(firstError);
    } : nil;

    if (settledEpisodes.count > 0) {
        [self _removeCacheForEpisodes:settledEpisodes
                            automatic:automatic
                  physicalURLSnapshot:physicalURLSnapshot
                           completion:operationCompletion];
    }
    for (CDEpisode* episode in activeEpisodes) {
        [self _beginRemovalAfterCancellingEpisode:episode
                                         automatic:automatic
                               physicalURLSnapshot:physicalURLSnapshot
                                        completion:operationCompletion];
    }
}

- (void) removeCacheForEpisode:(CDEpisode*)episode
                      automatic:(BOOL)automatic
                     completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self removeCacheForEpisode:episode automatic:automatic completion:completion];
        });
        return;
    }
    if (!episode) {
        if (completion) {
            completion([NSError errorWithDomain:@"CacheManager"
                                            code:30
                                        userInfo:@{NSLocalizedDescriptionKey: @"The downloaded file could not be removed because the episode is no longer available.".ls}]);
        }
        return;
    }
    if (automatic && episode.starred) {
        if (completion) {
            completion([NSError errorWithDomain:@"CacheManager"
                                            code:31
                                        userInfo:@{NSLocalizedDescriptionKey: @"Favorite episodes are not removed automatically.".ls}]);
        }
        return;
    }

	if ([self isCachingEpisode:episode] ||
        _cancelledDownloadRemovalRequestsByIdentifier[episode.objectHash] ||
        [InstacastBackupImporter ownsDeferredDownloadWithObjectHash:episode.objectHash]) {
		[self _beginRemovalAfterCancellingEpisode:episode
                                         automatic:automatic
                               physicalURLSnapshot:nil
                                        completion:completion];
		return;
	}

    [self _removeCacheForEpisodes:@[episode] automatic:automatic completion:completion];
}

- (void)_beginRemovalAfterCancellingEpisode:(CDEpisode*)episode
                                  automatic:(BOOL)automatic
                        physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot
                                  completion:(void (^)(NSError* error))completion
{
    NSString* identifier = episode.objectHash;
    NSDictionary* existingRequest = _cancelledDownloadRemovalRequestsByIdentifier[identifier];
    if (existingRequest) {
        id existingPhysicalURLSnapshot = existingRequest[@"physicalURLSnapshot"];
        if (physicalURLSnapshot && (!existingPhysicalURLSnapshot || existingPhysicalURLSnapshot == NSNull.null)) {
            NSMutableDictionary* updatedRequest = [existingRequest mutableCopy];
            updatedRequest[@"physicalURLSnapshot"] = physicalURLSnapshot;
            _cancelledDownloadRemovalRequestsByIdentifier[identifier] = [updatedRequest copy];
        }
        if (completion) {
            NSMutableArray* completions = _cacheDeletionCompletionsByIdentifier[identifier] ?: [NSMutableArray array];
            [completions addObject:[completion copy]];
            _cacheDeletionCompletionsByIdentifier[identifier] = completions;
        }
        return;
    }

    CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
    NSURL* localURL = operation.localURL ?: _cachedURLIndex[identifier];
    NSString* token = NSUUID.UUID.UUIDString;
    ICCacheDeletionPreparation* deletionPreparation = [[ICCacheDeletionPreparation alloc] init];
    BOOL wasCached = [_cachedEpisodes containsObject:episode];
    _cacheDeletionTokensByIdentifier[identifier] = token;
    _cancelledDownloadRemovalRequestsByIdentifier[identifier] = @{
        @"token": token,
        @"automatic": @(automatic),
        @"url": localURL ?: (id)NSNull.null,
        @"objectID": episode.objectID,
        @"lastDownloaded": episode.lastDownloaded ?: (id)NSNull.null,
        @"downloaded": @(episode.downloaded),
        @"wasCached": @(wasCached),
        @"cacheDeletionPreparation": deletionPreparation,
        @"physicalURLSnapshot": physicalURLSnapshot ?: (id)NSNull.null,
    };
    if (completion) {
        _cacheDeletionCompletionsByIdentifier[identifier] = [NSMutableArray arrayWithObject:[completion copy]];
    }
    [_cachedURLIndex removeObjectForKey:identifier];
    if (_cacheIndexScanInFlight) [_cacheDeletionHashesDuringIndexScan addObject:identifier];

    NSMutableDictionary* userInfo = [@{
        @"episodeHashes": @[identifier],
        @"automatic": @(automatic),
        @"episode": episode,
        @"cacheDeletionPreparation": deletionPreparation,
    } mutableCopy];
    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerWillDeleteCacheFilesNotification
                                                        object:self
                                                      userInfo:userInfo];
    if (!_flags.supressDidClear) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidClearCacheNotification
                                                            object:self
                                                          userInfo:userInfo];
    }

    dispatch_async(_cacheDeletionQueue, ^{
        NSError* preparationError = [deletionPreparation waitForPreparation];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSDictionary* currentRequest = self->_cancelledDownloadRemovalRequestsByIdentifier[identifier];
            if (![currentRequest[@"token"] isEqualToString:token]) return;
            if (preparationError) {
                [self->_cancelledDownloadRemovalRequestsByIdentifier removeObjectForKey:identifier];
                [self->_cacheDeletionTokensByIdentifier removeObjectForKey:identifier];
                [self->_cacheDeletionHashesDuringIndexScan removeObject:identifier];
                if (localURL) self->_cachedURLIndex[identifier] = localURL;
                NSError* publicError = ICCacheDeletionDurabilityError(preparationError);
                [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidUpdateNotification object:self];
                [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidRestoreCacheNotification
                                                                    object:self
                                                                  userInfo:@{ @"episodeHashes": @[identifier] }];
                [self _presentCacheDeletionError:publicError automatic:automatic];
                [self _completeCacheDeletionForIdentifier:identifier error:publicError];
                return;
            }

            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerWillCommitCacheFileDeletionNotification
                                                                object:self
                                                              userInfo:@{
                                                                  @"episodeHashes": @[identifier],
                                                                  @"automatic": @(automatic),
                                                                  @"episode": episode,
                                                              }];
            NSMutableDictionary* committedRequest = [currentRequest mutableCopy];
            committedRequest[@"commitNotificationPosted"] = @YES;
            self->_cancelledDownloadRemovalRequestsByIdentifier[identifier] = [committedRequest copy];
            [self _cancelCachingEpisode:episode
                    disableAutoDownload:automatic
                             completion:^(BOOL waitsForOperationEnd, NSError *cancelError) {
                NSDictionary *latestRequest = self->_cancelledDownloadRemovalRequestsByIdentifier[identifier];
                if (![latestRequest[@"token"] isEqualToString:token]) return;
                if (cancelError) {
                    [self->_cancelledDownloadRemovalRequestsByIdentifier removeObjectForKey:identifier];
                    [self->_cacheDeletionTokensByIdentifier removeObjectForKey:identifier];
                    [self->_cacheDeletionHashesDuringIndexScan removeObject:identifier];
                    if (localURL) self->_cachedURLIndex[identifier] = localURL;
                    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidUpdateNotification object:self];
                    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidRestoreCacheNotification
                                                                        object:self
                                                                      userInfo:@{ @"episodeHashes": @[identifier] }];
                    [self _completeCacheDeletionForIdentifier:identifier error:cancelError];
                    return;
                }
                if (!waitsForOperationEnd) {
                    [self _finishCancelledDownloadRemovalForIdentifier:identifier];
                }
            }];
        });
    });
}

- (void)_finishCancelledDownloadRemovalForIdentifier:(NSString*)identifier
{
    NSAssert([NSThread isMainThread], @"Cancelled download removal must finish on the main thread");
    NSDictionary* request = _cancelledDownloadRemovalRequestsByIdentifier[identifier];
    if (!request) return;
    [_cancelledDownloadRemovalRequestsByIdentifier removeObjectForKey:identifier];
    NSString* token = request[@"token"];
    BOOL automatic = [request[@"automatic"] boolValue];
    NSURL* localURL = request[@"url"] == NSNull.null ? nil : request[@"url"];
    NSManagedObjectID* objectID = request[@"objectID"];
    ICCacheDeletionPreparation* deletionPreparation = request[@"cacheDeletionPreparation"];
    ICCachePhysicalURLSnapshot* physicalURLSnapshot = request[@"physicalURLSnapshot"] == NSNull.null
        ? nil
        : request[@"physicalURLSnapshot"];

    dispatch_async(_cacheDeletionQueue, ^{
        NSError* preparationError = [deletionPreparation waitForPreparation];
        if (!preparationError && ![request[@"commitNotificationPosted"] boolValue]) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerWillCommitCacheFileDeletionNotification
                                                                    object:self
                                                                  userInfo:@{
                                                                      @"episodeHashes": @[identifier],
                                                                      @"automatic": @(automatic),
                                                                  }];
            });
        }
        NSFileManager* fileManager = [[NSFileManager alloc] init];
        NSMutableOrderedSet<NSURL*>* physicalURLs = [NSMutableOrderedSet orderedSet];
        if (localURL) [physicalURLs addObject:localURL];
        if (physicalURLSnapshot) {
            [physicalURLs addObjectsFromArray:physicalURLSnapshot.URLsByEpisodeHash[identifier] ?: @[]];
        }

        BOOL wasAccounted = [request[@"terminalDownloadSucceeded"] boolValue] ||
            [request[@"wasCached"] boolValue] || [request[@"downloaded"] boolValue];
        BOOL fileWasPresent = NO;
        BOOL needsRecalculation = NO;
        unsigned long long removedBytes = 0;
        NSError* removalError = preparationError ? ICCacheDeletionDurabilityError(preparationError) : nil;
        if (!removalError && physicalURLSnapshot.error) removalError = physicalURLSnapshot.error;
        BOOL success = (removalError == nil);
        NSURL* remainingURL = success ? nil : physicalURLs.firstObject;
        if (success) {
            needsRecalculation = !wasAccounted;
            for (NSURL* physicalURL in physicalURLs) {
                NSError* attributesError = nil;
                NSDictionary* fileAttributes = [fileManager attributesOfItemAtPath:physicalURL.path error:&attributesError];
                if (!fileAttributes && ICCacheFileErrorMeansMissing(attributesError)) continue;
                if (!fileAttributes) {
                    needsRecalculation = YES;
                } else if ([fileAttributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                    success = NO;
                    remainingURL = remainingURL ?: physicalURL;
                    removalError = removalError ?: [NSError errorWithDomain:NSCocoaErrorDomain
                                                                        code:NSFileWriteInvalidFileNameError
                                                                    userInfo:@{NSLocalizedDescriptionKey: @"The episode cache path is not a regular file."}];
                    continue;
                } else {
                    fileWasPresent = YES;
                }

                NSError* mediaRemovalError = nil;
                BOOL removed = [fileManager removeItemAtURL:physicalURL error:&mediaRemovalError]
                    || ICCacheFileErrorMeansMissing(mediaRemovalError);
                if (removed) {
                    if (fileAttributes) removedBytes += [fileAttributes fileSize];
                } else {
                    success = NO;
                    remainingURL = remainingURL ?: physicalURL;
                    removalError = removalError ?: mediaRemovalError;
                }
            }
        }
        if (success && !fileWasPresent) needsRecalculation = YES;
        if (!success && removedBytes > 0) needsRecalculation = YES;
        if (success) {
            if (!physicalURLSnapshot) ICRemoveTranscriptCacheForEpisodeHashes([NSSet setWithObject:identifier]);
#if TARGET_OS_IPHONE
            [CACHE_OPERATION_CLASS deleteResumeInfoForIdentifier:identifier];
#endif
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self->_cacheDeletionTokensByIdentifier[identifier] isEqualToString:token]) return;
            [self->_cacheDeletionTokensByIdentifier removeObjectForKey:identifier];
            NSError* objectError = nil;
            CDEpisode* storedEpisode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:objectID error:&objectError];
            if (objectError || ![storedEpisode isKindOfClass:[CDEpisode class]] || storedEpisode.isDeleted) {
                storedEpisode = nil;
            }
            NSError* publicError = nil;
            if (success) {
                [self willChangeValueForKey:@"cachedEpisodes"];
                for (CDEpisode* cachedEpisode in [self->_cachedEpisodes copy]) {
                    if ([cachedEpisode.objectHash isEqualToString:identifier]) {
                        [self->_cachedEpisodes removeObject:cachedEpisode];
                    }
                }
                [self->_cachedURLIndex removeObjectForKey:identifier];
                if (storedEpisode) {
                    storedEpisode.downloaded = NO;
                    storedEpisode.lastDownloaded = nil;
                }
                [self didChangeValueForKey:@"cachedEpisodes"];
                NSError* saveError = storedEpisode ? [DMANAGER saveReturningError] : nil;
                if (saveError) {
                    publicError = saveError;
                    [self _presentCacheDeletionError:saveError automatic:automatic];
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidDeleteCacheFilesNotification
                                                                    object:self
                                                                  userInfo:@{ @"episodeHashes": @[identifier] }];
            } else {
                NSError* rollbackSaveError = nil;
                if (storedEpisode) {
                    BOOL terminalDownloadSucceeded = [request[@"terminalDownloadSucceeded"] boolValue];
                    BOOL restoreAsCached = terminalDownloadSucceeded || [request[@"wasCached"] boolValue] || remainingURL != nil;
                    [self willChangeValueForKey:@"cachedEpisodes"];
                    if (restoreAsCached) {
                        [self->_cachedEpisodes addObject:storedEpisode];
                    }
                    if (remainingURL) self->_cachedURLIndex[identifier] = remainingURL;
                    storedEpisode.downloaded = restoreAsCached || [request[@"downloaded"] boolValue];
                    storedEpisode.lastDownloaded = terminalDownloadSucceeded
                        ? request[@"terminalDownloadedAt"]
                        : (request[@"lastDownloaded"] == NSNull.null ? nil : request[@"lastDownloaded"]);
                    [self didChangeValueForKey:@"cachedEpisodes"];
                    rollbackSaveError = [DMANAGER saveReturningError];
                }
                [self->_cacheDeletionHashesDuringIndexScan removeObject:identifier];
                NSError* removalPublicError = [removalError.domain isEqualToString:@"CacheManager"] && removalError.code == 36
                    ? removalError
                    : [NSError errorWithDomain:@"CacheManager"
                                          code:41
                                      userInfo:@{
                                          NSLocalizedDescriptionKey: @"The downloaded file could not be deleted. Restart the app and try again.".ls,
                                          NSUnderlyingErrorKey: removalError ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil],
                                      }];
                [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidUpdateNotification object:self];
                if (rollbackSaveError) {
                    publicError = [NSError errorWithDomain:@"CacheManager"
                                                       code:42
                                                   userInfo:@{
                        NSLocalizedDescriptionKey: @"The downloaded file is still present, but its local download state could not be restored. Restart InstacastPlus and try again.".ls,
                        NSUnderlyingErrorKey: rollbackSaveError,
                        @"ICCacheFileRemovalError": removalPublicError,
                    }];
                } else {
                    publicError = removalPublicError;
                    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidRestoreCacheNotification
                                                                        object:self
                                                                      userInfo:@{ @"episodeHashes": @[identifier] }];
                }
                [self _presentCacheDeletionError:publicError automatic:automatic];
            }
            if (needsRecalculation) {
                [self _invalidateDownloadedBytesAndRecalculate];
            } else if (success && wasAccounted) {
                [self _subtractDownloadedBytes:removedBytes];
            }
            [self _completeCacheDeletionForIdentifier:identifier error:publicError];
            [self _completeBackgroundSessionForIdentifier:identifier];
        });
    });
}

- (void) removeCacheForFeed:(CDFeed*)feed automatic:(BOOL)automatic
{
    [self removeCacheForFeed:feed automatic:automatic completion:nil];
}

- (void) removeCacheForFeed:(CDFeed*)feed
                   automatic:(BOOL)automatic
                  completion:(void (^)(NSError* error))completion
{
    [self removeCacheForFeeds:feed ? @[feed] : @[] automatic:automatic completion:completion];
}

- (void)removeCacheForFeeds:(NSArray<CDFeed*>*)feeds
                    automatic:(BOOL)automatic
                   completion:(void (^)(NSError* error))completion
{
    [self _removeCacheForFeeds:feeds
                     automatic:automatic
 preserveSubscriptionCleanupDeferredStarts:NO
                    completion:completion];
}

- (void)removeCacheForFeedsDuringSubscriptionCleanup:(NSArray<CDFeed*>*)feeds
                                           completion:(void (^)(NSError* error))completion
{
    [self _removeCacheForFeeds:feeds
                     automatic:NO
 preserveSubscriptionCleanupDeferredStarts:YES
                    completion:completion];
}

- (void)_removeCacheForFeeds:(NSArray<CDFeed*>*)feeds
                    automatic:(BOOL)automatic
preserveSubscriptionCleanupDeferredStarts:(BOOL)preserveDeferredStarts
                   completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _removeCacheForFeeds:feeds
                             automatic:automatic
         preserveSubscriptionCleanupDeferredStarts:preserveDeferredStarts
                            completion:completion];
        });
        return;
    }

    feeds = [NSOrderedSet orderedSetWithArray:feeds ?: @[]].array;
    if (feeds.count == 0) {
        if (completion) completion(nil);
        return;
    }

    NSSet<CDFeed*>* feedSet = [NSSet setWithArray:feeds];
    NSMutableDictionary<NSString*, CDEpisode*>* candidateEpisodesByURI = [NSMutableDictionary dictionary];
    NSMutableOrderedSet<NSURL*>* candidateEpisodeURIs = [NSMutableOrderedSet orderedSet];
    void (^addCandidateEpisode)(CDEpisode*) = ^(CDEpisode* episode) {
        if (![feedSet containsObject:episode.feed] || !episode.objectID || episode.objectID.isTemporaryID) return;
        NSURL* episodeURI = episode.objectID.URIRepresentation;
        candidateEpisodesByURI[episodeURI.absoluteString] = episode;
        [candidateEpisodeURIs addObject:episodeURI];
    };
    for (CDEpisode* episode in [_cachingEpisodes copy]) {
        addCandidateEpisode(episode);
    }
    for (CDEpisode* episode in [self cachedEpisodes]) {
        addCandidateEpisode(episode);
    }

    NSMutableArray<NSURL*>* feedObjectURIs = [NSMutableArray arrayWithCapacity:feeds.count];
    for (CDFeed* feed in feeds) {
        if (feed.objectID && !feed.objectID.isTemporaryID) {
            [feedObjectURIs addObject:feed.objectID.URIRepresentation];
        }
    }
    NSError* databaseUnavailableError = [NSError errorWithDomain:@"CacheManager"
                                                             code:52
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Podcast download data could not be accessed for cleanup. Please restart InstacastPlus and try again.".ls}];

    __block BOOL cancellationFinished = NO;
    __block BOOL removalFinished = NO;
    __block NSError* cancellationError = nil;
    __block NSError* cacheRemovalError = nil;
    void (^finishIfReady)(void) = ^{
        if (cancellationFinished && removalFinished && completion) {
            completion(cacheRemovalError ?: cancellationError);
        }
    };
    [self _cancelCachingFeeds:feeds
 preserveSubscriptionCleanupDeferredStarts:preserveDeferredStarts
                  completion:^(NSError* error) {
        cancellationError = error;
        cancellationFinished = YES;
        finishIfReady();
    }];

    NSArray<NSURL*>* immutableFeedObjectURIs = [feedObjectURIs copy];
    dispatch_async(_cacheDeletionQueue, ^{
        ICCachePhysicalURLSnapshot* physicalURLSnapshot = [self _physicalCacheURLSnapshot];
        if (physicalURLSnapshot.error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                cacheRemovalError = physicalURLSnapshot.error;
                removalFinished = YES;
                finishIfReady();
            });
            return;
        }

        NSArray<NSString*>* physicalEpisodeHashes = physicalURLSnapshot.URLsByEpisodeHash.allKeys;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSManagedObjectContext* selectionContext = [DMANAGER newICloudSyncBackgroundContext];
            if (!selectionContext) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    cacheRemovalError = databaseUnavailableError;
                    removalFinished = YES;
                    finishIfReady();
                });
                return;
            }
            [selectionContext performBlock:^{
        NSError* selectionError = nil;
        NSPersistentStoreCoordinator* selectionCoordinator = selectionContext.persistentStoreCoordinator;
        NSMutableArray<CDFeed*>* backgroundFeeds = [NSMutableArray arrayWithCapacity:immutableFeedObjectURIs.count];
        for (NSURL* feedObjectURI in immutableFeedObjectURIs) {
            NSManagedObjectID* feedObjectID = [selectionCoordinator managedObjectIDForURIRepresentation:feedObjectURI];
            if (!feedObjectID) {
                selectionError = databaseUnavailableError;
                break;
            }
            CDFeed* feed = (CDFeed*)[selectionContext existingObjectWithID:feedObjectID error:&selectionError];
            if (!feed || selectionError) break;
            [backgroundFeeds addObject:feed];
        }

        NSMutableOrderedSet<NSManagedObjectID*>* selectedEpisodeObjectIDs = [NSMutableOrderedSet orderedSet];
        if (!selectionError && backgroundFeeds.count > 0) {
            NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
            request.predicate = [NSPredicate predicateWithFormat:@"feed IN %@ AND lastDownloaded != nil", backgroundFeeds];
            request.resultType = NSManagedObjectIDResultType;
            NSArray<NSManagedObjectID*>* historyObjectIDs = [selectionContext executeFetchRequest:request error:&selectionError];
            if (historyObjectIDs) [selectedEpisodeObjectIDs addObjectsFromArray:historyObjectIDs];

            const NSUInteger cleanupSelectionHashBatchSize = 400;
            for (NSUInteger offset = 0;
                 !selectionError && offset < physicalEpisodeHashes.count;
                 offset += cleanupSelectionHashBatchSize) {
                NSRange hashRange = NSMakeRange(offset,
                                                MIN(cleanupSelectionHashBatchSize, physicalEpisodeHashes.count - offset));
                NSArray<NSString*>* hashBatch = [physicalEpisodeHashes subarrayWithRange:hashRange];
                NSFetchRequest* hashRequest = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                hashRequest.predicate = [NSPredicate predicateWithFormat:@"feed IN %@ AND objectHash IN %@",
                                         backgroundFeeds,
                                         hashBatch];
                hashRequest.resultType = NSManagedObjectIDResultType;
                NSArray<NSManagedObjectID*>* hashObjectIDs = [selectionContext executeFetchRequest:hashRequest error:&selectionError];
                if (hashObjectIDs) [selectedEpisodeObjectIDs addObjectsFromArray:hashObjectIDs];
            }
        }
        NSMutableArray<NSURL*>* selectedEpisodeObjectURIs = [NSMutableArray arrayWithCapacity:selectedEpisodeObjectIDs.count];
        for (NSManagedObjectID* episodeObjectID in selectedEpisodeObjectIDs) {
            [selectedEpisodeObjectURIs addObject:episodeObjectID.URIRepresentation];
        }
        NSArray<NSURL*>* immutableSelectedEpisodeObjectURIs = [selectedEpisodeObjectURIs copy];
        NSArray<CDFeed*>* immutableBackgroundFeeds = [backgroundFeeds copy];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (selectionError) {
                cacheRemovalError = selectionError;
                removalFinished = YES;
                finishIfReady();
                return;
            }

            NSManagedObjectContext* mainContext = DMANAGER.objectContext;
            if (!mainContext) {
                cacheRemovalError = databaseUnavailableError;
                removalFinished = YES;
                finishIfReady();
                return;
            }
            [candidateEpisodeURIs addObjectsFromArray:immutableSelectedEpisodeObjectURIs];
            NSArray<NSURL*>* episodeObjectURIs = candidateEpisodeURIs.array;
            NSPersistentStoreCoordinator* mainCoordinator = mainContext.persistentStoreCoordinator;
            const NSUInteger cleanupBatchSize = 100;
            __block NSUInteger nextURIIndex = 0;
            __block NSError* firstRemovalError = nil;
            void (^finishTranscriptCleanup)(void) = ^{
                dispatch_async(self->_cacheDeletionQueue, ^{
                    ICTranscriptCacheSnapshot* transcriptSnapshot = ICTranscriptCacheURLSnapshot();
                    NSArray<NSString*>* transcriptEpisodeHashes = transcriptSnapshot.URLsByEpisodeHash.allKeys;
                    [selectionContext performBlock:^{
                        NSError* transcriptSelectionError = transcriptSnapshot.error;
                        NSMutableSet<NSString*>* matchedTranscriptEpisodeHashes = [NSMutableSet set];
                        const NSUInteger cleanupTranscriptHashBatchSize = 400;
                        for (NSUInteger offset = 0;
                             !transcriptSelectionError && offset < transcriptEpisodeHashes.count;
                             offset += cleanupTranscriptHashBatchSize) {
                            NSRange hashRange = NSMakeRange(offset,
                                                            MIN(cleanupTranscriptHashBatchSize, transcriptEpisodeHashes.count - offset));
                            NSArray<NSString*>* hashBatch = [transcriptEpisodeHashes subarrayWithRange:hashRange];
                            NSFetchRequest* transcriptRequest = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                            transcriptRequest.predicate = [NSPredicate predicateWithFormat:@"feed IN %@ AND objectHash IN %@",
                                                           immutableBackgroundFeeds,
                                                           hashBatch];
                            transcriptRequest.resultType = NSDictionaryResultType;
                            transcriptRequest.propertiesToFetch = @[@"objectHash"];
                            transcriptRequest.returnsDistinctResults = YES;
                            NSArray<NSDictionary*>* rows = [selectionContext executeFetchRequest:transcriptRequest
                                                                                           error:&transcriptSelectionError];
                            for (NSDictionary* row in rows) {
                                NSString* episodeHash = row[@"objectHash"];
                                if (episodeHash.length > 0) [matchedTranscriptEpisodeHashes addObject:episodeHash];
                            }
                        }

                        NSSet<NSString*>* immutableMatchedTranscriptEpisodeHashes = [matchedTranscriptEpisodeHashes copy];
                        dispatch_async(self->_cacheDeletionQueue, ^{
                            NSError* transcriptRemovalError = ICRemoveTranscriptCacheURLsForEpisodeHashes(immutableMatchedTranscriptEpisodeHashes,
                                                                                                            transcriptSnapshot);
                            NSError* transcriptCleanupError = transcriptSelectionError ?: transcriptRemovalError;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (!firstRemovalError && transcriptCleanupError) firstRemovalError = transcriptCleanupError;
                                cacheRemovalError = firstRemovalError;
                                removalFinished = YES;
                                finishIfReady();
                            });
                        });
                    }];
                });
            };
            __block void (^processNextChunk)(void) = nil;
            processNextChunk = ^{
                if (nextURIIndex >= episodeObjectURIs.count) {
                    processNextChunk = nil;
                    finishTranscriptCleanup();
                    return;
                }

                NSRange chunkRange = NSMakeRange(nextURIIndex,
                                                 MIN(cleanupBatchSize, episodeObjectURIs.count - nextURIIndex));
                nextURIIndex = NSMaxRange(chunkRange);
                NSArray<NSURL*>* URIChunk = [episodeObjectURIs subarrayWithRange:chunkRange];
                NSMutableArray<CDEpisode*>* episodes = [NSMutableArray arrayWithCapacity:URIChunk.count];
                for (NSURL* episodeObjectURI in URIChunk) {
                    CDEpisode* episode = candidateEpisodesByURI[episodeObjectURI.absoluteString];
                    if (!episode) {
                        NSManagedObjectID* episodeObjectID = [mainCoordinator managedObjectIDForURIRepresentation:episodeObjectURI];
                        NSError* bindingError = nil;
                        if (episodeObjectID) {
                            episode = (CDEpisode*)[mainContext existingObjectWithID:episodeObjectID error:&bindingError];
                        } else {
                            bindingError = databaseUnavailableError;
                        }
                        if (!firstRemovalError && bindingError) firstRemovalError = bindingError;
                    }
                    if ([episode isKindOfClass:[CDEpisode class]] && !episode.isDeleted) {
                        [episodes addObject:episode];
                    }
                }

                [self _removeCacheRequestsForEpisodes:episodes
                                            automatic:automatic
                                  physicalURLSnapshot:physicalURLSnapshot
                                           completion:^(NSError* removalError) {
                    if (!firstRemovalError && removalError) firstRemovalError = removalError;
                    dispatch_async(dispatch_get_main_queue(), processNextChunk);
                }];
            };
            processNextChunk();
        });
            }];
        });
    });
}

- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes
                       automatic:(BOOL)automatic
                      completion:(void (^)(NSError* error))completion
{
    [self _removeCacheForEpisodes:episodes
                        automatic:automatic
              physicalURLSnapshot:nil
                       completion:completion];
}

- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes
                       automatic:(BOOL)automatic
             physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot
                      completion:(void (^)(NSError* error))completion
{
    NSAssert([NSThread isMainThread], @"Cache deletion state must be mutated on the main thread");

    NSString* token = NSUUID.UUID.UUIDString;
    NSUInteger generation = _cacheIndexGeneration;
    NSMutableArray<NSDictionary*>* items = [NSMutableArray array];
    NSMutableArray<CDEpisode*>* logicalEpisodes = [NSMutableArray array];
    NSMutableSet<NSString*>* seenHashes = [NSMutableSet set];
    NSMutableSet<NSString*>* identifiersToWaitFor = [NSMutableSet set];
    BOOL completionWasQueued = NO;
    NSError* preparationError = nil;

    for (CDEpisode* episode in episodes) {
        if (automatic && episode.starred) continue;
        NSString* identifier = episode.objectHash;
        if (identifier.length == 0 || [seenHashes containsObject:identifier]) continue;
        [seenHashes addObject:identifier];

        if (_cacheDeletionTokensByIdentifier[identifier]) {
            if (completion) [identifiersToWaitFor addObject:identifier];
            continue;
        }

        BOOL wasCached = [_cachedEpisodes containsObject:episode];
        BOOL importInFlight = (_cacheImportTokensByIdentifier[identifier] != nil);
        NSURL* cachedURL = _cachedURLIndex[identifier];
        BOOL indexedFile = (cachedURL != nil);
        BOOL hasLogicalState = wasCached || indexedFile || importInFlight || episode.downloaded || episode.lastDownloaded;
        if (!hasLogicalState) continue;
        if (wasCached && !cachedURL) {
            preparationError = [NSError errorWithDomain:@"CacheManager"
                                                    code:32
                                                userInfo:@{NSLocalizedDescriptionKey: @"The downloaded file could not be located. Restart the app and try again.".ls}];
            continue;
        }
        if (episode.objectID.isTemporaryID) {
            preparationError = [NSError errorWithDomain:@"CacheManager"
                                                    code:33
                                                userInfo:@{NSLocalizedDescriptionKey: @"The downloaded file could not be removed because the episode has not been saved yet.".ls}];
            continue;
        }

        NSMutableDictionary* item = [@{
            ICCacheDeletionHashKey: identifier,
            ICCacheDeletionObjectIDKey: episode.objectID,
            ICCacheDeletionURLKey: cachedURL ?: (id)NSNull.null,
            ICCacheDeletionLastDownloadedKey: episode.lastDownloaded ?: (id)NSNull.null,
            ICCacheDeletionDownloadedKey: @(episode.downloaded),
            ICCacheDeletionWasCachedKey: @(wasCached),
            ICCacheDeletionWasAccountedKey: @(wasCached || episode.downloaded),
        } mutableCopy];
#if !TARGET_OS_IPHONE
        if (cachedURL) {
            NSString* partialName = [cachedURL.lastPathComponent stringByAppendingString:@".part"];
            item[@"temporaryURL"] = [NSURL fileURLWithPath:[[CacheManager _pathToCache] stringByAppendingPathComponent:partialName]];
        }
#endif
        [items addObject:[item copy]];
        [logicalEpisodes addObject:episode];
        if (completion) [identifiersToWaitFor addObject:identifier];
        _cacheDeletionTokensByIdentifier[identifier] = token;
        if (_cacheIndexScanInFlight) [_cacheDeletionHashesDuringIndexScan addObject:identifier];
    }

    if (completion && identifiersToWaitFor.count > 0) {
        __block NSUInteger remainingCompletions = identifiersToWaitFor.count;
        __block NSError* batchError = preparationError;
        void (^itemCompletion)(NSError*) = ^(NSError* error) {
            if (!batchError && error) batchError = error;
            remainingCompletions--;
            if (remainingCompletions == 0) completion(batchError);
        };
        for (NSString* identifier in identifiersToWaitFor) {
            NSMutableArray* completions = _cacheDeletionCompletionsByIdentifier[identifier];
            if (!completions) {
                completions = [NSMutableArray array];
                _cacheDeletionCompletionsByIdentifier[identifier] = completions;
            }
            [completions addObject:[itemCompletion copy]];
        }
        completionWasQueued = YES;
    }

    if (items.count == 0) {
        if (preparationError) {
            [self _presentCacheDeletionError:preparationError automatic:automatic];
            if (completion && !completionWasQueued) completion(preparationError);
        } else if (completion && !completionWasQueued) {
            completion(nil);
        }
        return;
    }

    [self willChangeValueForKey:@"cachedEpisodes"];
    for (NSUInteger index = 0; index < items.count; index++) {
        NSDictionary* item = items[index];
        CDEpisode* episode = logicalEpisodes[index];
        NSString* identifier = item[ICCacheDeletionHashKey];
        [_cachedEpisodes removeObject:episode];
        [_cachedURLIndex removeObjectForKey:identifier];
        episode.downloaded = NO;
        episode.lastDownloaded = nil;
    }
    [self didChangeValueForKey:@"cachedEpisodes"];

    NSError* saveError = [DMANAGER saveReturningError];
    if (saveError) {
        NSMutableArray<NSString*>* failedIdentifiers = [NSMutableArray arrayWithCapacity:items.count];
        [self willChangeValueForKey:@"cachedEpisodes"];
        for (NSUInteger index = 0; index < items.count; index++) {
            NSDictionary* item = items[index];
            CDEpisode* episode = logicalEpisodes[index];
            NSString* identifier = item[ICCacheDeletionHashKey];
            NSURL* cachedURL = item[ICCacheDeletionURLKey] == NSNull.null ? nil : item[ICCacheDeletionURLKey];
            if ([item[ICCacheDeletionWasCachedKey] boolValue]) [_cachedEpisodes addObject:episode];
            if (cachedURL) _cachedURLIndex[identifier] = cachedURL;
            episode.downloaded = [item[ICCacheDeletionDownloadedKey] boolValue];
            episode.lastDownloaded = item[ICCacheDeletionLastDownloadedKey] == NSNull.null ? nil : item[ICCacheDeletionLastDownloadedKey];
            if ([_cacheDeletionTokensByIdentifier[identifier] isEqualToString:token]) {
                [_cacheDeletionTokensByIdentifier removeObjectForKey:identifier];
            }
            [_cacheDeletionHashesDuringIndexScan removeObject:identifier];
            [failedIdentifiers addObject:identifier];
        }
        [self didChangeValueForKey:@"cachedEpisodes"];
        [DMANAGER.objectContext processPendingChanges];
        [self _presentCacheDeletionError:saveError automatic:automatic];
        for (NSString* identifier in failedIdentifiers) {
            [self _completeCacheDeletionForIdentifier:identifier error:saveError];
        }
        return;
    }

    NSMutableArray<NSString*>* removedHashes = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary* item in items) [removedHashes addObject:item[ICCacheDeletionHashKey]];
    ICCacheDeletionPreparation* deletionPreparation = [[ICCacheDeletionPreparation alloc] init];
    NSDictionary* lifecycleUserInfo = @{
        @"episodeHashes": [removedHashes copy],
        @"automatic": @(automatic),
        @"cacheDeletionPreparation": deletionPreparation,
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerWillDeleteCacheFilesNotification
                                                        object:self
                                                      userInfo:lifecycleUserInfo];
    if (!_flags.supressDidClear) {
        NSMutableDictionary* userInfo = [lifecycleUserInfo mutableCopy];
        if (logicalEpisodes.count == 1) userInfo[@"episode"] = logicalEpisodes.firstObject;
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidClearCacheNotification
                                                            object:self
                                                          userInfo:userInfo];
    }

    if (preparationError) [self _presentCacheDeletionError:preparationError automatic:automatic];
    NSArray<NSDictionary*>* fileItems = [items copy];
    dispatch_async(_cacheDeletionQueue, ^{
        [self _performCacheFileDeletionForItems:fileItems
                                          token:token
                                     generation:generation
                                      automatic:automatic
                            deletionPreparation:deletionPreparation
                            physicalURLSnapshot:physicalURLSnapshot];
    });
}

- (ICCachePhysicalURLSnapshot*)_physicalCacheURLSnapshot
{
    NSFileManager* fileManager = [[NSFileManager alloc] init];
    NSString* storagePath = [CacheManager _pathToStorageLocation];
    NSError* directoryError = nil;
    NSArray<NSString*>* fileNames = [fileManager contentsOfDirectoryAtPath:storagePath error:&directoryError];
    if (ICCacheFileErrorMeansMissing(directoryError)) directoryError = nil;

    NSMutableDictionary<NSString*, NSMutableOrderedSet<NSURL*>*>* mutableURLsByHash = [NSMutableDictionary dictionary];
    for (NSString* fileName in fileNames) {
        NSString* nameWithoutExtension = [fileName stringByDeletingPathExtension];
        NSRange lastSeparator = [nameWithoutExtension rangeOfString:@" - " options:NSBackwardsSearch];
        NSString* identifier = lastSeparator.location == NSNotFound
            ? nameWithoutExtension
            : [nameWithoutExtension substringFromIndex:NSMaxRange(lastSeparator)];
        if (identifier.length == 0) continue;
        NSMutableOrderedSet<NSURL*>* physicalURLs = mutableURLsByHash[identifier];
        if (!physicalURLs) {
            physicalURLs = [NSMutableOrderedSet orderedSet];
            mutableURLsByHash[identifier] = physicalURLs;
        }
        [physicalURLs addObject:[NSURL fileURLWithPath:[storagePath stringByAppendingPathComponent:fileName]]];
    }

    NSMutableDictionary<NSString*, NSArray<NSURL*>*>* URLsByHash = [NSMutableDictionary dictionaryWithCapacity:mutableURLsByHash.count];
    [mutableURLsByHash enumerateKeysAndObjectsUsingBlock:^(NSString* identifier,
                                                           NSMutableOrderedSet<NSURL*>* physicalURLs,
                                                           BOOL* stop) {
        URLsByHash[identifier] = physicalURLs.array;
    }];
    ICCachePhysicalURLSnapshot* snapshot = [[ICCachePhysicalURLSnapshot alloc] init];
    snapshot.URLsByEpisodeHash = [URLsByHash copy];
    snapshot.error = directoryError;
    return snapshot;
}

- (void)_performCacheFileDeletionForItems:(NSArray<NSDictionary*>*)items
                                     token:(NSString*)token
                                generation:(NSUInteger)generation
                                 automatic:(BOOL)automatic
                       deletionPreparation:(ICCacheDeletionPreparation*)deletionPreparation
                       physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot
{
    @autoreleasepool {
        NSError* preparationError = [deletionPreparation waitForPreparation];
        if (preparationError) {
            NSError* durabilityError = ICCacheDeletionDurabilityError(preparationError);
            NSMutableArray<NSDictionary*>* failedResults = [NSMutableArray arrayWithCapacity:items.count];
            for (NSDictionary* item in items) {
                NSURL* cachedURL = item[ICCacheDeletionURLKey] == NSNull.null ? nil : item[ICCacheDeletionURLKey];
                [failedResults addObject:@{
                    ICCacheDeletionSuccessKey: @NO,
                    ICCacheDeletionRemovedBytesKey: @0,
                    ICCacheDeletionNeedsRecalculationKey: @NO,
                    ICCacheDeletionErrorKey: durabilityError,
                    ICCacheDeletionResolvedURLKey: cachedURL ?: (id)NSNull.null,
                    ICCacheDeletionFileWasPresentKey: @NO,
                }];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finishCacheFileDeletionForItems:items
                                               results:failedResults
                                                 token:token
                                            generation:generation
                                             automatic:automatic];
            });
            return;
        }
        NSMutableArray<NSString*>* committingHashes = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary* item in items) {
            NSString* identifier = item[ICCacheDeletionHashKey];
            if (identifier.length > 0) [committingHashes addObject:identifier];
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerWillCommitCacheFileDeletionNotification
                                                                object:self
                                                              userInfo:@{
                                                                  @"episodeHashes": committingHashes,
                                                                  @"automatic": @(automatic),
                                                              }];
        });
        NSFileManager* fileManager = [[NSFileManager alloc] init];
        NSMutableArray<NSDictionary*>* results = [NSMutableArray arrayWithCapacity:items.count];
        NSMutableSet<NSString*>* successfullyRemovedHashes = [NSMutableSet setWithCapacity:items.count];
        NSMutableSet<NSString*>* requestedHashes = [NSMutableSet setWithCapacity:items.count];
        NSMutableDictionary<NSString*, NSMutableOrderedSet<NSURL*>*>* physicalURLsByHash = [NSMutableDictionary dictionaryWithCapacity:items.count];
        for (NSDictionary* item in items) {
            NSString* identifier = item[ICCacheDeletionHashKey];
            if (identifier.length == 0) continue;
            [requestedHashes addObject:identifier];
            NSURL* indexedURL = item[ICCacheDeletionURLKey] == NSNull.null ? nil : item[ICCacheDeletionURLKey];
            if (indexedURL) {
                physicalURLsByHash[identifier] = [NSMutableOrderedSet orderedSetWithObject:indexedURL];
            }
        }

        NSError* URLResolutionError = physicalURLSnapshot.error;
        if (physicalURLSnapshot) {
            for (NSString* identifier in requestedHashes) {
                NSArray<NSURL*>* snapshotURLs = physicalURLSnapshot.URLsByEpisodeHash[identifier];
                if (snapshotURLs.count == 0) continue;
                NSMutableOrderedSet<NSURL*>* physicalURLs = physicalURLsByHash[identifier];
                if (!physicalURLs) {
                    physicalURLs = [NSMutableOrderedSet orderedSet];
                    physicalURLsByHash[identifier] = physicalURLs;
                }
                [physicalURLs addObjectsFromArray:snapshotURLs];
            }
        } else {
            NSString* storagePath = [CacheManager _pathToStorageLocation];
            NSArray<NSString*>* fileNames = [fileManager contentsOfDirectoryAtPath:storagePath error:&URLResolutionError];
            if (ICCacheFileErrorMeansMissing(URLResolutionError)) URLResolutionError = nil;
            for (NSString* fileName in fileNames) {
                NSString* nameWithoutExtension = [fileName stringByDeletingPathExtension];
                NSRange lastSeparator = [nameWithoutExtension rangeOfString:@" - " options:NSBackwardsSearch];
                NSString* identifier = lastSeparator.location == NSNotFound
                    ? nameWithoutExtension
                    : [nameWithoutExtension substringFromIndex:NSMaxRange(lastSeparator)];
                if (![requestedHashes containsObject:identifier]) continue;
                NSMutableOrderedSet<NSURL*>* physicalURLs = physicalURLsByHash[identifier];
                if (!physicalURLs) {
                    physicalURLs = [NSMutableOrderedSet orderedSet];
                    physicalURLsByHash[identifier] = physicalURLs;
                }
                NSURL* fileURL = [NSURL fileURLWithPath:[storagePath stringByAppendingPathComponent:fileName]];
                [physicalURLs addObject:fileURL];
            }
        }

        for (NSDictionary* item in items) {
            NSString* identifier = item[ICCacheDeletionHashKey];
            NSArray<NSURL*>* physicalURLs = physicalURLsByHash[identifier].array ?: @[];
            unsigned long long removedBytes = 0;
            BOOL wasAccounted = [item[ICCacheDeletionWasAccountedKey] boolValue];
            BOOL needsRecalculation = !wasAccounted;
            BOOL success = (URLResolutionError == nil);
            BOOL fileWasPresent = NO;
            NSURL* remainingURL = nil;
            NSError* removalError = success ? nil : URLResolutionError;

#if !TARGET_OS_IPHONE
            NSURL* temporaryURL = item[@"temporaryURL"];
            if (success && temporaryURL) {
                NSError* temporaryRemovalError = nil;
                BOOL removedTemporaryFile = [fileManager removeItemAtURL:temporaryURL error:&temporaryRemovalError] || ICCacheFileErrorMeansMissing(temporaryRemovalError);
                if (!removedTemporaryFile) {
                    success = NO;
                    removalError = temporaryRemovalError;
                }
            }
#endif

            if (!success) {
                remainingURL = physicalURLs.firstObject;
            }
            BOOL canRemovePhysicalFiles = success;
            for (NSURL* physicalURL in physicalURLs) {
                if (!canRemovePhysicalFiles) break;
                NSError* attributesError = nil;
                NSDictionary* attributes = [fileManager attributesOfItemAtPath:physicalURL.path error:&attributesError];
                if (!attributes && ICCacheFileErrorMeansMissing(attributesError)) {
                    continue;
                }
                if (!attributes) {
                    needsRecalculation = YES;
                } else if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                    success = NO;
                    remainingURL = physicalURL;
                    removalError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                       code:NSFileWriteInvalidFileNameError
                                                   userInfo:@{NSLocalizedDescriptionKey: @"The episode cache path is not a regular file."}];
                    continue;
                } else {
                    fileWasPresent = YES;
                }

                NSError* mediaRemovalError = nil;
                BOOL removed = [fileManager removeItemAtURL:physicalURL error:&mediaRemovalError]
                    || ICCacheFileErrorMeansMissing(mediaRemovalError);
                if (removed) {
                    if (attributes) {
                        removedBytes += [attributes fileSize];
                    }
                } else {
                    success = NO;
                    remainingURL = remainingURL ?: physicalURL;
                    removalError = removalError ?: mediaRemovalError;
                }
            }
            if (!fileWasPresent) needsRecalculation = YES;
            if (!success && removedBytes > 0) needsRecalculation = YES;

            if (success) {
                [successfullyRemovedHashes addObject:identifier];
#if TARGET_OS_IPHONE
                [CACHE_OPERATION_CLASS deleteResumeInfoForIdentifier:identifier];
#endif
            }

            [results addObject:@{
                ICCacheDeletionSuccessKey: @(success),
                ICCacheDeletionRemovedBytesKey: @(success && wasAccounted ? removedBytes : 0),
                ICCacheDeletionNeedsRecalculationKey: @(needsRecalculation),
                ICCacheDeletionErrorKey: removalError ?: (id)NSNull.null,
                ICCacheDeletionResolvedURLKey: remainingURL ?: (id)NSNull.null,
                ICCacheDeletionFileWasPresentKey: @(remainingURL != nil || fileWasPresent),
            }];
        }

        if (!physicalURLSnapshot) ICRemoveTranscriptCacheForEpisodeHashes(successfullyRemovedHashes);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _finishCacheFileDeletionForItems:items
                                           results:results
                                             token:token
                                        generation:generation
                                         automatic:automatic];
        });
    }
}

- (void)_finishCacheFileDeletionForItems:(NSArray<NSDictionary*>*)items
                                  results:(NSArray<NSDictionary*>*)results
                                    token:(NSString*)token
                               generation:(NSUInteger)generation
                                automatic:(BOOL)automatic
{
    NSAssert([NSThread isMainThread], @"Cache deletion completion must run on the main thread");
    if (generation != _cacheIndexGeneration) return;

    unsigned long long removedBytes = 0;
    BOOL needsRecalculation = NO;
    NSError* firstPublicError = nil;
    NSMutableArray<NSDictionary*>* rollbackEntries = [NSMutableArray array];
    NSMutableDictionary<NSString*, NSError*>* completionErrors = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* currentIdentifiers = [NSMutableArray array];
    NSMutableArray<NSString*>* successfulIdentifiers = [NSMutableArray array];

    for (NSUInteger index = 0; index < items.count; index++) {
        NSDictionary* item = items[index];
        NSString* identifier = item[ICCacheDeletionHashKey];
        if (![self->_cacheDeletionTokensByIdentifier[identifier] isEqualToString:token]) continue;
        [currentIdentifiers addObject:identifier];

        NSDictionary* result = index < results.count ? results[index] : nil;
        BOOL success = [result[ICCacheDeletionSuccessKey] boolValue];
        needsRecalculation = needsRecalculation || [result[ICCacheDeletionNeedsRecalculationKey] boolValue];
        if (success) {
            [successfulIdentifiers addObject:identifier];
            removedBytes += [result[ICCacheDeletionRemovedBytesKey] unsignedLongLongValue];
            continue;
        }

        NSError* underlyingError = result[ICCacheDeletionErrorKey] == NSNull.null ? nil : result[ICCacheDeletionErrorKey];
        NSError* publicError = [underlyingError.domain isEqualToString:@"CacheManager"] && underlyingError.code == 36
            ? underlyingError
            : [NSError errorWithDomain:@"CacheManager"
                                  code:34
                              userInfo:@{
                                  NSLocalizedDescriptionKey: @"The downloaded file could not be deleted. Restart the app and try again.".ls,
                                  NSUnderlyingErrorKey: underlyingError ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil],
                              }];
        completionErrors[identifier] = publicError;
        if (!firstPublicError) firstPublicError = publicError;

        NSError* objectError = nil;
        CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:item[ICCacheDeletionObjectIDKey]
                                                                                       error:&objectError];
        if (!objectError && [episode isKindOfClass:[CDEpisode class]] && !episode.isDeleted) {
            [rollbackEntries addObject:@{ @"episode": episode, @"item": item, @"result": result ?: @{} }];
        }
    }

    if (rollbackEntries.count > 0) {
        [self willChangeValueForKey:@"cachedEpisodes"];
        for (NSDictionary* rollbackEntry in rollbackEntries) {
            CDEpisode* episode = rollbackEntry[@"episode"];
            NSDictionary* item = rollbackEntry[@"item"];
            NSDictionary* result = rollbackEntry[@"result"];
            NSString* identifier = item[ICCacheDeletionHashKey];
            NSURL* cachedURL = result[ICCacheDeletionResolvedURLKey] == NSNull.null ? nil : result[ICCacheDeletionResolvedURLKey];
            if (!cachedURL && item[ICCacheDeletionURLKey] != NSNull.null) cachedURL = item[ICCacheDeletionURLKey];
            BOOL restoreAsCached = [item[ICCacheDeletionWasCachedKey] boolValue] || [result[ICCacheDeletionFileWasPresentKey] boolValue];
            if (restoreAsCached) [_cachedEpisodes addObject:episode];
            if (cachedURL) _cachedURLIndex[identifier] = cachedURL;
            episode.downloaded = restoreAsCached || [item[ICCacheDeletionDownloadedKey] boolValue];
            episode.lastDownloaded = item[ICCacheDeletionLastDownloadedKey] == NSNull.null ? nil : item[ICCacheDeletionLastDownloadedKey];
            [_cacheDeletionHashesDuringIndexScan removeObject:identifier];
        }
        [self didChangeValueForKey:@"cachedEpisodes"];

        NSError* rollbackSaveError = [DMANAGER saveReturningError];
        if (rollbackSaveError) {
            firstPublicError = rollbackSaveError;
            for (NSDictionary* rollbackEntry in rollbackEntries) {
                NSString* identifier = rollbackEntry[@"item"][ICCacheDeletionHashKey];
                completionErrors[identifier] = rollbackSaveError;
            }
        }
    }

    if (needsRecalculation) {
        [self _invalidateDownloadedBytesAndRecalculate];
    } else {
        [self _subtractDownloadedBytes:removedBytes];
    }

    for (NSString* identifier in currentIdentifiers) {
        [self->_cacheDeletionTokensByIdentifier removeObjectForKey:identifier];
    }
    NSMutableSet<NSString*>* restoredIdentifiers = [NSMutableSet set];
    for (NSDictionary* rollbackEntry in rollbackEntries) {
        [restoredIdentifiers addObject:rollbackEntry[@"item"][ICCacheDeletionHashKey]];
    }
    if (restoredIdentifiers.count > 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidUpdateNotification object:self];
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidRestoreCacheNotification
                                                            object:self
                                                          userInfo:@{ @"episodeHashes": restoredIdentifiers.allObjects }];
    }
    NSMutableSet<NSString*>* terminalDeletedIdentifiers = [NSMutableSet setWithArray:successfulIdentifiers];
    for (NSString* identifier in currentIdentifiers) {
        if (completionErrors[identifier] && ![restoredIdentifiers containsObject:identifier]) {
            [terminalDeletedIdentifiers addObject:identifier];
        }
    }
    if (terminalDeletedIdentifiers.count > 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidDeleteCacheFilesNotification
                                                            object:self
                                                          userInfo:@{ @"episodeHashes": terminalDeletedIdentifiers.allObjects }];
    }
    if (firstPublicError) [self _presentCacheDeletionError:firstPublicError automatic:automatic];
    for (NSString* identifier in currentIdentifiers) {
        [self _completeCacheDeletionForIdentifier:identifier error:completionErrors[identifier]];
    }
    if (_hasPendingAutoClear && !_autoClearSelectionInFlight) {
        unsigned long long pendingBytes = _pendingAutoClearBytes;
        BOOL pendingAutomatic = _pendingAutoClearAutomatic;
        _hasPendingAutoClear = NO;
        _pendingAutoClearBytes = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self autoClearAndMakeRoomForBytes:pendingBytes automatic:pendingAutomatic];
        });
    }
}

- (void)_completeCacheDeletionForIdentifier:(NSString*)identifier error:(NSError*)error
{
    NSArray* completions = [_cacheDeletionCompletionsByIdentifier[identifier] copy];
    [_cacheDeletionCompletionsByIdentifier removeObjectForKey:identifier];
    for (id completionObject in completions) {
        void (^completion)(NSError*) = completionObject;
        completion(error);
    }
    if (_subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier]) {
        [self _resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil];
    }
}

- (void)_presentCacheDeletionError:(NSError*)error automatic:(BOOL)automatic
{
    if (!error) return;
    ErrLog(@"cache deletion failed: %@", error);
#if TARGET_OS_IPHONE
    if (!automatic && App.applicationState == UIApplicationStateActive) {
        [App showBackgroundErrorWithTitle:@"Download Could Not Be Removed".ls
                                  message:error.localizedDescription
                                 duration:8.0];
    }
#else
    (void)automatic;
#endif
}


- (BOOL) isCaching
{
	return (_downloadOperationsByIdentifier.count > 0
        || _streamingCacheLeaseTokensByIdentifier.count > 0
        || _subscriptionCleanupDeferredDownloadInfosByIdentifier.count > 0);
}

- (CACHE_OPERATION_CLASS*) _cacheOperationForEpisode:(CDEpisode*)episode
{
	NSString* identifier = episode.objectHash;
	return identifier.length > 0 ? _downloadOperationsByIdentifier[identifier] : nil;
}

- (BOOL) _removeTrackedDownloadOperation:(CACHE_OPERATION_CLASS*)operation
{
    NSString* identifier = operation.identifier;
    if (identifier.length == 0 || _downloadOperationsByIdentifier[identifier] != operation) {
        return NO;
    }

    [_downloadOperationsByIdentifier removeObjectForKey:identifier];
    [_scheduledDownloadOperationIdentifiers removeObject:identifier];
    [_downloadPauseYieldTokensByIdentifier removeObjectForKey:identifier];
    [_downloadQueueRanksByIdentifier removeObjectForKey:identifier];
    [_manuallySuspendedDownloadIdentifiers removeObject:identifier];
    [self _removeSavedCachingInfoForIdentifier:identifier];
    [self _removeCachingEpisodeForIdentifierIfUnowned:identifier];
    if (_subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier]) {
        [self _resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil];
    }
    return YES;
}

- (void)_removeCachingEpisodeForIdentifierIfUnowned:(NSString*)identifier
{
    if (identifier.length == 0 ||
        _downloadOperationsByIdentifier[identifier] ||
        _streamingCacheLeaseTokensByIdentifier[identifier]) {
        return;
    }

    BOOL removedEpisode = NO;
    for (CDEpisode* cachingEpisode in [_cachingEpisodes copy]) {
        if ([cachingEpisode.objectHash isEqualToString:identifier]) {
            if (!removedEpisode) {
                [self willChangeValueForKey:@"cachingEpisodes"];
                removedEpisode = YES;
            }
            [_cachingEpisodes removeObject:cachingEpisode];
        }
    }
    if (removedEpisode) {
        [self didChangeValueForKey:@"cachingEpisodes"];
    }
    [_cachingEpisodeHashes removeObject:identifier];
}


- (BOOL) isCachingSourceOfEpisode:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation) {
		return ![operation isCancelled];
	}
	return NO;
}

- (BOOL) isCachingEpisode:(CDEpisode*)episode
{
    NSString* identifier = episode.objectHash;
    return identifier.length > 0
        && ([_cachingEpisodeHashes containsObject:identifier]
            || _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier]);
}

- (BOOL) isCachingFeed:(CDFeed*)feed
{
    NSArray* operations = [_downloadOperationsByIdentifier.allValues copy];
    for(CACHE_OPERATION_CLASS* operation in operations) {
        CDEpisode* episode = (CDEpisode*)operation.userInfo;
        if (![operation isCancelled] && [episode.feed isEqual:feed]) {
            return YES;
        }
	}

    for (CDEpisode* episode in _subscriptionCleanupDeferredDownloadEpisodesByIdentifier.allValues) {
        if ([episode.feed isEqual:feed]) return YES;
    }

    return NO;
}

- (void) cancelCaching
{
    for (CDEpisode* episode in [self cachingEpisodes]) {
        [self cancelCachingEpisode:episode disableAutoDownload:NO];
    }
}

- (void) cancelCachingEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload
{
    [self _cancelCachingEpisode:episode disableAutoDownload:disableAutodownload completion:nil];
}

- (void)_cancelDownloadOperationForStreamingTransition:(CACHE_OPERATION_CLASS*)operation
{
    NSString* identifier = operation.identifier;
    if (identifier.length == 0) return;
    BOOL hasPendingYield = _downloadPauseYieldTokensByIdentifier[identifier] != nil;
    if (!hasPendingYield &&
        (operation.cancelled ||
         operation.finished ||
         [_finalizingDownloadOperationIdentifiers containsObject:identifier])) {
        return;
    }
    if (_downloadOperationsByIdentifier[identifier] == operation) {
        [_downloadPauseYieldTokensByIdentifier removeObjectForKey:identifier];
        [self _cancelTrackedDownloadOperationAfterDurableIntent:operation];
    }
}

- (void)_cancelCachingEpisode:(CDEpisode*)episode
          disableAutoDownload:(BOOL)disableAutodownload
                   completion:(void (^)(BOOL waitsForOperationEnd, NSError* error))completion
{
    NSAssert([NSThread isMainThread], @"Download cancellation lifecycle must run on the main thread");
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
    NSString *identifier = episode.objectHash;
    BOOL operationIsFinalizing = operation
        && [_finalizingDownloadOperationIdentifiers containsObject:operation.identifier];
    BOOL needsDeferredRestoreCommit = [InstacastBackupImporter ownsDeferredDownloadWithObjectHash:identifier];
    if (identifier.length == 0 || !needsDeferredRestoreCommit) {
        BOOL waitsForOperationEnd = operation
            && (operation.isExecuting || operationIsFinalizing);
        [self _cancelCachingEpisodeAfterDurableIntent:episode disableAutoDownload:disableAutodownload];
        if (completion) completion(waitsForOperationEnd, nil);
        return;
    }

    if (completion) {
        NSMutableArray *completions = _durableCancellationCompletionsByIdentifier[identifier];
        if (!completions) {
            completions = [NSMutableArray array];
            _durableCancellationCompletionsByIdentifier[identifier] = completions;
        }
        [completions addObject:[completion copy]];
    }
    if ([_pendingDurableCancellationIdentifiers containsObject:identifier]) return;
    [_pendingDurableCancellationIdentifiers addObject:identifier];

    [InstacastBackupImporter prepareForDeferredDownloadCancellation:identifier
                                                            feedURL:episode.feed.sourceURL.absoluteString ?: @""
                                                         episodeGUID:episode.guid ?: @""
                                                          completion:^(NSError *error) {
        NSArray *completions = [self->_durableCancellationCompletionsByIdentifier[identifier] copy];
        [self->_durableCancellationCompletionsByIdentifier removeObjectForKey:identifier];
        [self->_pendingDurableCancellationIdentifiers removeObject:identifier];
        if (error) {
            ErrLog(@"could not persist deferred-download cancellation: %@", error);
#if TARGET_OS_IPHONE
            if (App.applicationState == UIApplicationStateActive) {
                [App showBackgroundErrorWithTitle:@"Download Could Not Be Cancelled".ls
                                          message:error.localizedDescription
                                         duration:8.0];
            }
#endif
            for (void (^pendingCompletion)(BOOL, NSError*) in completions) {
                pendingCompletion(NO, error);
            }
            return;
        }

        CACHE_OPERATION_CLASS *currentOperation = [self _cacheOperationForEpisode:episode];
        BOOL currentOperationIsFinalizing = currentOperation
            && [self->_finalizingDownloadOperationIdentifiers
                containsObject:currentOperation.identifier];
        BOOL waitsForOperationEnd = currentOperation
            && (currentOperation.isExecuting || currentOperationIsFinalizing);
        [self _cancelCachingEpisodeAfterDurableIntent:episode disableAutoDownload:disableAutodownload];
        [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
        for (void (^pendingCompletion)(BOOL, NSError*) in completions) {
            pendingCompletion(waitsForOperationEnd, nil);
        }
    }];
}

- (void)_cancelTrackedDownloadOperationAfterDurableIntent:(CACHE_OPERATION_CLASS*)operation
{
    if (!operation) return;
    NSString* identifier = operation.identifier;
    BOOL operationWasExecuting = operation.isExecuting;
    BOOL mustInvalidateBackgroundSession = !operationWasExecuting &&
        _backgroundSessionCompletionHandlers[identifier] != nil;
    if (mustInvalidateBackgroundSession &&
        _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier]) {
        [_subscriptionCleanupBackgroundSessionCancellationIdentifiers addObject:identifier];
    }
    [_downloadPauseYieldTokensByIdentifier removeObjectForKey:identifier];
    [self _removeSavedCachingInfoForIdentifier:identifier];
    [operation cancel];

    if (!operationWasExecuting) {
        [self _removeTrackedDownloadOperation:operation];
        if (mustInvalidateBackgroundSession) {
            [self _cancelOrphanedBackgroundSession:identifier];
        } else {
            [self _completeBackgroundSessionForIdentifier:identifier];
        }
        [self _automaticRetryOperationDidFinishWithIdentifier:identifier];
        [self _startNextDownloadOperations];
        [self _finishDownloadBatchAfterOperation:operation];
        [self coalescedPerformSelector:@selector(_postDidUpdateNotification) afterDelay:0.1];
    }
}

- (void)_cancelCachingEpisodeAfterDurableIntent:(CDEpisode*)episode
                            disableAutoDownload:(BOOL)disableAutodownload
{
    [self _removeDownloadDeferredBySubscriptionCleanupForIdentifier:episode.objectHash
                                                 removeNormalDescriptor:YES];
    BOOL hasStreamingCache = [self _hasStreamingCacheForEpisode:episode];
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
    BOOL operationIsFinalizing = operation
        && [_finalizingDownloadOperationIdentifiers containsObject:operation.identifier];
	if (operation && !operationIsFinalizing)  {
        [self _cancelTrackedDownloadOperationAfterDurableIntent:operation];
    } else if (!operationIsFinalizing && !hasStreamingCache && [self isCachingEpisode:episode]) {
        NSString* identifier = episode.objectHash;
        [self willChangeValueForKey:@"cachingEpisodes"];
        [_cachingEpisodes removeObject:episode];
        [self didChangeValueForKey:@"cachingEpisodes"];
        [_cachingEpisodeHashes removeObject:identifier];
        [_downloadQueueRanksByIdentifier removeObjectForKey:identifier];
        [_manuallySuspendedDownloadIdentifiers removeObject:identifier];
        [self _removeSavedCachingInfoForIdentifier:identifier];
        [self _finishDownloadBatchAfterOperation:nil];
        [self coalescedPerformSelector:@selector(_postDidUpdateNotification) afterDelay:0.1];
    }

    if (hasStreamingCache) {
        [self _cancelStreamingCacheForEpisodeAfterDurableIntent:episode disableAutoDownload:disableAutodownload];
        return;
    }

    if (disableAutodownload) {
        [self.cacheHistory setEpisode:episode didAutoDownload:YES completion:^(NSError* error) {
            if (error) ErrLog(@"could not disable auto-download after cancellation: %@", error);
        }];
    }
}

- (BOOL)completeDeferredRestoreCancellationForObjectHash:(NSString*)objectHash episode:(CDEpisode*)episode
{
    NSAssert([NSThread isMainThread], @"Deferred restore cancellation must finish on the main thread");
    if (objectHash.length == 0) return YES;

    CACHE_OPERATION_CLASS *operation = _downloadOperationsByIdentifier[objectHash];
    BOOL cancelledStreamingWithoutEpisode = NO;
    BOOL episodeMatchesOwner = [episode.objectHash isEqualToString:objectHash];
    CDEpisode *ownerEpisode = episodeMatchesOwner ? episode : nil;
    CDEpisode *operationEpisode = [operation.userInfo isKindOfClass:[CDEpisode class]] ? operation.userInfo : nil;
    if (!ownerEpisode && [operationEpisode.objectHash isEqualToString:objectHash]) {
        ownerEpisode = operationEpisode;
    }

    [self _removeDownloadDeferredBySubscriptionCleanupForIdentifier:objectHash
                                                 removeNormalDescriptor:YES];
    if (ownerEpisode) {
        [self _cancelCachingEpisodeAfterDurableIntent:ownerEpisode disableAutoDownload:NO];
    } else {
        [self _cancelTrackedDownloadOperationAfterDurableIntent:operation];
        NSString *streamingLeaseToken = _streamingCacheLeaseTokensByIdentifier[objectHash];
        if (streamingLeaseToken.length > 0) {
            cancelledStreamingWithoutEpisode = YES;
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidCancelStreamingCacheEpisodeNotification
                                                                object:self
                                                              userInfo:@{
                                                                  @"episodeHash" : objectHash,
                                                                  @"leaseToken" : streamingLeaseToken,
                                                              }];
            [_streamingCacheLeaseTokensByIdentifier removeObjectForKey:objectHash];
            [_streamingCacheProgresses removeObjectForKey:objectHash];
            [self _removeStreamingCacheBytesForIdentifier:objectHash];
            [self _postDidUpdateNotification];
            [self _invalidateDownloadedBytesAndRecalculate];
        }
    }

    [self _removeCachingEpisodeForIdentifierIfUnowned:objectHash];
    BOOL ownerRemoved = !_downloadOperationsByIdentifier[objectHash]
        && !_streamingCacheLeaseTokensByIdentifier[objectHash]
        && !_subscriptionCleanupDeferredDownloadInfosByIdentifier[objectHash]
        && ![_cachingEpisodeHashes containsObject:objectHash];
    if (cancelledStreamingWithoutEpisode && ownerRemoved && ![self isCaching]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidEndCachingNotification object:self];
    }
    return ownerRemoved;
}

- (void) cancelStreamingCacheForEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload
{
    NSString *identifier = episode.objectHash;
    if (identifier.length == 0 || ![self _hasStreamingCacheForEpisode:episode]) return;
    if (![InstacastBackupImporter ownsDeferredDownloadWithObjectHash:identifier]) {
        [self _cancelStreamingCacheForEpisodeAfterDurableIntent:episode disableAutoDownload:disableAutodownload];
        return;
    }
    [InstacastBackupImporter prepareForDeferredDownloadCancellation:identifier
                                                            feedURL:episode.feed.sourceURL.absoluteString ?: @""
                                                         episodeGUID:episode.guid ?: @""
                                                          completion:^(NSError *error) {
        if (error) {
            ErrLog(@"could not persist deferred streaming-download cancellation: %@", error);
            return;
        }
        [self _cancelStreamingCacheForEpisodeAfterDurableIntent:episode disableAutoDownload:disableAutodownload];
        [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
    }];
}

- (void)_cancelStreamingCacheForEpisodeAfterDurableIntent:(CDEpisode*)episode
                                       disableAutoDownload:(BOOL)disableAutodownload
{
    NSString* key = [self _streamingCacheKeyForEpisode:episode];
    if (!key) {
        return;
    }

    if (disableAutodownload) {
        [self.cacheHistory setEpisode:episode didAutoDownload:YES completion:^(NSError* error) {
            if (error) ErrLog(@"could not disable auto-download after streaming cancellation: %@", error);
        }];
    }

    NSString* leaseToken = _streamingCacheLeaseTokensByIdentifier[key];
    if (leaseToken.length == 0) {
        return;
    }

    [_streamingCacheLeaseTokensByIdentifier removeObjectForKey:key];
    [_streamingCacheProgresses removeObjectForKey:key];
    [self _removeCachingEpisodeForIdentifierIfUnowned:key];

    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidCancelStreamingCacheEpisodeNotification
                                                        object:self
                                                      userInfo:@{
                                                          @"episode" : episode,
                                                          @"episodeHash" : key,
                                                          @"leaseToken" : leaseToken,
                                                      }];
    [self _removeStreamingCacheBytesForIdentifier:key];
    [self _postDidUpdateNotification];
    [self autoClearAndMakeRoomForBytes:0 automatic:YES];
    if (![self isCaching]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidEndCachingNotification object:self];
    }
}

- (void) cancelCachingFeed:(CDFeed*)feed
{
    if (!feed) return;
    [self cancelCachingFeeds:@[feed] completion:^(NSError* error) {
        if (error) ErrLog(@"could not clear failed downloads for feed: %@", error);
    }];
}

- (void)cancelCachingFeeds:(NSArray<CDFeed*>*)feeds
                  completion:(void (^)(NSError* error))completion
{
    [self _cancelCachingFeeds:feeds
 preserveSubscriptionCleanupDeferredStarts:NO
                  completion:completion];
}

- (void)_cancelCachingFeeds:(NSArray<CDFeed*>*)feeds
preserveSubscriptionCleanupDeferredStarts:(BOOL)preserveDeferredStarts
                  completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _cancelCachingFeeds:feeds
         preserveSubscriptionCleanupDeferredStarts:preserveDeferredStarts
                          completion:completion];
        });
        return;
    }

    feeds = [NSOrderedSet orderedSetWithArray:feeds ?: @[]].array;
    if (feeds.count == 0) {
        if (completion) completion(nil);
        return;
    }

    NSError* databaseUnavailableError = [NSError errorWithDomain:@"CacheManager"
                                                             code:53
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Podcast download data could not be accessed for cleanup. Please restart InstacastPlus and try again.".ls}];
    NSMutableArray<NSURL*>* feedObjectURIs = [NSMutableArray arrayWithCapacity:feeds.count];
    for (CDFeed* feed in feeds) {
        if (feed.objectID && !feed.objectID.isTemporaryID) {
            [feedObjectURIs addObject:feed.objectID.URIRepresentation];
        }
    }
    if (feedObjectURIs.count != feeds.count) {
        if (completion) completion(databaseUnavailableError);
        return;
    }

    NSSet<CDFeed*>* feedSet = [NSSet setWithArray:feeds];
    NSMutableSet<NSString*>* handledIdentifiers = [NSMutableSet set];
    for (CDEpisode* episode in [_cachingEpisodes copy]) {
        if ([feedSet containsObject:episode.feed]) {
            NSString* identifier = episode.objectHash;
            if (identifier.length > 0) [handledIdentifiers addObject:identifier];
            if (preserveDeferredStarts &&
                _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier]) {
                CACHE_OPERATION_CLASS* operation = _downloadOperationsByIdentifier[identifier];
                if (operation) {
                    [self _cancelTrackedDownloadOperationAfterDurableIntent:operation];
                }
                if ([self _hasStreamingCacheForEpisode:episode]) {
                    [self _cancelStreamingCacheForEpisodeAfterDurableIntent:episode
                                                         disableAutoDownload:NO];
                }
                continue;
            }
            [self cancelCachingEpisode:episode disableAutoDownload:NO];
        }
    }
    if (!preserveDeferredStarts) {
        for (NSString* identifier in
             [_subscriptionCleanupDeferredDownloadEpisodesByIdentifier.allKeys copy]) {
            CDEpisode* episode = _subscriptionCleanupDeferredDownloadEpisodesByIdentifier[identifier];
            if (![handledIdentifiers containsObject:identifier]
                && [feedSet containsObject:episode.feed]) {
                [self cancelCachingEpisode:episode disableAutoDownload:NO];
            }
        }
    }

    NSSet<NSString*>* immutableInMemoryFailedEpisodeHashes = [_failedDownloadEpisodeHashes copy];
    NSArray<NSURL*>* immutableFeedObjectURIs = [feedObjectURIs copy];
    dispatch_async(_failedDownloadPersistenceQueue, ^{
        [self _migrateLegacyFailedDownloadsNow];
        NSFileManager* fileManager = [[NSFileManager alloc] init];
        NSString* directoryPath = [self _failedDownloadsStateDirectoryPath];
        NSError* listingError = nil;
        NSArray<NSString*>* filenames = [fileManager contentsOfDirectoryAtPath:directoryPath error:&listingError];
        if (!filenames && ICCacheFileErrorMeansMissing(listingError)) {
            filenames = @[];
            listingError = nil;
        }
        if (listingError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(databaseUnavailableError);
            });
            return;
        }

        NSMutableSet<NSString*>* persistedFailedEpisodeHashes = [NSMutableSet set];
        NSError* firstReadError = nil;
        for (NSString* filename in filenames) {
            if (![filename.pathExtension isEqualToString:@"failed-download"]) {
                continue;
            }
            NSString* path = [directoryPath stringByAppendingPathComponent:filename];
            NSError* readError = nil;
            NSData* data = [NSData dataWithContentsOfFile:path options:0 error:&readError];
            if (!data) {
                if (!ICCacheFileErrorMeansMissing(readError) && !firstReadError) {
                    firstReadError = readError;
                }
                continue;
            }
            NSError* propertyListError = nil;
            NSDictionary* metadata = [NSPropertyListSerialization propertyListWithData:data
                                                                                options:NSPropertyListImmutable
                                                                                 format:NULL
                                                                                  error:&propertyListError];
            if (![metadata isKindOfClass:[NSDictionary class]] || propertyListError) {
                continue;
            }
            NSString* episodeHash = metadata[@"episodeHash"];
            if (episodeHash.length > 0) {
                [persistedFailedEpisodeHashes addObject:episodeHash];
            }
        }
        if (firstReadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(databaseUnavailableError);
            });
            return;
        }

        NSMutableSet<NSString*>* candidateFailedEpisodeHashes = [NSMutableSet setWithSet:immutableInMemoryFailedEpisodeHashes];
        [candidateFailedEpisodeHashes unionSet:persistedFailedEpisodeHashes];
        if (candidateFailedEpisodeHashes.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil);
            });
            return;
        }

        NSArray<NSString*>* immutableCandidateFailedEpisodeHashes = candidateFailedEpisodeHashes.allObjects;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSManagedObjectContext* selectionContext = [DMANAGER newICloudSyncBackgroundContext];
            if (!selectionContext) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(databaseUnavailableError);
                });
                return;
            }
            [selectionContext performBlock:^{
                NSError* selectionError = nil;
                NSPersistentStoreCoordinator* selectionCoordinator = selectionContext.persistentStoreCoordinator;
                NSMutableArray<CDFeed*>* backgroundFeeds = [NSMutableArray arrayWithCapacity:immutableFeedObjectURIs.count];
                for (NSURL* feedObjectURI in immutableFeedObjectURIs) {
                    NSManagedObjectID* feedObjectID = [selectionCoordinator managedObjectIDForURIRepresentation:feedObjectURI];
                    if (!feedObjectID) {
                        selectionError = databaseUnavailableError;
                        break;
                    }
                    CDFeed* feed = (CDFeed*)[selectionContext existingObjectWithID:feedObjectID error:&selectionError];
                    if (!feed || selectionError) break;
                    [backgroundFeeds addObject:feed];
                }

                NSMutableSet<NSString*>* matchedEpisodeHashes = [NSMutableSet set];
                const NSUInteger failedDownloadSelectionHashBatchSize = 400;
                for (NSUInteger offset = 0;
                     !selectionError && offset < immutableCandidateFailedEpisodeHashes.count;
                     offset += failedDownloadSelectionHashBatchSize) {
                    NSRange hashRange = NSMakeRange(offset,
                                                    MIN(failedDownloadSelectionHashBatchSize,
                                                        immutableCandidateFailedEpisodeHashes.count - offset));
                    NSArray<NSString*>* hashBatch = [immutableCandidateFailedEpisodeHashes subarrayWithRange:hashRange];
                    NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                    request.predicate = [NSPredicate predicateWithFormat:@"feed IN %@ AND objectHash IN %@",
                                         backgroundFeeds,
                                         hashBatch];
                    request.resultType = NSDictionaryResultType;
                    request.propertiesToFetch = @[@"objectHash"];
                    request.returnsDistinctResults = YES;
                    NSArray<NSDictionary*>* rows = [selectionContext executeFetchRequest:request error:&selectionError];
                    for (NSDictionary* row in rows) {
                        NSString* episodeHash = row[@"objectHash"];
                        if (episodeHash.length > 0) [matchedEpisodeHashes addObject:episodeHash];
                    }
                }

                NSSet<NSString*>* immutableMatchedEpisodeHashes = [matchedEpisodeHashes copy];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (selectionError) {
                        if (completion) completion(selectionError);
                        return;
                    }
                    [self _clearDownloadErrorsForEpisodeHashes:immutableMatchedEpisodeHashes completion:completion];
                });
            }];
        });
    });
}


- (BOOL) isCachingSuspended
{
	if (self.suspended) {
        return YES;
    }
    
    NSArray* operations = [_downloadOperationsByIdentifier.allValues copy];
	for(CACHE_OPERATION_CLASS* operation in operations) {
        if (operation.suspended) {
            return YES;
        }
	}
    
    return NO;
}

- (void) pauseCaching
{
    self.suspended = YES;
    [USER_DEFAULTS setBool:YES forKey:ICDownloadQueueSuspended];
    
	NSArray* operations = [_downloadOperationsByIdentifier.allValues copy];
	for(CACHE_OPERATION_CLASS* operation in operations) {
        operation.suspended = YES;
	}
    
    _rateDate = nil;
    _rateBytes = 0LL;
}

- (void) pauseCachingEpisode:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation) {
		[_manuallySuspendedDownloadIdentifiers addObject:operation.identifier];
		[self _persistCachingOperation:operation];
		operation.suspended = YES;
		[self _requestDownloadOperationYield:operation];
	}
    
    _rateDate = nil;
    _rateBytes = 0LL;
}

- (void) resumeCaching
{
    self.suspended = NO;
    [USER_DEFAULTS setBool:NO forKey:ICDownloadQueueSuspended];
	NSArray* operations = [_downloadOperationsByIdentifier.allValues copy];
	for(CACHE_OPERATION_CLASS* operation in operations) {
		BOOL manuallySuspended = [_manuallySuspendedDownloadIdentifiers containsObject:operation.identifier];
        CDEpisode* episode = [operation.userInfo isKindOfClass:[CDEpisode class]]
            ? operation.userInfo : nil;
		operation.suspended = ![self _networkAllowsDownloadOperation:operation] || manuallySuspended
            || [self _subscriptionCleanupBlocksEpisode:episode];
    }
    [self _startNextDownloadOperations];
    [self _drainPendingAutomaticRetries];
}

- (void) resumeCachingEpisode:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation) {
		[_manuallySuspendedDownloadIdentifiers removeObject:operation.identifier];
		[self _persistCachingOperation:operation];
		operation.suspended = self.suspended || ![self _networkAllowsDownloadOperation:operation]
            || [self _subscriptionCleanupBlocksEpisode:episode];
		[self _startNextDownloadOperations];
	}
}

- (NSInteger) numberOfCachedEpisodes
{
    return [_cachedEpisodes count];
}

- (BOOL)isCacheIndexReady
{
    return _cacheIndexReady;
}

- (BOOL)isReadyForAutomaticDownloads
{
    return _cacheIndexReady && self.cacheHistory.isLoaded && _cachingEpisodesRestored;
}


- (NSArray*) cachedEpisodes
{
    return [_cachedEpisodes allObjects];
}

- (NSSet<NSString*>*) cachedEpisodeObjectHashes
{
    __block NSSet<NSString*>* hashes = nil;
    void (^snapshot)(void) = ^{
        NSMutableSet<NSString*>* result = [[NSMutableSet alloc] initWithCapacity:self->_cachedEpisodes.count];
        for (CDEpisode* episode in self->_cachedEpisodes) {
            if (episode.objectHash.length > 0) {
                [result addObject:episode.objectHash];
            }
        }
        hashes = [result copy];
    };

    if ([NSThread isMainThread]) {
        snapshot();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), snapshot);
    }
    return hashes ?: [NSSet set];
}

+ (NSSet*) keyPathsForValuesAffectingPartiallyCachedEpisodes {
    return [NSSet setWithObjects:@"cachedEpisodes", nil];
}

- (NSArray*) partiallyCachedEpisodes
{
    NSFileManager* fman = [NSFileManager defaultManager];
    
    NSMutableArray* partiallyCachedEpisodes = [[NSMutableArray alloc] init];
    
    NSError* error = nil;
    NSArray* directoryContent = [fman contentsOfDirectoryAtPath:[CacheManager _pathToCache] error:&error];
    if (!error) {
        for(NSString* filename in directoryContent)
        {
            if (![[filename pathExtension] isEqualToString:@"part"]) {
                continue;
            }

            NSString* nameWithoutPartExtension = [filename stringByDeletingPathExtension];
            NSString* nameWithoutMediaExtension = [nameWithoutPartExtension stringByDeletingPathExtension];
            NSString* hash = nil;
            NSRange lastDash = [nameWithoutMediaExtension rangeOfString:@" - " options:NSBackwardsSearch];
            if (lastDash.location != NSNotFound) {
                hash = [nameWithoutMediaExtension substringFromIndex:NSMaxRange(lastDash)];
            } else {
                hash = nameWithoutMediaExtension;
            }
            CDEpisode* episode = [DMANAGER episodeWithObjectHash:hash];
            if (episode) {
                [partiallyCachedEpisodes addObject:episode];
            }
        }
    }
    
    return partiallyCachedEpisodes;
}

- (NSArray*) cachingEpisodes
{
	NSMutableOrderedSet<CDEpisode*>* episodes =
        [NSMutableOrderedSet orderedSetWithArray:_cachingEpisodes];
    NSArray<NSString*>* deferredIdentifiers =
        [_subscriptionCleanupDeferredDownloadInfosByIdentifier.allKeys
            sortedArrayUsingComparator:^NSComparisonResult(NSString* left, NSString* right) {
                NSNumber* leftRank = self->_subscriptionCleanupDeferredDownloadInfosByIdentifier[left][@"queueRank"];
                NSNumber* rightRank = self->_subscriptionCleanupDeferredDownloadInfosByIdentifier[right][@"queueRank"];
                NSComparisonResult rankOrder = [leftRank compare:rightRank];
                return rankOrder == NSOrderedSame ? [left compare:right] : rankOrder;
            }];
    for (NSString* identifier in deferredIdentifiers) {
        CDEpisode* episode = _subscriptionCleanupDeferredDownloadEpisodesByIdentifier[identifier];
        if (episode) [episodes addObject:episode];
    }
	return episodes.array;
}

- (BOOL) canReorderCachingEpisodes
{
    return _subscriptionCleanupDeferredDownloadInfosByIdentifier.count == 0
        && _streamingCacheLeaseTokensByIdentifier.count == 0
        && _cachingEpisodes.count == _downloadOperationsByIdentifier.count;
}

- (NSArray<CDEpisode*>*) failedDownloadEpisodes
{
    return [_failedDownloadEpisodes copy];
}

- (NSString*)_failedDownloadsStatePath
{
    NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]];
    return [dataPath stringByAppendingPathComponent:@"FailedEpisodeDownloads.plist"];
}

- (NSString*)_failedDownloadsStateDirectoryPath
{
    NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]];
    NSString* directoryPath = [DatabaseManager pathToSubfolder:@"FailedEpisodeDownloads" parent:dataPath];
    AddSkipBackupAttributeToFile(directoryPath);
    return directoryPath;
}

- (NSString*)_failedDownloadStatePathForIdentifier:(NSString*)identifier
{
    NSString* directoryPath = [self _failedDownloadsStateDirectoryPath];
    NSString* filename = identifier.length > 0 ? [[identifier MD5Hash] stringByAppendingPathExtension:@"failed-download"] : nil;
    return filename.length > 0 ? [directoryPath stringByAppendingPathComponent:filename] : nil;
}

- (NSError*)_writeFailedDownloadMetadataNow:(NSDictionary*)metadata forIdentifier:(NSString*)identifier
{
    NSString* path = [self _failedDownloadStatePathForIdentifier:identifier];
    if (path.length == 0 || ![metadata isKindOfClass:[NSDictionary class]]) {
        return [NSError errorWithDomain:@"CacheManager"
                                   code:44
                               userInfo:@{NSLocalizedDescriptionKey: @"The failed download state could not be saved.".ls}];
    }
    NSMutableDictionary* storedMetadata = [metadata mutableCopy];
    storedMetadata[@"episodeHash"] = identifier;
    NSError* serializationError = nil;
    NSData* data = [NSPropertyListSerialization dataWithPropertyList:storedMetadata
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&serializationError];
    if (!data) {
        ErrLog(@"could not serialize failed episode download %@: %@", identifier, serializationError);
        return serializationError ?: [NSError errorWithDomain:@"CacheManager"
                                                           code:44
                                                       userInfo:@{NSLocalizedDescriptionKey: @"The failed download state could not be saved.".ls}];
    }
    NSError* writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        ErrLog(@"could not persist failed episode download %@: %@", identifier, writeError);
        return writeError ?: [NSError errorWithDomain:@"CacheManager"
                                                  code:44
                                              userInfo:@{NSLocalizedDescriptionKey: @"The failed download state could not be saved.".ls}];
    }
    AddSkipBackupAttributeToFile(path);
    return nil;
}

- (void)_migrateLegacyFailedDownloadsNow
{
    NSString* legacyPath = [self _failedDownloadsStatePath];
    NSData* data = [NSData dataWithContentsOfFile:legacyPath];
    if (data.length == 0) {
        return;
    }
    NSError* error = nil;
    NSDictionary* legacyMetadata = [NSPropertyListSerialization propertyListWithData:data
                                                                              options:NSPropertyListImmutable
                                                                               format:NULL
                                                                                error:&error];
    if (![legacyMetadata isKindOfClass:[NSDictionary class]]) {
        ErrLog(@"could not migrate legacy failed downloads: %@", error);
        [[NSFileManager defaultManager] removeItemAtPath:legacyPath error:nil];
        return;
    }

    BOOL migratedAll = YES;
    NSFileManager* fileManager = [NSFileManager defaultManager];
    for (NSString* identifier in legacyMetadata) {
        NSDictionary* metadata = legacyMetadata[identifier];
        if (identifier.length == 0 || ![metadata isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString* destinationPath = [self _failedDownloadStatePathForIdentifier:identifier];
        if (destinationPath.length == 0) {
            migratedAll = NO;
            continue;
        }
        if ([fileManager fileExistsAtPath:destinationPath]) {
            continue;
        }
        if ([self _writeFailedDownloadMetadataNow:metadata forIdentifier:identifier]) {
            migratedAll = NO;
        }
    }
    if (migratedAll) {
        [fileManager removeItemAtPath:legacyPath error:nil];
    }
}

- (void)_persistFailedDownloadMetadata:(NSDictionary*)metadata
                          forIdentifier:(NSString*)identifier
                             completion:(void (^)(NSError* error))completion
{
    NSDictionary* copiedMetadata = [metadata copy];
    NSString* copiedIdentifier = [identifier copy];
    dispatch_async(_failedDownloadPersistenceQueue, ^{
        [self _migrateLegacyFailedDownloadsNow];
        NSError* persistenceError = [self _writeFailedDownloadMetadataNow:copiedMetadata
                                                              forIdentifier:copiedIdentifier];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(persistenceError);
            });
        }
    });
}

- (void)_deletePersistedFailedDownloadForIdentifier:(NSString*)identifier
                                          completion:(void (^)(NSError* error))completion
{
    NSString* copiedIdentifier = [identifier copy];
    dispatch_async(_failedDownloadPersistenceQueue, ^{
        [self _migrateLegacyFailedDownloadsNow];
        NSString* path = [self _failedDownloadStatePathForIdentifier:copiedIdentifier];
        NSError* deletionError = nil;
        if (path.length > 0) {
            BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:path error:&deletionError];
            if (removed || ICCacheFileErrorMeansMissing(deletionError)) {
                deletionError = nil;
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(deletionError);
            });
        }
    });
}

- (void)_deletePersistedFailedDownloadsForIdentifiers:(NSArray<NSString*>*)identifiers
                                            completion:(void (^)(NSSet<NSString*>* successfulIdentifiers, NSError* error))completion
{
    NSArray<NSString*>* copiedIdentifiers = [identifiers copy];
    dispatch_async(_failedDownloadPersistenceQueue, ^{
        [self _migrateLegacyFailedDownloadsNow];
        NSFileManager* fileManager = [[NSFileManager alloc] init];
        NSString* directoryPath = [self _failedDownloadsStateDirectoryPath];
        NSMutableDictionary<NSString*, NSString*>* identifiersByPath = [NSMutableDictionary dictionaryWithCapacity:copiedIdentifiers.count];
        NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSetWithCapacity:copiedIdentifiers.count];
        for (NSString* identifier in copiedIdentifiers) {
            NSString* path = [self _failedDownloadStatePathForIdentifier:identifier];
            if (path.length == 0) {
                continue;
            }
            identifiersByPath[path] = identifier;
            [paths addObject:path];
        }

        NSError* firstError = nil;
        NSError* listingError = nil;
        NSArray<NSString*>* filenames = [fileManager contentsOfDirectoryAtPath:directoryPath error:&listingError];
        if (listingError && !ICCacheFileErrorMeansMissing(listingError)) {
            firstError = listingError;
        }
        for (NSString* filename in filenames) {
            if ([filename.pathExtension isEqualToString:@"failed-download"]) {
                [paths addObject:[directoryPath stringByAppendingPathComponent:filename]];
            }
        }

        NSMutableSet<NSString*>* successfulIdentifiers = [NSMutableSet setWithArray:copiedIdentifiers];
        for (NSString* path in paths) {
            NSError* deletionError = nil;
            BOOL removed = [fileManager removeItemAtPath:path error:&deletionError];
            if (removed || ICCacheFileErrorMeansMissing(deletionError)) {
                continue;
            }
            NSString* identifier = identifiersByPath[path];
            if (identifier.length > 0) {
                [successfulIdentifiers removeObject:identifier];
            }
            if (!firstError) {
                firstError = deletionError;
            }
        }

        NSError* legacyDeletionError = nil;
        BOOL removedLegacy = [fileManager removeItemAtPath:[self _failedDownloadsStatePath]
                                                     error:&legacyDeletionError];
        if (!removedLegacy && !ICCacheFileErrorMeansMissing(legacyDeletionError)) {
            [successfulIdentifiers removeAllObjects];
            if (!firstError) {
                firstError = legacyDeletionError;
            }
        }

        NSError* publicError = nil;
        if (firstError) {
            publicError = [NSError errorWithDomain:@"CacheManager"
                                              code:46
                                          userInfo:@{
                                              NSLocalizedDescriptionKey: @"Download errors could not all be removed. Please try again.".ls,
                                              NSUnderlyingErrorKey: firstError,
                                          }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion([successfulIdentifiers copy], publicError);
            }
        });
    });
}

- (void)_deletePersistedFailedDownloadFilesForIdentifiers:(NSArray<NSString*>*)identifiers
                                                completion:(void (^)(NSSet<NSString*>* successfulIdentifiers, NSError* error))completion
{
    NSArray<NSString*>* copiedIdentifiers = [identifiers copy];
    dispatch_async(_failedDownloadPersistenceQueue, ^{
        [self _migrateLegacyFailedDownloadsNow];
        NSFileManager* fileManager = [[NSFileManager alloc] init];
        NSMutableSet<NSString*>* successfulIdentifiers = [NSMutableSet set];
        NSString* directoryPath = [self _failedDownloadsStateDirectoryPath];
        NSError* firstError = directoryPath.length > 0 ? nil : [NSError errorWithDomain:NSCocoaErrorDomain
                                                                                    code:NSFileWriteUnknownError
                                                                                userInfo:nil];
        for (NSString* identifier in copiedIdentifiers) {
            if (directoryPath.length == 0) continue;
            NSString* filename = [[identifier MD5Hash] stringByAppendingPathExtension:@"failed-download"];
            NSString* path = [directoryPath stringByAppendingPathComponent:filename];
            NSError* deletionError = nil;
            BOOL removed = [fileManager removeItemAtPath:path error:&deletionError];
            if (removed || ICCacheFileErrorMeansMissing(deletionError)) {
                [successfulIdentifiers addObject:identifier];
            } else if (!firstError) {
                firstError = deletionError;
            }
        }

        NSError* publicError = nil;
        if (firstError) {
            publicError = [NSError errorWithDomain:@"CacheManager"
                                              code:46
                                          userInfo:@{
                                              NSLocalizedDescriptionKey: @"Download errors could not all be removed. Please try again.".ls,
                                              NSUnderlyingErrorKey: firstError,
                                          }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion([successfulIdentifiers copy], publicError);
        });
    });
}

- (void)_restoreFailedDownloads
{
    NSUInteger restoreGeneration = _failedDownloadRestoreGeneration;
    dispatch_async(_failedDownloadPersistenceQueue, ^{
        [self _migrateLegacyFailedDownloadsNow];
        NSString* directoryPath = [self _failedDownloadsStateDirectoryPath];
        NSArray<NSString*>* filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directoryPath error:nil];
        NSMutableDictionary<NSString*, NSDictionary*>* savedMetadata = [NSMutableDictionary dictionary];
        for (NSString* filename in filenames) {
            if (![filename.pathExtension isEqualToString:@"failed-download"]) {
                continue;
            }
            NSString* path = [directoryPath stringByAppendingPathComponent:filename];
            NSData* data = [NSData dataWithContentsOfFile:path];
            NSError* error = nil;
            id propertyList = [NSPropertyListSerialization propertyListWithData:data
                                                                         options:NSPropertyListMutableContainers
                                                                          format:NULL
                                                                           error:&error];
            if (![propertyList isKindOfClass:[NSDictionary class]] || error) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                continue;
            }
            NSMutableDictionary* metadata = [propertyList mutableCopy];
            NSString* identifier = metadata[@"episodeHash"];
            if (identifier.length == 0) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                continue;
            }
            [metadata removeObjectForKey:@"episodeHash"];
            savedMetadata[identifier] = metadata;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (restoreGeneration != self->_failedDownloadRestoreGeneration) {
                return;
            }
            NSArray<NSString*>* identifiers = savedMetadata.allKeys;
            NSArray<CDEpisode*>* episodes = identifiers.count > 0 ? [DMANAGER episodesWithObjectHashes:identifiers] : @[];
            NSMutableDictionary<NSString*, CDEpisode*>* episodesByHash = [NSMutableDictionary dictionaryWithCapacity:episodes.count];
            for (CDEpisode* episode in episodes) {
                if (episode.objectHash.length > 0) {
                    episodesByHash[episode.objectHash] = episode;
                }
            }

            NSMutableArray<CDEpisode*>* restoredEpisodes = [NSMutableArray array];
            for (NSString* episodeHash in savedMetadata) {
                CDEpisode* episode = episodesByHash[episodeHash];
                if (!episode || [self episodeIsCached:episode]) {
                    [self _deletePersistedFailedDownloadForIdentifier:episodeHash completion:nil];
                    continue;
                }
                if (self->_failedDownloadMutationGenerationsByEpisodeHash[episodeHash]) {
                    continue;
                }
                if (self->_failedDownloadMetadataByEpisodeHash[episodeHash]) {
                    continue;
                }
                NSDictionary* metadata = savedMetadata[episodeHash];
                NSString* domain = metadata[@"errorDomain"] ?: @"ICCacheOperationErrorDomain";
                NSInteger code = [metadata[@"errorCode"] integerValue];
                NSString* description = metadata[@"errorDescription"] ?: @"The episode download could not be completed.".ls;
                self->_downloadErrorsByEpisodeHash[episodeHash] = [NSError errorWithDomain:domain
                                                                                       code:code
                                                                                   userInfo:@{NSLocalizedDescriptionKey: description}];
                self->_failedDownloadMetadataByEpisodeHash[episodeHash] = metadata;
                if (![self->_failedDownloadEpisodeHashes containsObject:episodeHash]) {
                    [self->_failedDownloadEpisodeHashes addObject:episodeHash];
                    [restoredEpisodes addObject:episode];
                }
            }
            if (restoredEpisodes.count > 0) {
                [self willChangeValueForKey:@"failedDownloadEpisodes"];
                [self->_failedDownloadEpisodes addObjectsFromArray:restoredEpisodes];
                [self didChangeValueForKey:@"failedDownloadEpisodes"];
            }
            [self retryFailedAutomaticDownloadsIfPossible];
        });
    });
}

- (NSError*) downloadErrorForEpisode:(CDEpisode*)episode
{
    if (episode.objectHash.length == 0) {
        return nil;
    }
    return _downloadErrorsByEpisodeHash[episode.objectHash];
}

- (void) clearDownloadErrorForEpisode:(CDEpisode*)episode
{
    [self clearDownloadErrorForEpisode:episode completion:nil];
}

- (void) clearDownloadErrorForEpisode:(CDEpisode*)episode
                            completion:(void (^)(NSError* error))completion
{
    NSString* episodeHash = episode.objectHash;
    if (episodeHash.length == 0) {
        if (completion) completion(nil);
        return;
    }
    [_pendingAutomaticRetryEpisodeHashes removeObject:episodeHash];
    [_automaticRetrySuppressedEpisodeHashes addObject:episodeHash];
    _failedDownloadMutationGeneration += 1;
    NSNumber* mutationGeneration = @(_failedDownloadMutationGeneration);
    _failedDownloadMutationGenerationsByEpisodeHash[episodeHash] = mutationGeneration;
    [self _deletePersistedFailedDownloadForIdentifier:episodeHash completion:^(NSError* error) {
        if (error) {
            if ([self->_failedDownloadMutationGenerationsByEpisodeHash[episodeHash] isEqual:mutationGeneration]) {
                [self->_automaticRetrySuppressedEpisodeHashes removeObject:episodeHash];
            }
            if (completion) completion(error);
            return;
        }
        if (![self->_failedDownloadMutationGenerationsByEpisodeHash[episodeHash] isEqual:mutationGeneration]) {
            NSError* conflictError = [NSError errorWithDomain:@"CacheManager"
                                                          code:45
                                                      userInfo:@{NSLocalizedDescriptionKey: @"The failed download state changed while it was being removed. Try again.".ls}];
            if (completion) completion(conflictError);
            return;
        }

        if ([self->_failedDownloadEpisodeHashes containsObject:episodeHash]) {
            [self willChangeValueForKey:@"failedDownloadEpisodes"];
            for (CDEpisode* failedEpisode in [self->_failedDownloadEpisodes copy]) {
                if ([failedEpisode.objectHash isEqualToString:episodeHash]) {
                    [self->_failedDownloadEpisodes removeObject:failedEpisode];
                }
            }
            [self->_failedDownloadEpisodeHashes removeObject:episodeHash];
            [self didChangeValueForKey:@"failedDownloadEpisodes"];
        }
        [self->_downloadErrorsByEpisodeHash removeObjectForKey:episodeHash];
        [self->_failedDownloadMetadataByEpisodeHash removeObjectForKey:episodeHash];
        [self->_failedDownloadMutationGenerationsByEpisodeHash removeObjectForKey:episodeHash];
        [self->_automaticRetrySuppressedEpisodeHashes removeObject:episodeHash];
        if (completion) completion(nil);
    }];
}

- (void) clearDownloadErrorsForEpisodes:(NSArray<CDEpisode*>*)episodes
                              completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearDownloadErrorsForEpisodes:episodes completion:completion];
        });
        return;
    }

    NSMutableSet<NSString*>* identifiers = [NSMutableSet setWithCapacity:episodes.count];
    for (CDEpisode* episode in episodes) {
        if (episode.objectHash.length > 0) [identifiers addObject:episode.objectHash];
    }
    [self _clearDownloadErrorsForEpisodeHashes:identifiers completion:completion];
}

- (void)_clearDownloadErrorsForEpisodeHashes:(NSSet<NSString*>*)episodeHashes
                                    completion:(void (^)(NSError* error))completion
{
    NSAssert([NSThread isMainThread], @"Failed-download state must be mutated on the main thread");
    NSSet<NSString*>* identifiers = [episodeHashes copy] ?: [NSSet set];
    if (identifiers.count == 0) {
        if (completion) completion(nil);
        return;
    }

    _failedDownloadMutationGeneration += 1;
    NSNumber* clearGeneration = @(_failedDownloadMutationGeneration);
    NSMutableDictionary<NSString*, NSNumber*>* mutationGenerationsByIdentifier = [NSMutableDictionary dictionaryWithCapacity:identifiers.count];
    for (NSString* identifier in identifiers) {
        _failedDownloadMutationGenerationsByEpisodeHash[identifier] = clearGeneration;
        mutationGenerationsByIdentifier[identifier] = clearGeneration;
        [_pendingAutomaticRetryEpisodeHashes removeObject:identifier];
        [_automaticRetrySuppressedEpisodeHashes addObject:identifier];
    }

    [self _deletePersistedFailedDownloadFilesForIdentifiers:identifiers.allObjects
                                                 completion:^(NSSet<NSString*>* successfulIdentifiers, NSError* error) {
        NSMutableSet<NSString*>* identifiersToRemove = [NSMutableSet set];
        for (NSString* identifier in successfulIdentifiers) {
            NSNumber* mutationGeneration = mutationGenerationsByIdentifier[identifier];
            if (mutationGeneration &&
                [self->_failedDownloadMutationGenerationsByEpisodeHash[identifier] isEqual:mutationGeneration]) {
                [identifiersToRemove addObject:identifier];
            }
        }

        if (identifiersToRemove.count > 0) {
            BOOL removesVisibleEpisodes = [self->_failedDownloadEpisodeHashes intersectsSet:identifiersToRemove];
            if (removesVisibleEpisodes) {
                [self willChangeValueForKey:@"failedDownloadEpisodes"];
                for (CDEpisode* failedEpisode in [self->_failedDownloadEpisodes copy]) {
                    if ([identifiersToRemove containsObject:failedEpisode.objectHash]) {
                        [self->_failedDownloadEpisodes removeObject:failedEpisode];
                    }
                }
                [self didChangeValueForKey:@"failedDownloadEpisodes"];
            }
            [self->_failedDownloadEpisodeHashes minusSet:identifiersToRemove];
            for (NSString* identifier in identifiersToRemove) {
                [self->_downloadErrorsByEpisodeHash removeObjectForKey:identifier];
                [self->_failedDownloadMetadataByEpisodeHash removeObjectForKey:identifier];
                [self->_failedDownloadMutationGenerationsByEpisodeHash removeObjectForKey:identifier];
            }
        }
        for (NSString* identifier in identifiers) {
            if ([identifiersToRemove containsObject:identifier] ||
                [self->_failedDownloadMutationGenerationsByEpisodeHash[identifier] isEqual:mutationGenerationsByIdentifier[identifier]]) {
                [self->_automaticRetrySuppressedEpisodeHashes removeObject:identifier];
            }
        }
        if (completion) completion(error);
    }];
}

- (void) clearAllDownloadErrors
{
    [self clearAllDownloadErrorsWithCompletion:nil];
}

- (void) clearAllDownloadErrorsWithCompletion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearAllDownloadErrorsWithCompletion:completion];
        });
        return;
    }

    _failedDownloadRestoreGeneration += 1;
    _failedDownloadMutationGeneration += 1;
    NSNumber* clearGeneration = @(_failedDownloadMutationGeneration);
    NSMutableSet<NSString*>* identifiers = [NSMutableSet setWithSet:_failedDownloadEpisodeHashes];
    [identifiers addObjectsFromArray:_downloadErrorsByEpisodeHash.allKeys];
    [identifiers addObjectsFromArray:_failedDownloadMetadataByEpisodeHash.allKeys];
    NSMutableDictionary<NSString*, NSNumber*>* mutationGenerationsByIdentifier = [NSMutableDictionary dictionaryWithCapacity:identifiers.count];
    _automaticRetryScanInProgress = NO;
    _automaticRetryRescanRequested = NO;
    _automaticRetryScanCursor = 0;
    _automaticRetryNextWakeTimestamp = 0;
    [self _cancelAutomaticRetryWake];
    [_pendingAutomaticRetryEpisodeHashes removeAllObjects];
    for (NSString* identifier in identifiers) {
        _failedDownloadMutationGenerationsByEpisodeHash[identifier] = clearGeneration;
        mutationGenerationsByIdentifier[identifier] = clearGeneration;
        [_automaticRetrySuppressedEpisodeHashes addObject:identifier];
    }

    [self _deletePersistedFailedDownloadsForIdentifiers:identifiers.allObjects
                                              completion:^(NSSet<NSString*>* successfulIdentifiers, NSError* error) {
        NSMutableSet<NSString*>* identifiersToRemove = [NSMutableSet set];
        for (NSString* identifier in successfulIdentifiers) {
            NSNumber* mutationGeneration = mutationGenerationsByIdentifier[identifier];
            if (mutationGeneration &&
                [self->_failedDownloadMutationGenerationsByEpisodeHash[identifier] isEqual:mutationGeneration]) {
                [identifiersToRemove addObject:identifier];
            }
        }

        if (identifiersToRemove.count > 0) {
            BOOL removesVisibleEpisodes = [self->_failedDownloadEpisodeHashes intersectsSet:identifiersToRemove];
            if (removesVisibleEpisodes) {
                [self willChangeValueForKey:@"failedDownloadEpisodes"];
                for (CDEpisode* failedEpisode in [self->_failedDownloadEpisodes copy]) {
                    if ([identifiersToRemove containsObject:failedEpisode.objectHash]) {
                        [self->_failedDownloadEpisodes removeObject:failedEpisode];
                    }
                }
                [self didChangeValueForKey:@"failedDownloadEpisodes"];
            }
            [self->_failedDownloadEpisodeHashes minusSet:identifiersToRemove];
            for (NSString* identifier in identifiersToRemove) {
                [self->_downloadErrorsByEpisodeHash removeObjectForKey:identifier];
                [self->_failedDownloadMetadataByEpisodeHash removeObjectForKey:identifier];
                [self->_failedDownloadMutationGenerationsByEpisodeHash removeObjectForKey:identifier];
            }
        }
        for (NSString* identifier in identifiers) {
            if ([identifiersToRemove containsObject:identifier] ||
                [self->_failedDownloadMutationGenerationsByEpisodeHash[identifier] isEqual:mutationGenerationsByIdentifier[identifier]]) {
                [self->_automaticRetrySuppressedEpisodeHashes removeObject:identifier];
            }
        }
        if (completion) {
            completion(error);
        }
    }];
}

- (BOOL)retryFailedDownloadForEpisode:(CDEpisode*)episode error:(NSError**)error
{
    if (error) *error = nil;
    NSString* identifier = episode.objectHash;
    if (!episode || identifier.length == 0) {
        if (error) *error = [self _downloadStartError:@"The episode cannot be downloaded because its local identifier is missing.".ls];
        return NO;
    }

    NSDictionary* metadata = _failedDownloadMetadataByEpisodeHash[identifier];
    if (!metadata) {
        if (error) *error = [self _downloadStartError:@"The saved download failure details are no longer available. Close Downloads and start the episode download again.".ls];
        return NO;
    }
    if (_clearingAllCache) {
        if (error) *error = [self _downloadStartError:@"The download cannot be retried while downloaded files are being cleared. Wait for the operation to finish and try again.".ls];
        return NO;
    }
    BOOL subscriptionCleanupBlocked = [self _subscriptionCleanupBlocksEpisode:episode];
    if (!subscriptionCleanupBlocked && _cacheDeletionTokensByIdentifier[identifier]) {
        if (error) *error = [self _downloadStartError:@"The download is still being removed. Wait for the operation to finish and try again.".ls];
        return NO;
    }
    if (!subscriptionCleanupBlocked && _cacheImportTokensByIdentifier[identifier]) {
        if (error) *error = [self _downloadStartError:@"A file is currently being imported for this episode. Wait for the import to finish and try again.".ls];
        return NO;
    }
    if (!subscriptionCleanupBlocked && [self episodeIsCached:episode]) {
        [self clearDownloadErrorForEpisode:episode];
        return YES;
    }
    CACHE_OPERATION_CLASS* existingOperation = _downloadOperationsByIdentifier[identifier];
    if (existingOperation.cancelled) {
        if (error) *error = [self _downloadStartError:@"The previous download attempt is still being cancelled. Wait a moment and try again.".ls];
        return NO;
    }

    BOOL automatic = [metadata[@"automatic"] boolValue];
    BOOL overwriteCellularLock = [metadata[@"overwriteCellularLock"] boolValue];
    BOOL preservesConsumedState = [metadata[@"preservesConsumedState"] boolValue];
    if (automatic) {
        _automaticRetryAttemptsByActiveEpisodeHash[identifier] = @([metadata[ICAutomaticDownloadRetryAttemptKey] unsignedIntegerValue]);
    }
    BOOL started = [self _cacheEpisode:episode
                             autoCache:automatic
               overwriteCellularLock:overwriteCellularLock
                  reportsFailureToUser:NO
                              queueRank:nil
                preservesConsumedState:preservesConsumedState
         deferDuringSubscriptionCleanup:YES];
    if (!started) {
        NSError* retryError = [self downloadErrorForEpisode:episode] ?: [self _downloadStartError:@"The episode download could not be started.".ls];
        [_automaticRetryMetadataUpdateEpisodeHashes addObject:identifier];
        [self _recordDownloadError:retryError
                        forEpisode:episode
                         automatic:automatic
            overwriteCellularLock:overwriteCellularLock
              reportsFailureToUser:YES
            preservesConsumedState:preservesConsumedState
                        completion:nil];
        [_automaticRetryMetadataUpdateEpisodeHashes removeObject:identifier];
        [_automaticRetryAttemptsByActiveEpisodeHash removeObjectForKey:identifier];
        if (error) *error = retryError;
    }
    return started;
}

- (NSString*)_automaticRetryClassificationForError:(NSError*)error
{
    if (!error) {
        return ICAutomaticDownloadRetryPermanent;
    }

    NSError* underlyingError = error.userInfo[NSUnderlyingErrorKey];
    NSInteger statusCode = 0;
    if ([error.domain isEqualToString:@"ICCacheOperationErrorDomain"]) {
        if (error.code == 5) {
            return ICAutomaticDownloadRetryTransient;
        }
        if (error.code >= 400 && error.code <= 599) {
            statusCode = error.code;
        }
    }

    if (statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500) {
        return ICAutomaticDownloadRetryTransient;
    }
    if (statusCode >= 400) {
        return ICAutomaticDownloadRetryPermanent;
    }
    if ([error.domain isEqualToString:@"ICCacheOperationErrorDomain"]) {
        return ICAutomaticDownloadRetryPermanent;
    }

    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorTimedOut:
            case NSURLErrorCannotFindHost:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorDNSLookupFailed:
            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorResourceUnavailable:
            case NSURLErrorCannotLoadFromNetwork:
                return ICAutomaticDownloadRetryTransient;

            case NSURLErrorUserAuthenticationRequired:
            case NSURLErrorUserCancelledAuthentication:
            case NSURLErrorBadURL:
            case NSURLErrorUnsupportedURL:
            case NSURLErrorCancelled:
            case NSURLErrorNoPermissionsToReadFile:
                return ICAutomaticDownloadRetryPermanent;

            default:
                return ICAutomaticDownloadRetryPermanent;
        }
    }

    if (underlyingError && underlyingError != error) {
        return [self _automaticRetryClassificationForError:underlyingError];
    }
    return ICAutomaticDownloadRetryPermanent;
}

- (NSTimeInterval)_automaticRetryBackoffForAttempt:(NSUInteger)attempt
{
    NSTimeInterval backoff = ICAutomaticDownloadRetryInitialBackoff;
    NSUInteger remainingDoublings = attempt > 1 ? attempt - 1 : 0;
    while (remainingDoublings > 0 && backoff < ICAutomaticDownloadRetryMaximumBackoff) {
        backoff = MIN(ICAutomaticDownloadRetryMaximumBackoff, backoff * 2.0);
        remainingDoublings -= 1;
    }
    return backoff;
}

- (void)_cancelAutomaticRetryWake
{
    NSAssert([NSThread isMainThread], @"Automatic retry scheduling must stay on the main thread");
    _automaticRetryWakeGeneration += 1;
    if (_automaticRetryWakeSource) {
        dispatch_source_cancel(_automaticRetryWakeSource);
        _automaticRetryWakeSource = nil;
    }
    _automaticRetryWakeTimestamp = 0;
}

- (void)_scheduleAutomaticRetryWakeAtTimestamp:(NSTimeInterval)timestamp
{
    NSAssert([NSThread isMainThread], @"Automatic retry scheduling must stay on the main thread");
    if (timestamp <= 0) {
        return;
    }
    if (timestamp <= [NSDate date].timeIntervalSince1970) {
        [self retryFailedAutomaticDownloadsIfPossible];
        return;
    }
    if (_automaticRetryWakeSource && _automaticRetryWakeTimestamp <= timestamp) {
        return;
    }

    [self _cancelAutomaticRetryWake];
    _automaticRetryWakeTimestamp = timestamp;
    _automaticRetryWakeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    NSUInteger generation = ++_automaticRetryWakeGeneration;

    time_t seconds = (time_t)timestamp;
    long nanoseconds = (long)((timestamp - (NSTimeInterval)seconds) * (NSTimeInterval)NSEC_PER_SEC);
    struct timespec deadline = { .tv_sec = seconds, .tv_nsec = nanoseconds };
    dispatch_source_set_timer(_automaticRetryWakeSource,
                              dispatch_walltime(&deadline, 0),
                              DISPATCH_TIME_FOREVER,
                              NSEC_PER_SEC / 10);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_automaticRetryWakeSource, ^{
        CacheManager* strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_automaticRetryWakeGeneration != generation) {
            return;
        }
        [strongSelf _cancelAutomaticRetryWake];
        [strongSelf retryFailedAutomaticDownloadsIfPossible];
    });
    dispatch_resume(_automaticRetryWakeSource);
}

- (NSDictionary*)_automaticRetryMetadataByAddingMissingState:(NSDictionary*)metadata error:(NSError*)error
{
    if (metadata[ICAutomaticDownloadRetryClassificationKey] &&
        metadata[ICAutomaticDownloadRetryAttemptKey] &&
        metadata[ICAutomaticDownloadRetryNextEligibleTimestampKey]) {
        return metadata;
    }

    NSMutableDictionary* normalizedMetadata = [metadata mutableCopy];
    normalizedMetadata[ICAutomaticDownloadRetryClassificationKey] = [self _automaticRetryClassificationForError:error];
    if (!normalizedMetadata[ICAutomaticDownloadRetryAttemptKey]) {
        normalizedMetadata[ICAutomaticDownloadRetryAttemptKey] = @1;
    }
    if (!normalizedMetadata[ICAutomaticDownloadRetryNextEligibleTimestampKey]) {
        normalizedMetadata[ICAutomaticDownloadRetryNextEligibleTimestampKey] = @0;
    }
    return [normalizedMetadata copy];
}

- (BOOL)_automaticRetryFailureIsStaleForEpisode:(CDEpisode*)episode
{
    CDFeed* feed = episode.feed;
    if (!episode || episode.isDeleted || !feed || feed.isDeleted || !feed.subscribed || feed.parked ||
        episode.consumed || episode.archived || [self episodeIsCached:episode fastLookup:YES] ||
        [self automaticCachingDisabledForEpisode:episode]) {
        return YES;
    }

    BOOL autoCacheAudio = [feed boolForKey:AutoCacheNewAudioEpisodes];
    BOOL autoCacheVideo = [feed boolForKey:AutoCacheNewVideoEpisodes];
    return (!episode.video && !autoCacheAudio) || (episode.video && !autoCacheVideo);
}

- (void)retryFailedAutomaticDownloadsIfPossible
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self retryFailedAutomaticDownloadsIfPossible];
        });
        return;
    }
    if (!_cacheIndexReady || !self.cacheHistory.isLoaded || _clearingAllCache ||
        [self _subscriptionCleanupBlocksEpisode:nil]) {
        return;
    }
    if (_automaticRetryScanInProgress) {
        _automaticRetryRescanRequested = YES;
        return;
    }

    _automaticRetryScanInProgress = YES;
    _automaticRetryRescanRequested = NO;
    _automaticRetryNextWakeTimestamp = 0;
    _automaticRetryScanCursor = _failedDownloadEpisodes.count;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _processAutomaticRetryScanChunk];
    });
}

- (void)_processAutomaticRetryScanChunk
{
    NSAssert([NSThread isMainThread], @"Automatic retry eligibility must be evaluated on the main context");
    if (!_automaticRetryScanInProgress) {
        return;
    }
    if (!_cacheIndexReady || !self.cacheHistory.isLoaded || _clearingAllCache) {
        _automaticRetryScanInProgress = NO;
        _automaticRetryRescanRequested = NO;
        _automaticRetryScanCursor = 0;
        return;
    }

    _automaticRetryScanCursor = MIN(_automaticRetryScanCursor, _failedDownloadEpisodes.count);
    NSUInteger batchLength = MIN(ICAutomaticDownloadRetryScanBatchSize, _automaticRetryScanCursor);
    NSUInteger batchStart = _automaticRetryScanCursor - batchLength;
    NSArray<CDEpisode*>* batch = [_failedDownloadEpisodes subarrayWithRange:NSMakeRange(batchStart, batchLength)];
    _automaticRetryScanCursor = batchStart;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    for (CDEpisode* episode in batch) {
        NSString* identifier = episode.objectHash;
        NSDictionary* metadata = identifier.length > 0 ? _failedDownloadMetadataByEpisodeHash[identifier] : nil;
        if (![metadata[@"automatic"] boolValue] || [_automaticRetrySuppressedEpisodeHashes containsObject:identifier]) {
            continue;
        }
        if ([self _subscriptionCleanupBlocksEpisode:episode]) {
            continue;
        }
        if ([self _automaticRetryFailureIsStaleForEpisode:episode]) {
            [self clearDownloadErrorForEpisode:episode];
            continue;
        }

        NSError* error = _downloadErrorsByEpisodeHash[identifier];
        NSDictionary* normalizedMetadata = [self _automaticRetryMetadataByAddingMissingState:metadata error:error];
        if (normalizedMetadata != metadata) {
            _failedDownloadMetadataByEpisodeHash[identifier] = normalizedMetadata;
            metadata = normalizedMetadata;
        }
        if (![metadata[ICAutomaticDownloadRetryClassificationKey] isEqualToString:ICAutomaticDownloadRetryTransient] ||
            _downloadOperationsByIdentifier[identifier]) {
            continue;
        }
        NSTimeInterval nextEligibleTimestamp = [metadata[ICAutomaticDownloadRetryNextEligibleTimestampKey] doubleValue];
        if (nextEligibleTimestamp > now) {
            if (_automaticRetryNextWakeTimestamp == 0 || nextEligibleTimestamp < _automaticRetryNextWakeTimestamp) {
                _automaticRetryNextWakeTimestamp = nextEligibleTimestamp;
            }
            continue;
        }
        [_pendingAutomaticRetryEpisodeHashes addObject:identifier];
    }

    if (_automaticRetryScanCursor > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _processAutomaticRetryScanChunk];
        });
        return;
    }

    BOOL needsRescan = _automaticRetryRescanRequested;
    _automaticRetryScanInProgress = NO;
    _automaticRetryRescanRequested = NO;
    if (!needsRescan) {
        [self _cancelAutomaticRetryWake];
        [self _scheduleAutomaticRetryWakeAtTimestamp:_automaticRetryNextWakeTimestamp];
    }
    [self _drainPendingAutomaticRetries];
    if (needsRescan) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self retryFailedAutomaticDownloadsIfPossible];
        });
    }
}

- (void)_drainPendingAutomaticRetries
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _drainPendingAutomaticRetries];
        });
        return;
    }
    if (!_cacheIndexReady || !self.cacheHistory.isLoaded || ![self canDownload] || self.suspended || _clearingAllCache) {
        return;
    }
    if (_automaticRetryDrainRemainingCount > 0) {
        _automaticRetryDrainRescanRequested = YES;
    } else {
        _automaticRetryDrainRemainingCount = _pendingAutomaticRetryEpisodeHashes.count;
    }
    [self _continueDrainingPendingAutomaticRetries];
}

- (void)_continueDrainingPendingAutomaticRetries
{
    NSAssert([NSThread isMainThread], @"Automatic retry draining belongs to the main thread");
    _automaticRetryDrainContinuationScheduled = NO;
    if (!_cacheIndexReady || !self.cacheHistory.isLoaded || ![self canDownload]
        || self.suspended || _clearingAllCache) {
        return;
    }

    NSUInteger inspectedCount = 0;
    while (_pendingAutomaticRetryEpisodeHashes.count > 0 &&
           _automaticRetryDrainRemainingCount > 0 &&
           inspectedCount < ICAutomaticDownloadRetryScanBatchSize &&
           _downloadOperationsByIdentifier.count < ICAutomaticDownloadRetryTrackedCapacity &&
           _automaticRetryInFlightEpisodeHashes.count < ICAutomaticDownloadRetryTrackedCapacity) {
        inspectedCount += 1;
        _automaticRetryDrainRemainingCount -= 1;
        NSString* identifier = _pendingAutomaticRetryEpisodeHashes.firstObject;
        [_pendingAutomaticRetryEpisodeHashes removeObjectAtIndex:0];
        if (identifier.length == 0 || [_automaticRetrySuppressedEpisodeHashes containsObject:identifier]) {
            continue;
        }

        NSDictionary* metadata = _failedDownloadMetadataByEpisodeHash[identifier];
        if (![metadata[@"automatic"] boolValue] || _downloadOperationsByIdentifier[identifier]) {
            continue;
        }
        CDEpisode* episode = [DMANAGER episodeWithObjectHash:identifier];
        if (!episode) {
            for (CDEpisode* failedEpisode in [_failedDownloadEpisodes copy]) {
                if ([failedEpisode.objectHash isEqualToString:identifier]) {
                    [self clearDownloadErrorForEpisode:failedEpisode];
                    break;
                }
            }
            continue;
        }
        if ([self _subscriptionCleanupBlocksEpisode:episode]) {
            [_pendingAutomaticRetryEpisodeHashes addObject:identifier];
            continue;
        }
        if ([self _automaticRetryFailureIsStaleForEpisode:episode]) {
            [self clearDownloadErrorForEpisode:episode];
            continue;
        }

        NSError* error = _downloadErrorsByEpisodeHash[identifier];
        metadata = [self _automaticRetryMetadataByAddingMissingState:metadata error:error];
        _failedDownloadMetadataByEpisodeHash[identifier] = metadata;
        if (![metadata[ICAutomaticDownloadRetryClassificationKey] isEqualToString:ICAutomaticDownloadRetryTransient] ||
            [metadata[ICAutomaticDownloadRetryNextEligibleTimestampKey] doubleValue] > [NSDate date].timeIntervalSince1970) {
            continue;
        }

        _automaticRetryAttemptsByActiveEpisodeHash[identifier] = @([metadata[ICAutomaticDownloadRetryAttemptKey] unsignedIntegerValue]);
        [_automaticRetryInFlightEpisodeHashes addObject:identifier];
        BOOL started = [self _cacheEpisode:episode
                                autoCache:YES
                  overwriteCellularLock:[metadata[@"overwriteCellularLock"] boolValue]
                     reportsFailureToUser:NO
                                 queueRank:nil];
        if (!started) {
            [_automaticRetryInFlightEpisodeHashes removeObject:identifier];
            [_automaticRetryAttemptsByActiveEpisodeHash removeObjectForKey:identifier];
        }
    }
    if (_pendingAutomaticRetryEpisodeHashes.count == 0) {
        _automaticRetryDrainRemainingCount = 0;
    }
    if (_automaticRetryDrainRemainingCount > 0 &&
        _downloadOperationsByIdentifier.count < ICAutomaticDownloadRetryTrackedCapacity &&
        _automaticRetryInFlightEpisodeHashes.count < ICAutomaticDownloadRetryTrackedCapacity &&
        !_automaticRetryDrainContinuationScheduled) {
        _automaticRetryDrainContinuationScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _continueDrainingPendingAutomaticRetries];
        });
    } else if (_automaticRetryDrainRemainingCount == 0 &&
               _automaticRetryDrainRescanRequested) {
        _automaticRetryDrainRescanRequested = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _drainPendingAutomaticRetries];
        });
    }
}

- (void)_automaticRetryOperationDidFinishWithIdentifier:(NSString*)identifier
{
    if (identifier.length > 0) {
        [_automaticRetryInFlightEpisodeHashes removeObject:identifier];
        [_automaticRetryAttemptsByActiveEpisodeHash removeObjectForKey:identifier];
    }
    [self _drainPendingAutomaticRetries];
}

- (void)_recordDownloadError:(NSError*)error
                  forEpisode:(CDEpisode*)episode
                   automatic:(BOOL)automatic
      overwriteCellularLock:(BOOL)overwriteCellularLock
        reportsFailureToUser:(BOOL)reportsFailureToUser
      preservesConsumedState:(BOOL)preservesConsumedState
                  completion:(void (^)(NSError* error))completion
{
    if (!episode || episode.objectHash.length == 0 || !error) {
        if (completion) completion(nil);
        return;
    }
    [[ICDiagnosticLogger shared] logEvent:@"episode-download-failed"
                                  message:@"Episoden-Download fehlgeschlagen"
                                 metadata:@{
                                     @"episodeHash": episode.objectHash,
                                     @"automatic": @(automatic),
                                     @"overwriteCellularLock": @(overwriteCellularLock),
                                     @"reportsFailureToUser": @(reportsFailureToUser),
                                     @"preservesConsumedState": @(preservesConsumedState),
                                     @"error": error.localizedDescription ?: @"",
                                 }];
    NSString* episodeHash = episode.objectHash;
    NSDictionary* previousMetadata = _failedDownloadMetadataByEpisodeHash[episodeHash];
    NSUInteger previousAttempt = [previousMetadata[ICAutomaticDownloadRetryAttemptKey] unsignedIntegerValue];
    previousAttempt = MAX(previousAttempt, [_automaticRetryAttemptsByActiveEpisodeHash[episodeHash] unsignedIntegerValue]);
    NSMutableDictionary* metadata = [@{
        @"errorDomain": error.domain ?: @"ICCacheOperationErrorDomain",
        @"errorCode": @(error.code),
        @"errorDescription": error.localizedDescription ?: @"The episode download could not be completed.".ls,
        @"overwriteCellularLock": @(overwriteCellularLock),
        @"automatic": @(automatic),
        @"reportsFailureToUser": @(reportsFailureToUser),
        @"preservesConsumedState": @(preservesConsumedState),
    } mutableCopy];
    if (automatic) {
        BOOL metadataOnlyUpdate = [_automaticRetryMetadataUpdateEpisodeHashes containsObject:episodeHash];
        NSUInteger attempt = metadataOnlyUpdate
            ? MAX((NSUInteger)1, previousAttempt)
            : (previousAttempt == NSUIntegerMax ? NSUIntegerMax : previousAttempt + 1);
        NSString* classification = [self _automaticRetryClassificationForError:error];
        NSTimeInterval nextEligibleTimestamp = 0;
        if ([classification isEqualToString:ICAutomaticDownloadRetryTransient]) {
            BOOL preservesEligibility = metadataOnlyUpdate &&
                [previousMetadata[ICAutomaticDownloadRetryClassificationKey] isEqualToString:classification] &&
                previousMetadata[ICAutomaticDownloadRetryNextEligibleTimestampKey];
            nextEligibleTimestamp = preservesEligibility
                ? [previousMetadata[ICAutomaticDownloadRetryNextEligibleTimestampKey] doubleValue]
                : [NSDate date].timeIntervalSince1970 + [self _automaticRetryBackoffForAttempt:attempt];
        }
        metadata[ICAutomaticDownloadRetryClassificationKey] = classification;
        metadata[ICAutomaticDownloadRetryAttemptKey] = @(attempt);
        metadata[ICAutomaticDownloadRetryNextEligibleTimestampKey] = @(nextEligibleTimestamp);
        if (nextEligibleTimestamp > 0) {
            [self _scheduleAutomaticRetryWakeAtTimestamp:nextEligibleTimestamp];
            if (_automaticRetryScanInProgress) {
                _automaticRetryRescanRequested = YES;
            }
        }
    }

    [_pendingAutomaticRetryEpisodeHashes removeObject:episodeHash];
    [_automaticRetrySuppressedEpisodeHashes removeObject:episodeHash];
    _failedDownloadMutationGeneration += 1;
    _failedDownloadMutationGenerationsByEpisodeHash[episodeHash] = @(_failedDownloadMutationGeneration);
    _downloadErrorsByEpisodeHash[episodeHash] = error;
    _failedDownloadMetadataByEpisodeHash[episodeHash] = [metadata copy];
    if (![_failedDownloadEpisodeHashes containsObject:episodeHash]) {
        [_failedDownloadEpisodeHashes addObject:episodeHash];
        [self willChangeValueForKey:@"failedDownloadEpisodes"];
        [_failedDownloadEpisodes addObject:episode];
        [self didChangeValueForKey:@"failedDownloadEpisodes"];
    }
    [self _persistFailedDownloadMetadata:metadata forIdentifier:episodeHash completion:completion];
}

- (void) reorderCachingEpisodeFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex
{
    if (![self canReorderCachingEpisodes]) {
        return;
    }
    if (fromIndex >= _cachingEpisodes.count || toIndex >= _cachingEpisodes.count || fromIndex == toIndex) {
        return;
    }

    [self willChangeValueForKey:@"cachingEpisodes"];
	id object = [_cachingEpisodes objectAtIndex:fromIndex];
	[_cachingEpisodes removeObject:object];
	[_cachingEpisodes insertObject:object atIndex:toIndex];
    [self didChangeValueForKey:@"cachingEpisodes"];

    CDEpisode* movedEpisode = object;
    NSString* identifier = movedEpisode.objectHash;
    CACHE_OPERATION_CLASS* operation = identifier.length > 0 ? _downloadOperationsByIdentifier[identifier] : nil;
    if (!operation) {
        return;
    }

    NSNumber* previousRank = nil;
    NSNumber* nextRank = nil;
    if (toIndex > 0) {
        CDEpisode* previousEpisode = _cachingEpisodes[toIndex - 1];
        previousRank = _downloadQueueRanksByIdentifier[previousEpisode.objectHash];
    }
    if (toIndex + 1 < _cachingEpisodes.count) {
        CDEpisode* nextEpisode = _cachingEpisodes[toIndex + 1];
        nextRank = _downloadQueueRanksByIdentifier[nextEpisode.objectHash];
    }

    BOOL needsRebalance = NO;
    long long newRank = 0;
    if (!previousRank && nextRank) {
        long long value = nextRank.longLongValue;
        needsRebalance = value < LLONG_MIN + ICCachingEpisodeRankStep;
        newRank = needsRebalance ? 0 : value - ICCachingEpisodeRankStep;
    } else if (previousRank && !nextRank) {
        long long value = previousRank.longLongValue;
        needsRebalance = value > LLONG_MAX - ICCachingEpisodeRankStep;
        newRank = needsRebalance ? 0 : value + ICCachingEpisodeRankStep;
    } else if (previousRank && nextRank) {
        long long lower = previousRank.longLongValue;
        long long upper = nextRank.longLongValue;
        needsRebalance = upper <= lower || upper - lower <= 1;
        newRank = needsRebalance ? 0 : lower + ((upper - lower) / 2);
    }

    if (needsRebalance) {
        long long rank = ICCachingEpisodeRankStep;
        for (CDEpisode* episode in _cachingEpisodes) {
            CACHE_OPERATION_CLASS* queuedOperation = _downloadOperationsByIdentifier[episode.objectHash];
            if (!queuedOperation) {
                continue;
            }
            _downloadQueueRanksByIdentifier[episode.objectHash] = @(rank);
            [self _persistCachingOperation:queuedOperation];
            rank += ICCachingEpisodeRankStep;
        }
        _nextDownloadQueueRank = rank - ICCachingEpisodeRankStep;
    } else {
        _downloadQueueRanksByIdentifier[identifier] = @(newRank);
        _nextDownloadQueueRank = MAX(_nextDownloadQueueRank, newRank);
        [self _persistCachingOperation:operation];
    }

    [self _startNextDownloadOperations];
}

#pragma mark -
#pragma mark CacheOperation Delegate


- (void) _endBackgroundTaskAfterSoundPlayed
{
#if TARGET_OS_IPHONE

#else

    if (_noSystemSleepAssertionID > 0) {
        IOReturn success = IOPMAssertionRelease(_noSystemSleepAssertionID);
        if (success == kIOReturnSuccess) {
            _noSystemSleepAssertionID = 0;
        }
    }
#endif
}


- (void) cacheOperationDidEnd:(CACHE_OPERATION_CLASS*)operation
{
    if (_downloadOperationsByIdentifier[operation.identifier] != operation) {
        [self _completeBackgroundSessionForIdentifier:operation.identifier];
        return;
    }

    BOOL succeeded = ![operation isCancelled] && !operation.failed;

    if ([self _replaceYieldedDownloadOperation:operation]) {
        return;
    }

    NSDictionary* pendingRemoval = _cancelledDownloadRemovalRequestsByIdentifier[operation.identifier];
    if (pendingRemoval) {
        BOOL retryDeferredCancellation = operation.cancelled
            && [InstacastBackupImporter ownsDeferredDownloadWithObjectHash:operation.identifier];
        BOOL queueOwnerRemoved = [self _removeTrackedDownloadOperation:operation];
        [_finalizingDownloadOperationIdentifiers removeObject:operation.identifier];
        NSMutableDictionary* terminalRequest = [pendingRemoval mutableCopy];
        terminalRequest[@"terminalDownloadSucceeded"] = @(succeeded);
        if (succeeded) {
            if (operation.localURL) {
                terminalRequest[@"url"] = operation.localURL;
            }
#if TARGET_OS_IPHONE
            [operation claimFinalizedDownload];
            terminalRequest[@"terminalFileSize"] = @(operation.finalFileSize);
#else
            terminalRequest[@"terminalFileSize"] = @([[[NSFileManager defaultManager] attributesOfItemAtPath:operation.localURL.path error:nil] fileSize]);
#endif
            terminalRequest[@"terminalDownloadedAt"] = [NSDate date];
        }
        _cancelledDownloadRemovalRequestsByIdentifier[operation.identifier] = [terminalRequest copy];
        [self _finishCancelledDownloadRemovalForIdentifier:operation.identifier];
        [self _automaticRetryOperationDidFinishWithIdentifier:operation.identifier];
        [self _startNextDownloadOperations];
        [self _finishDownloadBatchAfterOperation:operation];
        if (queueOwnerRemoved && retryDeferredCancellation) {
            [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
        }
        return;
    }

	if (succeeded)
	{
        [_finalizingDownloadOperationIdentifiers addObject:operation.identifier];
        [_scheduledDownloadOperationIdentifiers removeObject:operation.identifier];
        [self _startNextDownloadOperations];
        [self _persistSuccessfulDownloadForOperation:operation completion:^(NSError* error) {
            [self _finishCacheOperationDidEnd:operation persistenceError:error];
        }];
        return;
    }

    [self _finishCacheOperationDidEnd:operation persistenceError:nil];
}

- (void)_persistSuccessfulDownloadForOperation:(CACHE_OPERATION_CLASS*)operation
                                    completion:(void (^)(NSError* error))completion
{
    CDEpisode* episode = operation.userInfo;
    CDFeed* feed = episode.feed;
    BOOL previousDownloaded = episode.downloaded;
    NSDate* previousLastDownloaded = episode.lastDownloaded;
    BOOL previousConsumed = episode.consumed;
    NSString* previousUsername = [feed.username copy];
    NSString* previousPassword = [feed.password copy];
    __block NSError* persistenceError = nil;

    void (^restorePreviousValues)(void) = ^{
        episode.downloaded = previousDownloaded;
        episode.lastDownloaded = previousLastDownloaded;
        episode.consumed = previousConsumed;
        feed.username = previousUsername;
        feed.password = previousPassword;
    };

    @try {
        if (!operation.automatic && !operation.preservesConsumedState) {
            episode.consumed = NO;
        }
        episode.lastDownloaded = [NSDate date];
        episode.downloaded = YES;
        if (![operation.username isEqualToString:feed.username] ||
            ![operation.password isEqualToString:feed.password]) {
            feed.username = operation.username;
            feed.password = operation.password;
        }
        persistenceError = [DMANAGER saveReturningError];
    }
    @catch (NSException* exception) {
        persistenceError = [NSError errorWithDomain:@"CacheManager"
                                               code:43
                                           userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"The downloaded episode state could not be saved."}];
    }

    if (persistenceError) {
        @try {
            restorePreviousValues();
        }
        @catch (NSException* exception) {
            ErrLog(@"could not roll back failed download persistence: %@", exception);
        }
        NSError* publicError = [NSError errorWithDomain:@"CacheManager"
                                                   code:43
                                               userInfo:@{
                                                   NSLocalizedDescriptionKey: @"The downloaded episode state could not be saved. Restart the app and try again.".ls,
                                                   NSUnderlyingErrorKey: persistenceError,
                                               }];
        if (completion) completion(publicError);
        return;
    }

    if (!operation.automatic) {
        if (completion) completion(nil);
        return;
    }

    [self.cacheHistory setEpisode:operation.userInfo
                  didAutoDownload:YES
                       completion:^(NSError* historyError) {
        if (!historyError) {
            if (completion) completion(nil);
            return;
        }

        NSError* rollbackError = nil;
        @try {
            restorePreviousValues();
            rollbackError = [DMANAGER saveReturningError];
        }
        @catch (NSException* exception) {
            rollbackError = [NSError errorWithDomain:@"CacheManager"
                                                 code:43
                                             userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"The downloaded episode state could not be rolled back."}];
        }
        if (rollbackError) {
            ErrLog(@"could not roll back download after history failure: %@", rollbackError);
        }
        NSError* publicError = [NSError errorWithDomain:@"CacheManager"
                                                   code:43
                                               userInfo:@{
                                                   NSLocalizedDescriptionKey: @"The downloaded episode state could not be saved. Restart the app and try again.".ls,
                                                   NSUnderlyingErrorKey: historyError,
                                               }];
        if (completion) completion(publicError);
    }];
}

- (void)_finishCacheOperationDidEnd:(CACHE_OPERATION_CLASS*)operation
                   persistenceError:(NSError*)persistenceError
{
    CDEpisode* episode = operation.userInfo;
    BOOL succeeded = !operation.cancelled && !operation.failed && !persistenceError;
    BOOL failed = (!operation.cancelled && operation.failed) || persistenceError != nil;
    NSError* terminalError = persistenceError;
#if TARGET_OS_IPHONE
    if (!terminalError) terminalError = operation.terminalError;
#endif
    if (failed && !terminalError) {
        terminalError = [NSError errorWithDomain:@"ICCacheOperationErrorDomain"
                                             code:1
                                         userInfo:@{NSLocalizedDescriptionKey: @"The episode download could not be completed.".ls}];
    }

    NSDictionary* pendingRemoval = _cancelledDownloadRemovalRequestsByIdentifier[operation.identifier];
    BOOL retryDeferredCancellation = operation.cancelled
        && [InstacastBackupImporter ownsDeferredDownloadWithObjectHash:operation.identifier];
    BOOL queueOwnerRemoved = [self _removeTrackedDownloadOperation:operation];
    [_finalizingDownloadOperationIdentifiers removeObject:operation.identifier];
    if (queueOwnerRemoved && retryDeferredCancellation) {
        [InstacastBackupImporter retryPendingDeferredRestoreIfNeeded];
    }
    if (pendingRemoval) {
        NSMutableDictionary* terminalRequest = [pendingRemoval mutableCopy];
        terminalRequest[@"terminalDownloadSucceeded"] = @(succeeded);
        if (succeeded) {
            if (operation.localURL) terminalRequest[@"url"] = operation.localURL;
#if TARGET_OS_IPHONE
            [operation claimFinalizedDownload];
            terminalRequest[@"terminalFileSize"] = @(operation.finalFileSize);
#else
            terminalRequest[@"terminalFileSize"] = @([[[NSFileManager defaultManager] attributesOfItemAtPath:operation.localURL.path error:nil] fileSize]);
#endif
            terminalRequest[@"terminalDownloadedAt"] = [NSDate date];
        }
        _cancelledDownloadRemovalRequestsByIdentifier[operation.identifier] = [terminalRequest copy];
        [self _finishCancelledDownloadRemovalForIdentifier:operation.identifier];
        [self _automaticRetryOperationDidFinishWithIdentifier:operation.identifier];
        [self _startNextDownloadOperations];
        [self _finishDownloadBatchAfterOperation:operation];
        return;
    }

    if (persistenceError) {
#if TARGET_OS_IPHONE
        [operation cancel];
#else
        [[NSFileManager defaultManager] removeItemAtURL:operation.localURL error:nil];
#endif
    }

	if (succeeded)
	{
#if TARGET_OS_IPHONE
        [operation claimFinalizedDownload];
        [self _addDownloadedBytes:operation.finalFileSize];
        if (episode.objectHash.length > 0 && operation.localURL) {
            _cachedURLIndex[episode.objectHash] = operation.localURL;
        }
#else
        unsigned long long finalFileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:operation.localURL.path error:nil] fileSize];
        [self _addDownloadedBytes:finalFileSize];
#endif
        [self willChangeValueForKey:@"cachedEpisodes"];
        [_cachedEpisodes addObject:episode];
        [self didChangeValueForKey:@"cachedEpisodes"];

        if (operation.automatic) {
#if TARGET_OS_IPHONE
            if ([episode.feed boolForKey:EnableNewEpisodeNotification] && App.applicationState == UIApplicationStateBackground) {
                // UILocalNotification is deprecated but kept for stability
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                UILocalNotification* notification = [[UILocalNotification alloc] init];
                NSString* episodeTitle = [NSString stringWithFormat:@"%@ - %@", episode.feed.title, [episode cleanTitleUsingFeedTitle:episode.feed.title]];
                if ([notification respondsToSelector:@selector(alertTitle)]) {
                    notification.alertTitle = @"New Episode".ls;
                }
                if ([notification respondsToSelector:@selector(category)]) {
                    notification.category = @"episode_available";
                }
                notification.alertBody = [NSString stringWithFormat:@"'%@' is available to play.".ls, episodeTitle];
                notification.soundName = @"NewEpisodes";
                notification.userInfo = @{ @"episode_hash" : [episode objectHash], @"podcast" : episode.feed.title, @"episode" : [episode cleanTitleUsingFeedTitle:episode.feed.title]};
                [App presentLocalNotificationNow:notification];
#pragma clang diagnostic pop
            }
#endif
        }
	}

    void (^failurePersistenceCompletion)(NSError*) = ^(NSError* persistenceError) {
        if (persistenceError) {
            [[ICDiagnosticLogger shared] logEvent:@"episode-download-failure-persist-failed"
                                          message:@"Download-Fehlerzustand konnte nicht gespeichert werden"
                                         metadata:@{
                                             @"episodeHash": operation.identifier ?: @"",
                                             @"error": persistenceError.localizedDescription ?: @"",
                                         }];
        }
        [self _completeBackgroundSessionForIdentifier:operation.identifier];
    };

    if (failed) {
        _currentQueueHadFailure = YES;
        [self _recordDownloadError:terminalError
                        forEpisode:episode
                         automatic:operation.automatic
            overwriteCellularLock:operation.overwriteCellularLock
              reportsFailureToUser:operation.reportsFailureToUser
            preservesConsumedState:operation.preservesConsumedState
                        completion:failurePersistenceCompletion];
#if TARGET_OS_IPHONE
        if (operation.reportsFailureToUser && !operation.automatic && App.applicationState == UIApplicationStateActive) {
            NSString* episodeTitle = [episode cleanTitleUsingFeedTitle:episode.feed.title] ?: episode.title ?: @"";
            NSString* message = episodeTitle.length > 0
                ? [NSString stringWithFormat:@"%@\n%@", episodeTitle, terminalError.localizedDescription]
                : terminalError.localizedDescription;
            [App showBackgroundErrorWithTitle:@"Download Failed".ls message:message duration:8.0];
        }
#endif
    }

    [self _automaticRetryOperationDidFinishWithIdentifier:operation.identifier];
    
    _flags.supressSendUpdate = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableDictionary* userInfo = [@{
            @"episode": episode,
            @"automatic": @(operation.automatic),
            @"reportsFailureToUser": @(operation.reportsFailureToUser),
        } mutableCopy];
        if (succeeded) {
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidFinishCachingEpisodeNotification
                                                                object:self
                                                              userInfo:userInfo];
        } else if (failed) {
            userInfo[@"error"] = terminalError;
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidFailCachingEpisodeNotification
                                                                object:self
                                                              userInfo:userInfo];
        }
        
        if (!failed) {
            [self _completeBackgroundSessionForIdentifier:operation.identifier];
        }
        
        self->_flags.supressSendUpdate = NO;
    });
    
    [self _startNextDownloadOperations];
    [self _finishDownloadBatchAfterOperation:operation];

    [self autoClearAndMakeRoomForBytes:0 automatic:operation.automatic];
}

- (void) _finishDownloadBatchAfterOperation:(CACHE_OPERATION_CLASS*)operation
{
    if (_downloadOperationsByIdentifier.count > 0 || _totalOps == 0) {
        return;
    }
    [_updateTimer invalidate];
    _updateTimer = nil;
    _rateDate = nil;
    _rateBytes = 0;
    self.rate = 0;
    if (_subscriptionCleanupDeferredDownloadInfosByIdentifier.count > 0) return;

    BOOL queueHadFailure = _currentQueueHadFailure;
    _currentQueueHadFailure = NO;
    _totalOps = 0;
    self.suspended = NO;
    [USER_DEFAULTS setBool:NO forKey:ICDownloadQueueSuspended];
    BOOL hasStreamingCache = (_streamingCacheLeaseTokensByIdentifier.count > 0);

    if (!hasStreamingCache && operation && !queueHadFailure && !operation.cancelled && !operation.failed) {
        BOOL notificationEnabled = [USER_DEFAULTS boolForKey:EnableManualDownloadFinishedNotification];
        if (notificationEnabled) {
#if TARGET_OS_IPHONE
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            UILocalNotification* finishedNotification = [[UILocalNotification alloc] init];
            finishedNotification.alertBody = @"Downloads Finished".ls;
            [App presentLocalNotificationNow:finishedNotification];
#pragma clang diagnostic pop
#else
            NSUserNotification* finishedNotification = [[NSUserNotification alloc] init];
            finishedNotification.title = @"Downloads Finished".ls;
            [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:finishedNotification];
#endif
        }
        PlaySoundFile(@"DownloadFinished",NO);
        [self performSelector:@selector(_endBackgroundTaskAfterSoundPlayed) withObject:nil afterDelay:1.0];
    } else {
        [self _endBackgroundTaskAfterSoundPlayed];
    }

    if (!hasStreamingCache) {
        _flags.supressSendUpdate = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidEndCachingNotification object:self];
            self->_flags.supressSendUpdate = NO;
        });
    }
}

- (void) cacheOperationHasBeenSuspended:(CACHE_OPERATION_CLASS*)operation
{
    
}

- (void) cacheOperation:(CACHE_OPERATION_CLASS*)operation didLoadNumberOfBytes:(int64_t)numberOfBytes
{
    if (!_rateDate) {
        _rateDate = [NSDate date];
        _rateBytes = 0LL;
    }
    
    _rateBytes += numberOfBytes;
}

#pragma mark -

- (double) progress
{
    if (_totalOps <= 0) {
        return 0.0;
    }
    NSInteger outstandingCount = MIN(_totalOps, (NSInteger)_downloadOperationsByIdentifier.count);
	double mainProgress = (double)(_totalOps - outstandingCount) / (double)_totalOps;
	double progressPerOperation = 1.0 / (double)_totalOps;
	for(CACHE_OPERATION_CLASS* operation in _downloadOperationsByIdentifier.allValues) {
		mainProgress += operation.progress * progressPerOperation;
	}
	return MIN(1.0, MAX(0.0, mainProgress));
}

- (double) cacheProgressForEpisode:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation) {
		return operation.progress;
	}
	return [self streamingCacheProgressForEpisode:episode];
}

- (double) cacheProgressForFeed:(CDFeed*)feed
{
    NSInteger episodes = 0;
    double progress = 0;
    NSArray* operations = [_downloadOperationsByIdentifier.allValues copy];
	for(CACHE_OPERATION_CLASS* operation in operations) {
        CDEpisode* episode = (CDEpisode*)operation.userInfo;
        if (![operation isCancelled] && [episode.feed isEqual:feed]) {
            episodes++;
            progress += operation.progress;
        }
	}
    
    return (episodes > 0) ? (progress / (double)episodes) : 0;
}

- (double) cacheProgress
{
    NSInteger episodes = 0;
    double progress = 0;
    NSArray* operations = [_downloadOperationsByIdentifier.allValues copy];
	for(CACHE_OPERATION_CLASS* operation in operations) {
        if (![operation isCancelled]) {
            episodes++;
            progress += operation.progress;
        }
	}
    
    return (episodes > 0) ? (progress / (double)episodes) : 0;
}

- (long long) expectedContentLengthForEpisode:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation) {
		return operation.expectedContentLength;
	}

    if ([self _hasStreamingCacheForEpisode:episode]) {
        return [episode preferedMedium].byteSize;
    }

	return 0;
}

- (BOOL) isLoadingEpisode:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation) {
		return [operation isExecuting];
	}
	return ([self streamingCacheProgressForEpisode:episode] > 0 || [self _hasStreamingCacheForEpisode:episode]);
}

- (BOOL) isLoadingEpisodeSuspended:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation) {
		return ([operation isExecuting] && operation.suspended);
	}
    NSDictionary* deferredInfo =
        _subscriptionCleanupDeferredDownloadInfosByIdentifier[episode.objectHash];
    return deferredInfo != nil
        && (self.suspended || [deferredInfo[@"suspended"] boolValue]);
}

- (NSString*) _streamingCacheKeyForEpisode:(CDEpisode*)episode
{
    NSString* key = episode.objectHash;
    return ([key length] > 0) ? key : nil;
}

- (BOOL) _hasStreamingCacheForEpisode:(CDEpisode*)episode
{
    NSString* key = [self _streamingCacheKeyForEpisode:episode];
    return (key && _streamingCacheLeaseTokensByIdentifier[key] != nil);
}

- (NSString*) beginStreamingCacheForEpisode:(CDEpisode*)episode
                           acquiredNewLease:(BOOL*)acquiredNewLease
{
    if (acquiredNewLease) *acquiredNewLease = NO;
    NSString* key = [self _streamingCacheKeyForEpisode:episode];
    if (!key || _clearingAllCache) {
        return nil;
    }
    CACHE_OPERATION_CLASS* sourceOperation = _downloadOperationsByIdentifier[key];
    BOOL sourceOperationHasPendingYield = _downloadPauseYieldTokensByIdentifier[key] != nil;
    if (sourceOperation &&
        !sourceOperationHasPendingYield && sourceOperation.cancelled) {
        sourceOperation = nil;
    }
    if (sourceOperation &&
        !sourceOperationHasPendingYield &&
        (sourceOperation.finished ||
         [_finalizingDownloadOperationIdentifiers containsObject:key])) {
        return nil;
    }
    if ([self _subscriptionCleanupBlocksEpisode:episode]) {
        BOOL accepted = [self _deferDownloadUntilSubscriptionCleanupFinishes:episode
                                                                    autoCache:NO
                                                      overwriteCellularLock:YES
                                                         reportsFailureToUser:NO
                                                       preservesConsumedState:YES
                                                                     queueRank:nil];
        if (accepted && sourceOperation) {
            [self _cancelDownloadOperationForStreamingTransition:sourceOperation];
        }
        return nil;
    }
    if (_cacheDeletionTokensByIdentifier[key]) {
        return nil;
    }
    NSString* existingLeaseToken = _streamingCacheLeaseTokensByIdentifier[key];
    if (existingLeaseToken.length > 0) {
        if (sourceOperation) {
            [self _cancelDownloadOperationForStreamingTransition:sourceOperation];
        }
        return existingLeaseToken;
    }
    if (_cacheImportTokensByIdentifier[key] || [self episodeIsCached:episode]) {
        return nil;
    }
    [self clearDownloadErrorForEpisode:episode];

    BOOL wasCaching = [self isCaching];
    BOOL wasTrackingEpisode = [self isCachingEpisode:episode];
    NSString* leaseToken = nil;
    do {
        leaseToken = NSUUID.UUID.UUIDString;
    } while ([_streamingCacheRecoveryCandidateTokens containsObject:leaseToken]);
    _streamingCacheLeaseTokensByIdentifier[key] = leaseToken;
    _streamingCacheProgresses[key] = @(0.0);
    _streamingCacheBytesByIdentifier[key] = @0;
    if (acquiredNewLease) *acquiredNewLease = YES;
    if (sourceOperation) {
        [self _cancelDownloadOperationForStreamingTransition:sourceOperation];
    }

    if (!wasTrackingEpisode) {
        [self willChangeValueForKey:@"cachingEpisodes"];
        [_cachingEpisodes addObject:episode];
        [_cachingEpisodeHashes addObject:key];
        [self didChangeValueForKey:@"cachingEpisodes"];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:wasCaching ? CacheManagerDidAddEpisodeToCachingQueueNotification : CacheManagerDidStartCachingNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidStartCachingEpisodeNotification
                                                        object:self
                                                      userInfo:@{ @"episode" : episode }];
    [self _postDidUpdateNotification];
    return leaseToken;
}

- (void) updateStreamingCacheForEpisode:(CDEpisode*)episode
                               progress:(double)progress
                        downloadedBytes:(unsigned long long)downloadedBytes
                             leaseToken:(NSString*)leaseToken
{
    NSString* key = [self _streamingCacheKeyForEpisode:episode];
    if (!key || ![_streamingCacheLeaseTokensByIdentifier[key] isEqualToString:leaseToken]) {
        return;
    }

    double normalizedProgress = MIN(MAX(progress, 0.0), 1.0);
    _streamingCacheProgresses[key] = @(normalizedProgress);
    [self _setStreamingCacheBytes:downloadedBytes forIdentifier:key];

    [self _postDidUpdateNotification];
    unsigned long long maxAllowedBytes = (unsigned long long)[USER_DEFAULTS integerForKey:AutoCacheStorageLimit] * 1024LLU * 1024LLU;
    if (!_downloadedBytesKnown || (maxAllowedBytes > 0 && _downloadedBytes > maxAllowedBytes)) {
        [self autoClearAndMakeRoomForBytes:0 automatic:YES];
    }
}

- (void) finishStreamingCacheForEpisode:(CDEpisode*)episode leaseToken:(NSString*)leaseToken
{
    NSString* key = [self _streamingCacheKeyForEpisode:episode];
    if (!key || ![_streamingCacheLeaseTokensByIdentifier[key] isEqualToString:leaseToken]) {
        return;
    }

    [self _removeStreamingCacheBytesForIdentifier:key];
    [_streamingCacheLeaseTokensByIdentifier removeObjectForKey:key];
    [_streamingCacheProgresses removeObjectForKey:key];
    [self _removeCachingEpisodeForIdentifierIfUnowned:key];

    [self _postDidUpdateNotification];
    [self autoClearAndMakeRoomForBytes:0 automatic:YES];
    if (![self isCaching]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidEndCachingNotification object:self];
    }
}

- (void) failStreamingCacheForEpisode:(CDEpisode*)episode error:(NSError*)error leaseToken:(NSString*)leaseToken
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self failStreamingCacheForEpisode:episode error:error leaseToken:leaseToken];
        });
        return;
    }
    NSString* key = [self _streamingCacheKeyForEpisode:episode];
    if (![_streamingCacheLeaseTokensByIdentifier[key] isEqualToString:leaseToken]) {
        return;
    }

    [self finishStreamingCacheForEpisode:episode leaseToken:leaseToken];
    [self _recordDownloadError:error
                    forEpisode:episode
                     automatic:NO
        overwriteCellularLock:NO
          reportsFailureToUser:YES
        preservesConsumedState:YES
                    completion:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidFailCachingEpisodeNotification
                                                        object:self
                                                      userInfo:@{
                                                          @"episode": episode,
                                                          @"error": error,
                                                          @"automatic": @NO,
                                                          @"reportsFailureToUser": @YES,
                                                      }];
#if TARGET_OS_IPHONE
    if (App.applicationState == UIApplicationStateActive) {
        NSString* episodeTitle = [episode cleanTitleUsingFeedTitle:episode.feed.title] ?: episode.title ?: @"";
        NSString* message = episodeTitle.length > 0
            ? [NSString stringWithFormat:@"%@\n%@", episodeTitle, error.localizedDescription]
            : error.localizedDescription;
        [App showBackgroundErrorWithTitle:@"Download Failed".ls message:message duration:8.0];
    }
#endif
}

- (double) streamingCacheProgressForEpisode:(CDEpisode*)episode
{
    NSString* key = [self _streamingCacheKeyForEpisode:episode];
    NSNumber* progress = (key && _streamingCacheLeaseTokensByIdentifier[key]) ? _streamingCacheProgresses[key] : nil;
    return progress ? [progress doubleValue] : 0.0;
}

- (NSTimeInterval) cacheTimeLeftForEpisode:(CDEpisode*)episode
{
	CACHE_OPERATION_CLASS* operation = [self _cacheOperationForEpisode:episode];
	if (operation && !operation.suspended) {
        return operation.estimatedTimeLeft;
	}
	return 0;
}

#pragma mark -


- (void) tidyUp
{
	NSFileManager* fman = [NSFileManager defaultManager];
	
	NSMutableDictionary* validHashes = [[NSMutableDictionary alloc] init];
	for(CDFeed* feed in DMANAGER.visibleFeeds)
	{
        NSURL* refURL = feed.imageURL;
        if (!refURL) {
            continue;
        }
        
        [validHashes setObject:[NSNumber numberWithInteger:1] forKey:[[refURL absoluteString] MD5Hash]];
	}
	
	NSInteger i=0;
	NSInteger removed = 0;
	NSDirectoryEnumerator* e = [fman enumeratorAtPath:[DMANAGER.imageCacheURL path]];
	for(NSString* filename in e)
	{
		NSString* f = [filename stringByDeletingPathExtension];
		NSRange r = [f rangeOfString:@"_"];
		if (r.location != NSNotFound)
		{
			f = [f substringToIndex:r.location];
			
			if (![validHashes objectForKey:f])
			{
				NSString* path = [[DMANAGER.imageCacheURL path] stringByAppendingPathComponent:filename];
				NSError* attributesError = nil;
				NSDictionary* fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:&attributesError];
				NSDate* modDate = [fileAttributes fileModificationDate];
				
				if ([[NSDate date] timeIntervalSinceDate:modDate] > 86400) {
					[fman removeItemAtPath:path error:nil];
					removed++;
				}
				i++;
			}
		}
		
		/* only check 20 files for performance reasons */
		if (i>=20) {
			break;
		}
	}
    
    NSInteger removed_episodes = 0;
    // checking for orphaned episode files (limit to 50 files per run for performance)
    NSInteger episodeFilesChecked = 0;
    e = [fman enumeratorAtPath:[CacheManager _pathToStorageLocation]];
    for(NSString* filename in e)
	{
        @autoreleasepool {
            // Extract hash: new format "Podcast - Episode - HASH.ext" or old format "HASH.ext"
            NSString* nameWithoutExt = [filename stringByDeletingPathExtension];
            NSString* episodeHash = nil;
            NSRange lastDash = [nameWithoutExt rangeOfString:@" - " options:NSBackwardsSearch];
            if (lastDash.location != NSNotFound) {
                episodeHash = [nameWithoutExt substringFromIndex:NSMaxRange(lastDash)];
            } else if (nameWithoutExt.length >= 8) {
                episodeHash = nameWithoutExt;
            }

            if (episodeHash.length > 0 && ![DMANAGER episodeWithObjectHash:episodeHash]) {
                [fman removeItemAtPath:[[CacheManager _pathToStorageLocation] stringByAppendingPathComponent:filename] error:nil];
                removed_episodes++;
            }
            episodeFilesChecked++;
            if (episodeFilesChecked >= 50) break;
        }
    }
    [self _invalidateDownloadedBytesAndRecalculate];
}

- (unsigned long long) numberOfDownloadedBytes
{
    if (!_downloadedBytesKnown) {
        [self recalculateDownloadedBytesInBackground];
    }
    return _downloadedBytes;
}

- (void)_setDownloadedBytes:(unsigned long long)bytes known:(BOOL)known
{
    BOOL changed = (_downloadedBytes != bytes);
    if (changed) {
        [self willChangeValueForKey:@"numberOfDownloadedBytes"];
    }
    _downloadedBytes = bytes;
    _downloadedBytesKnown = known;
    if (changed) {
        [self didChangeValueForKey:@"numberOfDownloadedBytes"];
    }
}

- (unsigned long long)_activeStreamingCacheBytes
{
    unsigned long long total = 0;
    for (NSNumber* value in _streamingCacheBytesByIdentifier.allValues) {
        unsigned long long bytes = value.unsignedLongLongValue;
        total = ULLONG_MAX - total < bytes ? ULLONG_MAX : total + bytes;
    }
    return total;
}

- (void)_setStreamingCacheBytes:(unsigned long long)bytes forIdentifier:(NSString*)identifier
{
    if (identifier.length == 0) {
        return;
    }

    unsigned long long previousBytes = [_streamingCacheBytesByIdentifier[identifier] unsignedLongLongValue];
    if (previousBytes == bytes) {
        return;
    }
    _streamingCacheBytesByIdentifier[identifier] = @(bytes);
    if (!_downloadedBytesKnown) {
        return;
    }

    if (bytes > previousBytes) {
        unsigned long long addedBytes = bytes - previousBytes;
        unsigned long long totalBytes = ULLONG_MAX - _downloadedBytes < addedBytes
            ? ULLONG_MAX
            : _downloadedBytes + addedBytes;
        [self _setDownloadedBytes:totalBytes known:YES];
    } else {
        unsigned long long removedBytes = previousBytes - bytes;
        [self _setDownloadedBytes:(removedBytes >= _downloadedBytes ? 0 : _downloadedBytes - removedBytes)
                            known:YES];
    }
}

- (void)_removeStreamingCacheBytesForIdentifier:(NSString*)identifier
{
    if (identifier.length == 0) {
        return;
    }
    if (_streamingCacheBytesByIdentifier[identifier]) {
        [self _setStreamingCacheBytes:0 forIdentifier:identifier];
    }
    [_streamingCacheBytesByIdentifier removeObjectForKey:identifier];
}

- (void)_addDownloadedBytes:(unsigned long long)bytes
{
    if (bytes == 0) {
        return;
    }
    _downloadedBytesGeneration += 1;
    if (!_downloadedBytesKnown) {
        [self recalculateDownloadedBytesInBackground];
        return;
    }
    unsigned long long newValue = ULLONG_MAX - _downloadedBytes < bytes ? ULLONG_MAX : _downloadedBytes + bytes;
    [self _setDownloadedBytes:newValue known:YES];
}

- (void)_subtractDownloadedBytes:(unsigned long long)bytes
{
    if (bytes == 0) {
        return;
    }
    _downloadedBytesGeneration += 1;
    if (!_downloadedBytesKnown) {
        [self recalculateDownloadedBytesInBackground];
        return;
    }
    [self _setDownloadedBytes:(bytes >= _downloadedBytes ? 0 : _downloadedBytes - bytes) known:YES];
}

- (void)_invalidateDownloadedBytesAndRecalculate
{
    _downloadedBytesGeneration += 1;
    _downloadedBytesKnown = NO;
    [self recalculateDownloadedBytesInBackground];
}

- (void)recalculateDownloadedBytesInBackground
{
    if (_downloadedBytesRecalculationInFlight) {
        return;
    }
    _downloadedBytesRecalculationInFlight = YES;
    NSUInteger scanGeneration = _downloadedBytesGeneration;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSFileManager* fman = [[NSFileManager alloc] init];
        __block unsigned long long size = 0;
        NSError* streamingCleanupError = nil;
        __block BOOL scanSnapshotValid = [self _removeOrphanedStreamingCacheDirectoriesWithFileManager:fman
                                                                                                  error:&streamingCleanupError];
        NSString* streamingPath = [[CacheManager _pathToCache] stringByAppendingPathComponent:@"Streaming"];
        void (^accumulateDirectory)(NSString*) = ^(NSString* directoryPath) {
            if (!scanSnapshotValid || directoryPath.length == 0) {
                if (directoryPath.length == 0) scanSnapshotValid = NO;
                return;
            }
            NSURL* directoryURL = [NSURL fileURLWithPath:directoryPath isDirectory:YES];
            NSError* reachabilityError = nil;
            if (![directoryURL checkResourceIsReachableAndReturnError:&reachabilityError]) {
                if (!ICCacheFileErrorMeansMissing(reachabilityError)) scanSnapshotValid = NO;
                return;
            }
            NSDirectoryEnumerator<NSURL*>* files = [fman enumeratorAtURL:directoryURL
                                               includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                                  options:0
                                                             errorHandler:^BOOL(NSURL* url, NSError* error) {
                (void)url;
                if (!ICCacheFileErrorMeansMissing(error)) scanSnapshotValid = NO;
                return NO;
            }];
            for (NSURL* fileURL in files) {
                @autoreleasepool {
                    if ([fileURL.path isEqualToString:streamingPath]) {
                        [files skipDescendants];
                        continue;
                    }
                    NSError* resourceError = nil;
                    NSDictionary* values = [fileURL resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                                    error:&resourceError];
                    if (!values) {
                        if (!ICCacheFileErrorMeansMissing(resourceError)) scanSnapshotValid = NO;
                        continue;
                    }
                    if ([values[NSURLIsRegularFileKey] boolValue]) {
                        size += [values[NSURLFileSizeKey] unsignedLongLongValue];
                    }
                }
            }
        };

        NSString* pathToDownloads = [CacheManager _pathToStorageLocation];
        accumulateDirectory(pathToDownloads);

        NSString* pathToPartialDownloads = [CacheManager _pathToCache];
        if (![pathToPartialDownloads isEqualToString:pathToDownloads]) {
            accumulateDirectory(pathToPartialDownloads);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_downloadedBytesRecalculationInFlight = NO;
            if (scanGeneration != self->_downloadedBytesGeneration) {
                if (!self->_downloadedBytesKnown) {
                    [self recalculateDownloadedBytesInBackground];
                }
                return;
            }
            if (!scanSnapshotValid) {
                self->_downloadedBytesKnown = NO;
                [[ICDiagnosticLogger shared] logEvent:@"cache"
                                              message:@"Download-Speicher konnte nicht vollständig gelesen werden"
                                             metadata:@{ @"error": streamingCleanupError.localizedDescription ?: @"" }];
                return;
            }
            unsigned long long activeStreamingBytes = [self _activeStreamingCacheBytes];
            unsigned long long totalBytes = ULLONG_MAX - size < activeStreamingBytes
                ? ULLONG_MAX
                : size + activeStreamingBytes;
            [self _setDownloadedBytes:totalBytes known:YES];
            if (self->_hasPendingAutoClear) {
                unsigned long long pendingBytes = self->_pendingAutoClearBytes;
                BOOL pendingAutomatic = self->_pendingAutoClearAutomatic;
                self->_hasPendingAutoClear = NO;
                self->_pendingAutoClearBytes = 0;
                [self autoClearAndMakeRoomForBytes:pendingBytes automatic:pendingAutomatic];
            }
        });
    });
}

- (unsigned long long) numberOfDownloadedBytesForEpisode:(CDEpisode*)episode
{
    NSFileManager* fman = [NSFileManager defaultManager];
    NSError* error = nil;

    NSURL* url = [self URLForCachedEpisode:episode];
    if (!url) return 0;
    NSDictionary* fileAttributes = [fman attributesOfItemAtPath:[url path] error:&error];
    if (!error) {
        return [fileAttributes fileSize];
    }

    error = nil;
    url = [self tempURLForCachedEpisode:episode];
    fileAttributes = [fman attributesOfItemAtPath:[url path] error:&error];
    if (!error) {
        return [fileAttributes fileSize];
    }

    return 0;
}

- (ICCacheDeletionPreparation*) _prepareForDestructiveCacheClear
{
    ICCacheDeletionPreparation* deletionPreparation = [[ICCacheDeletionPreparation alloc] init];
    [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerWillDeleteCacheFilesNotification
                                                        object:self
                                                      userInfo:@{
                                                          @"all" : @YES,
                                                          @"cacheDeletionPreparation": deletionPreparation,
                                                      }];
    return deletionPreparation;
}

- (void) _commitDestructiveCacheClearPreparation
{
    // A user clear is authoritative even if the launch-time directory snapshot is still
    // being assembled. Its completion must not repopulate URLs, episode flags or jobs.
    _cacheIndexGeneration += 1;
    NSError* interruptedDeletionError = [NSError errorWithDomain:@"CacheManager"
                                                             code:35
                                                         userInfo:@{NSLocalizedDescriptionKey: @"The individual download removal was replaced by clearing all downloaded files.".ls}];
    NSDictionary<NSString*, NSArray*>* pendingCompletions = [_cacheDeletionCompletionsByIdentifier copy];
    [_cacheDeletionCompletionsByIdentifier removeAllObjects];
    [_cacheDeletionTokensByIdentifier removeAllObjects];
    [_cacheDeletionHashesDuringIndexScan removeAllObjects];
    [_cancelledDownloadRemovalRequestsByIdentifier removeAllObjects];
    for (NSArray* completions in pendingCompletions.allValues) {
        for (id completionObject in completions) {
            void (^completion)(NSError*) = completionObject;
            completion(interruptedDeletionError);
        }
    }
    _cacheIndexReady = YES;
    _cacheIndexScanInFlight = NO;
    self.suspended = NO;
    [USER_DEFAULTS setBool:NO forKey:ICDownloadQueueSuspended];
}

- (void) _finalizeDestructiveCacheClearJobState
{
    [self _removeAllSavedCachingInfos];
#if TARGET_OS_IPHONE
    [CACHE_OPERATION_CLASS deleteAllResumeInfo];
#endif
}

- (NSError*) _deleteAllCacheFilesNow
{
    NSFileManager* fileManager = [[NSFileManager alloc] init];
    NSMutableOrderedSet<NSString*>* paths = [NSMutableOrderedSet orderedSet];
    NSString* storagePath = [CacheManager _pathToStorageLocation];
    NSString* partialPath = [CacheManager _pathToCache];
    if (storagePath.length > 0) [paths addObject:storagePath];
    if (partialPath.length > 0) [paths addObject:partialPath];
    NSError* firstError = nil;
    NSMutableSet<NSString*>* initialEpisodeHashes = [NSMutableSet set];
    for (NSString* rootPath in paths) {
        NSError* listingError = nil;
        [fileManager contentsOfDirectoryAtPath:rootPath error:&listingError];
        if (listingError && !ICCacheFileErrorMeansMissing(listingError)) {
            if (!firstError) firstError = listingError;
            continue;
        }
        NSDirectoryEnumerator* enumerator = [fileManager enumeratorAtPath:rootPath];
        NSArray<NSString*>* entries = enumerator.allObjects;
        if ([rootPath isEqualToString:storagePath]) {
            for (NSString* entry in entries) {
                if (entry.pathComponents.count != 1) continue;
                NSString* nameWithoutExtension = [entry.lastPathComponent stringByDeletingPathExtension];
                NSRange lastSeparator = [nameWithoutExtension rangeOfString:@" - " options:NSBackwardsSearch];
                NSString* identifier = lastSeparator.location == NSNotFound
                    ? nameWithoutExtension
                    : [nameWithoutExtension substringFromIndex:NSMaxRange(lastSeparator)];
                if (identifier.length > 0) [initialEpisodeHashes addObject:identifier];
            }
        }
        for (NSString* entry in entries.reverseObjectEnumerator) {
            NSError* removeError = nil;
            if (![fileManager removeItemAtPath:[rootPath stringByAppendingPathComponent:entry] error:&removeError] &&
                !ICCacheFileErrorMeansMissing(removeError) && !firstError) {
                firstError = removeError;
            }
        }
    }
    NSError* transcriptError = ICClearAllTranscriptCache();
    if (!firstError && transcriptError) firstError = transcriptError;

    NSMutableDictionary<NSString*, NSURL*>* remainingURLsByHash = [NSMutableDictionary dictionary];
    unsigned long long remainingBytes = 0;
    BOOL remainingSnapshotValid = YES;
    for (NSString* rootPath in paths) {
        NSError* listingError = nil;
        [fileManager contentsOfDirectoryAtPath:rootPath error:&listingError];
        if (ICCacheFileErrorMeansMissing(listingError)) continue;
        if (listingError) {
            remainingSnapshotValid = NO;
            if (!firstError) firstError = listingError;
            continue;
        }
        NSDirectoryEnumerator* enumerator = [fileManager enumeratorAtPath:rootPath];
        for (NSString* entry in enumerator) {
            NSString* filePath = [rootPath stringByAppendingPathComponent:entry];
            NSError* attributesError = nil;
            NSDictionary* attributes = [fileManager attributesOfItemAtPath:filePath error:&attributesError];
            if (!attributes) {
                remainingSnapshotValid = NO;
                if (!firstError) firstError = attributesError;
                continue;
            }
            if ([attributes[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
            remainingBytes += [attributes fileSize];
            if ([rootPath isEqualToString:storagePath] && entry.pathComponents.count == 1) {
                NSString* nameWithoutExtension = [entry.lastPathComponent stringByDeletingPathExtension];
                NSRange lastSeparator = [nameWithoutExtension rangeOfString:@" - " options:NSBackwardsSearch];
                NSString* identifier = lastSeparator.location == NSNotFound
                    ? nameWithoutExtension
                    : [nameWithoutExtension substringFromIndex:NSMaxRange(lastSeparator)];
                if (identifier.length > 0) remainingURLsByHash[identifier] = [NSURL fileURLWithPath:filePath];
            }
        }
    }
    NSMutableSet<NSString*>* removedHashes = [initialEpisodeHashes mutableCopy];
    [removedHashes minusSet:[NSSet setWithArray:remainingURLsByHash.allKeys]];
    _cacheClearRemainingURLsByHash = [remainingURLsByHash copy];
    _cacheClearRemovedHashes = [removedHashes copy];
    _cacheClearRemainingBytes = remainingBytes;
    _cacheClearSnapshotValid = remainingSnapshotValid;

    if (!firstError) return nil;
    return [NSError errorWithDomain:@"CacheManager"
                               code:20
                           userInfo:@{
                               NSLocalizedDescriptionKey: @"Downloaded files could not all be deleted. No other app data was reset. Please try again.".ls,
                               NSUnderlyingErrorKey: firstError,
                           }];
}

- (NSError*) _finishDestructiveCacheClear
{
    if (!_cacheClearSnapshotValid) {
        [self _invalidateDownloadedBytesAndRecalculate];
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidRestoreCacheNotification
                                                            object:self
                                                          userInfo:@{ @"all" : @YES }];
        return [NSError errorWithDomain:@"CacheManager"
                                   code:22
                               userInfo:@{NSLocalizedDescriptionKey: @"The remaining downloaded files could not be verified. Restart the app and try again.".ls}];
    }

    NSDictionary<NSString*, NSURL*>* remainingURLs = _cacheClearRemainingURLsByHash ?: @{};
    NSSet<NSString*>* remainingHashes = [NSSet setWithArray:remainingURLs.allKeys];
    NSMutableSet<NSString*>* removedHashes = [_cacheClearRemovedHashes mutableCopy] ?: [NSMutableSet set];
    NSArray<CDEpisode*>* previouslyCachedEpisodes = _cachedEpisodes.allObjects;
    for (CDEpisode* episode in previouslyCachedEpisodes) {
        if (episode.objectHash.length > 0 && ![remainingHashes containsObject:episode.objectHash]) {
            [removedHashes addObject:episode.objectHash];
        }
    }

    NSMutableSet<NSString*>* affectedHashes = [remainingHashes mutableCopy];
    [affectedHashes unionSet:removedHashes];
    NSArray<CDEpisode*>* affectedEpisodes = [DMANAGER episodesWithObjectHashes:affectedHashes.allObjects];
    NSMutableArray<CDEpisode*>* remainingEpisodes = [NSMutableArray array];
    [self willChangeValueForKey:@"cachedEpisodes"];
    for (CDEpisode* episode in affectedEpisodes) {
        if ([remainingHashes containsObject:episode.objectHash]) {
            episode.downloaded = YES;
            [remainingEpisodes addObject:episode];
        } else {
            episode.downloaded = NO;
            episode.lastDownloaded = nil;
        }
    }
    [_cachedEpisodes removeAllObjects];
    [_cachedEpisodes addObjectsFromArray:remainingEpisodes];
    [_cachedURLIndex removeAllObjects];
    [_cachedURLIndex addEntriesFromDictionary:remainingURLs];
    [_cachingEpisodes removeAllObjects];
    [_cachingEpisodeHashes removeAllObjects];
    [_subscriptionCleanupDeferredDownloadInfosByIdentifier removeAllObjects];
    [_subscriptionCleanupDeferredDownloadEpisodesByIdentifier removeAllObjects];
    [_subscriptionCleanupBackgroundSessionCancellationIdentifiers removeAllObjects];
    _subscriptionCleanupPromotionRequested = NO;
    _subscriptionCleanupPromotionIdentifiers = nil;
    _subscriptionCleanupPromotionCursor = 0;
    [_streamingCacheLeaseTokensByIdentifier removeAllObjects];
    [_streamingCacheProgresses removeAllObjects];
    [_streamingCacheBytesByIdentifier removeAllObjects];
    [_streamingCacheRecoveryCandidateTokens removeAllObjects];
    [_scheduledDownloadOperationIdentifiers removeAllObjects];
    [_downloadQueueRanksByIdentifier removeAllObjects];
    [_manuallySuspendedDownloadIdentifiers removeAllObjects];
    _nextDownloadQueueRank = 0;
    _totalOps = 0;
    _automaticRetryDrainRemainingCount = 0;
    _automaticRetryDrainContinuationScheduled = NO;
    _automaticRetryDrainRescanRequested = NO;
    [self didChangeValueForKey:@"cachedEpisodes"];
    _downloadedBytesGeneration += 1;
    [self _setDownloadedBytes:_cacheClearRemainingBytes known:YES];
    _hasPendingAutoClear = NO;
    _pendingAutoClearBytes = 0;
    BOOL fullyCleared = (remainingURLs.count == 0 && _cacheClearRemainingBytes == 0);

    [self willChangeValueForKey:@"partiallyCachedEpisodes"];
    [self didChangeValueForKey:@"partiallyCachedEpisodes"];

    NSError* saveError = [DMANAGER saveReturningError];
    if (fullyCleared) {
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidClearCacheNotification
                                                            object:self
                                                          userInfo:@{ @"all" : @YES }];
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidDeleteCacheFilesNotification
                                                            object:self
                                                          userInfo:@{ @"all" : @YES }];
    } else {
        NSArray<NSString*>* removedEpisodeHashes = removedHashes.allObjects;
        if (removedEpisodeHashes.count > 0) {
            NSDictionary* userInfo = @{ @"episodeHashes": removedEpisodeHashes };
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidClearCacheNotification
                                                                object:self
                                                              userInfo:userInfo];
            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidDeleteCacheFilesNotification
                                                                object:self
                                                              userInfo:userInfo];
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidRestoreCacheNotification
                                                            object:self
                                                          userInfo:@{ @"all" : @YES }];
    }
    _cacheClearRemainingURLsByHash = nil;
    _cacheClearRemovedHashes = nil;
    return saveError;
}

- (void)cancelDownloadsAndClearCacheWithCompletion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self cancelDownloadsAndClearCacheWithCompletion:completion];
        });
        return;
    }
    if (_clearingAllCache) {
        if (completion) {
            completion([NSError errorWithDomain:@"CacheManager"
                                            code:21
                                        userInfo:@{NSLocalizedDescriptionKey: @"Downloaded files are already being cleared.".ls}]);
        }
        return;
    }

    _clearingAllCache = YES;
    ICCacheDeletionPreparation* deletionPreparation = [self _prepareForDestructiveCacheClear];
    [deletionPreparation beginPreparation];
    [InstacastBackupImporter prepareForDeferredDownloadClearAllWithCompletion:^(NSError *error) {
        [deletionPreparation finishPreparationWithError:error];
    }];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_cacheDeletionQueue, ^{
        NSError* preparationError = [deletionPreparation waitForPreparation];
        dispatch_async(dispatch_get_main_queue(), ^{
            CacheManager* strongSelf = weakSelf;
            if (!strongSelf) return;
            if (preparationError) {
                NSError* publicError = ICCacheDeletionDurabilityError(preparationError);
                [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidRestoreCacheNotification
                                                                    object:strongSelf
                                                                  userInfo:@{ @"all": @YES }];
                [strongSelf _presentCacheDeletionError:publicError automatic:NO];
                strongSelf->_clearingAllCache = NO;
                if (completion) completion(publicError);
                return;
            }

            [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerWillCommitCacheFileDeletionNotification
                                                                object:strongSelf
                                                              userInfo:@{ @"all": @YES }];
            [strongSelf _commitDestructiveCacheClearPreparation];
            __block id endObserver = nil;
            __block BOOL didBeginDeletion = NO;
            void (^beginDeletion)(void) = ^{
                if (didBeginDeletion) return;
                didBeginDeletion = YES;
                if (endObserver) {
                    [[NSNotificationCenter defaultCenter] removeObserver:endObserver];
                    endObserver = nil;
                }
                [strongSelf _finalizeDestructiveCacheClearJobState];
                dispatch_async(strongSelf->_cacheDeletionQueue, ^{
                    NSError* fileError = [strongSelf _deleteAllCacheFilesNow];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        BOOL shouldClearHistory = strongSelf->_cacheClearSnapshotValid
                            && strongSelf->_cacheClearRemainingURLsByHash.count == 0
                            && strongSelf->_cacheClearRemainingBytes == 0;
                        void (^finishStateClear)(NSError*) = ^(NSError* historyError) {
                            NSError* stateError = [strongSelf _finishDestructiveCacheClear];
                            [strongSelf clearAllDownloadErrorsWithCompletion:^(NSError* failureStateError) {
                                strongSelf->_clearingAllCache = NO;
                                if (completion) completion(fileError ?: stateError ?: historyError ?: failureStateError);
                            }];
                        };
                        if (shouldClearHistory) {
                            [strongSelf.cacheHistory clearWithCompletion:finishStateClear];
                        } else {
                            finishStateClear(nil);
                        }
                    });
                });
            };

            if ([strongSelf isCaching]) {
                endObserver = [[NSNotificationCenter defaultCenter] addObserverForName:CacheManagerDidEndCachingNotification
                                                                                object:strongSelf
                                                                                 queue:NSOperationQueue.mainQueue
                                                                            usingBlock:^(__unused NSNotification* notification) {
                    dispatch_async(dispatch_get_main_queue(), beginDeletion);
                }];
                [strongSelf cancelCaching];
                if (![strongSelf isCaching]) {
                    dispatch_async(dispatch_get_main_queue(), beginDeletion);
                }
            } else {
                beginDeletion();
            }
        });
    });
}

- (void) _removeAllSavedCachingInfos
{
    NSDictionary* defaults = [USER_DEFAULTS dictionaryRepresentation];
    for (NSString* key in defaults) {
        if ([key hasPrefix:ICCachingEpisodeJobKeyPrefix]
            || [key hasPrefix:ICSubscriptionCleanupDeferredDownloadJobKeyPrefix]) {
            [USER_DEFAULTS removeObjectForKey:key];
        }
    }
    [USER_DEFAULTS removeObjectForKey:kUserDefaultsCachingEpisodesKey];
}

- (NSString*) _savedCachingKeyForIdentifier:(NSString*)identifier
{
    return identifier.length > 0 ? [ICCachingEpisodeJobKeyPrefix stringByAppendingString:identifier] : nil;
}

- (void) _persistCachingOperation:(CACHE_OPERATION_CLASS*)operation
{
    NSString* identifier = operation.identifier;
    NSString* key = [self _savedCachingKeyForIdentifier:identifier];
    NSNumber* rank = identifier.length > 0 ? _downloadQueueRanksByIdentifier[identifier] : nil;
    if (!key || !rank) {
        return;
    }
    NSDictionary* info = @{
        @"identifier": identifier,
        @"automatic": @(operation.automatic),
        @"cellular": @(operation.overwriteCellularLock),
        @"reportsFailureToUser": @(operation.reportsFailureToUser),
        @"preservesConsumedState": @(operation.preservesConsumedState),
        @"suspended": @([_manuallySuspendedDownloadIdentifiers containsObject:identifier]),
        @"queueRank": rank,
    };
    [USER_DEFAULTS setObject:info forKey:key];
}

- (void) _removeSavedCachingInfoForIdentifier:(NSString*)identifier
{
    NSString* key = [self _savedCachingKeyForIdentifier:identifier];
    if (key) {
        [USER_DEFAULTS removeObjectForKey:key];
    }
}

- (NSArray<NSDictionary*>*) _savedCachingInfosMigratingLegacyIfNeeded
{
    NSArray* legacyInfos = [USER_DEFAULTS objectForKey:kUserDefaultsCachingEpisodesKey];
    if ([legacyInfos isKindOfClass:[NSArray class]] && legacyInfos.count > 0) {
        NSMutableSet<NSString*>* migratedIdentifiers = [NSMutableSet set];
        long long rank = ICCachingEpisodeRankStep;
        for (NSDictionary* legacyInfo in legacyInfos) {
            if (![legacyInfo isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString* identifier = legacyInfo[@"identifier"];
            if (identifier.length == 0 || [migratedIdentifiers containsObject:identifier]) {
                continue;
            }
            [migratedIdentifiers addObject:identifier];
            NSMutableDictionary* migratedInfo = [legacyInfo mutableCopy];
            migratedInfo[@"queueRank"] = @(rank);
            [USER_DEFAULTS setObject:migratedInfo forKey:[self _savedCachingKeyForIdentifier:identifier]];
            rank += ICCachingEpisodeRankStep;
        }
    }
    [USER_DEFAULTS removeObjectForKey:kUserDefaultsCachingEpisodesKey];

    NSDictionary* defaults = [USER_DEFAULTS dictionaryRepresentation];
    NSMutableArray<NSDictionary*>* savedInfos = [NSMutableArray array];
    long long maximumRank = 0;
    for (NSString* key in defaults) {
        if (![key hasPrefix:ICCachingEpisodeJobKeyPrefix]) {
            continue;
        }
        NSDictionary* info = defaults[key];
        NSString* identifier = [info isKindOfClass:[NSDictionary class]] ? info[@"identifier"] : nil;
        if (identifier.length == 0) {
            [USER_DEFAULTS removeObjectForKey:key];
            continue;
        }
        NSNumber* rank = info[@"queueRank"];
        if ([rank isKindOfClass:[NSNumber class]]) {
            maximumRank = MAX(maximumRank, rank.longLongValue);
        }
        [savedInfos addObject:info];
    }

    for (NSUInteger index = 0; index < savedInfos.count; index++) {
        NSDictionary* info = savedInfos[index];
        if ([info[@"queueRank"] isKindOfClass:[NSNumber class]]) {
            continue;
        }
        maximumRank += ICCachingEpisodeRankStep;
        NSMutableDictionary* repairedInfo = [info mutableCopy];
        repairedInfo[@"queueRank"] = @(maximumRank);
        savedInfos[index] = repairedInfo;
        [USER_DEFAULTS setObject:repairedInfo forKey:[self _savedCachingKeyForIdentifier:repairedInfo[@"identifier"]]];
    }
    return savedInfos;
}

- (NSUInteger)_restoreDownloadsDeferredBySubscriptionCleanup
{
    NSDictionary* defaults = [USER_DEFAULTS dictionaryRepresentation];
    NSMutableArray<NSDictionary*>* infos = [NSMutableArray array];
    for (NSString* key in defaults) {
        if (![key hasPrefix:ICSubscriptionCleanupDeferredDownloadJobKeyPrefix]) continue;
        NSDictionary* info = [defaults[key] isKindOfClass:[NSDictionary class]]
            ? defaults[key] : nil;
        NSString* identifier = info[@"identifier"];
        if (identifier.length == 0) {
            [USER_DEFAULTS removeObjectForKey:key];
            continue;
        }
        [infos addObject:info];
    }
    if (infos.count == 0) return 0;

    NSArray<NSString*>* identifiers = [infos valueForKey:@"identifier"];
    NSArray<CDEpisode*>* episodes = [DMANAGER episodesWithObjectHashes:identifiers];
    NSMutableDictionary<NSString*, CDEpisode*>* episodesByIdentifier =
        [NSMutableDictionary dictionaryWithCapacity:episodes.count];
    for (CDEpisode* episode in episodes) {
        if (episode.objectHash.length > 0) {
            episodesByIdentifier[episode.objectHash] = episode;
        }
    }

    [self willChangeValueForKey:@"cachingEpisodes"];
    NSUInteger restoredCount = 0;
    for (NSDictionary* rawInfo in infos) {
        NSString* identifier = rawInfo[@"identifier"];
        CDEpisode* episode = episodesByIdentifier[identifier];
        if (!episode) {
            if (![InstacastBackupImporter ownsDeferredDownloadWithObjectHash:identifier]) {
                [USER_DEFAULTS removeObjectForKey:
                    [ICSubscriptionCleanupDeferredDownloadJobKeyPrefix
                        stringByAppendingString:identifier]];
            }
            continue;
        }
        NSMutableDictionary* info = [rawInfo mutableCopy];
        NSNumber* rank = info[@"queueRank"];
        if (![rank isKindOfClass:[NSNumber class]]) {
            rank = @(_nextDownloadQueueRank + ICCachingEpisodeRankStep);
            info[@"queueRank"] = rank;
            [USER_DEFAULTS setObject:info
                              forKey:[ICSubscriptionCleanupDeferredDownloadJobKeyPrefix
                                stringByAppendingString:identifier]];
        }
        _nextDownloadQueueRank = MAX(_nextDownloadQueueRank, rank.longLongValue);
        if ([info[@"suspended"] boolValue]) {
            [_manuallySuspendedDownloadIdentifiers addObject:identifier];
        }
        _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier] = [info copy];
        _subscriptionCleanupDeferredDownloadEpisodesByIdentifier[identifier] = episode;
        restoredCount += 1;
    }
    [self didChangeValueForKey:@"cachingEpisodes"];
    if (restoredCount > 0) {
        _subscriptionCleanupPromotionRequested = YES;
    }
    return restoredCount;
}

- (void) restoreCachingEpisodes
{
    if (!_cacheIndexReady) {
        return;
    }
    NSUInteger deferredRestoreCount = [self _restoreDownloadsDeferredBySubscriptionCleanup];
    NSArray<NSDictionary*>* savedInfos = [[self _savedCachingInfosMigratingLegacyIfNeeded]
        sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* left, NSDictionary* right) {
            NSComparisonResult rankOrder = [left[@"queueRank"] compare:right[@"queueRank"]];
            if (rankOrder != NSOrderedSame) {
                return rankOrder;
            }
            return [left[@"identifier"] compare:right[@"identifier"]];
        }];

    _flags.restoringCachingEpisodes = YES;
    if (savedInfos.count > 0) {
        [self willChangeValueForKey:@"cachingEpisodes"];
    }

    NSArray<NSString*>* identifiers = [savedInfos valueForKey:@"identifier"];
    NSArray<CDEpisode*>* savedEpisodes = identifiers.count > 0 ? [DMANAGER episodesWithObjectHashes:identifiers] : @[];
    NSMutableDictionary<NSString*, CDEpisode*>* episodesByIdentifier = [NSMutableDictionary dictionaryWithCapacity:savedEpisodes.count];
    for (CDEpisode* episode in savedEpisodes) {
        if (episode.objectHash.length > 0) {
            episodesByIdentifier[episode.objectHash] = episode;
        }
    }

    for (NSDictionary* info in savedInfos) {
        NSString* identifier = info[@"identifier"];
        BOOL automatic = [info[@"automatic"] boolValue];
        BOOL cellular = [info[@"cellular"] boolValue];
        BOOL preservesConsumedState = [info[@"preservesConsumedState"] boolValue];
        NSNumber* reportsValue = info[@"reportsFailureToUser"];
        BOOL reportsFailureToUser = reportsValue ? reportsValue.boolValue : !automatic;
        if ([info[@"suspended"] boolValue]) {
            [_manuallySuspendedDownloadIdentifiers addObject:identifier];
        }
        CDEpisode* episode = episodesByIdentifier[identifier];
        BOOL restored = episode && [self _cacheEpisode:episode
                                             autoCache:automatic
                               overwriteCellularLock:cellular
                                  reportsFailureToUser:reportsFailureToUser
                                              queueRank:info[@"queueRank"]
                                preservesConsumedState:preservesConsumedState
                         deferDuringSubscriptionCleanup:NO];
        if (!restored) {
            [_manuallySuspendedDownloadIdentifiers removeObject:identifier];
            [self _removeSavedCachingInfoForIdentifier:identifier];
        }
    }

    _flags.restoringCachingEpisodes = NO;
    if (savedInfos.count > 0) {
        [self didChangeValueForKey:@"cachingEpisodes"];
    }
    if (_downloadOperationsByIdentifier.count > 0
        || _subscriptionCleanupDeferredDownloadInfosByIdentifier.count > 0) {
        _currentQueueHadFailure = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidStartCachingNotification object:self];
        [self _startNextDownloadOperations];
        [self _ensureDownloadUpdateTimer];
    } else if (self.suspended) {
        self.suspended = NO;
        [USER_DEFAULTS setBool:NO forKey:ICDownloadQueueSuspended];
    }
    if (deferredRestoreCount > 0) {
        [self _promoteDownloadsDeferredBySubscriptionCleanup];
    }
}

#pragma mark -

static NSComparisonResult ReverseDownloadDateSort(CDEpisode* obj1, CDEpisode* obj2, void *context)
{
    CDFeed* feed1 = obj1.feed;
	CDFeed* feed2 = obj2.feed;
    
    BOOL nm1 = [feed1 boolForKey:AutoDeleteNewsMode];
    BOOL nm2 = [feed2 boolForKey:AutoDeleteNewsMode];
    
    if (nm1 != nm2) {
        return (nm1) ? NSOrderedAscending : NSOrderedDescending;
    }
    
    if (obj1.consumed != obj2.consumed) {
        return (obj1.consumed) ? NSOrderedAscending : NSOrderedDescending;
    }
    
    NSDate* d1 = obj1.lastDownloaded;
    NSDate* d2 = obj2.lastDownloaded;
    
    if (d1 && d2) {
        if ([d1 earlierDate:d2] == d2) {
            return NSOrderedDescending;
        }
        else if ([d1 earlierDate:d2] == d1) {
            return NSOrderedAscending;
        }
    }
    
	
	if (feed1.rank < feed2.rank) {
		return NSOrderedDescending;
	}
	else if (feed1.rank > feed2.rank) {
		return NSOrderedAscending;
	}
    
    if ([obj1.pubDate earlierDate:obj2.pubDate] == obj2.pubDate) {
		return NSOrderedDescending;
	}
	else if ([obj1.pubDate earlierDate:obj2.pubDate] == obj1.pubDate) {
		return NSOrderedAscending;
	}
	
	return NSOrderedSame;
}

- (void) autoClearAndMakeRoomForBytes:(unsigned long long)bytes automatic:(BOOL)automatic
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self autoClearAndMakeRoomForBytes:bytes automatic:automatic];
        });
        return;
    }
    if (_clearingAllCache) return;
    unsigned long long maxAllowedBytes = (unsigned long long)[USER_DEFAULTS integerForKey:AutoCacheStorageLimit]*1024LLU*1024LLU;
    if (maxAllowedBytes == 0) {
        _hasPendingAutoClear = NO;
        _pendingAutoClearBytes = 0;
        return;
    }

    if (_autoClearSelectionInFlight) {
        [self _recordPendingAutoClearBytes:bytes automatic:automatic];
        return;
    }
    if (!_downloadedBytesKnown) {
        [self _recordPendingAutoClearBytes:bytes automatic:automatic];
        [self recalculateDownloadedBytesInBackground];
        return;
    }

    unsigned long long loadedBytes = [self numberOfDownloadedBytes];
    if (loadedBytes <= maxAllowedBytes && bytes <= maxAllowedBytes - loadedBytes) {
        return;
    }

    unsigned long long requestedBytes = ULLONG_MAX - loadedBytes < bytes ? ULLONG_MAX : loadedBytes + bytes;
    unsigned long long spaceToDelete = requestedBytes - maxAllowedBytes;
    NSMutableSet<NSString*>* excludedHashes = [NSMutableSet setWithArray:_cacheDeletionTokensByIdentifier.allKeys];
    [excludedHashes addObjectsFromArray:_cacheImportTokensByIdentifier.allKeys];
    _autoClearSelectionInFlight = YES;
    dispatch_async(_cacheDeletionQueue, ^{
        NSFileManager* fileManager = [[NSFileManager alloc] init];
        NSString* storagePath = [CacheManager _pathToStorageLocation];
        NSError* directoryError = nil;
        NSArray<NSString*>* directoryContent = [fileManager contentsOfDirectoryAtPath:storagePath error:&directoryError];
        if (!directoryContent && ICCacheFileErrorMeansMissing(directoryError)) {
            directoryContent = @[];
            directoryError = nil;
        }

        NSMutableDictionary<NSString*, NSURL*>* URLsByEpisodeHash = [NSMutableDictionary dictionary];
        if (directoryContent) {
            for (NSString* filename in directoryContent) {
                NSString* nameWithoutExtension = filename.stringByDeletingPathExtension;
                NSRange lastSeparator = [nameWithoutExtension rangeOfString:@" - " options:NSBackwardsSearch];
                NSString* identifier = lastSeparator.location == NSNotFound
                    ? nameWithoutExtension
                    : [nameWithoutExtension substringFromIndex:NSMaxRange(lastSeparator)];
                if (identifier.length > 0 && ![excludedHashes containsObject:identifier]) {
                    URLsByEpisodeHash[identifier] = [NSURL fileURLWithPath:[storagePath stringByAppendingPathComponent:filename]];
                }
            }
        }

        __block NSError* selectionError = directoryError;
        __block NSArray<NSDictionary*>* selectionItems = @[];
        NSManagedObjectContext* context = selectionError ? nil : [DMANAGER newBackgroundContext];
        if (!selectionError && !context) {
            selectionError = [NSError errorWithDomain:@"CacheManager"
                                                  code:50
                                              userInfo:@{NSLocalizedDescriptionKey: @"The download database was not available for automatic storage cleanup.".ls}];
        }
        if (context) {
            [context performBlockAndWait:^{
                NSMutableArray<CDEpisode*>* loadedEpisodes = [NSMutableArray array];
                NSArray<NSString*>* episodeHashes = URLsByEpisodeHash.allKeys;
                const NSUInteger fetchBatchSize = 400;
                for (NSUInteger offset = 0; offset < episodeHashes.count; offset += fetchBatchSize) {
                    NSRange range = NSMakeRange(offset, MIN(fetchBatchSize, episodeHashes.count - offset));
                    NSArray<NSString*>* hashBatch = [episodeHashes subarrayWithRange:range];
                    NSFetchRequest* request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                    request.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", hashBatch];
                    request.relationshipKeyPathsForPrefetching = @[@"feed", @"feed.properties"];
                    NSError* fetchError = nil;
                    NSArray<CDEpisode*>* fetchedEpisodes = [context executeFetchRequest:request error:&fetchError];
                    if (!fetchedEpisodes) {
                        selectionError = fetchError;
                        break;
                    }
                    [loadedEpisodes addObjectsFromArray:fetchedEpisodes];
                }
                if (selectionError) return;

                NSArray<CDEpisode*>* sortedEpisodes = [loadedEpisodes sortedArrayUsingFunction:ReverseDownloadDateSort
                                                                                       context:NULL];
                NSMutableArray<NSDictionary*>* items = [NSMutableArray arrayWithCapacity:sortedEpisodes.count];
                NSMutableSet<NSString*>* seenIdentifiers = [NSMutableSet setWithCapacity:sortedEpisodes.count];
                for (CDEpisode* episode in sortedEpisodes) {
                    NSString* identifier = episode.objectHash;
                    NSURL* URL = identifier.length > 0 ? URLsByEpisodeHash[identifier] : nil;
                    if (episode.starred || !URL || episode.objectID.isTemporaryID || [seenIdentifiers containsObject:identifier]) {
                        continue;
                    }
                    [seenIdentifiers addObject:identifier];
                    [items addObject:@{ @"objectID": episode.objectID, @"url": URL }];
                }
                selectionItems = [items copy];
            }];
        }

        if (selectionError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_autoClearSelectionInFlight = NO;
                [self _recordPendingAutoClearBytes:bytes automatic:automatic];
                [[ICDiagnosticLogger shared] logEvent:@"cache"
                                              message:@"Automatische Download-Auswahl konnte nicht geladen werden"
                                             metadata:@{ @"error": selectionError.localizedDescription ?: @"" }];
            });
            return;
        }

        BOOL needsRecalculation = NO;
        NSArray<NSManagedObjectID*>* selectedObjectIDs = [self _autoClearSelectionFromItems:selectionItems
                                                                              bytesToDelete:spaceToDelete
                                                                         needsRecalculation:&needsRecalculation];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_clearingAllCache) {
                self->_autoClearSelectionInFlight = NO;
                return;
            }
            NSMutableArray<CDEpisode*>* selectedEpisodes = [NSMutableArray arrayWithCapacity:selectedObjectIDs.count];
            for (NSManagedObjectID* objectID in selectedObjectIDs) {
                NSError* objectError = nil;
                CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:objectID error:&objectError];
                if (!objectError && [episode isKindOfClass:[CDEpisode class]] && !episode.isDeleted) {
                    [selectedEpisodes addObject:episode];
                }
            }
            self->_autoClearSelectionInFlight = NO;
            if (selectedEpisodes.count > 0) {
                if (needsRecalculation) {
                    [self _recordPendingAutoClearBytes:bytes automatic:automatic];
                    [self _invalidateDownloadedBytesAndRecalculate];
                }
                [self removeCacheForEpisodes:selectedEpisodes automatic:automatic completion:nil];
            } else if (needsRecalculation) {
                [self _recordPendingAutoClearBytes:bytes automatic:automatic];
                [self _invalidateDownloadedBytesAndRecalculate];
            }
        });
    });
}

- (void)_recordPendingAutoClearBytes:(unsigned long long)bytes automatic:(BOOL)automatic
{
    _pendingAutoClearAutomatic = _hasPendingAutoClear ? (_pendingAutoClearAutomatic && automatic) : automatic;
    _hasPendingAutoClear = YES;
    _pendingAutoClearBytes = MAX(_pendingAutoClearBytes, bytes);
}

- (NSArray<NSManagedObjectID*>*)_autoClearSelectionFromItems:(NSArray<NSDictionary*>*)items
                                               bytesToDelete:(unsigned long long)bytesToDelete
                                          needsRecalculation:(BOOL*)needsRecalculation
{
    NSFileManager* fileManager = [[NSFileManager alloc] init];
    NSMutableArray<NSManagedObjectID*>* selectedObjectIDs = [NSMutableArray array];
    unsigned long long remainingBytes = bytesToDelete;
    BOOL requiresRecalculation = NO;
    for (NSDictionary* item in items) {
        NSError* attributesError = nil;
        NSDictionary* attributes = [fileManager attributesOfItemAtPath:[item[@"url"] path] error:&attributesError];
        if (!attributes) {
            requiresRecalculation = YES;
            if (!ICCacheFileErrorMeansMissing(attributesError)) {
                [selectedObjectIDs addObject:item[@"objectID"]];
                break;
            }
            continue;
        }
        [selectedObjectIDs addObject:item[@"objectID"]];
        unsigned long long fileSize = [attributes fileSize];
        remainingBytes -= MIN(fileSize, remainingBytes);
        if (remainingBytes == 0) break;
    }
    if (needsRecalculation) *needsRecalculation = requiresRecalculation;
    return [selectedObjectIDs copy];
}

#pragma mark - NSURLSession

- (NSDictionary*) savedCachingInfoForIdentifier:(NSString*)identifier
{
    NSString* key = [self _savedCachingKeyForIdentifier:identifier];
    NSDictionary* info = key ? [USER_DEFAULTS objectForKey:key] : nil;
    if (![info isKindOfClass:[NSDictionary class]] && [USER_DEFAULTS objectForKey:kUserDefaultsCachingEpisodesKey]) {
        [self _savedCachingInfosMigratingLegacyIfNeeded];
        info = key ? [USER_DEFAULTS objectForKey:key] : nil;
    }
    return [info isKindOfClass:[NSDictionary class]] ? info : nil;
}

- (void) _completeBackgroundSessionForIdentifier:(NSString*)identifier
{
    if (identifier.length == 0) {
        return;
    }
    void (^completionHandler)(void) = _backgroundSessionCompletionHandlers[identifier];
    if (!completionHandler) {
        return;
    }
    [_backgroundSessionCompletionHandlers removeObjectForKey:identifier];
    completionHandler();
}

- (void) _cancelOrphanedBackgroundSession:(NSString*)identifier
{
    if (identifier.length == 0 || _orphanedBackgroundSessionsByIdentifier[identifier]) {
        return;
    }
    NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:configuration
                                                          delegate:self
                                                     delegateQueue:NSOperationQueue.mainQueue];
    _orphanedBackgroundSessionsByIdentifier[identifier] = session;
    [session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask*>* dataTasks,
                                             NSArray<NSURLSessionUploadTask*>* uploadTasks,
                                             NSArray<NSURLSessionDownloadTask*>* downloadTasks) {
        for (NSURLSessionTask* task in dataTasks) {
            [task cancel];
        }
        for (NSURLSessionTask* task in uploadTasks) {
            [task cancel];
        }
        for (NSURLSessionTask* task in downloadTasks) {
            [task cancel];
        }
        [session invalidateAndCancel];
    }];
}

- (void) URLSession:(NSURLSession*)session didBecomeInvalidWithError:(NSError*)error
{
    NSString* identifier = session.configuration.identifier;
    if (identifier.length == 0 || _orphanedBackgroundSessionsByIdentifier[identifier] != session) {
        return;
    }
    [_orphanedBackgroundSessionsByIdentifier removeObjectForKey:identifier];
    if (error) {
        ErrLog(@"orphaned background download session %@ ended with error: %@", identifier, error);
    }
    BOOL wasDeferredCleanupCancellation =
        [_subscriptionCleanupBackgroundSessionCancellationIdentifiers containsObject:identifier];
    [_subscriptionCleanupBackgroundSessionCancellationIdentifiers removeObject:identifier];
    [self _completeBackgroundSessionForIdentifier:identifier];
    if (wasDeferredCleanupCancellation) {
        [self _resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil];
    }
}

- (void) handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler
{
    if (identifier.length == 0) {
        completionHandler();
        return;
    }
    _backgroundSessionCompletionHandlers[identifier] = [completionHandler copy];
    CACHE_OPERATION_CLASS* foundOperation = _downloadOperationsByIdentifier[identifier];
    if (!foundOperation) {
        NSDictionary* deferredInfo =
            _subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier];
        if (!deferredInfo) {
            NSString* deferredKey = [ICSubscriptionCleanupDeferredDownloadJobKeyPrefix
                stringByAppendingString:identifier];
            deferredInfo = [USER_DEFAULTS objectForKey:deferredKey];
        }
        if ([deferredInfo isKindOfClass:[NSDictionary class]]) {
            [_subscriptionCleanupBackgroundSessionCancellationIdentifiers addObject:identifier];
            [self _cancelOrphanedBackgroundSession:identifier];
            return;
        }
    }
    
    if (!foundOperation) {
        NSDictionary* savedInfo = [self savedCachingInfoForIdentifier:identifier];
        if (!savedInfo) {
            [self _cancelOrphanedBackgroundSession:identifier];
            return;
        }
        CDEpisode* episode = [DMANAGER episodeWithObjectHash:identifier];
        BOOL automatic = [savedInfo[@"automatic"] boolValue];
        BOOL cellular = [savedInfo[@"cellular"] boolValue];
        BOOL preservesConsumedState = [savedInfo[@"preservesConsumedState"] boolValue];
        NSNumber* reportsValue = savedInfo[@"reportsFailureToUser"];
        BOOL reportsFailureToUser = reportsValue ? reportsValue.boolValue : !automatic;
        if ([savedInfo[@"suspended"] boolValue]) {
            [_manuallySuspendedDownloadIdentifiers addObject:identifier];
        }
        if (episode) {
            [self _cacheEpisode:episode
                     autoCache:automatic
       overwriteCellularLock:cellular
          reportsFailureToUser:reportsFailureToUser
                      queueRank:savedInfo[@"queueRank"]
        preservesConsumedState:preservesConsumedState
 deferDuringSubscriptionCleanup:NO];
        }
        if (!_downloadOperationsByIdentifier[identifier]) {
            if (_subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier]) {
                [_subscriptionCleanupBackgroundSessionCancellationIdentifiers addObject:identifier];
                [self _cancelOrphanedBackgroundSession:identifier];
                return;
            }
            [_manuallySuspendedDownloadIdentifiers removeObject:identifier];
            [self _removeSavedCachingInfoForIdentifier:identifier];
            [self _cancelOrphanedBackgroundSession:identifier];
        }
    }
}

#pragma mark -

- (void) importFileAtURL:(NSURL*)url forEpisode:(CDEpisode*)episode completion:(void (^)(BOOL success, NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self importFileAtURL:url forEpisode:episode completion:completion];
        });
        return;
    }
    if (!url || !episode) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil]);
        }
        return;
    }
    if (_clearingAllCache) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CacheManager"
                                                 code:40
                                             userInfo:@{NSLocalizedDescriptionKey: @"The file cannot be imported while downloaded files are being cleared.".ls}]);
        }
        return;
    }

    NSString* identifier = episode.objectHash;
    if (identifier.length == 0) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CacheManager"
                                                 code:36
                                             userInfo:@{NSLocalizedDescriptionKey: @"The file could not be imported because the episode identifier is missing.".ls}]);
        }
        return;
    }
    if (_cacheImportTokensByIdentifier[identifier]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CacheManager"
                                                 code:37
                                             userInfo:@{NSLocalizedDescriptionKey: @"A file is already being imported for this episode.".ls}]);
        }
        return;
    }
    if (_cacheDeletionTokensByIdentifier[identifier] || [self episodeIsCached:episode]) {
        [self removeCacheForEpisode:episode automatic:NO completion:^(NSError* removalError) {
            if (removalError) {
                if (completion) completion(NO, removalError);
                return;
            }
            [self _importFileAtURL:url
                        forEpisode:episode
                streamingLeaseToken:nil
                        movesSource:NO
                        completion:completion];
        }];
        return;
    }

    if ([self isCachingSourceOfEpisode:episode]) {
        [self cancelCachingEpisode:episode disableAutoDownload:NO];
    }
    [self _importFileAtURL:url
                forEpisode:episode
        streamingLeaseToken:nil
                movesSource:NO
                completion:completion];
}

- (void) importStreamingFileAtURL:(NSURL*)url
                       forEpisode:(CDEpisode*)episode
                       leaseToken:(NSString*)leaseToken
                       completion:(void (^)(BOOL success, NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self importStreamingFileAtURL:url
                                forEpisode:episode
                                leaseToken:leaseToken
                                completion:completion];
        });
        return;
    }

    NSString* identifier = episode.objectHash;
    BOOL leaseIsCurrent = identifier.length > 0 &&
        [_streamingCacheLeaseTokensByIdentifier[identifier] isEqualToString:leaseToken];
    if (!url || !episode || !leaseIsCurrent || _clearingAllCache || _cacheDeletionTokensByIdentifier[identifier]) {
        NSError* supersededError = [NSError errorWithDomain:@"CacheManager"
                                                        code:42
                                                    userInfo:@{NSLocalizedDescriptionKey: @"The streaming cache was superseded before its file could be imported.".ls}];
        if (url) {
            dispatch_async(_cacheDeletionQueue, ^{
                NSFileManager* fileManager = [[NSFileManager alloc] init];
                [fileManager removeItemAtURL:url error:nil];
                [fileManager removeItemAtURL:url.URLByDeletingLastPathComponent error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, supersededError);
                });
            });
        } else if (completion) {
            completion(NO, supersededError);
        }
        return;
    }
    if (_cacheImportTokensByIdentifier[identifier]) {
        NSError* supersededError = [NSError errorWithDomain:@"CacheManager"
                                                        code:42
                                                    userInfo:@{NSLocalizedDescriptionKey: @"The streaming cache was superseded by another file import.".ls}];
        dispatch_async(_cacheDeletionQueue, ^{
            NSFileManager* fileManager = [[NSFileManager alloc] init];
            [fileManager removeItemAtURL:url error:nil];
            [fileManager removeItemAtURL:url.URLByDeletingLastPathComponent error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, supersededError);
            });
        });
        return;
    }

    [self _importFileAtURL:url
                forEpisode:episode
        streamingLeaseToken:leaseToken
                movesSource:YES
                completion:completion];
}

- (void)_importFileAtURL:(NSURL*)url
              forEpisode:(CDEpisode*)episode
      streamingLeaseToken:(NSString*)streamingLeaseToken
              movesSource:(BOOL)movesSource
              completion:(void (^)(BOOL success, NSError* error))completion
{
    NSString* identifier = episode.objectHash;
    NSURL* cachedURL = [self URLForCachedEpisode:episode];
    if (identifier.length == 0 || !cachedURL) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"CacheManager"
                                                 code:38
                                             userInfo:@{NSLocalizedDescriptionKey: @"The file import location could not be created on this device.".ls}]);
        }
        return;
    }

    NSString* importToken = NSUUID.UUID.UUIDString;
    NSUInteger importGeneration = _cacheIndexGeneration;
    _cacheImportTokensByIdentifier[identifier] = importToken;
    _cachedURLIndex[identifier] = cachedURL;
    dispatch_async(_cacheDeletionQueue, ^{
        NSFileManager* fman = [[NSFileManager alloc] init];
        NSError* error = nil;
        NSDictionary* sourceAttributes = movesSource ? [fman attributesOfItemAtPath:url.path error:&error] : nil;
        unsigned long long sourceFileSize = [sourceAttributes fileSize];
        BOOL sourceIsRegularFile = !movesSource ||
            ([sourceAttributes[NSFileType] isEqualToString:NSFileTypeRegular] && sourceFileSize > 0);
        if (!sourceIsRegularFile && !error) {
            error = [NSError errorWithDomain:@"CacheManager"
                                        code:48
                                    userInfo:@{NSLocalizedDescriptionKey: @"The downloaded episode file is empty.".ls}];
        }
        BOOL destinationAlreadyExists = movesSource && [fman fileExistsAtPath:cachedURL.path];
        BOOL existingDestinationIsComplete = NO;
        BOOL createdDestination = NO;

        if (sourceIsRegularFile && destinationAlreadyExists) {
            NSDictionary* destinationAttributes = [fman attributesOfItemAtPath:cachedURL.path error:&error];
            unsigned long long destinationFileSize = [destinationAttributes fileSize];
            existingDestinationIsComplete =
                [destinationAttributes[NSFileType] isEqualToString:NSFileTypeRegular] &&
                destinationFileSize > 0 &&
                destinationFileSize == sourceFileSize;
            if (!existingDestinationIsComplete) {
                error = nil;
                NSURL* resultingURL = nil;
                createdDestination = [fman replaceItemAtURL:cachedURL
                                              withItemAtURL:url
                                             backupItemName:nil
                                                    options:NSFileManagerItemReplacementUsingNewMetadataOnly
                                           resultingItemURL:&resultingURL
                                                      error:&error];
            }
        } else if (sourceIsRegularFile) {
            createdDestination = movesSource
                ? [fman moveItemAtURL:url toURL:cachedURL error:&error]
                : [fman copyItemAtURL:url toURL:cachedURL error:&error];
        }

        BOOL success = createdDestination || existingDestinationIsComplete;
        unsigned long long importedFileSize = success ? [[fman attributesOfItemAtPath:cachedURL.path error:nil] fileSize] : 0;
        if (success) {
            error = nil;
        }
        if (movesSource && !createdDestination) [fman removeItemAtURL:url error:nil];
        if (movesSource) {
            [fman removeItemAtURL:url.URLByDeletingLastPathComponent error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL tokenIsCurrent = [self->_cacheImportTokensByIdentifier[identifier] isEqualToString:importToken];
            BOOL streamingLeaseIsCurrent = streamingLeaseToken.length == 0 ||
                [self->_streamingCacheLeaseTokensByIdentifier[identifier] isEqualToString:streamingLeaseToken];
            BOOL canPublish = tokenIsCurrent &&
                streamingLeaseIsCurrent &&
                importGeneration == self->_cacheIndexGeneration &&
                !self->_cacheDeletionTokensByIdentifier[identifier] &&
                !self->_clearingAllCache &&
                !episode.isDeleted && episode.managedObjectContext != nil;
            if (tokenIsCurrent) {
                [self->_cacheImportTokensByIdentifier removeObjectForKey:identifier];
                if (self->_subscriptionCleanupDeferredDownloadInfosByIdentifier[identifier]) {
                    [self _resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil];
                }
            }

            NSError* completionError = error;
            if (success && !canPublish) {
                completionError = [NSError errorWithDomain:@"CacheManager"
                                                       code:(streamingLeaseToken.length > 0 ? 42 : 39)
                                                   userInfo:@{NSLocalizedDescriptionKey: streamingLeaseToken.length > 0
                                                       ? @"The streaming cache was superseded before its file could be imported.".ls
                                                       : @"The file import was cancelled because the download was removed.".ls}];
            }

            if (success && canPublish) {
                self->_cachedURLIndex[identifier] = cachedURL;
                if (movesSource) {
                    [self _invalidateDownloadedBytesAndRecalculate];
                } else {
                    [self _addDownloadedBytes:importedFileSize];
                }
                [self clearDownloadErrorForEpisode:episode];
                [self willChangeValueForKey:@"cachedEpisodes"];

                for (CDEpisode* cachedEpisode in [self->_cachedEpisodes copy]) {
                    if ([cachedEpisode.objectHash isEqualToString:identifier]) {
                        [self->_cachedEpisodes removeObject:cachedEpisode];
                    }
                }
                [self->_cachedEpisodes addObject:episode];
                [self didChangeValueForKey:@"cachedEpisodes"];

                @try {
                    episode.lastDownloaded = [NSDate date];
                    episode.downloaded = YES;
                }
                @catch (NSException *exception) {
                    ErrLog(@"could not update episode download flags: %@", exception);
                }

                [DMANAGER save];

                [[NSNotificationCenter defaultCenter] postNotificationName:CacheManagerDidFinishCachingEpisodeNotification
                                                                    object:self
                                                                  userInfo:@{@"episode": episode}];
            } else if (tokenIsCurrent && [self->_cachedURLIndex[identifier] isEqual:cachedURL]) {
                [self->_cachedURLIndex removeObjectForKey:identifier];
            }

            if (createdDestination && success && !canPublish) {
                dispatch_async(self->_cacheDeletionQueue, ^{
                    [[NSFileManager defaultManager] removeItemAtURL:cachedURL error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self _invalidateDownloadedBytesAndRecalculate];
                        if (completion) completion(NO, completionError);
                    });
                });
            } else if (completion) {
                if (movesSource && !(success && canPublish)) {
                    [self _invalidateDownloadedBytesAndRecalculate];
                }
                completion(success && canPublish, completionError);
            }
        });
    });
    
    
    
}
@end
