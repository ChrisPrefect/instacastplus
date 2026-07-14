//
//  UIActions.m
//  Instacast
//
//  Created by Martin Hering on 23.09.11.
//  Copyright (c) 2011 Vemedio. All rights reserved.
//

#import "UtilityFunctions.h"
#import <CommonCrypto/CommonDigest.h>

void AddSkipBackupAttributeToFile(NSString* path)
{
    if (!path) {
        return ;
        
    }
    NSURL* url = [NSURL fileURLWithPath:path];
    
    NSError *error = nil;
    [url setResourceValue:@(YES) forKey: NSURLIsExcludedFromBackupKey error:&error];
    if (error) {
        ErrLog(@"error excluding file from backup: %@", error);
    }
}

NSString* ICRedactedURLStringForLogging(NSString* URLString)
{
    NSString* source = [URLString isKindOfClass:[NSString class]] ? URLString : @"";
    const char* input = source.UTF8String ?: "";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input, (CC_LONG)strlen(input), digest);
    NSMutableString* fingerprint = [NSMutableString stringWithCapacity:16];
    for (NSUInteger index = 0; index < 8; index++) {
        [fingerprint appendFormat:@"%02x", digest[index]];
    }

    NSURLComponents* components = [NSURLComponents componentsWithString:source];
    components.user = nil;
    components.password = nil;
    components.path = @"";
    components.query = nil;
    components.fragment = nil;

    NSString* origin = nil;
    if (components.scheme.length > 0 && components.host.length > 0) {
        components.scheme = components.scheme.lowercaseString;
        components.host = components.host.lowercaseString;
        origin = components.string;
    } else if ([components.scheme.lowercaseString isEqualToString:@"file"]) {
        origin = @"file://local";
    } else {
        origin = @"invalid-url";
    }
    return [NSString stringWithFormat:@"%@/<redacted>#%@", origin, fingerprint];
}

