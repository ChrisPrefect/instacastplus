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

static CGFloat ICMeasuredLabelHeight(UILabel* label, CGFloat width)
{
    if (width <= 0) {
        return 0;
    }

    NSString* text = label.text;
    if (text.length == 0) {
        return 0;
    }

    UIFont* font = label.font ?: [UIFont systemFontOfSize:[UIFont labelFontSize]];
    NSDictionary* attributes = @{ NSFontAttributeName : font };
    CGRect textRect = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                      attributes:attributes
                                         context:nil];

    CGFloat height = ceil(CGRectGetHeight(textRect));
    if (label.numberOfLines > 0) {
        CGFloat maxHeight = ceil(font.lineHeight * label.numberOfLines);
        height = MIN(height, maxHeight);
    }

    return height;
}

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
    titleLabel.font = [UIFont boldSystemFontOfSize:18.0f];
    titleLabel.backgroundColor = [UIColor clearColor];
    titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.7;
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
    CGFloat contentWidth = CGRectGetWidth(self.view.bounds);
    CGFloat labelWidth = MAX(0, contentWidth - 72 - 60);
    CGFloat labelX = 72 + 15 + 15;

    CGFloat titleHeight = ICMeasuredLabelHeight(self.titleLabel, labelWidth);
    CGFloat authorHeight = ICMeasuredLabelHeight(self.subtitleLabel, labelWidth);
    CGFloat feedSubtitleHeight = ICMeasuredLabelHeight(self.feedSubtitleLabel, labelWidth);

    CGFloat labelsHeight = 0;
    if (titleHeight > 0) {
        labelsHeight += titleHeight;
    }
    if (authorHeight > 0) {
        if (labelsHeight > 0) {
            labelsHeight += 2;
        }
        labelsHeight += authorHeight;
    }
    if (feedSubtitleHeight > 0) {
        if (labelsHeight > 0) {
            labelsHeight += 2;
        }
        labelsHeight += feedSubtitleHeight;
    }

    CGFloat yOffset = 10 + floorf((72 - labelsHeight) / 2);
    yOffset = MAX(10, yOffset);

    CGFloat currentY = yOffset;

    self.titleLabel.frame = CGRectMake(labelX, currentY, labelWidth, titleHeight);
    self.titleLabel.hidden = (titleHeight <= 0);
    currentY = CGRectGetMaxY(self.titleLabel.frame);

    if (authorHeight > 0) {
        if (currentY > yOffset) {
            currentY += 2;
        }
        self.subtitleLabel.frame = CGRectMake(labelX, currentY, labelWidth, authorHeight);
        self.subtitleLabel.hidden = NO;
        currentY = CGRectGetMaxY(self.subtitleLabel.frame);
    } else {
        self.subtitleLabel.hidden = YES;
    }

    if (feedSubtitleHeight > 0) {
        if (currentY > yOffset) {
            currentY += 2;
        }
        self.feedSubtitleLabel.frame = CGRectMake(labelX, currentY, labelWidth, feedSubtitleHeight);
        self.feedSubtitleLabel.hidden = NO;
    } else {
        self.feedSubtitleLabel.hidden = YES;
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    (void)size;
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [self layoutContent];
    } completion:nil];
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
