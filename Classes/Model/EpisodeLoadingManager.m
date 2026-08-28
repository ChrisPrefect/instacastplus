//
//  EpisodeLoadingManager.m
//  Instacast
//
//  Created by Claude on 01.02.26.
//

#import "EpisodeLoadingManager.h"
#import "DatabaseManager.h"
#import "CDFeed.h"
#import "CDFeed+Helper.h"
#import "CDEpisode.h"
#import "CDMedium.h"
#import "ICEpisode.h"
#import "ICMedia.h"
#import "InstacastPlus-Swift.h"

// Notifications
NSString* const EpisodeLoadingManagerDidStartLoadingNotification = @"EpisodeLoadingManagerDidStartLoadingNotification";
NSString* const EpisodeLoadingManagerDidLoadBatchNotification = @"EpisodeLoadingManagerDidLoadBatchNotification";
NSString* const EpisodeLoadingManagerDidFinishLoadingNotification = @"EpisodeLoadingManagerDidFinishLoadingNotification";
NSString* const EpisodeLoadingManagerDidFailLoadingNotification = @"EpisodeLoadingManagerDidFailLoadingNotification";
NSString* const EpisodeLoadingManagerDidCancelLoadingNotification = @"EpisodeLoadingManagerDidCancelLoadingNotification";

// FeedProperty keys
NSString* const kFeedPropertyEpisodeLoadingComplete = @"episodeLoadingComplete";
NSString* const kFeedPropertyTotalExpectedEpisodes = @"totalExpectedEpisodes";
NSString* const kFeedPropertyLoadedEpisodeCount = @"loadedEpisodeCount";

// Legacy queue key. New jobs live in independent payload/cursor files; this key is
// read once during migration and then removed.
static NSString* const kUserDefaultsEpisodeLoadingQueueKey = @"EpisodeLoadingQueueKey";

static NSString* const kEpisodeLoadingPayloadSuffix = @".payload.plist";
static NSString* const kEpisodeLoadingCursorSuffix = @".cursor.plist";
static NSString* const kLoadFeedURLKey = @"feedURL";
static NSString* const kLoadEpisodesKey = @"episodes";
static NSString* const kLoadNextIndexKey = @"nextIndex";
static NSString* const kLoadInitialLoadedCountKey = @"initialLoadedCount";
static NSString* const kLoadGenerationKey = @"generation";
static NSString* const kLoadPayloadFilenameKey = @"payloadFilename";
static NSString* const kEpisodeLoadingErrorDomain = @"EpisodeLoadingManagerErrorDomain";

// Adaptive batching: the batch size follows the MEASURED main-thread cost of the
// previous batch, so fast devices process big batches at full speed while slow ones
// automatically fall back to small batches that fit into the target slice. No fixed
// pacing delays — between batches the work hops through the background prep queue,
// which gives the main run loop room to handle pending UI events. (Fixed 50-episode
// batches took 1-2.6s each on an iPad 6 — the app was unusable during hydration.)
static const NSTimeInterval kTargetBatchSeconds = 0.1;
static const NSInteger kMinEpisodeBatchSize = 10;
static const NSInteger kMaxEpisodeBatchSize = 100;
static const NSInteger kInitialAdaptiveBatchSize = 50;

@interface EpisodeLoadingManager ()
@property (nonatomic, strong) NSOperationQueue* loadingQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* pendingLoads;
@property (nonatomic, strong) NSMutableSet<NSString*>* preparingFeedURLs;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* preparingGenerations;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* retryLoads;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* latestGenerations;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSError*>* loadingErrors;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* loadingErrorGenerations;
@property (nonatomic, strong) NSLock* lock;
@property (nonatomic, copy) NSString* activeFeedURL; // currently loading feed (sequential)
@property (nonatomic, copy) NSString* activeGeneration;
@property (nonatomic) NSInteger adaptiveBatchSize;   // guarded by lock
@property (nonatomic, strong) dispatch_queue_t persistenceQueue;
@property (nonatomic) NSUInteger queueGeneration;
@property (nonatomic) BOOL restoreScheduled;
@property (nonatomic) BOOL restoringState;
- (BOOL)_persistNewLoadInfo:(NSDictionary*)loadInfo error:(NSError**)error;
- (BOOL)_persistCursorForLoadInfo:(NSDictionary*)loadInfo error:(NSError**)error;
- (BOOL)_persistedJobMatchesLoadInfo:(NSDictionary*)loadInfo;
- (BOOL)_deletePersistedJobForLoadInfo:(NSDictionary*)loadInfo error:(NSError**)error;
- (void)_deletePersistedJobForFeedURL:(NSString*)feedURL;
- (void)_deletePayloadForLoadInfo:(NSDictionary*)loadInfo;
- (void)_deleteAllPersistedJobs;
- (void)_migrateLegacyLoadingState;
- (void)_restorePersistedJobsForQueueGeneration:(NSUInteger)queueGeneration;
- (BOOL)_isCurrentLoadInfo:(NSDictionary*)loadInfo forFeedURL:(NSString*)feedURL;
- (BOOL)_isCurrentLoadInfoLocked:(NSDictionary*)loadInfo forFeedURL:(NSString*)feedURL;
- (NSDictionary*)_loadInfoForCancellationFailureAtFeedURL:(NSString*)feedURL;
- (void)_releaseActiveLoadInfo:(NSDictionary*)loadInfo forFeedURL:(NSString*)feedURL;
- (void)_handleLoadFailure:(NSError*)error forFeedURL:(NSString*)feedURL loadInfo:(NSDictionary*)loadInfo;
- (CDFeed*)_feedForURL:(NSString*)feedURL context:(NSManagedObjectContext*)context error:(NSError**)error;
- (BOOL)_insertParserEpisodes:(NSArray<ICEpisode*>*)parserEpisodes
                       toFeed:(CDFeed*)feed
                    inContext:(NSManagedObjectContext*)context
                 markConsumed:(BOOL)markConsumed
                        error:(NSError**)error;
@end

@implementation EpisodeLoadingManager

+ (instancetype)sharedManager
{
    static EpisodeLoadingManager* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _loadingQueue = [[NSOperationQueue alloc] init];
        _loadingQueue.maxConcurrentOperationCount = 1;
        _loadingQueue.name = @"com.vemedio.instacast.episodeLoading";
        _loadingQueue.qualityOfService = NSQualityOfServiceBackground; // Niedrige Priorität
        _pendingLoads = [[NSMutableDictionary alloc] init];
        _preparingFeedURLs = [[NSMutableSet alloc] init];
        _preparingGenerations = [[NSMutableDictionary alloc] init];
        _retryLoads = [[NSMutableDictionary alloc] init];
        _latestGenerations = [[NSMutableDictionary alloc] init];
        _loadingErrors = [[NSMutableDictionary alloc] init];
        _loadingErrorGenerations = [[NSMutableDictionary alloc] init];
        _lock = [[NSLock alloc] init];
        _adaptiveBatchSize = kInitialAdaptiveBatchSize;
        _persistenceQueue = dispatch_queue_create("com.vemedio.instacast.episodeLoading.persistence", DISPATCH_QUEUE_SERIAL);
        _queueGeneration = 1;
    }
    return self;
}

#pragma mark - Public Methods

