//
//  TranscriptionQueueViewController.m
//  Instacast
//
//  Transcription queue — consistent with DownloadsViewController.
//

#import "TranscriptionQueueViewController.h"
#import "DownloadsTableViewCell.h"
#import "EpisodePlayComboButton.h"
#import "CDEpisode+ShowNotes.h"
#import "PlaybackViewController.h"
#import "CacheManager.h"
#import "InstacastPlus-Swift.h"
#import <BackgroundTasks/BackgroundTasks.h>

// MARK: - Log Detail View

// Presented when the user taps the (i) accessory on a queued/finished transcription.
// Shows the full per-episode log (times, phases, durations, sizes, char/chapter counts).
@interface TranscriptionLogDetailViewController : UITableViewController
@property (nonatomic, copy) NSString* episodeHash;
@property (nonatomic, copy) NSString* displayTitle;
@end

@implementation TranscriptionLogDetailViewController {
    NSArray<ICTranscriptionLogEntry*>* _entries;
    NSDateFormatter* _timeFormatter;
    UILabel* _emptyStateLabel;
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

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_reload {
    if (self.episodeHash.length == 0) {
        _entries = @[];
    } else {
        _entries = [[TranscriptionLogger shared] entriesWithEpisodeHash:self.episodeHash];
    }
    self.tableView.backgroundView = (_entries.count == 0) ? _emptyStateLabel : nil;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_entries.count;
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
    if ([phase isEqualToString:@"done"])      return NSLocalizedString(@"Fertig", nil);
    if ([phase isEqualToString:@"error"])     return NSLocalizedString(@"Fehler", nil);
    return phase;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString* cellID = @"LogEntryCell";
    UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:cellID];
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
@property (nonatomic, strong) NSMutableDictionary<NSString*, CDEpisode*>* episodeCache;
@end

@implementation TranscriptionQueueViewController {
    NSDate* _lastCacheProgressUpdate;
}

static NSString* const ICTranscriptionProcessingTaskIdentifier = @"com.iteconomy.instacastplus.transcription.processing";
static NSString* const ICTranscriptionContinuedTaskIdentifier = @"com.iteconomy.instacastplus.transcription.continued";

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
    self.episodeCache = [NSMutableDictionary dictionary];

    // Toolbar — same pattern as Downloads (Pause + Cancel)
    self.cancelItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Alle abbrechen", nil)
                                                      style:UIBarButtonItemStylePlain
                                                     target:self
                                                     action:@selector(_cancelAll)];
    [self.cancelItem setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)]} forState:UIControlStateNormal];

    self.pauseItem = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Im Hintergrund transkribieren", nil)
                                                     style:UIBarButtonItemStylePlain
                                                    target:self
                                                    action:@selector(_continueInBackground)];
    [self.pauseItem setTitleTextAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)]} forState:UIControlStateNormal];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_queueChanged)
                                                 name:@"ICTranscriptionQueueDidChangeNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_progressUpdated)
                                                 name:@"ICTranscriptionDidProgressNotification" object:nil];
    // CacheManagerDidUpdateNotification fires on every download-byte update (dozens per
    // second on fast connections). Route through a throttled handler — 0.5 Hz / 2 s is
    // plenty for a download progress bar and avoids burning CPU on cell re-layout.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_cacheProgressUpdated)
                                                 name:CacheManagerDidUpdateNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self _syncBackgroundButtonState];

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
    if (self.suppressReload) return;
    if (self.swipeInteractionActive) return;
    [self _syncBackgroundButtonState];
    [self _restartElapsedTimerIfNeeded];
    // Debounce: coalesce rapid queue changes into a single reload
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_debouncedReload) object:nil];
    [self performSelector:@selector(_debouncedReload) withObject:nil afterDelay:0.3];
}

- (void)_debouncedReload {
    if (self.suppressReload) return;
    if (self.swipeInteractionActive) return;
    [self.tableView reloadData];
}

