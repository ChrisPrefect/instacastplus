//
//  EpisodesTableViewController.m
//  Instacast
//
//  Created by Martin Hering on 25.05.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>

#import "EpisodesTableViewController.h"
#import "EpisodesTableViewCell.h"

#import "InstacastAppDelegate.h"
#import "MainViewController_4.h"
#import "UIManager.h"

#import "VDModalInfo.h"
#import "CDModel.h"
#import "CDEpisode+ShowNotes.h"

#import "EpisodeViewController.h"
#import "PlaybackViewController.h"
#import "EpisodePlayComboButton.h"

#import "AlertStylePopoverController.h"
#import "NumberAccessoryView.h"

#import "ToolbarLabelsViewController.h"
#import "PlaybackDefines.h"
#import "AudioSession+UpNextPlaylist.h"
#import "ICSidebarPanGestureRecognizer.h"
#import "UpNextTableViewController.h"
#import "PortraitNavigationController.h"
#import "InstacastAppDelegate.h"
#import "TranscriptionSettingsViewController.h"
#import "ICEpisodeUIConfig.h"
#import "InstacastPlus-Swift.h"
#import "AppleWatchSyncManager.h"

NSString* kDefaultEpisodesSelectedEpisodeUID = @"DefaultEpisodesSelectedEpisodeUID";
static const NSUInteger kBulkEpisodeMutationBatchSize = 50;

@interface EpisodesTableViewController ()
@property (nonatomic, strong) NSDateFormatter* dateFormatter;
@property (nonatomic, strong) NSDateFormatter* weekdayDateFormatter;
@property (nonatomic, strong, readwrite) ToolbarLabelsViewController* toolbarLabelsViewController;
@property (nonatomic, strong, readwrite) UIBarButtonItem* labelsItems;
@property (nonatomic, weak) UITapGestureRecognizer* cancelDeleteButtonTapRecognizer;

// Toolbar items - created once and reused
@property (nonatomic, strong) UIBarButtonItem* cacheItem;
@property (nonatomic, strong) UIBarButtonItem* consumeAllItem;
@property (nonatomic, strong) UIBarButtonItem* editItem;
@property (nonatomic, strong) UIBarButtonItem* playItem;
@property (nonatomic, strong) UIBarButtonItem* downloadItem;
@property (nonatomic, strong) UIBarButtonItem* selectAllItem;
@property (nonatomic, strong) UIBarButtonItem* cancelItem;
@property (nonatomic, strong) NumberAccessoryView* numView;

// iOS 26: Floating glass buttons on navigationController.view replace system toolbar.
// Normal mode: consumeAll (left) + edit (right) — glass buttons like FeedVC/WebController.
// Editing mode: custom UIToolbar with glass pill — proper animations, layout, and touch handling.
@property (nonatomic, strong) UIButton* floatingConsumeAllButton API_AVAILABLE(ios(26.0));
@property (nonatomic, strong) UIButton* floatingEditButton API_AVAILABLE(ios(26.0));
@property (nonatomic, strong) UIToolbar* editingToolbar API_AVAILABLE(ios(26.0));

- (void)_finishBulkEpisodeMutationWithCacheEpisodes:(NSMutableOrderedSet<CDEpisode*>*)cacheEpisodes
                                           automatic:(BOOL)automatic
                                           saveError:(NSError*)saveError
                                           modalInfo:(VDModalInfo*)modalInfo
                                         reloadTable:(BOOL)reloadTable;
- (void)_finishClearPlayedCacheWithEpisodes:(NSMutableOrderedSet<CDEpisode*>*)episodesToClear
                                  modalInfo:(VDModalInfo*)modalInfo;

@end

@implementation EpisodesTableViewController {
@private
    BOOL _defaultsPushed;
    BOOL _observing;
    BOOL _needsPlayComboButtonUpdate;
}

- (void)dealloc
{
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
    [self _setObserving:NO];
}

- (void) _setObserving:(BOOL)observing
{
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];

    if (observing && !_observing)
    {
        __weak EpisodesTableViewController* weakSelf = self;

        [[CacheManager sharedCacheManager] addTaskObserver:self forKeyPath:@"cachingEpisodes" task:^(id obj, NSDictionary *change) {
            [self _setNeedsPlayComboButtonUpdate];
        }];
        [[AudioSession sharedAudioSession] addTaskObserver:self forKeyPath:@"playlist" task:^(__unused id obj, __unused NSDictionary *change) {
            [weakSelf _updateVisiblePlaylistIndicators];
        }];

        [nc addObserver:self selector:@selector(cacheManagerDidUpdateNotification:) name:CacheManagerDidUpdateNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidClearCacheNotification:) name:CacheManagerDidClearCacheNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidFinishCachingEpisodeNotification:) name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
        [nc addObserver:self selector:@selector(cacheManagerDidFinishCachingEpisodeNotification:) name:CacheManagerDidFailCachingEpisodeNotification object:nil];
        [nc addObserver:self
                                                 selector:@selector(updateAppearance)
                                                     name:ICAppearanceManagerDidUpdateAppearanceNotification
                                                   object:nil];
        [nc addObserver:self
                                                 selector:@selector(_playbackEpisodeDidChange:)
                                                     name:PlaybackManagerDidChangeEpisodeNotification
                                                   object:nil];
        [nc addObserver:self
                                                 selector:@selector(_playbackEpisodeDidChange:)
                                                     name:PlaybackManagerDidEndNotification
                                                   object:nil];
        [nc addObserver:self
               selector:@selector(_appleWatchEpisodeStatesDidChange:)
                   name:ICAppleWatchEpisodeStatesDidChangeNotification
                 object:nil];

        _observing = YES;
        [self _setNeedsPlayComboButtonUpdate];
    }
    else if (!observing && _observing)
    {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_performPlayComboButtonUpdate) object:nil];
        _needsPlayComboButtonUpdate = NO;
        [nc removeObserver:self];

        [[CacheManager sharedCacheManager] removeTaskObserver:self forKeyPath:@"cachingEpisodes"];
        [[AudioSession sharedAudioSession] removeTaskObserver:self forKeyPath:@"playlist"];

        _observing = NO;
    }
}

- (void) _playbackEpisodeDidChange:(NSNotification*)notification
{
    if (self.tableView.window) {
        [self.tableView reloadData];
    }
}

- (void) _appleWatchEpisodeStatesDidChange:(NSNotification*)notification
{
    (void)notification;
    if (self.tableView.window) {
        [self.tableView reloadData];
    }
}

- (void) _updateVisiblePlaylistIndicators
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateVisiblePlaylistIndicators];
        });
        return;
    }

    if (!self.tableView.window) {
        return;
    }

    for (UITableViewCell* visibleCell in self.tableView.visibleCells) {
        if ([visibleCell isKindOfClass:[EpisodesTableViewCell class]]) {
            [(EpisodesTableViewCell*)visibleCell updatePlaylistIndicatorState];
        }
    }
}

- (void) _setNeedsPlayComboButtonUpdate
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _setNeedsPlayComboButtonUpdate];
        });
        return;
    }

    if (!_needsPlayComboButtonUpdate) {
        _needsPlayComboButtonUpdate = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_needsPlayComboButtonUpdate) {
                [self _performPlayComboButtonUpdate];
            }
        });
    }
}

- (void) _performPlayComboButtonUpdate
{
    _needsPlayComboButtonUpdate = NO;
    [[self.tableView visibleCells] makeObjectsPerformSelector:@selector(updatePlayComboButtonState)];
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

- (BOOL) showsImage
{
    return YES;
}

- (BOOL) canArchiveEpisodes
{
    return YES;
}

- (BOOL) canPlayMultiple
{
    return YES;
}

- (void) addAdditionalButtonsToMultiActionSheet:(UIAlertController*)sheet completionBlock:(void (^)(void))completionBlock
{

}

- (void) addAdditionalButtonsToLongPressActionSheet:(UIAlertController*)sheet rowIndexPath:(NSIndexPath*)indexPath completionBlock:(void (^)(void))completionBlock
{

}

- (void) addAdditionalButtonsToMultiSelectEditActionSheet:(UIAlertController*)sheet selectedIndexPathes:(NSArray*)selectedIndexPathes completionBlock:(void (^)(void))completionBlock
{

}

- (id)initWithStyle:(UITableViewStyle)style {
    // Override initWithStyle: if you create the controller programmatically and want to perform customization that is not appropriate for viewDidLoad.
    self = [super initWithStyle:style];
    if (self) {
        // Custom initialization.
	}
    return self;
}


- (void) viewDidLoad
{
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeBottom;
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    // Update transcript indicators when queue changes
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_transcriptionQueueChanged)
                                                 name:@"ICTranscriptionQueueDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_transcriptionQueueChanged)
                                                 name:@"ICTranscriptionDidFinishNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_transcriptionQueueChanged)
                                                 name:@"ICTranscriptionDidChangeNotification" object:nil];

    self.tableView.separatorInset = UIEdgeInsetsMake(0, 0, 0, 0);

    // Extra scrollable space at the bottom equal to one episode row height so the user
    // can scroll the last episode up above the floating toolbar buttons.
    UIEdgeInsets inset = self.tableView.contentInset;
    inset.bottom += 72;
    self.tableView.contentInset = inset;
    UIEdgeInsets scrollIndicatorInset = self.tableView.verticalScrollIndicatorInsets;
    scrollIndicatorInset.bottom += 72;
    self.tableView.verticalScrollIndicatorInsets = scrollIndicatorInset;

    self.toolbarLabelsViewController = [ToolbarLabelsViewController toolbarLabelsViewController];

    self.labelsItems = [[UIBarButtonItem alloc] initWithCustomView:self.toolbarLabelsViewController.view];
    self.labelsItems.width = CGRectGetWidth(self.toolbarLabelsViewController.view.bounds);


    UITapGestureRecognizer* cancelDeleteButtonTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancelDelete:)];
    cancelDeleteButtonTapRecognizer.delegate = self;
    [self.tableView addGestureRecognizer:cancelDeleteButtonTapRecognizer];
    self.cancelDeleteButtonTapRecognizer = cancelDeleteButtonTapRecognizer;

    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = YES;
        [self _setupFloatingToolbarButtons];
    }
}

- (void) restoreShowNotes
{
    NSString* savedEpisodeUID = [USER_DEFAULTS objectForKey:kDefaultEpisodesSelectedEpisodeUID];
    
    if (!_defaultsPushed && savedEpisodeUID) {
        __block CDEpisode* selectedEpisode = nil;;
        [self.episodes enumerateObjectsUsingBlock:^(CDEpisode* episode, NSUInteger idx, BOOL *stop) {
            if ([episode.uid isEqualToString:savedEpisodeUID]) {
                selectedEpisode = episode;
                *stop = YES;
            }
        }];
        
        if (selectedEpisode) {
            [self _pushShowNotesOfEpisode:selectedEpisode animated:NO inAppearanceTransition:YES];
        }
    }
    else {
        [USER_DEFAULTS removeObjectForKey:kDefaultEpisodesSelectedEpisodeUID];
    }
    _defaultsPushed = YES;
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    // iOS 26: toolbarHidden stays YES. Show correct set of floating glass buttons.
    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = YES;
        [self _syncFloatingButtonVisibility];

        // iOS 26's "swipe back from anywhere" gesture (interactiveContentPopGestureRecognizer)
        // competes with the row swipe actions on the whole content area. Reproducible conflict
        // (bestätigt 09.07.): while one cell's swipe-back animation is still settling, a swipe on
        // another row is grabbed by the content-pop gesture and pops the WHOLE view back to the
        // subscriptions list instead of revealing the row action. Disable the content-area pop
        // on episode lists; the edge-swipe (interactivePopGestureRecognizer) and the back button
        // keep working for navigation.
        self.navigationController.interactiveContentPopGestureRecognizer.enabled = NO;
    }

    [self _setObserving:YES];
    [self updateAppearance];

    [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:animated];

    [self restoreShowNotes];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;

    // iOS 26: sync floating button appearance with app theme
    if (@available(iOS 26.0, *)) {
        UIUserInterfaceStyle style = [ICAppearanceManager sharedManager].nightSettingMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        self.floatingConsumeAllButton.overrideUserInterfaceStyle = style;
        self.floatingEditButton.overrideUserInterfaceStyle = style;
        self.editingToolbar.overrideUserInterfaceStyle = style;
    }

    [self.tableView reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}


