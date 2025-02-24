//
//  PlaybackControlViewController.m
//  Instacast
//
//  Created by Martin Hering on 09.10.12.
//
//

#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MPVolumeView.h>

#import "PlaybackControlsViewController.h"
#import "PlayerController.h"
#import "ICProgressSlider.h"
#import "CDEpisode+ShowNotes.h"

#import "VDModalInfo.h"
#import "ICVolumeView.h"
#import "InstacastAppDelegate.h"
#import "ImageFunctions.h"
#import <MediaPlayer/MediaPlayer.h>

@interface PlaybackControlsViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, weak) NSTimer* progressTimer;
@property (nonatomic, weak) NSTimer* skipTimer;
@property (nonatomic) BOOL toolsVisible;
@property (nonatomic, strong) VDModalInfo* scrubbingModalInfo;
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
    
    MPVolumeView* volumeView = [[MPVolumeView alloc] initWithFrame:CGRectMake(57.5, 103, CGRectGetWidth(b)-120, 29)];
    volumeView.backgroundColor = [UIColor clearColor];
    volumeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    //volumeView.showsVolumeSlider = YES;
    //[volumeView setVolumeThumbImage:[UIImage imageNamed:@"Video Slider Thumb"] forState:UIControlStateNormal];
    if (@available(iOS 16, *)) {
        for (UIView *subview in volumeView.subviews) {
            if ([subview isKindOfClass:[UIButton class]]) {
                subview.hidden = YES;
                break;
            }
        }
    } else {
        [volumeView setValue:@(NO) forKey:@"showsRouteButton"];
    }
    
    [self.view addSubview:volumeView];
    self.volumeView = volumeView;
    self.volumeView.hidden = NO;//DevD to do
    //self.volumeView.clipsToBounds = true;

    ICVolumeView* routeButton = [[ICVolumeView alloc] initWithFrame:CGRectMake(8, -12, 60, 60)];
    routeButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    routeButton.backgroundColor = [UIColor clearColor];
    routeButton.showsVolumeSlider = NO;
    //DevD To DO
    routeButton.showsRouteButton = YES;
    [routeButton setRouteButtonImage:[[UIImage imageNamed:@"Player AirPlay"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    [routeButton setRouteButtonImage:[UIImage imageNamed:@"Player AirPlay Active"] forState:UIControlStateSelected];
    
    [self.toolsView addSubview:routeButton];
    self.routeButton = routeButton;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.shown = YES;
    self.tintColor = ICTintColor;
    [self createVolumeViews];
    self.timeSlider.accessibilityLabel = @"Time Value".ls;
    
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

}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    self.view.backgroundColor = ICTransparentBackdropColor;
    
    self.elapsedTimeLabel.textColor = ICTextColor;
    self.remainingTimeLabel.textColor = ICTextColor;
    
    
    CGFloat white;
    [ICTextColor getWhite:&white alpha:NULL];
    white = (white > 0.5f) ? 1.0f : 0.0f;
    self.timeSlider.progressColor = [UIColor colorWithWhite:white alpha:0.1f];
    
    self.volumeMinButton.tintColor = [UIColor colorWithWhite:white alpha:0.2f];
    self.volumeMaxButton.tintColor = [UIColor colorWithWhite:white alpha:0.2f];
    
    UIImage* maxImage = ICImageFromByDrawingInContextWithScale(CGSizeMake(3, 2), NO, self.view.window.screen.scale, ^() {
        UIBezierPath* rectanglePath = [UIBezierPath bezierPathWithRoundedRect: CGRectMake(0, 0, 3, 2) cornerRadius:1];
        
        CGFloat white;
        [ICTextColor getWhite:&white alpha:NULL];
        white = (white > 0.5f) ? 1.0f : 0.0f;
        [[UIColor colorWithWhite:white alpha:0.2] setFill];
        [rectanglePath fillWithBlendMode:kCGBlendModeNormal alpha:1.0];
    });
    maxImage = [maxImage resizableImageWithCapInsets:UIEdgeInsetsMake(0, 1, 0, 1)];
    [self.volumeView setMaximumVolumeSliderImage:maxImage forState:UIControlStateNormal];
    
    
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
        
        // when controller is not shown, we want the HUD for volume
        self.volumeView.hidden = !shown;
        self.routeButton.hidden = !shown;//Devd TO Do
    }
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
    
    //DebugLog(@"cur %d", cur);
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
	CDEpisode* episode = [AudioSession sharedAudioSession].episode;

    if (episode.duration > 0 && episode.position < episode.duration)
	{
		NSInteger cur = pman.time;
		NSInteger dur = pman.duration;
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
    self.elapsedTimeLabel.text = @"0:00:00";
    self.remainingTimeLabel.text = @"-0:00:00";
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
                [USER_DEFAULTS synchronize];
            }
        }
        else if (isAlwaysTimerActive)
        {
            NSTimeInterval tRem = [AudioSession sharedAudioSession].timerRemainingTime;
            if (tRem > 0)
            {
                [USER_DEFAULTS setInteger:round(tRem) forKey:UncompletedSleepTimeInterval];
                [USER_DEFAULTS synchronize];
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
    
	if (_wasPlaying) {
		[pman play];
	}
	pman.seeking = NO;
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
