#!/usr/bin/env python3
"""Pins iCloud settings updates to the sections whose data actually changed."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "Classes" / "ICiCloudSyncSettingsViewController.m").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
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


require(
    "selector:@selector(syncStateDidChange:) name:ICiCloudSyncStateDidChangeNotification" in SETTINGS
    and "selector:@selector(syncDevicesDidChange:) name:ICiCloudSyncDevicesDidChangeNotification" in SETTINGS,
    "State and device notifications must use separate UI update paths.",
)

state_change = body(SETTINGS, "- (void)syncStateDidChange:")
require(
    "reloadStatusAndStorageSections" in state_change
    and "cachedDevices" not in state_change
    and ".devices" not in state_change,
    "A progress/status notification must not parse the device-cache file.",
)

devices_change = body(SETTINGS, "- (void)syncDevicesDidChange:")
require(
    "cachedDevices = [ICiCloudSyncManager sharedManager].devices" in devices_change
    and "ICiCloudSyncSettingsSectionDevices" in devices_change,
    "A device notification must refresh the cached device list and its section.",
)

complete = body(METADATA, "func markSyncCompleted()")
require(
    "updateDeviceCache(with: payload)" in complete
    and "postDevicesChanged()" not in complete,
    "Completing one sync must publish exactly one device-list notification.",
)

print("iCloud settings UI notification regression checks passed")
