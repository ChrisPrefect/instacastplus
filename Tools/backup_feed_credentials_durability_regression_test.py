#!/usr/bin/env python3
"""Pins backup feed credentials to a crash-durable, compare-and-set journal."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
FEED_HEADER = (ROOT / "Classes" / "Model" / "CDFeed.h").read_text()
FEED = (ROOT / "Classes" / "Model" / "CDFeed.m").read_text()
DE_STRINGS = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
EN_STRINGS = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


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


class BackupFeedCredentialsDurabilityRegressionTests(unittest.TestCase):
    def test_import_journals_expected_and_desired_credentials_before_commit(self):
        restore = body(IMPORTER, "+ (NSInteger)importFeedSettingsFromBackup:")
        self.assertIn("credentialIntents", restore)
        self.assertIn("expectedPassword", restore)
        self.assertIn("expectedPasswordPresent", restore)
        self.assertIn("desiredUsername", restore)
        self.assertIn("desiredPassword", restore)
        self.assertIn("journalBackgroundSubscriptionChangesInContext", restore)
        self.assertLess(
            restore.index("journalBackgroundSubscriptionChangesInContext"),
            restore.index("[context save:&saveError]"),
            "The credential intent must commit atomically with the restored feed.",
        )
        self.assertNotIn(
            "feedsByURL[feedURL].password = passwordOverrides[feedURL]",
            restore,
            "A void Keychain setter after the database commit is not crash durable.",
        )

    def test_local_credential_intent_is_persisted_even_without_icloud_participation(self):
        journal = body(
            LOCAL,
            "nonisolated static func journalBackgroundSubscriptionChanges(",
        )
        credential_write = journal.index("localCredentialOutboxCategory")
        participation_gate = journal.index("subscriptionsSyncHasParticipatedKey")
        self.assertLess(
            credential_write,
            participation_gate,
            "Credential recovery must not depend on iCloud ever having been enabled.",
        )
        self.assertIn("localCredentialAccountRecordName", journal)
        self.assertIn("credentialIntents", journal)

    def test_replay_uses_compare_and_set_and_removes_intent_only_after_readback(self):
        replay = body(
            LOCAL,
            "nonisolated static func resolvePendingLocalCredentialIntentsBatch(",
        )
        self.assertIn("expectedPasswordPresent", replay)
        self.assertIn("expectedPassword", replay)
        self.assertIn("desiredUsername", replay)
        self.assertIn("desiredPassword", replay)
        self.assertIn("try feed.compareAndSetPassword", replay)
        self.assertIn("guard replaced", replay)
        self.assertIn("context.delete(entry)", replay)
        replacement_guard = replay.index("guard replaced")
        self.assertLess(
            replacement_guard,
            replay.index("context.delete(entry)", replacement_guard),
            "The durable intent may only be removed after verified Keychain readback.",
        )

    def test_import_and_both_replay_entry_points_share_one_serialized_gate(self):
        restore = body(IMPORTER, "+ (NSInteger)importFeedSettingsFromBackup:")
        lease_begin = restore.index("beginLocalCredentialRestore")
        expected_read = restore.index("NSString *expectedPassword = feed.password")
        database_save = restore.index("[context save:&saveError]", expected_read)
        targeted_replay = restore.index(
            "resolvePendingLocalCredentialIntentsWithRestoreLease",
            database_save,
        )
        lease_end = restore.index("endLocalCredentialRestore", targeted_replay)
        main_callback = restore.index("commitBackgroundLocalSubscriptionMergePlan", lease_end)
        self.assertLess(lease_begin, expected_read)
        self.assertLess(expected_read, database_save)
        self.assertLess(database_save, targeted_replay)
        self.assertLess(targeted_replay, lease_end)
        self.assertLess(lease_end, main_callback)

        targeted = body(
            LOCAL,
            "nonisolated static func resolvePendingLocalCredentialIntents(\n        forFeedURLs",
        )
        global_replay = body(
            LOCAL,
            "nonisolated static func resolvePendingLocalCredentialIntents() async",
        )
        self.assertIn("resolvePendingLocalCredentialIntentsSerialized", targeted)
        self.assertIn("resolvePendingLocalCredentialIntentsSerialized", global_replay)

    def test_keychain_compare_and_set_is_atomic_with_every_feed_password_writer(self):
        self.assertIn("ICFeedCredentialLock", FEED)
        password_getter = body(FEED, "- (NSString*) password")
        password_setter = body(FEED, "- (void) setPassword:")
        credential_cas = body(FEED, "- (BOOL)compareAndSetPassword:")
        for method in (password_getter, password_setter, credential_cas):
            self.assertIn("@synchronized(ICFeedCredentialLock())", method)
        self.assertIn("storedPassword", credential_cas)
        self.assertIn("compareAndSetPassword", FEED_HEADER)
        replay = body(
            LOCAL,
            "nonisolated static func resolvePendingLocalCredentialIntentsBatch(",
        )
        self.assertIn("try feed.compareAndSetPassword", replay)
        self.assertNotIn("feed.password = desiredPassword", replay)

    def test_superseded_intents_are_retired_once_and_specific_error_reaches_import_ui(self):
        replay = body(
            LOCAL,
            "nonisolated static func resolvePendingLocalCredentialIntentsBatch(",
        )
        self.assertIn("retireSupersededIntent", replay)
        self.assertIn("context.delete(entry)", replay)
        targeted = body(
            LOCAL,
            "nonisolated static func resolvePendingLocalCredentialIntents(\n        forFeedURLs",
        )
        self.assertIn("validateTargetedLocalCredentialReplay", targeted)
        validation = body(
            LOCAL,
            "nonisolated static func validateTargetedLocalCredentialReplay(",
        )
        self.assertIn("supersededIdentityCount", validation)
        self.assertIn("supersededPasswordCount", validation)
        restore = body(IMPORTER, "+ (NSInteger)importFeedSettingsFromBackup:")
        credential_failure = restore[
            restore.index("resolvePendingLocalCredentialIntentsWithRestoreLease"):
        ]
        self.assertIn("*error = credentialError", credential_failure)
        self.assertNotIn("ICBackupImportPersistenceError(credentialError)", credential_failure)

    def test_start_replays_credentials_even_when_all_sync_categories_are_off(self):
        start = body(MANAGER, "@objc func start()")
        self.assertIn("startPostInitializationRecoveryLifecycle()", start)
        recovery = body(MANAGER, "func startPostInitializationRecoveryLifecycle()")
        replay_index = recovery.index("resolvePendingLocalCredentialIntentsIfNeeded")
        sync_gate_index = recovery.index("if self.anySyncEnabled")
        self.assertLess(
            replay_index,
            sync_gate_index,
            "Credential recovery must run independently of the iCloud enable switches.",
        )

    def test_credential_restore_failures_are_localized_in_both_languages(self):
        keys = (
            "Die vorgemerkte Wiederherstellung der Podcast-Zugangsdaten ist beschädigt.",
            "Die importierten Podcast-Zugangsdaten sind unvollständig.",
            "Die importierten Podcast-Zugangsdaten passen nicht mehr zum lokalen Podcast.",
            "Die Podcast-Zugangsdaten wurden zwischenzeitlich geändert und nicht überschrieben.",
            "Die importierten Podcast-Zugangsdaten konnten nicht sicher gespeichert werden.",
            "Der lokale Speicher für die importierten Podcast-Zugangsdaten konnte nicht geöffnet werden.",
        )
        for key in keys:
            self.assertIn(f'"{key}"', DE_STRINGS)
            self.assertIn(f'"{key}"', EN_STRINGS)


if __name__ == "__main__":
    unittest.main()
