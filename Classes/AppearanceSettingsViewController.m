//
//  AppearanceSettingsViewController.m
//  Instacast
//

#import "AppearanceSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "SettingsValuesTableViewController.h"
#import "Language.h"
#import "InstacastAppDelegate.h"
#import "ChapterImageCell.h"
#import "ChooseThemeColorCell.h"
#import "WidgetDataExporter.h"
#import "InstacastPlus-Swift.h"
#import <MessageUI/MessageUI.h>

typedef NS_ENUM(NSInteger, AppearanceSettingsSections) {
    kLanguage = 0,
    kEpisodesSection,
    kAppearanceThemeSection,
    kFontSizeSection,
    kTranscriptHighlightSection,
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
    self->appIconsArray = @[ @"appiconCore", @"appiconStandard", @"appicon1", @"appicon4", @"appicon2", @"appicon3", @"appicon5", @"appicon6", @"appicon7", @"appiconClassicAlt1", @"appiconClassicAlt2", @"appiconClassicAlt3" ];
    self->appIconNamesArray = @[ @"InstacastPlus_Icon_Core", @"", @"AppIcon-1", @"AppIcon-4", @"AppIcon-2", @"AppIcon-3", @"AppIcon-5", @"AppIcon-6", @"AppIcon-7", @"InstacastPlus_Icon_Classic_Alt1", @"InstacastPlus_Icon_Classic_Alt2", @"InstacastPlus_Icon_Classic_Alt3" ];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    // Update title in case language changed
    self.navigationItem.title = @"Appearance".ls;

    // SettingsValuesTableViewController sets the UserDefault directly,
    // so trigger appearance update when returning from Appearance mode selection.
    [[ICAppearanceManager sharedManager] updateAppearance];

    // Force notification for font size changes (appearance may not have changed)
    [[NSNotificationCenter defaultCenter] postNotificationName:ICAppearanceManagerDidUpdateAppearanceNotification
                                                        object:[ICAppearanceManager sharedManager]];

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

- (UIColor*)_storedColorForHexKey:(NSString*)hexKey legacyArchiveKey:(NSString*)legacyArchiveKey
{
    return [UIColor ic_colorFromDefaults:USER_DEFAULTS hexKey:hexKey legacyArchiveKey:legacyArchiveKey];
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
        case kEpisodesSection:
            return 3;
        case kAppearanceThemeSection:
            return [ICAppearanceManager sharedManager].nightSettingMode ? 2 : 1;
        case kFontSizeSection:
            return 1;
        case kTranscriptHighlightSection:
            return 1;
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
            return 2;
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
        NSDictionary* lngValues = @{ @1 : @"English", @2 : @"Deutsch"};
        UITableViewCell* cell = [self detailCell];
        cell.textLabel.text = @"Language".ls;
        NSInteger selectedLanguage = [USER_DEFAULTS integerForKey:SelectedAppLanguage];
        cell.detailTextLabel.text = lngValues[@(selectedLanguage)];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    else if (indexPath.section == kEpisodesSection)
    {
        UITableViewCell* cell = [self detailCell];
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Tap on Episode".ls;

            NSInteger tapAction = [USER_DEFAULTS integerForKey:TapOnEpisodeAction];
            NSDictionary* tapActionTitles = @{
                @(ICTapOnEpisodeActionPlay): @"Play Episode Action".ls,
                @(ICTapOnEpisodeActionShowNotes): @"Show Notes".ls,
                @(ICTapOnEpisodeActionOpenContextMenu): @"Open Long-Press Menu".ls,
            };
            cell.detailTextLabel.text = tapActionTitles[@(tapAction)] ?: @"Play Episode Action".ls;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Swipe Right".ls;
            NSInteger action = [USER_DEFAULTS integerForKey:EpisodeSwipeRightAction];
            cell.detailTextLabel.text = [self _titleForSwipeAction:action];
        } else {
            cell.textLabel.text = @"Swipe Left".ls;
            NSInteger action = [USER_DEFAULTS integerForKey:EpisodeSwipeLeftAction];
            cell.detailTextLabel.text = [self _titleForSwipeAction:action];
        }
        return cell;
    }
    else if (indexPath.section == kAppearanceThemeSection)
    {
        if (indexPath.row == 0) {
            UITableViewCell* cell = [self detailCell];
            cell.textLabel.text = @"Appearance Mode".ls;

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
    else if (indexPath.section == kFontSizeSection)
    {
        UITableViewCell* cell = [self detailCell];
        cell.textLabel.text = @"Font Size".ls;
        NSDictionary* fontSizeNames = @{
            @0: @"Normal".ls,
            @1: @"Larger".ls,
            @2: @"Even Larger".ls,
            @3: @"Largest".ls
        };
        NSInteger level = [USER_DEFAULTS integerForKey:kDefaultFontSizeLarger];
        cell.detailTextLabel.text = fontSizeNames[@(level)] ?: @"Normal".ls;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    else if (indexPath.section == kTranscriptHighlightSection)
    {
        UITableViewCell* cell = [self detailCell];
        cell.textLabel.text = @"Transcript Highlight".ls;
        NSDictionary* styleNames = @{
            @(ICTranscriptHighlightBold): @"Bold and Colored".ls,
            @(ICTranscriptHighlightBackground): @"Colored with Background".ls
        };
        NSInteger style = [USER_DEFAULTS integerForKey:kDefaultTranscriptHighlightStyle];
        cell.detailTextLabel.text = styleNames[@(style)] ?: @"Bold and Colored".ls;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
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

                cell.textLabel.text = @"Choose Custom".ls;
                [cell.disclosureView setHidden:FALSE];
                [cell.colorView setHidden:FALSE];
                [cell.textField setHidden:TRUE];
                [cell.tfView setHidden:TRUE];
                cell.disclosureView.tintColor = [UIColor colorWithRed:199/255.f green:199/255.f blue:204/255.f alpha:1.f];
                [cell.colorView setHidden:YES];
                UIColor* themeColor = [self _storedColorForHexKey:PlayerThemeColorHexCode legacyArchiveKey:PlayerThemeColorCode];
                if (themeColor) {
                    [cell.colorView setHidden:NO];
                    cell.colorView.clipsToBounds = true;
                    cell.colorView.layer.cornerRadius = 5;
                    cell.colorView.backgroundColor = themeColor;
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

                cell.textLabel.text = @"Choose Custom".ls;
                [cell.disclosureView setHidden:FALSE];
                [cell.colorView setHidden:FALSE];
                [cell.textField setHidden:TRUE];
                [cell.tfView setHidden:TRUE];
                cell.disclosureView.tintColor = [UIColor colorWithRed:199/255.f green:199/255.f blue:204/255.f alpha:1.f];
                [cell.colorView setHidden:YES];
                UIColor* themeColor = [self _storedColorForHexKey:InterfaceThemeColorHexCode legacyArchiveKey:InterfaceThemeColorCode];
                if (themeColor) {
                    [cell.colorView setHidden:NO];
                    cell.colorView.clipsToBounds = true;
                    cell.colorView.layer.cornerRadius = 5;
                    cell.colorView.backgroundColor = themeColor;
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

                cell.textLabel.text = @"Choose Custom".ls;
                [cell.disclosureView setHidden:FALSE];
                [cell.colorView setHidden:FALSE];
                [cell.textField setHidden:TRUE];
                [cell.tfView setHidden:TRUE];
                cell.disclosureView.tintColor = [UIColor colorWithRed:199/255.f green:199/255.f blue:204/255.f alpha:1.f];
                [cell.colorView setHidden:YES];
                UIColor* themeColor = [self _storedColorForHexKey:WidgetThemeColorHexCode legacyArchiveKey:WidgetThemeColorCode];
                if (themeColor) {
                    [cell.colorView setHidden:NO];
                    cell.colorView.clipsToBounds = true;
                    cell.colorView.layer.cornerRadius = 5;
                    cell.colorView.backgroundColor = themeColor;
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

        if (indexPath.row == 0) {
            cell.textLabel.text = @"Interface Sounds".ls;
            control.on = [USER_DEFAULTS boolForKey:UISoundEnabled];
            [control addTarget:self action:@selector(toggleInterfaceSounds:) forControlEvents:UIControlEventValueChanged];
        }
        else {
            cell.textLabel.text = @"Haptic Feedback".ls;
            control.on = [USER_DEFAULTS boolForKey:UIHapticsEnabled];
            [control addTarget:self action:@selector(toggleHapticFeedback:) forControlEvents:UIControlEventValueChanged];
        }
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
            if ([UIColor ic_setColorHexString:textField.text
                                    inDefaults:USER_DEFAULTS
                                        hexKey:PlayerThemeColorHexCode
                              legacyArchiveKey:PlayerThemeColorCode]) {
                [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];
                [self.tableView reloadData];
            }
        }
    }
    else if (textField.tag == 777)
    {
        [textField resignFirstResponder];
        if (textField.text.length == 6 || textField.text.length == 7)
        {
            if ([UIColor ic_setColorHexString:textField.text
                                    inDefaults:USER_DEFAULTS
                                        hexKey:InterfaceThemeColorHexCode
                              legacyArchiveKey:InterfaceThemeColorCode]) {
                [USER_DEFAULTS setBool:false forKey:InterfaceThemeDefaultActive];
                [[ICAppearanceManager sharedManager] updateThemeTintColor];
                [[ICAppearanceManager sharedManager] updateAppearance];
                [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];
                [self.tableView reloadData];
            }
        }
    }
    else if (textField.tag == 888)
    {
        [textField resignFirstResponder];
        if (textField.text.length == 6 || textField.text.length == 7)
        {
            if ([UIColor ic_setColorHexString:textField.text
                                    inDefaults:USER_DEFAULTS
                                        hexKey:WidgetThemeColorHexCode
                              legacyArchiveKey:WidgetThemeColorCode]) {
                [USER_DEFAULTS setBool:false forKey:WidgetThemeDefaultActive];
                [[WidgetDataExporter sharedExporter] exportSettingsSnapshot];
                [WidgetKitHelper reloadAllTimelines];
                [self.tableView reloadData];
            }
        }
    }
    return YES;
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kLanguage:
            return @"";
        case kEpisodesSection:
            return @"Episodes".ls;
        case kAppearanceThemeSection:
            return @"";
        case kFontSizeSection:
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
                [UIColor ic_setColor:self->selectedPlayerColor
                          inDefaults:USER_DEFAULTS
                              hexKey:PlayerThemeColorHexCode
                    legacyArchiveKey:PlayerThemeColorCode];
                [USER_DEFAULTS setBool:false forKey:PlayerColorPerPodcastActive];
                [self.tableView reloadData];
            }
            break;
        }
        case ColorPickerTargetInterface:
        {
            if (self->selectedThemeColor)
            {
                [UIColor ic_setColor:self->selectedThemeColor
                          inDefaults:USER_DEFAULTS
                              hexKey:InterfaceThemeColorHexCode
                    legacyArchiveKey:InterfaceThemeColorCode];
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
                [UIColor ic_setColor:self->selectedWidgetColor
                          inDefaults:USER_DEFAULTS
                              hexKey:WidgetThemeColorHexCode
                    legacyArchiveKey:WidgetThemeColorCode];
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
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.valueType = kSettingTypeInteger;
        controller.key = SelectedAppLanguage;
        controller.title = @"Language".ls;
        controller.values = @[ @1, @2 ];
        controller.titles = @[ @"English", @"Deutsch" ];
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }

    else if (indexPath.section == kEpisodesSection)
    {
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.valueType = kSettingTypeInteger;
        if (indexPath.row == 0) {
            controller.key = TapOnEpisodeAction;
            controller.title = @"Tap on Episode".ls;
            controller.values = @[ @(ICTapOnEpisodeActionPlay), @(ICTapOnEpisodeActionShowNotes), @(ICTapOnEpisodeActionOpenContextMenu) ];
            controller.titles = @[ @"Play Episode Action".ls, @"Show Notes".ls, @"Open Long-Press Menu".ls ];
        } else {
            controller.key = (indexPath.row == 1) ? EpisodeSwipeRightAction : EpisodeSwipeLeftAction;
            controller.title = (indexPath.row == 1) ? @"Swipe Right".ls : @"Swipe Left".ls;
            controller.values = @[
                @(ICEpisodeSwipeActionTogglePlayed),
                @(ICEpisodeSwipeActionToggleFavorite),
                @(ICEpisodeSwipeActionDownload),
                @(ICEpisodeSwipeActionAddToPlayNext),
                @(ICEpisodeSwipeActionDelete),
                @(ICEpisodeSwipeActionEpisodeInfo),
                @(ICEpisodeSwipeActionTranscribe),
                @(ICEpisodeSwipeActionSendToAppleWatch)
            ];
            controller.titles = @[
                @"Mark as Played".ls,
                @"Mark as Favorite".ls,
                @"Download".ls,
                @"Add to Play Next".ls,
                @"Delete Episode from List".ls,
                @"Show Show Notes".ls,
                @"Transcribe".ls,
                @"An Apple Watch senden".ls
            ];
            UIImageSymbolConfiguration* symbolConfig = [UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleMedium];
            controller.images = @[
                [UIImage systemImageNamed:@"circle" withConfiguration:symbolConfig],
                [UIImage systemImageNamed:@"star" withConfiguration:symbolConfig],
                [UIImage systemImageNamed:@"square.and.arrow.down" withConfiguration:symbolConfig],
                [UIImage systemImageNamed:@"list.bullet.indent" withConfiguration:symbolConfig],
                [UIImage systemImageNamed:@"trash" withConfiguration:symbolConfig],
                [UIImage systemImageNamed:@"info.circle" withConfiguration:symbolConfig],
                [UIImage systemImageNamed:@"captions.bubble" withConfiguration:symbolConfig],
                [UIImage systemImageNamed:@"applewatch" withConfiguration:symbolConfig],
            ];
            controller.footerText = @"Swipe Action Toggle Info".ls;
        }
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }

    else if (indexPath.section == kPlayerColor) {
        if (indexPath.row == 1) {
            self->colorPickerTarget = ColorPickerTargetPlayer;
            [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
            UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
            self->selectedPlayerColor = [self _storedColorForHexKey:PlayerThemeColorHexCode legacyArchiveKey:PlayerThemeColorCode];
            if (self->selectedPlayerColor) {
                picker.selectedColor = self->selectedPlayerColor;
            }
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        }
    }

    else if (indexPath.section == kPInterfaceColor) {
        if (indexPath.row == 1) {
            self->colorPickerTarget = ColorPickerTargetInterface;
            [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
            UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
            self->selectedThemeColor = [self _storedColorForHexKey:InterfaceThemeColorHexCode legacyArchiveKey:InterfaceThemeColorCode];
            if (self->selectedThemeColor) {
                picker.selectedColor = self->selectedThemeColor;
            }
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        }
    }

    else if (indexPath.section == kWidgetColor) {
        if (indexPath.row == 1) {
            self->colorPickerTarget = ColorPickerTargetWidget;
            [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
            UIColorPickerViewController* picker = [[UIColorPickerViewController alloc] init];
            self->selectedWidgetColor = [self _storedColorForHexKey:WidgetThemeColorHexCode legacyArchiveKey:WidgetThemeColorCode];
            if (self->selectedWidgetColor) {
                picker.selectedColor = self->selectedWidgetColor;
            }
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
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
        controller.title = @"Appearance Mode".ls;
        controller.values = @[ @(ICAppearanceModeAutomatic), @(ICAppearanceModeLight), @(ICAppearanceModeDark) ];
        controller.titles = @[ @"Automatic".ls, @"Light".ls, @"Dark".ls ];
        controller.footerText = @"Automatic switches between Light and Dark based on your device settings.".ls;
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }

    else if (indexPath.section == kFontSizeSection)
    {
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.valueType = kSettingTypeInteger;
        controller.key = kDefaultFontSizeLarger;
        controller.title = @"Font Size".ls;
        controller.values = @[ @0, @1, @2, @3 ];
        controller.titles = @[ @"Normal".ls, @"Larger".ls, @"Even Larger".ls, @"Largest".ls ];
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }

    else if (indexPath.section == kTranscriptHighlightSection)
    {
        SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
        controller.valueType = kSettingTypeInteger;
        controller.key = kDefaultTranscriptHighlightStyle;
        controller.title = @"Transcript Highlight".ls;
        controller.values = @[ @(ICTranscriptHighlightBold), @(ICTranscriptHighlightBackground) ];
        controller.titles = @[ @"Bold and Colored".ls, @"Colored with Background".ls ];
        controller.footerTexts = @[
            @"The active line is displayed bold and in the accent color.".ls,
            @"The active line is displayed in the accent color with a subtle background. This avoids text reflow caused by the bold font weight.".ls
        ];
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

#pragma mark - Helpers

- (NSString*) _titleForSwipeAction:(NSInteger)action
{
    switch (action) {
        case ICEpisodeSwipeActionTogglePlayed: return @"Mark as Played".ls;
        case ICEpisodeSwipeActionToggleFavorite: return @"Mark as Favorite".ls;
        case ICEpisodeSwipeActionDownload: return @"Download".ls;
        case ICEpisodeSwipeActionAddToPlayNext: return @"Add to Play Next".ls;
        case ICEpisodeSwipeActionDelete: return @"Delete Episode from List".ls;
        case ICEpisodeSwipeActionEpisodeInfo: return @"Show Show Notes".ls;
        case ICEpisodeSwipeActionTranscribe: return @"Transcribe".ls;
        case ICEpisodeSwipeActionSendToAppleWatch: return @"An Apple Watch senden".ls;
        default: return @"Mark as Played".ls;
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

- (void) toggleHapticFeedback:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:UIHapticsEnabled];
    if (sender.on) {
        // confirm re-enable with a sample tap
        PlayHapticFeedback(ICHapticFeedbackMedium);
    }
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
        NSUInteger iconIndex = [self->appIconNamesArray indexOfObject:currentIconName];
        if (iconIndex == NSNotFound) {
            return -1;
        }
        return (NSInteger)iconIndex;
    }
    return 0;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    ChapterImageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"chapter_cell" forIndexPath:indexPath];
    cell.chapterImageView.image = [UIImage imageNamed: self->appIconsArray[indexPath.item]];
    cell.chapterImageView.layer.cornerRadius = 16;
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
    NSString* selectedIconName = self->appIconNamesArray[indexPath.item];
    NSString* appIconName = (selectedIconName.length > 0) ? selectedIconName : nil;
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
