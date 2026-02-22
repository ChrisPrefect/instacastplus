//
//  Application.m
//  Instacast
//
//  Created by Martin Hering on 03.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#include <asl.h>
#include <sys/sysctl.h>
#include <sqlite3.h>
#include <unistd.h>

#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import "VDModalInfo.h"
#import "Reachability.h"
#import "ICErrorSheet.h"
#import <MediaPlayer/MPVolumeView.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"
#import "CDModel.h"
#import "CDPlaylist.h"
#import "CDPlaylistEpisode.h"
#import "CDSmartPlaylist.h"
#import "CDEpisodeList.h"
#import "DatabaseManager.h"
#import "SubscriptionManager.h"
#import "ICFeed.h"
#import "UtilityFunctions.h"
#import "ICDailyBackupManager.h"


NSString* UniqueDeviceId = @"UniqueDeviceId";
NSString* ApplicationDidRegisterTouchNotification = @"ApplicationDidRegisterTouchNotification";

@interface Application ()
@property (nonatomic, readwrite, strong) UIAlertController* errorAlertController;
@property (nonatomic, readwrite, strong) NSOperationQueue* mainQueue;
@property (nonatomic, readwrite, strong) CTTelephonyNetworkInfo* telephonyInfo;
@property (nonatomic, strong) Reachability* reachability;
@property (nonatomic, strong) ICErrorSheet* backgroundErrorSheet;
@property (nonatomic, readwrite, strong) GTMLogger* applicationLogger;
@property (nonatomic, strong) CMMotionManager *motionManager;
@end

#pragma mark - Daily Backup

NSString* const ICDailyBackupManagerStatusDidChangeNotification = @"ICDailyBackupManagerStatusDidChangeNotification";

static NSString* const kICDailyBackupErrorDomain = @"ICDailyBackupErrorDomain";
static NSString* const kICDailyBackupFolderName = @"AutoBackups";
static NSString* const kICDailyBackupInfoFileName = @"Info.plist";
static NSString* const kICDailyBackupSnapshotSQLiteFileName = @"DataStoreSnapshot.sqlite";
static NSString* const kICDailyBackupDefaultsFileName = @"UserDefaults.plist";
static NSString* const kICDailyBackupPendingRestoreFileName = @"PendingRestore.plist";
static NSInteger const kICDailyBackupRetentionDays = 7;

static void ICDailyBackupPerformOnMainThreadSync(dispatch_block_t block)
{
    if (!block) {
        return;
    }

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static NSError* ICDailyBackupError(NSInteger code, NSString* description, NSError* underlyingError)
{
    NSMutableDictionary* userInfo = [[NSMutableDictionary alloc] init];
    if (description.length > 0) {
        userInfo[NSLocalizedDescriptionKey] = description;
    }
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }

    return [NSError errorWithDomain:kICDailyBackupErrorDomain code:code userInfo:userInfo];
}

static unsigned long long ICDailyBackupDirectorySizeAtPath(NSString* path)
{
    NSFileManager* fman = [NSFileManager defaultManager];
    NSDirectoryEnumerator* enumerator = [fman enumeratorAtPath:path];
    unsigned long long totalSize = 0;

    for (NSString* fileName in enumerator) {
        NSString* filePath = [path stringByAppendingPathComponent:fileName];
        NSDictionary* attributes = [fman attributesOfItemAtPath:filePath error:nil];
        if ([attributes[NSFileType] isEqualToString:NSFileTypeRegular]) {
            NSNumber* fileSize = attributes[NSFileSize];
            totalSize += [fileSize unsignedLongLongValue];
        }
    }

    return totalSize;
}

