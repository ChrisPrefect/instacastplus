//
//  OptionsViewController.m
//  Instacast
//
//  Created by Martin Hering on 07.11.11.
//  Copyright (c) 2011 Vemedio. All rights reserved.
//

#import <MessageUI/MessageUI.h>
#import <StoreKit/StoreKit.h>

#import "OptionsViewController.h"

#import "SubscriptionManager.h"
#import "TwitterHelper.h"
#import "UtilityFunctions.h"
#import "XPFF.h"
#import "VDModalInfo.h"
#import "FeedOptionsViewController.h"
#import "NotificationSettingsViewController.h"
#import "MediaFilesViewController.h"
#import "GeneralSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "InstacastAppDelegate.h"
#include <sys/sysctl.h>
#import "VDModalInfo.h"
#import <CloudKit/CloudKit.h>

#define kDonate1ProductID @"donate_to_developer_1"
#define kDonate5ProductID @"donate_to_developer_5"
#define kDonate15ProductID @"donate_to_developer_15"
#define kDonate20ProductID @"donate_to_developer_20"
#define kUserEnableICloudSync @"UserEnableiCloudSync"

@interface OptionsViewController () <MFMailComposeViewControllerDelegate, UIDocumentInteractionControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@property (strong) VDModalInfo* mInfo;
@property (nonatomic, assign) BOOL isICloudSyncAvailable;
@property (nonatomic, strong) NSString *icloudStatusMessage;
@end


enum {
    kOptionsSectionSettings,
    kOptionsSectionIO,
    kEmailFeedback,
    kDonateToDeveloper,
    kNumberOfSections
};


@implementation OptionsViewController


+ (OptionsViewController*) optionsViewController
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


#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.icloudStatusMessage = @"Checking...";
    [self checkICloudStatusWithCompletion:^(NSString *statusMessage, BOOL available) {
        self.isICloudSyncAvailable = available;
        self.icloudStatusMessage = statusMessage;
        [self.tableView reloadData];
    }];
    
    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Settings".ls;
    [self fetchAvailableProducts];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];
    [self updateAppearance];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
    [self.navigationController.navigationBar setTintColor:[[ICAppearanceManager sharedManager] appearance].tintColor];
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


- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    
    [self.tableView reloadData];
}


#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kOptionsSectionSettings:
            return 5;
        case kOptionsSectionIO:
            return 3;
        case kEmailFeedback:
            return 1;
        case kDonateToDeveloper:
            return 1;
        default:
            break;
    }
    return 1;
}


- (void)checkICloudStatusWithCompletion:(void (^)(NSString *statusMessage, BOOL available))completion {
    [[CKContainer defaultContainer] accountStatusWithCompletionHandler:^(CKAccountStatus status, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion([NSString stringWithFormat:@"iCloud check failed: %@", error.localizedDescription], NO);
                return;
            }
            switch (status) {
                case CKAccountStatusAvailable:
//                    completion(@"✅ iCloud is available", YES);
                    completion(@"✅ Available", YES);
                    break;
                case CKAccountStatusNoAccount:
//                    completion(@"❌ No iCloud account signed in", NO);
                    completion(@"❌ Not Available", NO);
                    break;
                case CKAccountStatusRestricted:
//                    completion(@"❌ iCloud is restricted on this device", NO);
                    completion(@"❌ Restricted", NO);
                    break;
                case CKAccountStatusCouldNotDetermine:
//                    completion(@"⚠️ Unable to determine iCloud status", NO);
                    completion(@"❌ Not Available", NO);
                    break;
                default:
//                    completion(@"❌ Unknown iCloud status", NO);
                    completion(@"❌ Not Available", NO);
                    break;
            }
        });
    }];
}

- (BOOL)isICloudSyncEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kUserEnableICloudSync];
}

- (void)setICloudSyncEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kUserEnableICloudSync];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)isICloudAvailable {
    return [[NSFileManager defaultManager] ubiquityIdentityToken] != nil;
}

