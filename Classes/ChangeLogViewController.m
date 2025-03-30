//
//  ChangeLogViewController.m
//  Instacast
//
//  Created by Devendra Kamal on 28/03/25.
//  Copyright © 2025 Vemedio. All rights reserved.
//

#import "ChangeLogViewController.h"

@interface ChangeLogViewController () <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *changelogSections;
@property (nonatomic, strong) NSArray *changelogItems;

@end

@implementation ChangeLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Add Close Button
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithTitle:@"Got it!" style:UIBarButtonItemStylePlain target:self action:@selector(closeTapped)];
    closeButton.tintColor = ICTintColor;
    self.navigationItem.rightBarButtonItem = closeButton;
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    
    self.view.backgroundColor = [UIColor whiteColor];
    // Define the sections and their items
    self.changelogSections = @[
        @"🚀 Smarter Listening",
        @"📱 Seamless Experience Across Devices",
        @"🎛️ Total Control Over Your Podcasts",
        @"🛠️ Quality-of-Life Upgrades",
        @"🎨 Personalization & Extras",
        @"🔗 Smarter Navigation & Storage",
        @"💡 Community & Support"
    ];
    
    self.changelogItems = @[
        @[
            @"Intelligent Sleep Timer – Reduce playing in your ear while you are already sleeping. The new sleep timer can be activated permanently and resets whenever you interact with the app, your phone detects movement in the bed, or you change the volume.",
            @"Auto-Skip Chapters – Tired of intros, ads, or segments you don’t care about? Now you can skip them automatically by setting keyword triggers for chapters to avoid! You can also skip intros and outros automatically by selecting a time in seconds to skip at the start and end.",
            @"Swipeable Chapter Images – Easily look through all chapter artwork while listening. Peek ahead or go back to the last image discussed in the podcast without losing your listening position."
        ],
        @[
            @"iCloud Sync – Keep your podcasts, listened status, and scroll positions synced across all your Apple devices!",
            @"Basic CarPlay Integration – Take your podcasts on the road with full CarPlay support.",
            @"Basic iPad & macOS Support – Enjoy an optimized experience on iPad and Mac with a new, dedicated layout!"
        ],
        @[
            @"Filter Episodes Your Way – Instantly sort your episodes by All, Unlistened, Started, Favorites, or Downloaded. No more endless scrolling!",
            @"Restore Deleted Episodes – Accidentally deleted an episode? No worries—bring it back with one tap in the settings!",
            @"Custom Interface Colors – Make the app yours! Choose your own interface color or let each podcast have its own unique tint."
        ],
        @[
            @"Remember Scroll Position – No more losing your place when browsing for older episodes!",
            @"Bigger Tap Areas – Buttons are now easier to hit, especially on the player screen."
        ],
        @[
            @"More Playback Speeds – Find your perfect listening speed with new options: 1.1x, 1.2x, 1.3x.",
            @"Multiple App Icons – Choose from different icons, including a Dark Mode version! You can even send us your custom icons so we can integrate them in the next version."
        ],
        @[
            @"Sort Downloads by Size – Quickly manage storage by seeing which episodes take up the most space in the offline space screen.",
            @"Auto-Delete Old Downloads – Set rules to remove unplayed episodes after a day, a week, or a month.",
            @"External Browser Option – Prefer Safari or Chrome? Now you can set all shownote links to open externally."
        ],
        @[
            @"Feature Request & Bug Report Link – Share your ideas and issues directly through the app.",
            @"Donation Support – Love InstacastPlus? Now you can support development with in-app donations."
        ]
    ];
    
    // Initialize UITableView
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.tableHeaderView = [self createHeaderView]; // Set custom header
    [self.view addSubview:self.tableView];
}

// MARK: - Custom Header View
- (UIView *)createHeaderView {
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 120)];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, self.view.frame.size.width - 32, 50)];
    titleLabel.text = @"InstacastPlus Changelog – Fresh Features for Your Listening Pleasure! 🎉🎧";
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.numberOfLines = 0;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    
    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 50, self.view.frame.size.width - 32, 60)];
    subtitleLabel.text = @"We’ve been busy making InstacastPlus even smarter, and more powerful. Check out what’s new and get ready to experience podcasts like never before!";
    subtitleLabel.font = [UIFont systemFontOfSize:14];
    subtitleLabel.numberOfLines = 0;
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.textColor = [UIColor darkGrayColor];
    
    [headerView addSubview:titleLabel];
    [headerView addSubview:subtitleLabel];
    
    return headerView;
}

// MARK: - Close Button Action
- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// MARK: - UITableView DataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.changelogSections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.changelogItems[section] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.changelogSections[section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"ChangelogCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:14];
    }
    
    cell.textLabel.text = self.changelogItems[indexPath.section][indexPath.row];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

// MARK: - UITableView Delegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 30;
}

@end
