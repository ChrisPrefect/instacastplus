//
//  InstacastBackupImportViewController.m
//  Instacast
//

#import "InstacastBackupImportViewController.h"
#import "InstacastBackupData.h"
#import "InstacastBackupImporter.h"
#import "ICBackupImportProgressView.h"
#import "UITableViewController+Settings.h"
#import "CDFeed.h"
#import "CDEpisode.h"
#import "CDBookmark.h"
#import "DatabaseManager.h"

typedef NS_ENUM(NSInteger, ICBackupImportSection) {
    kBackupInfoSection = 0,
    kCategoriesSection,
    kImportButtonSection,
    kNumberOfImportSections,
};

typedef NS_ENUM(NSInteger, ICBackupImportRow) {
    kRowNewPodcasts = 0,
    kRowEpisodeStatus,
    kRowFeedSettings,
    kRowBookmarks,
    kRowUpNext,
    kRowNowPlaying,
    kRowAppleWatchEpisodes,
    kRowPlaylists,
    kRowAppSettings,
    kRowSortOrder,
    kRowDownloads,
    kNumberOfCategoryRows,
};

static NSString * const ICBackupPreviewErrorDomain = @"com.vemedio.instacast.backup-preview";

@interface ICBackupAnalysisResult : NSObject
@property (nonatomic) NSInteger newPodcastCount;
@property (nonatomic) NSInteger totalEpisodeCount;
@property (nonatomic) NSInteger updatedEpisodeCount;
@property (nonatomic) NSInteger feedsWithSettingsCount;
@property (nonatomic) NSInteger totalBookmarkCount;
@property (nonatomic) NSInteger newBookmarkCount;
@property (nonatomic) NSInteger upNextCount;
@property (nonatomic) NSInteger appleWatchEpisodeCount;
@property (nonatomic) NSInteger playlistCount;
@property (nonatomic) NSInteger episodeListCount;
@property (nonatomic, strong) NSString *nowPlayingTitle;
@property (nonatomic, strong) NSString *sortModeDescription;
@property (nonatomic) NSInteger downloadedEpisodeCount;
@end

@implementation ICBackupAnalysisResult
@end

static NSString *ICBackupPreviewNormalizedURL(NSString *URLString) {
    return [DatabaseManager normalizedFeedURLStringForURLString:URLString];
}

static void ICBackupIndexExistingFeedURL(NSMutableDictionary<NSString *, NSString *> *lookup, NSString *rawURL) {
    NSArray<NSString *> *equivalentURLs = [DatabaseManager equivalentFeedURLStringsForURLString:rawURL];
    NSString *normalizedURL = equivalentURLs.firstObject;
    if (!normalizedURL) return;
    lookup[normalizedURL] = normalizedURL;
    for (NSUInteger index = 1; index < equivalentURLs.count; index++) {
        NSString *alternateURL = equivalentURLs[index];
        if (!lookup[alternateURL]) lookup[alternateURL] = normalizedURL;
    }
}

static NSString *ICBackupResolvedPreviewFeedURL(NSDictionary<NSString *, NSString *> *lookup, NSString *rawURL) {
    NSString *normalizedURL = ICBackupPreviewNormalizedURL(rawURL);
    return normalizedURL ? lookup[normalizedURL] : nil;
}