- (void)didTapResetICloudSync {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset iCloud Sync"
                                                                   message:@"Are you sure you want to reset iCloud sync data?"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self resetICloudSync];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];

    [alert addAction:confirm];
    [alert addAction:cancel];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetICloudSync {
    CKDatabase *privateDB = [[CKContainer defaultContainer] privateCloudDatabase];
    NSPredicate *predicate = [NSPredicate predicateWithValue:YES];

    CKQuery *query = [[CKQuery alloc] initWithRecordType:@"YourRecordType" predicate:predicate];
    [privateDB performQuery:query inZoneWithID:nil completionHandler:^(NSArray<CKRecord *> *results, NSError *error) {
        if (error) {
            NSLog(@"Error fetching records: %@", error.localizedDescription);
            return;
        }

        NSMutableArray *recordIDs = [NSMutableArray array];
        for (CKRecord *record in results) {
            [recordIDs addObject:record.recordID];
        }

        CKModifyRecordsOperation *deleteOp = [[CKModifyRecordsOperation alloc] initWithRecordsToSave:nil recordIDsToDelete:recordIDs];
        deleteOp.modifyRecordsCompletionBlock = ^(NSArray *saved, NSArray *deleted, NSError *opError) {
            if (opError) {
                NSLog(@"❌ Reset failed: %@", opError.localizedDescription);
            } else {
                NSLog(@"✅ iCloud sync data reset successfully");
            }
        };

        [privateDB addOperation:deleteOp];
    }];
}

