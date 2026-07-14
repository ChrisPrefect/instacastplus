//
//  CacheOperation_iOS7.m
//  Instacast
//
//  Created by Martin Hering on 22/07/13.
//
//

#import "CacheOperation_iOS7.h"
#import "HTTPAuthentication.h"
#import "UtilityFunctions.h"
#import <AVFoundation/AVFoundation.h>

NSString* kUserDefaultsResumeInfoKey = @"DownloadResumeInfos_NSURLSession";
static NSString* const ICCacheOperationErrorDomain = @"ICCacheOperationErrorDomain";
static NSString* const ICResumeDataDirectoryName = @"DownloadResumeData";
static NSString* const ICResumeEnvelopeVersionKey = @"version";
static NSString* const ICResumeEnvelopeIdentifierKey = @"identifier";
static NSString* const ICResumeEnvelopeRemoteURLKey = @"remoteURL";
static NSString* const ICResumeEnvelopeDataKey = @"resumeData";
static const NSInteger ICResumeEnvelopeVersion = 1;
static char ICDownloadResumeStoreQueueKey;
static BOOL ICResumeStoreMigrationCompleted = NO;

static dispatch_queue_t ICDownloadResumeStoreQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.vemedio.instacast.downloadResumeStore", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_queue_set_specific(queue, &ICDownloadResumeStoreQueueKey, &ICDownloadResumeStoreQueueKey, NULL);
    });
    return queue;
}

static void ICDownloadResumeStoreSync(dispatch_block_t block)
{
    if (dispatch_get_specific(&ICDownloadResumeStoreQueueKey)) {
        block();
    } else {
        dispatch_sync(ICDownloadResumeStoreQueue(), block);
    }
}

static void ICDownloadResumeStoreAsync(dispatch_block_t block)
{
    dispatch_async(ICDownloadResumeStoreQueue(), block);
}

static NSString* ICResumeDataDirectoryPath(void)
{
    NSURL* applicationSupportURL = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                          inDomains:NSUserDomainMask].firstObject;
    return [[applicationSupportURL URLByAppendingPathComponent:ICResumeDataDirectoryName isDirectory:YES] path];
}

static BOOL ICEnsureResumeDataDirectory(void)
{
    NSString* directoryPath = ICResumeDataDirectoryPath();
    if (directoryPath.length == 0) {
        return NO;
    }
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSError* error = nil;
    if (![fileManager createDirectoryAtPath:directoryPath
                withIntermediateDirectories:YES
                                 attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                      error:&error]) {
        ErrLog(@"could not create download resume-data directory: %@", error);
        return NO;
    }
    AddSkipBackupAttributeToFile(directoryPath);
    return YES;
}

static NSString* ICResumeDataPathForIdentifier(NSString* identifier)
{
    NSString* filenameHash = identifier.length > 0 ? [identifier MD5Hash] : nil;
    NSString* directoryPath = ICResumeDataDirectoryPath();
    if (filenameHash.length == 0 || directoryPath.length == 0) {
        return nil;
    }
    return [directoryPath stringByAppendingPathComponent:[filenameHash stringByAppendingPathExtension:@"resume"]];
}

static void ICMigrateLegacyResumeDataIfNeeded(void)
{
    if (ICResumeStoreMigrationCompleted) {
        return;
    }

    id legacyResumeData = [USER_DEFAULTS objectForKey:kUserDefaultsResumeInfoKey];
    if (legacyResumeData) {
        // Legacy entries contain only Apple's opaque token. They cannot be proven to
        // belong to the episode's current enclosure URL, so importing them would be
        // able to resume an obsolete media URL. Retire the unsafe format once.
        [USER_DEFAULTS removeObjectForKey:kUserDefaultsResumeInfoKey];
    }
    ICResumeStoreMigrationCompleted = YES;
}

static BOOL ICWriteResumeData(NSString* identifier, NSURL* remoteURL, NSData* resumeData)
{
    ICMigrateLegacyResumeDataIfNeeded();
    if (identifier.length == 0 || remoteURL.absoluteString.length == 0 || resumeData.length == 0 || !ICEnsureResumeDataDirectory()) {
        return NO;
    }

    NSDictionary* envelope = @{
        ICResumeEnvelopeVersionKey: @(ICResumeEnvelopeVersion),
        ICResumeEnvelopeIdentifierKey: identifier,
        ICResumeEnvelopeRemoteURLKey: remoteURL.absoluteString,
        ICResumeEnvelopeDataKey: resumeData,
    };
    NSError* serializationError = nil;
    NSData* serializedEnvelope = [NSPropertyListSerialization dataWithPropertyList:envelope
                                                                            format:NSPropertyListBinaryFormat_v1_0
                                                                           options:0
                                                                             error:&serializationError];
    NSString* path = ICResumeDataPathForIdentifier(identifier);
    NSError* writeError = nil;
    BOOL wrote = serializedEnvelope && path.length > 0 && [serializedEnvelope writeToFile:path
                                                                                  options:NSDataWritingAtomic
                                                                                    error:&writeError];
    if (!wrote) {
        ErrLog(@"could not persist resume data for %@: %@", identifier, serializationError ?: writeError);
        return NO;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}
                                     ofItemAtPath:path
                                            error:nil];
    AddSkipBackupAttributeToFile(path);
    return YES;
}

