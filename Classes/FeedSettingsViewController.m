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
#import "ChapterSkipListViewController.h"
#import "SkipTimeCell.h"
#import "AppleWatchSyncManager.h"
#import "VDModalInfo.h"
#import "InstacastPlus-Swift.h"

static const NSUInteger ICRestoreArchivedEpisodeBatchSize = 100;

enum {
    kEpisodesSection,
    kTranscriptionSection,
    kAutoSkipSection,
    kChapterEndSponsorSkipSection,
    kAutoDownloadSettingsSection,
    kAppleWatchSection,
    kAutoDeleteSettingsSection,
    kNewsModeSection,
    kPlaybackSection,
    kRestoreDeletedSection,
    kAggregateUnavailableEpisodesSection,
    kSyncPauseSection,
    kResetSection,
    kNumberOfSections
};

@interface FeedSettingsViewController () <UITextFieldDelegate>
@property (nonatomic, strong) CDFeed* feed;
@property (nonatomic) BOOL appleWatchSettingsSnapshotValid;
@property (nonatomic) NSInteger appleWatchSendLatestCountSnapshot;
@property (nonatomic) BOOL appleWatchOnlyUnplayedSnapshot;
@property (nonatomic, strong) NSNumber* archivedEpisodeCount;
@property (nonatomic, strong) NSError* archivedEpisodeCountError;
@property (nonatomic) NSUInteger archivedEpisodeCountGeneration;
@property (nonatomic) BOOL restoreDeletedEpisodesInProgress;

- (BOOL)_saveAndSyncAppleWatchSettings;

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

    [self.tableView registerNib:[UINib nibWithNibName:@"SkipTimeCell" bundle:nil] forCellReuseIdentifier:@"SkipTimeCell"];
    if ([self.navigationController.viewControllers objectAtIndex:0] == self) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, [[UIScreen mainScreen] bounds].size.width, 44)];
        label.backgroundColor = [UIColor clearColor];
        label.numberOfLines = 2;
        label.font = [UIFont boldSystemFontOfSize:ICFontSize(16.0f)];
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = ICTextColor;
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
    // Add tap gesture to dismiss keyboard
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGesture.cancelsTouchesInView = NO; // Allow other interactions (e.g., stepper)
    [self.tableView addGestureRecognizer:tapGesture];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)handleTap:(UITapGestureRecognizer *)sender {
    [self.view endEditing:YES]; // Dismiss keyboard
}



- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
    [self syncAppleWatchSettingsIfNeeded];
    [self.navigationController setToolbarHidden:YES animated:YES];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView reloadData];
    [self _reloadArchivedEpisodeCount];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];

    UILabel *titleLabel = (UILabel *)self.navigationItem.titleView;
    if ([titleLabel isKindOfClass:[UILabel class]]) {
        titleLabel.textColor = ICTextColor;
    }

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

