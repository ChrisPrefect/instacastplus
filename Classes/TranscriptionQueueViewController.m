//
//  TranscriptionQueueViewController.m
//  Instacast
//
//  Transcription queue — consistent with DownloadsViewController.
//

#import "TranscriptionQueueViewController.h"
#import "DownloadsTableViewCell.h"
#import "EpisodePlayComboButton.h"
#import "ICEpisodeSwipeActionHandler.h"
#import "CDEpisode+ShowNotes.h"
#import "PlaybackViewController.h"
#import "CacheManager.h"
#import "InstacastPlus-Swift.h"
#import "InstacastAppDelegate.h"
#import <BackgroundTasks/BackgroundTasks.h>

// Shared by the queue row and its detail screen: only measured or scheduled facts.
static NSString* ICServerTranscriptionTitle(ICTranscriptionQueueItem* item) {
    if (item.status == ICTranscriptionStatusCompleted) return NSLocalizedString(@"Ready to use", nil);
    if (item.status == ICTranscriptionStatusCanceled) return NSLocalizedString(@"Canceled", nil);
    if (item.requiresExplicitRetryAfterCrash) return NSLocalizedString(@"Status needs checking", nil);
    if (item.status == ICTranscriptionStatusFailed) return [item.serverPhase isEqualToString:@"importing"]
        ? NSLocalizedString(@"Result could not be saved", nil) : NSLocalizedString(@"Transcription stopped", nil);
    if (item.serverWaitingForNetwork) return NSLocalizedString(@"Waiting for internet", nil);
    if (item.serverConnectionIssue) return NSLocalizedString(@"Connection interrupted", nil);
    NSDictionary* titles = @{
        @"paused": NSLocalizedString(@"Processing paused", nil),
        @"checking_audio": NSLocalizedString(@"Checking audio", nil),
        @"sending": NSLocalizedString(@"Sending request", nil),
        @"checking_request": NSLocalizedString(@"Checking saved request", nil),
        @"queued": NSLocalizedString(@"Waiting on the server", nil),
        @"downloading_audio": NSLocalizedString(@"Server is downloading audio", nil),
        @"transcribing": NSLocalizedString(@"Creating transcript", nil),
        @"analyzing": NSLocalizedString(@"Creating chapters and summary", nil),
        @"finalizing": NSLocalizedString(@"Server is preparing results", nil),
        @"ready": NSLocalizedString(@"Retrieving results", nil),
        @"importing": NSLocalizedString(@"Saving results on this device", nil)
    };
    return titles[item.serverPhase ?: @""] ?: NSLocalizedString(@"Preparing request", nil);
}

