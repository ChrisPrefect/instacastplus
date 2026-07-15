#!/usr/bin/env python3
"""Pins main-menu initialization, versioning, and lossless Cloud migration."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


engine_records = (ROOT / "Classes/ICiCloudSyncManager+EngineRecords.swift").read_text()
remote_apply = (ROOT / "Classes/ICiCloudSyncManager+RemoteApply.swift").read_text()
local_changes = (ROOT / "Classes/ICiCloudSyncManager+LocalChanges.swift").read_text()
main_view = (ROOT / "Classes/MainViewController_4.m").read_text()

callback = method_body(
    engine_records,
    "nonisolated static func mainMenuListUIDsForSyncEngineCallback",
)
payload_builder = method_body(
    engine_records,
    "nonisolated static func subscriptionListSettingsPayloadForSyncEngineCallback",
)
fingerprint_builder = method_body(
    engine_records,
    "nonisolated static func subscriptionListSettingsFingerprint(\n        payload: [String: Any]",
)

# The original bug was here: a callback that ran before MainViewController initialized
# the key published []. Missing means product defaults; stored [] means the user hid all
# optional links and must be serialized verbatim.
stored_array_branch = re.search(
    r'if\s+let\s+(\w+)\s*=\s*UserDefaults\.standard\.array\(forKey:\s*"MainMenuListUIDs"\)'
    r'\s+as\?\s*\[String\]\s*\{\s*return\s+\1\s*\}',
    callback,
    re.DOTALL,
)
require(
    stored_array_branch is not None,
    "The sync callback must return a stored MainMenuListUIDs array verbatim, including [].",
)
require(
    "return defaultMainMenuListUIDs()" in callback[stored_array_branch.end():],
    "A missing MainMenuListUIDs key must publish product defaults, never [].",
)
require(
    "mainMenuListUIDsSchemaVersion = 1" in engine_records
    and '"mainMenuListUIDsSchemaVersion": mainMenuListUIDsSchemaVersion' in payload_builder
    and 'payload["mainMenuListUIDsSchemaVersion"]' in fingerprint_builder,
    "Current payloads and their fingerprints must version intentional empty menus.",
)

apply_remote_menu = method_body(remote_apply, "func applyRemoteMainMenuListUIDs")
require(
    'defaults.object(forKey: "MainMenuListUIDs")' in apply_remote_menu
    and "hasStoredUIDs" in apply_remote_menu,
    "Remote apply must distinguish a missing key from an explicitly stored empty array.",
)

apply_subscription_settings = method_body(
    remote_apply,
    "func applyRemoteSubscriptionListSettings",
)
for token in [
    "hasStoredMainMenuListUIDs",
    "currentMainMenuListUIDs",
    "isAmbiguousLegacyEmptyMainMenu",
    "shouldRepairAmbiguousLegacyMainMenu",
    "remoteMainMenuSchemaVersion",
    "queueSubscriptionListSettingsRepair",
    "remoteOutboxDecision",
]:
    require(token in apply_subscription_settings, f"Missing legacy-empty merge contract: {token}")
require(
    apply_subscription_settings.find("isAmbiguousLegacyEmptyMainMenu")
    < apply_subscription_settings.find("remoteOutboxDecision"),
    "Ambiguous old Cloud [] must be recognized before LWW can discard current local state.",
)
require(
    "!hasStoredMainMenuListUIDs || !currentMainMenuListUIDs.isEmpty" in apply_subscription_settings,
    "Only missing/default or nonempty local menus may reject an ambiguous legacy Cloud [].",
)
ambiguous_decision = apply_subscription_settings.find("shouldRepairAmbiguousLegacyMainMenu")
outbox_decision = apply_subscription_settings.find("remoteOutboxDecision")
require(
    "return queueSubscriptionListSettingsRepair" not in apply_subscription_settings[ambiguous_decision:outbox_decision]
    and "!shouldRepairAmbiguousLegacyMainMenu" in apply_subscription_settings[outbox_decision:]
    and "shouldRepairSortSettings || shouldRepairAmbiguousLegacyMainMenu" in apply_subscription_settings[outbox_decision:],
    "An ambiguous old menu field must be preserved and republished without discarding valid remote sort/list changes.",
)
require(
    "MainMenuListUIDsEmptyRepairV1" not in apply_subscription_settings
    and "MainMenuListUIDsEmptyRepairPendingUploadV1" not in apply_subscription_settings,
    "Cloud merge must use schema and durable outbox state, not a lossy repair epoch.",
)

view_did_load = method_body(main_view, "- (void)viewDidLoad")
require(
    'if (!existingUIDs)' in view_did_load
    and '@[@"default.favorites", @"default.unplayed", @"default.started", @"default.downloaded"]' in view_did_load,
    "First launch must still initialize the four product-default list links.",
)
require(
    "MainMenuListUIDsEmptyRepairV1" not in view_did_load
    and "MainMenuListUIDsEmptyRepairPendingUploadV1" not in view_did_load
    and "migratedDefaults && existingUIDs && [existingUIDs count] == 0" not in view_did_load,
    "App Store startup migration must preserve an explicit empty menu.",
)
settings_check = method_body(local_changes, "func checkAndQueueSettingsChange")
require(
    "MainMenuListUIDsEmptyRepairPendingUploadV1" not in settings_check,
    "Settings observation must not silently replace a deliberate [] with defaults.",
)


DEFAULT_UIDS = [
    "default.favorites",
    "default.unplayed",
    "default.started",
    "default.downloaded",
]


def apply_remote(has_stored_local, local_uids, incoming_uids, schema_version):
    current = local_uids if has_stored_local else DEFAULT_UIDS.copy()
    ambiguous_empty = incoming_uids == [] and schema_version < 1
    if ambiguous_empty and (not has_stored_local or current):
        return current, True
    return incoming_uids, False


visible, republishes = apply_remote(True, DEFAULT_UIDS.copy(), [], 0)
require(visible == DEFAULT_UIDS and republishes,
        "A stale old Cloud [] must not erase an existing visible default menu.")
custom, republishes = apply_remote(True, ["custom.list"], [], 0)
require(custom == ["custom.list"] and republishes,
        "A stale old Cloud [] must not erase a customized visible menu.")
missing, republishes = apply_remote(False, None, [], 0)
require(missing == DEFAULT_UIDS and republishes,
        "A genuinely missing key must retain and publish product defaults.")
deliberate_empty, republishes = apply_remote(True, [], [], 0)
require(deliberate_empty == [] and not republishes,
        "An explicit legacy local [] is indistinguishable from a deliberate choice and must survive.")
versioned_empty, republishes = apply_remote(True, DEFAULT_UIDS, [], 1)
require(versioned_empty == [] and not republishes,
        "A current versioned [] must intentionally hide all optional list links.")

print("iCloud main-menu initialization regression checks passed")
