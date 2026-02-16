    //
//  DirectoryFeedViewController.m
//  Instacast
//
//  Created by Martin Hering on 17.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>

#import "ICFeedURLScraper.h"
#import "NSString+ICParser.h"
#import "ICFeedParser.h"
#import "ICPagedFeedParser.h"

#import "DirectoryFeedViewController.h"
#import "UIImageView+BorderedImage.h"

#import "VDModalInfo.h"
#import "PlaybackViewController.h"
#import "PlayerController.h"
#import "UIViewController+ShowNotes.h"
#import "ICImageCacheOperation.h"


static NSString* kDefaultImportedEpisodesHintShown = @"DefaultImportedEpisodesHintShown";


@interface DirectoryFeedViewController () <ICFeedURLScraperDelegate>
@property (nonatomic, strong) ICFeed* feed;
@property (nonatomic, strong) WKWebView* webView;
@property (nonatomic, strong) UIImageView* backgroundImageView;
@property (nonatomic, strong) VDModalInfo* loadingInfo;
@property (nonatomic, strong) ICFeedURLScraper* scraper;
@property (nonatomic, strong) ICFeedParser* feedParser;
@property (nonatomic, strong) UIButton* updateButton;
@property (nonatomic, strong) UIImageView* feedImageView;
@property (nonatomic, strong) NSArray* otherPodcasts;
@property (nonatomic) BOOL loaded;
@property (nonatomic) NSInteger initialScrollPosition;
@property (nonatomic, strong) UIView* webShadowView;
@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* authorLabel;
@property (nonatomic) NSUInteger webContentGeneration;

@end


@implementation DirectoryFeedViewController


+ (DirectoryFeedViewController*) directoryFeedViewController
{
	return [[self alloc] initWithNibName:nil bundle:nil];
}

- (id) initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if ((self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]))
    {
    }
    return self;
}

- (void)dealloc
{
    _webView.navigationDelegate = nil;
    [_scraper cancel];
    [_feedParser cancel];
}

