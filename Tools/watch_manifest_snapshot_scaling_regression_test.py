#!/usr/bin/env python3
"""Pins off-main Watch manifest materialization and bounded state transitions."""

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


send = method_body("- (void)_sendCurrentManifestAndNotify")
require("manifestBuildQueue" in send and "_advanceManifestBuildGeneration" in send,
        "Manifest requests need a coalesced utility snapshot pipeline.")
require("newExportBackgroundContext" in send and "performBlockAndWait" in send,
        "Manifest Core Data reads must run on the isolated WAL reader, never the UI context.")
require("allEpisodeStates" not in send and "_manifestEntriesForStates" not in send,
        "The send entry point must not fetch/materialize Watch state on main.")

snapshot = method_body("- (NSDictionary*)_manifestSnapshotInContext:")
require("ICAppleWatchEpisodeFetchBatchSize" in snapshot and "subarrayWithRange:" in snapshot,
        "Large manifest episode lookups must stay within bounded IN batches.")
require("setQueryGenerationFromToken" in snapshot,
        "Paged state and episode reads must come from one stable Core Data generation.")
require("NSDictionaryResultType" in snapshot and "fetchLimit" in snapshot and "fetchOffset" in snapshot,
        "Watch state must be paged as lightweight values instead of retaining every managed object.")
require("stateByEpisodeHash" not in snapshot,
        "The snapshot must not keep the complete managed Watch-state graph alive.")
require('predicateWithFormat:@"objectHash IN %@"' in snapshot,
        "Manifest episodes need indexed hash batches.")
require('relationshipKeyPathsForPrefetching = @[@"feed", @"feed.properties", @"media"]' in snapshot,
        "Manifest metadata relationships must be prefetched off-main in each bounded batch.")
require("DMANAGER" not in snapshot,
        "The isolated snapshot must not fall back to main-context DatabaseManager lookups.")

sent_apply = method_body("- (void)_applyManifestSentStateForEpisodeHashes:")
require('predicateWithFormat:@"episodeHash IN %@"' in sent_apply and
        "saveReturningError" in sent_apply and
        "dispatch_async(dispatch_get_main_queue()" in sent_apply,
        "Post-send state updates must also be bounded and UI-yielding.")
require("ICAppleWatchStateWriteBatchSize" in sent_apply and
        "![state.watchStatus isEqualToString:ICAppleWatchStatusSelected]" in sent_apply,
        "Only still-selected rows may advance to manifestSent; ACK and terminal states must never regress.")
require("_applyManifestRevisionForSnapshot:" not in SOURCE and 'snapshot[@"revisionHashes"]' not in SOURCE,
        "Causal floors belong to acknowledged Watch revisions, not speculative outgoing snapshots.")

require("- (NSArray<NSDictionary*>*)_manifestEntriesForStates:" not in SOURCE,
        "The old main-context manifest builder must be removed.")

print("Watch manifest snapshot scaling regression checks passed")
