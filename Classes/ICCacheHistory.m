//
//  ICCacheHistory.m
//  Instacast
//
//  Created by Martin Hering on 20.03.13.
//

#import "ICCacheHistory.h"

#import <sqlite3.h>

static NSString* const ICCacheHistoryTableName = @"auto_downloaded_episode";
static const NSInteger ICCacheHistorySchemaVersion = 1;

static NSError* ICCacheHistoryError(NSInteger code, NSString* description, NSError* underlyingError)
{
    NSMutableDictionary* userInfo = [@{
        NSLocalizedDescriptionKey: description ?: @"Download history could not be updated.",
    } mutableCopy];
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:@"ICCacheHistory" code:code userInfo:userInfo];
}

@interface ICCacheHistory ()
@property (nonatomic, copy) NSString* legacyFilePath;
@property (nonatomic, copy) NSString* databasePath;
@property (nonatomic) sqlite3* database;
@property (nonatomic) dispatch_queue_t persistenceQueue;
@property (nonatomic, strong) NSMutableSet<NSString*>* history;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* pendingValues;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSNumber*>* mutationGenerations;
@property (nonatomic) NSUInteger mutationGeneration;
@property (nonatomic, readwrite, getter=isLoaded) BOOL loaded;
@property (nonatomic) BOOL loading;
@property (nonatomic, strong) NSError* loadError;
@property (nonatomic, strong) NSMutableArray<void (^)(NSError*)>* loadCompletions;
@end

@implementation ICCacheHistory

- (id)initWithContentsOfFile:(NSString*)filePath
{
    if ((self = [super init])) {
        _legacyFilePath = [filePath copy];
        _databasePath = [[[filePath stringByDeletingPathExtension]
            stringByAppendingString:@".sqlite"] copy];
        _history = [NSMutableSet set];
        _pendingValues = [NSMutableDictionary dictionary];
        _mutationGenerations = [NSMutableDictionary dictionary];
        _loadCompletions = [NSMutableArray array];
        _persistenceQueue = dispatch_queue_create("com.vemedio.instacast.cacheHistory", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_persistenceQueue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        [self reloadIfNeededWithCompletion:^(NSError* error) {
            if (error) {
                NSLog(@"could not read download history: %@", error);
            }
        }];
    }
    return self;
}

- (void)dealloc
{
    sqlite3* database = _database;
    if (database) {
        dispatch_sync(_persistenceQueue, ^{
            sqlite3_close(database);
        });
    }
}

- (NSError*)_sqliteErrorWithCode:(int)code description:(NSString*)description
{
    const char* message = self.database ? sqlite3_errmsg(self.database) : sqlite3_errstr(code);
    NSString* sqliteMessage = message ? [NSString stringWithUTF8String:message] : @"Unknown SQLite error";
    NSError* underlyingError = [NSError errorWithDomain:@"SQLite"
                                                    code:code
                                                userInfo:@{NSLocalizedDescriptionKey: sqliteMessage}];
    return ICCacheHistoryError(code, description, underlyingError);
}

- (NSError*)_executeSQL:(NSString*)SQL description:(NSString*)description
{
    char* message = NULL;
    int result = sqlite3_exec(self.database, SQL.UTF8String, NULL, NULL, &message);
    if (result == SQLITE_OK) {
        return nil;
    }
    NSString* sqliteMessage = message ? [NSString stringWithUTF8String:message] : @"Unknown SQLite error";
    if (message) sqlite3_free(message);
    NSError* underlyingError = [NSError errorWithDomain:@"SQLite"
                                                    code:result
                                                userInfo:@{NSLocalizedDescriptionKey: sqliteMessage}];
    return ICCacheHistoryError(result, description, underlyingError);
}

- (NSError*)_openDatabaseReturningError
{
    if (self.database) {
        return nil;
    }
    sqlite3* database = NULL;
    int result = sqlite3_open_v2(self.databasePath.fileSystemRepresentation,
                                 &database,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                                 NULL);
    if (result != SQLITE_OK) {
        self.database = database;
        NSError* error = [self _sqliteErrorWithCode:result description:@"Download history could not be opened."];
        if (database) sqlite3_close(database);
        self.database = NULL;
        return error;
    }
    self.database = database;
    sqlite3_busy_timeout(database, 5000);
    NSError* error = [self _executeSQL:@"PRAGMA journal_mode=WAL" description:@"Download history journal mode could not be configured."];
    if (!error) {
        error = [self _executeSQL:@"PRAGMA synchronous=FULL" description:@"Download history durability could not be configured."];
    }
    if (!error) {
        NSString* createSQL = [NSString stringWithFormat:
            @"CREATE TABLE IF NOT EXISTS %@ (episode_hash TEXT PRIMARY KEY NOT NULL) WITHOUT ROWID",
            ICCacheHistoryTableName];
        error = [self _executeSQL:createSQL description:@"Download history table could not be created."];
    }
    if (error) {
        sqlite3_close(self.database);
        self.database = NULL;
    }
    return error;
}

- (NSInteger)_schemaVersionReturningError:(NSError**)error
{
    sqlite3_stmt* statement = NULL;
    int result = sqlite3_prepare_v2(self.database, "PRAGMA user_version", -1, &statement, NULL);
    if (result != SQLITE_OK) {
        if (error) *error = [self _sqliteErrorWithCode:result description:@"Download history schema could not be read."];
        return 0;
    }
    NSInteger version = 0;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        version = sqlite3_column_int(statement, 0);
    }
    sqlite3_finalize(statement);
    return version;
}

