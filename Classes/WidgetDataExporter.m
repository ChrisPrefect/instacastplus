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

#import "InstacastPlus-Swift.h"

// App Group and file constants (must match SharedConstants.swift)
static NSString* const kAppGroupID           = @"group.com.iteconomy.instacastplus";
static NSString* const kNowPlayingFile       = @"widget_nowplaying.json";
static NSString* const kListsIndexFile       = @"widget_lists.json";
static NSString* const kListEpisodesPrefix   = @"widget_list_";
static NSString* const kFeedsFile            = @"widget_feeds.json";
static NSString* const kStatsFile            = @"widget_stats.json";
static NSString* const kSettingsFile          = @"widget_settings.json";
static NSString* const kListeningLogFile     = @"widget_listening_log.plist";
static NSString* const kImagesFolder         = @"WidgetImages";

// Image sizes for widgets
static const NSInteger kImageSizeSmall  = 60;
static const NSInteger kImageSizeMedium = 120;
static const NSInteger kImageSizeGrid   = 160;

// Max episodes per list snapshot
static const NSInteger kMaxEpisodesPerList = 12;

@interface WidgetDataExporter ()
@property (nonatomic, strong) NSURL *containerURL;
@property (nonatomic, strong) NSURL *imagesURL;

// Debounced now-playing export. Uses GCD instead of NSTimer so it still fires while audio keeps the app alive in background.
@property (nonatomic, copy) dispatch_block_t pendingNowPlayingExportBlock;
@property (nonatomic, strong) NSTimer *listsDebounceTimer;
@property (nonatomic, strong) NSTimer *reloadTimelineTimer;

// Listening time tracking
@property (nonatomic, strong) NSDate *lastListeningTimestamp;

// Cached stats values so widget exports stay cheap on the main thread.
@property (nonatomic) NSInteger cachedNewEpisodesTodayCount;
@property (nonatomic, copy) NSString *cachedStatsDayKey;
@property (nonatomic, strong) dispatch_queue_t statsRefreshQueue;
@property (nonatomic) BOOL statsRefreshInProgress;

// Cache last played episode so widget can show it after playback ends
@property (nonatomic, strong) NSDictionary *lastPlayedEpisodeDict;
@property (nonatomic, strong) NSDictionary *lastPlayedExtraFields;

// Track the last exported live playback state to decide when a timeline reload is actually necessary.
@property (nonatomic, copy) NSString *lastNowPlayingEpisodeHash;
@property (nonatomic) BOOL lastNowPlayingPaused;
@property (nonatomic) NSInteger lastNowPlayingChapterIndex;
@property (nonatomic) NSInteger lastNowPlayingChapterCount;
@property (nonatomic) NSInteger lastNowPlayingArtworkIndex;
@property (nonatomic) BOOL lastNowPlayingHasNextEpisode;
@property (nonatomic) NSTimeInterval lastNowPlayingPosition;
@property (nonatomic) NSTimeInterval lastNowPlayingExportWallClock;

- (void)_persistLastPlayedCache;
- (void)_restoreLastPlayedCache;
- (void)_removeLegacyUpNextFiles;
- (void)_restoreStatsCacheFromDisk;
- (void)_refreshStatsCacheInBackgroundWritingSnapshot:(BOOL)writeSnapshot reloadWhenDone:(BOOL)reloadWhenDone;
- (void)_updateStatsDayIfNeededForDate:(NSDate *)date;
- (void)_updateStatsCacheForAddedEpisodes:(NSArray<CDEpisode *> *)episodes;
- (NSDate *)_dateFromISOString:(NSString *)string;
- (NSDictionary<NSManagedObjectID *, CDEpisode *> *)_latestEpisodesByFeedForFeeds:(NSArray<CDFeed *> *)feeds;
- (void)_scheduleDebouncedNowPlayingExport;
- (void)_captureCurrentNowPlayingState;
- (BOOL)_shouldReloadTimelinesForCurrentNowPlayingState;
- (NSURL *)_cachedImageSourceURLForURL:(NSURL *)imageURL requestedSize:(NSInteger)size;
- (NSArray<NSNumber *> *)_candidateSourceImageSizesForRequestedSize:(NSInteger)size;
@end

@implementation WidgetDataExporter

