//
//  SubscriptionManager.h
//  Instacast
//
//  Created by Martin Hering on 30.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <Foundation/Foundation.h>

extern NSString* SubscriptionManagerWillStartRefreshingFeedsNotification;
extern NSString* SubscriptionManagerDidStartRefreshingFeedsNotification;
extern NSString* SubscriptionManagerWillParseFeedNotification;
extern NSString* SubscriptionManagerDidParseFeedNotification;       // userinfo "feed": CDFeed object
extern NSString* SubscriptionManagerDidAddEpisodesNotification;
extern NSString* SubscriptionManagerDidFinishRefreshingFeedsNotification;

@class CDFeed;
@class CDEpisode;
@class ICFeed;

typedef void(^ICSubscriptionManagerRefreshCompletionBlock)(BOOL success, NSArray* newEpisodes, NSError* error);

@interface SubscriptionManager : NSObject

+ (SubscriptionManager*) sharedSubscriptionManager;

- (CDFeed*) subscribeParserFeed:(ICFeed*)parserFeed;
- (CDFeed*) subscribeParserFeed:(ICFeed*)parserFeed autodownload:(BOOL)autodownload options:(ICSubscribeOptions)options;
- (void) unsubscribeFeed:(CDFeed*)feed;

- (void) reloadContentOfFeed:(CDFeed*)feed recoverArchivedEpisodes:(BOOL)recoverArchived completion:(ICSubscriptionManagerRefreshCompletionBlock)completion;
- (void) subscribeFeedWithURL:(NSURL*)url options:(ICSubscribeOptions)options completion:(void (^)(CDFeed* feed, NSError* error))completion;
- (void) subscribeFeedWithURL:(NSURL*)url username:(NSString*)username password:(NSString*)password options:(ICSubscribeOptions)options completion:(void (^)(CDFeed* feed, NSError* error))completion;

@property (nonatomic, readonly) NSString* formattedLastRefreshDate;
- (NSString*) formattedLastRefreshDateForFeed:(CDFeed*)feed;

- (void) refreshAllFeedsForce:(BOOL)force;
- (void) refreshAllFeedsForce:(BOOL)force completion:(ICSubscriptionManagerRefreshCompletionBlock)handler;
- (void) refreshAllFeedsForce:(BOOL)force etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)handler;

- (void) refreshFeeds:(NSArray*)feeds etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)handler;
- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)handler;
- (BOOL) canRefreshFeedsOnCurrentNetwork;

// Phase 2 of the iCloud two-phase subscription apply: fills a stub feed (subscribed, but
// never refreshed, no episodes) with content. Unlike refreshFeed:, this never merges the
// full feed in one main-context push — it follows the subscribeFeed:withOptions: pattern:
// the newest episodes are inserted directly, the rest loads via EpisodeLoadingManager.
- (void) hydrateStubFeed:(CDFeed*)feed completion:(ICSubscriptionManagerRefreshCompletionBlock)completion;

//- (void) callbackWhenRefreshCompleted:(void(^)())handler;
- (void) updateLocalFeedInfo:(CDFeed*)localFeed withRemoteFeed:(ICFeed*)remoteFeed force:(BOOL)force;

@property (nonatomic, readonly, getter=isRefreshing) BOOL refreshing;
@property (nonatomic, readonly, strong) NSMutableArray* refreshingFeedURLs;
@property (nonatomic, readonly, assign) double refreshProgress;
@property (nonatomic, readonly, strong) NSURL* refreshedURL;
@property (nonatomic, readonly) NSString* refreshStatusText;
// Status text including done/total podcast count. Use in podcast list UI only.
- (NSString*) refreshStatusTextWithPodcastCount;
@property (nonatomic, readonly) NSString* lastRefreshingFeedName;
@property (nonatomic, readonly, strong) NSArray<NSString*>* pendingRefreshFeedTitles;
@property (nonatomic, readonly) NSString* pendingRefreshStatusDetailsText;
@property (nonatomic, readonly) NSString* lastRefreshFailedFeedName;
@property (nonatomic, readonly, strong) NSArray<NSString*>* lastRefreshFailureMessages;

/* Enforcing Download Settings */
- (BOOL) autoDownloadEpisodesInFeed:(CDFeed*)feed;
- (BOOL) autoDownloadEpisode:(CDEpisode*)episode;
- (void) autoDownloadEpisodesInFeedAsynchronously:(CDFeed*)feed;
- (void) autoDownloadAllFeedsAsynchronously;
- (void) recoverPendingAutoDownloadsAfterDatabaseStartup;

/* Importing */

- (void) importURL:(NSURL*)url completion:(void (^)(void))completion;
- (void) importOPMLData:(NSData*)data completion:(void (^)(NSError* error))completion progress:(void (^)(float progress))progress;

- (void)opmlDataWithCompletion:(void (^)(NSData* data, NSError* error))completion;

@end