- (void)queuePendingEpisodesForFeed:(CDFeed*)feed
                     parserEpisodes:(NSArray<ICEpisode*>*)episodes
                         startIndex:(NSInteger)startIndex
{
    if (!feed || !feed.sourceURL || startIndex >= episodes.count) {
        return;
    }

    NSString* feedURL = [feed.sourceURL absoluteString];
    NSArray<ICEpisode*>* remainingEpisodes = [episodes subarrayWithRange:NSMakeRange(startIndex, episodes.count - startIndex)];
    NSInteger initialLoadedCount = [feed integerForKey:kFeedPropertyLoadedEpisodeCount];
    NSString* generation = [NSUUID UUID].UUIDString;
    __block NSUInteger queueGeneration = 0;
    [_lock lock];
    queueGeneration = _queueGeneration;
    _preparingGenerations[feedURL] = generation;
    [_preparingFeedURLs addObject:feedURL];
    [_lock unlock];

    // Fulltext/transcript serialization and the one-time payload write can be much
    // larger than the database itself. Keep both off the caller/main thread.
    dispatch_async(self.persistenceQueue, ^{
        @autoreleasepool {
            [self->_lock lock];
            BOOL shouldPrepare = (queueGeneration == self->_queueGeneration &&
                                  [self->_preparingGenerations[feedURL] isEqualToString:generation]);
            [self->_lock unlock];
            if (!shouldPrepare) {
                return;
            }

            NSMutableArray<NSDictionary*>* episodeData = [[NSMutableArray alloc] initWithCapacity:remainingEpisodes.count];
            for (ICEpisode* episode in remainingEpisodes) {
                NSDictionary* serialized = [self _serializeEpisode:episode];
                if (serialized) {
                    [episodeData addObject:serialized];
                }
            }

            NSError* persistenceError = nil;
            if (episodeData.count == 0) {
                persistenceError = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                                       code:1
                                                   userInfo:@{NSLocalizedDescriptionKey: @"No valid episodes could be queued."}];
            }

            NSString* cursorID = [feedURL MD5Hash];
            NSString* payloadFilename = [NSString stringWithFormat:@"%@-%@%@", cursorID, generation, kEpisodeLoadingPayloadSuffix];
            NSDictionary* loadInfo = @{
                kLoadFeedURLKey: feedURL,
                kLoadEpisodesKey: episodeData,
                kLoadNextIndexKey: @0,
                kLoadInitialLoadedCountKey: @(MAX(0, initialLoadedCount)),
                kLoadGenerationKey: generation,
                kLoadPayloadFilenameKey: payloadFilename,
            };

            [self->_lock lock];
            BOOL shouldPersist = (queueGeneration == self->_queueGeneration &&
                                  [self->_preparingGenerations[feedURL] isEqualToString:generation]);
            [self->_lock unlock];
            if (!shouldPersist) {
                return;
            }

            if (!persistenceError) {
                BOOL persisted = [self _persistNewLoadInfo:loadInfo error:&persistenceError];
                if (!persisted && !persistenceError) {
                    persistenceError = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                                           code:3
                                                       userInfo:@{NSLocalizedDescriptionKey: @"The episode-loading job could not be saved."}];
                }
            }

            [self->_lock lock];
            BOOL queueIsCurrent = (queueGeneration == self->_queueGeneration);
            NSString* preparingGeneration = self->_preparingGenerations[feedURL];
            BOOL isLatestPreparation = [preparingGeneration isEqualToString:generation];
            NSDictionary* replacedLoad = nil;
            if (queueIsCurrent && !persistenceError && isLatestPreparation) {
                replacedLoad = self->_pendingLoads[feedURL];
                self->_pendingLoads[feedURL] = loadInfo;
                self->_latestGenerations[feedURL] = generation;
                [self->_retryLoads removeObjectForKey:feedURL];
                if (![self->_loadingErrorGenerations[feedURL] isEqualToString:generation]) {
                    [self->_loadingErrors removeObjectForKey:feedURL];
                    [self->_loadingErrorGenerations removeObjectForKey:feedURL];
                }
            } else if (queueIsCurrent && persistenceError && isLatestPreparation) {
                self->_retryLoads[feedURL] = loadInfo;
            }
            if (isLatestPreparation) {
                [self->_preparingGenerations removeObjectForKey:feedURL];
                [self->_preparingFeedURLs removeObject:feedURL];
            }
            [self->_lock unlock];

            if (!queueIsCurrent || (!isLatestPreparation && !persistenceError)) {
                if (!persistenceError) {
                    [self _deletePersistedJobForLoadInfo:loadInfo error:NULL];
                }
                return;
            }
            if (persistenceError) {
                if (isLatestPreparation) {
                    [self _handleLoadFailure:persistenceError forFeedURL:feedURL loadInfo:loadInfo];
                }
                return;
            }

            if (replacedLoad && ![replacedLoad[kLoadGenerationKey] isEqualToString:generation]) {
                [self _deletePayloadForLoadInfo:replacedLoad];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidStartLoadingNotification
                                                                    object:self
                                                                  userInfo:@{@"feedURL": feedURL}];
            });
            [self _startNextPendingFeed];
        }
    });
}

- (void)cancelLoadingForFeed:(CDFeed*)feed
{
    if (!feed || !feed.sourceURL) {
        return;
    }

    NSString* feedURL = [feed.sourceURL absoluteString];
    if (feed.subscribed && ![feed boolForKey:kFeedPropertyEpisodeLoadingComplete]) {
        NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        request.predicate = [NSPredicate predicateWithFormat:@"feed == %@", feed];
        NSError* countError = nil;
        NSUInteger count = [feed.managedObjectContext countForFetchRequest:request error:&countError];
        if (count == NSNotFound) {
            NSDictionary* loadInfo = [self _loadInfoForCancellationFailureAtFeedURL:feedURL];
            [self _handleLoadFailure:countError forFeedURL:feedURL loadInfo:loadInfo];
            return;
        }

        NSInteger previousLoadedCount = [feed integerForKey:kFeedPropertyLoadedEpisodeCount];
        NSInteger previousTotalExpectedEpisodes = [feed integerForKey:kFeedPropertyTotalExpectedEpisodes];
        BOOL previousLoadingComplete = [feed boolForKey:kFeedPropertyEpisodeLoadingComplete];
        NSInteger loadedCount = (NSInteger)count;
        [feed setInteger:loadedCount forKey:kFeedPropertyLoadedEpisodeCount];
        [feed setInteger:loadedCount forKey:kFeedPropertyTotalExpectedEpisodes];
        [feed setBool:YES forKey:kFeedPropertyEpisodeLoadingComplete];
        NSError* saveError = [DMANAGER saveReturningError];
        if (saveError) {
            [feed setInteger:previousLoadedCount forKey:kFeedPropertyLoadedEpisodeCount];
            [feed setInteger:previousTotalExpectedEpisodes forKey:kFeedPropertyTotalExpectedEpisodes];
            [feed setBool:previousLoadingComplete forKey:kFeedPropertyEpisodeLoadingComplete];
            NSDictionary* loadInfo = [self _loadInfoForCancellationFailureAtFeedURL:feedURL];
            [self _handleLoadFailure:saveError forFeedURL:feedURL loadInfo:loadInfo];
            return;
        }
    }
    [self _cancelLoadingForFeedURL:feedURL];
}

- (NSDictionary*)_loadInfoForCancellationFailureAtFeedURL:(NSString*)feedURL
{
    [_lock lock];
    NSString* preparingGeneration = _preparingGenerations[feedURL];
    NSDictionary* loadInfo = nil;
    if (preparingGeneration.length > 0) {
        loadInfo = @{kLoadGenerationKey: preparingGeneration};
    } else {
        loadInfo = _pendingLoads[feedURL] ?: _retryLoads[feedURL];
    }
    [_lock unlock];
    return loadInfo;
}