//- (BOOL)isICloudSyncEnabled {
//    return [[NSUserDefaults standardUserDefaults] boolForKey:kUserEnableICloudSync];
//}
//
//- (void)setICloudSyncEnabled:(BOOL)enabled {
//    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kUserEnableICloudSync];
//    [[NSUserDefaults standardUserDefaults] synchronize];
//    [self.tableView reloadData];
//}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section)
    {
        case kOptionsSectionSettings:
        {
            UITableViewCell* cell = [self detailCell];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            if (indexPath.row == 0) {
                cell.textLabel.text = @"General".ls;
                cell.detailTextLabel.text = nil;
            }
            else if (indexPath.row == 1)
            {
                cell.textLabel.text = @"Subscriptions".ls;
                cell.detailTextLabel.text = nil;
            }
            else if (indexPath.row == 2)
            {
                cell.textLabel.text = @"Notifications".ls;
                cell.detailTextLabel.text = nil;
            }
            else if (indexPath.row == 3)
            {
                cell.textLabel.text = @"Offline Storage".ls;
                cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:[[CacheManager sharedCacheManager] numberOfDownloadedBytes] countStyle:NSByteCountFormatterCountStyleMemory];
            }
            else if (indexPath.row == 4)
            {
                cell.textLabel.text = @"iCloud Sync Status".ls;
                cell.accessoryType = nil;
//                BOOL syncEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"iCloudSyncEnabled"];
//                if (self.isICloudSyncEnabled) {
//                    cell.detailTextLabel.text = @"ON".ls;
//                } else {
//                    cell.detailTextLabel.text = @"OFF".ls;
//                }
                NSString *statusText = self.icloudStatusMessage ?: @"Checking...";

                NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:statusText];

                // Always style status text
                [attributedText addAttribute:NSForegroundColorAttributeName
                                       value:[UIColor labelColor]
                                       range:NSMakeRange(0, statusText.length)];

                if (self.isICloudSyncAvailable == YES) {
                    NSString *resetText = @"   Reset";
                    NSString *fullText = [NSString stringWithFormat:@"%@%@", statusText, resetText];

                    attributedText = [[NSMutableAttributedString alloc] initWithString:fullText];

                    // Style main status
                    [attributedText addAttribute:NSForegroundColorAttributeName
                                           value:[UIColor labelColor]
                                           range:NSMakeRange(0, statusText.length)];

                    // Style Reset in red
                    [attributedText addAttribute:NSForegroundColorAttributeName
                                           value:[UIColor systemRedColor]
                                           range:NSMakeRange(statusText.length, resetText.length)];
                }

                cell.detailTextLabel.attributedText = attributedText;
            }
            return cell;
        }
            
        case kOptionsSectionIO:
        {
            UITableViewCell* cell = [self buttonCell];
            cell.detailTextLabel.text = nil;
            
            switch (indexPath.row) {
                case 0:
                    cell.textLabel.text = @"Export Data".ls;
                    break;
                case 1:
                    cell.textLabel.text = @"Send Data as Email".ls;
                    if (![MFMailComposeViewController canSendMail]) {
                        cell.textLabel.textColor = [UIColor colorWithWhite:0.7f alpha:1.f];
                        cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    }
                    break;
                case 2:
                    cell.textLabel.text = @"Import Data".ls;
                    break;
                default:
                    break;
            }
            return cell;
        }
        case kEmailFeedback:
        {
            UITableViewCell* cell = [self buttonCell];
            cell.detailTextLabel.text = nil;
            cell.textLabel.text = @"E-Mail Feedback".ls;
            if ([ICAppearanceManager sharedManager].nightSettingMode) {
                cell.backgroundColor = [UIColor colorWithRed:17/255.0 green:17/255.0 blue:17/255.0 alpha:1.0];
            } else {
                cell.backgroundColor = [UIColor colorWithRed:226/255.0 green:226/255.0 blue:226/255.0 alpha:1.0];
            }
            return cell;
        }
        case kDonateToDeveloper:
        {
            UITableViewCell* cell = [self buttonCell];
            cell.detailTextLabel.text = nil;
            cell.textLabel.text = @"Donate for further development ❤️".ls;
            if ([ICAppearanceManager sharedManager].nightSettingMode) {
                cell.backgroundColor = [UIColor colorWithRed:17/255.0 green:17/255.0 blue:17/255.0 alpha:1.0];
            } else {
                cell.backgroundColor = [UIColor colorWithRed:226/255.0 green:226/255.0 blue:226/255.0 alpha:1.0];
            }
            return cell;
        }
            
        default:
            break;
    }
    
    
    return nil;
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
    } else {
        NSLog(@"Unexpected footer view type: %@", [view class]);
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == kNumberOfSections-1) {
        // Create the footer view
        UIView *footerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, tableView.frame.size.width, 200)];
        footerView.backgroundColor = [UIColor clearColor];
        
        // Create the label
        UILabel *footerLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, footerView.frame.size.width-40, 200)];
        footerLabel.numberOfLines = 0; // Allow multiple lines
        footerLabel.textAlignment = NSTextAlignmentLeft; // Center align the text
        footerLabel.userInteractionEnabled = YES; // Enable interaction
        [footerLabel setTextColor:[UIColor grayColor]];
        footerLabel.font = [UIFont systemFontOfSize:14];
        
        // Set up the attributed string with links
        //@"\nVersion %@ (%@)\nPublisher: Chris Thomann \nWebsite: https://instacast.ch/contact/ \nDeveloper: Devendra Kamal, Tasia Mosahid \nOriginally developed by Martin Hering \nThank you Martin!"
        NSString *footerText = [NSString stringWithFormat:@"\nVersion %@ (%@)\nPublisher: Chris Thomann \nDeveloper: Devendra Kamal, Tasia Mosahid \nOriginally developed by Martin Hering \nThank you Martin!", [NSBundle appVersion], [NSBundle buildVersion]];
        /*NSMutableAttributedString *attributedText = [[NSMutableAttributedString alloc] initWithString:footerText];
         NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
         paragraphStyle.lineSpacing = 5.0;
         [attributedText addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(0, footerText.length)];
         
         [attributedText addAttribute:NSLinkAttributeName value:@"https://instacast.ch/contact/" range:[footerText rangeOfString:@"https://instacast.ch/contact/"]];
         
         footerLabel.attributedText = attributedText;*/
        footerLabel.text = footerText;
        
        // Add gesture recognizer for link taps
        /*UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleFooterLinkTap:)];
         [footerLabel addGestureRecognizer:tapGesture];*/
        
        // Add label to footer view
        [footerView addSubview:footerLabel];
        
        return footerView;
    }
    return nil;
}

