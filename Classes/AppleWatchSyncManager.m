//
//  AppleWatchSyncManager.m
//  Instacast
//

#import "AppleWatchSyncManager.h"
#import "CDModel.h"
#import "DatabaseManager.h"
#import "PlaybackManager.h"
#import "AudioSession.h"
#import "ICAppearanceManager.h"
#import "InstacastPlus-Swift.h"

#import <TargetConditionals.h>

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
@import WatchConnectivity;
#define IC_WATCH_CONNECTIVITY_ENABLED 1
#else
#define IC_WATCH_CONNECTIVITY_ENABLED 0
#endif

NSString* const ICAppleWatchSyncManagerStateDidChangeNotification = @"ICAppleWatchSyncManagerStateDidChangeNotification";
NSString* const ICAppleWatchEpisodeStatesDidChangeNotification = @"ICAppleWatchEpisodeStatesDidChangeNotification";
NSString* const ICAppleWatchLiveStatusDidChangeNotification = @"ICAppleWatchLiveStatusDidChangeNotification";
NSString* const ICAppleWatchChangedEpisodeHashesUserInfoKey = @"episodeHashes";

static NSString* const ICAppleWatchMessageTypeKey = @"type";
static NSString* const ICAppleWatchManifestReplace = @"manifest.replace";
static NSString* const ICAppleWatchManifestFileAvailable = @"manifest.fileAvailable";
static NSString* const ICAppleWatchManifestRemoveEpisodes = @"manifest.removeEpisodes";
static NSString* const ICAppleWatchDownloadPrioritize = @"download.prioritize";
static NSString* const ICAppleWatchPlaybackPhoneState = @"playback.phoneState";
static NSString* const ICAppleWatchSuppressedAutomaticEpisodeHashesKey = @"ICAppleWatchSuppressedAutomaticEpisodeHashes";
static NSString* const ICAppleWatchManifestRevisionKey = @"ICAppleWatchManifestRevision";
static NSString* const ICAppleWatchPendingManifestRevisionKey = @"ICAppleWatchPendingManifestRevision";
static NSString* const ICAppleWatchReceivedManifestAcknowledgementRevisionKey = @"ICAppleWatchReceivedManifestAcknowledgementRevision";
static NSString* const ICAppleWatchManifestTransferDirectoryName = @"AppleWatchManifestTransfers";
static NSString* const ICAppleWatchManifestProtocolVersionFilename = @"InstacastManifestProtocolVersion";
static NSString* const ICAppleWatchDeletionInboxDirectoryName = @"PendingWatchDeletionEvents";
static const NSUInteger ICAppleWatchEpisodeFetchBatchSize = 400;
static const NSUInteger ICAppleWatchAutomaticFetchPageSize = 50;
static const NSUInteger ICAppleWatchAutomaticApplyBatchSize = 50;
static const NSUInteger ICAppleWatchStateWriteBatchSize = 50;
static const NSUInteger ICAppleWatchMaximumDeletionAcknowledgementCount = 200;
static const NSUInteger ICAppleWatchMaximumDeletionInboxPayloadBytes = 256 * 1024;
static const NSInteger ICAppleWatchWatchEventProtocolVersion = 2;
enum { ICAppleWatchManifestReadBufferSize = 64 * 1024 };
static const NSUInteger ICAppleWatchMaximumManifestEntryCount = 10000;
static const unsigned long long ICAppleWatchMaximumManifestFileSize = 16ull * 1024ull * 1024ull;
static NSString* const ICAppleWatchTransferLoadedBytesKey = @"loadedBytes";
static NSString* const ICAppleWatchTransferTotalBytesKey = @"totalBytes";
static NSString* const ICAppleWatchTransferTotalKnownKey = @"totalKnown";
static NSString* const ICAppleWatchTransferPhaseKey = @"phase";

static BOOL ICAppleWatchIsOrderedDownloadEventType(NSString* type)
{
    return [type isEqualToString:@"watch.downloadQueued"] ||
           [type isEqualToString:@"watch.downloadProgress"] ||
           [type isEqualToString:@"watch.downloaded"] ||
           [type isEqualToString:@"watch.downloadFailed"] ||
           [type isEqualToString:@"watch.downloadEvicted"];
}

static NSError* ICAppleWatchManifestFileError(NSInteger code)
{
    return [NSError errorWithDomain:@"AppleWatchSync"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch manifest could not be prepared. Check the available storage and try again.".ls}];
}

static NSComparisonResult ICCompareAppleWatchEpisodeStates(AppleWatchEpisodeState* first,
                                                           AppleWatchEpisodeState* second)
{
    NSDate* firstDate = first.watchAddedDate ?: NSDate.distantPast;
    NSDate* secondDate = second.watchAddedDate ?: NSDate.distantPast;
    NSComparisonResult dateOrder = [secondDate compare:firstDate];
    if (dateOrder != NSOrderedSame) return dateOrder;

    NSComparisonResult hashOrder = [(first.episodeHash ?: @"") compare:(second.episodeHash ?: @"")];
    if (hashOrder != NSOrderedSame) return hashOrder;

    if (first.watchLastEventRevision != second.watchLastEventRevision) {
        return first.watchLastEventRevision > second.watchLastEventRevision ? NSOrderedAscending : NSOrderedDescending;
    }
    if (first.removingFromWatch != second.removingFromWatch) {
        return first.removingFromWatch ? NSOrderedAscending : NSOrderedDescending;
    }

    NSComparisonResult uidOrder = [(first.uid ?: @"") compare:(second.uid ?: @"")];
    if (uidOrder != NSOrderedSame) return uidOrder;
    NSString* firstObjectID = first.objectID.URIRepresentation.absoluteString ?: @"";
    NSString* secondObjectID = second.objectID.URIRepresentation.absoluteString ?: @"";
    return [firstObjectID compare:secondObjectID];
}

static NSData* ICAppleWatchManifestNewlineData(void)
{
    static NSData* data = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        static const uint8_t newline = '\n';
        data = [NSData dataWithBytes:&newline length:1];
    });
    return data;
}

static BOOL ICWriteDataToOutputStream(NSOutputStream* stream, NSData* data, NSError** error)
{
    const uint8_t* bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        NSInteger written = [stream write:bytes + offset maxLength:data.length - offset];
        if (written <= 0) {
            if (error) {
                *error = stream.streamError ?: ICAppleWatchManifestFileError(10);
            }
            return NO;
        }
        offset += (NSUInteger)written;
    }
    return YES;
}

static BOOL ICWriteJSONObjectLine(NSOutputStream* stream, NSDictionary* object, NSError** error)
{
    NSData* data = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (!data || !ICWriteDataToOutputStream(stream, data, error)) {
        return NO;
    }
    return ICWriteDataToOutputStream(stream, ICAppleWatchManifestNewlineData(), error);
}

static BOOL ICProcessJSONLine(NSData* lineData,
                              NSUInteger lineIndex,
                              BOOL (^handler)(NSDictionary* object, NSUInteger lineIndex, NSError** error),
                              NSError** error)
{
    if (lineData.length == 0) {
        if (error) *error = ICAppleWatchManifestFileError(11);
        return NO;
    }
    id object = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error && !*error) *error = ICAppleWatchManifestFileError(12);
        return NO;
    }
    return handler(object, lineIndex, error);
}

static BOOL ICEnumerateJSONLinesAtURL(NSURL* fileURL,
                                      BOOL (^handler)(NSDictionary* object, NSUInteger lineIndex, NSError** error),
                                      NSError** error)
{
    NSInputStream* stream = [NSInputStream inputStreamWithURL:fileURL];
    if (!stream) {
        if (error) *error = ICAppleWatchManifestFileError(13);
        return NO;
    }
    [stream open];
    NSMutableData* pendingData = [NSMutableData data];
    uint8_t buffer[ICAppleWatchManifestReadBufferSize];
    NSUInteger lineIndex = 0;
    BOOL success = YES;
    while (success) {
        NSInteger readCount = [stream read:buffer maxLength:sizeof(buffer)];
        if (readCount < 0) {
            if (error) *error = stream.streamError ?: ICAppleWatchManifestFileError(14);
            success = NO;
            break;
        }
        if (readCount == 0) {
            break;
        }
        [pendingData appendBytes:buffer length:(NSUInteger)readCount];
        while (YES) {
            NSRange newlineRange = [pendingData rangeOfData:ICAppleWatchManifestNewlineData()
                                                    options:0
                                                      range:NSMakeRange(0, pendingData.length)];
            if (newlineRange.location == NSNotFound) {
                break;
            }
            NSData* lineData = [pendingData subdataWithRange:NSMakeRange(0, newlineRange.location)];
            [pendingData replaceBytesInRange:NSMakeRange(0, NSMaxRange(newlineRange)) withBytes:NULL length:0];
            if (!ICProcessJSONLine(lineData, lineIndex, handler, error)) {
                success = NO;
                break;
            }
            lineIndex += 1;
        }
    }
    if (success && pendingData.length > 0) {
        success = ICProcessJSONLine(pendingData, lineIndex, handler, error);
        lineIndex += success ? 1 : 0;
    }
    if (success && lineIndex == 0) {
        if (error) *error = ICAppleWatchManifestFileError(15);
        success = NO;
    }
    [stream close];
    return success;
}

@interface AppleWatchSyncManager ()
#if IC_WATCH_CONNECTIVITY_ENABLED
<WCSessionDelegate>
#endif

@property (nonatomic, readwrite) BOOL supported;
@property (nonatomic, readwrite) BOOL paired;
@property (nonatomic, readwrite) BOOL watchAppInstalled;
@property (nonatomic, readwrite) BOOL reachable;
@property (nonatomic, strong, readwrite) NSDate* lastSyncDate;
@property (nonatomic, strong, readwrite) NSDate* lastWatchStatusDate;
@property (nonatomic, readwrite) int64_t watchFreeBytes;
@property (nonatomic, readwrite) int64_t watchUsedBytes;
@property (nonatomic, readwrite) int64_t watchTotalBytes;
@property (nonatomic, readwrite) int64_t watchDownloadBytes;
@property (nonatomic, copy, readwrite) NSString* currentWatchDownloadTitle;
@property (nonatomic, copy) NSString* currentWatchDownloadHash;
@property (nonatomic, readwrite) int64_t currentWatchDownloadedBytes;
@property (nonatomic, readwrite) int64_t currentWatchExpectedBytes;
// Per-episode live progress from watch.downloadProgress, keyed by episodeHash. Basis for the
// aggregated "x MB von TOTAL MB" status instead of the per-download value that flipped between
// episodes (User-Feedback 05.07.).
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* watchDownloadProgressByHash;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* watchTransferContributionByHash;
@property (nonatomic) BOOL watchTransferSnapshotValid;
@property (nonatomic) int64_t cachedWatchTransferLoadedBytes;
@property (nonatomic) int64_t cachedWatchTransferTotalBytes;
@property (nonatomic) NSInteger cachedWatchTransferUnknownTotalCount;
@property (nonatomic) NSInteger cachedWatchTransferWaitingCount;
@property (nonatomic) NSInteger cachedWatchTransferDownloadingCount;
@property (nonatomic) NSInteger cachedWatchStorageEvictedCount;
@property (nonatomic) NSInteger cachedWatchDownloadedCount;
@property (nonatomic, strong) NSMutableSet<NSString*>* pendingLiveStatusEpisodeHashes;
@property (nonatomic) BOOL pendingGlobalLiveStatusChange;
@property (nonatomic) BOOL liveStatusNotificationScheduled;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL needsManifestSyncAfterActivation;
@property (nonatomic) dispatch_queue_t automaticSelectionQueue;
@property (nonatomic) NSUInteger automaticSelectionGeneration;
@property (nonatomic) dispatch_queue_t manifestBuildQueue;
@property (nonatomic) dispatch_queue_t watchDeletionInboxQueue;
@property (nonatomic) NSUInteger manifestBuildGeneration;
@property (nonatomic) BOOL manifestDeliveryInProgress;
@property (nonatomic) BOOL manifestBuildRequestedAfterDelivery;
@property (nonatomic) int64_t manifestAcknowledgementRevisionInProgress;
@property (nonatomic) NSInteger watchManifestProtocolVersion;
@property (nonatomic) int64_t legacyManifestRevisionAwaitingResult;
@property (nonatomic) BOOL watchDeletionInboxProcessing;
@property (nonatomic) BOOL watchDeletionInboxProcessingRequested;
@property (nonatomic, strong) NSMutableArray<NSDictionary*>* pendingOrderedWatchDownloadPayloads;
@property (nonatomic) NSUInteger pendingOrderedWatchDownloadPayloadIndex;
@property (nonatomic) BOOL orderedWatchDownloadPayloadProcessing;
@property (nonatomic, strong) NSManagedObjectContext* watchEventRevisionPersistenceContext;

- (void)_sendCurrentManifestAndNotify;
- (void)_repairDuplicateAppleWatchEpisodeStatesWithCompletion:(void (^)(NSError* error))completion;
- (void)_finishStartingAfterWatchStateRepair;
- (NSNumber*)_nextManifestRevision;
- (NSDate*)_nextWatchSelectionDateAfterDate:(NSDate*)previousDate;
- (BOOL)_shouldApplyWatchEventPayload:(NSDictionary*)payload toState:(AppleWatchEpisodeState*)state;
- (int64_t)_acceptedWatchEventRevisionForPayload:(NSDictionary*)payload
                                         toState:(AppleWatchEpisodeState*)state
                             advanceDurableState:(BOOL)advanceDurableState;
- (AppleWatchEpisodeState*)_stateForWatchEventPayload:(NSDictionary*)payload;
- (NSArray<AppleWatchEpisodeState*>*)_visibleEpisodeStatesFromAllStates:(NSArray<AppleWatchEpisodeState*>*)states;
- (NSDictionary<NSString*, CDEpisode*>*)_episodesByHashForEpisodeHashes:(NSArray<NSString*>*)episodeHashes;
- (NSDictionary<NSString*, NSArray<AppleWatchEpisodeState*>*>*)_statesByHashForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
                                                                                       error:(NSError**)error;
- (BOOL)_applyWatchDeletedPayload:(NSDictionary*)payload state:(AppleWatchEpisodeState*)state;
- (BOOL)_applyWatchDeletedEpisodesPayload:(NSDictionary*)payload error:(NSError**)error;
- (BOOL)_isWatchDeletionPayload:(NSDictionary*)payload;
- (NSURL*)_stageIncomingWatchDeletionPayload:(NSDictionary*)payload error:(NSError**)error;
- (void)_scheduleWatchDeletionInboxProcessing;
- (void)_finishWatchDeletionInboxProcessing:(BOOL)processNext;
- (void)_commitStagedWatchDeletionPayload:(NSDictionary*)payload fileURL:(NSURL*)fileURL;
- (BOOL)_sendWatchDeletionAcknowledgementForPayload:(NSDictionary*)payload;
- (void)_postEpisodeStatesChangedForEpisodeHashes:(NSArray<NSString*>*)episodeHashes;
- (void)_postLiveStatusChangedForEpisodeHashes:(NSArray<NSString*>*)episodeHashes;
- (void)_presentWatchDeletionProcessingError;
- (NSDictionary*)_manifestEntryForEpisode:(CDEpisode*)episode
                           selectionSource:(NSString*)selectionSource
                            watchAddedDate:(NSDate*)watchAddedDate
                       selectionIdentifier:(NSString*)selectionIdentifier;
- (void)_applyManifestAcknowledgementForEpisodeHashes:(NSArray*)episodeHashes;
- (NSUInteger)_advanceAutomaticSelectionGeneration;
- (BOOL)_isAutomaticSelectionGenerationCurrent:(NSUInteger)generation;
- (NSDictionary*)_automaticSelectionPlanInContext:(NSManagedObjectContext*)context
                                        generation:(NSUInteger)generation
                               defaultEpisodeCount:(NSInteger)defaultEpisodeCount
                               defaultOnlyUnplayed:(BOOL)defaultOnlyUnplayed
                         suppressedEpisodeHashes:(NSSet<NSString*>*)suppressedEpisodeHashes
                                          startedAt:(NSDate*)startedAt
                                              error:(NSError**)error;
- (void)_applyAutomaticSelectionPlan:(NSDictionary*)plan generation:(NSUInteger)generation;
- (void)_applyAutomaticSelectionOperations:(NSArray<NSDictionary*>*)operations
                                     offset:(NSUInteger)offset
                                  startedAt:(NSDate*)startedAt
                                 generation:(NSUInteger)generation;
- (void)_automaticSelectionFailedWithError:(NSError*)error generation:(NSUInteger)generation;
- (NSUInteger)_advanceManifestBuildGeneration;
- (BOOL)_isManifestBuildGenerationCurrent:(NSUInteger)generation;
- (void)_invalidateManifestBuildForUpcomingSelection;
- (NSDictionary*)_manifestSnapshotInContext:(NSManagedObjectContext*)context
                                  generation:(NSUInteger)generation
                                       error:(NSError**)error;
- (void)_sendPreparedManifestPayload:(NSDictionary*)payload
                            snapshot:(NSDictionary*)snapshot
                          generation:(NSUInteger)generation;
- (NSURL*)_prepareManifestFileForPayload:(NSDictionary*)payload
                               generation:(NSUInteger)generation
                                    error:(NSError**)error;
- (NSURL*)_manifestFileURLForRevision:(int64_t)manifestRevision;
- (NSArray<NSString*>*)_episodeHashesFromManifestFileForRevision:(int64_t)manifestRevision error:(NSError**)error;
- (BOOL)_sendManifestPayload:(NSDictionary*)payload fileURL:(NSURL*)fileURL error:(NSError**)outError;
#if IC_WATCH_CONNECTIVITY_ENABLED
- (NSInteger)_storedWatchManifestProtocolVersionForSession:(WCSession*)session;
- (void)_storeWatchManifestProtocolVersion:(NSInteger)version forSession:(WCSession*)session;
#endif
- (void)_applyManifestSentStateForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
                                         offset:(NSUInteger)offset
                                     generation:(NSUInteger)generation;
- (void)_manifestBuildFailedWithError:(NSError*)error generation:(NSUInteger)generation;
- (void)_manifestDeliveryFailedWithError:(NSError*)error generation:(NSUInteger)generation;
- (void)_finishManifestBuildGeneration:(NSUInteger)generation;
- (void)_applyManifestAcknowledgementForRevision:(int64_t)manifestRevision;
- (void)_applyManifestAcknowledgementBatchForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
                                                     offset:(NSUInteger)offset
                                           manifestRevision:(int64_t)manifestRevision;
- (void)_finishManifestAcknowledgementForRevision:(int64_t)manifestRevision;
- (void)_enqueueOrderedWatchDownloadPayload:(NSDictionary*)payload type:(NSString*)type;
- (void)_processNextOrderedWatchDownloadPayload;
- (void)_finishOrderedWatchDownloadPayload;
- (void)_persistWatchProgressRevisionForPayload:(NSDictionary*)payload;
- (void)_finishPersistedWatchProgressPayload:(NSDictionary*)payload
                            updatedObjectIDs:(NSArray<NSManagedObjectID*>*)updatedObjectIDs
                                       error:(NSError*)error;
- (AppleWatchEpisodeState*)_applyPersistedTransientDownloadProgressPayload:(NSDictionary*)payload;
- (AppleWatchEpisodeState*)_applyTransientDownloadProgressPayload:(NSDictionary*)payload;

@end

@implementation AppleWatchSyncManager

