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
#import "CDEpisodeList.h"
#import "InstacastAppDelegate.h"
#import "InstacastBackupParser.h"
#import "InstacastBackupImportViewController.h"
#import "CacheManager.h"
#import "AppleWatchSyncManager.h"
#import "AppleWatchEpisodeState.h"
#import "InstacastPlus-Swift.h"
#import <math.h>
typedef NS_ENUM(NSInteger, ImportExportSections) {
    kExportSection = 0,
    kImportSection,
    kResetAppSection,
    kNumberOfSections,
};

@interface ImportExportSettingsViewController () <UIDocumentInteractionControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@property (nonatomic, strong) VDModalInfo* mInfo;
@property (nonatomic) NSInteger selectedImportRow;
@property (nonatomic) BOOL importInProgress;
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
    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Import / Export".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    self.importInProgress = NO;
    [self updateAppearance];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView reloadData];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

- (void) dealloc
{
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
        case kResetAppSection:
            return 1;
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
    cell.detailTextLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
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
        case kResetAppSection:
            cell.textLabel.text = @"Reset App".ls;
            cell.textLabel.textColor = [UIColor redColor];
            cell.detailTextLabel.text = @"Delete all data and reset the app to factory settings.".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            cell.imageView.tintColor = [UIColor redColor];
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
        footerView.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString* text = [self tableView:tableView titleForFooterInSection:section];
    return [self heightForFooterText:text];
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
            self.selectedImportRow = indexPath.row;
            [self showImportDocumentPicker];
            break;
        case kResetAppSection:
            [self resetApp];
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

- (NSString *)_hexColorForDefaults:(NSUserDefaults *)defaults hexKey:(NSString *)hexKey colorDataKey:(NSString *)colorDataKey
{
    NSString *storedHex = [defaults stringForKey:hexKey];
    if (storedHex.length > 0) return storedHex;

    id colorObject = [defaults objectForKey:colorDataKey];
    if (![colorObject isKindOfClass:[NSData class]]) return nil;

    UIColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:(NSData *)colorObject error:nil];
    if (!color) return nil;

    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) return nil;

    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)round(r * 255), (int)round(g * 255), (int)round(b * 255)];
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
        NSMutableString *podcastAttrs = [NSMutableString stringWithFormat:@"url=\"%@\" rank=\"%d\" title=\"%@\"",
            [self xmlEscape:[feed.sourceURL absoluteString]], feed.rank, [self xmlEscape:feed.title ?: @""]];
        if (feed.parked) {
            [podcastAttrs appendString:@" parked=\"true\""];
        }
        if (feed.username.length > 0) {
            [podcastAttrs appendFormat:@" username=\"%@\"", [self xmlEscape:feed.username]];
        }
        if (feed.password.length > 0) {
            [podcastAttrs appendFormat:@" password=\"%@\"", [self xmlEscape:feed.password]];
        }
        [xml appendFormat:@"    <podcast %@>\n", podcastAttrs];

        // Custom properties (skip internal keys)
        NSArray* propertyKeys = [feed propertyKeys];
        BOOL hasTranscriptPrefs = [propertyKeys containsObject:@"preferredTranscriptLanguage"] || [propertyKeys containsObject:@"preferredTranscriptURL"];
        if ([feed hasCustomProperties] || hasTranscriptPrefs) {
            NSSet* internalKeys = [NSSet setWithObjects:@"episodeLoadingComplete", @"loadedEpisodeCount", @"totalExpectedEpisodes", nil];
            [xml appendString:@"      <settings>\n"];
            for (NSString* key in propertyKeys) {
                if ([internalKeys containsObject:key]) continue;
                NSString* escapedKey = [self xmlEscape:key];

                // Check all CDFeedProperty value types (each stored in separate field)
                NSString* stringVal = [feed stringForKey:key];
                if (stringVal.length > 0) {
                    [xml appendFormat:@"        <setting key=\"%@\" value=\"%@\"/>\n", escapedKey, [self xmlEscape:stringVal]];
                    continue;
                }
                double dblVal = [feed doubleForKey:key];
                if (dblVal != 0.0) {
                    [xml appendFormat:@"        <setting key=\"%@\" value=\"%@\"/>\n", escapedKey, [NSString stringWithFormat:@"%.1f", dblVal]];
                    continue;
                }
                NSInteger intVal = [feed integerForKey:key];
                if (intVal != 0) {
                    [xml appendFormat:@"        <setting key=\"%@\" value=\"%ld\"/>\n", escapedKey, (long)intVal];
                    continue;
                }
                // Bool: CDFeedProperty exists (in propertyKeys), export even if false
                [xml appendFormat:@"        <setting key=\"%@\" value=\"%@\"/>\n", escapedKey,
                    [feed boolForKey:key] ? @"true" : @"false"];
            }
            [xml appendString:@"      </settings>\n"];
        }

        // Episodes with state
        BOOL hasEpisodes = NO;
        NSInteger downloadedCount = 0;
        CacheManager *cacheManager = [CacheManager sharedCacheManager];
        for (CDEpisode* episode in feed.episodes) {
            BOOL isCached = [cacheManager episodeIsCached:episode];
            if (isCached) downloadedCount++;
            if (episode.consumed || episode.starred || episode.archived || episode.position > 0 || isCached) {
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
                if (isCached) [xml appendString:@"          <downloaded>true</downloaded>\n"];
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

    // Apple Watch episode selection
    AppleWatchSyncManager *watchManager = [AppleWatchSyncManager sharedManager];
    NSArray<AppleWatchEpisodeState *> *watchStates = [watchManager visibleEpisodeStates];
    BOOL hasAppleWatchEpisodes = NO;
    for (AppleWatchEpisodeState *state in watchStates) {
        CDEpisode *episode = [DMANAGER episodeWithObjectHash:state.episodeHash];
        if (![watchManager canSendEpisodeToWatch:episode]) continue;

        if (!hasAppleWatchEpisodes) {
            [xml appendString:@"  <appleWatchEpisodes>\n"];
            hasAppleWatchEpisodes = YES;
        }

        NSString *feedURL = [episode.feed.sourceURL absoluteString] ?: @"";
        NSString *feedIdentifier = state.feedIdentifier ?: feedURL ?: episode.feed.uid ?: @"";
        NSMutableString *attrs = [NSMutableString stringWithFormat:@"episodeHash=\"%@\" guid=\"%@\" feedUrl=\"%@\" feedIdentifier=\"%@\" selectionSource=\"%@\"",
            [self xmlEscape:state.episodeHash ?: episode.objectHash ?: @""],
            [self xmlEscape:episode.guid ?: @""],
            [self xmlEscape:feedURL],
            [self xmlEscape:feedIdentifier],
            [self xmlEscape:state.selectionSource ?: @"manual"]];

        if (state.watchAddedDate) [attrs appendFormat:@" watchAddedDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.watchAddedDate]]];
        if (state.lastPhonePosition > 0) [attrs appendFormat:@" lastPhonePosition=\"%d\"", state.lastPhonePosition];
        if (state.lastPhonePositionDate) [attrs appendFormat:@" lastPhonePositionDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.lastPhonePositionDate]]];
        if (state.lastWatchPosition > 0) [attrs appendFormat:@" lastWatchPosition=\"%d\"", state.lastWatchPosition];
        if (state.lastWatchPositionDate) [attrs appendFormat:@" lastWatchPositionDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.lastWatchPositionDate]]];
        if (state.watchConsumed) [attrs appendString:@" watchConsumed=\"true\""];
        if (state.watchConsumedDate) [attrs appendFormat:@" watchConsumedDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.watchConsumedDate]]];

        [xml appendFormat:@"    <episode %@/>\n", attrs];
    }
    if (hasAppleWatchEpisodes) [xml appendString:@"  </appleWatchEpisodes>\n"];

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

    // Episode Lists (default filter lists like Unplayed, Favorites, etc.)
    BOOL hasEpisodeLists = NO;
    for (CDList* list in lists) {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            CDEpisodeList* episodeList = (CDEpisodeList*)list;
            if (!episodeList.uid) continue;
            if (!hasEpisodeLists) {
                [xml appendString:@"  <episodeLists>\n"];
                hasEpisodeLists = YES;
            }
            [xml appendFormat:@"    <episodeList uid=\"%@\" name=\"%@\" icon=\"%@\" rank=\"%d\">\n",
                [self xmlEscape:episodeList.uid],
                [self xmlEscape:episodeList.name ?: @""],
                [self xmlEscape:episodeList.icon ?: @""],
                episodeList.rank];
            [xml appendFormat:@"      <audio>%@</audio>\n", episodeList.audio ? @"true" : @"false"];
            [xml appendFormat:@"      <video>%@</video>\n", episodeList.video ? @"true" : @"false"];
            [xml appendFormat:@"      <downloaded>%@</downloaded>\n", episodeList.downloaded ? @"true" : @"false"];
            [xml appendFormat:@"      <downloading>%@</downloading>\n", episodeList.downloading ? @"true" : @"false"];
            [xml appendFormat:@"      <notDownloaded>%@</notDownloaded>\n", episodeList.notDownloaded ? @"true" : @"false"];
            [xml appendFormat:@"      <unplayed>%@</unplayed>\n", episodeList.unplayed ? @"true" : @"false"];
            [xml appendFormat:@"      <unfinished>%@</unfinished>\n", episodeList.unfinished ? @"true" : @"false"];
            [xml appendFormat:@"      <played>%@</played>\n", episodeList.played ? @"true" : @"false"];
            [xml appendFormat:@"      <starred>%@</starred>\n", episodeList.starred ? @"true" : @"false"];
            [xml appendFormat:@"      <notStarred>%@</notStarred>\n", episodeList.notStarred ? @"true" : @"false"];
            if (episodeList.orderBy) [xml appendFormat:@"      <orderBy>%@</orderBy>\n", [self xmlEscape:episodeList.orderBy]];
            [xml appendFormat:@"      <descending>%@</descending>\n", episodeList.descending ? @"true" : @"false"];
            [xml appendFormat:@"      <groupByPodcast>%@</groupByPodcast>\n", episodeList.groupByPodcast ? @"true" : @"false"];
            [xml appendFormat:@"      <continuousPlayback>%@</continuousPlayback>\n", episodeList.continuousPlayback ? @"true" : @"false"];
            if (episodeList.includedFeeds.count > 0) {
                [xml appendString:@"      <includedFeeds>\n"];
                for (CDFeed* feed in episodeList.includedFeeds) {
                    [xml appendFormat:@"        <feedUrl>%@</feedUrl>\n", [self xmlEscape:[feed.sourceURL absoluteString] ?: @""]];
                }
                [xml appendString:@"      </includedFeeds>\n"];
            }
            [xml appendString:@"    </episodeList>\n"];
        }
    }
    if (hasEpisodeLists) [xml appendString:@"  </episodeLists>\n"];

    // Settings
    NSUserDefaults* defaults = USER_DEFAULTS;
    [xml appendString:@"  <settings>\n"];
    // Playback
    if ([defaults objectForKey:DefaultPlaybackSpeed]) [xml appendFormat:@"    <playbackSpeed>%ld</playbackSpeed>\n", (long)[defaults integerForKey:DefaultPlaybackSpeed]];
    if ([defaults objectForKey:PlayerSkipBackPeriod]) [xml appendFormat:@"    <skipBack>%ld</skipBack>\n", (long)[defaults integerForKey:PlayerSkipBackPeriod]];
    if ([defaults objectForKey:PlayerSkipForwardPeriod]) [xml appendFormat:@"    <skipForward>%ld</skipForward>\n", (long)[defaults integerForKey:PlayerSkipForwardPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipStartPeriod]) [xml appendFormat:@"    <autoSkipStart>%ld</autoSkipStart>\n", (long)[defaults integerForKey:PlayerAutoSkipStartPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipEndPeriod]) [xml appendFormat:@"    <autoSkipEnd>%ld</autoSkipEnd>\n", (long)[defaults integerForKey:PlayerAutoSkipEndPeriod]];
    if ([defaults objectForKey:PlayerReplayAfterPause]) [xml appendFormat:@"    <replayAfterPause>%ld</replayAfterPause>\n", (long)[defaults integerForKey:PlayerReplayAfterPause]];
    if ([defaults objectForKey:kDefaultPlayerControls]) [xml appendFormat:@"    <playerControls>%ld</playerControls>\n", (long)[defaults integerForKey:kDefaultPlayerControls]];
    if ([defaults objectForKey:kDefaultDontDeleteUpNextWhenChangingEpisode]) [xml appendFormat:@"    <dontDeleteUpNext>%@</dontDeleteUpNext>\n", [defaults boolForKey:kDefaultDontDeleteUpNextWhenChangingEpisode] ? @"true" : @"false"];
    if ([defaults objectForKey:ContinuousPlayFromFeed]) [xml appendFormat:@"    <continuousPlay>%@</continuousPlay>\n", [defaults boolForKey:ContinuousPlayFromFeed] ? @"true" : @"false"];
    if ([defaults objectForKey:DefaultIntelligentSleepTimer]) [xml appendFormat:@"    <defaultSleepTimer>%ld</defaultSleepTimer>\n", (long)[defaults integerForKey:DefaultIntelligentSleepTimer]];
    // Downloads
    if ([defaults objectForKey:AutoCacheNewAudioEpisodes]) [xml appendFormat:@"    <autoCacheAudio>%@</autoCacheAudio>\n", [defaults boolForKey:AutoCacheNewAudioEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoCacheNewVideoEpisodes]) [xml appendFormat:@"    <autoCacheVideo>%@</autoCacheVideo>\n", [defaults boolForKey:AutoCacheNewVideoEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteAfterFinishedPlaying]) [xml appendFormat:@"    <autoDeletePlayed>%@</autoDeletePlayed>\n", [defaults boolForKey:AutoDeleteAfterFinishedPlaying] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteAfterMarkedAsPlayed]) [xml appendFormat:@"    <autoDeleteMarkedPlayed>%@</autoDeleteMarkedPlayed>\n", [defaults boolForKey:AutoDeleteAfterMarkedAsPlayed] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteNewsMode]) [xml appendFormat:@"    <autoDeleteNews>%@</autoDeleteNews>\n", [defaults boolForKey:AutoDeleteNewsMode] ? @"true" : @"false"];
    if ([defaults objectForKey:PodcastRefreshOnAppStart]) [xml appendFormat:@"    <podcastRefreshOnAppStart>%@</podcastRefreshOnAppStart>\n", [defaults boolForKey:PodcastRefreshOnAppStart] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoCacheStorageLimit]) [xml appendFormat:@"    <autoCacheStorageLimit>%ld</autoCacheStorageLimit>\n", (long)[defaults integerForKey:AutoCacheStorageLimit]];
    if ([defaults objectForKey:AutoDownloadWhileStreaming]) [xml appendFormat:@"    <autoDownloadWhileStreaming>%@</autoDownloadWhileStreaming>\n", [defaults boolForKey:AutoDownloadWhileStreaming] ? @"true" : @"false"];
    // Cellular
    if ([defaults objectForKey:EnableCachingOver3G]) [xml appendFormat:@"    <enableCachingOver3G>%@</enableCachingOver3G>\n", [defaults boolForKey:EnableCachingOver3G] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableRefreshingOver3G]) [xml appendFormat:@"    <enableRefreshingOver3G>%@</enableRefreshingOver3G>\n", [defaults boolForKey:EnableRefreshingOver3G] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableStreamingOver3G]) [xml appendFormat:@"    <enableStreamingOver3G>%@</enableStreamingOver3G>\n", [defaults boolForKey:EnableStreamingOver3G] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableCachingImagesOver3G]) [xml appendFormat:@"    <enableCachingImagesOver3G>%@</enableCachingImagesOver3G>\n", [defaults boolForKey:EnableCachingImagesOver3G] ? @"true" : @"false"];
    // General
    if ([defaults objectForKey:DisableAutoLock]) [xml appendFormat:@"    <disableAutoLock>%@</disableAutoLock>\n", [defaults boolForKey:DisableAutoLock] ? @"true" : @"false"];
    if ([defaults objectForKey:UISoundEnabled]) [xml appendFormat:@"    <uiSoundEnabled>%@</uiSoundEnabled>\n", [defaults boolForKey:UISoundEnabled] ? @"true" : @"false"];
    if ([defaults objectForKey:ShowApplicationBadgeForUnseen]) [xml appendFormat:@"    <showBadge>%@</showBadge>\n", [defaults boolForKey:ShowApplicationBadgeForUnseen] ? @"true" : @"false"];
    if ([defaults objectForKey:kDefaultShowUnavailableEpisodes]) [xml appendFormat:@"    <showUnavailable>%@</showUnavailable>\n", [defaults boolForKey:kDefaultShowUnavailableEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:OpenLinksInExternalBrowser]) [xml appendFormat:@"    <openLinksExternal>%@</openLinksExternal>\n", [defaults boolForKey:OpenLinksInExternalBrowser] ? @"true" : @"false"];
    if ([defaults objectForKey:AllowSendingDiagnostics]) [xml appendFormat:@"    <allowDiagnostics>%ld</allowDiagnostics>\n", (long)[defaults integerForKey:AllowSendingDiagnostics]];
    if ([defaults objectForKey:AmazonAffiliateEnabled]) [xml appendFormat:@"    <amazonAffiliateEnabled>%@</amazonAffiliateEnabled>\n", [defaults boolForKey:AmazonAffiliateEnabled] ? @"true" : @"false"];
    // Notifications
    if ([defaults objectForKey:EnableNewEpisodeNotification]) [xml appendFormat:@"    <notifyNewEpisode>%@</notifyNewEpisode>\n", [defaults boolForKey:EnableNewEpisodeNotification] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableManualRefreshFinishedNotification]) [xml appendFormat:@"    <notifyRefreshFinished>%@</notifyRefreshFinished>\n", [defaults boolForKey:EnableManualRefreshFinishedNotification] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableManualDownloadFinishedNotification]) [xml appendFormat:@"    <notifyDownloadFinished>%@</notifyDownloadFinished>\n", [defaults boolForKey:EnableManualDownloadFinishedNotification] ? @"true" : @"false"];
    // Appearance
    if ([defaults objectForKey:kDefaultAppearanceMode]) [xml appendFormat:@"    <appearanceMode>%ld</appearanceMode>\n", (long)[defaults integerForKey:kDefaultAppearanceMode]];
    if ([defaults objectForKey:InterfaceThemeDefaultActive]) [xml appendFormat:@"    <themeDefaultActive>%@</themeDefaultActive>\n", [defaults boolForKey:InterfaceThemeDefaultActive] ? @"true" : @"false"];
    NSString *interfaceColorHex = [self _hexColorForDefaults:defaults hexKey:InterfaceThemeColorHexCode colorDataKey:InterfaceThemeColorCode];
    if (interfaceColorHex.length > 0) [xml appendFormat:@"    <themeColorHex>%@</themeColorHex>\n", [self xmlEscape:interfaceColorHex]];
    if ([defaults objectForKey:PlayerColorPerPodcastActive]) [xml appendFormat:@"    <playerPerPodcastColor>%@</playerPerPodcastColor>\n", [defaults boolForKey:PlayerColorPerPodcastActive] ? @"true" : @"false"];
    NSString *playerColorHex = [self _hexColorForDefaults:defaults hexKey:PlayerThemeColorHexCode colorDataKey:PlayerThemeColorCode];
    if (playerColorHex.length > 0) [xml appendFormat:@"    <playerColorHex>%@</playerColorHex>\n", [self xmlEscape:playerColorHex]];
    if ([defaults objectForKey:WidgetThemeDefaultActive]) [xml appendFormat:@"    <widgetThemeDefaultActive>%@</widgetThemeDefaultActive>\n", [defaults boolForKey:WidgetThemeDefaultActive] ? @"true" : @"false"];
    NSString *widgetColorHex = [self _hexColorForDefaults:defaults hexKey:WidgetThemeColorHexCode colorDataKey:WidgetThemeColorCode];
    if (widgetColorHex.length > 0) [xml appendFormat:@"    <widgetColorHex>%@</widgetColorHex>\n", [self xmlEscape:widgetColorHex]];
    if ([defaults objectForKey:kDefaultTranscriptHighlightStyle]) [xml appendFormat:@"    <transcriptHighlightStyle>%ld</transcriptHighlightStyle>\n", (long)[defaults integerForKey:kDefaultTranscriptHighlightStyle]];
    // Sleep Timer
    if ([defaults objectForKey:ScreenTimerAlwaysActive]) [xml appendFormat:@"    <sleepTimerAlways>%@</sleepTimerAlways>\n", [defaults boolForKey:ScreenTimerAlwaysActive] ? @"true" : @"false"];
    if ([defaults objectForKey:IntelligentSleepTimerAlwaysActive]) [xml appendFormat:@"    <intelligentSleepAlways>%@</intelligentSleepAlways>\n", [defaults boolForKey:IntelligentSleepTimerAlwaysActive] ? @"true" : @"false"];
    if ([defaults objectForKey:DisableSleepTimerInCarPlay]) [xml appendFormat:@"    <disableSleepTimerCarPlay>%@</disableSleepTimerCarPlay>\n", [defaults boolForKey:DisableSleepTimerInCarPlay] ? @"true" : @"false"];
    if ([defaults objectForKey:LastSelectedSleepTimer]) [xml appendFormat:@"    <lastSleepTimer>%ld</lastSleepTimer>\n", (long)[defaults integerForKey:LastSelectedSleepTimer]];
    // Sleep Timer Motion/Touch/Volume Detection
    if ([defaults objectForKey:DeviceMovementIntelligentSleep]) [xml appendFormat:@"    <deviceMovementIntelligentSleep>%@</deviceMovementIntelligentSleep>\n", [defaults boolForKey:DeviceMovementIntelligentSleep] ? @"true" : @"false"];
    if ([defaults objectForKey:DeviceMovementSensitivity]) [xml appendFormat:@"    <deviceMovementSensitivity>%.3f</deviceMovementSensitivity>\n", [defaults doubleForKey:DeviceMovementSensitivity]];
    if ([defaults objectForKey:ScreenTouchIntelligentSleep]) [xml appendFormat:@"    <screenTouchIntelligentSleep>%@</screenTouchIntelligentSleep>\n", [defaults boolForKey:ScreenTouchIntelligentSleep] ? @"true" : @"false"];
    if ([defaults objectForKey:VolumeChangeIntelligentSleep]) [xml appendFormat:@"    <volumeChangeIntelligentSleep>%@</volumeChangeIntelligentSleep>\n", [defaults boolForKey:VolumeChangeIntelligentSleep] ? @"true" : @"false"];
    // App Icon
    NSString *alternateIconName = [[UIApplication sharedApplication] alternateIconName];
    if (alternateIconName) {
        [xml appendFormat:@"    <appIcon>%@</appIcon>\n", [self xmlEscape:alternateIconName]];
    }
    // SmartHome
    if ([defaults objectForKey:SmarthomeMQTTEnabled]) [xml appendFormat:@"    <smarthomeMQTTEnabled>%@</smarthomeMQTTEnabled>\n", [defaults boolForKey:SmarthomeMQTTEnabled] ? @"true" : @"false"];
    if ([defaults objectForKey:SmarthomeMQTTHost]) [xml appendFormat:@"    <smarthomeMQTTHost>%@</smarthomeMQTTHost>\n", [self xmlEscape:[defaults stringForKey:SmarthomeMQTTHost]]];
    if ([defaults objectForKey:SmarthomeMQTTPort]) [xml appendFormat:@"    <smarthomeMQTTPort>%ld</smarthomeMQTTPort>\n", (long)[defaults integerForKey:SmarthomeMQTTPort]];
    if ([defaults objectForKey:SmarthomeMQTTUsername]) [xml appendFormat:@"    <smarthomeMQTTUsername>%@</smarthomeMQTTUsername>\n", [self xmlEscape:[defaults stringForKey:SmarthomeMQTTUsername]]];
    if ([defaults objectForKey:SmarthomeMQTTPassword]) [xml appendFormat:@"    <smarthomeMQTTPassword>%@</smarthomeMQTTPassword>\n", [self xmlEscape:[defaults stringForKey:SmarthomeMQTTPassword]]];
    if ([defaults objectForKey:SmarthomeAllowControl]) [xml appendFormat:@"    <smarthomeAllowControl>%@</smarthomeAllowControl>\n", [defaults boolForKey:SmarthomeAllowControl] ? @"true" : @"false"];
    if ([defaults objectForKey:SmarthomeWiFiOnly]) [xml appendFormat:@"    <smarthomeWiFiOnly>%@</smarthomeWiFiOnly>\n", [defaults boolForKey:SmarthomeWiFiOnly] ? @"true" : @"false"];
    if ([defaults objectForKey:SmarthomeDeviceName]) [xml appendFormat:@"    <smarthomeDeviceName>%@</smarthomeDeviceName>\n", [self xmlEscape:[defaults stringForKey:SmarthomeDeviceName]]];
    // MainMenuListUIDs
    NSArray* mainMenuUIDs = [defaults objectForKey:@"MainMenuListUIDs"];
    if (mainMenuUIDs.count > 0) {
        [xml appendString:@"    <mainMenuListUIDs>\n"];
        for (NSString* uid in mainMenuUIDs) {
            [xml appendFormat:@"      <uid>%@</uid>\n", [self xmlEscape:uid]];
        }
        [xml appendString:@"    </mainMenuListUIDs>\n"];
    }
    // Sort order
    if ([defaults objectForKey:FeedListSortMode]) [xml appendFormat:@"    <feedListSortMode>%@</feedListSortMode>\n", [self xmlEscape:[defaults stringForKey:FeedListSortMode]]];
    if ([defaults objectForKey:FeedSortOrder]) [xml appendFormat:@"    <feedSortOrder>%@</feedSortOrder>\n", [self xmlEscape:[defaults stringForKey:FeedSortOrder]]];
    if ([defaults objectForKey:SelectedAppLanguage]) [xml appendFormat:@"    <selectedAppLanguage>%@</selectedAppLanguage>\n", [self xmlEscape:[defaults stringForKey:SelectedAppLanguage]]];
    // Swipe Actions
    if ([defaults objectForKey:EpisodeSwipeRightAction]) [xml appendFormat:@"    <episodeSwipeRightAction>%ld</episodeSwipeRightAction>\n", (long)[defaults integerForKey:EpisodeSwipeRightAction]];
    if ([defaults objectForKey:EpisodeSwipeLeftAction]) [xml appendFormat:@"    <episodeSwipeLeftAction>%ld</episodeSwipeLeftAction>\n", (long)[defaults integerForKey:EpisodeSwipeLeftAction]];
    if ([defaults objectForKey:AppleWatchSendLatestCount]) [xml appendFormat:@"    <appleWatchSendLatestCount>%ld</appleWatchSendLatestCount>\n", (long)[defaults integerForKey:AppleWatchSendLatestCount]];
    if ([defaults objectForKey:AppleWatchOnlyUnplayed]) [xml appendFormat:@"    <appleWatchOnlyUnplayed>%@</appleWatchOnlyUnplayed>\n", [defaults boolForKey:AppleWatchOnlyUnplayed] ? @"true" : @"false"];
    // Display
    if ([defaults objectForKey:kDefaultDarkModePureBlack]) [xml appendFormat:@"    <darkModePureBlack>%@</darkModePureBlack>\n", [defaults boolForKey:kDefaultDarkModePureBlack] ? @"true" : @"false"];
    if ([defaults objectForKey:kDefaultFontSizeLarger]) [xml appendFormat:@"    <fontSizeLarger>%ld</fontSizeLarger>\n", (long)[defaults integerForKey:kDefaultFontSizeLarger]];
    if ([defaults objectForKey:TapOnEpisodeAction]) [xml appendFormat:@"    <tapOnEpisodeAction>%ld</tapOnEpisodeAction>\n", (long)[defaults integerForKey:TapOnEpisodeAction]];
    if ([defaults objectForKey:@"MediaFilesSortMode"]) [xml appendFormat:@"    <mediaFilesSortMode>%ld</mediaFilesSortMode>\n", (long)[defaults integerForKey:@"MediaFilesSortMode"]];
    // Transcription & Chapters
    if ([defaults objectForKey:kTranscriptionEngine]) [xml appendFormat:@"    <transcriptionEngine>%@</transcriptionEngine>\n", [self xmlEscape:[defaults stringForKey:kTranscriptionEngine]]];
    if ([defaults objectForKey:kTranscriptionWhisperModel]) [xml appendFormat:@"    <transcriptionWhisperModel>%@</transcriptionWhisperModel>\n", [self xmlEscape:[defaults stringForKey:kTranscriptionWhisperModel]]];
    if ([defaults objectForKey:@"ChapterGenerationModel"]) [xml appendFormat:@"    <chapterGenerationModel>%@</chapterGenerationModel>\n", [self xmlEscape:[defaults stringForKey:@"ChapterGenerationModel"]]];
    if ([defaults objectForKey:kTranscriptionAutoDefault]) [xml appendFormat:@"    <transcriptionAutoDefault>%@</transcriptionAutoDefault>\n", [defaults boolForKey:kTranscriptionAutoDefault] ? @"true" : @"false"];
    if ([defaults objectForKey:kChapterAutoDefault]) [xml appendFormat:@"    <chapterAutoDefault>%@</chapterAutoDefault>\n", [defaults boolForKey:kChapterAutoDefault] ? @"true" : @"false"];
    if ([defaults objectForKey:kAutoSkipSponsors]) [xml appendFormat:@"    <autoSkipSponsors>%@</autoSkipSponsors>\n", [defaults boolForKey:kAutoSkipSponsors] ? @"true" : @"false"];
    if ([defaults objectForKey:kTranscriptionEverActivated]) [xml appendFormat:@"    <transcriptionEverActivated>%@</transcriptionEverActivated>\n", [defaults boolForKey:kTranscriptionEverActivated] ? @"true" : @"false"];
    if ([defaults objectForKey:kTranscriptionFirstRunShown]) [xml appendFormat:@"    <transcriptionFirstRunShown>%@</transcriptionFirstRunShown>\n", [defaults boolForKey:kTranscriptionFirstRunShown] ? @"true" : @"false"];
    if ([defaults objectForKey:@"TranscriptVisiblePreference"]) [xml appendFormat:@"    <transcriptVisiblePreference>%@</transcriptVisiblePreference>\n", [defaults boolForKey:@"TranscriptVisiblePreference"] ? @"true" : @"false"];
    NSDictionary *credentialValues = [ICRemoteChapterCredentialStore backupCredentialValues];
    NSArray *credentialKeys = @[@"openAIAPIKey", @"anthropicAPIKey", @"kimiAPIKey", @"openAIOAuthAccessToken", @"openAIOAuthRefreshToken", @"openAIOAuthIDToken", @"openAIOAuthAccountID", @"openAIOAuthAccountEmail", @"openAIOAuthFedRAMP"];
    for (NSString *key in credentialKeys) {
        NSString *value = credentialValues[key];
        if ([value isKindOfClass:[NSString class]] && value.length > 0) {
            [xml appendFormat:@"    <%@>%@</%@>\n", key, [self xmlEscape:value], key];
        }
    }
    // Enabled Playback Speeds
    if ([defaults objectForKey:EnabledPlaybackSpeedsKey]) {
        NSArray* speeds = [defaults objectForKey:EnabledPlaybackSpeedsKey];
        [xml appendString:@"    <enabledPlaybackSpeeds>\n"];
        for (NSNumber* speed in speeds) {
            [xml appendFormat:@"      <speed>%ld</speed>\n", (long)[speed integerValue]];
        }
        [xml appendString:@"    </enabledPlaybackSpeeds>\n"];
    }
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
    NSArray *documentTypes;
    if (self.selectedImportRow == 0) {
        documentTypes = @[@"public.xml"];
    } else {
        documentTypes = @[@"public.xml", @"org.opml.opml", @"instacast.opml"];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:documentTypes inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
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

    [self importFileFromURL:url];
}

