//
//  SettingInputChapterController.h
//  Instacast
//
//  Created by Vinh Huynh on 12/1/25.
//  Copyright © 2025 Vemedio. All rights reserved.
//

#import "SettingsValuesTableViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SettingInputChapterController : SettingsValuesTableViewController
{
    NSString *chapterKey;
}
@property(nonatomic,retain) NSString *chapterKey;
+ (SettingInputChapterController*) inputSampleViewController;
@end

NS_ASSUME_NONNULL_END