static NSString *ICBackupPreviewStringValue(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSNumber *ICBackupPreviewNumberValue(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static NSString *ICBackupEpisodeLookupKey(NSString *feedURL, NSString *guid) {
    if (feedURL.length == 0 || guid.length == 0) return nil;
    return [NSString stringWithFormat:@"%lu:%@%@", (unsigned long)feedURL.length, feedURL, guid];
}

static void ICBackupIndexBookmark(NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *> *bookmarkPositionsByEpisode,
                                  NSString *feedURL,
                                  NSString *guid,
                                  double position) {
    NSString *episodeKey = ICBackupEpisodeLookupKey(feedURL, guid);
    if (!episodeKey) return;
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *positionBuckets = bookmarkPositionsByEpisode[episodeKey];
    if (!positionBuckets) {
        positionBuckets = [NSMutableDictionary dictionary];
        bookmarkPositionsByEpisode[episodeKey] = positionBuckets;
    }
    NSNumber *bucket = @((NSInteger)floor(position));
    NSMutableArray<NSNumber *> *positions = positionBuckets[bucket];
    if (!positions) {
        positions = [NSMutableArray array];
        positionBuckets[bucket] = positions;
    }
    [positions addObject:@(position)];
}

static BOOL ICBackupBookmarkExists(NSDictionary<NSString *, NSDictionary<NSNumber *, NSArray<NSNumber *> *> *> *bookmarkPositionsByEpisode,
                                   NSString *feedURL,
                                   NSString *guid,
                                   double position) {
    NSString *episodeKey = ICBackupEpisodeLookupKey(feedURL, guid);
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *positionBuckets = episodeKey ? bookmarkPositionsByEpisode[episodeKey] : nil;
    if (!positionBuckets) return NO;
    NSInteger centerBucket = (NSInteger)floor(position);
    for (NSInteger bucket = centerBucket - 1; bucket <= centerBucket + 1; bucket++) {
        for (NSNumber *existingPosition in positionBuckets[@(bucket)]) {
            if (fabs(existingPosition.doubleValue - position) <= 1.0) return YES;
        }
    }
    return NO;
}

@interface InstacastBackupImportViewController ()
@property (nonatomic, strong) NSMutableSet<NSNumber *> *selectedCategories;
@property (nonatomic) BOOL analysisInProgress;
@property (nonatomic, strong) NSError *analysisError;
@property (nonatomic) NSUInteger analysisGeneration;

// Analysis results
@property (nonatomic) NSInteger newPodcastCount;
@property (nonatomic) NSInteger totalEpisodeCount;
@property (nonatomic) NSInteger updatedEpisodeCount;
@property (nonatomic) NSInteger feedsWithSettingsCount;
@property (nonatomic) NSInteger totalBookmarkCount;
@property (nonatomic) NSInteger newBookmarkCount;
@property (nonatomic) NSInteger upNextCount;
@property (nonatomic) NSInteger appleWatchEpisodeCount;
@property (nonatomic) NSInteger playlistCount;
@property (nonatomic) NSInteger episodeListCount;
@property (nonatomic, strong) NSString *nowPlayingTitle;
@property (nonatomic, strong) NSString *sortModeDescription;
@property (nonatomic) NSInteger downloadedEpisodeCount;
@end

@implementation InstacastBackupImportViewController

+ (instancetype)viewControllerWithBackupData:(InstacastBackupData *)backupData {
    InstacastBackupImportViewController *vc = [[self alloc] initWithStyle:UITableViewStyleGrouped];
    vc.backupData = backupData;
    return vc;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupSettingsTableViewSpacing];

    self.navigationItem.title = @"Import Backup".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];

    self.selectedCategories = [NSMutableSet set];
    [self analyzeBackup];
    [self updateAppearance];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

#pragma mark - Analysis

+ (ICBackupAnalysisResult *)analysisResultForBackup:(InstacastBackupData *)backup
                                            context:(NSManagedObjectContext *)context
                                              error:(NSError **)error {
    ICBackupAnalysisResult *result = [[ICBackupAnalysisResult alloc] init];

    NSFetchRequest<NSDictionary *> *feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
    feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND sourceURL_ != nil"];
    feedRequest.resultType = NSDictionaryResultType;
    feedRequest.propertiesToFetch = @[@"sourceURL_"];
    NSError *fetchError = nil;
    NSArray<NSDictionary *> *feedRows = [context executeFetchRequest:feedRequest error:&fetchError];
    if (!feedRows) {
        if (error) *error = fetchError;
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *existingFeedURLByLookupKey = [NSMutableDictionary dictionaryWithCapacity:feedRows.count * 2];
    for (NSDictionary *row in feedRows) {
        ICBackupIndexExistingFeedURL(existingFeedURLByLookupKey, ICBackupPreviewStringValue(row[@"sourceURL_"]));
    }

    NSMutableSet<NSString *> *backupEpisodeGUIDs = [NSMutableSet set];
    for (ICBackupPodcast *podcast in backup.podcasts) {
        if (!ICBackupResolvedPreviewFeedURL(existingFeedURLByLookupKey, podcast.feedURL)) continue;
        for (ICBackupEpisode *episode in podcast.episodes) {
            if (episode.guid.length > 0) [backupEpisodeGUIDs addObject:episode.guid];
        }
    }
    if (backup.nowPlaying.guid.length > 0) [backupEpisodeGUIDs addObject:backup.nowPlaying.guid];

    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSDictionary *> *> *episodeStatesByFeedURL = [NSMutableDictionary dictionary];
    NSArray<NSString *> *allGUIDs = backupEpisodeGUIDs.allObjects;
    const NSUInteger episodeFetchBatchSize = 400;
    for (NSUInteger offset = 0; offset < allGUIDs.count; offset += episodeFetchBatchSize) {
        NSArray<NSString *> *GUIDBatch = [allGUIDs subarrayWithRange:NSMakeRange(offset, MIN(episodeFetchBatchSize, allGUIDs.count - offset))];
        NSFetchRequest<CDEpisode *> *episodeRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        episodeRequest.predicate = [NSPredicate predicateWithFormat:@"guid IN %@ AND feed.subscribed == YES", GUIDBatch];
        episodeRequest.relationshipKeyPathsForPrefetching = @[@"feed"];
        episodeRequest.includesSubentities = NO;
        episodeRequest.fetchBatchSize = episodeFetchBatchSize;
        NSArray<CDEpisode *> *episodes = [context executeFetchRequest:episodeRequest error:&fetchError];
        if (!episodes) {
            if (error) *error = fetchError;
            return nil;
        }
        for (CDEpisode *episode in episodes) {
            NSString *rawFeedURL = [episode.feed valueForKey:@"sourceURL_"];
            NSString *resolvedFeedURL = ICBackupResolvedPreviewFeedURL(existingFeedURLByLookupKey, rawFeedURL) ?: ICBackupPreviewNormalizedURL(rawFeedURL);
            if (resolvedFeedURL.length == 0 || episode.guid.length == 0) continue;
            NSMutableDictionary<NSString *, NSDictionary *> *statesByGUID = episodeStatesByFeedURL[resolvedFeedURL];
            if (!statesByGUID) {
                statesByGUID = [NSMutableDictionary dictionary];
                episodeStatesByFeedURL[resolvedFeedURL] = statesByGUID;
            }
            NSDictionary *existingState = statesByGUID[episode.guid];
            if (existingState) {
                NSString *existingTitle = ICBackupPreviewStringValue(existingState[@"title"]);
                statesByGUID[episode.guid] = @{
                    @"consumed": @([existingState[@"consumed"] boolValue] && episode.consumed),
                    @"starred": @([existingState[@"starred"] boolValue] && episode.starred),
                    @"archived": @([existingState[@"archived"] boolValue] && episode.archived),
                    @"position": @(MIN([existingState[@"position"] integerValue], episode.position)),
                    @"duration": @(MIN([existingState[@"duration"] integerValue], episode.duration)),
                    @"title": existingTitle.length > 0 ? existingTitle : (episode.title ?: @""),
                };
            } else {
                statesByGUID[episode.guid] = @{
                    @"consumed": @(episode.consumed),
                    @"starred": @(episode.starred),
                    @"archived": @(episode.archived),
                    @"position": @(episode.position),
                    @"duration": @(episode.duration),
                    @"title": episode.title ?: @"",
                };
            }
        }
        [context reset];
    }

    NSFetchRequest<NSDictionary *> *bookmarkRequest = [[NSFetchRequest alloc] initWithEntityName:@"Bookmark"];
    bookmarkRequest.resultType = NSDictionaryResultType;
    bookmarkRequest.propertiesToFetch = @[@"episodeGuid", @"feedURL_", @"position"];
    NSArray<NSDictionary *> *bookmarkRows = [context executeFetchRequest:bookmarkRequest error:&fetchError];
    if (!bookmarkRows) {
        if (error) *error = fetchError;
        return nil;
    }
    NSMutableDictionary<NSString *, NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *> *bookmarkPositionsByEpisode = [NSMutableDictionary dictionaryWithCapacity:bookmarkRows.count];
    for (NSDictionary *row in bookmarkRows) {
        NSString *rawFeedURL = ICBackupPreviewStringValue(row[@"feedURL_"]);
        NSString *feedURL = ICBackupResolvedPreviewFeedURL(existingFeedURLByLookupKey, rawFeedURL) ?: ICBackupPreviewNormalizedURL(rawFeedURL);
        NSNumber *position = ICBackupPreviewNumberValue(row[@"position"]);
        ICBackupIndexBookmark(bookmarkPositionsByEpisode,
                              feedURL,
                              ICBackupPreviewStringValue(row[@"episodeGuid"]),
                              position ? position.doubleValue : 0);
    }

    NSSet *internalKeys = [NSSet setWithObjects:@"episodeLoadingComplete", @"loadedEpisodeCount", @"totalExpectedEpisodes", nil];
    NSMutableSet<NSString *> *downloadEpisodeKeys = [NSMutableSet set];
    for (ICBackupPodcast *podcast in backup.podcasts) {
        NSString *normalizedBackupFeedURL = ICBackupPreviewNormalizedURL(podcast.feedURL);
        NSString *resolvedFeedURL = normalizedBackupFeedURL ? existingFeedURLByLookupKey[normalizedBackupFeedURL] : nil;
        if (normalizedBackupFeedURL && !resolvedFeedURL) result.newPodcastCount++;

        result.totalEpisodeCount += podcast.episodes.count;
        BOOL feedHasCustomSettings = NO;
        for (NSString *key in podcast.settings) {
            if (![internalKeys containsObject:key]) {
                feedHasCustomSettings = YES;
                break;
            }
        }
        if (feedHasCustomSettings) result.feedsWithSettingsCount++;

        for (ICBackupEpisode *backupEpisode in podcast.episodes) {
            if (podcast.feedURL && backupEpisode.downloaded && backupEpisode.guid.length > 0) {
                NSString *downloadFeedURL = resolvedFeedURL ?: normalizedBackupFeedURL ?: podcast.feedURL;
                NSString *downloadKey = ICBackupEpisodeLookupKey(downloadFeedURL, backupEpisode.guid);
                if (downloadKey && ![downloadEpisodeKeys containsObject:downloadKey]) {
                    [downloadEpisodeKeys addObject:downloadKey];
                    result.downloadedEpisodeCount++;
                }
            }
            if (!resolvedFeedURL) {
                if (backupEpisode.played || backupEpisode.starred || backupEpisode.archived ||
                    backupEpisode.position > 0 || backupEpisode.duration > 0) {
                    result.updatedEpisodeCount++;
                }
                continue;
            }
            NSDictionary *localState = episodeStatesByFeedURL[resolvedFeedURL][backupEpisode.guid];
            if (!localState) continue;
            BOOL wouldChange =
                (backupEpisode.played && ![localState[@"consumed"] boolValue]) ||
                (backupEpisode.starred && ![localState[@"starred"] boolValue]) ||
                (backupEpisode.archived && ![localState[@"archived"] boolValue]) ||
                (backupEpisode.position > [localState[@"position"] integerValue]) ||
                (backupEpisode.duration > 0 && [localState[@"duration"] integerValue] == 0);
            if (wouldChange) result.updatedEpisodeCount++;
        }
    }

    result.totalBookmarkCount = backup.bookmarks.count;
    for (ICBackupBookmark *bookmark in backup.bookmarks) {
        NSString *normalizedFeedURL = ICBackupPreviewNormalizedURL(bookmark.feedURL);
        NSString *resolvedFeedURL = normalizedFeedURL ? existingFeedURLByLookupKey[normalizedFeedURL] : nil;
        NSString *feedURL = resolvedFeedURL ?: normalizedFeedURL;
        if (bookmark.episodeGuid.length == 0 || feedURL.length == 0) continue;
        if (!ICBackupBookmarkExists(bookmarkPositionsByEpisode, feedURL, bookmark.episodeGuid, bookmark.position)) {
            result.newBookmarkCount++;
        }
    }

    result.upNextCount = backup.upNextEpisodes.count;
    result.appleWatchEpisodeCount = backup.appleWatchEpisodes.count;
    result.playlistCount = backup.playlists.count;
    result.episodeListCount = backup.episodeLists.count;
    if (backup.nowPlaying.guid.length > 0) {
        NSString *resolvedFeedURL = ICBackupResolvedPreviewFeedURL(existingFeedURLByLookupKey, backup.nowPlaying.feedURL);
        NSString *title = episodeStatesByFeedURL[resolvedFeedURL][backup.nowPlaying.guid][@"title"];
        result.nowPlayingTitle = title.length > 0 ? title : @"1 Episode".ls;
    }
    if (backup.settings.manualFeedOrder.count > 0) {
        result.sortModeDescription = [NSString stringWithFormat:@"Manual order with %ld podcasts".ls,
                                      (long)backup.settings.manualFeedOrder.count];
    } else if (backup.settings.feedListSortMode.length > 0) {
        result.sortModeDescription = backup.settings.feedListSortMode;
    }
    return result;
}

- (void)analyzeBackup {
    self.analysisInProgress = YES;
    self.analysisError = nil;
    self.selectedCategories = [NSMutableSet set];
    NSUInteger generation = ++self.analysisGeneration;
    InstacastBackupData *backup = self.backupData;
    [self.tableView reloadData];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSManagedObjectContext *context = [DMANAGER newExportBackgroundContext];
        if (!context) {
            NSError *error = [NSError errorWithDomain:ICBackupPreviewErrorDomain
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Backup database is unavailable"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf applyAnalysisResult:nil error:error generation:generation];
            });
            return;
        }
        [context performBlock:^{
            NSError *error = nil;
            ICBackupAnalysisResult *result = [InstacastBackupImportViewController analysisResultForBackup:backup context:context error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf applyAnalysisResult:result error:error generation:generation];
            });
        }];
    });
}