+ (instancetype)sharedManager
{
    static AppleWatchSyncManager* manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] init];
    });
    return manager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
#if IC_WATCH_CONNECTIVITY_ENABLED
        _supported = [WCSession isSupported];
#else
        _supported = NO;
#endif
        _watchDownloadProgressByHash = [NSMutableDictionary dictionary];
        _watchTransferContributionByHash = [NSMutableDictionary dictionary];
        _pendingLiveStatusEpisodeHashes = [NSMutableSet set];
        _pendingOrderedWatchDownloadPayloads = [NSMutableArray array];
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _automaticSelectionQueue = dispatch_queue_create("com.instacastplus.watch-automatic-selection", attributes);
        _manifestBuildQueue = dispatch_queue_create("com.instacastplus.watch-manifest-snapshot", attributes);
        _watchDeletionInboxQueue = dispatch_queue_create("com.instacastplus.watch-deletion-inbox", attributes);
    }
    return self;
}

// Aggregated download progress over the whole wanted set (downloaded + downloading + queued).
// The phase keeps an offline/unacknowledged manifest distinct from an actual Watch download.
- (ICAppleWatchTransferPhase)watchDownloadProgressLoadedBytes:(int64_t*)outLoadedBytes
                                                  totalBytes:(int64_t*)outTotalBytes
                                             totalBytesKnown:(BOOL*)outTotalBytesKnown
{
    [self _rebuildWatchTransferSnapshotIfNeeded];

    if (outLoadedBytes) {
        *outLoadedBytes = self.cachedWatchTransferLoadedBytes;
    }
    if (outTotalBytes) {
        *outTotalBytes = self.cachedWatchTransferTotalBytes;
    }
    if (outTotalBytesKnown) {
        *outTotalBytesKnown = (self.cachedWatchTransferUnknownTotalCount == 0);
    }
    if (self.cachedWatchTransferDownloadingCount > 0) {
        return ICAppleWatchTransferPhaseDownloading;
    }
    if (self.cachedWatchTransferWaitingCount > 0) {
        return ICAppleWatchTransferPhaseWaiting;
    }
    return ICAppleWatchTransferPhaseNone;
}

- (NSDictionary*)_liveDownloadProgressForState:(AppleWatchEpisodeState*)state
{
    NSDictionary* progress = self.watchDownloadProgressByHash[state.episodeHash ?: @""];
    if (!progress) {
        return nil;
    }
    NSString* selectionIdentifier = [progress[@"selectionIdentifier"] isKindOfClass:[NSString class]] ?
        progress[@"selectionIdentifier"] : nil;
    if (selectionIdentifier.length > 0 && ![selectionIdentifier isEqualToString:state.uid]) {
        return nil;
    }
    if (self.watchManifestProtocolVersion >= 3 && selectionIdentifier.length == 0) {
        return nil;
    }
    return progress;
}

- (NSDictionary*)_watchTransferContributionForState:(AppleWatchEpisodeState*)state
                                      episodesByHash:(NSDictionary<NSString*, CDEpisode*>*)episodesByHash
{
    NSDictionary* progress = [self _liveDownloadProgressForState:state];
    if (progress) {
        int64_t expectedBytes = MAX((int64_t)0, [progress[@"expectedBytes"] longLongValue]);
        if (expectedBytes <= 0) {
            CDEpisode* episode = episodesByHash[state.episodeHash ?: @""];
            expectedBytes = MAX((int64_t)0, episode.preferedMedium.byteSize);
        }
        int64_t downloadedBytes = MAX((int64_t)0, [progress[@"downloadedBytes"] longLongValue]);
        return @{
            ICAppleWatchTransferLoadedBytesKey: @(MIN(downloadedBytes, expectedBytes)),
            ICAppleWatchTransferTotalBytesKey: @(expectedBytes),
            ICAppleWatchTransferTotalKnownKey: @(expectedBytes > 0),
            ICAppleWatchTransferPhaseKey: @(ICAppleWatchTransferPhaseDownloading),
        };
    }

    // Evicted episodes are not loading; failed ones never will by themselves — counting
    // them as incomplete kept "Watch lädt Podcasts (x von y)" showing forever.
    if ([state.watchStatus isEqualToString:ICAppleWatchStatusEvicted] ||
        [state.watchStatus isEqualToString:ICAppleWatchStatusFailed]) {
        return nil;
    }
    if (state.downloadedOnWatch) {
        int64_t actualBytes = MAX((int64_t)0, state.watchActualFileSize);
        return @{
            ICAppleWatchTransferLoadedBytesKey: @(actualBytes),
            ICAppleWatchTransferTotalBytesKey: @(actualBytes),
            ICAppleWatchTransferTotalKnownKey: @YES,
            ICAppleWatchTransferPhaseKey: @(ICAppleWatchTransferPhaseNone),
        };
    }

    CDEpisode* episode = episodesByHash[state.episodeHash ?: @""];
    int64_t expectedBytes = MAX((int64_t)0, episode.preferedMedium.byteSize);
    ICAppleWatchTransferPhase phase = ICAppleWatchTransferPhaseNone;
    if ([state.watchStatus isEqualToString:ICAppleWatchStatusDownloading]) {
        // Compatibility with durable states written by older app versions. New live progress
        // remains in memory and takes the branch above.
        phase = ICAppleWatchTransferPhaseDownloading;
    }
    else if ([state.watchStatus isEqualToString:ICAppleWatchStatusSelected] ||
             [state.watchStatus isEqualToString:ICAppleWatchStatusManifestSent] ||
             [state.watchStatus isEqualToString:ICAppleWatchStatusQueuedOnWatch]) {
        phase = ICAppleWatchTransferPhaseWaiting;
    }
    return @{
        ICAppleWatchTransferLoadedBytesKey: @0,
        ICAppleWatchTransferTotalBytesKey: @(expectedBytes),
        ICAppleWatchTransferTotalKnownKey: @(expectedBytes > 0),
        ICAppleWatchTransferPhaseKey: @(phase),
    };
}

- (void)_setWatchTransferContribution:(NSDictionary*)contribution forEpisodeHash:(NSString*)episodeHash
{
    NSDictionary* previous = self.watchTransferContributionByHash[episodeHash];
    if (previous) {
        self.cachedWatchTransferLoadedBytes -= [previous[ICAppleWatchTransferLoadedBytesKey] longLongValue];
        self.cachedWatchTransferTotalBytes -= [previous[ICAppleWatchTransferTotalBytesKey] longLongValue];
        if (![previous[ICAppleWatchTransferTotalKnownKey] boolValue]) {
            self.cachedWatchTransferUnknownTotalCount -= 1;
        }
        ICAppleWatchTransferPhase phase = [previous[ICAppleWatchTransferPhaseKey] integerValue];
        self.cachedWatchTransferWaitingCount -= (phase == ICAppleWatchTransferPhaseWaiting);
        self.cachedWatchTransferDownloadingCount -= (phase == ICAppleWatchTransferPhaseDownloading);
    }

    if (!contribution) {
        [self.watchTransferContributionByHash removeObjectForKey:episodeHash];
        return;
    }
    self.watchTransferContributionByHash[episodeHash] = contribution;
    self.cachedWatchTransferLoadedBytes += [contribution[ICAppleWatchTransferLoadedBytesKey] longLongValue];
    self.cachedWatchTransferTotalBytes += [contribution[ICAppleWatchTransferTotalBytesKey] longLongValue];
    if (![contribution[ICAppleWatchTransferTotalKnownKey] boolValue]) {
        self.cachedWatchTransferUnknownTotalCount += 1;
    }
    ICAppleWatchTransferPhase phase = [contribution[ICAppleWatchTransferPhaseKey] integerValue];
    self.cachedWatchTransferWaitingCount += (phase == ICAppleWatchTransferPhaseWaiting);
    self.cachedWatchTransferDownloadingCount += (phase == ICAppleWatchTransferPhaseDownloading);
}

- (void)_invalidateWatchTransferSnapshot
{
    self.watchTransferSnapshotValid = NO;
    [self.watchTransferContributionByHash removeAllObjects];
    self.cachedWatchTransferLoadedBytes = 0;
    self.cachedWatchTransferTotalBytes = 0;
    self.cachedWatchTransferUnknownTotalCount = 0;
    self.cachedWatchTransferWaitingCount = 0;
    self.cachedWatchTransferDownloadingCount = 0;
    self.cachedWatchStorageEvictedCount = 0;
    self.cachedWatchDownloadedCount = 0;
}

- (void)_rebuildWatchTransferSnapshotIfNeeded
{
    if (self.watchTransferSnapshotValid) {
        return;
    }
    [self _invalidateWatchTransferSnapshot];

    NSArray<AppleWatchEpisodeState*>* visibleStates = [self visibleEpisodeStates];
    NSMutableArray<NSString*>* hashesMissingExpectedBytes = [NSMutableArray array];
    for (AppleWatchEpisodeState* state in visibleStates) {
        NSDictionary* progress = [self _liveDownloadProgressForState:state];
        if (progress || (!state.downloadedOnWatch &&
                         ![state.watchStatus isEqualToString:ICAppleWatchStatusEvicted] &&
                         ![state.watchStatus isEqualToString:ICAppleWatchStatusFailed])) {
            if ([progress[@"expectedBytes"] longLongValue] <= 0 && state.episodeHash.length > 0) {
                [hashesMissingExpectedBytes addObject:state.episodeHash];
            }
        }
    }
    NSDictionary<NSString*, CDEpisode*>* episodesByHash =
        [self _episodesByHashForEpisodeHashes:hashesMissingExpectedBytes];
    for (AppleWatchEpisodeState* state in visibleStates) {
        self.cachedWatchStorageEvictedCount += [state.watchStatus isEqualToString:ICAppleWatchStatusEvicted];
        self.cachedWatchDownloadedCount += state.downloadedOnWatch;
        NSDictionary* contribution = [self _watchTransferContributionForState:state episodesByHash:episodesByHash];
        [self _setWatchTransferContribution:contribution forEpisodeHash:state.episodeHash ?: @""];
    }
    self.watchTransferSnapshotValid = YES;
}

- (void)_updateCachedWatchTransferContributionForState:(AppleWatchEpisodeState*)state
                                                payload:(NSDictionary*)payload
{
    if (!self.watchTransferSnapshotValid || state.episodeHash.length == 0) {
        return;
    }
    NSDictionary* previous = self.watchTransferContributionByHash[state.episodeHash];
    if (!previous) {
        [self _invalidateWatchTransferSnapshot];
        return;
    }
    int64_t expectedBytes = MAX((int64_t)0, [payload[@"expectedBytes"] longLongValue]);
    if (expectedBytes <= 0) {
        expectedBytes = MAX((int64_t)0, [previous[ICAppleWatchTransferTotalBytesKey] longLongValue]);
    }
    int64_t downloadedBytes = MAX((int64_t)0, [payload[@"downloadedBytes"] longLongValue]);
    NSDictionary* contribution = @{
        ICAppleWatchTransferLoadedBytesKey: @(MIN(downloadedBytes, expectedBytes)),
        ICAppleWatchTransferTotalBytesKey: @(expectedBytes),
        ICAppleWatchTransferTotalKnownKey: @(expectedBytes > 0),
        ICAppleWatchTransferPhaseKey: @(ICAppleWatchTransferPhaseDownloading),
    };
    [self _setWatchTransferContribution:contribution forEpisodeHash:state.episodeHash];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)start
{
    if (self.started) {
        return;
    }
    self.started = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_playbackDidUpdate:)
                                                 name:PlaybackManagerDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_playbackDidUpdate:)
                                                 name:PlaybackManagerDidEndNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_playbackDidUpdate:)
                                                 name:PlaybackManagerEpisodeDidFinishNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_appearanceDidUpdate:)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

    [self _repairDuplicateAppleWatchEpisodeStatesWithCompletion:^(NSError* error) {
        if (error) {
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                          message:@"Doppelte Watch-Auswahlzustände konnten nicht repariert werden"
                                         metadata:@{ @"error": error.localizedDescription ?: @"" }];
#if TARGET_OS_IPHONE
            if (App.applicationState == UIApplicationStateActive) {
                [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                          message:@"Apple Watch changes could not be applied. Try syncing again.".ls
                                         duration:8.0];
            }
#endif
            return;
        }
        [self _finishStartingAfterWatchStateRepair];
    }];
}

- (void)_finishStartingAfterWatchStateRepair
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    if ([WCSession isSupported]) {
        WCSession* session = WCSession.defaultSession;
        session.delegate = self;
        [session activateSession];
        [self _refreshSessionStateAndNotify:YES];
    }
#endif

    [self _scheduleWatchDeletionInboxProcessing];

    int64_t pendingManifestRevision = [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey];
    if (pendingManifestRevision > 0 &&
        [USER_DEFAULTS integerForKey:ICAppleWatchReceivedManifestAcknowledgementRevisionKey] >= pendingManifestRevision) {
        [self _applyManifestAcknowledgementForRevision:pendingManifestRevision];
    }
}

- (void)_repairDuplicateAppleWatchEpisodeStatesWithCompletion:(void (^)(NSError* error))completion
{
    NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
    if (!context) {
        if (completion) {
            completion([NSError errorWithDomain:@"AppleWatchSync"
                                             code:32
                                         userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch changes could not be applied. Try syncing again.".ls}]);
        }
        return;
    }

    [context performBlock:^{
        NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
        NSError* fetchError = nil;
        NSArray<AppleWatchEpisodeState*>* states = [context executeFetchRequest:request error:&fetchError];
        if (!states) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(fetchError);
            });
            return;
        }

        NSMutableDictionary<NSString*, AppleWatchEpisodeState*>* canonicalStateByHash = [NSMutableDictionary dictionary];
        NSMutableArray<NSManagedObjectID*>* deletedObjectIDs = [NSMutableArray array];
        for (AppleWatchEpisodeState* state in states) {
            NSString* episodeHash = state.episodeHash;
            if (episodeHash.length == 0) continue;
            AppleWatchEpisodeState* canonicalState = canonicalStateByHash[episodeHash];
            if (!canonicalState) {
                canonicalStateByHash[episodeHash] = state;
                continue;
            }

            AppleWatchEpisodeState* duplicateState = state;
            if (ICCompareAppleWatchEpisodeStates(state, canonicalState) == NSOrderedAscending) {
                duplicateState = canonicalState;
                canonicalStateByHash[episodeHash] = state;
            }
            [deletedObjectIDs addObject:duplicateState.objectID];
            [context deleteObject:duplicateState];
        }

        NSError* saveError = nil;
        if (deletedObjectIDs.count > 0 && ![context save:&saveError]) {
            [context rollback];
        }
        NSArray<NSManagedObjectID*>* committedDeletedObjectIDs = saveError ? @[] : [deletedObjectIDs copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (committedDeletedObjectIDs.count > 0) {
                [NSManagedObjectContext mergeChangesFromRemoteContextSave:@{ NSDeletedObjectsKey: committedDeletedObjectIDs }
                                                              intoContexts:@[DMANAGER.objectContext]];
            }
            if (completion) completion(saveError);
        });
    }];
}

- (NSArray<AppleWatchEpisodeState*>*)allEpisodeStates
{
    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.sortDescriptors = @[
        [[NSSortDescriptor alloc] initWithKey:@"watchAddedDate" ascending:NO],
        [[NSSortDescriptor alloc] initWithKey:@"episodeHash" ascending:YES],
        [[NSSortDescriptor alloc] initWithKey:@"watchLastEventRevision" ascending:NO],
        [[NSSortDescriptor alloc] initWithKey:@"uid" ascending:YES],
    ];
    NSArray* results = [DMANAGER.objectContext executeFetchRequest:request error:nil];
    return results ? [results sortedArrayUsingComparator:^NSComparisonResult(AppleWatchEpisodeState* first, AppleWatchEpisodeState* second) {
        return ICCompareAppleWatchEpisodeStates(first, second);
    }] : @[];
}

- (NSArray<AppleWatchEpisodeState*>*)visibleEpisodeStates
{
    return [self _visibleEpisodeStatesFromAllStates:[self allEpisodeStates]];
}

- (NSArray<AppleWatchEpisodeState*>*)_visibleEpisodeStatesFromAllStates:(NSArray<AppleWatchEpisodeState*>*)states
{
    NSMutableArray<AppleWatchEpisodeState*>* visibleStates = [NSMutableArray arrayWithCapacity:states.count];
    NSMutableSet<NSString*>* seenEpisodeHashes = [NSMutableSet setWithCapacity:states.count];
    for (AppleWatchEpisodeState* state in states) {
        NSString* episodeHash = state.episodeHash;
        if (episodeHash.length == 0 || [seenEpisodeHashes containsObject:episodeHash]) {
            continue;
        }
        [seenEpisodeHashes addObject:episodeHash];
        if (state.removingFromWatch) {
            continue;
        }
        [visibleStates addObject:state];
    }
    return visibleStates;
}

- (NSDictionary<NSString*, CDEpisode*>*)_episodesByHashForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
{
    NSMutableOrderedSet<NSString*>* uniqueHashes = [NSMutableOrderedSet orderedSetWithCapacity:episodeHashes.count];
    for (NSString* episodeHash in episodeHashes) {
        if (episodeHash.length > 0) {
            [uniqueHashes addObject:episodeHash];
        }
    }

    NSMutableDictionary<NSString*, CDEpisode*>* episodesByHash = [NSMutableDictionary dictionaryWithCapacity:uniqueHashes.count];
    NSArray<NSString*>* hashes = uniqueHashes.array;
    for (NSUInteger offset = 0; offset < hashes.count; offset += ICAppleWatchEpisodeFetchBatchSize) {
        NSRange range = NSMakeRange(offset, MIN(ICAppleWatchEpisodeFetchBatchSize, hashes.count - offset));
        NSArray<NSString*>* batch = [hashes subarrayWithRange:range];
        for (CDEpisode* episode in [DMANAGER episodesWithObjectHashes:batch]) {
            if (episode.objectHash.length > 0 && !episodesByHash[episode.objectHash]) {
                episodesByHash[episode.objectHash] = episode;
            }
        }
    }
    return episodesByHash;
}

- (NSDictionary<NSString*, NSArray<AppleWatchEpisodeState*>*>*)_statesByHashForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
                                                                                       error:(NSError**)error
{
    NSMutableOrderedSet<NSString*>* uniqueHashes = [NSMutableOrderedSet orderedSetWithCapacity:episodeHashes.count];
    for (NSString* episodeHash in episodeHashes) {
        if (episodeHash.length > 0) {
            [uniqueHashes addObject:episodeHash];
        }
    }

    NSMutableDictionary<NSString*, NSMutableArray<AppleWatchEpisodeState*>*>* statesByHash = [NSMutableDictionary dictionaryWithCapacity:uniqueHashes.count];
    NSArray<NSString*>* hashes = uniqueHashes.array;
    for (NSUInteger offset = 0; offset < hashes.count; offset += ICAppleWatchEpisodeFetchBatchSize) {
        NSRange range = NSMakeRange(offset, MIN(ICAppleWatchEpisodeFetchBatchSize, hashes.count - offset));
        NSArray<NSString*>* batch = [hashes subarrayWithRange:range];
        NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
        request.predicate = [NSPredicate predicateWithFormat:@"episodeHash IN %@", batch];
        request.sortDescriptors = @[
            [[NSSortDescriptor alloc] initWithKey:@"watchAddedDate" ascending:NO],
            [[NSSortDescriptor alloc] initWithKey:@"uid" ascending:YES],
        ];
        NSError* fetchError = nil;
        NSArray<AppleWatchEpisodeState*>* states = [DMANAGER.objectContext executeFetchRequest:request error:&fetchError];
        if (!states) {
            if (error) {
                *error = fetchError;
            }
            return nil;
        }
        for (AppleWatchEpisodeState* state in states) {
            if (state.episodeHash.length > 0) {
                NSMutableArray* matchingStates = statesByHash[state.episodeHash];
                if (!matchingStates) {
                    matchingStates = [NSMutableArray array];
                    statesByHash[state.episodeHash] = matchingStates;
                }
                [matchingStates addObject:state];
            }
        }
    }
    return statesByHash;
}