- (void)handleFooterLinkTap:(UITapGestureRecognizer *)gesture {
    UILabel *label = (UILabel *)gesture.view;
    if (label) {
        CGPoint tapLocation = [gesture locationInView:label];
        NSTextStorage *textStorage = [[NSTextStorage alloc] initWithAttributedString:label.attributedText];
        NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
        NSTextContainer *textContainer = [[NSTextContainer alloc] initWithSize:label.bounds.size];
        textContainer.lineFragmentPadding = 0;
        textContainer.lineBreakMode = label.lineBreakMode;
        textContainer.maximumNumberOfLines = label.numberOfLines;
        
        [layoutManager addTextContainer:textContainer];
        [textStorage addLayoutManager:layoutManager];
        
        // Adjust the tap location for line spacing
        tapLocation.y -= (tapLocation.y / label.font.lineHeight) * 5.0; // Adjust for the extra spacing (5.0 in this case)
        
        NSUInteger characterIndex = [layoutManager characterIndexForPoint:tapLocation inTextContainer:textContainer fractionOfDistanceBetweenInsertionPoints:nil];
        
        if (characterIndex < label.attributedText.length) {
            NSString *urlString = [label.attributedText attribute:NSLinkAttributeName atIndex:characterIndex effectiveRange:nil];
            if (urlString) {
                NSURL *url = [NSURL URLWithString:urlString];
                if (url) {
                    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                }
            }
        }
    }
}



#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    switch (indexPath.section)
    {
        case kOptionsSectionSettings:
        {
            if (indexPath.row == 0) {
                GeneralSettingsViewController* controller = [GeneralSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 1) {
                FeedOptionsViewController* controller = [FeedOptionsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 2) {
                NotificationSettingsViewController* controller = [NotificationSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 3) {
                MediaFilesViewController* controller = [MediaFilesViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 4) {
//                BOOL enabled = [self isICloudSyncEnabled];
//                [self setICloudSyncEnabled:!enabled];
                if (self.isICloudSyncAvailable == YES) {
                    [self didTapResetICloudSync];
                }
            }
            
            break;
        }
            
            
        case kOptionsSectionIO:
            switch (indexPath.row) {
                case 0:
                    [self exportToDropboxAction:nil];
                    break;
                case 1:
                    [self sendEmailAction:nil];
                    break;
                case 2:
                    [self importDataFromFilesMailAction:nil];
                    break;
                default:
                    break;
            }
            break;
        case kEmailFeedback:
            [self emailFeedbackCLicked];
            break;
        case kDonateToDeveloper:
            [self donateToDeveloper:nil];
            break;
            
        default:
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

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    if (section == kNumberOfSections-1) {
        return 200;
    }

    return 0.0f;
}

#pragma mark -

- (void) sendEmailAction:(id)sender
{
    if (![MFMailComposeViewController canSendMail]) {
        [self presentAlertControllerWithTitle:@"Email not configured.".ls message:@"Please configure email on this device.".ls button:@"OK".ls animated:YES completion:NULL];
        return;
    }
    
    NSString* deviceName = [UIDevice currentDevice].name;
    
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Export Data".ls
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Subscriptions".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {

                                                    NSData* data = [[SubscriptionManager sharedSubscriptionManager] opmlData];
                                                    NSString* fileName = [NSString stringWithFormat:@"%@-%@.opml", @"Subscriptions".ls, deviceName];
                                                    
                                                    MFMailComposeViewController *picker = [[MFMailComposeViewController alloc] init];
                                                    picker.mailComposeDelegate = self;
                                                    [picker setSubject:[NSString stringWithFormat:@"Instacast Subscriptions from %@".ls, deviceName]];
                                                    [picker addAttachmentData:data mimeType:@"text/x-opml" fileName:fileName];
                                                    [self presentViewController:picker animated:YES completion:NULL];

                                                    
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Bookmarks".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    
                                                    NSData* data = XPFFDataWithBookmarks(DMANAGER.bookmarks);
                                                    NSString* fileName = [NSString stringWithFormat:@"%@-%@.xpff", @"Bookmarks".ls, deviceName];
                                                    
                                                    MFMailComposeViewController *picker = [[MFMailComposeViewController alloc] init];
                                                    picker.mailComposeDelegate = self;
                                                    [picker setSubject:[NSString stringWithFormat:@"Instacast Bookmarks from %@".ls, deviceName]];
                                                    [picker addAttachmentData:data mimeType:@"text/x-xpff" fileName:fileName];
                                                    [self presentViewController:picker animated:YES completion:NULL];

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

- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error
{
    [self dismissViewControllerAnimated:YES completion:^{
    }];
	
	if (error) {
		[self presentError:error];
	}
}

- (void) exportToDropboxAction:(id)sender
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Export Data".ls
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Subscriptions".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    
                                                    NSData* data = [[SubscriptionManager sharedSubscriptionManager] opmlData];
                                                    
                                                    NSString* fileName = [NSString stringWithFormat:@"%@-%@.opml", @"Subscriptions".ls, [UIDevice currentDevice].name];
                                                    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
                                                    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];
                                                    
                                                    [data writeToURL:url atomically:YES];
                                                    
                                                    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
                                                    self.interactionController.delegate = self;
                                                    self.interactionController.name = fileName;
                                                    self.interactionController.UTI = @"instacast.opml";
                                                    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
                                                        self.interactionController = nil;
                                                    }
                                                    
                                                } afterDelay:0.3];
                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Bookmarks".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    
                                                    NSData* data = XPFFDataWithBookmarks(DMANAGER.bookmarks);
                                                    
                                                    NSString* fileName = [NSString stringWithFormat:@"%@-%@.xpff", @"Bookmarks".ls, [UIDevice currentDevice].name];
                                                    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
                                                    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];
                                                    
                                                    [data writeToURL:url atomically:YES];
                                                    
                                                    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
                                                    self.interactionController.delegate = self;
                                                    self.interactionController.name = fileName;
                                                    self.interactionController.UTI = @"com.vemedio.xpff";
                                                    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
                                                        self.interactionController = nil;
                                                    }

                                                    
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

