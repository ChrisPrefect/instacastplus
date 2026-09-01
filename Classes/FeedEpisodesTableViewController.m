//
//  EpisodesTableViewController.m
//  Instacast
//
//  Created by Martin Hering on 29.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <MobileCoreServices/MobileCoreServices.h>

#import "FeedEpisodesTableViewController.h"
#import "FeedViewController.h"

#import "ICShareItem.h"
#import "SubscriptionManager.h"
#import "EpisodeViewController.h"
#import "VDModalInfo.h"
#import "PlaybackViewController.h"
#import "AnimatingLabel.h"
#import "PlaybackViewController.h"
#import "UIManager.h"

#import "EpisodesTableViewCell.h"
#import "ToolbarLabelsViewController.h"
#import "CDModel.h"
#import "NumberAccessoryView.h"
#import "ICFeedHeaderViewController.h"
#import "ImageFunctions.h"
#import "FeedSettingsViewController.h"
#import "CDFeed+Helper.h"
#import "ICFTSController.h"
#import "InstacastAppDelegate.h"
#import "ICRefreshControl.h"

typedef NS_ENUM(NSUInteger, ICFeedEpisodeArchiveBehavior) {
    ICFeedEpisodeArchiveBehaviorArchiveOnly,
    ICFeedEpisodeArchiveBehaviorArchiveAndConsume,
};

@interface FeedEpisodesTableViewController() <UIGestureRecognizerDelegate, NSFetchedResultsControllerDelegate, UIScrollViewDelegate>
@property (nonatomic, strong) NSFetchedResultsController* fetchController;
@property (nonatomic, strong) ICFeedHeaderViewController* headerViewController;
@property (nonatomic, strong) UIStackView* headerButtonStack;
@property (nonatomic, strong) UIView* headerToolbarSeparatorView;
@property (nonatomic, weak) UIButton* shareButton;
@property (nonatomic, weak) UIButton* filterButton;
@property (nonatomic, strong) VDModalInfo* modalInfo;
@property (nonatomic, strong) UIView* tableHeaderView;
@property (nonatomic, strong) UILabel* navTitleLabel;
@property (nonatomic, strong) UIView* navTitleContainerView;
@end

@implementation FeedEpisodesTableViewController {
    NSMutableSet* _selectionPreservingIndexPathes;
    BOOL _didRestoreScrollPosition;
    BOOL isDownloadedFilter;
    NSInteger _searchGeneration;
}

+ (FeedEpisodesTableViewController*) episodesControllerWithFeed:(CDFeed*)feed
{
	FeedEpisodesTableViewController* controller = [[self alloc] initWithStyle:UITableViewStylePlain];
    controller.feed = feed;
	return controller;
}

- (CGFloat) _navigationTitleViewWidth
{
    CGFloat referenceWidth = CGRectGetWidth(self.navigationController.navigationBar.bounds);
    if (referenceWidth <= 0) {
        referenceWidth = CGRectGetWidth(self.view.bounds);
    }
    if (referenceWidth <= 0) {
        referenceWidth = CGRectGetWidth([UIScreen mainScreen].bounds);
    }

    // Keep explicit space for left/right bar button items so title wraps
    // consistently and never reflows after the controller is shown.
    CGFloat width = referenceWidth - 120.0f;
    return MAX(140.0f, MIN(320.0f, width));
}

- (void) _setupNavigationTitleViewWithText:(NSString*)titleText
{
    CGFloat titleWidth = [self _navigationTitleViewWidth];

    UIView* navTitleContainerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, titleWidth, 44)];
    navTitleContainerView.userInteractionEnabled = NO;

    UILabel* navTitleLabel = [[UILabel alloc] initWithFrame:navTitleContainerView.bounds];
    navTitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    navTitleLabel.text = titleText;
    navTitleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(18.0f)];
    navTitleLabel.textColor = ICTextColor;
    navTitleLabel.backgroundColor = [UIColor clearColor];
    navTitleLabel.textAlignment = NSTextAlignmentCenter;
    navTitleLabel.numberOfLines = 2;
    navTitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    navTitleLabel.adjustsFontSizeToFitWidth = NO;
    [navTitleContainerView addSubview:navTitleLabel];

    self.navigationItem.titleView = navTitleContainerView;
    self.navTitleContainerView = navTitleContainerView;
    self.navTitleLabel = navTitleLabel;
}

- (void) _setNavigationTitleText:(NSString*)titleText
{
    self.navTitleLabel.text = titleText;
}


