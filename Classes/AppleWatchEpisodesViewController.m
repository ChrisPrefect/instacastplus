//
//  AppleWatchEpisodesViewController.m
//  Instacast
//

#import "AppleWatchEpisodesViewController.h"
#import "AppleWatchSyncManager.h"
#import "CDModel.h"
#import "DatabaseManager.h"
#import "EpisodePlayComboButton.h"
#import "EpisodesTableViewCell.h"
#import "ImageCacheManager.h"
#import "AudioSession.h"
#import "PlaybackViewController.h"
#import <math.h>

static NSString* const ICAppleWatchEpisodeCellIdentifier = @"AppleWatchEpisodeCell";
static NSString* const ICAppleWatchMessageCellIdentifier = @"AppleWatchMessageCell";

@interface AppleWatchEpisodesViewController ()

@property (nonatomic, strong) NSArray<AppleWatchEpisodeState*>* states;
@property (nonatomic, strong) UIView* headerContainerView;
@property (nonatomic, strong) UILabel* summaryLabel;
@property (nonatomic, strong) UILabel* syncLabel;
@property (nonatomic, strong) UILabel* storageLabel;
@property (nonatomic, strong) UIView* storageProgressTrackView;
@property (nonatomic, strong) UIView* storageUsedProgressView;
@property (nonatomic, strong) UIView* storagePodcastProgressView;
@property (nonatomic, strong) UIBarButtonItem* editIconButtonItem;

@end

@implementation AppleWatchEpisodesViewController

+ (instancetype)viewController
{
    return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Folgen auf Apple Watch".ls;
    self.clearsSelectionOnViewWillAppear = YES;
    self.editIconButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(toggleEditMode:)];
    self.navigationItem.rightBarButtonItem = self.editIconButtonItem;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:ICAppleWatchMessageCellIdentifier];
    [self.tableView registerClass:[EpisodesTableViewCell class] forCellReuseIdentifier:ICAppleWatchEpisodeCellIdentifier];

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
    [[AppleWatchSyncManager sharedManager] syncNow];
    [self _reloadDataFromManager];
}

