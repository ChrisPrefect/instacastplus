//
//  WidgetDataExporter.m
//  Instacast
//

#import "WidgetDataExporter.h"
#import "DatabaseManager.h"
#import "PlaybackManager.h"
#import "PlaybackDefines.h"
#import "PlayerSpeedButton.h"
#import "Defines.h"
#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"
#import "CacheManager.h"
#import "CDFeed.h"
#import "CDEpisode.h"
#import "CDChapter.h"
#import "CDList.h"
#import "CDSmartPlaylist.h"
#import "CDEpisodeList.h"
#import "CDPlaylist.h"
#import "ImageCacheManager.h"
#import "ICMetadata.h"
#import <UIKit/UIKit.h>

#import "InstacastPlus-Swift.h"

// App Group and file constants (must match SharedConstants.swift)
static NSString* const kAppGroupID           = @"group.com.iteconomy.instacastplus";
static NSString* const kNowPlayingFile       = @"widget_nowplaying.json";
static NSString* const kListsIndexFile       = @"widget_lists.json";
static NSString* const kListEpisodesPrefix   = @"widget_list_";
static NSString* const kStatsFile            = @"widget_stats.json";
static NSString* const kSettingsFile          = @"widget_settings.json";
static NSString* const kListeningLogFile     = @"widget_listening_log.plist";
static NSString* const kImagesFolder         = @"WidgetImages";
static NSString* const kPendingActionFile    = @"widget_pending_action.json";

// Image sizes for widgets
static const NSInteger kImageSizeMedium = 120;

// Max episodes per list snapshot
static const NSInteger kMaxEpisodesPerList = 14;
static const NSTimeInterval kNowPlayingExportThrottleInterval = 0.75;
static const NSTimeInterval kControlActionExportDelay = 0.35;

@interface WidgetDataExporter ()
@property (nonatomic, strong) NSURL *containerURL;
@property (nonatomic, strong) NSURL *imagesURL;

// Debounced now-playing export. Uses GCD instead of NSTimer so it still fires while audio keeps the app alive in background.
@property (nonatomic, copy) dispatch_block_t pendingNowPlayingExportBlock;
@property (nonatomic, copy) dispatch_block_t pendingControlActionExportBlock;
@property (nonatomic, strong) NSTimer *listsDebounceTimer;
@property (nonatomic, strong) NSTimer *reloadTimelineTimer;

// Listening time tracking
@property (nonatomic, strong) NSDate *lastListeningTimestamp;

// Cached stats values so widget exports stay cheap on the main thread.
@property (nonatomic) NSInteger cachedNewEpisodesTodayCount;
@property (nonatomic) double cachedListenedTodaySec;
@property (nonatomic) double cachedListenedWeekSec;
@property (nonatomic) NSInteger cachedDownloadedCount;
@property (nonatomic) unsigned long long cachedDownloadedSizeBytes;
@property (nonatomic) NSInteger cachedSubscribedCount;
@property (nonatomic) NSInteger cachedUnplayedCount;
@property (nonatomic, copy) NSString *cachedStatsDayKey;
@property (nonatomic, strong) dispatch_queue_t statsRefreshQueue;
@property (nonatomic, strong) dispatch_queue_t listsExportQueue;
@property (nonatomic) BOOL statsRefreshInProgress;
@property (nonatomic, strong) NSDate *lastPlaybackStatsRefreshDate;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingImageFetchKeys;

// Heavy widget exports (per-list Core Data scans) deferred because they were requested
// while the app was kept alive in the background by audio playback — running them there
// burns sustained CPU and the system kills the app (cpu_resource_fatal). Flushed on the
// next foreground. See _deferHeavyListsExportInBackgroundPlayback.
@property (nonatomic) BOOL pendingListsExport;
@property (nonatomic) BOOL pendingStatsRefresh;

// Coalescing: a feed refresh posts several export triggers in a row. Run at most one heavy
// lists pass at a time and collapse the burst into a single trailing rerun (main-thread only).
@property (nonatomic) BOOL listsExportRunning;
@property (nonatomic) BOOL listsExportQueuedAgain;

// Cache last played episode so widget can show it after playback ends
@property (nonatomic, strong) NSDictionary *lastPlayedEpisodeDict;
@property (nonatomic, strong) NSDictionary *lastPlayedExtraFields;

// Track the structural now-playing state that warrants a timeline reload.
@property (nonatomic, copy) NSString *lastNowPlayingReloadSignature;

- (void)_persistLastPlayedCache;
- (void)_restoreLastPlayedCache;
- (void)_removeLegacyUpNextFiles;
- (void)_restoreStatsCacheFromDisk;
- (void)_refreshStatsCacheInBackgroundWritingSnapshot:(BOOL)writeSnapshot reloadWhenDone:(BOOL)reloadWhenDone;
- (void)_updateStatsDayIfNeededForDate:(NSDate *)date;
- (void)_updateStatsCacheForAddedEpisodes:(NSArray<CDEpisode *> *)episodes;
- (NSDate *)_dateFromISOString:(NSString *)string;
- (BOOL)_appendListeningDeltaSinceLastTimestampAtDate:(NSDate *)date;
- (void)_refreshStatsDuringPlaybackIfNeeded;
- (void)_scheduleDebouncedNowPlayingExport;
- (void)_scheduleControlActionNowPlayingExport;
- (void)_consumePendingWidgetActionIfNeeded;
- (void)_clearPendingWidgetActionFile;
- (void)_handleWidgetAction:(NSString *)action chapterIndex:(NSNumber *)chapterIndex;
- (NSString *)_currentNowPlayingReloadSignature;
- (NSInteger)_resolvedLiveChapterIndexForChapters:(NSArray<ICMetadataChapter *> *)liveChapters fallbackIndex:(NSInteger)fallbackIndex currentPosition:(NSInteger)currentPosition;
- (BOOL)_hasNextEpisodeForPlaybackManager:(PlaybackManager *)pm audioSession:(AudioSession *)as;
- (BOOL)_hasPreviousEpisodeForPlaybackManager:(PlaybackManager *)pm audioSession:(AudioSession *)as;
- (CDEpisode *)_previousEpisodeForPlaybackManager:(PlaybackManager *)pm audioSession:(AudioSession *)as;
- (NSURL *)_cachedImageSourceURLForURL:(NSURL *)imageURL requestedSize:(NSInteger)size;
- (NSArray<NSNumber *> *)_candidateSourceImageSizesForRequestedSize:(NSInteger)size;
- (void)_prefetchImageForWidgetIfNeeded:(NSURL *)imageURL size:(NSInteger)size;
@end

@implementation WidgetDataExporter

+ (instancetype)sharedExporter {
    // iOS widgets don't work on macOS ("Designed for iPad").
    // Skip entirely to avoid App Group container access triggering TCC dialog.
    if (NSProcessInfo.processInfo.isiOSAppOnMac) return nil;

    static WidgetDataExporter *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[WidgetDataExporter alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:kAppGroupID];
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _statsRefreshQueue = dispatch_queue_create("com.instacastplus.widget-stats", queueAttributes);
        _listsExportQueue = dispatch_queue_create("com.instacastplus.widget-lists", queueAttributes);
        _cachedStatsDayKey = [self _dateKeyForDate:[NSDate date]];
        _pendingImageFetchKeys = [NSMutableSet set];
        if (_containerURL) {
            _imagesURL = [_containerURL URLByAppendingPathComponent:kImagesFolder];
            [[NSFileManager defaultManager] createDirectoryAtURL:_imagesURL withIntermediateDirectories:YES attributes:nil error:nil];
            // Restore persisted last-played cache so widget shows last episode after app restart
            [self _restoreLastPlayedCache];
            [self _removeLegacyUpNextFiles];
            [self _restoreStatsCacheFromDisk];
        } else {
            DebugLog(@"WidgetDataExporter init: WARNING — App Group container is nil! Widgets will not receive data.");
        }
    }
    return self;
}

#pragma mark - Observation