- (NSError*)_setSchemaVersion
{
    NSString* SQL = [NSString stringWithFormat:@"PRAGMA user_version=%ld", (long)ICCacheHistorySchemaVersion];
    return [self _executeSQL:SQL description:@"Download history schema could not be finalized."];
}

- (NSError*)_migrateLegacyPlistIfNeeded
{
    NSError* schemaError = nil;
    NSInteger version = [self _schemaVersionReturningError:&schemaError];
    if (schemaError) return schemaError;
    if (version >= ICCacheHistorySchemaVersion) {
        return nil;
    }

    NSFileManager* fileManager = [[NSFileManager alloc] init];
    BOOL hasLegacyFile = [fileManager fileExistsAtPath:self.legacyFilePath];
    NSDictionary* legacyHistory = nil;
    if (hasLegacyFile) {
        NSError* readError = nil;
        NSData* data = [NSData dataWithContentsOfFile:self.legacyFilePath options:0 error:&readError];
        if (!data) {
            return ICCacheHistoryError(3, @"Download history could not be read.", readError);
        }
        NSError* parseError = nil;
        id propertyList = [NSPropertyListSerialization propertyListWithData:data
                                                                     options:NSPropertyListImmutable
                                                                      format:NULL
                                                                       error:&parseError];
        if (![propertyList isKindOfClass:[NSDictionary class]]) {
            return ICCacheHistoryError(4, @"Download history is not a dictionary.", parseError);
        }
        legacyHistory = propertyList;
    }

    NSError* error = [self _executeSQL:@"BEGIN IMMEDIATE TRANSACTION"
                            description:@"Download history migration could not start."];
    sqlite3_stmt* statement = NULL;
    if (!error && legacyHistory.count > 0) {
        NSString* SQL = [NSString stringWithFormat:
            @"INSERT OR IGNORE INTO %@ (episode_hash) VALUES (?)", ICCacheHistoryTableName];
        int result = sqlite3_prepare_v2(self.database, SQL.UTF8String, -1, &statement, NULL);
        if (result != SQLITE_OK) {
            error = [self _sqliteErrorWithCode:result description:@"Download history migration could not be prepared."];
        }
        if (!error) {
            for (NSString* episodeHash in legacyHistory) {
                NSDictionary* values = [legacyHistory[episodeHash] isKindOfClass:[NSDictionary class]]
                    ? legacyHistory[episodeHash]
                    : nil;
                if (episodeHash.length == 0 || ![values[@"DidAutoDownload"] boolValue]) {
                    continue;
                }
                sqlite3_reset(statement);
                sqlite3_clear_bindings(statement);
                sqlite3_bind_text(statement, 1, episodeHash.UTF8String, -1, SQLITE_TRANSIENT);
                result = sqlite3_step(statement);
                if (result != SQLITE_DONE) {
                    error = [self _sqliteErrorWithCode:result description:@"Download history migration could not be saved."];
                    break;
                }
            }
        }
    }
    if (statement) sqlite3_finalize(statement);
    if (!error) error = [self _setSchemaVersion];
    if (!error) error = [self _executeSQL:@"COMMIT" description:@"Download history migration could not be committed."];
    if (error) {
        [self _executeSQL:@"ROLLBACK" description:@"Download history migration could not be rolled back."];
        return error;
    }

    if (hasLegacyFile) {
        NSError* deletionError = nil;
        if (![fileManager removeItemAtPath:self.legacyFilePath error:&deletionError] &&
            deletionError.code != NSFileNoSuchFileError) {
            NSLog(@"could not remove migrated download history plist: %@", deletionError);
        }
    }
    return nil;
}

