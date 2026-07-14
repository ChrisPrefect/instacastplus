#!/usr/bin/env python3
"""Pins clear-cache authority over an in-flight startup filesystem snapshot."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("_cacheIndexGeneration" in SOURCE and "_cacheIndexReady" in SOURCE and "_cacheIndexScanInFlight" in SOURCE,
        "Startup cache discovery needs lifecycle state separate from byte-accounting scans.")

scan_start = SOURCE.find("- (void)_buildCacheIndexInBackground", SOURCE.find("@implementation CacheManager"))
scan_end = SOURCE.find("- (BOOL) canDownload", scan_start)
scan = SOURCE[scan_start:scan_end]
guard = "cacheIndexGeneration != self->_cacheIndexGeneration"
require(guard in scan,
        "A stale startup filesystem snapshot must be rejected by its own generation.")
require(scan.find(guard) < scan.find("episodesWithObjectHashes:episodeHashes") < scan.find("_restoreCachingEpisodesWhenHistoryReady"),
        "The generation check must precede every Core Data flag, URL-index and queue-restore side effect.")

clear_start = SOURCE.find("- (void)cancelDownloadsAndClearCacheWithCompletion:")
clear_end = SOURCE.find("- (NSString*) _savedCachingKeyForIdentifier", clear_start)
clear = SOURCE[clear_start:clear_end]
prepare_start = SOURCE.find("- (ICCacheDeletionPreparation*) _prepareForDestructiveCacheClear", SOURCE.find("@implementation CacheManager"))
prepare_end = SOURCE.find("- (NSError*) _deleteAllCacheFilesNow", prepare_start)
prepare = SOURCE[prepare_start:prepare_end]
require("_prepareForDestructiveCacheClear" in clear and
        "_commitDestructiveCacheClearPreparation" in clear and
        "_cacheIndexGeneration += 1" in prepare and "_cacheIndexReady = YES" in prepare,
        "A successful clear must make the empty cache authoritative over the startup scan.")
require("_finalizeDestructiveCacheClearJobState" in clear and
        "_removeAllSavedCachingInfos" in prepare,
        "Clearing before queue restoration must delete durable jobs so they cannot reappear next launch.")
require("_removeAllSavedCachingInfos" in SOURCE and "ICCachingEpisodeJobKeyPrefix" in SOURCE,
        "All per-job descriptors and the legacy queue snapshot need one clear-all path.")

print("Download startup-index generation regression checks passed")
