//
//  main.m
//  Instacast
//
//  Created by Martin Hering on 22.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "InstacastAppDelegate.h"
#import "Application.h"

int main(int argc, char *argv[]) {
    
    @autoreleasepool {
        NSString* timerClass = NSStringFromClass([Application class]);
        NSString* appDelegateClass = NSStringFromClass([InstacastAppDelegate class]);
        int retVal = UIApplicationMain(argc, argv, timerClass, appDelegateClass);
        return retVal;
    }
}
