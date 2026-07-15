#!/usr/bin/env python3
"""Pins cross-coordinator UI merge validation before the durable backup commit."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


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


class BackupFeedSettingsMergeCommitRegressionTests(unittest.TestCase):
    def test_all_fallible_merge_work_precedes_background_save(self):
        restore = body(IMPORTER, "+ (NSInteger)importFeedSettingsFromBackup:")
        self.assertIn("obtainPermanentIDsForObjects", restore)
        self.assertIn("prepareBackgroundLocalSubscriptionMerge", restore)
        self.assertIn("commitBackgroundLocalSubscriptionMergePlan", restore)
        save_index = restore.index("[context save:&saveError]")
        self.assertLess(restore.index("obtainPermanentIDsForObjects"), save_index)
        self.assertLess(restore.index("prepareBackgroundLocalSubscriptionMerge"), save_index)
        self.assertGreater(restore.index("commitBackgroundLocalSubscriptionMergePlan"), save_index)
        after_save = restore[save_index:]
        self.assertNotIn("mergeError", after_save)

    def test_preflight_resolves_exact_ids_and_commit_is_void(self):
        preflight = body(
            LOCAL,
            "func prepareBackgroundLocalSubscriptionMerge(",
        )
        self.assertIn("managedObjectIDs", preflight)
        self.assertIn("viewContext", preflight)
        self.assertIn("coordinator", preflight)

        commit = body(
            LOCAL,
            "func commitBackgroundLocalSubscriptionMergePlan(",
        )
        self.assertIn("NSManagedObjectContext.mergeChanges", commit)
        self.assertNotIn("managedObjectIDs", commit)
        self.assertNotIn("throw", commit)


if __name__ == "__main__":
    unittest.main()