static NSString* ICServerTranscriptionNextAction(ICTranscriptionQueueItem* item) {
    if (item.status == ICTranscriptionStatusCompleted) return NSLocalizedString(@"The transcript, chapters and summary are available in the player.", nil);
    if (item.status == ICTranscriptionStatusCanceled) return NSLocalizedString(@"This request will not restart automatically.", nil);
    if (item.requiresExplicitRetryAfterCrash) return NSLocalizedString(@"Automatic checks have stopped. Check this saved request again; this will not create a new transcription.", nil);
    if (item.status == ICTranscriptionStatusFailed) return [item.serverPhase isEqualToString:@"importing"]
        ? NSLocalizedString(@"The server result remains available. Retry retrieving it without transcribing again.", nil)
        : NSLocalizedString(@"No further attempt is scheduled. Resolve the reason above, then try again.", nil);
    if (item.serverWaitingForNetwork) return NSLocalizedString(@"Continues automatically when this app has internet access. In the background, iOS decides when the app can run; opening the app resumes it immediately.", nil);
    NSMutableArray* lines = [NSMutableArray array];
    if (item.nextRetryAt) {
        if (item.nextRetryAt.timeIntervalSinceNow > 0) {
            NSString* time = [NSDateFormatter localizedStringFromDate:item.nextRetryAt dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
            [lines addObject:[NSString stringWithFormat:NSLocalizedString(@"Next status check in this app: %@", nil), time]];
        } else {
            [lines addObject:NSLocalizedString(@"The next status check is due and will run when the app can connect.", nil)];
        }
    } else {
        [lines addObject:NSLocalizedString(@"This step is in progress. The status updates automatically.", nil)];
    }
    if ([[ServerTranscriptionManager shared] hasConfirmedAdmissionForEpisodeHash:item.episodeHash] &&
        ![@[@"importing", @"ready"] containsObject:item.serverPhase ?: @""]) {
        [lines addObject:NSLocalizedString(@"The server does not provide a remaining time.", nil)];
        [lines addObject:NSLocalizedString(@"You can leave this screen. Server processing continues independently; this app retrieves the result when it can run.", nil)];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static NSString* ICServerTranscriptionReason(ICTranscriptionQueueItem* item) {
    if (item.status == ICTranscriptionStatusFailed) return item.error;
    if (item.status == ICTranscriptionStatusCompleted || item.status == ICTranscriptionStatusCanceled) return nil;
    // The headline already names a confirmed phase. Keep interruptions and their reasons visible.
    if (!item.serverConnectionIssue && !item.serverWaitingForNetwork && !item.requiresExplicitRetryAfterCrash &&
        [@[@"queued", @"downloading_audio", @"transcribing", @"analyzing", @"finalizing", @"importing"] containsObject:item.serverPhase ?: @""]) return nil;
    return item.statusDetail;
}

static NSString* ICServerTranscriptionStatusText(ICTranscriptionQueueItem* item) {
    // Keep the overview scannable; precise timing and recovery live on the status page.
    NSString* detail = ICServerTranscriptionReason(item);
    if (item.status == ICTranscriptionStatusCompleted) detail = NSLocalizedString(@"Transcript, chapters and summary saved", nil);
    if (item.status == ICTranscriptionStatusCanceled) detail = nil;
    NSString* title = ICServerTranscriptionTitle(item);
    return detail.length ? [NSString stringWithFormat:@"%@\n%@", title, detail] : title;
}

@interface ICTranscriptionQueueCell : DownloadsTableViewCell
@property (nonatomic) BOOL serverItem;
@end

@implementation ICTranscriptionQueueCell

- (void)layoutSubviews {
    UIColor* statusColor = self.sizeLabel.textColor;
    [super layoutSubviews];
    if (self.serverItem) {
        self.sizeLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
        self.sizeLabel.textColor = statusColor;
        CGRect titleFrame = self.textLabel.frame;
        titleFrame.size.height = ceil(self.textLabel.font.lineHeight);
        self.textLabel.frame = titleFrame;
    }
    if (self.sizeLabel.numberOfLines != 0) return;

    CGRect bounds = self.contentView.bounds;
    if (self.showsErrorStatus) {
        CGRect statusFrame = self.sizeLabel.frame;
        if (self.serverItem) statusFrame.origin.y = CGRectGetMaxY(self.textLabel.frame) + 3;
        statusFrame.size.height = MAX(0, CGRectGetHeight(bounds) - CGRectGetMinY(statusFrame) - 7);
        self.sizeLabel.frame = statusFrame;
        return;
    }

    CGFloat textLeft = CGRectGetMinX(self.textLabel.frame);
    CGFloat textWidth = CGRectGetWidth(self.textLabel.frame);
    CGFloat statusTop = self.serverItem ? MAX(32, CGRectGetMaxY(self.textLabel.frame) + 3) : 47;
    self.progressView.frame = CGRectMake(textLeft, 34, textWidth, 10);
    self.sizeLabel.frame = CGRectMake(textLeft, statusTop, textWidth, MAX(0, CGRectGetHeight(bounds) - statusTop - 7));

    if (self.timeLabel.text.length > 0 && self.rightContentAccessoryView.superview == self.contentView) {
        CGFloat accessoryWidth = MAX(44, ceilf(self.rightContentAccessoryView.intrinsicContentSize.width));
        self.timeLabel.frame = CGRectMake(CGRectGetMaxX(bounds) - accessoryWidth - 5, 47, accessoryWidth, 16);
        self.timeLabel.hidden = NO;
    }
}

@end

// MARK: - Log Detail View

// Presented when the user taps the (i) accessory on a queued/finished transcription.
// Shows the full per-episode log (times, phases, durations, sizes, char/chapter counts).
@interface TranscriptionLogDetailViewController : UITableViewController
@property (nonatomic, copy) NSString* episodeHash;
@property (nonatomic, copy) NSString* displayTitle;
@property (nonatomic) BOOL showsHistory;
@property (nonatomic, copy) void (^openResult)(void);
@end

@implementation TranscriptionLogDetailViewController {
    NSArray<ICTranscriptionLogEntry*>* _entries;
    NSDateFormatter* _timeFormatter;
    UILabel* _emptyStateLabel;
    ICTranscriptionQueueItem* _currentItem;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = self.displayTitle ?: NSLocalizedString(@"Transkriptions-Log", nil);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 60;
    self.tableView.backgroundColor = ICBackgroundColor;
    _timeFormatter = [[NSDateFormatter alloc] init];
    _timeFormatter.dateStyle = NSDateFormatterNoStyle;
    _timeFormatter.timeStyle = NSDateFormatterMediumStyle;

    _emptyStateLabel = [[UILabel alloc] init];
    _emptyStateLabel.text = NSLocalizedString(@"Noch keine Aktionen aufgezeichnet.", nil);
    _emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    _emptyStateLabel.textColor = ICMutedTextColor;
    _emptyStateLabel.font = [UIFont systemFontOfSize:ICFontSize(14)];
    _emptyStateLabel.numberOfLines = 0;

    [self _reload];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                 name:@"ICTranscriptionQueueDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                 name:@"ICTranscriptionDidProgressNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                 name:@"ICTranscriptionDidFinishNotification" object:nil];
}

- (void)_leaveStatus {
    if (self.navigationController.viewControllers.count > 1) [self.navigationController popViewControllerAnimated:YES];
    else [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_reload {
    if (self.episodeHash.length == 0) {
        _entries = @[];
    } else {
        _entries = [[TranscriptionLogger shared] entriesWithEpisodeHash:self.episodeHash];
    }
    _currentItem = nil;
    for (ICTranscriptionQueueItem* item in [ServerTranscriptionManager shared].items) {
        if ([item.episodeHash isEqualToString:self.episodeHash]) { _currentItem = item; break; }
    }
    self.tableView.backgroundColor = _currentItem && !self.showsHistory ? UIColor.systemGroupedBackgroundColor : ICBackgroundColor;
    self.tableView.backgroundView = (_entries.count == 0 && !_currentItem) ? _emptyStateLabel : nil;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
    return _currentItem && !self.showsHistory ? 4 : 1;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
    if (!_currentItem || self.showsHistory) return nil;
    return @[@"", NSLocalizedString(@"What happens next", nil), NSLocalizedString(@"Process", nil), @""][section];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
    if (!_currentItem || self.showsHistory) return _entries.count;
    if (section == 1) return 2;
    if (section == 2) return 3;
    return 1;
}

- (NSString*)_actionTitle {
    if (_currentItem.requiresExplicitRetryAfterCrash) return NSLocalizedString(@"Check saved request", nil);
    if (_currentItem.status == ICTranscriptionStatusFailed) return [_currentItem.serverPhase isEqualToString:@"importing"]
        ? NSLocalizedString(@"Retrieve result again", nil) : NSLocalizedString(@"Try again", nil);
    if (_currentItem.status == ICTranscriptionStatusCompleted) return NSLocalizedString(@"Open player", nil);
    if (_currentItem.status == ICTranscriptionStatusCanceled) return NSLocalizedString(@"Remove from list", nil);
    return NSLocalizedString(@"Cancel request", nil);
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
    if (!_currentItem || self.showsHistory) return [self _logCellForIndexPath:indexPath];
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.textColor = ICTextColor;
    cell.detailTextLabel.textColor = ICMutedTextColor;
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == 0) {
        cell.accessibilityIdentifier = @"ICServerStatusTitle";
        cell.textLabel.text = ICServerTranscriptionTitle(_currentItem);
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
        NSMutableArray* detail = [NSMutableArray array];
        NSString* reason = ICServerTranscriptionReason(_currentItem);
        if (reason.length && _currentItem.status != ICTranscriptionStatusCompleted) [detail addObject:reason];
        if (_currentItem.serverLastResponseAt) {
            NSString* date = [NSDateFormatter localizedStringFromDate:_currentItem.serverLastResponseAt dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle];
            [detail addObject:[NSString stringWithFormat:NSLocalizedString(@"Last server response: %@", nil), date]];
        }
        cell.detailTextLabel.text = [detail componentsJoinedByString:@"\n\n"];
        BOOL failed = _currentItem.status == ICTranscriptionStatusFailed || _currentItem.requiresExplicitRetryAfterCrash;
        cell.imageView.image = [UIImage systemImageNamed:failed ? @"exclamationmark.circle" : (_currentItem.status == ICTranscriptionStatusCompleted ? @"checkmark.circle" : (_currentItem.serverWaitingForNetwork ? @"wifi.slash" : @"server.rack"))];
        cell.imageView.tintColor = failed ? UIColor.systemRedColor : (_currentItem.status == ICTranscriptionStatusCompleted ? UIColor.systemGreenColor : ICTintColor);
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.accessibilityIdentifier = @"ICServerNextAction";
        cell.textLabel.text = ICServerTranscriptionNextAction(_currentItem);
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    } else if (indexPath.section == 1) {
        cell.accessibilityIdentifier = @"ICServerAction";
        cell.textLabel.text = [self _actionTitle];
        BOOL destructive = !(_currentItem.requiresExplicitRetryAfterCrash || _currentItem.status == ICTranscriptionStatusFailed || _currentItem.status == ICTranscriptionStatusCompleted);
        cell.textLabel.textColor = destructive ? UIColor.systemRedColor : ICTintColor;
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.section == 2) {
        cell.accessibilityIdentifier = @"ICServerProcess";
        NSArray* titles = @[NSLocalizedString(@"Prepare and send request", nil), NSLocalizedString(@"Process on the server", nil), NSLocalizedString(@"Save result on this device", nil)];
        BOOL accepted = [[ServerTranscriptionManager shared] hasConfirmedAdmissionForEpisodeHash:_currentItem.episodeHash];
        BOOL importing = [_currentItem.serverPhase isEqualToString:@"importing"] || [_currentItem.serverPhase isEqualToString:@"ready"];
        NSInteger current = _currentItem.status == ICTranscriptionStatusCompleted ? 3 : (importing ? 2 : (accepted ? 1 : 0));
        BOOL done = indexPath.row < current;
        cell.textLabel.text = titles[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:done ? @"checkmark.circle.fill" : (indexPath.row == current ? @"circle.inset.filled" : @"circle")];
        cell.imageView.tintColor = done ? UIColor.systemGreenColor : (indexPath.row == current ? ICTintColor : ICMutedTextColor);
        cell.detailTextLabel.text = done ? NSLocalizedString(@"Completed", nil) : (indexPath.row == current ? ICServerTranscriptionTitle(_currentItem) : NSLocalizedString(@"Not started", nil));
    } else {
        cell.textLabel.text = NSLocalizedString(@"Diagnostic history", nil);
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
    }
    return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_currentItem || self.showsHistory) return;
    if (indexPath.section == 3) {
        TranscriptionLogDetailViewController* history = [[TranscriptionLogDetailViewController alloc] initWithStyle:UITableViewStylePlain];
        history.episodeHash = self.episodeHash;
        history.displayTitle = NSLocalizedString(@"Diagnostic history", nil);
        history.showsHistory = YES;
        [self.navigationController pushViewController:history animated:YES];
        return;
    }
    if (indexPath.section != 1 || indexPath.row != 1) return;
    if (_currentItem.requiresExplicitRetryAfterCrash || _currentItem.status == ICTranscriptionStatusFailed) {
        [[ServerTranscriptionManager shared] retryEpisodeHash:self.episodeHash];
    } else if (_currentItem.status == ICTranscriptionStatusCompleted) {
        if (self.openResult) self.openResult();
    } else if (_currentItem.status == ICTranscriptionStatusCanceled) {
        [[ServerTranscriptionManager shared] dequeueEpisodeHash:self.episodeHash];
        [self _leaveStatus];
    } else {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Cancel request", nil)
            message:NSLocalizedString(@"The cancellation is saved on this device and sent to the server. If offline, it will be sent when the connection returns. Pending cancellations are shown in the transcription list.", nil) preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Keep processing", nil) style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel request", nil) style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction* action) {
            [[ServerTranscriptionManager shared] dequeueEpisodeHash:self.episodeHash];
            [self _leaveStatus];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

// Localized human-readable label for the technical phase tag stored in the log.
- (NSString*)_phaseLabelForPhase:(NSString*)phase {
    if ([phase isEqualToString:@"queued"])    return NSLocalizedString(@"Warteschlange", nil);
    if ([phase isEqualToString:@"download"])  return NSLocalizedString(@"Download", nil);
    if ([phase isEqualToString:@"music"])     return NSLocalizedString(@"Audio-Analyse", nil);
    if ([phase isEqualToString:@"model"])     return NSLocalizedString(@"Modell", nil);
    if ([phase isEqualToString:@"transcribe"]) return NSLocalizedString(@"Transkription", nil);
    if ([phase isEqualToString:@"chapters"])  return NSLocalizedString(@"Kapitel", nil);
    if ([phase isEqualToString:@"background"]) return NSLocalizedString(@"Hintergrund", nil);
    if ([phase isEqualToString:@"automatic"]) return NSLocalizedString(@"Automatische Verarbeitung", nil);
    if ([phase isEqualToString:@"transcript-import"]) return NSLocalizedString(@"Podcast-Transkript", nil);
    if ([phase isEqualToString:@"recovery"])  return NSLocalizedString(@"Wiederherstellung", nil);
    if ([phase isEqualToString:@"retry"])     return NSLocalizedString(@"Neuer Versuch", nil);
    if ([phase isEqualToString:@"server"])    return NSLocalizedString(@"Server", nil);
    if ([phase isEqualToString:@"status"])    return NSLocalizedString(@"Status", nil);
    if ([phase isEqualToString:@"done"])      return NSLocalizedString(@"Fertig", nil);
    if ([phase isEqualToString:@"error"])     return NSLocalizedString(@"Fehler", nil);
    return phase;
}

- (UITableViewCell*)_logCellForIndexPath:(NSIndexPath*)indexPath {
    static NSString* cellID = @"LogEntryCell";
    UITableViewCell* cell = [self.tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
    }
    ICTranscriptionLogEntry* entry = _entries[indexPath.row];
    NSString* timeStr = [_timeFormatter stringFromDate:entry.timestamp];
    NSString* phaseLabel = [self _phaseLabelForPhase:entry.phase];

    // Headline: human-readable phase + message.
    cell.textLabel.text = [NSString stringWithFormat:@"%@ — %@", phaseLabel, entry.message];

    // Subtitle: timestamp, relative offset since first event, optional detail.
    NSMutableArray* subParts = [NSMutableArray arrayWithObject:timeStr];
    if (indexPath.row > 0) {
        NSTimeInterval dt = [entry.timestamp timeIntervalSinceDate:_entries.firstObject.timestamp];
        [subParts addObject:[NSString stringWithFormat:@"+%.1f s", dt]];
    }
    if (entry.detailText.length > 0) {
        [subParts addObject:entry.detailText];
    }
    cell.detailTextLabel.text = [subParts componentsJoinedByString:@"  ·  "];

    cell.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13) weight:UIFontWeightSemibold];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:ICFontSize(12)];
    cell.textLabel.textColor = [entry.phase isEqualToString:@"error"] ? [UIColor systemRedColor] : ICTextColor;
    cell.detailTextLabel.textColor = ICMutedTextColor;
    cell.backgroundColor = ICBackgroundColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end

@interface TranscriptionQueue (TranscriptionQueueViewControllerRetry)
- (void)retryWithEpisodeHash:(NSString*)episodeHash;
@end

@interface TranscriptionQueueViewController ()
@property (nonatomic, strong) UIBarButtonItem* pauseItem;
@property (nonatomic, strong) UIBarButtonItem* cancelItem;
@property (nonatomic, strong) NSTimer* elapsedTimer;
@property (nonatomic) BOOL suppressReload; // prevent double-update during swipe delete
@property (nonatomic) BOOL backgroundTaskActive;
@property (nonatomic) BOOL swipeInteractionActive;
@property (nonatomic) BOOL pendingReloadAfterSwipe;
@property (nonatomic, copy) NSArray<ICTranscriptionQueueItem*>* displayedItems;
@property (nonatomic, strong) UILabel* capacitySummaryLabel;
@property (nonatomic, strong) UIButton* dismissCapacityNoticeButton;
@property (nonatomic, strong) UIButton* retryServerCancellationButton;
@property (nonatomic, strong) UIButton* retryQueueStorageButton;
@property (nonatomic, copy) NSDictionary<NSString*, CDEpisode*>* episodeCache;
@property (nonatomic, copy) NSSet<NSString*>* episodeCacheHashes;
- (NSString*)_updateCellStatus:(DownloadsTableViewCell*)cell withItem:(ICTranscriptionQueueItem*)item;
@end

@implementation TranscriptionQueueViewController {
    NSDate* _lastCacheProgressUpdate;
}

+ (TranscriptionLogDetailViewController*)_serverStatusControllerForHash:(NSString*)hash title:(NSString*)title {
    TranscriptionLogDetailViewController* detail = [[TranscriptionLogDetailViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    detail.episodeHash = hash;
    detail.displayTitle = title;
    __weak TranscriptionLogDetailViewController* weakDetail = detail;
    detail.openResult = ^{
        CDEpisode* episode = [DMANAGER episodesWithObjectHashes:@[hash]].firstObject;
        if (!episode || !weakDetail) return;
        BOOL alreadySelected = [[AudioSession sharedAudioSession].episode isEqual:episode];
        PlaybackViewController* player = [PlaybackViewController playbackViewControllerWithUserInitiatedEpisode:episode forceReload:!alreadySelected];
        [player presentFromParentViewController:weakDetail.navigationController autostart:NO completion:nil];
    };
    return detail;
}

+ (void)showServerStatusForEpisodeHash:(NSString*)hash title:(NSString*)title fromViewController:(UIViewController*)presenter {
    if (!presenter || hash.length == 0) return;
    TranscriptionLogDetailViewController* detail = [self _serverStatusControllerForHash:hash title:title];
    UINavigationController* navigation = presenter.navigationController;
    if (navigation) {
        [navigation pushViewController:detail animated:YES];
    } else {
        UINavigationController* modal = [[UINavigationController alloc] initWithRootViewController:detail];
        modal.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle;
        detail.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:detail action:@selector(_close)];
        [presenter presentViewController:modal animated:YES completion:nil];
    }
}

+ (void)startServerTranscriptionForEpisode:(CDEpisode*)episode fromViewController:(UIViewController*)presenter {
    __block NSString* immediateFailure = nil;
    BOOL staged = [[ServerTranscriptionManager shared] enqueueEpisode:episode completion:^(BOOL accepted, NSString* message) {
        if (accepted) PlaySoundFile(@"AffirmIn", NO);
        else immediateFailure = message;
        // Once staged, the observed status page owns asynchronous feedback, including offline waits.
    }];
    if (staged || [[ServerTranscriptionManager shared] hasActiveItemForEpisodeHash:episode.objectHash]) {
        [self showServerStatusForEpisodeHash:episode.objectHash title:episode.title fromViewController:presenter];
    } else if (!presenter.presentedViewController) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Request could not be added", nil)
            message:immediateFailure ?: NSLocalizedString(@"Check that server transcription is enabled and this episode has an audio URL.", nil) preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    }
}

static NSString* const ICTranscriptionProcessingTaskIdentifier = @"com.iteconomy.instacastplus.transcription.processing";
static NSString* const ICTranscriptionActiveContinuedPath = @"ICTranscriptionActiveContinuedPath";
static NSString* const ICTranscriptionActiveContinuedIdentifier = @"ICTranscriptionActiveContinuedIdentifier";

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = NSLocalizedString(@"Transkribieren", nil);

    // Edit button — pencil icon, same as Downloads
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(toggleEditing:)];

    self.tableView.rowHeight = 80;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 0, 0, 0);
    self.tableView.backgroundColor = ICBackgroundColor;
    self.episodeCache = @{};
    self.episodeCacheHashes = [NSSet set];
    self.displayedItems = [TranscriptionQueue shared].displayItems;
    self.capacitySummaryLabel = [[UILabel alloc] init];
    self.capacitySummaryLabel.numberOfLines = 0;
    self.capacitySummaryLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
    self.capacitySummaryLabel.textColor = ICMutedTextColor;
    self.tableView.tableHeaderView = [[UIView alloc] init];
    [self.tableView.tableHeaderView addSubview:self.capacitySummaryLabel];
    self.dismissCapacityNoticeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.dismissCapacityNoticeButton setTitle:NSLocalizedString(@"Dismiss notice", nil) forState:UIControlStateNormal];
    self.dismissCapacityNoticeButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.dismissCapacityNoticeButton addTarget:self action:@selector(_dismissCapacityNotice) forControlEvents:UIControlEventTouchUpInside];
    [self.tableView.tableHeaderView addSubview:self.dismissCapacityNoticeButton];
    self.retryServerCancellationButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryServerCancellationButton setTitle:NSLocalizedString(@"Retry server cancellations", nil) forState:UIControlStateNormal];
    self.retryServerCancellationButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.retryServerCancellationButton addTarget:self action:@selector(_retryServerCancellations) forControlEvents:UIControlEventTouchUpInside];
    [self.tableView.tableHeaderView addSubview:self.retryServerCancellationButton];
    self.retryQueueStorageButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryQueueStorageButton setTitle:NSLocalizedString(@"Retry storage access", nil) forState:UIControlStateNormal];
    self.retryQueueStorageButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [self.retryQueueStorageButton addTarget:self action:@selector(_retryQueueStorage) forControlEvents:UIControlEventTouchUpInside];
    [self.tableView.tableHeaderView addSubview:self.retryQueueStorageButton];

    // Toolbar — same pattern as Downloads (Pause + Cancel)
    self.cancelItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Alle abbrechen", nil)
                                                      style:UIBarButtonItemStylePlain
                                                     target:self
                                                     action:@selector(_cancelAll)];
    [self.cancelItem setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)]} forState:UIControlStateNormal];

    self.pauseItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Im Hintergrund verarbeiten", nil)
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(_continueInBackground)];
    [self.pauseItem setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)]} forState:UIControlStateNormal];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_queueChanged)
                                                 name:@"ICTranscriptionQueueDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_queueChanged)
                                                 name:@"ICTranscriptionQueueCapacityDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_progressUpdated)
                                                 name:@"ICTranscriptionDidProgressNotification" object:nil];
    // CacheManagerDidUpdateNotification fires on every download-byte update (dozens per
    // second on fast connections). Route through a throttled handler — 0.5 Hz / 2 s is
    // plenty for a download progress bar and avoids burning CPU on cell re-layout.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_cacheProgressUpdated)
                                                 name:CacheManagerDidUpdateNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_contextObjectsDidChange:)
                                                 name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self _rebuildEpisodeCacheForCurrentItems];
    [self _queueChanged];

    // Restart elapsed timer if an item is currently loading or starting
    [self _restartElapsedTimerIfNeeded];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self _updateToolbarItemsAnimated:NO];
}

