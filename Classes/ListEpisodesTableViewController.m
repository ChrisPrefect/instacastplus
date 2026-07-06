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
#import "CDList.h"
#import "CDEpisodeList.h"
#import "CDPlaylist.h"
#import "CDSmartPlaylist.h"
#import "DatabaseManager.h"

#define EPISODE_PAGE_SIZE 25

@interface ListEpisodesTableViewController ()
@property (nonatomic) NSInteger loadPages;
@property (nonatomic) NSArray* allEpisodes;
@property (nonatomic) NSInteger episodesLoadGeneration;
@end

@implementation ListEpisodesTableViewController {
    BOOL _list_episodes_observing;
    BOOL _didRestoreScrollPosition;
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

+ (instancetype) viewControllerWithList:(CDList*)list
{
    ListEpisodesTableViewController* controller = [[self alloc] initWithStyle:UITableViewStylePlain];
    controller.list = list;
    return controller;
}

- (BOOL)_showsEditorButton
{
    return [self.list isKindOfClass:[CDEpisodeList class]];
}

- (BOOL)_allowsPullToRefresh
{
    return ![self.list isKindOfClass:[CDSmartPlaylist class]];
}

- (CDPlaylist*)_playlist
{
    if (![self.list isKindOfClass:[CDPlaylist class]]) {
        return nil;
    }
    return (CDPlaylist*)self.list;
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
            if (weakSelf.suppressNextListReload) {
                weakSelf.suppressNextListReload = NO;
                [weakSelf _updateToolbarItemsAnimated:NO];
                [weakSelf _updateToolbarLabels];
                return;
            }

            if (!weakSelf.userAction) {
                // During a refresh every merged feed bumps the count — refetching and reloading
                // the whole list per feed contends with the merges for the main thread (the
                // pull-to-refresh stutter). Coalesce to one reload per second while refreshing,
                // same pattern as SubscriptionsTableViewController.
                if ([SubscriptionManager sharedSubscriptionManager].refreshing) {
                    [weakSelf coalescedPerformSelector:@selector(_reloadListAfterCountChange) afterDelay:1.0];
                }
                else {
                    [weakSelf _reloadListAfterCountChange];
                }
            }
        }];
        
        if ([self _allowsPullToRefresh]) {
            [nc addObserver:self name:SubscriptionManagerDidStartRefreshingFeedsNotification object:nil handler:^(NSNotification *notification) {
                if (self.isViewLoaded && self.view.window) {
                    [self.refreshControl beginRefreshing];
                }
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
        }

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

- (void) _reloadListAfterCountChange
{
    // A coalesced reload can fire after a swipe action armed suppressNextListReload —
    // consume it here too so the swipe's row-level update is not followed by a full
    // reload that shifts the scroll position.
    if (self.suppressNextListReload) {
        self.suppressNextListReload = NO;
        [self _updateToolbarItemsAnimated:NO];
        [self _updateToolbarLabels];
        return;
    }
    if (self.userAction) {
        return;
    }
    [self updateEpisodes];
    [self reloadDataAndPreserveSelection];

    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];
}

- (void) viewDidLoad
{
    [super viewDidLoad];
    
    self.title = self.list.name;

    if ([self _showsEditorButton]) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
                                                                                    style:UIBarButtonItemStylePlain
                                                                                   target:self
                                                                                   action:@selector(editButtonAction:)];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }

    if ([self _allowsPullToRefresh]) {
        ICRefreshControl* refreshControl = [[ICRefreshControl alloc] init];
        refreshControl.pulldownText = @"Pull to refresh…".ls;
        refreshControl.refreshText = @"Looking for new episodes…".ls;
        refreshControl.idleText = [[SubscriptionManager sharedSubscriptionManager] formattedLastRefreshDate];
        [refreshControl addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
        self.refreshControl = refreshControl;
    }
}

