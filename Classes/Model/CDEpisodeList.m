//
//  CDEpisodeList.m
//  Instacast
//
//  Created by Martin Hering on 18.08.14.
//
//

NSString* kEpisodeIconUnplayed = @"List Unplayed";

#import "CDEpisodeList.h"
#import "ICFTSController.h"

@interface CDEpisodeList ()
@property (nonatomic) NSNumber* cachedEpisodesCount;
// Completions waiting for the in-flight background count (main thread only). During a
// sync/refresh every save invalidates the cached count and badge/widgets/UI all re-ask
// at once; running one throwaway background context per request put several parallel
// counts on the store at the same time and crashed under load (use-after-free, iPad
// SIGSEGV 10.06.2026). Only one count per list runs at a time — late callers attach here.
@property (nonatomic, strong) NSMutableArray<void (^)(NSUInteger)>* pendingCountCompletions;
@end

@implementation CDEpisodeList {
    BOOL _observing;
    NSNumber* _cachedEpisodesCount;
}

// NSManagedObject subclasses get NO automatic property synthesis
// (NS_REQUIRES_PROPERTY_DEFINITIONS) — without this line the accessors don't exist at
// runtime and calling them throws "unrecognized selector".
@synthesize pendingCountCompletions = _pendingCountCompletions;


@dynamic icon;
@dynamic query;

@dynamic audio;
@dynamic video;

@dynamic downloaded;
@dynamic downloading;
@dynamic notDownloaded;

@dynamic starred;
@dynamic notStarred;

@dynamic unplayed;
@dynamic unfinished;
@dynamic played;

@dynamic orderBy;
@dynamic groupByPodcast;
@dynamic descending;
@dynamic continuousPlayback;

@dynamic includedFeeds;
@dynamic episodes;
@dynamic cachedEpisodesCount;



- (void) setObserving:(BOOL)observing
{
    if (!_observing && observing)
    {
        _observing = YES;
    }
    else if (_observing && !observing)
    {
        _observing = NO;
    }
}


- (void) awakeFromFetch
{
    [super awakeFromFetch];
    
    if (self.managedObjectContext == DMANAGER.objectContext) {
        [self setObserving:YES];
    }
    if ([self.orderBy isEqualToString:@"manuel"]) {
        self.orderBy = @"pubDate";
    }
}

- (void) awakeFromInsert
{
    [super awakeFromInsert];

    // Match the model's defaultValueString="YES"
    self.continuousPlayback = YES;

    if (self.managedObjectContext == DMANAGER.objectContext) {
        [self setObserving:YES];
    }
}

- (void) willTurnIntoFault
{
    if (self.managedObjectContext == DMANAGER.objectContext) {
        [self setObserving:NO];
    }
}

- (NSInteger) playbackTime
{
    return 0;
}

