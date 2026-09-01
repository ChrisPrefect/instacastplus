//
//  UpNextTableViewController.m
//  Instacast
//
//  Created by Martin Hering on 31.10.14.
//
//

#import "UpNextTableViewController.h"
#import "EpisodesTableViewCell.h"
#import "PlaybackManager.h"
#import "ImageCacheManager.h"
#import "EpisodePlayComboButton.h"
#import "PlaybackViewController.h"
#import "CacheManager.h"
#import "EpisodeViewController.h"
#import "ICEpisodeUIConfig.h"
#import "ICEpisodeSwipeActionHandler.h"

static NSString* kUpNextCell = @"UpNextCell";

@interface UpNextTableViewController () <UITableViewDragDelegate, UITableViewDropDelegate>
@property (nonatomic, strong) UILabel* emptyStateLabel;
@property (nonatomic) BOOL observing;
// While a swipe action is open UIKit owns the cell layout — reloads and passes over
// the visible cells are collected and applied after the swipe closes.
@property (nonatomic) BOOL swipeInteractionActive;
@property (nonatomic) BOOL pendingReloadAfterSwipe;
@end

@implementation UpNextTableViewController {
    BOOL _needsPlayComboButtonUpdate;
    BOOL _didRestoreScrollPosition;
}

+ (instancetype) viewController {
    return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (BOOL) _showsModalCloseButton
{
    if (self.presentedAsMainView) {
        return NO;
    }

    UINavigationController* navigationController = self.navigationController;
    if (navigationController) {
        return navigationController.presentingViewController != nil && navigationController.viewControllers.firstObject == self;
    }

    return self.presentingViewController != nil;
}

- (void) _updateLeftBarButtonItem
{
    if (self.presentedAsMainView) {
        return;
    }

    if ([self _showsModalCloseButton]) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Player Close"] style:UIBarButtonItemStylePlain target:self action:@selector(playerCloseButtonAction:)];
    } else {
        self.navigationItem.leftBarButtonItem = nil;
    }
}

- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
    [self _setObserving:NO];
}

- (void) _setObserving:(BOOL)observing
{
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];

    if (observing && !_observing)
    {
        // Observe download progress changes
        [[CacheManager sharedCacheManager] addTaskObserver:self forKeyPath:@"cachingEpisodes" task:^(id obj, NSDictionary *change) {
            [self _setNeedsPlayComboButtonUpdate];
        }];

        [nc addObserver:self selector:@selector(cacheManagerDidUpdateNotification:) name:CacheManagerDidUpdateNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidClearCacheNotification:) name:CacheManagerDidClearCacheNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidFinishCachingEpisodeNotification:) name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidFinishCachingEpisodeNotification:) name:CacheManagerDidFailCachingEpisodeNotification object:nil];
        [nc addObserver:self selector:@selector(playbackManagerDidUpdateNotification:) name:PlaybackManagerDidUpdateNotification object:nil];
        [nc addObserver:self selector:@selector(playbackManagerDidChangeEpisodeNotification:) name:PlaybackManagerDidChangeEpisodeNotification object:nil];

        _observing = YES;
    }
    else if (!observing && _observing)
    {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_performPlayComboButtonUpdate) object:nil];
        [[CacheManager sharedCacheManager] removeTaskObserver:self forKeyPath:@"cachingEpisodes"];
        [nc removeObserver:self name:CacheManagerDidUpdateNotification object:nil];
        [nc removeObserver:self name:CacheManagerDidClearCacheNotification object:nil];
        [nc removeObserver:self name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
        [nc removeObserver:self name:CacheManagerDidFailCachingEpisodeNotification object:nil];
        [nc removeObserver:self name:PlaybackManagerDidUpdateNotification object:nil];
        [nc removeObserver:self name:PlaybackManagerDidChangeEpisodeNotification object:nil];

        _observing = NO;
    }
}

- (void) _setNeedsPlayComboButtonUpdate
{
    if (!_needsPlayComboButtonUpdate) {
        _needsPlayComboButtonUpdate = YES;
        [self performSelector:@selector(_performPlayComboButtonUpdate) withObject:nil afterDelay:0];
    }
}

