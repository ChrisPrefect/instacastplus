//
//  SubscriptionManager.m
//  Instacast
//
//  Created by Martin Hering on 30.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//


#import "ICFeedParser.h"
#import "ICPagedFeedParser.h"

#import "OPML.h"
#import "CDModel.h"
#import "CDFeed+Helper.h"
#import "CDEpisode+ShowNotes.h"
#import "EpisodeLoadingManager.h"

NSString* SubscriptionManagerWillStartRefreshingFeedsNotification = @"SubscriptionManagerWillStartRefreshingFeedsNotification";
NSString* SubscriptionManagerDidStartRefreshingFeedsNotification = @"SubscriptionManagerDidStartRefreshingFeedsNotification";
NSString* SubscriptionManagerDidFinishRefreshingFeedsNotification = @"SubscriptionManagerDidFinishRefreshingFeedsNotification";

NSString* SubscriptionManagerWillParseFeedNotification = @"SubscriptionManagerWillParseFeedNotification";
NSString* SubscriptionManagerDidParseFeedNotification = @"SubscriptionManagerDidParseFeedNotification";
NSString* SubscriptionManagerDidAddEpisodesNotification = @"SubscriptionManagerDidAddEpisodesNotification";

static SubscriptionManager* gSharedSubscriptionManager = nil;

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
@property (nonatomic, strong) NSDate* refreshStartDate;

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

- (BOOL)_isSynchronizationPausedForFeed:(CDFeed*)feed
{
    if (!feed) {
        return NO;
    }
    return [feed boolForKey:PauseFeedSynchronization];
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
    if (autodownload && !subscribedFeed.parked) {
        [self autoDownloadEpisodesInFeed:subscribedFeed];
    }
    return subscribedFeed;
}

