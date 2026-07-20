//
//  TranscriptionSettingsViewController.m
//  Instacast
//
//  Settings UI for "Transkription und Kapitel".
//

#import "TranscriptionSettingsViewController.h"
#import "TranscriptionQueueViewController.h"
#import "InstacastPlus-Swift.h"

@interface ICModelLibraryViewController : UITableViewController
@property (nonatomic, assign) BOOL focusVoiceToText;
@property (nonatomic, assign) ICDownloadableModelRole modelRole;
@property (nonatomic, strong) NSMutableSet<NSString *> *busyModelIDs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ICModelDownloadTask *> *downloadTasksByModelID;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ICModelDownloadProgress *> *downloadProgressByModelID;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

typedef NS_ENUM(NSInteger, TSSection) {
    TSSectionEnabled = 0,
    TSSectionIntro,
    TSSectionModels,
    TSSectionCloud,
    TSSectionChapters,
    TSSectionAuto,
    TSSectionCount
};

typedef NS_ENUM(NSInteger, ICTranscriptionSettingsPage) {
    ICTranscriptionSettingsPageHub = 0,
    ICTranscriptionSettingsPageLocal,
    ICTranscriptionSettingsPageServer
};

@interface TranscriptionSettingsViewController ()
@property (nonatomic, assign) ICTranscriptionSettingsPage pageMode;
@end

@implementation TranscriptionSettingsViewController

+ (UIViewController *)modelLibraryViewController {
    return [self modelLibraryViewControllerFocusedOnVoiceToText:YES];
}

+ (UIViewController *)modelLibraryViewControllerFocusedOnVoiceToText:(BOOL)voiceToText {
    ICModelLibraryViewController *controller = [[ICModelLibraryViewController alloc] initWithStyle:UITableViewStyleGrouped];
    controller.focusVoiceToText = voiceToText;
    controller.modelRole = voiceToText ? ICDownloadableModelRoleVoiceToText : ICDownloadableModelRoleTextToChapters;
    return controller;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    switch (self.pageMode) {
        case ICTranscriptionSettingsPageLocal:
            self.title = NSLocalizedString(@"Lokale Transkription", nil);
            break;
        case ICTranscriptionSettingsPageServer:
            self.title = NSLocalizedString(@"Serverbasierte Transkription", nil);
            break;
        case ICTranscriptionSettingsPageHub:
        default:
            self.title = NSLocalizedString(@"Transkription und Kapitel", nil);
            break;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                 name:@"ICTranscriptionQueueDidChangeNotification" object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_reload { [self.tableView reloadData]; }

#pragma mark - Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.pageMode == ICTranscriptionSettingsPageHub) return 1;
    if (self.pageMode == ICTranscriptionSettingsPageServer) return 0;
    return TSSectionCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.pageMode != ICTranscriptionSettingsPageLocal) return nil;
    switch (section) {
        case TSSectionEnabled: return nil;
        case TSSectionIntro: return nil;
        case TSSectionModels: return nil;
        case TSSectionCloud: return NSLocalizedString(@"Cloud-Zugänge", nil);
        case TSSectionChapters: return NSLocalizedString(@"Kapitel & Sponsoren", nil);
        case TSSectionAuto: return NSLocalizedString(@"Automatisch", nil);
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.pageMode != ICTranscriptionSettingsPageLocal) return nil;
    switch (section) {
        case TSSectionEnabled:
            return NSLocalizedString(@"Wenn deaktiviert, werden keine neuen lokalen Transkriptions- oder Kapitelaufträge gestartet und die Aktionen in Episodenmenüs ausgeblendet. Bereits laufende Aufträge werden nicht abgebrochen.", nil);
        case TSSectionIntro:
            return nil;
        case TSSectionModels:
            return nil;
        case TSSectionCloud:
            return nil;
        case TSSectionChapters:
            return NSLocalizedString(@"Sponsoren-Kapitel können automatisch übersprungen werden. Vorhandene Podcast-Kapitel bleiben erhalten und werden um erkannte Sponsorsegmente ergänzt. Zusammenfassungen benötigen ein Remote-Kapitelmodell.", nil);
        case TSSectionAuto:
            return NSLocalizedString(@"Voreinstellungen für alle Podcasts. Kann pro Podcast in den Podcast-Einstellungen angepasst werden.", nil);
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.pageMode == ICTranscriptionSettingsPageHub) return 2;
    if (self.pageMode == ICTranscriptionSettingsPageServer) return 0;
    switch (section) {
        case TSSectionEnabled: return 1;
        case TSSectionIntro: return 1;
        case TSSectionModels: return 2;
        case TSSectionCloud: return 4;
        case TSSectionChapters: return 1;
        case TSSectionAuto: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.pageMode == ICTranscriptionSettingsPageHub) return [self _hubCellForRow:indexPath.row];
    switch (indexPath.section) {
        case TSSectionEnabled: return [self _enabledCell];
        case TSSectionIntro: return [self _introCell];
        case TSSectionModels: return [self _modelCellForRow:indexPath.row];
        case TSSectionCloud: return [self _cloudCellForRow:indexPath.row];
        case TSSectionChapters: return [self _chaptersCellForRow:indexPath.row];
        case TSSectionAuto: return [self _autoCellForRow:indexPath.row];
        default: return [[UITableViewCell alloc] init];
    }
}

