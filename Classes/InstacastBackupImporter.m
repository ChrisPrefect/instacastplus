//
//  InstacastBackupImporter.m
//  Instacast
//

#import "InstacastBackupImporter.h"
#import "InstacastBackupData.h"
#import "SubscriptionManager.h"
#import "EpisodeLoadingManager.h"
#import "CDPlaylist.h"
#import "CDEpisodeList.h"
#import "CDBookmark.h"
#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"
#import "CacheManager.h"
#import "NSString+VMFoundation.h"

static NSString * const kPendingBackupDownloadsKey = @"PendingBackupDownloads";
static NSString * const kPendingNowPlayingKey = @"PendingBackupNowPlaying";

// Cancel flags — accessed from main thread
static BOOL _cancelImport = NO;
static BOOL _skipCurrentFeed = NO;

// GUID index for O(1) episode lookup
static NSMutableDictionary<NSString *, NSDictionary<NSString *, CDEpisode *> *> *_guidIndexByFeedURL = nil;

@implementation InstacastBackupImporter

#pragma mark - Cancel

+ (void)cancelImport {
    _cancelImport = YES;
}

+ (void)skipCurrentFeed {
    _skipCurrentFeed = YES;
}

#pragma mark - Main Entry Point

+ (void)importBackup:(InstacastBackupData *)backup
          categories:(ICBackupImportCategory)categories
           callbacks:(ICBackupImportCallbacks)callbacks
          completion:(void(^)(NSInteger importedCount, NSError *error))completion
{
    if (categories == 0) {
        if (completion) completion(0, nil);
        return;
    }

    _cancelImport = NO;
    _skipCurrentFeed = NO;
    _guidIndexByFeedURL = nil;

    // Copy all callback blocks to ensure they're on the heap (C struct doesn't auto-copy blocks)
    ICBackupImportCallbacks cb = {
        .setCurrentFeed   = [callbacks.setCurrentFeed copy],
        .setFeedProgress  = [callbacks.setFeedProgress copy],
        .setFeedCompleted = [callbacks.setFeedCompleted copy],
        .setFeedError     = [callbacks.setFeedError copy],
        .setFeedSkipped   = [callbacks.setFeedSkipped copy],
        .setTotalProgress = [callbacks.setTotalProgress copy],
        .setStatusText    = [callbacks.setStatusText copy],
        .setMetadataActive    = [callbacks.setMetadataActive copy],
        .setMetadataCompleted = [callbacks.setMetadataCompleted copy],
    };

    __block NSInteger totalImported = 0;

    // Determine which podcasts are new (not yet subscribed)
    NSMutableArray<ICBackupPodcast *> *newPodcasts = [NSMutableArray array];
    NSMutableArray<NSString *> *newFeedTitles = [NSMutableArray array];
    if (categories & ICBackupImportNewPodcasts) {
        for (ICBackupPodcast *podcast in backup.podcasts) {
            if (!podcast.feedURL) continue;
            NSURL *url = [NSURL URLWithString:podcast.feedURL];
            if (url && ![DMANAGER feedWithSourceURL:url]) {
                [newPodcasts addObject:podcast];
                [newFeedTitles addObject:podcast.title ?: podcast.feedURL];
            }
        }
    }

    // PHASE A: Subscribe feeds sequentially
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cb.setStatusText) cb.setStatusText(@"Subscribing podcasts…".ls);

        // Suspend episode loading during Phase A to prevent the EpisodeLoadingManager
        // from flooding the main queue with batch-insert blocks (which would starve
        // Phase A's completion blocks and freeze the UI).
        [EpisodeLoadingManager sharedManager].suspended = YES;

        [self _phaseA_subscribeFeeds:newPodcasts
                             atIndex:0
                           callbacks:cb
                          completion:^(NSArray<CDFeed *> *subscribedFeeds) {
            totalImported += subscribedFeeds.count;

            if (_cancelImport) {
                [EpisodeLoadingManager sharedManager].suspended = NO;
                [self _finalize:backup categories:categories totalImported:totalImported completion:completion];
                return;
            }

            // PHASE B: Wait for episode loading on all subscribed feeds
            // Resume the EpisodeLoadingManager — all queued feeds will start loading.
            [EpisodeLoadingManager sharedManager].suspended = NO;
            if (cb.setStatusText) cb.setStatusText(@"Loading episodes…".ls);

            [self _phaseB_waitForEpisodeLoading:subscribedFeeds
                                        atIndex:0
                                  feedIndexBase:0
                                      callbacks:cb
                                     completion:^{

                if (_cancelImport) {
                    [self _finalize:backup categories:categories totalImported:totalImported completion:completion];
                    return;
                }

                // Build GUID index for O(1) lookup in Phase C
                [self _buildGuidIndex];

                // PHASE C: Import local data (no network, async with UI yields)
                if (cb.setStatusText) cb.setStatusText(@"Importing local data…".ls);

                [self _phaseC_importLocalData:backup categories:categories callbacks:cb completion:^(NSInteger localCount) {
                    totalImported += localCount;

                    if (_cancelImport) {
                        [self _finalize:backup categories:categories totalImported:totalImported completion:completion];
                        return;
                    }

                    // PHASE D: Downloads + Now Playing
                    if (cb.setStatusText) cb.setStatusText(@"Finalizing…".ls);
                    [self _phaseD_finishDownloadsAndNowPlaying:cb];

                    // Finalize
                    [self _finalize:backup categories:categories totalImported:totalImported completion:completion];
                }];
            }];
        }];
    });
}

