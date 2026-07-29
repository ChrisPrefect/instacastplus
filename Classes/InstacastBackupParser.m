//
//  InstacastBackupParser.m
//  Instacast
//

#import "InstacastBackupParser.h"
#import "InstacastBackupData.h"

NSString * const ICXMLImportErrorDomain = @"ICXMLImportErrorDomain";

// A 4500-episode customer backup is about 1.1 MiB. 16 MiB leaves ample room
// for larger libraries and metadata while bounding every external allocation.
static const NSUInteger ICXMLImportMaximumDataLength = 16 * 1024 * 1024;
// NSXMLParser emits events incrementally, but the parsed model retains semantic
// entries. Derive both structure budgets from the already bounded input: the
// app's exporter uses at least eight serialized bytes per element and at least
// 32 bytes for every repeatable semantic entry. Denser external XML is treated
// as a structure attack instead of forcing a valid app backup into a fixed
// episode-count ceiling.
static const NSUInteger ICXMLImportMinimumSerializedBytesPerElement = 8;
static const NSUInteger ICXMLImportMinimumSerializedBytesPerSemanticObject = 32;
static const NSUInteger ICXMLImportMaximumElementCount = ICXMLImportMaximumDataLength / ICXMLImportMinimumSerializedBytesPerElement;
static const NSUInteger ICXMLImportMaximumObjectCount = ICXMLImportMaximumDataLength / ICXMLImportMinimumSerializedBytesPerSemanticObject;
static const NSUInteger ICXMLImportMaximumDepth = 64;
static const NSUInteger ICXMLImportMaximumStringLength = 16 * 1024 * 1024;

