//
//  PlaybackControlViewController.m
//  Instacast
//
//  Created by Martin Hering on 09.10.12.
//
//

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <MediaPlayer/MPVolumeView.h>

#import "PlaybackControlsViewController.h"
#import "PlayerController.h"
#import "PlayerSpeedButton.h"
#import "PlayerTimerButton.h"
#import "ICProgressSlider.h"
#import "ICMetadata.h"
#import "CDEpisode+ShowNotes.h"

#import "VDModalInfo.h"
#import "ICVolumeView.h"
#import "InstacastAppDelegate.h"
#import "ImageFunctions.h"
#import <MediaPlayer/MediaPlayer.h>

// Container that only accepts touches within 3x the thumb area
@interface ICVolumeThumbHitView : UIView
@property (nonatomic, strong) MPVolumeView *volumeView;
@property (nonatomic, strong) UIView *debugBorderView;
@property (nonatomic, strong) CADisplayLink *debugLink;
@end

@implementation ICVolumeThumbHitView

- (void)dealloc {
    [_debugLink invalidate];
}

- (UISlider *)_findSlider {
    for (UIView *subview in self.volumeView.subviews) {
        if ([subview isKindOfClass:[UISlider class]]) {
            return (UISlider *)subview;
        }
    }
    return nil;
}

- (CGRect)_expandedThumbRect {
    UISlider *slider = [self _findSlider];
    if (!slider) return CGRectZero;

    CGRect trackRect = [slider trackRectForBounds:slider.bounds];
    CGRect thumbRect = [slider thumbRectForBounds:slider.bounds trackRect:trackRect value:slider.value];
    CGRect thumbInSelf = [self convertRect:thumbRect fromView:slider];

    // 3x height, 4.5x width (3x * 1.5)
    CGFloat expandX = thumbInSelf.size.width * 1.5;
    CGFloat expandY = thumbInSelf.size.height;
    return CGRectInset(thumbInSelf, -expandX, -expandY);
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint([self _expandedThumbRect], point);
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if ([self pointInside:point withEvent:event]) {
        return self; // handle all touches ourselves via gesture recognizers
    }
    return nil;
}

- (void)setupGestures {
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_handlePan:)];
    [self addGestureRecognizer:pan];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_handleTap:)];
    [self addGestureRecognizer:tap];
}

- (void)_handlePan:(UIPanGestureRecognizer *)pan {
    UISlider *slider = [self _findSlider];
    if (!slider) return;

    CGPoint point = [pan locationInView:slider];
    CGRect trackRect = [slider trackRectForBounds:slider.bounds];
    float value = (point.x - trackRect.origin.x) / trackRect.size.width;
    value = MAX(0.0f, MIN(1.0f, value));

    [slider setValue:value animated:NO];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)_handleTap:(UITapGestureRecognizer *)tap {
    UISlider *slider = [self _findSlider];
    if (!slider) return;

    CGPoint point = [tap locationInView:slider];
    CGRect trackRect = [slider trackRectForBounds:slider.bounds];
    float value = (point.x - trackRect.origin.x) / trackRect.size.width;
    value = MAX(0.0f, MIN(1.0f, value));

    [slider setValue:value animated:YES];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)startDebugBorder {
    self.debugBorderView = [[UIView alloc] init];
    self.debugBorderView.layer.borderColor = [UIColor redColor].CGColor;
    self.debugBorderView.layer.borderWidth = 2.0;
    self.debugBorderView.userInteractionEnabled = NO;
    [self addSubview:self.debugBorderView];

    self.debugLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_updateDebug)];
    self.debugLink.preferredFramesPerSecond = 15;
    [self.debugLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDebugBorder {
    [self.debugLink invalidate];
    self.debugLink = nil;
    [self.debugBorderView removeFromSuperview];
    self.debugBorderView = nil;
}

- (void)_updateDebug {
    self.debugBorderView.frame = [self _expandedThumbRect];
}

@end

@interface PlaybackControlsViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, weak) NSTimer* progressTimer;
@property (nonatomic, weak) NSTimer* skipTimer;
@property (nonatomic) BOOL toolsVisible;
@property (nonatomic, strong) VDModalInfo* scrubbingModalInfo;
@property (nonatomic, strong) ICVolumeThumbHitView *volumeHitView;
@property (nonatomic, strong) UIImage* transcriptImageNormal;
@property (nonatomic, strong) UIImage* transcriptImageActive;
@end

