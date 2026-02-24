//
//  ListEpisodesTableViewController.m
//  Instacast
//
//  Created by Martin Hering on 21.08.14.
//
//

#import "ListEpisodesTableViewController.h"
#import "ToolbarLabelsViewController.h"
#import "EpisodeListEditorViewController.h"
#import "EpisodePlayComboButton.h"
#import "ICRefreshControl.h"

#define EPISODE_PAGE_SIZE 25

@interface ListEpisodesTableViewController ()
@property (nonatomic) NSInteger loadPages;
@property (nonatomic) NSArray* allEpisodes;
@end

@implementation ListEpisodesTableViewController {
    BOOL _list_episodes_observing;
    BOOL _didRestoreScrollPosition;
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

+ (instancetype) viewControllerWithList:(CDEpisodeList*)list
{
    ListEpisodesTableViewController* controller = [[self alloc] initWithStyle:UITableViewStylePlain];
    controller.list = list;
    return controller;
}

- (void) _setObserving:(BOOL)observing
{
    [super _setObserving:observing];
    
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
    
    if (observing && !_list_episodes_observing)
    {
        __weak ListEpisodesTableViewController* weakSelf = self;
        
        [self addTaskObserver:self forKeyPath:@"list.numberOfEpisodes" task:^(id obj, NSDictionary *change) {
            [weakSelf _updateToolbarLabels];
            
            if (!weakSelf.userAction) {
                [weakSelf updateEpisodes];
                [weakSelf reloadDataAndPreserveSelection];

                [weakSelf _updateToolbarItemsAnimated:NO];
                [weakSelf _updateToolbarLabels];
            }
        }];
        
        [nc addObserver:self name:SubscriptionManagerDidStartRefreshingFeedsNotification object:nil handler:^(NSNotification *notification) {
            [self.refreshControl beginRefreshing];
        }];
        
        [nc addObserver:self name:SubscriptionManagerDidFinishRefreshingFeedsNotification object:nil handler:^(NSNotification *notification) {
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
        }];
        
        [sman addTaskObserver:self forKeyPath:@"formattedLastRefreshDate" task:^(id obj, NSDictionary *change) {
            ((ICRefreshControl*)self.refreshControl).idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDate];
        }];

        [sman addTaskObserver:self forKeyPath:@"refreshStatusText" task:^(id obj, NSDictionary *change) {
            SubscriptionManager* sm = [SubscriptionManager sharedSubscriptionManager];
            if (sm.refreshing) {
                ((ICRefreshControl*)self.refreshControl).refreshText = sm.refreshStatusText;
            }
        }];

        _list_episodes_observing = YES;
    }
    else if (!observing && _list_episodes_observing)
    {
        [self removeTaskObserver:self forKeyPath:@"list.numberOfEpisodes"];
        
        [nc removeHandlerForObserver:self name:SubscriptionManagerDidStartRefreshingFeedsNotification object:nil];
        [nc removeHandlerForObserver:self name:SubscriptionManagerDidFinishRefreshingFeedsNotification object:nil];
        
        [sman removeTaskObserver:self forKeyPath:@"formattedLastRefreshDate"];
        [sman removeTaskObserver:self forKeyPath:@"refreshStatusText"];
        _list_episodes_observing = NO;
    }
}

- (void) viewDidLoad
{
    [super viewDidLoad];
    
    self.title = self.list.name;
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(editButtonAction:)];

    ICRefreshControl* refreshControl = [[ICRefreshControl alloc] init];
    refreshControl.pulldownText = @"Pull to refresh…".ls;
    refreshControl.refreshText = @"Looking for new episodes…".ls;
    refreshControl.idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDate];
    [refreshControl addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = refreshControl;
}