- (void)dealloc {
    [self.elapsedTimer invalidate];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)toggleEditing:(id)sender {
    [self.tableView setEditing:!self.tableView.isEditing animated:YES];
    self.navigationItem.rightBarButtonItem.image = self.tableView.isEditing
        ? [UIImage systemImageNamed:@"checkmark"]
        : [UIImage systemImageNamed:@"pencil"];
}

- (void)_queueChanged {
    [self _rebuildEpisodeCacheForCurrentItems];
    if (self.suppressReload || self.swipeInteractionActive) {
        self.pendingReloadAfterSwipe = YES;
        return;
    }
    [self _syncBackgroundButtonState];
    [self _restartElapsedTimerIfNeeded];
    [self _updateCapacitySummary];
    NSArray<ICTranscriptionQueueItem*>* items = [TranscriptionQueue shared].displayItems;
    if (![self.displayedItems isEqualToArray:items]) {
        self.displayedItems = items;
        [self.tableView reloadData];
    } else {
        [self _progressUpdated];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.swipeInteractionActive && !self.suppressReload) [self _updateCapacitySummary];
}

- (void)_updateCapacitySummary {
    NSString* summary = [TranscriptionQueue shared].queueCapacitySummary;
    BOOL showsNotice = [TranscriptionQueue shared].capacitySkippedCount > 0;
    BOOL showsCancellationRetry = [ServerTranscriptionManager shared].cancellationError.length > 0;
    BOOL showsStorageRetry = [TranscriptionQueue shared].queueStorageError != nil || [ServerTranscriptionManager shared].queueStorageError != nil;
    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    if ([self.capacitySummaryLabel.text isEqualToString:summary] &&
        CGRectGetWidth(self.tableView.tableHeaderView.frame) == width) return;
    self.capacitySummaryLabel.text = summary;
    CGSize size = [self.capacitySummaryLabel sizeThatFits:CGSizeMake(MAX(1, width - 32), CGFLOAT_MAX)];
    self.capacitySummaryLabel.frame = CGRectMake(16, 12, MAX(1, width - 32), ceil(size.height));
    self.dismissCapacityNoticeButton.hidden = !showsNotice;
    self.dismissCapacityNoticeButton.frame = CGRectMake(16, CGRectGetMaxY(self.capacitySummaryLabel.frame) + 4, MAX(1, width - 32), 44);
    self.retryServerCancellationButton.hidden = !showsCancellationRetry;
    self.retryServerCancellationButton.frame = CGRectMake(16, CGRectGetMaxY(self.capacitySummaryLabel.frame) + 4 + (showsNotice ? 48 : 0), MAX(1, width - 32), 44);
    self.retryQueueStorageButton.hidden = !showsStorageRetry;
    self.retryQueueStorageButton.frame = CGRectMake(16, CGRectGetMaxY(self.capacitySummaryLabel.frame) + 4 + (showsNotice ? 48 : 0) + (showsCancellationRetry ? 48 : 0), MAX(1, width - 32), 44);
    UIView* header = self.tableView.tableHeaderView;
    header.frame = CGRectMake(0, 0, width, ceil(size.height) + 24 + (showsNotice ? 48 : 0) + (showsCancellationRetry ? 48 : 0) + (showsStorageRetry ? 48 : 0));
    self.tableView.tableHeaderView = header;
}

