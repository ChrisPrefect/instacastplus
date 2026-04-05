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
    [self _setupFooterViewIfNeeded];
    [self updateFooterInfo];
}

- (void) _setupFooterViewIfNeeded
{
    if (self.footerContainerView) {
        return;
    }

    // Empty footer to prevent extra separators
    UIView* footerContainer = [[UIView alloc] initWithFrame:CGRectZero];
    footerContainer.backgroundColor = [UIColor clearColor];
    self.footerContainerView = footerContainer;
    self.tableView.tableFooterView = footerContainer;
}


- (void) viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self updateTableTopInsetForCurrentBounds];
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

- (void) updateTableTopInsetForCurrentBounds
{
    CGFloat h = CGRectGetHeight(self.view.bounds);
    if (h <= 0) return;

    NSInteger itemCount = 0;
    CGFloat totalTopSpacing = 0;
    for (NSArray* sectionItems in self.items) {
        itemCount += [sectionItems count];
        for (MainSidebarItem* item in sectionItems) {
            totalTopSpacing += item.topSpacing;
        }
    }

    CGFloat totalContentHeight = itemCount * (ROW_HEIGHT + 1) + totalTopSpacing;
    CGFloat headerHeight = floorf((h - totalContentHeight) / 2);
    headerHeight = MAX(headerHeight, 94 + 15);

    // If content doesn't fit, reduce headerHeight so items remain visible
    if (headerHeight + totalContentHeight > h) {
        headerHeight = MAX(h - totalContentHeight, 20);
        self.tableView.scrollEnabled = YES;
    } else {
        self.tableView.scrollEnabled = NO;
    }

    self.tableView.contentInset = UIEdgeInsetsMake(headerHeight, 0, 0, 0);

    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    UIEdgeInsets adjustedInset = self.tableView.adjustedContentInset;
    DebugLog(@"[Sidebar Layout] viewBounds=%@ safeArea=(%g,%g,%g,%g) items=%ld contentH=%g headerH=%g contentInset.top=%g adjustedInset.top=%g scrollEnabled=%d",
             NSStringFromCGRect(self.view.bounds),
             safeArea.top, safeArea.left, safeArea.bottom, safeArea.right,
             (long)itemCount, totalContentHeight, headerHeight,
             self.tableView.contentInset.top, adjustedInset.top,
             self.tableView.scrollEnabled);
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

    NSString* subtitle = (item.subtitle) ? item.subtitle() : nil;
    cell.subtitleLabel.text = subtitle;
    cell.subtitleLabel.hidden = (subtitle.length == 0);

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
    // Statistics moved to Settings > Data screen
}

@end
