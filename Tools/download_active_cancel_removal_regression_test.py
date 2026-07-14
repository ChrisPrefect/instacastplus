#!/usr/bin/env python3
"""Pins terminal cache-removal semantics when the episode is still downloading."""

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


remove_episode = body(
    "- (void) removeCacheForEpisode:(CDEpisode*)episode\n"
    "                      automatic:(BOOL)automatic\n"
    "                     completion:(void (^)(NSError* error))completion"
)
begin_cancel = body("- (void)_beginRemovalAfterCancellingEpisode:")
finish_cancel = body("- (void)_finishCancelledDownloadRemovalForIdentifier:")
operation_end = body("- (void) cacheOperationDidEnd:")
prepare_clear = body("- (ICCacheDeletionPreparation*) _prepareForDestructiveCacheClear")
commit_clear = body("- (void) _commitDestructiveCacheClearPreparation")

require("_cancelledDownloadRemovalRequestsByIdentifier" in SOURCE,
        "Active-download removals need durable per-hash terminal state.")
require("_beginRemovalAfterCancellingEpisode:" in remove_episode and
        "completion(nil)" not in remove_episode.split("isCachingEpisode", 1)[-1].split("return;", 1)[0],
        "Cancellation must not claim success before the operation and staged-file cleanup end.")
require("CacheManagerWillDeleteCacheFilesNotification" in begin_cancel and
        "_cacheDeletionTokensByIdentifier" in begin_cancel and
        "_cacheDeletionHashesDuringIndexScan" in begin_cancel and
        "cancelCachingEpisode:" in begin_cancel,
        "Active cancellation must enter the same identity, startup-index and lifecycle contract as cached deletion.")
require("waitForPreparation" in begin_cancel and
        begin_cancel.find("waitForPreparation") < begin_cancel.find("cancelCachingEpisode:"),
        "The active operation must remain untouched until the pre-delete queue snapshot is durable.")
require('"lastDownloaded"' in begin_cancel and '"downloaded"' in begin_cancel and
        '"wasCached"' in begin_cancel,
        "Rollback must restore the pre-cancel logical episode state instead of inventing a downloaded state.")
require("_finishCancelledDownloadRemovalForIdentifier:" in operation_end,
        "The CacheOperation terminal callback must finish a pending removal.")
require('terminalRequest[@"url"] = operation.localURL' in operation_end and
        operation_end.find('terminalRequest[@"url"] = operation.localURL') <
        operation_end.find("_finishCancelledDownloadRemovalForIdentifier:"),
        "A terminal download can change its file extension; removal must delete the operation's final URL, not its preflight URL.")
pending_branch = operation_end.find("_cancelledDownloadRemovalRequestsByIdentifier")
normal_success = operation_end.find("\n\tif (succeeded)")
require(pending_branch != -1 and normal_success != -1 and pending_branch < normal_success and
        "return;" in operation_end[pending_branch:normal_success],
        "An operation completing during preparation must not publish a normal download before removal finishes.")
require("removeItemAtURL" in finish_cancel and "error:&" in finish_cancel and
        "CacheManagerWillCommitCacheFileDeletionNotification" in finish_cancel and
        finish_cancel.find("CacheManagerWillCommitCacheFileDeletionNotification") < finish_cancel.find("removeItemAtURL") and
        "attributesOfItemAtPath" in finish_cancel and
        "_invalidateDownloadedBytesAndRecalculate" in finish_cancel and
        "ICRemoveTranscriptCacheForEpisodeHashes" in finish_cancel and
        "CacheManagerDidDeleteCacheFilesNotification" in finish_cancel and
        "CacheManagerDidRestoreCacheNotification" in finish_cancel and
        "CacheManagerDidUpdateNotification" in finish_cancel,
        "Terminal cancellation must verify cleanup, reconcile bytes and report success or rollback explicitly.")
require("waitForPreparation" in SOURCE and
        "removeAllObjects" in commit_clear and
        "_cancelledDownloadRemovalRequestsByIdentifier" in commit_clear,
        "Full clear must invalidate active-cancellation requests and their callbacks.")

print("Download active-cancel removal regression checks passed")
