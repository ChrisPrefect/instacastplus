#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORTER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
IMPORTER_H = (ROOT / "Classes" / "InstacastBackupImporter.h").read_text()
IMPORT_UI = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text()
PROGRESS_VIEW = (ROOT / "Classes" / "ICBackupImportProgressView.m").read_text()
PARSER = (ROOT / "Classes" / "InstacastBackupParser.m").read_text()
DATA_H = (ROOT / "Classes" / "InstacastBackupData.h").read_text()
WATCH_MANAGER_H = (ROOT / "Classes" / "AppleWatchSyncManager.h").read_text()
WATCH_MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


missing_setting_tags = [
    "defaultSleepTimer",
    "allowDiagnostics",
    "amazonAffiliateEnabled",
    "widgetThemeDefaultActive",
    "widgetColorHex",
    "transcriptHighlightStyle",
    "appleWatchSendLatestCount",
    "appleWatchOnlyUnplayed",
    "mediaFilesSortMode",
    "transcriptionEngine",
    "transcriptionWhisperModel",
    "chapterGenerationModel",
    "transcriptionAutoDefault",
    "chapterAutoDefault",
    "autoSkipSponsors",
    "transcriptionEverActivated",
    "transcriptionFirstRunShown",
    "transcriptVisiblePreference",
    "podcastRefreshOnAppStart",
    "notifyRefreshFailure",
]

for tag in missing_setting_tags:
    require(f"<{tag}>" in EXPORTER, f"Backup export is missing <{tag}>.")
    require(f'"{tag}"' in IMPORTER, f"Backup import is missing {tag}.")

credential_tags = [
    "openAIAPIKey",
    "anthropicAPIKey",
    "kimiAPIKey",
    "openAIOAuthAccessToken",
    "openAIOAuthRefreshToken",
    "openAIOAuthIDToken",
    "openAIOAuthAccountID",
    "openAIOAuthAccountEmail",
    "openAIOAuthFedRAMP",
]

for tag in credential_tags:
    require(f'"{tag}"' in EXPORTER, f"Backup export is missing credential key {tag}.")
    require(f'"{tag}"' in IMPORTER, f"Backup import is missing credential key {tag}.")
    require(f'"{tag}"' in ENGINE, f"Credential store is missing backup support for {tag}.")

require("backupCredentialValues" in ENGINE, "Credential store must expose backupCredentialValues.")
require("restoreBackupCredentialValues" in ENGINE, "Credential store must expose restoreBackupCredentialValues.")
require("backupCredentialValues" in EXPORTER, "Exporter must read credential backup values.")
require("restoreBackupCredentialValues" in IMPORTER, "Importer must restore credential backup values.")

for tag in ["themeColorCode", "playerColorCode"]:
    require(f"<{tag}>" not in EXPORTER, f"Backup export must not write obsolete {tag} integer values.")

require(
    "ICBackupApplyColorHex(defaults, value, InterfaceThemeColorHexCode, InterfaceThemeColorCode)" in IMPORTER
    and "ICBackupApplyColorHex(defaults, value, PlayerThemeColorHexCode, PlayerThemeColorCode)" in IMPORTER
    and "ICBackupApplyColorHex(defaults, value, WidgetThemeColorHexCode, WidgetThemeColorCode)" in IMPORTER,
    "Color hex imports must update every app and widget color preference.",
)
require(
    "ic_setColorHexString:hexString" in IMPORTER and "NSKeyedArchiver" not in IMPORTER,
    "Color imports must persist canonical hex without recreating legacy UIKit archives.",
)

require("<appleWatchEpisodes>" in EXPORTER, "Backup export must include Apple Watch episode selections.")
for key in [
    "episodeHash",
    "feedIdentifier",
    "selectionSource",
    "watchAddedDate",
    "lastPhonePosition",
    "lastWatchPosition",
    "watchConsumed",
]:
    require(key in EXPORTER, f"Backup export is missing Apple Watch key {key}.")
    require(key in PARSER, f"Backup parser is missing Apple Watch key {key}.")
    require(key in DATA_H, f"Backup data model is missing Apple Watch key {key}.")

require("ICBackupImportAppleWatch" in IMPORTER_H, "Backup importer must define an Apple Watch import category.")
require("ICBackupImportAppleWatch" in IMPORTER, "Backup importer must run the Apple Watch import category.")
require("importAppleWatchEpisodesFromBackup" in IMPORTER, "Backup importer must restore Apple Watch episode selections.")
require("kRowAppleWatchEpisodes" in IMPORT_UI, "Backup import UI must expose Apple Watch episodes as a separate row.")
require("Apple Watch Episodes" in IMPORT_UI, "Backup import UI must label the Apple Watch episode row.")
require("ICBackupImportAppleWatch" in PROGRESS_VIEW, "Backup progress view must show Apple Watch episode import progress.")
require("syncCurrentSelectionsNow" in WATCH_MANAGER_H and "syncCurrentSelectionsNow" in WATCH_MANAGER, "Apple Watch import must sync restored selections without rebuilding automatic rules first.")
