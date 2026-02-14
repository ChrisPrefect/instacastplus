//
//  ApplePodcastChartsClient.m
//  Instacast
//
//  Created by Chris on 12.02.26.
//

#import "ApplePodcastChartsClient.h"

NSString* const kAppleChartsName = @"kAppleChartsName";
NSString* const kAppleChartsArtistName = @"kAppleChartsArtistName";
NSString* const kAppleChartsArtworkUrl100 = @"kAppleChartsArtworkUrl100";
NSString* const kAppleChartsID = @"kAppleChartsID";
NSString* const kAppleChartsURL = @"kAppleChartsURL";
NSString* const kAppleChartsGenres = @"kAppleChartsGenres";
NSString* const kAppleChartsGenreIDs = @"kAppleChartsGenreIDs";

static NSString* const kCacheDirectoryName = @"ApplePodcastCharts";
static NSTimeInterval const kCacheTTL = 30 * 60; // 30 minutes

@interface ApplePodcastChartsClient ()
@property (nonatomic, strong) NSCache *memoryCache;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation ApplePodcastChartsClient

+ (instancetype)sharedClient
{
    static ApplePodcastChartsClient *client = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[ApplePodcastChartsClient alloc] init];
    });
    return client;
}

- (instancetype)init
{
    if ((self = [super init]))
    {
        _memoryCache = [[NSCache alloc] init];
        _memoryCache.countLimit = 10;

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 20.0;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - Public

- (NSString *)defaultCountryCode
{
    NSString *countryCode = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    if ([countryCode length] >= 2) {
        return [countryCode lowercaseString];
    }
    return @"ch";
}

- (NSString *)_cacheKeyForCountryCode:(NSString *)countryCode limit:(NSInteger)limit
{
    return [NSString stringWithFormat:@"%@_%ld", countryCode, (long)limit];
}

- (NSInteger)_clampLimit:(NSInteger)limit
{
    if (limit <= 10) return 10;
    if (limit <= 25) return 25;
    if (limit <= 50) return 50;
    return 100;
}

- (NSArray *)cachedTopPodcastsForCountryCode:(NSString *)countryCode limit:(NSInteger)limit
{
    if (!countryCode) {
        countryCode = [self defaultCountryCode];
    }
    countryCode = [countryCode lowercaseString];
    limit = [self _clampLimit:limit];

    NSString *cacheKey = [self _cacheKeyForCountryCode:countryCode limit:limit];

    // Check memory cache (any age)
    NSDictionary *cached = [self.memoryCache objectForKey:cacheKey];
    if (cached) {
        return cached[@"results"];
    }

    // Check disk cache (any age)
    NSDictionary *diskCached = [self _loadDiskCacheForKey:cacheKey];
    if (diskCached) {
        [self.memoryCache setObject:diskCached forKey:cacheKey];
        return diskCached[@"results"];
    }

    return nil;
}

- (void)fetchTopPodcastsWithCountryCode:(NSString *)countryCode
                                  limit:(NSInteger)limit
                             completion:(void (^)(NSArray *results, NSString *updated, NSError *error))completion
{
    if (!countryCode) {
        countryCode = [self defaultCountryCode];
    }
    countryCode = [countryCode lowercaseString];
    limit = [self _clampLimit:limit];

    NSString *cacheKey = [self _cacheKeyForCountryCode:countryCode limit:limit];

    // 1. Check memory cache (still valid)
    NSDictionary *cached = [self.memoryCache objectForKey:cacheKey];
    if (cached && [self _isCacheValid:cached]) {
        if (completion) {
            completion(cached[@"results"], cached[@"updated"], nil);
        }
        return;
    }

    // 2. Check disk cache (still valid)
    NSDictionary *diskCached = [self _loadDiskCacheForKey:cacheKey];
    if (diskCached && [self _isCacheValid:diskCached]) {
        [self.memoryCache setObject:diskCached forKey:cacheKey];
        if (completion) {
            completion(diskCached[@"results"], diskCached[@"updated"], nil);
        }
        return;
    }

    // 3. Fetch from network
    NSString *urlString = [NSString stringWithFormat:@"https://rss.marketingtools.apple.com/api/v2/%@/podcasts/top/%ld/podcasts.json",
                           countryCode, (long)limit];
    NSURL *url = [NSURL URLWithString:urlString];

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                // Fallback to stale cache
                NSDictionary *staleCache = diskCached ?: cached;
                if (staleCache) {
                    if (completion) {
                        completion(staleCache[@"results"], staleCache[@"updated"], nil);
                    }
                } else {
                    if (completion) {
                        completion(nil, nil, error);
                    }
                }
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode != 200) {
                NSError *statusError = [NSError errorWithDomain:@"ApplePodcastChartsErrorDomain"
                                                          code:httpResponse.statusCode
                                                      userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]}];
                // Fallback to stale cache
                NSDictionary *staleCache = diskCached ?: cached;
                if (staleCache) {
                    if (completion) {
                        completion(staleCache[@"results"], staleCache[@"updated"], nil);
                    }
                } else {
                    if (completion) {
                        completion(nil, nil, statusError);
                    }
                }
                return;
            }

            NSArray *results = nil;
            NSString *updated = nil;
            NSError *parseError = nil;
            [self _parseData:data results:&results updated:&updated error:&parseError];

            if (parseError || !results) {
                NSDictionary *staleCache = diskCached ?: cached;
                if (staleCache) {
                    if (completion) {
                        completion(staleCache[@"results"], staleCache[@"updated"], nil);
                    }
                } else {
                    if (completion) {
                        completion(nil, nil, parseError);
                    }
                }
                return;
            }

            // Cache the results
            NSDictionary *cacheEntry = @{
                @"results": results,
                @"updated": updated ?: @"",
                @"timestamp": @([[NSDate date] timeIntervalSince1970])
            };
            [self.memoryCache setObject:cacheEntry forKey:cacheKey];
            [self _saveDiskCache:cacheEntry forKey:cacheKey rawData:data];

            if (completion) {
                completion(results, updated, nil);
            }
        });
    }];
    [task resume];
}