static NSData* ICReadAndDeleteResumeData(NSString* identifier, NSURL* remoteURL)
{
    ICMigrateLegacyResumeDataIfNeeded();
    NSString* path = ICResumeDataPathForIdentifier(identifier);
    if (path.length == 0) {
        return nil;
    }

    NSError* readError = nil;
    NSData* serializedEnvelope = [NSData dataWithContentsOfFile:path options:0 error:&readError];
    if (!serializedEnvelope) {
        return nil;
    }
    NSError* deleteError = nil;
    if (![[NSFileManager defaultManager] removeItemAtPath:path error:&deleteError]) {
        ErrLog(@"could not consume resume data for %@: %@", identifier, deleteError);
        return nil;
    }

    NSError* parseError = nil;
    NSDictionary* envelope = [NSPropertyListSerialization propertyListWithData:serializedEnvelope
                                                                        options:NSPropertyListImmutable
                                                                         format:NULL
                                                                          error:&parseError];
    NSData* resumeData = [envelope isKindOfClass:[NSDictionary class]] ? envelope[ICResumeEnvelopeDataKey] : nil;
    BOOL valid = [envelope[ICResumeEnvelopeVersionKey] integerValue] == ICResumeEnvelopeVersion &&
                 [envelope[ICResumeEnvelopeIdentifierKey] isEqualToString:identifier] &&
                 [envelope[ICResumeEnvelopeRemoteURLKey] isEqualToString:remoteURL.absoluteString] &&
                 [resumeData isKindOfClass:[NSData class]] && resumeData.length > 0;
    if (!valid && parseError) {
        ErrLog(@"could not parse resume data for %@: %@", identifier, parseError);
    }
    return valid ? resumeData : nil;
}

