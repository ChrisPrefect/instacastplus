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
#import "STITunesStore.h"
#import "CDFeed+Helper.h"
#import "ICFTSController.h"
#import "InstacastAppDelegate.h"

@interface FeedEpisodesTableViewController() <UIGestureRecognizerDelegate, NSFetchedResultsControllerDelegate, UIScrollViewDelegate>
@property (nonatomic, strong) NSFetchedResultsController* fetchController;
@property (nonatomic, strong) ICFeedHeaderViewController* headerViewController;
@property (nonatomic, strong) UIToolbar* headerToolbar;
@property (nonatomic, strong) UIView* headerToolbarSeparatorView;
@property (nonatomic, weak) UIBarButtonItem* shareItem;
@property (nonatomic, strong) VDModalInfo* modalInfo;
@property (nonatomic, strong) UIView* tableHeaderView;
@property (nonatomic, strong) UIBarButtonItem *filterItem;
@end

@implementation FeedEpisodesTableViewController {
    NSMutableSet* _selectionPreservingIndexPathes;
    BOOL isFirstTimeScrolled;
    BOOL isDownloadedFilter;
}

+ (FeedEpisodesTableViewController*) episodesControllerWithFeed:(CDFeed*)feed
{
	FeedEpisodesTableViewController* controller = [[self alloc] initWithStyle:UITableViewStylePlain];
    controller.feed = feed;
	return controller;
}


- (void) addAdditionalButtonsToLongPressActionSheet:(UIAlertController*)sheet rowIndexPath:(NSIndexPath*)indexPath completionBlock:(void (^)())completionBlock
{
    WEAK_SELF
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
                                                STRONG_SELF
        NSArray *array = @[];
        [self showDeleteConfirmPopUp:1 rowIndexPath:indexPath selectedIndexPathes:array];
                                                completionBlock();
                                            }]];
}

-(void)showDeleteConfirmPopUp:(NSInteger)type rowIndexPath:(NSIndexPath*)indexPathDev selectedIndexPathes:(NSArray*)selectedIndexPathes
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Are you sure you want to delete?".ls message:nil preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Yes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        if (type == 1)
        {
            [self perform:^(id sender) {
                [self archiveEpisodesAtRowAtIndexPath:indexPathDev];
            } afterDelay:0.3];
        }
        else
        {
            [self perform:^(id sender) {
                NSMutableArray* myEpisodes = [self.episodes mutableCopy];
                for(NSIndexPath* indexPath in selectedIndexPathes)
                {
                    if (indexPath.row < [myEpisodes count]) {
                        CDEpisode* episode = myEpisodes[indexPath.row];
                        episode.archived = YES;
                        //[DMANAGER markEpisode:episode asDownloaded:NO];
                        [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
                    }
                }
                [DMANAGER save];
                
                [self updateEpisodes];
                [self _updateToolbarItemsAnimated:NO];
            } afterDelay:0.3];
        }
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

- (void) addAdditionalButtonsToMultiSelectEditActionSheet:(UIAlertController*)sheet selectedIndexPathes:(NSArray*)selectedIndexPathes completionBlock:(void (^)())completionBlock
{
    WEAK_SELF
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
        [self showDeleteConfirmPopUp:2 rowIndexPath:[NSIndexPath indexPathForRow:0 inSection:0] selectedIndexPathes:selectedIndexPathes];
        completionBlock();
                                                completionBlock();
                                            }]];
}


#pragma mark -
#pragma mark View lifecycle

- (void) updateEpisodes
{
    if (!self->isDownloadedFilter)
    {
        self.episodes = [self.fetchController fetchedObjects];
    }
}

- (BOOL) showsImage
{
    return NO;
}

- (void) _updateFetchController
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    if ([self.searchTerm length] > 0)
    {
        NSSet* episodeGuids = [DMANAGER.ftsController episodeUIDsForSearchTerm:self.searchTerm];
        
        NSString* t = [NSString stringWithFormat:@"*%@*", self.searchTerm];
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == %@ && (guid IN %@ || feed.title like[cd] %@ || feed.author like[cd] %@ || feed.summary like[cd] %@)", self.feed, @NO, episodeGuids, t, t, t];
        
    } else {
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == %@", self.feed, @NO];
    }
    
    fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
    
    NSString* cacheName = [NSString stringWithFormat:@"_feed_episodes_%@", self.feed.title];
    [NSFetchedResultsController deleteCacheWithName:cacheName];
    self.fetchController = [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:cacheName];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    
    [self updateEpisodes];
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
    //NSLog(@"==DEVD CONTROLLER DID CHANGE CONTENT STARTED==");
    if (self.userAction) {
        return;
    }
    [self updateEpisodes];
    //NSLog(@"Before endUpdates111: %lu rows in section 0", [self.tableView numberOfRowsInSection:0]);
    [self.tableView endUpdates];//crashes
    //NSLog(@"Before endUpdates222: %lu rows in section 0", [self.tableView numberOfRowsInSection:0]);
    [self _updateToolbarLabels];
    
    for (NSIndexPath* indexPath in _selectionPreservingIndexPathes) {
        [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    }
    
    _selectionPreservingIndexPathes = nil;

    //NSLog(@"==DEVD CONTROLLER DID CHANGE CONTENT ENDED==");
}

