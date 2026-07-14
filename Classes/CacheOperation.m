//
//  CacheOperation.m
//  Instacast
//
//  Created by Martin Hering on 03.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import "CacheOperation.h"
#import "HTTPAuthentication.h"
#import "UtilityFunctions.h"

static NSString* kUserDefaultsResumeInfoKey = @"DownloadResumeInfos";

@interface CacheOperation () <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (readwrite, copy) NSURL* remoteURL;
@property (readwrite, copy) NSURL* localURL;
@property (readwrite, copy) NSURL* tempURL;
@property (readwrite, strong) NSFileHandle* fileHandle;
@property (readwrite, strong) NSDate* startDate;
@property BOOL authDone;
@property BOOL authCancel;
@property BOOL finishedLoading;
@property BOOL mainCanceled;
@property BOOL tryAgain;
@property (strong) NSURLSession* urlSession;
@property (strong) NSURLSessionDataTask* mainTask;
@property (strong) NSOperationQueue* delegateQueue;
@property (strong) HTTPAuthentication* authentication;
@property (readwrite, strong) NSString* identifier;
@end


@implementation CacheOperation {
	long long			_expectedContentLength;
	long long			_loadedContentLength;
    long long           _restartedAtContentLength;
    NSMutableData*      _temporaryData;
    dispatch_semaphore_t _stateChangeSemaphore;
}

@dynamic progress;

- (id) initWithURL:(NSURL*)aRemoteURL localURL:(NSURL*)aLocalURL tempURL:(NSURL*)aTempURL identifier:(NSString*)identifier
{
	if ((self = [self init]))
	{
        // workaround for a bug in the feed parser up to version 3.0.2
        NSString* remoteURLString = [aRemoteURL absoluteString];
        if ([remoteURLString rangeOfString:@"%25"].location != NSNotFound) {
            remoteURLString = [remoteURLString stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
            aRemoteURL = [NSURL URLWithString:remoteURLString];
        }

		_remoteURL = [aRemoteURL copy];
		_localURL = [aLocalURL copy];
		_tempURL = [aTempURL copy];
        _identifier = [identifier copy];
        _expectedContentLength = 0;

        _temporaryData = [[NSMutableData alloc] initWithCapacity:1024*1024*2];
        _stateChangeSemaphore = dispatch_semaphore_create(0);
	}

	return self;
}



+ (void) removeCacheForRemoteURL:(NSURL*)remoteURL atLocalURL:(NSURL*)url tempURL:(NSURL*)tempURL
{
	NSFileManager* fman = [NSFileManager defaultManager];

	NSString* path = [url path];
    [[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:[path stringByDeletingLastPathComponent] destination:@"" files:@[[path lastPathComponent]] tag:NULL];
	[fman removeItemAtPath:path error:nil];

	NSString* tempPath = [tempURL path];
	[fman removeItemAtPath:tempPath error:nil];

    [self deleteResumeInfoForRemoteURL:remoteURL];
}

- (void) cancel
{
    if (![self isExecuting]) {
        self.failed = YES;
        [self _notifyDidEndOnMainThread];
    }

    [super cancel];
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

- (void)_notifyDidLoadBytesOnMainThread:(int64_t)loadedBytes
{
    id<CacheOperationDelegate> delegate = self.delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(cacheOperation:didLoadNumberOfBytes:)]) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        id<CacheOperationDelegate> strongDelegate = self.delegate;
        if (strongDelegate && [strongDelegate respondsToSelector:@selector(cacheOperation:didLoadNumberOfBytes:)]) {
            [strongDelegate cacheOperation:self didLoadNumberOfBytes:loadedBytes];
        }
    });
}

- (void)_performSessionStateWorkAndWait:(dispatch_block_t)block
{
    if (!block) {
        return;
    }

    if (!self.delegateQueue) {
        block();
        return;
    }

    NSBlockOperation* operation = [NSBlockOperation blockOperationWithBlock:block];
    [self.delegateQueue addOperations:@[operation] waitUntilFinished:YES];
}

- (double) progress
{
	if (_expectedContentLength == 0 || _expectedContentLength < _loadedContentLength) {
		return 0.0;
	}
	return (double)_loadedContentLength / (double)_expectedContentLength;
}

