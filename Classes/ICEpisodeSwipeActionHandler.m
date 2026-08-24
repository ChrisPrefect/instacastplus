#import "ICEpisodeSwipeActionHandler.h"

#import "AppleWatchSyncManager.h"
#import "AudioSession+UpNextPlaylist.h"
#import "CacheManager.h"
#import "CDModel.h"
#import "EpisodeViewController.h"
#import "ICEpisodeUIConfig.h"
#import "InstacastAppDelegate.h"
#import "InstacastPlus-Swift.h"
#import "MainViewController_4.h"
#import "PortraitNavigationController.h"
#import "TranscriptionSettingsViewController.h"
#import "UpNextTableViewController.h"
#import "UIViewController+Alert.h"

@implementation ICEpisodeSwipeActionHandler

+ (UIImage*)_downloadImage
{
    NSString* imageName = ICEpisodeDownloadActionStartIconName();
    UIImage* image = ICEpisodeDownloadActionStartUsesAssetImage() ? [UIImage imageNamed:imageName] : [UIImage systemImageNamed:imageName];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (UIImage*)_playNextImageForEpisode:(CDEpisode*)episode configuration:(UIImageSymbolConfiguration*)configuration
{
    UIImage* baseImage = [UIImage systemImageNamed:ICEpisodePlayNextMenuSymbolName() withConfiguration:configuration];
    baseImage = [baseImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (![[AudioSession sharedAudioSession].playlist containsObject:episode]) {
        return baseImage;
    }

    CGFloat iconSide = MAX(baseImage.size.width, baseImage.size.height);
    CGFloat badgeSide = ceil(iconSide * 0.38f);
    CGRect canvasRect = CGRectMake(0, 0, baseImage.size.width, baseImage.size.height);
    CGRect badgeRect = CGRectMake(-badgeSide * 0.05f,
                                  baseImage.size.height - badgeSide * 0.78f,
                                  badgeSide,
                                  badgeSide);
    UIImageSymbolConfiguration* badgeConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:badgeSide weight:UIImageSymbolWeightSemibold];
    UIImage* badgeImage = [[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:badgeConfiguration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasRect.size];
    UIImage* rendered = [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext* context) {
        [ICMutedTextColor setFill];
        [baseImage drawInRect:canvasRect];
        [ICMutedTextColor setFill];
        [badgeImage drawInRect:badgeRect];
    }];
    return [rendered imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

+ (UIImage*)_imageForAction:(ICEpisodeSwipeAction)action episode:(CDEpisode*)episode
{
    UIImageSymbolConfiguration* configuration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    NSString* symbolName;
    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
            symbolName = episode.consumed ? @"circle.fill" : @"circle";
            break;
        case ICEpisodeSwipeActionToggleFavorite:
            symbolName = episode.starred ? @"star.slash" : @"star";
            break;
        case ICEpisodeSwipeActionDownload:
            return [self _downloadImage];
        case ICEpisodeSwipeActionAddToPlayNext:
            return [self _playNextImageForEpisode:episode configuration:configuration];
        case ICEpisodeSwipeActionDelete:
            symbolName = @"trash";
            break;
        case ICEpisodeSwipeActionEpisodeInfo:
            symbolName = @"info.circle";
            break;
        case ICEpisodeSwipeActionTranscribe:
            symbolName = @"captions.bubble";
            break;
        case ICEpisodeSwipeActionSendToAppleWatch:
            symbolName = [[AppleWatchSyncManager sharedManager] isEpisodeSelectedForWatch:episode] ? @"applewatch.slash" : @"applewatch";
            break;
        default:
            return nil;
    }
    UIImage* image = [UIImage systemImageNamed:symbolName withConfiguration:configuration];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

+ (NSString*)_accessibilityLabelForAction:(ICEpisodeSwipeAction)action episode:(CDEpisode*)episode
{
    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
            return episode.consumed ? @"Mark as Unplayed".ls : @"Mark as Played".ls;
        case ICEpisodeSwipeActionToggleFavorite:
            return episode.starred ? @"Unmark Favorite".ls : @"Mark as Favorite".ls;
        case ICEpisodeSwipeActionDownload:
        {
            CacheManager* cacheManager = [CacheManager sharedCacheManager];
            if ([cacheManager episodeIsCached:episode]) return @"Delete Download".ls;
            if ([cacheManager isCachingEpisode:episode]) return @"Cancel Download".ls;
            return @"Download".ls;
        }
        case ICEpisodeSwipeActionAddToPlayNext:
            return ([[AudioSession sharedAudioSession].playlist containsObject:episode] ? @"Remove from Play Next" : @"Add to Play Next").ls;
        case ICEpisodeSwipeActionDelete:
            return @"Delete Episode".ls;
        case ICEpisodeSwipeActionEpisodeInfo:
            return @"Episode Info".ls;
        case ICEpisodeSwipeActionTranscribe:
            return NSLocalizedString(@"Transkribieren", nil);
        case ICEpisodeSwipeActionSendToAppleWatch:
            return [[AppleWatchSyncManager sharedManager] isEpisodeSelectedForWatch:episode] ? @"Von Apple Watch entfernen".ls : @"An Apple Watch senden".ls;
        default:
            return nil;
    }
}

+ (UIColor*)_tintColorForAction:(ICEpisodeSwipeAction)action episode:(CDEpisode*)episode
{
    UIColor* grayColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
            return episode.consumed ? ICTintColor : grayColor;
        case ICEpisodeSwipeActionToggleFavorite:
            return episode.starred ? grayColor : ICTintColor;
        case ICEpisodeSwipeActionDownload:
        {
            CacheManager* cacheManager = [CacheManager sharedCacheManager];
            return ([cacheManager episodeIsCached:episode] || [cacheManager isCachingEpisode:episode]) ? grayColor : ICTintColor;
        }
        case ICEpisodeSwipeActionAddToPlayNext:
            return [[AudioSession sharedAudioSession].playlist containsObject:episode] ? grayColor : ICTintColor;
        case ICEpisodeSwipeActionDelete:
            return [UIColor systemRedColor];
        case ICEpisodeSwipeActionEpisodeInfo:
            return ICTintColor;
        case ICEpisodeSwipeActionTranscribe:
            return [[TranscriptionEngine shared] hasSRTFor:episode.objectHash] ? [UIColor systemRedColor] : ICTintColor;
        case ICEpisodeSwipeActionSendToAppleWatch:
        {
            AppleWatchSyncManager* watchManager = [AppleWatchSyncManager sharedManager];
            if (![watchManager canSendEpisodeToWatch:episode]) return grayColor;
            return [watchManager isEpisodeSelectedForWatch:episode] ? grayColor : ICTintColor;
        }
        default:
            return grayColor;
    }
}

+ (void)_showToastWithText:(NSString*)text
                buttonTitle:(NSString*)buttonTitle
                 buttonHidden:(BOOL)buttonHidden
                buttonAction:(void (^)(void))buttonAction
                    duration:(NSTimeInterval)duration
{
    UIWindow* window = App.ic_keyWindow;
    if (!window) return;

    UIVisualEffectView* blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurView.layer.cornerRadius = 12;
    blurView.clipsToBounds = YES;
    blurView.alpha = 0;

    UILabel* label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:ICFontSize(14)];

    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:buttonTitle forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(14)];
    [button setTitleColor:ICTintColor forState:UIControlStateNormal];
    button.hidden = buttonHidden;

    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, button]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [blurView.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor constant:-10],
    ]];

    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:blurView];
    [NSLayoutConstraint activateConstraints:@[
        [blurView.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-100],
    ]];

    [button addAction:[UIAction actionWithHandler:^(__unused UIAction* action) {
        [blurView removeFromSuperview];
        if (buttonAction) buttonAction();
    }] forControlEvents:UIControlEventTouchUpInside];

    [UIView animateWithDuration:0.3 animations:^{
        blurView.alpha = 1.0;
    } completion:^(__unused BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                blurView.alpha = 0;
            } completion:^(__unused BOOL finished) {
                [blurView removeFromSuperview];
            }];
        });
    }];
}

