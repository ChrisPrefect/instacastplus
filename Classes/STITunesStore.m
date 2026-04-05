//
//  STITunesStoreManager.m
//  Snowtape
//
//  Created by Martin Hering on 01.05.09.
//  Copyright 2009 vemedio. All rights reserved.
//

//#import "NSString_CleanTrackTitle.h"
#import "STITunesStore.h"

NSString* kiTunesStoreKind = @"kiTunesStoreKind";
NSString* kiTunesStoreTitleLink = @"kiTunesStoreTitleLink";
NSString* kiTunesStoreTitle = @"kiTunesStoreTitle";
NSString* kiTunesStoreAlbumLink = @"kiTunesStoreAlbumLink";
NSString* kiTunesStoreAlbum = @"kiTunesStoreAlbum";
NSString* kiTunesStoreArtistLink = @"kiTunesStoreArtistLink";
NSString* kiTunesStoreArtist = @"kiTunesStoreArtist";
NSString* kiTunesStoreTrackPrice = @"kiTunesStoreTrackPrice";
NSString* kiTunesStoreTrackPriceCurrency = @"kiTunesStoreTrackPriceCurrency";
NSString* kiTunesStorePreviewLink = @"kiTunesStorePreviewLink";
NSString* kiTunesStoreFeedURL = @"kiTunesStoreFeedURL";

NSString* kiTunesStoreArtwork60 = @"kiTunesStoreArtwork60";
NSString* kiTunesStoreArtwork100 = @"kiTunesStoreArtwork100";
NSString* kiTunesStoreArtwork170 = @"kiTunesStoreArtwork170";

NSString* kiTunesStoreSongKind = @"song";
NSString* kiTunesStoreMusicVideoKind = @"music-video";

NSString* kiTunesStoreTrackId = @"kiTunesStoreTrackId";
NSString* kiTunesStoreCollectionId = @"kiTunesStoreCollectionId";

@interface STITunesStore ()
@property (nonatomic, strong) NSMutableData* connectionData;
@property (nonatomic, strong) NSURLSessionDataTask* dataTask;
@property (nonatomic, strong) id connectionDelegate;
@end


@implementation STITunesStore

- (id) init
{
	if ((self = [super init]))
	{
		_storeLocale = [NSLocale currentLocale];
		_media = @"music";
		_entity = @"musicTrack";
	}

	return self;
}

- (NSURLRequest*) _urlRequestForSearchString:(NSString*)searchString
{
    NSString* encodedSearchString = [searchString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];


	if ([encodedSearchString length] == 0) {
		return nil;
	}

	NSString* countryCode = [self.storeLocale objectForKey:NSLocaleCountryCode];

	NSMutableString* searchURLString = [NSMutableString stringWithFormat:@"https://itunes.apple.com/search?media=%@", self.media];
	if (self.entity) {
		[searchURLString appendFormat:@"&entity=%@", self.entity];
	}
	if (self.attribute) {
		[searchURLString appendFormat:@"&attribute=%@", self.attribute];
	}
	if (countryCode) {
		[searchURLString appendFormat:@"&country=%@", countryCode];
	}
	if (encodedSearchString) {
		[searchURLString appendFormat:@"&term=%@", encodedSearchString];
	}

	return [NSURLRequest requestWithURL:[NSURL URLWithString:searchURLString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0f];
}

- (NSArray*) _searchResultsForData:(NSData*)data
{
    NSError* error = nil;
    NSDictionary* dictionary = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!dictionary) {
        ErrLog(@"%@", [error description]);
        return nil;
    }


	NSMutableArray* items = [NSMutableArray array];

	NSArray* results = [dictionary objectForKey:@"results"];
	for(NSDictionary* result in results)
	{
		NSMutableDictionary* item = [NSMutableDictionary dictionary];

		if ([result objectForKey:@"trackId"]) {
			[item setObject:[result objectForKey:@"trackId"] forKey:kiTunesStoreTrackId];
		}

		if ([result objectForKey:@"collectionId"]) {
			[item setObject:[result objectForKey:@"collectionId"] forKey:kiTunesStoreCollectionId];
		}

        if ([result objectForKey:@"trackName"]) {
            [item setObject:[result objectForKey:@"trackName"] forKey:kiTunesStoreTitle];
        }

		NSString* link = [result objectForKey:@"trackViewUrl"];
		if (link && ![link isKindOfClass:[NSNull class]]) {
			[item setObject:link forKey:kiTunesStoreTitleLink];
		}

        if ([result objectForKey:@"collectionName"]) {
            [item setObject:[result objectForKey:@"collectionName"] forKey:kiTunesStoreAlbum];
        }

		link = [result objectForKey:@"collectionViewUrl"];
		if (link && ![link isKindOfClass:[NSNull class]]) {
			[item setObject:link forKey:kiTunesStoreAlbumLink];
		}

        if ([result objectForKey:@"artistName"]) {
            [item setObject:[result objectForKey:@"artistName"] forKey:kiTunesStoreArtist];
        }

		link = [result objectForKey:@"artistViewUrl"];
		if (link && ![link isKindOfClass:[NSNull class]]) {
			[item setObject:link forKey:kiTunesStoreArtistLink];
		}

        if ([result objectForKey:@"artworkUrl60"]) {
            [item setObject:[result objectForKey:@"artworkUrl60"] forKey:kiTunesStoreArtwork60];
        }

        if ([result objectForKey:@"artworkUrl100"]) {
            [item setObject:[result objectForKey:@"artworkUrl100"] forKey:kiTunesStoreArtwork100];
        }

		NSString* link100 = [result objectForKey:@"artworkUrl100"];
        if (link100) {
            NSString* link170 = [[[link100 stringByDeletingPathExtension] stringByDeletingPathExtension] stringByAppendingPathExtension:@"170x170-75.jpg"];
            [item setObject:link170 forKey:kiTunesStoreArtwork170];
        }

		if ([result objectForKey:@"kind"]) {
            [item setObject:[result objectForKey:@"kind"] forKey:kiTunesStoreKind];
        }
        if ([result objectForKey:@"trackPrice"]) {
            [item setObject:[result objectForKey:@"trackPrice"] forKey:kiTunesStoreTrackPrice];
        }
        if ([result objectForKey:@"currency"]) {
            [item setObject:[result objectForKey:@"currency"] forKey:kiTunesStoreTrackPriceCurrency];
        }
        if ([result objectForKey:@"previewUrl"]) {
            [item setObject:[result objectForKey:@"previewUrl"] forKey:kiTunesStorePreviewLink];
        }

        if ([result objectForKey:@"feedUrl"]) {
            NSString* feedURLString = [result objectForKey:@"feedUrl"];
            NSURL* feedURL = [NSURL URLWithString:feedURLString];
            if (feedURL) {
                [item setObject:feedURL forKey:kiTunesStoreFeedURL];
            }
        }

		//DebugLog(@"%@ %@",[result description], link170);

		[items addObject:item];
	}

	return items;
}