- (NSString*)_webViewHTMLForFeed:(ICFeed*)feed retina:(BOOL)retina
{
    NSLocale* locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US".ls];
    
    NSString* description = ([feed.summary length] > [feed.textDescription length]) ? feed.summary : feed.textDescription;
    
    NSMutableString* content = [NSMutableString string];
    [content appendString:@"<style type=\"text/css\" scoped>"];
    NSString* appearanceCssPath = [[NSBundle mainBundle] pathForResource:[ICAppearanceManager sharedManager].appearance.cssFile ofType:@"css"];
    NSString* appearanceCss = [NSString stringWithContentsOfFile:appearanceCssPath encoding:NSUTF8StringEncoding error:nil];
    [content appendString:appearanceCss];
    [content appendString:@"</style>"];
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone )
    {
        [content appendString:@"<header><meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no'></header>"];
    }
    else
    {
        [content appendString:@"<header><meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no'></header>"];
    }
        
    [content appendString:@"<div id=\"description\">"];
    if ( ([description length] > 0)) {
        [content appendString:description];
    }
    [content appendString:@"<table>"];
    
    if (feed.title) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Title".ls, feed.title];
    }
    
    if (feed.subtitle && ![feed.subtitle isEqualToString:feed.title] && ![feed.subtitle isEqualToString:description]) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Subtitle".ls, feed.subtitle];
    }
    
    
    NSArray* categories = feed.categories;
    if ([categories count] > 0)
    {
        NSInteger catNum = 0;
        for(ICCategory* category in categories) {
            NSString* catString = nil;
            ICCategory* parentCategory = category.parent;
            if (parentCategory) {
                catString = [NSString stringWithFormat:@"%@ <div class=\"category_arrow\">\u203A</div> %@", parentCategory.title, category.title];
            } else {
                catString = category.title;
            }
            
            [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", (catNum==0) ? @"Genre".ls : @"", catString];
            catNum++;
        }
    }
    
    if ([feed.language length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Language".ls, [locale displayNameForKey:NSLocaleLanguageCode value:feed.language]];
    }
    if ([feed.country length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Country".ls, [locale displayNameForKey:NSLocaleCountryCode value:feed.country]];
    }
    if ([feed.copyright length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Copyright".ls, feed.copyright];
    }
    if ([feed.owner length] > 0 && [feed.ownerEmail length] > 0) {
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\"><a href=\"mailto:%@\">%@</a></td></tr>", @"Owner".ls, feed.ownerEmail, feed.owner];
    }
    
    [content appendString:@"</table>"];
    [content appendString:@"</div>"];
    
    [content appendString:@"<div id=\"other_podcasts_container\" style=\"display: none;\">"];
    [content appendFormat:@"<div class=\"label\">%@</div>", [NSString stringWithFormat:@"Other Podcasts by %@".ls, feed.author]];
    [content appendString:@"<div id=\"other_podcasts\">"];
    [content appendString:@"</div>"];
    [content appendString:@"</div>"];
    
    [content appendString:@"<div id=\"episodes_list\">"];
    [content appendFormat:@"<div class=\"label\">%@</div>", [NSString stringWithFormat:@"%d Episodes".ls, [feed.episodes count]]];
    [content appendString:@"</div>"];
    
    NSArray* sortedEpisodes = [feed.episodes sortedArrayUsingSelector:@selector(compare:)];
    if ([sortedEpisodes count] > 0) {
        [content appendString:@"<table id=\"episodes\" cellpadding=\"0\" cellspacing=\"0\" border=\"0\">"];
    }
    
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    NSInteger thisYear = [[[NSCalendar currentCalendar] components:NSCalendarUnitYear fromDate:[NSDate date]] year];
    
    [sortedEpisodes enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop)
     {
         ICEpisode* episode = (ICEpisode*)obj;
         NSString* cleanTitle = [episode cleanTitleUsingFeedTitle:feed.title];
         
         NSInteger pubYear = [[[NSCalendar currentCalendar] components:NSCalendarUnitYear fromDate:episode.pubDate] year];
         
         if (pubYear == thisYear) {
             [formatter setDateFormat:@"MMM d".ls];
         } else {
             [formatter setDateFormat:@"MMM d, yy".ls];
         }
         
         [content appendFormat:@"<tr><td><a href=\"delegate://play-episode/%lu\"><div id=\"episodes-row-%ld\" class=\"row %@\"><div class=\"%@\">%@</div><div class=\"%@\">%@</div></div></a></td></tr>",
          (unsigned long)idx,
          (unsigned long)idx,
          (idx % 2 == 0) ? @"even" : @"odd",
          (episode.video) ? @"title_video": @"title_audio",
          cleanTitle,
          (episode.video) ? @"date_video": @"date",
          [formatter stringFromDate:episode.pubDate]
          ];
     }];

    [content appendString:@"</table>"];
    
    if (feed.firstPageURL != feed.lastPageURL) {
        [content appendFormat:@"<div id=\"load_more\" ontouchstart=""><a href=\"delegate://load-more-episodes\">%@</a></div>", @"Load older episodes…".ls];
    }
    
    if ([sortedEpisodes count] > 0) {
        [content appendString:@"<script>"];
        [content appendString:@"var ctr = document.getElementById('episodes');"];
        [content appendString:@"ctr.addEventListener('touchstart', onTouchStartTable, false);"];
        [content appendString:@"ctr.addEventListener('touchend', onTouchEndTable, false);"];
        [content appendString:@"ctr.addEventListener('touchmove', onTouchMoveTable, false);"];
        [content appendString:@"ctr.addEventListener('touchcancel', onTouchCancelTable, false);"];
        [content appendString:@"</script>"];
    }
    
    
    
    //NSString* templateName = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) ? @"InfoDescriptionTemplateIPad" : @"InfoDescriptionTemplateIPhone";
    
    NSString* templatePath = [[NSBundle mainBundle] pathForResource:@"InfoDescriptionTemplateIPhone" ofType:@"html"];
    
    //NSString* templatePath = [[NSBundle mainBundle] pathForResource:templateName ofType:@"html"];
    NSString* infoHTMLTemplate = [NSString stringWithContentsOfFile:templatePath encoding:NSUTF8StringEncoding error:nil];
    
    NSString* htmlContent = [infoHTMLTemplate stringByReplacingOccurrencesOfString:@"###CONTENT###" withString:content];
    
    NSString* buttons = @"";
    htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"###BUTTONS###" withString:buttons];
    
    NSString* videoPath = [[NSBundle mainBundle] pathForResource:(retina)?@"tv@2x":@"tv" ofType:@"png"];
    NSURL* videoURL = (videoPath) ? [NSURL fileURLWithPath:videoPath] : nil;
    htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"###VIDEO_IMAGE_URL###" withString:[videoURL absoluteString]];
    
    NSString* importImagePath = [[NSBundle mainBundle] pathForResource:(retina)?@"import-episode@2x":@"import-episode" ofType:@"png"];
    NSURL* importImageURL = (importImagePath) ? [NSURL fileURLWithPath:importImagePath] : nil;
    htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"###IMPORT_EPISODE_IMAGE_URL###" withString:[importImageURL absoluteString]];
    
    NSString* videoPathH = [[NSBundle mainBundle] pathForResource:(retina)?@"tv@2x":@"tv" ofType:@"png"];
    NSURL* videoURLH = (videoPathH) ? [NSURL fileURLWithPath:videoPathH] : nil;
    htmlContent = [htmlContent stringByReplacingOccurrencesOfString:@"###VIDEO_SELECTED_IMAGE_URL###" withString:[videoURLH absoluteString]];
    return htmlContent;
}