- (void)_progressUpdated {
    if (self.suppressReload) return;
    if (self.swipeInteractionActive) return;
    // Update visible cells without full reloadData for smooth progress bar animation
    for (UITableViewCell* cell in self.tableView.visibleCells) {
        NSIndexPath* indexPath = [self.tableView indexPathForCell:cell];
        if (!indexPath || indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) continue;
        DownloadsTableViewCell* dlCell = (DownloadsTableViewCell*)cell;
        ICTranscriptionQueueItem* item = [TranscriptionQueue shared].items[indexPath.row];
        [self _updateCellStatus:dlCell withItem:item];
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
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Zurück", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_continueInBackground {
    if (![self backgroundControlsAvailable]) {
        self.backgroundTaskActive = NO;
        [USER_DEFAULTS setBool:NO forKey:@"TranscriptionBackgroundTaskActive"];
        [self _updateBackgroundButtonAppearance];
        return;
    }

    if (self.backgroundTaskActive) {
        // Already active — deactivate (cancel the scheduled task)
        self.backgroundTaskActive = NO;
        [USER_DEFAULTS setBool:NO forKey:@"TranscriptionBackgroundTaskActive"];
        [self _updateBackgroundButtonAppearance];
        [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:ICTranscriptionProcessingTaskIdentifier];
        if (@available(iOS 26.0, *)) {
            [[BGTaskScheduler sharedScheduler] cancelTaskRequestWithIdentifier:ICTranscriptionContinuedTaskIdentifier];
        }
        [[TranscriptionQueue shared] deactivateBackgroundExecutionPathWithReason:@"user-disabled"];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"Hintergrund-Transkription deaktiviert"
                                     metadata:@{
                                         @"queueCount": @([TranscriptionQueue shared].count),
                                     }];
        return;
    }

    if ([self _shouldUseContinuedGPUBackgroundPath]) {
        [self _submitContinuedGPUBackgroundTask];
    } else {
        [self _submitProcessingBackgroundTask];
    }
}

- (void)_submitProcessingBackgroundTask {
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
    [USER_DEFAULTS setBool:YES forKey:@"TranscriptionBackgroundTaskActive"];
    [self _updateBackgroundButtonAppearance];
    [[TranscriptionQueue shared] activateBackgroundExecutionPathWithPath:@"legacy-processing"
                                                                  detail:@"BGProcessingTask eingereicht"];
    [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                  message:@"Hintergrundpfad aktiviert"
                                 metadata:@{
                                     @"path": @"legacy-processing",
                                     @"queueCount": @([TranscriptionQueue shared].count),
                                 }];
    [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                  message:@"BGProcessingTask-Request eingereicht"
                                 metadata:@{
                                     @"identifier": ICTranscriptionProcessingTaskIdentifier,
                                     @"path": @"legacy-processing",
                                     @"queueCount": @([TranscriptionQueue shared].count),
                                 }];
    [self _presentBackgroundExplanationIfNeeded];
}

