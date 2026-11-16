//
//  OnboardScreenVC.m
//  Instacast
//
//  Created by Devendra Kamal on 15/08/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import "OnboardScreenVC.h"
#import "ChangeLogViewController.h"
#import "SubscriptionsTableViewController.h"
#import "InstacastPlus-Swift.h"

@interface OnboardScreenVC ()
@property (nonatomic, assign) BOOL overlaySetupDone;
@end

@implementation OnboardScreenVC

@synthesize delegate;

- (void)viewDidLoad {
    [super viewDidLoad];

    // Setup shadow overlay (full coverage, no cutout)
    self.shadowView.userInteractionEnabled = YES;
    UITapGestureRecognizer *tapGesture1 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapGesture:)];
    tapGesture1.numberOfTapsRequired = 1;
    [self.shadowView addGestureRecognizer:tapGesture1];
    self.shadowView.backgroundColor = [UIColor blackColor];
    self.shadowView.alpha = 0.5;

    // Hide XIB elements - we create new ones positioned dynamically over the real button
    self.arrowImage.hidden = YES;
    self.descLabel.hidden = YES;
    self.plusBtn.hidden = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_observedFeedsDidChange:)
                                                 name:DatabaseManagerDidUpdateObservedFeedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_addButtonDidAppear:)
                                                 name:ICSubscriptionsAddButtonDidAppearNotification
                                               object:nil];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ChangeLogViewController *changelogVC = [[ChangeLogViewController alloc] init];
        UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:changelogVC];
        navVC.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:navVC animated:YES completion:nil];
    });
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if ([self _dismissIfPodcastsExist]) {
        return;
    }
    if (!self.overlaySetupDone) {
        [self _setupOnboardOverlay];
    }
}

#pragma mark - Obsolete Hint

// The hint explains how to add the first podcast. Once podcasts exist (OPML or backup
// import, iCloud, a subscribe link) it would only cover the list.
- (BOOL)_dismissIfPodcastsExist
{
    if (DMANAGER.feeds.count == 0 || self.presentedViewController || self.isBeingDismissed) {
        return NO;
    }
    [self dismissViewControllerAnimated:NO completion:nil];
    return YES;
}

- (void)_observedFeedsDidChange:(NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.viewIfLoaded.window) {
            [self _dismissIfPodcastsExist];
        }
    });
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Onboard Overlay

- (void)_addButtonDidAppear:(NSNotification *)notification
{
    if (!self.overlaySetupDone && self.viewIfLoaded.window && ![self _dismissIfPodcastsExist]) {
        [self _setupOnboardOverlay];
    }
}