- (void) _loadWebViewContent
{
    if (!self.feed || !self.webView) {
        return;
    }

    ICFeed* feed = self.feed;
    BOOL retina = ([[[self.view window] screen] scale] > 1);
    NSUInteger generation = ++self.webContentGeneration;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString* htmlContent = [self _webViewHTMLForFeed:feed retina:retina];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.webContentGeneration || self.feed != feed || !self.webView) {
                return;
            }

            [self.webView setOpaque:NO];
            self.webView.backgroundColor = [UIColor clearColor];
            [self.webView loadHTMLString:htmlContent baseURL:nil];
        });
    });
}

- (void) _prepareViewWhenFeedLoaded
{
    UIBarButtonItem* subscribeBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Add"]
                                                                               style:UIBarButtonItemStylePlain
                                                                              target:self
                                                                              action:@selector(subscribeAction:)];
    
    CDFeed* feed = [DMANAGER feedWithSourceURL:self.feed.sourceURL];
    if (!feed) {
        feed = [DMANAGER feedWithSourceURL:self.feed.changedSourceURL];
    }
    
	if (feed && !feed.parked)
    {
        subscribeBarButtonItem.enabled = NO;
	}
    [self.navigationItem setRightBarButtonItem:subscribeBarButtonItem animated:YES];
    
	if (self.feed)
	{
        CGRect bounds = CGRectMake(10, self.view.bounds.origin.y + 10, self.view.bounds.size.width-20, self.view.bounds.size.height - 10);//self.view.bounds;
        CGFloat contentWidth = CGRectGetWidth(bounds);
        (void)contentWidth; // Used in HTML generation below
        
        if (!self.webView)
        {
            WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
            config.preferences.minimumFontSize = 10;
            WKWebView* webView = [[WKWebView alloc] initWithFrame:bounds configuration:config];
            [webView setOpaque:NO];
            webView.backgroundColor = [UIColor clearColor];
            webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            webView.navigationDelegate = self;
            webView.hidden = YES;
            
            UIEdgeInsets safeAreaInsets = UIEdgeInsetsMake(20, 0, 0, 0);
            if (@available(iOS 11.0, *)) {
                safeAreaInsets = self.view.safeAreaInsets;
            }
            
           // [self setScrollView:webView.scrollView contentInsets:UIEdgeInsetsMake(safeAreaInsets.top + 72+15, 0, safeAreaInsets.bottom, 0) byAdjustingForStandardBars:YES];
            
            [self.view addSubview:webView];
            self.webView = webView;
            
            CGFloat topOffset = 74;
            self.webView.scrollView.contentInset = UIEdgeInsetsMake(topOffset, 0, 44, 0);
            self.webView.scrollView.scrollIndicatorInsets = UIEdgeInsetsMake(topOffset, 0, 44, 0);
            self.webView.scrollView.contentOffset = CGPointMake(0, -self.webView.scrollView.contentInset.top);
            self.webView.scrollView.showsHorizontalScrollIndicator = false;
            
            UIView* webShadowView = [[UIView alloc] initWithFrame:CGRectMake(0,  safeAreaInsets.top, self.view.bounds.size.width, 72+15)];
            webShadowView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
            [self.view addSubview:webShadowView];
            self.webShadowView = webShadowView;

            
            self.feedImageView = [[UIImageView alloc] initWithFrame:CGRectMake(15, 7, 74, 74)];
            [webShadowView addSubview:self.feedImageView];
            
            self.feedImageView.image = [UIImage imageNamed:@"Podcast Placeholder 72"];
            
            ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
            [iman imageForURL:self.feed.imageURL size:72 grayscale:NO sender:self completion:^(UIImage *image) {
                if (image) {
                    self.feedImageView.image = image;
                }
            }];
            
            // create title label
            UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
            titleLabel.numberOfLines = 2;
            titleLabel.text = self.feed.title;
            titleLabel.font = [UIFont systemFontOfSize:17.0f];
            titleLabel.backgroundColor = [UIColor clearColor];
            titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
            [webShadowView addSubview:titleLabel];
            self.titleLabel = titleLabel;
            
            // create author label
            UILabel* authorLabel = [[UILabel alloc] initWithFrame:CGRectZero];
            authorLabel.numberOfLines = 2;
            authorLabel.text = self.feed.author;
            authorLabel.font = [UIFont systemFontOfSize:13.0f];
            authorLabel.backgroundColor = [UIColor clearColor];
            authorLabel.lineBreakMode = NSLineBreakByWordWrapping;
            
            CGSize titleSize = [titleLabel.attributedText boundingRectWithSize:CGSizeMake(contentWidth-72-45, 100) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
            IC_SIZE_INTEGRAL(titleSize);
            
            CGSize authorSize = [authorLabel.attributedText boundingRectWithSize:CGSizeMake(contentWidth-72-45, 100) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
            IC_SIZE_INTEGRAL(authorSize);
            
            CGFloat labelsHeight = titleSize.height + authorSize.height + 2;
            CGFloat yOffset = floorf((72-labelsHeight)/2);
            
            titleLabel.frame = CGRectMake(72+15+15, yOffset, contentWidth-72-30-15, titleSize.height);
            authorLabel.frame = CGRectMake(72+15+15, CGRectGetMaxY(titleLabel.frame)+2, contentWidth-72-30-15, authorSize.height);
            
            [webShadowView addSubview:authorLabel];
            self.authorLabel = authorLabel;

            // create toolbar items
            UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
            UIBarButtonItem* actionItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                         target:self
                                                                                         action:@selector(actionAction:)];

            [self setToolbarItems:[NSArray arrayWithObjects:flexSpace, actionItem, nil] animated:NO];
            
            self.view.backgroundColor = ICBackgroundColor;
            self.webView.backgroundColor = ICBackgroundColor;
            self.webView.scrollView.backgroundColor = ICBackgroundColor;
            self.webShadowView.backgroundColor = ICTransparentBackdropColor;
            self.titleLabel.textColor = ICTextColor;
            self.authorLabel.textColor = ICMutedTextColor;
		}
        
        [self _loadWebViewContent];
	}
}


