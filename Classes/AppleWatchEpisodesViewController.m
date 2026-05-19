//
//  AppleWatchEpisodesViewController.m
//  Instacast
//

#import "AppleWatchEpisodesViewController.h"
#import "AppleWatchSyncManager.h"
#import "CDModel.h"
#import "DatabaseManager.h"
#import "EpisodeViewController.h"

static NSString* const ICAppleWatchEpisodeCellIdentifier = @"AppleWatchEpisodeCell";
static NSString* const ICAppleWatchMessageCellIdentifier = @"AppleWatchMessageCell";

@interface AppleWatchEpisodesViewController ()

@property (nonatomic, strong) NSArray<AppleWatchEpisodeState*>* states;
@property (nonatomic, strong) UIView* headerContainerView;
@property (nonatomic, strong) UILabel* titleLabel;
@property (nonatomic, strong) UILabel* summaryLabel;
@property (nonatomic, strong) UILabel* syncLabel;
@property (nonatomic, strong) UIButton* syncButton;

@end

@implementation AppleWatchEpisodesViewController

+ (instancetype)viewController
{
    return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Apple Watch".ls;
    self.clearsSelectionOnViewWillAppear = YES;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:ICAppleWatchMessageCellIdentifier];

    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(syncAction:) forControlEvents:UIControlEventValueChanged];

    [self _buildHeaderView];
    [self _reloadDataFromManager];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_managerDidChange:)
                                                 name:ICAppleWatchSyncManagerStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_managerDidChange:)
                                                 name:ICAppleWatchEpisodeStatesDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
    [self.navigationController setToolbarHidden:YES animated:animated];
    [[AppleWatchSyncManager sharedManager] start];
    [self _reloadDataFromManager];
}

- (void)_buildHeaderView
{
    UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 140)];
    header.backgroundColor = ICBackgroundColor;

    UILabel* titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(28)];
    titleLabel.textColor = ICTextColor;
    titleLabel.text = @"Apple Watch".ls;
    [header addSubview:titleLabel];
    self.titleLabel = titleLabel;

    UILabel* summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    summaryLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    summaryLabel.textColor = ICTextColor;
    summaryLabel.numberOfLines = 0;
    [header addSubview:summaryLabel];
    self.summaryLabel = summaryLabel;

    UILabel* syncLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    syncLabel.font = [UIFont systemFontOfSize:ICFontSize(12)];
    syncLabel.textColor = ICMutedTextColor;
    [header addSubview:syncLabel];
    self.syncLabel = syncLabel;

    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Jetzt synchronisieren".ls forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(15)];
    [button addTarget:self action:@selector(syncAction:) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:button];
    self.syncButton = button;

    self.headerContainerView = header;
    self.tableView.tableHeaderView = header;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self _layoutHeaderForWidth:CGRectGetWidth(self.tableView.bounds)];
}

- (void)_layoutHeaderForWidth:(CGFloat)width
{
    CGFloat contentWidth = MAX(0, width - 32);
    CGFloat y = 18;
    self.titleLabel.frame = CGRectMake(16, y, contentWidth, 34);
    y += 40;

    CGSize summarySize = [self.summaryLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    self.summaryLabel.frame = CGRectMake(16, y, contentWidth, ceil(summarySize.height));
    y += ceil(summarySize.height) + 8;

    self.syncLabel.frame = CGRectMake(16, y, contentWidth, 18);
    y += 26;

    CGSize buttonSize = [self.syncButton sizeThatFits:CGSizeMake(contentWidth, 44)];
    self.syncButton.frame = CGRectMake(16, y, MIN(contentWidth, ceil(buttonSize.width)), 36);
    y += 48;

    CGRect headerFrame = self.headerContainerView.frame;
    headerFrame.size.width = width;
    headerFrame.size.height = y;
    if (!CGRectEqualToRect(self.headerContainerView.frame, headerFrame)) {
        self.headerContainerView.frame = headerFrame;
        self.tableView.tableHeaderView = self.headerContainerView;
    }
}

- (void)updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    self.headerContainerView.backgroundColor = ICBackgroundColor;
    self.titleLabel.textColor = ICTextColor;
    self.summaryLabel.textColor = ICTextColor;
    self.syncLabel.textColor = ICMutedTextColor;
    self.syncButton.tintColor = ICTintColor;
    [self.tableView reloadData];
}

- (void)_managerDidChange:(NSNotification*)notification
{
    (void)notification;
    [self _reloadDataFromManager];
}

