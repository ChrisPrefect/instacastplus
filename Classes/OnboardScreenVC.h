//
//  OnboardScreenVC.h
//  Instacast
//
//  Created by Devendra Kamal on 15/08/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class OnboardScreenVC;
@protocol OnboardScreenVCDelegate <NSObject>
- (void) plusButtonPressDelegateMethod: (OnboardScreenVC *) sender;
@end

@interface OnboardScreenVC : UIViewController
{
    NSArray* imageArray;
    NSArray* titleArray;
    NSArray* descArray;
}
@property (nonatomic, weak) IBOutlet UIView* shadowView;
@property (nonatomic, weak) IBOutlet UIImageView* arrowImage;
@property (nonatomic, weak) IBOutlet UILabel* descLabel;
@property (nonatomic, weak) IBOutlet UIButton* plusBtn;

@property (nonatomic, weak) id <OnboardScreenVCDelegate> delegate;


@end



NS_ASSUME_NONNULL_END