#pragma mark -

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;
    self.title = ([self.searchTerm length] > 0) ? [NSString stringWithFormat:@"'%@'", self.searchTerm].ls : nil;
    
    WEAK_SELF
    self.editingStyle = EpisodesTableViewEditingStyleNormal;
    
    {
        CGFloat w = CGRectGetWidth(self.view.bounds);
        self.tableHeaderView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 93+45)];
        self.tableHeaderView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
        
        self.headerViewController = [ICFeedHeaderViewController viewController];
        self.headerViewController.view.frame = CGRectMake(0, 0, w, 93);
        self.headerViewController.titleLabel.text = self.feed.title;
        self.headerViewController.subtitleLabel.text = self.feed.author;
        
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

        self.headerViewController.action = ^() {
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
        
        self.headerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 94, w, 44)];
        self.headerToolbar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
        [self.headerToolbar setShadowImage:[[UIImage alloc] init] forToolbarPosition:UIBarPositionAny];
        [self.tableHeaderView addSubview:self.headerToolbar];
        
        [self _updateHeaderToolbar];
    }
    
    //[self updateEpisodes];
    [self _updateToolbarItemsAnimated:NO];
}

- (void) _updateHeaderToolbar
{
    UIBarButtonItem* reloadItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"refreshd_ic"] style:UIBarButtonItemStylePlain target:self action:@selector(reload:)];
    UIBarButtonItem* shareItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"sharedd_ic"] style:UIBarButtonItemStylePlain target:self action:@selector(share:)];
    UIBarButtonItem* settingsItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"settingd_ic"] style:UIBarButtonItemStylePlain target:self action:@selector(settings:)];
    
    _filterItem = [[UIBarButtonItem alloc] initWithTitle: @"All".ls style:UIBarButtonItemStylePlain target:self action:@selector(filterAction:)];
    
    UIBarButtonItem* fixItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace target:nil action:nil];
    fixItem.width = -1;
    
    UIBarButtonItem* flexItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    
    [self.headerToolbar setItems:@[reloadItem, flexItem, shareItem, flexItem, settingsItem, flexItem, _filterItem]];
    self.shareItem = shareItem;
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
    
    CGFloat w = CGRectGetWidth(self.view.bounds);
    self.headerToolbar.frame = CGRectMake(0, 94, w, 44);
    
    [self.headerToolbar setBackgroundImage:ICImageFromByDrawingInContext(CGSizeMake(1, 1), ^() {
        [ICBackgroundColor set];
        UIRectFill(CGRectMake(0, 0, 1, 1));
    }) forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault];
    self.headerToolbarSeparatorView.backgroundColor = ICTableSeparatorColor;
    
    
    if ([self.searchTerm length] > 0)
    {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Close"] style:UIBarButtonItemStylePlain target:self action:@selector(toolbarCloseButtonAction:)];
                                                  
    }
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
    
    if ([[NSUserDefaults standardUserDefaults] objectForKey:_feed.uid] != nil){
        NSString* filterOptionStr = [[NSUserDefaults standardUserDefaults] valueForKey:_feed.uid];
        if ([filterOptionStr  isEqual: @"All"])
        {
            self->isDownloadedFilter = false;
            [self _filterAllEpisode];
            self.filterItem.title = @"All".ls;
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Unplayed"])
        {
            self->isDownloadedFilter = false;
            [self _filterUnlistenedEpisode];
            self.filterItem.title = @"Unplayed".ls;
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Unfinished"])
        {
            self->isDownloadedFilter = false;
            [self _filterUnfinishedEpisode];
            self.filterItem.title = @"Unfinished".ls;
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Downloaded"])
        {
            self->isDownloadedFilter = true;
            [self _filterDownloadedEpisode];
            self.filterItem.title = @"Downloaded".ls;
            [self reloadDataWithFilter:YES];
        }
        else if ([filterOptionStr  isEqual: @"Favorites"])
        {
            self->isDownloadedFilter = false;
            [self _filterFavoriteEpisode];
            self.filterItem.title = @"Favorites".ls;
            [self reloadDataWithFilter:YES];
        }
        else
        {
            self->isDownloadedFilter = false;
            [self _filterAllEpisode];
            self.filterItem.title = @"All".ls;
            [self reloadDataWithFilter:YES];
        }
    }
    else
    {
        self->isDownloadedFilter = false;
        [self _filterAllEpisode];
        self.filterItem.title = @"All".ls;
        [self reloadDataWithFilter:YES];
    }
}

- (void) reloadDataWithFilter:(BOOL)isScrolled
{
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
    
    [self reloadDataAndPreserveSelection];
    self.tableView.tableHeaderView = ([self.searchTerm length] == 0) ? self.tableHeaderView : nil;
    self.headerToolbar.frame = CGRectMake(0, 94, CGRectGetWidth(self.tableHeaderView.frame), 44);

    if (isScrolled)
    {
        [self srollToLastScrollingPosition];
    }
}

- (void) reloadData
{
    [self _updateFetchController];
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
    
    [self reloadDataAndPreserveSelection];
    self.tableView.tableHeaderView = ([self.searchTerm length] == 0) ? self.tableHeaderView : nil;
    self.headerToolbar.frame = CGRectMake(0, 94, CGRectGetWidth(self.tableHeaderView.frame), 44);

    [self srollToLastScrollingPosition];
}


- (void) srollToLastScrollingPosition
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([[NSUserDefaults standardUserDefaults] objectForKey:[NSString stringWithFormat:@"%@_visible_row", _feed.uid]] != nil)
        {
            if (!self->isFirstTimeScrolled)
            {
                self->isFirstTimeScrolled = true;
                NSInteger lastIndexToScroll = [[NSUserDefaults standardUserDefaults] integerForKey:[NSString stringWithFormat:@"%@_visible_row", _feed.uid]];
                if (lastIndexToScroll < self.episodes.count)
                {
                    if (lastIndexToScroll > 0)
                    {
                        [self.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:lastIndexToScroll inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
                    }
                }
            }
        }
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    NSArray *visibleIndexPaths = [self.tableView indexPathsForVisibleRows];
    if (visibleIndexPaths.count > 0) {
        NSInteger visibleRow = [visibleIndexPaths.firstObject row];
        [[NSUserDefaults standardUserDefaults] setInteger:visibleRow forKey:[NSString stringWithFormat:@"%@_visible_row", _feed.uid]];
        [[NSUserDefaults standardUserDefaults] synchronize];
        //NSLog(@"VISIble stored row====%ld",(long)visibleRow);
    }
}

- (void) updateAppearance
{
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.tableView.backgroundColor = ICBackgroundColor;
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    [self.headerToolbar setBackgroundImage:ICImageFromByDrawingInContext(CGSizeMake(1, 1), ^() {
        [ICBackgroundColor set];
        UIRectFill(CGRectMake(0, 0, 1, 1));
    })
                        forToolbarPosition:UIToolbarPositionAny
                                barMetrics:UIBarMetricsDefault];
    self.headerToolbarSeparatorView.backgroundColor = ICTableSeparatorColor;
}

- (void) toolbarCloseButtonAction:(id)sender
{
    self.navigationItem.rightBarButtonItem = nil;
    self.searchTerm = nil;
    self.title = nil;
    [self reloadData];
}

- (void) playerCloseButtonAction:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:NULL];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
        [sman autoDownloadEpisodesInFeed:self.feed];
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
    NSURL* feedURL = [self.feed sourceURLAsPcastURL];
    
    UIActivityViewController* shareController = [[UIActivityViewController alloc] initWithActivityItems:@[feedURL] applicationActivities:nil];
    if ([shareController respondsToSelector:@selector(popoverPresentationController)]) {
        shareController.popoverPresentationController.barButtonItem = sender;
    }
    [self presentViewController:shareController animated:YES completion:NULL];
}