- (NSTimeInterval) estimatedTimeLeft
{
    if (_expectedContentLength - _restartedAtContentLength <= 0) {
        return 0;
    }

    double progress = (double)(_loadedContentLength - _restartedAtContentLength) / (double)(_expectedContentLength - _restartedAtContentLength);
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

- (BOOL) _initializeDownload
{
    NSFileManager* fman = [NSFileManager defaultManager];
	NSString* tempPath = [self.tempURL path];

    NSDictionary* resumeInfo = [self _resumeInfo];
    _expectedContentLength = [resumeInfo[@"Content-Length"] longLongValue];

	// create file if not already exists from a former canceled download
	if (![fman fileExistsAtPath:tempPath]) {
		[fman createFileAtPath:tempPath contents:[NSData data] attributes:nil];
		_loadedContentLength = 0LL;
	}
	else {
		NSError* error = nil;
		NSDictionary* fileAttributes = [fman attributesOfItemAtPath:tempPath error:&error];
		_loadedContentLength = [[fileAttributes objectForKey:NSFileSize] longLongValue];
	}

    // remove the partial file, when there is no resume data
    if (_loadedContentLength > 0 && _expectedContentLength == 0) {
        [fman removeItemAtURL:self.tempURL error:nil];
        [fman createFileAtPath:tempPath contents:[NSData data] attributes:nil];
        _loadedContentLength = 0;
    }

	self.fileHandle = [NSFileHandle fileHandleForWritingAtPath:tempPath];
	if (!self.fileHandle) {
		ErrLog(@"error creating file handle");
		self.failed = YES;
		return NO;
	}
	[self.fileHandle seekToEndOfFile];


	self.startDate = [NSDate date];


    NSURL* requestURL = self.remoteURL;

    BOOL enabled3G = (self.overwriteCellularLock || [USER_DEFAULTS boolForKey:EnableCachingOver3G]);
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:requestURL cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.f];
    [request setAllowsCellularAccess:enabled3G];
    [request setNetworkServiceType:NSURLNetworkServiceTypeVoice];

    // make sure to send fake iTunes Header when content is hosted on iTunes
    if ([[requestURL host] rangeOfString:@"apple.com" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [request addValue:@"143441-1,12" forHTTPHeaderField:@"X-Apple-Store-Front"];
        [request addValue:@"iTunes/10.1.2 (Macintosh; Intel Mac OS X 10.6.6) AppleWebKit/533.19.4" forHTTPHeaderField:@"User-Agent"];
    }

    if (_expectedContentLength > 0 && _loadedContentLength > 0) {
        NSString* rangeString = [NSString stringWithFormat:@"bytes=%lld-%lld", _loadedContentLength, _expectedContentLength-1];
        [request addValue:rangeString forHTTPHeaderField:@"Range"];
        [request addValue:@"" forHTTPHeaderField:@"Accept-Encoding"]; // make sure we not accept Gzip to get a valid expectedContentLength
        _restartedAtContentLength = _loadedContentLength;
    }

    // Create session configuration
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.allowsCellularAccess = enabled3G;
    config.timeoutIntervalForRequest = 30.0;

    if (!self.delegateQueue) {
        NSOperationQueue* delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1;
        delegateQueue.qualityOfService = self.automatic ? NSQualityOfServiceUtility : NSQualityOfServiceUserInitiated;
        delegateQueue.name = [NSString stringWithFormat:@"com.vemedio.instacast.cache.mac.%@", self.identifier ?: @"download"];
        self.delegateQueue = delegateQueue;
    }

    self.urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:self.delegateQueue];
    self.mainTask = [self.urlSession dataTaskWithRequest:request];
    [self.mainTask resume];
    dispatch_semaphore_signal(_stateChangeSemaphore);

    return YES;
}

- (void) _runDownload
{
    // if the partial download failed, start from the beginning
    if (self.mainCanceled && self.mainTask) {
        [self.mainTask cancel];
        self.mainTask = nil;
        [self.urlSession invalidateAndCancel];
        self.urlSession = nil;
        self.mainCanceled = NO;

        [self.fileHandle closeFile];
        self.fileHandle = nil;
        [[NSFileManager defaultManager] removeItemAtURL:self.tempURL error:nil];
        _restartedAtContentLength = 0;

        [self _initializeDownload];
    }

    // we got suspended, but have a task, kill the task
    if (self.suspended && self.mainTask) {
        [self.mainTask cancel];
        self.mainTask = nil;
        [self.urlSession invalidateAndCancel];
        self.urlSession = nil;

        if ([_temporaryData length] > 0) {
            [self.fileHandle writeData:_temporaryData];
            [_temporaryData setData:[NSData data]];
        }

        [self.fileHandle closeFile];
        self.fileHandle = nil;
        _restartedAtContentLength = 0;
    }

    // we got resumed, but have no task yet, start a new one with range parameters
    else if (!self.suspended && !self.mainTask) {
        [self _initializeDownload];
    }

    dispatch_semaphore_signal(_stateChangeSemaphore);
}