- (void)importFileFromURL:(NSURL *)url
{
    if (self.importInProgress) return;
    self.importInProgress = YES;

    self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Analyzing backup…".ls];
    [self.mInfo show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL needsSecurity = [url startAccessingSecurityScopedResource];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (needsSecurity) {
            [url stopAccessingSecurityScopedResource];
        }

        if (!data || data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.mInfo close];
                self.mInfo = nil;
                self.importInProgress = NO;
            });
            return;
        }

        // Detect format: Instacast backup XML vs OPML
        if ([InstacastBackupParser isInstacastBackupData:data]) {
            [self importInstacastBackupFromData:data];
        } else {
            [self importOPMLFromData:data];
        }
    });
}

- (void)importInstacastBackupFromData:(NSData *)data
{
    [InstacastBackupParser parseData:data completion:^(InstacastBackupData *backupData, NSError *error) {
        [self.mInfo close];
        self.mInfo = nil;

        if (error || !backupData) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Error".ls
                                                                          message:error.localizedDescription ?: @"Could not parse backup file.".ls
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
            self.importInProgress = NO;
            return;
        }

        InstacastBackupImportViewController *importVC = [InstacastBackupImportViewController viewControllerWithBackupData:backupData];
        [self.navigationController pushViewController:importVC animated:YES];
        self.importInProgress = NO;
    }];
}