- (void) addAdditionalButtonsToLongPressActionSheet:(UIAlertController*)sheet rowIndexPath:(NSIndexPath*)indexPath completionBlock:(void (^)(void))completionBlock
{
    CDEpisode* episode = [[self _episodesAtIndexPaths:@[indexPath]] firstObject];
    if (!episode) {
        return;
    }
    WEAK_SELF
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
                                                STRONG_SELF
        [self showDeleteConfirmPopUpForEpisodes:@[episode] behavior:ICFeedEpisodeArchiveBehaviorArchiveAndConsume];
                                                completionBlock();
                                            }]];
}

- (NSArray<UIMenuElement*>*) additionalContextMenuActionsForIndexPath:(NSIndexPath*)indexPath
{
    CDEpisode* episode = [[self _episodesAtIndexPaths:@[indexPath]] firstObject];
    if (!episode) {
        return @[];
    }
    WEAK_SELF
    UIAction* deleteAction = [UIAction actionWithTitle:@"Delete".ls
                                                 image:[UIImage systemImageNamed:@"trash"]
                                            identifier:nil
                                               handler:^(UIAction *action) {
                                                   STRONG_SELF
                                                   [self showDeleteConfirmPopUpForEpisodes:@[episode] behavior:ICFeedEpisodeArchiveBehaviorArchiveAndConsume];
                                               }];
    deleteAction.attributes = UIMenuElementAttributesDestructive;
    return @[deleteAction];
}

- (NSArray<CDEpisode*>*)_episodesAtIndexPaths:(NSArray<NSIndexPath*>*)indexPaths
{
    NSMutableArray<CDEpisode*>* episodes = [NSMutableArray arrayWithCapacity:indexPaths.count];
    NSArray<CDEpisode*>* currentEpisodes = self.episodes;
    for (NSIndexPath* indexPath in indexPaths) {
        if (indexPath.section == 0 && indexPath.row < currentEpisodes.count) {
            [episodes addObject:currentEpisodes[indexPath.row]];
        }
    }
    return episodes;
}

- (void)showDeleteConfirmPopUpForEpisodes:(NSArray<CDEpisode*>*)episodes behavior:(ICFeedEpisodeArchiveBehavior)behavior
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Are you sure you want to delete?".ls message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Yes".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
        STRONG_SELF
        for (CDEpisode* episode in episodes) {
            if (!episode.isDeleted && episode.managedObjectContext) {
                [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
                if (behavior == ICFeedEpisodeArchiveBehaviorArchiveAndConsume) {
                    [DMANAGER setEpisode:episode archived:YES];
                } else {
                    episode.archived = YES;
                }
            }
        }
        if (behavior == ICFeedEpisodeArchiveBehaviorArchiveOnly) {
            [DMANAGER save];
        }
        [self updateEpisodes];
        [self _updateToolbarItemsAnimated:NO];
        [self _updateToolbarLabels];
        self.alertController = nil;
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
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

- (void) addAdditionalButtonsToMultiSelectEditActionSheet:(UIAlertController*)sheet selectedIndexPathes:(NSArray*)selectedIndexPathes completionBlock:(void (^)(void))completionBlock
{
    NSArray<CDEpisode*>* selectedEpisodes = [self _episodesAtIndexPaths:selectedIndexPathes];
    if (selectedEpisodes.count == 0) {
        return;
    }
    WEAK_SELF
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
        [self showDeleteConfirmPopUpForEpisodes:selectedEpisodes behavior:ICFeedEpisodeArchiveBehaviorArchiveOnly];
        completionBlock();
                                            }]];
}


#pragma mark -
#pragma mark View lifecycle

- (void) updateEpisodes
{
    self.episodes = [self.fetchController fetchedObjects] ?: @[];
}

- (void)_updateFilterEmptyState
{
    NSString* currentFilter = [[NSUserDefaults standardUserDefaults] stringForKey:self.feed.uid] ?: @"All";
    BOOL showsFilteredEmptyState = self.searchTerm.length == 0 && ![currentFilter isEqualToString:@"All"] && self.episodes.count == 0;
    if (!showsFilteredEmptyState) {
        self.tableView.backgroundView = nil;
        return;
    }

    UILabel* emptyLabel = [[UILabel alloc] initWithFrame:self.tableView.bounds];
    emptyLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    emptyLabel.backgroundColor = [UIColor clearColor];
    emptyLabel.font = [UIFont systemFontOfSize:ICFontSize(15.0f)];
    emptyLabel.textColor = ICMutedTextColor;
    emptyLabel.textAlignment = NSTextAlignmentCenter;
    emptyLabel.text = @"Keine Folgen mit diesem Filter".ls;
    self.tableView.backgroundView = emptyLabel;
}

