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
static NSString * const kInstacastPlusAppStoreID = @"6472283494";

enum {
    kSectionDonationButtons,
    kSectionLinks,
    kSectionDonationHistory,
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

- (void)openAppStoreReviewPage
{
    NSString *reviewURLString = [NSString stringWithFormat:@"itms-apps://itunes.apple.com/app/id%@?action=write-review", kInstacastPlusAppStoreID];
    NSURL *reviewURL = [NSURL URLWithString:reviewURLString];
    if (!reviewURL) {
        return;
    }
    [[UIApplication sharedApplication] openURL:reviewURL options:@{} completionHandler:nil];
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

    static NSDateFormatter *saveDateFormatter = nil;
    static dispatch_once_t saveDateOnce;
    dispatch_once(&saveDateOnce, ^{
        saveDateFormatter = [[NSDateFormatter alloc] init];
        saveDateFormatter.dateFormat = @"yyyy-MM-dd";
    });
    NSString *dateString = [saveDateFormatter stringFromDate:[NSDate date]];

    NSDictionary *entry = @{
        @"amount": amount,
        @"currency": currencyCode,
        @"date": dateString,
        @"productId": productId
    };

    NSMutableArray *history = [[[USER_DEFAULTS arrayForKey:kDonationHistoryKey] mutableCopy] ?: [NSMutableArray array] mutableCopy];
    [history insertObject:entry atIndex:0];
    [USER_DEFAULTS setObject:history forKey:kDonationHistoryKey];
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

    // Format the date nicely (cached formatters)
    static NSDateFormatter *inputFormatter = nil;
    static NSDateFormatter *outputFormatter = nil;
    static NSNumberFormatter *currencyFormatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inputFormatter = [[NSDateFormatter alloc] init];
        inputFormatter.dateFormat = @"yyyy-MM-dd";
        outputFormatter = [[NSDateFormatter alloc] init];
        outputFormatter.dateStyle = NSDateFormatterMediumStyle;
        outputFormatter.timeStyle = NSDateFormatterNoStyle;
        currencyFormatter = [[NSNumberFormatter alloc] init];
        currencyFormatter.numberStyle = NSNumberFormatterCurrencyStyle;
    });
    NSDate *date = [inputFormatter dateFromString:dateStr];

    NSString *displayDate = dateStr;
    if (date) {
        displayDate = [outputFormatter stringFromDate:date];
    }

    // Format amount with currency
    currencyFormatter.currencyCode = currency;
    NSNumber *amountNumber = @([amount doubleValue]);
    NSString *formattedAmount = [currencyFormatter stringFromNumber:amountNumber] ?: [NSString stringWithFormat:@"%@ %@", amount, currency];

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
                [self openAppStoreReviewPage];
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
        footer.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
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