- (void) unsubscribeFeed:(CDFeed*)feed
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    AudioSession* session = [AudioSession sharedAudioSession];

    if ([pman.playingEpisode.feed isEqual:feed]) {
        [session stop];
    }

    // Cancel any pending episode loading for this feed
    [[EpisodeLoadingManager sharedManager] cancelLoadingForFeed:feed];

    // remove cache
    CacheManager* cman = [CacheManager sharedCacheManager];
    [cman removeCacheForFeed:feed automatic:NO];
    [cman resetAutoCacheForFeed:feed];

    // remove from Up Next
    [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:[feed.episodes allObjects]];

    [DMANAGER unsubscribeFeed:feed];
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

        [DMANAGER saveAndSync:YES];

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
    if (!url) {
        return;
    }
    
    [App retainNetworkActivity];

    DebugLog(@"subscribing with URL: %@", url);
    
    ICFeedParser* parser = [[ICFeedParser alloc] init];
    parser.url = url;
    parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
    parser.didParseFeedBlock = ^(ICFeed* parserFeed) {

        CDFeed* persistentFeed = [self subscribeParserFeed:parserFeed autodownload:YES options:options];

        [DMANAGER saveAndSync:YES];

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

    DebugLog(@"subscribing with URL: %@", url);
    
    ICFeedParser* parser = [[ICFeedParser alloc] init];
    parser.url = url;
    parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
    parser.didParseFeedBlock = ^(ICFeed* parserFeed) {
        
        CDFeed* persistentFeed = [self subscribeParserFeed:parserFeed autodownload:NO options:options];
        
        [DMANAGER saveAndSync:YES];
        
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

    DebugLog(@"subscribing with URL: %@", url);
    
    ICFeedParser* parser = [[ICFeedParser alloc] init];
    parser.url = url;
    parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
    parser.didParseFeedBlock = ^(ICFeed* parserFeed) {
        if (!url) {
            if (completion) completion(nil, [NSError errorWithDomain:@"OPML" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Invalid feed URL"}]);
            [App releaseNetworkActivity];
            return;
        }

        // 🧠 Check if already subscribed
        NSFetchRequest *fetchRequest = [CDFeed fetchRequest];
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", url.absoluteString];
        fetchRequest.fetchLimit = 1;
        NSError *fetchError = nil;
        NSArray *existingFeeds = [DMANAGER.objectContext executeFetchRequest:fetchRequest error:&fetchError];

        CDFeed *persistentFeed = nil;

        if (existingFeeds.count > 0) {
            persistentFeed = existingFeeds.firstObject;
            DebugLog(@"Already subscribed to feed: %@", url);
        } else {
            //persistentFeed = [self subscribeParserFeedMetadataOnly:parserFeed];
            persistentFeed = [self subscribeParserFeed:parserFeed autodownload:NO options:options];
            [DMANAGER saveAndSync:YES];
            DebugLog(@"New feed subscribed: %@", url);
        }

        if (completion) {
            completion(persistentFeed, fetchError);
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

    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorTimedOut:
                return @"Timeout".ls;
            case NSURLErrorCannotFindHost:
            case NSURLErrorDNSLookupFailed:
            case NSURLErrorFileDoesNotExist:
            case NSURLErrorResourceUnavailable:
                return @"Not found".ls;
            case NSURLErrorUserAuthenticationRequired:
            case NSURLErrorNoPermissionsToReadFile:
            case NSURLErrorDataNotAllowed:
                return @"No access".ls;
            default:
                break;
        }
    }

    NSString* lowerDescription = [[error localizedDescription] lowercaseString];
    NSString* lowerRecovery = [[[error userInfo][NSLocalizedRecoverySuggestionErrorKey] description] lowercaseString];
    NSString* lowerCombined = [NSString stringWithFormat:@"%@ %@", lowerDescription ?: @"", lowerRecovery ?: @""];

    if ([lowerCombined rangeOfString:@"timeout"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"timed out"].location != NSNotFound) {
        return @"Timeout".ls;
    }
    if ([lowerCombined rangeOfString:@"not found"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"cannot be found"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"404"].location != NSNotFound) {
        return @"Not found".ls;
    }
    if ([lowerCombined rangeOfString:@"permission"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"forbidden"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"unauthorized"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"401"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"403"].location != NSNotFound ||
        [lowerCombined rangeOfString:@"auth"].location != NSNotFound) {
        return @"No access".ls;
    }

    return error.localizedDescription ?: @"Unknown error".ls;
}

- (void) _beginRefreshTrackingForFeeds:(NSArray*)feeds
{
    [self.refreshFeedStartDates removeAllObjects];
    [self.refreshFeedTitlesByURL removeAllObjects];
    [self.refreshFailedFeedTitles removeAllObjects];
    [self.refreshTimedOutFeedTitles removeAllObjects];
    [self.refreshFailureMessages removeAllObjects];
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
            DebugLog(@"not auto refreshing, because no internet connection");
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


    for(CDFeed* feed in eligibleFeeds)
    {
        [self refreshFeed:feed
             etagHandling:etagHandling
               completion:(([eligibleFeeds lastObject] == feed) ? completion : nil)];
    }
    
}

- (void) _finishParsingFeed:(CDFeed*)feed url:(NSURL*)url
{
    [self autoDownloadEpisodesInFeed:feed];

    // Always called from main thread (via performSelectorOnMainThread in ICFeedParser)
    [self _finishRefreshingURL:url];

    [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidParseFeedNotification
                                                        object:self
                                                      userInfo:(feed)?[NSDictionary dictionaryWithObject:feed forKey:@"feed"]:nil];
}

- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion
{    
    if (!feed || [self _isSynchronizationPausedForFeed:feed]) {
        if (completion) {
            completion(YES, @[], nil);
        }
        return;
    }

    NSURL* url = [feed.sourceURL copy];
    if (!url) {
        return;
    }
    [self.refreshingFeedURLs addObject:url];

    BOOL notificationBefore = ([self.parserQueue operationCount] == 0);
    if (notificationBefore) {
        self.refreshedURL = feed.sourceURL;
        [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerWillParseFeedNotification object:self userInfo:@{@"url" : feed.sourceURL}];
    }
    
    ICFeedParser* feedParser = [ICFeedParser feedParser];
    if (etagHandling) {
        feedParser.etag = feed.etag;
    }
    
    feedParser.url = [feed.sourceURL copy];
    feedParser.username = feed.username;
    feedParser.password = feed.password;
    feedParser.timeout = 8;
#if TARGET_OS_IPHONE
    feedParser.dontAskForCredentials = ([App applicationState] != UIApplicationStateActive);
    feedParser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
#endif
    __weak ICFeedParser* weakFeedParser = feedParser;
    feedParser.didParseFeedBlock = ^(ICFeed* parsedFeed) {
        if (![self.refreshingFeedURLs containsObject:url]) {
            return;
        }
        
        if (!notificationBefore) {
            self.refreshedURL = feed.sourceURL;
            [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerWillParseFeedNotification object:self userInfo:@{@"url" : url}];
        }
        
        
        NSMutableArray* allNewEpisodes = [NSMutableArray array];
        
        if (parsedFeed)
        {
            // merge
            NSArray* feeds = [DMANAGER visibleFeeds];
            
            for(CDFeed* feed in feeds) {
                if ([feed.sourceURL isEqual:parsedFeed.sourceURL])
                {
                    // import new episodes
                    if (!etagHandling || ![feed.contentHash isEqual:parsedFeed.contentHash]) {
                        NSArray* newEpisodes = [self _mergeLocalFeed:feed withWithRemoteFeed:parsedFeed force:NO];
                        if ([newEpisodes count] > 0) {
                            [allNewEpisodes addObjectsFromArray:newEpisodes];
                        }
                    }
                    
                    // update existing content
                    feed.contentHash = parsedFeed.contentHash;
                    feed.etag = parsedFeed.etag;
                    break;
                }
            }
            
            self.numOfNewEpisodesAfterRefresh += [allNewEpisodes count];
            
            
            if ([allNewEpisodes count] > 0 && [feed boolForKey:AutoDeleteNewsMode]) {
                [self _recycleOldEpisodesInNewsModeFeed:feed];
            }
        }
        if (weakFeedParser.username && ![weakFeedParser.username isEqualToString:feed.username]) {
            feed.username = weakFeedParser.username;
        }
        if (weakFeedParser.password && ![weakFeedParser.password isEqualToString:feed.password]) {
            feed.password = weakFeedParser.password;
        }
        feed.lastUpdate = [NSDate date];
        
        DebugLog(@"parsed %@", feed.title);
        
        [self _finishParsingFeed:feed url:url];
        
        if (completion) {
            completion(YES, allNewEpisodes, nil);
        }
    };
    
    feedParser.didEndWithError = ^(NSError* error) {
        if (![self.refreshingFeedURLs containsObject:url]) {
            return;
        }
        
        if (completion) {
            completion(NO, nil, error);
        }
        
        if (!notificationBefore) {
            [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerWillParseFeedNotification object:self userInfo:@{@"url" : feed.sourceURL}];
        }
        
        ErrLog(@"error parsing '%@': %@", feed.title, [error description]);
        [self _markFeedFailedForURL:url timedOut:NO error:error];
        [self _finishParsingFeed:feed url:url];
    };
    
    [self.parserQueue addOperation:feedParser];
}


- (void) checkRefreshOperationsTimer:(NSTimer*)timer
{
    if (self.refreshingFeedURLs.count > 0) {
        NSDate* now = [NSDate date];
        NSMutableArray<NSURL*>* timedOutURLs = [NSMutableArray array];
        for (NSURL* url in [self.refreshingFeedURLs copy]) {
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
                [self _finishRefreshingURL:url];
            }
        }
    }

    // Safety timeout: force-finish after 30 seconds regardless
    NSTimeInterval elapsed = -[self.refreshStartDate timeIntervalSinceNow];
    if (elapsed > 30.0 && [self.refreshingFeedURLs count] > 0) {
        for (NSURL* url in [self.refreshingFeedURLs copy]) {
            [self _markFeedFailedForURL:url timedOut:YES error:nil];
            [self _finishRefreshingURL:url];
        }
        [self.parserQueue cancelAllOperations];
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
        
        
        // save all changes
        [DMANAGER save];
        
        // update application badge
#if TARGET_OS_IPHONE
        App.applicationIconBadgeNumber = ([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0;
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

            App.applicationIconBadgeNumber = ([USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen]) ? DMANAGER.unplayedList.numberOfEpisodes : 0;
            [App presentLocalNotificationNow:finishedNotification];
#pragma clang diagnostic pop
        }
#endif

 
 
#if TARGET_OS_IPHONE
        [self perform:^(id sender) {
            DebugLog(@"end background task");
            if (self.backgroundIdentifier != UIBackgroundTaskInvalid) {
                [App endBackgroundTask:self.backgroundIdentifier];
                self.backgroundIdentifier = UIBackgroundTaskInvalid;
            }
        } afterDelay:1.0f];
#endif
		
        [self willChangeValueForKey:@"formattedLastRefreshDate"];
		[USER_DEFAULTS setDouble:[[NSDate date] timeIntervalSince1970] forKey:LastRefreshSubscriptionDate];
		[USER_DEFAULTS synchronize];
        [self didChangeValueForKey:@"formattedLastRefreshDate"];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidFinishRefreshingFeedsNotification object:self];
	}
}

- (void) updateLocalFeedInfo:(CDFeed*)localFeed withRemoteFeed:(ICFeed*)remoteFeed force:(BOOL)force
{
    if (!force)
    {    
        if (remoteFeed.changedSourceURL) {
            localFeed.sourceURL = remoteFeed.changedSourceURL;
        }
        localFeed.etag = remoteFeed.etag;
        localFeed.title = remoteFeed.title;
        localFeed.linkURL = remoteFeed.linkURL;
        localFeed.paymentURL = remoteFeed.paymentURL;
        localFeed.imageURL = remoteFeed.imageURL;

        NSMutableDictionary* localEpisodeIndex = [NSMutableDictionary dictionary];
        for(CDEpisode* episode in localFeed.episodes) {
            if (episode.guid) {
                localEpisodeIndex[episode.guid] = episode;
            }
        }

        for(ICEpisode* remoteEpisode in remoteFeed.episodes)
        {
            if (!remoteEpisode.guid) {
                continue;
            }
            
            CDEpisode* localEpisode = localEpisodeIndex[remoteEpisode.guid];
            BOOL newer = ([remoteEpisode.pubDate timeIntervalSince1970] > [localEpisode.pubDate timeIntervalSince1970]);
            
            if (newer) {
                localEpisode.fulltext = remoteEpisode.textDescription;
                localEpisode.imageURL = remoteEpisode.imageURL;
                localEpisode.pubDate = remoteEpisode.pubDate;
            }
            else {
                if (!localEpisode.fulltext || ![localEpisode.fulltext isEqualToString:remoteEpisode.textDescription]) {
                    localEpisode.fulltext = remoteEpisode.textDescription;
                }
                
                if (!localEpisode.imageURL || ![localEpisode.imageURL isEqual:remoteEpisode.imageURL]) {
                    localEpisode.imageURL = remoteEpisode.imageURL;
                }
            }
        }
    }
    
    else
    {
        [DMANAGER _copyFeedValuesFrom:remoteFeed to:localFeed];
        
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
            [DMANAGER _copyEpisodeValuesFrom:episode to:localEpisode];
            
            
            NSArray* localMedia = [localEpisode.media allObjects];
            for(ICMedia* remoteMedium in episode.media)
            {
                // dont add mediums without file URL, because medium depends on it for syncing
                if (!remoteMedium.fileURL) {
                    continue;
                }
                
                [[episode.media copy] enumerateObjectsUsingBlock:^(ICMedia* media, NSUInteger idx, BOOL *stop) {
                    
                    if ([localMedia count] > idx) {
                        CDMedium* localMedium = localMedia[idx];
                        [DMANAGER _copyMediumValuesFrom:remoteMedium to:localMedium];
                    }
                    else
                    {
                        CDMedium* persistentMedium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:DMANAGER.objectContext];
                        [DMANAGER _copyMediumValuesFrom:remoteMedium to:persistentMedium];
                        [[localEpisode mutableSetValueForKey:@"media"] addObject:persistentMedium];
                    }
                    
                }];
            }
        }
        
        // remove duplicate episodes
        NSArray* episodes = [localFeed.episodes sortedArrayUsingDescriptors:@[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO] ]];
        
        NSMutableSet* guids = [NSMutableSet setWithCapacity:[episodes count]];
        for(CDEpisode* episode in episodes) {
            if (!episode.guid) {
                continue;
            }
            if (![guids containsObject:episode.guid]) {
                [guids addObject:episode.guid];
            }
            else {
                [DMANAGER.objectContext deleteObject:episode];
            }
        }
    }
}