- (BOOL) _removeEpisodeFromDisplayedListIfNeededAfterMutation:(CDEpisode*)episode atIndexPath:(NSIndexPath*)indexPath
{
    NSPredicate* predicate = self.fetchController.fetchRequest.predicate;
    if (!predicate || [predicate evaluateWithObject:episode]) {
        return NO;
    }

    if (!indexPath || indexPath.section != 0 || indexPath.row >= [self.episodes count]) {
        return NO;
    }

    CDEpisode* displayedEpisode = self.episodes[indexPath.row];
    BOOL isSameEpisode = (displayedEpisode == episode || [displayedEpisode isEqual:episode]);
    if (!isSameEpisode && episode.objectHash.length > 0) {
        isSameEpisode = [displayedEpisode.objectHash isEqualToString:episode.objectHash];
    }
    if (!isSameEpisode) {
        return NO;
    }

    NSMutableArray* episodes = [self.episodes mutableCopy];
    [episodes removeObjectAtIndex:indexPath.row];
    self.episodes = [episodes copy];
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [self _updateFilterEmptyState];
    return YES;
}

- (BOOL) showsImage
{
    return NO;
}

- (void) _updateFetchControllerWithEpisodeObjectHashes:(NSSet*)episodeObjectHashes
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    if ([self.searchTerm length] > 0)
    {
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == %@ && objectHash IN %@", self.feed, @NO, episodeObjectHashes];
        
    } else {
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == %@", self.feed, @NO];
    }
    
    fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
    
    self.fetchController = [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    
    [self updateEpisodes];
}

- (void) _updateFetchController
{
    NSString* searchTerm = [self.searchTerm copy];
    NSInteger searchGeneration = ++_searchGeneration;
    if ([searchTerm length] > 0)
    {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSSet* episodeObjectHashes = [DMANAGER.ftsController episodeObjectHashesForSearchTerm:searchTerm];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (searchGeneration != self->_searchGeneration || ![self.searchTerm isEqualToString:searchTerm]) {
                    return;
                }

                [self _updateFetchControllerWithEpisodeObjectHashes:episodeObjectHashes];
                [self.tableView reloadData];
                [self _updateToolbarItemsAnimated:NO];
                [self _updateToolbarLabels];
            });
        });
        return;
    }

    [self _updateFetchControllerWithEpisodeObjectHashes:nil];
}

#pragma mark - FetchedResultsController delegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller
{
    if (self.userAction) {
        return;
    }
    [self.tableView beginUpdates];
    _selectionPreservingIndexPathes = [[NSMutableSet alloc] init];
}

- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath
{
    if (self.userAction) {
        return;
    }
    
    NSArray* indexPathes = [self.tableView indexPathsForSelectedRows];
    BOOL indexPathWasSelected = [indexPathes containsObject:indexPath];
    
    
    UITableView *tableView = self.tableView;
    
    switch(type) {
            
        case NSFetchedResultsChangeInsert:
            [tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeDelete:
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
            
        case NSFetchedResultsChangeUpdate:
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            if (indexPathWasSelected) {
                [_selectionPreservingIndexPathes addObject:indexPath];
            }
            break;
            
        case NSFetchedResultsChangeMove:
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
            [tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
            break;
    }
}

- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
    if (self.userAction) {
        return;
    }
    [self updateEpisodes];
    [self.tableView endUpdates];
    [self _updateToolbarLabels];
    [self _updateFilterEmptyState];
    
    for (NSIndexPath* indexPath in _selectionPreservingIndexPathes) {
        [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
    
    _selectionPreservingIndexPathes = nil;
}

#pragma mark -

- (void)viewDidLoad
{
    [super viewDidLoad];
    // UIRectEdgeNone prevents glass artifacts at top (nav bar) but causes
    // an opaque bar artifact at the bottom on iOS 26 floating toolbars.
    // UIRectEdgeBottom: extend under bottom bar (toolbar) but NOT under top bar (nav bar).
    self.edgesForExtendedLayout = UIRectEdgeBottom;

    if (@available(iOS 26.0, *)) {
        self.tableView.bottomEdgeEffect.hidden = YES;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
    {
        NSString* titleText = ([self.searchTerm length] > 0) ? [NSString stringWithFormat:@"'%@'", self.searchTerm].ls : self.feed.title;
        // Only set titleView, NOT self.title — setting both causes a visible
        // jump during push animation (system animates self.title first, then
        // switches to titleView).
        [self _setupNavigationTitleViewWithText:titleText];
    }

    WEAK_SELF
    self.editingStyle = EpisodesTableViewEditingStyleNormal;
    
    {
        CGFloat w = CGRectGetWidth(self.view.bounds);
        self.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 93+55)];
        self.tableHeaderView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        
        self.headerViewController = [ICFeedHeaderViewController viewController];
        self.headerViewController.view.frame = CGRectMake(0, 0, w, 93);
        // Title is shown in the navigation bar, not in the header
        self.headerViewController.titleLabel.text = self.feed.author;
        // Show feed subtitle below author if available and different from title
        NSString* feedSubtitle = self.feed.subtitle;
        if (feedSubtitle.length > 0 && ![feedSubtitle isEqualToString:self.feed.title]) {
            self.headerViewController.subtitleLabel.text = feedSubtitle;
        } else {
            self.headerViewController.subtitleLabel.text = nil;
        }
        
        ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
        [iman imageForURL:self.feed.imageURL size:72 grayscale:NO sender:self completion:^(UIImage *image) {
            STRONG_SELF
            if (image) {
                self.headerViewController.imageView.image = image;
            }
        }];
        
        [self addChildViewController:self.headerViewController];
        [self.tableHeaderView addSubview:self.headerViewController.view];
        [self.headerViewController didMoveToParentViewController:self];

        self.headerViewController.action = ^(void) {
            STRONG_SELF
            
            UIBarButtonItem* a = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
            self.navigationItem.backBarButtonItem = a;
            
            FeedViewController* feedInfoController = [FeedViewController feedViewController];
            feedInfoController.feed = self.feed;
            [self.navigationController pushViewController:feedInfoController animated:YES];
        };
        
        UIView* headerToolbarSeparatorView = [[UIView alloc] initWithFrame:CGRectMake(0, 93, w, 0.5)];
        [self.tableHeaderView addSubview:headerToolbarSeparatorView];
        self.headerToolbarSeparatorView = headerToolbarSeparatorView;

        // Flache Buttons in UIStackView statt UIToolbar
        UIStackView* buttonStack = [[UIStackView alloc] initWithFrame:CGRectMake(0, 98, w, 40)];
        buttonStack.axis = UILayoutConstraintAxisHorizontal;
        buttonStack.distribution = UIStackViewDistributionEqualSpacing;
        buttonStack.alignment = UIStackViewAlignmentCenter;
        buttonStack.layoutMargins = UIEdgeInsetsMake(0, 40, 0, 40);
        buttonStack.layoutMarginsRelativeArrangement = YES;
        buttonStack.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        UIButton* reloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [reloadButton setImage:[UIImage imageNamed:@"refreshd_ic"] forState:UIControlStateNormal];
        [reloadButton addTarget:self action:@selector(reload:) forControlEvents:UIControlEventTouchUpInside];

        UIButton* shareButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [shareButton setImage:[UIImage imageNamed:@"sharedd_ic"] forState:UIControlStateNormal];
        [shareButton addTarget:self action:@selector(share:) forControlEvents:UIControlEventTouchUpInside];
        self.shareButton = shareButton;

        UIButton* filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [filterButton setTitle:@"All".ls forState:UIControlStateNormal];
        filterButton.titleLabel.font = [UIFont systemFontOfSize:ICFontSize(17)];
        filterButton.menu = [self _buildFilterMenu];
        filterButton.showsMenuAsPrimaryAction = YES;
        self.filterButton = filterButton;

        [buttonStack addArrangedSubview:reloadButton];
        [buttonStack addArrangedSubview:shareButton];
        [buttonStack addArrangedSubview:filterButton];

        [self.tableHeaderView addSubview:buttonStack];
        self.headerButtonStack = buttonStack;
    }
    
    //[self updateEpisodes];
    [self _updateToolbarItemsAnimated:NO];

    ICRefreshControl* refreshControl = [[ICRefreshControl alloc] init];
    refreshControl.pulldownText = @"Pull to refresh…".ls;
    refreshControl.refreshText = @"Looking for new episodes…".ls;
    refreshControl.idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDateForFeed:self.feed];
    [refreshControl addTarget:self action:@selector(pullToRefresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;

    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
    [sman addTaskObserver:self forKeyPath:@"formattedLastRefreshDate" task:^(id obj, NSDictionary *change) {
        STRONG_SELF;
        ((ICRefreshControl*)self.refreshControl).idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDateForFeed:self.feed];
    }];

    [sman addTaskObserver:self forKeyPath:@"refreshStatusText" task:^(id obj, NSDictionary *change) {
        STRONG_SELF;
        SubscriptionManager* sm = [SubscriptionManager sharedSubscriptionManager];
        if (sm.refreshing) {
            ((ICRefreshControl*)self.refreshControl).refreshText = sm.refreshStatusText;
        }
    }];

    [[CacheManager sharedCacheManager] addTaskObserver:self forKeyPath:@"cachedEpisodes" task:^(__unused id object, __unused NSDictionary* change) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FeedEpisodesTableViewController* strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->isDownloadedFilter || !strongSelf.viewIfLoaded.window) {
                return;
            }
            [strongSelf downloadedUpdateEpisodes];
        });
    }];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(subscriptionManagerDidStartRefreshingFeedsNotification:)
                                                 name:SubscriptionManagerDidStartRefreshingFeedsNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(subscriptionManagerDidFinishRefreshingFeedsNotification:)
                                                 name:SubscriptionManagerDidFinishRefreshingFeedsNotification
                                               object:nil];
}