static NSError* ICDailyBackupCopySQLiteDatabase(NSString* sourcePath, NSString* destinationPath)
{
    if (sourcePath.length == 0 || destinationPath.length == 0) {
        return ICDailyBackupError(1001, @"Invalid database path for backup.", nil);
    }

    NSFileManager* fman = [NSFileManager defaultManager];
    if (![fman fileExistsAtPath:sourcePath]) {
        return ICDailyBackupError(1002, @"The source database does not exist.", nil);
    }

    [fman removeItemAtPath:destinationPath error:nil];

    sqlite3* sourceDB = NULL;
    sqlite3* destinationDB = NULL;
    sqlite3_backup* backup = NULL;
    NSError* backupError = nil;

    do {
        int rc = sqlite3_open_v2([sourcePath UTF8String], &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
        if (rc != SQLITE_OK) {
            NSString* message = sourceDB ? [NSString stringWithUTF8String:sqlite3_errmsg(sourceDB)] : @"Could not open source database.";
            backupError = ICDailyBackupError(1003, message ?: @"Could not open source database.", nil);
            break;
        }

        rc = sqlite3_open_v2([destinationPath UTF8String], &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
        if (rc != SQLITE_OK) {
            NSString* message = destinationDB ? [NSString stringWithUTF8String:sqlite3_errmsg(destinationDB)] : @"Could not open destination database.";
            backupError = ICDailyBackupError(1004, message ?: @"Could not open destination database.", nil);
            break;
        }

        backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main");
        if (!backup) {
            NSString* message = [NSString stringWithUTF8String:sqlite3_errmsg(destinationDB)];
            backupError = ICDailyBackupError(1005, message ?: @"Could not initialize SQLite backup.", nil);
            break;
        }

        int stepResult = SQLITE_OK;
        NSUInteger busyRetryCount = 0;
        const NSUInteger maxBusyRetries = 250; // ~5 seconds

        while (stepResult == SQLITE_OK || stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED) {
            stepResult = sqlite3_backup_step(backup, 256);
            if (stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED) {
                busyRetryCount += 1;
                if (busyRetryCount > maxBusyRetries) {
                    break;
                }
                usleep(20000);
            }
        }

        if (stepResult != SQLITE_DONE) {
            NSString* message = [NSString stringWithUTF8String:sqlite3_errmsg(destinationDB)];
            backupError = ICDailyBackupError(1006, message ?: @"SQLite backup did not finish successfully.", nil);
            break;
        }

        rc = sqlite3_backup_finish(backup);
        backup = NULL;
        if (rc != SQLITE_OK) {
            NSString* message = [NSString stringWithUTF8String:sqlite3_errmsg(destinationDB)];
            backupError = ICDailyBackupError(1007, message ?: @"SQLite backup finalization failed.", nil);
            break;
        }
    } while (NO);

    if (backup) {
        sqlite3_backup_finish(backup);
    }
    if (sourceDB) {
        sqlite3_close(sourceDB);
    }
    if (destinationDB) {
        sqlite3_close(destinationDB);
    }

    return backupError;
}

static NSError* ICDailyBackupValidateSQLiteDatabase(NSString* path)
{
    if (path.length == 0) {
        return ICDailyBackupError(1008, @"Invalid database path for validation.", nil);
    }

    NSFileManager* fman = [NSFileManager defaultManager];
    if (![fman fileExistsAtPath:path]) {
        return ICDailyBackupError(1009, @"Database file for validation does not exist.", nil);
    }

    sqlite3* db = NULL;
    sqlite3_stmt* statement = NULL;
    NSError* validationError = nil;
    const unsigned char* text = NULL;
    NSString* result = nil;

    do {
        // Snapshot files can retain WAL journal mode metadata.
        // Read-only handles can fail at statement prepare with SQLITE_CANTOPEN when
        // SQLite needs access to sidecar files; open read-write (without CREATE)
        // so integrity_check can run reliably against the snapshot.
        int rc = sqlite3_open_v2([path UTF8String], &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL);
        if (rc != SQLITE_OK) {
            NSString* message = db ? [NSString stringWithUTF8String:sqlite3_errmsg(db)] : @"Could not open database for validation.";
            validationError = ICDailyBackupError(1013, message ?: @"Could not open database for validation.", nil);
            break;
        }

        rc = sqlite3_prepare_v2(db, "PRAGMA integrity_check(1);", -1, &statement, NULL);
        if (rc != SQLITE_OK) {
            NSString* message = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
            validationError = ICDailyBackupError(1014, message ?: @"Could not prepare SQLite integrity check.", nil);
            break;
        }

        rc = sqlite3_step(statement);
        if (rc != SQLITE_ROW) {
            NSString* message = [NSString stringWithUTF8String:sqlite3_errmsg(db)];
            validationError = ICDailyBackupError(1015, message ?: @"SQLite integrity check did not return a result.", nil);
            break;
        }

        text = sqlite3_column_text(statement, 0);
        result = text ? [NSString stringWithUTF8String:(const char*)text] : @"";
        if (![result isEqualToString:@"ok"]) {
            validationError = ICDailyBackupError(1016, [NSString stringWithFormat:@"SQLite integrity check failed: %@", result ?: @"unknown"], nil);
            break;
        }
    } while (NO);

    if (statement) {
        sqlite3_finalize(statement);
    }
    if (db) {
        sqlite3_close(db);
    }

    return validationError;
}

@interface ICDailyBackupManager ()
@property (nonatomic, strong) dispatch_queue_t backupQueue;
@property (atomic, copy) NSArray<NSDictionary*>* cachedBackups;
@property (atomic, copy) NSDictionary<NSString*, id>* latestStatusSnapshot;
@property (nonatomic, strong) NSDate* lastSuccessfulBackupDate;
@property (nonatomic, copy) NSString* lastErrorDescription;
@property (nonatomic) BOOL backupInProgress;
@end

@implementation ICDailyBackupManager

+ (instancetype)sharedManager
{
    static ICDailyBackupManager* manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[self alloc] initPrivate];
    });
    return manager;
}

- (instancetype)init
{
    NSAssert(NO, @"Use +sharedManager");
    return nil;
}

- (instancetype)initPrivate
{
    if ((self = [super init])) {
        _backupQueue = dispatch_queue_create("com.instacastplus.dailybackup", DISPATCH_QUEUE_SERIAL);
        _cachedBackups = @[];
        _latestStatusSnapshot = @{
            @"backupInProgress": @NO,
            @"retentionDays": @(kICDailyBackupRetentionDays),
            @"availableBackups": @0,
            @"lastSuccessfulBackupDate": [NSNull null],
            @"lastErrorDescription": [NSNull null],
            @"backupDestination": @""
        };

        dispatch_async(_backupQueue, ^{
            [self _reloadBackupsLocked];
            NSDictionary* latest = [self.cachedBackups firstObject];
            NSDate* latestDate = latest[@"date"];
            if ([latestDate isKindOfClass:[NSDate class]]) {
                self.lastSuccessfulBackupDate = latestDate;
            }
            [self _publishStatusChangeLocked];
        });
    }
    return self;
}

+ (void)applyPendingRestoreIfNeededAtLaunch
{
    ICDailyBackupManager* manager = [ICDailyBackupManager sharedManager];
    dispatch_sync(manager.backupQueue, ^{
        [manager _applyPendingRestoreIfNeededLocked];
    });
}

- (NSDictionary<NSString*, id>*)statusSnapshot
{
    NSDictionary<NSString*, id>* snapshot = self.latestStatusSnapshot;
    if (snapshot) {
        return snapshot;
    }

    return @{
        @"backupInProgress": @(self.backupInProgress),
        @"retentionDays": @(kICDailyBackupRetentionDays),
        @"availableBackups": @(self.cachedBackups.count),
        @"lastSuccessfulBackupDate": self.lastSuccessfulBackupDate ?: [NSNull null],
        @"lastErrorDescription": self.lastErrorDescription ?: [NSNull null],
        @"backupDestination": @""
    };
}

- (NSArray<NSDictionary*>*)availableBackups
{
    NSArray<NSDictionary*>* snapshot = self.cachedBackups;
    return snapshot ? [snapshot copy] : @[];
}

