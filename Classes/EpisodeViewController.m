    //
//  EpisodeViewController.m
//  Instacast
//
//  Created by Martin Hering on 12.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//


#import "EpisodeViewController.h"
#import "UIManager.h"
#import "InstacastPlus-Swift.h"
#import "TranscriptionSettingsViewController.h"
#import "AppleWatchSyncManager.h"

#import "InstacastAppDelegate.h"
#import "PlaybackViewController.h"
#import "PlaybackManager.h"
#import "VDModalInfo.h"

#import "UtilityFunctions.h"
#import "CDModel.h"
#import "CDEpisode+ShowNotes.h"

#import "UIViewController+ShowNotes.h"
#import "UtilityFunctions.h"
#import "UIImageView+BorderedImage.h"
#import "EpisodePlayComboButton.h"
#import "ICEpisodeConsumeIndicator.h"
#import "OpenInSafariActivity.h"
#import "InstacastAppDelegate.h"

static NSString* ICGeneratedSummaryForEpisodeHash(NSString* episodeHash)
{
    if (episodeHash.length == 0) {
        return nil;
    }

    NSString* summary = [[ChapterGenerator shared] loadSummaryFor:episodeHash];
    summary = [summary stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return summary.length > 0 ? summary : nil;
}

@interface EpisodeViewController () <UIGestureRecognizerDelegate, UIScrollViewDelegate, WKNavigationDelegate>
@property (nonatomic, strong) CDFeed* feed;
@property (nonatomic, strong) VDModalInfo* modalInfo;
@property (nonatomic, strong) WKWebView* sharedWebView;

// added as subviews to self.view
@property (nonatomic, strong) UIView* headerView;
@property (nonatomic, strong) UIImageView* imageView;

@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* feedTitleLabel;
@property (nonatomic, strong) ICEpisodeConsumeIndicator* consumeIndicator;
@property (nonatomic, strong) UILabel* timeLabel;
@property (nonatomic, strong) UIButton* cacheButton;
@property (nonatomic, strong) UIBarButtonItem* cacheButtonItem;
@property (nonatomic, strong) UIImageView* videoIndicator;
@property (nonatomic, strong) UIView* starredIndicator;

@property (nonatomic, strong) EpisodePlayComboButton* playButton;
@property (nonatomic, strong) UILongPressGestureRecognizer* longPressRecognizer;
@property (nonatomic, strong) id<ICAppearance> appearance;
@end

@implementation EpisodeViewController {
    BOOL _observing;
    BOOL _observingScrollView;
    BOOL _dontReleaseSharedContent;
    CGPoint _scrollOffset;
    BOOL    _dontSaveScrollOffset;
}


+ (EpisodeViewController*) episodeViewController
{
    return [[self alloc] initWithNibName:nil bundle:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self _releaseSharedContent];
    self.episode = nil;
    [self _setObserving:NO];
    [_modalInfo close];
}

- (void) setupWebView {
    WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
    CGRect bTemp = CGRectMake(0, self.headerView.frame.origin.y + self.headerView.frame.size.height, self.view.bounds.size.width, self.view.bounds.size.height - (self.headerView.frame.origin.y + self.headerView.frame.size.height));
    
    self.sharedWebView = [[WKWebView alloc] initWithFrame:bTemp configuration:config];
    [self.sharedWebView setOpaque:NO];
    self.sharedWebView.backgroundColor = [UIColor clearColor];
    self.sharedWebView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.sharedWebView.contentMode = UIViewContentModeScaleAspectFit;
    self.sharedWebView.scrollView.showsHorizontalScrollIndicator = false;
    if (@available(iOS 26.0, *)) {
        self.sharedWebView.scrollView.bottomEdgeEffect.hidden = YES;
    }
    
    NSString* templatePath = [[NSBundle mainBundle] pathForResource:@"ShowNotesTemplateIPhone" ofType:@"html"];
    NSString* infoHTMLTemplate = [NSString stringWithContentsOfFile:templatePath encoding:NSUTF8StringEncoding error:nil];
    NSString* scaledFontSize = [NSString stringWithFormat:@"%.0f", ICFontSize(15)];
    infoHTMLTemplate = [infoHTMLTemplate stringByReplacingOccurrencesOfString:@"###FONT_SIZE###" withString:scaledFontSize];
    [self.sharedWebView loadHTMLString:infoHTMLTemplate baseURL:nil];
//    
//    self.sharedWebView.scrollView.contentInset = UIEdgeInsetsZero;
//    self.sharedWebView.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
//    self.sharedWebView.scrollView.bounces = NO;
}

#pragma mark -

- (NSString*) showNotesAsHTMLIncludingAttributes:(BOOL)attributes
{
    CDFeed* feed = self.episode.feed;
    
    // load webview content
    NSLocale* locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US".ls];
    NSString* description = [self.episode cleanedShowNotes];
    
    NSMutableString* content = [NSMutableString string];
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone )
    {
        [content appendString:@"<header><meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no'></header>"];
    }
    else
    {
        [content appendString:@"<header><meta name='viewport' content='width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no'></header>"];
    }
    
    [content appendString:@"<style type=\"text/css\" scoped>"];
    NSString* appearanceCssPath = [[NSBundle mainBundle] pathForResource:[ICAppearanceManager sharedManager].appearance.cssFile ofType:@"css"];
    NSString* appearanceCss = [NSString stringWithContentsOfFile:appearanceCssPath encoding:NSUTF8StringEncoding error:nil];
    [content appendString:appearanceCss];
    if ([ICAppearanceManager sharedManager].nightSettingMode && [USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
        [content appendString:@"body { background-color: #000000; } #episodes .row_even, #episodes .even { background-color: #000000; }"];
    }
    [content appendString:@"</style>"];

    NSString* generatedSummary = ICGeneratedSummaryForEpisodeHash(self.episode.objectHash);
    if (generatedSummary.length > 0) {
        NSString* heading = [@"KI-Zusammenfassung".ls stringByEncodingStandardHTMLEntities] ?: @"";
        NSString* escapedSummary = [generatedSummary stringByEncodingStandardHTMLEntities] ?: @"";
        escapedSummary = [escapedSummary stringByReplacingOccurrencesOfString:@"\r\n" withString:@"<br>"];
        escapedSummary = [escapedSummary stringByReplacingOccurrencesOfString:@"\r" withString:@"<br>"];
        escapedSummary = [escapedSummary stringByReplacingOccurrencesOfString:@"\n" withString:@"<br>"];
        [content appendFormat:@"<section id=\"ai-summary\"><h2>%@</h2><p>%@</p></section>", heading, escapedSummary];
    }

    [content appendString:@"<div id=\"description\">"];
    if (description)
    {
        // find time codes and replace them with links
        if ([self.episode preferedMedium] && [description length] > 7) {
            @try {
                
                //description = [NSString stringWithFormat:@"<span>%@</span>",description];
                
                NSUInteger l = [description length];
                
                description = [description stringByReplacingOccurrencesOfRegex:@"(\\d{1,2}:\\d{2}:\\d{2})(?=[^>]*(<|$))" withString:@"<a href=\"delegate://play-chapter-timecode/$1\">$1</a>"];
                
                // if pattern failed
                if ([description length] == l) {
                    // matches 00:00
                    description = [description stringByReplacingOccurrencesOfRegex:@"(\\d{2}:\\d{2})(?=[^>]*(<|$))" withString:@"<a href=\"delegate://play-chapter-timecode/00:$1\">$1</a>"];
                }
                
                description = [description stringByReplacingOccurrencesOfRegex:@"(?!<a.*?>)(\\s)@([\\w\\d]+)(?!</a>)" withString:@"$1<a href=\"http://twitter.com/$2\">@$2</a>"];
                
            }
            @catch (NSException *exception) {
                ErrLog(@"%@", [exception description])
            }
        }
        if (description) {
            [content appendString:description];
        }
    }
    [content appendString:@"<table>"];
    
    if (attributes)
    {
        if ([self.episode.title length] > 0) {
            [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Title".ls, self.episode.title];
        }
        
        if ([self.episode.author length] > 0) {
            [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Author".ls, self.episode.author];
        }
        
        if (self.episode.pubDate) {
            NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
            [formatter setLocale:locale];
            [formatter setDateStyle:NSDateFormatterLongStyle];
            [formatter setTimeStyle:NSDateFormatterShortStyle];
            NSString* pubdate = [formatter stringFromDate:self.episode.pubDate];
            [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Published".ls, pubdate];
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
        
        //#ifdef DEBUG
        //    if (self.episode.feed.sourceURL) {
        //        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">Feed</td><td valign=\"top\">%@</td></tr>", [self.episode.feed.sourceURL absoluteString]];
        //    }
        //
        //    if (self.episode.objectHash) {
        //        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">Hash</td><td valign=\"top\">%@</td></tr>", self.episode.objectHash];
        //    }
        //
        //    if (self.episode.guid) {
        //        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">Guid</td><td valign=\"top\">%@</td></tr>", self.episode.guid];
        //    }
        //#endif
        
        if (self.episode.duration >= 1) {
            
            NSInteger duration = self.episode.duration;
            NSValueTransformer* durationTransformer = [NSValueTransformer valueTransformerForName:kICDurationValueTransformer];
            NSString* time = [durationTransformer transformedValue:@(duration)];
            
            [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"Duration".ls, time];
        }
        
        // add cached file size
        unsigned long long fileSize = [self.episode preferedMedium].byteSize;
        
        if ([[CacheManager sharedCacheManager] episodeIsCached:self.episode]) {
            NSURL* fileURL = [[CacheManager sharedCacheManager] URLForCachedEpisode:self.episode];
            NSError* error = nil;
            NSDictionary* fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[fileURL path] error:&error];
            
            if (!error) {
                fileSize = [fileAttributes fileSize];
            }
        }
        
        if (fileSize > 0)
        {
            NSString* sizeString = [NSByteCountFormatter stringFromByteCount:fileSize countStyle:NSByteCountFormatterCountStyleMemory];
            if (sizeString) {
                [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">%@</td><td valign=\"top\">%@</td></tr>", @"File".ls, sizeString];
            }
        }
        
#ifdef DEBUG
        
        [content appendFormat:@"<tr><td class=\"label\" valign=\"top\">UID</td><td valign=\"top\">%@</td></tr>", self.episode.objectHash];
#endif
        
        [content appendString:@"</table></div>"];
    }
    
    return content;
}


- (void) _loadWebContent
{
    [self _loadWebContentPreservingScrollOffset:NO];
}

- (void) _loadWebContentPreservingScrollOffset:(BOOL)preserveScrollOffset
{
    CGPoint previousContentOffset = self.sharedWebView.scrollView.contentOffset;
    NSString* content = [self showNotesAsHTMLIncludingAttributes:YES];
    content = [content stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    content = [content stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    content = [content stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];

    [self.sharedWebView evaluateJavaScript:[NSString stringWithFormat:@"setContent('%@')", content] completionHandler:^(id result, NSError * _Nullable error) {
        if (error == nil) {
            NSString* res =  (NSString*)result;

            if (![res isEqualToString:@"ok"]) {
                ErrLog(@"javascript error");
            }
            if (preserveScrollOffset) {
                [self.sharedWebView.scrollView setContentOffset:previousContentOffset animated:NO];
            }
        }
        self.appearance = [ICAppearanceManager sharedManager].appearance;
    }];

    
    
    
    
   
    
}

- (void) _deleteWebContent
{
    //WKWebView* webView = self.sharedWebView;
    [self.sharedWebView evaluateJavaScript:[NSString stringWithFormat:@"setContent('')"] completionHandler:^(id result, NSError * _Nullable error) {
        
        
    }];
}


- (void)viewDidLoad {
    [super viewDidLoad];
    //[self viewDidLoadContenLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(transcriptionDidChangeNotification:)
                                                 name:@"ICTranscriptionDidChangeNotification"
                                               object:nil];

    self.title = @"Show Notes".ls;
    CGRect viewBounds = self.view.bounds;

    if (!self.episode) {
        return;
    }

    CGFloat masterWidth = CGRectGetWidth(viewBounds);


    UIView* headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 44, masterWidth, 10+72+10)];
    headerView.backgroundColor = ICBackgroundColor;
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:headerView];
    self.headerView = headerView;

    [self setupWebView];

    // Ensure header stays above webview
    [self.view bringSubviewToFront:headerView];
    
    
    UIImageView* imageView = [[UIImageView alloc] initWithFrame:CGRectMake(masterWidth-15-72, 10, 72, 72)];
    imageView.backgroundColor = [UIColor clearColor];
    imageView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [headerView addSubview:imageView];
    
    imageView.image = [UIImage imageNamed:@"Podcast Placeholder 72"];
    
    NSURL* url = (self.episode.imageURL) ? self.episode.imageURL : self.episode.feed.imageURL;
    ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
    NSURL* requestedImageURL = url;
    [iman imageForURL:requestedImageURL size:72 grayscale:NO sender:self completion:^(UIImage* image) {
        if (image && [requestedImageURL isEqual:((self.episode.imageURL) ? self.episode.imageURL : self.episode.feed.imageURL)]) {
            imageView.image = image;
        }
    }];
    
    // create title label
    UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, masterWidth-72-45, 72)];
    titleLabel.backgroundColor = [UIColor clearColor];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    titleLabel.text = [self.episode cleanTitleUsingFeedTitle:self.episode.feed.title];
    titleLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    titleLabel.numberOfLines = 20;
    titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    //titleLabel.backgroundColor = [UIColor redColor];
    
    CGSize titleBoundingSize = [[titleLabel attributedText] boundingRectWithSize:CGSizeMake(masterWidth-72-45, 72) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(titleBoundingSize);
    titleLabel.frame = CGRectMake(15, 10, masterWidth-72-45, titleBoundingSize.height);
    
    [headerView addSubview:titleLabel];
    self.titleLabel = titleLabel;
    
    UILabel* feedTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, CGRectGetMaxY(titleLabel.frame), masterWidth-72-45, 300)];
    feedTitleLabel.backgroundColor = [UIColor clearColor];
    feedTitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    feedTitleLabel.text = self.episode.feed.title;
    feedTitleLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    feedTitleLabel.numberOfLines = 1;
    feedTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    //feedTitleLabel.backgroundColor = [UIColor blueColor];
    
    CGSize feedTitleBoundinSize = [[feedTitleLabel attributedText] boundingRectWithSize:CGSizeMake(masterWidth-72-45, 72) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(feedTitleBoundinSize);
    feedTitleLabel.frame = CGRectMake(15, CGRectGetMaxY(titleLabel.frame), masterWidth-72-45, feedTitleBoundinSize.height);
    [headerView addSubview:feedTitleLabel];
    self.feedTitleLabel = feedTitleLabel;
    
    UILabel* timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    timeLabel.backgroundColor = [UIColor clearColor];
    timeLabel.font = [UIFont systemFontOfSize:ICFontSize(15.0f)];
    [headerView addSubview:timeLabel];
    self.timeLabel = timeLabel;

    self.consumeIndicator = [[ICEpisodeConsumeIndicator alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.consumeIndicator.backgroundColor = [UIColor clearColor];
    self.consumeIndicator.opaque = NO;
    self.consumeIndicator.tintColor = (self.episode.consumed) ? ICMutedTextColor : self.view.tintColor;
    [headerView addSubview:self.consumeIndicator];

    UIImageView* videoIndicator = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"Episode Video"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    videoIndicator.backgroundColor = [UIColor clearColor];
    videoIndicator.tintColor = ICMutedTextColor;
    videoIndicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    videoIndicator.hidden = !self.episode.video;
    [headerView addSubview:videoIndicator];
    self.videoIndicator = videoIndicator;


    UIView* starredIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 15, 3, 72)];
    starredIndicator.backgroundColor = [UIColor colorWithRed:1.f green:174/255.0 blue:0.f alpha:1.f];
    starredIndicator.hidden = !self.episode.starred;
    [headerView addSubview:starredIndicator];
    self.starredIndicator = starredIndicator;
    // correct
    [self _updateTimeDisplay];
    /*UIBarButtonItem* notesButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"globe"] style:UIBarButtonItemStylePlain target:self action:@selector(showMoreInfoInExternalBrowser:)];
     self.navigationItem.rightBarButtonItem = notesButtonItem;*/
}


