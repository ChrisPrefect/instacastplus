//
//  CDEpisode.m
//  Instacast
//
//  Created by Martin Hering on 07.08.12.
//
//

#import "CDEpisode.h"
#import "CDChapter.h"
#import "CDFeed.h"
#import "CDMedium.h"
#import "InstacastPlus-Swift.h"

@interface CDEpisode ()
@property (nonatomic, strong) NSString * imageURL_;
@property (nonatomic, strong) NSString * linkURL_;
@property (nonatomic, strong) NSString * paymentURL_;
@property (nonatomic, strong) NSString * deeplinkURL_;
@property (nonatomic, strong) NSString * transcriptsJSON_;
@property (nonatomic, strong) NSArray* showLinks_;
@end

@implementation CDEpisode

static NSObject* ICTranscriptCleanupLock;
static NSMutableSet<NSString*>* ICPendingTranscriptCleanupHashes;
static dispatch_queue_t ICTranscriptCleanupQueue;
static BOOL ICTranscriptCleanupScheduled;

static void ICProcessPendingTranscriptCacheRemovals(void)
{
    while (YES) {
        NSSet<NSString*>* episodeHashes;
        @synchronized (ICTranscriptCleanupLock) {
            episodeHashes = [ICPendingTranscriptCleanupHashes copy];
            [ICPendingTranscriptCleanupHashes removeAllObjects];
            if (episodeHashes.count == 0) {
                ICTranscriptCleanupScheduled = NO;
                return;
            }
        }

        NSString* transcriptCachePath = [[ICTranscriptionPaths transcriptCacheDirectory] path];
        if (transcriptCachePath.length == 0) {
            continue;
        }
        NSFileManager* fileManager = [NSFileManager defaultManager];
        NSArray<NSString*>* fileNames = [fileManager contentsOfDirectoryAtPath:transcriptCachePath error:nil];
        NSInteger removedFileCount = 0;
        for (NSString* fileName in fileNames) {
            if (![[fileName pathExtension] isEqualToString:@"trcache"]) {
                continue;
            }
            NSString* episodeHash = [[fileName componentsSeparatedByString:@"_"] firstObject];
            if (![episodeHashes containsObject:episodeHash]) {
                continue;
            }
            NSString* filePath = [transcriptCachePath stringByAppendingPathComponent:fileName];
            if ([fileManager removeItemAtPath:filePath error:nil]) {
                removedFileCount += 1;
            }
        }
        if (removedFileCount > 0) {
            [[ICDiagnosticLogger shared] logDirectoryEvent:@"cache"
                                                   message:@"Episode-Transcript-Artefakte beim Modell-Update entfernt"
                                                      path:transcriptCachePath
                                                  metadata:@{
                                                      @"episodeHashes": @(episodeHashes.count),
                                                      @"removedFiles": @(removedFileCount),
                                                  }];
        }
    }
}

static void ICScheduleTranscriptCacheRemovalForEpisodeHash(NSString* episodeHash)
{
    if (episodeHash.length == 0) {
        return;
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ICTranscriptCleanupLock = [[NSObject alloc] init];
        ICPendingTranscriptCleanupHashes = [[NSMutableSet alloc] init];
        ICTranscriptCleanupQueue = dispatch_queue_create("com.iteconomy.instacast.transcript-cleanup",
                                                         DISPATCH_QUEUE_SERIAL);
    });
    @synchronized (ICTranscriptCleanupLock) {
        [ICPendingTranscriptCleanupHashes addObject:[episodeHash copy]];
        if (ICTranscriptCleanupScheduled) {
            return;
        }
        ICTranscriptCleanupScheduled = YES;
        dispatch_async(ICTranscriptCleanupQueue, ^{
            ICProcessPendingTranscriptCacheRemovals();
        });
    }
}

//@synthesize temporarySavedProperities;

- (void) reconstructObjectHash
{
    self.objectHash = [[NSString stringWithFormat:@"%@%@", [self.feed.sourceURL absoluteString], self.guid] MD5Hash];
}

- (NSString*) designatedUID
{
    if (!self.objectHash) {
        [self reconstructObjectHash];
    }
    
    return self.objectHash;
}

- (NSSet*) keyPathesForValuesNotToBeLogged
{
    return [NSSet setWithObjects:@"fulltext", @"lastDownloaded",nil];
}

