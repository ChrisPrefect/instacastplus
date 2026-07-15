//
//  DownloadsViewController.m
//  Instacast
//
//  Created by Martin Hering on 22.10.11.
//  Copyright (c) 2011 Vemedio. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>

#import "DownloadsViewController.h"

#import "DownloadsTableViewCell.h"
#import "CDModel.h"
#import "CDEpisode+ShowNotes.h"
#import "EpisodePlayComboButton.h"

static void ICConfigureDownloadRetryButton(UIButton* button)
{
    [button setTitle:@"Retry".ls forState:UIControlStateNormal];
    [button setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    [button sizeToFit];
}

static CGFloat ICDownloadRetryButtonWidth(void)
{
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    ICConfigureDownloadRetryButton(button);
    return MAX(44, ceilf(button.intrinsicContentSize.width));
}

@interface DownloadsViewController ()
@property (nonatomic, strong) UIView* functionOverlayView;
@property (nonatomic, strong) UILabel* captionLabel;
@property (nonatomic, strong) UIBarButtonItem* pauseItem;
@property (nonatomic, strong) UIBarButtonItem* cancelItem;
@property (nonatomic, copy) NSArray<CDEpisode*>* displayEpisodes;
@property (nonatomic) NSUInteger activeDownloadCount;
@end

@implementation DownloadsViewController {
    BOOL _observing;
    BOOL _userAction;
    BOOL _didRestoreScrollPosition;
    BOOL _clearingDownloadErrors;
    BOOL _downloadErrorClearNeedsRetry;
}

+ (DownloadsViewController*) downloadsViewController
{
    return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self _setObserving:NO];
}


#pragma mark - View lifecycle

- (void) _setObserving:(BOOL)observing
{
    if (observing && !_observing)
    {
        __weak DownloadsViewController* weakSelf = self;
        
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self name:CacheManagerDidUpdateNotification object:nil handler:^(NSNotification *notification) {
            NSArray* indexPaths = [weakSelf.tableView indexPathsForVisibleRows];
            NSArray* displayEpisodes = weakSelf.displayEpisodes;
            NSUInteger activeDownloadCount = weakSelf.activeDownloadCount;
            
            for(NSIndexPath* indexPath in indexPaths)
            {
                if (indexPath.row >= activeDownloadCount || indexPath.row >= displayEpisodes.count) {
                    continue;
                }
                
                DownloadsTableViewCell* cell = (DownloadsTableViewCell*)[weakSelf.tableView cellForRowAtIndexPath:indexPath];
                if ([cell isKindOfClass:[DownloadsTableViewCell class]])
                {
                    CDEpisode* episode = [displayEpisodes objectAtIndex:indexPath.row];
                    [weakSelf _updateCellProgress:cell withEpisode:episode];
                }
            }
            
            [weakSelf _updateCaption];
            [weakSelf _updateToolbar];
        }];
        
        [[CacheManager sharedCacheManager] addTaskObserver:self forKeyPath:@"cachingEpisodes" task:^(id obj, NSDictionary *change) {
            DownloadsViewController* strongSelf = weakSelf;
            [strongSelf _rebuildDisplayEpisodes];
            if (strongSelf && !strongSelf->_userAction) {
                [strongSelf.tableView reloadData];
            }
        }];
        [[CacheManager sharedCacheManager] addTaskObserver:self forKeyPath:@"failedDownloadEpisodes" task:^(id obj, NSDictionary *change) {
            DownloadsViewController* strongSelf = weakSelf;
            [strongSelf _rebuildDisplayEpisodes];
            if (strongSelf && !strongSelf->_userAction) {
                [strongSelf.tableView reloadData];
                [strongSelf _updateCaption];
                [strongSelf _updateToolbar];
            }
        }];
        
        [nc addObserver:self name:CacheManagerDidEndCachingNotification object:nil handler:^(NSNotification *notification) {
            [weakSelf _rebuildDisplayEpisodes];
            [weakSelf _updateCaption];
            if (weakSelf.displayEpisodes.count == 0) {
                [weakSelf dismissViewControllerAnimated:YES completion:NULL];
            } else {
                [weakSelf.tableView reloadData];
            }
        }];
        
    }
    else if (!observing && _observing)
    {
        NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
        [nc removeHandlerForObserver:self name:CacheManagerDidUpdateNotification object:nil];
        [nc removeHandlerForObserver:self name:CacheManagerDidEndCachingNotification object:nil];

        [[CacheManager sharedCacheManager] removeTaskObserver:self forKeyPath:@"cachingEpisodes"];
        [[CacheManager sharedCacheManager] removeTaskObserver:self forKeyPath:@"failedDownloadEpisodes"];
    }
    
    _observing = observing;
}