- (void) showMoreInfoInExternalBrowser:(id)sender
{
    [self.sharedWebView evaluateJavaScript:@"document.documentElement.outerHTML.toString()" completionHandler:^(NSString *html, NSError *error) {
        if (html && !error) {
            // Save the HTML to a temporary file
            NSString *tempDirectory = NSTemporaryDirectory();
            NSString *filePath = [tempDirectory stringByAppendingPathComponent:@"show_notes.html"];
            NSError *writeError = nil;
            BOOL success = [html writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
            if (success) {
                // Open the file in an external browser
                NSURL *fileURL = [NSURL fileURLWithPath:filePath];
                if ([[UIApplication sharedApplication] canOpenURL:fileURL]) {
                    [[UIApplication sharedApplication] openURL:fileURL options:@{} completionHandler:nil];
                }
            } else {
                ErrLog(@"Error writing HTML to file: %@", writeError.localizedDescription);
            }
        } else {
            ErrLog(@"Error getting HTML content: %@", error.localizedDescription);
        }
    }];
}

- (void) _retainSharedContent
{
    //WKWebView* webview = self.sharedWebView;
    if (self.sharedWebView.superview != self.view || [ICAppearanceManager sharedManager].appearance != self.appearance)
    {
        CGRect b = CGRectMake(0, self.headerView.frame.origin.y + self.headerView.frame.size.height, self.view.bounds.size.width, self.view.bounds.size.height - (self.headerView.frame.origin.y + self.headerView.frame.size.height));
        self.sharedWebView.frame = b;
        self.sharedWebView.navigationDelegate = self;
        [self.view insertSubview:self.sharedWebView belowSubview:self.headerView];
        
        //UIScrollView* scrollView = self.sharedWebView.scrollView;
        self.sharedWebView.scrollView.delegate = self;
        
        // toolbarShown was used for content inset calculations that are now commented out
        
//        _dontSaveScrollOffset = YES;
//        CGFloat topOffset = CGRectGetMaxY(self.headerView.frame);
//        if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"11.0.0")) {
//            topOffset = CGRectGetHeight(self.headerView.frame);
//            toolbarShown = NO;
//        }
//        scrollView.contentInset = UIEdgeInsetsMake(topOffset, 0, (toolbarShown)?44:0, 0);
//        scrollView.scrollIndicatorInsets = UIEdgeInsetsMake(topOffset, 0, (toolbarShown)?44:0, 0);
//        scrollView.contentOffset = CGPointMake(0, -scrollView.contentInset.top);
//        _dontSaveScrollOffset = NO;
        
        [self _loadWebContent];
    }
}

- (void)viewDidLoadContenLoad
{
    self.title = @"Show Notes".ls;
    CGRect viewBounds = self.view.bounds;
    
    if (!self.episode) {
        return;
    }
    
    CGFloat masterWidth = CGRectGetWidth(viewBounds);
    
    
    UIView* headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 44, masterWidth, 10+72+10)];
    headerView.backgroundColor = [UIColor clearColor];
    headerView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:headerView];
    self.headerView = headerView;
    
    [self setupWebView];
    
    
    UIImageView* imageView = [[UIImageView alloc] initWithFrame:CGRectMake(masterWidth-15-72, 10, 72, 72)];
    imageView.backgroundColor = [UIColor clearColor];
    imageView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    [headerView addSubview:imageView];
    
    imageView.image = [UIImage imageNamed:@"Podcast Placeholder 72"];
    
    NSURL* url = (self.episode.imageURL) ? self.episode.imageURL : self.episode.feed.imageURL;
    ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
    NSURL* requestedImageURL = url;
    [iman imageForURL:requestedImageURL size:72 grayscale:NO sender:self completion:^(UIImage* image) {
        if (image && [requestedImageURL isEqual:((self.episode.imageURL) ? self.episode.imageURL : self.episode.feed.imageURL)]) {
            imageView.image = image;
        }
    }];
    
    // create title label
    UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, masterWidth-72-45, 72)];
    titleLabel.backgroundColor = [UIColor clearColor];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    titleLabel.text = [self.episode cleanTitleUsingFeedTitle:self.episode.feed.title];
    titleLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    titleLabel.numberOfLines = 20;
    titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    //titleLabel.backgroundColor = [UIColor redColor];
    
    CGSize titleBoundingSize = [[titleLabel attributedText] boundingRectWithSize:CGSizeMake(masterWidth-72-45, 72) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(titleBoundingSize);
    titleLabel.frame = CGRectMake(15, 10, masterWidth-72-45, titleBoundingSize.height);
    
    [headerView addSubview:titleLabel];
    self.titleLabel = titleLabel;
    
    UILabel* feedTitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, CGRectGetMaxY(titleLabel.frame), masterWidth-72-45, 300)];
    feedTitleLabel.backgroundColor = [UIColor clearColor];
    feedTitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    feedTitleLabel.text = self.episode.feed.title;
    feedTitleLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    feedTitleLabel.numberOfLines = 1;
    feedTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    //feedTitleLabel.backgroundColor = [UIColor blueColor];
    
    CGSize feedTitleBoundinSize = [[feedTitleLabel attributedText] boundingRectWithSize:CGSizeMake(masterWidth-72-45, 72) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(feedTitleBoundinSize);
    feedTitleLabel.frame = CGRectMake(15, CGRectGetMaxY(titleLabel.frame), masterWidth-72-45, feedTitleBoundinSize.height);
    [headerView addSubview:feedTitleLabel];
    self.feedTitleLabel = feedTitleLabel;
    
    UILabel* timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    timeLabel.backgroundColor = [UIColor clearColor];
    timeLabel.font = [UIFont systemFontOfSize:ICFontSize(11.0f)];
    [headerView addSubview:timeLabel];
    self.timeLabel = timeLabel;
    
    self.consumeIndicator = [[ICEpisodeConsumeIndicator alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
    self.consumeIndicator.backgroundColor = [UIColor clearColor];
    self.consumeIndicator.opaque = NO;
    self.consumeIndicator.tintColor = (self.episode.consumed) ? ICMutedTextColor : self.view.tintColor;
    [headerView addSubview:self.consumeIndicator];
    
    UIImageView* videoIndicator = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"Episode Video"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    videoIndicator.backgroundColor = [UIColor clearColor];
    videoIndicator.tintColor = ICMutedTextColor;
    videoIndicator.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    videoIndicator.hidden = !self.episode.video;
    [headerView addSubview:videoIndicator];
    self.videoIndicator = videoIndicator;
    
    
    UIView* starredIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 15, 3, 72)];
    starredIndicator.backgroundColor = [UIColor colorWithRed:1.f green:174/255.0 blue:0.f alpha:1.f];
    starredIndicator.hidden = !self.episode.starred;
    [headerView addSubview:starredIndicator];
    self.starredIndicator = starredIndicator;
    
}

