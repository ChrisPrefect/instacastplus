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
	_webView.navigationDelegate = nil;
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
    self.webView.backgroundColor = ICBackgroundColor;
    self.webView.scrollView.backgroundColor = ICBackgroundColor;
    self.webView.underPageBackgroundColor = ICBackgroundColor;

	[self.view addSubview:self.webView];

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

    // Initial toolbar
    UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    [self setToolbarItems:@[flexSpace, self.actionItem]];
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
    [self.navigationController setToolbarHidden:NO animated:YES];
    [self _updateToolbar];
}

- (void) viewWillDisappear:(BOOL)animated
{
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