- (NSError*)_loadHistoryOnPersistenceQueue:(NSSet<NSString*>**)history
{
    NSError* error = [self _openDatabaseReturningError];
    if (!error) error = [self _migrateLegacyPlistIfNeeded];
    if (error) return error;

    NSString* SQL = [NSString stringWithFormat:@"SELECT episode_hash FROM %@", ICCacheHistoryTableName];
    sqlite3_stmt* statement = NULL;
    int result = sqlite3_prepare_v2(self.database, SQL.UTF8String, -1, &statement, NULL);
    if (result != SQLITE_OK) {
        return [self _sqliteErrorWithCode:result description:@"Download history could not be queried."];
    }
    NSMutableSet<NSString*>* loadedHistory = [NSMutableSet set];
    while ((result = sqlite3_step(statement)) == SQLITE_ROW) {
        const unsigned char* text = sqlite3_column_text(statement, 0);
        if (text) {
            NSString* episodeHash = [NSString stringWithUTF8String:(const char*)text];
            if (episodeHash.length > 0) [loadedHistory addObject:episodeHash];
        }
    }
    sqlite3_finalize(statement);
    if (result != SQLITE_DONE) {
        return [self _sqliteErrorWithCode:result description:@"Download history could not be read."];
    }
    if (history) *history = [loadedHistory copy];
    return nil;
}

- (void)reloadIfNeededWithCompletion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadIfNeededWithCompletion:completion];
        });
        return;
    }
    if (self.loaded) {
        if (completion) completion(nil);
        return;
    }
    if (completion) [self.loadCompletions addObject:[completion copy]];
    if (self.loading) return;
    self.loading = YES;

    dispatch_async(self.persistenceQueue, ^{
        NSSet<NSString*>* loadedHistory = nil;
        NSError* error = [self _loadHistoryOnPersistenceQueue:&loadedHistory];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loading = NO;
            if (!error) {
                self.history = [loadedHistory mutableCopy] ?: [NSMutableSet set];
                self.loaded = YES;
                self.loadError = nil;
            } else {
                self.loaded = NO;
                self.loadError = error;
            }
            NSArray<void (^)(NSError*)>* completions = [self.loadCompletions copy];
            [self.loadCompletions removeAllObjects];
            for (void (^loadCompletion)(NSError*) in completions) {
                loadCompletion(error);
            }
        });
    });
}

- (BOOL)episodeDidAutoDownload:(CDEpisode*)episode
{
    if (!self.loaded || episode.objectHash.length == 0) {
        return YES;
    }
    NSNumber* pendingValue = self.pendingValues[episode.objectHash];
    if (pendingValue) return pendingValue.boolValue;
    return [self.history containsObject:episode.objectHash];
}

