#!/usr/bin/env python3
import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def read_plist(path):
    return plistlib.loads((ROOT / path).read_bytes())


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


DEFINES_H = read("Classes/Defines.h")
DEFINES_M = read("Classes/Defines.m")
MANAGER = read("Classes/ICiCloudSyncManager.swift")
SETTINGS = read("Classes/ICiCloudSyncSettingsViewController.m")
OPTIONS = read("Classes/OptionsViewController.m")
APP_DELEGATE = read("Classes/InstacastAppDelegate.m")
EXPORTER = read("Classes/ImportExportSettingsViewController.m")
IMPORTER = read("Classes/InstacastBackupImporter.m")
PROJECT = read("Instacast.xcodeproj/project.pbxproj")
AGENTS = read("AGENTS.md")
EN_STRINGS = read("Resources/en.lproj/Localizable.strings")
DE_STRINGS = read("Resources/de.lproj/Localizable.strings")

DEFAULTS = read_plist("Resources/Defaults.plist")
IPAD_DEFAULTS = read_plist("Resources-iPad/Defaults.plist")
ENTITLEMENTS = read_plist("Instacast.entitlements")
IPAD_INFO = read_plist("Resources-iPad/Instacast HD-Info.plist")

SYNC_KEYS = [
    "ICiCloudSyncEpisodesEnabled",
    "ICiCloudSyncSubscriptionsEnabled",
    "ICiCloudSyncSettingsEnabled",
]
BACKUP_TAGS = ["iCloudSyncEpisodes", "iCloudSyncSubscriptions", "iCloudSyncSettings"]

for key in SYNC_KEYS:
    require(f"extern NSString* {key};" in DEFINES_H, f"{key} is missing from Defines.h.")
    require(f'NSString* {key} = @"{key}";' in DEFINES_M, f"{key} is missing from Defines.m.")
    require(DEFAULTS.get(key) is False, f"{key} must default off in Resources/Defaults.plist.")
    require(IPAD_DEFAULTS.get(key) is False, f"{key} must default off in Resources-iPad/Defaults.plist.")

require(
    ENTITLEMENTS.get("com.apple.developer.icloud-container-identifiers") == ["iCloud.com.iteconomy.instacastplus"]
    and ENTITLEMENTS.get("com.apple.developer.icloud-services") == ["CloudKit"],
    "The app entitlement must enable the InstacastPlus CloudKit container.",
)
require(
    "remote-notification" in IPAD_INFO.get("UIBackgroundModes", []),
    "The iPad target must handle CloudKit remote notifications in the background.",
)
require(
    "UI-Reaktivität hat oberste Priorität" in AGENTS
    and "asynchron im Hintergrund ausgeführt werden" in AGENTS,
    "AGENTS.md must document that UI reactivity has highest priority.",
)

for source_name in ["ICiCloudSyncManager.swift", "ICiCloudSyncSettingsViewController.m"]:
    require(source_name in PROJECT, f"{source_name} must be part of the Instacast target.")
require("CloudKit.framework" in PROJECT, "CloudKit.framework must be linked into the Instacast target.")

require("@available(iOS 17.0, *)" in MANAGER, "iCloud Sync must be compiled only on CKSyncEngine-capable iOS.")
require("static var isAvailable: Bool" in MANAGER and "#available(iOS 17.0, *)" in MANAGER, "Availability must hide iCloud Sync on older iOS versions.")
require("CKSyncEngine" in MANAGER, "iCloud Sync must use CKSyncEngine.")
require("container.privateCloudDatabase" in MANAGER, "iCloud Sync must use the user's private CloudKit database.")
require("stateSerialization: loadStateSerialization()" in MANAGER, "CKSyncEngine state must be persisted and restored.")
require(".saveZone(CKRecordZone(zoneID: zoneID))" in MANAGER, "The custom CloudKit zone must be created by the sync engine.")
require("syncEngine.sendChanges()" in MANAGER and "syncEngine.fetchChanges()" in MANAGER, "Sync must send and fetch changes explicitly.")
require('record.encryptedValues["payload"]' in MANAGER, "Synced payloads must be stored in encrypted CloudKit fields.")
require("handleSentRecordZoneChanges" in MANAGER and "serverRecordChanged" in MANAGER, "Sync must reconcile server change conflicts.")
require("ICEpisodeState" in MANAGER and "ICSubscription" in MANAGER and "ICAppSettings" in MANAGER, "Episode, subscription, and settings records must be modeled.")
require("ICListScrollPositions" in MANAGER and "ICListScrollPositionsSnapshot()" in MANAGER, "Episode list scroll positions must be included in episode sync.")
require("backupCredentialValues" in MANAGER and "restoreBackupCredentialValues" in MANAGER, "Settings sync must include app settings stored in the credential store.")
require('"valueType": Self.feedPropertyValueType(for: property)' in MANAGER, "Podcast settings sync must preserve property value types.")
require("applyFeedPropertyPayload" in MANAGER, "Podcast settings sync must apply false, zero, and empty values explicitly.")