- (NSArray*) storeSearchResultForSearchString:(NSString*)searchString
{
	NSURLRequest* request = [self _urlRequestForSearchString:searchString];
	if (!request) {
		return nil;
	}

	__block NSData* resultData = nil;
	__block NSHTTPURLResponse* response = nil;
	__block NSError* error = nil;

	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
		resultData = data;
		response = (NSHTTPURLResponse*)resp;
		error = err;
		dispatch_semaphore_signal(semaphore);
	}];
	[task resume];

	dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

	if (error || [response statusCode] != 200) {
		return nil;
	}

	return [self _searchResultsForData: resultData];
}


- (void) startStoreSearchForSearchString:(NSString*)searchString delegate:(id)delegate
{
    self.searchTerm = searchString;

	NSURLRequest* request = [self _urlRequestForSearchString:searchString];
	if (request) {
		self.connectionDelegate = delegate;
		self.connectionData = [[NSMutableData alloc] init];

		__weak typeof(self) weakSelf = self;
		self.dataTask = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				if (error) {
					if (weakSelf.connectionDelegate && [weakSelf.connectionDelegate respondsToSelector:@selector(itunesStore:didEndWithError:)]) {
						[weakSelf.connectionDelegate itunesStore:weakSelf didEndWithError:error];
					}
				} else {
					NSArray* searchResults = [weakSelf _searchResultsForData:data];
					if (weakSelf.connectionDelegate && [weakSelf.connectionDelegate respondsToSelector:@selector(itunesStore:didFindSearchResults:)]) {
						[weakSelf.connectionDelegate itunesStore:weakSelf didFindSearchResults:searchResults];
					}
				}
				weakSelf.dataTask = nil;
				weakSelf.connectionDelegate = nil;
			});
		}];
		[self.dataTask resume];
	}
	else {
		if (delegate && [delegate respondsToSelector:@selector(itunesStore:didEndWithError:)]) {
            NSError* error = [NSError errorWithDomain:@"ITunesStoreErrorDomain"
                                                 code:0
                                             userInfo:[NSDictionary dictionaryWithObject:@"Search term is too short." forKey:NSLocalizedDescriptionKey]];
			[delegate itunesStore:self didEndWithError:error];
		}
	}
}

- (void) cancelStoreSearch
{
	[self.dataTask cancel];
	self.dataTask = nil;
}


#pragma mark -

- (NSArray*) storeItemsForTitle:(NSString*)title artist:(NSString*)artist
{
	NSArray* storeItems = [self storeSearchResultForSearchString:((artist) ? [NSString stringWithFormat:@"%@ %@",artist, title] : title)];
	//DebugLog(@"%@",[storeItems description]);
	return storeItems;
}

- (NSArray*) storeItemsForArtist:(NSString*)artist
{
	NSArray* storeItems = [self storeSearchResultForSearchString:artist];
	//DebugLog(@"%@",[storeItems description]);
	return storeItems;
}

- (NSArray*) storeItemsForAlbum:(NSString*)album
{
	NSArray* storeItems = [self storeSearchResultForSearchString:album];
	//DebugLog(@"%@",[storeItems description]);
	return storeItems;
}

#if TARGET_OS_IPHONE
- (UIImage*) imageForStoreLink:(NSString*)link
{
	NSURLRequest* imageRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:link]];

	__block NSData* imageData = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:imageRequest completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
		imageData = data;
		dispatch_semaphore_signal(semaphore);
	}];
	[task resume];

	dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

	if (!imageData) {
		return nil;
	}

	return [[UIImage alloc] initWithData:imageData];
}
#else
- (NSImage*) imageForStoreLink:(NSString*)link
{
	NSURLRequest* imageRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:link]];

	__block NSData* imageData = nil;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

	NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:imageRequest completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
		imageData = data;
		dispatch_semaphore_signal(semaphore);
	}];
	[task resume];

	dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));

	if (!imageData) {
		return nil;
	}

	return [[NSImage alloc] initWithData:imageData];
}
#endif

@end
