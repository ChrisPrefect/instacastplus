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
@property (nonatomic, strong) NSOperationQueue* mergeQueue;
@property (nonatomic, strong) NSDate* refreshStartDate;
@property (nonatomic, strong) NSMutableSet<NSURL*>* feedsMergingURLs;

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

        _mergeQueue = [[NSOperationQueue alloc] init];
        [_mergeQueue setMaxConcurrentOperationCount:2];
        _mergeQueue.qualityOfService = NSQualityOfServiceUtility;

        _feedsMergingURLs = [[NSMutableSet alloc] init];
        
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
    if (autodownload && !subscribedFeed.parked) {
        [self _autoDownloadEpisodesInFeedAsynchronously:subscribedFeed];
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

        [DMANAGER save];

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


    for(CDFeed* feed in eligibleFeeds)
    {
        [self refreshFeed:feed
             etagHandling:etagHandling
               completion:(([eligibleFeeds lastObject] == feed) ? completion : nil)];
    }
    
}

- (void) _finishParsingFeed:(CDFeed*)feed url:(NSURL*)url shouldAutoDownload:(BOOL)shouldAutoDownload
{
    if (shouldAutoDownload) {
        [self _autoDownloadEpisodesInFeedAsynchronously:feed];
    }

    [self _enforceKeepNewestLimitForFeed:feed];

    // Must always run on main thread.
    [self _finishRefreshingURL:url];

    [[NSNotificationCenter defaultCenter] postNotificationName:SubscriptionManagerDidParseFeedNotification
                                                        object:self
                                                      userInfo:(feed)?[NSDictionary dictionaryWithObject:feed forKey:@"feed"]:nil];
}

- (BOOL)_feedNeedsDurationMetadataRefreshForFeedObjectID:(NSManagedObjectID*)feedObjectID
{
    if (!feedObjectID || feedObjectID.isTemporaryID) {
        return NO;
    }

    NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
    if (!context) {
        return NO;
    }

    __block BOOL needsRefresh = NO;
    [context performBlockAndWait:^{
        NSError* feedError = nil;
        CDFeed* feed = (CDFeed*)[context existingObjectWithID:feedObjectID error:&feedError];
        if (![feed isKindOfClass:[CDFeed class]] || feedError) {
            return;
        }

        NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        request.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == NO && consumed == NO && position <= 0 && duration <= 0", feed];
        request.fetchLimit = 1;

        NSError* countError = nil;
        NSUInteger count = [context countForFetchRequest:request error:&countError];
        needsRefresh = (!countError && count != NSNotFound && count > 0);
    }];
    return needsRefresh;
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
    
    BOOL needsDurationMetadataRefresh = [self _feedNeedsDurationMetadataRefreshForFeedObjectID:feed.objectID];
    ICFeedParser* feedParser = [ICFeedParser feedParser];
    if (etagHandling && !needsDurationMetadataRefresh) {
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

                        localFeed.contentHash = parsedFeed.contentHash;
                        localFeed.etag = parsedFeed.etag;
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

                dispatch_async(dispatch_get_main_queue(), ^{
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
            [strongSelf _finishParsingFeed:feed url:url shouldAutoDownload:NO];
        });
    };
    
    [self.parserQueue addOperation:feedParser];
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
        
        
        // save all changes
        [DMANAGER save];
        
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
            NSInteger remoteDuration = remoteEpisode.duration;
            if (remoteDuration > 0 && localEpisode.duration != (int32_t)remoteDuration) {
                localEpisode.duration = (int32_t)remoteDuration;
            }
            BOOL newer = ([remoteEpisode.pubDate timeIntervalSince1970] > [localEpisode.pubDate timeIntervalSince1970]);
            
            if (newer) {
                localEpisode.fulltext = remoteEpisode.textDescription;
                localEpisode.imageURL = remoteEpisode.imageURL;
                localEpisode.pubDate = remoteEpisode.pubDate;
                localEpisode.transcripts = remoteEpisode.transcripts;
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
                [context deleteObject:episode];
            }
        }
    }
}

