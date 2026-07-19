//
//  DatabaseManager.m
//  Instacast
//
//  Created by Martin Hering on 22.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <objc/runtime.h>
#include <sys/xattr.h>
#include <sqlite3.h>

#if TARGET_OS_IPHONE
#else
#import "ICSharingManager.h"
#endif

#import "ICFeed.h"
#import "ICEpisode.h"
#import "ICMedia.h"
#import "ICCategory.h"
#import "EpisodeLoadingManager.h"
#import "InstacastPlus-Swift.h"
#import "UtilityFunctions.h"

#import "UIManager.h"
#import "ICFTSController.h"
#import "ICSpotlightIndexer.h"

// legacy migration
#import "CDSmartPlaylist.h"
#import "CDPlaylist.h"
#import "CDFeedProperty.h"
#import "FSCrossbucketConnection.h"


#define MODEL_VERSION 5
#define DATA_STORE_GENERATION 6
NSTimeInterval kTrialReferenceDate = 0;

static DatabaseManager* gSharedDatabaseManager = nil;

NSString* DatabaseManagerDidUpdateObservedFeedNotification = @"DatabaseManagerDidUpdateObservedFeedNotification";
NSString* DatabaseManagerDidAddBookmarkNotification = @"DatabaseManagerDidAddBookmarkNotification";

static NSString* kDefaultEpisodePositionMigrationDone = @"EpisodePositionMigrationDone";
static NSString* kDefaultFTSIndexVersion = @"FTSIndexVersion";
static const NSInteger kFTSIndexVersion = 3;
static NSString* const kCurrentFTSIndexFilename = @"FTSIndex-v3.sqlite";
static NSString* const kLegacyFTSIndexFilename = @"FTSIndex.sqlite";
static NSString* const kDefaultLegacyFTSMigrationDone = @"FTSMigrationDone";
static NSString* kDefaultSpotlightMigrationDone = @"SpotlightMigrationDone";
static const NSUInteger kEpisodeDeletionBatchSize = 50;
static NSString* const ICDataStoreMigrationPhaseBuilding = @"building";
static NSString* const ICDataStoreMigrationPhaseReady = @"ready";
static NSString* const ICDataStoreMigrationPhaseCommitting = @"committing";
static NSString* const ICDataStoreMigrationPhaseKey = @"phase";
static NSString* const ICDataStoreMigrationSourcePathKey = @"sourcePath";
static NSString* const ICDataStoreMigrationTargetPathKey = @"targetPath";
static NSString* const ICDataStoreMigrationEntityCountsKey = @"entityCounts";
static NSString* const ICDataStoreMigrationGenerationKey = @"generation";
static NSString* const ICDataStoreMigrationFormatVersionKey = @"formatVersion";
static NSString* const ICDataStoreMigrationSourceStoreUUIDKey = @"sourceStoreUUID";
static NSString* const ICDataStoreMigrationTargetStoreUUIDKey = @"targetStoreUUID";
static const NSInteger ICDataStoreMigrationFormatVersion = 1;

static BOOL ICFeedPropertyAffectsEpisodeCount(NSString* key)
{
    return [key isEqualToString:kFeedPropertyEpisodeLoadingComplete] ||
           [key isEqualToString:kFeedPropertyTotalExpectedEpisodes];
}


#if TARGET_OS_IPHONE

static NSString* kFeedsProperty = @"feeds";
static NSString* kListsProperty = @"lists";
static NSString* kBookmarksProperty = @"bookmarks";


@interface DatabaseManager () <NSFetchedResultsControllerDelegate>
#else
@interface DatabaseManager ()
#endif

@property (nonatomic, strong, readwrite) NSManagedObjectContext* objectContext;
@property (nonatomic, strong, readwrite) NSPersistentContainer* persistentContainer;
@property (nonatomic, strong, readwrite) NSPersistentStoreCoordinator* storeCoordinator;
@property (nonatomic, strong, readwrite) NSManagedObjectModel* objectModel;
@property (nonatomic, strong, readwrite) NSError* initializationError;
@property (nonatomic, strong, readwrite) ICFTSController* ftsController;
@property (nonatomic, strong, readwrite) ICSpotlightIndexer* spotlightIndexer;
@property (nonatomic, readwrite) BOOL ftsIndexing;
@property (nonatomic) NSUInteger ftsIndexingOperationCount;

+ (NSURL*)_currentDataStoreURL;
+ (NSURL*)_dataStoreMigrationMarkerURL;
+ (NSURL*)_authoritativeSourceDataStoreURLWithError:(NSError**)error;
+ (NSURL*)_legacyMigrationSourceURLForTargetURL:(NSURL*)targetURL error:(NSError**)error;
+ (NSURL*)_validatedLegacyDataStoreURL:(NSURL*)storeURL error:(NSError**)error;
+ (NSDictionary*)_readDataStoreMigrationMarkerWithError:(NSError**)error;
+ (BOOL)_writeDataStoreMigrationMarker:(NSDictionary*)marker error:(NSError**)error;
+ (BOOL)_prepareDataStoreMigrationWithError:(NSError**)error;
+ (NSString*)_relativeDataStorePathForURL:(NSURL*)storeURL error:(NSError**)error;
+ (NSURL*)_dataStoreURLForRelativePath:(NSString*)relativePath error:(NSError**)error;
+ (BOOL)_removePreparedDataStoreAtURL:(NSURL*)storeURL error:(NSError**)error;
+ (NSManagedObjectModel*)_compatibleSourceModelForMetadata:(NSDictionary*)metadata error:(NSError**)error;
+ (BOOL)_lightweightMigrateCurrentDataStoreAtURL:(NSURL*)storeURL
                                    sourceMetadata:(NSDictionary*)sourceMetadata
                                             error:(NSError**)error;
+ (NSDictionary<NSString*, NSNumber*>*)_entityCountsAtStoreURL:(NSURL*)storeURL
                                                         model:(NSManagedObjectModel*)model
                                                       options:(NSDictionary*)options
                                                         error:(NSError**)error;
+ (BOOL)_validatePreparedStoreAtURL:(NSURL*)storeURL
                     expectedCounts:(NSDictionary<NSString*, NSNumber*>*)expectedCounts
                  expectedStoreUUID:(NSString*)expectedStoreUUID
                              error:(NSError**)error;
+ (BOOL)_sqliteStoreAtURLIsClean:(NSURL*)storeURL error:(NSError**)error;
+ (NSError*)_dataStoreMigrationErrorWithUnderlyingError:(NSError*)underlyingError;
+ (NSSet<NSString*>*)_obsoleteDataStoreFilenames;
+ (BOOL)_isRemovableObsoleteDataStoreItemAtURL:(NSURL*)itemURL;
- (NSError*)_databaseInitializationErrorWithUnderlyingError:(NSError*)underlyingError;
- (void)_finalizeVersionedFTSMigration;
- (void)_deleteEpisodeObjectIDs:(NSArray<NSManagedObjectID*>*)episodeObjectIDs
                     startingAt:(NSUInteger)startIndex
     successfullyDeletedEpisodes:(NSMutableArray<CDEpisode*>*)successfullyDeletedEpisodes
                     completion:(void (^)(NSError* error))completion;
- (void)_finishDeletingEpisodes:(NSArray<CDEpisode*>*)successfullyDeletedEpisodes
                           error:(NSError*)error
                      completion:(void (^)(NSError* error))completion;


@end


@implementation DatabaseManager {
@protected
#if TARGET_OS_IPHONE
    NSFetchedResultsController* _feedsController;
    NSFetchedResultsController* _listsController;
    NSFetchedResultsController* _bookmarksController;
#else
    NSArrayController*          _feedsController;
    NSArrayController*          _listsController;
    NSArrayController*          _bookmarksController;
#endif
    NSInteger                   _savingInterruption;
    NSPersistentStoreCoordinator* _exportStoreCoordinator;
    NSPersistentStoreCoordinator* _iCloudSyncStoreCoordinator;
    NSMutableSet<CDFeed*>*      _feedsAwaitingCountSave;
}

+ (NSString*) pathToDocuments
{
	NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* path = [paths lastObject];
    
#if !TARGET_OS_IPHONE
    path = [path stringByAppendingPathComponent:@"Instacast"];
#endif
    
    return path;
}

+ (NSString*) pathToSubfolder:(NSString*)subfolder parent:(NSString*)pathToParentFolder
{
	if (!pathToParentFolder) {
		return nil;
	}
	
	NSString* pathToSubFolder = [pathToParentFolder stringByAppendingPathComponent:subfolder];
	
	NSFileManager* fman = [NSFileManager defaultManager];
    
	if (![fman fileExistsAtPath:pathToSubFolder])
	{
		NSError* error = nil;
		if (![fman createDirectoryAtPath:pathToSubFolder withIntermediateDirectories:YES
							  attributes:nil
								   error:&error]) {
			ErrLog(@"error creating directory %@: %@", pathToSubFolder, [error description]);
			return nil;
		}
	}
    
    return pathToSubFolder;
}

+ (DatabaseManager*) sharedDatabaseManager
{
    // Core Data lifecycle callbacks recurse into DMANAGER while init is still running, so the
    // object must stay pre-published. The reentrant lock lets that same thread through while a
    // detached/background caller waits instead of observing and opening a half-built container.
    @synchronized (self) {
        if (!gSharedDatabaseManager) {
            gSharedDatabaseManager = [self alloc];
            gSharedDatabaseManager = [gSharedDatabaseManager init];
        }
        return gSharedDatabaseManager;
    }
}

#pragma mark -

NS_INLINE NSString* _ModelFile(void) {
    return [NSString stringWithFormat:@"Model%d", MODEL_VERSION];
}

NS_INLINE NSString* _DataStoreFile(void) {
    return [NSString stringWithFormat:@"DataStore%d.sqlite", DATA_STORE_GENERATION];
}

+ (NSString*) currentDataStoreFilename
{
    return _DataStoreFile();
}

+ (void) _migrateRootFilesToDataFolder
{
    NSFileManager* fman = [NSFileManager defaultManager];
    NSString* docs = [DatabaseManager pathToDocuments];
    NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:docs];

    // Move database files, FTS index, CacheHistory from root to Data/
    NSArray* filesToMove = @[
        _DataStoreFile(),
        [_DataStoreFile() stringByAppendingString:@"-shm"],
        [_DataStoreFile() stringByAppendingString:@"-wal"],
        kLegacyFTSIndexFilename,
        @"CacheHistory.plist",
        @"CustomViewFilterSets.plist",
    ];

    for (NSString* filename in filesToMove) {
        NSString* oldPath = [docs stringByAppendingPathComponent:filename];
        NSString* newPath = [dataPath stringByAppendingPathComponent:filename];
        if ([fman fileExistsAtPath:oldPath] && ![fman fileExistsAtPath:newPath]) {
            NSError* error;
            if (![fman moveItemAtPath:oldPath toPath:newPath error:&error]) {
                ErrLog(@"error moving %@ to Data/: %@", filename, error);
            }
        }
    }

    // Move FileIndex.plist from Episodes/ to Data/
    NSString* episodesPath = [docs stringByAppendingPathComponent:@"Episodes"];
    NSString* oldFileIndex = [episodesPath stringByAppendingPathComponent:@"FileIndex.plist"];
    NSString* newFileIndex = [dataPath stringByAppendingPathComponent:@"FileIndex.plist"];
    if ([fman fileExistsAtPath:oldFileIndex] && ![fman fileExistsAtPath:newFileIndex]) {
        NSError* error;
        if (![fman moveItemAtPath:oldFileIndex toPath:newFileIndex error:&error]) {
            ErrLog(@"error moving FileIndex.plist to Data/: %@", error);
        }
    }
}

+ (NSURL*) _urlOfLastDataStoreFile
{
    NSFileManager* fman = [[NSFileManager alloc] init];
    NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]];
    NSInteger version;
    for(version = DATA_STORE_GENERATION-1; version>0; version--)
    {
        // Check Data/ folder first
        NSURL* url = [NSURL fileURLWithPath:[dataPath stringByAppendingPathComponent:[NSString stringWithFormat:@"DataStore%ld.sqlite", (long)version]]];
        if ([fman fileExistsAtPath:[url path]]) {
            return url;
        }
        // Fallback: check old location in Documents root
        url = [NSURL fileURLWithPath:[[DatabaseManager pathToDocuments] stringByAppendingPathComponent:[NSString stringWithFormat:@"DataStore%ld.sqlite", (long)version]]];
        if ([fman fileExistsAtPath:[url path]]) {
            return url;
        }
    }

    // Fallback: old DataStore.sqlite in Documents root
    return [NSURL fileURLWithPath:[[DatabaseManager pathToDocuments] stringByAppendingPathComponent:@"DataStore.sqlite"]];
}

+ (NSInteger)_dataStoreGenerationForURL:(NSURL*)storeURL
{
    NSString* filename = storeURL.lastPathComponent;
    if ([filename isEqualToString:@"DataStore.sqlite"]) {
        return 0;
    }

    NSRegularExpression* expression = [NSRegularExpression regularExpressionWithPattern:@"^DataStore([1-9][0-9]*)\\.sqlite$"
                                                                                  options:0
                                                                                    error:nil];
    NSTextCheckingResult* match = [expression firstMatchInString:filename
                                                          options:0
                                                            range:NSMakeRange(0, filename.length)];
    if (!match || match.numberOfRanges != 2) {
        return NSNotFound;
    }
    return [[filename substringWithRange:[match rangeAtIndex:1]] integerValue];
}

+ (NSURL*)_validatedLegacyDataStoreURL:(NSURL*)storeURL error:(NSError**)error
{
    NSString* documentsPath = self.pathToDocuments.stringByStandardizingPath;
    NSString* dataPath = [documentsPath stringByAppendingPathComponent:@"Data"];
    NSString* storePath = storeURL.path.stringByStandardizingPath;
    NSString* parentPath = storePath.stringByDeletingLastPathComponent;
    NSInteger generation = [self _dataStoreGenerationForURL:storeURL];
    BOOL validLocation = [parentPath isEqualToString:documentsPath] || [parentPath isEqualToString:dataPath];
    if (!validLocation || generation == NSNotFound || generation >= DATA_STORE_GENERATION) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:68
                                     userInfo:@{NSLocalizedDescriptionKey: @"The previous database marker references an unsupported store."}];
        }
        return nil;
    }

    NSError* resourceError = nil;
    id isSymbolicLink = nil;
    id isRegularFile = nil;
    BOOL readSymbolicLinkState = [storeURL getResourceValue:&isSymbolicLink
                                                     forKey:NSURLIsSymbolicLinkKey
                                                      error:&resourceError];
    BOOL readRegularFileState = [storeURL getResourceValue:&isRegularFile
                                                    forKey:NSURLIsRegularFileKey
                                                     error:&resourceError];
    NSString* resolvedPath = storeURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    if (!readSymbolicLinkState || !readRegularFileState || [isSymbolicLink boolValue] ||
        ![isRegularFile boolValue] || ![resolvedPath isEqualToString:storePath]) {
        if (error) {
            *error = resourceError ?: [NSError errorWithDomain:@"DatabaseManager"
                                                          code:69
                                                      userInfo:@{NSLocalizedDescriptionKey: @"The previous database is not a regular store file."}];
        }
        return nil;
    }
    return [NSURL fileURLWithPath:storePath];
}

+ (NSURL*)_legacyMigrationSourceURLForTargetURL:(NSURL*)targetURL error:(NSError**)error
{
    NSURL* markerURL = [NSURL fileURLWithPath:[targetURL.path stringByAppendingString:@".migration-in-progress"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:markerURL.path]) {
        return nil;
    }

    id isSymbolicLink = nil;
    NSError* markerResourceError = nil;
    if (![markerURL getResourceValue:&isSymbolicLink forKey:NSURLIsSymbolicLinkKey error:&markerResourceError] ||
        [isSymbolicLink boolValue]) {
        if (error) {
            *error = markerResourceError ?: [NSError errorWithDomain:@"DatabaseManager"
                                                                 code:70
                                                             userInfo:@{NSLocalizedDescriptionKey: @"The previous database migration marker is not a regular file."}];
        }
        return nil;
    }

    NSError* readError = nil;
    NSString* markedSourcePath = [NSString stringWithContentsOfURL:markerURL
                                                          encoding:NSUTF8StringEncoding
                                                             error:&readError];
    NSString* documentsPath = self.pathToDocuments.stringByStandardizingPath;
    NSRange documentsRange = [markedSourcePath rangeOfString:@"/Documents/" options:NSBackwardsSearch];
    if (!markedSourcePath || documentsRange.location == NSNotFound) {
        if (error) {
            *error = readError ?: [NSError errorWithDomain:@"DatabaseManager"
                                                      code:71
                                                  userInfo:@{NSLocalizedDescriptionKey: @"The previous database migration marker is damaged."}];
        }
        return nil;
    }

    NSUInteger relativeStart = NSMaxRange(documentsRange);
    NSString* relativePath = [markedSourcePath substringFromIndex:relativeStart];
    NSURL* sourceURL = [NSURL fileURLWithPath:[documentsPath stringByAppendingPathComponent:relativePath]];
    sourceURL = [self _validatedLegacyDataStoreURL:sourceURL error:error];
    if (!sourceURL) {
        return nil;
    }

    NSInteger targetGeneration = [self _dataStoreGenerationForURL:targetURL];
    NSInteger sourceGeneration = [self _dataStoreGenerationForURL:sourceURL];
    if (sourceGeneration >= targetGeneration) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:72
                                     userInfo:@{NSLocalizedDescriptionKey: @"The previous database migration marker does not reference an older store."}];
        }
        return nil;
    }
    return sourceURL;
}

