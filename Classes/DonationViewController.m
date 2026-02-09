//
//  DonationViewController.m
//  Instacast
//
//  Created by Chris Thomann on 09.02.26.
//  Copyright (c) 2026 Instacast. All rights reserved.
//

#import <StoreKit/StoreKit.h>

#import "DonationViewController.h"
#import "UITableViewController+Settings.h"
#import "InstacastAppDelegate.h"
#import "UtilityFunctions.h"
#import "PlaybackManager.h"
#import "PlaybackViewController.h"
#import "CDEpisode.h"
#import "CDMedium.h"
#import "CDChapter.h"
#import "Model/DatabaseManager.h"

#define kDonate1ProductID  @"donate_to_developer_1"
#define kDonate5ProductID  @"donate_to_developer_5"
#define kDonate15ProductID @"donate_to_developer_15"
#define kDonate20ProductID @"donate_to_developer_20"

#define kDonationHistoryKey @"DonationHistory"

static NSString * const kPodcastAudioURL = @"https://www.schleifenquadrat.fm/podlove/file/1957/s/webplayer/sq265.mp3";

enum {
    kSectionDonationButtons,
    kSectionDonationHistory,
    kSectionLinks,
    kNumberOfSections
};

@interface DonationViewController ()
{
    SKProductsRequest *_productsRequest;
    NSMutableDictionary *_validProducts;
}
@end

@implementation DonationViewController

+ (DonationViewController *)viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

#pragma mark - View lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.navigationItem.title = @"Support InstacastPlus".ls;
    self.clearsSelectionOnViewWillAppear = YES;
    [self setupSettingsTableViewSpacing];
    [self fetchAvailableProducts];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];
    [self updateAppearance];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    self.view.backgroundColor = ICBackgroundColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

#pragma mark - StoreKit

- (void)fetchAvailableProducts
{
    NSSet *productIdentifiers = [NSSet setWithObjects:
                                 kDonate1ProductID,
                                 kDonate5ProductID,
                                 kDonate15ProductID,
                                 kDonate20ProductID, nil];
    _productsRequest = [[SKProductsRequest alloc] initWithProductIdentifiers:productIdentifiers];
    _productsRequest.delegate = self;
    [_productsRequest start];
}

- (BOOL)canMakePurchases
{
    return [SKPaymentQueue canMakePayments];
}

- (void)purchaseProduct:(SKProduct *)product
{
    if ([self canMakePurchases]) {
        SKPayment *payment = [SKPayment paymentWithProduct:product];
        [[SKPaymentQueue defaultQueue] addTransactionObserver:self];
        [[SKPaymentQueue defaultQueue] addPayment:payment];
    } else {
        [self showAlertWithTitle:@"In app purchase are disabled in your device.".ls];
    }
}

- (NSString *)formattedPriceForProduct:(SKProduct *)product
{
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterCurrencyStyle;
    formatter.locale = product.priceLocale;
    return [formatter stringFromNumber:product.price];
}

- (SKProduct *)productForRow:(NSInteger)row
{
    switch (row) {
        case 0: return _validProducts[@"product_first"];
        case 1: return _validProducts[@"product_second"];
        case 2: return _validProducts[@"product_third"];
        case 3: return _validProducts[@"product_fourth"];
        default: return nil;
    }
}

- (NSString *)fallbackPriceForRow:(NSInteger)row
{
    switch (row) {
        case 0: return @"$1";
        case 1: return @"$5";
        case 2: return @"$15";
        case 3: return @"$20";
        default: return @"";
    }
}

#pragma mark - SKProductsRequestDelegate

- (void)productsRequest:(SKProductsRequest *)request didReceiveResponse:(SKProductsResponse *)response
{
    if (response.products.count > 0) {
        _validProducts = [[NSMutableDictionary alloc] init];
        for (SKProduct *product in response.products) {
            if ([product.productIdentifier isEqualToString:kDonate1ProductID]) {
                _validProducts[@"product_first"] = product;
            } else if ([product.productIdentifier isEqualToString:kDonate5ProductID]) {
                _validProducts[@"product_second"] = product;
            } else if ([product.productIdentifier isEqualToString:kDonate15ProductID]) {
                _validProducts[@"product_third"] = product;
            } else if ([product.productIdentifier isEqualToString:kDonate20ProductID]) {
                _validProducts[@"product_fourth"] = product;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
        });
    }
}

