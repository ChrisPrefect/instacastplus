#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker=None):
    # Brace-matching extraction: the old "cut at the next private member" heuristic broke
    # when the manager was split into files and member access became internal.
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


MANAGER = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])

# There is exactly ONE implementation of the settings-key filters (the nonisolated static
# one). The instance duplicates were removed on purpose: parallel copies are how the
# uid-key payload bug slipped in.
require("func nonSettingsUserDefaultsKeys()" not in MANAGER, "Duplicate instance copy of nonSettingsUserDefaultsKeys must not come back.")
require("func shouldSyncSettingsKey(" not in MANAGER, "Duplicate instance copy of shouldSyncSettingsKey must not come back.")
require("func isValidSettingsValue(" not in MANAGER, "Duplicate instance copy of isValidSettingsValue must not come back.")

body = method_body(MANAGER, "nonisolated static func nonSettingsUserDefaultsKeysForSyncEngineCallback() -> Set<String>")
for key in [
    '"DownloadResumeInfos"',
    '"DownloadResumeInfos_NSURLSession"',
    '"EpisodeLoadingQueueKey"',
    '"ICDiagnosticPreviousSessionEndedInBackground"',
    '"ICDiagnosticPreviousSessionEndedUnexpectedly"',
    '"ICDiagnosticPreviousSessionState"',
    '"FTSIndexVersion"',
]:
    require(key in body, f"{key} must not be synced as an app setting.")

static_should_sync = method_body(MANAGER, "nonisolated static func shouldSyncSettingsKeyForSyncEngineCallback")
require("nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key)" in static_should_sync, "SyncEngine app-settings payload must reject non-settings defaults keys.")
require('key.hasPrefix("ICiCloudSync")' in static_should_sync, "Sync-internal defaults keys must never be part of the settings payload (feedback-loop guard).")

static_valid = method_body(MANAGER, "nonisolated static func isValidSettingsValueForSyncEngineCallback")
require("case is String, is NSNumber, is Date:" in static_valid, "Settings sync should only accept scalar preference values.")
require("is Data" not in static_valid, "Settings sync must not upload arbitrary Data blobs from UserDefaults.")
require("case let array" not in static_valid and "case let dictionary" not in static_valid, "Settings sync must not upload arrays/dictionaries from the whole defaults domain.")

# The value-writing core lives in adoptSettingsPayload (shared by the normal apply and
# the user's "use iCloud settings" choice from the enable dialog).
apply_remote = method_body(MANAGER, "func adoptSettingsPayload")
require("Self.shouldSyncSettingsKeyForSyncEngineCallback(key)" in apply_remote, "Remote settings apply must not write excluded non-settings defaults keys.")
require("setStoredSyncedSettingsHash(syncedSettingsHash())" in apply_remote, "Remote settings apply must re-baseline the persisted hash (echo guard).")
require('logSyncEvent("Einstellungs-Payload ungültig"' in apply_remote, "Malformed remote settings payloads must be visible in customer diagnostics.")
require('"settingsValueCount"' in apply_remote and '"appliedSettingsValueCount"' in apply_remote, "Remote settings adoption logs must show how many values arrived and were applied.")

adopt_choice = method_body(MANAGER, "@objc func resolveInitialSettingsAdoptingCloud")
require('logSyncEvent("Einstellungs-Wahl: iCloud-Stand fehlt"' in adopt_choice, "Choosing iCloud settings with no parked payload must be logged instead of silently doing nothing.")
require('"hasCredentials"' in adopt_choice and '"settingsValueCount"' in adopt_choice, "The explicit iCloud-settings adoption choice must log payload shape.")

# The baseline hash must be persisted — an in-memory baseline re-uploaded the whole
# settings record on every app start with a fresh updatedAt, breaking last-writer-wins.
queue_check = method_body(MANAGER, "func checkAndQueueSettingsChange")
require("storedSyncedSettingsHash()" in queue_check, "Settings queueing must compare against the persisted baseline hash.")
require("var lastSyncedSettingsHash" not in MANAGER, "The in-memory settings hash baseline must not come back.")

# Device-local playback restore state must never travel as a "setting" (08.07.): syncing
# PlaybackEpisode dirtied the settings hash on every episode switch (one settings upload
# per change) and made other devices restore this device's episode after a restart.
transient_keys = method_body(MANAGER, "nonisolated static func transientSettingsKeysForSyncEngineCallback")
for key in ('"PlaybackEpisode"', '"PlaybackPlaylist"', '"PlaybackSourceList"',
            '"TotalEpisodesPlayedCount"', '"TotalListeningTime"', '"SleepTimerFellAsleepCount"'):
    require(key in transient_keys, f"{key} must be excluded from settings sync (device-local playback state).")
print("settings payload regression checks passed")
