//
//  SubscriptionsTableViewController.m
//  Instacast
//
//  Created by Martin Hering on 28.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>

#import "SubscriptionsTableViewController.h"

#import "SubscriptionManager.h"
#import "SubscriptionTableViewCell.h"
#import "FeedEpisodesTableViewController.h"

#import "ICFeedURLScraper.h"
#import "AnimatingLabel.h"


#import "OptionsViewController.h"
#import "InstacastAppDelegate.h"
#import "ToolbarLabelsViewController.h"
#import "FeedSettingsViewController.h"
#import "CDModel.h"
#import "PortraitNavigationController.h"
#import "ICRefreshControl.h"
#import "ICSearchBar.h"
#import "ICFTSController.h"
#import "DirectorySearchViewController.h"
#import "InstacastAppDelegate.h"

@interface SubscriptionsTableViewController () <UIGestureRecognizerDelegate, NSFetchedResultsControllerDelegate, UISearchBarDelegate>
@property (nonatomic, strong) ToolbarLabelsViewController* toolbarLabelsViewController;
@property (nonatomic, strong) UIBarButtonItem* labelsItems;
@property (nonatomic, strong) UIBarButtonItem* addItem;
@property (nonatomic, strong) UIBarButtonItem* sortItem;
@property (nonatomic, strong) ICSearchBar* searchBar;
@property (nonatomic, strong) NSFetchedResultsController* fetchController;
@property (nonatomic, assign) BOOL tableViewIsUpdating;
@property (nonatomic, assign) BOOL needsFullReload;
@end

@implementation SubscriptionsTableViewController {
    struct {
        unsigned int observing:1;
        unsigned int defaultPushed:1;
        unsigned int userAction:1;
    } _flags;
    BOOL _didRestoreScrollPosition;
}

#pragma mark -
#pragma mark Initialization

+ (SubscriptionsTableViewController*) subscriptionsController
{
    return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (void) _setObserving:(BOOL)observing
{
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
    
    if (observing && _flags.observing == 0)
    {
        [nc addObserver:self selector:@selector(subscriptionManagerDidStartRefreshingFeedsNotification:) name:SubscriptionManagerDidStartRefreshingFeedsNotification object:nil];
        
        [nc addObserver:self selector:@selector(subscriptionManagerDidFinishRefreshingFeedsNotification:) name:SubscriptionManagerDidFinishRefreshingFeedsNotification object:nil];
        
        [sman addTaskObserver:self forKeyPath:@"formattedLastRefreshDate" task:^(id obj, NSDictionary *change) {
            ((ICRefreshControl*)self.refreshControl).idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDate];
        }];

        [sman addTaskObserver:self forKeyPath:@"refreshStatusText" task:^(id obj, NSDictionary *change) {
            SubscriptionManager* sm = [SubscriptionManager sharedSubscriptionManager];
            if (sm.refreshing) {
                ((ICRefreshControl*)self.refreshControl).refreshText = [sm refreshStatusTextWithPodcastCount];
            }
        }];

        [nc addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
        
        [nc addObserver:self selector:@selector(handleFeedListUpdateNotification:)
                   name:DatabaseManagerDidUpdateObservedFeedNotification
                 object:nil];
        [DMANAGER addTaskObserver:self forKeyPath:@"ftsIndexing" task:^(id obj, NSDictionary *change) {
            self.searchBar.showsActivity = DMANAGER.ftsIndexing;
        }];
        
        
        _flags.observing = 1;
    }
    else if (!observing && _flags.observing == 1)
    {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_performCoalescedReload) object:nil];
        [nc removeObserver:self];

        [sman removeTaskObserver:self forKeyPath:@"formattedLastRefreshDate"];
        [sman removeTaskObserver:self forKeyPath:@"refreshStatusText"];
        [DMANAGER removeTaskObserver:self forKeyPath:@"ftsIndexing"];

        _flags.observing = 0;
    }
}

- (void) subscriptionManagerDidStartRefreshingFeedsNotification:(NSNotification*)notification
{
    [self.refreshControl beginRefreshing];
}

