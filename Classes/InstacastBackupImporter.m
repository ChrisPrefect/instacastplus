//
//  InstacastBackupImporter.m
//  Instacast
//
//  Completely rewritten: Synchronous import on a dedicated background thread.
//  Cancel kills the operation immediately. All Core Data + UI dispatched to main thread.
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
#import "ImageCacheManager.h"
#import "WidgetDataExporter.h"
#import "AppleWatchSyncManager.h"
#import "AppleWatchEpisodeState.h"
#import "NSString+VMFoundation.h"
#import "InstacastPlus-Swift.h"
#import <UIKit/UIKit.h>

static NSString * const kPendingBackupDownloadsKey = @"PendingBackupDownloads";
static NSString * const kPendingNowPlayingKey = @"PendingBackupNowPlaying";

// The currently running import operation — cancel via [_currentOperation cancel]
static NSOperationQueue *_importQueue = nil;
static NSBlockOperation *_currentOperation = nil;
static BOOL _skipCurrentFeed;

// GUID index for O(1) episode lookup
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSManagedObjectID *> *> *_guidIndexByFeedURL = nil;

static dispatch_queue_t ICBackupImportStateQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.vemedio.instacast.backupImport.state", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void ICBackupSetSkipCurrentFeed(BOOL skip) {
    dispatch_sync(ICBackupImportStateQueue(), ^{
        _skipCurrentFeed = skip;
    });
}

static BOOL ICBackupConsumeSkipCurrentFeed(void) {
    __block BOOL skip = NO;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        skip = _skipCurrentFeed;
        _skipCurrentFeed = NO;
    });
    return skip;
}

static BOOL ICBackupSkipCurrentFeedRequested(void) {
    __block BOOL skip = NO;
    dispatch_sync(ICBackupImportStateQueue(), ^{
        skip = _skipCurrentFeed;
    });
    return skip;
}

static UIColor *ICBackupColorFromHexString(NSString *hexString) {
    if (![hexString isKindOfClass:[NSString class]]) return nil;

    NSString *cleanString = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (cleanString.length != 6) return nil;

    unsigned int rgbValue = 0;
    NSScanner *scanner = [NSScanner scannerWithString:cleanString];
    if (![scanner scanHexInt:&rgbValue]) return nil;

    return [UIColor colorWithRed:((rgbValue >> 16) & 0xFF) / 255.0
                           green:((rgbValue >> 8) & 0xFF) / 255.0
                            blue:(rgbValue & 0xFF) / 255.0
                           alpha:1.0];
}

static void ICBackupApplyColorHex(NSUserDefaults *defaults, NSString *hexString, NSString *hexKey, NSString *colorDataKey) {
    if (hexString.length == 0) return;

    [defaults setObject:hexString forKey:hexKey];

    UIColor *color = ICBackupColorFromHexString(hexString);
    if (!color) return;

    NSError *error = nil;
    NSData *colorData = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:YES error:&error];
    if (colorData) {
        [defaults setObject:colorData forKey:colorDataKey];
    }
}

#pragma mark - Helper: run block on main thread synchronously (from background)

static void runOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

@implementation InstacastBackupImporter

#pragma mark - Cancel

+ (void)cancelImport {
    [_currentOperation cancel];
    // Also cancel any pending episode loading
    runOnMain(^{
        [[EpisodeLoadingManager sharedManager] cancelAllLoading];
    });
}

