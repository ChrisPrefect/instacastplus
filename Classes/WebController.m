    //
//  WebController.m
//  Instacast
//
//  Created by Martin Hering on 13.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import "WebController.h"
#import "UtilityFunctions.h"
#import "UIViewController+ShowNotes.h"
#import "ICListTitleView.h"
#import "OpenInSafariActivity.h"
#import "ICAppearanceManager.h"

@interface WebController ()
@property (nonatomic, readwrite, strong) WKWebView* webView;
@property (nonatomic, strong) UIBarButtonItem* actionItem;
@property (nonatomic, strong) UIBarButtonItem* reloadItem;
@property (nonatomic, strong) UIBarButtonItem* backItem;
@property (nonatomic, strong) UIBarButtonItem* forwardItem;
@property (nonatomic, assign) BOOL canceled;
@property (nonatomic, assign) BOOL failed;
@property (nonatomic, assign) BOOL closed;
@property (nonatomic, strong) ICListTitleView* titleView;

// iOS 26: Floating glass buttons replace system toolbar.
// The system floating toolbar (FloatingBarHostingView) intercepts touches in an
// 86pt zone above the visible pill, blocking taps on web content underneath.
// Custom floating buttons only block touches on their actual frame.
@property (nonatomic, strong) UIButton* floatingBackButton API_AVAILABLE(ios(26.0));
@property (nonatomic, strong) UIButton* floatingForwardButton API_AVAILABLE(ios(26.0));
@property (nonatomic, strong) UIButton* floatingSafariButton API_AVAILABLE(ios(26.0));
@end

@implementation WebController {
    NSInteger _loading;
    BOOL _lastCanGoBack;
    BOOL _lastCanGoForward;
}

+ (WebController*) webController
{
	WebController* controller = [[self alloc] initWithNibName:nil bundle:nil];
    return controller;
}

- (void)dealloc {
    [_webView removeObserver:self forKeyPath:@"canGoBack"];
    [_webView removeObserver:self forKeyPath:@"canGoForward"];
	_webView.navigationDelegate = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (BOOL) _canDisplayTwoTitles:(UIInterfaceOrientation)orientation
{
    return ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad || UIInterfaceOrientationIsPortrait(orientation));
}


- (void)viewDidLoad {
    [super viewDidLoad];

    // Extend under bottom bar for safe area coverage, but not behind nav bar
    self.edgesForExtendedLayout = UIRectEdgeBottom;

    self.view.backgroundColor = ICBackgroundColor;

	self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds];
    self.webView.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
	self.webView.navigationDelegate = self;
    if (@available(iOS 26.0, *)) {
        self.webView.scrollView.bottomEdgeEffect.hidden = YES;
    }
    self.webView.backgroundColor = ICBackgroundColor;
    self.webView.scrollView.backgroundColor = ICBackgroundColor;
    if (@available(iOS 15.0, *)) {
        self.webView.underPageBackgroundColor = ICBackgroundColor;
    }

	[self.view addSubview:self.webView];

    // KVO on canGoBack/canGoForward ensures floating buttons update even when
    // WKWebView navigation delegate callbacks don't fire (e.g., JS-driven navigation).
    [self.webView addObserver:self forKeyPath:@"canGoBack" options:0 context:nil];
    [self.webView addObserver:self forKeyPath:@"canGoForward" options:0 context:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

	NSURLRequest* request = [NSURLRequest requestWithURL:self.url];
	[self.webView loadRequest:request];

    CGRect b = self.view.bounds;

    self.titleView = [[ICListTitleView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(b)-88, 44)];

    // Close button (modal dismiss)
    UIBarButtonItem* closeButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"xmark"]
                                                                       style:UIBarButtonItemStylePlain target:self action:@selector(closeAction:)];
    self.navigationItem.leftBarButtonItem = closeButtonItem;

    UIBarButtonItem* shareButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                                                       style:UIBarButtonItemStylePlain target:self action:@selector(actionAction:)];
    self.navigationItem.rightBarButtonItem = shareButtonItem;

    self.actionItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"safari"]
                                                       style:UIBarButtonItemStylePlain target:self action:@selector(showMoreInfoInExternalBrowser:)];

    self.backItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                     style:UIBarButtonItemStylePlain target:self action:@selector(backAction:)];

    self.forwardItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]
                                                        style:UIBarButtonItemStylePlain target:self action:@selector(forwardAction:)];

    self.navigationItem.titleView = self.titleView;

    // iOS 26: use floating glass buttons instead of system toolbar to avoid
    // touch-blocking by FloatingBarHostingView (86pt dead zone above toolbar pill).
    // iOS ≤25: use system toolbar as before.
    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = YES;
        [self _setupFloatingToolbarButtons];
    } else {
        // Initial toolbar (iOS ≤25)
        UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        [self setToolbarItems:@[flexSpace, self.actionItem]];
    }
}

