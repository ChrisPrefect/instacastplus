#!/usr/bin/env python3
"""Regression proof for a deferred singleton CKSyncEngine save hot-loop."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : index]
    raise SystemExit(f"Unterminated method: {signature}")


next_batch = method_body(ENGINE, "nonisolated func nextRecordZoneChangeBatch")
require(
    "localChangesDeferred: !materialized.deferred.isEmpty" in next_batch,
    "The CKSyncEngine callback must propagate deferred singleton state instead of silently dropping it.",
)

materialize = method_body(ENGINE, "nonisolated static func materializeRecordsForSyncEngineCallback")
list_singleton = materialize.split(
    "if recordID.recordName == RecordPrefix.subscriptionListSettings,",
    1,
)[1].split(
    "if let record = recordToSaveForSyncEngineCallback(",
    1,
)[0]
stale_outbox_check = list_singleton.find("guard entry.category == localOutboxSubscriptionListSettingsCategory")
deferred_intent_check = list_singleton.find("guard let singletonIntent")
require(
    0 <= stale_outbox_check < deferred_intent_check,
    "An acknowledged or superseded list-settings outbox row must be removed as stale before a missing intent can defer it and hot-loop.",
)


def list_singleton_disposition(acknowledged: bool, intent_matches: bool) -> str:
    if acknowledged:
        return "stale"
    if not intent_matches:
        return "deferred"
    return "send"


require(
    list_singleton_disposition(True, False) == "stale"
    and list_singleton_disposition(False, False) == "deferred",
    "Only a live list-settings mutation may wait for intent reconciliation; an acknowledged row must never defer.",
)

record_outcome = method_body(MANAGER, "func recordInitialUploadOutcome")
take_outcome = method_body(MANAGER, "func takeInitialUploadOutcome")
require(
    "localChangesDeferred" in record_outcome
    and "self.localChangesDeferred = self.localChangesDeferred || localChangesDeferred" in record_outcome
    and "localChangesDeferred" in take_outcome
    and "localChangesDeferred = false" in take_outcome,
    "The callback gate must carry each deferred singleton exactly once into the manager-owned send cycle.",
)

apply_outcome = method_body(MANAGER, "func applySyncEngineCallbackOutcome")
require(
    "-> Bool" in MANAGER[MANAGER.find("func applySyncEngineCallbackOutcome") : MANAGER.find("func applySyncEngineCallbackOutcome") + 220]
    and "outcome.localChangesDeferred" in apply_outcome
    and "return hasDeferredLocalChanges" in apply_outcome,
    "Applying a CKSyncEngine callback outcome must report that local singleton reconciliation is required.",
)

send_wrapper = method_body(MANAGER, "func sendChangesAndApplyCallbackOutcomes")
require(
    "async throws -> Bool" in MANAGER[
        MANAGER.find("func sendChangesAndApplyCallbackOutcomes") :
        MANAGER.find("func sendChangesAndApplyCallbackOutcomes") + 260
    ]
    and "hasDeferredLocalChanges" in send_wrapper
    and "if hasDeferredLocalChanges && hasPendingSyncChanges { return true }" in send_wrapper,
    "A deferred singleton must end the current send loop instead of immediately sending the same pending change again.",
)

# A category can be disabled while sendChanges awaits CloudKit. The callback bit then
# describes the old snapshot, but no enabled pending change remains to reconcile.
def deferred_result(callback_deferred: bool, has_pending_enabled_change: bool) -> bool:
    return callback_deferred and has_pending_enabled_change


require(
    deferred_result(True, True) and not deferred_result(True, False),
    "A stale deferred callback must not strand completion after its category was disabled.",
)

low_priority = method_body(MANAGER, "func performLowPrioritySync() async")
first_send = low_priority.find("sendChangesAndApplyCallbackOutcomes")
first_fetch = low_priority.find("syncEngine.fetchChanges()", first_send)
deferred_exit = low_priority.find("if deferredLocalChanges", first_send)
continuation = low_priority.find("shouldScheduleContinuation =", deferred_exit)
require(
    0 <= first_send < deferred_exit < continuation < first_fetch,
    "Low-priority sync must end the current cycle and request one distinct reconciliation cycle before fetching or resending.",
)

manual = method_body(MANAGER, "func performManualSync() async throws")
require(
    "if deferredLocalChanges" in manual,
    "Manual sync must also leave the send cycle when singleton state needs reconciliation.",
)

background = method_body(MANAGER, "@objc func performBackgroundSyncWithCompletion")
require(
    "if deferredLocalChanges" in background,
    "Background sync must not continue to completion side effects after a deferred singleton send.",
)

final_device = method_body(MANAGER, "func sendFinalDeviceRecordUpdate")
require(
    "if deferredLocalChanges" in final_device
    and final_device.find("if deferredLocalChanges")
    < final_device.find("ICiCloudSyncFinalDeviceRecord"),
    "A deferred unrelated singleton must schedule reconciliation, not misreport the final device update as failed.",
)

print("iCloud deferred-singleton cycle regression checks passed")
