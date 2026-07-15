#!/usr/bin/env python3
"""Pins the central cache/stream gate used while subscription cleanup owns a feed."""

import unittest
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
SUBSCRIPTIONS_H = (
    ROOT / "Classes" / "Model" / "SubscriptionManager.h"
).read_text()
CACHE_OPERATION_IOS_H = (ROOT / "Classes" / "CacheOperation_iOS7.h").read_text()
CACHE_OPERATION_MAC_H = (ROOT / "Classes" / "CacheOperation.h").read_text()
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
DOWNLOADS = (ROOT / "Classes" / "DownloadsViewController.m").read_text()
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()


def body(source: str, signature: str) -> str:
    start = -1
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


@dataclass
class Job:
    identifier: str
    feed: str
    automatic: bool
    rank: int
    deferred: bool = False
    scheduled: bool = False


class CleanupAwareQueueModel:
    def __init__(self):
        self.jobs = []
        self.blocked_feeds = set()
        self.persisted = {}
        self.resume_scheduled = False
        self.resume_passes = 0
        self.retry_scans = 0
        self.backup_retries = 0

    def enqueue(self, job):
        job.deferred = job.feed in self.blocked_feeds
        self.jobs.append(job)
        self.persisted[job.identifier] = {
            "automatic": job.automatic,
            "queueRank": job.rank,
        }
        self.schedule()

    def schedule(self):
        active = [job for job in self.jobs if job.scheduled]
        waiting = sorted(
            self.jobs,
            key=lambda job: (job.automatic, job.rank),
        )
        for job in waiting:
            if len(active) >= 3:
                break
            if job.deferred or job.scheduled:
                continue
            job.scheduled = True
            active.append(job)

    def cleanup_cancel(self, feed):
        self.jobs = [
            job for job in self.jobs if job.feed != feed or job.deferred
        ]

    def protection_changed(self):
        self.resume_scheduled = True

    def run_coalesced_resume(self):
        if not self.resume_scheduled:
            return
        self.resume_scheduled = False
        self.resume_passes += 1
        for job in self.jobs:
            if job.feed not in self.blocked_feeds:
                job.deferred = False
        # A newly released manual request receives one of the three slots rather
        # than waiting behind an arbitrary number of automatic jobs.
        waiting_manual = next(
            (job for job in self.jobs if not job.automatic and not job.scheduled),
            None,
        )
        if waiting_manual:
            running_auto = next(
                (job for job in self.jobs if job.automatic and job.scheduled),
                None,
            )
            if running_auto:
                running_auto.scheduled = False
        self.schedule()
        self.retry_scans += 1
        self.backup_retries += 1


class RetryModel:
    def __init__(self):
        self.metadata = {
            "retryAttempt": 2,
            "retryNextEligibleTimestamp": 0,
        }
        self.pending = ["episode-a"]

    def drain(self, blocked):
        before = dict(self.metadata)
        identifier = self.pending.pop(0)
        if blocked:
            self.pending.append(identifier)
            return before
        self.metadata["retryAttempt"] += 1
        return before

    def drain_many(self, blocked_identifiers):
        started = []
        initial_count = len(self.pending)
        for _ in range(initial_count):
            identifier = self.pending.pop(0)
            if identifier in blocked_identifiers:
                self.pending.append(identifier)
            else:
                started.append(identifier)
        return started


class PromotionDrainModel:
    def __init__(self):
        self.pending = []
        self.snapshot = None
        self.requested = False
        self.promoted = []

    def add(self, identifier):
        self.pending.append(identifier)
        self.request_drain()

    def request_drain(self):
        self.requested = True

    def run_one_pass(self):
        if self.snapshot is None:
            self.requested = False
            self.snapshot = list(self.pending)
        for identifier in self.snapshot:
            if identifier in self.pending:
                self.pending.remove(identifier)
                self.promoted.append(identifier)
        self.snapshot = None
        if self.requested:
            self.run_one_pass()


