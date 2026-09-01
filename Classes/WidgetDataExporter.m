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

// Navigation availability is structural state. Playback position ticks reuse it until an
// episode/queue/list/cache transition explicitly advances this generation.
@property (nonatomic) NSUInteger nowPlayingNavigationGeneration;
@property (nonatomic) NSUInteger cachedNowPlayingNavigationGeneration;
@property (nonatomic) BOOL hasCachedNowPlayingNavigationState;
@property (nonatomic) BOOL cachedHasNextEpisode;
@property (nonatomic, copy) NSString *cachedNowPlayingEpisodeHash;

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
- (void)_invalidateNowPlayingNavigationCache;
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
    [nc addObserver:self selector:@selector(_cacheDidClear:) name:CacheManagerDidRestoreCacheNotification object:nil];
    [[CacheManager sharedCacheManager] addObserver:self forKeyPath:@"numberOfDownloadedBytes" options:0 context:NULL];

    // Playlist events
    [nc addObserver:self selector:@selector(_playlistDidChange:) name:CDPlaylistDidChangeEpisodesNotification object:nil];
    AudioSession *audioSession = [AudioSession sharedAudioSession];
    [audioSession addTaskObserver:self forKeyPath:@"playlist" task:^(__unused id obj, __unused NSDictionary *change) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _invalidateNowPlayingNavigationCache];
            [self exportNowPlayingSnapshot];
            [WidgetKitHelper reloadNowPlayingTimeline];
        });
    }];

    // Sleep timer
    [nc addObserver:self selector:@selector(_sleepTimerExpired:) name:AudioSessionSleepTimerDidExpireNotification object:nil];

    // Core Data changes (for smart playlist updates)
    [nc addObserver:self selector:@selector(_coreDataDidChange:) name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];

    // A newly-installed widget kind needs its snapshot populated immediately (WidgetKit does
    // not wake the app for a Core Data export). Populate on the next foreground/launch probe.
    [nc addObserver:self selector:@selector(_installedWidgetsDidChange:) name:@"ICWidgetInstalledKindsDidChange" object:nil];

    // Widget control actions (from Darwin notifications via WidgetKitHelper)
    [nc addObserver:self selector:@selector(_widgetControlAction:) name:@"WidgetControlActionNotification" object:nil];
    [nc addObserver:self selector:@selector(_consumePendingWidgetActionNotification:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(_consumePendingWidgetActionNotification:) name:UIApplicationWillEnterForegroundNotification object:nil];

    // Catch up on heavy exports that were deferred during background playback.
    [nc addObserver:self selector:@selector(_flushDeferredExportsOnForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [nc addObserver:self selector:@selector(_flushDeferredExportsOnForeground:) name:UIApplicationDidBecomeActiveNotification object:nil];

    // Probe installed widgets up front so the export gate has a fresh answer.
    [WidgetKitHelper refreshInstalledWidgets];

    // Initial export so widget config has data immediately
    // (exportAllSnapshots is also called in sceneDidEnterBackground).
    // Each export method is gated on installed widgets, so this whole burst is a no-op
    // when the user has no widgets.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _consumePendingWidgetActionIfNeeded];
        if (![WidgetKitHelper hasInstalledWidgets]) return;
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
        [self _invalidateNowPlayingNavigationCache];
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [WidgetKitHelper reloadNowPlayingTimeline];
    });
}

- (void)_playbackDidEnd:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _invalidateNowPlayingNavigationCache];
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
        [self _invalidateNowPlayingNavigationCache];
        NSString *previousHash = self.lastPlayedEpisodeDict[@"id"];
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [self _exportListsAffectedByEpisodeHashes:[self _transitionEpisodeHashesWithPrevious:previousHash]];
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
        [self _invalidateNowPlayingNavigationCache];
        NSString *previousHash = self.lastPlayedEpisodeDict[@"id"];
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        // Incremental: only the lists containing the finished/next episode change here —
        // never a full all-lists scan on a playback transition (User-Vorgabe 08.07.).
        [self _exportListsAffectedByEpisodeHashes:[self _transitionEpisodeHashesWithPrevious:previousHash]];
        [self exportStatsSnapshot];
        [WidgetKitHelper reloadNowPlayingTimeline];
        [WidgetKitHelper reloadStatsTimeline];
    });
}

- (NSArray<NSString *> *)_transitionEpisodeHashesWithPrevious:(NSString *)previousHash {
    NSMutableArray *hashes = [NSMutableArray array];
    NSString *currentHash = [PlaybackManager playbackManager].playingEpisode.objectHash;
    if (currentHash.length > 0) {
        [hashes addObject:currentHash];
    }
    if (previousHash.length > 0 && ![previousHash isEqualToString:currentHash]) {
        [hashes addObject:previousHash];
    }
    return hashes;
}

- (void)_feedsDidRefresh:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _invalidateNowPlayingNavigationCache];
        [self exportListsSnapshot];
        [WidgetKitHelper reloadListsTimeline];
    });
}

