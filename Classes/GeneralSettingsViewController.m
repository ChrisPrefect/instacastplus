//
//  GeneralSettingsViewController.m
//  Instacast
//
//  Created by Martin Hering on 21.06.13.
//
//

#import "GeneralSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "SettingsValuesTableViewController.h"
#import "PlaybackDefines.h"
#import "InstacastAppDelegate.h"
#import "ChapterImageCell.h"
#import "ChooseThemeColorCell.h"
#import <MessageUI/MessageUI.h>

typedef NS_ENUM(NSInteger, GeneralSettingsSections) {
    k3GSection = 0,
    kLanguage,
    kPlaybackSection,
    //kAutoSkipSection,
    kAutomaticTimer,
    kIntelligentSleep,
    kAppearanceThemeSection,
    kPlayerColor,
    kPInterfaceColor,
    kAppIcons,
    kAppIconSuggestion,
    kAppSection,
    kDebuggingSection,
    kNumberOfSections,
};

typedef NS_ENUM(NSInteger, CellularDataUsage) {
    kDontUseCellularData = 0,
    kDontDownloadOverCellular,
    kUseCellularData,
};

@interface GeneralSettingsViewController ()<UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate, MFMailComposeViewControllerDelegate, UITextFieldDelegate>
@end

@implementation GeneralSettingsViewController

+ (GeneralSettingsViewController*) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
        // Custom initialization
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];
    
    [self.tableView registerClass:[ChooseThemeColorCell class] forCellReuseIdentifier:@"ChooseThemeColorCell"];
    
    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"General".ls;
    self->appIconsArray = [NSArray arrayWithObjects: @"appicon1", @"appicon2", @"appicon3", @"appicon4", @"appicon5", @"appicon6", @"appicon7", nil];
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

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    [self _updateNavigationBarAppearance];

    [self.tableView reloadData];
}

- (void) _updateNavigationBarAppearance {
    id<ICAppearance> appearance = [ICAppearanceManager sharedManager].appearance;
    UINavigationBar *navBar = self.navigationController.navigationBar;

    UIImage *backgroundImage = [[ICAppearanceManager sharedManager] navigationBarBackgroundImage];

    UINavigationBarAppearance *navAppearance = [[UINavigationBarAppearance alloc] init];
    [navAppearance configureWithOpaqueBackground];
    navAppearance.backgroundImage = backgroundImage;
    navAppearance.shadowImage = [[UIImage alloc] init];
    navAppearance.shadowColor = nil;
    navAppearance.titleTextAttributes = @{ NSForegroundColorAttributeName : appearance.textColor };

    navBar.standardAppearance = navAppearance;
    navBar.scrollEdgeAppearance = navAppearance;
    navBar.compactAppearance = navAppearance;
}


- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
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
        case kLanguage:
            return 1;
        case kPlaybackSection:
            return 6;
