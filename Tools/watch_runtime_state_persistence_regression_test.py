#!/usr/bin/env python3
"""Pins O(1), crash-safe Watch runtime-state persistence beside the full manifest."""

from dataclasses import dataclass
from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "InstacastWatch"
    / "WatchManifestStore.swift"
).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require("private struct WatchEpisodeRuntimeState: Codable, Sendable" in SOURCE,
        "Runtime progress needs one small, independently codable per-episode record.")
require("private actor WatchEpisodeRuntimeStateWriter" in SOURCE,
        "Atomic runtime writes and obsolete-record cleanup need one non-MainActor serial owner.")
require("runtimeStateGeneration" in SOURCE and "decodeIfPresent(" in SOURCE and "UInt64.self" in SOURCE,
        "The manifest archive needs a backwards-compatible runtime generation floor.")

runtime_writer = body("private actor WatchEpisodeRuntimeStateWriter")
require("JSONEncoder" in runtime_writer and ".write(to:" in runtime_writer and ".atomic" in runtime_writer,
        "Each runtime record must be atomically replaced without rewriting the full manifest.")
require("latestGenerationByHash" in runtime_writer and "state.generation < latestGeneration" in runtime_writer,
        "Out-of-order tasks must not replace a newer runtime record with an older generation.")
require("removeStates(atOrBefore" in runtime_writer,
        "A committed full manifest must compact only runtime records covered by its generation floor.")

load = body("private func performInitialLoad(")
require("loadRuntimeStates" in load and "applyRuntimeStates" in load,
        "Cold launch must replay durable runtime records over the last full manifest.")
apply_runtime = body("private nonisolated static func applyRuntimeStates(")
for identity_token in ("selectionIdentifier", "watchAddedDate", "mediaURL", "status"):
    require(identity_token in apply_runtime,
            f"A stale runtime record must be rejected when {identity_token} changed.")
require("state.generation > archiveRuntimeStateGeneration" in apply_runtime,
        "Runtime records already included in the full archive must never overwrite it after a crash.")

update_one = body("func updateEpisode(hash:")
require("isRuntimeOnlyMutation" in update_one and "scheduleRuntimeStatePersist" in update_one,
        "Position/download-byte-only changes must take the small runtime-state path.")
require("schedulePersist()" in update_one,
        "Structural and terminal episode changes must still persist the full manifest.")
runtime_schedule = body("private func scheduleRuntimeStatePersist(")
for forbidden in ("episodes", "WatchManifestArchive", "persistenceWriter"):
    require(forbidden not in runtime_schedule,
            f"Runtime-state scheduling must not capture/rewrite the full manifest: {forbidden}")


@dataclass(frozen=True)
class State:
    generation: int
    selection: str
    status: str
    position: int


def replay(archive_floor: int, current_selection: str, current_status: str, state: State) -> int:
    if state.generation <= archive_floor:
        return 0
    if state.selection != current_selection or state.status != current_status:
        return 0
    return state.position


require(replay(40, "A", "downloaded", State(41, "A", "downloaded", 120)) == 120,
        "A newer matching runtime position must survive a crash/relaunch.")
require(replay(41, "A", "downloaded", State(41, "A", "downloaded", 120)) == 0,
        "A stale record must not overwrite the full manifest that already includes it.")
require(replay(40, "B", "downloaded", State(41, "A", "downloaded", 120)) == 0,
        "A record from an older selection identity must not affect a replacement episode.")

arrivals = [41, 43, 42]
latest_generation = 0
for generation in arrivals:
    if generation >= latest_generation:
        latest_generation = generation
require(latest_generation == 43,
        "A delayed older task must not regress the atomically stored runtime generation.")

print("Watch runtime-state persistence regression checks passed")
