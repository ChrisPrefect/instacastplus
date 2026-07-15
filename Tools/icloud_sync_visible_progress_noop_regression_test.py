#!/usr/bin/env python3
"""Pins user-visible iCloud progress, re-enable no-op and local-echo cost."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
LOCAL_CHANGES = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
ALL = "\n".join((MANAGER, ENGINE, REMOTE, METADATA))


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


class ICloudVisibleProgressRegressionTests(unittest.TestCase):
    def test_first_upload_is_planned_before_any_network_sync_cycle(self):
        changed = method_body(MANAGER, "func syncOptionsChanged")
        continuation = method_body(MANAGER, "func continueEnabledSyncAfterAccountVerification")
        self.assertIn("continueEnabledSyncAfterAccountVerification", changed)
        self.assertIn("if hasInitialUploadBackfillWork", continuation)
        self.assertIn("scheduleCurrentEnabledDataForUpload()", continuation)
        migration_gate = continuation.find("if requiresInitialBackfillFetchBeforeUpload")
        gated_fetch = continuation.find("scheduleLowPrioritySync()", migration_gate)
        gated_return = continuation.find("return", gated_fetch)
        fresh_queue = continuation.find("scheduleCurrentEnabledDataForUpload()", gated_return)
        self.assertTrue(
            -1 < migration_gate < gated_fetch < gated_return < fresh_queue,
            "Only ambiguous App-Store migration state may fetch first; a genuinely fresh "
            "backfill must still be queued immediately without the old 45-60 second delay.",
        )
        start = method_body(
            MANAGER,
            "func startPostInitializationRecoveryLifecycle",
        )
        foreground = method_body(MANAGER, "@objc func performForegroundSyncIfNeeded")
        self.assertIn("await self.continueEnabledSyncAfterAccountVerification()", start)
        self.assertIn("await self.continueEnabledSyncAfterAccountVerification()", foreground)

    def test_reenable_does_not_reupload_an_unchanged_library(self):
        episodes = method_body(MANAGER, "private func applyEpisodesSyncEnabled")
        subscriptions = method_body(MANAGER, "private func applySubscriptionsSyncEnabled")
        for body in [episodes, subscriptions]:
            self.assertNotIn("hasParticipated", body)
            disabled_branch = body.split("} else {", 1)[1]
            self.assertNotIn("clearInitial", disabled_branch)

        changed = method_body(MANAGER, "func syncOptionsChanged")
        disabled_all = changed.split('logSyncEvent("iCloud Sync deaktiviert")', 1)[1]
        self.assertNotIn("clearInitialUploadCursors()", disabled_all)

        capture = method_body(LOCAL_CHANGES, "@objc nonisolated func coreDataDidChange")
        continuation = method_body(MANAGER, "func continueEnabledSyncAfterAccountVerification")
        self.assertIn("episodesSyncHasParticipatedKey", capture)
        self.assertIn("subscriptionsSyncHasParticipatedKey", capture)
        self.assertNotIn("ICiCloudSyncEpisodesEnabled", capture)
        self.assertNotIn("ICiCloudSyncSubscriptionsEnabled", capture)
        self.assertIn("await drainLocalOutbox()", continuation)
        self.assertIn("queueDeviceRecord(scheduleSync: false)", changed)

    def test_each_cloudkit_ack_advances_visible_backfill_progress(self):
        batch = MANAGER[MANAGER.find("struct InitialUploadBatch"):]
        batch = batch[:batch.find("\n    }")]
        counts = method_body(MANAGER, "@objc var syncCounts")
        self.assertIn("episodeRecordCount", batch)
        self.assertIn("subscriptionRecordCount", batch)
        self.assertIn("acknowledgedInitialUploadCount", counts)
        acknowledged = method_body(MANAGER, "func acknowledgedInitialUploadCount")
        self.assertIn("unresolvedSubscriptionIdentities", acknowledged)
        self.assertIn("Set(batch.subscriptionRecordNames.compactMap", acknowledged)
        self.assertIn("batch.subscriptionRecordCount - unresolvedSubscriptionIdentities.count", acknowledged)
        self.assertNotIn("resolvedRecordCount / 2", acknowledged)

        # A-save and B-save are individually ACKed while both inverse tombstone deletes
        # remain pending. No logical subscription is complete, even though two of four
        # operations are resolved globally.
        unresolved = {"subscriptionTombstone-A", "subscriptionTombstone-B"}
        unresolved_identities = {
            name.removeprefix("subscriptionTombstone-").removeprefix("subscription-")
            for name in unresolved
        }
        self.assertEqual(2 - len(unresolved_identities), 0)

    def test_backfill_status_is_live_not_a_stale_saved_string(self):
        status = method_body(MANAGER, "@objc var statusText")
        self.assertIn("if hasInitialUploadBackfillWork", status)
        self.assertIn("return backfillProgressStatusText()", status)
        self.assertLess(
            status.find("return backfillProgressStatusText()"),
            status.find("syncActivityStatusText()"),
            "Confirmed backfill cursors must drive the visible X/Y value for every page.",
        )
        advance = method_body(MANAGER, "func advanceConfirmedInitialUploadBatches")
        self.assertIn("Prüft, ob alle Daten auf iCloud angekommen sind…", advance)

    def test_remote_batch_size_is_never_used_as_a_global_progress_total(self):
        fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
        apply_batch = method_body(REMOTE, "func processFetchedModificationBatch")
        activity = method_body(METADATA, "func syncActivityStatusText")
        self.assertNotIn("expectedByLabel", fetched)
        self.assertNotIn("expectedByLabel", apply_batch)
        self.assertNotIn("syncActivityExpectedCount", activity)
        self.assertNotIn('"%@ %ld/%ld %@"', activity)
        for orphan in [
            "syncActivityExpectedCount",
            "syncActivityKindLabel",
            "syncActivityStartDate",
            "activityKindLabel(forRecordType:",
        ]:
            self.assertNotIn(orphan, ALL)

    def test_record_origin_uses_the_cloudkit_field_and_local_echoes_skip_main_apply(self):
        direction = method_body(REMOTE, "func fetchedActivityDirection")
        fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
        sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
        self.assertIn("localEchoModifications", fetched)
        self.assertIn("remoteModifications", fetched)
        self.assertIn("recentlyUploadedRecordVersions", fetched)
        self.assertIn("record.recordChangeTag", fetched)
        self.assertIn("record.recordChangeTag", sent)
        self.assertIn(
            "isVisibleSyncActivityRecordType(record.recordType)",
            sent,
            "Settings/list singleton saves need their acknowledged change tag too; "
            "otherwise their exact fetch echo is falsely shown as a download.",
        )
        self.assertIn("guard let uploadedChangeTag", fetched)
        self.assertIn("let fetchedChangeTag = record.recordChangeTag", fetched)
        self.assertIn("uploadedChangeTag == fetchedChangeTag", fetched)
        self.assertNotIn("] == record.recordChangeTag", fetched)
        self.assertIn("guard let localEchoChangeTag", fetched)
        self.assertIn("return true", fetched)
        self.assertIn("removeValue(forKey:", fetched)
        bulk = method_body(MANAGER, "func isBulkEchoRecord")
        self.assertIn("RecordKind.episodeState", bulk)
        self.assertIn("RecordKind.subscription", bulk)
        self.assertIn("RecordKind.subscriptionTombstone", bulk)
        self.assertNotIn("RecordKind.appSettings", bulk)
        self.assertIn(
            "recordSyncActivity(verifiedOwnEchoModifications.count)",
            fetched,
            "A verified singleton echo must visibly report verification even though it "
            "still passes through remote apply.",
        )
        self.assertIn("orderedModifications(remoteModifications)", fetched)
        self.assertNotIn("orderedModifications(event.modifications)", fetched)
        self.assertIn("remoteModifications.contains", direction)
        self.assertIn("verifiedOwnEchoModifications.contains", direction)
        self.assertIn("verifiedOwnEchoRecordNames", direction)
        self.assertIn("deletions.contains", direction)
        self.assertIn("remoteModifications: remoteModifications", fetched)
        self.assertIn("verifiedOwnEchoModifications: verifiedOwnEchoModifications", fetched)
        self.assertIn("deletions: event.deletions", fetched)
        self.assertNotIn('record["deviceID"]', direction)

        def is_exact_echo(uploaded_tag, fetched_tag, same_device):
            return (uploaded_tag is not None
                    and fetched_tag is not None
                    and uploaded_tag == fetched_tag
                    and same_device)

        self.assertFalse(is_exact_echo(None, None, True),
                         "A tagless callback was never acknowledged and must be applied remotely.")
        self.assertFalse(is_exact_echo("ack-1", "remote-2", True),
                         "A cloned device ID with another server version is a real download.")
        self.assertTrue(is_exact_echo("ack-1", "ack-1", True))

    def test_count_cache_cannot_survive_an_option_change(self):
        changed = method_body(MANAGER, "func syncOptionsChanged")
        refresh = method_body(MANAGER, "func refreshSyncTotalCountsInBackground")
        self.assertIn("cachedSyncTotalCounts = nil", changed)
        self.assertIn("episodesEnabled == self.episodesSyncEnabled", refresh)
        self.assertIn("subscriptionsEnabled == self.subscriptionsSyncEnabled", refresh)
        self.assertIn("settingsEnabled == self.settingsSyncEnabled", refresh)

    def test_fetch_gated_settings_upload_is_sent_in_the_same_cycle(self):
        low_priority = method_body(MANAGER, "func performLowPrioritySync")
        fetch = low_priority.find("try await syncEngine.fetchChanges()")
        follow_up_send = low_priority.find("sendChangesAndApplyCallbackOutcomes", fetch)
        self.assertNotEqual(fetch, -1)
        self.assertGreater(
            follow_up_send,
            fetch,
            "The first empty-cloud fetch queues settings_app; it must be sent immediately "
            "instead of waiting for another full low-priority cycle and fetch.",
        )


if __name__ == "__main__":
    unittest.main()
