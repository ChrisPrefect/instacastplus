//
//  PlayerSpeedButton.h
//  Instacast
//
//  Created by Martin Hering on 10.01.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "PlaybackDefines.h"

@interface PlayerSpeedButton : UIButton

+ (NSArray<NSNumber*>*) allSpeedControlsOrdered;
+ (NSArray<NSNumber*>*) allSpeedControlsDescending;
+ (NSArray<NSNumber*>*) enabledSpeedControls;
+ (PlaybackSpeedControl) nextEnabledSpeedAfter:(PlaybackSpeedControl)current;
+ (NSString*) titleForSpeedControl:(PlaybackSpeedControl)control;

@end
