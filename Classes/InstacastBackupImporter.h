//
//  InstacastBackupImporter.h
//  Instacast
//

#import <Foundation/Foundation.h>

@class InstacastBackupData;

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, ICBackupImportCategory) {
    ICBackupImportNewPodcasts     = 1 << 0,
    ICBackupImportEpisodeStatus   = 1 << 1,
    ICBackupImportFeedSettings    = 1 << 2,
    ICBackupImportBookmarks       = 1 << 3,
    ICBackupImportUpNext          = 1 << 4,
    ICBackupImportNowPlaying      = 1 << 5,
    ICBackupImportPlaylists       = 1 << 6,
    ICBackupImportSettings        = 1 << 7,
    ICBackupImportSortOrder       = 1 << 8,
    ICBackupImportDownloads       = 1 << 9,
    ICBackupImportAppleWatch      = 1 << 10,
    ICBackupImportAll             = 0x7FF,
};

/// Callbacks for detailed import progress reporting.
/// All callbacks are dispatched to the main thread.
typedef struct {
    void (^ _Nullable setCurrentFeed)(NSString *title, NSInteger index, NSInteger total);
    void (^ _Nullable setFeedProgress)(NSInteger index, float progress, NSString *detail);
    void (^ _Nullable setFeedCompleted)(NSInteger index, NSInteger episodeCount);
    void (^ _Nullable setFeedError)(NSInteger index, NSString *message);
    void (^ _Nullable setFeedSkipped)(NSInteger index);
    void (^ _Nullable setTotalProgress)(float progress);
    void (^ _Nullable setStatusText)(NSString *text);
    void (^ _Nullable setMetadataActive)(ICBackupImportCategory cat);
    void (^ _Nullable setMetadataCompleted)(ICBackupImportCategory cat, NSString *detail);
} ICBackupImportCallbacks;

@interface InstacastBackupImporter : NSObject

/// Full import with detailed callbacks.
/// Runs on a dedicated background thread. All Core Data + UI work is dispatched to main.
/// Cancel via +cancelImport immediately terminates the operation.
+ (void)importBackup:(InstacastBackupData *)backup
          categories:(ICBackupImportCategory)categories
           callbacks:(ICBackupImportCallbacks)callbacks
          completion:(void(^)(NSInteger importedCount, NSError * _Nullable error))completion;

/// Cancel the entire import. Safe to call from any thread. Takes effect immediately.
+ (void)cancelImport;

/// Skip only the currently loading feed. Safe to call from any thread.
+ (void)skipCurrentFeed;

/// Restore now-playing from pending state (call after episodes are loaded)
+ (void)processPendingNowPlaying;

/// Queue pending downloads (call after feeds have media URLs)
+ (void)processPendingDownloads;

@end

NS_ASSUME_NONNULL_END
