#!/usr/bin/env python3
"""Pins initial-backfill participation to one verified account and live zone."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
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


# `*HasParticipated` is deliberately only the durable OFF-state outbox capture gate.
# It was historically set on enable, not on completion, and therefore cannot prove that
# an initial upload completed for the current CloudKit account/zone.
for key in [
    "initialEpisodeBackfillAccountKey",
    "initialSubscriptionBackfillAccountKey",
    "initialEpisodeBackfillCompletedAccountKey",
    "initialSubscriptionBackfillCompletedAccountKey",
]:
    require(key in MANAGER, f"Missing account-bound initial-backfill state: {key}")

episodes_enable = method_body(MANAGER, "private func applyEpisodesSyncEnabled")
subscriptions_enable = method_body(MANAGER, "private func applySubscriptionsSyncEnabled")
for body in [episodes_enable, subscriptions_enable]:
    require("hasParticipated" not in body,
            "The historical participation bool must not decide whether a backfill is complete.")

continuation = method_body(MANAGER, "func continueEnabledSyncAfterAccountVerification")
require("prepareInitialBackfillsForVerifiedAccount()" in continuation,
        "Every verified continuation must validate backfill state against the current account/zone.")
require(continuation.find("prepareInitialBackfillsForVerifiedAccount()")
        < continuation.find("if hasInitialUploadBackfillWork"),
        "Account-bound backfill state must be prepared before choosing backfill vs no-op.")

start = method_body(MANAGER, "@objc func start")
startup_recovery = method_body(MANAGER, "func startPostInitializationRecoveryLifecycle")
reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require("migrateResumableInitialBackfillAccountsIfNeeded()" not in start,
        "Legacy migration must not commit against an unverified or missing persisted account.")
require("migrateResumableInitialBackfillAccountsIfNeeded()" in reconcile
        and reconcile.find("migrateResumableInitialBackfillAccountsIfNeeded()")
        < reconcile.find("setICloudAccountIdentityVerified(true)"),
        "Migration must run after account binding/reset cleanup but before the verified callback gate opens.")
require(start.find("episodesSyncHasParticipatedKey") < start.find("startPostInitializationRecoveryLifecycle()")
        and start.find("subscriptionsSyncHasParticipatedKey") < start.find("startPostInitializationRecoveryLifecycle()")
        and "refreshAccountStatus()" in startup_recovery,
        "Legacy participation evidence must be reconstructed before account verification can migrate it.")

prepare = method_body(MANAGER, "func prepareInitialBackfillsForVerifiedAccount")
for token in [
    "initialEpisodeBackfillAccountKey",
    "initialSubscriptionBackfillAccountKey",
    "initialEpisodeBackfillCompletedAccountKey",
    "initialSubscriptionBackfillCompletedAccountKey",
    "initialEpisodeBackfillOffsetKey",
    "initialSubscriptionBackfillOffsetKey",
]:
    require(token in prepare, f"Verified backfill preparation does not consult {token}.")


def needs_full_seed(account, started_account, completed_account, cursor):
    if completed_account == account:
        return False
    if started_account == account and cursor is not None:
        return False
    return True


require(not needs_full_seed("A", "A", "A", None),
        "Completed same-account OFF→ON must remain a no-op backfill.")
require(not needs_full_seed("A", "A", None, "hash-3000"),
        "Incomplete same-account OFF→ON must resume its confirmed cursor.")
require(needs_full_seed("B", "A", "A", None),
        "Account A participation must never suppress Account B's initial seed.")
require(needs_full_seed("A", None, None, None),
        "A deleted/recreated zone must require a fresh seed.")


def migrate_legacy_backfill(enabled, participated, offset, cursor, reset_required):
    if reset_required:
        return None
    if participated and not enabled:
        return "fetch_on_reenable"
    if offset is not None:
        return "fetch_then_resume"
    if enabled and participated and cursor is None:
        return "fetch_then_reseed"
    return None


require(migrate_legacy_backfill(True, True, None, None, False) == "fetch_then_reseed",
        "Legacy participation without a completion marker is ambiguous and must fetch before an idempotent reseed.")
require(migrate_legacy_backfill(True, True, 3000, "hash-3000", False) == "fetch_then_resume",
        "An enabled, interrupted App-Store backfill must fetch before retaining its resume cursor.")
require(migrate_legacy_backfill(False, True, None, None, False) == "fetch_on_reenable",
        "An OFF legacy category has no safe completion proof and must fetch before a later reseed.")
require(migrate_legacy_backfill(True, True, None, None, True) is None,
        "A stale account pending reset must never receive migrated completion state.")

migration = method_body(MANAGER, "func migrateResumableInitialBackfillAccountsIfNeeded")
for token in [
    "initialBackfillAccountMigrationCompletedKey",
    "episodesSyncEnabled",
    "subscriptionsSyncEnabled",
    "episodesSyncHasParticipatedKey",
    "subscriptionsSyncHasParticipatedKey",
    "initialEpisodeBackfillCompletedAccountKey",
    "initialSubscriptionBackfillCompletedAccountKey",
]:
    require(token in migration, f"Legacy completed-backfill migration does not consult {token}.")
migration_commit = migration.rfind(
    "defaults.set(true, forKey: Self.initialBackfillAccountMigrationCompletedKey)"
)
require(migration_commit > migration.find("guard !isICloudAccountResetRequired")
        and migration_commit > migration.find("initialSubscriptionBackfillCompletedAccountKey"),
        "The one-time migration marker must commit last so a crash or missing account cannot suppress its retry.")
require("initialBackfillFetchBeforeUploadAccountKey" in migration
        and "resetInitialEpisodeBackfillCursor()" in migration
        and "resetInitialSubscriptionBackfillCursor()" in migration,
        "Ambiguous legacy completion must become an account-bound fetch-before-reseed, never a blind completed marker.")
require("defaults.set(accountRecordName, forKey: Self.initialEpisodeBackfillCompletedAccountKey)" not in migration
        and "defaults.set(accountRecordName, forKey: Self.initialSubscriptionBackfillCompletedAccountKey)" not in migration,
        "Legacy participation alone cannot prove that either category reached CloudKit.")
require("suppressSubscriptionDeletionsKey" in migration,
        "A migrated subscription fetch must preserve local subscriptions until its complete catch-up fetch is applied.")

require("requiresInitialBackfillFetchBeforeUpload" in continuation
        and "scheduleLowPrioritySync()" in continuation,
        "The migrated backfill must fetch remote state instead of queueing local records immediately.")
low_priority = method_body(MANAGER, "func performLowPrioritySync")
require("requiresInitialBackfillFetchBeforeUpload" in low_priority,
        "Fetch-before-reseed must bypass the normal send-only backfill optimization.")
require(low_priority.find("fetchChangesForInitialBackfillMigration")
        < low_priority.find("sendChangesAndApplyCallbackOutcomes"),
        "A migrated backfill must fetch before any user-record send path can run.")
manual_sync = method_body(MANAGER, "func performManualSync() async throws")
background_sync = method_body(MANAGER, "@objc func performBackgroundSyncWithCompletion")
require("fetchChangesForInitialBackfillMigration" in manual_sync
        and "fetchChangesForInitialBackfillMigration" in background_sync,
        "Manual and background entry points must obey the same fetch-before-reseed gate.")
gated_fetch = method_body(MANAGER, "func fetchChangesForInitialBackfillMigration")
require("database.save(CKRecordZone(zoneID: zoneID))" in gated_fetch
        and gated_fetch.find("database.save") < gated_fetch.find("syncEngine.fetchChanges"),
        "The private zone must exist before the safe migration fetch; creating it must not send user records.")
send_loop = method_body(MANAGER, "func sendChangesAndApplyCallbackOutcomes")
require(send_loop.count("!requiresInitialBackfillFetchBeforeUpload") >= 2,
        "Every send-loop iteration must re-check the migration gate, not only the call entry.")
batch = method_body(ENGINE, "nonisolated func nextRecordZoneChangeBatch")
snapshot = ENGINE[ENGINE.find("struct SyncEngineCallbackSnapshot"):]
snapshot = snapshot[:snapshot.find("\n    }")]
require("requiresInitialBackfillFetchBeforeUpload" in snapshot
        and "!snapshot.requiresInitialBackfillFetchBeforeUpload" in batch,
        "A send already in progress must re-read and enforce the fetch gate for every CloudKit batch.")
gate = method_body(MANAGER, "var requiresInitialBackfillFetchBeforeUpload")
snapshot_builder = method_body(ENGINE, "nonisolated static func syncEngineCallbackSnapshot")
require("hasStoredInitialBackfill" not in gate and "hasStoredBackfill" not in snapshot_builder,
        "The durable legacy-category gate must close as soon as OFF→ON writes enabled, before its checkpoint is recreated.")
status = method_body(MANAGER, "@objc var statusText")
gate_status = 'NSLocalizedString("Vorhandene iCloud-Daten werden vor dem Hochladen geprüft…", comment: "")'
require(gate_status in status
        and status.find("requiresInitialBackfillFetchBeforeUpload")
        < status.find("if hasInitialUploadBackfillWork"),
        "Fetch-before-reseed must never claim that records are uploading or downloading before the fetch completes.")
schedule_initial = method_body(MANAGER, "func scheduleCurrentEnabledDataForUpload")
queue_next = method_body(MANAGER, "func queueNextInitialUploadPageDuringActiveSend")
require("!requiresInitialBackfillFetchBeforeUpload" in schedule_initial
        and "!requiresInitialBackfillFetchBeforeUpload" in queue_next,
        "No eager or send-loop path may bypass the migrated fetch gate.")
did_fetch = ENGINE.split("case .didFetchChanges:", 1)[1].split(
    "case .didFetchRecordZoneChanges", 1
)[0]
require("completeInitialBackfillFetchBeforeUploadIfNeeded()" in did_fetch,
        "Only a complete successfully applied CloudKit fetch may release the migrated reseed.")

update_episode = method_body(MANAGER, "func updateInitialEpisodeBackfillCursor")
update_subscription = method_body(MANAGER, "func updateInitialSubscriptionBackfillCursor")
require("markInitialEpisodeBackfillCompleted" in update_episode,
        "Only the final confirmed episode cursor may mark the account backfill complete.")
require("markInitialSubscriptionBackfillCompleted" in update_subscription,
        "Only the final confirmed subscription cursor may mark the account backfill complete.")
for signature in ["func clearInitialEpisodeBackfillCursor", "func clearInitialSubscriptionBackfillCursor"]:
    clear = method_body(MANAGER, signature)
    require("Completed" not in clear,
            "Generic cursor clearing (reset/delete) must not mark an upload complete.")

reset = method_body(MANAGER, "func resetAllLocalSyncMetadata")
require("preserveInitialBackfillState" in reset and "invalidateInitialBackfillParticipation" in reset,
        "Destructive metadata resets must invalidate account/zone completion state explicitly.")
transition = method_body(REMOTE, "func resetForICloudAccountTransition")
require("preserveInitialBackfillState: true" in transition,
        "A verified same-account sign-out/in must preserve incomplete cursors and completion state.")
sign_out_branch = transition.split("guard reinitializeEngine else", 1)[1].split("return", 1)[0]
require("resetInitialBackfillCursorsForEnabledOptions" not in sign_out_branch,
        "Sign-out cannot reset cursors before CloudKit identifies whether the account changed.")

zone_deletion = method_body(REMOTE, "func handleFetchedDatabaseChanges")
require("invalidateInitialBackfillParticipation()" in zone_deletion
        and "resetInitialBackfillCursorsForEnabledOptions()" in zone_deletion,
        "A fetched deletion of the custom zone must invalidate completion for OFF categories and reseed ON categories.")
require(".saveZone(CKRecordZone(zoneID: zoneID))" in zone_deletion
        and zone_deletion.find(".saveZone(CKRecordZone(zoneID: zoneID))")
        < zone_deletion.find("scheduleCurrentEnabledDataForUpload()"),
        "A fetched zone deletion must recreate the zone before queueing the replacement records.")
sent_changes = method_body(REMOTE, "func handleSentRecordZoneChanges")
require(".zoneNotFound" in sent_changes
        and "invalidateInitialBackfillParticipation()" in sent_changes
        and "resetInitialBackfillCursorsForEnabledOptions()" in sent_changes,
        "A send that proves the zone disappeared must also invalidate completion before recreating it.")
delete_all = method_body(MANAGER, "@objc func deleteAllICloudDataWithCompletion")
require(delete_all.find("invalidateInitialBackfillParticipation()")
        > delete_all.find("database.deleteRecordZone")
        and delete_all.find("invalidateInitialBackfillParticipation()")
        < delete_all.find("deleteAllPendingEpisodeStates()"),
        "A successful explicit zone deletion must invalidate completion before fallible local cleanup.")

capture = method_body((ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text(),
                      "@objc nonisolated func coreDataDidChange")
require("episodesSyncHasParticipatedKey" in capture
        and "subscriptionsSyncHasParticipatedKey" in capture,
        "Same-account OFF/offline changes must remain journaled independently of completion state.")

print("iCloud account/zone participation regression checks passed")
