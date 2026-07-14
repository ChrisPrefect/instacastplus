//
//  ICFTSController.m
//  Instacast
//
//  Created by Martin Hering on 28.08.14.
//
//

#import "ICFTSController.h"
#include <limits.h>
#include <sqlite3.h>
#include <stdint.h>
#include <string.h>
#include <zlib.h>

@interface ICFTSPendingMutation : NSObject
@property (nonatomic) BOOL deletion;
@property (nonatomic) BOOL reindexEpisodes;
@end

@implementation ICFTSPendingMutation
@end

@interface ICFTSSaveChangeSet : NSObject
@property (nonatomic, copy) NSArray<NSDictionary*>* feedSnapshots;
@property (nonatomic, copy) NSArray<NSDictionary*>* episodeSnapshots;
@property (nonatomic, copy) NSArray<NSString*>* deletedFeedUIDs;
@property (nonatomic, copy) NSArray<NSString*>* deletedEpisodeUIDs;
@property (nonatomic, copy) NSSet<NSString*>* reindexEpisodeFeedUIDs;
@end

@implementation ICFTSSaveChangeSet
@end

@interface ICFTSController ()
@property (nonatomic, strong) NSURL* searchIndexURL;
@property (nonatomic, strong) NSURL* dirtyMarkerURL;
@property (nonatomic, strong) FMDatabaseQueue *queue;
// FMDatabaseQueue's inDatabase: is dispatch_SYNC — during a feed refresh the per-episode index
// writes ran as synchronous SQLite writes on the main thread. Single-object writes hop through
// this serial queue instead so the caller returns immediately; FIFO order is preserved.
@property (nonatomic, strong) dispatch_queue_t writeQueue;
@property (nonatomic) BOOL rebuildingIndex;
@property (nonatomic, strong) NSMutableDictionary<NSString*, ICFTSPendingMutation*>* pendingFeedMutations;
@property (nonatomic, strong) NSMutableDictionary<NSString*, ICFTSPendingMutation*>* pendingEpisodeMutations;
@property (nonatomic, strong) NSManagedObjectContext* pendingChangesContext;
@property (nonatomic, strong) NSManagedObjectContext* committedChangesContext;
@property (nonatomic, strong) NSMapTable<NSManagedObjectContext*, ICFTSSaveChangeSet*>* stagedChangesByContext;
@property (nonatomic) NSUInteger pendingCommittedWrites;
@property (nonatomic) BOOL incrementalWriteFailed;
@property (nonatomic) BOOL indexRequiresAuthoritativeRebuild;
@property (nonatomic) NSUInteger requestedRebuildGeneration;
@property (nonatomic) BOOL externalStoreMutationPending;
- (BOOL)_markIndexDirty:(NSError**)error;
- (BOOL)_markIndexClean:(NSError**)error;
@end

@implementation ICFTSController

static const unsigned char kICFTSCompressedContentMagic[4] = { 'I', 'C', 'Z', 1 };
static const int kICFTSCompressedContentHeaderLength = 8;
static const int kICFTSCompressionMinimumLength = 128;

static void ICFTSWriteOriginalLength(unsigned char* header, uint32_t length)
{
    header[4] = (unsigned char)(length >> 24);
    header[5] = (unsigned char)(length >> 16);
    header[6] = (unsigned char)(length >> 8);
    header[7] = (unsigned char)length;
}

static uint32_t ICFTSReadOriginalLength(const unsigned char* header)
{
    return ((uint32_t)header[4] << 24) |
           ((uint32_t)header[5] << 16) |
           ((uint32_t)header[6] << 8) |
           (uint32_t)header[7];
}

static void ICFTSCompressionError(sqlite3_context* context, const char* message, int code)
{
    sqlite3_result_error(context, message, -1);
    sqlite3_result_error_code(context, code);
}

static void ICFTSCompressValue(sqlite3_context* context, int argumentCount, sqlite3_value** arguments)
{
    if (argumentCount != 1) {
        ICFTSCompressionError(context, "Invalid FTS compression argument count", SQLITE_MISUSE);
        return;
    }

    int valueType = sqlite3_value_type(arguments[0]);
    if (valueType == SQLITE_NULL) {
        sqlite3_result_null(context);
        return;
    }
    if (valueType != SQLITE_TEXT) {
        sqlite3_result_value(context, arguments[0]);
        return;
    }

    const unsigned char* source = sqlite3_value_text(arguments[0]);
    int sourceLength = sqlite3_value_bytes(arguments[0]);
    if (!source || sourceLength < kICFTSCompressionMinimumLength) {
        sqlite3_result_text(context, (const char*)source, sourceLength, SQLITE_TRANSIENT);
        return;
    }

    uLongf compressedCapacity = compressBound((uLong)sourceLength);
    sqlite3_uint64 allocationLength = (sqlite3_uint64)kICFTSCompressedContentHeaderLength + compressedCapacity;
    unsigned char* compressed = sqlite3_malloc64(allocationLength);
    if (!compressed) {
        sqlite3_result_error_nomem(context);
        return;
    }

    uLongf compressedLength = compressedCapacity;
    int zlibResult = compress2(compressed + kICFTSCompressedContentHeaderLength,
                               &compressedLength,
                               source,
                               (uLong)sourceLength,
                               Z_DEFAULT_COMPRESSION);
    if (zlibResult != Z_OK) {
        sqlite3_free(compressed);
        ICFTSCompressionError(context, "Could not compress FTS content", SQLITE_ERROR);
        return;
    }

    if (compressedLength + kICFTSCompressedContentHeaderLength >= (uLongf)sourceLength) {
        sqlite3_free(compressed);
        sqlite3_result_text(context, (const char*)source, sourceLength, SQLITE_TRANSIENT);
        return;
    }

    memcpy(compressed, kICFTSCompressedContentMagic, sizeof(kICFTSCompressedContentMagic));
    ICFTSWriteOriginalLength(compressed, (uint32_t)sourceLength);
    sqlite3_result_blob(context,
                        compressed,
                        (int)(compressedLength + kICFTSCompressedContentHeaderLength),
                        sqlite3_free);
}

