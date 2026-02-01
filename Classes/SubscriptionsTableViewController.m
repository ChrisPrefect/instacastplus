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

#import "STITunesStore.h"
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
@property (nonatomic, assign) BOOL isLoadingFromCloud;
@property (nonatomic, assign) BOOL tableViewIsUpdating;
//@property (nonatomic, strong) UILabel *iCloudLoadingLabel;
@end

@implementation SubscriptionsTableViewController {
    struct {
        unsigned int observing:1;
        unsigned int defaultPushed:1;
        unsigned int userAction:1;
    } _flags;
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
        
        [nc addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
        
        [nc addObserver:self selector:@selector(handleICloudSyncUpdateNotification:)
                   name:DatabaseManagerDidUpdateObservedFeedNotification
                 object:nil];
        [DMANAGER addTaskObserver:self forKeyPath:@"ftsIndexing" task:^(id obj, NSDictionary *change) {
            self.searchBar.showsActivity = DMANAGER.ftsIndexing;
        }];
        
        
        _flags.observing = 1;
    }
    else if (!observing && _flags.observing == 1)
    {
        [nc removeObserver:self];
        
        [sman removeTaskObserver:self forKeyPath:@"formattedLastRefreshDate"];
        [DMANAGER removeTaskObserver:self forKeyPath:@"ftsIndexing"];
        
        _flags.observing = 0;
    }
}

- (void) subscriptionManagerDidStartRefreshingFeedsNotification:(NSNotification*)notification
{
    [self.refreshControl beginRefreshing];
}

- (void) subscriptionManagerDidFinishRefreshingFeedsNotification:(NSNotification*)notification
{
    [self.refreshControl endRefreshing];
}

#pragma mark -
#pragma mark View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.title = @"Podcasts".ls;
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    
    self.tableView.rowHeight = 57+10;
    self.tableView.separatorInset = UIEdgeInsetsZero;
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"episode_list_scroll_position"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"episode_list_last_index"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
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
    // Hinweis: NSPersistentStoreRemoteChangeNotification wird bereits in DatabaseManager behandelt
    // und über DatabaseManagerDidUpdateObservedFeedNotification weitergeleitet
    self.isLoadingFromCloud = YES;
    if ([USER_DEFAULTS valueForKey: @"icloud_sync_log_view_show"] == nil)
    {
        [self checkForiCloudData];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self hideiCloudLogView];
        });
    }
    else
    {
        self.isLoadingFromCloud = NO;
        if (self.tableView.window) {
            [self.tableView reloadData];
        }
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"OPMLImportDidFinishNotification" object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleOPMLImportFinish) name:@"OPMLImportDidFinishNotification" object:nil];
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
    feedsRequest.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"title" ascending:YES]];

    self.fetchController = [[NSFetchedResultsController alloc] initWithFetchRequest:feedsRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:nil];
    self.fetchController.delegate = self;
}


- (void)hideiCloudLogView {
    self.isLoadingFromCloud = NO;
    //self.iCloudLoadingLabel.hidden = YES;
    if (self.tableView.window) {
        [self.tableView reloadData];
    }
    [USER_DEFAULTS setBool:true forKey:@"icloud_sync_log_view_show"];
    [USER_DEFAULTS synchronize];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (self.isLoadingFromCloud) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 30)];
        label.text = [@"Loading data from iCloud".ls stringByAppendingString:@"..."];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.textColor = [UIColor grayColor];
        //NSLog(@"Returning iCloud loading header view");
        return label;
    }
    //NSLog(@"Returning nil for header view (isLoadingFromCloud = NO)");
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (self.isLoadingFromCloud) {
        //NSLog(@"Header height: 30.0 (isLoadingFromCloud = YES)");
        return 30.0;
    }
    //NSLog(@"Header height: 0.0 (isLoadingFromCloud = NO)");
    return 0.0;
}



- (void)checkForiCloudData {
    if (self.isLoadingFromCloud && self.fetchController.fetchedObjects.count > 0) {
        self.isLoadingFromCloud = NO;

        NSError *fetchError = nil;
        [self.fetchController performFetch:&fetchError];
        if (fetchError) {
            NSLog(@"❌ Fetch error: %@", fetchError);
        }

        [self.tableView reloadData]; // ✅ full reload = safe
    } else if (self.isLoadingFromCloud) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self checkForiCloudData];
        });
    }
}


- (void)cloudKitDidSync:(NSNotification *)notification {
    if (!self.isLoadingFromCloud) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[self.fetchController fetchedObjects] count] > 0 && self.isLoadingFromCloud) {
            self.isLoadingFromCloud = NO;
            //self.iCloudLoadingLabel.hidden = YES;
            if (self.tableView.window) {
                [self.tableView reloadData];
            }
            [USER_DEFAULTS setBool:true forKey:@"icloud_sync_log_view_show"];
            [USER_DEFAULTS synchronize];
        } else {
            //NSLog(@"⏳ Waiting for data… current feed count: %lu", (unsigned long)[[self.fetchController fetchedObjects] count]);
        }
    });
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
        self.addItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Add"] style:UIBarButtonItemStylePlain target:self action:@selector(addAction:)];
    }
    if (!self.sortItem) {
        self.sortItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Sort"] style:UIBarButtonItemStylePlain target:self action:@selector(sortAction:)];
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
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.tableView.backgroundColor = ICBackgroundColor;
    [self.searchBar appearanceDidChange];
    
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
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void) reloadDataAndTable:(BOOL)reloadTable
{
    //self.feeds = [DMANAGER.feeds filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"parked == NO"]];
    if (reloadTable && self.tableView.window) {
        //self.isLoadingFromCloud = NO;
        [self.tableView reloadData];
    }
}

