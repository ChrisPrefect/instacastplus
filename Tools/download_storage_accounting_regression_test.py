#!/usr/bin/env python3
"""Pins exact, single-flight accounting for downloaded storage."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
OPERATION = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()
HEADER = (ROOT / "Classes" / "CacheOperation_iOS7.h").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = source.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("_downloadedBytesKnown" in MANAGER and
        "_downloadedBytesRecalculationInFlight" in MANAGER and
        "_downloadedBytesGeneration" in MANAGER,
        "Zero bytes, unknown state, in-flight scan, and scan generation must be distinct.")
require("finalFileSize" in HEADER and "self.finalFileSize = (unsigned long long)fileSize" in OPERATION,
        "A verified download must report its exact final size without a directory rescan.")

count = method_body(MANAGER, "- (unsigned long long) numberOfDownloadedBytes")
require("_downloadedBytesKnown" in count and "_downloadedBytes == 0" not in count,
        "A legitimately empty cache must not trigger endless directory scans.")

recalculate = method_body(MANAGER, "- (void)recalculateDownloadedBytesInBackground")
require("_downloadedBytesRecalculationInFlight" in recalculate,
        "Overlapping callers must share one directory reconciliation.")
require("scanGeneration" in recalculate and "_downloadedBytesGeneration" in recalculate,
        "An obsolete scan must never overwrite newer add/remove/clear state.")
require("scanSnapshotValid" in recalculate and "errorHandler" in recalculate and
        "ICCacheFileErrorMeansMissing" in recalculate and "resourceValuesForKeys" in recalculate,
        "Directory and attribute read failures must invalidate accounting instead of being silently counted as zero bytes.")
known_publish = recalculate.find("_setDownloadedBytes:totalBytes known:YES")
validity_guard = recalculate.find("if (!scanSnapshotValid)")
require(validity_guard != -1 and known_publish != -1 and validity_guard < known_publish,
        "Only a complete readable filesystem snapshot plus tracked active-stream bytes may become authoritative known bytes.")

finish = method_body(MANAGER, "- (void)_finishCacheOperationDidEnd:")
require("_addDownloadedBytes:operation.finalFileSize" in finish and
        finish.find("_addDownloadedBytes:operation.finalFileSize") < finish.find("autoClearAndMakeRoomForBytes"),
        "A successful final move must update exact bytes before enforcing the storage limit.")
require("_downloadedBytes = 0" not in finish and "recalculateDownloadedBytesInBackground" not in finish,
        "Every completed episode must not invalidate and rescan the whole cache.")

remove_one = method_body(MANAGER, "- (void) removeCacheForEpisode:")
remove_one_with_completion = method_body(
    MANAGER,
    "- (void) removeCacheForEpisode:(CDEpisode*)episode\n"
    "                      automatic:(BOOL)automatic\n"
    "                     completion:(void (^)(NSError* error))completion",
)
remove_feed = method_body(MANAGER, "- (void) removeCacheForFeed:")
remove_feed_with_completion = method_body(
    MANAGER,
    "- (void) removeCacheForFeed:(CDFeed*)feed\n"
    "                   automatic:(BOOL)automatic\n"
    "                  completion:(void (^)(NSError* error))completion",
)
require("completion:nil" in remove_one and "_removeCacheForEpisodes:" in remove_one_with_completion and
        "completion:nil" in remove_feed and
        "removeCacheForFeeds:feed ? @[feed] : @[]" in remove_feed_with_completion,
        "Single and feed deletion must preserve exact batch accounting after durable ownership partitioning.")

finish_removal = method_body(MANAGER, "- (void)_finishCacheFileDeletionForItems:")
require("removedBytes +=" in finish_removal and
        finish_removal.count("_subtractDownloadedBytes:removedBytes") == 1,
        "A deletion batch must accumulate successful file sizes and subtract one exact byte delta.")
require("_invalidateDownloadedBytesAndRecalculate" in finish_removal,
        "Unknown/raced file sizes must reconcile once instead of guessing the byte delta.")

import_file = method_body(MANAGER, "- (void) importFileAtURL:")
perform_import = method_body(MANAGER, "- (void)_importFileAtURL:")
require("_importFileAtURL:" in import_file and "importedFileSize" in perform_import and
        "_addDownloadedBytes:importedFileSize" in perform_import,
        "A successful import must add its copied file size without rescanning.")

auto_clear = method_body(MANAGER, "- (void) autoClearAndMakeRoomForBytes:")
require("_downloadedBytesKnown" in auto_clear and "_hasPendingAutoClear" in auto_clear,
        "Storage enforcement must wait for real accounting when startup reconciliation is incomplete.")
require("bytes <= maxAllowedBytes - loadedBytes" in auto_clear,
        "Exactly reaching the configured limit must not evict an entire extra episode.")

print("Download storage accounting regression checks passed")
