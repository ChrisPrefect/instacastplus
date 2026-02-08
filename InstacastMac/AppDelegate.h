//
//  AppDelegate.h
//  InstacastMac
//
//  Created by Vinh Huynh on 14/11/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (readonly, strong) NSPersistentContainer *persistentContainer;


@end