#pragma mark - Hub

- (UITableViewCell *)_hubCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (row == 0) {
        cell.textLabel.text = NSLocalizedString(@"Lokale Transkription", nil);
        cell.detailTextLabel.text = [USER_DEFAULTS boolForKey:kLocalTranscriptionEnabled]
            ? NSLocalizedString(@"Ein", nil)
            : NSLocalizedString(@"Aus", nil);
    } else {
        cell.textLabel.text = NSLocalizedString(@"Serverbasierte Transkription", nil);
        cell.detailTextLabel.text = NSLocalizedString(@"In Vorbereitung", nil);
    }
    return cell;
}

#pragma mark - Enabled Section

- (UITableViewCell *)_enabledCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = NSLocalizedString(@"Lokale Transkription aktivieren", nil);
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [USER_DEFAULTS boolForKey:kLocalTranscriptionEnabled];
    [toggle addTarget:self action:@selector(_localTranscriptionToggle:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)_localTranscriptionToggle:(UISwitch *)toggle {
    [USER_DEFAULTS setBool:toggle.isOn forKey:kLocalTranscriptionEnabled];
}

#pragma mark - Intro Section

- (UITableViewCell *)_introCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.textColor = ICMutedTextColor;
    cell.textLabel.text = NSLocalizedString(@"Long Press auf eine Episode und wähle „Transkribieren“ oder „Kapitel generieren“ im Kontextmenü. Den Fortschritt siehst du direkt im Menü Transkribieren. Im Player blendest du Transkripte über das Sprechblasen-Symbol in der unteren Werkzeugleiste ein.\nTranskribieren und Kapitel-Erstellen ist in der Beta-Phase.", nil);
    return cell;
}

#pragma mark - Model Section

- (UITableViewCell *)_modelCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (row == 0) {
        ICDownloadableModel *model = [ICDownloadableModelStore selectedModelForRole:ICDownloadableModelRoleVoiceToText];
        cell.textLabel.text = NSLocalizedString(@"Transkribieren", nil);
        cell.detailTextLabel.text = [self _summaryForModel:model];
        return cell;
    }

    if (row == 1) {
        ICDownloadableModel *model = [ICDownloadableModelStore selectedModelForRole:ICDownloadableModelRoleTextToChapters];
        cell.textLabel.text = NSLocalizedString(@"Kapitel generieren", nil);
        cell.detailTextLabel.text = [self _summaryForModel:model];
        return cell;
    }

    return cell;
}

- (NSString *)_summaryForModel:(ICDownloadableModel *)model {
    if (![model requiresDownload]) return model.shortTitle;
    if ([ICDownloadableModelStore isDownloadedModel:model]) {
        return [NSString stringWithFormat:@"%@ · %@", model.shortTitle,
                [NSByteCountFormatter stringFromByteCount:[ICDownloadableModelStore sizeOnDiskForModel:model]
                                                countStyle:NSByteCountFormatterCountStyleFile]];
    }
    return [NSString stringWithFormat:@"%@ · %@", model.shortTitle, NSLocalizedString(@"nicht geladen", nil)];
}

#pragma mark - Cloud Section

- (UITableViewCell *)_cloudCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    switch (row) {
        case 0:
            cell.textLabel.text = @"Anthropic API-Key";
            cell.detailTextLabel.text = [ICRemoteChapterCredentialStore anthropicAPIKeyPreview];
            break;
        case 1:
            cell.textLabel.text = @"OpenAI API-Key";
            cell.detailTextLabel.text = [ICRemoteChapterCredentialStore openAIAPIKeyPreview];
            break;
        case 2:
            cell.textLabel.text = @"OpenAI Codex Login";
            cell.detailTextLabel.text = [ICRemoteChapterCredentialStore hasOpenAIOAuthCredentials] ? [ICRemoteChapterCredentialStore openAIOAuthAccountLabel] : NSLocalizedString(@"Gerätecode erstellen", nil);
            break;
        case 3:
            cell.textLabel.text = @"Kimi API-Key";
            cell.detailTextLabel.text = [ICRemoteChapterCredentialStore kimiAPIKeyPreview];
            break;
    }
    return cell;
}

