//
//  SubscriptionManager.m
//  Instacast
//
//  Created by Martin Hering on 30.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//


#import <UserNotifications/UserNotifications.h>
#import "ICFeedParser.h"
#import "ICPagedFeedParser.h"

#import "OPML.h"
#import "CDModel.h"
#import "CDFeed+Helper.h"
#import "CDEpisode+ShowNotes.h"
#import "EpisodeLoadingManager.h"
#import "ICMedia.h"
#import "InstacastPlus-Swift.h"

NSString* SubscriptionManagerWillStartRefreshingFeedsNotification = @"SubscriptionManagerWillStartRefreshingFeedsNotification";
NSString* SubscriptionManagerDidStartRefreshingFeedsNotification = @"SubscriptionManagerDidStartRefreshingFeedsNotification";
NSString* SubscriptionManagerDidFinishRefreshingFeedsNotification = @"SubscriptionManagerDidFinishRefreshingFeedsNotification";

NSString* SubscriptionManagerWillParseFeedNotification = @"SubscriptionManagerWillParseFeedNotification";
NSString* SubscriptionManagerDidParseFeedNotification = @"SubscriptionManagerDidParseFeedNotification";
NSString* SubscriptionManagerDidAddEpisodesNotification = @"SubscriptionManagerDidAddEpisodesNotification";
NSString* SubscriptionManagerUnsubscribeCleanupProtectionDidChangeNotification = @"SubscriptionManagerUnsubscribeCleanupProtectionDidChangeNotification";

static SubscriptionManager* gSharedSubscriptionManager = nil;

@interface ICUnsubscribeCleanupProtectionStage : NSObject
@property (nonatomic, copy) NSString* revision;
@property (nonatomic) NSUInteger sequence;
@end

@implementation ICUnsubscribeCleanupProtectionStage
@end

@interface ICUnsubscribeCleanupProtectionState : NSObject
@property (nonatomic, copy) NSString* committedRevision;
@property (nonatomic) NSUInteger committedSequence;
@property (nonatomic, strong) NSMutableDictionary<NSString*, ICUnsubscribeCleanupProtectionStage*>* stagesByToken;
@end

@implementation ICUnsubscribeCleanupProtectionState

- (instancetype)init
{
    if ((self = [super init])) {
        _stagesByToken = [[NSMutableDictionary alloc] init];
    }
    return self;
}

@end

@interface SubscriptionManager ()
@property (nonatomic, readwrite, strong) NSMutableArray* refreshingFeedURLs;
@property (nonatomic, readwrite, strong) NSMutableArray* refreshedFeeds;
@property (nonatomic, readwrite, weak) NSTimer* refreshCheckTimer;
@property (nonatomic, readwrite, strong) NSURL* refreshedURL;
@property (nonatomic, readwrite, copy) NSString* lastRefreshFailedFeedName;
@property (nonatomic, strong) NSMutableDictionary<NSURL*, NSDate*>* refreshFeedStartDates;
@property (nonatomic, strong) NSMutableDictionary<NSURL*, NSString*>* refreshFeedTitlesByURL;
@property (nonatomic, strong) NSMutableOrderedSet<NSString*>* refreshFailedFeedTitles;
@property (nonatomic, strong) NSMutableOrderedSet<NSString*>* refreshTimedOutFeedTitles;
@property (nonatomic, strong) NSMutableOrderedSet<NSString*>* refreshFailureMessages;
@property (nonatomic, copy) NSString* finalRefreshStatusText;

@property (nonatomic) NSInteger numOfNewEpisodesAfterRefresh;
@property (nonatomic) NSInteger numTotalRefreshFeeds;
//@property (nonatomic, copy) void (^refreshCompletionHandler)(BOOL success, BOOL newData);
@property BOOL importing;
@property (nonatomic, strong) NSOperationQueue* parserQueue;
@property (nonatomic, strong) NSOperationQueue* mergeQueue;
@property (nonatomic, strong) NSDate* refreshStartDate;
@property (nonatomic, strong) NSMutableSet<NSURL*>* feedsMergingURLs;
@property (nonatomic, strong) NSMutableSet<NSManagedObjectID*>* pendingAutoDownloadFeedObjectIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString*, ICUnsubscribeCleanupProtectionState*>* unsubscribeCleanupProtectionStatesByFeedObjectURIString;
@property (nonatomic) NSUInteger unsubscribeCleanupProtectionSequence;
@property (nonatomic, strong) NSLock* unsubscribeCleanupProtectionLock;
@property (nonatomic) BOOL unsubscribeCleanupRecoveryBlocked;
@property (nonatomic, strong) dispatch_queue_t autoDownloadFeedScanQueue;
@property (nonatomic) BOOL autoDownloadFeedScanInFlight;

- (void)_retainPendingAutoDownloadFeedUIDs:(NSArray<NSString*>*)feedUIDs;
- (void)_retainPendingAutoDownloadFeedObjectIDs:(NSArray<NSManagedObjectID*>*)feedObjectIDs;
- (void)_removePendingAutoDownloadFeedUIDs:(NSArray<NSString*>*)feedUIDs;
- (BOOL)_autoDownloadsBlockedDuringUnsubscribeCleanupForFeedObjectID:(NSManagedObjectID*)feedObjectID;
- (void)_resumeAfterUnsubscribeCleanupProtectionChange;

#if TARGET_OS_IPHONE
@property (nonatomic) UIBackgroundTaskIdentifier backgroundIdentifier;
#else
@property (nonatomic, strong) NSTimer* checkTimer;
#endif

@end



@implementation SubscriptionManager {
    struct {
        unsigned int refreshFailed;
    } _flags;
}

static const NSTimeInterval kPerFeedRefreshTimeout = 8.0;
static const NSUInteger ICAutoDownloadFeedScanBatchSize = 20;
static const NSUInteger ICAutoDownloadCandidateDeliveryBatchSize = 32;
static NSString* const ICAutoDownloadCandidateEpisodeObjectIDKey = @"episodeObjectID";
static NSString* const ICAutoDownloadCandidateFeedObjectIDKey = @"feedObjectID";
static NSString* const ICPendingAutoDownloadFeedUIDsKey = @"ICPendingAutoDownloadFeedUIDs";

static NSArray<NSDictionary*>* ICAutoDownloadCandidatesForFeedObjectIDs(NSManagedObjectContext* context,
                                                                         NSArray<NSManagedObjectID*>* feedObjectIDs,
                                                                         NSError** error)
{
    NSMutableDictionary<NSString*, NSManagedObjectID*>* feedObjectIDsByUID = [[NSMutableDictionary alloc] init];
    for (NSManagedObjectID* feedObjectID in feedObjectIDs) {
        NSError* feedError = nil;
        CDFeed* feed = (CDFeed*)[context existingObjectWithID:feedObjectID error:&feedError];
        if (![feed isKindOfClass:[CDFeed class]] || feedError || feed.isDeleted ||
            !feed.subscribed || feed.parked || feed.uid.length == 0) {
            continue;
        }
        feedObjectIDsByUID[feed.uid] = feedObjectID;
    }
    if (feedObjectIDsByUID.count == 0) {
        return @[];
    }

    NSExpressionDescription* feedUIDExpression = [[NSExpressionDescription alloc] init];
    feedUIDExpression.name = @"feedUID";
    feedUIDExpression.expression = [NSExpression expressionForKeyPath:@"feed.uid"];
    feedUIDExpression.expressionResultType = NSStringAttributeType;

    NSExpressionDescription* latestPubDateExpression = [[NSExpressionDescription alloc] init];
    latestPubDateExpression.name = @"latestPubDate";
    latestPubDateExpression.expression = [NSExpression expressionForFunction:@"max:"
                                                                    arguments:@[[NSExpression expressionForKeyPath:@"pubDate"]]];
    latestPubDateExpression.expressionResultType = NSDateAttributeType;

    NSFetchRequest* latestDatesRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    latestDatesRequest.predicate = [NSPredicate predicateWithFormat:@"pubDate != nil AND feed.uid IN %@",
                                    feedObjectIDsByUID.allKeys];
    latestDatesRequest.resultType = NSDictionaryResultType;
    latestDatesRequest.propertiesToFetch = @[feedUIDExpression, latestPubDateExpression];
    latestDatesRequest.propertiesToGroupBy = @[@"feed.uid"];

    NSArray<NSDictionary*>* latestDateRows = [context executeFetchRequest:latestDatesRequest error:error];
    if (!latestDateRows) {
        return nil;
    }

    NSCalendar* calendar = [NSCalendar currentCalendar];
    NSMutableArray<NSPredicate*>* latestDayPredicates = [[NSMutableArray alloc] initWithCapacity:latestDateRows.count];
    for (NSDictionary* row in latestDateRows) {
        NSString* feedUID = row[@"feedUID"];
        NSDate* latestPubDate = row[@"latestPubDate"];
        if (![feedUID isKindOfClass:[NSString class]] || ![latestPubDate isKindOfClass:[NSDate class]]) {
            continue;
        }

        NSDate* startOfDay = [calendar startOfDayForDate:latestPubDate];
        NSDate* startOfNextDay = [calendar dateByAddingUnit:NSCalendarUnitDay
                                                      value:1
                                                     toDate:startOfDay
                                                    options:0];
        if (!startOfNextDay) {
            continue;
        }
        [latestDayPredicates addObject:[NSPredicate predicateWithFormat:@"feed.uid == %@ AND pubDate >= %@ AND pubDate < %@",
                                        feedUID, startOfDay, startOfNextDay]];
    }
    if (latestDayPredicates.count == 0) {
        return @[];
    }

    NSFetchRequest* candidatesRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    NSPredicate* eligiblePredicate = [NSPredicate predicateWithFormat:@"consumed == NO AND archived == NO AND feed.subscribed == YES AND feed.parked == NO"];
    candidatesRequest.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        eligiblePredicate,
        [NSCompoundPredicate orPredicateWithSubpredicates:latestDayPredicates]
    ]];
    candidatesRequest.sortDescriptors = @[
        [NSSortDescriptor sortDescriptorWithKey:@"feed.uid" ascending:YES],
        [NSSortDescriptor sortDescriptorWithKey:@"pubDate" ascending:NO],
        [NSSortDescriptor sortDescriptorWithKey:@"objectHash" ascending:YES]
    ];
    candidatesRequest.fetchBatchSize = ICAutoDownloadCandidateDeliveryBatchSize;
    candidatesRequest.includesSubentities = NO;

    NSArray<CDEpisode*>* episodes = [context executeFetchRequest:candidatesRequest error:error];
    if (!episodes) {
        return nil;
    }

    NSMutableArray<NSDictionary*>* candidates = [[NSMutableArray alloc] initWithCapacity:episodes.count];
    for (CDEpisode* episode in episodes) {
        NSManagedObjectID* feedObjectID = feedObjectIDsByUID[episode.feed.uid];
        if (!feedObjectID || episode.objectID.isTemporaryID) {
            continue;
        }
        [candidates addObject:@{
            ICAutoDownloadCandidateEpisodeObjectIDKey: episode.objectID,
            ICAutoDownloadCandidateFeedObjectIDKey: feedObjectID
        }];
    }
    return candidates;
}

+ (SubscriptionManager*) sharedSubscriptionManager
{
	if (!gSharedSubscriptionManager) {
		gSharedSubscriptionManager = [self alloc];
		gSharedSubscriptionManager = [gSharedSubscriptionManager init];
	}
	return gSharedSubscriptionManager;
}

- (id) init
{
	if ((self = [super init]))
	{
		_refreshingFeedURLs = [[NSMutableArray alloc] init];
        _refreshFeedStartDates = [[NSMutableDictionary alloc] init];
        _refreshFeedTitlesByURL = [[NSMutableDictionary alloc] init];
        _refreshFailedFeedTitles = [[NSMutableOrderedSet alloc] init];
        _refreshTimedOutFeedTitles = [[NSMutableOrderedSet alloc] init];
        _refreshFailureMessages = [[NSMutableOrderedSet alloc] init];
        
        _parserQueue = [[NSOperationQueue alloc] init];
        [_parserQueue setMaxConcurrentOperationCount:10];

        _mergeQueue = [[NSOperationQueue alloc] init];
        [_mergeQueue setMaxConcurrentOperationCount:2];
        _mergeQueue.qualityOfService = NSQualityOfServiceUtility;

        _feedsMergingURLs = [[NSMutableSet alloc] init];
        _pendingAutoDownloadFeedObjectIDs = [[NSMutableSet alloc] init];
        _unsubscribeCleanupProtectionStatesByFeedObjectURIString = [[NSMutableDictionary alloc] init];
        _unsubscribeCleanupProtectionLock = [[NSLock alloc] init];
        _unsubscribeCleanupRecoveryBlocked = YES;
        dispatch_queue_attr_t autoDownloadQueueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                                     QOS_CLASS_UTILITY,
                                                                                                     0);
        _autoDownloadFeedScanQueue = dispatch_queue_create("com.instacastplus.feed-auto-download-scan",
                                                           autoDownloadQueueAttributes);
        
#if TARGET_OS_IPHONE==0
        _checkTimer = [NSTimer scheduledTimerWithTimeInterval:5*60 block:^(NSTimeInterval time) {
            [self refreshAllFeedsForce:NO];
        } repeats:YES];
#endif
	}
	
	return self;
}

- (NSString*) formattedLastRefreshDate
{
    double lastRefreshDate = [USER_DEFAULTS doubleForKey:LastRefreshSubscriptionDate];
    if (lastRefreshDate <= 0) {
        return @"Last Updated: –".ls;
    }

    NSDate* date = [NSDate dateWithTimeIntervalSince1970:lastRefreshDate];
    NSTimeInterval elapsed = -[date timeIntervalSinceNow];

    NSString* relativeTime;
    if (elapsed < 60) {
        relativeTime = @"just now".ls;
    } else if (elapsed < 3600) {
        NSInteger minutes = (NSInteger)(elapsed / 60);
        relativeTime = [NSString stringWithFormat:@"%ld min ago".ls, (long)minutes];
    } else if (elapsed < 86400) {
        NSInteger hours = (NSInteger)(elapsed / 3600);
        relativeTime = [NSString stringWithFormat:@"%ld hours ago".ls, (long)hours];
    } else {
        NSInteger days = (NSInteger)(elapsed / 86400);
        relativeTime = [NSString stringWithFormat:@"%ld days ago".ls, (long)days];
    }

    return [NSString stringWithFormat:@"Last Updated: %@".ls, relativeTime];
}

- (NSString*) formattedLastRefreshDateForFeed:(CDFeed*)feed
{
    if (feed.lastUpdate) {
    
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateStyle:NSDateFormatterShortStyle];
        [formatter setTimeStyle:NSDateFormatterShortStyle];
        NSString* formattedDate = [NSString stringWithFormat:@"Last Updated: %@".ls, [formatter stringFromDate:feed.lastUpdate]];
        return formattedDate;
    }
    
    return [self formattedLastRefreshDate];
}