- (void) filterAction:(UIBarButtonItem*)item
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Filter by".ls message:nil  preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction* allAction = [UIAlertAction actionWithTitle:@"All".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            self->isDownloadedFilter = false;
            [self _filterAllEpisode];
            self.filterItem.title = @"All".ls;
            [[NSUserDefaults standardUserDefaults] setValue:@"All" forKey:_feed.uid];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self reloadDataWithFilter:NO];
        } afterDelay:0.01];
        self.alertController = nil;
    }];
    [alert addAction:allAction];
    
    UIAlertAction* unlistenedAction = [UIAlertAction actionWithTitle:@"Unplayed".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            self->isDownloadedFilter = false;
            [self _filterUnlistenedEpisode];
            self.filterItem.title = @"Unplayed".ls;
            [[NSUserDefaults standardUserDefaults] setValue:@"Unplayed" forKey:_feed.uid];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self reloadDataWithFilter:NO];
        } afterDelay:0.01];
        self.alertController = nil;
        
    }];
    [alert addAction:unlistenedAction];
    
    UIAlertAction* unFinishedAction = [UIAlertAction actionWithTitle:@"Unfinished".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            self->isDownloadedFilter = false;
            [self _filterUnfinishedEpisode];
            self.filterItem.title = @"Unfinished".ls;
            [[NSUserDefaults standardUserDefaults] setValue:@"Unfinished" forKey:_feed.uid];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self reloadDataWithFilter:NO];
        } afterDelay:0.01];
        self.alertController = nil;
        
    }];
    [alert addAction:unFinishedAction];
    
    UIAlertAction* downloadedAction = [UIAlertAction actionWithTitle:@"Downloaded".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            self->isDownloadedFilter = true;
            [self _filterDownloadedEpisode];
            self.filterItem.title = @"Downloaded".ls;
            [[NSUserDefaults standardUserDefaults] setValue:@"Downloaded" forKey:_feed.uid];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self reloadDataWithFilter:NO];
        } afterDelay:0.01];
        self.alertController = nil;
        
    }];
    [alert addAction:downloadedAction];
    
    UIAlertAction* favoritesAction = [UIAlertAction actionWithTitle:@"Favorites".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            self->isDownloadedFilter = false;
            [self _filterFavoriteEpisode];
            self.filterItem.title = @"Favorites".ls;
            [[NSUserDefaults standardUserDefaults] setValue:@"Favorites" forKey:_feed.uid];
            [[NSUserDefaults standardUserDefaults] synchronize];
            [self reloadDataWithFilter:NO];
        } afterDelay:0.01];
        
        self.alertController = nil;
    }];
    [alert addAction:favoritesAction];
    
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        STRONG_SELF
        self.alertController = nil;
    }];
    [alert addAction:defaultAction];
    
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