#pragma mark - SKPaymentTransactionObserver

- (void)paymentQueue:(SKPaymentQueue *)queue updatedTransactions:(NSArray *)transactions
{
    for (SKPaymentTransaction *transaction in transactions) {
        switch (transaction.transactionState) {
            case SKPaymentTransactionStatePurchased:
            {
                [self saveDonationForTransaction:transaction];
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.tableView reloadData];
                    [self showFireworks];
                });
                break;
            }
            case SKPaymentTransactionStateFailed:
            {
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            }
            case SKPaymentTransactionStateRestored:
            {
                [[SKPaymentQueue defaultQueue] finishTransaction:transaction];
                break;
            }
            case SKPaymentTransactionStatePurchasing:
                break;
            default:
                break;
        }
    }
}

#pragma mark - Donation History

- (void)saveDonationForTransaction:(SKPaymentTransaction *)transaction
{
    NSString *productId = transaction.payment.productIdentifier;

    // Determine amount and currency from the product
    SKProduct *product = nil;
    if ([productId isEqualToString:kDonate1ProductID]) {
        product = _validProducts[@"product_first"];
    } else if ([productId isEqualToString:kDonate5ProductID]) {
        product = _validProducts[@"product_second"];
    } else if ([productId isEqualToString:kDonate15ProductID]) {
        product = _validProducts[@"product_third"];
    } else if ([productId isEqualToString:kDonate20ProductID]) {
        product = _validProducts[@"product_fourth"];
    }

    NSString *amount = product ? [product.price stringValue] : @"?";

    NSNumberFormatter *currencyFormatter = [[NSNumberFormatter alloc] init];
    currencyFormatter.numberStyle = NSNumberFormatterCurrencyStyle;
    currencyFormatter.locale = product.priceLocale;
    NSString *currencyCode = currencyFormatter.currencyCode ?: @"USD";

    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.dateFormat = @"yyyy-MM-dd";
    NSString *dateString = [dateFormatter stringFromDate:[NSDate date]];

    NSDictionary *entry = @{
        @"amount": amount,
        @"currency": currencyCode,
        @"date": dateString,
        @"productId": productId
    };

    NSMutableArray *history = [[[USER_DEFAULTS arrayForKey:kDonationHistoryKey] mutableCopy] ?: [NSMutableArray array] mutableCopy];
    [history insertObject:entry atIndex:0];
    [USER_DEFAULTS setObject:history forKey:kDonationHistoryKey];
    [USER_DEFAULTS synchronize];
}

- (NSArray *)donationHistory
{
    return [USER_DEFAULTS arrayForKey:kDonationHistoryKey] ?: @[];
}

- (NSString *)formattedDonationEntry:(NSDictionary *)entry
{
    NSString *amount = entry[@"amount"] ?: @"?";
    NSString *currency = entry[@"currency"] ?: @"USD";
    NSString *dateStr = entry[@"date"] ?: @"";

    // Format the date nicely
    NSDateFormatter *inputFormatter = [[NSDateFormatter alloc] init];
    inputFormatter.dateFormat = @"yyyy-MM-dd";
    NSDate *date = [inputFormatter dateFromString:dateStr];

    NSString *displayDate = dateStr;
    if (date) {
        NSDateFormatter *outputFormatter = [[NSDateFormatter alloc] init];
        outputFormatter.dateStyle = NSDateFormatterMediumStyle;
        outputFormatter.timeStyle = NSDateFormatterNoStyle;
        displayDate = [outputFormatter stringFromDate:date];
    }

    // Format amount with currency
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterCurrencyStyle;
    formatter.currencyCode = currency;
    NSNumber *amountNumber = @([amount doubleValue]);
    NSString *formattedAmount = [formatter stringFromNumber:amountNumber] ?: [NSString stringWithFormat:@"%@ %@", amount, currency];

    return [NSString stringWithFormat:@"%@ — %@", displayDate, formattedAmount];
}

#pragma mark - Alert Helper

