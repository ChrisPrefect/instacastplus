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

@interface WebController ()
@property (nonatomic, readwrite, strong) WKWebView* webView;
@property (nonatomic, strong) UIBarButtonItem* actionItem;
@property (nonatomic, strong) UIBarButtonItem* reloadItem;
@property (nonatomic, strong) UIBarButtonItem* backItem;
@property (nonatomic, strong) UIBarButtonItem* forwardItem;
@property (nonatomic, strong) UIBarButtonItem* activityItem;
@property (nonatomic, assign) BOOL canceled;
@property (nonatomic, assign) BOOL failed;
@property (nonatomic, assign) BOOL closed;
@property (nonatomic, strong) ICListTitleView* titleView;
@end

@implementation WebController {
    NSInteger _loading;
    BOOL _toolbarWasHidden;
}

+ (WebController*) webController
{
	WebController* controller = [[self alloc] initWithNibName:nil bundle:nil];
    controller.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    return controller;
}

- (void)dealloc {
	_webView.navigationDelegate = nil;
}


- (BOOL) _canDisplayTwoTitles:(UIInterfaceOrientation)orientation
{
    return ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad || UIInterfaceOrientationIsPortrait(orientation));
}


// Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
- (void)viewDidLoad {
    [super viewDidLoad];

    // Prevent web content from extending under the navigation bar
    self.edgesForExtendedLayout = UIRectEdgeBottom;

    self.view.backgroundColor = ICBackgroundColor;

	self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds];
    self.webView.autoresizingMask = (UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
	self.webView.navigationDelegate = self;
    [self.webView sizeToFit];
    self.webView.backgroundColor = ICBackgroundColor;
    self.webView.scrollView.backgroundColor = ICBackgroundColor;
    self.webView.underPageBackgroundColor = ICBackgroundColor;

    for(UIView* subview in self.webView.scrollView.subviews) {
        subview.backgroundColor = ICBackgroundColor;
    }
    
	[self.view addSubview:self.webView];
	
	NSURLRequest* request = [NSURLRequest requestWithURL:self.url];
	[self.webView loadRequest:request];
	
    CGRect b = self.view.bounds;
    
    self.titleView = [[ICListTitleView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(b)-88, 44)];

    
    // Share button in navigation bar (swapped from toolbar)
    UIBarButtonItem* shareButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                                                       style:UIBarButtonItemStylePlain target:self action:@selector(actionAction:)];
    self.navigationItem.rightBarButtonItem = shareButtonItem;

    // Open in external browser in toolbar (swapped from nav bar)
    self.actionItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"]
                                                       style:UIBarButtonItemStylePlain target:self action:@selector(showMoreInfoInExternalBrowser:)];

    self.backItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Previous"]
                                                     style:UIBarButtonItemStylePlain target:self action:@selector(backAction:)];

    self.forwardItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Next"]
                                                        style:UIBarButtonItemStylePlain target:self action:@selector(forwardAction:)];

    self.reloadItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Reload"]
                                                       style:UIBarButtonItemStylePlain target:self action:@selector(reloadAction:)];
    self.reloadItem.width = 44;

    self.navigationItem.titleView = self.titleView;

    UIActivityIndicatorView* activityIndicator = [[UIActivityIndicatorView alloc] initWithFrame:CGRectMake(0,0,44,44)];
    activityIndicator.activityIndicatorViewStyle = [ICAppearanceManager sharedManager].appearance.activityIndicatorStyle;
    [activityIndicator startAnimating];
    self.activityItem = [[UIBarButtonItem alloc] initWithCustomView:activityIndicator];
    self.activityItem.width = 44;
}

- (void) showMoreInfoInExternalBrowser:(id)sender
{
    NSURL* currentURL = self.webView.URL ?: self.url;
    if ([[UIApplication sharedApplication] canOpenURL:currentURL]) {
        [[UIApplication sharedApplication] openURL:currentURL options:@{} completionHandler:nil];
    }
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    _toolbarWasHidden = self.navigationController.toolbarHidden;
    [self.navigationController setToolbarHidden:NO animated:YES];

    // Force navigation bar to use opaque app theme colors
    UINavigationBarAppearance *navAppearance = [[UINavigationBarAppearance alloc] init];
    [navAppearance configureWithOpaqueBackground];
    navAppearance.backgroundColor = ICBackgroundColor;
    navAppearance.titleTextAttributes = @{ NSForegroundColorAttributeName : [ICAppearanceManager sharedManager].appearance.textColor };
    navAppearance.shadowColor = nil;
    self.navigationController.navigationBar.standardAppearance = navAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navAppearance;
    self.navigationController.navigationBar.compactAppearance = navAppearance;

    // Force toolbar to use opaque app theme colors
    UIToolbarAppearance *toolbarAppearance = [[UIToolbarAppearance alloc] init];
    [toolbarAppearance configureWithOpaqueBackground];
    toolbarAppearance.backgroundColor = ICBackgroundColor;
    toolbarAppearance.shadowColor = nil;
    self.navigationController.toolbar.standardAppearance = toolbarAppearance;
    self.navigationController.toolbar.scrollEdgeAppearance = toolbarAppearance;
    self.navigationController.toolbar.compactAppearance = toolbarAppearance;

    // Bottom inset so content can scroll past the toolbar (avoids blocking cookie banners)
    [self setScrollView:self.webView.scrollView contentInsets:UIEdgeInsetsMake(0, 0, 44, 0) byAdjustingForStandardBars:YES];
    [self _updateToolbar];
}


- (void) viewWillDisappear:(BOOL)animated
{
    // Restore default navigation bar appearance for other view controllers
    self.navigationController.navigationBar.standardAppearance = nil;
    self.navigationController.navigationBar.scrollEdgeAppearance = nil;
    self.navigationController.navigationBar.compactAppearance = nil;
    self.navigationController.toolbar.standardAppearance = nil;
    self.navigationController.toolbar.scrollEdgeAppearance = nil;
    self.navigationController.toolbar.compactAppearance = nil;

    [self.navigationController setToolbarHidden:_toolbarWasHidden animated:YES];

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
    BOOL loading = (_loading > 0);

    NSMutableArray* items = [NSMutableArray array];

    if ([self.webView canGoBack]) {
        [items addObject:self.backItem];
        [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    }

    if ([self.webView canGoForward]) {
        [items addObject:self.forwardItem];
        [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    }

    if (loading) {
        [(UIActivityIndicatorView*)(self.activityItem.customView) startAnimating];
        [items addObject:self.activityItem];
    } else {
        [(UIActivityIndicatorView*)(self.activityItem.customView) stopAnimating];
        [items addObject:self.reloadItem];
    }

    [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    self.actionItem.enabled = (!self.failed);
    [items addObject:self.actionItem];

    [self setToolbarItems:items];
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
        [self performSelector:@selector(popAfterDelay) withObject:nil afterDelay:0.5];
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
    [self performSelector:@selector(popAfterDelay) withObject:nil afterDelay:0.5];
    self.closed = YES;
}


- (void) popAfterDelay
{
	[self.navigationController popViewControllerAnimated:YES];
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
