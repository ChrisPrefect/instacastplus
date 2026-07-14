//
//  CacheManager.h
//  Instacast
//
//  Created by Martin Hering on 03.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <Foundation/Foundation.h>

extern NSString* CacheManagerDidStartCachingNotification;
extern NSString* CacheManagerDidEndCachingNotification;
extern NSString* CacheManagerDidAddEpisodeToCachingQueueNotification;

extern NSString* CacheManagerDidUpdateNotification;
extern NSString* CacheManagerDidStartCachingEpisodeNotification;		// userinfo = episode
extern NSString* CacheManagerDidFinishCachingEpisodeNotification;		// userinfo = episode
extern NSString* CacheManagerDidFailCachingEpisodeNotification;          // userinfo = episode, error, automatic, reportsFailureToUser
extern NSString* CacheManagerDidCancelStreamingCacheEpisodeNotification;	// userinfo = episode
extern NSString* CacheManagerDidLoadFeedImageNotification;
// userInfo: episode (single removal), episodeHashes (single/batch), all (full clear)
extern NSString* CacheManagerDidClearCacheNotification;
extern NSString* CacheManagerWillDeleteCacheFilesNotification;          // userinfo = episodeHashes/all
extern NSString* CacheManagerWillCommitCacheFileDeletionNotification;   // userinfo = episodeHashes/all
extern NSString* CacheManagerDidDeleteCacheFilesNotification;           // userinfo = episodeHashes/all
extern NSString* CacheManagerDidRestoreCacheNotification;               // userinfo = episodeHashes
extern NSString* CacheManagerDidFinishBuildingCacheIndexNotification;

extern NSString* CacheManagerWiFiDidBecomeAvailableNotification;

@class CDFeed, CDEpisode;

@interface CacheManager : NSObject

+ (CacheManager*) sharedCacheManager;

- (NSURL*) URLForCachedEpisode:(CDEpisode*)episode;
- (BOOL) episodeIsCached:(CDEpisode*)episode;
- (BOOL) episodeIsCached:(CDEpisode*)episode fastLookup:(BOOL)fastLookup;
- (BOOL) cacheEpisode:(CDEpisode*)episode;
- (BOOL) cacheEpisode:(CDEpisode*)episode overwriteCellularLock:(BOOL)overwriteCellular;
- (BOOL) cacheEpisode:(CDEpisode*)episode overwriteCellularLock:(BOOL)overwriteCellular reportsFailureToUser:(BOOL)reportsFailureToUser;
- (void) removeCacheForEpisode:(CDEpisode*)episode automatic:(BOOL)automatic;
- (void) removeCacheForEpisode:(CDEpisode*)episode
                      automatic:(BOOL)automatic
                     completion:(void (^)(NSError* error))completion;
- (void) removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes automatic:(BOOL)automatic;
- (void) removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes
                       automatic:(BOOL)automatic
                      completion:(void (^)(NSError* error))completion;
- (void) removeCacheForFeed:(CDFeed*)feed automatic:(BOOL)automatic;
- (void) removeCacheForFeed:(CDFeed*)feed
                   automatic:(BOOL)automatic
                  completion:(void (^)(NSError* error))completion;
- (BOOL) isCaching;
- (BOOL) isCachingEpisode:(CDEpisode*)episode;
- (BOOL) isCachingSourceOfEpisode:(CDEpisode*)episode;
- (BOOL) isCachingFeed:(CDFeed*)feed;
- (void) cancelCaching;
- (void) cancelCachingEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload;
// Backup restore has already committed its durable cancel intent. Returns YES only once every indexed owner is gone.
- (BOOL)completeDeferredRestoreCancellationForObjectHash:(NSString*)objectHash episode:(CDEpisode*)episode;
- (void) cancelStreamingCacheForEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload;
- (void) cancelCachingFeed:(CDFeed*)feed;


@property (nonatomic) BOOL suspended;
- (void) pauseCaching;
- (void) pauseCachingEpisode:(CDEpisode*)episode;
- (BOOL) isCachingSuspended;
- (void) resumeCaching;
- (void) resumeCachingEpisode:(CDEpisode*)episode;

