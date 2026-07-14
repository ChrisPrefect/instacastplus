//
//  MediaFilesViewController.m
//  Instacast
//
//  Created by Martin Hering on 24.10.12.
//
//

#import "MediaFilesViewController.h"
#import "UIManager.h"

#import "VDModalInfo.h"
#import "CDEpisode+ShowNotes.h"
#import "UITableViewController+Settings.h"
#import "InstacastAppDelegate.h"

typedef NS_ENUM(NSInteger, MediaFilesSortMode) {
    kSortBySize = 0,
    kSortByDate,
    kSortByPodcast
};

static NSString *CellIdentifier = @"Cell";
static NSString *PodcastHeaderCellIdentifier = @"PodcastHeaderCell";
static NSString *PlaceholderCellIdentifier = @"PlaceholderCell";
static NSString *MediaFilesSortModeKey = @"MediaFilesSortMode";

@interface MediaFilesViewController () <UIDocumentInteractionControllerDelegate>
@property (nonatomic, strong) NSArray* cachedEpisodes;
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@property (nonatomic) MediaFilesSortMode sortMode;
@property (nonatomic, strong) UISegmentedControl *sortControl;
@property (nonatomic, strong) NSArray<NSDictionary*> *podcastSections;
@property (nonatomic, copy) NSDictionary<NSString*, NSNumber*> *downloadedBytesByEpisodeHash;
@property (nonatomic, copy) NSArray<CDEpisode*> *pendingContentEpisodes;
@property (nonatomic) NSUInteger contentReloadGeneration;
@end

@implementation MediaFilesViewController

+ (id) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

#pragma mark - Podcast mode helpers

- (BOOL)_isPodcastMode
{
    return (self.sortMode == kSortByPodcast);
}

- (BOOL)_isPodcastHeaderAtIndexPath:(NSIndexPath *)indexPath
{
    return ([self _isPodcastMode] && [self _isEpisodeSection:indexPath.section] && indexPath.row == 0);
}

- (CDEpisode *)_episodeAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _isPodcastMode]) {
        if (indexPath.section < (NSInteger)self.podcastSections.count) {
            // row 0 = podcast header, episodes start at row 1
            NSInteger episodeIndex = indexPath.row - 1;
            NSArray *episodes = self.podcastSections[indexPath.section][@"episodes"];
            if (episodeIndex >= 0 && episodeIndex < (NSInteger)episodes.count) {
                return episodes[episodeIndex];
            }
        }
        return nil;
    }
    if (indexPath.row < (NSInteger)self.cachedEpisodes.count) {
        return self.cachedEpisodes[indexPath.row];
    }
    return nil;
}

- (NSInteger)_deleteAllButtonSection
{
    if ([self _isPodcastMode]) {
        return MAX((NSInteger)self.podcastSections.count, 1);
    }
    return 1;
}

- (BOOL)_isEpisodeSection:(NSInteger)section
{
    if ([self _isPodcastMode]) {
        return section < (NSInteger)self.podcastSections.count;
    }
    return section == 0;
}

#pragma mark - Data

