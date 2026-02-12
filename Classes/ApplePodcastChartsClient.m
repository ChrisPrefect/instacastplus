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

- (void)fetchTopPodcastsWithCountryCode:(NSString *)countryCode
                                  limit:(NSInteger)limit
                             completion:(void (^)(NSArray *results, NSString *updated, NSError *error))completion
{
    if (!countryCode) {
        countryCode = [self defaultCountryCode];
    }
    countryCode = [countryCode lowercaseString];

    // Clamp limit to valid values
    if (limit <= 10) {
        limit = 10;
    } else if (limit <= 25) {
        limit = 25;
    } else {
        limit = 50;
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%@_%ld", countryCode, (long)limit];

    // 1. Check memory cache
    NSDictionary *cached = [self.memoryCache objectForKey:cacheKey];
    if (cached && [self _isCacheValid:cached]) {
        if (completion) {
            completion(cached[@"results"], cached[@"updated"], nil);
        }
        return;
    }

    // 2. Check disk cache
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

        // Parse genres into comma-separated string
        NSArray *genres = entry[@"genres"];
        if ([genres isKindOfClass:[NSArray class]] && genres.count > 0) {
            NSMutableArray *genreNames = [NSMutableArray array];
            for (NSDictionary *genre in genres) {
                if ([genre isKindOfClass:[NSDictionary class]]) {
                    NSString *genreName = genre[@"name"];
                    if ([genreName isKindOfClass:[NSString class]]) {
                        [genreNames addObject:genreName];
                    }
                }
            }
            if (genreNames.count > 0) {
                item[kAppleChartsGenres] = [genreNames componentsJoinedByString:@", "];
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

@end