//        case kAutoSkipSection:
//            return 2;
        case kAutomaticTimer:
            return 1;
        case kIntelligentSleep:
            return 3;
        case kAppearanceThemeSection:
            return 2;
        case kPlayerColor:
            if ([USER_DEFAULTS boolForKey:PlayerColorPerPodcastActive])
            {
                return 1;
            }
            else
            {
                return 2;
            }
        case kPInterfaceColor:
            if ([USER_DEFAULTS boolForKey:InterfaceThemeDefaultActive])
            {
                return 1;
            }
            else
            {
                return 2;
            }
        case kAppIcons:
            return 1;
        case kAppIconSuggestion:
            return 1;
        case kAppSection:
            return 2;
        case kDebuggingSection:
            return 1;
        default:
            break;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kAppIcons)
    {
        return 100;
    }
    return UITableViewAutomaticDimension;
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
    else if (indexPath.section == kLanguage)
    {
        NSDictionary* lngValues = @{ @1 : @"English".ls, @2 : @"German".ls};
        UITableViewCell* cell = [self detailCell];
        cell.textLabel.text = @"Language".ls;
        NSInteger period = [USER_DEFAULTS integerForKey:SelectedAppLanguage];
        cell.detailTextLabel.text = lngValues[@(period)];
        
        return cell;
    }
    else if (indexPath.section == kPlaybackSection)
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
                /*case 4:
                 {
                 UITableViewCell* cell = [self detailCell];
                 
                 cell.textLabel.text = @"Intelligent Sleep".ls;
                 
                 NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
                 
                 NSDictionary* sleepTimerValues = @{ @(PlaybackStopTimeNoValue) : @"Off".ls,
                 @(PlaybackStopTime5min) : @"5 Minutes".ls,
                 @(PlaybackStopTime10min) : @"10 Minutes".ls,
                 @(PlaybackStopTime15min) : @"15 Minutes".ls,
                 @(PlaybackStopTime20min) : @"20 Minutes".ls,
                 @(PlaybackStopTime30min) : @"30 Minutes".ls,
                 @(PlaybackStopTime60min) : @"60 Minutes".ls };
                 
                 cell.detailTextLabel.text = sleepTimerValues[@(sleepTimer)];
                 
                 return cell;
                 }*/
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
    /*else if (indexPath.section == kAutoSkipSection){
        NSDictionary* skippingValues = @{@0: @"0 Seconds".ls,@5 : @"5 Seconds".ls, @10 : @"10 Seconds".ls, @20 : @"20 Seconds".ls, @30 : @"30 Seconds".ls, @60 : @"1 Minute".ls, @120 : @"2 Minutes".ls, @300 : @"5 Minutes".ls, @600 : @"10 Minutes".ls };
        UITableViewCell* cell = [self detailCell];
        cell.tag = indexPath.row;
        if (indexPath.row == 0)
        {
            cell.textLabel.text = @"Skipping Start".ls;
            NSInteger period = [USER_DEFAULTS integerForKey:PlayerAutoSkipStartPeriod];
            cell.detailTextLabel.text =  [NSString stringWithFormat:@" %li Seconds", (long)period].ls;
            [self addStepperToCell:cell forStart:YES];
        } else {
            cell.textLabel.text =  @"Skipping End".ls;
            NSInteger period = [USER_DEFAULTS integerForKey:PlayerAutoSkipEndPeriod];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld Seconds", (long)period].ls;
            [self addStepperToCell:cell forStart:NO];
        }
        return cell;
    }*/
    else if (indexPath.section == kAutomaticTimer)
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
    else if (indexPath.section == kAppearanceThemeSection)
    {
        BOOL switchAutomatically = [ICAppearanceManager sharedManager].switchesNightModeAutomatically;
        
        switch (indexPath.row) {
            case 0:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;
                
                cell.textLabel.text = @"Enable".ls;
                
                control.on = [ICAppearanceManager sharedManager].nightSettingMode;
                [control addTarget:self action:@selector(toggleNightModeSettings:) forControlEvents:UIControlEventValueChanged];
                
                
                return cell;
            }
            case 1:
            {
                /*
                 Okay title will be "Reset intelligent sleep timer on:", and setting options will be "Sleep timer always active", "Screen Touch", "Volume Change", "Device Movement" right?
                 */
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;
                
                cell.textLabel.text = @"Switch Automatically".ls;
                control.on = switchAutomatically;
                [control addTarget:self action:@selector(toggleNightModeSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            default:
                break;
        }
        
    }
    else if (indexPath.section == kPlayerColor)
    {
        BOOL colorAsPerPodcast = [USER_DEFAULTS boolForKey:PlayerColorPerPodcastActive];
        switch (indexPath.row) {
            case 0:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;
                
                cell.textLabel.text = @"Automatic As Per Podcast".ls;
                cell.textLabel.numberOfLines = 0;
                control.on = colorAsPerPodcast;
                [control addTarget:self action:@selector(togglePlayerColorSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            case 1:
            {
                ChooseThemeColorCell *cell = (ChooseThemeColorCell*)[tableView dequeueReusableCellWithIdentifier:@"ChooseThemeColorCell" forIndexPath:indexPath];
                cell.textLabel.numberOfLines = 0;
                
                if (@available(iOS 14.0, *)) {
                    cell.textLabel.text = @"Choose Custom".ls;
                    [cell.disclosureView setHidden:FALSE];
                    [cell.colorView setHidden:FALSE];
                    [cell.textField setHidden:TRUE];
                    [cell.tfView setHidden:TRUE];
                    cell.disclosureView.tintColor = [UIColor colorWithRed:199/255.f green:199/255.f blue:204/255.f alpha:1.f];
                    [cell.colorView setHidden:YES];
                    if ([USER_DEFAULTS objectForKey:PlayerThemeColorCode])
                    {
                        [cell.colorView setHidden:NO];
                        cell.colorView.clipsToBounds = true;
                        cell.colorView.layer.cornerRadius = 5;
                        NSData *colorData = [[NSUserDefaults standardUserDefaults] objectForKey:PlayerThemeColorCode];
                        UIColor *themeColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
                        cell.colorView.backgroundColor = themeColor;
                    }
                }
                else
                {
                    cell.textLabel.text = @"Choose Custom (Hex)".ls;
                    [cell.disclosureView setHidden:TRUE];
                    [cell.colorView setHidden:TRUE];
                    [cell.textField setHidden:FALSE];
                    [cell.tfView setHidden:FALSE];
                    cell.textField.tag = 555;
                    cell.textField.delegate = self;
                    cell.textField.text = @"";
                    if ([USER_DEFAULTS objectForKey:PlayerThemeColorHexCode])
                    {
                        cell.textField.text = [NSString stringWithFormat:@"%@", [USER_DEFAULTS stringForKey:PlayerThemeColorHexCode]];
                    }
                }
                return cell;
            }
            default:
                break;
        }
        
    }
    else if (indexPath.section == kPInterfaceColor)
    {
        BOOL interfaceDefalutTheme = [USER_DEFAULTS boolForKey:InterfaceThemeDefaultActive];
        switch (indexPath.row) {
            case 0:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;
                
                cell.textLabel.text = @"Use Default".ls;
                cell.textLabel.numberOfLines = 0;
                control.on = interfaceDefalutTheme;
                [control addTarget:self action:@selector(toggleInterfaceColorSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            case 1:
            {
                ChooseThemeColorCell *cell = (ChooseThemeColorCell*)[tableView dequeueReusableCellWithIdentifier:@"ChooseThemeColorCell" forIndexPath:indexPath];
                cell.textLabel.numberOfLines = 0;
                                
                if (@available(iOS 14.0, *)) {
                    cell.textLabel.text = @"Choose Custom".ls;
                    [cell.disclosureView setHidden:FALSE];
                    [cell.colorView setHidden:FALSE];
                    [cell.textField setHidden:TRUE];
                    [cell.tfView setHidden:TRUE];
                    cell.disclosureView.tintColor = [UIColor colorWithRed:199/255.f green:199/255.f blue:204/255.f alpha:1.f];
                    [cell.colorView setHidden:YES];
                    if ([USER_DEFAULTS objectForKey:InterfaceThemeColorCode])
                    {
                        [cell.colorView setHidden:NO];
                        cell.colorView.clipsToBounds = true;
                        cell.colorView.layer.cornerRadius = 5;
                        NSData *colorData = [[NSUserDefaults standardUserDefaults] objectForKey:InterfaceThemeColorCode];
                        UIColor *themeColor = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
                        cell.colorView.backgroundColor = themeColor;
                    }
                }
                else
                {
                    cell.textLabel.text = @"Choose Custom (Hex)".ls;
                    [cell.disclosureView setHidden:TRUE];
                    [cell.colorView setHidden:TRUE];
                    [cell.textField setHidden:FALSE];
                    [cell.tfView setHidden:FALSE];
                    cell.textField.tag = 777;
                    cell.textField.delegate = self;
                    cell.textField.text = @"";
                    if ([USER_DEFAULTS objectForKey:InterfaceThemeColorHexCode])
                    {
                        cell.textField.text = [NSString stringWithFormat:@"%@", [USER_DEFAULTS stringForKey:InterfaceThemeColorHexCode]];
                    }
                }
                
                return cell;
            }
            default:
                break;
        }
        
    }
    else if (indexPath.section == kAppIcons)
    {
        static NSString *AppIConCellIdentifier = @"AppIconCell";
        UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:AppIConCellIdentifier];
        if (cell == nil) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:AppIConCellIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        cell.backgroundColor = ICGroupCellBackgroundColor;
        
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
        layout.itemSize = CGSizeMake(80, 80);
        layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
        [layout setMinimumInteritemSpacing:10];
        [layout setMinimumLineSpacing:10];
        UICollectionView* appIconsCollection = [[UICollectionView alloc] initWithFrame:CGRectMake(20, 10, self.view.bounds.size.width - 40, 80) collectionViewLayout:layout];
        [appIconsCollection registerClass:[ChapterImageCell class] forCellWithReuseIdentifier: @"chapter_cell"];
        [appIconsCollection registerNib:[UINib nibWithNibName:@"ChapterImageCell" bundle:nil]  forCellWithReuseIdentifier:@"chapter_cell"];
        appIconsCollection.backgroundColor = [UIColor clearColor];
        appIconsCollection.showsHorizontalScrollIndicator = YES;
        appIconsCollection.showsVerticalScrollIndicator = NO;
        
        for (UIView *subview in [cell.contentView subviews])
        {
            if ([subview isKindOfClass:[UICollectionView class]])
            {
                [subview removeFromSuperview];
            }
        }
        
        [cell.contentView addSubview:appIconsCollection];
        appIconsCollection.delegate = self;
        appIconsCollection.dataSource = self;
        [appIconsCollection reloadData];
        
        return cell;
    }
    else if (indexPath.section == kAppIconSuggestion)
    {
        UITableViewCell* cell = [self buttonCell];
        cell.detailTextLabel.text = nil;
        cell.textLabel.text = @"Suggest App Icon".ls;
        if ([ICAppearanceManager sharedManager].nightSettingMode) {
            cell.backgroundColor = [UIColor colorWithRed:17/255.0 green:17/255.0 blue:17/255.0 alpha:1.0];
        } else {
            cell.backgroundColor = [UIColor colorWithRed:226/255.0 green:226/255.0 blue:226/255.0 alpha:1.0];
        }
        return cell;
    }
    else if (indexPath.section == kAppSection)
    {
        switch (indexPath.row) {
            case 0:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;
                
                cell.textLabel.text = @"Application Badge".ls;
                control.on = [USER_DEFAULTS boolForKey:ShowApplicationBadgeForUnseen];
                [control addTarget:self action:@selector(toggleAppSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            case 1:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;
                
                cell.textLabel.text = @"Interface Sounds".ls;
                control.on = [USER_DEFAULTS boolForKey:UISoundEnabled];
                [control addTarget:self action:@selector(toggleAppSettings:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
            default:
                break;
        }
    }
    
    else if (indexPath.section == kDebuggingSection)
    {
        UITableViewCell* cell = [self detailCell];
        
        cell.textLabel.text = @"Send Reports".ls;
        
        NSInteger value = [USER_DEFAULTS integerForKey:AllowSendingDiagnostics];
        NSDictionary* values = @{ @2 : @"Automatically".ls, @1 : @"Ask Before Sending".ls, @0 : @"Don't Send".ls };
        cell.detailTextLabel.text = values[@(value)];
        
        return cell;
        
    }
    
    return nil;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField.tag == 555)
    {
        NSLog(@"Player Color: %@", textField.text);
        [textField resignFirstResponder];
        if (textField.text.length == 6 || textField.text.length == 7)
        {
            UIColor *customColor = [UIColor colorWithHexString:textField.text];
            NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:customColor requiringSecureCoding:NO error:nil];
            [USER_DEFAULTS setObject:colorData forKey:PlayerThemeColorCode];
            [USER_DEFAULTS setObject:textField.text forKey:PlayerThemeColorHexCode];
            [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];
            [USER_DEFAULTS synchronize];

            [self.tableView reloadData];
        }
    }
    else if (textField.tag == 777)
    {
        NSLog(@"Interface Color: %@", textField.text);
        [textField resignFirstResponder];
        if (textField.text.length == 6 || textField.text.length == 7)
        {
            UIColor *customColor = [UIColor colorWithHexString:textField.text];
            NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:customColor requiringSecureCoding:NO error:nil];
            [USER_DEFAULTS setObject:colorData forKey:InterfaceThemeColorCode];
            [USER_DEFAULTS setObject:textField.text forKey:InterfaceThemeColorHexCode];
            [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];
            [USER_DEFAULTS synchronize];
            
            [[ICAppearanceManager sharedManager] updateThemeTintColor];
            [[ICAppearanceManager sharedManager] setNightMode:[ICAppearanceManager sharedManager].nightSettingMode];
            [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];

            [self.tableView reloadData];
        }
    }
    return YES;
}

+ (UIColor *)colorWithHexString:(NSString *)hexString {
    // Remove # if it exists
    NSString *cleanString = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    
    if ([cleanString length] == 6) { // Ensure it's a valid hex code
        unsigned int rgbValue = 0;
        NSScanner *scanner = [NSScanner scannerWithString:cleanString];
        [scanner scanHexInt:&rgbValue];
        
        CGFloat red   = ((rgbValue >> 16) & 0xFF) / 255.0;
        CGFloat green = ((rgbValue >> 8) & 0xFF) / 255.0;
        CGFloat blue  = (rgbValue & 0xFF) / 255.0;
        
        return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
    }
    return [UIColor orangeColor]; // Return black if invalid hex
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case k3GSection:
            return @"Cellular Data (EDGE, 3G, LTE)".ls;
        case kLanguage:
            return @"";
        case kPlaybackSection:
            return @"Playback".ls;
//        case kAutoSkipSection:
//            return @"Auto Skip".ls;
        case kAutomaticTimer:
            return @"";
        case kIntelligentSleep:
            return @"Reset intelligent sleep timer on:".ls;
        case kAppearanceThemeSection:
            return @"Dark mode:".ls;
        case kPlayerColor:
            return @"Player Color".ls;
        case kPInterfaceColor:
            return @"Interface Color".ls;
        case kAppIcons:
            return @"App Icons".ls;
        case kAppIconSuggestion:
            return @"";
        case kAppSection:
            return @"Miscellaneous".ls;
        case kDebuggingSection:
            return @"Crash & Failure Diagnostics".ls;
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
        case k3GSection:
        {
            return @"You can either disable the usage of cellular data completely (which might decrease the user experience when not on WiFi), enable cellular usage for everything except downloading episodes, or enable cellular usage for everything including downloading episodes. Disabling cellular data completely will also prevent iOS's cellular data alert from popping up.".ls;
        }
        case kDebuggingSection:
        {
            NSString* footerText = @"Help InstacastPlus improve its products and services by automatically sending reports upon application crash or failure. Reports do not include any personal or private data.".ls;
            //footerText = [footerText stringByAppendingFormat:@"\n\nCloud ID: %@", [NSBundle deviceId]];
            return footerText;
        }
        /*case kAppearanceThemeSection:
        {
            return @"Use system setting".ls;//@"Night mode can be enabled automatically at sunset, and disabled automatically at sunrise. To calculate the times of sunset and sunrise, Instacast asks for your permission to gather location data. Location data is only ever gathered when you open the app – never in the background.".ls;
        }*/
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
            return @"Intelligent Sleep Timer resets itself to the set timeout if he detects that you are not yet sleeping.".ls;
        }
        case kAppIconSuggestion:
        {
            return @"We’re looking for creative suggestions for our app icon. If you have ideas, feel free to share your design as a .psd file, or send a link to your proposed app icon.".ls;
        }
        default:
            break;
    }
    return nil;
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController didSelectColor:(UIColor *)color continuously:(BOOL)continuously  API_AVAILABLE(ios(14.0)){
    if (self->isPlayerColorSelected)
    {
        self->selectedPlayerColor = color;
    }
    else
    {
        self->selectedThemeColor = color;
    }
}

-(void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController
API_AVAILABLE(ios(14.0)){
    NSLog(@"COLOR PICKER DID FINISH");
    //DEVD TO DO
    if (self->isPlayerColorSelected)
    {
        if (self->selectedPlayerColor)
        {
            //[USER_DEFAULTS setBool:true forKey:InterfaceThemeColorActive];
            NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:self->selectedPlayerColor requiringSecureCoding:NO error:nil];
            [USER_DEFAULTS setObject:colorData forKey:PlayerThemeColorCode];
            [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];
            [USER_DEFAULTS synchronize];

            [self.tableView reloadData];
        }
    }
    else
    {
        if (self->selectedThemeColor)
        {
            //[USER_DEFAULTS setBool:true forKey:InterfaceThemeColorActive];
            NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:self->selectedThemeColor requiringSecureCoding:NO error:nil];
            [USER_DEFAULTS setObject:colorData forKey:InterfaceThemeColorCode];
            [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];
            [USER_DEFAULTS synchronize];

            [[ICAppearanceManager sharedManager] updateThemeTintColor];
            [[ICAppearanceManager sharedManager] setNightMode:[ICAppearanceManager sharedManager].nightSettingMode];
            [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];

            [self.tableView reloadData];
        }
    }
}


#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    
    if (indexPath.section == k3GSection)
    {
        switch (indexPath.row) {
            case 0:
            {
                [USER_DEFAULTS setBool:NO forKey:EnableStreamingOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableCachingImagesOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableRefreshingOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableSyncingOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableCachingOver3G];
                break;
            }
            case 1:
                [USER_DEFAULTS setBool:YES forKey:EnableStreamingOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableCachingImagesOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableRefreshingOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableSyncingOver3G];
                [USER_DEFAULTS setBool:NO forKey:EnableCachingOver3G];
                break;
            case 2:
                [USER_DEFAULTS setBool:YES forKey:EnableStreamingOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableCachingImagesOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableRefreshingOver3G];
                [USER_DEFAULTS setBool:YES forKey:EnableSyncingOver3G];
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
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
    
    else if (indexPath.section == kLanguage)
    {
        /*
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.valueType = kSettingTypeInteger;
        controller.key = SelectedAppLanguage;
        controller.title = @"Language".ls;
        controller.values = @[ @1, @2];
        controller.titles = @[ @"English".ls, @"German".ls];
        [self.navigationController pushViewController:controller animated:YES];
         */
        NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        [[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
    }
    
    else if (indexPath.section == kPlaybackSection)
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
                /*case 4:
                 {
                 SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
                 controller.valueType = kSettingTypeInteger;
                 controller.key = DefaultIntelligentSleepTimer;
                 controller.title = @"Intelligent Sleep".ls;
                 controller.values = @[ @(PlaybackStopTimeNoValue), @(PlaybackStopTime5min), @(PlaybackStopTime10min), @(PlaybackStopTime15min), @(PlaybackStopTime20min), @(PlaybackStopTime30min), @(PlaybackStopTime60min)];
                 controller.titles = @[ @"Off".ls, @"5 Minutes".ls, @"10 Minutes".ls, @"15 Minutes".ls, @"20 Minutes".ls, @"30 Minutes".ls, @"60 Minutes".ls];
                 [self.navigationController pushViewController:controller animated:YES];
                 break;
                 }*/
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
    
//    else if (indexPath.section == kAutoSkipSection) {
//        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
//        controller.valueType = kSettingTypeInteger;
//        controller.key = (indexPath.row == 0) ? PlayerAutoSkipStartPeriod : PlayerAutoSkipEndPeriod;
//        controller.title = (indexPath.row == 0) ? @"Skipping Start".ls : @"Skipping End".ls;
//        controller.values = @[@0, @5, @10, @20, @30, @60, @120, @300, @600 ];
//        controller.titles = @[@"0 Seconds".ls, @"5 Seconds".ls, @"10 Seconds".ls, @"20 Seconds".ls, @"30 Seconds".ls, @"1 Minute".ls, @"2 Minutes".ls, @"5 Minutes".ls, @"10 Minutes".ls];
//        [self.navigationController pushViewController:controller animated:YES];
  //  }
    
    else if (indexPath.section == kPlayerColor) {
        if (indexPath.row == 1) {
            if (@available(iOS 14.0, *)) {
                self->isPlayerColorSelected = true;
                [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
                UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
                picker.delegate = self;
                [self presentViewController:picker animated:YES completion:nil];
            } else {
                // Fallback on earlier versions
            }
        }
    }
    
    else if (indexPath.section == kPInterfaceColor) {
        if (indexPath.row == 1) {
            if (@available(iOS 14.0, *)) {
                self->isPlayerColorSelected = false;
                [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
                UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
                picker.delegate = self;
                [self presentViewController:picker animated:YES completion:nil];
            } else {
                // Fallback on earlier versions
            }
        }
    }
    
    else if (indexPath.section == kDebuggingSection)
    {
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.valueType = kSettingTypeInteger;
        controller.key = AllowSendingDiagnostics;
        controller.title = @"Send Reports".ls;
        controller.values = @[ @2, @1, @0 ];
        controller.titles = @[ @"Automatically".ls, @"Ask Before Sending".ls, @"Don't Send".ls ];
        [self.navigationController pushViewController:controller animated:YES];
    }
    else if (indexPath.section == kAppIconSuggestion)
    {
        [self suggestAppIconsAction:nil];
    }
}

- (void) suggestAppIconsAction:(id)sender
{
    if ([MFMailComposeViewController canSendMail]) {
        MFMailComposeViewController *mailComposer = [[MFMailComposeViewController alloc] init];
        mailComposer.mailComposeDelegate = self;
        
        // Configure the email
        [mailComposer setSubject:@"App Icon Suggestion"];
        [mailComposer setToRecipients:@[@"info@instacast.ch"]];
        [mailComposer setMessageBody:@"Please attach your .psd file or share the app icon link below:" isHTML:NO];
        
        // Present the mail compose view controller
        [self presentViewController:mailComposer animated:YES completion:nil];
    } else {
        // Show an alert if email is not set up on the device
        [self presentAlertControllerWithTitle:@"Email not configured.".ls message:@"Please configure email on this device.".ls button:@"OK".ls animated:YES completion:NULL];
    }
}

- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error
{
    [self dismissViewControllerAnimated:YES completion:^{
    }];
    
    if (error) {
        [self presentError:error];
    }
}

- (void) toggle3GSettings:(UISwitch*)sender
{
    switch (sender.tag) {
        case 0:
        {
            [USER_DEFAULTS setBool:sender.on forKey:EnableStreamingOver3G];
            [USER_DEFAULTS setBool:sender.on forKey:EnableCachingImagesOver3G];
            [USER_DEFAULTS setBool:sender.on forKey:EnableRefreshingOver3G];
            [USER_DEFAULTS setBool:sender.on forKey:EnableSyncingOver3G];
            break;
        }
        case 1:
        {
            [USER_DEFAULTS setBool:sender.on forKey:EnableCachingOver3G];
            break;
        }
        default:
            break;
    }
}

- (void) togglePlayerSettings:(UISwitch*)sender
{
    if (sender.tag == 0) {
        [USER_DEFAULTS setBool:sender.on forKey:PlayerReplayAfterPause];
    }
    else if (sender.tag == 5) {
        [USER_DEFAULTS setBool:sender.on forKey:DisableAutoLock];
    }
}

- (void) toggleAppSettings:(UISwitch*)sender
{
    if (sender.tag == 0) {
        [USER_DEFAULTS setBool:sender.on forKey:ShowApplicationBadgeForUnseen];
    }
    else if (sender.tag == 1) {
        [USER_DEFAULTS setBool:sender.on forKey:UISoundEnabled];
    }
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
                //[USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
                [USER_DEFAULTS synchronize];
            }
        }
    }
    [self.tableView reloadData];
}

- (void) toggleNightModeSettings:(UISwitch*)sender
{
    UISwitch* theSwitch = sender;
    
    switch (sender.tag) {
        case 0:
        {
            [self perform:^(id sender) {
                [ICAppearanceManager sharedManager].nightMode = theSwitch.on;
            } afterDelay:0.3];
        }
            break;
        case 1:
        {
            [ICAppearanceManager sharedManager].switchesNightModeAutomatically = sender.on;
            
            /*[self perform:^(id sender) {
                if (![[ICAppearanceManager sharedManager] switchNightModeAutomaticallyNow])
                {
                    [self presentAlertControllerWithTitle:@"Location Services denied".ls
                                                  message:@"To switch to night mode automatically, please go to iOS's Settings app and allow Instacast to use Location Services.".ls
                                                   button:@"OK".ls
                                                 animated:YES
                                               completion:NULL];
                }
                
                if ([ICAppearanceManager sharedManager].switchesNightModeAutomatically != theSwitch.on) {
                    theSwitch.on = [ICAppearanceManager sharedManager].switchesNightModeAutomatically;
                }
                
            } afterDelay:0.3];*/
            [self perform:^(id sender) {
                if ([ICAppearanceManager sharedManager].switchesNightModeAutomatically) {
                    // Get system appearance mode
                    UIUserInterfaceStyle style = self.traitCollection.userInterfaceStyle;
                    
                    if (style == UIUserInterfaceStyleDark) {
                        [ICAppearanceManager sharedManager].nightMode = YES;
                    } else {
                        [ICAppearanceManager sharedManager].nightMode = NO;
                    }
                }
                
                // Ensure the switch reflects the correct state
                if ([ICAppearanceManager sharedManager].switchesNightModeAutomatically != theSwitch.on) {
                    theSwitch.on = [ICAppearanceManager sharedManager].switchesNightModeAutomatically;
                }
            } afterDelay:0.3];
        }
            break;
        default:
            break;
    }
    
}

- (void) togglePlayerColorSettings:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:PlayerColorPerPodcastActive];
    [USER_DEFAULTS synchronize];
    [self.tableView reloadData];
}

- (void) toggleInterfaceColorSettings:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:InterfaceThemeDefaultActive];
    [USER_DEFAULTS synchronize];
    [[ICAppearanceManager sharedManager] updateThemeTintColor];
    [[ICAppearanceManager sharedManager] setNightMode:[ICAppearanceManager sharedManager].nightSettingMode];
    [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];

    [self.tableView reloadData];
}


- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return self->appIconsArray.count;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return CGSizeMake(80, 80);
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    ChapterImageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"chapter_cell" forIndexPath:indexPath];
    cell.chapterImageView.image = [UIImage imageNamed: self->appIconsArray[indexPath.item]];
    cell.chapterImageView.layer.cornerRadius = 5;
    cell.chapterImageView.layer.masksToBounds = true;
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    NSString* appIconName = [NSString stringWithFormat:@"AppIcon-%ld", (long)(indexPath.item + 1)];
    NSLog(@"AppIconName===%@",appIconName);
    [[UIApplication sharedApplication] setAlternateIconName:appIconName completionHandler:^(NSError * _Nullable error) {
        if (error != nil){
            NSLog(@"Error===%@",error.localizedDescription);
        } else {
            NSLog(@"Success! - APP ICON UPDATED");
        }
    }];
}

#pragma mark - Stepper Handlers
/*
- (void)addStepperToCell:(UITableViewCell *)cell forStart:(BOOL)isStart {
    UIStepper *stepper = [[UIStepper alloc] init];
    stepper.stepValue = 5;
    NSInteger period = isStart ?  [USER_DEFAULTS integerForKey:PlayerAutoSkipStartPeriod] : [USER_DEFAULTS integerForKey:PlayerAutoSkipEndPeriod];
    stepper.tag = isStart ? 0 : 1;
    stepper.value = period;
    stepper.maximumValue = 5*60;
    [stepper addTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = stepper;
}


- (void)stepperValueChanged:(UIStepper *)sender {
    NSString *key = @"";
    if (sender.tag == 0) {
        key = PlayerAutoSkipStartPeriod;
    } else {
        key = PlayerAutoSkipEndPeriod;
    }
  
    [USER_DEFAULTS setInteger:sender.value forKey:key];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:sender.tag inSection:kAutoSkipSection]] withRowAnimation:UITableViewRowAnimationNone];
}*/


@end