- (void) _presentRefreshFailureAlert:(NSArray<NSString*>*)failures
{
    if (failures.count == 0) {
        return;
    }
    if (!self.isViewLoaded || !self.view.window || self.presentedViewController) {
        return;
    }

    UIFont* regularFont = [UIFont systemFontOfSize:13.0f];
    UIFont* boldFont = [UIFont boldSystemFontOfSize:13.0f];
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
    NSArray<NSString*>* failures = sm.lastRefreshFailureMessages;
    [self _presentRefreshFailureAlert:failures];

    NSString* failedFeedName = sm.lastRefreshFailedFeedName;
    if (failedFeedName.length > 0) {
        ((ICRefreshControl*)self.refreshControl).refreshText = failedFeedName;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ((ICRefreshControl*)self.refreshControl).refreshText = @"Looking for new episodes…".ls;
            [self.refreshControl endRefreshing];
        });
        return;
    }

    ((ICRefreshControl*)self.refreshControl).refreshText = @"Looking for new episodes…".ls;
    [self.refreshControl endRefreshing];
}

#pragma mark -
#pragma mark View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    if (@available(iOS 26.0, *)) {
        self.tableView.bottomEdgeEffect.hidden = YES;
    }

    self.title = @"Podcasts".ls;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(toggleEditMode:)];
    
    self.tableView.rowHeight = 57+10;
    self.tableView.separatorInset = UIEdgeInsetsZero;
    
    ICRefreshControl* refreshControl = [[ICRefreshControl alloc] init];
    refreshControl.pulldownText = @"Pull to refresh…".ls;
    refreshControl.refreshText = @"Looking for new episodes…".ls;
    refreshControl.idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDate];
    [refreshControl addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;
    
    
    ICSearchBar* searchBar = [[ICSearchBar alloc] initWithFrame:CGRectZero];
    searchBar.backgroundImage = [[UIImage alloc] init];
    searchBar.scopeBarBackgroundImage = [[UIImage alloc] init];
    
    searchBar.delegate = self;
    searchBar.placeholder = @"Search".ls;
    searchBar.translucent = YES;
    //searchBar.searchBarStyle = UISearchBarStyleProminent;
    searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [searchBar sizeToFit];
    
    //Search bar modification
    //end
    self.tableView.tableHeaderView = searchBar;
    self.searchBar = searchBar;
    
    self.searchBar.showsActivity = DMANAGER.ftsIndexing;
    
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsMake(0, 0, 0, 0) byAdjustingForStandardBars:YES];
    
    self.toolbarLabelsViewController = [ToolbarLabelsViewController toolbarLabelsViewController];
    
    UILongPressGestureRecognizer* pressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    pressRecognizer.delegate = self;
    [self.tableView addGestureRecognizer:pressRecognizer];
    
    
    self.labelsItems = [[UIBarButtonItem alloc] initWithCustomView:self.toolbarLabelsViewController.view];
    self.labelsItems.width = CGRectGetWidth(self.toolbarLabelsViewController.view.bounds);
    
    
    //[NSFetchedResultsController deleteCacheWithName:@"_subscriptiontableview_feeds_"];
    NSFetchRequest* feedsRequest = [[NSFetchRequest alloc] init];
    feedsRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:DMANAGER.objectContext];
    feedsRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES && parked == NO"];
    feedsRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
    
    
    self.fetchController = [[NSFetchedResultsController alloc] initWithFetchRequest:feedsRequest
                                                               managedObjectContext:DMANAGER.objectContext
                                                                 sectionNameKeyPath:nil
                                                                          cacheName:nil];
    
    self.tableView.sectionHeaderHeight = 0.0;
    self.tableView.estimatedSectionHeaderHeight = 0.0;
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    self.tableView.estimatedSectionHeaderHeight = 0;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"OPMLImportDidFinishNotification" object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleOPMLImportFinish) name:@"OPMLImportDidFinishNotification" object:nil];
}

