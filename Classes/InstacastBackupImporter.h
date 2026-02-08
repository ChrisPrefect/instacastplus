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
    ICBackupImportAll             = 0x1FF,
};

@interface InstacastBackupImporter : NSObject

+ (void)importBackup:(InstacastBackupData *)backup
           categories:(ICBackupImportCategory)categories
             progress:(void(^)(float progress, NSString *statusText))progress
           completion:(void(^)(NSInteger importedCount, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