- (void) importDataFromFilesMailAction:(id)sender
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Open an opml file from mail or the files app in InstacastPlus to import podcasts.".ls message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Import".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                //mail import feature
                                                    UIDocumentPickerViewController *picker =
                                                        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.xml"] inMode:UIDocumentPickerModeImport];
                                                    picker.delegate = self;
                                                    picker.allowsMultipleSelection = NO;
                                                    picker.shouldShowFileExtensions = YES;
                                                    picker.modalPresentationStyle = UIModalPresentationFormSheet;
                                                    [self presentViewController:picker animated:YES completion:nil];

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

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url && [[url.pathExtension lowercaseString] isEqualToString:@"opml"]) {
        self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Importing…".ls];
        [self.mInfo show];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            BOOL needsSecurity = [url startAccessingSecurityScopedResource];
            NSLog(@"Security access granted? %@", needsSecurity ? @"YES" : @"NO");

            NSData *opmlData = [NSData dataWithContentsOfURL:url];

            if (needsSecurity) {
                [url stopAccessingSecurityScopedResource];
            }

            if (!opmlData || opmlData.length == 0) {
                NSLog(@"Invalid OPML data or empty");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.mInfo close];
                    self.mInfo = nil;
                });
                return;
            }

            [[SubscriptionManager sharedSubscriptionManager] importOPMLData:opmlData completion:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.mInfo close];
                    self.mInfo = nil;
                });
            } progress:^(float progress) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"Progress: %.0f%%", progress * 100);
                    if (progress > 0.03) {
                        [self.mInfo setProgress:progress];
                    }
                });
            }];
        });
    }
}