- (void)_submitContinuedGPUBackgroundTask {
    if (@available(iOS 26.0, *)) {
        BGContinuedProcessingTaskRequest* request = [[BGContinuedProcessingTaskRequest alloc] initWithIdentifier:ICTranscriptionContinuedTaskIdentifier
                                                                                                          title:NSLocalizedString(@"Transkription läuft", nil)
                                                                                                       subtitle:NSLocalizedString(@"WhisperKit verarbeitet Podcasts im Hintergrund.", nil)];
        request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
        request.requiredResources = BGContinuedProcessingTaskRequestResourcesGPU;

        NSError* submitError = nil;
        [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&submitError];
        if (submitError) {
            [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                          message:@"BGContinuedProcessingTask-Request fehlgeschlagen"
                                         metadata:@{
                                             @"error": submitError.localizedDescription ?: @"",
                                             @"path": @"continued-gpu",
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
        [USER_DEFAULTS setBool:YES forKey:@"TranscriptionBackgroundTaskActive"];
        [self _updateBackgroundButtonAppearance];
        [[TranscriptionQueue shared] activateBackgroundExecutionPathWithPath:@"continued-gpu"
                                                                      detail:@"BGContinuedProcessingTask mit GPU eingereicht"];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"Hintergrundpfad aktiviert"
                                     metadata:@{
                                         @"path": @"continued-gpu",
                                         @"queueCount": @([TranscriptionQueue shared].count),
                                     }];
        [[ICDiagnosticLogger shared] logEvent:@"background-task"
                                      message:@"BGContinuedProcessingTask-Request eingereicht"
                                     metadata:@{
                                         @"identifier": ICTranscriptionContinuedTaskIdentifier,
                                         @"path": @"continued-gpu",
                                         @"gpuSupported": @((BGTaskScheduler.supportedResources & BGContinuedProcessingTaskRequestResourcesGPU) != 0),
                                         @"queueCount": @([TranscriptionQueue shared].count),
                                     }];
        [self _presentBackgroundExplanationIfNeeded];
    }
}

- (void)_presentBackgroundExplanationIfNeeded {
    if (![USER_DEFAULTS boolForKey:@"TranscriptionBackgroundExplained"]) {
        [USER_DEFAULTS setBool:YES forKey:@"TranscriptionBackgroundExplained"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Hintergrund-Transkription", nil)
                                                                      message:NSLocalizedString(@"Die Transkription wird im Hintergrund fortgesetzt, auch wenn die App geschlossen wird. Das System entscheidet, wann und wie lange die Verarbeitung läuft.", nil)
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (BOOL)_isWhisperKitEngine {
    NSString* engine = [USER_DEFAULTS stringForKey:kTranscriptionEngine];
    return engine.length == 0 || [engine isEqualToString:@"WhisperKit"];
}

- (BOOL)_shouldUseContinuedGPUBackgroundPath {
    if (![self _isWhisperKitEngine]) return NO;
    return [TranscriptionQueue supportsContinuedGPUBackgroundProcessing];
}

- (BOOL)backgroundControlsAvailable {
    if (![self _isWhisperKitEngine]) return YES;
    return [TranscriptionQueue supportsContinuedGPUBackgroundProcessing];
}

- (void)_syncBackgroundButtonState {
    BOOL available = [self backgroundControlsAvailable];
    BOOL persistedActive = [USER_DEFAULTS boolForKey:@"TranscriptionBackgroundTaskActive"];
    if (!available && persistedActive) {
        persistedActive = NO;
        [USER_DEFAULTS setBool:NO forKey:@"TranscriptionBackgroundTaskActive"];
    }
    self.backgroundTaskActive = available && persistedActive;
    [self _updateBackgroundButtonAppearance];
    [self _updateToolbarItemsAnimated:NO];
}

- (void)_updateToolbarItemsAnimated:(BOOL)animated {
    if ([TranscriptionQueue shared].items.count == 0) {
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
    if (self.backgroundTaskActive) {
        self.pauseItem.title = NSLocalizedString(@"Hintergrund aktiv ✓", nil);
        [self.pauseItem setTitleTextAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)],
            NSForegroundColorAttributeName: [UIColor systemGreenColor]
        } forState:UIControlStateNormal];
    } else {
        self.pauseItem.title = NSLocalizedString(@"Im Hintergrund transkribieren", nil);
        [self.pauseItem setTitleTextAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:ICFontSize(14)]
        } forState:UIControlStateNormal];
    }
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [TranscriptionQueue shared].items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 1:1 like DownloadsViewController
    static NSString *CellIdentifier = @"TranscriptionCachingCell";

    DownloadsTableViewCell *cell = (DownloadsTableViewCell*)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[DownloadsTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
    }
    cell.backgroundColor = tableView.backgroundColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.sizeLabel.numberOfLines = 2;
    cell.sizeLabel.lineBreakMode = NSLineBreakByWordWrapping;
    cell.timeLabel.textAlignment = NSTextAlignmentCenter;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.rightContentAccessoryView = nil;
    // Remove play button and reclaim its space.
    [cell.playAccessoryButton removeFromSuperview];

    // Bounds check — items array could change between numberOfRows and cellForRow
    if (indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) {
        return cell;
    }

    ICTranscriptionQueueItem *item = [TranscriptionQueue shared].items[indexPath.row];
    cell.tag = indexPath.row;
    // (i) accessory opens the detailed log (durations, sizes, char/chapter counts).
    UIButton* logButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration* logButtonConfiguration = [UIButtonConfiguration plainButtonConfiguration];
    logButtonConfiguration.image = [UIImage systemImageNamed:@"info.circle"];
    logButtonConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(8, 0, -8, 0);
    logButton.configuration = logButtonConfiguration;
    logButton.frame = CGRectMake(0, 0, 44, 44);
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
        [iman imageForURL:imageURL size:56 grayscale:NO sender:self completion:^(UIImage *image) {
            if (image) {
                cell.imageView.image = image;
                cell.imageView.tag = 1;
            }
        }];
    }

    // Progress + Status — using sizeLabel and timeLabel like Downloads
    [self _updateCellStatus:cell withItem:item];

    return cell;
}