+ (instancetype)sharedExporter {
    // iOS widgets don't work on macOS ("Designed for iPad").
    // Skip entirely to avoid App Group container access triggering TCC dialog.
    if (@available(iOS 14.0, *)) {
        if (NSProcessInfo.processInfo.isiOSAppOnMac) return nil;
    }

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
        DebugLog(@"WidgetDataExporter init: containerURL=%@", _containerURL);
        dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _statsRefreshQueue = dispatch_queue_create("com.instacastplus.widget-stats", queueAttributes);
        _cachedStatsDayKey = [self _dateKeyForDate:[NSDate date]];
        _lastNowPlayingChapterIndex = NSNotFound;
        _lastNowPlayingArtworkIndex = NSNotFound;
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

    // Queue events
    [nc addObserver:self selector:@selector(_playlistDidChange:) name:CDPlaylistDidChangeEpisodesNotification object:nil];

    // Sleep timer
    [nc addObserver:self selector:@selector(_sleepTimerExpired:) name:AudioSessionSleepTimerDidExpireNotification object:nil];

    // Core Data changes (for smart playlist updates)
    [nc addObserver:self selector:@selector(_coreDataDidChange:) name:NSManagedObjectContextObjectsDidChangeNotification object:DMANAGER.objectContext];

    // Widget control actions (from Darwin notifications via WidgetKitHelper)
    [nc addObserver:self selector:@selector(_widgetControlAction:) name:@"WidgetControlActionNotification" object:nil];

    DebugLog(@"WidgetDataExporter: started observing notifications");

    // Initial export so widget config has data immediately
    // (exportAllSnapshots is also called in sceneDidEnterBackground)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportFeedsSnapshot];
        [self exportListsSnapshot];
        [self exportSettingsSnapshot];
        [self exportNowPlayingSnapshot];
        [self exportStatsSnapshot];
        [self reloadWidgetTimelines];
        [self _refreshStatsCacheInBackgroundWritingSnapshot:YES reloadWhenDone:NO];
    });
}

- (void)dealloc {
    [[CacheManager sharedCacheManager] removeObserver:self forKeyPath:@"numberOfDownloadedBytes"];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_pendingNowPlayingExportBlock) {
        dispatch_block_cancel(_pendingNowPlayingExportBlock);
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
        [self reloadWidgetTimelines];
    });
}

- (void)_playbackDidEnd:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [self reloadWidgetTimelines];
    });
}

- (void)_playbackDidChangeEpisode:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [self reloadWidgetTimelines];
    });
}

- (void)_playbackDidUpdate:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _scheduleDebouncedNowPlayingExport];
        // Track listening time (every 10 seconds)
        [self _trackListeningTime];
    });
}

- (void)_episodeDidFinish:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self _persistLastPlayedCache];
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_feedsDidRefresh:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportFeedsSnapshot];
        [self exportListsSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_episodesAdded:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<CDEpisode *> *episodes = note.userInfo[@"episodes"];
        [self _updateStatsCacheForAddedEpisodes:episodes];
        [self exportStatsSnapshot];
        [self _debouncedListsExport];
        [self reloadWidgetTimelines];
    });
}

- (void)_cacheDidFinish:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_cacheDidClear:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _debouncedListsExport];
        [self exportStatsSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_playlistDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_sleepTimerExpired:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_coreDataDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Debounce: 3 seconds, fires frequently
        [self.listsDebounceTimer invalidate];
        self.listsDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                                  target:self
                                                                selector:@selector(_debouncedListsAndFeedsExport)
                                                                userInfo:nil
                                                                 repeats:NO];
    });
}

