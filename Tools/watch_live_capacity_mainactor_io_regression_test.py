#!/usr/bin/env python3
"""Pins live Watch capacity reads off MainActor and out of SwiftUI rendering."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORAGE = (ROOT / "InstacastWatch" / "WatchStorageManager.swift").read_text()
DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()
VIEWS = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require(
    "final class WatchStorageManager: ObservableObject" in STORAGE
    and "@Published private(set) var latestFreeBytes: Int64?" in STORAGE,
    "SwiftUI and diagnostics need a reactive last-known value instead of issuing volume stats while rendering.",
)

measure = body(STORAGE, "nonisolated static func measureAvailableBytes(")
available = body(STORAGE, "private nonisolated static func availableBytes(")
require(
    "Task.detached(priority: .utility)" in measure
    and "Self.availableBytes(" in measure
    and "volumeAvailableCapacityKey" in available,
    "Fresh safety checks must read volume capacity in detached utility work.",
)

progress = body(
    DOWNLOAD,
    "nonisolated func urlSession(_ session: URLSession,\n"
    "                                downloadTask: URLSessionDownloadTask,\n"
    "                                didWriteData bytesWritten: Int64,",
)
require(
    "await WatchStorageManager.measureAvailableBytes(" in progress
    and progress.count("activeTasksByHash[hash] === downloadTask") >= 2
    and progress.count("status == .downloading") >= 2,
    "The two-second live guard must await a fresh off-main measurement and then revalidate task ownership/state.",
)
require(
    "WatchStorageManager.shared.freeBytes()" not in progress,
    "Download progress must never issue a synchronous MainActor volume stat.",
)

abort = body(DOWNLOAD, "private func abortDownloadForInsufficientStorage(")
require(
    "measuredFreeBytes: Int64" in DOWNLOAD[DOWNLOAD.find("private func abortDownloadForInsufficientStorage("):DOWNLOAD.find("private func abortDownloadForInsufficientStorage(") + 260]
    and "WatchStorageManager.shared.freeBytes()" not in abort,
    "The abort diagnostic must reuse the authoritative measurement that triggered it.",
)

autofill = body(DOWNLOAD, "private func autoFillEvictedEpisodes()")
require(
    "await WatchStorageManager.measureAvailableBytes(" in autofill
    and "guard activeTasksByHash.isEmpty" in autofill
    and "WatchStorageManager.shared.freeBytes()" not in autofill,
    "Auto-fill must measure asynchronously and revalidate idle state before queueing episodes.",
)

require(
    "@ObservedObject private var storageManager = WatchStorageManager.shared" in VIEWS
    and "storageManager.latestFreeBytes" in VIEWS
    and "WatchStorageManager.shared.freeBytes()" not in VIEWS,
    "The storage header must render cached reactive state, never query the filesystem from View.body.",
)
require(
    "WatchStorageManager.shared.freeBytes()" not in PLAYER,
    "Playback diagnostics must use the last measured value rather than blocking audio/UI callbacks.",
)

print("Watch live-capacity MainActor I/O regression checks passed")
