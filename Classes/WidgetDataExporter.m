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
static NSString* const kUpNextFile           = @"widget_upnext.json";
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

// Debounce timers
@property (nonatomic, strong) NSTimer *nowPlayingDebounceTimer;
@property (nonatomic, strong) NSTimer *listsDebounceTimer;
@property (nonatomic, strong) NSTimer *reloadTimelineTimer;

// Listening time tracking
@property (nonatomic, strong) NSDate *lastListeningTimestamp;

// Cache last played episode so widget can show it after playback ends
@property (nonatomic, strong) NSDictionary *lastPlayedEpisodeDict;
@property (nonatomic, strong) NSDictionary *lastPlayedExtraFields;
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
        if (_containerURL) {
            _imagesURL = [_containerURL URLByAppendingPathComponent:kImagesFolder];
            [[NSFileManager defaultManager] createDirectoryAtURL:_imagesURL withIntermediateDirectories:YES attributes:nil error:nil];
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
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_nowPlayingDebounceTimer invalidate];
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
        [self exportUpNextSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_playbackDidEnd:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self exportUpNextSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_playbackDidChangeEpisode:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self exportUpNextSnapshot];
        [self reloadWidgetTimelines];
    });
}

- (void)_playbackDidUpdate:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Debounce: NowPlaying export every 2 seconds
        [self.nowPlayingDebounceTimer invalidate];
        self.nowPlayingDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                                       target:self
                                                                     selector:@selector(_debouncedNowPlayingExport)
                                                                     userInfo:nil
                                                                      repeats:NO];
        // Track listening time (every 10 seconds)
        [self _trackListeningTime];
    });
}

- (void)_episodeDidFinish:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self exportNowPlayingSnapshot];
        [self exportUpNextSnapshot];
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
        [self exportUpNextSnapshot];
        [self _debouncedListsExport];
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
            [pm nextTrack];
        } else if ([action isEqualToString:@"previousepisode"]) {
            [pm previousTrack];
        } else if ([action isEqualToString:@"cyclespeed"]) {
            // Cycle through enabled speeds (uses same logic as player button)
            PlaybackSpeedControl current = pm.speedControl;
            PlaybackSpeedControl next = [PlayerSpeedButton nextEnabledSpeedAfter:current];
            pm.speedControl = next;
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
        } else if ([action isEqualToString:@"skipchapter"]) {
            // Read the target chapter index written by SkipToChapterIntent
            NSURL *skipFileURL = [self.containerURL URLByAppendingPathComponent:@"widget_skip_chapter.txt"];
            NSString *indexStr = [NSString stringWithContentsOfURL:skipFileURL encoding:NSUTF8StringEncoding error:nil];
            NSInteger targetIdx = [indexStr integerValue];
            DebugLog(@"WidgetControlAction: skipchapter → index=%ld (chapters=%lu)", (long)targetIdx, (unsigned long)pm.chapters.count);
            if (targetIdx >= 0 && targetIdx < (NSInteger)pm.chapters.count) {
                pm.currentChapter = targetIdx;
            }
            [[NSFileManager defaultManager] removeItemAtURL:skipFileURL error:nil];
        }

        // Immediate snapshot update + timeline reload + live activity
        DebugLog(@"WidgetControlAction: '%@' — playingEpisode=%@, isPaused=%d, speed=%ld",
                 action, pm.playingEpisode.title, pm.isPaused, (long)pm.speedControl);
        [self exportNowPlayingSnapshot];
        [self exportUpNextSnapshot];
        [WidgetKitHelper reloadAllTimelines];
    });
}

- (void)_debouncedNowPlayingExport {
    [self exportNowPlayingSnapshot];
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
    [self exportUpNextSnapshot];
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
        NSDictionary *episodeDict = [self _episodeDictForEpisode:episode withImageSize:kImageSizeMedium];
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
            }
            snapshot[@"chapterIndex"] = @(idx);
            snapshot[@"chapterCount"] = @(chapters.count);

            // Chapter list for large widget
            NSMutableArray *chapterDicts = [NSMutableArray array];
            NSTimeInterval trackDuration = (NSTimeInterval)episode.duration;
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
                NSString *artFilename = @"chapter_art_current.jpg";
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
        snapshot[@"hasNextEpisode"] = @(as.playlist.count > 0);
        snapshot[@"hasPrevEpisode"] = @NO;  // No playback history tracking available

        // Cache for fallback when playback ends
        self.lastPlayedEpisodeDict = episodeDict;
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
}