#pragma mark - Filter By Favorite
- (void) _filterFavoriteEpisode
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && starred == %d", self.feed, 1];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    NSString* cacheName = [NSString stringWithFormat:@"_feed_episodes_favorite_%@", self.feed.title];
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];
 
    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:cacheName];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By Unlistened
- (void) _filterUnlistenedEpisode
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && consumed == %d && position <= %d", self.feed,0,0];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    NSString* cacheName = [NSString stringWithFormat:@"_feed_episodes_unlistened_%@", self.feed.title];
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];
 
    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:cacheName];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By All
- (void) _filterAllEpisode
{
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    if ([self.searchTerm length] > 0)
    {
        NSSet* episodeGuids = [DMANAGER.ftsController episodeUIDsForSearchTerm:self.searchTerm];
        
        NSString* t = [NSString stringWithFormat:@"*%@*", self.searchTerm];
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == %@ && (guid IN %@ || feed.title like[cd] %@ || feed.author like[cd] %@ || feed.summary like[cd] %@)", self.feed, @NO, episodeGuids, t, t, t];
        
    } else {
        fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ && archived == %@", self.feed, @NO];
    }
    
    fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder] ];
    
    NSString* cacheName = [NSString stringWithFormat:@"_feed_episodes_all_%@", self.feed.title];
    [NSFetchedResultsController deleteCacheWithName:cacheName];
    self.fetchController = [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:cacheName];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

#pragma mark - Filter By Unfinished/Started_Playing
- (void) _filterUnfinishedEpisode
{
    //[NSPredicate predicateWithFormat:@"feed == %@ AND consumed == %@ AND archived == %@", self, @NO, @NO] --Unplayed
    BOOL reverseOrder = ([[self.feed stringForKey:FeedSortOrder] isEqualToString:SortOrderOlderFirst]);
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"feed == %@ && position > %d", self.feed,0];
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = predicate;
    NSString* cacheName = [NSString stringWithFormat:@"_feed_episodes_unfinished_%@", self.feed.title];
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:reverseOrder]];
    
    self.fetchController =  [[NSFetchedResultsController alloc] initWithFetchRequest:fetchRequest managedObjectContext:DMANAGER.objectContext sectionNameKeyPath:nil cacheName:cacheName];
    self.fetchController.delegate = self;
    [self.fetchController performFetch:nil];
    [self updateEpisodes];
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
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

-(void) downloadedUpdateEpisodes
{
    self.episodes = nil;
    NSMutableArray *downloadedArray = [NSMutableArray array];
    NSArray* cachedEpisodes = [CacheManager sharedCacheManager].cachedEpisodes;
    for(CDEpisode* episode in cachedEpisodes) {
        if ([episode.feed isEqual:self.feed]) {
            [downloadedArray addObject:episode];
        }
    }
    self.episodes = downloadedArray;
    [self.tableView reloadData];
    [self.tableView layoutIfNeeded];
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

@end