- (void) _releaseSharedContent
{
   // WKWebView* webview = self.sharedWebView;
    if (self.sharedWebView.superview == self.view) {
        self.sharedWebView.navigationDelegate = nil;
        self.sharedWebView.scrollView.delegate = nil;
        [self _deleteWebContent];
        [self.sharedWebView removeFromSuperview];
    }
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];



    [self updateAppearance];
    
    
    UINavigationBar* navBar = self.navigationController.navigationBar;
    self.headerView.frame = CGRectMake(0, CGRectGetMaxY(navBar.frame), CGRectGetWidth(self.view.bounds), MAX(10+72+15, CGRectGetMaxY(self.timeLabel.frame)+12));
    CGRect b = CGRectMake(0, self.headerView.frame.origin.y + self.headerView.frame.size.height, self.view.bounds.size.width, self.view.bounds.size.height - (self.headerView.frame.origin.y + self.headerView.frame.size.height));
    self.sharedWebView.frame = b;
    [self _updateTimeDisplay];
    // Toolbar-Items verzögert setzen, um Constraint-Warnungen zu vermeiden
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _updateToolbarAnimated:NO];
    });

    [self _retainSharedContent];
    
    self.longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    self.longPressRecognizer.delegate = self;
    [self.view addGestureRecognizer:self.longPressRecognizer];
    
    //[self.sharedWebView setHidden:YES];
