#!/usr/bin/env python3
"""Regression proof for atomic iCloud journaling by local background writers."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CHANGES = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    opening = source.find("{", start)
    require(opening >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


# A sibling background-context save is merged into the view context as refreshed objects.
# It has no changed keys and does not cause a view-context save, so the existing observer
# cannot reconstruct or durably journal the original user mutation after that save.
observer = body(LOCAL_CHANGES, "@objc nonisolated func coreDataDidChange")
require(
    "NSRefreshedObjectsKey" not in observer,
    "The view-context observer must not guess background mutations from keyless refreshed objects.",
)

# The real producer must ask the common journal-aware writer to add the episode snapshot and
# conflict metadata to the SAME context before its one save. A later Task/second context leaves
# a kill window and is not an atomic fix.
import_phase = body(IMPORTER, "+ (NSInteger)_importEpisodeStatusForPodcastAtIndex:")
call = "journalBackgroundEpisodeChangesInContext:context"
require(call in import_phase, "Backup episode-status import does not journal its background changes.")
require(
    "context.mergePolicy = NSErrorMergePolicy" in import_phase,
    "A concurrent newer episode/outbox commit must fail the import transaction instead of being overwritten.",
)
require(
    import_phase.find(call) < import_phase.find("[context save:&saveError]"),
    "The outbox must be prepared before the background episode transaction is saved.",
)
require(
    "journalError" in import_phase and "[context rollback]" in import_phase,
    "A journaling failure must roll back the episode mutation instead of silently losing sync intent.",
)
require(
    "backgroundLocalEpisodeChangesDidCommit" in import_phase,
    "A committed background outbox transaction must wake the normal outbox drain.",
)

journal = body(
    LOCAL_CHANGES,
    "nonisolated static func journalBackgroundEpisodeChanges",
)
for token in [
    "context.updatedObjects",
    "changedValuesForCurrentEvent",
    "syncRelevantEpisodeKeys",
    "prepareSyncItemMetadataContextBatch",
    "upsertSyncItemMetadata",
    "ICCloudSyncOutboxEntry",
    '"played"',
    '"position"',
    '"starred"',
    "payloadData",
]:
    require(token in journal, f"Atomic background episode journal is missing: {token}")
require(
    "databaseManager.objectContext" not in journal
    and "newBackgroundContext" not in journal
    and "context.save" not in journal
    and "Task {" not in journal,
    "The writer must mutate only the supplied transaction; the caller owns its single save.",
)
commit = body(LOCAL_CHANGES, "@objc func backgroundLocalEpisodeChangesDidCommit")
require(
    "backgroundLocalOutboxChangesDidCommit" in commit,
    "The episode callback must delegate to the common background outbox callback.",
)
common_commit = body(LOCAL_CHANGES, "@objc func backgroundLocalOutboxChangesDidCommit")
require(
    "scheduleLocalOutboxDrain" in common_commit,
    "The common post-commit callback must coalesce into the normal durable outbox drain.",
)

print("iCloud background episode-writer regression checks passed")