- (void) _showLoadingDialog:(BOOL)show
{
    if (show)
    {
        VDModalInfo* loadingInfo = [VDModalInfo modalInfoWithProgressLabel:@"Loading…".ls];
		loadingInfo.navigationAndToolbarEnabled = YES;
		[loadingInfo show];
        self.loadingInfo = loadingInfo;
    }
    else
    {
        [self.loadingInfo close];
        self.loadingInfo = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

    [self.webView scrollView].delegate = self;
    
    if (self.canBeCanceled) {
        UIBarButtonItem* subscribeBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelAction:)];
        self.navigationItem.leftBarButtonItem = subscribeBarButtonItem;
    }
}

- (void) updateAppearance
{
    self.view.backgroundColor = ICBackgroundColor;
    self.webView.backgroundColor = ICTransparentBackdropColor;
    self.webView.scrollView.backgroundColor = ICTransparentBackdropColor;
    self.webShadowView.backgroundColor = ICTransparentBackdropColor;
    self.titleLabel.textColor = ICTextColor;
    self.authorLabel.textColor = ICMutedTextColor;
    [self _loadWebViewContent];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    self.view.backgroundColor = ICBackgroundColor;
    self.webView.backgroundColor = ICTransparentBackdropColor;
    self.webView.scrollView.bounces = NO;
    self.webView.scrollView.backgroundColor = ICTransparentBackdropColor;
    self.webShadowView.backgroundColor = ICTransparentBackdropColor;
    self.titleLabel.textColor = ICTextColor;
    self.authorLabel.textColor = ICMutedTextColor;

    [self _loadWebViewContent];
}