- (void)viewWillDisappear:(BOOL)animated {
    // iOS 26: restore system toolbar for the next VC, hide all floating buttons
    if (@available(iOS 26.0, *)) {
        self.navigationController.toolbarHidden = NO;
        [self _hideAllFloatingButtons];
        // Re-enable the swipe-back-from-anywhere gesture for the next screen (which has no
        // row swipe actions to conflict with).
        self.navigationController.interactiveContentPopGestureRecognizer.enabled = YES;
    }
    [super viewWillDisappear:animated];

    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self _setObserving:NO];
}



- (void) updateEpisodes
{
    self.episodes = nil;
}

- (void) _updateToolbarLabels
{
    
}


// iOS 26: Creates floating glass buttons on navigationController.view.
// Exact same pattern as WebController/FeedViewController/SubscriptionsTableVC.
// Normal mode: consumeAll (left) + edit (right). Editing: editOptions + play + download + selectAll + done.
- (void) _setupFloatingToolbarButtons API_AVAILABLE(ios(26.0))
{
    UIView* container = self.navigationController.view;
    if (!container) return;

    WEAK_SELF
    UIUserInterfaceStyle style = [ICAppearanceManager sharedManager].nightSettingMode ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;

    // --- Normal mode: 2 floating glass buttons ---

    UIButtonConfiguration* consumeConfig = [UIButtonConfiguration glassButtonConfiguration];
    consumeConfig.image = [UIImage systemImageNamed:@"checkmark.circle"];
    consumeConfig.buttonSize = UIButtonConfigurationSizeLarge;
    self.floatingConsumeAllButton = [UIButton buttonWithConfiguration:consumeConfig primaryAction:nil];
    self.floatingConsumeAllButton.showsMenuAsPrimaryAction = YES;
    self.floatingConsumeAllButton.menu = [self _buildConsumeAllMenu];
    self.floatingConsumeAllButton.accessibilityLabel = @"Mark all".ls;

    UIButtonConfiguration* editConfig = [UIButtonConfiguration glassButtonConfiguration];
    editConfig.image = [UIImage systemImageNamed:@"pencil"];
    editConfig.buttonSize = UIButtonConfigurationSizeLarge;
    self.floatingEditButton = [UIButton buttonWithConfiguration:editConfig primaryAction:
        [UIAction actionWithHandler:^(__unused UIAction* action) {
            STRONG_SELF
            [self editForCachingAction:nil];
        }]];
    self.floatingEditButton.accessibilityLabel = @"Edit".ls;

    for (UIButton* btn in @[self.floatingConsumeAllButton, self.floatingEditButton]) {
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.overrideUserInterfaceStyle = style;
        btn.hidden = YES;
        [container addSubview:btn];
    }

    UILayoutGuide* safeArea = container.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.floatingConsumeAllButton.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:20],
        [self.floatingConsumeAllButton.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
        [self.floatingEditButton.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-20],
        [self.floatingEditButton.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
    ]];

    // --- Editing mode: custom UIToolbar with liquid glass ---
    // Standalone UIToolbar gets liquid glass automatically on iOS 26.
    // Unlike nav controller's toolbar, it doesn't create FloatingBarHostingView touch-blocking.

    self.editingToolbar = [[UIToolbar alloc] init];
    self.editingToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    self.editingToolbar.overrideUserInterfaceStyle = style;
    self.editingToolbar.hidden = YES;
    [container addSubview:self.editingToolbar];

    [NSLayoutConstraint activateConstraints:@[
        [self.editingToolbar.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [self.editingToolbar.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [self.editingToolbar.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor constant:-14],
    ]];

    // Don't call _updateEditingToolbarItems here — UIBarButtonItems are lazily created
    // in _updateToolbarItemsAnimated: and would be nil at this point.
    // Items will be set when first entering editing mode.

    // Show initial state (normal mode buttons)
    [self _syncFloatingButtonVisibility];
}

// Updates the editing toolbar items (enabled state, select all title).
// Reuses the existing UIBarButtonItem properties from the iOS ≤25 code path.
- (void) _updateEditingToolbarItems API_AVAILABLE(ios(26.0))
{
    NSInteger selectedCount = [[self.tableView indexPathsForSelectedRows] count];
    NSInteger rowCount = [self.tableView numberOfRowsInSection:0];
    BOOL hasSelection = (selectedCount > 0);

    self.selectAllItem.title = [self _selectionToggleTitleKeyForSelectedCount:selectedCount rowCount:rowCount].ls;
    self.editItem.enabled = hasSelection;
    self.playItem.enabled = hasSelection;
    self.downloadItem.enabled = hasSelection;

    // Set items only once (9 = 5 items + 4 flex spaces)
    if (self.editingToolbar.items.count != 9) {
        UIBarButtonItem* flex1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem* flex2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem* flex3 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        UIBarButtonItem* flex4 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        [self.editingToolbar setItems:@[self.editItem, flex1, self.playItem, flex2, self.downloadItem, flex3, self.selectAllItem, flex4, self.cancelItem] animated:YES];
    }
}

// Shows the correct set of floating buttons/toolbar for the current editing state.
- (void) _syncFloatingButtonVisibility API_AVAILABLE(ios(26.0))
{
    BOOL isEditing = (self.tableView.editing && self.editingStyle == EpisodesTableViewEditingStyleDownload);
    UIView* container = self.navigationController.view;

    // Normal mode: floating glass buttons
    self.floatingConsumeAllButton.hidden = isEditing;
    self.floatingEditButton.hidden = isEditing;
    if (!isEditing) {
        BOOL hasEpisodes = ([self.episodes count] > 0);
        self.floatingConsumeAllButton.enabled = hasEpisodes;
        self.floatingEditButton.enabled = hasEpisodes;
        self.floatingConsumeAllButton.menu = [self _buildConsumeAllMenu];
        [container bringSubviewToFront:self.floatingConsumeAllButton];
        [container bringSubviewToFront:self.floatingEditButton];
    }

    // Editing mode: custom UIToolbar
    self.editingToolbar.hidden = !isEditing;
    if (isEditing) {
        [self _updateEditingToolbarItems];
        [container bringSubviewToFront:self.editingToolbar];
    }
}

// Hides all floating buttons and editing toolbar (viewWillDisappear).
- (void) _hideAllFloatingButtons API_AVAILABLE(ios(26.0))
{
    self.floatingConsumeAllButton.hidden = YES;
    self.floatingEditButton.hidden = YES;
    self.editingToolbar.hidden = YES;
}

// Builds a UIMenu for the consumeAll floating button (bulk actions).
- (UIMenu*) _buildConsumeAllMenu API_AVAILABLE(ios(26.0))
{
    WEAK_SELF
    NSMutableArray<UIMenuElement*>* items = [NSMutableArray array];

    if ([self _numberOfNotPlayedDisplayEpisodes] > 0) {
        [items addObject:[UIAction actionWithTitle:@"Mark all as Played".ls
                                            image:[UIImage systemImageNamed:@"checkmark.circle"]
                                       identifier:nil
                                          handler:^(__unused UIAction* a) { STRONG_SELF [self _setAllAsConsumed:YES]; }]];
    }
    if ([self _numberOfDisplayEpisodes] - [self _numberOfNotPlayedDisplayEpisodes] > 0) {
        [items addObject:[UIAction actionWithTitle:@"Mark all as Unplayed".ls
                                            image:[UIImage systemImageNamed:@"circle"]
                                       identifier:nil
                                          handler:^(__unused UIAction* a) { STRONG_SELF [self _setAllAsConsumed:NO]; }]];
    }
    if ([self _numberOfPlayedDownloadedEpisodes] > 0) {
        UIAction* act = [UIAction actionWithTitle:@"Delete played content".ls
                                           image:[[UIImage systemImageNamed:@"square.and.arrow.down"] imageWithTintColor:[UIColor colorWithWhite:0.5f alpha:1.0f] renderingMode:UIImageRenderingModeAlwaysOriginal]
                                      identifier:nil
                                         handler:^(__unused UIAction* a) { STRONG_SELF [self _clearCacheOfAllPlayed]; }];
        [items addObject:act];
    }
    if ([self canArchiveEpisodes] && [self _numberOfPlayedDisplayEpisodes] > 0) {
        UIAction* act = [UIAction actionWithTitle:@"Delete all Played".ls
                                           image:[UIImage systemImageNamed:@"trash"]
                                      identifier:nil
                                         handler:^(__unused UIAction* a) { STRONG_SELF [self _archiveAllPlayed]; }];
        act.attributes = UIMenuElementAttributesDestructive;
        [items addObject:act];
    }

    return [UIMenu menuWithTitle:@"" children:items];
}

- (void) _updateToolbarItemsAnimated:(BOOL)animated
{
    // Lazy-create UIBarButtonItems (used by both iOS ≤25 system toolbar and iOS 26 editing toolbar)
    if (!self.cacheItem) {
        self.cacheItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Select"]
                                                          style:UIBarButtonItemStylePlain
                                                         target:self
                                                         action:@selector(editForCachingAction:)];
        self.cacheItem.accessibilityLabel = @"Edit".ls;
    }
    if (!self.consumeAllItem) {
        self.consumeAllItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Complete"]
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(consumeAllAction:)];
        self.consumeAllItem.accessibilityLabel = @"Mark all".ls;
    }
    if (!self.editItem) {
        self.editItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Multitoolbar Edit"]
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(showEditingOptionsForSelection:)];
        self.editItem.accessibilityLabel = @"Edit".ls;
    }
    if (!self.playItem) {
        self.playItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Multitoolbar Play"]
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(showPlayingOptionsForSelection:)];
        self.playItem.accessibilityLabel = @"Play".ls;
    }
    if (!self.downloadItem) {
        self.downloadItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Multitoolbar Download"]
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(downloadSelection:)];
        self.downloadItem.accessibilityLabel = @"Download".ls;
    }
    if (!self.selectAllItem) {
        self.selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"All".ls
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(selectAllAction:)];
    }
    if (!self.cancelItem) {
        self.cancelItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                        target:self
                                                                        action:@selector(editForCachingAction:)];
        self.cancelItem.tintColor = ICTintColor;
    }

    // iOS 26: items are now created, use floating glass buttons + editing toolbar
    if (@available(iOS 26.0, *)) {
        [self _syncFloatingButtonVisibility];
        return;
    }

    // iOS ≤25: system toolbar
    [self willChangeValueForKey:@"toolbarItems"];

    BOOL isEditing = (self.tableView.editing && self.editingStyle == EpisodesTableViewEditingStyleDownload);

	if (isEditing)
	{
        NSInteger selectedCellsCount = [[self.tableView indexPathsForSelectedRows] count];
        NSInteger rowCount = [self.tableView numberOfRowsInSection:0];

        self.selectAllItem.title = [self _selectionToggleTitleKeyForSelectedCount:selectedCellsCount rowCount:rowCount].ls;
        self.editItem.enabled = (selectedCellsCount > 0);
        self.playItem.enabled = (selectedCellsCount > 0);
        self.downloadItem.enabled = (selectedCellsCount > 0);

        NSArray* currentItems = self.toolbarItems;
        if (currentItems.count != 9 || ![currentItems containsObject:self.editItem]) {
            UIBarButtonItem* flex1 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
            UIBarButtonItem* flex2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
            UIBarButtonItem* flex3 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
            UIBarButtonItem* flex4 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];

            [self setToolbarItems:@[self.editItem, flex1, self.playItem, flex2, self.downloadItem, flex3, self.selectAllItem, flex4, self.cancelItem] animated:animated];
        }
	}
    else
	{
        self.cacheItem.enabled = ([self.episodes count] > 0);
        self.consumeAllItem.enabled = ([self.episodes count] > 0);

        NSArray* currentItems = self.toolbarItems;
        if (currentItems.count != 3 || ![currentItems containsObject:self.consumeAllItem]) {
            UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
            [self setToolbarItems:@[self.consumeAllItem, flexSpace, self.cacheItem] animated:animated];
        }
	}

    [self didChangeValueForKey:@"toolbarItems"];

}


