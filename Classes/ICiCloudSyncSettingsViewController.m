//
//  ICiCloudSyncSettingsViewController.m
//  Instacast
//

#import "ICiCloudSyncSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "InstacastPlus-Swift.h"

typedef NS_ENUM(NSInteger, ICiCloudSyncSettingsSection) {
    ICiCloudSyncSettingsSectionStatus = 0,
    ICiCloudSyncSettingsSectionOptions,
    ICiCloudSyncSettingsSectionDevices,
    ICiCloudSyncSettingsSectionCount,
};

typedef NS_ENUM(NSInteger, ICiCloudSyncOptionRow) {
    ICiCloudSyncOptionRowEpisodes = 0,
    ICiCloudSyncOptionRowSubscriptions,
    ICiCloudSyncOptionRowSettings,
    ICiCloudSyncOptionRowCount,
};

@interface ICiCloudSyncSettingsViewController ()
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@end

@implementation ICiCloudSyncSettingsViewController

+ (ICiCloudSyncSettingsViewController*)viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];
    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"iCloud Sync".ls;

    self.dateFormatter = [[NSDateFormatter alloc] init];
    self.dateFormatter.dateStyle = NSDateFormatterShortStyle;
    self.dateFormatter.timeStyle = NSDateFormatterShortStyle;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(syncStateDidChange:) name:ICiCloudSyncStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(syncStateDidChange:) name:ICiCloudSyncDevicesDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

    [[ICiCloudSyncManager sharedManager] start];
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
    [self.tableView reloadData];
}

- (void)syncStateDidChange:(NSNotification*)notification
{
    [self.tableView reloadData];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return ICiCloudSyncSettingsSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case ICiCloudSyncSettingsSectionStatus:
            return 2;
        case ICiCloudSyncSettingsSectionOptions:
            return ICiCloudSyncOptionRowCount;
        case ICiCloudSyncSettingsSectionDevices:
            return MAX(1, [ICiCloudSyncManager sharedManager].devices.count);
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == ICiCloudSyncSettingsSectionStatus) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [self detailCell];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"Status".ls;
            cell.detailTextLabel.text = [ICiCloudSyncManager sharedManager].statusText;
            return cell;
        }

        UITableViewCell *cell = [self buttonCell];
        [self configureSyncNowCell:cell];
        return cell;
    }

    if (indexPath.section == ICiCloudSyncSettingsSectionOptions) {
        UITableViewCell *cell = [self switchCell];
        UISwitch *control = (UISwitch*)cell.accessoryView;
        control.tag = indexPath.row;
        [control addTarget:self action:@selector(toggleSyncOption:) forControlEvents:UIControlEventValueChanged];

        switch (indexPath.row) {
            case ICiCloudSyncOptionRowEpisodes:
                cell.textLabel.text = @"Sync Episodes".ls;
                control.on = [ICiCloudSyncManager sharedManager].episodesSyncEnabled;
                break;
            case ICiCloudSyncOptionRowSubscriptions:
                cell.textLabel.text = @"Sync Subscriptions".ls;
                control.on = [ICiCloudSyncManager sharedManager].subscriptionsSyncEnabled;
                break;
            case ICiCloudSyncOptionRowSettings:
                cell.textLabel.text = @"Sync Settings".ls;
                control.on = [ICiCloudSyncManager sharedManager].settingsSyncEnabled;
                break;
        }
        return cell;
    }

    NSArray<ICiCloudSyncDeviceInfo*> *devices = [ICiCloudSyncManager sharedManager].devices;
    if (devices.count == 0) {
        UITableViewCell *cell = [self detailCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.text = @"No synced devices yet".ls;
        cell.detailTextLabel.text = nil;
        return cell;
    }

    ICiCloudSyncDeviceInfo *device = devices[indexPath.row];
    UITableViewCell *cell = [self detailCell];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.text = device.isCurrentDevice ? [NSString stringWithFormat:@"%@ (%@)", device.name, @"This Device".ls] : device.name;
    cell.detailTextLabel.text = [self detailTextForDevice:device];
    cell.detailTextLabel.numberOfLines = 2;
    return cell;
}

