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
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;

@end

@implementation ChangeLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Add Close Button
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithTitle:@"Got it!".ls style:UIBarButtonItemStylePlain target:self action:@selector(closeTapped)];
    closeButton.tintColor = ICTintColor;
    self.navigationItem.rightBarButtonItem = closeButton;

    // Define the sections and their items
    self.changelogSections = @[
        [NSString stringWithFormat:@"💡 %@", @"CL Tips Title".ls],
        [NSString stringWithFormat:@"🎙️ %@", @"CL Transcription Title".ls],
        [NSString stringWithFormat:@"🚀 %@", @"Smarter Listening".ls],
        [NSString stringWithFormat:@"🎵 %@", @"Redesigned Player".ls],
        [NSString stringWithFormat:@"📱 %@", @"Across Devices".ls],
        [NSString stringWithFormat:@"🎛️ %@", @"Podcast Management".ls],
        [NSString stringWithFormat:@"🛠️ %@", @"Quality-of-Life".ls],
        [NSString stringWithFormat:@"🎨 %@", @"Personalization".ls],
        [NSString stringWithFormat:@"🏠 %@", @"Smart Home".ls],
        [NSString stringWithFormat:@"💡 %@", @"Community & Support".ls]
    ];

    self.changelogItems = @[
        @[
            @"CL Tip LongPress".ls,
            @"CL Tip SwipeActions".ls,
            @"CL Tip Transcription".ls,
            @"CL Tip ChapterSkip".ls,
            @"CL Tip SleepTimer".ls,
            @"CL Tip Playlists".ls
        ],
        @[
            @"CL Transcription Feature".ls,
            @"CL Chapter Generation".ls,
            @"CL Sponsor Detection".ls,
            @"CL Music Analysis".ls
        ],
        @[
            @"CL Live Transcripts".ls,
            @"CL Intelligent Sleep Timer".ls,
            @"CL Auto-Skip Chapters".ls
        ],
        @[
            @"CL Redesigned Now Playing".ls,
            @"CL Chapter Markers".ls,
            @"CL Swipeable Chapter Images".ls
        ],
        @[
            @"CL Widgets".ls,
            @"CL Backup & Restore".ls,
            @"CL CarPlay".ls,
            @"CL iPad & macOS".ls
        ],
        @[
            @"CL Podcast Charts".ls,
            @"CL Episode Filters".ls,
            @"CL Episode Retention".ls,
            @"CL Pause Podcast Updates".ls,
            @"CL Restore Deleted Episodes".ls,
            @"CL Download Management".ls
        ],
        @[
            @"CL Configurable Swipe Actions".ls,
            @"CL Tap on Episode".ls,
            @"CL Context Menus".ls,
            @"CL Adjustable Font Size".ls,
            @"CL Faster Refresh".ls,
            @"CL Remember Scroll Position".ls,
            @"CL Faster App Start".ls
        ],
        @[
            @"CL Custom Colors".ls,
            @"CL App Icons".ls,
            @"CL Playback Speeds".ls,
            @"CL Dark Mode".ls
        ],
        @[
            @"CL MQTT Integration".ls
        ],
        @[
            @"CL Feedback".ls,
            @"CL Donations".ls
        ]
    ];

    // Initialize UITableView
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.tableHeaderView = [self createHeaderView];
    [self.view addSubview:self.tableView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAppearance];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateAppearance {
    BOOL isDark = [ICAppearanceManager sharedManager].nightSettingMode;

    if (isDark) {
        self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
        self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }

    self.view.backgroundColor = ICBackgroundColor;
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    self.titleLabel.textColor = ICTextColor;
    self.subtitleLabel.textColor = ICMutedTextColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

// MARK: - Custom Header View
- (UIView *)createHeaderView {
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 165)];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, headerView.bounds.size.width - 32, 80)];
    self.titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.titleLabel.text = @"InstacastPlus Changelog".ls;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(18)];
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.textColor = ICTextColor;

    self.subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 80, headerView.bounds.size.width - 32, 75)];
    self.subtitleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.subtitleLabel.text = @"We've been busy making InstacastPlus even smarter, and more powerful. Check out what's new and get ready to experience podcasts like never before!".ls;
    self.subtitleLabel.font = [UIFont systemFontOfSize:ICFontSize(14)];
    self.subtitleLabel.numberOfLines = 0;
    self.subtitleLabel.textAlignment = NSTextAlignmentCenter;
    self.subtitleLabel.textColor = ICMutedTextColor;

    [headerView addSubview:self.titleLabel];
    [headerView addSubview:self.subtitleLabel];

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
        cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(14)];
    }

    cell.textLabel.text = self.changelogItems[indexPath.section][indexPath.row];
    cell.textLabel.textColor = ICTextColor;
    cell.backgroundColor = ICGroupCellBackgroundColor;
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

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.textColor = ICMutedTextColor;
    }
}

@end
