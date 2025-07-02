//
//  FeedSettingsViewController.m
//  Instacast
//
//  Created by Martin Hering on 17.02.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import "FeedSettingsViewController.h"

#import "SettingsValuesTableViewController.h"
#import "PlaybackDefines.h"
#import "CDModel.h"
#import "SubscriptionManager.h"
#import "UITableViewController+Settings.h"
#import "InstacastAppDelegate.h"
#import "SettingInputViewController.h"

enum {
    kEpisodesSection,
    kNewsModeSection,
    kAggregateUnavailableEpisodesSection,
    kAutoDownloadSettingsSection,
    kAutoDeleteSettingsSection,
    kPlaybackSection,
    kAutoSkipSection,
    kResetSection,
    kNumberOfSections
};

@interface FeedSettingsViewController ()
@property (nonatomic, strong) CDFeed* feed;

@end

@implementation FeedSettingsViewController 

+ (FeedSettingsViewController*) feedSettingsViewControllerWithFeed:(CDFeed*)feed;
{
    FeedSettingsViewController* controller = [[self alloc] initWithStyle:UITableViewStyleGrouped];
    controller.feed = feed;
    return controller;
}


#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
   
    
    self.clearsSelectionOnViewWillAppear = YES;

    
    if ([self.navigationController.viewControllers objectAtIndex:0] == self) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, [[UIScreen mainScreen] bounds].size.width, 44)];
        label.backgroundColor = [UIColor clearColor];
        label.numberOfLines = 2;
        label.font = [UIFont boldSystemFontOfSize: 16.0f];
        label.textAlignment = NSTextAlignmentCenter;
        if ([ICAppearanceManager sharedManager].nightSettingMode) {
            label.textColor = [UIColor whiteColor];
        } else {
            label.textColor = [UIColor blackColor];
        }
        label.text = [NSString stringWithFormat:@"%@\n%@", self.feed.title, @"Subscription Settings".ls];
        self.navigationItem.titleView = label;
        
#if !__has_feature(objc_arc)
        [label release];
#endif
        //
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(doneAction:)];
    } else {
        self.navigationItem.title = self.feed.title;
    }
}


- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
    [self.navigationController setToolbarHidden:YES animated:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}
- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    
    [self.tableView reloadData];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) doneAction:(id)sender
{
    [DMANAGER save];
    [self dismissViewControllerAnimated:YES completion:^{
        SubscriptionManager* sman = [SubscriptionManager sharedSubscriptionManager];
        [sman autoDownloadEpisodesInFeed:self.feed];
    }];
}

#pragma mark - Table view data source


- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kEpisodesSection:
            return 2;
        case kNewsModeSection:
            return 1;
        case kAggregateUnavailableEpisodesSection:
            return 1;
        case kAutoDownloadSettingsSection:
            return 2;
        case kAutoDeleteSettingsSection:
            return 3;
        case kPlaybackSection:
            return 3;
        case kAutoSkipSection:
            return 3;
        case kResetSection:
            return 1;
        default:
            break;
    }
    return 0;
}



- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = nil;

    if (indexPath.section == kEpisodesSection)
    {
        switch (indexPath.row) {
            case 0:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Sort Order".ls;
                
                NSString* feedSortOrder = [self.feed stringForKey:FeedSortOrder];
                cell.detailTextLabel.text = ([feedSortOrder isEqualToString:@"NewerFirst"]) ? @"Newest First".ls : @"Oldest First".ls;
                break;
            }
            case 1:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Restore Deleted Episodes".ls;
                cell.detailTextLabel.text = nil;
                break;
            }
            default:
            {
                break;
            }
        }
    }
    
    else if (indexPath.section == kNewsModeSection)
    {
        cell.accessoryView = nil;
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"News Mode".ls;
                control.on = [self.feed boolForKey:AutoDeleteNewsMode];
                break;
            default:
                break;
        }
        
        control.tag = indexPath.row;
        [control addTarget:self action:@selector(toggleNewsModeSettings:) forControlEvents:UIControlEventValueChanged];
        
        return cell;
    }
    
    else if (indexPath.section == kAggregateUnavailableEpisodesSection)
    {
        cell.accessoryView = nil;
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"Show Unavailable Episodes".ls;
                control.on = [self.feed boolForKey:kDefaultShowUnavailableEpisodes];
                break;
            default:
                break;
        }
        
        control.tag = indexPath.row;
        [control addTarget:self action:@selector(toggleShowUnavailableEpisodes:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    
    else if (indexPath.section == kAutoDownloadSettingsSection)
    {
        cell.accessoryView = nil;
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"Audio Content".ls;
                control.on = [self.feed boolForKey:AutoCacheNewAudioEpisodes];
                break;
            case 1:
                cell.textLabel.text = @"Video Content".ls;
                control.on = [self.feed boolForKey:AutoCacheNewVideoEpisodes];
                break;
            default:
                break;
        }
        
        control.tag = indexPath.row;
        [control addTarget:self action:@selector(toggleDownloadSettings:) forControlEvents:UIControlEventValueChanged];
        
        return cell;
    }
    
    else if (indexPath.section == kAutoDeleteSettingsSection)
    {
        if (indexPath.row == 2)
        {
            cell.accessoryView = nil;
            NSDictionary* vTemp = @{ @0 : @"Off", @1 : @"1 Day", @2 : @"2 Days", @3 : @"3 Days", @4 : @"5 Days", @5 : @"7 Days", @6 : @"10 Days", @7 : @"20 Days", @8 : @"30 Days"};
            cell = [self detailCell];
            cell.textLabel.text = @"If not played after".ls;
            cell.textLabel.numberOfLines = 0;
            NSString*daysKey = [NSString stringWithFormat:@"%@_old_episode_delete_days", self.feed.uid];
            NSNumber* getDeletedDays = [NSNumber numberWithInteger:[self.feed integerForKey:daysKey]];
            NSString* localizedKeyD = vTemp[@([getDeletedDays integerValue])];
            cell.detailTextLabel.text = localizedKeyD.ls;
        }
        else
        {
            cell.accessoryView = nil;
            UITableViewCell* cell = [self switchCell];
            UISwitch* control = (UISwitch*)cell.accessoryView;
            switch (indexPath.row) {
                case 0:
                    cell.textLabel.text = @"Finished Playing".ls;
                    control.on = [self.feed boolForKey:AutoDeleteAfterFinishedPlaying];
                    break;
                case 1:
                    cell.textLabel.text = @"Marked as Played".ls;
                    control.on = [self.feed boolForKey:AutoDeleteAfterMarkedAsPlayed];
                    break;
                default:
                    break;
            }
            control.tag = indexPath.row;
            [control addTarget:self action:@selector(toggleAutoDeleteSettings:) forControlEvents:UIControlEventValueChanged];
            return cell;
        }
    }

    else if (indexPath.section == kPlaybackSection)
    {
        NSDictionary* v = @{ @5 : @"5 Seconds", @10 : @"10 Seconds", @20 : @"20 Seconds", @30 : @"30 Seconds", @60 : @"1 Minute", @120 : @"2 Minutes", @300 : @"5 Minutes", @600 : @"10 Minutes" };
        
        switch (indexPath.row) {
            case 0:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Skipping Back".ls;
                
                NSInteger period = [self.feed integerForKey:PlayerSkipBackPeriod];
                NSString* localizedKey = v[@(period)];
                cell.detailTextLabel.text = localizedKey.ls;
                
                break;
            }
            case 1:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Skipping Forward".ls;
                
                NSInteger period = [self.feed integerForKey:PlayerSkipForwardPeriod];
                NSString* localizedKey = v[@(period)];
                cell.detailTextLabel.text = localizedKey.ls;
                
                break;
            }
            case 2:
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Speed".ls;
                
                NSInteger speed = [self.feed integerForKey:DefaultPlaybackSpeed];
                switch (speed) {
                    case PlaybackSpeedControlNormalSpeed:
                        cell.detailTextLabel.text = @"Normal (1x)".ls;
                        break;
                    case PlaybackSpeedControlDoubleSpeed:
                        cell.detailTextLabel.text = @"Fast (2x)".ls;
                        break;
                    case PlaybackSpeedControlPlusHalfSpeed:
                        cell.detailTextLabel.text = @"Faster (1.5x)".ls;
                        break;
                    case PlaybackSpeedControlMinusHalfSpeed:
                        cell.detailTextLabel.text = @"Slower (0.5x)".ls;
                        break;
                    case PlaybackSpeedControlTripleSpeed:
                        cell.detailTextLabel.text = @"Crazy (3x)".ls;
                        break;
                    case PlaybackSpeedControlFaster11:
                        cell.detailTextLabel.text = @"Faster (1.1x)".ls;
                        break;
                    case PlaybackSpeedControlFaster12:
                        cell.detailTextLabel.text = @"Faster (1.2x)".ls;
                        break;
                    case PlaybackSpeedControlFaster13:
                        cell.detailTextLabel.text = @"Faster (1.3x)".ls;
                        break;
                    default:
                        break;
                }
                
                
                break;
            default:
                break;
        }
    }
    else if (indexPath.section == kAutoSkipSection) 
    {
        cell = [self detailStepperCell];
        //NSDictionary* v = @{ @0 : @"0 Seconds",@5 : @"5 Seconds", @10 : @"10 Seconds", @20 : @"20 Seconds", @30 : @"30 Seconds", @60 : @"1 Minute", @120 : @"2 Minutes", @300 : @"5 Minutes", @600 : @"10 Minutes" };
        switch (indexPath.row) {
            case 0:
            {
                cell.accessoryView = nil;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", self.feed.uid];
                NSString *chaptersName = [self.feed stringForKey:key];
                cell.textLabel.text = @"Auto Skip Chapter".ls;
                cell.detailTextLabel.text = chaptersName;
                break;
            }
            case 1:
            {
                cell.textLabel.text = @"Skip intro".ls;
                double period = [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_start_period", self.feed.uid]];
                NSString *timeTest = [NSString stringWithFormat:@"%.1f %@", period, @"Seconds".ls];

                for (UIView *subview in cell.contentView.subviews) {
                    if ([subview isKindOfClass:[UIStackView class]]) {
                        [subview removeFromSuperview];
                    }
                }
                if ([self isSmallDevice]) {
                    UILabel *detailLabel = [[UILabel alloc] init];
                    detailLabel.text = timeTest;
                    detailLabel.textColor = [UIColor grayColor];
                    detailLabel.textAlignment = NSTextAlignmentLeft;
                    detailLabel.numberOfLines = 0;
                    
                    UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[cell.textLabel, detailLabel]];
                    stackView.axis = UILayoutConstraintAxisVertical;
                    stackView.spacing = 5;
                    stackView.alignment = UIStackViewAlignmentLeading;
                    
                    stackView.translatesAutoresizingMaskIntoConstraints = NO;
                    [cell.contentView addSubview:stackView];
                    
                    // Add Constraints
                    [NSLayoutConstraint activateConstraints:@[
                        [stackView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:15],
                        [stackView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-15],
                        [stackView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                        [stackView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
                    ]];
                }
                else
                {
                    cell.detailTextLabel.text = timeTest;
                }
                [self addStepperToCell:cell forStart:YES];
                break;
            }
            case 2:
            {
                cell.textLabel.text =  @"Skip outro".ls;
               
                double period = [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_end_period", self.feed.uid]];
                NSString *timeTest = [NSString stringWithFormat:@"%.1f %@", period, @"Seconds".ls];
                
                for (UIView *subview in cell.contentView.subviews) {
                    if ([subview isKindOfClass:[UIStackView class]]) {
                        [subview removeFromSuperview];
                    }
                }
                if ([self isSmallDevice]) {
                    UILabel *detailLabel = [[UILabel alloc] init];
                    detailLabel.text = timeTest;
                    detailLabel.textColor = [UIColor grayColor];
                    detailLabel.textAlignment = NSTextAlignmentLeft;
                    detailLabel.numberOfLines = 0;
                    
                    UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[cell.textLabel, detailLabel]];
                    stackView.axis = UILayoutConstraintAxisVertical;
                    stackView.spacing = 5;
                    stackView.alignment = UIStackViewAlignmentLeading;
                    
                    stackView.translatesAutoresizingMaskIntoConstraints = NO;
                    [cell.contentView addSubview:stackView];
                    
                    // Add Constraints
                    [NSLayoutConstraint activateConstraints:@[
                        [stackView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:15],
                        [stackView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-15],
                        [stackView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                        [stackView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
                    ]];
                }
                else
                {
                    cell.detailTextLabel.text = timeTest;
                }
                [self addStepperToCell:cell forStart:NO];
                break;
            }
            default:
                break;
        }
    }
    else if (indexPath.section == kResetSection)
    {
        cell.accessoryView = nil;
        cell = [self resetCell];
        cell.textLabel.text = @"Reset to Defaults".ls;
        
        if (![self.feed hasCustomProperties])
        {
            cell.userInteractionEnabled = NO;
            cell.textLabel.textColor = ICMutedTextColor;
        }
        else
        {
            cell.userInteractionEnabled = YES;
            cell.textLabel.textColor = [UIColor redColor];
        }
    }
    
    return cell;
}
- (BOOL)isSmallDevice {
    return ([UIScreen mainScreen].bounds.size.width < 375); // iPhone SE and similar
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kEpisodesSection:
            return @"Episodes".ls;
            break;
        case kAutoDownloadSettingsSection:
            return @"Auto-Download Content".ls;
            break;
        case kAutoDeleteSettingsSection:
            return @"Auto-Delete Content".ls;
            break;
        case kPlaybackSection:
            return @"Playback".ls;
            break;
        case kAutoSkipSection:
            return @"Auto Skip".ls;
        default:
            break;
    }
    return nil;
}

- (void) toggleShowUnavailableEpisodes:(UISwitch*)sender
{
    [self setBool:sender.on forKey:kDefaultShowUnavailableEpisodes];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kResetSection] withRowAnimation:UITableViewRowAnimationNone];
}