- (void) donateToDeveloper:(id)sender
{
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Donate for further development".ls message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction* firstAction = [UIAlertAction actionWithTitle:@"$1".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            if([validProducts valueForKey:@"product_first"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_first"]];
            }
        } afterDelay:0.01];
        self.alertController = nil;
    }];
    [alert addAction:firstAction];
    
    UIAlertAction* secondAction = [UIAlertAction actionWithTitle:@"$5".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            if([validProducts valueForKey:@"product_second"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_second"]];
            }
        } afterDelay:0.01];
        self.alertController = nil;
    }];
    [alert addAction:secondAction];
    
    UIAlertAction* thirdAction = [UIAlertAction actionWithTitle:@"$15".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            if([validProducts valueForKey:@"product_third"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_third"]];
            }
        } afterDelay:0.01];
        self.alertController = nil;
    }];
    [alert addAction:thirdAction];
    
    UIAlertAction* fourthAction = [UIAlertAction actionWithTitle:@"$20".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        STRONG_SELF
        [self perform:^(id sender) {
            if([validProducts valueForKey:@"product_fourth"] != nil)
            {
                [self purchaseMyProduct:[validProducts valueForKey:@"product_fourth"]];
            }
        } afterDelay:0.01];
        self.alertController = nil;
    }];
    [alert addAction:fourthAction];
    
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        STRONG_SELF
        self.alertController = nil;
    }];
    [alert addAction:defaultAction];
    
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


#pragma mark -

- (void) documentInteractionControllerDidDismissOpenInMenu: (UIDocumentInteractionController *) controller
{
    self.interactionController = nil;
}

-(void)fetchAvailableProducts {
    NSSet *productIdentifiers = [NSSet setWithObjects:kDonate1ProductID,kDonate5ProductID,kDonate15ProductID,kDonate20ProductID,nil];
    productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:productIdentifiers];
    productsRequest.delegate = self;
    [productsRequest start];
}

- (BOOL)canMakePurchases {
    return [SKPaymentQueue canMakePayments];
}

- (void)purchaseMyProduct:(SKProduct*)product {
    if ([self canMakePurchases]) {
        SKPayment *payment = [SKPayment paymentWithProduct:product];
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
        [[SKPaymentQueue defaultQueue] addPayment:payment];
    } else {
        [self showPurchaseAlertController:@"In app purchase are disabled in your device"];
    }
}

- (void)showPurchaseAlertController:(NSString*)titleStr
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:titleStr.ls message:nil preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:@"Okay".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {}];
    [alert addAction:defaultAction];
    
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
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark StoreKit Delegate

-(void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions {
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStatePurchasing:
                NSLog(@"Purchasing===%@",transaction.payment.productIdentifier);
                break;
            case SKPaymentTransactionStatePurchased:
                NSLog(@"Purchased ");
                if ([transaction.payment.productIdentifier isEqualToString:kDonate1ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                else if ([transaction.payment.productIdentifier isEqualToString:kDonate5ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                else if ([transaction.payment.productIdentifier isEqualToString:kDonate15ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                else if ([transaction.payment.productIdentifier isEqualToString:kDonate20ProductID]) {
                    [self showPurchaseAlertController:@"Thank you! Your donation is appreciated!.".ls];
                }
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStateRestored:
                NSLog(@"Restored ");
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            case SKPaymentTransactionStateFailed:
                NSLog(@"Purchase failed ");
                break;
            default:
                break;
        }
    }
}

-(void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response {
    int count = (int)[response.products count];
    if (count>0) {
        NSArray* products = response.products;
        validProducts = [[NSMutableDictionary alloc] init];
        for (SKProduct* product in products)
        {
            if ([product.productIdentifier  isEqual: kDonate1ProductID])
            {
                [validProducts setObject:product forKey:@"product_first"];
            }
            else if ([product.productIdentifier  isEqual: kDonate5ProductID])
            {
                [validProducts setObject:product forKey:@"product_second"];
            }
            else if ([product.productIdentifier  isEqual: kDonate15ProductID])
            {
                [validProducts setObject:product forKey:@"product_third"];
            }
            else if ([product.productIdentifier  isEqual: kDonate20ProductID])
            {
                [validProducts setObject:product forKey:@"product_fourth"];
            }
        }
    }
}


@end
