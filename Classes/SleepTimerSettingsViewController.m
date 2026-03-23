//
//  SleepTimerSettingsViewController.m
//  Instacast
//

#import "SleepTimerSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "PlaybackDefines.h"
#import "InstacastAppDelegate.h"
#import "AudioSession.h"
#import "PlaybackManager.h"
#if !TARGET_OS_MACCATALYST
#import <CarPlay/CarPlay.h>
#endif

typedef NS_ENUM(NSInteger, SleepTimerSettingsSections) {
    kAutomaticTimer = 0,
    kIntelligentSleep,
    kCarPlaySection,
    kNumberOfSections,
};

@interface SleepTimerSettingsViewController ()
@property (nonatomic, weak) UILabel* thresholdValueLabel;
@property (nonatomic, weak) UILabel* motionIndicatorLabel;
@end

@implementation SleepTimerSettingsViewController {
    BOOL _thresholdHighlighted;
}

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

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(motionDetected)
                                                 name:ApplicationDidDetectMotionNotification
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

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fadeBackMotionIndicator) object:nil];
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
        case kAutomaticTimer:
            return 1;
        case kIntelligentSleep:
            return [USER_DEFAULTS boolForKey:DeviceMovementIntelligentSleep] ? 4 : 3;
        case kCarPlaySection:
            return 1;
        default:
            break;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kAutomaticTimer)
    {
        if (indexPath.row == 0)
        {
            UITableViewCell* cell = [self switchCell];
            UISwitch* control = (UISwitch*)cell.accessoryView;
            control.tag = indexPath.row;

            cell.textLabel.text = @"Sleep Timer Always Active".ls;
            control.on = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
            [control addTarget:self action:@selector(toggleSleepTimeAlwaysSettings:) forControlEvents:UIControlEventValueChanged];
            return cell;
        }
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
            case 3:
            {
                UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                cell.backgroundColor = ICGroupCellBackgroundColor;
                cell.textLabel.text = @"Schwellwert für Bewegung".ls;
                cell.textLabel.textColor = ICTextColor;
                cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
                self.motionIndicatorLabel = cell.textLabel;

                UIButton *minusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                [minusBtn setTitle:@"−" forState:UIControlStateNormal];
                minusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(20)];
                [minusBtn addTarget:self action:@selector(decreaseThreshold:) forControlEvents:UIControlEventTouchUpInside];

                UILabel *valueLbl = [[UILabel alloc] init];
                double currentThreshold = [USER_DEFAULTS doubleForKey:DeviceMovementSensitivity];
                if (currentThreshold <= 0) currentThreshold = 0.004;
                valueLbl.text = [NSString stringWithFormat:@"%.3f", currentThreshold];
                valueLbl.textColor = ICTextColor;
                valueLbl.font = [UIFont monospacedDigitSystemFontOfSize:ICFontSize(15) weight:UIFontWeightMedium];
                valueLbl.textAlignment = NSTextAlignmentCenter;
                self.thresholdValueLabel = valueLbl;

                UIButton *plusBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                [plusBtn setTitle:@"+" forState:UIControlStateNormal];
                plusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(20)];
                [plusBtn addTarget:self action:@selector(increaseThreshold:) forControlEvents:UIControlEventTouchUpInside];

                UIStackView *controlStack = [[UIStackView alloc] initWithArrangedSubviews:@[minusBtn, valueLbl, plusBtn]];
                controlStack.axis = UILayoutConstraintAxisHorizontal;
                controlStack.spacing = 12;
                controlStack.alignment = UIStackViewAlignmentCenter;
                [controlStack sizeToFit];
                CGFloat scale = [ICAppearanceManager sharedManager].fontSizeScale;
                controlStack.frame = CGRectMake(0, 0, 120 * scale, 30 * scale);
                cell.accessoryView = controlStack;

                return cell;
            }
            default:
                break;
        }
    }
    else if (indexPath.section == kCarPlaySection)
    {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        control.tag = indexPath.row;

        cell.textLabel.text = @"Disable Sleep Timer in CarPlay".ls;
        control.on = [USER_DEFAULTS boolForKey:DisableSleepTimerInCarPlay];
        [control addTarget:self action:@selector(toggleCarPlaySleepTimerSettings:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    return nil;
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kAutomaticTimer:
            return @"";
        case kIntelligentSleep:
            return @"Smart Sleep Timer reset at:".ls;
        case kCarPlaySection:
            return @"";
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
        case kAutomaticTimer:
        {
            if ([USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive]) {
                return @"If a podcast is playing, the sleep timer will be enabled automatically. Prevents podcasts from unintentionally playing trough the night.".ls;
            }
            return nil;
        }
        case kIntelligentSleep:
        {
            return @"The Smart Sleep Timer automatically resets its countdown when it detects you are still awake, so your podcast keeps playing until you fall asleep.".ls;
        }
        case kCarPlaySection:
        {
            if ([USER_DEFAULTS boolForKey:DisableSleepTimerInCarPlay]) {
                return @"While CarPlay is active, the Sleep Timer stays disabled.".ls;
            }
            return nil;
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

#pragma mark - Helpers

- (BOOL)isCarPlayConnected
{
#if TARGET_OS_MACCATALYST
    return NO;
#else
    if (@available(iOS 13.0, *))
    {
        NSSet<UIScene*>* connectedScenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene* scene in connectedScenes)
        {
            if ([scene.session.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication] &&
                scene.activationState != UISceneActivationStateUnattached &&
                scene.activationState != UISceneActivationStateBackground)
            {
                return YES;
            }
        }
    }
    return NO;
#endif
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
            NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
            if (lastSleepTimer <= 0) {
                [USER_DEFAULTS setInteger:PlaybackStopTime5min forKey:LastSelectedSleepTimer];
            }
        }
    }
    [self.tableView reloadData];
}

- (void) toggleCarPlaySleepTimerSettings:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:DisableSleepTimerInCarPlay];

    AudioSession* session = [AudioSession sharedAudioSession];
    if (sender.on) {
        if ([self isCarPlayConnected]) {
            session.timerValue = PlaybackStopTimeNoValue;
        }
    }
    else if ([PlaybackManager playbackManager].isPodcastPlaying && [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive]) {
        NSInteger timer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
        if (timer == PlaybackStopTimeNoValue) {
            NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
            timer = (lastSleepTimer > 0) ? lastSleepTimer : PlaybackStopTime5min;
        }
        session.timerValue = timer;
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
        NSIndexPath *thresholdPath = [NSIndexPath indexPathForRow:3 inSection:kIntelligentSleep];
        [self.tableView beginUpdates];
        if (sender.on) {
            [self.tableView insertRowsAtIndexPaths:@[thresholdPath] withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [self.tableView deleteRowsAtIndexPaths:@[thresholdPath] withRowAnimation:UITableViewRowAnimationFade];
        }
        [self.tableView endUpdates];
    }
}