- (void) _finishDownload
{
    if (self.mainTask)
    {
        [self.mainTask cancel];
        self.mainTask = nil;
        [self.urlSession finishTasksAndInvalidate];
        self.urlSession = nil;

        // close the temporary file
        [self.fileHandle closeFile];
        self.fileHandle = nil;

        // move the temporary file to its final destination, if everything ended well
        if (![self isCancelled] && !self.failed)
        {
            NSError* error = nil;
            if (![[NSFileManager defaultManager] moveItemAtPath:[self.tempURL path] toPath:[self.localURL path] error:&error]) {
                ErrLog(@"error moving temporary file %@", [error description]);
                self.failed = YES;
            }
            // remove the temporary file
            [[NSFileManager defaultManager] removeItemAtPath:[self.tempURL path] error:nil];
        }
    }

    if (self.finishedLoading) {
        [self _deleteResumeInfo];
    }

    if (!self.tryAgain) {
        [self _notifyDidEndOnMainThread];
    }

    dispatch_semaphore_signal(_stateChangeSemaphore);
}


- (void) main
{
	@autoreleasepool
    {
        while (self.suspended && ![self isCancelled]) {
            dispatch_semaphore_wait(_stateChangeSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)));
        }

        if ([self isCancelled]) {
            [self _performSessionStateWorkAndWait:^{
                [self _finishDownload];
            }];
            return;
        }

        do
        {
            self.tryAgain = NO;
            self.failed = NO;
            self.finishedLoading = NO;

            if (![self _initializeDownload]) {
                [self _finishDownload];
                [self cancel];
                break;
            }


            while (![self isCancelled] && (!self.failed || self.suspended))
            {
                @autoreleasepool {
                    dispatch_semaphore_wait(_stateChangeSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)));

                    if (self.finishedLoading) {
                        break;
                    }

                    [self _performSessionStateWorkAndWait:^{
                        [self _runDownload];
                    }];
                }
            }

            [self _performSessionStateWorkAndWait:^{
                if ([_temporaryData length] > 0 && self.fileHandle) {
                    [self.fileHandle writeData:_temporaryData];
                    [_temporaryData setData:[NSData data]];
                }

                [self _finishDownload];
            }];

        } while (self.tryAgain);

    }
}

#pragma mark -
#pragma mark NSURLSession Delegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask willCacheResponse:(NSCachedURLResponse *)proposedResponse completionHandler:(void (^)(NSCachedURLResponse * _Nullable))completionHandler
{
    completionHandler(nil);
}


- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    NSInteger statusCode = [(NSHTTPURLResponse*)response statusCode];

	if (statusCode == 401) {
		ErrLog(@"authorization required");
		self.failed = (!self.suspended);
        dispatch_semaphore_signal(_stateChangeSemaphore);
        completionHandler(NSURLSessionResponseCancel);
		return;
	}

    if (statusCode < 200 || statusCode > 299 )
    {
        ErrLog(@"media download failed. status code: %ld", (long)statusCode);
        self.failed = (!self.suspended);
        dispatch_semaphore_signal(_stateChangeSemaphore);
        completionHandler(NSURLSessionResponseCancel);
		return;
	}

    NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;

    if (dataTask == self.mainTask)
    {
        if (_expectedContentLength == 0LLU && [response expectedContentLength] > 0) {
            _expectedContentLength = [response expectedContentLength] + _restartedAtContentLength;

            NSDictionary* allHeaders = [httpResponse allHeaderFields];
            [self _saveResumeInfo:allHeaders];
        }

        // check etag if resume is still valid
        if (_restartedAtContentLength > 0) {
            NSString* currentEtag = [httpResponse allHeaderFields][@"Etag"];
            NSString* savedEtag = [self _resumeInfo][@"Etag"];

            if (currentEtag != savedEtag && ![currentEtag isEqualToString:savedEtag]) {
                ErrLog(@"can't resume, 'Etag' changed.");
                self.mainCanceled = YES;
                dispatch_semaphore_signal(_stateChangeSemaphore);
                completionHandler(NSURLSessionResponseCancel);
                return;
            }
        }
    }

    dispatch_semaphore_signal(_stateChangeSemaphore);
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    NSURLProtectionSpace *protectionSpace = challenge.protectionSpace;

    // Handle server trust
    if ([protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSURLCredential *credential = [NSURLCredential credentialForTrust:protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
        return;
    }

	// in case we can use the username and password stored in the feed
	if (self.username && self.password && [challenge previousFailureCount] == 0)
	{
		NSURLCredential* credentials = [NSURLCredential credentialWithUser:self.username password:self.password persistence:NSURLCredentialPersistenceNone];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credentials);
		return;
	}

    dispatch_async(dispatch_get_main_queue(), ^{
        self.authentication = [[HTTPAuthentication alloc] init];
        self.authentication.url = self.remoteURL;
        self.authentication.username = (self.username) ? self.username : [[challenge proposedCredential] user];
        self.authentication.userInfo = challenge;
        self.authentication.failedBefore = ([challenge previousFailureCount] > 0);
        [self.authentication showAuthenticationDialogCompletion:^(BOOL success, NSString *username, NSString *password)
        {
            if (!success) {
                completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
            } else {
                self.username = username;
                self.password = password;
                NSURLCredential* credentials = [NSURLCredential credentialWithUser:self.username password:self.password persistence:NSURLCredentialPersistenceNone];
                completionHandler(NSURLSessionAuthChallengeUseCredential, credentials);
            }
            dispatch_semaphore_signal(_stateChangeSemaphore);
        }];
    });

}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    [_temporaryData appendData:data];

    if ([_temporaryData length] > 1024*1024) {
        [self.fileHandle writeData:_temporaryData];
        [_temporaryData setData:[NSData data]];
    }

	_loadedContentLength += [data length];

    [self _notifyDidLoadBytesOnMainThread:[data length]];
    dispatch_semaphore_signal(_stateChangeSemaphore);

}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error) {
        BOOL cancelledError = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled;
        if (!cancelledError && !self.mainCanceled && !self.suspended && ![self isCancelled]) {
            self.failed = YES;
        }
        dispatch_semaphore_signal(_stateChangeSemaphore);
    } else {
        if (_expectedContentLength== 0LL || _loadedContentLength == _expectedContentLength) {
            self.finishedLoading = YES;
        }
        dispatch_semaphore_signal(_stateChangeSemaphore);
    }
}

#pragma mark - Handling Resume Information

- (NSString*) _resourceHash
{
    return [[self.remoteURL absoluteString] MD5Hash];
}

- (void) _saveResumeInfo:(NSDictionary*)resumeInfo
{
    NSMutableDictionary* resumeInfos = [[USER_DEFAULTS objectForKey:kUserDefaultsResumeInfoKey] mutableCopy];
    if (!resumeInfos) {
        resumeInfos = [[NSMutableDictionary alloc] init];
    }

    NSString* resourceHash = [self _resourceHash];
    NSError* archiveError = nil;
    NSData* resumeData = [NSKeyedArchiver archivedDataWithRootObject:resumeInfo requiringSecureCoding:NO error:&archiveError];
    if (resourceHash && resumeData) {
        [resumeInfos setObject:resumeData forKey:resourceHash];
        [USER_DEFAULTS setObject:resumeInfos forKey:kUserDefaultsResumeInfoKey];
    }
}

+ (void) deleteResumeInfoForRemoteURL:(NSURL*)url
{
    NSString* resourceHash = [[url absoluteString] MD5Hash];

    NSMutableDictionary* resumeInfos = [[USER_DEFAULTS objectForKey:kUserDefaultsResumeInfoKey] mutableCopy];

    if (resumeInfos[resourceHash]) {
        [resumeInfos removeObjectForKey:resourceHash];
        [USER_DEFAULTS setObject:resumeInfos forKey:kUserDefaultsResumeInfoKey];
    }
}

- (void) _deleteResumeInfo
{
    [CacheOperation deleteResumeInfoForRemoteURL:self.remoteURL];
}

- (NSDictionary*) _resumeInfo
{
    NSString* resourceHash = [self _resourceHash];
    NSData* resumeData = [USER_DEFAULTS objectForKey:kUserDefaultsResumeInfoKey][resourceHash];
    if (resumeData) {
        NSError* unarchiveError = nil;
        return [NSKeyedUnarchiver unarchivedObjectOfClass:[NSDictionary class] fromData:resumeData error:&unarchiveError];
    }
    return nil;
}
@end
