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
    self.sizeLabel.textColor = ICMutedTextColor;
    self.timeLabel.textColor = ICMutedTextColor;
	
    CGRect bounds = self.contentView.bounds;
	CGRect textLabelRect = self.textLabel.frame;
    CGRect imageViewRect = CGRectMake(10, 7, 56, 56);
    

    self.imageView.frame = imageViewRect;
    CGFloat accessoryReservedWidth = (self.accessoryType != UITableViewCellAccessoryNone || self.accessoryView != nil) ? 34 : 0;
	CGFloat rightPadding = ((self.playAccessoryButton.superview != nil) ? 55 : 15) + accessoryReservedWidth;
	CGFloat width = CGRectGetWidth(bounds)-CGRectGetMaxX(imageViewRect)-rightPadding;
    
    textLabelRect.origin.x = CGRectGetMaxX(imageViewRect) + 10;
	textLabelRect.origin.y = 10;
    textLabelRect.size.width = width;
    
	self.textLabel.frame = textLabelRect;
	

	self.progressView.frame = CGRectMake(CGRectGetMinX(textLabelRect), 34, width, 10);
    
    BOOL multilineStatus = self.sizeLabel.numberOfLines > 1;
	if (multilineStatus) {
        // Use the label's actual line height so both rows share the same baseline.
        // Previously the hard-coded 13pt didn't match the 11pt system font's intrinsic
        // line height (~13.2pt), which put the time label ~2pt above the first line.
        CGFloat lineH = ceilf(self.sizeLabel.font.lineHeight);
        CGFloat timeWidth = ([self.timeLabel.text length] == 0) ? 0 : 54;
        CGFloat spacing = (timeWidth > 0) ? 6 : 0;
        CGFloat sizeWidth = width - timeWidth - spacing;
        self.sizeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect), 43, sizeWidth, lineH * 2);
        if (timeWidth > 0) {
            // Match the first line of sizeLabel exactly: same y, same height, same font.
            self.timeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect) + width - timeWidth, 43, timeWidth, lineH);
            self.timeLabel.hidden = NO;
        } else {
            self.timeLabel.hidden = YES;
        }
    } else if ([self.timeLabel.text length] == 0) {
		self.sizeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect), 47, width, 13);
		self.timeLabel.hidden = YES;
	} else {
		self.sizeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect), 47, width/2+20, 13);
		self.timeLabel.frame = CGRectMake(CGRectGetMinX(textLabelRect)+floorf(width/2)+20, 47, floorf(width/2)-20, 13);
		self.timeLabel.hidden = NO;
	}
	
    self.playAccessoryButton.frame = CGRectMake(CGRectGetMaxX(bounds)-44, floorf((CGRectGetHeight(bounds)-44)/2), 44, 44);
}


@end
