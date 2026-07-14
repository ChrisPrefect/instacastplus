#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = "\n".join(
    (ROOT / "Classes" / name).read_text()
    for name in [
        "ICiCloudSyncManager.swift",
        "ICiCloudSyncManager+EngineRecords.swift",
        "ICiCloudSyncManager+LocalChanges.swift",
        "ICiCloudSyncManager+RemoteApply.swift",
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


# Sequence under test:
# 1. Settings sync is enabled and the initial fetch gate is armed.
# 2. A local UserDefaults write arrives before/during the cloud-settings choice.
# 3. No ICAppSettings save may be queued or materialized until the fetch/choice resolves.
queue_check = method_body("func checkAndQueueSettingsChange")
settings_branch = queue_check.split("if settingsSyncEnabled", 1)[1].split("// hasLocalSubscriptionListSettings", 1)[0]
require(
    "initialSettingsBackfillPendingKey" in settings_branch
    and "hasPendingInitialSettingsChoice" in settings_branch,
    "Local settings changes must stay parked throughout the initial fetch and explicit cloud/local choice.",
)
require(
    settings_branch.find("initialSettingsBackfillPendingKey") < settings_branch.find("addPendingSave(appSettingsRecordID())"),
    "The initial settings gate must run before a local ICAppSettings save can be queued.",
)

# A stale ICAppSettings pending change from an earlier disabled/offline run must not bypass
# the observer gate when CKSyncEngine asks to materialize it after re-enabling sync.
snapshot = MANAGER[MANAGER.find("struct SyncEngineCallbackSnapshot"):MANAGER.find("func syncEngineCallbackSnapshot")]
snapshot_builder = method_body("func syncEngineCallbackSnapshot")
record_builder = method_body("nonisolated static func recordToSaveForSyncEngineCallback")
require(
    "initialSettingsBackfillPending" in snapshot
    and "initialSettingsChoicePending" in snapshot
    and "initialSettingsBackfillPendingKey" in snapshot_builder
    and "pendingInitialSettingsPayloadKey" in snapshot_builder,
    "The send callback snapshot must carry the initial settings fetch gate.",
)
require(
    "!snapshot.initialSettingsBackfillPending" in record_builder,
    "CKSyncEngine must not materialize even a stale ICAppSettings save before the initial fetch/choice resolves.",
)
require(
    "!snapshot.initialSettingsChoicePending" in record_builder,
    "A parked cloud-settings choice must independently block stale ICAppSettings materialization.",
)

# Only the completed no-cloud fetch or an explicit user choice may release the gate and queue.
event_handler = method_body("func handleEventOnMain")
did_fetch = event_handler.split("case .didFetchChanges:", 1)[1].split("case .didFetchRecordZoneChanges", 1)[0]
publish_choice = method_body("@objc func resolveInitialSettingsPublishingLocal")
require(
    "removeObject(forKey: Self.initialSettingsBackfillPendingKey)" in did_fetch
    and "addPendingSave(appSettingsRecordID())" in did_fetch,
    "A successful first fetch with no cloud settings must release the gate before publishing local settings.",
)
require(
    publish_choice.find("removeObject(forKey: Self.initialSettingsBackfillPendingKey)")
    < publish_choice.find("addPendingSave(appSettingsRecordID())"),
    "Choosing local settings must explicitly release the gate before publishing.",
)


print("iCloud settings enable gate regression checks passed")