- (NSArray*) _mergeLocalFeed:(CDFeed*)localFeed withWithRemoteFeed:(ICFeed*)remoteFeed force:(BOOL)force
{
    NSManagedObjectContext* context = localFeed.managedObjectContext;
    NSSet* localEpisodes = localFeed.episodes;
    NSMutableSet* episodeGuids = [[NSMutableSet alloc] initWithCapacity:[localEpisodes count]];
    NSMutableSet* episodeObjectHashes = [[NSMutableSet alloc] initWithCapacity:[localEpisodes count]];

    for(CDEpisode* episode in localEpisodes) {
        if (episode.guid) {
            [episodeGuids addObject:episode.guid];
        }
        if (episode.objectHash) {
            [episodeObjectHashes addObject:episode.objectHash];
        }
    }
    
	// merge new entries
	NSArray* remoteEpisodes = [remoteFeed.episodes sortedArrayUsingDescriptors:@[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:YES] ]];
    CDEpisode* newestLocalEpisode = [[localFeed sortedEpisodes] firstObject];
	
    NSMutableArray* newEpisodes = [[NSMutableArray alloc] init];
	for (ICEpisode* remoteEpisode in remoteEpisodes)
	{
        if (!remoteEpisode.guid) {
            continue;
        }

        BOOL guidAlreadyExists = [episodeGuids containsObject:remoteEpisode.guid];
        BOOL hashAlreadyExists = (remoteEpisode.objectHash && [episodeObjectHashes containsObject:remoteEpisode.objectHash]);

        // Episode exists locally — check if it's a stub from backup import (no title)
        if (guidAlreadyExists || hashAlreadyExists) {
            for (CDEpisode *localEp in localEpisodes) {
                if ((localEp.guid && [localEp.guid isEqualToString:remoteEpisode.guid]) ||
                    (localEp.objectHash && [localEp.objectHash isEqualToString:remoteEpisode.objectHash])) {
                    if (!localEp.title || localEp.title.length == 0) {
                        // Stub episode from backup import — fill in metadata, preserve status
                        [self _copyEpisodeValuesFrom:remoteEpisode toPersistentEpisode:localEp];
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
                        localEp.media = media;
                    }
                    break;
                }
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

            [episodeGuids addObject:remoteEpisode.guid];
            if (newPersistentEpisode.objectHash) {
                [episodeObjectHashes addObject:newPersistentEpisode.objectHash];
            }
            
            // only mark those episodes as unplayed that are newer than the latest episodes we already got
            NSTimeInterval newEpisodeTimeInterval = [newPersistentEpisode.pubDate timeIntervalSince1970];
            NSTimeInterval formerEpisodeTimeInterval = [newestLocalEpisode.pubDate timeIntervalSince1970];
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
    
    for(CDEpisode* episode in [localFeed.episodes copy])
    {
        if (![episodeGuids containsObject:episode.guid]) {
            [DMANAGER deleteEpisode:episode];
        }
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

- (void)_autoDownloadEpisodesInFeedAsynchronously:(CDFeed*)feed
{
    if (!feed || feed.parked || !feed.subscribed || feed.objectID.isTemporaryID) {
        return;
    }

    NSManagedObjectID* feedObjectID = feed.objectID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        if (!context) {
            return;
        }

        __block NSArray<NSManagedObjectID*>* episodeObjectIDs = @[];
        [context performBlockAndWait:^{
            NSError* feedError = nil;
            CDFeed* backgroundFeed = (CDFeed*)[context existingObjectWithID:feedObjectID error:&feedError];
            if (![backgroundFeed isKindOfClass:[CDFeed class]] || feedError || backgroundFeed.parked || !backgroundFeed.subscribed) {
                return;
            }

            NSArray* sortedEpisodes = [backgroundFeed chronologicallySortedEpisodes];
            NSDate* firstPubDate = [[sortedEpisodes firstObject] pubDate];
            if (!firstPubDate) {
                return;
            }

            NSDateComponents* firstComps = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                                                           fromDate:firstPubDate];
            NSMutableArray<NSManagedObjectID*>* objectIDs = [NSMutableArray array];
            for (CDEpisode* episode in sortedEpisodes) {
                NSDate* pubDate = episode.pubDate;
                NSDateComponents* comps = [[NSCalendar currentCalendar] components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay)
                                                                          fromDate:pubDate];
                if ([comps day] != [firstComps day] || [comps month] != [firstComps month] || [comps year] != [firstComps year]) {
                    continue;
                }
                if (episode.consumed || episode.archived || episode.objectID.isTemporaryID) {
                    continue;
                }
                [objectIDs addObject:episode.objectID];
            }
            episodeObjectIDs = [objectIDs copy];
        }];

        if (episodeObjectIDs.count == 0) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray* thisSortedEpisodes = [[NSMutableArray alloc] initWithCapacity:episodeObjectIDs.count];
            for (NSManagedObjectID* objectID in episodeObjectIDs) {
                NSError* error = nil;
                CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:objectID error:&error];
                if ([episode isKindOfClass:[CDEpisode class]] && !error && !episode.isDeleted) {
                    [thisSortedEpisodes addObject:episode];
                }
            }
            [self _autoDownloadEpisode:nil sortedEpisodes:thisSortedEpisodes];
        });
    });
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

            // Collect existing feed URLs on main thread (Core Data is not thread-safe)
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

    [DMANAGER beginInterruptSaving];

    NSUInteger totalCount = urls.count;
    __block NSUInteger completedCount = 0;

    for (NSURL *url in urls) {
        dispatch_group_enter(group);

        [self subscribeFeedWithOpmlURLNew:url options:kSubscribeOptionNone completion:^(CDFeed *feed, NSError *error) {
            if (error) {
                ErrLog(@"Skipping %@ due to error: %@", url.absoluteString, error.localizedDescription);
            }
            [self updateProgress:&completedCount total:totalCount progress:progress group:group];
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self finalizeImportWithCompletion:completion progress:progress];
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
        if (progress) progress(1.0);
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
		if (!feed.sourceURL) continue;
		NSMutableDictionary* dict = [NSMutableDictionary dictionary];
		if (feed.title) dict[OPMLFeedTitle] = feed.title;
		dict[OPMLFeedType] = @"rss";
		dict[OPMLFeedXmlUrl] = [feed.sourceURL absoluteString];
		if (feed.linkURL) dict[OPMLFeedHtmlUrl] = [feed.linkURL absoluteString];
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