- (void) reloadDataAndPreserveSelection
{
    NSArray* myEpisodes = self.episodes;

    NSMutableArray* selectedEpisodes = [NSMutableArray array];

    NSArray* indexPathes = [self.tableView indexPathsForSelectedRows];
    for(NSIndexPath* indexPath in indexPathes)
    {
        if (indexPath.row < [myEpisodes count]) {
            [selectedEpisodes addObject:myEpisodes[indexPath.row]];
        }
    }

    [self.tableView reloadData];

    for(CDEpisode* episode in selectedEpisodes) {
        NSUInteger index = [myEpisodes indexOfObject:episode];
        if (index != NSNotFound) {
            [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForItem:index inSection:0] animated:NO scrollPosition:UITableViewScrollPositionNone];
        }
    }
}

#pragma mark -

- (NSInteger) playbackTime
{
    __block NSInteger playbackTime = 0;
    [self enumerateEpisodesUsingBlock:^(CDEpisode* episode, NSUInteger idx, BOOL *stop) {
        playbackTime += episode.duration;
    }];
    
    return playbackTime;
}

- (NSInteger) _numberOfNotPlayedDisplayEpisodes
{
	// count non-consumed
	__block NSInteger nonConsumed = 0;
	[self enumerateEpisodesUsingBlock:^(CDEpisode* episode, NSUInteger idx, BOOL *stop) {
		nonConsumed += (episode.consumed) ? 0 : 1;
	}];
	return nonConsumed;
}

- (NSInteger)_numberOfDisplayEpisodes
{
    return self.episodes.count;
}

- (NSString*)_selectionToggleTitleKeyForSelectedCount:(NSUInteger)selectedCount rowCount:(NSUInteger)rowCount
{
    return ICEpisodeSelectionToggleTitleKey(selectedCount, rowCount);
}

- (NSInteger) _numberOfPlayedDisplayEpisodes
{
	// count non-consumed
	__block NSInteger nonConsumed = 0;
	[self enumerateEpisodesUsingBlock:^(CDEpisode* episode, NSUInteger idx, BOOL *stop) {
		nonConsumed += (episode.consumed) ? 1 : 0;
	}];
	return nonConsumed;
}

- (NSInteger) _numberOfPlayedDownloadedEpisodes
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    // count non-consumed
    __block NSInteger downloaded = 0;
    [self enumerateEpisodesUsingBlock:^(CDEpisode* episode, NSUInteger idx, BOOL *stop) {
        downloaded += (episode.consumed && [cman episodeIsCached:episode])?1:0;
    }];
    return downloaded;
}

- (void)enumerateEpisodesUsingBlock:(void (^)(CDEpisode* episode, NSUInteger idx, BOOL *stop))block
{
    [[self.episodes copy] enumerateObjectsUsingBlock:block];
}

- (void)loadEpisodeObjectIDsForBulkActionWithCompletion:(void (^)(NSArray<NSManagedObjectID*>*, NSError*))completion
{
    if (!completion) {
        return;
    }

    NSMutableArray<NSManagedObjectID*>* episodeObjectIDs = [[NSMutableArray alloc] initWithCapacity:self.episodes.count];
    for (CDEpisode* episode in [self.episodes copy]) {
        if (episode.objectID) {
            [episodeObjectIDs addObject:episode.objectID];
        }
    }
    completion(episodeObjectIDs, nil);
}


- (void) _setAllAsConsumed:(BOOL)consumed
{
	VDModalInfo* allConsumedModalInfo = [VDModalInfo modalInfo];
	allConsumedModalInfo.closableByTap = NO;
	
	allConsumedModalInfo.textLabel.text = (consumed) ? @"All Played".ls : @"All Unplayed".ls;
	allConsumedModalInfo.animation = VDModalInfoAnimationScaleUp;
	allConsumedModalInfo.showingProgress = YES;
	allConsumedModalInfo.size = CGSizeMake(125, 125);
	
	[allConsumedModalInfo show];

    [self loadEpisodeObjectIDsForBulkActionWithCompletion:^(NSArray<NSManagedObjectID*>* episodeObjectIDs, NSError* loadError) {
        if (loadError) {
            [allConsumedModalInfo close];
            [self presentAlertControllerWithTitle:@"Unable to Load Episodes".ls
                                          message:@"The episodes could not be loaded from this device. Try again.".ls
                                           button:@"OK".ls
                                         animated:YES
                                       completion:nil];
            return;
        }

        if (episodeObjectIDs.count == 0) {
            [allConsumedModalInfo close];
            return;
        }

        NSMutableSet<NSManagedObjectID*>* feedObjectIDsNeedingAutoDownload = [NSMutableSet set];
        NSMutableOrderedSet<CDEpisode*>* cacheEpisodes = [NSMutableOrderedSet orderedSet];
        [[ICiCloudSyncManager sharedManager] beginLocalOutboxBatch];
        [self _setEpisodeObjectIDs:episodeObjectIDs
                asConsumed:consumed
              startingAt:0
feedObjectIDsNeedingAutoDownload:feedObjectIDsNeedingAutoDownload
             cacheEpisodes:cacheEpisodes
                 modalInfo:allConsumedModalInfo];
    }];
}

- (void) _setEpisodeObjectIDs:(NSArray<NSManagedObjectID*>*)episodeObjectIDs
           asConsumed:(BOOL)consumed
            startingAt:(NSUInteger)startIndex
feedObjectIDsNeedingAutoDownload:(NSMutableSet<NSManagedObjectID*>*)feedObjectIDsNeedingAutoDownload
         cacheEpisodes:(NSMutableOrderedSet<CDEpisode*>*)cacheEpisodes
             modalInfo:(VDModalInfo*)modalInfo
{
    NSUInteger endIndex = MIN(startIndex + kBulkEpisodeMutationBatchSize, episodeObjectIDs.count);
    NSMutableArray<NSDictionary*>* previousStates = [NSMutableArray array];
    NSMutableSet<NSManagedObjectID*>* batchFeedObjectIDs = [NSMutableSet set];
    NSMutableOrderedSet<CDEpisode*>* batchCacheEpisodes = [NSMutableOrderedSet orderedSet];
    [DMANAGER.objectContext.undoManager disableUndoRegistration];
    for (NSUInteger index = startIndex; index < endIndex; index++) {
        NSError* existingObjectError = nil;
        CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:episodeObjectIDs[index]
                                                                               error:&existingObjectError];
        if (existingObjectError || ![episode isKindOfClass:[CDEpisode class]] || episode.isDeleted) {
            continue;
        }
        if (episode.consumed != consumed) {
            [previousStates addObject:@{
                @"episode": episode,
                @"previousConsumed": @(episode.consumed),
                @"previousPosition": @(episode.position),
            }];
            episode.consumed = consumed;
            if (consumed) {
                episode.position = 0;
            }
        }

        if (consumed) {
            if ([episode.feed boolForKey:AutoDeleteAfterMarkedAsPlayed] && !episode.starred) {
                [batchCacheEpisodes addObject:episode];
            }
        } else if (episode.feed && !episode.feed.isDeleted && episode.feed.objectID) {
            [batchFeedObjectIDs addObject:episode.feed.objectID];
        }
    }
    NSError* saveError = previousStates.count > 0 ? [DMANAGER saveReturningError] : nil;
    if (saveError) {
        for (NSDictionary* previousState in previousStates) {
            CDEpisode* episode = previousState[@"episode"];
            episode.consumed = [previousState[@"previousConsumed"] boolValue];
            episode.position = [previousState[@"previousPosition"] doubleValue];
        }
        [DMANAGER.objectContext processPendingChanges];
        [DMANAGER.objectContext.undoManager enableUndoRegistration];
        [self _finishBulkEpisodeMutationWithCacheEpisodes:cacheEpisodes
                                                automatic:YES
                                                saveError:saveError
                                                modalInfo:modalInfo
                                              reloadTable:YES];
        return;
    }
    [DMANAGER.objectContext.undoManager enableUndoRegistration];
    [feedObjectIDsNeedingAutoDownload unionSet:batchFeedObjectIDs];
    [cacheEpisodes addObjectsFromArray:batchCacheEpisodes.array];

    if (endIndex < episodeObjectIDs.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _setEpisodeObjectIDs:episodeObjectIDs
                    asConsumed:consumed
                     startingAt:endIndex
feedObjectIDsNeedingAutoDownload:feedObjectIDsNeedingAutoDownload
                 cacheEpisodes:cacheEpisodes
                      modalInfo:modalInfo];
        });
        return;
    }

    if (!consumed) {
        for (NSManagedObjectID* feedObjectID in feedObjectIDsNeedingAutoDownload) {
            NSError* existingObjectError = nil;
            CDFeed* feed = (CDFeed*)[DMANAGER.objectContext existingObjectWithID:feedObjectID
                                                                          error:&existingObjectError];
            if (!existingObjectError && [feed isKindOfClass:[CDFeed class]] && !feed.isDeleted) {
                [[SubscriptionManager sharedSubscriptionManager] autoDownloadEpisodesInFeedAsynchronously:feed];
            }
        }
    }
    [self _finishBulkEpisodeMutationWithCacheEpisodes:cacheEpisodes
                                            automatic:YES
                                            saveError:nil
                                            modalInfo:modalInfo
                                          reloadTable:YES];
}

- (void) _archiveAllPlayed
{
    VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Deleting…".ls];
	[modelInfo show];

    [self loadEpisodeObjectIDsForBulkActionWithCompletion:^(NSArray<NSManagedObjectID*>* episodeObjectIDs, NSError* loadError) {
        if (loadError) {
            [modelInfo close];
            [self presentAlertControllerWithTitle:@"Unable to Load Episodes".ls
                                          message:@"The episodes could not be loaded from this device. Try again.".ls
                                           button:@"OK".ls
                                         animated:YES
                                       completion:nil];
            return;
        }
        if (episodeObjectIDs.count == 0) {
            [modelInfo close];
            return;
        }

        [[ICiCloudSyncManager sharedManager] beginLocalOutboxBatch];
        [self _archivePlayedEpisodeObjectIDs:episodeObjectIDs
                                  startingAt:0
                               cacheEpisodes:[NSMutableOrderedSet orderedSet]
                                   modalInfo:modelInfo];
    }];
}