#pragma mark - Up Next Export

- (void)exportUpNextSnapshot {
    if (!self.containerURL) return;

    AudioSession *as = [AudioSession sharedAudioSession];
    PlaybackManager *pm = [PlaybackManager playbackManager];

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"isPaused"] = @(pm.isPaused);
    snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];

    CDEpisode *current = pm.playingEpisode;
    if (current) {
        snapshot[@"currentEpisode"] = [self _episodeDictForEpisode:current withImageSize:kImageSizeMedium];
    }

    NSArray *playlist = as.playlist;
    NSMutableArray *queueItems = [NSMutableArray array];
    for (CDEpisode *ep in playlist) {
        if (queueItems.count >= 8) break;
        [queueItems addObject:[self _episodeDictForEpisode:ep withImageSize:kImageSizeMedium]];
    }
    snapshot[@"queue"] = queueItems;

    [self _writeJSON:snapshot toFile:kUpNextFile];
}

#pragma mark - Feeds Export

- (void)exportFeedsSnapshot {
    if (!self.containerURL) return;

    NSArray *feeds = DMANAGER.visibleFeeds;
    NSMutableArray *feedDicts = [NSMutableArray arrayWithCapacity:feeds.count];

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
        NSFetchRequest *epReq = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        epReq.predicate = [NSPredicate predicateWithFormat:@"feed == %@ AND consumed == NO", feed];
        epReq.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"pubDate" ascending:NO]];
        epReq.fetchLimit = 1;
        CDEpisode *latestEpisode = [DMANAGER.objectContext executeFetchRequest:epReq error:nil].firstObject;
        if (!latestEpisode) {
            epReq.predicate = [NSPredicate predicateWithFormat:@"feed == %@", feed];
            epReq.fetchLimit = 1;
            latestEpisode = [DMANAGER.objectContext executeFetchRequest:epReq error:nil].firstObject;
        }
        if (latestEpisode.objectHash) {
            d[@"latestEpisodeHash"] = latestEpisode.objectHash;
        }

        [feedDicts addObject:d];
    }

    [self _writeJSON:feedDicts toFile:kFeedsFile];

    // Cleanup unused images (optional, run periodically)
    // We skip cleanup here to avoid deleting episode images used by other widgets.
}

#pragma mark - Lists Export

