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
static NSString* const ICAppleWatchSetupCellIdentifier = @"AppleWatchSetupCell";
static NSUInteger const ICAppleWatchEpisodeLookupBatchSize = 200;
static CGFloat const ICAppleWatchHeaderHorizontalInset = 16.f;
static CGFloat const ICAppleWatchHeaderTopInset = 10.f;
static CGFloat const ICAppleWatchHeaderBottomInset = 10.f;
static CGFloat const ICAppleWatchHeaderSummaryHeight = 20.f;
static CGFloat const ICAppleWatchHeaderLineHeight = 16.f;
static CGFloat const ICAppleWatchHeaderProgressHeight = 4.f;

@interface AppleWatchEpisodesViewController ()

@property (nonatomic, strong) NSArray<AppleWatchEpisodeState*>* states;
@property (nonatomic, copy) NSDictionary<NSString*, CDEpisode*>* episodesByHash;
@property (nonatomic, copy) NSDictionary<NSString*, NSNumber*>* stateIndexByHash;
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
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:ICAppleWatchSetupCellIdentifier];
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
                                             selector:@selector(_liveStatusDidChange:)
                                                 name:ICAppleWatchLiveStatusDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_contextObjectsDidChange:)
                                                 name:NSManagedObjectContextObjectsDidChangeNotification
                                               object:DMANAGER.objectContext];
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
    summaryLabel.numberOfLines = 1;
    summaryLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [header addSubview:summaryLabel];
    self.summaryLabel = summaryLabel;

    UILabel* syncLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    syncLabel.font = [UIFont systemFontOfSize:ICFontSize(12)];
    syncLabel.textColor = ICMutedTextColor;
    syncLabel.numberOfLines = 1;
    syncLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [header addSubview:syncLabel];
    self.syncLabel = syncLabel;

    UILabel* storageLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    storageLabel.font = [UIFont systemFontOfSize:ICFontSize(12)];
    storageLabel.textColor = ICMutedTextColor;
    storageLabel.numberOfLines = 1;
    storageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
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
    CGFloat contentWidth = MAX(0, width - 2 * ICAppleWatchHeaderHorizontalInset);
    CGFloat y = ICAppleWatchHeaderTopInset;
    BOOL showsSummary = (self.summaryLabel.text.length > 0);
    BOOL showsStorage = (self.storageLabel.text.length > 0);
    BOOL reservesStatus = showsStorage;
    BOOL showsStatus = reservesStatus && (self.syncLabel.text.length > 0);

    if (showsSummary) {
        self.summaryLabel.hidden = NO;
        self.summaryLabel.frame = CGRectMake(ICAppleWatchHeaderHorizontalInset, y, contentWidth, ICAppleWatchHeaderSummaryHeight);
        y += ICAppleWatchHeaderSummaryHeight + 10;
    }
    else {
        self.summaryLabel.hidden = YES;
        self.summaryLabel.frame = CGRectZero;
    }

    if (showsStorage) {
        self.storageLabel.hidden = NO;
        self.storageLabel.frame = CGRectMake(ICAppleWatchHeaderHorizontalInset, y, contentWidth, ICAppleWatchHeaderLineHeight);
        y += ICAppleWatchHeaderLineHeight + 5;

        self.storageProgressTrackView.hidden = NO;
        self.storageProgressTrackView.frame = CGRectMake(ICAppleWatchHeaderHorizontalInset, y, contentWidth, ICAppleWatchHeaderProgressHeight);
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

    if (reservesStatus) {
        self.syncLabel.hidden = !showsStatus;
        self.syncLabel.frame = CGRectMake(ICAppleWatchHeaderHorizontalInset, y, contentWidth, ICAppleWatchHeaderLineHeight);
        y += ICAppleWatchHeaderLineHeight + ICAppleWatchHeaderBottomInset;
    }
    else {
        self.syncLabel.hidden = YES;
        self.syncLabel.frame = CGRectZero;
        y += ICAppleWatchHeaderBottomInset;
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
    NSArray<NSString*>* changedHashes = notification.userInfo[ICAppleWatchChangedEpisodeHashesUserInfoKey];
    if ([notification.name isEqualToString:ICAppleWatchEpisodeStatesDidChangeNotification] &&
        [changedHashes isKindOfClass:[NSArray class]] && changedHashes.count > 0) {
        [self _updateHeaderText];
        [self _reloadVisibleRowsForEpisodeHashes:changedHashes];
        [self.refreshControl endRefreshing];
        return;
    }
    [self _reloadDataFromManager];
}

- (void)_liveStatusDidChange:(NSNotification*)notification
{
    [self _updateHeaderText];
    NSArray<NSString*>* changedHashes = notification.userInfo[ICAppleWatchChangedEpisodeHashesUserInfoKey];
    if ([changedHashes isKindOfClass:[NSArray class]] && changedHashes.count > 0) {
        [self _reloadVisibleRowsForEpisodeHashes:changedHashes];
    }
}

- (void)_reloadVisibleRowsForEpisodeHashes:(NSArray<NSString*>*)episodeHashes
{
    if (!self.viewIfLoaded.window || episodeHashes.count == 0) {
        return;
    }
    NSSet<NSString*>* changedHashes = [NSSet setWithArray:episodeHashes];
    NSMutableArray<NSIndexPath*>* affectedIndexPaths = [NSMutableArray array];
    for (NSIndexPath* indexPath in self.tableView.indexPathsForVisibleRows ?: @[]) {
        if (indexPath.row < self.states.count &&
            [changedHashes containsObject:self.states[indexPath.row].episodeHash ?: @""]) {
            [affectedIndexPaths addObject:indexPath];
        }
    }
    if (affectedIndexPaths.count > 0) {
        [self.tableView reloadRowsAtIndexPaths:affectedIndexPaths withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)_reloadDataFromManager
{
    AppleWatchSyncManager* manager = [AppleWatchSyncManager sharedManager];
    NSArray<AppleWatchEpisodeState*>* newStates = nil;
    if (manager.supported && manager.paired && manager.watchAppInstalled) {
        newStates = [manager visibleEpisodeStates];
    }
    else {
        newStates = @[];
    }
    BOOL firstLoad = (self.states == nil);
    BOOL episodeHashesChanged = firstLoad || ![[self _episodeHashesForStates:self.states] isEqualToArray:[self _episodeHashesForStates:newStates]];
    if (episodeHashesChanged) {
        self.episodesByHash = [self _episodesByHashForStates:newStates];
        NSMutableDictionary<NSString*, NSNumber*>* stateIndexByHash = [NSMutableDictionary dictionaryWithCapacity:newStates.count];
        [newStates enumerateObjectsUsingBlock:^(AppleWatchEpisodeState* state, NSUInteger index, BOOL* stop) {
            (void)stop;
            if (state.episodeHash.length > 0) {
                stateIndexByHash[state.episodeHash] = @(index);
            }
        }];
        self.stateIndexByHash = stateIndexByHash;
    }
    self.states = newStates;
    [self _updateHeaderText];
    if (episodeHashesChanged) {
        [self.tableView reloadData];
    }
    else {
        NSArray<NSIndexPath*>* visibleIndexPaths = [self.tableView indexPathsForVisibleRows] ?: @[];
        if (visibleIndexPaths.count > 0) {
            [self.tableView reloadRowsAtIndexPaths:visibleIndexPaths withRowAnimation:UITableViewRowAnimationNone];
        }
    }
    [self.refreshControl endRefreshing];
}

- (NSDictionary<NSString*, CDEpisode*>*)_episodesByHashForStates:(NSArray<AppleWatchEpisodeState*>*)states
{
    NSMutableOrderedSet<NSString*>* hashes = [NSMutableOrderedSet orderedSetWithCapacity:states.count];
    for (AppleWatchEpisodeState* state in states) {
        if (state.episodeHash.length > 0) {
            [hashes addObject:state.episodeHash];
        }
    }

    NSMutableDictionary<NSString*, CDEpisode*>* episodesByHash = [NSMutableDictionary dictionaryWithCapacity:hashes.count];
    NSArray<NSString*>* allHashes = hashes.array;
    for (NSUInteger offset = 0; offset < allHashes.count; offset += ICAppleWatchEpisodeLookupBatchSize) {
        NSRange range = NSMakeRange(offset, MIN(ICAppleWatchEpisodeLookupBatchSize, allHashes.count - offset));
        NSArray<NSString*>* batch = [allHashes subarrayWithRange:range];
        for (CDEpisode* episode in [DMANAGER episodesWithObjectHashes:batch]) {
            if (episode.objectHash.length > 0 && !episode.deleted) {
                episodesByHash[episode.objectHash] = episode;
            }
        }
    }
    return episodesByHash;
}

- (CDEpisode*)_episodeForState:(AppleWatchEpisodeState*)state
{
    return state.episodeHash.length > 0 ? self.episodesByHash[state.episodeHash] : nil;
}

- (void)_contextObjectsDidChange:(NSNotification*)notification
{
    if ([notification.userInfo[NSInvalidatedAllObjectsKey] boolValue]) {
        [self _reloadDataFromManager];
        return;
    }

    NSMutableDictionary<NSString*, CDEpisode*>* updatedEpisodesByHash =
        [self.episodesByHash mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableOrderedSet<NSString*>* changedEpisodeHashes = [NSMutableOrderedSet orderedSet];

    NSMutableSet* removedObjects = [NSMutableSet setWithSet:notification.userInfo[NSDeletedObjectsKey] ?: [NSSet set]];
    [removedObjects unionSet:notification.userInfo[NSInvalidatedObjectsKey] ?: [NSSet set]];
    for (NSManagedObject* object in removedObjects) {
        if (![object isKindOfClass:[CDEpisode class]]) {
            continue;
        }
        CDEpisode* episode = (CDEpisode*)object;
        NSArray<NSString*>* candidateHashes = @[
            episode.objectHash ?: @"",
            [episode.changedValuesForCurrentEvent[@"objectHash"] isKindOfClass:[NSString class]] ?
                episode.changedValuesForCurrentEvent[@"objectHash"] : @"",
        ];
        for (NSString* episodeHash in candidateHashes) {
            if (self.stateIndexByHash[episodeHash]) {
                [updatedEpisodesByHash removeObjectForKey:episodeHash];
                [changedEpisodeHashes addObject:episodeHash];
            }
        }
    }

    NSMutableSet* changedObjects = [NSMutableSet setWithSet:notification.userInfo[NSInsertedObjectsKey] ?: [NSSet set]];
    [changedObjects unionSet:notification.userInfo[NSUpdatedObjectsKey] ?: [NSSet set]];
    [changedObjects unionSet:notification.userInfo[NSRefreshedObjectsKey] ?: [NSSet set]];
    for (NSManagedObject* object in changedObjects) {
        if (![object isKindOfClass:[CDEpisode class]]) {
            continue;
        }
        CDEpisode* episode = (CDEpisode*)object;
        NSString* previousHash = [episode.changedValuesForCurrentEvent[@"objectHash"] isKindOfClass:[NSString class]] ?
            episode.changedValuesForCurrentEvent[@"objectHash"] : nil;
        if (previousHash.length > 0 && ![previousHash isEqualToString:episode.objectHash] && self.stateIndexByHash[previousHash]) {
            [updatedEpisodesByHash removeObjectForKey:previousHash];
            [changedEpisodeHashes addObject:previousHash];
        }
        if (episode.objectHash.length > 0 && self.stateIndexByHash[episode.objectHash]) {
            if (episode.deleted) {
                [updatedEpisodesByHash removeObjectForKey:episode.objectHash];
            }
            else {
                updatedEpisodesByHash[episode.objectHash] = episode;
            }
            [changedEpisodeHashes addObject:episode.objectHash];
        }
    }

    if (changedEpisodeHashes.count > 0) {
        self.episodesByHash = updatedEpisodesByHash;
        [self _reloadVisibleRowsForEpisodeHashes:changedEpisodeHashes.array];
    }
}

- (NSArray<NSString*>*)_episodeHashesForStates:(NSArray<AppleWatchEpisodeState*>*)states
{
    NSMutableArray<NSString*>* hashes = [NSMutableArray arrayWithCapacity:states.count];
    for (AppleWatchEpisodeState* state in states) {
        [hashes addObject:state.episodeHash ?: @""];
    }
    return hashes;
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
    else if ([manager watchStorageFull]) {
        // Only surfaced when the watch could not keep a single episode — the rare case where the
        // user actually has to act. Normal over-subscription is managed silently.
        self.summaryLabel.text = @"Kein Platz auf der Apple Watch – gib Speicher frei, um Folgen zu laden.".ls;
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
    // Aggregated over the whole wanted set instead of the per-download value, which flipped
    // between episodes while several were loading (User-Feedback 05.07.).
    int64_t loadedBytes = 0;
    int64_t totalBytes = 0;
    BOOL totalBytesKnown = NO;
    ICAppleWatchTransferPhase phase = [manager watchDownloadProgressLoadedBytes:&loadedBytes
                                                                      totalBytes:&totalBytes
                                                                 totalBytesKnown:&totalBytesKnown];
    if (phase == ICAppleWatchTransferPhaseDownloading) {
        if (totalBytesKnown && totalBytes > 0) {
            NSString* downloaded = [self _byteStringForBytes:loadedBytes];
            NSString* total = [self _byteStringForBytes:totalBytes];
            return [NSString stringWithFormat:@"Watch lädt Podcasts (%@ von %@)".ls, downloaded, total];
        }
        return @"Watch lädt Podcasts…".ls;
    }
    if (phase == ICAppleWatchTransferPhaseWaiting) {
        return @"Wartet auf Apple Watch…".ls;
    }

    return nil;
}

- (NSString*)_failureGuidanceForState:(AppleWatchEpisodeState*)state
{
    if ([[AppleWatchSyncManager sharedManager] hasLiveDownloadProgressForEpisodeHash:state.episodeHash
                                                               selectionIdentifier:state.uid]) {
        return nil;
    }
    if (![state.watchStatus isEqualToString:ICAppleWatchStatusFailed]) {
        return nil;
    }
    NSString* retryGuidance = @"Nach rechts wischen, um erneut zu laden.".ls;
    NSString* reason = [state.watchLastError stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (reason.length > 0) {
        return [NSString stringWithFormat:@"%@ %@", reason, retryGuidance];
    }
    return [NSString stringWithFormat:@"%@ %@", @"Download fehlgeschlagen.".ls, retryGuidance];
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
        BOOL opensWatchApp = [self _emptyMessageOpensWatchApp];
        if (opensWatchApp) {
            UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:ICAppleWatchSetupCellIdentifier forIndexPath:indexPath];
            [self _configureWatchSetupCell:cell];
            return cell;
        }

        UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:ICAppleWatchMessageCellIdentifier forIndexPath:indexPath];
        cell.textLabel.textColor = ICMutedTextColor;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.text = [self _emptyMessage];
        cell.backgroundColor = ICBackgroundColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.imageView.image = nil;
        return cell;
    }

    AppleWatchEpisodeState* state = self.states[indexPath.row];
    CDEpisode* episode = [self _episodeForState:state];
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
    cell.usesNativeSwipeActions = YES;
    cell.topSeparator = (indexPath.row > 0);
    [cell.playAccessoryButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.playAccessoryButton addTarget:self action:@selector(playComboButtonAction:) forControlEvents:UIControlEventTouchUpInside];
    cell.playAccessoryButton.userInteractionEnabled = YES;
    cell.playAccessoryButton.userInfo = episode;
    cell.objectValue = episode;
    NSString* failureGuidance = [self _failureGuidanceForState:state];
    cell.supplementalStatusText = failureGuidance;
    if (failureGuidance) {
        cell.supplementalStatusTextColor = UIColor.systemOrangeColor;
    }
    else {
        cell.supplementalStatusTextColor = nil;
    }
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

- (void)_configureWatchSetupCell:(UITableViewCell*)cell
{
    for (UIView* subview in [cell.contentView.subviews copy]) {
        [subview removeFromSuperview];
    }
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = ICBackgroundColor;

    UILabel* label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = [self _emptyMessage];
    label.textColor = ICMutedTextColor;
    label.font = [UIFont systemFontOfSize:ICFontSize(15)];
    label.numberOfLines = 0;

    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:@"Watch-App öffnen".ls forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(15)];
    [button addTarget:self action:@selector(_watchInstallButtonAction:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, button]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentLeading;
    stack.spacing = 10;
    [cell.contentView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],
    ]];
}

- (BOOL)_emptyMessageOpensWatchApp
{
    AppleWatchSyncManager* manager = [AppleWatchSyncManager sharedManager];
    return manager.supported && manager.paired && !manager.watchAppInstalled;
}

- (void)_watchInstallButtonAction:(UIButton*)button
{
    (void)button;
    [self _openWatchApp];
}

- (void)_openWatchApp
{
    NSURL* url = [NSURL URLWithString:@"itms-watchs://"];
    if (!url) {
        return;
    }

    UIApplication* application = [UIApplication sharedApplication];
    [application openURL:url options:@{} completionHandler:nil];
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
    CDEpisode* episode = [self _episodeForState:state];
    if (!episode) {
        return UITableViewAutomaticDimension;
    }

    return [EpisodesTableViewCell proposedHeightWithObjectValue:episode
                                                      tableSize:tableView.bounds.size
                                                      imageSize:CGSizeMake(56, 56)
                                                       embedded:NO
                                                        editing:tableView.editing
                                                     upNextStyle:NO
                                                   summaryOverride:[self _failureGuidanceForState:state]];
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
    [[AppleWatchSyncManager sharedManager] removeEpisodeStateFromWatch:state];
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

    UIContextualAction* removeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:@"Entfernen".ls
                                                                             handler:^(__unused UIContextualAction* action, __unused UIView* sourceView, void (^completionHandler)(BOOL)) {
                                                                                 [[AppleWatchSyncManager sharedManager] removeEpisodeStateFromWatch:state];
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
    CDEpisode* episode = [self _episodeForState:state];
    if (!episode || state.downloadedOnWatch || state.removingFromWatch) {
        return nil;
    }

    NSString* title = [state.watchStatus isEqualToString:ICAppleWatchStatusFailed] ? @"Wiederholen".ls : @"Laden".ls;
    NSString* symbolName = [state.watchStatus isEqualToString:ICAppleWatchStatusFailed] ? @"arrow.clockwise" : @"arrow.down.circle";
    UIContextualAction* prioritizeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                                  title:title
                                                                                handler:^(__unused UIContextualAction* action, __unused UIView* sourceView, void (^completionHandler)(BOOL)) {
                                                                                    [[AppleWatchSyncManager sharedManager] prioritizeEpisodeOnWatch:episode];
                                                                                    completionHandler(YES);
                                                                                }];
    prioritizeAction.image = [UIImage systemImageNamed:symbolName];
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
    CDEpisode* episode = [self _episodeForState:state];

    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu* (NSArray<UIMenuElement*>* suggestedActions) {
        (void)suggestedActions;
        NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];

        if (episode && !state.downloadedOnWatch && !state.removingFromWatch) {
            BOOL retriesFailure = [state.watchStatus isEqualToString:ICAppleWatchStatusFailed];
            NSString* title = retriesFailure ? @"Download erneut versuchen".ls : @"Priorisiert auf Watch laden".ls;
            NSString* symbolName = retriesFailure ? @"arrow.clockwise" : @"arrow.down.circle";
            UIAction* prioritize = [UIAction actionWithTitle:title
                                                       image:[UIImage systemImageNamed:symbolName]
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
                                                 [[AppleWatchSyncManager sharedManager] removeEpisodeStateFromWatch:state];
                                             }];
        remove.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:remove];

        return [UIMenu menuWithTitle:episode.title ?: @"Nicht verfügbar".ls children:actions];
    }];
}

@end