- (void)_archivePlayedEpisodeObjectIDs:(NSArray<NSManagedObjectID*>*)episodeObjectIDs
                            startingAt:(NSUInteger)startIndex
                         cacheEpisodes:(NSMutableOrderedSet<CDEpisode*>*)cacheEpisodes
                             modalInfo:(VDModalInfo*)modalInfo
{
    NSUInteger endIndex = MIN(startIndex + kBulkEpisodeMutationBatchSize, episodeObjectIDs.count);
    NSMutableArray<NSDictionary*>* previousStates = [NSMutableArray array];
    NSMutableOrderedSet<CDEpisode*>* batchCacheEpisodes = [NSMutableOrderedSet orderedSet];
    [DMANAGER.objectContext.undoManager disableUndoRegistration];
    for (NSUInteger index = startIndex; index < endIndex; index++) {
        NSError* existingObjectError = nil;
        CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:episodeObjectIDs[index]
                                                                               error:&existingObjectError];
        if (existingObjectError || ![episode isKindOfClass:[CDEpisode class]] || episode.isDeleted) {
            continue;
        }
        if (episode.consumed && !episode.starred) {
            [batchCacheEpisodes addObject:episode];
            if (!episode.archived) {
                [previousStates addObject:@{
                    @"episode": episode,
                    @"previousArchived": @(episode.archived),
                }];
                episode.archived = YES;
            }
        }
    }
    NSError* saveError = previousStates.count > 0 ? [DMANAGER saveReturningError] : nil;
    if (saveError) {
        for (NSDictionary* previousState in previousStates) {
            CDEpisode* episode = previousState[@"episode"];
            episode.archived = [previousState[@"previousArchived"] boolValue];
        }
        [DMANAGER.objectContext processPendingChanges];
        [DMANAGER.objectContext.undoManager enableUndoRegistration];
        [self _finishBulkEpisodeMutationWithCacheEpisodes:cacheEpisodes
                                                automatic:NO
                                                saveError:saveError
                                                modalInfo:modalInfo
                                              reloadTable:NO];
        return;
    }
    [DMANAGER.objectContext.undoManager enableUndoRegistration];
    [cacheEpisodes addObjectsFromArray:batchCacheEpisodes.array];

    if (endIndex < episodeObjectIDs.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _archivePlayedEpisodeObjectIDs:episodeObjectIDs
                                      startingAt:endIndex
                                   cacheEpisodes:cacheEpisodes
                                       modalInfo:modalInfo];
        });
        return;
    }

    [self _finishBulkEpisodeMutationWithCacheEpisodes:cacheEpisodes
                                            automatic:NO
                                            saveError:nil
                                            modalInfo:modalInfo
                                          reloadTable:NO];
}

- (void)_finishBulkEpisodeMutationWithCacheEpisodes:(NSMutableOrderedSet<CDEpisode*>*)cacheEpisodes
                                           automatic:(BOOL)automatic
                                           saveError:(NSError*)saveError
                                           modalInfo:(VDModalInfo*)modalInfo
                                         reloadTable:(BOOL)reloadTable
{
    [[ICiCloudSyncManager sharedManager] endLocalOutboxBatch];
    void (^finishUI)(NSError*) = ^(NSError* cacheError) {
        [self updateEpisodes];
        if (reloadTable) [self.tableView reloadData];
        [self _updateToolbarLabels];
        [self _updateToolbarItemsAnimated:NO];
        [modalInfo close];

        if (saveError) {
            [self presentAlertControllerWithTitle:@"Unable to Save".ls
                                          message:@"The changes could not be saved on this device. Check the available storage and try again.".ls
                                           button:@"OK".ls
                                         animated:YES
                                       completion:nil];
        } else if (automatic && cacheError) {
            [self presentAlertControllerWithTitle:@"Download Could Not Be Removed".ls
                                          message:cacheError.localizedDescription
                                           button:@"OK".ls
                                         animated:YES
                                       completion:nil];
        }
    };

    if (cacheEpisodes.count == 0) {
        finishUI(nil);
        return;
    }
    [[CacheManager sharedCacheManager] removeCacheForEpisodes:cacheEpisodes.array
                                                    automatic:automatic
                                                   completion:finishUI];
}

- (void) _clearCacheOfAllPlayed
{
    VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Clearing…".ls];
	[modelInfo show];

    [self loadEpisodeObjectIDsForBulkActionWithCompletion:^(NSArray<NSManagedObjectID*>* episodeObjectIDs, NSError* loadError) {
        if (loadError) {
            [modelInfo close];
            [self presentAlertControllerWithTitle:@"Unable to Load Episodes".ls
                                          message:@"The episodes could not be loaded from this device. Try again.".ls
                                           button:@"OK".ls
                                         animated:YES
                                       completion:nil];
            return;
        }
        [self _clearPlayedCacheForEpisodeObjectIDs:episodeObjectIDs
                                       cachedHashes:[CacheManager sharedCacheManager].cachedEpisodeObjectHashes
                                         startingAt:0
                                    episodesToClear:[NSMutableOrderedSet orderedSet]
                                         modalInfo:modelInfo];
    }];
}

- (void)_clearPlayedCacheForEpisodeObjectIDs:(NSArray<NSManagedObjectID*>*)episodeObjectIDs
                                 cachedHashes:(NSSet<NSString*>*)cachedHashes
                                  startingAt:(NSUInteger)startIndex
                             episodesToClear:(NSMutableOrderedSet<CDEpisode*>*)episodesToClear
                                   modalInfo:(VDModalInfo*)modalInfo
{
    NSUInteger endIndex = MIN(startIndex + kBulkEpisodeMutationBatchSize, episodeObjectIDs.count);
    for (NSUInteger index = startIndex; index < endIndex; index++) {
        NSError* existingObjectError = nil;
        CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:episodeObjectIDs[index]
                                                                               error:&existingObjectError];
        if (!existingObjectError &&
            [episode isKindOfClass:[CDEpisode class]] &&
            !episode.isDeleted &&
            episode.consumed &&
            [cachedHashes containsObject:episode.objectHash]) {
            [episodesToClear addObject:episode];
        }
    }

    if (endIndex < episodeObjectIDs.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _clearPlayedCacheForEpisodeObjectIDs:episodeObjectIDs
                                           cachedHashes:cachedHashes
                                             startingAt:endIndex
                                        episodesToClear:episodesToClear
                                             modalInfo:modalInfo];
        });
        return;
    }

    [self _finishClearPlayedCacheWithEpisodes:episodesToClear modalInfo:modalInfo];
}

- (void)_finishClearPlayedCacheWithEpisodes:(NSMutableOrderedSet<CDEpisode*>*)episodesToClear
                                  modalInfo:(VDModalInfo*)modalInfo
{
    void (^finishUI)(NSError*) = ^(__unused NSError* error) {
        [self updateEpisodes];
        [self _updateToolbarLabels];
        [self _updateToolbarItemsAnimated:NO];
        [modalInfo close];
    };
    if (episodesToClear.count == 0) {
        finishUI(nil);
        return;
    }
    [[CacheManager sharedCacheManager] removeCacheForEpisodes:episodesToClear.array
                                                    automatic:NO
                                                   completion:finishUI];
}


- (void) consumeAllAction:(id)sender
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    if ([self _numberOfNotPlayedDisplayEpisodes] > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Mark all as Played".ls
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * action) {
                                                    STRONG_SELF
                                                    [self perform:^(id sender) {
                                                        [self _setAllAsConsumed:YES];
                                                    } afterDelay:0.3];
                                                    self.alertController = nil;
                                                }]];
    }
    
    if ([self _numberOfDisplayEpisodes]-[self _numberOfNotPlayedDisplayEpisodes] > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Mark all as Unplayed".ls
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * action) {
                                                    STRONG_SELF
                                                    [self perform:^(id sender) {
                                                        [self _setAllAsConsumed:NO];
                                                    } afterDelay:0.3];
                                                    self.alertController = nil;
                                                }]];
    }
    
    if ([self _numberOfPlayedDownloadedEpisodes] > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete played content".ls
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * action) {
                                                    STRONG_SELF
                                                    [self perform:^(id sender) {
                                                        [self _clearCacheOfAllPlayed];
                                                    } afterDelay:0.3];
                                                    self.alertController = nil;
                                                }]];
    }
    
    if ([self canArchiveEpisodes] && [self _numberOfPlayedDisplayEpisodes] > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Delete all Played".ls
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * action) {
                                                    STRONG_SELF
                                                    [self perform:^(id sender) {
                                                        [self _archiveAllPlayed];
                                                    } afterDelay:0.3];
                                                    self.alertController = nil;
                                                }]];
    }
    
    [self addAdditionalButtonsToMultiActionSheet:alert completionBlock:^{
        STRONG_SELF
        self.alertController = nil;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                self.alertController = nil;
                                            }]];
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        [alert setModalPresentationStyle:UIModalPresentationPopover];
        UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
        popPresenter.sourceView = self.view;
        popPresenter.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
        popPresenter.permittedArrowDirections = 0;
    }
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.alertController = alert;

    // Present directly - the helper method can silently fail
    if (self.presentedViewController) {
        [self.presentedViewController dismissViewControllerAnimated:NO completion:^{
            [self presentViewController:alert animated:YES completion:NULL];
        }];
    } else {
        [self presentViewController:alert animated:YES completion:NULL];
    }
}


- (void) _updateCacheButtonStateWithSelectedIndexPathes:(NSArray*)indexPathes
{
    if (self.editing)
    {
        [self _updateToolbarItemsAnimated:NO];
    }
}


#pragma mark -
#pragma mark Pan Gesture

- (void) didSwipeRightInCellAtIndexPath:(NSIndexPath*)indexPath
{
	NSArray* lEpisodes = self.episodes;
    
    // swiping on an empty cell not allowed
    if (indexPath.section != 0 || indexPath.row >= [lEpisodes count]) {
        return;
    }
    
	CDEpisode* episode = (CDEpisode*)[lEpisodes objectAtIndex:indexPath.row];
	EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[self.tableView cellForRowAtIndexPath:indexPath];
    
	if ([cell isKindOfClass:[EpisodesTableViewCell class]])
	{
		BOOL flag = !episode.consumed;
		
        self.userAction = YES;
        self.suppressNextListReload = YES;
        [DMANAGER markEpisode:episode asConsumed:flag];
        
        // stop playback of episode
		if (flag && [episode isEqual:[AudioSession sharedAudioSession].episode]) {
			[[AudioSession sharedAudioSession] stop];
		}
		
        BOOL removed = [self _removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:indexPath];
        if (!removed) {
            [cell updatePlayedAndStarredState];
        }
		[self _updateToolbarItemsAnimated:NO];
        [self _updateToolbarLabels];
		
        self.userAction = NO;
		PlaySoundFile((flag)?@"AffirmOut":@"AffirmIn", NO);
	}
}

- (void) toggleFavoriteAtIndexPath:(NSIndexPath*)indexPath
{
	NSArray* lEpisodes = self.episodes;
    
    // swiping on an empty cell not allowed
    if (indexPath.section != 0 || indexPath.row >= [lEpisodes count]) {
        return;
    }
    
	CDEpisode* episode = (CDEpisode*)[lEpisodes objectAtIndex:indexPath.row];
	EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[self.tableView cellForRowAtIndexPath:indexPath];
    
	if ([cell isKindOfClass:[EpisodesTableViewCell class]])
	{
		BOOL flag = !episode.starred;
		
        self.userAction = YES;
        self.suppressNextListReload = YES;
        [DMANAGER markEpisode:episode asStarred:flag];
        
        BOOL removed = [self _removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:indexPath];
        if (!removed) {
            [cell updatePlayedAndStarredState];
        }
		[self _updateToolbarItemsAnimated:NO];
        [self _updateToolbarLabels];
		self.userAction = NO;
		PlaySoundFile((flag)?@"AffirmIn":@"AffirmOut", NO);
	}
}

