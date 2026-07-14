//
//  CDList.m
//  Instacast
//
//  Created by Martin Hering on 07.08.12.
//
//

#import "CDList.h"
#import "CacheManager.h"


@implementation CDList

@dynamic name;
@dynamic rank;

+ (NSSet*) keyPathsForValuesAffectingNumberOfEpisodes
{
    return [NSSet setWithObject:@"sortedEpisodes"];
}

- (NSUInteger) numberOfEpisodes
{
    return 0;
}

- (void) calculateNumberOfEpisodesCompletion:(void (^)(NSUInteger numberOfEpisodes))completion {
    if (completion) {
        completion([self numberOfEpisodes]);
    }
}

- (NSArray*) sortedEpisodes
{
    return nil;
}

- (NSArray*) sortedEpisodesWithLimit:(NSUInteger)limit
{
    return [self sortedEpisodesWithOffset:0 limit:limit];
}

- (NSArray*) sortedEpisodesWithOffset:(NSUInteger)offset limit:(NSUInteger)limit
{
    return [self sortedEpisodesWithOffset:offset limit:limit error:NULL];
}

- (NSArray*) sortedEpisodesWithOffset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError**)error
{
    (void)error;
    NSArray* all = [self sortedEpisodes];
    if (offset >= all.count) {
        return @[];
    }

    NSUInteger count = all.count - offset;
    if (limit > 0) {
        count = MIN(count, limit);
    }
    return [all subarrayWithRange:NSMakeRange(offset, count)];
}

- (NSInteger) playbackTime
{
    NSInteger playbackTime = 0;
    for(CDEpisode* episode in self.sortedEpisodes) {
        playbackTime += episode.duration;
    }
    
    return playbackTime;
}

- (NSUInteger) numberOfPlayedEpisodes
{
    NSUInteger count = 0;
    for (CDEpisode* episode in self.sortedEpisodes) {
        if (episode.consumed) {
            count++;
        }
    }
    return count;
}

- (NSUInteger) numberOfPlayedDownloadedEpisodes
{
    NSSet<NSString*>* cachedHashes = [CacheManager sharedCacheManager].cachedEpisodeObjectHashes;
    NSUInteger count = 0;
    for (CDEpisode* episode in self.sortedEpisodes) {
        if (episode.consumed && [cachedHashes containsObject:episode.objectHash]) {
            count++;
        }
    }
    return count;
}

- (IC_IMAGE*) image
{
#if TARGET_OS_IPHONE
    return [[UIImage imageNamed:@"List Custom"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
#else
    return nil;
#endif
}

+ (void) updateRanksOfLists:(NSArray*)lists
{
    NSInteger num = 0;
    for(CDList* list in lists) {
        list.rank = (int32_t)num;
        num++;
    }
}
@end
