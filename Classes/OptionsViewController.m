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
#import "AppearanceSettingsViewController.h"
#import "PlaybackSettingsViewController.h"
#import "SleepTimerSettingsViewController.h"
#import "DataSettingsViewController.h"
#import "ImportExportSettingsViewController.h"
#import "SmarthomeSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "InstacastAppDelegate.h"
#include <sys/sysctl.h>
#import "VDModalInfo.h"

#define kDonate1ProductID @"donate_to_developer_1"
#define kDonate5ProductID @"donate_to_developer_5"
#define kDonate15ProductID @"donate_to_developer_15"
#define kDonate20ProductID @"donate_to_developer_20"

@interface OptionsViewController () <MFMailComposeViewControllerDelegate>
@end


enum {
    kOptionsSectionSettings,
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
    switch (section) {
        case kOptionsSectionSettings:
            return 8;
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
            cell.detailTextLabel.text = nil;

            if (indexPath.row == 0) {
                cell.textLabel.text = @"Appearance".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"paintbrush"];
            }
            else if (indexPath.row == 1)
            {
                cell.textLabel.text = @"Playback".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"play.circle"];
            }
            else if (indexPath.row == 2)
            {
                cell.textLabel.text = @"Sleep Timer".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"moon.zzz"];
            }
            else if (indexPath.row == 3)
            {
                cell.textLabel.text = @"Data".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"tray.full"];
            }
            else if (indexPath.row == 4)
            {
                cell.textLabel.text = @"Subscriptions".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            }
            else if (indexPath.row == 5)
            {
                cell.textLabel.text = @"Notifications".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"bell"];
            }
            else if (indexPath.row == 6)
            {
                cell.textLabel.text = @"Import / Export".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.up.arrow.down"];
            }
            else if (indexPath.row == 7)
            {
                cell.textLabel.text = @"Smart Home".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"house"];
            }
            cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
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
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == kOptionsSectionSettings) {
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
                AppearanceSettingsViewController* controller = [AppearanceSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 1) {
                PlaybackSettingsViewController* controller = [PlaybackSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 2) {
                SleepTimerSettingsViewController* controller = [SleepTimerSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 3) {
                DataSettingsViewController* controller = [DataSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 4) {
                FeedOptionsViewController* controller = [FeedOptionsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 5) {
                NotificationSettingsViewController* controller = [NotificationSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 6) {
                ImportExportSettingsViewController* controller = [ImportExportSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }
            else if (indexPath.row == 7) {
                SmarthomeSettingsViewController* controller = [SmarthomeSettingsViewController viewController];
                [self.navigationController pushViewController:controller animated:YES];
            }

            break;
        }
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
    if (section == kOptionsSectionSettings) {
        return 200;
    }

    return 0.0f;
}

#pragma mark -

- (void)mailComposeController:(MFMailComposeViewController*)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError*)error
{
    [self dismissViewControllerAnimated:YES completion:^{
    }];
	
	if (error) {
		[self presentError:error];
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