+ (NSURL*)_authoritativeSourceDataStoreURLWithError:(NSError**)error
{
    NSURL* sourceURL = [self _urlOfLastDataStoreFile];
    NSMutableSet<NSString*>* visitedPaths = [NSMutableSet set];
    while ([[NSFileManager defaultManager] fileExistsAtPath:sourceURL.path]) {
        sourceURL = [self _validatedLegacyDataStoreURL:sourceURL error:error];
        if (!sourceURL) {
            return nil;
        }
        if ([visitedPaths containsObject:sourceURL.path]) {
            if (error) {
                *error = [NSError errorWithDomain:@"DatabaseManager"
                                             code:73
                                         userInfo:@{NSLocalizedDescriptionKey: @"The previous database migration markers contain a cycle."}];
            }
            return nil;
        }
        [visitedPaths addObject:sourceURL.path];

        NSError* markerError = nil;
        NSURL* markedSourceURL = [self _legacyMigrationSourceURLForTargetURL:sourceURL error:&markerError];
        if (markerError) {
            if (error) *error = markerError;
            return nil;
        }
        if (!markedSourceURL) {
            return sourceURL;
        }
        sourceURL = markedSourceURL;
    }
    return sourceURL;
}

+ (NSURL*)_currentDataStoreURL
{
    NSString* dataPath = [self pathToSubfolder:@"Data" parent:[self pathToDocuments]];
    return dataPath.length > 0 ? [NSURL fileURLWithPath:[dataPath stringByAppendingPathComponent:_DataStoreFile()]] : nil;
}

+ (NSURL*)_dataStoreMigrationMarkerURL
{
    NSURL* storeURL = [self _currentDataStoreURL];
    return storeURL ? [NSURL fileURLWithPath:[storeURL.path stringByAppendingString:@".migration-in-progress"]] : nil;
}

+ (NSError*)_dataStoreMigrationErrorWithUnderlyingError:(NSError*)underlyingError
{
    NSMutableDictionary* userInfo = [@{
        NSLocalizedDescriptionKey: @"InstacastPlus could not update the local podcast database. Your data was left unchanged. Make sure enough storage is available, restart the device, and try again.".ls,
    } mutableCopy];
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:@"DatabaseManager" code:42 userInfo:userInfo];
}

+ (NSString*)_relativeDataStorePathForURL:(NSURL*)storeURL error:(NSError**)error
{
    NSString* documentsPath = self.pathToDocuments.stringByStandardizingPath;
    NSString* storePath = storeURL.path.stringByStandardizingPath;
    NSString* documentsPrefix = [documentsPath stringByAppendingString:@"/"];
    if (documentsPath.length == 0 || storePath.length == 0 || ![storePath hasPrefix:documentsPrefix]) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:43
                                     userInfo:@{NSLocalizedDescriptionKey: @"The database migration path is outside the app's Documents directory."}];
        }
        return nil;
    }
    return [storePath substringFromIndex:documentsPrefix.length];
}

+ (NSURL*)_dataStoreURLForRelativePath:(NSString*)relativePath error:(NSError**)error
{
    if (relativePath.length == 0 || relativePath.isAbsolutePath) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:44
                                     userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker contains an invalid path."}];
        }
        return nil;
    }

    NSURL* storeURL = [NSURL fileURLWithPath:[[self pathToDocuments] stringByAppendingPathComponent:relativePath]];
    NSString* canonicalRelativePath = [self _relativeDataStorePathForURL:storeURL error:error];
    if (!canonicalRelativePath || ![canonicalRelativePath isEqualToString:relativePath]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:45
                                     userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker path is not canonical."}];
        }
        return nil;
    }
    return storeURL;
}

+ (NSDictionary*)_readDataStoreMigrationMarkerWithError:(NSError**)error
{
    NSURL* markerURL = [self _dataStoreMigrationMarkerURL];
    NSData* markerData = markerURL ? [NSData dataWithContentsOfURL:markerURL options:0 error:error] : nil;
    if (!markerData) {
        return nil;
    }

    id propertyList = [NSPropertyListSerialization propertyListWithData:markerData
                                                                 options:NSPropertyListImmutable
                                                                  format:nil
                                                                   error:error];
    if (![propertyList isKindOfClass:NSDictionary.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:46
                                     userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker is damaged."}];
        }
        return nil;
    }
    return propertyList;
}

+ (BOOL)_writeDataStoreMigrationMarker:(NSDictionary*)marker error:(NSError**)error
{
    NSData* markerData = [NSPropertyListSerialization dataWithPropertyList:marker
                                                                     format:NSPropertyListBinaryFormat_v1_0
                                                                    options:0
                                                                      error:error];
    if (!markerData) {
        return NO;
    }
    return [markerData writeToURL:[self _dataStoreMigrationMarkerURL]
                          options:NSDataWritingAtomic
                            error:error];
}

+ (BOOL)_removePreparedDataStoreAtURL:(NSURL*)storeURL error:(NSError**)error
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    for (NSString* suffix in @[@"", @"-wal", @"-shm", @"-journal"]) {
        NSURL* fileURL = [NSURL fileURLWithPath:[storeURL.path stringByAppendingString:suffix]];
        if (![fileManager fileExistsAtPath:fileURL.path]) {
            continue;
        }
        if (![fileManager removeItemAtURL:fileURL error:error]) {
            return NO;
        }
    }
    return YES;
}

+ (NSManagedObjectModel*)_compatibleSourceModelForMetadata:(NSDictionary*)metadata error:(NSError**)error
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSURL*>* modelURLs = [NSMutableArray array];
    for (NSURL* modelDirectoryURL in [[NSBundle mainBundle] URLsForResourcesWithExtension:@"momd" subdirectory:nil] ?: @[]) {
        NSArray<NSURL*>* children = [fileManager contentsOfDirectoryAtURL:modelDirectoryURL
                                                includingPropertiesForKeys:nil
                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                     error:nil];
        for (NSURL* childURL in children) {
            if ([childURL.pathExtension isEqualToString:@"mom"]) {
                [modelURLs addObject:childURL];
            }
        }
    }
    [modelURLs addObjectsFromArray:[[NSBundle mainBundle] URLsForResourcesWithExtension:@"mom" subdirectory:nil] ?: @[]];
    [modelURLs sortUsingComparator:^NSComparisonResult(NSURL* left, NSURL* right) {
        return [left.path compare:right.path];
    }];

    NSManagedObjectModel* compatibleSourceModel = nil;
    NSDictionary* compatibleHashes = nil;
    for (NSURL* modelURL in modelURLs) {
        NSManagedObjectModel* candidate = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
        if (!candidate || ![candidate isConfiguration:nil compatibleWithStoreMetadata:metadata]) {
            continue;
        }
        if (!compatibleSourceModel) {
            compatibleSourceModel = candidate;
            compatibleHashes = candidate.entityVersionHashesByName;
        }
        else if (![compatibleHashes isEqualToDictionary:candidate.entityVersionHashesByName]) {
            if (error) {
                *error = [NSError errorWithDomain:@"DatabaseManager"
                                             code:47
                                         userInfo:@{NSLocalizedDescriptionKey: @"More than one bundled database model matches the existing store."}];
            }
            return nil;
        }
    }

    if (!compatibleSourceModel && error) {
        *error = [NSError errorWithDomain:@"DatabaseManager"
                                     code:48
                                 userInfo:@{NSLocalizedDescriptionKey: @"No bundled database model matches the existing store."}];
    }
    return compatibleSourceModel;
}

+ (BOOL)_lightweightMigrateCurrentDataStoreAtURL:(NSURL*)storeURL
                                    sourceMetadata:(NSDictionary*)sourceMetadata
                                             error:(NSError**)error
{
    NSManagedObjectModel* sourceModel = [self _compatibleSourceModelForMetadata:sourceMetadata
                                                                          error:error];
    NSString* sourceStoreUUID = sourceMetadata[NSStoreUUIDKey];
    if (!sourceModel || sourceStoreUUID.length == 0) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:71
                                     userInfo:@{NSLocalizedDescriptionKey: @"The existing database identity could not be verified for the model update."}];
        }
        return NO;
    }
    NSDictionary* sourceCounts = [self _entityCountsAtStoreURL:storeURL
                                                          model:sourceModel
                                                        options:@{NSPersistentHistoryTrackingKey: @NO}
                                                          error:error];
    if (!sourceCounts) {
        return NO;
    }

    NSURL* modelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
    NSManagedObjectModel* currentModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    NSPersistentStoreCoordinator* coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:currentModel];
    NSDictionary* options = @{
        NSMigratePersistentStoresAutomaticallyOption: @YES,
        NSInferMappingModelAutomaticallyOption: @YES,
        NSPersistentHistoryTrackingKey: @NO,
    };
    NSError* migrationError = nil;
    NSPersistentStore* store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                          configuration:nil
                                                                    URL:storeURL
                                                                options:options
                                                                  error:&migrationError];
    if (!store) {
        if (error) *error = migrationError;
        return NO;
    }
    if (![coordinator removePersistentStore:store error:&migrationError]) {
        if (error) *error = migrationError;
        return NO;
    }
    return [self _validatePreparedStoreAtURL:storeURL
                               expectedCounts:sourceCounts
                            expectedStoreUUID:sourceStoreUUID
                                        error:error];
}

+ (NSDictionary<NSString*, NSNumber*>*)_entityCountsAtStoreURL:(NSURL*)storeURL
                                                         model:(NSManagedObjectModel*)model
                                                       options:(NSDictionary*)options
                                                         error:(NSError**)error
{
    NSPersistentStoreCoordinator* coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSError* addError = nil;
    NSPersistentStore* store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                         configuration:nil
                                                                   URL:storeURL
                                                               options:options
                                                                 error:&addError];
    if (!store) {
        if (error) *error = addError;
        return nil;
    }

    NSManagedObjectContext* context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = coordinator;
    context.undoManager = nil;
    __block NSError* countError = nil;
    __block NSMutableDictionary<NSString*, NSNumber*>* entityCounts = [NSMutableDictionary dictionary];
    NSArray<NSEntityDescription*>* entities = [model.entities sortedArrayUsingComparator:^NSComparisonResult(NSEntityDescription* left, NSEntityDescription* right) {
        return [left.name compare:right.name];
    }];
    [context performBlockAndWait:^{
        for (NSEntityDescription* entity in entities) {
            if (entity.isAbstract || entity.name.length == 0) {
                continue;
            }
            NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:entity.name];
            request.includesSubentities = NO;
            NSUInteger count = [context countForFetchRequest:request error:&countError];
            if (count == NSNotFound) {
                break;
            }
            entityCounts[entity.name] = @(count);
        }
        [context reset];
        context.persistentStoreCoordinator = nil;
    }];

    NSError* removeError = nil;
    if (![coordinator removePersistentStore:store error:&removeError] && !countError) {
        countError = removeError;
    }
    if (countError) {
        if (error) *error = countError;
        return nil;
    }
    return entityCounts;
}

+ (BOOL)_sqliteStoreAtURLIsClean:(NSURL*)storeURL error:(NSError**)error
{
    sqlite3* database = NULL;
    int openResult = sqlite3_open_v2(storeURL.path.fileSystemRepresentation,
                                    &database,
                                    SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                                    NULL);
    if (openResult != SQLITE_OK) {
        NSString* message = database ? [NSString stringWithUTF8String:sqlite3_errmsg(database)] : @"SQLite could not open the prepared store.";
        if (database) sqlite3_close(database);
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:49 userInfo:@{NSLocalizedDescriptionKey: message ?: @"SQLite open failed."}];
        }
        return NO;
    }

    BOOL valid = NO;
    sqlite3_stmt* statement = NULL;
    int prepareResult = sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, NULL);
    if (prepareResult == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char* result = sqlite3_column_text(statement, 0);
        valid = result && strcmp((const char*)result, "ok") == 0 && sqlite3_step(statement) == SQLITE_DONE;
    }
    sqlite3_finalize(statement);

    NSInteger obsoleteTableCount = -1;
    statement = NULL;
    const char* obsoleteTableQuery = "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND (name LIKE 'ANSCK%' OR name IN ('ACHANGE', 'ATRANSACTION', 'ATRANSACTIONSTRING'))";
    if (valid && sqlite3_prepare_v2(database, obsoleteTableQuery, -1, &statement, NULL) == SQLITE_OK && sqlite3_step(statement) == SQLITE_ROW) {
        obsoleteTableCount = sqlite3_column_int64(statement, 0);
    }
    sqlite3_finalize(statement);

    NSString* sqliteMessage = [NSString stringWithUTF8String:sqlite3_errmsg(database)] ?: @"SQLite validation failed.";
    sqlite3_close(database);
    if (!valid || obsoleteTableCount != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager"
                                         code:50
                                     userInfo:@{NSLocalizedDescriptionKey: valid ? @"The prepared database still contains obsolete CloudKit or history tables." : sqliteMessage}];
        }
        return NO;
    }
    return YES;
}

+ (BOOL)_validatePreparedStoreAtURL:(NSURL*)storeURL
                     expectedCounts:(NSDictionary<NSString*, NSNumber*>*)expectedCounts
                  expectedStoreUUID:(NSString*)expectedStoreUUID
                              error:(NSError**)error
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:storeURL.path]) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:51 userInfo:@{NSLocalizedDescriptionKey: @"The prepared database file is missing."}];
        }
        return NO;
    }
    if (![self _sqliteStoreAtURLIsClean:storeURL error:error]) {
        return NO;
    }

    NSError* metadataError = nil;
    NSDictionary* metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                         URL:storeURL
                                                                                     options:nil
                                                                                       error:&metadataError];
    NSString* storeUUID = metadata[NSStoreUUIDKey];
    if (!metadata || expectedStoreUUID.length == 0 || ![storeUUID isEqualToString:expectedStoreUUID]) {
        if (error) {
            *error = metadataError ?: [NSError errorWithDomain:@"DatabaseManager" code:52 userInfo:@{NSLocalizedDescriptionKey: @"The prepared database identity does not match its migration marker."}];
        }
        return NO;
    }

    NSURL* modelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
    NSManagedObjectModel* currentModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    if (![currentModel isConfiguration:nil compatibleWithStoreMetadata:metadata]) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:53 userInfo:@{NSLocalizedDescriptionKey: @"The prepared database does not match the current model."}];
        }
        return NO;
    }

    if (expectedCounts) {
        NSDictionary* entityCounts = [self _entityCountsAtStoreURL:storeURL
                                                              model:currentModel
                                                            options:@{NSPersistentHistoryTrackingKey: @NO}
                                                              error:error];
        if (!entityCounts || ![entityCounts isEqualToDictionary:expectedCounts]) {
            if (error && !*error) {
                *error = [NSError errorWithDomain:@"DatabaseManager" code:54 userInfo:@{NSLocalizedDescriptionKey: @"The prepared database is incomplete."}];
            }
            return NO;
        }
    }
    return YES;
}