- (void)scheduleDailyBackupIfNeededWithReason:(NSString*)reason
{
    dispatch_async(self.backupQueue, ^{
        [self _reloadBackupsLocked];
        NSDictionary* latestBackup = [self.cachedBackups firstObject];
        NSDate* latestDate = latestBackup[@"date"];

        if ([latestDate isKindOfClass:[NSDate class]] &&
            [[NSCalendar currentCalendar] isDate:latestDate inSameDayAsDate:[NSDate date]]) {
            return;
        }

        [self _createBackupLockedWithReason:(reason ?: @"scheduled")
                                      force:NO
                                 completion:nil];
    });
}

- (void)createBackupNowWithReason:(NSString*)reason
                       completion:(void (^)(BOOL success, NSError* _Nullable error))completion
{
    dispatch_async(self.backupQueue, ^{
        [self _createBackupLockedWithReason:(reason ?: @"manual")
                                      force:YES
                                 completion:completion];
    });
}

- (void)prepareRestoreForBackupWithIdentifier:(NSString*)identifier
                                   completion:(void (^)(BOOL success, NSError* _Nullable error))completion
{
    dispatch_async(self.backupQueue, ^{
        [self _reloadBackupsLocked];

        NSDictionary* target = nil;
        for (NSDictionary* entry in self.cachedBackups) {
            if ([entry[@"identifier"] isEqualToString:identifier]) {
                target = entry;
                break;
            }
        }

        if (!target) {
            NSError* error = ICDailyBackupError(1010, @"Backup snapshot not found.", nil);
            [self _complete:completion success:NO error:error];
            return;
        }

        NSString* backupPath = target[@"path"];
        NSString* backupSQLitePath = [backupPath stringByAppendingPathComponent:kICDailyBackupSnapshotSQLiteFileName];
        NSString* backupDefaultsPath = [backupPath stringByAppendingPathComponent:kICDailyBackupDefaultsFileName];

        NSFileManager* fman = [NSFileManager defaultManager];
        if (![fman fileExistsAtPath:backupSQLitePath] || ![fman fileExistsAtPath:backupDefaultsPath]) {
            NSError* error = ICDailyBackupError(1011, @"Backup snapshot is incomplete.", nil);
            [self _complete:completion success:NO error:error];
            return;
        }

        NSError* sqliteValidationError = ICDailyBackupValidateSQLiteDatabase(backupSQLitePath);
        if (sqliteValidationError) {
            [self _complete:completion success:NO error:sqliteValidationError];
            return;
        }

        NSDictionary* defaultsSnapshot = [NSDictionary dictionaryWithContentsOfFile:backupDefaultsPath];
        if (![defaultsSnapshot isKindOfClass:[NSDictionary class]]) {
            NSError* error = ICDailyBackupError(1017, @"Backup settings snapshot is unreadable.", nil);
            [self _complete:completion success:NO error:error];
            return;
        }

        if (![NSPropertyListSerialization propertyList:defaultsSnapshot isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
            NSError* error = ICDailyBackupError(1018, @"Backup settings snapshot contains invalid values.", nil);
            [self _complete:completion success:NO error:error];
            return;
        }

        NSString* pendingPath = [self _pendingRestoreRequestPathLocked];
        NSDictionary* request = @{
            @"backupID": identifier ?: @"",
            @"requestedAt": [NSDate date]
        };

        if (![request writeToFile:pendingPath atomically:YES]) {
            NSError* error = ICDailyBackupError(1012, @"Could not prepare backup restore request.", nil);
            [self _complete:completion success:NO error:error];
            return;
        }

        self.lastErrorDescription = nil;
        [self _publishStatusChangeLocked];
        [self _complete:completion success:YES error:nil];
    });
}

- (NSString*)_dataPathLocked
{
    NSString* documents = [DatabaseManager pathToDocuments];
    return [DatabaseManager pathToSubfolder:@"Data" parent:documents];
}

- (NSString*)_backupRootPathLocked
{
    NSString* dataPath = [self _dataPathLocked];
    if (dataPath.length == 0) {
        return nil;
    }

    NSString* backupPath = [DatabaseManager pathToSubfolder:kICDailyBackupFolderName parent:dataPath];
    if (backupPath.length > 0) {
        AddSkipBackupAttributeToFile(backupPath);
    }
    return backupPath;
}

- (NSString*)_pendingRestoreRequestPathLocked
{
    NSString* dataPath = [self _dataPathLocked];
    if (dataPath.length == 0) {
        return nil;
    }
    return [dataPath stringByAppendingPathComponent:kICDailyBackupPendingRestoreFileName];
}

- (NSString*)_backupIdentifierForDateLocked:(NSDate*)date
{
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone localTimeZone];
    formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    return [formatter stringFromDate:(date ?: [NSDate date])];
}

- (void)_reloadBackupsLocked
{
    NSString* backupRoot = [self _backupRootPathLocked];
    if (backupRoot.length == 0) {
        self.cachedBackups = @[];
        return;
    }

    NSFileManager* fman = [NSFileManager defaultManager];
    NSArray* names = [fman contentsOfDirectoryAtPath:backupRoot error:nil] ?: @[];
    NSMutableArray<NSDictionary*>* backups = [[NSMutableArray alloc] init];

    for (NSString* name in names) {
        if ([name hasPrefix:@"tmp-"]) {
            continue;
        }

        NSString* path = [backupRoot stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        if (![fman fileExistsAtPath:path isDirectory:&isDirectory] || !isDirectory) {
            continue;
        }

        NSString* infoPath = [path stringByAppendingPathComponent:kICDailyBackupInfoFileName];
        NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:infoPath] ?: @{};
        NSDate* createdAt = info[@"createdAt"];

        if (![createdAt isKindOfClass:[NSDate class]]) {
            NSDictionary* attrs = [fman attributesOfItemAtPath:path error:nil];
            createdAt = attrs[NSFileCreationDate];
        }

        if (![createdAt isKindOfClass:[NSDate class]]) {
            continue;
        }

        unsigned long long bytes = ICDailyBackupDirectorySizeAtPath(path);
        [backups addObject:@{
            @"identifier": name,
            @"date": createdAt,
            @"path": path,
            @"sizeBytes": @(bytes)
        }];
    }

    [backups sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        NSDate* dateA = a[@"date"];
        NSDate* dateB = b[@"date"];
        NSComparisonResult result = [dateB compare:dateA];
        if (result == NSOrderedSame) {
            NSString* identifierA = a[@"identifier"] ?: @"";
            NSString* identifierB = b[@"identifier"] ?: @"";
            return [identifierB compare:identifierA];
        }
        return result;
    }];

    self.cachedBackups = [backups copy];
}

