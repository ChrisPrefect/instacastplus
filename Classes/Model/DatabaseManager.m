//
//  DatabaseManager.m
//  Instacast
//
//  Created by Martin Hering on 22.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <objc/runtime.h>
#include <sys/xattr.h>

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

#import "UIManager.h"
#import "ICFTSController.h"
#import "ICSpotlightIndexer.h"

// legacy migration
#import "CDSmartPlaylist.h"
#import "CDPlaylist.h"
#import "FSCrossbucketConnection.h"


#define MODEL_VERSION 5
NSTimeInterval kTrialReferenceDate = 0;

static DatabaseManager* gSharedDatabaseManager = nil;

NSString* DatabaseManagerDidUpdateObservedFeedNotification = @"DatabaseManagerDidUpdateObservedFeedNotification";
NSString* DatabaseManagerDidAddBookmarkNotification = @"DatabaseManagerDidAddBookmarkNotification";

static NSString* kDefaultEpisodePositionMigrationDone = @"EpisodePositionMigrationDone";
static NSString* kDefaultFTSMigrationDone = @"FTSMigrationDone";
static NSString* kDefaultSpotlightMigrationDone = @"SpotlightMigrationDone";


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
@property (nonatomic, strong, readwrite) ICFTSController* ftsController;
@property (nonatomic, strong, readwrite) ICSpotlightIndexer* spotlightIndexer;
@property (nonatomic, readwrite) BOOL ftsIndexing;


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
	if (!gSharedDatabaseManager) {
		gSharedDatabaseManager = [self alloc];
		gSharedDatabaseManager = [gSharedDatabaseManager init];
	}
	return gSharedDatabaseManager;
}

#pragma mark -

NS_INLINE NSString* _ModelFile(void) {
    return [NSString stringWithFormat:@"Model%d", MODEL_VERSION];
}

NS_INLINE NSString* _DataStoreFile(void) {
    return [NSString stringWithFormat:@"DataStore%d.sqlite", MODEL_VERSION];
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
        @"FTSIndex.sqlite",
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
    for(version = MODEL_VERSION-1; version>0; version--)
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

+ (BOOL) dataStoreNeedsMigrationForFileAtURL:(NSURL*)storeURL
{
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:_ModelFile() withExtension:@"momd"];
    NSManagedObjectModel* destinationModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    
    NSError *error = nil;
    NSDictionary *sourceMetadata;
    
    @try {
        sourceMetadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSSQLiteStoreType
                                                                                    URL:storeURL
                                                                                options:nil
                                                                                  error:&error];
    }
    @catch (NSException *exception) {
    }
    
    return (![destinationModel isConfiguration:nil compatibleWithStoreMetadata:sourceMetadata]);
}

+ (BOOL) dataStoreNeedsMigration
{
    // check current file (in Data/ subfolder)
    NSURL* storeURL = [NSURL fileURLWithPath:[[DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]] stringByAppendingPathComponent:_DataStoreFile()]];
    NSFileManager* fman = [[NSFileManager alloc] init];
    if ([fman fileExistsAtPath:[storeURL path]]) {
        return [self dataStoreNeedsMigrationForFileAtURL:storeURL];
    }

    // check old file
    NSURL* urlOfLastDataStoreFile = [self _urlOfLastDataStoreFile];
    if ([fman fileExistsAtPath:[urlOfLastDataStoreFile path]]) {
        return [self dataStoreNeedsMigrationForFileAtURL:urlOfLastDataStoreFile];
    }

    return NO;
}