static void ICFTSUncompressValue(sqlite3_context* context, int argumentCount, sqlite3_value** arguments)
{
    if (argumentCount != 1) {
        ICFTSCompressionError(context, "Invalid FTS uncompression argument count", SQLITE_MISUSE);
        return;
    }

    int valueType = sqlite3_value_type(arguments[0]);
    if (valueType == SQLITE_NULL) {
        sqlite3_result_null(context);
        return;
    }
    if (valueType == SQLITE_TEXT) {
        sqlite3_result_value(context, arguments[0]);
        return;
    }
    if (valueType != SQLITE_BLOB) {
        ICFTSCompressionError(context, "Invalid FTS compressed content type", SQLITE_CORRUPT);
        return;
    }

    const unsigned char* compressed = sqlite3_value_blob(arguments[0]);
    int compressedLength = sqlite3_value_bytes(arguments[0]);
    if (!compressed || compressedLength <= kICFTSCompressedContentHeaderLength ||
        memcmp(compressed, kICFTSCompressedContentMagic, sizeof(kICFTSCompressedContentMagic)) != 0) {
        ICFTSCompressionError(context, "Invalid FTS compressed content header", SQLITE_CORRUPT);
        return;
    }

    uint32_t originalLength = ICFTSReadOriginalLength(compressed);
    int sqliteLengthLimit = sqlite3_limit(sqlite3_context_db_handle(context), SQLITE_LIMIT_LENGTH, -1);
    if (originalLength < (uint32_t)kICFTSCompressionMinimumLength ||
        originalLength > (uint32_t)sqliteLengthLimit || originalLength > INT_MAX) {
        ICFTSCompressionError(context, "Invalid FTS uncompressed content length", SQLITE_CORRUPT);
        return;
    }

    unsigned char* uncompressed = sqlite3_malloc((int)originalLength);
    if (!uncompressed) {
        sqlite3_result_error_nomem(context);
        return;
    }

    uLongf uncompressedLength = (uLongf)originalLength;
    int zlibResult = uncompress(uncompressed,
                                &uncompressedLength,
                                compressed + kICFTSCompressedContentHeaderLength,
                                (uLong)(compressedLength - kICFTSCompressedContentHeaderLength));
    if (zlibResult != Z_OK || uncompressedLength != originalLength) {
        sqlite3_free(uncompressed);
        ICFTSCompressionError(context, "Invalid FTS compressed content payload", SQLITE_CORRUPT);
        return;
    }

    sqlite3_result_text(context, (const char*)uncompressed, (int)uncompressedLength, sqlite3_free);
}

static int ICFTSRegisterCompressionFunctions(sqlite3* database)
{
    int flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC;
    int result = sqlite3_create_function_v2(database,
                                             "ic_fts_compress",
                                             1,
                                             flags,
                                             NULL,
                                             ICFTSCompressValue,
                                             NULL,
                                             NULL,
                                             NULL);
    if (result != SQLITE_OK) {
        return result;
    }
    return sqlite3_create_function_v2(database,
                                      "ic_fts_uncompress",
                                      1,
                                      flags,
                                      NULL,
                                      ICFTSUncompressValue,
                                      NULL,
                                      NULL,
                                      NULL);
}

static NSString* ICFTSString(id value)
{
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSError* ICFTSRebuildError(NSString* description, NSError* underlyingError)
{
    NSMutableDictionary* userInfo = [@{ NSLocalizedDescriptionKey: description } mutableCopy];
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:@"ICFTSController" code:1 userInfo:userInfo];
}

static NSString* ICFTSFeedUID(CDFeed* feed)
{
    NSString* uid = [feed valueForKey:@"sourceURL_"];
    if (![uid isKindOfClass:NSString.class]) {
        uid = nil;
    }
    return uid;
}

static NSDictionary* ICFTSFeedSnapshot(CDFeed* feed)
{
    NSString* uid = ICFTSFeedUID(feed);
    if (!feed.subscribed || uid.length == 0) {
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
    NSString* uid = episode.objectHash;
    NSString* feedUID = ICFTSFeedUID(episode.feed);
    if (!episode.feed.subscribed || uid.length == 0 || feedUID.length == 0 || episode.guid.length == 0) {
        return nil;
    }
    return @{
        @"title": ICFTSString(episode.title),
        @"summary": ICFTSString(episode.summary),
        // Raw fulltext — the HTML stripping is expensive and runs in _replaceEpisodeSnapshot
        // on the database queue, not on the (often main) thread taking the snapshot.
        @"fulltext": ICFTSString(episode.fulltext),
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

- (BOOL) _insertFeedSnapshot:(NSDictionary*)feedSnapshot inDatabase:(FMDatabase*)db
{
    if (![db executeUpdate:@"INSERT INTO feeds (title, author, summary, uid) VALUES(?,?,?,?)", feedSnapshot[@"title"], feedSnapshot[@"author"], feedSnapshot[@"summary"], feedSnapshot[@"uid"]]) {
        ErrLog(@"%@", [db lastErrorMessage]);
        return NO;
    }
    return YES;
}

- (BOOL) _replaceFeedSnapshot:(NSDictionary*)feedSnapshot inDatabase:(FMDatabase*)db
{
    NSString* uid = feedSnapshot[@"uid"];
    if (![db executeUpdate:@"DELETE FROM feeds WHERE uid = ?", uid]) {
        ErrLog(@"%@", [db lastErrorMessage]);
        return NO;
    }
    return [self _insertFeedSnapshot:feedSnapshot inDatabase:db];
}

- (BOOL) _insertEpisodeSnapshot:(NSDictionary*)episodeSnapshot inDatabase:(FMDatabase*)db
{
    NSString* fulltext = [ICFTSString(episodeSnapshot[@"fulltext"]) stringByStrippingHTML] ?: @"";
    if (![db executeUpdate:@"INSERT INTO episodes (title, summary, fulltext, uid, feed_uid) VALUES(?,?,?,?,?)", episodeSnapshot[@"title"], episodeSnapshot[@"summary"], fulltext, episodeSnapshot[@"uid"], episodeSnapshot[@"feed_uid"]]) {
        ErrLog(@"%@", [db lastErrorMessage]);
        return NO;
    }
    return YES;
}

- (BOOL) _replaceEpisodeSnapshot:(NSDictionary*)episodeSnapshot inDatabase:(FMDatabase*)db
{
    NSString* uid = episodeSnapshot[@"uid"];
    if (![db executeUpdate:@"DELETE FROM episodes WHERE uid = ?", uid]) {
        ErrLog(@"%@", [db lastErrorMessage]);
        return NO;
    }
    return [self _insertEpisodeSnapshot:episodeSnapshot inDatabase:db];
}

- (id) initWithSearchIndexURL:(NSURL*)url
{
    if ((self = [super init])) {
        _searchIndexURL = url;
        _dirtyMarkerURL = [url URLByAppendingPathExtension:@"dirty"];
        _indexRequiresAuthoritativeRebuild = ![[NSFileManager defaultManager] fileExistsAtPath:url.path];
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _writeQueue = dispatch_queue_create("com.iteconomy.instacastplus.fts-write", attributes);
        _pendingFeedMutations = [[NSMutableDictionary alloc] init];
        _pendingEpisodeMutations = [[NSMutableDictionary alloc] init];
        _stagedChangesByContext = [NSMapTable weakToStrongObjectsMapTable];
    }

    return self;
}

- (BOOL)indexNeedsRebuild
{
    return self.indexRequiresAuthoritativeRebuild ||
           [[NSFileManager defaultManager] fileExistsAtPath:self.dirtyMarkerURL.path];
}

- (BOOL)prepareForExternalStoreMutation:(NSError**)error
{
    @synchronized (self) {
        if (![self _markIndexDirty:error]) {
            self.incrementalWriteFailed = YES;
            return NO;
        }
        self.indexRequiresAuthoritativeRebuild = YES;
        self.externalStoreMutationPending = YES;
        return YES;
    }
}

- (BOOL)_markIndexDirty:(NSError**)error
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.dirtyMarkerURL.path]) {
        return YES;
    }
    NSData* marker = [@"pending\n" dataUsingEncoding:NSUTF8StringEncoding];
    return [marker writeToURL:self.dirtyMarkerURL options:NSDataWritingAtomic error:error];
}

