//
//  EpisodesTableViewCell.m
//  Instacast
//
//  Created by Martin Hering on 29.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import "EpisodesTableViewCell.h"

#import "CDEpisode+ShowNotes.h"
#import "EpisodePlayComboButton.h"
#import "ImageCacheManager.h"
#import "ICEpisodeConsumeIndicator.h"
#import "GradientProgressView.h"
#import "PlaybackManager.h"


@interface EpisodesTableViewCell ()
@property (nonatomic, readwrite, strong) UIView* panningContentView;

@property (nonatomic, strong, readwrite) UILabel* titleLabel;
@property (nonatomic, strong, readwrite) UILabel* summaryLabel;
@property (nonatomic, strong, readwrite) UIImageView* iconView;


@property (nonatomic, strong) UILabel* durationLabel;
@property (nonatomic, strong) UILabel* dateLabel;
@property (nonatomic, strong) ICEpisodeConsumeIndicator* consumeIndicator2;

@property (nonatomic, strong, readwrite) UIImageView* leftPanImage;
@property (nonatomic, strong, readwrite) UIImageView* rightPanImage;
@property (nonatomic, strong, readwrite) UIButton* moreButton;
@property (nonatomic, strong, readwrite) UIButton* deleteButton;

@property (nonatomic, readwrite, strong) UIImageView* videoIndicator;
@property (nonatomic, strong) UIView* starredIndicator;
@property (nonatomic, strong, readwrite) EpisodePlayComboButton* playAccessoryButton;
@property (nonatomic, strong, readwrite) UIPanGestureRecognizer* panRecognizer;
@property (nonatomic, readwrite) BOOL showsDeleteControl;
@property (nonatomic, strong, readwrite) UIView* topSeparatorView;
@property (nonatomic) BOOL showsEditControl;

@end

@implementation EpisodesTableViewCell {
    CGFloat _cachedTextFieldWidth;
    CGSize _cachedTitleSize;
    CGSize _cachedSummarySize;
    BOOL _textSizeCacheValid;
}