+ (BOOL)_prepareDataStoreMigrationWithError:(NSError**)error
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSURL* targetURL = [self _currentDataStoreURL];
    NSURL* markerURL = [self _dataStoreMigrationMarkerURL];
    if (!targetURL || !markerURL) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:55 userInfo:@{NSLocalizedDescriptionKey: @"The database directory is unavailable."}];
        }
        return NO;
    }

    NSDictionary* marker = nil;
    if ([fileManager fileExistsAtPath:markerURL.path]) {
        marker = [self _readDataStoreMigrationMarkerWithError:error];
        if (!marker) return NO;
    }
    else if ([fileManager fileExistsAtPath:targetURL.path]) {
        NSError* metadataError = nil;
        NSDictionary* metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                             URL:targetURL
                                                                                         options:nil
                                                                                           error:&metadataError];
        NSURL* modelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
        NSManagedObjectModel* currentModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
        if (!metadata) {
            if (error) *error = metadataError ?: [NSError errorWithDomain:@"DatabaseManager" code:56 userInfo:@{NSLocalizedDescriptionKey: @"The current database metadata could not be read."}];
            return NO;
        }
        if (![currentModel isConfiguration:nil compatibleWithStoreMetadata:metadata]) {
            return [self _lightweightMigrateCurrentDataStoreAtURL:targetURL
                                                    sourceMetadata:metadata
                                                             error:error];
        }
        return YES;
    }
    else {
        NSURL* sourceURL = [self _authoritativeSourceDataStoreURLWithError:error];
        if (!sourceURL && error && *error) {
            return NO;
        }
        if (![fileManager fileExistsAtPath:sourceURL.path]) {
            return YES;
        }

        NSError* metadataError = nil;
        NSDictionary* sourceMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                                    URL:sourceURL
                                                                                                options:nil
                                                                                                  error:&metadataError];
        NSString* sourceStoreUUID = sourceMetadata[NSStoreUUIDKey];
        NSString* sourcePath = [self _relativeDataStorePathForURL:sourceURL error:error];
        NSString* targetPath = [self _relativeDataStorePathForURL:targetURL error:error];
        if (!sourceMetadata || sourceStoreUUID.length == 0 || !sourcePath || !targetPath) {
            if (error && !*error) *error = metadataError ?: [NSError errorWithDomain:@"DatabaseManager" code:57 userInfo:@{NSLocalizedDescriptionKey: @"The existing database identity could not be read."}];
            return NO;
        }
        if (![self _compatibleSourceModelForMetadata:sourceMetadata error:error]) {
            return NO;
        }

        marker = @{
            ICDataStoreMigrationFormatVersionKey: @(ICDataStoreMigrationFormatVersion),
            ICDataStoreMigrationGenerationKey: @(DATA_STORE_GENERATION),
            ICDataStoreMigrationPhaseKey: ICDataStoreMigrationPhaseBuilding,
            ICDataStoreMigrationSourcePathKey: sourcePath,
            ICDataStoreMigrationTargetPathKey: targetPath,
            ICDataStoreMigrationSourceStoreUUIDKey: sourceStoreUUID,
        };
        if (![self _writeDataStoreMigrationMarker:marker error:error]) {
            return NO;
        }
    }

    NSString* phase = marker[ICDataStoreMigrationPhaseKey];
    NSString* sourcePath = marker[ICDataStoreMigrationSourcePathKey];
    NSString* targetPath = marker[ICDataStoreMigrationTargetPathKey];
    NSNumber* formatVersion = marker[ICDataStoreMigrationFormatVersionKey];
    NSNumber* generation = marker[ICDataStoreMigrationGenerationKey];
    NSString* sourceStoreUUID = marker[ICDataStoreMigrationSourceStoreUUIDKey];
    if (![phase isKindOfClass:NSString.class] || ![sourcePath isKindOfClass:NSString.class] ||
        ![targetPath isKindOfClass:NSString.class] || ![formatVersion isKindOfClass:NSNumber.class] ||
        ![generation isKindOfClass:NSNumber.class] || ![sourceStoreUUID isKindOfClass:NSString.class] ||
        formatVersion.integerValue != ICDataStoreMigrationFormatVersion || generation.integerValue != DATA_STORE_GENERATION) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:58 userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker is invalid."}];
        }
        return NO;
    }

    NSString* markerTargetStoreUUID = marker[ICDataStoreMigrationTargetStoreUUIDKey];
    NSDictionary* markerEntityCounts = marker[ICDataStoreMigrationEntityCountsKey];
    BOOL markerIsReady = [phase isEqualToString:ICDataStoreMigrationPhaseReady];
    BOOL markerIsCommitting = [phase isEqualToString:ICDataStoreMigrationPhaseCommitting];
    BOOL preparedMarkerHasValidTypes =
        (!markerIsReady && !markerIsCommitting) ||
        ([markerTargetStoreUUID isKindOfClass:NSString.class] &&
         (!markerIsReady || [markerEntityCounts isKindOfClass:NSDictionary.class]));
    if (!preparedMarkerHasValidTypes) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:58 userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker is invalid."}];
        }
        return NO;
    }

    NSURL* sourceURL = [self _dataStoreURLForRelativePath:sourcePath error:error];
    sourceURL = sourceURL ? [self _validatedLegacyDataStoreURL:sourceURL error:error] : nil;
    NSURL* markedTargetURL = [self _dataStoreURLForRelativePath:targetPath error:error];
    if (!sourceURL || !markedTargetURL || ![markedTargetURL.path isEqualToString:targetURL.path] || [sourceURL.path isEqualToString:targetURL.path]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:59 userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker targets an unexpected store."}];
        }
        return NO;
    }
    if (![fileManager fileExistsAtPath:sourceURL.path]) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:60 userInfo:@{NSLocalizedDescriptionKey: @"The source database needed to finish the update is missing."}];
        }
        return NO;
    }

    NSError* sourceMetadataError = nil;
    NSDictionary* sourceMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                               URL:sourceURL
                                                                                           options:nil
                                                                                             error:&sourceMetadataError];
    if (!sourceMetadata || ![sourceMetadata[NSStoreUUIDKey] isEqualToString:sourceStoreUUID]) {
        if (error) *error = sourceMetadataError ?: [NSError errorWithDomain:@"DatabaseManager" code:61 userInfo:@{NSLocalizedDescriptionKey: @"The source database no longer matches the migration marker."}];
        return NO;
    }
    NSManagedObjectModel* compatibleSourceModel = [self _compatibleSourceModelForMetadata:sourceMetadata error:error];
    if (!compatibleSourceModel) {
        return NO;
    }

    if ([phase isEqualToString:ICDataStoreMigrationPhaseCommitting] ||
        [phase isEqualToString:ICDataStoreMigrationPhaseReady]) {
        NSError* validationError = nil;
        if ([self _validatePreparedStoreAtURL:targetURL
                               expectedCounts:nil
                            expectedStoreUUID:markerTargetStoreUUID
                                        error:&validationError]) {
            return YES;
        }
        NSError* targetMetadataError = nil;
        NSDictionary* targetMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                                    URL:targetURL
                                                                                                options:nil
                                                                                                  error:&targetMetadataError];
        NSURL* currentModelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
        NSManagedObjectModel* currentModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:currentModelURL];
        BOOL markerIdentityMatches = [targetMetadata[NSStoreUUIDKey] isEqualToString:markerTargetStoreUUID];
        if (targetMetadata && markerIdentityMatches &&
            ![currentModel isConfiguration:nil compatibleWithStoreMetadata:targetMetadata]) {
            return [self _lightweightMigrateCurrentDataStoreAtURL:targetURL
                                                    sourceMetadata:targetMetadata
                                                             error:error];
        }
        if ([phase isEqualToString:ICDataStoreMigrationPhaseCommitting]) {
            if (error) *error = validationError ?: targetMetadataError;
            return NO;
        }
    }

    if ([phase isEqualToString:ICDataStoreMigrationPhaseReady]) {
        NSMutableDictionary* rebuildingMarker = [marker mutableCopy];
        rebuildingMarker[ICDataStoreMigrationPhaseKey] = ICDataStoreMigrationPhaseBuilding;
        [rebuildingMarker removeObjectForKey:ICDataStoreMigrationEntityCountsKey];
        [rebuildingMarker removeObjectForKey:ICDataStoreMigrationTargetStoreUUIDKey];
        if (![self _writeDataStoreMigrationMarker:rebuildingMarker error:error]) {
            return NO;
        }
        marker = rebuildingMarker;
        phase = ICDataStoreMigrationPhaseBuilding;
    }

    if (![phase isEqualToString:ICDataStoreMigrationPhaseBuilding]) {
        if (error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:62 userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker has an unknown phase."}];
        }
        return NO;
    }

    NSDictionary* sourceOptions = @{NSPersistentHistoryTrackingKey: @YES};
    NSDictionary* sourceEntityCounts = [self _entityCountsAtStoreURL:sourceURL
                                                                model:compatibleSourceModel
                                                              options:sourceOptions
                                                                error:error];
    if (!sourceEntityCounts) {
        return NO;
    }
    if (![self _removePreparedDataStoreAtURL:targetURL error:error]) {
        return NO;
    }

    NSPersistentStoreCoordinator* sourceCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:compatibleSourceModel];
    NSError* migrationError = nil;
    NSPersistentStore* sourceStore = [sourceCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                      configuration:nil
                                                                                URL:sourceURL
                                                                            options:sourceOptions
                                                                              error:&migrationError];
    if (!sourceStore) {
        if (error) *error = migrationError;
        return NO;
    }

    NSDictionary* targetOptions = @{NSPersistentHistoryTrackingKey: @NO};
    NSPersistentStore* migratedStore = [sourceCoordinator migratePersistentStore:sourceStore
                                                                            toURL:targetURL
                                                                          options:targetOptions
                                                                         withType:NSSQLiteStoreType
                                                                            error:&migrationError];
    if (!migratedStore) {
        if ([sourceCoordinator.persistentStores containsObject:sourceStore]) {
            [sourceCoordinator removePersistentStore:sourceStore error:nil];
        }
        if (error) *error = migrationError;
        return NO;
    }
    if (![sourceCoordinator removePersistentStore:migratedStore error:&migrationError]) {
        if (error) *error = migrationError;
        return NO;
    }

    NSURL* currentModelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
    NSManagedObjectModel* currentModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:currentModelURL];
    NSError* targetMetadataError = nil;
    NSDictionary* targetMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                               URL:targetURL
                                                                                           options:nil
                                                                                             error:&targetMetadataError];
    if (!targetMetadata) {
        if (error) *error = targetMetadataError;
        return NO;
    }
    if (![currentModel isConfiguration:nil compatibleWithStoreMetadata:targetMetadata]) {
        NSPersistentStoreCoordinator* migrationCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:currentModel];
        NSDictionary* lightweightOptions = @{
            NSMigratePersistentStoresAutomaticallyOption: @YES,
            NSInferMappingModelAutomaticallyOption: @YES,
            NSPersistentHistoryTrackingKey: @NO,
        };
        NSPersistentStore* currentStore = [migrationCoordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                              configuration:nil
                                                                                        URL:targetURL
                                                                                    options:lightweightOptions
                                                                                      error:&migrationError];
        if (!currentStore || ![migrationCoordinator removePersistentStore:currentStore error:&migrationError]) {
            if (error) *error = migrationError;
            return NO;
        }
    }

    NSDictionary* entityCounts = [self _entityCountsAtStoreURL:targetURL
                                                          model:currentModel
                                                        options:@{NSPersistentHistoryTrackingKey: @NO}
                                                          error:error];
    if (!entityCounts) {
        return NO;
    }
    NSMutableDictionary* sourceProjection = [NSMutableDictionary dictionaryWithCapacity:sourceEntityCounts.count];
    NSMutableDictionary* targetProjection = [NSMutableDictionary dictionaryWithCapacity:sourceEntityCounts.count];
    for (NSString* entityName in sourceEntityCounts) {
        NSNumber* targetCount = entityCounts[entityName];
        if (!targetCount) {
            if (error) {
                *error = [NSError errorWithDomain:@"DatabaseManager" code:63 userInfo:@{NSLocalizedDescriptionKey: @"The migrated database is missing an entity from the source model."}];
            }
            return NO;
        }
        sourceProjection[entityName] = sourceEntityCounts[entityName];
        targetProjection[entityName] = targetCount;
    }
    if (![sourceProjection isEqualToDictionary:targetProjection] || ![self _sqliteStoreAtURLIsClean:targetURL error:error]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"DatabaseManager" code:64 userInfo:@{NSLocalizedDescriptionKey: @"The migrated database failed verification."}];
        }
        return NO;
    }

    targetMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                 URL:targetURL
                                                                             options:nil
                                                                               error:&targetMetadataError];
    NSString* targetStoreUUID = targetMetadata[NSStoreUUIDKey];
    if (targetStoreUUID.length == 0) {
        if (error) *error = targetMetadataError ?: [NSError errorWithDomain:@"DatabaseManager" code:65 userInfo:@{NSLocalizedDescriptionKey: @"The migrated database identity could not be read."}];
        return NO;
    }

    NSMutableDictionary* readyMarker = [marker mutableCopy];
    readyMarker[ICDataStoreMigrationPhaseKey] = ICDataStoreMigrationPhaseReady;
    readyMarker[ICDataStoreMigrationEntityCountsKey] = entityCounts;
    readyMarker[ICDataStoreMigrationTargetStoreUUIDKey] = targetStoreUUID;
    return [self _writeDataStoreMigrationMarker:readyMarker error:error];
}

+ (void) prepareDataStoreMigrationWithCompletion:(void (^)(NSError* error))completion
{
    static dispatch_queue_t migrationQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                   QOS_CLASS_UTILITY,
                                                                                   0);
        migrationQueue = dispatch_queue_create("com.instacastplus.datastore-migration", attributes);
    });
    dispatch_async(migrationQueue, ^{
        @autoreleasepool {
            NSError* migrationError = nil;
            BOOL success = [self _prepareDataStoreMigrationWithError:&migrationError];
            NSError* presentedError = success ? nil : [self _dataStoreMigrationErrorWithUnderlyingError:migrationError];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(presentedError);
            });
        }
    });
}

+ (BOOL) dataStoreNeedsMigrationForFileAtURL:(NSURL*)storeURL
{
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
    NSManagedObjectModel* destinationModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    NSError *error = nil;
    NSDictionary *sourceMetadata = nil;
    @try {
        sourceMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                    URL:storeURL
                                                                                options:nil
                                                                                  error:&error];
    }
    @catch (__unused NSException *exception) {
    }
    return !sourceMetadata || ![destinationModel isConfiguration:nil compatibleWithStoreMetadata:sourceMetadata];
}

+ (BOOL) dataStoreNeedsMigration
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSURL* storeURL = [self _currentDataStoreURL];
    NSURL* migrationMarkerURL = [self _dataStoreMigrationMarkerURL];
    if ([fileManager fileExistsAtPath:migrationMarkerURL.path]) {
        return YES;
    }
    if ([fileManager fileExistsAtPath:storeURL.path]) {
        return [self dataStoreNeedsMigrationForFileAtURL:storeURL];
    }

    NSURL* previousStoreURL = [self _urlOfLastDataStoreFile];
    return [fileManager fileExistsAtPath:previousStoreURL.path];
}

- (id) init
{
	if ((self = [super init]))
	{
        // Ensure Data subfolder exists
        NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]];
        if (dataPath.length == 0) {
            self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:nil];
            return self;
        }

        _databaseURL = [NSURL fileURLWithPath:[dataPath stringByAppendingPathComponent:_DataStoreFile()]];

        NSString* imageCachePath = [DatabaseManager pathToSubfolder:@"Images" parent:[DatabaseManager pathToDocuments]];
        NSString* fileCachePath = [DatabaseManager pathToSubfolder:@"Episodes" parent:[DatabaseManager pathToDocuments]];
        _imageCacheURL = imageCachePath.length > 0 ? [NSURL fileURLWithPath:imageCachePath] : nil;
        _fileCacheURL = fileCachePath.length > 0 ? [NSURL fileURLWithPath:fileCachePath] : nil;
        AddSkipBackupAttributeToFile(fileCachePath);

        // Migrate: move database files from old Documents root to Data subfolder
        [DatabaseManager _migrateRootFilesToDataFolder];

        NSFileManager* fileManager = [NSFileManager defaultManager];
        NSURL* migrationMarkerURL = [DatabaseManager _dataStoreMigrationMarkerURL];
        NSURL* previousStoreURL = [DatabaseManager _urlOfLastDataStoreFile];
        BOOL legacyStoreExists = [fileManager fileExistsAtPath:previousStoreURL.path];
        BOOL migrationInProgress = [fileManager fileExistsAtPath:migrationMarkerURL.path];

        // The asynchronous preparation owns all destructive work. Initialization may only open
        // a fully verified target (ready), or resume the app's idempotent post-migration saves
        // (committing). A building/invalid marker must never expose a killed, empty SQLite file.
        if (migrationInProgress) {
            NSError* markerError = nil;
            NSDictionary* marker = [DatabaseManager _readDataStoreMigrationMarkerWithError:&markerError];
            BOOL markerHasValidTypes =
                [marker[ICDataStoreMigrationPhaseKey] isKindOfClass:NSString.class] &&
                [marker[ICDataStoreMigrationSourcePathKey] isKindOfClass:NSString.class] &&
                [marker[ICDataStoreMigrationTargetPathKey] isKindOfClass:NSString.class] &&
                [marker[ICDataStoreMigrationFormatVersionKey] isKindOfClass:NSNumber.class] &&
                [marker[ICDataStoreMigrationGenerationKey] isKindOfClass:NSNumber.class] &&
                [marker[ICDataStoreMigrationEntityCountsKey] isKindOfClass:NSDictionary.class] &&
                [marker[ICDataStoreMigrationTargetStoreUUIDKey] isKindOfClass:NSString.class];
            if (!markerHasValidTypes) {
                NSError* invalidMarkerError = markerError ?: [NSError errorWithDomain:@"DatabaseManager"
                                                                                  code:66
                                                                              userInfo:@{NSLocalizedDescriptionKey: @"The database migration marker is invalid."}];
                self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:invalidMarkerError];
                return self;
            }
            NSString* phase = marker[ICDataStoreMigrationPhaseKey];
            NSString* sourcePath = marker[ICDataStoreMigrationSourcePathKey];
            NSString* targetPath = marker[ICDataStoreMigrationTargetPathKey];
            NSURL* sourceURL = [DatabaseManager _dataStoreURLForRelativePath:sourcePath error:&markerError];
            NSURL* targetURL = [DatabaseManager _dataStoreURLForRelativePath:targetPath error:&markerError];
            BOOL phaseCanOpen = [phase isEqualToString:ICDataStoreMigrationPhaseReady] ||
                                [phase isEqualToString:ICDataStoreMigrationPhaseCommitting];
            BOOL markerIsComplete = marker && phaseCanOpen &&
                                    [marker[ICDataStoreMigrationFormatVersionKey] integerValue] == ICDataStoreMigrationFormatVersion &&
                                    [marker[ICDataStoreMigrationGenerationKey] integerValue] == DATA_STORE_GENERATION &&
                                    [marker[ICDataStoreMigrationEntityCountsKey] isKindOfClass:NSDictionary.class] &&
                                    [marker[ICDataStoreMigrationTargetStoreUUIDKey] isKindOfClass:NSString.class] &&
                                    [targetURL.path isEqualToString:_databaseURL.path] &&
                                    [fileManager fileExistsAtPath:sourceURL.path] &&
                                    [fileManager fileExistsAtPath:targetURL.path];
            if (!markerIsComplete) {
                NSError* invalidMarkerError = markerError ?: [NSError errorWithDomain:@"DatabaseManager"
                                                                                  code:66
                                                                              userInfo:@{NSLocalizedDescriptionKey: @"The database update has not finished preparing a verified store."}];
                self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:invalidMarkerError];
                return self;
            }

            if ([phase isEqualToString:ICDataStoreMigrationPhaseReady]) {
                NSMutableDictionary* committingMarker = [marker mutableCopy];
                committingMarker[ICDataStoreMigrationPhaseKey] = ICDataStoreMigrationPhaseCommitting;
                if (![DatabaseManager _writeDataStoreMigrationMarker:committingMarker error:&markerError]) {
                    self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:markerError];
                    return self;
                }
            }
        }
        else if (![fileManager fileExistsAtPath:_databaseURL.path] && legacyStoreExists) {
            NSError* preparationRequiredError = [NSError errorWithDomain:@"DatabaseManager"
                                                                     code:67
                                                                 userInfo:@{NSLocalizedDescriptionKey: @"The existing database must be prepared before it can be opened."}];
            self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:preparationRequiredError];
            return self;
        }

        BOOL shouldCreateInitialData = ![fileManager fileExistsAtPath:[_databaseURL path]];
        NSManagedObjectContext* startupContext = self.objectContext;
        if (!startupContext) {
            if (!self.initializationError) {
                self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:nil];
            }
            return self;
        }

        // create initial data when started first
        if (shouldCreateInitialData) {
            [self _createDatabase];
        }
        else {
            [self _migrateDatabase];
            [self _deleteUnsubscribedFeeds];

            NSError* migrationCompletionError = [self saveReturningError];
            if (migrationCompletionError) {
                self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:migrationCompletionError];
                return self;
            }

            if (migrationInProgress) {
                NSError* markerRemovalError = nil;
                if (![fileManager removeItemAtURL:migrationMarkerURL error:&markerRemovalError]) {
                    self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:markerRemovalError];
                    return self;
                }
            }
            [self _deleteObsoleteDataStores];
        }

