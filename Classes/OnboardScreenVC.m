//
//  OnboardScreenVC.m
//  Instacast
//
//  Created by Devendra Kamal on 15/08/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import "OnboardScreenVC.h"
#import "ChangeLogViewController.h"

@interface OnboardScreenVC ()
@end

@implementation OnboardScreenVC

@synthesize delegate;

- (void)viewDidLoad {
    [super viewDidLoad];

    self.descLabel.text = @"to add podcasts, search the podcast directory".ls;
    self.shadowView.userInteractionEnabled = YES;
    UITapGestureRecognizer *tapGesture1 = [[UITapGestureRecognizer alloc] initWithTarget:self  action:@selector(tapGesture:)];
    tapGesture1.numberOfTapsRequired = 1;
    [self.shadowView addGestureRecognizer:tapGesture1];
    self.shadowView.backgroundColor = [UIColor blackColor];
    self.shadowView.alpha = 0.5;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ChangeLogViewController *changelogVC = [[ChangeLogViewController alloc] init];
        UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:changelogVC];
        navVC.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:navVC animated:YES completion:nil];
    });
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)
    {
        self.arrowImage.image = [UIImage imageNamed:@"onboard_arrow_wh"];
        self.descLabel.textColor = [UIColor whiteColor];
    }
    else
    {
        self.arrowImage.image = [UIImage imageNamed:@"onboard_arrow_bl"];
        self.descLabel.textColor = [UIColor blackColor];
    }
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self _createToolbarSpotlight];
}

#pragma mark - Spotlight Cutout

- (void)_createToolbarSpotlight
{
    // Find the real toolbar plus button in the presenting VC's view hierarchy
    UIView *buttonView = [self _findToolbarPlusButton];
    if (!buttonView) return;

    // Convert button center to shadowView's coordinate system
    CGPoint buttonCenter = [buttonView convertPoint:CGPointMake(CGRectGetMidX(buttonView.bounds),
                                                                 CGRectGetMidY(buttonView.bounds))
                                             toView:self.shadowView];

    // Create mask: full overlay with circular cutout around the plus button
    CGFloat radius = 30.0;
    UIBezierPath *overlayPath = [UIBezierPath bezierPathWithRect:self.shadowView.bounds];
    UIBezierPath *spotlightPath = [UIBezierPath bezierPathWithOvalInRect:
        CGRectMake(buttonCenter.x - radius, buttonCenter.y - radius, radius * 2, radius * 2)];
    [overlayPath appendPath:spotlightPath];

    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.path = overlayPath.CGPath;
    maskLayer.fillRule = kCAFillRuleEvenOdd;
    self.shadowView.layer.mask = maskLayer;
}

- (UIView *)_findToolbarPlusButton
{
    UIWindow *window = self.view.window;
    if (!window) return nil;

    // Find the UIToolbar in the window, then get its leftmost button
    UIToolbar *toolbar = [self _findToolbarInView:window];
    if (!toolbar) return nil;

    return [self _findLeftmostButtonInToolbar:toolbar];
}

- (UIToolbar *)_findToolbarInView:(UIView *)view
{
    // Don't search into our own view hierarchy
    if (view == self.view) return nil;

    if ([view isKindOfClass:[UIToolbar class]]) {
        return (UIToolbar *)view;
    }
    for (UIView *sub in view.subviews) {
        UIToolbar *result = [self _findToolbarInView:sub];
        if (result) return result;
    }
    return nil;
}

- (UIView *)_findLeftmostButtonInToolbar:(UIView *)view
{
    // Look for UIControl subviews (toolbar buttons are UIControl subclasses)
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    [self _collectControlsInView:view into:buttons];

    // Return the leftmost one
    UIView *leftmost = nil;
    for (UIView *btn in buttons) {
        CGPoint pos = [btn convertPoint:CGPointZero toView:self.view.window];
        if (!leftmost) {
            leftmost = btn;
        } else {
            CGPoint leftPos = [leftmost convertPoint:CGPointZero toView:self.view.window];
            if (pos.x < leftPos.x) {
                leftmost = btn;
            }
        }
    }
    return leftmost;
}

- (void)_collectControlsInView:(UIView *)view into:(NSMutableArray<UIView *> *)controls
{
    if ([view isKindOfClass:[UIControl class]] && view.bounds.size.width > 10 && view.bounds.size.height > 10) {
        [controls addObject:view];
        return;
    }
    for (UIView *sub in view.subviews) {
        [self _collectControlsInView:sub into:controls];
    }
}

- (void) addAction:(id)sender
{
    [self dismissViewControllerAnimated:NO completion:^{
        [self.delegate plusButtonPressDelegateMethod:self];
    }];
}

- (void) tapGesture: (id)sender
{
    [self dismissViewControllerAnimated:NO completion:nil];
}

-(IBAction)plusButtonPressed:(id)sender 
{
    [self dismissViewControllerAnimated:NO completion:^{
        [self.delegate plusButtonPressDelegateMethod:self];
    }];
    
}



@end
