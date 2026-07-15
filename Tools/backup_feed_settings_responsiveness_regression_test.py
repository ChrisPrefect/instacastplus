#!/usr/bin/env python3
"""Pins podcast-settings restore to bounded off-main writes with atomic iCloud intent."""

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


class BackupFeedSettingsResponsivenessRegressionTests(unittest.TestCase):
    def test_feed_settings_phase_is_not_dispatched_to_main(self):
        phase_loop = IMPORTER[
            IMPORTER.index("NSInteger metadataTotal = metadataPhases.count"):
            IMPORTER.index("if (terminalError) {", IMPORTER.index("NSInteger metadataTotal = metadataPhases.count"))
        ]
        worker_branch = phase_loop[
            phase_loop.index("else if (cat == ICBackupImportBookmarks"):
            phase_loop.index("} else {", phase_loop.index("else if (cat == ICBackupImportBookmarks"))
        ]
        self.assertIn(
            "ICBackupImportFeedSettings",
            worker_branch,
            "Podcast settings restore is still synchronously dispatched to the UI thread.",
        )

    def test_feed_settings_batches_coalesce_one_outbox_drain(self):
        phase_loop = IMPORTER[
            IMPORTER.index("NSInteger metadataTotal = metadataPhases.count"):
            IMPORTER.index("if (terminalError) {", IMPORTER.index("NSInteger metadataTotal = metadataPhases.count"))
        ]
        self.assertIn("cat == ICBackupImportFeedSettings", phase_loop)
        self.assertIn("beginLocalOutboxBatch", phase_loop)
        self.assertIn("endLocalOutboxBatch", phase_loop)
        self.assertTrue(
            phase_loop.index("beginLocalOutboxBatch")
            < phase_loop.index("count = importBlock(&phaseError)", phase_loop.index("cat == ICBackupImportFeedSettings"))
            < phase_loop.index("endLocalOutboxBatch"),
            "All feed-settings commits must share one deferred outbox drain.",
        )

    def test_feed_settings_restore_uses_bounded_indexed_background_transactions(self):
        restore = body(IMPORTER, "+ (NSInteger)importFeedSettingsFromBackup:")
        self.assertIn("newICloudSyncBackgroundContext", restore)
        self.assertIn("ICBackupFeedSettingsBatchSize", restore)
        self.assertIn('initWithEntityName:@"Feed"', restore)
        self.assertIn("sourceURL_ IN %@", restore)
        self.assertIn('relationshipKeyPathsForPrefetching = @[@"properties"]', restore)
        self.assertIn("journalBackgroundSubscriptionChangesInContext", restore)
        self.assertIn("resolvePendingLocalCredentialIntentsWithRestoreLease", restore)
        self.assertIn("beginLocalCredentialRestore", restore)
        self.assertIn("endLocalCredentialRestore", restore)
        self.assertIn("prepareBackgroundLocalSubscriptionMergeWithInsertedObjectURIStrings", restore)
        self.assertIn("commitBackgroundLocalSubscriptionMergePlan", restore)
        self.assertIn("[context save:&saveError]", restore)
        self.assertNotIn("feedsByURL[feedURL].password =", restore)
        self.assertLess(
            restore.index("[context save:&saveError]"),
            restore.index("resolvePendingLocalCredentialIntentsWithRestoreLease"),
            "The durable credential journal must commit before its Keychain intent is resolved.",
        )
        self.assertLess(
            restore.index("resolvePendingLocalCredentialIntentsWithRestoreLease"),
            restore.index("endLocalCredentialRestore"),
            "The targeted resolver must stay inside the import credential lease.",
        )
        self.assertLess(
            restore.index("endLocalCredentialRestore"),
            restore.index("commitBackgroundLocalSubscriptionMergePlan"),
            "The UI merge may schedule the global drain only after targeted replay finishes.",
        )
        journal_index = restore.index("journalBackgroundSubscriptionChangesInContext")
        process_index = restore.find("[context processPendingChanges]")
        self.assertTrue(
            process_index == -1 or journal_index < process_index,
            "processPendingChanges clears changedValuesForCurrentEvent before the outbox journal reads it.",
        )
        for forbidden in (
            "[DMANAGER feedWithSourceURL:",
            "ICBackupSaveMainContext()",
        ):
            self.assertNotIn(forbidden, restore)

    def test_identical_backup_values_do_not_dirty_the_store_or_restart_sync(self):
        apply_setting = body(IMPORTER, "static BOOL ICBackupApplyFeedSetting(")
        self.assertIn(
            "ICBackupFeedSettingAlreadyMatches",
            apply_setting,
            "Restoring an unchanged property must not create a Core Data update/outbox upload.",
        )
        restore = body(IMPORTER, "+ (NSInteger)importFeedSettingsFromBackup:")
        self.assertIn("if (mergePlan || committedChanges)", restore)
        self.assertIn("committedChanges = YES", restore)
        self.assertGreater(
            restore.index("committedChanges = YES"),
            restore.index("if (context.hasChanges)"),
            "A fully unchanged batch must not schedule an outbox drain.",
        )

    def test_feed_url_mapping_exists_for_a_feed_settings_only_restore(self):
        index_builder = body(IMPORTER, "+ (NSError *)_buildGuidIndexForBackup:")
        self.assertIn("ICBackupImportFeedSettings", index_builder)
        self.assertIn('initWithEntityName:@"Feed"', index_builder)
        self.assertIn('propertiesToFetch = @[@"sourceURL_"]', index_builder)
        self.assertNotIn(
            "if (candidateGUIDs.count == 0) return nil;",
            index_builder,
            "A settings-only backup has no episode GUIDs but still needs URL identity mapping.",
        )

    def test_background_subscription_journal_is_in_the_same_transaction(self):
        journal = body(
            LOCAL,
            "nonisolated static func journalBackgroundSubscriptionChanges(",
        )
        self.assertIn("subscriptionsSyncHasParticipatedKey", journal)
        self.assertIn("prepareSyncItemMetadataContextBatch", journal)
        self.assertIn("localOutboxEntityName", journal)
        self.assertIn("subscriptionPayload(", journal)
        self.assertIn("for: feed", journal)
        self.assertIn("subscriptionTombstoneRecordName", journal)
        self.assertNotIn("context.save()", journal)
        self.assertNotIn("MainActor", journal)


if __name__ == "__main__":
    unittest.main()
