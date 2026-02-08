//
//  InstacastBackupData.h
//  Instacast
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - ICBackupEpisode

@interface ICBackupEpisode : NSObject
@property (nonatomic, strong, nullable) NSString *guid;
@property (nonatomic, strong, nullable) NSString *mediaURL;
@property (nonatomic, strong, nullable) NSString *feedURL; // used in upnext/playlists
@property (nonatomic) BOOL played;
@property (nonatomic) BOOL starred;
@property (nonatomic) BOOL archived;
@property (nonatomic) BOOL downloaded;
@property (nonatomic) int32_t position;
@property (nonatomic) int32_t duration;
@end

#pragma mark - ICBackupPodcast

@interface ICBackupPodcast : NSObject
@property (nonatomic, strong, nullable) NSString *feedURL;
@property (nonatomic) int32_t rank;
@property (nonatomic, strong, nullable) NSMutableDictionary *settings;
@property (nonatomic, strong) NSMutableArray<ICBackupEpisode *> *episodes;
@end

#pragma mark - ICBackupBookmark

@interface ICBackupBookmark : NSObject
@property (nonatomic) double position;
@property (nonatomic, strong, nullable) NSString *title;
@property (nonatomic, strong, nullable) NSString *episodeGuid;
@property (nonatomic, strong, nullable) NSString *feedURL;
@end

#pragma mark - ICBackupPlaylist

@interface ICBackupPlaylist : NSObject
@property (nonatomic, strong, nullable) NSString *name;
@property (nonatomic) int32_t rank;
@property (nonatomic, strong) NSMutableArray<ICBackupEpisode *> *episodes;
@end

#pragma mark - ICBackupSettings

@interface ICBackupSettings : NSObject
@property (nonatomic, strong) NSMutableDictionary *values;
@property (nonatomic, strong, nullable) NSString *feedListSortMode;
@property (nonatomic, strong, nullable) NSMutableArray<NSString *> *manualFeedOrder;
@end

#pragma mark - InstacastBackupData

@interface InstacastBackupData : NSObject
@property (nonatomic, strong, nullable) NSString *version;
@property (nonatomic, strong, nullable) NSDate *date;
@property (nonatomic, strong) NSMutableArray<ICBackupPodcast *> *podcasts;
@property (nonatomic, strong) NSMutableArray<ICBackupBookmark *> *bookmarks;
@property (nonatomic, strong) NSMutableArray<ICBackupEpisode *> *upNextEpisodes;
@property (nonatomic, strong, nullable) ICBackupEpisode *nowPlaying;
@property (nonatomic, strong) NSMutableArray<ICBackupPlaylist *> *playlists;
@property (nonatomic, strong) ICBackupSettings *settings;
@end

NS_ASSUME_NONNULL_END