- (id) init
{
	if ((self = [super init]))
	{
        // Ensure Data subfolder exists
        NSString* dataPath = [DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]];

        _databaseURL = [NSURL fileURLWithPath:[dataPath stringByAppendingPathComponent:_DataStoreFile()]];

        _imageCacheURL = [NSURL fileURLWithPath:[DatabaseManager pathToSubfolder:@"Images" parent:[DatabaseManager pathToDocuments]]];
        _fileCacheURL = [NSURL fileURLWithPath:[DatabaseManager pathToSubfolder:@"Episodes" parent:[DatabaseManager pathToDocuments]]];

        // Migrate: move database files from old Documents root to Data subfolder
        [DatabaseManager _migrateRootFilesToDataFolder];

        // find old database file and make a copy for new database
        if (![[NSFileManager defaultManager] fileExistsAtPath:[_databaseURL path]])
        {
            NSURL* urlOfLastDataStoreFile = [DatabaseManager _urlOfLastDataStoreFile];
            if ([[NSFileManager defaultManager] fileExistsAtPath:[urlOfLastDataStoreFile path]])
            {
                NSError* error;
                if (![[NSFileManager defaultManager] copyItemAtURL:urlOfLastDataStoreFile toURL:_databaseURL error:&error]) {
                    ErrLog(@"error copying old database file to new location");
                }

                NSURL* shmURL = [[urlOfLastDataStoreFile URLByDeletingPathExtension] URLByAppendingPathExtension:@"sqlite-shm"];
                NSURL* toShmURL = [[_databaseURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"sqlite-shm"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:[shmURL path]]) {
                    NSError* error;
                    if (![[NSFileManager defaultManager] copyItemAtURL:shmURL toURL:toShmURL error:&error]) {
                        ErrLog(@"error copying old database shm file to new location");
                    }
                }

                NSURL* walURL = [[urlOfLastDataStoreFile URLByDeletingPathExtension] URLByAppendingPathExtension:@"sqlite-wal"];
                NSURL* toWalURL = [[_databaseURL URLByDeletingPathExtension] URLByAppendingPathExtension:@"sqlite-wal"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:[walURL path]]) {
                    NSError* error;
                    if (![[NSFileManager defaultManager] copyItemAtURL:walURL toURL:toWalURL error:&error]) {
                        ErrLog(@"error copying old database wal file to new location");
                    }
                }
            }
        }


        // create initial data when started first
        if (![[NSFileManager defaultManager] fileExistsAtPath:[_databaseURL path]]) {
            [self _createDatabase];
        }
        else {
            [self _migrateDatabase];
            [self _deleteUnsubscribedFeeds];
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
        
        
        _ftsController = [[ICFTSController alloc] initWithSearchIndexURL:[NSURL fileURLWithPath:[[DatabaseManager pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]] stringByAppendingPathComponent:@"FTSIndex.sqlite"]]];
        [_ftsController open];
        _spotlightIndexer = [[ICSpotlightIndexer alloc] init];

        [self _migrateFTS];
        [self _migrateSpotlight];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextObjectsDidChangeNotification:)
                                                     name:NSManagedObjectContextObjectsDidChangeNotification
                                                   object:self.objectContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(transcriptionDidFinishNotification:)
                                                     name:ICTranscriptionDidFinishNotification
                                                   object:nil];
	}
	return self;
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
    NSMutableSet *uniqueRecords = [NSMutableSet set];


    for (CDList *object in fetchedResults) {
        if (![uniqueRecords containsObject:object.uid]) {
            [uniqueRecords addObject:object.uid];
        }
    }

    NSArray *lists = [uniqueRecords allObjects];
    
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
        else if ([list isKindOfClass:[CDPlaylist class]])
        {
            // custom list migration doesn't work and has been removed
            // no support anymore
            [self.objectContext deleteObject:list];
            [self save];
        }
    }
}

- (NSString *)normalizedURLString:(NSURL *)url {
    if (!url) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    components.scheme = components.scheme.lowercaseString;
    components.host = components.host.lowercaseString;
    if (components.path.length == 0) components.path = @"/";
    if ([components.path hasSuffix:@"/"] && components.path.length > 1) {
        components.path = [components.path substringToIndex:components.path.length - 1];
    }
    return components.URL.absoluteString;
}

