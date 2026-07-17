        //
    //  PlaybackViewController.m
    //  Instacast
    //
    //  Created by Martin Hering on 06.01.11.
    //  Copyright 2011 Vemedio. All rights reserved.
    //

    #import "PlaybackViewController.h"
    #import "PlayerController.h"
    #import "StatusBarFixingViewController.h"
#import "InstacastAppDelegate.h"
#import <MediaPlayer/MediaPlayer.h>


    @interface PlaybackViewController () <UIViewControllerTransitioningDelegate>
    @property (nonatomic, strong) CDEpisode* episode;
    @property (nonatomic, assign) BOOL force;
    @property (nonatomic, strong, readwrite) ICPlaybackViewControllerDismissedAnimator* dismissalAnimator;
    @property (nonatomic, readwrite) BOOL interactive;
    @property (nonatomic, readwrite) BOOL pausedForDismiss;
    @end

    @implementation PlaybackViewController {
        BOOL _appeared;
    }


    + (PlaybackViewController*) playbackViewControllerWithEpisode:(CDEpisode*)anEpisode forceReload:(BOOL)force
    {
        PlayerController* playerController = [PlayerController playerController];
        PlaybackViewController* controller = [[self alloc] initWithRootViewController:playerController];
        
        controller.episode = anEpisode;
        controller.force = force;
        
        //controller.transitioningDelegate = controller;
        controller.modalPresentationStyle = UIModalPresentationFullScreen;
        
        return controller;
    }

    + (PlaybackViewController*) playbackViewControllerWithEpisode:(CDEpisode*)anEpisode
    {
        return [self playbackViewControllerWithEpisode:anEpisode forceReload:NO];
    }

    + (PlaybackViewController*) playbackViewController
    {
        return [self playbackViewControllerWithEpisode:nil];
    }

    - (void) dealloc
    {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }

    - (void) _ensureDismissalAnimator
    {
        if (self.dismissalAnimator) {
            return;
        }

        self.dismissalAnimator = [[ICPlaybackViewControllerDismissedAnimator alloc] init];
        self.dismissalAnimator.parent = self;
    }

    - (void) viewDidLoad
    {
        [super viewDidLoad];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

        [self _ensureDismissalAnimator];
        [self addDismissalPanGestureRecognizerToView:self.navigationBar];
    }

    - (void) addDismissalPanGestureRecognizerToView:(UIView*)view
    {
        [self _ensureDismissalAnimator];

        UIPanGestureRecognizer* panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self.dismissalAnimator action:@selector(handlePan:)];
        panGestureRecognizer.delegate = self.dismissalAnimator;
        [view addGestureRecognizer:panGestureRecognizer];
    }

    - (UIColor*) _cachedPlayerTintColor
    {
        if ([USER_DEFAULTS boolForKey:PlayerColorPerPodcastActive]) {
            CDEpisode* episode = [AudioSession sharedAudioSession].episode;
            NSString* cachedHex = [episode.feed stringForKey:@"cachedPlayerTintColor"];
            if (cachedHex.length > 0) {
                UIColor* rawColor = [UIColor colorWithHexString:cachedHex];
                return [PlayerController adjustedPlayerColor:rawColor];
            }
        }
        return ICTintColor;
    }

    - (void) updateAppearance
    {
        self.view.backgroundColor = ICBackgroundColor;
        self.view.tintColor = [self _cachedPlayerTintColor];
        [self setNeedsStatusBarAppearanceUpdate];
    }


    - (void) viewWillAppear:(BOOL)animated
    {
        [super viewWillAppear:animated];

        self.view.backgroundColor = ICBackgroundColor;
        self.view.tintColor = [self _cachedPlayerTintColor];
        
        // xxx: workaround for status bar issues
    //    if (!_appeared) {
    //        self.navigationBar.transform = CGAffineTransformMakeTranslation(0, 20);
    //        _appeared = YES;
    //    }
    }

    - (void) viewDidAppear:(BOOL)animated
    {
        [super viewDidAppear:animated];
        
        // xxx: workaround for status bar issues
        //self.navigationBar.transform = CGAffineTransformIdentity;
    }

    - (UIInterfaceOrientationMask)supportedInterfaceOrientations
    {
        return [self.topViewController supportedInterfaceOrientations];
    }

    - (UIStatusBarStyle)preferredStatusBarStyle
    {
        if ([ICAppearanceManager sharedManager].nightSettingMode)
        {
            return UIStatusBarStyleLightContent;
        }
        else
        {
            return UIStatusBarStyleDarkContent;
        }
        //return [ICAppearanceManager sharedManager].appearance.statusBarStyle;
    }


    #pragma mark -

    - (CDEpisode*) _loadedEpisode
    {
        if (self.episode) {
            return self.episode;
        }
        
        return [AudioSession sharedAudioSession].episode;
    }

    - (BOOL) _requestedEpisodeAlreadyLoaded
    {
        AudioSession* audioSession = [AudioSession sharedAudioSession];
        return (!self.episode && audioSession.episode);
    }

    - (void) _presentFromParentViewController:(UIViewController*)parentViewController autostart:(BOOL)autostart completion:(void (^)(void))completion
    {
        AudioSession* audioSession = [AudioSession sharedAudioSession];
        if (self.episode && (self.force || ![audioSession.episode isEqual:self.episode])) {
            [audioSession playEpisode:self.episode queueUpCurrent:NO at:0 autostart:autostart];
            [self setTimerUpdateOnPlay];
        }
        
        // if audio session knows what to play, but it's not already playing load it
        else if (audioSession.episode && ![PlaybackManager playbackManager].ready) {
            [audioSession playEpisode:audioSession.episode queueUpCurrent:NO at:0 autostart:autostart];
            [self setTimerUpdateOnPlay];
        }
        else if (autostart) {
            //DevD to do : timer things
            [[PlaybackManager playbackManager] play];
            [self setTimerUpdateOnPlay];
        }
    //    [parentViewController.navigationController setNavigationBarHidden:YES animated:YES];
    //    [parentViewController.view addSubview:self.view];
    //    [parentViewController addChildViewController: self];
    //    [self didMoveToParentViewController:parentViewController];
            
        [parentViewController presentViewController:self animated:YES completion:^{
            if (completion) {
                completion();
            }
        }];
    }