- (void)_showOpenAIAPIKeyEditor {
    [self _showAPIKeyEditorWithTitle:@"OpenAI API-Key"
                              message:NSLocalizedString(@"Der Key wird im iOS-Keychain gespeichert und nur für OpenAI Kapitelmodelle verwendet.", nil)
                          placeholder:@"sk-..."
                  keyCreationURLString:@"https://platform.openai.com/api-keys"
                         isConfigured:[ICRemoteChapterCredentialStore hasOpenAIAPIKey]
                          saveHandler:^(NSString *value) {
        [ICRemoteChapterCredentialStore setOpenAIAPIKey:value];
    } deleteHandler:^{
        [ICRemoteChapterCredentialStore setOpenAIAPIKey:nil];
    }];
}

- (void)_showAnthropicAPIKeyEditor {
    [self _showAPIKeyEditorWithTitle:@"Anthropic API-Key"
                              message:NSLocalizedString(@"Der Key wird im iOS-Keychain gespeichert und nur für Anthropic Kapitelmodelle verwendet.", nil)
                          placeholder:@"sk-ant-..."
                  keyCreationURLString:@"https://console.anthropic.com/settings/keys"
                         isConfigured:[ICRemoteChapterCredentialStore hasAnthropicAPIKey]
                          saveHandler:^(NSString *value) {
        [ICRemoteChapterCredentialStore setAnthropicAPIKey:value];
    } deleteHandler:^{
        [ICRemoteChapterCredentialStore setAnthropicAPIKey:nil];
    }];
}

- (void)_showKimiAPIKeyEditor {
    [self _showAPIKeyEditorWithTitle:@"Kimi API-Key"
                              message:NSLocalizedString(@"Eigener Key wird im iOS-Keychain gespeichert und überschreibt den integrierten Kimi-Zugang.", nil)
                          placeholder:@"sk-..."
                  keyCreationURLString:@"https://platform.kimi.ai/console/api-keys"
                         isConfigured:[ICRemoteChapterCredentialStore hasKimiUserAPIKey]
                          saveHandler:^(NSString *value) {
        [ICRemoteChapterCredentialStore setKimiAPIKey:value];
    } deleteHandler:^{
        [ICRemoteChapterCredentialStore setKimiAPIKey:nil];
    }];
}

- (void)_showAPIKeyEditorWithTitle:(NSString *)title
                           message:(NSString *)message
                       placeholder:(NSString *)placeholder
               keyCreationURLString:(NSString *)keyCreationURLString
                      isConfigured:(BOOL)isConfigured
                       saveHandler:(void (^)(NSString *value))saveHandler
                     deleteHandler:(void (^)(void))deleteHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = placeholder;
        textField.secureTextEntry = YES;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        UIButton *pasteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [pasteButton setTitle:NSLocalizedString(@"Einfügen", nil) forState:UIControlStateNormal];
        pasteButton.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
        [pasteButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            NSString *clipboardValue = UIPasteboard.generalPasteboard.string;
            if (clipboardValue.length > 0) {
                textField.text = clipboardValue;
            }
        }] forControlEvents:UIControlEventTouchUpInside];
        textField.rightView = pasteButton;
        textField.rightViewMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Speichern", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *value = alert.textFields.firstObject.text ?: @"";
        saveHandler(value);
        [self.tableView reloadData];
    }]];
    if (isConfigured) {
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Entfernen", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            deleteHandler();
            [self.tableView reloadData];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Key erstellen", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _openURLString:keyCreationURLString];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_openURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)_showOpenAIOAuthLogin {
    if ([ICRemoteChapterCredentialStore hasOpenAIOAuthCredentials]) {
        UIAlertController *existing = [UIAlertController alertControllerWithTitle:@"OpenAI Codex Login"
                                                                          message:[ICRemoteChapterCredentialStore openAIOAuthAccountLabel]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [existing addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Neu anmelden", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self _requestOpenAIDeviceCode];
        }]];
        [existing addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abmelden", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [ICRemoteChapterCredentialStore clearOpenAIOAuthCredentials];
            [self.tableView reloadData];
        }]];
        [existing addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:existing animated:YES completion:nil];
        return;
    }
    [self _requestOpenAIDeviceCode];
}

- (void)_requestOpenAIDeviceCode {
    self.navigationItem.prompt = NSLocalizedString(@"Codex Gerätecode wird geladen…", nil);
    [ICRemoteChapterCredentialStore requestOpenAIDeviceCodeWithCompletion:^(ICOpenAIDeviceCodeInfo *info, NSError *error) {
        self.navigationItem.prompt = nil;
        if (error) {
            [self _showError:error.localizedDescription];
            return;
        }
        if (!info) return;
        [self _showOpenAIDeviceCode:info];
    }];
}