- (void)handleICloudSyncUpdateNotification:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.fetchController performFetch:nil];
        self.isLoadingFromCloud = NO;
        [self.tableView reloadData];
    });
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
    // Return the number of sections.
    if (self.isLoadingFromCloud)
    {
        return 1; // Just show the loading label in header
    }
    return [[self.fetchController sections] count];
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (self.isLoadingFromCloud &&
        self.fetchController.fetchedObjects.count == 0) {
        return 0;
    }
    
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

        _flags.userAction = 1;
		[[SubscriptionManager sharedSubscriptionManager] unsubscribeFeed:feed];

        // Refresh fetch controller and reload table
        [self.fetchController performFetch:nil];
        [self reloadDataAndTable:YES];
        _flags.userAction = 0;

		UIBarButtonItem* sortItem = self.navigationItem.rightBarButtonItem;
        sortItem.enabled = ([[self.fetchController fetchedObjects] count] > 1);
        [self _updateToolbarLabels];
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
    
    _flags.userAction = 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return @"Unsubscribe".ls;
}

- (void) showEpisodeListForFeed:(CDFeed*)feed animated:(BOOL)animated
{
    UINavigationBarAppearance *navBarAppearance = [[UINavigationBarAppearance alloc] init];
    [navBarAppearance configureWithOpaqueBackground];
    [navBarAppearance setTitleTextAttributes:@{NSForegroundColorAttributeName: ICTextColor}];
    [navBarAppearance setLargeTitleTextAttributes:@{NSForegroundColorAttributeName: ICTextColor}];
    navBarAppearance.backgroundColor = ICBackgroundColor;
    self.navigationController.navigationBar.standardAppearance = navBarAppearance;
    self.navigationController.navigationBar.scrollEdgeAppearance = navBarAppearance;

    NSArray* feeds = [self.fetchController fetchedObjects];
    if (feeds) {
        FeedEpisodesTableViewController* controller = [FeedEpisodesTableViewController episodesControllerWithFeed:feed];
        
        [self.navigationController pushViewController:controller animated:animated];
    }
    else {
        [USER_DEFAULTS setObject:feed.uid forKey:kUIPersistenceSubscriptionsSelectedFeedUID];
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
    NSInteger rowDev = [indexPath row];
    if ([[NSUserDefaults standardUserDefaults] valueForKey:@"episode_list_last_index"] != nil){
        NSInteger lastIndex = [[NSUserDefaults standardUserDefaults] integerForKey:@"episode_list_last_index"];
        if (lastIndex != rowDev)
        {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"episode_list_scroll_position"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    }
    else
    {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"episode_list_scroll_position"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    [[NSUserDefaults standardUserDefaults] setInteger:rowDev forKey:@"episode_list_last_index"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self _pushControllerForFeedAtIndexPath:indexPath animated:YES];
    
    CDFeed* feed = [self.fetchController objectAtIndexPath:indexPath];
    [USER_DEFAULTS setObject:feed.uid forKey:kUIPersistenceSubscriptionsSelectedFeedUID];
}

#pragma mark - FetchedResultsController delegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller {
//    if (_flags.userAction == 0) {
//        [self.tableView beginUpdates];
//    }
    if (self.isLoadingFromCloud || _flags.userAction == 0) return;
        self.tableViewIsUpdating = YES;
        [self.tableView beginUpdates];
}

- (void)controller:(NSFetchedResultsController *)controller
  didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex
     forChangeType:(NSFetchedResultsChangeType)type {
    
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
    if (self.isLoadingFromCloud || _flags.userAction == 1) return;
    
    // If table is not yet visible/valid, bail out
    if (!self.tableViewIsUpdating || self.tableView.window == nil) {
        return;
    }
    
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
    NSLog(@"🎯 controllerDidChangeContent triggered, userAction=%d", _flags.userAction);
    
    if (self.isLoadingFromCloud || _flags.userAction == 1) return;
    @try {
        [self.tableView endUpdates];
    } @catch (NSException *exception) {
        NSLog(@"🔥 Fallback to reloadData due to: %@", exception);
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
    self.editButtonItem.enabled = ([searchText length] == 0);
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
    
    
    UIAlertAction* titleAction = [UIAlertAction actionWithTitle:@"Title".ls style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * action) {
                                                              STRONG_SELF
                                                              [self perform:^(id sender) {
                                                                  [DMANAGER sortFeedsByKey:@"title" ascending:YES selector:@selector(naturalCaseInsensitiveCompare:)];
                                                              } afterDelay:0.3];
                                                              self.alertController = nil;
                                                          }];
    [alert addAction:titleAction];
    
    
    UIAlertAction* unplayedAction = [UIAlertAction actionWithTitle:@"Unplayed".ls style:UIAlertActionStyleDefault
                                                        handler:^(UIAlertAction * action) {
                                                            STRONG_SELF
                                                            [self perform:^(id sender) {
                                                                [DMANAGER sortFeedsByKey:@"unplayedCount" ascending:NO selector:nil];
                                                            } afterDelay:0.3];
                                                            self.alertController = nil;
                                                        }];
    [alert addAction:unplayedAction];
    
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction * action) {
                                                              STRONG_SELF
                                                              self.alertController = nil;
                                                          }];
    [alert addAction:defaultAction];
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