- (void) pullToRefresh:(id)sender
{
    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
    [sman refreshFeeds:@[self.feed] etagHandling:YES completion:^(BOOL success, NSArray* newEpisodes, NSError* error) {
        if ([newEpisodes count] > 0) {
            PlaySoundFile(@"NewEpisodes",NO);
        }
    }];
}

- (void) subscriptionManagerDidStartRefreshingFeedsNotification:(NSNotification*)notification
{
    if (self.isViewLoaded && self.view.window) {
        [self.refreshControl beginRefreshing];
    }
}

- (void) _presentRefreshFailureAlert:(NSArray<NSString*>*)failures
{
    if (![USER_DEFAULTS boolForKey:EnableRefreshFailureNotification]) {
        return;
    }
    if (failures.count == 0) {
        return;
    }
    if (!self.isViewLoaded || !self.view.window || self.presentedViewController) {
        return;
    }

    UIFont* regularFont = [UIFont systemFontOfSize:ICFontSize(13.0f)];
    UIFont* boldFont = [UIFont boldSystemFontOfSize:ICFontSize(13.0f)];
    NSMutableAttributedString* message = [[NSMutableAttributedString alloc] init];

    [failures enumerateObjectsUsingBlock:^(NSString* line, NSUInteger idx, BOOL *stop) {
        NSRange separatorRange = [line rangeOfString:@" - "];
        NSString* title = (separatorRange.location != NSNotFound) ? [line substringToIndex:separatorRange.location] : line;
        NSString* reason = (separatorRange.location != NSNotFound) ? [line substringFromIndex:separatorRange.location] : @"";

        [message appendAttributedString:[[NSAttributedString alloc] initWithString:title attributes:@{ NSFontAttributeName : boldFont }]];
        [message appendAttributedString:[[NSAttributedString alloc] initWithString:reason attributes:@{ NSFontAttributeName : regularFont }]];
        if (idx + 1 < failures.count) {
            [message appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n\n" attributes:@{ NSFontAttributeName : regularFont }]];
        }
    }];

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Some podcasts could not be updated".ls
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert setValue:message forKey:@"attributedMessage"];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void) subscriptionManagerDidFinishRefreshingFeedsNotification:(NSNotification*)notification
{
    SubscriptionManager* sm = [SubscriptionManager sharedSubscriptionManager];
    [self _presentRefreshFailureAlert:sm.lastRefreshFailureMessages];

    ((ICRefreshControl*)self.refreshControl).refreshText = @"Looking for new episodes…".ls;
    [self.refreshControl endRefreshing];
}