- (NSString*) _scrollPersistenceKey
{
    return @"subscriptions";
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

- (void)handleOPMLImportFinish {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.fetchController = nil; // ✅ Reset to force fresh instance

        [self setupFetchController];
        self.fetchController.delegate = self;
        [self.fetchController performFetch:nil];

        [self.tableView reloadData];

        [self _updateToolbarLabels];
    });
}

- (void)setupFetchController {
    NSFetchRequest *feedsRequest = [CDFeed fetchRequest];
    feedsRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES && parked == NO"];
    feedsRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"rank" ascending:YES]];

    self.fetchController = [[NSFetchedResultsController alloc] initWithFetchRequest:feedsRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
}


- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 0.0;
}



-(void)searchBarColorUpdates
{
    UITextField *searchTextField;
    UIColor *textColor;
    UIColor *tintColorD;
    if ([ICAppearanceManager sharedManager].nightSettingMode) {
        tintColorD = [UIColor lightGrayColor];
        textColor = [UIColor whiteColor];
    } else {
        tintColorD = [UIColor grayColor];
        textColor = [UIColor blackColor];
    }
    if (@available(iOS 13.0, *)) {
        searchTextField = self.searchBar.searchTextField;
    } else {
        searchTextField = [self.searchBar valueForKey:@"_searchField"];
    }
    searchTextField.textColor = textColor;
    searchTextField.tintColor = tintColorD;
    // 1. Change placeholder text color
    searchTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search".ls attributes:@{NSForegroundColorAttributeName: tintColorD}];
    
    // 2. Change magnifying glass (search) icon color
    UIImageView *iconView = (UIImageView *)searchTextField.leftView;
    iconView.image = [iconView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    iconView.tintColor = tintColorD;  // Set your desired color here
    
    // 3. Change dismiss (clear) icon color
    UIButton *clearButton = [searchTextField valueForKey:@"_clearButton"];
    [clearButton setImage:[[clearButton imageForState:UIControlStateNormal] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    clearButton.tintColor = tintColorD;  // Set your desired color here
}

- (void) updateAppearance
{
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.tableView.backgroundColor = ICBackgroundColor;
    [self.searchBar appearanceDidChange];
    if (self.tableView.window) {
        [self.tableView reloadData];
    }
}

- (void) _updateToolbarLabels
{
    id <NSFetchedResultsSectionInfo> sectionInfo = [[self.fetchController sections] firstObject];

    
    if ([self.searchBar.text length] == 0)
    {
        if ([sectionInfo numberOfObjects] == 0) {
            self.toolbarLabelsViewController.mainText = @"No subscription".ls;
        }
        else if ([sectionInfo numberOfObjects] == 1) {
            self.toolbarLabelsViewController.mainText = @"1 subscription".ls;
        }
        else {
            self.toolbarLabelsViewController.mainText = [NSString stringWithFormat:@"%lu %@", (unsigned long)[sectionInfo numberOfObjects], @"Subscriptions".ls];
        }
        
        unsigned long long megaBytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytes];
        if (megaBytes == 0LLU) {
            self.toolbarLabelsViewController.auxiliaryText = nil;
        }
        else {
            self.toolbarLabelsViewController.auxiliaryText = [NSByteCountFormatter stringFromByteCount:megaBytes countStyle:NSByteCountFormatterCountStyleMemory];
        }
    }
    else
    {
        if ([sectionInfo numberOfObjects] == 0) {
            self.toolbarLabelsViewController.mainText = @"No subscription found".ls;
        }
        else if ([sectionInfo numberOfObjects] == 1) {
            self.toolbarLabelsViewController.mainText = @"1 subscription found".ls;
        }
        else {
            self.toolbarLabelsViewController.mainText = [NSString stringWithFormat:@"%d Subscriptions found", (int)[sectionInfo numberOfObjects]];
        }
        
        self.toolbarLabelsViewController.auxiliaryText = nil;
    }
    
    [self.toolbarLabelsViewController layout];
}


- (void) _updateToolbarItemsAnimated:(BOOL)animated
{
    // Items nur einmal erstellen
    if (!self.addItem) {
        self.addItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] style:UIBarButtonItemStylePlain target:self action:@selector(addAction:)];
    }
    if (!self.sortItem) {
        self.sortItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"] style:UIBarButtonItemStylePlain target:self action:@selector(sortAction:)];
    }

    // Toolbar-Items nur setzen wenn noch nicht gesetzt
    if (!self.toolbarItems || self.toolbarItems.count == 0) {
        UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        [self setToolbarItems:@[self.addItem, flexSpace, self.sortItem] animated:animated];
    }
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
    _didRestoreScrollPosition = NO;
    
    NSString* searchTerm = [USER_DEFAULTS objectForKey:kUIPersistenceSubscriptionsSearchTerm];
    if (searchTerm) {
        self.searchBar.text = searchTerm;
        [self _searchTermDidChange];
    }
    

    [self reloadDataAndTable:YES];
    
    // Dispatch to avoid "offscreen beginRefreshing" warning
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([SubscriptionManager sharedSubscriptionManager].refreshing && !self.refreshControl.refreshing) {
            [self.refreshControl beginRefreshing];
        }
        else if (![SubscriptionManager sharedSubscriptionManager].refreshing && self.refreshControl.refreshing) {
            [self.refreshControl endRefreshing];
        }
    });

    [self _updateToolbarLabels];
    
    
    NSString* savedFeedUID = [USER_DEFAULTS objectForKey:kUIPersistenceSubscriptionsSelectedFeedUID];
    if (_flags.defaultPushed == 0 && savedFeedUID) {
        __block NSUInteger index = NSNotFound;
        [[self.fetchController fetchedObjects] enumerateObjectsUsingBlock:^(CDFeed* feed, NSUInteger idx, BOOL *stop) {
            if ([feed.uid isEqualToString:savedFeedUID]) {
                index = idx;
                *stop = YES;
            }
        }];
        
        if (index != NSNotFound) {
            [self _pushControllerForFeedAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0] animated:NO];
        }
    }
    else {
        [USER_DEFAULTS removeObjectForKey:kUIPersistenceSubscriptionsSelectedFeedUID];
        [USER_DEFAULTS synchronize];
    }
    
    [self _setObserving:YES];
    
    _flags.defaultPushed = 1;
    [self searchBarColorUpdates];
}



- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self _updateToolbarItemsAnimated:NO];
    [self _restoreScrollPositionIfNeeded];

    if (self.needsFullReload) {
        self.needsFullReload = NO;
        [self.fetchController performFetch:nil];
        [self.tableView reloadData];
        [self _updateToolbarLabels];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self _storeScrollPosition];
}

- (void) reloadDataAndTable:(BOOL)reloadTable
{
    if (reloadTable) {
        [self.fetchController performFetch:nil];
        [self.tableView reloadData];
    }
}

- (void)handleFeedListUpdateNotification:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.tableView.window) {
            if (!self.needsFullReload) {
                self.needsFullReload = YES;
                [self performSelector:@selector(_performCoalescedReload) withObject:nil afterDelay:0.2];
            }
        } else {
            self.needsFullReload = YES;
        }
    });
}

- (void)_performCoalescedReload {
    if (self.needsFullReload && self.tableView.window) {
        self.needsFullReload = NO;
        [self.fetchController performFetch:nil];
        [self.tableView reloadData];
        [self _updateToolbarLabels];
    }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    
    return UIInterfaceOrientationMaskPortrait;
}

#pragma mark -
#pragma mark Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [[self.fetchController sections] count];
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([[self.fetchController sections] count] > 0) {
        id <NSFetchedResultsSectionInfo> sectionInfo = [[self.fetchController sections] objectAtIndex:section];
        return [sectionInfo numberOfObjects];
    }
    return 0;
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *SubscriptionFeedCell = @"SubscriptionFeedCell";

    SubscriptionTableViewCell *cell = (SubscriptionTableViewCell*)[tableView dequeueReusableCellWithIdentifier:SubscriptionFeedCell];
    if (cell == nil) {
        cell = [[SubscriptionTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:SubscriptionFeedCell];
    }
    
    cell.backgroundColor = tableView.backgroundColor;
    cell.accessibilityHint = @"Shows list of podcast episodes.".ls;
    
    
    CDFeed* feed = [self.fetchController objectAtIndexPath:indexPath];
    cell.objectValue = feed;
    
    cell.numberLabel.hidden = ([self.searchBar.text length] > 0);
    
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}


// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete)
	{
        CDFeed* feed = [self.fetchController objectAtIndexPath:indexPath];

        NSString* title = [NSString stringWithFormat:@"%@ \"%@\"?", @"Unsubscribe".ls, feed.title ?: @""];
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:@"All downloaded episodes will be deleted.".ls
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction* action) {
            [tableView setEditing:NO animated:YES];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Unsubscribe".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
            self->_flags.userAction = 1;
            [[SubscriptionManager sharedSubscriptionManager] unsubscribeFeed:feed];

            // Refresh fetch controller and reload table
            [self.fetchController performFetch:nil];
            [self reloadDataAndTable:YES];
            self->_flags.userAction = 0;

            [self _updateToolbarLabels];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
	return YES;
}

// Override to support rearranging the table view.
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath
{
    _flags.userAction = 1;
    
    NSArray* feeds = DMANAGER.visibleFeeds;
    
    CDFeed* srcFeed = [self.fetchController objectAtIndexPath:fromIndexPath];
    NSUInteger srcIndex = [feeds indexOfObject:srcFeed];
    
    CDFeed* dstFeed = [self.fetchController objectAtIndexPath:toIndexPath];
    NSUInteger dstIndex = [feeds indexOfObject:dstFeed];
    
    [DMANAGER reorderFeedFromIndex:srcIndex toIndex:dstIndex];
    [DMANAGER saveManualFeedOrder];
    [USER_DEFAULTS setObject:@"manual" forKey:FeedListSortMode];

    _flags.userAction = 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return @"Unsubscribe".ls;
}

- (void) showEpisodeListForFeed:(CDFeed*)feed animated:(BOOL)animated
{
    if (!feed) {
        return;
    }

    if ([self.searchBar.text length] > 0) {
        self.searchBar.text = nil;
        [self _searchTermDidChange];
    }

    UINavigationBarAppearance *navBarAppearance = [[UINavigationBarAppearance alloc] init];
    [navBarAppearance configureWithOpaqueBackground];
    [navBarAppearance setTitleTextAttributes:@{NSForegroundColorAttributeName: ICTextColor}];
    [navBarAppearance setLargeTitleTextAttributes:@{NSForegroundColorAttributeName: ICTextColor}];
    navBarAppearance.backgroundColor = ICBackgroundColor;
    self.navigationController.navigationBar.standardAppearance = navBarAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navBarAppearance;

    if ([feed.uid length] > 0) {
        [USER_DEFAULTS setObject:feed.uid forKey:kUIPersistenceSubscriptionsSelectedFeedUID];
    }

    NSArray* feeds = [self.fetchController fetchedObjects];
    if (feeds) {
        FeedEpisodesTableViewController* controller = [FeedEpisodesTableViewController episodesControllerWithFeed:feed];
        
        [self.navigationController pushViewController:controller animated:animated];
    }
}

#pragma mark -
#pragma mark Table view delegate

- (void) _pushControllerForFeedAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated
{
    CDFeed* feed = [self.fetchController objectAtIndexPath:indexPath];
    FeedEpisodesTableViewController* controller = [FeedEpisodesTableViewController episodesControllerWithFeed:feed];
    controller.searchTerm = self.searchBar.text;
    
    UINavigationBarAppearance *navBarAppearance = [[UINavigationBarAppearance alloc] init];
    [navBarAppearance configureWithOpaqueBackground];
    [navBarAppearance setTitleTextAttributes:@{NSForegroundColorAttributeName: ICTextColor}];
    [navBarAppearance setLargeTitleTextAttributes:@{NSForegroundColorAttributeName: ICTextColor}];
    navBarAppearance.backgroundColor = ICBackgroundColor;
    self.navigationController.navigationBar.standardAppearance = navBarAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navBarAppearance;
 
    [self.navigationController pushViewController:controller animated:animated];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self _storeScrollPosition];
    [self _pushControllerForFeedAtIndexPath:indexPath animated:YES];
    
    CDFeed* feed = [self.fetchController objectAtIndexPath:indexPath];
    [USER_DEFAULTS setObject:feed.uid forKey:kUIPersistenceSubscriptionsSelectedFeedUID];
}

