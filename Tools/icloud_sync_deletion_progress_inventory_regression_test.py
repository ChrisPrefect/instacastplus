#!/usr/bin/env python3
"""Pins committed deletion progress and the inventory state it invalidates."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


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


class ICloudDeletionProgressInventoryRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
        cls.deletion_path = fetched.split("var deletionIndex", 1)[1].split(
            "var modificationCountsByType", 1
        )[0]

    def test_only_a_committed_user_data_deletion_advances_visible_activity(self):
        flush_guard = self.deletion_path.find("guard didFlush")
        activity = self.deletion_path.find("recordSyncActivity", flush_guard)
        self.assertGreater(flush_guard, -1)
        self.assertGreater(
            activity,
            flush_guard,
            "Deletion activity must be counted only after its local Core Data commit succeeded.",
        )
        activity_context = self.deletion_path[:activity]
        self.assertIn(
            "isVisibleSyncActivityDeletion",
            activity_context,
            "Inverse tombstone/helper/device deletions must not look like downloaded user data.",
        )

    def test_failed_deletion_commit_cannot_change_progress_or_inventory(self):
        flush_guard = self.deletion_path.find("guard didFlush")
        before_commit = self.deletion_path[:flush_guard]
        self.assertNotIn("recordSyncActivity", before_commit)
        self.assertNotIn("requestedCloudInventoryRefreshReason", before_commit)
        self.assertNotIn("cloudInventoryKey", before_commit)

    def test_committed_deletions_coalesce_one_later_inventory_refresh(self):
        flush_guard = self.deletion_path.find("guard didFlush")
        committed = self.deletion_path[flush_guard:]
        requests_coalesced_refresh = (
            "requestedCloudInventoryRefreshReason" in committed
            or "requestCloudInventoryRefreshAfterDeletion" in committed
        )
        self.assertTrue(
            requests_coalesced_refresh,
            "A committed deletion must request one refresh after the complete sync cycle.",
        )
        invalidates_stale_inventory = (
            "cloudInventoryKey" in committed
            or "invalidateCloudInventory" in committed
        )
        self.assertTrue(
            invalidates_stale_inventory,
            "The now-stale persisted inventory must be invalidated immediately.",
        )
        self.assertIn(
            "isCloudInventoryRecordType",
            committed,
            "Only episode, subscription, and app-settings records affect the three inventory rows.",
        )
        self.assertNotIn(
            "refreshCloudInventory(",
            committed,
            "Deletion batches must coalesce a later refresh, not scan the entire zone per batch.",
        )

    def test_zone_deletion_publishes_zero_before_fallible_cleanup(self):
        database_changes = method_body(REMOTE, "func handleFetchedDatabaseChanges")
        zero_inventory = database_changes.find("storeCloudInventory([:]")
        cleanup = database_changes.find("try await Self.deleteKnownRecordSystemFields")
        self.assertGreater(
            zero_inventory,
            -1,
            "A deleted sync zone proves that its cloud inventory is immediately zero.",
        )
        self.assertLess(
            zero_inventory,
            cleanup,
            "Zero inventory must be visible even when later local cleanup fails.",
        )

    def test_zone_reseed_recounts_progress_and_refreshes_inventory_after_sync(self):
        database_changes = method_body(REMOTE, "func handleFetchedDatabaseChanges")
        schedule = database_changes.find("scheduleCurrentEnabledDataForUpload()")
        self.assertIn("cloudInventoryPayloadScanCompletedKey", database_changes)
        self.assertIn('requestedCloudInventoryRefreshReason = "fetchedZoneReseed"', database_changes)
        self.assertIn("cachedSyncTotalCounts = nil", database_changes)
        self.assertIn("captureInitialBackfillTotalsFromCachedCountsIfNeeded()", database_changes)
        self.assertLess(
            database_changes.find("captureInitialBackfillTotalsFromCachedCountsIfNeeded()"),
            schedule,
        )

    def test_delete_all_reseed_refreshes_zero_inventory_after_reupload(self):
        delete_all = method_body(MANAGER, "@objc func deleteAllICloudDataWithCompletion")
        enabled = delete_all.split("if anySyncEnabled {", 1)[1].split("} else {", 1)[0]
        self.assertIn('requestedCloudInventoryRefreshReason = "deleteAllReseed"', enabled)
        self.assertIn("captureInitialBackfillTotalsFromCachedCountsIfNeeded()", enabled)
        self.assertLess(
            enabled.find("captureInitialBackfillTotalsFromCachedCountsIfNeeded()"),
            enabled.find("scheduleCurrentEnabledDataForUpload()"),
        )


if __name__ == "__main__":
    unittest.main()