#if TARGET_OS_IPHONE
        NSFetchRequest* feedsRequest = [[NSFetchRequest alloc] init];
        feedsRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:self.objectContext];
        feedsRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == %@", @YES];
        feedsRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
        
        NSFetchRequest* listsRequest = [[NSFetchRequest alloc] init];
        listsRequest.entity = [NSEntityDescription entityForName:@"List" inManagedObjectContext:self.objectContext];
        listsRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
        
        NSFetchRequest* bookmarksRequest = [[NSFetchRequest alloc] init];
        bookmarksRequest.entity = [NSEntityDescription entityForName:@"Bookmark" inManagedObjectContext:self.objectContext];
        bookmarksRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"position" ascending:YES] ];
        
        

        [NSFetchedResultsController deleteCacheWithName:@"_databasemanager_feeds_"];
        _feedsController = [[NSFetchedResultsController alloc] initWithFetchRequest:feedsRequest
                                                               managedObjectContext:self.objectContext
                                                                 sectionNameKeyPath:nil
                                                                          cacheName:@"_databasemanager_feeds_"];
        _feedsController.delegate = self;
        [_feedsController performFetch:nil];

        _listsController = [[NSFetchedResultsController alloc] initWithFetchRequest:listsRequest
                                                               managedObjectContext:self.objectContext
                                                                 sectionNameKeyPath:nil
                                                                          cacheName:@"_databasemanager_lists_"];
        _listsController.delegate = self;
        [_listsController performFetch:nil];

        _bookmarksController = [[NSFetchedResultsController alloc] initWithFetchRequest:bookmarksRequest
                                                               managedObjectContext:self.objectContext
                                                                 sectionNameKeyPath:nil
                                                                          cacheName:@"_databasemanager_bookmarks_"];
        _bookmarksController.delegate = self;
#else
        _feedsController = [[NSArrayController alloc] initWithContent:nil];
        [_feedsController setManagedObjectContext:self.objectContext];
        [_feedsController setEntityName:@"Feed"];
        [_feedsController setFetchPredicate:[NSPredicate predicateWithFormat:@"subscribed == %@", @YES]];
        [_feedsController setSortDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]]];
        [_feedsController setAutomaticallyPreparesContent:YES];
        [_feedsController setAvoidsEmptySelection:NO];
        [_feedsController fetchWithRequest:nil merge:YES error:nil];
        
        
        _bookmarksController = [[NSArrayController alloc] initWithContent:nil];
        [_bookmarksController setManagedObjectContext:self.objectContext];
        [_bookmarksController setEntityName:@"Bookmark"];
        [_bookmarksController setSortDescriptors:@[ [[NSSortDescriptor alloc] initWithKey:@"position" ascending:YES] ]];
        [_bookmarksController setAutomaticallyPreparesContent:YES];
        [_bookmarksController setAvoidsEmptySelection:NO];
        [_bookmarksController fetchWithRequest:nil merge:YES error:nil];
        
        _listsController = [[NSArrayController alloc] initWithContent:nil];
        [_listsController setManagedObjectContext:self.objectContext];
        [_listsController setEntityName:@"List"];
        [_listsController setSortDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]]];
        [_listsController setAutomaticallyPreparesContent:YES];
        [_listsController setAvoidsEmptySelection:YES];
        [_listsController fetchWithRequest:nil merge:YES error:nil];
        
#endif
        
        
        _ftsController = [[ICFTSController alloc] initWithSearchIndexURL:[NSURL fileURLWithPath:[[DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]] stringByAppendingPathComponent:kCurrentFTSIndexFilename]]];
        [_ftsController open];
        _spotlightIndexer = [[ICSpotlightIndexer alloc] init];

        [self _migrateFTS];
        [self _migrateSpotlight];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextObjectsDidChangeNotification:)
                                                     name:NSManagedObjectContextObjectsDidChangeNotification
                                                   object:self.objectContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextWillSaveNotification:)
                                                     name:NSManagedObjectContextWillSaveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextDidSaveNotification:)
                                                     name:NSManagedObjectContextDidSaveNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(transcriptionDidChangeNotification:)
                                                     name:@"ICTranscriptionDidChangeNotification"
                                                   object:nil];
	}
	return self;
}

- (NSError*)_databaseInitializationErrorWithUnderlyingError:(NSError*)underlyingError
{
    NSMutableDictionary* userInfo = [@{
        NSLocalizedDescriptionKey: @"InstacastPlus could not open the local podcast database. Your data was left unchanged. Check the available storage, restart the device, and open InstacastPlus again.".ls,
    } mutableCopy];
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:@"DatabaseManager" code:40 userInfo:userInfo];
}

- (void) _createDatabase
{
    CDEpisodeList* favorites = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
    favorites.name = @"Favorites".ls;
    favorites.icon = @"List Favorites";
    favorites.rank = 0;
    favorites.notStarred = NO;
    favorites.orderBy = @"pubDate";
    favorites.descending = YES;
    favorites.groupByPodcast = NO;
    favorites.uid = @"default.favorites";


    CDEpisodeList* unplayed = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
    unplayed.name = @"Unplayed".ls;
    unplayed.icon = @"List Unplayed";
    unplayed.rank = 1;
    unplayed.played = NO;
    unplayed.orderBy = @"pubDate";
    unplayed.descending = YES;
    unplayed.groupByPodcast = NO;
    unplayed.uid = @"default.unplayed";


    CDEpisodeList* started = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
    started.name = @"Started".ls;
    started.icon = @"List Partially Played";
    started.rank = 2;
    started.unfinished = YES;
    started.unplayed = NO;
    started.played = NO;
    started.orderBy = @"lastPlayed";
    started.descending = YES;
    started.groupByPodcast = NO;
    started.uid = @"default.started";


    CDEpisodeList* downloaded = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
    downloaded.name = @"Downloaded".ls;
    downloaded.icon = @"List Downloaded";
    downloaded.rank = 3;
    downloaded.downloaded = YES;
    downloaded.notDownloaded = NO;
    downloaded.orderBy = @"pubDate";
    downloaded.descending = YES;
    downloaded.groupByPodcast = NO;
    downloaded.uid = @"default.downloaded";


    CDEpisodeList* video = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
    video.name = @"Videos".ls;
    video.icon = @"List Video";
    video.rank = 4;
    video.audio = NO;
    video.orderBy = @"pubDate";
    video.descending = YES;
    video.groupByPodcast = NO;
    video.uid = @"default.video";
    
    [self save];
}

- (void) _migrateOldSmartPlaylists
{
    NSFetchRequest* listsRequest = [[NSFetchRequest alloc] init];
    listsRequest.entity = [NSEntityDescription entityForName:@"List" inManagedObjectContext:self.objectContext];
    
    NSError* error;
    NSArray *fetchedResults = [self.objectContext executeFetchRequest:listsRequest error:&error];
    NSMutableDictionary<NSString*, CDList*>* uniqueRecords = [NSMutableDictionary dictionary];


    for (CDList *object in fetchedResults) {
        if (object.uid.length > 0 && !uniqueRecords[object.uid]) {
            uniqueRecords[object.uid] = object;
        }
    }

    NSArray<CDList*>* lists = uniqueRecords.allValues;
    
    for(CDList* list in lists)
    {
        if ([list isKindOfClass:[CDSmartPlaylist class]])
        {
            CDSmartPlaylist* smartPlaylist = (CDSmartPlaylist*)list;
            
            NSString* type = [smartPlaylist.smartPredicate objectForKey:@"type"];
            
            if ([type isEqualToString:kSmartListTypeUnplayed])
            {
                CDEpisodeList* newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
                newList.name = smartPlaylist.name;
                newList.icon = @"List Unplayed";
                newList.rank = smartPlaylist.rank;
                newList.played = NO;
                newList.orderBy = @"pubDate";
                newList.descending = YES;
                newList.groupByPodcast = NO;
                newList.uid = @"default.unplayed";
                
                [self.objectContext deleteObject:smartPlaylist];
                [self save];
            }
            
            else if ([type isEqualToString:kSmartListTypeStarred])
            {
                CDEpisodeList* newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
                newList.name = smartPlaylist.name;
                newList.icon = @"List Favorites";
                newList.rank = smartPlaylist.rank;
                newList.notStarred = NO;
                newList.orderBy = @"pubDate";
                newList.descending = YES;
                newList.groupByPodcast = NO;
                newList.uid = @"default.favorites";
                
                [self.objectContext deleteObject:smartPlaylist];
                [self save];
            }
            else if ([type isEqualToString:kSmartListTypeDownload])
            {
                CDEpisodeList* newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
                newList.name = smartPlaylist.name;
                newList.icon = @"List Downloaded";
                newList.rank = smartPlaylist.rank;
                newList.downloaded = YES;
                newList.notDownloaded = NO;
                newList.orderBy = @"pubDate";
                newList.descending = YES;
                newList.groupByPodcast = NO;
                newList.uid = @"default.downloaded";
                
                [self.objectContext deleteObject:smartPlaylist];
                [self save];
            }
            else if ([type isEqualToString:kSmartListTypePartiallyPlayed])
            {
                CDEpisodeList* newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
                newList.name = smartPlaylist.name;
                newList.icon = @"List Partially Played";
                newList.rank = smartPlaylist.rank;
                newList.played = NO;
                newList.unplayed = NO;
                newList.orderBy = @"pubDate";
                newList.descending = YES;
                newList.groupByPodcast = NO;
                newList.uid = @"default.partiallyplayed";
                
                [self.objectContext deleteObject:smartPlaylist];
                [self save];
            }
            else if ([type isEqualToString:kSmartListTypeMostRecent])
            {
                CDEpisodeList* newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
                newList.name = smartPlaylist.name;
                newList.icon = @"List Most Recent";
                newList.rank = smartPlaylist.rank;
                newList.orderBy = @"pubDate";
                newList.descending = YES;
                newList.groupByPodcast = NO;
                newList.uid = @"default.mostrecent";
                
                [self.objectContext deleteObject:smartPlaylist];
                [self save];
            }
            else if ([type isEqualToString:kSmartListTypeRecentlyPlayed])
            {
                CDEpisodeList* newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
                newList.name = smartPlaylist.name;
                newList.icon = @"List Recently Played";
                newList.rank = smartPlaylist.rank;
                newList.orderBy = @"lastPlayed";
                newList.descending = YES;
                newList.groupByPodcast = NO;
                newList.uid = @"default.recentlyplayed";
                
                [self.objectContext deleteObject:smartPlaylist];
                [self save];
            }
        }
    }
}

+ (NSString *)normalizedFeedURLStringForURLString:(NSString *)URLString {
    if (URLString.length == 0) return nil;
    NSURL *URL = [NSURL URLWithString:URLString];
    if (!URL) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (!components) return nil;
    components.scheme = components.scheme.lowercaseString;
    components.host = components.host.lowercaseString;
    if (components.path.length == 0) components.path = @"/";
    if ([components.path hasSuffix:@"/"] && components.path.length > 1) {
        components.path = [components.path substringToIndex:components.path.length - 1];
    }
    return components.URL.absoluteString;
}

+ (NSArray<NSString *> *)equivalentFeedURLStringsForURLString:(NSString *)URLString {
    NSString *normalizedURL = [self normalizedFeedURLStringForURLString:URLString];
    if (!normalizedURL) return @[];
    if ([normalizedURL hasPrefix:@"http://"]) {
        return @[normalizedURL, [@"https://" stringByAppendingString:[normalizedURL substringFromIndex:7]]];
    }
    if ([normalizedURL hasPrefix:@"https://"]) {
        return @[normalizedURL, [@"http://" stringByAppendingString:[normalizedURL substringFromIndex:8]]];
    }
    return @[normalizedURL];
}

- (void) _migrateFTS
{
    NSManagedObjectContext* committedChangesContext = [self newExportBackgroundContext];
    [self.ftsController setCommittedChangesManagedObjectContext:committedChangesContext];

    if ([USER_DEFAULTS integerForKey:kDefaultFTSIndexVersion] >= kFTSIndexVersion &&
        ![self.ftsController indexNeedsRebuild]) {
        [self _finalizeVersionedFTSMigration];
        return;
    }

    [self _beginFTSIndexing];

    NSManagedObjectContext* indexContext = [self newExportBackgroundContext];
    if (!indexContext) {
        ErrLog(@"FTS index rebuild could not open its read-only data context");
        [self _endFTSIndexing];
        return;
    }
    indexContext.undoManager = nil;

    [self.ftsController rebuildIndexWithManagedObjectContext:indexContext completion:^(NSError* error) {
        if (!error) {
            [USER_DEFAULTS setInteger:kFTSIndexVersion forKey:kDefaultFTSIndexVersion];
            [self _finalizeVersionedFTSMigration];
        }
        else {
            ErrLog(@"FTS index rebuild failed: %@", error);
        }
        [self _endFTSIndexing];
    }];
}

- (void)_finalizeVersionedFTSMigration
{
    // The previous build understands only the uncompressed filename. Publish its rebuild
    // request durably before removing that file, so a TestFlight rollback can never open an
    // empty index while still believing the legacy one-shot migration already completed.
    [USER_DEFAULTS setBool:NO forKey:kDefaultLegacyFTSMigrationDone];
    if (![USER_DEFAULTS synchronize]) {
        ErrLog(@"Could not persist the legacy FTS rebuild marker; keeping the rollback index");
        return;
    }

    NSString* documentsPath = [DatabaseManager pathToDocuments];
    NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:documentsPath];
    NSArray<NSString*>* suffixes = @[@"", @"-wal", @"-shm", @"-journal", @".dirty", @".rebuild"];
    for (NSString* directoryPath in @[documentsPath, dataPath]) {
        NSString* legacyPath = [directoryPath stringByAppendingPathComponent:kLegacyFTSIndexFilename];
        for (NSString* suffix in suffixes) {
            NSString* path = [legacyPath stringByAppendingString:suffix];
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
                continue;
            }
            NSError* cleanupError = nil;
            if (![[NSFileManager defaultManager] removeItemAtPath:path error:&cleanupError]) {
                ErrLog(@"Could not remove legacy FTS index item at %@: %@", path, cleanupError.localizedDescription);
            }
        }
    }
}

- (void)_beginFTSIndexing
{
    self.ftsIndexingOperationCount += 1;
    self.ftsIndexing = YES;
}

- (void)_endFTSIndexing
{
    NSAssert(self.ftsIndexingOperationCount > 0, @"Unbalanced FTS indexing operation");
    self.ftsIndexingOperationCount -= 1;
    self.ftsIndexing = self.ftsIndexingOperationCount > 0;
}

- (void) _migrateSpotlight
{
    if ([USER_DEFAULTS boolForKey:kDefaultSpotlightMigrationDone]) {
        return;
    }

    NSManagedObjectContext* childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [childContext setParentContext:self.objectContext];

    [childContext performBlock:^{
        NSFetchRequest* feedRequest = [[NSFetchRequest alloc] init];
        feedRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:childContext];
        feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
        feedRequest.fetchBatchSize = 25;

        NSError* error;
        NSArray* objects = [childContext executeFetchRequest:feedRequest error:&error];
        if (error) {
            ErrLog(@"error fetching feeds for spotlight from private context: %@", error);
        }

        [self.spotlightIndexer indexFeeds:objects];

        dispatch_async(dispatch_get_main_queue(), ^{
            [USER_DEFAULTS setBool:YES forKey:kDefaultSpotlightMigrationDone];
        });
    }];
}

- (void) _migrateDatabase
{
    // Timing per step: these run on the main context at launch, so a slow one freezes the UI.
    // A fresh install/first-launch after update prints where the time goes.
#define IC_MIGRATE_STEP(sel) do { \
    __unused CFAbsoluteTime _t0 = CFAbsoluteTimeGetCurrent(); \
    [self sel]; \
    DebugLog(@"[Migrate] %s %.1f ms", #sel, (CFAbsoluteTimeGetCurrent() - _t0) * 1000.0); \
} while (0)

    __unused CFAbsoluteTime migrateStart = CFAbsoluteTimeGetCurrent();
    IC_MIGRATE_STEP(_migrateOldSmartPlaylists);
    IC_MIGRATE_STEP(_migrateAddStartedList);
    IC_MIGRATE_STEP(_migrateDefaultListNamesToKeys);
    IC_MIGRATE_STEP(_migrateRemoveDuplicateFeeds);
    IC_MIGRATE_STEP(_migrateRemoveDuplicateLists);
    IC_MIGRATE_STEP(_ensureWidgetOnlyDefaultLists);
    IC_MIGRATE_STEP(_migrateDefaultListOrderOnce);
    IC_MIGRATE_STEP(_migrateRemoveObsoletePauseFeedProperty);
    DebugLog(@"[Migrate] TOTAL %.1f ms", (CFAbsoluteTimeGetCurrent() - migrateStart) * 1000.0);

#undef IC_MIGRATE_STEP
}

// Deletes old Core Data generations only after the verified current store has opened and saved.
// Legacy releases used both Documents/ and Documents/Data/, so cleanup must cover both locations.
+ (NSSet<NSString*>*)_obsoleteDataStoreFilenames
{
    NSArray<NSString*>* suffixes = @[@"", @"-wal", @"-shm", @"-journal", @".migration-in-progress"];
    NSMutableArray<NSString*>* baseNames = [NSMutableArray arrayWithObject:@"DataStore.sqlite"];
    for (NSInteger generation = 1; generation < DATA_STORE_GENERATION; generation++) {
        [baseNames addObject:[NSString stringWithFormat:@"DataStore%ld.sqlite", (long)generation]];
    }

    NSMutableSet<NSString*>* filenames = [NSMutableSet set];
    for (NSString* baseName in baseNames) {
        for (NSString* suffix in suffixes) {
            [filenames addObject:[baseName stringByAppendingString:suffix]];
        }
    }
    return filenames;
}

