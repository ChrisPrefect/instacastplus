//
//  AppearanceSettingsViewController.m
//  Instacast
//

#import "AppearanceSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "SettingsValuesTableViewController.h"
#import "InstacastAppDelegate.h"
#import "ChapterImageCell.h"
#import "ChooseThemeColorCell.h"
#import "WidgetDataExporter.h"
#import "InstacastPlus-Swift.h"
#import <MessageUI/MessageUI.h>

typedef NS_ENUM(NSInteger, AppearanceSettingsSections) {
    kLanguage = 0,
    kAppearanceThemeSection,
    kPlayerColor,
    kPInterfaceColor,
    kWidgetColor,
    kAppIcons,
    kAppIconSuggestion,
    kInterfaceSoundsSection,
    kExternalBrowserSection,
    kNumberOfSections,
};

@interface AppearanceSettingsViewController ()<UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate, MFMailComposeViewControllerDelegate, UITextFieldDelegate, UIPopoverPresentationControllerDelegate>
@end

@implementation AppearanceSettingsViewController

+ (AppearanceSettingsViewController*) viewController
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

    [self.tableView registerClass:[ChooseThemeColorCell class] forCellReuseIdentifier:@"ChooseThemeColorCell"];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Appearance".ls;
    self->appIconsArray = [NSArray arrayWithObjects: @"appicon1", @"appicon2", @"appicon3", @"appicon4", @"appicon5", @"appicon6", @"appicon7", nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    // SettingsValuesTableViewController sets the UserDefault directly,
    // so trigger appearance update when returning from Appearance mode selection.
    [[ICAppearanceManager sharedManager] updateAppearance];

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
        case kLanguage:
            return 1;
        case kAppearanceThemeSection:
            return [ICAppearanceManager sharedManager].nightSettingMode ? 2 : 1;
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
        case kWidgetColor:
            if ([USER_DEFAULTS boolForKey:WidgetThemeDefaultActive])
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
        case kInterfaceSoundsSection:
            return 1;
        case kExternalBrowserSection:
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
    if (indexPath.section == kLanguage)
    {
        NSDictionary* lngValues = @{ @1 : @"English".ls, @2 : @"German".ls};
        UITableViewCell* cell = [self detailCell];
        cell.textLabel.text = @"Language".ls;
        NSInteger period = [USER_DEFAULTS integerForKey:SelectedAppLanguage];
        cell.detailTextLabel.text = lngValues[@(period)];

        return cell;
    }
    else if (indexPath.section == kAppearanceThemeSection)
    {
        if (indexPath.row == 0) {
            UITableViewCell* cell = [self detailCell];
            cell.textLabel.text = @"Appearance".ls;

            NSDictionary* values = @{
                @(ICAppearanceModeAutomatic): @"Automatic".ls,
                @(ICAppearanceModeLight): @"Light".ls,
                @(ICAppearanceModeDark): @"Dark".ls
            };
            cell.detailTextLabel.text = values[@([ICAppearanceManager sharedManager].appearanceMode)];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

            return cell;
        } else {
            UITableViewCell* cell = [self switchCell];
            UISwitch* control = (UISwitch*)cell.accessoryView;
            cell.textLabel.text = @"Pure Black Background".ls;
            control.on = [USER_DEFAULTS boolForKey:kDefaultDarkModePureBlack];
            [control addTarget:self action:@selector(togglePureBlack:) forControlEvents:UIControlEventValueChanged];
            return cell;
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
    else if (indexPath.section == kWidgetColor)
    {
        BOOL widgetDefault = [USER_DEFAULTS boolForKey:WidgetThemeDefaultActive];
        switch (indexPath.row) {
            case 0:
            {
                UITableViewCell* cell = [self switchCell];
                UISwitch* control = (UISwitch*)cell.accessoryView;
                control.tag = indexPath.row;

                cell.textLabel.text = @"Use Interface Color".ls;
                cell.textLabel.numberOfLines = 0;
                control.on = widgetDefault;
                [control addTarget:self action:@selector(toggleWidgetColorSettings:) forControlEvents:UIControlEventValueChanged];
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
                    if ([USER_DEFAULTS objectForKey:WidgetThemeColorCode])
                    {
                        [cell.colorView setHidden:NO];
                        cell.colorView.clipsToBounds = true;
                        cell.colorView.layer.cornerRadius = 5;
                        NSData *colorData = [[NSUserDefaults standardUserDefaults] objectForKey:WidgetThemeColorCode];
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
                    cell.textField.tag = 888;
                    cell.textField.delegate = self;
                    cell.textField.text = @"";
                    if ([USER_DEFAULTS objectForKey:WidgetThemeColorHexCode])
                    {
                        cell.textField.text = [NSString stringWithFormat:@"%@", [USER_DEFAULTS stringForKey:WidgetThemeColorHexCode]];
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
        [layout setMinimumInteritemSpacing:5];
        [layout setMinimumLineSpacing:5];
        UICollectionView* appIconsCollection = [[UICollectionView alloc] initWithFrame:CGRectMake(15, 10, self.view.bounds.size.width - 30, 80) collectionViewLayout:layout];
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
    else if (indexPath.section == kInterfaceSoundsSection)
    {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        control.tag = 0;

        cell.textLabel.text = @"Interface Sounds".ls;
        control.on = [USER_DEFAULTS boolForKey:UISoundEnabled];
        [control addTarget:self action:@selector(toggleInterfaceSounds:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
    else if (indexPath.section == kExternalBrowserSection)
    {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        control.tag = 0;

        cell.textLabel.text = @"Open Links in External Browser".ls;
        control.on = [USER_DEFAULTS boolForKey:OpenLinksInExternalBrowser];
        [control addTarget:self action:@selector(toggleExternalBrowser:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    return nil;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField.tag == 555)
    {
        [textField resignFirstResponder];
        if (textField.text.length == 6 || textField.text.length == 7)
        {
            UIColor *customColor = [UIColor colorWithHexString:textField.text];
            NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:customColor requiringSecureCoding:NO error:nil];
            [USER_DEFAULTS setObject:colorData forKey:PlayerThemeColorCode];
            [USER_DEFAULTS setObject:textField.text forKey:PlayerThemeColorHexCode];
            [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];

            [self.tableView reloadData];
        }
    }
    else if (textField.tag == 777)
    {
        [textField resignFirstResponder];
        if (textField.text.length == 6 || textField.text.length == 7)
        {
            UIColor *customColor = [UIColor colorWithHexString:textField.text];
            NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:customColor requiringSecureCoding:NO error:nil];
            [USER_DEFAULTS setObject:colorData forKey:InterfaceThemeColorCode];
            [USER_DEFAULTS setObject:textField.text forKey:InterfaceThemeColorHexCode];
            [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];

            [[ICAppearanceManager sharedManager] updateThemeTintColor];
            [[ICAppearanceManager sharedManager] updateAppearance];
            [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];

            [self.tableView reloadData];
        }
    }
    else if (textField.tag == 888)
    {
        [textField resignFirstResponder];
        if (textField.text.length == 6 || textField.text.length == 7)
        {
            UIColor *customColor = [UIColor colorWithHexString:textField.text];
            NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:customColor requiringSecureCoding:NO error:nil];
            [USER_DEFAULTS setObject:colorData forKey:WidgetThemeColorCode];
            [USER_DEFAULTS setObject:textField.text forKey:WidgetThemeColorHexCode];
            [USER_DEFAULTS setBool:false forKey:WidgetThemeDefaultActive];

            [[WidgetDataExporter sharedExporter] exportSettingsSnapshot];
            [WidgetKitHelper reloadAllTimelines];

            [self.tableView reloadData];
        }
    }
    return YES;
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kLanguage:
            return @"";
        case kAppearanceThemeSection:
            return @"";
        case kPlayerColor:
            return @"Player Color".ls;
        case kPInterfaceColor:
            return @"Interface Color".ls;
        case kWidgetColor:
            return @"Widget Color".ls;
        case kAppIcons:
            return @"App Icon".ls;
        case kAppIconSuggestion:
            return @"";
        case kInterfaceSoundsSection:
            return @"";
        case kExternalBrowserSection:
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
}

- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section)
    {
        case kAppIconSuggestion:
        {
            return @"We're looking for creative suggestions for our app icon. If you have ideas, feel free to share your design as a .psd file, or send a link to your proposed app icon.".ls;
        }
        default:
            break;
    }
    return nil;
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController didSelectColor:(UIColor *)color continuously:(BOOL)continuously  API_AVAILABLE(ios(14.0)){
    switch (self->colorPickerTarget) {
        case ColorPickerTargetPlayer:
            self->selectedPlayerColor = color;
            break;
        case ColorPickerTargetInterface:
            self->selectedThemeColor = color;
            break;
        case ColorPickerTargetWidget:
            self->selectedWidgetColor = color;
            break;
    }
}

-(void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController
API_AVAILABLE(ios(14.0)){
    switch (self->colorPickerTarget) {
        case ColorPickerTargetPlayer:
        {
            if (self->selectedPlayerColor)
            {
                NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:self->selectedPlayerColor requiringSecureCoding:NO error:nil];
                [USER_DEFAULTS setObject:colorData forKey:PlayerThemeColorCode];
                [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];
                [self.tableView reloadData];
            }
            break;
        }
        case ColorPickerTargetInterface:
        {
            if (self->selectedThemeColor)
            {
                NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:self->selectedThemeColor requiringSecureCoding:NO error:nil];
                [USER_DEFAULTS setObject:colorData forKey:InterfaceThemeColorCode];
                [USER_DEFAULTS setBool:false forKey:InterfaceThemeDefaultActive];

                [[ICAppearanceManager sharedManager] updateThemeTintColor];
                [[ICAppearanceManager sharedManager] updateAppearance];
                [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];
                [self.tableView reloadData];
            }
            break;
        }
        case ColorPickerTargetWidget:
        {
            if (self->selectedWidgetColor)
            {
                NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:self->selectedWidgetColor requiringSecureCoding:NO error:nil];
                [USER_DEFAULTS setObject:colorData forKey:WidgetThemeColorCode];
                [USER_DEFAULTS setBool:false forKey:WidgetThemeDefaultActive];

                [[WidgetDataExporter sharedExporter] exportSettingsSnapshot];
                [WidgetKitHelper reloadAllTimelines];
                [self.tableView reloadData];
            }
            break;
        }
    }
}


#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kLanguage)
    {
        NSURL *settingsURL = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        [[UIApplication sharedApplication] openURL:settingsURL options:@{} completionHandler:nil];
    }

    else if (indexPath.section == kPlayerColor) {
        if (indexPath.row == 1) {
            if (@available(iOS 14.0, *)) {
                self->colorPickerTarget = ColorPickerTargetPlayer;
                [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
                UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
                picker.delegate = self;
                [self presentViewController:picker animated:YES completion:nil];
            }
        }
    }

    else if (indexPath.section == kPInterfaceColor) {
        if (indexPath.row == 1) {
            if (@available(iOS 14.0, *)) {
                self->colorPickerTarget = ColorPickerTargetInterface;
                [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
                UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
                picker.delegate = self;
                [self presentViewController:picker animated:YES completion:nil];
            }
        }
    }

    else if (indexPath.section == kWidgetColor) {
        if (indexPath.row == 1) {
            if (@available(iOS 14.0, *)) {
                self->colorPickerTarget = ColorPickerTargetWidget;
                [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
                UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
                picker.delegate = self;
                [self presentViewController:picker animated:YES completion:nil];
            }
        }
    }

    else if (indexPath.section == kAppIconSuggestion)
    {
        [self suggestAppIconsAction:nil];
    }

    else if (indexPath.section == kAppearanceThemeSection && indexPath.row == 0)
    {
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.valueType = kSettingTypeInteger;
        controller.key = kDefaultAppearanceMode;
        controller.title = @"Appearance".ls;
        controller.values = @[ @(ICAppearanceModeAutomatic), @(ICAppearanceModeLight), @(ICAppearanceModeDark) ];
        controller.titles = @[ @"Automatic".ls, @"Light".ls, @"Dark".ls ];
        controller.footerText = @"Automatic switches between Light and Dark based on your device settings.".ls;
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller
{
    return UIModalPresentationNone;
}

- (void) suggestAppIconsAction:(id)sender
{
    if ([MFMailComposeViewController canSendMail]) {
        MFMailComposeViewController *mailComposer = [[MFMailComposeViewController alloc] init];
        mailComposer.mailComposeDelegate = self;

        [mailComposer setSubject:@"App Icon Suggestion"];
        [mailComposer setToRecipients:@[@"info@instacast.ch"]];
        [mailComposer setMessageBody:@"Please attach your .psd file or share the app icon link below:" isHTML:NO];

        [self presentViewController:mailComposer animated:YES completion:nil];
    } else {
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

#pragma mark - Toggle actions

- (void) togglePlayerColorSettings:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:PlayerColorPerPodcastActive];
    [self.tableView reloadData];
}

- (void) toggleInterfaceColorSettings:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:InterfaceThemeDefaultActive];
    [[ICAppearanceManager sharedManager] updateThemeTintColor];
    [[ICAppearanceManager sharedManager] updateAppearance];
    [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];

    [self.tableView reloadData];
}

- (void) toggleWidgetColorSettings:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:WidgetThemeDefaultActive];
    [[WidgetDataExporter sharedExporter] exportSettingsSnapshot];
    [WidgetKitHelper reloadAllTimelines];
    [self.tableView reloadData];
}

- (void) toggleInterfaceSounds:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:UISoundEnabled];
}

- (void) togglePureBlack:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:kDefaultDarkModePureBlack];
    [[ICAppearanceManager sharedManager] updateAppearance];
}

- (void) toggleExternalBrowser:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:OpenLinksInExternalBrowser];
}