- (void) dealloc
{
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

- (BOOL)_nearChapterEndForwardSkipEnabled
{
    return [self.feed integerForKey:PlayerNearChapterEndForwardSkipMode] > 0;
}


- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kEpisodesSection:
            return 1;
        case kTranscriptionSection:
            return ICAITranscriptionFeaturesEnabled() ? 3 : 0; // auto-transcribe, auto-chapters, sponsor-skip
        case kAutoSkipSection:
            return 3;
        case kChapterEndSponsorSkipSection:
            return [self _nearChapterEndForwardSkipEnabled] ? 2 : 1;
        case kNewsModeSection:
            return 1;
        case kAggregateUnavailableEpisodesSection:
            return 1;
        case kAutoDownloadSettingsSection:
            return 2;
        case kAppleWatchSection:
            return 2;
        case kAutoDeleteSettingsSection:
            return 4;
        case kPlaybackSection:
            return 4;
        case kRestoreDeletedSection:
            return (self.archivedEpisodeCount.unsignedIntegerValue > 0 || self.archivedEpisodeCountError) ? 1 : 0;
        case kSyncPauseSection:
            return 1;
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
        cell.accessoryView = nil;
        cell = [self detailCell];
        cell.textLabel.text = @"Sort Order".ls;

        NSString* feedSortOrder = [self.feed stringForKey:FeedSortOrder];
        cell.detailTextLabel.text = ([feedSortOrder isEqualToString:@"NewerFirst"]) ? @"Newest First".ls : @"Oldest First".ls;
    }

    else if (indexPath.section == kTranscriptionSection)
    {
        cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        control.tag = 1000 + indexPath.row; // offset to avoid conflicts

        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = NSLocalizedString(@"Neue Folgen transkribieren", nil);
                {
                    NSString* val = [self.feed stringForKey:kFeedPropertyAutoTranscribe];
                    control.on = (val == nil || [val isEqualToString:@"default"])
                        ? [USER_DEFAULTS boolForKey:kTranscriptionAutoDefault]
                        : [val isEqualToString:@"yes"];
                }
                break;
            case 1:
                cell.textLabel.text = NSLocalizedString(@"Neue Folgen analysieren", nil);
                {
                    NSString* val = [self.feed stringForKey:kFeedPropertyAutoChapters];
                    control.on = (val == nil || [val isEqualToString:@"default"])
                        ? [USER_DEFAULTS boolForKey:kChapterAutoDefault]
                        : [val isEqualToString:@"yes"];
                }
                break;
            case 2:
                cell.textLabel.text = NSLocalizedString(@"Sponsoren überspringen", nil);
                {
                    NSString* val = [self.feed stringForKey:kFeedPropertyAutoSkipSponsors];
                    control.on = (val == nil || [val isEqualToString:@"default"])
                        ? [USER_DEFAULTS boolForKey:kAutoSkipSponsors]
                        : [val isEqualToString:@"yes"];
                }
                break;
        }

        [control addTarget:self action:@selector(_transcriptionToggleChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    else if (indexPath.section == kRestoreDeletedSection)
    {
        if (self.archivedEpisodeCountError) {
            cell = [self detailCell];
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"Restore Deleted Episodes".ls;
            cell.detailTextLabel.text = @"Try Again".ls;
        }
        else {
            cell = [self buttonCell];
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.textLabel.text = @"Restore Deleted Episodes".ls;
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

    else if (indexPath.section == kAppleWatchSection)
    {
        if (indexPath.row == 0)
        {
            cell.accessoryView = nil;
            cell = [self detailCell];
            cell.textLabel.text = @"Neueste Episoden senden".ls;
            NSInteger count = [self.feed integerForKey:AppleWatchSendLatestCount];
            if (count <= 0) {
                cell.detailTextLabel.text = @"Off".ls;
            }
            else if (count == 1) {
                cell.detailTextLabel.text = @"1 Episode".ls;
            }
            else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%d Episodes".ls, (int)count];
            }
        }
        else
        {
            cell.accessoryView = nil;
            UITableViewCell* cell = [self switchCell];
            UISwitch* control = (UISwitch*)cell.accessoryView;
            cell.textLabel.text = @"Nur ungespielte Episoden".ls;
            control.on = [self.feed boolForKey:AppleWatchOnlyUnplayed];
            control.tag = indexPath.row;
            [control addTarget:self action:@selector(toggleAppleWatchSettings:) forControlEvents:UIControlEventValueChanged];
            return cell;
        }
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
        else if (indexPath.row == 3)
        {
            cell.accessoryView = nil;
            cell = [self detailCell];
            cell.textLabel.text = @"Keep only newest".ls;
            NSInteger keepCount = [self.feed integerForKey:KeepNewestEpisodesCount];
            if (keepCount <= 0) {
                cell.detailTextLabel.text = @"Off".ls;
            } else if (keepCount == 1) {
                cell.detailTextLabel.text = @"1 Episode".ls;
            } else {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%d Episodes".ls, (int)keepCount];
            }
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
        NSInteger playbackRow = indexPath.row;

        switch (playbackRow) {
            case 0:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Continuous Playback".ls;

                NSInteger mode = [self.feed integerForKey:ContinuousPlayFromFeed];
                switch (mode) {
                    case ContinuousPlaybackOn:
                        cell.detailTextLabel.text = @"Newer to Older".ls;
                        break;
                    case ContinuousPlaybackReverse:
                        cell.detailTextLabel.text = @"Older to Newer".ls;
                        break;
                    default:
                        cell.detailTextLabel.text = @"Off".ls;
                        break;
                }
                break;
            }
            case 1:
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
            case 2:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Skipping Back".ls;

                NSInteger period = [self.feed integerForKey:PlayerSkipBackPeriod];
                NSString* localizedKey = v[@(period)];
                cell.detailTextLabel.text = localizedKey.ls;

                break;
            }
            case 3:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Skipping Forward".ls;

                NSInteger period = [self.feed integerForKey:PlayerSkipForwardPeriod];
                NSString* localizedKey = v[@(period)];
                cell.detailTextLabel.text = localizedKey.ls;

                break;
            }
            default:
                break;
        }
    }
    else if (indexPath.section == kChapterEndSponsorSkipSection)
    {
        NSDictionary* chapterEndSkipModes = @{ @0 : @"Aus", @1 : @"Ein", @5 : @"Ein + 5 Sekunden", @10 : @"Ein + 10 Sekunden", @15 : @"Ein + 15 Sekunden", @20 : @"Ein + 20 Sekunden" };
        NSDictionary* chapterEndSkipWindows = @{ @60 : @"1 Minute", @120 : @"2 Minutes", @180 : @"3 Minutes", @240 : @"4 Minutes", @300 : @"5 Minutes" };

        switch (indexPath.row) {
            case 0:
            {
                static NSString *ChapterEndSponsorSkipCellIdentifier = @"ChapterEndSponsorSkipCell";
                cell = [tableView dequeueReusableCellWithIdentifier:ChapterEndSponsorSkipCellIdentifier];
                if (cell == nil) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ChapterEndSponsorSkipCellIdentifier];
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectedBackgroundView = [[UIView alloc] init];
                }

                cell.accessoryView = nil;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.backgroundColor = ICGroupCellBackgroundColor;
                cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
                cell.textLabel.textColor = ICTextColor;
                cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(17)];
                cell.textLabel.numberOfLines = 1;
                cell.textLabel.adjustsFontSizeToFitWidth = YES;
                cell.textLabel.minimumScaleFactor = 0.85;
                cell.detailTextLabel.textColor = ICMutedTextColor;
                cell.detailTextLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
                cell.detailTextLabel.numberOfLines = 1;
                cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
                cell.detailTextLabel.minimumScaleFactor = 0.85;
                cell.textLabel.text = @"Sponsoren am Kapitelende überspringen".ls;

                NSInteger mode = [self.feed integerForKey:PlayerNearChapterEndForwardSkipMode];
                NSString* localizedKey = chapterEndSkipModes[@(mode)];
                cell.detailTextLabel.text = localizedKey.ls;
                break;
            }
            case 1:
            {
                cell.accessoryView = nil;
                cell = [self detailCell];
                cell.textLabel.text = @"Ende des Kapitels ab".ls;

                NSInteger seconds = [self.feed integerForKey:PlayerNearChapterEndForwardSkipWindow];
                NSString* localizedKey = chapterEndSkipWindows[@(seconds)];
                cell.detailTextLabel.text = localizedKey.ls;
                break;
            }
            default:
                break;
        }
    }
    else if (indexPath.section == kAutoSkipSection) 
    {
        if (indexPath.row == 0)
        {
            cell = [self detailStepperCell];
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", self.feed.uid];
            NSString *chaptersName = [self.feed stringForKey:key];
            cell.textLabel.text = @"Skip Chapter".ls;

            if (chaptersName.length == 0) {
                cell.detailTextLabel.text = @"None".ls;
            } else {
                NSArray *names = [chaptersName componentsSeparatedByString:@".  "];
                if (names.count == 1) {
                    cell.detailTextLabel.text = names.firstObject;
                } else {
                    cell.detailTextLabel.text = [NSString stringWithFormat:@"%d Keywords".ls, (int)names.count];
                }
            }
            return cell;
        }
        else
        {
            SkipTimeCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SkipTimeCell" forIndexPath:indexPath];
            if (cell == nil) {
                cell = [[SkipTimeCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"SkipTimeCell"];
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectedBackgroundView = [[UIView alloc] init];
            }
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.contentView.backgroundColor = ICGroupCellBackgroundColor;
            cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
            
            BOOL isNightMode = [ICAppearanceManager sharedManager].nightSettingMode;
            cell.titleLbl.textColor = isNightMode ? [UIColor whiteColor] : [UIColor blackColor];
            cell.timeTF.textColor = ICMutedTextColor;
            cell.secondsLbl.textColor = ICMutedTextColor;
            cell.timeTF.text = @"";
            double period = [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_%@_period", self.feed.uid, (indexPath.row == 1 ? @"start" : @"end")]];
            cell.timeTF.text = [NSString stringWithFormat:@"%.1f", period];
            cell.timeTF.delegate = self;
            cell.secondsLbl.text = @"Seconds".ls;
            
            if (indexPath.row == 1) {
                cell.titleLbl.text = @"Skip intro".ls;
                [self configureStepper:cell.stepperView forStart:YES];
            } else {
                cell.titleLbl.text = @"Skip outro".ls;
                [self configureStepper:cell.stepperView forStart:NO];
            }
            return cell;
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
    else if (indexPath.section == kSyncPauseSection)
    {
        cell.accessoryView = nil;
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        cell.textLabel.text = @"Pause Synchronization".ls;
        control.on = self.feed.parked;
        control.tag = indexPath.row;
        [control addTarget:self action:@selector(togglePauseSynchronization:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    
    return cell;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kEpisodesSection:
            return @"Episodes".ls;
        case kTranscriptionSection:
            return ICAITranscriptionFeaturesEnabled()
                ? NSLocalizedString(@"Transkription und Kapitel", nil)
                : nil;
        case kAutoSkipSection:
            return @"Auto Skip".ls;
        case kAutoDownloadSettingsSection:
            return @"Auto-Download Content".ls;
        case kAppleWatchSection:
            return nil;
        case kAutoDeleteSettingsSection:
            return @"Auto-Delete Content".ls;
        case kPlaybackSection:
            return @"Playback".ls;
        default:
            break;
    }
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (section != kAppleWatchSection) {
        return nil;
    }

    UITableViewHeaderFooterView* header = [[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:nil];
    header.contentView.backgroundColor = tableView.backgroundColor;

    UIImageSymbolConfiguration* symbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:ICFontSize(13) weight:UIImageSymbolWeightSemibold];
    UIImageView* imageView = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"applewatch"] imageWithConfiguration:symbolConfiguration]];
    imageView.tintColor = [UIColor grayColor];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [header.contentView addSubview:imageView];

    UILabel* label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = [@"Apple Watch".ls uppercaseString];
    label.textColor = [UIColor grayColor];
    label.font = [UIFont systemFontOfSize:ICFontSize(13)];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [header.contentView addSubview:label];

    UILayoutGuide* margins = header.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [imageView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [imageView.centerYAnchor constraintEqualToAnchor:header.contentView.centerYAnchor constant:2],
        [imageView.widthAnchor constraintEqualToConstant:18],
        [imageView.heightAnchor constraintEqualToConstant:18],

        [label.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:7],
        [label.centerYAnchor constraintEqualToAnchor:imageView.centerYAnchor],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor]
    ]];

    return header;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    if (section == kTranscriptionSection && !ICAITranscriptionFeaturesEnabled()) {
        return CGFLOAT_MIN;
    }
    if (section == kAppleWatchSection) {
        return 44.f;
    }
    return UITableViewAutomaticDimension;
}