@dynamic objectHash;
@dynamic title;
@dynamic subtitle;
@dynamic guid;
@dynamic pubDate;
@dynamic imageURL_;
@dynamic linkURL_;
@dynamic author;
@dynamic summary;
@dynamic fulltext;
@dynamic transcriptsJSON_;
@dynamic paymentURL_;
@dynamic deeplinkURL_;
@dynamic video;
@dynamic explicitContent;
@dynamic duration;
@dynamic lastPlayed;
@dynamic consumed;
@dynamic starred;
@dynamic archived;
@dynamic position;
@dynamic lastDownloaded;

@dynamic timeLeft;
@dynamic downloaded;

@dynamic feed;
@dynamic media;
@dynamic chapters;
@dynamic episodeLists;

@synthesize showLinks_;


- (NSURL*) deeplinkURL
{
    if (self.deeplinkURL_) {
        return [NSURL URLWithString:self.deeplinkURL_];
    }
    return nil;
}

- (void) setDeeplinkURL:(NSURL *)deeplinkURL
{
    self.deeplinkURL_ = [deeplinkURL absoluteString];
}

- (NSURL*) linkURL
{
    if (self.linkURL_) {
        return [NSURL URLWithString:self.linkURL_];
    }
    return nil;
}

- (void) setLinkURL:(NSURL *)linkURL
{
    self.linkURL_ = [linkURL absoluteString];
}

- (NSURL*) paymentURL
{
    if (self.paymentURL_) {
        return [NSURL URLWithString:self.paymentURL_];
    }
    return nil;
}

- (void) setPaymentURL:(NSURL *)paymentURL
{
    self.paymentURL_ = [paymentURL absoluteString];
}

- (NSURL*) imageURL
{
    if (self.imageURL_) {
        return [NSURL URLWithString:self.imageURL_];
    }
    return nil;
}

- (void) setImageURL:(NSURL *)imageURL
{
    self.imageURL_ = [imageURL absoluteString];
}

- (NSArray*) transcripts
{
    NSString* raw = self.transcriptsJSON_;
    if (raw.length == 0) {
        return @[];
    }

    NSData* data = [raw dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        return @[];
    }

    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([object isKindOfClass:[NSArray class]]) {
        return object;
    }

    return @[];
}

- (void) setTranscripts:(NSArray *)transcripts
{
    if (transcripts.count == 0) {
        self.transcriptsJSON_ = nil;
        return;
    }

    NSMutableArray* normalized = [NSMutableArray arrayWithCapacity:transcripts.count];
    for (id item in transcripts) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSDictionary* dict = (NSDictionary*)item;
        NSString* url = [dict[@"url"] isKindOfClass:[NSString class]] ? dict[@"url"] : nil;
        if (url.length == 0) {
            continue;
        }

        NSMutableDictionary* entry = [NSMutableDictionary dictionaryWithObject:url forKey:@"url"];
        NSString* type = [dict[@"type"] isKindOfClass:[NSString class]] ? dict[@"type"] : nil;
        NSString* language = [dict[@"language"] isKindOfClass:[NSString class]] ? dict[@"language"] : nil;
        NSString* rel = [dict[@"rel"] isKindOfClass:[NSString class]] ? dict[@"rel"] : nil;
        NSString* title = [dict[@"title"] isKindOfClass:[NSString class]] ? dict[@"title"] : nil;
        NSString* fallbackURL = [dict[@"fallbackURL"] isKindOfClass:[NSString class]] ? dict[@"fallbackURL"] : nil;
        NSString* href = [dict[@"href"] isKindOfClass:[NSString class]] ? dict[@"href"] : nil;

        if (type.length > 0) {
            entry[@"type"] = type;
        }
        if (language.length > 0) {
            entry[@"language"] = language;
        }
        if (rel.length > 0) {
            entry[@"rel"] = rel;
        }
        if (title.length > 0) {
            entry[@"title"] = title;
        }
        if (fallbackURL.length > 0) {
            entry[@"fallbackURL"] = fallbackURL;
        }
        if (href.length > 0) {
            entry[@"href"] = href;
        }

        [normalized addObject:entry];
    }

    if (normalized.count == 0) {
        self.transcriptsJSON_ = nil;
        return;
    }

    NSData* data = [NSJSONSerialization dataWithJSONObject:normalized options:0 error:nil];
    self.transcriptsJSON_ = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void) setArchived:(BOOL)archived
{
    BOOL wasArchived = self.archived;
    if (wasArchived == archived) {
        return;
    }
    [self willChangeValueForKey:@"archived"];
    [self setPrimitiveValue:@(archived) forKey:@"archived"];
    [self didChangeValueForKey:@"archived"];
}