- (IC_IMAGE*) image
{
#if TARGET_OS_IPHONE
    // Try SF Symbol first
    UIImage* sfImage = [UIImage systemImageNamed:self.icon];
    if (sfImage) return [sfImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    // Fallback: named image from assets
    UIImage* image = [[UIImage imageNamed:self.icon] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return (image) ? image : [super image];
#else
    return [NSImage imageNamed:self.icon];
#endif
}

- (NSArray*) sortedEpisodes
{
    return [self _sortedEpisodesWithFetchLimit:0];
}

- (NSArray*) sortedEpisodesWithLimit:(NSUInteger)limit
{
    NSArray* result = [self _sortedEpisodesWithFetchLimit:limit];
    if (limit > 0 && result.count > limit) {
        return [result subarrayWithRange:NSMakeRange(0, limit)];
    }
    return result;
}

- (BOOL) evaluatesEpisodeNow:(CDEpisode*)episode
{
    if (!episode) {
        return NO;
    }
    // Mirror _sortedEpisodesWithFetchLimit: a list with explicit members is keyed by the
    // relationship only; otherwise the live filter predicate decides.
    if ([[self explicitEpisodeRelationshipObjectsWithFetchLimit:1] count] > 0) {
        return [episode.episodeLists containsObject:self];
    }
    return [[self _episodesMainPredicate] evaluateWithObject:episode];
}

// The store predicate of this smart list — shared by the episode fetch and the cheap
// SQL count below so both always agree.
- (NSPredicate*) _episodesMainPredicate
{
    NSMutableArray* subPredicates = [[NSMutableArray alloc] init];
    [subPredicates addObject:[NSPredicate predicateWithFormat:@"feed.subscribed == YES AND archived == NO"]];

    if (!self.audio) {
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"video == YES"]];
    }

    if (!self.video) {
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"video == NO"]];
    }

    if (!self.unplayed) {
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"consumed == YES OR (consumed == NO AND position > 0)"]];
    }

    if (!self.unfinished) {
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"position == 0"]];
    }

    if (!self.played) {
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"consumed == NO"]];
    }

    if (!self.starred) {
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"starred == NO"]];
    }

    if (!self.notStarred) {
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"starred == YES"]];
    }

    if (!self.downloaded || !self.notDownloaded) {
        // `downloaded` is a TRANSIENT episode attribute (no store column) — a SQL
        // predicate on it matches nothing, which left the "Downloaded" list empty
        // although the files were all there. Filter against the cache manager's
        // object hashes instead.
        NSArray* cachedHashes = [[[CacheManager sharedCacheManager] cachedEpisodes] valueForKey:@"objectHash"];
        if (!self.downloaded) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"NOT (objectHash IN %@)", cachedHashes ?: @[]]];
        } else {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"objectHash IN %@", cachedHashes ?: @[]]];
        }
    }

    if ([self.includedFeeds count] > 0)
    {
        NSMutableArray* includedFeedsSubPredicates = [[NSMutableArray alloc] init];
        for(CDFeed* feed in self.includedFeeds) {
            [includedFeedsSubPredicates addObject:[NSPredicate predicateWithFormat:@"feed == %@", feed]];
        }

        [subPredicates addObject:[NSCompoundPredicate orPredicateWithSubpredicates:includedFeedsSubPredicates]];
    }

    if ([self.query length] > 0) {
        NSSet* episodeGuids = [DMANAGER.ftsController episodeUIDsForSearchTerm:self.query];
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"guid IN %@", episodeGuids]];
    }

    return [NSCompoundPredicate andPredicateWithSubpredicates:subPredicates];
}

// Counts via SQL instead of materializing the episodes. The background-context guard
// in numberOfEpisodes used to fall back to `[[self sortedEpisodes] count]` — the widget
// exporter calls that for every list on every Core Data save, and the resulting
// full two-stage fetches over the whole episode table kept a background thread above
// 80% CPU until the system killed the app (cpu_resource_fatal, 12.06.).
- (NSUInteger) _countEpisodesViaStore
{
    NSManagedObjectContext* context = self.managedObjectContext;
    if (!context) {
        return 0;
    }

    NSFetchRequest* explicitRequest = [[NSFetchRequest alloc] init];
    explicitRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    explicitRequest.includesSubentities = NO;
    explicitRequest.predicate = [NSPredicate predicateWithFormat:@"episodeLists CONTAINS %@", self];
    NSUInteger explicitCount = [context countForFetchRequest:explicitRequest error:NULL];
    if (explicitCount != NSNotFound && explicitCount > 0) {
        return explicitCount;
    }

    NSFetchRequest* request = [[NSFetchRequest alloc] init];
    request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    request.includesSubentities = NO;
    request.predicate = [self _episodesMainPredicate];
    NSUInteger count = [context countForFetchRequest:request error:NULL];
    return (count == NSNotFound) ? 0 : count;
}

