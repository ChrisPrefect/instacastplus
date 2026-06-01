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
require("if !hasUnresolvedSyncFailures {\n            markSyncCompleted()" in manual_sync, "Manual sync must not report success after partial CKSyncEngine send failures.")

background_sync = method_body(MANAGER, "@objc func performBackgroundSyncWithCompletion")
require("hasUnresolvedSyncFailures = false" in background_sync, "Background sync must reset unresolved fetch failure tracking.")
require("if !hasUnresolvedSyncFailures {\n                        markSyncCompleted()" in background_sync, "Background sync must not report success after partial CKSyncEngine fetch failures.")

event_handler = method_body(MANAGER, "func handleEvent")
require("hasUnresolvedSyncFailures = true" in event_handler, "Fetch zone errors must be remembered until the sync finishes.")
require("case .didFetchChanges:\n            if !hasUnresolvedSyncFailures" in event_handler, "Fetch completion must not overwrite a failed zone fetch status.")
require("case .didSendChanges:\n            break" in event_handler, "A finished send operation must not overwrite failed record or zone send status.")
require("as? [AnyHashable: Any]" in method_body(MANAGER, "@objc func shouldHandleRemoteNotification"), "Malformed remote notification payloads must not crash iCloud Sync detection.")

queue_enabled_data = method_body(MANAGER, "private func queueCurrentEnabledDataForUpload")
require("queueSettingsRecord()" in queue_enabled_data, "Manual Sync must queue settings immediately instead of relying on a debounce timer.")
require("markSettingsLocallyChangedAndQueue()" not in queue_enabled_data, "Current enabled data upload must not use delayed settings queueing.")

sent_changes = method_body(MANAGER, "private func handleSentRecordZoneChanges")
require("event.failedRecordDeletes" in sent_changes, "Record delete failures must be handled, not ignored.")
require("handleFailedRecordDelete(recordID: recordID, error: error)" in sent_changes, "Record delete failures must go through explicit error handling.")
require("if hasFailedRecordChanges {\n            hasUnresolvedSyncFailures = true" in sent_changes, "Failed record sends must not be marked as a completed sync.")

require("as? NSData" in method_body(MANAGER, "private func payloadDictionary"), "CloudKit payload decoding must accept NSData from encryptedValues.")
require("normalizedDataDictionary" in MANAGER, "Persisted CKRecord system fields must survive UserDefaults NSData bridging.")

devices_body = source_between(MANAGER, "@objc var devices: [ICiCloudSyncDeviceInfo] {", "\n    private override init()")
require("cache[deviceID] = localDevicePayload()" not in devices_body, "Devices must not inject the current device before a successful sync.")
require("guard deviceParticipates(value) else { return nil }" in devices_body, "Devices must only list devices that participate in sync.")
require("deviceParticipates" in MANAGER, "Device participation must be explicit and based on enabled sync categories.")

sync_options_changed = method_body(MANAGER, "@objc func syncOptionsChanged()")
require('"iCloud prüfen…"' in sync_options_changed, "Enabling sync must show that iCloud availability is being checked, not Ready.")
require("await refreshAccountStatus()" in sync_options_changed, "Enabling sync must refresh account status immediately.")

settings_key_filter = method_body(MANAGER, "private func shouldSyncSettingsKey")
require('if key.hasPrefix("ICiCloudSync") { return false }' in settings_key_filter, "iCloud Sync opt-in switches must stay local to each device.")
require("private var syncOptionKeys" not in MANAGER, "Settings sync must not whitelist iCloud Sync opt-in switches.")

require("@available(iOS 17.0, *)" in OPTIONS and "[ICiCloudSyncManager isAvailable]" in OPTIONS, "Options must hide iCloud Sync on older iOS.")
require("kRowiCloudSync" in OPTIONS and '"iCloud Sync".ls' in OPTIONS, "Options must show an iCloud Sync row.")
require("[ICiCloudSyncManager sharedManager].anySyncEnabled" in OPTIONS, "Options must display whether any iCloud Sync category is enabled.")
require("ICiCloudSyncSettingsViewController" in OPTIONS, "Options must open the iCloud Sync settings controller.")