- (void) editButtonAction:(id)sender
{
    EpisodeListEditorViewController* controller = [EpisodeListEditorViewController episodeListEditorViewControllerWithList:self.list];
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
    [self presentViewController:navController animated:YES completion:NULL];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _didRestoreScrollPosition = NO;
    
    // edit button is always enabled - it opens the list editor
    self.navigationItem.rightBarButtonItem.enabled = YES;
    
    [self updateEpisodes];
    [self reloadDataAndPreserveSelection];
    [self _updateToolbarLabels];
    
    // Dispatch to avoid "offscreen beginRefreshing" warning
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
    [self _restoreScrollPositionIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self _storeScrollPosition];
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

- (NSArray*) _loadNextPage
{
    NSInteger numEpisodes = [self.allEpisodes count];
    
    NSInteger start = MIN(numEpisodes, self.loadPages * EPISODE_PAGE_SIZE);
    NSInteger end = MIN(numEpisodes, start+EPISODE_PAGE_SIZE);
    
    if (end-start <= 0) {
        return nil;
    }
    
    NSArray* newEpisodes = [self.allEpisodes subarrayWithRange:NSMakeRange(start, end-start)];
    if (self.episodes) {
        self.episodes = [self.episodes arrayByAddingObjectsFromArray:newEpisodes];
    } else {
        self.episodes = newEpisodes;
    }
    self.loadPages++;

    return newEpisodes;
}

- (void) updateEpisodes
{
    self.allEpisodes = [self.list sortedEpisodes];
    self.loadPages = 0;
    self.episodes = nil;
    [self _loadNextPage];
}

- (void)enumerateEpisodesUsingBlock:(void (^)(CDEpisode* episode, NSUInteger idx, BOOL *stop))block
{
    [self.allEpisodes enumerateObjectsUsingBlock:block];
}

- (NSString*) _scrollPersistenceKey
{
    NSString* listKey = self.list.uid;
    if ([listKey length] == 0) {
        listKey = self.list.name;
    }
    if ([listKey length] == 0) {
        return @"listEpisodes.unknown";
    }
    return [NSString stringWithFormat:@"listEpisodes.%@", listKey];
}

- (void) _restoreScrollPositionIfNeeded
{
    if (_didRestoreScrollPosition) {
        return;
    }
    _didRestoreScrollPosition = YES;

    NSString* key = [self _scrollPersistenceKey];
    NSNumber* storedOffset = ICListScrollPositionForKey(key);
    if (storedOffset) {
        CGFloat targetOffset = storedOffset.doubleValue;
        CGFloat requiredHeight = targetOffset + CGRectGetHeight(self.tableView.bounds);
        [self.tableView layoutIfNeeded];

        // Ensure enough pages are loaded before restoring a deep scroll offset.
        while (self.episodes.count < self.allEpisodes.count &&
               self.tableView.contentSize.height < requiredHeight) {
            NSArray* newEpisodes = [self _loadNextPage];
            if ([newEpisodes count] == 0) {
                break;
            }
            [self reloadDataAndPreserveSelection];
            [self.tableView layoutIfNeeded];
        }
    }

    ICRestoreScrollPositionForScrollView(key, self.tableView);
}

- (void) _storeScrollPosition
{
    ICStoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView);
}

#pragma mark -

- (NSInteger) _playbackTime
{
    NSInteger playbackTime = 0;
    for(CDEpisode* episode in self.allEpisodes) {
        playbackTime += episode.duration;
    }
    
    return playbackTime;
}

