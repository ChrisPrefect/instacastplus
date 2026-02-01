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
#import "CDPlaylist.h"

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

#define kDonate1ProductID @"donate_to_developer_1"
#define kDonate5ProductID @"donate_to_developer_5"
#define kDonate15ProductID @"donate_to_developer_15"
#define kDonate20ProductID @"donate_to_developer_20"

@interface OptionsViewController () <MFMailComposeViewControllerDelegate, UIDocumentInteractionControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@property (strong) VDModalInfo* mInfo;
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
            return 4;
        case kOptionsSectionIO:
            return 2;
        case kEmailFeedback:
            return 1;
        case kDonateToDeveloper:
            return 1;
        default:
            break;
    }
    return 1;
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section)
    {
        case kOptionsSectionSettings:
        {
            UITableViewCell* cell = [self detailCell];
            
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
        NSString *footerText = [NSString stringWithFormat:@"\nVersion %@ (%@)\nPublisher: Chris Thomann \nDeveloper: Claude Code Opus 4.5, Devendra Kamal, Tasia Mosahid \nOriginally developed by Martin Hering \nThank you Martin!", [NSBundle appVersion], [NSBundle buildVersion]];
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
            
            break;
        }
            
            
        case kOptionsSectionIO:
            switch (indexPath.row) {
                case 0:
                    [self exportToDropboxAction:nil];
                    break;
                case 1:
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

    [alert addAction:[UIAlertAction actionWithTitle:@"Alles".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                [self perform:^(id sender) {
                                                    [self exportEverything];
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


- (NSString*) xmlEscape:(NSString*)string
{
    if (!string) return @"";
    string = [string stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    string = [string stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    string = [string stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    string = [string stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    return string;
}

- (void) exportEverything
{
    NSMutableString* xml = [NSMutableString string];
    NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];

    // XML Header
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendFormat:@"<instacast version=\"1\" date=\"%@\">\n", [dateFormatter stringFromDate:[NSDate date]]];

    // Podcasts
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
    NSArray* feeds = [DMANAGER.objectContext executeFetchRequest:fetchRequest error:nil];

    [xml appendString:@"  <podcasts>\n"];
    for (CDFeed* feed in feeds) {
        [xml appendFormat:@"    <podcast url=\"%@\" rank=\"%d\">\n",
            [self xmlEscape:[feed.sourceURL absoluteString]], feed.rank];

        // Custom properties
        if ([feed hasCustomProperties]) {
            [xml appendString:@"      <settings>\n"];
            for (NSString* key in [feed propertyKeys]) {
                NSString* stringVal = [feed stringForKey:key];
                if (stringVal) {
                    [xml appendFormat:@"        <%@>%@</%@>\n", key, [self xmlEscape:stringVal], key];
                } else {
                    NSInteger intVal = [feed integerForKey:key];
                    if (intVal != 0) {
                        [xml appendFormat:@"        <%@>%ld</%@>\n", key, (long)intVal, key];
                    }
                }
            }
            [xml appendString:@"      </settings>\n"];
        }

        // Episodes with state
        BOOL hasEpisodes = NO;
        for (CDEpisode* episode in feed.episodes) {
            if (episode.consumed || episode.starred || episode.archived || episode.position > 0 || episode.downloaded) {
                if (!hasEpisodes) {
                    [xml appendString:@"      <episodes>\n"];
                    hasEpisodes = YES;
                }
                CDMedium* medium = [episode preferedMedium];
                [xml appendFormat:@"        <episode media=\"%@\" guid=\"%@\">\n",
                    [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                    [self xmlEscape:episode.guid ?: @""]];
                if (episode.consumed) [xml appendString:@"          <played>true</played>\n"];
                if (episode.starred) [xml appendString:@"          <starred>true</starred>\n"];
                if (episode.archived) [xml appendString:@"          <archived>true</archived>\n"];
                if (episode.downloaded) [xml appendString:@"          <downloaded>true</downloaded>\n"];
                if (episode.position > 0) [xml appendFormat:@"          <position>%d</position>\n", episode.position];
                if (episode.duration > 0) [xml appendFormat:@"          <duration>%d</duration>\n", episode.duration];
                [xml appendString:@"        </episode>\n"];
            }
        }
        if (hasEpisodes) [xml appendString:@"      </episodes>\n"];
        [xml appendString:@"    </podcast>\n"];
    }
    [xml appendString:@"  </podcasts>\n"];

    // Bookmarks
    NSArray* bookmarks = DMANAGER.bookmarks;
    if (bookmarks.count > 0) {
        [xml appendString:@"  <bookmarks>\n"];
        for (CDBookmark* bookmark in bookmarks) {
            [xml appendFormat:@"    <bookmark position=\"%.0f\" title=\"%@\" episodeGuid=\"%@\" feedUrl=\"%@\"/>\n",
                bookmark.position,
                [self xmlEscape:bookmark.title ?: @""],
                [self xmlEscape:bookmark.episodeGuid ?: @""],
                [self xmlEscape:[bookmark.feedURL absoluteString] ?: @""]];
        }
        [xml appendString:@"  </bookmarks>\n"];
    }

    // Up Next
    AudioSession* session = [AudioSession sharedAudioSession];
    NSArray* upNextPlaylist = session.playlist;
    if (upNextPlaylist.count > 0) {
        [xml appendString:@"  <upnext>\n"];
        for (CDEpisode* episode in upNextPlaylist) {
            CDMedium* medium = [episode preferedMedium];
            [xml appendFormat:@"    <episode media=\"%@\" guid=\"%@\" feedUrl=\"%@\"/>\n",
                [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                [self xmlEscape:episode.guid ?: @""],
                [self xmlEscape:[episode.feed.sourceURL absoluteString] ?: @""]];
        }
        [xml appendString:@"  </upnext>\n"];
    }

    // Now Playing
    CDEpisode* currentEpisode = session.episode;
    if (currentEpisode) {
        CDMedium* medium = [currentEpisode preferedMedium];
        [xml appendFormat:@"  <nowplaying media=\"%@\" guid=\"%@\" feedUrl=\"%@\" position=\"%d\"/>\n",
            [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
            [self xmlEscape:currentEpisode.guid ?: @""],
            [self xmlEscape:[currentEpisode.feed.sourceURL absoluteString] ?: @""],
            currentEpisode.position];
    }

    // Playlists
    NSArray* lists = DMANAGER.lists;
    BOOL hasPlaylists = NO;
    for (CDList* list in lists) {
        if ([list isKindOfClass:[CDPlaylist class]]) {
            if (!hasPlaylists) {
                [xml appendString:@"  <playlists>\n"];
                hasPlaylists = YES;
            }
            CDPlaylist* playlist = (CDPlaylist*)list;
            [xml appendFormat:@"    <playlist name=\"%@\" rank=\"%d\">\n",
                [self xmlEscape:playlist.name], playlist.rank];
            for (CDEpisode* episode in playlist.sortedEpisodes) {
                CDMedium* medium = [episode preferedMedium];
                [xml appendFormat:@"      <episode media=\"%@\" guid=\"%@\" feedUrl=\"%@\"/>\n",
                    [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                    [self xmlEscape:episode.guid ?: @""],
                    [self xmlEscape:[episode.feed.sourceURL absoluteString] ?: @""]];
            }
            [xml appendString:@"    </playlist>\n"];
        }
    }
    if (hasPlaylists) [xml appendString:@"  </playlists>\n"];

    // Settings
    NSUserDefaults* defaults = USER_DEFAULTS;
    [xml appendString:@"  <settings>\n"];
    if ([defaults objectForKey:DefaultPlaybackSpeed]) [xml appendFormat:@"    <playbackSpeed>%ld</playbackSpeed>\n", (long)[defaults integerForKey:DefaultPlaybackSpeed]];
    if ([defaults objectForKey:PlayerSkipBackPeriod]) [xml appendFormat:@"    <skipBack>%ld</skipBack>\n", (long)[defaults integerForKey:PlayerSkipBackPeriod]];
    if ([defaults objectForKey:PlayerSkipForwardPeriod]) [xml appendFormat:@"    <skipForward>%ld</skipForward>\n", (long)[defaults integerForKey:PlayerSkipForwardPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipStartPeriod]) [xml appendFormat:@"    <autoSkipStart>%ld</autoSkipStart>\n", (long)[defaults integerForKey:PlayerAutoSkipStartPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipEndPeriod]) [xml appendFormat:@"    <autoSkipEnd>%ld</autoSkipEnd>\n", (long)[defaults integerForKey:PlayerAutoSkipEndPeriod]];
    if ([defaults objectForKey:PlayerReplayAfterPause]) [xml appendFormat:@"    <replayAfterPause>%ld</replayAfterPause>\n", (long)[defaults integerForKey:PlayerReplayAfterPause]];
    if ([defaults objectForKey:AutoCacheNewAudioEpisodes]) [xml appendFormat:@"    <autoCacheAudio>%@</autoCacheAudio>\n", [defaults boolForKey:AutoCacheNewAudioEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoCacheNewVideoEpisodes]) [xml appendFormat:@"    <autoCacheVideo>%@</autoCacheVideo>\n", [defaults boolForKey:AutoCacheNewVideoEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteAfterFinishedPlaying]) [xml appendFormat:@"    <autoDeletePlayed>%@</autoDeletePlayed>\n", [defaults boolForKey:AutoDeleteAfterFinishedPlaying] ? @"true" : @"false"];
    if ([defaults objectForKey:DisableAutoLock]) [xml appendFormat:@"    <disableAutoLock>%@</disableAutoLock>\n", [defaults boolForKey:DisableAutoLock] ? @"true" : @"false"];
    if ([defaults objectForKey:kDefaultNightMode]) [xml appendFormat:@"    <nightMode>%@</nightMode>\n", [defaults boolForKey:kDefaultNightMode] ? @"true" : @"false"];
    if ([defaults objectForKey:ScreenTimerAlwaysActive]) [xml appendFormat:@"    <sleepTimerAlways>%@</sleepTimerAlways>\n", [defaults boolForKey:ScreenTimerAlwaysActive] ? @"true" : @"false"];
    if ([defaults objectForKey:LastSelectedSleepTimer]) [xml appendFormat:@"    <lastSleepTimer>%ld</lastSleepTimer>\n", (long)[defaults integerForKey:LastSelectedSleepTimer]];
    [xml appendString:@"  </settings>\n"];

    [xml appendString:@"</instacast>\n"];

    // Write file
    NSData* data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSString* fileName = [NSString stringWithFormat:@"Instacast-Backup-%@.xml", [UIDevice currentDevice].name];
    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];

    [data writeToURL:url atomically:YES];

    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
    self.interactionController.delegate = self;
    self.interactionController.name = fileName;
    self.interactionController.UTI = @"public.xml";
    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
        self.interactionController = nil;
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
    popPresenter.permittedArrowDirections = 0;
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
