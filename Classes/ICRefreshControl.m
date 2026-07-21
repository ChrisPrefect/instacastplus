//
//  ICRefreshControl.m
//  Instacast
//
//  Created by Martin Hering on 04.08.13.
//
//

#import "ICRefreshControl.h"
#import "CircleProgressView.h"

typedef NS_ENUM(NSInteger, ICRefreshState) {
    kICRefreshStateClosed = 0,
    kICRefreshStateDragging,
    kICRefreshStateRefreshing,
    kICRefreshStateClosing,
};


@interface ICRefreshControl ()
@property (nonatomic, strong) CircleProgressView* progressView;
@property (nonatomic) ICRefreshState refreshState;
@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* detailLabel;
@end

@implementation ICRefreshControl

- (id) init
{
    if ((self = [super init]))
    {
        // UIKit sizes the refresh control to the current pull distance. Without
        // clipping, the fixed-height circle/labels block reaches past the bottom edge
        // and paints over the first episode rows while the user is still dragging.
        self.clipsToBounds = YES;

        _progressView = [[CircleProgressView alloc] initWithFrame:CGRectZero];
        _progressView.style = CircleProgressStyleFillingOutline;
        [self addSubview:_progressView];
        
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:ICFontSize(13.0f)];
        _titleLabel.textColor = ICTextColor;
        [self addSubview:_titleLabel];
        
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.font = [UIFont systemFontOfSize:ICFontSize(11.0f)];
        _detailLabel.textColor = ICMutedTextColor;
        [self addSubview:_detailLabel];
    }
    
    return self;
}

- (void) setPulldownText:(NSString *)pulldownText
{
    if ((_pulldownText == pulldownText) || [_pulldownText isEqualToString:pulldownText]) {
        return;
    }
    _pulldownText = [pulldownText copy];
    [self setNeedsLayout];
}

- (void) setRefreshText:(NSString *)refreshText
{
    if ((_refreshText == refreshText) || [_refreshText isEqualToString:refreshText]) {
        return;
    }
    _refreshText = [refreshText copy];
    [self setNeedsLayout];
}

- (void) setIdleText:(NSString *)idleText
{
    if ((_idleText == idleText) || [_idleText isEqualToString:idleText]) {
        return;
    }
    _idleText = [idleText copy];
    [self setNeedsLayout];
}

- (void) beginRefreshing
{
    [super beginRefreshing];
    
    self.progressView.style = CircleProgressStyleStandard;
    self.progressView.progress = -1;
    
    self.refreshState = kICRefreshStateRefreshing;
}

- (void) endRefreshing
{
    [super endRefreshing];
    
    self.refreshState = kICRefreshStateClosing;
}

- (void) setRefreshState:(ICRefreshState)refreshState
{
    if (_refreshState != refreshState) {
        _refreshState = refreshState;
        
        [self setNeedsLayout];
    }
}


- (void) _updateProgress
{
    UIScrollView* scrollView = [self.superview isKindOfClass:[UIScrollView class]] ? (UIScrollView*)self.superview : nil;
    if (!scrollView) {
        return;
    }

    if (!self.refreshing) {
        CGFloat restingOffsetY = -scrollView.adjustedContentInset.top;
        CGFloat pullDistance = MAX(0.0f, restingOffsetY - scrollView.contentOffset.y);

        CGFloat progress = MIN(pullDistance / 140.0f, 0.85f);
        self.progressView.style = CircleProgressStyleFillingOutline;
        self.progressView.progress = progress;

        if (pullDistance <= 0.5f) {
            self.refreshState = kICRefreshStateClosed;
        }
        else if (self.refreshState == kICRefreshStateClosed || self.refreshState == kICRefreshStateDragging) {
            self.refreshState = kICRefreshStateDragging;
        }
    } else {
        self.progressView.style = CircleProgressStyleStandard;
        self.progressView.progress = -1;
    }
}

- (void) setFrame:(CGRect)frame
{
    [super setFrame:frame];

    [self _updateProgress];
}

- (void) layoutSubviews
{
    [super layoutSubviews];
    
    CGRect b = self.bounds;
    
    //self.backgroundColor = [UIColor colorWithWhite:0.92f alpha:1.f];
    
    self.titleLabel.textColor = ICTextColor;
    self.detailLabel.textColor = ICMutedTextColor;
    
    for(UIView* subview in self.subviews) {
        if ([NSStringFromClass([subview class]) hasPrefix:@"_UIRefresh"]) {
            subview.hidden = YES;
        }
    }
    
    // The block has a fixed height. It is centred only once the control is tall enough
    // for it; while the control is still shorter it stays anchored to the bottom edge
    // and slides in from underneath the navigation bar instead of overlapping content.
    static const CGFloat kBlockHeight = 37.0f;
    static const CGFloat kBlockBottomMargin = 6.0f;
    CGFloat blockTop = (CGRectGetHeight(b) >= kBlockHeight + 2 * kBlockBottomMargin)
        ? floorf((CGRectGetHeight(b) - kBlockHeight) / 2.0f)
        : CGRectGetHeight(b) - kBlockHeight - kBlockBottomMargin;

    self.progressView.frame = CGRectMake(floorf((76-37)/2), blockTop, 37, 37);

    self.titleLabel.text = (self.refreshState == kICRefreshStateDragging && self.pulldownText) ? self.pulldownText : self.refreshText;
    self.titleLabel.frame = CGRectMake(76, CGRectGetMinY(self.progressView.frame), CGRectGetWidth(b)-76-15, 17);
    
    self.detailLabel.text = self.idleText;
    self.detailLabel.frame = CGRectMake(76, CGRectGetMaxY(self.titleLabel.frame)+2, CGRectGetWidth(b)-76-15, 15);
}

@end
