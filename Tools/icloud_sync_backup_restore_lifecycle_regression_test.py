#!/usr/bin/env python3
"""Pins backup-restored iCloud switches to the manager lifecycle."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


import_settings = body(IMPORTER, "+ (NSInteger)importSettingsFromBackup:")
bool_keys = import_settings.split("NSSet *boolKeys", 1)[1].split("];", 1)[0]
for xml_key in ("iCloudSyncEpisodes", "iCloudSyncSubscriptions", "iCloudSyncSettings"):
    require(
        f'@"{xml_key}"' not in bool_keys,
        f"{xml_key} must not be written through the generic NSUserDefaults boolean branch.",
    )

require(
    "restoreSyncOptionsWithEpisodes:" in import_settings
    and "subscriptions:" in import_settings
    and "settings:" in import_settings,
    "Backup import must hand all present iCloud switches to ICiCloudSyncManager as one lifecycle transition.",
)

restore = body(MANAGER, "func restoreSyncOptions(")
for helper in (
    "applyEpisodesSyncEnabled",
    "applySubscriptionsSyncEnabled",
    "applySettingsSyncEnabled",
):
    require(helper in restore, f"Backup restore must use the same {helper} transition as the settings UI.")
require(
    restore.count("syncOptionsChanged()") == 1,
    "A backup with several iCloud switches must schedule one consolidated sync transition.",
)

for setter, helper in (
    ("setEpisodesSyncEnabled", "applyEpisodesSyncEnabled"),
    ("setSubscriptionsSyncEnabled", "applySubscriptionsSyncEnabled"),
    ("setSettingsSyncEnabled", "applySettingsSyncEnabled"),
):
    setter_body = body(MANAGER, f"func {setter}")
    require(helper in setter_body, f"{setter} and backup restore must share {helper}.")


print("iCloud backup restore lifecycle regression checks passed")
