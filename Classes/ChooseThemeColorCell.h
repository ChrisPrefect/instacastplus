//
//  ChooseThemeColorCell.h
//  Instacast
//
//  Created by Martin Hering on 02.09.13.
//
//

#import <UIKit/UIKit.h>

@interface ChooseThemeColorCell : UITableViewCell

@property (nonatomic, strong, readonly) UIView* colorView;
@property (nonatomic, strong, readonly) UIImageView* disclosureView;
@property (nonatomic, strong, readonly) UITextField* textField;
@property (nonatomic, strong, readonly) UIView* tfView;
@end
