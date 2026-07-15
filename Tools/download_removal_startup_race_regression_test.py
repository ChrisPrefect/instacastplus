#!/usr/bin/env python3
"""Pins deletion authority over an incomplete launch-time download index."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = SOURCE.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


remove_batch = body(
    "- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes\n"
    "                       automatic:(BOOL)automatic\n"
    "             physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot\n"
    "                      completion:"
)
perform_files = body("- (void)_performCacheFileDeletionForItems:")
finish_files = body("- (void)_finishCacheFileDeletionForItems:")
remove_feed = body("- (void)_removeCacheForFeeds:")

scan_start = SOURCE.find("- (void)_buildCacheIndexInBackground")
scan_end = SOURCE.find("- (BOOL) canDownload", scan_start)
startup_scan = SOURCE[scan_start:scan_end]

require("_cacheDeletionHashesDuringIndexScan" in SOURCE and
        "_cacheIndexScanInFlight" in remove_batch and
        "_cacheDeletionHashesDuringIndexScan" in remove_batch,
        "Deletion begun during startup discovery must leave a hash marker until the snapshot is applied.")
require("_cacheDeletionHashesDuringIndexScan" in startup_scan and
        startup_scan.find("_cacheDeletionHashesDuringIndexScan") < startup_scan.find("addEntriesFromDictionary:validScannedURLs"),
        "The startup snapshot must filter deletions before adding URLs, episodes, or downloaded flags.")
require("_cacheDeletionHashesDuringIndexScan removeObject:" in finish_files,
        "A true file-deletion failure must release the startup filter so rollback can restore the download.")

require("requestedHashes" in perform_files and "physicalURLsByHash" in perform_files and
        perform_files.count("contentsOfDirectoryAtPath") == 1 and
        "rangeOfString:@\" - \" options:NSBackwardsSearch" in perform_files,
        "An incomplete index must resolve all old/new audio URLs with one off-main directory scan per batch.")
require("indexedURL" in perform_files and "orderedSetWithObject:indexedURL" in perform_files and
        "ICCacheFileErrorMeansMissing(attributesError)" in perform_files,
        "A stale expected URL must be combined with hash discovery instead of hiding a different real file.")
require("ICCacheDeletionResolvedURLKey" in perform_files and
        "ICCacheDeletionFileWasPresentKey" in perform_files and
        "ICCacheDeletionResolvedURLKey" in finish_files,
        "Rollback must restore the URL and downloaded state discovered by the physical deletion phase.")
require("lastDownloaded != nil" in remove_feed and "newICloudSyncBackgroundContext" in remove_feed,
        "Unsubscribing during startup must select persisted feed episodes, not only the still-empty cache set.")

print("Download removal startup-race regression checks passed")
