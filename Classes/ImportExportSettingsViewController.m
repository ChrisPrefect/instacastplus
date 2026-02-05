//
//  ImportExportSettingsViewController.m
//  Instacast
//

#import "ImportExportSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "SubscriptionManager.h"
#import "XPFF.h"
#import "VDModalInfo.h"
#import "CDPlaylist.h"
#import "InstacastAppDelegate.h"

typedef NS_ENUM(NSInteger, ImportExportSections) {
    kExportSection = 0,
    kImportSection,
    kNumberOfSections,
};

@interface ImportExportSettingsViewController () <UIDocumentInteractionControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@property (nonatomic, strong) VDModalInfo* mInfo;
@end

@implementation ImportExportSettingsViewController

+ (ImportExportSettingsViewController*) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Import / Export".ls;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self updateAppearance];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    [self.tableView reloadData];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kExportSection:
            return 3;
        case kImportSection:
            return 2;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return 80;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

    cell.textLabel.textColor = ICTextColor;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;

    UIView* selectedView = [[UIView alloc] init];
    selectedView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    cell.selectedBackgroundView = selectedView;

    switch (indexPath.section) {
        case kExportSection:
            if (indexPath.row == 0) {
                cell.textLabel.text = @"All InstacastPlus Data".ls;
                cell.detailTextLabel.text = @"For exchanging data between InstacastPlus apps. Contains all data including subscriptions, bookmarks, playback status and settings.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Subscriptions (OPML)".ls;
                cell.detailTextLabel.text = @"The OPML file can be read by other podcast apps but only contains the subscriptions without any additional data.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            } else {
                cell.textLabel.text = @"Bookmarks".ls;
                cell.detailTextLabel.text = @"Export all bookmarks as a file.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"bookmark"];
            }
            break;
        case kImportSection:
            if (indexPath.row == 0) {
                cell.textLabel.text = @"All InstacastPlus Data".ls;
                cell.detailTextLabel.text = @"Import all data from an InstacastPlus backup file.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
            } else {
                cell.textLabel.text = @"Subscriptions (OPML)".ls;
                cell.detailTextLabel.text = @"Import subscriptions from an OPML file.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            }
            break;
    }

    return cell;
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kExportSection:
            return @"Export".ls;
        case kImportSection:
            return @"Import".ls;
    }
    return nil;
}

- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kImportSection) {
        return @"You can also open .opml or .xml files from Mail or the Files app in InstacastPlus to import data.".ls;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *footerView = (UITableViewHeaderFooterView *)view;
        footerView.textLabel.textColor = [UIColor grayColor];
    }
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case kExportSection:
            if (indexPath.row == 0) {
                [self exportEverything];
            } else if (indexPath.row == 1) {
                [self exportSubscriptions];
            } else {
                [self exportBookmarks];
            }
            break;
        case kImportSection:
            [self showImportDocumentPicker];
            break;
    }
}

#pragma mark - Export

- (void) exportSubscriptions
{
    NSData* data = [[SubscriptionManager sharedSubscriptionManager] opmlData];

    NSString* fileName = [NSString stringWithFormat:@"%@-%@.opml", @"Subscriptions".ls, [UIDevice currentDevice].name];
    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];

    [data writeToURL:url atomically:YES];

    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
    self.interactionController.delegate = self;
    self.interactionController.name = fileName;
    self.interactionController.UTI = @"instacast.opml";
    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
        self.interactionController = nil;
    }
}

- (void) exportBookmarks
{
    NSData* data = XPFFDataWithBookmarks(DMANAGER.bookmarks);

    NSString* fileName = [NSString stringWithFormat:@"%@-%@.xpff", @"Bookmarks".ls, [UIDevice currentDevice].name];
    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];

    [data writeToURL:url atomically:YES];

    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
    self.interactionController.delegate = self;
    self.interactionController.name = fileName;
    self.interactionController.UTI = @"com.vemedio.xpff";
    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
        self.interactionController = nil;
    }
}

