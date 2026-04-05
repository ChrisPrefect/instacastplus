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
@property (strong) NSCache* imageCache;

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
    if (image) {
        [iman.imageCache setObject:image forKey:cacheKey];
    }
}

- (void) _writeJPGImage:(IC_IMAGE*)image toFile:(NSString*)path
{
#if TARGET_OS_IPHONE
    NSData* jpegData = UIImageJPEGRepresentation(image, 0.8f);
#else
    NSData* jpegData = nil;
    for(NSBitmapImageRep* imageRep in [image representations]) {
        if ([imageRep isKindOfClass:[NSBitmapImageRep class]]) {
            jpegData = [imageRep representationUsingType:NSJPEGFileType properties:nil];
            break;
        }
    }
#endif
    if (!jpegData || path.length == 0) {
        return;
    }

    NSFileManager* fman = [NSFileManager defaultManager];
    NSString* directory = [path stringByDeletingLastPathComponent];
    if (directory.length > 0 && ![fman fileExistsAtPath:directory]) {
        NSError* directoryError = nil;
        if (![fman createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            ErrLog(@"image cache write failed (mkdir): %@", directoryError);
            return;
        }
    }

    // O(1) deduplication via content hash index (no directory scan)
    NSString* contentHash = [jpegData MD5Hash];
    ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
    NSString* existingPath = [iman existingPathForContentHash:contentHash];

    if (existingPath && ![existingPath isEqualToString:path]) {
        [fman removeItemAtPath:path error:nil];
        if ([fman linkItemAtPath:existingPath toPath:path error:nil]) {
            return;
        }
    }

    NSError* writeError = nil;
    if (![jpegData writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
        ErrLog(@"image cache write failed: %@", writeError);
        return;
    }
    [iman registerContentHash:contentHash forPath:path];
}

- (NSMutableOrderedSet<NSNumber*>*)_scaledVariantSizes
{
    NSMutableOrderedSet<NSNumber*>* scaledSizes = [NSMutableOrderedSet orderedSetWithArray:@[@(56), @(60), @(72), @(320)]];
    NSNumber* requestedSize = @(self.size);
    if (![scaledSizes containsObject:requestedSize]) {
        [scaledSizes addObject:requestedSize];
    }
    return scaledSizes;
}

- (IC_IMAGE*)_scaledOutputImageFromImage:(IC_IMAGE*)image size:(NSInteger)size
{
    NSInteger imageSize = size * [ImageCacheManager scalingFactor];
    CGImageRef scaledRef = CreateSquaredScaledCGImageFromCGImage([image CGImage], imageSize);
    if (scaledRef) {
        IC_IMAGE* thumb = [[IC_IMAGE alloc] initWithCGImage:scaledRef];
        CGImageRelease(scaledRef);
        return (self.grayscale) ? [ImageCacheManager grayscaleImageForImage:thumb] : thumb;
    }

    return (self.grayscale) ? [ImageCacheManager grayscaleImageForImage:image] : image;
}

- (IC_IMAGE*)_persistScaledVariantsFromSourceImage:(IC_IMAGE*)image
{
    if (!image) {
        return nil;
    }

    IC_IMAGE* requestedImage = nil;
    for (NSNumber* scaledSizeNumber in [self _scaledVariantSizes]) {
        NSInteger size = [scaledSizeNumber integerValue];
        NSURL* scaledFileURL = [ImageCacheManager fileURLToCachedImageForImageURL:self.url size:size grayscale:self.grayscale];
        NSString* scaledPath = [scaledFileURL path];

        IC_IMAGE* outputImage = [self _scaledOutputImageFromImage:image size:size];
        [self _writeJPGImage:outputImage toFile:scaledPath];
        AddSkipBackupAttributeToFile(scaledPath);

        if (size == self.size) {
            requestedImage = outputImage;
        }
    }

    if (!requestedImage) {
        NSString* localPath = [[ImageCacheManager fileURLToCachedImageForImageURL:self.url size:self.size grayscale:self.grayscale] path];
        requestedImage = [self _scaledOutputImageFromImage:image size:self.size];
        [self _writeJPGImage:requestedImage toFile:localPath];
        AddSkipBackupAttributeToFile(localPath);
    }

    return requestedImage;
}

- (IC_IMAGE*)_loadBestCachedVariantImage
{
    for (NSNumber* scaledSizeNumber in [self _scaledVariantSizes]) {
        NSInteger size = [scaledSizeNumber integerValue];
        NSURL* scaledFileURL = [ImageCacheManager fileURLToCachedImageForImageURL:self.url size:size grayscale:self.grayscale];
        NSString* scaledPath = [scaledFileURL path];
        if (![[NSFileManager defaultManager] fileExistsAtPath:scaledPath]) {
            continue;
        }

        IC_IMAGE* image = [[IC_IMAGE alloc] initWithContentsOfFile:scaledPath];
        if (image) {
            return image;
        }
    }
    return nil;
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
            [[ImageCacheManager sharedImageCacheManager] saveContentHashIndex];
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
    (void)scaledSize;
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
    
    // If the exact size is missing, reuse any already cached variant and derive all sizes locally.
    image = [self _loadBestCachedVariantImage];
    if (image && ![self isCancelled]) {
        IC_IMAGE* requestedImage = [self _persistScaledVariantsFromSourceImage:image];
        [[ImageCacheManager sharedImageCacheManager] saveContentHashIndex];
        [self _cacheImage:requestedImage forKey:cacheKey];
        [self _sendCompletionBlockImage:requestedImage error:nil];
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
        IC_IMAGE* requestedImage = [self _persistScaledVariantsFromSourceImage:image];

        // Persist content hash index after writing all sizes
        [[ImageCacheManager sharedImageCacheManager] saveContentHashIndex];

        [self _cacheImage:requestedImage forKey:cacheKey];
        [self _sendCompletionBlockImage:requestedImage error:nil];
        return;
    }


    [self _sendCompletionBlockImage:nil error:error];
}

- (void) main
{
    @autoreleasepool {

        if ([self isCancelled]) {
            return;
        }

        if (!self.url) {
            [self _sendCompletionBlockImage:nil error:nil];
            return;
        }
        
        NSInteger scaledSize = self.size*[ImageCacheManager scalingFactor];
        NSString* cacheKey = [ImageCacheManager cacheKeyWithURL:self.url size:self.size grayscale:self.grayscale];

        IC_IMAGE* cachedImage = [[ImageCacheManager sharedImageCacheManager] cachedImageForKey:cacheKey];
        if (cachedImage) {
            [self _sendCompletionBlockImage:cachedImage error:nil];
            return;
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