- (void)_episodesAdded:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _invalidateNowPlayingNavigationCache];
        NSArray<CDEpisode *> *episodes = note.userInfo[@"episodes"];
        [self _updateStatsCacheForAddedEpisodes:episodes];
        // This notification fires once PER FEED during a refresh. Exporting stats + lists and
        // reloading both widget timelines per feed ran several full store fetches while the
        // merges were still writing (store-lock contention = pull-to-refresh stutter). Debounce
        // to one export after the adds settle; _feedsDidRefresh still exports at the end anyway.
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_exportAfterEpisodesAdded) object:nil];
        [self performSelector:@selector(_exportAfterEpisodesAdded) withObject:nil afterDelay:2.0];
    });
}

- (void)_exportAfterEpisodesAdded {
    [self exportStatsSnapshot];
    [self _debouncedListsExport];
    [WidgetKitHelper reloadListsTimeline];
    [WidgetKitHelper reloadStatsTimeline];
}

- (void)_cacheDidFinish:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _invalidateNowPlayingNavigationCache];
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [WidgetKitHelper reloadListsTimeline];
        [WidgetKitHelper reloadStatsTimeline];
    });
}

- (void)_cacheDidClear:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _invalidateNowPlayingNavigationCache];
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [WidgetKitHelper reloadListsTimeline];
        [WidgetKitHelper reloadStatsTimeline];
    });
}

- (void)_playlistDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _invalidateNowPlayingNavigationCache];
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
    [self _invalidateNowPlayingNavigationCache];

    // A handful of updated episodes (consumed/starred toggles) only needs the incremental
    // per-episode export; structural changes (inserts/deletes, feed/list updates, bulk
    // passes like an iCloud states apply) fall back to the throttled full reload.
    NSArray<NSString *> *episodeHashes = [self _episodeHashesForIncrementalUpdateFromNote:note];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (episodeHashes.count > 0) {
            [self _exportListsAffectedByEpisodeHashes:episodeHashes];
            return;
        }
        // Debounce: 3 seconds, fires frequently
        [self.listsDebounceTimer invalidate];
        self.listsDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                  target:self
                                                                selector:@selector(_debouncedListsReload)
                                                                userInfo:nil
                                                                 repeats:NO];
    });
}

// Returns the changed episode hashes when the change set consists ONLY of episode field
// updates (small count), nil when a full lists pass is needed. Must run synchronously to
// the notification (changedValuesForCurrentEvent).
- (NSArray<NSString *> *)_episodeHashesForIncrementalUpdateFromNote:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    if ([info[NSInsertedObjectsKey] count] > 0 || [info[NSDeletedObjectsKey] count] > 0) {
        return nil;
    }

    NSMutableArray *hashes = [NSMutableArray array];
    for (NSManagedObject *obj in info[NSUpdatedObjectsKey]) {
        if ([obj isKindOfClass:[CDList class]] || [obj isKindOfClass:[CDFeed class]]) {
            return nil;
        }
        if ([obj isKindOfClass:[CDEpisode class]]) {
            // Same membership-relevant key filter as _coreDataChangeAffectsLists — episodes
            // dirtied only by e.g. `position` don't need a lists export at all.
            BOOL relevant = NO;
            for (NSString *changedKey in obj.changedValuesForCurrentEvent) {
                if ([[[self class] _relevantEpisodeKeys] containsObject:changedKey]) { relevant = YES; break; }
            }
            if (!relevant) {
                continue;
            }
            NSString *objectHash = ((CDEpisode *)obj).objectHash;
            if (objectHash.length > 0) {
                [hashes addObject:objectHash];
            }
            if (hashes.count > 8) {
                return nil;  // bulk change — one full pass is cheaper than many small ones
            }
        }
    }
    return hashes;
}

+ (NSSet *)_relevantEpisodeKeys {
    static NSSet *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:@"consumed", @"starred", @"archived", @"feed", @"episodeLists", nil];
    });
    return keys;
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
    NSSet *relevantEpisodeKeys = [[self class] _relevantEpisodeKeys];
    NSSet *relevantListFeedKeys = [[self class] _relevantListFeedKeys];
    for (NSManagedObject *obj in info[NSUpdatedObjectsKey]) {
        if ([obj isKindOfClass:[CDList class]] || [obj isKindOfClass:[CDFeed class]]) {
            // Ignore false/no-op updates: Core Data marks list/feed objects dirty during count
            // recalcs, FRC housekeeping, faulting, etc. with an EMPTY (or irrelevant) change set.
            // Those fired a needless lists export every ~30-60s during playback. Require a real
            // membership-relevant key (rename/rank, filter flags, subscribe/park).
            for (NSString *changedKey in obj.changedValuesForCurrentEvent) {
                if ([relevantListFeedKeys containsObject:changedKey]) return YES;
            }
            continue;
        }
        if ([obj isKindOfClass:[CDEpisode class]]) {
            for (NSString *changedKey in obj.changedValuesForCurrentEvent) {
                if ([relevantEpisodeKeys containsObject:changedKey]) return YES;
            }
        }
    }
    return NO;
}