- (void)motionDetected
{
    UILabel *label = self.motionIndicatorLabel;
    if (!label || !label.text) return;

    if (!_thresholdHighlighted) {
        _thresholdHighlighted = YES;
        NSString *text = label.text;
        NSRange lastSpace = [text rangeOfString:@" " options:NSBackwardsSearch];
        NSRange wordRange = (lastSpace.location != NSNotFound)
            ? NSMakeRange(lastSpace.location + 1, text.length - lastSpace.location - 1)
            : NSMakeRange(0, text.length);

        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: label.font,
            NSForegroundColorAttributeName: label.textColor
        }];
        [attr addAttribute:NSBackgroundColorAttributeName value:ICTintColor range:wordRange];
        label.attributedText = attr;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fadeBackMotionIndicator) object:nil];
    [self performSelector:@selector(fadeBackMotionIndicator) withObject:nil afterDelay:0.3];
}

- (void)fadeBackMotionIndicator
{
    _thresholdHighlighted = NO;
    UILabel *label = self.motionIndicatorLabel;
    if (!label || !label.text) return;

    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:label.text attributes:@{
        NSFontAttributeName: label.font,
        NSForegroundColorAttributeName: label.textColor
    }];
    label.attributedText = attr;
}

- (void)decreaseThreshold:(UIButton*)sender
{
    double threshold = [USER_DEFAULTS doubleForKey:DeviceMovementSensitivity];
    if (threshold <= 0) threshold = 0.004;
    threshold -= 0.001;
    if (threshold < 0.001) threshold = 0.001;
    [USER_DEFAULTS setDouble:threshold forKey:DeviceMovementSensitivity];
    self.thresholdValueLabel.text = [NSString stringWithFormat:@"%.3f", threshold];
}

- (void)increaseThreshold:(UIButton*)sender
{
    double threshold = [USER_DEFAULTS doubleForKey:DeviceMovementSensitivity];
    if (threshold <= 0) threshold = 0.004;
    threshold += 0.001;
    [USER_DEFAULTS setDouble:threshold forKey:DeviceMovementSensitivity];
    self.thresholdValueLabel.text = [NSString stringWithFormat:@"%.3f", threshold];
}

@end
