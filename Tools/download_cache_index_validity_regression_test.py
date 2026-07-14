#!/usr/bin/env python3
"""Pins authoritative startup-cache readiness and transcription resume gating."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE_M = (ROOT / "Classes" / "CacheManager.m").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("prepareCacheIndexIfNeeded" in CACHE_H and
        "_buildCacheIndexInBackground" in CACHE_M,
        "An invalid startup listing needs an event-driven retryable index builder.")

scan_start = CACHE_M.find("- (void)_buildCacheIndexInBackground")
scan_end = CACHE_M.find("- (BOOL) canDownload", scan_start)
require(scan_start != -1 and scan_end != -1, "Missing extracted startup cache-index builder.")
scan = CACHE_M[scan_start:scan_end]
require("cacheIndexSnapshotValid" in scan and
        "if (!cacheIndexSnapshotValid)" in scan and
        "_cacheIndexReady = NO" in scan,
        "A protected-data or directory-I/O error must not become an authoritative empty cache.")
require("attributesOfItemAtPath" in scan and
        "cacheIndexSnapshotValid = NO" in scan and
        "checkResourceIsReachableAndReturnError" in scan,
        "A non-missing error for one protected file must invalidate the whole authoritative snapshot.")
require(scan.find("if (!cacheIndexSnapshotValid)") < scan.find("_cacheIndexReady = YES"),
        "Only a successful filesystem snapshot may publish cache-index readiness.")
require("UIApplicationProtectedDataDidBecomeAvailable" in CACHE_M and
        "UIApplicationWillEnterForegroundNotification" in CACHE_M,
        "Indexing must retry on real protection/lifecycle transitions, without a timer workaround.")

process_start = QUEUE.find("private func processNext()")
process_end = QUEUE.find("// Resolve audio URL", process_start)
process_guard = QUEUE[process_start:process_end]
require("prepareCacheIndexIfNeeded" in process_guard and
        "isCacheIndexReady" in process_guard,
        "Persisted audio jobs must not resolve or auto-download before cache discovery completes.")

print("Download cache-index validity regression checks passed")