- (void) _transcriptionToggleChanged:(UISwitch*)sender
{
    if (!ICAITranscriptionFeaturesEnabled()) {
        return;
    }
    NSInteger row = sender.tag - 1000;
    NSString* value = sender.on ? @"yes" : @"no";
    switch (row) {
        case 0:
            [self.feed setString:value forKey:kFeedPropertyAutoTranscribe];
            break;
        case 1:
            if (sender.on && ![ICDownloadableModelStore selectedChapterModelCanGenerate]) {
                sender.on = NO;
                UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Automatische Analyse einrichten", nil)
                                                                               message:[ICDownloadableModelStore selectedChapterModelUnavailableReason]
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            [self.feed setString:value forKey:kFeedPropertyAutoChapters];
            break;
        case 2:
            [self.feed setString:value forKey:kFeedPropertyAutoSkipSponsors];
            break;
    }
    [DMANAGER save];
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
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.feed = self.feed;

        controller.key = FeedSortOrder;
        controller.valueType = kSettingTypeString;
        controller.title = @"Sort Order".ls;
        controller.values = [NSArray arrayWithObjects:@"NewerFirst", @"OlderFirst", nil];
        controller.titles = [NSArray arrayWithObjects:@"Newest First".ls, @"Oldest First".ls, nil];

        [self.navigationController pushViewController:controller animated:YES];
    }
    else if (indexPath.section == kRestoreDeletedSection)
    {
        if (self.restoreDeletedEpisodesInProgress) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
        if (self.archivedEpisodeCountError) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            [self _reloadArchivedEpisodeCount];
            return;
        }
        if (self.archivedEpisodeCount.unsignedIntegerValue == 0) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }

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
        popPresenter.permittedArrowDirections = 0;
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
        else if (indexPath.row == 3)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            controller.valueType = kSettingTypeInteger;
            controller.key = KeepNewestEpisodesCount;
            controller.title = @"Keep only newest".ls;
            controller.values = @[ @(0), @(1), @(2), @(3), @(4), @(5), @(6), @(7), @(8), @(9), @(10), @(11), @(12) ];
            controller.titles = @[ @"Off".ls, @"1 Episode".ls,
                [NSString stringWithFormat:@"%d Episodes".ls, 2],
                [NSString stringWithFormat:@"%d Episodes".ls, 3],
                [NSString stringWithFormat:@"%d Episodes".ls, 4],
                [NSString stringWithFormat:@"%d Episodes".ls, 5],
                [NSString stringWithFormat:@"%d Episodes".ls, 6],
                [NSString stringWithFormat:@"%d Episodes".ls, 7],
                [NSString stringWithFormat:@"%d Episodes".ls, 8],
                [NSString stringWithFormat:@"%d Episodes".ls, 9],
                [NSString stringWithFormat:@"%d Episodes".ls, 10],
                [NSString stringWithFormat:@"%d Episodes".ls, 11],
                [NSString stringWithFormat:@"%d Episodes".ls, 12] ];
            [self.navigationController pushViewController:controller animated:YES];
        }
    }
    else if (indexPath.section == kAppleWatchSection)
    {
        if (indexPath.row == 0)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            controller.valueType = kSettingTypeInteger;
            controller.key = AppleWatchSendLatestCount;
            controller.title = @"Neueste Episoden senden".ls;
            controller.values = @[ @(0), @(1), @(2), @(3), @(5), @(10) ];
            controller.titles = @[ @"Off".ls, @"1 Episode".ls,
                [NSString stringWithFormat:@"%d Episodes".ls, 2],
                [NSString stringWithFormat:@"%d Episodes".ls, 3],
                [NSString stringWithFormat:@"%d Episodes".ls, 5],
                [NSString stringWithFormat:@"%d Episodes".ls, 10] ];
            [self.navigationController pushViewController:controller animated:YES];
        }
    }
    else if (indexPath.section == kPlaybackSection)
    {
        NSInteger playbackRow = indexPath.row;

        if (playbackRow == 0)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            controller.valueType = kSettingTypeInteger;
            controller.key = ContinuousPlayFromFeed;
            controller.title = @"Continuous Playback".ls;
            controller.values = @[ @(ContinuousPlaybackOff), @(ContinuousPlaybackOn), @(ContinuousPlaybackReverse) ];
            controller.titles = @[ @"Off".ls, @"Newer to Older".ls, @"Older to Newer".ls ];
            [self.navigationController pushViewController:controller animated:YES];
        }
        else if (playbackRow == 1)
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
        else if (playbackRow == 2 || playbackRow == 3)
        {
            SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
            controller.feed = self.feed;
            controller.valueType = kSettingTypeInteger;
            controller.key = (playbackRow == 2 ) ? PlayerSkipBackPeriod : PlayerSkipForwardPeriod;
            controller.title = (playbackRow == 2 ) ? @"Skipping Back".ls : @"Skipping Forward".ls;
            controller.values = @[ @(5), @(10), @(20), @(30), @(60), @(120), @(300), @(600) ];
            controller.titles = @[@"5 Seconds".ls, @"10 Seconds".ls, @"20 Seconds".ls, @"30 Seconds".ls, @"1 Minute".ls, @"2 Minutes".ls, @"5 Minutes".ls, @"10 Minutes".ls];
            [self.navigationController pushViewController:controller animated:YES];
        }
    }
    else if (indexPath.section == kChapterEndSponsorSkipSection)
    {
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.feed = self.feed;
        controller.valueType = kSettingTypeInteger;
        if (indexPath.row == 0) {
            controller.key = PlayerNearChapterEndForwardSkipMode;
            controller.title = @"Sponsoren am Kapitelende überspringen".ls;
            controller.values = @[ @(0), @(1), @(5), @(10), @(15), @(20) ];
            controller.titles = @[ @"Aus".ls, @"Ein".ls, @"Ein + 5 Sekunden".ls, @"Ein + 10 Sekunden".ls, @"Ein + 15 Sekunden".ls, @"Ein + 20 Sekunden".ls ];
        }
        else {
            controller.key = PlayerNearChapterEndForwardSkipWindow;
            controller.title = @"Ende des Kapitels ab".ls;
            controller.values = @[ @(60), @(120), @(180), @(240), @(300) ];
            controller.titles = @[ @"1 Minute".ls, @"2 Minutes".ls, @"3 Minutes".ls, @"4 Minutes".ls, @"5 Minutes".ls ];
        }
        [self.navigationController pushViewController:controller animated:YES];
    }
    else if (indexPath.section == kAutoSkipSection) {
        if (indexPath.row == 0) {
            ChapterSkipListViewController *controller = [ChapterSkipListViewController controllerWithFeed:self.feed];
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

- (void)_reloadArchivedEpisodeCount
{
    if (self.restoreDeletedEpisodesInProgress) {
        return;
    }

    NSUInteger generation = ++self.archivedEpisodeCountGeneration;
    self.archivedEpisodeCount = nil;
    self.archivedEpisodeCountError = nil;
    NSManagedObjectID* feedObjectID = self.feed.objectID;
    NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
    if (!context) {
        self.archivedEpisodeCountError = [NSError errorWithDomain:@"FeedSettingsRestore"
                                                             code:1
                                                         userInfo:nil];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kRestoreDeletedSection]
                      withRowAnimation:UITableViewRowAnimationNone];
        return;
    }

    [context performBlock:^{
        NSError* countError = nil;
        CDFeed* feed = (CDFeed*)[context existingObjectWithID:feedObjectID error:&countError];
        NSUInteger archivedCount = NSNotFound;
        if (feed && !countError) {
            NSFetchRequest* countRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
            countRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ AND archived == %@", feed, @YES];
            archivedCount = [context countForFetchRequest:countRequest error:&countError];
        }
        if (archivedCount == NSNotFound && !countError) {
            countError = [NSError errorWithDomain:@"FeedSettingsRestore" code:2 userInfo:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.archivedEpisodeCountGeneration || self.restoreDeletedEpisodesInProgress) {
                return;
            }
            self.archivedEpisodeCount = countError ? nil : @(archivedCount);
            self.archivedEpisodeCountError = countError;
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kRestoreDeletedSection]
                          withRowAnimation:UITableViewRowAnimationNone];
        });
    }];
}