- (NSError*)_setEpisodeHash:(NSString*)episodeHash autoDownloaded:(BOOL)autoDownloaded
{
    NSError* error = [self _openDatabaseReturningError];
    if (error) return error;
    NSString* SQL = autoDownloaded
        ? [NSString stringWithFormat:@"INSERT OR IGNORE INTO %@ (episode_hash) VALUES (?)", ICCacheHistoryTableName]
        : [NSString stringWithFormat:@"DELETE FROM %@ WHERE episode_hash = ?", ICCacheHistoryTableName];
    sqlite3_stmt* statement = NULL;
    int result = sqlite3_prepare_v2(self.database, SQL.UTF8String, -1, &statement, NULL);
    if (result == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, episodeHash.UTF8String, -1, SQLITE_TRANSIENT);
        result = sqlite3_step(statement);
    }
    if (statement) sqlite3_finalize(statement);
    if (result != SQLITE_DONE) {
        return [self _sqliteErrorWithCode:result description:@"Download history could not be updated."];
    }
    return nil;
}

- (void)setEpisode:(CDEpisode*)episode didAutoDownload:(BOOL)autoDownload
{
    [self setEpisode:episode didAutoDownload:autoDownload completion:^(NSError* error) {
        if (error) NSLog(@"could not update download history: %@", error);
    }];
}

- (void)setEpisode:(CDEpisode*)episode
 didAutoDownload:(BOOL)autoDownload
      completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setEpisode:episode didAutoDownload:autoDownload completion:completion];
        });
        return;
    }
    NSString* episodeHash = [episode.objectHash copy];
    if (episodeHash.length == 0) {
        if (completion) completion(nil);
        return;
    }
    if (!self.loaded) {
        if (completion) completion(self.loadError ?: ICCacheHistoryError(5, @"Download history has not been loaded.", nil));
        return;
    }

    self.mutationGeneration += 1;
    NSNumber* mutationGeneration = @(self.mutationGeneration);
    self.mutationGenerations[episodeHash] = mutationGeneration;
    self.pendingValues[episodeHash] = @(autoDownload);
    dispatch_async(self.persistenceQueue, ^{
        NSError* error = [self _setEpisodeHash:episodeHash autoDownloaded:autoDownload];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.mutationGenerations[episodeHash] isEqual:mutationGeneration]) {
                if (!error) {
                    if (autoDownload) {
                        [self.history addObject:episodeHash];
                    } else {
                        [self.history removeObject:episodeHash];
                    }
                }
                [self.mutationGenerations removeObjectForKey:episodeHash];
                [self.pendingValues removeObjectForKey:episodeHash];
            }
            if (completion) completion(error);
        });
    });
}

- (void)resetValuesForEpisode:(CDEpisode*)episode
{
    [self setEpisode:episode didAutoDownload:NO];
}

- (NSError*)_deleteEpisodeHashes:(NSSet<NSString*>*)episodeHashes
{
    NSError* error = [self _openDatabaseReturningError];
    if (error || episodeHashes.count == 0) return error;
    error = [self _executeSQL:@"BEGIN IMMEDIATE TRANSACTION"
                  description:@"Download history reset could not start."];
    sqlite3_stmt* statement = NULL;
    if (!error) {
        NSString* SQL = [NSString stringWithFormat:
            @"DELETE FROM %@ WHERE episode_hash = ?", ICCacheHistoryTableName];
        int result = sqlite3_prepare_v2(self.database, SQL.UTF8String, -1, &statement, NULL);
        if (result != SQLITE_OK) {
            error = [self _sqliteErrorWithCode:result description:@"Download history reset could not be prepared."];
        }
        if (!error) {
            for (NSString* episodeHash in episodeHashes) {
                sqlite3_reset(statement);
                sqlite3_clear_bindings(statement);
                sqlite3_bind_text(statement, 1, episodeHash.UTF8String, -1, SQLITE_TRANSIENT);
                result = sqlite3_step(statement);
                if (result != SQLITE_DONE) {
                    error = [self _sqliteErrorWithCode:result description:@"Download history reset could not be saved."];
                    break;
                }
            }
        }
    }
    if (statement) sqlite3_finalize(statement);
    if (!error) error = [self _executeSQL:@"COMMIT" description:@"Download history reset could not be committed."];
    if (error) [self _executeSQL:@"ROLLBACK" description:@"Download history reset could not be rolled back."];
    return error;
}