- (BOOL)canRefreshFeedsOnCurrentNetwork
{
    if (App.networkAccessTechnology == kICNetworkAccessTechnlogyWIFI) {
        return YES;
    }
    return App.networkAccessTechnology > kICNetworkAccessTechnlogyGPRS &&
           [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
}

// Returns YES if the two values differ (nil-safe). Used to avoid dirtying objects on
// every refresh merge: Core Data marks an object as updated even when a setter writes
// the identical value, and an always-dirty feed made every refresh fan out into FRC
// notifications, full table reloads and iCloud-sync change checks per feed.
static BOOL ICFeedValueDiffers(id currentValue, id newValue)
{
    if (currentValue == newValue) {
        return NO;
    }
    if (!currentValue || !newValue) {
        return YES;
    }
    return ![currentValue isEqual:newValue];
}

- (BOOL)_isSynchronizationPausedForFeed:(CDFeed*)feed
{
    if (!feed) {
        return NO;
    }
    return feed.parked;
}

- (NSArray<CDFeed*>*)_feedsEligibleForSynchronization:(NSArray<CDFeed*>*)feeds
{
    if (feeds.count == 0) {
        return @[];
    }

    NSMutableArray<CDFeed*>* eligibleFeeds = [NSMutableArray arrayWithCapacity:feeds.count];
    for (CDFeed* feed in feeds) {
        if (![self _isSynchronizationPausedForFeed:feed]) {
            [eligibleFeeds addObject:feed];
        }
    }
    return eligibleFeeds;
}

- (CDFeed*) subscribeParserFeed:(ICFeed*)parserFeed
{
    return [self subscribeParserFeed:parserFeed autodownload:YES options:kSubscribeOptionNone];
}

- (CDFeed*) subscribeParserFeed:(ICFeed*)parserFeed autodownload:(BOOL)autodownload options:(ICSubscribeOptions)options
{
    if (parserFeed.changedSourceURL) {
        parserFeed.sourceURL = parserFeed.changedSourceURL;
    }
    
    CDFeed* subscribedFeed = [DMANAGER subscribeFeed:parserFeed withOptions:options];
    if (autodownload && subscribedFeed.subscribed && !subscribedFeed.parked) {
        [self _autoDownloadEpisodesInFeedAsynchronously:subscribedFeed];
    }
    return subscribedFeed;
}

- (void) unsubscribeFeed:(CDFeed*)feed
{
    [self unsubscribeFeed:feed completion:^(NSError* error) {
        if (error) ErrLog(@"could not unsubscribe feed: %@", error);
    }];
}

- (void)unsubscribeFeed:(CDFeed*)feed
           completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self unsubscribeFeed:feed completion:completion];
        });
        return;
    }
    if (!feed) {
        if (completion) {
            completion([NSError errorWithDomain:@"SubscriptionManager"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"The podcast could not be unsubscribed because it is no longer available.".ls}]);
        }
        return;
    }
    [[ICiCloudSyncManager sharedManager]
        commitLocalSubscriptionUnsubscribeForFeed:feed
        completion:^(NSError* error) {
            if (completion) completion(error);
        }];
}

- (void)performUnsubscribeSideEffectsForFeeds:(NSArray<CDFeed*>*)feeds
                                   completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performUnsubscribeSideEffectsForFeeds:feeds completion:completion];
        });
        return;
    }

    NSMutableOrderedSet<CDFeed*>* uniqueFeeds = [NSMutableOrderedSet orderedSet];
    for (CDFeed* feed in feeds) {
        if ([feed isKindOfClass:[CDFeed class]]) {
            [uniqueFeeds addObject:feed];
        }
    }
    feeds = uniqueFeeds.array;
    if (feeds.count == 0) {
        if (completion) completion(nil);
        return;
    }

    PlaybackManager* pman = [PlaybackManager playbackManager];
    AudioSession* session = [AudioSession sharedAudioSession];
    NSSet<CDFeed*>* feedSet = [NSSet setWithArray:feeds];

    if ([feedSet containsObject:pman.playingEpisode.feed]) {
        [session stop];
    }

    EpisodeLoadingManager* loadingManager = [EpisodeLoadingManager sharedManager];
    for (CDFeed* feed in feeds) {
        [loadingManager cancelLoadingForFeed:feed];
    }

    NSMutableArray<CDEpisode*>* upNextEpisodes = [NSMutableArray array];
    for (CDEpisode* episode in session.playlist) {
        if ([feedSet containsObject:episode.feed]) {
            [upNextEpisodes addObject:episode];
        }
    }
    if (upNextEpisodes.count > 0) {
        [session eraseEpisodesFromUpNext:upNextEpisodes];
    }

    NSMutableSet<NSManagedObjectID*>* feedObjectIDs = [NSMutableSet setWithCapacity:feeds.count];
    NSMutableArray<NSString*>* feedUIDs = [NSMutableArray arrayWithCapacity:feeds.count];
    for (CDFeed* feed in feeds) {
        if (feed.objectID) [feedObjectIDs addObject:feed.objectID];
        if (feed.uid.length > 0) [feedUIDs addObject:feed.uid];
    }
    [self.pendingAutoDownloadFeedObjectIDs minusSet:feedObjectIDs];
    [self _removePendingAutoDownloadFeedUIDs:feedUIDs];

    CacheManager* cman = [CacheManager sharedCacheManager];
    __block BOOL cacheRemovalFinished = NO;
    __block BOOL historyResetFinished = NO;
    __block NSError* cacheRemovalError = nil;
    __block NSError* historyResetError = nil;
    void (^finishIfReady)(void) = ^{
        if (!cacheRemovalFinished || !historyResetFinished) return;
        if (completion) completion(cacheRemovalError ?: historyResetError);
    };
    [cman removeCacheForFeedsDuringSubscriptionCleanup:feeds completion:^(NSError* error) {
        cacheRemovalError = error;
        cacheRemovalFinished = YES;
        finishIfReady();
    }];
    [cman resetAutoCacheForFeeds:feeds completion:^(NSError* error) {
        historyResetError = error;
        historyResetFinished = YES;
        finishIfReady();
    }];
}

- (void)installAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:(NSString*)feedObjectURIString
                                                                  revision:(NSString*)revision
{
    if (feedObjectURIString.length == 0 || revision.length == 0) return;
    [self.unsubscribeCleanupProtectionLock lock];
    ICUnsubscribeCleanupProtectionState* state =
        self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString];
    if (!state) {
        state = [[ICUnsubscribeCleanupProtectionState alloc] init];
        self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString] = state;
    }

    ICUnsubscribeCleanupProtectionStage* matchingStage = nil;
    NSMutableArray<NSString*>* matchingStageTokens = [[NSMutableArray alloc] init];
    for (NSString* stageToken in state.stagesByToken) {
        ICUnsubscribeCleanupProtectionStage* stage = state.stagesByToken[stageToken];
        if (![stage.revision isEqualToString:revision]) continue;
        [matchingStageTokens addObject:stageToken];
        if (!matchingStage || stage.sequence > matchingStage.sequence) {
            matchingStage = stage;
        }
    }
    if (matchingStage) {
        if (matchingStage.sequence > state.committedSequence) {
            state.committedRevision = matchingStage.revision;
            state.committedSequence = matchingStage.sequence;
        }
        [state.stagesByToken removeObjectsForKeys:matchingStageTokens];
    } else if (state.committedSequence == 0) {
        state.committedRevision = revision;
        state.committedSequence = 0;
    }
    BOOL becameUnprotected = !state.committedRevision && state.stagesByToken.count == 0;
    if (becameUnprotected) {
        [self.unsubscribeCleanupProtectionStatesByFeedObjectURIString removeObjectForKey:feedObjectURIString];
    }
    [self.unsubscribeCleanupProtectionLock unlock];
    if (becameUnprotected) {
        [self _resumeAfterUnsubscribeCleanupProtectionChange];
    }
}

- (NSString*)stageAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:(NSString*)feedObjectURIString
                                                                      revision:(NSString*)revision
{
    if (feedObjectURIString.length == 0 || revision.length == 0) return nil;
    [self.unsubscribeCleanupProtectionLock lock];
    ICUnsubscribeCleanupProtectionState* state =
        self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString];
    if (!state) {
        state = [[ICUnsubscribeCleanupProtectionState alloc] init];
        self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString] = state;
    }
    NSString* stageToken = NSUUID.UUID.UUIDString;
    ICUnsubscribeCleanupProtectionStage* stage =
        [[ICUnsubscribeCleanupProtectionStage alloc] init];
    stage.revision = revision;
    stage.sequence = ++self.unsubscribeCleanupProtectionSequence;
    state.stagesByToken[stageToken] = stage;
    [self.unsubscribeCleanupProtectionLock unlock];
    return stageToken;
}

- (void)commitAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:(NSString*)feedObjectURIString
                                                                  revision:(NSString*)revision
                                                                stageToken:(NSString*)stageToken
{
    if (feedObjectURIString.length == 0 || revision.length == 0 || stageToken.length == 0) return;
    [self.unsubscribeCleanupProtectionLock lock];
    ICUnsubscribeCleanupProtectionState* state =
        self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString];
    ICUnsubscribeCleanupProtectionStage* stage = state.stagesByToken[stageToken];
    if (!stage || ![stage.revision isEqualToString:revision]) {
        [self.unsubscribeCleanupProtectionLock unlock];
        return;
    }
    [state.stagesByToken removeObjectForKey:stageToken];
    if (stage.sequence > state.committedSequence) {
        state.committedRevision = stage.revision;
        state.committedSequence = stage.sequence;
    }
    BOOL becameUnprotected = !state.committedRevision && state.stagesByToken.count == 0;
    if (becameUnprotected) {
        [self.unsubscribeCleanupProtectionStatesByFeedObjectURIString removeObjectForKey:feedObjectURIString];
    }
    [self.unsubscribeCleanupProtectionLock unlock];
    if (becameUnprotected) {
        [self _resumeAfterUnsubscribeCleanupProtectionChange];
    }
}

- (void)cancelAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:(NSString*)feedObjectURIString
                                                                  revision:(NSString*)revision
                                                                stageToken:(NSString*)stageToken
{
    if (feedObjectURIString.length == 0 || revision.length == 0 || stageToken.length == 0) return;
    [self.unsubscribeCleanupProtectionLock lock];
    ICUnsubscribeCleanupProtectionState* state =
        self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString];
    ICUnsubscribeCleanupProtectionStage* stage = state.stagesByToken[stageToken];
    if (stage && [stage.revision isEqualToString:revision]) {
        [state.stagesByToken removeObjectForKey:stageToken];
    }
    BOOL becameUnprotected = state && !state.committedRevision && state.stagesByToken.count == 0;
    if (becameUnprotected) {
        [self.unsubscribeCleanupProtectionStatesByFeedObjectURIString removeObjectForKey:feedObjectURIString];
    }
    [self.unsubscribeCleanupProtectionLock unlock];
    if (becameUnprotected) {
        [self _resumeAfterUnsubscribeCleanupProtectionChange];
    }
}

- (void)completeAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:(NSString*)feedObjectURIString
                                                                    revision:(NSString*)revision
{
    if (feedObjectURIString.length == 0 || revision.length == 0) return;
    [self.unsubscribeCleanupProtectionLock lock];
    ICUnsubscribeCleanupProtectionState* state =
        self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString];
    if ([state.committedRevision isEqualToString:revision]) {
        state.committedRevision = nil;
    }
    NSMutableArray<NSString*>* matchingStageTokens = [[NSMutableArray alloc] init];
    for (NSString* stageToken in state.stagesByToken) {
        if ([state.stagesByToken[stageToken].revision isEqualToString:revision]) {
            [matchingStageTokens addObject:stageToken];
        }
    }
    [state.stagesByToken removeObjectsForKeys:matchingStageTokens];
    BOOL becameUnprotected = state && !state.committedRevision && state.stagesByToken.count == 0;
    if (becameUnprotected) {
        [self.unsubscribeCleanupProtectionStatesByFeedObjectURIString removeObjectForKey:feedObjectURIString];
    }
    [self.unsubscribeCleanupProtectionLock unlock];
    if (becameUnprotected) {
        [self _resumeAfterUnsubscribeCleanupProtectionChange];
    }
}

- (BOOL)_autoDownloadsBlockedDuringUnsubscribeCleanupForFeedObjectID:(NSManagedObjectID*)feedObjectID
{
    NSString* feedObjectURIString = !feedObjectID.isTemporaryID
        ? feedObjectID.URIRepresentation.absoluteString : nil;
    [self.unsubscribeCleanupProtectionLock lock];
    BOOL blocked = self.unsubscribeCleanupRecoveryBlocked;
    if (!blocked && feedObjectURIString.length > 0) {
        ICUnsubscribeCleanupProtectionState* state =
            self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString];
        blocked = state.committedRevision.length > 0 || state.stagesByToken.count > 0;
    }
    [self.unsubscribeCleanupProtectionLock unlock];
    return blocked || feedObjectURIString.length == 0;
}

- (BOOL)automaticDownloadsBlockedDuringUnsubscribeCleanupForFeed:(CDFeed*)feed
{
    NSAssert([NSThread isMainThread], @"Automatic download eligibility belongs to the main thread");
    if (![feed isKindOfClass:[CDFeed class]] || feed.isDeleted ||
        !feed.subscribed || feed.parked) {
        return YES;
    }
    return [self _autoDownloadsBlockedDuringUnsubscribeCleanupForFeedObjectID:feed.objectID];
}

- (BOOL)downloadsBlockedDuringUnsubscribeCleanupForFeed:(CDFeed*)feed
{
    NSAssert([NSThread isMainThread], @"Download cleanup eligibility belongs to the main thread");
    NSString* feedObjectURIString = [feed isKindOfClass:[CDFeed class]]
        && !feed.objectID.isTemporaryID
        ? feed.objectID.URIRepresentation.absoluteString : nil;
    [self.unsubscribeCleanupProtectionLock lock];
    BOOL blocked = self.unsubscribeCleanupRecoveryBlocked;
    if (!blocked && feedObjectURIString.length > 0) {
        ICUnsubscribeCleanupProtectionState* state =
            self.unsubscribeCleanupProtectionStatesByFeedObjectURIString[feedObjectURIString];
        blocked = state.committedRevision.length > 0 || state.stagesByToken.count > 0;
    }
    [self.unsubscribeCleanupProtectionLock unlock];
    return blocked;
}

- (void)_resumeAfterUnsubscribeCleanupProtectionChange
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _startPendingAutoDownloads];
        [[NSNotificationCenter defaultCenter]
            postNotificationName:SubscriptionManagerUnsubscribeCleanupProtectionDidChangeNotification
                          object:self];
    });
}

- (void)setUnsubscribeCleanupRecoveryBlocked:(BOOL)blocked
{
    NSAssert([NSThread isMainThread], @"Unsubscribe cleanup state belongs to the main thread");
    [self.unsubscribeCleanupProtectionLock lock];
    BOOL becameUnblocked = _unsubscribeCleanupRecoveryBlocked && !blocked;
    _unsubscribeCleanupRecoveryBlocked = blocked;
    [self.unsubscribeCleanupProtectionLock unlock];
    if (becameUnblocked) [self _resumeAfterUnsubscribeCleanupProtectionChange];
}

- (void)resetUnsubscribeCleanupProtectionForLocalAppReset
{
    NSAssert([NSThread isMainThread], @"Unsubscribe cleanup state belongs to the main thread");
    [self.unsubscribeCleanupProtectionLock lock];
    _unsubscribeCleanupRecoveryBlocked = YES;
    [self.unsubscribeCleanupProtectionStatesByFeedObjectURIString removeAllObjects];
    [self.unsubscribeCleanupProtectionLock unlock];
}

- (void)performResubscribeCleanupForFeeds:(NSArray<CDFeed*>*)feeds
                               completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performResubscribeCleanupForFeeds:feeds completion:completion];
        });
        return;
    }

    NSMutableOrderedSet<CDFeed*>* uniqueFeeds = [NSMutableOrderedSet orderedSet];
    for (CDFeed* feed in feeds) {
        if ([feed isKindOfClass:[CDFeed class]]) [uniqueFeeds addObject:feed];
    }
    feeds = uniqueFeeds.array;
    if (feeds.count == 0) {
        if (completion) completion(nil);
        return;
    }

    [[CacheManager sharedCacheManager] resetAutoCacheForFeeds:feeds completion:^(NSError* error) {
        if (completion) completion(error);
    }];
}

