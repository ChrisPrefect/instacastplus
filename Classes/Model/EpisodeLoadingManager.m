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
#import "ICEpisode.h"
#import "ICMedia.h"

// Notifications
NSString* const EpisodeLoadingManagerDidStartLoadingNotification = @"EpisodeLoadingManagerDidStartLoadingNotification";
NSString* const EpisodeLoadingManagerDidLoadBatchNotification = @"EpisodeLoadingManagerDidLoadBatchNotification";
NSString* const EpisodeLoadingManagerDidFinishLoadingNotification = @"EpisodeLoadingManagerDidFinishLoadingNotification";

// FeedProperty keys
NSString* const kFeedPropertyEpisodeLoadingComplete = @"episodeLoadingComplete";
NSString* const kFeedPropertyTotalExpectedEpisodes = @"totalExpectedEpisodes";
NSString* const kFeedPropertyLoadedEpisodeCount = @"loadedEpisodeCount";

// NSUserDefaults key for persistence
static NSString* const kUserDefaultsEpisodeLoadingQueueKey = @"EpisodeLoadingQueueKey";

// Batch size for background loading
static const NSInteger kEpisodeBatchSize = 50;

// Delay between main-queue batches to keep UI responsive
static const NSTimeInterval kBatchDelay = 0.25;

@interface EpisodeLoadingManager ()
@property (nonatomic, strong) NSOperationQueue* loadingQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSDictionary*>* pendingLoads;
@property (nonatomic, strong) NSLock* lock;
@property (nonatomic, copy) NSString* activeFeedURL; // currently loading feed (sequential)
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
        _lock = [[NSLock alloc] init];
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

    // Serialize remaining episodes
    NSMutableArray* episodeData = [[NSMutableArray alloc] init];
    for (NSInteger i = startIndex; i < episodes.count; i++) {
        NSDictionary* serialized = [self _serializeEpisode:episodes[i]];
        if (serialized) {
            [episodeData addObject:serialized];
        }
    }

    if (episodeData.count == 0) {
        return;
    }

    NSDictionary* loadInfo = @{
        @"feedURL": feedURL,
        @"episodes": episodeData
    };

    [_lock lock];
    _pendingLoads[feedURL] = loadInfo;
    [_lock unlock];

    // Don't save loading state here — it would write megabytes of episode data to NSUserDefaults.
    // State is saved when feeds finish or are cancelled, which is sufficient for crash recovery.
    // If the app crashes mid-load, at most one batch of episodes will be re-processed (deduplication handles it).

    DebugLog(@"EpisodeLoadingManager: Queued %lu episodes for feed %@", (unsigned long)episodeData.count, feed.title);

    [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidStartLoadingNotification
                                                        object:self
                                                      userInfo:@{@"feedURL": feedURL}];

    [self _startNextPendingFeed];
}

- (void)cancelLoadingForFeed:(CDFeed*)feed
{
    if (!feed || !feed.sourceURL) {
        return;
    }

    NSString* feedURL = [feed.sourceURL absoluteString];
    [self _cancelLoadingForFeedURL:feedURL];
}

- (void)_cancelLoadingForFeedURL:(NSString*)feedURL
{
    BOOL wasActive;
    [_lock lock];
    [_pendingLoads removeObjectForKey:feedURL];
    wasActive = [_activeFeedURL isEqualToString:feedURL];
    if (wasActive) {
        _activeFeedURL = nil;
    }
    [_lock unlock];

    [self _saveLoadingState];

    DebugLog(@"EpisodeLoadingManager: Cancelled loading for %@", feedURL);

    if (wasActive) {
        [self _startNextPendingFeed];
    }
}

- (void)cancelAllLoading
{
    [_loadingQueue cancelAllOperations];

    [_lock lock];
    NSArray* feedURLs = [_pendingLoads allKeys];
    [_pendingLoads removeAllObjects];
    _activeFeedURL = nil;
    [_lock unlock];

    [self _saveLoadingState];

    DebugLog(@"EpisodeLoadingManager: Cancelled all loading (%lu feeds)", (unsigned long)feedURLs.count);
}

- (BOOL)isLoadingFeed:(CDFeed*)feed
{
    if (!feed || !feed.sourceURL) {
        return NO;
    }

    NSString* feedURL = [feed.sourceURL absoluteString];

    [_lock lock];
    BOOL isLoading = (_pendingLoads[feedURL] != nil);
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
    return (double)loaded / (double)total;
}

- (BOOL)isLoading
{
    [_lock lock];
    BOOL loading = (_pendingLoads.count > 0);
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
    DebugLog(@"EpisodeLoadingManager: %@", suspended ? @"suspended" : @"resumed");

    if (!suspended) {
        [self _startNextPendingFeed];
    }
}

- (NSArray<NSString*>*)feedURLsWithPendingEpisodes
{
    [_lock lock];
    NSArray* urls = [_pendingLoads allKeys];
    [_lock unlock];
    return urls;
}

- (void)logStatus
{
    // Status-Logging nur im Debug
#ifdef DEBUG
    [_lock lock];
    NSUInteger feedCount = _pendingLoads.count;
    [_lock unlock];

    if (feedCount > 0) {
        DebugLog(@"EpisodeLoadingManager: %lu feeds pending", (unsigned long)feedCount);
    }
#endif
}

