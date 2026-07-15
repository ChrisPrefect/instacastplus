#!/usr/bin/env python3
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
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


model = ET.parse(MODEL).getroot()
entity = model.find("./entity[@name='ICCloudPendingEpisodeState']")
require(entity is not None,
        "Model6 must store pending remote episode states as indexed Core Data rows.")
attributes = {attribute.attrib["name"]: attribute.attrib for attribute in entity.findall("attribute")}
require(attributes.get("accountRecordName", {}).get("indexed") == "YES",
        "Pending states must be isolated and indexed by iCloud account.")
require(attributes.get("recordName", {}).get("indexed") == "YES",
        "Pending states need an indexed CloudKit record identity.")
require(attributes.get("payloadData", {}).get("attributeType") == "Binary",
        "Each pending state must persist its payload independently.")
constraints = [[constraint.attrib.get("value") for constraint in group.findall("constraint")]
               for group in entity.findall("./uniquenessConstraints/uniquenessConstraint")]
require(["accountRecordName", "recordName"] in constraints,
        "One account/record pair must own exactly one latest pending payload.")

require("ICCloudPendingEpisodeStateSnapshot" in TYPES,
        "Pending rows need immutable Sendable snapshots across Core Data queues.")
require('pendingEpisodeStateEntityName = "ICCloudPendingEpisodeState"' in MANAGER,
        "The manager must name the indexed pending-state entity explicitly.")

fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
stage_call = fetched.find("stagePendingEpisodeStates")
apply_call = fetched.find("processFetchedModificationBatch")
commit_call = fetched.find("applyPendingEpisodeStateBatchInBackground", stage_call)
require(-1 not in (stage_call, commit_call) and stage_call < commit_call,
        "Each remote chunk must durably stage episode payloads before its background transaction.")

modification_batch = method_body(REMOTE, "func applyPendingEpisodeStateBatchInBackground")
require("mergePendingEpisodeStates" not in modification_batch
        and "pendingPayloads" not in modification_batch
        and "context.delete(pending)" in modification_batch
        and modification_batch.find("context.delete(pending)") < modification_batch.find("context.save()"),
        "Remote episode chunks must not merge/rewrite the growing pending-payload plist.")

pending_replay = method_body(REMOTE, "func applyPendingEpisodeStates")
require("pendingEpisodeStateBatch" in pending_replay
        and "pendingPayloads" not in pending_replay
        and "pendingEpisodeStatesKey" not in pending_replay,
        "Pending episode replay must page indexed rows rather than load the complete plist.")
require("await Task.yield()" in pending_replay,
        "Pending episode replay must yield between bounded batches.")

for signature in [
    "nonisolated static func stagePendingEpisodeStates",
    "nonisolated static func pendingEpisodeStateBatch",
    "nonisolated static func removePendingEpisodeStates",
    "nonisolated static func deleteAllPendingEpisodeStates",
]:
    body = method_body(REMOTE, signature)
    require(("newBackgroundContext()" in body or "newICloudSyncBackgroundContext()" in body)
            and "context.perform" in body,
            f"{signature} must run Core Data I/O on a background context.")

stage = method_body(REMOTE, "nonisolated static func stagePendingEpisodeStates")
require("remoteApplyBatchSize" in stage and "context.save()" in stage,
        "Pending upserts must commit in bounded <=100-row transactions.")
remove = method_body(REMOTE, "nonisolated static func removePendingEpisodeStates")
require("payloadData" in remove and "context.delete" in remove and "context.save()" in remove,
        "Cleanup must compare the staged payload revision and durably delete only matching rows.")

migration = method_body(REMOTE, "func migrateLegacyPendingEpisodeStatesIfNeeded")
require("pendingEpisodeStatesKey" in migration
        and "stagePendingEpisodeStates" in migration
        and "removeSyncMetadataValue" in migration,
        "Legacy pending-state plists must migrate idempotently before being removed.")
require(migration.find("stagePendingEpisodeStates") < migration.find("removeSyncMetadataValue"),
        "The legacy plist must remain until every indexed row is durable.")

reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require(reconcile.find("userRecordID()") < reconcile.find("migrateLegacyPendingEpisodeStatesIfNeeded")
        < reconcile.find("setICloudAccountIdentityVerified(true)"),
        "Legacy rows must bind only after CloudKit identifies the account and before callbacks reopen.")
require("deleteAllPendingEpisodeStates" in reconcile,
        "An account change must remove pending rows that belong to the previous account.")

reset = method_body(MANAGER, "func prepareForLocalAppResetWithCompletion")
delete_all = method_body(MANAGER, "func deleteAllICloudDataWithCompletion")
require("deleteAllPendingEpisodeStates" in reset and "deleteAllPendingEpisodeStates" in delete_all,
        "Local reset and iCloud-zone reset must both clean the indexed pending store.")

print("iCloud pending episode-state store regression checks passed")