- (void)resetValuesForEpisodes:(NSArray<CDEpisode*>*)episodes
                    completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resetValuesForEpisodes:episodes completion:completion];
        });
        return;
    }
    NSMutableSet<NSString*>* episodeHashes = [NSMutableSet set];
    for (CDEpisode* episode in episodes) {
        if (episode.objectHash.length > 0) [episodeHashes addObject:episode.objectHash];
    }
    if (episodeHashes.count == 0) {
        if (completion) completion(nil);
        return;
    }
    if (!self.loaded) {
        if (completion) completion(self.loadError ?: ICCacheHistoryError(5, @"Download history has not been loaded.", nil));
        return;
    }

    self.mutationGeneration += 1;
    NSNumber* mutationGeneration = @(self.mutationGeneration);
    for (NSString* episodeHash in episodeHashes) {
        self.mutationGenerations[episodeHash] = mutationGeneration;
        self.pendingValues[episodeHash] = @NO;
    }
    dispatch_async(self.persistenceQueue, ^{
        NSError* error = [self _deleteEpisodeHashes:episodeHashes];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSString* episodeHash in episodeHashes) {
                if (![self.mutationGenerations[episodeHash] isEqual:mutationGeneration]) continue;
                if (!error) [self.history removeObject:episodeHash];
                [self.mutationGenerations removeObjectForKey:episodeHash];
                [self.pendingValues removeObjectForKey:episodeHash];
            }
            if (completion) completion(error);
        });
    });
}

- (NSError*)_replaceStoreWithEmptyDatabase
{
    if (self.database) {
        sqlite3_close(self.database);
        self.database = NULL;
    }
    NSFileManager* fileManager = [[NSFileManager alloc] init];
    NSArray<NSString*>* paths = @[
        self.databasePath,
        [self.databasePath stringByAppendingString:@"-wal"],
        [self.databasePath stringByAppendingString:@"-shm"],
        self.legacyFilePath,
    ];
    NSError* firstError = nil;
    for (NSString* path in paths) {
        NSError* deletionError = nil;
        if (![fileManager removeItemAtPath:path error:&deletionError] &&
            deletionError.code != NSFileNoSuchFileError && !firstError) {
            firstError = deletionError;
        }
    }
    if (firstError) {
        return ICCacheHistoryError(6,
                                   NSLocalizedString(@"Download history could not be cleared. Please try again.", nil),
                                   firstError);
    }
    NSError* error = [self _openDatabaseReturningError];
    if (!error) error = [self _setSchemaVersion];
    return error;
}

- (void)clearWithCompletion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearWithCompletion:completion];
        });
        return;
    }
    NSSet<NSString*>* episodeHashes = [self.history setByAddingObjectsFromSet:[NSSet setWithArray:self.pendingValues.allKeys]];
    self.mutationGeneration += 1;
    NSNumber* mutationGeneration = @(self.mutationGeneration);
    for (NSString* episodeHash in episodeHashes) {
        self.mutationGenerations[episodeHash] = mutationGeneration;
        self.pendingValues[episodeHash] = @NO;
    }
    dispatch_async(self.persistenceQueue, ^{
        NSError* error = [self _replaceStoreWithEmptyDatabase];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error) {
                self.loaded = YES;
                self.loadError = nil;
                [self.history removeAllObjects];
            }
            for (NSString* episodeHash in episodeHashes) {
                if (![self.mutationGenerations[episodeHash] isEqual:mutationGeneration]) continue;
                if (!error) [self.history removeObject:episodeHash];
                [self.mutationGenerations removeObjectForKey:episodeHash];
                [self.pendingValues removeObjectForKey:episodeHash];
            }
            if (completion) completion(error);
        });
    });
}

@end