- (void) viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
    	
	if (self.scraper) {
		[App releaseNetworkActivity];
		[self.scraper cancel];
	}
	
	if (self.feedParser) {
		[App releaseNetworkActivity];
		[self.feedParser cancel];
	}
	
	[self.loadingInfo close];
	self.loadingInfo = nil;
	    
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
}


#pragma mark - Loading

- (void) startLoading
{
    if (self.feed) {
		[self _prepareViewWhenFeedLoaded];
	}
	
	else if (self.itunesURL)
	{
        [self _showLoadingDialog:YES];
		[self performSelector:@selector(_startParsingITunesURL:) withObject:self.itunesURL afterDelay:0.3];
	}
	
	else if (self.feedURL)
	{
		[self _showLoadingDialog:YES];
		[self performSelector:@selector(_startParsingFeedURL:) withObject:self.feedURL afterDelay:0.3];
	}
}

- (void) _presentParserError:(NSError*)error
{
    return;
    
    if (error) {
        [self presentError:error];
    }
    
    [self perform:^(id sender) {
        [self.navigationController popViewControllerAnimated:YES];
    } afterDelay:0.2];
}

- (void) _startParsingITunesURL:(NSURL*)url
{
	[App retainNetworkActivity];
	self.scraper = [ICFeedURLScraper feedURLScraperWithURL:url];
	self.scraper.delegate = self;
	[[App mainQueue] addOperation:self.scraper];
}

- (void) _startParsingFeedURL:(NSURL*)url
{
	[App retainNetworkActivity];

    ICFeedParser* parser = [[ICFeedParser alloc] init];
    parser.url = url;
    parser.didParseFeedBlock = ^(ICFeed* feed) {
        [App releaseNetworkActivity];
        
        self.feedParser = nil;
        
        [self _showLoadingDialog:NO];
        
        self.feed = feed;
        
        [self _prepareViewWhenFeedLoaded];
        
        if (self.didLoadFeed) {
            self.didLoadFeed(YES, nil);
        }

    };
    parser.didEndWithError = ^(NSError* error) {

        [App releaseNetworkActivity];
        
        ErrLog(@"feed could not be parsed: %@", [error description]);
        self.feedParser = nil;
        
        [self _showLoadingDialog:NO];
        
        if (self.didLoadFeed) {
            self.didLoadFeed(NO, error);
        }
        
        [self _presentParserError:error];
    };
    
    self.feedParser = parser;
	[[App mainQueue] addOperation:self.feedParser];
}

- (NSUInteger) feedParser:(ICFeedParser*)feedParser shouldSwitchOneOfTheAlternativeFeeds:(NSArray*)alternativeFeeds feed:(ICFeed*)feed;
{
    return NSNotFound;
}

- (void) feedURLScraper:(ICFeedURLScraper*)scraper didScrapeFeedURL:(NSURL*)url
{
	[App releaseNetworkActivity];
    self.feedURL = url;
    [self _startParsingFeedURL:url];
}

- (void) feedURLScraper:(ICFeedURLScraper*)scraper didEndWithError:(NSError*)error
{
	[App releaseNetworkActivity];
	
	ErrLog(@"feedURLScraper error %@", [error description]);
	[self _showLoadingDialog:NO];
	
    if (self.didLoadFeed) {
        self.didLoadFeed(NO, error);
    }
    
    [self _presentParserError:error];
}




#pragma mark -


- (void) actionAction:(id)sender
{
	if (self.feed.linkURL) {
		[[UIApplication sharedApplication] openURL:self.feed.linkURL options:@{} completionHandler:nil];
	}
}