+ (NSArray *)podcastGenreIDs
{
    static NSArray *ids = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ids = @[
            // Main categories
            @"1301", // Arts
            @"1303", // Comedy
            @"1304", // Education
            @"1305", // Kids & Family
            @"1519", // Education for Kids
            @"1520", // Stories for Kids
            @"1521", // Parenting
            @"1522", // Pets & Animals
            @"1309", // TV & Film
            @"1310", // Music
            @"1314", // Religion & Spirituality
            @"1318", // Technology
            @"1321", // Business
            @"1324", // Society & Culture
            @"1483", // Fiction
            @"1487", // History
            @"1488", // True Crime
            @"1489", // News
            @"1502", // Leisure
            @"1511", // Government
            @"1512", // Health & Fitness
            @"1533", // Science
            @"1545", // Sports
            // Arts subcategories
            @"1482", // Books
            @"1402", // Design
            @"1459", // Fashion & Beauty
            @"1306", // Food
            @"1405", // Performing Arts
            // Comedy subcategories
            @"1496", // Comedy Interviews
            @"1495", // Improv
            @"1497", // Stand-Up
            // Education subcategories
            @"1501", // Courses
            @"1499", // How To
            @"1498", // Language Learning
            @"1500", // Self-Improvement
            // TV & Film subcategories
            @"1562", // After Shows
            @"1564", // Film History
            @"1565", // Film Interviews
            @"1563", // Film Reviews
            @"1561", // TV Reviews
            // Music subcategories
            @"1523", // Music Commentary
            @"1524", // Music History
            @"1525", // Music Interviews
            // Religion & Spirituality subcategories
            @"1438", // Buddhism
            @"1439", // Christianity
            @"1463", // Hinduism
            @"1440", // Islam
            @"1441", // Judaism
            // Business subcategories
            @"1410", // Careers
            @"1493", // Entrepreneurship
            @"1412", // Investing
            @"1491", // Management
            @"1492", // Marketing
            @"1494", // Non-Profit
            // Society & Culture subcategories
            @"1543", // Documentary
            @"1302", // Personal Journals
            @"1443", // Philosophy
            @"1320", // Places & Travel
            @"1544", // Relationships
            // Fiction subcategories
            @"1486", // Comedy Fiction
            @"1484", // Drama
            @"1485", // Science Fiction
            // News subcategories
            @"1526", // Daily News
            @"1490", // Business News
            @"1531", // Entertainment News
            @"1530", // News Commentary
            @"1527", // Politics
            @"1529", // Sports News
            @"1528", // Tech News
            // Leisure subcategories
            @"1510", // Animation & Manga
            @"1503", // Automotive
            @"1504", // Aviation
            @"1506", // Crafts
            @"1507", // Games
            // Health & Fitness subcategories
            @"1513", // Alternative Health
            @"1514", // Fitness
            @"1518", // Medicine
            @"1517", // Mental Health
            // Science subcategories
            @"1538", // Astronomy
            @"1539", // Chemistry
            @"1540", // Earth Sciences
            @"1541", // Life Sciences
            @"1536", // Mathematics
            // Sports subcategories
            @"1547", // Football
            @"1548", // Basketball
            @"1546", // Soccer
            @"1550", // Hockey
            @"1560", // Fantasy Sports
        ];
    });
    return ids;
}