- (UIImage*) _imageForSwipeAction:(ICEpisodeSwipeAction)action episode:(CDEpisode*)episode
{
    UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    NSString* name;
    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
            // consumed → mark unplayed: full dot. !consumed → mark played: empty circle
            name = episode.consumed ? @"circle.fill" : @"circle";
            break;
        case ICEpisodeSwipeActionToggleFavorite:
            name = episode.starred ? @"star.slash" : @"star";
            break;
        case ICEpisodeSwipeActionDownload:
            return [self _downloadStartActionImage];
        case ICEpisodeSwipeActionAddToPlayNext:
            return [self _playNextActionImageForEpisode:episode configuration:config];
        case ICEpisodeSwipeActionDelete:
            name = @"trash";
            break;
        case ICEpisodeSwipeActionEpisodeInfo:
            name = @"info.circle";
            break;
        case ICEpisodeSwipeActionTranscribe:
            name = @"captions.bubble";
            break;
        case ICEpisodeSwipeActionSendToAppleWatch:
            name = [[AppleWatchSyncManager sharedManager] isEpisodeSelectedForWatch:episode] ? @"applewatch.slash" : @"applewatch";
            break;
        default:
            name = @"circle";
            break;
    }
    UIImage* image = [UIImage systemImageNamed:name withConfiguration:config];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIImage*) _downloadStartActionImage
{
    NSString* imageName = ICEpisodeDownloadActionStartIconName();
    UIImage* image = ICEpisodeDownloadActionStartUsesAssetImage() ? [UIImage imageNamed:imageName] : [UIImage systemImageNamed:imageName];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (NSString*) _playNextActionTitleForEpisode:(CDEpisode*)episode
{
    return [[AudioSession sharedAudioSession].playlist containsObject:episode] ? @"Remove from Play Next" : @"Add to Play Next";
}

- (UIImage*) _playNextActionImageForEpisode:(CDEpisode*)episode configuration:(UIImageSymbolConfiguration*)configuration
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
    UIImageSymbolConfiguration* badgeConfig = [UIImageSymbolConfiguration configurationWithPointSize:badgeSide weight:UIImageSymbolWeightSemibold];
    UIImage* badgeImage = [[UIImage systemImageNamed:@"xmark.circle.fill" withConfiguration:badgeConfig] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];

    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasRect.size];
    UIImage* rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [ICMutedTextColor setFill];
        [baseImage drawInRect:canvasRect];
        [ICMutedTextColor setFill];
        [badgeImage drawInRect:badgeRect];
    }];
    return [rendered imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

- (void) _togglePlayNextForEpisode:(CDEpisode*)episode
{
    BOOL inUpNext = [[AudioSession sharedAudioSession].playlist containsObject:episode];
    NSString* toastText;

    if (inUpNext) {
        [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
        toastText = @"Removed from Play Next".ls;
    } else {
        [[AudioSession sharedAudioSession] appendToUpNext:@[episode]];
        toastText = @"Added to Play Next".ls;
    }
    [self _showPlayNextToastWithText:toastText added:!inUpNext];
}

- (void) _presentPlayNextViewController
{
    UpNextTableViewController* controller = [UpNextTableViewController viewController];
    PortraitNavigationController* navigationController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
    navigationController.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:navigationController animated:YES completion:nil];
}

- (void) _openPlayNextOverlayAction:(id)sender
{
    [self _presentPlayNextViewController];
}

// VoiceOver label for image-only swipe actions. Uses the same wording as the
// long-press context menu so both surfaces announce identically.
- (NSString*) _accessibilityLabelForSwipeAction:(ICEpisodeSwipeAction)action episode:(CDEpisode*)episode
{
    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
            return episode.consumed ? @"Mark as Unplayed".ls : @"Mark as Played".ls;
        case ICEpisodeSwipeActionToggleFavorite:
            return episode.starred ? @"Unmark Favorite".ls : @"Mark as Favorite".ls;
        case ICEpisodeSwipeActionDownload:
        {
            CacheManager* cman = [CacheManager sharedCacheManager];
            if ([cman episodeIsCached:episode]) {
                return @"Delete Download".ls;
            } else if ([cman isCachingEpisode:episode]) {
                return @"Cancel Download".ls;
            }
            return @"Download".ls;
        }
        case ICEpisodeSwipeActionAddToPlayNext:
            return [self _playNextActionTitleForEpisode:episode].ls;
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

- (UIColor*) _tintColorForSwipeAction:(ICEpisodeSwipeAction)action episode:(CDEpisode*)episode
{
    UIColor* accentColor = ICTintColor;
    UIColor* grayColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
    UIColor* deleteColor = [UIColor systemRedColor];

    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
            return episode.consumed ? accentColor : grayColor;
        case ICEpisodeSwipeActionToggleFavorite:
            return episode.starred ? grayColor : accentColor;
        case ICEpisodeSwipeActionDownload:
        {
            CacheManager* cman = [CacheManager sharedCacheManager];
            if ([cman episodeIsCached:episode] || [cman isCachingEpisode:episode]) {
                return grayColor;
            } else {
                return accentColor;
            }
        }
        case ICEpisodeSwipeActionAddToPlayNext:
        {
            BOOL inUpNext = [[AudioSession sharedAudioSession].playlist containsObject:episode];
            return inUpNext ? grayColor : accentColor;
        }
        case ICEpisodeSwipeActionDelete:
            return deleteColor;
        case ICEpisodeSwipeActionEpisodeInfo:
            return accentColor;
        case ICEpisodeSwipeActionTranscribe:
            return [[TranscriptionEngine shared] hasSRTFor:episode.objectHash] ? deleteColor : accentColor;
        case ICEpisodeSwipeActionSendToAppleWatch:
            if (![[AppleWatchSyncManager sharedManager] canSendEpisodeToWatch:episode]) {
                return grayColor;
            }
            return [[AppleWatchSyncManager sharedManager] isEpisodeSelectedForWatch:episode] ? grayColor : accentColor;
        default:
            return grayColor;
    }
}

- (NSIndexPath*) _indexPathForEpisode:(CDEpisode*)episode
{
    if (!episode) {
        return nil;
    }

    NSArray* lEpisodes = self.episodes;
    NSString* objectHash = episode.objectHash;
    for(NSUInteger row = 0; row < [lEpisodes count]; row++) {
        CDEpisode* currentEpisode = (CDEpisode*)[lEpisodes objectAtIndex:row];
        if (currentEpisode == episode || [currentEpisode isEqual:episode]) {
            return [NSIndexPath indexPathForRow:row inSection:0];
        }

        if (objectHash && currentEpisode.objectHash && [currentEpisode.objectHash isEqualToString:objectHash]) {
            return [NSIndexPath indexPathForRow:row inSection:0];
        }
    }

    return nil;
}

- (BOOL) _removeEpisodeFromDisplayedListIfNeededAfterMutation:(CDEpisode*)episode atIndexPath:(NSIndexPath*)indexPath
{
    return NO;
}

- (UIContextualAction*) _contextualSwipeActionForSwipeAction:(ICEpisodeSwipeAction)swipeAction atIndexPath:(NSIndexPath*)indexPath
{
    if (swipeAction == ICEpisodeSwipeActionTranscribe && ![USER_DEFAULTS boolForKey:kLocalTranscriptionEnabled]) {
        return nil;
    }
    NSArray* lEpisodes = self.episodes;
    if (indexPath.section != 0 || indexPath.row >= [lEpisodes count]) {
        return nil;
    }

    CDEpisode* episode = (CDEpisode*)[lEpisodes objectAtIndex:indexPath.row];
    UIContextualActionStyle style = (swipeAction == ICEpisodeSwipeActionDelete) ? UIContextualActionStyleDestructive : UIContextualActionStyleNormal;
    __weak EpisodesTableViewController* weakSelf = self;

    UIContextualAction* action = [UIContextualAction contextualActionWithStyle:style title:nil handler:^(__unused UIContextualAction* action, __unused UIView* sourceView, void (^completionHandler)(BOOL)) {
        EpisodesTableViewController* strongSelf = weakSelf;
        if (!strongSelf) {
            completionHandler(NO);
            return;
        }

        NSIndexPath* currentIndexPath = [strongSelf _indexPathForEpisode:episode];
        if (!currentIndexPath) {
            completionHandler(NO);
            return;
        }

        [strongSelf _performSwipeAction:swipeAction atIndexPath:currentIndexPath];
        completionHandler(YES);
    }];
    // UIContextualAction has no accessibilityLabel; with title:nil UIKit falls back
    // to the image's accessibilityLabel for VoiceOver.
    UIImage* image = [self _imageForSwipeAction:swipeAction episode:episode];
    image.accessibilityLabel = [self _accessibilityLabelForSwipeAction:swipeAction episode:episode];
    action.image = image;
    action.backgroundColor = [self _tintColorForSwipeAction:swipeAction episode:episode];
    return action;
}

- (void) _showPlayNextToastWithText:(NSString*)text added:(BOOL)added
{
    UIWindow* window = App.ic_keyWindow;
    if (!window) return;

    // Container view with blur background
    UIVisualEffectView* blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurView.layer.cornerRadius = 12;
    blurView.clipsToBounds = YES;
    blurView.alpha = 0;

    // Horizontal stack: label + "Anzeigen" button
    UILabel* label = [[UILabel alloc] init];
    label.text = text;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:ICFontSize(14)];

    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Play Next".ls forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(14)];
    [button setTitleColor:ICTintColor forState:UIControlStateNormal];

    // Only show "Anzeigen" button when adding (navigating to empty list on remove makes no sense)
    button.hidden = !added;

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

    // Tap on "Anzeigen" navigates to Up Next
    [button addAction:[UIAction actionWithHandler:^(UIAction* action) {
        // Dismiss toast immediately
        [blurView removeFromSuperview];
        [self _openPlayNextOverlayAction:action];
    }] forControlEvents:UIControlEventTouchUpInside];

    // Animate in, wait 3 seconds, animate out
    [UIView animateWithDuration:0.3 animations:^{
        blurView.alpha = 1.0;
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ICEpisodePlayNextOverlayDisplayDuration() * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                blurView.alpha = 0;
            } completion:^(BOOL finished) {
                [blurView removeFromSuperview];
            }];
        });
    }];
}

- (void) _showTranscriptionToast
{
    [self _showTranscriptionToastWithText:NSLocalizedString(@"Transkription gestartet", nil)];
}

- (void) _showTranscriptionToastWithText:(NSString*)text
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

    UIButton* showButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [showButton setTitle:@"Show".ls forState:UIControlStateNormal];
    showButton.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(14)];
    [showButton setTitleColor:ICTintColor forState:UIControlStateNormal];

    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, showButton]];
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

    // Tap on "Anzeigen" navigates to Transcription Queue
    [showButton addAction:[UIAction actionWithHandler:^(__unused UIAction* action) {
        [blurView removeFromSuperview];
        InstacastAppDelegate* appDelegate = (InstacastAppDelegate*)[UIApplication sharedApplication].delegate;
        [appDelegate.mainViewController showTranscriptionQueue];
    }] forControlEvents:UIControlEventTouchUpInside];

    [UIView animateWithDuration:0.3 animations:^{
        blurView.alpha = 1.0;
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                blurView.alpha = 0;
            } completion:^(BOOL finished) {
                [blurView removeFromSuperview];
            }];
        });
    }];
}