-(void)setTimerUpdateOnPlay
{
    NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    [AudioSession sharedAudioSession].timerValue = sleepTimer;
    BOOL isAlwaysTimerActive = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
    if (isAlwaysTimerActive)
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
}

    - (void) presentFromParentViewController:(UIViewController*)parentViewController
    {
        [self presentFromParentViewController:parentViewController autostart:YES completion:NULL];
    }

    - (void) presentFromParentViewController:(UIViewController*)parentViewController autostart:(BOOL)autostart completion:(void (^)(void))completion
    {
        CacheManager* cman = [CacheManager sharedCacheManager];
        PlaybackManager* pman = [PlaybackManager playbackManager];
        
        ICNetworkAccessTechnlogy networkAccessTechnology = App.networkAccessTechnology;
        BOOL warn3G = (networkAccessTechnology < kICNetworkAccessTechnlogyWIFI && ![USER_DEFAULTS boolForKey:EnableStreamingOver3G]);
        BOOL episodeIsCached = (![self _loadedEpisode] || [cman episodeIsCached:[self _loadedEpisode]]);
        BOOL readyAndPlaying = (pman.ready && !pman.paused);
        
        if (!episodeIsCached && warn3G && !([self _requestedEpisodeAlreadyLoaded] && readyAndPlaying))
        {
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Streaming with Cellular Data?".ls
                                                                           message:@"There is currently no WiFi available. Do you really want to use cellular data to stream this episode?".ls
                                                                    preferredStyle:UIAlertControllerStyleAlert];
        
            [alert addAction:[UIAlertAction actionWithTitle:@"Stream".ls
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * action) {
                                                        [self perform:^(id sender) {
                                                            [self _presentFromParentViewController:parentViewController autostart:autostart completion:completion];
                                                        } afterDelay:0.3];
                                                        parentViewController.alertController = nil;
                                                    }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                                      style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction * action) {
                                                        parentViewController.alertController = nil;
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
            parentViewController.alertController = alert;
            [parentViewController presentAlertControllerAnimated:YES completion:NULL];
            return;
        }
        
        CDEpisode* myEpisode = (CDEpisode*)[self _loadedEpisode];
        if (!myEpisode) {
            return;
        }
        
        if (![myEpisode preferedMedium])
        {
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"No media to play.".ls
                                                                           message:@"Unable to play this episode because the media format is not supported.".ls
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * action) {
                                                        parentViewController.alertController = nil;
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
            parentViewController.alertController = alert;
            [parentViewController presentAlertControllerAnimated:YES completion:NULL];
            return;
        }
        
        [self _presentFromParentViewController:parentViewController autostart:autostart completion:completion];
    }

    #pragma mark - UIViewControllerTransitioningDelegate

    - (id<UIViewControllerAnimatedTransitioning>) animationControllerForPresentedController:(UIViewController *)presented presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source
    {
        return [[ICPlaybackViewControllerPresentedAnimator alloc] init];
    }

    - (id<UIViewControllerAnimatedTransitioning>) animationControllerForDismissedController:(UIViewController *)dismissed
    {
        return self.dismissalAnimator;
    }

    - (id<UIViewControllerInteractiveTransitioning>)interactionControllerForDismissal:(id<UIViewControllerAnimatedTransitioning>)animator
    {
        return (self.interactive) ? self.dismissalAnimator : nil;
    }

    - (void) beginInteractiveDismissing
    {
        PlaybackManager* pman = [PlaybackManager playbackManager];
        
        if (pman.movingVideo) {
            if (!pman.paused) {
                [pman pause];
                self.pausedForDismiss = YES;
            }
        }
        
        self.interactive = YES;
        
    //    [UIView animateWithDuration:1
    //                         animations:^{
    //        self.view.frame = CGRectMake(self.view.frame.origin.x ,  self.view.frame.origin.y + self.view.frame.size.height, self.view.frame.size.width, self.view.frame.size.height);
    //
    //                         } completion:^(BOOL finished) {
    //                             [self.parentViewController.navigationController setNavigationBarHidden:NO animated:YES];
    //                             [self willMoveToParentViewController:nil];
    //                             [self.view removeFromSuperview];
    //                             [self removeFromParentViewController];
    //                         }];
        
        if (self.fromSearch == false) {
            self.transitioningDelegate = self;
        }
       
        
        [self dismissViewControllerAnimated:YES completion:^{
            self.transitioningDelegate = NULL;
        }];
    }

    - (void) endInteractiveDismissing
    {
        self.interactive = NO;
        
        if (self.pausedForDismiss) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            [pman play];
            self.pausedForDismiss = NO;
        }
    }
    @end


    #pragma mark -


    @implementation ICPlaybackViewControllerPresentedAnimator

    - (NSTimeInterval)transitionDuration:(id <UIViewControllerContextTransitioning>)transitionContext {
        return 0.3;
    }

    - (void)animateTransition:(id <UIViewControllerContextTransitioning>)transitionContext
    {
        UIViewController *fromVC = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
        UIViewController *toVC = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
        
        CGRect fromInitialFrame = [transitionContext initialFrameForViewController:fromVC];
        
        CGRect toInitialFrame = fromInitialFrame;
        toInitialFrame.origin.y += toInitialFrame.size.height;
        
        toVC.view.frame = toInitialFrame;
        [transitionContext.containerView addSubview:toVC.view];
        
        
        [UIView animateWithDuration:[self transitionDuration:transitionContext]
                              delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{

                             toVC.view.frame = fromInitialFrame;
                         }
                         completion:^(BOOL finished) {
                             if (![transitionContext transitionWasCancelled])
                             {
                                 [transitionContext completeTransition:YES];
                             }
                             else {
                                 [transitionContext completeTransition:NO];
                             }
                         }];
    }
    @end

    @implementation ICPlaybackViewControllerDismissedAnimator

    - (NSTimeInterval)transitionDuration:(id <UIViewControllerContextTransitioning>)transitionContext {
        return 0.3;
    }

    - (void)animateTransition:(id <UIViewControllerContextTransitioning>)transitionContext
    {
        UIViewController *fromVC = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
        UIViewController *toVC = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
        
        CGRect toFinalFrame = [transitionContext finalFrameForViewController:toVC];
        //CGRect toFinalFrame = fromVC.view.window.bounds;
        
        toVC.view.frame = toFinalFrame;
        [transitionContext.containerView insertSubview:toVC.view belowSubview:fromVC.view];

        
        CGRect toFrame = toFinalFrame;
        toFrame.origin.y += toFrame.size.height;
        
        NSTimeInterval duration = [self transitionDuration:transitionContext];
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:UIViewAnimationOptionCurveLinear | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                             fromVC.view.frame = toFrame;
                         }
                         completion:^(BOOL finished) {
                             if (![transitionContext transitionWasCancelled])
                             {
                                 [fromVC.view removeFromSuperview];
                                 
                                 [transitionContext completeTransition:YES];
                             }
                             else {
                                 [transitionContext completeTransition:NO];
                             }
                         }];
    }

    - (void) _driveTransitionWithTranslation:(CGPoint)translation velocity:(CGPoint)velocity recognizerState:(UIGestureRecognizerState)state
    {
        CGRect bounds = self.parent.view.bounds;
        
        switch (state) {
            case UIGestureRecognizerStateBegan:
                [self.parent beginInteractiveDismissing];
                // UIKit has already accumulated a small translation when the pan enters
                // Began. Apply it immediately so the player stays attached to the finger.
                __attribute__((fallthrough));
            case UIGestureRecognizerStateChanged:
            {
                if (translation.y > 0) {
                    CGFloat h = CGRectGetHeight(bounds);
                    CGFloat percent = MIN(MAX(0, (translation.y / h) ), 1);
                    [self updateInteractiveTransition:percent];
                }
                break;
            }
            case UIGestureRecognizerStateEnded:
            case UIGestureRecognizerStateCancelled:
            {
                if (((velocity.y > 1000 && translation.y > 50) || translation.y > CGRectGetHeight(bounds)/2) && state != UIGestureRecognizerStateCancelled) {
                    [self finishInteractiveTransition];
                } else {
                    [self cancelInteractiveTransition];
                }
                [self.parent endInteractiveDismissing];
                
                break;
            }
            default:
                break;
        }

    }

    - (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
    {
        if (![gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
            return YES;
        }

        UIView* gestureView = gestureRecognizer.view;
        CGPoint location = [gestureRecognizer locationInView:gestureView];
        UIView* hitView = [gestureView hitTest:location withEvent:nil];
        for (UIView* view = hitView; view && view != gestureView; view = view.superview) {
            if ([view isKindOfClass:[UIControl class]]) {
                return NO;
            }
        }

        CGPoint velocity = [(UIPanGestureRecognizer*)gestureRecognizer velocityInView:gestureView];
        if (velocity.y <= 0 || velocity.y <= fabs(velocity.x)) {
            return NO;
        }

        // When the pan starts on the chapter artwork (which lives inside the
        // info list's table header), only allow the interactive dismissal while
        // that list is scrolled to the very top. If the artwork has been pushed
        // up (list scrolled down), a downward swipe must first scroll the
        // artwork back into place instead of dismissing the player.
        UITableView* enclosingTableView = nil;
        for (UIView* view = gestureView; view != nil; view = view.superview) {
            if ([view isKindOfClass:[UITableView class]]) {
                enclosingTableView = (UITableView*)view;
                break;
            }
        }
        if (enclosingTableView) {
            CGFloat topY = -enclosingTableView.contentInset.top;
            if (enclosingTableView.contentOffset.y > topY + 1.0) {
                return NO;
            }
        }

        return YES;
    }

    - (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
    {
        return NO;
    }

    - (void) handlePan:(UIPanGestureRecognizer*)recognizer
    {
        CGPoint translation = [recognizer translationInView:self.parent.view];
        CGPoint velocity = [recognizer velocityInView:self.parent.view];

        UIGestureRecognizerState state = [recognizer state];
        [self _driveTransitionWithTranslation:translation velocity:velocity recognizerState:state];
    }


    - (UIViewAnimationCurve)completionCurve
    {
        return UIViewAnimationCurveEaseOut;
    }
    @end
