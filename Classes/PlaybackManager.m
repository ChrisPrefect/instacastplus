//
//  PlaybackManager.m
//  Instacast
//
//  Created by Martin Hering on 05.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_IPHONE
#import <MediaPlayer/MediaPlayer.h>
#import <CarPlay/CarPlay.h>
#import "PlayerView.h"
#else
#import "AudioSession_OSX.h"
#import "ICPlayerView_OSX.h"
#import "PlaybackManager+Mikey.h"
#import "PlaybackManager+AudioDevice.h"
#import "PlaybackManager+RemoteControl.h"
#import "ICSharingManager.h"
#endif



#import "ImageFunctions.h"
#import "InstacastPlus-Swift.h"
#import "CDModel.h"
#import "CDEpisode+ShowNotes.h"
#import "CDChapter.h"
#import "ICMetadataParser.h"
#import "ICImageCacheOperation.h"
#import "CacheManager.h"
#import <MediaPlayer/MediaPlayer.h>

#define SEND_UPDATE [self _sendUpdateNotification];

static NSString* const ICGeneratedSponsorSkipName = @"__ICGeneratedSponsor__";

#if !TARGET_OS_IPHONE
#ifdef __MAC_10_9
#define ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR 1
#endif
#endif

NSString* PlaybackManagerDidStartNotification = @"MPPlaybackManagerDidStartNotification";
NSString* PlaybackManagerDidEndNotification = @"MPPlaybackManagerDidEndNotification";
NSString* PlaybackManagerDidUpdateNotification = @"MPPlaybackManagerDidUpdateNotification";
NSString* PlaybackManagerDidChangeEpisodeNotification = @"MPPlaybackManagerDidChangeEpisodeNotification";
NSString* PlaybackManagerEpisodeDidFinishNotification = @"MPPlaybackManagerEpisodeDidFinishNotification";


#if TARGET_OS_IPHONE
static NSString* kMediaItemInstacastCurrentArtwork =  @"Instacast_currentArtwork";
static NSString* kMediaItemInstacastEpisodeHash =  @"Instacast_episodeHash";
#endif

static NSString* kDefaultTemporaryPlaybackPositions = @"TemporaryPlaybackPositions";
static NSString* kDefaultPlaybackVolume = @"PlaybackVolume";

enum {
	IdleState,
	InitializedState,
	ShouldRunState,
	RunningState,
	VideoPausedInBackground
};

#if TARGET_OS_IPHONE
typedef struct {
    int64_t start;
    int64_t end; // exclusive
} ICStreamByteRange;

static ICStreamByteRange ICStreamByteRangeMake(int64_t start, int64_t end)
{
    ICStreamByteRange range;
    range.start = start;
    range.end = end;
    return range;
}

static BOOL ICStreamByteRangeIsValid(ICStreamByteRange range)
{
    return (range.end > range.start && range.start >= 0);
}

static NSValue* ICStreamRangeValue(ICStreamByteRange range)
{
    return [NSValue valueWithBytes:&range objCType:@encode(ICStreamByteRange)];
}

static ICStreamByteRange ICStreamRangeFromValue(NSValue* value)
{
    ICStreamByteRange range = ICStreamByteRangeMake(0, 0);
    [value getValue:&range];
    return range;
}

static void ICStreamMergeRangeIntoArray(NSMutableArray<NSValue*>* ranges, ICStreamByteRange newRange)
{
    if (!ICStreamByteRangeIsValid(newRange)) {
        return;
    }

    NSInteger insertIndex = ranges.count;
    for (NSInteger i = 0; i < (NSInteger)ranges.count; i++) {
        ICStreamByteRange existing = ICStreamRangeFromValue(ranges[i]);
        if (newRange.end < existing.start) {
            insertIndex = i;
            break;
        }
        if (newRange.start > existing.end) {
            continue;
        }

        newRange.start = MIN(newRange.start, existing.start);
        newRange.end = MAX(newRange.end, existing.end);
        [ranges removeObjectAtIndex:i];
        i--;
        insertIndex = i + 1;
    }

    [ranges insertObject:ICStreamRangeValue(newRange) atIndex:MAX(0, insertIndex)];
}

static int64_t ICStreamContiguousEndForOffset(NSArray<NSValue*>* ranges, int64_t offset)
{
    if (offset < 0) {
        return 0;
    }
    for (NSValue* value in ranges) {
        ICStreamByteRange range = ICStreamRangeFromValue(value);
        if (offset < range.start) {
            return offset;
        }
        if (offset >= range.start && offset < range.end) {
            return range.end;
        }
    }
    return offset;
}

static NSString* const ICStreamingCacheScheme = @"instacast-stream-cache";
static const int64_t ICStreamingHighPriorityChunkSize = 512 * 1024;
static const int64_t ICStreamingBackfillChunkSize = 512 * 1024;
static const void* ICStreamingQueueSpecific = &ICStreamingQueueSpecific;

@interface CacheManager (PlaybackStreamCache)
- (NSURL*)tempURLForCachedEpisode:(CDEpisode*)episode;
@end

static NSMutableSet* ICStreamingDetachedLoaderSet(void)
{
    static NSMutableSet* detachedLoaders = nil;
    static dispatch_once_t onceToken = 0;
    dispatch_once(&onceToken, ^{
        detachedLoaders = [[NSMutableSet alloc] init];
    });
    return detachedLoaders;
}

@interface ICStreamingCacheLoader : NSObject <AVAssetResourceLoaderDelegate, NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, strong, readonly) NSURL* assetURL;
@property (nonatomic, strong, readonly) dispatch_queue_t resourceLoaderQueue;
@property (nonatomic, readonly, getter=isCacheComplete) BOOL cacheComplete;
@property (nonatomic, copy) void (^progressChangeHandler)(double progress, BOOL cacheComplete);
- (instancetype)initWithEpisode:(CDEpisode*)episode
                      remoteURL:(NSURL*)remoteURL
                   expectedSize:(int64_t)expectedSize
                       mimeType:(NSString*)mimeType
                       username:(NSString*)username
                       password:(NSString*)password;
- (void)detachFromPlaybackAndContinueCaching;
- (void)stop;
- (void)cancelAndDiscardPartialCache;
- (BOOL)matchesEpisodeHash:(NSString*)episodeHash;
+ (BOOL)cancelDetachedLoaderForEpisodeHash:(NSString*)episodeHash;
@end

@interface ICStreamingCacheLoader ()
@property (nonatomic, strong) CDEpisode* episode;
@property (nonatomic, strong) NSURL* remoteURL;
@property (nonatomic, strong) NSURL* tempURL;
@property (nonatomic, strong) NSURL* readURL;
@property (nonatomic, strong) NSString* username;
@property (nonatomic, strong) NSString* password;
@property (nonatomic, strong) NSString* mimeType;
@property (nonatomic, strong) NSString* contentType;
@property (nonatomic) int64_t contentLength;
@property (nonatomic) int64_t hintedContentLength;
@property (nonatomic) BOOL contentLengthConfirmed;
@property (nonatomic) BOOL supportsByteRange;
@property (nonatomic) BOOL stopped;
@property (nonatomic) BOOL cacheCoverageComplete;
@property (nonatomic) BOOL cacheImportStarted;
@property (nonatomic) BOOL cacheImportFinished;
@property (nonatomic, strong) NSFileHandle* writeHandle;
@property (nonatomic, strong) NSMutableArray<NSValue*>* downloadedRanges;
@property (nonatomic, strong) NSMutableArray<NSValue*>* highPriorityRanges;
@property (nonatomic, strong) NSMutableArray<AVAssetResourceLoadingRequest*>* pendingRequests;
@property (nonatomic, strong) NSURLSession* session;
@property (nonatomic, strong) NSURLSessionDataTask* activeTask;
@property (nonatomic) ICStreamByteRange activeRange;
@property (nonatomic) int64_t activeWriteOffset;
@property (nonatomic, strong) dispatch_queue_t resourceLoaderQueue;
@property (nonatomic, strong) NSURL* assetURL;
@property (nonatomic) double lastNotifiedProgress;
@property (nonatomic) BOOL lastNotifiedComplete;
@end

@implementation ICStreamingCacheLoader

- (instancetype)initWithEpisode:(CDEpisode*)episode
                      remoteURL:(NSURL*)remoteURL
                   expectedSize:(int64_t)expectedSize
                       mimeType:(NSString*)mimeType
                       username:(NSString*)username
                       password:(NSString*)password
{
    if ((self = [super init])) {
        _episode = episode;
        _remoteURL = remoteURL;
        _contentLength = 0;
        _hintedContentLength = expectedSize;
        _contentLengthConfirmed = NO;
        _mimeType = mimeType;
        _username = username;
        _password = password;
        _downloadedRanges = [[NSMutableArray alloc] init];
        _highPriorityRanges = [[NSMutableArray alloc] init];
        _pendingRequests = [[NSMutableArray alloc] init];

        NSString* hash = (episode.objectHash.length > 0) ? episode.objectHash : [[NSUUID UUID] UUIDString];
        _assetURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@", ICStreamingCacheScheme, hash]];
        _resourceLoaderQueue = dispatch_queue_create([[NSString stringWithFormat:@"com.vemedio.instacast.streamcache.%@", hash] UTF8String], DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_resourceLoaderQueue, ICStreamingQueueSpecific, (void*)ICStreamingQueueSpecific, NULL);

        CacheManager* cacheManager = [CacheManager sharedCacheManager];
        _tempURL = [cacheManager tempURLForCachedEpisode:episode];
        _readURL = _tempURL;

        [self _prepareTempFile];

        NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

        NSOperationQueue* delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.qualityOfService = NSOperationQualityOfServiceUserInitiated;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:delegateQueue];

        _contentType = [self _contentTypeForMIMEType:mimeType];
    }
    return self;
}

- (void)dealloc
{
    [self stop];
}

- (BOOL)matchesEpisodeHash:(NSString*)episodeHash
{
    return (episodeHash.length > 0 && [self.episode.objectHash isEqualToString:episodeHash]);
}

+ (BOOL)cancelDetachedLoaderForEpisodeHash:(NSString*)episodeHash
{
    if (episodeHash.length == 0) {
        return NO;
    }

    ICStreamingCacheLoader* matchingLoader = nil;
    NSMutableSet* detachedSet = ICStreamingDetachedLoaderSet();
    @synchronized(detachedSet) {
        for (ICStreamingCacheLoader* loader in [detachedSet copy]) {
            if ([loader matchesEpisodeHash:episodeHash]) {
                matchingLoader = loader;
                [detachedSet removeObject:loader];
                break;
            }
        }
    }

    if (!matchingLoader) {
        return NO;
    }

    [matchingLoader cancelAndDiscardPartialCache];
    return YES;
}

- (BOOL)isCacheComplete
{
    return self.cacheCoverageComplete;
}

- (void)_releaseDetachedRetentionIfPossible
{
    if (!self.cacheImportFinished && !self.stopped) {
        return;
    }

    NSMutableSet* detachedSet = ICStreamingDetachedLoaderSet();
    @synchronized(detachedSet) {
        [detachedSet removeObject:self];
    }
}

- (void)detachFromPlaybackAndContinueCaching
{
    dispatch_async(self.resourceLoaderQueue, ^{
        if (self.stopped || self.cacheCoverageComplete) {
            return;
        }

        NSMutableSet* detachedSet = ICStreamingDetachedLoaderSet();
        @synchronized(detachedSet) {
            [detachedSet addObject:self];
        }

        NSError* cancelError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        for (AVAssetResourceLoadingRequest* request in [self.pendingRequests copy]) {
            [request finishLoadingWithError:cancelError];
        }
        [self.pendingRequests removeAllObjects];

        [self _notifyProgressIfNeededForce:NO];
        [self _pumpDownloads];
    });
}

- (void)stop
{
    void (^stopBlock)(void) = ^{
        if (self.stopped) {
            return;
        }
        self.stopped = YES;

        NSError* cancelError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        for (AVAssetResourceLoadingRequest* request in [self.pendingRequests copy]) {
            [request finishLoadingWithError:cancelError];
        }
        [self.pendingRequests removeAllObjects];
        [self.highPriorityRanges removeAllObjects];

        [self.activeTask cancel];
        self.activeTask = nil;
        [self.session invalidateAndCancel];
        self.session = nil;

        [self.writeHandle closeFile];
        self.writeHandle = nil;
        self.cacheImportFinished = YES;
        self.cacheCoverageComplete = YES;
        [self _notifyProgressIfNeededForce:YES];
        [self _releaseDetachedRetentionIfPossible];
    };

    if (dispatch_get_specific(ICStreamingQueueSpecific)) {
        stopBlock();
    } else {
        dispatch_sync(self.resourceLoaderQueue, stopBlock);
    }
}

- (void)cancelAndDiscardPartialCache
{
    NSURL* tempURL = self.tempURL;
    self.progressChangeHandler = nil;
    [self stop];
    if (tempURL) {
        [[NSFileManager defaultManager] removeItemAtURL:tempURL error:nil];
    }
}

- (void)_prepareTempFile
{
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* tempPath = self.tempURL.path;
    NSString* tempDirectory = [tempPath stringByDeletingLastPathComponent];
    [fileManager createDirectoryAtPath:tempDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    [fileManager removeItemAtPath:tempPath error:nil];
    [fileManager createFileAtPath:tempPath contents:[NSData data] attributes:nil];
    self.writeHandle = [NSFileHandle fileHandleForWritingAtPath:tempPath];
}

- (NSString*)_contentTypeForMIMEType:(NSString*)mimeType
{
    if (mimeType.length == 0) {
        return nil;
    }
    NSString* lowerMime = [mimeType lowercaseString];
    if ([lowerMime isEqualToString:@"audio/mpeg"]) {
        return @"public.mp3";
    }
    if ([lowerMime isEqualToString:@"audio/m4a"] ||
        [lowerMime isEqualToString:@"audio/mp4"] ||
        [lowerMime isEqualToString:@"audio/x-m4a"] ||
        [lowerMime isEqualToString:@"audio/mpeg4"]) {
        return @"public.mpeg-4-audio";
    }
    if ([lowerMime hasPrefix:@"video/"]) {
        return @"public.mpeg-4";
    }
    return nil;
}

- (double)_currentCoverageProgress
{
    int64_t targetLength = (self.contentLengthConfirmed && self.contentLength > 0) ? self.contentLength : self.hintedContentLength;
    if (targetLength <= 0) {
        return 0.0;
    }

    int64_t downloadedLength = 0;
    for (NSValue* value in self.downloadedRanges) {
        ICStreamByteRange range = ICStreamRangeFromValue(value);
        if (!ICStreamByteRangeIsValid(range)) {
            continue;
        }
        int64_t clippedStart = MAX((int64_t)0, range.start);
        int64_t clippedEnd = MIN(targetLength, range.end);
        if (clippedEnd > clippedStart) {
            downloadedLength += (clippedEnd - clippedStart);
        }
    }

    double progress = (double)downloadedLength / (double)targetLength;
    return MIN(MAX(progress, 0.0), 1.0);
}

- (void)_notifyProgressIfNeededForce:(BOOL)force
{
    if (!self.progressChangeHandler) {
        return;
    }

    double progress = [self _currentCoverageProgress];
    BOOL complete = self.cacheCoverageComplete;
    BOOL progressChanged = (fabs(progress - self.lastNotifiedProgress) >= 0.003);
    BOOL completionChanged = (complete != self.lastNotifiedComplete);
    if (!force && !progressChanged && !completionChanged) {
        return;
    }

    self.lastNotifiedProgress = progress;
    self.lastNotifiedComplete = complete;

    void (^handler)(double, BOOL) = [self.progressChangeHandler copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(progress, complete);
    });
}

