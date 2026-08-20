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
@property (nonatomic) NSInteger episodesLoadGeneration;
@property (nonatomic, strong) NSMutableArray<CDEpisode*>* loadedEpisodes;
@property (nonatomic) NSUInteger nextPageOffset;
@property (nonatomic) BOOL loadingPage;
@property (nonatomic) BOOL reachedListEnd;
@property (nonatomic, strong) NSError* pageError;
@property (nonatomic) BOOL statisticsLoaded;
@property (nonatomic) NSUInteger totalEpisodeCount;
@property (nonatomic) NSInteger totalPlaybackTime;
@property (nonatomic) NSUInteger playedEpisodeCount;
@property (nonatomic) NSUInteger playedDownloadedEpisodeCount;
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

- (NSURL*) artworkURLForEpisode:(CDEpisode*)episode
{
    CDEpisodeList* episodeList = [self.list isKindOfClass:[CDEpisodeList class]] ? (CDEpisodeList*)self.list : nil;
    if (episodeList.usePodcastArtwork) {
        return episode.feed.imageURL;
    }
    return [super artworkURLForEpisode:episode];
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
    if ([self _deferEpisodeReloadDuringInteraction]) {
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

- (void)_updatePageFooter
{
    if (self.pageError) {
        UIButton* retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        retryButton.frame = CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 72.0);
        retryButton.titleLabel.numberOfLines = 0;
        retryButton.titleLabel.textAlignment = NSTextAlignmentCenter;
        retryButton.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        [retryButton setTitle:@"Episodes could not be loaded. Tap to try again.".ls forState:UIControlStateNormal];
        [retryButton addTarget:self action:@selector(_retryPageLoad:) forControlEvents:UIControlEventTouchUpInside];
        retryButton.accessibilityHint = @"Retry".ls;
        self.tableView.tableFooterView = retryButton;
        return;
    }

    if (self.loadingPage) {
        UIView* footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 44.0)];
        UIActivityIndicatorView* spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.center = CGPointMake(CGRectGetMidX(footer.bounds), CGRectGetMidY(footer.bounds));
        spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [spinner startAnimating];
        [footer addSubview:spinner];
        self.tableView.tableFooterView = footer;
        return;
    }

    self.tableView.tableFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
}

- (void)_retryPageLoad:(id)sender
{
    (void)sender;
    self.pageError = nil;
    [self _loadNextPage];
}

- (void) _loadNextPage
{
    if (self.loadingPage || self.reachedListEnd || self.pageError) {
        return;
    }

    self.loadingPage = YES;
    [self _updatePageFooter];

    NSInteger generation = self.episodesLoadGeneration;
    NSUInteger offset = self.nextPageOffset;
    NSManagedObjectID* listID = self.list.objectID;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSArray<NSManagedObjectID*>* episodeIDs = nil;
        __block NSError* pageError = nil;
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        [context performBlockAndWait:^{
            CDList* list = (CDList*)[context existingObjectWithID:listID error:&pageError];
            if (!list || pageError) {
                return;
            }

            NSArray<CDEpisode*>* page = [list sortedEpisodesWithOffset:offset
                                                                  limit:EPISODE_PAGE_SIZE
                                                                  error:&pageError];
            if (page) {
                episodeIDs = [page valueForKey:@"objectID"];
            }
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.episodesLoadGeneration) {
                return;
            }

            self.loadingPage = NO;
            if (pageError) {
                self.pageError = pageError;
                [self _updatePageFooter];
                return;
            }

            NSUInteger oldCount = self.loadedEpisodes.count;
            NSMutableArray<CDEpisode*>* pageEpisodes = [[NSMutableArray alloc] initWithCapacity:episodeIDs.count];
            for(NSManagedObjectID* episodeID in episodeIDs) {
                NSError* error = nil;
                CDEpisode* episode = (CDEpisode*)[DMANAGER.objectContext existingObjectWithID:episodeID error:&error];
                if (episode && !error) {
                    [pageEpisodes addObject:episode];
                }
            }

            [self.loadedEpisodes addObjectsFromArray:pageEpisodes];
            self.episodes = self.loadedEpisodes;
            self.nextPageOffset = offset + episodeIDs.count;
            self.reachedListEnd = episodeIDs.count < EPISODE_PAGE_SIZE;
            if (self.statisticsLoaded && self.nextPageOffset >= self.totalEpisodeCount) {
                self.reachedListEnd = YES;
            }

            if (oldCount == 0) {
                [self reloadDataAndPreserveSelection];
            }
            else if (pageEpisodes.count > 0) {
                NSMutableArray<NSIndexPath*>* indexPaths = [[NSMutableArray alloc] initWithCapacity:pageEpisodes.count];
                for (NSUInteger index = oldCount; index < self.loadedEpisodes.count; index++) {
                    [indexPaths addObject:[NSIndexPath indexPathForRow:index inSection:0]];
                }
                [self.tableView insertRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationNone];
            }

            [self _updatePageFooter];
            [self _updateToolbarItemsAnimated:NO];
            [self _updateToolbarLabels];
            [self _restoreScrollPositionIfNeeded];
        });

        if (offset != 0 || pageError) {
            return;
        }

        __block NSUInteger totalEpisodeCount = 0;
        __block NSInteger totalPlaybackTime = 0;
        __block NSUInteger playedEpisodeCount = 0;
        __block NSUInteger playedDownloadedEpisodeCount = 0;
        [context performBlockAndWait:^{
            NSError* listError = nil;
            CDList* list = (CDList*)[context existingObjectWithID:listID error:&listError];
            if (!list || listError) {
                return;
            }
            totalEpisodeCount = list.numberOfEpisodes;
            totalPlaybackTime = list.playbackTime;
            playedEpisodeCount = list.numberOfPlayedEpisodes;
            playedDownloadedEpisodeCount = list.numberOfPlayedDownloadedEpisodes;
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.episodesLoadGeneration) {
                return;
            }
            self.totalEpisodeCount = totalEpisodeCount;
            self.totalPlaybackTime = totalPlaybackTime;
            self.playedEpisodeCount = playedEpisodeCount;
            self.playedDownloadedEpisodeCount = playedDownloadedEpisodeCount;
            self.statisticsLoaded = YES;
            if (self.nextPageOffset >= totalEpisodeCount) {
                self.reachedListEnd = YES;
            }
            [self _updatePageFooter];
            [self _updateToolbarLabels];
            [self _updateToolbarItemsAnimated:NO];
        });
    });
}