- (void) subscribeFeed:(ICFeed*)feed andDismissViewController:(UIViewController*)viewController byPopping:(BOOL)popping
{
    VDModalInfo* subscribingModelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Subscribing…"];
    [subscribingModelInfo showWithCompletion:^{

        if (feed.changedSourceURL) {
            feed.sourceURL = feed.changedSourceURL;
        }

        CDFeed* subscribedFeed = [DMANAGER feedWithSourceURL:feed.sourceURL];

        if (subscribedFeed) {
            subscribedFeed.parked = NO;
            [DMANAGER save];
            [[SubscriptionManager sharedSubscriptionManager] reloadContentOfFeed:subscribedFeed recoverArchivedEpisodes:YES completion:^(BOOL success, NSArray* newEpisodes, NSError* error) {

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) {
                        [self presentError:error];
                    }

                    [subscribingModelInfo closeWithCompletion:^{

                        if (!viewController) {
                            return;
                        }

                        if (popping) {
                            [viewController.navigationController dismissViewControllerAnimated:YES completion:^{
                                [[NSNotificationCenter defaultCenter] postNotificationName:DatabaseManagerDidUpdateObservedFeedNotification object:nil];
                            }];
                        } else {
                            [viewController dismissViewControllerAnimated:YES completion:^{ }];
                        }
                    }];
                });

            }];
        }
        else
        {
            CDFeed* subscribedFeed = [[SubscriptionManager sharedSubscriptionManager] subscribeParserFeed:feed autodownload:YES options:kSubscribeOptionNone];
            subscribedFeed.parked = NO;

            [subscribingModelInfo closeWithCompletion:^{

                if (!viewController) {
                    return;
                }

                if (popping) {
                    [viewController.navigationController dismissViewControllerAnimated:YES completion:^{
                        [[NSNotificationCenter defaultCenter] postNotificationName:DatabaseManagerDidUpdateObservedFeedNotification object:nil];
                    }];
                } else {
                    [viewController dismissViewControllerAnimated:YES completion:^{ }];
                }
            }];
        }
    }];
}


- (void) subscribeAction:(id)sender
{
	self.navigationItem.rightBarButtonItem.enabled = NO;
    [self subscribeFeed:self.feed andDismissViewController:self byPopping:self.shouldPopBackToList];
}

- (void) cancelAction:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:NO];
}

#pragma mark WebView Delegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    
    NSURL* url = [navigationAction.request URL];
    
    if ([[url scheme] isEqualToString:@"delegate"])
    {
        NSString* command = [url host];
        
        
        if ([command isEqualToString:@"load-more-episodes"])
        {
            [self.webView evaluateJavaScript:@"scrollY" completionHandler:^(id result, NSError * _Nullable error) {
                if (error == nil) {
                    self.initialScrollPosition = [result integerValue];
                }
            
            }];
            
            [self _showLoadingDialog:YES];
            
            ICPagedFeedParser* parser = [[ICPagedFeedParser alloc] init];
            parser.url = self.feed.sourceURL;
            parser.username = self.feed.username;
            parser.password = self.feed.password;
            parser.allowsCellularAccess = [USER_DEFAULTS boolForKey:EnableRefreshingOver3G];
            
            parser.didParsePage = ^(NSInteger page) {
                self.loadingInfo.textLabel.text = [NSString stringWithFormat:@"Page %ld".ls, page];
            };
            
            parser.didParseFeedBlock = ^(ICFeed* parserFeed) {
                self.feed = parserFeed;
                [self _prepareViewWhenFeedLoaded];
                [self _showLoadingDialog:NO];
            };
            
            parser.didEndWithError = ^(NSError* error) {
                [self _showLoadingDialog:NO];
            };
            
            [[App mainQueue] addOperation:parser];
        }
        
        else if ([command isEqualToString:@"play-episode"])
        {
            NSInteger index = [[[url path] lastPathComponent] integerValue];
            NSArray* sortedEpisodes = [self.feed.episodes sortedArrayUsingSelector:@selector(compare:)];
            ICEpisode* episode = [sortedEpisodes objectAtIndex:index];

            CDEpisode* persistentEpisode = [DMANAGER addUnsubscribedFeed:self.feed andEpisode:episode];
            
            PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:persistentEpisode];
            PlayerController* playerController = [playbackController.viewControllers objectAtIndex:0];
            playerController.backgroundPlayback = NO;
            playbackController.fromSearch = YES;
            [playbackController presentFromParentViewController:self];
            
            [[AudioSession sharedAudioSession] disableContinuousPlaybackForCurrentEpisode];
        }
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.loaded = YES;
    
    [self perform:^(id sender) {
        for(UIView* subview in self.view.subviews) {
            subview.hidden = NO;
        }
    } afterDelay:0.2];
}


@end