- (void)importOPMLFromData:(NSData *)data
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.mInfo close];
        self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Importing\u2026".ls];
        [self.mInfo show];

        [[SubscriptionManager sharedSubscriptionManager] importOPMLData:data completion:^{
            [self.mInfo close];
            self.mInfo = nil;
            self.importInProgress = NO;
        } progress:^(float progress) {
            if (progress > 0.03) {
                [self.mInfo setProgress:progress];
            }
        }];
    });
}

#pragma mark - UIDocumentInteractionControllerDelegate

- (void) documentInteractionControllerDidDismissOpenInMenu:(UIDocumentInteractionController *)controller
{
    self.interactionController = nil;
}


#pragma mark - Reset App

- (void) resetApp
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Reset App".ls
                                                                   message:@"Are you sure you want to delete all data and reset the app? This action cannot be undone.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Reset".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
        [self performAppReset];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void) performAppReset
{
    self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Resetting…".ls];
    [self.mInfo show];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Clear all UserDefaults
        NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:appDomain];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // Clear all downloaded files
        [[CacheManager sharedCacheManager] clearTheFuckingCache];

        dispatch_async(dispatch_get_main_queue(), ^{
            // Unsubscribe all feeds (Core Data must be on main thread)
            NSArray* allFeeds = [DMANAGER.feeds copy];
            for (CDFeed* feed in allFeeds) {
                [DMANAGER unsubscribeFeed:feed];
            }
            [DMANAGER save];

            [self.mInfo close];
            self.mInfo = nil;

            // Reset app icon if needed, then show confirmation
            if ([UIApplication sharedApplication].alternateIconName != nil) {
                [[UIApplication sharedApplication] setAlternateIconName:nil completionHandler:^(NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self _showResetCompleteAlert];
                    });
                }];
            } else {
                [self _showResetCompleteAlert];
            }
        });
    });
}

- (void)_showResetCompleteAlert
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Reset Complete".ls
                                                                   message:@"Please restart the app.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
        exit(0);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