- (void) _reloadContent
{
    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    NSArray<CDEpisode*>* allEpisodes = cacheManager.cachedEpisodes;
    NSMutableArray* fileURLs = [NSMutableArray arrayWithCapacity:allEpisodes.count];
    NSMutableArray* episodeHashes = [NSMutableArray arrayWithCapacity:allEpisodes.count];
    for (CDEpisode* episode in allEpisodes) {
        NSURL* fileURL = [cacheManager URLForCachedEpisode:episode];
        [fileURLs addObject:fileURL ?: NSNull.null];
        [episodeHashes addObject:episode.objectHash ?: NSNull.null];
    }

    NSUInteger generation = ++self.contentReloadGeneration;
    MediaFilesSortMode sortMode = self.sortMode;
    self.pendingContentEpisodes = allEpisodes;
    __weak MediaFilesViewController* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager* fileManager = [[NSFileManager alloc] init];
        NSMutableDictionary<NSString*, NSNumber*>* downloadedBytesByEpisodeHash = [NSMutableDictionary dictionaryWithCapacity:episodeHashes.count];
        for (NSUInteger index = 0; index < episodeHashes.count; index++) {
            NSString* episodeHash = episodeHashes[index];
            NSURL* fileURL = fileURLs[index];
            if (![episodeHash isKindOfClass:[NSString class]] || ![fileURL isKindOfClass:[NSURL class]]) {
                continue;
            }
            NSDictionary* attributes = [fileManager attributesOfItemAtPath:fileURL.path error:nil];
            downloadedBytesByEpisodeHash[episodeHash] = @([attributes fileSize]);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            MediaFilesViewController* self = weakSelf;
            if (!self || generation != self.contentReloadGeneration) {
                return;
            }
            NSArray<CDEpisode*>* episodes = self.pendingContentEpisodes ?: @[];
            self.pendingContentEpisodes = nil;
            self.downloadedBytesByEpisodeHash = downloadedBytesByEpisodeHash;
            [self _applyContentEpisodes:episodes sortMode:sortMode];
            [self.tableView reloadData];
        });
    });
}

- (unsigned long long)_downloadedBytesForEpisode:(CDEpisode*)episode
{
    return [self.downloadedBytesByEpisodeHash[episode.objectHash] unsignedLongLongValue];
}

- (void) _applyContentEpisodes:(NSArray<CDEpisode*>*)allEpisodes sortMode:(MediaFilesSortMode)sortMode
{

    switch (sortMode) {
        case kSortBySize:
        {
            self.podcastSections = nil;
            self.cachedEpisodes = [allEpisodes sortedArrayUsingComparator:^NSComparisonResult(CDEpisode *episode1, CDEpisode *episode2) {
                unsigned long long fileSize1 = [self _downloadedBytesForEpisode:episode1];
                unsigned long long fileSize2 = [self _downloadedBytesForEpisode:episode2];

                if (fileSize1 < fileSize2) {
                    return NSOrderedDescending;
                } else if (fileSize1 > fileSize2) {
                    return NSOrderedAscending;
                } else {
                    return NSOrderedSame;
                }
            }];
            break;
        }
        case kSortByDate:
        {
            self.podcastSections = nil;
            self.cachedEpisodes = [allEpisodes sortedArrayUsingComparator:^NSComparisonResult(CDEpisode *episode1, CDEpisode *episode2) {
                NSDate *date1 = episode1.lastDownloaded ?: episode1.pubDate;
                NSDate *date2 = episode2.lastDownloaded ?: episode2.pubDate;
                if (!date1 && !date2) return NSOrderedSame;
                if (!date1) return NSOrderedDescending;
                if (!date2) return NSOrderedAscending;
                return [date2 compare:date1]; // newest first
            }];
            break;
        }
        case kSortByPodcast:
        {
            NSMutableDictionary<NSString*, NSMutableArray*> *grouped = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString*, id> *feedMap = [NSMutableDictionary dictionary];

            for (CDEpisode *episode in allEpisodes) {
                NSString *feedIdentifier = episode.feed.objectID.URIRepresentation.absoluteString;
                if (feedIdentifier.length == 0) {
                    NSString* episodeIdentifier = episode.objectID.URIRepresentation.absoluteString ?: episode.objectHash ?: @"";
                    feedIdentifier = [@"orphan:" stringByAppendingString:episodeIdentifier];
                }
                if (!grouped[feedIdentifier]) {
                    grouped[feedIdentifier] = [NSMutableArray array];
                    feedMap[feedIdentifier] = episode.feed ?: NSNull.null;
                }
                [grouped[feedIdentifier] addObject:episode];
            }

            NSArray *sortedFeedIdentifiers = [grouped.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString* firstIdentifier, NSString* secondIdentifier) {
                id firstFeed = feedMap[firstIdentifier];
                id secondFeed = feedMap[secondIdentifier];
                NSString* firstTitle = [firstFeed isKindOfClass:[CDFeed class]] ? [firstFeed title] : @"";
                NSString* secondTitle = [secondFeed isKindOfClass:[CDFeed class]] ? [secondFeed title] : @"";
                NSComparisonResult titleOrder = [firstTitle localizedCaseInsensitiveCompare:secondTitle];
                return titleOrder == NSOrderedSame ? [firstIdentifier compare:secondIdentifier] : titleOrder;
            }];

            NSMutableArray *sections = [NSMutableArray array];
            for (NSString *feedIdentifier in sortedFeedIdentifiers) {
                NSArray *sortedEpisodes = [grouped[feedIdentifier] sortedArrayUsingComparator:^NSComparisonResult(CDEpisode *ep1, CDEpisode *ep2) {
                    NSDate *d1 = ep1.pubDate;
                    NSDate *d2 = ep2.pubDate;
                    if (!d1 && !d2) return NSOrderedSame;
                    if (!d1) return NSOrderedDescending;
                    if (!d2) return NSOrderedAscending;
                    return [d2 compare:d1];
                }];

                unsigned long long totalBytes = 0;
                for (CDEpisode *ep in sortedEpisodes) {
                    totalBytes += [self _downloadedBytesForEpisode:ep];
                }

                [sections addObject:@{
                    @"feed": feedMap[feedIdentifier],
                    @"episodes": sortedEpisodes,
                    @"totalBytes": @(totalBytes)
                }];
            }

            self.podcastSections = sections;
            self.cachedEpisodes = allEpisodes;
            break;
        }
    }
}

