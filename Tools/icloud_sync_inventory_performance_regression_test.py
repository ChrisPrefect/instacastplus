#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
SETTINGS = (ROOT / "Classes" / "ICiCloudSyncSettingsViewController.m").read_text()


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


tick = method_body(SETTINGS, "- (void)refreshCloudStateTick")
require("refreshCloudInventory" not in tick,
        "The 30-second relative-time UI timer must not re-download the entire CloudKit zone.")

completion = method_body(METADATA, "func markSyncCompleted")
require("refreshCloudInventory" not in completion,
        "Routine automatic sync completion must not re-download every record in the CloudKit zone.")
require("runRequestedCloudInventoryRefresh()" in completion,
        "A settings toggle may request one inventory refresh after its sync has really completed.")

toggle = method_body(SETTINGS, "- (void)toggleSyncOption:")
require("requestCloudInventoryRefreshAfterSync" in toggle,
        "A settings toggle must explicitly request its post-sync inventory refresh.")
require("refreshCloudInventory" not in toggle,
        "A settings toggle must not scan CloudKit before its asynchronous sync has completed.")

request_refresh = method_body(MANAGER, "@objc func requestCloudInventoryRefreshAfterSync")
require("requestedCloudInventoryRefreshReason" in request_refresh,
        "The explicit post-sync inventory request must be retained until completion.")

run_requested_refresh = method_body(MANAGER, "func runRequestedCloudInventoryRefresh")
require('refreshCloudInventory(reason: "settingsActionAfterSync")' in run_requested_refresh,
        "Only an explicit settings action may start its post-sync full inventory scan.")

manual_action = method_body(SETTINGS, "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")
require("requestCloudInventoryRefreshAfterSync" in manual_action
        and manual_action.find("requestCloudInventoryRefreshAfterSync") < manual_action.find("performManualSyncWithCompletion"),
        "Manual Sync must explicitly request exactly one inventory refresh before starting its sync cycle.")
require("refreshCloudInventory" not in manual_action,
        "Manual Sync must not start a second full inventory scan from its completion callback.")

inventory = method_body(MANAGER, "func refreshCloudInventory(reason:")
require("cloudInventoryPayloadScanCompletedKey" in inventory,
        "Inventory needs a durable one-time payload-inspection gate.")
require('configuration.desiredKeys = shouldInspectPayloads ? ["payload"] : []' in inventory,
        "Normal inventory refreshes must request system metadata only.")
require("transitionalSubscriptionInventoryRecords" in inventory,
        "One-time transitional tombstones must remain countable without later payload downloads.")

box = method_body(TYPES, "func record(_ record: CKRecord)")
require("record.recordChangeTag" in box and "transitionalSubscriptionRecordChangeTags" in box,
        "Metadata-only scans must exclude a known tombstone only while its exact change tag is unchanged.")

reset = method_body(MANAGER, "func resetAllLocalSyncMetadata")
require("cloudInventoryPayloadScanCompletedKey" in reset
        and "transitionalSubscriptionInventoryRecordsKey" in reset,
        "The one-time inventory scan cache must be account-bound.")

print("iCloud inventory performance regression checks passed")