- (void) _updateToolbarLabels
{
    NSInteger numEpisodes = [self.episodes count];
    
    if (numEpisodes == 0) {
        self.toolbarLabelsViewController.mainText = @"No Episodes".ls;
        self.toolbarLabelsViewController.auxiliaryText = @"";
    }
    else
    {
        self.toolbarLabelsViewController.mainText = (numEpisodes == 1) ? @"1 Episode".ls : [NSString stringWithFormat:@"%d Episodes".ls, numEpisodes];
        self.toolbarLabelsViewController.auxiliaryText = @"";
    }

    [self.toolbarLabelsViewController layout];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
    _didRestoreScrollPosition = NO;

    CGFloat w = CGRectGetWidth(self.view.bounds);
    self.headerButtonStack.frame = CGRectMake(0, 98, w, 40);
    
    
    if ([self.searchTerm length] > 0)
    {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Close"] style:UIBarButtonItemStylePlain target:self action:@selector(toolbarCloseButtonAction:)];
    }
    else
    {
        // Settings button in navigation bar
        UIImage* gearImage = [UIImage systemImageNamed:@"gearshape"];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:gearImage style:UIBarButtonItemStylePlain target:self action:@selector(settings:)];
    }
    
    if ([[NSUserDefaults standardUserDefaults] objectForKey:_feed.uid] != nil){
        NSString* filterOptionStr = [[NSUserDefaults standardUserDefaults] valueForKey:_feed.uid];
        if ([filterOptionStr  isEqual: @"All"])
        {
            self->isDownloadedFilter = false;
            [self _filterAllEpisode];
            [self.filterButton setTitle:@"All".ls forState:UIControlStateNormal];
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Unplayed"])
        {
            self->isDownloadedFilter = false;
            [self _filterUnlistenedEpisode];
            [self.filterButton setTitle:@"Unplayed".ls forState:UIControlStateNormal];
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Unfinished"])
        {
            self->isDownloadedFilter = false;
            [self _filterUnfinishedEpisode];
            [self.filterButton setTitle:@"Unfinished".ls forState:UIControlStateNormal];
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Downloaded"])
        {
            self->isDownloadedFilter = true;
            [self _filterDownloadedEpisode];
            [self.filterButton setTitle:@"Downloaded".ls forState:UIControlStateNormal];
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Favorites"])
        {
            self->isDownloadedFilter = false;
            [self _filterFavoriteEpisode];
            [self.filterButton setTitle:@"Favorites".ls forState:UIControlStateNormal];
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"UnplayedAndStarted"])
        {
            self->isDownloadedFilter = false;
            [self _filterUnplayedAndStartedEpisode];
            [self.filterButton setTitle:@"Unplayed & Started".ls forState:UIControlStateNormal];
            [self reloadDataWithFilter:YES];
        }
        else
        {
            self->isDownloadedFilter = false;
            [self _filterAllEpisode];
            [self.filterButton setTitle:@"All".ls forState:UIControlStateNormal];
            [self reloadDataWithFilter:YES];
        }
    }
    else
    {
        self->isDownloadedFilter = false;
        [self _filterAllEpisode];
        [self.filterButton setTitle:@"All".ls forState:UIControlStateNormal];
        [self reloadDataWithFilter:YES];
    }

    // Sync refresh control state
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([SubscriptionManager sharedSubscriptionManager].refreshing && !self.refreshControl.refreshing) {
            [self.refreshControl beginRefreshing];
        }
        else if (![SubscriptionManager sharedSubscriptionManager].refreshing && self.refreshControl.refreshing) {
            [self.refreshControl endRefreshing];
        }
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self _updateToolbarItemsAnimated:NO];
    [self reloadDataAndPreserveSelection];
    [self _restoreScrollPositionIfNeeded];
}

- (void) reloadDataWithFilter:(BOOL)isScrolled
{
    [self _updateToolbarLabels];
    [self _updateFilterEmptyState];

    // Nur updaten wenn View im Window ist
    if (self.view.window) {
        [self _updateToolbarItemsAnimated:NO];
        [self reloadDataAndPreserveSelection];
    }

    self.tableView.tableHeaderView = ([self.searchTerm length] == 0) ? self.tableHeaderView : nil;
    self.headerButtonStack.frame = CGRectMake(0, 98, CGRectGetWidth(self.tableHeaderView.frame), 40);

    if (isScrolled)
    {
        [self _restoreScrollPositionIfNeeded];
    }
}

- (void) reloadData
{
    [self _updateFetchController];
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
    [self _updateFilterEmptyState];
    
    [self reloadDataAndPreserveSelection];
    self.tableView.tableHeaderView = ([self.searchTerm length] == 0) ? self.tableHeaderView : nil;
    self.headerButtonStack.frame = CGRectMake(0, 98, CGRectGetWidth(self.tableHeaderView.frame), 40);

    [self _restoreScrollPositionIfNeeded];
}


- (NSString*) _scrollPersistenceKey
{
    NSString* feedKey = self.feed.uid;
    if ([feedKey length] == 0) {
        feedKey = [self.feed.sourceURL absoluteString];
    }
    if ([feedKey length] == 0) {
        return @"feedEpisodes.unknown";
    }
    return [NSString stringWithFormat:@"feedEpisodes.%@", feedKey];
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

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self _storeScrollPosition];
}

- (void) updateAppearance
{
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableHeaderView.backgroundColor = ICBackgroundColor;
    self.headerToolbarSeparatorView.backgroundColor = ICTableSeparatorColor;
    self.headerButtonStack.tintColor = ICTintColor;
    self.navTitleLabel.textColor = ICTextColor;
    [self _updateFilterEmptyState];
    if (self.tableView.window) {
        [self.tableView reloadData];
    }
}

- (void) toolbarCloseButtonAction:(id)sender
{
    self.navigationItem.rightBarButtonItem = nil;
    self.searchTerm = nil;
    [self _setNavigationTitleText:self.feed.title];
    [self reloadData];
}