- (void)startObserving {
    if (!self.containerURL) {
        ErrLog(@"WidgetDataExporter: App Group container not available");
        return;
    }

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // Playback events
    [nc addObserver:self selector:@selector(_playbackDidStart:) name:PlaybackManagerDidStartNotification object:nil];
    [nc addObserver:self selector:@selector(_playbackDidEnd:) name:PlaybackManagerDidEndNotification object:nil];
    [nc addObserver:self selector:@selector(_playbackDidChangeEpisode:) name:PlaybackManagerDidChangeEpisodeNotification object:nil];
    [nc addObserver:self selector:@selector(_playbackDidUpdate:) name:PlaybackManagerDidUpdateNotification object:nil];
    [nc addObserver:self selector:@selector(_episodeDidFinish:) name:PlaybackManagerEpisodeDidFinishNotification object:nil];

    // Subscription events
    [nc addObserver:self selector:@selector(_feedsDidRefresh:) name:SubscriptionManagerDidFinishRefreshingFeedsNotification object:nil];
    [nc addObserver:self selector:@selector(_episodesAdded:) name:SubscriptionManagerDidAddEpisodesNotification object:nil];

    // Cache events
    [nc addObserver:self selector:@selector(_cacheDidFinish:) name:CacheManagerDidFinishCachingEpisodeNotification object:nil];
    [nc addObserver:self selector:@selector(_cacheDidClear:) name:CacheManagerDidClearCacheNotification object:nil];
    [[CacheManager sharedCacheManager] addObserver:self forKeyPath:@"numberOfDownloadedBytes" options:0 context:NULL];

    // Playlist events
    [nc addObserver:self selector:@selector(_playlistDidChange:) name:CDPlaylistDidChangeEpisodesNotification object:nil];
    AudioSession *audioSession = [AudioSession sharedAudioSession];
    [audioSession addTaskObserver:self forKeyPath:@"playlist" task:^(__unused id obj, __unused NSDictionary *change) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self exportNowPlayingSnapshot];
            [WidgetKitHelper reloadNowPlayingTimeline];
        });
    }];

    // Sleep timer
    [nc addObserver:self selector:@selector(_sleepTimerExpired:) name:AudioSessionSleepTimerDidExpireNotification object:nil];

    // Core Data changes (for smart playlist updates)
    [nc addObserver:self selector:@selector(_coreDataDidChange:) name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];

    // Widget control actions (from Darwin notifications via WidgetKitHelper)
    [nc addObserver:self selector:@selector(_widgetControlAction:) name:@"WidgetControlActionNotification" object:nil];
    [nc addObserver:self selector:@selector(_consumePendingWidgetActionNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(_consumePendingWidgetActionNotification:) name:UIApplicationWillEnterForegroundNotification object:nil];

    // Catch up on heavy exports that were deferred during background playback.
    [nc addObserver:self selector:@selector(_flushDeferredExportsOnForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(_flushDeferredExportsOnForeground:) name:UIApplicationDidBecomeActiveNotification object:nil];

    // Initial export so widget config has data immediately
    // (exportAllSnapshots is also called in sceneDidEnterBackground)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _consumePendingWidgetActionIfNeeded];
        [self exportListsSnapshot];
        [self exportSettingsSnapshot];
        [self exportNowPlayingSnapshot];
        [self exportStatsSnapshot];
        [WidgetKitHelper reloadAllTimelines];
        [self _refreshStatsCacheInBackgroundWritingSnapshot:YES reloadWhenDone:NO];
    });
}

- (void)dealloc {
    [[CacheManager sharedCacheManager] removeObserver:self forKeyPath:@"numberOfDownloadedBytes"];
    [[AudioSession sharedAudioSession] removeTaskObserver:self forKeyPath:@"playlist"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_pendingNowPlayingExportBlock) {
        dispatch_block_cancel(_pendingNowPlayingExportBlock);
    }
    if (_pendingControlActionExportBlock) {
        dispatch_block_cancel(_pendingControlActionExportBlock);
    }
    [_listsDebounceTimer invalidate];
    [_reloadTimelineTimer invalidate];
}

#pragma mark - Notification Handlers
//
// All handlers dispatch to main thread because:
// 1. NSTimer MUST be created on the main thread's run loop
// 2. DMANAGER.objectContext is NSMainQueueConcurrencyType — Core Data access only on main thread
// 3. Some notifications may fire from background threads (e.g., AVPlayer observers, parser callbacks)
//

- (void)_playbackDidStart:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [WidgetKitHelper reloadNowPlayingTimeline];
    });
}

- (void)_playbackDidEnd:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _appendListeningDeltaSinceLastTimestampAtDate:[NSDate date]];
        self.lastListeningTimestamp = nil;
        self.lastPlaybackStatsRefreshDate = nil;
        [self exportNowPlayingSnapshot];
        [self exportStatsSnapshot];
        [self _persistLastPlayedCache];
        [WidgetKitHelper reloadNowPlayingTimeline];
    });
}

- (void)_playbackDidChangeEpisode:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [WidgetKitHelper reloadNowPlayingTimeline];
    });
}

- (void)_playbackDidUpdate:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _scheduleDebouncedNowPlayingExport];
        // Track listening time (every 10 seconds)
        [self _trackListeningTime];
        [self _refreshStatsDuringPlaybackIfNeeded];
    });
}

- (void)_episodeDidFinish:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [WidgetKitHelper reloadNowPlayingTimeline];
        [WidgetKitHelper reloadListsTimeline];
        [WidgetKitHelper reloadStatsTimeline];
    });
}

- (void)_feedsDidRefresh:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportListsSnapshot];
        [WidgetKitHelper reloadListsTimeline];
    });
}

- (void)_episodesAdded:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<CDEpisode *> *episodes = note.userInfo[@"episodes"];
        [self _updateStatsCacheForAddedEpisodes:episodes];
        [self exportStatsSnapshot];
        [self _debouncedListsExport];
        [WidgetKitHelper reloadListsTimeline];
        [WidgetKitHelper reloadStatsTimeline];
    });
}

- (void)_cacheDidFinish:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [WidgetKitHelper reloadListsTimeline];
        [WidgetKitHelper reloadStatsTimeline];
    });
}

- (void)_cacheDidClear:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [WidgetKitHelper reloadListsTimeline];
        [WidgetKitHelper reloadStatsTimeline];
    });
}

- (void)_playlistDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportListsSnapshot];
        [WidgetKitHelper reloadListsTimeline];
    });
}

- (void)_sleepTimerExpired:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [WidgetKitHelper reloadNowPlayingTimeline];
    });
}

- (void)_coreDataDidChange:(NSNotification *)note {
    // A routine ~30s playback-position save is a Core Data change too — but it must NOT kick
    // off the heavy lists export. Only react when something that actually affects list
    // membership/counts changed. Inspect the change set SYNCHRONOUSLY here; in the async
    // block below changedValuesForCurrentEvent is already empty. (Same approach as
    // ICiCloudSyncManager's change filter.)
    if (![self _coreDataChangeAffectsLists:note]) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Debounce: 3 seconds, fires frequently
        [self.listsDebounceTimer invalidate];
        self.listsDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                  target:self
                                                                selector:@selector(_debouncedListsReload)
                                                                userInfo:nil
                                                                 repeats:NO];
    });
}

- (BOOL)_coreDataChangeAffectsLists:(NSNotification *)note {
    NSDictionary *info = note.userInfo;

    // Inserted/deleted episodes, feeds or lists always change list contents.
    for (NSString *bucket in @[ NSInsertedObjectsKey, NSDeletedObjectsKey ]) {
        for (NSManagedObject *obj in info[bucket]) {
            if ([obj isKindOfClass:[CDEpisode class]] ||
                [obj isKindOfClass:[CDFeed class]] ||
                [obj isKindOfClass:[CDList class]]) {
                return YES;
            }
        }
    }

    // For updates, only membership-affecting keys matter — explicitly NOT `position`
    // (the playback tick) and NOT `lastPlayed` etc.
    static NSSet *relevantEpisodeKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        relevantEpisodeKeys = [NSSet setWithObjects:@"consumed", @"starred", @"archived", @"feed", @"episodeLists", nil];
    });
    for (NSManagedObject *obj in info[NSUpdatedObjectsKey]) {
        if ([obj isKindOfClass:[CDList class]] || [obj isKindOfClass:[CDFeed class]]) {
            return YES;  // list rename/rank, feed (un)subscribe / park
        }
        if ([obj isKindOfClass:[CDEpisode class]]) {
            for (NSString *changedKey in obj.changedValuesForCurrentEvent) {
                if ([relevantEpisodeKeys containsObject:changedKey]) return YES;
            }
        }
    }
    return NO;
}