- (NSString*)detailTextForDevice:(ICiCloudSyncDeviceInfo*)device
{
    NSMutableArray<NSString*> *parts = [NSMutableArray array];
    if (device.episodesEnabled) [parts addObject:@"Episodes".ls];
    if (device.subscriptionsEnabled) [parts addObject:@"Subscriptions".ls];
    if (device.settingsEnabled) [parts addObject:@"Settings".ls];
    NSString *categories = (parts.count > 0) ? [parts componentsJoinedByString:@", "] : @"Off".ls;

    NSString *dateString = device.lastSyncDate ? [self.dateFormatter stringFromDate:device.lastSyncDate] : @"Never".ls;
    return [NSString stringWithFormat:@"%@ · %@: %@", categories, @"Last Sync".ls, dateString];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case ICiCloudSyncSettingsSectionStatus:
            return @"iCloud Sync".ls;
        case ICiCloudSyncSettingsSectionOptions:
            return @"Sync Options".ls;
        case ICiCloudSyncSettingsSectionDevices:
            return @"Devices".ls;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == ICiCloudSyncSettingsSectionStatus) {
        return @"iCloud Sync keeps selected data in sync through your private iCloud account.".ls;
    }
    if (section == ICiCloudSyncSettingsSectionOptions) {
        return @"Sync Episodes keeps played state, playback position, favorites, and list scroll positions in sync. Sync Subscriptions keeps subscribed podcasts, podcast settings, deletions, and sort order in sync. Sync Settings keeps app settings in sync. These iCloud Sync switches stay local to this device.".ls;
    }
    if (section == ICiCloudSyncSettingsSectionDevices) {
        return @"Only devices that have successfully synced with at least one enabled category appear here.".ls;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    return [self heightForFooterText:[self tableView:tableView titleForFooterInSection:section]];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.textColor = [UIColor grayColor];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *footerView = (UITableViewHeaderFooterView *)view;
        footerView.textLabel.textColor = [UIColor grayColor];
        footerView.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
    }
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == ICiCloudSyncSettingsSectionStatus && indexPath.row == 1) {
        if (![ICiCloudSyncManager sharedManager].anySyncEnabled) { return; }

        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        cell.userInteractionEnabled = NO;
        cell.textLabel.text = @"Syncing…".ls;

        [[ICiCloudSyncManager sharedManager] performManualSyncWithCompletion:^(NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                cell.userInteractionEnabled = YES;
                if (error) {
                    [self presentAlertControllerWithTitle:@"iCloud Sync".ls
                                                  message:error.localizedDescription
                                                   button:@"OK".ls
                                                 animated:YES
                                               completion:nil];
                }
                [self.tableView reloadData];
            });
        }];
    }
}

- (void)toggleSyncOption:(UISwitch*)sender
{
    switch (sender.tag) {
        case ICiCloudSyncOptionRowEpisodes:
            [[ICiCloudSyncManager sharedManager] setEpisodesSyncEnabled:sender.on];
            break;
        case ICiCloudSyncOptionRowSubscriptions:
            [[ICiCloudSyncManager sharedManager] setSubscriptionsSyncEnabled:sender.on];
            break;
        case ICiCloudSyncOptionRowSettings:
            [[ICiCloudSyncManager sharedManager] setSettingsSyncEnabled:sender.on];
            break;
    }
    [self.tableView reloadData];
}

- (void)configureSyncNowCell:(UITableViewCell*)cell
{
    BOOL syncEnabled = [ICiCloudSyncManager sharedManager].anySyncEnabled;
    cell.textLabel.text = @"Sync Now".ls;
    cell.userInteractionEnabled = syncEnabled;
    cell.textLabel.enabled = syncEnabled;
    cell.textLabel.textColor = syncEnabled ? [[ICAppearanceManager sharedManager] appearance].tintColor : ICMutedTextColor;
    cell.selectionStyle = syncEnabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
}

@end
