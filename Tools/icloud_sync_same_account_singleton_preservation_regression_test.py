#!/usr/bin/env python3
"""Pins same-account sign-out survival for singleton user-data records."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


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


transition = method_body(REMOTE, "func resetForICloudAccountTransition")
flush = transition.find("flushPendingSingletonChangesForSameAccountTransition()")
capture = transition.find("transferablePendingUserChanges()")
reset = transition.find("resetAllLocalSyncMetadata(")
require(-1 not in (flush, capture, reset) and flush < capture < reset,
        "Same-account rebuild must flush debounced singleton edits before capturing and resetting the old engine.")
require("preserveSameAccountUserDataState: true" in transition,
        "Same-account rebuild must preserve LWW clocks and baselines; account switches must keep the default false.")

scroll_change = method_body(LOCAL, "@objc nonisolated func listScrollPositionsDidChange")
cleared_scroll_debounce = scroll_change.find("scrollDebounceWorkItem = nil")
queued_scroll_record = scroll_change.find("queueListScrollPositionsRecord()")
require(-1 not in (cleared_scroll_debounce, queued_scroll_record)
        and cleared_scroll_debounce < queued_scroll_record,
        "A completed scroll debounce must clear its marker so a later no-edit sign-in does not republish it.")

transferable = method_body(REMOTE, "func transferablePendingUserChanges")
for token in [
    "RecordPrefix.appSettings",
    "RecordPrefix.listScrollPositions",
    "RecordPrefix.subscriptionListSettings",
]:
    require(token in transferable, f"Same-account pending singleton transfer is missing {token}.")
for gate in ["settingsSyncEnabled", "episodesSyncEnabled", "subscriptionsSyncEnabled"]:
    require(gate not in transferable,
            f"A paused same-account singleton must survive engine rebuilding: {gate}.")

reset_metadata = method_body(MANAGER, "func resetAllLocalSyncMetadata")
require("preserveSameAccountUserDataState" in MANAGER[MANAGER.find("func resetAllLocalSyncMetadata"):
                                                        MANAGER.find("func resetAllLocalSyncMetadata") + 220],
        "Metadata reset needs an explicit same-account preservation contract.")
preserved_keys = [
    "pendingInitialSettingsPayloadKey",
    "settingsLocalModifiedDateKey",
    "settingsSyncedHashKey",
    "scrollPositionsLocalModifiedDateKey",
    "subscriptionListSettingsLocalModifiedDateKey",
    "subscriptionListSettingsBaselineKey",
]
preserve_branch = reset_metadata.find("if !preserveSameAccountUserDataState")
require(preserve_branch != -1, "Singleton metadata may only be cleared outside a verified same-account rebuild.")
for key in preserved_keys:
    require(reset_metadata.find(key, preserve_branch) != -1,
            f"Same-account rebuild does not explicitly preserve {key}.")


def should_transfer(record_name: str, episodes: bool, subscriptions: bool, settings: bool) -> bool:
    if record_name.startswith(("episode_", "subscription_", "subscriptionTombstone_")):
        return True
    if record_name == "settings_app":
        return settings
    if record_name == "settings_listScrollPositions":
        return episodes
    if record_name == "settings_subscriptionList":
        return subscriptions
    return False


require(should_transfer("settings_app", False, False, True),
        "An offline settings edit must remain pending after same-account sign-in.")
require(should_transfer("settings_listScrollPositions", True, False, False),
        "An offline scroll edit must remain pending after same-account sign-in.")
require(should_transfer("settings_subscriptionList", False, True, False),
        "An offline list/menu edit must remain pending after same-account sign-in.")
require(not should_transfer("settings_app", False, False, False),
        "A disabled category must not be republished merely because the engine was rebuilt.")

# With no local edit, preserving both baseline and clock keeps the hash equal and allows a
# genuinely newer fetched record to win. Clearing either causes a fresh local timestamp.
local_hash = "unchanged"
stored_hash = "unchanged"
local_clock = 100
remote_clock = 200
require(local_hash == stored_hash and remote_clock > local_clock,
        "No-edit same-account sign-in must adopt newer remote state without a fresh local republish.")

print("iCloud same-account singleton preservation regression checks passed")