static void ICDeleteResumeData(NSString* identifier)
{
    ICMigrateLegacyResumeDataIfNeeded();
    NSString* path = ICResumeDataPathForIdentifier(identifier);
    if (path.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
}

static void ICDeleteAllResumeData(void)
{
    ICMigrateLegacyResumeDataIfNeeded();
    NSString* directoryPath = ICResumeDataDirectoryPath();
    if (directoryPath.length > 0) {
        [[NSFileManager defaultManager] removeItemAtPath:directoryPath error:nil];
    }
    [USER_DEFAULTS removeObjectForKey:kUserDefaultsResumeInfoKey];
}


@interface CacheOperation_iOS7 () <NSURLSessionDelegate, NSURLSessionDownloadDelegate>
@property (readwrite, copy) NSURL* localURL;
@property (strong) NSURLSession* session;
@property (strong) NSURLSessionDownloadTask* downloadTask;
@property (strong) NSOperationQueue* delegateQueue;

@property (readwrite, strong) NSString* identifier;
@property (readwrite) long long expectedContentLength;
@property (readwrite) long long loadedContentLength;
@property (readwrite) long long restartedAtContentLength;
@property (readwrite, strong) NSDate* startDate;
@property (readwrite, strong) NSError* terminalError;
@property (readwrite) long long feedExpectedContentLength;
@property (readwrite) long long transportExpectedContentLength;
@property (readwrite) unsigned long long finalFileSize;
@property (readwrite, strong) NSURL* stagedDownloadURL;
@property (strong) AVURLAsset* validationAsset;
@property (strong) dispatch_semaphore_t mediaValidationSemaphore;
@property (strong) NSLock* finalizationLock;
@property (strong) NSLock* progressLock;
@property int64_t unreportedLoadedBytes;
@property BOOL finalizedDownload;
@property BOOL taskInventoryResolved;
@property BOOL receivedFinishedDownload;
@property (strong) NSURLSessionDownloadTask* pendingCompletedTask;
@property (strong) NSError* pendingCompletionError;
@property (strong) HTTPAuthentication* authentication;
@property (readwrite, strong) GTMLogger* logger;
@end


@implementation CacheOperation_iOS7 {
    BOOL _shouldBeSuspended;
    dispatch_semaphore_t _stateChangeSemaphore;
}

- (id) initWithURL:(NSURL*)aRemoteURL localURL:(NSURL*)aLocalURL identifier:(NSString*)identifier expectedContentLength:(long long)expectedContentLength
{
	if ((self = [self init]))
	{
        if (!aRemoteURL || !aLocalURL || !identifier) {
            return nil;
        }
        
        // workaround for a bug in the feed parser up to version 3.0.2
        NSString* remoteURLString = [aRemoteURL absoluteString];
        if ([remoteURLString rangeOfString:@"%25"].location != NSNotFound) {
            remoteURLString = [remoteURLString stringByRemovingPercentEncoding];
            aRemoteURL = [NSURL URLWithString:remoteURLString];
        }
        
        // workaround for urls with whitespace
        // has been fixed in the feed parser
        if ([remoteURLString rangeOfString:@"%20"].location == 0) {
            remoteURLString = [[remoteURLString stringByRemovingPercentEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            aRemoteURL = [NSURL URLWithString:remoteURLString];
        }


        // make sure we have http urls
        if (![[aRemoteURL scheme] caseInsensitiveEquals:@"http"] && ![[aRemoteURL scheme] caseInsensitiveEquals:@"https"]) {
            NSString* scheme = [aRemoteURL scheme];
            NSString* urlString = [aRemoteURL absoluteString];
            urlString = [urlString stringByReplacingCharactersInRange:NSMakeRange(0, [scheme length]) withString:@"http"];
            if (urlString) {
                aRemoteURL = [NSURL URLWithString:urlString];
            }
        }

		_remoteURL = [aRemoteURL copy];
		_localURL = [aLocalURL copy];
        _identifier = [identifier copy];
        _feedExpectedContentLength = MAX(0LL, expectedContentLength);
        _expectedContentLength = _feedExpectedContentLength;
        
        NSString* logsPath = [[NSBundle pathToLogsDirectory] stringByAppendingPathComponent:@"MediaFileImporter.log"];
        
        _logger = [GTMLogger standardLoggerWithPath:logsPath];
        [_logger setFilter:[[GTMLogLevelFilter alloc] init]];
        _stateChangeSemaphore = dispatch_semaphore_create(0);
        _finalizationLock = [[NSLock alloc] init];
        _progressLock = [[NSLock alloc] init];
        
        VMLoggerInfo(@"remote url: %@, local url: %@, identifier: %@", aRemoteURL, aLocalURL, identifier);
	}
	
	return self;
}

+ (void) removeCacheForRemoteURL:(NSURL*)remoteURL atLocalURL:(NSURL*)url
{
	NSFileManager* fman = [NSFileManager defaultManager];
	
	NSString* path = [url path];
	[fman removeItemAtPath:path error:nil];
}

#pragma mark -

- (double) progress
{
    long long expectedContentLength = self.expectedContentLength;
    long long loadedContentLength = self.loadedContentLength;
    
	if (expectedContentLength == 0 || expectedContentLength < loadedContentLength) {
		return 0.0;
	}
	return (double)loadedContentLength / (double)expectedContentLength;
}

- (NSTimeInterval) estimatedTimeLeft
{
    long long expectedContentLength = self.expectedContentLength;
    long long loadedContentLength = self.loadedContentLength;
    long long restartedAtContentLength = self.restartedAtContentLength;
    
    if (expectedContentLength - restartedAtContentLength <= 0) {
        return 0;
    }
    
    double progress = (double)(loadedContentLength - restartedAtContentLength) / (double)(expectedContentLength - restartedAtContentLength);
    if (progress == 0) {
        return 0;
    }
    
    NSTimeInterval timeLoaded = [[NSDate date] timeIntervalSinceDate:self.startDate];
    if (timeLoaded > 3) {
        NSTimeInterval estimated = (timeLoaded / progress)-timeLoaded;
        return estimated;
    }
    
    return 0;
}


#pragma mark -


- (void) cancel
{
    [super cancel];
    [self.validationAsset cancelLoading];
    dispatch_semaphore_t mediaValidationSemaphore = self.mediaValidationSemaphore;
    if (mediaValidationSemaphore) {
        dispatch_semaphore_signal(mediaValidationSemaphore);
    }
    [self.finalizationLock lock];
    if (self.finalizedDownload) {
        [[NSFileManager defaultManager] removeItemAtURL:self.localURL error:nil];
        self.finalizedDownload = NO;
    }
    [self.finalizationLock unlock];
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)claimFinalizedDownload
{
    [self.finalizationLock lock];
    self.finalizedDownload = NO;
    [self.finalizationLock unlock];
}

- (BOOL) suspended {
    NSURLSessionDownloadTask* downloadTask = self.downloadTask;
    return downloadTask ? (downloadTask.state == NSURLSessionTaskStateSuspended) : _shouldBeSuspended;
}

- (void) setSuspended:(BOOL)suspended
{
    _shouldBeSuspended = suspended;
    NSURLSessionDownloadTask* downloadTask = self.downloadTask;
    if (!downloadTask || suspended == (downloadTask.state == NSURLSessionTaskStateSuspended)) {
        dispatch_semaphore_signal(_stateChangeSemaphore);
        return;
    }

    if (suspended) {
        [downloadTask suspend];
    } else {
        [downloadTask resume];
        self.restartedAtContentLength = self.loadedContentLength;
        self.startDate = [NSDate date];
    }
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)_notifyDidEndOnMainThread
{
    id<CacheOperationDelegate> delegate = self.delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(cacheOperationDidEnd:)]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        id<CacheOperationDelegate> strongDelegate = self.delegate;
        if (strongDelegate && [strongDelegate respondsToSelector:@selector(cacheOperationDidEnd:)]) {
            [strongDelegate cacheOperationDidEnd:self];
        }
    });
}

