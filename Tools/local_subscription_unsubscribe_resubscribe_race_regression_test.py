#!/usr/bin/env python3
"""Pins auto-download handoff across unsubscribe/resubscribe cleanup overlap."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
HEADER = (ROOT / "Classes" / "Model" / "SubscriptionManager.h").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def body(signature: str, source: str = SOURCE) -> str:
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


class AutoDownloadCleanupGate:
    def __init__(self):
        self.cleanup_active = False
        self.pending = False
        self.started = 0

    def begin_cleanup(self):
        self.cleanup_active = True
        self.pending = False

    def request_after_resubscribe(self):
        self.pending = True
        self.drain()

    def finish_cleanup(self, *, history_reset_fails=False):
        if history_reset_fails:
            return
        self.cleanup_active = False
        self.drain()

    def drain(self):
        if self.cleanup_active or not self.pending:
            return
        self.pending = False
        self.started += 1


class StartupRecoveryGate:
    def __init__(self):
        self.blocked = True
        self.resume_calls = 0

    def finish_drain(self, *, failed=False, cancelled=False):
        if failed or cancelled:
            return
        self.blocked = False
        self.resume_calls += 1


class LocalUnsubscribeResubscribeRaceTests(unittest.TestCase):
    def test_resubscribe_handoff_waits_for_cleanup_then_runs_exactly_once(self):
        gate = AutoDownloadCleanupGate()
        gate.begin_cleanup()
        gate.request_after_resubscribe()
        self.assertTrue(gate.pending)
        self.assertEqual(gate.started, 0)

        gate.finish_cleanup()
        self.assertFalse(gate.pending)
        self.assertEqual(gate.started, 1)

    def test_history_failure_keeps_handoff_blocked_until_safe_retry_succeeds(self):
        gate = AutoDownloadCleanupGate()
        gate.begin_cleanup()
        gate.request_after_resubscribe()
        gate.finish_cleanup(history_reset_fails=True)
        self.assertTrue(gate.cleanup_active)
        self.assertTrue(gate.pending)
        self.assertEqual(gate.started, 0)

        # A subscribed feed retries only the history reset. It must not run the old
        # destructive file cleanup against downloads from the new subscription.
        gate.finish_cleanup(history_reset_fails=False)
        self.assertFalse(gate.cleanup_active)
        self.assertFalse(gate.pending)
        self.assertEqual(gate.started, 1)

    def test_global_startup_gate_only_opens_after_a_complete_successful_drain(self):
        gate = StartupRecoveryGate()
        gate.finish_drain(failed=True)
        self.assertTrue(gate.blocked)
        gate.finish_drain(cancelled=True)
        self.assertTrue(gate.blocked)
        self.assertEqual(gate.resume_calls, 0)
        gate.finish_drain()
        self.assertFalse(gate.blocked)
        self.assertEqual(gate.resume_calls, 1)

    def test_cleanup_recovery_gate_is_closed_from_subscription_manager_init(self):
        initializer = body("- (id) init")
        self.assertIn("_unsubscribeCleanupRecoveryBlocked = YES;", initializer)

    def test_startup_cleanup_registry_scan_is_async_batched_and_reset_owned(self):
        self.assertIn("startupRecoveryTask", MANAGER)
        self.assertIn("startupCleanupProtectionTask", MANAGER)
        startup = body("func startPostInitializationRecoveryLifecycle()", MANAGER)
        self.assertIn("startupRecoveryTask = task", startup)
        self.assertIn(
            "try await self.protectPendingSubscriptionCleanupAutoDownloads()",
            startup,
        )

        scan = body(
            "nonisolated static func pendingSubscriptionCleanupIntentSnapshotsForStartup()",
            REMOTE,
        )
        self.assertIn("newICloudSyncBackgroundContext", scan)
        self.assertIn("try await context.perform", scan)

        protect = body(
            "func protectPendingSubscriptionCleanupAutoDownloads() async throws",
            REMOTE,
        )
        self.assertIn("startupCleanupProtectionBatchSize", protect)
        self.assertIn("await Task.yield()", protect)
        self.assertLess(
            protect.index("pendingSubscriptionCleanupIntentSnapshotsForStartup"),
            protect.index("installAutoDownloadsDuringUnsubscribeCleanup"),
        )
        self.assertLess(
            protect.index("installAutoDownloadsDuringUnsubscribeCleanup"),
            protect.index("setUnsubscribeCleanupRecoveryBlocked(false)"),
        )

        reset = body("@objc func prepareForLocalAppResetWithCompletion", MANAGER)
        self.assertIn(
            "let startupCleanupProtectionTask = startupCleanupProtectionTask",
            reset,
        )
        self.assertIn("startupCleanupProtectionTask?.cancel()", reset)
        self.assertIn("await startupCleanupProtectionTask.value", reset)
        self.assertIn("let startupRecoveryTask = startupRecoveryTask", reset)
        self.assertIn("startupRecoveryTask?.cancel()", reset)
        self.assertIn("await startupRecoveryTask.value", reset)

        drain = body(
            "func drainPendingSubscriptionCleanupIntentsIfNeeded()",
            REMOTE,
        )
        scan_wait = drain.index("await startupCleanupProtectionTask.value")
        self.assertLess(
            scan_wait,
            drain.index("localSubscriptionCleanupRequestedGeneration &+= 1"),
        )

    def test_foreground_sync_task_is_reset_owned(self):
        self.assertIn("foregroundSyncTask", MANAGER)
        foreground = body("@objc func performForegroundSyncIfNeeded()", MANAGER)
        self.assertIn("foregroundSyncTask = task", foreground)
        self.assertIn("self.isStarted", foreground)

        reset = body("@objc func prepareForLocalAppResetWithCompletion", MANAGER)
        self.assertIn("let foregroundSyncTask = foregroundSyncTask", reset)
        self.assertIn("foregroundSyncTask?.cancel()", reset)
        self.assertIn("await foregroundSyncTask.value", reset)

    def test_production_has_one_feed_specific_cleanup_gate(self):
        self.assertIn(
            "@property (nonatomic, strong) NSMutableDictionary<NSString*, ICUnsubscribeCleanupProtectionState*>* unsubscribeCleanupProtectionStatesByFeedObjectURIString;",
            SOURCE,
        )
        self.assertIn(
            "_unsubscribeCleanupProtectionStatesByFeedObjectURIString = [[NSMutableDictionary alloc] init];",
            SOURCE,
        )
        self.assertIn("unsubscribeCleanupProtectionLock", SOURCE)
        self.assertIn("unsubscribeCleanupRecoveryBlocked", SOURCE)
        self.assertIn("setUnsubscribeCleanupRecoveryBlocked", HEADER)

        cleanup = body("- (void)performUnsubscribeSideEffectsForFeeds:")
        self.assertIn("historyResetError", cleanup)
        self.assertNotIn("protectAutoDownloadsDuringUnsubscribeCleanup", cleanup)
        self.assertNotIn("retireAutoDownloadsDuringUnsubscribeCleanup", cleanup)
        self.assertNotIn("_startPendingAutoDownloads", cleanup)

        self.assertIn("performResubscribeCleanupForFeeds", HEADER)
        safe_cleanup = body("- (void)performResubscribeCleanupForFeeds:")
        self.assertIn("resetAutoCacheForFeeds:feeds", safe_cleanup)
        self.assertNotIn("removeCacheForFeeds", safe_cleanup)
        self.assertNotIn("retireAutoDownloadsDuringUnsubscribeCleanup", safe_cleanup)
        self.assertNotIn("_startPendingAutoDownloads", safe_cleanup)

        install = body(
            "- (void)installAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:"
        )
        self.assertIn("state.committedRevision = revision", install)
        self.assertIn("state.committedSequence = 0", install)
        self.assertIn("unsubscribeCleanupProtectionLock", install)
        complete = body(
            "- (void)completeAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:"
        )
        self.assertIn("[state.committedRevision isEqualToString:revision]", complete)
        self.assertIn("BOOL becameUnprotected", complete)
        self.assertIn("if (becameUnprotected)", complete)
        self.assertIn("_resumeAfterUnsubscribeCleanupProtectionChange", complete)
        resume = body("- (void)_resumeAfterUnsubscribeCleanupProtectionChange")
        self.assertIn("_startPendingAutoDownloads", resume)
        self.assertIn(
            "SubscriptionManagerUnsubscribeCleanupProtectionDidChangeNotification",
            resume,
        )

        auto_download = body("- (void)_autoDownloadEpisodesInFeedAsynchronously:")
        self.assertIn("self.unsubscribeCleanupRecoveryBlocked", auto_download)
        self.assertIn(
            "_autoDownloadsBlockedDuringUnsubscribeCleanupForFeedObjectID:feedObjectID",
            auto_download,
        )
        self.assertIn(
            "automaticDownloadsBlockedDuringUnsubscribeCleanupForFeed:currentFeed",
            auto_download[auto_download.index("deliverNextCandidateBatch"):],
        )
        self.assertIn(
            "self.unsubscribeCleanupRecoveryBlocked",
            auto_download[auto_download.index("deliverNextCandidateBatch"):],
        )
        self.assertIn(
            "pendingAutoDownloadFeedObjectIDs addObjectsFromArray:feedObjectIDs",
            auto_download[auto_download.index("deliverNextCandidateBatch"):],
        )
        self.assertIn(
            "[self _autoDownloadsBlockedDuringUnsubscribeCleanupForFeedObjectID:feedObjectID]) {\n                            [self.pendingAutoDownloadFeedObjectIDs addObject:feedObjectID]",
            auto_download[auto_download.index("completedFeedUIDs"):],
        )

        drain = body("func performPendingSubscriptionCleanupIntentDrain()", REMOTE)
        self.assertIn("resubscribedFeeds", drain)
        self.assertIn("performResubscribeCleanup(for: resubscribedFeeds)", drain)
        self.assertLess(
            drain.index("performResubscribeCleanup(for: resubscribedFeeds)"),
            drain.index("completePendingSubscriptionCleanupIntents(resubscribedIntents)"),
        )
        self.assertIn("for intent in completedResubscribedIntents", drain)
        self.assertIn(
            "completeAutoDownloadsDuringUnsubscribeCleanup(",
            drain,
        )

        drain_entry = body("func drainPendingSubscriptionCleanupIntentsIfNeeded()", REMOTE)
        cancellation_start = drain_entry.index("catch is CancellationError")
        cancellation_end = drain_entry.index("} catch {", cancellation_start)
        self.assertNotIn("return nil", drain_entry[cancellation_start:cancellation_end])
        self.assertIn("localSubscriptionCleanupCancellationError", drain_entry)
        self.assertIn("localSubscriptionCleanupRequestedGeneration &+= 1", drain_entry)
        self.assertIn(
            "callerGeneration <= localSubscriptionCleanupCompletedGeneration",
            drain_entry,
        )
        self.assertLess(
            drain_entry.index("localSubscriptionCleanupTask = nil"),
            drain_entry.index("setUnsubscribeCleanupRecoveryBlocked(false)"),
        )

        start = body("func startPostInitializationRecoveryLifecycle()", MANAGER)
        self.assertIn("protectPendingSubscriptionCleanupAutoDownloads", start)
        cleanup_protection_task = start.index("let cleanupProtectionTask = Task")
        startup_recovery_task = start.index("let task = Task", cleanup_protection_task)
        self.assertLess(
            cleanup_protection_task,
            startup_recovery_task,
        )
        self.assertIn(
            "protectPendingSubscriptionCleanupAutoDownloads",
            start[cleanup_protection_task:startup_recovery_task],
        )

        startup_gate = body("func protectPendingSubscriptionCleanupAutoDownloads()", REMOTE)
        self.assertIn("setUnsubscribeCleanupRecoveryBlocked(true)", startup_gate)
        self.assertIn("setUnsubscribeCleanupRecoveryBlocked(false)", startup_gate)
        self.assertLess(
            startup_gate.index("installAutoDownloadsDuringUnsubscribeCleanup"),
            startup_gate.index("setUnsubscribeCleanupRecoveryBlocked(false)"),
        )

        apply_batch = body("nonisolated static func applyPendingSubscriptionBatchInBackground(", REMOTE)
        cleanup_start = apply_batch.index("for feed in cleanupAffectedFeeds")
        cleanup_end = apply_batch.index("let userEntityNames", cleanup_start)
        active_cleanup = apply_batch[cleanup_start:cleanup_end]
        self.assertNotIn("retirePendingSubscriptionCleanupIntent", active_cleanup)
        self.assertIn("subscriptionCleanupIntentEntry", active_cleanup)
        self.assertIn("hasPendingSubscriptionCleanup = true", active_cleanup)


if __name__ == "__main__":
    unittest.main()