- (void) reloadContentOfFeed:(CDFeed*)feed recoverArchivedEpisodes:(BOOL)recoverArchived completion:(ICSubscriptionManagerRefreshCompletionBlock)completion
{
    if (!feed || [self _isSynchronizationPausedForFeed:feed]) {
        if (completion) {
            completion(YES, @[], nil);
        }
        return;
    }

    NSURL* sourceURL = feed.sourceURL;
    ICPagedFeedParser* parser = [[ICPagedFeedParser alloc] init];
    parser.url = sourceURL;
    parser.username = feed.username;
    parser.password = feed.password;
    parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
    parser.didParseFeedBlock = ^(ICFeed* parserFeed) {
        
        NSArray* newEpisodes = [self _mergeLocalFeed:feed withWithRemoteFeed:parserFeed force:YES];
        if (newEpisodes.count > 0) {
            [self _postDidAddEpisodesNotification:newEpisodes];
        }

        // delete cached chapters
        for(CDEpisode* episode in feed.episodes) {
            NSSet* chapters = [episode.chapters copy];
            for(NSManagedObject* chapter in chapters) {
                [DMANAGER.objectContext deleteObject:chapter];
            }
            
            // recover all deleted episodes
            if (recoverArchived) {
                episode.archived = NO;
            }
            
//                // recreate object hashes, important for sync
//                [episode reconstructObjectHash];
        }
        
        if (![feed boolForKey:kDefaultShowUnavailableEpisodes]) {
            [self _deleteUnavailableEpisodesFromFeed:feed withRemoteFeed:parserFeed];
        }
        
        if ([newEpisodes count] > 0 && [feed boolForKey:AutoDeleteNewsMode]) {
            [self _recycleOldEpisodesInNewsModeFeed:feed];
        }

        [self _enforceKeepNewestLimitForFeed:feed];

        if (newEpisodes.count > 0) {
            [self _retainPendingAutoDownloadFeedUIDs:@[feed.uid ?: @""]];
        }

        NSError* reloadSaveError = [DMANAGER saveReturningError];
        if (reloadSaveError) {
            if (completion) {
                completion(NO, nil, reloadSaveError);
            }
            return;
        }

        if (newEpisodes.count > 0) {
            [self _autoDownloadEpisodesInFeedAsynchronously:feed];
        }

        if (completion) {
            completion(YES ,newEpisodes, nil);
        }
    };
    parser.didEndWithError = ^(NSError* error) {

        if (completion) {
            completion(NO, nil, error);
        }
    };

    [_parserQueue addOperation:parser];
}

- (void) subscribeFeedWithURL:(NSURL*)url options:(ICSubscribeOptions)options completion:(void (^)(CDFeed* feed, NSError* error))completion
{
    [self subscribeFeedWithURL:url username:nil password:nil options:options completion:completion];
}

- (void) subscribeFeedWithURL:(NSURL*)url username:(NSString*)username password:(NSString*)password options:(ICSubscribeOptions)options completion:(void (^)(CDFeed* feed, NSError* error))completion
{
    if (!url) {
        return;
    }

    [App retainNetworkActivity];

    ICFeedParser* parser = [[ICFeedParser alloc] init];
    parser.url = url;
    parser.timeout = 20;
    parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
    if (username.length > 0) parser.username = username;
    if (password.length > 0) parser.password = password;
    parser.dontAskForCredentials = (username.length > 0); // Don't show auth dialog if we have credentials

    parser.didParseFeedBlock = ^(ICFeed* parserFeed) {

        CDFeed* persistentFeed = [self subscribeParserFeed:parserFeed autodownload:YES options:options];

        [DMANAGER save];

        if (completion) {
            completion(persistentFeed, nil);
        }

        [App releaseNetworkActivity];

    };
    parser.didEndWithError = ^(NSError* error) {
        if (completion) {
            completion(nil, error);
        }
        [App releaseNetworkActivity];
    };

    [_parserQueue addOperation:parser];
}

- (void) subscribeFeedWithOpmlURL:(NSURL*)url options:(ICSubscribeOptions)options completion:(void (^)(CDFeed* feed, NSError* error))completion
{
    if (!url) {
        return;
    }
    
    [App retainNetworkActivity];

    ICFeedParser* parser = [[ICFeedParser alloc] init];
    parser.url = url;
    parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
    parser.didParseFeedBlock = ^(ICFeed* parserFeed) {
        
        CDFeed* persistentFeed = [self subscribeParserFeed:parserFeed autodownload:NO options:options];
        
        [DMANAGER save];
        
        if (completion) {
            completion(persistentFeed, nil);
        }
        
        [App releaseNetworkActivity];

    };
    parser.didEndWithError = ^(NSError* error) {
        if (completion) {
            completion(nil, error);
        }
        [App releaseNetworkActivity];
    };
    
    [_parserQueue addOperation:parser];
}

- (void) subscribeFeedWithOpmlURLNew:(NSURL*)url options:(ICSubscribeOptions)options completion:(void (^)(CDFeed* feed, NSError* error))completion
{
    if (!url) {
        return;
    }
    
    [App retainNetworkActivity];

    ICFeedParser* parser = [[ICFeedParser alloc] init];
    parser.url = url;
    parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
    parser.timeout = 8;
    parser.didParseFeedBlock = ^(ICFeed* parserFeed) {
        // Core Data access must happen on main queue (DMANAGER.objectContext is main-queue context)
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!url) {
                if (completion) completion(nil, [NSError errorWithDomain:@"OPML" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Invalid feed URL"}]);
                [App releaseNetworkActivity];
                return;
            }

            // Check if already subscribed
            NSFetchRequest *fetchRequest = [CDFeed fetchRequest];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", url.absoluteString];
            fetchRequest.fetchLimit = 1;
            NSError *fetchError = nil;
            NSArray *existingFeeds = [DMANAGER.objectContext executeFetchRequest:fetchRequest error:&fetchError];

            CDFeed *persistentFeed = nil;

            if (existingFeeds.count > 0) {
                persistentFeed = existingFeeds.firstObject;
            } else {
                persistentFeed = [self subscribeParserFeed:parserFeed autodownload:NO options:options];
                [DMANAGER save];
            }

            if (completion) {
                completion(persistentFeed, fetchError);
            }

            [App releaseNetworkActivity];
        });
    };
    parser.didEndWithError = ^(NSError* error) {
        if (completion) {
            completion(nil, error);
        }
        [App releaseNetworkActivity];
    };
    
    [_parserQueue addOperation:parser];
}

#pragma mark -
#pragma mark Refreshing Feeds


- (BOOL) isRefreshing
{
	return (self.refreshCheckTimer != nil);
}

- (double) refreshProgress
{
    return MAX(0.0, MIN(1.0, (double)(self.numTotalRefreshFeeds - [self.refreshingFeedURLs count])/self.numTotalRefreshFeeds));
}

- (NSString*) refreshStatusText
{
    if (!self.isRefreshing && self.finalRefreshStatusText.length > 0) {
        return self.finalRefreshStatusText;
    }

    if (self.numTotalRefreshFeeds <= 0) {
        return @"Looking for new episodes…".ls;
    }

    // Generic status for episode-centric views (no podcast count here).
    return @"Looking for new episodes…".ls;
}

- (NSString*) refreshStatusTextWithPodcastCount
{
    if (!self.isRefreshing && self.finalRefreshStatusText.length > 0) {
        return self.finalRefreshStatusText;
    }

    NSInteger remaining = [self.refreshingFeedURLs count];
    NSInteger done = self.numTotalRefreshFeeds - remaining;

    if (self.numTotalRefreshFeeds <= 0) {
        return @"Looking for new episodes…".ls;
    }

    return [NSString stringWithFormat:@"%ld/%ld podcasts updating…".ls, (long)done, (long)self.numTotalRefreshFeeds];
}

- (NSString*) lastRefreshingFeedName
{
    if (self.refreshingFeedURLs.count == 1) {
        NSURL* url = self.refreshingFeedURLs.firstObject;
        for (CDFeed* feed in [DMANAGER visibleFeeds]) {
            if ([feed.sourceURL isEqual:url]) {
                return feed.title;
            }
        }
    }
    return nil;
}

- (NSArray<NSString*>*) pendingRefreshFeedTitles
{
    NSMutableArray<NSString*>* titles = [NSMutableArray arrayWithCapacity:self.refreshingFeedURLs.count];
    for (NSURL* url in self.refreshingFeedURLs) {
        NSString* title = self.refreshFeedTitlesByURL[url];
        if (!title.length) {
            title = url.host ?: url.absoluteString;
        }
        [titles addObject:title];
    }
    return titles;
}

- (NSString*) pendingRefreshStatusDetailsText
{
    NSArray<NSString*>* pendingTitles = self.pendingRefreshFeedTitles;
    if (pendingTitles.count == 0) {
        return nil;
    }
    NSMutableString* details = [NSMutableString stringWithFormat:@"Not updated yet (%ld):".ls, (long)pendingTitles.count];
    for (NSString* title in pendingTitles) {
        [details appendFormat:@"\n• %@", title];
    }
    return details;
}

- (NSArray<NSString*>*) lastRefreshFailureMessages
{
    return [self.refreshFailureMessages array];
}

- (NSString*) _friendlyRefreshFailureReasonForError:(NSError*)error
{
    if (!error) {
        return @"Unknown error".ls;
    }

    NSString* recoverySuggestion = [error.userInfo[NSLocalizedRecoverySuggestionErrorKey] description];
    if ([recoverySuggestion isEqualToString:@"Returned content is a website and not a podcast feed.".ls]) {
        return @"Website returned instead of podcast feed.".ls;
    }
    if ([recoverySuggestion isEqualToString:@"The podcast feed can not be found.".ls]) {
        return @"Feed not found or removed.".ls;
    }
    if ([recoverySuggestion isEqualToString:@"The server is temporarily unavailable.".ls]) {
        return @"Server temporarily unavailable.".ls;
    }
    if ([recoverySuggestion isEqualToString:@"The server rejected the feed request.".ls]) {
        return @"Server rejected the feed request.".ls;
    }
    if ([recoverySuggestion isEqualToString:@"The feed could not be read because the username or password is incorrect.".ls]) {
        return @"No access.".ls;
    }
    if ([recoverySuggestion isEqualToString:@"The podcast could not be read, either because the feed does not exist or because the feed format is not supported.".ls]) {
        return @"Unsupported podcast feed format.".ls;
    }

    NSNumber* httpStatusCode = error.userInfo[ICFeedParserHTTPStatusCodeErrorKey];
    if ([httpStatusCode respondsToSelector:@selector(integerValue)]) {
        NSInteger statusCode = httpStatusCode.integerValue;
        if (statusCode == 401 || statusCode == 403) {
            return @"No access.".ls;
        }
        if (statusCode == 404 || statusCode == 410) {
            return @"Feed not found or removed.".ls;
        }
        if (statusCode >= 500 && statusCode < 600) {
            return @"Server temporarily unavailable.".ls;
        }
        if (statusCode >= 400 && statusCode < 500) {
            return @"Server rejected the feed request.".ls;
        }
    }

    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorNotConnectedToInternet:
                return @"No internet connection.".ls;
            case NSURLErrorTimedOut:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorNetworkConnectionLost:
                return @"Server temporarily unavailable.".ls;
            case NSURLErrorCannotFindHost:
            case NSURLErrorDNSLookupFailed:
                return @"Domain not found.".ls;
            case NSURLErrorFileDoesNotExist:
            case NSURLErrorResourceUnavailable:
                return @"Feed not found or removed.".ls;
            case NSURLErrorUserAuthenticationRequired:
            case NSURLErrorNoPermissionsToReadFile:
            case NSURLErrorDataNotAllowed:
                return @"No access.".ls;
            case NSURLErrorSecureConnectionFailed:
            case NSURLErrorServerCertificateHasBadDate:
            case NSURLErrorServerCertificateUntrusted:
            case NSURLErrorServerCertificateHasUnknownRoot:
            case NSURLErrorServerCertificateNotYetValid:
                return @"Secure connection failed.".ls;
            default:
                break;
        }
    }

    if ([error.domain isEqualToString:NSXMLParserErrorDomain]) {
        return @"Feed contains invalid XML.".ls;
    }

    if ([error.domain isEqualToString:@"kPodcastFeedParserErrorDomain"]) {
        return @"Unsupported podcast feed format.".ls;
    }

    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCannotParseResponse) {
        return @"Unsupported podcast feed format.".ls;
    }

    NSError* underlyingError = error.userInfo[NSUnderlyingErrorKey];
    if ([underlyingError isKindOfClass:[NSError class]]) {
        NSString* underlyingReason = [self _friendlyRefreshFailureReasonForError:underlyingError];
        if (![underlyingReason isEqualToString:@"Unknown error".ls]) {
            return underlyingReason;
        }
    }

    return @"Unknown error".ls;
}

- (void) _beginRefreshTrackingForFeeds:(NSArray*)feeds
{
    [self.refreshFeedStartDates removeAllObjects];
    [self.refreshFeedTitlesByURL removeAllObjects];
    [self.refreshFailedFeedTitles removeAllObjects];
    [self.refreshTimedOutFeedTitles removeAllObjects];
    [self.refreshFailureMessages removeAllObjects];
    [self.feedsMergingURLs removeAllObjects];
    self.lastRefreshFailedFeedName = nil;
    self.finalRefreshStatusText = nil;

    NSDate* now = [NSDate date];
    for (CDFeed* feed in feeds) {
        NSURL* url = [feed.sourceURL copy];
        if (!url) {
            continue;
        }
        self.refreshFeedStartDates[url] = now;
        if (feed.title.length > 0) {
            self.refreshFeedTitlesByURL[url] = feed.title;
        }
    }
}

- (void) _markFeedFailedForURL:(NSURL*)url timedOut:(BOOL)timedOut error:(NSError*)error
{
    NSString* title = self.refreshFeedTitlesByURL[url];
    if (!title.length) {
        title = url.host ?: url.absoluteString;
    }
    if (title.length == 0) {
        return;
    }
    [self.refreshFailedFeedTitles addObject:title];
    if (timedOut) {
        [self.refreshTimedOutFeedTitles addObject:title];
    }

    NSString* reason = timedOut ? @"Timeout".ls : [self _friendlyRefreshFailureReasonForError:error];
    NSString* line = [NSString stringWithFormat:@"%@ - %@", title, reason];
    [self.refreshFailureMessages addObject:line];
}

- (void) _removeFeedTrackingForURL:(NSURL*)url
{
    [self.refreshFeedStartDates removeObjectForKey:url];
    [self.refreshFeedTitlesByURL removeObjectForKey:url];
}

- (void) _finishRefreshingURL:(NSURL*)url
{
    [self willChangeValueForKey:@"refreshStatusText"];
    [self willChangeValueForKey:@"lastRefreshingFeedName"];
    [self.refreshingFeedURLs removeObject:url];
    [self.feedsMergingURLs removeObject:url];
    [self _removeFeedTrackingForURL:url];
    [self didChangeValueForKey:@"lastRefreshingFeedName"];
    [self didChangeValueForKey:@"refreshStatusText"];
}

- (void) refreshAllFeedsForce:(BOOL)force
{
    return [self refreshAllFeedsForce:force etagHandling:YES completion:nil];
}

- (void) refreshAllFeedsForce:(BOOL)force completion:(ICSubscriptionManagerRefreshCompletionBlock)completion
{
    [self refreshAllFeedsForce:force etagHandling:YES completion:completion];
}

