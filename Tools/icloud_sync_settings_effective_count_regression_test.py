#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


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
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


payload = method_body(ENGINE, "nonisolated static func appSettingsPayloadForSyncEngineCallback")
require(
    "syncableNonDefaultSettingsValuesForSyncEngineCallback" in payload
    and '"defaultKeys"' in payload,
    "The uploaded settings payload must contain only non-default values plus explicit reset keys.",
)

filter_values = method_body(
    ENGINE,
    "nonisolated static func syncableNonDefaultSettingsValuesForSyncEngineCallback",
)
require(
    "UserDefaults.registrationDomain" in filter_values
    and "isEqual" in filter_values,
    "Non-default filtering must compare persisted values with the app's registered defaults.",
)

count = method_body(MANAGER, "nonisolated static func syncedSettingsValueCount")
require(
    "syncableNonDefaultSettingsValuesForSyncEngineCallback" in count,
    "The local settings progress count must use the exact same non-default filter as the payload.",
)

inventory = method_body(MANAGER, "func refreshCloudInventory(reason:")
require(
    "appSettingsValueCountFromCloud" in inventory,
    "The cloud inventory must resolve the value count inside settings_app instead of counting its one record.",
)
cloud_count = method_body(MANAGER, "func appSettingsValueCountFromCloud")
require(
    "database.record(for: appSettingsRecordID())" in cloud_count
    and "syncableNonDefaultSettingsValuesForSyncEngineCallback" in cloud_count,
    "The effective cloud count must fetch only settings_app and count its non-default values.",
)

apply = method_body(REMOTE, "func adoptSettingsPayload")
require(
    'payload["defaultKeys"] as? [String]' in apply
    and "defaults.removeObject(forKey: key)" in apply,
    "A new payload must explicitly propagate resets to registered defaults without treating missing legacy keys as resets.",
)

print("iCloud effective settings count regression checks passed")