#pragma mark - Phase A: Subscribe Feeds (Sequential, Async)

+ (void)_phaseA_subscribeFeeds:(NSArray<ICBackupPodcast *> *)podcasts
                       atIndex:(NSInteger)index
                     callbacks:(ICBackupImportCallbacks)callbacks
                    completion:(void(^)(NSArray<CDFeed *> *subscribedFeeds))completion
{
    static NSMutableArray<CDFeed *> *_subscribedFeeds = nil;
    if (index == 0) {
        _subscribedFeeds = [NSMutableArray array];
    }

    NSInteger total = podcasts.count;

    if (_cancelImport || index >= total) {
        NSArray *result = [_subscribedFeeds copy];
        _subscribedFeeds = nil;
        if (completion) completion(result);
        return;
    }

    ICBackupPodcast *podcast = podcasts[index];
    NSString *title = podcast.title ?: podcast.feedURL;
    NSURL *url = [NSURL URLWithString:podcast.feedURL];

    if (callbacks.setCurrentFeed) callbacks.setCurrentFeed(title, index, total);

    // Update total progress
    float progress = (float)index / (float)MAX(total, 1);
    if (callbacks.setTotalProgress) callbacks.setTotalProgress(progress * 0.5); // Phase A = first 50%

    if (!url) {
        if (callbacks.setFeedError) callbacks.setFeedError(index, @"Invalid URL");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _phaseA_subscribeFeeds:podcasts atIndex:index + 1 callbacks:callbacks completion:completion];
        });
        return;
    }

    SubscriptionManager *sm = [SubscriptionManager sharedSubscriptionManager];
    [sm subscribeFeedWithURL:url options:kSubscribeOptionDontManageConsumedFlags completion:^(CDFeed *feed, NSError *error) {

        // subscribeFeedWithURL may call completion on a background thread (on error/timeout),
        // so we must dispatch everything to the main queue for thread safety.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_skipCurrentFeed) {
                _skipCurrentFeed = NO;
                if (callbacks.setFeedSkipped) callbacks.setFeedSkipped(index);
            } else if (error) {
                if (callbacks.setFeedError) callbacks.setFeedError(index, error.localizedDescription);
            } else if (feed) {
                // Feed subscribed — apply backup metadata
                feed.parked = podcast.parked;
                feed.rank = podcast.rank;
                if (podcast.username.length > 0) feed.username = podcast.username;
                if (podcast.password.length > 0) feed.password = podcast.password;

                [_subscribedFeeds addObject:feed];

                // Initial episodes are already loaded by subscribeFeedWithURL
                NSInteger episodeCount = feed.episodes.count;
                if (callbacks.setFeedProgress) callbacks.setFeedProgress(index, 0.5, [NSString stringWithFormat:@"%ld", (long)episodeCount]);
            }

            [DMANAGER save];

            // Next feed on next run loop iteration (keeps UI responsive)
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _phaseA_subscribeFeeds:podcasts atIndex:index + 1 callbacks:callbacks completion:completion];
            });
        });
    }];
}

#pragma mark - Phase B: Wait for Episode Loading

+ (void)_phaseB_waitForEpisodeLoading:(NSArray<CDFeed *> *)feeds
                              atIndex:(NSInteger)index
                        feedIndexBase:(NSInteger)feedIndexBase
                            callbacks:(ICBackupImportCallbacks)callbacks
                           completion:(void(^)(void))completion
{
    if (_cancelImport || index >= (NSInteger)feeds.count) {
        if (completion) completion();
        return;
    }

    CDFeed *feed = feeds[index];
    NSInteger feedDisplayIndex = feedIndexBase + index;
    EpisodeLoadingManager *elm = [EpisodeLoadingManager sharedManager];

    if (![elm isLoadingFeed:feed]) {
        // Already done loading
        NSInteger episodeCount = feed.episodes.count;
        if (callbacks.setFeedCompleted) callbacks.setFeedCompleted(feedDisplayIndex, episodeCount);

        float progress = 0.5 + (0.3 * ((float)(index + 1) / (float)MAX(feeds.count, 1))); // Phase B = 50%-80%
        if (callbacks.setTotalProgress) callbacks.setTotalProgress(progress);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _phaseB_waitForEpisodeLoading:feeds atIndex:index + 1 feedIndexBase:feedIndexBase callbacks:callbacks completion:completion];
        });
        return;
    }

    // Feed is still loading episodes — observe notifications
    __block id batchObserver = nil;
    __block id finishObserver = nil;
    __block BOOL observerCleanedUp = NO;

    void (^cleanupObservers)(void) = ^{
        if (observerCleanedUp) return;
        observerCleanedUp = YES;
        if (batchObserver) [[NSNotificationCenter defaultCenter] removeObserver:batchObserver];
        if (finishObserver) [[NSNotificationCenter defaultCenter] removeObserver:finishObserver];
        batchObserver = nil;
        finishObserver = nil;
    };

    batchObserver = [[NSNotificationCenter defaultCenter] addObserverForName:EpisodeLoadingManagerDidLoadBatchNotification
                                                                      object:nil
                                                                       queue:[NSOperationQueue mainQueue]
                                                                  usingBlock:^(NSNotification *note) {
        CDFeed *noteFeed = note.userInfo[@"feed"];
        if (![noteFeed isEqual:feed]) return;

        if (_skipCurrentFeed) {
            _skipCurrentFeed = NO;
            cleanupObservers();
            [elm cancelLoadingForFeed:feed];
            if (callbacks.setFeedSkipped) callbacks.setFeedSkipped(feedDisplayIndex);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _phaseB_waitForEpisodeLoading:feeds atIndex:index + 1 feedIndexBase:feedIndexBase callbacks:callbacks completion:completion];
            });
            return;
        }

        double p = [elm loadingProgressForFeed:feed];
        NSInteger loaded = feed.episodes.count;
        NSInteger total = [feed integerForKey:kFeedPropertyTotalExpectedEpisodes];
        NSString *detail = [NSString stringWithFormat:@"%ld/%ld", (long)loaded, (long)total];
        if (callbacks.setFeedProgress) callbacks.setFeedProgress(feedDisplayIndex, (float)p, detail);
    }];

    finishObserver = [[NSNotificationCenter defaultCenter] addObserverForName:EpisodeLoadingManagerDidFinishLoadingNotification
                                                                       object:nil
                                                                        queue:[NSOperationQueue mainQueue]
                                                                   usingBlock:^(NSNotification *note) {
        CDFeed *noteFeed = note.userInfo[@"feed"];
        if (![noteFeed isEqual:feed]) return;

        cleanupObservers();

        NSInteger episodeCount = feed.episodes.count;
        if (callbacks.setFeedCompleted) callbacks.setFeedCompleted(feedDisplayIndex, episodeCount);

        float progress = 0.5 + (0.3 * ((float)(index + 1) / (float)MAX(feeds.count, 1)));
        if (callbacks.setTotalProgress) callbacks.setTotalProgress(progress);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _phaseB_waitForEpisodeLoading:feeds atIndex:index + 1 feedIndexBase:feedIndexBase callbacks:callbacks completion:completion];
        });
    }];

    // Safety timeout: 120s per feed for episode loading
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (observerCleanedUp) return;

        cleanupObservers();
        [elm cancelLoadingForFeed:feed];

        NSInteger episodeCount = feed.episodes.count;
        if (callbacks.setFeedError) callbacks.setFeedError(feedDisplayIndex,
            [NSString stringWithFormat:@"%ld Ep. (timeout)", (long)episodeCount]);

        DebugLog(@"BackupImporter: Episode loading timeout for %@, loaded %ld episodes", feed.title, (long)episodeCount);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _phaseB_waitForEpisodeLoading:feeds atIndex:index + 1 feedIndexBase:feedIndexBase callbacks:callbacks completion:completion];
        });
    });
}