- (void) _updateToolbarLabels
{
    NSInteger numEpisodes = [self.list numberOfEpisodes];
    
    if (numEpisodes == 0) {
        self.toolbarLabelsViewController.mainText = @"No Episodes".ls;
        self.toolbarLabelsViewController.auxiliaryText = @"";
    }
    else
    {
        self.toolbarLabelsViewController.mainText = (numEpisodes == 1) ? @"1 Episode".ls : [NSString stringWithFormat:@"%d Episodes".ls, numEpisodes];
        
        NSInteger duration = [self _playbackTime];
        NSValueTransformer* durationTransformer = [NSValueTransformer valueTransformerForName:kICDurationValueTransformer];
        NSString* durString = [durationTransformer transformedValue:@(duration)];
        self.toolbarLabelsViewController.auxiliaryText = durString;
    }
    
    
    [self.toolbarLabelsViewController layout];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    CGSize size = scrollView.contentSize;
    if (size.height == 0) {
        return;
    }
    
    UIEdgeInsets insets = scrollView.contentInset;
    CGPoint offset = scrollView.contentOffset;
    CGPoint bottomScroll = CGPointMake(0, size.height - CGRectGetHeight(scrollView.frame) + insets.top);
    
    if (offset.y > bottomScroll.y) {
        NSArray* newEpisodes = [self _loadNextPage];
        if ([newEpisodes count] > 0) {
            [self reloadDataAndPreserveSelection];
        }
    }
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

- (void) playComboButtonAction:(EpisodePlayComboButton*)button
{
    [super playComboButtonAction:button];
    
    if ((button.comboState != kEpisodePlayButtonComboStateFilling || button.comboState != kEpisodePlayButtonComboStateHolding) && self.list.continuousPlayback)
    {
        AudioSession* session = [AudioSession sharedAudioSession];
        [session eraseAllEpisodesFromUpNext];
        
        CDEpisode* episode = (CDEpisode*)button.userInfo;
        NSInteger location = [self.allEpisodes indexOfObject:episode];
        
        if (location != NSNotFound)
        {
            if (location+1 < [self.episodes count])
            {
                AudioSession* session = [AudioSession sharedAudioSession];
                
                // add only 10 episodes to up next
                NSInteger length = MIN([self.allEpisodes count]-location-1, 10);
                NSArray* remainingEpisodes = [self.allEpisodes subarrayWithRange:NSMakeRange(location+1, length)];
                [session appendToUpNext:remainingEpisodes];
            }
        }
    }
}

#pragma mark - Editing
/*
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    CDEpisode* episode = [self.episodes objectAtIndex:indexPath.row];
    
    [[self mutableArrayValueForKey:@"episodes"] removeObjectAtIndex:indexPath.row];

    [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
    [DMANAGER setEpisode:episode archived:YES];
    
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleDelete;
}
*/

#pragma mark - Archiving

- (void) addAdditionalButtonsToLongPressActionSheet:(UIAlertController*)sheet rowIndexPath:(NSIndexPath*)indexPath completionBlock:(void (^)(void))completionBlock
{
    WEAK_SELF
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    [self archiveEpisodesAtRowAtIndexPath:indexPath];
                                                } afterDelay:0.3];
                                                completionBlock();
                                            }]];
}

- (NSArray<UIMenuElement*>*) additionalContextMenuActionsForIndexPath:(NSIndexPath*)indexPath
{
    WEAK_SELF
    UIAction* deleteAction = [UIAction actionWithTitle:@"Delete".ls
                                                 image:[UIImage systemImageNamed:@"trash"]
                                            identifier:nil
                                               handler:^(UIAction *action) {
                                                   STRONG_SELF
                                                   [self archiveEpisodesAtRowAtIndexPath:indexPath];
                                               }];
    deleteAction.attributes = UIMenuElementAttributesDestructive;
    return @[deleteAction];
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
    
    self.userAction = YES;
    
    CDEpisode* episode = [self.episodes objectAtIndex:indexPath.row];
    
    [[self mutableArrayValueForKey:@"episodes"] removeObjectAtIndex:indexPath.row];
    [[self mutableArrayValueForKey:@"allEpisodes"] removeObjectAtIndex:indexPath.row];
    
    [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
    [DMANAGER setEpisode:episode archived:YES];
    //[DMANAGER markEpisode:episode asDownloaded:NO];
    
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
    
    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
    
    self.userAction = NO;
}
@end