- (void) _performPlayComboButtonUpdate
{
    if (self.swipeInteractionActive) {
        return;
    }
    _needsPlayComboButtonUpdate = NO;
    [[self.tableView visibleCells] makeObjectsPerformSelector:@selector(updatePlayComboButtonState)];
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    self.swipeInteractionActive = YES;
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self _endSwipeInteractionAndFlushDeferredUpdate];
}

- (void) _endSwipeInteractionAndFlushDeferredUpdate
{
    if (!self.swipeInteractionActive) {
        return;
    }
    self.swipeInteractionActive = NO;
    if (self.pendingReloadAfterSwipe) {
        self.pendingReloadAfterSwipe = NO;
        [self.tableView reloadData];
    }
    else if (_needsPlayComboButtonUpdate) {
        [self _performPlayComboButtonUpdate];
    }
}

- (void) cacheManagerDidUpdateNotification:(NSNotification*)notification
{
    [self _setNeedsPlayComboButtonUpdate];
}

- (void) cacheManagerDidClearCacheNotification:(NSNotification*)notification
{
    [self _setNeedsPlayComboButtonUpdate];
}

- (void) cacheManagerDidFinishCachingEpisodeNotification:(NSNotification*)notification
{
    // Called on main queue after episode is fully added to cachedEpisodes
    [self _setNeedsPlayComboButtonUpdate];
}

- (void) playbackManagerDidUpdateNotification:(NSNotification*)notification
{
    [self _setNeedsPlayComboButtonUpdate];
}

- (void) playbackManagerDidChangeEpisodeNotification:(NSNotification*)notification
{
    // Reload to update the highlighting of currently playing episode
    if (self.swipeInteractionActive) {
        self.pendingReloadAfterSwipe = YES;
        return;
    }
    [self.tableView reloadData];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsMake(20, 0, 0, 0) byAdjustingForStandardBars:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

    self.title = @"Play Next".ls;

    self.tableView.separatorInset = UIEdgeInsetsZero;
    [self.tableView registerClass:[EpisodesTableViewCell class] forCellReuseIdentifier:kUpNextCell];

    // Enable drag and drop for reordering
    self.tableView.dragInteractionEnabled = YES;
    self.tableView.dragDelegate = self;
    self.tableView.dropDelegate = self;

    [self _updateLeftBarButtonItem];

    // Download all and Remove all buttons as icons
    UIBarButtonItem* downloadAllButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
                                                                          style:UIBarButtonItemStylePlain
                                                                         target:self
                                                                         action:@selector(downloadAllButtonAction:)];

    UIBarButtonItem* removeAllButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"]
                                                                        style:UIBarButtonItemStylePlain
                                                                       target:self
                                                                       action:@selector(removeAllButtonAction:)];

    self.navigationItem.rightBarButtonItems = @[removeAllButton, downloadAllButton];

    // Setup empty state label
    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.text = @"To add episodes, long-press on any episode and select 'Add to Play Next'".ls;
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.numberOfLines = 0;
    self.emptyStateLabel.textColor = ICMutedTextColor;
    self.emptyStateLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    self.emptyStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
}

- (void) playerCloseButtonAction:(id)sender
{
    UINavigationController* navigationController = self.navigationController;
    if (navigationController && navigationController.viewControllers.count > 1 && navigationController.topViewController == self) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    if (navigationController && navigationController.presentingViewController != nil && self.navigationController.viewControllers.firstObject == self) {
        [navigationController dismissViewControllerAnimated:YES completion:NULL];
        return;
    }

    [self dismissViewControllerAnimated:YES completion:NULL];
}

- (void) removeAllButtonAction:(id)sender
{
    NSInteger count = [[AudioSession sharedAudioSession].playlist count];
    if (count == 0) {
        return;
    }

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Remove All".ls
                                                                   message:@"Remove all episodes from the play next list?".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Remove All".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        [[AudioSession sharedAudioSession] eraseAllEpisodesFromUpNext];
        [self.tableView reloadData];
        [self _updateEmptyState];
        [self _updateToolbarItems];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void) downloadAllButtonAction:(id)sender
{
    NSArray* episodes = [AudioSession sharedAudioSession].playlist;
    if ([episodes count] == 0) {
        return;
    }

    for (CDEpisode* episode in episodes) {
        if (![[CacheManager sharedCacheManager] episodeIsCached:episode] &&
            ![[CacheManager sharedCacheManager] isCachingEpisode:episode]) {
            [[CacheManager sharedCacheManager] cacheEpisode:episode overwriteCellularLock:NO];
        }
    }
}

