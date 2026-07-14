#!/usr/bin/env python3
"""Pins a true per-selection identity across Watch events, deletion retries, and re-adds."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PHONE = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
WATCH_EPISODE = (ROOT / "InstacastWatch" / "WatchEpisode.swift").read_text()
WATCH_CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
WATCH_DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()


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


manifest_entry = body(PHONE, "- (NSDictionary*)_manifestEntryForEpisode:")
manual_add = body(PHONE, "- (void)sendEpisodeToWatch:")
automatic_apply = body(PHONE, "- (void)_applyAutomaticSelectionOperations:")
event_gate = body(PHONE, "- (int64_t)_acceptedWatchEventRevisionForPayload:")
update_event = body(PHONE, "- (AppleWatchEpisodeState*)_updateStateForPayload:")
merge_playback = body(PHONE, "- (void)_mergeWatchPlaybackPayload:")
state_for_hash = body(PHONE, "- (AppleWatchEpisodeState*)stateForEpisodeHash:")
require('@"selectionIdentifier"' in manifest_entry and "state.uid" in PHONE,
        "The phone manifest must carry the Core Data state's unique lifetime identity.")
require("wasRemovingFromWatch" in manual_add and "state.uid = [NSUUID UUID].UUIDString" in manual_add and
        "wasRemovingFromWatch" in automatic_apply and "state.uid = [NSUUID UUID].UUIDString" in automatic_apply,
        "Every remove/re-add transition must rotate selection identity independently of sort dates.")
require("watchManifestProtocolVersion >= 3" in event_gate and
        'payload[@"selectionIdentifier"]' in event_gate and "state.uid" in event_gate and
        "advanceDurableState" in event_gate,
        "Current Watch events must be rejected unless they identify the exact current selection.")
require("_stateForWatchEventPayload:" in update_event and "_stateForWatchEventPayload:" in merge_playback,
        "Download and playback events must resolve state by selection identity, not an arbitrary duplicate hash row.")
require("request.fetchLimit = 1" not in state_for_hash and
        "watchAddedDate" in state_for_hash and "return states.firstObject;" in state_for_hash and
        "if (!state.removingFromWatch)" not in state_for_hash,
        "Hash-only UI actions must use the newest selection generation, including a removal that blocks older duplicates.")

require("let selectionIdentifier: String" in WATCH_EPISODE and
        "case selectionIdentifier" in WATCH_EPISODE and
        'dictionary["selectionIdentifier"]' in WATCH_EPISODE,
        "The Watch manifest/archive must retain the per-selection identity with legacy decode compatibility.")
send = body(WATCH_CONNECTIVITY, "func send(type:")
activation = body(WATCH_CONNECTIVITY, "activationDidCompleteWith")
require('message["selectionIdentifier"]' in send and "episode.selectionIdentifier" in send,
        "Every per-episode Watch event must automatically include the current selection identity.")
require('"manifestProtocolVersion": 3' in activation,
        "The Watch must negotiate mandatory selection identities separately from older protocol versions.")

send_deleted = body(WATCH_DOWNLOAD, "private func sendDeletionAcknowledgements(")
ack_deleted = body(WATCH_DOWNLOAD, "func acknowledgeDeletedEpisodes(")
require('"selectionIdentifiers"' in send_deleted and "episode.selectionIdentifier" in send_deleted and
        "selectionIdentifiers" in ack_deleted and "episode.selectionIdentifier" in ack_deleted,
        "Deletion batches and app ACKs must correlate by immutable selection identity, not watchAddedDate.")

print("Watch selection identity regression checks passed")
