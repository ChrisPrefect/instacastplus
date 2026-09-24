#!/usr/bin/env python3
"""Run production list counters against SQLite and the app's Core Data model."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "CDEpisodeList.m").read_text()


def method(signature: str) -> str:
    start = SOURCE.index(signature)
    end = SOURCE.index("{", start) + 1
    depth = 1
    while depth:
        if SOURCE[end] == "{":
            depth += 1
        elif SOURCE[end] == "}":
            depth -= 1
        end += 1
    return SOURCE[start:end]


METHODS = "\n".join(method(signature) for signature in (
    "- (NSPredicate*) _episodesMainPredicate",
    "- (NSUInteger) _countEpisodesViaStore",
    "- (void) calculateNumberOfEpisodesCompletion:",
    "- (NSUInteger)explicitEpisodeRelationshipCountInContext:",
))

HARNESS = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#define ErrLog(...) NSLog(__VA_ARGS__)

// Only external services are stubbed; both counters and membership come from production.
@interface FTS : NSObject
- (NSSet *)episodeObjectHashesForSearchTerm:(NSString *)query;
@end
@implementation FTS
- (NSSet *)episodeObjectHashesForSearchTerm:(NSString *)query { return [NSSet set]; }
@end

@interface ProbeDatabase : NSObject
@property(strong) NSPersistentStoreCoordinator *storeCoordinator;
@property(strong) FTS *ftsController;
@end
@implementation ProbeDatabase
@end
static ProbeDatabase *DMANAGER;

@interface CacheManager : NSObject
+ (instancetype)sharedCacheManager;
@property(readonly) NSSet *cachedEpisodeObjectHashes;
@end
@implementation CacheManager
+ (instancetype)sharedCacheManager {
    static CacheManager *instance;
    if (!instance) instance = [self new];
    return instance;
}
- (NSSet *)cachedEpisodeObjectHashes { return [NSSet set]; }
@end

@interface CDEpisodeList : NSManagedObject
@property BOOL audio, video, downloaded, notDownloaded, unplayed, unfinished, played, starred, notStarred;
@property(strong) NSSet *includedFeeds;
@property(strong) NSString *query;
@property(strong) NSString *orderBy;
@property(strong) NSNumber *cachedEpisodesCount;
@property(strong) NSMutableArray<void (^)(NSUInteger)> *pendingCountCompletions;
- (NSPredicate *)_episodesMainPredicate;
- (NSUInteger)_countEpisodesViaStore;
- (void)calculateNumberOfEpisodesCompletion:(void (^)(NSUInteger))completion;
- (NSUInteger)explicitEpisodeRelationshipCountInContext:(NSManagedObjectContext *)context episodeList:(CDEpisodeList *)list;
@end
@implementation CDEpisodeList
@dynamic audio, video, downloaded, notDownloaded, unplayed, unfinished, played, starred, notStarred, includedFeeds, query, orderBy;
@synthesize cachedEpisodesCount, pendingCountCompletions;
PRODUCTION_METHODS
@end

static void insertEpisode(NSManagedObjectContext *context, NSManagedObject *feed,
                          NSString *hash, BOOL dated, BOOL consumed, BOOL archived) {
    NSManagedObject *episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
    [episode setValue:hash forKey:@"objectHash"];
    [episode setValue:feed forKey:@"feed"];
    [episode setValue:@(consumed) forKey:@"consumed"];
    [episode setValue:@(archived) forKey:@"archived"];
    if (dated) {
        NSDate *date = [NSDate dateWithTimeIntervalSinceReferenceDate:1000];
        [episode setValue:date forKey:@"lastPlayed"];
        [episode setValue:date forKey:@"lastDownloaded"];
    }
}

static BOOL check(CDEpisodeList *list, NSString *orderBy, BOOL includePlayed, NSUInteger expected) {
    list.orderBy = orderBy;
    list.played = includePlayed;
    list.cachedEpisodesCount = nil;
    NSError *error = nil;
    if (![list.managedObjectContext save:&error]) {
        NSLog(@"Could not save fixture: %@", error);
        return NO;
    }
    NSUInteger storeCount = [list _countEpisodesViaStore];
    __block BOOL completed = NO;
    __block NSUInteger asyncCount = NSNotFound;
    [list calculateNumberOfEpisodesCompletion:^(NSUInteger count) {
        asyncCount = count;
        completed = YES;
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!completed && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    BOOL success = completed && storeCount == expected && asyncCount == expected;
    if (!success) {
        fprintf(stderr, "%s, includePlayed=%s: expected=%lu, store=%lu, async=%lu, completed=%s\n",
                orderBy.UTF8String, includePlayed ? "YES" : "NO", (unsigned long)expected,
                (unsigned long)storeCount, (unsigned long)asyncCount, completed ? "YES" : "NO");
    }
    return success;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@(argv[1])]];
        for (NSEntityDescription *entity in model.entities) entity.managedObjectClassName = @"NSManagedObject";
        model.entitiesByName[@"EpisodeList"].managedObjectClassName = @"CDEpisodeList";
        DMANAGER = [ProbeDatabase new];
        DMANAGER.storeCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        NSError *error = nil;
        if (![DMANAGER.storeCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
                                                            URL:[NSURL fileURLWithPath:@(argv[2])] options:nil error:&error]) {
            NSLog(@"Could not create fixture store: %@", error);
            return 1;
        }
        NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        context.persistentStoreCoordinator = DMANAGER.storeCoordinator;
        CDEpisodeList *list = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:context];
        NSManagedObject *feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
        [feed setValue:@YES forKey:@"subscribed"];
        NSManagedObject *unsubscribed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
        insertEpisode(context, feed, @"never-played-or-downloaded", NO, NO, NO);
        insertEpisode(context, feed, @"played", YES, YES, NO);
        insertEpisode(context, feed, @"dated-unplayed", YES, NO, NO);
        insertEpisode(context, feed, @"archived", YES, NO, YES);
        insertEpisode(context, unsubscribed, @"unsubscribed", YES, NO, NO);
        NSUInteger failures = 0;
        for (NSString *orderBy in @[@"lastPlayed", @"lastDownloaded", @"duration"]) {
            if (!check(list, orderBy, YES, 3)) failures++;
            if (!check(list, orderBy, NO, 2)) failures++;
        }
        if (failures > 0) return 1;
        puts("Episode-list count membership runtime checks passed");
        return 0;
    }
}
'''.replace("PRODUCTION_METHODS", METHODS)


with tempfile.TemporaryDirectory(prefix="instacast-list-count-membership-") as directory:
    temporary = Path(directory)
    source = temporary / "main.m"
    executable = temporary / "list-count"
    model = temporary / "Model9.mom"
    source.write_text(HARNESS)
    subprocess.run(
        ["xcrun", "momc", str(ROOT / "Resources/Models/Model5.xcdatamodeld/Model9.xcdatamodel"), str(model)],
        cwd=ROOT,
        check=True,
        stdout=subprocess.DEVNULL,
    )
    subprocess.run(
        ["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreData",
         str(source), "-o", str(executable)],
        cwd=ROOT,
        check=True,
    )
    subprocess.run([str(executable), str(model), str(temporary / "store.sqlite")], cwd=ROOT, check=True)
