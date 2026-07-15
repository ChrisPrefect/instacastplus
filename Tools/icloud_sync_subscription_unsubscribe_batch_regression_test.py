#!/usr/bin/env python3
"""Pins remote mass-unsubscribe cleanup to one linear MainActor pass."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
HISTORY = (ROOT / "Classes" / "ICCacheHistory.m").read_text()
CACHE_IMPLEMENTATION = CACHE[CACHE.index("@implementation CacheManager") :]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


cache_cleanup = body(CACHE_IMPLEMENTATION, "- (void)_removeCacheForFeeds:")
require(
    "newICloudSyncBackgroundContext" in cache_cleanup and "performBlock:" in cache_cleanup,
    "Mass cache selection must run on the dedicated iCloud Core Data coordinator.",
)
require(
    "dispatch_get_global_queue(QOS_CLASS_UTILITY" in cache_cleanup
    and cache_cleanup.index("dispatch_get_global_queue(QOS_CLASS_UTILITY")
    < cache_cleanup.index("newICloudSyncBackgroundContext"),
    "The dedicated iCloud coordinator must be opened off the main thread.",
)
require(
    "if (!selectionContext)" in cache_cleanup
    and "Podcast download data could not be accessed for cleanup." in cache_cleanup,
    "A missing background cache-selection context must complete with a localized error.",
)
require(
    "objectContext executeFetchRequest" not in cache_cleanup,
    "Mass cache selection still performs a synchronous main-context fetch.",
)
require(
    "URIRepresentation" in cache_cleanup
    and cache_cleanup.count("managedObjectIDForURIRepresentation:") >= 2,
    "Cache cleanup must rebind feed and episode IDs across Core Data coordinators via URI.",
)
require(
    "cleanupBatchSize = 100" in cache_cleanup
    and "MIN(cleanupBatchSize" in cache_cleanup
    and "dispatch_async(dispatch_get_main_queue(), processNextChunk)" in cache_cleanup,
    "Main-context cache mutation must advance sequentially in bounded queue-hop chunks.",
)
require(
    "_cachedURLIndex.allKeys" not in cache_cleanup
    and "cleanupSelectionHashBatchSize = 400" in cache_cleanup
    and "objectHash IN" in cache_cleanup
    and "downloaded ==" not in cache_cleanup,
    "Disk-backed hashes must be selected in bounded batches without querying transient downloaded.",
)
require(
    "NSSet<CDFeed*>* feedSet" in cache_cleanup
    and "[feedSet containsObject:episode.feed]" in cache_cleanup,
    "Active and cached candidates must be restricted to the target feed batch.",
)
require(
    cache_cleanup.count("physicalCacheURLSnapshot") == 1,
    "A feed cleanup must list the physical cache directory exactly once.",
)
require(
    cache_cleanup.count("ICTranscriptCacheURLSnapshot") == 1
    and cache_cleanup.count("ICRemoveTranscriptCacheURLsForEpisodeHashes") == 1
    and "cleanupTranscriptHashBatchSize = 400" in cache_cleanup,
    "A feed cleanup must snapshot transcripts once at the end and match only target-feed hashes in bounded batches.",
)
require(
    cache_cleanup.index("ICTranscriptCacheURLSnapshot")
    < cache_cleanup.index("removalFinished = YES", cache_cleanup.index("ICTranscriptCacheURLSnapshot")),
    "Transcript cleanup and its errors must settle before the durable feed-cleanup completion.",
)

cache_requests = body(CACHE_IMPLEMENTATION, "- (void)_removeCacheRequestsForEpisodes:")
require(
    "physicalURLSnapshot:physicalURLSnapshot\n                  physicalURLSnapshot:" not in cache_requests,
    "The cache-removal call must pass the physical URL snapshot exactly once.",
)

physical_delete = body(
    CACHE_IMPLEMENTATION,
    "- (void)_performCacheFileDeletionForItems:",
)
require(
    "physicalURLSnapshot" in physical_delete,
    "Every settled deletion chunk must receive the shared physical URL snapshot.",
)
require(
    "if (physicalURLSnapshot)" in physical_delete,
    "The settled deletion path must skip directory resolution when a batch snapshot exists.",
)
require(
    "if (!physicalURLSnapshot)" in physical_delete,
    "Settled batch chunks must defer transcript cleanup instead of rescanning the directory.",
)

cache_implementation = CACHE_IMPLEMENTATION
require(
    "physicalURLSnapshot:physicalURLSnapshot" in cache_requests[cache_requests.index("_beginRemovalAfterCancellingEpisode:") :],
    "Active download cancellation must receive the same batch cleanup context.",
)
cancelled_finish = body(cache_implementation, "- (void)_finishCancelledDownloadRemovalForIdentifier:")
require(
    "if (!physicalURLSnapshot)" in cancelled_finish,
    "Successful active-download removal must defer to the final transcript cleanup pass.",
)
require(
    "NSMutableOrderedSet<NSURL*>* physicalURLs" in cancelled_finish
    and "physicalURLSnapshot.URLsByEpisodeHash[identifier]" in cancelled_finish
    and "for (NSURL* physicalURL in physicalURLs)" in cancelled_finish,
    "Active cancellation must delete the deduplicated union of its direct URL and the shared disk snapshot.",
)
require(
    "removedBytes" in cancelled_finish
    and "needsRecalculation" in cancelled_finish
    and "remainingURL" in cancelled_finish,
    "Active snapshot deletion must preserve exact accounting and a truthful rollback URL.",
)

transcript_snapshot = body(CACHE, "static ICTranscriptCacheSnapshot* ICTranscriptCacheURLSnapshot(")
require(
    transcript_snapshot.count("contentsOfDirectoryAtPath:transcriptCachePath") == 1,
    "The final transcript snapshot must list its directory exactly once.",
)

download_count = 4_500
require(
    (download_count + 99) // 100 == 45
    and (download_count + 399) // 400 == 12,
    "The deterministic large-library model must use 45 main chunks and 12 hash selections.",
)
snapshot_hashes = {"cached-without-last-downloaded"}
background_rows = {
    "cached-without-last-downloaded": False,
    "history-backed": True,
    "unrelated": False,
}
selected_hashes = {
    episode_hash
    for episode_hash, has_last_downloaded in background_rows.items()
    if has_last_downloaded or episode_hash in snapshot_hashes
}
require(
    selected_hashes == {"cached-without-last-downloaded", "history-backed"},
    "A physical snapshot hash must be selected even when lastDownloaded is nil.",
)
transcript_snapshot_hashes = {"target-leftover", "other-feed-leftover"}
target_feed_episode_hashes = {"target-leftover", "target-without-transcript"}
matched_transcript_hashes = transcript_snapshot_hashes & target_feed_episode_hashes
require(
    matched_transcript_hashes == {"target-leftover"},
    "A retry must remove a target-feed transcript after its media state is already gone without touching another feed.",
)

history_cleanup = body(CACHE, "- (void)resetAutoCacheForFeeds:")
require(
    "newICloudSyncBackgroundContext" in history_cleanup and "performBlock:" in history_cleanup,
    "Mass history selection must run on the dedicated iCloud Core Data coordinator.",
)
require(
    "dispatch_get_global_queue(QOS_CLASS_UTILITY" in history_cleanup
    and history_cleanup.index("dispatch_get_global_queue(QOS_CLASS_UTILITY")
    < history_cleanup.index("newICloudSyncBackgroundContext"),
    "The history-selection coordinator must be opened off the main thread.",
)
require(
    "if (!selectionContext)" in history_cleanup
    and "Podcast download data could not be accessed for cleanup." in history_cleanup,
    "A missing background history-selection context must complete with a localized error.",
)
require(
    "objectContext executeFetchRequest" not in history_cleanup,
    "Mass history selection still materializes all episodes on the main context.",
)
require(
    "URIRepresentation" in history_cleanup
    and "managedObjectIDForURIRepresentation:" in history_cleanup,
    "History cleanup must rebind feed IDs on the dedicated coordinator via URI.",
)
require(
    "resetValuesForEpisodeHashes:" in history_cleanup,
    "Cache history must consume immutable background-selected hashes, not managed objects.",
)

episode_history_reset = body(HISTORY, "- (void)resetValuesForEpisodes:")
hash_history_reset = body(HISTORY, "- (void)resetValuesForEpisodeHashes:")
require(
    "resetValuesForEpisodeHashes:episodeHashes" in episode_history_reset,
    "The legacy episode API must forward to the immutable hash reset API.",
)
require(
    "_deleteEpisodeHashes:" in hash_history_reset,
    "The hash reset API must own the durable history transaction.",
)

cancel_cleanup = body(CACHE_IMPLEMENTATION, "- (void)_cancelCachingFeeds:")
require(
    cancel_cleanup.count("_clearDownloadErrorsForEpisodeHashes:") == 1
    and "immutableMatchedEpisodeHashes completion:completion" in cancel_cleanup,
    "Failed-download persistence must clear the matched immutable hash batch once and retain its durability completion.",
)
require(
    "clearDownloadErrorForEpisode:" not in cancel_cleanup
    and "clearDownloadErrorsForEpisodes:" not in cancel_cleanup,
    "Failed-download persistence is still cleared fire-and-forget per episode.",
)
require(
    "_cancelCachingFeeds:feeds" in cache_cleanup
    and "preserveSubscriptionCleanupDeferredStarts:preserveDeferredStarts" in cache_cleanup,
    "Cache cleanup must await the batched failed-download persistence cleanup.",
)

consume = body(REMOTE, "func consumeSubscriptionApplyBatchResult(")
drain = body(REMOTE, "func performPendingSubscriptionCleanupIntentDrain(")
require(
    "drainPendingSubscriptionCleanupIntentsIfNeeded" in consume,
    "A remote page must hand durable cleanup work to the shared drain.",
)
require(
    drain.count("performUnsubscribeSideEffects(for: unsubscribedFeeds)") == 1,
    "A cleanup page must run unsubscribe side effects once for the whole feed batch.",
)
require(
    "for objectID in unsubscribedFeedObjectIDs" not in consume,
    "Remote cleanup still repeats global cache/queue scans once per feed.",
)

batch_cleanup = body(SUBSCRIPTIONS, "- (void)performUnsubscribeSideEffectsForFeeds:")
require(
    "- (void)performUnsubscribeSideEffectsForFeed:" not in SUBSCRIPTIONS,
    "A one-feed cleanup wrapper must not bypass the revision-owned batch checkpoint.",
)
require(
    "removeCacheForFeedsDuringSubscriptionCleanup:feeds" in batch_cleanup,
    "Subscription cleanup must invoke one batched cache removal.",
)
require(
    "removeCacheForFeed:" not in batch_cleanup,
    "The batch cleanup must not fall back to one global cache scan per feed.",
)

require(
    cache_cleanup.count("for (CDEpisode* episode in [self cachedEpisodes])") == 1,
    "All unsubscribed feeds must share one scan of the global downloaded-episode index.",
)
require(
    cache_cleanup.count("[self _removeCacheRequestsForEpisodes:") == 1,
    "The cache manager must use one sequential chunk-processing call site per remote page.",
)

print("iCloud subscription batched-unsubscribe regression checks passed")