- (void)_widgetControlAction:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *action = note.userInfo[@"action"];
        if (!action) return;

        NSURL *pendingURL = ([action isEqualToString:@"skipchapter"] && self.containerURL) ? [self.containerURL URLByAppendingPathComponent:kPendingActionFile] : nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSNumber *chapterIndex = nil;
            if (pendingURL) {
                NSData *data = [NSData dataWithContentsOfURL:pendingURL];
                if (data) {
                    NSError *error = nil;
                    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                    if ([payload isKindOfClass:[NSDictionary class]] && !error) {
                        NSString *pendingAction = payload[@"action"];
                        if ([pendingAction isEqualToString:@"skipchapter"]) {
                            chapterIndex = payload[@"chapterIndex"];
                        }
                    }
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [self _clearPendingWidgetActionFile];
                [self _handleWidgetAction:action chapterIndex:chapterIndex];
            });
        });
    });
}

- (void)_consumePendingWidgetActionNotification:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _consumePendingWidgetActionIfNeeded];
    });
}

- (void)_consumePendingWidgetActionIfNeeded {
    if (!self.containerURL) return;

    NSURL *pendingURL = [self.containerURL URLByAppendingPathComponent:kPendingActionFile];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:pendingURL];
        if (!data) return;

        NSError *error = nil;
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![payload isKindOfClass:[NSDictionary class]] || error) {
                [self _clearPendingWidgetActionFile];
                return;
            }

            NSString *action = payload[@"action"];
            NSNumber *chapterIndex = payload[@"chapterIndex"];
            [self _clearPendingWidgetActionFile];

            if (action.length > 0) {
                [self _handleWidgetAction:action chapterIndex:chapterIndex];
            }
        });
    });
}

- (void)_clearPendingWidgetActionFile {
    if (!self.containerURL) return;
    NSURL *pendingURL = [self.containerURL URLByAppendingPathComponent:kPendingActionFile];
    [[NSFileManager defaultManager] removeItemAtURL:pendingURL error:nil];
}

- (void)_handleWidgetAction:(NSString *)action chapterIndex:(NSNumber *)chapterIndex {
    if (action.length == 0) return;

    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];
    BOOL exportImmediately = NO;
    BOOL scheduleDelayedExport = NO;

    if ([action isEqualToString:@"playpause"]) {
        if (pm.playingEpisode) {
            // Episode already loaded — just toggle play/pause
            [pm playPause];
        } else if (self.lastPlayedEpisodeDict[@"id"]) {
            // No episode loaded — resume the last played episode
            NSString *episodeHash = self.lastPlayedEpisodeDict[@"id"];
            CDEpisode *episode = [DMANAGER episodeWithObjectHash:episodeHash];
            if (episode) {
                [as playEpisode:episode];
            }
        }
        exportImmediately = YES;
    } else if ([action isEqualToString:@"skipforward"]) {
        [pm seekForward];
        scheduleDelayedExport = YES;
    } else if ([action isEqualToString:@"skipbackward"]) {
        [pm seekBackward];
        scheduleDelayedExport = YES;
    } else if ([action isEqualToString:@"nextchapter"]) {
        [pm nextChapter];
        scheduleDelayedExport = YES;
    } else if ([action isEqualToString:@"prevchapter"]) {
        [pm previousChapter];
        scheduleDelayedExport = YES;
    } else if ([action isEqualToString:@"nextepisode"]) {
        CDEpisode *nextEpisode = [as nextPlayableEpisode];
        if (nextEpisode) {
            [as playEpisode:nextEpisode];
        }
        scheduleDelayedExport = YES;
    } else if ([action isEqualToString:@"previousepisode"]) {
        CDEpisode *previousEpisode = [self _previousEpisodeForPlaybackManager:pm audioSession:as];
        if (previousEpisode) {
            [as playEpisode:previousEpisode];
        }
        scheduleDelayedExport = YES;
    } else if ([action isEqualToString:@"cyclespeed"]) {
        PlaybackSpeedControl current = pm.speedControl;
        PlaybackSpeedControl next = [PlayerSpeedButton nextEnabledSpeedAfter:current];
        pm.speedControl = next;
        exportImmediately = YES;
    } else if ([action isEqualToString:@"togglesleeptimer"]) {
        if (as.timerRemainingTime > 0) {
            as.timerValue = PlaybackStopTimeNoValue;
        } else {
            PlaybackStopTimeValue lastTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
            if (lastTimer <= 0) lastTimer = PlaybackStopTime15min;
            as.timerValue = lastTimer;
        }
        exportImmediately = YES;
    } else if ([action isEqualToString:@"skipchapter"]) {
        NSInteger targetIdx = NSNotFound;
        if (chapterIndex) {
            targetIdx = chapterIndex.integerValue;
        } else {
            NSURL *skipFileURL = [self.containerURL URLByAppendingPathComponent:@"widget_skip_chapter.txt"];
            NSString *indexStr = [NSString stringWithContentsOfURL:skipFileURL encoding:NSUTF8StringEncoding error:nil];
            targetIdx = [indexStr integerValue];
            [[NSFileManager defaultManager] removeItemAtURL:skipFileURL error:nil];
        }

        if (targetIdx >= 0 && targetIdx < (NSInteger)pm.chapters.count) {
            ICMetadataChapter *chapter = pm.chapters[targetIdx];
            [pm seekToChapter:chapter];
            scheduleDelayedExport = YES;
        }
    }

    if (exportImmediately) {
        [self exportNowPlayingSnapshot];
        [WidgetKitHelper reloadNowPlayingTimeline];
    } else if (scheduleDelayedExport) {
        [self _scheduleControlActionNowPlayingExport];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"numberOfDownloadedBytes"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self exportStatsSnapshot];
            // Only reload Stats widget — download progress doesn't affect NowPlaying or Lists
            [WidgetKitHelper reloadStatsTimeline];
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)_debouncedNowPlayingExport {
    // Export the JSON snapshot — the widget reads it on next getTimeline.
    // Do NOT call reloadTimelines here! During playback, chapter/artwork changes
    // happen frequently and waste the WidgetKit budget (40-70 reloads/day).
    // The widget's timeline policy refreshes every 60s during playback, which picks
    // up the updated JSON. Critical state changes (play/pause, episode change) are
    // handled by direct reloadNowPlayingTimeline calls in their notification handlers.
    [self exportNowPlayingSnapshot];
    self.lastNowPlayingReloadSignature = [self _currentNowPlayingReloadSignature];
}

- (void)_debouncedListsExport {
    [self exportListsSnapshot];
}

- (void)_debouncedListsReload {
    // The Core Data channel fires for EVERY save — during playback the position save
    // re-triggers it every ~30s, forever. Together with the (formerly expensive) list
    // counts this kept a background thread busy until the system killed the app for
    // CPU usage. One lists export per minute is plenty for widgets; the explicit
    // triggers (refresh finished, playlist changed, entering background) stay direct.
    static CFAbsoluteTime lastCoreDataListsExport = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastCoreDataListsExport < 60.0) {
        return;
    }
    lastCoreDataListsExport = now;
    [self exportListsSnapshot];
    [WidgetKitHelper reloadListsTimeline];
}

#pragma mark - Export All

- (void)exportAllSnapshots {
    if (!self.containerURL) return;
    [self exportNowPlayingSnapshot];
    [self _persistLastPlayedCache];
    [self exportListsSnapshot];
    [self exportStatsSnapshot];
    [self exportSettingsSnapshot];
    // Full reload is OK here — only called on app background/startup
    [WidgetKitHelper reloadAllTimelines];
}