#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kEpisodesSection)
    {
        if (indexPath.row == 0)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            
            controller.key = FeedSortOrder;
            controller.valueType = kSettingTypeString;
            controller.title = @"Sort Order".ls;
            controller.values = [NSArray arrayWithObjects:@"NewerFirst", @"OlderFirst", nil];
            controller.titles = [NSArray arrayWithObjects:@"Newest First".ls, @"Oldest First".ls, nil];
            
            [self.navigationController pushViewController:controller animated:YES];
        } else if (indexPath.row == 1) 
        {
            NSLog(@"Restore Deleted Episode Tappped");
            WEAK_SELF
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Are you sure you want to restore?".ls message:nil preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Yes".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                STRONG_SELF
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                [self restoreDeletedEpisodes];
                self.alertController = nil;
            }]];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
                STRONG_SELF
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                self.alertController = nil;
            }]];
            
            [alert setModalPresentationStyle:UIModalPresentationPopover];
            UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
            UIViewController* rootViewController = [(InstacastAppDelegate*)[[UIApplication sharedApplication]delegate] getRootViewControllerDev];
            popPresenter.sourceView = [rootViewController view];
            popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
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
    }
    else if (indexPath.section == kAutoDeleteSettingsSection)
    {
        if (indexPath.row == 2)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            controller.valueType = kSettingTypeInteger;
            controller.key = [NSString stringWithFormat:@"%@_old_episode_delete_days", self.feed.uid];
            controller.title = @"If not played after".ls;
            controller.values = @[ @(0), @(1), @(2), @(3), @(4), @(5), @(6), @(7), @(8)];
            controller.titles = @[@"Off".ls, @"1 Day".ls, @"2 Days".ls, @"3 Days".ls, @"5 Days".ls, @"7 Days".ls, @"10 Days".ls, @"20 Days".ls, @"30 Days".ls];
            [self.navigationController pushViewController:controller animated:YES];
        }
    }
    else if (indexPath.section == kPlaybackSection)
    {
        if (indexPath.row == 0 || indexPath.row == 1)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            controller.valueType = kSettingTypeInteger;
            controller.key = (indexPath.row == 0 ) ? PlayerSkipBackPeriod : PlayerSkipForwardPeriod;
            controller.title = (indexPath.row == 0 ) ? @"Skipping Back".ls : @"Skipping Forward".ls;
            controller.values = @[ @(5), @(10), @(20), @(30), @(60), @(120), @(300), @(600) ];
            controller.titles = @[@"5 Seconds".ls, @"10 Seconds".ls, @"20 Seconds".ls, @"30 Seconds".ls, @"1 Minute".ls, @"2 Minutes".ls, @"5 Minutes".ls, @"10 Minutes".ls];
            [self.navigationController pushViewController:controller animated:YES];
        }
        
        else if (indexPath.row == 2)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            controller.valueType = kSettingTypeInteger;
            controller.key = DefaultPlaybackSpeed;
            controller.title = @"Speed".ls;
            controller.values = [NSArray arrayWithObjects:
                                 [NSNumber numberWithInteger:PlaybackSpeedControlMinusHalfSpeed],
                                 [NSNumber numberWithInteger:PlaybackSpeedControlNormalSpeed],
                                 [NSNumber numberWithInteger:PlaybackSpeedControlFaster11],
                                 [NSNumber numberWithInteger:PlaybackSpeedControlFaster12],
                                 [NSNumber numberWithInteger:PlaybackSpeedControlFaster13],
                                 [NSNumber numberWithInteger:PlaybackSpeedControlPlusHalfSpeed],
                                 [NSNumber numberWithInteger:PlaybackSpeedControlDoubleSpeed],
                                 [NSNumber numberWithInteger:PlaybackSpeedControlTripleSpeed],
                                 nil];
            controller.titles = [NSArray arrayWithObjects:
                                 @"Slower (0.5x)".ls,
                                 @"Normal (1x)".ls,
                                 @"Faster (1.1x)".ls,
                                 @"Faster (1.2x)".ls,
                                 @"Faster (1.3x)".ls,
                                 @"Faster (1.5x)".ls,
                                 @"Fast (2x)".ls,
                                 @"Crazy (3x)".ls, nil];
            [self.navigationController pushViewController:controller animated:YES];
        }
    }
    
    else if (indexPath.section == kAutoSkipSection) {
        if (indexPath.row == 0) {
            SettingInputViewController* controller = [SettingInputViewController inputSampleViewController];
            //controller.title = @"Skipping Chapter".ls;
            controller.feed = self.feed;
            controller.titleStr = @"Skipping Chapter".ls;
            NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", self.feed.uid];
            controller.key = key;
            NSString *chaptersName = [self.feed stringForKey:key];
            NSArray *names = [chaptersName componentsSeparatedByString:@".  "];
            controller.valueType = kSettingTypeString;
            controller.inputValues = [NSMutableArray arrayWithArray:names];
            [self.navigationController pushViewController:controller animated:YES];
        }
       
    }
        
    else if (indexPath.section == kResetSection)
    {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];

        WEAK_SELF
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Reset to Defaults".ls
                                                                       message:@"Are you sure you want to reset all custom subscription settings to default?".ls
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset".ls
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * action) {
                                                    STRONG_SELF
                                                    [self perform:^(id sender) {
                                                        [self.feed resetAllProperties];
                                                        [self.tableView reloadData];
                                                    } afterDelay:0.3];
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

}

