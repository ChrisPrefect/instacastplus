#!/usr/bin/env python3
"""Pins every bulk iCloud metadata operation to the dedicated store coordinator."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing function: {signature}")
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
    raise AssertionError(f"Unterminated function: {signature}")


class ICloudMetadataStoreIsolationRegressionTests(unittest.TestCase):
    def test_bulk_metadata_operations_never_use_the_main_store_coordinator(self):
        signatures = (
            "nonisolated static func persistKnownRecordSystemFields(",
            "nonisolated static func removeKnownRecordSystemFields(",
            "nonisolated static func snapshotKnownRecordSystemFieldsForPruning(",
            "nonisolated static func pruneKnownRecordSystemFields(",
            "nonisolated static func deleteKnownRecordSystemFields(",
            "nonisolated static func syncItemMetadataByRecordName(",
            "nonisolated static func deleteSyncItemMetadata(",
            "nonisolated static func bindSyncItemMetadata(",
            "nonisolated static func pruneEpisodeSyncItemMetadata(",
            "nonisolated static func allLocalEpisodeObjectHashes()",
            "nonisolated static func syncMetadataStorageSnapshot(",
        )
        for signature in signatures:
            with self.subTest(signature=signature):
                body = function_body(METADATA, signature)
                self.assertIn(
                    "newICloudSyncBackgroundContext()",
                    body,
                    f"{signature} can still contend with the main Core Data coordinator.",
                )
                self.assertNotIn("newBackgroundContext()", body)

    def test_metadata_extension_has_no_sync_operation_on_the_main_coordinator(self):
        self.assertNotIn(
            "newBackgroundContext()",
            METADATA,
            "All contexts in the iCloud metadata extension are sync-only and must use "
            "the dedicated coordinator.",
        )


if __name__ == "__main__":
    unittest.main()
