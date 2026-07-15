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
    ICiCloudSyncSettingsSectionStorage,
    ICiCloudSyncSettingsSectionDevices,
    ICiCloudSyncSettingsSectionDelete,
    ICiCloudSyncSettingsSectionCount,
};

typedef NS_ENUM(NSInteger, ICiCloudSyncOptionRow) {
    ICiCloudSyncOptionRowEpisodes = 0,
    ICiCloudSyncOptionRowSubscriptions,
    ICiCloudSyncOptionRowSettings,
    ICiCloudSyncOptionRowCount,
};

typedef NS_ENUM(NSInteger, ICiCloudSyncStorageRow) {
    ICiCloudSyncStorageRowEpisodes = 0,
    ICiCloudSyncStorageRowSubscriptions,
    ICiCloudSyncStorageRowSettings,
    ICiCloudSyncStorageRowCount,
};

static CGFloat const ICiCloudSyncSettingsDeviceRowHeight = 70.0f;

@interface ICiCloudSyncSettingsViewController ()
@property (nonatomic, strong) NSRelativeDateTimeFormatter *relativeDateFormatter;
@property (nonatomic, strong) NSArray<ICiCloudSyncDeviceInfo*> *cachedDevices;
@property (nonatomic, strong) NSTimer *relativeTimeRefreshTimer;
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

    self.relativeDateFormatter = [[NSRelativeDateTimeFormatter alloc] init];
    self.relativeDateFormatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
    self.relativeDateFormatter.dateTimeStyle = NSRelativeDateTimeFormatterStyleNamed;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(syncStateDidChange:) name:ICiCloudSyncStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(syncDevicesDidChange:) name:ICiCloudSyncDevicesDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

    [[ICiCloudSyncManager sharedManager] start];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];

    // Refresh the hard cloud inventory once on appearance. The 30-second timer below is
    // only for relative timestamps/UI; re-listing the whole zone there downloaded every
    // record repeatedly while this screen was open.
    [[ICiCloudSyncManager sharedManager] refreshCloudInventory];
    [self.relativeTimeRefreshTimer invalidate];
    self.relativeTimeRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                                     target:self
                                                                   selector:@selector(refreshCloudStateTick)
                                                                   userInfo:nil
                                                                    repeats:YES];

    // A parked settings payload means the user enabled settings sync while iCloud
    // already had settings and hasn't decided yet — ask (again) now.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(presentInitialSettingsChoiceIfNeeded)
                                                 name:ICiCloudSyncManager.initialSettingsChoiceNeededNotification
                                               object:nil];
    [self presentInitialSettingsChoiceIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.relativeTimeRefreshTimer invalidate];
    self.relativeTimeRefreshTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:ICiCloudSyncManager.initialSettingsChoiceNeededNotification
                                                  object:nil];
}