#pragma mark - Now Playing Export

- (void)exportNowPlayingSnapshot {
    if (!self.containerURL) return;

    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];

    CDEpisode *episode = pm.playingEpisode;

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"isPaused"] = @(pm.isPaused);
    snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];

    if (episode) {
        NSMutableDictionary *episodeDict = [[self _episodeDictForEpisode:episode withImageSize:kImageSizeMedium] mutableCopy];
        NSInteger currentPosition = MAX(0, (NSInteger)lrint(pm.time));
        NSInteger currentDuration = (pm.duration > 0) ? (NSInteger)lrint(pm.duration) : episode.duration;
        episodeDict[@"position"] = @(currentPosition);
        episodeDict[@"duration"] = @(MAX(0, currentDuration));
        snapshot[@"episode"] = episodeDict;

        // Skip times from feed settings
        CDFeed *feed = episode.feed;
        snapshot[@"skipForwardSeconds"] = @([feed integerForKey:PlayerSkipForwardPeriod]);
        snapshot[@"skipBackwardSeconds"] = @([feed integerForKey:PlayerSkipBackPeriod]);

        // Playback speed
        snapshot[@"playbackSpeed"] = [self _playbackSpeedString:pm.speedControl];

        // Chapter info
        NSArray *liveChapters = pm.chapters;
        NSArray *storedChapters = [episode sortedChapters];
        if (liveChapters.count > 0 || storedChapters.count > 0) {
            NSMutableArray *chapterDicts = [NSMutableArray array];
            NSTimeInterval trackDuration = (NSTimeInterval)currentDuration;
            NSInteger currentChapterIndex = 0;
            NSString *currentChapterTitle = @"";

            if (liveChapters.count > 0) {
                for (ICMetadataChapter *ch in liveChapters) {
                    NSTimeInterval startSec = CMTimeGetSeconds(ch.start);
                    NSTimeInterval dur = [ch durationWithTrackDuration:trackDuration];
                    [chapterDicts addObject:@{
                        @"title": ch.title ?: @"",
                        @"startTime": @(startSec),
                        @"duration": @(MAX(0, dur))
                    }];
                }

                NSInteger idx = [self _resolvedLiveChapterIndexForChapters:liveChapters
                                                              fallbackIndex:pm.currentChapter
                                                             currentPosition:currentPosition];
                if (idx >= 0 && idx < (NSInteger)liveChapters.count) {
                    ICMetadataChapter *chapter = liveChapters[idx];
                    currentChapterIndex = idx;
                    currentChapterTitle = chapter.title ?: @"";
                }
            } else {
                for (NSInteger i = 0; i < (NSInteger)storedChapters.count; i++) {
                    CDChapter *chapter = storedChapters[i];
                    NSTimeInterval startSec = MAX(0, chapter.timecode);
                    NSTimeInterval dur = chapter.duration;
                    if (!(dur > 0)) {
                        NSTimeInterval nextStart = trackDuration;
                        if (i + 1 < (NSInteger)storedChapters.count) {
                            CDChapter *nextChapter = storedChapters[i + 1];
                            nextStart = MAX(0, nextChapter.timecode);
                        }
                        dur = MAX(0, nextStart - startSec);
                    }

                    if (currentPosition >= (NSInteger)startSec) {
                        currentChapterIndex = i;
                        currentChapterTitle = chapter.title ?: @"";
                    }

                    [chapterDicts addObject:@{
                        @"title": chapter.title ?: @"",
                        @"startTime": @(startSec),
                        @"duration": @(MAX(0, dur))
                    }];
                }
            }

            snapshot[@"chapterTitle"] = currentChapterTitle;
            snapshot[@"chapterIndex"] = @(currentChapterIndex);
            snapshot[@"chapterCount"] = @(chapterDicts.count);
            snapshot[@"chapters"] = chapterDicts;
        }

        // Chapter artwork
        NSArray *artworks = pm.artworks;
        NSInteger artIdx = pm.currentArtwork;
        if (artworks.count > 0 && artIdx >= 0 && artIdx < (NSInteger)artworks.count) {
            ICMetadataImage *art = artworks[artIdx];
            if (art.data) {
                NSString *episodeHash = episode.objectHash ?: @"unknown";
                NSString *artFilename = [NSString stringWithFormat:@"chapter_art_%@_%ld.jpg", episodeHash, (long)artIdx];
                NSURL *artDest = [self.imagesURL URLByAppendingPathComponent:artFilename];
                [art.data writeToURL:artDest atomically:YES];
                snapshot[@"chapterArtPath"] = artFilename;
            }
        }

        // Sleep timer
        NSTimeInterval remaining = as.timerRemainingTime;
        if (remaining > 0 && as.stopDate) {
            snapshot[@"sleepTimerRemaining"] = @(remaining);
            snapshot[@"sleepTimerStopDate"] = [self _iso8601String:as.stopDate];
        }

        // Next/prev episode availability
        snapshot[@"hasPreviousEpisode"] = @([self _hasPreviousEpisodeForPlaybackManager:pm audioSession:as]);
        snapshot[@"hasNextEpisode"] = @([self _hasNextEpisodeForPlaybackManager:pm audioSession:as]);

        // Cache for fallback when playback ends.
        self.lastPlayedEpisodeDict = [episodeDict copy];
        NSMutableDictionary *extra = [NSMutableDictionary dictionary];
        extra[@"skipForwardSeconds"] = snapshot[@"skipForwardSeconds"];
        extra[@"skipBackwardSeconds"] = snapshot[@"skipBackwardSeconds"];
        extra[@"playbackSpeed"] = snapshot[@"playbackSpeed"];
        extra[@"hasPreviousEpisode"] = snapshot[@"hasPreviousEpisode"];
        extra[@"hasNextEpisode"] = snapshot[@"hasNextEpisode"];
        // Preserve chapter data so fallback display still shows chapter list/title
        if (snapshot[@"chapters"]) {
            extra[@"chapters"] = snapshot[@"chapters"];
            extra[@"chapterTitle"] = snapshot[@"chapterTitle"] ?: @"";
            extra[@"chapterIndex"] = snapshot[@"chapterIndex"] ?: @0;
            extra[@"chapterCount"] = snapshot[@"chapterCount"] ?: @0;
        }
        if (snapshot[@"chapterArtPath"]) {
            extra[@"chapterArtPath"] = snapshot[@"chapterArtPath"];
        }
        self.lastPlayedExtraFields = [extra copy];
    } else if (self.lastPlayedEpisodeDict) {
        // No current playback — show last played episode as paused
        snapshot[@"isPaused"] = @YES;
        snapshot[@"episode"] = self.lastPlayedEpisodeDict;
        if (self.lastPlayedExtraFields) {
            [snapshot addEntriesFromDictionary:self.lastPlayedExtraFields];
        }
    } else {
        // No episode and no cache — don't overwrite existing widget data
        // (previous session's last played info may still be in the JSON file)
        return;
    }

    [self _writeJSON:snapshot toFile:kNowPlayingFile];
    self.lastNowPlayingReloadSignature = [self _currentNowPlayingReloadSignature];
}

- (void)_scheduleDebouncedNowPlayingExport {
    if (self.pendingNowPlayingExportBlock) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    __block dispatch_block_t exportBlock = nil;
    exportBlock = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.pendingNowPlayingExportBlock != exportBlock) {
            return;
        }

        strongSelf.pendingNowPlayingExportBlock = nil;
        [strongSelf _debouncedNowPlayingExport];
    });

    self.pendingNowPlayingExportBlock = exportBlock;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNowPlayingExportThrottleInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   exportBlock);
}

- (void)_scheduleControlActionNowPlayingExport {
    if (self.pendingControlActionExportBlock) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    __block dispatch_block_t exportBlock = nil;
    exportBlock = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.pendingControlActionExportBlock != exportBlock) {
            return;
        }

        strongSelf.pendingControlActionExportBlock = nil;
        [strongSelf exportNowPlayingSnapshot];
        [WidgetKitHelper reloadAllTimelines];
    });

    self.pendingControlActionExportBlock = exportBlock;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kControlActionExportDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   exportBlock);
}