- (void)_retryQueueStorage {
    [[ServerTranscriptionManager shared] retryQueueStorage];
    [[TranscriptionQueue shared] retryQueueStorage];
    [self _queueChanged];
}

- (void)_retryServerCancellations {
    [[ServerTranscriptionManager shared] retryPendingCancellations];
}

- (void)_dismissCapacityNotice {
    [[TranscriptionQueue shared] acknowledgeCapacityNotice];
    [self _queueChanged];
}

- (void)_progressUpdated {
    if (self.suppressReload) return;
    if (self.swipeInteractionActive) return;
    // Update visible cells without full reloadData for smooth progress bar animation
    BOOL needsHeightUpdate = NO;
    for (UITableViewCell* cell in self.tableView.visibleCells) {
        NSIndexPath* indexPath = [self.tableView indexPathForCell:cell];
        if (!indexPath || indexPath.row >= (NSInteger)self.displayedItems.count) continue;
        DownloadsTableViewCell* dlCell = (DownloadsTableViewCell*)cell;
        ICTranscriptionQueueItem* item = self.displayedItems[indexPath.row];
        [self _updateCellStatus:dlCell withItem:item];
        CGFloat requiredHeight = [self tableView:self.tableView heightForRowAtIndexPath:indexPath];
        if (fabs(requiredHeight - CGRectGetHeight(cell.bounds)) > 0.5) {
            needsHeightUpdate = YES;
        }
    }
    if (needsHeightUpdate) {
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
    }
    [self _restartElapsedTimerIfNeeded];
}

// Throttled wrapper for CacheManagerDidUpdateNotification. Download notifications can
// fire dozens of times per second; we only need one UI refresh every 2 seconds.
- (void)_cacheProgressUpdated {
    if (self.suppressReload) return;
    if (self.swipeInteractionActive) return;
    NSDate* now = [NSDate date];
    if (_lastCacheProgressUpdate && [now timeIntervalSinceDate:_lastCacheProgressUpdate] < 2.0) {
        return;
    }
    _lastCacheProgressUpdate = now;
    [self _progressUpdated];
}

- (void)_cancelAll {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Alle Transkriptionen abbrechen?", nil)
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Alle abbrechen", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[TranscriptionQueue shared] cancelAll];
        [[ServerTranscriptionManager shared] cancelAll];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Zurück", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_continueInBackground {
    if (![self backgroundControlsAvailable]) {
        self.backgroundTaskActive = NO;
        [USER_DEFAULTS setBool:NO forKey:@"TranscriptionBackgroundTaskRequested"];
        [self _updateBackgroundButtonAppearance];
        return;
    }

    if (self.backgroundTaskActive) {
        // Already active — deactivate (cancel the scheduled task)
        NSString* requestedContinuedPath = [USER_DEFAULTS stringForKey:ICTranscriptionActiveContinuedPath];
        BOOL isContinuedRequest = [requestedContinuedPath hasPrefix:@"continued-"];
        self.backgroundTaskActive = NO;
        [USER_DEFAULTS setBool:NO forKey:@"TranscriptionBackgroundTaskRequested"];
        [self _updateBackgroundButtonAppearance];
        if (!isContinuedRequest) {
            [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:ICTranscriptionProcessingTaskIdentifier];
        }
        if (@available(iOS 26.0, *)) {
            NSString* continuedIdentifier = [USER_DEFAULTS stringForKey:ICTranscriptionActiveContinuedIdentifier];
            if (continuedIdentifier.length > 0) {
                [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:continuedIdentifier];
            }
        }
        [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedPath];
        [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedIdentifier];
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        [queue deactivateBackgroundExecutionPathWithReason:@"user-disabled"];
        [queue scheduleAutomaticBackgroundProcessingIfNeeded];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"Hintergrund-Transkription deaktiviert"
                                     metadata:@{
                                         @"continuedRequest": @(isContinuedRequest),
                                         @"queueCount": @(queue.count),
                                     }];
        return;
    }

    if ([self _shouldUseContinuedBackgroundPath]) {
        [self _submitContinuedBackgroundTask];
    } else {
        [self _submitProcessingBackgroundTask];
    }
}

- (void)_submitProcessingBackgroundTask {
    [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedPath];
    [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedIdentifier];
    BGProcessingTaskRequest* request = [[BGProcessingTaskRequest alloc] initWithIdentifier:ICTranscriptionProcessingTaskIdentifier];
    request.requiresExternalPower = NO;
    request.requiresNetworkConnectivity = NO;
    NSError* submitError = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&submitError];

    if (submitError) {
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGProcessingTask-Request fehlgeschlagen"
                                     metadata:@{
                                         @"error": submitError.localizedDescription ?: @"",
                                         @"queueCount": @([TranscriptionQueue shared].count),
                                     }];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Fehler", nil)
                                                                      message:submitError.localizedDescription
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.backgroundTaskActive = YES;
    [USER_DEFAULTS setBool:YES forKey:@"TranscriptionBackgroundTaskRequested"];
    [self _updateBackgroundButtonAppearance];
    [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                  message:@"BGProcessingTask-Request eingereicht"
                                 metadata:@{
                                     @"identifier": ICTranscriptionProcessingTaskIdentifier,
                                     @"path": @"legacy-processing",
                                     @"queueCount": @([TranscriptionQueue shared].count),
                                 }];
    [self _presentBackgroundExplanationIfNeeded];
}

