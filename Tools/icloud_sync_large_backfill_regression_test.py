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
require("initialSettingsBackfillPendingKey" in MANAGER, "Settings initial backfill must be a one-shot flag.")

plan = method_body(MANAGER, "nonisolated static func buildInitialUploadPlan")
require("episodeObjectHashesForInitialUploadPlan(offset:" in plan, "Initial episode upload planning must use a paged fetch.")
require("subscribedFeedURLsForInitialUploadPlan(offset:" in plan, "Initial subscription upload planning must use a paged fetch.")
require("nextEpisodeBackfillOffset" in plan, "Initial episode planning must return the next page cursor.")
require("nextSubscriptionBackfillOffset" in plan, "Initial subscription planning must return the next page cursor.")

episode_fetch = method_body(MANAGER, "nonisolated static func episodeObjectHashesForInitialUploadPlan")
subscription_fetch = method_body(MANAGER, "nonisolated static func subscribedFeedURLsForInitialUploadPlan")
for name, body in [("episode", episode_fetch), ("subscription", subscription_fetch)]:
    require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in body, f"Initial {name} backfill must fetch one bounded page plus a has-more row.")
    require("fetchOffset = offset" in body, f"Initial {name} backfill must use the persisted page cursor.")
    require("while true" not in body, f"Initial {name} backfill must not loop through every row in one task.")
    require("append(contentsOf:" not in body, f"Initial {name} backfill must not accumulate pages into one array.")

apply_plan = method_body(MANAGER, "func applyInitialUploadPlan")
require("recordInitialUploadBatchQueued(plan)" in apply_plan, "Applying an initial page must register the batch whose confirmed upload advances the cursor.")
records_saved = method_body(MANAGER, "func recordInitialUploadRecordsSaved")
require("updateInitialEpisodeBackfillCursor(nextOffset:" in records_saved and "updateInitialSubscriptionBackfillCursor(nextOffset:" in records_saved, "The page cursor may only advance after CloudKit confirmed the saves.")
require("scheduleLowPrioritySync()" in apply_plan, "Each initial page must be sent before the next page is queued.")
require("scheduleCurrentEnabledDataForUpload()" in apply_plan, "Empty pages with remaining work may schedule the next bounded page.")

mark_completed = method_body(MANAGER, "func markSyncCompleted")
require("if hasInitialUploadBackfillWork" in mark_completed and "scheduleCurrentEnabledDataForUpload()" in mark_completed, "The next initial page may only be scheduled after current pending changes finish.")

remember = method_body(MANAGER, "func rememberServerRecord")
forget = method_body(MANAGER, "func forgetServerRecord")
require("writeKnownRecordSystemFields" in remember, "Known CKRecord system fields must be written per record.")
require("removeKnownRecordSystemFields" in forget, "Known CKRecord system fields must be removed per record.")
require("setSyncMetadata(records, forKey: Self.knownRecordsKey)" not in remember + forget, "Known records must not be rewritten as one large dictionary.")

