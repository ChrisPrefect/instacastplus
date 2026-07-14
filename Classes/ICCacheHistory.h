//
//  ICCacheHistory.h
//  Instacast
//
//  Created by Martin Hering on 20.03.13.
//
//

#import <Foundation/Foundation.h>

@interface ICCacheHistory : NSObject

@property (nonatomic, readonly, getter=isLoaded) BOOL loaded;

- (id) initWithContentsOfFile:(NSString*)filePath;

- (BOOL) episodeDidAutoDownload:(CDEpisode*)episode;
- (void) setEpisode:(CDEpisode*)episode didAutoDownload:(BOOL)autoDownload;
- (void)setEpisode:(CDEpisode*)episode
 didAutoDownload:(BOOL)autoDownload
      completion:(void (^)(NSError* error))completion;
- (void) resetValuesForEpisode:(CDEpisode*)episode;
- (void)resetValuesForEpisodes:(NSArray<CDEpisode*>*)episodes
                    completion:(void (^)(NSError* error))completion;

- (void)reloadIfNeededWithCompletion:(void (^)(NSError* error))completion;
- (void)clearWithCompletion:(void (^)(NSError* error))completion;
@end
