#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
DB_HEADER = (ROOT / "Classes" / "Model" / "DatabaseManager.h").read_text()
DB_IMPL = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


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


require("saveReturningError" in DB_HEADER,
        "DatabaseManager needs a checked save API; void save cannot protect sync durability.")
save = method_body(DB_IMPL, "- (NSError*) saveReturningError")
require("return error" in save and "processPendingChanges" in save,
        "The checked save must return the real Core Data error and preserve normal successful processing.")
legacy_save = method_body(DB_IMPL, "- (void) save")
require("saveReturningError" in legacy_save,
        "Existing callers should delegate to the single checked save implementation.")

flush = method_body(REMOTE, "func flushRemoteApplyBatchBeforeYield")
require("-> Bool" in REMOTE[REMOTE.find("func flushRemoteApplyBatchBeforeYield"):REMOTE.find("{", REMOTE.find("func flushRemoteApplyBatchBeforeYield"))]
        and "saveReturningError" in flush,
        "Remote batch commit must expose and inspect Core Data save failure.")
require("handleLocalPersistenceFailure" in flush,
        "A failed local commit must enter a visible unresolved sync state.")

fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
require(fetched.count("performSynchronousRemoteApplyBatch {") >= 2,
        "Fetched modifications/deletions must stop before yielding or completing after a failed commit.")

# CKSyncEngine can advance its change token even though the local Core Data save fails.
# Stage every episode payload durably before applying it, then remove only those whose
# Core Data transaction succeeded. This makes an app kill/disk-full failure replayable.
require(fetched.find("stagePendingEpisodeStates") < fetched.find("processFetchedModificationBatch"),
        "Enabled episode records must be durably staged before their local Core Data apply.")
require(fetched.rfind("performSynchronousRemoteApplyBatch {", 0, fetched.find("processFetchedModificationBatch"))
        < fetched.find("removePendingEpisodeStates"),
        "Staged episode rows must only be removed after the matching local Core Data commit.")
modification_batch = method_body(REMOTE, "func processFetchedModificationBatch")
require("FetchedModificationBatchResult" in REMOTE
        and "prepareSyncItemMetadataContextBatch" in modification_batch
        and "upsertSyncItemMetadata" in modification_batch,
        "Episode clocks must be inserted into the exact Core Data transaction whose success controls pending-payload removal.")
require("finalizeFetchedEpisodeBatch" not in REMOTE,
        "A post-save metadata finalizer would recreate the kill window between episode data and its logical clock.")

pending_episodes = method_body(REMOTE, "func applyPendingEpisodeStates")
require("performSynchronousRemoteApplyBatch {" in pending_episodes,
        "Pending replay must retain its payload when Core Data cannot commit.")

for signature in ["func performLowPrioritySync() async", "func performManualSync() async throws"]:
    sync_path = method_body(MANAGER, signature)
    require("await applyPendingEpisodeStates()" in sync_path
            and "await applyPendingSubscriptions()" in sync_path,
            f"A later sync attempt must replay locally uncommitted payloads before network completion: {signature}")
    require(sync_path.find("hasUnresolvedSyncFailures = false")
            < sync_path.find("await applyPendingEpisodeStates()"),
            f"Replay save failures must not be cleared by the sync path after they occur: {signature}")

display_status = method_body(METADATA, "func displayStatus(for error:")
require("lokal gespeichert" in display_status or "auf diesem Gerät gespeichert" in display_status,
        "A local database failure needs actionable wording instead of a generic iCloud error.")

print("iCloud local save failure regression checks passed")