- (UIImage *)confettiCircleImage
{
    CGSize size = CGSizeMake(12, 12);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, size.width, size.height));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)confettiRectImage
{
    CGSize size = CGSizeMake(14, 8);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, size.width, size.height));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)confettiStarImage
{
    CGSize size = CGSizeMake(14, 14);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    // 5-point star
    CGFloat cx = 7, cy = 7, outerR = 7, innerR = 3;
    CGMutablePathRef path = CGPathCreateMutable();
    for (int i = 0; i < 10; i++) {
        CGFloat r = (i % 2 == 0) ? outerR : innerR;
        CGFloat angle = (M_PI / 2.0) + (i * M_PI / 5.0);
        CGFloat x = cx + r * cosf(angle);
        CGFloat y = cy - r * sinf(angle);
        if (i == 0) CGPathMoveToPoint(path, NULL, x, y);
        else CGPathAddLineToPoint(path, NULL, x, y);
    }
    CGPathCloseSubpath(path);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)showFireworks
{
    UIWindow *window = self.view.window;
    if (!window) return;

    UIView *overlay = [[UIView alloc] initWithFrame:window.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    overlay.alpha = 0.0;
    overlay.userInteractionEnabled = YES;
    [window addSubview:overlay];

    // Thank you label with shadow
    UILabel *thankYouLabel = [[UILabel alloc] init];
    thankYouLabel.text = @"Thank you! Your donation is appreciated!.".ls;
    thankYouLabel.font = [UIFont systemFontOfSize:ICFontSize(28) weight:UIFontWeightHeavy];
    thankYouLabel.textColor = [UIColor whiteColor];
    thankYouLabel.textAlignment = NSTextAlignmentCenter;
    thankYouLabel.numberOfLines = 0;
    thankYouLabel.layer.shadowColor = [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0].CGColor;
    thankYouLabel.layer.shadowOffset = CGSizeZero;
    thankYouLabel.layer.shadowOpacity = 1.0;
    thankYouLabel.layer.shadowRadius = 15;
    thankYouLabel.translatesAutoresizingMaskIntoConstraints = NO;
    thankYouLabel.transform = CGAffineTransformMakeScale(0.5, 0.5);
    thankYouLabel.alpha = 0.0;
    [overlay addSubview:thankYouLabel];

    [NSLayoutConstraint activateConstraints:@[
        [thankYouLabel.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [thankYouLabel.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [thankYouLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:30],
        [thankYouLabel.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-30]
    ]];

    CGFloat w = overlay.bounds.size.width;

    // Shape images
    UIImage *circleImg = [self confettiCircleImage];
    UIImage *rectImg = [self confettiRectImage];
    UIImage *starImg = [self confettiStarImage];
    NSArray *shapes = @[circleImg, rectImg, starImg, circleImg, rectImg];

    // Colors - vivid and varied
    NSArray *colors = @[
        [UIColor colorWithRed:1.0 green:0.84 blue:0.0 alpha:1.0],    // gold
        [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:1.0],   // red
        [UIColor colorWithRed:1.0 green:0.55 blue:0.0 alpha:1.0],    // orange
        [UIColor colorWithRed:0.0 green:0.8 blue:1.0 alpha:1.0],     // cyan
        [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:1.0],     // white
        [UIColor colorWithRed:0.85 green:0.1 blue:0.85 alpha:1.0],   // magenta
        [UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0],     // green
        [UIColor colorWithRed:1.0 green:0.4 blue:0.6 alpha:1.0],     // pink
        [UIColor colorWithRed:0.4 green:0.4 blue:1.0 alpha:1.0],     // blue
        [UIColor colorWithRed:1.0 green:1.0 blue:0.3 alpha:1.0],     // yellow
    ];

    // === Emitter 1: Top shower (main confetti rain) ===
    CAEmitterLayer *topEmitter = [CAEmitterLayer layer];
    topEmitter.emitterPosition = CGPointMake(w / 2.0, -20);
    topEmitter.emitterSize = CGSizeMake(w * 1.5, 1);
    topEmitter.emitterShape = kCAEmitterLayerLine;
    topEmitter.renderMode = kCAEmitterLayerOldestFirst;

    NSMutableArray *topCells = [NSMutableArray array];
    for (int i = 0; i < (int)colors.count; i++) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        cell.birthRate = 30;
        cell.lifetime = 6.0;
        cell.velocity = 350;
        cell.velocityRange = 150;
        cell.emissionLongitude = M_PI; // downward
        cell.emissionRange = M_PI / 3.0; // wide spread
        cell.spin = 3.0;
        cell.spinRange = 6.0;
        cell.scale = 0.15;
        cell.scaleRange = 0.1;
        cell.scaleSpeed = -0.01;
        cell.alphaSpeed = -0.05;
        cell.yAcceleration = 80;
        cell.xAcceleration = (i % 2 == 0) ? 10 : -10; // gentle drift
        cell.color = ((UIColor *)colors[i]).CGColor;
        cell.contents = (id)((UIImage *)shapes[i % shapes.count]).CGImage;
        [topCells addObject:cell];
    }
    topEmitter.emitterCells = topCells;
    [overlay.layer addSublayer:topEmitter];

    // === Emitter 2: Center burst (explosion from center) ===
    CAEmitterLayer *burstEmitter = [CAEmitterLayer layer];
    burstEmitter.emitterPosition = CGPointMake(w / 2.0, overlay.bounds.size.height / 2.0);
    burstEmitter.emitterSize = CGSizeMake(1, 1);
    burstEmitter.emitterShape = kCAEmitterLayerPoint;
    burstEmitter.renderMode = kCAEmitterLayerOldestFirst;

    NSMutableArray *burstCells = [NSMutableArray array];
    for (int i = 0; i < (int)colors.count; i++) {
        CAEmitterCell *cell = [CAEmitterCell emitterCell];
        cell.birthRate = 50;
        cell.lifetime = 4.0;
        cell.velocity = 400;
        cell.velocityRange = 200;
        cell.emissionRange = M_PI * 2; // all directions
        cell.spin = 5.0;
        cell.spinRange = 8.0;
        cell.scale = 0.12;
        cell.scaleRange = 0.08;
        cell.scaleSpeed = -0.015;
        cell.alphaSpeed = -0.05;
        cell.yAcceleration = 120; // gravity pulls down
        cell.color = ((UIColor *)colors[i]).CGColor;
        cell.contents = (id)((UIImage *)shapes[i % shapes.count]).CGImage;
        [burstCells addObject:cell];
    }
    burstEmitter.emitterCells = burstCells;
    [overlay.layer addSublayer:burstEmitter];

    // === Emitter 3: Side cannons (left and right) ===
    CAEmitterLayer *leftEmitter = [CAEmitterLayer layer];
    leftEmitter.emitterPosition = CGPointMake(-10, overlay.bounds.size.height * 0.7);
    leftEmitter.emitterSize = CGSizeMake(1, 1);
    leftEmitter.emitterShape = kCAEmitterLayerPoint;
    leftEmitter.renderMode = kCAEmitterLayerOldestFirst;

    CAEmitterLayer *rightEmitter = [CAEmitterLayer layer];
    rightEmitter.emitterPosition = CGPointMake(w + 10, overlay.bounds.size.height * 0.7);
    rightEmitter.emitterSize = CGSizeMake(1, 1);
    rightEmitter.emitterShape = kCAEmitterLayerPoint;
    rightEmitter.renderMode = kCAEmitterLayerOldestFirst;

    NSMutableArray *leftCells = [NSMutableArray array];
    NSMutableArray *rightCells = [NSMutableArray array];
    for (int i = 0; i < (int)colors.count; i++) {
        // Left cannon - shoots up and right
        CAEmitterCell *lCell = [CAEmitterCell emitterCell];
        lCell.birthRate = 20;
        lCell.lifetime = 5.0;
        lCell.velocity = 500;
        lCell.velocityRange = 100;
        lCell.emissionLongitude = -M_PI / 4.0; // up-right (315 degrees)
        lCell.emissionRange = M_PI / 6.0;
        lCell.spin = 4.0;
        lCell.spinRange = 6.0;
        lCell.scale = 0.13;
        lCell.scaleRange = 0.07;
        lCell.alphaSpeed = -0.05;
        lCell.yAcceleration = 150;
        lCell.color = ((UIColor *)colors[i]).CGColor;
        lCell.contents = (id)((UIImage *)shapes[i % shapes.count]).CGImage;
        [leftCells addObject:lCell];

        // Right cannon - shoots up and left
        CAEmitterCell *rCell = [CAEmitterCell emitterCell];
        rCell.birthRate = 20;
        rCell.lifetime = 5.0;
        rCell.velocity = 500;
        rCell.velocityRange = 100;
        rCell.emissionLongitude = -3.0 * M_PI / 4.0; // up-left (225 degrees)
        rCell.emissionRange = M_PI / 6.0;
        rCell.spin = 4.0;
        rCell.spinRange = 6.0;
        rCell.scale = 0.13;
        rCell.scaleRange = 0.07;
        rCell.alphaSpeed = -0.05;
        rCell.yAcceleration = 150;
        rCell.color = ((UIColor *)colors[i]).CGColor;
        rCell.contents = (id)((UIImage *)shapes[i % shapes.count]).CGImage;
        [rightCells addObject:rCell];
    }
    leftEmitter.emitterCells = leftCells;
    rightEmitter.emitterCells = rightCells;
    [overlay.layer addSublayer:leftEmitter];
    [overlay.layer addSublayer:rightEmitter];

    // Fade in overlay
    [UIView animateWithDuration:0.2 animations:^{
        overlay.alpha = 1.0;
    }];

    // Pop-in animation for label
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:0 animations:^{
            thankYouLabel.transform = CGAffineTransformIdentity;
            thankYouLabel.alpha = 1.0;
        } completion:nil];
    });

    // After 3 seconds: stop new particles, let existing ones fall slowly
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!overlay.superview) return;

        // Stop all emitters (layer-level birthRate, not cell-level)
        for (CALayer *sublayer in [overlay.layer.sublayers copy]) {
            if ([sublayer isKindOfClass:[CAEmitterLayer class]]) {
                CAEmitterLayer *em = (CAEmitterLayer *)sublayer;
                em.birthRate = 0;
            }
        }

        // Let particles fall for 4 more seconds, then fade out
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self dismissOverlay:overlay];
        });
    });

    // Tap to dismiss early
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissFireworksOverlay:)];
    [overlay addGestureRecognizer:tap];
}

- (void)dismissFireworksOverlay:(UITapGestureRecognizer *)gesture
{
    [self dismissOverlay:gesture.view];
}

- (void)dismissOverlay:(UIView *)overlay
{
    if (!overlay.superview) return;

    // Stop all emitters (layer-level birthRate)
    for (CALayer *sublayer in [overlay.layer.sublayers copy]) {
        if ([sublayer isKindOfClass:[CAEmitterLayer class]]) {
            CAEmitterLayer *emitter = (CAEmitterLayer *)sublayer;
            emitter.birthRate = 0;
        }
    }

    [UIView animateWithDuration:1.0 animations:^{
        overlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

@end
