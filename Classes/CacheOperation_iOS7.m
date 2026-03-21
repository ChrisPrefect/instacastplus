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

NSString* kUserDefaultsResumeInfoKey = @"DownloadResumeInfos_NSURLSession";


@interface CacheOperation_iOS7 () <NSURLSessionDelegate, NSURLSessionDownloadDelegate>
@property (strong) NSURLSession* session;
@property (strong) NSURLSessionDownloadTask* downloadTask;
@property (strong) NSOperationQueue* delegateQueue;

@property (readwrite, strong) NSString* identifier;
@property (readwrite) long long expectedContentLength;
@property (readwrite) long long loadedContentLength;
@property (readwrite) long long restartedAtContentLength;
@property (readwrite, strong) NSDate* startDate;
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
        _expectedContentLength = expectedContentLength;
        
        NSString* logsPath = [[NSBundle pathToLogsDirectory] stringByAppendingPathComponent:@"MediaFileImporter.log"];
        
        _logger = [GTMLogger standardLoggerWithPath:logsPath];
        [_logger setFilter:[[GTMLogLevelFilter alloc] init]];
        _stateChangeSemaphore = dispatch_semaphore_create(0);
        
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
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (BOOL) suspended {
    return (self.downloadTask.state == NSURLSessionTaskStateSuspended);
}

- (void) setSuspended:(BOOL)suspended
{
    if (suspended != (self.downloadTask.state == NSURLSessionTaskStateSuspended))
    {
        _shouldBeSuspended = suspended;
        
        if (suspended)
        {
            if (self.downloadTask.state != NSURLSessionTaskStateSuspended) {
                [self.downloadTask suspend];
            }
        }
        else
        {
            if (self.downloadTask.state == NSURLSessionTaskStateSuspended) {
                [self.downloadTask resume];
            }
            
            self.restartedAtContentLength = self.loadedContentLength;
            self.startDate = [NSDate date];
        }

        dispatch_semaphore_signal(_stateChangeSemaphore);
    }
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

- (void)_notifyDidLoadBytesOnMainThread:(int64_t)bytesWritten
{
    id<CacheOperationDelegate> delegate = self.delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(cacheOperation:didLoadNumberOfBytes:)]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        id<CacheOperationDelegate> strongDelegate = self.delegate;
        if (strongDelegate && [strongDelegate respondsToSelector:@selector(cacheOperation:didLoadNumberOfBytes:)]) {
            [strongDelegate cacheOperation:self didLoadNumberOfBytes:bytesWritten];
        }
    });
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
            DebugLog(@"download tasks %lu", (unsigned long)[downloadTasks count]);

            if ([downloadTasks count] > 0) {
                self.downloadTask = [downloadTasks firstObject];
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

                [self _deleteResumeInfo];

                if (!self.downloadTask) {
                    [activeSession invalidateAndCancel];
                    activeSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:self.delegateQueue];
                    self.session = activeSession;
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
                    self.failed = YES;
                    [self cancel];
                }
            }

            if (self.downloadTask && !self->_shouldBeSuspended) {
                [self.downloadTask resume];
            }
            self.startDate = [NSDate date];
            setupFinished = YES;
            dispatch_semaphore_signal(self->_stateChangeSemaphore);
        }];

        while (!setupFinished && ![self isCancelled]) {
            dispatch_semaphore_wait(_stateChangeSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));
        }

        NSInteger idleCounter = 0;
        while ((!self.downloadTask || self.downloadTask.state != NSURLSessionTaskStateCompleted) && ![self isCancelled]) {
            dispatch_semaphore_wait(_stateChangeSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));

            if (self.loadedContentLength == 0 && self.downloadTask && self.downloadTask.state == NSURLSessionTaskStateRunning) {
                idleCounter++;
                if (idleCounter >= 20) {
                    self.failed = YES;
                    // Cancel only the task (not the session) to avoid double-invalidation:
                    // The session cleanup happens below via finishTasksAndInvalidate,
                    // which fires didBecomeInvalidWithError: exactly once.
                    [self.downloadTask cancel];
                    break;
                }
            } else if (self.loadedContentLength > 0) {
                idleCounter = 0;
            }
        }

        if ([self isCancelled])
        {
            [self.downloadTask cancelByProducingResumeData:^(NSData *resumeData) {
                if (resumeData) {
                    [self _saveResumeData:resumeData];
                }
                dispatch_semaphore_signal(self->_stateChangeSemaphore);
            }];

            [self.session invalidateAndCancel];
        }
        else if (self.session)
        {
            [self.session finishTasksAndInvalidate];
        }

        while (self.session && ![self isCancelled]) {
            dispatch_semaphore_wait(_stateChangeSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));
        }

        [self _notifyDidEndOnMainThread];
    }
}