- (void) _performSwipeAction:(ICEpisodeSwipeAction)action atIndexPath:(NSIndexPath*)indexPath
{
    NSArray* lEpisodes = self.episodes;
    if (indexPath.section != 0 || indexPath.row >= [lEpisodes count]) {
        return;
    }

    CDEpisode* episode = (CDEpisode*)[lEpisodes objectAtIndex:indexPath.row];
    EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[self.tableView cellForRowAtIndexPath:indexPath];

    // No app haptic here: UIKit already plays a system haptic for full-swipe
    // contextual actions, and any main-thread work in this method delays the
    // start of the swipe dismiss animation.

    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed:
        {
            BOOL flag = !episode.consumed;
            self.userAction = YES;
            self.suppressNextListReload = YES;
            [DMANAGER markEpisode:episode asConsumed:flag];
            if (flag && [episode isEqual:[AudioSession sharedAudioSession].episode]) {
                [[AudioSession sharedAudioSession] stop];
            }
            BOOL removed = [self _removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:indexPath];
            if (!removed && [cell isKindOfClass:[EpisodesTableViewCell class]]) {
                [cell updatePlayedAndStarredState];
            }
            [self _updateToolbarItemsAnimated:NO];
            [self _updateToolbarLabels];
            self.userAction = NO;
            PlaySoundFile((flag)?@"AffirmOut":@"AffirmIn", NO);
            break;
        }
        case ICEpisodeSwipeActionToggleFavorite:
        {
            [self toggleFavoriteAtIndexPath:indexPath];
            break;
        }
        case ICEpisodeSwipeActionDownload:
        {
            CacheManager* cman = [CacheManager sharedCacheManager];
            if ([cman episodeIsCached:episode]) {
                self.userAction = YES;
                self.suppressNextListReload = YES;
                [cman removeCacheForEpisode:episode automatic:NO];
                BOOL removed = [self _removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:indexPath];
                if (!removed && [cell isKindOfClass:[EpisodesTableViewCell class]]) {
                    [cell updatePlayComboButtonState];
                }
                self.userAction = NO;
                PlaySoundFile(@"AffirmOut", NO);
            } else if ([cman isCachingEpisode:episode]) {
                self.userAction = YES;
                self.suppressNextListReload = YES;
                [cman cancelCachingEpisode:episode disableAutoDownload:YES];
                if ([cell isKindOfClass:[EpisodesTableViewCell class]]) {
                    [cell updatePlayComboButtonState];
                }
                self.userAction = NO;
                PlaySoundFile(@"AffirmOut", NO);
            } else {
                WEAK_SELF
                [self _askUserForCellularDownloadIfNecessary:^(BOOL canDownload) {
                    if (canDownload) {
                        [[CacheManager sharedCacheManager] cacheEpisode:episode overwriteCellularLock:YES];
                        EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[weakSelf.tableView cellForRowAtIndexPath:indexPath];
                        [cell updatePlayComboButtonState];
                    }
                }];
                PlaySoundFile(@"AffirmIn", NO);
            }
            break;
        }
        case ICEpisodeSwipeActionAddToPlayNext:
        {
            [self _togglePlayNextForEpisode:episode];
            break;
        }
        case ICEpisodeSwipeActionDelete:
        {
            self.userAction = YES;
            self.suppressNextListReload = YES;

            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
            [DMANAGER setEpisode:episode archived:YES];

            BOOL removed = [self _removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:indexPath];
            if (!removed) {
                NSMutableArray* mutableEpisodes = [self.episodes mutableCopy];
                [mutableEpisodes removeObjectAtIndex:indexPath.row];
                self.episodes = [mutableEpisodes copy];

                [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationRight];
            }

            [self _updateToolbarItemsAnimated:NO];
            [self _updateToolbarLabels];
            self.userAction = NO;
            PlaySoundFile(@"AffirmOut", NO);
            break;
        }
        case ICEpisodeSwipeActionEpisodeInfo:
        {
            [self _pushShowNotesOfEpisode:episode animated:YES inAppearanceTransition:NO];
            break;
        }
        case ICEpisodeSwipeActionTranscribe:
        {
            [self _transcribeEpisode:episode];
            break;
        }
        case ICEpisodeSwipeActionSendToAppleWatch:
        {
            AppleWatchSyncManager* watchManager = [AppleWatchSyncManager sharedManager];
            if (![watchManager canSendEpisodeToWatch:episode]) {
                break;
            }
            if ([watchManager isEpisodeSelectedForWatch:episode]) {
                [watchManager removeEpisodeFromWatch:episode];
                PlaySoundFile(@"AffirmOut", NO);
            }
            else {
                [watchManager sendEpisodeToWatch:episode];
                PlaySoundFile(@"AffirmIn", NO);
            }
            break;
        }
    }
}

- (void) _transcribeEpisode:(CDEpisode*)episode
{
    if (![USER_DEFAULTS boolForKey:kLocalTranscriptionEnabled]) {
        return;
    }

    // Check if already transcribed
    if ([[TranscriptionEngine shared] hasSRTFor:episode.objectHash]) {
        return;
    }

    if (![ICDownloadableModelStore selectedVoiceModelIsReady]) {
        UIViewController *settingsVC = [TranscriptionSettingsViewController modelLibraryViewControllerFocusedOnVoiceToText:YES];
        [self.navigationController pushViewController:settingsVC animated:YES];
        return;
    }

    // Enqueue for transcription — auto-downloads episode if needed
    CacheManager* cman = [CacheManager sharedCacheManager];
    NSURL* audioURL = [cman episodeIsCached:episode] ? [cman URLForCachedEpisode:episode] : nil;
    BOOL enqueued = [[TranscriptionQueue shared] enqueueWithEpisodeHash:episode.objectHash
                                                          episodeTitle:episode.title ?: @""
                                                             feedTitle:episode.feed.title ?: @""
                                                              audioURL:audioURL
                                                              language:episode.feed.language];
    if (enqueued) {
        PlaySoundFile(@"AffirmIn", NO);
        [self _showTranscriptionToast];
    } else {
        // Already in queue — haptic feedback only
        PlayHapticFeedback(ICHapticFeedbackLight);
    }
    [self.tableView reloadData];
}

- (UISwipeActionsConfiguration*)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.tableView.editing) {
        return nil;
    }

    ICEpisodeSwipeAction swipeAction = [USER_DEFAULTS integerForKey:EpisodeSwipeRightAction];
    UIContextualAction* action = [self _contextualSwipeActionForSwipeAction:swipeAction atIndexPath:indexPath];
    if (!action) {
        return nil;
    }

    UISwipeActionsConfiguration* configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (UISwipeActionsConfiguration*)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.tableView.editing) {
        return nil;
    }

    ICEpisodeSwipeAction swipeAction = [USER_DEFAULTS integerForKey:EpisodeSwipeLeftAction];
    UIContextualAction* action = [self _contextualSwipeActionForSwipeAction:swipeAction atIndexPath:indexPath];
    if (!action) {
        return nil;
    }

    UISwipeActionsConfiguration* configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (void) _transcriptionQueueChanged
{
    [self.tableView reloadData];
}

- (UIView*) _separatorViewOfCell:(UITableViewCell*)cell
{
    for(UIView* subview in cell.subviews) {
        if (CGRectGetHeight(subview.bounds) == 1) {
            return subview;
        }
    }
    
    return nil;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if (gestureRecognizer == self.cancelDeleteButtonTapRecognizer)
    {
        for(NSIndexPath* indexPath in [self.tableView indexPathsForVisibleRows])
        {
            EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[self.tableView cellForRowAtIndexPath:indexPath];
            if (cell.showsDeleteControl) {
                return YES;
            }
        }
    }
    
    return NO;
}

- (void) cancelDelete:(id)sender
{
    for(NSIndexPath* indexPath in [self.tableView indexPathsForVisibleRows])
    {
        EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[self.tableView cellForRowAtIndexPath:indexPath];
        if (cell.showsDeleteControl) {
            [cell cancelDelete:nil];
        }
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self cancelDelete:nil];
}


#pragma mark -
#pragma mark Actions

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
    if (self.tableView.editing) return nil;
    if (indexPath.row >= [self.episodes count]) return nil;

    WEAK_SELF
    UIContextMenuConfiguration* config = [UIContextMenuConfiguration configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
            __strong EpisodesTableViewController* strongSelf = weakSelf;
            if (!strongSelf) return [UIMenu menuWithTitle:@"" children:@[]];
            return [strongSelf _contextMenuForIndexPath:indexPath];
        }];
    // Force fixed element order so the cell long-press menu matches the show-notes
    // more-menu regardless of whether iOS would otherwise flip based on tap position.
    // Docs: https://developer.apple.com/documentation/uikit/uicontextmenuconfiguration/elementorder/fixed
    if (@available(iOS 16.0, *)) {
        config.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
    }
    return config;
}