//    NSTimeInterval delayInSeconds = 0.6;
//    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
//    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
//        [self.sharedWebView.scrollView setContentOffset:CGPointZero animated:NO];
//        //[self.sharedWebView setHidden:NO];
//    });
}

- (void) updateAppearance {
    self.view.backgroundColor = ICBackgroundColor;
    self.headerView.backgroundColor = ICBackgroundColor;

    self.titleLabel.textColor = ICTextColor;
    self.feedTitleLabel.textColor = ICMutedTextColor;
    self.timeLabel.textColor = ICMutedTextColor;
    self.sharedWebView.backgroundColor = ICBackgroundColor;
    self.sharedWebView.scrollView.backgroundColor = ICBackgroundColor;
    self.sharedWebView.scrollView.indicatorStyle = [[ICAppearanceManager sharedManager] appearance].scrollIndicatorStyle;

    [self _loadWebContent];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    [self _updateTitleLayout];
    [self _setObserving:YES];
}


- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [self _setObserving:NO];
}

- (void) viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    if (!_dontReleaseSharedContent) {
        [self _releaseSharedContent];
        _dontReleaseSharedContent = NO;
    }
    
    [self.view removeGestureRecognizer:self.longPressRecognizer];
    self.longPressRecognizer = nil;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation
{
    return UIInterfaceOrientationPortrait;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    (void)size;
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [self _updateTitleLayout];
    } completion:nil];
}

#pragma mark -

- (void) handleLongPress:(UILongPressGestureRecognizer*)sender
{
    if (sender.state == UIGestureRecognizerStateBegan)
    {
        //WKWebView* webview = self.sharedWebView;
        UIScrollView* scrollView = self.sharedWebView.scrollView;
        UIEdgeInsets insets = scrollView.contentInset;
        
        CGPoint location = [sender locationInView:self.sharedWebView];
        [self hrefAtLocation:CGPointMake(location.x, location.y - insets.top) completionHandler:^(NSString* href) {
            NSURL* url = (href) ? [NSURL URLWithString:href] : nil;
            if (url) {
                UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:@[[[OpenInSafariActivity alloc] init]]];
                if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
                    shareController.popoverPresentationController.sourceView = self.view;
                    shareController.popoverPresentationController.sourceRect = CGRectMake(location.x, location.y, 1, 1);
                }
                [self presentViewController:shareController animated:YES completion:NULL];
            }
            
            //[App beginIgnoringInteractionEvents];
        }];
        
        
        
    }
    else
    {
        // Deprecated in iOS 13: isIgnoringInteractionEvents/endIgnoringInteractionEvents
        // These were used to prevent user interaction during animations, but are no longer needed
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)hrefAtLocation:(CGPoint)location completionHandler:(void (^ _Nullable)(NSString* _Nullable result))completionHandler {
    
    
    NSString *body = @"\n\
    var link = 0;\n\
    \n\
    var x = x__;\n\
    var y = y__;\n\
    \n\
    var d = 15;\n\
    \n\
    for (var h=0; h<=d; h++) {\n\
    for (var hi=-1; hi<=1; hi+=2) {\n\
    var hx = hi * h;\n\
    for (var v=0; v<=d; v++) {\n\
    for (var vi=-1; vi<=1; vi+=2) {\n\
    var vy = vi * v;\n\
    x = x__ + hx;\n\
    y = y__ + vy;\n\
    \n\
    var elem = document.elementFromPoint(x,y);\n\
    \n\
    do {\n\
    \n\
    if (elem == document.body) {\n\
    break;\n\
    }\n\
    \n\
    if (elem.tagName.toLowerCase() == 'a') {\n\
    link = elem;\n\
    break;\n\
    }\n\
    \n\
    elem = elem.parentNode;\n\
    \n\
    } while (elem);\n\
    \n\
    if (link) break;\n\
    \n\
    }\n\
    }\n\
    }\n\
    \n\
    if (link) break;\n\
    \n\
    }\n\
    \n\
    \n\
    if (link) {\n\
    return link.href;\n\
    }\n\
    return '';";
    
    
    
    NSString *js = [NSString stringWithFormat:@"(function(x__, y__) { %@ })(%f,%f)",body,location.x,location.y];
    
    [self.sharedWebView evaluateJavaScript:js completionHandler:^(id result, NSError * _Nullable error) {
        if (error == nil) {
            NSString *ret = (NSString*)result;
            if ([ret hasPrefix:@"http"]) {
                completionHandler(ret);
            } else {
                completionHandler(nil);
            }
        } else {
            completionHandler(nil);
        }
        
    }];
    
    //TODO
    
}

#pragma mark -

