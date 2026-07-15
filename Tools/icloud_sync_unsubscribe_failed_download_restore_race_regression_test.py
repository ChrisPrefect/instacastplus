#!/usr/bin/env python3
"""Pins durable unsubscribe cleanup during cold-start failed-download restoration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start >= 0, f"Missing function: {signature}")
        brace = source.find("{", start)
        require(brace >= 0, f"Missing body: {signature}")
        if source.find(";", start, brace) == -1:
            break
        search_start = brace + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : index]
    raise AssertionError(f"Unterminated function: {signature}")


restore = body(CACHE, "- (void)_restoreFailedDownloads")
cancel_feeds = body(CACHE, "- (void)_cancelCachingFeeds:")
remove_feeds = body(CACHE, "- (void)_removeCacheForFeeds:")
subscription_cleanup = body(SUBSCRIPTIONS, "- (void)performUnsubscribeSideEffectsForFeeds:")
intent_drain = body(REMOTE, "func performPendingSubscriptionCleanupIntentDrain()")

# The launch restore deliberately crosses two queues: persisted sentinels are read
# first, then become visible in `_failedDownloadEpisodes` in a later Main callback.
require(
    "dispatch_async(_failedDownloadPersistenceQueue" in restore
    and "dispatch_async(dispatch_get_main_queue()" in restore,
    "The regression fixture no longer models the cold-start restore race.",
)

# Cleanup must use the sentinel store as its authoritative and naturally small
# source.  Loading every episode hash for a large feed would move thousands of
# irrelevant identities through Core Data and onto Main just to delete a handful
# of `.failed-download` files.
require(
    "dispatch_async(_failedDownloadPersistenceQueue" in cancel_feeds
    and "contentsOfDirectoryAtPath" in cancel_feeds
    and "failed-download" in cancel_feeds,
    "Many-episode unsubscribe cleanup must first discover the actually persisted .failed-download hashes on the serial persistence queue.",
)
sentinel_scan_index = cancel_feeds.index("dispatch_async(_failedDownloadPersistenceQueue")
require(
    "dispatch_get_global_queue(QOS_CLASS_UTILITY" in cancel_feeds
    and "newICloudSyncBackgroundContext" in cancel_feeds
    and sentinel_scan_index < cancel_feeds.index("dispatch_get_global_queue(QOS_CLASS_UTILITY")
    and cancel_feeds.index("dispatch_get_global_queue(QOS_CLASS_UTILITY")
    < cancel_feeds.index("newICloudSyncBackgroundContext"),
    "Persisted failed-download hashes must be intersected with target feeds on the dedicated off-main coordinator.",
)
require(
    "URIRepresentation" in cancel_feeds
    and "managedObjectIDForURIRepresentation:" in cancel_feeds
    and "failedDownloadSelectionHashBatchSize = 400" in cancel_feeds
    and "objectHash IN" in cancel_feeds
    and "objectHash != nil" not in cancel_feeds
    and "propertiesToFetch = @[@\"objectHash\"]" in cancel_feeds,
    "Only persisted sentinel hashes may be matched against target feeds, in bounded 400-hash objectHash IN batches.",
)
require(
    "_failedDownloadEpisodes copy" not in cancel_feeds
    and "_failedDownloadEpisodeHashes copy" in cancel_feeds
    and "feed.episodes" not in cancel_feeds
    and "feed.sortedEpisodes" not in cancel_feeds
    and "_clearDownloadErrorsForEpisodeHashes:" in cancel_feeds,
    "Main must snapshot only the in-memory failure hash index and receive its target-feed intersection, never fault failed or ordinary episode objects.",
)

# The hash cleanup installs mutation generations before deleting on the serial
# persistence queue.  An already-read restore callback therefore cannot publish
# stale state while the durable deletion is in flight.
clear_hashes = body(CACHE, "- (void)_clearDownloadErrorsForEpisodeHashes:")
require(
    "_failedDownloadMutationGenerationsByEpisodeHash[identifier] = clearGeneration" in clear_hashes
    and clear_hashes.index("_failedDownloadMutationGenerationsByEpisodeHash[identifier] = clearGeneration")
    < clear_hashes.index("_deletePersistedFailedDownloadFilesForIdentifiers:"),
    "A restore callback can republish stale failed-download state while unsubscribe deletion is in flight.",
)
require(
    "_deletePersistedFailedDownloadFilesForIdentifiers:" in clear_hashes
    and clear_hashes.index("_deletePersistedFailedDownloadFilesForIdentifiers:")
    < clear_hashes.index("if (completion) completion(error)"),
    "Failed-download cleanup must complete only after durable sentinel deletion.",
)
require(
    "_cancelCachingFeeds:feeds" in remove_feeds
    and "preserveSubscriptionCleanupDeferredStarts:preserveDeferredStarts" in remove_feeds
    and "cancellationFinished = YES" in remove_feeds
    and "if (cancellationFinished && removalFinished && completion)" in remove_feeds
    and "removeCacheForFeedsDuringSubscriptionCleanup:feeds completion:^(NSError* error)" in subscription_cleanup
    and "cacheRemovalFinished = YES" in subscription_cleanup
    and "if (!cacheRemovalFinished || !historyResetFinished) return" in subscription_cleanup,
    "Subscription cleanup must retain the failed-download durability completion.",
)
require(
    intent_drain.index("performUnsubscribeSideEffects(for: unsubscribedFeeds)")
    < intent_drain.index(
        "completePendingSubscriptionCleanupIntents(unsubscribedIntents)"
    ),
    "The iCloud cleanup intent must remain durable until local side effects finish.",
)

print("iCloud unsubscribe cold-start failed-download restore race checks passed")