- (void)_widgetControlAction:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *action = note.userInfo[@"action"];
        if (!action) return;

        PlaybackManager *pm = [PlaybackManager playbackManager];
        AudioSession *as = [AudioSession sharedAudioSession];
        BOOL exportImmediately = NO;
        if ([action isEqualToString:@"playpause"]) {
            [pm playPause];
        } else if ([action isEqualToString:@"skipforward"]) {
            [pm seekForward];
        } else if ([action isEqualToString:@"skipbackward"]) {
            [pm seekBackward];
        } else if ([action isEqualToString:@"nextchapter"]) {
            [pm nextChapter];
        } else if ([action isEqualToString:@"prevchapter"]) {
            [pm previousChapter];
        } else if ([action isEqualToString:@"nextepisode"]) {
            CDEpisode *nextEpisode = [as nextPlayableEpisode];
            if (nextEpisode) {
                [as playEpisode:nextEpisode];
            }
        } else if ([action isEqualToString:@"previousepisode"]) {
            [pm previousTrack];
        } else if ([action isEqualToString:@"cyclespeed"]) {
            // Cycle through enabled speeds (uses same logic as player button)
            PlaybackSpeedControl current = pm.speedControl;
            PlaybackSpeedControl next = [PlayerSpeedButton nextEnabledSpeedAfter:current];
            pm.speedControl = next;
            exportImmediately = YES;
        } else if ([action isEqualToString:@"togglesleeptimer"]) {
            AudioSession *as = [AudioSession sharedAudioSession];
            if (as.timerRemainingTime > 0) {
                // Timer is running → cancel
                as.timerValue = PlaybackStopTimeNoValue;
            } else {
                // No timer → start with last used value or 15 min default
                PlaybackStopTimeValue lastTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                if (lastTimer <= 0) lastTimer = PlaybackStopTime15min;
                as.timerValue = lastTimer;
            }
            exportImmediately = YES;
        } else if ([action isEqualToString:@"skipchapter"]) {
            // Read the target chapter index written by SkipToChapterIntent
            NSURL *skipFileURL = [self.containerURL URLByAppendingPathComponent:@"widget_skip_chapter.txt"];
            NSString *indexStr = [NSString stringWithContentsOfURL:skipFileURL encoding:NSUTF8StringEncoding error:nil];
            NSInteger targetIdx = [indexStr integerValue];
            DebugLog(@"WidgetControlAction: skipchapter → index=%ld (chapters=%lu)", (long)targetIdx, (unsigned long)pm.chapters.count);
            if (targetIdx >= 0 && targetIdx < (NSInteger)pm.chapters.count) {
                ICMetadataChapter *chapter = pm.chapters[targetIdx];
                [pm seekToChapter:chapter];
            }
            [[NSFileManager defaultManager] removeItemAtURL:skipFileURL error:nil];
        }

        // Only export immediately when the state mutation is already synchronous.
        // Seek/chapter/episode changes update asynchronously and would otherwise
        // write a stale snapshot right back into the shared container.
        DebugLog(@"WidgetControlAction: '%@' — playingEpisode=%@, isPaused=%d, speed=%ld",
                 action, pm.playingEpisode.title, pm.isPaused, (long)pm.speedControl);
        if (exportImmediately) {
            [self exportNowPlayingSnapshot];
            [WidgetKitHelper reloadAllTimelines];
        }
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"numberOfDownloadedBytes"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self exportStatsSnapshot];
            [self reloadWidgetTimelines];
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)_debouncedNowPlayingExport {
    BOOL shouldReload = [self _shouldReloadTimelinesForCurrentNowPlayingState];
    [self exportNowPlayingSnapshot];
    if (shouldReload) {
        [self reloadWidgetTimelines];
    }
}

- (void)_debouncedListsExport {
    [self exportListsSnapshot];
}

- (void)_debouncedListsAndFeedsExport {
    [self exportListsSnapshot];
    [self exportFeedsSnapshot];
    [self reloadWidgetTimelines];
}

#pragma mark - Export All

- (void)exportAllSnapshots {
    if (!self.containerURL) return;
    [self exportNowPlayingSnapshot];
    [self _persistLastPlayedCache];
    [self exportFeedsSnapshot];
    [self exportListsSnapshot];
    [self exportStatsSnapshot];
    [self exportSettingsSnapshot];
    [self reloadWidgetTimelines];
}

#pragma mark - Now Playing Export