- (void)_setupOnboardOverlay
{
    // iOS 26: "+" is the list's floating glass button. On a first launch this hint can appear
    // before the list put that button on screen; anchoring to the system toolbar or a fixed
    // position then highlights a place next to the real button (measured 25 pt off). Wait
    // until the list reports the button instead.
    if (@available(iOS 26.0, *)) {
        UIView *floatingButton = [self _findViewWithAccessibilityIdentifier:ICSubscriptionsAddButtonAccessibilityIdentifier
                                                                     inView:self.view.window];
        if (!floatingButton.window || CGRectIsEmpty(floatingButton.bounds)) {
            [[ICDiagnosticLogger shared] logEvent:@"onboarding"
                                          message:@"Hinweis wartet auf Hinzufügen-Button"
                                         metadata:@{ @"floatingButtonFound": @(floatingButton != nil) }];
            return;
        }
    }
    self.overlaySetupDone = YES;

    // Find the real toolbar plus button position
    UIView *buttonView = [self _findToolbarPlusButton];
    UIView *floatingButton = [self _findViewWithAccessibilityIdentifier:ICSubscriptionsAddButtonAccessibilityIdentifier inView:self.view.window];
    [[ICDiagnosticLogger shared] logEvent:@"onboarding"
                                  message:@"Hinweis auf Hinzufügen-Button eingerichtet"
                                 metadata:@{
        @"anchor": buttonView ? NSStringFromClass(buttonView.class) : @"fallback",
        @"anchorIsFloatingButton": @(buttonView != nil && buttonView == floatingButton),
        @"floatingButtonFound": @(floatingButton != nil),
        @"floatingButtonInWindow": @(floatingButton.window != nil),
        @"floatingButtonHidden": @(floatingButton.hidden),
        @"floatingButtonBounds": NSStringFromCGRect(floatingButton.bounds),
        @"floatingButtonSuperview": floatingButton.superview ? NSStringFromClass(floatingButton.superview.class) : @"",
    }];

    CGPoint buttonCenter;
    if (buttonView) {
        buttonCenter = [buttonView convertPoint:CGPointMake(CGRectGetMidX(buttonView.bounds),
                                                             CGRectGetMidY(buttonView.bounds))
                                         toView:self.view];
    } else {
        // Fallback: bottom-left toolbar area
        CGFloat safeBottom = self.view.safeAreaInsets.bottom;
        buttonCenter = CGPointMake(40, self.view.bounds.size.height - safeBottom - 25);
    }

    BOOL isDark = [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;

    // --- 1. Fake plus button graphic (larger than real, with glow) ---
    CGFloat size = 54.0;
    UIView *fakeButton = [[UIView alloc] initWithFrame:CGRectMake(buttonCenter.x - size / 2,
                                                                    buttonCenter.y - size / 2,
                                                                    size, size)];
    fakeButton.backgroundColor = isDark
        ? [UIColor colorWithWhite:0.25 alpha:1.0]
        : [UIColor colorWithWhite:0.95 alpha:1.0];
    fakeButton.layer.cornerRadius = size / 2;
    fakeButton.userInteractionEnabled = NO;

    // Plus icon
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    UIImageView *plusIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus" withConfiguration:config]];
    plusIcon.tintColor = isDark ? [UIColor whiteColor] : [UIColor blackColor];
    plusIcon.contentMode = UIViewContentModeCenter;
    plusIcon.frame = fakeButton.bounds;
    [fakeButton addSubview:plusIcon];

    // Glow effect around the button
    fakeButton.layer.shadowColor = (isDark
        ? [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0]
        : [UIColor colorWithWhite:1.0 alpha:1.0]).CGColor;
    fakeButton.layer.shadowOffset = CGSizeZero;
    fakeButton.layer.shadowRadius = 15.0;
    fakeButton.layer.shadowOpacity = 0.9;
    fakeButton.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(fakeButton.bounds, -4, -4)].CGPath;

    [self.view insertSubview:fakeButton aboveSubview:self.shadowView];

    // --- 2. Arrow (positioned dynamically above the fake button) ---
    NSString *arrowName = isDark ? @"onboard_arrow_wh" : @"onboard_arrow_bl";
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage imageNamed:arrowName]];
    arrow.contentMode = UIViewContentModeScaleAspectFit;

    CGFloat arrowW = 50, arrowH = 60;
    arrow.frame = CGRectMake(buttonCenter.x - 5,
                              buttonCenter.y - size / 2 - arrowH - 2,
                              arrowW, arrowH);

    // White glow for readability on grey overlay
    arrow.layer.shadowColor = [UIColor whiteColor].CGColor;
    arrow.layer.shadowOffset = CGSizeZero;
    arrow.layer.shadowRadius = 6.0;
    arrow.layer.shadowOpacity = 1.0;

    [self.view insertSubview:arrow aboveSubview:fakeButton];

    // --- 3. Label (to the right of arrow) ---
    UILabel *label = [[UILabel alloc] init];
    label.text = @"to add podcasts, search the podcast directory".ls;
    label.font = [UIFont systemFontOfSize:ICFontSize(18) weight:UIFontWeightMedium];
    label.textColor = isDark ? [UIColor whiteColor] : [UIColor blackColor];
    label.numberOfLines = 0;

    CGFloat labelX = CGRectGetMaxX(arrow.frame) + 10;
    CGFloat labelMaxW = self.view.bounds.size.width - labelX - 20;
    label.frame = CGRectMake(labelX,
                              CGRectGetMinY(arrow.frame) - 10,
                              labelMaxW, 100);
    [label sizeToFit];

    // White glow for readability
    label.layer.shadowColor = [UIColor whiteColor].CGColor;
    label.layer.shadowOffset = CGSizeZero;
    label.layer.shadowRadius = 6.0;
    label.layer.shadowOpacity = 1.0;

    [self.view insertSubview:label aboveSubview:arrow];

    // --- 4. Invisible tap button over fake plus button ---
    UIButton *tapButton = [UIButton buttonWithType:UIButtonTypeCustom];
    tapButton.frame = CGRectMake(buttonCenter.x - 40, buttonCenter.y - 40, 80, 80);
    [tapButton addTarget:self action:@selector(plusButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:tapButton];
}

#pragma mark - Find Toolbar Button

- (UIView *)_findToolbarPlusButton
{
    UIWindow *window = self.view.window;
    if (!window) return nil;

    // iOS 26: the system toolbar is hidden and "+" is a glass button on the navigation
    // controller's view. Searching only for a UIToolbar ended in the fixed fallback
    // position, about 25 pt away from the real button.
    // The change log is presented full screen over this hint first; while it is up, the list
    // hides its glass buttons and shows them again only after this view reappeared. The
    // button's position is valid regardless, so it is looked up whether hidden or not.
    UIView *floatingButton = [self _findViewWithAccessibilityIdentifier:ICSubscriptionsAddButtonAccessibilityIdentifier
                                                                 inView:window];
    [floatingButton.superview layoutIfNeeded];
    if (floatingButton.window && !CGRectIsEmpty(floatingButton.bounds)) return floatingButton;

    // Find the UIToolbar in the window, then get its leftmost button
    UIToolbar *toolbar = [self _findToolbarInView:window];
    if (!toolbar) return nil;

    return [self _findLeftmostButtonInToolbar:toolbar];
}

- (UIView *)_findViewWithAccessibilityIdentifier:(NSString *)identifier inView:(UIView *)view
{
    // Don't search into our own view hierarchy
    if (view == self.view) return nil;

    if ([view.accessibilityIdentifier isEqualToString:identifier]) {
        return view;
    }
    for (UIView *sub in view.subviews) {
        UIView *result = [self _findViewWithAccessibilityIdentifier:identifier inView:sub];
        if (result) return result;
    }
    return nil;
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

#pragma mark - Actions

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