manual_completion = method_body(MANAGER, "@objc func performManualSyncWithCompletion")
require("setError(error)" in manual_completion, "Manual sync errors must be persisted into the transparent sync status.")

manual_sync = method_body(MANAGER, "private func performManualSync() async throws")
require("hasUnresolvedSyncFailures = false" in manual_sync, "Manual sync must reset unresolved failure tracking before sending.")
require("markSyncCompletedIfFinished()" in manual_sync, "Manual sync must not report success while CKSyncEngine still has pending changes.")
require("await initialQueueTask?.value" in manual_sync, "Manual sync must wait for already scheduled initial queueing instead of queueing unchanged data itself.")
require("queueCurrentEnabledDataForUpload()" not in manual_sync, "Manual sync must not re-upload all enabled data when nothing changed.")
require("queueDeviceRecordForPendingUserDataIfNeeded()" in manual_sync, "Manual sync must only refresh the device record when user data is pending.")

background_sync = method_body(MANAGER, "@objc func performBackgroundSyncWithCompletion")
require("hasUnresolvedSyncFailures = false" in background_sync, "Background sync must reset unresolved fetch failure tracking.")
require("markSyncCompletedIfFinished()" in background_sync, "Background sync must not report success while CKSyncEngine still has pending changes.")

event_handler = method_body(MANAGER, "private func handleEventOnMain")
require("nonisolated func handleEvent" in MANAGER and "await handleEventOnMain" in MANAGER, "CKSyncEngine event callbacks must enter through a nonisolated delegate wrapper.")
require("hasUnresolvedSyncFailures = true" in event_handler, "Fetch zone errors must be remembered until the sync finishes.")
# The case body may carry extra fetch-completion logic (e.g. ending the subscription
# deletion suppression) — what matters is that completion is only marked CONDITIONALLY.
did_fetch_changes_block = event_handler.split("case .didFetchChanges:")[1].split("case .")[0]
require(
    "markSyncCompletedIfFinished()" in did_fetch_changes_block
    and "markSyncCompleted()" not in did_fetch_changes_block,
    "Fetch completion must not overwrite a failed or unfinished sync status.",
)
require("case .didSendChanges:\n            break" in event_handler, "A finished send operation must not overwrite failed record or zone send status.")
require("as? [AnyHashable: Any]" in method_body(MANAGER, "@objc func shouldHandleRemoteNotification"), "Malformed remote notification payloads must not crash iCloud Sync detection.")

initial_upload_apply = method_body(MANAGER, "private func applyInitialUploadPlan")
# The initial settings publish is FETCH-GATED: enabling settings sync must first adopt
# an existing cloud state. The old eager publish stamped a fresh localModifiedDate and
# won last-writer-wins against the real remote settings (they were silently discarded).
require("appSettingsRecordID()" not in initial_upload_apply, "Enabling settings sync must not eagerly publish local settings before the first fetch.")
require("markSettingsLocallyChangedAndQueue()" not in initial_upload_apply, "Current enabled data upload must not use delayed settings queueing.")
did_fetch_block = method_body(MANAGER, "private func handleEventOnMain").split("case .didFetchChanges:")[1].split("case .")[0]
require(
    "initialSettingsBackfillPendingKey" in did_fetch_block and "addPendingSave(appSettingsRecordID())" in did_fetch_block,
    "The initial settings publish must happen after the first complete fetch, only when no remote settings arrived.",
)
apply_remote_settings = method_body(MANAGER, "private func applyRemoteAppSettings")
# Enable phase: arriving cloud settings are PARKED and the user chooses (adopt cloud
# vs. publish local) — nothing is silently applied or published in either direction.
require(
    "pendingInitialSettingsPayloadKey" in apply_remote_settings
    and "initialSettingsChoiceNeededNotification" in apply_remote_settings,
    "Remote settings arriving during the enable phase must be parked for a user choice, not silently applied.",
)
adopt_settings = method_body(MANAGER, "private func adoptSettingsPayload")
require(
    "removeObject(forKey: Self.initialSettingsBackfillPendingKey)" in adopt_settings,
    "Adopting cloud settings must consume the initial-publish marker.",
)
require(
    "func resolveInitialSettingsAdoptingCloud" in MANAGER and "func resolveInitialSettingsPublishingLocal" in MANAGER,
    "Both initial-settings choices must be offered.",
)
require(
    "!hasPendingInitialSettingsChoice" in did_fetch_changes_block,
    "The fetch-gated initial publish must wait while the settings choice is pending.",
)
require("buildInitialUploadPlan" in MANAGER, "Initial iCloud queueing must build the large upload plan away from the switch tap.")
require("applyInitialEpisodeQueue" in initial_upload_apply, "Episode initial queueing must apply pending changes in chunks.")
require("applyInitialSubscriptionQueue" in initial_upload_apply, "Subscription initial queueing must apply pending changes in chunks.")
require("Task.yield()" in initial_upload_apply, "Full iCloud queueing must yield back to the UI between large sync categories.")