- (void)fetchGenrePodcastsWithCountryCode:(NSString *)countryCode
                            limitPerGenre:(NSInteger)limitPerGenre
                               completion:(void (^)(NSArray *results, NSError *error))completion
{
    if (!countryCode) {
        countryCode = [self defaultCountryCode];
    }
    countryCode = [countryCode lowercaseString];

    NSString *cacheKey = [NSString stringWithFormat:@"legacy_genres_%@", countryCode];

    // Check memory cache (still valid)
    NSDictionary *cached = [self.memoryCache objectForKey:cacheKey];
    if (cached && [self _isCacheValid:cached]) {
        if (completion) {
            completion(cached[@"results"], nil);
        }
        return;
    }

    // Check disk cache (still valid)
    NSDictionary *diskCached = [self _loadGenreDiskCacheForKey:cacheKey];
    if (diskCached && [self _isCacheValid:diskCached]) {
        [self.memoryCache setObject:diskCached forKey:cacheKey];
        if (completion) {
            completion(diskCached[@"results"], nil);
        }
        return;
    }

    // Fetch from network — all genres in parallel
    NSArray *genreIDs = [ApplePodcastChartsClient podcastGenreIDs];
    NSMutableArray *allResults = [NSMutableArray array];
    NSMutableSet *seenIDs = [NSMutableSet set];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t mergeQueue = dispatch_queue_create("com.instacast.charts.merge", DISPATCH_QUEUE_SERIAL);

    for (NSString *genreId in genreIDs) {
        dispatch_group_enter(group);

        NSString *urlString = [NSString stringWithFormat:@"https://itunes.apple.com/%@/rss/toppodcasts/limit=%ld/genre=%@/json",
                               countryCode, (long)limitPerGenre, genreId];
        NSURL *url = [NSURL URLWithString:urlString];

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error) {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode == 200) {
                    NSArray *results = nil;
                    [self _parseLegacyData:data results:&results error:nil];

                    if (results.count > 0) {
                        dispatch_sync(mergeQueue, ^{
                            for (NSDictionary *item in results) {
                                NSString *podcastId = item[kAppleChartsID];
                                if (podcastId && ![seenIDs containsObject:podcastId]) {
                                    [seenIDs addObject:podcastId];
                                    [allResults addObject:item];
                                }
                            }
                        });
                    }
                }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray *results = [allResults copy];

        if (results.count > 0) {
            NSDictionary *cacheEntry = @{
                @"results": results,
                @"timestamp": @([[NSDate date] timeIntervalSince1970])
            };
            [self.memoryCache setObject:cacheEntry forKey:cacheKey];
            [self _saveGenreDiskCache:cacheEntry forKey:cacheKey];
        }

        // Fallback to stale cache
        if (results.count == 0) {
            NSDictionary *staleCache = diskCached ?: cached;
            if (staleCache) {
                if (completion) {
                    completion(staleCache[@"results"], nil);
                }
                return;
            }
        }

        if (completion) {
            completion(results.count > 0 ? results : nil, nil);
        }
    });
}

- (NSArray *)cachedGenrePodcastsForCountryCode:(NSString *)countryCode
{
    if (!countryCode) {
        countryCode = [self defaultCountryCode];
    }
    countryCode = [countryCode lowercaseString];

    NSString *cacheKey = [NSString stringWithFormat:@"legacy_genres_%@", countryCode];

    NSDictionary *cached = [self.memoryCache objectForKey:cacheKey];
    if (cached) {
        return cached[@"results"];
    }

    NSDictionary *diskCached = [self _loadGenreDiskCacheForKey:cacheKey];
    if (diskCached) {
        [self.memoryCache setObject:diskCached forKey:cacheKey];
        return diskCached[@"results"];
    }

    return nil;
}

- (void)clearCache
{
    [self.memoryCache removeAllObjects];

    NSURL *cacheDir = [self _cacheDirectory];
    [[NSFileManager defaultManager] removeItemAtURL:cacheDir error:nil];
}

#pragma mark - Parsing

