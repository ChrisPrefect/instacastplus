//
//  InputSampleViewController.h
//  Instacast
//
//  Created by Vinh Huynh on 29/12/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SettingsValuesTableViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SettingInputViewController : SettingsValuesTableViewController
@property (nonatomic, strong) NSMutableArray<NSString *> *inputValues;
+ (SettingInputViewController*) inputSampleViewController;

@end

NS_ASSUME_NONNULL_END
