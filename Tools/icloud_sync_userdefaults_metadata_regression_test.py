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
APP_DELEGATE = read("Classes/InstacastAppDelegate.m")

for key in [
    "engineStateKey",
    "knownRecordsKey",
    "deviceCacheKey",
    "subscriptionRecordURLsKey",
    "pendingEpisodeStatesKey",
    "pendingSubscriptionPayloadsKey",
    "episodeLocalModifiedDatesKey",
    "subscriptionLocalModifiedDatesKey",
]:
    require(key in MANAGER, f"{key} must remain explicit iCloud sync metadata.")
    require(key in method_body(MANAGER, "private nonisolated static var fileBackedSyncMetadataKeys"), f"{key} must be file-backed, not stored in UserDefaults.")

set_sync_metadata = method_body(MANAGER, "private func setSyncMetadata")
require("Self.isFileBackedSyncMetadataKey(key)" in set_sync_metadata, "Large iCloud metadata writes must branch away from UserDefaults.")
require("Self.writeSyncMetadataValue" in set_sync_metadata, "Large iCloud metadata must be written to files.")
require("defaults.set(value, forKey: key)" not in source_between(set_sync_metadata, "if let value {", "} else {"), "setSyncMetadata must not blindly write all values into UserDefaults.")
require("NSLog" in set_sync_metadata and "iCloudSync metadata" in set_sync_metadata, "iCloud metadata writes must emit console diagnostics with key/size/thread.")

require("private nonisolated static func syncMetadataValue(forKey key: String) -> Any?" in MANAGER, "File-backed iCloud metadata needs a shared read path.")
require("private nonisolated static func writeSyncMetadataValue" in MANAGER, "File-backed iCloud metadata needs a shared write path.")
require("private nonisolated static func removeSyncMetadataValue" in MANAGER, "File-backed iCloud metadata needs a shared remove path.")
require("knownRecordSystemFieldsDirectoryName" in MANAGER, "CKRecord system fields must be stored as per-record files, not one huge knownRecords blob.")
require("knownRecordSystemFieldsData(forRecordName:" in MANAGER, "CKSyncEngine record materialization must read only the requested known record system fields.")
require("writeKnownRecordSystemFields" in MANAGER, "Remembering a server record must write only that record's system fields.")
require("removeKnownRecordSystemFields" in MANAGER, "Forgetting a server record must remove only that record's system fields.")
require("@objc nonisolated static func logSyncMetadataStorageSnapshot" in MANAGER, "iCloud metadata storage snapshots must be available for TestFlight crash-log diagnosis without touching the manager actor.")
require("migrateLegacySyncMetadataOutOfUserDefaults" not in MANAGER, "iCloud sync is unreleased; do not ship legacy metadata migration.")
require("logPendingLegacySyncMetadataMigrationSummary" not in MANAGER, "iCloud sync is unreleased; do not keep migration diagnostics.")
require("legacyUserDefaultsPlistURL" not in MANAGER, "iCloud sync is unreleased; no direct legacy defaults migration path is needed.")

sync_metadata_value = method_body(MANAGER, "private nonisolated static func syncMetadataValue")
require("if key == knownRecordsKey" in sync_metadata_value, "knownRecords must not be loaded as one dictionary blob.")
file_backed_branch = source_between(sync_metadata_value, "if isFileBackedSyncMetadataKey(key) {", "\n        return UserDefaults.standard.object(forKey: key)")
require("UserDefaults.standard.object(forKey: key)" not in file_backed_branch, "File-backed metadata reads must not fall back to legacy UserDefaults.")
remember_server_record = method_body(MANAGER, "private func rememberServerRecord")
forget_server_record = method_body(MANAGER, "private func forgetServerRecord")
require("knownRecords()" not in remember_server_record and "setSyncMetadata(records, forKey: Self.knownRecordsKey)" not in remember_server_record, "rememberServerRecord must not rewrite a full knownRecords dictionary.")
require("knownRecords()" not in forget_server_record and "setSyncMetadata(records, forKey: Self.knownRecordsKey)" not in forget_server_record, "forgetServerRecord must not rewrite a full knownRecords dictionary.")

launch = method_body(APP_DELEGATE, "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions", "\n    [App initializeLoggers]")
initialize = method_body(APP_DELEGATE, "+ (void) initialize", "\n\n#pragma mark -")
initialize_before_defaults = source_between(initialize, "{", "NSUserDefaults* defs = [NSUserDefaults standardUserDefaults];")
require("migrateLegacySyncMetadataOutOfUserDefaults" not in initialize_before_defaults, "AppDelegate +initialize must not run iCloud legacy migration.")
post_logger_start = method_body(APP_DELEGATE, "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions", "\n    [[ICDiagnosticLogger shared] recordLifecycle")
require("logPendingLegacySyncMetadataMigrationSummary" not in post_logger_start, "Launch must not log removed migration diagnostics.")
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
