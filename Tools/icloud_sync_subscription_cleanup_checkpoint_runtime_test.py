#!/usr/bin/env python3
"""Deterministic remote-unsubscribe cleanup checkpoint regression coverage."""

import unittest
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
LOCAL_CHANGES = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
DE = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
EN = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


def body(source: str, signature: str) -> str:
    search_from = 0
    while True:
        start = source.find(signature, search_from)
        if start < 0:
            raise AssertionError(f"Missing function: {signature}")
        brace = source.find("{", start)
        semicolon = source.find(";", start)
        if brace >= 0 and (semicolon < 0 or brace < semicolon):
            break
        search_from = start + len(signature)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


@dataclass(frozen=True)
class Snapshot:
    record_name: str
    payload_revision: str
    feed: str


@dataclass(frozen=True)
class CleanupIntent:
    feed: str
    revision: str
    snapshots: tuple[Snapshot, ...]


class PendingStore:
    def __init__(self, snapshots):
        self.payload_by_record = {
            snapshot.record_name: snapshot.payload_revision for snapshot in snapshots
        }
        self.intent_by_feed = {
            snapshot.feed: CleanupIntent(snapshot.feed, "cleanup-r1", (snapshot,))
            for snapshot in snapshots
        }

    def complete_if_unchanged(self, intents):
        for intent in intents:
            if self.intent_by_feed.get(intent.feed) != intent:
                continue
            del self.intent_by_feed[intent.feed]
            for snapshot in intent.snapshots:
                if self.payload_by_record.get(snapshot.record_name) == snapshot.payload_revision:
                    del self.payload_by_record[snapshot.record_name]

    def replace_intent_snapshots_newest_wins(self, feed, snapshots):
        snapshots_by_record = {
            snapshot.record_name: snapshot
            for snapshot in self.intent_by_feed[feed].snapshots
        }
        for snapshot in snapshots:
            snapshots_by_record[snapshot.record_name] = snapshot
        self.intent_by_feed[feed] = CleanupIntent(
            feed,
            "cleanup-r2",
            tuple(snapshots_by_record.values()),
        )


class StartupGarbageCollector:
    @staticmethod
    def delete_unsubscribed(feeds, store):
        protected_feeds = set(store.intent_by_feed)
        return {
            feed: state
            for feed, state in feeds.items()
            if state["subscribed"] or feed in protected_feeds
        }


class ControlledBatchCleanup:
    def __init__(self):
        self.pages = []
        self.subsystem_calls = {
            "cache": 0,
            "up_next": 0,
            "loader": 0,
            "autodownload": 0,
        }
        self.completion = None

    def start(self, feeds, completion):
        self.pages.append(tuple(feeds))
        for subsystem in self.subsystem_calls:
            self.subsystem_calls[subsystem] += 1
        self.completion = completion

    def finish(self, error=None):
        completion, self.completion = self.completion, None
        completion(error)


class CleanupCoordinator:
    def __init__(self, store, cleanup):
        self.store = store
        self.cleanup = cleanup
        self.error = None

    def drain(self, *, sync_enabled, account_verified, online):
        del sync_enabled, account_verified, online
        intents = list(self.store.intent_by_feed.values())
        feeds = list(dict.fromkeys(intent.feed for intent in intents))

        def completed(error):
            self.error = error
            if error is None:
                self.store.complete_if_unchanged(intents)

        self.cleanup.start(feeds, completed)


class StatusCoordinator:
    def __init__(self):
        self.cleanup_status = None
        self.cloud_status = None

    def handle_cleanup_failure(self):
        self.cleanup_status = "cleanup pending"

    def set_cloud_status(self, status):
        self.cloud_status = status

    def status_text(self, *, sync_enabled):
        if self.cleanup_status:
            return self.cleanup_status
        if not sync_enabled:
            return "off"
        return self.cloud_status


class SubscriptionCleanupCheckpointRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.snapshots = [
            Snapshot("subscription:a", "r1", "feed-a"),
            Snapshot("subscription:b", "r1", "feed-b"),
        ]

    def test_one_page_invokes_every_cleanup_subsystem_once(self):
        store = PendingStore(self.snapshots)
        cleanup = ControlledBatchCleanup()
        CleanupCoordinator(store, cleanup).drain(
            sync_enabled=True,
            account_verified=True,
            online=True,
        )

        self.assertEqual(cleanup.pages, [("feed-a", "feed-b")])
        self.assertEqual(
            cleanup.subsystem_calls,
            {"cache": 1, "up_next": 1, "loader": 1, "autodownload": 1},
        )
        self.assertEqual(len(store.payload_by_record), 2)
        self.assertEqual(len(store.intent_by_feed), 2)

    def test_kill_before_completion_keeps_checkpoint_for_idempotent_restart(self):
        store = PendingStore(self.snapshots)
        feeds = {
            "feed-a": {"subscribed": False, "episodes": ("a1", "a2")},
            "feed-b": {"subscribed": False, "episodes": ("b1",)},
        }
        first_cleanup = ControlledBatchCleanup()
        CleanupCoordinator(store, first_cleanup).drain(
            sync_enabled=True,
            account_verified=True,
            online=True,
        )

        # Process death drops the in-memory completion but cannot touch the durable store.
        feeds = StartupGarbageCollector.delete_unsubscribed(feeds, store)
        self.assertEqual(set(feeds), {"feed-a", "feed-b"})
        restarted_cleanup = ControlledBatchCleanup()
        CleanupCoordinator(store, restarted_cleanup).drain(
            sync_enabled=False,
            account_verified=False,
            online=False,
        )
        restarted_cleanup.finish()

        self.assertEqual(restarted_cleanup.pages, [("feed-a", "feed-b")])
        self.assertEqual(store.payload_by_record, {})
        self.assertEqual(store.intent_by_feed, {})
        self.assertEqual(StartupGarbageCollector.delete_unsubscribed(feeds, store), {})

    def test_error_keeps_checkpoint_and_success_removes_only_matching_revision(self):
        store = PendingStore(self.snapshots)
        failed_cleanup = ControlledBatchCleanup()
        coordinator = CleanupCoordinator(store, failed_cleanup)
        coordinator.drain(sync_enabled=False, account_verified=False, online=False)
        failed_cleanup.finish(RuntimeError("disk busy"))
        self.assertEqual(len(store.payload_by_record), 2)
        self.assertEqual(len(store.intent_by_feed), 2)

        store.payload_by_record["subscription:b"] = "r2"
        retry_cleanup = ControlledBatchCleanup()
        CleanupCoordinator(store, retry_cleanup).drain(
            sync_enabled=False,
            account_verified=False,
            online=False,
        )
        retry_cleanup.finish()

        self.assertEqual(store.payload_by_record, {"subscription:b": "r2"})
        self.assertEqual(store.intent_by_feed, {})

    def test_newer_cleanup_intent_survives_older_completion_atomically(self):
        store = PendingStore(self.snapshots)
        cleanup = ControlledBatchCleanup()
        CleanupCoordinator(store, cleanup).drain(
            sync_enabled=True,
            account_verified=True,
            online=True,
        )
        old_feed_a_intent = store.intent_by_feed["feed-a"]
        store.intent_by_feed["feed-a"] = CleanupIntent(
            "feed-a",
            "cleanup-r2",
            old_feed_a_intent.snapshots,
        )
        cleanup.finish()

        self.assertIn("feed-a", store.intent_by_feed)
        self.assertIn("subscription:a", store.payload_by_record)
        self.assertNotIn("feed-b", store.intent_by_feed)
        self.assertNotIn("subscription:b", store.payload_by_record)

    def test_newer_tombstone_payload_replaces_older_intent_generation(self):
        store = PendingStore([self.snapshots[0]])
        newer = Snapshot("subscription:a", "r2", "feed-a")
        store.payload_by_record["subscription:a"] = "r2"
        store.replace_intent_snapshots_newest_wins("feed-a", [newer])

        intent = store.intent_by_feed["feed-a"]
        self.assertEqual(intent.snapshots, (newer,))
        cleanup = ControlledBatchCleanup()
        CleanupCoordinator(store, cleanup).drain(
            sync_enabled=False,
            account_verified=False,
            online=False,
        )
        cleanup.finish()
        self.assertEqual(store.payload_by_record, {})
        self.assertEqual(store.intent_by_feed, {})

    def test_cleanup_failure_survives_cloud_status_changes_while_sync_is_off(self):
        status = StatusCoordinator()
        status.handle_cleanup_failure()
        status.set_cloud_status("ready")

        self.assertEqual(status.status_text(sync_enabled=False), "cleanup pending")

    def test_production_orders_batch_completion_before_snapshot_removal(self):
        self.assertIn("ICCloudSubscriptionCleanupIntentSnapshot", TYPES)
        self.assertIn("hasPendingSubscriptionCleanup", TYPES)
        worker = body(REMOTE, "nonisolated static func applyPendingSubscriptionBatchInBackground(")
        consume = body(REMOTE, "func consumeSubscriptionApplyBatchResult(")
        self.assertIn("persistPendingSubscriptionCleanupIntent", worker)
        self.assertLess(
            worker.index("persistPendingSubscriptionCleanupIntent"),
            worker.index("try context.save()"),
        )
        self.assertIn("drainPendingSubscriptionCleanupIntentsIfNeeded", consume)
        self.assertNotIn("for objectID in unsubscribedFeedObjectIDs", consume)

        persist = body(
            REMOTE,
            "nonisolated static func persistPendingSubscriptionCleanupIntent(",
        )
        self.assertLess(
            persist.index("existingSnapshot.pendingSnapshots"),
            persist.index("for snapshot in pendingSnapshots"),
        )
        self.assertIn("pendingSnapshotsByIdentity[identity] = snapshot", persist)

        drain = body(REMOTE, "func performPendingSubscriptionCleanupIntentDrain(")
        self.assertIn("performUnsubscribeSideEffects(for: unsubscribedFeeds)", drain)
        cleanup_call = drain.index("performUnsubscribeSideEffects(for: unsubscribedFeeds)")
        checkpoint_commit = drain.index(
            "completePendingSubscriptionCleanupIntents(unsubscribedIntents)"
        )
        self.assertLess(cleanup_call, checkpoint_commit)
        self.assertIn("for intent in completedUnsubscribedIntents", drain)
        self.assertLess(
            checkpoint_commit,
            drain.index("for intent in completedUnsubscribedIntents"),
        )
        self.assertIn(
            "completeAutoDownloadsDuringUnsubscribeCleanup(",
            drain[drain.index("for intent in completedUnsubscribedIntents"):],
        )
        self.assertNotIn("RemoteApplyCommitLease", drain)
        self.assertNotIn("acquireICloudAccountTransition", drain)

        completion = body(
            REMOTE,
            "nonisolated static func completePendingSubscriptionCleanupIntents(",
        )
        self.assertIn("localOutboxEntityName", completion)
        self.assertIn("deleteMatchingPendingSubscriptionSnapshots", completion)
        pending_delete = body(
            REMOTE,
            "nonisolated static func deleteMatchingPendingSubscriptionSnapshots(",
        )
        self.assertIn("pendingSubscriptionStateEntityName", pending_delete)
        self.assertEqual(completion.count("try context.save()"), 1)
        self.assertIn("payloadData", completion)
        self.assertIn("revision", completion)

        start = body(
            MANAGER,
            "func startPostInitializationRecoveryLifecycle()",
        )
        cleanup_start = start.index("drainPendingSubscriptionCleanupIntentsIfNeeded")
        sync_gate = start.index("if self.anySyncEnabled")
        self.assertLess(cleanup_start, sync_gate)
        self.assertLess(
            start.index("await self.drainPendingSubscriptionCleanupIntentsIfNeeded"),
            start.index("self.initializeSyncEngineIfNeeded"),
        )
        foreground = body(MANAGER, "@objc func performForegroundSyncIfNeeded()")
        self.assertLess(
            foreground.index("await self.drainPendingSubscriptionCleanupIntentsIfNeeded"),
            foreground.index("self.anySyncEnabled else"),
        )
        self.assertLess(
            foreground.index("await self.drainPendingSubscriptionCleanupIntentsIfNeeded"),
            foreground.index("await self.refreshAccountStatus"),
        )
        self.assertIn("localSubscriptionCleanupTask", MANAGER)
        reset = body(MANAGER, "@objc func prepareForLocalAppResetWithCompletion")
        self.assertIn("localSubscriptionCleanupTask", reset)
        self.assertIn("await cleanupTask.value", reset)
        self.assertIn("localSubscriptionCleanupStatusKey", reset)

        intent_fetch = body(
            REMOTE,
            "nonisolated static func pendingSubscriptionCleanupIntentBatch(",
        )
        self.assertIn("localSubscriptionCleanupAccountRecordName", intent_fetch)
        self.assertIn("localSubscriptionCleanupCategory", intent_fetch)

        local_commit = body(
            LOCAL_CHANGES,
            "nonisolated static func prepareBackgroundLocalOutboxCommit(",
        )
        self.assertIn("category != localSubscriptionCleanupCategory", local_commit)

        cleanup_error = body(
            REMOTE,
            "func handleLocalSubscriptionCleanupFailure(",
        )
        self.assertNotIn("handleLocalPersistenceFailure", cleanup_error)
        self.assertNotIn("requiresSyncEngineStateRollbackAfterPersistenceFailure", cleanup_error)
        self.assertNotIn("scheduleSyncRetryAfterFailure", cleanup_error)
        self.assertIn("localSubscriptionCleanupFailureStatusText", cleanup_error)
        self.assertIn("localSubscriptionCleanupStatusKey", cleanup_error)
        self.assertNotIn("lastErrorKey", cleanup_error)
        status_text = body(MANAGER, "@objc var statusText: String")
        self.assertLess(
            status_text.index("localSubscriptionCleanupStatusKey"),
            status_text.index("if !anySyncEnabled"),
        )
        set_status = body(
            (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text(),
            "func setStatus(_ status: String)",
        )
        self.assertNotIn("localSubscriptionCleanupStatusKey", set_status)
        drain_task = body(
            REMOTE,
            "func drainPendingSubscriptionCleanupIntentsIfNeeded()",
        )
        self.assertIn("if resultError == nil,", drain_task)
        self.assertIn("callerEpoch == localSubscriptionCleanupEpoch", drain_task)
        self.assertIn(
            "callerGeneration <= localSubscriptionCleanupCompletedGeneration",
            drain_task,
        )
        self.assertIn("clearLocalSubscriptionCleanupFailureIfNeeded", drain_task)
        cleanup_status_key = (
            "Abbestellte Podcasts wurden gespeichert, aber ihre lokalen Downloads "
            "konnten noch nicht vollst\u00e4ndig entfernt werden. InstacastPlus versucht "
            "es sp\u00e4ter erneut."
        )
        self.assertIn(f'"{cleanup_status_key}"', DE)
        self.assertIn(f'"{cleanup_status_key}"', EN)

        startup_gc = body(DATABASE, "- (void) _deleteUnsubscribedFeeds")
        self.assertIn("pendingSubscriptionCleanupFeedObjectURIStringsInContext", startup_gc)
        self.assertIn("protectedFeedObjectURIStrings", startup_gc)
        self.assertLess(
            startup_gc.index("protectedFeedObjectURIStrings"),
            startup_gc.index("deleteObject:feed"),
        )

        batch_cleanup = body(SUBSCRIPTIONS, "- (void)performUnsubscribeSideEffectsForFeeds:")
        self.assertEqual(
            batch_cleanup.count(
                "removeCacheForFeedsDuringSubscriptionCleanup:feeds"
            ),
            1,
        )
        self.assertEqual(batch_cleanup.count("resetAutoCacheForFeeds:feeds"), 1)
        self.assertEqual(batch_cleanup.count("eraseEpisodesFromUpNext:"), 1)
        self.assertEqual(batch_cleanup.count("cancelLoadingForFeed:"), 1)
        self.assertEqual(batch_cleanup.count("_removePendingAutoDownloadFeedUIDs:"), 1)

        cache_cleanup = body(CACHE, "- (void)_removeCacheForFeeds:")
        self.assertIn(
            "preserveSubscriptionCleanupDeferredStarts:(BOOL)preserveDeferredStarts",
            CACHE,
        )
        self.assertIn("newICloudSyncBackgroundContext", cache_cleanup)
        self.assertLess(
            cache_cleanup.index("dispatch_get_global_queue(QOS_CLASS_UTILITY"),
            cache_cleanup.index("newICloudSyncBackgroundContext"),
        )
        self.assertNotIn("objectContext executeFetchRequest", cache_cleanup)
        self.assertIn("if (!selectionContext)", cache_cleanup)
        self.assertIn("URIRepresentation", cache_cleanup)
        self.assertGreaterEqual(
            cache_cleanup.count("managedObjectIDForURIRepresentation:"),
            2,
        )
        self.assertIn("cleanupBatchSize = 100", cache_cleanup)
        self.assertIn("MIN(cleanupBatchSize", cache_cleanup)
        self.assertIn(
            "dispatch_async(dispatch_get_main_queue(), processNextChunk)",
            cache_cleanup,
        )
        self.assertNotIn("_cachedURLIndex.allKeys", cache_cleanup)
        self.assertIn("cleanupSelectionHashBatchSize = 400", cache_cleanup)
        self.assertIn("objectHash IN", cache_cleanup)
        self.assertNotIn("downloaded ==", cache_cleanup)
        self.assertEqual(cache_cleanup.count("physicalCacheURLSnapshot"), 1)
        self.assertEqual(
            cache_cleanup.count("ICTranscriptCacheURLSnapshot"),
            1,
        )
        self.assertEqual(
            cache_cleanup.count("ICRemoveTranscriptCacheURLsForEpisodeHashes"),
            1,
        )
        self.assertIn("cleanupTranscriptHashBatchSize = 400", cache_cleanup)
        transcript_snapshot_index = cache_cleanup.index("ICTranscriptCacheURLSnapshot")
        self.assertLess(
            transcript_snapshot_index,
            cache_cleanup.index("removalFinished = YES", transcript_snapshot_index),
        )
        self.assertIn("NSSet<CDFeed*>* feedSet", cache_cleanup)
        self.assertIn("_cancelCachingFeeds:feeds", cache_cleanup)
        self.assertIn(
            "preserveSubscriptionCleanupDeferredStarts:preserveDeferredStarts",
            cache_cleanup,
        )
        self.assertEqual(
            cache_cleanup.count("for (CDEpisode* episode in [self cachedEpisodes])"),
            1,
        )
        self.assertEqual(cache_cleanup.count("_removeCacheRequestsForEpisodes:"), 1)
        physical_delete = body(
            CACHE[CACHE.index("@implementation CacheManager") :],
            "- (void)_performCacheFileDeletionForItems:",
        )
        self.assertIn(
            "if (!physicalURLSnapshot)",
            physical_delete,
        )
        cache_implementation = CACHE[CACHE.index("@implementation CacheManager") :]
        cache_requests = body(
            cache_implementation,
            "- (void)_removeCacheRequestsForEpisodes:",
        )
        active_removal = cache_requests[cache_requests.index("_beginRemovalAfterCancellingEpisode:") :]
        self.assertIn("physicalURLSnapshot:physicalURLSnapshot", active_removal)
        cancelled_finish = body(
            cache_implementation,
            "- (void)_finishCancelledDownloadRemovalForIdentifier:",
        )
        self.assertIn(
            "if (!physicalURLSnapshot)",
            cancelled_finish,
        )
        self.assertIn("NSMutableOrderedSet<NSURL*>* physicalURLs", cancelled_finish)
        self.assertIn(
            "physicalURLSnapshot.URLsByEpisodeHash[identifier]",
            cancelled_finish,
        )
        self.assertIn("for (NSURL* physicalURL in physicalURLs)", cancelled_finish)
        self.assertIn("remainingURL", cancelled_finish)
        transcript_snapshot = body(
            CACHE,
            "static ICTranscriptCacheSnapshot* ICTranscriptCacheURLSnapshot(",
        )
        self.assertEqual(
            transcript_snapshot.count("contentsOfDirectoryAtPath:transcriptCachePath"),
            1,
        )
        history_cleanup = body(CACHE, "- (void)resetAutoCacheForFeeds:")
        self.assertIn("newICloudSyncBackgroundContext", history_cleanup)
        self.assertLess(
            history_cleanup.index("dispatch_get_global_queue(QOS_CLASS_UTILITY"),
            history_cleanup.index("newICloudSyncBackgroundContext"),
        )
        self.assertNotIn("objectContext executeFetchRequest", history_cleanup)
        self.assertIn("if (!selectionContext)", history_cleanup)
        self.assertIn("URIRepresentation", history_cleanup)
        self.assertIn("managedObjectIDForURIRepresentation:", history_cleanup)
        self.assertEqual(history_cleanup.count("executeFetchRequest:"), 1)
        self.assertEqual(history_cleanup.count("resetValuesForEpisodeHashes:"), 1)
        cancel_cleanup = body(CACHE, "- (void)_cancelCachingFeeds:")
        self.assertEqual(cancel_cleanup.count("_clearDownloadErrorsForEpisodeHashes:"), 1)
        self.assertIn("candidateFailedEpisodeHashes", cancel_cleanup)
        self.assertIn(
            "immutableMatchedEpisodeHashes completion:completion",
            cancel_cleanup,
        )
        self.assertNotIn("clearDownloadErrorForEpisode:", cancel_cleanup)


if __name__ == "__main__":
    unittest.main()
