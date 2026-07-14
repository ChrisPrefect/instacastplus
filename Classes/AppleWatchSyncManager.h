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
FOUNDATION_EXPORT NSString* const ICAppleWatchLiveStatusDidChangeNotification;
FOUNDATION_EXPORT NSString* const ICAppleWatchChangedEpisodeHashesUserInfoKey;

typedef NS_ENUM(NSInteger, ICAppleWatchTransferPhase) {
    ICAppleWatchTransferPhaseNone = 0,
    ICAppleWatchTransferPhaseWaiting,
    ICAppleWatchTransferPhaseDownloading,
};

@interface AppleWatchSyncManager : NSObject

@property (nonatomic, readonly) BOOL supported;
@property (nonatomic, readonly) BOOL paired;
@property (nonatomic, readonly) BOOL watchAppInstalled;
@property (nonatomic, readonly) BOOL reachable;
@property (nonatomic, strong, readonly, nullable) NSDate* lastSyncDate;
@property (nonatomic, strong, readonly, nullable) NSDate* lastWatchStatusDate;
@property (nonatomic, readonly) int64_t watchFreeBytes;
@property (nonatomic, readonly) int64_t watchUsedBytes;
@property (nonatomic, readonly) int64_t watchTotalBytes;
@property (nonatomic, readonly) int64_t watchDownloadBytes;
@property (nonatomic, copy, readonly, nullable) NSString* currentWatchDownloadTitle;
@property (nonatomic, readonly) int64_t currentWatchDownloadedBytes;
@property (nonatomic, readonly) int64_t currentWatchExpectedBytes;

// Aggregated progress over all episodes that should be on the watch ("x MB von TOTAL MB").
// Waiting means the manifest/download queue has not reported an active transfer yet.
// outTotalBytesKnown is NO when any unfinished episode has no known enclosure/download size.
- (ICAppleWatchTransferPhase)watchDownloadProgressLoadedBytes:(int64_t* _Nullable)outLoadedBytes
                                                  totalBytes:(int64_t* _Nullable)outTotalBytes
                                             totalBytesKnown:(BOOL* _Nullable)outTotalBytesKnown;

+ (instancetype)sharedManager;

- (void)start;
- (void)syncNow;
- (void)syncCurrentSelectionsNow;
- (void)rebuildAutomaticSelectionsAndSync;

- (NSArray<AppleWatchEpisodeState*>*)allEpisodeStates;
- (NSArray<AppleWatchEpisodeState*>*)visibleEpisodeStates;
- (nullable AppleWatchEpisodeState*)stateForEpisodeHash:(nullable NSString*)episodeHash;
- (BOOL)hasLiveDownloadProgressForEpisodeHash:(nullable NSString*)episodeHash
                          selectionIdentifier:(nullable NSString*)selectionIdentifier;

- (BOOL)isEpisodeSelectedForWatch:(CDEpisode*)episode;
- (BOOL)isEpisodeDownloadedOnWatch:(CDEpisode*)episode;
- (BOOL)canSendEpisodeToWatch:(CDEpisode*)episode;

- (NSInteger)watchStorageEvictedCount;
- (BOOL)watchStorageFull;

- (void)sendEpisodeToWatch:(CDEpisode*)episode;
- (void)removeEpisodeFromWatch:(CDEpisode*)episode;
- (void)removeEpisodeStateFromWatch:(AppleWatchEpisodeState*)state;
- (void)prioritizeEpisodeOnWatch:(CDEpisode*)episode;
- (void)moveEpisodeAtIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;

@end

NS_ASSUME_NONNULL_END
