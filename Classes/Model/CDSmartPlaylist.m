//
//  CDSmartPlaylist.m
//  Instacast
//
//  Created by Martin Hering on 09.08.12.
//
//

#import "CDSmartPlaylist.h"


NSString* kSmartListTypeUnplayed = @"unplayed";
NSString* kSmartListTypeStarred = @"starred";
NSString* kSmartListTypeDownload = @"downloaded";
NSString* kSmartListTypeMostRecent = @"recent";
NSString* kSmartListTypePartiallyPlayed = @"partially_played";
NSString* kSmartListTypeRecentlyPlayed = @"recently_played";

NSString* kSmartListSortNewestFirst = @"newest_first";
NSString* kSmartListSortOldestFirst = @"oldest_first";

NSString* kSmartListPredicateTitleKey = @"title";
NSString* kSmartListPredicateTypeKey = @"type";
NSString* kSmartListPredicateSortOrderKey = @"sort";
NSString* kSmartListPredicateGroupedKey = @"grouped";
NSString* kSmartListPredicateSortKeyKey = @"sort_key";

@interface CDSmartPlaylist ()
@property (nonatomic, retain) NSString * smartPredicate_;
@end


@implementation CDSmartPlaylist {
    BOOL _observing;
}

- (NSString*) designatedUID
{
    return [self.name MD5Hash];
}

@dynamic smartPredicate_;
@dynamic smartPredicate;

- (NSDictionary*) smartPredicate
{
    NSString* primitivePredicate = self.smartPredicate_;
    if (!primitivePredicate) {
        return nil;
    }
    NSData* data = [primitivePredicate dataUsingEncoding:NSUTF8StringEncoding];
    NSError* jsonError;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
}

- (void) setSmartPredicate:(NSDictionary *)predicate
{
    if (!predicate) {
        self.smartPredicate_ = nil;
        return;
    }
    NSError* jsonError;
    NSData* data = [NSJSONSerialization dataWithJSONObject:predicate options:0 error:&jsonError];
    self.smartPredicate_ = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (BOOL) isVisible {
    return (self.smartPredicate_ != nil);
}


- (void) setObserving:(BOOL)observing
{
    if (!_observing && observing)
    {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextObjectsDidChangeNotification:)
                                                     name:NSManagedObjectContextObjectsDidChangeNotification
                                                   object:self.managedObjectContext];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cacheManagerDidClearCacheNotification:)
                                                     name:CacheManagerDidClearCacheNotification
                                                   object:[CacheManager sharedCacheManager]];
        
        _observing = YES;
    }
    else if (_observing && !observing)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:NSManagedObjectContextObjectsDidChangeNotification
                                                      object:self.managedObjectContext];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:CacheManagerDidClearCacheNotification
                                                      object:[CacheManager sharedCacheManager]];
        _observing = NO;
    }
}

- (void) awakeFromFetch
{
    [super awakeFromFetch];
    if (self.managedObjectContext == DMANAGER.objectContext) {
        [self setObserving:YES];
    }
}

- (void) awakeFromInsert
{
    [super awakeFromInsert];
    if (self.managedObjectContext == DMANAGER.objectContext) {
        [self setObserving:YES];
    }
}

- (void) willTurnIntoFault
{
    [self setObserving:NO];
}

- (void) dealloc
{
    [self setObserving:NO];
}

- (void) _notifySortedEpisodesChanged
{
    if (![[NSThread currentThread] isMainThread]) {
        return;
    }

    [self willChangeValueForKey:@"sortedEpisodes"];
    [self didChangeValueForKey:@"sortedEpisodes"];
}

