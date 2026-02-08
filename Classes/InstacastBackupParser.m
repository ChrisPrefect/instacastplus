//
//  InstacastBackupParser.m
//  Instacast
//

#import "InstacastBackupParser.h"
#import "InstacastBackupData.h"

#pragma mark - Parser Delegate

@interface InstacastBackupParserDelegate : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) InstacastBackupData *backupData;
@end

@implementation InstacastBackupParserDelegate {
    NSMutableArray<NSString *> *_elementStack;
    NSMutableString *_currentText;

    // Current objects being built
    ICBackupPodcast *_currentPodcast;
    ICBackupEpisode *_currentEpisode;
    ICBackupPlaylist *_currentPlaylist;
}

- (instancetype)init {
    if ((self = [super init])) {
        _backupData = [[InstacastBackupData alloc] init];
        _elementStack = [NSMutableArray array];
    }
    return self;
}

- (NSString *)currentPath {
    return [_elementStack componentsJoinedByString:@"/"];
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName
    attributes:(NSDictionary *)attrs
{
    [_elementStack addObject:elementName];
    _currentText = [NSMutableString string];

    NSString *path = [self currentPath];

    // <instacast version="1" date="...">
    if ([path isEqualToString:@"instacast"]) {
        _backupData.version = attrs[@"version"];
        NSString *dateStr = attrs[@"date"];
        if (dateStr) {
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            [df setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];
            _backupData.date = [df dateFromString:dateStr];
        }
    }
    // <podcast url="..." rank="...">
    else if ([path isEqualToString:@"instacast/podcasts/podcast"]) {
        _currentPodcast = [[ICBackupPodcast alloc] init];
        _currentPodcast.feedURL = attrs[@"url"];
        NSString *rankStr = attrs[@"rank"];
        if (rankStr) _currentPodcast.rank = (int32_t)[rankStr integerValue];
    }
    // <episode media="..." guid="..." feedUrl="..."> inside podcast
    else if ([path isEqualToString:@"instacast/podcasts/podcast/episodes/episode"]) {
        _currentEpisode = [[ICBackupEpisode alloc] init];
        _currentEpisode.mediaURL = attrs[@"media"];
        _currentEpisode.guid = attrs[@"guid"];
        _currentEpisode.feedURL = attrs[@"feedUrl"];
    }
    // <bookmark position="..." title="..." episodeGuid="..." feedUrl="..."/>
    else if ([path isEqualToString:@"instacast/bookmarks/bookmark"]) {
        ICBackupBookmark *bm = [[ICBackupBookmark alloc] init];
        bm.position = [attrs[@"position"] doubleValue];
        bm.title = attrs[@"title"];
        bm.episodeGuid = attrs[@"episodeGuid"];
        bm.feedURL = attrs[@"feedUrl"];
        [_backupData.bookmarks addObject:bm];
    }
    // <episode media="..." guid="..." feedUrl="..."/> inside upnext
    else if ([path isEqualToString:@"instacast/upnext/episode"]) {
        ICBackupEpisode *ep = [[ICBackupEpisode alloc] init];
        ep.mediaURL = attrs[@"media"];
        ep.guid = attrs[@"guid"];
        ep.feedURL = attrs[@"feedUrl"];
        [_backupData.upNextEpisodes addObject:ep];
    }
    // <nowplaying media="..." guid="..." feedUrl="..." position="..."/>
    else if ([path isEqualToString:@"instacast/nowplaying"]) {
        ICBackupEpisode *np = [[ICBackupEpisode alloc] init];
        np.mediaURL = attrs[@"media"];
        np.guid = attrs[@"guid"];
        np.feedURL = attrs[@"feedUrl"];
        np.position = (int32_t)[attrs[@"position"] integerValue];
        _backupData.nowPlaying = np;
    }
    // <playlist name="..." rank="...">
    else if ([path isEqualToString:@"instacast/playlists/playlist"]) {
        _currentPlaylist = [[ICBackupPlaylist alloc] init];
        _currentPlaylist.name = attrs[@"name"];
        NSString *rankStr = attrs[@"rank"];
        if (rankStr) _currentPlaylist.rank = (int32_t)[rankStr integerValue];
    }
    // <episode ...> inside playlist
    else if ([path isEqualToString:@"instacast/playlists/playlist/episode"]) {
        ICBackupEpisode *ep = [[ICBackupEpisode alloc] init];
        ep.mediaURL = attrs[@"media"];
        ep.guid = attrs[@"guid"];
        ep.feedURL = attrs[@"feedUrl"];
        [_currentPlaylist.episodes addObject:ep];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_currentText appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName
{
    NSString *path = [self currentPath];
    NSString *text = [_currentText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Episode child elements (inside podcast/episodes/episode)
    if ([path hasPrefix:@"instacast/podcasts/podcast/episodes/episode/"] && _currentEpisode) {
        if ([elementName isEqualToString:@"played"]) {
            _currentEpisode.played = [text isEqualToString:@"true"];
        } else if ([elementName isEqualToString:@"starred"]) {
            _currentEpisode.starred = [text isEqualToString:@"true"];
        } else if ([elementName isEqualToString:@"archived"]) {
            _currentEpisode.archived = [text isEqualToString:@"true"];
        } else if ([elementName isEqualToString:@"downloaded"]) {
            _currentEpisode.downloaded = [text isEqualToString:@"true"];
        } else if ([elementName isEqualToString:@"position"]) {
            _currentEpisode.position = (int32_t)[text integerValue];
        } else if ([elementName isEqualToString:@"duration"]) {
            _currentEpisode.duration = (int32_t)[text integerValue];
        }
    }
    // Settings child elements (inside podcast/settings)
    else if ([path hasPrefix:@"instacast/podcasts/podcast/settings/"] && _currentPodcast) {
        if (text.length > 0) {
            if (!_currentPodcast.settings) {
                _currentPodcast.settings = [NSMutableDictionary dictionary];
            }
            _currentPodcast.settings[elementName] = text;
        }
    }
    // Global settings child elements
    else if ([path hasPrefix:@"instacast/settings/"] && ![elementName isEqualToString:@"manualFeedOrder"] && ![elementName isEqualToString:@"feedUrl"]) {
        if (text.length > 0) {
            if ([elementName isEqualToString:@"feedListSortMode"]) {
                _backupData.settings.feedListSortMode = text;
            } else {
                _backupData.settings.values[elementName] = text;
            }
        }
    }
    // feedUrl inside manualFeedOrder
    else if ([path isEqualToString:@"instacast/settings/manualFeedOrder/feedUrl"]) {
        if (text.length > 0) {
            if (!_backupData.settings.manualFeedOrder) {
                _backupData.settings.manualFeedOrder = [NSMutableArray array];
            }
            [_backupData.settings.manualFeedOrder addObject:text];
        }
    }

    // Close episode inside podcast
    if ([path isEqualToString:@"instacast/podcasts/podcast/episodes/episode"]) {
        if (_currentEpisode && _currentPodcast) {
            [_currentPodcast.episodes addObject:_currentEpisode];
        }
        _currentEpisode = nil;
    }
    // Close podcast
    else if ([path isEqualToString:@"instacast/podcasts/podcast"]) {
        if (_currentPodcast) {
            [_backupData.podcasts addObject:_currentPodcast];
        }
        _currentPodcast = nil;
    }
    // Close playlist
    else if ([path isEqualToString:@"instacast/playlists/playlist"]) {
        if (_currentPlaylist) {
            [_backupData.playlists addObject:_currentPlaylist];
        }
        _currentPlaylist = nil;
    }

    [_elementStack removeLastObject];
}

@end

#pragma mark - InstacastBackupParser

@implementation InstacastBackupParser

+ (BOOL)isInstacastBackupData:(NSData *)data {
    if (!data || data.length < 50) return NO;

    // Check first 500 bytes for <instacast
    NSUInteger checkLength = MIN(data.length, 500);
    NSData *head = [data subdataWithRange:NSMakeRange(0, checkLength)];
    NSString *headStr = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
    if (!headStr) return NO;

    return [headStr rangeOfString:@"<instacast "].location != NSNotFound;
}

+ (void)parseData:(NSData *)data completion:(void(^)(InstacastBackupData *data, NSError *error))completion {
    if (!completion) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        InstacastBackupParserDelegate *delegate = [[InstacastBackupParserDelegate alloc] init];

        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        parser.delegate = delegate;

        BOOL success = [parser parse];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                completion(delegate.backupData, nil);
            } else {
                completion(nil, [parser parserError]);
            }
        });
    });
}

@end
