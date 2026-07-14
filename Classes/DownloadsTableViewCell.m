//
//  DownloadsTableViewCell.m
//  Instacast
//
//  Created by Martin Hering on 04.09.12.
//
//

#import "DownloadsTableViewCell.h"
#import "EpisodePlayComboButton.h"


@interface DownloadsTableViewCell ()
@property (nonatomic, readwrite, strong) UIProgressView* progressView;
@property (nonatomic, readwrite, strong) UILabel* sizeLabel;
@property (nonatomic, readwrite, strong) UILabel* timeLabel;

@property (nonatomic, strong, readwrite) EpisodePlayComboButton* playAccessoryButton;
@end


@implementation DownloadsTableViewCell

- (void)setShowsErrorStatus:(BOOL)showsErrorStatus
{
    if (_showsErrorStatus == showsErrorStatus) {
        return;
    }
    _showsErrorStatus = showsErrorStatus;
    self.progressView.hidden = showsErrorStatus;
    self.timeLabel.hidden = showsErrorStatus;
    if (showsErrorStatus) {
        self.sizeLabel.numberOfLines = 0;
        self.sizeLabel.lineBreakMode = NSLineBreakByWordWrapping;
    } else {
        self.sizeLabel.numberOfLines = 1;
        self.sizeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    [self setNeedsLayout];
}

- (void)setRightContentAccessoryView:(UIView *)rightContentAccessoryView {
    if (_rightContentAccessoryView == rightContentAccessoryView) {
        return;
    }
    [_rightContentAccessoryView removeFromSuperview];
    _rightContentAccessoryView = rightContentAccessoryView;
    if (_rightContentAccessoryView) {
        [self.contentView addSubview:_rightContentAccessoryView];
    }
    [self setNeedsLayout];
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        
        self.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
        
        // Initialization code.
		_progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
		[self.contentView addSubview:_progressView];
		
		_sizeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_sizeLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];
        _sizeLabel.numberOfLines = 1;
        _sizeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
		[self.contentView addSubview:_sizeLabel];
		
		_timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_timeLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];
		_timeLabel.textAlignment = NSTextAlignmentRight;
        _timeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
		[self.contentView addSubview:_timeLabel];
		
        _playAccessoryButton = [EpisodePlayComboButton button];
        _playAccessoryButton.frame = CGRectMake(0, 0, 44, 44);
        _playAccessoryButton.comboState = kEpisodePlayButtonComboStateHolding;
        [self.contentView addSubview:_playAccessoryButton];
        
    }
    return self;
}


- (void) layoutSubviews
{
	[super layoutSubviews];

    // Update fonts for dynamic font size scaling
    self.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
    self.sizeLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];
    self.timeLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];

    self.textLabel.textColor = ICTextColor;
    self.sizeLabel.textColor = self.showsErrorStatus ? UIColor.systemOrangeColor : ICMutedTextColor;
    self.timeLabel.textColor = ICMutedTextColor;
	
    CGRect bounds = self.contentView.bounds;
	CGRect textLabelRect = self.textLabel.frame;
    CGRect imageViewRect = CGRectMake(10, 7, 56, 56);
    BOOL showsPlayButton = (self.playAccessoryButton.superview == self.contentView);
    BOOL showsRightContentAccessory = (self.rightContentAccessoryView.superview == self.contentView);
    CGFloat rightContentAccessoryWidth = showsRightContentAccessory
        ? MAX(44, ceilf(self.rightContentAccessoryView.intrinsicContentSize.width))
        : 0;
    

    self.imageView.frame = imageViewRect;
    CGFloat textLeft = CGRectGetMaxX(imageViewRect) + (showsPlayButton ? 25 : 10);
    CGFloat rightInset = showsPlayButton ? 44 : (showsRightContentAccessory ? rightContentAccessoryWidth + 5 : ((self.accessoryView != nil) ? 49 : 0));
	CGFloat width = MAX(0, CGRectGetWidth(bounds)-textLeft-rightInset);
    
    textLabelRect.origin.x = textLeft;
	textLabelRect.origin.y = 10;
    textLabelRect.size.width = width;
    
	self.textLabel.frame = textLabelRect;
	

    BOOL multilineStatus = self.sizeLabel.numberOfLines > 1;
    if (self.showsErrorStatus) {
        self.progressView.hidden = YES;
        self.timeLabel.hidden = YES;
        CGFloat statusTop = CGRectGetMaxY(textLabelRect) + 3;
        self.sizeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect),
                                          statusTop,
                                          width,
                                          MAX(0, CGRectGetHeight(bounds) - statusTop - 7));
    }
	else if (multilineStatus) {
        CGFloat timeWidth = ([self.timeLabel.text length] == 0) ? 0 : 54;
        CGFloat spacing = (timeWidth > 0) ? 6 : 0;
        CGFloat progressWidth = MAX(0, width - ((rightContentAccessoryWidth > 0) ? 0 : (timeWidth + spacing)));
        self.progressView.frame = CGRectMake(CGRectGetMinX(textLabelRect), 34, progressWidth, 10);
        if (timeWidth > 0 && rightContentAccessoryWidth > 0) {
            self.timeLabel.frame = CGRectMake(CGRectGetMaxX(bounds) - rightContentAccessoryWidth - 5, 47, rightContentAccessoryWidth, 16);
            self.timeLabel.hidden = NO;
        } else if (timeWidth > 0) {
            self.timeLabel.frame = CGRectMake(CGRectGetMaxX(self.progressView.frame) + 6, 30, timeWidth, 16);
            self.timeLabel.hidden = NO;
        } else {
            self.timeLabel.hidden = YES;
        }
        // Use the label's actual line height so both rows share the same baseline.
        // Previously the hard-coded 13pt didn't match the 11pt system font's intrinsic
        // line height (~13.2pt), which put the time label ~2pt above the first line.
        CGFloat lineH = ceilf(self.sizeLabel.font.lineHeight);
        self.sizeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect), 47, width, lineH * 2);
    } else if ([self.timeLabel.text length] == 0) {
        self.progressView.frame = CGRectMake(CGRectGetMinX(textLabelRect), 34, width, 10);
		self.sizeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect), 47, width, 13);
		self.timeLabel.hidden = YES;
	} else {
        self.progressView.frame = CGRectMake(CGRectGetMinX(textLabelRect), 34, width, 10);
		self.sizeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect), 47, width/2+20, 13);
		self.timeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect)+floorf(width/2)+20, 47, floorf(width/2)-20, 13);
		self.timeLabel.hidden = NO;
	}
	
    self.playAccessoryButton.frame = CGRectMake(CGRectGetMaxX(bounds)-44, floorf((CGRectGetHeight(bounds)-44)/2), 44, 44);
    if (showsRightContentAccessory) {
        self.rightContentAccessoryView.frame = CGRectMake(CGRectGetMaxX(bounds)-rightContentAccessoryWidth-5, 4, rightContentAccessoryWidth, 44);
    }
}


@end