- (void)_showOpenAIDeviceCode:(ICOpenAIDeviceCodeInfo *)info {
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@",
                         info.verificationURL,
                         info.userCode,
                         NSLocalizedString(@"Nach dem Login wartet die App bis zu 15 Minuten auf die Freigabe.", nil)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Codex Login", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Code kopieren", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = info.userCode;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self _showOpenAIDeviceCode:info];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Browser öffnen", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:info.verificationURL];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
        [self _completeOpenAIDeviceLogin:info];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Ich habe den Code eingegeben", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _completeOpenAIDeviceLogin:info];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_completeOpenAIDeviceLogin:(ICOpenAIDeviceCodeInfo *)info {
    self.navigationItem.prompt = NSLocalizedString(@"Warte auf Codex Login…", nil);
    [ICRemoteChapterCredentialStore completeOpenAIDeviceLoginWithDeviceCode:info completion:^(NSError *error) {
        self.navigationItem.prompt = nil;
        if (error) {
            [self _showError:error.localizedDescription];
        }
        [self.tableView reloadData];
    }];
}

#pragma mark - Chapters Section

- (UITableViewCell *)_chaptersCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = NSLocalizedString(@"Sponsoren überspringen", nil);
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [USER_DEFAULTS boolForKey:kAutoSkipSponsors];
    [toggle addTarget:self action:@selector(_sponsorToggle:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)_sponsorToggle:(UISwitch *)toggle {
    [USER_DEFAULTS setBool:toggle.isOn forKey:kAutoSkipSponsors];
}

#pragma mark - Auto Section

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
            cell.textLabel.text = NSLocalizedString(@"Neue Folgen analysieren", nil);
            toggle.on = [USER_DEFAULTS boolForKey:kChapterAutoDefault];
            break;
    }
    return cell;
}

- (void)_autoToggle:(UISwitch *)toggle {
    if (toggle.tag == 0) {
        [USER_DEFAULTS setBool:toggle.isOn forKey:kTranscriptionAutoDefault];
        return;
    }

    if (toggle.isOn) {
        if (![ICDownloadableModelStore selectedChapterModelCanGenerate]) {
            toggle.on = NO;
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Automatische Analyse einrichten", nil)
                                                                           message:[ICDownloadableModelStore selectedChapterModelUnavailableReason]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Kapitelmodell auswählen", nil)
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction* action) {
                UIViewController* controller = [TranscriptionSettingsViewController modelLibraryViewControllerFocusedOnVoiceToText:NO];
                [self.navigationController pushViewController:controller animated:YES];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil)
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
    }
    [USER_DEFAULTS setBool:toggle.isOn forKey:kChapterAutoDefault];
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.pageMode == ICTranscriptionSettingsPageHub) {
        TranscriptionSettingsViewController *controller = [[TranscriptionSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
        controller.pageMode = indexPath.row == 0 ? ICTranscriptionSettingsPageLocal : ICTranscriptionSettingsPageServer;
        [self.navigationController pushViewController:controller animated:YES];
        return;
    }
    if (indexPath.section == TSSectionCloud) {
        if (indexPath.row == 0) [self _showAnthropicAPIKeyEditor];
        else if (indexPath.row == 1) [self _showOpenAIAPIKeyEditor];
        else if (indexPath.row == 2) [self _showOpenAIOAuthLogin];
        else if (indexPath.row == 3) [self _showKimiAPIKeyEditor];
        return;
    }
    if (indexPath.section != TSSectionModels) return;
    if (indexPath.row > 1) return;

    BOOL focusVoice = indexPath.row != 1;
    UIViewController *controller = [TranscriptionSettingsViewController modelLibraryViewControllerFocusedOnVoiceToText:focusVoice];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)_showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Fehler", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Model Library

@implementation ICModelLibraryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.modelRole == ICDownloadableModelRoleVoiceToText ? NSLocalizedString(@"Transkribieren", nil) : NSLocalizedString(@"Kapitel generieren", nil);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 96.f;
    self.busyModelIDs = [NSMutableSet set];
    self.downloadTasksByModelID = [NSMutableDictionary dictionary];
    self.downloadProgressByModelID = [NSMutableDictionary dictionary];
    if ([self _hasBusyModels]) {
        [self _startRefreshTimerIfNeeded];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_reload)
                                                 name:@"ICTranscriptionQueueDidChangeNotification" object:nil];
    [self _updateBlockedHeader];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if ([self _hasBusyModels]) {
        [self _startRefreshTimerIfNeeded];
    }
    [self _updateBlockedHeader];
    [self.tableView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.refreshTimer invalidate];
}

