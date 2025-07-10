//
//  SkipTimeCell.h
//  Instacast
//
//  Created by DevD on 04/07/25.
//  Copyright © 2025 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SkipTimeCell : UITableViewCell

@property (nonatomic, weak) IBOutlet UILabel* titleLbl;
@property (nonatomic, weak) IBOutlet UITextField* timeTF;
@property (nonatomic, weak) IBOutlet UILabel* secondsLbl;
@property (nonatomic, weak) IBOutlet UIStepper* stepperView;

@end



NS_ASSUME_NONNULL_END