- (void)_enqueueHighPriorityRangeFrom:(int64_t)start to:(int64_t)end
{
    int64_t maxLength = (self.contentLengthConfirmed && self.contentLength > 0) ? self.contentLength : self.hintedContentLength;
    if (maxLength > 0) {
        end = MIN(end, maxLength);
    }
    if (end <= start) {
        return;
    }
    ICStreamMergeRangeIntoArray(self.highPriorityRanges, ICStreamByteRangeMake(start, end));
}

- (ICStreamByteRange)_dequeueHighPriorityChunk
{
    while (self.highPriorityRanges.count > 0) {
        ICStreamByteRange range = ICStreamRangeFromValue(self.highPriorityRanges.firstObject);
        [self.highPriorityRanges removeObjectAtIndex:0];

        int64_t current = range.start;
        while (current < range.end) {
            int64_t availableEnd = ICStreamContiguousEndForOffset(self.downloadedRanges, current);
            if (availableEnd <= current) {
                break;
            }
            current = availableEnd;
        }

        if (current >= range.end) {
            continue;
        }

        int64_t chunkEnd = MIN(range.end, current + ICStreamingHighPriorityChunkSize);
        if (chunkEnd < range.end) {
            ICStreamMergeRangeIntoArray(self.highPriorityRanges, ICStreamByteRangeMake(chunkEnd, range.end));
        }

        return ICStreamByteRangeMake(current, chunkEnd);
    }
    return ICStreamByteRangeMake(0, 0);
}

- (ICStreamByteRange)_nextBackfillChunk
{
    int64_t targetLength = (self.contentLengthConfirmed && self.contentLength > 0) ? self.contentLength : self.hintedContentLength;
    if (self.cacheCoverageComplete) {
        return ICStreamByteRangeMake(0, 0);
    }

    int64_t cursor = 0;
    for (NSValue* value in self.downloadedRanges) {
        ICStreamByteRange range = ICStreamRangeFromValue(value);
        if (range.start > cursor) {
            int64_t end = MIN(range.start, cursor + ICStreamingBackfillChunkSize);
            return ICStreamByteRangeMake(cursor, end);
        }
        cursor = MAX(cursor, range.end);
        if (targetLength > 0 && cursor >= targetLength) {
            if (!self.contentLengthConfirmed) {
                return ICStreamByteRangeMake(cursor, cursor + ICStreamingBackfillChunkSize);
            }
            return ICStreamByteRangeMake(0, 0);
        }
    }

    if (targetLength <= 0) {
        return ICStreamByteRangeMake(cursor, cursor + ICStreamingBackfillChunkSize);
    }

    if (cursor < targetLength) {
        int64_t end = MIN(targetLength, cursor + ICStreamingBackfillChunkSize);
        return ICStreamByteRangeMake(cursor, end);
    }

    if (!self.contentLengthConfirmed) {
        return ICStreamByteRangeMake(cursor, cursor + ICStreamingBackfillChunkSize);
    }

    return ICStreamByteRangeMake(0, 0);
}

- (void)_startTaskForRange:(ICStreamByteRange)range
{
    if (!ICStreamByteRangeIsValid(range) || self.stopped) {
        return;
    }

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:self.remoteURL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.0];
    request.networkServiceType = NSURLNetworkServiceTypeVoice;
    NSString* rangeHeader = [NSString stringWithFormat:@"bytes=%lld-%lld", range.start, range.end - 1];
    [request setValue:rangeHeader forHTTPHeaderField:@"Range"];
    [request setValue:@"" forHTTPHeaderField:@"Accept-Encoding"];

    if (self.username.length > 0) {
        NSString* rawAuth = [NSString stringWithFormat:@"%@:%@", self.username ?: @"", self.password ?: @""];
        NSData* authData = [rawAuth dataUsingEncoding:NSUTF8StringEncoding];
        NSString* base64 = [authData base64EncodedStringWithOptions:0];
        if (base64.length > 0) {
            [request setValue:[NSString stringWithFormat:@"Basic %@", base64] forHTTPHeaderField:@"Authorization"];
        }
    }

    self.activeRange = range;
    self.activeWriteOffset = range.start;
    self.activeTask = [self.session dataTaskWithRequest:request];
    [self.activeTask resume];
}

- (void)_pumpDownloads
{
    if (self.stopped || self.activeTask || !self.session || self.cacheCoverageComplete) {
        return;
    }

    ICStreamByteRange range = [self _dequeueHighPriorityChunk];
    if (!ICStreamByteRangeIsValid(range)) {
        range = [self _nextBackfillChunk];
    }

    if (!ICStreamByteRangeIsValid(range)) {
        return;
    }

    [self _startTaskForRange:range];
}

- (NSData*)_readDataAtOffset:(int64_t)offset length:(NSUInteger)length
{
    if (length == 0 || offset < 0) {
        return [NSData data];
    }

    NSFileHandle* handle = [NSFileHandle fileHandleForReadingAtPath:self.readURL.path];
    if (!handle) {
        return nil;
    }

    NSData* data = nil;
    @try {
        [handle seekToFileOffset:(unsigned long long)offset];
        data = [handle readDataOfLength:length];
    }
    @catch (NSException* exception) {
        ErrLog(@"stream cache read exception: %@", exception);
    }
    @finally {
        [handle closeFile];
    }

    return data;
}

- (void)_fillContentInformationForLoadingRequest:(AVAssetResourceLoadingRequest*)loadingRequest
{
    AVAssetResourceLoadingContentInformationRequest* contentRequest = loadingRequest.contentInformationRequest;
    if (!contentRequest) {
        return;
    }

    if (self.contentType.length > 0) {
        contentRequest.contentType = self.contentType;
    }
    int64_t advertisedLength = (self.contentLengthConfirmed && self.contentLength > 0) ? self.contentLength : self.hintedContentLength;
    if (advertisedLength > 0) {
        contentRequest.contentLength = advertisedLength;
    }
    contentRequest.byteRangeAccessSupported = YES;
}

- (void)_processPendingRequests
{
    for (AVAssetResourceLoadingRequest* loadingRequest in [self.pendingRequests copy]) {
        [self _fillContentInformationForLoadingRequest:loadingRequest];

        AVAssetResourceLoadingDataRequest* dataRequest = loadingRequest.dataRequest;
        if (!dataRequest) {
            [loadingRequest finishLoading];
            [self.pendingRequests removeObject:loadingRequest];
            continue;
        }

        int64_t requestedOffset = dataRequest.requestedOffset;
        int64_t currentOffset = dataRequest.currentOffset;
        if (currentOffset <= 0) {
            currentOffset = requestedOffset;
        }

        int64_t streamLength = (self.contentLengthConfirmed && self.contentLength > 0) ? self.contentLength : self.hintedContentLength;

        int64_t requestedEnd = 0;
        if (dataRequest.requestsAllDataToEndOfResource && streamLength > 0) {
            requestedEnd = streamLength;
        } else if (dataRequest.requestedLength > 0) {
            requestedEnd = requestedOffset + dataRequest.requestedLength;
        } else {
            requestedEnd = currentOffset + ICStreamingHighPriorityChunkSize;
        }

        int64_t availableEnd = ICStreamContiguousEndForOffset(self.downloadedRanges, currentOffset);
        int64_t deliverEnd = MIN(availableEnd, requestedEnd);
        if (deliverEnd > currentOffset) {
            NSUInteger bytesToRead = (NSUInteger)MIN((int64_t)INT_MAX, deliverEnd - currentOffset);
            NSData* data = [self _readDataAtOffset:currentOffset length:bytesToRead];
            if (data.length > 0) {
                [dataRequest respondWithData:data];
                currentOffset += data.length;
            }
        }

        BOOL finished = NO;
        if (dataRequest.requestsAllDataToEndOfResource && streamLength > 0) {
            finished = (currentOffset >= streamLength);
        } else {
            finished = (currentOffset >= requestedEnd);
        }

        if (finished) {
            [loadingRequest finishLoading];
            [self.pendingRequests removeObject:loadingRequest];
        } else {
            [self _enqueueHighPriorityRangeFrom:currentOffset to:requestedEnd];
        }
    }
}

- (void)_updateCoverageStateAndImportIfNeeded
{
    if (!self.contentLengthConfirmed || self.contentLength <= 0 || self.cacheCoverageComplete) {
        return;
    }

    int64_t contiguousEnd = ICStreamContiguousEndForOffset(self.downloadedRanges, 0);
    if (contiguousEnd < self.contentLength) {
        return;
    }

    self.cacheCoverageComplete = YES;
    [self _notifyProgressIfNeededForce:YES];

    if (self.cacheImportStarted) {
        return;
    }
    self.cacheImportStarted = YES;

    [self.writeHandle closeFile];
    self.writeHandle = nil;

    __weak ICStreamingCacheLoader* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong ICStreamingCacheLoader* strongSelf = weakSelf;
        if (!strongSelf || strongSelf.stopped) {
            return;
        }

        [[CacheManager sharedCacheManager] importFileAtURL:strongSelf.tempURL forEpisode:strongSelf.episode completion:^(BOOL success, NSError* error) {
            __strong ICStreamingCacheLoader* innerSelf = weakSelf;
            if (!innerSelf) {
                return;
            }
            [[CacheManager sharedCacheManager] finishStreamingCacheForEpisode:innerSelf.episode];

            dispatch_async(innerSelf.resourceLoaderQueue, ^{
                if (!success) {
                    ErrLog(@"stream cache import failed: %@", error);
                    innerSelf.cacheImportFinished = YES;
                    [innerSelf.session finishTasksAndInvalidate];
                    innerSelf.session = nil;
                    [innerSelf _notifyProgressIfNeededForce:YES];
                    [innerSelf _releaseDetachedRetentionIfPossible];
                    return;
                }

                innerSelf.cacheImportFinished = YES;
                [innerSelf.session finishTasksAndInvalidate];
                innerSelf.session = nil;
                innerSelf.readURL = [[CacheManager sharedCacheManager] URLForCachedEpisode:innerSelf.episode];
                [[NSFileManager defaultManager] removeItemAtURL:innerSelf.tempURL error:nil];
                [innerSelf _processPendingRequests];
                [innerSelf _notifyProgressIfNeededForce:YES];
                [innerSelf _releaseDetachedRetentionIfPossible];
            });
        }];
    });
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest
{
    __weak ICStreamingCacheLoader* weakSelf = self;
    dispatch_async(self.resourceLoaderQueue, ^{
        __strong ICStreamingCacheLoader* strongSelf = weakSelf;
        if (!strongSelf || strongSelf.stopped) {
            NSError* error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            [loadingRequest finishLoadingWithError:error];
            return;
        }

        [strongSelf.pendingRequests addObject:loadingRequest];
        [strongSelf _processPendingRequests];
        [strongSelf _pumpDownloads];
    });
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest
{
    __weak ICStreamingCacheLoader* weakSelf = self;
    dispatch_async(self.resourceLoaderQueue, ^{
        __strong ICStreamingCacheLoader* strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf.pendingRequests removeObject:loadingRequest];
    });
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler
{
    NSString* method = challenge.protectionSpace.authenticationMethod;
    if (([method isEqualToString:NSURLAuthenticationMethodHTTPBasic] || [method isEqualToString:NSURLAuthenticationMethodHTTPDigest]) &&
        self.username.length > 0) {
        NSURLCredential* credential = [NSURLCredential credentialWithUser:self.username password:self.password ?: @"" persistence:NSURLCredentialPersistenceForSession];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
        return;
    }

    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    dispatch_async(self.resourceLoaderQueue, ^{
        if (self.stopped) {
            completionHandler(NSURLSessionResponseCancel);
            return;
        }

        NSInteger statusCode = 0;
        int64_t requestedRangeLength = self.activeRange.end - self.activeRange.start;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
            statusCode = httpResponse.statusCode;
            NSDictionary* headers = httpResponse.allHeaderFields;
            NSString* contentRange = headers[@"Content-Range"] ?: headers[@"content-range"];
            if ([contentRange isKindOfClass:[NSString class]]) {
                NSArray* slashParts = [contentRange componentsSeparatedByString:@"/"];
                NSArray* dashParts = [slashParts.firstObject componentsSeparatedByString:@"-"];
                if (dashParts.count == 2) {
                    NSString* startString = [[dashParts.firstObject componentsSeparatedByString:@" "] lastObject];
                    int64_t responseStart = [startString longLongValue];
                    self.activeWriteOffset = responseStart;
                }
                if (slashParts.count == 2) {
                    int64_t totalLength = [slashParts.lastObject longLongValue];
                    if (totalLength > 0) {
                        self.contentLength = totalLength;
                        self.contentLengthConfirmed = YES;
                    }
                }
                self.supportsByteRange = YES;
            } else if (statusCode == 206) {
                self.supportsByteRange = YES;
            } else if (statusCode == 200) {
                self.activeWriteOffset = 0;
            }

            NSString* acceptRanges = headers[@"Accept-Ranges"] ?: headers[@"accept-ranges"];
            if ([acceptRanges isKindOfClass:[NSString class]] && [acceptRanges rangeOfString:@"bytes" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                self.supportsByteRange = YES;
            }
        }

        if (response.MIMEType.length > 0) {
            self.mimeType = response.MIMEType;
            NSString* type = [self _contentTypeForMIMEType:response.MIMEType];
            if (type.length > 0) {
                self.contentType = type;
            }
        }

        if (self.contentLength <= 0 && response.expectedContentLength > 0) {
            if (statusCode == 206 && self.supportsByteRange) {
                int64_t hinted = self.activeWriteOffset + response.expectedContentLength;
                if (hinted > self.hintedContentLength) {
                    self.hintedContentLength = hinted;
                }
            } else {
                self.contentLength = (self.activeWriteOffset > 0) ? self.activeWriteOffset + response.expectedContentLength : response.expectedContentLength;
                self.contentLengthConfirmed = YES;
            }
        }

        if (!self.contentLengthConfirmed &&
            statusCode == 206 &&
            requestedRangeLength > 0 &&
            response.expectedContentLength > 0 &&
            response.expectedContentLength < requestedRangeLength)
        {
            self.contentLength = self.activeWriteOffset + response.expectedContentLength;
            self.contentLengthConfirmed = YES;
        }

        completionHandler(NSURLSessionResponseAllow);
        [self _processPendingRequests];
        [self _notifyProgressIfNeededForce:NO];
        [self _pumpDownloads];
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    dispatch_async(self.resourceLoaderQueue, ^{
        if (self.stopped || data.length == 0 || !self.writeHandle) {
            return;
        }

        int64_t writeStart = self.activeWriteOffset;
        @try {
            [self.writeHandle seekToFileOffset:(unsigned long long)writeStart];
            [self.writeHandle writeData:data];
            self.activeWriteOffset += data.length;
            ICStreamMergeRangeIntoArray(self.downloadedRanges, ICStreamByteRangeMake(writeStart, self.activeWriteOffset));
        }
        @catch (NSException* exception) {
            ErrLog(@"stream cache write exception: %@", exception);
        }

        [self _processPendingRequests];
        [self _notifyProgressIfNeededForce:NO];
        [self _updateCoverageStateAndImportIfNeeded];
        [self _pumpDownloads];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    dispatch_async(self.resourceLoaderQueue, ^{
        if (task != self.activeTask) {
            return;
        }

        self.activeTask = nil;
        self.activeRange = ICStreamByteRangeMake(0, 0);

        if (error && error.code != NSURLErrorCancelled && !self.stopped) {
            ErrLog(@"stream cache download failed: %@", error);
            for (AVAssetResourceLoadingRequest* request in [self.pendingRequests copy]) {
                [request finishLoadingWithError:error];
            }
            [self.pendingRequests removeAllObjects];
            self.cacheImportFinished = YES;
            [self _notifyProgressIfNeededForce:YES];
            [self _releaseDetachedRetentionIfPossible];
            return;
        }

        [self _processPendingRequests];
        [self _updateCoverageStateAndImportIfNeeded];
        [self _pumpDownloads];
    });
}

@end
#endif

@class ICStreamingCacheLoader;

@interface AudioSession ()
@property (nonatomic, readwrite, strong) CDEpisode* episode;
@property (nonatomic, readwrite, strong) NSMutableArray* playlist;
@property BOOL autoStopDisabled;
@end

@interface PlaybackManager ()
@property (nonatomic, readwrite, strong) CDEpisode* playingEpisode;
@property (nonatomic, readwrite, getter=isReady) BOOL ready;
@property (nonatomic, readwrite) BOOL failed;
@property (nonatomic, readwrite, getter=hasMovingVideo) BOOL movingVideo;
@property (nonatomic, readwrite) CGSize viewImageSize;

@property (nonatomic, readwrite, strong) AVURLAsset* mediaAsset;
@property (nonatomic, readwrite, strong) AVPlayer* player;
@property (readwrite, strong) PlayerView* playerView;
@property (nonatomic, readwrite, strong) NSDate* lastPauseDate;
@property (nonatomic, readwrite, strong) NSDate* playStartDate;

@property (nonatomic) BOOL changingEpisode;
@property (nonatomic) BOOL changingPosition;

@property (readwrite, strong) NSArray* chapters;
@property (readwrite, strong) NSArray* artworks;

@property (nonatomic, weak) NSTimer* controlTimer;
@property (nonatomic, strong) NSDate* controlStartDate;

#if TARGET_OS_IPHONE
@property (nonatomic) UIBackgroundTaskIdentifier bufferNextItemTaskIdentifier;
#endif

@property (nonatomic) double initialPlaybackTime;
@property (nonatomic, strong) id playbackObserver;
@property (nonatomic, strong) id temporaryPositionObserver;
@property (nonatomic, strong) id savedPositionObserver;
@property (assign) NSInteger state;

@property (nonatomic) BOOL inTransitionToNextTrack;
@property (nonatomic, strong) NSMutableDictionary* nowPlayingInfo;
@property (nonatomic, strong) NSTimer* nowPlayingDelayTimer;
@property (nonatomic) double seekingPosition;
@property (nonatomic, strong) NSDate* seekingPositionChangeDate;
@property (nonatomic, strong) ICMetadataChapter* seekingChapter;

// Chapter skip protection
@property (nonatomic) BOOL isAutoSkipping;
@property (nonatomic, strong) NSDate *lastAutoSkipDate;
@property (nonatomic, strong) NSArray *autoSkipMarkers;  // @[@{@"start": @(time), @"resume": @(time)}], resume == -1 → finish episode
@property (nonatomic) NSInteger suppressedSkipMarker;    // Manual seek protection: marker index to suppress
@property (nonatomic, strong) NSDate *lastBackgroundPlaybackDiagnosticDate;
#if TARGET_OS_IPHONE
@property (nonatomic, strong) ICStreamingCacheLoader* streamCacheLoader;
#endif
@property (nonatomic, readwrite) BOOL streamingCacheActive;
@property (nonatomic, readwrite) double streamingCacheProgress;
@property (nonatomic, readwrite) BOOL streamingCacheComplete;
@end


@implementation PlaybackManager {
    float       _volume;
    float*      _chapterTimesIdx;
    float*      _artworkTimesIdx;
}

#pragma mark -

+ (PlaybackManager*) playbackManager;
{
	static PlaybackManager* gPlaybackManager = nil;
    static dispatch_once_t onceToken = 0;
    dispatch_once(&onceToken, ^{
        gPlaybackManager = [[PlaybackManager alloc] init];
    });
	return gPlaybackManager;
}



- (id) init
{
	if ((self = [super init]))
	{
#if TARGET_OS_IPHONE

        // overwrite current default on iOS, because we actually use the system volume
        [USER_DEFAULTS setFloat:1.0f forKey:kDefaultPlaybackVolume];

        // Reload chapters when generated chapters are added or deleted
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_generatedChaptersDidChange:) name:@"ICTranscriptionDidChangeNotification" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_cacheManagerDidCancelStreamingCacheEpisode:) name:CacheManagerDidCancelStreamingCacheEpisodeNotification object:nil];
#else
        dispatch_async(dispatch_get_main_queue(), ^{
            [self initializeMikey];
            [self initializeAudioDeviceListener];
#ifndef APP_STORE
            [self initializeRemoteControl];
#endif
            [self _setAudioEndpointToCurrentSystemAudioDevice];
        });
#endif
	}
	
	return self;
}

- (void)_cacheManagerDidCancelStreamingCacheEpisode:(NSNotification*)notification
{
    CDEpisode* episode = notification.userInfo[@"episode"];
    [self cancelStreamingCacheForEpisode:episode];
}


- (void) _sendUpdateNotification
{
    if ([NSThread isMainThread]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerDidUpdateNotification object:self];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerDidUpdateNotification object:self];
        });
    }
}