- (void)_reload {
    [self _updateBlockedHeader];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.modelRole == ICDownloadableModelRoleVoiceToText ? NSLocalizedString(@"Transkribieren", nil) : NSLocalizedString(@"Kapitel generieren", nil);
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSString *deleteHint = NSLocalizedString(@"Geladene Modelle kannst du per Swipe nach links löschen.", nil);
    if (self.modelRole == ICDownloadableModelRoleVoiceToText) {
        return [NSString stringWithFormat:@"%@\n%@", NSLocalizedString(@"Wähle das Modell für Transkriptionen. Wenn es fehlt, wird es heruntergeladen und vorbereitet.", nil), deleteHint];
    }
    return [NSString stringWithFormat:@"%@\n%@", NSLocalizedString(@"Wähle das Modell für Kapitel. Wenn es fehlt, wird es heruntergeladen und vorbereitet.", nil), deleteHint];
}

- (NSArray<ICDownloadableModel *> *)_modelsForSection:(NSInteger)section {
    return [ICDownloadableModelStore modelsForRole:self.modelRole];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self _modelsForSection:section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    ICDownloadableModel *model = [self _modelsForSection:indexPath.section][indexPath.row];
    BOOL selected = [[[ICDownloadableModelStore selectedModelForRole:model.role] identifier] isEqualToString:model.identifier];
    BOOL downloaded = [ICDownloadableModelStore isDownloadedModel:model];
    BOOL busy = [self _isBusyModel:model];
    BOOL remoteMissingCredentials = model.usesRemoteChapterService && ![self _remoteCredentialsReadyForModel:model];

    cell.textLabel.text = model.shortTitle;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = [self _detailTextForModel:model downloaded:downloaded busy:busy selected:selected];
    cell.accessoryType = selected && !busy && (downloaded || !model.requiresDownload) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = ICTintColor;

    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    } else {
        cell.accessoryView = nil;
    }

    if (busy) {
        cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle"];
        cell.imageView.tintColor = ICTintColor;
    } else if (remoteMissingCredentials) {
        cell.imageView.image = [UIImage systemImageNamed:@"exclamationmark.circle"];
        cell.imageView.tintColor = [UIColor systemOrangeColor];
    } else if (downloaded || !model.requiresDownload) {
        cell.imageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
        cell.imageView.tintColor = [UIColor systemGreenColor];
    } else {
        cell.imageView.image = [UIImage systemImageNamed:@"arrow.down.circle"];
        cell.imageView.tintColor = ICTintColor;
    }

    return cell;
}

- (NSString *)_detailTextForModel:(ICDownloadableModel *)model downloaded:(BOOL)downloaded busy:(BOOL)busy selected:(BOOL)selected {
    if (busy) {
        return [NSString stringWithFormat:@"%@\n%@", [self _downloadProgressTextForModel:model], model.detail];
    }
    NSString *blockedReason = [[TranscriptionQueue shared] modelMutationBlockReasonForRole:model.role];
    if (blockedReason.length > 0) {
        return model.detail;
    }
    if (model.usesRemoteChapterService) {
        NSString *credentialState = [self _remoteCredentialsReadyForModel:model]
            ? NSLocalizedString(@"Zugangsdaten eingerichtet.", nil)
            : NSLocalizedString(@"Zugangsdaten fehlen.", nil);
        return [NSString stringWithFormat:@"%@\n%@", credentialState, model.detail];
    }
    if (!model.requiresDownload) {
        return model.detail;
    }
    if (downloaded) {
        NSString *size = [NSByteCountFormatter stringFromByteCount:[ICDownloadableModelStore sizeOnDiskForModel:model]
                                                        countStyle:NSByteCountFormatterCountStyleFile];
        NSString *prepare = NSLocalizedString(@"Geladen und vorbereitet.", nil);
        return [NSString stringWithFormat:@"%@ · %@\n%@", size, prepare, model.detail];
    }
    if (selected) {
        return [NSString stringWithFormat:@"%@ · %@ %@\n%@",
                NSLocalizedString(@"Ausgewählt, noch nicht geladen", nil),
                NSLocalizedString(@"Download", nil),
                model.downloadSizeText,
                model.detail];
    }
    return [NSString stringWithFormat:@"%@ %@\n%@", NSLocalizedString(@"Download", nil), model.downloadSizeText, model.detail];
}

