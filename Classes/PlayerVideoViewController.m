//
//  PlayerVideoFullscreenViewController.m
//  Instacast
//
//  Created by Martin Hering on 06/08/14.
//
//

#import <AVKit/AVKit.h>
#import "PlayerVideoViewController.h"
#import "PlayerView.h"
#import "InstacastAppDelegate.h"

static const CGFloat kTopMargin = 30.0;
static const CGFloat kFullscreenButtonSize = 44.0;

// Subclass to detect dismissal
@interface ICFullscreenPlayerViewController : AVPlayerViewController
@property (nonatomic, copy) void (^onDismiss)(void);
@end

@implementation ICFullscreenPlayerViewController
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed && self.onDismiss) {
        self.onDismiss();
    }
}
@end

@interface PlayerVideoViewController () <AVPlayerViewControllerDelegate>
@property (nonatomic, strong) UIView* videoContainerView;
@property (nonatomic, strong) UIButton* fullscreenButton;
@property (nonatomic, readwrite) BOOL fullscreen;
@property (nonatomic, strong) ICFullscreenPlayerViewController* avPlayerViewController;
@end

@implementation PlayerVideoViewController

+ (instancetype) viewController {
    return [[self alloc] initWithNibName:nil bundle:nil];
}

- (void) viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];
    self.view.autoresizingMask = UIViewAutoresizingNone;

    // Video container with top margin
    self.videoContainerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.videoContainerView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.videoContainerView];

    // Player view inside video container
    if (self.playerView) {
        self.playerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.videoContainerView addSubview:self.playerView];
    }

    // Fullscreen button - right aligned, no text, iOS system icon
    self.fullscreenButton = [UIButton buttonWithType:UIButtonTypeSystem];

    // Use SF Symbol for fullscreen (iOS 13+)
    UIImage* fullscreenImage = [UIImage systemImageNamed:@"arrow.up.left.and.arrow.down.right"];
    UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    fullscreenImage = [fullscreenImage imageByApplyingSymbolConfiguration:config];
    [self.fullscreenButton setImage:fullscreenImage forState:UIControlStateNormal];
    [self.fullscreenButton addTarget:self action:@selector(fullscreenButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.fullscreenButton];

    // Tap on video also enters fullscreen
    UITapGestureRecognizer* tapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(fullscreenButtonTapped:)];
    [self.videoContainerView addGestureRecognizer:tapRecognizer];

    [self _updateLayout];
}

- (void) viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self _updateLayout];
}

- (void) _updateLayout
{
    CGRect b = self.view.bounds;
    CGFloat videoHeight = MAX(CGRectGetHeight(b) - kTopMargin - kFullscreenButtonSize, 0);

    self.videoContainerView.frame = CGRectMake(0, kTopMargin, CGRectGetWidth(b), videoHeight);
    self.playerView.frame = self.videoContainerView.bounds;

    // Button positioned at right edge
    self.fullscreenButton.frame = CGRectMake(CGRectGetWidth(b) - kFullscreenButtonSize, kTopMargin + videoHeight, kFullscreenButtonSize, kFullscreenButtonSize);
}

- (void) setPlayerView:(PlayerView *)playerView
{
    if (_playerView != playerView)
    {
        [_playerView removeFromSuperview];

        _playerView = playerView;

        if (self.videoContainerView && playerView) {
            playerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            playerView.frame = self.videoContainerView.bounds;
            [self.videoContainerView addSubview:playerView];
        }
    }
}

- (void) _transitionToFullscreen:(BOOL)fullscreen animated:(BOOL)animated completion:(void (^)(void))completion
{
    if (fullscreen)
    {
        // Check if player is available
        if (!self.playerView.player) {
            if (completion) {
                completion();
            }
            return;
        }

        // Create and configure AVPlayerViewController
        self.avPlayerViewController = [[ICFullscreenPlayerViewController alloc] init];
        self.avPlayerViewController.player = self.playerView.player;
        self.avPlayerViewController.modalPresentationStyle = UIModalPresentationFullScreen;
        self.avPlayerViewController.delegate = self;

        // Set dismissal callback
        __weak typeof(self) weakSelf = self;
        self.avPlayerViewController.onDismiss = ^{
            [weakSelf _cleanupAfterDismiss];
        };

        // Allow Picture-in-Picture if available
        self.avPlayerViewController.canStartPictureInPictureAutomaticallyFromInline = YES;

        // Present the system video player
        [self.parentViewController presentViewController:self.avPlayerViewController animated:animated completion:^{
            weakSelf.fullscreen = YES;

            [((InstacastAppDelegate*)(App.delegate)) setNeedsStatusBarAppearanceUpdate];

            if (completion) {
                completion();
            }
        }];
    }
    else
    {
        // Guard against calling when not in fullscreen
        if (!self.avPlayerViewController) {
            self.fullscreen = NO;
            if (completion) {
                completion();
            }
            return;
        }

        __weak typeof(self) weakSelf = self;
        self.avPlayerViewController.onDismiss = nil; // Prevent callback during programmatic dismiss
        [self.avPlayerViewController dismissViewControllerAnimated:animated completion:^{
            weakSelf.avPlayerViewController = nil;
            weakSelf.fullscreen = NO;

            [((InstacastAppDelegate*)(App.delegate)) setNeedsStatusBarAppearanceUpdate];

            if (completion) {
                completion();
            }
        }];
    }
}

- (void) _cleanupAfterDismiss
{
    // Guard against double cleanup
    if (!self.fullscreen) {
        return;
    }

    self.avPlayerViewController = nil;
    self.fullscreen = NO;

    [((InstacastAppDelegate*)(App.delegate)) setNeedsStatusBarAppearanceUpdate];
}

- (void) setFullscreen:(BOOL)fullscreen animated:(BOOL)animated completion:(void (^)(void))completion
{
    if (_fullscreen != fullscreen)
    {
        if (!self.parentViewController.view.window) {
            if (completion) {
                completion();
            }
            return;
        }

        [self _transitionToFullscreen:fullscreen animated:animated completion:completion];
    }
    else {
        if (completion) {
            completion();
        }
    }
}

- (void) fullscreenButtonTapped:(id)sender
{
    if (!self.fullscreen)
    {
        [self _transitionToFullscreen:YES animated:YES completion:NULL];
    }
}
@end