start_body = source_between(MANAGER, "@objc func start()", "\n    @objc func setEpisodesSyncEnabled")
require("queueDeviceRecord()" not in start_body, "App launch must not queue a device-only sync that makes Last Sync look current.")
require("queueDeviceRecordForPendingUserDataIfNeeded()" in start_body, "App launch may only queue the device record when user data is already pending.")
require("if hasInitialUploadBackfillWork" in start_body and "scheduleCurrentEnabledDataForUpload()" in start_body, "App launch may only resume an already-pending paged initial backfill.")
require("queueCurrentEnabledDataForUpload()" not in start_body, "App launch must not synchronously queue the whole library.")

sent_changes = method_body(MANAGER, "private func handleSentRecordZoneChanges")
require("event.failedRecordDeletes" in sent_changes, "Record delete failures must be handled, not ignored.")
require("handleFailedRecordDelete(recordID: recordID, error: error)" in sent_changes, "Record delete failures must go through explicit error handling.")
require("if hasFailedRecordChanges {\n            hasUnresolvedSyncFailures = true" in sent_changes, "Failed record sends must not be marked as a completed sync.")
require("markSyncCompletedIfFinished()" in sent_changes, "Record sends must only show Synced after all pending changes are finished.")
database_changes = method_body(MANAGER, "private func handleSentDatabaseChanges")
require("markSyncCompleted()" not in database_changes, "Creating the CloudKit zone must not show Synced before records are uploaded.")
require("markSyncCompletedIfFinished()" in MANAGER, "Sync completion must check pending CKSyncEngine changes before showing Synced.")

require("as? NSData" in method_body(MANAGER, "private func payloadDictionary"), "CloudKit payload decoding must accept NSData from encryptedValues.")
# System fields moved from UserDefaults to dedicated metadata files; the remaining
# bridging hazard is the encrypted payload value, which must tolerate NSData.
require(
    "writeKnownRecordSystemFields" in MANAGER and "as? NSData" in MANAGER,
    "Persisted CKRecord system fields must survive Data/NSData bridging.",
)
require("deviceHardwareIdentifierForSyncEngineCallback()" in MANAGER, "Device records must read the hardware identifier instead of relying on generic UIDevice.model.")
require("deviceMarketingNameForSyncEngineCallback()" in MANAGER, "Device records must store a user-facing Apple marketing model name.")
require('"iPhone18,1": "iPhone 17 Pro"' in MANAGER, "iPhone 17 Pro must be displayed by marketing name.")
require('"iPhone18,2": "iPhone 17 Pro Max"' in MANAGER, "iPhone 17 Pro Max must be displayed by marketing name.")
# localDevicePayload delegates to the static devicePayload builder since the
# nonisolated-callback consolidation — the marketing-name invariant lives there now.
device_payload = method_body(MANAGER, "private nonisolated static func devicePayload")
require('"name": marketingName' in device_payload and '"model": marketingName' in device_payload, "Local device payload must not store generic iPhone/iPad names.")
device_record = method_body(MANAGER, "private nonisolated static func deviceRecordForSyncEngineCallback")
require("snapshot.deviceRecordShouldStampSyncDate" in device_record, "Device records may stamp Last Sync only when user data was synced.")
require('if snapshot.deviceRecordShouldStampSyncDate {\n            payload["lastSyncDate"] = now' in device_record, "Device-only records must not move Last Sync to now.")
queue_device_record = method_body(MANAGER, "private func queueDeviceRecord")
require("setSyncMetadata(true, forKey: Self.deviceRecordShouldStampSyncDateKey)" in queue_device_record, "Device Last Sync stamping must survive CKSyncEngine queue callbacks and app restarts.")
add_pending_saves = method_body(MANAGER, "private func addPendingSaves(_ recordIDs: [CKRecord.ID], pendingKeys: inout Set<String>")
require("containsUserDataRecordID(recordIDs)" in add_pending_saves, "Pending user data must be detected before queueing the device sync date.")
require("queueDeviceRecord(stampLastSyncDate: true)" in add_pending_saves, "User-data changes must queue a device record that can publish the real data-sync date.")
# Deletes are queued inline in the local-change handler now; they must still end in a
# device record that publishes the real data-sync date.
require(
    "PendingRecordZoneChange.deleteRecord(subscriptionRecordID" in MANAGER,
    "Subscription deletes must be queued through the sync engine.",
)
require(
    "if queuedUserData {\n            queueDeviceRecord(stampLastSyncDate: true)" in MANAGER,
    "User-data deletes must queue a device record that can publish the real data-sync date.",
)
mark_completed = method_body(MANAGER, "private func markSyncCompleted")
require("if syncedUserDataInCurrentRun" in mark_completed, "Last Sync must only update after user data was actually sent or received.")
require('"Synchronisation vollständig"' in mark_completed, "Completed syncs must report completion, not a misleading no-op status.")
require("setSyncMetadata(false, forKey: Self.deviceRecordShouldStampSyncDateKey)" in mark_completed, "Completed syncs must clear persisted device Last Sync stamping.")