- (void)_submitContinuedBackgroundTask {
#if TARGET_OS_MACCATALYST
    // BGContinuedProcessingTaskRequest ist auf Mac Catalyst nicht verfügbar.
    // Gleicher Weg wie bei fehlender Wildcard-Registrierung: BGProcessingTask.
    [self _submitProcessingBackgroundTask];
#else
    if (@available(iOS 26.0, *)) {
        NSString* identifier = [[self _instacastAppDelegate] newTranscriptionContinuedTaskIdentifier];
        if (identifier.length == 0) {
            [self _submitProcessingBackgroundTask];
            return;
        }
        BOOL gpuSupported = (BGTaskScheduler.supportedResources & BGContinuedProcessingTaskRequestResourcesGPU) != 0;
        NSString* path = gpuSupported ? @"continued-gpu" : @"continued-cpu";
        TranscriptionQueue* queue = [TranscriptionQueue shared];
        ICTranscriptionQueueItem* item = queue.currentItem ?: queue.items.firstObject;
        NSString* title = item.episodeTitle.length > 0
            ? item.episodeTitle
            : NSLocalizedString(@"Podcast-Verarbeitung", nil);
        NSString* subtitle = item.statusDetail.length > 0
            ? item.statusDetail
            : NSLocalizedString(@"Transkription wird vorbereitet.", nil);
        BGContinuedProcessingTaskRequest* request = [[BGContinuedProcessingTaskRequest alloc] initWithIdentifier:identifier
                                                                                                          title:title
                                                                                                       subtitle:subtitle];
        request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
        request.requiredResources = gpuSupported
            ? BGContinuedProcessingTaskRequestResourcesGPU
            : BGContinuedProcessingTaskRequestResourcesDefault;

        [USER_DEFAULTS setObject:path forKey:ICTranscriptionActiveContinuedPath];
        [USER_DEFAULTS setObject:identifier forKey:ICTranscriptionActiveContinuedIdentifier];
        NSError* submitError = nil;
        [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&submitError];
        if (submitError) {
            [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedPath];
            [USER_DEFAULTS removeObjectForKey:ICTranscriptionActiveContinuedIdentifier];
            [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                          message:@"BGContinuedProcessingTask-Request fehlgeschlagen"
                                         metadata:@{
                                             @"error": submitError.localizedDescription ?: @"",
                                             @"path": path,
                                             @"queueCount": @([TranscriptionQueue shared].count),
                                         }];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Fehler", nil)
                                                                          message:submitError.localizedDescription
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }

        // A visible continued request owns this queue run. Retire only the
        // still-pending processing request after the continued submit succeeds;
        // an already delivered processing task is rejected by AppDelegate's
        // task-ownership check instead of having its grant overwritten.
        [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:ICTranscriptionProcessingTaskIdentifier];
        self.backgroundTaskActive = YES;
        [USER_DEFAULTS setBool:YES forKey:@"TranscriptionBackgroundTaskRequested"];
        [self _updateBackgroundButtonAppearance];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask-Request eingereicht"
                                     metadata:@{
                                         @"identifier": identifier,
                                         @"path": path,
                                         @"gpuSupported": @(gpuSupported),
                                         @"queueCount": @([TranscriptionQueue shared].count),
                                     }];
        [self _presentBackgroundExplanationIfNeeded];
    }
#endif
}

- (void)_presentBackgroundExplanationIfNeeded {
    if (![USER_DEFAULTS boolForKey:@"TranscriptionBackgroundExplained"]) {
        [USER_DEFAULTS setBool:YES forKey:@"TranscriptionBackgroundExplained"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Hintergrundverarbeitung", nil)
                                                                      message:NSLocalizedString(@"Die Anfrage wurde an iOS übergeben. Sobald iOS Rechenzeit gewährt, läuft die Verarbeitung im Hintergrund. Wird sie unterbrochen, bleiben Fortschritt und Warteschlange erhalten; fortgesetzt wird beim nächsten verfügbaren Hintergrundlauf oder App-Start.", nil)
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (BOOL)_isWhisperKitEngine {
    NSString* engine = [USER_DEFAULTS stringForKey:kTranscriptionEngine];
    return engine.length == 0 || [engine isEqualToString:@"WhisperKit"];
}

- (InstacastAppDelegate*)_instacastAppDelegate {
    return (InstacastAppDelegate*)[UIApplication sharedApplication].delegate;
}

- (BOOL)_shouldUseContinuedBackgroundPath {
    if (![self _isWhisperKitEngine]) return NO;
    // Without an accepted launch handler the submit throws instead of returning
    // an error, so the legacy BGProcessingTask path has to take over.
    if (![self _instacastAppDelegate].transcriptionContinuedTasksAvailable) return NO;
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

- (BOOL)backgroundControlsAvailable {
    for (ICTranscriptionQueueItem* item in [TranscriptionQueue shared].items) {
        if (!item.usesServerTranscription && item.status != ICTranscriptionStatusCompleted &&
            item.status != ICTranscriptionStatusFailed && item.status != ICTranscriptionStatusCanceled) return YES;
    }
    return NO;
}

- (void)_syncBackgroundButtonState {
    BOOL available = [self backgroundControlsAvailable];
    BOOL persistedActive = [USER_DEFAULTS boolForKey:@"TranscriptionBackgroundTaskRequested"];
    BOOL hasActiveGrant = [TranscriptionQueue shared].hasActiveBackgroundExecutionGrant;
    self.backgroundTaskActive = available && (persistedActive || hasActiveGrant);
    [self _updateBackgroundButtonAppearance];
    [self _updateToolbarItemsAnimated:NO];
}

- (void)_updateToolbarItemsAnimated:(BOOL)animated {
    if ([TranscriptionQueue shared].displayItems.count == 0) {
        [self setToolbarItems:@[] animated:animated];
        return;
    }

    UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    if ([self backgroundControlsAvailable]) {
        [self setToolbarItems:@[self.pauseItem, flexSpace, self.cancelItem] animated:animated];
    } else {
        [self setToolbarItems:@[flexSpace, self.cancelItem] animated:animated];
    }
}

- (void)_updateBackgroundButtonAppearance {
    if (![self backgroundControlsAvailable]) {
        self.pauseItem.enabled = NO;
        self.pauseItem.title = NSLocalizedString(@"Hintergrund nicht verfügbar", nil);
        NSDictionary* attributes = @{
            NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)],
            NSForegroundColorAttributeName: ICMutedTextColor
        };
        [self.pauseItem setTitleTextAttributes:attributes forState:UIControlStateNormal];
        [self.pauseItem setTitleTextAttributes:attributes forState:UIControlStateDisabled];
        return;
    }

    self.pauseItem.enabled = YES;
    BOOL hasActiveGrant = [TranscriptionQueue shared].hasActiveBackgroundExecutionGrant;
    if (self.backgroundTaskActive && hasActiveGrant) {
        self.pauseItem.title = NSLocalizedString(@"Hintergrund aktiv ✓", nil);
        [self.pauseItem setTitleTextAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)],
            NSForegroundColorAttributeName: [UIColor systemGreenColor]
        } forState:UIControlStateNormal];
    } else if (self.backgroundTaskActive) {
        self.pauseItem.title = NSLocalizedString(@"Hintergrund angefordert …", nil);
        [self.pauseItem setTitleTextAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)],
            NSForegroundColorAttributeName: self.view.tintColor
        } forState:UIControlStateNormal];
    } else {
        self.pauseItem.title = NSLocalizedString(@"Im Hintergrund verarbeiten", nil);
        [self.pauseItem setTitleTextAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)],
            NSForegroundColorAttributeName: self.view.tintColor
        } forState:UIControlStateNormal];
    }
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.displayedItems.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= (NSInteger)self.displayedItems.count) return 80;
    ICTranscriptionQueueItem* item = self.displayedItems[indexPath.row];
    NSString* statusText = [self _updateCellStatus:nil withItem:item];
    UIFont* statusFont = [UIFont systemFontOfSize:ICFontSize(item.usesServerTranscription ? 13 : 11)];
    UIFont* titleFont = [UIFont systemFontOfSize:ICFontSize(13)];
    CGFloat statusWidth = MAX(1, CGRectGetWidth(tableView.bounds) - 125);
    CGRect statusBounds = [statusText boundingRectWithSize:CGSizeMake(statusWidth, CGFLOAT_MAX)
                                                options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                             attributes:@{ NSFontAttributeName: statusFont }
                                                context:nil];
    CGFloat statusTop = item.status == ICTranscriptionStatusFailed
        ? 10 + ceil(titleFont.lineHeight) + 3
        : (item.usesServerTranscription ? MAX(32, 10 + ceil(titleFont.lineHeight) + 3) : 47);
    return MAX(80, statusTop + ceil(CGRectGetHeight(statusBounds)) + 7);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 1:1 like DownloadsViewController
    static NSString *CellIdentifier = @"TranscriptionCachingCell";

    DownloadsTableViewCell *cell = (DownloadsTableViewCell*)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[ICTranscriptionQueueCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
    }
    cell.backgroundColor = tableView.backgroundColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.showsErrorStatus = NO;
    cell.sizeLabel.numberOfLines = 0;
    cell.sizeLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.timeLabel.textAlignment = NSTextAlignmentCenter;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.rightContentAccessoryView = nil;
    cell.accessibilityIdentifier = nil;
    // Remove play button and reclaim its space.
    [cell.playAccessoryButton removeFromSuperview];

    // Use the same snapshot as the row count, including while a swipe is open.
    if (indexPath.row >= (NSInteger)self.displayedItems.count) {
        return cell;
    }

    ICTranscriptionQueueItem *item = self.displayedItems[indexPath.row];
    ((ICTranscriptionQueueCell*)cell).serverItem = item.usesServerTranscription;
    cell.sizeLabel.font = [UIFont systemFontOfSize:ICFontSize(item.usesServerTranscription ? 13 : 11)];
    cell.tag = indexPath.row;
    cell.accessibilityIdentifier = item.episodeHash;
    // (i) accessory opens the detailed log (durations, sizes, char/chapter counts).
    UIButton* logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration* logButtonConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    logButtonConfiguration.image = [UIImage systemImageNamed:@"info.circle"];
    logButtonConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(8, 0, -8, 0);
    logButton.configuration = logButtonConfiguration;
    logButton.frame = CGRectMake(0, 0, 44, 44);
    logButton.accessibilityLabel = NSLocalizedString(@"Status and activity", nil);
    logButton.tag = indexPath.row;
    [logButton addTarget:self action:@selector(_showLogFromAccessoryButton:) forControlEvents:UIControlEventTouchUpInside];
    cell.rightContentAccessoryView = logButton;

    // Title — same as Downloads: cleaned episode title
    CDEpisode* episode = [self _episodeForHash:item.episodeHash];
    if (episode) {
        cell.textLabel.text = [episode cleanTitleUsingFeedTitle:episode.feed.title];
    } else {
        cell.textLabel.text = item.episodeTitle;
    }

    // Image — same as Downloads
    cell.imageView.tag = 0;
    cell.imageView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];
    if (episode) {
        NSURL* imageURL = (episode.imageURL) ? episode.imageURL : episode.feed.imageURL;
        ImageCacheManager* iman = [ImageCacheManager sharedImageCacheManager];
        NSString* requestedEpisodeHash = item.episodeHash;
        __weak DownloadsTableViewCell* weakCell = cell;
        [iman imageForURL:imageURL size:56 grayscale:NO sender:cell completion:^(UIImage *image) {
            DownloadsTableViewCell* strongCell = weakCell;
            if (image && [strongCell.accessibilityIdentifier isEqualToString:requestedEpisodeHash]) {
                strongCell.imageView.image = image;
                strongCell.imageView.tag = 1;
            }
        }];
    }

    // Progress + Status — using sizeLabel and timeLabel like Downloads
    [self _updateCellStatus:cell withItem:item];

    return cell;
}

