//
//  OptionsViewController.m
//  Instacast
//
//  Created by Martin Hering on 07.11.11.
//  Copyright (c) 2011 Vemedio. All rights reserved.
//

#import <MessageUI/MessageUI.h>

#import "OptionsViewController.h"
#import "CDPlaylist.h"

#import "SubscriptionManager.h"
#import "UtilityFunctions.h"
#import "XPFF.h"
#import "FeedOptionsViewController.h"
#import "NotificationSettingsViewController.h"
#import "AppearanceSettingsViewController.h"
#import "PlaybackSettingsViewController.h"
#import "SleepTimerSettingsViewController.h"
#import "DataSettingsViewController.h"
#import "ImportExportSettingsViewController.h"
#import "ICiCloudSyncSettingsViewController.h"
#import "SmarthomeSettingsViewController.h"
#import "TranscriptionSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "InstacastAppDelegate.h"
#import "DonationViewController.h"
#import "InstacastPlus-Swift.h"
#include <sys/sysctl.h>


@interface OptionsViewController () <MFMailComposeViewControllerDelegate>
@property (nonatomic) BOOL sendingCrashLogMail;
@end


enum {
    kOptionsSectionMain,
    kNumberOfSections
};

enum {
    kRowAppearance = 0,
    kRowPlayback,
    kRowSleepTimer,
    kRowData,
    kRowSubscriptions,
    kRowNotifications,
    kRowiCloudSync,
    kRowImportExport,
    kRowTranscription,
    kRowSmartHome,
    kRowEmailFeedback,
    kRowDonateToDeveloper,
    kRowCrashLogs,
    kNumberOfRows
};


@implementation OptionsViewController


+ (OptionsViewController*) optionsViewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

+ (BOOL)iCloudSyncSettingsAvailable
{
    if (@available(iOS 17.0, *)) {
        return [ICiCloudSyncManager isAvailable];
    }
    return NO;
}

+ (BOOL)crashLogMailAvailable
{
    return [ICDiagnosticLogger isTestFlightBuild];
}

- (NSInteger)settingsRowForIndexPath:(NSIndexPath*)indexPath
{
    NSInteger row = indexPath.row;
    if (![OptionsViewController iCloudSyncSettingsAvailable] && row >= kRowiCloudSync) {
        row++;
    }
    if (![OptionsViewController crashLogMailAvailable] && row >= kRowCrashLogs) {
        row++;
    }
    return row;
}

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
        // Custom initialization
    }
    return self;
}


#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Settings".ls;
    [self setupSettingsTableViewSpacing];

    // Register for appearance changes once in viewDidLoad, not viewWillAppear
    // This ensures the view updates even when it's not visible (e.g., when in a sub-menu)
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];
    [self updateAppearance];
    [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView reloadData];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    self.view.backgroundColor = ICBackgroundColor;

    // Always reload - the colors of cells need to update
    [self.tableView reloadData];
}


#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger rows = kNumberOfRows;
    if (![OptionsViewController iCloudSyncSettingsAvailable]) {
        rows--;
    }
    if (![OptionsViewController crashLogMailAvailable]) {
        rows--;
    }
    return rows;
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [self detailCell];
    cell.detailTextLabel.text = nil;
    cell.backgroundColor = ICGroupCellBackgroundColor;

    switch ([self settingsRowForIndexPath:indexPath])
    {
        case kRowAppearance:
            cell.textLabel.text = @"Appearance".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"paintbrush"];
            break;
        case kRowPlayback:
            cell.textLabel.text = @"Playback".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"play.circle"];
            break;
        case kRowSleepTimer:
            cell.textLabel.text = @"Sleep Timer".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"moon.zzz"];
            break;
        case kRowData:
            cell.textLabel.text = @"Data".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"tray.full"];
            break;
        case kRowSubscriptions:
            cell.textLabel.text = @"Podcast Settings".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            break;
        case kRowNotifications:
            cell.textLabel.text = @"Notifications".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"bell"];
            break;
        case kRowiCloudSync:
            cell.textLabel.text = @"iCloud Sync".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"icloud"];
            break;
        case kRowImportExport:
            cell.textLabel.text = @"Import / Export".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.up.arrow.down"];
            break;
        case kRowTranscription:
            cell.textLabel.text = NSLocalizedString(@"Transkription und Kapitel", nil);
            cell.imageView.image = [UIImage systemImageNamed:@"captions.bubble"];
            break;
        case kRowSmartHome:
            cell.textLabel.text = @"Smart Home".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"house"];
            break;
        case kRowEmailFeedback:
            cell.textLabel.text = @"Send Feedback/Question".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"envelope"];
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.backgroundColor = [[[ICAppearanceManager sharedManager] appearance].tintColor colorWithAlphaComponent:0.08];
            break;
        case kRowDonateToDeveloper:
            cell.textLabel.text = @"Support InstacastPlus".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"heart"];
            cell.backgroundColor = [[[ICAppearanceManager sharedManager] appearance].tintColor colorWithAlphaComponent:0.08];
            break;
        case kRowCrashLogs:
            cell.textLabel.text = @"Crash Logs per Mail schicken".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.backgroundColor = [[[ICAppearanceManager sharedManager] appearance].tintColor colorWithAlphaComponent:0.08];
            break;
    }

    cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
    return cell;
}


- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
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
        footerView.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
    }
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch ([self settingsRowForIndexPath:indexPath])
    {
        case kRowAppearance: {
            AppearanceSettingsViewController* controller = [AppearanceSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowPlayback: {
            PlaybackSettingsViewController* controller = [PlaybackSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowSleepTimer: {
            SleepTimerSettingsViewController* controller = [SleepTimerSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowData: {
            DataSettingsViewController* controller = [DataSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowSubscriptions: {
            FeedOptionsViewController* controller = [FeedOptionsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowNotifications: {
            NotificationSettingsViewController* controller = [NotificationSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowiCloudSync: {
            ICiCloudSyncSettingsViewController* controller = [ICiCloudSyncSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowImportExport: {
            ImportExportSettingsViewController* controller = [ImportExportSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowTranscription: {
            TranscriptionSettingsViewController* controller = [[TranscriptionSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowSmartHome: {
            SmarthomeSettingsViewController* controller = [SmarthomeSettingsViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowEmailFeedback:
            [self emailFeedbackCLicked];
            break;
        case kRowDonateToDeveloper: {
            DonationViewController *controller = [DonationViewController viewController];
            [self.navigationController pushViewController:controller animated:YES];
            break;
        }
        case kRowCrashLogs:
            [self emailCrashLogsClicked];
            break;
    }
}

- (void)emailFeedbackCLicked {
    if ([MFMailComposeViewController canSendMail]) {
        MFMailComposeViewController *mailComposer = [[MFMailComposeViewController alloc] init];
        mailComposer.mailComposeDelegate = self;

        NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *buildNumber = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        NSString *iOSVersion = [[UIDevice currentDevice] systemVersion];
        //NSString *deviceName = [[UIDevice currentDevice] name];  // "John's iPhone"
        //NSString *deviceModel = [[UIDevice currentDevice] model]; // Generic (e.g., "iPhone")
        NSString *deviceIdentifier = [self deviceModelName];  // Precise model (e.g., "iPhone15,2")

        NSString* feedbackSubject = [NSString stringWithFormat:@"Feedback for InstacastPlus Version %@ (%@) on ios %@ on %@", appVersion, buildNumber, iOSVersion, deviceIdentifier];
        // Configure the email
        [mailComposer setSubject:feedbackSubject];
        [mailComposer setToRecipients:@[@"info@instacast.ch"]];
        [mailComposer setMessageBody:@"" isHTML:NO];

        // Present the mail compose view controller
        [self presentViewController:mailComposer animated:YES completion:nil];
    } else {
        // Show an alert if email is not set up on the device
        [self presentAlertControllerWithTitle:@"Email not configured.".ls message:@"Please configure email on this device.".ls button:@"OK".ls animated:YES completion:NULL];
    }
}

- (void)emailCrashLogsClicked {
    if ([MFMailComposeViewController canSendMail]) {
        MFMailComposeViewController *mailComposer = [[MFMailComposeViewController alloc] init];
        mailComposer.mailComposeDelegate = self;

        NSString *appVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *buildNumber = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
        NSString *subject = [NSString stringWithFormat:@"%@ %@ (%@)", @"Crash Logs InstacastPlus".ls, appVersion, buildNumber];
        [mailComposer setSubject:subject];
        [mailComposer setToRecipients:@[@"info@instacast.ch"]];
        [mailComposer setMessageBody:[[ICDiagnosticLogger shared] crashLogMailBody] isHTML:NO];

        NSArray<ICDiagnosticMailAttachment *> *attachments = [[ICDiagnosticLogger shared] crashLogMailAttachments];
        for (ICDiagnosticMailAttachment *attachment in attachments) {
            [mailComposer addAttachmentData:(NSData *)attachment.data mimeType:attachment.mimeType fileName:attachment.fileName];
        }

        self.sendingCrashLogMail = YES;
        [self presentViewController:mailComposer animated:YES completion:nil];
    } else {
        [self presentAlertControllerWithTitle:@"Email not configured.".ls message:@"Please configure email on this device.".ls button:@"OK".ls animated:YES completion:NULL];
    }
}

- (NSString *)deviceModelName {
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *model = malloc(size);
    sysctlbyname("hw.machine", model, &size, NULL, 0);
    NSString *deviceIdentifier = [NSString stringWithCString:model encoding:NSUTF8StringEncoding];
    free(model);
    
    return deviceIdentifier;
}

- (void)openContactFormInSafari {
    NSURL *url = [NSURL URLWithString:@"https://instacast.ch/contact/"];
    if (url) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == kOptionsSectionMain) {
        UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.frame.size.width, 119)];
        footerView.backgroundColor = [UIColor clearColor];

        UILabel *footerLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 5, footerView.frame.size.width-40, 119)];
        footerLabel.numberOfLines = 0;
        footerLabel.textAlignment = NSTextAlignmentLeft;
        [footerLabel setTextColor:[UIColor grayColor]];
        footerLabel.font = [UIFont systemFontOfSize:ICFontSize(14)];
        footerLabel.text = [NSString stringWithFormat:@"Version %@ (%@)\nPublisher: Chris Thomann \nOriginally developed by Martin Hering \nThank you Martin!", [NSBundle appVersion], [NSBundle buildVersion]];

        [footerView addSubview:footerLabel];
        return footerView;
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if (section == kOptionsSectionMain) {
        return 119;
    }
    return 0.0f;
}

#pragma mark -

- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error
{
    BOOL clearCrashLogMailArtifacts = self.sendingCrashLogMail && result == MFMailComposeResultSent && !error;
    self.sendingCrashLogMail = NO;

    [self dismissViewControllerAnimated:YES completion:^{
    }];

    if (clearCrashLogMailArtifacts) {
        [[ICDiagnosticLogger shared] clearCrashLogMailArtifacts];
    }
	
	if (error) {
		[self presentError:error];
	}
}


@end
