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
static NSString* PlaceholderCellIdentifier = @"PlaceholderCell";
static NSString* SettingCellIdentifier = @"SettingCell";
static NSString* MediaFilesSortModeKey = @"MediaFilesSortMode";

@interface MediaFilesViewController () <UIDocumentInteractionControllerDelegate>
@property (nonatomic, strong) NSArray* cachedEpisodes;
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@property (nonatomic) MediaFilesSortMode sortMode;
@property (nonatomic, strong) UISegmentedControl *sortControl;
@property (nonatomic, strong) NSArray<NSDictionary*> *podcastSections;
@end

@implementation MediaFilesViewController

+ (id) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (CDEpisode *)_episodeAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.sortMode == kSortByPodcast && self.podcastSections) {
        if (indexPath.section < (NSInteger)self.podcastSections.count) {
            NSArray *episodes = self.podcastSections[indexPath.section][@"episodes"];
            if (indexPath.row < (NSInteger)episodes.count) {
                return episodes[indexPath.row];
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
    if (self.sortMode == kSortByPodcast && self.podcastSections) {
        return self.podcastSections.count;
    }
    return 1; // kDeleteAllButton
}

- (BOOL)_isEpisodeSection:(NSInteger)section
{
    if (self.sortMode == kSortByPodcast && self.podcastSections) {
        return section < (NSInteger)self.podcastSections.count;
    }
    return section == 0; // kDownloadedSection
}

- (void) _reloadContent
{
    NSArray *allEpisodes = [[CacheManager sharedCacheManager] cachedEpisodes];

    switch (self.sortMode) {
        case kSortBySize:
        {
            self.podcastSections = nil;
            self.cachedEpisodes = [allEpisodes sortedArrayUsingComparator:^NSComparisonResult(CDEpisode *episode1, CDEpisode *episode2) {
                unsigned long long fileSize1 = [[CacheManager sharedCacheManager] numberOfDownloadedBytesForEpisode:episode1];
                unsigned long long fileSize2 = [[CacheManager sharedCacheManager] numberOfDownloadedBytesForEpisode:episode2];

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
            // Group by feed
            NSMutableDictionary<NSString*, NSMutableArray*> *grouped = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString*, CDFeed*> *feedMap = [NSMutableDictionary dictionary];

            for (CDEpisode *episode in allEpisodes) {
                NSString *feedTitle = episode.feed.title ?: @"";
                if (!grouped[feedTitle]) {
                    grouped[feedTitle] = [NSMutableArray array];
                    feedMap[feedTitle] = episode.feed;
                }
                [grouped[feedTitle] addObject:episode];
            }

            // Sort feed titles alphabetically
            NSArray *sortedTitles = [grouped.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];

            NSMutableArray *sections = [NSMutableArray array];
            for (NSString *title in sortedTitles) {
                // Sort episodes within group by pubDate descending
                NSArray *sortedEpisodes = [grouped[title] sortedArrayUsingComparator:^NSComparisonResult(CDEpisode *ep1, CDEpisode *ep2) {
                    NSDate *d1 = ep1.pubDate;
                    NSDate *d2 = ep2.pubDate;
                    if (!d1 && !d2) return NSOrderedSame;
                    if (!d1) return NSOrderedDescending;
                    if (!d2) return NSOrderedAscending;
                    return [d2 compare:d1];
                }];
                [sections addObject:@{ @"feed": feedMap[title] ?: [NSNull null], @"episodes": sortedEpisodes }];
            }

            self.podcastSections = sections;
            self.cachedEpisodes = allEpisodes; // keep for clearCacheAction
            break;
        }
    }
}

- (void) _setupTableHeaderView
{
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 74)];

    // Segmented Control
    self.sortControl = [[UISegmentedControl alloc] initWithItems:@[@"Size".ls, @"Date".ls, @"Podcast".ls]];
    self.sortControl.selectedSegmentIndex = self.sortMode;
    [self.sortControl addTarget:self action:@selector(sortModeChanged:) forControlEvents:UIControlEventValueChanged];
    self.sortControl.translatesAutoresizingMaskIntoConstraints = NO;

    // Hint Label
    UILabel *hintLabel = [[UILabel alloc] init];
    hintLabel.text = @"Swipe left to delete.".ls;
    hintLabel.font = [UIFont systemFontOfSize:12];
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
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    // Update hint label color
    UILabel *hintLabel = [self.tableView.tableHeaderView viewWithTag:100];
    hintLabel.textColor = ICMutedTextColor;

    [[CacheManager sharedCacheManager] autoClearAndMakeRoomForBytes:0 automatic:YES];
    [self _reloadContent];
    [self.tableView reloadData];
}

- (void) dealloc
{
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
    // Dispose of any resources that can be recreated.
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
    if (self.sortMode == kSortByPodcast && self.podcastSections) {
        return self.podcastSections.count + 1; // +1 for delete button
    }
    return 2; // episodes + delete button
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == [self _deleteAllButtonSection]) {
        return 1;
    }

    if (self.sortMode == kSortByPodcast && self.podcastSections) {
        if (section < (NSInteger)self.podcastSections.count) {
            return [self.podcastSections[section][@"episodes"] count];
        }
        return 0;
    }

    // Flat mode (size or date)
    return MAX(1, [self.cachedEpisodes count]);
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == [self _deleteAllButtonSection])
    {
        UITableViewCell* cell = [self resetCell];
        cell.userInteractionEnabled = YES;
        cell.textLabel.text = @"Delete Content".ls;
        return cell;
    }

    if (self.sortMode == kSortByPodcast && self.podcastSections)
    {
        // Podcast mode — always has episodes (empty feeds wouldn't appear)
        CDEpisode *episode = [self _episodeAtIndexPath:indexPath];
        if (!episode) return [[UITableViewCell alloc] init];

        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.textLabel.font = [UIFont systemFontOfSize:13];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        }

        cell.backgroundColor = ICGroupCellBackgroundColor;
        cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
        cell.detailTextLabel.textColor = ICMutedTextColor;

        UILabel* sizeLabel = (UILabel*)cell.accessoryView;
        if (!sizeLabel) {
            sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, (44-20)/2, 65, 20)];
            sizeLabel.font = [UIFont systemFontOfSize:14];
            sizeLabel.textAlignment = NSTextAlignmentRight;
            sizeLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
            cell.accessoryView = sizeLabel;
        }

        CDFeed* feed = episode.feed;
        cell.textLabel.text = [episode cleanTitleUsingFeedTitle:feed.title];

        unsigned long long bytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytesForEpisode:episode];
        cell.detailTextLabel.text = feed.title;

        cell.textLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;
        sizeLabel.text = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];

        return cell;
    }

    // Flat mode (size or date)
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
        cell.textLabel.font = [UIFont italicSystemFontOfSize:15];
        cell.textLabel.textColor = ICMutedTextColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        return cell;
    }
    else
    {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
            cell.selectedBackgroundView = [[UIView alloc] init];
            cell.textLabel.font = [UIFont systemFontOfSize:13];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
        }

        cell.backgroundColor = ICGroupCellBackgroundColor;
        cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
        cell.detailTextLabel.textColor = ICMutedTextColor;

        UILabel* sizeLabel = (UILabel*)cell.accessoryView;
        if (!sizeLabel) {
            sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, (44-20)/2, 65, 20)];
            sizeLabel.font = [UIFont systemFontOfSize:14];
            sizeLabel.textAlignment = NSTextAlignmentRight;
            sizeLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
            cell.accessoryView = sizeLabel;
        }

        CDEpisode* episode = episodes[indexPath.row];
        CDFeed* feed = episode.feed;

        cell.textLabel.text = [episode cleanTitleUsingFeedTitle:feed.title];

        unsigned long long bytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytesForEpisode:episode];
        cell.detailTextLabel.text = feed.title;

        cell.textLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;
        sizeLabel.text = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];

        return cell;
    }
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
    if (self.sortMode == kSortByPodcast && self.podcastSections) {
        return nil; // Custom header views in podcast mode
    }
    if (section == 0) {
        return @"Downloaded Content".ls;
    }
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (self.sortMode != kSortByPodcast || !self.podcastSections) {
        return nil;
    }
    if (section >= (NSInteger)self.podcastSections.count) {
        return nil;
    }

    NSDictionary *sectionInfo = self.podcastSections[section];
    CDFeed *feed = sectionInfo[@"feed"];
    NSString *title = ([feed isKindOfClass:[NSNull class]]) ? @"" : feed.title;

    UIView *headerView = [[UIView alloc] init];

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title.uppercaseString;
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    titleLabel.textColor = [UIColor grayColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [deleteButton setImage:[UIImage systemImageNamed:@"trash"] forState:UIControlStateNormal];
    deleteButton.tintColor = [UIColor systemRedColor];
    deleteButton.tag = section;
    [deleteButton addTarget:self action:@selector(deletePodcastSection:) forControlEvents:UIControlEventTouchUpInside];
    deleteButton.translatesAutoresizingMaskIntoConstraints = NO;

    [headerView addSubview:titleLabel];
    [headerView addSubview:deleteButton];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:20],
        [titleLabel.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:deleteButton.leadingAnchor constant:-8],

        [deleteButton.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-20],
        [deleteButton.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        [deleteButton.widthAnchor constraintEqualToConstant:30],
        [deleteButton.heightAnchor constraintEqualToConstant:30],
    ]];

    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if (self.sortMode == kSortByPodcast && self.podcastSections && section < (NSInteger)self.podcastSections.count) {
        return 36.0f;
    }
    return UITableViewAutomaticDimension;
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
}