- (NSInteger)_resolvedLiveChapterIndexForChapters:(NSArray<ICMetadataChapter *> *)liveChapters
                                     fallbackIndex:(NSInteger)fallbackIndex
                                    currentPosition:(NSInteger)currentPosition {
    if (liveChapters.count == 0) {
        return NSNotFound;
    }

    NSTimeInterval playbackPosition = MAX(0, currentPosition);
    NSInteger resolvedIndex = NSNotFound;

    for (NSInteger i = 0; i < (NSInteger)liveChapters.count; i++) {
        ICMetadataChapter *chapter = liveChapters[i];
        NSTimeInterval startSec = CMTimeGetSeconds(chapter.start);
        if (!(startSec >= 0)) {
            startSec = 0;
        }

        if (playbackPosition >= startSec) {
            resolvedIndex = i;
        } else {
            break;
        }
    }

    if (resolvedIndex != NSNotFound) {
        return resolvedIndex;
    }
    if (fallbackIndex >= 0 && fallbackIndex < (NSInteger)liveChapters.count) {
        return fallbackIndex;
    }
    return 0;
}

- (NSString *)_currentNowPlayingReloadSignature {
    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];
    CDEpisode *episode = pm.playingEpisode;
    NSString *episodeHash = episode.objectHash ?: @"";
    BOOL isPaused = (!episode || pm.isPaused);
    NSInteger chapterIndex = NSNotFound;
    NSString *chapterTitle = @"";
    if (episode && pm.chapters.count > 0) {
        NSInteger currentPosition = MAX(0, (NSInteger)lrint(pm.time));
        NSInteger resolvedIndex = [self _resolvedLiveChapterIndexForChapters:pm.chapters
                                                                fallbackIndex:pm.currentChapter
                                                               currentPosition:currentPosition];
        if (resolvedIndex >= 0 && resolvedIndex < (NSInteger)pm.chapters.count) {
            chapterIndex = resolvedIndex;
            ICMetadataChapter *chapter = pm.chapters[resolvedIndex];
            chapterTitle = chapter.title ?: @"";
        }
    }

    NSString *playbackSpeed = [self _playbackSpeedString:pm.speedControl] ?: @"";
    NSString *chapterArtSource = @"";
    if (episode && pm.currentArtwork >= 0 && pm.currentArtwork < (NSInteger)pm.artworks.count) {
        chapterArtSource = [NSString stringWithFormat:@"%@:%ld", episodeHash, (long)pm.currentArtwork];
    }

    NSTimeInterval sleepTimerState = as.stopDate ? as.stopDate.timeIntervalSince1970 : 0;
    BOOL hasPreviousEpisode = [self _hasPreviousEpisodeForPlaybackManager:pm audioSession:as];
    BOOL hasNextEpisode = [self _hasNextEpisodeForPlaybackManager:pm audioSession:as];
    NSInteger skipForwardSeconds = episode ? [episode.feed integerForKey:PlayerSkipForwardPeriod] : 0;
    NSInteger skipBackwardSeconds = episode ? [episode.feed integerForKey:PlayerSkipBackPeriod] : 0;
    return [NSString stringWithFormat:@"%@|%d|%ld|%@|%@|%@|%d|%d|%ld|%ld|%.0f",
            episodeHash,
            isPaused,
            (long)chapterIndex,
            chapterTitle,
            chapterArtSource,
            playbackSpeed,
            hasPreviousEpisode,
            hasNextEpisode,
            (long)skipForwardSeconds,
            (long)skipBackwardSeconds,
            sleepTimerState];
}

- (BOOL)_hasNextEpisodeForPlaybackManager:(PlaybackManager *)pm audioSession:(AudioSession *)as {
    if (!pm.playingEpisode) {
        return NO;
    }
    return ([as nextPlayableEpisode] != nil);
}

- (CDEpisode *)_previousEpisodeForPlaybackManager:(PlaybackManager *)pm audioSession:(AudioSession *)as {
    CDEpisode *currentEpisode = pm.playingEpisode;
    if (!currentEpisode) {
        return nil;
    }

    NSArray *playlist = as.playlist;
    NSUInteger index = [playlist indexOfObject:currentEpisode];
    if (index != NSNotFound && index > 0 && index < playlist.count) {
        return playlist[index - 1];
    }
    return nil;
}

- (BOOL)_hasPreviousEpisodeForPlaybackManager:(PlaybackManager *)pm audioSession:(AudioSession *)as {
    return ([self _previousEpisodeForPlaybackManager:pm audioSession:as] != nil);
}

#pragma mark - Lists Export

- (void)exportListsSnapshot {
    if (!self.containerURL) return;
    // Evaluate the background/playback gate on the main thread (UIApplication state),
    // so off-main callers (e.g. image-prefetch completions) are handled correctly too.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self exportListsSnapshot]; });
        return;
    }
    if ([self _deferHeavyListsExportInBackgroundPlayback]) return;

    // Coalesce bursts (a feed refresh posts several triggers) into a single pass: while one
    // export is in flight, just remember another is wanted and run it once afterwards.
    if (self.listsExportRunning) { self.listsExportQueuedAgain = YES; return; }
    self.listsExportRunning = YES;

    BOOL foreground = ([UIApplication sharedApplication].applicationState == UIApplicationStateActive);
    dispatch_async(self.listsExportQueue, ^{
        CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
        __block CFAbsoluteTime querySeconds = 0, countSeconds = 0, fetchSeconds = 0, imageSeconds = 0;
        __block NSUInteger listCount = 0, episodeCount = 0;
        NSMutableArray *listIndex = [NSMutableArray array];
        NSMutableArray *episodeSnapshots = [NSMutableArray array];
        NSManagedObjectContext *backgroundContext = [DMANAGER newBackgroundContext];

        CFAbsoluteTime queryStart = CFAbsoluteTimeGetCurrent();
        [backgroundContext performBlockAndWait:^{
            NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"List"];
            request.includesSubentities = YES;
            request.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
            NSArray *lists = [backgroundContext executeFetchRequest:request error:nil];
            listCount = lists.count;

            for (CDList *list in lists) {
                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"id"] = list.uid ?: @"";
                d[@"name"] = list.name ?: @"";
                CFAbsoluteTime cT = CFAbsoluteTimeGetCurrent();
                d[@"episodeCount"] = @(list.numberOfEpisodes);
                countSeconds += CFAbsoluteTimeGetCurrent() - cT;

                if ([list isKindOfClass:[CDSmartPlaylist class]]) {
                    CDSmartPlaylist *smart = (CDSmartPlaylist *)list;
                    NSString *type = smart.smartPredicate[@"type"];
                    d[@"type"] = type ? [NSString stringWithFormat:@"smart:%@", type] : @"smart";
                } else if ([list isKindOfClass:[CDEpisodeList class]]) {
                    d[@"type"] = @"episode_list";
                } else {
                    d[@"type"] = @"playlist";
                }

                [listIndex addObject:d];

                CFAbsoluteTime fT = CFAbsoluteTimeGetCurrent();
                NSArray *episodes = [list sortedEpisodesWithLimit:kMaxEpisodesPerList];
                fetchSeconds += CFAbsoluteTimeGetCurrent() - fT;

                NSMutableArray *episodeDicts = [NSMutableArray array];
                NSInteger count = 0;
                CFAbsoluteTime iT = CFAbsoluteTimeGetCurrent();
                for (CDEpisode *ep in episodes) {
                    if (count >= kMaxEpisodesPerList) break;
                    [episodeDicts addObject:[self _episodeDictForEpisode:ep withImageSize:kImageSizeMedium]];
                    count++;
                }
                imageSeconds += CFAbsoluteTimeGetCurrent() - iT;
                episodeCount += count;

                NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
                snapshot[@"listId"] = list.uid ?: @"";
                snapshot[@"listName"] = list.name ?: @"";
                snapshot[@"episodes"] = episodeDicts;
                snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];

                NSString *filename = [NSString stringWithFormat:@"%@%@.json", kListEpisodesPrefix, list.uid ?: @"unknown"];
                [episodeSnapshots addObject:@{ @"filename": filename, @"snapshot": snapshot }];
            }
        }];
        querySeconds = CFAbsoluteTimeGetCurrent() - queryStart;

        CFAbsoluteTime writeStart = CFAbsoluteTimeGetCurrent();
        for (NSDictionary *entry in episodeSnapshots) {
            [self _writeJSON:entry[@"snapshot"] toFile:entry[@"filename"]];
        }
        [self _writeJSON:listIndex toFile:kListsIndexFile];
        CFAbsoluteTime writeSeconds = CFAbsoluteTimeGetCurrent() - writeStart;

        // Per-phase breakdown so one foreground run pinpoints where the budget goes
        // (target: total <= 0.100s). count = SQL counts, fetch = sorted episode fetches,
        // image = dict build incl. image stat/MD5, write = JSON file writes.
        [[ICDiagnosticLogger shared] logEvent:@"widget-export"
                                      message:@"Listen-Export fertig"
                                     metadata:@{ @"lists": [NSString stringWithFormat:@"%lu", (unsigned long)listCount],
                                                 @"episodes": [NSString stringWithFormat:@"%lu", (unsigned long)episodeCount],
                                                 @"total_s": [NSString stringWithFormat:@"%.3f", CFAbsoluteTimeGetCurrent() - startTime],
                                                 @"query_s": [NSString stringWithFormat:@"%.3f", querySeconds],
                                                 @"count_s": [NSString stringWithFormat:@"%.3f", countSeconds],
                                                 @"fetch_s": [NSString stringWithFormat:@"%.3f", fetchSeconds],
                                                 @"image_s": [NSString stringWithFormat:@"%.3f", imageSeconds],
                                                 @"write_s": [NSString stringWithFormat:@"%.3f", writeSeconds],
                                                 @"foreground": foreground ? @"1" : @"0" }];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.listsExportRunning = NO;
            if (self.listsExportQueuedAgain) {
                self.listsExportQueuedAgain = NO;
                [self exportListsSnapshot];
            }
        });
    });
}