+ (NSSet *)_relevantListFeedKeys {
    static NSSet *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithObjects:
                // CDList / CDEpisodeList / CDSmartPlaylist edits that change what a widget shows
                @"name", @"rank", @"icon", @"query", @"orderBy", @"descending", @"groupByPodcast",
                @"audio", @"video", @"unplayed", @"unfinished", @"played",
                @"starred", @"notStarred", @"downloaded", @"notDownloaded", @"includedFeeds",
                // CDFeed edits that change membership
                @"subscribed", @"parked", @"title", @"rank",
                nil];
    });
    return keys;
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
                [as playEpisode:episode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:[as.episode isEqual:episode]];
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
            [as playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES];
        }
        scheduleDelayedExport = YES;
    } else if ([action isEqualToString:@"previousepisode"]) {
        CDEpisode *previousEpisode = [self _previousEpisodeForPlaybackManager:pm audioSession:as];
        if (previousEpisode) {
            [as playEpisode:previousEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES];
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
    if (![WidgetKitHelper isNowPlayingWidgetInstalled]) return;

    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];

    CDEpisode *episode = pm.playingEpisode;

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"isPaused"] = @(pm.isPaused);
    snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];

    if (episode) {
        NSSet<NSString *> *cachedEpisodeHashes = [CacheManager sharedCacheManager].cachedEpisodeObjectHashes;
        NSMutableDictionary *episodeDict = [[self _episodeDictForEpisode:episode
                                                            withImageSize:kImageSizeMedium
                                                     cachedEpisodeHashes:cachedEpisodeHashes] mutableCopy];
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
        BOOL hasPreviousEpisode = [self _hasPreviousEpisodeForPlaybackManager:pm audioSession:as];
        BOOL hasNextEpisode = [self _hasNextEpisodeForPlaybackManager:pm audioSession:as];
        snapshot[@"hasPreviousEpisode"] = @(hasPreviousEpisode);
        snapshot[@"hasNextEpisode"] = @(hasNextEpisode);

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
}

- (void)_scheduleDebouncedNowPlayingExport {
    if (self.pendingNowPlayingExportBlock) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    __block dispatch_block_t exportBlock = nil;
    exportBlock = dispatch_block_create(0, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            exportBlock = nil;
        });
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
        dispatch_async(dispatch_get_main_queue(), ^{
            exportBlock = nil;
        });
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

- (void)_invalidateNowPlayingNavigationCache {
    self.nowPlayingNavigationGeneration += 1;
    self.hasCachedNowPlayingNavigationState = NO;
    self.cachedNowPlayingEpisodeHash = nil;
}