- (void) updateEpisodes
{
    self.episodesLoadGeneration++;
    self.loadedEpisodes = [[NSMutableArray alloc] init];
    self.episodes = self.loadedEpisodes;
    self.nextPageOffset = 0;
    self.loadingPage = NO;
    self.reachedListEnd = NO;
    self.pageError = nil;
    self.statisticsLoaded = NO;
    self.totalEpisodeCount = 0;
    self.totalPlaybackTime = 0;
    self.playedEpisodeCount = 0;
    self.playedDownloadedEpisodeCount = 0;
    [self.tableView reloadData];
    [self _updateToolbarLabels];
    [self _loadNextPage];
}

- (void) loadEpisodeObjectIDsForBulkActionWithCompletion:(void (^)(NSArray<NSManagedObjectID*>*, NSError*))completion
{
    if (!completion) {
        return;
    }

    NSManagedObjectID* listID = self.list.objectID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSMutableArray<NSManagedObjectID*>* episodeObjectIDs = [[NSMutableArray alloc] init];
        __block NSError* loadError = nil;
        NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
        [context performBlockAndWait:^{
            CDList* list = (CDList*)[context existingObjectWithID:listID error:&loadError];
            if (!list || loadError) {
                return;
            }

            NSUInteger offset = 0;
            NSUInteger pageSize = 500;
            if ([list isKindOfClass:[CDEpisodeList class]] &&
                [((CDEpisodeList*)list).orderBy isEqualToString:@"timeLeft"]) {
                // timeLeft must be globally sorted in memory; request it once instead of
                // repeating that full lightweight sort for every bulk-ID page.
                pageSize = 0;
            }

            while (!loadError) {
                @autoreleasepool {
                    NSArray<CDEpisode*>* page = [list sortedEpisodesWithOffset:offset
                                                                          limit:pageSize
                                                                          error:&loadError];
                    if (!page || loadError) {
                        break;
                    }
                    [episodeObjectIDs addObjectsFromArray:[page valueForKey:@"objectID"]];
                    if (pageSize == 0 || page.count < pageSize) {
                        break;
                    }
                    offset += page.count;
                }
            }
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(loadError ? @[] : episodeObjectIDs, loadError);
        });
    });
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

