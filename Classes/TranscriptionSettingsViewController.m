//
//  TranscriptionSettingsViewController.m
//  Instacast
//
//  Settings UI for "Transkription und Kapitel".
//  Sections: Intro → Sprachmodell (combined Engine+Model) → Kapitel & Sponsoren → Automatisch
//

#import "TranscriptionSettingsViewController.h"
#import "SettingsValuesTableViewController.h"
#import "InstacastPlus-Swift.h"

// Combined engine+model values
static NSString* const kCombinedWhisperLarge = @"WhisperKit_large";
static NSString* const kCombinedWhisperSmall = @"WhisperKit_small";
static NSString* const kCombinedApple       = @"Apple";

typedef NS_ENUM(NSInteger, TSSection) {
    TSSectionModel = 0,
    TSSectionChapters,
    TSSectionAuto,
    TSSectionCount
};

@interface TranscriptionSettingsViewController ()
@property (nonatomic) BOOL isDownloadingModel;
@property (nonatomic, strong) NSTimer* downloadProgressTimer;
@end

@implementation TranscriptionSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NSLocalizedString(@"Transkription", nil);

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                 name:@"ICTranscriptionQueueDidChangeNotification" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Sync combined value back to underlying keys (after returning from picker)
    [self _syncCombinedToUnderlyingKeys];
    // Cancel any running download if model changed (prevents mismatched download)
    if (self.isDownloadingModel) {
        self.isDownloadingModel = NO;
        [self.downloadProgressTimer invalidate];
        self.downloadProgressTimer = nil;
    }
    [self.tableView reloadData];
}

- (void)dealloc {
    [self.downloadProgressTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_reload { [self.tableView reloadData]; }

#pragma mark - Combined Value Helpers

/// Read current combined value from underlying keys
- (NSString*)_combinedValue {
    NSString* engine = [USER_DEFAULTS stringForKey:kTranscriptionEngine];
    if ([engine isEqualToString:@"Apple"]) return kCombinedApple;
    // WhisperKit (default)
    NSString* model = [TranscriptionEngine resolvedModelName];
    if ([model containsString:@"large"]) return kCombinedWhisperLarge;
    return kCombinedWhisperSmall;
}

/// Sync the "TranscriptionModelCombined" UserDefault to the two underlying keys
- (void)_syncCombinedToUnderlyingKeys {
    NSString* combined = [USER_DEFAULTS stringForKey:@"TranscriptionModelCombined"];
    if (!combined) return;

    if ([combined isEqualToString:kCombinedWhisperLarge]) {
        [USER_DEFAULTS setObject:@"WhisperKit" forKey:kTranscriptionEngine];
        [USER_DEFAULTS setObject:@"openai_whisper-large-v3-v20240930_turbo_632MB" forKey:kTranscriptionWhisperModel];
    } else if ([combined isEqualToString:kCombinedWhisperSmall]) {
        [USER_DEFAULTS setObject:@"WhisperKit" forKey:kTranscriptionEngine];
        [USER_DEFAULTS setObject:@"openai_whisper-small_216MB" forKey:kTranscriptionWhisperModel];
    } else if ([combined isEqualToString:kCombinedApple]) {
        [USER_DEFAULTS setObject:@"Apple" forKey:kTranscriptionEngine];
    }
}

- (BOOL)_isWhisperKit {
    NSString* engine = [USER_DEFAULTS stringForKey:kTranscriptionEngine];
    return engine == nil || [engine isEqualToString:@"WhisperKit"];
}

- (BOOL)_isLargeAvailableOnDevice {
    // Large V3 Turbo needs ~8 GB RAM for CoreML inference
    uint64_t physicalMemory = [NSProcessInfo processInfo].physicalMemory;
    return physicalMemory >= (uint64_t)8 * 1024 * 1024 * 1024;
}

#pragma mark - Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return TSSectionCount; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case TSSectionModel: return NSLocalizedString(@"Sprachmodell", nil);
        case TSSectionChapters: return NSLocalizedString(@"Kapitel & Sponsoren", nil);
        case TSSectionAuto: return NSLocalizedString(@"Automatisch", nil);
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case TSSectionModel:
            return NSLocalizedString(@"WhisperKit nutzt Core ML/GPU und läuft nur im Vordergrund; beim Verlassen der App wird pausiert. Apple-Spracherkennung benötigt keinen Download und kann im Hintergrund weiterlaufen, wenn iOS dafür Zeit gibt.", nil);
        case TSSectionChapters: {
            if ([ChapterGenerator isAvailable]) {
                return NSLocalizedString(@"Apple Intelligence erkennt Themenwechsel und Werbung im Transkript und erzeugt daraus Kapitel. Sponsoren-Kapitel können automatisch übersprungen werden. Folgen mit vorhandenen Kapiteln bleiben unverändert.", nil);
            }
            NSString* reason = [ChapterGenerator unavailabilityReason];
            return reason ?: NSLocalizedString(@"Apple Intelligence nicht verfügbar. Für automatische Kapitel und Sponsor-Erkennung wird Apple Intelligence benötigt.", nil);
        }
        case TSSectionAuto:
            return NSLocalizedString(@"Voreinstellungen für alle Podcasts. Kann pro Podcast in den Podcast-Einstellungen angepasst werden.", nil);
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case TSSectionModel: {
            if (![self _isWhisperKit]) return 1; // Just the picker row
            BOOL downloaded = [[TranscriptionEngine shared] isModelDownloaded];
            return downloaded ? 3 : 2; // picker + (download OR ready) + (delete if downloaded)
        }
        case TSSectionChapters: return 2;
        case TSSectionAuto: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case TSSectionModel: return [self _modelCellForRow:indexPath.row];
        case TSSectionChapters: return [self _chaptersCellForRow:indexPath.row];
        case TSSectionAuto: return [self _autoCellForRow:indexPath.row];
        default: return [[UITableViewCell alloc] init];
    }
}