- (void)showAlertWithTitle:(NSString *)title
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];

    if ([ICAppearanceManager sharedManager].nightSettingMode) {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kSectionDonationButtons:
            return 4;
        case kSectionDonationHistory:
        {
            NSArray *history = [self donationHistory];
            return history.count > 0 ? history.count : 1; // 1 for "No donations yet" placeholder
        }
        case kSectionLinks:
            return 2;
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kSectionDonationButtons:
            return @"Donate for further development".ls;
        case kSectionDonationHistory:
            return @"Donation History".ls;
        case kSectionLinks:
            return nil;
        default:
            return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    switch (indexPath.section) {
        case kSectionDonationButtons:
        {
            UITableViewCell *cell = [self buttonCell];
            SKProduct *product = [self productForRow:indexPath.row];
            if (product) {
                cell.textLabel.text = [self formattedPriceForProduct:product];
            } else {
                cell.textLabel.text = [self fallbackPriceForRow:indexPath.row];
            }
            if ([ICAppearanceManager sharedManager].nightSettingMode) {
                cell.backgroundColor = [UIColor colorWithRed:17/255.0 green:17/255.0 blue:17/255.0 alpha:1.0];
            } else {
                cell.backgroundColor = [UIColor colorWithRed:226/255.0 green:226/255.0 blue:226/255.0 alpha:1.0];
            }
            return cell;
        }
        case kSectionDonationHistory:
        {
            NSArray *history = [self donationHistory];
            if (history.count == 0) {
                UITableViewCell *cell = [self standardCell];
                cell.textLabel.text = @"No donations yet".ls;
                cell.textLabel.textColor = ICMutedTextColor;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                return cell;
            }
            UITableViewCell *cell = [self standardCell];
            cell.textLabel.text = [self formattedDonationEntry:history[indexPath.row]];
            cell.textLabel.textColor = ICTextColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        case kSectionLinks:
        {
            UITableViewCell *cell = [self detailCell];
            cell.detailTextLabel.text = nil;
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Rate on App Store".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"star"];
            } else {
                cell.textLabel.text = @"Listen to Instacast lebt Podcast".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"mic"];
            }
            cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;
            return cell;
        }
        default:
            return nil;
    }
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case kSectionDonationButtons:
        {
            SKProduct *product = [self productForRow:indexPath.row];
            if (product) {
                [self purchaseProduct:product];
            }
            break;
        }
        case kSectionLinks:
        {
            if (indexPath.row == 0) {
                // Rate on App Store
                [SKStoreReviewController requestReview];
            } else {
                // Instacast lebt Podcast - create temporary episode and play
                [self playPodcastEpisode];
            }
            break;
        }
        default:
            break;
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.textColor = [UIColor grayColor];
    }
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
        footer.textLabel.textColor = [UIColor grayColor];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    return 0.0f;
}

#pragma mark - Podcast Playback

- (void)playPodcastEpisode
{
    NSManagedObjectContext *context = DMANAGER.objectContext;

    // Check if episode already exists (avoid duplicates)
    NSFetchRequest *fetchRequest = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"guid == %@", @"sq265-instacast-lebt"];
    NSArray *existing = [context executeFetchRequest:fetchRequest error:nil];
    CDEpisode *episode = existing.firstObject;

    if (!episode) {
        episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode"
                                                inManagedObjectContext:context];
        episode.guid = @"sq265-instacast-lebt";
        episode.title = @"SQ265 Instacast lebt!";
        episode.author = @"Schleifenquadrat";
        episode.duration = 9666; // 2h 41m 6s
        episode.imageURL = [NSURL URLWithString:@"https://www.schleifenquadrat.fm/podlove/image/68747470733a2f2f7777772e7363686c656966656e717561647261742e666d2f77702d636f6e74656e742f75706c6f6164732f323032352f30352f636f7665722d323032352d7363616c65642e6a7067/500/0/0/schleifenquadrat-der-apple-podcast-von-mac-life"];

        // Media
        CDMedium *medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium"
                                                         inManagedObjectContext:context];
        medium.fileURL = [NSURL URLWithString:kPodcastAudioURL];
        medium.mimeType = @"audio/mpeg";
        medium.byteSize = 156949564;
        medium.episode = episode;
        episode.media = [NSSet setWithObject:medium];

        [DMANAGER save];
    }

    // Remove stored chapters so AudioSession re-parses them from the MP3 metadata
    // (includes correct durations, links, and chapter images)
    if (episode.chapters.count > 0) {
        for (CDChapter *ch in [episode.chapters copy]) {
            [context deleteObject:ch];
        }
        episode.chapters = nil;
    }

    // Start at 4:00 (beginning of the InstacastPlus interview)
    episode.position = 240;
    [DMANAGER save];

    PlaybackViewController *playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:YES];
    [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
}