- (void) _endNextItemHandover
{
#if TARGET_OS_IPHONE
	if (self.bufferNextItemTaskIdentifier != UIBackgroundTaskInvalid) {
		[App endBackgroundTask:self.bufferNextItemTaskIdentifier];
		self.bufferNextItemTaskIdentifier = UIBackgroundTaskInvalid;
	}
#endif
}

- (void) _startNextItemHandover
{
	[self _endNextItemHandover];
#if TARGET_OS_IPHONE
	self.bufferNextItemTaskIdentifier = [App beginBackgroundTaskWithExpirationHandler:^(void) {
        [App endBackgroundTask:self.bufferNextItemTaskIdentifier];
		self.bufferNextItemTaskIdentifier = UIBackgroundTaskInvalid;
	}];
	#endif
}

#if TARGET_OS_IPHONE
- (BOOL)_isCarPlaySceneConnectedForNowPlaying
{
#if TARGET_OS_MACCATALYST
    return NO;
#else
    NSSet<UIScene*>* connectedScenes = [UIApplication sharedApplication].connectedScenes;
    for (UIScene* scene in connectedScenes)
    {
        if ([scene.session.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication] &&
            scene.activationState != UISceneActivationStateUnattached &&
            scene.activationState != UISceneActivationStateBackground)
        {
            return YES;
        }
    }
    return NO;
#endif
}

- (void)_setNowPlayingArtworkFromImage:(UIImage*)image
{
    if (!image) {
        return;
    }

    MPMediaItemArtwork* artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage * _Nonnull(CGSize size) {
        return image;
    }];
    if (artwork) {
        self.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork;
    }
}

- (void)_applyEpisodeArtworkToNowPlayingForEpisode:(CDEpisode*)episode forceRefresh:(BOOL)forceRefresh
{
    if (!episode) {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyArtwork];
        [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastEpisodeHash];
        return;
    }

    NSString* episodeHash = episode.objectHash ?: @"";
    NSString* currentEpisodeHash = self.nowPlayingInfo[kMediaItemInstacastEpisodeHash];
    BOOL hasArtwork = (self.nowPlayingInfo[MPMediaItemPropertyArtwork] != nil);
    if (!forceRefresh && [currentEpisodeHash isEqualToString:episodeHash] && hasArtwork) {
        return;
    }

    self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] = episodeHash;

    // Always clear the old artwork immediately when the episode changes,
    // so the previous podcast's image doesn't persist in Dynamic Island / lock screen.
    [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyArtwork];

    void (^clearArtworkIfCurrentEpisode)(void) = ^{
        CDEpisode* playingEpisode = self.playingEpisode;
        if (!playingEpisode || ![playingEpisode.objectHash isEqualToString:episodeHash]) {
            return;
        }
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyArtwork];
    };

    void (^displayImageIfCurrentEpisode)(UIImage*) = ^(UIImage* image) {
        if (!image) {
            return;
        }
        CDEpisode* playingEpisode = self.playingEpisode;
        if (!playingEpisode || ![playingEpisode.objectHash isEqualToString:episodeHash]) {
            return;
        }
        [self _setNowPlayingArtworkFromImage:image];
    };

    ImageCacheManager* imageManager = [ImageCacheManager sharedImageCacheManager];
    UIImage* cachedEpisodeImage = [imageManager localImageForImageURL:episode.imageURL size:320 grayscale:NO];
    if (cachedEpisodeImage) {
        displayImageIfCurrentEpisode(cachedEpisodeImage);
        return;
    }

    UIImage* cachedFeedImage = [imageManager localImageForImageURL:episode.feed.imageURL size:320 grayscale:NO];
    if (cachedFeedImage) {
        displayImageIfCurrentEpisode(cachedFeedImage);
        return;
    }

    if (episode.imageURL) {
        ICImageCacheOperation* episodeOperation = [[ICImageCacheOperation alloc] initWithURL:episode.imageURL size:320 grayscale:NO];
        episodeOperation.didEndBlock = ^(IC_IMAGE* image, NSError* error) {
            if (image) {
                displayImageIfCurrentEpisode(image);
                [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
                return;
            }

            if (episode.feed.imageURL) {
                ICImageCacheOperation* feedOperation = [[ICImageCacheOperation alloc] initWithURL:episode.feed.imageURL size:320 grayscale:NO];
                feedOperation.didEndBlock = ^(IC_IMAGE* feedImage, NSError* feedError) {
                    if (feedImage) {
                        displayImageIfCurrentEpisode(feedImage);
                    } else {
                        clearArtworkIfCurrentEpisode();
                    }
                    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
                };
                [imageManager addImageCacheOperation:feedOperation sender:self];
            } else {
                clearArtworkIfCurrentEpisode();
                [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
            }
        };
        [imageManager addImageCacheOperation:episodeOperation sender:self];
        return;
    }

    if (episode.feed.imageURL) {
        ICImageCacheOperation* feedOperation = [[ICImageCacheOperation alloc] initWithURL:episode.feed.imageURL size:320 grayscale:NO];
        feedOperation.didEndBlock = ^(IC_IMAGE* image, NSError* error) {
            if (image) {
                displayImageIfCurrentEpisode(image);
            } else {
                clearArtworkIfCurrentEpisode();
            }
            [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
        };
        [imageManager addImageCacheOperation:feedOperation sender:self];
        return;
    }

    clearArtworkIfCurrentEpisode();
}
#endif


- (void) _setNowPlayingInfoOfEpisode:(CDEpisode*)anEpisode
{
#if TARGET_OS_IPHONE
    if (!self.nowPlayingInfo) {
        self.nowPlayingInfo = [NSMutableDictionary dictionary];
    }
    else if (![self.nowPlayingInfo isKindOfClass:[NSMutableDictionary class]])
    {
        self.nowPlayingInfo = [self.nowPlayingInfo mutableCopy];
    }
    
    
    [self.nowPlayingInfo setObject:@(MPMediaTypePodcast) forKey:MPMediaItemPropertyMediaType];
    
	
    NSString* podcastTitle = nil;
    NSString* episodeTitle = nil;
    NSString* chapterTitle = nil;
    
    if (anEpisode)
    {
        CDFeed* feed = anEpisode.feed;
        podcastTitle = feed.title;

        if (anEpisode.title && feed.title) {
            episodeTitle = [anEpisode cleanTitleUsingFeedTitle:feed.title];
        } else {
            episodeTitle = anEpisode.title;
        }

        if (feed.uid.length > 0) {
            [self.nowPlayingInfo setObject:feed.uid forKey:MPNowPlayingInfoCollectionIdentifier];
        } else {
            [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoCollectionIdentifier];
        }
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoCollectionIdentifier];
    }
    
    // Put the current chapter into the subtitle line where supported.
    if ([self.chapters count] > 0 && self.currentChapter >= 0 && self.currentChapter < [self.chapters count])
    {
        ICMetadataChapter* chapter = [self.chapters objectAtIndex:self.currentChapter];
        chapterTitle = chapter.title;
    }

    NSString* nowPlayingTitle = episodeTitle;
    NSString* nowPlayingArtist = podcastTitle;
    NSString* nowPlayingAlbum = chapterTitle;

    if ([self _isCarPlaySceneConnectedForNowPlaying]) {
        // CarPlay layout: top = episode, second line = current chapter, third line = podcast.
        NSString* carPlayTitle = (episodeTitle.length > 0) ? episodeTitle : podcastTitle;
        NSString* carPlayArtist = nil;
        NSString* carPlayAlbum = nil;

        if (chapterTitle.length > 0) {
            carPlayArtist = chapterTitle;
            if (podcastTitle.length > 0 &&
                ![podcastTitle isEqualToString:carPlayTitle] &&
                ![podcastTitle isEqualToString:carPlayArtist]) {
                carPlayAlbum = podcastTitle;
            }
        }
        else if (podcastTitle.length > 0 && ![podcastTitle isEqualToString:carPlayTitle]) {
            carPlayArtist = podcastTitle;
        }

        nowPlayingTitle = carPlayTitle;
        nowPlayingArtist = carPlayArtist;
        nowPlayingAlbum = carPlayAlbum;
    }

    if (nowPlayingTitle.length > 0) {
        [self.nowPlayingInfo setObject:nowPlayingTitle forKey:MPMediaItemPropertyTitle];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyTitle];
    }

    if (nowPlayingArtist.length > 0) {
        [self.nowPlayingInfo setObject:nowPlayingArtist forKey:MPMediaItemPropertyArtist];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyArtist];
    }

    if (nowPlayingAlbum.length > 0) {
        [self.nowPlayingInfo setObject:nowPlayingAlbum forKey:MPMediaItemPropertyAlbumTitle];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyAlbumTitle];
    }

    
    // set image in case we have chapter based images
    if (!self.movingVideo && [self.artworks count] > 0 && self.currentArtwork >= 0 && self.currentArtwork < [self.artworks count])
    {
        ICMetadataImage* artwork = self.artworks[self.currentArtwork];
        NSNumber* currentArtwork = self.nowPlayingInfo[kMediaItemInstacastCurrentArtwork];
        NSString* episodeHash = anEpisode.objectHash ?: @"";
        NSString* currentEpisodeHash = self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] ?: @"";
        BOOL episodeChanged = ![currentEpisodeHash isEqualToString:episodeHash];
        
        if (!currentArtwork || [currentArtwork integerValue] != self.currentArtwork || episodeChanged)
        {
            NSInteger expectedArtworkIndex = self.currentArtwork;
            NSString* expectedEpisodeHash = episodeHash;
            [artwork loadPlatformImageWithCompletion:^(id platformImage) {
                CDEpisode* playingEpisode = self.playingEpisode;
                if (expectedEpisodeHash.length > 0 &&
                    (!playingEpisode || ![playingEpisode.objectHash isEqualToString:expectedEpisodeHash])) {
                    return;
                }

                if (platformImage)
                {
                    if (self.currentArtwork != expectedArtworkIndex) {
                        return;
                    }
                    [self _setNowPlayingArtworkFromImage:(UIImage*)platformImage];
                    self.nowPlayingInfo[kMediaItemInstacastCurrentArtwork] = @(expectedArtworkIndex);
                    if (expectedEpisodeHash.length > 0) {
                        self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] = expectedEpisodeHash;
                    } else {
                        [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastEpisodeHash];
                    }
                }
                else {
                    [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastCurrentArtwork];
                    [self _applyEpisodeArtworkToNowPlayingForEpisode:anEpisode forceRefresh:YES];
                }
                
                [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;

            }];
        }
        if (episodeHash.length > 0) {
            self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] = episodeHash;
        } else {
            [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastEpisodeHash];
        }
    }
    else
    {
        BOOL hadChapterArtwork = (self.nowPlayingInfo[kMediaItemInstacastCurrentArtwork] != nil);
        [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastCurrentArtwork];
        [self _applyEpisodeArtworkToNowPlayingForEpisode:anEpisode forceRefresh:hadChapterArtwork];
    }
    
    [self.nowPlayingInfo setObject:[NSNumber numberWithFloat:self.duration] forKey:MPMediaItemPropertyPlaybackDuration];
    
    [self.nowPlayingInfo setObject:[NSNumber numberWithDouble:self.player.rate] forKey:MPNowPlayingInfoPropertyPlaybackRate];
    [self.nowPlayingInfo setObject:[NSNumber numberWithDouble:(double)self.time] forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    
    if (self.chapters && self.currentChapter >= 0) {
        [self.nowPlayingInfo setObject:[NSNumber numberWithUnsignedInteger:[self.chapters count]] forKey:MPNowPlayingInfoPropertyChapterCount];
        [self.nowPlayingInfo setObject:[NSNumber numberWithInteger:self.currentChapter] forKey:MPNowPlayingInfoPropertyChapterNumber];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoPropertyChapterCount];
        [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoPropertyChapterNumber];
    }
    
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
    MPNowPlayingInfoCenter.defaultCenter.playbackState = (self.player.rate > 0.0f) ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
    