#pragma mark - Table header

- (void) _setupTableHeaderView
{
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 84)];

    self.sortControl = [[UISegmentedControl alloc] initWithItems:@[@"Size".ls, @"Date".ls, @"Podcast".ls]];
    self.sortControl.selectedSegmentIndex = self.sortMode;
    [self.sortControl addTarget:self action:@selector(sortModeChanged:) forControlEvents:UIControlEventValueChanged];
    self.sortControl.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.text = @"Swipe left to delete.".ls;
    hintLabel.font = [UIFont systemFontOfSize:ICFontSize(12)];
    hintLabel.textColor = ICMutedTextColor;
    hintLabel.textAlignment = NSTextAlignmentCenter;
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
    hintLabel.tag = 100;

    [headerView addSubview:self.sortControl];
    [headerView addSubview:hintLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.sortControl.topAnchor constraintEqualToAnchor:headerView.topAnchor constant:16],
        [self.sortControl.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:20],
        [self.sortControl.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-20],

        [hintLabel.topAnchor constraintEqualToAnchor:self.sortControl.bottomAnchor constant:6],
        [hintLabel.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:20],
        [hintLabel.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-20],
    ]];

    self.tableView.tableHeaderView = headerView;
}

- (void) sortModeChanged:(UISegmentedControl *)sender
{
    self.sortMode = (MediaFilesSortMode)sender.selectedSegmentIndex;
    [USER_DEFAULTS setInteger:self.sortMode forKey:MediaFilesSortModeKey];
    [self _reloadContent];
    [self.tableView reloadData];
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Downloaded Files".ls;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(toggleEditMode:)];

    self.sortMode = (MediaFilesSortMode)[USER_DEFAULTS integerForKey:MediaFilesSortModeKey];
    if (self.sortMode < kSortBySize || self.sortMode > kSortByPodcast) {
        self.sortMode = kSortBySize;
    }

    [self _setupTableHeaderView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
    __weak MediaFilesViewController* weakSelf = self;
    [[CacheManager sharedCacheManager] addTaskObserver:self forKeyPath:@"cachedEpisodes" task:^(__unused id object, __unused NSDictionary* change) {
        void (^reloadVisibleContent)(void) = ^{
            MediaFilesViewController* strongSelf = weakSelf;
            if (!strongSelf.viewIfLoaded.window) {
                return;
            }
            [strongSelf _reloadContent];
            [strongSelf.tableView reloadData];
        };
        if ([NSThread isMainThread]) {
            reloadVisibleContent();
        } else {
            dispatch_async(dispatch_get_main_queue(), reloadVisibleContent);
        }
    }];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    UILabel *hintLabel = [self.tableView.tableHeaderView viewWithTag:100];
    hintLabel.textColor = ICMutedTextColor;

    [[CacheManager sharedCacheManager] autoClearAndMakeRoomForBytes:0 automatic:YES];
    [self _reloadContent];
    [self.tableView reloadData];
}

- (void) dealloc
{
    [[CacheManager sharedCacheManager] removeTaskObserver:self forKeyPath:@"cachedEpisodes"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    UILabel *hintLabel = [self.tableView.tableHeaderView viewWithTag:100];
    hintLabel.textColor = ICMutedTextColor;

    [self.tableView reloadData];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

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

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    if ([self _isPodcastMode]) {
        return MAX((NSInteger)self.podcastSections.count, 1) + 1; // +1 for delete button
    }
    return 2; // episodes + delete button
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == [self _deleteAllButtonSection]) {
        return 1;
    }

    if ([self _isPodcastMode]) {
        if (self.podcastSections.count == 0 && section == 0) {
            return 1;
        }
        if (section < (NSInteger)self.podcastSections.count) {
            // +1 for podcast header row at index 0
            return [self.podcastSections[section][@"episodes"] count] + 1;
        }
        return 0;
    }

    // Flat mode
    return MAX(1, [self.cachedEpisodes count]);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    // Delete All button
    if (indexPath.section == [self _deleteAllButtonSection])
    {
        UITableViewCell* cell = [self resetCell];
        cell.userInteractionEnabled = YES;
        cell.textLabel.text = @"Delete Content".ls;
        return cell;
    }

    // Podcast mode
    if ([self _isPodcastMode])
    {
        if (self.podcastSections.count == 0 && indexPath.section == 0)
        {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:PlaceholderCellIdentifier];
            if (cell == nil) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:PlaceholderCellIdentifier];
                cell.backgroundColor = ICGroupCellBackgroundColor;
            }

            cell.accessoryView = nil;
            cell.textLabel.text = @"Nothing downloaded yet.".ls;
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.font = [UIFont italicSystemFontOfSize:ICFontSize(15)];
            cell.textLabel.textColor = ICMutedTextColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            return cell;
        }

        // Row 0 = podcast header cell
        if (indexPath.row == 0)
        {
            NSDictionary *sectionInfo = self.podcastSections[indexPath.section];
            CDFeed *feed = sectionInfo[@"feed"];
            unsigned long long totalBytes = [sectionInfo[@"totalBytes"] unsignedLongLongValue];

            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:PodcastHeaderCellIdentifier];
            if (cell == nil) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:PodcastHeaderCellIdentifier];
                cell.selectedBackgroundView = [[UIView alloc] init];
            }

            cell.backgroundColor = ICGroupCellBackgroundColor;
            cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(15) weight:UIFontWeightSemibold];
            cell.textLabel.textColor = ICTextColor;
            cell.textLabel.text = ([feed isKindOfClass:[NSNull class]]) ? @"" : feed.title;

            UILabel *sizeLabel = (UILabel*)cell.accessoryView;
            if (!sizeLabel) {
                sizeLabel = [[UILabel alloc] init];
                sizeLabel.font = [UIFont systemFontOfSize:ICFontSize(14) weight:UIFontWeightSemibold];
                sizeLabel.textAlignment = NSTextAlignmentRight;
                sizeLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
                cell.accessoryView = sizeLabel;

                UILabel *editLabel = [[UILabel alloc] init];
                editLabel.font = sizeLabel.font;
                editLabel.textAlignment = NSTextAlignmentRight;
                editLabel.textColor = sizeLabel.textColor;
                cell.editingAccessoryView = editLabel;
            }

            NSString *sizeText = [NSByteCountFormatter stringFromByteCount:totalBytes countStyle:NSByteCountFormatterCountStyleMemory];
            sizeLabel.text = sizeText;
            [sizeLabel sizeToFit];
            ((UILabel*)cell.editingAccessoryView).text = sizeText;
            [(UILabel*)cell.editingAccessoryView sizeToFit];

            return cell;
        }

        // Episode cell
        CDEpisode *episode = [self _episodeAtIndexPath:indexPath];
        if (!episode) return [[UITableViewCell alloc] init];

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];
        }

        cell.backgroundColor = ICGroupCellBackgroundColor;
        cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
        cell.detailTextLabel.textColor = ICMutedTextColor;

        UILabel* sizeLabel = (UILabel*)cell.accessoryView;
        if (!sizeLabel) {
            sizeLabel = [[UILabel alloc] init];
            sizeLabel.font = [UIFont systemFontOfSize:ICFontSize(14)];
            sizeLabel.textAlignment = NSTextAlignmentRight;
            sizeLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
            cell.accessoryView = sizeLabel;

            UILabel *editLabel = [[UILabel alloc] init];
            editLabel.font = sizeLabel.font;
            editLabel.textAlignment = NSTextAlignmentRight;
            editLabel.textColor = sizeLabel.textColor;
            cell.editingAccessoryView = editLabel;
        }

        CDFeed* feed = episode.feed;
        cell.textLabel.text = [episode cleanTitleUsingFeedTitle:feed.title];
        cell.detailTextLabel.text = feed.title;
        cell.textLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;

        unsigned long long bytes = [self _downloadedBytesForEpisode:episode];
        NSString *sizeText = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];
        sizeLabel.text = sizeText;
        [sizeLabel sizeToFit];
        ((UILabel*)cell.editingAccessoryView).text = sizeText;
        [(UILabel*)cell.editingAccessoryView sizeToFit];

        return cell;
    }

    // Flat mode — empty placeholder
    NSArray* episodes = self.cachedEpisodes;
    if ([episodes count] == 0)
    {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:PlaceholderCellIdentifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:PlaceholderCellIdentifier];
            cell.backgroundColor = ICGroupCellBackgroundColor;
        }

        cell.accessoryView = nil;
        cell.textLabel.text = @"Nothing downloaded yet.".ls;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont italicSystemFontOfSize:ICFontSize(15)];
        cell.textLabel.textColor = ICMutedTextColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        return cell;
    }

    // Flat mode — episode cell
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
        cell.selectedBackgroundView = [[UIView alloc] init];
        cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:ICFontSize(11)];
    }

    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    cell.detailTextLabel.textColor = ICMutedTextColor;

    UILabel* sizeLabel = (UILabel*)cell.accessoryView;
    if (!sizeLabel) {
        sizeLabel = [[UILabel alloc] init];
        sizeLabel.font = [UIFont systemFontOfSize:ICFontSize(14)];
        sizeLabel.textAlignment = NSTextAlignmentRight;
        sizeLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
        cell.accessoryView = sizeLabel;

        UILabel *editLabel = [[UILabel alloc] init];
        editLabel.font = sizeLabel.font;
        editLabel.textAlignment = NSTextAlignmentRight;
        editLabel.textColor = sizeLabel.textColor;
        cell.editingAccessoryView = editLabel;
    }

    CDEpisode* episode = episodes[indexPath.row];
    CDFeed* feed = episode.feed;
    cell.textLabel.text = [episode cleanTitleUsingFeedTitle:feed.title];
    cell.detailTextLabel.text = feed.title;
    cell.textLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;

    unsigned long long bytes = [self _downloadedBytesForEpisode:episode];
    NSString *sizeText = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];
    sizeLabel.text = sizeText;
    [sizeLabel sizeToFit];
    ((UILabel*)cell.editingAccessoryView).text = sizeText;
    [(UILabel*)cell.editingAccessoryView sizeToFit];

    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == [self _deleteAllButtonSection]) {
        return 43.0f;
    }

    return 44.0f;
}