#pragma mark - Model Section (Combined Engine + Model)

- (UITableViewCell *)_modelCellForRow:(NSInteger)row {
    switch (row) {
        case 0: {
            // Combined engine+model picker
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            cell.textLabel.text = NSLocalizedString(@"Sprachmodell", nil);
            cell.detailTextLabel.text = [self _modelDisplayName];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case 1: {
            // Download / Ready status
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            BOOL downloaded = [[TranscriptionEngine shared] isModelDownloaded];

            if (self.isDownloadingModel) {
                int64_t currentSize = [[TranscriptionEngine shared] modelSizeOnDisk];
                NSString *currentSizeStr = [NSByteCountFormatter stringFromByteCount:currentSize countStyle:NSByteCountFormatterCountStyleFile];
                cell.textLabel.text = NSLocalizedString(@"Wird geladen...", nil);
                cell.detailTextLabel.text = currentSizeStr;
                cell.textLabel.textColor = ICTintColor;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [spinner startAnimating];
                cell.accessoryView = spinner;
            } else if (!downloaded) {
                cell.textLabel.text = NSLocalizedString(@"Modell herunterladen", nil);
                cell.textLabel.textColor = ICTintColor;
                cell.detailTextLabel.text = [self _modelSizeText];
            } else {
                cell.textLabel.text = NSLocalizedString(@"Bereit", nil);
                cell.textLabel.textColor = [UIColor systemGreenColor];
                int64_t size = [[TranscriptionEngine shared] modelSizeOnDisk];
                cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:size countStyle:NSByteCountFormatterCountStyleFile];
                cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
                cell.imageView.tintColor = [UIColor systemGreenColor];
            }
            return cell;
        }
        case 2: {
            // Delete model (only shown when downloaded)
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = NSLocalizedString(@"Modell löschen", nil);
            cell.textLabel.textColor = [UIColor systemRedColor];
            return cell;
        }
        default: return [[UITableViewCell alloc] init];
    }
}

- (NSString *)_modelDisplayName {
    if (![self _isWhisperKit]) return @"Apple";
    NSString *model = [TranscriptionEngine resolvedModelName];
    if ([model containsString:@"large"]) return @"WhisperKit Large V3";
    return @"WhisperKit Small";
}

- (NSString *)_modelSizeText {
    NSString *model = [TranscriptionEngine resolvedModelName];
    if ([model containsString:@"large"]) return @"~645 MB";
    return @"~216 MB";
}

#pragma mark - Chapters Section

- (UITableViewCell *)_chaptersCellForRow:(NSInteger)row {
    if (row == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if ([ChapterGenerator isAvailable]) {
            cell.textLabel.text = NSLocalizedString(@"Apple Intelligence aktiv", nil);
            cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
            cell.imageView.tintColor = [UIColor systemGreenColor];
        } else {
            cell.textLabel.text = NSLocalizedString(@"Apple Intelligence nicht aktiviert", nil);
            cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
            cell.imageView.tintColor = [UIColor systemOrangeColor];
            cell.textLabel.numberOfLines = 0;
        }
        return cell;
    } else {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = NSLocalizedString(@"Sponsoren überspringen", nil);
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [USER_DEFAULTS boolForKey:kAutoSkipSponsors];
        [toggle addTarget:self action:@selector(_sponsorToggle:) forControlEvents:UIControlEventValueChanged];
        toggle.enabled = [ChapterGenerator isAvailable];
        cell.accessoryView = toggle;
        return cell;
    }
}

- (void)_sponsorToggle:(UISwitch *)toggle {
    [USER_DEFAULTS setBool:toggle.isOn forKey:kAutoSkipSponsors];
}

#pragma mark - Auto Section (moved to bottom)