- (void) editButtonAction:(id)sender
{
    if (![self _showsEditorButton]) {
        return;
    }

    EpisodeListEditorViewController* controller = [EpisodeListEditorViewController episodeListEditorViewControllerWithList:(CDEpisodeList*)self.list];
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
    [self presentViewController:navController animated:YES completion:NULL];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _didRestoreScrollPosition = NO;

    if (self.navigationItem.rightBarButtonItem) {
        self.navigationItem.rightBarButtonItem.enabled = YES;
    }
    
    [self updateEpisodes];
    [self reloadDataAndPreserveSelection];
    [self _updateToolbarLabels];
    
    // Dispatch to avoid "offscreen beginRefreshing" warning
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self _allowsPullToRefresh]) {
            return;
        }
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
    if (![self _allowsPullToRefresh]) {
        [self.refreshControl endRefreshing];
        return;
    }

    [[SubscriptionManager sharedSubscriptionManager] refreshAllFeedsForce:YES etagHandling:YES completion:nil];
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
    NSInteger generation = ++self.episodesLoadGeneration;
    NSManagedObjectID* listID = self.list.objectID;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSArray* episodeIDs = @[];
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        [context performBlockAndWait:^{
            NSError* error = nil;
            CDList* list = (CDList*)[context existingObjectWithID:listID error:&error];
            if (!list || error) {
                return;
            }

            NSArray* episodes = [list sortedEpisodes];
            episodeIDs = [episodes valueForKey:@"objectID"];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.episodesLoadGeneration) {
                return;
            }

            NSMutableArray* episodes = [[NSMutableArray alloc] initWithCapacity:episodeIDs.count];
            for(NSManagedObjectID* episodeID in episodeIDs) {
                NSError* error = nil;
                CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:episodeID error:&error];
                if (episode && !error) {
                    [episodes addObject:episode];
                }
            }

            self.allEpisodes = episodes;
            self.loadPages = 0;
            self.episodes = nil;
            [self _loadNextPage];
            [self reloadDataAndPreserveSelection];
            [self _updateToolbarItemsAnimated:NO];
            [self _updateToolbarLabels];
            [self _restoreScrollPositionIfNeeded];
        });
    });
}

- (void)enumerateEpisodesUsingBlock:(void (^)(CDEpisode* episode, NSUInteger idx, BOOL *stop))block
{
    [self.allEpisodes enumerateObjectsUsingBlock:block];
}

- (BOOL)_episode:(CDEpisode*)episode matchesCurrentEpisodeList:(CDEpisodeList*)list
{
    if (!episode || !list) {
        return YES;
    }

    if (episode.archived || !episode.feed.subscribed) {
        return NO;
    }

    if (!list.audio && !episode.video) {
        return NO;
    }
    if (!list.video && episode.video) {
        return NO;
    }
    if (!list.unplayed && !(episode.consumed || (!episode.consumed && episode.position > 0))) {
        return NO;
    }
    if (!list.unfinished && episode.position != 0) {
        return NO;
    }
    if (!list.played && episode.consumed) {
        return NO;
    }
    if (!list.starred && episode.starred) {
        return NO;
    }
    if (!list.notStarred && !episode.starred) {
        return NO;
    }

    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    BOOL cached = [cacheManager episodeIsCached:episode fastLookup:YES];
    if (!list.downloaded && cached) {
        return NO;
    }
    if (!list.notDownloaded && !cached) {
        return NO;
    }

    if ([list.includedFeeds count] > 0 && ![list.includedFeeds containsObject:episode.feed]) {
        return NO;
    }

    return YES;
}

- (void)_removeEpisode:(CDEpisode*)episode fromArrayProperty:(NSString*)propertyName
{
    NSMutableArray* mutableEpisodes = [[self valueForKey:propertyName] mutableCopy];
    NSUInteger index = [mutableEpisodes indexOfObject:episode];
    if (index == NSNotFound && episode.objectHash.length > 0) {
        index = [mutableEpisodes indexOfObjectPassingTest:^BOOL(id candidate, NSUInteger idx, BOOL* stop) {
            return [[candidate objectHash] isEqualToString:episode.objectHash];
        }];
    }
    if (index != NSNotFound) {
        [mutableEpisodes removeObjectAtIndex:index];
        [self setValue:[mutableEpisodes copy] forKey:propertyName];
    }
}

