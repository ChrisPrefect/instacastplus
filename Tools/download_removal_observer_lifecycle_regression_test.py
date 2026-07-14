#!/usr/bin/env python3
"""Pins reversible observer behavior around asynchronous download-file deletion."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE_M = (ROOT / "Classes" / "CacheManager.m").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
PLAYER = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
AUDIO = (ROOT / "Classes" / "AudioSession.m").read_text()
WIDGET = (ROOT / "Classes" / "WidgetDataExporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


for notification in (
    "CacheManagerWillDeleteCacheFilesNotification",
    "CacheManagerDidDeleteCacheFilesNotification",
    "CacheManagerDidRestoreCacheNotification",
):
    require(notification in CACHE_H and notification in CACHE_M,
            f"Missing explicit cache-file lifecycle notification: {notification}")

require("pendingCacheDeletionHashes" in QUEUE and
        "cacheFilesWillBeDeleted" in QUEUE and
        "cacheFilesWereDeleted" in QUEUE and
        "cacheDeletionWasRestored" in QUEUE,
        "Transcription jobs must pause before I/O, dequeue only on success, and resume after rollback.")
require("!pendingCacheDeletionHashes.contains" in QUEUE,
        "A queue item waiting on a physical delete result must not restart prematurely.")
observer_start = QUEUE.find("// Cancel transcription when episode cache is removed")
observer_end = QUEUE.find("// Single observer for download completion", observer_start)
observer = QUEUE[observer_start:observer_end]
require("addObserver(self," in observer and "selector: #selector(cacheFilesWillBeDeleted" in observer and
        "Task { @MainActor" not in observer,
        "The pre-delete cancellation must execute synchronously in the main-thread notification stack.")

player_handler_start = PLAYER.find("- (void)cacheManagerDidClearCacheNotification:")
player_handler_end = PLAYER.find("- (void)_transcriptDidChange:", player_handler_start)
player_handler = PLAYER[player_handler_start:player_handler_end]
require("[self.transcriptTask cancel]" in player_handler and
        "_transcriptLoadingURL = nil" in player_handler and
        "transcriptPrefetchTasks" in player_handler,
        "Deleting a download must invalidate matching HTTP transcript writes before file cleanup.")
require("CacheManagerWillDeleteCacheFilesNotification" in PLAYER and
        "@selector(cacheManagerDidClearCacheNotification:)" in PLAYER,
        "Full clear must cancel transcript HTTP work on the pre-delete notification, not after disk removal.")
require("self.transcriptPrefetchTasks[taskKey] != task" in PLAYER,
        "A cancelled prefetch completion must not restart or rewrite its transcript cache.")

audio_observer_start = AUDIO.index("- (void) _observeEpisodeCacheBeingDeleted")
audio_observer_end = AUDIO.index("- (void) _handleEpisodeCacheCleared:", audio_observer_start)
audio_observer = AUDIO[audio_observer_start:audio_observer_end]
require("CacheManagerWillCommitCacheFileDeletionNotification" in audio_observer and
        "CacheManagerWillDeleteCacheFilesNotification" not in audio_observer and
        "CacheManagerDidClearCacheNotification" not in audio_observer,
        "Playback must stop after durable preparation but before full-clear file I/O.")

require("CacheManagerDidRestoreCacheNotification" in WIDGET and
        "@selector(_cacheDidClear:)" in WIDGET,
        "A physical-delete rollback must export the restored download state to widgets.")

print("Download removal observer-lifecycle regression checks passed")
