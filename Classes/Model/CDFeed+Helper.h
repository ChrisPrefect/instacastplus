//
//  CDFeed+Helper.h
//  Instacast
//
//  Created by Martin Hering on 18.12.12.
//
//

#import "CDFeed.h"

@interface CDFeed (Helper)

- (NSArray*) sortedEpisodes;
- (NSArray*) chronologicallySortedEpisodes;

- (NSArray*) unplayedEpisodes;

- (NSURL*) sourceURLAsPcastURL;

// Episode lazy loading status
@property (nonatomic, readonly) BOOL hasMoreEpisodesToLoad;
@property (nonatomic, readonly) double episodeLoadingProgress;

@end