- (void)_parseData:(NSData *)data results:(NSArray **)outResults updated:(NSString **)outUpdated error:(NSError **)outError
{
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = jsonError ?: [NSError errorWithDomain:@"ApplePodcastChartsErrorDomain" code:-1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON response"}];
        return;
    }

    NSDictionary *feed = json[@"feed"];
    if (!feed || ![feed isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = [NSError errorWithDomain:@"ApplePodcastChartsErrorDomain" code:-2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Missing feed object"}];
        return;
    }

    if (outUpdated) {
        *outUpdated = [feed[@"updated"] isKindOfClass:[NSString class]] ? feed[@"updated"] : nil;
    }

    NSArray *rawResults = feed[@"results"];
    if (!rawResults || ![rawResults isKindOfClass:[NSArray class]]) {
        if (outResults) *outResults = @[];
        return;
    }

    NSMutableArray *parsedResults = [NSMutableArray arrayWithCapacity:rawResults.count];

    for (NSDictionary *entry in rawResults) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;

        NSMutableDictionary *item = [NSMutableDictionary dictionary];

        NSString *name = entry[@"name"];
        if ([name isKindOfClass:[NSString class]]) {
            item[kAppleChartsName] = name;
        }

        NSString *artistName = entry[@"artistName"];
        if ([artistName isKindOfClass:[NSString class]]) {
            item[kAppleChartsArtistName] = artistName;
        }

        NSString *artworkUrl = entry[@"artworkUrl100"];
        if ([artworkUrl isKindOfClass:[NSString class]]) {
            item[kAppleChartsArtworkUrl100] = artworkUrl;
        }

        NSString *podcastId = entry[@"id"];
        if ([podcastId isKindOfClass:[NSString class]]) {
            item[kAppleChartsID] = podcastId;
        }

        NSString *url = entry[@"url"];
        if ([url isKindOfClass:[NSString class]]) {
            item[kAppleChartsURL] = url;
        }

        // Parse genres
        NSArray *genres = entry[@"genres"];
        if ([genres isKindOfClass:[NSArray class]] && genres.count > 0) {
            NSMutableArray *genreNames = [NSMutableArray array];
            NSMutableArray *genreIDs = [NSMutableArray array];
            for (NSDictionary *genre in genres) {
                if ([genre isKindOfClass:[NSDictionary class]]) {
                    NSString *genreName = genre[@"name"];
                    NSString *genreId = genre[@"genreId"];
                    if ([genreName isKindOfClass:[NSString class]]) {
                        [genreNames addObject:genreName];
                    }
                    if ([genreId isKindOfClass:[NSString class]]) {
                        [genreIDs addObject:genreId];
                    }
                }
            }
            if (genreNames.count > 0) {
                item[kAppleChartsGenres] = [genreNames componentsJoinedByString:@", "];
            }
            if (genreIDs.count > 0) {
                item[kAppleChartsGenreIDs] = [genreIDs copy];
            }
        }

        [parsedResults addObject:item];
    }

    if (outResults) *outResults = [parsedResults copy];
}

#pragma mark - Caching

- (BOOL)_isCacheValid:(NSDictionary *)cacheEntry
{
    NSNumber *timestamp = cacheEntry[@"timestamp"];
    if (!timestamp) return NO;

    NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - [timestamp doubleValue];
    return age < kCacheTTL;
}

- (NSURL *)_cacheDirectory
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cachePath = [[paths firstObject] stringByAppendingPathComponent:kCacheDirectoryName];
    return [NSURL fileURLWithPath:cachePath];
}