- (NSString*) xmlEscape:(NSString*)string
{
    if (!string) return @"";
    string = [string stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    string = [string stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    string = [string stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    string = [string stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    return string;
}

- (void) exportEverything
{
    NSMutableString* xml = [NSMutableString string];
    NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];

    // XML Header
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendFormat:@"<instacast version=\"1\" date=\"%@\">\n", [dateFormatter stringFromDate:[NSDate date]]];

    // Podcasts
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
    NSArray* feeds = [DMANAGER.objectContext executeFetchRequest:fetchRequest error:nil];

    [xml appendString:@"  <podcasts>\n"];
    for (CDFeed* feed in feeds) {
        [xml appendFormat:@"    <podcast url=\"%@\" rank=\"%d\">\n",
            [self xmlEscape:[feed.sourceURL absoluteString]], feed.rank];

        // Custom properties
        if ([feed hasCustomProperties]) {
            [xml appendString:@"      <settings>\n"];
            for (NSString* key in [feed propertyKeys]) {
                NSString* stringVal = [feed stringForKey:key];
                if (stringVal) {
                    [xml appendFormat:@"        <%@>%@</%@>\n", key, [self xmlEscape:stringVal], key];
                } else {
                    NSInteger intVal = [feed integerForKey:key];
                    if (intVal != 0) {
                        [xml appendFormat:@"        <%@>%ld</%@>\n", key, (long)intVal, key];
                    }
                }
            }
            [xml appendString:@"      </settings>\n"];
        }

        // Episodes with state
        BOOL hasEpisodes = NO;
        for (CDEpisode* episode in feed.episodes) {
            if (episode.consumed || episode.starred || episode.archived || episode.position > 0 || episode.downloaded) {
                if (!hasEpisodes) {
                    [xml appendString:@"      <episodes>\n"];
                    hasEpisodes = YES;
                }
                CDMedium* medium = [episode preferedMedium];
                [xml appendFormat:@"        <episode media=\"%@\" guid=\"%@\">\n",
                    [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                    [self xmlEscape:episode.guid ?: @""]];
                if (episode.consumed) [xml appendString:@"          <played>true</played>\n"];
                if (episode.starred) [xml appendString:@"          <starred>true</starred>\n"];
                if (episode.archived) [xml appendString:@"          <archived>true</archived>\n"];
                if (episode.downloaded) [xml appendString:@"          <downloaded>true</downloaded>\n"];
                if (episode.position > 0) [xml appendFormat:@"          <position>%d</position>\n", episode.position];
                if (episode.duration > 0) [xml appendFormat:@"          <duration>%d</duration>\n", episode.duration];
                [xml appendString:@"        </episode>\n"];
            }
        }
        if (hasEpisodes) [xml appendString:@"      </episodes>\n"];
        [xml appendString:@"    </podcast>\n"];
    }
    [xml appendString:@"  </podcasts>\n"];

    // Bookmarks
    NSArray* bookmarks = DMANAGER.bookmarks;
    if (bookmarks.count > 0) {
        [xml appendString:@"  <bookmarks>\n"];
        for (CDBookmark* bookmark in bookmarks) {
            [xml appendFormat:@"    <bookmark position=\"%.0f\" title=\"%@\" episodeGuid=\"%@\" feedUrl=\"%@\"/>\n",
                bookmark.position,
                [self xmlEscape:bookmark.title ?: @""],
                [self xmlEscape:bookmark.episodeGuid ?: @""],
                [self xmlEscape:[bookmark.feedURL absoluteString] ?: @""]];
        }
        [xml appendString:@"  </bookmarks>\n"];
    }

    // Up Next
    AudioSession* session = [AudioSession sharedAudioSession];
    NSArray* upNextPlaylist = session.playlist;
    if (upNextPlaylist.count > 0) {
        [xml appendString:@"  <upnext>\n"];
        for (CDEpisode* episode in upNextPlaylist) {
            CDMedium* medium = [episode preferedMedium];
            [xml appendFormat:@"    <episode media=\"%@\" guid=\"%@\" feedUrl=\"%@\"/>\n",
                [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                [self xmlEscape:episode.guid ?: @""],
                [self xmlEscape:[episode.feed.sourceURL absoluteString] ?: @""]];
        }
        [xml appendString:@"  </upnext>\n"];
    }

    // Now Playing
    CDEpisode* currentEpisode = session.episode;
    if (currentEpisode) {
        CDMedium* medium = [currentEpisode preferedMedium];
        [xml appendFormat:@"  <nowplaying media=\"%@\" guid=\"%@\" feedUrl=\"%@\" position=\"%d\"/>\n",
            [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
            [self xmlEscape:currentEpisode.guid ?: @""],
            [self xmlEscape:[currentEpisode.feed.sourceURL absoluteString] ?: @""],
            currentEpisode.position];
    }

    // Playlists
    NSArray* lists = DMANAGER.lists;
    BOOL hasPlaylists = NO;
    for (CDList* list in lists) {
        if ([list isKindOfClass:[CDPlaylist class]]) {
            if (!hasPlaylists) {
                [xml appendString:@"  <playlists>\n"];
                hasPlaylists = YES;
            }
            CDPlaylist* playlist = (CDPlaylist*)list;
            [xml appendFormat:@"    <playlist name=\"%@\" rank=\"%d\">\n",
                [self xmlEscape:playlist.name], playlist.rank];
            for (CDEpisode* episode in playlist.sortedEpisodes) {
                CDMedium* medium = [episode preferedMedium];
                [xml appendFormat:@"      <episode media=\"%@\" guid=\"%@\" feedUrl=\"%@\"/>\n",
                    [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                    [self xmlEscape:episode.guid ?: @""],
                    [self xmlEscape:[episode.feed.sourceURL absoluteString] ?: @""]];
            }
            [xml appendString:@"    </playlist>\n"];
        }
    }
    if (hasPlaylists) [xml appendString:@"  </playlists>\n"];

    // Settings
    NSUserDefaults* defaults = USER_DEFAULTS;
    [xml appendString:@"  <settings>\n"];
    if ([defaults objectForKey:DefaultPlaybackSpeed]) [xml appendFormat:@"    <playbackSpeed>%ld</playbackSpeed>\n", (long)[defaults integerForKey:DefaultPlaybackSpeed]];
    if ([defaults objectForKey:PlayerSkipBackPeriod]) [xml appendFormat:@"    <skipBack>%ld</skipBack>\n", (long)[defaults integerForKey:PlayerSkipBackPeriod]];
    if ([defaults objectForKey:PlayerSkipForwardPeriod]) [xml appendFormat:@"    <skipForward>%ld</skipForward>\n", (long)[defaults integerForKey:PlayerSkipForwardPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipStartPeriod]) [xml appendFormat:@"    <autoSkipStart>%ld</autoSkipStart>\n", (long)[defaults integerForKey:PlayerAutoSkipStartPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipEndPeriod]) [xml appendFormat:@"    <autoSkipEnd>%ld</autoSkipEnd>\n", (long)[defaults integerForKey:PlayerAutoSkipEndPeriod]];
    if ([defaults objectForKey:PlayerReplayAfterPause]) [xml appendFormat:@"    <replayAfterPause>%ld</replayAfterPause>\n", (long)[defaults integerForKey:PlayerReplayAfterPause]];
    if ([defaults objectForKey:AutoCacheNewAudioEpisodes]) [xml appendFormat:@"    <autoCacheAudio>%@</autoCacheAudio>\n", [defaults boolForKey:AutoCacheNewAudioEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoCacheNewVideoEpisodes]) [xml appendFormat:@"    <autoCacheVideo>%@</autoCacheVideo>\n", [defaults boolForKey:AutoCacheNewVideoEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteAfterFinishedPlaying]) [xml appendFormat:@"    <autoDeletePlayed>%@</autoDeletePlayed>\n", [defaults boolForKey:AutoDeleteAfterFinishedPlaying] ? @"true" : @"false"];
    if ([defaults objectForKey:DisableAutoLock]) [xml appendFormat:@"    <disableAutoLock>%@</disableAutoLock>\n", [defaults boolForKey:DisableAutoLock] ? @"true" : @"false"];
    if ([defaults objectForKey:kDefaultAppearanceMode]) [xml appendFormat:@"    <appearanceMode>%ld</appearanceMode>\n", (long)[defaults integerForKey:kDefaultAppearanceMode]];
    if ([defaults objectForKey:ScreenTimerAlwaysActive]) [xml appendFormat:@"    <sleepTimerAlways>%@</sleepTimerAlways>\n", [defaults boolForKey:ScreenTimerAlwaysActive] ? @"true" : @"false"];
    if ([defaults objectForKey:LastSelectedSleepTimer]) [xml appendFormat:@"    <lastSleepTimer>%ld</lastSleepTimer>\n", (long)[defaults integerForKey:LastSelectedSleepTimer]];
    if ([defaults objectForKey:FeedListSortMode]) [xml appendFormat:@"    <feedListSortMode>%@</feedListSortMode>\n", [self xmlEscape:[defaults stringForKey:FeedListSortMode]]];
    if ([defaults objectForKey:@"ManualFeedOrder"]) {
        NSArray* manualOrder = [defaults objectForKey:@"ManualFeedOrder"];
        [xml appendString:@"    <manualFeedOrder>\n"];
        for (NSString* url in manualOrder) {
            [xml appendFormat:@"      <feedUrl>%@</feedUrl>\n", [self xmlEscape:url]];
        }
        [xml appendString:@"    </manualFeedOrder>\n"];
    }
    [xml appendString:@"  </settings>\n"];

    [xml appendString:@"</instacast>\n"];

    // Write file
    NSData* data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSString* fileName = [NSString stringWithFormat:@"Instacast-Backup-%@.xml", [UIDevice currentDevice].name];
    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];

    [data writeToURL:url atomically:YES];

    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
    self.interactionController.delegate = self;
    self.interactionController.name = fileName;
    self.interactionController.UTI = @"public.xml";
    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
        self.interactionController = nil;
    }
}

#pragma mark - Import

- (void) showImportDocumentPicker
{
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.xml"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;

    NSString* extension = [url.pathExtension lowercaseString];
    if ([extension isEqualToString:@"opml"] || [extension isEqualToString:@"xml"]) {
        [self importOPMLFromURL:url];
    }
}

- (void) importOPMLFromURL:(NSURL*)url
{
    self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Importing\u2026".ls];
    [self.mInfo show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL needsSecurity = [url startAccessingSecurityScopedResource];

        NSData *opmlData = [NSData dataWithContentsOfURL:url];

        if (needsSecurity) {
            [url stopAccessingSecurityScopedResource];
        }

        if (!opmlData || opmlData.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.mInfo close];
                self.mInfo = nil;
            });
            return;
        }

        [[SubscriptionManager sharedSubscriptionManager] importOPMLData:opmlData completion:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.mInfo close];
                self.mInfo = nil;
            });
        } progress:^(float progress) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress > 0.03) {
                    [self.mInfo setProgress:progress];
                }
            });
        }];
    });
}

#pragma mark - UIDocumentInteractionControllerDelegate

- (void) documentInteractionControllerDidDismissOpenInMenu:(UIDocumentInteractionController *)controller
{
    self.interactionController = nil;
}

@end