- (void) _migrateFTS
{
    if ([USER_DEFAULTS boolForKey:kDefaultFTSMigrationDone]) {
        return;
    }
    
    self.ftsIndexing = YES;
    
    NSManagedObjectContext* childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [childContext setParentContext:self.objectContext];
    
    [childContext performBlock:^{
        
        NSFetchRequest* feedRequest = [[NSFetchRequest alloc] init];
        feedRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:childContext];
        feedRequest.fetchBatchSize = 50;
        
        NSError* error;
        NSArray* objects = [childContext executeFetchRequest:feedRequest error:&error];
        if (error) {
            ErrLog(@"error fetching feeds from private context: %@", error);
        }
        
        [self.ftsController indexFeeds:objects];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [USER_DEFAULTS setBool:YES forKey:kDefaultFTSMigrationDone];
            self.ftsIndexing = NO;
        });
    }];
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
    [self _migrateOldSmartPlaylists];
    [self _migrateAddStartedList];
    [self _migrateDefaultListNamesToKeys];
    [self _migrateRemoveDuplicateFeeds];
    [self _migrateRemoveDuplicateLists];
    [self _migrateRemoveObsoletePauseFeedProperty];
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
    // Remove ghost duplicate feeds: same sourceURL, keep the one with more episodes.
    // Duplicates can arise from subscribeFeedMetadataOnly creating parked placeholders
    // that never got properly merged with the real subscription.
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
    NSArray* allFeeds = [self.objectContext executeFetchRequest:fetchRequest error:nil];

    NSMutableDictionary<NSString*, NSMutableArray<CDFeed*>*>* feedsByURL = [NSMutableDictionary dictionary];
    for (CDFeed* feed in allFeeds) {
        NSString* urlStr = feed.sourceURL.absoluteString;
        if (!urlStr) continue;
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
            return [@(b.episodes.count) compare:@(a.episodes.count)];
        }];

        // Keep first (non-parked, most episodes), delete rest
        for (NSUInteger i = 1; i < feeds.count; i++) {
            CDFeed* duplicate = feeds[i];
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
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:self.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == NO"];
    NSArray* unsubscribedFeeds = [self.objectContext executeFetchRequest:fetchRequest error:nil];
    
    for(NSManagedObject* feed in unsubscribedFeeds) {
        [self.objectContext deleteObject:feed];
    }
    [self save];
    
}

- (void) save
{
    if (_savingInterruption == 0)
    {
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

        NSError* error;
        if (![self.objectContext save:&error] ) {
            ErrLog(@"Error saving context: %@", error.localizedDescription);
        }
        else {
            [self.persistentContainer.viewContext processPendingChanges];
        }

        if (error) {
            ErrLog(@"error saving database context: %@", error);
        }
    }
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
    
    //    NSMutableSet* set = [[NSMutableSet alloc] init];
    //    [set unionSet:insertedObjects];
    //    [set unionSet:updatedObjects];
    //    [set unionSet:deletedObjects];
    
    
    for(NSManagedObject* insertedObject in insertedObjects)
    {
        if ([insertedObject isKindOfClass:[CDEpisode class]]) {
            [self.ftsController addEpisode:(CDEpisode*)insertedObject];
            [self.spotlightIndexer addEpisode:(CDEpisode*)insertedObject];
        }
        else if ([insertedObject isKindOfClass:[CDFeed class]]) {
            [self.ftsController addFeed:(CDFeed*)insertedObject];
            [self.spotlightIndexer addFeed:(CDFeed*)insertedObject];
        }
    }
    
    for(NSManagedObject* updatedObject in updatedObjects)
    {
        NSDictionary* cv = [updatedObject changedValues];
        
        if ([updatedObject isKindOfClass:[CDEpisode class]] && (cv[@"title"] || cv[@"summary"] || cv[@"fulltext"])) {
            [self.ftsController updateEpisode:(CDEpisode*)updatedObject];
        }
        else if ([updatedObject isKindOfClass:[CDFeed class]] && (cv[@"title"] || cv[@"author"] || cv[@"summary"])) {
            [self.ftsController updateFeed:(CDFeed*)updatedObject];
        }

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
    }
    
    for(NSManagedObject* deletedObject in deletedObjects)
    {
        if ([deletedObject isKindOfClass:[CDEpisode class]]) {
            [self.ftsController removeEpisode:(CDEpisode*)deletedObject];
            [self.spotlightIndexer removeEpisode:(CDEpisode*)deletedObject];
        }
        else if ([deletedObject isKindOfClass:[CDFeed class]]) {
            [self.ftsController removeFeed:(CDFeed*)deletedObject];
            [self.spotlightIndexer removeFeed:(CDFeed*)deletedObject];
        }
    }
}

