//
//  EpisodeLoadingManager.h
//  Instacast
//
//  Created by Claude on 01.02.26.
//
//  Manages lazy loading of episodes for feeds with many episodes.
//  Only the newest episodes are loaded initially, the rest loads in background.
//  Persists immutable payloads and small cursors for crash recovery.
//

#import <Foundation/Foundation.h>

@class CDFeed, ICEpisode;

// Notifications
extern NSString* const EpisodeLoadingManagerDidStartLoadingNotification;
extern NSString* const EpisodeLoadingManagerDidLoadBatchNotification;
extern NSString* const EpisodeLoadingManagerDidFinishLoadingNotification;
extern NSString* const EpisodeLoadingManagerDidFailLoadingNotification;
extern NSString* const EpisodeLoadingManagerDidCancelLoadingNotification;

// FeedProperty keys for tracking loading state
extern NSString* const kFeedPropertyEpisodeLoadingComplete;
extern NSString* const kFeedPropertyTotalExpectedEpisodes;
extern NSString* const kFeedPropertyLoadedEpisodeCount;

@interface EpisodeLoadingManager : NSObject

+ (instancetype)sharedManager;

// Queue pending episodes for background loading
// Called after initial batch of episodes has been saved
- (void)queuePendingEpisodesForFeed:(CDFeed*)feed
                     parserEpisodes:(NSArray<ICEpisode*>*)episodes
                         startIndex:(NSInteger)startIndex;

// Cancel loading for a feed (e.g., when unsubscribing)
- (void)cancelLoadingForFeed:(CDFeed*)feed;

// Cancel ALL pending loading operations
- (void)cancelAllLoading;

// Retry a durable job that stopped because its payload/cursor or Core Data save failed.
- (void)retryLoadingForFeed:(CDFeed*)feed;
- (NSError*)loadingErrorForFeed:(CDFeed*)feed;

// Check if a feed is currently loading
- (BOOL)isLoadingFeed:(CDFeed*)feed;

// Get loading progress (0.0 to 1.0) for a feed
- (double)loadingProgressForFeed:(CDFeed*)feed;

// Crash recovery - call on app launch to resume incomplete loads
- (void)restoreLoadingState;

// Current loading status
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) NSArray<NSString*>* feedURLsWithPendingEpisodes;

// Suspend/resume background loading (pauses the internal operation queue).
// Use this to prevent episode loading from flooding the main queue during batch operations.
@property (nonatomic) BOOL suspended;

// Log current loading status to console (for debugging)
- (void)logStatus;

@end