+ (void)skipCurrentFeed {
    ICBackupSetSkipCurrentFeed(YES);
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

    ICBackupSetSkipCurrentFeed(NO);
    _guidIndexByFeedURL = nil;

    // Copy all callback blocks (C struct doesn't auto-copy)
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

    // Create import queue (serial, one operation at a time)
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _importQueue = [[NSOperationQueue alloc] init];
        _importQueue.maxConcurrentOperationCount = 1;
        _importQueue.name = @"com.vemedio.instacast.backupImport";
    });

    // Cancel any previous import
    [_currentOperation cancel];

    // Determine which podcasts are new
    __block NSMutableArray<ICBackupPodcast *> *newPodcasts = nil;
    runOnMain(^{
        newPodcasts = [NSMutableArray array];
        if (categories & ICBackupImportNewPodcasts) {
            for (ICBackupPodcast *podcast in backup.podcasts) {
                if (!podcast.feedURL) continue;
                NSURL *url = [NSURL URLWithString:podcast.feedURL];
                if (url && ![DMANAGER feedWithSourceURL:url]) {
                    [newPodcasts addObject:podcast];
                }
            }
        }
    });

    // Create the import operation
    NSBlockOperation *operation = [[NSBlockOperation alloc] init];
    _currentOperation = operation;

    __weak NSBlockOperation *weakOp = operation;

    [operation addExecutionBlock:^{
        NSBlockOperation *op = weakOp;
        if (!op || op.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:0 wasCancelled:YES completion:completion];
            });
            return;
        }

        // Suspend ELM during entire import — we do episode loading ourselves
        runOnMain(^{
            [EpisodeLoadingManager sharedManager].suspended = YES;
            if (cb.setStatusText) cb.setStatusText(@"Subscribing podcasts…".ls);
        });

        __block NSInteger totalImported = 0;
        NSMutableArray<CDFeed *> *subscribedFeeds = [NSMutableArray array];
        NSInteger feedCount = newPodcasts.count;

        // ═══════════════════════════════════════════════════════
        // PHASE A: Subscribe feeds — ONE AT A TIME, synchronous
        // ═══════════════════════════════════════════════════════

        for (NSInteger i = 0; i < feedCount; i++) {
            if (op.isCancelled) break;

            ICBackupPodcast *podcast = newPodcasts[i];
            NSString *title = podcast.title ?: podcast.feedURL;
            NSURL *url = [NSURL URLWithString:podcast.feedURL];

            // UI: show which feed is being subscribed
            // Phase A uses 0–98% of progress (it's 99% of total time)
            runOnMain(^{
                if (cb.setCurrentFeed) cb.setCurrentFeed(title, i, feedCount);
                float progress = (float)i / (float)MAX(feedCount, 1) * 0.98;
                if (cb.setTotalProgress) cb.setTotalProgress(progress);
            });

            if (!url) {
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, @"Invalid URL");
                });
                continue;
            }

            if (ICBackupConsumeSkipCurrentFeed()) {
                runOnMain(^{
                    if (cb.setFeedSkipped) cb.setFeedSkipped(i);
                });
                continue;
            }

            // Subscribe synchronously using semaphore
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            __block CDFeed *subscribedFeed = nil;
            __block NSError *subscribeError = nil;

            NSString *username = podcast.username;
            NSString *password = podcast.password;

            runOnMain(^{
                SubscriptionManager *sm = [SubscriptionManager sharedSubscriptionManager];
                [sm subscribeFeedWithURL:url username:username password:password options:kSubscribeOptionDontManageConsumedFlags completion:^(CDFeed *feed, NSError *error) {
                    subscribedFeed = feed;
                    subscribeError = error;
                    dispatch_semaphore_signal(sem);
                }];
            });

            // Wait for subscribe completion (timeout 25s, poll every 200ms for cancel)
            long result = -1;
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:25];
            while (result != 0 && !op.isCancelled && [deadline timeIntervalSinceNow] > 0) {
                result = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)));
            }

            if (op.isCancelled) break;

            if (ICBackupConsumeSkipCurrentFeed()) {
                runOnMain(^{
                    if (cb.setFeedSkipped) cb.setFeedSkipped(i);
                });
                continue;
            }

            if (result != 0) {
                // Timeout
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, @"Timeout");
                });
                continue;
            }

            if (subscribeError) {
                NSString *errorMsg = subscribeError.localizedDescription;
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, errorMsg);
                });
                continue;
            }

            if (!subscribedFeed) {
                runOnMain(^{
                    if (cb.setFeedError) cb.setFeedError(i, @"Unknown error");
                });
                continue;
            }

            // Apply backup metadata on main thread
            runOnMain(^{
                subscribedFeed.parked = podcast.parked;
                subscribedFeed.rank = podcast.rank;
                if (podcast.username.length > 0) subscribedFeed.username = podcast.username;
                if (podcast.password.length > 0) subscribedFeed.password = podcast.password;
                [DMANAGER save];

                // Pre-load podcast theme image so it's available when the subscription list appears
                if (subscribedFeed.imageURL) {
                    [ImageCacheManager loadImageForURL:subscribedFeed.imageURL
                                                 size:88
                                            grayscale:NO
                                           completion:nil];
                }
            });

            [subscribedFeeds addObject:subscribedFeed];
            totalImported++;

            // UI: show initial episode count
            __block NSInteger initialEpCount = 0;
            runOnMain(^{
                initialEpCount = subscribedFeed.episodes.count;
                if (cb.setFeedProgress) cb.setFeedProgress(i, 0.2,
                    [NSString stringWithFormat:@"%ld", (long)initialEpCount]);
            });

            // ═════════════════════════════════════════════════
            // EPISODE LOADING: Load remaining episodes for this feed
            // Resume ELM, observe batch/finish notifications, wait until done
            // ═════════════════════════════════════════════════

            if (op.isCancelled) break;

            EpisodeLoadingManager *elm = [EpisodeLoadingManager sharedManager];
            __block BOOL feedHasPending = NO;
            runOnMain(^{
                feedHasPending = [elm isLoadingFeed:subscribedFeed];
            });

            if (feedHasPending) {
                runOnMain(^{
                    if (cb.setStatusText) cb.setStatusText([NSString stringWithFormat:@"Loading episodes: %@".ls, title]);
                });

                __block NSInteger totalExpected = 0;
                runOnMain(^{
                    totalExpected = [subscribedFeed integerForKey:kFeedPropertyTotalExpectedEpisodes];
                });

                // Set up notifications and resume ELM
                dispatch_semaphore_t finishSem = dispatch_semaphore_create(0);
                __block id batchObserver = nil;
                __block id finishObserver = nil;
                __block BOOL cleanedUp = NO;

                void (^cleanupObservers)(void) = ^{
                    if (cleanedUp) return;
                    cleanedUp = YES;
                    if (batchObserver) [[NSNotificationCenter defaultCenter] removeObserver:batchObserver];
                    if (finishObserver) [[NSNotificationCenter defaultCenter] removeObserver:finishObserver];
                    batchObserver = nil;
                    finishObserver = nil;
                };

                runOnMain(^{
                    // Observe batch progress (UI updates only)
                    batchObserver = [[NSNotificationCenter defaultCenter]
                        addObserverForName:EpisodeLoadingManagerDidLoadBatchNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            CDFeed *noteFeed = note.userInfo[@"feed"];
                            if (![noteFeed isEqual:subscribedFeed]) return;

                            NSInteger loaded = subscribedFeed.episodes.count;
                            float p = totalExpected > 0 ? (float)loaded / (float)totalExpected : 1.0;
                            NSString *detail = [NSString stringWithFormat:@"%ld/%ld", (long)loaded, (long)totalExpected];
                            if (cb.setFeedProgress) cb.setFeedProgress(i, p, detail);
                        }];

                    // Observe finish (signals semaphore so background thread continues)
                    finishObserver = [[NSNotificationCenter defaultCenter]
                        addObserverForName:EpisodeLoadingManagerDidFinishLoadingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            CDFeed *noteFeed = note.userInfo[@"feed"];
                            if (![noteFeed isEqual:subscribedFeed]) return;
                            dispatch_semaphore_signal(finishSem);
                        }];

                    // Resume ELM — it will load this feed's episodes batch by batch
                    elm.suspended = NO;
                });

                // Wait for feed to finish loading.
                // Poll every 0.2s to check cancel/skip. Cancel reacts within 200ms.
                BOOL feedDone = NO;
                while (!feedDone && !op.isCancelled && !ICBackupSkipCurrentFeedRequested()) {
                    long waitResult = dispatch_semaphore_wait(finishSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)));
                    if (waitResult == 0) {
                        feedDone = YES; // finish notification received
                    }
                    // On timeout (200ms), loop re-checks cancel/skip flags
                }

                // Clean up
                runOnMain(^{
                    cleanupObservers();
                    elm.suspended = YES; // Suspend again for next feed
                });

                if (!feedDone) {
                    // Cancelled or skipped while loading
                    runOnMain(^{
                        [elm cancelLoadingForFeed:subscribedFeed];
                    });
                }
            }

            if (op.isCancelled) break;

            if (ICBackupConsumeSkipCurrentFeed()) {
                runOnMain(^{
                    [elm cancelLoadingForFeed:subscribedFeed];
                    if (cb.setFeedSkipped) cb.setFeedSkipped(i);
                });
                continue;
            }

            // Mark feed complete
            runOnMain(^{
                NSInteger finalEpCount = subscribedFeed.episodes.count;
                if (cb.setFeedCompleted) cb.setFeedCompleted(i, finalEpCount);
                float progress = (float)(i + 1) / (float)MAX(feedCount, 1) * 0.98;
                if (cb.setTotalProgress) cb.setTotalProgress(progress);
            });
        }

        // ═══════════════════════════════════════════════
        // Check cancel before Phase C
        // ═══════════════════════════════════════════════

        if (op.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:totalImported wasCancelled:YES completion:completion];
            });
            return;
        }

        // ═══════════════════════════════════════════════
        // PHASE C: Import local data (metadata)
        // ═══════════════════════════════════════════════

        // Build GUID index for O(1) lookup
        [self _buildGuidIndex];
        runOnMain(^{
            if (cb.setStatusText) cb.setStatusText(@"Importing local data…".ls);
        });

        // Define metadata import blocks (they run on main thread via runOnMain)
        NSArray *metadataPhases = @[
            @[@(ICBackupImportEpisodeStatus), ^NSInteger{ return [self importEpisodeStatusFromBackup:backup]; }],
            @[@(ICBackupImportFeedSettings),  ^NSInteger{ return [self importFeedSettingsFromBackup:backup]; }],
            @[@(ICBackupImportBookmarks),     ^NSInteger{ return [self importBookmarksFromBackup:backup]; }],
            @[@(ICBackupImportUpNext),        ^NSInteger{ return [self importUpNextFromBackup:backup]; }],
            @[@(ICBackupImportNowPlaying),    ^NSInteger{ return [self importNowPlayingFromBackup:backup]; }],
            @[@(ICBackupImportPlaylists),     ^NSInteger{
                NSInteger c = [self importPlaylistsFromBackup:backup];
                c += [self importEpisodeListsFromBackup:backup];
                return c;
            }],
            @[@(ICBackupImportSettings),      ^NSInteger{ return [self importSettingsFromBackup:backup]; }],
            @[@(ICBackupImportSortOrder),     ^NSInteger{ return [self importSortOrderFromBackup:backup]; }],
            @[@(ICBackupImportAppleWatch),    ^NSInteger{ return [self importAppleWatchEpisodesFromBackup:backup]; }],
            @[@(ICBackupImportDownloads),     ^NSInteger{ return [self importDownloadsFromBackup:backup]; }],
        ];

        // Count enabled phases for progress calculation
        NSInteger enabledMetadataCount = 0;
        for (NSArray *phase in metadataPhases) {
            ICBackupImportCategory cat = [phase[0] unsignedIntegerValue];
            if (categories & cat) enabledMetadataCount++;
        }

        NSInteger metadataTotal = metadataPhases.count;
        NSInteger enabledIndex = 0;
        for (NSInteger mi = 0; mi < metadataTotal; mi++) {
            if (op.isCancelled) break;

            NSArray *phase = metadataPhases[mi];
            ICBackupImportCategory cat = [phase[0] unsignedIntegerValue];
            NSInteger (^importBlock)(void) = phase[1];

            if (!(categories & cat)) continue;

            runOnMain(^{
                if (cb.setMetadataActive) cb.setMetadataActive(cat);
            });

            __block NSInteger count = 0;

            // Episode status import can be very large (thousands of episodes per feed).
            // Run it feed-by-feed with progress updates between feeds so the UI stays responsive.
            if (cat == ICBackupImportEpisodeStatus) {
                NSInteger podcastTotal = backup.podcasts.count;
                for (NSInteger pi = 0; pi < podcastTotal; pi++) {
                    if (op.isCancelled) break;

                    NSInteger podcastIndex = pi;
                    NSInteger feedCount = [self _importEpisodeStatusForPodcastAtIndex:podcastIndex fromBackup:backup];
                    count += feedCount;

                    // Update progress per feed within the episode status phase
                    float phaseStart = 0.98 + (0.02 * ((float)enabledIndex / (float)MAX(enabledMetadataCount, 1)));
                    float phaseEnd   = 0.98 + (0.02 * ((float)(enabledIndex + 1) / (float)MAX(enabledMetadataCount, 1)));
                    float feedProgress = phaseStart + (phaseEnd - phaseStart) * ((float)(pi + 1) / (float)MAX(podcastTotal, 1));
                    runOnMain(^{
                        if (cb.setTotalProgress) cb.setTotalProgress(feedProgress);
                    });
                }
            } else {
                runOnMain(^{
                    count = importBlock();
                });
            }

            runOnMain(^{
                NSString *detail;
                if (cat == ICBackupImportNowPlaying) {
                    detail = count > 0 ? @"1" : @"—";
                } else if (cat == ICBackupImportSortOrder) {
                    detail = count > 0 ? @"✓" : @"—";
                } else {
                    detail = [NSString stringWithFormat:@"%ld", (long)count];
                }
                if (cb.setMetadataCompleted) cb.setMetadataCompleted(cat, detail);
            });

            totalImported += count;

            // Update total progress (metadata uses 98–100%)
            float metaProgress = 0.98 + (0.02 * ((float)(enabledIndex + 1) / (float)MAX(enabledMetadataCount, 1)));
            runOnMain(^{
                if (cb.setTotalProgress) cb.setTotalProgress(metaProgress);
            });

            enabledIndex++;
        }

        if (op.isCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _finalize:backup categories:categories totalImported:totalImported wasCancelled:YES completion:completion];
            });
            return;
        }

        // ═══════════════════════════════════════════════
        // PHASE D: Downloads + Now Playing
        // ═══════════════════════════════════════════════

        runOnMain(^{
            if (cb.setStatusText) cb.setStatusText(@"Finalizing…".ls);
            [self processPendingNowPlaying];
            [self processPendingDownloads];
        });

        // ═══════════════════════════════════════════════
        // FINALIZE
        // ═══════════════════════════════════════════════

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _finalize:backup categories:categories totalImported:totalImported wasCancelled:NO completion:completion];
        });
    }];

    [_importQueue addOperation:operation];
}

