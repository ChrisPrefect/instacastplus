//
//  ICFeedHeaderViewController.m
//  Instacast
//
//  Created by Martin Hering on 01/06/14.
//
//

#import "ICFeedHeaderViewController.h"

@interface ICFeedHeaderViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, strong, readwrite) UIImageView* imageView;
@property (nonatomic, strong, readwrite) UILabel* titleLabel;
@property (nonatomic, strong, readwrite) UILabel* subtitleLabel;
@property (nonatomic, strong, readwrite) UILabel* feedSubtitleLabel;
@property (nonatomic, strong, readwrite) UIView* selectedBackgroundView;
@property (nonatomic, strong, readwrite) UIImageView* triangleImageView;
@end

@implementation ICFeedHeaderViewController

+ (instancetype) viewController {
    return [[self alloc] initWithNibName:nil bundle:nil];
}

- (void) viewDidLoad
{
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(setAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    
    // create image view
    UIImageView* imageView = [[UIImageView alloc] initWithFrame:CGRectMake(15, 10, 72, 72)];
    imageView.image = [UIImage imageNamed:@"Podcast Placeholder 72"];
    [self.view addSubview:imageView];
    self.imageView = imageView;
    
    // create title label
    UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.numberOfLines = 2;
    titleLabel.font = [UIFont systemFontOfSize:17.0f];
    titleLabel.backgroundColor = [UIColor clearColor];
    titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.view addSubview:titleLabel];
    
    // create author label
    UILabel* authorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    authorLabel.numberOfLines = 2;
    authorLabel.font = [UIFont systemFontOfSize:13.0f];
    authorLabel.backgroundColor = [UIColor clearColor];
    authorLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [self.view addSubview:authorLabel];
    
    // create feed subtitle label (shown below author)
    UILabel* feedSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    feedSubtitleLabel.numberOfLines = 2;
    feedSubtitleLabel.font = [UIFont systemFontOfSize:12.0f];
    feedSubtitleLabel.backgroundColor = [UIColor clearColor];
    feedSubtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:feedSubtitleLabel];

    self.titleLabel = titleLabel;
    self.subtitleLabel = authorLabel;
    self.feedSubtitleLabel = feedSubtitleLabel;

    CGRect b = self.view.bounds;
    self.view.frame = CGRectMake(0, 0, CGRectGetWidth(b), 93);
    
    UIImageView* triangleImageView = [[UIImageView alloc] initWithFrame:CGRectMake(CGRectGetWidth(b)-8-15, 39, 8, 14)];
    triangleImageView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    triangleImageView.contentMode = UIViewContentModeCenter;
    triangleImageView.image = [[UIImage imageNamed:@"TableView Disclosure Triangle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.triangleImageView = triangleImageView;
    [self.view addSubview:triangleImageView];
    
}


- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self setAppearance];
    
    self.triangleImageView.hidden = (self.action == nil);
    
    [self layoutContent];
}

- (void) setAppearance {
    self.view.backgroundColor = ICTransparentBackdropColor;
    self.titleLabel.textColor = ICTextColor;
    self.subtitleLabel.textColor = ICMutedTextColor;
    self.feedSubtitleLabel.textColor = ICMutedTextColor;
    self.triangleImageView.tintColor = ICMutedTextColor;
    self.selectedBackgroundView.backgroundColor = ICTableSelectedBackgroundColor;
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) layoutContent
{
    CGFloat contentWidth = [[UIScreen mainScreen] bounds].size.width;
    CGFloat labelWidth = contentWidth - 72 - 45;
    CGFloat labelX = 72 + 15 + 15;

    CGSize titleSize = [self.titleLabel.attributedText boundingRectWithSize:CGSizeMake(labelWidth, 100) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(titleSize);

    CGSize authorSize = [self.subtitleLabel.attributedText boundingRectWithSize:CGSizeMake(labelWidth, 100) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(authorSize);

    BOOL hasFeedSubtitle = (self.feedSubtitleLabel.text.length > 0);
    CGSize feedSubtitleSize = CGSizeZero;
    if (hasFeedSubtitle) {
        feedSubtitleSize = [self.feedSubtitleLabel.attributedText boundingRectWithSize:CGSizeMake(labelWidth, 100) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
        IC_SIZE_INTEGRAL(feedSubtitleSize);
    }

    CGFloat labelsHeight = titleSize.height + authorSize.height + 2;
    if (hasFeedSubtitle) {
        labelsHeight += feedSubtitleSize.height + 2;
    }
    CGFloat yOffset = 10 + floorf((72 - labelsHeight) / 2);

    self.titleLabel.frame = CGRectMake(labelX, yOffset, labelWidth, titleSize.height);
    self.subtitleLabel.frame = CGRectMake(labelX, CGRectGetMaxY(self.titleLabel.frame) + 2, labelWidth, authorSize.height);

    if (hasFeedSubtitle) {
        self.feedSubtitleLabel.frame = CGRectMake(labelX, CGRectGetMaxY(self.subtitleLabel.frame) + 2, labelWidth, feedSubtitleSize.height);
        self.feedSubtitleLabel.hidden = NO;
    } else {
        self.feedSubtitleLabel.hidden = YES;
    }
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation duration:(NSTimeInterval)duration
{
    [self layoutContent];
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self layoutContent];
    [self deselectAnimated:animated];
}


- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (!self.action) {
        return;
    }
    
    if (!self.selectedBackgroundView) {
        self.selectedBackgroundView = [[UIView alloc] initWithFrame:self.view.bounds];
        self.selectedBackgroundView.backgroundColor = ICTableSelectedBackgroundColor;
        [self.view insertSubview:self.selectedBackgroundView atIndex:0];
    }
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (self.action) {
        self.action();
    }    
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    [self.selectedBackgroundView removeFromSuperview];
    self.selectedBackgroundView = nil;
}

- (void) deselectAnimated:(BOOL)animated
{
    if (self.selectedBackgroundView) {
        if (animated) {
            [UIView animateWithDuration:0.3f
                             animations:^{
                                 self.selectedBackgroundView.alpha = 0;
                             } completion:^(BOOL finished) {
                                 [self.selectedBackgroundView removeFromSuperview];
                                 self.selectedBackgroundView = nil;
                             }];
        }
        else {
            [self.selectedBackgroundView removeFromSuperview];
            self.selectedBackgroundView = nil;
        }
    }
}
@end