- (void)viewDidLoad
{
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

    self.tableView.rowHeight = 70;
    
    self.navigationItem.title = @"Downloads".ls;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(toggleEditing:)];

    UIBarButtonItem* pauseItem = [[UIBarButtonItem alloc] initWithTitle:@"Pause".ls
                                                                  style:UIBarButtonItemStylePlain target:self action:@selector(toggleLoading:)];
    [pauseItem setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)]} forState:UIControlStateNormal];

    UIBarButtonItem* cancelItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel All".ls
                                                                  style:UIBarButtonItemStylePlain target:self action:@selector(cancelAllDownloads:)];
    [cancelItem setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)]} forState:UIControlStateNormal];

    // Caption Label in der Mitte (schwebendes Label)
    UILabel* captionLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 150, 44)];
    captionLabel.tag = 100;
    captionLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    captionLabel.textColor = ICMutedTextColor;
    captionLabel.textAlignment = NSTextAlignmentCenter;
    self.captionLabel = captionLabel;

    // Toolbar items werden in viewDidAppear gesetzt wenn Toolbar bereit ist
    self.pauseItem = pauseItem;
    self.cancelItem = cancelItem;
    self.displayEpisodes = @[];
}

- (void) updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;
    self.captionLabel.textColor = ICMutedTextColor;
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    _didRestoreScrollPosition = NO;
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 0, 0, 0);
    self.tableView.separatorColor = ICTableSeparatorColor;
    [self _rebuildDisplayEpisodes];
    [self.tableView reloadData];

    // Caption Label direkt zur Toolbar hinzufügen (schwebendes Label, keine Bubble)
    UIToolbar* toolbar = self.navigationController.toolbar;
    if (![toolbar viewWithTag:100]) {
        self.captionLabel.center = CGPointMake(toolbar.bounds.size.width / 2, toolbar.bounds.size.height / 2);
        self.captionLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
        [toolbar addSubview:self.captionLabel];
    }

    [self _setObserving:YES];
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self _loadImagesForOnscreenRows];
    [self _restoreScrollPositionIfNeeded];

    // Toolbar items setzen
    if (!self.toolbarItems || self.toolbarItems.count == 0) {
        UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        [self setToolbarItems:@[self.pauseItem, flexSpace, self.cancelItem]];
    }
    [self _updateToolbar];
    [self _updateCaption];
}

- (void) viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self _storeScrollPosition];
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [self _setObserving:NO];
}


#pragma mark -