- (BOOL)_taskBelongsToOperation:(NSURLSessionTask*)task session:(NSURLSession*)session
{
    if (!task || session != self.session) {
        return NO;
    }
    NSURL* taskURL = task.originalRequest.URL ?: task.currentRequest.URL;
    return taskURL && [taskURL isEqual:self.remoteURL];
}

- (void)_applyCompletionError:(NSError*)error forTask:(NSURLSessionTask*)task
{
    if (!error || self.suspended || [self isCancelled]) {
        return;
    }
    [self _failWithError:error];
    NSData* resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (resumeData) {
        [self _saveResumeData:resumeData];
    }
}

- (NSError*)_downloadErrorWithCode:(NSInteger)code description:(NSString*)description underlyingError:(NSError*)underlyingError
{
    NSMutableDictionary* userInfo = [@{NSLocalizedDescriptionKey: description ?: @"Download Failed".ls} mutableCopy];
    if (underlyingError) {
        userInfo[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:ICCacheOperationErrorDomain code:code userInfo:userInfo];
}

- (void)_failWithError:(NSError*)error
{
    if (!self.terminalError) {
        self.terminalError = error ?: [self _downloadErrorWithCode:1
                                                       description:@"The episode download could not be completed.".ls
                                                   underlyingError:nil];
    }
    self.failed = YES;
}

- (void)_removeStagedDownload
{
    NSURL* stagedDownloadURL = self.stagedDownloadURL;
    self.stagedDownloadURL = nil;
    if (stagedDownloadURL) {
        [[NSFileManager defaultManager] removeItemAtURL:stagedDownloadURL error:nil];
    }
}

- (BOOL)_responseHasNonMediaMIMEType:(NSURLResponse*)response
{
    NSString* mimeType = response.MIMEType.lowercaseString;
    if (mimeType.length == 0) {
        return NO;
    }
    return [mimeType containsString:@"text/html"] ||
           [mimeType containsString:@"application/json"] ||
           [mimeType containsString:@"application/xml"] ||
           [mimeType containsString:@"application/xhtml"];
}

- (NSString*)fileExtensionForMIMEType:(NSString*)mimeType
{
    NSString* normalized = [mimeType.lowercaseString componentsSeparatedByString:@";"].firstObject;
    NSDictionary<NSString*, NSString*>* extensions = @{
        @"audio/mpeg": @"mp3",
        @"audio/mp3": @"mp3",
        @"audio/mpeg3": @"mp3",
        @"audio/mp4": @"m4a",
        @"audio/x-m4a": @"m4a",
        @"audio/m4a": @"m4a",
        @"audio/mp4a-latm": @"m4a",
        @"audio/aac": @"aac",
        @"audio/x-aac": @"aac",
        @"audio/ogg": @"ogg",
        @"application/ogg": @"ogg",
        @"audio/wav": @"wav",
        @"audio/x-wav": @"wav",
        @"audio/flac": @"flac",
        @"video/mp4": @"mp4",
        @"video/x-m4v": @"m4v",
        @"video/quicktime": @"mov",
    };
    return extensions[[normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
}

- (BOOL)isCompletePartialContentResponse:(NSHTTPURLResponse*)response actualSize:(long long)actualSize
{
    NSString* contentRange = [[response valueForHTTPHeaderField:@"Content-Range"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (actualSize <= 0 || contentRange.length == 0) {
        return NO;
    }
    NSArray<NSString*>* components = [contentRange componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<NSString*>* nonEmptyComponents = [NSMutableArray array];
    for (NSString* component in components) {
        if (component.length > 0) {
            [nonEmptyComponents addObject:component];
        }
    }
    if (nonEmptyComponents.count != 2 || ![nonEmptyComponents[0] caseInsensitiveEquals:@"bytes"]) {
        return NO;
    }
    NSArray<NSString*>* rangeAndTotal = [nonEmptyComponents[1] componentsSeparatedByString:@"/"];
    if (rangeAndTotal.count != 2) {
        return NO;
    }
    long long totalSize = [rangeAndTotal[1] longLongValue];
    // A resumed response describes only its final network segment. URLSession's
    // staging file is already reassembled, so equality with the resource total is
    // the proof of completeness; requiring a zero range start rejects valid resumes.
    return totalSize > 0 && totalSize == actualSize;
}

- (NSError*)_transportValidationErrorForTask:(NSURLSessionDownloadTask*)downloadTask fileSize:(long long)fileSize
{
    NSHTTPURLResponse* response = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)downloadTask.response : nil;
    if (!response) {
        return [self _downloadErrorWithCode:2
                                description:@"The podcast server did not return a valid HTTP response.".ls
                            underlyingError:nil];
    }

    NSInteger statusCode = response.statusCode;
    if (statusCode < 200 || statusCode >= 300) {
        NSString* description = [NSString stringWithFormat:@"The podcast server returned HTTP %ld. The episode file is not available at the address published by the podcast.".ls,
                                 (long)statusCode];
        return [self _downloadErrorWithCode:statusCode description:description underlyingError:nil];
    }
    if ([self _responseHasNonMediaMIMEType:response]) {
        return [self _downloadErrorWithCode:3
                                description:@"The podcast server returned a web page instead of a playable episode file.".ls
                            underlyingError:nil];
    }
    if (fileSize <= 0) {
        return [self _downloadErrorWithCode:4
                                description:@"The downloaded episode file is empty.".ls
                            underlyingError:nil];
    }
    if (statusCode == 206 && ![self isCompletePartialContentResponse:response actualSize:fileSize]) {
        return [self _downloadErrorWithCode:5
                                description:@"The podcast server ended the transfer before the complete episode file was received.".ls
                            underlyingError:nil];
    }

    long long taskExpectedContentLength = downloadTask.countOfBytesExpectedToReceive;
    if (self.transportExpectedContentLength <= 0 && taskExpectedContentLength > 0) {
        self.transportExpectedContentLength = taskExpectedContentLength;
        self.expectedContentLength = taskExpectedContentLength;
    }
    if (self.transportExpectedContentLength > 0 && fileSize < self.transportExpectedContentLength) {
        return [self _downloadErrorWithCode:5
                                description:@"The podcast server ended the transfer before the complete episode file was received.".ls
                            underlyingError:nil];
    }
    if (self.transportExpectedContentLength <= 0 &&
        self.feedExpectedContentLength > 0 &&
        fileSize < self.feedExpectedContentLength / 2) {
        return [self _downloadErrorWithCode:5
                                description:@"The podcast server ended the transfer before the complete episode file was received.".ls
                            underlyingError:nil];
    }
    return nil;
}

- (NSURL*)_newStagedDownloadURLWithError:(NSError**)outError
{
    NSString* stagingPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"InstacastEpisodeDownloads"];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (![fileManager createDirectoryAtPath:stagingPath withIntermediateDirectories:YES attributes:nil error:outError]) {
        return nil;
    }
    NSString* extension = self.localURL.pathExtension;
    NSString* filename = NSUUID.UUID.UUIDString;
    if (extension.length > 0) {
        filename = [filename stringByAppendingPathExtension:extension];
    }
    return [NSURL fileURLWithPath:[stagingPath stringByAppendingPathComponent:filename]];
}

- (NSError*)_mediaValidationErrorForStagedDownload
{
    NSURL* stagedDownloadURL = self.stagedDownloadURL;
    if (!stagedDownloadURL) {
        return [self _downloadErrorWithCode:6
                                description:@"The downloaded episode file is not playable.".ls
                            underlyingError:nil];
    }

    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:stagedDownloadURL options:nil];
    dispatch_semaphore_t validationSemaphore = dispatch_semaphore_create(0);
    self.validationAsset = asset;
    self.mediaValidationSemaphore = validationSemaphore;
    __block BOOL playable = NO;
    __block NSTimeInterval measuredDuration = 0;
    __block NSError* loadError = nil;
    [asset loadValuesAsynchronouslyForKeys:@[@"playable", @"duration"] completionHandler:^{
        NSError* playableError = nil;
        NSError* durationError = nil;
        AVKeyValueStatus playableStatus = [asset statusOfValueForKey:@"playable" error:&playableError];
        AVKeyValueStatus durationStatus = [asset statusOfValueForKey:@"duration" error:&durationError];
        if (playableStatus == AVKeyValueStatusLoaded && durationStatus == AVKeyValueStatusLoaded) {
            playable = asset.playable;
            double seconds = CMTimeGetSeconds(asset.duration);
            if (isfinite(seconds)) {
                measuredDuration = MAX(0, seconds);
            }
        } else {
            loadError = playableError ?: durationError;
        }
        dispatch_semaphore_signal(validationSemaphore);
    }];
    if ([self isCancelled]) {
        [asset cancelLoading];
        dispatch_semaphore_signal(validationSemaphore);
    }
    dispatch_semaphore_wait(validationSemaphore, DISPATCH_TIME_FOREVER);
    if (self.validationAsset == asset) {
        self.validationAsset = nil;
        self.mediaValidationSemaphore = nil;
    }

    if (!playable || measuredDuration <= 0) {
        return [self _downloadErrorWithCode:6
                                description:@"The downloaded episode file is not playable.".ls
                            underlyingError:loadError];
    }
    if (self.expectedDuration >= 600 && measuredDuration < self.expectedDuration / 2) {
        return [self _downloadErrorWithCode:5
                                description:@"The podcast server ended the transfer before the complete episode file was received.".ls
                            underlyingError:nil];
    }
    return nil;
}

- (NSError*)_moveValidatedStagedDownloadToFinalURL
{
    if (!self.stagedDownloadURL || !self.localURL) {
        return [self _downloadErrorWithCode:7
                                description:@"The downloaded episode file could not be saved on this device.".ls
                            underlyingError:nil];
    }

    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSError* moveError = nil;
    if ([fileManager fileExistsAtPath:self.localURL.path]) {
        BOOL replaced = [fileManager replaceItemAtURL:self.localURL
                                       withItemAtURL:self.stagedDownloadURL
                                      backupItemName:nil
                                             options:0
                                    resultingItemURL:nil
                                               error:&moveError];
        if (!replaced) {
            return [self _downloadErrorWithCode:7
                                    description:@"The downloaded episode file could not be saved on this device.".ls
                                underlyingError:moveError];
        }
    } else if (![fileManager moveItemAtURL:self.stagedDownloadURL toURL:self.localURL error:&moveError]) {
        return [self _downloadErrorWithCode:7
                                description:@"The downloaded episode file could not be saved on this device.".ls
                            underlyingError:moveError];
    }
    self.stagedDownloadURL = nil;
    return nil;
}

- (void) main
{
	@autoreleasepool
    {
        NSURL* remoteURL = self.remoteURL;

        BOOL enabled3G = (self.overwriteCellularLock || [USER_DEFAULTS boolForKey:EnableCachingOver3G]);
        NSURLSessionConfiguration* config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:self.identifier];
        config.discretionary = NO;
        config.allowsCellularAccess = enabled3G;

        if (!self.delegateQueue) {
            NSOperationQueue* delegateQueue = [[NSOperationQueue alloc] init];
            delegateQueue.maxConcurrentOperationCount = 1;
            delegateQueue.qualityOfService = self.automatic ? NSQualityOfServiceUtility : NSQualityOfServiceUserInitiated;
            delegateQueue.name = [NSString stringWithFormat:@"com.vemedio.instacast.cache.%@", self.identifier ?: @"download"];
            self.delegateQueue = delegateQueue;
        }

        __block BOOL setupFinished = NO;
        __block NSURLSession* activeSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:self.delegateQueue];
        self.session = activeSession;

        [activeSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
            [self.delegateQueue addOperationWithBlock:^{
            self.taskInventoryResolved = YES;
            if ([self isCancelled]) {
                setupFinished = YES;
                dispatch_semaphore_signal(self->_stateChangeSemaphore);
                return;
            }

            if (self.receivedFinishedDownload) {
                for (NSURLSessionDownloadTask* candidate in downloadTasks) {
                    if (candidate != self.downloadTask) {
                        [candidate cancel];
                    }
                }
                self.pendingCompletedTask = nil;
                self.pendingCompletionError = nil;
                setupFinished = YES;
                dispatch_semaphore_signal(self->_stateChangeSemaphore);
                return;
            }

            NSURLSessionDownloadTask* matchingTask = nil;
            for (NSURLSessionDownloadTask* candidate in downloadTasks) {
                BOOL active = candidate.state != NSURLSessionTaskStateCompleted;
                BOOL matchesRemoteURL = [self _taskBelongsToOperation:candidate session:activeSession];
                if (active && matchesRemoteURL && (!matchingTask || candidate.taskIdentifier > matchingTask.taskIdentifier)) {
                    [matchingTask cancel];
                    matchingTask = candidate;
                } else {
                    [candidate cancel];
                }
            }
            if (matchingTask) {
                self.downloadTask = matchingTask;
                self.pendingCompletedTask = nil;
                self.pendingCompletionError = nil;
                if (self->_shouldBeSuspended) {
                    [self.downloadTask suspend];
                } else if (self.downloadTask.state == NSURLSessionTaskStateSuspended) {
                    [self.downloadTask resume];
                }
                self.startDate = [NSDate date];
                setupFinished = YES;
                dispatch_semaphore_signal(self->_stateChangeSemaphore);
                return;
            }

            if (self.pendingCompletedTask) {
                self.downloadTask = self.pendingCompletedTask;
                NSError* pendingError = self.pendingCompletionError;
                self.pendingCompletedTask = nil;
                self.pendingCompletionError = nil;
                if (pendingError) {
                    [self _applyCompletionError:pendingError forTask:self.downloadTask];
                } else {
                    [self _failWithError:[self _downloadErrorWithCode:9
                                                               description:@"The episode download finished without providing a file.".ls
                                                           underlyingError:nil]];
                }
                setupFinished = YES;
                dispatch_semaphore_signal(self->_stateChangeSemaphore);
                return;
            }

            NSData* resumeData = [self _resumeData];
            if (resumeData)
            {
                // In case the resume data is invalid, creating the task can throw.
                @try {
                    self.downloadTask = [activeSession downloadTaskWithResumeData:resumeData];
                }
                @catch (NSException *exception) {
                    ErrLog(@"downloadTaskWithResumeData exception: %@", [exception description]);
                    self.downloadTask = nil;
                }
            }

            if (!self.downloadTask)
            {
                @try {
                    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:remoteURL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.f];
                    self.downloadTask = [activeSession downloadTaskWithRequest:request];
                }
                @catch (NSException *exception) {
                    ErrLog(@"downloadTaskWithRequest exception: %@", [exception description]);
                    self.downloadTask = nil;
                    NSError* requestError = [NSError errorWithDomain:ICCacheOperationErrorDomain
                                                                 code:8
                                                             userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"The episode download could not be started.".ls}];
                    [self _failWithError:requestError];
                }
            }

            if (self.downloadTask && !self->_shouldBeSuspended) {
                [self.downloadTask resume];
            }
            self.startDate = [NSDate date];
            setupFinished = YES;
            dispatch_semaphore_signal(self->_stateChangeSemaphore);
            }];
        }];

        while (!setupFinished && ![self isCancelled]) {
            dispatch_semaphore_wait(_stateChangeSemaphore, DISPATCH_TIME_FOREVER);
        }

        while ((!self.downloadTask || self.downloadTask.state != NSURLSessionTaskStateCompleted) &&
               ![self isCancelled] && !self.failed) {
            dispatch_semaphore_wait(_stateChangeSemaphore, DISPATCH_TIME_FOREVER);
        }

        if ([self isCancelled])
        {
            NSURLSessionDownloadTask* downloadTask = self.downloadTask;
            if (downloadTask && downloadTask.state != NSURLSessionTaskStateCompleted) {
                dispatch_semaphore_t cancellationSemaphore = dispatch_semaphore_create(0);
                [downloadTask cancelByProducingResumeData:^(NSData *resumeData) {
                    if (resumeData) {
                        [self _saveResumeData:resumeData];
                    }
                    dispatch_semaphore_signal(cancellationSemaphore);
                }];
                dispatch_semaphore_wait(cancellationSemaphore, DISPATCH_TIME_FOREVER);
            }

            [self.session invalidateAndCancel];
        }
        else if (self.session)
        {
            [self.session finishTasksAndInvalidate];
        }

        while (self.session) {
            dispatch_semaphore_wait(_stateChangeSemaphore, DISPATCH_TIME_FOREVER);
        }

        if (![self isCancelled] && !self.failed) {
            NSError* validationError = [self _mediaValidationErrorForStagedDownload];
            [self.finalizationLock lock];
            if (!validationError && ![self isCancelled]) {
                validationError = [self _moveValidatedStagedDownloadToFinalURL];
                self.finalizedDownload = (validationError == nil);
            }
            [self.finalizationLock unlock];
            if (validationError && ![self isCancelled]) {
                [self _failWithError:validationError];
            }
        }
        if ([self isCancelled] || self.failed) {
            [self _removeStagedDownload];
        }

        [self _notifyDidEndOnMainThread];
    }
}