- (void)_saveDiskCache:(NSDictionary *)cacheEntry forKey:(NSString *)key rawData:(NSData *)rawData
{
    NSURL *cacheDir = [self _cacheDirectory];
    [[NSFileManager defaultManager] createDirectoryAtURL:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Save the raw JSON data for parsing later
    NSURL *dataFileURL = [cacheDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", key]];
    [rawData writeToURL:dataFileURL atomically:YES];

    // Save the timestamp
    NSURL *metaFileURL = [cacheDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.meta.plist", key]];
    NSDictionary *meta = @{
        @"timestamp": cacheEntry[@"timestamp"] ?: @0,
        @"updated": cacheEntry[@"updated"] ?: @""
    };
    [meta writeToURL:metaFileURL atomically:YES];
}

- (NSDictionary *)_loadDiskCacheForKey:(NSString *)key
{
    NSURL *cacheDir = [self _cacheDirectory];

    NSURL *metaFileURL = [cacheDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.meta.plist", key]];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfURL:metaFileURL];
    if (!meta) return nil;

    NSURL *dataFileURL = [cacheDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", key]];
    NSData *data = [NSData dataWithContentsOfURL:dataFileURL];
    if (!data) return nil;

    NSArray *results = nil;
    NSString *updated = nil;
    [self _parseData:data results:&results updated:&updated error:nil];
    if (!results) return nil;

    return @{
        @"results": results,
        @"updated": updated ?: meta[@"updated"] ?: @"",
        @"timestamp": meta[@"timestamp"] ?: @0
    };
}

#pragma mark - Legacy iTunes RSS API Parsing

- (void)_parseLegacyData:(NSData *)data results:(NSArray **)outResults error:(NSError **)outError
{
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = jsonError ?: [NSError errorWithDomain:@"ApplePodcastChartsErrorDomain" code:-1
                                                              userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON response"}];
        return;
    }

    NSDictionary *feed = json[@"feed"];
    if (!feed || ![feed isKindOfClass:[NSDictionary class]]) {
        if (outError) *outError = [NSError errorWithDomain:@"ApplePodcastChartsErrorDomain" code:-2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Missing feed object"}];
        return;
    }

    NSArray *entries = feed[@"entry"];
    if (!entries || ![entries isKindOfClass:[NSArray class]]) {
        if (outResults) *outResults = @[];
        return;
    }

    NSMutableArray *parsedResults = [NSMutableArray arrayWithCapacity:entries.count];

    for (NSDictionary *entry in entries) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;

        NSMutableDictionary *item = [NSMutableDictionary dictionary];

        // im:name
        NSDictionary *nameObj = entry[@"im:name"];
        if ([nameObj isKindOfClass:[NSDictionary class]]) {
            NSString *name = nameObj[@"label"];
            if ([name isKindOfClass:[NSString class]]) {
                item[kAppleChartsName] = name;
            }
        }

        // im:artist
        NSDictionary *artistObj = entry[@"im:artist"];
        if ([artistObj isKindOfClass:[NSDictionary class]]) {
            NSString *artist = artistObj[@"label"];
            if ([artist isKindOfClass:[NSString class]]) {
                item[kAppleChartsArtistName] = artist;
            }
        }

        // im:image — get largest (last in array, typically 170px)
        NSArray *images = entry[@"im:image"];
        if ([images isKindOfClass:[NSArray class]] && images.count > 0) {
            NSDictionary *largestImage = [images lastObject];
            if ([largestImage isKindOfClass:[NSDictionary class]]) {
                NSString *imageUrl = largestImage[@"label"];
                if ([imageUrl isKindOfClass:[NSString class]]) {
                    item[kAppleChartsArtworkUrl100] = imageUrl;
                }
            }
        }

        // id → attributes.im:id
        NSDictionary *idObj = entry[@"id"];
        if ([idObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *idAttrs = idObj[@"attributes"];
            if ([idAttrs isKindOfClass:[NSDictionary class]]) {
                NSString *podcastId = idAttrs[@"im:id"];
                if ([podcastId isKindOfClass:[NSString class]]) {
                    item[kAppleChartsID] = podcastId;
                }
            }
            NSString *url = idObj[@"label"];
            if ([url isKindOfClass:[NSString class]]) {
                item[kAppleChartsURL] = url;
            }
        }

        // category
        NSDictionary *category = entry[@"category"];
        if ([category isKindOfClass:[NSDictionary class]]) {
            NSDictionary *catAttrs = category[@"attributes"];
            if ([catAttrs isKindOfClass:[NSDictionary class]]) {
                NSString *genreName = catAttrs[@"label"];
                NSString *genreId = catAttrs[@"im:id"];
                if ([genreName isKindOfClass:[NSString class]]) {
                    item[kAppleChartsGenres] = genreName;
                }
                if ([genreId isKindOfClass:[NSString class]]) {
                    item[kAppleChartsGenreIDs] = @[genreId];
                }
            }
        }

        if (item[kAppleChartsName]) {
            [parsedResults addObject:item];
        }
    }

    if (outResults) *outResults = [parsedResults copy];
}

#pragma mark - Genre Disk Cache

- (void)_saveGenreDiskCache:(NSDictionary *)cacheEntry forKey:(NSString *)key
{
    NSURL *cacheDir = [self _cacheDirectory];
    [[NSFileManager defaultManager] createDirectoryAtURL:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *dataFileURL = [cacheDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", key]];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:cacheEntry format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [data writeToURL:dataFileURL atomically:YES];
}

- (NSDictionary *)_loadGenreDiskCacheForKey:(NSString *)key
{
    NSURL *cacheDir = [self _cacheDirectory];
    NSURL *dataFileURL = [cacheDir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", key]];

    NSData *data = [NSData dataWithContentsOfURL:dataFileURL];
    if (!data) return nil;

    NSDictionary *cacheEntry = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![cacheEntry isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *results = cacheEntry[@"results"];
    if (![results isKindOfClass:[NSArray class]]) return nil;

    return cacheEntry;
}

@end