- (NSDictionary<NSString*, id>*)_statusSnapshotLocked
{
    NSString* backupRoot = [self _backupRootPathLocked];
    return @{
        @"backupInProgress": @(self.backupInProgress),
        @"retentionDays": @(kICDailyBackupRetentionDays),
        @"availableBackups": @(self.cachedBackups.count),
        @"lastSuccessfulBackupDate": self.lastSuccessfulBackupDate ?: [NSNull null],
        @"lastErrorDescription": self.lastErrorDescription ?: [NSNull null],
        @"backupDestination": backupRoot ?: @""
    };
}

- (void)_pruneBackupsLocked
{
    [self _reloadBackupsLocked];

    NSFileManager* fman = [NSFileManager defaultManager];
    NSCalendar* calendar = [NSCalendar currentCalendar];
    NSDate* todayStart = [calendar startOfDayForDate:[NSDate date]];
    NSDate* cutoffDate = [calendar dateByAddingUnit:NSCalendarUnitDay value:-(kICDailyBackupRetentionDays - 1) toDate:todayStart options:0];

    for (NSDictionary* entry in [self.cachedBackups copy]) {
        NSDate* date = entry[@"date"];
        if (![date isKindOfClass:[NSDate class]]) {
            continue;
        }

        if ([date compare:cutoffDate] != NSOrderedAscending) {
            continue;
        }

        NSString* path = entry[@"path"];
        if (path.length == 0) {
            continue;
        }
        NSError* error = nil;
        if (![fman removeItemAtPath:path error:&error]) {
            ErrLog(@"Daily backup prune failed for %@: %@", path, error);
        }
    }

    [self _reloadBackupsLocked];

    if (self.cachedBackups.count <= kICDailyBackupRetentionDays) {
        return;
    }

    NSArray* staleBackups = [self.cachedBackups subarrayWithRange:NSMakeRange(kICDailyBackupRetentionDays, self.cachedBackups.count - kICDailyBackupRetentionDays)];
    for (NSDictionary* entry in staleBackups) {
        NSString* path = entry[@"path"];
        if (path.length == 0) {
            continue;
        }
        NSError* error = nil;
        if (![fman removeItemAtPath:path error:&error]) {
            ErrLog(@"Daily backup prune failed for %@: %@", path, error);
        }
    }

    [self _reloadBackupsLocked];
}

- (void)_publishStatusChangeLocked
{
    self.latestStatusSnapshot = [self _statusSnapshotLocked];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ICDailyBackupManagerStatusDidChangeNotification object:self];
    });
}