#pragma mark - Finalize

+ (void)_finalize:(InstacastBackupData *)backup
       categories:(ICBackupImportCategory)categories
    totalImported:(NSInteger)totalImported
     wasCancelled:(BOOL)wasCancelled
       completion:(void(^)(NSInteger importedCount, NSError *error))completion
{
    [DMANAGER save];

    // Resume ELM — all feeds should be fully loaded already, but just in case
    [EpisodeLoadingManager sharedManager].suspended = NO;

    if (categories & ICBackupImportSettings) {
        [[ICAppearanceManager sharedManager] updateAppearance];
        [[WidgetDataExporter sharedExporter] exportSettingsSnapshot];
        [WidgetKitHelper reloadAllTimelines];
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
    _feedURLMapping = nil;
    _currentOperation = nil;

    if (completion) {
        NSError *error = wasCancelled
            ? [NSError errorWithDomain:@"InstacastBackupImporter" code:1
                              userInfo:@{NSLocalizedDescriptionKey: @"Import was cancelled.".ls}]
            : nil;
        completion(totalImported, error);
    }
}

#pragma mark - GUID Index Cache

// Maps backup feedURL → normalized feed sourceURL (handles redirects, trailing slashes)
static NSMutableDictionary<NSString *, NSString *> *_feedURLMapping = nil;

+ (void)_buildGuidIndex {
    _guidIndexByFeedURL = [NSMutableDictionary dictionary];
    _feedURLMapping = [NSMutableDictionary dictionary];

    NSManagedObjectContext *context = [DMANAGER newBackgroundContext];
    [context performBlockAndWait:^{
        NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        request.includesSubentities = NO;
        request.predicate = [NSPredicate predicateWithFormat:@"guid != nil AND feed.sourceURL_ != nil"];
        request.fetchBatchSize = 500;
        NSArray *episodes = [context executeFetchRequest:request error:nil];

        for (CDEpisode *ep in episodes) {
            NSString *feedURL = [ep.feed.sourceURL absoluteString];
            if (feedURL.length == 0 || ep.guid.length == 0) continue;

            NSMutableDictionary *index = _guidIndexByFeedURL[feedURL];
            if (!index) {
                index = [NSMutableDictionary dictionary];
                _guidIndexByFeedURL[feedURL] = index;
            }
            index[ep.guid] = ep.objectID;
        }
    }];
}

/// Map a backup feedURL to the actual feed sourceURL stored in Core Data.
/// Handles URL normalization, redirects, HTTP→HTTPS differences, trailing slashes.
+ (NSString *)_resolvedFeedURLForBackupURL:(NSString *)backupURL {
    if (!backupURL) return nil;

    // Check cache first
    NSString *cached = _feedURLMapping[backupURL];
    if (cached) return cached;

    // Direct match
    if (_guidIndexByFeedURL[backupURL]) {
        _feedURLMapping[backupURL] = backupURL;
        return backupURL;
    }

    // Try without trailing slash
    NSString *normalized = backupURL;
    if ([normalized hasSuffix:@"/"]) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }
    if (_guidIndexByFeedURL[normalized]) {
        _feedURLMapping[backupURL] = normalized;
        return normalized;
    }

    // Try HTTP ↔ HTTPS
    if ([normalized hasPrefix:@"http://"]) {
        NSString *httpsURL = [@"https://" stringByAppendingString:[normalized substringFromIndex:7]];
        if (_guidIndexByFeedURL[httpsURL]) {
            _feedURLMapping[backupURL] = httpsURL;
            return httpsURL;
        }
    } else if ([normalized hasPrefix:@"https://"]) {
        NSString *httpURL = [@"http://" stringByAppendingString:[normalized substringFromIndex:8]];
        if (_guidIndexByFeedURL[httpURL]) {
            _feedURLMapping[backupURL] = httpURL;
            return httpURL;
        }
    }

    // Fallback: find feed via DatabaseManager (handles all normalization)
    NSURL *url = [NSURL URLWithString:backupURL];
    CDFeed *feed = url ? [DMANAGER feedWithSourceURL:url] : nil;
    if (feed && feed.sourceURL) {
        NSString *resolvedKey = [feed.sourceURL absoluteString];
        _feedURLMapping[backupURL] = resolvedKey;
        return resolvedKey;
    }

    return nil;
}

