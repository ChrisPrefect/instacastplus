//
//  ChaptersTableViewCell.m
//  Instacast
//
//  Created by Martin Hering on 31.05.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import "ChaptersTableViewCell.h"

static CGFloat const kChapterTitleFontSize = 16.0f;

@interface ChaptersTableViewCell ()
@property (nonatomic, readwrite, strong) UILabel* numLabel;
@property (nonatomic, readwrite, strong) UILabel* timeLabel;
@property (nonatomic, readwrite, strong) UIImageView* currentIndicatorImageView;
@property (nonatomic, readwrite, strong) UIButton* linkButton;
@property (nonatomic, readwrite, strong) UIProgressView* progressView;
@end

@implementation ChaptersTableViewCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self)
    {
        self.selectedBackgroundView = [[UIView alloc] init];
        
        self.textLabel.font = [UIFont systemFontOfSize:ICFontSize(kChapterTitleFontSize)];
        self.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        self.textLabel.numberOfLines = 20;
        
        // Initialization code.
		_numLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_numLabel.font = [UIFont systemFontOfSize:ICFontSize(13.f)];
        _numLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
		[self.contentView addSubview:_numLabel];
		
		_timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_timeLabel.font = [UIFont systemFontOfSize:ICFontSize(15.f)];
		_timeLabel.textAlignment = NSTextAlignmentRight;
        _timeLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
		[self.contentView addSubview:_timeLabel];

        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressView.hidden = YES;
        _progressView.trackTintColor = [UIColor clearColor];
        _progressView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_progressView];

        _linkButton = [[UIButton alloc] initWithFrame:CGRectZero];
        [_linkButton setImage:[[UIImage imageNamed:@"Player Chapter Link"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                     forState:UIControlStateNormal];
        _linkButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        _linkButton.imageEdgeInsets = UIEdgeInsetsMake(0, 5, 0, 0);
        _linkButton.hidden = YES;
        [self.contentView addSubview:_linkButton];
        
        // ✅ Add Auto Layout Constraints for ProgressView
        [NSLayoutConstraint activateConstraints:@[
            [_progressView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:-1],
            [_progressView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-1],
            [_progressView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:0],
            [_progressView.heightAnchor constraintEqualToConstant:2] // Ensures 1pt height
        ]];
    }
    return self;
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    
    [super setSelected:selected animated:animated];
    
    // Configure the view for the selected state.
    
    if (!selected && animated) {
        [self perform:^(id sender) {
            [self.linkButton setImage:nil forState:UIControlStateHighlighted];
        } afterDelay:0.3];
    }
}

- (void) setObjectValue:(CDChapter *)objectValue
{
    if (_objectValue != objectValue) {
        _objectValue = objectValue;
        
        self.textLabel.text = objectValue.title;
        
        self.numLabel.text = [NSString stringWithFormat:@"%ld.", (long)objectValue.index+1];
        self.linkButton.hidden = !objectValue.linkURL;
        self.linkButton.tag = objectValue.index;
        
        NSInteger time = objectValue.duration;
        if (time > 3600) {
            self.timeLabel.text = [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)time/3600, (long)(time/60)%60, (long)time%60];
        } else {
            self.timeLabel.text = [NSString stringWithFormat:@"%ld:%02ld", (long)time/60, (long)time%60];
        }

    }
}

- (void) layoutSubviews
{
	[super layoutSubviews];

    // Update fonts for dynamic font size scaling
    self.textLabel.font = [UIFont systemFontOfSize:ICFontSize(kChapterTitleFontSize)];
    self.numLabel.font = [UIFont systemFontOfSize:ICFontSize(13.f)];
    self.timeLabel.font = [UIFont systemFontOfSize:ICFontSize(15.f)];

    self.selectedBackgroundView.backgroundColor = ICTableSelectedBackgroundColor;
	
	CGRect b = self.bounds;
    CGFloat scale = [ICAppearanceManager sharedManager].fontSizeScale;
    CGFloat numWidth = 20 * scale;
    CGFloat numHeight = 17 * scale;
    CGFloat timeWidth = 55 * scale;
    CGFloat timeHeight = numHeight;
    CGFloat timeReserve = (80 - 55) + timeWidth; // padding + scaled time width

    CGSize titleSize = [self.textLabel.attributedText boundingRectWithSize:CGSizeMake(CGRectGetWidth(b)-15-numWidth-15-timeReserve-15, 200)
                                                                   options:NSStringDrawingUsesLineFragmentOrigin
                                                                   context:nil].size;
    IC_SIZE_INTEGRAL(titleSize);

	CGRect titleRect = CGRectMake(15+numWidth+15, 11, CGRectGetWidth(b)-15-numWidth-15-timeReserve-15, titleSize.height);
	self.textLabel.frame = [self.contentView convertRect:titleRect fromView:self];

	CGRect numRect = CGRectMake(15, 12.f, numWidth, numHeight);
	self.numLabel.frame = [self.contentView convertRect:numRect fromView:self];

	CGRect timeRect = CGRectMake(CGRectGetWidth(b)-15-timeWidth, 12.f, timeWidth, timeHeight);
	self.timeLabel.frame = [self.contentView convertRect:timeRect fromView:self];

    self.linkButton.frame = CGRectMake(CGRectGetWidth(b)-100, 0, 100, CGRectGetHeight(b));
    

//    CGFloat progressY = CGRectGetHeight(b) - 2; // Ensures 1pt height
//    self.progressView.frame = CGRectMake(-1, progressY, CGRectGetWidth(b) + 2, 2);
//    self.progressView.layer.masksToBounds = YES;

}

+ (CGFloat) proposedHeightWithTitle:(NSString*)title tableBounds:(CGRect)tableBounds
{
    if (!title) {
        return 44;
    }
    
    CGFloat width = CGRectGetWidth(tableBounds);
    CGFloat scale = [ICAppearanceManager sharedManager].fontSizeScale;
    CGFloat numWidth = 20 * scale;
    CGFloat timeWidth = 55 * scale;
    CGFloat timeReserve = (80 - 55) + timeWidth;
    UIFont* font = [UIFont systemFontOfSize:ICFontSize(kChapterTitleFontSize)];

    NSAttributedString* attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName : font}];

    CGSize titleSize = [attributedTitle boundingRectWithSize:CGSizeMake(width-15-numWidth-15-timeReserve-15, 200)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                     context:nil].size;
    IC_SIZE_INTEGRAL(titleSize);
    
    return titleSize.height + 22;
}


- (UITableView*) _tableView
{
    UIView* view = self.superview;
    
    while (view && ![view isKindOfClass:[UITableView class]]) {
        view = view.superview;
    }
    
    return (UITableView*)view;
}

@end
