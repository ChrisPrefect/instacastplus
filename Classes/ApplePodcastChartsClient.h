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
extern NSString* const kAppleChartsGenreIDs; // NSArray of NSString genreId values

@interface ApplePodcastChartsClient : NSObject

+ (instancetype)sharedClient;

/// Fetches top podcasts from Apple Charts API.
/// @param countryCode 2-letter lowercase country code (e.g. "ch", "us", "de"). Pass nil for auto-detect.
/// @param limit Number of results: 10, 25, 50, or 100.
/// @param completion Called on main thread with results array (dictionaries with kAppleCharts* keys), last-updated string, and error.
- (void)fetchTopPodcastsWithCountryCode:(NSString *)countryCode
                                  limit:(NSInteger)limit
                             completion:(void (^)(NSArray *results, NSString *updated, NSError *error))completion;

/// Returns cached results synchronously (even if stale). Returns nil if no cache exists.
- (NSArray *)cachedTopPodcastsForCountryCode:(NSString *)countryCode limit:(NSInteger)limit;

/// Returns the device's country code (lowercase), or "ch" as fallback.
- (NSString *)defaultCountryCode;

/// Fetches per-genre top podcasts from legacy iTunes RSS API (~19 genres in parallel).
/// Results are normalized to the same kAppleCharts* dictionary format.
/// @param countryCode 2-letter lowercase country code. Pass nil for auto-detect.
/// @param limitPerGenre Number of podcasts to fetch per genre (max 200).
/// @param completion Called on main thread with merged deduplicated results array and error.
- (void)fetchGenrePodcastsWithCountryCode:(NSString *)countryCode
                            limitPerGenre:(NSInteger)limitPerGenre
                               completion:(void (^)(NSArray *results, NSError *error))completion;

/// Returns cached genre podcast results synchronously (even if stale). Returns nil if no cache exists.
- (NSArray *)cachedGenrePodcastsForCountryCode:(NSString *)countryCode;

/// Clears all cached data.
- (void)clearCache;

@end
