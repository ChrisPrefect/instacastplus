//
//  iCloudSettingsViewController.m
//  Instacast
//

#import "iCloudSettingsViewController.h"
#import "ICCloudSyncManager.h"
#import "ICCloudInitialSyncViewController.h"
#import "UITableViewController+Settings.h"

typedef NS_ENUM(NSInteger, iCloudSettingsSections) {
    kICloudMasterSection = 0,
    kICloudCategoriesSection,
    kICloudStatusSection,
    kICloudDevicesSection,
};

typedef NS_ENUM(NSInteger, iCloudCategoryRows) {
    kCategoryNowPlaying = 0,
    kCategoryPlaybackStatus,
    kCategorySubscriptions,
    kCategoryFeedSettings,
    kCategoryLists,
    kCategoryUpNext,
    kCategoryAppSettings,
    kCategoryDownloadStatus,
    kCategoryNumberOfRows,
};

typedef NS_ENUM(NSInteger, iCloudStatusRows) {
    kStatusLastSync = 0,
    kStatusSyncNow,
    kStatusReset,
    kStatusNumberOfRows,
};

@interface iCloudSettingsViewController ()
@property (nonatomic, strong) NSArray<ICCloudSyncDeviceInfo *> *devices;
@property (nonatomic, strong) NSTimer *relativeTimeTimer;
@end

@implementation iCloudSettingsViewController

+ (iCloudSettingsViewController*) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
        _devices = @[];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"iCloud".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(syncStateChanged)
                                                 name:ICCloudSyncManagerDidSyncNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(devicesUpdated)
                                                 name:ICCloudSyncManagerDidUpdateDevicesNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(syncProgressChanged)
                                                 name:ICCloudSyncManagerDidUpdateProgressNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
    [self loadDevices];
    [self startRelativeTimeUpdates];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self stopRelativeTimeUpdates];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView reloadData];
}

- (void)dealloc
{
    [self stopRelativeTimeUpdates];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)startRelativeTimeUpdates
{
    [self stopRelativeTimeUpdates];
    self.relativeTimeTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                               target:self
                                                             selector:@selector(updateRelativeTimeUI)
                                                             userInfo:nil
                                                              repeats:YES];
}

- (void)stopRelativeTimeUpdates
{
    [self.relativeTimeTimer invalidate];
    self.relativeTimeTimer = nil;
}

- (void)updateRelativeTimeUI
{
    [self updateLastSyncCell];
}

- (void)updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

- (void)syncStateChanged
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateLastSyncCell];
        [self updateSyncNowCell];
    });
}

- (void)syncProgressChanged
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateSyncNowCell];
    });
}

- (void)devicesUpdated
{
    dispatch_async(dispatch_get_main_queue(), ^{
        self.devices = [ICCloudSyncManager sharedManager].devices;
        [self.tableView reloadData];
    });
}

- (void)loadDevices
{
    // Always try to load devices, even when sync is off
    self.devices = [ICCloudSyncManager sharedManager].devices;

    [[ICCloudSyncManager sharedManager] checkAccountStatus:^(BOOL available) {
        if (!available) {
            self.devices = @[];
            [self.tableView reloadData];
            return;
        }
        [[ICCloudSyncManager sharedManager] fetchDeviceList];
    }];
}

#pragma mark - Section Mapping

- (iCloudSettingsSections)typeForSection:(NSInteger)section
{
    BOOL enabled = [self masterEnabled];
    if (section == 0) return kICloudMasterSection;
    if (enabled) {
        if (section == 1) return kICloudCategoriesSection;
        if (section == 2) return kICloudStatusSection;
        if (section == 3) return kICloudDevicesSection;
    } else {
        if (section == 1 && self.devices.count > 0) return kICloudDevicesSection;
    }
    return kICloudMasterSection;
}

- (NSInteger)sectionForType:(iCloudSettingsSections)type
{
    BOOL enabled = [self masterEnabled];
    switch (type) {
        case kICloudMasterSection: return 0;
        case kICloudCategoriesSection: return enabled ? 1 : NSNotFound;
        case kICloudStatusSection: return enabled ? 2 : NSNotFound;
        case kICloudDevicesSection:
            if (self.devices.count == 0) return NSNotFound;
            return enabled ? 3 : 1;
    }
    return NSNotFound;
}