- (void)exportListsSnapshot {
    if (!self.containerURL) return;

    NSArray *lists = DMANAGER.lists;
    NSMutableArray *listIndex = [NSMutableArray arrayWithCapacity:lists.count + 1];

    // Add "Up Next" as a virtual list at the beginning
    AudioSession *upNextAS = [AudioSession sharedAudioSession];
    PlaybackManager *pm = [PlaybackManager playbackManager];
    NSArray *playlist = upNextAS.playlist;
    NSDictionary *upNextEntry = @{
        @"id": @"__upnext__",
        @"name": @"Up Next",
        @"type": @"upnext",
        @"episodeCount": @(playlist.count + (pm.playingEpisode ? 1 : 0))
    };
    [listIndex addObject:upNextEntry];
    [self _exportUpNextAsList];

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

- (void)_exportUpNextAsList {
    PlaybackManager *pm = [PlaybackManager playbackManager];
    AudioSession *as = [AudioSession sharedAudioSession];
    NSMutableArray *episodes = [NSMutableArray array];

    if (pm.playingEpisode) {
        [episodes addObject:[self _episodeDictForEpisode:pm.playingEpisode withImageSize:kImageSizeMedium]];
    }
    for (CDEpisode *ep in as.playlist) {
        if ((NSInteger)episodes.count >= kMaxEpisodesPerList) break;
        [episodes addObject:[self _episodeDictForEpisode:ep withImageSize:kImageSizeMedium]];
    }

    NSDictionary *snapshot = @{
        @"listId": @"__upnext__",
        @"listName": @"Up Next",
        @"episodes": episodes,
        @"timestamp": [self _iso8601String:[NSDate date]]
    };
    [self _writeJSON:snapshot toFile:@"widget_list___upnext__.json"];
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

    NSDictionary *listeningLog = [self _readListeningLog];

    // Today
    NSString *todayKey = [self _dateKeyForDate:[NSDate date]];
    double todaySec = [listeningLog[todayKey] doubleValue];

    // This week
    double weekSec = 0;
    NSCalendar *cal = [NSCalendar currentCalendar];
    for (NSInteger i = 0; i < 7; i++) {
        NSDate *day = [cal dateByAddingUnit:NSCalendarUnitDay value:-i toDate:[NSDate date] options:0];
        NSString *key = [self _dateKeyForDate:day];
        weekSec += [listeningLog[key] doubleValue];
    }

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    snapshot[@"listenedTodaySec"] = @(todaySec);
    snapshot[@"listenedWeekSec"] = @(weekSec);
    snapshot[@"downloadedCount"] = @([[CacheManager sharedCacheManager] numberOfCachedEpisodes]);
    snapshot[@"subscribedCount"] = @(DMANAGER.visibleFeeds.count);
    snapshot[@"unplayedCount"] = @(DMANAGER.unplayedList.numberOfEpisodes);
    snapshot[@"timestamp"] = [self _iso8601String:[NSDate date]];

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

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *sourceURL = nil;

    // 1. Try exact requested size via ImageCacheManager
    sourceURL = [ImageCacheManager fileURLToCachedImageForImageURL:imageURL size:size grayscale:NO];
    BOOL step1Exists = sourceURL && [fm fileExistsAtPath:sourceURL.path];
    DebugLog(@"_copyImageForURL: url=%@ size=%ld → step1=%@ exists=%d",
             imageURL.lastPathComponent, (long)size, sourceURL.path, step1Exists);
    if (step1Exists) {
        return [self _doCopyImageFromSource:sourceURL forURL:imageURL size:size];
    }

    // 2. Exact size not found — search for any cached file matching this URL's MD5
    NSString *cacheDir = [DMANAGER.imageCacheURL path];
    DebugLog(@"_copyImageForURL: step2 cacheDir=%@", cacheDir);
    if (!cacheDir) {
        DebugLog(@"_copyImageForURL: DMANAGER.imageCacheURL is nil — cannot search fallback");
        return nil;
    }

    NSString *md5 = [[imageURL absoluteString] MD5Hash];
    NSString *prefix = [NSString stringWithFormat:@"%@_", md5];

    NSArray *files = [fm contentsOfDirectoryAtPath:cacheDir error:nil];
    NSString *bestFile = nil;
    NSInteger bestSize = 0;

    for (NSString *file in files) {
        if ([file hasPrefix:prefix] && [file hasSuffix:@".jpg"] && ![file hasSuffix:@"g.jpg"]) {
            NSString *sizeStr = [[file stringByDeletingPathExtension] substringFromIndex:prefix.length];
            NSInteger fileSize = [sizeStr integerValue];
            if (fileSize > bestSize) {
                bestSize = fileSize;
                bestFile = file;
            }
        }
    }

    if (bestFile) {
        DebugLog(@"_copyImageForURL: found fallback=%@ (size=%ld)", bestFile, (long)bestSize);
        sourceURL = [NSURL fileURLWithPath:[cacheDir stringByAppendingPathComponent:bestFile]];
        return [self _doCopyImageFromSource:sourceURL forURL:imageURL size:size];
    }

    // Neither exact size nor any cached variant found — log ALL files in cacheDir matching any prefix
    // to help diagnose naming/format mismatches
    NSArray *allFiles = [fm contentsOfDirectoryAtPath:cacheDir error:nil];
    NSUInteger totalFiles = allFiles.count;
    DebugLog(@"_copyImageForURL: NO match for md5=%@ prefix=%@ in cacheDir (totalFiles=%lu)",
             md5, prefix, (unsigned long)totalFiles);
    // Log up to 3 sample filenames to see actual naming pattern
    NSUInteger sampleCount = MIN(3, totalFiles);
    for (NSUInteger i = 0; i < sampleCount; i++) {
        DebugLog(@"_copyImageForURL: sample file[%lu]=%@", (unsigned long)i, allFiles[i]);
    }
    return nil;
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

#pragma mark - ISO 8601 Helpers

- (NSString *)_iso8601String:(NSDate *)date {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [fmt stringFromDate:date];
}

@end