#pragma mark - Phase C: Local Data Import (async with UI yields)

+ (void)_phaseC_importLocalData:(InstacastBackupData *)backup
                     categories:(ICBackupImportCategory)categories
                      callbacks:(ICBackupImportCallbacks)callbacks
                     completion:(void(^)(NSInteger localCount))completion
{
    // Build phase array — each phase runs on main thread, with a run loop pass between phases
    NSMutableArray<dispatch_block_t> *phases = [NSMutableArray array];
    __block NSInteger totalImported = 0;

    if (categories & ICBackupImportEpisodeStatus) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportEpisodeStatus);
            NSInteger count = [self importEpisodeStatusFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportEpisodeStatus,
                [NSString stringWithFormat:@"%ld", (long)count]);
        }];
    }

    if (categories & ICBackupImportFeedSettings) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportFeedSettings);
            NSInteger count = [self importFeedSettingsFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportFeedSettings,
                [NSString stringWithFormat:@"%ld", (long)count]);
        }];
    }

    if (categories & ICBackupImportBookmarks) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportBookmarks);
            NSInteger count = [self importBookmarksFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportBookmarks,
                [NSString stringWithFormat:@"%ld", (long)count]);
        }];
    }

    if (categories & ICBackupImportUpNext) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportUpNext);
            NSInteger count = [self importUpNextFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportUpNext,
                [NSString stringWithFormat:@"%ld", (long)count]);
        }];
    }

    if (categories & ICBackupImportNowPlaying) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportNowPlaying);
            NSInteger count = [self importNowPlayingFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportNowPlaying,
                count > 0 ? @"1" : @"—");
        }];
    }

    if (categories & ICBackupImportPlaylists) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportPlaylists);
            NSInteger count = [self importPlaylistsFromBackup:backup];
            count += [self importEpisodeListsFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportPlaylists,
                [NSString stringWithFormat:@"%ld", (long)count]);
        }];
    }

    if (categories & ICBackupImportSettings) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportSettings);
            NSInteger count = [self importSettingsFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportSettings,
                [NSString stringWithFormat:@"%ld", (long)count]);
        }];
    }

    if (categories & ICBackupImportSortOrder) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportSortOrder);
            NSInteger count = [self importSortOrderFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportSortOrder,
                count > 0 ? @"✓" : @"—");
        }];
    }

    if (categories & ICBackupImportDownloads) {
        [phases addObject:^{
            if (callbacks.setMetadataActive) callbacks.setMetadataActive(ICBackupImportDownloads);
            NSInteger count = [self importDownloadsFromBackup:backup];
            totalImported += count;
            if (callbacks.setMetadataCompleted) callbacks.setMetadataCompleted(ICBackupImportDownloads,
                [NSString stringWithFormat:@"%ld", (long)count]);
        }];
    }

    // Run phases with run-loop yield between each (keeps UI responsive)
    [self _runPhaseCBlocks:phases atIndex:0 totalPhases:phases.count callbacks:callbacks completion:^{
        if (completion) completion(totalImported);
    }];
}