- (void) showMoreInfoInExternalBrowser:(id)sender
{
    NSURL* currentURL = self.webView.URL ?: self.url;
    if ([[UIApplication sharedApplication] canOpenURL:currentURL]) {
        [[UIApplication sharedApplication] openURL:currentURL options:@{} completionHandler:nil];
    }
}

// iOS 26: Creates floating glass buttons (back, forward, safari) on the
// navigationController's view. Back/forward are shown/hidden dynamically
// based on WebView navigation state. Safari button is always visible.
- (void) _setupFloatingToolbarButtons API_AVAILABLE(ios(26.0))
{
    WEAK_SELF

    // Back button (bottom-left)
    UIButtonConfiguration* backConfig = [UIButtonConfiguration glassButtonConfiguration];
    backConfig.image = [UIImage systemImageNamed:@"chevron.left"];
    backConfig.buttonSize = UIButtonConfigurationSizeLarge;
    self.floatingBackButton = [UIButton buttonWithConfiguration:backConfig primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* action) {
            STRONG_SELF
            [self backAction:nil];
        }]];
    self.floatingBackButton.hidden = YES; // initially hidden until canGoBack
    self.floatingBackButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Forward button (next to back)
    UIButtonConfiguration* fwdConfig = [UIButtonConfiguration glassButtonConfiguration];
    fwdConfig.image = [UIImage systemImageNamed:@"chevron.right"];
    fwdConfig.buttonSize = UIButtonConfigurationSizeLarge;
    self.floatingForwardButton = [UIButton buttonWithConfiguration:fwdConfig primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* action) {
            STRONG_SELF
            [self forwardAction:nil];
        }]];
    self.floatingForwardButton.hidden = YES; // initially hidden until canGoForward
    self.floatingForwardButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Safari button (bottom-right, always visible)
    UIButtonConfiguration* safariConfig = [UIButtonConfiguration glassButtonConfiguration];
    safariConfig.image = [UIImage systemImageNamed:@"safari"];
    safariConfig.buttonSize = UIButtonConfigurationSizeLarge;
    self.floatingSafariButton = [UIButton buttonWithConfiguration:safariConfig primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* action) {
            STRONG_SELF
            [self showMoreInfoInExternalBrowser:nil];
        }]];
    self.floatingSafariButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Match button appearance to app theme (glass buttons may not inherit
    // window's overrideUserInterfaceStyle when presented modally before window connection)
    UIUserInterfaceStyle style = [ICAppearanceManager sharedManager].nightSettingMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    self.floatingBackButton.overrideUserInterfaceStyle = style;
    self.floatingForwardButton.overrideUserInterfaceStyle = style;
    self.floatingSafariButton.overrideUserInterfaceStyle = style;

    UIView* container = self.navigationController.view;
    [container addSubview:self.floatingBackButton];
    [container addSubview:self.floatingForwardButton];
    [container addSubview:self.floatingSafariButton];

    UILayoutGuide* safeArea = container.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        // Back: bottom-left
        [self.floatingBackButton.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [self.floatingBackButton.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        // Forward: right of back
        [self.floatingForwardButton.leadingAnchor constraintEqualToAnchor:self.floatingBackButton.trailingAnchor constant:12],
        [self.floatingForwardButton.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        // Safari: bottom-right
        [self.floatingSafariButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],
        [self.floatingSafariButton.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
    ]];
}

// KVO callback for canGoBack/canGoForward — keeps floating buttons in sync
// even when WKWebView changes history state without navigation delegate callbacks.
- (void) observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
    if (object == self.webView && ([keyPath isEqualToString:@"canGoBack"] || [keyPath isEqualToString:@"canGoForward"])) {
        [self _updateToolbar];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void) updateAppearance
{
    self.view.backgroundColor = ICBackgroundColor;
    self.webView.backgroundColor = ICBackgroundColor;
    self.webView.scrollView.backgroundColor = ICBackgroundColor;
    if (@available(iOS 15.0, *)) {
        self.webView.underPageBackgroundColor = ICBackgroundColor;
    }

    // iOS 26: sync floating button appearance with app theme
    if (@available(iOS 26.0, *)) {
        UIUserInterfaceStyle style = [ICAppearanceManager sharedManager].nightSettingMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        self.floatingBackButton.overrideUserInterfaceStyle = style;
        self.floatingForwardButton.overrideUserInterfaceStyle = style;
        self.floatingSafariButton.overrideUserInterfaceStyle = style;
    }
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    // Debug: check floating button sizes to diagnose safari button size mismatch
    if (@available(iOS 26.0, *)) {
        DebugLog(@"FloatingButton frames — back: %@ forward: %@ safari: %@",
            NSStringFromCGSize(self.floatingBackButton.bounds.size),
            NSStringFromCGSize(self.floatingForwardButton.bounds.size),
            NSStringFromCGSize(self.floatingSafariButton.bounds.size));
    }
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    if (@available(iOS 26.0, *)) {
        // iOS 26: show floating buttons, keep system toolbar hidden
        self.navigationController.toolbarHidden = YES;
        self.floatingSafariButton.hidden = NO;
        [self.navigationController.view bringSubviewToFront:self.floatingBackButton];
        [self.navigationController.view bringSubviewToFront:self.floatingForwardButton];
        [self.navigationController.view bringSubviewToFront:self.floatingSafariButton];
    } else {
        // iOS ≤25: show system toolbar
        [self.navigationController setToolbarHidden:NO animated:YES];
    }
    [self _updateToolbar];
}

- (void) viewWillDisappear:(BOOL)animated
{
    // iOS 26: restore system toolbar for next VC, hide floating buttons
    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = NO;
        self.floatingBackButton.hidden = YES;
        self.floatingForwardButton.hidden = YES;
        self.floatingSafariButton.hidden = YES;
    }

	self.canceled = YES;
	[super viewWillDisappear:animated];
	[self.webView stopLoading];

    while (_loading > 0) {
        [App releaseNetworkActivity];
        _loading--;
    }
}


#pragma mark - WebView Delegate

- (void) _updateToolbar
{
    BOOL canGoBack = [self.webView canGoBack];
    BOOL canGoForward = [self.webView canGoForward];

    // iOS 26: update floating button visibility based on navigation state
    if (@available(iOS 26.0, *)) {
        self.floatingBackButton.hidden = !canGoBack;
        self.floatingForwardButton.hidden = !canGoForward;
        self.floatingSafariButton.enabled = (!self.failed);
        _lastCanGoBack = canGoBack;
        _lastCanGoForward = canGoForward;
        return;
    }

    // iOS ≤25: update system toolbar items
    if (canGoBack == _lastCanGoBack && canGoForward == _lastCanGoForward) {
        self.actionItem.enabled = (!self.failed);
        return;
    }
    _lastCanGoBack = canGoBack;
    _lastCanGoForward = canGoForward;

    UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem* fixedSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixedSpace.width = 20;

    NSMutableArray* items = [NSMutableArray array];

    if (canGoBack) {
        [items addObject:self.backItem];
    }
    if (canGoBack && canGoForward) {
        [items addObject:fixedSpace];
    }
    if (canGoForward) {
        [items addObject:self.forwardItem];
    }

    [items addObject:flexSpace];
    self.actionItem.enabled = (!self.failed);
    [items addObject:self.actionItem];

    [self setToolbarItems:items animated:YES];
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    self.failed = NO;

    [App retainNetworkActivity];
    _loading++;
    [self _updateToolbar];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [App releaseNetworkActivity];
    _loading--;
    [self _updateToolbar];

    [webView evaluateJavaScript:@"document.title" completionHandler:^(id result, NSError * _Nullable error) {
        if (error == nil) {
            NSString* title = result;
            self.navigationItem.title = title;
            self.titleView.textLabel.text = title;
        }
    }];

    [webView evaluateJavaScript:@"document.location.href" completionHandler:^(id result, NSError * _Nullable error) {
        if (error == nil) {
            NSString* href = result;
            self.titleView.detailTextLabel.text = href;
        }
    }];
}


#define WebKitErrorCannotShowURL 101
#define WebKitErrorFrameLoadInterruptedByPolicyChange 102

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [App releaseNetworkActivity];
    _loading--;

    if ([error code] == kCFURLErrorCancelled) {
        return;
    }

    if ([error code] == WebKitErrorCannotShowURL && [App canOpenURL:self.url]) {
        [App openURL:self.url options:@{} completionHandler:nil];
        self.canceled = YES;
        [self performSelector:@selector(dismissAfterDelay) withObject:nil afterDelay:0.5];
        self.closed = YES;
        return;
    }

    ErrLog(@"error loading page %@", error);

    if (!self.canceled && [error code] != 204 && [error code] != WebKitErrorCannotShowURL && [error code] != WebKitErrorFrameLoadInterruptedByPolicyChange)
    {
        [self presentAlertControllerWithTitle:@"Loading website failed.".ls
                                      message:@"Either the server is not available or you may not have an internet connection.".ls
                                       button:@"OK".ls
                                     animated:YES
                                   completion:NULL];
    }

    self.failed = YES;
    [self _updateToolbar];
    [self performSelector:@selector(dismissAfterDelay) withObject:nil afterDelay:0.5];
    self.closed = YES;
}


- (void) dismissAfterDelay
{
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void) closeAction:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark -
#pragma mark Actions


- (void) actionAction:(id)sender
{
    NSURL* currentURL = self.webView.URL ?: self.url;
    UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[currentURL] applicationActivities:@[[[OpenInSafariActivity alloc] init]]];
    if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
        shareController.popoverPresentationController.barButtonItem = sender;
    }
    [self presentViewController:shareController animated:YES completion:NULL];
}


- (void) reloadAction:(id)sender
{
	[self.webView reload];
}

- (void) backAction:(id)sender
{
	[self.webView goBack];
}

- (void) forwardAction:(id)sender
{
	[self.webView goForward];
}

@end