- (void)_presentRestoreDeletedEpisodesError
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Restore Failed".ls
                                                                   message:@"Some deleted episodes could not be restored. Please try again.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

-(void)restoreDeletedEpisodes
{
    if (self.restoreDeletedEpisodesInProgress) {
        return;
    }

    NSManagedObjectContext* context = [DMANAGER newBackgroundContext];
    if (!context) {
        [self _presentRestoreDeletedEpisodesError];
        return;
    }

    self.restoreDeletedEpisodesInProgress = YES;
    self.archivedEpisodeCountGeneration++;
    NSManagedObjectID* feedObjectID = self.feed.objectID;
    VDModalInfo* restoreInfo = [VDModalInfo modalInfoWithProgressLabel:@"Restoring…".ls];
    restoreInfo.progress = 0.0;
    [restoreInfo show];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block NSError* restoreError = nil;
        __block NSArray<NSManagedObjectID*>* episodeObjectIDs = nil;
        [context performBlockAndWait:^{
            CDFeed* feed = (CDFeed*)[context existingObjectWithID:feedObjectID error:&restoreError];
            if (!feed || restoreError) {
                return;
            }

            NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
            fetchRequest.predicate = [NSPredicate predicateWithFormat:@"feed == %@ AND archived == %@", feed, @YES];
            fetchRequest.resultType = NSManagedObjectIDResultType;
            fetchRequest.includesPropertyValues = NO;
            episodeObjectIDs = [context executeFetchRequest:fetchRequest error:&restoreError];
            if (!episodeObjectIDs || restoreError) {
                return;
            }

            NSUInteger totalCount = episodeObjectIDs.count;
            for (NSUInteger offset = 0; offset < totalCount && !restoreError; offset += ICRestoreArchivedEpisodeBatchSize) {
                @autoreleasepool {
                    NSRange batchRange = NSMakeRange(offset, MIN(ICRestoreArchivedEpisodeBatchSize, totalCount - offset));
                    NSArray<NSManagedObjectID*>* batchObjectIDs = [episodeObjectIDs subarrayWithRange:batchRange];
                    for (NSManagedObjectID* episodeObjectID in batchObjectIDs) {
                        CDEpisode* episode = (CDEpisode*)[context existingObjectWithID:episodeObjectID error:&restoreError];
                        if (!episode || restoreError) {
                            break;
                        }
                        episode.archived = NO;
                    }
                    if (restoreError) {
                        [context rollback];
                        break;
                    }

                    NSError* batchError = nil;
                    if (![context save:&batchError]) {
                        restoreError = batchError ?: [NSError errorWithDomain:@"FeedSettingsRestore" code:3 userInfo:nil];
                        [context rollback];
                        break;
                    }

                    double progress = totalCount == 0 ? 1.0 : (double)NSMaxRange(batchRange) / (double)totalCount;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [NSManagedObjectContext mergeChangesFromRemoteContextSave:@{ NSUpdatedObjectsKey: batchObjectIDs }
                                                                      intoContexts:@[DMANAGER.objectContext]];
                        [DMANAGER.objectContext processPendingChanges];
                        restoreInfo.progress = progress;
                    });
                    [context reset];
                    if (NSMaxRange(batchRange) < totalCount) {
                        [NSThread sleepForTimeInterval:0.01];
                    }
                }
            }
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [restoreInfo close];
            self.restoreDeletedEpisodesInProgress = NO;
            for (CDList* list in DMANAGER.lists) {
                if ([list isKindOfClass:[CDEpisodeList class]]) {
                    [(CDEpisodeList*)list invalidateCaches];
                }
            }
            [self _reloadArchivedEpisodeCount];
            if (restoreError) {
                ErrLog(@"Error restoring archived episodes: %@", restoreError);
                [self _presentRestoreDeletedEpisodesError];
            }
        });
    });
}


- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kResetSection) {
        return @"Resets subscription specific settings back to default settings.".ls;
    }
    else if (section == kSyncPauseSection) {
        return @"Temporarily stop updating this podcast when syncing subscriptions.".ls;
    }
    else if (section == kNewsModeSection) {
        return @"News Mode keeps only episodes from the newest publishing day as unplayed. Older episodes are marked as played and downloaded files are deleted automatically.".ls;
    }
    else if (section == kAppleWatchSection) {
        return @"Die Apple Watch lädt ausgewählte Audiodateien selbst über WLAN oder Mobilfunk.".ls;
    }
    else if (section == kAggregateUnavailableEpisodesSection) {
        return @"Enable to show all episodes regardless of whether or not they are still available on the publisher's server.".ls;
    }
    else if (section == kChapterEndSponsorSkipSection) {
        return @"Sponsor-Segmente, die am Ende eines Kapitels eingefügt sind, können mit einem Druck auf Vorwärts-Spulen übersprungen werden. Es wird direkt zum nächsten Kapitel gesprungen und je nach Einstellung zusätzlich einige Sekunden weiter.".ls;
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
    if (section == kTranscriptionSection && !ICAITranscriptionFeaturesEnabled()) {
        return CGFLOAT_MIN;
    }
    NSString* text = [self tableView:tableView titleForFooterInSection:section];
    return [self heightForFooterText:text];
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

- (void) togglePauseSynchronization:(UISwitch*)sender
{
    if (sender.tag == 0) {
        self.feed.parked = sender.on;
        [DMANAGER save];
    }

    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kResetSection] withRowAnimation:UITableViewRowAnimationNone];
}

