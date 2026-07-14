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
APP_DELEGATE = read("Classes/InstacastAppDelegate.m")

file_backed_keys = method_body(MANAGER, "nonisolated static var fileBackedSyncMetadataKeys")
for key in [
    "engineStateKey",
    "knownRecordsKey",
    "deviceCacheKey",
    "pendingEpisodeStatesKey",
    "pendingSubscriptionPayloadsKey",
    "pendingSubscriptionFetchCompleteKey",
    "transitionalSubscriptionInventoryRecordsKey",
]:
    require(key in MANAGER, f"{key} must remain explicit iCloud sync metadata.")
    require(key in file_backed_keys, f"{key} must be file-backed, not stored in UserDefaults.")

legacy_row_keys = [
    "subscriptionRecordURLsKey",
    "subscriptionLocalModifiedDatesKey",
    "subscriptionLocalStatesKey",
    "subscriptionPayloadHashesKey",
    "episodeLocalModifiedDatesKey",
]
for key in legacy_row_keys:
    require(key in MANAGER, f"{key} must remain readable for migration from the last App Store version.")
    require(key not in file_backed_keys,
            f"{key} is migration input, not active whole-library metadata that launch cleanup may purge: {key}")

set_sync_metadata = method_body(MANAGER, "func setSyncMetadata")
require("Self.isFileBackedSyncMetadataKey(key)" in set_sync_metadata, "Large iCloud metadata writes must branch away from UserDefaults.")
require("Self.writeSyncMetadataValue" in set_sync_metadata, "Large iCloud metadata must be written to files.")
require("defaults.set(value, forKey: key)" not in source_between(set_sync_metadata, "if let value {", "} else {"), "setSyncMetadata must not blindly write all values into UserDefaults.")
# Per-write metadata logging was removed: logging every write (plus a synchronous NSLog) once
# flooded the diagnostics log to 26 MB and spammed the console on the main thread. Only genuine
# write failures may be logged now.
require("NSLog" not in set_sync_metadata, "setSyncMetadata must not log every write (this flooded the diagnostics log).")
require("write-failed" in set_sync_metadata, "Genuine iCloud metadata write failures must still be logged.")

require("nonisolated static func syncMetadataValue(forKey key: String) -> Any?" in MANAGER, "File-backed iCloud metadata needs a shared read path.")
require("nonisolated static func writeSyncMetadataValue" in MANAGER, "File-backed iCloud metadata needs a shared write path.")
require("nonisolated static func removeSyncMetadataValue" in MANAGER, "File-backed iCloud metadata needs a shared remove path.")
require("knownRecordSystemFieldsEntityName" in MANAGER,
        "CKRecord system fields must use the account-scoped indexed Core Data store.")
require("knownRecordSystemFieldsForSyncEngineCallback" in MANAGER,
        "CKSyncEngine materialization must load only its current bounded record page.")
require("persistKnownRecordSystemFields" in MANAGER,
        "Remembering server system fields must use a durable bounded transaction.")
require("removeKnownRecordSystemFields" in MANAGER,
        "Forgetting server system fields must use an account-scoped bounded transaction.")
require("migrateLegacyKnownRecordSystemFieldsIfNeeded" in MANAGER,
        "Existing per-record files must migrate after CloudKit verifies the account.")
require("@objc nonisolated static func logSyncMetadataStorageSnapshot" in MANAGER, "iCloud metadata storage snapshots must be available for TestFlight crash-log diagnosis without touching the manager actor.")
require("migrateLegacySyncItemMetadataIfNeeded" in MANAGER,
        "The indexed row store must migrate customers from the last App Store version.")
legacy_reader = method_body(MANAGER, "nonisolated static func legacySyncItemMetadataWrites")
require("UserDefaults.standard.object(forKey: key)" in legacy_reader,
        "Migration must read legacy dictionaries that still live in UserDefaults.")
require("syncMetadataFileURL(forKey: key)" in legacy_reader,
        "Migration must also resume from the intermediate file-backed dictionaries.")

purge = method_body(MANAGER, "@objc nonisolated static func purgeLegacyDefaultsBackedSyncMetadata")
for active_key in [
    "initialEpisodeBackfillOffsetKey",
    "initialSubscriptionBackfillOffsetKey",
    "initialEpisodeBackfillCursorKey",
    "initialSubscriptionBackfillCursorKey",
    "initialSettingsBackfillPendingKey",
]:
    require(
        active_key not in purge,
        f"Launch cleanup must preserve the active resumable sync state {active_key}.",
    )
for legacy_key in legacy_row_keys:
    require(legacy_key not in file_backed_keys,
            f"Launch cleanup must preserve {legacy_key} until its indexed-row migration commits.")

sync_metadata_value = method_body(MANAGER, "nonisolated static func syncMetadataValue")
require("if key == knownRecordsKey" in sync_metadata_value, "knownRecords must not be loaded as one dictionary blob.")
file_backed_branch = source_between(sync_metadata_value, "if isFileBackedSyncMetadataKey(key) {", "\n        return UserDefaults.standard.object(forKey: key)")
require("UserDefaults.standard.object(forKey: key)" not in file_backed_branch, "File-backed metadata reads must not fall back to legacy UserDefaults.")
persist_system_fields = method_body(MANAGER, "nonisolated static func persistKnownRecordSystemFields")
remove_system_fields = method_body(MANAGER, "nonisolated static func removeKnownRecordSystemFields")
require("knownRecords()" not in persist_system_fields + remove_system_fields
        and "setSyncMetadata(records, forKey: Self.knownRecordsKey)" not in persist_system_fields + remove_system_fields,
        "System-field row transactions must not revive the obsolete full knownRecords dictionary.")

launch = method_body(APP_DELEGATE, "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions", "\n    [App initializeLoggers]")
initialize = method_body(APP_DELEGATE, "+ (void) initialize", "\n\n#pragma mark -")
initialize_before_defaults = source_between(initialize, "{", "NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];")
require("purgeLegacyDefaultsBackedSyncMetadata" in initialize_before_defaults,
        "AppDelegate +initialize may purge obsolete defaults copies only for currently file-backed keys.")
post_logger_start = method_body(APP_DELEGATE, "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions", "\n    [[ICDiagnosticLogger shared] recordLifecycle")
require("logSyncMetadataStorageSnapshot" in APP_DELEGATE, "Launch must log a compact iCloud metadata storage snapshot for future crash-log mails.")

for bad_read in [
    "UserDefaults.standard.dictionary(forKey: Self.knownRecordsKey)",
    "UserDefaults.standard.dictionary(forKey: Self.subscriptionRecordURLsKey)",
    "UserDefaults.standard.dictionary(forKey: Self.episodeLocalModifiedDatesKey)",
    "UserDefaults.standard.dictionary(forKey: Self.subscriptionLocalModifiedDatesKey)",
    "defaults.dictionary(forKey: Self.knownRecordsKey)",
    "defaults.dictionary(forKey: Self.subscriptionRecordURLsKey)",
    "defaults.dictionary(forKey: Self.episodeLocalModifiedDatesKey)",
    "defaults.dictionary(forKey: Self.subscriptionLocalModifiedDatesKey)",
]:
    require(bad_read not in MANAGER, f"Large metadata read still bypasses file-backed storage: {bad_read}")
