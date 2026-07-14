#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WATCH = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
PHONE = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
HEADER = (ROOT / "Classes" / "Model" / "AppleWatchEpisodeState.h").read_text()
MODEL = (ROOT / "Classes" / "Model" / "AppleWatchEpisodeState.m").read_text()
SCHEMA = (ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model6.xcdatamodel" / "contents").read_text()


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


send = body(WATCH, "func send(type:")
next_revision = body(WATCH, "private func nextWatchEventRevision()")
require('message["watchEventRevision"]' in send and "nextWatchEventRevision" in send,
        "Every Watch-to-phone delivery channel must carry one event revision.")
require("previousRevision + 1" in next_revision and "timeIntervalSince1970" in next_revision,
        "Watch event revisions must remain monotonic across rapid events and restarts.")

handle = body(WATCH, "private func handle(payload:")
replace_block = handle.split('case "manifest.replace"', 1)[1].split("case ", 1)[0]
replace_apply = body(WATCH, "private func applyManifestReplace(")
require("applyManifestReplace" in replace_block and "advanceWatchEventRevisionFloor" in replace_apply,
        "manifest.replace must advance the outgoing event floor before applying side effects.")
for case_name in ['case "manifest.upsertEpisodes"', 'case "manifest.removeEpisodes"']:
    case_block = handle.split(case_name, 1)[1].split("case ", 1)[0]
    require("advanceWatchEventRevisionFloor" in case_block,
            f"{case_name} must advance the outgoing event floor before applying side effects.")

require("watchLastEventRevision" in HEADER and "@dynamic watchLastEventRevision" in MODEL,
        "The phone must persist the last applied Watch event revision per episode.")
require('name="watchLastEventRevision"' in SCHEMA and 'attributeType="Integer 64"' in SCHEMA,
        "Model6 must persist the per-episode Watch event revision.")

gate = body(PHONE, "- (int64_t)_acceptedWatchEventRevisionForPayload:")
require('payload[@"watchEventRevision"]' in gate
        and "state.watchLastEventRevision" in gate
        and "_liveDownloadProgressForState:" in gate
        and "transientEventRevision" in gate
        and "ICAppleWatchReceivedManifestAcknowledgementRevisionKey" not in gate
        and "eventRevision <= MAX(state.watchLastEventRevision, transientEventRevision)" in gate,
        "A manifest ACK must not discard delayed but still authoritative per-episode Watch events.")

durable_gate = body(PHONE, "- (BOOL)_shouldApplyWatchEventPayload:")
require("_acceptedWatchEventRevisionForPayload:" in durable_gate
        and "advanceDurableState:YES" in durable_gate,
        "Durable queued/terminal events must use the shared durable/transient revision floor.")

update = body(PHONE, "- (AppleWatchEpisodeState*)_updateStateForPayload:")
require("_shouldApplyWatchEventPayload" in update,
        "Queued/progress/downloaded/failed events must all pass through the ordering gate.")

download_evicted_route = PHONE.split('@"watch.downloadEvicted"', 1)[1].split("else if", 1)[0]
deleted_helper = body(PHONE, "- (BOOL)_applyWatchDeletedPayload:")
incoming = body(PHONE, "- (void)_handleIncomingPayload:")
commit_deleted = body(PHONE, "- (void)_commitStagedWatchDeletionPayload:")
require("_stageIncomingWatchDeletionPayload" in incoming and
        "_applyWatchDeletedPayload" in commit_deleted and
        "_shouldApplyWatchEventPayload" in deleted_helper,
        "watch.deleted must use the shared per-episode ordering gate.")
require("_shouldApplyWatchEventPayload" in download_evicted_route,
        "watch.downloadEvicted must not apply after a newer manifest or Watch event.")

deleted = deleted_helper
send_to_watch = body(PHONE, "- (void)sendEpisodeToWatch:")
require('payload[@"selectionDate"]' in deleted and "_stringFromDate:state.watchAddedDate" in deleted and
        "state.removingFromWatch" in send_to_watch and "_nextWatchSelectionDateAfterDate:" in send_to_watch,
        "A delayed delete from an older selection must not remove an episode that was selected again.")
require("BOOL matchesCurrentSelection = state.removingFromWatch" in deleted and
        "!matchesCurrentSelection && selectionIdentifier.length == 0" in deleted,
        "A delete without selection identity must only confirm a removal already requested by the phone.")

ack_route = PHONE.split('@"watch.ackManifest"', 1)[1].split("else if", 1)[0]
require("_applyManifestAcknowledgementForRevision:" in ack_route
        and "_applyManifestAcknowledgementForEpisodeHashes:" in ack_route,
        "Manifest acknowledgements must use the revision-bound path with legacy compatibility.")
ack = body(PHONE, "- (void)_applyManifestAcknowledgementBatchForEpisodeHashes:")
require("ICAppleWatchStatusSelected" in ack and "ICAppleWatchStatusManifestSent" in ack,
        "Manifest acknowledgements may only advance pre-ack states; they must not supersede download events.")

phone_handler = body(PHONE, "- (void)_handleIncomingPayloadOnMainThread:")
failed = phone_handler.split('@"watch.downloadFailed"', 1)[1].split("else if", 1)[0]
downloaded = phone_handler.split('@"watch.downloaded"', 1)[1].split("else if", 1)[0]
require("if (state)" in failed and "if (state)" in downloaded,
        "Rejected stale terminal events must not clear current progress or terminal metadata.")

print("Watch event ordering regression checks passed")