- (void)_cancelLoadingForFeedURL:(NSString*)feedURL
{
    NSDictionary* loadInfo = nil;
    NSDictionary* retryLoad = nil;
    BOOL wasActive = NO;
    [_lock lock];
    loadInfo = _pendingLoads[feedURL];
    retryLoad = _retryLoads[feedURL];
    [_pendingLoads removeObjectForKey:feedURL];
    [_preparingFeedURLs removeObject:feedURL];
    [_preparingGenerations removeObjectForKey:feedURL];
    [_retryLoads removeObjectForKey:feedURL];
    [_latestGenerations removeObjectForKey:feedURL];
    [_loadingErrors removeObjectForKey:feedURL];
    [_loadingErrorGenerations removeObjectForKey:feedURL];
    wasActive = [_activeFeedURL isEqualToString:feedURL];
    if (wasActive) {
        _activeFeedURL = nil;
        _activeGeneration = nil;
    }
    [_lock unlock];

    dispatch_async(self.persistenceQueue, ^{
        [self _deletePersistedJobForFeedURL:feedURL];
        [self _deletePayloadForLoadInfo:loadInfo];
        [self _deletePayloadForLoadInfo:retryLoad];
    });

    if (wasActive) {
        [self _startNextPendingFeed];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        CDFeed* feed = [DMANAGER feedWithSourceURL:[NSURL URLWithString:feedURL]];
        NSMutableDictionary* userInfo = [@{@"feedURL": feedURL} mutableCopy];
        if (feed) {
            userInfo[@"feed"] = feed;
            userInfo[@"feedObjectIDURI"] = feed.objectID.URIRepresentation.absoluteString;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidCancelLoadingNotification
                                                            object:self
                                                          userInfo:userInfo];
    });
}

- (void)cancelAllLoading
{
    [_loadingQueue cancelAllOperations];

    [_lock lock];
    NSArray<NSDictionary*>* loads = [_pendingLoads.allValues copy];
    _queueGeneration++;
    [_pendingLoads removeAllObjects];
    [_preparingFeedURLs removeAllObjects];
    [_preparingGenerations removeAllObjects];
    [_retryLoads removeAllObjects];
    [_latestGenerations removeAllObjects];
    [_loadingErrors removeAllObjects];
    [_loadingErrorGenerations removeAllObjects];
    _activeFeedURL = nil;
    _activeGeneration = nil;
    [_lock unlock];

    dispatch_async(self.persistenceQueue, ^{
        for (NSDictionary* loadInfo in loads) {
            [self _deletePersistedJobForLoadInfo:loadInfo error:NULL];
        }
        [self _deleteAllPersistedJobs];
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidCancelLoadingNotification
                                                            object:self];
    });
}

- (void)retryLoadingForFeed:(CDFeed*)feed
{
    NSString* feedURL = feed.sourceURL.absoluteString;
    if (feedURL.length == 0) {
        return;
    }
    [_lock lock];
    NSDictionary* retryLoad = _retryLoads[feedURL];
    NSDictionary* loadInfo = retryLoad ?: _pendingLoads[feedURL];
    BOOL retriesPreparation = (retryLoad != nil);
    NSUInteger queueGeneration = _queueGeneration;
    [_lock unlock];
    if (!loadInfo) {
        return;
    }

    dispatch_async(self.persistenceQueue, ^{
        [self->_lock lock];
        NSDictionary* currentLoad = retriesPreparation ? self->_retryLoads[feedURL] : self->_pendingLoads[feedURL];
        BOOL isCurrent = (queueGeneration == self->_queueGeneration &&
                          [currentLoad[kLoadGenerationKey] isEqualToString:loadInfo[kLoadGenerationKey]]);
        [self->_lock unlock];
        if (!isCurrent) {
            return;
        }

        NSError* persistenceError = nil;
        if (![self _persistedJobMatchesLoadInfo:loadInfo] &&
            ![self _persistNewLoadInfo:loadInfo error:&persistenceError]) {
            if (!persistenceError) {
                persistenceError = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                                       code:3
                                                   userInfo:@{NSLocalizedDescriptionKey: @"The episode-loading job could not be saved."}];
            }
            [self _handleLoadFailure:persistenceError forFeedURL:feedURL loadInfo:loadInfo];
            return;
        }

        NSDictionary* replacedLoad = nil;
        [self->_lock lock];
        currentLoad = retriesPreparation ? self->_retryLoads[feedURL] : self->_pendingLoads[feedURL];
        isCurrent = (queueGeneration == self->_queueGeneration &&
                     [currentLoad[kLoadGenerationKey] isEqualToString:loadInfo[kLoadGenerationKey]]);
        if (isCurrent && retriesPreparation) {
            replacedLoad = self->_pendingLoads[feedURL];
            self->_pendingLoads[feedURL] = loadInfo;
            self->_latestGenerations[feedURL] = loadInfo[kLoadGenerationKey];
            [self->_retryLoads removeObjectForKey:feedURL];
        }
        if (isCurrent) {
            [self->_loadingErrors removeObjectForKey:feedURL];
            [self->_loadingErrorGenerations removeObjectForKey:feedURL];
        }
        [self->_lock unlock];
        if (!isCurrent) {
            return;
        }
        if (replacedLoad && ![replacedLoad[kLoadGenerationKey] isEqualToString:loadInfo[kLoadGenerationKey]]) {
            [self _deletePayloadForLoadInfo:replacedLoad];
        }
        [self _startNextPendingFeed];
    });
}

- (NSError*)loadingErrorForFeed:(CDFeed*)feed
{
    NSString* feedURL = feed.sourceURL.absoluteString;
    if (feedURL.length == 0) {
        return nil;
    }
    [_lock lock];
    NSError* error = _loadingErrors[feedURL];
    [_lock unlock];
    return error;
}

- (BOOL)isLoadingFeed:(CDFeed*)feed
{
    if (!feed || !feed.sourceURL) {
        return NO;
    }

    NSString* feedURL = [feed.sourceURL absoluteString];

    [_lock lock];
    BOOL isLoading = (_pendingLoads[feedURL] != nil ||
                      _retryLoads[feedURL] != nil ||
                      [_preparingFeedURLs containsObject:feedURL]);
    [_lock unlock];

    return isLoading;
}

- (double)loadingProgressForFeed:(CDFeed*)feed
{
    if (!feed) {
        return 1.0;
    }

    NSInteger total = [feed integerForKey:kFeedPropertyTotalExpectedEpisodes];
    if (total == 0) {
        return 1.0;
    }

    NSInteger loaded = [feed integerForKey:kFeedPropertyLoadedEpisodeCount];
    return MIN(1.0, MAX(0.0, (double)loaded / (double)total));
}

- (BOOL)isLoading
{
    [_lock lock];
    BOOL loading = (_pendingLoads.count > 0 ||
                    _retryLoads.count > 0 ||
                    _preparingFeedURLs.count > 0 ||
                    _restoringState);
    [_lock unlock];
    return loading;
}

- (BOOL)suspended
{
    return _loadingQueue.suspended;
}

- (void)setSuspended:(BOOL)suspended
{
    _loadingQueue.suspended = suspended;

    if (!suspended) {
        [self _startNextPendingFeed];
    }
}

- (NSArray<NSString*>*)feedURLsWithPendingEpisodes
{
    [_lock lock];
    NSMutableSet<NSString*>* urls = [[NSMutableSet alloc] initWithArray:_pendingLoads.allKeys];
    [urls addObjectsFromArray:_retryLoads.allKeys];
    [urls unionSet:_preparingFeedURLs];
    [_lock unlock];
    return urls.allObjects;
}

