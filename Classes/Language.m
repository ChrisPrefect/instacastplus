//
//  Language.m
//  Instacast
//
//  Created by Devendra Kamal on 17/09/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import "Language.h"
#import "Foundation+Localization.h"

@implementation Language

static NSBundle *bundle = nil;

+(void)initialize
{
    NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];
    NSArray* languages = [defs objectForKey:@"AppleLanguages"];
    NSString *current = [languages objectAtIndex:0];
    [self setLanguage:current];
}

+(void)setLanguage:(NSString *)language
{
    NSString *path = [[ NSBundle mainBundle ] pathForResource:language ofType:@"lproj"];
    bundle = [NSBundle bundleWithPath:path];

    // Update mainBundle preferred localization so .ls works immediately
    [[NSBundle mainBundle] vm_setPreferredLocalizations:@[language]];
}

+(NSString *)get:(NSString *)key alter:(NSString *)alternate
{
    return [bundle localizedStringForKey:key value:alternate table:nil];
}




@end