- (AppleWatchEpisodeState*)stateForEpisodeHash:(NSString*)episodeHash
{
    if (episodeHash.length == 0) {
        return nil;
    }

    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.predicate = [NSPredicate predicateWithFormat:@"episodeHash == %@", episodeHash];
    request.sortDescriptors = @[
        [[NSSortDescriptor alloc] initWithKey:@"watchAddedDate" ascending:NO],
        [[NSSortDescriptor alloc] initWithKey:@"watchLastEventRevision" ascending:NO],
        [[NSSortDescriptor alloc] initWithKey:@"uid" ascending:YES],
    ];
    NSArray<AppleWatchEpisodeState*>* states = [DMANAGER.objectContext executeFetchRequest:request error:nil];
    states = [states sortedArrayUsingComparator:^NSComparisonResult(AppleWatchEpisodeState* first, AppleWatchEpisodeState* second) {
        return ICCompareAppleWatchEpisodeStates(first, second);
    }];
    return states.firstObject;
}

- (BOOL)hasLiveDownloadProgressForEpisodeHash:(NSString*)episodeHash
                          selectionIdentifier:(NSString*)selectionIdentifier
{
    NSDictionary* progress = self.watchDownloadProgressByHash[episodeHash ?: @""];
    if (!progress) {
        return NO;
    }
    NSString* progressSelectionIdentifier =
        [progress[@"selectionIdentifier"] isKindOfClass:[NSString class]] ? progress[@"selectionIdentifier"] : nil;
    if (progressSelectionIdentifier.length > 0) {
        return [progressSelectionIdentifier isEqualToString:selectionIdentifier ?: @""];
    }
    return self.watchManifestProtocolVersion < 3;
}

- (AppleWatchEpisodeState*)_stateForWatchEventPayload:(NSDictionary*)payload
{
    NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
    NSString* selectionIdentifier = [payload[@"selectionIdentifier"] isKindOfClass:[NSString class]] ? payload[@"selectionIdentifier"] : nil;
    if (episodeHash.length == 0) {
        return nil;
    }
    if (selectionIdentifier.length == 0) {
        return self.watchManifestProtocolVersion >= 3 ? nil : [self stateForEpisodeHash:episodeHash];
    }
    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.fetchLimit = 1;
    request.predicate = [NSPredicate predicateWithFormat:@"episodeHash == %@ AND uid == %@", episodeHash, selectionIdentifier];
    return [[DMANAGER.objectContext executeFetchRequest:request error:nil] firstObject];
}

- (AppleWatchEpisodeState*)_stateForEpisode:(CDEpisode*)episode createIfNeeded:(BOOL)createIfNeeded
{
    if (episode.objectHash.length == 0) {
        return nil;
    }

    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    if (!state && createIfNeeded) {
        state = [NSEntityDescription insertNewObjectForEntityForName:@"AppleWatchEpisodeState" inManagedObjectContext:DMANAGER.objectContext];
        state.episodeHash = episode.objectHash;
        state.feedIdentifier = [self _feedIdentifierForFeed:episode.feed];
        state.watchAddedDate = [NSDate date];
        state.watchStatus = ICAppleWatchStatusSelected;
        state.lastPhonePosition = episode.position;
        state.lastPhonePositionDate = [NSDate date];
    }

    return state;
}

- (BOOL)isEpisodeSelectedForWatch:(CDEpisode*)episode
{
    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    return state && !state.removingFromWatch;
}

- (BOOL)isEpisodeDownloadedOnWatch:(CDEpisode*)episode
{
    return [[self stateForEpisodeHash:episode.objectHash] downloadedOnWatch];
}

- (NSInteger)watchStorageEvictedCount
{
    [self _rebuildWatchTransferSnapshotIfNeeded];
    return self.cachedWatchStorageEvictedCount;
}

- (BOOL)watchStorageFull
{
    // The genuinely-stuck case worth surfacing: episodes were evicted for space AND nothing is
    // currently downloaded, so the watch could not keep a single episode. Normal over-subscription
    // (some downloaded, some evicted) is silent — the watch manages it automatically.
    [self _rebuildWatchTransferSnapshotIfNeeded];
    return self.cachedWatchStorageEvictedCount > 0 && self.cachedWatchDownloadedCount == 0;
}

- (BOOL)canSendEpisodeToWatch:(CDEpisode*)episode
{
    if (!episode || episode.video || episode.archived) {
        return NO;
    }
    return ([self _mediaURLStringForEpisode:episode].length > 0);
}

- (void)sendEpisodeToWatch:(CDEpisode*)episode
{
    if (![self canSendEpisodeToWatch:episode]) {
        return;
    }

    AppleWatchEpisodeState* state = [self _stateForEpisode:episode createIfNeeded:YES];
    BOOL wasRemovingFromWatch = state.removingFromWatch;
    state.selectionSource = ICAppleWatchSelectionSourceManual;
    state.watchStatus = ICAppleWatchStatusSelected;
    state.watchAddedDate = wasRemovingFromWatch ?
        [self _nextWatchSelectionDateAfterDate:state.watchAddedDate] : (state.watchAddedDate ?: [NSDate date]);
    if (wasRemovingFromWatch) {
        state.uid = [NSUUID UUID].UUIDString;
    }
    state.watchLastError = nil;
    state.feedIdentifier = [self _feedIdentifierForFeed:episode.feed];
    state.lastPhonePosition = episode.position;
    state.lastPhonePositionDate = [NSDate date];
    [self _unsuppressAutomaticEpisodeHash:episode.objectHash];

    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self syncCurrentSelectionsNow];
}

- (void)removeEpisodeFromWatch:(CDEpisode*)episode
{
    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    [self removeEpisodeStateFromWatch:state];
}

- (void)removeEpisodeStateFromWatch:(AppleWatchEpisodeState*)state
{
    NSString* episodeHash = state.episodeHash;
    if (!state || state.deleted || episodeHash.length == 0) {
        return;
    }

    state.watchStatus = ICAppleWatchStatusRemoving;
    state.watchLastError = nil;
    if ([state.selectionSource isEqualToString:ICAppleWatchSelectionSourceLatestRule]) {
        [self _suppressAutomaticEpisodeHash:episodeHash];
    }
    NSNumber* manifestRevision = [self _nextManifestRevision];
    state.watchLastEventRevision = MAX(state.watchLastEventRevision, manifestRevision.longLongValue);
    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self _sendCommand:@{ ICAppleWatchMessageTypeKey: ICAppleWatchManifestRemoveEpisodes,
                          @"manifestRevision": manifestRevision,
                          @"episodeHashes": @[episodeHash] }];
    [self _sendCurrentManifestAndNotify];
}

- (void)prioritizeEpisodeOnWatch:(CDEpisode*)episode
{
    if (![self isEpisodeSelectedForWatch:episode] || [self isEpisodeDownloadedOnWatch:episode]) {
        return;
    }

    [self _sendCommand:@{ ICAppleWatchMessageTypeKey: ICAppleWatchDownloadPrioritize,
                          @"episodeHash": episode.objectHash ?: @"" }];
}

- (void)moveEpisodeAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex
{
    NSMutableArray<AppleWatchEpisodeState*>* states = [[self visibleEpisodeStates] mutableCopy];
    if (fromIndex >= states.count || toIndex >= states.count || fromIndex == toIndex) {
        return;
    }

    AppleWatchEpisodeState* state = states[fromIndex];
    [states removeObjectAtIndex:fromIndex];
    [states insertObject:state atIndex:toIndex];
    [self _assignWatchOrderDatesForStates:states];
    [DMANAGER save];
    [self _postEpisodeStatesChanged];
    [self syncCurrentSelectionsNow];
}

- (void)rebuildAutomaticSelectionsAndSync
{
    [self syncNow];
}

- (void)syncNow
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncNow];
        });
        return;
    }

    NSUInteger generation = [self _advanceAutomaticSelectionGeneration];
    [self _invalidateManifestBuildForUpcomingSelection];
    NSInteger defaultEpisodeCount = [USER_DEFAULTS integerForKey:AppleWatchSendLatestCount];
    BOOL defaultOnlyUnplayed = [USER_DEFAULTS boolForKey:AppleWatchOnlyUnplayed];
    NSSet<NSString*>* suppressedEpisodeHashes = [[self _suppressedAutomaticEpisodeHashes] copy];
    NSDate* startedAt = [NSDate date];

    dispatch_async(self.automaticSelectionQueue, ^{
        if (![self _isAutomaticSelectionGenerationCurrent:generation]) {
            return;
        }
        NSManagedObjectContext* context = [DMANAGER newExportBackgroundContext];
        if (!context) {
            NSError* error = [NSError errorWithDomain:@"AppleWatchSync"
                                                  code:1
                                              userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch selections could not be prepared. Check the available storage and try again.".ls}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _automaticSelectionFailedWithError:error generation:generation];
            });
            return;
        }
        __block NSError* planError = nil;
        __block NSDictionary* plan = nil;
        [context performBlockAndWait:^{
            plan = [self _automaticSelectionPlanInContext:context
                                                generation:generation
                                       defaultEpisodeCount:defaultEpisodeCount
                                       defaultOnlyUnplayed:defaultOnlyUnplayed
                                 suppressedEpisodeHashes:suppressedEpisodeHashes
                                                  startedAt:startedAt
                                                      error:&planError];
            [context reset];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self _isAutomaticSelectionGenerationCurrent:generation]) {
                return;
            }
            if (!plan) {
                [self _automaticSelectionFailedWithError:planError generation:generation];
                return;
            }
            [self _applyAutomaticSelectionPlan:plan generation:generation];
        });
    });
}

- (void)syncCurrentSelectionsNow
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self syncCurrentSelectionsNow];
        });
        return;
    }
    [self _sendCurrentManifestAndNotify];
}

- (void)_sendCurrentManifestAndNotify
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _sendCurrentManifestAndNotify];
        });
        return;
    }

    if (self.manifestDeliveryInProgress) {
        self.manifestBuildRequestedAfterDelivery = YES;
        return;
    }

    NSUInteger generation = [self _advanceManifestBuildGeneration];
    NSString* accentColorHex = [[self _currentAccentColorHex] copy];
    dispatch_async(self.manifestBuildQueue, ^{
        if (![self _isManifestBuildGenerationCurrent:generation]) {
            return;
        }

        NSManagedObjectContext* context = [DMANAGER newExportBackgroundContext];
        if (!context) {
            NSError* error = [NSError errorWithDomain:@"AppleWatchSync"
                                                  code:2
                                              userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch manifest could not be prepared. Check the available storage and try again.".ls}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _manifestBuildFailedWithError:error generation:generation];
            });
            return;
        }

        __block NSError* snapshotError = nil;
        __block NSDictionary* snapshot = nil;
        [context performBlockAndWait:^{
            snapshot = [self _manifestSnapshotInContext:context generation:generation error:&snapshotError];
            [context reset];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self _isManifestBuildGenerationCurrent:generation]) {
                return;
            }
            if (!snapshot) {
                NSError* error = snapshotError ?: [NSError errorWithDomain:@"AppleWatchSync"
                                                                       code:3
                                                                   userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch manifest could not be prepared. Check the available storage and try again.".ls}];
                [self _manifestBuildFailedWithError:error generation:generation];
                return;
            }

            NSNumber* manifestRevision = [self _nextManifestRevision];
            NSDictionary* payload = @{
                ICAppleWatchMessageTypeKey: ICAppleWatchManifestReplace,
                @"manifestRevision": manifestRevision,
                @"watchEventProtocolVersion": @(ICAppleWatchWatchEventProtocolVersion),
                @"createdAt": [self _stringFromDate:[NSDate date]],
                @"accentColorHex": accentColorHex,
                @"episodes": snapshot[@"entries"] ?: @[],
            };
            dispatch_async(self.manifestBuildQueue, ^{
                NSError* fileError = nil;
                NSURL* fileURL = [self _prepareManifestFileForPayload:payload
                                                            generation:generation
                                                                 error:&fileError];
                if (![self _isManifestBuildGenerationCurrent:generation]) {
                    if (fileURL) {
                        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                    }
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (![self _isManifestBuildGenerationCurrent:generation]) {
                        if (fileURL) {
                            dispatch_async(self.manifestBuildQueue, ^{
                                [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                            });
                        }
                        return;
                    }
                    if (!fileURL) {
                        NSError* error = fileError ?: [NSError errorWithDomain:@"AppleWatchSync"
                                                                          code:4
                                                                      userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch manifest could not be prepared. Check the available storage and try again.".ls}];
                        [self _manifestBuildFailedWithError:error generation:generation];
                        return;
                    }
                    NSMutableDictionary* preparedSnapshot = [snapshot mutableCopy];
                    preparedSnapshot[@"manifestFileURL"] = fileURL;
                    self.manifestDeliveryInProgress = YES;
                    [self _sendPreparedManifestPayload:payload
                                              snapshot:preparedSnapshot
                                            generation:generation];
                });
            });
        });
    });
}

- (NSUInteger)_advanceAutomaticSelectionGeneration
{
    @synchronized (self) {
        self.automaticSelectionGeneration += 1;
        return self.automaticSelectionGeneration;
    }
}

- (BOOL)_isAutomaticSelectionGenerationCurrent:(NSUInteger)generation
{
    @synchronized (self) {
        return generation == self.automaticSelectionGeneration;
    }
}

- (NSUInteger)_advanceManifestBuildGeneration
{
    @synchronized (self) {
        self.manifestBuildGeneration += 1;
        return self.manifestBuildGeneration;
    }
}

- (BOOL)_isManifestBuildGenerationCurrent:(NSUInteger)generation
{
    @synchronized (self) {
        return generation == self.manifestBuildGeneration;
    }
}

- (void)_invalidateManifestBuildForUpcomingSelection
{
    if (self.manifestDeliveryInProgress) {
        self.manifestBuildRequestedAfterDelivery = YES;
        return;
    }
    [self _advanceManifestBuildGeneration];
}

