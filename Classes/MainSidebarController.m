//
//  MainSidebarController.m
//  Instacast
//
//  Created by Martin Hering on 29.06.13.
//
//

#import "MainSidebarController.h"
#import "MainSidebarTableCell.h"
#import "CDModel.h"

#define ROW_HEIGHT 40

static NSString* kDataCellIdentifier = @"DataCell";
static NSString* kHeaderCellIdentifier = @"HeaderCell";

@implementation MainSidebarItem

+ (instancetype) itemWithTitle:(NSString*)title tag:(NSInteger)tag image:(UIImage*)image selectedImage:(UIImage*)selectedImage
{
    return [self itemWithTitle:title tag:tag image:image selectedImage:selectedImage topSpacing:0];
}

+ (instancetype) itemWithTitle:(NSString*)title tag:(NSInteger)tag image:(UIImage*)image selectedImage:(UIImage*)selectedImage topSpacing:(CGFloat)topSpacing
{
    MainSidebarItem* item = [[self alloc] init];
    item.title = title;
    item.tag = tag;
    item.image = image;
    item.selectedImage = selectedImage;
    item.topSpacing = topSpacing;
    return item;
}

@end

@interface MainSidebarController ()
@property (nonatomic, strong) UILabel* footerInfoLabel;
@property (nonatomic, strong) UIView* footerContainerView;
@end

@implementation MainSidebarController

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.tableView.allowsMultipleSelection = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = ROW_HEIGHT;
    self.tableView.scrollEnabled = NO;

    // Remove default section header padding (iOS 15+)
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }

    [self.tableView registerClass:[MainSidebarTableCell class] forCellReuseIdentifier:kDataCellIdentifier];
    [self.tableView registerClass:[UITableViewHeaderFooterView class] forHeaderFooterViewReuseIdentifier:kHeaderCellIdentifier];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    self.view.backgroundColor = ICDarkBackgroundColor;
    [self.tableView reloadData];

    [self updateRowSelectionForSelectedItemTag];
    [self updateTableTopInset:UIInterfaceOrientationPortrait];
    [self _setupFooterViewIfNeeded];
    [self updateFooterInfo];
}

- (void) _setupFooterViewIfNeeded
{
    if (self.footerContainerView) {
        return;
    }

    CGRect b = self.tableView.bounds;

    // Footer container with top padding for spacing after Settings
    UIView* footerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(b), 140)];
    footerContainer.backgroundColor = [UIColor clearColor];
    self.footerContainerView = footerContainer;

    // Top padding of 25 for spacing after Settings menu item
    UILabel* footerLabel = [[UILabel alloc] initWithFrame:CGRectMake(75, 25, CGRectGetWidth(b) - 90, 110)];
    footerLabel.font = [UIFont systemFontOfSize:13];
    footerLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
    footerLabel.textAlignment = NSTextAlignmentLeft;
    footerLabel.numberOfLines = 5;
    [footerContainer addSubview:footerLabel];
    self.footerInfoLabel = footerLabel;

    // Use tableFooterView so it appears naturally below menu items
    self.tableView.tableFooterView = footerContainer;
}


- (void) viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        return UIStatusBarStyleLightContent;
    }
    else
    {
        return UIStatusBarStyleDarkContent;
    }
    //return UIStatusBarStyleLightContent;
}

