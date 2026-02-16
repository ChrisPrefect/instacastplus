    //
//  FeedViewController.m
//  Instacast
//
//  Created by Martin Hering on 10.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <MediaPlayer/MediaPlayer.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <QuartzCore/QuartzCore.h>

#import "FeedViewController.h"

#import "ICShareItem.h"
#import "UIViewController+ShowNotes.h"
#import "VDModalInfo.h"
#import "FeedSettingsViewController.h"
#import "CDModel.h"
#import "CDFeed+Helper.h"
#import "PortraitNavigationController.h"
#import "ICFeedHeaderViewController.h"

#import "SubscriptionManager.h"
#import "InstacastAppDelegate.h"

@interface FeedViewController () <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView* webView;
@property (nonatomic, strong) VDModalInfo* modalInfo;
@property (nonatomic, strong) UIBarButtonItem* actionItem;
@property (nonatomic, strong) UIBarButtonItem* reloadItem;
@property (nonatomic, strong) ICFeedHeaderViewController* headerViewController;
@end


@implementation FeedViewController


+ (FeedViewController*) feedViewController
{
	return [[self alloc] initWithNibName:nil bundle:nil];
}

- (void) _loadContent
{
    NSLocale* locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US".ls];

    NSString* description = ([self.feed.summary length] > [self.feed.fulltext length]) ? self.feed.summary : self.feed.fulltext;

    NSMutableString* content = [NSMutableString string];

    [content appendString:@"<header><meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no'></header>"];

    [content appendString:@"<style type=\"text/css\" scoped>"];
    NSString* appearanceCssPath = [[NSBundle mainBundle] pathForResource:[ICAppearanceManager sharedManager].appearance.cssFile ofType:@"css"];
    NSString* appearanceCss = [NSString stringWithContentsOfFile:appearanceCssPath encoding:NSUTF8StringEncoding error:nil];
    [content appendString:appearanceCss];
    [content appendString:@"</style>"];
    [content appendString:@"<div id=\"description\">"];
    if (description) {
        [content appendString:description];
    }
    [content appendString:@"<table>"];

    if ([self.feed.title length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Title".ls, self.feed.title];
    }

    if ([self.feed.subtitle length] > 0 && ![self.feed.subtitle isEqualToString:self.feed.title] && ![self.feed.subtitle isEqualToString:description]) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Subtitle".ls, self.feed.subtitle];
    }

    NSSet* categories = self.feed.categories;
    if ([categories count] > 0) {
        NSInteger catNum = 0;
        for(CDCategory* category in categories) {
            NSString* catString = nil;
            CDCategory* parentCategory = category.parent;
            if (parentCategory) {
                catString = [NSString stringWithFormat:@"%@ <div class=\"category_arrow\">\u203A</div> %@", parentCategory.title.ls, category.title.ls];
            } else {
                catString = category.title.ls;
            }
            [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", (catNum==0) ? @"Genre".ls : @"", catString];
            catNum++;
        }
    }

    if ([self.feed.language length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Language".ls, [locale displayNameForKey:NSLocaleLanguageCode value:self.feed.language]];
    }
    if ([self.feed.country length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Country".ls, [locale displayNameForKey:NSLocaleCountryCode value:self.feed.country]];
    }
    if (self.feed.linkURL) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\"><a href=\"%@\">%@</a></td></tr>", @"Website".ls, [self.feed.linkURL absoluteString], [self.feed.linkURL absoluteString]];
    }
    if ([self.feed.copyright length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Copyright".ls, self.feed.copyright];
    }
    if ([self.feed.owner length] > 0 && [self.feed.ownerEmail length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\"><a href=\"mailto:%@\">%@</a></td></tr>", @"Owner".ls, self.feed.ownerEmail, self.feed.owner];
    }
#ifdef DEBUG
    if (self.feed.sourceURL) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">Feed</td><td valign=\"top\">%@</td></tr>", [self.feed.sourceURL absoluteString]];
    }
#endif

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateStyle:NSDateFormatterLongStyle];
    [formatter setTimeStyle:NSDateFormatterShortStyle];
    NSString* lastUpdateStr = [formatter stringFromDate:self.feed.lastUpdate];
    [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Updated".ls, lastUpdateStr];

    [content appendString:@"</table></div>"];

    NSString* templatePath = [[NSBundle mainBundle] pathForResource:@"InfoDescriptionTemplateIPhone" ofType:@"html"];
    NSString* infoHTMLTemplate = [NSString stringWithContentsOfFile:templatePath encoding:NSUTF8StringEncoding error:nil];

    NSString* htmlContent = [infoHTMLTemplate stringByReplacingOccurrencesOfString:@"###CONTENT###" withString:content];
    htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"###BUTTONS###" withString:@""];

    [self.webView setOpaque:NO];
    self.webView.backgroundColor = [UIColor clearColor];
    [self.webView loadHTMLString:htmlContent baseURL:nil];
}

