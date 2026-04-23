//
//  DataSettingsViewController.m
//  Instacast
//

#import "DataSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "MediaFilesViewController.h"
#import "ValuesTableViewController.h"
#import "InstacastAppDelegate.h"
#import "DonationViewController.h"

typedef NS_ENUM(NSInteger, DataSettingsSections) {
    kLimitSettingSection = 0,
    kAutoDownloadSettingsSection,
    kAutoDownloadWhileStreamingSection,
    kAutoDeleteSettingsSection,
    k3GSection,
    kDownloadedFilesButton,
    kStatisticsSection,
    kNumberOfSections,
};

typedef NS_ENUM(NSInteger, CellularDataUsage) {
    kDontUseCellularData = 0,
    kDontDownloadOverCellular,
    kUseCellularData,
};

@implementation DataSettingsViewController

+ (DataSettingsViewController*) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Data".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

    [[CacheManager sharedCacheManager] addObserver:self forKeyPath:@"numberOfDownloadedBytes" options:0 context:NULL];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self updateAppearance];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView reloadData];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

- (void) dealloc
{
    [[CacheManager sharedCacheManager] removeObserver:self forKeyPath:@"numberOfDownloadedBytes"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"numberOfDownloadedBytes"]) {
        [self.tableView reloadData];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case k3GSection:
            return 3;
        case kLimitSettingSection:
            return 1;
        case kAutoDownloadSettingsSection:
            return 2;
        case kAutoDownloadWhileStreamingSection:
            return 1;
        case kAutoDeleteSettingsSection:
            return 2;
        case kDownloadedFilesButton:
            return 1;
        case kStatisticsSection:
            return 9;
        default:
            break;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == k3GSection)
    {
        UITableViewCell* cell = [self standardCell];
        cell.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
        CellularDataUsage usage = kDontUseCellularData;
        if ([USER_DEFAULTS boolForKey:EnableStreamingOver3G] && ![USER_DEFAULTS boolForKey:EnableCachingOver3G]) {
            usage = kDontDownloadOverCellular;
        }
        else if ([USER_DEFAULTS boolForKey:EnableStreamingOver3G] && [USER_DEFAULTS boolForKey:EnableCachingOver3G]) {
            usage = kUseCellularData;
        }

        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"Don't use Cellular Data".ls;
                cell.textLabel.textColor = (usage == kDontUseCellularData) ? [[ICAppearanceManager sharedManager] appearance].tintColor : ICTextColor;
                cell.accessoryType = (usage == kDontUseCellularData) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
                break;
            case 1:
                cell.textLabel.text = @"Don't download media".ls;
                cell.textLabel.textColor = (usage == kDontDownloadOverCellular) ? [[ICAppearanceManager sharedManager] appearance].tintColor : ICTextColor;
                cell.accessoryType = (usage == kDontDownloadOverCellular) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
                break;
            case 2:
                cell.textLabel.text = @"Always use Cellular Data".ls;
                cell.textLabel.textColor = (usage == kUseCellularData) ? [[ICAppearanceManager sharedManager] appearance].tintColor : ICTextColor;
                cell.accessoryType = (usage == kUseCellularData) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
                break;
            default:
                break;
        }

        cell.detailTextLabel.text = nil;
        return cell;
    }
    else if (indexPath.section == kLimitSettingSection)
    {
        UITableViewCell *cell = [self detailCell];
        long long limit = [USER_DEFAULTS integerForKey:AutoCacheStorageLimit];

        cell.textLabel.text = @"Storage Limit".ls;

        if (limit == 0) {
            cell.detailTextLabel.text = @"No Limit".ls;
        }
        else {
            cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:limit*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory];
        }
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        return cell;
    }
    else if (indexPath.section == kAutoDownloadSettingsSection)
    {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;

        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"Audio Content".ls;
                control.on = [USER_DEFAULTS boolForKey:AutoCacheNewAudioEpisodes];
                break;
            case 1:
                cell.textLabel.text = @"Video Content".ls;
                control.on = [USER_DEFAULTS boolForKey:AutoCacheNewVideoEpisodes];
                break;
            default:
                break;
        }

        control.tag = indexPath.row;
        [control addTarget:self action:@selector(toggleDownloadSettings:) forControlEvents:UIControlEventValueChanged];

        return cell;
    }
    else if (indexPath.section == kAutoDownloadWhileStreamingSection)
    {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        cell.textLabel.text = @"Auto-Download While Streaming".ls;
        control.on = [USER_DEFAULTS boolForKey:AutoDownloadWhileStreaming];
        [control addTarget:self action:@selector(toggleAutoDownloadWhileStreaming:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    else if (indexPath.section == kAutoDeleteSettingsSection)
    {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;

        if (indexPath.row == 0) {
            cell.textLabel.text = @"Finished Playing".ls;
            control.on = [USER_DEFAULTS boolForKey:AutoDeleteAfterFinishedPlaying];
        }
        else if (indexPath.row == 1) {
            cell.textLabel.text = @"Marked as Played".ls;
            control.on = [USER_DEFAULTS boolForKey:AutoDeleteAfterMarkedAsPlayed];
        }

        control.tag = indexPath.row;
        [control addTarget:self action:@selector(toggleAutoDeleteSettings:) forControlEvents:UIControlEventValueChanged];

        return cell;
    }
    else if (indexPath.section == kDownloadedFilesButton)
    {
        UITableViewCell* cell = [self detailCell];
        cell.textLabel.text = @"Downloaded Files".ls;
        cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:[[CacheManager sharedCacheManager] numberOfDownloadedBytes] countStyle:NSByteCountFormatterCountStyleMemory];
        return cell;
    }
    else if (indexPath.section == kStatisticsSection)
    {
        UITableViewCell* cell = [self detailCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;

        NSNumberFormatter* numberFormatter = [[NSNumberFormatter alloc] init];
        numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
        numberFormatter.locale = [NSLocale currentLocale];

        switch (indexPath.row) {
            case 0: {
                cell.textLabel.text = @"Subscriptions".ls;
                NSFetchRequest* request = [[NSFetchRequest alloc] init];
                request.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:DMANAGER.objectContext];
                request.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
                NSUInteger count = [DMANAGER.objectContext countForFetchRequest:request error:nil];
                cell.detailTextLabel.text = [numberFormatter stringFromNumber:@(count)];
                break;
            }
            case 1: {
                cell.textLabel.text = @"Total Episodes".ls;
                NSFetchRequest* request = [[NSFetchRequest alloc] init];
                request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
                request.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES && archived == NO"];
                NSUInteger count = [DMANAGER.objectContext countForFetchRequest:request error:nil];
                cell.detailTextLabel.text = [numberFormatter stringFromNumber:@(count)];
                break;
            }
            case 2: {
                cell.textLabel.text = @"Total Unplayed".ls;
                NSFetchRequest* request = [[NSFetchRequest alloc] init];
                request.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
                request.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES && archived == NO && consumed == NO"];
                NSUInteger count = [DMANAGER.objectContext countForFetchRequest:request error:nil];
                cell.detailTextLabel.text = [numberFormatter stringFromNumber:@(count)];
                break;
            }
            case 3: {
                cell.textLabel.text = @"Episodes Played".ls;
                NSInteger count = [USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"];
                cell.detailTextLabel.text = [numberFormatter stringFromNumber:@(count)];
                break;
            }
            case 4: {
                cell.textLabel.text = @"Time Listened".ls;
                double totalSeconds = [USER_DEFAULTS doubleForKey:@"TotalListeningTime"];
                NSInteger hours = (NSInteger)(totalSeconds / 3600);
                NSInteger minutes = ((NSInteger)totalSeconds % 3600) / 60;
                if (hours > 0) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ldh %ldm", (long)hours, (long)minutes];
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ldm", (long)minutes];
                }
                break;
            }
            case 5: {
                cell.textLabel.text = @"Total Downloaded".ls;
                NSUInteger count = [[CacheManager sharedCacheManager].cachedEpisodes count];
                cell.detailTextLabel.text = [numberFormatter stringFromNumber:@(count)];
                break;
            }
            case 6: {
                cell.textLabel.text = @"Storage Used".ls;
                unsigned long long bytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytes];
                cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];
                break;
            }
            case 7: {
                cell.textLabel.text = @"Fell Asleep with Timer".ls;
                NSInteger count = [USER_DEFAULTS integerForKey:@"SleepTimerFellAsleepCount"];
                cell.detailTextLabel.text = [numberFormatter stringFromNumber:@(count)];
                break;
            }
            case 8: {
                cell.textLabel.text = @"Donated to InstacastPlus".ls;
                NSArray *history = [USER_DEFAULTS arrayForKey:@"DonationHistory"];
                double totalDonated = 0;
                NSString *currency = @"USD";
                for (NSDictionary *entry in history) {
                    totalDonated += [entry[@"amount"] doubleValue];
                    if (entry[@"currency"]) currency = entry[@"currency"];
                }
                if (totalDonated > 0) {
                    NSNumberFormatter *currencyFormatter = [[NSNumberFormatter alloc] init];
                    currencyFormatter.numberStyle = NSNumberFormatterCurrencyStyle;
                    currencyFormatter.currencyCode = currency;
                    cell.detailTextLabel.text = [currencyFormatter stringFromNumber:@(totalDonated)];
                } else {
                    cell.detailTextLabel.text = @"—";
                }
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            default:
                break;
        }
        return cell;
    }

    return nil;
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case k3GSection:
            return @"Cellular Data".ls;
        case kLimitSettingSection:
            return @"";
        case kAutoDownloadSettingsSection:
            return @"Auto-Download Content".ls;
        case kAutoDownloadWhileStreamingSection:
            return @"";
        case kAutoDeleteSettingsSection:
            return @"Auto-Delete Content".ls;
        case kDownloadedFilesButton:
            return @"";
        case kStatisticsSection:
            return @"Statistics".ls;
        default:
            break;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
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

- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section)
    {
        case k3GSection:
        {
            return @"You can either disable the usage of cellular data completely (which might decrease the user experience when not on WiFi), enable cellular usage for everything except downloading episodes, or enable cellular usage for everything including downloading episodes. Disabling cellular data completely will also prevent iOS's cellular data alert from popping up.".ls;
        }
        case kAutoDownloadWhileStreamingSection:
        {
            return @"Automatically downloads the full episode while streaming.".ls;
        }
        default:
            break;
    }
    return nil;
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == k3GSection)
    {
        switch (indexPath.row) {
            case 0:
            {
                [USER_DEFAULTS setBool:NO forKey:EnableStreamingOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableCachingImagesOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableRefreshingOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableCachingOver3G];
                break;
            }
            case 1:
                [USER_DEFAULTS setBool:YES forKey:EnableStreamingOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableCachingImagesOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableRefreshingOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableCachingOver3G];
                break;
            case 2:
                [USER_DEFAULTS setBool:YES forKey:EnableStreamingOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableCachingImagesOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableRefreshingOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableCachingOver3G];
                break;
            default:
                break;
        }

        // update table
        for(NSIndexPath* ip in [tableView indexPathsForVisibleRows]) {
            if (ip.section == indexPath.section) {
                [tableView cellForRowAtIndexPath:ip].accessoryType = UITableViewCellAccessoryNone;
                [tableView cellForRowAtIndexPath:ip].textLabel.textColor = ICTextColor;
            }
        }
        [tableView cellForRowAtIndexPath:indexPath].accessoryType = UITableViewCellAccessoryCheckmark;
        [tableView cellForRowAtIndexPath:indexPath].textLabel.textColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
    }
    else if (indexPath.section == kLimitSettingSection)
    {
        ValuesTableViewController* controller = [ValuesTableViewController tableViewController];
        controller.key = AutoCacheStorageLimit;
        controller.valueType = kValueTypeInteger;
        controller.title = @"Storage Limit".ls;
        controller.values = [NSArray arrayWithObjects:@(512),@(1024),@(2048),@(5120),@(10240),@(20480),@(51200),@(0), nil];
        controller.titles = [NSArray arrayWithObjects:
                             [NSByteCountFormatter stringFromByteCount:512*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory],
                             [NSByteCountFormatter stringFromByteCount:1024*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory],
                             [NSByteCountFormatter stringFromByteCount:2048*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory].ls,
                             [NSByteCountFormatter stringFromByteCount:5120*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory].ls,
                             [NSByteCountFormatter stringFromByteCount:10240*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory].ls,
                             [NSByteCountFormatter stringFromByteCount:20480*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory].ls,
                             [NSByteCountFormatter stringFromByteCount:51200*1024LL*1024LL countStyle:NSByteCountFormatterCountStyleMemory].ls,
                             @"No Limit".ls, nil];
        controller.footerText = @"Played episodes and old content will be automatically deleted when the storage limit is exceeded.".ls;

        [self.navigationController pushViewController:controller animated:YES];
    }
    else if (indexPath.section == kDownloadedFilesButton)
    {
        MediaFilesViewController* controller = [MediaFilesViewController viewController];
        [self.navigationController pushViewController:controller animated:YES];
    }
    else if (indexPath.section == kStatisticsSection && indexPath.row == 8)
    {
        DonationViewController* controller = [DonationViewController viewController];
        [self.navigationController pushViewController:controller animated:YES];
    }
}

#pragma mark - Toggle actions

- (void) toggleDownloadSettings:(UISwitch*)sender
{
    switch (sender.tag) {
        case 0:
            [USER_DEFAULTS setBool:sender.on forKey:AutoCacheNewAudioEpisodes];
            break;
        case 1:
            [USER_DEFAULTS setBool:sender.on forKey:AutoCacheNewVideoEpisodes];
            break;
        default:
            break;
    }

}

- (void) toggleAutoDownloadWhileStreaming:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:AutoDownloadWhileStreaming];
}

- (void) toggleAutoDeleteSettings:(UISwitch*)sender
{
    if (sender.tag == 0) {
        [USER_DEFAULTS setBool:sender.on forKey:AutoDeleteAfterFinishedPlaying];
    }
    else if (sender.tag == 1) {
        [USER_DEFAULTS setBool:sender.on forKey:AutoDeleteAfterMarkedAsPlayed];
    }
}

@end
