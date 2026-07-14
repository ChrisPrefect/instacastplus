//
//  UIColor+VMFoundation.h
//  Instacast
//
//  Created by Martin Hering on 28.07.14.
//
//

#import <UIKit/UIKit.h>

@interface UIColor (VMFoundation)
+ (UIColor*) mergedColorOfImage:(UIImage*)image;
- (UIColor*) colorByCappingBrightnessAt:(float)brightness;
+ (UIColor*) colorWithHexString:(NSString*)hex;
- (NSString*) hexString;
+ (UIColor*)ic_colorFromDefaults:(NSUserDefaults*)defaults
                           hexKey:(NSString*)hexKey
                 legacyArchiveKey:(NSString*)legacyArchiveKey;
+ (NSString*)ic_colorHexFromDefaults:(NSUserDefaults*)defaults
                                hexKey:(NSString*)hexKey
                      legacyArchiveKey:(NSString*)legacyArchiveKey;
+ (void)ic_setColor:(UIColor*)color
          inDefaults:(NSUserDefaults*)defaults
              hexKey:(NSString*)hexKey
    legacyArchiveKey:(NSString*)legacyArchiveKey;
+ (BOOL)ic_setColorHexString:(NSString*)hexString
                   inDefaults:(NSUserDefaults*)defaults
                       hexKey:(NSString*)hexKey
             legacyArchiveKey:(NSString*)legacyArchiveKey;
@end