#pragma mark - Delete podcast section

- (void) deletePodcastSection:(UIButton *)sender
{
    NSInteger section = sender.tag;
    if (section >= (NSInteger)self.podcastSections.count) return;

    NSDictionary *sectionInfo = self.podcastSections[section];
    CDFeed *feed = sectionInfo[@"feed"];
    if ([feed isKindOfClass:[NSNull class]]) return;

    NSString *message = [NSString stringWithFormat:@"Delete all downloads from '%@'?".ls, feed.title];

    WEAK_SELF
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Delete".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
        STRONG_SELF
        [[CacheManager sharedCacheManager] removeCacheForFeed:feed automatic:NO];
        [self _reloadContent];
        [self.tableView reloadData];
    }]];

    if ([ICAppearanceManager sharedManager].nightSettingMode) {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Editing

// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete)
    {
        CDEpisode* episode = [self _episodeAtIndexPath:indexPath];
        if (!episode) return;

        [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];

        [self _reloadContent];
        [self.tableView reloadData];
    }
    else if (editingStyle == UITableViewCellEditingStyleInsert) {
        // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (![self _isEpisodeSection:indexPath.section]) {
        return NO;
    }

    if (self.sortMode == kSortByPodcast && self.podcastSections) {
        return YES; // podcast mode always has episodes in episode sections
    }

    // Flat mode
    return ([self.cachedEpisodes count] != 0);
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

    if ([cman isCaching])
    {
        [self presentAlertControllerWithTitle:@"Currently Downloading".ls
                                      message:@"Clearing the cache is not possible while Instacast is downloading episodes. Please try again later.".ls
                                       button:@"OK".ls
                                     animated:YES
                                   completion:NULL];
        return;
    }

    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"Only Delete Played".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Clearing…".ls];
                                                [modelInfo show];

                                                [self perform:^(id sender) {

                                                    for(CDEpisode* episode in self.cachedEpisodes) {
                                                        if (episode.consumed) {
                                                            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
                                                        }
                                                    }

                                                    [self _reloadContent];
                                                    [self.tableView reloadData];
                                                    [modelInfo close];
                                                } afterDelay:0.3f];

                                                self.alertController = nil;
                                            }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Delete All Content".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Clearing…".ls];
                                                [modelInfo show];

                                                [self perform:^(id sender) {
                                                    [cman clearTheFuckingCache];
                                                    [[ImageCacheManager sharedImageCacheManager] clearTheFuckingCache];
                                                    [self _reloadContent];
                                                    [self.tableView reloadData];
                                                    [modelInfo close];
                                                } afterDelay:0.3f];

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