- (void)_createBackupLockedWithReason:(NSString*)reason
                                force:(BOOL)force
                           completion:(void (^)(BOOL success, NSError* _Nullable error))completion
{
    [self _reloadBackupsLocked];

    if (!force) {
        NSDictionary* latestBackup = [self.cachedBackups firstObject];
        NSDate* latestDate = latestBackup[@"date"];
        if ([latestDate isKindOfClass:[NSDate class]] &&
            [[NSCalendar currentCalendar] isDate:latestDate inSameDayAsDate:[NSDate date]]) {
            [self _complete:completion success:YES error:nil];
            return;
        }
    }

    if (self.backupInProgress) {
        NSError* busyError = ICDailyBackupError(1020, @"Backup already in progress.", nil);
        [self _complete:completion success:NO error:busyError];
        return;
    }

    self.backupInProgress = YES;
    self.lastErrorDescription = nil;
    [self _publishStatusChangeLocked];

    __block BOOL protectedDataAvailable = YES;
    ICDailyBackupPerformOnMainThreadSync(^{
        UIApplication* application = [UIApplication sharedApplication];
        if ([application respondsToSelector:@selector(isProtectedDataAvailable)]) {
            protectedDataAvailable = application.protectedDataAvailable;
        }
    });

    if (!protectedDataAvailable) {
        self.backupInProgress = NO;
        self.lastErrorDescription = nil;
        [self _publishStatusChangeLocked];
        [self _complete:completion success:YES error:nil];
        return;
    }

    NSError* backupError = nil;
    NSFileManager* fman = [NSFileManager defaultManager];
    NSDate* now = [NSDate date];
    NSString* backupRootPath = [self _backupRootPathLocked];
    NSString* backupIdentifier = nil;
    NSString* finalBackupPath = nil;
    NSString* tempBackupPath = nil;
    NSString* databasePath = nil;
    NSDictionary* defaultsDomain = nil;

    do {
        if (backupRootPath.length == 0) {
            backupError = ICDailyBackupError(1021, @"Could not create backup directory.", nil);
            break;
        }

        backupIdentifier = [self _backupIdentifierForDateLocked:now];
        finalBackupPath = [backupRootPath stringByAppendingPathComponent:backupIdentifier];
        tempBackupPath = [backupRootPath stringByAppendingPathComponent:[NSString stringWithFormat:@"tmp-%@", backupIdentifier]];

        [fman removeItemAtPath:tempBackupPath error:nil];

        NSError* folderError = nil;
        if (![fman createDirectoryAtPath:tempBackupPath withIntermediateDirectories:YES attributes:nil error:&folderError]) {
            backupError = ICDailyBackupError(1022, @"Could not create temporary backup folder.", folderError);
            break;
        }

        NSPersistentStoreCoordinator* coordinator = DMANAGER.storeCoordinator;
        NSPersistentStore* persistentStore = [[coordinator persistentStores] firstObject];
        databasePath = [persistentStore.URL path];
        if (databasePath.length == 0) {
            databasePath = [[DMANAGER databaseURL] path];
        }
        NSString* appDomain = [[NSBundle mainBundle] bundleIdentifier];
        defaultsDomain = [[NSUserDefaults standardUserDefaults] persistentDomainForName:appDomain] ?: @{};

        if (databasePath.length == 0) {
            backupError = ICDailyBackupError(1028, @"Could not determine database path for backup.", nil);
            break;
        }
        if (![fman fileExistsAtPath:databasePath]) {
            backupError = ICDailyBackupError(1042, [NSString stringWithFormat:@"Live database file not found at %@", databasePath], nil);
            break;
        }

        NSString* databaseSnapshotPath = [tempBackupPath stringByAppendingPathComponent:kICDailyBackupSnapshotSQLiteFileName];
        backupError = ICDailyBackupCopySQLiteDatabase(databasePath, databaseSnapshotPath);
        if (backupError) {
            break;
        }

        backupError = ICDailyBackupValidateSQLiteDatabase(databaseSnapshotPath);
        if (backupError) {
            break;
        }

        NSDictionary* sanitizedDefaults = [defaultsDomain isKindOfClass:[NSDictionary class]] ? defaultsDomain : @{};
        if (![NSPropertyListSerialization propertyList:sanitizedDefaults isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
            backupError = ICDailyBackupError(1029, @"Settings snapshot contains non-property-list values.", nil);
            break;
        }

        NSString* defaultsSnapshotPath = [tempBackupPath stringByAppendingPathComponent:kICDailyBackupDefaultsFileName];
        if (![sanitizedDefaults writeToFile:defaultsSnapshotPath atomically:YES]) {
            backupError = ICDailyBackupError(1023, @"Could not write settings snapshot.", nil);
            break;
        }

        NSDictionary* info = @{
            @"backupID": backupIdentifier,
            @"createdAt": now,
            @"reason": reason ?: @"scheduled",
            @"retentionDays": @(kICDailyBackupRetentionDays),
            @"databaseFile": kICDailyBackupSnapshotSQLiteFileName,
            @"defaultsFile": kICDailyBackupDefaultsFileName,
            @"appVersion": [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] ?: @"",
            @"buildNumber": [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] ?: @"",
            @"deviceName": [UIDevice currentDevice].name ?: @""
        };

        NSString* infoPath = [tempBackupPath stringByAppendingPathComponent:kICDailyBackupInfoFileName];
        if (![info writeToFile:infoPath atomically:YES]) {
            backupError = ICDailyBackupError(1025, @"Could not write backup metadata.", nil);
            break;
        }

        if ([fman fileExistsAtPath:finalBackupPath]) {
            NSError* removeExistingError = nil;
            if (![fman removeItemAtPath:finalBackupPath error:&removeExistingError]) {
                backupError = ICDailyBackupError(1026, @"Could not replace existing backup folder.", removeExistingError);
                break;
            }
        }

        NSError* moveError = nil;
        if (![fman moveItemAtPath:tempBackupPath toPath:finalBackupPath error:&moveError]) {
            backupError = ICDailyBackupError(1027, @"Could not finalize backup snapshot.", moveError);
            break;
        }
        AddSkipBackupAttributeToFile(finalBackupPath);

        [self _pruneBackupsLocked];
        self.lastSuccessfulBackupDate = now;
        self.lastErrorDescription = nil;
        DebugLog(@"Daily backup created: %@", backupIdentifier);
    } while (NO);

    if (tempBackupPath.length > 0) {
        [fman removeItemAtPath:tempBackupPath error:nil];
    }

    if (backupError) {
        self.lastErrorDescription = backupError.localizedDescription ?: @"Daily backup failed.";
        ErrLog(@"Daily backup failed: %@", backupError);
    }

    [self _reloadBackupsLocked];
    self.backupInProgress = NO;
    [self _publishStatusChangeLocked];
    [self _complete:completion success:(backupError == nil) error:backupError];
}

- (void)_applyPendingRestoreIfNeededLocked
{
    NSString* pendingPath = [self _pendingRestoreRequestPathLocked];
    if (pendingPath.length == 0) {
        return;
    }

    NSFileManager* fman = [NSFileManager defaultManager];
    NSDictionary* request = [NSDictionary dictionaryWithContentsOfFile:pendingPath];
    NSString* backupID = request[@"backupID"];
    if (backupID.length == 0) {
        [fman removeItemAtPath:pendingPath error:nil];
        return;
    }

    NSError* restoreError = nil;
    BOOL restoreSucceeded = NO;

    NSString* backupRoot = [self _backupRootPathLocked];
    NSString* backupPath = [backupRoot stringByAppendingPathComponent:backupID];
    NSString* backupSQLitePath = [backupPath stringByAppendingPathComponent:kICDailyBackupSnapshotSQLiteFileName];
    NSString* backupDefaultsPath = [backupPath stringByAppendingPathComponent:kICDailyBackupDefaultsFileName];

    NSString* dataPath = [self _dataPathLocked];
    NSString* databasePath = [dataPath stringByAppendingPathComponent:[DatabaseManager currentDataStoreFilename]];
    NSString* walPath = [databasePath stringByAppendingString:@"-wal"];
    NSString* shmPath = [databasePath stringByAppendingString:@"-shm"];

    NSString* stageDatabasePath = [databasePath stringByAppendingString:@".restore-staging"];
    NSString* rollbackDatabasePath = [databasePath stringByAppendingString:@".restore-rollback"];
    NSString* rollbackWalPath = [walPath stringByAppendingString:@".restore-rollback"];
    NSString* rollbackShmPath = [shmPath stringByAppendingString:@".restore-rollback"];

    BOOL movedLiveDatabase = NO;
    BOOL movedLiveWal = NO;
    BOOL movedLiveShm = NO;
    BOOL appliedDefaults = NO;

    NSString* appDomain = [[NSBundle mainBundle] bundleIdentifier];
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary* originalDefaultsDomain = @{};
    NSDictionary* defaultsDomain = nil;

    [fman removeItemAtPath:stageDatabasePath error:nil];
    [fman removeItemAtPath:rollbackDatabasePath error:nil];
    [fman removeItemAtPath:rollbackWalPath error:nil];
    [fman removeItemAtPath:rollbackShmPath error:nil];

    do {
        if (![fman fileExistsAtPath:backupSQLitePath] || ![fman fileExistsAtPath:backupDefaultsPath]) {
            restoreError = ICDailyBackupError(1030, @"Pending restore backup is missing required files.", nil);
            break;
        }

        restoreError = ICDailyBackupValidateSQLiteDatabase(backupSQLitePath);
        if (restoreError) {
            break;
        }

        defaultsDomain = [NSDictionary dictionaryWithContentsOfFile:backupDefaultsPath];
        if (![defaultsDomain isKindOfClass:[NSDictionary class]]) {
            restoreError = ICDailyBackupError(1034, @"Backup settings snapshot is unreadable.", nil);
            break;
        }
        if (![NSPropertyListSerialization propertyList:defaultsDomain isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
            restoreError = ICDailyBackupError(1035, @"Backup settings snapshot contains invalid values.", nil);
            break;
        }

        if (appDomain.length == 0) {
            restoreError = ICDailyBackupError(1033, @"Could not determine app domain for restoring settings.", nil);
            break;
        }
        originalDefaultsDomain = [defaults persistentDomainForName:appDomain] ?: @{};

        NSError* stageDatabaseCopyError = nil;
        if (![fman copyItemAtPath:backupSQLitePath toPath:stageDatabasePath error:&stageDatabaseCopyError]) {
            restoreError = ICDailyBackupError(1031, @"Could not stage database restore file.", stageDatabaseCopyError);
            break;
        }

        if ([fman fileExistsAtPath:databasePath]) {
            NSError* moveLiveDatabaseError = nil;
            if (![fman moveItemAtPath:databasePath toPath:rollbackDatabasePath error:&moveLiveDatabaseError]) {
                restoreError = ICDailyBackupError(1036, @"Could not move current database to rollback location.", moveLiveDatabaseError);
                break;
            }
            movedLiveDatabase = YES;
        }

        if ([fman fileExistsAtPath:walPath]) {
            NSError* moveWalError = nil;
            if (![fman moveItemAtPath:walPath toPath:rollbackWalPath error:&moveWalError]) {
                restoreError = ICDailyBackupError(1037, @"Could not move current WAL file to rollback location.", moveWalError);
                break;
            }
            movedLiveWal = YES;
        }

        if ([fman fileExistsAtPath:shmPath]) {
            NSError* moveShmError = nil;
            if (![fman moveItemAtPath:shmPath toPath:rollbackShmPath error:&moveShmError]) {
                restoreError = ICDailyBackupError(1038, @"Could not move current SHM file to rollback location.", moveShmError);
                break;
            }
            movedLiveShm = YES;
        }

        NSError* activateDatabaseError = nil;
        if (![fman moveItemAtPath:stageDatabasePath toPath:databasePath error:&activateDatabaseError]) {
            restoreError = ICDailyBackupError(1039, @"Could not activate restored database.", activateDatabaseError);
            break;
        }

        [defaults removePersistentDomainForName:appDomain];
        [defaults setPersistentDomain:defaultsDomain forName:appDomain];
        [defaults synchronize];
        appliedDefaults = YES;

        restoreSucceeded = YES;
    } while (NO);

    if (!restoreSucceeded) {
        if (appliedDefaults) {
            [defaults removePersistentDomainForName:appDomain];
            [defaults setPersistentDomain:originalDefaultsDomain forName:appDomain];
            [defaults synchronize];
        }

        [fman removeItemAtPath:databasePath error:nil];
        [fman removeItemAtPath:walPath error:nil];
        [fman removeItemAtPath:shmPath error:nil];

        if (movedLiveDatabase && [fman fileExistsAtPath:rollbackDatabasePath]) {
            [fman moveItemAtPath:rollbackDatabasePath toPath:databasePath error:nil];
        }
        if (movedLiveWal && [fman fileExistsAtPath:rollbackWalPath]) {
            [fman moveItemAtPath:rollbackWalPath toPath:walPath error:nil];
        }
        if (movedLiveShm && [fman fileExistsAtPath:rollbackShmPath]) {
            [fman moveItemAtPath:rollbackShmPath toPath:shmPath error:nil];
        }
    } else {
        [fman removeItemAtPath:rollbackDatabasePath error:nil];
        [fman removeItemAtPath:rollbackWalPath error:nil];
        [fman removeItemAtPath:rollbackShmPath error:nil];
        self.lastErrorDescription = nil;
        DebugLog(@"Applied pending restore from daily backup: %@", backupID);
    }

    [fman removeItemAtPath:stageDatabasePath error:nil];
    [fman removeItemAtPath:pendingPath error:nil];

    if (restoreError) {
        self.lastErrorDescription = restoreError.localizedDescription ?: @"Backup restore failed.";
        ErrLog(@"Pending restore failed: %@", restoreError);
    }

    [self _reloadBackupsLocked];
    [self _publishStatusChangeLocked];
}

- (void)_complete:(void (^ _Nullable)(BOOL success, NSError* _Nullable error))completion
          success:(BOOL)success
            error:(NSError* _Nullable)error
{
    if (!completion) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        completion(success, error);
    });
}