+ (BOOL)_isRemovableObsoleteDataStoreItemAtURL:(NSURL*)itemURL
{
    id isRegularFile = nil;
    id isSymbolicLink = nil;
    NSError* resourceError = nil;
    BOOL readRegularFileState = [itemURL getResourceValue:&isRegularFile
                                                   forKey:NSURLIsRegularFileKey
                                                    error:&resourceError];
    BOOL readSymbolicLinkState = [itemURL getResourceValue:&isSymbolicLink
                                                    forKey:NSURLIsSymbolicLinkKey
                                                     error:&resourceError];
    if (!readRegularFileState || !readSymbolicLinkState) {
        ErrLog(@"[DataStoreCleanup] could not inspect %@: %@", itemURL.path, resourceError.localizedDescription);
        return NO;
    }
    return [isRegularFile boolValue] && ![isSymbolicLink boolValue];
}

- (void) _deleteObsoleteDataStores
{
    NSFileManager* fman = [NSFileManager defaultManager];
    NSString* documentsPath = [DatabaseManager pathToDocuments];
    NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:documentsPath];
    NSSet<NSString*>* obsoleteFilenames = [DatabaseManager _obsoleteDataStoreFilenames];
    NSMutableArray* removed = [NSMutableArray array];
    long long freedBytes = 0;
    for (NSString* directoryPath in @[dataPath, documentsPath]) {
        NSArray* files = [fman contentsOfDirectoryAtPath:directoryPath error:nil];
        for (NSString* file in files) {
            if (![obsoleteFilenames containsObject:file]) {
                continue;
            }
            NSString* fullPath = [directoryPath stringByAppendingPathComponent:file];
            NSURL* fileURL = [NSURL fileURLWithPath:fullPath];
            if (![DatabaseManager _isRemovableObsoleteDataStoreItemAtURL:fileURL]) {
                ErrLog(@"[DataStoreCleanup] skipped non-regular item %@", fullPath);
                continue;
            }
            long long size = [[fman attributesOfItemAtPath:fullPath error:nil] fileSize];
            NSError* cleanupError = nil;
            if ([fman removeItemAtPath:fullPath error:&cleanupError]) {
                NSString* location = [directoryPath isEqualToString:dataPath] ? [@"Data/" stringByAppendingString:file] : file;
                [removed addObject:location];
                freedBytes += size;
            }
            else {
                ErrLog(@"[DataStoreCleanup] failed to remove %@: %@", fullPath, cleanupError.localizedDescription);
            }
        }
    }
    // Log via the diagnostic logger (works in Release too) only when something was actually
    // removed, so it confirms the self-cleanup ran on customer devices without adding noise.
    if (removed.count > 0) {
        [[ICDiagnosticLogger shared] logEvent:@"storage"
                                      message:@"Obsolete Datenspeicher entfernt"
                                     metadata:@{ @"files": [removed componentsJoinedByString:@", "],
                                                 @"freedBytes": [NSString stringWithFormat:@"%lld", freedBytes] }];
    }
}

// One-time: put the default lists in the order Most Recent, Recently Played, Favorites,
// Downloaded, then the rest (leading negative ranks). Runs once so it never fights a user who
// later reorders lists manually.
- (void) _migrateDefaultListOrderOnce
{
    if ([USER_DEFAULTS boolForKey:@"ICDefaultListOrderMigrated_v1"]) {
        return;
    }
    NSDictionary<NSString*, NSNumber*>* rankByUID = @{
        @"default.mostrecent":     @(-4),
        @"default.recentlyplayed": @(-3),
        @"default.favorites":      @(-2),
        @"default.downloaded":     @(-1),
    };
    NSFetchRequest* req = [[NSFetchRequest alloc] initWithEntityName:@"EpisodeList"];
    req.predicate = [NSPredicate predicateWithFormat:@"uid IN %@", rankByUID.allKeys];
    NSArray* lists = [self.objectContext executeFetchRequest:req error:nil];
    for (CDEpisodeList* list in lists) {
        NSNumber* rank = rankByUID[list.uid];
        if (rank && list.rank != rank.intValue) {
            list.rank = rank.intValue;
        }
    }
    if (self.objectContext.hasChanges) {
        [self save];
    }
    [USER_DEFAULTS setBool:YES forKey:@"ICDefaultListOrderMigrated_v1"];
}

// uids of the built-in "Recently Played" / "Most Recent" default lists.
static NSArray<NSString*>* ICWidgetOnlyDefaultListUIDs(void)
{
    static NSArray* uids;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ uids = @[@"default.recentlyplayed", @"default.mostrecent"]; });
    return uids;
}

// Recreates the "Recently Played" / "Most Recent" default lists for installs that never had them
// (previously created only when migrating an old smart playlist). They appear in the "Lists" menu
// (and therefore the SmartList widget picker); they are just not auto-pinned to the main sidebar
// (MainMenuListUIDs), which the user considers optional. Idempotent.
- (void) _ensureWidgetOnlyDefaultLists
{
    NSFetchRequest* req = [[NSFetchRequest alloc] initWithEntityName:@"EpisodeList"];
    req.predicate = [NSPredicate predicateWithFormat:@"uid IN %@", ICWidgetOnlyDefaultListUIDs()];
    NSArray* existing = [self.objectContext executeFetchRequest:req error:nil];
    NSSet* existingUIDs = [NSSet setWithArray:[existing valueForKey:@"uid"]];

    // "Show everything" base (all media, all play/star/download states) so the list is never
    // empty; the two differ only in sort order.
    void (^configureShowAll)(CDEpisodeList*) = ^(CDEpisodeList* l) {
        l.audio = YES; l.video = YES;
        l.unplayed = YES; l.played = YES; l.unfinished = YES;
        l.starred = YES; l.notStarred = YES;
        l.downloaded = YES; l.notDownloaded = YES;
        l.descending = YES; l.groupByPodcast = NO;
    };

    // Leading negative ranks so these sort at the FRONT (order: Most Recent, Recently Played,
    // Favorites, Downloaded, then the rest) — see _migrateDefaultListOrderOnce for existing installs.
    if (![existingUIDs containsObject:@"default.recentlyplayed"]) {
        CDEpisodeList* l = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
        configureShowAll(l);
        l.name = @"Recently Played".ls;
        l.icon = @"List Recently Played";
        l.orderBy = @"lastPlayed";
        l.rank = -3;
        l.uid = @"default.recentlyplayed";
    }
    if (![existingUIDs containsObject:@"default.mostrecent"]) {
        CDEpisodeList* l = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
        configureShowAll(l);
        l.name = @"Most Recent".ls;
        l.icon = @"List Most Recent";
        l.orderBy = @"pubDate";
        l.rank = -4;
        l.uid = @"default.mostrecent";
    }
    if (self.objectContext.hasChanges) {
        [self save];
    }
}

// Removes duplicate/orphan CDList rows. Historically many List rows accumulated with the SAME
// uid (or a nil uid) — e.g. from earlier iCloud-sync / backup-import paths — which the app's
// `lists` getter already hid by deduping on read, but which bloated the widget export ("157
// lists") and the widget picker. This runs on every launch: it is idempotent (a no-op once
// clean) and thereby also PREVENTS future accumulation regardless of how a stray row got in.
- (void) _migrateRemoveDuplicateLists
{
    NSFetchRequest* request = [[NSFetchRequest alloc] init];
    request.entity = [NSEntityDescription entityForName:@"List" inManagedObjectContext:self.objectContext];
    request.includesSubentities = YES;
    request.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
    NSArray* allLists = [self.objectContext executeFetchRequest:request error:nil];

    NSMutableDictionary<NSString*, CDList*>* keepByUID = [NSMutableDictionary dictionary];
    NSMutableArray<CDList*>* toDelete = [NSMutableArray array];

    for (CDList* list in allLists) {
        NSString* uid = list.uid;
        if (uid.length == 0) {
            [toDelete addObject:list];   // orphan without identity — never user-visible
            continue;
        }
        CDList* kept = keepByUID[uid];
        if (!kept) {
            keepByUID[uid] = list;   // first row for this uid (lowest rank) wins
        }
        else {
            // Same uid ⇒ redundant copy of the same logical list. Keep the first, drop the rest.
            [toDelete addObject:list];
        }
    }

    if (toDelete.count == 0) {
        return;
    }

    for (CDList* list in toDelete) {
        [self.objectContext deleteObject:list];
    }
    [self save];
    DebugLog(@"[ListCleanup] removed %lu duplicate/orphan List rows, kept %lu unique", (unsigned long)toDelete.count, (unsigned long)keepByUID.count);
}

- (void) _migrateDefaultListNamesToKeys
{
    // Default lists now store the localized name directly. Names are set once at creation
    // and then treated identically to user-created lists (renameable, deletable).
    // This migration localizes any remaining English-key names from previous migration.
    NSDictionary* keyToLocalized = @{
        @"Unplayed"   : @"Unplayed".ls,
        @"Started"    : @"Started".ls,
        @"Downloaded" : @"Downloaded".ls,
        @"Favorites"  : @"Favorites".ls,
        @"Videos"     : @"Videos".ls,
    };

    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"uid BEGINSWITH %@", @"default."];
    NSArray* lists = [self.objectContext executeFetchRequest:fetchRequest error:nil];

    BOOL changed = NO;
    for (CDEpisodeList* list in lists) {
        NSString* localizedName = keyToLocalized[list.name];
        if (localizedName && ![list.name isEqualToString:localizedName]) {
            list.name = localizedName;
            changed = YES;
        }
    }

    if (changed) {
        [self save];
    }
}

- (void) _migrateRemoveDuplicateFeeds
{
    // Consolidate ghost duplicate feeds created by metadata-only placeholders. Feed owns
    // episodes, properties and categories with Cascade, so every relationship must move
    // to the keeper before the redundant row is deleted.
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
    NSArray* allFeeds = [self.objectContext executeFetchRequest:fetchRequest error:nil];

    NSMutableDictionary<NSString*, NSMutableArray<CDFeed*>*>* feedsByURL = [NSMutableDictionary dictionary];
    for (CDFeed* feed in allFeeds) {
        NSString* urlStr = [DatabaseManager normalizedFeedURLStringForURLString:feed.sourceURL.absoluteString];
        if (urlStr.length == 0) continue;
        if (!feedsByURL[urlStr]) {
            feedsByURL[urlStr] = [NSMutableArray array];
        }
        [feedsByURL[urlStr] addObject:feed];
    }

    BOOL changed = NO;
    for (NSString* urlStr in feedsByURL) {
        NSMutableArray<CDFeed*>* feeds = feedsByURL[urlStr];
        if (feeds.count <= 1) continue;

        // Sort: prefer non-parked, then most episodes
        [feeds sortUsingComparator:^NSComparisonResult(CDFeed* a, CDFeed* b) {
            if (a.parked != b.parked) {
                return a.parked ? NSOrderedDescending : NSOrderedAscending;
            }
            NSComparisonResult countOrder = [@(b.episodes.count) compare:@(a.episodes.count)];
            if (countOrder != NSOrderedSame) {
                return countOrder;
            }
            NSString* aID = a.objectID.URIRepresentation.absoluteString ?: @"";
            NSString* bID = b.objectID.URIRepresentation.absoluteString ?: @"";
            return [aID compare:bID];
        }];

        CDFeed* keeper = feeds.firstObject;
        NSMutableSet<NSString*>* keeperPropertyKeys = [NSMutableSet set];
        for (CDFeedProperty* property in keeper.properties) {
            if (property.key.length > 0) {
                [keeperPropertyKeys addObject:property.key];
            }
        }

        // Keep first (non-parked, most episodes), merge every owned relationship, then
        // delete only the empty feed row. Duplicate episode identities deliberately stay:
        // startup has no CacheManager lifecycle yet, so hard-deleting them could orphan or
        // remove a downloaded file. The normal feed refresh owns state-aware deduplication.
        for (NSUInteger i = 1; i < feeds.count; i++) {
            CDFeed* duplicate = feeds[i];
            for (CDEpisode* episode in [duplicate.episodes copy]) {
                episode.feed = keeper;
            }
            for (CDFeedProperty* property in [duplicate.properties copy]) {
                if (property.key.length == 0 || ![keeperPropertyKeys containsObject:property.key]) {
                    property.feed = keeper;
                    if (property.key.length > 0) {
                        [keeperPropertyKeys addObject:property.key];
                    }
                }
            }
            for (CDCategory* category in [duplicate.categories copy]) {
                category.feed = keeper;
            }
            for (CDEpisodeList* episodeList in [duplicate.episodeLists copy]) {
                [[episodeList mutableSetValueForKey:@"includedFeeds"] addObject:keeper];
            }

            if (keeper.username.length == 0 && duplicate.username.length > 0) {
                NSString* duplicatePassword = duplicate.password;
                keeper.username = duplicate.username;
                if (duplicatePassword.length > 0) {
                    keeper.password = duplicatePassword;
                }
            }
            [self.objectContext deleteObject:duplicate];
            changed = YES;
        }
    }

    if (changed) {
        [self save];
    }
}


- (void) _migrateRemoveObsoletePauseFeedProperty
{
    // PauseFeedSynchronization CDFeedProperty is obsolete — parked attribute is the sole
    // source of truth now. Remove any leftover PauseFeedSynchronization properties.
    for (CDFeed* feed in self.feeds) {
        [feed resetValueForKey:@"PauseFeedSynchronization"];
    }
    [self save];
}

- (void) _migrateAddStartedList
{
    // Check if default.started already exists
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"uid == %@", @"default.started"];
    NSArray* results = [self.objectContext executeFetchRequest:fetchRequest error:nil];

    if ([results count] == 0) {
        CDEpisodeList* started = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
        started.name = @"Started".ls;
        started.icon = @"List Partially Played";
        started.rank = 1;
        started.unfinished = YES;
        started.unplayed = NO;
        started.played = NO;
        started.orderBy = @"lastPlayed";
        started.descending = YES;
        started.groupByPodcast = NO;
        started.uid = @"default.started";

        // Shift existing lists down by 1
        NSFetchRequest* listsRequest = [[NSFetchRequest alloc] init];
        listsRequest.entity = [NSEntityDescription entityForName:@"EpisodeList" inManagedObjectContext:self.objectContext];
        listsRequest.predicate = [NSPredicate predicateWithFormat:@"uid != %@", @"default.started"];
        listsRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
        NSArray* existingLists = [self.objectContext executeFetchRequest:listsRequest error:nil];

        for (CDList* list in existingLists) {
            if (list.rank >= 1) {
                list.rank = list.rank + 1;
            }
        }

        [self save];
    }
}

- (void) _deleteUnsubscribedFeeds
{
    NSError* cleanupIntentError = nil;
    NSArray<NSString*>* protectedFeedObjectURIStringArray =
        [ICiCloudSyncManager pendingSubscriptionCleanupFeedObjectURIStringsInContext:self.objectContext
                                                                               error:&cleanupIntentError];
    if (!protectedFeedObjectURIStringArray) {
        ErrLog(@"Could not inspect pending subscription cleanup intents: %@", cleanupIntentError);
        return;
    }
    NSSet<NSString*>* protectedFeedObjectURIStrings =
        [NSSet setWithArray:protectedFeedObjectURIStringArray];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == NO"];
    NSError* fetchError = nil;
    NSArray* unsubscribedFeeds = [self.objectContext executeFetchRequest:fetchRequest error:&fetchError];
    if (!unsubscribedFeeds) {
        ErrLog(@"Could not inspect unsubscribed feeds: %@", fetchError);
        return;
    }
    
    for(NSManagedObject* feed in unsubscribedFeeds) {
        NSString* feedObjectURIString = feed.objectID.URIRepresentation.absoluteString;
        if ([protectedFeedObjectURIStrings containsObject:feedObjectURIString]) {
            continue;
        }
        [self.objectContext deleteObject:feed];
    }
    [self save];
    
}