- (BOOL)_markIndexClean:(NSError**)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.dirtyMarkerURL.path]) {
        return YES;
    }
    return [[NSFileManager defaultManager] removeItemAtURL:self.dirtyMarkerURL error:error];
}

- (void) open
{
    self.queue = [FMDatabaseQueue databaseQueueWithPath:[self.searchIndexURL path]];
    [self.queue inDatabase:^(FMDatabase *db) {
        int registrationResult = ICFTSRegisterCompressionFunctions((sqlite3*)db.sqliteHandle);
        if (registrationResult != SQLITE_OK) {
            self.incrementalWriteFailed = YES;
            self.indexRequiresAuthoritativeRebuild = YES;
            NSError* dirtyMarkerError = nil;
            [self _markIndexDirty:&dirtyMarkerError];
            ErrLog(@"Could not register FTS compression functions: %s", sqlite3_errmsg((sqlite3*)db.sqliteHandle));
            return;
        }

        FMResultSet* schema = [db executeQuery:@"SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name IN ('feeds', 'episodes')"];
        NSMutableDictionary<NSString*, NSString*>* tableSchemas = [NSMutableDictionary dictionary];
        while ([schema next]) {
            NSString* tableName = [schema stringForColumn:@"name"];
            NSString* tableSchema = [[schema stringForColumn:@"sql"] lowercaseString];
            if (tableName && tableSchema) tableSchemas[tableName] = tableSchema;
        }
        [schema close];

        NSString* feedSchema = tableSchemas[@"feeds"];
        NSString* episodeSchema = tableSchemas[@"episodes"];
        BOOL compressedSchema = feedSchema.length > 0 && episodeSchema.length > 0 &&
            [feedSchema rangeOfString:@"compress=ic_fts_compress"].location != NSNotFound &&
            [feedSchema rangeOfString:@"uncompress=ic_fts_uncompress"].location != NSNotFound &&
            [episodeSchema rangeOfString:@"compress=ic_fts_compress"].location != NSNotFound &&
            [episodeSchema rangeOfString:@"uncompress=ic_fts_uncompress"].location != NSNotFound;
        if (!compressedSchema) {
            self.indexRequiresAuthoritativeRebuild = YES;
            NSError* dirtyMarkerError = nil;
            if (![self _markIndexDirty:&dirtyMarkerError]) {
                self.incrementalWriteFailed = YES;
                ErrLog(@"Could not persist the missing FTS index marker: %@", dirtyMarkerError);
                return;
            }
        }
        [db executeUpdate:@"CREATE VIRTUAL TABLE IF NOT EXISTS feeds USING fts4(title, author, summary, uid, compress=ic_fts_compress, uncompress=ic_fts_uncompress)"];
        [db executeUpdate:@"CREATE VIRTUAL TABLE IF NOT EXISTS episodes USING fts4(title, summary, fulltext, uid, feed_uid, compress=ic_fts_compress, uncompress=ic_fts_uncompress)"];
    }];
}

- (void)setCommittedChangesManagedObjectContext:(NSManagedObjectContext*)context
{
    self.committedChangesContext = context;
}

- (BOOL)_recordPendingFeedUID:(NSString*)uid deletion:(BOOL)deletion
{
    @synchronized (self) {
        if (!self.rebuildingIndex) {
            [self.pendingFeedMutations removeObjectForKey:uid];
            return NO;
        }
        ICFTSPendingMutation* mutation = [[ICFTSPendingMutation alloc] init];
        mutation.deletion = deletion;
        self.pendingFeedMutations[uid] = mutation;
        return YES;
    }
}

- (BOOL)_recordPendingEpisodeUID:(NSString*)uid deletion:(BOOL)deletion
{
    @synchronized (self) {
        if (!self.rebuildingIndex) {
            [self.pendingEpisodeMutations removeObjectForKey:uid];
            return NO;
        }
        ICFTSPendingMutation* mutation = [[ICFTSPendingMutation alloc] init];
        mutation.deletion = deletion;
        self.pendingEpisodeMutations[uid] = mutation;
        return YES;
    }
}

- (NSError*)_replaceEpisodesForFeedUIDs:(NSSet<NSString*>*)feedUIDs
                   managedObjectContext:(NSManagedObjectContext*)context
                              database:(FMDatabase*)db
{
    NSError* reindexError = nil;
    for (NSString* feedUID in feedUIDs) {
        if (![db executeUpdate:@"DELETE FROM episodes WHERE feed_uid = ?", feedUID]) {
            return ICFTSRebuildError(@"Could not clear old episodes for a changed podcast.", db.lastError);
        }
    }

    NSString* lastEpisodeHash = nil;
    while (!reindexError) {
        @autoreleasepool {
            NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
            if (lastEpisodeHash) {
                request.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND feed.sourceURL_ IN %@ AND objectHash != nil AND objectHash != \"\" AND guid != nil AND guid != \"\" AND objectHash > %@", feedUIDs, lastEpisodeHash];
            }
            else {
                request.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND feed.sourceURL_ IN %@ AND objectHash != nil AND objectHash != \"\" AND guid != nil AND guid != \"\"", feedUIDs];
            }
            request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"objectHash" ascending:YES]];
            request.fetchLimit = 100;
            request.fetchBatchSize = 100;
            NSArray<CDEpisode*>* episodes = [context executeFetchRequest:request error:&reindexError];
            if (!episodes || episodes.count == 0) break;

            NSMutableSet<NSString*>* pageEpisodeHashes = [[NSMutableSet alloc] init];
            for (CDEpisode* episode in episodes) {
                NSDictionary* snapshot = ICFTSEpisodeSnapshot(episode);
                NSString* uid = snapshot[@"uid"];
                if (uid.length > 0 && ![pageEpisodeHashes containsObject:uid] &&
                    ![self _insertEpisodeSnapshot:snapshot inDatabase:db]) {
                    reindexError = ICFTSRebuildError(@"Could not reindex an episode after its podcast changed.", db.lastError);
                    break;
                }
                if (uid.length > 0) [pageEpisodeHashes addObject:uid];
                [context refreshObject:episode mergeChanges:NO];
            }
            lastEpisodeHash = [episodes.lastObject.objectHash copy];
            if (lastEpisodeHash.length == 0) {
                reindexError = ICFTSRebuildError(@"Could not page through episodes for a changed podcast.", nil);
            }
        }
    }
    return reindexError;
}