- (void)exportNowPlayingSnapshot {
    if (!self.containerURL) return;

    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];

    CDEpisode *episode = pm.playingEpisode;
    DebugLog(@"exportNowPlayingSnapshot: episode=%@, isPaused=%d", episode.title, pm.isPaused);

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
        NSArray *chapters = pm.chapters;
        if (chapters.count > 0) {
            NSInteger idx = pm.currentChapter;
            if (idx >= 0 && idx < (NSInteger)chapters.count) {
                ICMetadataChapter *chapter = chapters[idx];
                snapshot[@"chapterTitle"] = chapter.title ?: [NSNull null];
                snapshot[@"chapterIndex"] = @(idx);
            }
            snapshot[@"chapterCount"] = @(chapters.count);

            // Chapter list for large widget
            NSMutableArray *chapterDicts = [NSMutableArray array];
            NSTimeInterval trackDuration = (NSTimeInterval)currentDuration;
            for (ICMetadataChapter *ch in chapters) {
                NSTimeInterval startSec = CMTimeGetSeconds(ch.start);
                NSTimeInterval dur = [ch durationWithTrackDuration:trackDuration];
                [chapterDicts addObject:@{
                    @"title": ch.title ?: @"",
                    @"startTime": @(startSec),
                    @"duration": @(dur)
                }];
            }
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
        snapshot[@"hasNextEpisode"] = ([as nextPlayableEpisode] != nil) ? @YES : @NO;
        snapshot[@"hasPrevEpisode"] = @NO;  // No playback history tracking available

        // Cache for fallback when playback ends.
        self.lastPlayedEpisodeDict = [episodeDict copy];
        NSMutableDictionary *extra = [NSMutableDictionary dictionary];
        extra[@"skipForwardSeconds"] = snapshot[@"skipForwardSeconds"];
        extra[@"skipBackwardSeconds"] = snapshot[@"skipBackwardSeconds"];
        extra[@"playbackSpeed"] = snapshot[@"playbackSpeed"];
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
    [self _captureCurrentNowPlayingState];
}

- (void)_scheduleDebouncedNowPlayingExport {
    if (self.pendingNowPlayingExportBlock) {
        dispatch_block_cancel(self.pendingNowPlayingExportBlock);
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   exportBlock);
}

- (void)_captureCurrentNowPlayingState {
    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];
    CDEpisode *episode = pm.playingEpisode;

    self.lastNowPlayingEpisodeHash = episode.objectHash ?: @"";
    self.lastNowPlayingPaused = (!episode || pm.isPaused);
    self.lastNowPlayingChapterIndex = (episode && pm.currentChapter >= 0 && pm.currentChapter < (NSInteger)pm.chapters.count)
        ? pm.currentChapter
        : NSNotFound;
    self.lastNowPlayingChapterCount = episode ? pm.chapters.count : 0;
    self.lastNowPlayingArtworkIndex = (episode && pm.currentArtwork >= 0 && pm.currentArtwork < (NSInteger)pm.artworks.count)
        ? pm.currentArtwork
        : NSNotFound;
    self.lastNowPlayingHasNextEpisode = ([as nextPlayableEpisode] != nil);
    self.lastNowPlayingPosition = episode ? pm.time : 0;
    self.lastNowPlayingExportWallClock = [[NSDate date] timeIntervalSince1970];
}

- (BOOL)_shouldReloadTimelinesForCurrentNowPlayingState {
    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];
    CDEpisode *episode = pm.playingEpisode;

    NSString *episodeHash = episode.objectHash ?: @"";
    BOOL isPaused = (!episode || pm.isPaused);
    NSInteger chapterIndex = (episode && pm.currentChapter >= 0 && pm.currentChapter < (NSInteger)pm.chapters.count)
        ? pm.currentChapter
        : NSNotFound;
    NSInteger chapterCount = episode ? pm.chapters.count : 0;
    NSInteger artworkIndex = (episode && pm.currentArtwork >= 0 && pm.currentArtwork < (NSInteger)pm.artworks.count)
        ? pm.currentArtwork
        : NSNotFound;
    BOOL hasNextEpisode = ([as nextPlayableEpisode] != nil);
    NSTimeInterval position = episode ? pm.time : 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    BOOL shouldReload = NO;
    if (self.lastNowPlayingExportWallClock > 0) {
        if (![self.lastNowPlayingEpisodeHash isEqualToString:episodeHash] ||
            self.lastNowPlayingPaused != isPaused ||
            self.lastNowPlayingChapterIndex != chapterIndex ||
            self.lastNowPlayingChapterCount != chapterCount ||
            self.lastNowPlayingArtworkIndex != artworkIndex ||
            self.lastNowPlayingHasNextEpisode != hasNextEpisode) {
            shouldReload = YES;
        } else if (episode) {
            NSTimeInterval positionDelta = fabs(position - self.lastNowPlayingPosition);
            NSTimeInterval elapsed = MAX(0, now - self.lastNowPlayingExportWallClock);

            if (isPaused) {
                shouldReload = positionDelta > 1.0;
            } else {
                // Normal playback advances roughly with wall time; a large mismatch means seek/scrub happened.
                shouldReload = fabs(positionDelta - elapsed) > 8.0;
            }
        }
    }

    self.lastNowPlayingEpisodeHash = episodeHash;
    self.lastNowPlayingPaused = isPaused;
    self.lastNowPlayingChapterIndex = chapterIndex;
    self.lastNowPlayingChapterCount = chapterCount;
    self.lastNowPlayingArtworkIndex = artworkIndex;
    self.lastNowPlayingHasNextEpisode = hasNextEpisode;
    self.lastNowPlayingPosition = position;
    self.lastNowPlayingExportWallClock = now;

    return shouldReload;
}