- (void) _updateCellProgress:(DownloadsTableViewCell*)cell withEpisode:(CDEpisode*)episode
{
	CacheManager* cman = [CacheManager sharedCacheManager];
	cell.showsErrorStatus = NO;
	cell.rightContentAccessoryView = nil;
	cell.progressView.hidden = NO;
	cell.sizeLabel.numberOfLines = 1;
	
	double progress = [cman cacheProgressForEpisode:episode];
	cell.progressView.progress = progress;
	
	NSTimeInterval timeLeft = [cman cacheTimeLeftForEpisode:episode];
	
	long long expectedContentLength = [cman expectedContentLengthForEpisode:episode];
	long long loadedContentLength = expectedContentLength*progress;

    BOOL cached = [cman episodeIsCached:episode fastLookup:YES];
    BOOL caching = [cman isCachingEpisode:episode];
    BOOL loading = [cman isLoadingEpisode:episode];
    BOOL suspended = [cman isLoadingEpisodeSuspended:episode];
	
	if (cached) {
        cell.sizeLabel.text = [NSString stringWithFormat:@"%@ of %@".ls, [NSByteCountFormatter stringFromByteCount:loadedContentLength countStyle:NSByteCountFormatterCountStyleFile], [NSByteCountFormatter stringFromByteCount:expectedContentLength countStyle:NSByteCountFormatterCountStyleFile]];
        cell.playAccessoryButton.comboState = kEpisodePlayButtonComboStateFilled;
    }
	else if (caching && suspended) {
		cell.sizeLabel.text = @"Paused…".ls;
        cell.playAccessoryButton.comboState = kEpisodePlayButtonComboStateHolding;
	}
    else if (caching && !loading) {
		cell.sizeLabel.text = @"Waiting to download…".ls;
        cell.playAccessoryButton.comboState = kEpisodePlayButtonComboStateHolding;
	}
    else if (caching && loading && loadedContentLength == 0) {
		cell.sizeLabel.text = @"Loading…".ls;
        cell.playAccessoryButton.comboState = kEpisodePlayButtonComboStateFilling;
	}
    else if (caching && loading) {
		cell.sizeLabel.text = [NSString stringWithFormat:@"%@ of %@".ls, [NSByteCountFormatter stringFromByteCount:loadedContentLength countStyle:NSByteCountFormatterCountStyleFile], [NSByteCountFormatter stringFromByteCount:expectedContentLength countStyle:NSByteCountFormatterCountStyleFile]];
        cell.playAccessoryButton.comboState = kEpisodePlayButtonComboStateFilling;
	}
    else {
		cell.sizeLabel.text = @"Waiting to download…".ls;
        cell.playAccessoryButton.comboState = kEpisodePlayButtonComboStateOutline;
	}

    cell.playAccessoryButton.fillingProgress = progress;
	
	NSString* timeString = nil;
	if (timeLeft > 0 && expectedContentLength > 0) {
        NSString* time = [NSString stringWithFormat:@"%ld:%02ld", (long)timeLeft/60, (long)timeLeft%60];
		timeString = [NSString stringWithFormat:@"%@ left".ls, time];
	}
	NSString* prevTimeString = cell.timeLabel.text;
	cell.timeLabel.text = (loadedContentLength == 0) ? nil : timeString;
	
	// change layout if time label content changed
	if ((prevTimeString && !timeString) || (!prevTimeString && timeString)) {
		[cell setNeedsLayout];
	}
}

- (void) _rebuildDisplayEpisodes
{
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    NSArray<CDEpisode*>* activeEpisodes = cacheManager.cachingEpisodes;
    NSArray<CDEpisode*>* failedEpisodes = cacheManager.failedDownloadEpisodes;
    NSMutableArray<CDEpisode*>* episodes = [NSMutableArray arrayWithCapacity:activeEpisodes.count + failedEpisodes.count];
    NSMutableSet<NSString*>* seenEpisodeIdentities = [NSMutableSet setWithCapacity:activeEpisodes.count + failedEpisodes.count];
    for (CDEpisode* episode in activeEpisodes) {
        NSString* identity = episode.objectHash.length > 0
            ? episode.objectHash
            : episode.objectID.URIRepresentation.absoluteString;
        if ([seenEpisodeIdentities containsObject:identity]) {
            continue;
        }
        [seenEpisodeIdentities addObject:identity];
        [episodes addObject:episode];
    }
    self.activeDownloadCount = episodes.count;
    for (CDEpisode* episode in failedEpisodes) {
        NSString* identity = episode.objectHash.length > 0
            ? episode.objectHash
            : episode.objectID.URIRepresentation.absoluteString;
        if ([seenEpisodeIdentities containsObject:identity]) {
            continue;
        }
        [seenEpisodeIdentities addObject:identity];
        [episodes addObject:episode];
    }
    self.displayEpisodes = episodes;
}

- (NSString*) _failureTextForEpisode:(CDEpisode*)episode
{
    NSError* error = [[CacheManager sharedCacheManager] downloadErrorForEpisode:episode];
    if (!error) {
        return nil;
    }
    return [NSString stringWithFormat:@"%@\n%@", error.localizedDescription, @"Tap Retry to try the download again.".ls];
}