#pragma mark - Episode Status

/// Import episode status for a single podcast (called per-feed for responsive UI).
+ (NSInteger)_importEpisodeStatusForPodcastAtIndex:(NSInteger)index fromBackup:(InstacastBackupData *)backup {
    if (index < 0 || index >= (NSInteger)backup.podcasts.count) return 0;

    ICBackupPodcast *podcast = backup.podcasts[index];
    if (!podcast.feedURL) return 0;
    NSString *resolvedFeedURL = [self _resolvedFeedURLForBackupURL:podcast.feedURL];
    if (!resolvedFeedURL) return 0;

    // Build backup episode lookup by GUID
    NSMutableDictionary<NSString *, ICBackupEpisode *> *backupEpisodesByGuid = [NSMutableDictionary dictionaryWithCapacity:podcast.episodes.count];
    for (ICBackupEpisode *backupEp in podcast.episodes) {
        if (backupEp.guid) {
            backupEpisodesByGuid[backupEp.guid] = backupEp;
        }
    }

    __block NSInteger count = 0;
    NSManagedObjectContext *context = [DMANAGER newBackgroundContext];
    [context performBlockAndWait:^{
        NSFetchRequest *feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
        feedRequest.predicate = [NSPredicate predicateWithFormat:@"sourceURL_ == %@", resolvedFeedURL];
        feedRequest.fetchLimit = 1;
        CDFeed *feed = [[context executeFetchRequest:feedRequest error:nil] firstObject];
        if (!feed) return;

        for (CDEpisode *episode in feed.episodes) {
            if (!episode.guid) continue;

            ICBackupEpisode *backupEp = backupEpisodesByGuid[episode.guid];

            if (backupEp) {
                BOOL shouldBeConsumed = backupEp.played;
                if (shouldBeConsumed != episode.consumed) {
                    episode.consumed = shouldBeConsumed;
                    count++;
                }

                if (backupEp.starred != episode.starred) {
                    episode.starred = backupEp.starred;
                    count++;
                }

                if (backupEp.archived && !episode.archived) {
                    episode.archived = YES;
                    count++;
                }

                if (backupEp.position > 0 && backupEp.position != episode.position) {
                    episode.position = backupEp.position;
                    count++;
                }

                if (backupEp.duration > 0 && episode.duration == 0) {
                    episode.duration = backupEp.duration;
                    count++;
                }
            } else {
                if (episode.consumed) {
                    episode.consumed = NO;
                    count++;
                }
            }
        }

        if (context.hasChanges) {
            [context save:nil];
        }
    }];

    return count;
}

