#!/usr/bin/env python3
"""Pins durable, account-scoped singleton uploads across kills and stale ACKs."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


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


require('pendingSingletonUploadIntentsKey = "ICiCloudSyncPendingSingletonUploadIntents"' in MANAGER,
        "Singleton uploads need one atomic durable intent store.")
file_keys = method_body(MANAGER, "nonisolated static var fileBackedSyncMetadataKeys")
require("pendingSingletonUploadIntentsKey" in file_keys,
        "Singleton intents must survive a kill before CKSyncEngine serializes pending state.")
for token in ["accountRecordName", "revision", "modifiedAt"]:
    require(token in MANAGER, f"Singleton intent is missing {token}.")

persist = method_body(MANAGER, "func persistPendingSingletonUploadIntent")
intent_writer = method_body(MANAGER, "func writePendingSingletonUploadIntents")
require("writePendingSingletonUploadIntents" in persist
        and "writeSyncMetadataValue" in intent_writer
        and "revision: String = UUID().uuidString" in MANAGER,
        "Intent persistence must be atomic and every local mutation needs a distinct revision.")
resume = method_body(MANAGER, "func resumePendingSingletonUploadsForVerifiedAccount")
enabled_gate = method_body(MANAGER, "func singletonUploadIsEnabled")
for record_name in ["RecordPrefix.appSettings", "RecordPrefix.listScrollPositions",
                    "RecordPrefix.subscriptionListSettings"]:
    require(record_name in resume + enabled_gate, f"Cold-start intent resume is missing {record_name}.")
continuation = method_body(MANAGER, "func continueEnabledSyncAfterAccountVerification")
require("resumePendingSingletonUploadsForVerifiedAccount()" in continuation,
        "Verified startup/reconcile must restore durable singleton pending changes.")

settings_check = method_body(LOCAL, "func checkAndQueueSettingsChange")
settings_persist = settings_check.find("persistPendingSingletonUploadIntent")
settings_baseline = settings_check.find("setStoredSyncedSettingsHash(hash)")
settings_queue = settings_check.find("addPendingSave(appSettingsRecordID())")
require(-1 not in (settings_persist, settings_baseline, settings_queue)
        and settings_persist < settings_baseline < settings_queue,
        "Settings intent must commit before its baseline/date and CK pending key.")
list_persist = settings_check.rfind("persistPendingSingletonUploadIntent")
list_baseline = settings_check.find("subscriptionListSettingsBaselineKey", list_persist)
list_queue = settings_check.find("addPendingSave(subscriptionListSettingsRecordID())", list_persist)
require(list_persist > settings_persist and -1 not in (list_baseline, list_queue)
        and list_persist < list_baseline < list_queue,
        "List/menu intent must commit before its baseline/date and CK pending key.")

scroll_change = method_body(LOCAL, "@objc nonisolated func listScrollPositionsDidChange")
scroll_persist = scroll_change.find("persistPendingSingletonUploadIntent")
scroll_clock = scroll_change.find("setScrollPositionsLocalModifiedDate")
require(-1 not in (scroll_persist, scroll_clock) and scroll_persist < scroll_clock,
        "Scroll intent must commit immediately before its clock, not after the debounce.")
scroll_queue = method_body(LOCAL, "func queueListScrollPositionsRecord")
require("queuePendingSingletonUploadWithoutReplacingIntent" in scroll_queue,
        "The scroll debounce must queue the already-durable revision without replacing it.")

did_fetch = method_body(ENGINE, "func handleEventOnMain")
initial_settings_log = did_fetch.find("Initiale Einstellungen werden hochgeladen")
initial_settings_prefix = did_fetch[max(0, initial_settings_log - 1400):initial_settings_log]
require("persistPendingSingletonUploadIntent" in initial_settings_prefix,
        "Empty-cloud settings seeding must persist an intent before clearing its fetch gate.")
publish_local = method_body(REMOTE, "@objc func resolveInitialSettingsPublishingLocal")
require(publish_local.find("persistPendingSingletonUploadIntent")
        < publish_local.find("initialSettingsBackfillPendingKey")
        < publish_local.find("addPendingSave"),
        "Publishing local settings must survive a kill between the choice and CK serialization.")

snapshot = method_body(ENGINE, "nonisolated static func syncEngineCallbackSnapshot")
require("pendingSingletonUploadIntents" in snapshot,
        "Record materialization must use the durable intent's revision and modifiedAt.")
for signature in [
    "nonisolated static func appSettingsRecordForSyncEngineCallback",
    "nonisolated static func listScrollPositionsRecordForSyncEngineCallback",
    "nonisolated static func subscriptionListSettingsRecordForSyncEngineCallback",
]:
    builder = method_body(ENGINE, signature)
    require("localMutationRevisionPayloadKey" in builder and "modifiedAt" in builder,
            f"{signature} does not stamp the durable revision inside the encrypted payload.")

sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
ack = method_body(REMOTE, "func acknowledgePendingSingletonUpload")
require("acknowledgePendingSingletonUpload" in sent,
        "Saved singleton records must resolve their durable intent.")
for token in ["accountRecordName", "localMutationRevisionPayloadKey"]:
    require(token in ack, f"Singleton ACK validation is missing exact {token} matching.")
require("modifiedAt" in ack,
        "ACK diagnostics must retain the LWW timestamp even though CloudKit may normalize Date precision.")
require("queuePendingSingletonUploadWithoutReplacingIntent" in ack
        and "requiresImmediateSingletonRecordResend" in ack,
        "A stale singleton ACK must immediately requeue the current intent after the callback.")
send_loop = method_body(MANAGER, "func sendChangesAndApplyCallbackOutcomes")
require("requiresImmediateSingletonRecordResend" in send_loop and "continue" in send_loop,
        "The outer send loop must drain a singleton requeued from a stale ACK.")

batch_struct = MANAGER[MANAGER.find("struct InitialUploadBatch"):]
batch_struct = batch_struct[:batch_struct.find("\n    }")]
require("auxiliaryRecordNames" in batch_struct,
        "Initial list/scroll singleton records must participate in the ACK checkpoint.")
record_batches = method_body(MANAGER, "func recordInitialUploadBatchesQueued")
resolve_batches = method_body(MANAGER, "func recordInitialUploadRecordNamesResolved")
advance_batches = method_body(MANAGER, "func advanceConfirmedInitialUploadBatches")
require("auxiliaryRecordNames" in record_batches
        and "auxiliaryRecordNames.subtract(resolvedNames)" in resolve_batches
        and "batch.auxiliaryRecordNames.isEmpty" in advance_batches,
        "An empty library must not mark its backfill complete before auxiliary singleton ACKs.")
progress = method_body(MANAGER, "func acknowledgedInitialUploadCount")
require("auxiliaryRecordNames" not in progress,
        "Auxiliary ACK gating must not inflate the logical episode/subscription progress count.")

scroll_change = method_body(LOCAL, "@objc nonisolated func listScrollPositionsDidChange")
require("episodesSyncHasParticipatedKey" in scroll_change
        and "episodesSyncEnabled" not in scroll_change.split("persistPendingSingletonUploadIntent", 1)[0],
        "Scroll changes after participation must retain their real timestamp even while Episode sync is OFF.")
defaults_change = method_body(LOCAL, "@objc nonisolated func defaultsDidChange")
require("subscriptionsSyncHasParticipatedKey" in defaults_change,
        "List/menu UserDefaults changes must still be fingerprinted while Subscription sync is OFF.")
journal = method_body(LOCAL, "func journalLocalOutboxObjects")
require("capturesSubscriptions" in journal
        and "deletedEpisodeList" in journal
        and "localOutboxSubscriptionListSettingsCategory" in journal
        and "persistPendingSingletonUploadIntent" not in journal,
        "Inserted, updated and deleted episode lists must enter the transaction-local outbox, not an external pre-commit intent.")
list_capture = journal[journal.find("deletedEpisodeList"):]
require("LocalOutboxMutation" in list_capture
        and "subscriptionListSettingsDirtyMarkerPayload" in list_capture
        and "subscriptionListSettingsPayload(in: context)" not in list_capture
        and "addPendingSave(subscriptionListSettingsRecordID())" not in list_capture,
        "Offline list edits must atomically journal a lightweight marker and wait for coreDataDidSave before CK queueing.")
expand_list = method_body(LOCAL, "func expandCommittedSubscriptionListSettingsOutboxEntry")
replace_marker = method_body(LOCAL, "nonisolated static func replaceSubscriptionListSettingsDirtyMarker")
require("committedSubscriptionListSettingsPayload" in expand_list
        and "expectedRevision" in replace_marker
        and "context.save()" in replace_marker,
        "The full list graph must be expanded from committed state off-main and replace only the exact marker revision.")

initial_plan = method_body(MANAGER, "func applyInitialUploadPlan")
subscription_aux = initial_plan[initial_plan.find("subscriptionBackfillOffset != nil"):]
subscription_aux = subscription_aux[:subscription_aux.find("applyInitialSubscriptionQueue")]
require("pendingSingletonUploadIntent" in subscription_aux
        and "modifiedAt: plan.createdAt" not in subscription_aux,
        "Re-enable without a local list edit must not invent a fresh timestamp before the catch-up fetch.")


def lww(local_edit_at, remote_edit_at):
    if local_edit_at is None:
        return "remote"
    return "local" if local_edit_at > remote_edit_at else "remote"


require(lww(None, 200) == "remote",
        "A re-enabled device with no local edit must adopt the newer cloud list/scroll state.")
require(lww(300, 200) == "local",
        "A later offline local list/scroll edit must remain durable and win by its real timestamp.")

list_remote_apply = method_body(REMOTE, "func applyRemoteSubscriptionListSettings")
require("queueSubscriptionListSettingsRepair" in list_remote_apply
        and "addPendingSave(subscriptionListSettingsRecordID())" not in list_remote_apply,
        "Every local list-state defense/repair must create a durable revision before it is queued.")
list_repair = method_body(REMOTE, "func queueSubscriptionListSettingsRepair")
require(list_repair.find("persistPendingSingletonUploadIntent")
        < list_repair.find("subscriptionListSettingsLocalModifiedDateKey")
        < list_repair.find("addPendingSave(subscriptionListSettingsRecordID())"),
        "A list repair must commit its intent and clock before the CK pending key.")
discard = method_body(MANAGER, "func discardPendingSingletonUploadIntent")
require("writePendingSingletonUploadIntents" in discard
        and "removePendingRecordChanges" in discard,
        "Adopting a newer remote singleton must durably discard the superseded local revision and CK save.")
scroll_remote_apply = method_body(REMOTE, "func applyRemoteListScrollPositions")
require("discardPendingSingletonUploadIntent" in list_remote_apply
        and "discardPendingSingletonUploadIntent" in scroll_remote_apply,
        "When remote LWW wins, the old durable list/scroll intent must not overwrite it later.")


def acknowledge(intent, ack_account, ack_revision, ack_modified_at):
    exact = (intent["account"] == ack_account
             and intent["revision"] == ack_revision)
    return "clear" if exact else "requeue"


intent = {"account": "A", "revision": "r2", "modifiedAt": 200}
require(acknowledge(intent, "A", "r2", 200) == "clear",
        "Only the exact current singleton version may clear its intent.")
require(acknowledge(intent, "A", "r2", 199.999) == "clear",
        "CloudKit Date normalization must not cause an exact revision to resend forever.")
require(acknowledge(intent, "A", "r1", 100) == "requeue",
        "An older in-flight ACK must requeue the newer local mutation.")
require(acknowledge(intent, "B", "r2", 200) == "requeue",
        "Another account must never clear or send this account's intent.")

print("iCloud singleton intent regression checks passed")
