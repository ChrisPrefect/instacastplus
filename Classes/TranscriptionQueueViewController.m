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
#import "InstacastPlus-Swift.h"
#import <BackgroundTasks/BackgroundTasks.h>

@interface TranscriptionQueueViewController ()
@property (nonatomic, strong) UIBarButtonItem* pauseItem;
@property (nonatomic, strong) UIBarButtonItem* cancelItem;
@property (nonatomic, strong) NSTimer* elapsedTimer;
@property (nonatomic, strong) NSDate* modelLoadStartDate;
@property (nonatomic) BOOL suppressReload; // prevent double-update during swipe delete
@property (nonatomic) BOOL backgroundTaskActive;
@end

@implementation TranscriptionQueueViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.title = NSLocalizedString(@"Transkribieren", nil);

    // Edit button — pencil icon, same as Downloads
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(toggleEditing:)];

    self.tableView.rowHeight = 70;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 0, 0, 0);
    self.tableView.backgroundColor = ICBackgroundColor;

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
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.toolbarItems || self.toolbarItems.count == 0) {
        UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        [self setToolbarItems:@[self.pauseItem, flexSpace, self.cancelItem]];
    }
}

- (void)dealloc {
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
    [self.tableView reloadData];
}

- (void)_progressUpdated {
    // Update visible cells without full reloadData for smooth progress bar animation
    for (UITableViewCell* cell in self.tableView.visibleCells) {
        NSIndexPath* indexPath = [self.tableView indexPathForCell:cell];
        if (!indexPath || indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) continue;
        DownloadsTableViewCell* dlCell = (DownloadsTableViewCell*)cell;
        ICTranscriptionQueueItem* item = [TranscriptionQueue shared].items[indexPath.row];
        [self _updateCellStatus:dlCell withItem:item];
    }
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
    if (self.backgroundTaskActive) {
        // Already active — deactivate (cancel the scheduled task)
        self.backgroundTaskActive = NO;
        [self _updateBackgroundButtonAppearance];
        return;
    }

    BGProcessingTaskRequest* request = [[BGProcessingTaskRequest alloc] initWithIdentifier:@"com.iteconomy.instacastplus.transcription.processing"];
    request.requiresExternalPower = NO;
    request.requiresNetworkConnectivity = NO;
    NSError* submitError = nil;
    [[BGTaskScheduler sharedScheduler] submitTaskRequest:request error:&submitError];

    if (submitError) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Fehler", nil)
                                                                      message:submitError.localizedDescription
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.backgroundTaskActive = YES;
    [self _updateBackgroundButtonAppearance];

    // Show explanation only on first use
    if (![USER_DEFAULTS boolForKey:@"TranscriptionBackgroundExplained"]) {
        [USER_DEFAULTS setBool:YES forKey:@"TranscriptionBackgroundExplained"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Hintergrund-Transkription", nil)
                                                                      message:NSLocalizedString(@"Die Transkription wird im Hintergrund fortgesetzt, auch wenn die App geschlossen wird. Das System entscheidet, wann und wie lange die Verarbeitung läuft.", nil)
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)_updateBackgroundButtonAppearance {
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

    // Bounds check — items array could change between numberOfRows and cellForRow
    if (indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) {
        return cell;
    }
    cell.playAccessoryButton.hidden = YES;

    ICTranscriptionQueueItem *item = [TranscriptionQueue shared].items[indexPath.row];
    cell.tag = indexPath.row;

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
    switch (item.status) {
        case ICTranscriptionStatusNone:
        case ICTranscriptionStatusQueued:
            cell.sizeLabel.text = NSLocalizedString(@"Wartend...", nil);
            cell.progressView.progress = 0;
            cell.progressView.hidden = YES;
            break;
        case ICTranscriptionStatusDownloadingModel: {
            // Show elapsed time so user knows something is happening
            if (!self.modelLoadStartDate) {
                self.modelLoadStartDate = [NSDate date];
                // Start timer to update elapsed time every second
                [self.elapsedTimer invalidate];
                self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer* t) {
                    [self _progressUpdated];
                }];
            }
            NSInteger elapsed = (NSInteger)[[NSDate date] timeIntervalSinceDate:self.modelLoadStartDate];
            cell.sizeLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Sprachmodell wird vorbereitet... %lds", nil), (long)elapsed];
            cell.progressView.progress = 0;
            cell.progressView.hidden = YES;
            break;
        }
        case ICTranscriptionStatusAnalyzingMusic:
            cell.sizeLabel.text = NSLocalizedString(@"Musik wird analysiert...", nil);
            cell.progressView.progress = 0;
            cell.progressView.hidden = NO;
            break;
        case ICTranscriptionStatusTranscribing: {
            // Stop model-load timer
            if (self.modelLoadStartDate) {
                self.modelLoadStartDate = nil;
                [self.elapsedTimer invalidate];
                self.elapsedTimer = nil;
            }
            int pct = (int)(item.progress * 100);
            if (pct <= 0) {
                cell.sizeLabel.text = NSLocalizedString(@"Transkription wird gestartet...", nil);
            } else {
                cell.sizeLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Transkribiert... %d%%", nil), pct];
            }
            cell.progressView.progress = item.progress;
            cell.progressView.hidden = NO;
            break;
        }
        case ICTranscriptionStatusGeneratingChapters:
            cell.sizeLabel.text = NSLocalizedString(@"Kapitel werden erkannt...", nil);
            cell.progressView.progress = 0.95;
            cell.progressView.hidden = NO;
            break;
        case ICTranscriptionStatusCompleted:
            cell.sizeLabel.text = NSLocalizedString(@"Fertig ✓", nil);
            cell.sizeLabel.textColor = [UIColor systemGreenColor];
            cell.progressView.progress = 1.0;
            cell.progressView.hidden = YES;
            break;
        case ICTranscriptionStatusFailed:
            cell.sizeLabel.text = item.error ?: NSLocalizedString(@"Fehler ✗", nil);
            cell.sizeLabel.textColor = [UIColor systemRedColor];
            cell.progressView.hidden = YES;
            break;
    }
    cell.timeLabel.text = item.feedTitle; // Podcast name on the right
}

- (CDEpisode*)_episodeForHash:(NSString*)hash {
    for (CDFeed* feed in DMANAGER.feeds) {
        for (CDEpisode* episode in feed.episodes) {
            if ([episode.objectHash isEqualToString:hash]) return episode;
        }
    }
    return nil;
}


#pragma mark - Editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        ICTranscriptionQueueItem *item = [TranscriptionQueue shared].items[indexPath.row];
        self.suppressReload = YES;
        [[TranscriptionQueue shared] dequeueWithEpisodeHash:item.episodeHash];
        self.suppressReload = NO;
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
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
    UIContextualAction *action = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                        title:NSLocalizedString(@"Entfernen", nil)
                                                                      handler:^(UIContextualAction *a, UIView *v, void (^c)(BOOL)) {
        if (indexPath.row >= (NSInteger)[TranscriptionQueue shared].items.count) { c(NO); return; }
        ICTranscriptionQueueItem *item = [TranscriptionQueue shared].items[indexPath.row];
        // Suppress reload during animated row deletion to prevent double-update jank
        self.suppressReload = YES;
        [[TranscriptionQueue shared] dequeueWithEpisodeHash:item.episodeHash];
        self.suppressReload = NO;
        c(YES);
    }];
    action.image = [UIImage systemImageNamed:@"trash"];
    return [UISwipeActionsConfiguration configurationWithActions:@[action]];
}

@end