- (NSArray*) _sortedEpisodesWithFetchLimit:(NSUInteger)fetchLimit
{
    NSArray* explicitEpisodes = [self explicitEpisodeRelationshipObjectsWithFetchLimit:fetchLimit];
    if ([explicitEpisodes count] > 0) {
        return explicitEpisodes;
    }


    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
    fetchRequest.predicate = [self _episodesMainPredicate];
    fetchRequest.includesSubentities = NO;
    fetchRequest.resultType = NSDictionaryResultType;
    
    NSMutableArray* fetchedProperties = [[NSMutableArray alloc] initWithObjects:@"objectHash", nil];
    if ([self.orderBy isEqualToString:@"timeLeft"]) {
        [fetchedProperties addObject:@"duration"];
        [fetchedProperties addObject:@"position"];
    } else if (self.orderBy) {
        [fetchedProperties addObject:self.orderBy];
    }
    
    
    if (self.groupByPodcast) {
        [fetchedProperties addObject:@"feed.rank"];
    }
    fetchRequest.propertiesToFetch = fetchedProperties;
    
    
    
    NSMutableArray* sortDescriptors = [[NSMutableArray alloc] init];
    if (self.groupByPodcast) {
        [sortDescriptors addObject:[[NSSortDescriptor alloc] initWithKey:@"feed.rank" ascending:YES]];
    }
    if (self.orderBy && ![self.orderBy isEqualToString:@"timeLeft"]) {
        [sortDescriptors addObject:[[NSSortDescriptor alloc] initWithKey:self.orderBy ascending:!self.descending]];
    }
    if ([sortDescriptors count] > 0) {
        fetchRequest.sortDescriptors = sortDescriptors;
    }

    if (fetchLimit > 0) {
        fetchRequest.fetchLimit = fetchLimit;
    }

    NSError* error;
    NSArray* objects = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
    
    // sort manually
    if ([self.orderBy isEqualToString:@"timeLeft"]) {
        objects = [objects sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* obj1, NSDictionary* obj2) {
            NSInteger timeLeft1 = [obj1[@"duration"] integerValue] - [obj1[@"position"] integerValue];
            NSInteger timeLeft2 = [obj2[@"duration"] integerValue] - [obj2[@"position"] integerValue];
            
            if (timeLeft1 == timeLeft2) {
                return NSOrderedSame;
            }
            
            if (self.descending) {
                return (timeLeft1 > timeLeft2) ? NSOrderedAscending : NSOrderedDescending;
            }
            return (timeLeft1 < timeLeft2) ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    

    NSArray* objectHashes = [objects valueForKey:@"objectHash"];
    NSFetchRequest* fetchRequest2 = [[NSFetchRequest alloc] init];
    fetchRequest2.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
    fetchRequest2.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", objectHashes];
    fetchRequest2.includesSubentities = NO;
    fetchRequest2.sortDescriptors = sortDescriptors;

    
    NSError* error2;
    NSArray* stage3Objects = [self.managedObjectContext executeFetchRequest:fetchRequest2 error:&error2];
    
    if ([self.orderBy isEqualToString:@"timeLeft"]) {
        stage3Objects = [stage3Objects sortedArrayUsingComparator:^NSComparisonResult(CDEpisode* obj1, CDEpisode* obj2) {
            NSInteger timeLeft1 = obj1.duration - obj1.position;
            NSInteger timeLeft2 = obj2.duration - obj2.position;
            
            if (timeLeft1 == timeLeft2) {
                return NSOrderedSame;
            }
            
            if (self.descending) {
                return (timeLeft1 > timeLeft2) ? NSOrderedAscending : NSOrderedDescending;
            }
            return (timeLeft1 < timeLeft2) ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    
    self.cachedEpisodesCount = @(stage3Objects.count);
    return stage3Objects;
}

- (NSArray*)explicitEpisodeRelationshipObjectsWithFetchLimit:(NSUInteger)fetchLimit
{
    NSFetchRequest* request = [[NSFetchRequest alloc] init];
    request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
    request.includesSubentities = NO;
    request.predicate = [NSPredicate predicateWithFormat:@"episodeLists CONTAINS %@", self];
    if (fetchLimit > 0) {
        request.fetchLimit = fetchLimit;
    }

    NSError* error;
    NSArray* episodes = [self.managedObjectContext executeFetchRequest:request error:&error];
    if (error) {
        ErrLog(@"error fetching explicit episode list membership: %@", error);
        return @[];
    }
    return episodes ?: @[];
}


- (NSUInteger) numberOfEpisodes
{
    if (!self.cachedEpisodesCount) {
        // Instances living in a throwaway background context (e.g. the widget exporter's)
        // must NEVER start the deferred async count: it captures self.managedObjectContext,
        // which is deallocated together with the caller — the delayed blocks then message
        // a dangling pointer (both iPad SIGSEGVs of 10.06.2026, triggered on every save
        // during the sync). Count synchronously inside the owning context instead.
        if (self.managedObjectContext != DMANAGER.objectContext) {
            return [self _countEpisodesViaStore];
        }
        [self perform:^(id sender) {
            [self calculateNumberOfEpisodesCompletion:^(NSUInteger numberOfEpisodes) {
            }];
        } afterDelay:0.1];
    }

    return [self.cachedEpisodesCount unsignedIntegerValue];
}

- (void) calculateNumberOfEpisodesCompletion:(void (^)(NSUInteger numberOfEpisodes))completion
{
    if (!completion) {
        return;
    }

    // See numberOfEpisodes: never capture a non-main context in the async machinery.
    if (self.managedObjectContext != DMANAGER.objectContext) {
        completion([self _countEpisodesViaStore]);
        return;
    }
    
    if (self.cachedEpisodesCount) {
        completion([self.cachedEpisodesCount unsignedIntegerValue]);
        return;
    }

    if (!self.pendingCountCompletions) {
        self.pendingCountCompletions = [[NSMutableArray alloc] init];
    }
    [self.pendingCountCompletions addObject:[completion copy]];
    if (self.pendingCountCompletions.count > 1) {
        // A count for this list is already in flight; it serves this completion too.
        return;
    }

    NSManagedObjectContext* mainContext = self.managedObjectContext;
    NSManagedObjectID* selfId = [self objectID];
    __weak CDEpisodeList* weakSelf = self;
    void (^completeOnMainContext)(NSUInteger, BOOL) = ^(NSUInteger count, BOOL updateCache) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (updateCache) {
                NSError* mainError = nil;
                CDEpisodeList* calculatedList = (CDEpisodeList*)[mainContext existingObjectWithID:selfId error:&mainError];
                if (calculatedList && !mainError) {
                    calculatedList.cachedEpisodesCount = @(count);
                }
                else if (mainError) {
                    ErrLog(@"error getting episode list in main context: %@", mainError);
                }
            }

            CDEpisodeList* strongSelf = weakSelf;
            NSArray* completions = [strongSelf.pendingCountCompletions copy];
            [strongSelf.pendingCountCompletions removeAllObjects];
            if (completions.count > 0) {
                for (void (^pendingCompletion)(NSUInteger) in completions) {
                    pendingCompletion(count);
                }
            }
            else {
                // List object went away while counting — still serve the original caller.
                completion(count);
            }
        });
    };

    NSManagedObjectContext* childContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [childContext performBlock:^{

        childContext.persistentStoreCoordinator = DMANAGER.storeCoordinator;

        NSError* error;
        CDEpisodeList* contextSelf = (CDEpisodeList*)[childContext existingObjectWithID:selfId error:&error];
        if (error) {
            ErrLog(@"error getting episode list in child context: %@", error);
            // Drain waiting completions (without caching) so future counts aren't blocked.
            completeOnMainContext(0, NO);
            return;
        }

        NSUInteger explicitEpisodeCount = [contextSelf explicitEpisodeRelationshipCountInContext:childContext episodeList:contextSelf];
        if (explicitEpisodeCount > 0) {
            completeOnMainContext(explicitEpisodeCount, YES);
            return;
        }
        
        NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
        fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:childContext];
        NSMutableArray* subPredicates = [[NSMutableArray alloc] init];
        [subPredicates addObject:[NSPredicate predicateWithFormat:@"feed.subscribed == YES AND archived == NO"]];
        
        if (!contextSelf.audio) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"video == YES"]];
        }
        
        if (!contextSelf.video) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"video == NO"]];
        }
        
        if (!contextSelf.unplayed) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"consumed == YES OR (consumed == NO AND position > 0)"]];
        }
        
        if (!contextSelf.unfinished) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"position == 0"]];
        }
        
        if (!contextSelf.played) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"consumed == NO"]];
        }
        
        if (!contextSelf.starred) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"starred == NO"]];
        }
        
        if (!contextSelf.notStarred) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"starred == YES"]];
        }
        
        if ([contextSelf.includedFeeds count] > 0)
        {
            NSMutableArray* includedFeedsSubPredicates = [[NSMutableArray alloc] init];
            for(CDFeed* feed in contextSelf.includedFeeds) {
                [includedFeedsSubPredicates addObject:[NSPredicate predicateWithFormat:@"feed == %@", feed]];
            }
            
            [subPredicates addObject:[NSCompoundPredicate orPredicateWithSubpredicates:includedFeedsSubPredicates]];
        }
        
        if ([contextSelf.query length] > 0) {
            NSSet* episodeGuids = [DMANAGER.ftsController episodeUIDsForSearchTerm:contextSelf.query];
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"guid IN %@", episodeGuids]];
        }
        
        
        // add filters for order value
        if (contextSelf.orderBy && ![contextSelf.orderBy isEqualToString:@"timeLeft"]) {
            [subPredicates addObject:[NSPredicate predicateWithFormat:@"%K != nil", contextSelf.orderBy]];
        }
        
        // fetch from sql store
        NSPredicate* mainPredicate = [NSCompoundPredicate andPredicateWithSubpredicates:subPredicates];
        
        fetchRequest.predicate = mainPredicate;
        fetchRequest.includesSubentities = NO;
        fetchRequest.resultType = NSDictionaryResultType;
        fetchRequest.propertiesToFetch = @[@"objectHash"];
        
        NSError* fetchError;
        NSArray* objects = [childContext executeFetchRequest:fetchRequest error:&fetchError];
        NSArray* objectHashes = [objects valueForKey:@"objectHash"];
        NSMutableSet* filteredObjectHashes = [[NSMutableSet alloc] initWithArray:objectHashes];
        
        
        // additionally filter for transient properties
        if (!contextSelf.downloaded || !contextSelf.notDownloaded)
        {
            NSArray* cachedEpisodes = [[CacheManager sharedCacheManager] cachedEpisodes];
            
            // filter all out that are downloaded
            if (!contextSelf.downloaded) {
                for(CDEpisode* episode in cachedEpisodes) {
                    [filteredObjectHashes removeObject:episode.objectHash];
                }
            }
            
            //filter all out that are not downloaded
            else if (!contextSelf.notDownloaded)
            {
                NSMutableSet* cachedHashes = [[NSMutableSet alloc] init];
                for(CDEpisode* episode in cachedEpisodes) {
                    [cachedHashes addObject:episode.objectHash];
                }
                
                for(NSString* objectHash in objectHashes) {
                    if (![cachedHashes containsObject:objectHash]) {
                        [filteredObjectHashes removeObject:objectHash];
                    }
                }
            }
        }
        
        
        
        completeOnMainContext([filteredObjectHashes count], YES);

    }];
}