- (void) _updateToolbar
{
    if (self.toolbarItems.count == 0) {
        return;
    }
    UIBarButtonItem* pauseItem = self.toolbarItems[0];
    BOOL hasActiveDownloads = self.activeDownloadCount > 0;
    pauseItem.enabled = hasActiveDownloads;
    self.cancelItem.title = hasActiveDownloads ? @"Cancel All".ls : @"Clear Errors".ls;
    self.cancelItem.enabled = !_clearingDownloadErrors &&
        (self.displayEpisodes.count > 0 || _downloadErrorClearNeedsRetry);

    if ([[CacheManager sharedCacheManager] isCachingSuspended]) {
        pauseItem.title = @"Resume".ls;
    } else {
        pauseItem.title = @"Pause".ls;
    }
}

- (void) _updateCaption
{
    if (!self.captionLabel) {
        return;
    }
    
    CacheManager* cman = [CacheManager sharedCacheManager];
    
    if ([cman isCachingSuspended])
    {
        if (![self.captionLabel.layer animationForKey:@"pulseAnimation"]) {
            CABasicAnimation* pulseAnimation = [CABasicAnimation animation];
            pulseAnimation.keyPath = @"opacity";
            pulseAnimation.fromValue = [NSNumber numberWithFloat: 1.0];
            pulseAnimation.toValue = [NSNumber numberWithFloat: 0.0];
            pulseAnimation.duration = 0.75;
            pulseAnimation.repeatCount = MAXFLOAT;
            pulseAnimation.autoreverses = YES;
            pulseAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [self.captionLabel.layer addAnimation:pulseAnimation forKey:@"pulseAnimation"];
        }
        
        self.captionLabel.text = @"Downloads paused".ls;
    }
    else
    {
        if ([self.captionLabel.layer animationForKey:@"pulseAnimation"]) {
            [self.captionLabel.layer removeAllAnimations];
            self.captionLabel.layer.opacity = 1.0f;
        }
        
        if ([cman isCaching])
        {
            double rate = cman.rate;

            if (rate > 0) {
                NSString* rateString = [NSByteCountFormatter stringFromByteCount:(long long)rate countStyle:NSByteCountFormatterCountStyleMemory];
                self.captionLabel.text = [NSString stringWithFormat:@"%@/s", rateString];
            }
            else {
                self.captionLabel.text = nil;
            }
        }
        else {
            NSUInteger failedCount = cman.failedDownloadEpisodes.count;
            if (failedCount == 1) {
                self.captionLabel.text = @"1 download failed".ls;
            } else if (failedCount > 1) {
                self.captionLabel.text = [NSString stringWithFormat:@"%lu downloads failed".ls, (unsigned long)failedCount];
            } else {
                self.captionLabel.text = nil;
            }
        }
    }
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == 0) {
        return self.displayEpisodes.count;
    }
    
    return 0;
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    
    if (indexPath.section == 0)
    {
        static NSString *CellIdentifier = @"DownloadsEpisodesCachingCell";
        
        DownloadsTableViewCell *cell = (DownloadsTableViewCell*)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
        if (cell == nil) {
            cell = [[DownloadsTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
        }
        [cell.playAccessoryButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        cell.backgroundColor = tableView.backgroundColor;
        
        NSArray* episodes = self.displayEpisodes;
        CDEpisode* episode = [episodes objectAtIndex:indexPath.row];
        CDFeed* feed = episode.feed;
        
        cell.tag = indexPath.row;
        cell.accessibilityIdentifier = episode.objectHash;
        
        // make sure the feed title is not repeated in episode title
        NSString* title = [episode cleanTitleUsingFeedTitle:feed.title];
        
        cell.textLabel.text = title;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.playAccessoryButton.tag = indexPath.row;
        cell.playAccessoryButton.accessibilityIdentifier = episode.objectHash;
        
        cell.imageView.tag = 0;
        cell.imageView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];
        NSURL* imageURL = (episode.imageURL) ? episode.imageURL : episode.feed.imageURL;
        
        ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
        [iman imageForURL:imageURL size:56 grayscale:NO sender:self completion:^(UIImage *image) {
            if (image && [cell.accessibilityIdentifier isEqualToString:episode.objectHash]) {
                cell.imageView.image = image;
                cell.imageView.tag = 1;
            }
        }];

        
        BOOL isActiveDownload = indexPath.row < self.activeDownloadCount;
        NSError* downloadError = isActiveDownload ? nil : [cman downloadErrorForEpisode:episode];
        if (downloadError) {
            [cell.playAccessoryButton removeFromSuperview];
            UIButton* retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
            ICConfigureDownloadRetryButton(retryButton);
            retryButton.accessibilityLabel = @"Retry".ls;
            retryButton.tag = indexPath.row;
            retryButton.accessibilityIdentifier = episode.objectHash;
            [retryButton addTarget:self action:@selector(retryFailedDownload:) forControlEvents:UIControlEventTouchUpInside];
            cell.rightContentAccessoryView = retryButton;
            cell.showsErrorStatus = YES;
            cell.progressView.progress = 0;
            cell.sizeLabel.text = [self _failureTextForEpisode:episode];
            cell.timeLabel.text = nil;
        } else {
            cell.rightContentAccessoryView = nil;
            cell.showsErrorStatus = NO;
            if (cell.playAccessoryButton.superview != cell.contentView) {
                [cell.contentView addSubview:cell.playAccessoryButton];
            }
            [cell.playAccessoryButton addTarget:self action:@selector(cancelCachingEpisode:) forControlEvents:UIControlEventTouchUpInside];
            [self _updateCellProgress:cell withEpisode:episode];
        }
        
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    
        
        return cell;
    }
    
    
    return nil;
}

- (CGFloat)tableView:(UITableView*)tableView heightForRowAtIndexPath:(NSIndexPath*)indexPath
{
    NSArray<CDEpisode*>* episodes = self.displayEpisodes;
    if (indexPath.row >= episodes.count) {
        return 70;
    }
    BOOL isActiveDownload = indexPath.row < self.activeDownloadCount;
    NSString* failureText = isActiveDownload ? nil : [self _failureTextForEpisode:episodes[indexPath.row]];
    if (failureText.length == 0) {
        return 70;
    }
    CGFloat retryButtonWidth = ICDownloadRetryButtonWidth();
    CGFloat availableWidth = MAX(1, CGRectGetWidth(tableView.bounds) - 76 - retryButtonWidth - 5);
    CGRect textBounds = [failureText boundingRectWithSize:CGSizeMake(availableWidth, CGFLOAT_MAX)
                                                 options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                              attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(11)]}
                                                 context:nil];
    return MAX(82, 43 + ceilf(CGRectGetHeight(textBounds)) + 9);
}