#pragma mark - Cell Updates

- (void)updateLastSyncCell
{
    if (!self.tableView.window) return;
    NSInteger statusSection = [self sectionForType:kICloudStatusSection];
    if (statusSection == NSNotFound) return;

    NSIndexPath *path = [NSIndexPath indexPathForRow:kStatusLastSync inSection:statusSection];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if (cell) {
        cell.detailTextLabel.text = [self lastSyncText];
    }
}

- (void)updateSyncNowCell
{
    if (![self masterEnabled]) return;
    if (!self.tableView.window) return;
    NSInteger statusSection = [self sectionForType:kICloudStatusSection];
    if (statusSection == NSNotFound) return;

    NSIndexPath *path = [NSIndexPath indexPathForRow:kStatusSyncNow inSection:statusSection];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
    if (!cell) return;

    ICCloudSyncManager *mgr = [ICCloudSyncManager sharedManager];
    if (mgr.isSyncing && mgr.syncProgressTotal > 0) {
        cell.textLabel.text = [NSString stringWithFormat:@"%@ (%ld/%ld)", @"Syncing…".ls, (long)mgr.syncProgressCompleted, (long)mgr.syncProgressTotal];
        cell.userInteractionEnabled = NO;
        cell.textLabel.alpha = 0.5;
    } else {
        cell.textLabel.text = @"Sync Now".ls;
        cell.userInteractionEnabled = YES;
        cell.textLabel.alpha = 1.0;
    }
}

- (NSString *)lastSyncText
{
    NSDate *lastSync = [USER_DEFAULTS objectForKey:iCloudSyncLastSyncDate];
    return [self relativeTimeStringFromDate:lastSync];
}

- (NSString *)relativeTimeStringFromDate:(NSDate *)date
{
    if (!date) {
        return @"Never".ls;
    }

    NSTimeInterval interval = -[date timeIntervalSinceNow];
    if (interval < 60) {
        return @"just now".ls;
    } else if (interval < 3600) {
        return [NSString stringWithFormat:@"%ld min ago".ls, (long)(interval / 60)];
    } else if (interval < 86400) {
        return [NSString stringWithFormat:@"%ld hours ago".ls, (long)(interval / 3600)];
    } else {
        return [NSString stringWithFormat:@"%ld days ago".ls, (long)(interval / 86400)];
    }
}

- (NSString *)localizedCategoryName:(NSString *)category
{
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"playback": @"Playback Status",
            @"nowplaying": @"Now Playing",
            @"subscriptions": @"Subscriptions",
            @"feedsettings": @"Podcast Settings",
            @"lists": @"Lists",
            @"upnext": @"Play Next",
            @"appsettings": @"App Settings",
            @"downloads": @"Download Status",
        };
    });
    NSString *key = map[category];
    return key ? key.ls : category;
}