-(void)restoreDeletedEpisodes
{
    NSManagedObjectContext* context = DMANAGER.objectContext;
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:context];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed = %@ && archived == %@", self.feed, @YES];
    NSArray * episodes = [context executeFetchRequest:fetchRequest error:nil];
    
    for (int index = 0; index < [episodes count]; index++)
    {
        CDEpisode* episode = episodes[index];
        [DMANAGER setEpisode:episode archived:NO];
    }
    [DMANAGER save];
}


- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kResetSection) {
        return @"Resets subscription specific settings back to default settings.".ls;
    }
    else if (section == kNewsModeSection) {
        return @"Enable News Mode to only keep the most recent episode(s) of a podcast.".ls;
    }
    else if (section == kAggregateUnavailableEpisodesSection) {
        return @"Enable to show all episodes regardless of whether or not they are still available on the publisher's server.".ls;
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


- (void) setBool:(BOOL)value forKey:(NSString*)key
{
    if (value == [USER_DEFAULTS boolForKey:key]) {
        [self.feed resetValueForKey:key];
    }
    else {
        [self.feed setBool:value forKey:key];
    }
}

- (void) toggleDownloadSettings:(UISwitch*)sender
{
    switch (sender.tag) {
        case 0:
            [self setBool:sender.on forKey:AutoCacheNewAudioEpisodes];
            break;
        case 1:
            [self setBool:sender.on forKey:AutoCacheNewVideoEpisodes];
            break;
            
        default:
            break;
    }
    
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kResetSection] withRowAnimation:UITableViewRowAnimationNone];
}

