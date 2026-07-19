//
//  ICSpotlightIndexer.m
//  Instacast
//

#import "ICSpotlightIndexer.h"

#import <CoreSpotlight/CoreSpotlight.h>
#import <CoreSpotlight/CSSearchableItemAttributeSet_Documents.h>
#import <CoreSpotlight/CSSearchableItemAttributeSet_General.h>
#import <CoreSpotlight/CSSearchableItemAttributeSet_Media.h>
#import <CoreSpotlight/CSSearchableItemAttributeSet_Messaging.h>

#import "CDChapter.h"
#import "CDEpisode.h"
#import "CDFeed.h"
#import "InstacastPlus-Swift.h"
#import "NSString+VMFoundation.h"

static NSString* const ICSpotlightPodcastPrefix = @"podcast:";
static NSString* const ICSpotlightEpisodePrefix = @"episode:";
static NSString* const ICSpotlightDomainPrefix = @"com.iteconomy.instacastplus.feed.";
static NSUInteger const ICSpotlightIndexBatchSize = 80;

@interface ICSpotlightIndexer ()
// Serial background queue for everything expensive: HTML stripping, reading transcript/chapter
// files from disk and building CSSearchableItems. The Core-Data reads (raw snapshots) stay on
// the calling thread; running the rest inline in the main-context ObjectsDidChange handler
// stalled the UI during every feed refresh.
@property (nonatomic, strong) dispatch_queue_t indexQueue;
@end

@implementation ICSpotlightIndexer

- (instancetype)init
{
    if ((self = [super init])) {
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _indexQueue = dispatch_queue_create("com.iteconomy.instacastplus.spotlight-index", attributes);
    }
    return self;
}

+ (NSString*)podcastUniqueIdentifierForSourceURLString:(NSString*)sourceURLString
{
    if (sourceURLString.length == 0) {
        return nil;
    }
    return [ICSpotlightPodcastPrefix stringByAppendingString:sourceURLString];
}

+ (NSString*)episodeUniqueIdentifierForObjectHash:(NSString*)objectHash
{
    if (objectHash.length == 0) {
        return nil;
    }
    return [ICSpotlightEpisodePrefix stringByAppendingString:objectHash];
}

+ (NSString*)sourceURLStringFromPodcastUniqueIdentifier:(NSString*)uniqueIdentifier
{
    if (![uniqueIdentifier hasPrefix:ICSpotlightPodcastPrefix]) {
        return nil;
    }
    return [uniqueIdentifier substringFromIndex:ICSpotlightPodcastPrefix.length];
}

+ (NSString*)objectHashFromEpisodeUniqueIdentifier:(NSString*)uniqueIdentifier
{
    if (![uniqueIdentifier hasPrefix:ICSpotlightEpisodePrefix]) {
        return nil;
    }
    return [uniqueIdentifier substringFromIndex:ICSpotlightEpisodePrefix.length];
}

static NSString* ICSpotlightString(id value)
{
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSString* ICSpotlightCleanText(id value)
{
    NSString* string = ICSpotlightString(value);
    if (string.length == 0) {
        return @"";
    }
    return [string stringByStrippingHTML] ?: string;
}

static void ICSpotlightAppendString(NSMutableArray<NSString*>* strings, id value)
{
    NSString* string = ICSpotlightCleanText(value);
    if (string.length > 0) {
        [strings addObject:string];
    }
}

static void ICSpotlightAppendKeyword(NSMutableOrderedSet<NSString*>* keywords, id value)
{
    NSString* string = ICSpotlightCleanText(value);
    if (string.length > 0) {
        [keywords addObject:string];
    }
}

static NSString* ICSpotlightDomainIdentifierForSourceURLString(NSString* sourceURLString)
{
    if (sourceURLString.length == 0) {
        return nil;
    }
    return [ICSpotlightDomainPrefix stringByAppendingString:[sourceURLString MD5Hash]];
}

static NSString* ICSpotlightTranscriptTextForEpisodeHash(NSString* objectHash)
{
    if (objectHash.length == 0) {
        return @"";
    }

    NSURL* srtURL = [ICTranscriptionPaths srtURLFor:objectHash];
    NSString* raw = [NSString stringWithContentsOfURL:srtURL encoding:NSUTF8StringEncoding error:nil];
    if (raw.length == 0) {
        return @"";
    }

    NSMutableArray<NSString*>* textLines = [[NSMutableArray alloc] init];
    NSCharacterSet* decimalDigits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSString* line in [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) {
            continue;
        }
        if ([trimmed rangeOfString:@"-->"].location != NSNotFound) {
            continue;
        }
        if ([[trimmed stringByTrimmingCharactersInSet:decimalDigits] length] == 0) {
            continue;
        }
        [textLines addObject:trimmed];
    }
    return [textLines componentsJoinedByString:@" "];
}

