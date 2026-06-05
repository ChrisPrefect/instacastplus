#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker="\n    private func "):
    require(signature in source, f"{signature} is missing.")
    return source.split(signature, 1)[1].split(next_marker, 1)[0]


MANAGER = read("Classes/ICiCloudSyncManager.swift")

require("initialEpisodeBackfillOffsetKey" in MANAGER, "Episode initial backfill needs a persisted page cursor.")
require("initialSubscriptionBackfillOffsetKey" in MANAGER, "Subscription initial backfill needs a persisted page cursor.")
require("initialSettingsBackfillPendingKey" in MANAGER, "Settings initial backfill must be a one-shot flag.")

plan = method_body(MANAGER, "private nonisolated static func buildInitialUploadPlan")
require("episodeObjectHashesForInitialUploadPlan(offset:" in plan, "Initial episode upload planning must use a paged fetch.")
require("subscribedFeedURLsForInitialUploadPlan(offset:" in plan, "Initial subscription upload planning must use a paged fetch.")
require("nextEpisodeBackfillOffset" in plan, "Initial episode planning must return the next page cursor.")
require("nextSubscriptionBackfillOffset" in plan, "Initial subscription planning must return the next page cursor.")

episode_fetch = method_body(MANAGER, "private nonisolated static func episodeObjectHashesForInitialUploadPlan")
subscription_fetch = method_body(MANAGER, "private nonisolated static func subscribedFeedURLsForInitialUploadPlan")
for name, body in [("episode", episode_fetch), ("subscription", subscription_fetch)]:
    require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in body, f"Initial {name} backfill must fetch one bounded page plus a has-more row.")
    require("fetchOffset = offset" in body, f"Initial {name} backfill must use the persisted page cursor.")
    require("while true" not in body, f"Initial {name} backfill must not loop through every row in one task.")
    require("append(contentsOf:" not in body, f"Initial {name} backfill must not accumulate pages into one array.")

apply_plan = method_body(MANAGER, "private func applyInitialUploadPlan")
require("updateInitialUploadCursors(from: plan)" in apply_plan, "Applying an initial page must persist the next cursor.")
require("scheduleLowPrioritySync()" in apply_plan, "Each initial page must be sent before the next page is queued.")
require("scheduleCurrentEnabledDataForUpload()" in apply_plan, "Empty pages with remaining work may schedule the next bounded page.")

mark_completed = method_body(MANAGER, "private func markSyncCompleted")
require("if hasInitialUploadBackfillWork" in mark_completed and "scheduleCurrentEnabledDataForUpload()" in mark_completed, "The next initial page may only be scheduled after current pending changes finish.")

remember = method_body(MANAGER, "private func rememberServerRecord")
forget = method_body(MANAGER, "private func forgetServerRecord")
require("writeKnownRecordSystemFields" in remember, "Known CKRecord system fields must be written per record.")
require("removeKnownRecordSystemFields" in forget, "Known CKRecord system fields must be removed per record.")
require("setSyncMetadata(records, forKey: Self.knownRecordsKey)" not in remember + forget, "Known records must not be rewritten as one large dictionary.")