- (NSURL*)_prepareManifestFileForPayload:(NSDictionary*)payload
                               generation:(NSUInteger)generation
                                    error:(NSError**)error
{
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        return nil;
    }
    NSArray* entries = [payload[@"episodes"] isKindOfClass:[NSArray class]] ? payload[@"episodes"] : nil;
    if (!entries) {
        if (error) *error = ICAppleWatchManifestFileError(16);
        return nil;
    }
    if (entries.count > ICAppleWatchMaximumManifestEntryCount) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppleWatchSync"
                                         code:21
                                     userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch sync data is too large. Reduce the Apple Watch selection and try again.".ls}];
        }
        return nil;
    }

    int64_t revision = [payload[@"manifestRevision"] longLongValue];
    NSURL* fileURL = [self _manifestFileURLForRevision:revision];
    NSURL* directoryURL = fileURL.URLByDeletingLastPathComponent;
    if (!directoryURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppleWatchSync"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch manifest could not be prepared. Check the available storage and try again.".ls}];
        }
        return nil;
    }
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                        error:error]) {
        return nil;
    }
    [directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

    NSURL* temporaryURL = [NSURL fileURLWithPath:[fileURL.path stringByAppendingString:@".tmp"]];
    [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
    NSOutputStream* stream = [NSOutputStream outputStreamToFileAtPath:temporaryURL.path append:NO];
    [stream open];
    NSMutableDictionary* header = [@{
        ICAppleWatchMessageTypeKey: ICAppleWatchManifestReplace,
        @"manifestRevision": payload[@"manifestRevision"] ?: @0,
        @"watchEventProtocolVersion": payload[@"watchEventProtocolVersion"] ?: @1,
        @"createdAt": payload[@"createdAt"] ?: @"",
        @"accentColorHex": payload[@"accentColorHex"] ?: @"",
        @"entryCount": @(entries.count),
    } mutableCopy];
    BOOL wroteManifest = ICWriteJSONObjectLine(stream, header, error);
    for (id value in entries) {
        @autoreleasepool {
            if (!wroteManifest) {
                break;
            }
            if (![value isKindOfClass:[NSDictionary class]]) {
                if (error) *error = ICAppleWatchManifestFileError(17);
                wroteManifest = NO;
                break;
            }
            wroteManifest = ICWriteJSONObjectLine(stream, value, error);
        }
    }
    [stream close];
    if (!wroteManifest) {
        [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
        return nil;
    }
    NSError* attributesError = nil;
    NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:temporaryURL.path
                                                                                 error:&attributesError];
    if (!attributes) {
        if (error) *error = attributesError ?: ICAppleWatchManifestFileError(22);
        [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
        return nil;
    }
    if ([attributes[NSFileSize] unsignedLongLongValue] > ICAppleWatchMaximumManifestFileSize) {
        if (error) {
            *error = [NSError errorWithDomain:@"AppleWatchSync"
                                         code:23
                                     userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch sync data is too large. Reduce the Apple Watch selection and try again.".ls}];
        }
        [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
        return nil;
    }
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
        return nil;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                     ofItemAtPath:temporaryURL.path
                                            error:nil];
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path];
    BOOL committed = fileExists ?
        [[NSFileManager defaultManager] replaceItemAtURL:fileURL
                                           withItemAtURL:temporaryURL
                                          backupItemName:nil
                                                 options:0
                                        resultingItemURL:nil
                                                   error:error] :
        [[NSFileManager defaultManager] moveItemAtURL:temporaryURL toURL:fileURL error:error];
    if (!committed) {
        [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
        return nil;
    }
    return fileURL;
}

- (NSURL*)_manifestFileURLForRevision:(int64_t)manifestRevision
{
    NSURL* applicationSupportURL = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                           inDomains:NSUserDomainMask].firstObject;
    NSURL* directoryURL = [applicationSupportURL URLByAppendingPathComponent:ICAppleWatchManifestTransferDirectoryName
                                                                 isDirectory:YES];
    NSString* filename = [NSString stringWithFormat:@"manifest-%lld.jsonl", (long long)manifestRevision];
    return [directoryURL URLByAppendingPathComponent:filename isDirectory:NO];
}

- (NSArray<NSString*>*)_episodeHashesFromManifestFileForRevision:(int64_t)manifestRevision error:(NSError**)error
{
    NSURL* fileURL = [self _manifestFileURLForRevision:manifestRevision];
    NSMutableOrderedSet<NSString*>* episodeHashes = [NSMutableOrderedSet orderedSet];
    __block BOOL readHeader = NO;
    __block NSUInteger expectedEntryCount = NSNotFound;
    __block NSUInteger entryCount = 0;
    BOOL success = ICEnumerateJSONLinesAtURL(fileURL, ^BOOL(NSDictionary* object, NSUInteger lineIndex, NSError** lineError) {
        if (lineIndex == 0) {
            BOOL validHeader = [object[ICAppleWatchMessageTypeKey] isEqualToString:ICAppleWatchManifestReplace] &&
                               [object[@"manifestRevision"] longLongValue] == manifestRevision &&
                               [object[@"entryCount"] isKindOfClass:[NSNumber class]];
            if (!validHeader) {
                if (lineError) *lineError = ICAppleWatchManifestFileError(18);
                return NO;
            }
            readHeader = YES;
            expectedEntryCount = [object[@"entryCount"] unsignedIntegerValue];
            return YES;
        }
        NSString* episodeHash = [object[@"episodeHash"] isKindOfClass:[NSString class]] ? object[@"episodeHash"] : nil;
        if (episodeHash.length == 0) {
            if (lineError) *lineError = ICAppleWatchManifestFileError(19);
            return NO;
        }
        [episodeHashes addObject:episodeHash];
        entryCount += 1;
        return YES;
    }, error);
    if (!success || !readHeader || expectedEntryCount == NSNotFound || entryCount != expectedEntryCount) {
        if (error && !*error) *error = ICAppleWatchManifestFileError(20);
        return nil;
    }
    return episodeHashes.array;
}

- (NSDictionary*)_automaticSelectionPlanInContext:(NSManagedObjectContext*)context
                                        generation:(NSUInteger)generation
                               defaultEpisodeCount:(NSInteger)defaultEpisodeCount
                               defaultOnlyUnplayed:(BOOL)defaultOnlyUnplayed
                         suppressedEpisodeHashes:(NSSet<NSString*>*)suppressedEpisodeHashes
                                          startedAt:(NSDate*)startedAt
                                              error:(NSError**)error
{
    NSFetchRequest* feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
    feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == %@", @YES];
    feedRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
    feedRequest.relationshipKeyPathsForPrefetching = @[@"properties"];
    NSArray<CDFeed*>* feeds = [context executeFetchRequest:feedRequest error:error];
    if (!feeds) {
        return nil;
    }

    NSMutableArray<NSDictionary*>* feedRules = [NSMutableArray array];
    for (CDFeed* feed in feeds) {
        if (![self _isAutomaticSelectionGenerationCurrent:generation]) {
            return nil;
        }
        NSInteger episodeCount = defaultEpisodeCount;
        BOOL onlyUnplayed = defaultOnlyUnplayed;
        for (CDFeedProperty* property in feed.properties) {
            if ([property.key isEqualToString:AppleWatchSendLatestCount]) {
                episodeCount = property.int32Value;
            }
            else if ([property.key isEqualToString:AppleWatchOnlyUnplayed]) {
                onlyUnplayed = property.boolValue;
            }
        }
        if (episodeCount <= 0) {
            continue;
        }
        [feedRules addObject:@{
            @"objectID": feed.objectID,
            @"episodeCount": @(episodeCount),
            @"onlyUnplayed": @(onlyUnplayed),
            @"feedIdentifier": [self _feedIdentifierForFeed:feed] ?: @"",
        }];
    }
    [context reset];

    NSMutableArray<NSDictionary*>* candidates = [NSMutableArray array];
    NSMutableSet<NSString*>* desiredEpisodeHashes = [NSMutableSet set];
    for (NSDictionary* rule in feedRules) {
        if (![self _isAutomaticSelectionGenerationCurrent:generation]) {
            return nil;
        }
        NSError* feedError = nil;
        CDFeed* feed = (CDFeed*)[context existingObjectWithID:rule[@"objectID"] error:&feedError];
        if (!feed) {
            if (error) *error = feedError;
            return nil;
        }

        NSInteger desiredCount = [rule[@"episodeCount"] integerValue];
        BOOL onlyUnplayed = [rule[@"onlyUnplayed"] boolValue];
        NSUInteger fetchOffset = 0;
        NSInteger addedCount = 0;
        while (addedCount < desiredCount) {
            if (![self _isAutomaticSelectionGenerationCurrent:generation]) {
                return nil;
            }
            NSMutableArray<NSPredicate*>* predicates = [@[
                [NSPredicate predicateWithFormat:@"feed == %@", feed],
                [NSPredicate predicateWithFormat:@"archived == %@", @NO],
                [NSPredicate predicateWithFormat:@"video == %@", @NO],
                [NSPredicate predicateWithFormat:@"objectHash != nil"],
                [NSPredicate predicateWithFormat:@"objectHash != %@", @""],
            ] mutableCopy];
            if (onlyUnplayed) {
                [predicates addObject:[NSPredicate predicateWithFormat:@"consumed == %@", @NO]];
            }

            NSFetchRequest* episodeRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
            episodeRequest.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
            episodeRequest.sortDescriptors = @[
                [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO],
                [[NSSortDescriptor alloc] initWithKey:@"objectHash" ascending:YES],
            ];
            episodeRequest.relationshipKeyPathsForPrefetching = @[@"media"];
            episodeRequest.fetchLimit = ICAppleWatchAutomaticFetchPageSize;
            episodeRequest.fetchOffset = fetchOffset;
            NSArray<CDEpisode*>* page = [context executeFetchRequest:episodeRequest error:error];
            if (!page) {
                return nil;
            }

            for (CDEpisode* episode in page) {
                NSString* episodeHash = episode.objectHash;
                if ([suppressedEpisodeHashes containsObject:episodeHash] || [desiredEpisodeHashes containsObject:episodeHash]) {
                    continue;
                }
                if (episode.preferedMedium.fileURL.absoluteString.length == 0) {
                    continue;
                }
                [desiredEpisodeHashes addObject:episodeHash];
                [candidates addObject:@{
                    @"episodeHash": episodeHash,
                    @"feedIdentifier": rule[@"feedIdentifier"],
                    @"pubDate": episode.pubDate ?: startedAt,
                    @"position": @(episode.position),
                }];
                addedCount += 1;
                if (addedCount >= desiredCount) {
                    break;
                }
            }
            fetchOffset += page.count;
            if (page.count < ICAppleWatchAutomaticFetchPageSize) {
                break;
            }
        }
        [context reset];
    }

    NSFetchRequest* stateRequest = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    stateRequest.resultType = NSDictionaryResultType;
    stateRequest.propertiesToFetch = @[@"episodeHash", @"selectionSource"];
    NSArray<NSDictionary*>* stateRows = [context executeFetchRequest:stateRequest error:error];
    if (!stateRows) {
        return nil;
    }
    NSMutableOrderedSet<NSString*>* removalHashes = [NSMutableOrderedSet orderedSet];
    for (NSDictionary* row in stateRows) {
        NSString* episodeHash = [row[@"episodeHash"] isKindOfClass:[NSString class]] ? row[@"episodeHash"] : nil;
        NSString* selectionSource = [row[@"selectionSource"] isKindOfClass:[NSString class]] ? row[@"selectionSource"] : nil;
        if (episodeHash.length > 0 &&
            ![selectionSource isEqualToString:ICAppleWatchSelectionSourceManual] &&
            ![desiredEpisodeHashes containsObject:episodeHash]) {
            [removalHashes addObject:episodeHash];
        }
    }

    return @{
        @"candidates": candidates,
        @"removalHashes": removalHashes.array,
        @"startedAt": startedAt,
    };
}

- (void)_applyAutomaticSelectionPlan:(NSDictionary*)plan generation:(NSUInteger)generation
{
    NSMutableArray<NSDictionary*>* operations = [NSMutableArray array];
    for (NSDictionary* candidate in plan[@"candidates"]) {
        NSMutableDictionary* operation = [candidate mutableCopy];
        operation[@"kind"] = @"desired";
        [operations addObject:operation];
    }
    for (NSString* episodeHash in plan[@"removalHashes"]) {
        [operations addObject:@{ @"kind": @"remove", @"episodeHash": episodeHash }];
    }
    if (operations.count == 0) {
        if ([self _isAutomaticSelectionGenerationCurrent:generation]) {
            [self _postEpisodeStatesChanged];
            [self _sendCurrentManifestAndNotify];
        }
        return;
    }
    [self _applyAutomaticSelectionOperations:operations
                                      offset:0
                                   startedAt:plan[@"startedAt"]
                                  generation:generation];
}

- (void)_applyAutomaticSelectionOperations:(NSArray<NSDictionary*>*)operations
                                     offset:(NSUInteger)offset
                                  startedAt:(NSDate*)startedAt
                                 generation:(NSUInteger)generation
{
    if (![self _isAutomaticSelectionGenerationCurrent:generation]) {
        return;
    }
    NSRange range = NSMakeRange(offset, MIN(ICAppleWatchAutomaticApplyBatchSize, operations.count - offset));
    NSArray<NSDictionary*>* batch = [operations subarrayWithRange:range];
    NSMutableOrderedSet<NSString*>* hashes = [NSMutableOrderedSet orderedSetWithCapacity:batch.count];
    for (NSDictionary* operation in batch) {
        NSString* episodeHash = operation[@"episodeHash"];
        if (episodeHash.length > 0) {
            [hashes addObject:episodeHash];
        }
    }

    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.predicate = [NSPredicate predicateWithFormat:@"episodeHash IN %@", hashes.array];
    NSError* fetchError = nil;
    NSArray<AppleWatchEpisodeState*>* states = [DMANAGER.objectContext executeFetchRequest:request error:&fetchError];
    if (!states) {
        [self _automaticSelectionFailedWithError:fetchError generation:generation];
        return;
    }
    NSMutableDictionary<NSString*, NSMutableArray<AppleWatchEpisodeState*>*>* statesByHash = [NSMutableDictionary dictionary];
    for (AppleWatchEpisodeState* state in states) {
        if (state.episodeHash.length == 0) {
            continue;
        }
        NSMutableArray* matches = statesByHash[state.episodeHash];
        if (!matches) {
            matches = [NSMutableArray array];
            statesByHash[state.episodeHash] = matches;
        }
        [matches addObject:state];
    }

    NSSet<NSString*>* liveSuppressedHashes = [self _suppressedAutomaticEpisodeHashes];
    for (NSDictionary* operation in batch) {
        NSString* episodeHash = operation[@"episodeHash"];
        NSArray<AppleWatchEpisodeState*>* matchingStates = statesByHash[episodeHash] ?: @[];
        if ([operation[@"kind"] isEqualToString:@"remove"] || [liveSuppressedHashes containsObject:episodeHash]) {
            for (AppleWatchEpisodeState* state in matchingStates) {
                if (!state.manuallySelected && !state.removingFromWatch) {
                    state.watchStatus = ICAppleWatchStatusRemoving;
                }
            }
            continue;
        }

        AppleWatchEpisodeState* state = nil;
        BOOL hasManualState = NO;
        for (AppleWatchEpisodeState* candidateState in matchingStates) {
            if (candidateState.manuallySelected) {
                hasManualState = YES;
                break;
            }
            state = state ?: candidateState;
        }
        if (hasManualState) {
            continue;
        }
        BOOL inserted = (state == nil);
        if (inserted) {
            state = [NSEntityDescription insertNewObjectForEntityForName:@"AppleWatchEpisodeState"
                                                   inManagedObjectContext:DMANAGER.objectContext];
            state.episodeHash = episodeHash;
            state.lastPhonePosition = [operation[@"position"] intValue];
            state.lastPhonePositionDate = startedAt;
        }
        if (![state.selectionSource isEqualToString:ICAppleWatchSelectionSourceLatestRule]) {
            state.selectionSource = ICAppleWatchSelectionSourceLatestRule;
        }
        BOOL wasRemovingFromWatch = state.removingFromWatch;
        if (state.watchStatus.length == 0 || wasRemovingFromWatch) {
            state.watchStatus = ICAppleWatchStatusSelected;
        }
        if (wasRemovingFromWatch) {
            state.watchAddedDate = [self _nextWatchSelectionDateAfterDate:state.watchAddedDate];
            state.uid = [NSUUID UUID].UUIDString;
        }
        else if (!state.watchAddedDate) {
            state.watchAddedDate = operation[@"pubDate"] ?: startedAt;
        }
        NSString* feedIdentifier = operation[@"feedIdentifier"];
        if (![state.feedIdentifier isEqualToString:feedIdentifier]) {
            state.feedIdentifier = feedIdentifier;
        }
    }

    NSError* saveError = DMANAGER.objectContext.hasChanges ? [DMANAGER saveReturningError] : nil;
    if (saveError) {
        [self _automaticSelectionFailedWithError:saveError generation:generation];
        return;
    }

    NSUInteger nextOffset = NSMaxRange(range);
    if (nextOffset < operations.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _applyAutomaticSelectionOperations:operations
                                               offset:nextOffset
                                            startedAt:startedAt
                                           generation:generation];
        });
        return;
    }
    if ([self _isAutomaticSelectionGenerationCurrent:generation]) {
        [self _postEpisodeStatesChanged];
        [self _sendCurrentManifestAndNotify];
    }
}

- (void)_automaticSelectionFailedWithError:(NSError*)error generation:(NSUInteger)generation
{
    if (![self _isAutomaticSelectionGenerationCurrent:generation]) {
        return;
    }
    NSString* message = error.localizedDescription ?: @"Apple Watch selections could not be prepared. Check the available storage and try again.".ls;
    [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                  message:@"Automatische Watch-Auswahl fehlgeschlagen"
                                 metadata:@{ @"error": message }];
#if TARGET_OS_IPHONE
    if (App.applicationState == UIApplicationStateActive) {
        [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls message:message duration:8.0];
    }
#endif
    [self _postEpisodeStatesChanged];
    [self _refreshSessionStateAndNotify:YES];
}

- (NSDictionary*)_manifestSnapshotInContext:(NSManagedObjectContext*)context
                                  generation:(NSUInteger)generation
                                       error:(NSError**)error
{
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        return nil;
    }

    NSError* generationError = nil;
    if (![context setQueryGenerationFromToken:[NSQueryGenerationToken currentQueryGenerationToken]
                                         error:&generationError]) {
        if (error) {
            *error = generationError;
        }
        return nil;
    }

    NSFetchRequest* stateRequest = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    stateRequest.resultType = NSDictionaryResultType;
    stateRequest.propertiesToFetch = @[@"episodeHash", @"selectionSource", @"watchStatus", @"watchAddedDate", @"watchLastEventRevision", @"uid"];
    stateRequest.sortDescriptors = @[
        [[NSSortDescriptor alloc] initWithKey:@"watchAddedDate" ascending:NO],
        [[NSSortDescriptor alloc] initWithKey:@"episodeHash" ascending:YES],
        [[NSSortDescriptor alloc] initWithKey:@"watchLastEventRevision" ascending:NO],
        [[NSSortDescriptor alloc] initWithKey:@"watchStatus" ascending:YES],
        [[NSSortDescriptor alloc] initWithKey:@"uid" ascending:YES],
    ];
    stateRequest.fetchLimit = ICAppleWatchEpisodeFetchBatchSize;

    NSMutableOrderedSet<NSString*>* visibleEpisodeHashes = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString*>* seenEpisodeHashes = [NSMutableSet set];
    NSMutableDictionary<NSString*, NSDictionary*>* stateValuesByEpisodeHash = [NSMutableDictionary dictionary];
    NSUInteger stateOffset = 0;
    while (YES) {
        if (![self _isManifestBuildGenerationCurrent:generation]) {
            return nil;
        }
        stateRequest.fetchOffset = stateOffset;
        NSArray<NSDictionary*>* stateRows = [context executeFetchRequest:stateRequest error:error];
        if (!stateRows) {
            return nil;
        }
        for (NSDictionary* row in stateRows) {
            NSString* episodeHash = [row[@"episodeHash"] isKindOfClass:[NSString class]] ? row[@"episodeHash"] : nil;
            NSString* watchStatus = [row[@"watchStatus"] isKindOfClass:[NSString class]] ? row[@"watchStatus"] : nil;
            BOOL removingFromWatch = [watchStatus isEqualToString:ICAppleWatchStatusRemoving];
            if (episodeHash.length == 0) {
                continue;
            }
            if ([seenEpisodeHashes containsObject:episodeHash]) {
                continue;
            }
            [seenEpisodeHashes addObject:episodeHash];
            if (removingFromWatch) {
                continue;
            }
            [visibleEpisodeHashes addObject:episodeHash];
            NSMutableDictionary* values = [NSMutableDictionary dictionaryWithCapacity:3];
            if ([row[@"selectionSource"] isKindOfClass:[NSString class]]) {
                values[@"selectionSource"] = row[@"selectionSource"];
            }
            if ([row[@"watchAddedDate"] isKindOfClass:[NSDate class]]) {
                values[@"watchAddedDate"] = row[@"watchAddedDate"];
            }
            if ([row[@"uid"] isKindOfClass:[NSString class]]) {
                values[@"selectionIdentifier"] = row[@"uid"];
            }
            stateValuesByEpisodeHash[episodeHash] = values;
        }
        stateOffset += stateRows.count;
        if (stateRows.count < ICAppleWatchEpisodeFetchBatchSize) {
            break;
        }
    }

    NSMutableArray<NSDictionary*>* entries = [NSMutableArray arrayWithCapacity:visibleEpisodeHashes.count];
    NSMutableArray<NSString*>* entryEpisodeHashes = [NSMutableArray arrayWithCapacity:visibleEpisodeHashes.count];
    NSArray<NSString*>* episodeHashes = visibleEpisodeHashes.array;
    NSUInteger playbackOrder = 0;
    for (NSUInteger offset = 0; offset < episodeHashes.count; offset += ICAppleWatchEpisodeFetchBatchSize) {
        if (![self _isManifestBuildGenerationCurrent:generation]) {
            return nil;
        }
        NSRange range = NSMakeRange(offset, MIN(ICAppleWatchEpisodeFetchBatchSize, episodeHashes.count - offset));
        NSArray<NSString*>* batch = [episodeHashes subarrayWithRange:range];
        NSFetchRequest* episodeRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        episodeRequest.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", batch];
        episodeRequest.relationshipKeyPathsForPrefetching = @[@"feed", @"feed.properties", @"media"];
        episodeRequest.fetchBatchSize = batch.count;
        NSArray<CDEpisode*>* episodes = [context executeFetchRequest:episodeRequest error:error];
        if (!episodes) {
            return nil;
        }

        NSMutableDictionary<NSString*, CDEpisode*>* episodesByHash = [NSMutableDictionary dictionaryWithCapacity:episodes.count];
        for (CDEpisode* episode in episodes) {
            if (episode.objectHash.length > 0 && !episodesByHash[episode.objectHash]) {
                episodesByHash[episode.objectHash] = episode;
            }
        }
        for (NSString* episodeHash in batch) {
            NSDictionary* stateValues = stateValuesByEpisodeHash[episodeHash];
            NSMutableDictionary* entry = [[self _manifestEntryForEpisode:episodesByHash[episodeHash]
                                                                  selectionSource:stateValues[@"selectionSource"]
                                                                   watchAddedDate:stateValues[@"watchAddedDate"]
                                                              selectionIdentifier:stateValues[@"selectionIdentifier"]] mutableCopy];
            if (!entry) {
                continue;
            }
            entry[@"playbackOrder"] = @(playbackOrder);
            [entries addObject:entry];
            [entryEpisodeHashes addObject:episodeHash];
            playbackOrder += 1;
        }
    }

    return @{
        @"entries": entries,
        @"entryHashes": entryEpisodeHashes,
    };
}

