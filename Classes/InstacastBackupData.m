//
//  InstacastBackupData.m
//  Instacast
//

#import "InstacastBackupData.h"

@implementation ICBackupEpisode
@end

@implementation ICBackupPodcast
- (instancetype)init {
    if ((self = [super init])) {
        _episodes = [NSMutableArray array];
    }
    return self;
}
@end

@implementation ICBackupBookmark
@end

@implementation ICBackupPlaylist
- (instancetype)init {
    if ((self = [super init])) {
        _episodes = [NSMutableArray array];
    }
    return self;
}
@end

@implementation ICBackupSettings
- (instancetype)init {
    if ((self = [super init])) {
        _values = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

@implementation InstacastBackupData
- (instancetype)init {
    if ((self = [super init])) {
        _podcasts = [NSMutableArray array];
        _bookmarks = [NSMutableArray array];
        _upNextEpisodes = [NSMutableArray array];
        _playlists = [NSMutableArray array];
        _settings = [[ICBackupSettings alloc] init];
    }
    return self;
}
@end
