#!/usr/bin/env python3
"""Pins a single ordered, scalable source of truth for episode downloads."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = SOURCE.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("_downloadOperationsByIdentifier" in SOURCE,
        "Queued operations need a direct identifier index; row updates must not scan NSOperationQueue.")
require("_cachingEpisodeHashes" in SOURCE,
        "Download membership needs a direct hash set instead of repeated episode-array scans.")
require("_scheduledDownloadOperationIdentifiers" in SOURCE,
        "The manager must distinguish ordered pending work from the at-most-three scheduled operations.")

lookup = method_body("- (CACHE_OPERATION_CLASS*) _cacheOperationForEpisode:")
require("_downloadOperationsByIdentifier" in lookup and "_downloadQueue operations" not in lookup,
        "Per-episode download lookup must be O(1).")
membership = method_body("- (BOOL) isCachingEpisode:")
require("_cachingEpisodeHashes" in membership and "for (" not in membership,
        "Per-episode queue membership must be O(1).")

enqueue = method_body("- (BOOL) _cacheEpisode:(CDEpisode*)episode\n             autoCache:(BOOL)autoCache\noverwriteCellularLock:(BOOL)overwriteCellularLock\nreportsFailureToUser:(BOOL)reportsFailureToUser\n             queueRank:(NSNumber*)queueRank")
require("_downloadOperationsByIdentifier" in enqueue and "_persistCachingOperation" in enqueue,
        "An enqueue must enter the authoritative identifier index and persist its own descriptor.")
require("_startNextDownloadOperations" in enqueue and "[_downloadQueue addOperation:cacheOperation]" not in enqueue,
        "Enqueue must let the ordered bounded scheduler choose work, not hand every job to NSOperationQueue.")
owner_lookup = "CACHE_OPERATION_CLASS* existingOperation = _downloadOperationsByIdentifier[identifier];"
require(owner_lookup in enqueue and "return !existingOperation.cancelled;" in enqueue,
        "A tracked identifier must retain exclusive ownership until its terminal callback removes it.")
owner_guard = enqueue.find(owner_lookup)
require(owner_guard < enqueue.find("CACHE_OPERATION_CLASS* cacheOperation") and
        owner_guard < enqueue.find("_downloadOperationsByIdentifier[identifier] = cacheOperation") and
        owner_guard < enqueue.find("_totalOps++"),
        "Cancel/requeue ownership must be decided before allocating or mutating a replacement operation.")

scheduler = method_body("- (void) _startNextDownloadOperations")
require("_scheduledDownloadOperationIdentifiers.count < 3" in scheduler,
        "Only three operations may be handed to NSOperationQueue at once.")
require("for (CDEpisode* episode in _cachingEpisodes)" in scheduler,
        "The visible/persisted order must be the scheduler's pending order.")
require("[_downloadQueue addOperation:nextOperation]" in scheduler,
        "The bounded scheduler must be the sole normal owner of NSOperationQueue insertion.")

require("CachingEpisodeJob." in SOURCE,
        "Each queued job needs an independently addressable persistence key.")
require("- (void) saveCachingEpisodes" not in SOURCE,
        "Queue mutations must not rebuild and serialize the complete remaining queue.")
require("_savedCachingInfosMigratingLegacyIfNeeded" in SOURCE and "CachingEpisodesKey" in SOURCE,
        "Existing ordered queue snapshots need a one-time, order-preserving migration.")
saved_lookup = method_body("- (NSDictionary*) savedCachingInfoForIdentifier:")
require("_savedCachingKeyForIdentifier" in saved_lookup and "for (" not in saved_lookup,
        "Background wake-up must resolve one persisted job directly, not scan every saved job.")

cancel_entry = method_body("- (void) cancelCachingEpisode:")
require("_cancelCachingEpisode:" in cancel_entry,
        "The public cancel entry point must use the central cancellation lifecycle.")
cancel = method_body("- (void)_cancelTrackedDownloadOperationAfterDurableIntent:")
require("_removeTrackedDownloadOperation" in cancel and "_removeSavedCachingInfoForIdentifier" in cancel,
        "After durable cancel intent is committed, a pending cancel must atomically leave runtime and persistent queue state.")
require("_runningOps--" not in cancel,
        "Cancel must not manually decrement a counter that the delayed terminal callback can decrement again.")

finish = method_body("- (void) cacheOperationDidEnd:")
require("_downloadOperationsByIdentifier[operation.identifier] != operation" in finish,
        "A delayed or duplicate terminal callback must be ignored after its tracked transition was handled.")
require("_removeTrackedDownloadOperation" in finish and "_runningOps--" not in finish,
        "Terminal state must be removed once from the authoritative index, not from an independent counter.")

finished_count = method_body("- (NSInteger) finishedOperationCount")
require("_downloadOperationsByIdentifier.count" in finished_count and "_downloadQueue operations" not in finished_count,
        "Finished count must remain bounded and non-negative while NSOperationQueue retires a terminal operation.")

reorder = method_body("- (void) reorderCachingEpisodeFromIndex:")
require("_downloadQueueRanksByIdentifier" in reorder and "_persistCachingOperation" in reorder,
        "A user reorder must update durable scheduler rank, not only the table's array.")
require("_startNextDownloadOperations" in reorder,
        "The ordered scheduler must observe a reorder immediately for the next free slot.")

restore = method_body("- (void) restoreCachingEpisodes")
require("_savedCachingInfosMigratingLegacyIfNeeded" in restore and "sortedArrayUsingComparator" in restore,
        "Restart must restore jobs in their persisted order.")
require("episodesWithObjectHashes:identifiers" in restore and "episodeWithObjectHash:" not in restore,
        "Queue restore must resolve all episodes in one fetch instead of issuing one Core Data query per job.")

background = method_body("- (void) handleEventsForBackgroundURLSession:")
require("_downloadOperationsByIdentifier[identifier]" in background and "_downloadQueue operations" not in background,
        "A background URLSession callback must attach by O(1) identifier lookup.")
require("queueRank:savedInfo[@\"queueRank\"]" in background,
        "A background wake must restore the persisted queue rank instead of appending the job at a new rank.")

require("saveFileIndex" not in SOURCE and "FileIndex.plist" not in SOURCE,
        "The unused full cache index must not be rewritten on startup, import, or every completion.")

print("Download queue scaling regression checks passed")
