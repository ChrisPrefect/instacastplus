#!/usr/bin/env python3
"""Pins a bounded, account-scoped store for pending remote subscription payloads."""

from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
MODEL = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model6.xcdatamodel" / "contents"


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
    raise AssertionError(f"Unterminated body: {signature}")


# The old dictionary rewrites its complete history for every 100-row receive/apply batch:
# 100, 200, ... N rows serialized. The row model writes only the changed batch.
library_size = 5_000
batch_size = 100
whole_plist_rows_written = sum(range(batch_size, library_size + 1, batch_size))
row_store_rows_written = library_size
require(whole_plist_rows_written > row_store_rows_written * 20,
        "The performance model must expose the growing whole-plist rewrite cost.")


# Functional paging proof with the real record-name ordering: tombstones sort before
# active records. Keeping pair A unresolved must not prevent pair B from being returned
# by the next seed page, and the later active half of A must not replay A twice.
def pair_names(record_name):
    if record_name.startswith("subscriptionTombstone_"):
        suffix = record_name.removeprefix("subscriptionTombstone_")
    else:
        suffix = record_name.removeprefix("subscription_")
    return {f"subscriptionTombstone_{suffix}", f"subscription_{suffix}"}


def pending_page(rows, cursor, limit):
    seeds = sorted(name for name in rows if cursor is None or name > cursor)[:limit]
    if not seeds:
        return [], None
    seed_names = set(seeds)
    groups = {tuple(sorted(pair_names(seed))) for seed in seeds}
    eligible = []
    for group in groups:
        existing = [name for name in group if name in rows]
        if existing and min(existing) in seed_names:
            eligible.extend(existing)
    return sorted(eligible), seeds[-1]


pending_rows = {
    "subscriptionTombstone_a": b"delete-a",
    "subscription_a": b"active-a",
    "subscriptionTombstone_b": b"delete-b",
    "subscription_b": b"active-b",
}
first_page, first_cursor = pending_page(pending_rows, None, 1)
second_page, second_cursor = pending_page(pending_rows, first_cursor, 1)
require(first_page == ["subscriptionTombstone_a", "subscription_a"]
        and second_page == ["subscriptionTombstone_b", "subscription_b"],
        "An unresolved earlier pair must not starve later subscription pairs.")
third_page, _ = pending_page(pending_rows, second_cursor, 1)
require(third_page == [],
        "The later physical half must not replay an unresolved logical pair twice in one pass.")

# Exact-byte cleanup proof: if a callback stages a newer revision while local apply is
# suspended, cleanup of the older committed snapshot must leave the newer row intact.
exact_store = {("account", "subscription_a"): b"old"}
committed_snapshot = ("account", "subscription_a", b"old")
exact_store[("account", "subscription_a")] = b"new"
identity = committed_snapshot[:2]
if exact_store.get(identity) == committed_snapshot[2]:
    del exact_store[identity]
require(exact_store[identity] == b"new",
        "Conditional cleanup must preserve a newer payload staged during replay.")


model = ET.parse(MODEL).getroot()
entity = model.find("./entity[@name='ICCloudPendingSubscriptionState']")
require(entity is not None,
        "Model6 must store pending remote subscription payloads as independent Core Data rows.")
attributes = {attribute.attrib["name"]: attribute.attrib for attribute in entity.findall("attribute")}
require(attributes.get("accountRecordName", {}).get("indexed") == "YES",
        "Pending subscription rows must be isolated and indexed by iCloud account.")
require(attributes.get("recordName", {}).get("indexed") == "YES",
        "Pending subscription rows need an indexed CloudKit record identity.")
require(attributes.get("payloadData", {}).get("attributeType") == "Binary",
        "Each pending subscription payload must be stored independently.")
constraints = [[constraint.attrib.get("value") for constraint in group.findall("constraint")]
               for group in entity.findall("./uniquenessConstraints/uniquenessConstraint")]
require(["accountRecordName", "recordName"] in constraints,
        "One account/record pair must own exactly one latest pending subscription payload.")

require("ICCloudPendingSubscriptionStateWrite" in TYPES
        and "ICCloudPendingSubscriptionStateSnapshot" in TYPES,
        "Background staging and replay need immutable Sendable subscription snapshots.")
require('pendingSubscriptionStateEntityName = "ICCloudPendingSubscriptionState"' in MANAGER,
        "The manager must name the indexed pending-subscription entity explicitly.")


for signature in [
    "nonisolated static func stagePendingSubscriptionStates",
    "nonisolated static func pendingSubscriptionStateBatch",
    "nonisolated static func pendingSubscriptionStateCount",
    "nonisolated static func removePendingSubscriptionStates",
    "nonisolated static func deleteAllPendingSubscriptionStates",
]:
    body = method_body(REMOTE, signature)
    require("newICloudSyncBackgroundContext()" in body and "context.perform" in body,
            f"{signature} must keep Core Data I/O off the main actor.")