- (NSString*)_updateCellStatus:(DownloadsTableViewCell*)cell withItem:(ICTranscriptionQueueItem*)item {
    BOOL showsErrorStatus = item.status == ICTranscriptionStatusFailed;
    cell.showsErrorStatus = showsErrorStatus;
    if (!showsErrorStatus) {
        cell.sizeLabel.numberOfLines = 0;
        cell.sizeLabel.lineBreakMode = NSLineBreakByWordWrapping;
    }
    cell.sizeLabel.textColor = ICMutedTextColor; // reset color
    cell.timeLabel.textColor = ICMutedTextColor;
    NSString* elapsedText = [self _elapsedTextForItem:item];
    NSString* remainingText = [self _estimatedRemainingTextForItem:item];
    NSString* headline = nil;
    NSString* detail = item.statusDetail;

    if (item.usesServerTranscription) {
        cell.progressView.hidden = YES;
        cell.timeLabel.text = @"";
        if (item.status == ICTranscriptionStatusFailed) cell.sizeLabel.textColor = [UIColor systemRedColor];
        if (item.status == ICTranscriptionStatusCompleted) cell.sizeLabel.textColor = [UIColor systemGreenColor];
        NSString* statusText = ICServerTranscriptionStatusText(item);
        cell.sizeLabel.text = statusText;
        return statusText;
    }

    switch (item.status) {
        case ICTranscriptionStatusNone:
        case ICTranscriptionStatusQueued: {
            // Download-in-progress status has priority over "Unterbrochen" — a running
            // download must not be labelled as interrupted even though isProcessing=NO
            // on the queue (downloads run on the CacheManager, not the queue itself).
            BOOL isDownloading = [item.error isEqualToString:NSLocalizedString(@"Episode wird heruntergeladen...", nil)];
            BOOL isBackgroundPaused = [item.statusDetail isEqualToString:NSLocalizedString(@"Verarbeitung im Hintergrund pausiert. Wird mit verfügbarer Rechenzeit automatisch fortgesetzt.", nil)];
            if (isDownloading) {
                CDEpisode* ep = [self _episodeForHash:item.episodeHash];
                double p = ep ? [[CacheManager sharedCacheManager] cacheProgressForEpisode:ep] : 0.0;
                int pct = (int)(p * 100);
                if (pct > 0 && pct < 100) {
                    headline = [NSString stringWithFormat:NSLocalizedString(@"Episode wird heruntergeladen (%d%%)", nil), pct];
                    cell.progressView.progress = (float)p;
                    cell.progressView.hidden = NO;
                } else {
                    headline = NSLocalizedString(@"Episode wird heruntergeladen", nil);
                    cell.progressView.progress = 0;
                    cell.progressView.hidden = YES;
                }
                detail = item.statusDetail ?: NSLocalizedString(@"Automatischer Download für die Transkription.", nil);
                cell.timeLabel.text = elapsedText ?: @"";
            } else if (isBackgroundPaused) {
                int pct = (int)(item.progress * 100);
                if (pct > 0) {
                    if (remainingText.length > 0) {
                        headline = [NSString stringWithFormat:NSLocalizedString(@"Verarbeitung pausiert (%d%%, %@ verbleibend)", nil), pct, remainingText];
                    } else {
                        headline = [NSString stringWithFormat:NSLocalizedString(@"Verarbeitung pausiert (%d%%)", nil), pct];
                    }
                    cell.progressView.progress = item.progress;
                    cell.progressView.hidden = NO;
                } else {
                    headline = NSLocalizedString(@"Verarbeitung pausiert", nil);
                    cell.progressView.progress = 0;
                    cell.progressView.hidden = YES;
                }
                detail = item.statusDetail;
                cell.timeLabel.text = elapsedText ?: @"";
            } else if (item.automaticallyScheduled && item.nextRetryAt != nil) {
                headline = [self _automaticRetryHeadlineForItem:item];
                detail = nil;
                cell.progressView.progress = 0;
                cell.progressView.hidden = YES;
                cell.timeLabel.text = @"";
            } else if (item.error.length > 0 && ![TranscriptionQueue shared].isProcessing) {
                headline = NSLocalizedString(@"Unterbrochen", nil);
                if ([item.error isEqualToString:NSLocalizedString(@"Unterbrochen. Tippe zum Fortsetzen.", nil)]) {
                    detail = NSLocalizedString(@"Tippe für Optionen.", nil);
                } else {
                    detail = item.error;
                }
                cell.progressView.progress = 0;
                cell.progressView.hidden = YES;
                cell.timeLabel.text = @"";
            } else {
                if ([[TranscriptionEngine shared] hasCheckpointFor:item.episodeHash]) {
                    headline = NSLocalizedString(@"Unterbrochene Transkription wird fortgesetzt.", nil);
                } else {
                    headline = NSLocalizedString(@"Wartet auf Verarbeitung", nil);
                }
                cell.progressView.progress = 0;
                cell.progressView.hidden = YES;
                cell.timeLabel.text = @"";
            }
            break;
        }
        case ICTranscriptionStatusDownloadingModel: {
            headline = NSLocalizedString(@"Spracherkennungsmodell wird vorbereitet", nil);
            if (detail.length > 0 &&
                ![detail isEqualToString:NSLocalizedString(@"Modell wird vorbereitet.", nil)]) {
                headline = detail;
                detail = nil;
            } else {
                detail = nil;
            }
            cell.progressView.progress = 0;
            cell.progressView.hidden = YES;
            cell.timeLabel.text = elapsedText ?: @"";
            break;
        }
        case ICTranscriptionStatusAnalyzingMusic:
            headline = NSLocalizedString(@"Audio wird analysiert", nil);
            detail = detail ?: NSLocalizedString(@"Erkenne Musik, Sprache und Stille für spätere Kapitelgrenzen.", nil);
            cell.progressView.progress = 0;
            cell.progressView.hidden = YES;
            cell.timeLabel.text = elapsedText ?: @"";
            break;
        case ICTranscriptionStatusTranscribing: {
            int pct = (int)(item.progress * 100);
            if (pct > 0) {
                if (remainingText.length > 0) {
                    headline = [NSString stringWithFormat:NSLocalizedString(@"Transkription läuft (%d%%, %@ verbleibend)", nil), pct, remainingText];
                } else {
                    headline = [NSString stringWithFormat:NSLocalizedString(@"Transkription läuft (%d%%)", nil), pct];
                }
                cell.progressView.progress = item.progress;
                cell.progressView.hidden = NO;
            } else {
                headline = NSLocalizedString(@"Transkription läuft", nil);
                cell.progressView.progress = 0;
                cell.progressView.hidden = YES;
            }
            detail = detail ?: NSLocalizedString(@"Audiodatei wird verarbeitet.", nil);
            cell.timeLabel.text = elapsedText ?: @"";
            break;
        }
        case ICTranscriptionStatusGeneratingChapters: {
            int pct = (int)(item.progress * 100);
            if (pct > 0 && pct < 100) {
                if (remainingText.length > 0) {
                    headline = [NSString stringWithFormat:NSLocalizedString(@"Kapitel werden erstellt (%d%%, %@ verbleibend)", nil), pct, remainingText];
                } else {
                    headline = [NSString stringWithFormat:NSLocalizedString(@"Kapitel werden erstellt (%d%%)", nil), pct];
                }
            } else {
                headline = NSLocalizedString(@"Kapitel werden erstellt", nil);
            }
            detail = detail ?: NSLocalizedString(@"Kapitel werden aus dem Transkript erstellt.", nil);
            cell.progressView.progress = item.progress;
            cell.progressView.hidden = !(item.progress > 0 && item.progress < 1);
            cell.timeLabel.text = elapsedText ?: @"";
            break;
        }
        case ICTranscriptionStatusCompleted:
            if (item.chapterOnly) {
                headline = NSLocalizedString(@"Episodenanalyse fertig ✓", nil);
            } else if (item.shouldGenerateAnalysis) {
                headline = NSLocalizedString(@"Transkription und Episodenanalyse fertig ✓", nil);
            } else {
                headline = NSLocalizedString(@"Transkription fertig ✓", nil);
            }
            detail = nil;
            cell.sizeLabel.textColor = [UIColor systemGreenColor];
            cell.progressView.progress = 1.0;
            cell.progressView.hidden = YES;
            cell.timeLabel.text = @"";
            break;
        case ICTranscriptionStatusFailed:
            headline = NSLocalizedString(@"Fehler", nil);
            detail = item.error ?: NSLocalizedString(@"Fehler ✗", nil);
            cell.sizeLabel.textColor = [UIColor systemRedColor];
            cell.progressView.hidden = YES;
            cell.timeLabel.text = @"";
            break;
        case ICTranscriptionStatusCanceled:
            headline = NSLocalizedString(@"Canceled", nil);
            detail = nil;
            cell.progressView.hidden = YES;
            cell.timeLabel.text = @"";
            break;
    }

    NSString* statusText = [self _singleStatusTextWithHeadline:headline detail:detail];
    cell.sizeLabel.text = statusText;
    return statusText;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.displayedItems.count) return;
    ICTranscriptionQueueItem *item = self.displayedItems[indexPath.row];

    if (item.usesServerTranscription) {
        [self _showLogForRow:indexPath.row];
        return;
    }

    if (item.status == ICTranscriptionStatusQueued || item.status == ICTranscriptionStatusFailed || item.status == ICTranscriptionStatusCanceled) {
        [self _presentRecoveryActionsForItem:item];
        return;
    }

    CDEpisode* episode = [self _episodeForHash:item.episodeHash];
    if (!episode) return;
    BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
    PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithUserInitiatedEpisode:episode forceReload:!alreadyPlaying];
    [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
}

