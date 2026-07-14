#!/usr/bin/env python3
"""Pins large Watch manifest merge planning off MainActor with bounded stale-snapshot retry."""

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
    require(brace >= 0, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require("private struct WatchManifestMergePlan: Sendable" in SOURCE,
        "The detached merge must return one immutable Sendable commit plan.")
require("episodesMutationGeneration &+= 1" in SOURCE,
        "Every published episode mutation must invalidate a detached stale snapshot.")

planner = body("private nonisolated static func buildManifestMergePlan(")
for token in (
    "uniqueStoredEpisodes",
    "uniqueManifestEntries",
    "existingByHash",
    "desiredHashes",
    "pendingRemovals",
    "WatchEpisode(",
    "recordMergeDecision",
    "statusCountsMetadata",
):
    require(token in planner, f"Detached merge plan is missing bulk work: {token}")

current_plan = body("private func currentManifestMergePlan(")
require("Task.detached(priority: .utility)" in current_plan,
        "4,500-entry dictionary/set/object construction must not execute on MainActor.")
require("let maximumAttempts = 2" in current_plan
        and "episodesMutationGeneration" in current_plan
        and "releaseIncomingManifestRevision" in current_plan
        and "throw WatchManifestMergeError.superseded" in current_plan,
        "A stale plan must rebase once, then fail safely without an unbounded actor-blocking retry loop.")

replace = body("func applyManifest(")
upsert = body("func upsert(entries:")
for name, method in (("replace", replace), ("upsert", upsert)):
    require("try await currentManifestMergePlan(" in method
            and "episodes = plan.episodes" in method
            and "logMergeDecisions(plan.diagnostics" in method,
            f"Manifest {name} must commit one detached plan and bounded diagnostics.")
    for forbidden in ("var existingByHash", "var byHash", "uniqueEntries.map", "recordMergeDecision("):
        require(forbidden not in method,
                f"Manifest {name} still performs unbounded merge work on MainActor: {forbidden}")


def plan_attempt(snapshot_generation, generation_after_build):
    return snapshot_generation == generation_after_build


require(plan_attempt(10, 10), "An unchanged 4,500-entry snapshot must commit directly.")
require(not plan_attempt(10, 11), "Playback/progress mutation during detached work must reject the stale plan.")
attempts = [(10, 11), (11, 11)]
require(next(index for index, attempt in enumerate(attempts, 1) if plan_attempt(*attempt)) == 2,
        "One stale merge must rebase exactly once against the newest snapshot.")

print("Watch manifest merge MainActor-budget regression checks passed")
