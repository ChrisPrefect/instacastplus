//
//  ICFTSController.h
//  Instacast
//
//  Created by Martin Hering on 28.08.14.
//
//

#import <Foundation/Foundation.h>

@class NSManagedObjectContext;

@interface ICFTSController : NSObject

- (id) initWithSearchIndexURL:(NSURL*)url;

- (void) open;
- (BOOL) indexNeedsRebuild;
- (BOOL) prepareForExternalStoreMutation:(NSError**)error;

- (void) rebuildIndexWithManagedObjectContext:(NSManagedObjectContext*)context
                                   completion:(void (^)(NSError* error))completion;

- (void) stageChangesForManagedObjectContext:(NSManagedObjectContext*)context;
- (void) commitStagedChangesForManagedObjectContext:(NSManagedObjectContext*)context;
- (void) setCommittedChangesManagedObjectContext:(NSManagedObjectContext*)context;

- (void) addFeed:(CDFeed*)feed;
- (void) updateFeed:(CDFeed*)feed;
- (void) removeFeed:(CDFeed*)feed;

- (void) addEpisode:(CDEpisode*)episode;
- (void) updateEpisode:(CDEpisode*)episode;
- (void) removeEpisode:(CDEpisode*)episode;

- (NSSet*) feedSourceURLsForSearchTerm:(NSString*)search;
- (NSSet*) episodeObjectHashesForSearchTerm:(NSString*)search;

@end