class BatchModel:
    def __init__(self):
        self.total = 1
        self.timer_active = True
        self.normal_jobs = 1
        self.deferred_jobs = 1
        self.end_signals = 0

    def finish_normal(self):
        self.normal_jobs = 0
        self._finish_if_empty()

    def remove_deferred(self):
        self.deferred_jobs = 0
        self._finish_if_empty()

    def _finish_if_empty(self):
        if self.normal_jobs:
            return
        self.timer_active = False
        if self.deferred_jobs or self.total == 0:
            return
        self.total = 0
        self.end_signals += 1


class FinalizingCancellationModel:
    def __init__(self):
        self.finalizing_owner = True
        self.deferred_owner = True
        self.backup_owner = True
        self.prepared_durable_cancellation = False

    def cancel(self):
        if self.backup_owner:
            self.prepared_durable_cancellation = True
            self.backup_owner = False
        self.deferred_owner = False
        return self.finalizing_owner


class MissingEpisodeDeferredCancellationModel:
    def __init__(self):
        self.deferred_descriptor = True
        self.persisted_descriptor = True

    def complete(self):
        self.deferred_descriptor = False
        self.persisted_descriptor = False
        return not self.deferred_descriptor


class CacheManagerSubscriptionCleanupGateTests(unittest.TestCase):
    def test_deferred_manual_job_is_visible_durable_and_gets_a_slot_after_release(self):
        queue = CleanupAwareQueueModel()
        for index in range(3):
            queue.enqueue(Job(f"auto-{index}", "other", True, index + 1))

        queue.blocked_feeds.add("target")
        manual = Job("manual", "target", False, 4)
        queue.enqueue(manual)
        queue.cleanup_cancel("target")
        self.assertIn(manual, queue.jobs)
        self.assertIn("manual", queue.persisted)
        self.assertFalse(manual.scheduled)

        queue.blocked_feeds.remove("target")
        queue.protection_changed()
        queue.protection_changed()
        queue.run_coalesced_resume()
        self.assertTrue(manual.scheduled)
        self.assertEqual(queue.resume_passes, 1)
        self.assertEqual(queue.retry_scans, 1)
        self.assertEqual(queue.backup_retries, 1)

    def test_blocked_retry_keeps_pending_item_and_metadata_unchanged(self):
        retry = RetryModel()
        original = dict(retry.metadata)
        retry.drain(blocked=True)
        self.assertEqual(retry.pending, ["episode-a"])
        self.assertEqual(retry.metadata, original)

    def test_blocked_retry_does_not_starve_an_unprotected_feed(self):
        retry = RetryModel()
        retry.pending = ["blocked-a", "free-b"]
        self.assertEqual(retry.drain_many({"blocked-a"}), ["free-b"])
        self.assertEqual(retry.pending, ["blocked-a"])

        drain = body(CACHE, "- (void)_continueDrainingPendingAutomaticRetries")
        self.assertIn("_automaticRetryDrainRemainingCount", drain)
        gate = drain.index("_subscriptionCleanupBlocksEpisode:episode")
        self.assertNotIn("break;", drain[gate : gate + 250])
        self.assertIn("_automaticRetryDrainContinuationScheduled", drain)

    def test_subscription_manager_exposes_cleanup_only_gate(self):
        self.assertIn(
            "downloadsBlockedDuringUnsubscribeCleanupForFeed:",
            SUBSCRIPTIONS_H,
        )
        self.assertIn(
            "SubscriptionManagerUnsubscribeCleanupProtectionDidChangeNotification",
            SUBSCRIPTIONS_H,
        )
        gate = body(
            SUBSCRIPTIONS,
            "- (BOOL)downloadsBlockedDuringUnsubscribeCleanupForFeed:",
        )
        self.assertIn("unsubscribeCleanupRecoveryBlocked", gate)
        self.assertIn("unsubscribeCleanupProtectionLock", gate)
        self.assertNotIn("!feed.subscribed", gate)
        self.assertNotIn("feed.parked", gate)

    def test_every_cache_and_stream_start_uses_the_central_gate(self):
        cache = body(
            CACHE,
            "deferDuringSubscriptionCleanup:(BOOL)deferDuringSubscriptionCleanup",
        )
        self.assertIn("_subscriptionCleanupBlocksEpisode:episode", cache)
        self.assertIn("_deferDownloadUntilSubscriptionCleanupFinishes", cache)
        self.assertLess(
            cache.index("_deferDownloadUntilSubscriptionCleanupFinishes"),
            cache.index("_cacheDeletionTokensByIdentifier"),
        )

        scheduler = body(CACHE, "- (void) _startNextDownloadOperations")
        self.assertIn("_subscriptionCleanupBlocksEpisode:episode", scheduler)

        stream = body(CACHE, "- (NSString*) beginStreamingCacheForEpisode:")
        self.assertIn("_subscriptionCleanupBlocksEpisode:episode", stream)
        self.assertIn("_deferDownloadUntilSubscriptionCleanupFinishes", stream)
        self.assertLess(
            stream.index("_subscriptionCleanupBlocksEpisode:episode"),
            stream.index("_streamingCacheLeaseTokensByIdentifier[key] = leaseToken"),
        )
        self.assertLess(
            stream.index("_deferDownloadUntilSubscriptionCleanupFinishes"),
            stream.index("_streamingCacheLeaseTokensByIdentifier[key] = leaseToken"),
        )

    def test_cleanup_cancels_old_operations_but_preserves_new_deferred_owner(self):
        cancel_feeds = body(CACHE, "- (void)_cancelCachingFeeds:")
        self.assertIn(
            "_subscriptionCleanupDeferredDownloadInfosByIdentifier",
            cancel_feeds,
        )
        self.assertIn("_cancelTrackedDownloadOperationAfterDurableIntent", cancel_feeds)

    def test_restore_and_background_reattach_do_not_discard_a_deferred_job(self):
        restore = body(CACHE, "- (void) restoreCachingEpisodes")
        self.assertIn("_cacheEpisode:episode", restore)
        self.assertIn("if (!restored)", restore)
        self.assertIn("deferDuringSubscriptionCleanup:NO", restore)

        background = body(
            CACHE,
            "- (void) handleEventsForBackgroundURLSession:",
        )
        deferred_check = background.index(
            "_subscriptionCleanupDeferredDownloadInfosByIdentifier"
        )
        self.assertIn("_cancelOrphanedBackgroundSession:identifier", background)
        self.assertIn(
            "_subscriptionCleanupBackgroundSessionCancellationIdentifiers",
            background,
        )
        self.assertIn("deferDuringSubscriptionCleanup:NO", background)
        remove_saved = background.index("_removeSavedCachingInfoForIdentifier")
        self.assertLess(deferred_check, remove_saved)

        invalidated = body(CACHE, "- (void) URLSession:(NSURLSession*)session didBecomeInvalidWithError:")
        self.assertIn(
            "_subscriptionCleanupBackgroundSessionCancellationIdentifiers",
            invalidated,
        )
        self.assertIn(
            "_resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil",
            invalidated,
        )

    def test_automatic_retry_checks_gate_before_stale_or_metadata_mutation(self):
        scan = body(CACHE, "- (void)_processAutomaticRetryScanChunk")
        scan_gate = scan.index("_subscriptionCleanupBlocksEpisode:episode")
        self.assertLess(
            scan_gate,
            scan.index("_automaticRetryFailureIsStaleForEpisode:episode"),
        )

        drain = body(CACHE, "- (void)_continueDrainingPendingAutomaticRetries")
        drain_gate = drain.index("_subscriptionCleanupBlocksEpisode:episode")
        self.assertLess(
            drain_gate,
            drain.index("_automaticRetryFailureIsStaleForEpisode:episode"),
        )
        self.assertIn("_pendingAutomaticRetryEpisodeHashes addObject:identifier", drain)
        self.assertIn("_automaticRetryDrainRemainingCount", drain)
        self.assertIn("_automaticRetryDrainContinuationScheduled", drain)
        redispatch = drain.index("dispatch_async(dispatch_get_main_queue()")
        self.assertLess(
            drain.index("_automaticRetryDrainRemainingCount > 0"), redispatch
        )

    def test_gate_open_resume_is_coalesced_and_restarts_every_deferred_producer(self):
        resume = body(
            CACHE,
            "- (void)_resumeDownloadsAfterSubscriptionCleanupProtectionChange:",
        )
        self.assertIn("_subscriptionCleanupResumeScheduled", resume)
        self.assertIn("_startNextDownloadOperations", resume)
        self.assertIn("retryFailedAutomaticDownloadsIfPossible", resume)
        self.assertIn("retryPendingDeferredRestoreIfNeeded", resume)
        self.assertIn(
            "_promoteDownloadsDeferredBySubscriptionCleanup",
            resume,
        )

        persist = body(
            CACHE,
            "- (BOOL)_deferDownloadUntilSubscriptionCleanupFinishes:",
        )
        self.assertIn("ICSubscriptionCleanupDeferredDownloadJobKeyPrefix", persist)
        self.assertIn("queueRank", persist)
        self.assertIn("_subscriptionCleanupDeferredDownloadEpisodesByIdentifier", persist)

        finish_batch = body(CACHE, "- (void) _finishDownloadBatchAfterOperation:")
        self.assertIn(
            "_subscriptionCleanupDeferredDownloadInfosByIdentifier.count > 0",
            finish_batch,
        )

    def test_gate_open_only_yields_an_automatic_slot_for_a_promotable_manual_intent(self):
        resume = body(
            CACHE,
            "- (void)_resumeDownloadsAfterSubscriptionCleanupProtectionChange:",
        )
        readiness = resume[
            resume.index("NSUInteger waitingManualCount") :
            resume.index("if (waitingManualCount > 0")
        ]
        for required in (
            "self.suspended",
            'info[@"suspended"]',
            "episode.isDeleted",
            "feed.isDeleted",
            "feed.subscribed || feed.parked",
            "[episode preferedMedium].fileURL",
            "_cacheDeletionTokensByIdentifier",
            "_cacheImportTokensByIdentifier",
            "_subscriptionCleanupBackgroundSessionCancellationIdentifiers",
            "_downloadOperationsByIdentifier",
            "_streamingCacheLeaseTokensByIdentifier",
            "episodeIsCached:episode fastLookup:YES",
        ):
            with self.subTest(required=required):
                self.assertIn(required, readiness)
        self.assertIn("if (waitingManualCount >= 3) break", readiness)

    def test_promotion_drain_cannot_lose_a_request_arriving_during_a_snapshot(self):
        model = PromotionDrainModel()
        model.add("first")
        model.snapshot = list(model.pending)
        model.requested = False
        model.add("second")
        model.run_one_pass()
        self.assertEqual(model.pending, [])
        self.assertEqual(model.promoted, ["first", "second"])

        promote = body(
            CACHE,
            "- (void)_promoteDownloadsDeferredBySubscriptionCleanup",
        )
        resume = body(
            CACHE,
            "- (void)_resumeDownloadsAfterSubscriptionCleanupProtectionChange:",
        )
        self.assertIn("_subscriptionCleanupPromotionRequested", promote)
        self.assertIn("_subscriptionCleanupPromotionRequested", resume)

        deletion_complete = body(
            CACHE,
            "- (void)_completeCacheDeletionForIdentifier:",
        )
        self.assertIn(
            "_resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil",
            deletion_complete,
        )
        import_completion = body(CACHE, "- (void)_importFileAtURL:")
        self.assertIn(
            "_resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil",
            import_completion,
        )
        invalidated = body(
            CACHE,
            "- (void) URLSession:(NSURLSession*)session didBecomeInvalidWithError:",
        )
        self.assertIn(
            "_resumeDownloadsAfterSubscriptionCleanupProtectionChange:nil",
            invalidated,
        )

    def test_removing_last_deferred_owner_finishes_the_held_batch(self):
        model = BatchModel()
        model.finish_normal()
        self.assertEqual(model.total, 1)
        self.assertFalse(model.timer_active)
        self.assertEqual(model.end_signals, 0)
        model.remove_deferred()
        self.assertEqual(model.total, 0)
        self.assertFalse(model.timer_active)
        self.assertEqual(model.end_signals, 1)

        remove = body(
            CACHE,
            "- (void)_removeDownloadDeferredBySubscriptionCleanupForIdentifier:",
        )
        self.assertIn("_finishDownloadBatchAfterOperation:nil", remove)

        finish = body(CACHE, "- (void) _finishDownloadBatchAfterOperation:")
        timer_stop = finish.index("[_updateTimer invalidate]")
        deferred_hold = finish.index(
            "_subscriptionCleanupDeferredDownloadInfosByIdentifier.count > 0"
        )
        self.assertLess(timer_stop, deferred_hold)

    def test_unstarted_background_owner_is_invalidated_before_system_completion(self):
        cancel = body(
            CACHE,
            "- (void)_cancelTrackedDownloadOperationAfterDurableIntent:",
        )
        self.assertIn("_backgroundSessionCompletionHandlers", cancel)
        self.assertIn("_cancelOrphanedBackgroundSession:", cancel)
        self.assertIn(
            "_subscriptionCleanupBackgroundSessionCancellationIdentifiers",
            cancel,
        )
        orphan_cancel = cancel.index("_cancelOrphanedBackgroundSession:")
        system_complete = cancel.index("_completeBackgroundSessionForIdentifier:")
        self.assertLess(orphan_cancel, system_complete)
        self.assertIn("if (mustInvalidateBackgroundSession)", cancel)

        invalidated = body(
            CACHE,
            "- (void) URLSession:(NSURLSession*)session didBecomeInvalidWithError:",
        )
        self.assertLess(
            invalidated.index(
                "_subscriptionCleanupBackgroundSessionCancellationIdentifiers removeObject"
            ),
            invalidated.index("_completeBackgroundSessionForIdentifier:"),
        )

    def test_deferred_streaming_download_preserves_streaming_completion_semantics(self):
        stream = body(CACHE, "- (NSString*) beginStreamingCacheForEpisode:")
        self.assertIn("overwriteCellularLock:YES", stream)
        self.assertIn("preservesConsumedState:YES", stream)

        deferred = body(
            CACHE,
            "- (BOOL)_deferDownloadUntilSubscriptionCleanupFinishes:",
        )
        self.assertIn('@"preservesConsumedState"', deferred)

        promote = body(
            CACHE,
            "- (void)_promoteDownloadsDeferredBySubscriptionCleanup",
        )
        self.assertIn(
            "preservesConsumedState:[info[@\"preservesConsumedState\"] boolValue]",
            promote,
        )

        persist_job = body(CACHE, "- (void) _persistCachingOperation:")
        self.assertIn('@"preservesConsumedState"', persist_job)
        persist_success = body(
            CACHE,
            "- (void)_persistSuccessfulDownloadForOperation:",
        )
        self.assertIn("!operation.preservesConsumedState", persist_success)

        replace = body(CACHE, "- (BOOL)_replaceYieldedDownloadOperation:")
        self.assertIn(
            "replacement.preservesConsumedState = operation.preservesConsumedState",
            replace,
        )
        restore = body(CACHE, "- (void) restoreCachingEpisodes")
        background = body(CACHE, "- (void) handleEventsForBackgroundURLSession:")
        self.assertIn("preservesConsumedState", restore)
        self.assertIn("preservesConsumedState", background)
        self.assertIn("preservesConsumedState", CACHE_OPERATION_IOS_H)
        self.assertIn("preservesConsumedState", CACHE_OPERATION_MAC_H)

    def test_automatic_and_streaming_intents_merge_without_unconsuming_the_episode(self):
        deferred = body(
            CACHE,
            "- (BOOL)_deferDownloadUntilSubscriptionCleanupFinishes:",
        )
        self.assertIn("existingPreservesConsumedState", deferred)
        self.assertIn("requestedPreservesConsumedState", deferred)
        self.assertIn(
            '[existingInfo[@"automatic"] boolValue]',
            deferred,
        )
        self.assertIn("autoCache || preservesConsumedState", deferred)
        self.assertIn(
            "existingPreservesConsumedState && requestedPreservesConsumedState",
            deferred,
        )

        existing_automatic = True
        existing_preserves = False
        requested_automatic = False
        requested_preserves = True
        effective_automatic = existing_automatic and requested_automatic
        effective_preserves = (
            existing_automatic or existing_preserves
        ) and (requested_automatic or requested_preserves)
        self.assertFalse(effective_automatic)
        self.assertTrue(effective_preserves)

    def test_every_direct_unsuspend_path_respects_the_cleanup_gate(self):
        for signature in (
            "- (void) _handleNetworkStatusChanged",
            "- (void) resumeCaching\n",
            "- (void) resumeCachingEpisode:",
            "- (BOOL)_replaceYieldedDownloadOperation:",
        ):
            with self.subTest(signature=signature):
                method = body(CACHE, signature)
                self.assertIn("_subscriptionCleanupBlocksEpisode:", method)

    def test_deferred_only_rows_do_not_expose_invalid_reordering_or_stale_activity(self):
        self.assertIn("canReorderCachingEpisodes", CACHE_H)
        reorder_gate = body(CACHE, "- (BOOL) canReorderCachingEpisodes")
        self.assertIn(
            "_subscriptionCleanupDeferredDownloadInfosByIdentifier.count == 0",
            reorder_gate,
        )
        self.assertIn("_streamingCacheLeaseTokensByIdentifier.count == 0", reorder_gate)

        can_move = body(
            DOWNLOADS,
            "- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:",
        )
        target = body(
            DOWNLOADS,
            "- (NSIndexPath*)tableView:(UITableView*)tableView targetIndexPathForMoveFromRowAtIndexPath:",
        )
        self.assertIn("canReorderCachingEpisodes", can_move)
        self.assertIn("canReorderCachingEpisodes", target)

        finish = body(CACHE, "- (void) _finishDownloadBatchAfterOperation:")
        deferred_hold = finish.index(
            "_subscriptionCleanupDeferredDownloadInfosByIdentifier.count > 0"
        )
        for reset in ("_rateDate = nil", "_rateBytes = 0", "self.rate = 0"):
            self.assertIn(reset, finish)
            self.assertLess(finish.index(reset), deferred_hold)

        suspended = body(CACHE, "- (BOOL) isLoadingEpisodeSuspended:")
        self.assertIn(
            "_subscriptionCleanupDeferredDownloadInfosByIdentifier",
            suspended,
        )
        self.assertIn("self.suspended", suspended)

    def test_cancel_during_old_owner_finalization_removes_the_new_deferred_owner(self):
        model = FinalizingCancellationModel()
        waits_for_finalization = model.cancel()
        self.assertTrue(model.prepared_durable_cancellation)
        self.assertFalse(model.backup_owner)
        self.assertFalse(model.deferred_owner)
        self.assertTrue(waits_for_finalization)

        cancel = body(CACHE, "- (void)_cancelCachingEpisode:")
        durable_owner = cancel.index(
            "ownsDeferredDownloadWithObjectHash:identifier"
        )
        self.assertNotIn(
            "return;",
            cancel[:durable_owner],
            "A finalizing old owner must not bypass durable cancellation of a "
            "separate deferred owner.",
        )
        self.assertIn("_finalizingDownloadOperationIdentifiers", cancel)

        after_durable_intent = body(
            CACHE,
            "- (void)_cancelCachingEpisodeAfterDurableIntent:",
        )
        remove_deferred = after_durable_intent.index(
            "_removeDownloadDeferredBySubscriptionCleanupForIdentifier:"
        )
        finalizing_check = after_durable_intent.index(
            "_finalizingDownloadOperationIdentifiers"
        )
        self.assertLess(remove_deferred, finalizing_check)
        self.assertIn("!operationIsFinalizing", after_durable_intent)

    def test_paused_deferred_owner_stays_paused_when_the_old_owner_is_removed(self):
        deferred = body(
            CACHE,
            "- (BOOL)_deferDownloadUntilSubscriptionCleanupFinishes:",
        )
        self.assertIn("effectiveSuspended", deferred)
        self.assertIn('existingInfo[@"suspended"]', deferred)

        promote = body(
            CACHE,
            "- (void)_promoteDownloadsDeferredBySubscriptionCleanup",
        )
        restore_pause = promote.index(
            "_manuallySuspendedDownloadIdentifiers addObject:identifier"
        )
        start = promote.index("BOOL accepted = [self _cacheEpisode:episode")
        self.assertLess(restore_pause, start)

    def test_streaming_preserve_semantics_survive_failure_persistence_and_retry(self):
        record = body(CACHE, "- (void)_recordDownloadError:")
        self.assertIn("preservesConsumedState:(BOOL)preservesConsumedState", CACHE)
        self.assertIn('@"preservesConsumedState"', record)

        finish = body(CACHE, "- (void)_finishCacheOperationDidEnd:")
        self.assertIn(
            "preservesConsumedState:operation.preservesConsumedState",
            finish,
        )
        retry = body(CACHE, "- (BOOL)retryFailedDownloadForEpisode:")
        self.assertIn(
            'BOOL preservesConsumedState = [metadata[@"preservesConsumedState"] boolValue]',
            retry,
        )
        self.assertIn("preservesConsumedState:preservesConsumedState", retry)
        stream_failure = body(CACHE, "- (void) failStreamingCacheForEpisode:")
        self.assertIn("preservesConsumedState:YES", stream_failure)

        consumed = True
        persisted_failure = {"preservesConsumedState": True}
        retried_operation_preserves = persisted_failure["preservesConsumedState"]
        if not retried_operation_preserves:
            consumed = False
        self.assertTrue(consumed)

    def test_backup_cancellation_removes_a_deferred_owner_without_an_episode(self):
        model = MissingEpisodeDeferredCancellationModel()
        self.assertTrue(model.complete())
        self.assertFalse(model.deferred_descriptor)
        self.assertFalse(model.persisted_descriptor)

        complete = body(
            CACHE,
            "- (BOOL)completeDeferredRestoreCancellationForObjectHash:",
        )
        remove = complete.index(
            "_removeDownloadDeferredBySubscriptionCleanupForIdentifier:objectHash"
        )
        owner_resolution = complete.index("if (ownerEpisode)")
        self.assertLess(remove, owner_resolution)
        owner_removed = complete[complete.index("BOOL ownerRemoved") :]
        self.assertIn(
            "!_subscriptionCleanupDeferredDownloadInfosByIdentifier[objectHash]",
            owner_removed,
        )

        remove_deferred = body(
            CACHE,
            "- (void)_removeDownloadDeferredBySubscriptionCleanupForIdentifier:",
        )
        self.assertIn("hasInMemoryOwner", remove_deferred)
        self.assertIn("persistedInfo", remove_deferred)
        self.assertIn("!hasInMemoryOwner && !persistedInfo", remove_deferred)
        self.assertIn("[USER_DEFAULTS removeObjectForKey:key]", remove_deferred)

    def test_a_completed_operation_cannot_be_yielded_while_its_result_is_finalizing(self):
        resume = body(
            CACHE,
            "- (void)_resumeDownloadsAfterSubscriptionCleanupProtectionChange:",
        )
        yield_loop = resume[resume.index("if (waitingManualCount > 0") :]
        self.assertIn("_finalizingDownloadOperationIdentifiers", yield_loop)
        self.assertLess(
            yield_loop.index("_finalizingDownloadOperationIdentifiers"),
            yield_loop.index("_requestDownloadOperationYield:operation"),
        )
        self.assertLess(
            yield_loop.index("[self _requestDownloadOperationYield:operation]"),
            yield_loop.index("waitingManualCount -= 1"),
        )

        request_yield = body(CACHE, "- (BOOL)_requestDownloadOperationYield:")
        self.assertIn("operation.cancelled", request_yield)
        self.assertIn("operation.finished", request_yield)
        self.assertIn("_finalizingDownloadOperationIdentifiers", request_yield)

        did_end = body(CACHE, "- (void) cacheOperationDidEnd:")
        finalization = did_end[did_end.index("if (succeeded)") :]
        self.assertIn(
            "_scheduledDownloadOperationIdentifiers removeObject:operation.identifier",
            finalization,
        )
        self.assertIn("_startNextDownloadOperations", finalization)

        scheduler = body(CACHE, "- (void) _startNextDownloadOperations")
        self.assertIn("_finalizingDownloadOperationIdentifiers", scheduler)

    def test_streaming_transition_cancels_only_the_captured_old_download_owner(self):
        open_episode = body(PLAYBACK, "- (void) openWithEpisode:")
        self.assertNotIn("cancelCachingEpisode:anEpisode", open_episode)

        begin_stream = body(CACHE, "- (NSString*) beginStreamingCacheForEpisode:")
        source_snapshot = begin_stream.index(
            "sourceOperation = _downloadOperationsByIdentifier[key]"
        )
        deferred_owner = begin_stream.index(
            "_deferDownloadUntilSubscriptionCleanupFinishes"
        )
        first_transition = begin_stream.index(
            "_cancelDownloadOperationForStreamingTransition:"
        )
        stream_owner = begin_stream.index(
            "_streamingCacheLeaseTokensByIdentifier[key] = leaseToken"
        )
        last_transition = begin_stream.rindex(
            "_cancelDownloadOperationForStreamingTransition:"
        )
        self.assertLess(source_snapshot, deferred_owner)
        self.assertLess(deferred_owner, first_transition)
        self.assertLess(stream_owner, last_transition)

        cancel_old = body(
            CACHE,
            "- (void)_cancelDownloadOperationForStreamingTransition:",
        )
        self.assertIn(
            "_downloadOperationsByIdentifier[identifier] == operation",
            cancel_old,
        )
        self.assertIn(
            "_cancelTrackedDownloadOperationAfterDurableIntent:operation",
            cancel_old,
        )
        self.assertNotIn("_cancelCachingEpisodeAfterDurableIntent", cancel_old)
        self.assertNotIn(
            "_removeDownloadDeferredBySubscriptionCleanupForIdentifier",
            cancel_old,
        )
        self.assertNotIn("prepareForDeferredDownloadCancellation", cancel_old)

    def test_streaming_transition_consumes_a_pending_yield_without_resurrecting_download(self):
        begin_stream = body(CACHE, "- (NSString*) beginStreamingCacheForEpisode:")
        source_snapshot = begin_stream.index(
            "sourceOperation = _downloadOperationsByIdentifier[key]"
        )
        yield_snapshot = begin_stream.index(
            "sourceOperationHasPendingYield = "
            "_downloadPauseYieldTokensByIdentifier[key] != nil"
        )
        cancelled_filter = begin_stream.index("sourceOperation.cancelled")
        self.assertLess(source_snapshot, yield_snapshot)
        self.assertLess(yield_snapshot, cancelled_filter)
        self.assertIn(
            "!sourceOperationHasPendingYield && sourceOperation.cancelled",
            begin_stream,
        )
        self.assertIn(
            "!sourceOperationHasPendingYield &&",
            begin_stream[begin_stream.index("if (sourceOperation &&") :],
        )

        cancel_old = body(
            CACHE,
            "- (void)_cancelDownloadOperationForStreamingTransition:",
        )
        pending_yield = cancel_old.index(
            "hasPendingYield = _downloadPauseYieldTokensByIdentifier[identifier] != nil"
        )
        guarded_terminal_state = cancel_old.index("!hasPendingYield &&")
        consume_yield = cancel_old.index(
            "[_downloadPauseYieldTokensByIdentifier removeObjectForKey:identifier]"
        )
        cancel_exact_owner = cancel_old.index(
            "_cancelTrackedDownloadOperationAfterDurableIntent:operation"
        )
        self.assertLess(pending_yield, guarded_terminal_state)
        self.assertLess(guarded_terminal_state, consume_yield)
        self.assertLess(consume_yield, cancel_exact_owner)


if __name__ == "__main__":
    unittest.main()