devices_body = source_between(MANAGER, "@objc var devices: [ICiCloudSyncDeviceInfo] {", "\n    private override init()")
require("cache[deviceID] = localDevicePayload()" not in devices_body, "Devices must not inject the current device before a successful sync.")
require("guard deviceParticipates(value) else { return nil }" in devices_body, "Devices must only list devices that participate in sync.")
require("key == deviceID ? value.merging(localDevicePayload()" in devices_body, "Existing current-device cache entries must refresh to the current marketing model name.")
require("deviceParticipates" in MANAGER, "Device participation must be explicit and based on enabled sync categories.")

sync_options_changed = method_body(MANAGER, "@objc func syncOptionsChanged()")
require('"iCloud prüfen…"' in sync_options_changed, "Enabling sync must show that iCloud availability is being checked, not Ready.")
require("await refreshAccountStatus()" in sync_options_changed, "Enabling sync must refresh account status immediately.")
require('logSyncEvent("Sync-Optionen geändert"' in sync_options_changed, "iCloud Sync option changes must log the combined switch state.")
require('logSyncEvent("iCloud Sync deaktiviert"' in sync_options_changed, "Disabling the last sync category must be logged before observers reload.")
initial_queue_schedule = method_body(MANAGER, "private func scheduleCurrentEnabledDataForUpload")
require('logSyncEvent("Initiale iCloud-Queue geplant"' in initial_queue_schedule, "Scheduling the initial upload queue must be logged.")
require('logSyncEvent("Initiale iCloud-Queue gestartet"' in initial_queue_schedule, "Starting the initial upload queue must be logged after the UI-yield.")
require('logSyncEvent("Initiale iCloud-Queue abgeschlossen"' in initial_upload_apply, "Finishing the initial upload queue must be logged.")
require("Task.detached" in initial_queue_schedule and "Task { @MainActor" not in initial_queue_schedule, "Initial iCloud queue planning must not inherit the MainActor from the switch tap.")
require("await self.queueCurrentEnabledDataForUpload()" not in initial_queue_schedule, "Detached initial iCloud queueing must not hop directly back to the MainActor.")
require("buildInitialUploadPlan" in initial_queue_schedule and "applyInitialUploadPlan" in initial_queue_schedule, "Initial iCloud queueing must separate background planning from manager state application.")
low_priority_sync = method_body(MANAGER, "private func scheduleLowPrioritySync")
require("Task(priority: .background)" in low_priority_sync, "Automatic CloudKit sends must be background-priority.")
require("Task.detached" not in low_priority_sync, "Automatic CloudKit sends must not call CKSyncEngine from a detached task.")
require("MainActor.run" not in low_priority_sync, "Automatic CloudKit sends must not hand CKSyncEngine across actors via MainActor.run.")
initial_queue_cancel = method_body(MANAGER, "private func cancelInitialQueueTask")
require('logSyncEvent("Initiale iCloud-Queue abgebrochen"' in initial_queue_cancel, "Cancelling stale initial iCloud queueing must be logged.")
require('logSyncEvent("iCloud Upload-Queue baut Daten auf"' in initial_upload_apply, "Building the enabled-data upload queue must be logged.")
require("scheduleCurrentEnabledDataForUpload()" in sync_options_changed, "Toggling sync options must schedule initial queueing asynchronously.")
require("queueCurrentEnabledDataForUpload()" not in sync_options_changed, "Toggling sync options must not synchronously queue the whole library on the switch tap.")
require("initializeSyncEngineIfNeeded()" not in source_between(sync_options_changed, "if anySyncEnabled {", "} else if syncEngine != nil {"), "Toggling sync on must not synchronously create CKSyncEngine on the switch tap.")
require("queueDeviceRecord()" not in source_between(sync_options_changed, "if anySyncEnabled {", "} else if syncEngine != nil {"), "Toggling sync on must not synchronously mutate CKSyncEngine pending changes on the switch tap.")
require("cancelInitialQueueTask()" in MANAGER, "iCloud Sync must have a dedicated cancellation path for stale initial queueing.")
disable_all_sync = source_between(sync_options_changed, "} else if syncEngine != nil {", "\n        }")
require(
    disable_all_sync.find("cancelInitialQueueTask()") != -1
    and disable_all_sync.find("cancelInitialQueueTask()") < disable_all_sync.find("queueDeviceRecord()"),
    "Disabling the last iCloud Sync category must cancel stale initial episode/subscription queueing before queuing the device-off record.",
)
episode_initial_queue = method_body(MANAGER, "private func applyInitialEpisodeQueue")
require(
    "guard episodesSyncEnabled, !Task.isCancelled else { return queuedRecords }" in episode_initial_queue,
    "Stale initial episode queueing must stop after async fetches when Episode sync has been disabled.",
)
subscription_initial_queue = method_body(MANAGER, "private func applyInitialSubscriptionQueue")
require(
    "guard subscriptionsSyncEnabled, !Task.isCancelled else { return queuedRecords }" in subscription_initial_queue,
    "Stale initial subscription queueing must stop after async fetches when Subscription sync has been disabled.",
)

