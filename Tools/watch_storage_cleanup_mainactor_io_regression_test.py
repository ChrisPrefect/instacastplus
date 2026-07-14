#!/usr/bin/env python3
"""Pins the serialized off-main Watch storage-eviction transaction.

Starting a download must never synchronously enumerate/stat/delete an unbounded
number of episode files on MainActor.  The filesystem result is only authoritative
after stable identities are revalidated and the bounded manifest mutation is durably
persisted; only then may the URLSession task start.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORAGE = (ROOT / "InstacastWatch" / "WatchStorageManager.swift").read_text()
DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
MANIFEST = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


require(
    "func cleanupIfNeeded(bytesNeeded:" not in STORAGE,
    "The synchronous @MainActor cleanupIfNeeded path performs unbounded file stats, artwork "
    "enumeration, and deletions while the user starts a download.",
)
require(
    "struct WatchStorageEpisodeIdentity: Hashable, Sendable" in STORAGE
    and "struct WatchStorageCleanupSnapshot: Sendable" in STORAGE
    and "struct WatchStorageCleanupPlan: Sendable" in STORAGE
    and "struct WatchStorageCleanupExecution: Sendable" in STORAGE,
    "Storage planning and execution must cross actors only as immutable Sendable values with a "
    "stable episode identity.",
)

plan = function_body(STORAGE, "nonisolated static func makeCleanupPlan(")
execute = function_body(STORAGE, "nonisolated static func executeCleanup(")
remove = function_body(
    STORAGE,
    "nonisolated static func removeLocalFiles(\n"
    "        for episodes: [WatchEpisode],\n"
    "        downloadsDirectory: URL,",
)
require(
    "Task.detached(priority: .utility)" in plan
    and "Task.detached(priority: .utility)" in remove
    and "await removeLocalFiles(" in execute,
    "Capacity measurement/candidate selection and artwork enumeration/file deletion must run "
    "with utility priority away from MainActor.",
)
require(
    "activeDownloadHashes" in plan
    and "episode.expectedBytes" in plan
    and "episode.downloadedBytes" in plan
    and "reservedDownloadBytes" in plan,
    "A second simultaneous start must reserve the first task's remaining bytes during the same "
    "off-main capacity plan instead of spending the same free space twice.",
)
progress = function_body(DOWNLOAD, "didWriteData bytesWritten:")
require(
    "totalBytesExpectedToWrite > currentExpectedBytes" in progress
    and "storagePreparationGeneration &+= 1" in progress,
    "If a parallel task discloses a larger size after the immutable snapshot, that real state "
    "change must invalidate the under-reserved plan before any new network task starts.",
)
for forbidden in ("WatchManifestStore.shared", "WatchPlayerController.shared"):
    require(
        forbidden not in plan and forbidden not in execute,
        "Detached storage work may consume only its immutable snapshot/plan, never actor-owned "
        "manifest or playback state.",
    )

start = function_body(DOWNLOAD, "func startDownload(for episode:")
prepare = function_body(DOWNLOAD, "private func preparePendingDownloadStart(")
commit = function_body(DOWNLOAD, "private func commitStorageEvictions(")
begin = function_body(DOWNLOAD, "private func beginPreparedDownload(")
require(
    "enqueuePendingDownloadStart" in start
    and "cleanupIfNeeded" not in start
    and "freeBytes()" not in start
    and "FileManager" not in start,
    "startDownload must be a bounded enqueue and must not touch the filesystem synchronously.",
)
require(
    "storagePreparationTask" in DOWNLOAD
    and "storageEvictionOwnedIdentities" in DOWNLOAD
    and "storagePreparationGeneration" in DOWNLOAD
    and "pendingDownloadStartHashes" in DOWNLOAD
    and "removalCleanupInProgress" in DOWNLOAD,
    "Two simultaneous starts, manifest changes, playback, and removal cleanup need one generation-"
    "checked storage worker with explicit pending/claimed ownership.",
)
require(
    "WatchStorageManager.makeCleanupPlan" in prepare
    and "revalidatedStorageCandidates" in prepare
    and "WatchStorageManager.executeCleanup" in prepare
    and prepare.count("revalidatedStorageCandidates") >= 2,
    "The selected episode identities/state must be revalidated before claiming/deleting and again "
    "before committing the physical result.",
)
require(
    "storageEvictionCommitBatchSize" in commit
    and "try await WatchManifestStore.shared.updateEpisodesDurablyInBatches" in commit
    and "updateEpisodesEventually" not in commit
    and commit.count("updateEpisodesDurablyInBatches") == 1,
    "Physical evictions must use bounded/indexed in-memory mutation followed by one durable "
    "manifest snapshot commit, never one full-manifest write per batch.",
)

execute_index = prepare.find("WatchStorageManager.executeCleanup")
commit_index = prepare.find("commitStorageEvictions")
begin_index = prepare.find("beginPreparedDownload")
require(
    -1 not in (execute_index, commit_index, begin_index)
    and execute_index < commit_index < begin_index,
    "A new URLSession download may begin only after off-main deletion and its durable manifest "
    "commit have completed.",
)
require(
    "pendingStorageEvictionCommits" in commit
    and "catch" in commit
    and "pendingStorageEvictionCommits" in commit[commit.find("catch"):]
    and "storageEvictionCommitBlocked = true" in commit[commit.find("catch"):]
    and "sendStorageEviction" not in commit[commit.find("catch"):],
    "If a bounded durable manifest save fails after partial physical deletion, every uncommitted "
    "identity must retain retry ownership and the new download must remain stopped.",
)
require(
    "repairPendingStorageEvictions" in prepare
    and prepare.find("repairPendingStorageEvictions") < prepare.find("WatchStorageManager.makeCleanupPlan")
    and "!storageEvictionCommitBlocked" in DOWNLOAD,
    "Every queued network start must first repair a prior physically-deleted-but-uncommitted set; "
    "a permanent save failure blocks automatic queue churn until a real new request/state turn.",
)
require(
    "session.downloadTask" in begin
    and "task.resume()" in begin
    and "session.downloadTask" not in prepare,
    "Only the final revalidated begin step may create and resume the URLSession task.",
)

cancel = function_body(DOWNLOAD, "func cancelEpisode(hash:")
require(
    "pendingDownloadStartHashes.remove(hash)" in cancel
    and "storagePreparationGeneration" in cancel,
    "Cancel during off-main preparation must invalidate the request so it cannot create a network "
    "task after returning to MainActor.",
)
enqueue = function_body(DOWNLOAD, "private func enqueuePendingDownloadStart(")
require(
    "pendingDownloadStartHashes.insert" in enqueue
    and "storagePreparationTask == nil" in DOWNLOAD
    and "!reattachInProgress" in DOWNLOAD,
    "Concurrent start wishes must be deduplicated and processed by exactly one serialized storage "
    "worker rather than running overlapping capacity/deletion transactions.",
)
mutation_blocker = function_body(DOWNLOAD, "private func beginStorageMutationBlocker(")
enqueue_removal = function_body(DOWNLOAD, "private func enqueuePendingRemovalHashes(")
finish_removal = function_body(DOWNLOAD, "private func finishPendingRemovalCleanup(")
require(
    "await storagePreparationTask.value" in mutation_blocker
    and "removalCleanupInProgress" in mutation_blocker
    and "pendingStorageMutationWaiters" in mutation_blocker
    and "storageMutationBlockers.isEmpty" in enqueue_removal
    and "storagePreparationTask == nil" in enqueue_removal
    and "pendingStorageMutationWaiters.removeAll()" in finish_removal,
    "Manifest/removal mutations must wait for the same serialized storage/removal owner; every "
    "waiter is drained once when physical removal releases it, without polling or a busy loop.",
)

update_many = function_body(MANIFEST, "func updateEpisodesDurablyInBatches(")
require(
    "ensureEpisodeIndex()" in update_many
    and "for hash in hashes" in update_many
    and "for index in nextEpisodes.indices" not in update_many,
    "A bounded eviction batch must update indexed hashes directly instead of scanning the entire "
    "manifest on MainActor for every durable batch.",
)
require(
    "await Task.yield()" in update_many
    and update_many.count("persistEpisodesNow(") == 1
    and "storageEvictionBatchMutationInProgress" in update_many
    and "episodeCollection.updateStructuralEpisodes(chunkUpdates)" in update_many
    and "chunkUpdates" in update_many
    and "var nextEpisodes = episodes" not in update_many,
    "Chunked MainActor mutation must yield between bounded chunks and persist exactly one final "
    "snapshot so large evictions do not multiply full-manifest writes.",
)
schedule_persist = function_body(MANIFEST, "private func schedulePersist()")
persist_episodes = function_body(MANIFEST, "private func persistEpisodes(")
require(
    "storageEvictionBatchMutationInProgress" in schedule_persist
    and "storageEvictionBatchMutationInProgress" in persist_episodes
    and "deferredStorageEvictionDurableWaiters" in persist_episodes,
    "Player position/scheduled and durable mutations interleaved at a batch yield must be merged "
    "into the one final snapshot, never persisted as a partial eviction state or overwritten.",
)
require(
    "deferredStorageEvictionDurableWaiters.removeAll()" in update_many
    and update_many.count("deferredDurableWaiters.forEach { $0.resume() }") == 1
    and update_many.count("deferredDurableWaiters.forEach { $0.resume(throwing: error) }") == 1,
    "Every durable mutation suspended at a chunk yield must be resumed exactly once with the same "
    "final commit success or persistence error; task cancellation must not abandon the commit.",
)

play = function_body(PLAYER, "func play(_ episode:")
require(
    "claimPlaybackBeforeStorageEviction(hash:" in play,
    "Playback must invalidate an unclaimed plan and win; once physical deletion owns the stable "
    "identity, it must not open that same file concurrently.",
)


print("Watch storage-cleanup MainActor/I-O regression checks passed")
