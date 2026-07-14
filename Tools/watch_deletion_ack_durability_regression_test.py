#!/usr/bin/env python3
"""Pins durable receive-before-return plus application-level deletion ACKs."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WATCH_DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
WATCH_CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
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


cleanup = body(WATCH_DOWNLOAD, "private func processPendingRemovalBatch()")
ack_watch = body(WATCH_DOWNLOAD, "func acknowledgeDeletedEpisodes(")
watch_handle = body(WATCH_CONNECTIVITY, "private func handle(payload:")
require("supportsDeletionAcknowledgementBatches" in cleanup and
        "finishPendingRemovalCleanup" in cleanup and
        "removeEpisodes(hashes:" in cleanup,
        "Current protocol removals must wait for phone ACK; only negotiated legacy delivery may commit immediately.")
require('case "phone.ackDeletedEpisodes"' in watch_handle and
        "acknowledgeDeletedEpisodes" in watch_handle,
        "The Watch must consume the phone's durable application-level deletion ACK.")
require("selectionIdentifiers" in ack_watch and "status == .removing" in ack_watch and
        "episode.selectionIdentifier" in ack_watch and "removeEpisodes" in ack_watch,
        "ACK processing may remove only the exact still-pending Watch selection.")

incoming = body(PHONE, "- (void)_handleIncomingPayload:")
stage = body(PHONE, "- (NSURL*)_stageIncomingWatchDeletionPayload:")
schedule = body(PHONE, "- (void)_scheduleWatchDeletionInboxProcessing")
commit = body(PHONE, "- (void)_commitStagedWatchDeletionPayload:")
send_ack = body(PHONE, "- (BOOL)_sendWatchDeletionAcknowledgementForPayload:")
require("_isWatchDeletionPayload:" in incoming and
        "_stageIncomingWatchDeletionPayload:" in incoming and
        "_scheduleWatchDeletionInboxProcessing" in incoming,
        "Deletion payloads must be durably staged synchronously before the WCSession delegate returns.")
require("NSPropertyListSerialization" in stage and "NSDataWritingAtomic" in stage and
        "PendingWatchDeletionEvents" in PHONE,
        "The phone deletion inbox must use an atomic property-list file in Application Support.")
require("watchDeletionInboxQueue" in schedule and "dispatch_async" in schedule,
        "Inbox file discovery and reads must stay off the main thread.")
require("saveReturningError" in commit and "rollback" in commit and
        "_sendWatchDeletionAcknowledgementForPayload:" in commit and "removeItemAtURL" in commit,
        "The phone may remove an inbox file only after model save and ACK enqueue; failed saves must roll back and retain it.")
require("_presentWatchDeletionProcessingError" in commit,
        "Inbox apply/save failures must surface one complete actionable message while retaining the retry file.")
require('ICAppleWatchMessageTypeKey: @"phone.ackDeletedEpisodes"' in send_ack and
        "episodeHashes" in send_ack and "selectionIdentifiers" in send_ack,
        "The phone ACK must echo the exact causal deletion identities.")
require("_scheduleWatchDeletionInboxProcessing" in body(PHONE, "- (void)_finishStartingAfterWatchStateRepair") and
        "_scheduleWatchDeletionInboxProcessing" in body(PHONE, "activationDidCompleteWithState:"),
        "A phone restart after state repair or connectivity reactivation must resume staged deletion processing.")

print("Watch deletion ACK durability regression checks passed")
