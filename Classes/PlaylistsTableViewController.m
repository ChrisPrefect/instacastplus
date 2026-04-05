//
//  PlaylistsTableViewControllerViewController.m
//  Instacast
//
//  Created by Martin Hering on 03.04.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <MessageUI/MessageUI.h>


#import "PlaylistsTableViewController.h"

#import "SubscriptionManager.h"
#import "ICPlaylistsTableViewCell.h"
#import "VDModalInfo.h"

#import "ICFeedURLScraper.h"
#import "AnimatingLabel.h"


#import "OptionsViewController.h"
#import "InstacastAppDelegate.h"

#import "ToolbarLabelsViewController.h"
#import "BookmarksTableViewController.h"
#import "CDModel.h"
#import "PortraitNavigationController.h"
#import "ICRefreshControl.h"
#import "EpisodeListEditorViewController.h"
#import "ListEpisodesTableViewController.h"


@interface PlaylistsTableViewController () <MFMailComposeViewControllerDelegate, UIGestureRecognizerDelegate>

@property (nonatomic, assign) NSInteger action;
@property (nonatomic, strong) ToolbarLabelsViewController* toolbarLabelsViewController;
@property (nonatomic, strong) UIBarButtonItem* labelsItems;
@property (nonatomic, strong) UIBarButtonItem* addButtonItem;
@property (nonatomic, strong) UIBarButtonItem* editButtonItem;
@end

@implementation PlaylistsTableViewController {
    BOOL _observing;
    BOOL _defaultPushed;
    BOOL _userAction;
    BOOL _didRestoreScrollPosition;
}

#pragma mark -
#pragma mark Initialization

+ (PlaylistsTableViewController*) viewController
{
	return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (id)initWithStyle:(UITableViewStyle)style {
    // Override initWithStyle: if you create the controller programmatically and want to perform customization that is not appropriate for viewDidLoad.
    self = [super initWithStyle:style];
    if (self) {
        // Custom initialization.
    }
    return self;
}

- (void)dealloc
{
    [self _setObserving:NO];
}

#pragma mark -
#pragma mark View lifecycle

- (void) _setObserving:(BOOL)observing
{
    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    
    if (observing && !_observing)
    {
        [DMANAGER addTaskObserver:self forKeyPath:@"lists" task:^(id obj, NSDictionary *change) {
            if (!self->_userAction && self.tableView.window) {
                [self.tableView reloadData];
                [self _updateToolbarItemsAnimated:NO];
                [self _updateToolbarLabels];
            }
            [self _updateEditButton];
        }];
        
        [nc addObserver:self selector:@selector(subscriptionManagerDidAddEpisodesNotification:) name:SubscriptionManagerDidAddEpisodesNotification object:nil];
        [nc addObserver:self selector:@selector(subscriptionManagerDidStartRefreshingFeedsNotification:) name:SubscriptionManagerDidStartRefreshingFeedsNotification object:nil];
        [nc addObserver:self selector:@selector(subscriptionManagerDidFinishRefreshingFeedsNotification:) name:SubscriptionManagerDidFinishRefreshingFeedsNotification object:nil];
        
        [sman addTaskObserver:self forKeyPath:@"formattedLastRefreshDate" task:^(id obj, NSDictionary *change) {
            ((ICRefreshControl*)self.refreshControl).idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDate];
        }];

        [sman addTaskObserver:self forKeyPath:@"refreshStatusText" task:^(id obj, NSDictionary *change) {
            SubscriptionManager* sm = [SubscriptionManager sharedSubscriptionManager];
            if (sm.refreshing) {
                ((ICRefreshControl*)self.refreshControl).refreshText = sm.refreshStatusText;
            }
        }];

        [nc addObserver:self
                                                 selector:@selector(updateAppearance)
                                                     name:ICAppearanceManagerDidUpdateAppearanceNotification
                                                   object:nil];
        

        _observing = YES;
    }
    else if (!observing && _observing)
    {
        [DMANAGER removeTaskObserver:self forKeyPath:@"lists"];
        [nc removeObserver:self];
        
        [sman removeTaskObserver:self forKeyPath:@"formattedLastRefreshDate"];
        [sman removeTaskObserver:self forKeyPath:@"refreshStatusText"];
        _observing = NO;
    }
}

- (void) subscriptionManagerDidAddEpisodesNotification:(NSNotification*)notification
{
    if (!_userAction && self.tableView.window) {
        [self.tableView reloadData];
    }
}

- (void) subscriptionManagerDidStartRefreshingFeedsNotification:(NSNotification*)notification
{
    if (self.isViewLoaded && self.view.window) {
        [self.refreshControl beginRefreshing];
    }
}