- (void)_sendPreparedManifestPayload:(NSDictionary*)payload
                            snapshot:(NSDictionary*)snapshot
                          generation:(NSUInteger)generation
{
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        return;
    }
    NSArray<NSDictionary*>* entries = snapshot[@"entries"] ?: @[];
    NSURL* fileURL = snapshot[@"manifestFileURL"];
    NSError* deliveryError = nil;
    BOOL didSend = [self _sendManifestPayload:payload fileURL:fileURL error:&deliveryError];
    [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Manifest gesendet" metadata:@{
        @"type": ICAppleWatchManifestReplace,
        @"entryCount": @(entries.count),
        @"didSend": @(didSend),
        @"reachable": @(self.reachable),
        @"watchAppInstalled": @(self.watchAppInstalled),
    }];
    if (!didSend) {
        if (fileURL) {
            dispatch_async(self.manifestBuildQueue, ^{
                [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            });
        }
        if (deliveryError) {
            [self _manifestDeliveryFailedWithError:deliveryError generation:generation];
        } else {
            [self _finishManifestBuildGeneration:generation];
        }
        return;
    }
    NSArray<NSString*>* episodeHashes = snapshot[@"entryHashes"] ?: @[];
    if (episodeHashes.count == 0) {
        self.lastSyncDate = [NSDate date];
        [self _finishManifestBuildGeneration:generation];
        return;
    }
    [self _applyManifestSentStateForEpisodeHashes:episodeHashes offset:0 generation:generation];
}

- (void)_applyManifestSentStateForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
                                         offset:(NSUInteger)offset
                                     generation:(NSUInteger)generation
{
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        return;
    }
    if (offset >= episodeHashes.count) {
        self.lastSyncDate = [NSDate date];
        [self _finishManifestBuildGeneration:generation];
        return;
    }

    NSRange range = NSMakeRange(offset, MIN(ICAppleWatchStateWriteBatchSize, episodeHashes.count - offset));
    NSArray<NSString*>* batch = [episodeHashes subarrayWithRange:range];
    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.predicate = [NSPredicate predicateWithFormat:@"episodeHash IN %@", batch];
    NSError* fetchError = nil;
    NSArray<AppleWatchEpisodeState*>* states = [DMANAGER.objectContext executeFetchRequest:request error:&fetchError];
    if (!states) {
        [self _manifestBuildFailedWithError:fetchError generation:generation];
        return;
    }

    NSMutableDictionary<NSManagedObjectID*, id>* previousStatuses = [NSMutableDictionary dictionary];
    for (AppleWatchEpisodeState* state in states) {
        if (![state.watchStatus isEqualToString:ICAppleWatchStatusSelected]) {
            continue;
        }
        previousStatuses[state.objectID] = state.watchStatus;
        state.watchStatus = ICAppleWatchStatusManifestSent;
    }
    NSError* saveError = DMANAGER.objectContext.hasChanges ? [DMANAGER saveReturningError] : nil;
    if (saveError) {
        for (AppleWatchEpisodeState* state in states) {
            id previousStatus = previousStatuses[state.objectID];
            if (previousStatus) {
                state.watchStatus = (previousStatus == [NSNull null]) ? nil : previousStatus;
            }
        }
        [self _manifestBuildFailedWithError:saveError generation:generation];
        return;
    }

    NSUInteger nextOffset = NSMaxRange(range);
    if (nextOffset < episodeHashes.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _applyManifestSentStateForEpisodeHashes:episodeHashes offset:nextOffset generation:generation];
        });
        return;
    }
    self.lastSyncDate = [NSDate date];
    [self _finishManifestBuildGeneration:generation];
}

- (void)_manifestBuildFailedWithError:(NSError*)error generation:(NSUInteger)generation
{
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        return;
    }
    [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                  message:@"Watch-Manifest konnte nicht vorbereitet werden"
                                 metadata:@{ @"error": error.localizedDescription ?: @"" }];
    if (self.manifestDeliveryInProgress) {
        self.needsManifestSyncAfterActivation = YES;
    }
#if TARGET_OS_IPHONE
    if (App.applicationState == UIApplicationStateActive) {
        [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                  message:error.localizedDescription ?: @"Apple Watch manifest could not be prepared. Check the available storage and try again.".ls
                                 duration:8.0];
    }
#endif
    [self _finishManifestBuildGeneration:generation];
}

- (void)_manifestDeliveryFailedWithError:(NSError*)error generation:(NSUInteger)generation
{
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        return;
    }
    NSError* underlyingError = error.userInfo[NSUnderlyingErrorKey];
    [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                  message:@"Watch-Manifest konnte nicht übertragen werden"
                                 metadata:@{ @"error": underlyingError.localizedDescription ?: error.localizedDescription ?: @"" }];
#if TARGET_OS_IPHONE
    if (App.applicationState == UIApplicationStateActive) {
        [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                  message:error.localizedDescription ?: @"Apple Watch data could not be transferred. Keep the iPhone and Apple Watch nearby and try again.".ls
                                 duration:8.0];
    }
#endif
    [self _finishManifestBuildGeneration:generation];
}

- (void)_finishManifestBuildGeneration:(NSUInteger)generation
{
    if (![self _isManifestBuildGenerationCurrent:generation]) {
        return;
    }
    BOOL shouldBuildAgain = self.manifestBuildRequestedAfterDelivery;
    self.manifestDeliveryInProgress = NO;
    self.manifestBuildRequestedAfterDelivery = NO;
    [self _postEpisodeStatesChanged];
    [self _refreshSessionStateAndNotify:YES];
    if (shouldBuildAgain) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _sendCurrentManifestAndNotify];
        });
    }
}

- (NSDictionary*)_manifestEntryForEpisode:(CDEpisode*)episode
                           selectionSource:(NSString*)selectionSource
                            watchAddedDate:(NSDate*)watchAddedDate
                       selectionIdentifier:(NSString*)selectionIdentifier
{
    if (![self canSendEpisodeToWatch:episode]) {
        return nil;
    }

    NSString* mediaURL = [self _mediaURLStringForEpisode:episode];
    NSString* feedIdentifier = [self _feedIdentifierForFeed:episode.feed];
    NSDate* pubDate = episode.pubDate ?: [NSDate dateWithTimeIntervalSince1970:0];
    NSDate* addedDate = watchAddedDate ?: [NSDate date];
    NSInteger skipForwardSeconds = [self _skipSecondsForEpisode:episode key:PlayerSkipForwardPeriod fallback:30];
    NSInteger skipBackwardSeconds = [self _skipSecondsForEpisode:episode key:PlayerSkipBackPeriod fallback:30];

    // Sponsor-/Kapitel-Skip-Regeln des Feeds, damit die Watch-Kapitelliste markieren kann, was
    // übersprungen wird. Gleiche Semantik wie PlaybackManager: Namen matchen case-insensitiv per
    // containsString; autoSkipSponsors = per-Feed-Override ("yes"/"no"), sonst globales Default.
    NSString* skipNamesKey = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", episode.feed.uid];
    NSString* skipNamesValue = [episode.feed stringForKey:skipNamesKey];
    NSArray* skipChapterNames = (skipNamesValue.length > 0) ? [skipNamesValue componentsSeparatedByString:@".  "] : @[];
    NSString* sponsorsValue = [episode.feed stringForKey:kFeedPropertyAutoSkipSponsors];
    BOOL autoSkipSponsors;
    if ([sponsorsValue isEqualToString:@"yes"]) {
        autoSkipSponsors = YES;
    } else if ([sponsorsValue isEqualToString:@"no"]) {
        autoSkipSponsors = NO;
    } else {
        autoSkipSponsors = [USER_DEFAULTS boolForKey:kAutoSkipSponsors];
    }

    return @{
        @"episodeHash": episode.objectHash ?: @"",
        @"feedIdentifier": feedIdentifier ?: @"",
        @"title": episode.title ?: @"",
        @"podcastTitle": episode.feed.displayTitle ?: episode.feed.title ?: @"",
        @"imageURL": episode.imageURL.absoluteString ?: episode.feed.imageURL.absoluteString ?: @"",
        @"pubDate": [self _stringFromDate:pubDate],
        @"durationHint": @(MAX(0, episode.duration)),
        @"position": @(MAX(0, episode.position)),
        @"consumed": @(episode.consumed),
        @"mediaURL": mediaURL ?: @"",
        @"expectedFileSize": @(MAX((int64_t)0, episode.preferedMedium.byteSize)),
        @"selectionSource": selectionSource ?: ICAppleWatchSelectionSourceManual,
        @"watchAddedDate": [self _stringFromDate:addedDate],
        @"selectionIdentifier": selectionIdentifier ?: @"",
        @"skipForwardSeconds": @(skipForwardSeconds),
        @"skipBackwardSeconds": @(skipBackwardSeconds),
        @"skipChapterNames": skipChapterNames ?: @[],
        @"autoSkipSponsors": @(autoSkipSponsors),
    };
}

- (NSInteger)_skipSecondsForEpisode:(CDEpisode*)episode key:(NSString*)key fallback:(NSInteger)fallback
{
    NSInteger seconds = [episode.feed integerForKey:key];
    if (seconds <= 0) {
        seconds = [USER_DEFAULTS integerForKey:key];
    }
    return seconds > 0 ? seconds : fallback;
}

- (NSString*)_mediaURLStringForEpisode:(CDEpisode*)episode
{
    NSURL* url = episode.preferedMedium.fileURL;
    NSString* value = url.absoluteString;
    return (value.length > 0) ? value : nil;
}

- (NSString*)_feedIdentifierForFeed:(CDFeed*)feed
{
    NSString* source = feed.sourceURL.absoluteString;
    if (source.length > 0) {
        return source;
    }
    return feed.uid ?: @"";
}

- (void)_assignWatchOrderDatesForStates:(NSArray<AppleWatchEpisodeState*>*)states
{
    NSDate* baseDate = [NSDate date];
    [states enumerateObjectsUsingBlock:^(AppleWatchEpisodeState* state, NSUInteger index, BOOL* stop) {
        (void)stop;
        state.watchAddedDate = [baseDate dateByAddingTimeInterval:-(NSTimeInterval)index];
    }];
}

- (NSSet<NSString*>*)_suppressedAutomaticEpisodeHashes
{
    NSArray* storedHashes = [[NSUserDefaults standardUserDefaults] arrayForKey:ICAppleWatchSuppressedAutomaticEpisodeHashesKey];
    return [NSSet setWithArray:storedHashes ?: @[]];
}

- (void)_setSuppressedAutomaticEpisodeHashes:(NSSet<NSString*>*)hashes
{
    NSArray* sortedHashes = [[hashes allObjects] sortedArrayUsingSelector:@selector(compare:)];
    [[NSUserDefaults standardUserDefaults] setObject:sortedHashes forKey:ICAppleWatchSuppressedAutomaticEpisodeHashesKey];
}

- (void)_suppressAutomaticEpisodeHash:(NSString*)episodeHash
{
    if (episodeHash.length == 0) {
        return;
    }

    NSMutableSet* hashes = [[self _suppressedAutomaticEpisodeHashes] mutableCopy];
    [hashes addObject:episodeHash];
    [self _setSuppressedAutomaticEpisodeHashes:hashes];
}

- (void)_unsuppressAutomaticEpisodeHash:(NSString*)episodeHash
{
    if (episodeHash.length == 0) {
        return;
    }

    NSMutableSet* hashes = [[self _suppressedAutomaticEpisodeHashes] mutableCopy];
    if (![hashes containsObject:episodeHash]) {
        return;
    }
    [hashes removeObject:episodeHash];
    [self _setSuppressedAutomaticEpisodeHashes:hashes];
}

- (NSString*)_currentAccentColorHex
{
    UIColor* color = ICTintColor ?: [UIColor colorWithRed:1.f green:83/255.f blue:0.f alpha:1.f];
    UIColor* resolvedColor = [color resolvedColorWithTraitCollection:UIScreen.mainScreen.traitCollection] ?: color;
    CGFloat red = 1.f;
    CGFloat green = 83/255.f;
    CGFloat blue = 0.f;
    CGFloat alpha = 1.f;
    if (![resolvedColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0.f;
        if ([resolvedColor getWhite:&white alpha:&alpha]) {
            red = white;
            green = white;
            blue = white;
        }
    }
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lrint(MAX(0.f, MIN(1.f, red)) * 255.f),
            (int)lrint(MAX(0.f, MIN(1.f, green)) * 255.f),
            (int)lrint(MAX(0.f, MIN(1.f, blue)) * 255.f)];
}

- (void)_playbackDidUpdate:(NSNotification*)notification
{
    CDEpisode* episode = [AudioSession sharedAudioSession].episode ?: [PlaybackManager playbackManager].playingEpisode;
    if (![self isEpisodeSelectedForWatch:episode]) {
        return;
    }

    AppleWatchEpisodeState* state = [self stateForEpisodeHash:episode.objectHash];
    // PlaybackManagerDidUpdateNotification fires EVERY SECOND during playback. Without this
    // diff-gate that meant one Core-Data save plus two WCSession sends per second for the whole
    // playback session. Only propagate when position or consumed actually changed.
    if (state.lastPhonePosition == episode.position && state.watchConsumed == episode.consumed) {
        return;
    }

    NSDate* now = [NSDate date];
    state.lastPhonePosition = episode.position;
    state.lastPhonePositionDate = now;
    if (episode.consumed) {
        state.watchConsumed = YES;
        state.watchConsumedDate = now;
    }
    [DMANAGER save];

    NSDictionary* payload = @{
        ICAppleWatchMessageTypeKey: ICAppleWatchPlaybackPhoneState,
        @"episodeHash": episode.objectHash ?: @"",
        @"position": @(MAX(0, episode.position)),
        @"consumed": @(episode.consumed),
        @"timestamp": [self _stringFromDate:now],
    };
    [self _sendCurrentStateMessage:payload];
}

- (void)_appearanceDidUpdate:(NSNotification*)notification
{
    (void)notification;
    [self _sendCurrentManifestAndNotify];
}

- (void)_sendCommand:(NSDictionary*)command
{
    [self _sendLiveOrQueuedMessage:command];
    [self _refreshSessionStateAndNotify:YES];
}

- (void)_sendLiveOrQueuedMessage:(NSDictionary*)payload
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    WCSession* session = WCSession.defaultSession;
    if (![WCSession isSupported] || session.activationState != WCSessionActivationStateActivated) {
        return;
    }
    if (session.reachable) {
        [session sendMessage:payload replyHandler:nil errorHandler:^(__unused NSError* error) {
            [self _transferUserInfo:payload];
        }];
    }
    else {
        [self _transferUserInfo:payload];
    }
#endif
}

- (void)_sendCurrentStateMessage:(NSDictionary*)payload
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    WCSession* session = WCSession.defaultSession;
    if (![WCSession isSupported] || session.activationState != WCSessionActivationStateActivated) {
        return;
    }

    // WCSession has exactly one outgoing applicationContext. Keep the durable manifest
    // as its root and embed the latest coalesced playback state; replacing the context
    // with a playback-only dictionary left a cold/offline Watch without any episode list.
    NSDictionary* existingContext = session.applicationContext;
    NSString* contextType = existingContext[ICAppleWatchMessageTypeKey];
    if ([contextType isEqualToString:ICAppleWatchManifestReplace] ||
        [contextType isEqualToString:ICAppleWatchManifestFileAvailable]) {
        NSMutableDictionary* mergedContext = [existingContext mutableCopy];
        mergedContext[@"phonePlaybackState"] = payload;
        NSError* contextError = nil;
        [session updateApplicationContext:mergedContext error:&contextError];
        if (contextError) {
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Wiedergabestatus applicationContext fehlgeschlagen" metadata:@{
                @"error": contextError.localizedDescription ?: @"",
            }];
        }
    }
    if (session.reachable) {
        [session sendMessage:payload replyHandler:nil errorHandler:nil];
    }
#endif
}

- (BOOL)_sendManifestPayload:(NSDictionary*)payload fileURL:(NSURL*)fileURL error:(NSError**)outError
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    if (![WCSession isSupported] || !fileURL) {
        return NO;
    }

    WCSession* session = WCSession.defaultSession;
    if (session.activationState != WCSessionActivationStateActivated || !session.watchAppInstalled) {
        self.needsManifestSyncAfterActivation = YES;
        return NO;
    }

    NSNumber* manifestRevision = payload[@"manifestRevision"] ?: @0;
    NSDictionary* descriptor = @{
        ICAppleWatchMessageTypeKey: ICAppleWatchManifestFileAvailable,
        @"protocolVersion": @2,
        @"manifestRevision": manifestRevision,
        @"watchEventProtocolVersion": payload[@"watchEventProtocolVersion"] ?: @1,
        @"createdAt": payload[@"createdAt"] ?: @"",
        @"accentColorHex": payload[@"accentColorHex"] ?: @"",
        @"entryCount": @([payload[@"episodes"] count]),
    };
    BOOL usesFileProtocol = self.watchManifestProtocolVersion >= 2;
    NSError* contextError = nil;
    if (usesFileProtocol) {
        [session updateApplicationContext:descriptor error:&contextError];
    }
    else {
        [session updateApplicationContext:payload error:&contextError];
    }
    if (contextError) {
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Manifest applicationContext fehlgeschlagen" metadata:@{
            @"error": contextError.localizedDescription ?: @"",
        }];
        if (outError) {
            NSString* description = @"Apple Watch data could not be transferred. Keep the iPhone and Apple Watch nearby and try again.".ls;
            if (!usesFileProtocol &&
                [contextError.domain isEqualToString:WCErrorDomain] &&
                contextError.code == WCErrorCodePayloadTooLarge) {
                description = @"Update the Apple Watch app to sync this many episodes.".ls;
            }
            *outError = [NSError errorWithDomain:@"AppleWatchSync"
                                            code:9
                                        userInfo:@{
                NSLocalizedDescriptionKey: description,
                NSUnderlyingErrorKey: contextError,
            }];
        }
        self.needsManifestSyncAfterActivation = YES;
        return NO;
    }

    int64_t previousPendingRevision = [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey];
    if (!usesFileProtocol) {
        [USER_DEFAULTS removeObjectForKey:ICAppleWatchPendingManifestRevisionKey];
        for (WCSessionFileTransfer* transfer in session.outstandingFileTransfers) {
            if ([transfer.file.metadata[ICAppleWatchMessageTypeKey] isEqualToString:ICAppleWatchManifestFileAvailable]) {
                [transfer cancel];
            }
        }
        if (session.reachable) {
            [session sendMessage:payload replyHandler:nil errorHandler:nil];
        }
        dispatch_async(self.manifestBuildQueue, ^{
            [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
            if (previousPendingRevision > 0 && previousPendingRevision != manifestRevision.longLongValue) {
                [[NSFileManager defaultManager] removeItemAtURL:[self _manifestFileURLForRevision:previousPendingRevision]
                                                         error:nil];
            }
        });
        self.legacyManifestRevisionAwaitingResult = manifestRevision.longLongValue;
        self.needsManifestSyncAfterActivation = NO;
        return YES;
    }

    BOOL previousTransferStillOutstanding = NO;
    for (WCSessionFileTransfer* transfer in session.outstandingFileTransfers) {
        if ([transfer.file.metadata[ICAppleWatchMessageTypeKey] isEqualToString:ICAppleWatchManifestFileAvailable]) {
            if ([transfer.file.metadata[@"manifestRevision"] longLongValue] == previousPendingRevision) {
                previousTransferStillOutstanding = YES;
            }
            [transfer cancel];
        }
    }
    [session transferFile:fileURL metadata:descriptor];
    if (session.reachable) {
        [session sendMessage:descriptor replyHandler:nil errorHandler:nil];
    }

    [USER_DEFAULTS setObject:manifestRevision forKey:ICAppleWatchPendingManifestRevisionKey];
    self.legacyManifestRevisionAwaitingResult = 0;
    if (previousPendingRevision > 0 &&
        previousPendingRevision != manifestRevision.longLongValue &&
        !previousTransferStillOutstanding) {
        NSURL* previousFileURL = [self _manifestFileURLForRevision:previousPendingRevision];
        dispatch_async(self.manifestBuildQueue, ^{
            [[NSFileManager defaultManager] removeItemAtURL:previousFileURL error:nil];
        });
    }
    self.needsManifestSyncAfterActivation = NO;
    return YES;
#else
    return NO;
#endif
}