static NSError *ICXMLImportLimitError(ICXMLImportErrorCode code)
{
    NSString *description = (code == ICXMLImportErrorFileTooLarge)
        ? @"The selected XML file is too large to import. InstacastPlus supports files up to 16 MB.".ls
        : @"The selected XML file is too complex to import safely.".ls;
    return [NSError errorWithDomain:ICXMLImportErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

@implementation ICXMLImportLimits

+ (NSData *)readDataFromURL:(NSURL *)url error:(NSError **)error
{
    BOOL scopedAccess = [url startAccessingSecurityScopedResource];
    @try {
        NSNumber *fileSize = nil;
        [url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        if (fileSize.unsignedLongLongValue > ICXMLImportMaximumDataLength) {
            if (error) *error = ICXMLImportLimitError(ICXMLImportErrorFileTooLarge);
            return nil;
        }

        NSError *readError = nil;
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:url error:&readError];
        if (!handle) {
            if (error) *error = readError;
            return nil;
        }

        NSUInteger initialCapacity = MIN(fileSize.unsignedIntegerValue, ICXMLImportMaximumDataLength);
        NSMutableData *data = [NSMutableData dataWithCapacity:initialCapacity];
        NSUInteger maximumReadLength = ICXMLImportMaximumDataLength + 1;
        while (data.length < maximumReadLength) {
            NSUInteger remainingLength = maximumReadLength - data.length;
            NSData *chunk = [handle readDataUpToLength:MIN((NSUInteger)(64 * 1024), remainingLength)
                                                error:&readError];
            if (!chunk || chunk.length == 0) {
                break;
            }
            [data appendData:chunk];
        }

        NSError *closeError = nil;
        [handle closeAndReturnError:&closeError];
        if (readError || closeError) {
            if (error) *error = readError ?: closeError;
            return nil;
        }
        if (![self validateData:data error:error]) {
            return nil;
        }
        return [data copy];
    }
    @finally {
        if (scopedAccess) {
            [url stopAccessingSecurityScopedResource];
        }
    }
}

+ (BOOL)validateData:(NSData *)data error:(NSError **)error
{
    if (data.length <= ICXMLImportMaximumDataLength) {
        return YES;
    }
    if (error) *error = ICXMLImportLimitError(ICXMLImportErrorFileTooLarge);
    return NO;
}

@end

@implementation ICXMLImportParserBudget {
    NSUInteger _elementCount;
    NSUInteger _objectCount;
    NSUInteger _depth;
    NSUInteger _stringLength;
}

- (BOOL)failWithParser:(NSXMLParser *)parser
{
    if (!_error) {
        _error = ICXMLImportLimitError(ICXMLImportErrorDocumentTooComplex);
    }
    [parser abortParsing];
    return NO;
}

- (BOOL)consumeStringLength:(NSUInteger)length parser:(NSXMLParser *)parser
{
    if (length > ICXMLImportMaximumStringLength - _stringLength) {
        return [self failWithParser:parser];
    }
    _stringLength += length;
    return YES;
}

- (BOOL)consumeElement:(NSString *)elementName
            attributes:(NSDictionary<NSString *,NSString *> *)attributes
                parser:(NSXMLParser *)parser
{
    if (_elementCount >= ICXMLImportMaximumElementCount || _depth >= ICXMLImportMaximumDepth) {
        return [self failWithParser:parser];
    }
    _elementCount++;
    _depth++;

    if (![self consumeStringLength:elementName.length parser:parser]) {
        return NO;
    }
    for (NSString *key in attributes) {
        NSString *value = attributes[key];
        NSUInteger length = key.length + value.length;
        if (length < key.length || ![self consumeStringLength:length parser:parser]) {
            return [self failWithParser:parser];
        }
    }
    return YES;
}

- (BOOL)consumeCharacters:(NSString *)characters parser:(NSXMLParser *)parser
{
    return [self consumeStringLength:characters.length parser:parser];
}

- (BOOL)consumeObjectWithParser:(NSXMLParser *)parser
{
    if (_objectCount >= ICXMLImportMaximumObjectCount) {
        return [self failWithParser:parser];
    }
    _objectCount++;
    return YES;
}

- (void)finishElement
{
    if (_depth > 0) {
        _depth--;
    }
}

- (void)rejectEntityWithParser:(NSXMLParser *)parser
{
    [self failWithParser:parser];
}

@end

#pragma mark - Parser Delegate

@interface InstacastBackupParserDelegate : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) InstacastBackupData *backupData;
@property (nonatomic, strong) ICXMLImportParserBudget *budget;
@end

@implementation InstacastBackupParserDelegate {
    NSMutableArray<NSString *> *_elementStack;
    NSMutableString *_currentText;

    // Current objects being built
    ICBackupPodcast *_currentPodcast;
    ICBackupEpisode *_currentEpisode;
    ICBackupPlaylist *_currentPlaylist;
    ICBackupEpisodeList *_currentEpisodeList;
    NSDateFormatter *_dateFormatter;
}

- (instancetype)init {
    if ((self = [super init])) {
        _backupData = [[InstacastBackupData alloc] init];
        _elementStack = [NSMutableArray array];
        _budget = [[ICXMLImportParserBudget alloc] init];
    }
    return self;
}

- (NSDateFormatter *)dateFormatter {
    if (!_dateFormatter) {
        _dateFormatter = [[NSDateFormatter alloc] init];
        _dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        _dateFormatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        [_dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];
    }
    return _dateFormatter;
}

- (NSDate *)dateFromString:(NSString *)dateString {
    if (dateString.length == 0) return nil;
    return [[self dateFormatter] dateFromString:dateString];
}

- (NSString *)currentPath {
    return [_elementStack componentsJoinedByString:@"/"];
}

#pragma mark - NSXMLParserDelegate

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName
  namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qualifiedName
    attributes:(NSDictionary *)attrs
{
    if (![self.budget consumeElement:elementName attributes:attrs parser:parser]) {
        return;
    }
    [_elementStack addObject:elementName];
    _currentText = [NSMutableString string];

    NSString *path = [self currentPath];

    // <instacast version="1" date="...">
    if ([path isEqualToString:@"instacast"]) {
        _backupData.version = attrs[@"version"];
        NSString *dateStr = attrs[@"date"];
        if (dateStr) {
            _backupData.date = [self dateFromString:dateStr];
        }
    }
    // <podcast url="..." rank="..." username="..." password="...">
    else if ([path isEqualToString:@"instacast/podcasts/podcast"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        _currentPodcast = [[ICBackupPodcast alloc] init];
        _currentPodcast.feedURL = attrs[@"url"];
        _currentPodcast.title = attrs[@"title"];
        NSString *rankStr = attrs[@"rank"];
        if (rankStr) _currentPodcast.rank = (int32_t)[rankStr integerValue];
        _currentPodcast.parked = [attrs[@"parked"] isEqualToString:@"true"];
        _currentPodcast.username = attrs[@"username"];
        _currentPodcast.password = attrs[@"password"];
    }
    // <episode media="..." guid="..." feedUrl="..."> inside podcast
    else if ([path isEqualToString:@"instacast/podcasts/podcast/episodes/episode"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        _currentEpisode = [[ICBackupEpisode alloc] init];
        _currentEpisode.mediaURL = attrs[@"media"];
        _currentEpisode.guid = attrs[@"guid"];
        _currentEpisode.feedURL = attrs[@"feedUrl"];
    }
    // <bookmark position="..." title="..." episodeGuid="..." feedUrl="..."/>
    else if ([path isEqualToString:@"instacast/bookmarks/bookmark"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        ICBackupBookmark *bm = [[ICBackupBookmark alloc] init];
        bm.position = [attrs[@"position"] doubleValue];
        bm.title = attrs[@"title"];
        bm.episodeGuid = attrs[@"episodeGuid"];
        bm.feedURL = attrs[@"feedUrl"];
        [_backupData.bookmarks addObject:bm];
    }
    // <episode media="..." guid="..." feedUrl="..."/> inside upnext
    else if ([path isEqualToString:@"instacast/upnext/episode"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        ICBackupEpisode *ep = [[ICBackupEpisode alloc] init];
        ep.mediaURL = attrs[@"media"];
        ep.guid = attrs[@"guid"];
        ep.feedURL = attrs[@"feedUrl"];
        [_backupData.upNextEpisodes addObject:ep];
    }
    // <nowplaying media="..." guid="..." feedUrl="..." position="..."/>
    else if ([path isEqualToString:@"instacast/nowplaying"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        ICBackupEpisode *np = [[ICBackupEpisode alloc] init];
        np.mediaURL = attrs[@"media"];
        np.guid = attrs[@"guid"];
        np.feedURL = attrs[@"feedUrl"];
        np.position = (int32_t)[attrs[@"position"] integerValue];
        _backupData.nowPlaying = np;
    }
    // <episode .../> inside appleWatchEpisodes
    else if ([path isEqualToString:@"instacast/appleWatchEpisodes/episode"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        ICBackupAppleWatchEpisode *watchEpisode = [[ICBackupAppleWatchEpisode alloc] init];
        watchEpisode.episodeHash = attrs[@"episodeHash"];
        watchEpisode.guid = attrs[@"guid"];
        watchEpisode.feedURL = attrs[@"feedUrl"];
        watchEpisode.feedIdentifier = attrs[@"feedIdentifier"];
        watchEpisode.selectionSource = attrs[@"selectionSource"];
        watchEpisode.watchAddedDate = [self dateFromString:attrs[@"watchAddedDate"]];
        watchEpisode.lastPhonePosition = (int32_t)[attrs[@"lastPhonePosition"] integerValue];
        watchEpisode.lastPhonePositionDate = [self dateFromString:attrs[@"lastPhonePositionDate"]];
        watchEpisode.lastWatchPosition = (int32_t)[attrs[@"lastWatchPosition"] integerValue];
        watchEpisode.lastWatchPositionDate = [self dateFromString:attrs[@"lastWatchPositionDate"]];
        watchEpisode.watchConsumed = [attrs[@"watchConsumed"] isEqualToString:@"true"];
        watchEpisode.watchConsumedDate = [self dateFromString:attrs[@"watchConsumedDate"]];
        [_backupData.appleWatchEpisodes addObject:watchEpisode];
    }
    // <playlist name="..." rank="...">
    else if ([path isEqualToString:@"instacast/playlists/playlist"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        _currentPlaylist = [[ICBackupPlaylist alloc] init];
        _currentPlaylist.name = attrs[@"name"];
        NSString *rankStr = attrs[@"rank"];
        if (rankStr) _currentPlaylist.rank = (int32_t)[rankStr integerValue];
    }
    // <episode ...> inside playlist
    else if ([path isEqualToString:@"instacast/playlists/playlist/episode"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        ICBackupEpisode *ep = [[ICBackupEpisode alloc] init];
        ep.mediaURL = attrs[@"media"];
        ep.guid = attrs[@"guid"];
        ep.feedURL = attrs[@"feedUrl"];
        [_currentPlaylist.episodes addObject:ep];
    }
    // <setting key="..." value="..."/> inside podcast/settings
    else if ([elementName isEqualToString:@"setting"] && [path isEqualToString:@"instacast/podcasts/podcast/settings/setting"] && _currentPodcast) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        NSString *key = attrs[@"key"];
        NSString *value = attrs[@"value"];
        NSString *type = attrs[@"type"];
        if (key.length > 0 && value != nil) {
            if (!_currentPodcast.settings) {
                _currentPodcast.settings = [NSMutableDictionary dictionary];
            }
            _currentPodcast.settings[key] = value;
            if (type.length > 0) {
                _currentPodcast.settingTypes[key] = type;
            }
        }
    }
    // <episodeList uid="..." name="..." icon="..." rank="...">
    else if ([path isEqualToString:@"instacast/episodeLists/episodeList"]) {
        if (![self.budget consumeObjectWithParser:parser]) return;
        _currentEpisodeList = [[ICBackupEpisodeList alloc] init];
        _currentEpisodeList.uid = attrs[@"uid"];
        _currentEpisodeList.name = attrs[@"name"];
        _currentEpisodeList.icon = attrs[@"icon"];
        NSString *rankStr = attrs[@"rank"];
        if (rankStr) _currentEpisodeList.rank = (int32_t)[rankStr integerValue];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (![self.budget consumeCharacters:string parser:parser]) {
        return;
    }
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
    // EpisodeList child elements
    else if ([path hasPrefix:@"instacast/episodeLists/episodeList/"] && _currentEpisodeList) {
        if ([elementName isEqualToString:@"audio"]) _currentEpisodeList.audio = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"video"]) _currentEpisodeList.video = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"downloaded"]) _currentEpisodeList.downloaded = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"downloading"]) _currentEpisodeList.downloading = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"notDownloaded"]) _currentEpisodeList.notDownloaded = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"unplayed"]) _currentEpisodeList.unplayed = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"unfinished"]) _currentEpisodeList.unfinished = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"played"]) _currentEpisodeList.played = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"starred"]) _currentEpisodeList.starred = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"notStarred"]) _currentEpisodeList.notStarred = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"orderBy"]) _currentEpisodeList.orderBy = text;
        else if ([elementName isEqualToString:@"descending"]) _currentEpisodeList.descending = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"groupByPodcast"]) _currentEpisodeList.groupByPodcast = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"continuousPlayback"]) _currentEpisodeList.continuousPlayback = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"usePodcastArtwork"]) _currentEpisodeList.usePodcastArtwork = [text isEqualToString:@"true"];
        else if ([elementName isEqualToString:@"feedUrl"] && [path isEqualToString:@"instacast/episodeLists/episodeList/includedFeeds/feedUrl"]) {
            if (text.length > 0) {
                if (![self.budget consumeObjectWithParser:parser]) return;
                if (!_currentEpisodeList.includedFeedURLs) {
                    _currentEpisodeList.includedFeedURLs = [NSMutableArray array];
                }
                [_currentEpisodeList.includedFeedURLs addObject:text];
            }
        }
    }
    // Settings child elements (inside podcast/settings)
    // New format: <setting key="..." value="..."/> handled in didStartElement
    // Old format fallback: <keyName>value</keyName> for backward compatibility
    else if ([path hasPrefix:@"instacast/podcasts/podcast/settings/"] && _currentPodcast && ![elementName isEqualToString:@"setting"]) {
        if (text.length > 0) {
            if (![self.budget consumeObjectWithParser:parser]) return;
            if (!_currentPodcast.settings) {
                _currentPodcast.settings = [NSMutableDictionary dictionary];
            }
            _currentPodcast.settings[elementName] = text;
        }
    }
    // Global settings child elements
    else if ([path hasPrefix:@"instacast/settings/"] && ![elementName isEqualToString:@"manualFeedOrder"] && ![elementName isEqualToString:@"feedUrl"] && ![elementName isEqualToString:@"mainMenuListUIDs"] && ![elementName isEqualToString:@"uid"] && ![elementName isEqualToString:@"enabledPlaybackSpeeds"] && ![elementName isEqualToString:@"speed"]) {
        if (text.length > 0) {
            if (![self.budget consumeObjectWithParser:parser]) return;
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
            if (![self.budget consumeObjectWithParser:parser]) return;
            if (!_backupData.settings.manualFeedOrder) {
                _backupData.settings.manualFeedOrder = [NSMutableArray array];
            }
            [_backupData.settings.manualFeedOrder addObject:text];
        }
    }
    // uid inside mainMenuListUIDs
    else if ([path isEqualToString:@"instacast/settings/mainMenuListUIDs/uid"]) {
        if (text.length > 0) {
            if (![self.budget consumeObjectWithParser:parser]) return;
            if (!_backupData.settings.mainMenuListUIDs) {
                _backupData.settings.mainMenuListUIDs = [NSMutableArray array];
            }
            [_backupData.settings.mainMenuListUIDs addObject:text];
        }
    }
    // speed inside enabledPlaybackSpeeds
    else if ([path isEqualToString:@"instacast/settings/enabledPlaybackSpeeds/speed"]) {
        if (text.length > 0) {
            if (![self.budget consumeObjectWithParser:parser]) return;
            if (!_backupData.settings.enabledPlaybackSpeeds) {
                _backupData.settings.enabledPlaybackSpeeds = [NSMutableArray array];
            }
            [_backupData.settings.enabledPlaybackSpeeds addObject:@([text integerValue])];
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
    // Close episodeList
    else if ([path isEqualToString:@"instacast/episodeLists/episodeList"]) {
        if (_currentEpisodeList) {
            [_backupData.episodeLists addObject:_currentEpisodeList];
        }
        _currentEpisodeList = nil;
    }

    [_elementStack removeLastObject];
    [self.budget finishElement];
}

- (NSData *)parser:(NSXMLParser *)parser
resolveExternalEntityName:(NSString *)name
          systemID:(NSString *)systemID
{
    [self.budget rejectEntityWithParser:parser];
    return nil;
}

- (void)parser:(NSXMLParser *)parser
foundInternalEntityDeclarationWithName:(NSString *)name
         value:(NSString *)value
{
    [self.budget rejectEntityWithParser:parser];
}

- (void)parser:(NSXMLParser *)parser
foundExternalEntityDeclarationWithName:(NSString *)name
      publicID:(NSString *)publicID
      systemID:(NSString *)systemID
{
    [self.budget rejectEntityWithParser:parser];
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
        NSError *validationError = nil;
        if (![ICXMLImportLimits validateData:data error:&validationError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, validationError);
            });
            return;
        }

        InstacastBackupParserDelegate *delegate = [[InstacastBackupParserDelegate alloc] init];

        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        parser.delegate = delegate;
        parser.shouldResolveExternalEntities = NO;

        BOOL success = [parser parse];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                completion(delegate.backupData, nil);
            } else {
                completion(nil, delegate.budget.error ?: [parser parserError]);
            }
        });
    });
}

@end
