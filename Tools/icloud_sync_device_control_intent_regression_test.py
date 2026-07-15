#!/usr/bin/env python3
"""Pins durable, account-scoped ICDevice save/delete control intents.

The current final-device boolean and direct delete queue cannot identify the exact
revision/account that CloudKit acknowledged.  These tests stay red until saves and
device-list deletes use one durable revisioned intent path.
"""

from __future__ import annotations

import unittest
from dataclasses import asdict, dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
SOURCE = "\n".join((MANAGER, ENGINE, REMOTE, METADATA, TYPES))


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


@dataclass(frozen=True)
class ControlIntent:
    account: str
    target_device_id: str
    operation: str
    revision: str
    payload: dict[str, bool] | None
    pending_cleanup_device_ids: tuple[str, ...] = ()


class ControlIntentStoreModel:
    def __init__(self, rows=None, cached_devices=None):
        self.rows: dict[tuple[str, str], ControlIntent] = {}
        for row in rows or []:
            intent = ControlIntent(**row)
            self.rows[(intent.account, intent.target_device_id)] = intent
        self.cached_devices = set(cached_devices or ())
        self.retry_requested = False

    def capture(self, intent: ControlIntent) -> None:
        self.rows[(intent.account, intent.target_device_id)] = intent

    def pending_for(self, account: str) -> list[ControlIntent]:
        return [row for row in self.rows.values() if row.account == account]

    def acknowledge(self, *, account: str, target: str, operation: str, revision: str) -> bool:
        key = (account, target)
        current = self.rows.get(key)
        if current is None or current.operation != operation or current.revision != revision:
            return False
        del self.rows[key]
        if operation == "delete":
            self.cached_devices.discard(target)
        return True

    def acknowledge_save_and_promote_cleanup(
            self, *, account: str, target: str, revision: str) -> bool:
        key = (account, target)
        current = self.rows.get(key)
        if (current is None
                or current.operation != "save"
                or current.revision != revision):
            return False
        del self.rows[key]
        for old_device_id in current.pending_cleanup_device_ids:
            self.capture(ControlIntent(
                account,
                old_device_id,
                "delete",
                f"cleanup-{revision}-{old_device_id}",
                None,
            ))
        return True

    def complete_delete(self, *, account: str, target: str, revision: str, result: str) -> bool:
        if result == "unknownItem":
            return self.acknowledge(
                account=account,
                target=target,
                operation="delete",
                revision=revision,
            )
        if result == "transient":
            self.retry_requested = True
            return False
        raise AssertionError(f"Unexpected modeled result: {result}")

    def serialized_rows(self) -> list[dict]:
        return [asdict(row) for row in self.rows.values()]


class IdentityCleanupLedgerModel:
    def __init__(self, cleanup_ids: set[str]):
        self.cleanup_ids = cleanup_ids
        self.completed_accounts: set[str] = set()

    def cleanup_for(self, account: str) -> set[str]:
        if account in self.completed_accounts:
            return set()
        return set(self.cleanup_ids)

    def complete(self, account: str) -> None:
        self.completed_accounts.add(account)


