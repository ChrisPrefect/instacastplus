#!/usr/bin/env python3
"""Pins subscription conflict records behind complete-fetch pair resolution."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


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


apply_record = method_body(SOURCE, "func applyRemoteRecord(_ record:")

subscription_staging = apply_record.split(
    "} else if record.recordType == RecordKind.subscription", 1
)[1].split("let wasApplyingRemoteChange", 1)[0]
for record_kind in (
    "RecordKind.subscription",
    "RecordKind.subscriptionTombstone",
    "RecordKind.subscriptionListSettings",
):
    require(record_kind in subscription_staging,
            f"A serverRecordChanged {record_kind} must enter the durable row-store path.")
require("markPendingSubscriptionFetchIncomplete()" in subscription_staging and
        "stagePendingSubscriptionStates" in subscription_staging and
        subscription_staging.find("markPendingSubscriptionFetchIncomplete()")
        < subscription_staging.find("stagePendingSubscriptionStates"),
        "A conflict subscription row must close the complete-fetch gate before it is staged.")
require("payloadData: payloadData" in subscription_staging and
        "defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName" in subscription_staging,
        "A conflict subscription row must preserve its exact payload and verify the account after staging.")
for destructive_call in (
    "applyRemoteSubscription(payload",
    "applyRemoteSubscriptionTombstone(payload",
    "applyRemoteSubscriptionListSettings(payload",
):
    require(destructive_call not in apply_record,
            "A lone serverRecordChanged subscription record must remain parked until didFetchChanges resolves its pair.")
require("storePendingSubscription" not in SOURCE,
        "The removed full-plist pending-subscription path must not return.")

handler = method_body(SOURCE, "func handleFailedRecordSave(")
require("guard await applyRemoteRecord(serverRecord)" in handler,
        "CloudKit conflicts must enter the staged remote-record path before retry decisions.")
require("isSubscriptionConflictRecord" in handler and
        "retryRecords.append(.saveRecord(recordID))" in handler and
        "recordInitialUploadRecordsSaved([recordID])" in handler,
        "A staged subscription conflict must retain its local retry without stalling the initial backfill page.")

snapshot = method_body(ENGINE, "nonisolated static func syncEngineCallbackSnapshot()")
require("hasIncompletePendingSubscriptionFetch" in ENGINE and
        "pendingSubscriptionFetchCompleteKey" in snapshot,
        "The sync-engine callback snapshot must carry the durable incomplete-fetch gate.")
require("pendingSubscriptionPayloadsKey" not in snapshot,
        "The sync-engine callback must not read the retired full pending-payload plist.")
pending_change = method_body(ENGINE, "nonisolated static func pendingChangeIsEnabled(")
require("!snapshot.hasIncompletePendingSubscriptionFetch" in pending_change,
        "Neither half of a subscription intent may be resent while its remote pair is incomplete.")

pending = method_body(SOURCE, "func applyPendingSubscriptions() async")
require("guard pendingSubscriptionFetchIsComplete" in pending,
        "Staged conflict records must remain parked until a complete fetch is durable.")

low_priority = method_body(MANAGER, "func performLowPrioritySync() async")
require("hasIncompletePendingSubscriptionFetch" in low_priority and
        "!hasInitialUploadBackfillWork ||" in low_priority,
        "An incomplete subscription conflict must force fetchChanges even during initial upload backfill.")

print("iCloud subscription conflict fetch-gate regression checks passed")
