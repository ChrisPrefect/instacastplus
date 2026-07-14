#!/usr/bin/env python3
"""Pins streaming import to the same generation lease as its temp-file writer."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if source.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("importStreamingFileAtURL:(NSURL*)url" in CACHE_H and
        "leaseToken:(NSString*)leaseToken" in CACHE_H,
        "The stream loader needs a lease-bound import entry point distinct from external imports.")

external_import = body(CACHE, "- (void) importFileAtURL:")
require("removeItemAtURL:url" not in external_import and
        "removeItemAtURL:url.URLByDeletingLastPathComponent" not in external_import,
        "A busy external import must never delete the user-selected source file or its parent directory.")

stream_import = body(CACHE, "- (void) importStreamingFileAtURL:")
require("_streamingCacheLeaseTokensByIdentifier[identifier]" in stream_import and
        "isEqualToString:leaseToken" in stream_import,
        "A stream import must be rejected unless its exact writer lease is still current.")

internal_import = body(CACHE, "- (void)_importFileAtURL:")
require("streamingLeaseToken:(NSString*)streamingLeaseToken" in CACHE and
        "_streamingCacheLeaseTokensByIdentifier[identifier]" in internal_import and
        "isEqualToString:streamingLeaseToken" in internal_import,
        "The publish gate must reject a cancelled or superseded stream generation after file I/O finishes.")
require("moveItemAtURL:url toURL:cachedURL" in internal_import,
        "Once handed to CacheManager, the complete stream file must move atomically into final ownership instead of being copied then unlinked by another owner.")
file_operation = internal_import.split("dispatch_async(_cacheDeletionQueue", 1)[1].split("dispatch_async(dispatch_get_main_queue()", 1)[0]
require("destinationAlreadyExists" in file_operation and
        "removeItemAtURL:cachedURL" not in file_operation,
        "A failed move must never delete a pre-existing indexed download; a valid existing destination wins over the redundant stream source.")
require("_invalidateDownloadedBytesAndRecalculate" in internal_import,
        "Streaming source-to-final replacement must reconcile bytes after the partial source disappears.")

coverage_import = body(PLAYBACK, "- (void)_updateCoverageStateAndImportIfNeeded")
require("importStreamingFileAtURL:mainSelf.tempURL" in coverage_import and
        "leaseToken:mainSelf.leaseToken" in coverage_import,
        "The validated loader must pass its lease into CacheManager's stream import.")
require("cacheValidationStarted" in coverage_import and
        coverage_import.find("cacheImportStarted = YES") > coverage_import.find("if (!hasPlayableMediaTrack)") and
        coverage_import.find("cacheImportStarted = YES") < coverage_import.find("importStreamingFileAtURL"),
        "Validation must not claim CacheManager ownership; the handoff flag starts only after media validation succeeds.")
require("removeItemAtURL:innerSelf.tempURL" not in coverage_import,
        "The loader must not unlink a temp file after transferring its ownership to CacheManager.")

cancel_loader = body(PLAYBACK, "- (void)cancelAndDiscardPartialCache")
fail_loader = body(PLAYBACK, "- (void)_failWithError:")
require("!self.cacheImportStarted" in cancel_loader and
        "!self.cacheImportStarted" in fail_loader,
        "Cancel/failure may delete only temp files that have not already been handed to an in-flight import.")
require("ICCacheStreamingImportWasSuperseded" in PLAYBACK and
        "[innerSelf _failWithError:error]" in coverage_import,
        "A stale lease completion must end silently while genuine I/O/media failures remain visible.")
failed_import_completion = coverage_import.split("if (!success)", 1)[1].split("CacheManager* cacheManager", 1)[0]
require("ICCacheStreamingImportWasSuperseded(error)" in failed_import_completion and
        "finishStreamingCacheForEpisode:innerSelf.episode" in failed_import_completion and
        "leaseToken:innerSelf.leaseToken" in failed_import_completion,
        "A superseded import must terminally release its exact lease; token matching keeps a newer generation untouched.")

print("Download stream-import ownership regression checks passed")