- (void) refreshAllFeedsForce:(BOOL)force etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion
{
    NSMutableArray* feeds = [[NSMutableArray alloc] init];
    NSArray* allNonParkedFeeds = [DMANAGER visibleFeeds];
    
#if TARGET_OS_IPHONE
    for (CDFeed* feed in allNonParkedFeeds) {
        if ([self _isSynchronizationPausedForFeed:feed]) {
            continue;
        }
        [feeds addObject:feed];
    }
#else
    // check settings
    if (force) {
        for (CDFeed* feed in allNonParkedFeeds) {
            if ([self _isSynchronizationPausedForFeed:feed]) {
                continue;
            }
            [feeds addObject:feed];
        }
    }
    else
    {
        if (App.networkAccessTechnology < kICNetworkAccessTechnlogyEDGE) {
            return;
        }
        
        for(CDFeed* feed in allNonParkedFeeds)
        {
            if ([self _isSynchronizationPausedForFeed:feed]) {
                continue;
            }

            NSDate* lastRefreshDate = (feed.lastUpdate) ? feed.lastUpdate : [NSDate distantPast];
            
            AutoRefreshInterval autoRefreshInterval = [feed integerForKey:AutoRefresh];
            
            switch (autoRefreshInterval) {
                case AutoRefreshNever:
                    continue;
                    
                case AutoRefreshOncePerDay:
                {
                    NSCalendar* cal = [NSCalendar currentCalendar];
                    NSDateComponents* lastComps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:lastRefreshDate];
                    NSDateComponents* nowComps = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:[NSDate date]];
                    
                    if ([lastComps year] == [nowComps year] && [lastComps month] == [nowComps month] && [lastComps day] == [nowComps day]) {
                        continue;
                    }
                }
                    break;
                    
                case AutoRefreshEvery12Hours:
                    if ([[NSDate date] timeIntervalSinceDate:lastRefreshDate] < 12*60*60) {
                        continue;
                    }
                    break;
                    
                case AutoRefreshEvery6Hours:
                    if ([[NSDate date] timeIntervalSinceDate:lastRefreshDate] < 6*60*60) {
                        continue;
                    }
                    break;
                    
                case AutoRefreshEveryHour:
                    if ([[NSDate date] timeIntervalSinceDate:lastRefreshDate] < 1*60*60) {
                        continue;
                    }
                    break;
                    
                case AutoRefreshEvery15Minutes:
                    if ([[NSDate date] timeIntervalSinceDate:lastRefreshDate] < 15*60) {
                        continue;
                    }
                    break;
                    
                default:
                    break;
            }
            
            [feeds addObject:feed];
        }
    }
#endif
    
    if ([feeds count] > 0) {
        [self refreshFeeds:feeds etagHandling:etagHandling completion:completion];
    }
    else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidFinishRefreshingFeedsNotification object:self];
        });
    }
}


- (void) refreshFeeds:(NSArray*)feeds etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion
{
    if (self.importing) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(YES, @[], nil);
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidFinishRefreshingFeedsNotification object:self];
        });
        return;
    }

    NSArray* eligibleFeeds = [self _feedsEligibleForSynchronization:feeds];
    if ([eligibleFeeds count] == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(YES, @[], nil);
            }
            if (!self.refreshCheckTimer) {
                [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidFinishRefreshingFeedsNotification object:self];
            }
        });
        return;
    }
    
    
    if (!self.refreshCheckTimer)
    {
        PlaySoundFile(@"Scratch2",NO);
        [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerWillStartRefreshingFeedsNotification object:self];
        
        [App retainNetworkActivity];
        self.refreshCheckTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                                  target:self
                                                                selector:@selector(checkRefreshOperationsTimer:)
                                                                userInfo:eligibleFeeds
                                                                 repeats:YES];
        
        self.numOfNewEpisodesAfterRefresh = 0;
        self.numTotalRefreshFeeds = [eligibleFeeds count];
        self.refreshStartDate = [NSDate date];
        [self _beginRefreshTrackingForFeeds:eligibleFeeds];
#if TARGET_OS_IPHONE
        self.backgroundIdentifier = [App beginBackgroundTaskWithExpirationHandler:(^(void) {
            [App endBackgroundTask:self.backgroundIdentifier];
            self.backgroundIdentifier = UIBackgroundTaskInvalid;
        })];
#endif
        
        [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidStartRefreshingFeedsNotification object:self];
    }


    __block NSInteger remainingRefreshCompletions = eligibleFeeds.count;
    __block BOOL allRefreshesSucceeded = YES;
    __block NSError* firstRefreshError = nil;
    __block NSMutableArray* batchNewEpisodes = [[NSMutableArray alloc] init];
    ICSubscriptionManagerRefreshCompletionBlock batchCompletion = nil;
    if (completion) {
        batchCompletion = ^(BOOL success, NSArray* newEpisodes, NSError* error) {
            if (!success) {
                allRefreshesSucceeded = NO;
                if (!firstRefreshError) {
                    firstRefreshError = error;
                }
            }
            if (newEpisodes.count > 0) {
                [batchNewEpisodes addObjectsFromArray:newEpisodes];
            }
            remainingRefreshCompletions--;
            if (remainingRefreshCompletions == 0) {
                completion(allRefreshesSucceeded, [batchNewEpisodes copy], firstRefreshError);
            }
        };
    }

    for(CDFeed* feed in eligibleFeeds)
    {
        [self refreshFeed:feed
             etagHandling:etagHandling
               completion:batchCompletion];
    }
    
}

- (void) _finishParsingFeed:(CDFeed*)feed url:(NSURL*)url shouldAutoDownload:(BOOL)shouldAutoDownload
{
    if (shouldAutoDownload && feed.objectID && !feed.objectID.isTemporaryID) {
        [self.pendingAutoDownloadFeedObjectIDs addObject:feed.objectID];
    }

    [self _enforceKeepNewestLimitForFeed:feed];

    // Must always run on main thread.
    [self _finishRefreshingURL:url];

    [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidParseFeedNotification
                                                        object:self
                                                      userInfo:(feed)?[NSDictionary dictionaryWithObject:feed forKey:@"feed"]:nil];
}

- (NSArray<NSString*>*)_pendingAutoDownloadFeedUIDs
{
    id storedValue = [USER_DEFAULTS objectForKey:ICPendingAutoDownloadFeedUIDsKey];
    if (![storedValue isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableOrderedSet<NSString*>* validFeedUIDs = [[NSMutableOrderedSet alloc] init];
    for (id value in (NSArray*)storedValue) {
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            [validFeedUIDs addObject:value];
        }
    }
    return validFeedUIDs.array;
}

- (void)_retainPendingAutoDownloadFeedUIDs:(NSArray<NSString*>*)feedUIDs
{
    NSAssert([NSThread isMainThread], @"Auto-download handoff persistence belongs to the main-context lifecycle");
    NSMutableOrderedSet<NSString*>* pendingFeedUIDs = [NSMutableOrderedSet orderedSetWithArray:[self _pendingAutoDownloadFeedUIDs]];
    NSUInteger previousCount = pendingFeedUIDs.count;
    for (NSString* feedUID in feedUIDs) {
        if ([feedUID isKindOfClass:[NSString class]] && feedUID.length > 0) {
            [pendingFeedUIDs addObject:feedUID];
        }
    }
    if (pendingFeedUIDs.count == previousCount) {
        return;
    }
    [USER_DEFAULTS setObject:pendingFeedUIDs.array forKey:ICPendingAutoDownloadFeedUIDsKey];
    [USER_DEFAULTS synchronize];
}

- (void)_retainPendingAutoDownloadFeedObjectIDs:(NSArray<NSManagedObjectID*>*)feedObjectIDs
{
    NSMutableArray<NSString*>* feedUIDs = [[NSMutableArray alloc] initWithCapacity:feedObjectIDs.count];
    for (NSManagedObjectID* feedObjectID in feedObjectIDs) {
        NSError* error = nil;
        CDFeed* feed = (CDFeed*)[DMANAGER.objectContext existingObjectWithID:feedObjectID error:&error];
        if ([feed isKindOfClass:[CDFeed class]] && !error && !feed.isDeleted && feed.uid.length > 0) {
            [feedUIDs addObject:feed.uid];
        }
    }
    [self _retainPendingAutoDownloadFeedUIDs:feedUIDs];
}

- (void)_removePendingAutoDownloadFeedUIDs:(NSArray<NSString*>*)feedUIDs
{
    NSAssert([NSThread isMainThread], @"Auto-download handoff persistence belongs to the main-context lifecycle");
    if (feedUIDs.count == 0) {
        return;
    }
    NSMutableOrderedSet<NSString*>* pendingFeedUIDs = [NSMutableOrderedSet orderedSetWithArray:[self _pendingAutoDownloadFeedUIDs]];
    [pendingFeedUIDs removeObjectsInArray:feedUIDs];
    if (pendingFeedUIDs.count > 0) {
        [USER_DEFAULTS setObject:pendingFeedUIDs.array forKey:ICPendingAutoDownloadFeedUIDsKey];
    } else {
        [USER_DEFAULTS removeObjectForKey:ICPendingAutoDownloadFeedUIDsKey];
    }
    // This also commits the download jobs that CacheManager persisted before this
    // handoff acknowledgement, so a kill cannot lose both the intent and the job.
    [USER_DEFAULTS synchronize];
}

- (void)_startPendingAutoDownloads
{
    [self _autoDownloadEpisodesInFeedAsynchronously:nil];
}

// Marks that this feed already got its one full duration-metadata parse.
static NSString* const kFeedPropertyDurationRefreshAttempted = @"durationMetadataRefreshAttempted";

- (BOOL)_feedNeedsDurationMetadataRefresh:(CDFeed*)feed
{
    // At most ONE full (etag-less) parse per feed, ever: if the feed didn't deliver
    // durations on that pass it never will, and whenever the feed content actually
    // changes the regular merge updates durations anyway (updateLocalFeedInfo).
    // Re-forcing a full download+merge on EVERY refresh (introduced 25.04. with the
    // transcript feature) defeated the etag cache — refreshes took 3-4x longer.
    if ([feed boolForKey:kFeedPropertyDurationRefreshAttempted]) {
        return NO;
    }

    // Count via SQL instead of iterating the episodes relationship: the old loop ran
    // on the main thread for every feed when a refresh started and fired thousands of
    // faults — the multi-second freeze right after pull-to-refresh.
    NSFetchRequest* request = [[NSFetchRequest alloc] init];
    request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:feed.managedObjectContext];
    request.predicate = [NSPredicate predicateWithFormat:@"feed == %@ AND archived == NO AND consumed == NO AND position <= 0 AND duration <= 0", feed];
    request.includesSubentities = NO;
    NSUInteger count = [feed.managedObjectContext countForFetchRequest:request error:NULL];
    return (count != NSNotFound && count > 0);
}

- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion
{
    if (!feed || [self _isSynchronizationPausedForFeed:feed]) {
        if (completion) {
            completion(YES, @[], nil);
        }
        return;
    }

    // iCloud sync stubs (subscribed, never refreshed, no episodes) belong to the
    // sequential hydration queue — a regular refresh would merge the full feed in one
    // main-context push. The same applies while that backlog is already loading.
    if ((!feed.lastUpdate && feed.episodes.count == 0) ||
        [[EpisodeLoadingManager sharedManager] isLoadingFeed:feed]) {
        if (completion) {
            completion(YES, @[], nil);
        }
        return;
    }

    NSURL* url = [feed.sourceURL copy];
    if (!url) {
        if (completion) {
            completion(YES, @[], nil);
        }
        return;
    }
    [self.refreshingFeedURLs addObject:url];

    BOOL notificationBefore = ([self.parserQueue operationCount] == 0);
    if (notificationBefore) {
        self.refreshedURL = feed.sourceURL;
        [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerWillParseFeedNotification object:self userInfo:@{@"url" : feed.sourceURL}];
    }
    
    BOOL needsDurationMetadataRefresh = [self _feedNeedsDurationMetadataRefresh:feed];
    ICFeedParser* feedParser = [ICFeedParser feedParser];
    if (etagHandling && !needsDurationMetadataRefresh) {
        feedParser.etag = feed.etag;
    }
    
    feedParser.url = [feed.sourceURL copy];
    feedParser.userInfo = url;
    feedParser.username = feed.username;
    feedParser.password = feed.password;
    feedParser.timeout = 8;
#if TARGET_OS_IPHONE
    feedParser.dontAskForCredentials = ([App applicationState] != UIApplicationStateActive);
    feedParser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
#endif
    __weak ICFeedParser* weakFeedParser = feedParser;
    __weak typeof(self) weakSelf = self;
    NSManagedObjectID* feedObjectID = feed.objectID;
    feedParser.didParseFeedBlock = ^(ICFeed* parsedFeed) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf.refreshingFeedURLs containsObject:url]) {
            return;
        }
        
        if (!notificationBefore) {
            strongSelf.refreshedURL = feed.sourceURL;
            [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerWillParseFeedNotification object:strongSelf userInfo:@{@"url" : url}];
        }

        [strongSelf.feedsMergingURLs addObject:url];

        [strongSelf.mergeQueue addOperationWithBlock:^{
            @autoreleasepool {
                NSManagedObjectContext* mergeContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
                mergeContext.parentContext = DMANAGER.objectContext;
                mergeContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
                mergeContext.undoManager = nil;

                __block NSMutableArray<NSManagedObjectID*>* newEpisodeObjectIDs = [NSMutableArray array];
                __block NSError* mergeError = nil;

                // Profiling for the reported multi-second freeze during pull-to-refresh:
                // the child context's fetches and save push run through the MAIN-queue
                // parent, so this duration is main-thread time even though the block
                // runs on the merge queue.
                CFAbsoluteTime mergeStartTime = CFAbsoluteTimeGetCurrent();

                [mergeContext performBlockAndWait:^{
                    NSError* feedFetchError = nil;
                    CDFeed* localFeed = (CDFeed*)[mergeContext existingObjectWithID:feedObjectID error:&feedFetchError];
                    if (![localFeed isKindOfClass:[CDFeed class]]) {
                        mergeError = feedFetchError ?: [NSError errorWithDomain:@"SubscriptionManager"
                                                                            code:1001
                                                                        userInfo:@{NSLocalizedDescriptionKey: @"Feed not found while merging refresh result.".ls}];
                        return;
                    }

                    if (parsedFeed) {
                        if (!etagHandling || needsDurationMetadataRefresh || ![localFeed.contentHash isEqual:parsedFeed.contentHash]) {
                            NSArray* newEpisodes = [strongSelf _mergeLocalFeed:localFeed withWithRemoteFeed:parsedFeed force:NO];
                            for (CDEpisode* episode in newEpisodes) {
                                if (episode.objectID) {
                                    [newEpisodeObjectIDs addObject:episode.objectID];
                                }
                            }
                        }

                        if (ICFeedValueDiffers(localFeed.contentHash, parsedFeed.contentHash)) {
                            localFeed.contentHash = parsedFeed.contentHash;
                        }
                        if (ICFeedValueDiffers(localFeed.etag, parsedFeed.etag)) {
                            localFeed.etag = parsedFeed.etag;
                        }
                    }

                    if (weakFeedParser.username && ![weakFeedParser.username isEqualToString:localFeed.username]) {
                        localFeed.username = weakFeedParser.username;
                    }
                    if (weakFeedParser.password && ![weakFeedParser.password isEqualToString:localFeed.password]) {
                        localFeed.password = weakFeedParser.password;
                    }
                    localFeed.lastUpdate = [NSDate date];

                    NSError* saveError = nil;
                    if (![mergeContext save:&saveError]) {
                        mergeError = saveError;
                    }
                }];

                CFTimeInterval mergeSeconds = CFAbsoluteTimeGetCurrent() - mergeStartTime;

                dispatch_async(dispatch_get_main_queue(), ^{
                    CFAbsoluteTime mainStartTime = CFAbsoluteTimeGetCurrent();
                    __strong typeof(weakSelf) strongSelfInner = weakSelf;
                    if (!strongSelfInner) {
                        return;
                    }

                    if (mergeError) {
                        [strongSelfInner.feedsMergingURLs removeObject:url];
                        if (![strongSelfInner.refreshingFeedURLs containsObject:url]) {
                            return;
                        }

                        ErrLog(@"error merging '%@': %@", feed.title, mergeError);
                        [strongSelfInner _markFeedFailedForURL:url timedOut:NO error:mergeError];
                        [strongSelfInner _finishParsingFeed:feed url:url shouldAutoDownload:NO];

                        if (completion) {
                            completion(NO, nil, mergeError);
                        }
                        return;
                    }

                    if (![strongSelfInner.refreshingFeedURLs containsObject:url]) {
                        [strongSelfInner.feedsMergingURLs removeObject:url];
                        return;
                    }

                    if (needsDurationMetadataRefresh) {
                        // The one full duration pass for this feed is done — from now on
                        // the etag cache works again (see _feedNeedsDurationMetadataRefresh).
                        [feed setBool:YES forKey:kFeedPropertyDurationRefreshAttempted];
                    }

                    NSMutableArray* allNewEpisodes = [NSMutableArray arrayWithCapacity:newEpisodeObjectIDs.count];
                    for (NSManagedObjectID* objectID in newEpisodeObjectIDs) {
                        CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext objectWithID:objectID];
                        if (episode) {
                            [allNewEpisodes addObject:episode];
                        }
                    }

                    strongSelfInner.numOfNewEpisodesAfterRefresh += [allNewEpisodes count];

                    if ([allNewEpisodes count] > 0) {
                        [strongSelfInner _postDidAddEpisodesNotification:allNewEpisodes];
                        if ([feed boolForKey:AutoDeleteNewsMode]) {
                            [strongSelfInner _recycleOldEpisodesInNewsModeFeed:feed];
                        }
                    }

                    [strongSelfInner _finishParsingFeed:feed url:url shouldAutoDownload:([allNewEpisodes count] > 0)];

                    CFTimeInterval mainSeconds = CFAbsoluteTimeGetCurrent() - mainStartTime;
                    if (mergeSeconds > 0.05 || mainSeconds > 0.05) {
                        [[ICDiagnosticLogger shared] logEvent:@"feed-refresh-profile"
                                                      message:@"Feed-Merge-Timing"
                                                     metadata:@{
                            @"feed": feed.title ?: @"",
                            @"mergeSeconds": [NSString stringWithFormat:@"%.3f", mergeSeconds],
                            @"mainSeconds": [NSString stringWithFormat:@"%.3f", mainSeconds],
                            @"newEpisodes": @(allNewEpisodes.count).stringValue,
                            @"remainingFeeds": @(strongSelfInner.refreshingFeedURLs.count).stringValue,
                        }];
                    }

                    if (completion) {
                        completion(YES, allNewEpisodes, nil);
                    }
                });
            }
        }];
    };
    
    feedParser.didEndWithError = ^(NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf.refreshingFeedURLs containsObject:url]) {
                return;
            }

            [strongSelf.feedsMergingURLs removeObject:url];

            if (completion) {
                completion(NO, nil, error);
            }

            if (!notificationBefore) {
                [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerWillParseFeedNotification object:strongSelf userInfo:@{@"url" : feed.sourceURL}];
            }

            ErrLog(@"error parsing '%@': %@", feed.title, [error description]);
            [strongSelf _markFeedFailedForURL:url timedOut:NO error:error];
            [strongSelf _finishRefreshingURL:url];
        });
    };

    [self.parserQueue addOperation:feedParser];
}

