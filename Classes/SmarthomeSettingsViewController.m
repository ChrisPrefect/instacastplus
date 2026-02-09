//
//  SmarthomeSettingsViewController.m
//  Instacast
//

#import "SmarthomeSettingsViewController.h"
#import "SmarthomeManager.h"
#import "UITableViewController+Settings.h"

typedef NS_ENUM(NSInteger, SmarthomeSettingsSections) {
    kSmarthomeEnableSection = 0,
    kSmarthomeConnectionSection,
    kSmarthomeOptionsSection,
    kSmarthomeStatusSection,
    kSmarthomeNumberOfSections,
};

enum {
    kTagHost = 100,
    kTagPort,
    kTagUsername,
    kTagPassword,
    kTagDeviceName,
};

@interface SmarthomeSettingsViewController () <UITextFieldDelegate>
@end

@implementation SmarthomeSettingsViewController

+ (SmarthomeSettingsViewController*) viewController
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
    self.navigationItem.title = @"Smart Home".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(connectionStateChanged)
                                                 name:SmarthomeManagerDidChangeConnectionStateNotification
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

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

- (void)connectionStateChanged
{
    SmarthomeManager *mgr = [SmarthomeManager sharedManager];

    // Update status row
    NSIndexPath *statusPath = [NSIndexPath indexPathForRow:0 inSection:kSmarthomeStatusSection];
    UITableViewCell *statusCell = [self.tableView cellForRowAtIndexPath:statusPath];
    if (statusCell) {
        statusCell.detailTextLabel.text = mgr.connectionStatusText ?: @"Disabled".ls;
    }

    // Update button row
    NSIndexPath *buttonPath = [NSIndexPath indexPathForRow:1 inSection:kSmarthomeStatusSection];
    UITableViewCell *buttonCell = [self.tableView cellForRowAtIndexPath:buttonPath];
    if (buttonCell) {
        buttonCell.textLabel.text = mgr.connected ? @"Disconnect".ls : @"Connect".ls;
    }
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kSmarthomeNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kSmarthomeEnableSection:
            return 1;
        case kSmarthomeConnectionSection:
            return 5; // host, port, user, pass, device name
        case kSmarthomeOptionsSection:
            return 2; // allow control + wifi only
        case kSmarthomeStatusSection:
            return 2; // status display + connect/disconnect button
        default:
            return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case kSmarthomeEnableSection:
        {
            UITableViewCell *cell = [self switchCell];
            UISwitch *control = (UISwitch*)cell.accessoryView;
            cell.textLabel.text = @"Enable MQTT".ls;
            control.on = [USER_DEFAULTS boolForKey:SmarthomeMQTTEnabled];
            control.tag = 0;
            [control addTarget:self action:@selector(toggleEnable:) forControlEvents:UIControlEventValueChanged];
            return cell;
        }

        case kSmarthomeConnectionSection:
        {
            switch (indexPath.row) {
                case 0:
                    return [self textFieldCellWithLabel:@"Server".ls
                                           placeholder:@"192.168.1.100"
                                                   tag:kTagHost
                                                  text:[USER_DEFAULTS stringForKey:SmarthomeMQTTHost]
                                              keyboard:UIKeyboardTypeURL
                                                secure:NO];
                case 1:
                    return [self textFieldCellWithLabel:@"Port".ls
                                           placeholder:@"1883"
                                                   tag:kTagPort
                                                  text:[self portString]
                                              keyboard:UIKeyboardTypeNumberPad
                                                secure:NO];
                case 2:
                    return [self textFieldCellWithLabel:@"Username".ls
                                           placeholder:@"Optional".ls
                                                   tag:kTagUsername
                                                  text:[USER_DEFAULTS stringForKey:SmarthomeMQTTUsername]
                                              keyboard:UIKeyboardTypeDefault
                                                secure:NO];
                case 3:
                    return [self textFieldCellWithLabel:@"Password".ls
                                           placeholder:@"Optional".ls
                                                   tag:kTagPassword
                                                  text:[USER_DEFAULTS stringForKey:SmarthomeMQTTPassword]
                                              keyboard:UIKeyboardTypeDefault
                                                secure:YES];
                case 4:
                    return [self textFieldCellWithLabel:@"Client Name".ls
                                           placeholder:[SmarthomeManager defaultDeviceName]
                                                   tag:kTagDeviceName
                                                  text:[USER_DEFAULTS stringForKey:SmarthomeDeviceName]
                                              keyboard:UIKeyboardTypeDefault
                                                secure:NO];
            }
            break;
        }

        case kSmarthomeOptionsSection:
        {
            if (indexPath.row == 0) {
                UITableViewCell *cell = [self switchCell];
                UISwitch *control = (UISwitch*)cell.accessoryView;
                cell.textLabel.text = @"Allow Remote Control".ls;
                control.on = [USER_DEFAULTS boolForKey:SmarthomeAllowControl];
                control.tag = 1;
                [control addTarget:self action:@selector(toggleAllowControl:) forControlEvents:UIControlEventValueChanged];
                return cell;
            } else {
                UITableViewCell *cell = [self switchCell];
                UISwitch *control = (UISwitch*)cell.accessoryView;
                cell.textLabel.text = @"WiFi Only".ls;
                control.on = [USER_DEFAULTS boolForKey:SmarthomeWiFiOnly];
                control.tag = 2;
                [control addTarget:self action:@selector(toggleWiFiOnly:) forControlEvents:UIControlEventValueChanged];
                return cell;
            }
        }

        case kSmarthomeStatusSection:
        {
            if (indexPath.row == 0) {
                UITableViewCell *cell = [self detailCell];
                SmarthomeManager *mgr = [SmarthomeManager sharedManager];
                cell.textLabel.text = @"Status".ls;
                cell.detailTextLabel.text = mgr.connectionStatusText ?: @"Disabled".ls;
                cell.accessoryType = UITableViewCellAccessoryNone;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                return cell;
            } else {
                UITableViewCell *cell = [self buttonCell];
                SmarthomeManager *mgr = [SmarthomeManager sharedManager];
                cell.textLabel.text = mgr.connected ? @"Disconnect".ls : @"Connect".ls;
                return cell;
            }
        }
    }

    return nil;
}

