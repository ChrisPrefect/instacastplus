//
//  UITableViewController+Settings.h
//  Instacast
//
//  Created by Martin Hering on 22.06.13.
//
//

#import <UIKit/UIKit.h>
#import "SkipTimeCell.h"

@interface UITableViewController (Settings)
- (UITableViewCell*) standardCellWithClass:(Class)cellClass;
- (UITableViewCell*) standardCell;
- (UITableViewCell*) switchCell;
- (UITableViewCell*) textInputCell;
- (UITableViewCell*) detailCell;
- (UITableViewCell*) detailStepperCell;
- (UITableViewCell*) resetCell;
- (UITableViewCell*) buttonCell;
- (SkipTimeCell*) skipTimeCellByDev;

- (UITableViewCell*) textCell;
- (CGFloat)heightForTextCellUsingText:(NSString*)text;
- (void)setupSettingsTableViewSpacing;
@end
