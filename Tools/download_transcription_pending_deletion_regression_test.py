#!/usr/bin/env python3
"""Pins durable, linear transcription handling around asynchronous cache deletion."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE_M = (ROOT / "Classes" / "CacheManager.m").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("pendingCacheDeletionHashes: [String]?" in QUEUE,
        "Pending cache deletions must be backwards-compatibly persisted with the queue.")
require("pendingCacheDeletionHashes: pendingCacheDeletionHashes.sorted()" in QUEUE and
        "pendingCacheDeletionHashes = Set(persisted.pendingCacheDeletionHashes ?? [])" in QUEUE,
        "Persist and restore the pending deletion identities, including empty terminal state.")

require("ICPersistedTranscriptionQueueWriteQueue" in QUEUE and
        'label: "com.vemedio.instacast.transcription-queue-persistence"' in QUEUE,
        "Queue snapshots need one serial writer so older async writes cannot win a race.")
require("ICCacheDeletionPreparation" in QUEUE and
        "beginPreparation()" in QUEUE and
        "waitForPreparation" in QUEUE and
        "firstError" in QUEUE,
        "Physical deletion must wait off-main until the pre-delete queue snapshot is durable.")
require('"cacheDeletionPreparation"' in CACHE_M and
        "preparationError" in CACHE_M and
        "waitForPreparation" in CACHE_M,
        "Every deletion worker must abort and restore when pre-delete persistence fails.")
writer_start = QUEUE.index("private func ICWritePersistedTranscriptionQueueData")
writer_end = QUEUE.index("/// Lets synchronous pre-delete observers", writer_start)
writer = QUEUE[writer_start:writer_end]
require("try data.write" in writer and "completion?(error as NSError)" in writer and
        "try? data.write" not in writer,
        "The preparation barrier must propagate a real atomic-write failure, not just block completion.")
require("_commitDestructiveCacheClearPreparation" in CACHE_M,
        "Full clear must not cancel jobs or discard resume state before its queue snapshot is durable.")

require("CacheManagerDidFinishBuildingCacheIndexNotification" in CACHE_H and
        "CacheManagerDidFinishBuildingCacheIndexNotification" in CACHE_M,
        "Restart reconciliation needs an explicit authoritative cache-index-ready event.")
require("reconcilePendingCacheDeletionsIfReady" in QUEUE and
        "cachedEpisodeObjectHashes" in QUEUE and
        "guard cman.isCacheIndexReady" in QUEUE,
        "After restart, pending jobs must be reconciled only against the completed disk index.")

will_start = QUEUE.index("@objc private func cacheFilesWillBeDeleted")
will_end = QUEUE.index("@objc private func cacheFilesWereDeleted", will_start)
will_body = QUEUE[will_start:will_end]
require("itemsByHash" in will_body and "items.first(where:" not in will_body,
        "A 4,500-item deletion batch must map queue items once instead of scanning per hash.")

deleted_start = will_end
deleted_end = QUEUE.index("@objc private func cacheDeletionWasRestored", deleted_start)
restored_start = deleted_end
restored_end = QUEUE.index("// MARK: - Persistence", restored_start)
require("persistQueue()" in QUEUE[deleted_start:deleted_end] and
        "persistQueue()" in QUEUE[restored_start:restored_end],
        "Both terminal outcomes must persist removal of pending deletion identities.")

print("Transcription pending-deletion regression checks passed")