#pragma mark - Background-Playback Gate

// The background CPU watchdog only fires while the app keeps running in the background —
// which, for this app, means active audio playback. The heavy per-list Core Data scans in
// exportListsSnapshot have no business running then (the playing file + position via MQTT/
// iCloud are all that needs updating). Defer the export to the next foreground.
// Root cause of the 26.06. cpu_resource_fatal: 48s CPU over 49s in exportListsSnapshot.
- (BOOL)_deferHeavyListsExportInBackgroundPlayback {
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
        return NO;
    }
    PlaybackManager *pm = [PlaybackManager playbackManager];
    if (pm.playingEpisode == nil || pm.isPaused) {
        // Not playing → the app is about to be suspended, so no sustained background CPU.
        return NO;
    }
    self.pendingListsExport = YES;
    [[ICDiagnosticLogger shared] logEvent:@"widget-export"
                                  message:@"Listen-Export im Hintergrund-Playback aufgeschoben"
                                 metadata:@{ @"reason": @"background-playback" }];
    return YES;
}

- (void)_flushDeferredExportsOnForeground:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.pendingListsExport) {
            self.pendingListsExport = NO;
            [self exportListsSnapshot];
            [WidgetKitHelper reloadListsTimeline];
        }
        if (self.pendingStatsRefresh) {
            self.pendingStatsRefresh = NO;
            [self exportStatsSnapshot];
            [WidgetKitHelper reloadStatsTimeline];
        }
    });
}

#pragma mark - Stats Export

- (void)exportStatsSnapshot {
    if (!self.containerURL) return;
    NSDate *now = [NSDate date];
    [self _updateStatsDayIfNeededForDate:now];

    NSInteger sleepTimerCount = [USER_DEFAULTS integerForKey:@"SleepTimerFellAsleepCount"];

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"listenedTodaySec"] = @(self.cachedListenedTodaySec);
    snapshot[@"listenedWeekSec"] = @(self.cachedListenedWeekSec);
    snapshot[@"downloadedCount"] = @(self.cachedDownloadedCount);
    snapshot[@"downloadedSizeBytes"] = @(self.cachedDownloadedSizeBytes);
    snapshot[@"subscribedCount"] = @(self.cachedSubscribedCount);
    snapshot[@"unplayedCount"] = @(self.cachedUnplayedCount);
    snapshot[@"newEpisodesTodayCount"] = @(self.cachedNewEpisodesTodayCount);
    snapshot[@"sleepTimerUsedCount"] = @(sleepTimerCount);
    snapshot[@"timestamp"] = [self _iso8601String:now];

    [self _writeJSON:snapshot toFile:kStatsFile];
    [self _refreshStatsCacheInBackgroundWritingSnapshot:YES reloadWhenDone:NO];
}

#pragma mark - Listening Time Tracking

- (void)_trackListeningTime {
    PlaybackManager *pm = [PlaybackManager playbackManager];
    if (pm.isPaused || !pm.playingEpisode) {
        return;
    }

    NSDate *now = [NSDate date];
    if (self.lastListeningTimestamp) {
        [self _appendListeningDeltaSinceLastTimestampAtDate:now];
    }
    self.lastListeningTimestamp = now;
}

- (BOOL)_appendListeningDeltaSinceLastTimestampAtDate:(NSDate *)date {
    if (!self.lastListeningTimestamp || !self.containerURL || !date) {
        return NO;
    }

    NSTimeInterval delta = [date timeIntervalSinceDate:self.lastListeningTimestamp];
    if (!(delta > 0 && delta < 15)) {
        return NO;
    }

    NSMutableDictionary *log = [[self _readListeningLog] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *todayKey = [self _dateKeyForDate:date];
    double current = [log[todayKey] doubleValue];
    log[todayKey] = @(current + delta);

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *cutoff = [cal dateByAddingUnit:NSCalendarUnitDay value:-8 toDate:date options:0];
    NSString *cutoffKey = [self _dateKeyForDate:cutoff];
    NSMutableArray *keysToRemove = [NSMutableArray array];
    for (NSString *key in log) {
        if ([key compare:cutoffKey] == NSOrderedAscending) {
            [keysToRemove addObject:key];
        }
    }
    [log removeObjectsForKeys:keysToRemove];

    NSURL *logURL = [self.containerURL URLByAppendingPathComponent:kListeningLogFile];
    [log writeToURL:logURL atomically:YES];
    return YES;
}

- (void)_refreshStatsDuringPlaybackIfNeeded {
    PlaybackManager *pm = [PlaybackManager playbackManager];
    if (pm.isPaused || !pm.playingEpisode) {
        BOOL wroteListeningDelta = [self _appendListeningDeltaSinceLastTimestampAtDate:[NSDate date]];
        self.lastListeningTimestamp = nil;
        self.lastPlaybackStatsRefreshDate = nil;
        if (wroteListeningDelta) {
            [self exportStatsSnapshot];
            [WidgetKitHelper reloadStatsTimeline];
        }
        return;
    }

    // Same background-playback rule as the lists export: don't run the heavy stats
    // Core Data counts while the app is kept alive in the background by playback.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        self.pendingStatsRefresh = YES;
        return;
    }

    NSDate *now = [NSDate date];
    if (self.lastPlaybackStatsRefreshDate &&
        [now timeIntervalSinceDate:self.lastPlaybackStatsRefreshDate] < 60.0) {
        return;
    }

    self.lastPlaybackStatsRefreshDate = now;
    [self exportStatsSnapshot];
    [WidgetKitHelper reloadStatsTimeline];
}

- (NSDictionary *)_readListeningLog {
    NSURL *logURL = [self.containerURL URLByAppendingPathComponent:kListeningLogFile];
    return [NSDictionary dictionaryWithContentsOfURL:logURL] ?: @{};
}

- (NSString *)_dateKeyForDate:(NSDate *)date {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd";
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:date];
}

