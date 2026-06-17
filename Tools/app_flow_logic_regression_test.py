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
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")

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
    "_pendingLoads[feedURL] = loadInfo;" in queue_pending
    and "_saveLoadingState" in queue_pending
    and queue_pending.index("_pendingLoads[feedURL] = loadInfo;") < queue_pending.index("_saveLoadingState")
    and queue_pending.index("_saveLoadingState") < queue_pending.index("_startNextPendingFeed"),
    "EpisodeLoadingManager must persist the newly queued remainder before starting crash-prone background loading.",
)

load_batch = objc_method(
    episode_loader,
    "- (void)_loadNextBatchForFeedURL:(NSString*)feedURL",
)
before_main = load_batch.split("dispatch_async(dispatch_get_main_queue(), ^{", 1)[0]
require(
    "_pendingLoads[feedURL] = updatedInfo;" not in before_main,
    "EpisodeLoadingManager must not remove the active batch from persisted state before the main-context insert succeeds.",
)
after_main = load_batch.split("dispatch_async(dispatch_get_main_queue(), ^{", 1)[1]
require(
    "_pendingLoads[feedURL] = updatedInfo;" in after_main
    and after_main.index("_pendingLoads[feedURL] = updatedInfo;") > after_main.index("[DMANAGER save];"),
    "EpisodeLoadingManager must shrink the in-memory queue only after committing each batch.",
)
save_state = objc_method(episode_loader, "- (void)_saveLoadingState")
require(
    "[USER_DEFAULTS synchronize]" in save_state,
    "Episode loading crash recovery needs the queued state flushed durably, not left only in memory.",
)


replace_manifest = source_between(
    watch_download_manager,
    "func replaceManifest(entries: [WatchManifestEntry]) {",
    "    func upsertManifest(entries: [WatchManifestEntry]) {",
)
require(
    "removeEpisode(hash: episode.episodeHash)" not in replace_manifest
    and "deleteRemovedManifestEpisode(episode)" in replace_manifest,
    "Watch manifest replacement must delete the removed episode object directly after the store has already replaced it.",
)
require(
    "private func deleteRemovedManifestEpisode(_ episode: WatchEpisode)" in watch_download_manager
    and "WatchStorageManager.shared.removeLocalFile(for: episode)" in watch_download_manager
    and 'send(type: "watch.deleted"' in watch_download_manager,
    "Watch manifest replacement must remove local files and acknowledge removed entries to the phone.",
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
    "- (BOOL) _cacheEpisode:(CDEpisode*)episode autoCache:(BOOL)autoCache overwriteCellularLock:(BOOL)overwriteCellularLock",
)
require(
    "CDMedium* media = [episode preferedMedium];" in cache_episode
    and "if (!media.fileURL || episode.objectHash.length == 0)" in cache_episode
    and cache_episode.index("if (!media.fileURL || episode.objectHash.length == 0)") < cache_episode.index("initWithURL:media.fileURL"),
    "CacheManager must reject episodes without a real media URL before creating a cache operation.",
)
require(
    "if (!cacheOperation)" in cache_episode
    and cache_episode.index("if (!cacheOperation)") < cache_episode.index("[_downloadQueue addOperation:cacheOperation]"),
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