+ (void)_runPhaseCBlocks:(NSArray<dispatch_block_t> *)phases
                 atIndex:(NSInteger)index
             totalPhases:(NSInteger)total
               callbacks:(ICBackupImportCallbacks)callbacks
              completion:(void(^)(void))completion
{
    if (_cancelImport || index >= (NSInteger)phases.count) {
        if (completion) completion();
        return;
    }

    // Execute current phase
    phases[index]();

    // Update progress
    float progressBase = 0.8;
    float progressRange = 0.15;
    float progress = progressBase + progressRange * ((float)(index + 1) / (float)MAX(total, 1));
    if (callbacks.setTotalProgress) callbacks.setTotalProgress(progress);

    // Yield to run loop, then next phase
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _runPhaseCBlocks:phases atIndex:index + 1 totalPhases:total callbacks:callbacks completion:completion];
    });
}

#pragma mark - Phase D: Downloads + Now Playing

+ (void)_phaseD_finishDownloadsAndNowPlaying:(ICBackupImportCallbacks)callbacks {
    // Restore now playing
    [self processPendingNowPlaying];

    // Queue downloads
    [self processPendingDownloads];

    if (callbacks.setTotalProgress) callbacks.setTotalProgress(0.98);
}

#pragma mark - Finalize

+ (void)_finalize:(InstacastBackupData *)backup
       categories:(ICBackupImportCategory)categories
    totalImported:(NSInteger)totalImported
       completion:(void(^)(NSInteger importedCount, NSError *error))completion
{
    // Capture cancel state before resetting
    BOOL wasCancelled = _cancelImport;

    [DMANAGER save];

    if (categories & ICBackupImportSettings) {
        [[ICAppearanceManager sharedManager] updateAppearance];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"OPMLImportDidFinishNotification" object:nil];

    if (!wasCancelled && (categories & ICBackupImportSettings)) {
        NSString *backupIcon = backup.settings.values[@"appIcon"];
        if (backupIcon.length > 0) {
            NSString *currentIcon = [[UIApplication sharedApplication] alternateIconName];
            if (![backupIcon isEqualToString:currentIcon ?: @""]) {
                [[UIApplication sharedApplication] setAlternateIconName:backupIcon completionHandler:^(NSError *error) {
                    if (error) {
                        ErrLog(@"Failed to set app icon '%@': %@", backupIcon, error.localizedDescription);
                    }
                }];
            }
        }
    }

    // Clean up
    _guidIndexByFeedURL = nil;
    _cancelImport = NO;
    _skipCurrentFeed = NO;
    [EpisodeLoadingManager sharedManager].suspended = NO; // Safety: ensure loading is resumed

    if (completion) {
        NSError *error = wasCancelled
            ? [NSError errorWithDomain:@"InstacastBackupImporter" code:1
                              userInfo:@{NSLocalizedDescriptionKey: @"Import was cancelled.".ls}]
            : nil;
        completion(totalImported, error);
    }
}

#pragma mark - GUID Index Cache

+ (void)_buildGuidIndex {
    _guidIndexByFeedURL = [NSMutableDictionary dictionary];
    for (CDFeed *feed in DMANAGER.feeds) {
        if (!feed.sourceURL) continue;
        NSString *key = [feed.sourceURL absoluteString];
        NSMutableDictionary *index = [NSMutableDictionary dictionaryWithCapacity:feed.episodes.count];
        for (CDEpisode *ep in feed.episodes) {
            if (ep.guid) index[ep.guid] = ep;
        }
        _guidIndexByFeedURL[key] = index;
    }
    DebugLog(@"BackupImporter: Built GUID index for %lu feeds", (unsigned long)_guidIndexByFeedURL.count);
}

#pragma mark - Episode Status

+ (NSInteger)importEpisodeStatusFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;

    for (ICBackupPodcast *podcast in backup.podcasts) {
        if (!podcast.feedURL || podcast.episodes.count == 0) continue;
        NSURL *feedURL = [NSURL URLWithString:podcast.feedURL];
        if (!feedURL) continue;

        CDFeed *feed = [DMANAGER feedWithSourceURL:feedURL];
        if (!feed) continue;

        for (ICBackupEpisode *backupEp in podcast.episodes) {
            if (!backupEp.guid) continue;

            CDEpisode *episode = [self findEpisodeWithGuid:backupEp.guid feedURL:podcast.feedURL];
            if (!episode) continue;

            if (backupEp.played && !episode.consumed) {
                [DMANAGER markEpisode:episode asConsumed:YES];
                count++;
            }
            if (backupEp.starred && !episode.starred) {
                [DMANAGER markEpisode:episode asStarred:YES];
                count++;
            }
            if (backupEp.archived && !episode.archived) {
                [DMANAGER setEpisode:episode archived:YES];
                count++;
            }
            if (backupEp.position > episode.position) {
                [DMANAGER setEpisode:episode position:(double)backupEp.position];
                count++;
            }
            if (backupEp.duration > 0 && episode.duration == 0) {
                episode.duration = backupEp.duration;
                count++;
            }
        }
    }

    [DMANAGER save];
    return count;
}

#pragma mark - Feed Settings

