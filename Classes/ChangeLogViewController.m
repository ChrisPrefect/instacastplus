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
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithTitle:@"Got it!".ls style:UIBarButtonItemStylePlain target:self action:@selector(closeTapped)];
    closeButton.tintColor = ICTintColor;
    self.navigationItem.rightBarButtonItem = closeButton;
    if (@available(iOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    
    self.view.backgroundColor = [UIColor whiteColor];
    // Define the sections and their items
    self.changelogSections = @[
        [NSString stringWithFormat:@"🚀 %@", @"Smarter Listening".ls],
        [NSString stringWithFormat:@"🎵 %@", @"Redesigned Player".ls],
        [NSString stringWithFormat:@"📱 %@", @"Seamless Experience Across Devices".ls],
        [NSString stringWithFormat:@"🎛️ %@", @"Total Control Over Your Podcasts".ls],
        [NSString stringWithFormat:@"🛠️ %@", @"Quality-of-Life Upgrades".ls],
        [NSString stringWithFormat:@"🎨 %@", @"Personalization & Extras".ls],
        [NSString stringWithFormat:@"🔗 %@", @"Smarter Navigation & Storage".ls],
        [NSString stringWithFormat:@"💡 %@", @"Community & Support".ls]
    ];

    self.changelogItems = @[
        @[
            @"Live Transcripts – Podcasts with transcripts now show the spoken text live in the player. Tap any line to jump to that position. The text scrolls along automatically and highlights the current passage.".ls,
            @"Intelligent Sleep Timer – Reduce playing in your ear while you are already sleeping. The new sleep timer can be activated permanently and resets whenever you interact with the app, your phone detects movement in the bed, or you change the volume.".ls,
            @"Auto-Skip Chapters – Tired of intros, ads, or segments you don't care about? Now you can skip them automatically by setting keyword triggers for chapters to avoid! You can also skip intros and outros automatically by selecting a time in seconds to skip at the start and end.".ls
        ],
        @[
            @"Redesigned Now Playing – Larger play button, chapter name below the seek bar, bigger seek bar and time labels. Scrubbing: tap or drag anywhere on the seek bar to jump to that position.".ls,
            @"Chapter Markers on Seek Bar – See chapter boundaries at a glance. The current chapter is highlighted.".ls,
            @"Swipeable Chapter Images – Easily look through all chapter artwork while listening. Peek ahead or go back to the last image discussed in the podcast without losing your listening position.".ls
        ],
        @[
            @"Backup & Restore – Never lose your data! Full export of all subscriptions, settings, playlists and play status. The new import dialog shows live progress and lets you skip individual podcasts.".ls,
            @"CarPlay – Take your podcasts on the road with full CarPlay support.".ls,
            @"iPad & macOS Support – Enjoy an optimized experience on iPad and Mac with a dedicated layout. Optimized for iOS 26 Liquid Glass.".ls
        ],
        @[
            @"Podcast Charts with Genre Filter – Browse the current Apple Podcast Charts right in the directory, filterable by categories like True Crime, Comedy, News and more.".ls,
            @"Filter Episodes Your Way – Instantly sort your episodes by All, Unlistened, Started, Favorites, or Downloaded. No more endless scrolling!".ls,
            @"Episode Retention Rules – Automatically delete episodes after X days or keep only the newest Y episodes per podcast.".ls,
            @"Pause Podcast Updates – Temporarily exclude podcasts from syncing that you're not actively listening to.".ls,
            @"Restore Deleted Episodes – Accidentally deleted an episode? No worries—bring it back with one tap in the settings!".ls
        ],
        @[
            @"Blazing Fast Refresh – Up to 10 podcasts refresh simultaneously. Unreachable podcasts no longer block the rest.".ls,
            @"Bigger Fonts and Buttons – Better readability and easier operation throughout the entire interface.".ls,
            @"Remember Scroll Position – No more losing your place when browsing for older episodes!".ls,
            @"Faster App Start – The app launches noticeably faster.".ls
        ],
        @[
            @"Custom Interface Colors – Make the app yours! Choose your own interface color or let each podcast have its own unique tint.".ls,
            @"Multiple App Icons – Choose from different icons, including a Dark Mode version! You can even send us your custom icons so we can integrate them in the next version.".ls,
            @"More Playback Speeds – Find your perfect listening speed with new options: 1.1x, 1.2x, 1.3x.".ls,
            @"Dark Mode – Automatic (follows system), Light or Dark. Replaces the old location-based night mode.".ls
        ],
        @[
            @"Download Manager – Downloads sortable by size, date or podcast. Delete all downloads of a podcast at once.".ls,
            @"Auto-Delete Old Downloads – Set rules to remove unplayed episodes after a day, a week, or a month.".ls,
            @"MQTT Smart Home – Control your podcasts via your smart home! Playback status, chapters, sleep timer and more are published to your MQTT broker. Remote control included.".ls,
            @"External Browser Option – Prefer Safari or Chrome? Now you can set all shownote links to open externally.".ls
        ],
        @[
            @"Feature Request & Bug Report Link – Share your ideas and issues directly through the app.".ls,
            @"Donation Support – Love InstacastPlus? Now you can support development with in-app donations.".ls
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
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 165)];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, self.view.frame.size.width - 32, 80)];
    titleLabel.text = @"InstacastPlus Changelog".ls;
    titleLabel.font = [UIFont boldSystemFontOfSize:18];
    titleLabel.numberOfLines = 0;
    titleLabel.textAlignment = NSTextAlignmentCenter;
    
    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 80, self.view.frame.size.width - 32, 75)];
    subtitleLabel.text = @"We've been busy making InstacastPlus even smarter, and more powerful. Check out what's new and get ready to experience podcasts like never before!".ls;
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
    return 40;
}

@end
