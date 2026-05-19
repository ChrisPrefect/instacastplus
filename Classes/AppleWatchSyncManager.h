//
//  AppleWatchSyncManager.h
//  Instacast
//

#import <Foundation/Foundation.h>

@class CDEpisode;
@class AppleWatchEpisodeState;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const ICAppleWatchSyncManagerStateDidChangeNotification;
FOUNDATION_EXPORT NSString* const ICAppleWatchEpisodeStatesDidChangeNotification;

@interface AppleWatchSyncManager : NSObject

@property (nonatomic, readonly) BOOL supported;
@property (nonatomic, readonly) BOOL paired;
@property (nonatomic, readonly) BOOL watchAppInstalled;
@property (nonatomic, readonly) BOOL reachable;
@property (nonatomic, strong, readonly, nullable) NSDate* lastSyncDate;
@property (nonatomic, strong, readonly, nullable) NSDate* lastWatchStatusDate;
@property (nonatomic, readonly) int64_t watchFreeBytes;
@property (nonatomic, readonly) int64_t watchDownloadBytes;

+ (instancetype)sharedManager;

- (void)start;
- (void)syncNow;
- (void)rebuildAutomaticSelectionsAndSync;

- (NSArray<AppleWatchEpisodeState*>*)allEpisodeStates;
- (NSArray<AppleWatchEpisodeState*>*)visibleEpisodeStates;
- (nullable AppleWatchEpisodeState*)stateForEpisodeHash:(NSString*)episodeHash;

- (BOOL)isEpisodeSelectedForWatch:(CDEpisode*)episode;
- (BOOL)isEpisodeDownloadedOnWatch:(CDEpisode*)episode;
- (BOOL)canSendEpisodeToWatch:(CDEpisode*)episode;

- (void)sendEpisodeToWatch:(CDEpisode*)episode;
- (void)removeEpisodeFromWatch:(CDEpisode*)episode;
- (void)prioritizeEpisodeOnWatch:(CDEpisode*)episode;

@end

NS_ASSUME_NONNULL_END