#pragma mark - Settings Export

- (void)exportSettingsSnapshot {
    if (!self.containerURL) return;
    NSDictionary *settings = @{
        @"accentColorHex": [self _accentColorHex]
    };
    [self _writeJSON:settings toFile:kSettingsFile];
}

- (NSString *)_accentColorHex {
    UIColor *color = nil;

    // 1. Widget-specific color (if set)
    if (![USER_DEFAULTS boolForKey:WidgetThemeDefaultActive]) {
        NSData *colorData = [USER_DEFAULTS objectForKey:WidgetThemeColorCode];
        if (colorData) {
            color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
        }
    }

    // 2. Fallback: Interface color
    if (!color && ![USER_DEFAULTS boolForKey:InterfaceThemeDefaultActive]) {
        NSData *colorData = [USER_DEFAULTS objectForKey:InterfaceThemeColorCode];
        if (colorData) {
            color = [NSKeyedUnarchiver unarchivedObjectOfClass:[UIColor class] fromData:colorData error:nil];
        }
    }

    // 3. Fallback: Default Instacast orange #FF5300
    if (!color) {
        color = [UIColor colorWithRed:1.f green:83/255.f blue:0 alpha:1.f];
    }

    CGFloat r = 0, g = 0, b = 0, a = 0;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X", (int)(r * 255), (int)(g * 255), (int)(b * 255)];
}

#pragma mark - Widget Timeline Reload

- (void)reloadWidgetTimelines {
    // Ensure timer creation on main thread
    void (^block)(void) = ^{
        [self.reloadTimelineTimer invalidate];
        self.reloadTimelineTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                                   target:self
                                                                 selector:@selector(_doReloadTimelines)
                                                                 userInfo:nil
                                                                  repeats:NO];
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (void)_doReloadTimelines {
    [WidgetKitHelper reloadAllTimelines];
}

#pragma mark - Episode Dictionary Builder

- (NSDictionary *)_episodeDictForEpisode:(CDEpisode *)episode withImageSize:(NSInteger)size {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = episode.objectHash ?: @"";
    d[@"title"] = episode.title ?: @"";
    d[@"feedTitle"] = episode.feed.displayTitle ?: episode.feed.title ?: @"";
    d[@"duration"] = @(episode.duration);
    d[@"position"] = @(episode.position);
    d[@"consumed"] = @(episode.consumed);
    d[@"starred"] = @(episode.starred);
    d[@"downloaded"] = @(episode.downloaded);

    if (episode.pubDate) {
        d[@"pubDate"] = [self _iso8601String:episode.pubDate];
    }

    // Image: prefer episode image, fall back to feed image
    NSURL *imageURL = episode.imageURL ?: episode.feed.imageURL;
    if (imageURL) {
        d[@"feedImageURL"] = imageURL.absoluteString;
        NSString *localPath = [self _copyImageForURL:imageURL size:size];
        if (localPath) {
            d[@"localImagePath"] = localPath;
        }
    }

    return [d copy];
}

#pragma mark - Image Copying

- (NSString *)_copyImageForURL:(NSURL *)imageURL size:(NSInteger)size {
    if (!imageURL || !self.imagesURL) return nil;

    NSURL *sourceURL = [self _cachedImageSourceURLForURL:imageURL requestedSize:size];
    if (!sourceURL) {
        [self _prefetchImageForWidgetIfNeeded:imageURL size:size];
        return nil;
    }
    return [self _doCopyImageFromSource:sourceURL forURL:imageURL size:size];
}

- (NSString *)_doCopyImageFromSource:(NSURL *)sourceURL forURL:(NSURL *)imageURL size:(NSInteger)size {
    // Use a consistent filename in the widget images folder based on MD5 and requested size
    NSString *md5 = [[imageURL absoluteString] MD5Hash];
    NSString *filename = [NSString stringWithFormat:@"%@_%ld.jpg", md5, (long)size];
    NSURL *destURL = [self.imagesURL URLByAppendingPathComponent:filename];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:destURL.path]) {
        NSError *error = nil;
        BOOL copied = [fm copyItemAtURL:sourceURL toURL:destURL error:&error];
        if (!copied && error) {
            if (error.code == NSFileWriteFileExistsError) {
                return filename;
            }
            DebugLog(@"WidgetDataExporter: failed to copy image %@: %@", filename, error.localizedDescription);
            return nil;
        }
    }
    return filename;
}

- (void)_prefetchImageForWidgetIfNeeded:(NSURL *)imageURL size:(NSInteger)size {
    if (!imageURL) return;

    NSString *key = [NSString stringWithFormat:@"%@#%ld", imageURL.absoluteString ?: @"", (long)size];
    if (key.length == 0) return;

    @synchronized (self.pendingImageFetchKeys) {
        if ([self.pendingImageFetchKeys containsObject:key]) {
            return;
        }
        [self.pendingImageFetchKeys addObject:key];
    }

    [ImageCacheManager loadImageForURL:imageURL
                                  size:size
                             grayscale:NO
                            completion:^(UIImage *platformImage, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (self.pendingImageFetchKeys) {
                [self.pendingImageFetchKeys removeObject:key];
            }

            if (!platformImage || error) {
                if (error) {
                    DebugLog(@"WidgetDataExporter: image prefetch failed for %@: %@", imageURL.absoluteString, error.localizedDescription);
                }
                return;
            }

            NSString *localPath = [self _copyImageForURL:imageURL size:size];
            if (localPath.length > 0) {
                [self exportListsSnapshot];
                [self exportNowPlayingSnapshot];
                [WidgetKitHelper reloadListsTimeline];
                [WidgetKitHelper reloadNowPlayingTimeline];
            }
        });
    }];
}

#pragma mark - Playback Speed Helper

- (NSString *)_playbackSpeedString:(PlaybackSpeedControl)speed {
    return [PlayerSpeedButton titleForSpeedControl:speed];
}

- (void)_restoreStatsCacheFromDisk {
    self.cachedNewEpisodesTodayCount = 0;
    self.cachedStatsDayKey = [self _dateKeyForDate:[NSDate date]];
    if (!self.containerURL) return;

    NSURL *fileURL = [self.containerURL URLByAppendingPathComponent:kStatsFile];
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data) return;

    NSError *error = nil;
    NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![snapshot isKindOfClass:[NSDictionary class]] || error) return;

    NSString *timestampString = snapshot[@"timestamp"];
    NSDate *timestamp = [self _dateFromISOString:timestampString];
    if (timestamp && [[self _dateKeyForDate:timestamp] isEqualToString:self.cachedStatsDayKey]) {
        self.cachedNewEpisodesTodayCount = [snapshot[@"newEpisodesTodayCount"] integerValue];
    }
}