- (void)logStatus
{
    // no-op, retained for API compatibility
}

#pragma mark - Crash Recovery

- (void)restoreLoadingState
{
    [_lock lock];
    if (_restoreScheduled) {
        [_lock unlock];
        return;
    }
    _restoreScheduled = YES;
    _restoringState = YES;
    NSUInteger queueGeneration = _queueGeneration;
    [_lock unlock];

    dispatch_async(self.persistenceQueue, ^{
        [self _migrateLegacyLoadingState];
        [self _restorePersistedJobsForQueueGeneration:queueGeneration];
        [self->_lock lock];
        self->_restoreScheduled = NO;
        self->_restoringState = NO;
        [self->_lock unlock];
        [self _startNextPendingFeed];
    });
}

#pragma mark - Private Loading Methods

- (void)_startNextPendingFeed
{
    if (_loadingQueue.suspended) return; // suspended — will be started on resume

    [_lock lock];
    // Check _activeFeedURL inside the lock to prevent race conditions
    // (queuePendingEpisodesForFeed: can be called from parserQueue background thread)
    if (_activeFeedURL) {
        [_lock unlock];
        return; // already loading a feed
    }
    NSString* nextURL = nil;
    NSDictionary* nextLoad = nil;
    for (NSString* candidateURL in _pendingLoads) {
        NSDictionary* candidateLoad = _pendingLoads[candidateURL];
        if (!_loadingErrors[candidateURL] &&
            [_latestGenerations[candidateURL] isEqualToString:candidateLoad[kLoadGenerationKey]]) {
            nextURL = [candidateURL copy];
            nextLoad = candidateLoad;
            break;
        }
    }
    if (nextLoad) {
        _activeFeedURL = nextURL;
        _activeGeneration = [nextLoad[kLoadGenerationKey] copy];
    }
    [_lock unlock];

    if (nextURL) {
        [self _startLoadingForFeedURL:nextURL];
    }
}

- (void)_startLoadingForFeedURL:(NSString*)feedURL
{
    __weak typeof(self) weakSelf = self;

    [_loadingQueue addOperationWithBlock:^{
        [weakSelf _loadNextBatchForFeedURL:feedURL];
    }];
}