- (BOOL)_removeLoadedEpisode:(CDEpisode*)episode
{
    NSUInteger index = [self.loadedEpisodes indexOfObject:episode];
    if (index == NSNotFound && episode.objectHash.length > 0) {
        index = [self.loadedEpisodes indexOfObjectPassingTest:^BOOL(id candidate, NSUInteger idx, BOOL* stop) {
            return [[candidate objectHash] isEqualToString:episode.objectHash];
        }];
    }
    if (index == NSNotFound) {
        return NO;
    }

    [self.loadedEpisodes removeObjectAtIndex:index];
    self.episodes = self.loadedEpisodes;
    // The backing query has lost this row too. Continue exactly after the remaining
    // contiguous prefix or the next OFFSET page would skip one episode.
    self.nextPageOffset = self.loadedEpisodes.count;
    if (self.statisticsLoaded) {
        self.totalEpisodeCount = (self.totalEpisodeCount > 0) ? self.totalEpisodeCount - 1 : 0;
        self.totalPlaybackTime = MAX(0, self.totalPlaybackTime - episode.duration);
        if (episode.consumed && self.playedEpisodeCount > 0) {
            self.playedEpisodeCount--;
        }
        if (episode.consumed &&
            [[CacheManager sharedCacheManager].cachedEpisodeObjectHashes containsObject:episode.objectHash] &&
            self.playedDownloadedEpisodeCount > 0) {
            self.playedDownloadedEpisodeCount--;
        }
    }
    return YES;
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
    [self _removeLoadedEpisode:episode];
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

    NSString* key = [self _scrollPersistenceKey];
    NSNumber* storedOffset = ICListScrollPositionForKey(key);
    if (storedOffset) {
        CGFloat targetOffset = storedOffset.doubleValue;
        CGFloat requiredHeight = targetOffset + CGRectGetHeight(self.tableView.bounds);
        [self.tableView layoutIfNeeded];

        // Continue after each asynchronous page. The old synchronous while-loop laid
        // out every intermediate page on main before the user could interact.
        if (self.tableView.contentSize.height < requiredHeight && !self.reachedListEnd) {
            [self _loadNextPage];
            return;
        }
    }

    _didRestoreScrollPosition = YES;
    ICRestoreScrollPositionForScrollView(key, self.tableView);
}

- (void) _storeScrollPosition
{
    ICStoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView);
}

#pragma mark -

- (NSInteger)_numberOfDisplayEpisodes
{
    return self.statisticsLoaded ? self.totalEpisodeCount : self.loadedEpisodes.count;
}

- (NSInteger)_numberOfNotPlayedDisplayEpisodes
{
    if (self.statisticsLoaded) {
        return self.totalEpisodeCount - MIN(self.totalEpisodeCount, self.playedEpisodeCount);
    }
    return [super _numberOfNotPlayedDisplayEpisodes];
}

- (NSInteger)_numberOfPlayedDisplayEpisodes
{
    return self.statisticsLoaded ? self.playedEpisodeCount : [super _numberOfPlayedDisplayEpisodes];
}

- (NSInteger)_numberOfPlayedDownloadedEpisodes
{
    return self.statisticsLoaded ? self.playedDownloadedEpisodeCount : [super _numberOfPlayedDownloadedEpisodes];
}

- (NSString*)_selectionToggleTitleKeyForSelectedCount:(NSUInteger)selectedCount rowCount:(NSUInteger)rowCount
{
    if (!self.reachedListEnd && selectedCount < rowCount) {
        return @"All Loaded";
    }
    return [super _selectionToggleTitleKeyForSelectedCount:selectedCount rowCount:rowCount];
}

- (void) _updateToolbarLabels
{
    if (!self.statisticsLoaded) {
        self.toolbarLabelsViewController.mainText = @"Loading…".ls;
        self.toolbarLabelsViewController.auxiliaryText = @"";
        [self.toolbarLabelsViewController layout];
        return;
    }

    NSUInteger numEpisodes = self.totalEpisodeCount;
    
    if (numEpisodes == 0) {
        self.toolbarLabelsViewController.mainText = @"No Episodes".ls;
        self.toolbarLabelsViewController.auxiliaryText = @"";
    }
    else
    {
        self.toolbarLabelsViewController.mainText = (numEpisodes == 1) ? @"1 Episode".ls : [NSString stringWithFormat:@"%d Episodes".ls, (int)MIN(numEpisodes, INT_MAX)];
        
        NSValueTransformer* durationTransformer = [NSValueTransformer valueTransformerForName:kICDurationValueTransformer];
        NSString* durString = [durationTransformer transformedValue:@(self.totalPlaybackTime)];
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
    
    CGFloat visibleBottom = scrollView.contentOffset.y + CGRectGetHeight(scrollView.bounds);
    CGFloat prefetchDistance = MAX(240.0, CGRectGetHeight(scrollView.bounds) * 0.5);
    if (visibleBottom >= size.height - prefetchDistance) {
        [self _loadNextPage];
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
    // Continuous playback for lists: arm the list as the playback source BEFORE super
    // initiates playback (the play may run deferred behind the cellular-streaming alert).
    // The end-of-episode flow (AudioSession nextPlayableEpisode) checks the list's flag
    // and plays its next episode. The play-next queue stays untouched (previously this
    // erased the queue and pre-filled it with the next 10 list episodes).
    if (button.comboState != kEpisodePlayButtonComboStateFilling && button.comboState != kEpisodePlayButtonComboStateHolding)
    {
        CDEpisodeList* episodeList = [self.list isKindOfClass:[CDEpisodeList class]] ? (CDEpisodeList*)self.list : nil;
        [[AudioSession sharedAudioSession] notePlaybackSourceEpisodeList:episodeList];
    }

    [super playComboButtonAction:button];
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

    if ([self _numberOfPlayedDisplayEpisodes] == 0) {
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
    // während sie lief"). Remove by object because the visible index and backing
    // page offset have to be updated together.
    [self _removeLoadedEpisode:episode];
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