require("ICiCloudSyncSettingsSectionStatus" in SETTINGS, "iCloud Sync settings must have a status section.")
require("ICiCloudSyncSettingsSectionOptions" in SETTINGS, "iCloud Sync settings must have an options section.")
require("ICiCloudSyncSettingsSectionDevices" in SETTINGS, "iCloud Sync settings must have a devices section.")
require("ICiCloudSyncOptionRowEpisodes" in SETTINGS, "Episode sync option row is missing.")
require("ICiCloudSyncOptionRowSubscriptions" in SETTINGS, "Subscription sync option row is missing.")
require("ICiCloudSyncOptionRowSettings" in SETTINGS, "Settings sync option row is missing.")
require("performManualSyncWithCompletion" in SETTINGS and '"Sync Now".ls' in SETTINGS, "Manual sync UI must trigger CKSyncEngine.")
require("configureSyncNowCell:" in SETTINGS, "Sync Now cell must have explicit enabled/disabled state.")
require("cell.userInteractionEnabled = syncEnabled" in SETTINGS, "Sync Now must be disabled when no sync category is enabled.")
require("if (![ICiCloudSyncManager sharedManager].anySyncEnabled) { return; }" in SETTINGS, "Tapping disabled Sync Now must not trigger a sync.")
require("ICiCloudSyncDeviceInfo" in SETTINGS and '"Last Sync".ls' in SETTINGS, "Device list must show participating devices and last sync status.")
require('"No synced devices yet".ls' in SETTINGS, "Empty device state must make successful sync participation clear.")
require("iCloud Sync keeps selected data in sync through your private iCloud account." in SETTINGS, "iCloud Sync settings need clear user-facing option copy.")
require("Only devices that have successfully synced with at least one enabled category appear here." in SETTINGS, "Device section needs clear user-facing device copy.")

require("@available(iOS 17.0, *)" in APP_DELEGATE, "App delegate must not touch CKSyncEngine on older iOS.")
require("shouldHandleRemoteNotification:" in APP_DELEGATE, "App delegate must route CloudKit pushes to iCloud Sync.")
require("performBackgroundSyncWithCompletion:" in APP_DELEGATE, "App delegate must run background iCloud Sync for CloudKit pushes.")

for tag, key in zip(BACKUP_TAGS, SYNC_KEYS):
    require(f"<{tag}>" in EXPORTER and key in EXPORTER, f"Backup export must include {tag}.")
    require(f'"{tag}":' in IMPORTER and key in IMPORTER, f"Backup import must map {tag}.")
    require(f'"{tag}"' in IMPORTER.split("NSSet *boolKeys", 1)[1], f"Backup import must restore {tag} as a boolean.")

for strings, language in [(EN_STRINGS, "English"), (DE_STRINGS, "German")]:
    for key in ["iCloud Sync", "Sync Episodes", "Sync Subscriptions", "Sync Settings", "Sync Now", "Last Sync", "No synced devices yet", "iCloud prüfen…"]:
        require(f'"{key}" =' in strings, f"{language} localization is missing {key}.")
    for key in [
        "iCloud Sync keeps selected data in sync through your private iCloud account.",
        "Only devices that have successfully synced with at least one enabled category appear here.",
    ]:
        require(f'"{key}" =' in strings, f"{language} localization is missing clearer copy: {key}.")

require('"Sync Episodes" = "Folgen synchronisieren";' in DE_STRINGS, "German episode sync label is missing.")
require('"Sync Subscriptions" = "Abonnements synchronisieren";' in DE_STRINGS, "German subscription sync label is missing.")
require('"Sync Settings" = "Einstellungen synchronisieren";' in DE_STRINGS, "German settings sync label is missing.")
require('"No synced devices yet" = "Noch keine synchronisierten Geräte";' in DE_STRINGS, "German empty devices label is missing.")
