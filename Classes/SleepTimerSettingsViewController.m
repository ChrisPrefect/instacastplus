//
//  SleepTimerSettingsViewController.m
//  Instacast
//

#import "SleepTimerSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "PlaybackDefines.h"
#import "InstacastAppDelegate.h"

typedef NS_ENUM(NSInteger, SleepTimerSettingsSections) {
    kAutomaticTimer = 0,
    kIntelligentSleep,
    kNumberOfSections,
};

@implementation SleepTimerSettingsViewController

+ (SleepTimerSettingsViewController*) viewController
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
    self.navigationItem.title = @"Sleep Timer".ls;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self updateAppearance];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
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
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kAutomaticTimer:
            return 1;
        case kIntelligentSleep:
            return 3;
        default:
            break;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kAutomaticTimer)
    {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        control.tag = indexPath.row;

        cell.textLabel.text = @"Sleep Timer Always Active".ls;
        control.on = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
        [control addTarget:self action:@selector(toggleSleepTimeAlwaysSettings:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    else if (indexPath.section == kIntelligentSleep)
    {
        switch (indexPath.row) {
            case 0:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;

                cell.textLabel.text = @"Screen Touch".ls;
                control.on = [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep];
                [control addTarget:self action:@selector(toggleIntelligentSleepSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            case 1:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;

                cell.textLabel.text = @"Volume Change".ls;
                control.on = [USER_DEFAULTS boolForKey:VolumeChangeIntelligentSleep];
                [control addTarget:self action:@selector(toggleIntelligentSleepSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            case 2:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;

                cell.textLabel.text = @"Device Movement".ls;
                control.on = [USER_DEFAULTS boolForKey:DeviceMovementIntelligentSleep];
                [control addTarget:self action:@selector(toggleIntelligentSleepSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            default:
                break;
        }
    }

    return nil;
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kAutomaticTimer:
            return @"";
        case kIntelligentSleep:
            return @"Smart Sleep Timer".ls;
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
}

- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section)
    {
        case kAutomaticTimer:
        {
            if ([USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
            {
                return @"If a podcast is playing, the sleep timer will be enabled automatically. Prevents podcasts from unintentionally playing trough the night.".ls;
            }
            else
            {
                return nil;
            }
        }
        case kIntelligentSleep:
        {
            return @"The Smart Sleep Timer automatically resets its countdown when it detects you are still awake, so your podcast keeps playing until you fall asleep.".ls;
        }
        default:
            break;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Toggle actions

- (void) toggleSleepTimeAlwaysSettings:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:ScreenTimerAlwaysActive];
    if (sender.on)
    {
        NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
        if (sleepTimer <= 0)
        {
            if ([USER_DEFAULTS objectForKey:LastSelectedSleepTimer] == nil)
            {
                if ([USER_DEFAULTS objectForKey:DefaultIntelligentSleepTimer] == PlaybackStopTimeNoValue)
                {
                    [USER_DEFAULTS setInteger:PlaybackStopTime5min forKey:LastSelectedSleepTimer];
                }
                else
                {
                    [USER_DEFAULTS setInteger:DefaultIntelligentSleepTimer forKey:LastSelectedSleepTimer];
                }
                [USER_DEFAULTS synchronize];
            }
        }
    }
    [self.tableView reloadData];
}

- (void) toggleIntelligentSleepSettings:(UISwitch*)sender
{
    if (sender.tag == 0) {
        [USER_DEFAULTS setBool:sender.on forKey:ScreenTouchIntelligentSleep];
    }
    else if (sender.tag == 1) {
        [USER_DEFAULTS setBool:sender.on forKey:VolumeChangeIntelligentSleep];
    }
    else if (sender.tag == 2) {
        [USER_DEFAULTS setBool:sender.on forKey:DeviceMovementIntelligentSleep];
    }
}

@end
