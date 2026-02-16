//
//  ICImageCacheOperation.m
//  InstacastMac
//
//  Created by Martin Hering on 08.01.13.
//  Copyright (c) 2013 Vemedio. All rights reserved.
//

#include <sys/xattr.h>

#import "ICImageCacheOperation.h"
#import "ImageFunctions.h"
#import "UtilityFunctions.h"

#if TARGET_OS_IPHONE
#define IC_IMAGE UIImage
#else
#define IC_IMAGE NSImage
#endif

@interface ImageCacheManager ()
@property (strong) NSMutableDictionary* imageCache;

+ (NSString*) cacheKeyWithURL:(NSURL*)url size:(NSInteger)size grayscale:(BOOL)grayscale;
- (IC_IMAGE*) cachedImageForKey:(NSString*)cacheKey;
@end


@interface ICImageCacheOperation ()
@property NSInteger size;
@property (strong) NSURL* url;
@property BOOL grayscale;
@end



@implementation ICImageCacheOperation

- (id) initWithURL:(NSURL*)url size:(NSInteger)size grayscale:(BOOL)grayscale
{
    if ((self = [super init])) {
        _url = url;
        _size = size;
        _grayscale = grayscale;
    }
    
    return self;
}

- (void) _sendCompletionBlockImage:(IC_IMAGE*)image error:(NSError*)error
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![weakSelf isCancelled] && weakSelf.didEndBlock) {
            weakSelf.didEndBlock(image, error);
        }
    });
}

- (void) _cacheImage:(IC_IMAGE*)image forKey:(NSString*)cacheKey
{
    ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
    @synchronized(iman.imageCache) {
        if (image) {
            [iman.imageCache setObject:image forKey:cacheKey];
        }
    }
}

- (void) _writeJPGImage:(IC_IMAGE*)image toFile:(NSString*)path
{
#if TARGET_OS_IPHONE
    [UIImageJPEGRepresentation(image, 0.8f) writeToFile:path atomically:YES];
#else
    
    for(NSBitmapImageRep* imageRep in [image representations]) {
        if ([imageRep isKindOfClass:[NSBitmapImageRep class]]) {
            NSData* jpegData = [imageRep representationUsingType:NSJPEGFileType properties:nil];
            [jpegData writeToFile:path atomically:YES];
            break;
        }
        else {
            DebugLog(@"fail");
        }
    }
#endif
}


- (void) _processWithCacheKey:(NSString*)cacheKey
{
	NSURL* fileURL = [ImageCacheManager fileURLToCachedImageForImageURL:self.url size:self.size grayscale:self.grayscale];
    NSString* localPath = [fileURL path];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:localPath])
    {
        NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:self.url cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30.f];
        [request setAllowsCellularAccess:[USER_DEFAULTS boolForKey:EnableCachingImagesOver3G]];

        __block NSData* data = nil;
        __block NSError* error = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* responseData, NSURLResponse* resp, NSError* err) {
            data = responseData;
            error = err;
            dispatch_semaphore_signal(semaphore);
        }];
        [task resume];
        while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC))) != 0) {
            if ([self isCancelled]) {
                [task cancel];
                return;
            }
        }
        
        IC_IMAGE* image;
        
        if (data) {
            image = [[IC_IMAGE alloc] initWithData:data];
        }
        
        if (image) {
            [self _writeJPGImage:image toFile:localPath];
            [self _cacheImage:image forKey:cacheKey];
        }
        [self _sendCompletionBlockImage:image error:nil];
    }
    else
    {
        IC_IMAGE* image = [[IC_IMAGE alloc] initWithContentsOfFile:localPath];
        
        [self _cacheImage:image forKey:cacheKey];
        [self _sendCompletionBlockImage:image error:nil];
    }
}

- (BOOL)isJPEGValid:(NSData *)jpeg
{
    NSUInteger l = [jpeg length];
    
    if (l < 4) return NO;
    
    uint8_t bytes[2];
    
    [jpeg getBytes:(void*)bytes length:2];
    if (bytes[0] != 0xFF || bytes[1] != 0xD8) return NO;
    
    [jpeg getBytes:(void*)bytes range:NSMakeRange(l-2, 2)];
    if (bytes[0] != 0xFF || bytes[1] != 0xD9) return NO;
    
    return YES;
}