- (void)_loadNextBatchForFeedURL:(NSString*)feedURL
{
    [_lock lock];
    NSDictionary* loadInfo = _pendingLoads[feedURL];
    [_lock unlock];

    if (!loadInfo || ![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
        [self _releaseActiveLoadInfo:loadInfo forFeedURL:feedURL];
        return;
    }

    NSArray<NSDictionary*>* episodes = loadInfo[kLoadEpisodesKey];
    NSInteger nextIndex = [loadInfo[kLoadNextIndexKey] integerValue];
    if (nextIndex >= episodes.count) {
        [self _finishLoadingForFeedURL:feedURL];
        return;
    }

    // Take a batch — sized by the measured duration of the previous one.
    [_lock lock];
    NSInteger batchSize = _adaptiveBatchSize;
    [_lock unlock];
    NSInteger batchEnd = MIN(nextIndex + batchSize, (NSInteger)episodes.count);
    NSArray* batch = [episodes subarrayWithRange:NSMakeRange(nextIndex, batchEnd - nextIndex)];
    NSArray<ICEpisode*>* parserEpisodes = [self _deserializeEpisodes:batch];
    if (parserEpisodes.count != batch.count) {
        NSError* decodeError = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                                   code:2
                                               userInfo:@{NSLocalizedDescriptionKey: @"The saved episode-loading payload is damaged."}];
        [self _handleLoadFailure:decodeError forFeedURL:feedURL loadInfo:loadInfo];
        return;
    }

    if (![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
        [self _releaseActiveLoadInfo:loadInfo forFeedURL:feedURL];
        return;
    }

    CFAbsoluteTime batchStartTime = CFAbsoluteTimeGetCurrent();
    NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
    if (!context) {
        NSError* contextError = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                                    code:5
                                                userInfo:@{NSLocalizedDescriptionKey: @"The local podcast database is unavailable."}];
        [self _handleLoadFailure:contextError forFeedURL:feedURL loadInfo:loadInfo];
        return;
    }
    __block NSError* saveError = nil;
    __block BOOL feedUnavailable = NO;
    __block BOOL staleGeneration = NO;
    __block NSManagedObjectID* feedObjectID = nil;
    __block NSString* feedTitle = @"";
    [context performBlockAndWait:^{
        CDFeed* feed = [self _feedForURL:feedURL context:context error:&saveError];
        if (!feed || saveError || !feed.subscribed) {
            feedUnavailable = (saveError == nil);
            return;
        }
        if (![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
            staleGeneration = YES;
            return;
        }

        if (![self _insertParserEpisodes:parserEpisodes
                                  toFeed:feed
                               inContext:context
                            markConsumed:NO
                                    error:&saveError]) {
            [context rollback];
            return;
        }

        NSInteger initialLoadedCount = [loadInfo[kLoadInitialLoadedCountKey] integerValue];
        NSInteger loadedCount = initialLoadedCount + nextIndex + parserEpisodes.count;
        NSInteger totalExpected = [feed integerForKey:kFeedPropertyTotalExpectedEpisodes];
        if (totalExpected > 0) {
            loadedCount = MIN(loadedCount, totalExpected);
        }
        [feed setInteger:loadedCount forKey:kFeedPropertyLoadedEpisodeCount];

        // Cancellation/replacement can happen while the private context is preparing.
        // Never commit that transaction after its generation has been invalidated.
        if (![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
            staleGeneration = YES;
            [context rollback];
            return;
        }
        if (![context save:&saveError]) {
            [context rollback];
            return;
        }
        feedObjectID = feed.objectID;
        feedTitle = feed.title ?: @"";
    }];

    if (staleGeneration || ![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
        [self _releaseActiveLoadInfo:loadInfo forFeedURL:feedURL];
        return;
    }
    if (feedUnavailable) {
        [self _cancelLoadingForFeedURL:feedURL];
        return;
    }
    if (saveError) {
        [self _handleLoadFailure:saveError forFeedURL:feedURL loadInfo:loadInfo];
        return;
    }

    CFTimeInterval batchSeconds = CFAbsoluteTimeGetCurrent() - batchStartTime;
    NSTimeInterval perEpisode = MAX(batchSeconds / MAX((NSInteger)parserEpisodes.count, 1), 0.0001);
    NSInteger idealSize = (NSInteger)(kTargetBatchSeconds / perEpisode);
    [_lock lock];
    NSInteger smoothed = (_adaptiveBatchSize + idealSize) / 2;
    _adaptiveBatchSize = MAX(kMinEpisodeBatchSize, MIN(kMaxEpisodeBatchSize, smoothed));
    [_lock unlock];

    NSMutableDictionary* updatedInfo = [loadInfo mutableCopy];
    nextIndex = batchEnd;
    updatedInfo[kLoadNextIndexKey] = @(nextIndex);

    __block NSError* cursorError = nil;
    __block BOOL cursorPersisted = NO;
    dispatch_sync(self.persistenceQueue, ^{
        if ([self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
            cursorPersisted = [self _persistCursorForLoadInfo:updatedInfo error:&cursorError];
        }
    });
    if (cursorError) {
        [self _handleLoadFailure:cursorError forFeedURL:feedURL loadInfo:loadInfo];
        return;
    }
    if (!cursorPersisted || ![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
        [self _releaseActiveLoadInfo:loadInfo forFeedURL:feedURL];
        return;
    }

    [_lock lock];
    if ([self _isCurrentLoadInfoLocked:loadInfo forFeedURL:feedURL]) {
        _pendingLoads[feedURL] = [updatedInfo copy];
    }
    [_lock unlock];

    if (batchSeconds > 0.05) {
        [[ICDiagnosticLogger shared] logEvent:@"feed-refresh-profile"
                                      message:@"Episoden-Batch-Insert-Timing"
                                     metadata:@{
            @"feed": feedTitle,
            @"batchSeconds": [NSString stringWithFormat:@"%.3f", batchSeconds],
            @"episodes": @(parserEpisodes.count).stringValue,
            @"nextBatchSize": @(self.adaptiveBatchSize).stringValue,
        }];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSError* mainError = nil;
        CDFeed* mainFeed = (CDFeed*)[DMANAGER.objectContext existingObjectWithID:feedObjectID error:&mainError];
        if (mainFeed && !mainError) {
            [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidLoadBatchNotification
                                                                object:self
                                                              userInfo:@{@"feed": mainFeed, @"count": @(parserEpisodes.count)}];
        }
    });

    if (nextIndex < episodes.count) {
        [self _startLoadingForFeedURL:feedURL];
    } else {
        [self _finishLoadingForFeedURL:feedURL];
    }
}

- (void)_finishLoadingForFeedURL:(NSString*)feedURL
{
    [_lock lock];
    NSDictionary* loadInfo = _pendingLoads[feedURL];
    [_lock unlock];

    if (!loadInfo || ![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
        [self _releaseActiveLoadInfo:loadInfo forFeedURL:feedURL];
        return;
    }

    NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
    if (!context) {
        NSError* contextError = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                                    code:5
                                                userInfo:@{NSLocalizedDescriptionKey: @"The local podcast database is unavailable."}];
        [self _handleLoadFailure:contextError forFeedURL:feedURL loadInfo:loadInfo];
        return;
    }
    __block NSError* saveError = nil;
    __block BOOL feedUnavailable = NO;
    __block BOOL staleGeneration = NO;
    __block NSManagedObjectID* feedObjectID = nil;
    [context performBlockAndWait:^{
        CDFeed* feed = [self _feedForURL:feedURL context:context error:&saveError];
        if (!feed || saveError || !feed.subscribed) {
            feedUnavailable = (saveError == nil);
            return;
        }
        if (![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
            staleGeneration = YES;
            return;
        }

        [feed setBool:YES forKey:kFeedPropertyEpisodeLoadingComplete];
        NSInteger totalExpected = [feed integerForKey:kFeedPropertyTotalExpectedEpisodes];
        if (totalExpected > 0) {
            [feed setInteger:totalExpected forKey:kFeedPropertyLoadedEpisodeCount];
        }
        if (![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
            staleGeneration = YES;
            [context rollback];
            return;
        }
        if (![context save:&saveError]) {
            [context rollback];
            return;
        }
        feedObjectID = feed.objectID;
    }];

    if (staleGeneration || ![self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
        [self _releaseActiveLoadInfo:loadInfo forFeedURL:feedURL];
        return;
    }
    if (feedUnavailable) {
        [self _cancelLoadingForFeedURL:feedURL];
        return;
    }
    if (saveError) {
        [self _handleLoadFailure:saveError forFeedURL:feedURL loadInfo:loadInfo];
        return;
    }

    // The feed-complete save above must win the crash race. Only then may the durable
    // job disappear; at every instant either the job exists or the feed is complete.
    __block NSError* deleteError = nil;
    __block BOOL deleted = NO;
    dispatch_sync(self.persistenceQueue, ^{
        if ([self _isCurrentLoadInfo:loadInfo forFeedURL:feedURL]) {
            deleted = [self _deletePersistedJobForLoadInfo:loadInfo error:&deleteError];
        }
    });
    if (deleteError || !deleted) {
        NSError* error = deleteError ?: [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                                             code:3
                                                         userInfo:@{NSLocalizedDescriptionKey: @"The completed episode-loading job could not be removed."}];
        [self _handleLoadFailure:error forFeedURL:feedURL loadInfo:loadInfo];
        return;
    }

    [_lock lock];
    if ([self _isCurrentLoadInfoLocked:loadInfo forFeedURL:feedURL]) {
        [_pendingLoads removeObjectForKey:feedURL];
        [_latestGenerations removeObjectForKey:feedURL];
        if (!_retryLoads[feedURL]) {
            [_loadingErrors removeObjectForKey:feedURL];
            [_loadingErrorGenerations removeObjectForKey:feedURL];
        }
    }
    if ([_activeFeedURL isEqualToString:feedURL] &&
        [_activeGeneration isEqualToString:loadInfo[kLoadGenerationKey]]) {
        _activeFeedURL = nil;
        _activeGeneration = nil;
    }
    [_lock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSError* mainError = nil;
        CDFeed* feed = (CDFeed*)[DMANAGER.objectContext existingObjectWithID:feedObjectID error:&mainError];
        if (feed && !mainError) {
            [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidFinishLoadingNotification
                                                                object:self
                                                              userInfo:@{
                                                                  @"feed": feed,
                                                                  @"feedObjectIDURI": feed.objectID.URIRepresentation.absoluteString,
                                                              }];
        }
    });

    [self _startNextPendingFeed];
}

#pragma mark - Persistence

- (NSURL*)_loadingStateDirectoryURL
{
    NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]];
    NSString* queuePath = [DatabaseManager pathToSubfolder:@"EpisodeLoading" parent:dataPath];
    if (queuePath.length == 0) {
        return nil;
    }
    NSURL* URL = [NSURL fileURLWithPath:queuePath isDirectory:YES];
    [URL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
    return URL;
}

- (NSURL*)_cursorURLForFeedURL:(NSString*)feedURL
{
    NSString* filename = [[feedURL MD5Hash] stringByAppendingString:kEpisodeLoadingCursorSuffix];
    return [[self _loadingStateDirectoryURL] URLByAppendingPathComponent:filename];
}

- (NSURL*)_payloadURLForFilename:(NSString*)filename
{
    if (filename.length == 0 || ![filename isEqualToString:filename.lastPathComponent]) {
        return nil;
    }
    return [[self _loadingStateDirectoryURL] URLByAppendingPathComponent:filename];
}

- (BOOL)_writePropertyList:(id)propertyList toURL:(NSURL*)URL error:(NSError**)error
{
    if (!propertyList || !URL) {
        if (error) {
            *error = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"The episode-loading file path is invalid."}];
        }
        return NO;
    }

    NSError* serializationError = nil;
    NSData* data = [NSPropertyListSerialization dataWithPropertyList:propertyList
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&serializationError];
    if (!data) {
        if (error) *error = serializationError;
        return NO;
    }
    return [data writeToURL:URL options:NSDataWritingAtomic error:error];
}

- (id)_readPropertyListAtURL:(NSURL*)URL error:(NSError**)error
{
    if (!URL) {
        if (error) {
            *error = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"The episode-loading file path is invalid."}];
        }
        return nil;
    }
    NSData* data = [NSData dataWithContentsOfURL:URL options:0 error:error];
    if (!data) {
        return nil;
    }
    return [NSPropertyListSerialization propertyListWithData:data
                                                     options:NSPropertyListImmutable
                                                      format:NULL
                                                       error:error];
}

- (NSDictionary*)_cursorDictionaryForLoadInfo:(NSDictionary*)loadInfo
{
    return @{
        kLoadFeedURLKey: loadInfo[kLoadFeedURLKey],
        kLoadNextIndexKey: loadInfo[kLoadNextIndexKey],
        kLoadInitialLoadedCountKey: loadInfo[kLoadInitialLoadedCountKey],
        kLoadGenerationKey: loadInfo[kLoadGenerationKey],
        kLoadPayloadFilenameKey: loadInfo[kLoadPayloadFilenameKey],
    };
}

- (BOOL)_persistNewLoadInfo:(NSDictionary*)loadInfo error:(NSError**)error
{
    NSURL* payloadURL = [self _payloadURLForFilename:loadInfo[kLoadPayloadFilenameKey]];
    if (![self _writePropertyList:loadInfo[kLoadEpisodesKey] toURL:payloadURL error:error]) {
        return NO;
    }
    if (![self _persistCursorForLoadInfo:loadInfo error:error]) {
        [[NSFileManager defaultManager] removeItemAtURL:payloadURL error:NULL];
        return NO;
    }
    return YES;
}

- (BOOL)_persistCursorForLoadInfo:(NSDictionary*)loadInfo error:(NSError**)error
{
    NSURL* cursorURL = [self _cursorURLForFeedURL:loadInfo[kLoadFeedURLKey]];
    return [self _writePropertyList:[self _cursorDictionaryForLoadInfo:loadInfo]
                              toURL:cursorURL
                              error:error];
}

- (BOOL)_persistedJobMatchesLoadInfo:(NSDictionary*)loadInfo
{
    NSString* feedURL = loadInfo[kLoadFeedURLKey];
    NSString* generation = loadInfo[kLoadGenerationKey];
    NSString* payloadFilename = loadInfo[kLoadPayloadFilenameKey];
    if (feedURL.length == 0 || generation.length == 0 || payloadFilename.length == 0) {
        return NO;
    }

    NSDictionary* cursor = [self _readPropertyListAtURL:[self _cursorURLForFeedURL:feedURL] error:NULL];
    if (![cursor isKindOfClass:[NSDictionary class]] ||
        ![cursor[kLoadFeedURLKey] isEqualToString:feedURL] ||
        ![cursor[kLoadGenerationKey] isEqualToString:generation] ||
        ![cursor[kLoadPayloadFilenameKey] isEqualToString:payloadFilename]) {
        return NO;
    }

    NSArray* episodes = [self _readPropertyListAtURL:[self _payloadURLForFilename:payloadFilename] error:NULL];
    return [episodes isKindOfClass:[NSArray class]];
}

- (BOOL)_deletePersistedJobForLoadInfo:(NSDictionary*)loadInfo error:(NSError**)error
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSURL* cursorURL = [self _cursorURLForFeedURL:loadInfo[kLoadFeedURLKey]];
    if (!cursorURL) {
        if (error) {
            *error = [NSError errorWithDomain:kEpisodeLoadingErrorDomain
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"The episode-loading file path is invalid."}];
        }
        return NO;
    }
    if ([fileManager fileExistsAtPath:cursorURL.path] && ![fileManager removeItemAtURL:cursorURL error:error]) {
        return NO;
    }

    NSURL* payloadURL = [self _payloadURLForFilename:loadInfo[kLoadPayloadFilenameKey]];
    NSError* payloadError = nil;
    if (payloadURL && [fileManager fileExistsAtPath:payloadURL.path] &&
        ![fileManager removeItemAtURL:payloadURL error:&payloadError]) {
        ErrLog(@"error removing obsolete episode-loading payload: %@", payloadError);
    }
    return YES;
}