episode_queue = method_body(MANAGER, "private func applyInitialEpisodeQueue")
episode_fetch = method_body(MANAGER, "private nonisolated static func episodeObjectHashesForInitialUploadPlan")
require("private func applyInitialEpisodeQueue" in MANAGER, "Initial episode queueing must be async.")
require("performAndWait" not in episode_queue, "Initial episode queueing must not block the MainActor with performAndWait.")
require("objectHashes.reduce(into:" not in episode_queue, "Initial episode queueing must not build one full local-modified-date dictionary on the MainActor.")
require("await context.perform" in episode_fetch, "Initial episode queueing must fetch episode IDs on a Core Data background context.")
require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in episode_fetch, "Initial episode queueing must fetch only one bounded page at a time.")
require("while true" not in episode_fetch, "Initial episode queueing must not scan every matching episode in one task.")
require("nextEpisodeBackfillOffset" in MANAGER, "Initial episode queueing must track a next-page cursor.")

subscription_queue = method_body(MANAGER, "private func applyInitialSubscriptionQueue")
subscription_fetch = method_body(MANAGER, "private nonisolated static func subscribedFeedURLsForInitialUploadPlan")
require("private func applyInitialSubscriptionQueue" in MANAGER, "Initial subscription queueing must be async.")
require("databaseManager.feeds" not in subscription_queue, "Initial subscription queueing must not scan feeds on the MainActor.")
require("subscribedFeedURLsForInitialUploadPlan(offset:" in MANAGER, "Initial subscription queueing must collect feed URLs off the UI path.")
require("await context.perform" in subscription_fetch, "Initial subscription queueing must fetch feed URLs on a Core Data background context.")
require("fetchLimit = Self.pendingChangeQueueChunkSize + 1" in subscription_fetch, "Initial subscription queueing must fetch only one bounded page at a time.")
require("while true" not in subscription_fetch, "Initial subscription queueing must not scan every subscribed feed in one task.")
require("nextSubscriptionBackfillOffset" in MANAGER, "Initial subscription queueing must track a next-page cursor.")
require("pendingKeys: &pendingKeys" in initial_upload_apply, "Initial queueing must reuse pending CKSyncEngine keys while adding chunks.")

record_batch = method_body(MANAGER, "nonisolated func nextRecordZoneChangeBatch")
require("maximumRecordZoneChangesPerBatch" in record_batch, "CloudKit record send batches must be capped.")
require("validChangeCount >= Self.maximumRecordZoneChangesPerBatch" in record_batch, "CloudKit batch construction must stop before creating oversized requests.")
require("await " not in record_batch, "CKSyncEngine send batches must not hop actors or leave the engine delegate queue while reading syncEngine.state.")
require("recordToSaveForSyncEngineCallback(for: recordID" in record_batch, "CKSyncEngine send batches must materialize records synchronously on the delegate queue.")
require('logSyncEvent("CKSyncEngine-Send-Batch materialisiert"' in record_batch, "CKSyncEngine send batches must log materialized save/delete/stale counts.")
for key in ["scopedChanges", "recordsToSave", "recordIDsToDelete", "staleSaveChanges", "validChangeCount"]:
    require(f'"{key}"' in record_batch, f"CKSyncEngine send-batch diagnostics must include {key}.")