- (void) playAction:(id)sender
{
    AudioSession* session = [AudioSession sharedAudioSession];
    if ([session.playlist count] > 0) {
        CDEpisode* firstEpisode = session.playlist.firstObject;
        // Open the player directly with the first episode
        PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithUserInitiatedEpisode:firstEpisode forceReload:YES];
        [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
    }
}

- (void) playComboButtonAction:(EpisodePlayComboButton*)button
{
    CDEpisode* episode = (CDEpisode*)button.userInfo;

    if (button.comboState == kEpisodePlayButtonComboStateFilling || button.comboState == kEpisodePlayButtonComboStateHolding)
    {
        // Cancel download
        CacheManager* cman = [CacheManager sharedCacheManager];
        [cman cancelCachingEpisode:episode disableAutoDownload:YES];
    }
    else
    {
        // Play the episode - use its saved position
        PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithUserInitiatedEpisode:episode forceReload:YES];
        [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
    }
}

- (void) _updateToolbarItems
{
    if (!self.presentedAsMainView) {
        return;
    }

    NSInteger count = [[AudioSession sharedAudioSession].playlist count];

    UIBarButtonItem* playButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"play.fill"]
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(playAction:)];
    playButton.enabled = (count > 0);

    UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

    NSString* countText = (count == 1) ? [NSString stringWithFormat:@"1 %@", @"Episode".ls] : [NSString stringWithFormat:@"%ld %@", (long)count, @"Episodes".ls];
    UIBarButtonItem* countItem = [[UIBarButtonItem alloc] initWithTitle:countText style:UIBarButtonItemStylePlain target:nil action:nil];
    countItem.enabled = NO;

    [self setToolbarItems:@[playButton, flexSpace, countItem] animated:NO];
}

- (void) _updateEmptyState
{
    NSInteger count = [[AudioSession sharedAudioSession].playlist count];

    if (count == 0) {
        if (self.emptyStateLabel.superview == nil) {
            [self.tableView addSubview:self.emptyStateLabel];
            [NSLayoutConstraint activateConstraints:@[
                [self.emptyStateLabel.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
                [self.emptyStateLabel.topAnchor constraintEqualToAnchor:self.tableView.topAnchor constant:80],
                [self.emptyStateLabel.leadingAnchor constraintEqualToAnchor:self.tableView.leadingAnchor constant:40],
                [self.emptyStateLabel.trailingAnchor constraintEqualToAnchor:self.tableView.trailingAnchor constant:-40]
            ]];
        }
        self.emptyStateLabel.hidden = NO;
    } else {
        self.emptyStateLabel.hidden = YES;
    }
}

- (void) updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.emptyStateLabel.textColor = ICMutedTextColor;
    if (self.swipeInteractionActive) {
        self.pendingReloadAfterSwipe = YES;
        return;
    }
    [self.tableView reloadData];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self _updateLeftBarButtonItem];
    _didRestoreScrollPosition = NO;

    [self _setObserving:YES];

    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.emptyStateLabel.textColor = ICMutedTextColor;

    [self.tableView reloadData];
    [self _updateEmptyState];
    [self _updateToolbarItems];
}

- (void) viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
    [self _storeScrollPosition];
    [self _setObserving:NO];
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    // insert rows
    if ([self.episodesToInsert count] > 0)
    {
        AudioSession* audioSession = [AudioSession sharedAudioSession];
        // remove currently playing
        NSMutableArray* mutableEpisodes = [self.episodesToInsert mutableCopy];
        [mutableEpisodes removeObject:audioSession.episode];

        [[AudioSession sharedAudioSession] prependToUpNext:mutableEpisodes];

        NSMutableArray* rows = [[NSMutableArray alloc] init];
        NSInteger i;
        for(i=0; i<[mutableEpisodes count]; i++) {
            [rows addObject:[NSIndexPath indexPathForRow:i inSection:0]];
        }

        [self.tableView beginUpdates];
        [self.tableView insertRowsAtIndexPaths:rows withRowAnimation:UITableViewRowAnimationFade];
        [self.tableView endUpdates];

        self.episodesToInsert = nil;

        [self _updateEmptyState];
        [self _updateToolbarItems];
    }

    [self _restoreScrollPositionIfNeeded];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (NSString*) _scrollPersistenceKey
{
    return @"upnext";
}