- (void)_deletePayloadForLoadInfo:(NSDictionary*)loadInfo
{
    NSURL* payloadURL = [self _payloadURLForFilename:loadInfo[kLoadPayloadFilenameKey]];
    if (payloadURL) {
        [[NSFileManager defaultManager] removeItemAtURL:payloadURL error:NULL];
    }
}

- (void)_deletePersistedJobForFeedURL:(NSString*)feedURL
{
    NSURL* cursorURL = [self _cursorURLForFeedURL:feedURL];
    NSDictionary* cursor = [self _readPropertyListAtURL:cursorURL error:NULL];
    if ([cursor isKindOfClass:[NSDictionary class]]) {
        [self _deletePersistedJobForLoadInfo:cursor error:NULL];
    } else {
        [[NSFileManager defaultManager] removeItemAtURL:cursorURL error:NULL];
    }
}

- (void)_deleteAllPersistedJobs
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSArray<NSURL*>* files = [fileManager contentsOfDirectoryAtURL:[self _loadingStateDirectoryURL]
                                        includingPropertiesForKeys:nil
                                                           options:0
                                                             error:NULL];
    for (NSURL* fileURL in files) {
        if ([fileURL.lastPathComponent hasSuffix:kEpisodeLoadingCursorSuffix] ||
            [fileURL.lastPathComponent hasSuffix:kEpisodeLoadingPayloadSuffix]) {
            [fileManager removeItemAtURL:fileURL error:NULL];
        }
    }
}

- (void)_migrateLegacyLoadingState
{
    NSArray* legacyLoads = [USER_DEFAULTS objectForKey:kUserDefaultsEpisodeLoadingQueueKey];
    if (![legacyLoads isKindOfClass:[NSArray class]]) {
        return;
    }
    if (legacyLoads.count == 0) {
        [USER_DEFAULTS removeObjectForKey:kUserDefaultsEpisodeLoadingQueueKey];
        return;
    }

    BOOL migratedAll = YES;
    for (NSDictionary* legacyLoad in legacyLoads) {
        NSString* feedURL = legacyLoad[kLoadFeedURLKey];
        NSArray* episodes = legacyLoad[kLoadEpisodesKey];
        if (![feedURL isKindOfClass:[NSString class]] ||
            ![episodes isKindOfClass:[NSArray class]] ||
            episodes.count == 0) {
            continue;
        }

        NSURL* existingCursorURL = [self _cursorURLForFeedURL:feedURL];
        if ([[NSFileManager defaultManager] fileExistsAtPath:existingCursorURL.path]) {
            continue;
        }

        __block NSInteger initialLoadedCount = 0;
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        if (context) {
            [context performBlockAndWait:^{
                CDFeed* feed = [self _feedForURL:feedURL context:context error:NULL];
                NSInteger totalExpected = [feed integerForKey:kFeedPropertyTotalExpectedEpisodes];
                initialLoadedCount = MAX(0, totalExpected - (NSInteger)episodes.count);
            }];
        }

        NSString* generation = [NSUUID UUID].UUIDString;
        NSString* payloadFilename = [NSString stringWithFormat:@"%@-%@%@", [feedURL MD5Hash], generation, kEpisodeLoadingPayloadSuffix];
        NSDictionary* loadInfo = @{
            kLoadFeedURLKey: feedURL,
            kLoadEpisodesKey: episodes,
            kLoadNextIndexKey: @0,
            kLoadInitialLoadedCountKey: @(initialLoadedCount),
            kLoadGenerationKey: generation,
            kLoadPayloadFilenameKey: payloadFilename,
        };
        NSError* migrationError = nil;
        if (![self _persistNewLoadInfo:loadInfo error:&migrationError]) {
            migratedAll = NO;
            ErrLog(@"error migrating legacy episode-loading job: %@", migrationError);
        }
    }

    if (migratedAll) {
        [USER_DEFAULTS removeObjectForKey:kUserDefaultsEpisodeLoadingQueueKey];
        [USER_DEFAULTS synchronize];
    }
}