record_to_save = method_body(MANAGER, "private nonisolated static func recordToSaveForSyncEngineCallback")
require("await " not in record_to_save, "CKSyncEngine record materialization must stay synchronous once the engine asks for a batch.")
# Episode/subscription records are batch-materialized (ONE fetch per send batch) —
# the per-record callback path was the store-lock contention that froze the UI.
materialize_batch = method_body(MANAGER, "private nonisolated static func materializeRecordsForSyncEngineCallback")
require("await " not in materialize_batch, "CKSyncEngine batch materialization must stay synchronous once the engine asks for a batch.")
require("episodeStatesByObjectHash" in materialize_batch, "Episode records must be batch-materialized through the queue-local CKSyncEngine callback path.")
require("subscriptionPayloadsByFeedURL" in materialize_batch, "Subscription records must be batch-materialized through the queue-local CKSyncEngine callback path.")
require("databaseManager.episode" not in materialize_batch and "databaseManager.feed" not in materialize_batch, "Record materialization must not touch the main Core Data context from CKSyncEngine queues.")
episode_states_fetch = method_body(MANAGER, "private nonisolated static func episodeStatesByObjectHash")
require("newBackgroundContext()" in episode_states_fetch and "context.performAndWait" in episode_states_fetch, "Episode payload snapshots must be fetched synchronously on a background Core Data context queue during CKSyncEngine callbacks.")
require('NSPredicate(format: "objectHash IN %@"' in episode_states_fetch, "Episode payload snapshots must use ONE batch fetch, not a fetch per record.")
subscription_payloads_fetch = method_body(MANAGER, "private nonisolated static func subscriptionPayloadsByFeedURL")
require("newBackgroundContext()" in subscription_payloads_fetch and "context.performAndWait" in subscription_payloads_fetch, "Subscription payload snapshots must be fetched synchronously on a background Core Data context queue during CKSyncEngine callbacks.")
require('relationshipKeyPathsForPrefetching = ["properties"]' in subscription_payloads_fetch, "Subscription payload snapshots must prefetch feed properties instead of faulting per feed.")
require("private nonisolated static func feedPropertyValueType" in MANAGER and "private nonisolated static func defaultFeedPropertyValueType" in MANAGER, "Background subscription payload snapshots must not call main-actor feed property helpers.")

log_sync = method_body(MANAGER, "private func logSyncEvent")
require('logEvent("icloud-sync"' in log_sync, "iCloud Sync must write switch and CKSyncEngine diagnostics to the shared diagnostic log.")
for key in ["episodesSyncEnabled", "subscriptionsSyncEnabled", "settingsSyncEnabled", "anySyncEnabled", "actor", "syncEngineInitialized", "initialQueueTaskActive", "lowPrioritySyncTaskActive", "isMainThread", "threadID"]:
    require(f'"{key}"' in log_sync, f"iCloud Sync diagnostics must include {key}.")
require("syncEngine?.state" not in log_sync, "iCloud Sync diagnostics must not read CKSyncEngine.state just to log.")
require("Thread.isMainThread" in log_sync, "iCloud Sync diagnostics must record whether the event came from the main thread.")

episodes_switch = method_body(MANAGER, "@objc func setEpisodesSyncEnabled")
subscriptions_switch = method_body(MANAGER, "@objc func setSubscriptionsSyncEnabled")
settings_switch = method_body(MANAGER, "@objc func setSettingsSyncEnabled")
require('logSyncEvent("Episode Sync-Schalter geändert"' in episodes_switch and '"enabled": enabled' in episodes_switch, "Episode sync switch toggles must be logged.")
require('logSyncEvent("Abo Sync-Schalter geändert"' in subscriptions_switch and '"enabled": enabled' in subscriptions_switch, "Subscription sync switch toggles must be logged.")
require('logSyncEvent("Einstellungs-Sync-Schalter geändert"' in settings_switch and '"enabled": enabled' in settings_switch, "Settings sync switch toggles must be logged.")

set_error = method_body(MANAGER, "private func setError")
require("displayStatus(for: error)" in set_error, "Visible iCloud Sync errors must be converted to short user-facing status text.")
require("error.localizedDescription" not in set_error, "Raw backend error descriptions must not be shown directly in the status row.")
require("syncedUserDataInCurrentRun = false" in set_error, "Failed syncs must not leak user-data activity into the next no-op sync.")
require("setSyncMetadata(false, forKey: Self.deviceRecordShouldStampSyncDateKey)" in set_error, "Failed syncs must clear persisted device Last Sync stamping.")
require('logSyncEvent("iCloud Sync Fehler"' in set_error and '"domain"' in set_error and '"code"' in set_error and '"status"' in set_error, "iCloud Sync errors must log domain/code/status for future crash triage.")
set_status = method_body(MANAGER, "private func setStatus")
require("clearError()" in set_status, "New iCloud Sync status updates must clear stale raw errors from previous builds.")
post_state = method_body(MANAGER, "private func postStateChanged")
require("Thread.isMainThread" in post_state and "DispatchQueue.main.async" in post_state, "iCloud Sync state notifications must be delivered on the main queue for UIKit observers.")
post_devices = method_body(MANAGER, "private func postDevicesChanged")
require("Thread.isMainThread" in post_devices and "DispatchQueue.main.async" in post_devices, "iCloud Sync device notifications must be delivered on the main queue for UIKit observers.")