- (void)_updateCellStatus:(DownloadsTableViewCell*)cell withItem:(ICTranscriptionQueueItem*)item {
    cell.sizeLabel.textColor = ICMutedTextColor; // reset color
    cell.timeLabel.textColor = ICMutedTextColor;
    NSString* elapsedText = [self _elapsedTextForItem:item];
    NSString* remainingText = [self _estimatedRemainingTextForItem:item];
    NSString* headline = nil;
    NSString* detail = item.statusDetail;

    switch (item.status) {
        case ICTranscriptionStatusNone:
        case ICTranscriptionStatusQueued: {
            // Download-in-progress status has priority over "Unterbrochen" — a running
            // download must not be labelled as interrupted even though isProcessing=NO
            // on the queue (downloads run on the CacheManager, not the queue itself).
            BOOL isDownloading = [item.error isEqualToString:NSLocalizedString(@"Episode wird heruntergeladen...", nil)];
            BOOL isBackgroundPaused = [item.statusDetail isEqualToString:NSLocalizedString(@"Transkription im Hintergrund pausiert. Wird beim Zurückkehren automatisch fortgesetzt.", nil)];
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
                        headline = [NSString stringWithFormat:NSLocalizedString(@"Transkription pausiert (%d%%, %@ verbleibend)", nil), pct, remainingText];
                    } else {
                        headline = [NSString stringWithFormat:NSLocalizedString(@"Transkription pausiert (%d%%)", nil), pct];
                    }
                    cell.progressView.progress = item.progress;
                    cell.progressView.hidden = NO;
                } else {
                    headline = NSLocalizedString(@"Transkription pausiert", nil);
                    cell.progressView.progress = 0;
                    cell.progressView.hidden = YES;
                }
                detail = item.statusDetail;
                cell.timeLabel.text = elapsedText ?: @"";
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
            headline = NSLocalizedString(@"Fertig ✓", nil);
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
    }

    cell.sizeLabel.text = [self _singleStatusTextWithHeadline:headline detail:detail];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) return;
    ICTranscriptionQueueItem *item = [TranscriptionQueue shared].items[indexPath.row];

    if ((item.status == ICTranscriptionStatusQueued && item.error.length > 0 && ![TranscriptionQueue shared].isProcessing) ||
        item.status == ICTranscriptionStatusFailed) {
        [self _presentRecoveryActionsForItem:item];
        return;
    }

    CDEpisode* episode = [self _episodeForHash:item.episodeHash];
    if (!episode) return;
    BOOL alreadyPlaying = [[AudioSession sharedAudioSession].episode isEqual:episode];
    PlaybackViewController* playbackController = [PlaybackViewController playbackViewControllerWithEpisode:episode forceReload:!alreadyPlaying];
    [playbackController presentFromParentViewController:self.navigationController autostart:YES completion:NULL];
}

- (CDEpisode*)_episodeForHash:(NSString*)hash {
    if (hash.length == 0) return nil;
    CDEpisode* cachedEpisode = self.episodeCache[hash];
    if (cachedEpisode) return cachedEpisode;

    for (CDFeed* feed in DMANAGER.feeds) {
        for (CDEpisode* episode in feed.episodes) {
            if ([episode.objectHash isEqualToString:hash]) {
                self.episodeCache[hash] = episode;
                return episode;
            }
        }
    }
    return nil;
}

- (void)_showLogFromAccessoryButton:(UIButton*)button {
    [self _showLogForRow:button.tag];
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    [self _showLogForRow:indexPath.row];
}

- (void)_showLogForRow:(NSInteger)row {
    if (row >= (NSInteger)[TranscriptionQueue shared].items.count) return;
    ICTranscriptionQueueItem* item = [TranscriptionQueue shared].items[row];
    TranscriptionLogDetailViewController* vc = [[TranscriptionLogDetailViewController alloc] initWithStyle:UITableViewStylePlain];
    vc.episodeHash = item.episodeHash;
    CDEpisode* episode = [self _episodeForHash:item.episodeHash];
    vc.displayTitle = episode ? [episode cleanTitleUsingFeedTitle:episode.feed.title] : item.episodeTitle;
    [self.navigationController pushViewController:vc animated:YES];
}


