#!/usr/bin/env python3
"""Pins kill-safe ordering and interleaving rules for streamed iCloud backfills."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()


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


# A scheduled plan remains cancellable through every await in applyInitialUploadPlan.
# The generation model also pins the old-task/new-task race: an old task's cleanup must
# never clear the replacement task's handle.
generation = 1
old_generation = generation
generation += 1  # account reset/cancel
new_generation = generation
old_cleanup_clears_handle = old_generation == generation
require(not old_cleanup_clears_handle and new_generation == generation,
        "The regression model must distinguish an orphaned plan from its replacement.")

require("initialQueueTaskGeneration" in MANAGER,
        "Initial queue tasks need an identity token that survives actor reentrancy.")

schedule = method_body(MANAGER, "func scheduleCurrentEnabledDataForUpload")
require("cloudAccountGeneration" in schedule
        and "accountUserRecordNameKey" in schedule
        and "initialQueueTaskGeneration" in schedule,
        "A scheduled plan must capture its queue identity and verified cloud account scope.")
require("expectedCloudAccountGeneration:" in schedule
        and "expectedAccountRecordName:" in schedule
        and "queueTaskGeneration:" in schedule,
        "The captured account/task scope must travel with the asynchronously built plan.")

apply_plan = method_body(MANAGER, "func applyInitialUploadPlan")
require("if scheduleSyncAfterQueue {\n            initialQueueTask = nil" not in apply_plan,
        "The only task handle must not be cleared on entry, before the plan's suspension points.")
require("defer" in apply_plan
        and "queueTaskGeneration == initialQueueTaskGeneration" in apply_plan,
        "Only the still-current task may clear the retained initial queue handle.")
require(apply_plan.count("initialUploadPlanIsCurrent(") >= 3,
        "The plan must revalidate account, task and cursor scope after each queueing await.")

cancel = method_body(MANAGER, "func cancelInitialQueueTask")
require("initialQueueTaskGeneration &+= 1" in cancel,
        "Cancellation must invalidate an applying task even if a replacement is scheduled.")

current = method_body(MANAGER, "func initialUploadPlanIsCurrent")
for required in [
    "expectedCloudAccountGeneration == cloudAccountGeneration",
    "isICloudAccountIdentityVerified",
    "expectedAccountRecordName",
    "currentSnapshot.episodeBackfillOffset == snapshot.episodeBackfillOffset",
    "currentSnapshot.subscriptionBackfillCursor == snapshot.subscriptionBackfillCursor",
]:
    require(required in current, f"Initial plan scope is missing: {required}")

# Initial backfill/migration only fill missing fields. If a user edit commits while that
# background context is between fetch and save, the newer store row must win the merge.
metadata_upsert = method_body(METADATA, "nonisolated static func upsertSyncItemMetadata(\n        accountRecordName")
require("mergeByPropertyStoreTrumpMergePolicyType" in metadata_upsert
        and "replaceExisting" in metadata_upsert,
        "A concurrent user edit must beat fill-only backfill/migration metadata at the save boundary.")
metadata_bind = method_body(METADATA, "nonisolated static func bindSyncItemMetadata")
require("mergeByPropertyStoreTrumpMergePolicyType" in metadata_bind,
        "A user edit captured directly into the verified account must beat an older pending-scope row during binding.")


# A conflict is not a CloudKit ACK. Keeping the previous durable cursor is the recovery
# mechanism if the process dies before CKSyncEngine serializes the in-memory retry.
cursor = "feed-before-conflict"
retry_is_durable = False
if not retry_is_durable:
    cursor_after_conflict = cursor
require(cursor_after_conflict == cursor,
        "The regression model must keep the cursor behind a non-durable retry.")

failed_save = method_body(REMOTE, "func handleFailedRecordSave")
subscription_conflict = failed_save.split("if isSubscriptionConflictRecord {", 1)[1].split("}", 1)[0]
require("retryRecords.append(.saveRecord(recordID))" in subscription_conflict,
        "A subscription conflict must retain the local save for the post-fetch retry.")
require("recordInitialUploadRecordsSaved" not in subscription_conflict,
        "A serverRecordChanged conflict must not advance the initial cursor before retry success.")


# An unresolved send owns its retry through the backoff scheduler. The low-priority task
# must not create a second immediate task merely because the failed record remains pending.
has_unresolved_failure = True
has_pending_changes = True
immediate_reschedule = (not has_unresolved_failure) and has_pending_changes
require(not immediate_reschedule,
        "The regression model must leave failed pending work to the backoff scheduler.")

low_priority = method_body(MANAGER, "func performLowPrioritySync")
require("if anySyncEnabled, !hasUnresolvedSyncFailures, hasPendingSyncChanges" in low_priority,
        "An unresolved send failure must not bypass its retry timer with an immediate low-priority task.")


# A subscription page is the active save plus its inverse tombstone delete. ACKing only
# the save must leave the page blocked until the delete succeeds or is benignly absent.
page_records = {"subscription_feed", "subscriptionTombstone_feed"}
page_records -= {"subscription_feed"}
require(page_records == {"subscriptionTombstone_feed"},
        "The regression model must keep the page open after only the active save ACK.")

checkpoint = method_body(MANAGER, "func recordInitialUploadBatchesQueued")
require("subscriptionTombstoneRecordName(forFeedURL:" in checkpoint,
        "Initial subscription checkpoints must include each inverse tombstone delete.")

sent_changes = method_body(REMOTE, "func handleSentRecordZoneChanges")
require("resolvedInitialUploadDeleteRecordIDs" in sent_changes
        and "event.deletedRecordIDs" in sent_changes
        and "recordInitialUploadRecordsResolved(resolvedInitialUploadDeleteRecordIDs)" in sent_changes,
        "Successful and benignly absent deletes must resolve their initial-page checkpoint entries.")

print("iCloud streamed-backfill interleaving regression checks passed")