- (void)_rebuildEpisodeCacheForCurrentItems {
    NSMutableSet<NSString*>* hashes = [NSMutableSet set];
    for (ICTranscriptionQueueItem* item in [TranscriptionQueue shared].displayItems) {
        if (item.episodeHash.length > 0) {
            [hashes addObject:item.episodeHash];
        }
    }
    if ([self.episodeCacheHashes isEqualToSet:hashes]) {
        return;
    }

    NSArray<CDEpisode*>* episodes = hashes.count > 0 ? [DMANAGER episodesWithObjectHashes:hashes.allObjects] : @[];
    NSMutableDictionary<NSString*, CDEpisode*>* episodesByHash = [NSMutableDictionary dictionaryWithCapacity:episodes.count];
    for (CDEpisode* episode in episodes) {
        if (episode.objectHash.length > 0 && !episode.deleted) {
            episodesByHash[episode.objectHash] = episode;
        }
    }
    self.episodeCache = episodesByHash;
    self.episodeCacheHashes = hashes;
}

- (void)_contextObjectsDidChange:(NSNotification*)notification {
    NSMutableSet* removedObjects = [NSMutableSet setWithSet:notification.userInfo[NSDeletedObjectsKey] ?: [NSSet set]];
    [removedObjects unionSet:notification.userInfo[NSInvalidatedObjectsKey] ?: [NSSet set]];
    BOOL episodeCacheChanged = [notification.userInfo[NSInvalidatedAllObjectsKey] boolValue];
    if (!episodeCacheChanged) {
        for (NSManagedObject* object in removedObjects) {
            if ([object isKindOfClass:[CDEpisode class]]) {
                episodeCacheChanged = YES;
                break;
            }
        }
    }

    if (!episodeCacheChanged) {
        NSMutableSet* changedObjects = [NSMutableSet setWithSet:notification.userInfo[NSInsertedObjectsKey] ?: [NSSet set]];
        [changedObjects unionSet:notification.userInfo[NSUpdatedObjectsKey] ?: [NSSet set]];
        for (NSManagedObject* object in changedObjects) {
            if (![object isKindOfClass:[CDEpisode class]]) continue;
            CDEpisode* episode = (CDEpisode*)object;
            NSString* previousHash = episode.changedValuesForCurrentEvent[@"objectHash"];
            if ([self.episodeCacheHashes containsObject:episode.objectHash ?: @""] ||
                [self.episodeCacheHashes containsObject:previousHash ?: @""]) {
                episodeCacheChanged = YES;
                break;
            }
        }
    }
    if (!episodeCacheChanged) {
        return;
    }

    self.episodeCacheHashes = nil;
    [self _rebuildEpisodeCacheForCurrentItems];
    if (self.viewIfLoaded.window) {
        if (self.suppressReload || self.swipeInteractionActive) {
            self.pendingReloadAfterSwipe = YES;
            return;
        }
        [self.tableView reloadData];
    }
}

- (CDEpisode*)_episodeForHash:(NSString*)hash {
    if (hash.length == 0) return nil;
    CDEpisode* cachedEpisode = self.episodeCache[hash];
    if (!cachedEpisode) return nil;
    if (!cachedEpisode.deleted && cachedEpisode.managedObjectContext) {
        return cachedEpisode;
    }

    self.episodeCacheHashes = nil;
    [self _rebuildEpisodeCacheForCurrentItems];
    return self.episodeCache[hash];
}

- (void)_showLogFromAccessoryButton:(UIButton*)button {
    UIView* view = button;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    NSIndexPath* indexPath = [self.tableView indexPathForCell:(UITableViewCell*)view];
    if (indexPath) [self _showLogForRow:indexPath.row];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    [self _showLogForRow:indexPath.row];
}

- (void)_showLogForRow:(NSInteger)row {
    if (row >= (NSInteger)self.displayedItems.count) return;
    ICTranscriptionQueueItem* item = self.displayedItems[row];
    CDEpisode* episode = [self _episodeForHash:item.episodeHash];
    NSString* title = episode ? [episode cleanTitleUsingFeedTitle:episode.feed.title] : item.episodeTitle;
    TranscriptionLogDetailViewController* vc = item.usesServerTranscription
        ? [TranscriptionQueueViewController _serverStatusControllerForHash:item.episodeHash title:title]
        : [[TranscriptionLogDetailViewController alloc] initWithStyle:UITableViewStylePlain];
    vc.episodeHash = item.episodeHash;
    vc.displayTitle = title;
    [self.navigationController pushViewController:vc animated:YES];
}


#pragma mark - Editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return [ServerTranscriptionManager shared].items.count == 0; }

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    self.swipeInteractionActive = YES;
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    [self _endSwipeInteractionAndFlushDeferredUpdate];
}

- (void)_endSwipeInteractionAndFlushDeferredUpdate {
    self.swipeInteractionActive = NO;
    if (self.suppressReload) {
        return;
    }

    [self _syncBackgroundButtonState];
    if (self.pendingReloadAfterSwipe) {
        self.pendingReloadAfterSwipe = NO;
        self.displayedItems = [TranscriptionQueue shared].displayItems;
        [self.tableView reloadData];
        [self _restartElapsedTimerIfNeeded];
    } else {
        [self _progressUpdated];
    }
    [self _updateCapacitySummary];
}