// Initial number of episodes inserted synchronously when hydrating a stub feed.
// Keep in sync with kInitialEpisodeLimit in DatabaseManager.m.
static const NSInteger kHydrationInitialEpisodeLimit = 50;

- (void) hydrateStubFeed:(CDFeed*)feed completion:(ICSubscriptionManagerRefreshCompletionBlock)completion
{
    if (!feed || !feed.sourceURL) {
        if (completion) {
            completion(NO, nil, nil);
        }
        return;
    }

    ICFeedParser* feedParser = [ICFeedParser feedParser];
    feedParser.url = [feed.sourceURL copy];
    feedParser.username = feed.username;
    feedParser.password = feed.password;
    feedParser.timeout = 8;
    // Hydration is silent low-priority background work — it must never prompt and
    // never compete with user-initiated network traffic.
    feedParser.qualityOfService = NSQualityOfServiceUtility;
    feedParser.dontAskForCredentials = YES;
#if TARGET_OS_IPHONE
    feedParser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
#endif

    NSManagedObjectID* feedObjectID = feed.objectID;
    __weak typeof(self) weakSelf = self;
    feedParser.didParseFeedBlock = ^(ICFeed* parsedFeed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !parsedFeed) {
                if (completion) {
                    completion(NO, nil, nil);
                }
                return;
            }

            CDFeed* localFeed = (CDFeed*)[DMANAGER.objectContext existingObjectWithID:feedObjectID error:NULL];
            if (![localFeed isKindOfClass:[CDFeed class]] || !localFeed.subscribed) {
                if (completion) {
                    completion(NO, nil, nil);
                }
                return;
            }

            [strongSelf updateLocalFeedInfo:localFeed withRemoteFeed:parsedFeed force:NO];
            if (ICFeedValueDiffers(localFeed.contentHash, parsedFeed.contentHash)) {
                localFeed.contentHash = parsedFeed.contentHash;
            }
            if (ICFeedValueDiffers(localFeed.etag, parsedFeed.etag)) {
                localFeed.etag = parsedFeed.etag;
            }

            // Categories are only ever created on subscribe — replicate that here, the
            // stub was created without them.
            if (localFeed.categories.count == 0 && parsedFeed.categories.count > 0) {
                NSMutableSet* categories = [[NSMutableSet alloc] init];
                for (ICCategory* parserCategory in parsedFeed.categories) {
                    CDCategory* category = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:DMANAGER.objectContext];
                    category.title = parserCategory.title;
                    if (parserCategory.parent) {
                        CDCategory* parentCategory = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:DMANAGER.objectContext];
                        parentCategory.title = parserCategory.parent.title;
                        category.parent = parentCategory;
                    }
                    [categories addObject:category];
                }
                localFeed.categories = categories;
            }

            NSArray* sortedEpisodes = [parsedFeed.episodes sortedArrayUsingDescriptors:
                @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO]]];
            NSInteger totalEpisodeCount = sortedEpisodes.count;
            NSInteger initialLoadCount = MIN(kHydrationInitialEpisodeLimit, totalEpisodeCount);
            if (initialLoadCount > 0) {
                [DMANAGER addParserEpisodes:[sortedEpisodes subarrayWithRange:NSMakeRange(0, initialLoadCount)]
                                     toFeed:localFeed
                               markConsumed:NO];
            }

            // Takes the feed out of the stub hydration queue.
            localFeed.lastUpdate = [NSDate date];

            BOOL hasPendingEpisodeLoad = (totalEpisodeCount > initialLoadCount);
            if (hasPendingEpisodeLoad) {
                [localFeed setBool:NO forKey:kFeedPropertyEpisodeLoadingComplete];
                [localFeed setInteger:totalEpisodeCount forKey:kFeedPropertyTotalExpectedEpisodes];
                [localFeed setInteger:initialLoadCount forKey:kFeedPropertyLoadedEpisodeCount];
            } else {
                [localFeed setBool:YES forKey:kFeedPropertyEpisodeLoadingComplete];
            }

            if (initialLoadCount > 0) {
                [strongSelf _retainPendingAutoDownloadFeedUIDs:@[localFeed.uid ?: @""]];
            }

            NSError* hydrationSaveError = [DMANAGER saveReturningError];
            if (hydrationSaveError) {
                if (completion) {
                    completion(NO, nil, hydrationSaveError);
                }
                return;
            }

            [strongSelf _autoDownloadEpisodesInFeedAsynchronously:localFeed];

            if (hasPendingEpisodeLoad) {
                [[EpisodeLoadingManager sharedManager] queuePendingEpisodesForFeed:localFeed
                                                                    parserEpisodes:sortedEpisodes
                                                                        startIndex:initialLoadCount];
            }

            if (completion) {
                completion(YES, @[], nil);
            }
        });
    };
    feedParser.didEndWithError = ^(NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(NO, nil, error);
            }
        });
    };

    [self.parserQueue addOperation:feedParser];
}


- (void)_cancelRefreshParserForURL:(NSURL*)url
{
    if (!url) {
        return;
    }

    for (NSOperation* operation in [self.parserQueue.operations copy]) {
        if (![operation isKindOfClass:[ICFeedParser class]]) {
            continue;
        }

        ICFeedParser* feedParser = (ICFeedParser*)operation;
        NSURL* parserURL = ([feedParser.userInfo isKindOfClass:[NSURL class]]) ? feedParser.userInfo : feedParser.url;
        if ([parserURL isEqual:url]) {
            [feedParser cancel];
        }
    }
}


