#!/usr/bin/env python3
"""Pins non-blocking, race-safe automatic Watch selection for large libraries."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
FEED_SETTINGS = (ROOT / "Classes" / "FeedSettingsViewController.m").read_text()


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


sync = method_body(MANAGER, "- (void)syncNow")
require("_advanceAutomaticSelectionGeneration" in sync and "automaticSelectionQueue" in sync,
        "A full Watch sync needs a generation-coalesced background selection plan.")
require("newExportBackgroundContext" in sync and "_sendCurrentManifestAndNotify" not in sync,
        "Full selection reads must use the isolated WAL reader and send only after successful apply.")
require("performBlockAndWait" in sync and "[context performBlock:^" not in sync,
        "The serial planner queue must wait for each isolated read instead of overlapping Core Data scans.")

plan = method_body(MANAGER, "- (NSDictionary*)_automaticSelectionPlanInContext:")
require("relationshipKeyPathsForPrefetching = @[@\"properties\"]" in plan,
        "The selection planner may prefetch small feed rules, not episode relationships.")
require("feed.episodes" not in plan and "sortedArrayUsingDescriptors" not in plan,
        "Automatic selection must never materialize and sort complete feed episode relationships.")
require("fetchLimit = ICAppleWatchAutomaticFetchPageSize" in plan and "fetchOffset" in plan,
        "Per-feed candidates must be read in bounded pages.")
require('initWithKey:@"pubDate" ascending:NO' in plan and
        'initWithKey:@"objectHash" ascending:YES' in plan,
        "Candidate paging needs deterministic pub-date/hash order.")
require("preferedMedium.fileURL" in plan and "suppressedEpisodeHashes" in plan,
        "Top-K must be filled only after media and suppression filters.")

apply_batch = method_body(MANAGER, "- (void)_applyAutomaticSelectionOperations:")
require("ICAppleWatchAutomaticApplyBatchSize" in apply_batch and
        'predicateWithFormat:@"episodeHash IN %@"' in apply_batch,
        "Main-context reconciliation must use small indexed state batches.")
require("stateForEpisodeHash:" not in apply_batch and "_stateForEpisode:" not in apply_batch,
        "Reconciliation must not perform one state fetch per candidate.")
require("_isAutomaticSelectionGenerationCurrent:" in apply_batch and
        "saveReturningError" in apply_batch and
        "dispatch_async(dispatch_get_main_queue()" in apply_batch,
        "Each apply chunk must reject stale work, check its save, and yield before continuing.")
require("if (!state.watchAddedDate)" in apply_batch,
        "Full sync must preserve existing Watch ordering dates.")
require("_sendCurrentManifestAndNotify" in apply_batch,
        "Manifest/revision may be created only after the final successful apply chunk.")

rebuild = method_body(MANAGER, "- (void)rebuildAutomaticSelectionsAndSync")
require("[self syncNow]" in rebuild and "_rebuildAutomaticSelections" not in rebuild,
        "The public rebuild alias must not execute the old selector twice.")
require("- (void)_rebuildAutomaticSelections" not in MANAGER,
        "The synchronous relationship-scanning rebuild must be removed.")

send_episode = method_body(MANAGER, "- (void)sendEpisodeToWatch:")
move_episode = method_body(MANAGER, "- (void)moveEpisodeAtIndex:")
appearance = method_body(MANAGER, "- (void)_appearanceDidUpdate:")
require("syncCurrentSelectionsNow" in send_episode and "syncNow" not in send_episode,
        "A manual add must not scan all automatic feed rules.")
require("syncCurrentSelectionsNow" in move_episode and "syncNow" not in move_episode,
        "Reordering must send current order without rebuilding it away.")
require("_sendCurrentManifestAndNotify" in appearance and "allEpisodeStates" not in appearance and "syncNow" not in appearance,
        "An accent-color change must not launch a full library scan.")

current_sync = method_body(MANAGER, "- (void)syncCurrentSelectionsNow")
require("_advanceAutomaticSelectionGeneration" not in current_sync,
        "A current-only send must not abandon a partially applied full selection plan.")

save_and_sync = method_body(FEED_SETTINGS, "- (BOOL)_saveAndSyncAppleWatchSettings")
require("saveReturningError" in save_and_sync and
        save_and_sync.find("saveReturningError") < save_and_sync.find("rebuildAutomaticSelectionsAndSync"),
        "Per-feed Watch rules must be durable before the isolated reader plans from them.")

print("Watch automatic-selection scaling regression checks passed")