- (void)_reloadDataFromManager
{
    self.states = [[AppleWatchSyncManager sharedManager] visibleEpisodeStates];
    [self _updateHeaderText];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

- (void)_updateHeaderText
{
    AppleWatchSyncManager* manager = [AppleWatchSyncManager sharedManager];
    NSInteger downloadedCount = 0;
    NSInteger loadingCount = 0;
    for (AppleWatchEpisodeState* state in self.states) {
        if (state.downloadedOnWatch) {
            downloadedCount += 1;
        }
        else if ([state.watchStatus isEqualToString:ICAppleWatchStatusDownloading] ||
                 [state.watchStatus isEqualToString:ICAppleWatchStatusQueuedOnWatch] ||
                 [state.watchStatus isEqualToString:ICAppleWatchStatusManifestSent]) {
            loadingCount += 1;
        }
    }

    if (!manager.supported) {
        self.summaryLabel.text = @"Apple Watch ist auf diesem Gerät nicht verfügbar.".ls;
    }
    else if (!manager.paired) {
        self.summaryLabel.text = @"Keine Apple Watch gekoppelt.".ls;
    }
    else if (!manager.watchAppInstalled) {
        self.summaryLabel.text = @"Die Instacast-Watch-App ist noch nicht installiert.".ls;
    }
    else {
        self.summaryLabel.text = [NSString stringWithFormat:@"%ld auf der Watch\n%ld werden geladen".ls, (long)downloadedCount, (long)loadingCount];
    }

    NSString* syncText = @"Letzte Synchronisierung: nie".ls;
    if (manager.lastSyncDate) {
        NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
        syncText = [NSString stringWithFormat:@"%@ %@", @"Letzte Synchronisierung".ls, [formatter stringFromDate:manager.lastSyncDate]];
    }
    self.syncLabel.text = syncText;
    self.syncButton.enabled = manager.supported && manager.paired && manager.watchAppInstalled;
    [self _layoutHeaderForWidth:CGRectGetWidth(self.tableView.bounds)];
}

- (void)syncAction:(id)sender
{
    (void)sender;
    [[AppleWatchSyncManager sharedManager] syncNow];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return (self.states.count > 0) ? self.states.count : 1;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath
{
    if (self.states.count == 0) {
        UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:ICAppleWatchMessageCellIdentifier forIndexPath:indexPath];
        cell.textLabel.textColor = ICMutedTextColor;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.text = [self _emptyMessage];
        cell.backgroundColor = ICBackgroundColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.image = nil;
        return cell;
    }

    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:ICAppleWatchEpisodeCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ICAppleWatchEpisodeCellIdentifier];
    }
    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];

    cell.backgroundColor = ICBackgroundColor;
    cell.textLabel.textColor = episode.consumed ? ICMutedTextColor : ICTextColor;
    cell.detailTextLabel.textColor = ICMutedTextColor;
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 2;
    cell.textLabel.text = episode.title ?: @"No Title".ls;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n%@", episode.feed.displayTitle ?: episode.feed.title ?: @"", [state localizedStatusText]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
    UIImage* image = [UIImage systemImageNamed:@"applewatch" withConfiguration:config];
    cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    cell.imageView.tintColor = state.downloadedOnWatch ? ICTintColor : ICMutedTextColor;

    return cell;
}

- (NSString*)_emptyMessage
{
    AppleWatchSyncManager* manager = [AppleWatchSyncManager sharedManager];
    if (!manager.supported) {
        return @"Apple Watch ist auf diesem Gerät nicht verfügbar.".ls;
    }
    if (!manager.paired) {
        return @"Kopple eine Apple Watch, um Episoden für die Watch auszuwählen.".ls;
    }
    if (!manager.watchAppInstalled) {
        return @"Installiere die Instacast-Watch-App auf deiner Apple Watch.".ls;
    }
    return @"Keine Episoden für die Apple Watch ausgewählt.".ls;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
    if (self.states.count == 0) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode) {
        return;
    }

    EpisodeViewController* controller = [EpisodeViewController episodeViewController];
    controller.episode = episode;
    [self.navigationController pushViewController:controller animated:YES];
}

- (UIContextMenuConfiguration*)tableView:(UITableView*)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath point:(CGPoint)point
{
    (void)tableView;
    (void)point;
    if (self.states.count == 0 || indexPath.row >= self.states.count) {
        return nil;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode) {
        return nil;
    }

    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu* (NSArray<UIMenuElement*>* suggestedActions) {
        (void)suggestedActions;
        NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];

        if (!state.downloadedOnWatch && !state.removingFromWatch) {
            UIAction* prioritize = [UIAction actionWithTitle:@"Priorisiert auf Watch laden".ls
                                                       image:[UIImage systemImageNamed:@"arrow.down.circle"]
                                                  identifier:nil
                                                     handler:^(__unused UIAction* action) {
                                                         [[AppleWatchSyncManager sharedManager] prioritizeEpisodeOnWatch:episode];
                                                     }];
            [actions addObject:prioritize];
        }

        UIAction* remove = [UIAction actionWithTitle:@"Von Apple Watch entfernen".ls
                                               image:[UIImage systemImageNamed:@"trash"]
                                          identifier:nil
                                             handler:^(__unused UIAction* action) {
                                                 [[AppleWatchSyncManager sharedManager] removeEpisodeFromWatch:episode];
                                             }];
        remove.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:remove];

        return [UIMenu menuWithTitle:episode.title ?: @"" children:actions];
    }];
}

@end