+ (NSInteger)importEpisodeStatusFromBackup:(InstacastBackupData *)backup {
    NSInteger count = 0;
    for (NSInteger i = 0; i < (NSInteger)backup.podcasts.count; i++) {
        count += [self _importEpisodeStatusForPodcastAtIndex:i fromBackup:backup];
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
        return 1;
    }

    if (np.position > 0) {
        episode.position = np.position;
    }

    if (episode.preferedMedium.fileURL) {
        [[AudioSession sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:(NSTimeInterval)np.position autostart:NO];
    } else {
        [USER_DEFAULTS setObject:@{
            @"guid": np.guid ?: @"",
            @"feedURL": np.feedURL ?: @"",
            @"position": @(np.position)
        } forKey:kPendingNowPlayingKey];
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

    [[AudioSession sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:(NSTimeInterval)position autostart:NO];
}

#pragma mark - Apple Watch Episodes

+ (CDEpisode *)_episodeForAppleWatchBackupEpisode:(ICBackupAppleWatchEpisode *)backupEpisode {
    if (backupEpisode.episodeHash.length > 0) {
        CDEpisode *episode = [DMANAGER episodeWithObjectHash:backupEpisode.episodeHash];
        if (episode) return episode;
    }

    return [self findEpisodeWithGuid:backupEpisode.guid feedURL:backupEpisode.feedURL];
}

+ (NSString *)_feedIdentifierForWatchEpisode:(CDEpisode *)episode backupValue:(NSString *)backupValue {
    if (backupValue.length > 0) return backupValue;

    NSString *sourceURL = [episode.feed.sourceURL absoluteString];
    if (sourceURL.length > 0) return sourceURL;

    return episode.feed.uid ?: @"";
}

+ (NSString *)_validAppleWatchSelectionSource:(NSString *)selectionSource {
    if ([selectionSource isEqualToString:ICAppleWatchSelectionSourceManual] ||
        [selectionSource isEqualToString:ICAppleWatchSelectionSourceLatestRule]) {
        return selectionSource;
    }
    return ICAppleWatchSelectionSourceManual;
}

+ (NSInteger)importAppleWatchEpisodesFromBackup:(InstacastBackupData *)backup {
    AppleWatchSyncManager *watchManager = [AppleWatchSyncManager sharedManager];
    NSMutableSet<NSString *> *importedHashes = [NSMutableSet set];
    NSInteger count = 0;

    for (ICBackupAppleWatchEpisode *backupEpisode in backup.appleWatchEpisodes) {
        CDEpisode *episode = [self _episodeForAppleWatchBackupEpisode:backupEpisode];
        if (![watchManager canSendEpisodeToWatch:episode]) continue;

        NSString *episodeHash = episode.objectHash ?: backupEpisode.episodeHash;
        if (episodeHash.length == 0 || [importedHashes containsObject:episodeHash]) continue;
        [importedHashes addObject:episodeHash];

        AppleWatchEpisodeState *state = [watchManager stateForEpisodeHash:episodeHash];
        if (!state) {
            state = [NSEntityDescription insertNewObjectForEntityForName:@"AppleWatchEpisodeState" inManagedObjectContext:DMANAGER.objectContext];
            state.episodeHash = episodeHash;
        }

        BOOL keepLocalDownloadStatus = [state.watchStatus isEqualToString:ICAppleWatchStatusDownloaded] ||
                                       [state.watchStatus isEqualToString:ICAppleWatchStatusDownloading];

        state.feedIdentifier = [self _feedIdentifierForWatchEpisode:episode backupValue:backupEpisode.feedIdentifier];
        state.selectionSource = [self _validAppleWatchSelectionSource:backupEpisode.selectionSource];
        state.watchAddedDate = backupEpisode.watchAddedDate ?: state.watchAddedDate ?: [NSDate date];
        state.lastPhonePosition = backupEpisode.lastPhonePosition;
        state.lastPhonePositionDate = backupEpisode.lastPhonePositionDate;
        state.lastWatchPosition = backupEpisode.lastWatchPosition;
        state.lastWatchPositionDate = backupEpisode.lastWatchPositionDate;
        state.watchConsumed = backupEpisode.watchConsumed;
        state.watchConsumedDate = backupEpisode.watchConsumedDate;
        state.watchLastError = nil;

        if (!keepLocalDownloadStatus) {
            state.watchStatus = ICAppleWatchStatusSelected;
            state.watchDownloadedDate = nil;
            state.watchLastSeenDate = nil;
            state.watchActualDuration = 0;
            state.watchActualFileSize = 0;
        }

        count++;
    }

    if (count > 0) {
        [DMANAGER save];
        [watchManager syncCurrentSelectionsNow];
    }

    return count;
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
        @"defaultSleepTimer":       DefaultIntelligentSleepTimer,
        @"appearanceMode":          kDefaultAppearanceMode,
        @"sleepTimerAlways":        ScreenTimerAlwaysActive,
        @"disableSleepTimerCarPlay": DisableSleepTimerInCarPlay,
        @"lastSleepTimer":          LastSelectedSleepTimer,
        @"playerControls":          kDefaultPlayerControls,
        @"autoDeleteMarkedPlayed":  AutoDeleteAfterMarkedAsPlayed,
        @"autoDeleteNews":          AutoDeleteNewsMode,
        @"podcastRefreshOnAppStart": PodcastRefreshOnAppStart,
        @"enableCachingOver3G":     EnableCachingOver3G,
        @"enableRefreshingOver3G":  EnableRefreshingOver3G,
        @"enableStreamingOver3G":   EnableStreamingOver3G,
        @"uiSoundEnabled":          UISoundEnabled,
        @"uiHapticsEnabled":        UIHapticsEnabled,
        @"showBadge":               ShowApplicationBadgeForUnseen,
        @"dontDeleteUpNext":        kDefaultDontDeleteUpNextWhenChangingEpisode,
        @"showUnavailable":         kDefaultShowUnavailableEpisodes,
        @"themeDefaultActive":      InterfaceThemeDefaultActive,
        @"themeColorHex":           InterfaceThemeColorHexCode,
        @"playerPerPodcastColor":   PlayerColorPerPodcastActive,
        @"playerColorHex":          PlayerThemeColorHexCode,
        @"widgetThemeDefaultActive": WidgetThemeDefaultActive,
        @"widgetColorHex":          WidgetThemeColorHexCode,
        @"transcriptHighlightStyle": kDefaultTranscriptHighlightStyle,
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
        @"allowDiagnostics":        AllowSendingDiagnostics,
        @"amazonAffiliateEnabled":  AmazonAffiliateEnabled,
        @"notifyNewEpisode":        EnableNewEpisodeNotification,
        @"notifyRefreshFinished":   EnableManualRefreshFinishedNotification,
        @"notifyDownloadFinished":  EnableManualDownloadFinishedNotification,
        @"intelligentSleepAlways":  IntelligentSleepTimerAlwaysActive,
        @"feedSortOrder":           FeedSortOrder,
        @"selectedAppLanguage":     SelectedAppLanguage,
        @"episodeSwipeRightAction": EpisodeSwipeRightAction,
        @"episodeSwipeLeftAction":  EpisodeSwipeLeftAction,
        @"appleWatchSendLatestCount": AppleWatchSendLatestCount,
        @"appleWatchOnlyUnplayed":  AppleWatchOnlyUnplayed,
        @"iCloudSyncEpisodes":      ICiCloudSyncEpisodesEnabled,
        @"iCloudSyncSubscriptions": ICiCloudSyncSubscriptionsEnabled,
        @"iCloudSyncSettings":      ICiCloudSyncSettingsEnabled,
        @"darkModePureBlack":       kDefaultDarkModePureBlack,
        @"fontSizeLarger":          kDefaultFontSizeLarger,
        @"tapOnEpisodeAction":      TapOnEpisodeAction,
        @"mediaFilesSortMode":      @"MediaFilesSortMode",
        @"transcriptionEngine":     kTranscriptionEngine,
        @"transcriptionWhisperModel": kTranscriptionWhisperModel,
        @"chapterGenerationModel":  @"ChapterGenerationModel",
        @"transcriptionAutoDefault": kTranscriptionAutoDefault,
        @"chapterAutoDefault":      kChapterAutoDefault,
        @"autoSkipSponsors":        kAutoSkipSponsors,
        @"transcriptionEverActivated": kTranscriptionEverActivated,
        @"transcriptionFirstRunShown": kTranscriptionFirstRunShown,
        @"transcriptVisiblePreference": @"TranscriptVisiblePreference",
    };

    NSSet *boolKeys = [NSSet setWithArray:@[
        @"autoCacheAudio", @"autoCacheVideo", @"autoDeletePlayed", @"disableAutoLock",
        @"sleepTimerAlways", @"disableSleepTimerCarPlay", @"autoDeleteMarkedPlayed", @"autoDeleteNews",
        @"podcastRefreshOnAppStart",
        @"enableCachingOver3G", @"enableRefreshingOver3G", @"enableStreamingOver3G",
        @"uiSoundEnabled", @"uiHapticsEnabled", @"showBadge", @"dontDeleteUpNext", @"showUnavailable",
        @"themeDefaultActive", @"playerPerPodcastColor", @"widgetThemeDefaultActive",
        @"smarthomeMQTTEnabled", @"smarthomeAllowControl", @"smarthomeWiFiOnly",
        @"deviceMovementIntelligentSleep", @"screenTouchIntelligentSleep", @"volumeChangeIntelligentSleep",
        @"continuousPlay", @"autoDownloadWhileStreaming", @"enableCachingImagesOver3G",
        @"openLinksExternal", @"notifyNewEpisode", @"notifyRefreshFinished", @"notifyDownloadFinished",
        @"intelligentSleepAlways", @"darkModePureBlack", @"amazonAffiliateEnabled",
        @"appleWatchOnlyUnplayed", @"transcriptionAutoDefault", @"chapterAutoDefault",
        @"autoSkipSponsors", @"transcriptionEverActivated", @"transcriptionFirstRunShown",
        @"transcriptVisiblePreference", @"iCloudSyncEpisodes", @"iCloudSyncSubscriptions",
        @"iCloudSyncSettings",
    ]];

    NSSet *doubleKeys = [NSSet setWithArray:@[@"deviceMovementSensitivity"]];

    NSSet *stringKeys = [NSSet setWithArray:@[@"themeColorHex", @"playerColorHex", @"widgetColorHex",
        @"smarthomeMQTTHost", @"smarthomeMQTTUsername", @"smarthomeMQTTPassword", @"smarthomeDeviceName",
        @"feedSortOrder", @"selectedAppLanguage", @"transcriptionEngine", @"transcriptionWhisperModel",
        @"chapterGenerationModel"]];

    NSInteger count = 0;
    NSUserDefaults *defaults = USER_DEFAULTS;

    for (NSString *xmlKey in backup.settings.values) {
        NSString *defaultsKey = settingsMap[xmlKey];
        if (!defaultsKey) continue;

        NSString *value = backup.settings.values[xmlKey];
        if (!value || value.length == 0) continue;

        if ([xmlKey isEqualToString:@"themeColorHex"]) {
            ICBackupApplyColorHex(defaults, value, InterfaceThemeColorHexCode, InterfaceThemeColorCode);
        } else if ([xmlKey isEqualToString:@"playerColorHex"]) {
            ICBackupApplyColorHex(defaults, value, PlayerThemeColorHexCode, PlayerThemeColorCode);
        } else if ([xmlKey isEqualToString:@"widgetColorHex"]) {
            ICBackupApplyColorHex(defaults, value, WidgetThemeColorHexCode, WidgetThemeColorCode);
        } else if ([boolKeys containsObject:xmlKey]) {
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

    NSArray *credentialKeys = @[@"openAIAPIKey", @"anthropicAPIKey", @"kimiAPIKey", @"openAIOAuthAccessToken", @"openAIOAuthRefreshToken", @"openAIOAuthIDToken", @"openAIOAuthAccountID", @"openAIOAuthAccountEmail", @"openAIOAuthFedRAMP"];
    NSMutableDictionary *credentialValues = [NSMutableDictionary dictionary];
    for (NSString *key in credentialKeys) {
        NSString *value = backup.settings.values[key];
        if ([value isKindOfClass:[NSString class]] && value.length > 0) {
            credentialValues[key] = value;
        }
    }
    if (credentialValues.count > 0) {
        [ICRemoteChapterCredentialStore restoreBackupCredentialValues:credentialValues];
        count += credentialValues.count;
    }

    if (backup.settings.mainMenuListUIDs.count > 0) {
        [defaults setObject:backup.settings.mainMenuListUIDs forKey:@"MainMenuListUIDs"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MainMenuListUIDsDidChangeNotification" object:nil];
        count++;
    }

    if (backup.settings.enabledPlaybackSpeeds.count > 0) {
        [defaults setObject:backup.settings.enabledPlaybackSpeeds forKey:EnabledPlaybackSpeedsKey];
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
    }

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

}

#pragma mark - Helper

+ (CDEpisode *)findEpisodeWithGuid:(NSString *)guid feedURL:(NSString *)feedURLString {
    if (!guid || !feedURLString) return nil;

    // Try GUID index first (O(1)) — resolve backup URL to actual feed URL
    if (_guidIndexByFeedURL) {
        NSString *resolvedURL = [self _resolvedFeedURLForBackupURL:feedURLString];
        if (resolvedURL) {
            NSDictionary *index = _guidIndexByFeedURL[resolvedURL];
            NSManagedObjectID *episodeID = index[guid];
            if (episodeID) {
                return (CDEpisode *)[DMANAGER.objectContext existingObjectWithID:episodeID error:nil];
            }
        }
    }

    // Fallback: linear search via DatabaseManager (handles normalization)
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
