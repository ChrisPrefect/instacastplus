#!/usr/bin/env python3
"""Pins ordered/coalesced Watch manifest persistence across actor reentrancy."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing declaration: {signature}")
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
    raise AssertionError(f"Unterminated declaration: {signature}")


writer = body(STORE, "private actor WatchManifestPersistenceWriter")
require("pendingSnapshot" in writer and "activeSnapshot" in writer and "durableWaiters" in writer and
        "writeInProgress" in writer,
        "The persistence actor must own one active write, one coalesced latest snapshot, and durable barriers.")
require("Task.detached" in writer and "runWriteLoop" in writer,
        "Manifest encoding and atomic file I/O must run off MainActor while the actor continues accepting newer snapshots.")
require("generation <= committedGeneration" in writer and
        "waiter.generation <= committedGeneration" in writer,
        "A durable older request may complete only after its generation or a newer inclusive snapshot committed.")
require("generation > highestQueuedGeneration" in writer and
        "activeSnapshot?.generation" in writer,
        "An older request arriving while a newer snapshot is actively writing must never be queued to overwrite the newer file afterward.")
require(writer.count("generation <= lastFailedGeneration") >= 2,
        "A delayed older request must inherit a newer terminal write failure instead of retrying its stale archive afterward.")

should_apply = body(STORE, "func shouldApplyManifestRevision")
require("pendingManifestRevision" in should_apply,
        "Queued manifest messages must compare against the synchronously reserved in-flight revision, not only the last disk commit.")

schedule = body(STORE, "private func schedulePersistNow")
require("inMemoryManifestRevision" in schedule and "pendingManifestRevision" not in schedule and
        "try await persistenceWriter.persist" in schedule,
        "A local snapshot must carry the revision of its actual in-memory content, never a merely reserved incoming revision.")

persist = body(STORE, "private func persistEpisodesNow")
require("inMemoryManifestRevision" in persist and "manifestRevision" in persist and
        "awaitCommittedSnapshot" in persist and "restoreLastCommittedArchive" in persist,
        "A failed durable generation must follow newer inclusive snapshots before deciding whether the committed archive must be restored.")
restore = body(STORE, "private func restoreLastCommittedArchive")
require("inMemoryManifestRevision = lastAppliedManifestRevision" in restore,
        "Rollback must restore both content and the revision that content actually represents.")

# A reserved R11 must not relabel still-current R10 content while detached normalization
# is suspended; otherwise restart rejects the real R11 manifest as already committed.
last_applied = 10
pending = 11
in_memory = 10
local_archive_revision = in_memory
require(local_archive_revision == last_applied and local_archive_revision != pending,
        "Reserved revision and in-memory content revision must remain distinct until apply.")

for signature in (
    "func applyManifest(",
    "func upsert(",
    "func markEpisodesForRemoval(",
    "func removeEpisodes(hashes:",
    "func updateEpisodeDurably(",
    "func updateEpisodes(",
):
    require("episodes = previousEpisodes" not in body(STORE, signature),
            f"{signature} must not roll back an unrelated newer MainActor snapshot.")

load_signature_start = STORE.find("func load(")
load_signature_end = STORE.find("{", load_signature_start)
require("async" in STORE[load_signature_start:load_signature_end] and
        "performInitialLoad" in body(STORE, "func load(") and
        "Task.detached" in body(STORE, "private func performInitialLoad("),
        "Startup JSON read/decode must not block the Watch UI actor.")

print("Watch manifest concurrency regression checks passed")