- (void) managedObjectContextObjectsDidChangeNotification:(NSNotification*)notification
{
    NSSet* keyPathes = [self keyPathesForValuesAffectingObjects];
    
    NSDictionary* userInfo = [notification userInfo];
    NSSet* insertedObjects = userInfo[NSInsertedObjectsKey];
    NSSet* updatedObjects = userInfo[NSUpdatedObjectsKey];
    NSSet* deletedObjects = userInfo[NSDeletedObjectsKey];
    
    NSMutableSet* set = [[NSMutableSet alloc] init];
    [set unionSet:insertedObjects];
    [set unionSet:updatedObjects];
    [set unionSet:deletedObjects];
    
    BOOL shouldNotify = NO;
    
    for(id object in set)
    {
        if (shouldNotify) {
            break;
        }
        
        if ([object isKindOfClass:[CDEpisode class]])
        {
            CDEpisode* episode = (CDEpisode*)object;
            NSDictionary* episodeChanges = [episode changedValuesForCurrentEvent];
            
            for(NSString* keyPath in episodeChanges) {
                if ([keyPathes containsObject:keyPath]) {
                    shouldNotify = YES;
                    break;
                }
            }
            
            CDFeed* feed = episode.feed;
            NSDictionary* feedChanges = [feed changedValuesForCurrentEvent];
            for(NSString* keyPath in feedChanges) {
                if ([keyPathes containsObject:[@"feed." stringByAppendingString:keyPath]]) {
                    shouldNotify = YES;
                    break;
                }
            }
        }
        else if ([object isKindOfClass:[CDFeed class]])
        {
            CDFeed* feed = (CDFeed*)object;
            NSDictionary* feedChanges = [feed changedValuesForCurrentEvent];
            for(NSString* keyPath in feedChanges) {
                if ([keyPathes containsObject:[@"feed." stringByAppendingString:keyPath]]) {
                    shouldNotify = YES;
                    break;
                }
            }
        }
    }
    
    if (shouldNotify) {
        [self _notifySortedEpisodesChanged];
    }
}

- (void) cacheManagerDidClearCacheNotification:(NSNotification*)notification
{
    NSDictionary* predicate = self.smartPredicate;
    NSString* type = predicate[kSmartListPredicateTypeKey];
    
    if (predicate && [type isEqualToString:kSmartListTypeDownload]) {
        [self willChangeValueForKey:@"sortedEpisodes"];
        [self didChangeValueForKey:@"sortedEpisodes"];
    }
}