- (NSArray*) _mergeLocalFeed:(CDFeed*)localFeed withWithRemoteFeed:(ICFeed*)remoteFeed force:(BOOL)force
{
    NSSet* localEpisodes = localFeed.episodes;
    NSMutableSet* episodeGuids = [[NSMutableSet alloc] initWithCapacity:[localEpisodes count]];

    for(CDEpisode* episode in localEpisodes) {
        if (episode.guid) {
            [episodeGuids addObject:episode.guid];
        }
    }
    
	// merge new entries
	NSArray* remoteEpisodes = [remoteFeed.episodes sortedArrayUsingDescriptors:@[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:YES] ]];
    CDEpisode* newestLocalEpisode = [[localFeed sortedEpisodes] firstObject];
	
    NSMutableArray* newEpisodes = [[NSMutableArray alloc] init];
    CDEpisode* mostCurrentEpisode = nil;
	for (ICEpisode* remoteEpisode in remoteEpisodes)
	{
		// local episode does not exist
		if (![episodeGuids containsObject:remoteEpisode.guid])
		{
            // make persistent
			DebugLog(@"add episode %@", remoteEpisode.title);
            BOOL wasNew;
            CDEpisode* newPersistentEpisode = [DMANAGER addNewParserEpisode:remoteEpisode toFeed:localFeed wasNew:&wasNew];
            
            // only mark those episodes as unplayed that are newer than the latest episodes we already got
            NSTimeInterval newEpisodeTimeInterval = [newPersistentEpisode.pubDate timeIntervalSince1970];
            NSTimeInterval formerEpisodeTimeInterval = [newestLocalEpisode.pubDate timeIntervalSince1970];
            if (wasNew && newEpisodeTimeInterval > formerEpisodeTimeInterval) {
                newPersistentEpisode.consumed = NO;
            }

            if (!mostCurrentEpisode || [newPersistentEpisode.pubDate laterDate:mostCurrentEpisode.pubDate] == newPersistentEpisode.pubDate) {
                mostCurrentEpisode = newPersistentEpisode;
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
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidAddEpisodesNotification
                                                        object:self
                                                      userInfo:@{@"episodes" : newEpisodes}];
    
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
    
    for(CDEpisode* episode in [localFeed.episodes copy])
    {
        if (![episodeGuids containsObject:episode.guid]) {
            [DMANAGER deleteEpisode:episode];
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
    NSManagedObjectContext* childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [childContext setParentContext:DMANAGER.objectContext];
    
    
    [childContext performBlockAndWait:^{
        NSFetchRequest* feedsRequest = [[NSFetchRequest alloc] init];
        feedsRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:childContext];
        feedsRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES && parked == NO"];
        feedsRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
        
        NSError* error;
        NSArray* feeds = [childContext executeFetchRequest:feedsRequest error:&error];
        if (error) {
            ErrLog(@"error getting feeds: %@", error);
        }
        
        for(CDFeed* feed in feeds)
        {
            NSArray* sortedEpisodes = [feed chronologicallySortedEpisodes];
            NSMutableArray* sortedEpisodesIds = [[NSMutableArray alloc] init];
            for(CDEpisode* episode in sortedEpisodes) {
                [sortedEpisodesIds addObject:[episode objectID]];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                
                NSMutableArray* thisSortedEpisodes = [[NSMutableArray alloc] init];
                for(NSManagedObjectID* objectId in sortedEpisodesIds) {
                    CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext objectWithID:objectId];
                    if (episode) {
                        [thisSortedEpisodes addObject:episode];
                    }
                }
                
                [self _autoDownloadEpisode:nil sortedEpisodes:thisSortedEpisodes];
            });
        }
    }];
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
            //NSLog(@"try auto-caching episode '%@'", episode.title);
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
            
            feed.username = weakFeedParser.username;
            feed.password = weakFeedParser.password;
            feed.lastUpdate = [NSDate date];
            
            [DMANAGER subscribeFeed:feed];
            
            parsedFeeds--;
            if (parsedFeeds == 0 && completion) {
                completion();
            }
        };
        
        feedParser.didEndWithError = ^(NSError* error) {
            
            parsedFeeds--;
            if (parsedFeeds == 0 && completion) {
                completion();
            }
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
                        ErrLog(@"Skipping %@ due to error: %@", url.absoluteString, error.localizedDescription);
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


- (void)importOPMLData:(NSData *)data completion:(void (^)(void))completion progress:(void (^)(float))progress {
    OPMLParser *opmlParser = [OPMLParser opmlParserWithData:data];
    
    [opmlParser parseWithCompletionHandler:^(NSArray<NSDictionary *> *feeds) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            self.importing = YES;
            [App retainNetworkActivity];

            // Normalize and collect existing feed URLs
            NSMutableSet<NSString *> *existingFeedURLs = [NSMutableSet set];
            for (CDFeed *feed in DMANAGER.feeds) {
                NSString *normalized = [self normalizedURLString:feed.sourceURL];
                if (normalized) {
                    [existingFeedURLs addObject:normalized];
                }
            }
            
            NSMutableArray<NSURL *> *urlsToImport = [NSMutableArray arrayWithCapacity:feeds.count];
            for (NSDictionary *feedDict in feeds) {
                NSString *xmlURL = feedDict[OPMLFeedXmlUrl];
                if (!xmlURL) continue;
                
                NSURL *feedURL = [NSURL URLWithString:xmlURL];
                NSString *normalized = [self normalizedURLString:feedURL];
                
                if (!feedURL || !normalized || [existingFeedURLs containsObject:normalized]) {
                    ErrLog(@"skipped duplicate or invalid feed: %@", xmlURL);
                    continue;
                }

                [urlsToImport addObject:feedURL];
                DebugLog(@"queued for import: %@", normalized);
            }
            
            if (urlsToImport.count == 0) {
                [self finalizeImportWithCompletion:completion progress:progress];
                return;
            }
            
            [self importURLs:urlsToImport completion:completion progress:progress];
        });
    } errorHandler:^(NSError *error) {
        ErrLog(@"OPML parsing error: %@", error.localizedDescription);
        [self finalizeImportWithCompletion:completion progress:progress];
    }];
}


- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(void))completion progress:(void (^)(float))progress {
    dispatch_group_t group = dispatch_group_create();
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 8.0;
    //config.timeoutIntervalForResource = 20.0;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData; // Avoid caching
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:nil];
    
    [DMANAGER beginInterruptSaving];
    
    NSUInteger totalCount = urls.count;
    __block NSUInteger completedCount = 0;
    
    for (NSURL *url in urls) {
        dispatch_group_enter(group);
        
        NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            BOOL shouldSkip = error || !data || (httpResponse && (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300));
            
            if (shouldSkip) {
                ErrLog(@"Skipping %@ due to error: %@", url.absoluteString, error.localizedDescription ?: @"Invalid response");
                [self updateProgress:&completedCount total:totalCount progress:progress group:group];
                return;
            }

            [self subscribeFeedWithOpmlURLNew:url options:kSubscribeOptionNone completion:^(CDFeed *feed, NSError *error) {
                [self updateProgress:&completedCount total:totalCount progress:progress group:group];
            }];
        }];
        [task resume];
    }
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self finalizeImportWithCompletion:completion progress:progress];
        [session finishTasksAndInvalidate];
    });
}

- (void)updateProgress:(NSUInteger *)completedCount total:(NSUInteger)totalCount progress:(void (^)(float))progress group:(dispatch_group_t)group {
    dispatch_async(dispatch_get_main_queue(), ^{
        (*completedCount)++;
        if (progress) progress((float)*completedCount / totalCount);
        dispatch_group_leave(group);
    });
}

