#!/usr/bin/env python3
"""Pins lossless, explicitly typed podcast-setting backup round trips."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATA_H = (ROOT / "Classes" / "InstacastBackupData.h").read_text()
PARSER = (ROOT / "Classes" / "InstacastBackupParser.m").read_text()
EXPORTER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("settingTypes" in DATA_H,
        "Parsed podcast settings need a parallel type map so XML values are not guessed from their text.")
for value_type in ("string", "double", "integer", "bool"):
    require(f'type=\\"{value_type}\\"' in EXPORTER,
            f"Podcast setting export must explicitly identify {value_type} values.")

require('NSString *type = attrs[@"type"]' in PARSER and
        "_currentPodcast.settingTypes[key] = type" in PARSER,
        "The backup parser must retain each explicit podcast-setting type.")
require("podcast.settingTypes[originalKey]" in IMPORTER,
        "The importer must apply the type recorded for the original backup key.")
for assignment in ("property.stringValue = value", "property.doubleValue = doubleValue",
                   "property.int32Value = integerValue", "property.boolValue = boolValue"):
    require(assignment in IMPORTER, f"Typed podcast settings must route through {assignment}.")
require("property.stringValue = nil" in IMPORTER and "property.doubleValue = 0" in IMPORTER and
        "property.int32Value = 0" in IMPORTER and "property.boolValue = NO" in IMPORTER,
        "Importing one setting type must clear stale values left in the other Core Data fields.")

require("rangeOfString:@\".\"" not in IMPORTER.split("#pragma mark - Feed Settings", 1)[1].split("#pragma mark - Bookmarks", 1)[0],
        "A decimal point is not a type marker: URLs and chapter names must never be classified as doubles from their contents.")
require("_auto_skip_chapter_name" in IMPORTER and "preferredTranscriptURL" in IMPORTER,
        "Legacy untyped backups must preserve known string-valued podcast settings.")
require("_auto_skip_start_period" in IMPORTER and "_auto_skip_end_period" in IMPORTER,
        "Legacy untyped backups must preserve known double-valued podcast settings.")

print("Backup feed-setting type regression checks passed")
