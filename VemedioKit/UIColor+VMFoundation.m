//
//  UIColor+VMFoundation.m
//  Instacast
//
//  Created by Martin Hering on 28.07.14.
//
//

#import "UIColor+VMFoundation.h"
#import <math.h>

static UIColor* ICColorFromStoredHex(NSString* hexString)
{
    if (![hexString isKindOfClass:[NSString class]]) {
        return nil;
    }

    NSString* normalized = [[hexString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if ([normalized hasPrefix:@"#"]) {
        normalized = [normalized substringFromIndex:1];
    }
    if (normalized.length != 6) {
        return nil;
    }

    NSScanner* scanner = [NSScanner scannerWithString:normalized];
    unsigned int rgbValue = 0;
    if (![scanner scanHexInt:&rgbValue] || !scanner.isAtEnd) {
        return nil;
    }
    return [UIColor colorWithRed:((rgbValue >> 16) & 0xFF) / 255.0
                           green:((rgbValue >> 8) & 0xFF) / 255.0
                            blue:(rgbValue & 0xFF) / 255.0
                           alpha:1.0];
}

static NSString* ICStoredHexFromColor(UIColor* color)
{
    if (![color isKindOfClass:[UIColor class]]) {
        return nil;
    }

    UIColor* resolvedColor = color;
    CGFloat red = 0;
    CGFloat green = 0;
    CGFloat blue = 0;
    CGFloat alpha = 0;
    if (![resolvedColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
        CGFloat white = 0;
        if (![resolvedColor getWhite:&white alpha:&alpha]) {
            return nil;
        }
        red = white;
        green = white;
        blue = white;
    }

    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lrint(MAX(0.0, MIN(1.0, red)) * 255.0),
            (int)lrint(MAX(0.0, MIN(1.0, green)) * 255.0),
            (int)lrint(MAX(0.0, MIN(1.0, blue)) * 255.0)];
}

@implementation UIColor (VMFoundation)

+ (UIColor*) mergedColorOfImage:(UIImage*)image
{
    CGImageRef rawImageRef = [image CGImage];
    
    // scale image to an one pixel image
    
    uint8_t  bitmapData[4];
    int bitmapByteCount;
    int bitmapBytesPerRow;
    int width = 1;
    int height = 1;
    
    bitmapBytesPerRow = (width * 4);
    bitmapByteCount = (bitmapBytesPerRow * height);
    memset(bitmapData, 0, bitmapByteCount);
    CGColorSpaceRef colorspace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate (bitmapData,width,height,8,bitmapBytesPerRow,
                                                  colorspace,kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorspace);
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), rawImageRef);
    CGContextRelease(context);
    UIColor* averageColor = [UIColor colorWithRed:bitmapData[2] / 255.0f
                                              green:bitmapData[1] / 255.0f
                                               blue:bitmapData[0] / 255.0f
                                              alpha:1];
    
    return averageColor;
}