- (id)initWithStyle:(UITableViewCellStyle)mystyle reuseIdentifier:(NSString *)reuseIdentifier {
    
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (self)
    {
        // Initialization code.
		self.multipleSelectionBackgroundView = [[UIView alloc] initWithFrame:CGRectZero];
        self.selectedBackgroundView = [[UIView alloc] initWithFrame:CGRectZero];
        
        _panningContentView = [[UIView alloc] initWithFrame:self.contentView.bounds];
        _panningContentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.contentView addSubview:_panningContentView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:ICFontSize(15.0f)];
        _titleLabel.numberOfLines = 20;
        _titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self.panningContentView addSubview:_titleLabel];
        
        _summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _summaryLabel.font = [UIFont systemFontOfSize:ICFontSize(11.0f)];
        _summaryLabel.numberOfLines = 20;
        _summaryLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self.panningContentView addSubview:_summaryLabel];
        
        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        [self.panningContentView addSubview:_iconView];
        
        _durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_durationLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];
		
		[self.panningContentView addSubview:_durationLabel];
		
		_dateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
		_dateLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];
		[self.panningContentView addSubview:_dateLabel];
		
        _consumeIndicator2 = [[ICEpisodeConsumeIndicator alloc] initWithFrame:CGRectZero];
        [self.panningContentView addSubview:_consumeIndicator2];
        

        
		_videoIndicator = [[UIImageView alloc] initWithFrame:CGRectZero];
		_videoIndicator.image = [[UIImage imageNamed:@"Episode Video"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        _videoIndicator.tintColor = [UIColor colorWithWhite:0.6f alpha:1.0f];
		[self.panningContentView addSubview:_videoIndicator];
		
		_starredIndicator = [[UIView alloc] initWithFrame:CGRectZero];
		_starredIndicator.backgroundColor = [UIColor colorWithRed:1.f green:174/255.0 blue:0.f alpha:1.f];
		[self.panningContentView addSubview:_starredIndicator];
        
        _playAccessoryButton = [EpisodePlayComboButton button];
        _playAccessoryButton.frame = CGRectMake(0, 0, 60, 60);//CGRectMake(0, 0, 44, 44);
        [self.panningContentView addSubview:_playAccessoryButton];
        
        
        // Long-press gesture removed — UITableView's contextMenuConfigurationForRowAtIndexPath handles long-press via UIContextMenu

        UIPanGestureRecognizer* panRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        panRecognizer.delegate = self;
        [self addGestureRecognizer:panRecognizer];
        self.panRecognizer = panRecognizer;
        

        _leftPanImage = [[UIImageView alloc] initWithImage:nil];
        _leftPanImage.contentMode = UIViewContentModeCenter;
        _leftPanImage.tintColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
        _leftPanImage.hidden = YES;
        [self.contentView insertSubview:_leftPanImage belowSubview:_panningContentView];

        _rightPanImage = [[UIImageView alloc] initWithImage:nil];
        _rightPanImage.contentMode = UIViewContentModeCenter;
        _rightPanImage.tintColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
        _rightPanImage.hidden = YES;
        [self.contentView insertSubview:_rightPanImage belowSubview:_panningContentView];

        _moreButton = [[UIButton alloc] initWithFrame:CGRectZero];
        [_moreButton setBackgroundColor:self.contentView.backgroundColor];
        _moreButton.hidden = YES;
        _moreButton.titleLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
        [_moreButton setTitle:@"More".ls forState:UIControlStateNormal];
        [_moreButton setTitleColor:[UIColor colorWithWhite:0.6f alpha:1.0f] forState:UIControlStateNormal];
        [_moreButton setTitleColor:[UIColor colorWithWhite:0.6f alpha:0.5f] forState:UIControlStateHighlighted];
        [_moreButton addTarget:self action:@selector(more:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView insertSubview:_moreButton belowSubview:_panningContentView];


        _deleteButton = [[UIButton alloc] initWithFrame:CGRectZero];
        [_deleteButton setBackgroundColor:[UIColor colorWithRed:1.f green:59/255.f blue:48/255.f alpha:1.f]];
        _deleteButton.hidden = YES;
        _deleteButton.titleLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
        [_deleteButton setTitle:@"Delete".ls forState:UIControlStateNormal];
        [_deleteButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [_deleteButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.5] forState:UIControlStateHighlighted];
        [_deleteButton setTitleEdgeInsets:UIEdgeInsetsMake(0, 0, 0, 20)];
        [_deleteButton addTarget:self action:@selector(delete:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentView insertSubview:_deleteButton belowSubview:_panningContentView];
     
        
        UIView* shadowView = [[UIView alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:shadowView];
        self.topSeparatorView = shadowView;
        
        progressView = [[GradientProgressView alloc] initWithFrame:CGRectMake(0, CGRectGetHeight([[self contentView] bounds]) - 2.0f, CGRectGetWidth([[self panningContentView] bounds]), 2.0f)];
        //[progressView setProgress:0.0];
        [self.panningContentView addSubview:progressView];
        
    }
    return self;
}
- (void) dealloc
{
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
}


- (void) prepareForReuse {
    [super prepareForReuse];
    _textSizeCacheValid = NO;

    self.objectValue = nil;
    self.leftPanImage.hidden = YES;
    self.rightPanImage.hidden = YES;
    self.moreButton.hidden = YES;
    self.deleteButton.hidden = YES;
    self.canDelete = NO;
    self.showsDeleteControl = NO;
    self.topSeparator = NO;
    self.upNextStyle = NO;

    self.didPanRight = nil;
    self.didPanLeft = nil;
    self.shouldDelete = nil;
    self.leftSwipeImageProvider = nil;
    self.leftSwipeTintProvider = nil;
    self.rightSwipeImageProvider = nil;
    self.rightSwipeTintProvider = nil;

    [self.multipleSelectionBackgroundView removeFromSuperview];
    
    [self.playAccessoryButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
    
    //[self stopProgressUpdate]; // Ensure timer is stopped when reusing
    [progressView setProgress:0.0];//DevD to do
}

- (void) setBackgroundColor:(UIColor *)backgroundColor
{
    [super setBackgroundColor:backgroundColor];
    self.panningContentView.backgroundColor = backgroundColor;
    
    self.durationLabel.backgroundColor = self.panningContentView.backgroundColor;
    self.dateLabel.backgroundColor = self.panningContentView.backgroundColor;
    self.consumeIndicator2.backgroundColor = self.panningContentView.backgroundColor;
    self.videoIndicator.backgroundColor = self.panningContentView.backgroundColor;
}


- (CDEpisode*) _episode
{
    return (CDEpisode*)self.objectValue;
}

- (void) setObjectValue:(id)objectValue
{
    if (_objectValue != objectValue) {
        _objectValue = objectValue;
        _textSizeCacheValid = NO;

        if (!objectValue) {
            return;
        }
        
        
        CDEpisode* episode = (CDEpisode*)objectValue;
        CDFeed* feed = episode.feed;
                
        // make sure the feed title is not repeated in episode title
        NSString* title = [episode cleanTitleUsingFeedTitle:feed.title];

        if (self.upNextStyle) {
            // Feed title above (bold, slightly larger), episode title below
            self.titleLabel.text = feed.displayTitle ?: feed.title;
            self.titleLabel.font = [UIFont systemFontOfSize:ICFontSize(12.0f) weight:UIFontWeightSemibold];
            self.titleLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;
            self.summaryLabel.text = title;
            self.summaryLabel.font = [UIFont systemFontOfSize:ICFontSize(14.0f)];
        } else {
            self.titleLabel.text = title;
            self.titleLabel.font = [UIFont systemFontOfSize:ICFontSize(15.0f)];
            self.titleLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;

            if (!self.embedded) {
                self.summaryLabel.text = [episode.subtitle tailTruncatedStringWithMaxLength:160];
            }
            else {
                self.summaryLabel.text = episode.feed.title;
            }
            self.summaryLabel.font = [UIFont systemFontOfSize:ICFontSize(11.0f)];
        }
        
        //[self _setCell:cell imageForFeed:theFeed episode:episode];
        
        
        NSInteger duration = episode.duration-episode.position;
        NSString* formattedDuration = nil;
        if (duration > 0) {
            NSValueTransformer* durationTransformer = [NSValueTransformer valueTransformerForName:kICDurationValueTransformer];
            formattedDuration = [durationTransformer transformedValue:@(duration)];
        }
        self.durationLabel.text = (episode.consumed) ? nil : formattedDuration;
        
        NSDate* pubDate = episode.pubDate;
        
        NSValueTransformer* pubdateTransfomer = [NSValueTransformer valueTransformerForName:kICPubdateValueTransformer];
        self.dateLabel.text = [pubdateTransfomer transformedValue:pubDate];
        
    
        [self updatePlayComboButtonState];
        [self updatePlayedAndStarredState];
        
    }
}

+ (CGFloat) proposedHeightWithObjectValue:(id)objectValue tableSize:(CGSize)tableSize imageSize:(CGSize)imageSize embedded:(BOOL)embedded editing:(BOOL)editing
{
    return [self proposedHeightWithObjectValue:objectValue tableSize:tableSize imageSize:imageSize embedded:embedded editing:editing upNextStyle:NO];
}

+ (CGFloat) proposedHeightWithObjectValue:(id)objectValue tableSize:(CGSize)tableSize imageSize:(CGSize)imageSize embedded:(BOOL)embedded editing:(BOOL)editing upNextStyle:(BOOL)upNextStyle
{
    UIFont* textLabelFont;
    UIFont* detailLabelFont;

    if (upNextStyle) {
        textLabelFont = [UIFont systemFontOfSize:ICFontSize(12.0f) weight:UIFontWeightSemibold];
        detailLabelFont = [UIFont systemFontOfSize:ICFontSize(14.0f)];
    } else {
        textLabelFont = [UIFont systemFontOfSize:ICFontSize(15.0f)];
        detailLabelFont = [UIFont systemFontOfSize:ICFontSize(11.0f)];
    }


    CDEpisode* episode = (CDEpisode*)objectValue;
    CDFeed* feed = episode.feed;

    CGFloat w = tableSize.width-25-44;
    if (embedded) {
        w += 44-15;
        if (editing) {
            w -= 65;
        }
    }

    if (imageSize.width > 0) {
        w -= imageSize.width;
        w -= 10;
    }

    // make sure the feed title is not repeated in episode title
    NSString* title = [episode cleanTitleUsingFeedTitle:feed.title];
    if (!title) {
        title = @"No Title".ls;
    }

    NSString* topText;
    NSString* bottomText;

    if (upNextStyle) {
        topText = feed.displayTitle ?: feed.title ?: @"";
        bottomText = title;
    } else {
        topText = title;
        if (!embedded) {
            bottomText = [episode.subtitle tailTruncatedStringWithMaxLength:160];
        } else {
            bottomText = episode.feed.title;
        }
    }

    NSAttributedString* attributedTitle = [[NSAttributedString alloc] initWithString:topText attributes:@{ NSFontAttributeName : textLabelFont }];

    CGSize textLabelSize = [attributedTitle boundingRectWithSize:CGSizeMake(w, 500) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    IC_SIZE_INTEGRAL(textLabelSize);

    CGSize detailLabelSize = CGSizeZero;

    if ([bottomText length] > 0)
    {
        NSAttributedString* attributedSubtitle = [[NSAttributedString alloc] initWithString:bottomText attributes:@{ NSFontAttributeName : detailLabelFont }];

        detailLabelSize = [attributedSubtitle boundingRectWithSize:CGSizeMake(w, 500) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
        IC_SIZE_INTEGRAL(detailLabelSize);
    }

    return MAX(MAX(44.f, 5+textLabelSize.height+detailLabelSize.height+25), imageSize.width +10);
}


- (void) updatePlayComboButtonState
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    CDEpisode* episode = (CDEpisode*)self.objectValue;
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    BOOL cached = [cman episodeIsCached:episode fastLookup:YES];
    BOOL caching = [cman isCachingEpisode:episode];
    BOOL loading = [cman isLoadingEpisode:episode];
    BOOL suspended = [cman isLoadingEpisodeSuspended:episode];
    BOOL streamingCachingCurrentEpisode = (!cached &&
                                           pman.streamingCacheActive &&
                                           [pman.playingEpisode.objectHash isEqualToString:episode.objectHash]);
    double streamingProgress = streamingCachingCurrentEpisode ? pman.streamingCacheProgress : 0.0;
    
    if (cached) {
        self.playAccessoryButton.comboState = kEpisodePlayButtonComboStateFilled;
    }
    else if (streamingCachingCurrentEpisode && loading) {
        self.playAccessoryButton.comboState = kEpisodePlayButtonComboStateFilling;
    }
    else if (streamingCachingCurrentEpisode) {
        self.playAccessoryButton.comboState = kEpisodePlayButtonComboStateHolding;
    }
    else if (caching && (!loading || suspended)) {
        self.playAccessoryButton.comboState = kEpisodePlayButtonComboStateHolding;
    }
    else if (caching && loading) {
        self.playAccessoryButton.comboState = kEpisodePlayButtonComboStateFilling;
    }
    else {
        self.playAccessoryButton.comboState = kEpisodePlayButtonComboStateOutline;
    }
    
    self.playAccessoryButton.fillingProgress = MAX([cman cacheProgressForEpisode:episode], streamingProgress);
}

- (void) updatePlayedAndStarredState
{
    CDEpisode* episode = (CDEpisode*)self.objectValue;
    
    self.titleLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;

    self.consumeIndicator2.consumed = episode.consumed;
    self.consumeIndicator2.progress = (episode.duration > 0) ? (double)episode.position / (double)episode.duration : 0;
    self.consumeIndicator2.tintColor = (episode.consumed) ? [UIColor colorWithWhite:0.5 alpha:1.0] : ICTintColor;
    
    self.starredIndicator.hidden = !episode.starred;
    
    self.playAccessoryButton.tintColor = (episode.consumed) ? ICMutedTextColor : ICTintColor;
    
    double devideTemp = 0.0;
    if (episode.position < episode.duration)
    {
        devideTemp = (double)episode.position / (double)episode.duration;
    }
    double progressPercentage = (episode.duration > 0) ? devideTemp : 0;
    progressView.hidden = self.consumeIndicator2.hidden;

    PlaybackManager* pman = [PlaybackManager playbackManager];
    AudioSession* session = [AudioSession sharedAudioSession];
    CDEpisode* playingEpisode = session.episode;
    if (playingEpisode == episode)
    {
        if (pman.ready) {
            [progressView setProgress:pman.position];
        }
        else if (playingEpisode.duration > 0) {
            [progressView setProgress:(float)playingEpisode.position/(float)playingEpisode.duration];
        }
        else {
            [progressView setProgress:0];
        }
    }
    else
    {
        [progressView setProgress:progressPercentage];
    }
}

- (UIScrollView*) _cellScrollView
{
    UIScrollView* scrollView = nil;
    for(UIScrollView* view in self.subviews) {
        NSString* editControl = [[NSArray arrayWithObjects:@"UITableViewCell", @"ScrollView",nil] componentsJoinedByString:@""];
        Class editControlClass = NSClassFromString(editControl);
        if (editControlClass && [view isKindOfClass:editControlClass]) {
            scrollView = view;
            break;
        }
    }
    return scrollView;
}

- (void) layoutSubviews
{
	[super layoutSubviews];
    
    CDEpisode* episode = (CDEpisode*)self.objectValue;
    
    self.multipleSelectionBackgroundView.backgroundColor = ICTableSelectedBackgroundColor;
    self.selectedBackgroundView.backgroundColor = ICTableSelectedBackgroundColor;

    // Highlight currently loaded episode
    AudioSession* session = [AudioSession sharedAudioSession];
    if (session.episode && session.episode == episode) {
        ICAppearanceManager* aman = [ICAppearanceManager sharedManager];
        if (aman.nightSettingMode) {
            if ([USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack]) {
                self.backgroundColor = [UIColor colorWithWhite:0.12f alpha:1.0f];
            } else {
                self.backgroundColor = [UIColor blackColor];
            }
        } else {
            self.backgroundColor = [UIColor colorWithWhite:0.93f alpha:1.0f];
        }
    } else {
        self.backgroundColor = ICBackgroundColor;
    }

    self.titleLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;
    self.summaryLabel.textColor = ICMutedTextColor;
    self.durationLabel.textColor = ICMutedTextColor;
    self.dateLabel.textColor = ICMutedTextColor;
    self.playAccessoryButton.tintColor = ICTintColor;
    self.topSeparatorView.backgroundColor = ICTableSeparatorColor;
    self.videoIndicator.tintColor = ICMutedTextColor;
    
    
	CGRect bounds = self.bounds;
    self.panningContentView.frame = self.contentView.bounds;
    
	CGRect textLabelRect = self.titleLabel.frame;
    CGRect detailLabelRect = self.summaryLabel.frame;
    CGRect imageViewRect = CGRectMake(10, 5, 56, 56);
    
    // set consume indicator frame
	CGRect consumeIndicatorFrame = CGRectMake(10, 9, 10, 10);
    
    self.videoIndicator.hidden = (!episode.video);
    self.videoIndicator.alpha = (self.editing) ? 0.0 : 1.0;
    CGRect videoIndicatorFrame = CGRectMake(10, (self.consumeIndicator2.hidden)?10:28, 10, 9);
    
    textLabelRect.origin.x = 25;
    textLabelRect.origin.y = 5;
    

	if (self.editing)
    {
        imageViewRect.origin.x = -CGRectGetMinX(self.contentView.frame)-56;
        
        textLabelRect.origin.x = 15;
        detailLabelRect.origin.x = 15;
        consumeIndicatorFrame.origin.x = 0;
        videoIndicatorFrame.origin.x = 0;
    }
    
    
    CGFloat textFieldWidth = CGRectGetWidth(bounds)-25-44; // 44 = play button
    if (self.embedded) {
        textFieldWidth += 44-15;
        if (self.editing) {
            textFieldWidth -= 65;
        }
    }
    
    if (self.iconView.image)
    {
        CGFloat imageRightOffset = (!self.showsEditControl) ? CGRectGetWidth(imageViewRect) + 10 : 38;
        
        textFieldWidth -= CGRectGetWidth(imageViewRect) + 10;
        textLabelRect.origin.x += imageRightOffset;
        consumeIndicatorFrame.origin.x += imageRightOffset;
        videoIndicatorFrame.origin.x += imageRightOffset;
    }
    
    // calculate textLabel height (cached to avoid expensive re-measurement)
    if (!_textSizeCacheValid || textFieldWidth != _cachedTextFieldWidth) {
        _cachedTitleSize = [[self.titleLabel attributedText] boundingRectWithSize:CGSizeMake(textFieldWidth, 500) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
        IC_SIZE_INTEGRAL(_cachedTitleSize);
        _cachedSummarySize = [[self.summaryLabel attributedText] boundingRectWithSize:CGSizeMake(textFieldWidth, 500) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
        IC_SIZE_INTEGRAL(_cachedSummarySize);
        _cachedTextFieldWidth = textFieldWidth;
        _textSizeCacheValid = YES;
    }
    CGSize textLabelSize = _cachedTitleSize;
    textLabelRect.size.height = textLabelSize.height;

    CGSize detailTextSize = _cachedSummarySize;
    
	detailLabelRect.origin.x = CGRectGetMinX(textLabelRect);
	detailLabelRect.origin.y = CGRectGetMaxY(textLabelRect)+2;
	detailLabelRect.size.height = detailTextSize.height;
	
    textLabelRect.size.width = textFieldWidth;
    detailLabelRect.size.width = textFieldWidth;

    
    CGFloat bottomRowLeftAlignment = CGRectGetMinX(textLabelRect);
    
	if (self.dateLabel.text) {
        CGSize dateTextSize = [self.dateLabel.attributedText size];
        IC_SIZE_INTEGRAL(dateTextSize);
		self.dateLabel.frame = CGRectMake(bottomRowLeftAlignment,CGRectGetMaxY(bounds)-20, dateTextSize.width, dateTextSize.height);
        bottomRowLeftAlignment+=dateTextSize.width;
        self.dateLabel.hidden = NO;
	} else {
        self.dateLabel.hidden = YES;
    }
    
    self.dateLabel.backgroundColor = [UIColor clearColor];
    self.durationLabel.backgroundColor = [UIColor clearColor];
	
	if (self.durationLabel.text) {
        CGSize durationTextSize = [self.durationLabel.attributedText size];
        IC_SIZE_INTEGRAL(durationTextSize);
		self.durationLabel.frame = CGRectMake(bottomRowLeftAlignment+5, CGRectGetMaxY(bounds)-20, durationTextSize.width, durationTextSize.height);
        //bottomRowLeftAlignment+=5+durationTextSize.width;
        self.durationLabel.hidden = NO;
	} else {
        self.durationLabel.hidden = YES;
    }
    
    
	self.titleLabel.frame = textLabelRect;
	self.summaryLabel.frame = detailLabelRect;
	self.iconView.frame = imageViewRect;
    self.consumeIndicator2.frame = consumeIndicatorFrame;
    
    self.videoIndicator.frame = videoIndicatorFrame;
    
    self.starredIndicator.frame = (self.editing) ? CGRectMake(-56, 0, 3, CGRectGetHeight(bounds)) : CGRectMake(0, 0, 3, CGRectGetHeight(bounds));
    
    //self.playAccessoryButton.frame = CGRectMake(CGRectGetMaxX(bounds)-44, floorf((CGRectGetHeight(bounds)-44)/2), 44, 44);
    self.playAccessoryButton.frame = CGRectMake(CGRectGetMaxX(bounds)-60, floorf((CGRectGetHeight(bounds)-60)/2), 60, 60);
    self.playAccessoryButton.tintColor = (episode.consumed) ? [UIColor colorWithWhite:0.5f alpha:1.0f] : ICTintColor;
    
    
    self.playAccessoryButton.hidden = (self.embedded || self.editing);
    _starredIndicator.backgroundColor = [UIColor colorWithRed:1.f green:174/255.0 blue:0.f alpha:1.f];
    
    
    
    self.leftPanImage.frame = CGRectMake(-75, 0, 75 , floorf(CGRectGetHeight(bounds)));
    self.rightPanImage.frame = CGRectMake(CGRectGetMaxX(bounds), 0, 75, floorf(CGRectGetHeight(bounds)));
    self.moreButton.frame = CGRectMake(CGRectGetMaxX(bounds), 0, 75, CGRectGetHeight(bounds));
    self.deleteButton.frame = CGRectMake(CGRectGetMaxX(bounds)+75, 0, 75+20, CGRectGetHeight(bounds));
    
    self.topSeparatorView.frame = CGRectMake(0, 0, CGRectGetWidth(self.frame), 0.5f);
    self.topSeparatorView.hidden = !self.topSeparator;
//    if (self.editing) {
//        self.panningContentView.backgroundColor = ICTableSelectedBackgroundColor;
//    } else {
//        self.panningContentView.backgroundColor = [UIColor clearColor];
//    }
    progressView.frame = CGRectMake(0, CGRectGetHeight([[self panningContentView] bounds]) - 2.0f, CGRectGetWidth([[self panningContentView] bounds]), 2.0f);
}

- (void) willTransitionToState:(UITableViewCellStateMask)state
{
    [super willTransitionToState:state];
    
    self.showsEditControl = ((state & UITableViewCellStateShowingEditControlMask) > 0);
    if (self.showsEditControl) {
        self.contentView.backgroundColor = [UIColor clearColor];
        self.panningContentView.backgroundColor = [UIColor clearColor];
    }
    else {
        if (self.editing) {
            self.contentView.backgroundColor = [UIColor clearColor];
            self.panningContentView.backgroundColor = [UIColor clearColor];
        } else {
            self.contentView.backgroundColor = ICTableSeparatorColor;
            self.panningContentView.backgroundColor = ICTableSelectedBackgroundColor;
        }
        
    }
}

#pragma mark - Gestures


- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    UITableView* tableView = [self _tableView];
    
    if (tableView.editing) {
        return NO;
    }
    
    if (gestureRecognizer == self.panRecognizer) {
        CGPoint translation = [self.panRecognizer translationInView:self];
        CGPoint location = [self.panRecognizer locationInView:self];
        
        BOOL shouldBegin = (location.x > 44 && location.x < CGRectGetWidth(tableView.bounds)-44 && fabs(translation.x) / fabs(translation.y) > 1);
        return shouldBegin;
    }
    
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer;
{
    if (gestureRecognizer == self.panRecognizer) {
        if (otherGestureRecognizer == ((UIScrollView*)[self _tableView]).panGestureRecognizer || [otherGestureRecognizer isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
            return NO;
        }
    }
    
	return YES;
}


- (UITableView*) _tableView
{
    UIView* view = self.superview;
    
    while (view && ![view isKindOfClass:[UITableView class]]) {
        view = view.superview;
    }
    
    return (UITableView*)view;
}


- (void) handleLongPress:(UILongPressGestureRecognizer*)recognizer
{
    UITableView* tableView = [self _tableView];
	if (recognizer.state == UIGestureRecognizerStateBegan && !tableView.editing)
	{
        [self more:recognizer];
    }
}



- (UIImage*) _leftPanImageActive:(BOOL)active
{
    BOOL filled = ![self _episode].consumed;
    if (active) {
        filled = !filled;
    }
    
    return (filled) ? [UIImage imageNamed:@"Pan Played Fill"] : [UIImage imageNamed:@"Pan Played"];
}

- (UIImage*) _rightPanImageActive:(BOOL)active
{
    BOOL filled = [self _episode].starred;
    if (active) {
        filled = !filled;
    }
    return (filled) ? [UIImage imageNamed:@"Pan Starred Fill"] : [UIImage imageNamed:@"Pan Starred"];
}

- (void) _animateActivatePanToPoint:(CGFloat)point additionalAnimations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion
{
    CGRect b = self.contentView.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = CGRectGetHeight(b);
    
    [UIView animateWithDuration:0.3
                          delay:0.0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.0
                        options:0
                     animations:^{
                         
                         self.panningContentView.frame = CGRectMake(point, 0, w, h);
                         
                         if (animations) {
                             animations();
                         }

                     } completion:^(BOOL finished) {
                         
                         [UIView animateWithDuration:0.3
                                               delay:0.0
                              usingSpringWithDamping:1.0
                               initialSpringVelocity:0.0
                                             options:0
                                          animations:^{

                                              self.panningContentView.frame = b;

                                          } completion:^(BOOL finished) {

                                              self.leftPanImage.frame = CGRectMake(-75, 0, 75, h);
                                              self.rightPanImage.frame = CGRectMake(w, 0, 75, h);

                                              self.leftPanImage.hidden = YES;
                                              self.rightPanImage.hidden = YES;

                                              if (completion) {
                                                  completion(finished);
                                              }

                                          }];
                         
                     }];
}

- (void) handlePan:(UIPanGestureRecognizer*)recognizer
{
    CGPoint translation = [recognizer translationInView:self.contentView];
    CGRect b = self.contentView.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = CGRectGetHeight(b);
    CGFloat fh = floorf(h);
    
    switch (recognizer.state)
    {
        case UIGestureRecognizerStateBegan:
        {
            self.contentView.backgroundColor = ICTableSeparatorColor;

            if (self.didPanRight) {
                self.leftPanImage.image = self.rightSwipeImageProvider ? self.rightSwipeImageProvider() : [self _leftPanImageActive:YES];
                self.leftPanImage.tintColor = self.rightSwipeTintProvider ? self.rightSwipeTintProvider() : [UIColor colorWithWhite:0.5f alpha:1.0f];
                self.leftPanImage.hidden = NO;
            } else {
                self.leftPanImage.hidden = YES;
                self.leftPanImage.image = nil;
            }

            if (self.didPanLeft) {
                self.rightPanImage.image = self.leftSwipeImageProvider ? self.leftSwipeImageProvider() : nil;
                self.rightPanImage.tintColor = self.leftSwipeTintProvider ? self.leftSwipeTintProvider() : [UIColor colorWithWhite:0.5f alpha:1.0f];
                self.rightPanImage.hidden = NO;
            } else {
                self.rightPanImage.hidden = YES;
                self.rightPanImage.image = nil;
            }

            if (self.panDidBegin) {
                UITableView* tableView = [self _tableView];
                NSIndexPath* indexPath = [tableView indexPathForCell:self];
                self.panDidBegin(indexPath);
            }
        }
        case UIGestureRecognizerStateChanged:
        {
            self.panningContentView.frame = CGRectMake(translation.x, 0, w, h);

            self.leftPanImage.frame = CGRectMake(MIN(-75+translation.x, 0), 0, 75, fh);
            self.rightPanImage.frame = CGRectMake(MAX(w+translation.x, w-75), 0, 75, fh);

            // change leftPan image depending on translation coordinate (only for legacy non-provider mode)
            if (!self.rightSwipeImageProvider) {
                if (translation.x >= 75 && self.leftPanImage.image != [self _leftPanImageActive:YES]) {
                    self.leftPanImage.image = [self _leftPanImageActive:YES];
                }
                else if (translation.x < 75 && self.leftPanImage.image != [self _leftPanImageActive:NO]) {
                    self.leftPanImage.image = [self _leftPanImageActive:NO];
                }
            }

            break;
        }
        case UIGestureRecognizerStateEnded:
        {
            UITableView* tableView = [self _tableView];
            NSIndexPath* indexPath = [tableView indexPathForCell:self];

            // right swipe active
            if (translation.x >= 75 && self.didPanRight)
            {
                recognizer.enabled = NO;

                if (self.didPanRight && indexPath) {
                    self.didPanRight(indexPath);
                }

                [self _animateActivatePanToPoint:75 additionalAnimations:NULL completion:^(BOOL finished) {
                    recognizer.enabled = YES;
                }];

                break;
            }

            // left swipe active
            else if (translation.x <= -75 && self.didPanLeft)
            {
                recognizer.enabled = NO;

                if (self.didPanLeft && indexPath) {
                    self.didPanLeft(indexPath);
                }

                [self _animateActivatePanToPoint:-75 additionalAnimations:NULL completion:^(BOOL finished) {
                    recognizer.enabled = YES;
                }];

                break;
            }
        }
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
        {
            recognizer.enabled = NO;
            self.showsDeleteControl = NO;

            [UIView animateWithDuration:0.3
                                  delay:0.0
                 usingSpringWithDamping:1.0
                  initialSpringVelocity:0.0
                                options:0
                             animations:^{
                                 self.panningContentView.frame = b;
                                 self.leftPanImage.frame = CGRectMake(-75, 0, 75, fh);
                                 self.rightPanImage.frame = CGRectMake(w, 0, 75, fh);

                             } completion:^(BOOL finished) {
                                 recognizer.enabled = YES;

                                 self.leftPanImage.hidden = YES;
                                 self.rightPanImage.hidden = YES;
                             }
             ];
        }
        default:
            break;
    }
}

- (void) delete:(id)sender
{
    if (self.shouldDelete)
    {
        UITableView* tableView = [self _tableView];
        NSIndexPath* indexPath = [tableView indexPathForCell:self];
        
        self.shouldDelete(indexPath);
    }
}

- (void) more:(id)sender
{
    if (self.shouldShowMore)
    {
        UITableView* tableView = [self _tableView];
        NSIndexPath* indexPath = [tableView indexPathForCell:self];
        
        self.shouldShowMore(indexPath);
    }
}


- (void) cancelDelete:(id)sender
{
    CGRect b = self.contentView.bounds;
    CGFloat w = CGRectGetWidth(b);
    CGFloat h = CGRectGetHeight(b);
    CGFloat fh = floorf(h);

    [UIView animateWithDuration:0.3
                          delay:0.0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0.0
                        options:0
                     animations:^{
                         self.panningContentView.frame = b;
                         self.leftPanImage.frame = CGRectMake(-75, 0, 75, fh);
                         self.rightPanImage.frame = CGRectMake(w, 0, 75, fh);

                     } completion:^(BOOL finished) {

                         self.leftPanImage.hidden = YES;
                         self.rightPanImage.hidden = YES;

                         self.showsDeleteControl = NO;
                     }
     ];

}

@end