#endif
}


- (void) _setupRemotePlaybackCenterWithEpisode:(CDEpisode*)episode
{
#if TARGET_OS_IPHONE
    MPRemoteCommandCenter *rcc = [MPRemoteCommandCenter sharedCommandCenter];
    
    // reset all commands first
    MPRemoteCommand *pauseCommand = rcc.pauseCommand;
    pauseCommand.enabled = NO;
    [pauseCommand removeTarget:self];
    //
    MPRemoteCommand *playCommand = rcc.playCommand;
    playCommand.enabled = NO;
    [playCommand removeTarget:self];
    
    MPRemoteCommand *togglePlayPauseCommand = rcc.togglePlayPauseCommand;
    togglePlayPauseCommand.enabled = NO;
    [togglePlayPauseCommand removeTarget:self];
    
    
    MPSkipIntervalCommand* skipBackwardIntervalCommand = rcc.skipBackwardCommand;
    skipBackwardIntervalCommand.enabled = NO;
    [skipBackwardIntervalCommand removeTarget:self];
    
    MPSkipIntervalCommand* skipForwardIntervalCommand = rcc.skipForwardCommand;
    skipForwardIntervalCommand.enabled = NO;
    [skipForwardIntervalCommand removeTarget:self];
    
    
    MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
    nextTrackCommand.enabled = NO;
    [nextTrackCommand removeTarget:self];
    
    MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
    previousTrackCommand.enabled = NO;
    [previousTrackCommand removeTarget:self];
    
    MPRemoteCommand* skipForwardCommand = rcc.seekForwardCommand;
    skipForwardCommand.enabled = NO;
    [skipForwardCommand removeTarget:self];
    
    MPRemoteCommand* seekBackwardCommand = rcc.seekBackwardCommand;
    seekBackwardCommand.enabled = NO;
    [seekBackwardCommand removeTarget:self];

    MPChangePlaybackPositionCommand* changePlaybackPositionCommand = rcc.changePlaybackPositionCommand;
    changePlaybackPositionCommand.enabled = NO;
    [changePlaybackPositionCommand removeTarget:self];
    
    
    if (episode)
    {
        CDFeed* feed = episode.feed;
        
        MPRemoteCommand *pauseCommand = rcc.pauseCommand;
        pauseCommand.enabled = YES;
        [pauseCommand addTarget:self action:@selector(_pauseEvent:)];
        //
        MPRemoteCommand *playCommand = rcc.playCommand;
        playCommand.enabled = YES;
        [playCommand addTarget:self action:@selector(_playEvent:)];
        
        MPRemoteCommand *togglePlayPauseCommand = rcc.togglePlayPauseCommand;
        togglePlayPauseCommand.enabled = YES;
        [togglePlayPauseCommand addTarget:self action:@selector(_playPauseEvent:)];

        MPChangePlaybackPositionCommand* changePlaybackPositionCommand = rcc.changePlaybackPositionCommand;
        changePlaybackPositionCommand.enabled = YES;
        [changePlaybackPositionCommand addTarget:self action:@selector(_changePlaybackPositionEvent:)];
        
        if ([feed integerForKey:kDefaultPlayerControls] == kPlayerSkippingControls)
        {
            MPSkipIntervalCommand* skipBackwardIntervalCommand = rcc.skipBackwardCommand;
            skipBackwardIntervalCommand.enabled = YES;
            [skipBackwardIntervalCommand addTarget:self action:@selector(_skipBackwardEvent:)];
            skipBackwardIntervalCommand.preferredIntervals = @[@([feed integerForKey:PlayerSkipBackPeriod])];
            
            MPSkipIntervalCommand* skipForwardIntervalCommand = rcc.skipForwardCommand;
            skipForwardIntervalCommand.enabled = YES;
            skipForwardIntervalCommand.preferredIntervals = @[@([feed integerForKey:PlayerSkipForwardPeriod])];
            [skipForwardIntervalCommand addTarget:self action:@selector(_skipForwardEvent:)];
            
            MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
            nextTrackCommand.enabled = YES;
            [nextTrackCommand addTarget:self action:@selector(_skipForwardEvent:)];
            
            MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
            previousTrackCommand.enabled = YES;
            [previousTrackCommand addTarget:self action:@selector(_skipBackwardEvent:)];
        }
        else
        {
            if ([feed integerForKey:kDefaultPlayerControls] == kPlayerSeekingAndSkippingChaptersControls)
            {
                MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
                nextTrackCommand.enabled = YES;
                [nextTrackCommand addTarget:self action:@selector(_nextChapterEvent:)];
                
                MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
                previousTrackCommand.enabled = YES;
                [previousTrackCommand addTarget:self action:@selector(_previousChapterEvent:)];
            }
            else
            {
                MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
                nextTrackCommand.enabled = YES;
                [nextTrackCommand addTarget:self action:@selector(_skipForwardEvent:)];
                
                MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
                previousTrackCommand.enabled = YES;
                [previousTrackCommand addTarget:self action:@selector(_skipBackwardEvent:)];
            }
            
            
            MPRemoteCommand* skipForwardCommand = rcc.seekForwardCommand;
            skipForwardCommand.enabled = YES;
            [skipForwardCommand addTarget:self action:@selector(_seekForwardEvent:)];
            
            MPRemoteCommand* seekBackwardCommand = rcc.seekBackwardCommand;
            seekBackwardCommand.enabled = YES;
            [seekBackwardCommand addTarget:self action:@selector(_seekBackwardEvent:)];
        }
        
    }
#endif
}

#if TARGET_OS_IPHONE