- (UIColor*) colorByCappingBrightnessAt:(float)cappedBrightness
{
    CGFloat hue, saturation, brightness, alpha;
    [self getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
    
    saturation = MIN(saturation+0.3f, 1.0f);
    if (cappedBrightness > 0.6f) {
        brightness = MIN(brightness, cappedBrightness);
    } else {
        brightness = MAX(cappedBrightness, brightness);
    }
    
    return [UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:alpha];
}

- (NSString*) hexString
{
    CGFloat r, g, b, a;
    [self getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%02X%02X%02X",
            (int)(r * 255.0f), (int)(g * 255.0f), (int)(b * 255.0f)];
}

+ (UIColor*) colorWithHexString:(NSString*)hex
{
    NSString *cString = [[hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];

    // String should be 6 or 8 characters
    if ([cString length] < 6) return [UIColor grayColor];

    // strip 0X if it appears
    if ([cString hasPrefix:@"0X"]) cString = [cString substringFromIndex:2];

    if ([cString length] != 6) return  [UIColor grayColor];

    // Separate into r, g, b substrings
    NSRange range;
    range.location = 0;
    range.length = 2;
    NSString *rString = [cString substringWithRange:range];

    range.location = 2;
    NSString *gString = [cString substringWithRange:range];

    range.location = 4;
    NSString *bString = [cString substringWithRange:range];

    // Scan values
    unsigned int r, g, b;
    [[NSScanner scannerWithString:rString] scanHexInt:&r];
    [[NSScanner scannerWithString:gString] scanHexInt:&g];
    [[NSScanner scannerWithString:bString] scanHexInt:&b];

    return [UIColor colorWithRed:((float) r / 255.0f)
                           green:((float) g / 255.0f)
                            blue:((float) b / 255.0f)
                           alpha:1.0f];
}

// Pure read. This runs from ICTintColor and therefore from cell layout — it must never
// write to NSUserDefaults. Canonicalisation and legacy cleanup happen once in
// +ic_normalizeStoredColorInDefaults:hexKey:legacyArchiveKey:.
+ (UIColor*)ic_colorFromDefaults:(NSUserDefaults*)defaults
                           hexKey:(NSString*)hexKey
                 legacyArchiveKey:(NSString*)legacyArchiveKey
{
    UIColor* color = ICColorFromStoredHex([defaults objectForKey:hexKey]);
    if (color) {
        return color;
    }

    id legacyObject = [defaults objectForKey:legacyArchiveKey];
    if (![legacyObject isKindOfClass:[NSData class]]) {
        return nil;
    }

    @try {
        NSError* error = nil;
        color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class]
                                                  fromData:(NSData*)legacyObject
                                                     error:&error];
        if (error) {
            color = nil;
        }
    }
    @catch (NSException* exception) {
        (void)exception;
        color = nil;
    }
    return color;
}

// One-shot migration: rewrites a non-canonical hex value and drops the legacy archive.
// Call at startup, not from drawing or layout code.
+ (void)ic_normalizeStoredColorInDefaults:(NSUserDefaults*)defaults
                                   hexKey:(NSString*)hexKey
                         legacyArchiveKey:(NSString*)legacyArchiveKey
{
    id storedHex = [defaults objectForKey:hexKey];
    UIColor* color = ICColorFromStoredHex(storedHex);
    if (color) {
        NSString* canonicalHex = ICStoredHexFromColor(color);
        if (canonicalHex && ![canonicalHex isEqualToString:storedHex]) {
            [defaults setObject:canonicalHex forKey:hexKey];
        }
        if ([defaults objectForKey:legacyArchiveKey]) {
            [defaults removeObjectForKey:legacyArchiveKey];
        }
        return;
    }
    if (storedHex) {
        [defaults removeObjectForKey:hexKey];
    }
    if (![defaults objectForKey:legacyArchiveKey]) {
        return;
    }

    color = [self ic_colorFromDefaults:defaults hexKey:hexKey legacyArchiveKey:legacyArchiveKey];
    [defaults removeObjectForKey:legacyArchiveKey];
    NSString* canonicalHex = ICStoredHexFromColor(color);
    if (canonicalHex) {
        [defaults setObject:canonicalHex forKey:hexKey];
    }
}

+ (NSString*)ic_colorHexFromDefaults:(NSUserDefaults*)defaults
                                hexKey:(NSString*)hexKey
                      legacyArchiveKey:(NSString*)legacyArchiveKey
{
    UIColor* color = [self ic_colorFromDefaults:defaults hexKey:hexKey legacyArchiveKey:legacyArchiveKey];
    return ICStoredHexFromColor(color);
}

+ (void)ic_setColor:(UIColor*)color
          inDefaults:(NSUserDefaults*)defaults
              hexKey:(NSString*)hexKey
    legacyArchiveKey:(NSString*)legacyArchiveKey
{
    NSString* canonicalHex = ICStoredHexFromColor(color);
    if (canonicalHex) {
        [defaults setObject:canonicalHex forKey:hexKey];
    }
    else {
        [defaults removeObjectForKey:hexKey];
    }
    [defaults removeObjectForKey:legacyArchiveKey];
}

+ (BOOL)ic_setColorHexString:(NSString*)hexString
                   inDefaults:(NSUserDefaults*)defaults
                       hexKey:(NSString*)hexKey
             legacyArchiveKey:(NSString*)legacyArchiveKey
{
    UIColor* color = ICColorFromStoredHex(hexString);
    if (!color) {
        return NO;
    }
    [self ic_setColor:color inDefaults:defaults hexKey:hexKey legacyArchiveKey:legacyArchiveKey];
    return YES;
}


@end