#pragma mark - Fireworks Animation

- (void)showFireworks
{
    UIWindow *window = self.view.window;
    if (!window) return;

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.3];
    overlay.alpha = 0.0;
    overlay.userInteractionEnabled = YES;
    [window addSubview:overlay];

    // Thank you label
    UILabel *thankYouLabel = [[UILabel alloc] init];
    thankYouLabel.text = @"Thank you! Your donation is appreciated!.".ls;
    thankYouLabel.font = [UIFont boldSystemFontOfSize:22];
    thankYouLabel.textColor = [UIColor whiteColor];
    thankYouLabel.textAlignment = NSTextAlignmentCenter;
    thankYouLabel.numberOfLines = 0;
    thankYouLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:thankYouLabel];

    [NSLayoutConstraint activateConstraints:@[
        [thankYouLabel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [thankYouLabel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [thankYouLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:30],
        [thankYouLabel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-30]
    ]];

    // Create emitter layer
    CAEmitterLayer *emitter = [CAEmitterLayer layer];
    emitter.emitterPosition = CGPointMake(overlay.bounds.size.width / 2.0, -10);
    emitter.emitterSize = CGSizeMake(overlay.bounds.size.width, 1);
    emitter.emitterShape = kCAEmitterLayerLine;
    emitter.renderMode = kCAEmitterLayerAdditive;

    NSArray *colors = @[
        (id)[UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0].CGColor,   // gold
        (id)[UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:1.0].CGColor,     // red
        (id)[UIColor colorWithRed:1.0 green:0.6 blue:0.0 alpha:1.0].CGColor,     // orange
        (id)[UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0].CGColor,     // blue
        (id)[UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:1.0].CGColor,     // white
        (id)[UIColor colorWithRed:0.8 green:0.2 blue:0.8 alpha:1.0].CGColor,     // purple
    ];

    NSMutableArray *cells = [NSMutableArray array];
    for (int i = 0; i < (int)colors.count; i++) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        cell.birthRate = 8;
        cell.lifetime = 3.5;
        cell.velocity = 200;
        cell.velocityRange = 80;
        cell.emissionLongitude = M_PI; // downward
        cell.emissionRange = M_PI_4;
        cell.spin = 2.0;
        cell.spinRange = 4.0;
        cell.scale = 0.06;
        cell.scaleRange = 0.04;
        cell.scaleSpeed = -0.01;
        cell.alphaSpeed = -0.3;
        cell.yAcceleration = 50;
        cell.color = (__bridge CGColorRef)colors[i];

        // Use a simple circle as the particle content
        CGSize size = CGSizeMake(20, 20);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, size.width, size.height));
        UIImage *circleImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        cell.contents = (id)circleImage.CGImage;

        [cells addObject:cell];
    }

    emitter.emitterCells = cells;
    [overlay.layer addSublayer:emitter];

    // Fade in
    [UIView animateWithDuration:0.3 animations:^{
        overlay.alpha = 1.0;
    }];

    // Tap to dismiss
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissFireworksOverlay:)];
    [overlay addGestureRecognizer:tap];

    // Auto-remove after 5 seconds
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self dismissOverlay:overlay];
    });
}

- (void)dismissFireworksOverlay:(UITapGestureRecognizer *)gesture
{
    [self dismissOverlay:gesture.view];
}

- (void)dismissOverlay:(UIView *)overlay
{
    if (!overlay.superview) return;

    // Stop emitter birth rate
    for (CALayer *sublayer in overlay.layer.sublayers) {
        if ([sublayer isKindOfClass:[CAEmitterLayer class]]) {
            CAEmitterLayer *emitter = (CAEmitterLayer *)sublayer;
            for (CAEmitterCell *cell in emitter.emitterCells) {
                cell.birthRate = 0;
            }
        }
    }

    [UIView animateWithDuration:0.5 animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

@end