- (void) checkRefreshOperationsTimer:(NSTimer*)timer
{
    if (self.refreshingFeedURLs.count > 0) {
        NSDate* now = [NSDate date];
        NSMutableArray<NSURL*>* timedOutURLs = [NSMutableArray array];
        for (NSURL* url in [self.refreshingFeedURLs copy]) {
            if ([self.feedsMergingURLs containsObject:url]) {
                continue;
            }

            NSDate* started = self.refreshFeedStartDates[url];
            if (!started) {
                self.refreshFeedStartDates[url] = now;
                continue;
            }
            NSTimeInterval elapsedForFeed = [now timeIntervalSinceDate:started];
            if (elapsedForFeed >= kPerFeedRefreshTimeout) {
                [timedOutURLs addObject:url];
            }
        }

        if (timedOutURLs.count > 0) {
            for (NSURL* url in timedOutURLs) {
                [self _markFeedFailedForURL:url timedOut:YES error:nil];
                [self _cancelRefreshParserForURL:url];
                [self _finishRefreshingURL:url];
            }
        }
    }

    // Safety timeout: force-finish after 30 seconds for feeds still doing network work.
    NSTimeInterval elapsed = -[self.refreshStartDate timeIntervalSinceNow];
    if (elapsed > 30.0 && [self.refreshingFeedURLs count] > 0) {
        NSMutableArray<NSURL*>* timedOutNetworkURLs = [NSMutableArray array];
        for (NSURL* url in [self.refreshingFeedURLs copy]) {
            if (![self.feedsMergingURLs containsObject:url]) {
                [timedOutNetworkURLs addObject:url];
            }
        }

        for (NSURL* url in timedOutNetworkURLs) {
            [self _markFeedFailedForURL:url timedOut:YES error:nil];
            [self _finishRefreshingURL:url];
        }

        if (timedOutNetworkURLs.count > 0) {
            [self.parserQueue cancelAllOperations];
        }
    }

	if ([self.refreshingFeedURLs count] == 0)
	{
        if (self.refreshFailedFeedTitles.count == 1) {
            self.lastRefreshFailedFeedName = self.refreshFailedFeedTitles.firstObject;
            self.finalRefreshStatusText = self.lastRefreshFailedFeedName;
        } else {
            self.lastRefreshFailedFeedName = nil;
            self.finalRefreshStatusText = nil;
        }

        [self.refreshCheckTimer invalidate];
		self.refreshCheckTimer = nil;
        
        
        // Persist the child-context merges before a sibling background context scans
        // the feed for auto-download candidates.
        [self _retainPendingAutoDownloadFeedObjectIDs:self.pendingAutoDownloadFeedObjectIDs.allObjects];
        NSError* refreshSaveError = [DMANAGER saveReturningError];
        if (!refreshSaveError) {
            [self _startPendingAutoDownloads];
            [[CacheManager sharedCacheManager] retryFailedAutomaticDownloadsIfPossible];
        } else {
            [[ICDiagnosticLogger shared] logEvent:@"feed-refresh"
                                          message:@"Neue Episoden konnten nicht für Auto-Download gespeichert werden"
                                         metadata:@{ @"error": refreshSaveError.localizedDescription ?: @"" }];
        }
        
        // update application badge
#if TARGET_OS_IPHONE
        [[UNUserNotificationCenter currentNotificationCenter] setBadgeCount:([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0 withCompletionHandler:nil];
#endif

		[App releaseNetworkActivity];
		
		if (self.numOfNewEpisodesAfterRefresh > 0) {
			PlaySoundFile(@"NewEpisodes",NO);
		} else {
			PlaySoundFile(@"Pop",NO);
		}
        

#if TARGET_OS_IPHONE
        BOOL notificationEnabled = [USER_DEFAULTS boolForKey:EnableManualRefreshFinishedNotification];

        if (notificationEnabled && self.backgroundIdentifier != UIBackgroundTaskInvalid && App.applicationState == UIApplicationStateBackground)
        {
            // UILocalNotification is deprecated but kept for stability
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            UILocalNotification* finishedNotification = [[UILocalNotification alloc] init];
            if (self.numOfNewEpisodesAfterRefresh > 1) {
                finishedNotification.alertBody = [NSString stringWithFormat:@"Refreshing finished and %d new episodes are available.".ls, self.numOfNewEpisodesAfterRefresh];
            }
            else if (self.numOfNewEpisodesAfterRefresh == 1) {
                finishedNotification.alertBody = @"Refreshing finished and a new episode is available.".ls;
            }
            else {
                finishedNotification.alertBody = @"Refreshing finished and there are no new episodes available.".ls;
            }

            [[UNUserNotificationCenter currentNotificationCenter] setBadgeCount:([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0 withCompletionHandler:nil];
            [App presentLocalNotificationNow:finishedNotification];
#pragma clang diagnostic pop
        }
#endif

 
 
#if TARGET_OS_IPHONE
        [self perform:^(id sender) {
            if (self.backgroundIdentifier != UIBackgroundTaskInvalid) {
                [App endBackgroundTask:self.backgroundIdentifier];
                self.backgroundIdentifier = UIBackgroundTaskInvalid;
            }
        } afterDelay:1.0f];
#endif
		
        [self willChangeValueForKey:@"formattedLastRefreshDate"];
		[USER_DEFAULTS setDouble:[[NSDate date] timeIntervalSince1970] forKey:LastRefreshSubscriptionDate];
        [self didChangeValueForKey:@"formattedLastRefreshDate"];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidFinishRefreshingFeedsNotification object:self];
	}
}

- (void)_postDidAddEpisodesNotification:(NSArray<CDEpisode*>*)newEpisodes
{
    NSArray* episodes = newEpisodes ?: @[];
    [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidAddEpisodesNotification
                                                        object:self
                                                      userInfo:@{@"episodes" : episodes}];
}

- (void)_copyFeedValuesFrom:(ICFeed*)parserFeed toPersistentFeed:(CDFeed*)persistentFeed
{
    persistentFeed.title = parserFeed.title;
    persistentFeed.subtitle = parserFeed.subtitle;
    persistentFeed.sourceURL = parserFeed.sourceURL;
    persistentFeed.imageURL = parserFeed.imageURL;
    persistentFeed.pubDate = parserFeed.pubDate;
    persistentFeed.lastUpdate = parserFeed.lastUpdate;
    persistentFeed.video = parserFeed.video;
    persistentFeed.completed = parserFeed.completed;
    persistentFeed.linkURL = parserFeed.linkURL;
    persistentFeed.language = parserFeed.language;
    persistentFeed.country = parserFeed.country;
    persistentFeed.summary = parserFeed.summary;
    persistentFeed.fulltext = parserFeed.textDescription;
    persistentFeed.author = parserFeed.author;
    persistentFeed.copyright = parserFeed.copyright;
    persistentFeed.owner = parserFeed.owner;
    persistentFeed.ownerEmail = parserFeed.ownerEmail;
    persistentFeed.explicitContent = parserFeed.explicitContent;
    persistentFeed.paymentURL = parserFeed.paymentURL;
    persistentFeed.username = parserFeed.username;
    persistentFeed.password = parserFeed.password;
    persistentFeed.etag = parserFeed.etag;
    persistentFeed.contentHash = parserFeed.contentHash;
}

- (void)_copyEpisodeValuesFrom:(ICEpisode*)parserEpisode toPersistentEpisode:(CDEpisode*)persistentEpisode
{
    persistentEpisode.objectHash = parserEpisode.objectHash;
    persistentEpisode.title = parserEpisode.title;
    persistentEpisode.subtitle = parserEpisode.subtitle;
    persistentEpisode.guid = parserEpisode.guid;
    persistentEpisode.pubDate = parserEpisode.pubDate;
    persistentEpisode.imageURL = parserEpisode.imageURL;
    persistentEpisode.linkURL = parserEpisode.link;
    persistentEpisode.author = parserEpisode.author;
    persistentEpisode.summary = parserEpisode.summary;
    persistentEpisode.fulltext = parserEpisode.textDescription;
    persistentEpisode.transcripts = parserEpisode.transcripts;
    persistentEpisode.paymentURL = parserEpisode.paymentURL;
    persistentEpisode.deeplinkURL = parserEpisode.deeplink;
    persistentEpisode.video = parserEpisode.video;
    persistentEpisode.explicitContent = parserEpisode.explicitContent;
    persistentEpisode.duration = (int32_t)parserEpisode.duration;
}

- (void)_copyMediumValuesFrom:(ICMedia*)parserMedium toPersistentMedium:(CDMedium*)persistentMedium
{
    persistentMedium.fileURL = parserMedium.fileURL;
    persistentMedium.byteSize = parserMedium.byteSize;
    persistentMedium.mimeType = parserMedium.mimeType;
}

- (CDEpisode*)_addNewParserEpisode:(ICEpisode*)parserEpisode
                            toFeed:(CDFeed*)feed
                         inContext:(NSManagedObjectContext*)context
                            wasNew:(BOOL*)wasNew
{
    if (wasNew) {
        *wasNew = NO;
    }
    if (!parserEpisode || !feed || !context) {
        return nil;
    }

    CDEpisode* persistentEpisode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode"
                                                                   inManagedObjectContext:context];
    [self _copyEpisodeValuesFrom:parserEpisode toPersistentEpisode:persistentEpisode];

    NSMutableSet* media = [[NSMutableSet alloc] init];
    for (ICMedia* parserMedia in parserEpisode.media) {
        if (parserMedia.fileURL) {
            CDMedium* persistentMedium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium"
                                                                         inManagedObjectContext:context];
            [self _copyMediumValuesFrom:parserMedia toPersistentMedium:persistentMedium];
            [media addObject:persistentMedium];
        }
    }
    persistentEpisode.media = media;
    [feed addEpisodesObject:persistentEpisode];

    if (wasNew) {
        *wasNew = YES;
    }
    return persistentEpisode;
}

- (BOOL)_episodeHasLocalStateWorthPreserving:(CDEpisode*)episode
{
    if (!episode) return NO;
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    PlaybackManager* playbackManager = [PlaybackManager playbackManager];
    BOOL isPlaying = episode.objectHash.length > 0 &&
        [playbackManager.playingEpisode.objectHash isEqualToString:episode.objectHash];
    return isPlaying ||
        [cacheManager episodeIsCached:episode] ||
        [cacheManager isCachingEpisode:episode] ||
        [cacheManager downloadErrorForEpisode:episode] != nil ||
        episode.starred ||
        episode.position > 0;
}

- (BOOL)_shouldPreferEpisode:(CDEpisode*)candidate overEpisode:(CDEpisode*)current
{
    if (!current) return YES;
    BOOL candidateHasLocalState = [self _episodeHasLocalStateWorthPreserving:candidate];
    BOOL currentHasLocalState = [self _episodeHasLocalStateWorthPreserving:current];
    if (candidateHasLocalState != currentHasLocalState) {
        return candidateHasLocalState;
    }
    if (candidate.pubDate && !current.pubDate) return YES;
    if (!candidate.pubDate && current.pubDate) return NO;
    NSComparisonResult dateComparison = [candidate.pubDate compare:current.pubDate];
    if (dateComparison != NSOrderedSame) {
        return dateComparison == NSOrderedDescending;
    }
    return [candidate.objectHash ?: @"" compare:current.objectHash ?: @""] == NSOrderedAscending;
}

- (void) updateLocalFeedInfo:(CDFeed*)localFeed withRemoteFeed:(ICFeed*)remoteFeed force:(BOOL)force
{
    if (!force)
    {
        if (remoteFeed.changedSourceURL) {
            // Don't override sourceURL for feeds with credentials — the redirect
            // target is typically the public feed URL without auth path
            if (!localFeed.username || localFeed.username.length == 0) {
                localFeed.sourceURL = remoteFeed.changedSourceURL;
            }
        }
        if (ICFeedValueDiffers(localFeed.etag, remoteFeed.etag)) {
            localFeed.etag = remoteFeed.etag;
        }
        if (ICFeedValueDiffers(localFeed.title, remoteFeed.title)) {
            localFeed.title = remoteFeed.title;
        }
        if (ICFeedValueDiffers(localFeed.linkURL, remoteFeed.linkURL)) {
            localFeed.linkURL = remoteFeed.linkURL;
        }
        if (ICFeedValueDiffers(localFeed.paymentURL, remoteFeed.paymentURL)) {
            localFeed.paymentURL = remoteFeed.paymentURL;
        }
        if (ICFeedValueDiffers(localFeed.imageURL, remoteFeed.imageURL)) {
            localFeed.imageURL = remoteFeed.imageURL;
        }

        NSMutableDictionary* localEpisodeIndex = [NSMutableDictionary dictionary];
        for(CDEpisode* episode in localFeed.episodes) {
            if (episode.guid) {
                CDEpisode* canonicalEpisode = localEpisodeIndex[episode.guid];
                if ([self _shouldPreferEpisode:episode overEpisode:canonicalEpisode]) {
                    localEpisodeIndex[episode.guid] = episode;
                }
            }
        }

        for(ICEpisode* remoteEpisode in remoteFeed.episodes)
        {
            if (!remoteEpisode.guid) {
                continue;
            }
            
            CDEpisode* localEpisode = localEpisodeIndex[remoteEpisode.guid];
            NSInteger remoteDuration = remoteEpisode.duration;
            if (remoteDuration > 0 && localEpisode.duration != (int32_t)remoteDuration) {
                localEpisode.duration = (int32_t)remoteDuration;
            }
            BOOL newer = ([remoteEpisode.pubDate timeIntervalSince1970] > [localEpisode.pubDate timeIntervalSince1970]);

            if (newer) {
                // Diff-gate every write: Core Data marks the episode as updated even when the
                // value is identical, and each dirtied episode fires the whole observer cascade
                // (FRC reloads, widget export, Spotlight/FTS re-index) after the merge push.
                if (!localEpisode.fulltext || ![localEpisode.fulltext isEqualToString:remoteEpisode.textDescription]) {
                    localEpisode.fulltext = remoteEpisode.textDescription;
                }
                if (!localEpisode.imageURL || ![localEpisode.imageURL isEqual:remoteEpisode.imageURL]) {
                    localEpisode.imageURL = remoteEpisode.imageURL;
                }
                localEpisode.pubDate = remoteEpisode.pubDate;

                NSArray* localTranscripts = localEpisode.transcripts ?: @[];
                NSArray* remoteTranscripts = remoteEpisode.transcripts ?: @[];
                if (![localTranscripts isEqualToArray:remoteTranscripts]) {
                    localEpisode.transcripts = remoteTranscripts;
                }
            }
            else {
                if (!localEpisode.fulltext || ![localEpisode.fulltext isEqualToString:remoteEpisode.textDescription]) {
                    localEpisode.fulltext = remoteEpisode.textDescription;
                }
                
                if (!localEpisode.imageURL || ![localEpisode.imageURL isEqual:remoteEpisode.imageURL]) {
                    localEpisode.imageURL = remoteEpisode.imageURL;
                }

                NSArray* localTranscripts = localEpisode.transcripts ?: @[];
                NSArray* remoteTranscripts = remoteEpisode.transcripts ?: @[];
                if (![localTranscripts isEqualToArray:remoteTranscripts]) {
                    localEpisode.transcripts = remoteTranscripts;
                }
            }
        }
    }
    
    else
    {
        NSManagedObjectContext* context = localFeed.managedObjectContext;
        [self _copyFeedValuesFrom:remoteFeed toPersistentFeed:localFeed];
        
        NSMutableDictionary* localEpisodeIndex = [NSMutableDictionary dictionary];
        for(CDEpisode* episode in localFeed.episodes) {
            if (episode.guid) {
                localEpisodeIndex[episode.guid] = episode;
            }
        }
        
        for(ICEpisode* episode in remoteFeed.episodes)
        {
            if (!episode.guid) {
                continue;
            }

            CDEpisode* localEpisode = localEpisodeIndex[episode.guid];
            if (!localEpisode) {
                continue;
            }
            [self _copyEpisodeValuesFrom:episode toPersistentEpisode:localEpisode];
            
            
            NSArray* localMedia = [localEpisode.media allObjects];
            [episode.media enumerateObjectsUsingBlock:^(ICMedia* remoteMedium, NSUInteger idx, BOOL *stop) 
            {
                // dont add mediums without file URL, because medium depends on it for syncing
                if (!remoteMedium.fileURL) {
                    return;
                }

                if ([localMedia count] > idx) {
                    CDMedium* localMedium = localMedia[idx];
                    [self _copyMediumValuesFrom:remoteMedium toPersistentMedium:localMedium];
                }
                else
                {
                    CDMedium* persistentMedium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium"
                                                                                inManagedObjectContext:context];
                    [self _copyMediumValuesFrom:remoteMedium toPersistentMedium:persistentMedium];
                    [[localEpisode mutableSetValueForKey:@"media"] addObject:persistentMedium];
                }
            }];
        }
        
        NSMutableArray<CDEpisode*>* duplicateEpisodes = [NSMutableArray array];
        for (CDEpisode* episode in [localFeed.episodes copy]) {
            CDEpisode* canonicalEpisode = episode.guid ? localEpisodeIndex[episode.guid] : nil;
            if (canonicalEpisode && ![canonicalEpisode isEqual:episode]) {
                [duplicateEpisodes addObject:episode];
            }
        }
        if (duplicateEpisodes.count > 0) {
            [DMANAGER deleteEpisodes:duplicateEpisodes completion:nil];
        }
    }
}

- (NSArray*) _mergeLocalFeed:(CDFeed*)localFeed withWithRemoteFeed:(ICFeed*)remoteFeed force:(BOOL)force
{
    NSManagedObjectContext* context = localFeed.managedObjectContext;
    NSSet* localEpisodes = localFeed.episodes;
    NSMutableDictionary<NSString*, CDEpisode*>* localEpisodesByGUID = [NSMutableDictionary dictionaryWithCapacity:localEpisodes.count];
    NSMutableDictionary<NSString*, CDEpisode*>* localEpisodesByObjectHash = [NSMutableDictionary dictionaryWithCapacity:localEpisodes.count];
    NSDate* newestLocalEpisodeDate = nil;

    for(CDEpisode* episode in localEpisodes) {
        if (episode.guid && !localEpisodesByGUID[episode.guid]) {
            localEpisodesByGUID[episode.guid] = episode;
        }
        if (episode.objectHash && !localEpisodesByObjectHash[episode.objectHash]) {
            localEpisodesByObjectHash[episode.objectHash] = episode;
        }
        if (episode.pubDate && (!newestLocalEpisodeDate || [episode.pubDate compare:newestLocalEpisodeDate] == NSOrderedDescending)) {
            newestLocalEpisodeDate = episode.pubDate;
        }
    }
    
	// merge new entries
	NSArray* remoteEpisodes = [remoteFeed.episodes sortedArrayUsingDescriptors:@[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:YES] ]];
	
    NSMutableArray* newEpisodes = [[NSMutableArray alloc] init];
	for (ICEpisode* remoteEpisode in remoteEpisodes)
	{
        if (!remoteEpisode.guid) {
            continue;
        }

        CDEpisode* localEpisode = localEpisodesByGUID[remoteEpisode.guid];
        if (!localEpisode && remoteEpisode.objectHash) {
            localEpisode = localEpisodesByObjectHash[remoteEpisode.objectHash];
        }

        // Episode exists locally — check if it's a stub from backup import (no title)
        if (localEpisode) {
            if (!localEpisode.title || localEpisode.title.length == 0) {
                // Stub episode from backup import — fill in metadata, preserve status
                [self _copyEpisodeValuesFrom:remoteEpisode toPersistentEpisode:localEpisode];
                // Create media objects
                NSMutableSet *media = [[NSMutableSet alloc] init];
                for (ICMedia *parserMedia in remoteEpisode.media) {
                    if (parserMedia.fileURL) {
                        CDMedium *medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium"
                                                                        inManagedObjectContext:context];
                        [self _copyMediumValuesFrom:parserMedia toPersistentMedium:medium];
                        [media addObject:medium];
                    }
                }
                localEpisode.media = media;
            }
            continue;
        }

        // local episode does not exist
		{
            // make persistent
            BOOL wasNew;
            CDEpisode* newPersistentEpisode = [self _addNewParserEpisode:remoteEpisode
                                                                  toFeed:localFeed
                                                               inContext:context
                                                                  wasNew:&wasNew];
            if (!newPersistentEpisode) {
                continue;
            }

            localEpisodesByGUID[remoteEpisode.guid] = newPersistentEpisode;
            if (newPersistentEpisode.objectHash) {
                localEpisodesByObjectHash[newPersistentEpisode.objectHash] = newPersistentEpisode;
            }
            
            // only mark those episodes as unplayed that are newer than the latest episodes we already got
            NSTimeInterval newEpisodeTimeInterval = [newPersistentEpisode.pubDate timeIntervalSince1970];
            NSTimeInterval formerEpisodeTimeInterval = [newestLocalEpisodeDate timeIntervalSince1970];
            if (wasNew && newEpisodeTimeInterval > formerEpisodeTimeInterval) {
                newPersistentEpisode.consumed = NO;
            }

            [newEpisodes addObject:newPersistentEpisode];

#if !TARGET_OS_IPHONE
            NSUserNotification* finishedNotification = [[NSUserNotification alloc] init];
            finishedNotification.title = @"New episode available in Instacast.".ls;
            finishedNotification.subtitle = [NSString stringWithFormat:@"%@ - %@", localFeed.title, [newPersistentEpisode cleanTitleUsingFeedTitle:localFeed.title]];
            [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:finishedNotification];
#endif
		}
	}

    [self updateLocalFeedInfo:localFeed withRemoteFeed:remoteFeed force:force];
    
    return newEpisodes;
}

- (void) _deleteUnavailableEpisodesFromFeed:(CDFeed*)localFeed withRemoteFeed:(ICFeed*)remoteFeed
{
    NSMutableSet* episodeGuids = [[NSMutableSet alloc] init];
    
    for(ICEpisode* episode in remoteFeed.episodes) {
        if (episode.guid) {
            [episodeGuids addObject:episode.guid];
        }
    }
    
    NSMutableArray<CDEpisode*>* unavailableEpisodes = [NSMutableArray array];
    for(CDEpisode* episode in [localFeed.episodes copy]) {
        if (![episodeGuids containsObject:episode.guid]) {
            [unavailableEpisodes addObject:episode];
        }
    }
    if (unavailableEpisodes.count > 0) {
        [DMANAGER deleteEpisodes:unavailableEpisodes completion:nil];
    }
}