- (void)finalizeImportWithCompletion:(void (^)(void))completion progress:(void (^)(float))progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        [App releaseNetworkActivity];
        self.importing = NO;
        [DMANAGER endInterruptSaving];
        [DMANAGER save];
        //[self autoDownloadAllFeedsAsynchronously];
        if (progress) progress(1.0);
        // ✅ 🔔 Post notification so table view can refresh FRC
        [[NSNotificationCenter defaultCenter] postNotificationName:@"OPMLImportDidFinishNotification" object:nil];
        if (completion) completion();
    });
}

#pragma mark -

- (NSData*) opmlData
{
	NSArray* feeds = DMANAGER.feeds;
	NSMutableArray* feedDicts = [NSMutableArray array];
	
	for(CDFeed* feed in feeds)
	{
		NSDictionary* dict = [NSDictionary dictionaryWithObjectsAndKeys:
							  feed.title, OPMLFeedTitle,
							  @"rss", OPMLFeedType,
							  [feed.sourceURL absoluteString], OPMLFeedXmlUrl,
							  [feed.linkURL absoluteString], OPMLFeedHtmlUrl,
							  nil];
		[feedDicts addObject:dict];
	}
	
	NSString* title = [NSString stringWithFormat:@"Instacast Subscriptions from %@".ls, [NSBundle deviceName]];
	OPMLWriter* opmlWriter = [OPMLWriter opmlWriterWithFeeds:feedDicts];
	return [opmlWriter dataWithTitle:title];
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
