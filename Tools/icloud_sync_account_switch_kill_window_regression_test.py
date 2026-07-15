#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = "\n".join(
    (ROOT / "Classes" / name).read_text()
    for name in [
        "ICiCloudSyncManager.swift",
        "ICiCloudSyncManager+EngineRecords.swift",
        "ICiCloudSyncManager+RemoteApply.swift",
        "ICiCloudSyncManager+LocalChanges.swift",
        "ICiCloudSyncManager+Metadata.swift",
    ]
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = MANAGER.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = MANAGER.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require(
    "accountResetRequiredKey" in MANAGER,
    "An account switch needs a durable reset-required marker for process-kill recovery.",
)
file_backed_keys = method_body("nonisolated static var fileBackedSyncMetadataKeys")
require(
    "accountResetRequiredKey" in file_backed_keys,
    "The reset-required marker must use the atomic file-backed metadata store.",
)

begin_switch = method_body("func beginICloudAccountSwitch")
marker_write = begin_switch.find("persistICloudAccountResetRequired")
identity_removal = begin_switch.find("defaults.removeObject(forKey: Self.accountUserRecordNameKey)")
transition_reset = begin_switch.find("resetForICloudAccountTransition")
require(
    marker_write != -1
    and identity_removal != -1
    and transition_reset != -1
    and marker_write < transition_reset < identity_removal,
    "The durable marker must be committed before old-account producers are stopped; identity may clear only after bounded metadata cleanup.",
)
require(
    begin_switch.find("deleteSyncItemMetadata", transition_reset) < identity_removal
    and begin_switch.find("removeAllLegacySyncItemMetadataSources", transition_reset) < identity_removal,
    "A direct switch must durably remove old-account indexed rows and legacy sources before forgetting which account owned them.",
)

account_change = method_body("func handleAccountChange")
switch_branch = account_change.split("case .switchAccounts:", 1)[1].split("@unknown default:", 1)[0]
unknown_branch = account_change.split("@unknown default:", 1)[1]
require(
    "try await beginICloudAccountSwitch()" in switch_branch
    and "try await beginICloudAccountSwitch()" in unknown_branch,
    "Every direct/unknown CloudKit account transition must enter the durable switch transaction.",
)

start = method_body("@objc func start()")
startup_recovery = start.find("discardStaleICloudAccountEngineStateIfNeeded()")
startup_lifecycle = start.find("startPostInitializationRecoveryLifecycle()")
recovery_lifecycle = method_body("func startPostInitializationRecoveryLifecycle()")
require(
    startup_recovery != -1
    and startup_lifecycle != -1
    and startup_recovery < startup_lifecycle
    and "initializeSyncEngineIfNeeded()" in recovery_lifecycle,
    "Cold start must discard stale account engine metadata before an engine can be initialized.",
)

discard_stale_state = method_body("func discardStaleICloudAccountEngineStateIfNeeded")
require(
    "isICloudAccountResetRequired" in discard_stale_state
    and "engineStateKey" in discard_stale_state
    and "knownRecordsKey" in discard_stale_state,
    "Kill recovery must synchronously reject stale serialized engine metadata before startup.",
)
require(
    "deleteLocalOutbox" not in discard_stale_state
    and "localOutboxEntityName" not in discard_stale_state,
    "Account recovery must preserve durable local offline edits in the outbox.",
)

load_state = method_body("func loadStateSerialization")
require(
    "!isICloudAccountResetRequired" in load_state,
    "Old CKSyncEngine serialization must never load while account reset is pending.",
)

reconcile = method_body("func reconcileAvailableICloudAccount")
pending_reset_check = reconcile.find("isICloudAccountResetRequired")
reset = reconcile.find("resetForICloudAccountTransition")
bind_pending = reconcile.find("bindPendingAccountLocalOutboxEntries")
bind_unbound = reconcile.find("bindUnboundLocalOutboxEntries")
bind_metadata = reconcile.find("bindSyncItemMetadata")
migrate_metadata = reconcile.find("migrateLegacySyncItemMetadataIfNeeded")
delete_system_fields = reconcile.find("deleteKnownRecordSystemFields")
remove_legacy_system_fields = reconcile.find("removeAllLegacyKnownRecordSystemFieldFiles")
clear_marker = reconcile.find("clearICloudAccountResetRequired")
open_gate = reconcile.find("setICloudAccountIdentityVerified(true)")
require(
    pending_reset_check != -1
    and reset != -1
    and pending_reset_check < reset,
    "Reconciliation must force a reset even when the killed switch already removed the previous account ID.",
)
require(
    bind_pending != -1
    and bind_unbound != -1
    and bind_metadata != -1
    and migrate_metadata != -1
    and clear_marker != -1
    and open_gate != -1
    and reset < bind_pending < clear_marker < open_gate
    and reset < bind_unbound < clear_marker < open_gate,
    "The marker may clear only after reset, outbox/metadata binding, and legacy migration, before the verified callback gate opens.",
)
require(
    bind_metadata < clear_marker and migrate_metadata < clear_marker,
    "Indexed item metadata must be account-bound and migrated before kill-recovery clears its durable marker.",
)
require(
    -1 < delete_system_fields < clear_marker
    and -1 < remove_legacy_system_fields < clear_marker,
    "Kill recovery must durably delete old-account indexed/legacy CloudKit system fields before clearing its marker.",
)

clear_reset = method_body("func clearICloudAccountResetRequired")
require(
    "removeSyncMetadataValue" in clear_reset
    and "accountResetRequiredKey" in clear_reset,
    "Completing a verified rebind must durably remove the reset marker.",
)


print("iCloud account-switch kill-window regression checks passed")
