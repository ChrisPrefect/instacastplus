#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker="\n    private"):
    require(signature in source, f"{signature} is missing.")
    return source.split(signature, 1)[1].split(next_marker, 1)[0]


MANAGER = read("Classes/ICiCloudSyncManager.swift")

for signature in [
    "private nonisolated static func nonSettingsUserDefaultsKeysForSyncEngineCallback() -> Set<String>",
    "private func nonSettingsUserDefaultsKeys() -> Set<String>",
]:
    body = method_body(MANAGER, signature)
    for key in [
        '"DownloadResumeInfos"',
        '"DownloadResumeInfos_NSURLSession"',
        '"EpisodeLoadingQueueKey"',
        '"ICDiagnosticPreviousSessionEndedUnexpectedly"',
        '"ICDiagnosticPreviousSessionState"',
    ]:
        require(key in body, f"{key} must not be synced as an app setting.")

static_should_sync = method_body(MANAGER, "private nonisolated static func shouldSyncSettingsKeyForSyncEngineCallback")
instance_should_sync = method_body(MANAGER, "private func shouldSyncSettingsKey")
require("nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key)" in static_should_sync, "SyncEngine app-settings payload must reject non-settings defaults keys.")
require("nonSettingsUserDefaultsKeys().contains(key)" in instance_should_sync, "MainActor app-settings payload must reject non-settings defaults keys.")

static_valid = method_body(MANAGER, "private nonisolated static func isValidSettingsValueForSyncEngineCallback")
instance_valid = method_body(MANAGER, "private func isValidSettingsValue")
for body in [static_valid, instance_valid]:
    require("case is String, is NSNumber, is Date:" in body, "Settings sync should only accept scalar preference values.")
    require("is Data" not in body, "Settings sync must not upload arbitrary Data blobs from UserDefaults.")
    require("case let array" not in body and "case let dictionary" not in body, "Settings sync must not upload arrays/dictionaries from the whole defaults domain.")

apply_remote = method_body(MANAGER, "private func applyRemoteAppSettings")
require("shouldSyncSettingsKey(key)" in apply_remote, "Remote settings apply must not write excluded non-settings defaults keys.")