- (void)_buildHeaderView
{
    UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 104)];
    header.backgroundColor = ICBackgroundColor;

    UILabel* summaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    summaryLabel.font = [UIFont systemFontOfSize:ICFontSize(15)];
    summaryLabel.textColor = ICTextColor;
    summaryLabel.numberOfLines = 0;
    [header addSubview:summaryLabel];
    self.summaryLabel = summaryLabel;

    UILabel* syncLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    syncLabel.font = [UIFont systemFontOfSize:ICFontSize(12)];
    syncLabel.textColor = ICMutedTextColor;
    syncLabel.numberOfLines = 2;
    [header addSubview:syncLabel];
    self.syncLabel = syncLabel;

    UILabel* storageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    storageLabel.font = [UIFont systemFontOfSize:ICFontSize(12)];
    storageLabel.textColor = ICMutedTextColor;
    storageLabel.numberOfLines = 2;
    [header addSubview:storageLabel];
    self.storageLabel = storageLabel;

    UIView* storageProgressTrackView = [[UIView alloc] initWithFrame:CGRectZero];
    storageProgressTrackView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    storageProgressTrackView.clipsToBounds = YES;
    [header addSubview:storageProgressTrackView];
    self.storageProgressTrackView = storageProgressTrackView;

    UIView* storageUsedProgressView = [[UIView alloc] initWithFrame:CGRectZero];
    storageUsedProgressView.backgroundColor = [ICMutedTextColor colorWithAlphaComponent:0.24];
    [storageProgressTrackView addSubview:storageUsedProgressView];
    self.storageUsedProgressView = storageUsedProgressView;

    UIView* storagePodcastProgressView = [[UIView alloc] initWithFrame:CGRectZero];
    storagePodcastProgressView.backgroundColor = ICTintColor;
    [storageProgressTrackView addSubview:storagePodcastProgressView];
    self.storagePodcastProgressView = storagePodcastProgressView;

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
    CGFloat y = 10;
    BOOL showsSummary = (self.summaryLabel.text.length > 0);
    BOOL showsStorage = (self.storageLabel.text.length > 0);
    BOOL showsStatus = (self.syncLabel.text.length > 0);

    if (showsSummary) {
        CGSize summarySize = [self.summaryLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
        self.summaryLabel.frame = CGRectMake(16, y, contentWidth, ceil(summarySize.height));
        y += ceil(summarySize.height) + 10;
    }
    else {
        self.summaryLabel.frame = CGRectZero;
    }

    if (showsStorage) {
        self.storageLabel.hidden = NO;
        CGSize storageSize = [self.storageLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
        self.storageLabel.frame = CGRectMake(16, y, contentWidth, MIN(38, ceil(storageSize.height)));
        y += CGRectGetHeight(self.storageLabel.frame) + 5;

        self.storageProgressTrackView.hidden = NO;
        self.storageProgressTrackView.frame = CGRectMake(16, y, contentWidth, 4);
        self.storageProgressTrackView.layer.cornerRadius = 2;
        self.storageUsedProgressView.layer.cornerRadius = 2;
        self.storagePodcastProgressView.layer.cornerRadius = 2;
        [self _updateStorageProgressForManager:[AppleWatchSyncManager sharedManager]];
        y += 12;
    }
    else {
        self.storageLabel.hidden = YES;
        self.storageLabel.frame = CGRectZero;
        self.storageProgressTrackView.hidden = YES;
        self.storageProgressTrackView.frame = CGRectZero;
        self.storageUsedProgressView.frame = CGRectZero;
        self.storagePodcastProgressView.frame = CGRectZero;
    }

    if (showsStatus) {
        CGSize syncSize = [self.syncLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
        self.syncLabel.hidden = NO;
        self.syncLabel.frame = CGRectMake(16, y, contentWidth, MIN(38, ceil(syncSize.height)));
        y += CGRectGetHeight(self.syncLabel.frame) + 10;
    }
    else {
        self.syncLabel.hidden = YES;
        self.syncLabel.frame = CGRectZero;
        y += 4;
    }

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
    self.summaryLabel.textColor = ICTextColor;
    self.syncLabel.textColor = ICMutedTextColor;
    self.storageLabel.textColor = ICMutedTextColor;
    self.storageProgressTrackView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    self.storageUsedProgressView.backgroundColor = [ICMutedTextColor colorWithAlphaComponent:0.24];
    self.storagePodcastProgressView.backgroundColor = ICTintColor;
    [self _updateStorageProgressForManager:[AppleWatchSyncManager sharedManager]];
    [self.tableView reloadData];
}

- (void)_managerDidChange:(NSNotification*)notification
{
    (void)notification;
    [self _reloadDataFromManager];
}

- (void)_reloadDataFromManager
{
    AppleWatchSyncManager* manager = [AppleWatchSyncManager sharedManager];
    if (manager.supported && manager.paired && manager.watchAppInstalled) {
        self.states = [manager visibleEpisodeStates];
    }
    else {
        self.states = @[];
    }
    [self _updateHeaderText];
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

- (void)_updateHeaderText
{
    AppleWatchSyncManager* manager = [AppleWatchSyncManager sharedManager];

    BOOL canManageWatchApp = (manager.supported && manager.paired && manager.watchAppInstalled);

    if (!manager.supported) {
        self.summaryLabel.text = @"Apple Watch ist auf diesem Gerät nicht verfügbar.".ls;
    }
    else if (!manager.paired) {
        self.summaryLabel.text = @"Keine Apple Watch gekoppelt.".ls;
    }
    else if (!manager.watchAppInstalled) {
        self.summaryLabel.text = @"Die InstacastPlus-Watch-App ist noch nicht installiert.".ls;
    }
    else {
        self.summaryLabel.text = nil;
    }

    self.syncLabel.text = canManageWatchApp ? [self _statusTextForManager:manager] : nil;
    self.storageLabel.text = canManageWatchApp ? [self _storageTextForManager:manager] : nil;
    self.navigationItem.rightBarButtonItem = canManageWatchApp ? self.editIconButtonItem : nil;
    if (!canManageWatchApp && self.editing) {
        [self setEditing:NO animated:YES];
    }
    [self _layoutHeaderForWidth:CGRectGetWidth(self.tableView.bounds)];
    [self _updateStorageProgressForManager:manager];
}

- (void)toggleEditMode:(id)sender
{
    (void)sender;
    [self setEditing:!self.editing animated:YES];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
    self.editIconButtonItem.image = [UIImage systemImageNamed:(editing ? @"checkmark" : @"pencil")];
}

- (void)syncAction:(id)sender
{
    (void)sender;
    [[AppleWatchSyncManager sharedManager] syncNow];
}

- (NSString*)_storageTextForManager:(AppleWatchSyncManager*)manager
{
    if (!manager.lastWatchStatusDate) {
        return @"Speicher: wird geladen".ls;
    }

    NSString* free = [self _byteStringForBytes:manager.watchFreeBytes];
    int64_t totalBytes = MAX(manager.watchTotalBytes, manager.watchUsedBytes + manager.watchFreeBytes);
    NSString* total = [self _byteStringForBytes:totalBytes];
    NSString* podcasts = [self _byteStringForBytes:manager.watchDownloadBytes];
    return [NSString stringWithFormat:@"Speicher: %@ von %@ frei, %@ Podcasts".ls, free, total, podcasts];
}

- (NSString*)_statusTextForManager:(AppleWatchSyncManager*)manager
{
    if (manager.currentWatchDownloadTitle.length > 0 && manager.currentWatchExpectedBytes > 0) {
        NSString* downloaded = [self _byteStringForBytes:manager.currentWatchDownloadedBytes];
        NSString* expected = [self _byteStringForBytes:manager.currentWatchExpectedBytes];
        return [NSString stringWithFormat:@"Watch lädt \"%@\" (%@/%@)".ls, manager.currentWatchDownloadTitle, downloaded, expected];
    }

    return nil;
}

- (void)_updateStorageProgressForManager:(AppleWatchSyncManager*)manager
{
    CGFloat width = CGRectGetWidth(self.storageProgressTrackView.bounds);
    CGFloat height = CGRectGetHeight(self.storageProgressTrackView.bounds);
    if (width <= 0 || height <= 0) {
        self.storageUsedProgressView.frame = CGRectZero;
        self.storagePodcastProgressView.frame = CGRectZero;
        return;
    }

    double totalBytes = MAX((double)manager.watchTotalBytes, (double)(manager.watchUsedBytes + manager.watchFreeBytes));
    double usedFraction = totalBytes > 0 ? MIN(1.0, MAX(0.0, (double)manager.watchUsedBytes / totalBytes)) : 0.0;
    double podcastFraction = totalBytes > 0 ? MIN(usedFraction, MAX(0.0, (double)manager.watchDownloadBytes / totalBytes)) : 0.0;

    self.storageUsedProgressView.frame = CGRectMake(0, 0, width * usedFraction, height);
    self.storagePodcastProgressView.frame = CGRectMake(0, 0, width * podcastFraction, height);
}

- (NSString*)_byteStringForBytes:(int64_t)bytes
{
    double safeBytes = (double)MAX((int64_t)0, bytes);
    double gigabyte = 1000.0 * 1000.0 * 1000.0;
    double megabyte = 1000.0 * 1000.0;
    if (safeBytes >= gigabyte) {
        double value = safeBytes / gigabyte;
        double rounded = round(value);
        if (fabs(value - rounded) < 0.05) {
            return [NSString stringWithFormat:@"%.0fGB", rounded];
        }
        return [NSString stringWithFormat:@"%.1fGB", value];
    }

    if (safeBytes >= megabyte) {
        return [NSString stringWithFormat:@"%.0fMB", round(safeBytes / megabyte)];
    }

    return [NSString stringWithFormat:@"%.0fKB", round(safeBytes / 1000.0)];
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
        BOOL opensWatchApp = [self _emptyMessageOpensWatchApp];
        cell.textLabel.textColor = opensWatchApp ? ICTintColor : ICMutedTextColor;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.text = [self _emptyMessage];
        cell.backgroundColor = ICBackgroundColor;
        cell.selectionStyle = opensWatchApp ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.accessoryType = opensWatchApp ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
        cell.imageView.image = nil;
        return cell;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode) {
        UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:ICAppleWatchMessageCellIdentifier forIndexPath:indexPath];
        cell.textLabel.textColor = ICMutedTextColor;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.text = @"Nicht verfügbar".ls;
        cell.backgroundColor = ICBackgroundColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.imageView.image = nil;
        return cell;
    }

    EpisodesTableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:ICAppleWatchEpisodeCellIdentifier forIndexPath:indexPath];
    cell.backgroundColor = self.tableView.backgroundColor;
    cell.tintColor = self.view.tintColor;
    cell.embedded = NO;
    cell.upNextStyle = NO;
    cell.showsPlaybackProgress = NO;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.panRecognizer.enabled = NO;
    cell.topSeparator = (indexPath.row > 0);
    [cell.playAccessoryButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.playAccessoryButton addTarget:self action:@selector(playComboButtonAction:) forControlEvents:UIControlEventTouchUpInside];
    cell.playAccessoryButton.userInteractionEnabled = YES;
    cell.playAccessoryButton.userInfo = episode;
    cell.objectValue = episode;
    cell.iconView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];

    NSURL* imageURL = episode.imageURL ?: episode.feed.imageURL;
    ImageCacheManager* imageCacheManager = [ImageCacheManager sharedImageCacheManager];
    __weak EpisodesTableViewCell* weakCell = cell;
    [imageCacheManager imageForURL:imageURL size:56 grayscale:episode.consumed sender:cell completion:^(UIImage* image) {
        EpisodesTableViewCell* strongCell = weakCell;
        if (!strongCell || !image || strongCell.objectValue != episode) {
            return;
        }
        strongCell.iconView.image = image;
    }];

    return cell;
}