- (void) toggleAppleWatchSettings:(UISwitch*)sender
{
    if (sender.tag == 1) {
        [self setBool:sender.on forKey:AppleWatchOnlyUnplayed];
        if ([self _saveAndSyncAppleWatchSettings]) {
            [self storeAppleWatchSettingsSnapshot];
        }
    }

    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kResetSection] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)storeAppleWatchSettingsSnapshot
{
    self.appleWatchSendLatestCountSnapshot = [self.feed integerForKey:AppleWatchSendLatestCount];
    self.appleWatchOnlyUnplayedSnapshot = [self.feed boolForKey:AppleWatchOnlyUnplayed];
    self.appleWatchSettingsSnapshotValid = YES;
}

- (void)syncAppleWatchSettingsIfNeeded
{
    NSInteger latestCount = [self.feed integerForKey:AppleWatchSendLatestCount];
    BOOL onlyUnplayed = [self.feed boolForKey:AppleWatchOnlyUnplayed];
    if (!self.appleWatchSettingsSnapshotValid) {
        [self storeAppleWatchSettingsSnapshot];
        return;
    }

    if (latestCount == self.appleWatchSendLatestCountSnapshot && onlyUnplayed == self.appleWatchOnlyUnplayedSnapshot) {
        return;
    }

    if ([self _saveAndSyncAppleWatchSettings]) {
        [self storeAppleWatchSettingsSnapshot];
    }
}

