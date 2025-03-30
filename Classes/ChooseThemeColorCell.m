//
//  ChooseThemeColorCell.m
//  Instacast
//
//  Created by Martin Hering on 02.09.13.
//
//

#import "ChooseThemeColorCell.h"

@interface ChooseThemeColorCell () <UITextFieldDelegate>
@property (nonatomic, strong, readwrite) UIView* colorView;
@end

@implementation ChooseThemeColorCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // Initialization code
        self.selectedBackgroundView = [[UIView alloc] init];
        
        if (@available(iOS 14.0, *)) {
            _colorView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
            [self.contentView addSubview:_colorView];
            
            _disclosureView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"Toolbar Disclosure"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            [self.contentView addSubview:_disclosureView];
        }
        else
        {
            _tfView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 40)];
            [self.contentView addSubview:_tfView];
            
            _textField = [[UITextField alloc] initWithFrame:CGRectMake(5, 0, 90, 40)];
            
            // Set properties
            _textField.placeholder = @"#000000";
            _textField.font = [UIFont systemFontOfSize:15];
            _textField.backgroundColor = [UIColor clearColor];
            _textField.returnKeyType = UIReturnKeyDone;
            _tfView.layer.borderWidth = 0.5;
            _tfView.layer.cornerRadius = 3.0;
            _textField.delegate = self;
            if ([ICAppearanceManager sharedManager].nightSettingMode)
            {
                _textField.textColor = [UIColor lightGrayColor];
                _tfView.layer.borderColor = [UIColor lightGrayColor].CGColor;
            }
            else
            {
                _textField.textColor = [UIColor darkGrayColor];
                _tfView.layer.borderColor = [UIColor darkGrayColor].CGColor;
            }
            [_tfView addSubview:_textField];
        }
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
    if (@available(iOS 14.0, *)) {
        _colorView.frame = CGRectMake(CGRectGetWidth(b)-30-8-20, 7, 30, 30);
        
        CGRect textLabelFrame = self.textLabel.frame;
        textLabelFrame.size.width = CGRectGetWidth(b)-CGRectGetMinX(textLabelFrame)-30-10-25;
        self.textLabel.frame = textLabelFrame;
        
        _disclosureView.frame = CGRectMake(CGRectGetWidth(b)-8-10, 15, 8, 14);
    }
    else
    {
        _tfView.frame = CGRectMake(CGRectGetWidth(b)-100-20, 5, 100, 40);
    }
}


@end
