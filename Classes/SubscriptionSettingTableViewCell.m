//
//  SubscriptionSettingTableViewCell.m
//  Instacast
//
//  Created by Martin Hering on 02.09.13.
//
//

#import "SubscriptionSettingTableViewCell.h"

@interface SubscriptionSettingTableViewCell ()
@property (nonatomic, strong, readwrite) UISwitch* switchControl;
@end

@implementation SubscriptionSettingTableViewCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // Initialization code
        self.selectedBackgroundView = [[UIView alloc] init];

        _switchControl = [[UISwitch alloc] initWithFrame:CGRectMake(0, 0, 50, 30)];
        [self.contentView addSubview:_switchControl];
        
        _disclosureView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"Toolbar Disclosure"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        [self.contentView addSubview:_disclosureView];
    }
    return self;
}

- (void) prepareForReuse
{
    [super prepareForReuse];
    
    NSArray* actions = [self.switchControl actionsForTarget:[[self.switchControl allTargets] anyObject] forControlEvent:UIControlEventValueChanged];
    for(NSString* action in actions) {
        [self.switchControl removeTarget:self action:NSSelectorFromString(action) forControlEvents:UIControlEventValueChanged];
    }
}

- (void) layoutSubviews
{
    [super layoutSubviews];
    
    self.backgroundColor = ICGroupCellBackgroundColor;
    self.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    self.textLabel.textColor = ICTextColor;
    
    CGRect b = self.contentView.bounds;
    
    _disclosureView.frame = CGRectMake(CGRectGetWidth(b)-8-10, 15, 8, 14);
    _switchControl.frame = CGRectMake(CGRectGetMinX(_disclosureView.frame)-50-16, 7, 50, 30);

    CGRect textLabelFrame = self.textLabel.frame;
    textLabelFrame.size.width = CGRectGetMinX(_switchControl.frame)-CGRectGetMinX(textLabelFrame)-8;
    self.textLabel.frame = textLabelFrame;

}

@end