#pragma mark - Feeds Export

- (void)exportFeedsSnapshot {
    if (!self.containerURL) return;

    NSArray *feeds = DMANAGER.visibleFeeds;
    NSMutableArray *feedDicts = [NSMutableArray arrayWithCapacity:feeds.count];
    NSDictionary<NSManagedObjectID *, CDEpisode *> *latestEpisodesByFeedID = [self _latestEpisodesByFeedForFeeds:feeds];

    NSMutableSet *usedImagePaths = [NSMutableSet set];

    for (CDFeed *feed in feeds) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"id"] = feed.uid ?: @"";
        d[@"title"] = feed.displayTitle ?: feed.title ?: @"";
        d[@"unplayedCount"] = @(feed.unplayedCount);
        d[@"rank"] = @(feed.rank);

        if (feed.imageURL) {
            d[@"imageURL"] = feed.imageURL.absoluteString;
            NSString *localPath = [self _copyImageForURL:feed.imageURL size:kImageSizeGrid];
            if (localPath) {
                d[@"localImagePath"] = localPath;
                [usedImagePaths addObject:localPath];
            }
        }

        // Latest episode hash for tap-to-play in PodcastGridWidget
        // Prefer the newest unplayed episode; fall back to newest overall
        CDEpisode *latestEpisode = latestEpisodesByFeedID[feed.objectID];
        if (latestEpisode.objectHash) {
            d[@"latestEpisodeHash"] = latestEpisode.objectHash;
        }

        [feedDicts addObject:d];
    }

    [self _writeJSON:feedDicts toFile:kFeedsFile];

    // Cleanup unused images (optional, run periodically)
    // We skip cleanup here to avoid deleting episode images used by other widgets.
}

- (NSDictionary<NSManagedObjectID *, CDEpisode *> *)_latestEpisodesByFeedForFeeds:(NSArray<CDFeed *> *)feeds {
    if (feeds.count == 0) return @{};

    NSMutableDictionary<NSManagedObjectID *, CDEpisode *> *latestOverallByFeedID = [NSMutableDictionary dictionaryWithCapacity:feeds.count];
    NSMutableDictionary<NSManagedObjectID *, CDEpisode *> *latestUnplayedByFeedID = [NSMutableDictionary dictionaryWithCapacity:feeds.count];
    NSMutableSet<NSManagedObjectID *> *feedsNeedingUnplayed = [NSMutableSet setWithCapacity:feeds.count];
    NSMutableSet<NSManagedObjectID *> *resolvedFeedIDs = [NSMutableSet setWithCapacity:feeds.count];

    for (CDFeed *feed in feeds) {
        if (feed.unplayedCount > 0) {
            [feedsNeedingUnplayed addObject:feed.objectID];
        }
    }

    NSManagedObjectContext *context = DMANAGER.objectContext;
    NSInteger fetchOffset = 0;
    const NSInteger fetchBatchSize = 250;

    while (resolvedFeedIDs.count < feeds.count) {
        NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        request.predicate = [NSPredicate predicateWithFormat:@"feed IN %@", feeds];
        request.sortDescriptors = @[
            [NSSortDescriptor sortDescriptorWithKey:@"pubDate" ascending:NO],
            [NSSortDescriptor sortDescriptorWithKey:@"uid" ascending:NO]
        ];
        request.fetchOffset = fetchOffset;
        request.fetchLimit = fetchBatchSize;
        request.fetchBatchSize = fetchBatchSize;
        request.relationshipKeyPathsForPrefetching = @[@"feed"];

        NSError *error = nil;
        NSArray<CDEpisode *> *episodes = [context executeFetchRequest:request error:&error];
        if (error) {
            DebugLog(@"WidgetDataExporter: feed snapshot fetch failed: %@", error.localizedDescription);
            break;
        }
        if (episodes.count == 0) break;

        for (CDEpisode *episode in episodes) {
            CDFeed *feed = episode.feed;
            if (!feed) continue;

            NSManagedObjectID *feedID = feed.objectID;
            if (!latestOverallByFeedID[feedID]) {
                latestOverallByFeedID[feedID] = episode;
                if (![feedsNeedingUnplayed containsObject:feedID]) {
                    [resolvedFeedIDs addObject:feedID];
                }
            }

            if ([feedsNeedingUnplayed containsObject:feedID] &&
                !latestUnplayedByFeedID[feedID] &&
                !episode.consumed) {
                latestUnplayedByFeedID[feedID] = episode;
                [resolvedFeedIDs addObject:feedID];
            }
        }

        fetchOffset += episodes.count;
        if (episodes.count < fetchBatchSize) break;
    }

    NSMutableDictionary<NSManagedObjectID *, CDEpisode *> *selectedEpisodesByFeedID = [NSMutableDictionary dictionaryWithCapacity:feeds.count];
    for (CDFeed *feed in feeds) {
        NSManagedObjectID *feedID = feed.objectID;
        CDEpisode *selectedEpisode = latestUnplayedByFeedID[feedID];
        if (!selectedEpisode) {
            selectedEpisode = latestOverallByFeedID[feedID];
        }
        if (selectedEpisode) {
            selectedEpisodesByFeedID[feedID] = selectedEpisode;
        }
    }

    return [selectedEpisodesByFeedID copy];
}