- (void)_restorePersistedJobsForQueueGeneration:(NSUInteger)queueGeneration
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSArray<NSURL*>* files = [fileManager contentsOfDirectoryAtURL:[self _loadingStateDirectoryURL]
                                        includingPropertiesForKeys:nil
                                                           options:0
                                                             error:NULL];
    NSMutableSet<NSString*>* referencedPayloads = [[NSMutableSet alloc] init];
    for (NSURL* cursorURL in files) {
        if (![cursorURL.lastPathComponent hasSuffix:kEpisodeLoadingCursorSuffix]) {
            continue;
        }

        NSError* readError = nil;
        NSDictionary* cursor = [self _readPropertyListAtURL:cursorURL error:&readError];
        NSString* feedURL = [cursor[kLoadFeedURLKey] isKindOfClass:[NSString class]] ? cursor[kLoadFeedURLKey] : nil;
        NSString* generation = [cursor[kLoadGenerationKey] isKindOfClass:[NSString class]] ? cursor[kLoadGenerationKey] : nil;
        NSString* payloadFilename = [cursor[kLoadPayloadFilenameKey] isKindOfClass:[NSString class]] ? cursor[kLoadPayloadFilenameKey] : nil;
        if (payloadFilename) {
            [referencedPayloads addObject:payloadFilename];
        }
        NSNumber* nextIndexValue = [cursor[kLoadNextIndexKey] isKindOfClass:[NSNumber class]] ? cursor[kLoadNextIndexKey] : nil;
        NSNumber* initialCountValue = [cursor[kLoadInitialLoadedCountKey] isKindOfClass:[NSNumber class]] ? cursor[kLoadInitialLoadedCountKey] : nil;
        NSArray* episodes = [self _readPropertyListAtURL:[self _payloadURLForFilename:payloadFilename] error:&readError];

        if (!feedURL || !generation || !payloadFilename || !nextIndexValue || !initialCountValue ||
            ![episodes isKindOfClass:[NSArray class]] ||
            nextIndexValue.integerValue < 0 || nextIndexValue.integerValue > episodes.count) {
            if (payloadFilename) [referencedPayloads removeObject:payloadFilename];
            ErrLog(@"discarding malformed episode-loading job %@: %@", cursorURL.lastPathComponent, readError);
            if (feedURL) {
                [self _deletePersistedJobForFeedURL:feedURL];
            } else {
                [fileManager removeItemAtURL:cursorURL error:NULL];
                NSURL* malformedPayloadURL = [self _payloadURLForFilename:payloadFilename];
                if (malformedPayloadURL) {
                    [fileManager removeItemAtURL:malformedPayloadURL error:NULL];
                }
            }
            continue;
        }

        __block BOOL shouldRestore = NO;
        __block BOOL feedAlreadyComplete = NO;
        __block NSError* feedError = nil;
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        if (!context) {
            ErrLog(@"keeping episode-loading job because the local database is unavailable: %@", feedURL);
            continue;
        }
        [context performBlockAndWait:^{
            CDFeed* feed = [self _feedForURL:feedURL context:context error:&feedError];
            shouldRestore = (feed && feed.subscribed);
            feedAlreadyComplete = shouldRestore && [feed boolForKey:kFeedPropertyEpisodeLoadingComplete];
        }];
        if (feedError) {
            ErrLog(@"keeping episode-loading job because its feed could not be checked: %@", feedError);
            continue;
        }
        if (!shouldRestore || feedAlreadyComplete) {
            [referencedPayloads removeObject:payloadFilename];
            [self _deletePersistedJobForLoadInfo:cursor error:NULL];
            continue;
        }

        NSMutableDictionary* loadInfo = [cursor mutableCopy];
        loadInfo[kLoadEpisodesKey] = episodes;
        [_lock lock];
        if (queueGeneration == _queueGeneration && !_latestGenerations[feedURL]) {
            _latestGenerations[feedURL] = generation;
            _pendingLoads[feedURL] = [loadInfo copy];
        }
        [_lock unlock];
    }

    for (NSURL* fileURL in files) {
        NSString* filename = fileURL.lastPathComponent;
        if ([filename hasSuffix:kEpisodeLoadingPayloadSuffix] && ![referencedPayloads containsObject:filename]) {
            [fileManager removeItemAtURL:fileURL error:NULL];
        }
    }
}

#pragma mark - Job State And Core Data

- (BOOL)_isCurrentLoadInfoLocked:(NSDictionary*)loadInfo forFeedURL:(NSString*)feedURL
{
    NSString* generation = loadInfo[kLoadGenerationKey];
    return (generation.length > 0 &&
            [_latestGenerations[feedURL] isEqualToString:generation] &&
            [_pendingLoads[feedURL][kLoadGenerationKey] isEqualToString:generation]);
}

- (BOOL)_isCurrentLoadInfo:(NSDictionary*)loadInfo forFeedURL:(NSString*)feedURL
{
    if (!loadInfo || feedURL.length == 0) {
        return NO;
    }
    [_lock lock];
    BOOL current = [self _isCurrentLoadInfoLocked:loadInfo forFeedURL:feedURL];
    [_lock unlock];
    return current;
}

- (void)_releaseActiveLoadInfo:(NSDictionary*)loadInfo forFeedURL:(NSString*)feedURL
{
    [_lock lock];
    if ([_activeFeedURL isEqualToString:feedURL] &&
        (!loadInfo || [_activeGeneration isEqualToString:loadInfo[kLoadGenerationKey]])) {
        _activeFeedURL = nil;
        _activeGeneration = nil;
    }
    [_lock unlock];
    [self _startNextPendingFeed];
}

- (void)_handleLoadFailure:(NSError*)error forFeedURL:(NSString*)feedURL loadInfo:(NSDictionary*)loadInfo
{
    if (!error || feedURL.length == 0) {
        return;
    }

    [_lock lock];
    NSString* generation = loadInfo[kLoadGenerationKey];
    if (generation.length == 0) {
        generation = _preparingGenerations[feedURL] ?: _pendingLoads[feedURL][kLoadGenerationKey] ?: _retryLoads[feedURL][kLoadGenerationKey];
    }
    BOOL belongsToLatestGeneration = (generation.length == 0 ||
                                      [_preparingGenerations[feedURL] isEqualToString:generation] ||
                                      [_latestGenerations[feedURL] isEqualToString:generation] ||
                                      [_retryLoads[feedURL][kLoadGenerationKey] isEqualToString:generation]);
    if (belongsToLatestGeneration) {
        _loadingErrors[feedURL] = error;
        if (generation.length > 0) {
            _loadingErrorGenerations[feedURL] = generation;
        } else {
            [_loadingErrorGenerations removeObjectForKey:feedURL];
        }
        if ([_activeFeedURL isEqualToString:feedURL] &&
            (generation.length == 0 || [_activeGeneration isEqualToString:generation])) {
            _activeFeedURL = nil;
            _activeGeneration = nil;
        }
    }
    [_lock unlock];

    if (!belongsToLatestGeneration) {
        return;
    }

    [[ICDiagnosticLogger shared] logEvent:@"episode-loading-error"
                                  message:@"Episoden konnten nicht nachgeladen werden"
                                 metadata:@{
        @"feedURL": feedURL,
        @"error": error.localizedDescription ?: @"",
    }];
    dispatch_async(dispatch_get_main_queue(), ^{
        CDFeed* feed = [DMANAGER feedWithSourceURL:[NSURL URLWithString:feedURL]];
        NSMutableDictionary* userInfo = [@{@"feedURL": feedURL, @"error": error} mutableCopy];
        if (feed) {
            userInfo[@"feed"] = feed;
            userInfo[@"feedObjectIDURI"] = feed.objectID.URIRepresentation.absoluteString;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidFailLoadingNotification
                                                            object:self
                                                          userInfo:userInfo];
    });
    [self _startNextPendingFeed];
}