- (void) toggleNewsModeSettings:(UISwitch*)sender
{
    if (sender.tag == 0) {
        [self setBool:sender.on forKey:AutoDeleteNewsMode];
    }
    
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kResetSection] withRowAnimation:UITableViewRowAnimationNone];
}


- (void) toggleAutoDeleteSettings:(UISwitch*)sender
{
    if (sender.tag == 0) {
        [self setBool:sender.on forKey:AutoDeleteAfterFinishedPlaying];
    }
    else if (sender.tag == 1) {
        [self setBool:sender.on forKey:AutoDeleteAfterMarkedAsPlayed];
    }
    else if (sender.tag == 2) {
        [self setBool:sender.on forKey:AutoDeleteNewsMode];
        
    }
    
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kResetSection] withRowAnimation:UITableViewRowAnimationNone];
}


#pragma mark - Stepper Handlers
- (void)addStepperToCell:(UITableViewCell *)cell forStart:(BOOL)isStart {
    cell.accessoryView = nil;
    if ([cell.accessoryView isKindOfClass:[UIStepper class]]) {
        [(UIStepper *)cell.accessoryView removeFromSuperview];
    }

    UIStepper *stepper = [[UIStepper alloc] init];
    stepper.stepValue = 0.1; // ⬅️ Step value for 0.1 second
    stepper.tag = isStart ? 1 : 2;

    double period = isStart ?
        [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_start_period", self.feed.uid]] :
        [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_end_period", self.feed.uid]];

    stepper.minimumValue = -300.0; // -5 minutes
    stepper.maximumValue = 300.0;  // +5 minutes
    stepper.value = period;

    UIColor *colorTemp = [ICAppearanceManager sharedManager].nightSettingMode ? [UIColor whiteColor] : [UIColor blackColor];
    UIImage *plusImage = [[UIImage systemImageNamed:@"plus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *minusImage = [[UIImage systemImageNamed:@"minus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];

    [stepper setIncrementImage:plusImage forState:UIControlStateNormal];
    [stepper setDecrementImage:minusImage forState:UIControlStateNormal];

    [stepper addTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = stepper;
}



- (void)stepperValueChanged:(UIStepper *)sender {
    NSString *key = (sender.tag == 1) ?
        [NSString stringWithFormat:@"%@_auto_skip_start_period", self.feed.uid] :
        [NSString stringWithFormat:@"%@_auto_skip_end_period", self.feed.uid];

    double newValue = sender.value;

    if (self.feed) {
        [[self source] setDouble:newValue forKey:key];
    }

    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:sender.tag inSection:kAutoSkipSection]] withRowAnimation:UITableViewRowAnimationNone];
}



- (id) source
{
    return (self.feed) ? self.feed : USER_DEFAULTS;
}




@end