- (void) _presentRefreshFailureAlert:(NSArray<NSString*>*)failures
{
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

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];
    
    // Use edit icon instead of text
    self.editButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self
                                                           action:@selector(toggleEditMode:)];
    self.title = @"Lists".ls;

    self.tableView.rowHeight = 54;  // Increased from 44
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 18, 0, 18);  // More padding left/right
    
    ICRefreshControl* refreshControl = [[ICRefreshControl alloc] init];
    refreshControl.pulldownText = @"Pull to refresh…".ls;
    refreshControl.refreshText = @"Looking for new episodes…".ls;
    refreshControl.idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDate];
    [refreshControl addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;
    
    
    self.toolbarLabelsViewController = [ToolbarLabelsViewController toolbarLabelsViewController];
    
    self.labelsItems = [[UIBarButtonItem alloc] initWithCustomView:self.toolbarLabelsViewController.view];
    self.labelsItems.width = CGRectGetWidth(self.toolbarLabelsViewController.view.bounds);

    
    UILongPressGestureRecognizer* pressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
	pressRecognizer.delegate = self;
	[self.tableView addGestureRecognizer:pressRecognizer];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _didRestoreScrollPosition = NO;
    
    [self updateAppearance];
    [self _updateToolbarLabels];

    [self _updateEditButton];

    // Dispatch to avoid "offscreen beginRefreshing" warning
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([SubscriptionManager sharedSubscriptionManager].refreshing && !self.refreshControl.refreshing) {
            [self.refreshControl beginRefreshing];
        }
        else if (![SubscriptionManager sharedSubscriptionManager].refreshing && self.refreshControl.refreshing) {
            [self.refreshControl endRefreshing];
        }
    });
    
    
    NSString* savedUID = [USER_DEFAULTS objectForKey:kUIPersistencePlaylistsSelectedPlaylistUID];
    if (_defaultPushed == 0 && savedUID) {
        __block NSUInteger index = NSNotFound;
        [DMANAGER.lists enumerateObjectsUsingBlock:^(CDList* list, NSUInteger idx, BOOL *stop) {
            if ([list.uid isEqualToString:savedUID]) {
                index = idx;
                *stop = YES;
            }
        }];
        
        if (index != NSNotFound) {
            [self _pushControllerForListAtIndex:index animated:NO];
        }
    }
    else {
        [USER_DEFAULTS removeObjectForKey:kUIPersistencePlaylistsSelectedPlaylistUID];
    }
    _defaultPushed = 1;
    
    [self _setObserving:YES];
}

- (void) updateAppearance {
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.tableView.backgroundColor = ICBackgroundColor;

    if (self.tableView.window) {
        [self.tableView reloadData];
    }
}


- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self _updateToolbarItemsAnimated:NO];
    [self _restoreScrollPositionIfNeeded];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    [self _storeScrollPosition];
    [self _setObserving:NO];
}

- (NSString*) _scrollPersistenceKey
{
    return @"playlists";
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

- (void) _updateToolbarLabels
{
    if ([DMANAGER.lists count] == 0) {
        self.toolbarLabelsViewController.mainText = @"No Lists".ls;
    }
    else if ([DMANAGER.lists count] == 1) {
        self.toolbarLabelsViewController.mainText = @"1 List".ls;
    }
    else {
        self.toolbarLabelsViewController.mainText = [NSString stringWithFormat:@"%d Lists".ls, [DMANAGER.lists count]];
    }
    
    unsigned long long megaBytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytes];
    if (megaBytes == 0LLU) {
        self.toolbarLabelsViewController.auxiliaryText = nil;
    }
    else {
        self.toolbarLabelsViewController.auxiliaryText = [NSByteCountFormatter stringFromByteCount:megaBytes countStyle:NSByteCountFormatterCountStyleMemory];
    }
    [self.toolbarLabelsViewController layout];
}

- (void) _updateToolbarItemsAnimated:(BOOL)animated
{
    // Items nur einmal erstellen
    if (!self.addButtonItem) {
        self.addButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Add"] style:UIBarButtonItemStylePlain target:self action:@selector(addAction:)];
    }

    // Toolbar-Items nur setzen wenn noch nicht gesetzt
    if (!self.toolbarItems || self.toolbarItems.count == 0) {
        UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        [self setToolbarItems:@[self.addButtonItem, flexSpace, self.labelsItems, flexSpace] animated:animated];
    }
}


#pragma mark -
#pragma mark Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // Return the number of sections.
    return 1;
}


- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [DMANAGER.lists count];
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"Cell";
    
    ICPlaylistsTableViewCell *cell = (ICPlaylistsTableViewCell*)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[ICPlaylistsTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:CellIdentifier];
    }
    cell.backgroundColor = self.tableView.backgroundColor;
    
    CDList* list = [DMANAGER.lists objectAtIndex:indexPath.row];
    cell.objectValue = list;
        
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleDelete;
}


- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    _userAction = YES;
    CDList* list = [DMANAGER.lists objectAtIndex:indexPath.row];

    // Remove from MainMenuListUIDs if present
    if (list.uid) {
        NSMutableArray* mainMenuUIDs = [([USER_DEFAULTS objectForKey:@"MainMenuListUIDs"] ?: @[]) mutableCopy];
        if ([mainMenuUIDs containsObject:list.uid]) {
            [mainMenuUIDs removeObject:list.uid];
            [USER_DEFAULTS setObject:mainMenuUIDs forKey:@"MainMenuListUIDs"];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"MainMenuListUIDsDidChangeNotification" object:nil];
        }
    }

    [DMANAGER removeList:list];

    // Delete the row from the data source.
    [tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
    _userAction = NO;

    [self _updateEditButton];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
	return YES;
}