- (void)_finishSwipeDeletionUpdate {
    self.suppressReload = NO;
    [self _endSwipeInteractionAndFlushDeferredUpdate];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        if (indexPath.row >= (NSInteger)self.displayedItems.count) return;
        ICTranscriptionQueueItem *item = self.displayedItems[indexPath.row];
        if ([[TranscriptionQueue shared].displayItems indexOfObjectIdenticalTo:item] == NSNotFound) {
            [self _endSwipeInteractionAndFlushDeferredUpdate];
            return;
        }
        NSMutableArray* remainingItems = [self.displayedItems mutableCopy];
        [remainingItems removeObjectAtIndex:indexPath.row];
        self.suppressReload = YES;
        if (item.usesServerTranscription) [[ServerTranscriptionManager shared] dequeueEpisodeHash:item.episodeHash];
        else [[TranscriptionQueue shared] dequeueWithEpisodeHash:item.episodeHash];
        self.displayedItems = remainingItems;
        self.pendingReloadAfterSwipe = ![remainingItems isEqualToArray:[TranscriptionQueue shared].displayItems];
        [tableView performBatchUpdates:^{
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        } completion:^(__unused BOOL finished) {
            [self _finishSwipeDeletionUpdate];
        }];
    }
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
    NSMutableArray *items = [self.displayedItems mutableCopy];
    ICTranscriptionQueueItem *moved = items[src.row];
    [items removeObjectAtIndex:src.row];
    [items insertObject:moved atIndex:dst.row];
    self.displayedItems = items;
    [[TranscriptionQueue shared] reorderItems:items];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0 || indexPath.row >= (NSInteger)self.displayedItems.count) {
        return nil;
    }
    self.swipeInteractionActive = YES;
    ICTranscriptionQueueItem* item = self.displayedItems[indexPath.row];
    NSString* episodeHash = [item.episodeHash copy];
    BOOL usesServerTranscription = item.usesServerTranscription;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                        title:NSLocalizedString(@"Entfernen", nil)
                                                                      handler:^(UIContextualAction *a, UIView *v, void (^c)(BOOL)) {
        NSArray<ICTranscriptionQueueItem*>* currentItems = [TranscriptionQueue shared].displayItems;
        NSUInteger currentRow = [currentItems indexOfObjectIdenticalTo:item];
        if (currentRow == NSNotFound) {
            c(NO);
            [self _endSwipeInteractionAndFlushDeferredUpdate];
            return;
        }
        BOOL canAnimateDeletion = !self.pendingReloadAfterSwipe &&
                                  currentRow == (NSUInteger)indexPath.row &&
                                  [tableView numberOfRowsInSection:0] == (NSInteger)currentItems.count;
        // Suppress queue-change notifications while we manually delete the row so the
        // queue update does not reset the table during the deletion animation.
        self.suppressReload = YES;
        if (usesServerTranscription) [[ServerTranscriptionManager shared] dequeueEpisodeHash:episodeHash];
        else [[TranscriptionQueue shared] dequeueWithEpisodeHash:episodeHash];
        NSInteger updatedCount = (NSInteger)[TranscriptionQueue shared].displayItems.count;
        if (canAnimateDeletion && updatedCount + 1 == (NSInteger)currentItems.count) {
            self.pendingReloadAfterSwipe = NO;
            self.displayedItems = [TranscriptionQueue shared].displayItems;
            [tableView performBatchUpdates:^{
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            } completion:^(__unused BOOL finished) {
                [self _finishSwipeDeletionUpdate];
            }];
        } else {
            self.pendingReloadAfterSwipe = YES;
            [self _finishSwipeDeletionUpdate];
        }
        c(YES);
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[action]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 0 || indexPath.row >= (NSInteger)self.displayedItems.count) {
        return nil;
    }
    ICTranscriptionQueueItem* item = self.displayedItems[indexPath.row];
    CDEpisode* episode = [self _episodeForHash:item.episodeHash];
    if (!episode) return nil;

    __weak TranscriptionQueueViewController* weakSelf = self;
    UIContextualAction* action = [ICEpisodeSwipeActionHandler configuredRightSwipeActionForEpisode:episode
                                                                         presentingViewController:self
                                                                                      willPerform:nil
                                                                                        didPerform:^{
        [weakSelf _endSwipeInteractionAndFlushDeferredUpdate];
    }];
    if (!action) return nil;
    UISwipeActionsConfiguration* configuration = [UISwipeActionsConfiguration configurationWithActions:@[action]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

- (void)_restartElapsedTimerIfNeeded {
    // If an item is in a state that shows elapsed time, restart the timer
    for (ICTranscriptionQueueItem* item in [TranscriptionQueue shared].displayItems) {
        if (!item.usesServerTranscription && item.statusStartedAt != nil &&
            item.status != ICTranscriptionStatusQueued &&
            item.status != ICTranscriptionStatusCompleted &&
            item.status != ICTranscriptionStatusFailed &&
            item.status != ICTranscriptionStatusCanceled) {
            if (!self.elapsedTimer || !self.elapsedTimer.isValid) {
                WEAK_SELF
                self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer* t) {
                    [weakSelf _progressUpdated];
                }];
            }
            return;
        }
    }
    // No items need the timer
    [self.elapsedTimer invalidate];
    self.elapsedTimer = nil;
}

- (NSString*)_singleStatusTextWithHeadline:(NSString*)headline detail:(NSString*)detail {
    NSString* trimmedHeadline = [headline stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString* trimmedDetail = [detail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (trimmedDetail.length == 0 || [self _statusDetail:trimmedDetail duplicatesHeadline:trimmedHeadline]) {
        return trimmedHeadline;
    }
    if ([trimmedHeadline containsString:@"%"]) {
        return [NSString stringWithFormat:@"%@ — %@", trimmedHeadline, trimmedDetail];
    }
    if ([trimmedHeadline isEqualToString:NSLocalizedString(@"Fehler", nil)] ||
        [trimmedHeadline isEqualToString:NSLocalizedString(@"Unterbrochen", nil)]) {
        return [NSString stringWithFormat:@"%@ - %@", trimmedHeadline, trimmedDetail];
    }
    return trimmedDetail;
}

- (BOOL)_statusDetail:(NSString*)detail duplicatesHeadline:(NSString*)headline {
    NSString* normalizedDetail = [self _normalizedStatusText:detail];
    NSString* normalizedHeadline = [self _normalizedStatusText:headline];
    if (normalizedDetail.length == 0 || normalizedHeadline.length == 0) return NO;
    if ([normalizedDetail isEqualToString:normalizedHeadline]) return YES;
    return [normalizedHeadline hasPrefix:normalizedDetail] || [normalizedDetail hasPrefix:normalizedHeadline];
}

- (NSString*)_normalizedStatusText:(NSString*)text {
    NSString* normalized = [[text lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\\([^)]*%[^)]*\\)"
                                                       withString:@""
                                                          options:NSRegularExpressionSearch
                                                            range:NSMakeRange(0, normalized.length)];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"[[:punct:]]+"
                                                       withString:@" "
                                                          options:NSRegularExpressionSearch
                                                            range:NSMakeRange(0, normalized.length)];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\\s+"
                                                       withString:@" "
                                                          options:NSRegularExpressionSearch
                                                            range:NSMakeRange(0, normalized.length)];
    return [normalized stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString*)_elapsedTextForItem:(ICTranscriptionQueueItem*)item {
    if (!item.statusStartedAt) {
        return nil;
    }

    NSInteger elapsed = MAX(0, (NSInteger)[[NSDate date] timeIntervalSinceDate:item.statusStartedAt]);
    NSInteger minutes = elapsed / 60;
    NSInteger seconds = elapsed % 60;
    if (minutes > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
    }
    return [NSString stringWithFormat:@"%lds", (long)seconds];
}

- (NSString*)_automaticRetryHeadlineForItem:(ICTranscriptionQueueItem*)item {
    if (!item.nextRetryAt) {
        return nil;
    }
    NSDateFormatterStyle dateStyle = [[NSCalendar currentCalendar] isDateInToday:item.nextRetryAt]
        ? NSDateFormatterNoStyle
        : NSDateFormatterShortStyle;
    NSString* retryTime = [NSDateFormatter localizedStringFromDate:item.nextRetryAt
                                                          dateStyle:dateStyle
                                                          timeStyle:NSDateFormatterShortStyle];
    return [NSString stringWithFormat:NSLocalizedString(@"Automatischer neuer Versuch um %@", nil), retryTime];
}

- (NSString*)_estimatedRemainingTextForItem:(ICTranscriptionQueueItem*)item {
    if (!item.progressBaselineStartedAt || item.progress >= 1.0f) {
        return nil;
    }

    float progressDelta = item.progress - item.progressBaseline;
    if (progressDelta <= 0.01f) {
        return nil;
    }

    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:item.progressBaselineStartedAt];
    if (elapsed < 5) {
        return nil;
    }

    double remainingProgress = MAX(0.0, 1.0 - item.progress);
    NSInteger remaining = MAX(0, (NSInteger)ceil(elapsed * remainingProgress / progressDelta));
    NSInteger minutes = remaining / 60;
    NSInteger seconds = remaining % 60;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

- (NSString*)_activeEngineLabel {
    NSString* engine = [USER_DEFAULTS stringForKey:kTranscriptionEngine];
    BOOL isWhisper = (engine == nil) || [engine isEqualToString:@"WhisperKit"];
    if (!isWhisper) {
        return NSLocalizedString(@"Apple-Spracherkennung", nil);
    }

    NSString* model = [TranscriptionEngine resolvedModelName];
    if ([model containsString:@"large"]) {
        return @"WhisperKit Large V3 Turbo";
    }
    return @"WhisperKit Small";
}

- (void)_presentFailureDetailsForItem:(ICTranscriptionQueueItem*)item {
    [self _presentRecoveryActionsForItem:item];
}

- (void)_presentRecoveryActionsForItem:(ICTranscriptionQueueItem*)item {
    BOOL checksExistingRequest = item.usesServerTranscription && item.requiresExplicitRetryAfterCrash;
    NSString* title = checksExistingRequest ? NSLocalizedString(@"Check server status again", nil) : NSLocalizedString(@"Job neu starten?", nil);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:checksExistingRequest ? (item.statusDetail ?: item.error) : nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:(checksExistingRequest ? NSLocalizedString(@"Check again", nil) : NSLocalizedString(@"Neustarten", nil)) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (item.usesServerTranscription) [[ServerTranscriptionManager shared] retryEpisodeHash:item.episodeHash];
        else [self _retryWithEpisodeHash:item.episodeHash];
        [self _queueChanged];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Aus Liste löschen", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self _deleteFailedOrInterruptedItem:item];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_deleteFailedOrInterruptedItem:(ICTranscriptionQueueItem*)item {
    if (item.episodeHash.length == 0) return;
    if (item.usesServerTranscription) [[ServerTranscriptionManager shared] dequeueEpisodeHash:item.episodeHash];
    else [[TranscriptionQueue shared] dequeueWithEpisodeHash:item.episodeHash];
    [self _queueChanged];
}

- (void)_retryWithEpisodeHash:(NSString*)episodeHash {
    if (episodeHash.length == 0) return;
    TranscriptionQueue* queue = [TranscriptionQueue shared];
    NSAssert([queue respondsToSelector:@selector(retryWithEpisodeHash:)], @"TranscriptionQueue must implement retryWithEpisodeHash:");
    if (![queue respondsToSelector:@selector(retryWithEpisodeHash:)]) return;
    [queue retryWithEpisodeHash:episodeHash];
    [self _queueChanged];
}

@end