- (NSError*) saveReturningError
{
    if (_savingInterruption != 0) {
        return [NSError errorWithDomain:@"DatabaseManager"
                                   code:1
                               userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Die lokale Datenbank wird gerade exklusiv aktualisiert.", nil)}];
    }

    NSMutableSet* set = [[NSMutableSet alloc] init];
    [set unionSet:[self.objectContext insertedObjects]];
    [set unionSet:[self.objectContext updatedObjects]];
    [set unionSet:[self.objectContext deletedObjects]];

    for(CDBase* object in set)
    {
        if ([object isKindOfClass:[CDEpisode class]] && [object hasChanges]) {
            [self coalescedPerformSelector:@selector(_invalidateListCaches) afterDelay:0.1];
        }
        else if ([object isKindOfClass:[CDFeed class]] && [object hasChanges]) {
            [self coalescedPerformSelector:@selector(_invalidateListCaches) afterDelay:0.1];
        }
    }

    NSError* error = nil;
    if (![self.objectContext save:&error]) {
        ErrLog(@"Error saving context: %@", error.localizedDescription);
        for (CDFeed* feed in _feedsAwaitingCountSave) {
            [feed feedCountChangesDidFailSave];
        }
        return error ?: [NSError errorWithDomain:@"DatabaseManager"
                                             code:2
                                             userInfo:@{NSLocalizedDescriptionKey: NSLocalizedString(@"Die lokale Datenbank konnte nicht gespeichert werden.", nil)}];
    }
    NSArray<CDFeed*>* feedsWithSavedCountChanges = [_feedsAwaitingCountSave.allObjects copy];
    [_feedsAwaitingCountSave removeAllObjects];
    for (CDFeed* feed in feedsWithSavedCountChanges) {
        if (!feed.isDeleted) {
            [feed feedCountChangesDidSave];
        }
    }
    [self.persistentContainer.viewContext processPendingChanges];
    return nil;
}

- (void) save
{
    NSError* error = [self saveReturningError];
    if (error) {
        ErrLog(@"error saving database context: %@", error);
    }
}

- (void)resetAllUserDataWithCompletion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resetAllUserDataWithCompletion:completion];
        });
        return;
    }
    NSError* indexPreparationError = nil;
    if (![self.ftsController prepareForExternalStoreMutation:&indexPreparationError]) {
        NSMutableDictionary* userInfo = [@{
            NSLocalizedDescriptionKey: @"The search index could not be prepared for reset. No local database data was reset.".ls,
        } mutableCopy];
        if (indexPreparationError) {
            userInfo[NSUnderlyingErrorKey] = indexPreparationError;
        }
        NSError* publicError = [NSError errorWithDomain:@"DatabaseManager"
                                                   code:32
                                               userInfo:userInfo];
        if (completion) completion(publicError);
        return;
    }
    NSManagedObjectContext* context = [self newBackgroundContext];
    if (!context) {
        if (completion) {
            completion([NSError errorWithDomain:@"DatabaseManager"
                                            code:30
                                        userInfo:@{NSLocalizedDescriptionKey: @"The local app data could not be opened for reset.".ls}]);
        }
        return;
    }

    [context performBlock:^{
        NSArray<NSString*>* entityNames = @[
            @"PlaylistEpisode", @"EpisodeList", @"Playlist", @"SmartPlaylist",
            @"Bookmark", @"AppleWatchEpisodeState", @"Chapter", @"Medium",
            @"Episode", @"FeedProperty", @"Category", @"Feed", @"ICCloudSyncOutboxEntry",
            @"ICCloudPendingEpisodeState", @"ICCloudPendingSubscriptionState", @"ICCloudSyncItemMetadata",
            @"ICCloudKnownRecordSystemFields",
        ];
        NSMutableArray<NSManagedObjectID*>* deletedObjectIDs = [NSMutableArray array];
        NSError* resetError = nil;
        for (NSString* entityName in entityNames) {
            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:entityName];
            fetchRequest.includesSubentities = NO;
            NSBatchDeleteRequest* deleteRequest = [[NSBatchDeleteRequest alloc] initWithFetchRequest:fetchRequest];
            deleteRequest.resultType = NSBatchDeleteResultTypeObjectIDs;
            NSBatchDeleteResult* result = (NSBatchDeleteResult*)[context executeRequest:deleteRequest error:&resetError];
            if (!result) break;
            if ([result.result isKindOfClass:[NSArray class]]) {
                [deletedObjectIDs addObjectsFromArray:result.result];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (deletedObjectIDs.count > 0) {
                NSDictionary* changes = @{NSDeletedObjectsKey: deletedObjectIDs};
                [NSManagedObjectContext mergeChangesFromRemoteContextSave:changes intoContexts:@[self.objectContext]];
                [self.objectContext processPendingChanges];
            }
            NSError* publicError = nil;
            if (resetError) {
                publicError = [NSError errorWithDomain:@"DatabaseManager"
                                                   code:31
                                               userInfo:@{
                                                   NSLocalizedDescriptionKey: @"The local app data could not be completely deleted. Please try the reset again.".ls,
                                                   NSUnderlyingErrorKey: resetError,
                                                   }];
            }
            NSManagedObjectContext* indexContext = [self newExportBackgroundContext];
            if (!indexContext) {
                NSError* indexError = [NSError errorWithDomain:@"DatabaseManager"
                                                          code:33
                                                      userInfo:@{NSLocalizedDescriptionKey: @"The local app data was deleted, but the search index could not be rebuilt. Please restart InstacastPlus and try again.".ls}];
                if (completion) completion(publicError ?: indexError);
                return;
            }

            [self _beginFTSIndexing];
            [self.ftsController rebuildIndexWithManagedObjectContext:indexContext completion:^(NSError* indexError) {
                [self _endFTSIndexing];
                if (indexError) {
                    ErrLog(@"FTS rebuild after local data reset failed: %@", indexError);
                }
                NSError* reportedError = publicError;
                if (!reportedError && indexError) {
                    reportedError = [NSError errorWithDomain:@"DatabaseManager"
                                                        code:34
                                                    userInfo:@{
                                                        NSLocalizedDescriptionKey: @"The local app data was deleted, but the search index could not be rebuilt. Please restart InstacastPlus and try again.".ls,
                                                        NSUnderlyingErrorKey: indexError,
                                                    }];
                }
                if (completion) completion(reportedError);
            }];
        });
    }];
}


#if TARGET_OS_IPHONE

- (void) _sendObservedFeedsDidChangeNotification
{
    [[NSNotificationCenter defaultCenter] postNotificationName:DatabaseManagerDidUpdateObservedFeedNotification
                                                        object:self
                                                      userInfo:nil];
}

- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type newIndexPath:(NSIndexPath *)newIndexPath
{
    if (controller == _feedsController) {
        [self coalescedPerformSelector:@selector(_sendObservedFeedsDidChangeNotification)];
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    if (controller == _feedsController) {
        [self willChangeValueForKey:kFeedsProperty];
        [self didChangeValueForKey:kFeedsProperty];
    }
    else if (controller == _listsController) {
        [self willChangeValueForKey:kListsProperty];
        [self didChangeValueForKey:kListsProperty];
    }
    else if (controller == _bookmarksController) {
        [self willChangeValueForKey:kBookmarksProperty];
        [self didChangeValueForKey:kBookmarksProperty];
    }
}

#endif

- (void) managedObjectContextObjectsDidChangeNotification:(NSNotification*)notification
{
    NSDictionary* userInfo = [notification userInfo];
    NSSet* insertedObjects = userInfo[NSInsertedObjectsKey];
    NSSet* updatedObjects = userInfo[NSUpdatedObjectsKey];
    NSSet* deletedObjects = userInfo[NSDeletedObjectsKey];
    NSMutableSet<CDFeed*>* feedsWithChangedEpisodeCounts = [NSMutableSet set];
    NSMutableSet<CDFeed*>* feedsAwaitingSuccessfulSave = [NSMutableSet set];
    BOOL (^objectRequiresSave)(NSManagedObject*) = ^BOOL(NSManagedObject* object) {
        return [self.objectContext.insertedObjects containsObject:object] ||
               [self.objectContext.updatedObjects containsObject:object] ||
               [self.objectContext.deletedObjects containsObject:object];
    };
    
    //    NSMutableSet* set = [[NSMutableSet alloc] init];
    //    [set unionSet:insertedObjects];
    //    [set unionSet:updatedObjects];
    //    [set unionSet:deletedObjects];
    
    
    for(NSManagedObject* insertedObject in insertedObjects)
    {
        if ([insertedObject isKindOfClass:[CDEpisode class]]) {
            CDEpisode* episode = (CDEpisode*)insertedObject;
            [self.spotlightIndexer addEpisode:episode];
            if (episode.feed) {
                [feedsWithChangedEpisodeCounts addObject:episode.feed];
                if (objectRequiresSave(episode)) {
                    [feedsAwaitingSuccessfulSave addObject:episode.feed];
                }
            }
        }
        else if ([insertedObject isKindOfClass:[CDFeed class]]) {
            [self.spotlightIndexer addFeed:(CDFeed*)insertedObject];
        }
        else if ([insertedObject isKindOfClass:[CDFeedProperty class]]) {
            CDFeedProperty* property = (CDFeedProperty*)insertedObject;
            if (ICFeedPropertyAffectsEpisodeCount(property.key) && property.feed) {
                [feedsWithChangedEpisodeCounts addObject:property.feed];
                if (objectRequiresSave(property)) {
                    [feedsAwaitingSuccessfulSave addObject:property.feed];
                }
            }
        }
    }
    
    for(NSManagedObject* updatedObject in updatedObjects)
    {
        NSDictionary* cv = [updatedObject changedValues];
        NSDictionary* currentEventChanges = [updatedObject changedValuesForCurrentEvent];
        
        if ([updatedObject isKindOfClass:[CDEpisode class]] &&
            (cv[@"title"] || cv[@"subtitle"] || cv[@"summary"] || cv[@"fulltext"] ||
             cv[@"transcriptsJSON_"] || cv[@"imageURL_"] || cv[@"duration"] ||
             cv[@"pubDate"] || cv[@"lastDownloaded"] || cv[@"chapters"])) {
            [self.spotlightIndexer updateEpisode:(CDEpisode*)updatedObject];
        }
        else if ([updatedObject isKindOfClass:[CDFeed class]] &&
                 (cv[@"title"] || cv[@"displayTitle"] || cv[@"author"] || cv[@"summary"] ||
                  cv[@"fulltext"] || cv[@"imageURL_"] || cv[@"pubDate"] ||
                  cv[@"subscribed"])) {
            // Deliberately NOT lastUpdate: a refresh rewrites lastUpdate on EVERY feed even when
            // nothing changed — that re-indexed the whole subscription list on each pull-to-refresh.
            [self.spotlightIndexer updateFeed:(CDFeed*)updatedObject];
        }

        if ([updatedObject isKindOfClass:[CDEpisode class]] &&
            (currentEventChanges[@"archived"] || currentEventChanges[@"consumed"] || currentEventChanges[@"feed"])) {
            CDEpisode* episode = (CDEpisode*)updatedObject;
            if (episode.feed) {
                [feedsWithChangedEpisodeCounts addObject:episode.feed];
                if (objectRequiresSave(episode)) {
                    [feedsAwaitingSuccessfulSave addObject:episode.feed];
                }
            }
            CDFeed* previousFeed = [episode committedValuesForKeys:@[@"feed"]][@"feed"];
            if ([previousFeed isKindOfClass:[CDFeed class]]) {
                [feedsWithChangedEpisodeCounts addObject:previousFeed];
                if (objectRequiresSave(episode)) {
                    [feedsAwaitingSuccessfulSave addObject:previousFeed];
                }
            }
        }
        else if ([updatedObject isKindOfClass:[CDFeedProperty class]]) {
            CDFeedProperty* property = (CDFeedProperty*)updatedObject;
            NSString* previousKey = [property committedValuesForKeys:@[@"key"]][@"key"];
            if (ICFeedPropertyAffectsEpisodeCount(property.key) || ICFeedPropertyAffectsEpisodeCount(previousKey)) {
                if (property.feed) {
                    [feedsWithChangedEpisodeCounts addObject:property.feed];
                    if (objectRequiresSave(property)) {
                        [feedsAwaitingSuccessfulSave addObject:property.feed];
                    }
                }
                CDFeed* previousFeed = [property committedValuesForKeys:@[@"feed"]][@"feed"];
                if ([previousFeed isKindOfClass:[CDFeed class]]) {
                    [feedsWithChangedEpisodeCounts addObject:previousFeed];
                    if (objectRequiresSave(property)) {
                        [feedsAwaitingSuccessfulSave addObject:previousFeed];
                    }
                }
            }
        }
    }
    
    for(NSManagedObject* deletedObject in deletedObjects)
    {
        if ([deletedObject isKindOfClass:[CDEpisode class]]) {
            CDEpisode* episode = (CDEpisode*)deletedObject;
            [self.spotlightIndexer removeEpisode:episode];
            CDFeed* feed = episode.feed ?: [episode committedValuesForKeys:@[@"feed"]][@"feed"];
            if ([feed isKindOfClass:[CDFeed class]]) {
                [feedsWithChangedEpisodeCounts addObject:feed];
                if (objectRequiresSave(episode)) {
                    [feedsAwaitingSuccessfulSave addObject:feed];
                }
            }
        }
        else if ([deletedObject isKindOfClass:[CDFeed class]]) {
            [self.spotlightIndexer removeFeed:(CDFeed*)deletedObject];
        }
        else if ([deletedObject isKindOfClass:[CDFeedProperty class]]) {
            CDFeedProperty* property = (CDFeedProperty*)deletedObject;
            NSString* key = property.key ?: [property committedValuesForKeys:@[@"key"]][@"key"];
            CDFeed* feed = property.feed ?: [property committedValuesForKeys:@[@"feed"]][@"feed"];
            if (ICFeedPropertyAffectsEpisodeCount(key) && [feed isKindOfClass:[CDFeed class]]) {
                [feedsWithChangedEpisodeCounts addObject:feed];
                if (objectRequiresSave(property)) {
                    [feedsAwaitingSuccessfulSave addObject:feed];
                }
            }
        }
    }

    if (feedsAwaitingSuccessfulSave.count > 0) {
        if (!_feedsAwaitingCountSave) {
            _feedsAwaitingCountSave = [NSMutableSet set];
        }
        [_feedsAwaitingCountSave unionSet:feedsAwaitingSuccessfulSave];
    }
    for (CDFeed* feed in feedsWithChangedEpisodeCounts) {
        if (!feed.isDeleted) {
            [feed invalidateCountsAwaitingSave:[_feedsAwaitingCountSave containsObject:feed]];
        }
    }
}

- (BOOL)_managedObjectContextUsesPrimaryPersistentStore:(NSManagedObjectContext*)context
{
    return context && context.parentContext == nil &&
           context.persistentStoreCoordinator == self.storeCoordinator;
}

- (void) managedObjectContextWillSaveNotification:(NSNotification*)notification
{
    NSManagedObjectContext* context = notification.object;
    if (![context isKindOfClass:NSManagedObjectContext.class] ||
        ![self _managedObjectContextUsesPrimaryPersistentStore:context]) {
        return;
    }
    [self.ftsController stageChangesForManagedObjectContext:context];
}

- (void) managedObjectContextDidSaveNotification:(NSNotification*)notification
{
    NSManagedObjectContext* context = notification.object;
    if (![context isKindOfClass:NSManagedObjectContext.class] ||
        ![self _managedObjectContextUsesPrimaryPersistentStore:context]) {
        return;
    }
    [self.ftsController commitStagedChangesForManagedObjectContext:context];
}

- (void) transcriptionDidChangeNotification:(NSNotification*)notification
{
    NSString* episodeHash = [notification.userInfo[@"episodeHash"] copy];
    if (episodeHash.length == 0) {
        return;
    }

    [self.objectContext performBlock:^{
        CDEpisode* episode = [self episodeWithObjectHash:episodeHash];
        if (episode) {
            [self.spotlightIndexer updateEpisode:episode];
        }
    }];
}


- (void) beginInterruptSaving
{
    @synchronized(self) {
        _savingInterruption++;
    }
}

- (void) endInterruptSaving
{
    @synchronized(self) {
        _savingInterruption--;
    }
}

#pragma mark Feeds

- (NSArray*) feeds
{
#if TARGET_OS_IPHONE
    return [_feedsController fetchedObjects];
#else
    return [_feedsController arrangedObjects];
#endif
}

- (NSArray*) visibleFeeds
{
    return self.feeds;
}

- (void) _updateFeedOrderNums:(NSArray*)feeds
{
	NSInteger num = 0;
	for(CDFeed* feed in feeds) {
		feed.rank = (int32_t)num;
		num++;
	}
}


- (BOOL) feedExists:(CDFeed*)aFeed
{
	for(CDFeed* feed in self.feeds) {
		if ([feed isEqual:aFeed]) {
			return YES;
		}
	}
	
	return NO;
}

- (void) _mergeExistingEpisodes:(NSArray*)existingEpisodes withNewEpisodes:(NSArray*)newEpisodes andResetPlaybackStatesOfFeed:(CDFeed*)feed
{
    if ([newEpisodes count] > [existingEpisodes count])
    {
        // merge new episodes with existing ones
        for(ICEpisode* newEpisode in newEpisodes)
        {
            BOOL contained = NO;
            for(CDEpisode* existingEpisode in existingEpisodes) {
                if ([existingEpisode.objectHash isEqualToString:newEpisode.objectHash]) {
                    contained = YES;
                    break;
                }
            }
            
            if (!contained)
            {
                BOOL wasNew;
                CDEpisode* episode = [self addNewParserEpisode:newEpisode toFeed:feed wasNew:&wasNew];
                if (wasNew) {
                    episode.consumed = NO;
                }
            }
        }
    }
}

- (void) _copyFeedValuesFrom:(ICFeed*)parserFeed to:(CDFeed*)persitentFeed
{
    persitentFeed.title = parserFeed.title;
    persitentFeed.subtitle = parserFeed.subtitle;
    persitentFeed.sourceURL = parserFeed.sourceURL;
    persitentFeed.imageURL = parserFeed.imageURL;
    persitentFeed.pubDate = parserFeed.pubDate;
    persitentFeed.lastUpdate = parserFeed.lastUpdate;
    persitentFeed.video = parserFeed.video;
    persitentFeed.completed = parserFeed.completed;
    persitentFeed.linkURL = parserFeed.linkURL;
    persitentFeed.language = parserFeed.language;
    persitentFeed.country = parserFeed.country;
    persitentFeed.summary = parserFeed.summary;
    persitentFeed.fulltext = parserFeed.textDescription;
    persitentFeed.author = parserFeed.author;
    persitentFeed.copyright = parserFeed.copyright;
    persitentFeed.owner = parserFeed.owner;
    persitentFeed.ownerEmail = parserFeed.ownerEmail;
    persitentFeed.explicitContent = parserFeed.explicitContent;
    persitentFeed.paymentURL = parserFeed.paymentURL;
    persitentFeed.username = parserFeed.username;
    persitentFeed.password = parserFeed.password;
    persitentFeed.etag = parserFeed.etag;
    persitentFeed.contentHash = parserFeed.contentHash;
}

- (void) _copyEpisodeValuesFrom:(ICEpisode*)parserEpisode to:(CDEpisode*)persitentEpisode
{
    persitentEpisode.objectHash = parserEpisode.objectHash;
    persitentEpisode.title = parserEpisode.title;
    persitentEpisode.subtitle = parserEpisode.subtitle;
    persitentEpisode.guid = parserEpisode.guid;
    persitentEpisode.pubDate = parserEpisode.pubDate;
    persitentEpisode.imageURL = parserEpisode.imageURL;
    persitentEpisode.linkURL = parserEpisode.link;
    persitentEpisode.author = parserEpisode.author;
    persitentEpisode.summary = parserEpisode.summary;
    persitentEpisode.fulltext = parserEpisode.textDescription;
    persitentEpisode.transcripts = parserEpisode.transcripts;
    persitentEpisode.paymentURL = parserEpisode.paymentURL;
    persitentEpisode.deeplinkURL = parserEpisode.deeplink;
    persitentEpisode.video = parserEpisode.video;
    persitentEpisode.explicitContent = parserEpisode.explicitContent;
    persitentEpisode.duration = (int32_t)parserEpisode.duration;
}

- (void) _copyMediumValuesFrom:(ICMedia*)parserMedium to:(CDMedium*)persitentMedium
{
    persitentMedium.fileURL = parserMedium.fileURL;
    persitentMedium.byteSize = parserMedium.byteSize;
    persitentMedium.mimeType = parserMedium.mimeType;
}

- (CDEpisode*) addNewParserEpisode:(ICEpisode*)parserEpisode toFeed:(CDFeed*)feed wasNew:(BOOL*)wasNew
{
    if (wasNew) *wasNew = NO;
    
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"objectHash == %@", parserEpisode.objectHash];
    CDEpisode* persistentEpisode = [[self.objectContext executeFetchRequest:fetchRequest error:nil] firstObject];
    
    if (!persistentEpisode) {
        persistentEpisode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:self.objectContext];
        if (wasNew) *wasNew = YES;
    }
    [self _copyEpisodeValuesFrom:parserEpisode to:persistentEpisode];
    
    NSMutableSet* media = [[NSMutableSet alloc] init];
    for(ICMedia* parserMedia in parserEpisode.media)
    {
        if (parserMedia.fileURL) {
            CDMedium* persistentMedium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:self.objectContext];
            [self _copyMediumValuesFrom:parserMedia to:persistentMedium];
            [media addObject:persistentMedium];
        }
    }
    persistentEpisode.media = media;
    [feed addEpisodesObject:persistentEpisode];

    return persistentEpisode;
}

