#!/usr/bin/env python3
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


require(
    'pendingDeviceControlIntentsKey = "ICiCloudSyncPendingDeviceControlIntents"' in MANAGER,
    "Every all-off device update needs a durable revisioned control-intent store.",
)
file_keys = method_body(MANAGER, "nonisolated static var fileBackedSyncMetadataKeys")
require(
    "pendingDeviceControlIntentsKey" in file_keys,
    "Device control intents must use the atomic file-backed metadata store.",
)

options = method_body(MANAGER, "@objc func syncOptionsChanged")
persist = options.find("persistFinalDeviceRecordUpdateIntent()")
signed_out = options.find("isICloudAccountSignedOut")
require(
    -1 not in (persist, signed_out) and persist < signed_out,
    "Every toggle must persist its device revision before offline/network early returns.",
)
persist_wrapper = method_body(MANAGER, "func persistFinalDeviceRecordUpdateIntent")
require(
    "persistPendingDeviceControlSaveIntent()" in persist_wrapper,
    "The compatibility entry point must capture a revisioned payload, not a boolean.",
)

start = method_body(MANAGER, "@objc func start")
startup_recovery = method_body(MANAGER, "func startPostInitializationRecoveryLifecycle")
require(
    "startPostInitializationRecoveryLifecycle()" in start
    and "anySyncEnabled || self.hasPendingDeviceControlIntents" in startup_recovery
    and "initializeSyncEngineIfNeeded()" in startup_recovery
    and "refreshAccountStatus()" in startup_recovery,
    "Cold start with all categories off must verify the account and resume the durable revision.",
)

reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require(
    reconcile.find("setICloudAccountIdentityVerified(true)")
    < reconcile.find("resumePendingDeviceControlIntentsForVerifiedAccount()"),
    "A pending device revision may resume only after CloudKit verifies the real account.",
)

control_sender = method_body(MANAGER, "func sendPendingDeviceControlIntents")
require(
    "sendFinalDeviceRecordUpdate()" in control_sender and "anySyncEnabled" not in control_sender,
    "The all-off sender must not depend on a user-data category being enabled.",
)
final_send = method_body(MANAGER, "func sendFinalDeviceRecordUpdate")
require(
    "setError(error)" in final_send
    and 'scheduleSyncRetryAfterFailure(error: error, reason: "finalDeviceRecord")' in final_send,
    "All-off device sends must surface and retry CloudKit failures.",
)
require(
    "clearPendingDeviceControlIntent" not in final_send,
    "sendChanges returning cannot acknowledge a durable device revision.",
)

device_record = method_body(ENGINE, "nonisolated static func deviceRecordForSyncEngineCallback")
require(
    "snapshot.pendingDeviceControlIntents" in device_record
    and "localMutationRevisionPayloadKey" in device_record,
    "The exact durable revision must travel in the ICDevice record.",
)
sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
require(
    "acknowledgePendingDeviceControlSave" in sent,
    "Only the exact saved ICDevice revision may complete the durable intent.",
)
acknowledge = method_body(MANAGER, "func acknowledgePendingDeviceControlSave")
require(
    "currentRevision == sentRevision" in acknowledge
    and "requiresImmediateFinalDeviceRecordResend = true" in acknowledge,
    "A stale save acknowledgement must retain and immediately requeue the newer revision.",
)

send_wrapper = method_body(MANAGER, "func sendChangesAndApplyCallbackOutcomes")
require(
    "requiresImmediateFinalDeviceRecordResend" in send_wrapper and "continue" in send_wrapper,
    "The outer send loop must send the requeued revision after its callback returns.",
)


def acknowledgement_transition(current_revision: str, sent_revision: str) -> tuple[bool, bool]:
    matches = current_revision == sent_revision
    return matches, not matches


# An old ON payload may be in flight when the last switch is turned off. Payload booleans
# can repeat across later edits, so only the captured mutation revision is a safe ACK key.
require(
    acknowledgement_transition("all-off-r2", "old-on-r1") == (False, True),
    "An old ON acknowledgement must retain and requeue the all-off revision.",
)
require(
    acknowledgement_transition("all-off-r2", "all-off-r2") == (True, False),
    "Only the exact all-off revision may complete the intent.",
)
require(
    acknowledgement_transition("same-options-r3", "same-options-r2") == (False, True),
    "Identical option values from an older mutation must not clear a newer revision.",
)

retry = method_body(MANAGER, "func scheduleSyncRetryAfterFailure(code:")
require(
    "anySyncEnabled || hasPendingDeviceControlIntents" in retry
    and "resumePendingDeviceControlIntentsForVerifiedAccount()" in retry,
    "Automatic retry must remain alive when every user-data category is off.",
)

legacy_migration = method_body(
    MANAGER, "func migrateLegacyFinalDeviceRecordUpdateIntentIfNeeded"
)
require(
    legacy_migration.find("persistPendingDeviceControlSaveIntent")
    < legacy_migration.find("clearPendingFinalDeviceRecordUpdateIntent"),
    "Released boolean intents may clear only after their revisioned replacement is durable.",
)

print("iCloud final device-intent regression checks passed")