// Override to support conditional editing of the table view.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Return NO if you do not want the specified item to be editable.
    return (indexPath.section == 0);
}


// Override to support conditional rearranging of the table view.
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    return indexPath.section == 0
        && indexPath.row < self.activeDownloadCount
        && [[CacheManager sharedCacheManager] canReorderCachingEpisodes];
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath
{
    NSUInteger activeCount = self.activeDownloadCount;
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    if (![cacheManager canReorderCachingEpisodes]
        || fromIndexPath.row >= activeCount || toIndexPath.row >= activeCount) {
        return;
    }
    _userAction = YES;
    [cacheManager reorderCachingEpisodeFromIndex:fromIndexPath.row toIndex:toIndexPath.row];
    _userAction = NO;
}

- (NSIndexPath*)tableView:(UITableView*)tableView targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath*)sourceIndexPath toProposedIndexPath:(NSIndexPath*)proposedDestinationIndexPath
{
    if (![[CacheManager sharedCacheManager] canReorderCachingEpisodes]) {
        return sourceIndexPath;
    }
    NSUInteger activeCount = self.activeDownloadCount;
    if (activeCount == 0) {
        return sourceIndexPath;
    }
    return [NSIndexPath indexPathForRow:MIN(proposedDestinationIndexPath.row, activeCount - 1) inSection:0];
}

- (NSIndexPath *)tableView:(UITableView *)tableView willSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    return nil;
}

#pragma mark - Table view delegate

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath
{
    return NO;
}

#pragma mark Actions

