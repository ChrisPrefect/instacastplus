#!/usr/bin/env python3
"""Pins transactional, off-main removal of one or many downloaded episodes."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method/function: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
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
    raise AssertionError(f"Unterminated body: {signature}")


remove_one = body(MANAGER, "- (void) removeCacheForEpisode:")
remove_one_with_completion = body(
    MANAGER,
    "- (void) removeCacheForEpisode:(CDEpisode*)episode\n"
    "                      automatic:(BOOL)automatic\n"
    "                     completion:(void (^)(NSError* error))completion",
)
remove_feed = body(MANAGER, "- (void) removeCacheForFeed:")
remove_feed_with_completion = body(
    MANAGER,
    "- (void) removeCacheForFeed:(CDFeed*)feed\n"
    "                   automatic:(BOOL)automatic\n"
    "                  completion:(void (^)(NSError* error))completion",
)
remove_batch = body(
    MANAGER,
    "- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes\n"
    "                       automatic:(BOOL)automatic\n"
    "             physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot\n"
    "                      completion:",
)
perform_files = body(MANAGER, "- (void)_performCacheFileDeletionForItems:")
finish_files = body(MANAGER, "- (void)_finishCacheFileDeletionForItems:")
cache_episode = body(
    MANAGER,
    "- (BOOL) _cacheEpisode:(CDEpisode*)episode\n"
    "             autoCache:(BOOL)autoCache\n"
    "overwriteCellularLock:(BOOL)overwriteCellularLock\n"
    "reportsFailureToUser:(BOOL)reportsFailureToUser\n"
    "             queueRank:(NSNumber*)queueRank\n"
    "preservesConsumedState:(BOOL)preservesConsumedState\n"
    "deferDuringSubscriptionCleanup:(BOOL)deferDuringSubscriptionCleanup",
)
transcripts = body(MANAGER, "static ICTranscriptCacheSnapshot* ICTranscriptCacheURLSnapshot(")

require("completion:nil" in remove_one and "_removeCacheForEpisodes:" in remove_one_with_completion and
        "completion:nil" in remove_feed and "removeCacheForFeeds:feed ? @[feed] : @[]" in remove_feed_with_completion,
        "Single and feed deletion must use the durable public partition and one batch for settled unowned files.")
require("episode.downloaded = NO" in remove_batch and "episode.lastDownloaded = nil" in remove_batch and
        "[_cachedURLIndex removeObjectForKey:" in remove_batch and "saveReturningError" in remove_batch,
        "Logical removal must atomically clear every cache/model index and persist lastDownloaded once.")
require(remove_batch.find('willChangeValueForKey:@"cachedEpisodes"') < remove_batch.find("[_cachedEpisodes removeObject:") <
        remove_batch.find('didChangeValueForKey:@"cachedEpisodes"'),
        "cachedEpisodes KVO must bracket the actual mutation.")
require("dispatch_async(_cacheDeletionQueue" in remove_batch and
        "attributesOfItemAtPath" not in remove_batch and "removeItemAt" not in remove_batch,
        "File sizes, audio deletion, and transcript I/O must run on the serial utility queue.")
require("removeItemAtURL" in perform_files and "error:&mediaRemovalError" in perform_files and
        "ICRemoveTranscriptCacheForEpisodeHashes" in perform_files,
        "Physical deletion must report audio errors and index transcript artifacts once per batch.")
require("existingObjectWithID" in finish_files and "episode.downloaded = restoreAsCached" in finish_files and
        "[_cachedEpisodes addObject:episode]" in finish_files and "_presentCacheDeletionError" in finish_files,
        "A failed audio deletion must restore a still-existing episode instead of leaving model/file divergence.")
require("_cacheDeletionTokensByIdentifier" in cache_episode,
        "A replacement download must not start while the previous file deletion can still win the path race.")
require(transcripts.count("contentsOfDirectoryAtPath") == 1 and "URLsByEpisodeHash" in transcripts and
        "rangeOfString:@\"_\" options:NSBackwardsSearch" in transcripts and "error:&" in transcripts,
        "Feed deletion must scan the transcript directory once, not once per episode.")
require("CDEpisode" not in perform_files and ".feed" not in perform_files,
        "The utility-queue deletion phase must use immutable values, never main-context managed objects.")
require(perform_files.find("temporaryRemovalError") < perform_files.find("mediaRemovalError"),
        "On macOS, a partial-file failure must leave the main audio file intact for truthful rollback.")

print("Download removal state regression checks passed")