// Settings sync was enabled while iCloud already held another device's settings: the
// user decides which side wins — nothing is applied or published until then ("Später"
// keeps the choice pending; it is asked again the next time this screen opens).
- (void)presentInitialSettingsChoiceIfNeeded
{
    if (![ICiCloudSyncManager sharedManager].hasPendingInitialSettingsChoice) {
        return;
    }
    if (self.presentedViewController) {
        return;
    }

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"iCloud Settings Found".ls
                                                                   message:@"Another device already uploaded its settings to iCloud. Which settings should be used?".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    WEAK_SELF
    [alert addAction:[UIAlertAction actionWithTitle:@"Use iCloud Settings".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
        STRONG_SELF
        [[ICiCloudSyncManager sharedManager] resolveInitialSettingsAdoptingCloud];
        [self reloadStatusAndDevicesSections];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Use My Settings for All Devices".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
        STRONG_SELF
        [[ICiCloudSyncManager sharedManager] resolveInitialSettingsPublishingLocal];
        [self reloadStatusAndDevicesSections];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Decide Later".ls
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc
{
    [self.relativeTimeRefreshTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    self.cachedDevices = [ICiCloudSyncManager sharedManager].devices;
    [self.tableView reloadData];
}

// The manager's `devices` getter reads and parses the device-cache file from disk on
// every call — cache it per reload instead of hitting the disk from every table callback
// (row count, cell, row height, 10s timer).
- (NSArray<ICiCloudSyncDeviceInfo*>*)deviceList
{
    if (!self.cachedDevices) {
        self.cachedDevices = [ICiCloudSyncManager sharedManager].devices;
    }
    return self.cachedDevices;
}

- (void)syncStateDidChange:(NSNotification*)notification
{
    [self reloadStatusAndStorageSections];
}

- (void)syncDevicesDidChange:(NSNotification*)notification
{
    if (!self.isViewLoaded) {
        return;
    }
    self.cachedDevices = [ICiCloudSyncManager sharedManager].devices;
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ICiCloudSyncSettingsSectionDevices]
                      withRowAnimation:UITableViewRowAnimationNone];
    }];
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
        case ICiCloudSyncSettingsSectionStorage:
            return ICiCloudSyncStorageRowCount;
        case ICiCloudSyncSettingsSectionDevices:
            return MAX(1, [self deviceList].count);
        case ICiCloudSyncSettingsSectionDelete:
            return 1;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == ICiCloudSyncSettingsSectionStatus) {
        if (indexPath.row == 0) {
            NSString *statusText = [ICiCloudSyncManager sharedManager].statusText;
            return [self statusCellWithStatusText:statusText];
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

    if (indexPath.section == ICiCloudSyncSettingsSectionStorage) {
        // Hard record counts straight from iCloud (refreshed on appear + every 30s) —
        // never derived from local data or sync progress.
        ICiCloudSyncCloudInventory *inventory = [ICiCloudSyncManager sharedManager].cloudInventory;
        UITableViewCell *cell = [self detailCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.detailTextLabel.numberOfLines = 1;
        switch (indexPath.row) {
            case ICiCloudSyncStorageRowEpisodes:
                cell.textLabel.text = @"Episode States".ls;
                cell.detailTextLabel.text = inventory ? [NSNumberFormatter localizedStringFromNumber:@(inventory.episodeStates) numberStyle:NSNumberFormatterDecimalStyle] : @"…";
                break;
            case ICiCloudSyncStorageRowSubscriptions:
                cell.textLabel.text = @"Subscriptions".ls;
                cell.detailTextLabel.text = inventory ? [NSNumberFormatter localizedStringFromNumber:@(inventory.subscriptions) numberStyle:NSNumberFormatterDecimalStyle] : @"…";
                break;
            case ICiCloudSyncStorageRowSettings:
                cell.textLabel.text = @"Settings".ls;
                cell.detailTextLabel.text = inventory ? [NSNumberFormatter localizedStringFromNumber:@(inventory.settings) numberStyle:NSNumberFormatterDecimalStyle] : @"…";
                break;
        }
        return cell;
    }

    if (indexPath.section == ICiCloudSyncSettingsSectionDelete) {
        UITableViewCell *cell = [self buttonCell];
        cell.accessoryView = nil;
        cell.textLabel.text = @"Delete iCloud Data".ls;
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.enabled = YES;
        cell.userInteractionEnabled = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    NSArray<ICiCloudSyncDeviceInfo*> *devices = [self deviceList];
    if (devices.count == 0) {
        UITableViewCell *cell = [self detailCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.textLabel.text = @"No synced devices yet".ls;
        cell.detailTextLabel.text = nil;
        return cell;
    }

    ICiCloudSyncDeviceInfo *device = devices[indexPath.row];
    UITableViewCell *cell = [self multilineInfoCellWithIdentifier:@"ICiCloudSyncDeviceCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.text = [self displayNameForDevice:device];
    cell.detailTextLabel.text = [self detailTextForDevice:device];
    return cell;
}

- (NSString*)detailTextForDevice:(ICiCloudSyncDeviceInfo*)device
{
    NSMutableArray<NSString*> *parts = [NSMutableArray array];
    if (device.episodesEnabled) [parts addObject:@"Episodes".ls];
    if (device.subscriptionsEnabled) [parts addObject:@"Subscriptions".ls];
    if (device.settingsEnabled) [parts addObject:@"Settings".ls];
    NSString *categories = (parts.count > 0) ? [parts componentsJoinedByString:@", "] : @"Off".ls;

    NSString *dateString = device.lastSyncDate ? [self.relativeDateFormatter localizedStringForDate:device.lastSyncDate relativeToDate:[NSDate date]] : @"Never".ls;
    return [NSString stringWithFormat:@"%@\n%@: %@", categories, @"Last Sync".ls, dateString];
}

// Stale entries from old installations (every install registers under a fresh device
// ID) can be swiped away; the record deletion also cleans the lists on the other
// devices. The live current device cannot be removed — it would just re-announce
// itself on its next sync.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section != ICiCloudSyncSettingsSectionDevices) {
        return nil;
    }
    NSArray<ICiCloudSyncDeviceInfo*> *devices = [self deviceList];
    if (indexPath.row >= devices.count) {
        return nil;
    }
    ICiCloudSyncDeviceInfo *device = devices[indexPath.row];
    if (device.isCurrentDevice) {
        return nil;
    }

    WEAK_SELF
    UIContextualAction *deleteAction =
        [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                title:@"Remove".ls
                                              handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
        STRONG_SELF
        if (!self) {
            completionHandler(NO);
            return;
        }
        [[ICiCloudSyncManager sharedManager] deleteDeviceWithID:device.deviceID];
        self.cachedDevices = [ICiCloudSyncManager sharedManager].devices;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:ICiCloudSyncSettingsSectionDevices]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
        completionHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case ICiCloudSyncSettingsSectionStatus:
            return nil;
        case ICiCloudSyncSettingsSectionOptions:
            return @"Sync Options".ls;
        case ICiCloudSyncSettingsSectionStorage:
            return @"iCloud Data".ls;
        case ICiCloudSyncSettingsSectionDevices:
            return @"Synced Devices".ls;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == ICiCloudSyncSettingsSectionOptions) {
        return @"Sync Episodes keeps played state, playback position, favorites, and list scroll positions in sync. Sync Subscriptions keeps subscribed podcasts, podcast settings, deletions, and sort order in sync.".ls;
    }
    if (section == ICiCloudSyncSettingsSectionStatus) {
        return @"Beim ersten Sync überträgt iCloud jeden Episodenstatus als eigenen Datensatz. Der Fortschritt wird oben angezeigt; danach werden nur Änderungen übertragen.".ls;
    }
    if (section == ICiCloudSyncSettingsSectionStorage) {
        return [self cloudInventoryFooterText];
    }
    if (section == ICiCloudSyncSettingsSectionDelete) {
        return @"Removes all synced data from iCloud for all of your devices. Local data on this device is kept; if sync stays on, it is uploaded again.".ls;
    }
    return nil;
}

- (NSString*)cloudInventoryFooterText
{
    ICiCloudSyncManager *manager = [ICiCloudSyncManager sharedManager];
    if (manager.cloudInventoryRefreshInProgress) {
        return @"Updating iCloud data…".ls;
    }

    ICiCloudSyncCloudInventory *inventory = manager.cloudInventory;
    NSString *lastCheckedText = nil;
    if (inventory) {
        NSString *relativeDate = [self.relativeDateFormatter localizedStringForDate:inventory.fetchDate relativeToDate:[NSDate date]];
        lastCheckedText = [NSString stringWithFormat:@"Last checked %@.".ls, relativeDate];
    }
    if (manager.cloudInventoryRefreshErrorText.length > 0) {
        return lastCheckedText.length > 0
            ? [NSString stringWithFormat:@"%@ %@", manager.cloudInventoryRefreshErrorText, lastCheckedText]
            : manager.cloudInventoryRefreshErrorText;
    }
    return lastCheckedText ?: @"iCloud data has not been checked yet.".ls;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString *footer = [self tableView:tableView titleForFooterInSection:section];
    return footer.length > 0 ? [self heightForFooterText:footer] : 0.0f;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == ICiCloudSyncSettingsSectionDevices && [self deviceList].count > 0) {
        return ICiCloudSyncSettingsDeviceRowHeight;
    }
    return UITableViewAutomaticDimension;
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

    if (indexPath.section == ICiCloudSyncSettingsSectionDelete) {
        [self confirmAndDeleteICloudData];
        return;
    }

    if (indexPath.section == ICiCloudSyncSettingsSectionStatus && indexPath.row == 1) {
        if (![ICiCloudSyncManager sharedManager].anySyncEnabled) { return; }
        if ([ICiCloudSyncManager sharedManager].syncInProgress) { return; }

        [[ICiCloudSyncManager sharedManager] requestCloudInventoryRefreshAfterSync];
        [[ICiCloudSyncManager sharedManager] performManualSyncWithCompletion:^(NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    [self presentAlertControllerWithTitle:@"iCloud Sync".ls
                                                  message:[ICiCloudSyncManager sharedManager].statusText
                                                   button:@"OK".ls
                                                 animated:YES
                                               completion:nil];
                }
                [self reloadStatusAndDevicesSections];
            });
        }];
    }
}

