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
    MainSidebarItem* item = [[self alloc] init];
    item.title = title;
    item.tag = tag;
    item.image = image;
    item.selectedImage = selectedImage;
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

    UIView* footerContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(b), 60)];
    footerContainer.backgroundColor = [UIColor clearColor];
    self.footerContainerView = footerContainer;

    UILabel* footerLabel = [[UILabel alloc] initWithFrame:CGRectMake(75, 5, CGRectGetWidth(b) - 90, 50)];
    footerLabel.font = [UIFont systemFontOfSize:15];
    footerLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
    footerLabel.textAlignment = NSTextAlignmentLeft;
    footerLabel.numberOfLines = 2;
    [footerContainer addSubview:footerLabel];
    self.footerInfoLabel = footerLabel;

    [self.tableView addSubview:footerContainer];
}

- (void) _updateFooterPosition
{
    if (!self.footerContainerView) {
        return;
    }

    CGRect b = self.tableView.bounds;
    CGFloat bottomInset = 0;
    if (@available(iOS 11.0, *)) {
        bottomInset = self.tableView.safeAreaInsets.bottom;
    }

    // Account for the "now playing" bar height (44) + some padding
    CGFloat nowPlayingBarHeight = 70;
    CGFloat footerHeight = 50;
    CGFloat yPosition = self.tableView.contentOffset.y + CGRectGetHeight(b) - footerHeight - bottomInset - nowPlayingBarHeight;
    self.footerContainerView.frame = CGRectMake(0, yPosition, CGRectGetWidth(b), footerHeight);
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [self _updateFooterPosition];
}


- (void) viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self _updateFooterPosition];
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

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if (section != 0) {
        return 20.0f;
    }
    
    return 0.0f;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    UITableViewHeaderFooterView* headerView = [tableView dequeueReusableHeaderFooterViewWithIdentifier:kHeaderCellIdentifier];
    
    UIView *customView = [[UIView alloc] initWithFrame:CGRectZero];
    customView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    customView.backgroundColor = [UIColor clearColor];
    
    headerView.backgroundView = customView;

    return headerView;
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
    NSFetchRequest* feedsRequest = [[NSFetchRequest alloc] init];
    feedsRequest.entity = [NSEntityDescription entityForName:@"Feed" inManagedObjectContext:DMANAGER.objectContext];
    feedsRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES && parked == NO"];
    NSUInteger feedCount = [DMANAGER.objectContext countForFetchRequest:feedsRequest error:nil];

    unsigned long long megaBytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytes];

    NSMutableString* infoText = [[NSMutableString alloc] init];

    if (feedCount == 0) {
        [infoText appendString:@"No subscription".ls];
    } else if (feedCount == 1) {
        [infoText appendString:@"1 subscription".ls];
    } else {
        [infoText appendFormat:@"%lu %@", (unsigned long)feedCount, @"Subscriptions".ls];
    }

    if (megaBytes > 0) {
        NSString* sizeString = [NSByteCountFormatter stringFromByteCount:megaBytes countStyle:NSByteCountFormatterCountStyleMemory];
        [infoText appendFormat:@"\n%@", sizeString];
    }

    self.footerInfoLabel.text = infoText;
}

@end
