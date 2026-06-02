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
require("syncEngine.sendChanges()" in MANAGER and "syncEngine.fetchChanges()" in MANAGER, "Manual sync must send and fetch changes explicitly.")
require('record.encryptedValues["payload"]' in MANAGER, "Synced payloads must be stored in encrypted CloudKit fields.")
require("handleSentRecordZoneChanges" in MANAGER and "serverRecordChanged" in MANAGER, "Sync must reconcile server change conflicts.")
require("ICEpisodeState" in MANAGER and "ICSubscription" in MANAGER and "ICAppSettings" in MANAGER, "Episode, subscription, and settings records must be modeled.")
require("ICListScrollPositions" in MANAGER and "ICListScrollPositionsSnapshot()" in MANAGER, "Episode list scroll positions must be included in episode sync.")
require("backupCredentialValues" in MANAGER and "restoreBackupCredentialValues" in MANAGER, "Settings sync must include app settings stored in the credential store.")
require('"valueType": feedPropertyValueType(for: property)' in MANAGER, "Podcast settings sync must preserve property value types.")
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

event_handler = method_body(MANAGER, "func handleEvent")
require("hasUnresolvedSyncFailures = true" in event_handler, "Fetch zone errors must be remembered until the sync finishes.")
require("case .didFetchChanges:\n            markSyncCompletedIfFinished()" in event_handler, "Fetch completion must not overwrite a failed or unfinished sync status.")
require("case .didSendChanges:\n            break" in event_handler, "A finished send operation must not overwrite failed record or zone send status.")
require("as? [AnyHashable: Any]" in method_body(MANAGER, "@objc func shouldHandleRemoteNotification"), "Malformed remote notification payloads must not crash iCloud Sync detection.")

queue_enabled_data = method_body(MANAGER, "private func queueCurrentEnabledDataForUpload")
require("queueSettingsRecord()" in queue_enabled_data, "Manual Sync must queue settings immediately instead of relying on a debounce timer.")
require("markSettingsLocallyChangedAndQueue()" not in queue_enabled_data, "Current enabled data upload must not use delayed settings queueing.")
require("private func queueCurrentEnabledDataForUpload() async" in MANAGER, "Full iCloud queueing must be async so UI taps are not blocked.")
require("await queueAllEpisodeStateRecords()" in queue_enabled_data, "Episode initial queueing must yield while collecting large libraries.")
require("await queueAllSubscriptionRecords()" in queue_enabled_data, "Subscription initial queueing must yield while collecting large libraries.")
require("Task.yield()" in queue_enabled_data, "Full iCloud queueing must yield back to the UI between large sync categories.")

start_body = source_between(MANAGER, "@objc func start()", "\n    @objc func setEpisodesSyncEnabled")
require("queueDeviceRecord()" not in start_body, "App launch must not queue a device-only sync that makes Last Sync look current.")
require("queueDeviceRecordForPendingUserDataIfNeeded()" in start_body, "App launch may only queue the device record when user data is already pending.")
require("scheduleCurrentEnabledDataForUpload()" not in start_body, "App launch must not enqueue the whole library.")
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
require("normalizedDataDictionary" in MANAGER, "Persisted CKRecord system fields must survive UserDefaults NSData bridging.")
require("private func deviceHardwareIdentifier()" in MANAGER, "Device records must read the hardware identifier instead of relying on generic UIDevice.model.")
require("private func deviceMarketingName()" in MANAGER, "Device records must store a user-facing Apple marketing model name.")
require('"iPhone18,1": "iPhone 17 Pro"' in MANAGER, "iPhone 17 Pro must be displayed by marketing name.")
require('"iPhone18,2": "iPhone 17 Pro Max"' in MANAGER, "iPhone 17 Pro Max must be displayed by marketing name.")
local_device_payload = method_body(MANAGER, "private func localDevicePayload")
require('"name": marketingName' in local_device_payload and '"model": marketingName' in local_device_payload, "Local device payload must not store generic iPhone/iPad names.")
device_record = method_body(MANAGER, "private func deviceRecord")
require("deviceRecordShouldStampSyncDate" in device_record, "Device records may stamp Last Sync only when user data was synced.")
require('if deviceRecordShouldStampSyncDate {\n            payload["lastSyncDate"] = now' in device_record, "Device-only records must not move Last Sync to now.")
add_pending_saves = method_body(MANAGER, "private func addPendingSaves")
require("containsUserDataRecordID(recordIDs)" in add_pending_saves, "Pending user data must be detected before queueing the device sync date.")
require("queueDeviceRecord(stampLastSyncDate: true)" in add_pending_saves, "User-data changes must queue a device record that can publish the real data-sync date.")
add_pending_delete = method_body(MANAGER, "private func addPendingDelete")
require("isUserDataRecordID(recordID)" in add_pending_delete and "queueDeviceRecord(stampLastSyncDate: true)" in add_pending_delete, "User-data deletes must queue a device record that can publish the real data-sync date.")
mark_completed = method_body(MANAGER, "private func markSyncCompleted")
require("if syncedUserDataInCurrentRun" in mark_completed, "Last Sync must only update after user data was actually sent or received.")
require('"Keine Änderungen"' in mark_completed, "No-op sync checks must report that nothing changed instead of pretending data synced.")

