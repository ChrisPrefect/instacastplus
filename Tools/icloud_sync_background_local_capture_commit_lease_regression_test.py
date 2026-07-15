#!/usr/bin/env python3
"""Pins background local outbox commits to the account-transition lease barrier."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
DE_STRINGS = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
EN_STRINGS = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing function: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


class BackgroundLocalCaptureCommitLeaseRegressionTests(unittest.TestCase):
    def test_gate_supports_local_capture_on_the_account_transition_barrier(self):
        self.assertIn("case localCapture", TYPES)
        acquire = body(MANAGER, "func acquireLocalCaptureCommitLease(")
        self.assertIn("remoteApplyAccountTransitionDepth == 0", acquire)
        self.assertIn("activeRemoteApplyCommitLeases", acquire)
        transition = body(MANAGER, "func awaitRemoteApplyCommitLeases()")
        self.assertIn("activeRemoteApplyCommitLeases.isEmpty", transition)

    def test_context_plan_revalidates_scope_after_acquiring_lease(self):
        prepare = body(LOCAL, "nonisolated static func prepareBackgroundLocalOutboxCommit(")
        self.assertIn("localOutboxEntityName", prepare)
        self.assertIn("localCredentialOutboxCategory", prepare)
        self.assertIn("acquireLocalCaptureCommitLease", prepare)
        self.assertIn("localOutboxCaptureAccountRecordName", prepare)
        self.assertIn("releaseRemoteApplyCommitLease", prepare)

    def test_episode_and_subscription_writers_hold_plan_across_save(self):
        for signature in (
            "+ (NSInteger)_importEpisodeStatusForPodcastAtIndex:",
            "+ (NSInteger)importFeedSettingsFromBackup:",
        ):
            method = body(IMPORTER, signature)
            prepare = method.index("prepareBackgroundLocalOutboxCommitInContext")
            save = method.index("[context save:&saveError]", prepare)
            complete = method.index("completeBackgroundLocalOutboxCommit", save)
            self.assertLess(prepare, save)
            self.assertLess(save, complete)
            self.assertIn("cancelBackgroundLocalOutboxCommit", method)

    def test_account_change_abort_is_localized(self):
        key = "Der iCloud-Account hat sich während der lokalen Änderung geändert. Die Änderung wurde nicht gespeichert."
        self.assertIn(f'"{key}"', DE_STRINGS)
        self.assertIn(f'"{key}"', EN_STRINGS)


if __name__ == "__main__":
    unittest.main()