- (void) _restoreScrollPositionIfNeeded
{
    if (_didRestoreScrollPosition) {
        return;
    }
    _didRestoreScrollPosition = YES;
    ICRestoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView);
}

- (void) _storeScrollPosition
{
    ICStoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView);
}

- (void) _removeEpisodeAtIndexPath:(NSIndexPath*)indexPath
{
    if (indexPath.section != 0 || indexPath.row >= [[AudioSession sharedAudioSession].playlist count]) {
        return;
    }

    CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
    [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];

    [self.tableView beginUpdates];
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationRight];
    [self.tableView endUpdates];

    [self _updateEmptyState];
    [self _updateToolbarItems];
}

- (NSIndexPath*) _indexPathForEpisode:(CDEpisode*)episode
{
    if (!episode) {
        return nil;
    }

    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    NSString* objectHash = episode.objectHash;
    for(NSUInteger row = 0; row < [playlist count]; row++) {
        CDEpisode* currentEpisode = (CDEpisode*)playlist[row];
        if (currentEpisode == episode || [currentEpisode isEqual:episode]) {
            return [NSIndexPath indexPathForRow:row inSection:0];
        }

        if (objectHash && currentEpisode.objectHash && [currentEpisode.objectHash isEqualToString:objectHash]) {
            return [NSIndexPath indexPathForRow:row inSection:0];
        }
    }

    return nil;
}

- (UIContextualAction*) _removeSwipeActionAtIndexPath:(NSIndexPath*)indexPath
{
    if (indexPath.section != 0 || indexPath.row >= [[AudioSession sharedAudioSession].playlist count]) {
        return nil;
    }

    CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
    __weak UpNextTableViewController* weakSelf = self;
    UIContextualAction* action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:nil handler:^(__unused UIContextualAction* action, __unused UIView* sourceView, void (^completionHandler)(BOOL)) {
        UpNextTableViewController* strongSelf = weakSelf;
        if (!strongSelf) {
            completionHandler(NO);
            return;
        }
        // Performing the action does not reliably deliver didEndEditingRowAtIndexPath:
        // before the action's own updates run, so the gate is released here explicitly.
        [strongSelf _endSwipeInteractionAndFlushDeferredUpdate];

        NSIndexPath* currentIndexPath = [strongSelf _indexPathForEpisode:episode];
        if (!currentIndexPath) {
            completionHandler(NO);
            return;
        }

        [strongSelf _removeEpisodeAtIndexPath:currentIndexPath];
        completionHandler(YES);
    }];
    UIImageSymbolConfiguration* configuration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    UIImage* image = [[UIImage systemImageNamed:ICEpisodePlayNextMenuSymbolName() withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    image.accessibilityLabel = @"Remove from Play Next".ls;
    action.image = image;
    action.backgroundColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
    return action;
}

- (UISwipeActionsConfiguration*)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    if (indexPath.section != 0 || indexPath.row >= playlist.count) {
        return nil;
    }

    CDEpisode* episode = playlist[indexPath.row];
    __weak UpNextTableViewController* weakSelf = self;
    __block NSIndexPath* committedIndexPath;
    UIContextualAction* action = [ICEpisodeSwipeActionHandler configuredRightSwipeActionForEpisode:episode
                                                                         presentingViewController:self
                                                                                      willPerform:^{
        UpNextTableViewController* strongSelf = weakSelf;
        if (!strongSelf) return;
        committedIndexPath = [strongSelf _indexPathForEpisode:episode];
        [strongSelf _endSwipeInteractionAndFlushDeferredUpdate];
    } didPerform:^{
        UpNextTableViewController* strongSelf = weakSelf;
        if (!strongSelf) return;
        NSIndexPath* currentIndexPath = [strongSelf _indexPathForEpisode:episode];
        if (currentIndexPath) {
            [strongSelf.tableView reloadRowsAtIndexPaths:@[currentIndexPath] withRowAnimation:UITableViewRowAnimationNone];
        } else if (committedIndexPath) {
            [strongSelf.tableView deleteRowsAtIndexPaths:@[committedIndexPath] withRowAnimation:UITableViewRowAnimationRight];
        }
        [strongSelf _updateEmptyState];
        [strongSelf _updateToolbarItems];
    }];
    if (!action) {
        return nil;
    }

    UISwipeActionsConfiguration* configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (UISwipeActionsConfiguration*)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UIContextualAction* action = [self _removeSwipeActionAtIndexPath:indexPath];
    if (!action) {
        return nil;
    }

    UISwipeActionsConfiguration* configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [[AudioSession sharedAudioSession].playlist count];
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kUpNextCell forIndexPath:indexPath];

    CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];

    // Highlight currently playing episode
    BOOL isPlaying = [episode isEqual:[AudioSession sharedAudioSession].episode];
    cell.backgroundColor = isPlaying ? ICTableSelectedBackgroundColor : self.tableView.backgroundColor;
    cell.embedded = NO;
    cell.usesNativeSwipeActions = YES;
    cell.objectValue = episode;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    // Wire up play button
    [cell.playAccessoryButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.playAccessoryButton addTarget:self action:@selector(playComboButtonAction:) forControlEvents:UIControlEventTouchUpInside];
    cell.playAccessoryButton.userInfo = episode;

    // Set podcast image - exactly like EpisodesTableViewController
    cell.iconView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];
    NSURL* imageURL = (episode.imageURL) ? episode.imageURL : episode.feed.imageURL;

    ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
    __weak EpisodesTableViewCell* weakCell = cell;
    [iman imageForURL:imageURL size:56 grayscale:NO sender:cell completion:^(UIImage *image) {
        EpisodesTableViewCell* strongCell = weakCell;
        if (!strongCell || !image) {
            return;
        }

        if (strongCell.objectValue != episode) {
            return;
        }

        strongCell.iconView.image = image;
    }];

    return cell;
}



- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return 72.f;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
    return [EpisodesTableViewCell proposedHeightWithObjectValue:episode tableSize:self.tableView.bounds.size imageSize:CGSizeMake(56, 56) embedded:NO editing:NO];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

// Same long-press semantics as every other episode list: favorite, played, episode info
// and the list-specific remove action, with the shared titles/icons (see CLAUDE.md
// Icon-Referenz). User-Entscheid 08.07.: all episode lists behave consistently.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    if (indexPath.row >= (NSInteger)[playlist count]) {
        return nil;
    }
    CDEpisode* episode = playlist[indexPath.row];

    __weak UpNextTableViewController* weakSelf = self;
    UIContextMenuConfiguration* config =
        [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                previewProvider:nil
                                                 actionProvider:^UIMenu*(NSArray<UIMenuElement*>* suggestedActions) {
            NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];

            UIAction* favoriteAction = [UIAction actionWithTitle:(episode.starred) ? @"Unmark Favorite".ls : @"Mark as Favorite".ls
                                                           image:[UIImage systemImageNamed:episode.starred ? @"star.slash" : @"star"]
                                                      identifier:nil
                                                         handler:^(UIAction *action) {
                [DMANAGER markEpisode:episode asStarred:!episode.starred];
            }];
            [actions addObject:favoriteAction];

            UIAction* playedAction = [UIAction actionWithTitle:episode.consumed ? @"Mark as Unplayed".ls : @"Mark as Played".ls
                                                         image:[UIImage systemImageNamed:episode.consumed ? @"circle.fill" : @"circle"]
                                                    identifier:nil
                                                       handler:^(UIAction *action) {
                BOOL flag = !episode.consumed;
                [DMANAGER markEpisode:episode asConsumed:flag];
                if (flag && [episode isEqual:[AudioSession sharedAudioSession].episode]) {
                    [[AudioSession sharedAudioSession] stop];
                }
            }];
            [actions addObject:playedAction];

            UIAction* infoAction = [UIAction actionWithTitle:@"Episode Info".ls
                                                       image:[UIImage systemImageNamed:@"info.circle"]
                                                  identifier:nil
                                                     handler:^(UIAction *action) {
                [weakSelf _pushShowNotesOfEpisode:episode];
            }];
            [actions addObject:infoAction];

            UIAction* removeAction = [UIAction actionWithTitle:@"Remove from Play Next".ls
                                                         image:[UIImage systemImageNamed:@"list.bullet.indent"]
                                                    identifier:nil
                                                       handler:^(UIAction *action) {
                UpNextTableViewController* strongSelf = weakSelf;
                if (!strongSelf) return;
                NSIndexPath* currentIndexPath = [strongSelf _indexPathForEpisode:episode];
                if (currentIndexPath) {
                    [strongSelf _removeEpisodeAtIndexPath:currentIndexPath];
                }
            }];
            [actions addObject:removeAction];

            return [UIMenu menuWithTitle:@"" children:actions];
        }];
    if (@available(iOS 16.0, *)) {
        config.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
    }
    return config;
}

