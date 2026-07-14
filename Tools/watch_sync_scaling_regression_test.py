#!/usr/bin/env python3
"""Pins bounded Core Data work for frequently refreshed iPhone Watch state."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
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


visible = method_body("- (NSArray<AppleWatchEpisodeState*>*)visibleEpisodeStates")
require("_visibleEpisodeStatesFromAllStates:" in visible,
        "Visible Watch state must reuse the canonical fetch order.")
require("sortedArrayUsingComparator" not in visible and "episodeWithObjectHash:" not in visible,
        "Rendering Watch state must not issue episode fetches from an O(n log n) comparator.")

batch_lookup = method_body("- (NSDictionary<NSString*, CDEpisode*>*)_episodesByHashForEpisodeHashes:")
require("ICAppleWatchEpisodeFetchBatchSize" in SOURCE and "episodesWithObjectHashes:" in batch_lookup,
        "Watch episode resolution needs bounded indexed batches.")
require("subarrayWithRange:" in batch_lookup,
        "A large Watch selection must not exceed SQLite predicate limits in one IN query.")

progress = method_body("- (ICAppleWatchTransferPhase)watchDownloadProgressLoadedBytes:")
require("_rebuildWatchTransferSnapshotIfNeeded" in progress
        and "visibleEpisodeStates" not in progress
        and "_episodesByHashForEpisodeHashes:" not in progress,
        "Frequent Watch progress refreshes must read the cached aggregate without fetching the full selection.")
progress_rebuild = method_body("- (void)_rebuildWatchTransferSnapshotIfNeeded")
require("_episodesByHashForEpisodeHashes:" in progress_rebuild
        and "episodeWithObjectHash:" not in progress_rebuild,
        "The infrequent aggregate rebuild must resolve missing sizes in batches, not one fetch per row.")
progress_contribution = method_body("- (NSDictionary*)_watchTransferContributionForState:")
require("ICAppleWatchStatusDownloading" in progress_contribution
        and "ICAppleWatchStatusSelected" in progress_contribution
        and "ICAppleWatchTransferPhaseWaiting" in progress
        and "ICAppleWatchTransferPhaseDownloading" in progress,
        "Queued/offline Watch work must not be reported as an active download.")

send = method_body("- (void)_sendCurrentManifestAndNotify")
require("manifestBuildQueue" in send and "newExportBackgroundContext" in send and
        "[self allEpisodeStates]" not in send,
        "A manifest send must build one isolated snapshot without fetching Watch state on main.")

manifest = method_body("- (NSDictionary*)_manifestSnapshotInContext:")
require('predicateWithFormat:@"objectHash IN %@"' in manifest and "episodeWithObjectHash:" not in manifest,
        "Manifest construction must batch episode lookup in its isolated context.")
require("visibleEpisodeHashes" in manifest and "containsObject:episodeHash" in manifest,
        "A corrupt duplicate phone state must not produce duplicate Watch manifest identities.")

ack_apply = method_body("- (void)_applyManifestAcknowledgementBatchForEpisodeHashes:")
require("ICAppleWatchStateWriteBatchSize" in ack_apply and "subarrayWithRange:" in ack_apply,
        "A large manifest acknowledgement must be handled in bounded batches.")
require('predicateWithFormat:@"episodeHash IN %@"' in ack_apply and "stateForEpisodeHash:" not in ack_apply,
        "Manifest acknowledgement must fetch each state batch once, not once per hash.")
require("saveReturningError" in ack_apply and "dispatch_async(dispatch_get_main_queue()" in ack_apply,
        "Acknowledgement batches must save explicitly and yield to the UI between chunks.")

ack_route = SOURCE.split('@"watch.ackManifest"', 1)[1].split("else if", 1)[0]
require("_applyManifestAcknowledgementForRevision:" in ack_route and
        "_applyManifestAcknowledgementForEpisodeHashes:" in ack_route and
        "stateForEpisodeHash:" not in ack_route,
        "The Watch acknowledgement route must prefer compact revision batches and retain legacy compatibility.")

print("Watch sync scaling regression checks passed")
