#!/usr/bin/env python3
"""Regression contract for local/server transcription settings separation."""

from pathlib import Path
import plistlib
import re


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


settings = read("Classes/TranscriptionSettingsViewController.m")
defines_h = read("Classes/Defines.h")
defines_m = read("Classes/Defines.m")
queue = read("Classes/TranscriptionQueue.swift")
episode_list = read("Classes/EpisodesTableViewController.m")
episode_detail = read("Classes/EpisodeViewController.m")
models = read("Classes/TranscriptionEngine.swift")
backup_export = read("Classes/ImportExportSettingsViewController.m")
backup_import = read("Classes/InstacastBackupImporter.m")
german = read("Resources/de.lproj/Localizable.strings")
english = read("Resources/en.lproj/Localizable.strings")
project = read("Instacast.xcodeproj/project.pbxproj")

require(
    "kLocalTranscriptionEnabled" in defines_h
    and 'NSString* kLocalTranscriptionEnabled = @"LocalTranscriptionEnabled";' in defines_m,
    "The local transcription enablement setting has no shared source of truth.",
)

for relative in ("Resources/Defaults.plist", "Resources-iPad/Defaults.plist"):
    with (ROOT / relative).open("rb") as handle:
        defaults = plistlib.load(handle)
    require(
        defaults.get("LocalTranscriptionEnabled") is True,
        f"{relative} must preserve existing local transcription behavior by default.",
    )

require(
    "ICTranscriptionSettingsPageHub" in settings
    and "ICTranscriptionSettingsPageLocal" in settings
    and "ICTranscriptionSettingsPageServer" in settings,
    "Transcription settings are not split into hub, local and prepared server pages.",
)
require(
    'NSLocalizedString(@"Lokale Transkription", nil)' in settings
    and 'NSLocalizedString(@"Serverbasierte Transkription", nil)' in settings
    and "ICTranscriptionSettingsPageServer" in settings
    and "_serverTranscriptionToggle:" in settings
    and "kServerTranscriptionEnabled" in settings
    and "_pushAutomaticBackendChooser" in settings,
    "The settings hub does not expose configured local/server pages and one automatic backend selector.",
)
require(
    re.search(r"TSSectionEnabled\s*=\s*0", settings)
    and "_localTranscriptionToggle:" in settings
    and "kLocalTranscriptionEnabled" in settings,
    "Local transcription enablement is not the first setting on the local page.",
)

require(
    "localTranscriptionEnabled" in backup_export
    and "kLocalTranscriptionEnabled" in backup_export
    and '@"localTranscriptionEnabled": kLocalTranscriptionEnabled' in backup_import
    and '"localTranscriptionEnabled"' in backup_import,
    "Backup export/import is not symmetric for local transcription enablement.",
)

require(
    "guard UserDefaults.standard.bool(forKey: kLocalTranscriptionEnabled)" in queue,
    "The queue can still create local transcription/chapter jobs while the feature is disabled.",
)
require(
    episode_list.count("boolForKey:kLocalTranscriptionEnabled") >= 2
    and episode_detail.count("boolForKey:kLocalTranscriptionEnabled") >= 1,
    "Not every episode action surface removes local transcription/chapter creation when disabled.",
)

for old_notice in (
    "Sendet das vollständige Transkript an OpenAI",
    "Sendet das vollständige Transkript an Anthropic",
    "Sendet das vollständige Transkript an Kimi",
    "mindestens 30 Tage bei OpenAI gespeichert",
):
    require(old_notice not in models, f"Obsolete provider notice remains in model details: {old_notice}")

for expected_detail in (
    "Beste lokale Genauigkeit",
    "Schneller und sparsamer",
    "Kostenlos · Verarbeitung auf dem Gerät",
    "Geschätzte Kosten pro 1 h Transkript",
):
    require(expected_detail in models, f"Model selection lacks useful performance/cost guidance: {expected_detail}")

require(
    'detail: NSLocalizedString("Kein Download in der App."' not in models
    and 'return [NSString stringWithFormat:@"%@\\n%@", NSLocalizedString(@"Kein Download erforderlich."' not in settings,
    "Apple model rows still repeat download status instead of showing useful selection guidance.",
)
require(
    "self.tableView.rowHeight = UITableViewAutomaticDimension;" in settings
    and "self.tableView.estimatedRowHeight" in settings,
    "The longer model guidance can still be clipped to the old fixed row height.",
)

for localized in (german, english):
    for key in (
        "Lokale Transkription",
        "Serverbasierte Transkription",
        "Lokale Transkription aktivieren",
        "Serverbasierte Transkription aktivieren",
        "Automatische Transkription",
    ):
        require(f'"{key}" =' in localized, f"Missing DE/EN localization key: {key}")

versions = re.findall(r"MARKETING_VERSION = ([^;]+);", project)
require(versions and set(versions) == {"4.0"}, "Every target/configuration must use marketing version 4.0.")

print("Local/server transcription settings regression checks passed.")
