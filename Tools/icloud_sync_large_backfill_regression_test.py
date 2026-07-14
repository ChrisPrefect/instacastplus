#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker=None):
    # Brace-matching extraction: the old "cut at the next member" heuristic broke when
    # the manager was split into files and member access became internal.
    require(signature in source, f"{signature} is missing.")
    start = source.find(signature)
    brace = source.find("{", start)
    require(brace != -1, f"{signature} has no body.")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


MANAGER = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])

require("initialEpisodeBackfillOffsetKey" in MANAGER, "Episode initial backfill needs a persisted page cursor.")
require("initialSubscriptionBackfillOffsetKey" in MANAGER, "Subscription initial backfill needs a persisted page cursor.")
require("initialEpisodeBackfillCursorKey" in MANAGER, "Episode initial backfill needs a stable identifier cursor.")
require("initialSubscriptionBackfillCursorKey" in MANAGER, "Subscription initial backfill needs a stable identifier cursor.")
require("initialSettingsBackfillPendingKey" in MANAGER, "Settings initial backfill must be a one-shot flag.")
require(
    "maximumRecordZoneChangesPerBatch = 250" in MANAGER,
    "CloudKit send batches must respect the documented 250-operation request limit.",
)

plan = method_body(MANAGER, "nonisolated static func buildInitialUploadPlan")
require("episodeObjectHashesForInitialUploadPlan(cursor:" in plan, "Initial episode upload planning must use a paged fetch.")
require("subscribedFeedURLsForInitialUploadPlan(cursor:" in plan, "Initial subscription upload planning must use a paged fetch.")
require(
    "while episodeBackfillOffset != nil || subscriptionBackfillOffset != nil" not in plan
    and "pages.append(" not in plan
    and "pages: [page]" in plan,
    "One initial upload plan must contain only the next bounded page so the first CloudKit request can start immediately.",
)
require("append(contentsOf:" not in plan,
        "Initial upload planning must not duplicate the growing library into whole-plan arrays.")
require("var syncItemMetadataWrites: [ICCloudSyncItemMetadataWrite] = []" in plan
        and "reserveCapacity(episodes.values.count + subscriptions.values.count)" in plan
        and "syncItemMetadataWrites: syncItemMetadataWrites" in plan,
        "Each page must carry only bounded indexed metadata writes, not copies of prior whole-library dictionaries.")

episode_fetch = method_body(MANAGER, "nonisolated static func episodeObjectHashesForInitialUploadPlan")
subscription_fetch = method_body(MANAGER, "nonisolated static func subscribedFeedURLsForInitialUploadPlan")
for name, body in [("episode", episode_fetch), ("subscription", subscription_fetch)]:
    require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in body, f"Initial {name} backfill must fetch one bounded page plus a has-more row.")
    require("fetchOffset" not in body and "sortDescriptors" in body and "> %@" in body,
            f"Initial {name} backfill must use a stable keyset cursor, never a mutable row offset.")
    require("while true" not in body, f"Initial {name} backfill must not loop through every row in one task.")
    require("append(contentsOf:" not in body, f"Initial {name} backfill must not accumulate pages into one array.")

apply_plan = method_body(MANAGER, "func applyInitialUploadPlan")
metadata_upsert = apply_plan.find("upsertSyncItemMetadata")
engine_init = apply_plan.find("initializeSyncEngineIfNeeded()", metadata_upsert)
require(
    metadata_upsert != -1 and engine_init != -1 and metadata_upsert < engine_init,
    "A page must durably insert its indexed metadata before CKSyncEngine can materialize or send its records.",
)
require(
    apply_plan.find("initialUploadPlanIsCurrent", metadata_upsert) < engine_init,
    "Metadata persistence may suspend, so the account/generation/page cursor must be revalidated before queuing CloudKit work.",
)
require(
    "recordInitialUploadBatchesQueued(plan.pages)" in apply_plan,
    "Applying a complete plan must register every page whose CloudKit ACK advances a cursor.",
)
require(
    apply_plan.count("scheduleLowPrioritySync()") == 2,
    "The empty-library and prepared-plan branches may each start one send cycle; no page may start its own cycle.",
)
require(
    "scheduleCurrentEnabledDataForUpload()" not in apply_plan,
    "Applying a page must not defer the next page to another network cycle.",
)
require("scheduleSyncAfterQueue" in apply_plan,
        "A continuation page must be queueable inside the active CKSyncEngine send without starting another task.")

queue_next = method_body(MANAGER, "func queueNextInitialUploadPageDuringActiveSend")
require("pendingInitialUploadBatches.isEmpty" in queue_next
        and "isPreparingInitialUploadPage" in queue_next
        and "cloudAccountGeneration" in queue_next
        and "buildInitialUploadPlan(from:" in queue_next
        and "scheduleSyncAfterQueue: false" in queue_next
        and "expectedCloudAccountGeneration: generation" in queue_next,
        "Each acknowledged page must lazily queue exactly one account-scoped successor inside the active send operation.")

sent_records = method_body(MANAGER, "func handleSentRecordZoneChanges")
require("await queueNextInitialUploadPageDuringActiveSend()" in sent_records,
        "A successful CloudKit batch must replenish the bounded initial-upload queue before the send operation drains.")

send_changes = method_body(MANAGER, "func sendChangesAndApplyCallbackOutcomes")
require("await queueNextInitialUploadPageDuringActiveSend()" in send_changes,
        "A page containing only stale local rows must also advance to the next page after callback outcomes are applied.")
records_saved = method_body(MANAGER, "func recordInitialUploadRecordsSaved")
records_resolved = method_body(MANAGER, "func recordInitialUploadRecordsResolved")
record_names_resolved = method_body(MANAGER, "func recordInitialUploadRecordNamesResolved")
require(
    "recordInitialUploadRecordsResolved" in records_saved
    and "recordInitialUploadRecordNamesResolved" in records_resolved
    and "pendingInitialUploadBatches.indices" in record_names_resolved
    and "advanceConfirmedInitialUploadBatches()" in record_names_resolved,
    "CloudKit ACKs must resolve records across all prepared page checkpoints.",
)
advance = method_body(MANAGER, "func advanceConfirmedInitialUploadBatches")
require(
    "pendingInitialUploadBatches.first" in advance
    and "updateInitialEpisodeBackfillCursor(" in advance
    and "updateInitialSubscriptionBackfillCursor(" in advance,
    "Stable cursors may advance only through consecutively confirmed page checkpoints.",
)

engine_batch = method_body(MANAGER, "nonisolated func nextRecordZoneChangeBatch")
require(
    "recordInitialUploadOutcome" in engine_batch,
    "Records that disappear locally while a prepared backfill is sending must be handed off to resolve their checkpoint instead of deadlocking completion.",
)

materialize = method_body(MANAGER, "nonisolated static func materializeRecordsForSyncEngineCallback")
persist_system_fields = method_body(MANAGER, "nonisolated static func persistKnownRecordSystemFields")
require(materialize.count("knownRecordSystemFieldsForSyncEngineCallback(") == 1,
        "Each CloudKit page must load known system fields with one indexed lookup.")
require("maximumRecordZoneChangesPerBatch" in persist_system_fields
        and "context.save()" in persist_system_fields,
        "Known CKRecord system fields must commit in bounded indexed transactions.")
require("setSyncMetadata(records, forKey: Self.knownRecordsKey)" not in persist_system_fields,
        "Known records must not be rewritten as one large dictionary.")