#pragma mark - FetchedResultsController delegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
    if (_flags.userAction == 1) return;

    // Kein beginUpdates wenn Table nicht im Window - sonst entsteht eine Inkonsistenz
    // zwischen FRC-State und Table-State die den Table dauerhaft korrupt macht
    if (self.tableView.window == nil) {
        self.needsFullReload = YES;
        return;
    }

    self.tableViewIsUpdating = YES;
    [self.tableView beginUpdates];
}

- (void)controller:(NSFetchedResultsController *)controller
  didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex
     forChangeType:(NSFetchedResultsChangeType)type {

    if (!self.tableViewIsUpdating) return;

    switch(type) {
        case NSFetchedResultsChangeInsert:
            [self.tableView insertSections:[NSIndexSet indexSetWithIndex:sectionIndex]
                          withRowAnimation:UITableViewRowAnimationFade];
            break;

        case NSFetchedResultsChangeDelete:
            [self.tableView deleteSections:[NSIndexSet indexSetWithIndex:sectionIndex]
                          withRowAnimation:UITableViewRowAnimationFade];
            break;

        default:
            break;
    }
}

- (void)controller:(NSFetchedResultsController *)controller didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath forChangeType:(NSFetchedResultsChangeType)type
      newIndexPath:(NSIndexPath *)newIndexPath
{
    if (!self.tableViewIsUpdating) return;

    UITableView *tableView = self.tableView;

    switch (type) {
        case NSFetchedResultsChangeInsert:
            if (newIndexPath.section < [tableView numberOfSections]) {
                [tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
            }
            break;

        case NSFetchedResultsChangeDelete:
            if (indexPath.section < [tableView numberOfSections] &&
                indexPath.row < [tableView numberOfRowsInSection:indexPath.section]) {
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
            }
            break;

        case NSFetchedResultsChangeUpdate:
            if (indexPath.section < [tableView numberOfSections] &&
                indexPath.row < [tableView numberOfRowsInSection:indexPath.section]) {
                [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            }
            break;

        case NSFetchedResultsChangeMove:
            if (indexPath && newIndexPath && ![indexPath isEqual:newIndexPath]) {
                [tableView moveRowAtIndexPath:indexPath toIndexPath:newIndexPath];
            } else if (indexPath) {
                [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            }
            break;
    }
}


- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller {
    if (_flags.userAction == 1) return;

    if (!self.tableViewIsUpdating) {
        // Wurde in willChangeContent uebersprungen (kein Window) - nichts zu tun
        return;
    }

    @try {
        [self.tableView endUpdates];
    } @catch (NSException *exception) {
        [self.fetchController performFetch:nil];
        [self.tableView reloadData];
    }
    self.tableViewIsUpdating = NO;
    [self _updateToolbarLabels];
}


#pragma mark - SearchBar Delete


- (void) _searchTermDidChange
{
    NSString* searchText = self.searchBar.text;
    
    if ([searchText length] > 2)
    {
        NSSet* feedUIDs = [DMANAGER.ftsController feedUIDsForSearchTerm:searchText];
        
        self.fetchController.fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES && parked == NO && sourceURL_ IN %@", feedUIDs];
        [self.fetchController performFetch:nil];
        [USER_DEFAULTS setObject:searchText forKey:kUIPersistenceSubscriptionsSearchTerm];
    }
    else {
        self.fetchController.fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES && parked == NO"];
        [self.fetchController performFetch:nil];
        [USER_DEFAULTS removeObjectForKey:kUIPersistenceSubscriptionsSearchTerm];
    }
    [self.tableView reloadData];
    [self _updateToolbarLabels];
    self.navigationItem.rightBarButtonItem.enabled = ([searchText length] == 0);
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self coalescedPerformSelector:@selector(_searchTermDidChange) afterDelay:0.3];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [self.searchBar resignFirstResponder];
}

- (void) scrollViewDidScroll:(UIScrollView *)scrollView
{
    [self.searchBar resignFirstResponder];
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

#pragma mark -

- (void) refresh:(id)sender
{
    [[SubscriptionManager sharedSubscriptionManager] refreshAllFeedsForce:YES etagHandling:YES completion:^(BOOL success, NSArray* newEpisodes, NSError* error) {
        if (error) {
            [self presentError:error];
        }
    }];
}

#pragma mark -
#pragma mark Actions

- (void) toggleEditMode:(id)sender
{
    [self setEditing:!self.editing animated:YES];
}

- (void) setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    UIImage* editImage = editing ? [UIImage systemImageNamed:@"checkmark"] : [UIImage systemImageNamed:@"pencil"];
    self.navigationItem.rightBarButtonItem.image = editImage;
}

- (void) addAction:(id)sender
{
    DirectorySearchViewController* controller = [DirectorySearchViewController directorySearchViewController];
    PortraitNavigationController* navigationController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
    navigationController.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigationController animated:YES completion:NULL];
}


- (void) sortAction:(UIBarButtonItem*)item
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Sort by".ls
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSString* currentMode = [USER_DEFAULTS stringForKey:FeedListSortMode];

    UIAlertAction* titleAction = [UIAlertAction actionWithTitle:@"Title".ls style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * action) {
                                                              STRONG_SELF
                                                              [self dismissViewControllerAnimated:NO completion:nil];
                                                              self->_flags.userAction = 1;
                                                              [USER_DEFAULTS setObject:@"title" forKey:FeedListSortMode];
                                                              [DMANAGER sortFeedsByKey:@"title" ascending:YES selector:@selector(naturalCaseInsensitiveCompare:)];
                                                              [self.fetchController performFetch:nil];
                                                              [self.tableView reloadData];
                                                              self->_flags.userAction = 0;
                                                              self.alertController = nil;
                                                          }];
    if ([currentMode isEqualToString:@"title"]) [titleAction setValue:@YES forKey:@"checked"];
    [alert addAction:titleAction];


    UIAlertAction* unplayedAction = [UIAlertAction actionWithTitle:@"Unplayed".ls style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * action) {
                                                            STRONG_SELF
                                                            [self dismissViewControllerAnimated:NO completion:nil];
                                                            self->_flags.userAction = 1;
                                                            [USER_DEFAULTS setObject:@"unplayed" forKey:FeedListSortMode];
                                                            [DMANAGER sortFeedsByKey:@"unplayedCount" ascending:NO selector:nil];
                                                            [self.fetchController performFetch:nil];
                                                            [self.tableView reloadData];
                                                            self->_flags.userAction = 0;
                                                            self.alertController = nil;
                                                        }];
    if ([currentMode isEqualToString:@"unplayed"]) [unplayedAction setValue:@YES forKey:@"checked"];
    [alert addAction:unplayedAction];

    UIAlertAction* lastPlayedAction = [UIAlertAction actionWithTitle:@"Last Played".ls style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction * action) {
                                                                 STRONG_SELF
                                                                 [self dismissViewControllerAnimated:NO completion:nil];
                                                                 self->_flags.userAction = 1;
                                                                 [USER_DEFAULTS setObject:@"lastPlayed" forKey:FeedListSortMode];
                                                                 [DMANAGER sortFeedsByComparator:^NSComparisonResult(CDFeed* a, CDFeed* b) {
                                                                     NSDate* dateA = a.lastPlayed;
                                                                     NSDate* dateB = b.lastPlayed;
                                                                     if (!dateA && !dateB) return NSOrderedSame;
                                                                     if (!dateA) return NSOrderedDescending;
                                                                     if (!dateB) return NSOrderedAscending;
                                                                     return [dateB compare:dateA];
                                                                 }];
                                                                 [self.fetchController performFetch:nil];
                                                                 [self.tableView reloadData];
                                                                 self->_flags.userAction = 0;
                                                                 self.alertController = nil;
                                                             }];
    if ([currentMode isEqualToString:@"lastPlayed"]) [lastPlayedAction setValue:@YES forKey:@"checked"];
    [alert addAction:lastPlayedAction];

    UIAlertAction* newestEpisodesAction = [UIAlertAction actionWithTitle:@"Newest Episodes".ls style:UIAlertActionStyleDefault
                                                                 handler:^(UIAlertAction * action) {
                                                                     STRONG_SELF
                                                                     [self dismissViewControllerAnimated:NO completion:nil];
                                                                     self->_flags.userAction = 1;
                                                                     [USER_DEFAULTS setObject:@"newestEpisodes" forKey:FeedListSortMode];
                                                                     [DMANAGER sortFeedsByComparator:^NSComparisonResult(CDFeed* a, CDFeed* b) {
                                                                         NSDate* dateA = a.lastPubDate;
                                                                         NSDate* dateB = b.lastPubDate;
                                                                         if (!dateA && !dateB) return NSOrderedSame;
                                                                         if (!dateA) return NSOrderedDescending;
                                                                         if (!dateB) return NSOrderedAscending;
                                                                         return [dateB compare:dateA];
                                                                     }];
                                                                     [self.fetchController performFetch:nil];
                                                                     [self.tableView reloadData];
                                                                     self->_flags.userAction = 0;
                                                                     self.alertController = nil;
                                                                 }];
    if ([currentMode isEqualToString:@"newestEpisodes"]) [newestEpisodesAction setValue:@YES forKey:@"checked"];
    [alert addAction:newestEpisodesAction];

    if ([DMANAGER hasManualFeedOrder]) {
        UIAlertAction* manualAction = [UIAlertAction actionWithTitle:@"Manual".ls style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction * action) {
                                                                 STRONG_SELF
                                                                 [self dismissViewControllerAnimated:NO completion:nil];
                                                                 self->_flags.userAction = 1;
                                                                 [USER_DEFAULTS setObject:@"manual" forKey:FeedListSortMode];
                                                                 [DMANAGER restoreManualFeedOrder];
                                                                 [self.fetchController performFetch:nil];
                                                                 [self.tableView reloadData];
                                                                 self->_flags.userAction = 0;
                                                                 self.alertController = nil;
                                                             }];
        if ([currentMode isEqualToString:@"manual"]) [manualAction setValue:@YES forKey:@"checked"];
        [alert addAction:manualAction];
    }

    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction * action) {
                                                              STRONG_SELF
                                                              self.alertController = nil;
                                                          }];
    [alert addAction:defaultAction];
    [alert setModalPresentationStyle:UIModalPresentationPopover];
    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    popPresenter.barButtonItem = item;
    popPresenter.permittedArrowDirections = UIPopoverArrowDirectionAny;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.alertController = alert;
    [self presentViewController:alert animated:YES completion:NULL];
}


#pragma mark -
#pragma mark Gestures

- (void) handleLongPress:(UILongPressGestureRecognizer*)recognizer
{
	if (recognizer.state == UIGestureRecognizerStateBegan && !self.tableView.editing)
	{
        CGPoint location = [recognizer locationInView:self.tableView];
		NSIndexPath *rowIndexPath = [self.tableView indexPathForRowAtPoint:location];
        
//        NSArray* subscriptions = self.feeds;
//        
//        // long pressing on an empty cell not allowed
//        if (!rowIndexPath || rowIndexPath.row >= [subscriptions count]) {
//            return;
//        }
        
        CDFeed* feed = [self.fetchController objectAtIndexPath:rowIndexPath];
        
        FeedSettingsViewController* viewController = [FeedSettingsViewController feedSettingsViewControllerWithFeed:feed];
        PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:viewController];
        navController.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:navController animated:YES completion:^{
            
        }];
	}
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]] && !self.editing) {
        return YES;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer;
{
    return YES;
}


@end