stage = method_body(REMOTE, "nonisolated static func stagePendingSubscriptionStates")
require("remoteApplyBatchSize" in stage and "context.save()" in stage,
        "Pending subscription upserts must commit in bounded <=100-row transactions.")
require("accountRecordName == %@ AND recordName IN %@" in stage,
        "Upserts must be account-scoped and update only the current batch identities.")

load = method_body(REMOTE, "nonisolated static func pendingSubscriptionStateBatch")
require("fetchLimit" in load and "remoteApplyBatchSize" in load,
        "Replay must load a bounded page rather than the complete pending store.")
require("subscriptionOutboxRecordNames(forCloudRecordName:" in load,
        "A bounded page must batch-fetch both physical halves of every logical subscription.")

remove = method_body(REMOTE, "nonisolated static func removePendingSubscriptionStates")
require("payloadData" in remove and "context.delete" in remove and "context.save()" in remove,
        "Cleanup must delete only the exact staged payload revisions after local commit.")


fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
delete_apply = fetched.find("processFetchedDeletionBatch")
modification_apply = fetched.find("processFetchedModificationBatch")
stage_calls = [index for index in range(len(fetched))
               if fetched.startswith("stagePendingSubscriptionStates", index)]
require(len(stage_calls) >= 2
        and stage_calls[0] < delete_apply
        and delete_apply < stage_calls[1] < modification_apply,
        "Each bounded deletion/modification chunk must be durable before its local apply can advance the CloudKit token.")

modification_batch = method_body(REMOTE, "func processFetchedModificationBatch")
require("pendingSubscriptionUpdates" not in modification_batch
        and "mergePendingSubscriptions" not in modification_batch,
        "Fetched chunks must not rebuild the growing pending-subscription dictionary on the main actor.")

pending_replay = method_body(REMOTE, "func applyPendingSubscriptions")
subscription_worker = method_body(
    REMOTE,
    "nonisolated static func applyPendingSubscriptionBatchInBackground",
)
subscription_consume = method_body(REMOTE, "func consumeSubscriptionApplyBatchResult")
require("pendingSubscriptionStateBatch" in pending_replay
        and "applyPendingSubscriptionBatchInBackground" in pending_replay
        and "removePendingSubscriptionSnapshots" in subscription_worker
        and "removePendingSubscriptionStates" in subscription_consume
        and "pendingPayloads" not in pending_replay
        and "pendingSubscriptionPayloadsKey" not in pending_replay,
        "Pending subscriptions must page indexed rows and conditionally remove only committed snapshots.")
require("await Task.yield()" in pending_replay,
        "Pending subscription replay must yield between bounded logical batches.")
list_settings_lookup = pending_replay.find("pendingSubscriptionState(")
list_settings_apply = pending_replay.find("applyRemoteSubscriptionListSettings")
require(list_settings_lookup > pending_replay.find("while true")
        and list_settings_apply > list_settings_lookup,
        "Subscription-list settings must be fetched and applied only after every feed page.")

incomplete_gate = method_body(REMOTE, "var hasIncompletePendingSubscriptionFetch")
require("pendingPayloads" not in incomplete_gate
        and "pendingSubscriptionPayloadsKey" not in incomplete_gate,
        "The send gate must not deserialize the complete pending-subscription plist.")
callback_snapshot = method_body(ENGINE, "nonisolated static func syncEngineCallbackSnapshot")
require("pendingSubscriptionPayloadsKey" not in callback_snapshot,
        "Every CKSyncEngine send callback must avoid a whole pending-subscription file read.")


migration = method_body(REMOTE, "func migrateLegacyPendingSubscriptionStatesIfNeeded")
require("pendingSubscriptionPayloadsKey" in migration
        and "stagePendingSubscriptionStates" in migration
        and "replaceExisting: false" in migration
        and "removeSyncMetadataValue" in migration,
        "Legacy pending-subscription plists must migrate idempotently without overwriting newer rows.")
require(migration.find("stagePendingSubscriptionStates")
        < migration.find("removeSyncMetadataValue"),
        "The legacy plist is the migration commit marker and must remain until every row is durable.")
require("cloudAccountGeneration" in migration and "accountUserRecordNameKey" in migration,
        "Legacy migration must revalidate the account before deleting its retry source.")

reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require(reconcile.find("userRecordID()")
        < reconcile.find("migrateLegacyPendingSubscriptionStatesIfNeeded")
        < reconcile.find("setICloudAccountIdentityVerified(true)"),
        "Legacy rows must bind after CloudKit identifies the account and before callbacks reopen.")
require("deleteAllPendingSubscriptionStates" in reconcile,
        "An account change must remove rows belonging to the previous account.")

reset = method_body(MANAGER, "func prepareForLocalAppResetWithCompletion")
delete_all = method_body(MANAGER, "func deleteAllICloudDataWithCompletion")
require("deleteAllPendingSubscriptionStates" in reset
        and "deleteAllPendingSubscriptionStates" in delete_all,
        "Local reset and iCloud-zone reset must both clean the indexed subscription store.")

print("iCloud pending subscription-state store regression checks passed")