- (BOOL)_saveAndSyncAppleWatchSettings
{
    NSError* saveError = [DMANAGER saveReturningError];
    if (saveError) {
        [App showBackgroundErrorWithTitle:@"Unable to Save".ls
                                  message:@"The changes could not be saved on this device. Check the available storage and try again.".ls
                                 duration:8.0];
        return NO;
    }
    [[AppleWatchSyncManager sharedManager] rebuildAutomaticSelectionsAndSync];
    return YES;
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

- (void)configureStepper:(UIStepper *)stepper forStart:(BOOL)isStart {
    stepper.stepValue = 0.1;
    stepper.tag = isStart ? 1 : 2;
    
    double period = isStart ?
        [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_start_period", self.feed.uid]] :
        [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_end_period", self.feed.uid]];
    
    stepper.minimumValue = 0.0;
    stepper.maximumValue = 300.0;
    stepper.value = period;
    
    BOOL isNightMode = [ICAppearanceManager sharedManager].nightSettingMode;
    UIColor *colorTemp = isNightMode ? [UIColor whiteColor] : [UIColor blackColor];
    stepper.tintColor = colorTemp;
    UIImage *plusImage = [[UIImage systemImageNamed:@"plus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *minusImage = [[UIImage systemImageNamed:@"minus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    
    [stepper setIncrementImage:plusImage forState:UIControlStateNormal];
    [stepper setDecrementImage:minusImage forState:UIControlStateNormal];
    
    [stepper addTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
}

- (void)stepperValueChanged:(UIStepper *)sender {
    NSString *key = (sender.tag == 1) ?
        [NSString stringWithFormat:@"%@_auto_skip_start_period", self.feed.uid] :
        [NSString stringWithFormat:@"%@_auto_skip_end_period", self.feed.uid];

    double newValue = sender.value;

    if (self.feed) {
        if (newValue == [USER_DEFAULTS doubleForKey:key]) {
            [self.feed resetValueForKey:key];
        } else {
            [[self source] setDouble:newValue forKey:key];
        }
    }

    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:sender.tag inSection:kAutoSkipSection]] withRowAnimation:UITableViewRowAnimationNone];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSString *newText = [textField.text stringByReplacingCharactersInRange:range withString:string];
    
    if (newText.length == 0) {
        return YES;
    }
    
    // Validate decimal format
    NSString *decimalRegex = @"^-?\\d*\\.?\\d{0,1}$";
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", decimalRegex];
    if (![predicate evaluateWithObject:newText]) {
        return NO;
    }
    
    // Validate range (-300.0 to 300.0)
    double value = [newText doubleValue];
    if (value < 0.0 || value > 300.0) {
        return NO;
    }
    
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    SkipTimeCell *cell = (SkipTimeCell *)textField.superview.superview;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;
    
    NSString *key = (indexPath.row == 1) ?
        [NSString stringWithFormat:@"%@_auto_skip_start_period", self.feed.uid] :
        [NSString stringWithFormat:@"%@_auto_skip_end_period", self.feed.uid];
    
    double newValue = [textField.text doubleValue];
    newValue = MIN(MAX(newValue, 0.0), 300.0);
    
    if (self.feed) {
        if (newValue == [USER_DEFAULTS doubleForKey:key]) {
            [self.feed resetValueForKey:key];
        } else {
            [[self source] setDouble:newValue forKey:key];
        }
    }

    cell.stepperView.value = newValue;
    
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}



- (id) source
{
    return (self.feed) ? self.feed : USER_DEFAULTS;
}




@end