- (void) _updateTitleLayout
{
    CGFloat masterWidth = CGRectGetWidth(self.view.bounds);
    
    CGSize titleBoundingSize = [[self.titleLabel attributedText] boundingRectWithSize:CGSizeMake(masterWidth-72-45, 72) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(titleBoundingSize);
    self.titleLabel.frame = CGRectMake(15, 10, masterWidth-72-45, titleBoundingSize.height);
    
    CGSize feedTitleBoundinSize = [[self.feedTitleLabel attributedText] boundingRectWithSize:CGSizeMake(masterWidth-72-45, 72) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(feedTitleBoundinSize);
    self.feedTitleLabel.frame = CGRectMake(15, CGRectGetMaxY(self.titleLabel.frame), masterWidth-72-45, feedTitleBoundinSize.height);
    
    [self _updateTimeDisplay];
    
    
    UINavigationBar* navBar = self.navigationController.navigationBar;
    self.headerView.frame = CGRectMake(0, CGRectGetMaxY(navBar.frame), masterWidth, MAX(10+72+15, CGRectGetMaxY(self.timeLabel.frame)+12));
    CGRect b = CGRectMake(0, self.headerView.frame.origin.y + self.headerView.frame.size.height, self.view.bounds.size.width, self.view.bounds.size.height - (self.headerView.frame.origin.y + self.headerView.frame.size.height));
    self.sharedWebView.frame = b;
    BOOL toolbarShown = (!self.navigationController.toolbarHidden || [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad);
    CGFloat topOffset = CGRectGetMaxY(self.headerView.frame);
    topOffset = CGRectGetHeight(self.headerView.frame);
    toolbarShown = NO;
    
//    UIScrollView* webScrollView = self.sharedWebView.scrollView;
//    webScrollView.contentInset = UIEdgeInsetsMake(topOffset, 0, (toolbarShown)?44:0, 0);
//    webScrollView.scrollIndicatorInsets = UIEdgeInsetsMake(topOffset, 0, (toolbarShown)?44:0, 0);
}

- (void) _updateTimeDisplay
{
    CDEpisode* episode = self.episode;
    
    self.consumeIndicator.consumed = episode.consumed;
    self.consumeIndicator.progress = (episode.duration > 0) ? (double)episode.position / (double)episode.duration : 0;
    self.consumeIndicator.tintColor = (episode.consumed) ? ICMutedTextColor : self.view.tintColor;
    
    self.starredIndicator.hidden = !episode.starred;
    
    BOOL consumed = episode.consumed;
    
    
    NSInteger duration = episode.duration-episode.position;
    NSString* formattedDuration = nil;
    if (duration > 1) {
        NSValueTransformer* durationTransformer = [NSValueTransformer valueTransformerForName:kICDurationValueTransformer];
        formattedDuration = [durationTransformer transformedValue:@(duration)];
    }
    
    NSDate* pubDate = episode.pubDate;
    NSDate* today = [NSDate date];
    NSDate* yesterday = [today dateByAddingTimeInterval:-86400];
    
    unsigned unitFlags = NSCalendarUnitYear | NSCalendarUnitMonth |  NSCalendarUnitDay;
    NSDateComponents* pubDateComponents = [[NSCalendar currentCalendar] components:unitFlags fromDate:pubDate];
    NSDateComponents* todayComponents = [[NSCalendar currentCalendar] components:unitFlags fromDate:today];
    NSDateComponents* yesterdayComponents = [[NSCalendar currentCalendar] components:unitFlags fromDate:yesterday];
    
    NSString* dateString = nil;
    NSTimeInterval timeInterval = [[NSDate date] timeIntervalSinceDate:pubDate];
    if ([pubDateComponents year] == [todayComponents year] && [pubDateComponents month] == [todayComponents month] && [pubDateComponents day] == [todayComponents day]) {
        dateString = @"Today".ls;
    }
    else if ([pubDateComponents year] == [yesterdayComponents year] && [pubDateComponents month] == [yesterdayComponents month] && [pubDateComponents day] == [yesterdayComponents day]) {
        dateString = @"Yesterday".ls;
    }
    else if (timeInterval < 86400*7) {
        NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"EEEE"];
        dateString = [dateFormatter stringFromDate:pubDate];
    }
    else {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setFormatterBehavior:NSDateFormatterBehavior10_4];
        [formatter setDateStyle:NSDateFormatterShortStyle];
        [formatter setTimeStyle:NSDateFormatterNoStyle];
        dateString = [formatter stringForObjectValue:pubDate];
    }
    
    
    self.timeLabel.text = (!consumed && formattedDuration) ? [NSString stringWithFormat:@"%@ %@", dateString, formattedDuration] : dateString;
    CGSize timeSize = [[self.timeLabel attributedText] boundingRectWithSize:CGSizeMake(CGRectGetWidth(self.view.bounds)-72-45, 100) options:NSStringDrawingUsesLineFragmentOrigin context:NULL].size;
    IC_SIZE_INTEGRAL(timeSize);
    CGRect timeLabelFrame = CGRectMake(31, MAX(10+72-timeSize.height, CGRectGetMaxY(self.feedTitleLabel.frame)), timeSize.width, timeSize.height);
    self.timeLabel.frame = timeLabelFrame;
    
    self.consumeIndicator.frame = CGRectMake(15, CGRectGetMinY(timeLabelFrame)+1, 10, 10);
    self.videoIndicator.frame = CGRectMake(CGRectGetMaxX(timeLabelFrame)+5, CGRectGetMinY(timeLabelFrame)+2, 10, 9);
}

- (void) _updateToolbarAnimated:(BOOL)animated
{
    UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];


    EpisodePlayComboButton* playButton = [EpisodePlayComboButton buttonWithType:UIButtonTypeCustom];
    playButton.frame = CGRectMake(0, 0, 44, 44);
    playButton.contentMode = UIViewContentModeRedraw;
    [playButton addTarget:self action:@selector(playAction:) forControlEvents:UIControlEventTouchUpInside];
    self.playButton = playButton;
    
    [self updatePlayComboButtonState];
    
    UIBarButtonItem* playItem = [[UIBarButtonItem alloc] initWithCustomView:self.playButton];
    playItem.enabled = ([self.episode preferedMedium] != nil);
    
    UIBarButtonItem* downloadItem;
    downloadItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Download"] menu:[self _buildDownloadMenu]];
    downloadItem.enabled = ([self.episode preferedMedium] != nil);

    UIBarButtonItem* shareItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Share"]
                                                                  style:UIBarButtonItemStylePlain target:self action:@selector(shareAction:)];

    UIBarButtonItem* moreItem;
    moreItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar More"] menu:[self _buildMoreMenu]];
    // iOS default reorders the menu so the first child sits closest to the tap point,
    // which for a bottom toolbar means children are shown bottom-up. That flipped the
    // order relative to the cell long-press menu, which the user explicitly called out.
    // .fixed forces the menu to respect the children-array order regardless of anchor
    // position (iOS 16+). Also the same UIBarButtonItem.preferredMenuElementOrder docs:
    // https://developer.apple.com/documentation/uikit/uibarbuttonitem/preferredmenuelementorder
    if (@available(iOS 16.0, *)) {
        moreItem.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
    }

    UIBarButtonItem* negativeSpaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    negativeSpaceItem.width = -12;
    
    [self willChangeValueForKey:@"toolbarItems"];
    [self setToolbarItems:@[ negativeSpaceItem, playItem, flexSpace, downloadItem, flexSpace, shareItem, flexSpace, moreItem ] animated:animated];
    [self didChangeValueForKey:@"toolbarItems"];
    
}


- (void) updatePlayComboButtonState
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    CDEpisode* episode = self.episode;
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    BOOL cached = [cman episodeIsCached:episode fastLookup:YES];
    BOOL caching = [cman isCachingEpisode:episode];
    BOOL streamingCachingCurrentEpisode = (!cached &&
                                           pman.streamingCacheActive &&
                                           [pman.playingEpisode.objectHash isEqualToString:episode.objectHash]);
    double streamingProgress = streamingCachingCurrentEpisode ? pman.streamingCacheProgress : 0.0;
    
    if (cached) {
        self.playButton.comboState = kEpisodePlayButtonComboStateFilled;
    }
    else if (streamingCachingCurrentEpisode) {
        self.playButton.comboState = kEpisodePlayButtonComboStateFilling;
    }
    else if (caching) {
        self.playButton.comboState = kEpisodePlayButtonComboStateFilling;
    }
    else {
        self.playButton.comboState = kEpisodePlayButtonComboStateOutline;
    }
    
    self.playButton.fillingProgress = MAX([cman cacheProgressForEpisode:episode], streamingProgress);
}

- (void) _setObserving:(BOOL)observing
{
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    
    if (observing && !_observing)
    {
        [nc addObserver:self selector:@selector(playbackManagerDidEndNotification:) name:PlaybackManagerDidEndNotification object:nil];
        [nc addObserver:self selector:@selector(playbackManagerDidChangeEpisodeNotification:) name:PlaybackManagerDidChangeEpisodeNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidStartCachingEpisodeNotification:) name:CacheManagerDidStartCachingEpisodeNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidUpdateNotification:) name:CacheManagerDidUpdateNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidFinishCachingEpisodeNotification:) name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidFinishCachingEpisodeNotification:) name:CacheManagerDidFailCachingEpisodeNotification object:nil];
        
        [App addTaskObserver:self forKeyPath:@"networkAccessTechnology" task:^(id obj, NSDictionary *change) {
            [self _updateTimeDisplay];
        }];

    }
    else if (!observing && _observing)
    {
        [nc removeObserver:self name:PlaybackManagerDidEndNotification object:nil];
        [nc removeObserver:self name:PlaybackManagerDidChangeEpisodeNotification object:nil];
        [nc removeObserver:self name:CacheManagerDidStartCachingEpisodeNotification object:nil];
        [nc removeObserver:self name:CacheManagerDidUpdateNotification object:nil];
        [nc removeObserver:self name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
        [nc removeObserver:self name:CacheManagerDidFailCachingEpisodeNotification object:nil];
        [App removeTaskObserver:self forKeyPath:@"networkAccessTechnology"];
    }
    
    _observing = observing;
}