#pragma mark - Collection View (App Icons)

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

- (NSInteger)_currentAlternateIconIndex
{
    NSString *currentIconName = [[UIApplication sharedApplication] alternateIconName];
    if (currentIconName) {
        NSString *numberPart = [currentIconName stringByReplacingOccurrencesOfString:@"AppIcon-" withString:@""];
        return [numberPart integerValue] - 1;
    }
    return -1;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    ChapterImageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"chapter_cell" forIndexPath:indexPath];
    cell.chapterImageView.image = [UIImage imageNamed: self->appIconsArray[indexPath.item]];
    cell.chapterImageView.layer.cornerRadius = 5;
    cell.chapterImageView.layer.masksToBounds = true;

    BOOL isSelected = (indexPath.item == [self _currentAlternateIconIndex]);
    if (isSelected) {
        cell.chapterImageView.layer.borderColor = [[ICAppearanceManager sharedManager] appearance].tintColor.CGColor;
        cell.chapterImageView.layer.borderWidth = 3.0;
    } else {
        cell.chapterImageView.layer.borderWidth = 0;
    }

    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    NSString* appIconName = [NSString stringWithFormat:@"AppIcon-%ld", (long)(indexPath.item + 1)];
    [[UIApplication sharedApplication] setAlternateIconName:appIconName completionHandler:^(NSError * _Nullable error) {
        if (error != nil) {
            ErrLog(@"setAlternateIconName error: %@", error.localizedDescription);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [collectionView reloadData];
        });
    }];
}

@end