settings_key_filter = method_body(MANAGER, "private nonisolated static func shouldSyncSettingsKeyForSyncEngineCallback")
require('if key.hasPrefix("ICiCloudSync") { return false }' in settings_key_filter, "iCloud Sync opt-in switches must stay local to each device.")
require("private var syncOptionKeys" not in MANAGER, "Settings sync must not whitelist iCloud Sync opt-in switches.")
apply_settings = method_body(MANAGER, "private func applyRemoteAppSettings")
require("syncOptionsChanged()" not in apply_settings, "Applying synced settings must not re-run full iCloud option queueing.")
transient_keys = method_body(MANAGER, "private nonisolated static func transientSettingsKeysForSyncEngineCallback")
for key in [
    "kUIPersistenceMainSidebarItem",
    "kUIPersistenceSubscriptionsSelectedFeedUID",
    "kUIPersistenceSubscriptionsSearchTerm",
    "kUIPersistencePlaylistsSelectedPlaylistUID",
    "kUIPersistenceBookmarkSelectedEpisodeGUID",
    "kUIPersistenceDirectorySearchSearchString",
    "kUIPersistenceDirectorySearchSelectedScopeIndex",
]:
    require(key in transient_keys, f"{key} must not be synced as an app setting.")

require("@available(iOS 17.0, *)" in OPTIONS and "[ICiCloudSyncManager isAvailable]" in OPTIONS, "Options must hide iCloud Sync on older iOS.")
require("kRowiCloudSync" in OPTIONS and '"iCloud Sync".ls' in OPTIONS, "Options must show an iCloud Sync row.")
require("ICiCloudSyncSettingsViewController" in OPTIONS, "Options must open the iCloud Sync settings controller.")

require("ICiCloudSyncSettingsSectionStatus" in SETTINGS, "iCloud Sync settings must have a status section.")
require("ICiCloudSyncSettingsSectionOptions" in SETTINGS, "iCloud Sync settings must have an options section.")
require("ICiCloudSyncSettingsSectionDevices" in SETTINGS, "iCloud Sync settings must have a devices section.")
require("case ICiCloudSyncSettingsSectionStatus:\n            return nil;" in SETTINGS, "The status section must not repeat the page title as a header.")
require("ICiCloudSyncOptionRowEpisodes" in SETTINGS, "Episode sync option row is missing.")
require("ICiCloudSyncOptionRowSubscriptions" in SETTINGS, "Subscription sync option row is missing.")
require("ICiCloudSyncOptionRowSettings" in SETTINGS, "Settings sync option row is missing.")
require("performManualSyncWithCompletion" in SETTINGS and '"Sync Now".ls' in SETTINGS, "Manual sync UI must trigger CKSyncEngine.")
require("configureSyncNowCell:" in SETTINGS, "Sync Now cell must have explicit enabled/disabled state.")
require("cell.userInteractionEnabled = syncEnabled" in SETTINGS, "Sync Now must be disabled when no sync category is enabled.")
require("if (![ICiCloudSyncManager sharedManager].anySyncEnabled) { return; }" in SETTINGS, "Tapping disabled Sync Now must not trigger a sync.")
require("error.localizedDescription" not in SETTINGS, "Manual sync alerts must not show clipped raw CloudKit backend messages.")
require("reloadStatusAndDevicesSections" in SETTINGS, "iCloud settings updates must reload only status/devices, not rebuild switch rows while a switch is being tapped.")
toggle_body = method_body(SETTINGS, "- (void)toggleSyncOption:")
require("[self.tableView reloadData]" not in toggle_body, "Tapping an iCloud Sync switch must not rebuild the whole table view.")
require("ICiCloudSyncDeviceInfo" in SETTINGS and '"Last Sync".ls' in SETTINGS, "Device list must show participating devices and last sync status.")
require('"No synced devices yet".ls' in SETTINGS, "Empty device state must make successful sync participation clear.")
require("iCloud Sync keeps selected data in sync through your private iCloud account." not in SETTINGS, "The status footer copy must be removed from iCloud Sync settings.")
require("Sync Episodes keeps played state, playback position, favorites, and list scroll positions in sync. Sync Subscriptions keeps subscribed podcasts, podcast settings, deletions, and sort order in sync." in SETTINGS, "The option footer must explain episode and subscription sync.")
require("Sync Settings keeps app settings in sync." not in SETTINGS, "The option footer must not include the confusing settings-sync explanation.")
require("Choose on each device which categories this device syncs. This choice is not copied to your other devices." not in SETTINGS, "The per-device option footer copy must be removed from iCloud Sync settings.")
require("These iCloud Sync switches stay local to this device." not in SETTINGS, "Unclear per-device sync option copy must not be used.")
require('"Synced Devices".ls' in SETTINGS, "Device section must use a clear synced-devices header.")
require("Only devices that have successfully synced with at least one enabled category appear here." not in SETTINGS, "The device section footer copy must be removed.")
require("displayNameForDevice:" in SETTINGS, "The current-device row must not present a generic iOS device type as the user's chosen device name.")
require("multilineInfoCellWithIdentifier:" in SETTINGS, "Status and device rows must use a multiline cell layout.")
status_row = source_between(SETTINGS, "if (indexPath.section == ICiCloudSyncSettingsSectionStatus) {", "\n    if (indexPath.section == ICiCloudSyncSettingsSectionOptions)")
require("[self detailCell]" in status_row, "The iCloud Sync status row must stay a single-line detail row.")
require("multilineInfoCellWithIdentifier" not in status_row, "The iCloud Sync status row must not use the multiline device layout.")
require("NSRelativeDateTimeFormatter" in SETTINGS and "localizedStringForDate:" in SETTINGS and "relativeToDate:" in SETTINGS, "Device last-sync dates must be displayed relative to now.")
require("UITableViewCellStyleSubtitle" in SETTINGS, "Device rows need a full-width subtitle line instead of a narrow value label.")
require("ICiCloudSyncSettingsDeviceRowHeight" in SETTINGS, "Device rows must be tall enough for two-line sync details.")
require("heightForRowAtIndexPath" in SETTINGS, "The iCloud Sync settings table must explicitly size multiline rows.")
require('@"%@\\n%@: %@"' in SETTINGS, "Device details must put Last Sync on a second line when all categories are enabled.")
# Status redesign: per-category progress ("Lädt herunter… 31/51 Abonnements") instead
# of a flat item counter, driven by the sync-activity tracker.
require('"%@ %ld/%ld %@"' in MANAGER, "Sync status must expose per-category item progress while syncing.")
require("beginSyncActivity(" in MANAGER and "recordSyncActivity(" in MANAGER, "Sync progress must be tracked from CKSyncEngine activity.")
require("clearSyncActivity()" in MANAGER, "Transient sync progress must be cleared after completion or errors.")