- (void) _updateToolbarAnimated:(BOOL)animated
{
    UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    // reload item
    self.reloadItem = [[UIBarButtonItem alloc] initWithTitle:@"Reload".ls
                                                       style:UIBarButtonItemStylePlain target:self action:@selector(reloadAction:)];

    // share item
    self.actionItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                    target:self action:@selector(actionAction:)];

    UIBarButtonItem* settingsItem = [[UIBarButtonItem alloc] initWithTitle:@"Settings".ls
                                                                     style:UIBarButtonItemStylePlain target:self action:@selector(settingsAction:)];

    UIBarButtonItem* fixItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixItem.width = -1;

    [self setToolbarItems:@[fixItem, self.reloadItem, flexSpace, self.actionItem, flexSpace, settingsItem, fixItem] animated:animated];

}


// Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
- (void)viewDidLoad {
    [super viewDidLoad];

    self.navigationItem.title = @"Podcast Info".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
    

	if (self.feed)
	{
        UINavigationBar* navBar = self.navigationController.navigationBar;
        CGRect b = self.view.bounds;
        b.origin.y = 93 + CGRectGetMaxY(navBar.frame) ;
        WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
        //config.preferences.minimumFontSize = 25;
        WKWebView* webView = [[WKWebView alloc] initWithFrame:b configuration:config];
        [webView setOpaque:NO];
        webView.backgroundColor = [UIColor clearColor];
        webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		webView.navigationDelegate = self;
		[self.view addSubview:webView];
        self.webView = webView;
        
        self.webView.scrollView.showsHorizontalScrollIndicator = false;
        
        self.headerViewController = [ICFeedHeaderViewController viewController];
        self.headerViewController.view.frame = CGRectMake(0, CGRectGetMaxY(navBar.frame), CGRectGetWidth(b), 93);
        self.headerViewController.titleLabel.text = self.feed.title;
        self.headerViewController.subtitleLabel.text = self.feed.author;
        
        __weak FeedViewController* weakSelf = self;
        ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
        [iman imageForURL:self.feed.imageURL size:72 grayscale:NO sender:self completion:^(UIImage *image) {
            if (image) {
                weakSelf.headerViewController.imageView.image = image;
            }
        }];
        
        [self addChildViewController:self.headerViewController];
        [self.view addSubview:self.headerViewController.view];
        [self.headerViewController didMoveToParentViewController:self];
	}
}



- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self setScrollView:self.webView.scrollView contentInsets:UIEdgeInsetsMake(93, 0, 0, 0) byAdjustingForStandardBars:YES];

    self.webView.scrollView.contentInset = UIEdgeInsetsMake(0, 0, 50, 0);

    self.view.backgroundColor = ICBackgroundColor;
    self.webView.backgroundColor = ICBackgroundColor;
    self.webView.scrollView.backgroundColor = ICBackgroundColor;

    [self _loadContent];

    [self _updateToolbarAnimated:YES];
    [self.navigationController setToolbarHidden:NO animated:YES];
}

-(void) updateAppearance {
    self.view.backgroundColor = ICBackgroundColor;
    self.webView.backgroundColor = ICBackgroundColor;
    self.webView.scrollView.backgroundColor = ICBackgroundColor;

    [self _loadContent];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark -


- (void) unsubscribeAction:(id)sender
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Are you sure you want to unsubscribe '%@'?".ls, self.feed.title]
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Unsubscribe".ls style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * action) {
                                                              STRONG_SELF
                                                              
                                                              [self perform:^(id sender) {
                                                                  if ([[AudioSession sharedAudioSession].episode.feed isEqual:self.feed]) {
                                                                      [[AudioSession sharedAudioSession] stop];
                                                                  }
                                                                  
                                                                  [[CacheManager sharedCacheManager] removeCacheForFeed:self.feed automatic:NO];
                                                                  [DMANAGER unsubscribeFeed:self.feed];
                                                                  
                                                                  [self.navigationController popToRootViewControllerAnimated:YES];
                                                              } afterDelay:0.3];
                                                              
                                                              self.alertController = nil;
                                                          }];
    [alert addAction:defaultAction];
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction * action) {
                                                              STRONG_SELF
                                                              self.alertController = nil;
                                                          }];
    [alert addAction:cancelAction];
    [alert setModalPresentationStyle:UIModalPresentationPopover];
    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    UIViewController* rootViewController = [(InstacastAppDelegate*)[[UIApplication sharedApplication]delegate] getRootViewControllerDev];
    popPresenter.sourceView = [rootViewController view];
    popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
    popPresenter.permittedArrowDirections = 0;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.alertController = alert;
    [self presentAlertControllerAnimated:YES completion:NULL];
}

