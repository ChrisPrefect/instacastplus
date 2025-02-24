//
//  ChooseThemeColorCell.m
//  Instacast
//
//  Created by Martin Hering on 02.09.13.
//
//

#import "ChooseThemeColorCell.h"

@interface ChooseThemeColorCell ()
@property (nonatomic, strong, readwrite) UIView* colorView;
@end

@implementation ChooseThemeColorCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // Initialization code
        self.selectedBackgroundView = [[UIView alloc] init];

        _colorView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
        [self.contentView addSubview:_colorView];
        
        _disclosureView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"Toolbar Disclosure"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        [self.contentView addSubview:_disclosureView];
    }
    return self;
}

- (void) layoutSubviews
{
    [super layoutSubviews];
    
    self.backgroundColor = ICGroupCellBackgroundColor;
    self.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    self.textLabel.textColor = ICTextColor;
    
    CGRect b = self.contentView.bounds;
    
    _colorView.frame = CGRectMake(CGRectGetWidth(b)-30-8-20, 7, 30, 30);
    
    CGRect textLabelFrame = self.textLabel.frame;
    textLabelFrame.size.width = CGRectGetWidth(b)-CGRectGetMinX(textLabelFrame)-30-10-25;
    self.textLabel.frame = textLabelFrame;
    
    _disclosureView.frame = CGRectMake(CGRectGetWidth(b)-8-10, 15, 8, 14);

}

@end