- (void) updateTableTopInset:(UIInterfaceOrientation)orientation
{
    CGRect b = self.view.bounds;
    CGFloat h = 0;
    
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        h = (CGRectGetHeight(b) < CGRectGetWidth(b)) ? CGRectGetHeight(b) : CGRectGetWidth(b);
    }
    else {
        h = (CGRectGetHeight(b) > CGRectGetWidth(b)) ? CGRectGetHeight(b) : CGRectGetWidth(b);
    }
    
    
    NSInteger itemCount = [self.items count]-1;
    for (NSArray* items in self.items) {
        itemCount += [items count];
    }
    
    CGFloat headerHeight = floorf((h-(itemCount*(ROW_HEIGHT+1)))/2);
    headerHeight = MAX(headerHeight, 94+15);
    self.tableView.contentInset = UIEdgeInsetsMake(headerHeight, 0, 0, 0);
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation duration:(NSTimeInterval)duration
{
    [self updateTableTopInset:interfaceOrientation];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [self.items count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self.items[section] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    MainSidebarTableCell *cell = [tableView dequeueReusableCellWithIdentifier:kDataCellIdentifier forIndexPath:indexPath];
    
    NSArray* sectionItems = self.items[indexPath.section];
    MainSidebarItem* item = sectionItems[indexPath.row];
    cell.objectValue = item;
    
    NSInteger badgeNumber = (item.badgeNumber) ? item.badgeNumber() : 0;
    cell.badgeButton.hidden = (badgeNumber == 0);
    
    [cell.badgeButton setTitle:[@(badgeNumber) stringValue] forState:UIControlStateNormal];
    
    return cell;
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray* sectionItems = self.items[indexPath.section];
    MainSidebarItem* item = sectionItems[indexPath.row];
    
    NSInteger lastSelectedItemTag = self.selectedItemTag;
    self.selectedItemTag = item.tag;
    [self updateRowSelectionForSelectedItemTag];
    
    if (!self.didSelectItem(item)) {
        self.selectedItemTag = lastSelectedItemTag;
        [self updateRowSelectionForSelectedItemTag];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSArray* sectionItems = self.items[indexPath.section];
    MainSidebarItem* item = sectionItems[indexPath.row];
    return ROW_HEIGHT + item.topSpacing;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    return 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    return nil;
}

- (void) updateRowSelectionForSelectedItemTag
{
    [self.items enumerateObjectsUsingBlock:^(NSArray* sectionItems, NSUInteger section, BOOL *stop1) {
        [sectionItems enumerateObjectsUsingBlock:^(MainSidebarItem* item, NSUInteger row, BOOL *stop2) {
            if (item.tag == self.selectedItemTag) {
                NSIndexPath* indexPath = [NSIndexPath indexPathForRow:row inSection:section];
                [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionMiddle];
                *stop1 = YES;
                *stop2 = YES;
            }
        }];
    }];
}

- (void) updateFooterInfo
{
    // Number formatter for locale-specific thousand separators
    NSNumberFormatter* numberFormatter = [[NSNumberFormatter alloc] init];
    numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
    numberFormatter.locale = [NSLocale currentLocale];

    // Feed count
    NSFetchRequest* feedsRequest = [[NSFetchRequest alloc] init];
    feedsRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:DMANAGER.objectContext];
    feedsRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES && parked == NO"];
    NSUInteger feedCount = [DMANAGER.objectContext countForFetchRequest:feedsRequest error:nil];

    // Total episodes count
    NSFetchRequest* episodesRequest = [[NSFetchRequest alloc] init];
    episodesRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    episodesRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES && feed.parked == NO && archived == NO"];
    NSUInteger totalEpisodes = [DMANAGER.objectContext countForFetchRequest:episodesRequest error:nil];

    // Unplayed episodes count
    NSFetchRequest* unplayedRequest = [[NSFetchRequest alloc] init];
    unplayedRequest.entity = [NSEntityDescription entityForName:@"Episode" inManagedObjectContext:DMANAGER.objectContext];
    unplayedRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES && feed.parked == NO && archived == NO && consumed == NO"];
    NSUInteger unplayedEpisodes = [DMANAGER.objectContext countForFetchRequest:unplayedRequest error:nil];

    // Downloaded episodes count (use CacheManager for accurate count)
    NSUInteger downloadedEpisodes = [[CacheManager sharedCacheManager].cachedEpisodes count];

    // Storage size
    unsigned long long storageBytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytes];

    NSMutableString* infoText = [[NSMutableString alloc] init];

    // Subscriptions
    [infoText appendFormat:@"%@: %@\n", @"Subscriptions".ls, [numberFormatter stringFromNumber:@(feedCount)]];

    // Total Episodes
    [infoText appendFormat:@"%@: %@\n", @"Total Episodes".ls, [numberFormatter stringFromNumber:@(totalEpisodes)]];

    // Total Unplayed
    [infoText appendFormat:@"%@: %@\n", @"Total Unplayed".ls, [numberFormatter stringFromNumber:@(unplayedEpisodes)]];

    // Total Downloaded
    [infoText appendFormat:@"%@: %@\n", @"Total Downloaded".ls, [numberFormatter stringFromNumber:@(downloadedEpisodes)]];

    // Storage Used
    NSString* sizeString = [NSByteCountFormatter stringFromByteCount:storageBytes countStyle:NSByteCountFormatterCountStyleMemory];
    [infoText appendFormat:@"%@: %@", @"Storage Used".ls, sizeString];

    self.footerInfoLabel.text = infoText;
}

@end