+ (NSInteger)importFeedSettingsFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;

    NSSet *internalKeys = [NSSet setWithObjects:@"episodeLoadingComplete", @"loadedEpisodeCount", @"totalExpectedEpisodes", nil];

    for (ICBackupPodcast *podcast in backup.podcasts) {
        if (!podcast.feedURL) continue;
        NSURL *feedURL = [NSURL URLWithString:podcast.feedURL];
        if (!feedURL) continue;

        CDFeed *feed = [DMANAGER feedWithSourceURL:feedURL];
        if (!feed) continue;

        if (podcast.rank > 0) {
            feed.rank = podcast.rank;
        }
        feed.parked = podcast.parked;

        if (podcast.username.length > 0) {
            feed.username = podcast.username;
            count++;
        }
        if (podcast.password.length > 0) {
            feed.password = podcast.password;
            count++;
        }

        if (podcast.settings) {
            for (NSString *originalKey in podcast.settings) {
                if ([internalKeys containsObject:originalKey]) continue;

                NSString *value = podcast.settings[originalKey];
                if (!value || value.length == 0) continue;

                // Translate UID-prefixed keys: old UID → new feed's UID
                NSString *key = originalKey;
                if (key.length > 37 && [key characterAtIndex:36] == '_') {
                    NSString *prefix = [key substringToIndex:36];
                    if ([prefix characterAtIndex:8] == '-' && [prefix characterAtIndex:13] == '-' &&
                        [prefix characterAtIndex:18] == '-' && [prefix characterAtIndex:23] == '-') {
                        NSString *suffix = [key substringFromIndex:36];
                        key = [feed.uid stringByAppendingString:suffix];
                    }
                }

                if ([value isEqualToString:@"true"] || [value isEqualToString:@"false"]) {
                    [feed setBool:[value isEqualToString:@"true"] forKey:key];
                } else if ([value rangeOfString:@"."].location != NSNotFound) {
                    [feed setDouble:[value doubleValue] forKey:key];
                } else {
                    NSInteger intVal = [value integerValue];
                    if (intVal != 0 || [value isEqualToString:@"0"]) {
                        [feed setInteger:intVal forKey:key];
                    } else {
                        [feed setString:value forKey:key];
                    }
                }
                count++;
            }
        }
    }

    [DMANAGER save];
    return count;
}

#pragma mark - Bookmarks

+ (NSInteger)importBookmarksFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;
    NSArray *existingBookmarks = DMANAGER.bookmarks;

    for (ICBackupBookmark *backupBm in backup.bookmarks) {
        if (!backupBm.episodeGuid || !backupBm.feedURL) continue;

        BOOL isDuplicate = NO;
        for (CDBookmark *existing in existingBookmarks) {
            if ([existing.episodeGuid isEqualToString:backupBm.episodeGuid] &&
                [[existing.feedURL absoluteString] isEqualToString:backupBm.feedURL] &&
                fabs(existing.position - backupBm.position) <= 1.0) {
                isDuplicate = YES;
                break;
            }
        }
        if (isDuplicate) continue;

        NSURL *feedURL = [NSURL URLWithString:backupBm.feedURL];
        CDFeed *feed = feedURL ? [DMANAGER feedWithSourceURL:feedURL] : nil;
        CDEpisode *episode = [self findEpisodeWithGuid:backupBm.episodeGuid feedURL:backupBm.feedURL];

        CDBookmark *bookmark = [NSEntityDescription insertNewObjectForEntityForName:@"Bookmark"
                                                             inManagedObjectContext:DMANAGER.objectContext];
        bookmark.title = backupBm.title;
        bookmark.position = backupBm.position;
        bookmark.episodeGuid = backupBm.episodeGuid;
        bookmark.feedURL = feedURL;
        bookmark.episodeHash = [[NSString stringWithFormat:@"%@%@", backupBm.feedURL ?: @"", backupBm.episodeGuid ?: @""] MD5Hash];

        if (feed) {
            bookmark.feedTitle = feed.title;
            bookmark.imageURL = feed.imageURL;
        }
        if (episode) {
            bookmark.episodeTitle = episode.title;
        }

        [DMANAGER addBookmark:bookmark];
        count++;
    }

    [DMANAGER save];
    return count;
}

#pragma mark - Up Next

+ (NSInteger)importUpNextFromBackup:(InstacastBackupData *)backup {
    NSMutableArray<CDEpisode *> *upNextEpisodes = [NSMutableArray array];
    for (ICBackupEpisode *backupEp in backup.upNextEpisodes) {
        CDEpisode *episode = [self findEpisodeWithGuid:backupEp.guid feedURL:backupEp.feedURL];
        if (episode) {
            [upNextEpisodes addObject:episode];
        }
    }

    if (upNextEpisodes.count > 0) {
        [[AudioSession sharedAudioSession] appendToUpNext:upNextEpisodes];
    }
    return upNextEpisodes.count;
}

#pragma mark - Now Playing

