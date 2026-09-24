#!/usr/bin/env python3
import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read_plist(path):
    return plistlib.loads((ROOT / path).read_bytes())


def require(condition, message):
    if not condition:
        raise AssertionError(message)


DEFAULTS = read_plist("Resources/Defaults.plist")
IPAD_DEFAULTS = read_plist("Resources-iPad/Defaults.plist")
ENTITLEMENTS = read_plist("Instacast.entitlements")
IPAD_INFO = read_plist("Resources-iPad/Instacast HD-Info.plist")

SYNC_KEYS = [
    "ICiCloudSyncEpisodesEnabled",
    "ICiCloudSyncSubscriptionsEnabled",
    "ICiCloudSyncSettingsEnabled",
]

for key in SYNC_KEYS:
    require(DEFAULTS.get(key) is False, f"{key} must default off in Resources/Defaults.plist.")
    require(IPAD_DEFAULTS.get(key) is False, f"{key} must default off in Resources-iPad/Defaults.plist.")

require(
    ENTITLEMENTS.get("com.apple.developer.icloud-container-identifiers") == ["iCloud.com.iteconomy.instacastplus"]
    and ENTITLEMENTS.get("com.apple.developer.icloud-services") == ["CloudKit"],
    "The app entitlement must enable the InstacastPlus CloudKit container.",
)
require(
    "remote-notification" in IPAD_INFO.get("UIBackgroundModes", []),
    "The iPad target must handle CloudKit remote notifications in the background.",
)
print("iCloud defaults and entitlement contract checks passed")