- (NSUInteger)explicitEpisodeRelationshipCountInContext:(NSManagedObjectContext*)context episodeList:(CDEpisodeList*)episodeList
{
    NSFetchRequest* request = [[NSFetchRequest alloc] init];
    request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    request.includesSubentities = NO;
    request.predicate = [NSPredicate predicateWithFormat:@"episodeLists CONTAINS %@", episodeList];

    NSError* error;
    NSUInteger count = [context countForFetchRequest:request error:&error];
    if (count == NSNotFound) {
        ErrLog(@"error counting explicit episode list membership: %@", error);
        return 0;
    }
    return count;
}

- (void) invalidateCaches {
    [self invalidateSortedEpisodes];
    self.cachedEpisodesCount = nil;
}

- (void) invalidateSortedEpisodes
{
    [self willChangeValueForKey:@"sortedEpisodes"];
    self.episodes = nil;
    [self didChangeValueForKey:@"sortedEpisodes"];
}

//- (void) addNumberOfEpisodes:(NSInteger)number
//{
//    if (!self.cachedEpisodesCount) {
//        return;
//    }
//    
//    self.cachedEpisodesCount = @(MAX(0,[self.cachedEpisodesCount integerValue]+number));
//}

- (NSNumber*) cachedEpisodesCount {
    return _cachedEpisodesCount;
}

- (void) setCachedEpisodesCount:(NSNumber *)cachedEpisodesCount
{
    if ([_cachedEpisodesCount integerValue] != [cachedEpisodesCount integerValue]) {
        [self willChangeValueForKey:@"numberOfEpisodes"];
        _cachedEpisodesCount = cachedEpisodesCount;
        [self didChangeValueForKey:@"numberOfEpisodes"];
    }
}
@end