- (NSError*)_reindexEpisodesForFeedUIDs:(NSSet<NSString*>*)feedUIDs
                    managedObjectContext:(NSManagedObjectContext*)context
{
    if (feedUIDs.count == 0) return nil;
    if (!context) return ICFTSRebuildError(@"Could not read episodes for a changed podcast.", nil);

    __block NSError* reindexError = nil;
    [context performBlockAndWait:^{
        [self.queue inDatabase:^(FMDatabase *db) {
            if (![db beginTransaction]) {
                reindexError = ICFTSRebuildError(@"Could not start the changed podcast's episode index transaction.", db.lastError);
                return;
            }
            reindexError = [self _replaceEpisodesForFeedUIDs:feedUIDs
                                        managedObjectContext:context
                                                   database:db];
            if (reindexError || ![db commit]) {
                if (!reindexError) {
                    reindexError = ICFTSRebuildError(@"Could not commit the changed podcast's episode index.", db.lastError);
                }
                [db rollback];
            }
        }];
        [context reset];
    }];
    return reindexError;
}

- (NSError*)_drainPendingMutationsWithManagedObjectContext:(NSManagedObjectContext*)context
                                      removeMissingRecords:(BOOL)removeMissingRecords
{
    if (!context) {
        return ICFTSRebuildError(@"Could not read changes that arrived during the FTS rebuild.", nil);
    }

    NSDictionary<NSString*, ICFTSPendingMutation*>* feedMutations;
    NSDictionary<NSString*, ICFTSPendingMutation*>* episodeMutations;
    @synchronized (self) {
        feedMutations = [self.pendingFeedMutations copy];
        episodeMutations = [self.pendingEpisodeMutations copy];
    }
    if (feedMutations.count == 0 && episodeMutations.count == 0) {
        return nil;
    }

    __block NSError* drainError = nil;
    __block NSMutableSet<NSString*>* appliedFeedUIDs = [[NSMutableSet alloc] init];
    __block NSMutableSet<NSString*>* appliedEpisodeUIDs = [[NSMutableSet alloc] init];
    __block NSMutableSet<NSString*>* reindexFeedUIDs = [[NSMutableSet alloc] init];
    [context performBlockAndWait:^{
        NSArray<NSString*>* feedUIDs = feedMutations.allKeys;
        for (NSUInteger start = 0; start < feedUIDs.count && !drainError; start += 100) {
            @autoreleasepool {
                NSRange range = NSMakeRange(start, MIN((NSUInteger)100, feedUIDs.count - start));
                NSArray<NSString*>* pageUIDs = [feedUIDs subarrayWithRange:range];
                NSMutableArray<NSString*>* indexUIDs = [[NSMutableArray alloc] init];
                for (NSString* uid in pageUIDs) {
                    if (!feedMutations[uid].deletion) {
                        [indexUIDs addObject:uid];
                    }
                }

                NSMutableDictionary<NSString*, NSDictionary*>* snapshots = [[NSMutableDictionary alloc] init];
                if (indexUIDs.count > 0) {
                    NSString* lastSourceURL = nil;
                    while (!drainError) {
                        NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
                        if (lastSourceURL) {
                            request.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND sourceURL_ IN %@ AND sourceURL_ > %@", indexUIDs, lastSourceURL];
                        }
                        else {
                            request.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND sourceURL_ IN %@", indexUIDs];
                        }
                        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"sourceURL_" ascending:YES]];
                        request.fetchLimit = 100;
                        request.fetchBatchSize = 100;
                        NSArray<CDFeed*>* feeds = [context executeFetchRequest:request error:&drainError];
                        if (!feeds || feeds.count == 0) break;
                        for (CDFeed* feed in feeds) {
                            NSDictionary* snapshot = ICFTSFeedSnapshot(feed);
                            NSString* uid = snapshot[@"uid"];
                            if (uid && !snapshots[uid]) snapshots[uid] = snapshot;
                        }
                        lastSourceURL = [feeds.lastObject valueForKey:@"sourceURL_"];
                        if (![lastSourceURL isKindOfClass:NSString.class] || lastSourceURL.length == 0) {
                            drainError = ICFTSRebuildError(@"Could not page through pending podcast changes.", nil);
                        }
                    }
                }
                if (drainError) break;

                [self.queue inDatabase:^(FMDatabase *db) {
                    for (NSString* uid in pageUIDs) {
                        ICFTSPendingMutation* mutation = feedMutations[uid];
                        BOOL success = YES;
                        if (mutation.deletion) {
                            success = [db executeUpdate:@"DELETE FROM feeds WHERE uid = ?", uid] &&
                                      [db executeUpdate:@"DELETE FROM episodes WHERE feed_uid = ?", uid];
                        }
                        else if (snapshots[uid]) {
                            success = [self _replaceFeedSnapshot:snapshots[uid] inDatabase:db];
                        }
                        else if (removeMissingRecords) {
                            success = [db executeUpdate:@"DELETE FROM feeds WHERE uid = ?", uid] &&
                                      [db executeUpdate:@"DELETE FROM episodes WHERE feed_uid = ?", uid];
                        }
                        else {
                            continue;
                        }
                        if (!success) {
                            drainError = ICFTSRebuildError(@"Could not apply a podcast change after the FTS rebuild.", db.lastError);
                            break;
                        }
                        if (mutation.reindexEpisodes && snapshots[uid]) {
                            [reindexFeedUIDs addObject:uid];
                        }
                        else {
                            [appliedFeedUIDs addObject:uid];
                        }
                    }
                }];
                [context reset];
            }
        }

        NSArray<NSString*>* episodeUIDs = episodeMutations.allKeys;
        for (NSUInteger start = 0; start < episodeUIDs.count && !drainError; start += 100) {
            @autoreleasepool {
                NSRange range = NSMakeRange(start, MIN((NSUInteger)100, episodeUIDs.count - start));
                NSArray<NSString*>* pageUIDs = [episodeUIDs subarrayWithRange:range];
                NSMutableArray<NSString*>* indexUIDs = [[NSMutableArray alloc] init];
                for (NSString* uid in pageUIDs) {
                    if (!episodeMutations[uid].deletion) {
                        [indexUIDs addObject:uid];
                    }
                }

                NSMutableDictionary<NSString*, NSDictionary*>* snapshots = [[NSMutableDictionary alloc] init];
                if (indexUIDs.count > 0) {
                    NSString* lastEpisodeUID = nil;
                    while (!drainError) {
                        NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                        if (lastEpisodeUID) {
                            request.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND objectHash IN %@ AND objectHash > %@", indexUIDs, lastEpisodeUID];
                        }
                        else {
                            request.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND objectHash IN %@", indexUIDs];
                        }
                        request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"objectHash" ascending:YES]];
                        request.fetchLimit = 100;
                        request.fetchBatchSize = 100;
                        NSArray<CDEpisode*>* episodes = [context executeFetchRequest:request error:&drainError];
                        if (!episodes || episodes.count == 0) break;
                        for (CDEpisode* episode in episodes) {
                            NSDictionary* snapshot = ICFTSEpisodeSnapshot(episode);
                            NSString* uid = snapshot[@"uid"];
                            if (uid && !snapshots[uid]) snapshots[uid] = snapshot;
                        }
                        lastEpisodeUID = episodes.lastObject.objectHash;
                        if (lastEpisodeUID.length == 0) {
                            drainError = ICFTSRebuildError(@"Could not page through pending episode changes.", nil);
                        }
                    }
                }
                if (drainError) break;

                [self.queue inDatabase:^(FMDatabase *db) {
                    for (NSString* uid in pageUIDs) {
                        ICFTSPendingMutation* mutation = episodeMutations[uid];
                        BOOL success = YES;
                        if (mutation.deletion) {
                            success = [db executeUpdate:@"DELETE FROM episodes WHERE uid = ?", uid];
                        }
                        else if (snapshots[uid]) {
                            success = [self _replaceEpisodeSnapshot:snapshots[uid] inDatabase:db];
                        }
                        else if (removeMissingRecords) {
                            success = [db executeUpdate:@"DELETE FROM episodes WHERE uid = ?", uid];
                        }
                        else {
                            continue;
                        }
                        if (!success) {
                            drainError = ICFTSRebuildError(@"Could not apply an episode change after the FTS rebuild.", db.lastError);
                            break;
                        }
                        [appliedEpisodeUIDs addObject:uid];
                    }
                }];
                [context reset];
            }
        }
    }];

    if (!drainError && reindexFeedUIDs.count > 0) {
        drainError = [self _reindexEpisodesForFeedUIDs:reindexFeedUIDs
                                  managedObjectContext:context];
        if (!drainError) {
            [appliedFeedUIDs unionSet:reindexFeedUIDs];
        }
    }

    @synchronized (self) {
        for (NSString* uid in appliedFeedUIDs) {
            if (self.pendingFeedMutations[uid] == feedMutations[uid]) {
                [self.pendingFeedMutations removeObjectForKey:uid];
            }
        }
        for (NSString* uid in appliedEpisodeUIDs) {
            if (self.pendingEpisodeMutations[uid] == episodeMutations[uid]) {
                [self.pendingEpisodeMutations removeObjectForKey:uid];
            }
        }
    }
    return drainError;
}