- (void)confirmAndDeleteICloudData
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete iCloud Data".ls
                                                                  message:@"This removes all synced data from iCloud for all of your devices. This cannot be undone.".ls
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete".ls style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[ICiCloudSyncManager sharedManager] deleteAllICloudDataWithCompletion:^(NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    [self presentAlertControllerWithTitle:@"iCloud Sync".ls
                                                  message:[ICiCloudSyncManager sharedManager].statusText
                                                   button:@"OK".ls
                                                 animated:YES
                                               completion:nil];
                }
                [self.tableView reloadData];
            });
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)toggleSyncOption:(UISwitch*)sender
{
    [[ICDiagnosticLogger shared] logEvent:@"icloud-sync-ui"
                                  message:@"Sync-Schalter ValueChanged empfangen"
                                 metadata:@{
        @"row": @(sender.tag),
        @"requestedOn": @(sender.on),
        @"tracking": @(sender.tracking),
        @"highlighted": @(sender.highlighted),
    }];
    [ICiCloudSyncManager logSyncMetadataStorageSnapshot:@"icloud-switch-value-changed"];

    // The exact cloud counts require a full-zone scan. Stop/defer that optional work
    // before the switch starts the user-requested send/fetch cycle.
    [[ICiCloudSyncManager sharedManager] requestCloudInventoryRefreshAfterOptionChange];
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

    [[ICDiagnosticLogger shared] logEvent:@"icloud-sync-ui"
                                  message:@"Sync-Schalter Manager-Aufruf beendet"
                                 metadata:@{
        @"row": @(sender.tag),
        @"requestedOn": @(sender.on),
    }];
    [self reloadStatusAndDevicesSections];
    [[ICDiagnosticLogger shared] logEvent:@"icloud-sync-ui"
                                  message:@"Sync-Schalter Status/Devices neu geladen"
                                 metadata:@{
        @"row": @(sender.tag),
        @"requestedOn": @(sender.on),
    }];
}