- (void) playerCloseButtonAction:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:NULL];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
    [sman removeTaskObserver:self forKeyPath:@"formattedLastRefreshDate"];
    [sman removeTaskObserver:self forKeyPath:@"refreshStatusText"];
    [[CacheManager sharedCacheManager] removeTaskObserver:self forKeyPath:@"cachedEpisodes"];
}

#pragma mark -

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[super tableView:tableView cellForRowAtIndexPath:indexPath];
    cell.topSeparator = (indexPath.row == 0);
    return cell;
}
    
-(void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
//    if ([cell isKindOfClass:[EpisodesTableViewCell class]]) {
//        EpisodesTableViewCell *customCell = (EpisodesTableViewCell *)cell;
//        [customCell startProgressUpdate];
//    }
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
//    if ([cell isKindOfClass:[EpisodesTableViewCell class]]) {
//        EpisodesTableViewCell *customCell = (EpisodesTableViewCell *)cell;
//        [customCell stopProgressUpdate];
//    }
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

#pragma mark - Actions

- (void) editAction:(id)sender
{
    [self setEditing:!self.editing animated:YES];
}


- (CGFloat) mainSplitViewContentViewControllerFixedWidth
{
    return 320;
}

- (void) reload:(id)sender
{
    self.modalInfo = [VDModalInfo modalInfoWithProgressLabel:@"Reloading…".ls];
    [self.modalInfo show];
    
    __weak FeedEpisodesTableViewController* weakSelf = self;
    
    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
    [sman reloadContentOfFeed:self.feed recoverArchivedEpisodes:NO completion:^(BOOL success, NSArray* newEpisodes, NSError* error) {
        if (error) {
            [self presentError:error];
        }
        if ([newEpisodes count] > 0) {
            PlaySoundFile(@"NewEpisodes",NO);
        }
        [weakSelf updateEpisodes];
        [weakSelf.modalInfo close];
        weakSelf.modalInfo = nil;
    }];
}



- (void) settings:(id)sender
{
    FeedSettingsViewController* viewController = [FeedSettingsViewController feedSettingsViewControllerWithFeed:self.feed];
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:viewController];
    navController.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navController animated:YES completion:^{
        
    }];
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
    

    [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
    [DMANAGER setEpisode:episode archived:YES];
    //[DMANAGER markEpisode:episode asDownloaded:NO];
    [self updateEpisodes];
    
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Sharing

- (void) share:(id)sender
{
    NSURLComponents* shareComponents = [NSURLComponents componentsWithString:@"https://instacast.ch/share/podcast"];
    shareComponents.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:[self.feed.sourceURL absoluteString]]];
    NSURL* shareURL = shareComponents.URL;

    UIImage* feedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:self.feed.imageURL size:72 grayscale:NO];
    ICShareItem* shareItem = [ICShareItem itemWithURL:shareURL title:self.feed.title image:feedImage];
    UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[shareItem] applicationActivities:nil];
    if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
        shareController.popoverPresentationController.barButtonItem = sender;
    }
    [self presentViewController:shareController animated:YES completion:NULL];
}


- (UIMenu*) _buildFilterMenu
{
    WEAK_SELF
    NSString* currentFilter = [[NSUserDefaults standardUserDefaults] stringForKey:_feed.uid] ?: @"All";

    UIAction* allAction = [UIAction actionWithTitle:@"All".ls image:nil identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterAllEpisode];
        [self.filterButton setTitle:@"All".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"All" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.filterButton.menu = [self _buildFilterMenu];
    }];
    allAction.state = [currentFilter isEqualToString:@"All"] ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction* unplayedAction = [UIAction actionWithTitle:@"Unplayed".ls image:nil identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterUnlistenedEpisode];
        [self.filterButton setTitle:@"Unplayed".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Unplayed" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.filterButton.menu = [self _buildFilterMenu];
    }];
    unplayedAction.state = [currentFilter isEqualToString:@"Unplayed"] ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction* unfinishedAction = [UIAction actionWithTitle:@"Unfinished".ls image:nil identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterUnfinishedEpisode];
        [self.filterButton setTitle:@"Unfinished".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Unfinished" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.filterButton.menu = [self _buildFilterMenu];
    }];
    unfinishedAction.state = [currentFilter isEqualToString:@"Unfinished"] ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction* unplayedAndStartedAction = [UIAction actionWithTitle:@"Unplayed & Started".ls image:nil identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterUnplayedAndStartedEpisode];
        [self.filterButton setTitle:@"Unplayed & Started".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"UnplayedAndStarted" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.filterButton.menu = [self _buildFilterMenu];
    }];
    unplayedAndStartedAction.state = [currentFilter isEqualToString:@"UnplayedAndStarted"] ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction* downloadedAction = [UIAction actionWithTitle:@"Downloaded".ls image:nil identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = true;
        [self _filterDownloadedEpisode];
        [self.filterButton setTitle:@"Downloaded".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Downloaded" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.filterButton.menu = [self _buildFilterMenu];
    }];
    downloadedAction.state = [currentFilter isEqualToString:@"Downloaded"] ? UIMenuElementStateOn : UIMenuElementStateOff;

    UIAction* favoritesAction = [UIAction actionWithTitle:@"Favorites".ls image:nil identifier:nil handler:^(UIAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterFavoriteEpisode];
        [self.filterButton setTitle:@"Favorites".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Favorites" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.filterButton.menu = [self _buildFilterMenu];
    }];
    favoritesAction.state = [currentFilter isEqualToString:@"Favorites"] ? UIMenuElementStateOn : UIMenuElementStateOff;

    return [UIMenu menuWithTitle:@"" children:@[allAction, unplayedAction, unfinishedAction, unplayedAndStartedAction, downloadedAction, favoritesAction]];
}

