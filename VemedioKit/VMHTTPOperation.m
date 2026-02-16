//
//  VMHTTPOperation.m
//  InstacastMac
//
//  Created by Martin Hering on 08.01.13.
//  Copyright (c) 2013 Vemedio. All rights reserved.
//

#import "VMHTTPOperation.h"
#import "NSString+VMFoundation.h"
#import "NSData+VMFoundation.h"

#if TARGET_OS_IPHONE==0
#import <Security/Security.h>
#endif

@interface VMHTTPOperation () <NSURLSessionDelegate, NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
@property (strong) NSMutableData* connectionData;
@property (strong) NSURLSession* session;
@property (strong) NSURLSessionDataTask* dataTask;
@property (strong) NSURLResponse* connectionResponse;
@property (strong) NSError* connectionError;
@end

@implementation VMHTTPOperation {
    dispatch_semaphore_t _connectionSemaphore;
    long long _loadedBytes;
    long long _totalBytes;
}

- (id) init
{
	if ((self = [super init])) {
        // don't change, this timeout cancels request after 30 secs, even if traffic is slow
        _timeout = 0;
	}
	return self;
}

- (NSData*) sendSynchronousRequest:(NSMutableURLRequest*)request returningResponse:(__autoreleasing NSHTTPURLResponse**)outResponse error:(__autoreleasing NSError**)outError
{
    _connectionSemaphore = dispatch_semaphore_create(0);
    _loadedBytes = 0;

    NSInteger internalErrors = 0;
    NSData* data = nil;
    NSMutableSet* queriedURLs = [[NSMutableSet alloc] init];

    if (self.forceBasicAuth && self.username && self.password)
    {
        NSString* auth = [NSString stringWithFormat:@"%@:%@", self.username, self.password];
        NSString* base64 = [[auth dataUsingEncoding:NSUTF8StringEncoding] stringFromBase64EncodedData];
        [request addValue:[NSString stringWithFormat:@"Basic %@", base64] forHTTPHeaderField:@"Authorization"];
    }
    else if (self.forceBearerAuth && self.bearerToken)
    {
        [request addValue:[NSString stringWithFormat:@"Bearer %@", self.bearerToken] forHTTPHeaderField:@"Authorization"];
    }

    // Create session configuration
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    if (self.timeout > 0) {
        config.timeoutIntervalForRequest = self.timeout;
        config.timeoutIntervalForResource = self.timeout * 2;
    }

    // Create session with delegate
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];

    while (!data)
    {
#ifndef DEBUG // DEBUG should throw and exception
        if (!request.URL) {
            break;
        }
#endif

        if([queriedURLs containsObject:request.URL]) {
            self.connectionError = [NSError errorWithDomain:NSURLErrorDomain
                                                       code:kCFURLErrorHTTPTooManyRedirects
                                                   userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                             @"Redirection Loop", NSLocalizedDescriptionKey,
                                                             @"URLs are redirecting to each other forming a loop.", NSLocalizedRecoverySuggestionErrorKey, nil]];
            break;
        }

        if (request.URL != nil) {
            [queriedURLs addObject:request.URL];
        } else {
            NSLog(@"Warning: Attempted to add nil (request.URL) object to set.");
        }

        self.connectionResponse = nil;
        self.connectionError = nil;

        self.dataTask = [self.session dataTaskWithRequest:request];
        [self.dataTask resume];

        // wait for completion, but keep cancellation responsive.
        BOOL waitTimedOut = NO;
        BOOL waitCancelled = NO;
        if (self.timeout > 0) {
            dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeout * 2 * NSEC_PER_SEC));
            while (dispatch_semaphore_wait(_connectionSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC))) != 0) {
                if ([self isCancelled]) {
                    waitCancelled = YES;
                    break;
                }
                if (dispatch_time(DISPATCH_TIME_NOW, 0) >= deadline) {
                    waitTimedOut = YES;
                    break;
                }
            }
        } else {
            // Fallback max timeout of 120 seconds to prevent indefinite blocking
            dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC));
            while (dispatch_semaphore_wait(_connectionSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC))) != 0) {
                if ([self isCancelled]) {
                    waitCancelled = YES;
                    break;
                }
                if (dispatch_time(DISPATCH_TIME_NOW, 0) >= deadline) {
                    waitTimedOut = YES;
                    break;
                }
            }
        }

        if (waitTimedOut || waitCancelled) {
            [self.dataTask cancel];

            if (waitTimedOut) {
                self.connectionError = [NSError errorWithDomain:NSURLErrorDomain
                                                           code:kCFURLErrorTimedOut
                                                       userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                 @"Connection Timeout", NSLocalizedDescriptionKey,
                                                                 @"Connection timed out.", NSLocalizedRecoverySuggestionErrorKey, nil]];
            } else {
                self.connectionError = [NSError errorWithDomain:NSURLErrorDomain
                                                           code:kCFURLErrorCancelled
                                                       userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                                 @"Connection Cancelled", NSLocalizedDescriptionKey,
                                                                 @"The request was cancelled.", NSLocalizedRecoverySuggestionErrorKey, nil]];
            }

            self.connectionData = nil;
            self.dataTask = nil;
            break;
        }

        NSHTTPURLResponse* response = (NSHTTPURLResponse*)self.connectionResponse;
        NSInteger statusCode = [response statusCode];

        if (statusCode == 0 && !self.connectionError) {
            self.connectionData = nil;
            self.dataTask = nil;
            [queriedURLs removeObject:request.URL];
            internalErrors++;

            if (internalErrors > 5) {
                self.connectionData = nil;
                self.dataTask = nil;
                break;
            }
        }

        else if (statusCode == 301 || statusCode == 302 || statusCode == 307) {
            NSString* redirectLocation = [[response allHeaderFields] objectForKey:@"Location"];
            NSURL* originalURL = request.URL;
            NSURL* newURL = [NSURL URLWithString:redirectLocation relativeToURL:originalURL];
            if (!newURL) {
                newURL = [NSURL URLWithString:redirectLocation relativeToURL:originalURL];
            }
            request.URL = newURL;
            if (statusCode == 301) {
                self.permanentRedirectURL = request.URL;
            }
            else if (statusCode == 302 || statusCode == 307) {
                self.temporaryRedirectURL = request.URL;
            }

            self.connectionData = nil;
            self.dataTask = nil;
        }

        else if (statusCode == 401) {
            self.connectionError = [NSError errorWithDomain:NSURLErrorDomain
                                                       code:kCFURLErrorUserAuthenticationRequired
                                                   userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                             @"Authentication required", NSLocalizedDescriptionKey,
                                                             @"Please provide username and password.", NSLocalizedRecoverySuggestionErrorKey, nil]];
            self.connectionData = nil;
            self.dataTask = nil;
            break;
        }

        else
        {
#ifdef DEBUG
            if (statusCode == 404) {
                DebugLog(@"status code >= 300 (%ld): %@", (long)statusCode, [request.URL absoluteString]);
            }

            else if (statusCode >= 300) {
                NSString* content = [[NSString alloc] initWithData:self.connectionData encoding:NSUTF8StringEncoding];
                DebugLog(@"status code >= 300 (%ld)\n%@:\n%@\n", (long)statusCode, [request.URL absoluteString], content);
            }
#endif
            data = self.connectionData;
            self.connectionData = nil;
            self.dataTask = nil;
            break;
        }
    }


    if (outResponse) {
        *outResponse = (NSHTTPURLResponse*)self.connectionResponse;
    }

    if (outError) {
        *outError = self.connectionError;
    }

    [self.session finishTasksAndInvalidate];

    return data;
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    NSURLProtectionSpace *protectionSpace = challenge.protectionSpace;

    if ([protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
    {
        NSURLCredential *credential = [NSURLCredential credentialForTrust:protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
    }
    else if ([protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodClientCertificate]) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
    else if ([challenge previousFailureCount] == 0 && self.username && self.password)
    {
        NSURLCredential* credentials = [NSURLCredential credentialWithUser:self.username
                                                                  password:self.password
                                                               persistence:NSURLCredentialPersistenceNone];
        completionHandler(NSURLSessionAuthChallengeUseCredential, credentials);
    }
    else
    {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

#pragma mark - NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential * _Nullable))completionHandler
{
    [self URLSession:session didReceiveChallenge:challenge completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    // Return nil to handle redirects manually (like the old NSURLConnection behavior)
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    if (error) {
        self.connectionError = error;
    }
    dispatch_semaphore_signal(_connectionSemaphore);
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler
{
    self.connectionResponse = response;
    _totalBytes = [response expectedContentLength];

    NSNumber* contentLength = [(NSHTTPURLResponse*)response allHeaderFields][@"Content-Length"];
    if (_totalBytes <= 0 && contentLength) {
        _totalBytes = [contentLength longLongValue];
    }

    if (self.limitSize > 0 && [response expectedContentLength] != NSURLResponseUnknownLength && [response expectedContentLength] > self.limitSize) {
        ErrLog(@"feed limitation exceeded: %lld", [response expectedContentLength]);

        self.connectionError = [NSError errorWithDomain:NSURLErrorDomain
                                                   code:NSURLErrorDataLengthExceedsMaximum
                                               userInfo:[NSDictionary dictionaryWithObjectsAndKeys:
                                                         @"Data length exceeded", NSLocalizedDescriptionKey,
                                                         @"Resource data exceeds the maximum allowed.", NSLocalizedRecoverySuggestionErrorKey, nil]];
        completionHandler(NSURLSessionResponseCancel);
        return;
    }

    self.connectionData = [NSMutableData data];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data
{
    [self.connectionData appendData:data];

    _loadedBytes += [data length];

    long long loadedBytes = _loadedBytes;
    long long totalBytes = _totalBytes;
    void (^didLoadBytesBlock)(long long, long long) = self.didLoadBytes;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (didLoadBytesBlock) {
            didLoadBytesBlock(loadedBytes, totalBytes);
        }
    });
}

- (void) cancel
{
    [super cancel];
    [self.dataTask cancel];
    if (_connectionSemaphore) {
    	dispatch_semaphore_signal(_connectionSemaphore);
    }
}

- (void) main
{
    @autoreleasepool {
        [NSException raise:NSInternalInconsistencyException format:@"abstract class must be subsclassed"];
    }
}

@end
