//
//  ICCloudInitialSyncViewController.m
//  Instacast
//

#import "ICCloudInitialSyncViewController.h"
#import "ICCloudSyncManager.h"
#import "UITableViewController+Settings.h"

typedef NS_ENUM(NSInteger, ICInitialSyncSection) {
    kSectionLocalDevice = 0,
    kSectionCloud,
    kSectionActions,
    kSectionCancel,
    kNumberOfSections,
};

typedef NS_ENUM(NSInteger, ICInitialSyncLocalRow) {
    kLocalPodcasts = 0,
    kLocalEpisodes,
    kLocalLists,
    kLocalNumberOfRows,
};

typedef NS_ENUM(NSInteger, ICInitialSyncActionRow) {
    kActionUpload = 0,
    kActionDownload,
    kActionMerge,
    kActionNumberOfRows,
};

@interface ICCloudInitialSyncViewController ()
@property (nonatomic) NSInteger cloudSubscriptionCount;
@property (nonatomic) NSInteger cloudEpisodeStatusCount;
@property (nonatomic) NSInteger cloudListCount;
@property (nonatomic) NSInteger cloudDeviceCount;
@property (nonatomic) BOOL cloudStatsLoaded;
@property (nonatomic) BOOL cloudStatsError;
@end

@implementation ICCloudInitialSyncViewController

+ (instancetype)viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.navigationItem.title = @"Initial Sync".ls;
    self.navigationItem.hidesBackButton = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

    [self loadCloudStatistics];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

- (void)loadCloudStatistics
{
    if (!self.cloudDataExists) {
        // No cloud zone → no stats to load
        self.cloudStatsLoaded = YES;
        return;
    }

    [[ICCloudSyncManager sharedManager] fetchCloudRecordCounts:^(NSDictionary<NSString *,NSNumber *> *counts, NSError *error) {
        if (error || !counts) {
            self.cloudStatsError = YES;
        } else {
            self.cloudSubscriptionCount = [counts[@"SyncSubscription"] integerValue];
            self.cloudEpisodeStatusCount = [counts[@"SyncEpisodeStatus"] integerValue];
            self.cloudListCount = [counts[@"SyncList"] integerValue];
            self.cloudDeviceCount = [counts[@"SyncDevice"] integerValue];
            self.cloudStatsLoaded = YES;
        }
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kSectionCloud] withRowAnimation:UITableViewRowAnimationAutomatic];
    }];
}

#pragma mark - Helpers

- (NSString *)pluralizedString:(NSInteger)count singular:(NSString *)singular plural:(NSString *)plural
{
    if (count == 1) {
        return singular.ls;
    }
    return [NSString stringWithFormat:plural.ls, (long)count];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kSectionLocalDevice:
            return kLocalNumberOfRows;

        case kSectionCloud:
            if (!self.cloudDataExists) return 1; // "No cloud data"
            if (self.cloudStatsError) return 1;  // Error row
            if (!self.cloudStatsLoaded) return 1; // Loading row
            return 4; // Podcasts, Episodes, Lists, Devices

        case kSectionActions:
            if (!self.cloudDataExists) return 1; // Only Upload
            return kActionNumberOfRows;

        case kSectionCancel:
            return 1;

        default:
            return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case kSectionLocalDevice:
            return [self localDeviceCellForRow:indexPath.row];

        case kSectionCloud:
            return [self cloudCellForRow:indexPath.row];

        case kSectionActions:
            return [self actionCellForRow:indexPath.row];

        case kSectionCancel:
        {
            UITableViewCell *cell = [self resetCell];
            cell.textLabel.text = @"Disable Sync".ls;
            return cell;
        }
    }
    return nil;
}

- (UITableViewCell *)localDeviceCellForRow:(NSInteger)row
{
    UITableViewCell *cell = [self infoCell];

    switch (row) {
        case kLocalPodcasts:
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.textLabel.text = [self pluralizedString:self.localPodcastCount singular:@"1 Podcast" plural:@"%ld Podcasts"];
            break;
        case kLocalEpisodes:
            cell.imageView.image = [UIImage systemImageNamed:@"play.circle"];
            cell.textLabel.text = [self pluralizedString:self.localEpisodeCount singular:@"1 Episode with playback status" plural:@"%ld Episodes with playback status"];
            break;
        case kLocalLists:
            cell.imageView.image = [UIImage systemImageNamed:@"list.bullet"];
            cell.textLabel.text = [self pluralizedString:self.localListCount singular:@"1 List" plural:@"%ld Lists"];
            break;
    }
    return cell;
}