- (void)_refreshStatsCacheInBackgroundWritingSnapshot:(BOOL)writeSnapshot reloadWhenDone:(BOOL)reloadWhenDone {
    if (!self.containerURL || self.statsRefreshInProgress) return;

    self.statsRefreshInProgress = YES;
    [self _updateStatsDayIfNeededForDate:[NSDate date]];

    NSString *dayKey = [self.cachedStatsDayKey copy];
    NSDate *now = [NSDate date];
    NSDate *startOfToday = [[NSCalendar currentCalendar] startOfDayForDate:now];

    dispatch_async(self.statsRefreshQueue, ^{
        __block NSUInteger newEpisodesCount = 0;
        __block NSUInteger subscribedCount = 0;
        __block NSUInteger unplayedCount = 0;
        __block NSUInteger downloadedCount = 0;

        NSDictionary *listeningLog = [self _readListeningLog];
        NSString *todayKey = [self _dateKeyForDate:now];
        double todaySec = [listeningLog[todayKey] doubleValue];
        double weekSec = 0;
        NSCalendar *cal = [NSCalendar currentCalendar];
        for (NSInteger i = 0; i < 7; i++) {
            NSDate *day = [cal dateByAddingUnit:NSCalendarUnitDay value:-i toDate:now options:0];
            NSString *key = [self _dateKeyForDate:day];
            weekSec += [listeningLog[key] doubleValue];
        }

        NSManagedObjectContext *backgroundContext = [DMANAGER newBackgroundContext];
        if (backgroundContext) {
            [backgroundContext performBlockAndWait:^{
                NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                request.predicate = [NSPredicate predicateWithFormat:@"pubDate >= %@ AND feed.subscribed == YES AND archived == NO", startOfToday];
                request.resultType = NSCountResultType;
                NSUInteger count = [backgroundContext countForFetchRequest:request error:nil];
                newEpisodesCount = (count == NSNotFound) ? 0 : count;

                NSFetchRequest *subscribedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
                subscribedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES AND parked == NO"];
                subscribedRequest.resultType = NSCountResultType;
                NSUInteger feedCount = [backgroundContext countForFetchRequest:subscribedRequest error:nil];
                subscribedCount = (feedCount == NSNotFound) ? 0 : feedCount;

                NSFetchRequest *unplayedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                unplayedRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND archived == NO AND consumed == NO"];
                unplayedRequest.resultType = NSCountResultType;
                NSUInteger unplayedResult = [backgroundContext countForFetchRequest:unplayedRequest error:nil];
                unplayedCount = (unplayedResult == NSNotFound) ? 0 : unplayedResult;

                NSFetchRequest *downloadedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                downloadedRequest.predicate = [NSPredicate predicateWithFormat:@"downloaded == YES"];
                downloadedRequest.resultType = NSCountResultType;
                NSUInteger downloadedResult = [backgroundContext countForFetchRequest:downloadedRequest error:nil];
                downloadedCount = (downloadedResult == NSNotFound) ? 0 : downloadedResult;
            }];
        }
        unsigned long long downloadedSizeBytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytes];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.statsRefreshInProgress = NO;
            if (![self.cachedStatsDayKey isEqualToString:dayKey]) {
                return;
            }

            self.cachedNewEpisodesTodayCount = (NSInteger)newEpisodesCount;
            self.cachedListenedTodaySec = todaySec;
            self.cachedListenedWeekSec = weekSec;
            self.cachedDownloadedCount = (NSInteger)downloadedCount;
            self.cachedDownloadedSizeBytes = downloadedSizeBytes;
            self.cachedSubscribedCount = (NSInteger)subscribedCount;
            self.cachedUnplayedCount = (NSInteger)unplayedCount;

            if (writeSnapshot) {
                NSInteger sleepTimerCount = [USER_DEFAULTS integerForKey:@"SleepTimerFellAsleepCount"];
                NSDictionary *snapshot = @{
                    @"listenedTodaySec": @(self.cachedListenedTodaySec),
                    @"listenedWeekSec": @(self.cachedListenedWeekSec),
                    @"downloadedCount": @(self.cachedDownloadedCount),
                    @"downloadedSizeBytes": @(self.cachedDownloadedSizeBytes),
                    @"subscribedCount": @(self.cachedSubscribedCount),
                    @"unplayedCount": @(self.cachedUnplayedCount),
                    @"newEpisodesTodayCount": @(self.cachedNewEpisodesTodayCount),
                    @"sleepTimerUsedCount": @(sleepTimerCount),
                    @"timestamp": [self _iso8601String:[NSDate date]]
                };
                [self _writeJSON:snapshot toFile:kStatsFile];
            }
            if (reloadWhenDone) {
                [WidgetKitHelper reloadStatsTimeline];
            }
        });
    });
}

- (void)_updateStatsDayIfNeededForDate:(NSDate *)date {
    NSString *dayKey = [self _dateKeyForDate:date];
    if (![self.cachedStatsDayKey isEqualToString:dayKey]) {
        self.cachedStatsDayKey = dayKey;
        self.cachedNewEpisodesTodayCount = 0;
        if (self.containerURL && !self.statsRefreshInProgress) {
            [self _refreshStatsCacheInBackgroundWritingSnapshot:YES reloadWhenDone:NO];
        }
    }
}

- (void)_removeLegacyUpNextFiles {
    if (!self.containerURL) return;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *filename in @[@"widget_upnext.json", @"widget_list___upnext__.json"]) {
        NSURL *fileURL = [self.containerURL URLByAppendingPathComponent:filename];
        [fileManager removeItemAtURL:fileURL error:nil];
    }
}

- (void)_updateStatsCacheForAddedEpisodes:(NSArray<CDEpisode *> *)episodes {
    if (episodes.count == 0) return;

    NSDate *now = [NSDate date];
    [self _updateStatsDayIfNeededForDate:now];
    NSDate *startOfToday = [[NSCalendar currentCalendar] startOfDayForDate:now];

    NSInteger addedToday = 0;
    for (CDEpisode *episode in episodes) {
        if (episode.pubDate && [episode.pubDate compare:startOfToday] != NSOrderedAscending &&
            episode.feed.subscribed && !episode.archived) {
            addedToday += 1;
        }
    }

    self.cachedNewEpisodesTodayCount += addedToday;
}

- (NSDate *)_dateFromISOString:(NSString *)string {
    if (string.length == 0) return nil;

    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssXXXXX";
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [fmt dateFromString:string];
}

- (NSURL *)_cachedImageSourceURLForURL:(NSURL *)imageURL requestedSize:(NSInteger)size {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSNumber *candidateSize in [self _candidateSourceImageSizesForRequestedSize:size]) {
        NSURL *candidateURL = [ImageCacheManager fileURLToCachedImageForImageURL:imageURL size:[candidateSize integerValue] grayscale:NO];
        if (candidateURL && [fm fileExistsAtPath:candidateURL.path]) {
            return candidateURL;
        }
    }

    return nil;
}

- (NSArray<NSNumber *> *)_candidateSourceImageSizesForRequestedSize:(NSInteger)size {
    NSMutableOrderedSet<NSNumber *> *sizes = [NSMutableOrderedSet orderedSetWithObject:@(size)];
    for (NSNumber *candidate in @[@580, @320, @160, @120, @80, @72, @60, @56, @44, @0]) {
        [sizes addObject:candidate];
    }
    return sizes.array;
}

#pragma mark - JSON Writing

- (void)_writeJSON:(id)object toFile:(NSString *)filename {
    if (!self.containerURL) return;

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                  options:0
                                                    error:&error];
    if (error) {
        return;
    }

    NSURL *fileURL = [self.containerURL URLByAppendingPathComponent:filename];
    [data writeToURL:fileURL atomically:YES];
}

#pragma mark - Last Played Cache Persistence

static NSString* const kLastPlayedEpisodeCacheFile = @"widget_lastplayed_episode.plist";
static NSString* const kLastPlayedExtraCacheFile    = @"widget_lastplayed_extra.plist";

- (void)_persistLastPlayedCache {
    if (!self.containerURL || !self.lastPlayedEpisodeDict) return;
    NSURL *epURL = [self.containerURL URLByAppendingPathComponent:kLastPlayedEpisodeCacheFile];
    [self.lastPlayedEpisodeDict writeToURL:epURL atomically:YES];
    if (self.lastPlayedExtraFields) {
        NSURL *exURL = [self.containerURL URLByAppendingPathComponent:kLastPlayedExtraCacheFile];
        [self.lastPlayedExtraFields writeToURL:exURL atomically:YES];
    }
}

- (void)_restoreLastPlayedCache {
    NSURL *epURL = [self.containerURL URLByAppendingPathComponent:kLastPlayedEpisodeCacheFile];
    NSDictionary *ep = [NSDictionary dictionaryWithContentsOfURL:epURL];
    if (ep) {
        self.lastPlayedEpisodeDict = ep;
        NSURL *exURL = [self.containerURL URLByAppendingPathComponent:kLastPlayedExtraCacheFile];
        self.lastPlayedExtraFields = [NSDictionary dictionaryWithContentsOfURL:exURL];
    }
}

#pragma mark - ISO 8601 Helpers

- (NSString *)_iso8601String:(NSDate *)date {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssXXXXX"; // XXXXX → "Z" for UTC, parsable by Swift's .iso8601
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [fmt stringFromDate:date];
}

@end