- (BOOL)masterEnabled
{
    return [USER_DEFAULTS boolForKey:iCloudSyncEnabled];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    BOOL enabled = [self masterEnabled];
    if (enabled) {
        NSInteger sections = 3; // master + categories + status
        if (self.devices.count > 0) sections++; // + devices
        return sections;
    } else {
        NSInteger sections = 1; // master only
        if (self.devices.count > 0) sections++; // + devices even when disabled
        return sections;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch ([self typeForSection:section]) {
        case kICloudMasterSection:
            return 1;
        case kICloudCategoriesSection:
            return kCategoryNumberOfRows;
        case kICloudStatusSection:
            return kStatusNumberOfRows;
        case kICloudDevicesSection:
            return self.devices.count;
        default:
            return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch ([self typeForSection:indexPath.section]) {
        case kICloudMasterSection:
        {
            UITableViewCell *cell = [self switchCell];
            UISwitch *control = (UISwitch*)cell.accessoryView;
            cell.textLabel.text = @"iCloud Sync".ls;
            control.on = [USER_DEFAULTS boolForKey:iCloudSyncEnabled];
            control.tag = 100;
            [control addTarget:self action:@selector(toggleMaster:) forControlEvents:UIControlEventValueChanged];
            return cell;
        }

        case kICloudCategoriesSection:
        {
            UITableViewCell *cell = [self switchCell];
            UISwitch *control = (UISwitch*)cell.accessoryView;
            control.tag = 200 + indexPath.row;
            [control addTarget:self action:@selector(toggleCategory:) forControlEvents:UIControlEventValueChanged];

            switch (indexPath.row) {
                case kCategoryPlaybackStatus:
                    cell.textLabel.text = @"Playback Status".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncPlaybackStatus];
                    break;
                case kCategoryNowPlaying:
                    cell.textLabel.text = @"Now Playing".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncNowPlaying];
                    break;
                case kCategorySubscriptions:
                    cell.textLabel.text = @"Subscriptions".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncSubscriptions];
                    break;
                case kCategoryFeedSettings:
                    cell.textLabel.text = @"Podcast Settings".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncFeedSettings];
                    break;
                case kCategoryLists:
                    cell.textLabel.text = @"Lists".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncLists];
                    break;
                case kCategoryUpNext:
                    cell.textLabel.text = @"Play Next".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncUpNext];
                    break;
                case kCategoryAppSettings:
                    cell.textLabel.text = @"App Settings".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncAppSettings];
                    break;
                case kCategoryDownloadStatus:
                    cell.textLabel.text = @"Download Status".ls;
                    control.on = [USER_DEFAULTS boolForKey:iCloudSyncDownloadStatus];
                    break;
            }
            return cell;
        }

        case kICloudStatusSection:
        {
            switch (indexPath.row) {
                case kStatusLastSync:
                {
                    UITableViewCell *cell = [self detailCell];
                    cell.textLabel.text = @"Last Synced".ls;
                    cell.detailTextLabel.text = [self lastSyncText];
                    cell.accessoryType = UITableViewCellAccessoryNone;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    return cell;
                }
                case kStatusSyncNow:
                {
                    UITableViewCell *cell = [self buttonCell];
                    ICCloudSyncManager *mgr = [ICCloudSyncManager sharedManager];
                    if (mgr.isSyncing && mgr.syncProgressTotal > 0) {
                        cell.textLabel.text = [NSString stringWithFormat:@"%@ (%ld/%ld)", @"Syncing…".ls, (long)mgr.syncProgressCompleted, (long)mgr.syncProgressTotal];
                        cell.userInteractionEnabled = NO;
                        cell.textLabel.alpha = 0.5;
                    } else {
                        cell.textLabel.text = @"Sync Now".ls;
                        cell.userInteractionEnabled = YES;
                        cell.textLabel.alpha = 1.0;
                    }
                    return cell;
                }
                case kStatusReset:
                {
                    UITableViewCell *cell = [self resetCell];
                    cell.textLabel.text = @"Reset Sync Data".ls;
                    return cell;
                }
            }
            break;
        }

        case kICloudDevicesSection:
        {
            static NSString *deviceCellID = @"DeviceCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:deviceCellID];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:deviceCellID];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.detailTextLabel.numberOfLines = 0;
            }

            ICCloudSyncDeviceInfo *device = self.devices[indexPath.row];

            // Title: "Chris' iPhone — iPhone16,1 · iOS 18.5"
            NSMutableString *title = [NSMutableString stringWithString:device.deviceName ?: @"Unknown".ls];
            NSMutableArray *modelParts = [NSMutableArray array];
            if (device.deviceModel.length > 0) [modelParts addObject:device.deviceModel];
            if (device.systemVersion.length > 0) [modelParts addObject:[NSString stringWithFormat:@"iOS %@", device.systemVersion]];
            if (modelParts.count > 0) {
                [title appendFormat:@" — %@", [modelParts componentsJoinedByString:@" · "]];
            }
            cell.textLabel.text = title;
            cell.textLabel.font = [UIFont systemFontOfSize:15];
            cell.textLabel.textColor = ICTextColor;

            // Subtitle: "Letzter Sync: vor 5 min · Abos, Abspielstatus, Downloads"
            NSMutableString *detail = [NSMutableString string];
            [detail appendFormat:@"%@: %@", @"Last Synced".ls, [self relativeTimeStringFromDate:device.lastSyncDate]];
            if (device.activeCategories.count > 0) {
                NSMutableArray *names = [NSMutableArray array];
                for (NSString *cat in device.activeCategories) {
                    [names addObject:[self localizedCategoryName:cat]];
                }
                [detail appendFormat:@"\n%@", [names componentsJoinedByString:@", "]];
            }
            cell.detailTextLabel.text = detail;
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
            cell.detailTextLabel.textColor = [UIColor grayColor];

            cell.backgroundColor = ICGroupCellBackgroundColor;
            return cell;
        }
    }

    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self typeForSection:indexPath.section] == kICloudDevicesSection) {
        return UITableViewAutomaticDimension;
    }
    return tableView.rowHeight;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self typeForSection:indexPath.section] == kICloudDevicesSection) {
        return 64;
    }
    return tableView.estimatedRowHeight;
}

