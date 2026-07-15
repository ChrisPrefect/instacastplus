#!/usr/bin/env python3
"""Pins the empty-cloud settings publish to the cycle that performed the fetch."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
    brace = source.find("{", start)
    if brace == -1:
        raise AssertionError(f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


def assert_post_fetch_send(test: unittest.TestCase, body: str, completion_marker: str) -> None:
    fetch = body.find("fetchChanges()")
    test.assertNotEqual(fetch, -1, "The sync path must perform its CloudKit fetch.")
    tail = body[fetch:]
    pending = tail.find("hasPendingSyncChanges")
    send = tail.find("sendChangesAndApplyCallbackOutcomes")
    completion = tail.find(completion_marker)
    test.assertGreater(
        pending,
        -1,
        "The empty fetch can create settings_app, so pending state must be checked after fetch.",
    )
    test.assertGreater(
        send,
        pending,
        "settings_app created by didFetchChanges must be sent in the same sync cycle.",
    )
    test.assertGreater(
        completion,
        send,
        "The public completion must not run until the fetch-created settings record was sent.",
    )


class ICloudSettingsSameCycleRegressionTests(unittest.TestCase):
    def test_empty_fetch_is_the_only_gate_that_creates_initial_settings_save(self):
        handler = method_body(ENGINE, "func handleEventOnMain")
        did_fetch = handler.split("case .didFetchChanges:", 1)[1].split(
            "case .didFetchRecordZoneChanges", 1
        )[0]
        self.assertIn("initialSettingsBackfillPendingKey", did_fetch)
        self.assertIn("addPendingSave(appSettingsRecordID())", did_fetch)

    def test_manual_sync_sends_fetch_created_settings_before_returning(self):
        manual = method_body(MANAGER, "func performManualSync()")
        assert_post_fetch_send(
            self,
            manual,
            "markSyncCompletedIfFinished(allowActiveSyncCycle: true)",
        )

    def test_background_sync_excludes_an_existing_low_priority_cycle(self):
        background = method_body(
            MANAGER, "@objc func performBackgroundSyncWithCompletion"
        )
        cancellation = background.find("await cancelAndAwaitLowPrioritySync()")
        fetch = background.find("fetchChanges()")
        self.assertGreater(
            cancellation,
            -1,
            "A push/background fetch must first cancel and await a scheduled low-priority cycle.",
        )
        self.assertLess(
            cancellation,
            fetch,
            "Low-priority exclusion must be established before CKSyncEngine starts fetching.",
        )

    def test_background_sync_sends_fetch_created_settings_before_completion(self):
        background = method_body(
            MANAGER, "@objc func performBackgroundSyncWithCompletion"
        )
        assert_post_fetch_send(self, background, "completion(.newData)")


if __name__ == "__main__":
    unittest.main()