- (void)applyAnalysisResult:(ICBackupAnalysisResult *)result
                      error:(NSError *)error
                 generation:(NSUInteger)generation {
    if (generation != self.analysisGeneration) return;
    self.analysisInProgress = NO;
    if (error || !result) {
        NSError *resolvedError = error ?: [NSError errorWithDomain:ICBackupPreviewErrorDomain
                                                               code:2
                                                           userInfo:@{NSLocalizedDescriptionKey: @"Backup preview returned no result"}];
        self.analysisError = resolvedError;
        ErrLog(@"Backup preview analysis failed: %@", resolvedError);
        self.selectedCategories = [NSMutableSet set];
        [self.tableView reloadData];
        return;
    }
    self.analysisError = nil;

    self.newPodcastCount = result.newPodcastCount;
    self.totalEpisodeCount = result.totalEpisodeCount;
    self.updatedEpisodeCount = result.updatedEpisodeCount;
    self.feedsWithSettingsCount = result.feedsWithSettingsCount;
    self.totalBookmarkCount = result.totalBookmarkCount;
    self.newBookmarkCount = result.newBookmarkCount;
    self.upNextCount = result.upNextCount;
    self.appleWatchEpisodeCount = result.appleWatchEpisodeCount;
    self.playlistCount = result.playlistCount;
    self.episodeListCount = result.episodeListCount;
    self.nowPlayingTitle = result.nowPlayingTitle;
    self.sortModeDescription = result.sortModeDescription;
    self.downloadedEpisodeCount = result.downloadedEpisodeCount;
    [self initializeSelectedCategories];
    [self.tableView reloadData];
}