- (NSString *)_downloadProgressTextForModel:(ICDownloadableModel *)model {
    ICModelDownloadProgress *progress = self.downloadProgressByModelID[model.identifier] ?: [ICDownloadableModelStore downloadProgressForModel:model];
    if (progress) {
        return progress.displayText;
    }
    return NSLocalizedString(@"Download wird vorbereitet.", nil);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ICDownloadableModel *model = [self _modelsForSection:indexPath.section][indexPath.row];
    NSString *blockedReason = [[TranscriptionQueue shared] modelMutationBlockReasonForRole:model.role];
    if (blockedReason.length > 0) {
        [self _showError:blockedReason];
        return;
    }
    [ICDownloadableModelStore selectModel:model];
    if (model.usesRemoteChapterService && ![self _remoteCredentialsReadyForModel:model]) {
        [self _showCredentialSetupForModel:model];
        [self.tableView reloadData];
        return;
    }

    if (model.requiresDownload && ![ICDownloadableModelStore isDownloadedModel:model]) {
        [self _startDownloadForModel:model];
        return;
    }

    [self.tableView reloadData];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    ICDownloadableModel *model = [self _modelsForSection:indexPath.section][indexPath.row];
    if ([ICDownloadableModelStore isDownloadingModel:model]) {
        UIContextualAction *cancelAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                                   title:NSLocalizedString(@"Abbrechen", nil)
                                                                                 handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self _cancelDownloadForModel:model];
            completionHandler(YES);
        }];
        return [UISwipeActionsConfiguration configurationWithActions:@[cancelAction]];
    }

    if ([self.busyModelIDs containsObject:model.identifier]) return nil;
    if (!model.requiresDownload) return nil;
    if ([[TranscriptionQueue shared] modelMutationBlockReasonForRole:model.role].length > 0) return nil;

    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray array];
    BOOL downloaded = [ICDownloadableModelStore isDownloadedModel:model];

    if (downloaded) {
        UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                                   title:NSLocalizedString(@"Löschen", nil)
                                                                                 handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [self _deleteModel:model];
            completionHandler(YES);
        }];
        [actions addObject:deleteAction];

        if (model.supportsCompilation) {
            UIContextualAction *compileAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                                       title:NSLocalizedString(@"Vorbereiten", nil)
                                                                                     handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
                [self _prepareModel:model];
                completionHandler(YES);
            }];
            compileAction.backgroundColor = ICTintColor;
            [actions addObject:compileAction];
        }
    } else {
        UIContextualAction *downloadAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                                    title:NSLocalizedString(@"Laden", nil)
                                                                                  handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            [ICDownloadableModelStore selectModel:model];
            [self _startDownloadForModel:model];
            completionHandler(YES);
        }];
        downloadAction.backgroundColor = ICTintColor;
        [actions addObject:downloadAction];
    }

    return [UISwipeActionsConfiguration configurationWithActions:actions];
}

- (void)_startDownloadForModel:(ICDownloadableModel *)model {
    if ([self _isBusyModel:model]) return;

    [self.busyModelIDs addObject:model.identifier];
    [self.downloadProgressByModelID removeObjectForKey:model.identifier];
    [self _startRefreshTimerIfNeeded];
    [self.tableView reloadData];

    ICModelDownloadTask *task = [ICDownloadableModelStore downloadModel:model detailProgress:^(ICModelDownloadProgress *progress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.downloadProgressByModelID[model.identifier] = progress;
            [self.tableView reloadData];
        });
    } completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.downloadTasksByModelID removeObjectForKey:model.identifier];
            [self.downloadProgressByModelID removeObjectForKey:model.identifier];
            [self.busyModelIDs removeObject:model.identifier];
            [self _stopRefreshTimerIfIdle];
            if (error && !([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)) {
                [self _showError:error.localizedDescription];
            }
            [self.tableView reloadData];
        });
    }];
    self.downloadTasksByModelID[model.identifier] = task;
}

- (void)_cancelDownloadForModel:(ICDownloadableModel *)model {
    [ICDownloadableModelStore cancelDownloadForModel:model];
    [self.tableView reloadData];
}

- (void)_prepareModel:(ICDownloadableModel *)model {
    if ([self.busyModelIDs containsObject:model.identifier]) return;
    [self.busyModelIDs addObject:model.identifier];
    [self _startRefreshTimerIfNeeded];
    [self.tableView reloadData];

    [ICDownloadableModelStore prepareModel:model completion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.busyModelIDs removeObject:model.identifier];
            [self _stopRefreshTimerIfIdle];
            if (error) {
                [self _showError:error.localizedDescription];
            }
            [self.tableView reloadData];
        });
    }];
}

- (void)_deleteModel:(ICDownloadableModel *)model {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Modell löschen?", nil)
                                                                  message:model.title
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Löschen", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [ICDownloadableModelStore deleteModel:model completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    [self _showError:error.localizedDescription];
                }
                [self.tableView reloadData];
            });
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_startRefreshTimerIfNeeded {
    if (self.refreshTimer) return;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [self.tableView reloadData];
        [self _stopRefreshTimerIfIdle];
    }];
}