+ (void)_showPlayNextToastWithText:(NSString*)text
                              added:(BOOL)added
           presentingViewController:(UIViewController*)viewController
{
    __weak UIViewController* weakViewController = viewController;
    [self _showToastWithText:text
                 buttonTitle:@"Play Next".ls
                buttonHidden:!added
                buttonAction:^{
                    UIViewController* presenter = weakViewController;
                    if (!presenter) return;
                    UpNextTableViewController* controller = [UpNextTableViewController viewController];
                    PortraitNavigationController* navigationController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
                    navigationController.modalPresentationStyle = UIModalPresentationPageSheet;
                    [presenter presentViewController:navigationController animated:YES completion:nil];
                }
                    duration:ICEpisodePlayNextOverlayDisplayDuration()];
}

+ (void)_showTranscriptionToastWithText:(NSString*)text
{
    [self _showToastWithText:text
                 buttonTitle:@"Show".ls
                buttonHidden:NO
                buttonAction:^{
                    InstacastAppDelegate* appDelegate = (InstacastAppDelegate*)[UIApplication sharedApplication].delegate;
                    [appDelegate.mainViewController showTranscriptionQueue];
                }
                    duration:3.0];
}

+ (void)_requestCellularDownloadFromViewController:(UIViewController*)viewController
                                         completion:(void (^)(BOOL canDownload))completion
{
    if ([USER_DEFAULTS boolForKey:EnableCachingOver3G] || App.networkAccessTechnology == kICNetworkAccessTechnlogyWIFI) {
        completion(YES);
        return;
    }

    __weak UIViewController* weakViewController = viewController;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Downloading over cellular has been disabled in 'General' settings.".ls
                                                                   message:@"Do you still want to download the content of this episode right now?".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Download".ls style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
        UIViewController* presenter = weakViewController;
        completion(YES);
        presenter.alertController = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction* action) {
        UIViewController* presenter = weakViewController;
        completion(NO);
        presenter.alertController = nil;
    }]];
    alert.overrideUserInterfaceStyle = [ICAppearanceManager sharedManager].nightSettingMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    viewController.alertController = alert;
    if (![viewController presentAlertControllerAnimated:YES completion:nil]) {
        viewController.alertController = nil;
        completion(NO);
    }
}