- (IC_IMAGE*) image
{
#if TARGET_OS_IPHONE
    NSString* type = [self.smartPredicate objectForKey:@"type"];

    if ([type isEqualToString:kSmartListTypeUnplayed]) {
        return [[UIImage imageNamed:@"List Unplayed"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    else if ([type isEqualToString:kSmartListTypeStarred]) {
        return [[UIImage imageNamed:@"List Favorites"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    else if ([type isEqualToString:kSmartListTypeDownload]) {
        return [[UIImage imageNamed:@"List Downloaded"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    else if ([type isEqualToString:kSmartListTypePartiallyPlayed]) {
        return [[UIImage imageNamed:@"List Partially Played"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    else if ([type isEqualToString:kSmartListTypeMostRecent]) {
        return [[UIImage imageNamed:@"List Most Recent"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    else if ([type isEqualToString:kSmartListTypeRecentlyPlayed]) {
        return [[UIImage imageNamed:@"List Recently Played"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
#endif
    return [super image];
}

#pragma mark -

- (NSSet*) keyPathesForValuesAffectingObjects
{
    NSDictionary* predicate = self.smartPredicate;
    
    if (predicate)
    {
        NSString* type = predicate[kSmartListPredicateTypeKey];
        if ([type isEqualToString:kSmartListTypeUnplayed]) {
            return [NSSet setWithObjects:@"feed.subscribed", @"feed.parked", @"archived", @"consumed", nil];
        }
        else if ([type isEqualToString:kSmartListTypeStarred]) {
            return [NSSet setWithObjects:@"feed.subscribed", @"feed.parked", @"archived", @"starred", nil];
        }
        else if ([type isEqualToString:kSmartListTypeDownload]) {
            return [NSSet setWithObjects:@"feed.subscribed", @"feed.parked", @"archived", @"downloaded", nil];//lastDownloaded DEVD TODO
        }
        else if ([type isEqualToString:kSmartListTypePartiallyPlayed]) {
            return [NSSet setWithObjects:@"feed.subscribed", @"feed.parked", @"archived", @"consumed", @"position", nil];
        }
        else if ([type isEqualToString:kSmartListTypeMostRecent]) {
            return [NSSet setWithObjects:@"feed.subscribed", @"feed.parked", @"archived", nil];
        }
        else if ([type isEqualToString:kSmartListTypeRecentlyPlayed]) {
            return [NSSet setWithObjects:@"feed.subscribed", @"feed.parked", @"archived", @"lastPlayed", nil];
        }
    }
    
    return nil;
}


- (NSFetchRequest*) episodesFetchRequest
{
    NSDictionary* predicate = self.smartPredicate;
    
    if (predicate)
    {
        NSString* type = predicate[kSmartListPredicateTypeKey];
        NSString* sort = predicate[kSmartListPredicateSortOrderKey];
        
        BOOL reverseOrder = [sort isEqualToString:kSmartListSortOldestFirst];
        
        if ([type isEqualToString:kSmartListTypeUnplayed]) {
            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
            fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@ && consumed == %@", @YES, @NO, @NO];
            fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
            return fetchRequest;
        }
        
        else if ([type isEqualToString:kSmartListTypeStarred]) {
            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
            fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@ && starred == %@", @YES, @NO, @YES];
            fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
            return fetchRequest;
        }
        
        else if ([type isEqualToString:kSmartListTypeDownload])
        {
            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
            fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@ && downloaded == %@", @YES, @NO, @YES];
            fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
            return fetchRequest; //nil DEVD TODO
        }
        
        else if ([type isEqualToString:kSmartListTypePartiallyPlayed]) {
            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
            fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@ && consumed == %@ && position > %@", @YES, @NO, @NO, @0];
            fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
            fetchRequest.fetchLimit = 25;
            return fetchRequest;
        }
        
        
        else if ([type isEqualToString:kSmartListTypeMostRecent]) {
            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
            fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@", @YES, @NO];
            fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
            fetchRequest.fetchLimit = 25;
            return fetchRequest;
        }
        
        
        else if ([type isEqualToString:kSmartListTypeRecentlyPlayed]) {
            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
            fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == %@ && archived == %@ && lastPlayed != nil", @YES, @NO];
            fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"lastPlayed" ascending:reverseOrder] ];
            fetchRequest.fetchLimit = 25;
            return fetchRequest;
        }
        else {
            ErrLog(@"smart playlist '%@' not implemented yet.", type);
        }
    }
    
    return nil;
}


- (NSArray*) sortedEpisodes
{
    return [self sortedEpisodesWithOffset:0 limit:0];
}

- (NSArray*) sortedEpisodesWithOffset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError**)error
{
    NSDictionary* predicate = self.smartPredicate;
    if (!predicate) {
        return @[];
    }

    NSString* type = predicate[kSmartListPredicateTypeKey];
    NSFetchRequest* request = nil;
    if ([type isEqualToString:kSmartListTypeDownload]) {
        request = [[NSFetchRequest alloc] init];
        request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
        request.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@",
                             [CacheManager sharedCacheManager].cachedEpisodeObjectHashes];
        BOOL oldestFirst = [predicate[kSmartListPredicateSortOrderKey] isEqualToString:kSmartListSortOldestFirst];
        request.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:oldestFirst]];
    }
    else {
        request = [[self episodesFetchRequest] copy];
    }
    if (!request) {
        return @[];
    }

    NSUInteger intrinsicLimit = request.fetchLimit;
    if (intrinsicLimit > 0 && offset >= intrinsicLimit) {
        return @[];
    }

    NSUInteger effectiveLimit = limit;
    if (intrinsicLimit > 0) {
        NSUInteger remaining = intrinsicLimit - offset;
        effectiveLimit = (limit > 0) ? MIN(limit, remaining) : remaining;
    }

    NSMutableArray<NSSortDescriptor*>* sortDescriptors = [request.sortDescriptors mutableCopy] ?: [[NSMutableArray alloc] init];
    BOOL hasObjectHashTieBreaker = NO;
    for (NSSortDescriptor* descriptor in sortDescriptors) {
        if ([descriptor.key isEqualToString:@"objectHash"]) {
            hasObjectHashTieBreaker = YES;
            break;
        }
    }
    if (!hasObjectHashTieBreaker) {
        [sortDescriptors addObject:[[NSSortDescriptor alloc] initWithKey:@"objectHash" ascending:YES]];
    }
    request.sortDescriptors = sortDescriptors;
    request.fetchOffset = offset;
    request.fetchLimit = effectiveLimit;

    NSError* fetchError = nil;
    NSArray* episodes = [self.managedObjectContext executeFetchRequest:request error:&fetchError];
    if (fetchError) {
        ErrLog(@"error fetching smart-playlist page: %@", fetchError);
        if (error) {
            *error = fetchError;
        }
        return nil;
    }
    return episodes ?: @[];
}

- (NSFetchRequest*)_statisticsFetchRequest
{
    NSString* type = self.smartPredicate[kSmartListPredicateTypeKey];
    if ([type isEqualToString:kSmartListTypeDownload]) {
        NSFetchRequest* request = [[NSFetchRequest alloc] init];
        request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:self.managedObjectContext];
        request.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@",
                             [CacheManager sharedCacheManager].cachedEpisodeObjectHashes];
        return request;
    }
    return [[self episodesFetchRequest] copy];
}

- (NSInteger)playbackTime
{
    NSFetchRequest* request = [self _statisticsFetchRequest];
    if (!request) {
        return 0;
    }

    if (request.fetchLimit > 0) {
        request.resultType = NSDictionaryResultType;
        request.propertiesToFetch = @[@"duration"];
        NSError* error = nil;
        NSArray<NSDictionary*>* rows = [self.managedObjectContext executeFetchRequest:request error:&error];
        if (error) {
            ErrLog(@"error calculating limited smart-playlist duration: %@", error);
            return 0;
        }
        NSInteger duration = 0;
        for (NSDictionary* row in rows) {
            duration += [row[@"duration"] integerValue];
        }
        return duration;
    }

    NSExpressionDescription* totalDuration = [[NSExpressionDescription alloc] init];
    totalDuration.name = @"totalDuration";
    totalDuration.expression = [NSExpression expressionForFunction:@"sum:"
                                                          arguments:@[[NSExpression expressionForKeyPath:@"duration"]]];
    totalDuration.expressionResultType = NSInteger64AttributeType;
    request.resultType = NSDictionaryResultType;
    request.sortDescriptors = nil;
    request.propertiesToFetch = @[totalDuration];

    NSError* error = nil;
    NSDictionary* result = [[self.managedObjectContext executeFetchRequest:request error:&error] firstObject];
    if (error) {
        ErrLog(@"error calculating smart-playlist duration: %@", error);
        return 0;
    }
    return [result[@"totalDuration"] integerValue];
}

- (NSUInteger)numberOfPlayedEpisodes
{
    NSFetchRequest* request = [self _statisticsFetchRequest];
    if (!request) {
        return 0;
    }

    if (request.fetchLimit > 0) {
        request.resultType = NSDictionaryResultType;
        request.propertiesToFetch = @[@"consumed"];
        NSError* error = nil;
        NSArray<NSDictionary*>* rows = [self.managedObjectContext executeFetchRequest:request error:&error];
        if (error) {
            ErrLog(@"error calculating limited smart-playlist played count: %@", error);
            return 0;
        }
        NSUInteger count = 0;
        for (NSDictionary* row in rows) {
            if ([row[@"consumed"] boolValue]) {
                count++;
            }
        }
        return count;
    }

    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        request.predicate ?: [NSPredicate predicateWithValue:YES],
        [NSPredicate predicateWithFormat:@"consumed == YES"],
    ]];
    request.sortDescriptors = nil;
    NSUInteger count = [self.managedObjectContext countForFetchRequest:request error:NULL];
    return (count == NSNotFound) ? 0 : count;
}

- (NSUInteger)numberOfPlayedDownloadedEpisodes
{
    NSFetchRequest* request = [self _statisticsFetchRequest];
    if (!request) {
        return 0;
    }
    NSSet<NSString*>* cachedHashes = [CacheManager sharedCacheManager].cachedEpisodeObjectHashes;

    if (request.fetchLimit > 0) {
        request.resultType = NSDictionaryResultType;
        request.propertiesToFetch = @[@"consumed", @"objectHash"];
        NSError* error = nil;
        NSArray<NSDictionary*>* rows = [self.managedObjectContext executeFetchRequest:request error:&error];
        if (error) {
            ErrLog(@"error calculating limited smart-playlist downloaded count: %@", error);
            return 0;
        }
        NSUInteger count = 0;
        for (NSDictionary* row in rows) {
            if ([row[@"consumed"] boolValue] && [cachedHashes containsObject:row[@"objectHash"]]) {
                count++;
            }
        }
        return count;
    }

    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        request.predicate ?: [NSPredicate predicateWithValue:YES],
        [NSPredicate predicateWithFormat:@"consumed == YES"],
        [NSPredicate predicateWithFormat:@"objectHash IN %@", cachedHashes],
    ]];
    request.sortDescriptors = nil;
    NSUInteger count = [self.managedObjectContext countForFetchRequest:request error:NULL];
    return (count == NSNotFound) ? 0 : count;
}

+ (NSSet*) keyPathsForValuesAffectingNumberOfEpisodes
{
    return [NSSet setWithObjects:@"smartPredicate_", @"sortedEpisodes",nil];
}

- (NSUInteger) numberOfEpisodes
{
    NSDictionary* predicate = self.smartPredicate;
    
    if (predicate)
    {
        NSString* type = [predicate objectForKey:kSmartListPredicateTypeKey];
        
        if ([type isEqualToString:kSmartListTypeDownload]) {
            return [CacheManager sharedCacheManager].cachedEpisodeObjectHashes.count;
        }
        else
        {
            return [self.managedObjectContext countForFetchRequest:[self episodesFetchRequest] error:nil];
        }
        
        ErrLog(@"smart playlist '%@' not implemented yet.", type);
    }
    
    return 0;
}

- (NSSortDescriptor*) sortDescriptor
{
    NSDictionary* predicate = self.smartPredicate;
    
    if (predicate)
    {
        NSString* key = predicate[kSmartListPredicateSortKeyKey];
        if (!key) {
            key = @"pubDate";
        }
        NSString* sort = predicate[kSmartListPredicateSortOrderKey];
        BOOL ascending = [sort isEqualToString:kSmartListSortOldestFirst];
        
        return [[NSSortDescriptor alloc] initWithKey:key ascending:ascending];
    }
    
    return nil;
}

- (void) setSortDescriptor:(NSSortDescriptor *)sortDescriptor
{
    NSMutableDictionary* predicate = [self.smartPredicate mutableCopy];
    
    if (predicate)
    {
        predicate[kSmartListPredicateSortKeyKey] = [sortDescriptor key];
        predicate[kSmartListPredicateSortOrderKey] = ([sortDescriptor ascending]) ? kSmartListSortOldestFirst : kSmartListSortNewestFirst;
        
        self.smartPredicate = predicate;
    }
}

@end