- (void)_stopRefreshTimerIfIdle {
    if ([self _hasBusyModels]) return;
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (BOOL)_isBusyModel:(ICDownloadableModel *)model {
    return [self.busyModelIDs containsObject:model.identifier] || [ICDownloadableModelStore isDownloadingModel:model];
}

- (BOOL)_hasBusyModels {
    if (self.busyModelIDs.count > 0) return YES;
    for (ICDownloadableModel *model in [self _modelsForSection:0]) {
        if ([ICDownloadableModelStore isDownloadingModel:model]) return YES;
    }
    return NO;
}

- (NSString *)_modelMutationBlockedMessage {
    NSString *blockedReason = [[TranscriptionQueue shared] modelMutationBlockReasonForRole:self.modelRole];
    if (blockedReason.length == 0) return nil;
    return NSLocalizedString(@"Modell kann während einer laufenden Transkription oder Episodenanalyse nicht geändert werden.", nil);
}

- (void)_updateBlockedHeader {
    NSString *message = [self _modelMutationBlockedMessage];
    if (message.length == 0) {
        self.tableView.tableHeaderView = nil;
        return;
    }

    CGFloat width = CGRectGetWidth(self.tableView.bounds);
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 62)];
    header.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, MAX(0, width - 32), 22)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.textColor = ICMutedTextColor;
    label.text = message;
    label.numberOfLines = 0;
    [header addSubview:label];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(16, 32, MAX(0, width - 32), 24);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    [button setTitle:NSLocalizedString(@"Transkription", nil) forState:UIControlStateNormal];
    [button addTarget:self action:@selector(_openTranscriptionQueue) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:button];

    self.tableView.tableHeaderView = header;
}

- (void)_openTranscriptionQueue {
    TranscriptionQueueViewController *controller = [[TranscriptionQueueViewController alloc] initWithStyle:UITableViewStylePlain];
    [self.navigationController pushViewController:controller animated:YES];
}

- (BOOL)_remoteCredentialsReadyForModel:(ICDownloadableModel *)model {
    switch (model.chapterProvider) {
        case ICChapterModelProviderOpenAIAPI:
            return [ICRemoteChapterCredentialStore hasOpenAIAPIKey];
        case ICChapterModelProviderOpenAICodexOAuth:
            return [ICRemoteChapterCredentialStore hasOpenAIAPIKey] || [ICRemoteChapterCredentialStore hasOpenAIOAuthCredentials];
        case ICChapterModelProviderAnthropicAPI:
            return [ICRemoteChapterCredentialStore hasAnthropicAPIKey];
        case ICChapterModelProviderKimiAPI:
            return [ICRemoteChapterCredentialStore hasKimiAPIKey];
        default:
            return YES;
    }
}

- (void)_showCredentialSetupForModel:(ICDownloadableModel *)model {
    switch (model.chapterProvider) {
        case ICChapterModelProviderOpenAIAPI:
            [self _showAPIKeyEditorWithTitle:@"OpenAI API-Key"
                                      message:NSLocalizedString(@"Der Key wird im iOS-Keychain gespeichert und nur für OpenAI Kapitelmodelle verwendet.", nil)
                                  placeholder:@"sk-..."
                          keyCreationURLString:@"https://platform.openai.com/api-keys"
                                 isConfigured:[ICRemoteChapterCredentialStore hasOpenAIAPIKey]
                                  saveHandler:^(NSString *value) {
                [ICRemoteChapterCredentialStore setOpenAIAPIKey:value];
            } deleteHandler:^{
                [ICRemoteChapterCredentialStore setOpenAIAPIKey:nil];
            }];
            break;
        case ICChapterModelProviderOpenAICodexOAuth:
            [self _showAPIKeyEditorWithTitle:@"OpenAI API-Key"
                                      message:NSLocalizedString(@"Der Key wird im iOS-Keychain gespeichert und für OpenAI Kapitelmodelle verwendet. Alternativ kann in den Cloud-Zugängen der Codex Login eingerichtet werden.", nil)
                                  placeholder:@"sk-..."
                          keyCreationURLString:@"https://platform.openai.com/api-keys"
                                 isConfigured:[ICRemoteChapterCredentialStore hasOpenAIAPIKey]
                                  saveHandler:^(NSString *value) {
                [ICRemoteChapterCredentialStore setOpenAIAPIKey:value];
            } deleteHandler:^{
                [ICRemoteChapterCredentialStore setOpenAIAPIKey:nil];
            }];
            break;
        case ICChapterModelProviderAnthropicAPI:
            [self _showAPIKeyEditorWithTitle:@"Anthropic API-Key"
                                      message:NSLocalizedString(@"Der Key wird im iOS-Keychain gespeichert und nur für Anthropic Kapitelmodelle verwendet.", nil)
                                  placeholder:@"sk-ant-..."
                          keyCreationURLString:@"https://console.anthropic.com/settings/keys"
                                 isConfigured:[ICRemoteChapterCredentialStore hasAnthropicAPIKey]
                                  saveHandler:^(NSString *value) {
                [ICRemoteChapterCredentialStore setAnthropicAPIKey:value];
            } deleteHandler:^{
                [ICRemoteChapterCredentialStore setAnthropicAPIKey:nil];
            }];
            break;
        case ICChapterModelProviderKimiAPI:
            [self _showAPIKeyEditorWithTitle:@"Kimi API-Key"
                                      message:NSLocalizedString(@"Eigener Key wird im iOS-Keychain gespeichert und überschreibt den integrierten Kimi-Zugang.", nil)
                                  placeholder:@"sk-..."
                          keyCreationURLString:@"https://platform.kimi.ai/console/api-keys"
                                 isConfigured:[ICRemoteChapterCredentialStore hasKimiUserAPIKey]
                                  saveHandler:^(NSString *value) {
                [ICRemoteChapterCredentialStore setKimiAPIKey:value];
            } deleteHandler:^{
                [ICRemoteChapterCredentialStore setKimiAPIKey:nil];
            }];
            break;
        default:
            break;
    }
}