// Same tap semantics as every other episode list (EpisodesTableViewController): honor the
// user's TapOnEpisodeAction setting. TestFlight feedback 13.06.: tapping a row in the
// play-next list did nothing at all.
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    if (indexPath.row >= (NSInteger)[playlist count]) {
        return;
    }
    CDEpisode* episode = playlist[indexPath.row];

    NSInteger tapAction = [USER_DEFAULTS integerForKey:TapOnEpisodeAction];
    if (tapAction == ICTapOnEpisodeActionShowNotes) {
        [self _pushShowNotesOfEpisode:episode];
    } else if (tapAction == ICTapOnEpisodeActionOpenContextMenu) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else {
        BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
        PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithUserInitiatedEpisode:episode forceReload:!alreadyPlaying];
        [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
    }
}

- (void) _pushShowNotesOfEpisode:(CDEpisode*)episode
{
    UIBarButtonItem* backItem = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.navigationItem.backBarButtonItem = backItem;

    EpisodeViewController* controller = [EpisodeViewController episodeViewController];
    controller.episode = episode;
    controller.view.tintColor = ICTintColor;
    [self.navigationController pushViewController:controller animated:YES];
}

#pragma mark - UITableViewDragDelegate

- (NSArray<UIDragItem *> *)tableView:(UITableView *)tableView itemsForBeginningDragSession:(id<UIDragSession>)session atIndexPath:(NSIndexPath *)indexPath
{
    CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
    NSItemProvider* itemProvider = [[NSItemProvider alloc] initWithObject:episode.uid];
    UIDragItem* dragItem = [[UIDragItem alloc] initWithItemProvider:itemProvider];
    dragItem.localObject = episode;
    return @[dragItem];
}

- (UIDragPreviewParameters *)tableView:(UITableView *)tableView dragPreviewParametersForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UIDragPreviewParameters* params = [[UIDragPreviewParameters alloc] init];
    params.backgroundColor = [UIColor clearColor];
    return params;
}

#pragma mark - UITableViewDropDelegate

- (UITableViewDropProposal *)tableView:(UITableView *)tableView dropSessionDidUpdate:(id<UIDropSession>)session withDestinationIndexPath:(NSIndexPath *)destinationIndexPath
{
    if (session.localDragSession != nil) {
        return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationMove intent:UITableViewDropIntentInsertAtDestinationIndexPath];
    }
    return [[UITableViewDropProposal alloc] initWithDropOperation:UIDropOperationCancel];
}

- (void)tableView:(UITableView *)tableView performDropWithCoordinator:(id<UITableViewDropCoordinator>)coordinator
{
    NSIndexPath* destinationIndexPath = coordinator.destinationIndexPath;
    if (!destinationIndexPath) {
        destinationIndexPath = [NSIndexPath indexPathForRow:[[AudioSession sharedAudioSession].playlist count] inSection:0];
    }

    for (id<UITableViewDropItem> item in coordinator.items) {
        NSIndexPath* sourceIndexPath = item.sourceIndexPath;
        if (sourceIndexPath) {
            [self.tableView performBatchUpdates:^{
                [[AudioSession sharedAudioSession] reorderUpNextEpisodeFromIndex:sourceIndexPath.row toIndex:destinationIndexPath.row];
                [self.tableView moveRowAtIndexPath:sourceIndexPath toIndexPath:destinationIndexPath];
            } completion:nil];

            [coordinator dropItem:item.dragItem toRowAtIndexPath:destinationIndexPath];
        }
    }
    [self _storeScrollPosition];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
    if (!decelerate) {
        ICScheduleStoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView, 0.5);
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    ICScheduleStoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView, 0.5);
}

@end