- (BOOL)_hasNextEpisodeForPlaybackManager:(PlaybackManager *)pm audioSession:(AudioSession *)as {
    CDEpisode *episode = pm.playingEpisode;
    if (!episode) {
        return NO;
    }
    NSString *episodeHash = episode.objectHash ?: episode.guid ?: @"";
    if (self.hasCachedNowPlayingNavigationState &&
        self.cachedNowPlayingNavigationGeneration == self.nowPlayingNavigationGeneration &&
        [self.cachedNowPlayingEpisodeHash isEqualToString:episodeHash]) {
        return self.cachedHasNextEpisode;
    }

    BOOL hasNextEpisode = ([as nextPlayableEpisode] != nil);
    self.cachedNowPlayingEpisodeHash = episodeHash;
    self.cachedNowPlayingNavigationGeneration = self.nowPlayingNavigationGeneration;
    self.cachedHasNextEpisode = hasNextEpisode;
    self.hasCachedNowPlayingNavigationState = YES;
    return hasNextEpisode;
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

#pragma mark - Incremental Lists Export

// Minimal-overhead path (User-Vorgabe 08.07.): a changed episode only re-exports the lists
// it belongs(ed) to — per affected list one SQL count plus one limit-14 fetch — instead of
// scanning every list with every episode on each trigger. Deliberately NOT gated in
// background playback: this IS the cheap path, and playback transitions must reach the
// lists widgets immediately. The full exportListsSnapshot remains as periodic
// reconciliation (startup, backgrounding, feed refresh, foreground flush) and also picks
// up what this path misses by design (episodes newly entering a smart playlist).
- (void)_exportListsAffectedByEpisodeHashes:(NSArray<NSString *> *)episodeHashes {
    if (!self.containerURL || episodeHashes.count == 0) return;
    if (![WidgetKitHelper isSmartListWidgetInstalled]) return;
    NSSet<NSString *> *cachedEpisodeHashes = [CacheManager sharedCacheManager].cachedEpisodeObjectHashes;
    NSSet<NSString *> *requestedEpisodeHashes = [NSSet setWithArray:episodeHashes];

    dispatch_async(self.listsExportQueue, ^{
        CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
        NSMutableArray *writes = [NSMutableArray array];
        NSMutableDictionary *indexPatches = [NSMutableDictionary dictionary];
        __block NSUInteger affectedLists = 0;

        NSManagedObjectContext *backgroundContext = [DMANAGER newExportBackgroundContext];
        [backgroundContext performBlockAndWait:^{
            NSFetchRequest *episodeRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
            episodeRequest.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", requestedEpisodeHashes.allObjects];
            NSArray<CDEpisode *> *episodes = [backgroundContext executeFetchRequest:episodeRequest error:nil] ?: @[];

            NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"List"];
            request.includesSubentities = YES;
            request.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
            NSArray *lists = [backgroundContext executeFetchRequest:request error:nil];

            // Dedupe by uid — same user-facing set as the full pass / the "Lists" menu.
            NSMutableSet *seenUIDs = [NSMutableSet set];

            for (CDList *list in lists) {
                NSString *uid = list.uid;
                if (uid.length == 0 || [seenUIDs containsObject:uid]) continue;
                [seenUIDs addObject:uid];

                NSSet *hashesInFile = [self _episodeHashesInSnapshotFileForListUID:uid];
                BOOL affects = [hashesInFile intersectsSet:requestedEpisodeHashes];
                for (CDEpisode *episode in episodes) {
                    if (affects) break;
                    if ([list isKindOfClass:[CDSmartPlaylist class]]) {
                        continue;  // additions arrive via the reconciliation pass
                    }
                    if ([list isKindOfClass:[CDEpisodeList class]]) {
                        if ([(CDEpisodeList *)list evaluatesEpisodeNow:episode]) {
                            affects = YES;  // episode newly enters the list
                            break;
                        }
                    } else if ([[list sortedEpisodes] containsObject:episode]) {
                        affects = YES;  // manual playlists are small
                        break;
                    }
                }
                if (!affects) continue;

                affectedLists++;
                [self _buildSnapshotForList:list
                                  intoWrites:writes
                                indexPatches:indexPatches
                     cachedEpisodeHashes:cachedEpisodeHashes];
            }
        }];

        for (NSDictionary *entry in writes) {
            [self _writeJSON:entry[@"snapshot"] toFile:entry[@"filename"]];
        }
        [self _patchListsIndexWithEntries:indexPatches];

        if (affectedLists > 0) {
            [WidgetKitHelper reloadListsTimeline];
        }
        [[ICDiagnosticLogger shared] logEvent:@"widget-export"
                                      message:@"Inkrementeller Listen-Export"
                                     metadata:@{ @"episodes": [NSString stringWithFormat:@"%lu", (unsigned long)episodeHashes.count],
                                                 @"affectedLists": [NSString stringWithFormat:@"%lu", (unsigned long)affectedLists],
                                                 @"seconds": [NSString stringWithFormat:@"%.3f", CFAbsoluteTimeGetCurrent() - startTime] }];
    });
}

// One list's index entry + episodes snapshot. Keep in sync with the full pass in
// exportListsSnapshot. Must run inside the background context's queue.
- (void)_buildSnapshotForList:(CDList *)list
                   intoWrites:(NSMutableArray *)writes
                 indexPatches:(NSMutableDictionary *)indexPatches
      cachedEpisodeHashes:(NSSet<NSString *> *)cachedEpisodeHashes {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = list.uid ?: @"";
    d[@"name"] = list.name ?: @"";
    if ([list isKindOfClass:[CDSmartPlaylist class]]) {
        NSString *type = ((CDSmartPlaylist *)list).smartPredicate[@"type"];
        d[@"type"] = type ? [NSString stringWithFormat:@"smart:%@", type] : @"smart";
    } else if ([list isKindOfClass:[CDEpisodeList class]]) {
        d[@"type"] = @"episode_list";
    } else {
        d[@"type"] = @"playlist";
    }

    // Same as the full pass: only the capped episodes, no full numberOfEpisodes count.
    NSMutableArray *episodeDicts = [NSMutableArray array];
    for (CDEpisode *episode in [list sortedEpisodesWithLimit:kMaxEpisodesPerList]) {
        if ((NSInteger)episodeDicts.count >= kMaxEpisodesPerList) break;
        [episodeDicts addObject:[self _episodeDictForEpisode:episode
                                               withImageSize:kImageSizeMedium
                                        cachedEpisodeHashes:cachedEpisodeHashes]];
    }

    d[@"episodeCount"] = @(episodeDicts.count);
    indexPatches[list.uid ?: @""] = d;

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"listId"] = list.uid ?: @"";
    snapshot[@"listName"] = list.name ?: @"";
    snapshot[@"episodes"] = episodeDicts;
    snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];
    [writes addObject:@{ @"filename": [NSString stringWithFormat:@"%@%@.json", kListEpisodesPrefix, list.uid ?: @"unknown"],
                         @"snapshot": snapshot }];
}