- (void)initializeSelectedCategories {
    self.selectedCategories = [NSMutableSet set];

    // Select all categories that have data
    if (self.newPodcastCount > 0) [self.selectedCategories addObject:@(kRowNewPodcasts)];
    if (self.totalEpisodeCount > 0) [self.selectedCategories addObject:@(kRowEpisodeStatus)];
    if (self.feedsWithSettingsCount > 0) [self.selectedCategories addObject:@(kRowFeedSettings)];
    if (self.totalBookmarkCount > 0) [self.selectedCategories addObject:@(kRowBookmarks)];
    if (self.upNextCount > 0) [self.selectedCategories addObject:@(kRowUpNext)];
    if (self.nowPlayingTitle) [self.selectedCategories addObject:@(kRowNowPlaying)];
    if (self.appleWatchEpisodeCount > 0) [self.selectedCategories addObject:@(kRowAppleWatchEpisodes)];
    if (self.playlistCount + self.episodeListCount > 0) [self.selectedCategories addObject:@(kRowPlaylists)];
    if (self.backupData.settings.values.count > 0) [self.selectedCategories addObject:@(kRowAppSettings)];
    if (self.sortModeDescription) [self.selectedCategories addObject:@(kRowSortOrder)];
    if (self.downloadedEpisodeCount > 0) [self.selectedCategories addObject:@(kRowDownloads)];
}

