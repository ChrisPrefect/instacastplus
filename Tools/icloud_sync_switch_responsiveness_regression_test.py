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


def source_between(source, start, end):
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


MANAGER = read("Classes/ICiCloudSyncManager.swift")
SETTINGS = read("Classes/ICiCloudSyncSettingsViewController.m")

sync_options_changed = method_body(MANAGER, "@objc func syncOptionsChanged()")
enable_branch = source_between(sync_options_changed, "if anySyncEnabled {", "} else if syncEngine != nil {")
require("initializeSyncEngineIfNeeded()" not in enable_branch, "The switch tap must not synchronously create CKSyncEngine.")
require("queueDeviceRecord()" not in enable_branch, "The switch tap must not synchronously mutate CKSyncEngine pending changes.")
require("scheduleCurrentEnabledDataForUpload()" in enable_branch, "The switch tap must schedule initial queueing asynchronously.")

initial_queue_schedule = method_body(MANAGER, "private func scheduleCurrentEnabledDataForUpload")
require("Task.detached" in initial_queue_schedule, "Initial upload queueing must start from a detached background task.")
require("await self.queueCurrentEnabledDataForUpload()" not in initial_queue_schedule, "Detached queueing must not immediately hop back to the MainActor.")
require("buildInitialUploadPlan" in initial_queue_schedule, "Detached queueing must build the initial upload plan off the UI queue.")
require("applyInitialUploadPlan" in initial_queue_schedule, "Only the final small CKSyncEngine state mutations may return to the manager.")

engine_init = method_body(MANAGER, "private func initializeSyncEngineIfNeeded")
require("configuration.automaticallySync = false" in engine_init, "CKSyncEngine must not start immediate high-priority automatic sends from switch taps.")

low_priority_sync = method_body(MANAGER, "private func scheduleLowPrioritySync")
require("lowPrioritySyncTask" in MANAGER, "Automatic iCloud sends need a coalesced low-priority task.")
require("Task(priority: .background)" in low_priority_sync, "Automatic iCloud sends must run at background priority.")
require("Task.detached" not in low_priority_sync, "Automatic iCloud sends must not take CKSyncEngine off the manager actor with Task.detached.")
require("try await syncEngine.sendChanges()" in low_priority_sync, "Low-priority automatic sync must still send queued changes.")
require("try await syncEngine.fetchChanges()" in low_priority_sync, "Low-priority automatic sync must still fetch remote changes.")
require("MainActor.run" not in low_priority_sync, "Low-priority automatic sync must not hand CKSyncEngine across actors via MainActor.run.")

plan_builder = method_body(MANAGER, "private nonisolated static func buildInitialUploadPlan")
require("episodeObjectHashesForInitialUploadPlan(offset:" in plan_builder, "Initial upload planning must page episode identifiers off the UI path.")
require("subscribedFeedURLsForInitialUploadPlan(offset:" in plan_builder, "Initial upload planning must page feed identifiers off the UI path.")
require("MainActor.run" not in plan_builder and "await self." not in plan_builder, "Initial upload planning must not depend on the UI actor.")

episode_fetch = method_body(MANAGER, "private nonisolated static func episodeObjectHashesForInitialUploadPlan")
subscription_fetch = method_body(MANAGER, "private nonisolated static func subscribedFeedURLsForInitialUploadPlan")
require("DatabaseManager.shared()" in episode_fetch and "await context.perform" in episode_fetch, "Initial episode planning must fetch identifiers on a Core Data background context.")
require("DatabaseManager.shared()" in subscription_fetch and "await context.perform" in subscription_fetch, "Initial subscription planning must fetch identifiers on a Core Data background context.")
require("fetchBatchSize" not in episode_fetch, "DictionaryResultType episode planning fetches must not set fetchBatchSize because Core Data returns unbatched dictionary rows and warns on the switch path.")
require("fetchBatchSize" not in subscription_fetch, "DictionaryResultType subscription planning fetches must not set fetchBatchSize because Core Data returns unbatched dictionary rows and warns on the switch path.")
require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in episode_fetch, "Initial episode planning must fetch at most one bounded page plus a has-more row.")
require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in subscription_fetch, "Initial subscription planning must fetch at most one bounded page plus a has-more row.")
require("while true" not in episode_fetch and "while true" not in subscription_fetch, "Initial planning must not loop through the entire library in one task.")

plan_apply = method_body(MANAGER, "private func applyInitialUploadPlan")
require("var pendingKeys = pendingRecordZoneChangeKeys()" in plan_apply, "Initial queue application must reuse pending-change keys instead of rebuilding them per chunk.")
require("pendingKeys: &pendingKeys" in plan_apply, "Initial queue application must pass the reusable pending key set through chunked additions.")
require("await Task.yield()" in plan_apply, "Initial queue application must yield between CKSyncEngine state chunks.")
require("queueDeviceRecord(stampLastSyncDate: true)" in plan_apply, "Initial user-data queueing must still publish a real Last Sync device record.")
require("scheduleLowPrioritySync()" in plan_apply, "Initial queue application must schedule low-priority sync only after queued state is prepared.")
require("updateInitialUploadCursors(from: plan)" in plan_apply, "Initial queue application must advance page cursors instead of queueing the whole library.")

add_pending_saves = method_body(MANAGER, "private func addPendingSaves(_ recordIDs: [CKRecord.ID], pendingKeys: inout Set<String>")
require("let pendingKeys = Set(syncEngine?.state.pendingRecordZoneChanges.map" not in add_pending_saves, "Reusable pending-key additions must not rescan all pending CKSyncEngine changes.")
require("pendingKeys.insert(key)" in add_pending_saves, "Reusable pending-key additions must update the key set as chunks are added.")

sync_logger = method_body(MANAGER, "private func logSyncEvent")
require("syncEngine?.state" not in sync_logger, "iCloud logging must not read CKSyncEngine.state as a side effect because state access is queue-sensitive.")
require('details["actor"] = "MainActor"' in sync_logger, "iCloud logging must identify that manager logs were emitted from the MainActor.")

toggle_body = method_body(SETTINGS, "- (void)toggleSyncOption:")
require("[self.tableView reloadData]" not in toggle_body, "Tapping an iCloud Sync switch must not rebuild the whole table view.")
require("reloadStatusAndDevicesSections" in toggle_body, "Tapping an iCloud Sync switch may only refresh non-switch sections.")