- (void) playbackManagerDidEndNotification:(NSNotification*)notification
{
    [self _updateTimeDisplay];
}

- (void) transcriptionDidChangeNotification:(NSNotification*)notification
{
    NSString* episodeHash = [notification.userInfo[@"episodeHash"] copy];
    if (episodeHash.length == 0) {
        return;
    }
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self transcriptionDidChangeNotification:notification];
        });
        return;
    }
    if (![episodeHash isEqualToString:self.episode.objectHash]) {
        return;
    }
    if (!self.isViewLoaded || self.view.window == nil || self.sharedWebView.superview != self.view) {
        return;
    }

    [self _loadWebContentPreservingScrollOffset:YES];
}

- (void) playbackManagerDidChangeEpisodeNotification:(NSNotification*)notification
{
    [self _updateTimeDisplay];
}

- (void) cacheManagerDidStartCachingEpisodeNotification:(NSNotification*)notification
{
    [self updatePlayComboButtonState];
}

- (void) cacheManagerDidUpdateNotification:(NSNotification*)notification
{
    [self updatePlayComboButtonState];
}

- (void) cacheManagerDidFinishCachingEpisodeNotification:(NSNotification*)notification
{
    [self updatePlayComboButtonState];
    [self _updateTimeDisplay];
}

- (void) setEpisode:(CDEpisode *)episode
{
    if (_episode != episode)
    {
        [_episode removeTaskObserver:self forKeyPath:@"position"];
        [_episode removeTaskObserver:self forKeyPath:@"consumed"];
        [_episode removeTaskObserver:self forKeyPath:@"starred"];
        [_episode removeTaskObserver:self forKeyPath:@"downloaded"];
        
        _episode = episode;
        
        if (!episode) {
            return;
        }
        
        __weak EpisodeViewController* weakSelf = self;
        [episode addTaskObserver:self forKeyPath:@"position" task:^(id obj, NSDictionary *change) {
            [weakSelf _updateTimeDisplay];
        }];
        
        [episode addTaskObserver:self forKeyPath:@"consumed" task:^(id obj, NSDictionary *change) {
            [weakSelf _updateTimeDisplay];
        }];
        
        [episode addTaskObserver:self forKeyPath:@"starred" task:^(id obj, NSDictionary *change) {
            [weakSelf _updateTimeDisplay];
        }];
        
        [episode addTaskObserver:self forKeyPath:@"downloaded" task:^(id obj, NSDictionary *change) {
            [weakSelf _updateTimeDisplay];
        }];
    }
}


#pragma mark -
#pragma mark WebView Delegate

- (void) _startPlaybackAtTime:(double)time
{
    AudioSession* audioSession = [AudioSession sharedAudioSession];
    PlaybackManager* pman = [PlaybackManager playbackManager];
    if ([audioSession.episode isEqual:self.episode] && pman.ready)
    {
        [pman seekToTime:time];
        
        UINavigationController* navController = self.navigationController;
        if ([navController isKindOfClass:[PlaybackViewController class]]) {
            [navController popViewControllerAnimated:YES];
        }
        else {
            PlaybackViewController* playbackController = [PlaybackViewController playbackViewController];
            [playbackController presentFromParentViewController:self];
        }
    }
    else
    {
        [DMANAGER setEpisode:self.episode position:time];
        
        UINavigationController* navController = self.navigationController;
        if ([navController isKindOfClass:[PlaybackViewController class]]) {
            [navController popViewControllerAnimated:YES];
        }
        else {
            PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:self.episode];
            [playbackController presentFromParentViewController:self];
        }
    }
}



- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    NSURL* url = [navigationAction.request URL];
	NSString *urlString = url.absoluteString;
	
	if ([[url scheme] isEqualToString:@"delegate"])
	{
		NSString* command = [url host];
        
        if ([command isEqualToString:@"play-chapter-timecode"])
        {
            NSString* timecodeString = [[url path] lastPathComponent];
            NSScanner* scanner = [[NSScanner alloc] initWithString:timecodeString];
            
            NSInteger hour = 0;
            [scanner scanInteger:&hour];
            
            [scanner scanString:@":" intoString:NULL];
            
            NSInteger minute = 0;
            [scanner scanInteger:&minute];
            
            [scanner scanString:@":" intoString:NULL];
            
            NSInteger second = 0;
            [scanner scanInteger:&second];
            
            double time = hour*3600.0 + minute*60.0 + second;
            [self _startPlaybackAtTime:time];
        }

        decisionHandler(WKNavigationActionPolicyAllow);
	}
	
	// do not allow iframes
	if (navigationAction.navigationType == WKNavigationTypeOther && ![urlString isEqualToString:@"about:blank"]) {
        decisionHandler(WKNavigationActionPolicyCancel);
	}
	
    _dontReleaseSharedContent = YES;
    if ([self handleShowNotesURL:url]) {
        decisionHandler(WKNavigationActionPolicyAllow);
    } else {
        decisionHandler(WKNavigationActionPolicyCancel);
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if ([[[webView URL] absoluteString] isEqualToString:@"about:blank"]) {
        [self _loadWebContent];
    }

    if (self.didFinishLoading) {
        self.didFinishLoading();
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.sharedWebView evaluateJavaScript:@"window.scrollTo(0, 0);" completionHandler:nil];
    });
}

- (void) scrollViewDidScroll:(UIScrollView*)scrollView
{
    if (!_dontSaveScrollOffset) {
        _scrollOffset = scrollView.contentOffset;
    }
}

#pragma mark -

- (void) playAction:(id)sender
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    if ([cman isCachingEpisode:self.episode]) {
        [cman cancelCachingEpisode:self.episode disableAutoDownload:YES];
        return;
    }
    
    if ([self.episode preferedMedium])
    {
        PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:self.episode forceReload:YES];
        [playbackController presentFromParentViewController:self];
    }
}

- (void) openURLAction:(id)sender
{
    NSURL* linkURL = self.episode.linkURL;
    NSURL* deeplinkURL = self.episode.deeplinkURL;
    NSURL* link = (deeplinkURL) ? deeplinkURL : linkURL;
    
	if (link) {
        [self handleShowNotesURL:link];
	}
}

- (void) _downloadFile
{
    [self _downloadFileForEpisode:self.episode];
}

- (void) _downloadFileForEpisode:(CDEpisode*)episode
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    
    BOOL enabled3G = [USER_DEFAULTS boolForKey:EnableCachingOver3G];
    ICNetworkAccessTechnlogy networkAccessTechnology = App.networkAccessTechnology;
    if (!enabled3G && networkAccessTechnology < kICNetworkAccessTechnlogyWIFI)
    {
        WEAK_SELF
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Downloading over cellular has been disabled in 'General' settings.".ls message:@"Do you still want to download the content of this episode right now?".ls preferredStyle:UIAlertControllerStyleAlert];
        
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Download".ls
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * action) {
                                                    STRONG_SELF
                                                    [self perform:^(id sender) {
                                                        [cman cacheEpisode:episode overwriteCellularLock:YES];
                                                    } afterDelay:0.3];
                                                    self.alertController = nil;
                                                }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction * action) {
                                                    STRONG_SELF
                                                    self.alertController = nil;
                                                }]];
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
    else {
        [cman cacheEpisode:episode];
    }
}

