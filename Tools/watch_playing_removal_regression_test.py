#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
STORAGE = (ROOT / "InstacastWatch" / "WatchStorageManager.swift").read_text()
EPISODE = (ROOT / "InstacastWatch" / "WatchEpisode.swift").read_text()
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()
CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
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
    raise AssertionError(f"Unterminated function: {signature}")


remove = function_body(DOWNLOAD, "func removeEpisode(hash:")
require("markEpisodesForRemoval" in remove and "enqueuePendingRemovalHashes" in remove,
        "Removing the playing episode must persist a deferred .removing state instead of dropping its cleanup metadata.")

apply_manifest = function_body(STORE, "func applyManifest(")
merge_plan = function_body(STORE, "private nonisolated static func buildManifestMergePlan(")
require("return plan.pendingRemovals" in apply_manifest and
        "pendingRemoval.status = .removing" in merge_plan and "pendingRemovals" in merge_plan,
        "A replace manifest must retain every removal until physical cleanup finishes.")

reuse = function_body(EPISODE, "private static func canReuseDownloadedFile(")
merge = function_body(EPISODE, "init(entry:")
require("existing.status == .removing" in reuse and "localFileWasValidated" in reuse and
        "FileManager" not in reuse and
        "existing?.status != .removing" in merge,
        "Re-adding an episode before playback ends must cancel its pending removal and reuse the intact file.")

finalize = function_body(DOWNLOAD, "func finalizePendingRemoval(hash:")
require("enqueuePendingRemovalHashes" in finalize,
        "Only persisted pending removals may enter the serialized cleanup queue.")
cleanup_batch = function_body(DOWNLOAD, "private func processPendingRemovalBatch()")
send_deletions = function_body(DOWNLOAD, "private func sendDeletionAcknowledgements(")
enqueue_cleanup = function_body(DOWNLOAD, "private func enqueuePendingRemovalHashes(")
store_remove_batch = function_body(STORE, "func removeEpisodes(hashes:")
require("removalCleanupBatchSize" in cleanup_batch and "Task.yield" in cleanup_batch and
        "removeEpisodes" in cleanup_batch and "status == .removing" in send_deletions and
        "sendDeletionAcknowledgements(for: completedHashes)" in cleanup_batch and
        "try await persistEpisodes" in store_remove_batch,
        "Large removal sets must yield between file batches and drop metadata with one atomic store commit.")
storage_removal = function_body(
    STORAGE,
    "nonisolated static func removeLocalFiles(\n"
    "        for episodes: [WatchEpisode],\n"
    "        downloadsDirectory: URL,",
)
storage_batch_removal = function_body(
    STORAGE,
    "private nonisolated static func removeLocalFilesOffMain(\n"
    "        for episodes: [WatchEpisode],\n"
    "        context: WatchStorageRemovalContext",
)
storage_cleanup_plan = function_body(STORAGE, "nonisolated static func makeCleanupPlan(")
storage_cleanup_execution = function_body(STORAGE, "nonisolated static func executeCleanup(")
storage_cleanup_commit = function_body(DOWNLOAD, "private func commitStorageEvictions(")
require("removeLocalFiles" in cleanup_batch and "context: removalContext" in cleanup_batch and
        '"watch.deleted"' in send_deletions and '"watch.deletedEpisodes"' in send_deletions and
        "delivery: .durable" in send_deletions and "episode.selectionIdentifier" in send_deletions and
        "async -> WatchStorageFileRemovalResult" in STORAGE.split(
            "nonisolated static func removeLocalFiles(\n"
            "        for episodes: [WatchEpisode],\n"
            "        downloadsDirectory: URL,",
            1,
        )[1].split("{", 1)[0] and
        "Task.detached(priority: .utility)" in storage_removal and
        "removeLocalFilesOffMain" in storage_removal,
        "Physical removal must delete the file and acknowledge deletion to the phone.")
require("context.artworkFilesByEpisodeHash" in storage_batch_removal and
        "context.downloadsDirectory" in storage_batch_removal and
        storage_batch_removal.count("contentsOfDirectory") == 0 and
        "localFileURL(for:" not in storage_batch_removal,
        "A removal batch must reuse one prepared filesystem context without rescanning or recreating directories per episode.")
removal_context = function_body(STORAGE, "nonisolated static func removalContext(")
removal_context_off_main = function_body(
    STORAGE,
    "private nonisolated static func removalContextOffMain(",
)
prepare_cleanup = function_body(DOWNLOAD, "private func preparePendingRemovalCleanup() async")
require("Task.detached(priority: .utility)" in removal_context and
        "removalContextOffMain(" in removal_context and
        removal_context_off_main.count("contentsOfDirectory") == 1,
        "The chapter-artwork directory must be indexed once away from MainActor.")
require("activeRemovalHashes" in prepare_cleanup and
        "pendingRemovalHashes.subtract" in prepare_cleanup and
        "removalContext(" in prepare_cleanup and
        "preparePendingRemovalCleanup" in enqueue_cleanup and
        "removalContext(" not in cleanup_batch and
        "removalContext" in cleanup_batch and
        "context: removalContext" in cleanup_batch and
        "removeLocalFiles(for: batchEpisodes)" not in cleanup_batch,
        "One frozen cleanup generation and filesystem context must be reused across every 25-item batch.")
require("$0.status != .removing" in storage_cleanup_plan,
        "Storage eviction must not rewrite a durable pending removal into an evicted orphan state.")
require("await removeLocalFiles(" in storage_cleanup_execution and
        "downloadsDirectory: plan.snapshot.downloadsDirectory" in storage_cleanup_execution and
        "chapterArtworkDirectory: plan.snapshot.chapterArtworkDirectory" in storage_cleanup_execution and
        "plan.selectedCandidates.map(\\.episode)" in storage_cleanup_execution and
        "removeLocalFile(for:" not in storage_cleanup_execution and
        "updateEpisodesDurablyInBatches" in storage_cleanup_commit and
        "updateEpisodesEventually" not in storage_cleanup_commit,
        "Storage eviction must share one artwork index and one manifest commit across the cleanup batch.")
send_signature = CONNECTIVITY.split("func send(type:", 1)[1].split("{", 1)[0]
activation = function_body(CONNECTIVITY, "activationDidCompleteWith")
send = function_body(CONNECTIVITY, "func send(type:")
require("-> Bool" in send_signature and "case .durable" in send and
        "transferUserInfo(message)" in send and "finalizePendingRemovalsAfterConnectivityActivation" in activation,
        "Removal metadata must survive until reliable WatchConnectivity delivery is available after activation.")

startup = function_body(DOWNLOAD, "private func startQueuedDownloadsAfterReattach()")
require("finalizePendingRemovals" in startup and "enqueuePendingRemovalHashes" in DOWNLOAD,
        "A Watch restart must finish removals whose playback process no longer exists.")

finish = function_body(PLAYER, "nonisolated func audioPlayerDidFinishPlaying(")
require("finalizePendingRemoval" in finish,
        "Natural playback completion must release and finalize a deferred removal.")

play = function_body(PLAYER, "func play(_ episode:")
require("finalizePendingRemoval" in play,
        "Switching to another episode must finalize removal of the released previous file.")

print("Watch playing-removal regression checks passed")