+ (NSInteger)importNowPlayingFromBackup:(InstacastBackupData *)backup {
    ICBackupEpisode *np = backup.nowPlaying;
    if (!np) return 0;

    CDEpisode *episode = [self findEpisodeWithGuid:np.guid feedURL:np.feedURL];
    if (!episode) {
        // Episode not found — save for later (will be retried after episode loading)
        [USER_DEFAULTS setObject:@{
            @"guid": np.guid ?: @"",
            @"feedURL": np.feedURL ?: @"",
            @"position": @(np.position)
        } forKey:kPendingNowPlayingKey];
        [USER_DEFAULTS synchronize];
        return 1;
    }

    if (np.position > 0) {
        episode.position = np.position;
    }

    if (episode.preferedMedium.fileURL) {
        [[AudioSession sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:(NSTimeInterval)np.position autostart:NO];
    } else {
        // Stub episode — save for later, restore after feed refresh
        [USER_DEFAULTS setObject:@{
            @"guid": np.guid ?: @"",
            @"feedURL": np.feedURL ?: @"",
            @"position": @(np.position)
        } forKey:kPendingNowPlayingKey];
        [USER_DEFAULTS synchronize];
    }
    return 1;
}

+ (void)processPendingNowPlaying {
    NSDictionary *pending = [USER_DEFAULTS objectForKey:kPendingNowPlayingKey];
    if (!pending) return;

    NSString *guid = pending[@"guid"];
    NSString *feedURL = pending[@"feedURL"];
    int32_t position = [pending[@"position"] intValue];

    CDEpisode *episode = [self findEpisodeWithGuid:guid feedURL:feedURL];
    if (!episode || !episode.preferedMedium.fileURL) return;

    [USER_DEFAULTS removeObjectForKey:kPendingNowPlayingKey];
    [USER_DEFAULTS synchronize];

    [[AudioSession sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:(NSTimeInterval)position autostart:NO];
}

#pragma mark - Playlists

+ (NSInteger)importPlaylistsFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;

    for (ICBackupPlaylist *backupList in backup.playlists) {
        if (!backupList.name) continue;

        CDPlaylist *existingPlaylist = nil;
        for (CDList *list in DMANAGER.lists) {
            if ([list isKindOfClass:[CDPlaylist class]] && [list.name isEqualToString:backupList.name]) {
                existingPlaylist = (CDPlaylist *)list;
                break;
            }
        }

        CDPlaylist *playlist = existingPlaylist;
        if (!playlist) {
            playlist = [NSEntityDescription insertNewObjectForEntityForName:@"Playlist"
                                                     inManagedObjectContext:DMANAGER.objectContext];
            playlist.name = backupList.name;
            playlist.rank = backupList.rank;
            [DMANAGER addList:playlist];
            count++;
        }

        NSSet *existingEpisodes = [NSSet setWithArray:playlist.sortedEpisodes];
        for (ICBackupEpisode *backupEp in backupList.episodes) {
            CDEpisode *episode = [self findEpisodeWithGuid:backupEp.guid feedURL:backupEp.feedURL];
            if (episode && ![existingEpisodes containsObject:episode]) {
                [playlist addEpisode:episode];
                count++;
            }
        }
    }

    [DMANAGER save];
    return count;
}

#pragma mark - Episode Lists

+ (NSInteger)importEpisodeListsFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;

    for (ICBackupEpisodeList *backupList in backup.episodeLists) {
        if (!backupList.uid) continue;

        CDEpisodeList *existingList = nil;
        for (CDList *list in DMANAGER.lists) {
            if ([list isKindOfClass:[CDEpisodeList class]] && [list.uid isEqualToString:backupList.uid]) {
                existingList = (CDEpisodeList *)list;
                break;
            }
        }

        if (existingList) {
            existingList.audio = backupList.audio;
            existingList.video = backupList.video;
            existingList.downloaded = backupList.downloaded;
            existingList.downloading = backupList.downloading;
            existingList.notDownloaded = backupList.notDownloaded;
            existingList.unplayed = backupList.unplayed;
            existingList.unfinished = backupList.unfinished;
            existingList.played = backupList.played;
            existingList.starred = backupList.starred;
            existingList.notStarred = backupList.notStarred;
            if (backupList.orderBy) existingList.orderBy = backupList.orderBy;
            existingList.descending = backupList.descending;
            existingList.groupByPodcast = backupList.groupByPodcast;
            existingList.continuousPlayback = backupList.continuousPlayback;

            if (backupList.includedFeedURLs.count > 0) {
                NSMutableSet *feeds = [NSMutableSet set];
                for (NSString *urlStr in backupList.includedFeedURLs) {
                    NSURL *url = [NSURL URLWithString:urlStr];
                    CDFeed *feed = url ? [DMANAGER feedWithSourceURL:url] : nil;
                    if (feed) [feeds addObject:feed];
                }
                existingList.includedFeeds = feeds;
            }

            [existingList invalidateCaches];
            count++;
        } else {
            CDEpisodeList *newList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList"
                                                                  inManagedObjectContext:DMANAGER.objectContext];
            newList.uid = backupList.uid;
            newList.name = backupList.name;
            newList.icon = backupList.icon;
            newList.rank = backupList.rank;
            newList.audio = backupList.audio;
            newList.video = backupList.video;
            newList.downloaded = backupList.downloaded;
            newList.downloading = backupList.downloading;
            newList.notDownloaded = backupList.notDownloaded;
            newList.unplayed = backupList.unplayed;
            newList.unfinished = backupList.unfinished;
            newList.played = backupList.played;
            newList.starred = backupList.starred;
            newList.notStarred = backupList.notStarred;
            newList.orderBy = backupList.orderBy;
            newList.descending = backupList.descending;
            newList.groupByPodcast = backupList.groupByPodcast;
            newList.continuousPlayback = backupList.continuousPlayback;

            if (backupList.includedFeedURLs.count > 0) {
                NSMutableSet *feeds = [NSMutableSet set];
                for (NSString *urlStr in backupList.includedFeedURLs) {
                    NSURL *url = [NSURL URLWithString:urlStr];
                    CDFeed *feed = url ? [DMANAGER feedWithSourceURL:url] : nil;
                    if (feed) [feeds addObject:feed];
                }
                newList.includedFeeds = feeds;
            }

            [DMANAGER addList:newList];
            count++;
        }
    }

    [DMANAGER save];
    return count;
}

#pragma mark - App Settings