- (UIMenu*) _buildDownloadMenu API_AVAILABLE(ios(14.0))
{
    WEAK_SELF
    CacheManager* cman = [CacheManager sharedCacheManager];
    NSMutableArray* actions = [NSMutableArray array];

    if (![cman episodeIsCached:self.episode]) {
        NSString* addTitle = @"Download".ls;
        if ([self.episode preferedMedium].byteSize > 0LL) {
            unsigned long long totalBytes = [self.episode preferedMedium].byteSize;
            unsigned long long downloadedBytes = [cman numberOfDownloadedBytesForEpisode:self.episode];
            unsigned long long bytes = downloadedBytes >= totalBytes ? 0 : totalBytes - downloadedBytes;
            NSString* sizeString = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];
            addTitle = [NSString stringWithFormat:@"%@ (%@)", @"Download".ls, sizeString];
        }
        [actions addObject:[UIAction actionWithTitle:addTitle image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            [self _downloadFile];
        }]];
    } else {
        NSString* redownloadTitle = @"Re-Download".ls;
        unsigned long long bytes = [self.episode preferedMedium].byteSize;
        if (bytes > 0LL) {
            NSString* sizeString = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];
            redownloadTitle = [NSString stringWithFormat:@"%@ (%@)", @"Re-Download".ls, sizeString];
        }
        [actions addObject:[UIAction actionWithTitle:redownloadTitle image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            CDEpisode* episode = self.episode;
            NSString* episodeHash = [episode.objectHash copy];
            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode
                                                           automatic:NO
                                                          completion:^(NSError* error) {
                if (error) return;
                if ([self.episode.objectHash isEqualToString:episodeHash]) {
                    [self _updateTimeDisplay];
                    [self updatePlayComboButtonState];
                }
                [self _downloadFileForEpisode:episode];
            }];
        }]];

        UIAction* deleteAction = [UIAction actionWithTitle:@"Delete Download".ls image:[[UIImage systemImageNamed:@"square.and.arrow.down"] imageWithTintColor:[UIColor colorWithWhite:0.5f alpha:1.0f] renderingMode:UIImageRenderingModeAlwaysOriginal] identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            [[CacheManager sharedCacheManager] removeCacheForEpisode:self.episode automatic:NO];
            [self _updateTimeDisplay];
            [self updatePlayComboButtonState];
        }];
        [actions addObject:deleteAction];
    }

    return [UIMenu menuWithTitle:@"" children:actions];
}

- (UIMenu*) _buildMoreMenu API_AVAILABLE(ios(14.0))
{
    // Same order and items as EpisodesTableViewController._contextMenuForIndexPath:
    // (minus Episode Info / Play, which is the page itself)
    WEAK_SELF
    NSMutableArray* actions = [NSMutableArray array];

    // 1. Mark as Favorite / Unmark Favorite
    NSString* favTitle = self.episode.starred ? @"Unmark Favorite".ls : @"Mark as Favorite".ls;
    NSString* favIcon = self.episode.starred ? @"star.slash" : @"star";
    [actions addObject:[UIAction actionWithTitle:favTitle image:[UIImage systemImageNamed:favIcon] identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        BOOL flag = !self.episode.starred;
        [DMANAGER markEpisode:self.episode asStarred:flag];
        PlaySoundFile(flag ? @"AffirmIn" : @"AffirmOut", NO);
        [self _updateTimeDisplay];
        [self updatePlayComboButtonState];
    }]];

    // 2. Mark as Played / Unplayed
    NSString* playedTitle = self.episode.consumed ? @"Mark as Unplayed".ls : @"Mark as Played".ls;
    NSString* playedIcon = self.episode.consumed ? @"circle.fill" : @"circle";
    [actions addObject:[UIAction actionWithTitle:playedTitle image:[UIImage systemImageNamed:playedIcon] identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        BOOL flag = !self.episode.consumed;
        [DMANAGER markEpisode:self.episode asConsumed:flag];
        PlaySoundFile(flag ? @"AffirmOut" : @"AffirmIn", NO);
        if (self.episode.consumed && [self.episode isEqual:[AudioSession sharedAudioSession].episode]) {
            [[AudioSession sharedAudioSession] stop];
            [self.navigationItem setRightBarButtonItem:nil animated:YES];
        }
        [self _updateTimeDisplay];
        [self updatePlayComboButtonState];
    }]];

    // 3. Add to / Remove from Play Next
    {
        BOOL inUpNext = [[AudioSession sharedAudioSession].playlist containsObject:self.episode];
        NSString* upNextTitle = inUpNext ? @"Remove from Play Next".ls : @"Add to Play Next".ls;
        UIImage* upNextIcon = [UIImage systemImageNamed:@"list.bullet.indent"];
        if (inUpNext) {
            upNextIcon = [upNextIcon imageWithTintColor:[UIColor colorWithWhite:0.5f alpha:1.0f] renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
        [actions addObject:[UIAction actionWithTitle:upNextTitle image:upNextIcon identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            BOOL wasInUpNext = [[AudioSession sharedAudioSession].playlist containsObject:self.episode];
            if (wasInUpNext) {
                [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[self.episode]];
            } else {
                [[AudioSession sharedAudioSession] appendToUpNext:@[self.episode]];
            }
            PlayHapticFeedback(ICHapticFeedbackLight);
        }]];
    }

    AppleWatchSyncManager* watchManager = [AppleWatchSyncManager sharedManager];
    if ([watchManager canSendEpisodeToWatch:self.episode]) {
        BOOL selectedForWatch = [watchManager isEpisodeSelectedForWatch:self.episode];
        NSString* watchTitle = selectedForWatch ? @"Von Apple Watch entfernen".ls : @"An Apple Watch senden".ls;
        NSString* watchIcon = selectedForWatch ? @"applewatch.slash" : @"applewatch";
        [actions addObject:[UIAction actionWithTitle:watchTitle image:[UIImage systemImageNamed:watchIcon] identifier:nil handler:^(__unused UIAction* action) {
            STRONG_SELF
            if (selectedForWatch) {
                [watchManager removeEpisodeFromWatch:self.episode];
            }
            else {
                [watchManager sendEpisodeToWatch:self.episode];
            }
        }]];

        if (selectedForWatch && ![watchManager isEpisodeDownloadedOnWatch:self.episode]) {
            [actions addObject:[UIAction actionWithTitle:@"Priorisiert auf Watch laden".ls image:[UIImage systemImageNamed:@"arrow.down.circle"] identifier:nil handler:^(__unused UIAction* action) {
                STRONG_SELF
                [watchManager prioritizeEpisodeOnWatch:self.episode];
            }]];
        }
    }

    // 4. Download (if not cached and not currently caching)
    CacheManager* cman = [CacheManager sharedCacheManager];
    if (![cman episodeIsCached:self.episode] && ![cman isCachingEpisode:self.episode]) {
        [actions addObject:[UIAction actionWithTitle:@"Download".ls image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            [[CacheManager sharedCacheManager] cacheEpisode:self.episode overwriteCellularLock:YES];
        }]];
    }

    // 5. Delete File (if cached)
    if ([cman episodeIsCached:self.episode]) {
        [actions addObject:[UIAction actionWithTitle:@"Delete File".ls image:[[UIImage systemImageNamed:@"square.and.arrow.down"] imageWithTintColor:[UIColor colorWithWhite:0.5f alpha:1.0f] renderingMode:UIImageRenderingModeAlwaysOriginal] identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            [[CacheManager sharedCacheManager] removeCacheForEpisode:self.episode automatic:NO];
        }]];
    }

    // 6. Transcribe (auto-downloads if needed)
    BOOL localTranscriptionEnabled = [USER_DEFAULTS boolForKey:kLocalTranscriptionEnabled];
    if (localTranscriptionEnabled && ![[TranscriptionEngine shared] hasSRTFor:self.episode.objectHash]) {
        [actions addObject:[UIAction actionWithTitle:NSLocalizedString(@"Transkribieren", nil) image:[UIImage systemImageNamed:@"captions.bubble"] identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            if (![ICDownloadableModelStore selectedVoiceModelIsReady]) {
                UIViewController* settingsVC = [TranscriptionSettingsViewController modelLibraryViewControllerFocusedOnVoiceToText:YES];
                [self.navigationController pushViewController:settingsVC animated:YES];
                return;
            }
            NSURL* audioURL = [cman episodeIsCached:self.episode] ? [cman URLForCachedEpisode:self.episode] : nil;
            (void)[[TranscriptionQueue shared] enqueueWithEpisodeHash:self.episode.objectHash
                                                       episodeTitle:self.episode.title ?: @""
                                                          feedTitle:self.episode.feed.title ?: @""
                                                           audioURL:audioURL
                                                           language:self.episode.feed.language];
            PlaySoundFile(@"AffirmIn", NO);
        }]];
    }

    // 7. Generate chapters (only if no generated chapters exist — neither in the JSON
    // cache nor copied into Core Data on first playback). Otherwise "Generieren" and
    // "Löschen" would be visible at the same time, which is confusing.
    BOOL hasTranscript = [[TranscriptionQueue shared] hasChapterGenerationTranscriptWithEpisodeHash:self.episode.objectHash];
    BOOL hasAnyChapters = [[ChapterGenerator shared] hasChaptersFor:self.episode.objectHash] || self.episode.chapters.count > 0;
    if (localTranscriptionEnabled && hasTranscript && !hasAnyChapters) {
        ICDownloadableModel* chapterModel = [ICDownloadableModelStore selectedModelForRole:ICDownloadableModelRoleTextToChapters];
        NSString* createTitle = chapterModel.usesRemoteChapterService
            ? NSLocalizedString(@"Kapitel und Zusammenfassung erstellen", nil)
            : NSLocalizedString(@"Kapitel erstellen", nil);
        [actions addObject:[UIAction actionWithTitle:createTitle image:[UIImage systemImageNamed:@"list.number"] identifier:nil handler:^(UIAction *action) {
            STRONG_SELF
            if (![ICDownloadableModelStore selectedChapterModelCanGenerate]) {
                UIViewController* settingsVC = [TranscriptionSettingsViewController modelLibraryViewControllerFocusedOnVoiceToText:NO];
                [self.navigationController pushViewController:settingsVC animated:YES];
                return;
            }
            BOOL started = [[TranscriptionQueue shared] generateChaptersWithEpisodeHash:self.episode.objectHash
                                                                          episodeTitle:self.episode.title ?: @""
                                                                             feedTitle:self.episode.feed.title ?: @""];
            if (started) {
                PlaySoundFile(@"AffirmIn", NO);
            } else {
                PlayHapticFeedback(ICHapticFeedbackLight);
            }
        }]];
    }

    // 8+9. Delete transcript and chapters as separate destructive actions, so each can
    // be removed individually (and re-generated individually afterwards).
    {
        BOOL hasSRT = [[TranscriptionEngine shared] hasSRTFor:self.episode.objectHash];
        // Only the generated-chapter JSON proves ownership. CDChapter can also contain
        // podcast-provided chapters copied during playback, so it must not drive this action.
        BOOL hasGeneratedChapters = [[ChapterGenerator shared] hasChaptersFor:self.episode.objectHash];
        BOOL hasGeneratedSummary = hasGeneratedChapters && self.episode.objectHash.length > 0 && [[[ChapterGenerator shared] loadSummaryFor:self.episode.objectHash] length] > 0;

        if (hasSRT) {
            UIAction* deleteTranscriptAction = [UIAction actionWithTitle:NSLocalizedString(@"Transkript löschen", nil) image:[UIImage systemImageNamed:@"captions.bubble"] identifier:nil handler:^(UIAction *action) {
                STRONG_SELF
                NSString* hash = self.episode.objectHash;
                if (!hash) return;
                [[TranscriptionEngine shared] removeSRTFor:hash];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ICTranscriptionDidChangeNotification" object:nil userInfo:@{@"episodeHash": hash}];
            }];
            deleteTranscriptAction.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:deleteTranscriptAction];
        }
        if (hasGeneratedChapters) {
            NSString* deleteTitle = hasGeneratedSummary
                ? NSLocalizedString(@"Kapitel und Zusammenfassung löschen", nil)
                : NSLocalizedString(@"Kapitel löschen", nil);
            UIAction* deleteChaptersAction = [UIAction actionWithTitle:deleteTitle image:[UIImage systemImageNamed:@"list.number"] identifier:nil handler:^(UIAction *action) {
                STRONG_SELF
                NSString* hash = self.episode.objectHash;
                if (!hash) return;
                [[ChapterGenerator shared] removeGeneratedAnalysisForEpisodeHash:hash];
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ICTranscriptionDidChangeNotification" object:nil userInfo:@{@"episodeHash": hash}];
            }];
            deleteChaptersAction.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:deleteChaptersAction];
        }
    }

    // Reverse so the visible top-to-bottom order matches the long-press menu in
    // EpisodesTableViewController. The toolbar is anchored at the bottom of the
    // screen, and iOS shows menu items from the anchor outward — i.e. the first
    // child appears at the BOTTOM (next to the tap point). Without reversing the
    // array, the visible order would be the inverse of the long-press menu.
    return [UIMenu menuWithTitle:@"" children:actions];
}

