//
//  ICFTSController.m
//  Instacast
//
//  Created by Martin Hering on 28.08.14.
//
//

#import "ICFTSController.h"

@interface ICFTSController ()
@property (nonatomic, strong) NSURL* searchIndexURL;
@property (nonatomic, strong) FMDatabaseQueue *queue;
@end

@implementation ICFTSController

static NSString* ICFTSString(id value)
{
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSDictionary* ICFTSFeedSnapshot(CDFeed* feed)
{
    NSString* uid = [feed.sourceURL absoluteString];
    if (!uid) {
        return nil;
    }
    return @{
        @"title": ICFTSString(feed.title),
        @"author": ICFTSString(feed.author),
        @"summary": ICFTSString(feed.summary),
        @"uid": uid
    };
}

static NSDictionary* ICFTSEpisodeSnapshot(CDEpisode* episode)
{
    NSString* uid = episode.guid;
    NSString* feedUID = [episode.feed.sourceURL absoluteString];
    if (!uid || !feedUID) {
        return nil;
    }
    return @{
        @"title": ICFTSString(episode.title),
        @"summary": ICFTSString(episode.summary),
        @"fulltext": ICFTSString([episode.fulltext stringByStrippingHTML]),
        @"uid": uid,
        @"feed_uid": feedUID
    };
}

static NSArray* ICFTSTokensForSearchTerm(NSString* searchTerm)
{
    NSMutableArray* tokens = [[NSMutableArray alloc] init];
    NSCharacterSet* separators = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    NSArray* rawTokens = [searchTerm componentsSeparatedByCharactersInSet:separators];
    for(NSString* rawToken in rawTokens) {
        if (rawToken.length > 0) {
            [tokens addObject:rawToken];
        }
    }
    return tokens;
}

static NSString* ICFTSQueryForSearchTerm(NSString* searchTerm, NSArray* columns)
{
    NSArray* tokens = ICFTSTokensForSearchTerm(searchTerm);
    if (tokens.count == 0) {
        return nil;
    }

    NSMutableArray* clauses = [[NSMutableArray alloc] init];
    for(NSString* token in tokens) {
        for(NSString* column in columns) {
            [clauses addObject:[NSString stringWithFormat:@"%@:%@*", column, token]];
        }
    }
    return [clauses componentsJoinedByString:@" OR "];
}

- (void) _replaceFeedSnapshot:(NSDictionary*)feedSnapshot inDatabase:(FMDatabase*)db
{
    NSString* uid = feedSnapshot[@"uid"];
    [db executeUpdate:@"DELETE FROM feeds WHERE uid = ?", uid];
    if (![db executeUpdate:@"INSERT INTO feeds (title, author, summary, uid) VALUES(?,?,?,?)", feedSnapshot[@"title"], feedSnapshot[@"author"], feedSnapshot[@"summary"], uid]) {
        ErrLog(@"%@", [db lastErrorMessage]);
    }
}

- (void) _replaceEpisodeSnapshot:(NSDictionary*)episodeSnapshot inDatabase:(FMDatabase*)db
{
    NSString* uid = episodeSnapshot[@"uid"];
    [db executeUpdate:@"DELETE FROM episodes WHERE uid = ?", uid];
    if (![db executeUpdate:@"INSERT INTO episodes (title, summary, fulltext, uid, feed_uid) VALUES(?,?,?,?,?)", episodeSnapshot[@"title"], episodeSnapshot[@"summary"], episodeSnapshot[@"fulltext"], uid, episodeSnapshot[@"feed_uid"]]) {
        ErrLog(@"%@", [db lastErrorMessage]);
    }
}

- (id) initWithSearchIndexURL:(NSURL*)url
{
    if ((self = [super init])) {
        _searchIndexURL = url;
    }

    return self;
}

- (void) open
{
    self.queue = [FMDatabaseQueue databaseQueueWithPath:[self.searchIndexURL path]];
    [self.queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"CREATE VIRTUAL TABLE IF NOT EXISTS feeds USING fts4(title, author, summary, uid)"];
        [db executeUpdate:@"CREATE VIRTUAL TABLE IF NOT EXISTS episodes USING fts4(title, summary, fulltext, uid, feed_uid)"];
    }];
}