@end

@implementation Application {
@protected
	NSInteger	_networkActivityRetainCount;
	BOOL		_errorShown;
    BOOL        _sendTouchNotifications;
    double     lastAccelX;
    double     lastAccelY;
    double     lastAccelZ;
    UIInterfaceOrientation orientationLast;
}

- (id) init
{
	if ((self = [super init]))
	{
		_mainQueue = [[NSOperationQueue alloc] init];

        _reachability = [Reachability reachabilityForInternetConnection];
        [_reachability startNotifier];

#if !TARGET_OS_SIMULATOR
        _telephonyInfo = [CTTelephonyNetworkInfo new];
#endif

        [self updateNetworkAccessTechnology];

#if !TARGET_OS_SIMULATOR
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_networkAccessTechnologyDidChange:) name:CTServiceRadioAccessTechnologyDidChangeNotification object:nil];
#endif

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_networkAccessTechnologyDidChange:) name:kReachabilityChangedNotification object:nil];
        [self deviceMotionDetection];
        [self volumeChangeNotification];
	}
	return self;
}


- (GTMLogger*) _initializeLoggerAtPath:(NSString*)path
{
    
#ifdef DEBUG
    
    @try {
        GTMLogBasicFormatter *formatter = [[GTMLogBasicFormatter alloc] init];
        
        GTMLogger *stdoutLogger =
        [GTMLogger loggerWithWriter:[NSFileHandle fileHandleWithStandardOutput]
                     formatter:formatter
                        filter:[[GTMLogMaximumLevelFilter alloc] initWithMaximumLevel:kGTMLoggerLevelInfo]];
        
        GTMLogger *stderrLogger =
        [GTMLogger loggerWithWriter:[NSFileHandle fileHandleWithStandardError]
                     formatter:formatter
                        filter:[[GTMLogMininumLevelFilter alloc] initWithMinimumLevel:kGTMLoggerLevelError]];
        
        
        GTMLogger* fileLogger = [GTMLogger standardLoggerWithPath:path];
        [fileLogger setFilter:[[GTMLogNoFilter alloc] init]];
        
        NSURL* url = [NSURL fileURLWithPath:path];
        NSError *error = nil;
        [url setResourceValue:@(YES) forKey: NSURLIsExcludedFromBackupKey error:&error];
        
        GTMLogger *compositeWriter =
        [GTMLogger loggerWithWriter:@[stdoutLogger, stderrLogger, fileLogger]
                          formatter:formatter
                             filter:[[GTMLogNoFilter alloc] init]];
        
        GTMLogger *outerLogger = [GTMLogger standardLogger];
        [outerLogger setWriter:compositeWriter];
        return outerLogger;
    }
    @catch (id e) {
        // Ignored
    }
    
    
    GTMLogger* logger = [GTMLogger standardLoggerWithStdoutAndStderr];
    return logger;
#else
    GTMLogger* logger = [GTMLogger standardLoggerWithPath:path];
    [logger setFilter:[[GTMLogLevelFilter alloc] init]];
    
    NSURL* url = [NSURL fileURLWithPath:path];
    
    NSError *error = nil;
    [url setResourceValue:@(YES) forKey: NSURLIsExcludedFromBackupKey error:&error];
    
    return logger;
#endif
}

