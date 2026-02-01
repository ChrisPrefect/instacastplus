//
//  EpisodeLoadingManager.h
//  Instacast
//
//  Created by Claude on 01.02.26.
//
//  Manages lazy loading of episodes for feeds with many episodes.
//  Only the newest episodes are loaded initially, the rest loads in background.
//  Persists state to NSUserDefaults for crash recovery.
//

#import <Foundation/Foundation.h>

@class CDFeed, ICEpisode;

// Notifications
extern NSString* const EpisodeLoadingManagerDidStartLoadingNotification;
extern NSString* const EpisodeLoadingManagerDidLoadBatchNotification;
extern NSString* const EpisodeLoadingManagerDidFinishLoadingNotification;

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

// Check if a feed is currently loading
- (BOOL)isLoadingFeed:(CDFeed*)feed;

// Get loading progress (0.0 to 1.0) for a feed
- (double)loadingProgressForFeed:(CDFeed*)feed;

// Crash recovery - call on app launch to resume incomplete loads
- (void)restoreLoadingState;

// Current loading status
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) NSArray<NSString*>* feedURLsWithPendingEpisodes;

@end