- (void) _processScaledWithCacheKey:(NSString*)cacheKey scaledSize:(NSInteger)scaledSize
{
    NSURL* fileURL = [ImageCacheManager fileURLToCachedImageForImageURL:self.url size:self.size grayscale:self.grayscale];
    NSString* localPath = [fileURL path];
    
    
    IC_IMAGE* image = [[IC_IMAGE alloc] initWithContentsOfFile:localPath];
    if (image)
    {
        // touch the file to prevent tidying it too soon
        [[NSFileManager defaultManager] setAttributes:[NSDictionary dictionaryWithObject:[NSDate date] forKey:NSFileModificationDate]
                                         ofItemAtPath:localPath
                                                error:nil];
        
        [self _cacheImage:image forKey:cacheKey];
        [self _sendCompletionBlockImage:image error:nil];
        return;
    }
    

    
    // fetch and postprocess the original image
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:self.url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0f];
    [request setAllowsCellularAccess:[USER_DEFAULTS boolForKey:EnableCachingImagesOver3G]];
    NSHTTPURLResponse* response = nil;
    NSError* error = nil;
    NSData* imageData = [self sendSynchronousRequest:request returningResponse:&response error:&error];
    
    image = [[IC_IMAGE alloc] initWithData:imageData];
    if (!error && image && ![self isCancelled])
    {
        
        NSMutableOrderedSet* scaledSizes = [NSMutableOrderedSet orderedSetWithArray:@[@(56), @(60), @(72), @(320)]];
        NSNumber* requestedSize = @(self.size);
        if (![scaledSizes containsObject:requestedSize]) {
            [scaledSizes addObject:requestedSize];
        }

        IC_IMAGE* requestedImage = nil;
        for (NSNumber* scaledSizeNumber in scaledSizes) {
            NSInteger size = [scaledSizeNumber integerValue];
            NSInteger imageSize = size * [ImageCacheManager scalingFactor];
            NSURL* scaledFileURL = [ImageCacheManager fileURLToCachedImageForImageURL:self.url size:size grayscale:self.grayscale];
            NSString* scaledPath = [scaledFileURL path];

            CGImageRef scaledRef = CreateSquaredScaledCGImageFromCGImage([image CGImage], imageSize);
            IC_IMAGE* outputImage = nil;
            if (scaledRef) {
                IC_IMAGE* thumb = [[IC_IMAGE alloc] initWithCGImage:scaledRef];
                CGImageRelease(scaledRef);
                outputImage = (self.grayscale) ? [ImageCacheManager grayscaleImageForImage:thumb] : thumb;
            }
            else {
                outputImage = (self.grayscale) ? [ImageCacheManager grayscaleImageForImage:image] : image;
            }

            [self _writeJPGImage:outputImage toFile:scaledPath];
            AddSkipBackupAttributeToFile(scaledPath);

            if (size == self.size) {
                requestedImage = outputImage;
            }
        }

        if (!requestedImage) {
            requestedImage = (self.grayscale) ? [ImageCacheManager grayscaleImageForImage:image] : image;
            [self _writeJPGImage:requestedImage toFile:localPath];
            AddSkipBackupAttributeToFile(localPath);
        }

        [self _cacheImage:requestedImage forKey:cacheKey];
        [self _sendCompletionBlockImage:requestedImage error:nil];
        return;
    }


    DebugLog(@"original image not found at %@", [self.url absoluteString]);
    //[_failedImages setObject:@YES forKey:[refURL absoluteString]];
    
    [self _sendCompletionBlockImage:nil error:error];
}

- (void) main
{
    @autoreleasepool {

        if ([self isCancelled]) {
            DebugLog(@"canceled");
            return;
        }

        if (!self.url) {
            [self _sendCompletionBlockImage:nil error:nil];
            return;
        }
        
        ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
        
        NSInteger scaledSize = self.size*[ImageCacheManager scalingFactor];
        NSString* cacheKey = [ImageCacheManager cacheKeyWithURL:self.url size:self.size grayscale:self.grayscale];

        @synchronized(iman.imageCache) {
            IC_IMAGE* cachedImage = [[ImageCacheManager sharedImageCacheManager] cachedImageForKey:cacheKey];
            
            if (cachedImage) {
                [self _sendCompletionBlockImage:cachedImage error:nil];
                return;
            }
        }
        
        [App retainNetworkActivity];
        
        if (self.size > 0) {
            [self _processScaledWithCacheKey:cacheKey scaledSize:scaledSize];
        }
        else {
            [self _processWithCacheKey:cacheKey];
        }
        
        [App releaseNetworkActivity];
    }
}

@end