// YES when the on-disk snapshot already has the same episodes payload. The per-run `timestamp`
// AND the volatile `position` (playback progress) are ignored: a position tick while you listen
// is NOT a real list change, so a list containing the currently-playing episode must not
// re-write + reload the widget every export (that caused ~90s widget churn during playback).
// Lets the full pass do zero writes when nothing membership-relevant changed.
- (BOOL)_listSnapshotEpisodesUnchanged:(NSDictionary *)snapshot file:(NSString *)filename {
    if (!self.containerURL || filename.length == 0) return NO;
    NSURL *url = [self.containerURL URLByAppendingPathComponent:filename];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return NO;
    NSDictionary *existing = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![existing isKindOfClass:[NSDictionary class]]) return NO;
    NSArray *oldEpisodes = existing[@"episodes"];
    NSArray *newEpisodes = snapshot[@"episodes"];
    if (![oldEpisodes isKindOfClass:[NSArray class]]) return NO;
    BOOL sameName = [(existing[@"listName"] ?: @"") isEqual:(snapshot[@"listName"] ?: @"")];
    return sameName && [[self _episodesForComparison:newEpisodes] isEqualToArray:[self _episodesForComparison:oldEpisodes]];
}

// Copies of the episode dicts with the volatile `position` removed, so only membership-relevant
// changes (episode set, played/starred/downloaded state, title, …) count as "changed".
- (NSArray *)_episodesForComparison:(NSArray *)episodes {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:episodes.count];
    for (id ep in episodes) {
        if ([ep isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *copy = [ep mutableCopy];
            [copy removeObjectForKey:@"position"];
            [out addObject:copy];
        } else {
            [out addObject:ep];
        }
    }
    return out;
}

- (NSSet *)_episodeHashesInSnapshotFileForListUID:(NSString *)listUID {
    if (listUID.length == 0 || !self.containerURL) return [NSSet set];
    NSURL *url = [self.containerURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.json", kListEpisodesPrefix, listUID]];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return [NSSet set];
    NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![snapshot isKindOfClass:[NSDictionary class]]) return [NSSet set];
    NSMutableSet *hashes = [NSMutableSet set];
    for (NSDictionary *episodeDict in snapshot[@"episodes"]) {
        if ([episodeDict isKindOfClass:[NSDictionary class]] && [episodeDict[@"id"] isKindOfClass:[NSString class]]) {
            [hashes addObject:episodeDict[@"id"]];
        }
    }
    return hashes;
}