- (BOOL)_transferUserInfo:(NSDictionary*)payload
{
#if IC_WATCH_CONNECTIVITY_ENABLED
    if (![WCSession isSupported]) {
        return NO;
    }
    WCSession* session = WCSession.defaultSession;
    if (session.activationState != WCSessionActivationStateActivated) {
        return NO;
    }
    [session transferUserInfo:payload];
    return YES;
#else
    return NO;
#endif
}

- (NSURL*)_watchDeletionInboxDirectoryURL
{
    NSURL* supportURL = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                 inDomains:NSUserDomainMask] firstObject];
    return [supportURL URLByAppendingPathComponent:ICAppleWatchDeletionInboxDirectoryName isDirectory:YES];
}

- (BOOL)_isWatchDeletionPayload:(NSDictionary*)payload
{
    NSString* type = [payload[ICAppleWatchMessageTypeKey] isKindOfClass:[NSString class]] ? payload[ICAppleWatchMessageTypeKey] : nil;
    return [type isEqualToString:@"watch.deleted"] || [type isEqualToString:@"watch.deletedEpisodes"];
}

- (NSURL*)_stageIncomingWatchDeletionPayload:(NSDictionary*)payload error:(NSError**)error
{
    NSData* data = [NSPropertyListSerialization dataWithPropertyList:payload
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0
                                                                error:error];
    if (!data || data.length > ICAppleWatchMaximumDeletionInboxPayloadBytes) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"AppleWatchSync"
                                         code:32
                                     userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch changes could not be applied. Try syncing again.".ls}];
        }
        return nil;
    }

    NSURL* directoryURL = [self _watchDeletionInboxDirectoryURL];
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                                        error:error]) {
        return nil;
    }
    [directoryURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    NSString* filename = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"plist"];
    NSURL* fileURL = [directoryURL URLByAppendingPathComponent:filename isDirectory:NO];
    if (![data writeToURL:fileURL options:NSDataWritingAtomic error:error]) {
        return nil;
    }
    return fileURL;
}

- (void)_scheduleWatchDeletionInboxProcessing
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _scheduleWatchDeletionInboxProcessing];
        });
        return;
    }
    if (self.watchDeletionInboxProcessing) {
        self.watchDeletionInboxProcessingRequested = YES;
        return;
    }
    self.watchDeletionInboxProcessing = YES;
    self.watchDeletionInboxProcessingRequested = NO;

    dispatch_async(self.watchDeletionInboxQueue, ^{
        NSURL* directoryURL = [self _watchDeletionInboxDirectoryURL];
        NSError* readError = nil;
        NSArray<NSURL*>* fileURLs = @[];
        if ([[NSFileManager defaultManager] fileExistsAtPath:directoryURL.path]) {
            fileURLs = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directoryURL
                                                     includingPropertiesForKeys:nil
                                                                        options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                          error:&readError];
        }
        fileURLs = [fileURLs sortedArrayUsingComparator:^NSComparisonResult(NSURL* first, NSURL* second) {
            return [first.lastPathComponent compare:second.lastPathComponent];
        }];
        NSURL* fileURL = fileURLs.firstObject;
        if (!fileURL || readError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (readError) {
                    [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                                  message:@"Watch-Lösch-Inbox konnte nicht gelesen werden"
                                                 metadata:@{ @"error": readError.localizedDescription ?: @"" }];
                }
                [self _finishWatchDeletionInboxProcessing:NO];
            });
            return;
        }

        NSData* data = [NSData dataWithContentsOfURL:fileURL options:0 error:&readError];
        NSDictionary* payload = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                                  options:NSPropertyListImmutable
                                                                                   format:nil
                                                                                    error:&readError] : nil;
        if (![payload isKindOfClass:[NSDictionary class]] || ![self _isWatchDeletionPayload:payload]) {
            NSError* removalError = nil;
            BOOL removed = [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&removalError];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                              message:@"Ungültige Watch-Lösch-Inbox-Datei verworfen"
                                             metadata:@{ @"error": (readError ?: removalError).localizedDescription ?: @"" }];
                [self _finishWatchDeletionInboxProcessing:removed];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _commitStagedWatchDeletionPayload:payload fileURL:fileURL];
        });
    });
}

- (void)_finishWatchDeletionInboxProcessing:(BOOL)processNext
{
    self.watchDeletionInboxProcessing = NO;
    BOOL shouldProcessNext = processNext || self.watchDeletionInboxProcessingRequested;
    self.watchDeletionInboxProcessingRequested = NO;
    if (shouldProcessNext) {
        [self _scheduleWatchDeletionInboxProcessing];
    }
}

- (BOOL)_sendWatchDeletionAcknowledgementForPayload:(NSDictionary*)payload
{
    NSArray* episodeHashes = nil;
    NSArray* selectionIdentifiers = nil;
    NSArray* selectionDates = nil;
    NSString* type = payload[ICAppleWatchMessageTypeKey];
    if ([type isEqualToString:@"watch.deletedEpisodes"]) {
        episodeHashes = payload[@"episodeHashes"];
        selectionIdentifiers = payload[@"selectionIdentifiers"];
    }
    else {
        NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
        NSString* selectionIdentifier = [payload[@"selectionIdentifier"] isKindOfClass:[NSString class]] ? payload[@"selectionIdentifier"] : nil;
        NSString* selectionDate = [payload[@"selectionDate"] isKindOfClass:[NSString class]] ? payload[@"selectionDate"] : nil;
        if (episodeHash.length == 0 || (selectionIdentifier.length == 0 && selectionDate.length == 0)) {
            return YES;
        }
        episodeHashes = @[episodeHash];
        if (selectionIdentifier.length > 0) {
            selectionIdentifiers = @[selectionIdentifier];
        }
        else {
            selectionDates = @[selectionDate];
        }
    }
    NSMutableDictionary* acknowledgement = [@{
        ICAppleWatchMessageTypeKey: @"phone.ackDeletedEpisodes",
        @"episodeHashes": episodeHashes ?: @[],
        @"timestamp": [self _stringFromDate:[NSDate date]],
    } mutableCopy];
    if (selectionIdentifiers.count > 0) {
        acknowledgement[@"selectionIdentifiers"] = selectionIdentifiers;
    }
    else if (selectionDates.count > 0) {
        acknowledgement[@"selectionDates"] = selectionDates;
    }
    return [self _transferUserInfo:acknowledgement];
}

- (void)_presentWatchDeletionProcessingError
{
#if TARGET_OS_IPHONE
    if (App.applicationState == UIApplicationStateActive) {
        [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                  message:@"Apple Watch changes could not be applied. Try syncing again.".ls
                                 duration:8.0];
    }
#endif
}

- (void)_commitStagedWatchDeletionPayload:(NSDictionary*)payload fileURL:(NSURL*)fileURL
{
    NSError* preflightSaveError = DMANAGER.objectContext.hasChanges ? [DMANAGER saveReturningError] : nil;
    if (preflightSaveError) {
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Lokale Änderungen vor Watch-Löschung konnten nicht gespeichert werden"
                                     metadata:@{ @"error": preflightSaveError.localizedDescription ?: @"" }];
        [self _presentWatchDeletionProcessingError];
        [self _finishWatchDeletionInboxProcessing:NO];
        return;
    }

    NSError* applyError = nil;
    BOOL shouldSyncAfterHandling = NO;
    NSString* type = payload[ICAppleWatchMessageTypeKey];
    if ([type isEqualToString:@"watch.deletedEpisodes"]) {
        shouldSyncAfterHandling = [self _applyWatchDeletedEpisodesPayload:payload error:&applyError];
    }
    else {
        NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
        NSError* fetchError = nil;
        NSDictionary<NSString*, NSArray<AppleWatchEpisodeState*>*>* statesByHash =
            [self _statesByHashForEpisodeHashes:episodeHash ? @[episodeHash] : @[] error:&fetchError];
        if (!statesByHash) {
            applyError = fetchError;
        }
        else {
            NSArray<AppleWatchEpisodeState*>* matchingStates = statesByHash[episodeHash] ?: @[];
            NSString* selectionIdentifier = [payload[@"selectionIdentifier"] isKindOfClass:[NSString class]] ? payload[@"selectionIdentifier"] : nil;
            AppleWatchEpisodeState* matchingState = nil;
            for (AppleWatchEpisodeState* state in matchingStates) {
                if (selectionIdentifier.length > 0 && [state.uid isEqualToString:selectionIdentifier]) {
                    matchingState = state;
                    break;
                }
                if (selectionIdentifier.length == 0 && state.removingFromWatch) {
                    matchingState = state;
                    break;
                }
            }
            if (!matchingState && selectionIdentifier.length == 0 && self.watchManifestProtocolVersion < 3) {
                matchingState = matchingStates.firstObject;
            }
            shouldSyncAfterHandling = [self _applyWatchDeletedPayload:payload state:matchingState];
        }
    }
    if (applyError) {
        if (DMANAGER.objectContext.hasChanges) {
            [DMANAGER.objectContext rollback];
        }
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Löschung konnte nicht angewendet werden"
                                     metadata:@{ @"error": applyError.localizedDescription ?: @"" }];
        [self _presentWatchDeletionProcessingError];
        [self _finishWatchDeletionInboxProcessing:NO];
        return;
    }

    NSError* saveError = DMANAGER.objectContext.hasChanges ? [DMANAGER saveReturningError] : nil;
    if (saveError) {
        [DMANAGER.objectContext rollback];
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Löschung konnte nicht gespeichert werden"
                                     metadata:@{ @"error": saveError.localizedDescription ?: @"" }];
        [self _presentWatchDeletionProcessingError];
        [self _finishWatchDeletionInboxProcessing:NO];
        return;
    }
    if (![self _sendWatchDeletionAcknowledgementForPayload:payload]) {
        [self _presentWatchDeletionProcessingError];
        [self _finishWatchDeletionInboxProcessing:NO];
        return;
    }

    [self _postEpisodeStatesChanged];
    [self _refreshSessionStateAndNotify:YES];
    if (shouldSyncAfterHandling) {
        [self syncNow];
    }
    dispatch_async(self.watchDeletionInboxQueue, ^{
        NSError* removalError = nil;
        BOOL removed = [[NSFileManager defaultManager] removeItemAtURL:fileURL error:&removalError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (removalError) {
                [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                              message:@"Verarbeitete Watch-Lösch-Inbox-Datei konnte nicht entfernt werden"
                                             metadata:@{ @"error": removalError.localizedDescription ?: @"" }];
            }
            [self _finishWatchDeletionInboxProcessing:removed];
        });
    });
}

- (BOOL)_applyWatchDeletedPayload:(NSDictionary*)payload state:(AppleWatchEpisodeState*)state
{
    if (!state) {
        return NO;
    }
    NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
    NSString* selectionIdentifier = [payload[@"selectionIdentifier"] isKindOfClass:[NSString class]] ? payload[@"selectionIdentifier"] : nil;
    NSString* selectionDate = [payload[@"selectionDate"] isKindOfClass:[NSString class]] ? payload[@"selectionDate"] : nil;
    BOOL matchesCurrentSelection = state.removingFromWatch;
    if (!state.removingFromWatch && selectionIdentifier.length > 0) {
        matchesCurrentSelection = [selectionIdentifier isEqualToString:state.uid];
    }
    else if (!state.removingFromWatch && self.watchManifestProtocolVersion < 3 && selectionDate.length > 0 && state.watchAddedDate) {
        matchesCurrentSelection = [selectionDate isEqualToString:[self _stringFromDate:state.watchAddedDate]];
    }
    if (!matchesCurrentSelection && selectionIdentifier.length == 0) {
#if TARGET_OS_IPHONE
        if (App.applicationState == UIApplicationStateActive) {
            [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                      message:@"Update the Apple Watch app to remove episodes from the Watch.".ls
                                     duration:8.0];
        }
#endif
    }
    if (!matchesCurrentSelection) {
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Veraltete Watch-Löschung ignoriert"
                                     metadata:@{ @"episodeHash": episodeHash ?: @"" }];
        return NO;
    }
    NSMutableDictionary* orderedPayload = [payload mutableCopy];
    if (state.removingFromWatch && selectionIdentifier.length == 0 && state.uid.length > 0) {
        orderedPayload[@"selectionIdentifier"] = state.uid;
    }
    if (![self _shouldApplyWatchEventPayload:orderedPayload toState:state]) {
        return NO;
    }

    [self _clearCurrentWatchDownloadIfMatchesHash:episodeHash];
    if (state.removingFromWatch) {
        [DMANAGER.objectContext deleteObject:state];
        return NO;
    }
    if ([state.selectionSource isEqualToString:ICAppleWatchSelectionSourceLatestRule]) {
        [self _suppressAutomaticEpisodeHash:episodeHash];
    }
    [DMANAGER.objectContext deleteObject:state];
    return YES;
}

- (BOOL)_applyWatchDeletedEpisodesPayload:(NSDictionary*)payload error:(NSError**)error
{
    NSArray* episodeHashes = [payload[@"episodeHashes"] isKindOfClass:[NSArray class]] ? payload[@"episodeHashes"] : nil;
    NSArray* selectionIdentifiers = [payload[@"selectionIdentifiers"] isKindOfClass:[NSArray class]] ? payload[@"selectionIdentifiers"] : nil;
    BOOL validPayload = episodeHashes.count > 0 &&
        episodeHashes.count <= ICAppleWatchMaximumDeletionAcknowledgementCount &&
        episodeHashes.count == selectionIdentifiers.count;
    NSMutableSet<NSString*>* uniqueHashes = [NSMutableSet setWithCapacity:episodeHashes.count];
    if (validPayload) {
        for (NSUInteger index = 0; index < episodeHashes.count; index++) {
            NSString* episodeHash = [episodeHashes[index] isKindOfClass:[NSString class]] ? episodeHashes[index] : nil;
            NSString* selectionIdentifier = [selectionIdentifiers[index] isKindOfClass:[NSString class]] ? selectionIdentifiers[index] : nil;
            if (episodeHash.length == 0 || selectionIdentifier.length == 0 || [uniqueHashes containsObject:episodeHash]) {
                validPayload = NO;
                break;
            }
            [uniqueHashes addObject:episodeHash];
        }
    }
    if (!validPayload) {
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Ungültige gebündelte Watch-Löschung ignoriert"
                                     metadata:@{
            @"episodeHashCount": @(episodeHashes.count),
            @"selectionIdentifierCount": @(selectionIdentifiers.count),
        }];
        if (error) {
            *error = [NSError errorWithDomain:@"AppleWatchSync"
                                         code:30
                                     userInfo:@{NSLocalizedDescriptionKey: @"The Apple Watch sent invalid deletion data."}];
        }
        return NO;
    }

    NSError* fetchError = nil;
    NSDictionary<NSString*, NSArray<AppleWatchEpisodeState*>*>* statesByHash =
        [self _statesByHashForEpisodeHashes:episodeHashes error:&fetchError];
    if (!statesByHash) {
        NSString* message = @"Apple Watch changes could not be applied. Try syncing again.".ls;
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Gebündelte Watch-Löschungen konnten nicht geladen werden"
                                     metadata:@{ @"error": fetchError.localizedDescription ?: @"" }];
#if TARGET_OS_IPHONE
        if (App.applicationState == UIApplicationStateActive) {
            [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls message:message duration:8.0];
        }
#endif
        if (error) {
            *error = fetchError ?: [NSError errorWithDomain:@"AppleWatchSync"
                                                     code:31
                                                 userInfo:@{NSLocalizedDescriptionKey: message}];
        }
        return NO;
    }

    BOOL shouldSyncAfterHandling = NO;
    for (NSUInteger index = 0; index < episodeHashes.count; index++) {
        NSString* episodeHash = episodeHashes[index];
        NSString* selectionIdentifier = selectionIdentifiers[index];
        NSMutableDictionary* entryPayload = [payload mutableCopy];
        entryPayload[@"episodeHash"] = episodeHash;
        entryPayload[@"selectionIdentifier"] = selectionIdentifier;
        for (AppleWatchEpisodeState* state in statesByHash[episodeHash]) {
            if ([state.uid isEqualToString:selectionIdentifier]) {
                shouldSyncAfterHandling |= [self _applyWatchDeletedPayload:entryPayload state:state];
            }
        }
    }
    return shouldSyncAfterHandling;
}

- (void)_handleIncomingPayload:(NSDictionary*)payload
{
    NSString* type = [payload[ICAppleWatchMessageTypeKey] isKindOfClass:[NSString class]] ? payload[ICAppleWatchMessageTypeKey] : nil;
    if (type.length == 0) {
        return;
    }
    if ([self _isWatchDeletionPayload:payload]) {
        NSError* stageError = nil;
        NSURL* stagedURL = [self _stageIncomingWatchDeletionPayload:payload error:&stageError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (stagedURL) {
                [self _scheduleWatchDeletionInboxProcessing];
                return;
            }
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                          message:@"Watch-Löschung konnte nicht dauerhaft empfangen werden"
                                         metadata:@{ @"error": stageError.localizedDescription ?: @"" }];
#if TARGET_OS_IPHONE
            if (App.applicationState == UIApplicationStateActive) {
                [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                          message:@"Apple Watch changes could not be applied. Try syncing again.".ls
                                         duration:8.0];
            }
#endif
        });
        return;
    }

    if (ICAppleWatchIsOrderedDownloadEventType(type)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _enqueueOrderedWatchDownloadPayload:payload type:type];
        });
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self _handleIncomingPayloadOnMainThread:payload type:type];
    });
}

- (void)_enqueueOrderedWatchDownloadPayload:(NSDictionary*)payload type:(NSString*)type
{
    if (payload.count == 0 || type.length == 0) {
        return;
    }
    [self.pendingOrderedWatchDownloadPayloads addObject:@{
        @"payload": [payload copy],
        @"type": [type copy],
    }];
    [self _processNextOrderedWatchDownloadPayload];
}

- (void)_processNextOrderedWatchDownloadPayload
{
    if (self.orderedWatchDownloadPayloadProcessing ||
        self.pendingOrderedWatchDownloadPayloadIndex >= self.pendingOrderedWatchDownloadPayloads.count) {
        return;
    }

    self.orderedWatchDownloadPayloadProcessing = YES;
    NSDictionary* entry = self.pendingOrderedWatchDownloadPayloads[self.pendingOrderedWatchDownloadPayloadIndex];
    NSDictionary* payload = [entry[@"payload"] isKindOfClass:[NSDictionary class]] ? entry[@"payload"] : @{};
    NSString* type = [entry[@"type"] isKindOfClass:[NSString class]] ? entry[@"type"] : @"";
    if ([type isEqualToString:@"watch.downloadProgress"]) {
        [self _persistWatchProgressRevisionForPayload:payload];
        return;
    }

    [self _handleIncomingPayloadOnMainThread:payload type:type];
    [self _finishOrderedWatchDownloadPayload];
}