- (NSString*)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch ([self typeForSection:section]) {
        case kICloudCategoriesSection:
            return @"Sync Categories".ls;
        case kICloudDevicesSection:
            return @"Devices".ls;
        default:
            return nil;
    }
}

- (NSString*)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch ([self typeForSection:section]) {
        case kICloudMasterSection:
            return @"Syncs data between your devices via iCloud.".ls;
        case kICloudCategoriesSection:
            return @"Select which data to sync between your devices.".ls;
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

    if ([self typeForSection:indexPath.section] == kICloudStatusSection) {
        if (indexPath.row == kStatusSyncNow) {
            [self syncNow];
        } else if (indexPath.row == kStatusReset) {
            [self resetSyncData];
        }
    }
}

#pragma mark - Actions

- (void)toggleMaster:(UISwitch*)sender
{
    if (sender.on) {
        // Check iCloud account first
        [[ICCloudSyncManager sharedManager] checkAccountStatus:^(BOOL available) {
            if (!available) {
                sender.on = NO;
                [self showNoAccountAlert];
                return;
            }

            [USER_DEFAULTS setBool:YES forKey:iCloudSyncEnabled];
            [USER_DEFAULTS synchronize];

            [[ICCloudSyncManager sharedManager] start];
            [self.tableView reloadData];

            // Always show initial sync dialog
            [self showInitialSyncDialog];
        }];
    } else {
        [USER_DEFAULTS setBool:NO forKey:iCloudSyncEnabled];
        [USER_DEFAULTS synchronize];
        [[ICCloudSyncManager sharedManager] stop];
        [self.tableView reloadData];
    }
}

- (void)toggleCategory:(UISwitch*)sender
{
    NSString *key = nil;
    switch (sender.tag - 200) {
        case kCategoryPlaybackStatus:
            key = iCloudSyncPlaybackStatus;
            break;
        case kCategoryNowPlaying:
            key = iCloudSyncNowPlaying;
            break;
        case kCategorySubscriptions:
            key = iCloudSyncSubscriptions;
            break;
        case kCategoryFeedSettings:
            key = iCloudSyncFeedSettings;
            break;
        case kCategoryLists:
            key = iCloudSyncLists;
            break;
        case kCategoryUpNext:
            key = iCloudSyncUpNext;
            break;
        case kCategoryAppSettings:
            key = iCloudSyncAppSettings;
            break;
        case kCategoryDownloadStatus:
            key = iCloudSyncDownloadStatus;
            break;
    }

    if (key) {
        [USER_DEFAULTS setBool:sender.on forKey:key];
        [USER_DEFAULTS synchronize];
    }
}

- (void)syncNow
{
    ICCloudSyncManager *mgr = [ICCloudSyncManager sharedManager];
    if (mgr.isSyncing) return;

    // Start manager if not yet started
    if (!mgr.isStarted) {
        [mgr start];
    }
    [mgr syncNow];
}

