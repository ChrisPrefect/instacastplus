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

static NSString* const ICAppleWatchEpisodeCellIdentifier = @"AppleWatchEpisodeCell";
static NSString* const ICAppleWatchMessageCellIdentifier = @"AppleWatchMessageCell";

@interface AppleWatchEpisodesViewController ()

@property (nonatomic, strong) NSArray<AppleWatchEpisodeState*>* states;
@property (nonatomic, strong) UIView* headerContainerView;
@property (nonatomic, strong) UILabel* summaryLabel;
@property (nonatomic, strong) UILabel* syncLabel;
@property (nonatomic, strong) UILabel* storageLabel;
@property (nonatomic, strong) UIProgressView* storageProgressView;
@property (nonatomic, strong) UIButton* syncButton;
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
    [self _reloadDataFromManager];
}

- (void)_buildHeaderView
{
    UIView* header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 140)];
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
    storageLabel.numberOfLines = 1;
    [header addSubview:storageLabel];
    self.storageLabel = storageLabel;

    UIProgressView* storageProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    storageProgressView.progressTintColor = ICTintColor;
    storageProgressView.trackTintColor = ICGroupCellSelectedBackgroundColor;
    [header addSubview:storageProgressView];
    self.storageProgressView = storageProgressView;

    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration* configuration = [UIButtonConfiguration tintedButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    configuration.buttonSize = UIButtonConfigurationSizeSmall;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseForegroundColor = ICTintColor;
    configuration.baseBackgroundColor = [ICTintColor colorWithAlphaComponent:0.16];
    button.configuration = configuration;
    button.accessibilityLabel = @"Jetzt synchronisieren".ls;
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
    CGFloat buttonSize = 34;
    CGFloat textWidth = MAX(0, contentWidth - buttonSize - 10);
    BOOL showsSummary = (self.summaryLabel.text.length > 0);

    if (showsSummary) {
        CGSize summarySize = [self.summaryLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        self.summaryLabel.frame = CGRectMake(16, y, textWidth, ceil(summarySize.height));
        self.syncButton.frame = CGRectMake(width - 16 - buttonSize, y, buttonSize, buttonSize);
        y += MAX(ceil(summarySize.height), buttonSize) + 8;

        CGSize syncSize = [self.syncLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
        self.syncLabel.frame = CGRectMake(16, y, contentWidth, MIN(36, ceil(syncSize.height)));
        y += CGRectGetHeight(self.syncLabel.frame) + 8;
    }
    else {
        self.summaryLabel.frame = CGRectZero;
        self.syncButton.frame = CGRectMake(width - 16 - buttonSize, y, buttonSize, buttonSize);
        CGSize syncSize = [self.syncLabel sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        self.syncLabel.frame = CGRectMake(16, y, textWidth, MIN(36, ceil(syncSize.height)));
        y += MAX(CGRectGetHeight(self.syncLabel.frame), buttonSize) + 8;
    }

    self.storageLabel.frame = CGRectMake(16, y, contentWidth, 18);
    y += 21;

    self.storageProgressView.frame = CGRectMake(16, y, contentWidth, 3);
    y += 22;

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
    self.storageProgressView.progressTintColor = ICTintColor;
    self.storageProgressView.trackTintColor = ICGroupCellSelectedBackgroundColor;
    self.syncButton.tintColor = ICTintColor;
    [self _updateSyncButtonConfiguration];
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

    self.syncLabel.text = [self _statusTextForManager:manager];
    self.storageLabel.text = [self _storageTextForManager:manager];
    [self _updateStorageProgressForManager:manager];
    self.syncButton.enabled = manager.supported && manager.paired && manager.watchAppInstalled;
    [self _updateSyncButtonConfiguration];
    [self _layoutHeaderForWidth:CGRectGetWidth(self.tableView.bounds)];
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

- (void)_updateSyncButtonConfiguration
{
    UIButtonConfiguration* configuration = self.syncButton.configuration ?: [UIButtonConfiguration tintedButtonConfiguration];
    configuration.image = [UIImage systemImageNamed:@"arrow.clockwise"];
    configuration.buttonSize = UIButtonConfigurationSizeSmall;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseForegroundColor = self.syncButton.enabled ? ICTintColor : ICMutedTextColor;
    configuration.baseBackgroundColor = [(self.syncButton.enabled ? ICTintColor : ICMutedTextColor) colorWithAlphaComponent:0.16];
    self.syncButton.configuration = configuration;
    self.syncButton.alpha = self.syncButton.enabled ? 1.0 : 0.55;
}

- (NSString*)_storageTextForManager:(AppleWatchSyncManager*)manager
{
    if (!manager.lastWatchStatusDate) {
        return @"Watch-Speicher: wird geladen".ls;
    }

    NSString* used = [self _byteStringForBytes:manager.watchUsedBytes];
    NSString* free = [self _byteStringForBytes:manager.watchFreeBytes];
    return [NSString stringWithFormat:@"Watch-Speicher: %@ belegt, %@ frei".ls, used, free];
}

- (NSString*)_statusTextForManager:(AppleWatchSyncManager*)manager
{
    if (manager.currentWatchDownloadTitle.length > 0 && manager.currentWatchExpectedBytes > 0) {
        NSString* downloaded = [self _byteStringForBytes:manager.currentWatchDownloadedBytes];
        NSString* expected = [self _byteStringForBytes:manager.currentWatchExpectedBytes];
        return [NSString stringWithFormat:@"Watch lädt \"%@\" (%@/%@)".ls, manager.currentWatchDownloadTitle, downloaded, expected];
    }

    if (manager.lastSyncDate) {
        NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
        return [NSString stringWithFormat:@"%@ %@", @"Letzte Synchronisierung".ls, [formatter stringFromDate:manager.lastSyncDate]];
    }
    return @"Letzte Synchronisierung: nie".ls;
}

- (void)_updateStorageProgressForManager:(AppleWatchSyncManager*)manager
{
    float progress = 0.f;
    if (manager.watchTotalBytes > 0) {
        progress = (float)MIN(1.0, MAX(0.0, (double)manager.watchUsedBytes / (double)manager.watchTotalBytes));
    }
    [self.storageProgressView setProgress:progress animated:NO];
}

- (NSString*)_byteStringForBytes:(int64_t)bytes
{
    return [NSByteCountFormatter stringFromByteCount:MAX((int64_t)0, bytes) countStyle:NSByteCountFormatterCountStyleFile];
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

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
    if (!episode) {
        UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:ICAppleWatchMessageCellIdentifier forIndexPath:indexPath];
        cell.textLabel.textColor = ICMutedTextColor;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.text = @"Nicht verfügbar".ls;
        cell.backgroundColor = ICBackgroundColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
    cell.playAccessoryButton.userInteractionEnabled = NO;
    cell.playAccessoryButton.userInfo = nil;
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
        return @"Installiere die InstacastPlus-Watch-App auf deiner Apple Watch.".ls;
    }
    return @"Keine Episoden für die Apple Watch ausgewählt.".ls;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath
{
    (void)indexPath;
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
