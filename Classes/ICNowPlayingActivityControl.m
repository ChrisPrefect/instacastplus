//
//  MainSidebarPlayerControl.m
//  Instacast
//
//  Created by Martin Hering on 10.08.13.
//
//

#import "ICNowPlayingActivityControl.h"
#import "MarqueeLabel2.h"

@interface ICNowPlayingActivityControl ()
@property (nonatomic, strong) UIImageView* imageView;
@property (nonatomic, strong, readwrite) UILabel* label1;
@property (nonatomic, strong, readwrite) UILabel* label2;
@property (nonatomic, strong, readwrite) UILabel* label3;
@property (nonatomic, strong, readwrite) UIButton* rightButton;
@property (nonatomic, strong, readwrite) UIProgressView* progressView;
@end


@implementation ICNowPlayingActivityControl {
    UIColor* _normalBackgroundColor;
}

- (id)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {

        self.clipsToBounds = YES;

        // Labels: 34px vom linken Rand, +3px top padding (11 statt 8)
        _label1 = [[UILabel alloc] initWithFrame:CGRectMake(34, 0, CGRectGetWidth(frame)-34-80, 17)];
        _label1.font = [UIFont boldSystemFontOfSize:ICFontSize(13.f)];
        _label1.textColor = [UIColor whiteColor];
        [self addSubview:_label1];

        MarqueeLabel2* label2 = [[MarqueeLabel2 alloc] initWithFrame:CGRectMake(34, 20, CGRectGetWidth(frame)-34-80, 17)];
        label2.marqueeType = MLContinuous;
        label2.rate = 20.0;
        label2.animationCurve = UIViewAnimationOptionCurveEaseInOut;
        label2.fadeLength = 10.0f;
        label2.continuousMarqueeExtraBuffer = 10.0f;
        label2.animationDelay = 5.f;
        _label2 = label2;
        _label2.font = [UIFont systemFontOfSize:ICFontSize(13.f)];
        _label2.textColor = [UIColor colorWithWhite:0.57f alpha:1.0f];
        [self addSubview:_label2];

        _label3 = [[UILabel alloc] initWithFrame:CGRectMake(34, 40, CGRectGetWidth(frame)-34-80, 17)];
        _label3.font = [UIFont systemFontOfSize:ICFontSize(11.f)];
        _label3.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
        [self addSubview:_label3];
        _marqueePaused = YES;


        // Play-Button: 60x80 Touch-Area, 22px vom rechten Rand, -4px vom oberen Rand (+3px padding)
        _rightButton = [[UIButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(frame)-60-22, -4, 60, 80)];
        [_rightButton setImage:[[UIImage imageNamed:@"Activity Button Play"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                      forState:UIControlStateNormal];
        _rightButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        _rightButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentFill;
        _rightButton.contentVerticalAlignment = UIControlContentVerticalAlignmentFill;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _rightButton.imageEdgeInsets = UIEdgeInsetsMake(18, 8, 18, 8);
#pragma clang diagnostic pop
        _rightButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        _rightButton.tintColor = [UIColor whiteColor];
        [self addSubview:_rightButton];

        _progressView = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(frame), 2)];
        [self addSubview:_progressView];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_appearanceDidChange)
                                                     name:ICAppearanceManagerDidUpdateAppearanceNotification
                                                   object:nil];
    }
    return self;
}

- (void)_appearanceDidChange {
    [self setNeedsLayout];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) setMarqueePaused:(BOOL)marqueePaused
{
    if (_marqueePaused != marqueePaused) {
        _marqueePaused = marqueePaused;
        
        ((MarqueeLabel2*)self.label2).holdScrolling = marqueePaused;
        if (!marqueePaused) {
            [(MarqueeLabel2*)self.label2 restartLabel];
        }
    }
}

- (BOOL) beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
    _normalBackgroundColor = self.backgroundColor;
    CGFloat white, alpha;
    [_normalBackgroundColor getWhite:&white alpha:&alpha];
    white += 0.05f;

    UIColor* slightlyLighterColor = [UIColor colorWithWhite:white alpha:alpha];
    self.backgroundColor = slightlyLighterColor;

    return [super beginTrackingWithTouch:touch withEvent:event];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event {
    self.backgroundColor = _normalBackgroundColor;
    [super cancelTrackingWithEvent:event];
}

- (void) endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    self.backgroundColor = _normalBackgroundColor;
    [super endTrackingWithTouch:touch withEvent:event];
}

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event
{
    [super sendAction:action to:target forEvent:event];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.backgroundColor = self->_normalBackgroundColor;
    });
}


- (void) layoutSubviews{
    [super layoutSubviews];

    // Update fonts for dynamic font size scaling
    self.label1.font = [UIFont boldSystemFontOfSize:ICFontSize(13.f)];
    self.label2.font = [UIFont systemFontOfSize:ICFontSize(13.f)];
    self.label3.font = [UIFont systemFontOfSize:ICFontSize(11.f)];

    CGRect b = self.bounds;
    CGFloat labelHeight = ceil(self.label1.font.lineHeight);
    CGFloat label3Height = ceil(self.label3.font.lineHeight);
    CGFloat totalHeight = labelHeight + labelHeight + label3Height + 4; // 2px spacing between each
    CGFloat topY = floorf((CGRectGetHeight(b) - totalHeight) / 2);
    topY = MAX(2, topY);

    self.imageView.frame = CGRectMake(5, 0, 44, 44);
    self.label1.frame = CGRectMake(34, topY, CGRectGetWidth(b)-34-80, labelHeight);
    self.label2.frame = CGRectMake(34, topY + labelHeight + 2, CGRectGetWidth(b)-34-80, labelHeight);
    self.label3.frame = CGRectMake(34, topY + labelHeight * 2 + 4, CGRectGetWidth(b)-34-80, label3Height);

    // 60x80 Touch-Area, 22px vom rechten Rand, -4px vom oberen Rand
    self.rightButton.frame = CGRectMake(CGRectGetWidth(b)-60-22, -4, 60, 80);
    self.progressView.frame = CGRectMake(-2, 0, CGRectGetWidth(b)+2, 2);
}
@end