#pragma mark - Editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    self.swipeInteractionActive = YES;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_debouncedReload) object:nil];
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.swipeInteractionActive = NO;
        if (!self.suppressReload) {
            [self _syncBackgroundButtonState];
            [self _progressUpdated];
        }
    });
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        if (indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) return;
        ICTranscriptionQueueItem *item = [TranscriptionQueue shared].items[indexPath.row];
        self.suppressReload = YES;
        [[TranscriptionQueue shared] dequeueWithEpisodeHash:item.episodeHash];
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.suppressReload = NO;
            self.swipeInteractionActive = NO;
            [self _syncBackgroundButtonState];
            [self _progressUpdated];
        });
    }
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)src toIndexPath:(NSIndexPath *)dst {
    NSMutableArray *items = [[TranscriptionQueue shared].items mutableCopy];
    ICTranscriptionQueueItem *moved = items[src.row];
    [items removeObjectAtIndex:src.row];
    [items insertObject:moved atIndex:dst.row];
    [[TranscriptionQueue shared] reorderItems:items];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    self.swipeInteractionActive = YES;
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                        title:NSLocalizedString(@"Entfernen", nil)
                                                                      handler:^(UIContextualAction *a, UIView *v, void (^c)(BOOL)) {
        if (indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) { c(NO); return; }
        ICTranscriptionQueueItem *item = [TranscriptionQueue shared].items[indexPath.row];
        // Suppress queue-change notifications while we manually delete the row so the
        // debounced reload doesn't reset the tableView state half-way through the animation.
        self.suppressReload = YES;
        [[TranscriptionQueue shared] dequeueWithEpisodeHash:item.episodeHash];
        // UITableView does NOT remove the row automatically when the completion handler
        // reports YES — we must delete it explicitly now that the data source is updated.
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
        c(YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.suppressReload = NO;
            self.swipeInteractionActive = NO;
            [self _syncBackgroundButtonState];
            [self _progressUpdated];
        });
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[action]];
}

- (void)_restartElapsedTimerIfNeeded {
    // If an item is in a state that shows elapsed time, restart the timer
    for (ICTranscriptionQueueItem* item in [TranscriptionQueue shared].items) {
        if (item.statusStartedAt != nil &&
            item.status != ICTranscriptionStatusQueued &&
            item.status != ICTranscriptionStatusCompleted &&
            item.status != ICTranscriptionStatusFailed) {
            if (!self.elapsedTimer || !self.elapsedTimer.isValid) {
                self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer* t) {
                    [self _progressUpdated];
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
        return trimmedHeadline;
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

- (NSString*)_estimatedRemainingTextForItem:(ICTranscriptionQueueItem*)item {
    if (!item.statusStartedAt || item.progress <= 0.01f || item.progress >= 1.0f) {
        return nil;
    }

    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:item.statusStartedAt];
    if (elapsed < 5) {
        return nil;
    }

    NSInteger remaining = MAX(0, (NSInteger)ceil(elapsed * (1.0 - item.progress) / item.progress));
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Job neu starten?", nil)
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Neustarten", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _retryWithEpisodeHash:item.episodeHash];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Aus Liste löschen", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self _deleteFailedOrInterruptedItem:item];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_deleteFailedOrInterruptedItem:(ICTranscriptionQueueItem*)item {
    if (item.episodeHash.length == 0) return;
    [[TranscriptionQueue shared] dequeueWithEpisodeHash:item.episodeHash];
    [self _syncBackgroundButtonState];
    [self.tableView reloadData];
}

- (void)_retryWithEpisodeHash:(NSString*)episodeHash {
    if (episodeHash.length == 0) return;
    TranscriptionQueue* queue = [TranscriptionQueue shared];
    NSAssert([queue respondsToSelector:@selector(retryWithEpisodeHash:)], @"TranscriptionQueue must implement retryWithEpisodeHash:");
    if (![queue respondsToSelector:@selector(retryWithEpisodeHash:)]) return;
    [queue retryWithEpisodeHash:episodeHash];
    [self.tableView reloadData];
}

@end
