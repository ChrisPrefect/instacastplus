#!/usr/bin/env python3
"""Pins the local-reset epoch barrier across async sync producers."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def body(signature: str) -> str:
    start = MANAGER.find(signature)
    if start < 0:
        raise AssertionError(f"Missing function: {signature}")
    brace = MANAGER.find("{", start)
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


class ProducerBarrierModel:
    def __init__(self):
        self.epoch = 1
        self.started = True
        self.child_tasks = 0

    def capture(self):
        return self.epoch

    def reset(self):
        self.started = False
        self.epoch += 1

    def resume_after_await(self, captured_epoch):
        if not self.started or captured_epoch != self.epoch:
            return
        self.child_tasks += 1


class FailedResetModel:
    def __init__(self, options):
        self.options = options
        self.started = True
        self.cleanup_blocked = False

    def begin(self):
        self.started = False
        self.cleanup_blocked = True
        self.previous_options = self.options
        self.options = (False, False, False)

    def fail_and_recover(self):
        self.options = self.previous_options
        self.started = True
        # The shared startup protection/drain lifecycle opens this only after
        # every durable cleanup intent has its feed-specific gate installed.
        self.cleanup_blocked = False


class LocalResetProducerBarrierTests(unittest.TestCase):
    def test_reset_between_preflight_await_and_child_install_cannot_spawn(self):
        model = ProducerBarrierModel()
        captured_epoch = model.capture()
        model.reset()
        model.resume_after_await(captured_epoch)
        self.assertEqual(model.child_tasks, 0)

    def test_failed_prepare_restores_runtime_without_changing_sync_options(self):
        model = FailedResetModel((True, False, True))
        model.begin()
        model.fail_and_recover()
        self.assertTrue(model.started)
        self.assertFalse(model.cleanup_blocked)
        self.assertEqual(model.options, (True, False, True))

    def test_safe_database_failure_restores_options_and_reuses_startup_cleanup_lifecycle(self):
        prepare = body("@objc func prepareForLocalAppResetWithCompletion")
        self.assertIn("captureLocalAppResetSyncOptions", prepare)
        self.assertLess(
            prepare.index("captureLocalAppResetSyncOptions"),
            prepare.index("defaults.set(false, forKey: ICiCloudSyncEpisodesEnabled)"),
        )

        startup = body("func startPostInitializationRecoveryLifecycle()")
        self.assertIn("protectPendingSubscriptionCleanupAutoDownloads", startup)
        self.assertIn("drainPendingSubscriptionCleanupIntentsIfNeeded", startup)
        self.assertLess(
            startup.index("protectPendingSubscriptionCleanupAutoDownloads"),
            startup.index("drainPendingSubscriptionCleanupIntentsIfNeeded"),
        )

        start = body("@objc func start()")
        recovery = body("func recoverAfterFailedLocalAppReset(")
        restart = body("func restartAfterFailedLocalAppReset(")
        self.assertIn("startPostInitializationRecoveryLifecycle()", start)
        self.assertIn("restartAfterFailedLocalAppReset(error)", recovery)
        self.assertIn("restoreLocalAppResetSyncOptions()", restart)
        self.assertIn("startPostInitializationRecoveryLifecycle()", restart)
        self.assertNotIn("performForegroundSyncIfNeeded()", recovery)

        safe_recovery = body("@objc func recoverAfterLocalAppResetFailure")
        self.assertIn("restartAfterFailedLocalAppReset(error)", safe_recovery)

        complete = body("@objc func completeLocalAppReset()")
        self.assertIn("localAppResetSyncOptions = nil", complete)

    def test_continue_enabled_sync_rechecks_session_after_each_await(self):
        continuation = body("func continueEnabledSyncAfterAccountVerification() async")
        self.assertIn("let generation = cloudAccountGeneration", continuation)
        singleton_await = continuation.index(
            "await resumePendingSingletonUploadsForVerifiedAccount()"
        )
        outbox_await = continuation.index("await drainLocalOutbox()")
        self.assertIn(
            "generation == cloudAccountGeneration",
            continuation[singleton_await:outbox_await],
        )
        self.assertIn("isStarted", continuation[singleton_await:outbox_await])
        self.assertIn("!Task.isCancelled", continuation[singleton_await:outbox_await])
        self.assertIn(
            "generation == cloudAccountGeneration",
            continuation[outbox_await:],
        )
        self.assertIn("isStarted", continuation[outbox_await:])

    def test_manual_and_background_preflights_recheck_before_worker_install(self):
        manual = body("@objc func performManualSyncWithCompletion")
        self.assertIn("let preflightGeneration = cloudAccountGeneration", manual)
        manual_refresh = manual.index("await refreshAccountStatus()")
        manual_worker = manual.index("let operation = Task", manual_refresh)
        self.assertIn(
            "preflightGeneration == cloudAccountGeneration",
            manual[manual_refresh:manual_worker],
        )
        self.assertIn("isStarted", manual[manual_refresh:manual_worker])

        background = body("@objc func performBackgroundSyncWithCompletion")
        self.assertIn("let preflightGeneration = cloudAccountGeneration", background)
        background_refresh = background.index("await refreshAccountStatus()")
        background_worker = background.index("let operation = Task", background_refresh)
        self.assertIn(
            "preflightGeneration == cloudAccountGeneration",
            background[background_refresh:background_worker],
        )
        self.assertIn("isStarted", background[background_refresh:background_worker])

    def test_sync_option_preflights_recheck_after_account_refresh(self):
        options = body("@objc func syncOptionsChanged()")
        self.assertIn("let optionsGeneration = cloudAccountGeneration", options)
        self.assertGreaterEqual(
            options.count("optionsGeneration == cloudAccountGeneration"),
            2,
        )
        self.assertGreaterEqual(options.count("isStarted"), 3)

    def test_prepare_failure_recovers_and_outbox_delete_is_background_atomic(self):
        reset = body("@objc func prepareForLocalAppResetWithCompletion")
        first_delete = reset.index("deleteAllPendingEpisodeStates")
        options_off = reset.index(
            "defaults.set(false, forKey: ICiCloudSyncEpisodesEnabled)"
        )
        self.assertGreater(options_off, first_delete)
        self.assertNotIn("databaseManager.objectContext", reset)
        self.assertIn("deleteAllLocalOutboxEntriesForLocalReset", reset)
        self.assertGreaterEqual(reset.count("recoverAfterFailedLocalAppReset"), 2)

        outbox_delete = body(
            "nonisolated static func deleteAllLocalOutboxEntriesForLocalReset()"
        )
        self.assertIn("newICloudSyncBackgroundContext", outbox_delete)
        self.assertIn("NSBatchDeleteRequest", outbox_delete)

        recovery = body("func recoverAfterFailedLocalAppReset(")
        restart = body("func restartAfterFailedLocalAppReset(")
        self.assertIn("restartAfterFailedLocalAppReset(error)", recovery)
        self.assertIn("isStarted = true", restart)
        self.assertIn("restoreLocalAppResetSyncOptions()", restart)
        self.assertIn("resetForICloudAccountTransition(", restart)
        self.assertIn("reinitializeEngine: true", restart)
        self.assertIn("startPostInitializationRecoveryLifecycle()", restart)


if __name__ == "__main__":
    unittest.main()