- (BOOL) _removeEpisodeFromDisplayedListIfNeededAfterMutation:(CDEpisode*)episode atIndexPath:(NSIndexPath*)indexPath
{
    if (![self.list isKindOfClass:[CDEpisodeList class]]) {
        return NO;
    }

    if ([self _episode:episode matchesCurrentEpisodeList:(CDEpisodeList*)self.list]) {
        return NO;
    }

    if (!indexPath || indexPath.row >= [self.episodes count]) {
        return NO;
    }

    self.suppressNextListReload = YES;
    [self _removeEpisode:episode fromArrayProperty:@"episodes"];
    [self _removeEpisode:episode fromArrayProperty:@"allEpisodes"];
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    return YES;
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

    CDEpisodeList* episodeList = [self.list isKindOfClass:[CDEpisodeList class]] ? (CDEpisodeList*)self.list : nil;
    if ((button.comboState != kEpisodePlayButtonComboStateFilling && button.comboState != kEpisodePlayButtonComboStateHolding) &&
        episodeList.continuousPlayback)
    {
        AudioSession* session = [AudioSession sharedAudioSession];
        [session eraseAllEpisodesFromUpNext];
        
        CDEpisode* episode = (CDEpisode*)button.userInfo;
        NSInteger location = [self.allEpisodes indexOfObject:episode];
        
        if (location != NSNotFound)
        {
            if (location+1 < [self.allEpisodes count])
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

- (BOOL) canArchiveEpisodes
{
    return ([self _playlist] == nil);
}

- (void) addAdditionalButtonsToMultiActionSheet:(UIAlertController*)sheet completionBlock:(void (^)(void))completionBlock
{
    CDPlaylist* playlist = [self _playlist];
    if (!playlist) {
        return;
    }

    __block BOOL hasPlayedEpisodes = NO;
    [self.allEpisodes enumerateObjectsUsingBlock:^(CDEpisode* episode, NSUInteger idx, BOOL *stop) {
        if (episode.consumed) {
            hasPlayedEpisodes = YES;
            *stop = YES;
        }
    }];

    if (!hasPlayedEpisodes) {
        return;
    }

    WEAK_SELF
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete all Played".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction* action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    [playlist removeAllPlayedEpisodes];
                                                    [DMANAGER save];
                                                    [self updateEpisodes];
                                                    [self.tableView reloadData];
                                                    [self _updateToolbarItemsAnimated:NO];
                                                    [self _updateToolbarLabels];
                                                } afterDelay:0.3];
                                                completionBlock();
                                            }]];
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
    
    CDPlaylist* playlist = [self _playlist];
    self.userAction = YES;

    CDEpisode* episode = [self.episodes objectAtIndex:indexPath.row];

    // Data source mutation and the row animation MUST be adjacent: the side effects
    // below save and post notifications — removing the cache of the PLAYING episode
    // synchronously stops playback, whose notifications reload this table. With that
    // reload between the array mutation and deleteRows, UITableView asserted
    // ("Invalid number of rows" — TestFlight crash "Beim Löschen einer Folge,
    // während sie lief"). Removing from allEpisodes by OBJECT, not by row: with an
    // active search filter the row indexes of the two arrays differ.
    [self _removeEpisode:episode fromArrayProperty:@"episodes"];
    [self _removeEpisode:episode fromArrayProperty:@"allEpisodes"];
    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];

    if (playlist) {
        [playlist removeEpisode:episode];
        [DMANAGER save];
    } else {
        [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
        [DMANAGER setEpisode:episode archived:YES];
    }

    [self _updateToolbarItemsAnimated:NO];
    [self _updateToolbarLabels];

    self.userAction = NO;
}
@end