- (BOOL)rowHasData:(NSInteger)row {
    if (self.analysisInProgress || self.analysisError) return NO;
    switch (row) {
        case kRowNewPodcasts:   return self.newPodcastCount > 0;
        case kRowEpisodeStatus: return self.totalEpisodeCount > 0;
        case kRowFeedSettings:  return self.feedsWithSettingsCount > 0;
        case kRowBookmarks:     return self.totalBookmarkCount > 0;
        case kRowUpNext:        return self.upNextCount > 0;
        case kRowNowPlaying:    return self.nowPlayingTitle != nil;
        case kRowAppleWatchEpisodes: return self.appleWatchEpisodeCount > 0;
        case kRowPlaylists:     return (self.playlistCount + self.episodeListCount) > 0;
        case kRowAppSettings:   return self.backupData.settings.values.count > 0;
        case kRowSortOrder:     return self.sortModeDescription != nil;
        case kRowDownloads:     return self.downloadedEpisodeCount > 0;
        default: return NO;
    }
}

- (ICBackupImportCategory)categoryForRow:(NSInteger)row {
    switch (row) {
        case kRowNewPodcasts:   return ICBackupImportNewPodcasts;
        case kRowEpisodeStatus: return ICBackupImportEpisodeStatus;
        case kRowFeedSettings:  return ICBackupImportFeedSettings;
        case kRowBookmarks:     return ICBackupImportBookmarks;
        case kRowUpNext:        return ICBackupImportUpNext;
        case kRowNowPlaying:    return ICBackupImportNowPlaying;
        case kRowAppleWatchEpisodes: return ICBackupImportAppleWatch;
        case kRowPlaylists:     return ICBackupImportPlaylists;
        case kRowAppSettings:   return ICBackupImportSettings;
        case kRowSortOrder:     return ICBackupImportSortOrder;
        case kRowDownloads:     return ICBackupImportDownloads;
        default: return 0;
    }
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return kNumberOfImportSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case kBackupInfoSection:    return 1;
        case kCategoriesSection:    return kNumberOfCategoryRows;
        case kImportButtonSection:  return 1;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 50;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewAutomaticDimension;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == kCategoriesSection) return @"Import Categories".ls;
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == kCategoriesSection) {
        return @"Select the data you want to import. Existing data will be merged.".ls;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.textColor = ICTextColor;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.backgroundColor = ICGroupCellBackgroundColor;

    UIView *selectedView = [[UIView alloc] init];
    selectedView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    cell.selectedBackgroundView = selectedView;

    switch (indexPath.section) {
        case kBackupInfoSection: {
            cell.textLabel.text = @"Backup Date".ls;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (self.backupData.date) {
                NSDateFormatter *df = [[NSDateFormatter alloc] init];
                df.dateStyle = NSDateFormatterMediumStyle;
                df.timeStyle = NSDateFormatterShortStyle;
                cell.detailTextLabel.text = [df stringFromDate:self.backupData.date];
            } else {
                cell.detailTextLabel.text = @"Unknown".ls;
            }
            break;
        }

        case kCategoriesSection: {
            [self configureCategoryCell:cell forRow:indexPath.row];
            break;
        }

        case kImportButtonSection: {
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            if (self.analysisInProgress) {
                cell.textLabel.text = @"Analyzing backup…".ls;
                cell.textLabel.textColor = [UIColor grayColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                [spinner startAnimating];
                cell.accessoryView = spinner;
            } else if (self.analysisError) {
                cell.textLabel.text = @"Try Again".ls;
                cell.textLabel.textColor = ICTintColor;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                cell.detailTextLabel.textAlignment = NSTextAlignmentCenter;
                cell.detailTextLabel.text = @"The backup could not be analyzed. No data was changed. Check the available storage and try again.".ls;
            } else {
                cell.textLabel.text = @"Import Selected Data".ls;
                cell.textLabel.textColor = ICTintColor;
                cell.detailTextLabel.text = nil;
            }
            break;
        }
    }

    return cell;
}

- (void)configureCategoryCell:(UITableViewCell *)cell forRow:(NSInteger)row {
    BOOL hasData = [self rowHasData:row];
    BOOL isSelected = [self.selectedCategories containsObject:@(row)];

    switch (row) {
        case kRowNewPodcasts:
            cell.textLabel.text = @"Subscribe New Podcasts".ls;
            cell.detailTextLabel.text = self.newPodcastCount > 0
                ? [NSString stringWithFormat:@"%ld new podcasts".ls, (long)self.newPodcastCount]
                : @"No new podcasts".ls;
            break;

        case kRowEpisodeStatus:
            cell.textLabel.text = @"Episode Status".ls;
            if (self.totalEpisodeCount > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld episodes (%ld will be updated)".ls,
                                             (long)self.totalEpisodeCount, (long)self.updatedEpisodeCount];
            } else {
                cell.detailTextLabel.text = @"No episodes".ls;
            }
            break;

        case kRowFeedSettings:
            cell.textLabel.text = @"Podcast Settings".ls;
            cell.detailTextLabel.text = self.feedsWithSettingsCount > 0
                ? [NSString stringWithFormat:@"%ld podcasts with custom settings".ls, (long)self.feedsWithSettingsCount]
                : @"No custom settings".ls;
            break;

        case kRowBookmarks:
            cell.textLabel.text = @"Bookmarks".ls;
            if (self.totalBookmarkCount > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld bookmarks (%ld new)".ls,
                                             (long)self.totalBookmarkCount, (long)self.newBookmarkCount];
            } else {
                cell.detailTextLabel.text = @"No bookmarks".ls;
            }
            break;

        case kRowUpNext:
            cell.textLabel.text = @"Up Next".ls;
            cell.detailTextLabel.text = self.upNextCount > 0
                ? [NSString stringWithFormat:@"%ld episodes".ls, (long)self.upNextCount]
                : @"No episodes".ls;
            break;

        case kRowNowPlaying:
            cell.textLabel.text = @"Now Playing".ls;
            cell.detailTextLabel.text = self.nowPlayingTitle ?: @"Nothing playing".ls;
            break;

        case kRowAppleWatchEpisodes:
            cell.textLabel.text = @"Apple Watch Episodes".ls;
            cell.detailTextLabel.text = self.appleWatchEpisodeCount > 0
                ? [NSString stringWithFormat:@"%ld Apple Watch episodes".ls, (long)self.appleWatchEpisodeCount]
                : @"No Apple Watch episodes".ls;
            break;

        case kRowPlaylists:
            cell.textLabel.text = @"Playlists".ls;
            if (self.playlistCount > 0 && self.episodeListCount > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld playlists, %ld episode lists".ls,
                                             (long)self.playlistCount, (long)self.episodeListCount];
            } else if (self.playlistCount > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld playlists".ls, (long)self.playlistCount];
            } else if (self.episodeListCount > 0) {
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld episode lists".ls, (long)self.episodeListCount];
            } else {
                cell.detailTextLabel.text = @"No playlists".ls;
            }
            break;

        case kRowAppSettings:
            cell.textLabel.text = @"App Settings".ls;
            cell.detailTextLabel.text = self.backupData.settings.values.count > 0
                ? @"Playback, appearance, etc.".ls
                : @"No settings".ls;
            break;

        case kRowSortOrder:
            cell.textLabel.text = @"Podcast Sort Order".ls;
            cell.detailTextLabel.text = self.sortModeDescription ?: @"No sort order".ls;
            break;

        case kRowDownloads:
            cell.textLabel.text = @"Re-download Episodes".ls;
            cell.detailTextLabel.text = self.downloadedEpisodeCount > 0
                ? [NSString stringWithFormat:@"%ld episodes".ls, (long)self.downloadedEpisodeCount]
                : @"No downloaded episodes".ls;
            break;
    }

    if (self.analysisInProgress) {
        cell.detailTextLabel.text = @"Analyzing backup…".ls;
    } else if (self.analysisError) {
        cell.detailTextLabel.text = nil;
    }

    if (!hasData) {
        cell.textLabel.textColor = [UIColor grayColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
}

#pragma mark - Selection

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == kCategoriesSection) {
        if (![self rowHasData:indexPath.row]) return;

        NSNumber *rowNum = @(indexPath.row);
        if ([self.selectedCategories containsObject:rowNum]) {
            [self.selectedCategories removeObject:rowNum];
        } else {
            [self.selectedCategories addObject:rowNum];
        }
        [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
    else if (indexPath.section == kImportButtonSection) {
        if (self.analysisError) {
            [self analyzeBackup];
        } else {
            [self confirmImport];
        }
    }
}

#pragma mark - Import

- (void)confirmImport {
    if (self.analysisInProgress || self.analysisError) return;
    if (self.selectedCategories.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"No Data Selected".ls
                                                                      message:@"Please select at least one category to import.".ls
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSMutableArray *summaryItems = [NSMutableArray array];
    if ([self.selectedCategories containsObject:@(kRowNewPodcasts)])
        [summaryItems addObject:[NSString stringWithFormat:@"%ld new podcasts".ls, (long)self.newPodcastCount]];
    if ([self.selectedCategories containsObject:@(kRowEpisodeStatus)])
        [summaryItems addObject:[NSString stringWithFormat:@"%ld episode updates".ls, (long)self.updatedEpisodeCount]];
    if ([self.selectedCategories containsObject:@(kRowBookmarks)])
        [summaryItems addObject:[NSString stringWithFormat:@"%ld new bookmarks".ls, (long)self.newBookmarkCount]];
    if ([self.selectedCategories containsObject:@(kRowAppleWatchEpisodes)])
        [summaryItems addObject:[NSString stringWithFormat:@"%ld Apple Watch episodes".ls, (long)self.appleWatchEpisodeCount]];

    NSString *summary = summaryItems.count > 0
        ? [summaryItems componentsJoinedByString:@"\n"]
        : @"Import selected data?".ls;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Confirm Import".ls
                                                                  message:summary
                                                           preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Import".ls style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self performImport];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)performImport {
    if (self.analysisInProgress || self.analysisError) return;
    ICBackupImportCategory categories = 0;
    for (NSNumber *row in self.selectedCategories) {
        categories |= [self categoryForRow:row.integerValue];
    }

    // Build feed title list for new podcasts
    NSMutableArray<NSString *> *feedTitles = [NSMutableArray array];
    if (categories & ICBackupImportNewPodcasts) {
        for (ICBackupPodcast *podcast in self.backupData.podcasts) {
            if (!podcast.feedURL) continue;
            NSURL *url = [NSURL URLWithString:podcast.feedURL];
            if (url && ![DMANAGER feedWithSourceURL:url]) {
                [feedTitles addObject:podcast.title ?: podcast.feedURL];
            }
        }
    }

    ICBackupImportProgressView *progressView = [[ICBackupImportProgressView alloc] initWithFeedTitles:feedTitles
                                                                                          categories:categories];

    // Cancel handlers
    progressView.onCancelCurrentFeed = ^{
        [InstacastBackupImporter skipCurrentFeed];
    };
    progressView.onCancelImport = ^{
        [InstacastBackupImporter cancelImport];
    };

    [progressView showInWindow:self.view.window];

    // Build callbacks that forward to progress view (all called on main thread)
    ICBackupImportCallbacks callbacks = {
        .setCurrentFeed = ^(NSString *title, NSInteger index, NSInteger total) {
            [progressView setCurrentFeedAtIndex:index];
        },
        .setFeedProgress = ^(NSInteger index, float progress, NSString *detail) {
            [progressView setFeedProgress:progress detail:detail atIndex:index];
        },
        .setFeedCompleted = ^(NSInteger index, NSInteger episodeCount) {
            [progressView setFeedCompletedAtIndex:index episodeCount:episodeCount];
        },
        .setFeedError = ^(NSInteger index, NSString *message) {
            [progressView setFeedErrorAtIndex:index message:message];
        },
        .setFeedSkipped = ^(NSInteger index) {
            [progressView setFeedSkippedAtIndex:index];
        },
        .setTotalProgress = ^(float progress) {
            [progressView setTotalProgress:progress];
        },
        .setStatusText = ^(NSString *text) {
            [progressView setStatusText:text];
        },
        .setMetadataActive = ^(ICBackupImportCategory cat) {
            [progressView setMetadataCategoryActive:cat];
        },
        .setMetadataCompleted = ^(ICBackupImportCategory cat, NSString *detail) {
            [progressView setMetadataCategoryCompleted:cat detail:detail];
        },
        .setMetadataQueued = ^(ICBackupImportCategory cat, NSInteger itemCount) {
            [progressView setMetadataCategoryQueued:cat count:itemCount];
        },
    };

    [InstacastBackupImporter importBackup:self.backupData
                               categories:categories
                                callbacks:callbacks
                               completion:^(NSInteger importedCount, NSInteger queuedDownloadCount, NSError *error) {

        BOOL wasCancelled = error && [error.domain isEqualToString:@"InstacastBackupImporter"] && error.code == 1;
        NSString *queuedDownloadsSummary = nil;
        if (queuedDownloadCount == 1) {
            queuedDownloadsSummary = @"1 download queued for re-download. Track progress in Downloads.".ls;
        } else if (queuedDownloadCount > 1) {
            queuedDownloadsSummary = [NSString stringWithFormat:@"%ld downloads queued for re-download. Track progress in Downloads.".ls,
                                      (long)queuedDownloadCount];
        }

        if (wasCancelled) {
            NSString *summary = [NSString stringWithFormat:@"Import cancelled. %ld items imported.".ls, (long)importedCount];
            if (queuedDownloadsSummary) {
                summary = [NSString stringWithFormat:@"%@\n\n%@", summary, queuedDownloadsSummary];
            }
            [progressView showCompletionWithSummary:summary downloadsQueued:queuedDownloadCount > 0];
        } else if (error) {
            NSString *message = error.localizedDescription ?: @"Import Error".ls;
            if (importedCount > 0) {
                message = [NSString stringWithFormat:@"%@\n\n%@", message,
                           [NSString stringWithFormat:@"%ld items imported".ls, (long)importedCount]];
            }
            if (queuedDownloadsSummary) {
                message = [NSString stringWithFormat:@"%@\n\n%@", message, queuedDownloadsSummary];
            }
            [progressView closeWithCompletion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Error".ls
                                                                               message:message
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }];
            return;
        } else {
            NSString *summary = importedCount > 0 || !queuedDownloadsSummary
                ? [NSString stringWithFormat:@"%ld items imported".ls, (long)importedCount]
                : queuedDownloadsSummary;
            if (importedCount > 0 && queuedDownloadsSummary) {
                summary = [NSString stringWithFormat:@"%@\n\n%@", summary, queuedDownloadsSummary];
            }
            [progressView showCompletionWithSummary:summary downloadsQueued:queuedDownloadCount > 0];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [progressView closeWithCompletion:^{
                [self.navigationController popToRootViewControllerAnimated:YES];
            }];
        });
    }];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section {
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

@end
