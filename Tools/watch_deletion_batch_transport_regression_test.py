#!/usr/bin/env python3
"""Pins bounded Watch deletion acknowledgements and batched phone lookup."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WATCH = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
TRANSFER = (ROOT / "InstacastWatch" / "WatchManifestTransfer.swift").read_text()
PHONE = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing function/method: {signature}")
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
    raise AssertionError(f"Unterminated body: {signature}")


cleanup = body(WATCH, "private func processPendingRemovalBatch()")
send_batches = body(WATCH, "private func sendDeletionAcknowledgements(")
timestamp = body(WATCH, "private func timestamp(")
activation = body(CONNECTIVITY, "activationDidCompleteWith")
require("deletionAcknowledgementBatchSize = 200" in WATCH and
        "physicallyRemovedHashes" in WATCH,
        "Deletion acknowledgements must be accumulated and capped at a conservative payload size.")
require("eventDateFormatter" in WATCH and "eventDateFormatter.string(from: date)" in timestamp and
        "ISO8601DateFormatter()" not in timestamp,
        "Mass deletion must reuse one formatter instead of constructing thousands on MainActor.")
require('send(type: "watch.deleted"' not in cleanup and
        "sendDeletionAcknowledgements" in cleanup,
        "The cleanup loop must not enqueue one durable WatchConnectivity transfer per episode.")
require('send(type: "watch.deletedEpisodes"' in send_batches and
        '"episodeHashes"' in send_batches and '"selectionIdentifiers"' in send_batches and
        "stride(" in send_batches and "delivery: .durable" in send_batches and
        "episode.status == .removing" in send_batches and "episode.selectionIdentifier" in send_batches,
        "Removed episodes must be sent as bounded compact parallel-array batches.")
require("supportsDeletionAcknowledgementBatches" in send_batches and
        'send(type: "watch.deleted"' in send_batches and
        "ICAppleWatchWatchEventProtocolVersion = 2" in PHONE and
        '@"watchEventProtocolVersion"' in PHONE and
        "watchEventProtocolVersion" in TRANSFER and
        "phoneWatchEventProtocolVersion" in CONNECTIVITY,
        "Deletion batching must be negotiated by the current phone manifest; mixed app versions must use the legacy event.")
require("receivedApplicationContext" in activation and
        activation.find("phoneWatchEventProtocolVersion = eventProtocolVersion") <
        activation.find("finalizePendingRemovalsAfterConnectivityActivation"),
        "Recovery must restore the current phone capability before resending thousands of pending removals.")

states_by_hash = body(PHONE, "- (NSDictionary<NSString*, NSArray<AppleWatchEpisodeState*>*>*)_statesByHashForEpisodeHashes:")
apply_deleted = body(PHONE, "- (BOOL)_applyWatchDeletedPayload:")
apply_deleted_episodes = body(PHONE, "- (BOOL)_applyWatchDeletedEpisodesPayload:")
require('predicateWithFormat:@"episodeHash IN %@"' in states_by_hash and
        "ICAppleWatchEpisodeFetchBatchSize" in states_by_hash,
        "The phone must fetch each deletion batch with bounded IN queries, not one SQL fetch per episode.")
require("_stringFromDate:state.watchAddedDate" in apply_deleted and
        "_shouldApplyWatchEventPayload" in apply_deleted and
        "deleteObject:state" in apply_deleted,
        "Each batched deletion must retain selection identity and per-episode event ordering.")
commit_deleted = body(PHONE, "- (void)_commitStagedWatchDeletionPayload:")
require("_applyWatchDeletedEpisodesPayload:" in commit_deleted and
        "_statesByHashForEpisodeHashes:" in apply_deleted_episodes and
        "_applyWatchDeletedPayload:" in apply_deleted_episodes and
        "episodeHashes.count == selectionIdentifiers.count" in apply_deleted_episodes,
        "The phone must validate and apply compact deletion batches through the shared causal path.")

print("Watch deletion batch transport regression checks passed")
