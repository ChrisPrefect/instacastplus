#!/usr/bin/env python3
"""Deterministic model for serialized backup credential recovery."""

import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
FEED = (ROOT / "Classes" / "Model" / "CDFeed.m").read_text()


class BackupCredentialReplayConcurrencyRegressionTests(unittest.TestCase):
    def test_import_captures_baseline_and_resolves_before_drain_can_enter(self):
        self.assertIn("localCredentialReplaySemaphore", LOCAL)
        self.assertIn("resolvePendingLocalCredentialIntentsInCriticalSection", LOCAL)
        begin = IMPORTER.index("beginLocalCredentialRestore")
        baseline = IMPORTER.index("NSString *expectedPassword = feed.password")
        replay = IMPORTER.index("resolvePendingLocalCredentialIntentsWithRestoreLease")
        release = IMPORTER.index("endLocalCredentialRestore", replay)
        drain_callback = IMPORTER.index("commitBackgroundLocalSubscriptionMergePlan", release)
        self.assertLess(begin, baseline)
        self.assertLess(baseline, replay)
        self.assertLess(replay, release)
        self.assertLess(release, drain_callback)

        gate = threading.Lock()
        keychain = {"password": "A"}
        intent = {"expected": "A", "desired": "B"}
        old_holds_gate = threading.Event()
        import_attempted = threading.Event()
        import_holds_gate = threading.Event()
        drain_attempted = threading.Event()
        drain_entered = threading.Event()
        allow_old_finish = threading.Event()
        allow_import_finish = threading.Event()

        def resolve_current_intent() -> None:
            current = intent.copy() if intent else None
            if not current:
                return
            if keychain["password"] == current["expected"]:
                keychain["password"] = current["desired"]
            intent.clear()

        def old_replay() -> None:
            with gate:
                old_holds_gate.set()
                self.assertTrue(allow_old_finish.wait(timeout=2))
                resolve_current_intent()

        def imported_restore() -> None:
            self.assertTrue(old_holds_gate.wait(timeout=2))
            import_attempted.set()
            with gate:
                import_holds_gate.set()
                expected = keychain["password"]
                intent.update(expected=expected, desired="C")
                self.assertTrue(allow_import_finish.wait(timeout=2))
                resolve_current_intent()

        def global_drain() -> None:
            self.assertTrue(import_holds_gate.wait(timeout=2))
            drain_attempted.set()
            with gate:
                drain_entered.set()
                resolve_current_intent()

        old_thread = threading.Thread(target=old_replay)
        import_thread = threading.Thread(target=imported_restore)
        old_thread.start()
        import_thread.start()
        self.assertTrue(import_attempted.wait(timeout=2))
        self.assertFalse(import_holds_gate.is_set())
        allow_old_finish.set()
        self.assertTrue(import_holds_gate.wait(timeout=2))

        drain_thread = threading.Thread(target=global_drain)
        drain_thread.start()
        self.assertTrue(drain_attempted.wait(timeout=2))
        self.assertFalse(drain_entered.is_set())
        allow_import_finish.set()

        for thread in (old_thread, import_thread, drain_thread):
            thread.join(timeout=2)
            self.assertFalse(thread.is_alive())
        self.assertEqual(keychain["password"], "C")
        self.assertEqual(intent, {})

    def test_superseded_intent_is_retired_and_does_not_fail_every_start(self):
        self.assertIn("retireSupersededIntent", LOCAL)
        self.assertIn("try feed.compareAndSetPassword", LOCAL)
        self.assertIn("@synchronized(ICFeedCredentialLock())", FEED)

        keychain_password = "newer-user-password"
        pending_intent = {"expected": "old", "desired": "backup"}
        superseded_reports = 0

        def replay(targeted: bool) -> None:
            nonlocal pending_intent, superseded_reports
            if pending_intent is None:
                return
            if keychain_password != pending_intent["expected"]:
                pending_intent = None
                if targeted:
                    superseded_reports += 1

        replay(targeted=True)
        self.assertIsNone(pending_intent)
        self.assertEqual(superseded_reports, 1)
        replay(targeted=False)
        self.assertEqual(superseded_reports, 1)


if __name__ == "__main__":
    unittest.main()
