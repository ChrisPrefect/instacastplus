#!/usr/bin/env python3
"""Pins Watch download reattach filesystem work off MainActor.

Reattachment is actor-owned because it reconciles URLSession task identity and the
durable manifest. File existence checks are immutable utility work, though, and a
large manifest must not synchronously stat every episode on MainActor. Results from
an obsolete reattach snapshot must also be discarded after the actor-reentrant await.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require(
    "private struct WatchDownloadReconcileFileCandidate: Sendable" in SOURCE
    and "private struct WatchDownloadReconcileFileResolution: Sendable" in SOURCE,
    "Filesystem reconciliation must cross actors as immutable Sendable values.",
)

resolver = body("nonisolated static func resolveReconcileLocalFiles(")
require(
    "Task.isCancelled" in resolver
    and "fileManager.fileExists(atPath:" in resolver,
    "All reconcile path/file-existence checks must run in utility work off MainActor.",
)
require(
    "reconcileFileResolutionBatchSize" in SOURCE
    and "stride(" in resolver,
    "A large manifest must be resolved in bounded serial batches, not one task per episode.",
)

reattach = body("private func reattachDownloadTasks(")
reconcile = body("private func reconcileManifestWithDownloadTasks(")
require(
    "pendingReattachCompletions.append(completion)" in reattach
    and "Task.detached(priority: .utility)" in reconcile
    and "Self.resolveReconcileLocalFiles" in reconcile
    and "reattachResolutionTask = resolutionTask" in reconcile,
    "The actor-owned reconcile path must pass its generation across the off-main resolution await.",
)
await_index = reconcile.find("await resolutionTask.value")
generation_guard_index = reconcile.find("guard generation == reattachGeneration", await_index)
require(
    await_index != -1 and generation_guard_index > await_index,
    "A reattach snapshot superseded during filesystem resolution must not commit stale repairs.",
)
require(
    "WatchStorageManager.shared.resolvedLocalFileURL" not in reconcile
    and "FileManager.default.fileExists" not in reconcile,
    "The @MainActor reconcile method must not perform synchronous filesystem resolution.",
)
require(
    "item.selectionIdentifier == resolution.candidate.selectionIdentifier" in reconcile
    and "item.localFileURL == resolution.candidate.originalLocalFileURL" in reconcile,
    "A manifest generation changed during the await must not receive a prior selection/path result.",
)
require(
    reconcile.count("WatchManifestStore.shared.updateEpisodes(") == 1
    and "WatchManifestStore.shared.updateEpisode(hash:" not in reconcile,
    "Reconcile repairs must remain one durable manifest bulk commit.",
)


print("Watch download reconcile MainActor-I/O regression checks passed")