- (void) initializeLoggers
{
    NSString* appLogsPath = [[NSBundle pathToLogsDirectory] stringByAppendingPathComponent:@"Application.Log"];
    _applicationLogger = [self _initializeLoggerAtPath:appLogsPath];
}

#pragma mark - Network Info

- (void) _networkAccessTechnologyDidChange:(NSNotification*)note
{
    [self updateNetworkAccessTechnology];
}

- (void) updateNetworkAccessTechnology
{
    if (self.reachability.currentReachabilityStatus == ReachableViaWiFi) {
        self.networkAccessTechnology = kICNetworkAccessTechnlogyWIFI;
    }
    else if (self.reachability.currentReachabilityStatus == NotReachable) {
        self.networkAccessTechnology = kICNetworkAccessTechnlogyNone;
    }
    else
    {
        // Use serviceCurrentRadioAccessTechnology (returns dictionary of service identifier -> technology)
        NSDictionary<NSString*, NSString*> *radioAccessTechnologies = self.telephonyInfo.serviceCurrentRadioAccessTechnology;
        NSString* currentRadioAccessTechnology = radioAccessTechnologies.allValues.firstObject;
        if ([currentRadioAccessTechnology isEqualToString:CTRadioAccessTechnologyGPRS]) {
            self.networkAccessTechnology = kICNetworkAccessTechnlogyGPRS;
        }
        else if ([currentRadioAccessTechnology isEqualToString:CTRadioAccessTechnologyEdge]) {
            self.networkAccessTechnology = kICNetworkAccessTechnlogyEDGE;
        }
        else if ([currentRadioAccessTechnology isEqualToString:CTRadioAccessTechnologyLTE]) {
            self.networkAccessTechnology = kICNetworkAccessTechnlogyLTE;
        }
        else {
            self.networkAccessTechnology = kICNetworkAccessTechnlogy3G;
        }
    }
    
    
}

- (void) retainNetworkActivity
{
	dispatch_async(dispatch_get_main_queue(), ^{
        if (_networkActivityRetainCount == 0) {
            // networkActivityIndicatorVisible is deprecated in iOS 13 with no replacement
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            self.networkActivityIndicatorVisible = YES;
#pragma clang diagnostic pop
        }
        _networkActivityRetainCount++;
    });
}

- (void) releaseNetworkActivity
{
	dispatch_async(dispatch_get_main_queue(), ^{
        _networkActivityRetainCount = MAX(_networkActivityRetainCount-1,0);

        if (_networkActivityRetainCount == 0) {
            // networkActivityIndicatorVisible is deprecated in iOS 13 with no replacement
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            self.networkActivityIndicatorVisible = NO;
#pragma clang diagnostic pop
        }
    });
}

#pragma mark - Global Error Handling

- (void) handleNoInternetConnection
{
    [self showBackgroundErrorWithTitle:@"No internet connection.".ls message:@"Please make sure you are connected to a cellular or WiFi network.".ls];
}

- (void) showBackgroundErrorWithTitle:(NSString*)title message:(NSString*)message
{
    [self showBackgroundErrorWithTitle:title message:message duration:4.0f];
}

- (void) showBackgroundErrorWithTitle:(NSString*)title message:(NSString*)message duration:(NSTimeInterval)duration
{
    PlaySoundFile(@"Tink", NO);
    
    if (self.backgroundErrorSheet) {
        self.backgroundErrorSheet.title = title;
        self.backgroundErrorSheet.message = message;
        [self.backgroundErrorSheet extendDismissingAfterDelay:duration];
        return;
    }
    
    self.backgroundErrorSheet = [ICErrorSheet sheet];
    self.backgroundErrorSheet.title = title;
    self.backgroundErrorSheet.message = message;
    
    __weak Application* weakSelf = self;
    [self.backgroundErrorSheet showAnimated:YES dismissAfterDelay:duration completion:^{
        weakSelf.backgroundErrorSheet = nil;
    }];
}