#pragma mark - NSURLSession Delegate

- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
    if (!error) {
        DebugLog(@"didBecomeInvalidWithError %@ for: %@", error, session.configuration.identifier);
    }
    self.session = nil;
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    DebugLog(@"URLSessionDidFinishEventsForBackgroundURLSession for: %@", session.configuration.identifier);
}



#pragma mark NSURLSessionDownloadDelegate Delegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    DebugLog(@"%lx: didReceiveChallenge for: %@  auth: %lx", (long)self, session.configuration.identifier, (long)self.authentication);
    
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
    DebugLog(@"task didCompleteWithError %@", error);
    
    if (error) {
        self.failed = (!self.suspended);
        
        NSData* resumeData = [error userInfo][NSURLSessionDownloadTaskResumeData];
        if (resumeData) {
            [self _saveResumeData:resumeData];
        }
    }

    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location
{
    DebugLog(@"didFinishDownloadingToURL %@, %@ for: %@", location, self.localURL, session.configuration.identifier);
    
    NSFileManager* fman = [[NSFileManager alloc] init];
    [fman removeItemAtURL:self.localURL error:nil];
    
    NSError* error = nil;
    NSDictionary* info = [fman attributesOfItemAtPath:location.path error:&error];
    if (error) {
        ErrLog(@"could not get file attributes for downloaded file: %@", location);
        self.failed = YES;
        dispatch_semaphore_signal(_stateChangeSemaphore);
        return;
    }
    
    unsigned long long fileSize = [info[NSFileSize] unsignedLongLongValue];
    if (fileSize < 100*1024) {
        ErrLog(@"file is too small, maybe DNS error");
        self.failed = YES;
        dispatch_semaphore_signal(_stateChangeSemaphore);
        return;
    }
    
    error = nil;
    if (![fman moveItemAtURL:location toURL:self.localURL error:&error]) {
        self.failed = YES;
        ErrLog(@"could not move file: %@", error);
    }
    else {
        AddSkipBackupAttributeToFile([self.localURL path]);
    }

    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    //DebugLog(@"didWriteData bytesWritten=%lld, totalBytesWritten=%lld, totalBytesExpectedToWrite=%lld", bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    
    self.loadedContentLength = totalBytesWritten;
    if (self.expectedContentLength == 0) {
        self.expectedContentLength = totalBytesExpectedToWrite;
    }
    
    [self _notifyDidLoadBytesOnMainThread:bytesWritten];
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    self.expectedContentLength = expectedTotalBytes;
    self.restartedAtContentLength = fileOffset;
    dispatch_semaphore_signal(_stateChangeSemaphore);
}

#pragma mark - Handling Resume Information


- (void) _saveResumeData:(NSData*)resumeData
{
    NSMutableDictionary* resumeInfos = [[USER_DEFAULTS objectForKey:kUserDefaultsResumeInfoKey] mutableCopy];
    if (!resumeInfos) {
        resumeInfos = [[NSMutableDictionary alloc] init];
    }
    
    if (resumeData) {
        [resumeInfos setObject:resumeData forKey:self.identifier];
        [USER_DEFAULTS setObject:resumeInfos forKey:kUserDefaultsResumeInfoKey];
    }
}

+ (void) deleteResumeInfoForIdentifier:(NSString*)identifier
{
    NSMutableDictionary* resumeInfos = [[USER_DEFAULTS objectForKey:kUserDefaultsResumeInfoKey] mutableCopy];
    
    if (resumeInfos[identifier]) {
        [resumeInfos removeObjectForKey:identifier];
        [USER_DEFAULTS setObject:resumeInfos forKey:kUserDefaultsResumeInfoKey];
    }
}

- (void) _deleteResumeInfo
{
    [[self class] deleteResumeInfoForIdentifier:self.identifier];
}

- (NSData*) _resumeData
{
    NSDictionary* resumeInfos = [USER_DEFAULTS objectForKey:kUserDefaultsResumeInfoKey];
    NSData* resumeData = resumeInfos[self.identifier];
    
    if (!resumeData || [resumeData length] < 1) {
        return nil;
    }
        
    NSError *error;
    NSDictionary *resumeDictionary = [NSPropertyListSerialization propertyListWithData:resumeData
                                                                               options:NSPropertyListImmutable
                                                                                format:NULL
                                                                                 error:&error];
    if (!resumeDictionary || error) {
        return nil;
    }
    
    NSString *localFilePath = [resumeDictionary objectForKey:@"NSURLSessionResumeInfoLocalPath"];
    if ([localFilePath length] < 1) {
        return nil;
    }
        
    return ([[NSFileManager defaultManager] fileExistsAtPath:localFilePath]) ? resumeData : nil;
}

@end