- (UIMenu *) _contextMenuForIndexPath:(NSIndexPath *)indexPath
{
    CDEpisode* episode = (CDEpisode*)[self.episodes objectAtIndex:indexPath.row];
    NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];

    // Mark as Favorite / Unmark Favorite
    WEAK_SELF
    UIAction* favoriteAction = [UIAction actionWithTitle:(episode.starred) ? @"Unmark Favorite".ls : @"Mark as Favorite".ls
                                                   image:[UIImage systemImageNamed:episode.starred ? @"star.slash" : @"star"]
                                              identifier:nil
                                                 handler:^(UIAction *action) {
                                                     PlayHapticFeedback(ICHapticFeedbackLight);
                                                     [weakSelf toggleFavoriteAtIndexPath:indexPath];
                                                 }];
    [actions addObject:favoriteAction];

    // Mark as Played / Unplayed
    UIAction* playedAction = [UIAction actionWithTitle:episode.consumed ? @"Mark as Unplayed".ls : @"Mark as Played".ls
                                                  image:[UIImage systemImageNamed:episode.consumed ? @"circle.fill" : @"circle"]
                                             identifier:nil
                                                handler:^(UIAction *action) {
                                                    __strong EpisodesTableViewController* strongSelf = weakSelf;
                                                    if (!strongSelf) return;
                                                    PlayHapticFeedback(ICHapticFeedbackLight);
                                                    CDEpisode* ep = (CDEpisode*)[strongSelf.episodes objectAtIndex:indexPath.row];
                                                    BOOL flag = !ep.consumed;
                                                    strongSelf.userAction = YES;
                                                    strongSelf.suppressNextListReload = YES;
                                                    [DMANAGER markEpisode:ep asConsumed:flag];
                                                    if (flag && [ep isEqual:[AudioSession sharedAudioSession].episode]) {
                                                        [[AudioSession sharedAudioSession] stop];
                                                    }
                                                    BOOL removed = [strongSelf _removeEpisodeFromDisplayedListIfNeededAfterMutation:ep atIndexPath:indexPath];
                                                    if (!removed) {
                                                        EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[strongSelf.tableView cellForRowAtIndexPath:indexPath];
                                                        if ([cell isKindOfClass:[EpisodesTableViewCell class]]) {
                                                            [cell updatePlayedAndStarredState];
                                                        }
                                                    }
                                                    [strongSelf _updateToolbarItemsAnimated:NO];
                                                    [strongSelf _updateToolbarLabels];
                                                    strongSelf.userAction = NO;
                                                    PlaySoundFile(flag ? @"AffirmOut" : @"AffirmIn", NO);
                                                }];
    [actions addObject:playedAction];

    // Add to / Remove from Play Next
    {
        UIAction* playNextAction = [UIAction actionWithTitle:[self _playNextActionTitleForEpisode:episode].ls
                                                       image:[self _playNextActionImageForEpisode:episode configuration:nil]
                                                  identifier:nil
                                                     handler:^(UIAction *action) {
                                                         PlayHapticFeedback(ICHapticFeedbackLight);
                                                         [weakSelf _togglePlayNextForEpisode:episode];
                                                     }];
        [actions addObject:playNextAction];
    }

    AppleWatchSyncManager* watchManager = [AppleWatchSyncManager sharedManager];
    if ([watchManager canSendEpisodeToWatch:episode]) {
        BOOL selectedForWatch = [watchManager isEpisodeSelectedForWatch:episode];
        NSString* watchTitle = selectedForWatch ? @"Von Apple Watch entfernen".ls : @"An Apple Watch senden".ls;
        NSString* watchIcon = selectedForWatch ? @"applewatch.slash" : @"applewatch";
        UIAction* watchAction = [UIAction actionWithTitle:watchTitle
                                                    image:[UIImage systemImageNamed:watchIcon]
                                               identifier:nil
                                                  handler:^(__unused UIAction* action) {
                                                      if (selectedForWatch) {
                                                          [watchManager removeEpisodeFromWatch:episode];
                                                      }
                                                      else {
                                                          [watchManager sendEpisodeToWatch:episode];
                                                      }
                                                  }];
        [actions addObject:watchAction];

        if (selectedForWatch && ![watchManager isEpisodeDownloadedOnWatch:episode]) {
            UIAction* prioritizeAction = [UIAction actionWithTitle:@"Priorisiert auf Watch laden".ls
                                                             image:[UIImage systemImageNamed:@"arrow.down.circle"]
                                                        identifier:nil
                                                           handler:^(__unused UIAction* action) {
                                                               [watchManager prioritizeEpisodeOnWatch:episode];
                                                           }];
            [actions addObject:prioritizeAction];
        }
    }

    // Download (only if not cached and not currently caching)
    CacheManager* cman = [CacheManager sharedCacheManager];
    if (![cman episodeIsCached:episode] && ![cman isCachingEpisode:episode]) {
        UIAction* downloadAction = [UIAction actionWithTitle:@"Download".ls
                                                       image:[self _downloadStartActionImage]
                                                  identifier:nil
                                                     handler:^(UIAction *action) {
                                                         [weakSelf _askUserForCellularDownloadIfNecessary:^(BOOL canDownload) {
                                                             if (canDownload) {
                                                                 [[CacheManager sharedCacheManager] cacheEpisode:episode overwriteCellularLock:YES];
                                                                 EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[weakSelf.tableView cellForRowAtIndexPath:indexPath];
                                                                 [cell updatePlayComboButtonState];
                                                             }
                                                         }];
                                                     }];
        [actions addObject:downloadAction];
    }

    // Delete Download (only if cached)
    if ([cman episodeIsCached:episode]) {
        UIAction* deleteFileAction = [UIAction actionWithTitle:@"Delete Download".ls
                                                         image:[[UIImage systemImageNamed:@"square.and.arrow.down"] imageWithTintColor:[UIColor colorWithWhite:0.5f alpha:1.0f] renderingMode:UIImageRenderingModeAlwaysOriginal]
                                                    identifier:nil
                                                       handler:^(UIAction *action) {
                                                           [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
                                                           EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[weakSelf.tableView cellForRowAtIndexPath:indexPath];
                                                           [cell updatePlayComboButtonState];
                                                       }];
        [actions addObject:deleteFileAction];
    }

    // Transcribe (only if downloaded and not already transcribed)
    // Transcribe (episode will be auto-downloaded if needed)
    BOOL localTranscriptionEnabled = [USER_DEFAULTS boolForKey:kLocalTranscriptionEnabled];
    if (localTranscriptionEnabled && ![[TranscriptionEngine shared] hasSRTFor:episode.objectHash]) {
        UIAction* transcribeAction = [UIAction actionWithTitle:NSLocalizedString(@"Transkribieren", nil)
                                                         image:[UIImage systemImageNamed:@"captions.bubble"]
                                                    identifier:nil
                                                       handler:^(UIAction *action) {
                                                           [weakSelf _transcribeEpisode:episode];
                                                       }];
        [actions addObject:transcribeAction];
    }

    // Kapitel generieren (if transcript available but no generated chapters anywhere —
    // neither in the JSON cache nor copied into Core Data on first playback).
    BOOL hasTranscript = [[TranscriptionQueue shared] hasChapterGenerationTranscriptWithEpisodeHash:episode.objectHash];
    BOOL hasAnyChapters = [[ChapterGenerator shared] hasChaptersFor:episode.objectHash] || episode.chapters.count > 0;
    if (localTranscriptionEnabled && hasTranscript && !hasAnyChapters) {
        ICDownloadableModel* chapterModel = [ICDownloadableModelStore selectedModelForRole:ICDownloadableModelRoleTextToChapters];
        NSString* createTitle = chapterModel.usesRemoteChapterService
            ? NSLocalizedString(@"Kapitel und Zusammenfassung erstellen", nil)
            : NSLocalizedString(@"Kapitel erstellen", nil);
        UIAction* chaptersAction = [UIAction actionWithTitle:createTitle
                                                       image:[UIImage systemImageNamed:@"list.number"]
                                                  identifier:nil
                                                     handler:^(UIAction *action) {
                                                         if (![ICDownloadableModelStore selectedChapterModelCanGenerate]) {
                                                             UIViewController *settingsVC = [TranscriptionSettingsViewController modelLibraryViewControllerFocusedOnVoiceToText:NO];
                                                             [weakSelf.navigationController pushViewController:settingsVC animated:YES];
                                                             return;
                                                         }
                                                         BOOL started = [[TranscriptionQueue shared] generateChaptersWithEpisodeHash:episode.objectHash
                                                                                                                         episodeTitle:episode.title ?: @""
                                                                                                                            feedTitle:episode.feed.title ?: @""];
                                                         if (started) {
                                                             [weakSelf _showTranscriptionToastWithText:NSLocalizedString(@"Kapitelerkennung gestartet", nil)];
                                                             PlaySoundFile(@"AffirmIn", NO);
                                                         } else {
                                                             PlayHapticFeedback(ICHapticFeedbackLight);
                                                         }
                                                     }];
        [actions addObject:chaptersAction];
    }

    // Delete generated transcript + chapters as separate menu items
    {
        BOOL hasSRT = [[TranscriptionEngine shared] hasSRTFor:episode.objectHash];
        // Only the generated-chapter JSON proves ownership. CDChapter can also contain
        // podcast-provided chapters copied during playback, so it must not drive this action.
        BOOL hasGeneratedChapters = [[ChapterGenerator shared] hasChaptersFor:episode.objectHash];
        BOOL hasGeneratedSummary = hasGeneratedChapters && episode.objectHash.length > 0 && [[[ChapterGenerator shared] loadSummaryFor:episode.objectHash] length] > 0;

        if (hasSRT) {
            UIAction* deleteTranscriptAction = [UIAction actionWithTitle:NSLocalizedString(@"Transkript löschen", nil)
                                                         image:[UIImage systemImageNamed:@"captions.bubble"]
                                                    identifier:nil
                                                       handler:^(UIAction *action) {
                                                           [[TranscriptionEngine shared] removeSRTFor:episode.objectHash];
                                                           [weakSelf.tableView reloadData];
                                                           [[NSNotificationCenter defaultCenter] postNotificationName:@"ICTranscriptionDidChangeNotification" object:nil userInfo:@{@"episodeHash": episode.objectHash}];
                                                       }];
            deleteTranscriptAction.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:deleteTranscriptAction];
        }
        if (hasGeneratedChapters) {
            NSString* deleteTitle = hasGeneratedSummary
                ? NSLocalizedString(@"Kapitel und Zusammenfassung löschen", nil)
                : NSLocalizedString(@"Kapitel löschen", nil);
            UIAction* deleteChaptersAction = [UIAction actionWithTitle:deleteTitle
                                                         image:[UIImage systemImageNamed:@"list.number"]
                                                    identifier:nil
                                                       handler:^(UIAction *action) {
                                                           [[ChapterGenerator shared] removeGeneratedAnalysisForEpisodeHash:episode.objectHash];
                                                           [weakSelf.tableView reloadData];
                                                           [[NSNotificationCenter defaultCenter] postNotificationName:@"ICTranscriptionDidChangeNotification" object:nil userInfo:@{@"episodeHash": episode.objectHash}];
                                                       }];
            deleteChaptersAction.attributes = UIMenuElementAttributesDestructive;
            [actions addObject:deleteChaptersAction];
        }
    }

    // Show Notes or Play (depending on tap-on-episode setting)
    NSInteger tapAction = [USER_DEFAULTS integerForKey:TapOnEpisodeAction];
    if (tapAction == ICTapOnEpisodeActionOpenContextMenu) {
        UIAction* playAction = [UIAction actionWithTitle:@"Play Episode".ls
                                                   image:[UIImage systemImageNamed:@"play.fill"]
                                              identifier:nil
                                                 handler:^(UIAction *action) {
                                                     BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
                                                     PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:!alreadyPlaying];
                                                     [playbackController presentFromParentViewController:weakSelf.navigationController autostart:YES completion:NULL];
                                                 }];
        [actions addObject:playAction];

        UIAction* infoAction = [UIAction actionWithTitle:@"Episode Info".ls
                                                   image:[UIImage systemImageNamed:@"info.circle"]
                                              identifier:nil
                                                 handler:^(UIAction *action) {
                                                     [weakSelf _pushShowNotesOfEpisode:episode animated:YES inAppearanceTransition:NO];
                                                 }];
        [actions addObject:infoAction];
    } else if (tapAction == ICTapOnEpisodeActionShowNotes) {
        // Default tap shows notes, so context menu offers Play
        UIAction* playAction = [UIAction actionWithTitle:@"Play Episode".ls
                                                   image:[UIImage systemImageNamed:@"play.fill"]
                                              identifier:nil
                                                 handler:^(UIAction *action) {
                                                     BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
                                                     PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:!alreadyPlaying];
                                                     [playbackController presentFromParentViewController:weakSelf.navigationController autostart:YES completion:NULL];
                                                 }];
        [actions addObject:playAction];
    } else {
        // Default tap plays, so context menu offers Show Notes
        UIAction* infoAction = [UIAction actionWithTitle:@"Episode Info".ls
                                                   image:[UIImage systemImageNamed:@"info.circle"]
                                              identifier:nil
                                                 handler:^(UIAction *action) {
                                                     [weakSelf _pushShowNotesOfEpisode:episode animated:YES inAppearanceTransition:NO];
                                                 }];
        [actions addObject:infoAction];
    }

    // Additional actions from subclasses
    NSArray<UIMenuElement*>* additionalActions = [self additionalContextMenuActionsForIndexPath:indexPath];
    if (additionalActions.count > 0) {
        // Destructive actions in a separate section
        UIMenu* destructiveSection = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:additionalActions];
        [actions addObject:destructiveSection];
    }

    return [UIMenu menuWithTitle:episode.title children:actions];
}

- (NSArray<UIMenuElement*>*) additionalContextMenuActionsForIndexPath:(NSIndexPath*)indexPath
{
    return @[];
}


- (void) editForCachingAction:(id)sender
{
	if (!self.tableView.editing) {
        self.editingStyle = EpisodesTableViewEditingStyleDownload;
		[self setEditing:YES animated:YES];
	}
	else {
        self.editingStyle = EpisodesTableViewEditingStyleNormal;
		[self setEditing:NO animated:YES];
	}
}



- (void) showPlayingOptionsForSelection:(id)sender
{
    NSArray* selectedIndexPathes = [self.tableView indexPathsForSelectedRows];
    NSMutableArray* selectedEpisodes = [NSMutableArray array];
    for(NSIndexPath* indexPath in selectedIndexPathes) {
        [selectedEpisodes addObject:self.episodes[indexPath.row]];
    }
    AudioSession* session = [AudioSession sharedAudioSession];
    
    CDEpisode* firstEpisode = [selectedEpisodes firstObject];

    // Prepend all selected episodes to Up Next (including the first)
    [session prependToUpNext:selectedEpisodes];

    // Start playback of the first episode
    PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:firstEpisode forceReload:YES];
    [playbackController presentFromParentViewController:self.navigationController];
    [self setEditing:NO animated:YES];
}

- (void) showEditingOptionsForSelection:(id)sender
{
    NSArray* selectedIndexPathes = [self.tableView indexPathsForSelectedRows];
    
    typedef void(^ForEachEpisodeBlock)(CDEpisode* episode);
    void (^foreachSelectedEpisode)(ForEachEpisodeBlock) = ^(ForEachEpisodeBlock block) {
        
        NSArray* selectedIndexPathes = [self.tableView indexPathsForSelectedRows];
        for(NSIndexPath* indexPath in selectedIndexPathes) {
            CDEpisode* episode = self.episodes[indexPath.row];
            block(episode);
        }
        [self.tableView reloadRowsAtIndexPaths:selectedIndexPathes withRowAnimation:UITableViewRowAnimationFade];
        [DMANAGER save];
    };
    

    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Mark as Played".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    foreachSelectedEpisode(^(CDEpisode* episode){
                                                        if (!episode.consumed) {
                                                            [USER_DEFAULTS setInteger:[USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"] + 1 forKey:@"TotalEpisodesPlayedCount"];
                                                        }
                                                        episode.consumed = YES;
                                                    });
                                                    PlaySoundFile(@"AffirmIn", NO);
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Mark as Unplayed".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    foreachSelectedEpisode(^(CDEpisode* episode){
                                                        episode.consumed = NO;
                                                    });
                                                    PlaySoundFile(@"AffirmIn", NO);
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Mark as Favorite".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    foreachSelectedEpisode(^(CDEpisode* episode){
                                                        episode.starred = YES;
                                                    });
                                                    PlaySoundFile(@"AffirmOut", NO);
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Unmark Favorites".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    foreachSelectedEpisode(^(CDEpisode* episode){
                                                        episode.starred = NO;
                                                    });
                                                    PlaySoundFile(@"AffirmOut", NO);
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    [self addAdditionalButtonsToMultiSelectEditActionSheet:alert
                                       selectedIndexPathes:selectedIndexPathes
                                           completionBlock:^{
                                               STRONG_SELF
                                               self.alertController = nil;
                                           }];
    
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