- (NSInteger) numberOfCachedEpisodes;

@property (nonatomic, readonly) NSArray* cachedEpisodes;
@property (nonatomic, readonly, getter=isCacheIndexReady) BOOL cacheIndexReady;
- (void)prepareCacheIndexIfNeeded;
// Immutable value snapshot safe to request from background Core Data contexts.
// Unlike cachedEpisodes, this never exposes main-context managed objects.
@property (nonatomic, readonly) NSSet<NSString*>* cachedEpisodeObjectHashes;
@property (nonatomic, readonly) NSArray* partiallyCachedEpisodes;
@property (nonatomic, readonly) NSArray<CDEpisode*>* failedDownloadEpisodes;
- (NSError*) downloadErrorForEpisode:(CDEpisode*)episode;
- (void) clearDownloadErrorForEpisode:(CDEpisode*)episode;
- (void) clearDownloadErrorForEpisode:(CDEpisode*)episode
                            completion:(void (^)(NSError* error))completion;
- (void) clearDownloadErrorsForEpisodes:(NSArray<CDEpisode*>*)episodes
                              completion:(void (^)(NSError* error))completion;
- (void) clearAllDownloadErrors;
- (void) clearAllDownloadErrorsWithCompletion:(void (^)(NSError* error))completion;
- (BOOL) retryFailedDownloadForEpisode:(CDEpisode*)episode error:(NSError**)error;


- (NSArray*) cachingEpisodes;  // observable
- (void) reorderCachingEpisodeFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;

- (BOOL) autoCacheEpisode:(CDEpisode*)episode enableFilters:(BOOL)filters;
- (BOOL) autoCacheFeed:(CDFeed*)feed;
- (BOOL) automaticCachingDisabledForEpisode:(CDEpisode*)episode;
- (void) resetAutoCacheForFeed:(CDFeed*)feed;


@property (readonly) double progress;
@property (readonly) double rate;  // in bytes

- (double) cacheProgressForEpisode:(CDEpisode*)episode;
- (long long) expectedContentLengthForEpisode:(CDEpisode*)episode;
- (NSTimeInterval) cacheTimeLeftForEpisode:(CDEpisode*)episode;
- (double) cacheProgressForFeed:(CDFeed*)feed;
- (double) cacheProgress;
- (BOOL) isLoadingEpisode:(CDEpisode*)episode;
- (BOOL) isLoadingEpisodeSuspended:(CDEpisode*)episode;

- (NSString*) beginStreamingCacheForEpisode:(CDEpisode*)episode acquiredNewLease:(BOOL*)acquiredNewLease;
- (void) updateStreamingCacheForEpisode:(CDEpisode*)episode progress:(double)progress leaseToken:(NSString*)leaseToken;
- (void) finishStreamingCacheForEpisode:(CDEpisode*)episode leaseToken:(NSString*)leaseToken;
- (void) failStreamingCacheForEpisode:(CDEpisode*)episode error:(NSError*)error leaseToken:(NSString*)leaseToken;
- (double) streamingCacheProgressForEpisode:(CDEpisode*)episode;

@property (nonatomic, readonly) unsigned long long numberOfDownloadedBytes;
- (unsigned long long) numberOfDownloadedBytesForEpisode:(CDEpisode*)episode;

- (void) tidyUp;
- (void)cancelDownloadsAndClearCacheWithCompletion:(void (^)(NSError* error))completion;

- (void) autoClearAndMakeRoomForBytes:(unsigned long long)bytes automatic:(BOOL)automatic;

- (void) handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler;

- (void) importFileAtURL:(NSURL*)url forEpisode:(CDEpisode*)episode completion:(void (^)(BOOL success, NSError* error))completion;
- (void) importStreamingFileAtURL:(NSURL*)url
                       forEpisode:(CDEpisode*)episode
                       leaseToken:(NSString*)leaseToken
                       completion:(void (^)(BOOL success, NSError* error))completion;
@end
