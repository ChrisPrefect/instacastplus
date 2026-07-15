#!/usr/bin/env python3
"""Pins first-participation episode merge clocks and their CloudKit ACK boundary."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature):
    require(signature in source, f"{signature} is missing.")
    start = source.find(signature)
    brace = source.find("{", start)
    require(brace != -1, f"{signature} has no body.")
    depth = 0
    for index in range(brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


plan = method_body(MANAGER, "nonisolated static func buildInitialUploadPlan")
episode_writes = plan.split("for objectHash in episodes.values {", 1)[1].split(
    "for feedURL in subscriptions.values {", 1
)[0]
subscription_writes = plan.split("for feedURL in subscriptions.values {", 1)[1]

# A never-synced second device must enter the EpisodeState worker with no local clock.
# Otherwise the freshly-created backfill clock is newer than the real cloud value and the
# LWW guard re-uploads the local defaults without ever reaching the first-merge branch.
initial_episode_clock_is_nil = "localModifiedAt: nil" in episode_writes
local = {"played": False, "starred": False, "position": 0}
cloud = {"played": True, "starred": True, "position": 731}
if initial_episode_clock_is_nil:
    reconciled = {
        "played": local["played"] or cloud["played"],
        "starred": local["starred"] or cloud["starred"],
        "position": max(local["position"], cloud["position"]),
    }
    reuploads_local_default = False
else:
    reconciled = local
    reuploads_local_default = True

require(
    reconciled == cloud and not reuploads_local_default,
    "A first episode backfill must not invent a local clock before it has reconciled an existing cloud record.",
)

apply_remote = method_body(REMOTE, "func applyPendingEpisodeStateBatchInBackground")
require("metadata?.localModifiedAt == nil && activeOutbox == nil" in apply_remote
        and "episode.consumed && !played" in apply_remote
        and "episode.position > position" in apply_remote
        and "episode.starred && !starred" in apply_remote,
        "First-participation episode reconciliation must keep the documented content merge.")

# An empty-cloud initial upload needs a durable clock too, but only after CloudKit confirms
# the save. Persisting the exact acknowledged updatedAt prevents every later materialization
# from inventing another date and avoids a re-upload loop after relaunch.
ack_selection = method_body(MANAGER, "func initialEpisodeRecordsAwaitingAcknowledgedClock")
for required in [
    "pendingInitialUploadBatches",
    "episodeRecordNames",
    "$0.recordType == RecordKind.episodeState",
    "pendingRecordNames.contains($0.recordID.recordName)",
]:
    require(required in ack_selection, f"Initial episode ACK selection is missing: {required}")

ack_clock = method_body(MANAGER, "func persistAcknowledgedInitialEpisodeClocks")
for required in [
    "record[\"updatedAt\"] as? Date",
    "replaceExisting: false",
]:
    require(required in ack_clock, f"Confirmed initial episode clocks are missing: {required}")

sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
select_clock = sent.find("initialEpisodeRecordsAwaitingAcknowledgedClock(")
persist_clock = sent.find("try await persistAcknowledgedInitialEpisodeClocks(")
ack_outbox = sent.find("acknowledgeLocalOutboxOperationsInBackground(")
advance_cursor = sent.find("recordInitialUploadRecordsSaved(event.savedRecords.map")
require(select_clock != -1 and persist_clock != -1 and ack_outbox != -1 and advance_cursor != -1
        and select_clock < persist_clock < ack_outbox < advance_cursor,
        "CloudKit's initial episode clock must be durable before local ACK and cursor advancement.")
clock_failure = sent[persist_clock:ack_outbox]
require("handleLocalPersistenceFailure(error)" in clock_failure and "return" in clock_failure,
        "A failed initial clock commit must not advance the durable backfill cursor.")

# Subscription backfill intentionally keeps its existing LWW clock and payload baseline.
require("localModifiedAt: createdAt" in subscription_writes
        and "localState: true" in subscription_writes
        and "payloadHash: subscriptions.payloadHashes[feedURL]" in subscription_writes,
        "The episode first-merge fix must not change subscription backfill semantics.")

print("iCloud initial episode clock regression checks passed")