// Replaces only the entries of re-exported lists inside widget_lists.json. If no index
// exists yet, the next reconciliation pass writes the complete one.
- (void)_patchListsIndexWithEntries:(NSDictionary *)entriesByUID {
    if (entriesByUID.count == 0 || !self.containerURL) return;
    NSURL *url = [self.containerURL URLByAppendingPathComponent:kListsIndexFile];
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSArray *index = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![index isKindOfClass:[NSArray class]]) return;
    NSMutableArray *patched = [NSMutableArray arrayWithCapacity:index.count];
    for (NSDictionary *entry in index) {
        NSDictionary *replacement = [entry isKindOfClass:[NSDictionary class]] ? entriesByUID[entry[@"id"] ?: @""] : nil;
        [patched addObject:replacement ?: entry];
    }
    [self _writeJSON:patched toFile:kListsIndexFile];
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
    // Only the SmartList widget reads the per-list snapshots. If it isn't installed, the whole
    // lists export (the expensive one) never runs — e.g. a user with only the last-played widget.
    if (![WidgetKitHelper isSmartListWidgetInstalled]) return;
    if ([self _deferHeavyListsExportInBackgroundPlayback]) return;

    // Coalesce bursts (a feed refresh posts several triggers) into a single pass: while one
    // export is in flight, just remember another is wanted and run it once afterwards.
    if (self.listsExportRunning) { self.listsExportQueuedAgain = YES; return; }
    self.listsExportRunning = YES;

    BOOL foreground = ([UIApplication sharedApplication].applicationState == UIApplicationStateActive);
    NSSet<NSString *> *cachedEpisodeHashes = [CacheManager sharedCacheManager].cachedEpisodeObjectHashes;
    dispatch_async(self.listsExportQueue, ^{
        CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
        __block CFAbsoluteTime querySeconds = 0, countSeconds = 0, fetchSeconds = 0, imageSeconds = 0;
        __block NSUInteger listCount = 0, episodeCount = 0;
        NSMutableArray *listIndex = [NSMutableArray array];
        NSMutableArray *episodeSnapshots = [NSMutableArray array];
        NSManagedObjectContext *backgroundContext = [DMANAGER newExportBackgroundContext];

        CFAbsoluteTime queryStart = CFAbsoluteTimeGetCurrent();
        [backgroundContext performBlockAndWait:^{
            NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"List"];
            request.includesSubentities = YES;
            request.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
            NSArray *lists = [backgroundContext executeFetchRequest:request error:nil];

            // Only the user-facing lists — the same deduped set the "Lists" menu shows
            // (DMANAGER.lists). The raw store can hold many duplicate/orphan List rows with
            // repeated or nil uids (accumulated over migrations/iCloud sync); processing all
            // of them was the source of "157 lists" and the multi-second export. Dedupe by uid.
            NSMutableSet *seenUIDs = [NSMutableSet set];

            // Episodes are exported only for lists a widget can actually show: the built-in
            // default lists (any widget's fallback/common picks) plus the custom lists a widget is
            // configured to display (recorded by the provider). Every list still appears in the
            // index (the picker lists all of them); only the per-list episode payload is gated.
            NSUserDefaults *sharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.iteconomy.instacastplus"];
            NSSet *displayedListUIDs = [NSSet setWithArray:([sharedDefaults arrayForKey:@"ICWidgetDisplayedListUIDs"] ?: @[])];

            for (CDList *list in lists) {
                NSString *uid = list.uid;
                if (uid.length == 0 || [seenUIDs containsObject:uid]) continue;
                [seenUIDs addObject:uid];

                NSMutableDictionary *d = [NSMutableDictionary dictionary];
                d[@"id"] = uid;
                d[@"name"] = list.name ?: @"";

                if ([list isKindOfClass:[CDSmartPlaylist class]]) {
                    CDSmartPlaylist *smart = (CDSmartPlaylist *)list;
                    NSString *type = smart.smartPredicate[@"type"];
                    d[@"type"] = type ? [NSString stringWithFormat:@"smart:%@", type] : @"smart";
                } else if ([list isKindOfClass:[CDEpisodeList class]]) {
                    d[@"type"] = @"episode_list";
                } else {
                    d[@"type"] = @"playlist";
                }

                BOOL exportEpisodes = [uid hasPrefix:@"default."] || [displayedListUIDs containsObject:uid];
                if (!exportEpisodes) {
                    // Custom list no widget shows → index entry only, no episode fetch/file.
                    d[@"episodeCount"] = @0;
                    [listIndex addObject:d];
                    continue;
                }

                // Fetch only what the widget can show (capped at kMaxEpisodesPerList). We do NOT
                // run the full numberOfEpisodes SQL count anymore (it was the dominant cost and
                // the widget never displays a total > the capped list).
                CFAbsoluteTime fT = CFAbsoluteTimeGetCurrent();
                NSArray *episodes = [list sortedEpisodesWithLimit:kMaxEpisodesPerList];
                fetchSeconds += CFAbsoluteTimeGetCurrent() - fT;

                NSMutableArray *episodeDicts = [NSMutableArray array];
                NSInteger count = 0;
                CFAbsoluteTime iT = CFAbsoluteTimeGetCurrent();
                for (CDEpisode *ep in episodes) {
                    if (count >= kMaxEpisodesPerList) break;
                    [episodeDicts addObject:[self _episodeDictForEpisode:ep
                                                           withImageSize:kImageSizeMedium
                                                    cachedEpisodeHashes:cachedEpisodeHashes]];
                    count++;
                }
                imageSeconds += CFAbsoluteTimeGetCurrent() - iT;
                episodeCount += count;

                d[@"episodeCount"] = @(count);
                [listIndex addObject:d];

                NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
                snapshot[@"listId"] = uid;
                snapshot[@"listName"] = list.name ?: @"";
                snapshot[@"episodes"] = episodeDicts;
                snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];

                NSString *filename = [NSString stringWithFormat:@"%@%@.json", kListEpisodesPrefix, uid];
                [episodeSnapshots addObject:@{ @"filename": filename, @"snapshot": snapshot }];
            }

            // Append every subscribed podcast as a selectable widget option (after the lists,
            // in the same order as the subscriptions list = rank). Only the index entry is
            // written here — the episode payload for a podcast is exported on demand for the
            // podcast+filter a widget is actually configured to show (see
            // _exportConfiguredPodcastSnapshots), keeping the export minimal.
            NSFetchRequest *feedRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
            feedRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
            feedRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES] ];
            NSArray *feeds = [backgroundContext executeFetchRequest:feedRequest error:nil];
            listCount = listIndex.count;  // actual lists only (before podcasts are appended)

            for (CDFeed *feed in feeds) {
                NSString *feedUID = feed.uid;
                if (feedUID.length == 0) continue;
                [listIndex addObject:@{
                    @"id": [NSString stringWithFormat:@"feed:%@", feedUID],
                    @"name": feed.title ?: @"",
                    @"type": @"podcast",
                    @"episodeCount": @0,
                }];
            }
        }];
        querySeconds = CFAbsoluteTimeGetCurrent() - queryStart;

        // Write only lists whose episode content actually changed (the snapshot timestamp is
        // ignored in the comparison). Nothing changed → no file writes at all, matching the
        // "export only when a list really changed" rule.
        CFAbsoluteTime writeStart = CFAbsoluteTimeGetCurrent();
        NSUInteger changedFiles = 0;
        for (NSDictionary *entry in episodeSnapshots) {
            if ([self _listSnapshotEpisodesUnchanged:entry[@"snapshot"] file:entry[@"filename"]]) continue;
            [self _writeJSON:entry[@"snapshot"] toFile:entry[@"filename"]];
            changedFiles++;
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
                                                 @"changed": [NSString stringWithFormat:@"%lu", (unsigned long)changedFiles],
                                                 @"foreground": foreground ? @"1" : @"0" }];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.listsExportRunning = NO;
            if (self.listsExportQueuedAgain) {
                self.listsExportQueuedAgain = NO;
                [self exportListsSnapshot];
            }
        });
    });

    // Also refresh the on-demand podcast snapshots for whatever podcast+filter combos the
    // installed widgets are configured to show (no-op when none are).
    [self _exportConfiguredPodcastSnapshots];
}