- (void) downloadAction:(id)sender
{
    // Menu is shown automatically via barButtonItem.menu
    return;
}


- (void) shareAction:(id)sender
{
    UIBarButtonItem* barButton = [sender isKindOfClass:[UIBarButtonItem class]] ? (UIBarButtonItem*)sender : nil;

    NSURL* feedSourceURL = self.episode.feed.sourceURL;
    if (!feedSourceURL) {
        return;
    }

    NSMutableArray* queryItems = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"url" value:[feedSourceURL absoluteString]]];
    if (self.episode.guid.length > 0) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:@"guid" value:self.episode.guid]];
    }
    NSURLComponents* shareComponents = [NSURLComponents componentsWithString:@"https://instacast.ch/share/episode"];
    shareComponents.queryItems = queryItems;
    NSURL* link = shareComponents.URL;
    if (!link) {
        return;
    }

    UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[link] applicationActivities:nil];
    if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
        if (barButton) {
            shareController.popoverPresentationController.barButtonItem = barButton;
        } else {
            shareController.popoverPresentationController.sourceView = self.view;
            shareController.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        }
    }
    [self presentViewController:shareController animated:YES completion:NULL];
}

- (void) moreAction:(id)sender
{
    // Menu is shown automatically via barButtonItem.menu
    return;

    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:(self.episode.consumed)?@"Mark as Unplayed".ls:@"Mark as Played".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    BOOL flag = !self.episode.consumed;
                                                    [DMANAGER markEpisode:self.episode asConsumed:flag];
                                                    PlaySoundFile((flag)?@"AffirmOut":@"AffirmIn", NO);
                                                    if (self.episode.consumed && [self.episode isEqual:[AudioSession sharedAudioSession].episode]) {
                                                        [[AudioSession sharedAudioSession] stop];
                                                        [self.navigationItem setRightBarButtonItem:nil animated:YES];
                                                    }
                                                    [self _updateTimeDisplay];
                                                    [self updatePlayComboButtonState];
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];

    [alert addAction:[UIAlertAction actionWithTitle:(self.episode.starred)?@"Unmark Favorite".ls:@"Mark as Favorite".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    BOOL flag = !self.episode.starred;
                                                    [DMANAGER markEpisode:self.episode asStarred:flag];
                                                    PlaySoundFile((flag)?@"AffirmIn":@"AffirmOut", NO);
                                                    [self _updateTimeDisplay];
                                                    [self updatePlayComboButtonState];
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                self.alertController = nil;
                                            }]];
    [alert setModalPresentationStyle:UIModalPresentationPopover];
    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    UIViewController* rootViewController = [(InstacastAppDelegate*)[[UIApplication sharedApplication]delegate] getRootViewControllerDev];
    popPresenter.sourceView = [rootViewController view];
    popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
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
@end
