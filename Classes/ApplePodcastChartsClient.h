//
//  ApplePodcastChartsClient.h
//  Instacast
//
//  Created by Chris on 12.02.26.
//

#import <Foundation/Foundation.h>

extern NSString* const kAppleChartsName;
extern NSString* const kAppleChartsArtistName;
extern NSString* const kAppleChartsArtworkUrl100;
extern NSString* const kAppleChartsID;
extern NSString* const kAppleChartsURL;
extern NSString* const kAppleChartsGenres;

@interface ApplePodcastChartsClient : NSObject

+ (instancetype)sharedClient;

/// Fetches top podcasts from Apple Charts API.
/// @param countryCode 2-letter lowercase country code (e.g. "ch", "us", "de"). Pass nil for auto-detect.
/// @param limit Number of results: 10, 25, or 50.
/// @param completion Called on main thread with results array (dictionaries with kAppleCharts* keys), last-updated string, and error.
- (void)fetchTopPodcastsWithCountryCode:(NSString *)countryCode
                                  limit:(NSInteger)limit
                             completion:(void (^)(NSArray *results, NSString *updated, NSError *error))completion;

/// Returns the device's country code (lowercase), or "ch" as fallback.
- (NSString *)defaultCountryCode;

/// Clears all cached data.
- (void)clearCache;

@end