#pragma mark -


- (NSString*) errorLog
{
    NSString* logsPath = [[NSBundle pathToLogsDirectory] stringByAppendingPathComponent:@"Application.Log"];
    return [[NSString alloc] initWithContentsOfFile:logsPath encoding:NSUTF8StringEncoding error:nil];
}

-(void)sendEvent:(UIEvent *)event
{
    [super sendEvent:event];
    
    if (!myidleTimer)
    {
        [self resetIdleTimer];
    }
    
    NSSet *allTouches = [event allTouches];
    if ([allTouches count] > 0)
    {
        UITouchPhase phase = ((UITouch *)[allTouches anyObject]).phase;
        if (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved)
        {
            [self resetIdleTimer];
        }
        
    }
}
//as labeled...reset the timer
-(void)resetIdleTimer
{
    BOOL isTouchActive = [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep];
    BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
    if (isIntelligentTimerActive){
        if (isTouchActive){
            if (myidleTimer)
            {
                [myidleTimer invalidate];
            }
            //convert the wait period into minutes rather than seconds
            NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
            if ([PlaybackManager playbackManager].isPodcastPlaying)
            {
                if (sleepTimer > 0)
                {
                    [AudioSession sharedAudioSession].timerValue = sleepTimer;
                    int timeout = (int)sleepTimer * 60;
                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                }
                else if (lastSleepTimer > 0 && [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
                {
                    [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                    int timeout = (int)lastSleepTimer * 60;
                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                }
            }
        }
    }
}

-(void)idleTimerExceeded
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kApplicationDidTimeoutNotification object:nil];
}

-(void)deviceMotionDetection
{
    self.motionManager = [[CMMotionManager alloc] init];
    self.motionManager.accelerometerUpdateInterval = 0.3;

    if ([self.motionManager isAccelerometerAvailable])
    {
        NSOperationQueue *queue = [[NSOperationQueue alloc] init];
        [self.motionManager startAccelerometerUpdatesToQueue:queue withHandler:^(CMAccelerometerData *accelerometerData, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CMAcceleration acc = accelerometerData.acceleration;
                double threshold = [USER_DEFAULTS doubleForKey:DeviceMovementSensitivity];
                if (threshold <= 0) threshold = 0.004;
                if (fabs(acc.x - self->lastAccelX) > threshold ||
                    fabs(acc.y - self->lastAccelY) > threshold ||
                    fabs(acc.z - self->lastAccelZ) > threshold)
                {
                    self->lastAccelX = acc.x;
                    self->lastAccelY = acc.y;
                    self->lastAccelZ = acc.z;
                    [[NSNotificationCenter defaultCenter] postNotificationName:ApplicationDidDetectMotionNotification object:nil];
                    BOOL isMotionActive = [USER_DEFAULTS boolForKey:DeviceMovementIntelligentSleep];
                    BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];

                    if (isIntelligentTimerActive){
                        if (isMotionActive){
                            if ([PlaybackManager playbackManager].isPodcastPlaying)
                            {
                                if (myidleTimer)
                                {
                                    [myidleTimer invalidate];
                                }
                                NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
                                [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
                                NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                                
                                if (sleepTimer > 0)
                                {
                                    [AudioSession sharedAudioSession].timerValue = sleepTimer;
                                    int timeout = (int)sleepTimer * 60;
                                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                                }
                                else if (lastSleepTimer > 0 && [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
                                {
                                    [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                                    int timeout = (int)lastSleepTimer * 60;
                                    myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                                }
                            }
                        }
                    }
                }
            });
        }];
    }
}


-(void)volumeChangeNotification
{
    AVAudioSession* audioSession = [AVAudioSession sharedInstance];
    //[audioSession setActive:YES error:nil];
    [audioSession addObserver:self forKeyPath:@"outputVolume" options:0 context:nil];
    //[[AudioSession sharedAudioSession] addObserver:self forKeyPath:@"outputVolume" options:0 context:nil];
}

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    
    if ([keyPath isEqual:@"outputVolume"]) {
        BOOL isVolumeActive = [USER_DEFAULTS boolForKey:VolumeChangeIntelligentSleep];
        BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
        if (isIntelligentTimerActive){
            if (isVolumeActive){
                if ([PlaybackManager playbackManager].isPodcastPlaying)
                {
                    if (myidleTimer)
                    {
                        [myidleTimer invalidate];
                    }
                    //convert the wait period into minutes rather than seconds
                    NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
                    [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
                    NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                    if (sleepTimer > 0)
                    {
                        [AudioSession sharedAudioSession].timerValue = sleepTimer;
                        int timeout = (int)sleepTimer * 60;
                        myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                    }
                    else if (lastSleepTimer > 0 && [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
                    {
                        [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                        int timeout = (int)lastSleepTimer * 60;
                        myidleTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(idleTimerExceeded) userInfo:nil repeats:NO];
                    }
                }
            }
        }
    }
}

#pragma mark - Scene-aware Key Window

- (UIWindow *)ic_keyWindow
{
    // Only UIWindowScene instances have UIWindow collections. CarPlay template scenes do not.
    for (UIScene *scene in self.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene* windowScene = (UIWindowScene*)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in windowScene.windows) {
                if (window.isKeyWindow) {
                    return window;
                }
            }
        }
    }

    // Fallback: return first window from any foreground UIWindowScene.
    for (UIScene *scene in self.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }

        UIWindowScene* windowScene = (UIWindowScene*)scene;
        if (windowScene.activationState == UISceneActivationStateForegroundActive ||
            windowScene.activationState == UISceneActivationStateForegroundInactive) {
            if (windowScene.windows.count > 0) {
                return windowScene.windows.firstObject;
            }
        }
    }
    return nil;
}

@end