+ (NSInteger)importSettingsFromBackup:(InstacastBackupData *)backup {
    NSDictionary *settingsMap = @{
        @"playbackSpeed":           DefaultPlaybackSpeed,
        @"skipBack":                PlayerSkipBackPeriod,
        @"skipForward":             PlayerSkipForwardPeriod,
        @"autoSkipStart":           PlayerAutoSkipStartPeriod,
        @"autoSkipEnd":             PlayerAutoSkipEndPeriod,
        @"replayAfterPause":        PlayerReplayAfterPause,
        @"autoCacheAudio":          AutoCacheNewAudioEpisodes,
        @"autoCacheVideo":          AutoCacheNewVideoEpisodes,
        @"autoDeletePlayed":        AutoDeleteAfterFinishedPlaying,
        @"disableAutoLock":         DisableAutoLock,
        @"appearanceMode":          kDefaultAppearanceMode,
        @"sleepTimerAlways":        ScreenTimerAlwaysActive,
        @"disableSleepTimerCarPlay": DisableSleepTimerInCarPlay,
        @"lastSleepTimer":          LastSelectedSleepTimer,
        @"playerControls":          kDefaultPlayerControls,
        @"autoDeleteMarkedPlayed":  AutoDeleteAfterMarkedAsPlayed,
        @"autoDeleteNews":          AutoDeleteNewsMode,
        @"enableCachingOver3G":     EnableCachingOver3G,
        @"enableRefreshingOver3G":  EnableRefreshingOver3G,
        @"enableStreamingOver3G":   EnableStreamingOver3G,
        @"uiSoundEnabled":          UISoundEnabled,
        @"showBadge":               ShowApplicationBadgeForUnseen,
        @"dontDeleteUpNext":        kDefaultDontDeleteUpNextWhenChangingEpisode,
        @"showUnavailable":         kDefaultShowUnavailableEpisodes,
        @"themeDefaultActive":      InterfaceThemeDefaultActive,
        @"themeColorHex":           InterfaceThemeColorHexCode,
        @"playerPerPodcastColor":   PlayerColorPerPodcastActive,
        @"playerColorHex":          PlayerThemeColorHexCode,
        @"smarthomeMQTTEnabled":    SmarthomeMQTTEnabled,
        @"smarthomeMQTTHost":       SmarthomeMQTTHost,
        @"smarthomeMQTTPort":       SmarthomeMQTTPort,
        @"smarthomeMQTTUsername":   SmarthomeMQTTUsername,
        @"smarthomeMQTTPassword":   SmarthomeMQTTPassword,
        @"smarthomeAllowControl":   SmarthomeAllowControl,
        @"smarthomeWiFiOnly":       SmarthomeWiFiOnly,
        @"smarthomeDeviceName":     SmarthomeDeviceName,
        @"deviceMovementIntelligentSleep": DeviceMovementIntelligentSleep,
        @"deviceMovementSensitivity":      DeviceMovementSensitivity,
        @"screenTouchIntelligentSleep":    ScreenTouchIntelligentSleep,
        @"volumeChangeIntelligentSleep":   VolumeChangeIntelligentSleep,
        @"continuousPlay":          ContinuousPlayFromFeed,
        @"autoCacheStorageLimit":   AutoCacheStorageLimit,
        @"autoDownloadWhileStreaming": AutoDownloadWhileStreaming,
        @"enableCachingImagesOver3G": EnableCachingImagesOver3G,
        @"openLinksExternal":       OpenLinksInExternalBrowser,
        @"notifyNewEpisode":        EnableNewEpisodeNotification,
        @"notifyRefreshFinished":   EnableManualRefreshFinishedNotification,
        @"notifyDownloadFinished":  EnableManualDownloadFinishedNotification,
        @"themeColorCode":          InterfaceThemeColorCode,
        @"playerColorCode":         PlayerThemeColorCode,
        @"intelligentSleepAlways":  IntelligentSleepTimerAlwaysActive,
        @"feedSortOrder":           FeedSortOrder,
        @"selectedAppLanguage":     SelectedAppLanguage,
    };

    NSSet *boolKeys = [NSSet setWithArray:@[
        @"autoCacheAudio", @"autoCacheVideo", @"autoDeletePlayed", @"disableAutoLock",
        @"sleepTimerAlways", @"disableSleepTimerCarPlay", @"autoDeleteMarkedPlayed", @"autoDeleteNews",
        @"enableCachingOver3G", @"enableRefreshingOver3G", @"enableStreamingOver3G",
        @"uiSoundEnabled", @"showBadge", @"dontDeleteUpNext", @"showUnavailable",
        @"themeDefaultActive", @"playerPerPodcastColor",
        @"smarthomeMQTTEnabled", @"smarthomeAllowControl", @"smarthomeWiFiOnly",
        @"deviceMovementIntelligentSleep", @"screenTouchIntelligentSleep", @"volumeChangeIntelligentSleep",
        @"continuousPlay", @"autoDownloadWhileStreaming", @"enableCachingImagesOver3G",
        @"openLinksExternal", @"notifyNewEpisode", @"notifyRefreshFinished", @"notifyDownloadFinished",
        @"intelligentSleepAlways",
    ]];

    NSSet *doubleKeys = [NSSet setWithArray:@[@"deviceMovementSensitivity"]];

    NSSet *stringKeys = [NSSet setWithArray:@[@"themeColorHex", @"playerColorHex",
        @"smarthomeMQTTHost", @"smarthomeMQTTUsername", @"smarthomeMQTTPassword", @"smarthomeDeviceName",
        @"feedSortOrder", @"selectedAppLanguage"]];

    NSInteger count = 0;
    NSUserDefaults *defaults = USER_DEFAULTS;

    for (NSString *xmlKey in backup.settings.values) {
        NSString *defaultsKey = settingsMap[xmlKey];
        if (!defaultsKey) continue;

        NSString *value = backup.settings.values[xmlKey];
        if (!value || value.length == 0) continue;

        if ([boolKeys containsObject:xmlKey]) {
            [defaults setBool:[value isEqualToString:@"true"] forKey:defaultsKey];
        } else if ([doubleKeys containsObject:xmlKey]) {
            [defaults setDouble:[value doubleValue] forKey:defaultsKey];
        } else if ([stringKeys containsObject:xmlKey]) {
            [defaults setObject:value forKey:defaultsKey];
        } else {
            [defaults setInteger:[value integerValue] forKey:defaultsKey];
        }
        count++;
    }

    if (backup.settings.mainMenuListUIDs.count > 0) {
        [defaults setObject:backup.settings.mainMenuListUIDs forKey:@"MainMenuListUIDs"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MainMenuListUIDsDidChangeNotification" object:nil];
        count++;
    }

    [defaults synchronize];
    return count;
}

#pragma mark - Sort Order

+ (NSInteger)importSortOrderFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;
    NSUserDefaults *defaults = USER_DEFAULTS;

    if (backup.settings.feedListSortMode) {
        [defaults setObject:backup.settings.feedListSortMode forKey:FeedListSortMode];
        count++;
    }

    if (backup.settings.manualFeedOrder.count > 0) {
        [defaults setObject:backup.settings.manualFeedOrder forKey:@"ManualFeedOrder"];
        [DMANAGER restoreManualFeedOrder];
        count++;
    }

    [defaults synchronize];
    return count;
}

