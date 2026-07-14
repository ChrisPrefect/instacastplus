#!/usr/bin/env python3
"""Pins Watch transport bookkeeping out of the iCloud settings payload/hash."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
WATCH = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


transport_keys = [
    "ICAppleWatchManifestRevision",
    "ICAppleWatchPendingManifestRevision",
    "ICAppleWatchReceivedManifestAcknowledgementRevision",
]

# Prove the observed feedback path still exists in the source: applying cloud settings refreshes
# appearance, the Watch manager observes that refresh, and manifest transport advances local
# revisions in UserDefaults. These writes are legitimate, but they are not user settings.
adopt_settings = method_body(REMOTE, "func adoptSettingsPayload")
require("ICAppearanceManager.shared()?.updateAppearance()" in adopt_settings,
        "Remote settings apply no longer refreshes appearance; update this regression proof.")
require("ICAppearanceManagerDidUpdateAppearanceNotification" in WATCH,
        "Watch manager no longer observes appearance changes; update this regression proof.")
for key in transport_keys:
    require(key in WATCH, f"Watch transport key disappeared: {key}")

# Both the payload builder and syncedSettingsHash use shouldSyncSettingsKey..., whose final
# device-local exclusion is this set. If a transport revision is absent here, every appearance
# refresh changes the settings hash and queues settings_app + device again after the 0.8 s check.
excluded = method_body(ENGINE, "nonisolated static func nonSettingsUserDefaultsKeysForSyncEngineCallback")
for key in transport_keys:
    require(f'"{key}"' in excluded,
            f"Device-local Watch transport key is being synced as an app setting: {key}")

print("iCloud/Watch transport settings feedback-loop regression checks passed")
