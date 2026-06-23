//
//  ICSpotlightIndexer.h
//  Instacast
//

#import <Foundation/Foundation.h>

@class CDFeed, CDEpisode;

@interface ICSpotlightIndexer : NSObject

+ (NSString*)podcastUniqueIdentifierForSourceURLString:(NSString*)sourceURLString;
+ (NSString*)episodeUniqueIdentifierForObjectHash:(NSString*)objectHash;
+ (NSString*)sourceURLStringFromPodcastUniqueIdentifier:(NSString*)uniqueIdentifier;
+ (NSString*)objectHashFromEpisodeUniqueIdentifier:(NSString*)uniqueIdentifier;

- (void)indexFeeds:(NSArray*)feeds;

- (void)addFeed:(CDFeed*)feed;
- (void)updateFeed:(CDFeed*)feed;
- (void)removeFeed:(CDFeed*)feed;

- (void)addEpisode:(CDEpisode*)episode;
- (void)updateEpisode:(CDEpisode*)episode;
- (void)removeEpisode:(CDEpisode*)episode;

@end
