#!/usr/bin/env python3
"""Pins ownership rules for overlapping Watch download reattach callbacks.

URLSession.getAllTasks returns an asynchronous snapshot. When two callers overlap,
the older snapshot must not reconcile after the newer request, and a snapshot that
predates a locally started task must never reset that task to queued.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


reattach = method_body("private func reattachDownloadTasks(")
snapshot = method_body("private func handleReattachTasksSnapshot(")
require(
    "reattachGeneration" in SOURCE
    and "reattachGeneration &+= 1" in reattach
    and "pendingReattachCompletions.append(completion)" in reattach
    and "guard generation == reattachGeneration" in snapshot
    and "restartLatestReattach()" in snapshot,
    "Only the newest getAllTasks snapshot may reconcile the manifest; an older callback can "
    "otherwise reset a download started by the newer callback.",
)
stale_snapshot = snapshot.split("guard generation == reattachGeneration else", 1)[1].split("}", 1)[0]
require(
    "completion()" not in stale_snapshot,
    "A stale snapshot must not release a foreground/background completion that is now owned by "
    "the newest reattach generation.",
)

reconcile = method_body("private func reconcileManifestWithDownloadTasks(")
orphan_insert = reconcile.find("orphanedDownloadingHashes.insert")
require(orphan_insert != -1, "Missing orphaned-download reconciliation branch.")
resolution_await = reconcile.find("await resolutionTask.value")
orphan_branch = reconcile[resolution_await:orphan_insert]
require(
    "activeTasksByHash[episode.episodeHash] == nil" in orphan_branch
    or "activeTasksByHash[episodeHash] == nil" in orphan_branch,
    "Missing actor-owned task check after reconcile filesystem resolution.",
)
require(
    "!finishingDownloadHashes.contains(episodeHash)" in orphan_branch
    and "guard generation == reattachGeneration" in orphan_branch,
    "A getAllTasks snapshot taken before a local task start/completion must be revalidated after "
    "the actor-reentrant filesystem await before it can classify the newer task as an orphan.",
)

require(
    "activeTasksByHash[hash]" in reconcile
    and "!== task" in reconcile
    and "task.cancel()" in reconcile,
    "A stale reattach task must not replace a newer task already owned by the manager.",
)

print("Watch download reattach race regression checks passed")