- (void)addParserEpisodes:(NSArray<ICEpisode*>*)episodes toFeed:(CDFeed*)feed markConsumed:(BOOL)markConsumed
{
    if (!episodes || episodes.count == 0 || !feed) {
        return;
    }

    // Sub-profiling for the 1-2.6s main-thread batches measured on the iPad during
    // stub hydration: splits insert work from the save (with its notification fanout).
    CFAbsoluteTime insertStartTime = CFAbsoluteTimeGetCurrent();

    [self beginInterruptSaving];

    @autoreleasepool {
        // Batch-fetch all existing episodes by objectHash in ONE query (instead of N individual fetches)
        NSMutableArray *hashes = [NSMutableArray arrayWithCapacity:episodes.count];
        for (ICEpisode *ep in episodes) {
            if (ep.objectHash) [hashes addObject:ep.objectHash];
        }

        NSMutableDictionary *existingByHash = [NSMutableDictionary dictionaryWithCapacity:hashes.count];
        if (hashes.count > 0) {
            NSFetchRequest *batchFetch = [[NSFetchRequest alloc] init];
            batchFetch.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.objectContext];
            batchFetch.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", hashes];
            NSArray *existing = [self.objectContext executeFetchRequest:batchFetch error:nil];
            for (CDEpisode *ep in existing) {
                if (ep.objectHash) existingByHash[ep.objectHash] = ep;
            }
        }

        // Now insert/update episodes using the pre-fetched lookup
        for (ICEpisode* parserEpisode in episodes) {
            CDEpisode *persistentEpisode = parserEpisode.objectHash ? existingByHash[parserEpisode.objectHash] : nil;
            BOOL wasNew = (persistentEpisode == nil);

            if (!persistentEpisode) {
                persistentEpisode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:self.objectContext];
            }
            [self _copyEpisodeValuesFrom:parserEpisode to:persistentEpisode];

            NSMutableSet *media = [[NSMutableSet alloc] init];
            for (ICMedia *parserMedia in parserEpisode.media) {
                if (parserMedia.fileURL) {
                    CDMedium *persistentMedium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:self.objectContext];
                    [self _copyMediumValuesFrom:parserMedia to:persistentMedium];
                    [media addObject:persistentMedium];
                }
            }
            persistentEpisode.media = media;
            [feed addEpisodesObject:persistentEpisode];

            if (wasNew) {
                // markConsumed=YES: refresh adds older episodes → mark as heard
                // markConsumed=NO: subscription background-loads → mark as unheard
                persistentEpisode.consumed = markConsumed ? YES : NO;
            }
        }
    }

    [self endInterruptSaving];

    CFTimeInterval insertSeconds = CFAbsoluteTimeGetCurrent() - insertStartTime;
    CFAbsoluteTime saveStartTime = CFAbsoluteTimeGetCurrent();
    [self save];
    CFTimeInterval saveSeconds = CFAbsoluteTimeGetCurrent() - saveStartTime;
    if (insertSeconds + saveSeconds > 0.2) {
        [[ICDiagnosticLogger shared] logEvent:@"feed-refresh-profile"
                                      message:@"Episoden-Insert-Detail"
                                     metadata:@{
            @"insertSeconds": [NSString stringWithFormat:@"%.3f", insertSeconds],
            @"saveSeconds": [NSString stringWithFormat:@"%.3f", saveSeconds],
            @"episodes": @(episodes.count).stringValue,
        }];
    }
}

- (CDEpisode*) addUnsubscribedFeed:(ICFeed*)parserFeed andEpisode:(ICEpisode*)parserEpisode
{
    // create feed
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:self.objectContext];
    
    // Normalize feed URL before checking
    NSURL *normalizedURL = [self normalizedURL:parserFeed.sourceURL];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", [normalizedURL absoluteString]];
    //fetchRequest.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", parserFeed.sourceURL];
    NSArray* feeds = [self.objectContext executeFetchRequest:fetchRequest error:nil];
    CDFeed* persistentFeed = [feeds lastObject];
    
    if (!persistentFeed)
    {
        persistentFeed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:self.objectContext];
        [self _copyFeedValuesFrom:parserFeed to:persistentFeed];
        
        NSMutableSet* categories = [[NSMutableSet alloc] init];
        for(ICCategory* parserCategory in parserFeed.categories) {
            CDCategory* category = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:self.objectContext];
            category.title = parserCategory.title;
            
            if (parserCategory.parent) {
                CDCategory* parentCategory = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:self.objectContext];
                parentCategory.title = parserCategory.parent.title;
                category.parent = parentCategory;
            }
            
            [categories addObject:category];
        }
        persistentFeed.categories = categories;
        persistentFeed.subscribed = YES;
        persistentFeed.parked = YES;
    }
    
    // create episode
    NSFetchRequest* episodeFetchRequest = [[NSFetchRequest alloc] init];
    episodeFetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.objectContext];
    episodeFetchRequest.predicate = [NSPredicate predicateWithFormat:@"objectHash == %@", parserEpisode.objectHash];
    NSArray* episodes = [self.objectContext executeFetchRequest:episodeFetchRequest error:nil];
    CDEpisode* persistentEpisode = [episodes lastObject];
    
    if (!persistentEpisode)
    {
        BOOL wasNew;
        persistentEpisode = [self addNewParserEpisode:parserEpisode toFeed:persistentFeed wasNew:&wasNew];
        if (wasNew) {
            persistentEpisode.consumed = NO;
        }
    }
    
    return persistentEpisode;
}

- (CDFeed *)subscribeFeedMetadataOnly:(ICFeed *)parserFeed {
    CDFeed *feed = [self feedWithSourceURL:parserFeed.sourceURL];
    if (!feed) {
        feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:self.objectContext];
    }

    feed.sourceURL = parserFeed.sourceURL;
    feed.title = parserFeed.title;
    feed.linkURL = parserFeed.linkURL;
    feed.imageURL = parserFeed.imageURL;
    feed.paymentURL = parserFeed.paymentURL;
    feed.etag = parserFeed.etag;

    return feed;
}

- (NSURL *)normalizedURL:(NSURL *)url {
    NSString *urlStr = url.absoluteString;
    
    // Remove trailing slash
    if ([urlStr hasSuffix:@"/"]) {
        urlStr = [urlStr substringToIndex:urlStr.length - 1];
    }

    // Remove any whitespace or newline characters
    urlStr = [urlStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    return [NSURL URLWithString:urlStr];
}


// Maximum number of episodes to load initially (rest loads in background)
static const NSInteger kInitialEpisodeLimit = 50;

- (CDFeed*)subscribeFeed:(ICFeed*)parserFeed withOptions:(ICSubscribeOptions)options
{
    if (!parserFeed || !parserFeed.sourceURL) {
        return nil;
    }

    // Check if feed already exists by URL (use normalized NSURL)
    NSURL *normalizedURL = [self normalizedURL:parserFeed.sourceURL];

    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", [normalizedURL absoluteString]];
    fetchRequest.fetchLimit = 1;

    NSError *fetchError = nil;
    NSArray *matches = [self.objectContext executeFetchRequest:fetchRequest error:&fetchError];
    if (matches.count > 0) {
        CDFeed *existingFeed = matches.firstObject;
        if (!existingFeed.subscribed) {
            // Establish a clean transaction boundary before mutating the feed, ranks and
            // synchronously journaled outbox rows. A failed resubscribe save can then roll
            // back exactly this operation without discarding unrelated user edits.
            NSError* resubscribeBaselineSaveError = [self saveReturningError];
            if (resubscribeBaselineSaveError) {
                ErrLog(@"error preparing resubscribed feed save: %@", resubscribeBaselineSaveError);
                return nil;
            }
            // Feed war unsubscribed aber noch nicht aus Core Data entfernt - reaktivieren
            existingFeed.subscribed = YES;
            existingFeed.parked = NO;
            [self _copyFeedValuesFrom:parserFeed to:existingFeed];
            if ((options & kSubscribeOptionDontManageRanking) == 0) {
                NSMutableArray *feedsCopy = [self.feeds mutableCopy];
                if (![feedsCopy containsObject:existingFeed]) {
                    [feedsCopy insertObject:existingFeed atIndex:0];
                }
                [self _updateFeedOrderNums:feedsCopy];
            }
            NSError* resubscribeSaveError = [[ICiCloudSyncManager sharedManager]
                commitLocalSubscriptionResubscribeCleanupForFeed:existingFeed];
            if (resubscribeSaveError) {
                ErrLog(@"error saving resubscribed feed: %@", resubscribeSaveError);
                [self.objectContext rollback];
                return nil;
            }
        }
        return existingFeed;
    }

    // Create new feed
    CDFeed *persistentFeed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:self.objectContext];
    persistentFeed.sourceURL = normalizedURL;

    [self _copyFeedValuesFrom:parserFeed to:persistentFeed];

    // Sort episodes by pubDate descending (newest first) for lazy loading
    NSArray *sortedEpisodes = [parserFeed.episodes sortedArrayUsingDescriptors:
        @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO]]];

    NSInteger totalEpisodeCount = sortedEpisodes.count;
    NSInteger initialLoadCount = MIN(kInitialEpisodeLimit, totalEpisodeCount);

    if (sortedEpisodes.count > 0) {
        // Only load the first batch of episodes (newest first)
        for (NSInteger i = 0; i < initialLoadCount; i++) {
            ICEpisode *parserEpisode = sortedEpisodes[i];
            BOOL wasNew;
            CDEpisode *persistentEpisode = [self addNewParserEpisode:parserEpisode toFeed:persistentFeed wasNew:&wasNew];

            if (wasNew && (options & kSubscribeOptionDontManageConsumedFlags) == 0) {
                persistentEpisode.consumed = NO;
            }
        }
    }

    NSMutableSet *categories = [[NSMutableSet alloc] init];
    for (ICCategory *parserCategory in parserFeed.categories) {
        CDCategory *category = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:self.objectContext];
        category.title = parserCategory.title;

        if (parserCategory.parent) {
            CDCategory *parentCategory = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:self.objectContext];
            parentCategory.title = parserCategory.parent.title;
            category.parent = parentCategory;
        }

        [categories addObject:category];
    }

    persistentFeed.categories = categories;
    persistentFeed.subscribed = YES;

    if ((options & kSubscribeOptionDontManageRanking) == 0) {
        NSMutableArray *feedsCopy = [self.feeds mutableCopy];
        [feedsCopy insertObject:persistentFeed atIndex:0];
        [self _updateFeedOrderNums:feedsCopy];
    }

    BOOL hasPendingEpisodeLoad = (totalEpisodeCount > kInitialEpisodeLimit);
    if (hasPendingEpisodeLoad) {
        [persistentFeed setBool:NO forKey:kFeedPropertyEpisodeLoadingComplete];
        [persistentFeed setInteger:totalEpisodeCount forKey:kFeedPropertyTotalExpectedEpisodes];
        [persistentFeed setInteger:initialLoadCount forKey:kFeedPropertyLoadedEpisodeCount];
    } else {
        [persistentFeed setBool:YES forKey:kFeedPropertyEpisodeLoadingComplete];
    }

    // The background context can only resolve a feed that is already durable. The old
    // ordering queued first and occasionally raced the initial main-context save.
    NSError* initialSaveError = [self saveReturningError];
    if (initialSaveError) {
        ErrLog(@"error saving newly subscribed feed before episode loading: %@", initialSaveError);
        return persistentFeed;
    }

    if (hasPendingEpisodeLoad) {
        [[EpisodeLoadingManager sharedManager] queuePendingEpisodesForFeed:persistentFeed
                                                            parserEpisodes:sortedEpisodes
                                                                startIndex:initialLoadCount];
    }

    return persistentFeed;
}



- (CDFeed*) subscribeFeed:(ICFeed*)feed
{
	return [self subscribeFeed:feed withOptions:kSubscribeOptionNone];
}

- (void) unsubscribeFeed:(CDFeed*)feed
{
	if ([self feedExists:feed])
	{
		feed.subscribed = NO;
        [self save];
	}
}

- (CDFeed*) feedWithTitle:(NSString*)title
{
    for(CDFeed* feed in self.feeds) {
        if ([feed.title isEqual:title]) {
            return feed;
        }
    }
    return nil;
}

- (CDFeed*) feedWithSourceURL:(NSURL*)sourceURL
{
    /*for(CDFeed* feed in self.feeds) {
        if ([feed.sourceURL isEqual:sourceURL]) {
            return feed;
        }
    }
    return nil;*/
    NSArray<NSString *> *targets = [DatabaseManager equivalentFeedURLStringsForURLString:sourceURL.absoluteString];
    for (NSString *target in targets) {
        for (CDFeed* feed in self.feeds) {
            NSString *existing = [DatabaseManager normalizedFeedURLStringForURLString:feed.sourceURL.absoluteString];
            if ([existing isEqualToString:target]) {
                return feed;
            }
        }
    }
    return nil;
}

- (void) reorderFeedFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex
{
    if (fromIndex == toIndex) {
        return;
    }

    
    NSMutableArray* feedsCopy = [self.visibleFeeds mutableCopy];
    
	CDFeed* feed = [feedsCopy objectAtIndex:fromIndex];
	[feedsCopy removeObject:feed];
	[feedsCopy insertObject:feed atIndex:toIndex];
	
	[self _updateFeedOrderNums:feedsCopy];
    [self save];
}

- (void) sortFeedsByKey:(NSString*)key ascending:(BOOL)ascending selector:(SEL)selector
{
	NSMutableArray* feedsCopy = [self.feeds mutableCopy];
    

	NSSortDescriptor* descriptor;
    if (selector) {
        descriptor = [[NSSortDescriptor alloc] initWithKey:key
                                                 ascending:ascending
                                                  selector:selector];
    }
    else {
        descriptor = [[NSSortDescriptor alloc] initWithKey:key
                                                 ascending:ascending];
    }
    
                                    
    [feedsCopy sortUsingDescriptors:[NSArray arrayWithObject:descriptor]];
	[self _updateFeedOrderNums:feedsCopy];
    [self save];
}

- (void) sortFeedsByComparator:(NSComparator)comparator
{
    NSMutableArray* feedsCopy = [self.feeds mutableCopy];
    [feedsCopy sortUsingComparator:comparator];
    [self _updateFeedOrderNums:feedsCopy];
    [self save];
}

static NSString* const kManualFeedOrderKey = @"ManualFeedOrder";

- (void) saveManualFeedOrder
{
    NSMutableArray* urls = [NSMutableArray array];
    for (CDFeed* feed in self.feeds) {
        NSString* urlString = [feed.sourceURL absoluteString];
        if (urlString) {
            [urls addObject:urlString];
        }
    }
    [USER_DEFAULTS setObject:urls forKey:kManualFeedOrderKey];
}

- (BOOL) hasManualFeedOrder
{
    NSArray* savedOrder = [USER_DEFAULTS objectForKey:kManualFeedOrderKey];
    return (savedOrder && savedOrder.count > 0);
}

- (void) restoreManualFeedOrder
{
    NSArray* savedURLs = [USER_DEFAULTS objectForKey:kManualFeedOrderKey];
    if (!savedURLs || savedURLs.count == 0) {
        return;
    }

    NSMutableArray* feedsCopy = [self.feeds mutableCopy];
    NSMutableArray* orderedFeeds = [NSMutableArray array];

    // Restore saved order
    for (NSString* urlString in savedURLs) {
        for (CDFeed* feed in feedsCopy) {
            if ([[feed.sourceURL absoluteString] isEqualToString:urlString]) {
                [orderedFeeds addObject:feed];
                break;
            }
        }
    }

    // Append any feeds not in the saved order (newly added feeds)
    for (CDFeed* feed in feedsCopy) {
        if (![orderedFeeds containsObject:feed]) {
            [orderedFeeds addObject:feed];
        }
    }

    [self _updateFeedOrderNums:orderedFeeds];
    [self save];
}

#pragma mark -
#pragma mark Lists

- (NSArray*) lists
{
    NSArray *fetchedObjects = [_listsController fetchedObjects];

    NSMutableSet *uniqueUIDs = [NSMutableSet set];
    NSMutableArray *uniqueResults = [NSMutableArray array];
    for (CDList *object in fetchedObjects) {

        if (![uniqueUIDs containsObject:object.uid]) {
            if (object.uid != nil) {
                [uniqueUIDs addObject:object.uid];
                [uniqueResults addObject:object];
            }

        }
    }
#if TARGET_OS_IPHONE
    
    return uniqueResults;
#else
    return uniqueResults;
#endif
}

