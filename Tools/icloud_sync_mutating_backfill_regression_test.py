#!/usr/bin/env python3
"""Pins initial iCloud upload paging to stable ACKed keyset cursors."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = MANAGER.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = MANAGER.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("initialEpisodeBackfillCursorKey" in MANAGER and
        "initialSubscriptionBackfillCursorKey" in MANAGER,
        "Initial backfill needs stable identifier cursors in addition to numeric progress counts.")

snapshot = body("func initialUploadSnapshot()")
require("initialBackfillState" in snapshot,
        "Legacy nonzero offsets without keyset cursors must restart idempotent backfill at zero.")
legacy = body("func initialBackfillState(")
require("offset > 0" in legacy and "cursor == nil" in legacy and "defaults.set(0" in legacy,
        "An in-progress legacy offset cannot be mapped safely and must restart instead of skipping records.")

episode_fetch = body("nonisolated static func episodeObjectHashesForInitialUploadPlan")
subscription_fetch = body("nonisolated static func subscribedFeedURLsForInitialUploadPlan")
for name, fetch, key in (
    ("episode", episode_fetch, "objectHash"),
    ("subscription", subscription_fetch, "sourceURL_"),
):
    require("fetchOffset" not in fetch,
            f"Mutable {name} backfill must never page by numeric row offset.")
    require(f'NSSortDescriptor(key: "{key}", ascending: true)' in fetch and
            f'{key} > %@' in fetch,
            f"{name.title()} backfill must use a deterministic ascending keyset predicate.")

saved = body("func recordInitialUploadRecordsSaved")
resolved = body("func recordInitialUploadRecordsResolved")
names_resolved = body("func recordInitialUploadRecordNamesResolved")
advance = body("func advanceConfirmedInitialUploadBatches")
require("recordInitialUploadRecordsResolved" in saved and
        "recordInitialUploadRecordNamesResolved" in resolved and
        "advanceConfirmedInitialUploadBatches" in names_resolved and
        "nextEpisodeBackfillCursor" in advance and "nextSubscriptionBackfillCursor" in advance,
        "Stable cursors may advance only through consecutively resolved CloudKit save checkpoints.")

# Functional proof of the original failure: after ACKing 200/450, deleting one early
# row makes numeric offset paging skip ID 200. Keyset paging still includes it.
rows = list(range(450))
first_page = rows[:200]
remaining = [value for value in rows if value != 50]
offset_uploaded = first_page + remaining[200:]
keyset_uploaded = first_page + [value for value in remaining if value > first_page[-1]]
require(200 not in offset_uploaded and 200 in keyset_uploaded,
        "Regression simulation must prove keyset paging survives deletion before the cursor.")

print("iCloud mutating-backfill regression checks passed")
