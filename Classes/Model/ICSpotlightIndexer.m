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

@implementation ICSpotlightIndexer

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
        @"summary": ICSpotlightCleanText(feed.summary ?: feed.fulltext),
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

    NSMutableArray<NSString*>* searchableStrings = [[NSMutableArray alloc] init];
    NSMutableOrderedSet<NSString*>* keywords = [[NSMutableOrderedSet alloc] init];

    ICSpotlightAppendString(searchableStrings, episode.title);
    ICSpotlightAppendString(searchableStrings, episode.subtitle);
    ICSpotlightAppendString(searchableStrings, podcastTitle);
    ICSpotlightAppendString(searchableStrings, episode.author ?: episode.feed.author);
    ICSpotlightAppendString(searchableStrings, episode.summary);
    ICSpotlightAppendString(searchableStrings, episode.fulltext);

    ICSpotlightAppendKeyword(keywords, episode.title);
    ICSpotlightAppendKeyword(keywords, podcastTitle);
    ICSpotlightAppendKeyword(keywords, episode.author ?: episode.feed.author);
    ICSpotlightAppendKeyword(keywords, episode.feed.language);

    for (CDChapter* chapter in [episode sortedChapters]) {
        ICSpotlightAppendString(searchableStrings, chapter.title);
        ICSpotlightAppendKeyword(keywords, chapter.title);
    }

    for (NSString* chapterTitle in ICSpotlightGeneratedChapterTitlesForEpisodeHash(objectHash)) {
        ICSpotlightAppendString(searchableStrings, chapterTitle);
        ICSpotlightAppendKeyword(keywords, chapterTitle);
    }

    for (NSDictionary* transcript in episode.transcripts) {
        if (![transcript isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        ICSpotlightAppendString(searchableStrings, transcript[@"title"]);
        ICSpotlightAppendString(searchableStrings, transcript[@"language"]);
        ICSpotlightAppendString(searchableStrings, transcript[@"url"]);
        ICSpotlightAppendKeyword(keywords, transcript[@"title"]);
        ICSpotlightAppendKeyword(keywords, transcript[@"language"]);
    }

    ICSpotlightAppendString(searchableStrings, ICSpotlightTranscriptTextForEpisodeHash(objectHash));

    NSString* searchableText = [searchableStrings componentsJoinedByString:@"\n"];

    return @{
        @"uniqueIdentifier": [ICSpotlightIndexer episodeUniqueIdentifierForObjectHash:objectHash],
        @"domainIdentifier": ICSpotlightDomainIdentifierForSourceURLString(sourceURLString),
        @"title": ICSpotlightString(episode.title),
        @"subtitle": podcastTitle,
        @"summary": ICSpotlightCleanText(episode.summary ?: episode.fulltext),
        @"searchableText": searchableText ?: @"",
        @"keywords": keywords.array,
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
    CSSearchableItemAttributeSet* attributeSet = [[CSSearchableItemAttributeSet alloc] initWithItemContentType:@"public.audio"];
    attributeSet.displayName = snapshot[@"title"];
    attributeSet.title = snapshot[@"title"];
    attributeSet.contentDescription = snapshot[@"summary"];
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
    attributeSet.textContent = [@[ snapshot[@"title"], snapshot[@"subtitle"], snapshot[@"summary"] ] componentsJoinedByString:@"\n"];

    return [[CSSearchableItem alloc] initWithUniqueIdentifier:snapshot[@"uniqueIdentifier"]
                                             domainIdentifier:snapshot[@"domainIdentifier"]
                                                 attributeSet:attributeSet];
}

static CSSearchableItem* ICSpotlightSearchableItemForEpisodeSnapshot(NSDictionary* snapshot)
{
    CSSearchableItemAttributeSet* attributeSet = [[CSSearchableItemAttributeSet alloc] initWithItemContentType:@"public.audio"];
    attributeSet.displayName = snapshot[@"title"];
    attributeSet.title = snapshot[@"title"];
    attributeSet.contentDescription = snapshot[@"summary"];
    attributeSet.containerDisplayName = snapshot[@"subtitle"];
    attributeSet.album = snapshot[@"subtitle"];
    attributeSet.artist = snapshot[@"subtitle"];
    attributeSet.duration = snapshot[@"duration"];
    attributeSet.streamable = snapshot[@"streamable"];
    attributeSet.URL = [NSURL URLWithString:snapshot[@"episodeURL"]];
    attributeSet.thumbnailURL = [NSURL URLWithString:snapshot[@"imageURL"]];
    attributeSet.keywords = snapshot[@"keywords"];
    attributeSet.textContent = snapshot[@"searchableText"];

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
    [self _indexSearchableItems:@[ ICSpotlightSearchableItemForFeedSnapshot(snapshot) ]];
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
    [self _indexSearchableItems:@[ ICSpotlightSearchableItemForEpisodeSnapshot(snapshot) ]];
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