devices_body = source_between(MANAGER, "@objc var devices: [ICiCloudSyncDeviceInfo] {", "\n    private override init()")
require("cache[deviceID] = localDevicePayload()" not in devices_body, "Devices must not inject the current device before a successful sync.")
require("guard deviceParticipates(value) else { return nil }" in devices_body, "Devices must only list devices that participate in sync.")
require("key == deviceID ? value.merging(localDevicePayload()" in devices_body, "Existing current-device cache entries must refresh to the current marketing model name.")
require("deviceParticipates" in MANAGER, "Device participation must be explicit and based on enabled sync categories.")

sync_options_changed = method_body(MANAGER, "@objc func syncOptionsChanged()")
require('"iCloud prüfen…"' in sync_options_changed, "Enabling sync must show that iCloud availability is being checked, not Ready.")
require("await refreshAccountStatus()" in sync_options_changed, "Enabling sync must refresh account status immediately.")
require("scheduleCurrentEnabledDataForUpload()" in sync_options_changed, "Toggling sync options must schedule initial queueing asynchronously.")
require("queueCurrentEnabledDataForUpload()" not in sync_options_changed, "Toggling sync options must not synchronously queue the whole library on the switch tap.")
require("cancelInitialQueueTask()" in MANAGER, "iCloud Sync must have a dedicated cancellation path for stale initial queueing.")
disable_all_sync = source_between(sync_options_changed, "} else if syncEngine != nil {", "\n        }")
require(
    disable_all_sync.find("cancelInitialQueueTask()") != -1
    and disable_all_sync.find("cancelInitialQueueTask()") < disable_all_sync.find("queueDeviceRecord()"),
    "Disabling the last iCloud Sync category must cancel stale initial episode/subscription queueing before queuing the device-off record.",
)
episode_initial_queue = method_body(MANAGER, "private func queueAllEpisodeStateRecords")
require(
    "guard episodesSyncEnabled, !objectHashes.isEmpty, !Task.isCancelled else { return }" in episode_initial_queue
    and "guard episodesSyncEnabled, !Task.isCancelled else { return }" in episode_initial_queue,
    "Stale initial episode queueing must stop after async fetches when Episode sync has been disabled.",
)
subscription_initial_queue = method_body(MANAGER, "private func queueAllSubscriptionRecords")
require(
    "guard subscriptionsSyncEnabled, !feedURLs.isEmpty, !Task.isCancelled else { return }" in subscription_initial_queue
    and "guard subscriptionsSyncEnabled, !Task.isCancelled else { return }" in subscription_initial_queue,
    "Stale initial subscription queueing must stop after async fetches when Subscription sync has been disabled.",
)

episode_queue = method_body(MANAGER, "private func queueAllEpisodeStateRecords")
episode_fetch = method_body(MANAGER, "private func episodeObjectHashesForInitialSync")
require("private func queueAllEpisodeStateRecords() async" in MANAGER, "Initial episode queueing must be async.")
require("performAndWait" not in episode_queue, "Initial episode queueing must not block the MainActor with performAndWait.")
require("await context.perform" in episode_fetch, "Initial episode queueing must fetch episode IDs on a Core Data background context.")

subscription_queue = method_body(MANAGER, "private func queueAllSubscriptionRecords")
subscription_fetch = method_body(MANAGER, "private func subscribedFeedURLsForInitialSync")
require("private func queueAllSubscriptionRecords() async" in MANAGER, "Initial subscription queueing must be async.")
require("databaseManager.feeds" not in subscription_queue, "Initial subscription queueing must not scan feeds on the MainActor.")
require("await subscribedFeedURLsForInitialSync()" in subscription_queue, "Initial subscription queueing must collect feed URLs off the UI path.")
require("await context.perform" in subscription_fetch, "Initial subscription queueing must fetch feed URLs on a Core Data background context.")

record_batch = method_body(MANAGER, "func nextRecordZoneChangeBatch")
require("maximumRecordZoneChangesPerBatch" in record_batch, "CloudKit record send batches must be capped.")
require("validChangeCount >= Self.maximumRecordZoneChangesPerBatch" in record_batch, "CloudKit batch construction must stop before creating oversized requests.")

set_error = method_body(MANAGER, "private func setError")
require("displayStatus(for: error)" in set_error, "Visible iCloud Sync errors must be converted to short user-facing status text.")
require("error.localizedDescription" not in set_error, "Raw backend error descriptions must not be shown directly in the status row.")
require("syncedUserDataInCurrentRun = false" in set_error, "Failed syncs must not leak user-data activity into the next no-op sync.")
set_status = method_body(MANAGER, "private func setStatus")
require("clearError()" in set_status, "New iCloud Sync status updates must clear stale raw errors from previous builds.")

settings_key_filter = method_body(MANAGER, "private func shouldSyncSettingsKey")
require('if key.hasPrefix("ICiCloudSync") { return false }' in settings_key_filter, "iCloud Sync opt-in switches must stay local to each device.")
require("private var syncOptionKeys" not in MANAGER, "Settings sync must not whitelist iCloud Sync opt-in switches.")
apply_settings = method_body(MANAGER, "private func applyRemoteAppSettings")
require("syncOptionsChanged()" not in apply_settings, "Applying synced settings must not re-run full iCloud option queueing.")
transient_keys = method_body(MANAGER, "private var transientSettingsKeys")
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
require("%ld/%ld Elemente" in MANAGER, "Sync status must expose item progress while sending changes.")
require("beginSyncProgress()" in MANAGER and "updateSyncProgressFromPendingChanges()" in MANAGER, "Sync progress must be tracked from CKSyncEngine pending changes.")
require("clearSyncProgress()" in MANAGER, "Transient sync progress must be cleared after completion or errors.")

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