#pragma mark - Section headers

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        [header.textLabel setTextColor:[UIColor grayColor]];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
    header.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString* text = [self tableView:tableView titleForFooterInSection:section];
    return [self heightForFooterText:text];
}

#pragma mark - Editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (![self _isEpisodeSection:indexPath.section]) {
        return NO;
    }

    if ([self _isPodcastMode]) {
        return (indexPath.section < (NSInteger)self.podcastSections.count); // both header rows and episode rows are editable
    }

    // Flat mode
    return ([self.cachedEpisodes count] != 0);
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;

    if ([self _isPodcastHeaderAtIndexPath:indexPath])
    {
        // Delete all downloads for this podcast
        NSDictionary *sectionInfo = self.podcastSections[indexPath.section];
        CDFeed *feed = sectionInfo[@"feed"];
        if (![feed isKindOfClass:[NSNull class]]) {
            __weak MediaFilesViewController* weakSelf = self;
            [[CacheManager sharedCacheManager] removeCacheForFeed:feed automatic:NO completion:^(__unused NSError* error) {
                [weakSelf _reloadContent];
            }];
        }
    }
    else
    {
        // Delete single episode
        CDEpisode* episode = [self _episodeAtIndexPath:indexPath];
        if (!episode) return;
        __weak MediaFilesViewController* weakSelf = self;
        [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO completion:^(__unused NSError* error) {
            [weakSelf _reloadContent];
        }];
    }
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == [self _deleteAllButtonSection])
    {
        [self clearCacheAction:indexPath];
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    // Podcast header rows are not tappable
    if ([self _isPodcastHeaderAtIndexPath:indexPath]) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    if ([self _isEpisodeSection:indexPath.section])
    {
        CDEpisode *episode = [self _episodeAtIndexPath:indexPath];
        if (!episode) return;

        NSURL* cacheURL = [[CacheManager sharedCacheManager] URLForCachedEpisode:episode];
        self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:cacheURL];
        self.interactionController.delegate = self;
        self.interactionController.name = episode.title;
        self.interactionController.UTI = @"public.data";

        CGRect cellRect = [self.tableView rectForRowAtIndexPath:indexPath];

        if (![self.interactionController presentOpenInMenuFromRect:cellRect inView:self.tableView animated:YES]) {
            self.interactionController = nil;
            [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        }
    }
}