- (void) _askUserForCellularDownloadIfNecessary:(void (^)(BOOL canDownload))completionHandler
{
    BOOL enabled3G = [USER_DEFAULTS boolForKey:EnableCachingOver3G];
    if (enabled3G || App.networkAccessTechnology == kICNetworkAccessTechnlogyWIFI) {
        completionHandler(YES);
        return;
    }
    
    
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Downloading over cellular has been disabled in 'General' settings.".ls
                                                                   message:@"Do you still want to download the content of this episode right now?".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Download".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    completionHandler(YES);
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    completionHandler(NO);
                                                } afterDelay:0.3];
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

- (void) downloadSelection:(id)sender
{
    NSArray* selectedIndexPathes = [self.tableView indexPathsForSelectedRows];
    CacheManager* cman = [CacheManager sharedCacheManager];
    
    [self _askUserForCellularDownloadIfNecessary:^(BOOL canDownload) {
        if (canDownload) {
            for(NSIndexPath* selectedIndexPath in selectedIndexPathes) {
                CDEpisode* episode = [self.episodes objectAtIndex:selectedIndexPath.row];
                [cman cacheEpisode:episode overwriteCellularLock:YES];
            }
            [self setEditing:NO animated:YES];
            [self.tableView reloadRowsAtIndexPaths:selectedIndexPathes withRowAnimation:UITableViewRowAnimationFade];
        }
    }];
}

- (void) cancelCachingAction:(id)sender
{
	[[CacheManager sharedCacheManager] cancelCaching];
}

- (void) cancelCachingEpisode:(UIButton*)button
{
	NSInteger index = button.tag - 2000;
	CDEpisode* episode = [self.episodes objectAtIndex:index];
	
	[[CacheManager sharedCacheManager] cancelCachingEpisode:episode disableAutoDownload:YES];
}

- (void) archiveEpisodesAtRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!indexPath) {
        return;
    }
    
    NSArray* lEpisodes = self.episodes;
    
    // swiping on an empty cell not allowed
    if (indexPath.row >= [lEpisodes count]) {
        return;
    }
    
    CDEpisode* episode = (CDEpisode*)[lEpisodes objectAtIndex:indexPath.row];
    
    self.userAction = YES;
    [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
    [DMANAGER setEpisode:episode archived:YES];
    [self updateEpisodes];
    
    [self.tableView beginUpdates];
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationRight];
    [self.tableView endUpdates];
    
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
    self.userAction = NO;
}

- (void) selectAllAction:(id)sender
{
    NSInteger rowCount = [self.tableView numberOfRowsInSection:0];
    NSArray* selectedRows = [self.tableView indexPathsForSelectedRows];
    
    if ([selectedRows count] < rowCount)
    {
        NSInteger row = 0;
        for (row=0; row<rowCount; row++) {
            NSIndexPath* indexPath = [NSIndexPath indexPathForRow:row inSection:0];
            [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
        }
    }
    else
    {
        for(NSIndexPath* indexPath in selectedRows)
        {
            [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        }
    }
    
    [self _updateCacheButtonStateWithSelectedIndexPathes:selectedRows];
}

#pragma mark -
#pragma mark Content Selection


- (void) setEditingStyle:(EpisodesTableViewEditingStyle)editingStyle
{
    if (_editingStyle != editingStyle) {
        _editingStyle = editingStyle;
        
        switch (_editingStyle) {
            case EpisodesTableViewEditingStyleNormal:
                self.tableView.allowsMultipleSelectionDuringEditing = NO;
                break;
            case EpisodesTableViewEditingStyleDownload:
                self.tableView.allowsMultipleSelectionDuringEditing = YES;
                break;
            default:
                break;
        }
    }
}

- (void) setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];

    if (!editing) {
        self.editingStyle = EpisodesTableViewEditingStyleNormal;
    }

    [self _updateToolbarItemsAnimated:animated];
}


#pragma mark - TableView Datasource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    // Return the number of rows in the section.
	if (section == 0) {
		return [self.episodes count];
	}
    
	return 0;
}

- (void) _setCell:(EpisodesTableViewCell*)cell imageForFeed:(CDFeed*)feed episode:(CDEpisode*)episode
{
    if ([self showsImage])
    {
        cell.iconView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];
        
        NSURL* imageURL = (episode.imageURL) ? episode.imageURL : feed.imageURL;
        if (!imageURL) {
            return;
        }
        
        
        ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
        UIImage* cachedImage = [iman localImageForImageURL:imageURL size:56 grayscale:(episode.consumed)];
        if (cachedImage) {
            cell.iconView.image = cachedImage;
        }
    }
    else {
        cell.iconView.image = nil;
    }
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString* EpisodesCellIdentifier = @"EpisodesContentCell";
    
    EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[self.tableView dequeueReusableCellWithIdentifier:EpisodesCellIdentifier];
    if (!cell) {
        cell = [[EpisodesTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:EpisodesCellIdentifier];
    }
    [cell.playAccessoryButton addTarget:self action:@selector(playComboButtonAction:) forControlEvents:UIControlEventTouchUpInside];
    cell.backgroundColor = self.tableView.backgroundColor;
    cell.tintColor = self.view.tintColor;
    
    CDEpisode* episode = [self.episodes objectAtIndex:indexPath.row];
    
    cell.objectValue = episode;
    cell.playAccessoryButton.userInfo = episode;
    cell.usesNativeSwipeActions = YES;
    cell.primaryActionMenuButton.hidden = YES;
    if (@available(iOS 14.0, *)) {
        cell.primaryActionMenuButton.menu = nil;
        if ([USER_DEFAULTS integerForKey:TapOnEpisodeAction] == ICTapOnEpisodeActionOpenContextMenu) {
            cell.primaryActionMenuButton.menu = [self _contextMenuForIndexPath:indexPath];
            cell.primaryActionMenuButton.hidden = NO;
        }
    }
    
    if (self.showsImage) {
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
    }
    
    return cell;
}


- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return 72.f;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CDEpisode* episode = [self.episodes objectAtIndex:indexPath.row];

    CGSize imageSize = (self.showsImage) ? CGSizeMake(56, 56) : CGSizeZero;

    CGFloat h = [EpisodesTableViewCell proposedHeightWithObjectValue:episode tableSize:self.tableView.bounds.size imageSize:imageSize embedded:NO editing:self.editing];

    return h;
}

#pragma mark - Table view delegate


- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}


- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self _updateCacheButtonStateWithSelectedIndexPathes:[self.tableView indexPathsForSelectedRows]];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.episodes count] == 0) {
        return;
    }
    
    if (self.editingStyle == EpisodesTableViewEditingStyleDownload) {
        [self _updateCacheButtonStateWithSelectedIndexPathes:[self.tableView indexPathsForSelectedRows]];
        return;
    }
    
    
    CDEpisode* episode = (CDEpisode*)[self.episodes objectAtIndex:indexPath.row];

    NSInteger tapAction = [USER_DEFAULTS integerForKey:TapOnEpisodeAction];
    if (tapAction == ICTapOnEpisodeActionShowNotes) {
        [self _pushShowNotesOfEpisode:episode animated:YES inAppearanceTransition:NO];
    } else if (tapAction == ICTapOnEpisodeActionOpenContextMenu) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    } else {
        BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
        PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:!alreadyPlaying];
        [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
    }
}

//-(void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
//{
//    if ([cell isKindOfClass:[EpisodesTableViewCell class]]) {
//        EpisodesTableViewCell *customCell = (EpisodesTableViewCell *)cell;
//        [customCell startProgressUpdate];
//    }
//}
//
//- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
//{
//    if ([cell isKindOfClass:[EpisodesTableViewCell class]]) {
//        EpisodesTableViewCell *customCell = (EpisodesTableViewCell *)cell;
//        [customCell stopProgressUpdate];
//    }
//}


#pragma mark -

- (void) playComboButtonAction:(EpisodePlayComboButton*)button
{
    CDEpisode* episode = (CDEpisode*)button.userInfo;
    
    if (button.comboState == kEpisodePlayButtonComboStateFilling || button.comboState == kEpisodePlayButtonComboStateHolding)
    {
        CacheManager* cman = [CacheManager sharedCacheManager];
        [cman cancelCachingEpisode:episode disableAutoDownload:YES];
    }
    else
    {
        BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
        PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:!alreadyPlaying];
        [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
    }
}

- (void) _pushShowNotesOfEpisode:(CDEpisode*)episode animated:(BOOL)animated inAppearanceTransition:(BOOL)appearanceTransition
{
    UIBarButtonItem* a = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.navigationItem.backBarButtonItem = a;
    
    EpisodeViewController* controller = [EpisodeViewController episodeViewController];
    controller.episode = episode;
    controller.view.tintColor = ICTintColor;
    //controller.view.frame = controller.view.frame;
   
    [self.navigationController pushViewController:controller animated:YES];
}
@end


#pragma  mark -

@interface EpisodesContainerViewController ()
@property (nonatomic, strong) UIView* navigationExtensionView;
@end


@implementation EpisodesContainerViewController {
    BOOL _observing;
}


+ (instancetype) containerViewControllerWithTableViewController:(EpisodesTableViewController*)tableViewController
{
    EpisodesContainerViewController* controller = [[EpisodesContainerViewController alloc] initWithNibName:nil bundle:nil];
    controller.tableViewController = tableViewController;
    return controller;
}

- (void)dealloc
{
	[self _setObserving:NO];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) _setObserving:(BOOL)observing
{
    if (observing && !_observing)
    {
        __weak EpisodesContainerViewController* weakSelf = self;
        [self.tableViewController addTaskObserver:self forKeyPath:@"toolbarItems" task:^(id obj, NSDictionary *change) {
            UIToolbar* toolbar = weakSelf.navigationController.toolbar;
            if (weakSelf.view.window && toolbar && CGRectGetWidth(toolbar.bounds) > 0) {
                [weakSelf setToolbarItems:[weakSelf.tableViewController toolbarItems]];
            }
        }];

        _observing = YES;
    }
    else if (!observing && _observing)
    {
        [self.tableViewController removeTaskObserver:self forKeyPath:@"toolbarItems"];

        _observing = NO;
    }

}

- (void) viewDidLoad
{
    [super viewDidLoad];

    self.view.backgroundColor = ICBackgroundColor;

    UIBarButtonItem* a = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.navigationItem.backBarButtonItem = a;

    CGRect b = self.view.bounds;
    self.tableViewController.view.frame = b;

    self.tableViewController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    [self addChildViewController:self.tableViewController];
    [self.view addSubview:self.tableViewController.view];
    [self.tableViewController didMoveToParentViewController:self];

    self.navigationExtensionView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(b), 20+44+22)];
    self.navigationExtensionView.backgroundColor = ICTransparentBackdropColor;
    [self.view addSubview:self.navigationExtensionView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_updateContainerAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)_updateContainerAppearance {
    self.view.backgroundColor = ICBackgroundColor;
    self.navigationExtensionView.backgroundColor = ICTransparentBackdropColor;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self _setObserving:YES];
    [self _updateContainerAppearance];
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    UIToolbar* toolbar = self.navigationController.toolbar;
    if (self.view.window && toolbar && CGRectGetWidth(toolbar.bounds) > 0) {
        [self setToolbarItems:[self.tableViewController toolbarItems] animated:NO];
    }
    [self _setObserving:NO];
}


@end