// Exports 14 episodes for ONLY the podcast+filter combinations that installed SmartList widgets
// are actually configured to show (via WidgetKitHelper.configuredPodcastSources). A podcast the
// user never selected is never queried — this keeps the "all podcasts selectable" feature from
// exploding into 45×filters exports.
- (void)_exportConfiguredPodcastSnapshots {
    if (!self.containerURL) return;
    if (![WidgetKitHelper isSmartListWidgetInstalled]) return;

    // The SmartList widget records the podcast+filter combos it is configured to show into the
    // App Group defaults (it knows its own config; the app can't read a widget-extension intent
    // type directly). Export episode data ONLY for those combos.
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.iteconomy.instacastplus"];
    NSArray<NSDictionary<NSString *, NSString *> *> *combos = [shared arrayForKey:[WidgetKitHelper requestedPodcastKeysDefaultsKey]];
    NSSet<NSString *> *cachedEpisodeHashes = [[CacheManager sharedCacheManager] cachedEpisodeObjectHashes] ?: [NSSet set];
    {
        if (combos.count == 0) return;
        dispatch_async(self.listsExportQueue, ^{
            NSManagedObjectContext *ctx = [DMANAGER newExportBackgroundContext];
            NSMutableArray *writes = [NSMutableArray array];
            [ctx performBlockAndWait:^{
                for (NSDictionary *combo in combos) {
                    NSString *uid = combo[@"uid"];
                    NSString *filter = combo[@"filter"] ?: @"unplayed";
                    if (uid.length == 0) continue;

                    NSFetchRequest *feedReq = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
                    feedReq.predicate = [NSPredicate predicateWithFormat:@"uid == %@", uid];
                    feedReq.fetchLimit = 1;
                    CDFeed *feed = [[ctx executeFetchRequest:feedReq error:nil] firstObject];
                    if (!feed) continue;

                    NSFetchRequest *epReq = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                    epReq.predicate = [self _predicateForPodcastFilter:filter
                                                               feedUID:uid
                                                   cachedEpisodeHashes:cachedEpisodeHashes];
                    epReq.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"pubDate" ascending:NO] ];
                    epReq.fetchLimit = kMaxEpisodesPerList;
                    NSArray *episodes = [ctx executeFetchRequest:epReq error:nil];

                    NSMutableArray *episodeDicts = [NSMutableArray array];
                    for (CDEpisode *ep in episodes) {
                        [episodeDicts addObject:[self _episodeDictForEpisode:ep
                                                               withImageSize:kImageSizeMedium
                                                        cachedEpisodeHashes:cachedEpisodeHashes]];
                    }

                    NSString *key = [NSString stringWithFormat:@"feed.%@.%@", uid, filter];
                    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
                    snapshot[@"listId"] = key;
                    snapshot[@"listName"] = feed.title ?: @"";
                    snapshot[@"episodes"] = episodeDicts;
                    snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];
                    [writes addObject:@{ @"filename": [NSString stringWithFormat:@"%@%@.json", kListEpisodesPrefix, key],
                                         @"snapshot": snapshot }];
                }
            }];

            NSUInteger changed = 0;
            for (NSDictionary *entry in writes) {
                if ([self _listSnapshotEpisodesUnchanged:entry[@"snapshot"] file:entry[@"filename"]]) continue;
                [self _writeJSON:entry[@"snapshot"] toFile:entry[@"filename"]];
                changed++;
            }
            if (changed > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{ [WidgetKitHelper reloadListsTimeline]; });
            }
        });
    }
}

