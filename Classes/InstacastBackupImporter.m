//
//  InstacastBackupImporter.m
//  Instacast
//

#import "InstacastBackupImporter.h"
#import "InstacastBackupData.h"
#import "SubscriptionManager.h"
#import "CDPlaylist.h"
#import "CDBookmark.h"
#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"

// Forward-declare private method on SubscriptionManager
@interface SubscriptionManager (BackupImport)
- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(void))completion progress:(void (^)(float))progress;
@end

@implementation InstacastBackupImporter

+ (void)importBackup:(InstacastBackupData *)backup
           categories:(ICBackupImportCategory)categories
             progress:(void(^)(float progress, NSString *statusText))progress
           completion:(void(^)(NSInteger importedCount, NSError *error))completion
{
    // Run everything on the main queue for Core Data thread safety.
    // Use dispatch_async to not block the caller.
    dispatch_async(dispatch_get_main_queue(), ^{
        __block NSInteger totalImported = 0;
        float totalPhases = 0;
        __block float currentPhase = 0;

        // Count active phases
        if (categories & ICBackupImportNewPodcasts)   totalPhases++;
        if (categories & ICBackupImportEpisodeStatus)  totalPhases++;
        if (categories & ICBackupImportFeedSettings)   totalPhases++;
        if (categories & ICBackupImportBookmarks)      totalPhases++;
        if (categories & ICBackupImportUpNext)         totalPhases++;
        if (categories & ICBackupImportNowPlaying)     totalPhases++;
        if (categories & ICBackupImportPlaylists)      totalPhases++;
        if (categories & ICBackupImportSettings)       totalPhases++;
        if (categories & ICBackupImportSortOrder)      totalPhases++;

        if (totalPhases == 0) {
            if (completion) completion(0, nil);
            return;
        }

        void (^reportProgress)(NSString *) = ^(NSString *status) {
            if (progress) progress(currentPhase / totalPhases, status);
        };

        // We run the import phases sequentially using a block chain.
        // Phase 1 (new podcasts) is async, all others are sync on main thread.

        void (^runRemainingPhases)(void) = ^{
            // Phase 2: Episode Status
            if (categories & ICBackupImportEpisodeStatus) {
                reportProgress(@"Updating episode status…".ls);
                totalImported += [self importEpisodeStatusFromBackup:backup];
                currentPhase++;
            }

            // Phase 3: Feed Settings
            if (categories & ICBackupImportFeedSettings) {
                reportProgress(@"Importing podcast settings…".ls);
                totalImported += [self importFeedSettingsFromBackup:backup];
                currentPhase++;
            }

            // Phase 4: Bookmarks
            if (categories & ICBackupImportBookmarks) {
                reportProgress(@"Importing bookmarks…".ls);
                totalImported += [self importBookmarksFromBackup:backup];
                currentPhase++;
            }

            // Phase 5: Up Next
            if (categories & ICBackupImportUpNext) {
                reportProgress(@"Importing Up Next…".ls);
                totalImported += [self importUpNextFromBackup:backup];
                currentPhase++;
            }

            // Phase 6: Now Playing
            if (categories & ICBackupImportNowPlaying) {
                reportProgress(@"Restoring playback…".ls);
                totalImported += [self importNowPlayingFromBackup:backup];
                currentPhase++;
            }

            // Phase 7: Playlists
            if (categories & ICBackupImportPlaylists) {
                reportProgress(@"Importing playlists…".ls);
                totalImported += [self importPlaylistsFromBackup:backup];
                currentPhase++;
            }

            // Phase 8: App Settings
            if (categories & ICBackupImportSettings) {
                reportProgress(@"Importing settings…".ls);
                totalImported += [self importSettingsFromBackup:backup];
                currentPhase++;
            }

            // Phase 9: Sort Order
            if (categories & ICBackupImportSortOrder) {
                reportProgress(@"Importing sort order…".ls);
                totalImported += [self importSortOrderFromBackup:backup];
                currentPhase++;
            }

            // Finalize
            [DMANAGER save];

            // Re-apply appearance if settings were imported
            if (categories & ICBackupImportSettings) {
                [[ICAppearanceManager sharedManager] updateAppearance];
            }

            if (progress) progress(1.0, @"Done".ls);

            [[NSNotificationCenter defaultCenter] postNotificationName:@"OPMLImportDidFinishNotification" object:nil];

            // Change app icon if backup contains a different one (shows system dialog)
            if (categories & ICBackupImportSettings) {
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

            if (completion) completion(totalImported, nil);
        };

        // Phase 1: New Podcasts (async because importURLs uses network)
        if (categories & ICBackupImportNewPodcasts) {
            reportProgress(@"Subscribing new podcasts…".ls);

            NSMutableArray<NSURL *> *newURLs = [NSMutableArray array];
            for (ICBackupPodcast *podcast in backup.podcasts) {
                if (!podcast.feedURL) continue;
                NSURL *url = [NSURL URLWithString:podcast.feedURL];
                if (!url) continue;

                CDFeed *existingFeed = [DMANAGER feedWithSourceURL:url];
                if (!existingFeed) {
                    [newURLs addObject:url];
                }
            }

            if (newURLs.count > 0) {
                totalImported += newURLs.count;
                currentPhase++;

                [[SubscriptionManager sharedSubscriptionManager]
                 importURLs:newURLs
                 completion:^{
                     runRemainingPhases();
                 }
                 progress:nil];
            } else {
                currentPhase++;
                runRemainingPhases();
            }
        } else {
            runRemainingPhases();
        }
    });
}

#pragma mark - Phase 2: Episode Status

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

            CDEpisode *episode = nil;
            for (CDEpisode *ep in feed.episodes) {
                if ([ep.guid isEqualToString:backupEp.guid]) {
                    episode = ep;
                    break;
                }
            }
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

#pragma mark - Phase 3: Feed Settings

+ (NSInteger)importFeedSettingsFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;

    // Internal keys that should not be imported
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

        if (podcast.settings) {
            for (NSString *key in podcast.settings) {
                // Skip internal keys
                if ([internalKeys containsObject:key]) continue;

                NSString *value = podcast.settings[key];
                if (!value || value.length == 0) continue;

                if (![feed hasCustomProperties] || ![feed stringForKey:key]) {
                    if ([value isEqualToString:@"true"] || [value isEqualToString:@"false"]) {
                        [feed setBool:[value isEqualToString:@"true"] forKey:key];
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
    }

    [DMANAGER save];
    return count;
}

#pragma mark - Phase 4: Bookmarks

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
        CDEpisode *episode = nil;
        if (feed && backupBm.episodeGuid) {
            for (CDEpisode *ep in feed.episodes) {
                if ([ep.guid isEqualToString:backupBm.episodeGuid]) {
                    episode = ep;
                    break;
                }
            }
        }

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

#pragma mark - Phase 5: Up Next

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

#pragma mark - Phase 6: Now Playing

+ (NSInteger)importNowPlayingFromBackup:(InstacastBackupData *)backup {
    ICBackupEpisode *np = backup.nowPlaying;
    if (!np) return 0;

    CDEpisode *episode = [self findEpisodeWithGuid:np.guid feedURL:np.feedURL];
    if (!episode) return 0;

    [[AudioSession sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:(NSTimeInterval)np.position autostart:NO];
    return 1;
}

#pragma mark - Phase 7: Playlists

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

#pragma mark - Phase 8: App Settings

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
    };

    NSSet *boolKeys = [NSSet setWithArray:@[
        @"autoCacheAudio", @"autoCacheVideo", @"autoDeletePlayed", @"disableAutoLock",
        @"sleepTimerAlways", @"autoDeleteMarkedPlayed", @"autoDeleteNews",
        @"enableCachingOver3G", @"enableRefreshingOver3G", @"enableStreamingOver3G",
        @"uiSoundEnabled", @"showBadge", @"dontDeleteUpNext", @"showUnavailable",
        @"themeDefaultActive", @"playerPerPodcastColor",
    ]];

    NSSet *stringKeys = [NSSet setWithArray:@[@"themeColorHex", @"playerColorHex"]];

    NSInteger count = 0;
    NSUserDefaults *defaults = USER_DEFAULTS;

    for (NSString *xmlKey in backup.settings.values) {
        NSString *defaultsKey = settingsMap[xmlKey];
        if (!defaultsKey) continue;

        NSString *value = backup.settings.values[xmlKey];
        if (!value || value.length == 0) continue;

        if ([boolKeys containsObject:xmlKey]) {
            [defaults setBool:[value isEqualToString:@"true"] forKey:defaultsKey];
        } else if ([stringKeys containsObject:xmlKey]) {
            [defaults setObject:value forKey:defaultsKey];
        } else {
            [defaults setInteger:[value integerValue] forKey:defaultsKey];
        }
        count++;
    }

    [defaults synchronize];
    return count;
}

#pragma mark - Phase 9: Sort Order

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

#pragma mark - Helper

+ (CDEpisode *)findEpisodeWithGuid:(NSString *)guid feedURL:(NSString *)feedURLString {
    if (!guid || !feedURLString) return nil;

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