- (void) addList:(CDList*)list
{
#if TARGET_OS_IPHONE
    [CDList updateRanksOfLists:self.lists];
#else
    [CDList updateRanksOfLists:self.lists];
#endif
    
    [self save];
}

- (void) removeList:(CDList*)list
{
#if TARGET_OS_IPHONE
    [self.objectContext deleteObject:list];
    [self save];
    [_listsController performFetch:nil];
#else
    [_listsController removeObject:list];
#endif
    
    [self save];
}

- (void) reorderListFromIndex:(NSInteger)fromIndex toIndex:(NSInteger)toIndex
{
    NSMutableArray* listsCopy = [self.lists mutableCopy];
	CDList* list = [listsCopy objectAtIndex:fromIndex];
	[listsCopy removeObject:list];
	[listsCopy insertObject:list atIndex:toIndex];

	[CDList updateRanksOfLists:listsCopy];
    [self save];
#if TARGET_OS_IPHONE
    [_listsController performFetch:nil];
#endif
}

- (void) _invalidateListCaches
{
    for(CDList* list in self.lists) {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            [(CDEpisodeList*)list invalidateCaches];
        }
    }
}

- (CDEpisodeList*) unplayedList
{
    // First, try to find by uid (most reliable)
    for(CDEpisodeList* list in DMANAGER.lists) {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            if ([list.uid isEqualToString:@"default.unplayed"]) {
                return list;
            }
        }
    }

    // Fallback: find by icon (for backwards compatibility)
    for(CDEpisodeList* list in DMANAGER.lists) {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            if ([list.icon isEqualToString:@"List Unplayed"]) {
                return list;
            }
        }
    }

    // if there is no unplayed list, create one
    CDEpisodeList* unplayedList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:DMANAGER.objectContext];
    unplayedList.name = @"Unplayed".ls;
    unplayedList.icon = @"List Unplayed";
    unplayedList.rank = (int32_t)[DMANAGER.lists count]+1;
    unplayedList.played = NO;
    unplayedList.orderBy = @"pubDate";
    unplayedList.descending = YES;
    unplayedList.groupByPodcast = NO;
    unplayedList.continuousPlayback = YES;
    unplayedList.uid = @"default.unplayed";
    [DMANAGER save];

    return unplayedList;
}


#pragma mark -
#pragma mark Bookmarks

- (NSArray*) bookmarks
{
    if ([[_bookmarksController fetchedObjects] count] == 0) {
        [_bookmarksController performFetch:nil];
    }
#if TARGET_OS_IPHONE
    return [_bookmarksController fetchedObjects];
#else
    return [_bookmarksController arrangedObjects];
#endif
}

- (void) addBookmark:(CDBookmark*)bookmark
{
    [[NSNotificationCenter defaultCenter] postNotificationName:DatabaseManagerDidAddBookmarkNotification object:self];
}

- (void) removeBookmark:(CDBookmark*)bookmark
{
    [self.objectContext deleteObject:bookmark];
    [self save];
}

#pragma mark -

- (void) markEpisode:(CDEpisode*)episode asConsumed:(BOOL)flag
{
    if (episode.consumed != flag)
    {
        episode.consumed = flag;
    
        if (flag) {
            episode.position = 0;
        }
        [self save];
    }
    
    
    if (!flag) {
        [[SubscriptionManager sharedSubscriptionManager] autoDownloadEpisode:episode];
    }
    else
    {
        if ([episode.feed boolForKey:AutoDeleteAfterMarkedAsPlayed] && !episode.starred) {
            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:YES];
        }
    }
}

- (void) markEpisode:(CDEpisode*)episode asStarred:(BOOL)flag
{
    if (episode.starred != flag)
    {
        episode.starred = flag;
        [self save];

#if !TARGET_OS_IPHONE
        if (flag) {
            [[ICSharingManager sharedManager] triggerEvent:ICSharingServiceEpisodeMarkedAsStarred object:episode];
        }
#endif
    }
}

- (void) markEpisode:(CDEpisode*)episode asDownloaded:(BOOL)flag
{
    if (episode.downloaded != flag)
    {
        episode.downloaded = flag;
        [self save];
    }
}

- (void) setEpisode:(CDEpisode*)episode position:(double)position
{
    episode.position = position;
}

- (void) _removeEpisodeReferences:(CDEpisode*)episode
                          automatic:(BOOL)automatic
                         completion:(void (^)(NSError* error))completion
{
    [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    [cacheManager removeCacheForEpisode:episode automatic:automatic completion:^(NSError* error) {
        if (error) {
            if (completion) completion(error);
            return;
        }
        [cacheManager clearDownloadErrorForEpisode:episode completion:^(NSError* error) {
            if (completion) completion(error);
        }];
    }];
}

- (void) setEpisode:(CDEpisode *)episode archived:(BOOL)archived
{
    episode.archived = archived;
        
    if (archived)
    {
        [self markEpisode:episode asConsumed:YES];
        [self _removeEpisodeReferences:episode automatic:YES completion:nil];
    }
    
    [self save];
}

- (void) deleteEpisode:(CDEpisode*)episode
{
    [self deleteEpisodes:episode ? @[episode] : @[] completion:nil];
}

- (void) deleteEpisodes:(NSArray<CDEpisode*>*)episodes
              completion:(void (^)(NSError* error))completion
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self deleteEpisodes:episodes completion:completion];
        });
        return;
    }

    NSMutableArray<CDEpisode*>* uniqueEpisodes = [NSMutableArray array];
    NSMutableSet<NSManagedObjectID*>* seenObjectIDs = [NSMutableSet set];
    for (CDEpisode* episode in episodes) {
        if (![episode isKindOfClass:[CDEpisode class]] || episode.isDeleted || !episode.managedObjectContext) {
            continue;
        }
        if (![seenObjectIDs containsObject:episode.objectID]) {
            [seenObjectIDs addObject:episode.objectID];
            [uniqueEpisodes addObject:episode];
        }
    }
    if (uniqueEpisodes.count == 0) {
        if (completion) completion(nil);
        return;
    }

    NSArray<CDEpisode*>* temporaryEpisodes = [uniqueEpisodes filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CDEpisode* episode, NSDictionary* bindings) {
        return episode.objectID.isTemporaryID;
    }]];
    if (temporaryEpisodes.count > 0) {
        NSError* permanentIDError = nil;
        if (![self.objectContext obtainPermanentIDsForObjects:temporaryEpisodes error:&permanentIDError]) {
            if (completion) completion(permanentIDError);
            return;
        }
    }

    NSArray<NSManagedObjectID*>* episodeObjectIDs = [uniqueEpisodes valueForKey:@"objectID"];
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    [cacheManager removeCacheForEpisodes:uniqueEpisodes automatic:NO completion:^(NSError* cacheError) {
        if (cacheError) {
            if (completion) completion(cacheError);
            return;
        }
        [cacheManager clearDownloadErrorsForEpisodes:uniqueEpisodes completion:^(NSError* failureStateError) {
            if (failureStateError) {
                if (completion) completion(failureStateError);
                return;
            }
            [[ICiCloudSyncManager sharedManager] beginLocalOutboxBatch];
            [self _deleteEpisodeObjectIDs:episodeObjectIDs
                               startingAt:0
               successfullyDeletedEpisodes:[NSMutableArray array]
                               completion:^(NSError* deleteError) {
                [[ICiCloudSyncManager sharedManager] endLocalOutboxBatch];
                if (completion) completion(deleteError);
            }];
        }];
    }];
}

- (void)_finishDeletingEpisodes:(NSArray<CDEpisode*>*)successfullyDeletedEpisodes
                           error:(NSError*)error
                      completion:(void (^)(NSError* error))completion
{
    if (successfullyDeletedEpisodes.count > 0) {
        [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:successfullyDeletedEpisodes];
    }
    if (completion) completion(error);
}

- (void)_deleteEpisodeObjectIDs:(NSArray<NSManagedObjectID*>*)episodeObjectIDs
                     startingAt:(NSUInteger)startIndex
     successfullyDeletedEpisodes:(NSMutableArray<CDEpisode*>*)successfullyDeletedEpisodes
                     completion:(void (^)(NSError* error))completion
{
    NSUInteger endIndex = MIN(startIndex + kEpisodeDeletionBatchSize, episodeObjectIDs.count);
    NSMutableArray<CDEpisode*>* deletedEpisodes = [NSMutableArray arrayWithCapacity:endIndex - startIndex];
    for (NSUInteger index = startIndex; index < endIndex; index++) {
        NSError* objectError = nil;
        CDEpisode* episode = (CDEpisode*)[self.objectContext existingObjectWithID:episodeObjectIDs[index]
                                                                                error:&objectError];
        if (!objectError && [episode isKindOfClass:[CDEpisode class]] && !episode.isDeleted) {
            [deletedEpisodes addObject:episode];
            [self.objectContext deleteObject:episode];
        }
    }

    NSError* saveError = deletedEpisodes.count > 0 ? [self saveReturningError] : nil;
    if (saveError) {
        for (CDEpisode* episode in deletedEpisodes) {
            if (episode.managedObjectContext && episode.isDeleted) {
                [self.objectContext refreshObject:episode mergeChanges:NO];
            }
        }
        [self.objectContext processPendingChanges];
        [self _finishDeletingEpisodes:successfullyDeletedEpisodes error:saveError completion:completion];
        return;
    }

    [successfullyDeletedEpisodes addObjectsFromArray:deletedEpisodes];
    if (endIndex < episodeObjectIDs.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _deleteEpisodeObjectIDs:episodeObjectIDs
                               startingAt:endIndex
               successfullyDeletedEpisodes:successfullyDeletedEpisodes
                               completion:completion];
        });
    } else {
        [self _finishDeletingEpisodes:successfullyDeletedEpisodes error:nil completion:completion];
    }
}

- (NSArray*) episodesWithObjectHashes:(NSArray*)hashes
{
    NSManagedObjectContext* context = self.objectContext;
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", hashes];
    NSArray* episodes = [context executeFetchRequest:fetchRequest error:nil];
    return episodes;
}

- (CDEpisode*) episodeWithObjectHash:(NSString*)objectHash
{
    NSManagedObjectContext* context = self.objectContext;
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"objectHash == %@", objectHash];
    NSArray* episodes = [context executeFetchRequest:fetchRequest error:nil];
    return [episodes firstObject];
}

- (CDEpisode*) episodeWithGuid:(NSString*)guid
{
    NSManagedObjectContext* context = self.objectContext;
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"guid == %@", guid];
    NSArray* episodes = [context executeFetchRequest:fetchRequest error:nil];
    return [episodes firstObject];
}

- (NSUInteger) numberOfAllUnseenEpisodes
{
    NSManagedObjectContext* context = self.objectContext;
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@ && consumed == %@", @YES, @NO, @NO];
    return [context countForFetchRequest:fetchRequest error:nil];
}

- (NSArray*) allUnseenEpisodesReverseOrder:(BOOL)reverseOrder
{
    NSManagedObjectContext* context = self.objectContext;

    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@ && consumed == %@", @YES, @NO, @NO];
    fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
    return [context executeFetchRequest:fetchRequest error:nil];
}


#pragma mark -

- (NSManagedObjectContext *) objectContext
{
    if (_objectContext) {
        return _objectContext;
    }

    NSPersistentContainer* container = [self persistentContainer];
    if (container)
    {
        NSManagedObjectContext* context = container.viewContext;
        _objectContext = context;
        _objectContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
        [_objectContext setPersistentStoreCoordinator:container.persistentStoreCoordinator];
    }

    return _objectContext;
}

- (NSManagedObjectContext*)newBackgroundContext
{
    NSPersistentContainer* container = [self persistentContainer];
    if (!container) {
        return nil;
    }

    NSManagedObjectContext* context = [container newBackgroundContext];
    context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
    return context;
}

- (NSManagedObjectContext*)newExportBackgroundContext
{
    NSPersistentContainer* container = [self persistentContainer];
    if (!container) {
        return nil;
    }

    // Lazily build a dedicated coordinator over the same store file. Two coordinators on one
    // SQLite/WAL store is exactly the app+extension access pattern — readers on this second
    // coordinator do not acquire the main coordinator's lock, so a multi-second export scan
    // no longer starves main-thread Core Data (list load / cell faults) → no UI freeze.
    @synchronized (self) {
        if (!_exportStoreCoordinator) {
            NSPersistentStoreDescription* mainDescription = container.persistentStoreDescriptions.firstObject;
            NSURL* storeURL = mainDescription.URL;
            if (!storeURL) {
                return nil;
            }
            NSPersistentStoreCoordinator* coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:container.managedObjectModel];
            NSDictionary* options = @{
                NSMigratePersistentStoresAutomaticallyOption: @YES,
                NSInferMappingModelAutomaticallyOption: @YES,
            };
            NSError* addError = nil;
            __unused CFAbsoluteTime openStart = CFAbsoluteTimeGetCurrent();
            NSPersistentStore* store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                 configuration:nil
                                                                           URL:storeURL
                                                                       options:options
                                                                         error:&addError];
            DebugLog(@"[ExportCoordinator] first store open %.1f ms", (CFAbsoluteTimeGetCurrent() - openStart) * 1000.0);
            if (!store) {
                ErrLog(@"Export store coordinator unavailable at %@: %@", storeURL.path, addError.localizedDescription ?: @"unknown error");
                return nil;
            }
            _exportStoreCoordinator = coordinator;
        }
    }

    NSManagedObjectContext* context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = _exportStoreCoordinator;
    // Read-only usage; keep faults small and don't hold on to objects.
    context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
    return context;
}

- (NSManagedObjectContext*)newICloudSyncBackgroundContext
{
    NSPersistentContainer* container = [self persistentContainer];
    if (!container) {
        return nil;
    }

    @synchronized (self) {
        if (!_iCloudSyncStoreCoordinator) {
            NSPersistentStoreDescription* mainDescription = container.persistentStoreDescriptions.firstObject;
            NSURL* storeURL = mainDescription.URL;
            if (!storeURL) {
                return nil;
            }
            NSPersistentStoreCoordinator* coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:container.managedObjectModel];
            NSDictionary* options = @{
                NSMigratePersistentStoresAutomaticallyOption: @YES,
                NSInferMappingModelAutomaticallyOption: @YES,
            };
            NSError* addError = nil;
            NSPersistentStore* store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                 configuration:nil
                                                                           URL:storeURL
                                                                       options:options
                                                                         error:&addError];
            if (!store) {
                ErrLog(@"iCloud sync store coordinator unavailable at %@: %@", storeURL.path, addError.localizedDescription ?: @"unknown error");
                return nil;
            }
            _iCloudSyncStoreCoordinator = coordinator;
        }
    }

    NSManagedObjectContext* context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = _iCloudSyncStoreCoordinator;
    context.mergePolicy = NSErrorMergePolicy;
    context.undoManager = nil;
    return context;
}


- (NSManagedObjectModel *) objectModel
{
    if (_objectModel) {
        return _objectModel;
    }
    
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
    _objectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return _objectModel;
}

- (NSPersistentContainer *)persistentContainer {
    if (_persistentContainer != nil) {
        return _persistentContainer;
    }

    _persistentContainer = [[NSPersistentContainer alloc] initWithName:_ModelFile()];

    NSURL *storeURL = self.databaseURL;
    if (!storeURL || storeURL.path.length == 0) {
        ErrLog(@"Failed to load persistent store: database URL is invalid.");
        self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:nil];
        _persistentContainer = nil;
        return nil;
    }

    NSString* storeDirectory = [storeURL.path stringByDeletingLastPathComponent];
    if (storeDirectory.length == 0) {
        ErrLog(@"Failed to load persistent store: database directory path is invalid (%@).", storeURL.path);
        self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:nil];
        _persistentContainer = nil;
        return nil;
    }

    NSFileManager* fman = [NSFileManager defaultManager];
    if (![fman fileExistsAtPath:storeDirectory]) {
        NSError* createDirectoryError = nil;
        if (![fman createDirectoryAtPath:storeDirectory withIntermediateDirectories:YES attributes:nil error:&createDirectoryError]) {
            ErrLog(@"Failed to create database directory %@: %@", storeDirectory, createDirectoryError);
            self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:createDirectoryError];
            _persistentContainer = nil;
            return nil;
        }
    }

    NSPersistentStoreDescription *storeDescription = [[NSPersistentStoreDescription alloc] initWithURL:storeURL];
    storeDescription.type = NSSQLiteStoreType;
    storeDescription.shouldMigrateStoreAutomatically = YES;
    storeDescription.shouldInferMappingModelAutomatically = YES;
    _persistentContainer.persistentStoreDescriptions = @[storeDescription];
    __block BOOL storeLoadFailed = NO;
    __block NSError* storeLoadError = nil;
    __unused CFAbsoluteTime storeLoadStart = CFAbsoluteTimeGetCurrent();
    [_persistentContainer loadPersistentStoresWithCompletionHandler:^(NSPersistentStoreDescription *description, NSError *error) {
        if (error) {
            ErrLog(@"Failed to load persistent store: %@, %@", error, error.userInfo);
            storeLoadFailed = YES;
            storeLoadError = error;
        }
    }];
    DebugLog(@"[CoreData] persistent store load %.1f ms", (CFAbsoluteTimeGetCurrent() - storeLoadStart) * 1000.0);

    if (storeLoadFailed) {
        ErrLog(@"Persistent store unavailable at %@ (%@). Keeping existing files untouched.", storeURL.path, storeLoadError.localizedDescription ?: @"unknown error");
        self.initializationError = [self _databaseInitializationErrorWithUnderlyingError:storeLoadError];
        _persistentContainer = nil;
        return nil;
    }

    self.initializationError = nil;
    _persistentContainer.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
    _persistentContainer.viewContext.automaticallyMergesChangesFromParent = YES;

    self.storeCoordinator = _persistentContainer.persistentStoreCoordinator;
    return _persistentContainer;
}

- (void)refreshAllObjects {
    NSError *error = nil;
    if ([self.objectContext save:&error]) {
        [self.objectContext refreshAllObjects];
    } else {
        ErrLog(@"Failed to save context: %@", error.localizedDescription);
    }
}

@end