- (void) indexFeeds:(NSArray*)feeds
{
    NSMutableArray* feedSnapshots = [[NSMutableArray alloc] initWithCapacity:feeds.count];
    NSMutableArray* episodeSnapshots = [[NSMutableArray alloc] init];
    for(CDFeed* feed in feeds)
    {
        NSDictionary* feedSnapshot = ICFTSFeedSnapshot(feed);
        if (feedSnapshot) {
            [feedSnapshots addObject:feedSnapshot];
        }
        for(CDEpisode* episode in feed.episodes) {
            NSDictionary* episodeSnapshot = ICFTSEpisodeSnapshot(episode);
            if (episodeSnapshot) {
                [episodeSnapshots addObject:episodeSnapshot];
            }
        }
    }

    [self.queue inDatabase:^(FMDatabase *db) {
        [db beginTransaction];
        for(NSDictionary* feedSnapshot in feedSnapshots)
        {
            @autoreleasepool {
                [self _replaceFeedSnapshot:feedSnapshot inDatabase:db];
            }
        }
        for(NSDictionary* episodeSnapshot in episodeSnapshots)
        {
            @autoreleasepool {
                [self _replaceEpisodeSnapshot:episodeSnapshot inDatabase:db];
            }
        }
        [db commit];
    }];
}



- (void) addFeed:(CDFeed*)feed
{
    NSDictionary* feedSnapshot = ICFTSFeedSnapshot(feed);
    if (!feedSnapshot) {
        return;
    }

    [self.queue inDatabase:^(FMDatabase *db) {
        [self _replaceFeedSnapshot:feedSnapshot inDatabase:db];
    }];
}

- (void) updateFeed:(CDFeed*)feed
{
    [self addFeed:feed];
}

- (void) removeFeed:(CDFeed*)feed
{
    NSString* feedUID = [feed.sourceURL absoluteString];
    if (!feedUID) {
        return;
    }

    [self.queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"DELETE FROM feeds WHERE uid = ?", feedUID];
        [db executeUpdate:@"DELETE FROM episodes WHERE feed_uid = ?", feedUID];
    }];
}

- (void) addEpisode:(CDEpisode*)episode
{
    NSDictionary* episodeSnapshot = ICFTSEpisodeSnapshot(episode);
    if (!episodeSnapshot) {
        return;
    }

    [self.queue inDatabase:^(FMDatabase *db) {
        [self _replaceEpisodeSnapshot:episodeSnapshot inDatabase:db];
    }];
}

- (void) updateEpisode:(CDEpisode*)episode
{
    [self addEpisode:episode];
}

- (void) removeEpisode:(CDEpisode*)episode
{
    NSString* episodeUID = episode.guid;
    if (!episodeUID) {
        return;
    }

    [self.queue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:@"DELETE FROM episodes WHERE uid = ?", episodeUID];
    }];
}

#pragma mark -

- (NSSet*) feedUIDsForSearchTerm:(NSString*)searchTerm
{
    __block NSMutableSet* uids = [[NSMutableSet alloc] init];
    NSString* feedSearchQuery = ICFTSQueryForSearchTerm(searchTerm, @[ @"title", @"author", @"summary" ]);
    NSString* episodeSearchQuery = ICFTSQueryForSearchTerm(searchTerm, @[ @"title", @"summary", @"fulltext" ]);
    if (!feedSearchQuery && !episodeSearchQuery) {
        return uids;
    }
    
    if (feedSearchQuery) {
        [self.queue inDatabase:^(FMDatabase *db) {
            FMResultSet *rs = [db executeQuery:@"SELECT uid FROM feeds WHERE feeds MATCH ?", feedSearchQuery];
            while ([rs next]) {
                NSString* uid = [rs stringForColumn:@"uid"];
                if (uid) {
                    [uids addObject:uid];
                }
            }
            [rs close];
        }];
    }
    
    if (episodeSearchQuery) {
        [self.queue inDatabase:^(FMDatabase *db) {
            FMResultSet *rs = [db executeQuery:@"SELECT DISTINCT feed_uid FROM episodes WHERE episodes MATCH ?", episodeSearchQuery];
            while ([rs next]) {
                NSString* uid = [rs stringForColumn:@"feed_uid"];
                if (uid) {
                    [uids addObject:uid];
                }
            }
            [rs close];
        }];
    }
    
    return uids;
}

- (NSSet*) episodeUIDsForSearchTerm:(NSString*)searchTerm
{
    __block NSMutableSet* uids = [[NSMutableSet alloc] init];
    NSString* searchQuery = ICFTSQueryForSearchTerm(searchTerm, @[ @"title", @"summary", @"fulltext" ]);
    if (!searchQuery) {
        return uids;
    }
    
    [self.queue inDatabase:^(FMDatabase *db) {
        FMResultSet *rs = [db executeQuery:@"SELECT DISTINCT uid FROM episodes WHERE episodes MATCH ?", searchQuery];
        while ([rs next]) {
            NSString* uid = [rs stringForColumn:@"uid"];
            if (uid) {
                [uids addObject:uid];
            }
        }
        [rs close];
    }];
    
    return uids;
}
@end