#pragma mark - Lists Export

- (void)exportListsSnapshot {
    if (!self.containerURL) return;

    NSArray *lists = DMANAGER.lists;
    NSMutableArray *listIndex = [NSMutableArray arrayWithCapacity:lists.count];

    for (CDList *list in lists) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"id"] = list.uid ?: @"";
        d[@"name"] = list.name ?: @"";
        d[@"episodeCount"] = @(list.numberOfEpisodes);

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

        // Export per-list episode file
        [self _exportEpisodesForList:list];
    }

    [self _writeJSON:listIndex toFile:kListsIndexFile];
}

- (void)_exportEpisodesForList:(CDList *)list {
    NSArray *episodes = list.sortedEpisodes;
    NSMutableArray *episodeDicts = [NSMutableArray array];

    NSInteger count = 0;
    for (CDEpisode *ep in episodes) {
        if (count >= kMaxEpisodesPerList) break;
        [episodeDicts addObject:[self _episodeDictForEpisode:ep withImageSize:kImageSizeMedium]];
        count++;
    }

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"listId"] = list.uid ?: @"";
    snapshot[@"listName"] = list.name ?: @"";
    snapshot[@"episodes"] = episodeDicts;
    snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];

    NSString *filename = [NSString stringWithFormat:@"%@%@.json", kListEpisodesPrefix, list.uid ?: @"unknown"];
    [self _writeJSON:snapshot toFile:filename];
}

#pragma mark - Stats Export

- (void)exportStatsSnapshot {
    if (!self.containerURL) return;
    NSDate *now = [NSDate date];
    [self _updateStatsDayIfNeededForDate:now];

    NSDictionary *listeningLog = [self _readListeningLog];

    // Today
    NSString *todayKey = [self _dateKeyForDate:now];
    double todaySec = [listeningLog[todayKey] doubleValue];

    // This week
    double weekSec = 0;
    NSCalendar *cal = [NSCalendar currentCalendar];
    for (NSInteger i = 0; i < 7; i++) {
        NSDate *day = [cal dateByAddingUnit:NSCalendarUnitDay value:-i toDate:now options:0];
        NSString *key = [self _dateKeyForDate:day];
        weekSec += [listeningLog[key] doubleValue];
    }

    CacheManager *cman = [CacheManager sharedCacheManager];
    NSInteger downloadedCount = [cman numberOfCachedEpisodes];
    unsigned long long downloadedSizeBytes = [cman numberOfDownloadedBytes];

    NSInteger sleepTimerCount = [USER_DEFAULTS integerForKey:@"SleepTimerFellAsleepCount"];

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"listenedTodaySec"] = @(todaySec);
    snapshot[@"listenedWeekSec"] = @(weekSec);
    snapshot[@"downloadedCount"] = @(downloadedCount);
    snapshot[@"downloadedSizeBytes"] = @(downloadedSizeBytes);
    snapshot[@"subscribedCount"] = @(DMANAGER.visibleFeeds.count);
    snapshot[@"unplayedCount"] = @(DMANAGER.unplayedList.numberOfEpisodes);
    snapshot[@"newEpisodesTodayCount"] = @(self.cachedNewEpisodesTodayCount);
    snapshot[@"sleepTimerUsedCount"] = @(sleepTimerCount);
    snapshot[@"timestamp"] = [self _iso8601String:now];

    [self _writeJSON:snapshot toFile:kStatsFile];
}