class DeviceControlIntentRegressionTests(unittest.TestCase):
    def test_account_a_b_a_resumes_only_the_matching_scope(self) -> None:
        store = ControlIntentStoreModel()
        delete_a = ControlIntent("A", "stale-phone", "delete", "a-delete-1", None)
        save_b = ControlIntent(
            "B", "this-phone", "save", "b-save-1",
            {"episodesEnabled": False, "subscriptionsEnabled": True, "settingsEnabled": False},
        )
        store.capture(delete_a)
        self.assertEqual(store.pending_for("B"), [])
        store.capture(save_b)
        self.assertEqual(store.pending_for("A"), [delete_a])
        self.assertEqual(store.pending_for("B"), [save_b])

        self.assertTrue(
            "struct PendingDeviceControlIntent" in SOURCE,
            "The current unscoped final-device boolean/direct delete cannot survive A→B→A safely.",
        )
        intent = method_body(SOURCE, "struct PendingDeviceControlIntent")
        for field in (
            "accountRecordName", "targetDeviceID", "operation", "revision", "payloadData",
            "pendingCleanupDeviceIDs",
        ):
            self.assertIn(field, intent)
        pending_status = method_body(SOURCE, "var hasPendingDeviceControlIntents")
        self.assertIn("isICloudAccountIdentityVerified", pending_status)
        self.assertIn("accountUserRecordNameKey", pending_status)
        self.assertIn(
            "$0.accountRecordName == accountRecordName",
            pending_status,
            "After account verification, another account's durable intent must not keep "
            "the current account's status or sender active.",
        )
        resume = method_body(SOURCE, "func resumePendingDeviceControlIntentsForVerifiedAccount")
        self.assertIn("accountUserRecordNameKey", resume)
        self.assertIn("accountRecordName", resume)
        reset_start = MANAGER.find("func resetAllLocalSyncMetadata")
        reset_declaration = MANAGER[reset_start:MANAGER.find("{", reset_start)]
        self.assertIn("preservePendingDeviceControlIntents", reset_declaration)
        account_transition = method_body(REMOTE, "func resetForICloudAccountTransition")
        self.assertIn(
            "preservePendingDeviceControlIntents: true",
            account_transition,
            "An account transition must retain A's scoped pending intent so A→B→A can resume it.",
        )
        reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
        self.assertIn("resumePendingDeviceControlIntentsForVerifiedAccount", reconcile)

    def test_old_identity_cleanup_is_completed_per_account_not_globally(self) -> None:
        ledger = IdentityCleanupLedgerModel({"old-installation"})
        self.assertEqual(ledger.cleanup_for("A"), {"old-installation"})
        ledger.complete("A")
        self.assertEqual(ledger.cleanup_for("A"), set())
        self.assertEqual(
            ledger.cleanup_for("B"),
            {"old-installation"},
            "Cleaning the private CloudKit database for A says nothing about B's database.",
        )

        identity_state = method_body(SOURCE, "struct InstallationDeviceIdentityState")
        self.assertIn(
            "cleanupCompletedAccountRecordNames",
            identity_state,
            "The ThisDeviceOnly identity ledger must remember cleanup completion per "
            "CloudKit account while retaining old IDs for accounts visited later.",
        )
        capture_save = method_body(SOURCE, "func persistPendingDeviceControlSaveIntent")
        self.assertIn("pendingInstallationDeviceCleanupIDs", capture_save)
        promotion = method_body(
            SOURCE, "func promotePendingDeviceCleanupAfterSaveAcknowledgement"
        )
        self.assertNotIn(
            "clearInstallationDevicePendingCleanupIDs",
            promotion,
            "A save acknowledgement in account A must not globally discard cleanup IDs.",
        )
        acknowledge_deletes = method_body(
            SOURCE, "func acknowledgePendingDeviceControlDeletes"
        )
        self.assertIn(
            "acknowledgedInstallationCleanup",
            acknowledge_deletes,
            "Deleting an unrelated device must not mark the migration cleanup complete.",
        )
        self.assertIn(
            "completeInstallationDeviceCleanupIfPossible",
            acknowledge_deletes,
            "Account cleanup becomes complete only after every exact cleanup delete ACK.",
        )

    def test_stale_save_ack_with_same_options_cannot_clear_newer_revision(self) -> None:
        store = ControlIntentStoreModel()
        payload = {
            "episodesEnabled": False,
            "subscriptionsEnabled": False,
            "settingsEnabled": False,
        }
        store.capture(ControlIntent("A", "this-phone", "save", "r1", payload))
        store.capture(ControlIntent("A", "this-phone", "save", "r2", payload))
        self.assertFalse(store.acknowledge(
            account="A", target="this-phone", operation="save", revision="r1"
        ))
        self.assertEqual(store.pending_for("A")[0].revision, "r2")
        self.assertTrue(store.acknowledge(
            account="A", target="this-phone", operation="save", revision="r2"
        ))

        device_builder = method_body(
            ENGINE, "nonisolated static func deviceRecordForSyncEngineCallback"
        )
        self.assertIn("snapshot.pendingDeviceControlIntents", device_builder)
        self.assertIn("payloadDictionary", device_builder)
        self.assertIn(
            "localMutationRevisionPayloadKey",
            device_builder,
            "Comparing only three booleans lets an older identical ICDevice save ACK "
            "clear a newer intent; the sent revision must travel in the record.",
        )
        sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
        self.assertIn("acknowledgePendingDeviceControlSave", sent)
        acknowledge = method_body(SOURCE, "func acknowledgePendingDeviceControlSave")
        self.assertIn("sentRevision", acknowledge)
        self.assertIn("currentRevision", acknowledge)
        self.assertIn("currentRevision == sentRevision", acknowledge)

    def test_device_conflict_requeues_the_durable_revision_in_the_same_send_cycle(self) -> None:
        failed_save = method_body(REMOTE, "func handleFailedRecordSave")
        device_branch = failed_save.find("serverRecord.recordType == RecordKind.device")
        retry = failed_save.find("retryRecords.append(.saveRecord(recordID))", device_branch)
        immediate = failed_save.find(
            "requiresImmediateFinalDeviceRecordResend = true",
            device_branch,
        )
        self.assertTrue(
            -1 not in (device_branch, retry, immediate)
            and device_branch < retry
            and device_branch < immediate,
            "A serverRecordChanged result removes the attempted CKSyncEngine change. "
            "The durable ICDevice revision must be requeued immediately instead of "
            "showing sync complete until another unrelated trigger occurs.",
        )

    def test_delete_sends_and_retries_with_every_category_off(self) -> None:
        store = ControlIntentStoreModel(cached_devices={"stale-phone"})
        delete = ControlIntent("A", "stale-phone", "delete", "delete-1", None)
        store.capture(delete)
        categories = (False, False, False)
        self.assertFalse(any(categories))
        self.assertEqual(store.pending_for("A"), [delete])
        self.assertFalse(store.complete_delete(
            account="A", target="stale-phone", revision="delete-1", result="transient"
        ))
        self.assertTrue(store.retry_requested)
        self.assertEqual(store.pending_for("A"), [delete])
        self.assertIn("stale-phone", store.cached_devices)

        delete_device = method_body(METADATA, "@objc func deleteDevice(withID")
        persist_index = delete_device.find("persistPendingDeviceControlDeleteIntent")
        queue_index = delete_device.find("pendingRecordZoneChanges")
        self.assertTrue(
            persist_index != -1
            and queue_index != -1
            and persist_index < queue_index,
            "Device deletion must commit its durable intent before CK queue mutation.",
        )
        self.assertRegex(
            delete_device[:queue_index],
            r"guard\s+(?:let\s+\w+\s*=\s*)?persistPendingDeviceControlDeleteIntent",
            "A failed durable delete-intent write must stop before the CK queue is touched.",
        )
        control_sender = method_body(SOURCE, "func sendPendingDeviceControlIntents")
        self.assertNotIn(
            "anySyncEnabled",
            control_sender,
            "A dedicated control sender must not be gated by the three user-data categories.",
        )
        retry = method_body(MANAGER, "func scheduleSyncRetryAfterFailure(code:")
        self.assertIn("hasPendingDeviceControlIntents", retry)
        self.assertIn("resumePendingDeviceControlIntentsForVerifiedAccount", retry)

    def test_offline_delete_is_captured_in_the_pending_account_scope(self) -> None:
        delete_capture = method_body(
            SOURCE, "func persistPendingDeviceControlDeleteIntent"
        )
        self.assertIn(
            "deviceControlCaptureAccountRecordName()",
            delete_capture,
            "A cold offline launch has no verified callback account yet; the delete must "
            "survive in the same bind-on-verification scope as other offline edits.",
        )
        self.assertNotIn(
            "verifiedAccountRecordNameForLocalCapture()",
            delete_capture,
            "Requiring a verified account silently discards an offline swipe deletion.",
        )
        bind = method_body(SOURCE, "func bindPendingDeviceControlIntents")
        self.assertIn("sourceAccountRecordName", bind)
        self.assertIn("accountRecordName", bind)
        delete_device = method_body(METADATA, "@objc func deleteDevice(withID")
        self.assertIn("!isICloudAccountIdentityVerified", delete_device)
        self.assertIn("await refreshAccountStatus()", delete_device)
        self.assertIn(
            "resumePendingDeviceControlIntentsForVerifiedAccount()",
            delete_device,
            "With every category off, an intent created after start otherwise has no "
            "account-verification producer until the next app launch.",
        )

    def test_device_cache_remains_until_exact_delete_ack(self) -> None:
        store = ControlIntentStoreModel(cached_devices={"stale-phone"})
        store.capture(ControlIntent("A", "stale-phone", "delete", "delete-r2", None))
        self.assertIn("stale-phone", store.cached_devices)
        self.assertFalse(store.acknowledge(
            account="A", target="stale-phone", operation="delete", revision="delete-r1"
        ))
        self.assertIn("stale-phone", store.cached_devices)
        self.assertTrue(store.acknowledge(
            account="A", target="stale-phone", operation="delete", revision="delete-r2"
        ))
        self.assertNotIn("stale-phone", store.cached_devices)

        delete_device = method_body(METADATA, "@objc func deleteDevice(withID")
        self.assertNotIn(
            "removeDeviceFromCache",
            delete_device,
            "deleteDevice currently removes the visible row optimistically; it must remain "
            "until CloudKit confirms this exact delete revision.",
        )
        acknowledge = method_body(SOURCE, "func acknowledgePendingDeviceControlDeletes")
        revision_match = acknowledge.find("currentRevision == sentRevision")
        cache_removal = acknowledge.find("removeDeviceFromCache")
        intent_removal = acknowledge.find("clearPendingDeviceControlIntent")
        self.assertTrue(
            -1 not in (revision_match, cache_removal, intent_removal)
            and revision_match < cache_removal
            and revision_match < intent_removal,
            "Cache and durable delete intent may be removed only after the exact "
            "success/unknownItem delete revision is acknowledged.",
        )

    def test_old_identity_cleanup_starts_only_after_exact_account_bound_new_save_ack(self) -> None:
        store = ControlIntentStoreModel(cached_devices={"legacy-id", "new-id"})
        new_save = ControlIntent(
            "A",
            "new-id",
            "save",
            "new-save-r2",
            {"episodesEnabled": True, "subscriptionsEnabled": False, "settingsEnabled": False},
            ("legacy-id",),
        )
        store.capture(new_save)
        self.assertEqual(
            [row for row in store.pending_for("A") if row.operation == "delete"],
            [],
        )
        self.assertFalse(store.acknowledge_save_and_promote_cleanup(
            account="B", target="new-id", revision="new-save-r2"
        ))
        self.assertFalse(store.acknowledge_save_and_promote_cleanup(
            account="A", target="new-id", revision="stale-save-r1"
        ))
        self.assertEqual(store.pending_for("A"), [new_save])
        self.assertTrue(store.acknowledge_save_and_promote_cleanup(
            account="A", target="new-id", revision="new-save-r2"
        ))
        cleanup = store.pending_for("A")
        self.assertEqual(len(cleanup), 1)
        self.assertEqual(
            (cleanup[0].target_device_id, cleanup[0].operation),
            ("legacy-id", "delete"),
        )
        self.assertIn("legacy-id", store.cached_devices)

        self.assertTrue(
            "func persistPendingDeviceControlSaveIntent" in SOURCE,
            "The new installation's save and deferred old-ID cleanup need one durable "
            "account-scoped control intent.",
        )
        capture_save = method_body(SOURCE, "func persistPendingDeviceControlSaveIntent")
        self.assertIn("pendingCleanupDeviceIDs", capture_save)
        self.assertNotIn("persistPendingDeviceControlDeleteIntent", capture_save)
        acknowledge = method_body(SOURCE, "func acknowledgePendingDeviceControlSave")
        account_match = acknowledge.find("accountRecordName")
        target_match = acknowledge.find("targetDeviceID == deviceID")
        revision_match = acknowledge.find("currentRevision == sentRevision")
        promote = acknowledge.find(
            "promotePendingDeviceCleanupAfterSaveAcknowledgement"
        )
        self.assertTrue(
            -1 not in (account_match, target_match, revision_match, promote)
            and account_match < target_match < revision_match < promote,
            "The legacy/surviving ID may become a delete intent only after the exact "
            "new-device save revision is acknowledged in its owning account.",
        )
        promotion = method_body(
            SOURCE, "func promotePendingDeviceCleanupAfterSaveAcknowledgement"
        )
        self.assertIn("persistPendingDeviceControlDeleteIntent", promotion)
        self.assertIn("pendingCleanupDeviceIDs", promotion)

    def test_kill_relaunch_rehydrates_the_exact_control_revision(self) -> None:
        before_kill = ControlIntentStoreModel()
        intent = ControlIntent("A", "stale-watch", "delete", "delete-7", None)
        before_kill.capture(intent)
        after_relaunch = ControlIntentStoreModel(before_kill.serialized_rows())
        self.assertEqual(after_relaunch.pending_for("A"), [intent])

        self.assertTrue(
            'pendingDeviceControlIntentsKey = "ICiCloudSyncPendingDeviceControlIntents"' in SOURCE,
            "CKSyncEngine pending state alone is not a kill-safe device control intent.",
        )
        file_backed = method_body(MANAGER, "nonisolated static var fileBackedSyncMetadataKeys")
        self.assertIn("pendingDeviceControlIntentsKey", file_backed)
        start = method_body(MANAGER, "@objc func start")
        self.assertIn("startPostInitializationRecoveryLifecycle()", start)
        lifecycle = method_body(MANAGER, "func startPostInitializationRecoveryLifecycle()")
        self.assertIn("self.anySyncEnabled || self.hasPendingDeviceControlIntents", lifecycle)
        self.assertIn("resumePendingDeviceControlIntentsForVerifiedAccount", lifecycle)

    def test_unknown_item_completes_only_the_exact_delete_attempt(self) -> None:
        store = ControlIntentStoreModel(cached_devices={"stale-phone"})
        store.capture(ControlIntent("A", "stale-phone", "delete", "d1", None))
        # A newer delete can replace the durable row while d1 is in flight.
        store.capture(ControlIntent("A", "stale-phone", "delete", "d2", None))
        self.assertFalse(store.complete_delete(
            account="A", target="stale-phone", revision="d1", result="unknownItem"
        ))
        self.assertEqual(store.pending_for("A")[0].revision, "d2")
        self.assertIn("stale-phone", store.cached_devices)
        self.assertTrue(store.complete_delete(
            account="A", target="stale-phone", revision="d2", result="unknownItem"
        ))
        self.assertNotIn("stale-phone", store.cached_devices)

        failed_delete = method_body(REMOTE, "func handleFailedRecordDelete")
        self.assertIn(".unknownItem", failed_delete)
        batch = method_body(ENGINE, "nonisolated func nextRecordZoneChangeBatch")
        self.assertTrue(
            "pendingDeviceControlIntent" in batch,
            "The batch must pin the exact durable device-delete revision before CloudKit sends it.",
        )
        sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
        self.assertTrue(
            "acknowledgePendingDeviceControlDeletes" in sent,
            "CloudKit unknownItem is terminal for delete, but production currently has "
            "no durable device-control revision to clear.",
        )
        acknowledge = method_body(SOURCE, "func acknowledgePendingDeviceControlDeletes")
        self.assertIn("sentRevision", acknowledge)
        self.assertIn("currentRevision == sentRevision", acknowledge)

    def test_legacy_unscoped_intent_uses_the_last_proven_account_before_a_to_b(self) -> None:
        reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
        migration = reconcile.find(
            "migrateLegacyFinalDeviceRecordUpdateIntentIfNeeded"
        )
        previous = reconcile.find("previousAccountUserRecordName")
        overwrite = reconcile.find(
            "defaults.set(currentAccountUserRecordName, forKey: Self.accountUserRecordNameKey)"
        )
        migration_end = reconcile.find(
            "let accountChangedWhileAppWasInactive",
            migration,
        )
        self.assertTrue(
            -1 not in (migration, previous, overwrite)
            and previous < migration < overwrite
            and "accountRecordName: previousAccountUserRecordName"
                in reconcile[migration:overwrite],
            "A→B verification must capture the legacy revision under the last verified "
            "account A before B overwrites the only proven account identity.",
        )
        self.assertNotIn(
            "accountRecordName: currentAccountUserRecordName",
            reconcile[migration:migration_end],
            "The legacy bool contains no evidence that the offline edit belonged to B.",
        )
        begin_switch = method_body(REMOTE, "func beginICloudAccountSwitch")
        previous_in_switch = begin_switch.find("previousAccountRecordName")
        migrate_in_switch = begin_switch.find(
            "migrateLegacyFinalDeviceRecordUpdateIntentIfNeeded"
        )
        remove_previous = begin_switch.find(
            "defaults.removeObject(forKey: Self.accountUserRecordNameKey)"
        )
        self.assertTrue(
            -1 not in (previous_in_switch, migrate_in_switch, remove_previous)
            and previous_in_switch < migrate_in_switch < remove_previous
            and "accountRecordName: previousAccountRecordName"
                in begin_switch[migrate_in_switch:remove_previous],
            "A CKSyncEngine switchAccounts event must migrate A's legacy intent before "
            "beginICloudAccountSwitch removes A from defaults.",
        )

    def test_delete_all_removes_only_the_current_accounts_control_intents(self) -> None:
        delete_all = method_body(
            MANAGER, "@objc func deleteAllICloudDataWithCompletion"
        )
        discard = delete_all.find("removePendingDeviceControlIntents")
        reset = delete_all.find("resetAllLocalSyncMetadata")
        self.assertTrue(
            -1 not in (discard, reset) and discard < reset,
            "After deleting B's zone, discard B's intents before resetting local metadata.",
        )
        self.assertIn(
            "preservePendingDeviceControlIntents: true",
            delete_all,
            "Delete-All for B must retain durable intents belonging to A.",
        )
        remove_scope = method_body(
            SOURCE, "func removePendingDeviceControlIntents"
        )
        self.assertIn("$0.accountRecordName == accountRecordName", remove_scope)


if __name__ == "__main__":
    unittest.main()