- (void)resetSyncData
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Sync Data".ls
                                                                  message:@"Are you sure you want to reset all sync data? This will remove all cloud data for this app.".ls
                                                           preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[NSNotificationCenter defaultCenter] postNotificationName:ICCloudSyncManagerResetNotification object:nil];
        [USER_DEFAULTS removeObjectForKey:iCloudSyncLastSyncDate];
        [USER_DEFAULTS removeObjectForKey:iCloudSyncServerChangeToken];
        [USER_DEFAULTS setBool:NO forKey:iCloudSyncInitialSyncCompleted];
        [USER_DEFAULTS synchronize];
        [self.tableView reloadData];
    }]];

    if ([ICAppearanceManager sharedManager].nightSettingMode) {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Initial Sync Dialog

- (void)showNoAccountAlert
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No iCloud Account".ls
                                                                  message:@"Please sign in to iCloud in Settings to use sync.".ls
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

    if ([ICAppearanceManager sharedManager].nightSettingMode) {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showInitialSyncDialog
{
    // Compute local stats on main thread (Core Data context is main queue)
    NSInteger localPodcastCount = DMANAGER.feeds.count;

    NSFetchRequest *episodeRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    episodeRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES"];
    NSInteger localEpisodeCount = [DMANAGER.objectContext countForFetchRequest:episodeRequest error:nil];

    NSInteger localListCount = DMANAGER.lists.count;

    // Check if cloud data exists (determines which options are shown)
    [[ICCloudSyncManager sharedManager] checkCloudDataExists:^(BOOL exists) {
        if (!exists) {
            // No cloud data — just push local data directly
            [self performInitialUpload];
            return;
        }

        // Cloud data exists — show dedicated sync screen
        ICCloudInitialSyncViewController *syncVC = [ICCloudInitialSyncViewController viewController];
        syncVC.cloudDataExists = exists;
        syncVC.localPodcastCount = localPodcastCount;
        syncVC.localEpisodeCount = localEpisodeCount;
        syncVC.localListCount = localListCount;

        WEAK_SELF;
        syncVC.completionBlock = ^(ICInitialSyncAction action) {
            STRONG_SELF;
            [self.navigationController popViewControllerAnimated:YES];

            switch (action) {
                case ICInitialSyncActionCancel:
                    [USER_DEFAULTS setBool:NO forKey:iCloudSyncEnabled];
                    [USER_DEFAULTS synchronize];
                    [[ICCloudSyncManager sharedManager] stop];
                    [self.tableView reloadData];
                    break;
                case ICInitialSyncActionUpload:
                    [self performInitialUpload];
                    break;
                case ICInitialSyncActionDownload:
                    [self performInitialDownload];
                    break;
                case ICInitialSyncActionMerge:
                    [self performInitialMerge];
                    break;
            }
        };

        [self.navigationController pushViewController:syncVC animated:YES];
    }];
}

- (void)performInitialUpload
{
    self.navigationItem.title = @"Syncing…".ls;
    [[ICCloudSyncManager sharedManager] pushAllDataWithCompletion:^(NSError *error) {
        self.navigationItem.title = @"iCloud".ls;
        [self.tableView reloadData];
    }];
}

- (void)performInitialDownload
{
    self.navigationItem.title = @"Syncing…".ls;
    [[ICCloudSyncManager sharedManager] fetchAllDataWithCompletion:^(NSError *error) {
        self.navigationItem.title = @"iCloud".ls;
        [self.tableView reloadData];
    }];
}

- (void)performInitialMerge
{
    self.navigationItem.title = @"Syncing…".ls;
    // Merge: first pull cloud data (Last-Write-Wins applies), then push local data
    [[ICCloudSyncManager sharedManager] fetchAllDataWithCompletion:^(NSError *error) {
        [[ICCloudSyncManager sharedManager] pushAllDataWithCompletion:^(NSError *error) {
            self.navigationItem.title = @"iCloud".ls;
            [self.tableView reloadData];
        }];
    }];
}

@end