- (void) _enforceKeepNewestLimitForFeed:(CDFeed*)feed
{
    NSInteger keepCount = [feed integerForKey:KeepNewestEpisodesCount];
    if (keepCount <= 0) return;

    // Alle heruntergeladenen Episoden dieses Feeds filtern
    CacheManager *cman = [CacheManager sharedCacheManager];
    NSArray *allCachedEpisodes = [cman cachedEpisodes];

    NSMutableArray *feedCachedEpisodes = [NSMutableArray array];
    for (CDEpisode *episode in allCachedEpisodes) {
        if ([episode.feed isEqual:feed]) {
            [feedCachedEpisodes addObject:episode];
        }
    }

    // Nach pubDate sortieren (neueste zuerst)
    [feedCachedEpisodes sortUsingDescriptors:@[
        [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO]
    ]];

    // Alles über dem Limit löschen (starred überspringen)
    if ((NSInteger)feedCachedEpisodes.count > keepCount) {
        for (NSInteger i = keepCount; i < (NSInteger)feedCachedEpisodes.count; i++) {
            CDEpisode *episode = feedCachedEpisodes[i];
            if (!episode.starred) {
                [cman removeCacheForEpisode:episode automatic:YES];
            }
        }
    }
}

- (void) _recycleOldEpisodesInNewsModeFeed:(CDFeed*)feed
{
    NSArray* sortedEpisodes = [feed.episodes sortedArrayUsingDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO]]];
    NSDate* firstPubDate = [[sortedEpisodes firstObject] pubDate];
    
    if (!firstPubDate) {
        return;
    }
    
    NSDateComponents* firstComps = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear | NSCalendarUnitMonth |  NSCalendarUnitDay)
                                                              fromDate:firstPubDate];
    
    for (CDEpisode* episode in sortedEpisodes)
    {
        NSDate* pubDate = episode.pubDate;
        
        NSDateComponents* comps = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear | NSCalendarUnitMonth |  NSCalendarUnitDay)
                                                                      fromDate:pubDate];
        
        if ([comps day] != [firstComps day] || [comps month] != [firstComps month] || [comps year] != [firstComps year])
        {
            // is old episode
            [DMANAGER markEpisode:episode asConsumed:YES];
            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:YES];
        }
        else
        {
            // is new episode
            [DMANAGER markEpisode:episode asConsumed:NO];
        }
    }
}

#pragma mark -


- (void) autoDownloadAllFeedsAsynchronously
{
    NSMutableArray<NSString*>* pendingFeedUIDs = [[NSMutableArray alloc] init];
    for (CDFeed* feed in DMANAGER.visibleFeeds) {
        if (feed.subscribed && !feed.parked && !feed.objectID.isTemporaryID) {
            [self.pendingAutoDownloadFeedObjectIDs addObject:feed.objectID];
            if (feed.uid.length > 0) {
                [pendingFeedUIDs addObject:feed.uid];
            }
        }
    }
    [self _retainPendingAutoDownloadFeedUIDs:pendingFeedUIDs];
    [self _startPendingAutoDownloads];
}

- (void)_autoDownloadEpisodesInFeedAsynchronously:(CDFeed*)feed
{
    if (feed) {
        if (feed.parked || !feed.subscribed) {
            [self.pendingAutoDownloadFeedObjectIDs removeObject:feed.objectID];
            [self _removePendingAutoDownloadFeedUIDs:@[feed.uid ?: @""]];
            return;
        }
        if (feed.objectID.isTemporaryID) {
            return;
        }
        [self _retainPendingAutoDownloadFeedUIDs:@[feed.uid ?: @""]];
        [self.pendingAutoDownloadFeedObjectIDs addObject:feed.objectID];
    }

    if (self.unsubscribeCleanupRecoveryBlocked) {
        return;
    }

    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    if (!cacheManager.isReadyForAutomaticDownloads) {
        return;
    }

    NSMutableSet<NSManagedObjectID*>* eligibleFeedObjectIDs = [self.pendingAutoDownloadFeedObjectIDs mutableCopy];
    for (NSManagedObjectID* feedObjectID in [eligibleFeedObjectIDs copy]) {
        if ([self _autoDownloadsBlockedDuringUnsubscribeCleanupForFeedObjectID:feedObjectID]) {
            [eligibleFeedObjectIDs removeObject:feedObjectID];
        }
    }
    if (self.autoDownloadFeedScanInFlight || eligibleFeedObjectIDs.count == 0) {
        return;
    }

    NSArray<NSManagedObjectID*>* pendingFeedObjectIDs = eligibleFeedObjectIDs.allObjects;
    NSUInteger feedBatchCount = MIN(pendingFeedObjectIDs.count, ICAutoDownloadFeedScanBatchSize);
    NSArray<NSManagedObjectID*>* feedObjectIDs = [pendingFeedObjectIDs subarrayWithRange:NSMakeRange(0, feedBatchCount)];
    NSMutableDictionary<NSManagedObjectID*, NSString*>* feedUIDsByObjectID = [[NSMutableDictionary alloc] initWithCapacity:feedObjectIDs.count];
    for (NSManagedObjectID* feedObjectID in feedObjectIDs) {
        NSError* feedError = nil;
        CDFeed* selectedFeed = (CDFeed*)[DMANAGER.objectContext existingObjectWithID:feedObjectID error:&feedError];
        if ([selectedFeed isKindOfClass:[CDFeed class]] && !feedError && !selectedFeed.isDeleted && selectedFeed.uid.length > 0) {
            feedUIDsByObjectID[feedObjectID] = selectedFeed.uid;
        }
    }
    [self.pendingAutoDownloadFeedObjectIDs minusSet:[NSSet setWithArray:feedObjectIDs]];
    self.autoDownloadFeedScanInFlight = YES;

    dispatch_async(self.autoDownloadFeedScanQueue, ^{
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        __block NSArray<NSDictionary*>* candidateItems = nil;
        __block NSError* scanError = nil;
        if (context) {
            [context performBlockAndWait:^{
                candidateItems = ICAutoDownloadCandidatesForFeedObjectIDs(context, feedObjectIDs, &scanError);
                [context reset];
            }];
        } else {
            scanError = [NSError errorWithDomain:@"SubscriptionManagerAutoDownload"
                                            code:1
                                        userInfo:@{NSLocalizedDescriptionKey: @"The podcast database is not available."}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (scanError) {
                [self.pendingAutoDownloadFeedObjectIDs addObjectsFromArray:feedObjectIDs];
                self.autoDownloadFeedScanInFlight = NO;
                ErrLog(@"error scanning auto-download candidates: %@", scanError);
                return;
            }

            __block NSUInteger candidateIndex = 0;
            __block void (^deliverNextCandidateBatch)(void) = nil;
            deliverNextCandidateBatch = ^{
                if (self.unsubscribeCleanupRecoveryBlocked) {
                    [self.pendingAutoDownloadFeedObjectIDs addObjectsFromArray:feedObjectIDs];
                    self.autoDownloadFeedScanInFlight = NO;
                    deliverNextCandidateBatch = nil;
                    return;
                }
                NSUInteger remainingCount = candidateItems.count - candidateIndex;
                NSUInteger candidateBatchCount = MIN(remainingCount, ICAutoDownloadCandidateDeliveryBatchSize);
                NSRange candidateRange = NSMakeRange(candidateIndex, candidateBatchCount);
                NSArray<NSDictionary*>* candidateBatch = [candidateItems subarrayWithRange:candidateRange];
                NSMutableDictionary<NSManagedObjectID*, NSMutableArray<CDEpisode*>*>* episodesByFeedObjectID = [[NSMutableDictionary alloc] init];

                for (NSDictionary* candidate in candidateBatch) {
                    NSManagedObjectID* feedObjectID = candidate[ICAutoDownloadCandidateFeedObjectIDKey];
                    NSError* currentFeedError = nil;
                    CDFeed* currentFeed = (CDFeed*)[DMANAGER.objectContext existingObjectWithID:feedObjectID error:&currentFeedError];
                    if (![currentFeed isKindOfClass:[CDFeed class]] || currentFeedError || currentFeed.isDeleted ||
                        [self automaticDownloadsBlockedDuringUnsubscribeCleanupForFeed:currentFeed]) {
                        continue;
                    }

                    NSManagedObjectID* episodeObjectID = candidate[ICAutoDownloadCandidateEpisodeObjectIDKey];
                    NSError* episodeError = nil;
                    CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:episodeObjectID error:&episodeError];
                    if (![episode isKindOfClass:[CDEpisode class]] || episodeError || episode.isDeleted ||
                        ![episode.feed isEqual:currentFeed]) {
                        continue;
                    }

                    NSMutableArray<CDEpisode*>* episodes = episodesByFeedObjectID[feedObjectID];
                    if (!episodes) {
                        episodes = [[NSMutableArray alloc] init];
                        episodesByFeedObjectID[feedObjectID] = episodes;
                    }
                    [episodes addObject:episode];
                }

                for (NSManagedObjectID* feedObjectID in episodesByFeedObjectID) {
                    NSMutableArray<CDEpisode*>* thisSortedEpisodes = episodesByFeedObjectID[feedObjectID];
                    [self _autoDownloadEpisode:nil sortedEpisodes:thisSortedEpisodes];
                }

                candidateIndex += candidateBatchCount;
                if (candidateIndex < candidateItems.count) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        deliverNextCandidateBatch();
                    });
                } else {
                    NSMutableArray<NSString*>* completedFeedUIDs = [[NSMutableArray alloc] initWithCapacity:feedUIDsByObjectID.count];
                    for (NSManagedObjectID* feedObjectID in feedObjectIDs) {
                        if ([self _autoDownloadsBlockedDuringUnsubscribeCleanupForFeedObjectID:feedObjectID]) {
                            [self.pendingAutoDownloadFeedObjectIDs addObject:feedObjectID];
                            continue;
                        }
                        // A second refresh can enqueue the same feed while this scan is
                        // delivering. Keep its durable marker for that newer handoff.
                        if (![self.pendingAutoDownloadFeedObjectIDs containsObject:feedObjectID]) {
                            NSString* feedUID = feedUIDsByObjectID[feedObjectID];
                            if (feedUID.length > 0) {
                                [completedFeedUIDs addObject:feedUID];
                            }
                        }
                    }
                    [self _removePendingAutoDownloadFeedUIDs:completedFeedUIDs];
                    self.autoDownloadFeedScanInFlight = NO;
                    deliverNextCandidateBatch = nil;
                    [self _startPendingAutoDownloads];
                    [self recoverPendingAutoDownloadsAfterDatabaseStartup];
                }
            };
            deliverNextCandidateBatch();
        });
    });
}

- (void)recoverPendingAutoDownloadsAfterDatabaseStartup
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recoverPendingAutoDownloadsAfterDatabaseStartup];
        });
        return;
    }

    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    if (!cacheManager.isReadyForAutomaticDownloads || self.autoDownloadFeedScanInFlight) {
        return;
    }
    if (self.pendingAutoDownloadFeedObjectIDs.count > 0) {
        [self _startPendingAutoDownloads];
        return;
    }

    NSArray<NSString*>* pendingFeedUIDs = [self _pendingAutoDownloadFeedUIDs];
    if (pendingFeedUIDs.count == 0) {
        return;
    }
    NSUInteger recoveryBatchCount = MIN(pendingFeedUIDs.count, ICAutoDownloadFeedScanBatchSize);
    NSArray<NSString*>* recoveryFeedUIDs = [pendingFeedUIDs subarrayWithRange:NSMakeRange(0, recoveryBatchCount)];

    NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
    request.includesSubentities = NO;
    request.fetchLimit = 1;
    NSMutableArray<NSString*>* staleFeedUIDs = [[NSMutableArray alloc] init];
    BOOL recoveryFetchFailed = NO;
    for (NSString* feedUID in recoveryFeedUIDs) {
        request.predicate = [NSPredicate predicateWithFormat:@"uid == %@ AND subscribed == YES AND parked == NO", feedUID];
        NSError* fetchError = nil;
        NSArray<CDFeed*>* matchingFeeds = [DMANAGER.objectContext executeFetchRequest:request error:&fetchError];
        if (!matchingFeeds) {
            recoveryFetchFailed = YES;
            ErrLog(@"error recovering pending auto-download feed '%@': %@", feedUID, fetchError);
            continue;
        }
        CDFeed* feed = matchingFeeds.firstObject;
        if (![feed isKindOfClass:[CDFeed class]] || !feed.subscribed || feed.parked || feed.objectID.isTemporaryID) {
            [staleFeedUIDs addObject:feedUID];
            continue;
        }
        [self.pendingAutoDownloadFeedObjectIDs addObject:feed.objectID];
    }

    [self _removePendingAutoDownloadFeedUIDs:staleFeedUIDs];

    if (self.pendingAutoDownloadFeedObjectIDs.count > 0) {
        [self _startPendingAutoDownloads];
    } else if (!recoveryFetchFailed && [self _pendingAutoDownloadFeedUIDs].count > 0) {
        // Yield between bounded stale batches as well; thousands of removed feeds must
        // never become one main-thread cleanup pass.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self recoverPendingAutoDownloadsAfterDatabaseStartup];
        });
    }
}

- (void) autoDownloadEpisodesInFeedAsynchronously:(CDFeed*)feed
{
    [self _autoDownloadEpisodesInFeedAsynchronously:feed];
}

- (BOOL) autoDownloadEpisodesInFeed:(CDFeed*)feed
{
    return [self _autoDownloadEpisode:nil inFeed:feed];
}

- (BOOL) autoDownloadEpisode:(CDEpisode*)episode
{
    return [self _autoDownloadEpisode:episode inFeed:episode.feed];
}

- (BOOL) _autoDownloadEpisode:(CDEpisode*)pickedEpisode inFeed:(CDFeed*)feed
{
    if (feed.parked || !feed.subscribed) {
        return NO;
    }
    if ([self automaticDownloadsBlockedDuringUnsubscribeCleanupForFeed:feed]) {
        if (feed.objectID && !feed.objectID.isTemporaryID) {
            [self _retainPendingAutoDownloadFeedUIDs:@[feed.uid ?: @""]];
            [self.pendingAutoDownloadFeedObjectIDs addObject:feed.objectID];
        }
        return NO;
    }
    
    NSArray* sortedEpisodes = [feed chronologicallySortedEpisodes];
    return [self _autoDownloadEpisode:pickedEpisode sortedEpisodes:sortedEpisodes];
}

- (BOOL) _autoDownloadEpisode:(CDEpisode*)pickedEpisode sortedEpisodes:(NSArray*)sortedEpisodes
{
    BOOL caching = NO;
    BOOL onlyMostRecent = YES;
    
    CacheManager* cman = [CacheManager sharedCacheManager];
    
    NSDate* firstPubDate = [[sortedEpisodes firstObject] pubDate];
    
    if (!firstPubDate) {
        return NO;
    }
    
    NSDateComponents* firstComps = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear | NSCalendarUnitMonth |  NSCalendarUnitDay)
                                                                   fromDate:firstPubDate];
        
    for(CDEpisode* episode in sortedEpisodes)
    {
        // don't download old episodes when we only allow download of most recent once
        if (onlyMostRecent)
        {
            NSDate* pubDate = episode.pubDate;
            NSDateComponents* comps = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear | NSCalendarUnitMonth |  NSCalendarUnitDay)
                                                                      fromDate:pubDate];
            
            if ([comps day] != [firstComps day] || [comps month] != [firstComps month] || [comps year] != [firstComps year]) {
                continue;
            }
        }
        
        // don't download consumed and archived episodes
        if (episode.consumed || episode.archived) {
            continue;
        }
        /*
        else if ([episode.pubDate timeIntervalSinceDate:[NSDate date]] < -86000*14) {
            continue;
        }
        */
        else if (pickedEpisode && [episode isEqual:pickedEpisode]) {
            caching |= [cman autoCacheEpisode:episode enableFilters:YES];
        }
        
        else if (!pickedEpisode) {
            caching |= [cman autoCacheEpisode:episode enableFilters:YES];
        }
    }
    
    return caching;
}