@implementation PlaybackControlsViewController {
    BOOL _wasPlaying;
    BOOL _observing;
    CGRect _controllerRect;
    CGRect _toolsRect;
}

+ (id) playbackControlViewController
{
    return [[self alloc] initWithNibName:@"PlayerControlView" bundle:nil];
}


- (void) createVolumeViews
{
    CGRect b = self.view.bounds;
    CGFloat sliderWidth = CGRectGetWidth(b) - 120;
    CGFloat sliderHeight = 87;

    // Container: same frame as original volumeView, intercepts touches only near thumb
    ICVolumeThumbHitView *hitView = [[ICVolumeThumbHitView alloc] initWithFrame:CGRectMake(57.5, 82.333, sliderWidth, sliderHeight)];
    hitView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    hitView.backgroundColor = [UIColor clearColor];

    // MPVolumeView: fills container; on iPad the track renders higher, so offset down
    CGFloat volumeViewYOffset = 0;
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        volumeViewYOffset = 20;
    }
    MPVolumeView* volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(0, volumeViewYOffset, sliderWidth, sliderHeight)];
    volumeView.backgroundColor = [UIColor clearColor];
    volumeView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    volumeView.userInteractionEnabled = NO; // container handles all touches
    if (@available(iOS 16, *)) {
        for (UIView *subview in volumeView.subviews) {
            if ([subview isKindOfClass:[UIButton class]]) {
                subview.hidden = YES;
                break;
            }
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [volumeView setValue:@(NO) forKey:@"showsRouteButton"];
#pragma clang diagnostic pop
    }

    [hitView addSubview:volumeView];
    hitView.volumeView = volumeView;
    [hitView setupGestures];

    [self.view addSubview:hitView];
    self.volumeHitView = hitView;
    self.volumeView = volumeView;

    ICVolumeView* routeButton = [[ICVolumeView alloc] initWithFrame:CGRectMake(8, -17, 84, 84)];
    routeButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    routeButton.backgroundColor = [UIColor clearColor];
    // showsRouteButton/showsVolumeSlider/setRouteButtonImage are deprecated in iOS 13+ but still functional
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    routeButton.showsVolumeSlider = NO;
    //DevD To DO
    routeButton.showsRouteButton = YES;
    [routeButton setRouteButtonImage:[[UIImage imageNamed:@"Player AirPlay"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    [routeButton setRouteButtonImage:[UIImage imageNamed:@"Player AirPlay Active"] forState:UIControlStateSelected];
#pragma clang diagnostic pop
    
    [self.toolsView addSubview:routeButton];
    self.routeButton = routeButton;

    UIButton* transcriptButton = [UIButton buttonWithType:UIButtonTypeSystem];
    transcriptButton.frame = CGRectMake(8, -17, 84, 84);
    transcriptButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    transcriptButton.backgroundColor = [UIColor clearColor];
    UIImageSymbolConfiguration* normalConfig = [UIImageSymbolConfiguration configurationWithPointSize:23 weight:UIImageSymbolWeightRegular];
    UIImageSymbolConfiguration* activeConfig = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    self.transcriptImageNormal = [[UIImage systemImageNamed:@"captions.bubble" withConfiguration:normalConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    self.transcriptImageActive = [[UIImage systemImageNamed:@"captions.bubble.fill" withConfiguration:activeConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (!self.transcriptImageNormal || !self.transcriptImageActive) {
        ErrLog(@"[TranscriptControl] transcript symbol not found: captions.bubble");
    }
    [transcriptButton setImage:self.transcriptImageNormal forState:UIControlStateNormal];
    transcriptButton.contentEdgeInsets = UIEdgeInsetsMake(14, 14, 14, 14);
    [transcriptButton addTarget:self action:@selector(toggleTranscript:) forControlEvents:UIControlEventTouchUpInside];
    transcriptButton.accessibilityLabel = @"Transcript".ls;
    transcriptButton.hidden = YES;
    [self.toolsView addSubview:transcriptButton];
    self.transcriptButton = transcriptButton;
    DebugLog(@"[TranscriptControl] created route=%@ transcript=%@ transcriptImage=%@ transcriptImageActive=%@",
             self.routeButton,
             self.transcriptButton,
             self.transcriptImageNormal,
             self.transcriptImageActive);
    [self updateToolButtonsVisibility];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

    self.shown = YES;
    self.tintColor = ICTintColor;
    [self createVolumeViews];
    self.timeSlider.accessibilityLabel = @"Time Value".ls;

    // Chapter title label between time labels
    UILabel* chapterLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    chapterLabel.font = [UIFont systemFontOfSize:16];
    chapterLabel.textAlignment = NSTextAlignmentCenter;
    chapterLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    chapterLabel.backgroundColor = [UIColor clearColor];
    chapterLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:chapterLabel];
    self.chapterTitleLabel = chapterLabel;

    self.timeSlider.enabled = NO;
	[self updateControlsUI];
    
    [self.backButton setImage:[[UIImage imageNamed:@"Player Backward"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                     forState:UIControlStateNormal];
    
    [self.forwardButton setImage:[[UIImage imageNamed:@"Player Forward"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                     forState:UIControlStateNormal];
    
    [self.bookmarkButton setImage:[[UIImage imageNamed:@"Player Bookmark"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                       forState:UIControlStateNormal];
    
    [self.actionButton setImage:[[UIImage imageNamed:@"Player Share"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                     forState:UIControlStateNormal];
    
    
    [self.volumeMinButton setImage:[[UIImage imageNamed:@"Player Volume Min"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                          forState:UIControlStateNormal];
    [self.volumeMaxButton setImage:[[UIImage imageNamed:@"Player Volume Max"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                          forState:UIControlStateNormal];

    // Icons are decorative only — not touchable
    self.volumeMinButton.enabled = NO;
    self.volumeMinButton.userInteractionEnabled = NO;
    self.volumeMaxButton.enabled = NO;
    self.volumeMaxButton.userInteractionEnabled = NO;
}

- (void) updateAppearance
{
    self.view.backgroundColor = ICBackgroundColor;

    self.elapsedTimeLabel.textColor = ICTextColor;
    self.remainingTimeLabel.textColor = ICTextColor;
    self.chapterTitleLabel.textColor = ICTextColor;

    CGFloat white;
    [ICTextColor getWhite:&white alpha:NULL];
    white = (white > 0.5f) ? 1.0f : 0.0f;
    self.timeSlider.progressColor = [UIColor colorWithWhite:white alpha:0.1f];

    self.volumeMinButton.tintColor = [UIColor colorWithWhite:white alpha:0.2f];
    self.volumeMaxButton.tintColor = [UIColor colorWithWhite:white alpha:0.2f];

    CGFloat scale = self.view.window.screen.scale ?: [UIScreen mainScreen].scale;
    UIImage* maxImage = ICImageFromByDrawingInContextWithScale(CGSizeMake(3, 2), NO, scale, ^(void) {
        UIBezierPath* rectanglePath = [UIBezierPath bezierPathWithRoundedRect: CGRectMake(0, 0, 3, 2) cornerRadius:1];

        CGFloat white;
        [ICTextColor getWhite:&white alpha:NULL];
        white = (white > 0.5f) ? 1.0f : 0.0f;
        [[UIColor colorWithWhite:white alpha:0.2] setFill];
        [rectanglePath fillWithBlendMode:kCGBlendModeNormal alpha:1.0];
    });
    maxImage = [maxImage resizableImageWithCapInsets:UIEdgeInsetsMake(0, 1, 0, 1)];
    [self.volumeView setMaximumVolumeSliderImage:maxImage forState:UIControlStateNormal];

    self.tintColor = ICTintColor;
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self updateAppearance];

    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        CGFloat width = CGRectGetWidth(self.view.bounds);
        CGFloat offset = (self.toolsVisible) ? -width : 0;
        
        self.controllerView.frame = CGRectMake(0+offset, 0, width, 96);
        self.toolsView.frame = CGRectMake(width+offset, 0, width, 96);
    }
    
    NSTimeInterval delayInSeconds = 0.2;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        if (self.volumeView)
        {
            [self.volumeView setVolumeThumbImage:[UIImage imageNamed:@"Video Slider Thumb"] forState:UIControlStateNormal];
        }
       /* BOOL isTouchActive = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
        if (isTouchActive)
        {
            if ([USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer] == PlaybackStopTimeNoValue)
            {
                NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                if ([USER_DEFAULTS objectForKey:UncompletedSleepTimeInterval] != nil)
                {
                    [AudioSession sharedAudioSession].timerValue = [USER_DEFAULTS integerForKey:UncompletedSleepTimeInterval];
                }
                else if (lastSleepTimer > 0)
                {
                    [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                }
                else
                {
                    [AudioSession sharedAudioSession].timerValue = PlaybackStopTime5min;
                }
            }
        }*/
    });
}

      
- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    /*
    if (self.volumeView.hidden) {
        self.volumeView.hidden = NO;
        self.volumeView.alpha = 1;
        [UIView animateWithDuration:0.3 animations:^{
            self.volumeView.alpha = 1;
        }];
    }*/
}

- (void) viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];

    UIEdgeInsets safeAreaInsets = UIEdgeInsetsMake(20, 0, 0, 0);
    if (@available(iOS 11.0, *)) {
        safeAreaInsets = self.view.safeAreaInsets;
    }

    CGRect b = self.view.bounds;
    self.toolsView.frame = CGRectMake(0, CGRectGetHeight(b)-safeAreaInsets.bottom-50, CGRectGetWidth(b), 50);

    // Reposition toolbar buttons: Speed and Timer 50% bigger than the others
    CGFloat smallSize = 84;
    CGFloat bigSize = 101; // 20% bigger than original for Speed and Timer
    CGFloat toolsWidth = CGRectGetWidth(self.toolsView.bounds);
    CGFloat toolsHeight = CGRectGetHeight(self.toolsView.bounds);
    NSMutableArray *toolButtons = [NSMutableArray array];
    for (UIView *subview in self.toolsView.subviews) {
        if (subview.hidden) {
            continue;
        }
        [toolButtons addObject:subview];
    }
    DebugLog(@"[TranscriptControl] layout toolsView=%@ visibleToolButtons=%ld transcriptHidden=%@ routeHidden=%@",
             NSStringFromCGRect(self.toolsView.frame),
             (long)toolButtons.count,
             self.transcriptButton.hidden ? @"YES" : @"NO",
             self.routeButton.hidden ? @"YES" : @"NO");
    [toolButtons sortUsingComparator:^NSComparisonResult(UIView *v1, UIView *v2) {
        return [@(v1.frame.origin.x) compare:@(v2.frame.origin.x)];
    }];
    if (toolButtons.count == 0) {
        return;
    }
    CGFloat totalButtonWidth = 0;
    for (UIView *button in toolButtons) {
        if ([button isKindOfClass:[PlayerSpeedButton class]] || [button isKindOfClass:[PlayerTimerButton class]]) {
            totalButtonWidth += bigSize;
        } else {
            totalButtonWidth += smallSize;
        }
    }
    CGFloat spacing = (toolsWidth - totalButtonWidth) / (toolButtons.count + 1);
    CGFloat xPos = spacing;
    for (UIView *button in toolButtons) {
        CGFloat size;
        if ([button isKindOfClass:[PlayerSpeedButton class]] || [button isKindOfClass:[PlayerTimerButton class]]) {
            size = bigSize;
        } else {
            size = smallSize;
        }
        CGFloat yPos = (toolsHeight - size) / 2.0;
        button.frame = CGRectMake(xPos, yPos, size, size);
        if (button == self.transcriptButton || button == self.routeButton) {
            DebugLog(@"[TranscriptControl] layout button %@ frame=%@ hidden=%@",
                     (button == self.transcriptButton) ? @"transcript" : @"route",
                     NSStringFromCGRect(button.frame),
                     button.hidden ? @"YES" : @"NO");
        }
        xPos += size + spacing;
    }

    // Position chapter title label between the two time labels
    CGFloat labelX = CGRectGetMaxX(self.elapsedTimeLabel.frame) + 4;
    CGFloat labelW = CGRectGetMinX(self.remainingTimeLabel.frame) - 4 - labelX;
    self.chapterTitleLabel.frame = CGRectMake(labelX, CGRectGetMinY(self.elapsedTimeLabel.frame), labelW, CGRectGetHeight(self.elapsedTimeLabel.frame));
}

- (void) willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        CGFloat width = CGRectGetWidth(self.view.bounds);
        CGFloat offset = (self.toolsVisible) ? -width : 0;
        
        self.controllerView.frame = CGRectMake(0+offset, 0, width, 96);
        self.toolsView.frame = CGRectMake(width+offset, 0, width, 96);
    }
}

- (float)volume
{
    return [[PlaybackManager playbackManager] volume];
}

- (void)setVolume:(float)newVolume
{
    [[PlaybackManager playbackManager] setVolume:newVolume];
}

- (void)handleVolumeTap:(UITapGestureRecognizer *)recognizer
{
    CGPoint point = [recognizer locationInView:self.volumeView];
    CGFloat width = CGRectGetWidth(self.volumeView.bounds);
    float value = MAX(0.0f, MIN(1.0f, (float)(point.x / width)));

    for (UIView *subview in self.volumeView.subviews) {
        if ([subview isKindOfClass:[UISlider class]]) {
            [(UISlider*)subview setValue:value animated:YES];
            [(UISlider*)subview sendActionsForControlEvents:UIControlEventValueChanged];
            return;
        }
    }
}


- (UIColor*) tintColor {
    return self.view.tintColor;
}

- (void) setTintColor:(UIColor *)tintColor
{
    self.view.tintColor = tintColor;
}

- (void) setShown:(BOOL)shown
{
    if (_shown != shown) {
        _shown = shown;
        DebugLog(@"[TranscriptControl] setShown=%@ (volumeHitView hidden before=%@)",
                 shown ? @"YES" : @"NO",
                 self.volumeHitView.hidden ? @"YES" : @"NO");
        
        // when controller is not shown, we want the HUD for volume
        self.volumeHitView.hidden = !shown;
        [self updateToolButtonsVisibility];
    }
}

- (void)setTranscriptAvailable:(BOOL)transcriptAvailable
{
    if (_transcriptAvailable != transcriptAvailable) {
        DebugLog(@"[TranscriptControl] setTranscriptAvailable %@ -> %@",
                 _transcriptAvailable ? @"YES" : @"NO",
                 transcriptAvailable ? @"YES" : @"NO");
        _transcriptAvailable = transcriptAvailable;
        if (!transcriptAvailable) {
            _transcriptVisible = NO;
        }
        [self updateToolButtonsVisibility];
    }
}

- (void)setTranscriptVisible:(BOOL)transcriptVisible
{
    if (_transcriptVisible != transcriptVisible) {
        DebugLog(@"[TranscriptControl] setTranscriptVisible %@ -> %@",
                 _transcriptVisible ? @"YES" : @"NO",
                 transcriptVisible ? @"YES" : @"NO");
        _transcriptVisible = transcriptVisible;
        [self.transcriptButton setImage:(transcriptVisible ? self.transcriptImageActive : self.transcriptImageNormal) forState:UIControlStateNormal];
    }
}

- (void)updateToolButtonsVisibility
{
    BOOL showTranscriptControl = self.shown && self.transcriptAvailable;
    self.transcriptButton.hidden = !showTranscriptControl;
    [self.transcriptButton setImage:(self.transcriptVisible ? self.transcriptImageActive : self.transcriptImageNormal) forState:UIControlStateNormal];
    self.routeButton.hidden = !(self.shown && !self.transcriptAvailable);
    DebugLog(@"[TranscriptControl] updateToolButtonsVisibility shown=%@ available=%@ visible=%@ transcriptHidden=%@ routeHidden=%@ transcriptFrame=%@ routeFrame=%@",
             self.shown ? @"YES" : @"NO",
             self.transcriptAvailable ? @"YES" : @"NO",
             self.transcriptVisible ? @"YES" : @"NO",
             self.transcriptButton.hidden ? @"YES" : @"NO",
             self.routeButton.hidden ? @"YES" : @"NO",
             NSStringFromCGRect(self.transcriptButton.frame),
             NSStringFromCGRect(self.routeButton.frame));

    [self.view setNeedsLayout];
}

- (void)toggleTranscript:(UIButton*)sender
{
    DebugLog(@"[TranscriptControl] toggle tapped available=%@ visible(before)=%@",
             self.transcriptAvailable ? @"YES" : @"NO",
             self.transcriptVisible ? @"YES" : @"NO");
    if (!self.transcriptAvailable) {
        return;
    }

    self.transcriptVisible = !self.transcriptVisible;
    if (self.transcriptToggleHandler) {
        self.transcriptToggleHandler(self.transcriptVisible);
    }
    DebugLog(@"[TranscriptControl] toggle handled visible(after)=%@", self.transcriptVisible ? @"YES" : @"NO");
}

#pragma mark -

- (void) updateTimeUI
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
	if (self.progressTimer) {
		return;
	}
	NSInteger cur = pman.time;
	NSInteger dur = pman.duration;
	NSInteger rem = dur-cur;
	
	NSString* currentText = [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)cur/3600, (long)(cur/60)%60, (long)cur%60];
	self.elapsedTimeLabel.text = currentText;
	
	NSString* remainingText = [NSString stringWithFormat:@"-%ld:%02ld:%02ld", (long)rem/3600, (long)(rem/60)%60, (long)rem%60];
    self.remainingTimeLabel.text = remainingText;
	
	self.timeSlider.value = (double)cur / (double) dur;
	self.timeSlider.progress = pman.playableDuration / pman.duration;

    [self updateChapterTitle];
}

- (void) updateTimeUIDuringSliding
{
	PlaybackManager* pman = [PlaybackManager playbackManager];
	NSInteger dur = pman.duration;
	NSInteger cur = dur * self.timeSlider.value;
	NSInteger rem = dur-cur;
	
	NSString* currentText = [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)cur/3600, (long)(cur/60)%60, (long)cur%60];
	self.elapsedTimeLabel.text = currentText;
	
	NSString* remainingText = [NSString stringWithFormat:@"-%ld:%02ld:%02ld", (long)rem/3600, (long)(rem/60)%60, (long)rem%60];
	self.remainingTimeLabel.text = remainingText;
	

	switch (self.timeSlider.scrubbingMode) {
		case kICProgressSliderScrubbingModeHiSpeed:
			self.scrubbingModalInfo.textLabel.text = @"Hi-Speed Scrubbing".ls;
			break;
		case kICProgressSliderScrubbingModeHalf:
			self.scrubbingModalInfo.textLabel.text = @"Half-Speed Scrubbing".ls;
			break;
		case kICProgressSliderScrubbingModeQuarter:
			self.scrubbingModalInfo.textLabel.text = @"Quarter-Speed Scrubbing".ls;
			break;
		case kICProgressSliderScrubbingModeFine:
			self.scrubbingModalInfo.textLabel.text = @"Fine Scrubbing".ls;
			break;
		default:
			self.scrubbingModalInfo.textLabel.text = nil;
			break;
	}
}

- (void) updateTimeWhenLoading
{
	PlaybackManager* pman = [PlaybackManager playbackManager];

    // If PlaybackManager is ready and has valid values, use those
    if (pman.ready && pman.duration > 0) {
        [self updateTimeUI];
        return;
    }

    // Try to get episode from PlaybackManager first, then AudioSession
    CDEpisode* episode = pman.playingEpisode;
    if (!episode) {
        episode = [AudioSession sharedAudioSession].episode;
    }

    // Use episode's saved position/duration while loading
    if (episode && episode.duration > 0)
	{
		NSInteger cur = episode.position;
		NSInteger dur = episode.duration;
		NSInteger rem = dur-cur;

		NSString* currentText = [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)cur/3600, (long)(cur/60)%60, (long)cur%60];
		self.elapsedTimeLabel.text = currentText;

		NSString* remainingText = [NSString stringWithFormat:@"-%ld:%02ld:%02ld", (long)rem/3600, (long)(rem/60)%60, (long)rem%60];
		self.remainingTimeLabel.text = remainingText;

		self.timeSlider.value = (double)cur / (double) dur;
	}

    if (pman.duration > 0) {
        self.timeSlider.progress = pman.playableDuration / pman.duration;
    }
    else if (episode && episode.duration > 0) {
        // Show 0 progress while loading
        self.timeSlider.progress = 0.0f;
    }
    else {
        self.timeSlider.progress = 0.0f;
    }
}

- (void) updateControlsUI
{
	PlaybackManager* pman = [PlaybackManager playbackManager];
	if (pman.paused) {
		[self.playButton setImage:[[UIImage imageNamed:@"Player Play"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                         forState:UIControlStateNormal];
        self.playButton.accessibilityLabel = @"Play".ls;
	}
    else
    {
		[self.playButton setImage:[[UIImage imageNamed:@"Player Pause"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                         forState:UIControlStateNormal];
        self.playButton.accessibilityLabel = @"Pause".ls;
	}
    
    self.backButton.accessibilityLabel = @"Backward".ls;
    self.forwardButton.accessibilityLabel = @"Forward".ls;
    
    self.playButton.enabled = pman.ready;
    self.backButton.enabled = pman.ready;
    self.forwardButton.enabled = pman.ready;
    self.timeSlider.enabled = pman.ready;
}

- (void) resetControlUI
{
    self.playButton.enabled = NO;
    self.backButton.enabled = NO;
    self.forwardButton.enabled = NO;
    self.timeSlider.enabled = NO;
    self.timeSlider.progress = 0;
    self.timeSlider.value = 0;
    self.timeSlider.chapterMarkers = nil;
    self.chapterTitleLabel.text = nil;
    self.elapsedTimeLabel.text = @"0:00:00";
    self.remainingTimeLabel.text = @"-0:00:00";
}

- (void) updateChapterMarkers
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    NSArray* chapters = pman.chapters;
    NSTimeInterval duration = pman.duration;

    if (!chapters || chapters.count == 0 || duration <= 0) {
        self.timeSlider.chapterMarkers = nil;
        return;
    }

    NSMutableArray* markers = [NSMutableArray array];
    for (id chapter in chapters) {
        // ICMetadataChapter inherits from ICMetadataItem which has CMTime start
        if ([chapter respondsToSelector:@selector(start)]) {
            CMTime startCMTime = [[chapter valueForKey:@"start"] CMTimeValue];
            NSTimeInterval startTime = CMTimeGetSeconds(startCMTime);
            if (!isnan(startTime) && startTime > 0) {
                double normalizedPosition = startTime / duration;
                if (normalizedPosition > 0.0 && normalizedPosition < 1.0) {
                    [markers addObject:@(normalizedPosition)];
                }
            }
        }
    }
    self.timeSlider.chapterMarkers = markers;
}

- (void) updateChapterTitle
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    NSArray* chapters = pman.chapters;
    NSInteger idx = pman.currentChapter;

    if (!chapters || chapters.count == 0 || idx < 0 || idx >= (NSInteger)chapters.count) {
        self.chapterTitleLabel.text = nil;
        return;
    }

    ICMetadataChapter* chapter = chapters[idx];
    self.chapterTitleLabel.text = chapter.title;
}

#pragma mark -

- (void) togglePlay:(id)sender
{
	PlaybackManager* pman = [PlaybackManager playbackManager];
    //devd to do-full screen
	if (pman.paused) {
		[pman play];
        NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
        [AudioSession sharedAudioSession].timerValue = sleepTimer;
        BOOL isTouchActive = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
        if (isTouchActive)
        {
            if ([USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer] == PlaybackStopTimeNoValue)
            {
                NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                if (lastSleepTimer > 0)
                {
                    [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                }
                else
                {
                    [AudioSession sharedAudioSession].timerValue = PlaybackStopTime5min;
                }
            }
        }
	} else {
        BOOL isTouchActive = [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep];
        BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
        
        BOOL isAlwaysTimerActive = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
        
        if (((!isTouchActive) || (!isIntelligentTimerActive)) && ([USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer] != PlaybackStopTimeNoValue))
        {
            NSTimeInterval tRem = [AudioSession sharedAudioSession].timerRemainingTime;
            if (tRem > 0)
            {
                [USER_DEFAULTS setInteger:round(tRem) forKey:UncompletedSleepTimeInterval];
            }
        }
        else if (isAlwaysTimerActive)
        {
            NSTimeInterval tRem = [AudioSession sharedAudioSession].timerRemainingTime;
            if (tRem > 0)
            {
                [USER_DEFAULTS setInteger:round(tRem) forKey:UncompletedSleepTimeInterval];
            }
        }
        [pman pause];
	}
}

- (void) beganChangingProgress:(id)sender
{
	PlaybackManager* pman = [PlaybackManager playbackManager];
    pman.seeking = YES;
	_wasPlaying = !pman.paused;
	[pman pause];
    
    if (!self.scrubbingModalInfo) {
        self.scrubbingModalInfo = [VDModalInfo modalInfo];
        self.scrubbingModalInfo.closableByTap = NO;
        self.scrubbingModalInfo.tapThrough = YES;
        self.scrubbingModalInfo.animation = VDModalInfoAnimationMoveDown;
        self.scrubbingModalInfo.alignment = VDModalInfoAlignmentPhonePlayer;
        self.scrubbingModalInfo.size = CGSizeMake(280, 44);
        
        self.scrubbingModalInfo.textLabel.text = @"Hi-Speed Scrubbing".ls;
        [self.scrubbingModalInfo show];
    }
}

- (void) _asynchronouslySeek:(NSTimer*)timer
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
	self.progressTimer = nil;
	
	double progress = self.timeSlider.value;
	[pman setPosition:progress];
}

- (void) progress:(id)sender
{
	PlaybackManager* pman = [PlaybackManager playbackManager];
	
	if (pman.ready)
	{
		[self.progressTimer invalidate];
		self.progressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_asynchronouslySeek:) userInfo:nil repeats:NO];
		[self updateTimeUIDuringSliding];
	}
}

- (void) endChangingProgress:(id)sender
{
    [self.scrubbingModalInfo close];
    self.scrubbingModalInfo = nil;
    
	[self.progressTimer invalidate];
	self.progressTimer = nil;
	
	PlaybackManager* pman = [PlaybackManager playbackManager];
	
	double progress = self.timeSlider.value;
	[pman setPosition:progress];
    
    if (UIAccessibilityIsVoiceOverRunning()) {
        NSInteger cur = pman.time;
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, [NSString stringWithFormat:@"Playback time set to %d:%02d:%02d".ls, cur/3600, (cur/60)%60, cur%60]);
	}
    
    [pman endSeeking];
	if (_wasPlaying) {
		[pman play];
	}
}

- (void) _beginBackwardDelayed
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
	[pman beginSeekingBackward];
	self.skipTimer = nil;
}

- (void) beginBackwardAction:(id)sender
{
	[self.skipTimer invalidate];
	self.skipTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(_beginBackwardDelayed) userInfo:nil repeats:NO];
}

- (void) endBackwardAction:(id)sender
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
	if (self.skipTimer) {
		[self.skipTimer invalidate];
		self.skipTimer = nil;
		[pman seekBackward];
        [self updateTimeUI];
	}
	else
	{
		[pman endSeeking];
	}
}

- (IBAction) cancelBackwardAction:(id)sender
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
	if (self.skipTimer) {
		[self.skipTimer invalidate];
		self.skipTimer = nil;
        [self updateTimeUI];
	}
	else
	{
		[pman endSeeking];
	}
}

