//
//  PlaybackSettingsViewController.m
//  Instacast
//

#import "PlaybackSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "SettingsValuesTableViewController.h"
#import "PlaybackDefines.h"
#import "InstacastAppDelegate.h"

typedef NS_ENUM(NSInteger, PlaybackSettingsSections) {
    kPlaybackSection = 0,
    kNumberOfSections,
};

@implementation PlaybackSettingsViewController

+ (PlaybackSettingsViewController*) viewController
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
    self.navigationItem.title = @"Playback".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
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
        case kPlaybackSection:
            return 6;
        default:
            break;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kPlaybackSection)
    {
        NSDictionary* skippingValues = @{ @5 : @"5 Seconds".ls, @10 : @"10 Seconds".ls, @20 : @"20 Seconds".ls, @30 : @"30 Seconds".ls, @60 : @"1 Minute".ls, @120 : @"2 Minutes".ls, @300 : @"5 Minutes".ls, @600 : @"10 Minutes".ls };

        switch (indexPath.row) {
            case 0:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;

                cell.textLabel.text = @"Replay after Pause".ls;
                control.on = [USER_DEFAULTS boolForKey:PlayerReplayAfterPause];

                cell.detailTextLabel.text = nil;

                control.tag = indexPath.row;
                [control addTarget:self action:@selector(togglePlayerSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            case 1:
            {
                UITableViewCell* cell = [self detailCell];

                cell.textLabel.text = @"Skipping Back".ls;

                NSInteger period = [USER_DEFAULTS integerForKey:PlayerSkipBackPeriod];
                cell.detailTextLabel.text = skippingValues[@(period)];

                return cell;
            }
            case 2:
            {
                UITableViewCell* cell = [self detailCell];

                cell.textLabel.text = @"Skipping Forward".ls;

                NSInteger period = [USER_DEFAULTS integerForKey:PlayerSkipForwardPeriod];
                cell.detailTextLabel.text = skippingValues[@(period)];

                return cell;
            }
            case 3:
            {
                UITableViewCell* cell = [self detailCell];

                cell.textLabel.text = @"Speed".ls;

                NSInteger speed = [USER_DEFAULTS integerForKey:DefaultPlaybackSpeed];

                NSDictionary* speedValues = @{ @(PlaybackSpeedControlNormalSpeed) : @"Normal (1x)".ls,
                                               @(PlaybackSpeedControlDoubleSpeed) : @"Fast (2x)".ls,
                                               @(PlaybackSpeedControlPlusHalfSpeed) : @"Faster (1.5x)".ls,
                                               @(PlaybackSpeedControlMinusHalfSpeed) : @"Slower (0.5x)".ls,
                                               @(PlaybackSpeedControlTripleSpeed) : @"Crazy (3x)".ls,
                                               @(PlaybackSpeedControlFaster11) : @"Faster (1.1x)".ls,
                                               @(PlaybackSpeedControlFaster12) : @"Faster (1.2x)".ls,
                                               @(PlaybackSpeedControlFaster13) : @"Faster (1.3x)".ls };

                cell.detailTextLabel.text = speedValues[@(speed)];

                return cell;
            }
            case 4:
            {
                UITableViewCell* cell = [self detailCell];

                cell.textLabel.text = @"System Controls".ls;

                DefaultPlayerControls controls = [USER_DEFAULTS integerForKey:kDefaultPlayerControls];

                NSDictionary* values = @{ @(kPlayerSeekingControls) : @"Seeking".ls,
                                          @(kPlayerSeekingAndSkippingChaptersControls) : @"Seeking and Skipping Chapters".ls,
                                          @(kPlayerSkippingControls) : @"Skipping".ls };

                cell.detailTextLabel.text = [values[@(controls)] ls];

                return cell;
            }
            case 5:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;

                cell.textLabel.text = @"Disable Auto-Lock".ls;
                control.on = [USER_DEFAULTS boolForKey:DisableAutoLock];

                cell.detailTextLabel.text = nil;

                [control addTarget:self action:@selector(togglePlayerSettings:) forControlEvents:UIControlEventValueChanged];
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
        case kPlaybackSection:
            return @"Playback".ls;
        default:
            break;
    }
    return nil;
}

- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section) {
        case kPlaybackSection:
            return @"These are the default settings. They can be overridden per podcast in the podcast settings.".ls;
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

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kPlaybackSection)
    {
        switch (indexPath.row) {
            case 1:
            case 2:
            {
                SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
                controller.valueType = kSettingTypeInteger;
                controller.key = (indexPath.row == 1) ? PlayerSkipBackPeriod : PlayerSkipForwardPeriod;
                controller.title = (indexPath.row == 1) ? @"Skipping Back".ls : @"Skipping Forward".ls;
                controller.values = @[ @5, @10, @20, @30, @60, @120, @300, @600 ];
                controller.titles = @[ @"5 Seconds".ls, @"10 Seconds".ls, @"20 Seconds".ls, @"30 Seconds".ls, @"1 Minute".ls, @"2 Minutes".ls, @"5 Minutes".ls, @"10 Minutes".ls];
                [self.navigationController pushViewController:controller animated:YES];
                break;
            }
            case 3:
            {
                SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
                controller.valueType = kSettingTypeInteger;
                controller.key = DefaultPlaybackSpeed;
                controller.title = @"Speed".ls;
                controller.values = @[ @(PlaybackSpeedControlMinusHalfSpeed), @(PlaybackSpeedControlNormalSpeed), @(PlaybackSpeedControlFaster11), @(PlaybackSpeedControlFaster12), @(PlaybackSpeedControlFaster13), @(PlaybackSpeedControlPlusHalfSpeed), @(PlaybackSpeedControlDoubleSpeed), @(PlaybackSpeedControlTripleSpeed) ];
                controller.titles = @[ @"Slower (0.5x)".ls, @"Normal (1x)".ls, @"Faster (1.1x)".ls, @"Faster (1.2x)".ls, @"Faster (1.3x)".ls, @"Faster (1.5x)".ls, @"Fast (2x)".ls, @"Crazy (3x)".ls ];
                [self.navigationController pushViewController:controller animated:YES];
                break;
            }
            case 4:
            {
                SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
                controller.valueType = kSettingTypeInteger;
                controller.key = kDefaultPlayerControls;
                controller.title = @"System Controls".ls;
                controller.values = @[ @(kPlayerSeekingControls), @(kPlayerSeekingAndSkippingChaptersControls), @(kPlayerSkippingControls)];
                controller.titles = @[ @"Seeking".ls, @"Seeking and Skipping Chapters".ls, @"Skipping".ls];
                [self.navigationController pushViewController:controller animated:YES];
                break;
            }
            default:
                break;
        }
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - Toggle actions

- (void) togglePlayerSettings:(UISwitch*)sender
{
    if (sender.tag == 0) {
        [USER_DEFAULTS setBool:sender.on forKey:PlayerReplayAfterPause];
    }
    else if (sender.tag == 5) {
        [USER_DEFAULTS setBool:sender.on forKey:DisableAutoLock];
    }
}

@end