static NSArray<NSString*>* ICSpotlightGeneratedChapterTitlesForEpisodeHash(NSString* objectHash)
{
    if (objectHash.length == 0) {
        return @[];
    }

    NSURL* chaptersURL = [ICTranscriptionPaths chaptersJSONURLFor:objectHash];
    NSData* data = [NSData dataWithContentsOfURL:chaptersURL options:0 error:nil];
    if (data.length == 0) {
        return @[];
    }

    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSArray* chapters = json[@"chapters"];
    if (![chapters isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<NSString*>* titles = [[NSMutableArray alloc] init];
    for (NSDictionary* chapter in chapters) {
        if (![chapter isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString* title = ICSpotlightCleanText(chapter[@"title"]);
        if (title.length > 0) {
            [titles addObject:title];
        }
    }
    return titles;
}

static NSString* ICSpotlightGeneratedSummaryForEpisodeHash(NSString* objectHash)
{
    if (objectHash.length == 0) {
        return @"";
    }

    NSURL* analysisURL = [ICTranscriptionPaths analysisJSONURLFor:objectHash];
    NSData* data = [NSData dataWithContentsOfURL:analysisURL options:0 error:nil];
    if (data.length == 0) {
        return @"";
    }

    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return @"";
    }

    NSString* summary = ICSpotlightString(json[@"summary"]);
    return [summary stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Raw snapshots read ONLY Core-Data values (must run on the context's thread) and defer all
// text cleaning and file I/O to the searchable-item builders, which run on the index queue.
static NSDictionary* ICSpotlightFeedSnapshot(CDFeed* feed)
{
    NSString* sourceURLString = [feed.sourceURL absoluteString];
    if (sourceURLString.length == 0 || !feed.subscribed) {
        return nil;
    }

    NSString* title = ICSpotlightString(feed.displayTitle ?: feed.title);
    return @{
        @"uniqueIdentifier": [ICSpotlightIndexer podcastUniqueIdentifierForSourceURLString:sourceURLString],
        @"domainIdentifier": ICSpotlightDomainIdentifierForSourceURLString(sourceURLString),
        @"title": title,
        @"subtitle": ICSpotlightString(feed.author),
        @"summary": ICSpotlightString(feed.summary ?: feed.fulltext),
        @"sourceURL": sourceURLString,
        @"imageURL": [feed.imageURL absoluteString] ?: @"",
        @"pubDate": feed.pubDate ?: [NSNull null],
        @"modifiedDate": feed.lastUpdate ?: [NSNull null],
    };
}

static NSDictionary* ICSpotlightEpisodeSnapshot(CDEpisode* episode)
{
    NSString* objectHash = episode.objectHash;
    NSString* sourceURLString = [episode.feed.sourceURL absoluteString];
    if (objectHash.length == 0 || sourceURLString.length == 0 || !episode.feed.subscribed) {
        return nil;
    }

    NSString* podcastTitle = ICSpotlightString(episode.feed.displayTitle ?: episode.feed.title);
    NSString* imageURL = [episode.imageURL absoluteString] ?: [episode.feed.imageURL absoluteString] ?: @"";

    NSMutableArray<NSString*>* chapterTitles = [[NSMutableArray alloc] init];
    for (CDChapter* chapter in [episode sortedChapters]) {
        NSString* chapterTitle = ICSpotlightString(chapter.title);
        if (chapterTitle.length > 0) {
            [chapterTitles addObject:chapterTitle];
        }
    }

    NSMutableArray<NSDictionary*>* transcripts = [[NSMutableArray alloc] init];
    for (NSDictionary* transcript in episode.transcripts) {
        if ([transcript isKindOfClass:[NSDictionary class]]) {
            [transcripts addObject:transcript];
        }
    }

    return @{
        @"uniqueIdentifier": [ICSpotlightIndexer episodeUniqueIdentifierForObjectHash:objectHash],
        @"domainIdentifier": ICSpotlightDomainIdentifierForSourceURLString(sourceURLString),
        @"objectHash": objectHash,
        @"title": ICSpotlightString(episode.title),
        @"episodeSubtitle": ICSpotlightString(episode.subtitle),
        @"subtitle": podcastTitle,
        @"author": ICSpotlightString(episode.author ?: episode.feed.author),
        @"language": ICSpotlightString(episode.feed.language),
        @"summary": ICSpotlightString(episode.summary),
        @"fulltext": ICSpotlightString(episode.fulltext),
        @"chapterTitles": chapterTitles,
        @"transcripts": transcripts,
        @"sourceURL": sourceURLString,
        @"episodeURL": [episode.linkURL absoluteString] ?: @"",
        @"imageURL": imageURL,
        @"duration": @(episode.duration),
        @"pubDate": episode.pubDate ?: [NSNull null],
        @"downloadedDate": episode.lastDownloaded ?: [NSNull null],
        @"streamable": @(YES),
    };
}

static CSSearchableItem* ICSpotlightSearchableItemForFeedSnapshot(NSDictionary* snapshot)
{
    NSString* summary = ICSpotlightCleanText(snapshot[@"summary"]);

    CSSearchableItemAttributeSet* attributeSet = [[CSSearchableItemAttributeSet alloc] initWithItemContentType:@"public.audio"];
    attributeSet.displayName = snapshot[@"title"];
    attributeSet.title = snapshot[@"title"];
    attributeSet.contentDescription = summary;
    attributeSet.artist = snapshot[@"subtitle"];
    attributeSet.URL = [NSURL URLWithString:snapshot[@"sourceURL"]];
    attributeSet.streamable = @(YES);
    attributeSet.thumbnailURL = [NSURL URLWithString:snapshot[@"imageURL"]];

    if (![snapshot[@"pubDate"] isKindOfClass:[NSNull class]]) {
        attributeSet.contentCreationDate = snapshot[@"pubDate"];
    }
    if (![snapshot[@"modifiedDate"] isKindOfClass:[NSNull class]]) {
        attributeSet.contentModificationDate = snapshot[@"modifiedDate"];
    }

    NSMutableArray* keywords = [[NSMutableArray alloc] init];
    ICSpotlightAppendString(keywords, snapshot[@"title"]);
    ICSpotlightAppendString(keywords, snapshot[@"subtitle"]);
    attributeSet.keywords = keywords;
    attributeSet.textContent = [@[ snapshot[@"title"], snapshot[@"subtitle"], summary ] componentsJoinedByString:@"\n"];

    return [[CSSearchableItem alloc] initWithUniqueIdentifier:snapshot[@"uniqueIdentifier"]
                                             domainIdentifier:snapshot[@"domainIdentifier"]
                                                 attributeSet:attributeSet];
}

static CSSearchableItem* ICSpotlightSearchableItemForEpisodeSnapshot(NSDictionary* snapshot)
{
    NSString* objectHash = snapshot[@"objectHash"];

    NSMutableArray<NSString*>* searchableStrings = [[NSMutableArray alloc] init];
    NSMutableOrderedSet<NSString*>* keywords = [[NSMutableOrderedSet alloc] init];

    ICSpotlightAppendString(searchableStrings, snapshot[@"title"]);
    ICSpotlightAppendString(searchableStrings, snapshot[@"episodeSubtitle"]);
    ICSpotlightAppendString(searchableStrings, snapshot[@"subtitle"]);
    ICSpotlightAppendString(searchableStrings, snapshot[@"author"]);
    ICSpotlightAppendString(searchableStrings, snapshot[@"summary"]);
    ICSpotlightAppendString(searchableStrings, snapshot[@"fulltext"]);

    NSString* generatedSummary = ICSpotlightGeneratedSummaryForEpisodeHash(objectHash);
    ICSpotlightAppendString(searchableStrings, generatedSummary);

    ICSpotlightAppendKeyword(keywords, snapshot[@"title"]);
    ICSpotlightAppendKeyword(keywords, snapshot[@"subtitle"]);
    ICSpotlightAppendKeyword(keywords, snapshot[@"author"]);
    ICSpotlightAppendKeyword(keywords, snapshot[@"language"]);

    for (NSString* chapterTitle in snapshot[@"chapterTitles"]) {
        ICSpotlightAppendString(searchableStrings, chapterTitle);
        ICSpotlightAppendKeyword(keywords, chapterTitle);
    }

    for (NSString* chapterTitle in ICSpotlightGeneratedChapterTitlesForEpisodeHash(objectHash)) {
        ICSpotlightAppendString(searchableStrings, chapterTitle);
        ICSpotlightAppendKeyword(keywords, chapterTitle);
    }

    for (NSDictionary* transcript in snapshot[@"transcripts"]) {
        ICSpotlightAppendString(searchableStrings, transcript[@"title"]);
        ICSpotlightAppendString(searchableStrings, transcript[@"language"]);
        ICSpotlightAppendString(searchableStrings, transcript[@"url"]);
        ICSpotlightAppendKeyword(keywords, transcript[@"title"]);
        ICSpotlightAppendKeyword(keywords, transcript[@"language"]);
    }

    ICSpotlightAppendString(searchableStrings, ICSpotlightTranscriptTextForEpisodeHash(objectHash));

    NSString* fallbackSummary = ICSpotlightString(snapshot[@"summary"]);
    NSString* publisherSummary = ICSpotlightCleanText(fallbackSummary.length > 0 ? fallbackSummary : snapshot[@"fulltext"]);
    NSString* summary = generatedSummary.length > 0 ? ICSpotlightCleanText(generatedSummary) : publisherSummary;

    CSSearchableItemAttributeSet* attributeSet = [[CSSearchableItemAttributeSet alloc] initWithItemContentType:@"public.audio"];
    attributeSet.displayName = snapshot[@"title"];
    attributeSet.title = snapshot[@"title"];
    attributeSet.contentDescription = summary;
    attributeSet.containerDisplayName = snapshot[@"subtitle"];
    attributeSet.album = snapshot[@"subtitle"];
    attributeSet.artist = snapshot[@"subtitle"];
    attributeSet.duration = snapshot[@"duration"];
    attributeSet.streamable = snapshot[@"streamable"];
    attributeSet.URL = [NSURL URLWithString:snapshot[@"episodeURL"]];
    attributeSet.thumbnailURL = [NSURL URLWithString:snapshot[@"imageURL"]];
    attributeSet.keywords = keywords.array;
    attributeSet.textContent = [searchableStrings componentsJoinedByString:@"\n"];

    if (![snapshot[@"pubDate"] isKindOfClass:[NSNull class]]) {
        attributeSet.contentCreationDate = snapshot[@"pubDate"];
    }
    if (![snapshot[@"downloadedDate"] isKindOfClass:[NSNull class]]) {
        attributeSet.downloadedDate = snapshot[@"downloadedDate"];
    }

    return [[CSSearchableItem alloc] initWithUniqueIdentifier:snapshot[@"uniqueIdentifier"]
                                             domainIdentifier:snapshot[@"domainIdentifier"]
                                                 attributeSet:attributeSet];
}

- (void)_indexSearchableItems:(NSArray<CSSearchableItem*>*)items
{
    if (items.count == 0) {
        return;
    }

    [[CSSearchableIndex defaultSearchableIndex] indexSearchableItems:items completionHandler:^(NSError* error) {
        if (error) {
            ErrLog(@"Spotlight indexing failed: %@", error);
        }
    }];
}

- (void)indexFeeds:(NSArray*)feeds
{
    NSMutableArray<CSSearchableItem*>* items = [[NSMutableArray alloc] init];
    for (CDFeed* feed in feeds) {
        @autoreleasepool {
            NSDictionary* feedSnapshot = ICSpotlightFeedSnapshot(feed);
            if (feedSnapshot) {
                [items addObject:ICSpotlightSearchableItemForFeedSnapshot(feedSnapshot)];
            }

            if (feed.subscribed) {
                for (CDEpisode* episode in feed.episodes) {
                    NSDictionary* episodeSnapshot = ICSpotlightEpisodeSnapshot(episode);
                    if (episodeSnapshot) {
                        [items addObject:ICSpotlightSearchableItemForEpisodeSnapshot(episodeSnapshot)];
                    }

                    if (items.count >= ICSpotlightIndexBatchSize) {
                        [self _indexSearchableItems:[items copy]];
                        [items removeAllObjects];
                    }
                }
            }

            if (items.count >= ICSpotlightIndexBatchSize) {
                [self _indexSearchableItems:[items copy]];
                [items removeAllObjects];
            }
        }
    }
    [self _indexSearchableItems:items];
}

- (void)addFeed:(CDFeed*)feed
{
    NSDictionary* snapshot = ICSpotlightFeedSnapshot(feed);
    if (!snapshot) {
        [self removeFeed:feed];
        return;
    }
    dispatch_async(self.indexQueue, ^{
        [self _indexSearchableItems:@[ ICSpotlightSearchableItemForFeedSnapshot(snapshot) ]];
    });
}

- (void)updateFeed:(CDFeed*)feed
{
    [self addFeed:feed];
}

- (void)removeFeed:(CDFeed*)feed
{
    NSString* sourceURLString = [feed.sourceURL absoluteString];
    NSString* domainIdentifier = ICSpotlightDomainIdentifierForSourceURLString(sourceURLString);
    if (domainIdentifier.length == 0) {
        return;
    }

    [[CSSearchableIndex defaultSearchableIndex] deleteSearchableItemsWithDomainIdentifiers:@[ domainIdentifier ]
                                                                         completionHandler:^(NSError* error) {
        if (error) {
            ErrLog(@"Spotlight feed removal failed: %@", error);
        }
    }];
}

- (void)addEpisode:(CDEpisode*)episode
{
    NSDictionary* snapshot = ICSpotlightEpisodeSnapshot(episode);
    if (!snapshot) {
        [self removeEpisode:episode];
        return;
    }
    dispatch_async(self.indexQueue, ^{
        [self _indexSearchableItems:@[ ICSpotlightSearchableItemForEpisodeSnapshot(snapshot) ]];
    });
}

- (void)updateEpisode:(CDEpisode*)episode
{
    [self addEpisode:episode];
}

- (void)removeEpisode:(CDEpisode*)episode
{
    NSString* uniqueIdentifier = [ICSpotlightIndexer episodeUniqueIdentifierForObjectHash:episode.objectHash];
    if (uniqueIdentifier.length == 0) {
        return;
    }

    [[CSSearchableIndex defaultSearchableIndex] deleteSearchableItemsWithIdentifiers:@[ uniqueIdentifier ]
                                                                   completionHandler:^(NSError* error) {
        if (error) {
            ErrLog(@"Spotlight episode removal failed: %@", error);
        }
    }];
}

@end