// Override to support rearranging the table view.
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath
{
    _userAction = YES;
    [DMANAGER reorderListFromIndex:fromIndexPath.row toIndex:toIndexPath.row];
    _userAction = NO;

    // Sync sidebar order: re-sort MainMenuListUIDs to match the new list rank order
    NSArray* mainMenuUIDs = [USER_DEFAULTS objectForKey:@"MainMenuListUIDs"];
    if (mainMenuUIDs.count > 1) {
        NSArray* lists = DMANAGER.lists;
        NSMutableArray* sortedUIDs = [NSMutableArray array];
        for (CDList* list in lists) {
            if (list.uid && [mainMenuUIDs containsObject:list.uid]) {
                [sortedUIDs addObject:list.uid];
            }
        }
        // Append any UIDs not found in lists (shouldn't happen, but be safe)
        for (NSString* uid in mainMenuUIDs) {
            if (![sortedUIDs containsObject:uid]) {
                [sortedUIDs addObject:uid];
            }
        }
        [USER_DEFAULTS setObject:sortedUIDs forKey:@"MainMenuListUIDs"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MainMenuListUIDsDidChangeNotification" object:nil];
    }
}


#pragma mark -
#pragma mark Table view delegate

- (void) _pushControllerForListAtIndex:(NSUInteger)index animated:(BOOL)animated
{
    CDList* list = [DMANAGER.lists objectAtIndex:index];

    UIBarButtonItem* a = [[UIBarButtonItem alloc] initWithTitle:@"" style:UIBarButtonItemStylePlain target:nil action:nil];
    self.navigationItem.backBarButtonItem = a;
    
    ListEpisodesTableViewController* episodesController = [ListEpisodesTableViewController viewControllerWithList:list];
   
    [self.navigationController pushViewController:episodesController animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (!self.editing) {
        [self _storeScrollPosition];
        [self _pushControllerForListAtIndex:indexPath.row animated:YES];
        
        CDList* list = [DMANAGER.lists objectAtIndex:indexPath.row];
        [USER_DEFAULTS setObject:list.uid forKey:kUIPersistencePlaylistsSelectedPlaylistUID];
    }
    else {
        [self _updateToolbarItemsAnimated:NO];
    }
}


#pragma mark -
#pragma mark ScrollView Delegate


- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
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
#pragma mark Actions

- (BOOL) _canEditAnyList
{
    return (DMANAGER.lists.count > 0);
}

- (void) _updateEditButton
{
    if ([self _canEditAnyList]) {
        self.navigationItem.rightBarButtonItem = self.editButtonItem;
    } else {
        if (self.editing) {
            [self setEditing:NO animated:NO];
        }
        self.navigationItem.rightBarButtonItem = nil;
    }
}

- (void) toggleEditMode:(id)sender
{
    [self setEditing:!self.editing animated:YES];
}

- (void) setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];

    // Update edit button icon
    UIImage* editImage = editing ? [UIImage systemImageNamed:@"checkmark"] : [UIImage systemImageNamed:@"pencil"];
    self.navigationItem.rightBarButtonItem.image = editImage;

    [self _updateToolbarItemsAnimated:YES];
}


- (void) addAction:(id)sender
{
    EpisodeListEditorViewController* controller = [EpisodeListEditorViewController episodeListEditorViewControllerWithList:nil];
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
    [self presentViewController:navController animated:YES completion:^{
        
    }];
}


- (void) actionAction:(id)sender
{
    OptionsViewController* optionsViewController = [OptionsViewController optionsViewController];
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:optionsViewController];
    
    [self presentViewController:navController animated:YES completion:^{
    }];
}

- (void) refresh:(id)sender
{
    [[SubscriptionManager sharedSubscriptionManager] refreshAllFeedsForce:YES etagHandling:YES completion:^(BOOL success, NSArray* newEpisodes, NSError* error) {
        if (error) {
            [self presentError:error];
        }
    }];
}


#pragma mark -
#pragma mark Gestures

- (void) handleLongPress:(UILongPressGestureRecognizer*)recognizer
{
	if (recognizer.state == UIGestureRecognizerStateBegan && !self.tableView.editing)
	{
        CGPoint location = [recognizer locationInView:self.tableView];
		NSIndexPath *rowIndexPath = [self.tableView indexPathForRowAtPoint:location];
        
        // long pressing on an empty cell not allowed
        if (!rowIndexPath || rowIndexPath.row >= [DMANAGER.lists count]) {
            return;
        }
        
        CDEpisodeList* list = [DMANAGER.lists objectAtIndex:rowIndexPath.row];

        if ([list isKindOfClass:[CDEpisodeList class]])
        {
            EpisodeListEditorViewController* controller = [EpisodeListEditorViewController episodeListEditorViewControllerWithList:list];
            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            [self presentViewController:navController animated:YES completion:^{
                
            }];
        }
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