-(MPRemoteCommandHandlerStatus) _seekForwardEvent: (MPSeekCommandEvent *) seekEvent
{
    if (seekEvent.type == MPSeekCommandEventTypeBeginSeeking) {
        [self beginSeekingForward];
    }
    if (seekEvent.type == MPSeekCommandEventTypeEndSeeking) {
        [self endSeeking];
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

-(MPRemoteCommandHandlerStatus) _seekBackwardEvent: (MPSeekCommandEvent *) seekEvent
{
    if (seekEvent.type == MPSeekCommandEventTypeBeginSeeking) {
        [self beginSeekingBackward];
    }
    if (seekEvent.type == MPSeekCommandEventTypeEndSeeking) {
       [self endSeeking];
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _playPauseEvent:(MPRemoteCommandEvent*)event
{
    [self playPause];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _playEvent:(MPRemoteCommandEvent*)event
{
    if (self.paused) {
        [self play];
        [self updateNowPlayingInfo];
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _pauseEvent:(MPRemoteCommandEvent*)event
{
    if (!self.paused) {
        [self pause];
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)_changePlaybackPositionEvent:(MPChangePlaybackPositionCommandEvent*)event
{
    if (!self.playingEpisode || self.duration <= 0) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }

    NSTimeInterval requestedTime = event.positionTime;
    requestedTime = MAX(0.0, MIN(requestedTime, self.duration));
    [self _suppressAutoSkipMarkerAtTime:requestedTime];
    [self seekToTime:requestedTime tolerance:NO];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _skipBackwardEvent:(MPRemoteCommandEvent*)event
{
    [self seekBackward];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _skipForwardEvent:(MPRemoteCommandEvent*)event
{
    [self seekForward];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _nextChapterEvent:(MPRemoteCommandEvent*)event
{
    [self nextChapter];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _previousChapterEvent:(MPRemoteCommandEvent*)event
{
    [self previousChapter];
    return MPRemoteCommandHandlerStatusSuccess;
}
#endif

#pragma mark -

- (void) openWithEpisode:(CDEpisode*)anEpisode at:(NSTimeInterval)time autostart:(BOOL)autostart
{
	if (self.player) {
		self.changingEpisode = YES;
		[self closeAndSaveCurrentPosition:!self.inTransitionToNextTrack];
        self.inTransitionToNextTrack = NO;
	}

    // Capture notification name before resetting changingEpisode.
    // Must be posted AFTER self.playingEpisode is set so observers see the correct episode.
    NSString *pendingNotificationName = self.changingEpisode ? PlaybackManagerDidChangeEpisodeNotification : PlaybackManagerDidStartNotification;
	self.changingEpisode = NO;

    [self _setNowPlayingInfoOfEpisode:anEpisode];
    [self _setupRemotePlaybackCenterWithEpisode:anEpisode];

	// create background task until the first data is buffered and the app is ready to play
	[self _startNextItemHandover];

	self.ready = NO;
	self.failed = NO;
    self.movingVideo = NO;
	self.currentChapter = -1;
    self.currentArtwork = -1;
    self.initialPlaybackTime = time;

	CacheManager* eman = [CacheManager sharedCacheManager];
	CDMedium* media = [anEpisode preferedMedium];

	BOOL isCached = [eman episodeIsCached:anEpisode];
	NSURL* url = isCached ? [eman URLForCachedEpisode:anEpisode] : media.fileURL;

    BOOL canCacheViaStream = (!isCached &&
                              [USER_DEFAULTS boolForKey:AutoDownloadWhileStreaming] &&
                              ![eman automaticCachingDisabledForEpisode:anEpisode] &&
                              media.fileURL != nil &&
                              anEpisode.objectHash.length > 0);
    if (canCacheViaStream && [eman isCachingSourceOfEpisode:anEpisode]) {
        [eman cancelCachingEpisode:anEpisode disableAutoDownload:NO];
    }
    BOOL shouldCacheViaStream = canCacheViaStream;

    // workaround for a bug in the feed parser up to version 3.0.2
    NSString* urlString = [url absoluteString];
    if ([urlString rangeOfString:@"%25"].location != NSNotFound) {
        urlString = [urlString stringByRemovingPercentEncoding];
        url = [NSURL URLWithString:urlString];
    }

    if (!url) {
        shouldCacheViaStream = NO;
    }

    self.playingEpisode = anEpisode;
    // Post start/change notification now that playingEpisode is set, so observers
    // (e.g. WidgetDataExporter) read the correct current episode.
    [[NSNotificationCenter defaultCenter] postNotificationName:pendingNotificationName object:self];
	self.state = InitializedState;
    self.streamingCacheActive = NO;
    self.streamingCacheProgress = 0.0;
    self.streamingCacheComplete = NO;

#if TARGET_OS_IPHONE
    self.streamCacheLoader = nil;
    if (shouldCacheViaStream) {
        self.streamCacheLoader = [[ICStreamingCacheLoader alloc] initWithEpisode:anEpisode
                                                                        remoteURL:url
                                                                     expectedSize:media.byteSize
                                                                         mimeType:media.mimeType
                                                                         username:anEpisode.feed.username
                                                                         password:anEpisode.feed.password];
        __weak PlaybackManager* weakSelf = self;
        NSString* episodeHash = anEpisode.objectHash;
        self.streamCacheLoader.progressChangeHandler = ^(double progress, BOOL cacheComplete) {
            PlaybackManager* strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            CDEpisode* playingEpisode = strongSelf.playingEpisode;
            if (!playingEpisode || ![playingEpisode.objectHash isEqualToString:episodeHash]) {
                return;
            }
            [[CacheManager sharedCacheManager] updateStreamingCacheForEpisode:playingEpisode progress:progress];
            strongSelf.streamingCacheActive = !cacheComplete;
            strongSelf.streamingCacheProgress = progress;
            strongSelf.streamingCacheComplete = cacheComplete;
            [strongSelf _sendUpdateNotification];
        };
        self.streamingCacheActive = YES;
        [eman beginStreamingCacheForEpisode:anEpisode];
        self.mediaAsset = [AVURLAsset URLAssetWithURL:self.streamCacheLoader.assetURL options:nil];
        [self.mediaAsset.resourceLoader setDelegate:self.streamCacheLoader queue:self.streamCacheLoader.resourceLoaderQueue];
    } else {
        self.mediaAsset = [AVURLAsset URLAssetWithURL:url options:nil];
    }
#else
    self.mediaAsset = [AVURLAsset URLAssetWithURL:url options:nil];
#endif
	
	[self.mediaAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^(void) {
		NSError *error = nil;
		AVKeyValueStatus tracksStatus = [self.mediaAsset statusOfValueForKey:@"tracks" error:&error];
		switch (tracksStatus) {
			case AVKeyValueStatusLoaded:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self _continueOpeningAsset:self.mediaAsset autostart:autostart];
                });
				break;
            }
			case AVKeyValueStatusFailed:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ErrLog(@"AVAsset load failed: %@", [error description]);
                    self.failed = YES;
                    [self close];
                    SEND_UPDATE
                });
				break;
            }
			case AVKeyValueStatusCancelled:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.mediaAsset = nil;
                    [self _endNextItemHandover];
                });
				break;
            }
            default:
                break;
		}
	}];
}

- (void)updateNowPlayingInfo {
    if (self.playingEpisode) {
        [self _setNowPlayingInfoOfEpisode:self.playingEpisode];
    }
}


- (void) _continueOpeningAsset:(AVURLAsset*)asset autostart:(BOOL)autostart 
{
    if (self.initialPlaybackTime == 0) {
        // also handle special case, where we don't have a duration
        self.initialPlaybackTime = (self.playingEpisode.position < self.playingEpisode.duration - 5 || self.playingEpisode.duration < 1) ? self.playingEpisode.position : 0;

        // Check for temporary saved position first (user's last playback position)
        NSString* key = self.playingEpisode.objectHash;
        NSDictionary* playbackPositions = [USER_DEFAULTS objectForKey:kDefaultTemporaryPlaybackPositions];
        NSNumber* temporaryPosition = playbackPositions[key];
        if (temporaryPosition) {
            self.initialPlaybackTime = [temporaryPosition doubleValue];
        }

        // Apply start-skip only if we're starting from the beginning or before the skip point
        CDFeed* feed = self.playingEpisode.feed;
        double periodFeedStart = [feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_start_period", feed.uid]];
        double periodGeneralStart = [USER_DEFAULTS doubleForKey:PlayerAutoSkipStartPeriod];
        double skipStartPeriod = (periodFeedStart != 0.0) ? periodFeedStart : periodGeneralStart;

        // Only apply start-skip if current position is before the skip point
        if (skipStartPeriod > 0.0 && self.initialPlaybackTime < skipStartPeriod) {
            self.initialPlaybackTime = skipStartPeriod;
        }
    }
    
    AVPlayerItem* playerItem = [AVPlayerItem playerItemWithAsset:asset];
    if (!playerItem) {
        self.failed = YES;
        [self close];
        SEND_UPDATE
        return;
    }
    
    __weak PlaybackManager* weakSelf = self;
    
    [playerItem addTaskObserver:self forKeyPath:@"status" task:^(id obj, NSDictionary *change)
    {
        AVPlayerItem* currentItem = weakSelf.player.currentItem;
        if (currentItem.status == AVPlayerItemStatusReadyToPlay && weakSelf.state == InitializedState)
        {
            CDEpisode* episode = weakSelf.playingEpisode;
            CDFeed* feed = episode.feed;
            
            episode.lastPlayed = [NSDate date];
            [DMANAGER save];//DevD to do crashes            
            // check if we have moving video
            weakSelf.movingVideo = NO;
            
            NSArray* tracks = currentItem.tracks;
            for(AVPlayerItemTrack* track in tracks) {
                AVAssetTrack* assetTrack = track.assetTrack;
                
                if ([assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) //track.enabled && 
                {
                    CMFormatDescriptionRef formatDescription = (__bridge CMFormatDescriptionRef)[[assetTrack formatDescriptions] lastObject];
                    if (CMFormatDescriptionGetMediaSubType(formatDescription) != kCMVideoCodecType_JPEG) {
                        weakSelf.movingVideo = YES;
                        
                        CGSize videodimensions = CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, true, true);
                        weakSelf.viewImageSize = videodimensions;
                        break;
                    }
                }
            }
            
#if TARGET_OS_IPHONE
            if ([weakSelf.player respondsToSelector:@selector(allowsAirPlayVideo)]) {
                weakSelf.player.allowsExternalPlayback = weakSelf.movingVideo;
            }
            
            if (!weakSelf.playerView && weakSelf.movingVideo) {
                weakSelf.playerView = [[PlayerView alloc] init];
                [(PlayerView*)weakSelf.playerView setPlayer:weakSelf.player];
            }
            
#else
            if (!weakSelf.playerView && weakSelf.movingVideo) {
                weakSelf.playerView = [[PlayerView alloc] initWithFrame:NSZeroRect];
                [(PlayerView*)weakSelf.playerView setPlayer:weakSelf.player];
            }
#endif
            
            
            if (weakSelf.initialPlaybackTime > 0) {
                [weakSelf seekToTime:weakSelf.initialPlaybackTime];
                weakSelf.initialPlaybackTime = 0;
            }
#if !TARGET_OS_IPHONE
            else {
                [[ICSharingManager sharedManager] triggerEvent:ICSharingServiceEpisodeDidStartPlaying object:weakSelf.playingEpisode];
            }
#endif
            
            weakSelf.ready = YES;
            weakSelf.state = (autostart) ? ShouldRunState : RunningState;
            if (!autostart) {
                [weakSelf _endNextItemHandover];
            }

            // don't use the setter, otherwise the value will be stored
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            [strongSelf willChangeValueForKey:@"speedControl"];
            strongSelf->_speedControl = [feed integerForKey:DefaultPlaybackSpeed];
            strongSelf->_playbackRate = [strongSelf rateFromSpeedControl:strongSelf->_speedControl];
            [strongSelf didChangeValueForKey:@"speedControl"];

            [weakSelf willChangeValueForKey:@"duration"];
            [weakSelf didChangeValueForKey:@"duration"];

            SEND_UPDATE
            [weakSelf _startLoadingChapters];
            if (weakSelf.player.currentItem.playbackLikelyToKeepUp && autostart) {
                [weakSelf play];
                [weakSelf updateNowPlayingInfo];
            }
        }

        else if (weakSelf.player.currentItem.status == AVPlayerItemStatusFailed) {
            ErrLog(@"playback failed/interrupted due to error :%@", weakSelf.player.currentItem.error);
            weakSelf.failed = YES;
            [weakSelf close];
        }
    }];
    
    [playerItem addTaskObserver:self forKeyPath:@"playbackLikelyToKeepUp" task:^(id obj, NSDictionary *change)
    {
        if (weakSelf.state == ShouldRunState) {
            [weakSelf play];
            [weakSelf updateNowPlayingInfo];
        }
    }];

    [playerItem addTaskObserver:self forKeyPath:@"playbackBufferFull" task:^(id obj, NSDictionary *change)
     {
         if (weakSelf.state == ShouldRunState) {
             [weakSelf play];
             [weakSelf updateNowPlayingInfo];
         }
     }];
    
    
    [playerItem addTaskObserver:self forKeyPath:@"loadedTimeRanges" task:^(id obj, NSDictionary *change) {
        [self willChangeValueForKey:@"playableDuration"];
        [self didChangeValueForKey:@"playableDuration"];
        
        if ([self playableDuration] > 60 && self.state == ShouldRunState) {
            [self play];
            [self updateNowPlayingInfo];
        }
    }];
    
    
    
    self.player = [[AVPlayer alloc] initWithPlayerItem:playerItem];
    self.player.volume = [USER_DEFAULTS floatForKey:kDefaultPlaybackVolume];

#if ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR==1
    if ([NSBundle systemVersion] >= VM_SYSTEM_VERSION_OS_X_10_9 && [AVPlayer implementsSelector:@selector(audioOutputDeviceUniqueID)]) {
        [PlaybackManager setDataSourceOfAudioDeviceForEndpoint:self.audioEndpoint];
        self.player.audioOutputDeviceUniqueID = self.audioEndpoint.UID;
    }
#endif
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidPlayToEndTimeNotification:) name:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem];
    

    [self.player addTaskObserver:self forKeyPath:@"rate" task:^(id obj, NSDictionary *change)
    {
        float rate = weakSelf.player.rate;
                
        if (rate > 0 && weakSelf.state == ShouldRunState) {
            weakSelf.state = RunningState;
            [weakSelf performSelector:@selector(_endNextItemHandover) withObject:nil afterDelay:1.0];
        }

        if (weakSelf.mediaAsset && rate == 0 && weakSelf.state == RunningState)
        {
            [weakSelf _saveCurrentPlaybackPosition];//DevD to do
        }
        
        if (weakSelf.ready) {
            [weakSelf willChangeValueForKey:@"paused"];
            [weakSelf didChangeValueForKey:@"paused"];
        }
        
        [weakSelf perform:^(id sender) {
            [weakSelf _setNowPlayingInfoOfEpisode:weakSelf.playingEpisode];
            [weakSelf _setupRemotePlaybackCenterWithEpisode:weakSelf.playingEpisode];
        } afterDelay:0.1];

        MPNowPlayingInfoCenter.defaultCenter.playbackState = (rate > 0.0f) ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;

        // Propagate the effective player state (rate-based paused/running) immediately.
        [weakSelf _sendUpdateNotification];
    }];

    self.playbackObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1,25000) queue:NULL usingBlock:^(CMTime time) {
        
        // make sure we're not resetting the position here when we first need to seek to it on startup
        CDEpisode* episode = weakSelf.playingEpisode;
        
        if (weakSelf.initialPlaybackTime == 0 && episode.duration < 5)
        {
            // update position on consumable
            AVPlayerItem* item = weakSelf.player.currentItem;
            
            CMTime duration = item.asset.duration;
            NSInteger dur = (duration.timescale != 0) ? duration.value/duration.timescale : 0;
            
            // add duration parameter to episode if there is none
            episode.duration = (int32_t)dur;
            [DMANAGER save];
        }
        // handle auto skip end
        /*NSInteger periodFeedEnd = [episode.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_end_period", episode.feed.uid]];
        NSInteger periodGeneralEnd =  [USER_DEFAULTS integerForKey:PlayerAutoSkipEndPeriod];
        NSInteger period = periodFeedEnd != 0 ? periodFeedEnd : periodGeneralEnd;
        if (period > 0) {
            AVPlayerItem* item = weakSelf.player.currentItem;
            CMTime duration = item.asset.duration;
            NSInteger dur = (duration.timescale != 0) ? duration.value/duration.timescale : 0;
            NSInteger currentTime = CMTimeGetSeconds(time);
            if (currentTime >= dur - period) {
                [weakSelf.player pause];
                [weakSelf close];
                
                _changingPosition = YES;
                episode.consumed = YES;
                episode.position = 0;
                
                [DMANAGER setEpisode:episode position:(double)dur];
                _changingPosition = NO;
                [DMANAGER save];
            }
        }*/
        
        // Handle auto skip end
        double periodFeedEnd = [episode.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_end_period", episode.feed.uid]];
        double periodGeneralEnd = [USER_DEFAULTS doubleForKey:PlayerAutoSkipEndPeriod];
        double skipEndPeriod = (periodFeedEnd != 0.0) ? periodFeedEnd : periodGeneralEnd;

        if (skipEndPeriod > 0.0 && !episode.consumed) {
            AVPlayerItem *item = weakSelf.player.currentItem;
            CMTime duration = item.asset.duration;

            // Only proceed if duration is valid and fully loaded
            if (CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
                double dur = CMTimeGetSeconds(duration);

                // Ensure duration is valid and greater than the skip period
                if (dur > skipEndPeriod) {
                    double currentTime = CMTimeGetSeconds(time);
                    double skipTriggerTime = dur - skipEndPeriod;

                    if (currentTime >= skipTriggerTime && currentTime < dur) {
                        AudioSession *session = [AudioSession sharedAudioSession];
                        [weakSelf _logPlaybackAutoSkipEvent:@"Auto-Skip-Ende ausgelöst"
                                                    episode:episode
                                                currentTime:currentTime
                                                   duration:dur
                                                   metadata:@{
                                                       @"skipEndPeriod": @(skipEndPeriod),
                                                       @"skipTriggerTime": @(skipTriggerTime),
                                                       @"feedSkipEndPeriod": @(periodFeedEnd),
                                                       @"globalSkipEndPeriod": @(periodGeneralEnd),
                                                   }];

                        self->_changingPosition = YES;
                        if (!episode.consumed) {
                            [USER_DEFAULTS setInteger:[USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"] + 1 forKey:@"TotalEpisodesPlayedCount"];
                        }
                        episode.consumed = YES;
                        episode.position = 0;

                        [DMANAGER setEpisode:episode position:dur];
                        self->_changingPosition = NO;
                        [DMANAGER save];
                        // Remove consumed episode from Up Next playlist
                        [session eraseEpisodesFromUpNext:@[episode]];
                        CDEpisode *nextEpisode = [session nextPlayableEpisode];
                        [weakSelf _logPlaybackAutoSkipEvent:@"Auto-Skip-Ende abgeschlossen"
                                                    episode:episode
                                                currentTime:currentTime
                                                   duration:dur
                                                   metadata:@{
                                                       @"skipEndPeriod": @(skipEndPeriod),
                                                       @"skipTriggerTime": @(skipTriggerTime),
                                                       @"feedSkipEndPeriod": @(periodFeedEnd),
                                                       @"globalSkipEndPeriod": @(periodGeneralEnd),
                                                       @"nextEpisodeHash": nextEpisode.objectHash ?: @"",
                                                   }];
                        if (nextEpisode) {
                            weakSelf.inTransitionToNextTrack = YES;
                            [session playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES];
                        } else {
                            [weakSelf closeAndSaveCurrentPosition:NO];
                        }
                    }
                }
            }
        }

        
        if (weakSelf.player.rate > 0)
        {
            __strong PlaybackManager* strongSelf = weakSelf;
            float targetRate = strongSelf->_playbackRate;
            if (targetRate <= 0) targetRate = [weakSelf rateFromSpeedControl:weakSelf.speedControl];
            if (fabs(weakSelf.player.rate - targetRate) > 0.02) {
                weakSelf.player.rate = targetRate;
            }

            NSInteger chapter = weakSelf.currentChapter;
            NSInteger artwork = weakSelf.currentArtwork;
            [weakSelf _findAndSetCurrentChapter:-1];
            [weakSelf _findAndSetCurrentArtwork];
            if (weakSelf.currentChapter > -1) {
                [weakSelf nextTimeAfterSkipChapter:episode];
            }
            
            if (weakSelf.currentChapter != chapter || weakSelf.currentArtwork != artwork) {
                [weakSelf _setNowPlayingInfoOfEpisode:episode];
            }
        }

        [weakSelf willChangeValueForKey:@"time"];
        [weakSelf didChangeValueForKey:@"time"];
        
        [weakSelf _sendUpdateNotification];
    }];
    
    
    self.temporaryPositionObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(5,25000) queue:NULL usingBlock:^(CMTime time) {
        if (weakSelf.ready) {
            [weakSelf _temporarySavePosition];
        }
    }];

    self.savedPositionObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(30,25000) queue:NULL usingBlock:^(CMTime time) {
        if (weakSelf.ready && !weakSelf.paused) {
            [weakSelf _saveCurrentPlaybackPosition];
            [weakSelf _logBackgroundPlaybackCheckpointIfNeeded];
        }
    }];
    
    [self.playingEpisode addTaskObserver:self forKeyPath:@"position" task:^(id obj, NSDictionary *change) {
        if (!weakSelf.changingPosition && weakSelf.paused) {
            [weakSelf seekToTime:weakSelf.playingEpisode.position];
        }
    }];

    self.state = InitializedState;
    
    SEND_UPDATE
}

- (NSMutableDictionary*)_playbackDiagnosticsMetadataForEpisode:(CDEpisode*)episode currentTime:(NSTimeInterval)currentTime duration:(NSTimeInterval)duration
{
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    metadata[@"episodeHash"] = episode.objectHash ?: @"";
    metadata[@"currentTime"] = @(currentTime);
    metadata[@"duration"] = @(duration);
    metadata[@"playerRate"] = @(self.player.rate);
    metadata[@"state"] = @(self.state);
    metadata[@"autoSkipMarkerCount"] = @(self.autoSkipMarkers.count);
    metadata[@"suppressedSkipMarker"] = @(self.suppressedSkipMarker);
    metadata[@"isAutoSkipping"] = @(self.isAutoSkipping);
    return metadata;
}

