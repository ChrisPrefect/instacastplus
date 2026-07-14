#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def source_between(source: str, start: str, end: str) -> str:
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


def objc_method(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing method body: {signature}")
        semicolon = source.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method body: {signature}")


episode_loader = read("Classes/Model/EpisodeLoadingManager.m")
subscription_manager = read("Classes/Model/SubscriptionManager.m")
cache_manager = read("Classes/CacheManager.m")
watch_download_manager = read("InstacastWatch/WatchDownloadManager.swift")


queue_pending = objc_method(
    episode_loader,
    "- (void)queuePendingEpisodesForFeed:(CDFeed*)feed",
)
require(
    "_persistNewLoadInfo" in queue_pending
    and "_startNextPendingFeed" in queue_pending
    and queue_pending.index("_persistNewLoadInfo") < queue_pending.index("_startNextPendingFeed"),
    "EpisodeLoadingManager must persist the new immutable payload/cursor before starting background loading.",
)

load_batch = objc_method(
    episode_loader,
    "- (void)_loadNextBatchForFeedURL:(NSString*)feedURL",
)
require(
    "newBackgroundContext" in load_batch
    and "save:&saveError" in load_batch
    and "_persistCursorForLoadInfo" in load_batch
    and load_batch.index("save:&saveError") < load_batch.index("_persistCursorForLoadInfo"),
    "EpisodeLoadingManager must commit the background Core Data batch before advancing its tiny durable cursor.",
)
require(
    load_batch.count("_isCurrentLoadInfo") >= 2,
    "EpisodeLoadingManager must reject canceled/replaced generations before saving or advancing.",
)
require(
    "[USER_DEFAULTS setObject:allLoads" not in episode_loader
    and ".payload.plist" in episode_loader
    and ".cursor.plist" in episode_loader,
    "Episode loading crash recovery must use per-job payload/cursor files, not rewrite the whole queue in defaults.",
)


replace_manifest = source_between(
    watch_download_manager,
    "func replaceManifest(",
    "    func upsertManifest(",
)
require(
    "removeEpisode(hash: episode.episodeHash)" not in replace_manifest
    and "enqueuePendingRemovalHashes(removed.map" in replace_manifest,
    "Watch manifest replacement must retain and queue removed metadata after the atomic store commit.",
)
require(
    "private func processPendingRemovalBatch()" in watch_download_manager
    and "await WatchStorageManager.removeLocalFiles(" in watch_download_manager
    and "context: removalContext" in watch_download_manager
    and "sendDeletionAcknowledgements(for: completedHashes)" in watch_download_manager,
    "Watch manifest replacement must batch local cleanup and durably acknowledge removed entries to the phone.",
)


refresh_feeds = source_between(
    subscription_manager,
    "- (void) refreshFeeds:(NSArray*)feeds etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion",
    "- (void) _finishParsingFeed:",
)
refresh_feed = source_between(
    subscription_manager,
    "- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion",
    "- (void) checkRefreshOperationsTimer:(NSTimer*)timer",
)
require(
    "[eligibleFeeds lastObject] == feed" not in refresh_feeds,
    "Refresh batch completion must not be tied to the last feed object while parser operations are concurrent.",
)
require(
    "__block NSInteger remainingRefreshCompletions = eligibleFeeds.count;" in refresh_feeds
    and "ICSubscriptionManagerRefreshCompletionBlock batchCompletion" in refresh_feeds
    and "remainingRefreshCompletions--" in refresh_feeds
    and "completion(allRefreshesSucceeded, [batchNewEpisodes copy], firstRefreshError);" in refresh_feeds,
    "Refresh batch completion must aggregate every per-feed completion before notifying the caller.",
)
no_url_branch = source_between(
    refresh_feed,
    "NSURL* url = [feed.sourceURL copy];",
    "[self.refreshingFeedURLs addObject:url];",
)
require(
    "if (!url)" in no_url_branch
    and "completion(YES, @[], nil);" in no_url_branch,
    "RefreshFeed must complete skipped feeds with no sourceURL so batch refreshes cannot hang.",
)


cache_episode = objc_method(
    cache_manager,
    "- (BOOL) _cacheEpisode:(CDEpisode*)episode\n             autoCache:(BOOL)autoCache\noverwriteCellularLock:(BOOL)overwriteCellularLock\nreportsFailureToUser:(BOOL)reportsFailureToUser\n             queueRank:(NSNumber*)queueRank",
)
require(
    "CDMedium* media = [episode preferedMedium];" in cache_episode
    and "if (identifier.length == 0)" in cache_episode
    and "if (!media.fileURL)" in cache_episode
    and cache_episode.index("if (identifier.length == 0)") < cache_episode.index("initWithURL:media.fileURL")
    and cache_episode.index("if (!media.fileURL)") < cache_episode.index("initWithURL:media.fileURL"),
    "CacheManager must reject episodes without a real media URL before creating a cache operation.",
)
require(
    "if (!cacheOperation)" in cache_episode
    and cache_episode.index("if (!cacheOperation)") < cache_episode.index("_downloadOperationsByIdentifier[identifier] = cacheOperation"),
    "CacheManager must never enqueue a nil cache operation.",
)


partial_downloads = objc_method(cache_manager, "- (NSArray*) partiallyCachedEpisodes")
require(
    '[[filename pathExtension] isEqualToString:@"part"]' in partial_downloads,
    "Partial download enumeration must only consider .part files.",
)
require(
    'rangeOfString:@" - " options:NSBackwardsSearch' in partial_downloads
    and "substringFromIndex:NSMaxRange(lastDash)" in partial_downloads,
    "Partial download enumeration must extract the object hash from new-style 'Podcast - Episode - hash.ext.part' filenames.",
)


print("App flow logic regression checks passed.")