- (NSString*)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kSmarthomeConnectionSection:
            return @"MQTT Broker".ls;
        default:
            return nil;
    }
}

- (NSString*)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kSmarthomeConnectionSection) {
        NSString *deviceName = [USER_DEFAULTS stringForKey:SmarthomeDeviceName];
        if (deviceName && deviceName.length > 0) {
            return [NSString stringWithFormat:@"Topics: InstacastPlus/%@/...".ls, deviceName];
        } else {
            return @"Topics: InstacastPlus/...".ls;
        }
    }
    if (section == kSmarthomeEnableSection) {
        return @"Publishes playback status and device state to an MQTT broker for smart home integration.".ls;
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
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *footerView = (UITableViewHeaderFooterView *)view;
        footerView.textLabel.textColor = [UIColor grayColor];
    }
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == kSmarthomeStatusSection && indexPath.row == 1) {
        [self toggleConnection];
    }
}

#pragma mark - Actions

- (void)toggleEnable:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:SmarthomeMQTTEnabled];
    [USER_DEFAULTS synchronize];

    if (sender.on) {
        [[SmarthomeManager sharedManager] start];
    } else {
        [[SmarthomeManager sharedManager] stop];
    }
}

- (void)toggleAllowControl:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:SmarthomeAllowControl];
    [USER_DEFAULTS synchronize];

    // Reconnect to apply subscription changes
    SmarthomeManager *mgr = [SmarthomeManager sharedManager];
    if (mgr.connected) {
        [mgr stop];
        [mgr start];
    }
}

- (void)toggleWiFiOnly:(UISwitch*)sender
{
    [USER_DEFAULTS setBool:sender.on forKey:SmarthomeWiFiOnly];
    [USER_DEFAULTS synchronize];

    SmarthomeManager *mgr = [SmarthomeManager sharedManager];
    if (sender.on) {
        // If WiFi-only enabled and currently not on WiFi, disconnect
        [mgr checkWiFiAndReconnect];
    }
}