- (UITableViewCell *)_autoCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.tag = row;
    [toggle addTarget:self action:@selector(_autoToggle:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;

    switch (row) {
        case 0:
            cell.textLabel.text = NSLocalizedString(@"Neue Folgen transkribieren", nil);
            toggle.on = [USER_DEFAULTS boolForKey:kTranscriptionAutoDefault];
            break;
        case 1:
            cell.textLabel.text = NSLocalizedString(@"Neue Folgen Chapters generieren", nil);
            toggle.on = [USER_DEFAULTS boolForKey:kChapterAutoDefault];
            toggle.enabled = [ChapterGenerator isAvailable];
            break;
    }
    return cell;
}

- (void)_autoToggle:(UISwitch *)toggle {
    if (toggle.tag == 0) [USER_DEFAULTS setBool:toggle.isOn forKey:kTranscriptionAutoDefault];
    else [USER_DEFAULTS setBool:toggle.isOn forKey:kChapterAutoDefault];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section != TSSectionModel) return;

    switch (indexPath.row) {
        case 0: [self _showCombinedModelPicker]; break;
        case 1: [self _handleModelAction]; break;
        case 2: [self _handleDeleteModel]; break;
    }
}

- (void)_showCombinedModelPicker {
    // Persist combined value so the picker shows the current selection
    [USER_DEFAULTS setObject:[self _combinedValue] forKey:@"TranscriptionModelCombined"];

    SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];
    controller.valueType = kSettingTypeString;
    controller.key = @"TranscriptionModelCombined";
    controller.titleStr = NSLocalizedString(@"Sprachmodell", nil);

    NSMutableArray* values = [NSMutableArray array];
    NSMutableArray* titles = [NSMutableArray array];

    BOOL largeAvailable = [self _isLargeAvailableOnDevice];
    NSString* recEngine = [TranscriptionEngine recommendedEngine] == ICTranscriptionEngineTypeWhisperKit ? @"WhisperKit" : @"Apple";

    if (largeAvailable) {
        [values addObject:kCombinedWhisperLarge];
        NSString* rec = [recEngine isEqualToString:@"WhisperKit"] ? NSLocalizedString(@" (empfohlen)", nil) : @"";
        [titles addObject:[NSString stringWithFormat:@"WhisperKit Large V3 Turbo (~645 MB, %@)%@",
                           NSLocalizedString(@"nur Vordergrund", nil), rec]];
    }

    [values addObject:kCombinedWhisperSmall];
    {
        NSString* rec = (!largeAvailable && [recEngine isEqualToString:@"WhisperKit"]) ? NSLocalizedString(@" (empfohlen)", nil) : @"";
        [titles addObject:[NSString stringWithFormat:@"WhisperKit Small (~216 MB, %@)%@",
                           NSLocalizedString(@"nur Vordergrund", nil), rec]];
    }

    [values addObject:kCombinedApple];
    {
        NSString* rec = [recEngine isEqualToString:@"Apple"] ? NSLocalizedString(@" (empfohlen)", nil) : @"";
        [titles addObject:[NSString stringWithFormat:@"Apple Spracherkennung (%@)%@",
                           NSLocalizedString(@"Hintergrund möglich", nil), rec]];
    }

    controller.values = values;
    controller.titles = titles;
    controller.footerText = NSLocalizedString(@"Large V3 Turbo: Beste Genauigkeit (98%), ~645 MB, 8 GB RAM.\nSmall: Gute Genauigkeit (94%), ~216 MB, 2 GB RAM.\nWhisperKit läuft wegen Core ML/GPU nur im Vordergrund. Apple-Spracherkennung benötigt keinen Download und kann im Hintergrund weiterlaufen, wenn iOS dafür Zeit gibt.", nil);

    [self.navigationController pushViewController:controller animated:YES];
}

- (void)_handleModelAction {
    if (self.isDownloadingModel) {
        return;
    }

    if ([[TranscriptionEngine shared] isModelDownloaded]) {
        return;
    }

    // Download model
    self.isDownloadingModel = YES;
    [self.tableView reloadData];

    self.downloadProgressTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        [self.tableView reloadData];
    }];

    WEAK_SELF
    [[TranscriptionEngine shared] downloadModelWithProgress:^(float progress) {
    } completion:^(NSError *error) {
        STRONG_SELF
        self.isDownloadingModel = NO;
        [self.downloadProgressTimer invalidate];
        self.downloadProgressTimer = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [self _showError:error.localizedDescription];
            }
            [self.tableView reloadData];
        });
    }];
}

- (void)_handleDeleteModel {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Modell löschen?", nil)
                                                                  message:NSLocalizedString(@"Das Sprachmodell wird gelöscht und muss erneut geladen werden.", nil)
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Löschen", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[TranscriptionEngine shared] deleteModel];
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_showError:(NSString*)msg {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Fehler", nil) message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