- (void)stageChangesForManagedObjectContext:(NSManagedObjectContext*)context
{
    if (!context) {
        return;
    }

    NSMutableArray<NSDictionary*>* feedSnapshots = [[NSMutableArray alloc] init];
    NSMutableArray<NSDictionary*>* episodeSnapshots = [[NSMutableArray alloc] init];
    NSMutableSet<NSString*>* deletedFeedUIDs = [[NSMutableSet alloc] init];
    NSMutableSet<NSString*>* deletedEpisodeUIDs = [[NSMutableSet alloc] init];
    NSMutableSet<NSString*>* reindexEpisodeFeedUIDs = [[NSMutableSet alloc] init];

    for (NSManagedObject* object in context.insertedObjects) {
        if ([object isKindOfClass:CDFeed.class]) {
            NSDictionary* snapshot = ICFTSFeedSnapshot((CDFeed*)object);
            if (snapshot) [feedSnapshots addObject:snapshot];
        }
        else if ([object isKindOfClass:CDEpisode.class]) {
            NSDictionary* snapshot = ICFTSEpisodeSnapshot((CDEpisode*)object);
            if (snapshot) [episodeSnapshots addObject:snapshot];
        }
    }

    for (NSManagedObject* object in context.updatedObjects) {
        NSDictionary<NSString*, id>* changedValues = object.changedValues;
        if ([object isKindOfClass:CDFeed.class]) {
            BOOL metadataChanged = changedValues[@"title"] || changedValues[@"author"] || changedValues[@"summary"];
            BOOL identityChanged = changedValues[@"sourceURL_"] || changedValues[@"subscribed"];
            if (!metadataChanged && !identityChanged) continue;

            CDFeed* feed = (CDFeed*)object;
            NSDictionary* committedValues = [feed committedValuesForKeys:@[@"sourceURL_", @"subscribed"]];
            NSString* oldUID = [committedValues[@"sourceURL_"] isKindOfClass:NSString.class]
                ? committedValues[@"sourceURL_"] : nil;
            BOOL wasSubscribed = [committedValues[@"subscribed"] boolValue];
            NSString* newUID = ICFTSFeedUID(feed);

            if (wasSubscribed && oldUID.length > 0 &&
                (!feed.subscribed || ![oldUID isEqualToString:newUID])) {
                [deletedFeedUIDs addObject:oldUID];
            }
            if (feed.subscribed) {
                NSDictionary* snapshot = ICFTSFeedSnapshot(feed);
                if (snapshot) [feedSnapshots addObject:snapshot];
                if (identityChanged && newUID.length > 0) {
                    [reindexEpisodeFeedUIDs addObject:newUID];
                }
            }
        }
        else if ([object isKindOfClass:CDEpisode.class]) {
            BOOL contentChanged = changedValues[@"title"] || changedValues[@"summary"] || changedValues[@"fulltext"];
            BOOL identityChanged = changedValues[@"objectHash"] || changedValues[@"guid"] || changedValues[@"feed"];
            if (!contentChanged && !identityChanged) continue;

            CDEpisode* episode = (CDEpisode*)object;
            NSDictionary* committedValues = [episode committedValuesForKeys:@[@"objectHash", @"feed"]];
            NSString* oldUID = [committedValues[@"objectHash"] isKindOfClass:NSString.class]
                ? committedValues[@"objectHash"] : nil;
            CDFeed* oldFeed = [committedValues[@"feed"] isKindOfClass:CDFeed.class]
                ? committedValues[@"feed"] : nil;
            NSString* oldFeedUID = ICFTSFeedUID(oldFeed);
            NSDictionary* snapshot = ICFTSEpisodeSnapshot(episode);
            NSString* newUID = snapshot[@"uid"];
            NSString* newFeedUID = snapshot[@"feed_uid"];
            if (oldUID.length > 0 &&
                (!snapshot || ![oldUID isEqualToString:newUID] || ![oldFeedUID isEqualToString:newFeedUID])) {
                [deletedEpisodeUIDs addObject:oldUID];
            }
            if (snapshot) [episodeSnapshots addObject:snapshot];
        }
    }

    for (NSManagedObject* object in context.deletedObjects) {
        if ([object isKindOfClass:CDFeed.class]) {
            CDFeed* feed = (CDFeed*)object;
            NSString* uid = ICFTSFeedUID(feed);
            if (uid.length > 0) [deletedFeedUIDs addObject:uid];
            NSDictionary* committedValues = [feed committedValuesForKeys:@[@"sourceURL_"]];
            NSString* oldUID = [committedValues[@"sourceURL_"] isKindOfClass:NSString.class]
                ? committedValues[@"sourceURL_"] : nil;
            if (oldUID.length > 0) [deletedFeedUIDs addObject:oldUID];
        }
        else if ([object isKindOfClass:CDEpisode.class]) {
            CDEpisode* episode = (CDEpisode*)object;
            NSString* uid = episode.objectHash;
            if (uid.length > 0) [deletedEpisodeUIDs addObject:uid];
            NSDictionary* committedValues = [episode committedValuesForKeys:@[@"objectHash"]];
            NSString* oldUID = [committedValues[@"objectHash"] isKindOfClass:NSString.class]
                ? committedValues[@"objectHash"] : nil;
            if (oldUID.length > 0) [deletedEpisodeUIDs addObject:oldUID];
        }
    }

    if (feedSnapshots.count == 0 && episodeSnapshots.count == 0 &&
        deletedFeedUIDs.count == 0 && deletedEpisodeUIDs.count == 0 &&
        reindexEpisodeFeedUIDs.count == 0) {
        @synchronized (self) {
            [self.stagedChangesByContext removeObjectForKey:context];
        }
        return;
    }

    ICFTSSaveChangeSet* changeSet = [[ICFTSSaveChangeSet alloc] init];
    changeSet.feedSnapshots = feedSnapshots;
    changeSet.episodeSnapshots = episodeSnapshots;
    changeSet.deletedFeedUIDs = deletedFeedUIDs.allObjects;
    changeSet.deletedEpisodeUIDs = deletedEpisodeUIDs.allObjects;
    changeSet.reindexEpisodeFeedUIDs = reindexEpisodeFeedUIDs;
    NSError* dirtyMarkerError = nil;
    @synchronized (self) {
        [self.stagedChangesByContext setObject:changeSet forKey:context];
        if (![self _markIndexDirty:&dirtyMarkerError]) {
            self.incrementalWriteFailed = YES;
        }
    }
    if (dirtyMarkerError) {
        ErrLog(@"Could not persist the staged FTS write marker: %@", dirtyMarkerError);
    }
}

