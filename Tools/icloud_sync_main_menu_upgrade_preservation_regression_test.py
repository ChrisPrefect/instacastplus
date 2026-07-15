#!/usr/bin/env python3
"""Pins lossless migration of explicit main-menu visibility choices."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAIN_VIEW = (ROOT / "Classes" / "MainViewController_4.m").read_text()
REMOTE_APPLY = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
LOCAL_CHANGES = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
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


view_did_load = method_body(MAIN_VIEW, "- (void)viewDidLoad")
apply_remote = method_body(REMOTE_APPLY, "func applyRemoteSubscriptionListSettings")
settings_check = method_body(LOCAL_CHANGES, "func checkAndQueueSettingsChange")

# [] has always been a valid user choice (all optional list links hidden). No local
# upgrade marker can prove whether an old [] was deliberate or came from the buggy
# pre-initialization callback, so an App Store migration must never rewrite it.
require(
    "MainMenuListUIDsEmptyRepairV1" not in view_did_load
    and "MainMenuListUIDsEmptyRepairPendingUploadV1" not in view_did_load
    and "migratedDefaults && existingUIDs && [existingUIDs count] == 0" not in view_did_load,
    "App startup must preserve an explicitly stored empty main menu.",
)
require(
    "MainMenuListUIDsEmptyRepairPendingUploadV1" not in settings_check,
    "A defaults-change check must not silently turn an explicit empty menu into defaults.",
)

# Missing and explicit empty are distinguishable locally. An ambiguous unversioned
# Cloud [] may defend product defaults or an existing nonempty menu, but a stored local
# [] must remain untouched until a versioned current-client choice says otherwise.
require(
    'defaults.object(forKey: "MainMenuListUIDs") != nil' in apply_remote
    and "hasStoredMainMenuListUIDs" in apply_remote
    and "currentMainMenuListUIDs" in apply_remote
    and "isAmbiguousLegacyEmptyMainMenu" in apply_remote,
    "Legacy Cloud-empty handling must explicitly distinguish missing from stored-empty local state.",
)
require(
    "!hasStoredMainMenuListUIDs || !currentMainMenuListUIDs.isEmpty" in apply_remote,
    "Only missing/default or nonempty local menus may reject an ambiguous legacy Cloud [].",
)
require(
    "MainMenuListUIDsEmptyRepairPendingUploadV1" not in apply_remote
    and "MainMenuListUIDsEmptyRepairV1" not in apply_remote,
    "Cloud merge must rely on the versioned payload and durable singleton intent, not a lossy one-shot repair marker.",
)


DEFAULT_UIDS = [
    "default.favorites",
    "default.unplayed",
    "default.started",
    "default.downloaded",
]


def merge_legacy_empty(has_stored_local, local_uids):
    current = local_uids if has_stored_local else DEFAULT_UIDS
    rejects_ambiguous_remote = (not has_stored_local) or bool(current)
    return current, rejects_ambiguous_remote


explicit_empty, rejected = merge_legacy_empty(True, [])
require(explicit_empty == [] and not rejected,
        "A deliberate stored [] must survive an App Store upgrade and legacy Cloud replay.")
missing_defaults, rejected = merge_legacy_empty(False, None)
require(missing_defaults == DEFAULT_UIDS and rejected,
        "A genuinely missing key must retain the four product defaults.")
custom_menu, rejected = merge_legacy_empty(True, ["custom.list"])
require(custom_menu == ["custom.list"] and rejected,
        "An ambiguous old Cloud [] must not erase a visible customized menu.")

print("iCloud main-menu upgrade-preservation regression checks passed")