- (void) documentInteractionControllerDidDismissOpenInMenu: (UIDocumentInteractionController *) controller
{
    self.interactionController = nil;
    [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
}


- (void) clearCacheAction:(NSIndexPath*)cellIndexPath
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    NSString* clearMessage = [cman isCaching]
        ? @"Current downloads will be cancelled before all downloaded files are deleted.".ls
        : nil;

    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:clearMessage
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Only Delete Played".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Clearing…".ls];
                                                [modelInfo show];

                                                NSMutableArray<CDEpisode*>* playedEpisodes = [NSMutableArray array];
                                                for (CDEpisode* episode in self.cachedEpisodes) {
                                                    if (episode.consumed) [playedEpisodes addObject:episode];
                                                }
                                                [[CacheManager sharedCacheManager] removeCacheForEpisodes:playedEpisodes
                                                                                                  automatic:NO
                                                                                                 completion:^(NSError* error) {
                                                    (void)error;
                                                    [self _reloadContent];
                                                    [modelInfo close];
                                                }];

                                                self.alertController = nil;
                                            }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Delete All Content".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Clearing…".ls];
                                                [modelInfo show];

                                                [cman cancelDownloadsAndClearCacheWithCompletion:^(NSError* cacheError) {
                                                    if (cacheError) {
                                                        [modelInfo close];
                                                        [self presentAlertControllerWithTitle:@"Unable to Clear Downloads".ls
                                                                                      message:cacheError.localizedDescription
                                                                                       button:@"OK".ls
                                                                                     animated:YES
                                                                                   completion:nil];
                                                        return;
                                                    }
                                                    [[ImageCacheManager sharedImageCacheManager] cancelImageDownloadsAndClearCacheWithCompletion:^(BOOL imageSuccess) {
                                                        [self _reloadContent];
                                                        [self.tableView reloadData];
                                                        [modelInfo close];
                                                        if (!imageSuccess) {
                                                            [self presentAlertControllerWithTitle:@"Unable to Clear Downloads".ls
                                                                                          message:@"Some cached images could not be deleted. Restart the app and try again.".ls
                                                                                           button:@"OK".ls
                                                                                         animated:YES
                                                                                       completion:nil];
                                                        }
                                                    }];
                                                }];

                                                self.alertController = nil;
                                            }]];

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

@end