- (CDFeed*)_feedForURL:(NSString*)feedURL context:(NSManagedObjectContext*)context error:(NSError**)error
{
    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
    request.fetchLimit = 1;
    request.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", feedURL];
    return [[context executeFetchRequest:request error:error] firstObject];
}

- (BOOL)_insertParserEpisodes:(NSArray<ICEpisode*>*)parserEpisodes
                       toFeed:(CDFeed*)feed
                    inContext:(NSManagedObjectContext*)context
                 markConsumed:(BOOL)markConsumed
                         error:(NSError**)error
{
    NSMutableArray<NSString*>* hashes = [[NSMutableArray alloc] initWithCapacity:parserEpisodes.count];
    for (ICEpisode* episode in parserEpisodes) {
        if (episode.objectHash.length > 0) {
            [hashes addObject:episode.objectHash];
        }
    }

    NSMutableDictionary<NSString*, CDEpisode*>* existingByHash = [[NSMutableDictionary alloc] initWithCapacity:hashes.count];
    if (hashes.count > 0) {
        NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        request.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", hashes];
        NSArray<CDEpisode*>* existingEpisodes = [context executeFetchRequest:request error:error];
        if (!existingEpisodes) {
            return NO;
        }
        for (CDEpisode* episode in existingEpisodes) {
            if (episode.objectHash.length > 0) {
                existingByHash[episode.objectHash] = episode;
            }
        }
    }

    for (ICEpisode* parserEpisode in parserEpisodes) {
        CDEpisode* episode = existingByHash[parserEpisode.objectHash];
        BOOL wasNew = (episode == nil);
        if (!episode) {
            episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
            existingByHash[parserEpisode.objectHash] = episode;
        }
        [DMANAGER _copyEpisodeValuesFrom:parserEpisode to:episode];

        for (CDMedium* oldMedium in [episode.media copy]) {
            [context deleteObject:oldMedium];
        }
        NSMutableSet<CDMedium*>* media = [[NSMutableSet alloc] init];
        for (ICMedia* parserMedium in parserEpisode.media) {
            if (!parserMedium.fileURL) continue;
            CDMedium* medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
            [DMANAGER _copyMediumValuesFrom:parserMedium to:medium];
            [media addObject:medium];
        }
        episode.media = media;
        episode.feed = feed;
        if (wasNew) {
            episode.consumed = markConsumed;
        }
    }
    return YES;
}

#pragma mark - Episode Serialization

- (NSDictionary*)_serializeEpisode:(ICEpisode*)episode
{
    if (!episode) {
        return nil;
    }

    NSMutableDictionary* dict = [[NSMutableDictionary alloc] init];

    // Required fields
    if (episode.objectHash) {
        dict[@"objectHash"] = episode.objectHash;
    } else {
        return nil; // objectHash is required for deduplication
    }

    // String properties
    if (episode.guid) dict[@"guid"] = episode.guid;
    if (episode.title) dict[@"title"] = episode.title;
    if (episode.subtitle) dict[@"subtitle"] = episode.subtitle;
    if (episode.author) dict[@"author"] = episode.author;
    if (episode.summary) dict[@"summary"] = episode.summary;
    if (episode.textDescription) dict[@"textDescription"] = episode.textDescription;
    if (episode.transcripts.count > 0) dict[@"transcripts"] = episode.transcripts;

    // Date
    if (episode.pubDate) {
        dict[@"pubDate"] = @([episode.pubDate timeIntervalSince1970]);
    }

    // Numbers
    dict[@"duration"] = @(episode.duration);
    dict[@"video"] = @(episode.video);
    dict[@"explicitContent"] = @(episode.explicitContent);

    // URLs
    if (episode.imageURL) dict[@"imageURL"] = [episode.imageURL absoluteString];
    if (episode.link) dict[@"linkURL"] = [episode.link absoluteString];
    if (episode.paymentURL) dict[@"paymentURL"] = [episode.paymentURL absoluteString];
    if (episode.deeplink) dict[@"deeplinkURL"] = [episode.deeplink absoluteString];

    // Media
    NSMutableArray* mediaArray = [[NSMutableArray alloc] init];
    for (ICMedia* media in episode.media) {
        if (media.fileURL) {
            NSDictionary* mediaDict = @{
                @"fileURL": [media.fileURL absoluteString],
                @"mimeType": media.mimeType ?: @"",
                @"byteSize": @(media.byteSize)
            };
            [mediaArray addObject:mediaDict];
        }
    }
    dict[@"media"] = mediaArray;

    // Note: chapters are not serialized - they are typically parsed from the media file

    return dict;
}

- (NSArray<ICEpisode*>*)_deserializeEpisodes:(NSArray<NSDictionary*>*)episodeData
{
    NSMutableArray* episodes = [[NSMutableArray alloc] initWithCapacity:episodeData.count];

    for (NSDictionary* dict in episodeData) {
        ICEpisode* episode = [self _deserializeEpisode:dict];
        if (episode) {
            [episodes addObject:episode];
        }
    }

    return episodes;
}

- (ICEpisode*)_deserializeEpisode:(NSDictionary*)dict
{
    if (!dict || !dict[@"objectHash"]) {
        return nil;
    }

    ICEpisode* episode = [ICEpisode episode];

    // Required
    episode.objectHash = dict[@"objectHash"];

    // Strings
    episode.guid = dict[@"guid"];
    episode.title = dict[@"title"];
    episode.subtitle = dict[@"subtitle"];
    episode.author = dict[@"author"];
    episode.summary = dict[@"summary"];
    episode.textDescription = dict[@"textDescription"];
    if ([dict[@"transcripts"] isKindOfClass:[NSArray class]]) {
        episode.transcripts = dict[@"transcripts"];
    }

    // Date
    if (dict[@"pubDate"]) {
        episode.pubDate = [NSDate dateWithTimeIntervalSince1970:[dict[@"pubDate"] doubleValue]];
    }

    // Numbers
    episode.duration = [dict[@"duration"] integerValue];
    episode.video = [dict[@"video"] boolValue];
    episode.explicitContent = [dict[@"explicitContent"] boolValue];

    // URLs
    if (dict[@"imageURL"]) episode.imageURL = [NSURL URLWithString:dict[@"imageURL"]];
    if (dict[@"linkURL"]) episode.link = [NSURL URLWithString:dict[@"linkURL"]];
    if (dict[@"paymentURL"]) episode.paymentURL = [NSURL URLWithString:dict[@"paymentURL"]];
    if (dict[@"deeplinkURL"]) episode.deeplink = [NSURL URLWithString:dict[@"deeplinkURL"]];

    // Media
    NSMutableArray* media = [[NSMutableArray alloc] init];
    for (NSDictionary* mediaDict in dict[@"media"]) {
        ICMedia* m = [ICMedia media];
        m.fileURL = [NSURL URLWithString:mediaDict[@"fileURL"]];
        m.mimeType = mediaDict[@"mimeType"];
        m.byteSize = [mediaDict[@"byteSize"] unsignedLongLongValue];

        if (m.fileURL) {
            [media addObject:m];
        }
    }
    episode.media = media;

    return episode;
}

@end
