//
//  FeedOptionsViewController.m
//  Instacast
//
//  Created by Martin Hering on 31.05.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import "FeedOptionsViewController.h"
#import "UITableViewController+Settings.h"

#import "FeedSettingsViewController.h"
#import "CDModel.h"
#import "SubscriptionSettingTableViewCell.h"

static NSString* kFeedCell = @"FeedCell";

enum {
    kRefreshSection,
    kFeedsSection,
    kNumberOfSections
};


@interface FeedOptionsViewController ()

@end

@implementation FeedOptionsViewController

+ (FeedOptionsViewController*) viewController
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

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    [self.tableView registerClass:[SubscriptionSettingTableViewCell class] forCellReuseIdentifier:kFeedCell];
    
    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Podcast Settings".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
}

- (void)viewDidAppear:(BOOL)animated
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

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (section == kRefreshSection) {
        return 1;
    }
    return [DMANAGER.feeds count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kRefreshSection) {
        UITableViewCell* cell = [self switchCell];
        UISwitch* control = (UISwitch*)cell.accessoryView;
        cell.textLabel.text = @"Podcast-Refresh bei App-Start".ls;
        control.on = [USER_DEFAULTS boolForKey:PodcastRefreshOnAppStart];
        [control addTarget:self action:@selector(toggleStartupRefresh:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }

    SubscriptionSettingTableViewCell *cell = (SubscriptionSettingTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kFeedCell forIndexPath:indexPath];

    CDFeed* feed = [DMANAGER.feeds objectAtIndex:indexPath.row];
    cell.textLabel.text = feed.title;
    cell.disclosureView.tintColor = ([feed hasCustomProperties]) ? ICTintColor : [UIColor colorWithRed:199/255.f green:199/255.f blue:204/255.f alpha:1.f];
    
    cell.switchControl.on = !feed.parked;
    cell.switchControl.tag = indexPath.row;
    [cell.switchControl addTarget:self action:@selector(switchParking:) forControlEvents:UIControlEventValueChanged];
    
    return cell;
}


#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kRefreshSection) {
        return;
    }

    CDFeed* feed = [DMANAGER.feeds objectAtIndex:indexPath.row];
    
    FeedSettingsViewController* viewController = [FeedSettingsViewController feedSettingsViewControllerWithFeed:feed];
    
    [self.navigationController pushViewController:viewController animated:YES];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kRefreshSection) {
        return @"Automatically refresh podcasts when opening the app or returning to it. Manual refreshes, push updates, and iOS background fetch are unaffected.".ls;
    }

    return @"Use the switch to temporarily pause a podcast. No new episodes will be fetched and no auto-downloads will occur. Tap a row to change individual podcast settings. Colored disclosure triangles indicate that custom settings apply.".ls;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
    header.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString* text = [self tableView:tableView titleForFooterInSection:section];
    return [self heightForFooterText:text];
}


- (void) switchParking:(UISwitch*)switchControl
{
    NSInteger index = switchControl.tag;
    CDFeed* feed = [DMANAGER.feeds objectAtIndex:index];
    feed.parked = !switchControl.on;
    [DMANAGER save];
}

- (void) toggleStartupRefresh:(UISwitch*)switchControl
{
    [USER_DEFAULTS setBool:switchControl.on forKey:PodcastRefreshOnAppStart];
}

@end
