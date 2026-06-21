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

# There is exactly ONE implementation of the settings-key filters (the nonisolated static
# one). The instance duplicates were removed on purpose: parallel copies are how the
# uid-key payload bug slipped in.
require("private func nonSettingsUserDefaultsKeys()" not in MANAGER, "Duplicate instance copy of nonSettingsUserDefaultsKeys must not come back.")
require("private func shouldSyncSettingsKey(" not in MANAGER, "Duplicate instance copy of shouldSyncSettingsKey must not come back.")
require("private func isValidSettingsValue(" not in MANAGER, "Duplicate instance copy of isValidSettingsValue must not come back.")

body = method_body(MANAGER, "private nonisolated static func nonSettingsUserDefaultsKeysForSyncEngineCallback() -> Set<String>")
for key in [
    '"DownloadResumeInfos"',
    '"DownloadResumeInfos_NSURLSession"',
    '"EpisodeLoadingQueueKey"',
    '"ICDiagnosticPreviousSessionEndedInBackground"',
    '"ICDiagnosticPreviousSessionEndedUnexpectedly"',
    '"ICDiagnosticPreviousSessionState"',
]:
    require(key in body, f"{key} must not be synced as an app setting.")

static_should_sync = method_body(MANAGER, "private nonisolated static func shouldSyncSettingsKeyForSyncEngineCallback")
require("nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key)" in static_should_sync, "SyncEngine app-settings payload must reject non-settings defaults keys.")
require('key.hasPrefix("ICiCloudSync")' in static_should_sync, "Sync-internal defaults keys must never be part of the settings payload (feedback-loop guard).")

static_valid = method_body(MANAGER, "private nonisolated static func isValidSettingsValueForSyncEngineCallback")
require("case is String, is NSNumber, is Date:" in static_valid, "Settings sync should only accept scalar preference values.")
require("is Data" not in static_valid, "Settings sync must not upload arbitrary Data blobs from UserDefaults.")
require("case let array" not in static_valid and "case let dictionary" not in static_valid, "Settings sync must not upload arrays/dictionaries from the whole defaults domain.")

# The value-writing core lives in adoptSettingsPayload (shared by the normal apply and
# the user's "use iCloud settings" choice from the enable dialog).
apply_remote = method_body(MANAGER, "private func adoptSettingsPayload")
require("Self.shouldSyncSettingsKeyForSyncEngineCallback(key)" in apply_remote, "Remote settings apply must not write excluded non-settings defaults keys.")
require("setStoredSyncedSettingsHash(syncedSettingsHash())" in apply_remote, "Remote settings apply must re-baseline the persisted hash (echo guard).")
require('logSyncEvent("Einstellungs-Payload ungültig"' in apply_remote, "Malformed remote settings payloads must be visible in customer diagnostics.")
require('"settingsValueCount"' in apply_remote and '"appliedSettingsValueCount"' in apply_remote, "Remote settings adoption logs must show how many values arrived and were applied.")

adopt_choice = method_body(MANAGER, "@objc func resolveInitialSettingsAdoptingCloud")
require('logSyncEvent("Einstellungs-Wahl: iCloud-Stand fehlt"' in adopt_choice, "Choosing iCloud settings with no parked payload must be logged instead of silently doing nothing.")
require('"hasCredentials"' in adopt_choice and '"settingsValueCount"' in adopt_choice, "The explicit iCloud-settings adoption choice must log payload shape.")

# The baseline hash must be persisted — an in-memory baseline re-uploaded the whole
# settings record on every app start with a fresh updatedAt, breaking last-writer-wins.
queue_check = method_body(MANAGER, "private func checkAndQueueSettingsChange")
require("storedSyncedSettingsHash()" in queue_check, "Settings queueing must compare against the persisted baseline hash.")
require("private var lastSyncedSettingsHash" not in MANAGER, "The in-memory settings hash baseline must not come back.")