- (void)configureSyncNowCell:(UITableViewCell*)cell
{
    BOOL syncEnabled = [ICiCloudSyncManager sharedManager].anySyncEnabled;
    BOOL syncInProgress = [ICiCloudSyncManager sharedManager].syncInProgress;
    BOOL canStartSync = syncEnabled && !syncInProgress;
    cell.textLabel.text = syncInProgress ? @"Syncing…".ls : @"Sync Now".ls;
    cell.userInteractionEnabled = canStartSync;
    cell.textLabel.enabled = syncEnabled;
    cell.textLabel.textColor = syncEnabled ? [[ICAppearanceManager sharedManager] appearance].tintColor : ICMutedTextColor;
    cell.selectionStyle = canStartSync ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    if (syncInProgress) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        spinner.color = [[ICAppearanceManager sharedManager] appearance].tintColor;
        [spinner startAnimating];
        cell.accessoryView = spinner;
    }
}

- (NSString*)displayNameForDevice:(ICiCloudSyncDeviceInfo*)device
{
    NSString *model = device.model ?: @"";
    NSString *name = device.name ?: @"";
    NSString *displayName = (model.length > 0) ? model : name;
    if (device.isCurrentDevice) {
        return (displayName.length > 0) ? [NSString stringWithFormat:@"%@ (%@)", displayName, @"This Device".ls] : @"This Device".ls;
    }
    return (displayName.length > 0) ? displayName : @"Unbekanntes Gerät".ls;
}

- (UITableViewCell*)statusCellWithStatusText:(NSString*)statusText
{
    static NSString *identifier = @"ICiCloudSyncStatusCell";
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    }

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = @"Status".ls;
    content.secondaryText = statusText;
    content.prefersSideBySideTextAndSecondaryText = NO;
    content.textProperties.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:ICFontSize(17)]];
    content.textProperties.color = ICTextColor;
    content.textProperties.adjustsFontForContentSizeCategory = YES;
    content.secondaryTextProperties.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:[UIFont systemFontOfSize:ICFontSize(14)]];
    content.secondaryTextProperties.color = ICMutedTextColor;
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping;
    content.secondaryTextProperties.adjustsFontForContentSizeCategory = YES;

    cell.contentConfiguration = content;
    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = @"Status".ls;
    cell.accessibilityValue = statusText;
    cell.accessibilityTraits = UIAccessibilityTraitStaticText;
    return cell;
}

- (UITableViewCell*)multilineInfoCellWithIdentifier:(NSString*)identifier
{
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.selectedBackgroundView = [[UIView alloc] init];
    }

    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    cell.textLabel.textColor = ICTextColor;
    cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(17)];
    cell.detailTextLabel.textColor = ICMutedTextColor;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:ICFontSize(14)];
    cell.detailTextLabel.numberOfLines = 2;
    cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;

    return cell;
}

- (void)refreshCloudStateTick
{
    [self reloadStatusAndDevicesSections];
}

- (void)reloadStatusAndDevicesSections
{
    if (!self.isViewLoaded) {
        return;
    }

    self.cachedDevices = [ICiCloudSyncManager sharedManager].devices;

    NSIndexSet *sections = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(ICiCloudSyncSettingsSectionStatus, 1)];
    NSMutableIndexSet *mutableSections = [sections mutableCopy];
    [mutableSections addIndex:ICiCloudSyncSettingsSectionStorage];
    [mutableSections addIndex:ICiCloudSyncSettingsSectionDevices];

    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:mutableSections withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)reloadStatusAndStorageSections
{
    if (!self.isViewLoaded) {
        return;
    }

    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:ICiCloudSyncSettingsSectionStatus];
    [sections addIndex:ICiCloudSyncSettingsSectionStorage];
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
    }];
}

@end