- (void) setConsumed:(BOOL)consumed
{
    BOOL wasConsumed = self.consumed;
    if (wasConsumed == consumed) {
        return;
    }
    [self willChangeValueForKey:@"consumed"];
    [self setPrimitiveValue:@(consumed) forKey:@"consumed"];
    [self didChangeValueForKey:@"consumed"];

    if (consumed && !wasConsumed) {
        ICScheduleTranscriptCacheRemovalForEpisodeHash(self.objectHash);
    }
}

- (void) setStarred:(BOOL)starred
{
    BOOL wasStarred = self.starred;
    if (wasStarred == starred) {
        return;
    }
    [self willChangeValueForKey:@"starred"];
    [self setPrimitiveValue:@(starred) forKey:@"starred"];
    [self didChangeValueForKey:@"starred"];
}

- (void) setDownloaded:(BOOL)downloaded {
    // willChange/didChange must pair up — the willACCESS here left KVO unbalanced.
    [self willChangeValueForKey:@"downloaded"];
    [self setPrimitiveValue:@(downloaded) forKey:@"downloaded"];
    [self didChangeValueForKey:@"downloaded"];
    [self.feed invalidateDownloadedCount];
}

- (void) setFeed:(CDFeed *)feed
{
    CDFeed* previousFeed = self.feed;
    if (previousFeed == feed) {
        return;
    }
    [self willChangeValueForKey:@"feed"];
    [self setPrimitiveValue:feed forKey:@"feed"];
    [self didChangeValueForKey:@"feed"];
}

#pragma mark -

- (CDMedium*) preferedMedium
{
    NSSet* mediaItems = self.media;
	if ([mediaItems count] == 0) {
		return nil;
	}
    
    NSArray* preferredMediaTypes = [NSArray arrayWithObjects:@"audio/x-m4a", @"video/mp4", @"video/x-m4v", @"audio/mpeg", nil];
    
    NSMutableArray* filteredItems = [[NSMutableArray alloc] init];
	for(CDMedium* media in mediaItems) {
        if ([preferredMediaTypes containsObject:media.mimeType]) {
            [filteredItems addObject:media];
		}
	}
	
    CDMedium* mediaWithBiggestFileSize = nil;
    for(CDMedium* media in filteredItems) {
        if (media.byteSize > mediaWithBiggestFileSize.byteSize) {
            mediaWithBiggestFileSize = media;
        }
    }
    
    if (mediaWithBiggestFileSize) {
        return mediaWithBiggestFileSize;
    }
    
	for(CDMedium* media in mediaItems) {
		if ([media.mimeType rangeOfString:@"audio" options:NSCaseInsensitiveSearch].location != NSNotFound ||
			[media.mimeType rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound) {
			return media;
		}
	}
    
    CDMedium* media = [mediaItems anyObject];
    
    if ([media.mimeType hasPrefix:@"image"]) {
        return nil;
    }
	
	return media;
}

- (NSArray*) sortedChapters
{
    return [self.chapters sortedArrayUsingDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"index" ascending:YES]]];
}

- (NSString*) objectHash
{
    [self willAccessValueForKey:@"objectHash"];
    NSString* objectHash = [self primitiveValueForKey:@"objectHash"];
    [self didAccessValueForKey:@"objectHash"];
    
    if (!objectHash) {
        objectHash = [[NSString stringWithFormat:@"%@%@", [self.feed.sourceURL absoluteString], self.guid] MD5Hash];
    }
    
    return objectHash;
}

+ (NSSet*) keyPathsForValuesAffectingTimeLeft
{
    return [NSSet setWithObjects:@"duration", @"position",nil];
}


- (int32_t) timeLeft {
    [self willAccessValueForKey:@"timeLeft"];
    int32_t timeLeft = MAX(0, self.duration - self.position);
    [self didAccessValueForKey:@"timeLeft"];
    return timeLeft;
}


/*
- (void) setNotAvailable
{
    self.feed = nil;
    self.title = nil;
    self.author = nil;
    self.deeplinkURL = nil;
    self.fulltext = nil;
    self.imageURL = nil;
    self.lastDownloaded = nil;
    self.lastPlayed = nil;
    self.linkURL = nil;
    self.paymentURL = nil;
    self.pubDate = nil;
    self.subtitle = nil;
    self.summary = nil;
    
    for(NSManagedObject* object in [self.media copy]) {
        [self.managedObjectContext deleteObject:object];
    }
    
    for(NSManagedObject* object in [self.chapters copy]) {
        [self.managedObjectContext deleteObject:object];
    }
}
*/

@end