- (void)_logPlaybackAutoSkipEvent:(NSString*)message episode:(CDEpisode*)episode currentTime:(NSTimeInterval)currentTime duration:(NSTimeInterval)duration metadata:(NSDictionary*)extraMetadata
{
    NSMutableDictionary *metadata = [self _playbackDiagnosticsMetadataForEpisode:episode currentTime:currentTime duration:duration];
    if (extraMetadata.count > 0) {
        [metadata addEntriesFromDictionary:extraMetadata];
    }
    [[ICDiagnosticLogger shared] logEvent:@"playback-auto-skip" message:message metadata:metadata];
}

- (NSString *)matchingSkipNameForChapter:(ICMetadataChapter *)chapterObj withNames:(NSArray *)skipNames {
    if (!chapterObj.title || skipNames.count == 0) {
        return nil;
    }
    NSString *lowerTitle = chapterObj.title.lowercaseString;
    for (NSString *skipName in skipNames) {
        if (skipName.length > 0 && [lowerTitle containsString:skipName.lowercaseString]) {
            return skipName;
        }
    }
    return nil;
}

- (BOOL)_autoSkipSponsorsEnabledForFeed:(CDFeed*)feed
{
    NSString* value = [feed stringForKey:kFeedPropertyAutoSkipSponsors];
    if ([value isEqualToString:@"yes"]) {
        return YES;
    }
    if ([value isEqualToString:@"no"]) {
        return NO;
    }
    return [USER_DEFAULTS boolForKey:kAutoSkipSponsors];
}

- (NSString*)_skipNameForChapter:(ICMetadataChapter*)chapter withNames:(NSArray*)skipNames includeGeneratedSponsors:(BOOL)includeGeneratedSponsors
{
    if (includeGeneratedSponsors && chapter.generatedSponsor) {
        return ICGeneratedSponsorSkipName;
    }
    return [self matchingSkipNameForChapter:chapter withNames:skipNames];
}

- (void)nextTimeAfterSkipChapter:(CDEpisode *)episode {
    if (self.isAutoSkipping) return;
    if (!self.autoSkipMarkers || self.autoSkipMarkers.count == 0) return;
    if (self.lastAutoSkipDate && [[NSDate date] timeIntervalSinceDate:self.lastAutoSkipDate] < 1.0) return;

    NSTimeInterval currentTime = [self time];

    for (NSInteger i = 0; i < (NSInteger)self.autoSkipMarkers.count; i++) {
        NSDictionary *marker = self.autoSkipMarkers[i];
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];

        if (currentTime >= skipStart) {
            // Manual seek protection: don't re-skip if user deliberately seeked here
            if (i == self.suppressedSkipMarker) continue;

            if (resumeTime < 0) {
                // All remaining chapters are skip → finish episode
                [self _logPlaybackAutoSkipEvent:@"Kapitel-Skip beendet Episode"
                                        episode:episode
                                    currentTime:currentTime
                                       duration:self.duration
                                       metadata:@{
                                           @"markerIndex": @(i),
                                           @"skipStart": @(skipStart),
                                           @"resumeTime": @(resumeTime),
                                       }];
                [self _finishEpisodeDueToSkip:episode];
                return;
            }

            if (currentTime < resumeTime) {
                // We're in the skip zone → jump to resume point
                [self _logPlaybackAutoSkipEvent:@"Kapitel-Skip springt zu Resume-Zeit"
                                        episode:episode
                                    currentTime:currentTime
                                       duration:self.duration
                                       metadata:@{
                                           @"markerIndex": @(i),
                                           @"skipStart": @(skipStart),
                                           @"resumeTime": @(resumeTime),
                                       }];
                self.isAutoSkipping = YES;
                self.lastAutoSkipDate = [NSDate date];
                [self seekToTime:resumeTime tolerance:NO];
                self.isAutoSkipping = NO;
                return;
            }
            // currentTime >= resumeTime → already past this marker, check next
        }
    }
}

- (void)_finishEpisodeDueToSkip:(CDEpisode *)episode {
    self.isAutoSkipping = YES;
    AVPlayerItem *item = self.player.currentItem;
    CMTime duration = item.asset.duration;
    NSTimeInterval durationSeconds = 0;
    if (CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
        durationSeconds = CMTimeGetSeconds(duration);
        if (durationSeconds < 0) {
            durationSeconds = 0;
        }
    }
    AudioSession *session = [AudioSession sharedAudioSession];
    NSInteger dur = (NSInteger)durationSeconds;
    NSTimeInterval currentTime = [self time];
    [self _logPlaybackAutoSkipEvent:@"Kapitel-Skip-Episodenabschluss gestartet"
                            episode:episode
                        currentTime:currentTime
                           duration:durationSeconds
                           metadata:nil];
    _changingPosition = YES;
    if (!episode.consumed) {
        [USER_DEFAULTS setInteger:[USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"] + 1 forKey:@"TotalEpisodesPlayedCount"];
    }
    episode.consumed = YES;
    episode.position = 0;
    [DMANAGER setEpisode:episode position:(double)dur];
    _changingPosition = NO;
    [DMANAGER save];
    // Remove consumed episode from Up Next playlist
    [session eraseEpisodesFromUpNext:@[episode]];
    CDEpisode *nextEpisode = [session nextPlayableEpisode];
    [self _logPlaybackAutoSkipEvent:@"Kapitel-Skip-Episodenabschluss gespeichert"
                            episode:episode
                        currentTime:currentTime
                           duration:durationSeconds
                           metadata:@{
                               @"savedPosition": @(dur),
                               @"nextEpisodeHash": nextEpisode.objectHash ?: @"",
                           }];
    self.isAutoSkipping = NO;
    if (nextEpisode) {
        self.inTransitionToNextTrack = YES;
        [session playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES];
    } else {
        [self closeAndSaveCurrentPosition:NO];
    }
}


- (void) playerItemDidPlayToEndTimeNotification:(NSNotification*)notification
{
    CDEpisode* episode = self.playingEpisode;
    AudioSession* session = [AudioSession sharedAudioSession];

    // only mark episode as played if we actually finished playing this episode
    // could end prematurely if streaming and internet not available
    if (episode && [self time] > [self duration] - 10)
    {
        _changingPosition = YES;
        if (!episode.consumed) {
            [USER_DEFAULTS setInteger:[USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"] + 1 forKey:@"TotalEpisodesPlayedCount"];
        }
        episode.consumed = YES;
        episode.position = 0;
        _changingPosition = NO;

        [self _removeTemporarySavePosition];
        [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerEpisodeDidFinishNotification object:self];

        // Remove consumed episode from Up Next playlist
        [session eraseEpisodesFromUpNext:@[episode]];

        if ([episode.feed boolForKey:AutoDeleteAfterFinishedPlaying] && !episode.starred) {
            session.autoStopDisabled = YES;
            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:YES];
            session.autoStopDisabled = NO;
        }

        CDEpisode* nextEpisode = [session nextPlayableEpisode];
        if (nextEpisode) {
            self.inTransitionToNextTrack = YES;
            [session playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES];
        }
        else {
            [self closeAndSaveCurrentPosition:NO];
        }

        
#if TARGET_OS_IPHONE==0
        [[ICSharingManager sharedManager] triggerEvent:ICSharingServiceEpisodeDidEndPlaying object:episode];
#endif
    }

    else
    {
        [self closeAndSaveCurrentPosition:NO];
    }
}

- (void) _temporarySavePosition
{
    if (!self.paused)
    {
        CDEpisode* episode = self.playingEpisode;
        NSString* key = self.playingEpisode.objectHash;
        
        NSMutableDictionary* playbackPositions = [[USER_DEFAULTS objectForKey:kDefaultTemporaryPlaybackPositions] mutableCopy];
        if (!playbackPositions) {
            playbackPositions = [[NSMutableDictionary alloc] init];
        }
        
        // update position on consumable
        AVPlayerItem* item = self.player.currentItem;
        if (item && episode && key) {
            CMTime current = [item currentTime];
            NSInteger cur = (current.timescale != 0) ? current.value/current.timescale : 0;

            [playbackPositions setObject:@(cur) forKey:key];
            [USER_DEFAULTS setObject:playbackPositions forKey:kDefaultTemporaryPlaybackPositions];
        }
    }
}

- (void) _removeTemporarySavePosition
{
    NSString* key = self.playingEpisode.objectHash;
    
    NSMutableDictionary* playbackPositions = [[USER_DEFAULTS objectForKey:kDefaultTemporaryPlaybackPositions] mutableCopy];
    [playbackPositions removeObjectForKey:key];
    [USER_DEFAULTS setObject:playbackPositions forKey:kDefaultTemporaryPlaybackPositions];
}

- (void) _saveCurrentPlaybackPosition
{
    CDEpisode* episode = self.playingEpisode;
    
    // update position on consumable
    AVPlayerItem* item = self.player.currentItem;
    if (item && episode) {
        CMTime current = [item currentTime];
        NSInteger cur = (current.timescale != 0) ? current.value/current.timescale : 0;

        _changingPosition = YES;
        [DMANAGER setEpisode:episode position:(double)cur];
        _changingPosition = NO;
        [DMANAGER save];//DevD to do
        
        [self _removeTemporarySavePosition];
    }
}

- (void)_logBackgroundPlaybackCheckpointIfNeeded
{
#if TARGET_OS_IPHONE
    if (App.applicationState != UIApplicationStateBackground) {
        return;
    }
    NSDate* now = [NSDate date];
    if (self.lastBackgroundPlaybackDiagnosticDate && [now timeIntervalSinceDate:self.lastBackgroundPlaybackDiagnosticDate] < 60.0) {
        return;
    }
    self.lastBackgroundPlaybackDiagnosticDate = now;
    CDEpisode* episode = self.playingEpisode;
    [[ICDiagnosticLogger shared] logEvent:@"background-playback"
                                  message:@"Hintergrund-Playback-Checkpoint"
                                 metadata:@{
                                     @"episodeHash": episode.objectHash ?: @"",
                                     @"currentTime": @(self.time),
                                     @"duration": @(self.duration),
                                     @"playbackReady": @(self.ready),
                                     @"playbackPaused": @(self.paused),
                                     @"playerRate": @(self.player.rate),
                                     @"backgroundTimeRemaining": @(App.backgroundTimeRemaining),
                                 }];
#endif
}

- (void) restart
{
	CDEpisode* episode = self.playingEpisode;
	
	self.changingEpisode = YES;
    [self openWithEpisode:episode at:0 autostart:YES];
}

- (void) close
{
    [self closeAndSaveCurrentPosition:YES];
}

- (void) closeAndSaveCurrentPosition:(BOOL)saveCurrentPosition
{
	// stop the skipping thing in case the user holds down the buttons until the end
    self.ready = NO;

#if TARGET_OS_IPHONE
    ICStreamingCacheLoader* streamLoader = self.streamCacheLoader;
    self.streamCacheLoader = nil;
    self.streamingCacheActive = NO;
    self.streamingCacheProgress = 0.0;
    self.streamingCacheComplete = NO;
    if (streamLoader) {
        if ([USER_DEFAULTS boolForKey:AutoDownloadWhileStreaming] && !streamLoader.cacheComplete) {
            [streamLoader detachFromPlaybackAndContinueCaching];
        } else {
            [streamLoader stop];
        }
    }
#endif

    // Reset chapter skip protection
    self.isAutoSkipping = NO;
    self.lastAutoSkipDate = nil;
    self.autoSkipMarkers = nil;
    self.suppressedSkipMarker = -1;

	[self.controlTimer invalidate];
	self.controlTimer = nil;
	
	[self.mediaAsset cancelLoading];
	self.mediaAsset = nil;
	
    if (!self.changingEpisode) {
        [self _endNextItemHandover];
    }
	
	if (self.player)
	{
        if (saveCurrentPosition) {
            [self _saveCurrentPlaybackPosition];
        }
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem];
        
        
        if (self.player.rate > 0) {
			[self.player pause];
		}
        
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"status"];
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"playbackBufferFull"];
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"loadedTimeRanges"];
        [self.player removeTaskObserver:self forKeyPath:@"rate"];

		if (self.playbackObserver) { 
			[self.player removeTimeObserver:self.playbackObserver]; 
			self.playbackObserver = nil;
		}
        
        if (self.temporaryPositionObserver) {
            [self.player removeTimeObserver:self.temporaryPositionObserver];
            self.temporaryPositionObserver = nil;
        }
        
        if (self.savedPositionObserver) {
            [self.player removeTimeObserver:self.savedPositionObserver];
            self.savedPositionObserver = nil;
        }
        
        [self.playingEpisode removeTaskObserver:self forKeyPath:@"position"];
		
		[self.playerView removeFromSuperview];
		self.playerView = nil;
		
		//_state = IdleState;
		self.ready = NO;
        
		self.chapters = nil;
        if (_chapterTimesIdx) {
            free(_chapterTimesIdx);
            _chapterTimesIdx = NULL;
        }
        
        self.artworks = nil;
        if (_artworkTimesIdx) {
            free(_artworkTimesIdx);
            _artworkTimesIdx = nil;
        }
		
		self.player = nil;
        [self _setupRemotePlaybackCenterWithEpisode:nil];
	}
    
    if (!self.changingEpisode && self.playingEpisode) {
        self.playingEpisode = nil;
        [[AudioSession sharedAudioSession] clear];
        [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerDidEndNotification object:self];
    }
}

+ (NSSet*) keyPathsForValuesAffectingVolume {
    return [NSSet setWithObject:@"ready"];
}

- (float) volume
{
    return [USER_DEFAULTS floatForKey:kDefaultPlaybackVolume];
}

- (void) setVolume:(float)volume
{
    if (_volume != volume) {
        _volume = volume;

        self.player.volume = volume;
        [USER_DEFAULTS setFloat:volume forKey:kDefaultPlaybackVolume];
    }
}

+ (NSSet*) keyPathsForValuesAffectingWaitingForLoad {
    return [NSSet setWithObject:@"state"];
}


- (BOOL) isWaitingForLoad {
    return (self.state == ShouldRunState);
}

+ (NSSet*) keyPathsForValuesAffectingPaused {
    return [NSSet setWithObjects:@"state", @"player.rate", nil];
}

- (BOOL) isPaused
{
    if (self.state == ShouldRunState) {
        return NO;
    }
    
	return (self.player.rate == 0 && self.state != InitializedState);
}

- (BOOL) isPodcastPlaying
{
    float rate = self.player.rate;
    if (rate > 0)
    {
        return YES;
    }
    else
    {
        return NO;
    }
}