- (void) cancelCachingEpisode:(UIButton*)button
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    NSString* episodeHash = button.accessibilityIdentifier;
    if (episodeHash.length == 0) {
        return;
    }
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:episodeHash];
    if (episode && [cman isCachingEpisode:episode]) {
        [cman cancelCachingEpisode:episode disableAutoDownload:YES];
    }
}

- (void) retryFailedDownload:(UIButton*)button
{
    NSString* episodeHash = button.accessibilityIdentifier;
    if (episodeHash.length == 0) {
        return;
    }
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:episodeHash];
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    if (episode && [cacheManager downloadErrorForEpisode:episode]) {
        NSError* retryError = nil;
        if (![cacheManager retryFailedDownloadForEpisode:episode error:&retryError] && retryError) {
            NSUInteger row = [self.displayEpisodes indexOfObjectPassingTest:^BOOL(CDEpisode* candidate, NSUInteger index, BOOL* stop) {
                return [candidate.objectHash isEqualToString:episodeHash];
            }];
            if (row != NSNotFound) {
                NSIndexPath* indexPath = [NSIndexPath indexPathForRow:row inSection:0];
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            }
            [self presentError:retryError];
        }
    }
}

- (void) cancelAllDownloads:(id)sender
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    NSArray* cachingEpisode = [cman cachingEpisodes];
    for(CDEpisode* episode in [cachingEpisode copy]) {
        [cman cancelCachingEpisode:episode disableAutoDownload:YES];
    }
    _clearingDownloadErrors = YES;
    _downloadErrorClearNeedsRetry = NO;
    [self _updateToolbar];
    __weak typeof(self) weakSelf = self;
    [cman clearAllDownloadErrorsWithCompletion:^(NSError* error) {
        DownloadsViewController* strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_clearingDownloadErrors = NO;
        strongSelf->_downloadErrorClearNeedsRetry = (error != nil);
        [strongSelf _rebuildDisplayEpisodes];
        [strongSelf.tableView reloadData];
        [strongSelf _updateCaption];
        [strongSelf _updateToolbar];
        if (error) {
            [strongSelf presentError:error];
        } else if (strongSelf.displayEpisodes.count == 0) {
            [strongSelf dismissViewControllerAnimated:YES completion:nil];
        }
    }];
}

- (void) toggleEditing:(id)sender
{
    [self setEditing:!self.editing animated:YES];
    UIImage* editImage = self.editing ? [UIImage systemImageNamed:@"checkmark"] : [UIImage systemImageNamed:@"pencil"];
    self.navigationItem.rightBarButtonItem.image = editImage;
    [self _updateToolbar];
}

- (void) toggleLoading:(id)sender
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    
    if ([cman isCachingSuspended]) {
        [cman resumeCaching];
    }
    else {
        [cman pauseCaching];
    }
    [self _updateToolbar];
    [self _updateCaption];
}

#pragma mark -
#pragma mark ScrollView Delegate

- (NSString*) _scrollPersistenceKey
{
    return @"downloads";
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

- (void) _loadImagesForOnscreenRows
{
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];

	NSArray* episodes = self.displayEpisodes;
	NSArray *visiblePaths = [self.tableView indexPathsForVisibleRows];
	for (NSIndexPath *indexPath in visiblePaths)
	{
        UITableViewCell* cell = [self.tableView cellForRowAtIndexPath:indexPath];
        
        if (cell.imageView.tag == 0)
        {
            if (indexPath.row >= episodes.count) {
                continue;
            }
            CDEpisode* episode = [episodes objectAtIndex:indexPath.row];
            
            NSURL* imageURL = (episode.imageURL) ? episode.imageURL : episode.feed.imageURL;
            
            ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
            [iman imageForURL:imageURL size:56 grayscale:NO sender:self completion:^(UIImage *image) {
                if (image && [cell.accessibilityIdentifier isEqualToString:episode.objectHash]) {
                    cell.imageView.image = image;
                    cell.imageView.tag = 1;
                }
            }];
        }
	}
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView{
	
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
	if (!decelerate) {
        [self _loadImagesForOnscreenRows];
        ICScheduleStoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView, 0.5);
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    [self _loadImagesForOnscreenRows];
    ICScheduleStoreScrollPositionForScrollView([self _scrollPersistenceKey], self.tableView, 0.5);
}
@end