- (void) actionAction:(id)sender
{
    if (self.feed.username.length > 0)
    {
        WEAK_SELF
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Share podcast with login credentials?".ls
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"With Credentials".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            STRONG_SELF
            NSURLComponents* components = [NSURLComponents componentsWithURL:self.feed.sourceURL resolvingAgainstBaseURL:NO];
            components.scheme = @"podcast";
            components.user = self.feed.username;
            components.password = self.feed.password;
            NSURL* feedURL = components.URL;
            UIImage* feedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:self.feed.imageURL size:72 grayscale:NO];
            ICShareItem* shareItem = [ICShareItem itemWithURL:feedURL title:self.feed.title image:feedImage];
            UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[shareItem] applicationActivities:nil];
            if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
                shareController.popoverPresentationController.barButtonItem = sender;
            }
            [self presentViewController:shareController animated:YES completion:NULL];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Without Credentials".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            STRONG_SELF
            NSURL* feedURL = [self.feed sourceURLAsPcastURL];
            UIImage* feedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:self.feed.imageURL size:72 grayscale:NO];
            ICShareItem* shareItem = [ICShareItem itemWithURL:feedURL title:self.feed.title image:feedImage];
            UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[shareItem] applicationActivities:nil];
            if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
                shareController.popoverPresentationController.barButtonItem = sender;
            }
            [self presentViewController:shareController animated:YES completion:NULL];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];
        if ([ICAppearanceManager sharedManager].nightSettingMode) {
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        } else {
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        }
        [self presentViewController:alert animated:YES completion:NULL];
    }
    else
    {
        NSURL* feedURL = [self.feed sourceURLAsPcastURL];
        UIImage* feedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:self.feed.imageURL size:72 grayscale:NO];
        ICShareItem* shareItem = [ICShareItem itemWithURL:feedURL title:self.feed.title image:feedImage];
        UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[shareItem] applicationActivities:nil];
        if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
            shareController.popoverPresentationController.barButtonItem = sender;
        }
        [self presentViewController:shareController animated:YES completion:NULL];
    }
}

#pragma mark -


- (void) settingsAction:(id)sender
{
    FeedSettingsViewController* viewController = [FeedSettingsViewController feedSettingsViewControllerWithFeed:self.feed];
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:viewController];
    navController.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navController animated:YES completion:^{
        
    }];
}

- (void) _reloadAndRecover:(BOOL)recover
{
    self.modalInfo = [VDModalInfo modalInfoWithProgressLabel:@"Reloading…".ls];
    [self.modalInfo show];
    
    [[SubscriptionManager sharedSubscriptionManager] reloadContentOfFeed:self.feed recoverArchivedEpisodes:recover completion:^(BOOL success, NSArray* newEpisodes, NSError* error) {
        
        if (error) {
            [self presentError:error];
        }
        
        if (App.networkAccessTechnology > kICNetworkAccessTechnlogyGPRS) {
            [[ImageCacheManager sharedImageCacheManager] clearCachedImagesOfFeed:self.feed];
        }
        
        [self.modalInfo close];
        self.modalInfo = nil;
    }];
}

- (void) reloadAction:(id)sender
{
    [self _reloadAndRecover:YES];
}

#pragma mark -

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL* url = [navigationAction.request URL];
	NSString *urlString = [url absoluteString];
	
	if ([[url scheme] isEqualToString:@"delegate"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
	}
    
    // do not allow iframes
    if (navigationAction.navigationType == WKNavigationTypeOther && ![urlString isEqualToString:@"about:blank"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
    }
    
    if ([self handleShowNotesURL:url]) {
        decisionHandler(WKNavigationActionPolicyAllow);
    } else {
        decisionHandler(WKNavigationActionPolicyCancel);
    }
}

@end