- (void) useCachedFileIfAvailableAfterStreamingDownload
{
#if TARGET_OS_IPHONE
    if (!self.player || !self.streamCacheLoader || !self.playingEpisode) {
        return;
    }
    if (!self.streamCacheLoader.cacheComplete || ![[CacheManager sharedCacheManager] episodeIsCached:self.playingEpisode]) {
        return;
    }

    CDEpisode* episode = self.playingEpisode;
    NSTimeInterval resumeTime = [self time];
    if (self.seekingPositionChangeDate && [self.seekingPositionChangeDate timeIntervalSinceNow] > -1 && self.duration > 0) {
        resumeTime = self.seekingPosition * self.duration;
    }

    BOOL wasPlaying = (self.player.rate > 0 || self.state == ShouldRunState);
    [self openWithEpisode:episode at:resumeTime autostart:wasPlaying];
#endif
}

- (BOOL) cancelStreamingCacheForEpisode:(CDEpisode*)episode
{
#if TARGET_OS_IPHONE
    NSString* episodeHash = episode.objectHash;
    if (episodeHash.length == 0) {
        return NO;
    }

    BOOL stoppedLoader = [ICStreamingCacheLoader cancelDetachedLoaderForEpisodeHash:episodeHash];
    if (self.streamCacheLoader && [self.streamCacheLoader matchesEpisodeHash:episodeHash]) {
        BOOL hasPlayer = (self.player != nil);
        NSTimeInterval resumeTime = hasPlayer ? [self time] : 0;
        if (self.seekingPositionChangeDate && [self.seekingPositionChangeDate timeIntervalSinceNow] > -1 && self.duration > 0) {
            resumeTime = self.seekingPosition * self.duration;
        }
        BOOL wasPlaying = (self.player.rate > 0 || self.state == ShouldRunState);

        ICStreamingCacheLoader* loader = self.streamCacheLoader;
        self.streamCacheLoader = nil;
        self.streamingCacheActive = NO;
        self.streamingCacheProgress = 0.0;
        self.streamingCacheComplete = NO;
        [loader cancelAndDiscardPartialCache];
        [[CacheManager sharedCacheManager] finishStreamingCacheForEpisode:episode];
        stoppedLoader = YES;

        if (hasPlayer) {
            [self openWithEpisode:episode at:resumeTime autostart:wasPlaying];
        } else {
            [self _sendUpdateNotification];
        }
    }
    return stoppedLoader;
#else
    return NO;
#endif
}

- (void) play
{
    BOOL hasRecentSeek = (self.seekingPositionChangeDate && [self.seekingPositionChangeDate timeIntervalSinceNow] > -1);

	// rewind 30 seconds if we paused more than 10 mins
	if (self.lastPauseDate)
	{
		if (!hasRecentSeek && [USER_DEFAULTS boolForKey:PlayerReplayAfterPause] && [[NSDate date] timeIntervalSinceDate:self.lastPauseDate] > 600)
		{
			CMTime current = [self.player.currentItem currentTime];
			NSInteger cur = (current.timescale != 0) ? current.value/current.timescale : 0;
			NSTimeInterval next = MAX(cur-30, 0);
			[self seekToTime:next];
		}
			self.lastPauseDate = nil;
		}
		
    // When stream-caching finished in the background, switch to local file on the next explicit resume.
#if TARGET_OS_IPHONE
    if (self.paused && self.streamCacheLoader && self.playingEpisode && [[CacheManager sharedCacheManager] episodeIsCached:self.playingEpisode]) {
        NSTimeInterval resumeTime = [self time];
        if (hasRecentSeek && self.duration > 0) {
            resumeTime = self.seekingPosition * self.duration;
        }
        [self openWithEpisode:self.playingEpisode at:resumeTime autostart:YES];
        return;
    }
#endif

	float targetRate = _playbackRate > 0 ? _playbackRate : [self rateFromSpeedControl:self.speedControl];
	self.player.rate = targetRate;

    self.playStartDate = [NSDate date];
	SEND_UPDATE
}

- (void) pause
{
    if (!self.paused)
    {
        [self.player pause];
        self.lastPauseDate = [NSDate date];

        // Track cumulative listening time
        if (self.playStartDate) {
            NSTimeInterval delta = [self.lastPauseDate timeIntervalSinceDate:self.playStartDate];
            if (delta > 0) {
                double total = [USER_DEFAULTS doubleForKey:@"TotalListeningTime"];
                [USER_DEFAULTS setDouble:total + delta forKey:@"TotalListeningTime"];
            }
            self.playStartDate = nil;
        }

        // prevent starting auto-playback when playthrough available
        self.state = RunningState;

        [self _saveCurrentPlaybackPosition];
        SEND_UPDATE
    }
}

- (void) playPause
{
    if (self.paused) {
        [self play];
        [self updateNowPlayingInfo];
    } else {
        [self pause];
    }
}

- (void) seekToTime:(NSTimeInterval)time
{
	[self seekToTime:time tolerance:YES];
}

// If time falls inside a skip zone, return one full skip-back duration before the zone start.
- (NSTimeInterval)_adjustTimeBeforeSkipZone:(NSTimeInterval)time {
    if (!self.autoSkipMarkers) return time;
    for (NSDictionary *marker in self.autoSkipMarkers) {
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];
        if (resumeTime > 0 && time >= skipStart && time < resumeTime) {
            NSInteger skipPeriod = [self.playingEpisode.feed integerForKey:PlayerSkipBackPeriod];
            return MAX(skipStart - skipPeriod, 0);
        }
    }
    return time;
}

// If time falls inside a skip zone, return the resume point after the zone (for forward seek).
- (NSTimeInterval)_adjustTimeAfterSkipZone:(NSTimeInterval)time {
    if (!self.autoSkipMarkers) return time;
    for (NSDictionary *marker in self.autoSkipMarkers) {
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];
        if (resumeTime > 0 && time >= skipStart && time < resumeTime) {
            return resumeTime;
        }
    }
    return time;
}

- (void)_suppressAutoSkipMarkerAtTime:(NSTimeInterval)time {
    if (!self.autoSkipMarkers) return;
    self.suppressedSkipMarker = -1;
    for (NSInteger i = 0; i < (NSInteger)self.autoSkipMarkers.count; i++) {
        NSDictionary *marker = self.autoSkipMarkers[i];
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];
        if (resumeTime > 0 && time >= skipStart && time < resumeTime) {
            self.suppressedSkipMarker = i;
            break;
        }
    }
}

- (void) seekToTime:(NSTimeInterval)time tolerance:(BOOL)tolerance
{
    NSTimeInterval duration = self.duration;
    if (duration > 0) {
        self.seekingPosition = MIN(MAX(time / duration, 0), 1);
        self.seekingPositionChangeDate = [NSDate date];
        [self willChangeValueForKey:@"time"];
        [self didChangeValueForKey:@"time"];
    }

	CMTime current = CMTimeMake((int64_t)(time*1000), 1000);
    void (^finishSeekUpdate)(BOOL) = ^(BOOL finished) {
        if (!finished) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _findAndSetCurrentChapter:-1];
            [self _findAndSetCurrentArtwork];
            [self coalescedPerformSelector:@selector(_setNowPlayingInfoOfEpisode:) object:self.playingEpisode afterDelay:1.0];
            SEND_UPDATE

            if (self.paused && !self.seeking) {
                [self _saveCurrentPlaybackPosition];
            }
        });
    };

    // Suppress auto-skip marker is handled by callers that represent deliberate position
    // choices (setPosition:, seekToChapter:) — NOT here, so skip buttons still trigger auto-skip
    if (!tolerance) {
        [self.player seekToTime:current
                toleranceBefore:CMTimeMake(0, 1000)
                 toleranceAfter:CMTimeMake(1000, 1000)
              completionHandler:finishSeekUpdate];
    } else {
        [self.player seekToTime:current completionHandler:finishSeekUpdate];
    }
}

- (void) seekToChapter:(ICMetadataChapter*)chapter
{
    // fix chapter display for 5 seconds due to seeking fuzzyness
    self.seekingChapter = chapter;
    
    [self perform:^(id sender) {
        self.seekingChapter = nil;
        [self _findAndSetCurrentChapter:-1];
    } afterDelay:5.0];
    
    NSTimeInterval time = CMTimeGetSeconds(chapter.start);
    [self _suppressAutoSkipMarkerAtTime:time];
    [self seekToTime:time tolerance:NO];
}

- (NSTimeInterval) _scrubbTime
{
	NSTimeInterval t = [[NSDate date] timeIntervalSinceDate:self.controlStartDate];
	if (t < 1) {
		return 1.0f;
	}
	else if (t < 2) {
		return 2.0f;
	}
	else if (t < 3) {
		return 5.0f;
	}
	else if (t < 4) {
		return 10.0f;
	}
	else if (t < 5) {
		return 15.0f;
	}
	else if (t < 6) {
		return 30.0f;
	}
	else if (t < 7) {
		return 60.0f;
	}
	else if (t < 8) {
		return 120.0f;
	}
	
	return 240.0f;
}

- (void) _scrubb:(NSTimeInterval)time
{
	NSInteger cur = self.time;
	NSInteger dur = self.duration;
	
	NSTimeInterval t = MIN(MAX(cur+time,0),dur);
	[self seekToTime:t];
}


- (void) _backwardScrubb:(NSTimer*)timer
{
	NSTimeInterval scrubTime = [self _scrubbTime];
	[self _scrubb:-scrubTime];
}

- (void) _forwardScrubb:(NSTimer*)timer
{
	NSTimeInterval scrubTime = [self _scrubbTime];
	[self _scrubb:scrubTime];
}


- (void) beginSeekingBackward
{
    self.seeking = YES;
	[self.controlTimer invalidate];
	self.controlTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_backwardScrubb:) userInfo:nil repeats:YES];
	self.controlStartDate = [NSDate date];
}

- (void) beginSeekingForward
{
    self.seeking = YES;
	[self.controlTimer invalidate];
	self.controlTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_forwardScrubb:) userInfo:nil repeats:YES];
	self.controlStartDate = [NSDate date];
}

- (void) endSeeking
{
	[self.controlTimer invalidate];
	self.controlTimer = nil;
	self.controlStartDate = nil;
    self.seeking = NO;
    
    if (self.paused) {
        [self _saveCurrentPlaybackPosition];
    }
}

- (void) seekForward
{
    CDFeed* feed = self.playingEpisode.feed;
    
	NSInteger skipPeriod = [feed integerForKey:PlayerSkipForwardPeriod];
	
	NSInteger cur = self.time;
	NSInteger dur = self.duration;
	
	NSInteger next = MIN(dur-1,cur + skipPeriod);
	if (next < dur) {
		[self seekToTime:[self _adjustTimeAfterSkipZone:next]];
	}
}

- (void) seekBackward
{
    CDFeed* feed = self.playingEpisode.feed;

	NSInteger skipPeriod = [feed integerForKey:PlayerSkipBackPeriod];
	NSTimeInterval cur = self.time;
	NSInteger next = MAX(cur - skipPeriod,0);
    if (cur > 2) {
        [self seekToTime:[self _adjustTimeBeforeSkipZone:next]];
    }
}


- (void) rewind30Seconds
{
	NSTimeInterval cur = self.time;
	NSInteger next = MAX(cur - 30, 0);
	[self seekToTime:[self _adjustTimeBeforeSkipZone:next]];
}

- (BOOL) hasPlaylist
{
    return ([[AudioSession sharedAudioSession].playlist count] > 1);
}

- (void) nextTrack
{
    CDEpisode* episode = self.playingEpisode;
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    NSInteger index = [playlist indexOfObject:episode];

    if ([playlist count] < 1 || index == NSNotFound) {
        return;
    }

    CDEpisode* nextEpisode = nil;

    // if not last item, play next item
    if (index < [playlist count]-1) {
        nextEpisode = [playlist objectAtIndex:index+1];
    }
    // if last item, play the first item
    else {
        nextEpisode = [playlist objectAtIndex:0];
    }

    if (nextEpisode) {
        [[AudioSession sharedAudioSession] playEpisode:nextEpisode];
    }
}

- (void) previousTrack
{
    CDEpisode* episode = self.playingEpisode;
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    NSInteger index = [playlist indexOfObject:episode];

    if ([playlist count] == 0 || index == NSNotFound) {
        return;
    }

    CDEpisode* previousEpisode = nil;

    // if not first item, play previous item
    if (index > 0) {
        previousEpisode = [playlist objectAtIndex:index-1];
    }
    // if first item, play last item
    else {
        previousEpisode = [playlist lastObject];
    }

    if (previousEpisode) {
        [[AudioSession sharedAudioSession] playEpisode:previousEpisode];
    }
}

- (void) nextChapter
{
    if (self.currentChapter < [self.chapters count]-1)
    {
        ICMetadataChapter* nextChapter = [self.chapters objectAtIndex:self.currentChapter+1];
        NSTimeInterval time = (NSTimeInterval)CMTimeGetSeconds(nextChapter.start);
        
        [self seekToTime:time tolerance:NO];
    }
}

- (void) previousChapter
{
    if (self.currentChapter > 0)
    {
        ICMetadataChapter* previousChapter = [self.chapters objectAtIndex:self.currentChapter-1];
        NSTimeInterval time = (NSTimeInterval)CMTimeGetSeconds(previousChapter.start);

        [self seekToTime:time tolerance:NO];
    }
}

- (float)rateFromSpeedControl:(PlaybackSpeedControl)control
{
    switch (control) {
        case PlaybackSpeedControlMinusHalfSpeed:    return 0.5f;
        case PlaybackSpeedControlThreeQuarterSpeed: return 0.75f;
        case PlaybackSpeedControlNormalSpeed:        return 1.0f;
        case PlaybackSpeedControlFaster11:           return 1.1f;
        case PlaybackSpeedControlFaster12:           return 1.2f;
        case PlaybackSpeedControlFaster125:          return 1.25f;
        case PlaybackSpeedControlFaster13:           return 1.3f;
        case PlaybackSpeedControlPlusHalfSpeed:      return 1.5f;
        case PlaybackSpeedControlDoubleSpeed:        return 2.0f;
        case PlaybackSpeedControlTripleSpeed:        return 3.0f;
        default:                                     return 1.0f;
    }
}

- (void)setPlaybackRate:(float)rate
{
    rate = MAX(0.5f, MIN(3.0f, rate));
    _playbackRate = rate;
    if (self.player.rate > 0) {
        self.player.rate = rate;
    }
}

- (void) setSpeedControl:(PlaybackSpeedControl)_speed
{
	if (_speedControl != _speed) {
		_speedControl = _speed;
		_playbackRate = [self rateFromSpeedControl:_speed];

        [USER_DEFAULTS setInteger:_speed forKey:DefaultPlaybackSpeed];

		if (self.player.rate > 0) {
            self.player.rate = _playbackRate;
        }

		SEND_UPDATE
	}
}

- (void) updateForSpeedControlSettingsChanged
{
    CDFeed* feed = self.playingEpisode.feed;
    _speedControl = [feed integerForKey:DefaultPlaybackSpeed];
    _playbackRate = [self rateFromSpeedControl:_speedControl];

    if (self.player.rate > 0) {
        self.player.rate = _playbackRate;
    }
}

+ (NSSet*) keyPathsForValuesAffectingPosition
{
    return [NSSet setWithObjects:@"time", @"duration", @"ready", nil];
}

- (double) position
{
    if (self.seekingPositionChangeDate && [self.seekingPositionChangeDate timeIntervalSinceNow] > -1) {
        return self.seekingPosition;
    }
    
    return (self.duration > 0) ? self.time / self.duration : 0;
}