// Store predicate for a podcast source + filter — mirrors CDEpisodeList's filter semantics.
- (NSPredicate *)_predicateForPodcastFilter:(NSString *)filter
                                    feedUID:(NSString *)uid
                        cachedEpisodeHashes:(NSSet<NSString *> *)cachedEpisodeHashes {
    NSMutableArray *subs = [NSMutableArray array];
    [subs addObject:[NSPredicate predicateWithFormat:@"feed.uid == %@ AND feed.subscribed == YES AND archived == NO", uid]];
    if ([filter isEqualToString:@"unplayed"]) {
        [subs addObject:[NSPredicate predicateWithFormat:@"consumed == NO"]];
    } else if ([filter isEqualToString:@"started"]) {
        [subs addObject:[NSPredicate predicateWithFormat:@"consumed == NO AND position > 0"]];
    } else if ([filter isEqualToString:@"favorites"]) {
        [subs addObject:[NSPredicate predicateWithFormat:@"starred == YES"]];
    } else if ([filter isEqualToString:@"downloaded"]) {
        [subs addObject:[NSPredicate predicateWithFormat:@"objectHash IN %@", cachedEpisodeHashes.allObjects ?: @[]]];
    }
    // "all": latest episodes, no extra filter.
    return [NSCompoundPredicate andPredicateWithSubpredicates:subs];
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

- (void)_installedWidgetsDidChange:(NSNotification *)note {
    // A widget kind was just added. Populate every snapshot — each export self-gates on its
    // own widget kind and skips unchanged files, so this is cheap and only fills what's needed.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self exportListsSnapshot];
        [self exportStatsSnapshot];
        [self exportSettingsSnapshot];
        [WidgetKitHelper reloadAllTimelines];
    });
}

- (void)_flushDeferredExportsOnForeground:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Re-check whether any widgets are installed; the user may have added/removed one
        // while the app was backgrounded. This gates all subsequent export work.
        [WidgetKitHelper refreshInstalledWidgets];
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
    if (![WidgetKitHelper isStatsWidgetInstalled]) return;
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
    if (![WidgetKitHelper isStatsWidgetInstalled]) return;
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
    if (![WidgetKitHelper hasInstalledWidgets]) return;
    NSDictionary *settings = @{
        @"accentColorHex": [self _accentColorHex]
    };
    [self _writeJSON:settings toFile:kSettingsFile];
}

- (NSString *)_accentColorHex {
    UIColor *color = nil;

    // 1. Widget-specific color (if set)
    if (![USER_DEFAULTS boolForKey:WidgetThemeDefaultActive]) {
        color = [UIColor ic_colorFromDefaults:USER_DEFAULTS
                                       hexKey:WidgetThemeColorHexCode
                             legacyArchiveKey:WidgetThemeColorCode];
    }

    // 2. Fallback: Interface color
    if (!color && ![USER_DEFAULTS boolForKey:InterfaceThemeDefaultActive]) {
        color = [UIColor ic_colorFromDefaults:USER_DEFAULTS
                                       hexKey:InterfaceThemeColorHexCode
                             legacyArchiveKey:InterfaceThemeColorCode];
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

- (NSDictionary *)_episodeDictForEpisode:(CDEpisode *)episode
                            withImageSize:(NSInteger)size
                     cachedEpisodeHashes:(NSSet<NSString *> *)cachedEpisodeHashes {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = episode.objectHash ?: @"";
    d[@"title"] = episode.title ?: @"";
    d[@"feedTitle"] = episode.feed.displayTitle ?: episode.feed.title ?: @"";
    d[@"duration"] = @(episode.duration);
    d[@"position"] = @(episode.position);
    d[@"consumed"] = @(episode.consumed);
    d[@"starred"] = @(episode.starred);
    d[@"downloaded"] = @([cachedEpisodeHashes containsObject:episode.objectHash]);

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
    // Stats cache is read only by the Stats widget — don't scan the store if it isn't installed.
    if (![WidgetKitHelper isStatsWidgetInstalled]) return;

    self.statsRefreshInProgress = YES;
    [self _updateStatsDayIfNeededForDate:[NSDate date]];

    NSString *dayKey = [self.cachedStatsDayKey copy];
    NSDate *now = [NSDate date];
    NSDate *startOfToday = [[NSCalendar currentCalendar] startOfDayForDate:now];
    CacheManager *cacheManager = [CacheManager sharedCacheManager];
    NSUInteger downloadedCountSnapshot = cacheManager.cachedEpisodeObjectHashes.count;
    unsigned long long downloadedSizeSnapshot = cacheManager.numberOfDownloadedBytes;

    dispatch_async(self.statsRefreshQueue, ^{
        __block NSUInteger newEpisodesCount = 0;
        __block NSUInteger subscribedCount = 0;
        __block NSUInteger unplayedCount = 0;
        __block NSUInteger downloadedCount = downloadedCountSnapshot;

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

        NSManagedObjectContext *backgroundContext = [DMANAGER newExportBackgroundContext];
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

            }];
        }
        unsigned long long downloadedSizeBytes = downloadedSizeSnapshot;

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
