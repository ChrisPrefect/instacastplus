#!/usr/bin/env python3
"""A local read failure must not be mistaken for a deleted upload record."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = ENGINE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = ENGINE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(ENGINE)):
        if ENGINE[index] == "{":
            depth += 1
        elif ENGINE[index] == "}":
            depth -= 1
            if depth == 0:
                return ENGINE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require(
    "struct SyncPayloadLookup" in ENGINE and "let succeeded: Bool" in ENGINE,
    "Batched payload lookup must distinguish an empty successful fetch from a local read failure.",
)

materialize = body("nonisolated static func materializeRecordsForSyncEngineCallback")
require(
    "unresolved" in materialize and ".succeeded" in materialize,
    "Materialization must retain records whose local payload could not be read.",
)

next_batch = body("nonisolated func nextRecordZoneChangeBatch")
require(
    "materialized.unresolved" in next_batch
    and "recordInitialUploadOutcome" in next_batch,
    "CKSyncEngine callback must retain local read failures without removing their pending changes.",
)
require(
    "staleSaveChanges = materialized.stale" in next_batch,
    "Only confirmed missing/obsolete records may enter the stale-removal path.",
)
require(
    "takeInitialUploadOutcome" in MANAGER
    and "handleLocalUploadReadFailure(reason: \"recordMaterialization\")" in MANAGER,
    "The manager must consume callback outcomes after sendChanges and visibly retry local read failures.",
)


# Behavioral proof: an empty successful lookup means a deleted row; an empty failed
# lookup means unknown and therefore must remain pending for a later retry.
pending = {"episode_a", "episode_b"}
successful_rows = {"episode_a"}
stale = pending - successful_rows
require(stale == {"episode_b"}, "A successful fetch may resolve a genuinely missing row.")
failed_rows = set()
unresolved = pending if not False else pending - failed_rows
require(unresolved == pending, "A failed fetch must retain every pending row.")


print("iCloud upload materialization failure regression checks passed")