- (void) transcriptionDidFinishNotification:(NSNotification*)notification
{
    NSString* episodeHash = notification.userInfo[@"episodeHash"];
    if (episodeHash.length == 0) {
        return;
    }

    CDEpisode* episode = [self episodeWithObjectHash:episodeHash];
    if (episode) {
        [self.spotlightIndexer updateEpisode:episode];
    }
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
            [self save];
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

    // Set up lazy loading state if there are more episodes to load
    if (totalEpisodeCount > kInitialEpisodeLimit) {
        [persistentFeed setBool:NO forKey:kFeedPropertyEpisodeLoadingComplete];
        [persistentFeed setInteger:totalEpisodeCount forKey:kFeedPropertyTotalExpectedEpisodes];
        [persistentFeed setInteger:initialLoadCount forKey:kFeedPropertyLoadedEpisodeCount];

        // Queue remaining episodes for background loading
        [[EpisodeLoadingManager sharedManager] queuePendingEpisodesForFeed:persistentFeed
                                                            parserEpisodes:sortedEpisodes
                                                                startIndex:initialLoadCount];
    } else {
        [persistentFeed setBool:YES forKey:kFeedPropertyEpisodeLoadingComplete];
    }

    [self save];

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
    NSString *target = [self normalizedURLString:sourceURL];
    for (CDFeed* feed in self.feeds) {
        NSString *existing = [self normalizedURLString:feed.sourceURL];
        if ([existing isEqualToString:target]) {
            return feed;
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
{
    [self beginInterruptSaving];
    
    [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
    [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:YES];
    
    [self endInterruptSaving];
}

- (void) setEpisode:(CDEpisode *)episode archived:(BOOL)archived
{
    episode.archived = archived;
        
    if (archived)
    {
        [self markEpisode:episode asConsumed:YES];
        [self _removeEpisodeReferences:episode];
    }
    
    [self save];
}

- (void) deleteEpisode:(CDEpisode*)episode
{
    [self _removeEpisodeReferences:episode];
    [self.objectContext deleteObject:episode];
    
    [self save];
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
                NSPersistentHistoryTrackingKey: @YES,
            };
            NSError* addError = nil;
            NSPersistentStore* store = [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                                                 configuration:nil
                                                                           URL:storeURL
                                                                       options:options
                                                                         error:&addError];
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
        _persistentContainer = nil;
        return nil;
    }

    NSString* storeDirectory = [storeURL.path stringByDeletingLastPathComponent];
    if (storeDirectory.length == 0) {
        ErrLog(@"Failed to load persistent store: database directory path is invalid (%@).", storeURL.path);
        _persistentContainer = nil;
        return nil;
    }

    NSFileManager* fman = [NSFileManager defaultManager];
    if (![fman fileExistsAtPath:storeDirectory]) {
        NSError* createDirectoryError = nil;
        if (![fman createDirectoryAtPath:storeDirectory withIntermediateDirectories:YES attributes:nil error:&createDirectoryError]) {
            ErrLog(@"Failed to create database directory %@: %@", storeDirectory, createDirectoryError);
            _persistentContainer = nil;
            return nil;
        }
    }

    NSPersistentStoreDescription *storeDescription = [[NSPersistentStoreDescription alloc] initWithURL:storeURL];
    storeDescription.type = NSSQLiteStoreType;
    storeDescription.shouldMigrateStoreAutomatically = YES;
    storeDescription.shouldInferMappingModelAutomatically = YES;
    // Required: existing stores may already use persistent history tracking.
    // Without this flag, CoreData forces Read Only mode on the existing store.
    [storeDescription setOption:@YES forKey:NSPersistentHistoryTrackingKey];
    _persistentContainer.persistentStoreDescriptions = @[storeDescription];
    __block BOOL storeLoadFailed = NO;
    __block NSError* storeLoadError = nil;
    [_persistentContainer loadPersistentStoresWithCompletionHandler:^(NSPersistentStoreDescription *description, NSError *error) {
        if (error) {
            ErrLog(@"Failed to load persistent store: %@, %@", error, error.userInfo);
            storeLoadFailed = YES;
            storeLoadError = error;
        }
    }];

    if (storeLoadFailed) {
        ErrLog(@"Persistent store unavailable at %@ (%@). Keeping existing files untouched.", storeURL.path, storeLoadError.localizedDescription ?: @"unknown error");
        _persistentContainer = nil;
        return nil;
    }

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