options_icloud_row = source_between(OPTIONS, "case kRowiCloudSync:", "\n            break;")
require("[ICiCloudSyncManager sharedManager].anySyncEnabled" not in options_icloud_row, "The main settings menu must not show an On/Off status for iCloud Sync.")

require("@available(iOS 17.0, *)" in APP_DELEGATE, "App delegate must not touch CKSyncEngine on older iOS.")
require("shouldHandleRemoteNotification:" in APP_DELEGATE, "App delegate must route CloudKit pushes to iCloud Sync.")
require("performBackgroundSyncWithCompletion:" in APP_DELEGATE, "App delegate must run background iCloud Sync for CloudKit pushes.")

for tag, key in zip(BACKUP_TAGS, SYNC_KEYS):
    require(f"<{tag}>" in EXPORTER and key in EXPORTER, f"Backup export must include {tag}.")
    require(f'"{tag}":' in IMPORTER and key in IMPORTER, f"Backup import must map {tag}.")
    require(f'"{tag}"' in IMPORTER.split("NSSet *boolKeys", 1)[1], f"Backup import must restore {tag} as a boolean.")

for strings, language in [(EN_STRINGS, "English"), (DE_STRINGS, "German")]:
    for key in ["iCloud Sync", "Sync Episodes", "Sync Subscriptions", "Sync Settings", "Sync Now", "Last Sync", "No synced devices yet", "Synced Devices", "iCloud prüfen…", "Keine Änderungen"]:
        require(f'"{key}" =' in strings, f"{language} localization is missing {key}.")
    for key in [
        "Sync Episodes keeps played state, playback position, favorites, and list scroll positions in sync. Sync Subscriptions keeps subscribed podcasts, podcast settings, deletions, and sort order in sync.",
        "iCloud Sync will continue in smaller batches.",
        "%ld/%ld Elemente",
    ]:
        require(f'"{key}" =' in strings, f"{language} localization is missing clearer copy: {key}.")
    for removed_key in [
        "iCloud Sync keeps selected data in sync through your private iCloud account.",
        "Sync Episodes keeps played state, playback position, favorites, and list scroll positions in sync. Sync Subscriptions keeps subscribed podcasts, podcast settings, deletions, and sort order in sync. Sync Settings keeps app settings in sync.",
        "Choose on each device which categories this device syncs. This choice is not copied to your other devices.",
        "Only devices that have successfully synced with at least one enabled category appear here.",
    ]:
        require(f'"{removed_key}" =' not in strings, f"{language} localization still contains removed iCloud explainer copy.")

require('"Sync Episodes" = "Folgen synchronisieren";' in DE_STRINGS, "German episode sync label is missing.")
require('"Sync Subscriptions" = "Abonnements synchronisieren";' in DE_STRINGS, "German subscription sync label is missing.")
require('"Sync Settings" = "Einstellungen synchronisieren";' in DE_STRINGS, "German settings sync label is missing.")
require('"No synced devices yet" = "Noch keine synchronisierten Geräte";' in DE_STRINGS, "German empty devices label is missing.")