+ (void)_showEpisodeInfo:(CDEpisode*)episode fromViewController:(UIViewController*)viewController
{
    viewController.navigationItem.backBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
    EpisodeViewController* controller = [EpisodeViewController episodeViewController];
    controller.episode = episode;
    controller.view.tintColor = ICTintColor;
    [viewController.navigationController pushViewController:controller animated:YES];
}

+ (BOOL)_transcribeEpisode:(CDEpisode*)episode fromViewController:(UIViewController*)viewController
{
    if (!ICAITranscriptionFeaturesAvailable() || ![USER_DEFAULTS boolForKey:kLocalTranscriptionEnabled]) return NO;
    if ([[TranscriptionEngine shared] hasSRTFor:episode.objectHash]) return NO;

    if (![ICDownloadableModelStore selectedVoiceModelIsReady]) {
        UIViewController* settingsController = [TranscriptionSettingsViewController modelLibraryViewControllerFocusedOnVoiceToText:YES];
        [viewController.navigationController pushViewController:settingsController animated:YES];
        return YES;
    }

    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    NSURL* audioURL = [cacheManager episodeIsCached:episode] ? [cacheManager URLForCachedEpisode:episode] : nil;
    BOOL enqueued = [[TranscriptionQueue shared] enqueueWithEpisodeHash:episode.objectHash
                                                          episodeTitle:episode.title ?: @""
                                                             feedTitle:episode.feed.title ?: @""
                                                              audioURL:audioURL
                                                              language:episode.feed.language];
    if (enqueued) {
        PlaySoundFile(@"AffirmIn", NO);
        [self _showTranscriptionToastWithText:NSLocalizedString(@"Transkription gestartet", nil)];
    } else {
        PlayHapticFeedback(ICHapticFeedbackLight);
    }
    return YES;
}

+ (BOOL)_serverTranscribeEpisode:(CDEpisode*)episode
{
    if (!ICAITranscriptionFeaturesAvailable() || ![USER_DEFAULTS boolForKey:kServerTranscriptionEnabled]) return NO;
    if ([[ServerTranscriptionManager shared] enqueueEpisode:episode]) {
        PlaySoundFile(@"AffirmIn", NO);
        [self _showTranscriptionToastWithText:NSLocalizedString(@"Transkription gestartet", nil)];
    } else {
        PlayHapticFeedback(ICHapticFeedbackLight);
        [self _showTranscriptionToastWithText:NSLocalizedString(@"Server-Transkription läuft bereits", nil)];
    }
    return YES;
}

+ (BOOL)_performAction:(ICEpisodeSwipeAction)action
              episode:(CDEpisode*)episode