- (void)toggleConnection
{
    SmarthomeManager *mgr = [SmarthomeManager sharedManager];
    if (mgr.connected) {
        [mgr stop];
    } else {
        // Save any pending text field values
        [self.view endEditing:YES];

        [USER_DEFAULTS setBool:YES forKey:SmarthomeMQTTEnabled];
        [USER_DEFAULTS synchronize];
        [mgr start];

        // Update Enable switch if needed
        NSIndexPath *enablePath = [NSIndexPath indexPathForRow:0 inSection:kSmarthomeEnableSection];
        UITableViewCell *enableCell = [self.tableView cellForRowAtIndexPath:enablePath];
        if (enableCell) {
            UISwitch *sw = (UISwitch*)enableCell.accessoryView;
            sw.on = YES;
        }
    }
}

#pragma mark - Text Field Cells

- (UITableViewCell*)textFieldCellWithLabel:(NSString*)label
                               placeholder:(NSString*)placeholder
                                       tag:(NSInteger)tag
                                      text:(NSString*)text
                                  keyboard:(UIKeyboardType)keyboardType
                                    secure:(BOOL)secure
{
    NSString *cellId = [NSString stringWithFormat:@"TextFieldCell_%ld", (long)tag];
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:cellId];

    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
        textField.textAlignment = NSTextAlignmentRight;
        textField.tag = tag;
        textField.delegate = self;
        textField.returnKeyType = UIReturnKeyDone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        cell.accessoryView = textField;
    }

    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.textLabel.textColor = ICTextColor;
    cell.textLabel.text = label;

    UITextField *textField = (UITextField*)cell.accessoryView;
    textField.placeholder = placeholder;
    textField.text = text;
    textField.keyboardType = keyboardType;
    textField.secureTextEntry = secure;
    textField.textColor = ICMutedTextColor;

    return cell;
}

- (NSString*)portString
{
    NSInteger port = [USER_DEFAULTS integerForKey:SmarthomeMQTTPort];
    if (port == 0) port = 1883;
    return [NSString stringWithFormat:@"%ld", (long)port];
}

#pragma mark - UITextFieldDelegate

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    switch (textField.tag) {
        case kTagHost:
            [USER_DEFAULTS setObject:(textField.text ?: @"") forKey:SmarthomeMQTTHost];
            break;
        case kTagPort:
        {
            NSInteger port = [textField.text integerValue];
            if (port <= 0 || port > 65535) port = 1883;
            [USER_DEFAULTS setInteger:port forKey:SmarthomeMQTTPort];
            break;
        }
        case kTagUsername:
            [USER_DEFAULTS setObject:(textField.text ?: @"") forKey:SmarthomeMQTTUsername];
            break;
        case kTagPassword:
            [USER_DEFAULTS setObject:(textField.text ?: @"") forKey:SmarthomeMQTTPassword];
            break;
        case kTagDeviceName:
            [USER_DEFAULTS setObject:(textField.text ?: @"") forKey:SmarthomeDeviceName];
            break;
    }
    [USER_DEFAULTS synchronize];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
    // Live update topic preview when client name changes
    if (textField.tag == kTagDeviceName) {
        NSString *newText = [textField.text stringByReplacingCharactersInRange:range withString:string];
        [USER_DEFAULTS setObject:(newText ?: @"") forKey:SmarthomeDeviceName];
        [USER_DEFAULTS synchronize];
        // Update footer text directly without reloading section (which would steal first responder)
        UITableViewHeaderFooterView *footer = [self.tableView footerViewForSection:kSmarthomeConnectionSection];
        if (footer) {
            if (newText && newText.length > 0) {
                footer.textLabel.text = [NSString stringWithFormat:@"Topics: InstacastPlus/%@/...".ls, newText];
            } else {
                footer.textLabel.text = @"Topics: InstacastPlus/...".ls;
            }
            [footer setNeedsLayout];
        }
    }
    return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

@end