- (BOOL)_applyChangeSet:(ICFTSSaveChangeSet*)changeSet inDatabase:(FMDatabase*)db
{
    BOOL success = YES;
    for (NSString* uid in changeSet.deletedFeedUIDs) {
        success = [db executeUpdate:@"DELETE FROM feeds WHERE uid = ?", uid] &&
                  [db executeUpdate:@"DELETE FROM episodes WHERE feed_uid = ?", uid];
        if (!success) return NO;
    }
    for (NSDictionary* snapshot in changeSet.feedSnapshots) {
        if (![self _replaceFeedSnapshot:snapshot inDatabase:db]) return NO;
    }
    for (NSString* uid in changeSet.deletedEpisodeUIDs) {
        if (![db executeUpdate:@"DELETE FROM episodes WHERE uid = ?", uid]) return NO;
    }
    for (NSDictionary* snapshot in changeSet.episodeSnapshots) {
        if (![self _replaceEpisodeSnapshot:snapshot inDatabase:db]) return NO;
    }
    return YES;
}

- (void)_finishCommittedWriteSucceeded:(BOOL)success
{
    NSError* cleanMarkerError = nil;
    @synchronized (self) {
        if (self.pendingCommittedWrites > 0) {
            self.pendingCommittedWrites -= 1;
        }
        if (!success) {
            self.incrementalWriteFailed = YES;
        }
        if (self.pendingCommittedWrites == 0 &&
            self.stagedChangesByContext.count == 0 &&
            !self.incrementalWriteFailed &&
            !self.externalStoreMutationPending &&
            !self.rebuildingIndex &&
            ![self _markIndexClean:&cleanMarkerError]) {
            self.incrementalWriteFailed = YES;
        }
    }
    if (cleanMarkerError) {
        ErrLog(@"Could not clear the committed FTS write marker: %@", cleanMarkerError);
    }
}

- (void)commitStagedChangesForManagedObjectContext:(NSManagedObjectContext*)context
{
    if (!context) {
        return;
    }

    ICFTSSaveChangeSet* changeSet = nil;
    NSError* dirtyMarkerError = nil;
    @synchronized (self) {
        changeSet = [self.stagedChangesByContext objectForKey:context];
        [self.stagedChangesByContext removeObjectForKey:context];
        if (!changeSet) {
            return;
        }

        if (self.rebuildingIndex) {
            for (NSString* uid in changeSet.deletedFeedUIDs) {
                ICFTSPendingMutation* mutation = [[ICFTSPendingMutation alloc] init];
                mutation.deletion = YES;
                self.pendingFeedMutations[uid] = mutation;
            }
            for (NSDictionary* snapshot in changeSet.feedSnapshots) {
                NSString* uid = snapshot[@"uid"];
                if (uid.length == 0) continue;
                ICFTSPendingMutation* existingMutation = self.pendingFeedMutations[uid];
                ICFTSPendingMutation* mutation = [[ICFTSPendingMutation alloc] init];
                mutation.deletion = NO;
                mutation.reindexEpisodes = existingMutation.reindexEpisodes ||
                                           [changeSet.reindexEpisodeFeedUIDs containsObject:uid];
                self.pendingFeedMutations[uid] = mutation;
            }
            for (NSString* uid in changeSet.deletedEpisodeUIDs) {
                ICFTSPendingMutation* mutation = [[ICFTSPendingMutation alloc] init];
                mutation.deletion = YES;
                self.pendingEpisodeMutations[uid] = mutation;
            }
            for (NSDictionary* snapshot in changeSet.episodeSnapshots) {
                NSString* uid = snapshot[@"uid"];
                if (uid.length == 0) continue;
                ICFTSPendingMutation* mutation = [[ICFTSPendingMutation alloc] init];
                mutation.deletion = NO;
                self.pendingEpisodeMutations[uid] = mutation;
            }
            return;
        }

        if (![self _markIndexDirty:&dirtyMarkerError]) {
            self.incrementalWriteFailed = YES;
        }
        self.pendingCommittedWrites += 1;
    }
    if (dirtyMarkerError) {
        ErrLog(@"Could not persist the pending FTS write marker: %@", dirtyMarkerError);
    }

    dispatch_async(self.writeQueue, ^{
        NSManagedObjectContext* readContext = self.committedChangesContext;
        if (changeSet.reindexEpisodeFeedUIDs.count > 0 && !readContext) {
            ErrLog(@"Could not commit a podcast identity change to FTS because its read context is unavailable.");
            [self _finishCommittedWriteSucceeded:NO];
            return;
        }

        __block BOOL transactionCommitted = NO;
        void (^writeTransaction)(void) = ^{
            [self.queue inDatabase:^(FMDatabase *db) {
                if (![db beginTransaction]) {
                    ErrLog(@"Could not start saved Core Data changes FTS transaction: %@", db.lastErrorMessage);
                    return;
                }
                BOOL success = [self _applyChangeSet:changeSet inDatabase:db];
                NSError* reindexError = nil;
                if (success && changeSet.reindexEpisodeFeedUIDs.count > 0) {
                    reindexError = [self _replaceEpisodesForFeedUIDs:changeSet.reindexEpisodeFeedUIDs
                                                managedObjectContext:readContext
                                                           database:db];
                    success = reindexError == nil;
                }
                if (success) {
                    success = [db commit];
                    transactionCommitted = success;
                }
                if (!success) {
                    [db rollback];
                    ErrLog(@"Could not commit saved Core Data changes to FTS: %@",
                           reindexError ?: db.lastErrorMessage);
                }
            }];
        };

        if (changeSet.reindexEpisodeFeedUIDs.count > 0) {
            [readContext performBlockAndWait:^{
                writeTransaction();
                [readContext reset];
            }];
        }
        else {
            writeTransaction();
        }
        [self _finishCommittedWriteSucceeded:transactionCommitted];
    });
}