- (void)_showAPIKeyEditorWithTitle:(NSString *)title
                           message:(NSString *)message
                       placeholder:(NSString *)placeholder
               keyCreationURLString:(NSString *)keyCreationURLString
                      isConfigured:(BOOL)isConfigured
                       saveHandler:(void (^)(NSString *value))saveHandler
                     deleteHandler:(void (^)(void))deleteHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = placeholder;
        textField.secureTextEntry = YES;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        UIButton *pasteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [pasteButton setTitle:NSLocalizedString(@"Einfügen", nil) forState:UIControlStateNormal];
        pasteButton.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
        [pasteButton addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            NSString *clipboardValue = UIPasteboard.generalPasteboard.string;
            if (clipboardValue.length > 0) {
                textField.text = clipboardValue;
            }
        }] forControlEvents:UIControlEventTouchUpInside];
        textField.rightView = pasteButton;
        textField.rightViewMode = UITextFieldViewModeAlways;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Speichern", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *value = alert.textFields.firstObject.text ?: @"";
        saveHandler(value);
        [self.tableView reloadData];
    }]];
    if (isConfigured) {
        [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Entfernen", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            deleteHandler();
            [self.tableView reloadData];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Key erstellen", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _openURLString:keyCreationURLString];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_openURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)_showOpenAIOAuthLogin {
    if ([ICRemoteChapterCredentialStore hasOpenAIOAuthCredentials]) {
        UIAlertController *existing = [UIAlertController alertControllerWithTitle:@"OpenAI Codex Login"
                                                                          message:[ICRemoteChapterCredentialStore openAIOAuthAccountLabel]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [existing addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Neu anmelden", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self _requestOpenAIDeviceCode];
        }]];
        [existing addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abmelden", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [ICRemoteChapterCredentialStore clearOpenAIOAuthCredentials];
            [self.tableView reloadData];
        }]];
        [existing addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:existing animated:YES completion:nil];
        return;
    }
    [self _requestOpenAIDeviceCode];
}

- (void)_requestOpenAIDeviceCode {
    self.navigationItem.prompt = NSLocalizedString(@"Codex Gerätecode wird geladen…", nil);
    [ICRemoteChapterCredentialStore requestOpenAIDeviceCodeWithCompletion:^(ICOpenAIDeviceCodeInfo *info, NSError *error) {
        self.navigationItem.prompt = nil;
        if (error) {
            [self _showError:error.localizedDescription];
            return;
        }
        if (!info) return;
        [self _showOpenAIDeviceCode:info];
    }];
}

- (void)_showOpenAIDeviceCode:(ICOpenAIDeviceCodeInfo *)info {
    NSString *message = [NSString stringWithFormat:@"%@\n\n%@\n\n%@",
                         info.verificationURL,
                         info.userCode,
                         NSLocalizedString(@"Nach dem Login wartet die App bis zu 15 Minuten auf die Freigabe.", nil)];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Codex Login", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Code kopieren", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = info.userCode;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self _showOpenAIDeviceCode:info];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Browser öffnen", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:info.verificationURL];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
        [self _completeOpenAIDeviceLogin:info];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Ich habe den Code eingegeben", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self _completeOpenAIDeviceLogin:info];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Abbrechen", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_completeOpenAIDeviceLogin:(ICOpenAIDeviceCodeInfo *)info {
    self.navigationItem.prompt = NSLocalizedString(@"Warte auf Codex Login…", nil);
    [ICRemoteChapterCredentialStore completeOpenAIDeviceLoginWithDeviceCode:info completion:^(NSError *error) {
        self.navigationItem.prompt = nil;
        if (error) {
            [self _showError:error.localizedDescription];
        }
        [self.tableView reloadData];
    }];
}

- (void)_showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Fehler", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