- (void)_finishOrderedWatchDownloadPayload
{
    self.orderedWatchDownloadPayloadProcessing = NO;
    self.pendingOrderedWatchDownloadPayloadIndex += 1;
    if (self.pendingOrderedWatchDownloadPayloadIndex >= self.pendingOrderedWatchDownloadPayloads.count) {
        [self.pendingOrderedWatchDownloadPayloads removeAllObjects];
        self.pendingOrderedWatchDownloadPayloadIndex = 0;
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self _processNextOrderedWatchDownloadPayload];
    });
}

- (void)_persistWatchProgressRevisionForPayload:(NSDictionary*)payload
{
    self.lastWatchStatusDate = [NSDate date];
    AppleWatchEpisodeState* state = [self _stateForWatchEventPayload:payload];
    if (!state) {
        [self _finishOrderedWatchDownloadPayload];
        return;
    }
    int64_t eventRevision = [self _acceptedWatchEventRevisionForPayload:payload
                                                                toState:state
                                                    advanceDurableState:NO];
    if (eventRevision <= 0 || state.episodeHash.length == 0 || state.uid.length == 0) {
        [self _finishOrderedWatchDownloadPayload];
        return;
    }

    NSMutableDictionary* persistedPayload = [payload mutableCopy];
    persistedPayload[@"watchEventRevision"] = @(eventRevision);
    NSString* episodeHash = [state.episodeHash copy];
    NSString* selectionIdentifier = [state.uid copy];
    NSManagedObjectContext* context = self.watchEventRevisionPersistenceContext;
    if (!context) {
        context = [DMANAGER newBackgroundContext];
        context.name = @"Apple Watch progress revision persistence";
        self.watchEventRevisionPersistenceContext = context;
    }
    if (!context) {
        NSError* error = [NSError errorWithDomain:@"AppleWatchSync"
                                             code:40
                                         userInfo:@{NSLocalizedDescriptionKey: @"Apple Watch progress could not be saved.".ls}];
        [self _finishPersistedWatchProgressPayload:persistedPayload updatedObjectIDs:@[] error:error];
        return;
    }

    [context performBlock:^{
        NSBatchUpdateRequest* updateRequest = [[NSBatchUpdateRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
        updateRequest.predicate = [NSPredicate predicateWithFormat:
            @"episodeHash == %@ AND uid == %@ AND watchLastEventRevision < %@",
            episodeHash,
            selectionIdentifier,
            @(eventRevision)];
        updateRequest.propertiesToUpdate = @{@"watchLastEventRevision": @(eventRevision)};
        updateRequest.resultType = NSUpdatedObjectIDsResultType;
        NSError* updateError = nil;
        NSBatchUpdateResult* result = (NSBatchUpdateResult*)[context executeRequest:updateRequest error:&updateError];
        NSArray<NSManagedObjectID*>* updatedObjectIDs = [result.result isKindOfClass:[NSArray class]] ? result.result : @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _finishPersistedWatchProgressPayload:persistedPayload
                                      updatedObjectIDs:updatedObjectIDs
                                                 error:updateError];
        });
    }];
}

- (void)_finishPersistedWatchProgressPayload:(NSDictionary*)payload
                            updatedObjectIDs:(NSArray<NSManagedObjectID*>*)updatedObjectIDs
                                       error:(NSError*)error
{
    if (error) {
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Fortschrittsreihenfolge konnte nicht gespeichert werden"
                                     metadata:@{ @"error": error.localizedDescription ?: @"" }];
        [self _finishOrderedWatchDownloadPayload];
        return;
    }

    AppleWatchEpisodeState* currentState = [self _stateForWatchEventPayload:payload];
    if (!currentState || ![updatedObjectIDs containsObject:currentState.objectID]) {
        [self _finishOrderedWatchDownloadPayload];
        return;
    }

    AppleWatchEpisodeState* state = [self _applyPersistedTransientDownloadProgressPayload:payload];
    [NSManagedObjectContext mergeChangesFromRemoteContextSave:@{ NSUpdatedObjectsKey: updatedObjectIDs }
                                                  intoContexts:@[DMANAGER.objectContext]];
    if (state) {
        [self _postLiveStatusChangedForEpisodeHashes:@[state.episodeHash ?: @""]];
    }
    [self _finishOrderedWatchDownloadPayload];
}

- (void)_handleIncomingPayloadOnMainThread:(NSDictionary*)payload type:(NSString*)type
{
    self.lastWatchStatusDate = [NSDate date];

    // Diagnostics are by far the highest-volume watch messages (every WatchDiagnostics.log event,
    // and unreachable phases queue them up via transferUserInfo and deliver them in one burst).
    // They change no model state — handle them without the Core-Data-save/notification tail below,
    // which otherwise turns a reconnect burst into a main-thread freeze.
    if ([type isEqualToString:@"watch.diagnostic"]) {
        NSString* event = [payload[@"event"] isKindOfClass:[NSString class]] ? payload[@"event"] : @"";
        NSString* message = [payload[@"message"] isKindOfClass:[NSString class]] ? payload[@"message"] : @"Watch-Diagnose";
        NSDictionary* watchMetadata = [payload[@"metadata"] isKindOfClass:[NSDictionary class]] ? payload[@"metadata"] : @{};
        NSMutableDictionary* metadata = [watchMetadata mutableCopy];
        metadata[@"watchEvent"] = event ?: @"";
        metadata[@"watchTimestamp"] = [payload[@"timestamp"] isKindOfClass:[NSString class]] ? payload[@"timestamp"] : @"";
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:message metadata:metadata];
        return;
    }

    if ([type isEqualToString:@"watch.requestManifest"]) {
        NSNumber* protocolVersion = [payload[@"manifestProtocolVersion"] isKindOfClass:[NSNumber class]] ?
            payload[@"manifestProtocolVersion"] : nil;
        self.watchManifestProtocolVersion = MAX(self.watchManifestProtocolVersion,
                                                MAX((NSInteger)1, protocolVersion.integerValue));
#if IC_WATCH_CONNECTIVITY_ENABLED
        [self _storeWatchManifestProtocolVersion:self.watchManifestProtocolVersion
                                      forSession:WCSession.defaultSession];
#endif
        [self syncNow];
        return;
    }

    if ([type isEqualToString:@"watch.manifestFailed"]) {
        int64_t manifestRevision = [payload[@"manifestRevision"] longLongValue];
        int64_t pendingFileRevision = [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey];
        BOOL matchesPendingFile = manifestRevision > 0 && manifestRevision == pendingFileRevision;
        BOOL matchesPendingLegacy = manifestRevision > 0 && manifestRevision == self.legacyManifestRevisionAwaitingResult;
        if (!matchesPendingFile && !matchesPendingLegacy) {
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                          message:@"Veralteten Watch-Manifestfehler ignoriert"
                                         metadata:@{
                @"manifestRevision": @(manifestRevision),
                @"pendingFileRevision": @(pendingFileRevision),
                @"pendingLegacyRevision": @(self.legacyManifestRevisionAwaitingResult),
            }];
            return;
        }
        if (matchesPendingLegacy) {
            self.legacyManifestRevisionAwaitingResult = 0;
        }
        self.needsManifestSyncAfterActivation = YES;
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Manifest konnte auf der Watch nicht gespeichert werden"
                                     metadata:@{
            @"manifestRevision": payload[@"manifestRevision"] ?: @0,
            @"error": [payload[@"error"] isKindOfClass:[NSString class]] ? payload[@"error"] : @"",
        }];
#if TARGET_OS_IPHONE
        if (App.applicationState == UIApplicationStateActive) {
            [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                      message:@"Apple Watch could not save the synchronized episodes. Check free storage on the Apple Watch and try again.".ls
                                     duration:8.0];
        }
#endif
        [self _refreshSessionStateAndNotify:YES];
        return;
    }

    if ([type isEqualToString:@"watch.ackManifest"]) {
        NSNumber* revisionNumber = [payload[@"manifestRevision"] isKindOfClass:[NSNumber class]] ? payload[@"manifestRevision"] : nil;
        NSArray* episodeHashes = [payload[@"episodeHashes"] isKindOfClass:[NSArray class]] ? payload[@"episodeHashes"] : @[];
        if (revisionNumber.longLongValue > 0 &&
            revisionNumber.longLongValue == self.legacyManifestRevisionAwaitingResult) {
            self.legacyManifestRevisionAwaitingResult = 0;
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Manifest bestaetigt" metadata:@{
                @"manifestRevision": revisionNumber,
                @"episodeCount": @(episodeHashes.count),
            }];
            [self _applyManifestAcknowledgementForEpisodeHashes:episodeHashes];
            return;
        }
        if (revisionNumber.longLongValue > 0) {
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Manifest bestaetigt" metadata:@{
                @"manifestRevision": revisionNumber,
            }];
            [self _applyManifestAcknowledgementForRevision:revisionNumber.longLongValue];
            return;
        }
        self.legacyManifestRevisionAwaitingResult = 0;
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Manifest bestaetigt" metadata:@{
            @"episodeCount": @(episodeHashes.count),
        }];
        [self _applyManifestAcknowledgementForEpisodeHashes:episodeHashes];
        return;
    }
    NSMutableArray<NSString*>* changedEpisodeHashes = [NSMutableArray array];
    if ([type isEqualToString:@"watch.downloadQueued"]) {
        AppleWatchEpisodeState* state = [self _updateStateForPayload:payload status:ICAppleWatchStatusQueuedOnWatch error:nil];
        if (state) {
            [self _clearCurrentWatchDownloadIfMatchesHash:state.episodeHash];
            [changedEpisodeHashes addObject:state.episodeHash ?: @""];
        }
    }
    else if ([type isEqualToString:@"watch.downloadProgress"]) {
        AppleWatchEpisodeState* state = [self _applyTransientDownloadProgressPayload:payload];
        if (state) {
            [self _postLiveStatusChangedForEpisodeHashes:@[state.episodeHash ?: @""]];
        }
        return;
    }
    else if ([type isEqualToString:@"watch.downloaded"]) {
        AppleWatchEpisodeState* state = [self _updateStateForPayload:payload status:ICAppleWatchStatusDownloaded error:nil];
        if (state) {
            state.watchDownloadedDate = [self _dateFromPayload:payload key:@"timestamp"] ?: [NSDate date];
            state.watchActualDuration = [payload[@"actualDuration"] intValue];
            state.watchActualFileSize = [payload[@"actualFileSize"] longLongValue];
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Download abgeschlossen" metadata:@{
                @"episodeHash": state.episodeHash ?: @"",
                @"actualFileSize": @(state.watchActualFileSize),
                @"actualDuration": @(state.watchActualDuration),
            }];
            [self _clearCurrentWatchDownloadIfMatchesHash:state.episodeHash];
            [changedEpisodeHashes addObject:state.episodeHash ?: @""];
        }
    }
    else if ([type isEqualToString:@"watch.downloadFailed"]) {
        NSString* error = [payload[@"error"] isKindOfClass:[NSString class]] ? payload[@"error"] : @"";
        AppleWatchEpisodeState* state = [self _updateStateForPayload:payload status:ICAppleWatchStatusFailed error:error];
        if (state) {
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Download fehlgeschlagen" metadata:@{
                @"episodeHash": state.episodeHash ?: @"",
                @"error": error ?: @"",
            }];
            [self _clearCurrentWatchDownloadIfMatchesHash:state.episodeHash];
            [changedEpisodeHashes addObject:state.episodeHash ?: @""];
        }
    }
    else if ([type isEqualToString:@"watch.downloadEvicted"]) {
        NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
        AppleWatchEpisodeState* state = [self _stateForWatchEventPayload:payload];
        if (state && [self _shouldApplyWatchEventPayload:payload toState:state]) {
            [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Download wegen Speicher entfernt" metadata:@{
                @"episodeHash": episodeHash ?: @"",
                @"reason": [payload[@"reason"] isKindOfClass:[NSString class]] ? payload[@"reason"] : @"",
            }];
            [self _clearCurrentWatchDownloadIfMatchesHash:episodeHash];
            // The watch evicted this for storage. Mirror that state instead of resetting to "queued"
            // (which made the phone show "Wartet" while the watch showed "Speicher voll").
            state.watchStatus = ICAppleWatchStatusEvicted;
            state.watchLastError = @"Nicht genügend Speicher auf der Watch.".ls;
            state.watchDownloadedDate = nil;
            state.watchActualFileSize = 0;
            state.watchActualDuration = 0;
            [changedEpisodeHashes addObject:state.episodeHash ?: @""];
        }
    }
    else if ([type isEqualToString:@"watch.storageStatus"]) {
        self.watchFreeBytes = [payload[@"freeBytes"] longLongValue];
        self.watchUsedBytes = [payload[@"usedBytes"] longLongValue];
        self.watchTotalBytes = [payload[@"totalBytes"] longLongValue];
        self.watchDownloadBytes = [payload[@"instacastWatchDownloadBytes"] longLongValue];
        // The single most important signal for the eviction/thrash diagnosis: does the wanted set
        // fit? wantedBytes vs (freeBytes + downloadedBytes) shows it at a glance. Previously this
        // arrived on the phone but was never written to the diagnostics log.
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch" message:@"Watch-Speicherstatus" metadata:@{
            @"freeBytes": @(self.watchFreeBytes),
            // Diagnostics: the old typed Swift Int capacity value. A field log with freeBytes ~18 GB
            // and rawFreeBytes negative confirms the watchOS arm64_32 truncation fix landed.
            @"rawFreeBytes": payload[@"rawFreeBytes"] ?: @0,
            @"totalBytes": @(self.watchTotalBytes),
            @"appDownloadBytes": @(self.watchDownloadBytes),
            @"downloadedCount": payload[@"downloadedCount"] ?: @0,
            @"downloadedBytes": payload[@"downloadedBytes"] ?: @0,
            @"wantedBytes": payload[@"wantedBytes"] ?: @0,
            @"episodeCount": payload[@"episodeCount"] ?: @0,
            @"playingHash": payload[@"playingHash"] ?: @"",
            @"watchTimestamp": payload[@"watchTimestamp"] ?: @"",
        }];
        [self _postLiveStatusChangedForEpisodeHashes:@[]];
        [self _refreshSessionStateAndNotify:YES];
        return;
    }
    else if ([type isEqualToString:@"playback.watchPosition"] || [type isEqualToString:@"playback.watchFinished"]) {
        [self _mergeWatchPlaybackPayload:payload finished:[type isEqualToString:@"playback.watchFinished"]];
        NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
        if (episodeHash.length > 0) {
            [changedEpisodeHashes addObject:episodeHash];
        }
    }

    // Only save when a handler actually changed the model. High-frequency messages
    // (downloadProgress every 2 s, storageStatus) previously forced a main-thread save plus the
    // whole observer cascade per message — a reconnect burst froze the UI for many seconds.
    if (DMANAGER.objectContext.hasChanges) {
        [DMANAGER save];
    }
    if (changedEpisodeHashes.count > 0) {
        [self _postEpisodeStatesChangedForEpisodeHashes:changedEpisodeHashes];
    }
    else {
        [self _postEpisodeStatesChanged];
    }
    [self _refreshSessionStateAndNotify:YES];
}

- (void)_applyManifestAcknowledgementForRevision:(int64_t)manifestRevision
{
    int64_t pendingRevision = [USER_DEFAULTS objectForKey:ICAppleWatchPendingManifestRevisionKey] ?
        [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey] : 0;
    if (manifestRevision <= 0 || manifestRevision != pendingRevision) {
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Veraltete Watch-Manifest-Bestätigung ignoriert"
                                     metadata:@{
            @"manifestRevision": @(manifestRevision),
            @"pendingRevision": @(pendingRevision),
        }];
        return;
    }
    if (self.manifestAcknowledgementRevisionInProgress == manifestRevision) {
        return;
    }
    self.manifestAcknowledgementRevisionInProgress = manifestRevision;
    dispatch_async(self.manifestBuildQueue, ^{
        NSError* fileError = nil;
        NSArray<NSString*>* episodeHashes = [self _episodeHashesFromManifestFileForRevision:manifestRevision error:&fileError];
        dispatch_async(dispatch_get_main_queue(), ^{
            int64_t currentPendingRevision = [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey];
            if (currentPendingRevision != manifestRevision) {
                if (self.manifestAcknowledgementRevisionInProgress == manifestRevision) {
                    self.manifestAcknowledgementRevisionInProgress = 0;
                }
                return;
            }
            if (!episodeHashes) {
                self.manifestAcknowledgementRevisionInProgress = 0;
                self.needsManifestSyncAfterActivation = YES;
                [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                              message:@"Watch-Manifest-Bestätigung konnte nicht zugeordnet werden"
                                             metadata:@{ @"error": fileError.localizedDescription ?: @"" }];
                [self _postEpisodeStatesChanged];
                [self _refreshSessionStateAndNotify:YES];
                return;
            }

            int64_t receivedRevision = [USER_DEFAULTS integerForKey:ICAppleWatchReceivedManifestAcknowledgementRevisionKey];
            if (manifestRevision > receivedRevision) {
                [USER_DEFAULTS setObject:@(manifestRevision) forKey:ICAppleWatchReceivedManifestAcknowledgementRevisionKey];
            }
            if (episodeHashes.count == 0) {
                [self _finishManifestAcknowledgementForRevision:manifestRevision];
                return;
            }
            [self _applyManifestAcknowledgementBatchForEpisodeHashes:episodeHashes
                                                               offset:0
                                                     manifestRevision:manifestRevision];
        });
    });
}

- (void)_applyManifestAcknowledgementForEpisodeHashes:(NSArray*)episodeHashes
{
    NSMutableOrderedSet<NSString*>* uniqueHashes = [NSMutableOrderedSet orderedSetWithCapacity:episodeHashes.count];
    for (id value in episodeHashes) {
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            [uniqueHashes addObject:value];
        }
    }
    if (uniqueHashes.count == 0) {
        [self _postEpisodeStatesChanged];
        [self _refreshSessionStateAndNotify:YES];
        return;
    }
    [self _applyManifestAcknowledgementBatchForEpisodeHashes:uniqueHashes.array
                                                       offset:0
                                             manifestRevision:0];
}

- (void)_applyManifestAcknowledgementBatchForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
                                                     offset:(NSUInteger)offset
                                           manifestRevision:(int64_t)manifestRevision
{
    if (manifestRevision > 0 && [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey] != manifestRevision) {
        if (self.manifestAcknowledgementRevisionInProgress == manifestRevision) {
            self.manifestAcknowledgementRevisionInProgress = 0;
        }
        return;
    }
    NSRange range = NSMakeRange(offset, MIN(ICAppleWatchStateWriteBatchSize, episodeHashes.count - offset));
    NSArray<NSString*>* batch = [episodeHashes subarrayWithRange:range];
    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    request.predicate = [NSPredicate predicateWithFormat:@"episodeHash IN %@", batch];
    NSError* fetchError = nil;
    NSArray<AppleWatchEpisodeState*>* states = [DMANAGER.objectContext executeFetchRequest:request error:&fetchError];
    if (!states) {
        if (self.manifestAcknowledgementRevisionInProgress == manifestRevision) {
            self.manifestAcknowledgementRevisionInProgress = 0;
        }
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Manifest-Bestätigung konnte nicht verarbeitet werden"
                                     metadata:@{ @"error": fetchError.localizedDescription ?: @"" }];
        [self _postEpisodeStatesChanged];
        [self _refreshSessionStateAndNotify:YES];
        return;
    }

    NSMutableDictionary<NSManagedObjectID*, NSString*>* previousStatuses = [NSMutableDictionary dictionary];
    for (AppleWatchEpisodeState* state in states) {
        BOOL awaitingManifestAck = [state.watchStatus isEqualToString:ICAppleWatchStatusSelected] ||
                                   [state.watchStatus isEqualToString:ICAppleWatchStatusManifestSent];
        if (awaitingManifestAck && !state.removingFromWatch) {
            previousStatuses[state.objectID] = state.watchStatus;
            state.watchStatus = ICAppleWatchStatusQueuedOnWatch;
        }
    }
    NSError* saveError = DMANAGER.objectContext.hasChanges ? [DMANAGER saveReturningError] : nil;
    if (saveError) {
        for (AppleWatchEpisodeState* state in states) {
            NSString* previousStatus = previousStatuses[state.objectID];
            if (previousStatus) {
                state.watchStatus = previousStatus;
            }
        }
        if (self.manifestAcknowledgementRevisionInProgress == manifestRevision) {
            self.manifestAcknowledgementRevisionInProgress = 0;
        }
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Manifest-Bestätigung konnte nicht gespeichert werden"
                                     metadata:@{ @"error": saveError.localizedDescription ?: @"" }];
        [self _postEpisodeStatesChanged];
        [self _refreshSessionStateAndNotify:YES];
        return;
    }

    NSUInteger nextOffset = NSMaxRange(range);
    if (nextOffset < episodeHashes.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _applyManifestAcknowledgementBatchForEpisodeHashes:episodeHashes
                                                               offset:nextOffset
                                                     manifestRevision:manifestRevision];
        });
        return;
    }
    if (manifestRevision > 0) {
        [self _finishManifestAcknowledgementForRevision:manifestRevision];
        return;
    }
    [self _postEpisodeStatesChanged];
    [self _refreshSessionStateAndNotify:YES];
}