- (BOOL)_emptyMessageOpensWatchApp
{
    AppleWatchSyncManager* manager = [AppleWatchSyncManager sharedManager];
    return manager.supported && manager.paired && !manager.watchAppInstalled;
}

- (void)_openWatchApp
{
    NSURL* url = [NSURL URLWithString:@"itms-watchs://"];
    if (!url) {
        return;
    }

    UIApplication* application = [UIApplication sharedApplication];
    if (@available(iOS 10.0, *)) {
        [application openURL:url options:@{} completionHandler:nil];
    }
    else {
        [application openURL:url];
    }
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
        return @"Installiere die InstacastPlus-Watch-App über die Watch-App auf deinem iPhone. Scrolle dort ganz nach unten zu \"Verfügbare Apps\" und tippe bei InstacastPlus auf Installieren.".ls;
    }
    return @"Keine Episoden für die Apple Watch ausgewählt.".ls;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)indexPath;
    if (self.states.count == 0 && [self _emptyMessageOpensWatchApp]) {
        [self _openWatchApp];
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (CGFloat)tableView:(UITableView*)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)tableView;
    (void)indexPath;
    return self.states.count == 0 ? 64.f : 72.f;
}

- (CGFloat)tableView:(UITableView*)tableView heightForRowAtIndexPath:(NSIndexPath*)indexPath
{
    if (self.states.count == 0 || indexPath.row >= self.states.count) {
        return UITableViewAutomaticDimension;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode) {
        return UITableViewAutomaticDimension;
    }

    return [EpisodesTableViewCell proposedHeightWithObjectValue:episode
                                                      tableSize:tableView.bounds.size
                                                      imageSize:CGSizeMake(56, 56)
                                                       embedded:NO
                                                        editing:tableView.editing];
}

