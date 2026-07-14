#!/usr/bin/env python3
"""Pins cancellation/finish ordering for Watch background downloads."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()


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
    raise AssertionError(f"Unterminated body: {signature}")


start_download = function_body(DOWNLOAD, "func startDownload(for episode:")
current_download = function_body(DOWNLOAD, "private func isCurrentDownload(")
finished_download = function_body(DOWNLOAD, "private func processFinishedDownload(")
discard_download = function_body(DOWNLOAD, "private func discardFinishedDownload(")
remove_finished_files = function_body(DOWNLOAD, "private nonisolated static func removeFinishedDownloadFiles(")
reconcile = function_body(DOWNLOAD, "private func reconcileManifestWithDownloadTasks(")
completion = function_body(DOWNLOAD, "nonisolated func urlSession(_ session: URLSession, task:")
cancel = function_body(DOWNLOAD, "func cancelEpisode(hash:")
progress = function_body(
    DOWNLOAD,
    "nonisolated func urlSession(_ session: URLSession,\n"
    "                                downloadTask: URLSessionDownloadTask,\n"
    "                                didWriteData bytesWritten: Int64,",
)

require("finishingDownloadHashes" in DOWNLOAD and
        "!finishingDownloadHashes.contains(episode.episodeHash)" in start_download,
        "A re-add must not start a second download while an older completion is still validating files.")
require("activeTasksByHash[hash] === downloadTask" in current_download and
        "status == .downloading" in current_download,
        "Download callbacks must be authorized by task identity and the current manifest state.")
require(finished_download.count("isCurrentDownload(downloadTask, hash: hash)") >= 3 and
        "episodeIdentity.matches(currentEpisode)" in finished_download and
        "await Self.downloadedFileAttributes" in finished_download and
        "await WatchChapterExtractor.shared.extractChapters" in finished_download,
        "Completion must revalidate identity after each actor-reentrant await before committing files or metadata.")
require("chapterMetadata.chapters" in discard_download and
        "await Self.removeFinishedDownloadFiles" in discard_download and
        "Task.detached(priority: .utility)" in remove_finished_files and
        "removeItem" in remove_finished_files and
        "download-discard-failed" in discard_download,
        "A cancelled completion must remove its staged audio and any artwork created after the removal snapshot.")
require("episode.status == .downloading" in reconcile and
        "item.status = .downloading" not in reconcile and
        "item.status == .removing ? .removing : .queued" in reconcile,
        "Reattachment must cancel stale tasks instead of resurrecting a durable .removing state.")
require("activeTasksByHash[hash] === downloadTask" in completion and
        "finishingDownloadHashes.insert(hash)" in completion and
        "finishingDownloadHashes.remove(hash)" in completion,
        "A stale completion must neither clear a replacement task nor publish failure for it.")
finishing_guard = cancel.find("finishingDownloadHashes.contains(hash)")
clear_task = cancel.find("activeTasksByHash[hash] = nil")
queue_episode = cancel.find("item.status = .queued")
require(
    -1 not in (finishing_guard, clear_task, queue_episode)
    and finishing_guard < clear_task
    and finishing_guard < queue_episode,
    "Cancel must resolve before async finalization starts or leave that owned finalization intact; "
    "it must never rewrite a just-committed local file to .queued while the finisher is suspended.",
)
require("activeTasksByHash[hash] === downloadTask" in progress and
        "currentEpisode?.status == .downloading" in progress,
        "Late progress must not resurrect removed, replaced, failed, or evicted episodes.")

print("Watch download/removal race regression checks passed")