#pragma mark - Listening Time Tracking

- (void)_trackListeningTime {
    PlaybackManager *pm = [PlaybackManager playbackManager];
    if (pm.isPaused || !pm.playingEpisode) {
        self.lastListeningTimestamp = nil;
        return;
    }

    NSDate *now = [NSDate date];
    if (self.lastListeningTimestamp) {
        NSTimeInterval delta = [now timeIntervalSinceDate:self.lastListeningTimestamp];
        // Only record if delta is reasonable (< 15 seconds, to avoid jumps)
        if (delta > 0 && delta < 15) {
            NSMutableDictionary *log = [[self _readListeningLog] mutableCopy] ?: [NSMutableDictionary dictionary];
            NSString *todayKey = [self _dateKeyForDate:now];
            double current = [log[todayKey] doubleValue];
            log[todayKey] = @(current + delta);

            // Prune entries older than 8 days
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDate *cutoff = [cal dateByAddingUnit:NSCalendarUnitDay value:-8 toDate:now options:0];
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
        }
    }
    self.lastListeningTimestamp = now;
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
    if (@available(iOS 14.0, *)) {
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
}

- (void)_doReloadTimelines {
    [WidgetKitHelper reloadAllTimelines];
    DebugLog(@"WidgetDataExporter: reloaded all widget timelines");
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
    if (!sourceURL) return nil;
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
        [fm copyItemAtURL:sourceURL toURL:destURL error:&error];
        if (error) {
            DebugLog(@"WidgetDataExporter: failed to copy image %@: %@", filename, error.localizedDescription);
            return nil;
        }
    }
    return filename;
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
    NSDate *startOfToday = [[NSCalendar currentCalendar] startOfDayForDate:[NSDate date]];

    dispatch_async(self.statsRefreshQueue, ^{
        __block NSUInteger newEpisodesCount = 0;
        NSManagedObjectContext *backgroundContext = [DMANAGER newBackgroundContext];
        if (backgroundContext) {
            [backgroundContext performBlockAndWait:^{
                NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
                request.predicate = [NSPredicate predicateWithFormat:@"pubDate >= %@ AND feed.subscribed == YES AND archived == NO", startOfToday];
                request.resultType = NSCountResultType;
                NSUInteger count = [backgroundContext countForFetchRequest:request error:nil];
                newEpisodesCount = (count == NSNotFound) ? 0 : count;
            }];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.statsRefreshInProgress = NO;
            if (![self.cachedStatsDayKey isEqualToString:dayKey]) {
                return;
            }

            self.cachedNewEpisodesTodayCount = (NSInteger)newEpisodesCount;

            if (writeSnapshot) {
                [self exportStatsSnapshot];
            }
            if (reloadWhenDone) {
                [self reloadWidgetTimelines];
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

    DebugLog(@"_copyImageForURL: no cached variant for %@ (requestedSize=%ld)", imageURL.lastPathComponent, (long)size);
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
        DebugLog(@"WidgetDataExporter: JSON serialization error for %@: %@", filename, error.localizedDescription);
        return;
    }

    NSURL *fileURL = [self.containerURL URLByAppendingPathComponent:filename];
    BOOL ok = [data writeToURL:fileURL atomically:YES];
    DebugLog(@"WidgetDataExporter: wrote %@ (%lu bytes, success=%d)", filename, (unsigned long)data.length, ok);
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
        DebugLog(@"WidgetDataExporter: restored last played episode '%@' from disk", ep[@"title"]);
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