- (BOOL)tableView:(UITableView*)tableView canEditRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)tableView;
    return self.states.count > 0 && indexPath.row < self.states.count;
}

- (UITableViewCellEditingStyle)tableView:(UITableView*)tableView editingStyleForRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)tableView;
    (void)indexPath;
    return UITableViewCellEditingStyleDelete;
}

- (BOOL)tableView:(UITableView*)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView*)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath*)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.row >= self.states.count) {
        return;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode) {
        return;
    }

    [[AppleWatchSyncManager sharedManager] removeEpisodeFromWatch:episode];
}

- (BOOL)tableView:(UITableView*)tableView canMoveRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)tableView;
    return self.states.count > 0 && indexPath.row < self.states.count;
}

- (void)tableView:(UITableView*)tableView moveRowAtIndexPath:(NSIndexPath*)sourceIndexPath toIndexPath:(NSIndexPath*)destinationIndexPath
{
    (void)tableView;
    if (sourceIndexPath.row == destinationIndexPath.row) {
        return;
    }

    NSMutableArray<AppleWatchEpisodeState*>* states = [self.states mutableCopy];
    AppleWatchEpisodeState* state = states[sourceIndexPath.row];
    [states removeObjectAtIndex:sourceIndexPath.row];
    [states insertObject:state atIndex:destinationIndexPath.row];
    self.states = states;
    [[AppleWatchSyncManager sharedManager] moveEpisodeAtIndex:sourceIndexPath.row toIndex:destinationIndexPath.row];
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)tableView;
    if (self.states.count == 0 || indexPath.row >= self.states.count) {
        return nil;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode) {
        return nil;
    }

    UIContextualAction* removeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:@"Entfernen".ls
                                                                             handler:^(__unused UIContextualAction* action, __unused UIView* sourceView, void (^completionHandler)(BOOL)) {
                                                                                 [[AppleWatchSyncManager sharedManager] removeEpisodeFromWatch:episode];
                                                                                 completionHandler(YES);
                                                                             }];
    removeAction.image = [UIImage systemImageNamed:@"trash"];

    return [UISwipeActionsConfiguration configurationWithActions:@[removeAction]];
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)tableView;
    if (self.states.count == 0 || indexPath.row >= self.states.count) {
        return nil;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode || state.downloadedOnWatch || state.removingFromWatch) {
        return nil;
    }

    UIContextualAction* prioritizeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                                  title:@"Laden".ls
                                                                                handler:^(__unused UIContextualAction* action, __unused UIView* sourceView, void (^completionHandler)(BOOL)) {
                                                                                    [[AppleWatchSyncManager sharedManager] prioritizeEpisodeOnWatch:episode];
                                                                                    completionHandler(YES);
                                                                                }];
    prioritizeAction.image = [UIImage systemImageNamed:@"arrow.down.circle"];
    prioritizeAction.backgroundColor = ICTintColor;

    return [UISwipeActionsConfiguration configurationWithActions:@[prioritizeAction]];
}

- (void)playComboButtonAction:(EpisodePlayComboButton*)button
{
    CDEpisode* episode = (CDEpisode*)button.userInfo;
    if (!episode) {
        return;
    }

    BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
    PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:!alreadyPlaying];
    [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
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