- (void) _beginForwardwardDelayed
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
	[pman beginSeekingForward];
	self.skipTimer = nil;
}

- (void) beginForwardAction:(id)sender
{
	[self.skipTimer invalidate];
	self.skipTimer = [NSTimer scheduledTimerWithTimeInterval:1
													  target:self
													selector:@selector(_beginForwardwardDelayed)
													userInfo:nil
													 repeats:NO];
}

- (void) endForwardAction:(id)sender
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
	if (self.skipTimer) {
		[self.skipTimer invalidate];
		self.skipTimer = nil;
		[pman seekForward];
        [self updateTimeUI];
	}
	else
	{
		[pman endSeeking];
	}
}

- (void) cancelForwardAction:(id)sender
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
	if (self.skipTimer) {
		[self.skipTimer invalidate];
		self.skipTimer = nil;
        [self updateTimeUI];
	}
	else
	{
		[pman endSeeking];
	}
}


#pragma mark -


- (IBAction) addBookmark:(id)sender
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    BOOL wasPlaying = (!pman.paused);
    [pman pause];
    
    
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Add Bookmark".ls
                                                                   message:@"Please enter a bookmark title.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Bookmark title".ls;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                
                                                NSString* text = self.alertController.textFields.firstObject.text;
                                                
                                                [self perform:^(id sender) {

                                                    PlaybackManager* pman = [PlaybackManager playbackManager];
                                                    CDEpisode* episode = pman.playingEpisode;
                                                    CDFeed* feed = episode.feed;
                                                    
                                                    CDBookmark* bookmark = [NSEntityDescription insertNewObjectForEntityForName:@"Bookmark" inManagedObjectContext:DMANAGER.objectContext];
                                                    bookmark.episodeHash = episode.objectHash;
                                                    bookmark.title = text;
                                                    bookmark.position = MAX(0, pman.time - 2);
                                                    bookmark.feedURL = feed.sourceURL;
                                                    bookmark.imageURL = feed.imageURL;
                                                    bookmark.episodeGuid = episode.guid;
                                                    bookmark.feedTitle = feed.title;
                                                    bookmark.episodeTitle = [episode cleanTitleUsingFeedTitle:feed.title];
                                                    
                                                    [DMANAGER addBookmark:bookmark];
                                                    [DMANAGER save];
                                                    
                                                    if (wasPlaying) {
                                                        [pman play];
                                                    }
                                                
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                if (wasPlaying) {
                                                    [pman play];
                                                }

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


@end