- (void) filterActionLegacy:(id)sender
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"All".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterAllEpisode];
        [self.filterButton setTitle:@"All".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"All" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.alertController = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unplayed".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterUnlistenedEpisode];
        [self.filterButton setTitle:@"Unplayed".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Unplayed" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.alertController = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unfinished".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterUnfinishedEpisode];
        [self.filterButton setTitle:@"Unfinished".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Unfinished" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.alertController = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unplayed & Started".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterUnplayedAndStartedEpisode];
        [self.filterButton setTitle:@"Unplayed & Started".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"UnplayedAndStarted" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.alertController = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Downloaded".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = true;
        [self _filterDownloadedEpisode];
        [self.filterButton setTitle:@"Downloaded".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Downloaded" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.alertController = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Favorites".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        STRONG_SELF
        self->isDownloadedFilter = false;
        [self _filterFavoriteEpisode];
        [self.filterButton setTitle:@"Favorites".ls forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setValue:@"Favorites" forKey:self->_feed.uid];
        [self reloadDataWithFilter:NO];
        self.alertController = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        STRONG_SELF
        self.alertController = nil;
    }]];

    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    popPresenter.sourceView = self.filterButton;
    popPresenter.sourceRect = self.filterButton.bounds;
    popPresenter.permittedArrowDirections = UIPopoverArrowDirectionUp;
    if ([ICAppearanceManager sharedManager].nightSettingMode) {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.alertController = alert;
    [self presentAlertControllerAnimated:YES completion:NULL];
}

#pragma mark - Filter By Favorite
- (void) _filterFavoriteEpisode
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && starred == %d && archived == %@", self.feed, 1, @NO];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];
 
    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
        [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By Unlistened
- (void) _filterUnlistenedEpisode
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && consumed == %d && position <= %d && archived == %@", self.feed, 0, 0, @NO];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];
 
    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
        [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By All
- (void) _filterAllEpisode
{
    [self _updateFetchController];
    [self.tableView reloadData];
        [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By Unfinished/Started_Playing
- (void) _filterUnfinishedEpisode
{
    //[NSPredicate predicateWithFormat:@"feed == %@ AND consumed == %@ AND archived == %@", self, @NO, @NO] --Unplayed
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && position > %d && archived == %@", self.feed, 0, @NO];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];

    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
        [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By Unplayed & Started (not consumed)
- (void) _filterUnplayedAndStartedEpisode
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && consumed == %d && archived == %@", self.feed, 0, @NO];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];

    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
        [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By Downloaded
- (void) _filterDownloadedEpisode
{
   /* BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && downloaded == 1", self.feed];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    NSString* cacheName = [NSString stringWithFormat:@"_feed_episodes_downloaded_%@", self.feed.title];
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];
    
    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:cacheName];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];*/
    [self downloadedUpdateEpisodes];
}

- (void) downloadedUpdateEpisodes
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    NSSet<NSString*>* cachedHashes = [CacheManager sharedCacheManager].cachedEpisodeObjectHashes;
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == %@ && objectHash IN %@", self.feed, @NO, cachedHashes];
    fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];

    self.fetchController = [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
    NSError* fetchError = nil;
    if (![self.fetchController performFetch:&fetchError]) {
        ErrLog(@"Could not fetch downloaded feed episodes: %@", fetchError);
    }
    [self updateEpisodes];
    [self _updateFilterEmptyState];
    [self.tableView reloadData];
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

@end
