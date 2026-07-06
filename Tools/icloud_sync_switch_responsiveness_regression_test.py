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


def source_between(source, start, end):
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


MANAGER = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])
SETTINGS = read("Classes/ICiCloudSyncSettingsViewController.m")

sync_options_changed = method_body(MANAGER, "@objc func syncOptionsChanged()")
enable_branch = source_between(sync_options_changed, "if anySyncEnabled {", "} else if syncEngine != nil {")
require("initializeSyncEngineIfNeeded()" not in enable_branch, "The switch tap must not synchronously create CKSyncEngine.")
require("queueDeviceRecord()" not in enable_branch, "The switch tap must not synchronously mutate CKSyncEngine pending changes.")
require("scheduleCurrentEnabledDataForUpload()" in enable_branch, "The switch tap must schedule initial queueing asynchronously.")

initial_queue_schedule = method_body(MANAGER, "func scheduleCurrentEnabledDataForUpload")
require("Task.detached" in initial_queue_schedule, "Initial upload queueing must start from a detached background task.")
require("await self.queueCurrentEnabledDataForUpload()" not in initial_queue_schedule, "Detached queueing must not immediately hop back to the MainActor.")
require("buildInitialUploadPlan" in initial_queue_schedule, "Detached queueing must build the initial upload plan off the UI queue.")
require("applyInitialUploadPlan" in initial_queue_schedule, "Only the final small CKSyncEngine state mutations may return to the manager.")

engine_init = method_body(MANAGER, "func initializeSyncEngineIfNeeded")
require("configuration.automaticallySync = false" in engine_init, "CKSyncEngine must not start immediate high-priority automatic sends from switch taps.")

low_priority_sync = method_body(MANAGER, "func scheduleLowPrioritySync")
require("lowPrioritySyncTask" in MANAGER, "Automatic iCloud sends need a coalesced low-priority task.")
require("Task.detached(priority: .background)" in low_priority_sync, "Automatic iCloud sends must run from a detached background scheduler.")
require("await self.performLowPrioritySync()" in low_priority_sync, "Automatic iCloud sends must leave any CKSyncEngine delegate callback task before calling sendChanges.")
require("MainActor.run" not in low_priority_sync, "Low-priority automatic sync must not hand CKSyncEngine across actors via MainActor.run.")

perform_low_priority_sync = method_body(MANAGER, "func performLowPrioritySync")
require("try await syncEngine.sendChanges()" in perform_low_priority_sync, "Low-priority automatic sync must still send queued changes.")
require("try await syncEngine.fetchChanges()" in perform_low_priority_sync, "Low-priority automatic sync must still fetch remote changes.")

plan_builder = method_body(MANAGER, "nonisolated static func buildInitialUploadPlan")
require("episodeObjectHashesForInitialUploadPlan(offset:" in plan_builder, "Initial upload planning must page episode identifiers off the UI path.")
require("subscribedFeedURLsForInitialUploadPlan(offset:" in plan_builder, "Initial upload planning must page feed identifiers off the UI path.")
require("MainActor.run" not in plan_builder and "await self." not in plan_builder, "Initial upload planning must not depend on the UI actor.")

episode_fetch = method_body(MANAGER, "nonisolated static func episodeObjectHashesForInitialUploadPlan")
subscription_fetch = method_body(MANAGER, "nonisolated static func subscribedFeedURLsForInitialUploadPlan")
require("DatabaseManager.shared()" in episode_fetch and "await context.perform" in episode_fetch, "Initial episode planning must fetch identifiers on a Core Data background context.")
require("DatabaseManager.shared()" in subscription_fetch and "await context.perform" in subscription_fetch, "Initial subscription planning must fetch identifiers on a Core Data background context.")
require("fetchBatchSize" not in episode_fetch, "DictionaryResultType episode planning fetches must not set fetchBatchSize because Core Data returns unbatched dictionary rows and warns on the switch path.")
require("fetchBatchSize" not in subscription_fetch, "DictionaryResultType subscription planning fetches must not set fetchBatchSize because Core Data returns unbatched dictionary rows and warns on the switch path.")
require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in episode_fetch, "Initial episode planning must fetch at most one bounded page plus a has-more row.")
require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in subscription_fetch, "Initial subscription planning must fetch at most one bounded page plus a has-more row.")
require("while true" not in episode_fetch and "while true" not in subscription_fetch, "Initial planning must not loop through the entire library in one task.")

plan_apply = method_body(MANAGER, "func applyInitialUploadPlan")
require("var pendingKeys = pendingRecordZoneChangeKeys()" in plan_apply, "Initial queue application must reuse pending-change keys instead of rebuilding them per chunk.")
require("pendingKeys: &pendingKeys" in plan_apply, "Initial queue application must pass the reusable pending key set through chunked additions.")
require("await Task.yield()" in plan_apply, "Initial queue application must yield between CKSyncEngine state chunks.")
require("queueDeviceRecord(stampLastSyncDate: true)" in plan_apply, "Initial user-data queueing must still publish a real Last Sync device record.")
require("scheduleLowPrioritySync()" in plan_apply, "Initial queue application must schedule low-priority sync only after queued state is prepared.")
require("recordInitialUploadBatchQueued(plan)" in plan_apply, "Initial queue application must register the bounded batch (cursor advances after confirmed upload) instead of queueing the whole library.")

add_pending_saves = method_body(MANAGER, "func addPendingSaves(_ recordIDs: [CKRecord.ID], pendingKeys: inout Set<String>")
require("let pendingKeys = Set(syncEngine?.state.pendingRecordZoneChanges.map" not in add_pending_saves, "Reusable pending-key additions must not rescan all pending CKSyncEngine changes.")
require("pendingKeys.insert(key)" in add_pending_saves, "Reusable pending-key additions must update the key set as chunks are added.")

sync_logger = method_body(MANAGER, "func logSyncEvent")
require("syncEngine?.state" not in sync_logger, "iCloud logging must not read CKSyncEngine.state as a side effect because state access is queue-sensitive.")
require('details["actor"] = "MainActor"' in sync_logger, "iCloud logging must identify that manager logs were emitted from the MainActor.")

toggle_body = method_body(SETTINGS, "- (void)toggleSyncOption:")
require("[self.tableView reloadData]" not in toggle_body, "Tapping an iCloud Sync switch must not rebuild the whole table view.")
require("reloadStatusAndDevicesSections" in toggle_body, "Tapping an iCloud Sync switch may only refresh non-switch sections.")