- (void)_finishManifestAcknowledgementForRevision:(int64_t)manifestRevision
{
    if ([USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey] != manifestRevision) {
        if (self.manifestAcknowledgementRevisionInProgress == manifestRevision) {
            self.manifestAcknowledgementRevisionInProgress = 0;
        }
        return;
    }
    [USER_DEFAULTS removeObjectForKey:ICAppleWatchPendingManifestRevisionKey];
    self.manifestAcknowledgementRevisionInProgress = 0;
    NSURL* fileURL = [self _manifestFileURLForRevision:manifestRevision];
    dispatch_async(self.manifestBuildQueue, ^{
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
    });
    [self _postEpisodeStatesChanged];
    [self _refreshSessionStateAndNotify:YES];
}

- (BOOL)_shouldApplyWatchEventPayload:(NSDictionary*)payload toState:(AppleWatchEpisodeState*)state
{
    return [self _acceptedWatchEventRevisionForPayload:payload
                                               toState:state
                                   advanceDurableState:YES] > 0;
}

- (int64_t)_acceptedWatchEventRevisionForPayload:(NSDictionary*)payload
                                         toState:(AppleWatchEpisodeState*)state
                             advanceDurableState:(BOOL)advanceDurableState
{
    NSString* selectionIdentifier = [payload[@"selectionIdentifier"] isKindOfClass:[NSString class]] ? payload[@"selectionIdentifier"] : nil;
    if (selectionIdentifier.length > 0 && ![selectionIdentifier isEqualToString:state.uid]) {
        return NO;
    }
    if (self.watchManifestProtocolVersion >= 3 && selectionIdentifier.length == 0) {
        return NO;
    }
    NSNumber* revisionNumber = [payload[@"watchEventRevision"] isKindOfClass:[NSNumber class]] ? payload[@"watchEventRevision"] : nil;
    int64_t eventRevision = revisionNumber.longLongValue;
    NSDate* eventDate = [self _dateFromPayload:payload key:@"timestamp"];

    if (eventRevision <= 0) {
        // Unversioned queued payloads are accepted only until this episode has crossed the
        // versioned protocol boundary. Afterwards they can only be older and must not undo it.
        if (state.watchLastEventRevision > 0 || !eventDate) {
            return NO;
        }
        eventRevision = (int64_t)floor(eventDate.timeIntervalSince1970 * 1000.0);
    }
    NSDictionary* liveProgress = [self _liveDownloadProgressForState:state];
    int64_t transientEventRevision = [liveProgress[@"watchEventRevision"] longLongValue];
    if (eventRevision <= MAX(state.watchLastEventRevision, transientEventRevision)) {
        return NO;
    }

    if (advanceDurableState) {
        state.watchLastEventRevision = eventRevision;
        state.watchLastSeenDate = eventDate ?: [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)eventRevision / 1000.0];
    }
    return eventRevision;
}

- (AppleWatchEpisodeState*)_updateStateForPayload:(NSDictionary*)payload status:(NSString*)status error:(NSString*)error
{
    AppleWatchEpisodeState* state = [self _stateForWatchEventPayload:payload];
    if (!state || ![self _shouldApplyWatchEventPayload:payload toState:state]) {
        return nil;
    }
    state.watchStatus = status;
    state.watchLastError = error;
    return state;
}

- (AppleWatchEpisodeState*)_applyTransientDownloadProgressPayload:(NSDictionary*)payload
{
    AppleWatchEpisodeState* state = [self _stateForWatchEventPayload:payload];
    if (!state) {
        return nil;
    }
    int64_t eventRevision = [self _acceptedWatchEventRevisionForPayload:payload
                                                                toState:state
                                                    advanceDurableState:NO];
    if (eventRevision <= 0) {
        return nil;
    }
    [self _updateCurrentWatchDownloadFromPayload:payload state:state eventRevision:eventRevision];
    if (self.watchDownloadProgressByHash[state.episodeHash ?: @""]) {
        [self _updateCachedWatchTransferContributionForState:state payload:payload];
    }
    return state;
}

- (AppleWatchEpisodeState*)_applyPersistedTransientDownloadProgressPayload:(NSDictionary*)payload
{
    AppleWatchEpisodeState* state = [self _stateForWatchEventPayload:payload];
    if (!state) {
        return nil;
    }
    int64_t eventRevision = [payload[@"watchEventRevision"] longLongValue];
    NSDictionary* liveProgress = [self _liveDownloadProgressForState:state];
    int64_t transientEventRevision = [liveProgress[@"watchEventRevision"] longLongValue];
    if (eventRevision <= 0 ||
        state.watchLastEventRevision > eventRevision ||
        transientEventRevision >= eventRevision) {
        return nil;
    }
    [self _updateCurrentWatchDownloadFromPayload:payload state:state eventRevision:eventRevision];
    if (self.watchDownloadProgressByHash[state.episodeHash ?: @""]) {
        [self _updateCachedWatchTransferContributionForState:state payload:payload];
    }
    return state;
}

- (void)_updateCurrentWatchDownloadFromPayload:(NSDictionary*)payload
                                          state:(AppleWatchEpisodeState*)state
                                  eventRevision:(int64_t)eventRevision
{
    if (!state) {
        return;
    }

    if (![self.currentWatchDownloadHash isEqualToString:state.episodeHash]) {
        CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
        self.currentWatchDownloadHash = state.episodeHash;
        self.currentWatchDownloadTitle = episode.title ?: @"";
    }
    self.currentWatchDownloadedBytes = MAX((int64_t)0, [payload[@"downloadedBytes"] longLongValue]);
    self.currentWatchExpectedBytes = MAX((int64_t)0, [payload[@"expectedBytes"] longLongValue]);
    if (state.episodeHash.length > 0) {
        NSString* selectionIdentifier = [payload[@"selectionIdentifier"] isKindOfClass:[NSString class]] ?
            payload[@"selectionIdentifier"] : @"";
        self.watchDownloadProgressByHash[state.episodeHash] = @{
            @"downloadedBytes": @(self.currentWatchDownloadedBytes),
            @"expectedBytes": @(self.currentWatchExpectedBytes),
            @"watchEventRevision": @(eventRevision),
            @"selectionIdentifier": selectionIdentifier ?: @"",
        };
    }
}

- (void)_clearCurrentWatchDownloadIfMatchesHash:(NSString*)episodeHash
{
    if (![episodeHash isKindOfClass:[NSString class]] || episodeHash.length == 0) {
        return;
    }
    [self.watchDownloadProgressByHash removeObjectForKey:episodeHash];
    if (self.currentWatchDownloadHash.length > 0 && ![self.currentWatchDownloadHash isEqualToString:episodeHash]) {
        return;
    }
    self.currentWatchDownloadHash = nil;
    self.currentWatchDownloadTitle = nil;
    self.currentWatchDownloadedBytes = 0;
    self.currentWatchExpectedBytes = 0;
}

- (void)_mergeWatchPlaybackPayload:(NSDictionary*)payload finished:(BOOL)finished
{
    NSString* episodeHash = [payload[@"episodeHash"] isKindOfClass:[NSString class]] ? payload[@"episodeHash"] : nil;
    if (episodeHash.length == 0) {
        return;
    }

    AppleWatchEpisodeState* state = [self _stateForWatchEventPayload:payload];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:episodeHash];
    if (!state || !episode) {
        return;
    }

    NSDate* timestamp = [self _dateFromPayload:payload key:@"timestamp"] ?: [NSDate date];
    NSDate* newestPhoneDate = state.lastPhonePositionDate ?: [NSDate distantPast];
    if ([timestamp compare:newestPhoneDate] == NSOrderedAscending && !finished) {
        return;
    }

    int32_t position = (int32_t)[payload[@"position"] intValue];
    int32_t duration = MAX(episode.duration, state.watchActualDuration);
    if (duration > 0) {
        position = MIN(position, duration);
    }
    position = MAX(0, position);

    state.lastWatchPosition = position;
    state.lastWatchPositionDate = timestamp;

    if (finished || [payload[@"consumed"] boolValue]) {
        [DMANAGER markEpisode:episode asConsumed:YES];
        state.watchConsumed = YES;
        state.watchConsumedDate = timestamp;
    }
    else {
        [DMANAGER setEpisode:episode position:position];
    }
}

- (void)_postEpisodeStatesChanged
{
    [self _postEpisodeStatesChangedForEpisodeHashes:@[]];
}

- (void)_postEpisodeStatesChangedForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
{
    [self _invalidateWatchTransferSnapshot];
    NSMutableOrderedSet<NSString*>* uniqueHashes = [NSMutableOrderedSet orderedSet];
    for (NSString* episodeHash in episodeHashes) {
        if ([episodeHash isKindOfClass:[NSString class]] && episodeHash.length > 0) {
            [uniqueHashes addObject:episodeHash];
        }
    }
    NSDictionary* userInfo = uniqueHashes.count > 0 ?
        @{ ICAppleWatchChangedEpisodeHashesUserInfoKey: uniqueHashes.array } : nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:ICAppleWatchEpisodeStatesDidChangeNotification
                                                        object:self
                                                      userInfo:userInfo];
}

- (void)_postLiveStatusChangedForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
{
    for (NSString* episodeHash in episodeHashes) {
        if ([episodeHash isKindOfClass:[NSString class]] && episodeHash.length > 0) {
            [self.pendingLiveStatusEpisodeHashes addObject:episodeHash];
        }
    }
    self.pendingGlobalLiveStatusChange |= (episodeHashes.count == 0);
    if (self.liveStatusNotificationScheduled) {
        return;
    }
    self.liveStatusNotificationScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSString*>* changedHashes = self.pendingLiveStatusEpisodeHashes.allObjects;
        BOOL hasGlobalChange = self.pendingGlobalLiveStatusChange;
        [self.pendingLiveStatusEpisodeHashes removeAllObjects];
        self.pendingGlobalLiveStatusChange = NO;
        self.liveStatusNotificationScheduled = NO;
        NSDictionary* userInfo = changedHashes.count > 0 ?
            @{ ICAppleWatchChangedEpisodeHashesUserInfoKey: changedHashes } : nil;
        if (hasGlobalChange || changedHashes.count > 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:ICAppleWatchLiveStatusDidChangeNotification
                                                                object:self
                                                              userInfo:userInfo];
        }
    });
}

- (void)_refreshSessionStateAndNotify:(BOOL)notify
{
    BOOL oldPaired = self.paired;
    BOOL oldInstalled = self.watchAppInstalled;
    BOOL oldReachable = self.reachable;

#if IC_WATCH_CONNECTIVITY_ENABLED
    if ([WCSession isSupported]) {
        WCSession* session = WCSession.defaultSession;
        self.supported = YES;
        self.paired = session.paired;
        self.watchAppInstalled = session.watchAppInstalled;
        self.reachable = session.reachable;
        if (!self.watchAppInstalled) {
            self.watchManifestProtocolVersion = 0;
            self.legacyManifestRevisionAwaitingResult = 0;
        }
    }
    else
#endif
    {
        self.supported = NO;
        self.paired = NO;
        self.watchAppInstalled = NO;
        self.reachable = NO;
    }

    if (notify && (oldPaired != self.paired || oldInstalled != self.watchAppInstalled || oldReachable != self.reachable)) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ICAppleWatchSyncManagerStateDidChangeNotification object:self];
    }
}

- (NSString*)_stringFromDate:(NSDate*)date
{
    static NSISO8601DateFormatter* formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [formatter stringFromDate:date ?: [NSDate date]];
}

- (NSNumber*)_nextManifestRevision
{
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    int64_t previousRevision = [defaults objectForKey:ICAppleWatchManifestRevisionKey] ? [defaults integerForKey:ICAppleWatchManifestRevisionKey] : 0;
    int64_t wallClockRevision = (int64_t)floor([[NSDate date] timeIntervalSince1970] * 1000.0);
    int64_t nextRevision = MAX(wallClockRevision, previousRevision + 1);
    [defaults setObject:@(nextRevision) forKey:ICAppleWatchManifestRevisionKey];
    return @(nextRevision);
}

- (NSDate*)_nextWatchSelectionDateAfterDate:(NSDate*)previousDate
{
    NSDate* now = [NSDate date];
    if (!previousDate) {
        return now;
    }
    NSDate* nextDistinctSecond = [previousDate dateByAddingTimeInterval:1.0];
    return [now compare:nextDistinctSecond] == NSOrderedAscending ? nextDistinctSecond : now;
}

- (NSDate*)_dateFromPayload:(NSDictionary*)payload key:(NSString*)key
{
    id value = payload[key];
    if ([value isKindOfClass:[NSDate class]]) {
        return value;
    }
    if (![value isKindOfClass:[NSString class]]) {
        return nil;
    }

    static NSISO8601DateFormatter* formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [formatter dateFromString:value];
}

#if IC_WATCH_CONNECTIVITY_ENABLED

- (NSURL*)_watchManifestProtocolVersionURLForSession:(WCSession*)session
{
    NSURL* directoryURL = session.watchDirectoryURL;
    return directoryURL ? [directoryURL URLByAppendingPathComponent:ICAppleWatchManifestProtocolVersionFilename
                                                        isDirectory:NO] : nil;
}

- (NSInteger)_storedWatchManifestProtocolVersionForSession:(WCSession*)session
{
    NSURL* fileURL = [self _watchManifestProtocolVersionURLForSession:session];
    if (!fileURL) {
        return 0;
    }
    NSString* value = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:nil];
    return MAX((NSInteger)0, value.integerValue);
}

- (void)_storeWatchManifestProtocolVersion:(NSInteger)version forSession:(WCSession*)session
{
    if (version <= 0 || version <= [self _storedWatchManifestProtocolVersionForSession:session]) {
        return;
    }
    NSURL* fileURL = [self _watchManifestProtocolVersionURLForSession:session];
    if (!fileURL) {
        return;
    }
    NSError* error = nil;
    if (![[NSString stringWithFormat:@"%ld", (long)version] writeToURL:fileURL
                                                               atomically:YES
                                                                 encoding:NSUTF8StringEncoding
                                                                    error:&error]) {
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Protokollversion konnte nicht gespeichert werden"
                                     metadata:@{ @"error": error.localizedDescription ?: @"" }];
    }
}

- (void)session:(WCSession*)session activationDidCompleteWithState:(WCSessionActivationState)activationState error:(NSError*)error
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.watchManifestProtocolVersion = [self _storedWatchManifestProtocolVersionForSession:session];
        [self _scheduleWatchDeletionInboxProcessing];
        [self _refreshSessionStateAndNotify:YES];
        if (activationState == WCSessionActivationStateActivated && session.watchAppInstalled && (self.needsManifestSyncAfterActivation || [self allEpisodeStates].count > 0)) {
            [self syncNow];
        }
    });
}

- (void)sessionDidBecomeInactive:(WCSession*)session
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _refreshSessionStateAndNotify:YES];
    });
}

- (void)sessionDidDeactivate:(WCSession*)session
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.watchManifestProtocolVersion = 0;
        self.legacyManifestRevisionAwaitingResult = 0;
        [session activateSession];
    });
}

- (void)sessionReachabilityDidChange:(WCSession*)session
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _refreshSessionStateAndNotify:YES];
    });
}

- (void)sessionWatchStateDidChange:(WCSession*)session
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.watchManifestProtocolVersion = [self _storedWatchManifestProtocolVersionForSession:session];
        [self _refreshSessionStateAndNotify:YES];
        if (session.watchAppInstalled && self.needsManifestSyncAfterActivation) {
            [self syncNow];
        }
    });
}

- (void)session:(WCSession*)session didReceiveUserInfo:(NSDictionary<NSString*, id>*)userInfo
{
    [self _handleIncomingPayload:userInfo];
}

- (void)session:(WCSession*)session didReceiveMessage:(NSDictionary<NSString*, id>*)message
{
    [self _handleIncomingPayload:message];
}

- (void)session:(WCSession*)session didReceiveApplicationContext:(NSDictionary<NSString*, id>*)applicationContext
{
    [self _handleIncomingPayload:applicationContext];
}

- (void)session:(WCSession*)session didFinishFileTransfer:(WCSessionFileTransfer*)fileTransfer error:(NSError*)error
{
    NSURL* fileURL = fileTransfer.file.fileURL;
    NSNumber* revisionNumber = [fileTransfer.file.metadata[@"manifestRevision"] isKindOfClass:[NSNumber class]] ?
        fileTransfer.file.metadata[@"manifestRevision"] : nil;
    int64_t pendingRevision = [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey];
    if (fileURL && (error || revisionNumber.longLongValue != pendingRevision)) {
        [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
    }
    if (!error) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        int64_t currentPendingRevision = [USER_DEFAULTS integerForKey:ICAppleWatchPendingManifestRevisionKey];
        if (revisionNumber.longLongValue <= 0 || revisionNumber.longLongValue != currentPendingRevision) {
            return;
        }
        [USER_DEFAULTS removeObjectForKey:ICAppleWatchPendingManifestRevisionKey];
        self.needsManifestSyncAfterActivation = YES;
        [[ICDiagnosticLogger shared] logEvent:@"apple-watch"
                                      message:@"Watch-Manifestdatei konnte nicht übertragen werden"
                                     metadata:@{ @"error": error.localizedDescription ?: @"" }];
#if TARGET_OS_IPHONE
        if (App.applicationState == UIApplicationStateActive) {
            [App showBackgroundErrorWithTitle:@"Apple Watch Sync Failed".ls
                                      message:@"Apple Watch data could not be transferred. Keep the iPhone and Apple Watch nearby and try again.".ls
                                     duration:8.0];
        }
#endif
        [self _refreshSessionStateAndNotify:YES];
    });
}

- (void)session:(WCSession*)session didReceiveMessage:(NSDictionary<NSString*, id>*)message replyHandler:(void (^)(NSDictionary<NSString*, id>* replyMessage))replyHandler
{
    [self _handleIncomingPayload:message];
    replyHandler(@{ @"ok": @YES });
}

#endif

@end