#pragma mark - NSURLSession Delegate

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
    if (self.session == session) {
        if (error && ![self isCancelled]) {
            [self _failWithError:error];
        }
        self.session = nil;
    }
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
}



#pragma mark NSURLSessionDownloadDelegate Delegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLProtectionSpace* space = [challenge protectionSpace];
    
    // in case there is
    if ([space authenticationMethod] == NSURLAuthenticationMethodServerTrust || [space authenticationMethod] == NSURLAuthenticationMethodClientCertificate) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    
    // in case we can use the username and password stored in the feed
	if (self.username && self.password && [challenge previousFailureCount] == 0)
	{
		NSURLCredential* credentials = [NSURLCredential credentialWithUser:self.username password:self.password persistence:NSURLCredentialPersistenceNone];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credentials);
		return;
	}
    
    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    // Authentication challenges without stored feed credentials are intentionally cancelled.
//	if (self.authentication) {
//        [self.authentication dismissAnimated:NO];
//        self.authentication = nil;
//    }
//    
//#if TARGET_OS_IPHONE
//    if (App.applicationState == UIApplicationStateBackground) {
//        UILocalNotification* finishedNotification = [[UILocalNotification alloc] init];
//        finishedNotification.alertBody = @"Authentication required to download a file.".ls;
//        finishedNotification.soundName = UILocalNotificationDefaultSoundName;
//        [App presentLocalNotificationNow:finishedNotification];
//    }
//#endif
//    
//    self.authentication = [[HTTPAuthentication alloc] init];
//    self.authentication.url = self.remoteURL;
//    self.authentication.username = (self.username) ? self.username : [[challenge proposedCredential] user];
//    self.authentication.userInfo = challenge;
//    self.authentication.failedBefore = ([challenge previousFailureCount] > 0);
//    [self.authentication showAuthenticationDialogCompletion:^(BOOL success, NSString *username, NSString *password) {
//
//         if (success) {
//             self.username = username;
//             self.password = password;
//         }
//        
//        self.authentication = nil;
//         
//         if (!success) {
//             completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
//         } else {
//             NSURLCredential* credentials = [NSURLCredential credentialWithUser:self.username password:self.password persistence:NSURLCredentialPersistenceNone];
//             completionHandler(NSURLSessionAuthChallengeUseCredential, credentials);
//         }
//    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if ([self _taskBelongsToOperation:task session:session]) {
        if (task == self.downloadTask) {
            [self _applyCompletionError:error forTask:task];
        } else if (!self.taskInventoryResolved && [task isKindOfClass:[NSURLSessionDownloadTask class]]) {
            if (!self.pendingCompletedTask || task.taskIdentifier > self.pendingCompletedTask.taskIdentifier) {
                self.pendingCompletedTask = (NSURLSessionDownloadTask*)task;
                self.pendingCompletionError = error;
            }
        }
    }

    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
    if (![self _taskBelongsToOperation:downloadTask session:session]) {
        return;
    }
    if (self.receivedFinishedDownload) {
        return;
    }
    NSURLSessionDownloadTask* previousTask = self.downloadTask;
    if (previousTask && previousTask != downloadTask && previousTask.state != NSURLSessionTaskStateCompleted) {
        [previousTask cancel];
    }
    self.downloadTask = downloadTask;
    self.receivedFinishedDownload = YES;
    self.pendingCompletedTask = nil;
    self.pendingCompletionError = nil;
    NSFileManager* fileManager = [[NSFileManager alloc] init];
    NSError* error = nil;
    NSDictionary* info = [fileManager attributesOfItemAtPath:location.path error:&error];
    if (error) {
        ErrLog(@"could not get file attributes for downloaded file: %@", location);
        [self _failWithError:[self _downloadErrorWithCode:10
                                               description:@"The downloaded episode file could not be read on this device.".ls
                                           underlyingError:error]];
        dispatch_semaphore_signal(_stateChangeSemaphore);
        return;
    }

    long long fileSize = [info[NSFileSize] longLongValue];
    NSError* validationError = [self _transportValidationErrorForTask:downloadTask fileSize:fileSize];
    if (validationError) {
        [self _failWithError:validationError];
        dispatch_semaphore_signal(_stateChangeSemaphore);
        return;
    }
    self.finalFileSize = (unsigned long long)fileSize;

    NSString* transportExtension = [self fileExtensionForMIMEType:downloadTask.response.MIMEType];
    if (transportExtension.length > 0 && ![self.localURL.pathExtension caseInsensitiveEquals:transportExtension]) {
        self.localURL = [[self.localURL URLByDeletingPathExtension] URLByAppendingPathExtension:transportExtension];
    }

    NSURL* stagedDownloadURL = [self _newStagedDownloadURLWithError:&error];
    if (!stagedDownloadURL || ![fileManager moveItemAtURL:location toURL:stagedDownloadURL error:&error]) {
        [self _failWithError:[self _downloadErrorWithCode:11
                                               description:@"The downloaded episode file could not be staged for validation.".ls
                                           underlyingError:error]];
        dispatch_semaphore_signal(_stateChangeSemaphore);
        return;
    }
    self.stagedDownloadURL = stagedDownloadURL;

    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (downloadTask != self.downloadTask) {
        return;
    }
    self.loadedContentLength = totalBytesWritten;
    if (totalBytesExpectedToWrite > 0) {
        self.transportExpectedContentLength = totalBytesExpectedToWrite;
        self.expectedContentLength = totalBytesExpectedToWrite;
    }

    [self.progressLock lock];
    self.unreportedLoadedBytes += bytesWritten;
    [self.progressLock unlock];
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (int64_t)drainLoadedBytesSinceLastUpdate
{
    [self.progressLock lock];
    int64_t loadedBytes = self.unreportedLoadedBytes;
    self.unreportedLoadedBytes = 0;
    [self.progressLock unlock];
    return loadedBytes;
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    if (downloadTask != self.downloadTask) {
        return;
    }
    if (expectedTotalBytes > 0) {
        self.transportExpectedContentLength = expectedTotalBytes;
        self.expectedContentLength = expectedTotalBytes;
    }
    self.restartedAtContentLength = fileOffset;
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

#pragma mark - Handling Resume Information


- (void) _saveResumeData:(NSData*)resumeData
{
    NSString* identifier = [self.identifier copy];
    NSURL* remoteURL = [self.remoteURL copy];
    ICDownloadResumeStoreSync(^{
        ICWriteResumeData(identifier, remoteURL, resumeData);
    });
}

+ (void) prepareResumeInfoStore
{
    ICDownloadResumeStoreAsync(^{
        ICMigrateLegacyResumeDataIfNeeded();
    });
}

+ (void) deleteResumeInfoForIdentifier:(NSString*)identifier
{
    NSString* copiedIdentifier = [identifier copy];
    ICDownloadResumeStoreAsync(^{
        ICDeleteResumeData(copiedIdentifier);
    });
}

+ (void) deleteAllResumeInfo
{
    ICDownloadResumeStoreAsync(^{
        ICDeleteAllResumeData();
    });
}

- (NSData*) _resumeData
{
    NSString* identifier = [self.identifier copy];
    NSURL* remoteURL = [self.remoteURL copy];
    __block NSData* resumeData = nil;
    ICDownloadResumeStoreSync(^{
        resumeData = ICReadAndDeleteResumeData(identifier, remoteURL);
    });
    return resumeData;
}

@end
