//
//  EnabledSpeedStepsViewController.m
//  Instacast
//

#import "EnabledSpeedStepsViewController.h"
#import "UITableViewController+Settings.h"
#import "PlayerSpeedButton.h"
#import "PlaybackDefines.h"

@implementation EnabledSpeedStepsViewController

+ (EnabledSpeedStepsViewController*) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.navigationItem.title = @"Enabled Speed Steps".ls;

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
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [PlayerSpeedButton allSpeedControlsDescending].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [self standardCell];

    NSArray* allSpeeds = [PlayerSpeedButton allSpeedControlsDescending];
    NSNumber* speed = allSpeeds[indexPath.row];
    NSArray* enabledSpeeds = [PlayerSpeedButton enabledSpeedControls];
    BOOL isEnabled = [enabledSpeeds containsObject:speed];
    BOOL isNormal = (speed.integerValue == PlaybackSpeedControlNormalSpeed);

    cell.textLabel.text = [PlayerSpeedButton titleForSpeedControl:speed.integerValue];
    cell.accessoryType = isEnabled ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;

    if (isNormal) {
        cell.textLabel.textColor = ICTextColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.textColor = ICTextColor;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    return cell;
}

- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"Select which speed steps are available in the player. 1x is always enabled.".ls;
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
    [footer.textLabel setTextColor:[UIColor grayColor]];
    footer.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString* text = [self tableView:tableView titleForFooterInSection:section];
    return [self heightForFooterText:text];
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSArray* allSpeeds = [PlayerSpeedButton allSpeedControlsDescending];
    NSNumber* speed = allSpeeds[indexPath.row];

    // 1x is always enabled
    if (speed.integerValue == PlaybackSpeedControlNormalSpeed) {
        return;
    }

    NSMutableArray* current = [[PlayerSpeedButton enabledSpeedControls] mutableCopy];
    if ([current containsObject:speed]) {
        [current removeObject:speed];
    } else {
        [current addObject:speed];
    }
    [USER_DEFAULTS setObject:current forKey:EnabledPlaybackSpeedsKey];

    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