#pragma mark -
#pragma mark Importing Stuff

// returns multiple times
- (void) _importURLs:(NSArray*)array completion:(void (^)(void))completion
{
    __block NSInteger parsedFeeds = 0;
    
    for(NSURL* feedURL in array)
    {
        parsedFeeds++;
        ICFeedParser* feedParser = [ICFeedParser feedParser];
        feedParser.url = [feedURL copy];

        __weak ICFeedParser* weakFeedParser = feedParser;
        feedParser.didParseFeedBlock = ^(ICFeed* feed) {
            dispatch_async(dispatch_get_main_queue(), ^{
                feed.username = weakFeedParser.username;
                feed.password = weakFeedParser.password;
                feed.lastUpdate = [NSDate date];

                [DMANAGER subscribeFeed:feed];

                parsedFeeds--;
                if (parsedFeeds == 0 && completion) {
                    completion();
                }
            });
        };

        feedParser.didEndWithError = ^(NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                parsedFeeds--;
                if (parsedFeeds == 0 && completion) {
                    completion();
                }
            });
        };
        
        [self.parserQueue addOperation:feedParser];
    }
}

- (void) importURL:(NSURL*)url completion:(void (^)(void))completion
{
    for(CDFeed* feed in DMANAGER.feeds) {
		if ([feed.sourceURL isEqual:url]) {
			if (completion) completion();
			return;
		}
	}

    [App retainNetworkActivity];


    [self _importURLs:[NSArray arrayWithObject:url] completion:^{

        [App releaseNetworkActivity];

        if (completion) {
            completion();
        }
    }];
}


/*- (void) importOPMLData:(NSData*)data completion:(void (^)())completion
{
	OPMLParser* opmlParser = [OPMLParser opmlParserWithData:data];
    [opmlParser parseWithCompletionHandler:^(NSArray *feeds) {
        
        self.importing = YES;
        [App retainNetworkActivity];
        

        NSMutableDictionary* feedIndex = [NSMutableDictionary dictionary];
        for(CDFeed* feed in DMANAGER.feeds) {
            static NSString* kObj = @"1";
            [feedIndex setObject:kObj forKey:feed.sourceURL];
        }
        
        
        NSMutableArray* urls = [NSMutableArray array];

        for(NSDictionary* feedDict in feeds)
        {
            NSString* xmlURL = [feedDict objectForKey:OPMLFeedXmlUrl];
            if (!xmlURL) {
                continue;
            }
            
            NSURL* feedURL = [NSURL URLWithString:xmlURL];
            if (!feedURL) {
                ErrLog(@"can not make feed URL from: %@", xmlURL);
                continue;
            }

            if (![feedIndex objectForKey:feedURL]) {
                [urls addObject:feedURL];
            }
        }
        
        if ([urls count] > 0)
        {
            [DMANAGER beginInterruptSaving];
            [self _importURLs:urls completion:^(void) {

                [App releaseNetworkActivity];

                self.importing = NO;
                [DMANAGER endInterruptSaving];
                [DMANAGER save];
                
                [self autoDownloadAllFeedsAsynchronously];
                
                if (completion) {
                    completion();
                }
            }];
        }
        else {
            if (completion) {
                completion();
            }
        }

    } errorHandler:^(NSError *error) {
        ErrLog(@"opml didEndWithError: %@", [error description]);
        if (completion) {
            completion();
        }
    }];
}*/

/*- (void)importOPMLData:(NSData *)data completion:(void (^)())completion progress:(void (^)(float progress))progress
{
    OPMLParser *opmlParser = [OPMLParser opmlParserWithData:data];

    [opmlParser parseWithCompletionHandler:^(NSArray *feeds) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            self.importing = YES;
            [App retainNetworkActivity];

            NSMutableDictionary *feedIndex = [NSMutableDictionary dictionary];
            for (CDFeed *feed in DMANAGER.feeds) {
                feedIndex[feed.sourceURL.absoluteString] = @"1"; // use absoluteString for safety
            }

            NSMutableArray<NSURL *> *urlsToImport = [NSMutableArray array];
            for (NSDictionary *feedDict in feeds) {
                NSString *xmlURL = feedDict[OPMLFeedXmlUrl];
                if (!xmlURL) continue;

                NSURL *feedURL = [NSURL URLWithString:xmlURL];
                if (!feedURL) {
                    ErrLog(@"Cannot make feed URL from: %@", xmlURL);
                    continue;
                }

                if (!feedIndex[feedURL.absoluteString]) {
                    [urlsToImport addObject:feedURL];
                }
            }

            if (urlsToImport.count == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (progress) progress(1.0);
                    if (completion) completion();
                });
                return;
            }

            dispatch_group_t group = dispatch_group_create();
            NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
            config.timeoutIntervalForRequest = 10;
            config.timeoutIntervalForResource = 20;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

            [DMANAGER beginInterruptSaving];

            NSInteger totalCount = urlsToImport.count;
            __block NSInteger completedCount = 0;

            for (NSURL *url in urlsToImport) {
                dispatch_group_enter(group);

                NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    NSInteger statusCode = 200;
                    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                        statusCode = [(NSHTTPURLResponse *)response statusCode];
                    }

                    BOOL shouldSkip = error || !data || statusCode < 200 || statusCode >= 300;
                    if (shouldSkip) {
                        ErrLog(@"Skipping %@ due to error: %@", ICRedactedURLStringForLogging(url.absoluteString), error.localizedDescription);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completedCount++;
                            if (progress) progress((float)completedCount / (float)totalCount);
                            dispatch_group_leave(group);
                        });
                        return;
                    }

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self subscribeFeedWithURL:url options:kSubscribeOptionNone completion:^(CDFeed *feed, NSError *error) {

                            completedCount++;
                            if (progress) progress((float)completedCount / (float)totalCount);
                            dispatch_group_leave(group);
                        }];
                    });
                }];
                [task resume];
            }

            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                [App releaseNetworkActivity];
                self.importing = NO;
                [DMANAGER endInterruptSaving];
                [DMANAGER save];

                [self autoDownloadAllFeedsAsynchronously];

                if (progress) progress(1.0);
                if (completion) completion();
            });
        });

    } errorHandler:^(NSError *error) {
        ErrLog(@"opml didEndWithError: %@", error.localizedDescription);
        if (progress) progress(1.0);
        if (completion) completion();
    }];
}*/

- (CDFeed *)subscribeParserFeedMetadataOnly:(ICFeed *)parserFeed {
    if (parserFeed.changedSourceURL) {
        parserFeed.sourceURL = parserFeed.changedSourceURL;
    }

    CDFeed *subscribedFeed = [DMANAGER subscribeFeedMetadataOnly:parserFeed];
    subscribedFeed.parked = NO;
    subscribedFeed.subscribed = YES;
    return subscribedFeed;
}


- (void)importOPMLData:(NSData *)data completion:(void (^)(NSError* error))completion progress:(void (^)(float))progress {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self importOPMLData:data completion:completion progress:progress];
        });
        return;
    }
    if (self.importing) {
        if (completion) {
            completion([NSError errorWithDomain:@"OPMLImport"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey: @"Another subscription import is already in progress.".ls}]);
        }
        return;
    }

    self.importing = YES;
    [App retainNetworkActivity];
    OPMLParser *opmlParser = [OPMLParser opmlParserWithData:data];

    [opmlParser parseWithCompletionHandler:^(NSArray<NSDictionary *> *feeds) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            __block NSMutableSet<NSString *> *existingFeedURLs;
            dispatch_sync(dispatch_get_main_queue(), ^{
                existingFeedURLs = [NSMutableSet set];
                for (CDFeed *feed in DMANAGER.feeds) {
                    NSString *normalized = [self normalizedURLString:feed.sourceURL];
                    if (normalized) {
                        [existingFeedURLs addObject:normalized];
                    }
                }
            });

            NSMutableArray<NSURL *> *urlsToImport = [NSMutableArray arrayWithCapacity:feeds.count];
            NSUInteger invalidURLCount = 0;
            for (NSDictionary *feedDict in feeds) {
                NSString *xmlURL = feedDict[OPMLFeedXmlUrl];
                if (xmlURL.length == 0) {
                    invalidURLCount++;
                    continue;
                }

                NSURL *feedURL = [NSURL URLWithString:xmlURL];
                NSString *normalized = [self normalizedURLString:feedURL];
                if (!feedURL || !normalized) {
                    invalidURLCount++;
                    ErrLog(@"skipped invalid feed: %@", xmlURL);
                    continue;
                }
                if ([existingFeedURLs containsObject:normalized]) {
                    continue;
                }
                [urlsToImport addObject:feedURL];
            }

            if (urlsToImport.count == 0) {
                NSError* importError = nil;
                if (feeds.count == 0 || invalidURLCount > 0) {
                    importError = [NSError errorWithDomain:@"OPMLImport"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"The OPML file does not contain any valid podcast subscriptions.".ls}];
                }
                [self finalizeImportWithCompletion:completion
                                          progress:progress
                                             error:importError
                            savingWasInterrupted:NO];
                return;
            }

            [self importURLs:urlsToImport completion:completion progress:progress];
        });
    } errorHandler:^(NSError *error) {
        ErrLog(@"OPML parsing error: %@", error.localizedDescription);
        NSError* importError = error ?: [NSError errorWithDomain:@"OPMLImport"
                                                             code:3
                                                         userInfo:@{NSLocalizedDescriptionKey: @"The OPML file could not be read.".ls}];
        [self finalizeImportWithCompletion:completion
                                  progress:progress
                                     error:importError
                    savingWasInterrupted:NO];
    }];
}


- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSError* error))completion progress:(void (^)(float))progress {
    dispatch_group_t group = dispatch_group_create();
    NSMutableArray<NSError*>* importErrors = [NSMutableArray array];

    [DMANAGER beginInterruptSaving];

    NSUInteger totalCount = urls.count;
    __block NSUInteger completedCount = 0;

    for (NSURL *url in urls) {
        dispatch_group_enter(group);

        [self subscribeFeedWithOpmlURLNew:url options:kSubscribeOptionNone completion:^(CDFeed *feed, NSError *error) {
            if (error) {
                ErrLog(@"Skipping %@ due to error: %@", ICRedactedURLStringForLogging(url.absoluteString), error.localizedDescription);
                @synchronized(importErrors) {
                    [importErrors addObject:error];
                }
            }
            [self updateProgress:&completedCount total:totalCount progress:progress group:group];
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSError* importError = nil;
        if (importErrors.count > 0) {
            importError = [NSError errorWithDomain:@"OPMLImport"
                                              code:4
                                          userInfo:@{
                                              NSLocalizedDescriptionKey: @"Some podcast subscriptions could not be imported. Check your connection and try again.".ls,
                                              NSUnderlyingErrorKey: importErrors.firstObject,
                                          }];
        }
        [self finalizeImportWithCompletion:completion
                                  progress:progress
                                     error:importError
                    savingWasInterrupted:YES];
    });
}

- (void)updateProgress:(NSUInteger *)completedCount total:(NSUInteger)totalCount progress:(void (^)(float))progress group:(dispatch_group_t)group {
    dispatch_async(dispatch_get_main_queue(), ^{
        (*completedCount)++;
        if (progress) progress((float)*completedCount / totalCount);
        dispatch_group_leave(group);
    });
}

- (void)finalizeImportWithCompletion:(void (^)(NSError* error))completion
                            progress:(void (^)(float))progress
                               error:(NSError*)error
              savingWasInterrupted:(BOOL)savingWasInterrupted {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (savingWasInterrupted) {
            [DMANAGER endInterruptSaving];
        }
        NSError* saveError = [DMANAGER saveReturningError];
        NSError* finalError = saveError ?: error;
        [App releaseNetworkActivity];
        self.importing = NO;
        if (progress) progress(1.0);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"OPMLImportDidFinishNotification" object:nil];
        if (completion) completion(finalError);
    });
}

#pragma mark -

- (void)opmlDataWithCompletion:(void (^)(NSData* data, NSError* error))completion
{
    if (!completion) {
        return;
    }

    NSString* title = [NSString stringWithFormat:@"Instacast Subscriptions from %@".ls, [NSBundle deviceName]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSManagedObjectContext* context = [DMANAGER newExportBackgroundContext];
            if (!context) {
                NSError* error = [NSError errorWithDomain:@"OPMLExport"
                                                      code:1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"The podcast database could not be opened for export.".ls}];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, error);
                });
                return;
            }

            __block NSData* data = nil;
            __block NSError* exportError = nil;
            [context performBlockAndWait:^{
                NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
                request.predicate = [NSPredicate predicateWithFormat:@"subscribed == %@ AND sourceURL_ != nil", @YES];
                request.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
                request.resultType = NSDictionaryResultType;
                request.propertiesToFetch = @[@"title", @"sourceURL_", @"linkURL_"];
                NSArray<NSDictionary*>* feedRows = [context executeFetchRequest:request error:&exportError];
                if (!feedRows || exportError) {
                    return;
                }

                NSMutableArray* feedDicts = [NSMutableArray arrayWithCapacity:feedRows.count];
                for (NSDictionary* row in feedRows) {
                    NSString* sourceURL = [row[@"sourceURL_"] isKindOfClass:[NSString class]] ? row[@"sourceURL_"] : nil;
                    if (sourceURL.length == 0) {
                        continue;
                    }
                    NSMutableDictionary* dict = [NSMutableDictionary dictionary];
                    NSString* feedTitle = [row[@"title"] isKindOfClass:[NSString class]] ? row[@"title"] : nil;
                    NSString* linkURL = [row[@"linkURL_"] isKindOfClass:[NSString class]] ? row[@"linkURL_"] : nil;
                    if (feedTitle.length > 0) dict[OPMLFeedTitle] = feedTitle;
                    dict[OPMLFeedType] = @"rss";
                    dict[OPMLFeedXmlUrl] = sourceURL;
                    if (linkURL.length > 0) dict[OPMLFeedHtmlUrl] = linkURL;
                    [feedDicts addObject:dict];
                }

                OPMLWriter* opmlWriter = [OPMLWriter opmlWriterWithFeeds:feedDicts];
                data = [opmlWriter dataWithTitle:title];
                if (data.length == 0) {
                    exportError = [NSError errorWithDomain:@"OPMLExport"
                                                       code:2
                                                   userInfo:@{NSLocalizedDescriptionKey: @"The OPML document could not be created.".ls}];
                }
            }];

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(data, exportError);
            });
        }
    });
}

- (NSString *)normalizedURLString:(NSURL *)url {
    if (!url) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = components.scheme.lowercaseString;
    components.host = components.host.lowercaseString;

    // Normalize path
    if (components.path.length == 0) {
        components.path = @"/";
    }

    // Remove trailing slash
    if ([components.path hasSuffix:@"/"] && components.path.length > 1) {
        components.path = [components.path substringToIndex:components.path.length - 1];
    }

    return components.URL.absoluteString;
}

@end