- (void) rebuildIndexWithManagedObjectContext:(NSManagedObjectContext*)context
                                   completion:(void (^)(NSError* error))completion
{
    NSManagedObjectContext* pendingChangesContext = self.committedChangesContext;
    if (!pendingChangesContext) {
        pendingChangesContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        pendingChangesContext.persistentStoreCoordinator = context.persistentStoreCoordinator;
        pendingChangesContext.undoManager = nil;
        self.committedChangesContext = pendingChangesContext;
    }
    NSError* dirtyMarkerError = nil;
    BOOL dirtyMarkerReady = NO;
    NSUInteger rebuildGeneration = 0;
    @synchronized (self) {
        dirtyMarkerReady = [self _markIndexDirty:&dirtyMarkerError];
        if (dirtyMarkerReady) {
            self.externalStoreMutationPending = NO;
            rebuildGeneration = ++self.requestedRebuildGeneration;
            if (!self.rebuildingIndex) {
                self.rebuildingIndex = YES;
                self.pendingChangesContext = pendingChangesContext;
                [self.pendingFeedMutations removeAllObjects];
                [self.pendingEpisodeMutations removeAllObjects];
            }
        }
    }
    if (!dirtyMarkerReady) {
        NSError* error = ICFTSRebuildError(@"Could not persist the FTS rebuild marker.", dirtyMarkerError);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(error);
            }
        });
        return;
    }

    dispatch_async(self.writeQueue, ^{
        NSFileManager* fileManager = [NSFileManager defaultManager];
        NSURL* temporaryURL = [NSURL fileURLWithPath:[self.searchIndexURL.path stringByAppendingString:@".rebuild"]];
        __block NSError* rebuildError = nil;

        if ([fileManager fileExistsAtPath:temporaryURL.path] &&
            ![fileManager removeItemAtURL:temporaryURL error:&rebuildError]) {
            rebuildError = ICFTSRebuildError(@"Could not remove an incomplete FTS rebuild.", rebuildError);
        }

        if (!rebuildError) {
            [context performBlockAndWait:^{
                NSError* generationError = nil;
                if (![context setQueryGenerationFromToken:NSQueryGenerationToken.currentQueryGenerationToken error:&generationError]) {
                    rebuildError = ICFTSRebuildError(@"Could not pin the podcast data used for the FTS rebuild.", generationError);
                    return;
                }

                FMDatabase* database = [FMDatabase databaseWithPath:temporaryURL.path];
                if (![database open]) {
                    rebuildError = ICFTSRebuildError(@"Could not create the rebuilt FTS database.", database.lastError);
                    return;
                }

                int registrationResult = ICFTSRegisterCompressionFunctions((sqlite3*)database.sqliteHandle);
                if (registrationResult != SQLITE_OK) {
                    rebuildError = ICFTSRebuildError(@"Could not register compression for the rebuilt FTS database.", database.lastError);
                    [database close];
                    return;
                }

                BOOL transactionStarted = NO;
                if (![database executeUpdate:@"CREATE VIRTUAL TABLE feeds USING fts4(title, author, summary, uid, compress=ic_fts_compress, uncompress=ic_fts_uncompress)"] ||
                    ![database executeUpdate:@"CREATE VIRTUAL TABLE episodes USING fts4(title, summary, fulltext, uid, feed_uid, compress=ic_fts_compress, uncompress=ic_fts_uncompress)"]) {
                    rebuildError = ICFTSRebuildError(@"Could not create the rebuilt FTS schema.", database.lastError);
                }
                else if (![database beginTransaction]) {
                    rebuildError = ICFTSRebuildError(@"Could not start the FTS rebuild transaction.", database.lastError);
                }
                else {
                    transactionStarted = YES;
                }

                if (!rebuildError) {
                    NSString* lastFeedUID = nil;
                    while (!rebuildError) {
                        @autoreleasepool {
                            NSFetchRequest* feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
                            if (lastFeedUID) {
                                feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND sourceURL_ > %@", lastFeedUID];
                            }
                            else {
                                feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND sourceURL_ != nil AND sourceURL_ != \"\""];
                            }
                            feedRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"sourceURL_" ascending:YES]];
                            feedRequest.fetchLimit = 50;
                            feedRequest.fetchBatchSize = 50;
                            NSArray<CDFeed*>* feeds = [context executeFetchRequest:feedRequest error:&rebuildError];
                            if (!feeds || feeds.count == 0) {
                                break;
                            }

                            NSMutableSet<NSString*>* pageFeedUIDs = [[NSMutableSet alloc] init];
                            for (CDFeed* feed in feeds) {
                            NSDictionary* snapshot = ICFTSFeedSnapshot(feed);
                            NSString* uid = snapshot[@"uid"];
                                if (uid && ![pageFeedUIDs containsObject:uid] && ![self _insertFeedSnapshot:snapshot inDatabase:database]) {
                                    rebuildError = ICFTSRebuildError(@"Could not write a podcast to the rebuilt FTS database.", database.lastError);
                                    break;
                                }
                                if (uid) {
                                    [pageFeedUIDs addObject:uid];
                                }
                                [context refreshObject:feed mergeChanges:NO];
                            }
                            lastFeedUID = [feeds.lastObject valueForKey:@"sourceURL_"];
                            if (![lastFeedUID isKindOfClass:NSString.class] || lastFeedUID.length == 0) {
                                rebuildError = ICFTSRebuildError(@"Could not page through podcasts for the FTS rebuild.", nil);
                            }
                        }
                    }
                }

                if (!rebuildError) {
                    NSString* lastEpisodeUID = nil;
                    while (!rebuildError) {
                        @autoreleasepool {
                            NSFetchRequest* episodeRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                            if (lastEpisodeUID) {
                                episodeRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND objectHash > %@", lastEpisodeUID];
                            }
                            else {
                                episodeRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND objectHash != nil AND objectHash != \"\" AND guid != nil AND guid != \"\""];
                            }
                            episodeRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"objectHash" ascending:YES]];
                            episodeRequest.fetchLimit = 100;
                            episodeRequest.fetchBatchSize = 100;
                            NSArray<CDEpisode*>* episodes = [context executeFetchRequest:episodeRequest error:&rebuildError];
                            if (!episodes || episodes.count == 0) {
                                break;
                            }

                            NSMutableSet<NSString*>* pageEpisodeUIDs = [[NSMutableSet alloc] init];
                            for (CDEpisode* episode in episodes) {
                                NSDictionary* snapshot = ICFTSEpisodeSnapshot(episode);
                                NSString* uid = snapshot[@"uid"];
                                if (uid && ![pageEpisodeUIDs containsObject:uid] && ![self _insertEpisodeSnapshot:snapshot inDatabase:database]) {
                                    rebuildError = ICFTSRebuildError(@"Could not write an episode to the rebuilt FTS database.", database.lastError);
                                    break;
                                }
                                if (uid) {
                                    [pageEpisodeUIDs addObject:uid];
                                }
                                [context refreshObject:episode mergeChanges:NO];
                            }
                            lastEpisodeUID = episodes.lastObject.objectHash;
                            if (lastEpisodeUID.length == 0) {
                                rebuildError = ICFTSRebuildError(@"Could not page through episodes for the FTS rebuild.", nil);
                            }
                        }
                    }
                }

                if (transactionStarted) {
                    if (rebuildError) {
                        [database rollback];
                    }
                    else if (![database commit]) {
                        rebuildError = ICFTSRebuildError(@"Could not commit the rebuilt FTS database.", database.lastError);
                    }
                }

                if (!rebuildError &&
                    (![database executeUpdate:@"INSERT INTO feeds(feeds) VALUES('optimize')"] ||
                     ![database executeUpdate:@"INSERT INTO episodes(episodes) VALUES('optimize')"] ||
                     ![database executeUpdate:@"VACUUM"])) {
                    rebuildError = ICFTSRebuildError(@"Could not compact the rebuilt FTS database.", database.lastError);
                }

                if (!rebuildError) {
                    FMResultSet* integrityResult = [database executeQuery:@"PRAGMA quick_check"];
                    NSString* integrity = [integrityResult next] ? [integrityResult stringForColumnIndex:0] : nil;
                    [integrityResult close];
                    if (![integrity isEqualToString:@"ok"]) {
                        rebuildError = ICFTSRebuildError(@"The rebuilt FTS database did not pass its integrity check.", database.lastError);
                    }
                }

                [database close];
            }];
        }

        if (!rebuildError) {
            NSURL* resultingURL = nil;
            NSError* replacementError = nil;
            if (![fileManager replaceItemAtURL:self.searchIndexURL
                                 withItemAtURL:temporaryURL
                                backupItemName:nil
                                       options:0
                              resultingItemURL:&resultingURL
                                         error:&replacementError]) {
                rebuildError = ICFTSRebuildError(@"Could not publish the rebuilt FTS database.", replacementError);
            }
            else {
                FMDatabaseQueue* newQueue = [FMDatabaseQueue databaseQueueWithPath:self.searchIndexURL.path];
                if (!newQueue) {
                    rebuildError = ICFTSRebuildError(@"Could not open the rebuilt FTS database.", nil);
                }
                else {
                    __block int registrationResult = SQLITE_ERROR;
                    [newQueue inDatabase:^(FMDatabase* database) {
                        registrationResult = ICFTSRegisterCompressionFunctions((sqlite3*)database.sqliteHandle);
                    }];
                    if (registrationResult != SQLITE_OK) {
                        rebuildError = ICFTSRebuildError(@"Could not register compression for the published FTS database.", nil);
                        [newQueue close];
                    }
                    else {
                        FMDatabaseQueue* oldQueue = self.queue;
                        self.queue = newQueue;
                        [oldQueue close];
                    }
                }
            }
        }

        if ([fileManager fileExistsAtPath:temporaryURL.path]) {
            NSError* cleanupError = nil;
            if (![fileManager removeItemAtURL:temporaryURL error:&cleanupError] && !rebuildError) {
                rebuildError = ICFTSRebuildError(@"Could not clean up the temporary FTS database.", cleanupError);
            }
        }

        NSError* pendingMutationError = nil;
        while (!pendingMutationError) {
            pendingMutationError = [self _drainPendingMutationsWithManagedObjectContext:pendingChangesContext
                                                                   removeMissingRecords:YES];
            BOOL pendingMutationsAreEmpty = NO;
            @synchronized (self) {
                pendingMutationsAreEmpty = self.pendingFeedMutations.count == 0 &&
                                           self.pendingEpisodeMutations.count == 0;
                BOOL isLatestRebuildGeneration = rebuildGeneration == self.requestedRebuildGeneration;
                if ((pendingMutationsAreEmpty || pendingMutationError) && isLatestRebuildGeneration) {
                    if (pendingMutationsAreEmpty && !pendingMutationError && !rebuildError &&
                        !self.externalStoreMutationPending) {
                        NSError* cleanMarkerError = nil;
                        self.incrementalWriteFailed = NO;
                        self.indexRequiresAuthoritativeRebuild = NO;
                        if (self.stagedChangesByContext.count == 0 &&
                            ![self _markIndexClean:&cleanMarkerError]) {
                            pendingMutationError = ICFTSRebuildError(@"Could not clear the completed FTS rebuild marker.", cleanMarkerError);
                            self.incrementalWriteFailed = YES;
                        }
                    }
                    self.rebuildingIndex = NO;
                    self.pendingChangesContext = nil;
                }
            }
            if (pendingMutationsAreEmpty) {
                break;
            }
        }
        if (!rebuildError && pendingMutationError) {
            rebuildError = pendingMutationError;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(rebuildError);
            }
        });
    });
}



