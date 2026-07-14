#!/usr/bin/env python3
"""Pins one canonical phone-side Watch selection generation per episode hash."""

from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if SOURCE.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


visible = body("- (NSArray<AppleWatchEpisodeState*>*)_visibleEpisodeStatesFromAllStates:")
reserve = visible.find("[seenEpisodeHashes addObject:episodeHash]")
skip_removing = visible.find("if (state.removingFromWatch)")
require(reserve != -1 and skip_removing != -1 and reserve < skip_removing,
        "The newest generation must reserve its hash before a removing row is hidden; an older row may not resurrect it.")

state_for_hash = body("- (AppleWatchEpisodeState*)stateForEpisodeHash:")
require("return states.firstObject;" in state_for_hash and
        "if (!state.removingFromWatch)" not in state_for_hash and
        "watchLastEventRevision" in state_for_hash,
        "Hash lookup must return the deterministic newest generation even when that generation is removing.")

manifest = body("- (NSDictionary*)_manifestSnapshotInContext:")
manifest_reserve = manifest.find("[seenEpisodeHashes addObject:episodeHash]")
manifest_skip = manifest.find("if (removingFromWatch)")
require(manifest_reserve != -1 and manifest_skip != -1 and manifest_reserve < manifest_skip,
        "The background manifest snapshot must reserve a removing generation before filtering it out.")

start = body("- (void)start")
require("_repairDuplicateAppleWatchEpisodeStatesWithCompletion:" in start and
        "activateSession" not in start and
        "_scheduleWatchDeletionInboxProcessing" not in start,
        "Legacy duplicates must be repaired durably before WatchConnectivity activation or deletion-inbox replay.")
finish_start = body("- (void)_finishStartingAfterWatchStateRepair")
require("activateSession" in finish_start and "_scheduleWatchDeletionInboxProcessing" in finish_start,
        "Connectivity and inbox replay may start only in the successful post-repair continuation.")

repair = body("- (void)_repairDuplicateAppleWatchEpisodeStatesWithCompletion:")
require("newBackgroundContext" in repair and
        "deleteObject:" in repair and
        "save:&saveError" in repair and
        "mergeChangesFromRemoteContextSave" in repair,
        "Duplicate repair must run off-main, persist deletion, and merge exact deleted object IDs into the view context.")


@dataclass(frozen=True)
class State:
    added: int
    revision: int
    removing: bool
    uid: str


def canonical(states: list[State]) -> State:
    return sorted(states, key=lambda item: (-item.added, -item.revision, not item.removing, item.uid))[0]


new_removing = State(added=20, revision=2, removing=True, uid="new")
old_selected = State(added=10, revision=1, removing=False, uid="old")
require(canonical([old_selected, new_removing]) == new_removing,
        "A newer removal generation must beat an older selected duplicate.")
new_selected = State(added=20, revision=2, removing=False, uid="new")
old_removing = State(added=10, revision=1, removing=True, uid="old")
require(canonical([old_removing, new_selected]) == new_selected,
        "A genuinely newer re-add must beat an older removal generation.")
tie_selected = State(added=20, revision=2, removing=False, uid="a")
tie_removing = State(added=20, revision=2, removing=True, uid="z")
require(canonical([tie_selected, tie_removing]) == tie_removing,
        "For an exact generation tie, deletion must win so corruption cannot resurrect content.")

print("Watch phone-state uniqueness regression checks passed")