presentingViewController:(UIViewController*)viewController
           didPerform:(void (^)(void))didPerform
{
    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
        {
            BOOL consumed = !episode.consumed;
            [DMANAGER markEpisode:episode asConsumed:consumed];
            if (consumed && [episode isEqual:[AudioSession sharedAudioSession].episode]) {
                [[AudioSession sharedAudioSession] stop];
            }
            PlaySoundFile(consumed ? @"AffirmOut" : @"AffirmIn", NO);
            if (didPerform) didPerform();
            return YES;
        }
        case ICEpisodeSwipeActionToggleFavorite:
        {
            BOOL starred = !episode.starred;
            [DMANAGER markEpisode:episode asStarred:starred];
            PlaySoundFile(starred ? @"AffirmIn" : @"AffirmOut", NO);
            if (didPerform) didPerform();
            return YES;
        }
        case ICEpisodeSwipeActionDownload:
        {
            CacheManager* cacheManager = [CacheManager sharedCacheManager];
            if ([cacheManager episodeIsCached:episode]) {
                [cacheManager removeCacheForEpisode:episode automatic:NO];
                PlaySoundFile(@"AffirmOut", NO);
                if (didPerform) didPerform();
            } else if ([cacheManager isCachingEpisode:episode]) {
                [cacheManager cancelCachingEpisode:episode disableAutoDownload:YES];
                PlaySoundFile(@"AffirmOut", NO);
                if (didPerform) didPerform();
            } else {
                PlaySoundFile(@"AffirmIn", NO);
                [self _requestCellularDownloadFromViewController:viewController completion:^(BOOL canDownload) {
                    if (canDownload) {
                        [[CacheManager sharedCacheManager] cacheEpisode:episode overwriteCellularLock:YES];
                    }
                    if (didPerform) didPerform();
                }];
            }
            return YES;
        }
        case ICEpisodeSwipeActionAddToPlayNext:
        {
            BOOL inUpNext = [[AudioSession sharedAudioSession].playlist containsObject:episode];
            if (inUpNext) {
                [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
            } else {
                [[AudioSession sharedAudioSession] appendToUpNext:@[episode]];
            }
            [self _showPlayNextToastWithText:(inUpNext ? @"Removed from Play Next".ls : @"Added to Play Next".ls)
                                      added:!inUpNext
                   presentingViewController:viewController];
            if (didPerform) didPerform();
            return YES;
        }
        case ICEpisodeSwipeActionDelete:
            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
            [DMANAGER setEpisode:episode archived:YES];
            PlaySoundFile(@"AffirmOut", NO);
            if (didPerform) didPerform();
            return YES;
        case ICEpisodeSwipeActionEpisodeInfo:
            [self _showEpisodeInfo:episode fromViewController:viewController];
            if (didPerform) didPerform();
            return YES;
        case ICEpisodeSwipeActionTranscribe:
        {
            BOOL performed = [[TranscriptionQueue resolvedAutomaticBackend] isEqualToString:@"server"]
                ? [self _serverTranscribeEpisode:episode]
                : [self _transcribeEpisode:episode fromViewController:viewController];
            if (performed && didPerform) didPerform();
            return performed;
        }
        case ICEpisodeSwipeActionSendToAppleWatch:
        {
            AppleWatchSyncManager* watchManager = [AppleWatchSyncManager sharedManager];
            if (![watchManager canSendEpisodeToWatch:episode]) return NO;
            if ([watchManager isEpisodeSelectedForWatch:episode]) {
                [watchManager removeEpisodeFromWatch:episode];
                PlaySoundFile(@"AffirmOut", NO);
            } else {
                [watchManager sendEpisodeToWatch:episode];
                PlaySoundFile(@"AffirmIn", NO);
            }
            if (didPerform) didPerform();
            return YES;
        }
        default:
            return NO;
    }
}

+ (UIContextualAction*)configuredRightSwipeActionForEpisode:(CDEpisode*)episode
                                    presentingViewController:(UIViewController*)viewController
                                                 willPerform:(void (^)(void))willPerform
                                                   didPerform:(void (^)(void))didPerform
{
    if (!episode || !viewController) return nil;
    ICEpisodeSwipeAction actionValue = [USER_DEFAULTS integerForKey:EpisodeSwipeRightAction];
    if (actionValue == ICEpisodeSwipeActionTranscribe && !ICAITranscriptionFeaturesEnabled()) return nil;

    UIContextualActionStyle style = actionValue == ICEpisodeSwipeActionDelete ? UIContextualActionStyleDestructive : UIContextualActionStyleNormal;
    __weak UIViewController* weakViewController = viewController;
    UIContextualAction* action = [UIContextualAction contextualActionWithStyle:style
                                                                         title:nil
                                                                       handler:^(__unused UIContextualAction* contextualAction,
                                                                                 __unused UIView* sourceView,
                                                                                 void (^completionHandler)(BOOL)) {
        UIViewController* presenter = weakViewController;
        if (!presenter) {
            completionHandler(NO);
            return;
        }
        if (willPerform) willPerform();
        BOOL performed = [self _performAction:actionValue
                                      episode:episode
                     presentingViewController:presenter
                                   didPerform:didPerform];
        if (!performed && didPerform) didPerform();
        completionHandler(performed);
    }];
    UIImage* image = [self _imageForAction:actionValue episode:episode];
    image.accessibilityLabel = [self _accessibilityLabelForAction:actionValue episode:episode];
    action.image = image;
    action.backgroundColor = [self _tintColorForAction:actionValue episode:episode];
    return action;
}

@end