- (void) addFeed:(CDFeed*)feed
{
    NSString* feedUID = [feed.sourceURL absoluteString];
    if (!feedUID || [self _recordPendingFeedUID:feedUID deletion:NO]) {
        return;
    }
    NSDictionary* feedSnapshot = ICFTSFeedSnapshot(feed);
    if (!feedSnapshot) {
        return;
    }

    dispatch_async(self.writeQueue, ^{
        [self.queue inDatabase:^(FMDatabase *db) {
            [self _replaceFeedSnapshot:feedSnapshot inDatabase:db];
        }];
    });
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
    if ([self _recordPendingFeedUID:feedUID deletion:YES]) {
        return;
    }

    dispatch_async(self.writeQueue, ^{
        [self.queue inDatabase:^(FMDatabase *db) {
            [db executeUpdate:@"DELETE FROM feeds WHERE uid = ?", feedUID];
            [db executeUpdate:@"DELETE FROM episodes WHERE feed_uid = ?", feedUID];
        }];
    });
}

- (void) addEpisode:(CDEpisode*)episode
{
    NSString* episodeUID = episode.objectHash;
    if (!episodeUID || [self _recordPendingEpisodeUID:episodeUID deletion:NO]) {
        return;
    }
    NSDictionary* episodeSnapshot = ICFTSEpisodeSnapshot(episode);
    if (!episodeSnapshot) {
        return;
    }

    dispatch_async(self.writeQueue, ^{
        [self.queue inDatabase:^(FMDatabase *db) {
            [self _replaceEpisodeSnapshot:episodeSnapshot inDatabase:db];
        }];
    });
}

- (void) updateEpisode:(CDEpisode*)episode
{
    [self addEpisode:episode];
}

- (void) removeEpisode:(CDEpisode*)episode
{
    NSString* episodeUID = episode.objectHash;
    if (!episodeUID) {
        return;
    }
    if ([self _recordPendingEpisodeUID:episodeUID deletion:YES]) {
        return;
    }

    dispatch_async(self.writeQueue, ^{
        [self.queue inDatabase:^(FMDatabase *db) {
            [db executeUpdate:@"DELETE FROM episodes WHERE uid = ?", episodeUID];
        }];
    });
}

#pragma mark -

- (NSSet*) feedSourceURLsForSearchTerm:(NSString*)searchTerm
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

- (NSSet*) episodeObjectHashesForSearchTerm:(NSString*)searchTerm
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