- (UITableViewCell *)cloudCellForRow:(NSInteger)row
{
    if (!self.cloudDataExists) {
        UITableViewCell *cell = [self infoCell];
        cell.imageView.image = [UIImage systemImageNamed:@"icloud.slash"];
        cell.textLabel.text = @"No cloud data found.".ls;
        cell.textLabel.textColor = ICMutedTextColor;
        return cell;
    }

    if (self.cloudStatsError) {
        UITableViewCell *cell = [self infoCell];
        cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.icloud"];
        cell.textLabel.text = @"Could not load cloud data.".ls;
        cell.textLabel.textColor = [UIColor systemRedColor];
        return cell;
    }

    if (!self.cloudStatsLoaded) {
        UITableViewCell *cell = [self infoCell];
        cell.imageView.image = [UIImage systemImageNamed:@"icloud"];
        cell.textLabel.text = @"Loading cloud data…".ls;
        cell.textLabel.textColor = ICMutedTextColor;
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        return cell;
    }

    UITableViewCell *cell = [self infoCell];
    switch (row) {
        case 0:
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.textLabel.text = [self pluralizedString:self.cloudSubscriptionCount singular:@"1 Podcast" plural:@"%ld Podcasts"];
            break;
        case 1:
            cell.imageView.image = [UIImage systemImageNamed:@"play.circle"];
            cell.textLabel.text = [self pluralizedString:self.cloudEpisodeStatusCount singular:@"1 Episode with playback status" plural:@"%ld Episodes with playback status"];
            break;
        case 2:
            cell.imageView.image = [UIImage systemImageNamed:@"list.bullet"];
            cell.textLabel.text = [self pluralizedString:self.cloudListCount singular:@"1 List" plural:@"%ld Lists"];
            break;
        case 3:
            cell.imageView.image = [UIImage systemImageNamed:@"desktopcomputer"];
            cell.textLabel.text = [self pluralizedString:self.cloudDeviceCount singular:@"1 Device" plural:@"%ld Devices"];
            break;
    }
    return cell;
}

- (UITableViewCell *)actionCellForRow:(NSInteger)row
{
    UITableViewCell *cell = [self buttonCell];

    if (!self.cloudDataExists) {
        // Only option: Upload
        cell.textLabel.text = @"Upload Local Data".ls;
        cell.imageView.image = [UIImage systemImageNamed:@"arrow.up.circle"];
        cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
        return cell;
    }

    switch (row) {
        case kActionUpload:
            cell.textLabel.text = @"Upload Local Data".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.up.circle"];
            cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
            break;
        case kActionDownload:
            cell.textLabel.text = @"Download from iCloud".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle"];
            cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
            break;
        case kActionMerge:
            cell.textLabel.text = @"Merge".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.triangle.merge"];
            cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
            break;
    }
    return cell;
}

- (UITableViewCell *)infoCell
{
    static NSString *InfoCellID = @"InfoCell";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:InfoCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:InfoCellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.textLabel.textColor = ICTextColor;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.imageView.tintColor = ICMutedTextColor;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

#pragma mark - Headers & Footers

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kSectionLocalDevice:
            return @"This Device".ls;
        case kSectionCloud:
            return @"iCloud";
        case kSectionActions:
            return @"Choose Action".ls;
        default:
            return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section) {
        case kSectionLocalDevice:
            return @"Data currently stored on this device.".ls;

        case kSectionCloud:
            if (!self.cloudDataExists) {
                return @"No cloud data found. Your local data will be uploaded.".ls;
            }
            return @"Data stored in your iCloud account.".ls;

        case kSectionActions:
            if (!self.cloudDataExists) {
                return nil;
            }
            return @"Upload replaces cloud data with this device's data. Download replaces local data with cloud data. Merge combines both — conflicts are resolved by most recent change.".ls;

        default:
            return nil;
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *footerView = (UITableViewHeaderFooterView *)view;
        footerView.textLabel.textColor = [UIColor grayColor];
    }
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == kSectionActions) {
        if (!self.cloudDataExists) {
            // Only option = Upload
            [self finishWithAction:ICInitialSyncActionUpload];
            return;
        }

        switch (indexPath.row) {
            case kActionUpload:
                [self confirmUpload];
                break;
            case kActionDownload:
                [self finishWithAction:ICInitialSyncActionDownload];
                break;
            case kActionMerge:
                [self finishWithAction:ICInitialSyncActionMerge];
                break;
        }
    } else if (indexPath.section == kSectionCancel) {
        [self finishWithAction:ICInitialSyncActionCancel];
    }
}

#pragma mark - Actions

- (void)confirmUpload
{
    // Warn if cloud has more data than local
    if (self.cloudStatsLoaded && self.cloudSubscriptionCount > self.localPodcastCount) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Upload Local Data".ls
                                                                      message:@"iCloud contains more podcasts than this device. Uploading will replace cloud data. Other devices may lose podcasts. Are you sure?".ls
                                                               preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Upload".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [self finishWithAction:ICInitialSyncActionUpload];
        }]];

        if ([ICAppearanceManager sharedManager].nightSettingMode) {
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        } else {
            alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        }

        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self finishWithAction:ICInitialSyncActionUpload];
    }
}

- (void)finishWithAction:(ICInitialSyncAction)action
{
    if (self.completionBlock) {
        self.completionBlock(action);
    }
}

@end