- (void) setPosition:(double)position
{
	NSTimeInterval time = [self duration]*position;
	[self _suppressAutoSkipMarkerAtTime:time];
	[self seekToTime:time];
    
    self.seekingPosition = position;
    self.seekingPositionChangeDate = [NSDate date];
}

+ (NSSet*) keyPathsForValuesAffectingPlayablePosition
{
    return [NSSet setWithObjects:@"playableDuration", @"duration", nil];
}

- (double) playablePosition
{
    return (self.duration > 0) ? self.playableDuration / self.duration : 0;
}

- (NSTimeInterval) time
{
	AVPlayerItem* item = self.player.currentItem;
	CMTime current = [item currentTime];
	NSTimeInterval time = (current.timescale > 0) ? (NSTimeInterval)current.value/(NSTimeInterval)current.timescale : 0;
    return MIN(time, self.duration);
}

- (NSTimeInterval) duration
{
	AVPlayerItem* item = self.player.currentItem;
    AVAsset* asset = item.asset;
    
    AVKeyValueStatus status = [asset statusOfValueForKey:@"duration" error:nil];
    if (status == AVKeyValueStatusLoaded) {
        CMTime duration = item.asset.duration;
        NSTimeInterval dur = (duration.timescale > 0) ? (NSTimeInterval)duration.value/(NSTimeInterval)duration.timescale : 0;
        return floorf(dur);
    }
    
    return 0;
}

- (NSTimeInterval) playableDuration
{
	if (!self.player.currentItem) {
		return 0.0f;
	}
	
	AVPlayerItem* item = self.player.currentItem;
	CMTimeRange loadRange = [[item.loadedTimeRanges lastObject] CMTimeRangeValue];
	NSTimeInterval dur =  (NSTimeInterval)((double)loadRange.start.value / (double)loadRange.start.timescale + (double)loadRange.duration.value / (double)loadRange.duration.timescale);
    return floorf(dur);
}

- (void) stopAirPlayVideo
{
#if TARGET_OS_IPHONE
	if ([self.player respondsToSelector:@selector(allowsAirPlayVideo)]) {
		self.player.allowsExternalPlayback = NO;
	}
#endif
}

- (BOOL) isAirPlayVideoActive
{
#if TARGET_OS_IPHONE
	if ([self.player respondsToSelector:@selector(isAirPlayVideoActive)]) {
		return [self.player isExternalPlaybackActive];
	}
#endif
    return NO;
}

#pragma mark -

- (void) _findAndSetCurrentChapter:(NSTimeInterval)time
{
    if (self.seekingChapter) {
        NSUInteger idx = [self.chapters indexOfObject:self.seekingChapter];
        if (idx != NSNotFound) {
            self.currentChapter = idx;
            return;
        }
    }
    
	if (!_chapterTimesIdx) {
		return;
	}
	
    if (time < 0) {
        time = self.time;
    }
    
	NSInteger i;
	NSInteger c = -1;
	
	for(i=0; i<[self.chapters count]; i++)
	{
		if (time >= _chapterTimesIdx[i]) {
			c = i;
		} else {
			break;
		}
	}
	
    if (self.currentChapter != c) {
        self.currentChapter = c;
    }
}

- (void) _findAndSetCurrentArtwork
{
	if (!_artworkTimesIdx) {
		return;
	}
	
	NSTimeInterval time = self.time;
	
	NSInteger i;
	NSInteger c = -1;
	
	for(i=0; i<[self.artworks count]; i++)
	{
		if (time >= _artworkTimesIdx[i]) {
			c = i;
		} else {
			break;
		}
	}
	
    if (self.currentArtwork != c) {
        self.currentArtwork = c;
    }
}

#pragma mark -
#pragma mark Chapter Support

- (void) _generatedChaptersDidChange:(NSNotification*)notification
{
    NSString* hash = notification.userInfo[@"episodeHash"];
    if (!hash || !self.playingEpisode) return;
    if (![hash isEqualToString:self.playingEpisode.objectHash]) return;

    // Clear current chapters and reload
    if (_chapterTimesIdx) {
        free(_chapterTimesIdx);
        _chapterTimesIdx = NULL;
    }
    self.chapters = nil;
    [self _startLoadingChapters];
}

- (void) _startLoadingChapters
{
    NSString* episodeHash = self.playingEpisode.objectHash ?: @"";
    [[ICDiagnosticLogger shared] logEvent:@"chapter-load"
                                  message:@"Kapitel-Ladevorgang gestartet"
                                 metadata:@{
                                     @"episodeHash": episodeHash,
                                 }];

    ICMetadataParser* parser = [[ICMetadataParser alloc] initWithAsset:self.mediaAsset];
    [parser loadAsynchronouslyWithCompletionHandler:^(BOOL success, NSError *error) {
        
        NSArray* chapters = nil;

        // If the user generated chapters, make that explicit choice win. Otherwise a
        // media file with embedded chapters can make freshly generated chapters appear
        // to do nothing until the user deletes them.
        if (self.playingEpisode.objectHash.length > 0) {
            NSArray<ICGeneratedChapter*>* generated = [[ChapterGenerator shared] loadChaptersFor:self.playingEpisode.objectHash];
            if (generated.count > 0) {
                NSMutableArray* metaChapters = [NSMutableArray arrayWithCapacity:generated.count];
                for (ICGeneratedChapter* gch in generated) {
                    ICMetadataChapter* ch = [[ICMetadataChapter alloc] init];
                    ch.title = gch.title;
                    ch.start = CMTimeMakeWithSeconds(gch.start, NSEC_PER_SEC);
                    ch.end = CMTimeMakeWithSeconds(gch.end, NSEC_PER_SEC);
                    ch.generatedSponsor = gch.isSponsor;
                    [metaChapters addObject:ch];
                }
                chapters = metaChapters;
                [[ICDiagnosticLogger shared] logEvent:@"chapter-load"
                                              message:@"Generierte Kapitel für Playback geladen"
                                             metadata:@{
                                                 @"episodeHash": episodeHash,
                                                 @"chapterCount": @(generated.count),
                                             }];
            }
        }
        if (chapters == nil) {
            chapters = parser.metadataAsset.chapters;
            [[ICDiagnosticLogger shared] logEvent:@"chapter-load"
                                          message:@"Eingebettete Medien-Kapitel für Playback geladen"
                                         metadata:@{
                                             @"episodeHash": episodeHash,
                                             @"chapterCount": @([chapters count]),
                                             @"parserSuccess": @(success),
                                             @"error": error.localizedDescription ?: @"",
                                         }];
        }

        // create chapter index for fast chapter search
        self->_chapterTimesIdx = (float*)malloc(sizeof(float)*[chapters count]);
        [chapters enumerateObjectsUsingBlock:^(ICMetadataChapter* chapter, NSUInteger idx, BOOL *stop) {
            self->_chapterTimesIdx[idx] = (float)CMTimeGetSeconds(chapter.start);
        }];

        self.chapters = chapters;
        [self _findAndSetCurrentChapter:-1];
        [self _computeAutoSkipMarkers];


        NSArray* images = parser.metadataAsset.images;

        self->_artworkTimesIdx = (float*)malloc(sizeof(float)*[images count]);
        [images enumerateObjectsUsingBlock:^(ICMetadataImage* image, NSUInteger idx, BOOL *stop) {
            self->_artworkTimesIdx[idx] = (float)CMTimeGetSeconds(image.start);
        }];
        
        self.artworks = images;
        [self _findAndSetCurrentArtwork];
        
        [self _setNowPlayingInfoOfEpisode:self.playingEpisode];
        [self _sendUpdateNotification];
    }];
}

- (void)_computeAutoSkipMarkers {
    CDEpisode *episode = self.playingEpisode;
    if (!episode || !self.chapters || self.chapters.count == 0) {
        self.autoSkipMarkers = nil;
        if (episode) {
            [self _logPlaybackAutoSkipEvent:@"Auto-Skip-Marker berechnet"
                                    episode:episode
                                currentTime:[self time]
                                   duration:self.duration
                                   metadata:@{
                                       @"chapterCount": @(self.chapters.count),
                                       @"markerCount": @0,
                                       @"skipNameCount": @0,
                                       @"includeGeneratedSponsors": @(NO),
                                   }];
        }
        return;
    }

    NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", episode.feed.uid];
    NSString *chaptersName = [episode.feed stringForKey:key];
    NSArray *skipNames = (chaptersName.length > 0) ? [chaptersName componentsSeparatedByString:@".  "] : @[];
    BOOL includeGeneratedSponsors = [self _autoSkipSponsorsEnabledForFeed:episode.feed];
    if (skipNames.count == 0 && !includeGeneratedSponsors) {
        self.autoSkipMarkers = nil;
        [self _logPlaybackAutoSkipEvent:@"Auto-Skip-Marker berechnet"
                                episode:episode
                            currentTime:[self time]
                               duration:self.duration
                               metadata:@{
                                   @"chapterCount": @(self.chapters.count),
                                   @"markerCount": @0,
                                   @"skipNameCount": @(skipNames.count),
                                   @"includeGeneratedSponsors": @(includeGeneratedSponsors),
                               }];
        return;
    }

    NSMutableArray *markers = [NSMutableArray array];
    NSInteger chapterCount = self.chapters.count;
    NSInteger i = 0;

    while (i < chapterCount) {
        ICMetadataChapter *chapter = self.chapters[i];
        NSString *skipName = [self _skipNameForChapter:chapter withNames:skipNames includeGeneratedSponsors:includeGeneratedSponsors];

        if (!skipName) {
            // Check if next chapter is a skip chapter with negative startOffset → early skip from this chapter
            if (i + 1 < chapterCount) {
                ICMetadataChapter *nextChapter = self.chapters[i + 1];
                NSString *nextSkipName = [self _skipNameForChapter:nextChapter withNames:skipNames includeGeneratedSponsors:includeGeneratedSponsors];
                if (nextSkipName && ![nextSkipName isEqualToString:ICGeneratedSponsorSkipName]) {
                    NSString *startKey = [NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", episode.feed.uid, nextSkipName];
                    double startOffset = [episode.feed doubleForKey:startKey];
                    if (startOffset < 0) {
                        // Negative startOffset: skip starts before the skip chapter boundary
                        // Don't advance i here — the next iteration will handle the skip chapter group
                        // Just note: the group starting at i+1 will use this negative offset
                    }
                }
            }
            i++;
            continue;
        }

        // Found a skip chapter — start of a skip group
        NSString *firstSkipName = skipName;
        NSInteger groupStart = i;
        NSString *lastSkipName = skipName;
        NSInteger groupEnd = i; // inclusive

        // Find consecutive skip chapters
        NSInteger j = i + 1;
        while (j < chapterCount) {
            ICMetadataChapter *nextChap = self.chapters[j];
            NSString *nextName = [self _skipNameForChapter:nextChap withNames:skipNames includeGeneratedSponsors:includeGeneratedSponsors];
            if (!nextName) break;
            lastSkipName = nextName;
            groupEnd = j;
            j++;
        }

        // Calculate skipStart: first skip chapter start + startOffset
        ICMetadataChapter *firstSkipChapter = self.chapters[groupStart];
        NSTimeInterval firstSkipChapterStart = CMTimeGetSeconds(firstSkipChapter.start);

        double startOffset = 0;
        if (![firstSkipName isEqualToString:ICGeneratedSponsorSkipName]) {
            NSString *startKey = [NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", episode.feed.uid, firstSkipName];
            startOffset = [episode.feed doubleForKey:startKey];
        }

        NSTimeInterval skipStart;
        if (startOffset < 0) {
            // Negative: skip starts before the skip chapter (in the previous chapter)
            skipStart = firstSkipChapterStart + startOffset;
        } else {
            // Positive or zero: skip starts within/at the skip chapter
            skipStart = firstSkipChapterStart + startOffset;
        }
        skipStart = MAX(0, skipStart);

        // Calculate resumeTime
        NSTimeInterval resumeTime;
        if (j >= chapterCount) {
            // All remaining chapters are skip → finish episode
            resumeTime = -1;
        } else {
            // Resume at end of last skip chapter (= start of next non-skip chapter)
            ICMetadataChapter *lastSkipChapter = self.chapters[groupEnd];
            NSTimeInterval lastSkipChapterEnd = CMTimeGetSeconds(lastSkipChapter.end);

            double endOffset = 0;
            if (![lastSkipName isEqualToString:ICGeneratedSponsorSkipName]) {
                NSString *endKey = [NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", episode.feed.uid, lastSkipName];
                endOffset = [episode.feed doubleForKey:endKey];
            }

            resumeTime = lastSkipChapterEnd + endOffset;

            // Clamp: resume must not go before start of last skip chapter
            NSTimeInterval lastSkipChapterStart = CMTimeGetSeconds(lastSkipChapter.start);
            resumeTime = MAX(resumeTime, lastSkipChapterStart);

            // Clamp: resume must be after skipStart
            resumeTime = MAX(resumeTime, skipStart + 1.0);
        }

        [markers addObject:@{@"start": @(skipStart), @"resume": @(resumeTime)}];

        // Advance past the skip group
        i = j;
    }

    self.autoSkipMarkers = (markers.count > 0) ? [markers copy] : nil;
    self.suppressedSkipMarker = -1;
    [self _logPlaybackAutoSkipEvent:@"Auto-Skip-Marker berechnet"
                            episode:episode
                        currentTime:[self time]
                           duration:self.duration
                           metadata:@{
                               @"chapterCount": @(chapterCount),
                               @"markerCount": @(markers.count),
                               @"skipNameCount": @(skipNames.count),
                               @"includeGeneratedSponsors": @(includeGeneratedSponsors),
                           }];
}


#pragma mark - Audio Output


#if !TARGET_OS_IPHONE

- (void) setAudioEndpoint:(ICAudioEndpoint *)audioEndpoint
{
    if (_audioEndpoint != audioEndpoint) {
        _audioEndpoint = audioEndpoint;

#if ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR == 1
        if ([NSBundle systemVersion] >= VM_SYSTEM_VERSION_OS_X_10_9 && [AVPlayer implementsSelector:@selector(audioOutputDeviceUniqueID)]) {
            [PlaybackManager setDataSourceOfAudioDeviceForEndpoint:audioEndpoint];
            self.player.audioOutputDeviceUniqueID = audioEndpoint.UID;
            return;
        }
#endif

        [PlaybackManager setAudioEndpointToCurrentSystemOutput:audioEndpoint];
    }
}

- (void) _handleChangeOfCurrentSystemAudioOutputDevice
{
#if ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR == 1
    if ([NSBundle systemVersion] >= VM_SYSTEM_VERSION_OS_X_10_9 && [AVPlayer implementsSelector:@selector(audioOutputDeviceUniqueID)]) {
        return;
    }
#endif
    [self _setAudioEndpointToCurrentSystemAudioDevice];
}

- (void) _setAudioEndpointToCurrentSystemAudioDevice
{
    for (ICAudioEndpoint* endpoint in [PlaybackManager audioOutputEndpoints]) {
        if ([PlaybackManager audioEndpointIsCurrentSystemOutput:endpoint]) {
            [self willChangeValueForKey:@"audioEndpoint"];
            _audioEndpoint = endpoint;
            [self didChangeValueForKey:@"audioEndpoint"];
        }
    }
}

#endif
@end