#pragma mark - Crash Recovery

- (void)restoreLoadingState
{
    NSArray* savedInfo = [USER_DEFAULTS objectForKey:kUserDefaultsEpisodeLoadingQueueKey];
    if (!savedInfo || savedInfo.count == 0) {
        return;
    }

    DebugLog(@"EpisodeLoadingManager: Restoring %lu pending loads", (unsigned long)savedInfo.count);

    for (NSDictionary* loadInfo in savedInfo) {
        NSString* feedURL = loadInfo[@"feedURL"];
        NSArray* episodes = loadInfo[@"episodes"];

        if (!feedURL || !episodes || episodes.count == 0) {
            continue;
        }

        // Verify feed still exists before restoring
        CDFeed* feed = [DMANAGER feedWithSourceURL:[NSURL URLWithString:feedURL]];
        if (feed && feed.subscribed) {
            [_lock lock];
            _pendingLoads[feedURL] = loadInfo;
            [_lock unlock];
            DebugLog(@"EpisodeLoadingManager: Restored pending load for %@ (%lu episodes remaining)", feed.title, (unsigned long)episodes.count);
        } else {
            DebugLog(@"EpisodeLoadingManager: Skipping restored feed (deleted/unsubscribed): %@", feedURL);
        }
    }

    // Start loading one feed at a time
    [self _startNextPendingFeed];
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
    NSString* nextURL = [_pendingLoads.allKeys.firstObject copy];
    if (nextURL) {
        _activeFeedURL = nextURL;
    }
    [_lock unlock];

    if (nextURL) {
        DebugLog(@"EpisodeLoadingManager: Starting sequential load for %@", nextURL);
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

    if (!loadInfo) {
        return;
    }

    NSMutableArray* episodes = [loadInfo[@"episodes"] mutableCopy];

    if (episodes.count == 0) {
        [self _finishLoadingForFeedURL:feedURL];
        return;
    }

    // Take a batch
    NSInteger batchEnd = MIN(kEpisodeBatchSize, episodes.count);
    NSArray* batch = [episodes subarrayWithRange:NSMakeRange(0, batchEnd)];
    [episodes removeObjectsInRange:NSMakeRange(0, batchEnd)];
    NSArray<ICEpisode*>* parserEpisodes = [self _deserializeEpisodes:batch];

    // Update pending loads with remaining episodes
    NSDictionary* updatedInfo = @{
        @"feedURL": feedURL,
        @"episodes": episodes
    };

    [_lock lock];
    _pendingLoads[feedURL] = updatedInfo;
    [_lock unlock];

    // Insert episodes on main thread (Core Data requirement)
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            CDFeed* feed = [DMANAGER feedWithSourceURL:[NSURL URLWithString:feedURL]];

            if (!feed || !feed.subscribed) {
                // Feed was deleted or unsubscribed
                [self _cancelLoadingForFeedURL:feedURL];
                return;
            }

            if (parserEpisodes.count > 0) {
                [DMANAGER addParserEpisodes:parserEpisodes toFeed:feed markConsumed:YES];

                // Update progress in feed properties
                NSInteger loaded = [feed integerForKey:kFeedPropertyLoadedEpisodeCount];
                [feed setInteger:loaded + parserEpisodes.count forKey:kFeedPropertyLoadedEpisodeCount];
                [DMANAGER save];
            }

            DebugLog(@"EpisodeLoadingManager: Loaded batch of %lu episodes for %@, %lu remaining",
                     (unsigned long)parserEpisodes.count, feed.title, (unsigned long)episodes.count);

            // Notify observers
            [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidLoadBatchNotification
                                                                object:self
                                                              userInfo:@{@"feed": feed, @"count": @(parserEpisodes.count)}];

            // Continue or finish — delay next batch to keep UI responsive
            if (episodes.count > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBatchDelay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self _startLoadingForFeedURL:feedURL];
                });
            } else {
                [self _finishLoadingForFeedURL:feedURL];
            }
        }
    });
}

- (void)_finishLoadingForFeedURL:(NSString*)feedURL
{
    [_lock lock];
    [_pendingLoads removeObjectForKey:feedURL];
    if ([_activeFeedURL isEqualToString:feedURL]) {
        _activeFeedURL = nil;
    }
    [_lock unlock];

    [self _saveLoadingState];

    dispatch_async(dispatch_get_main_queue(), ^{
        CDFeed* feed = [DMANAGER feedWithSourceURL:[NSURL URLWithString:feedURL]];

        if (feed) {
            [feed setBool:YES forKey:kFeedPropertyEpisodeLoadingComplete];
            [DMANAGER save];

            DebugLog(@"EpisodeLoadingManager: Finished loading all episodes for %@", feed.title);

            [[NSNotificationCenter defaultCenter] postNotificationName:EpisodeLoadingManagerDidFinishLoadingNotification
                                                                object:self
                                                              userInfo:@{@"feed": feed}];
        }

        // Start next pending feed (sequential loading)
        [self _startNextPendingFeed];
    });
}

#pragma mark - Persistence

- (void)_saveLoadingState
{
    [_lock lock];
    NSArray* allLoads = [_pendingLoads allValues];
    [_lock unlock];

    [USER_DEFAULTS setObject:allLoads forKey:kUserDefaultsEpisodeLoadingQueueKey];
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