#pragma mark - Re-download Episodes (deferred)

+ (NSInteger)importDownloadsFromBackup:(InstacastBackupData *)backup {
    NSMutableArray *pendingDownloads = [NSMutableArray array];
    NSInteger count = 0;

    for (ICBackupPodcast *podcast in backup.podcasts) {
        if (!podcast.feedURL || podcast.episodes.count == 0) continue;

        NSMutableArray *guids = [NSMutableArray array];
        for (ICBackupEpisode *backupEp in podcast.episodes) {
            if (!backupEp.downloaded || !backupEp.guid) continue;
            [guids addObject:backupEp.guid];
            count++;
        }

        if (guids.count > 0) {
            [pendingDownloads addObject:@{@"feedURL": podcast.feedURL, @"guids": guids}];
        }
    }

    if (pendingDownloads.count > 0) {
        [USER_DEFAULTS setObject:pendingDownloads forKey:kPendingBackupDownloadsKey];
        [USER_DEFAULTS synchronize];
    }

    DebugLog(@"BackupImporter: Saved %ld episodes for deferred download", (long)count);
    return count;
}

+ (void)processPendingDownloads {
    NSArray *pendingDownloads = [USER_DEFAULTS objectForKey:kPendingBackupDownloadsKey];
    if (!pendingDownloads || pendingDownloads.count == 0) return;

    NSInteger queued = 0;
    NSMutableArray *remaining = [NSMutableArray array];

    for (NSDictionary *entry in pendingDownloads) {
        NSString *feedURLString = entry[@"feedURL"];
        NSArray *guids = entry[@"guids"];
        if (!feedURLString || !guids) continue;

        NSURL *feedURL = [NSURL URLWithString:feedURLString];
        if (!feedURL) continue;

        CDFeed *feed = [DMANAGER feedWithSourceURL:feedURL];
        if (!feed) continue;

        NSMutableArray *remainingGuids = [NSMutableArray array];
        for (NSString *guid in guids) {
            CDEpisode *episode = [self findEpisodeWithGuid:guid feedURL:feedURLString];

            if (!episode || [[CacheManager sharedCacheManager] episodeIsCached:episode]) continue;

            if (episode.preferedMedium.fileURL) {
                [[CacheManager sharedCacheManager] cacheEpisode:episode];
                queued++;
            } else {
                [remainingGuids addObject:guid];
            }
        }

        if (remainingGuids.count > 0) {
            [remaining addObject:@{@"feedURL": feedURLString, @"guids": remainingGuids}];
        }
    }

    if (remaining.count > 0) {
        [USER_DEFAULTS setObject:remaining forKey:kPendingBackupDownloadsKey];
    } else {
        [USER_DEFAULTS removeObjectForKey:kPendingBackupDownloadsKey];
    }
    [USER_DEFAULTS synchronize];

    if (queued > 0) {
        DebugLog(@"BackupImporter: Queued %ld pending downloads", (long)queued);
    }
}

#pragma mark - Helper

+ (CDEpisode *)findEpisodeWithGuid:(NSString *)guid feedURL:(NSString *)feedURLString {
    if (!guid || !feedURLString) return nil;

    // Try GUID index first (O(1))
    if (_guidIndexByFeedURL) {
        NSDictionary *index = _guidIndexByFeedURL[feedURLString];
        if (index) return index[guid];
    }

    // Fallback: linear search
    NSURL *feedURL = [NSURL URLWithString:feedURLString];
    if (!feedURL) return nil;

    CDFeed *feed = [DMANAGER feedWithSourceURL:feedURL];
    if (!feed) return nil;

    for (CDEpisode *ep in feed.episodes) {
        if ([ep.guid isEqualToString:guid]) {
            return ep;
        }
    }
    return nil;
}

@end
