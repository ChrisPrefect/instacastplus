#!/usr/bin/env python3
"""Pins system metadata and capabilities for Siri media, SharePlay, and Handoff."""

import plistlib
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def plist(path: str):
    with (ROOT / path).open("rb") as handle:
        return plistlib.load(handle)


def strings(path: str):
    """Reads an old-style .strings table the way the build system does."""
    converted = subprocess.run(
        ["plutil", "-convert", "xml1", "-o", "-", str(ROOT / path)],
        capture_output=True,
    )
    require(converted.returncode == 0, f"Unreadable strings table: {path}")
    return plistlib.loads(converted.stdout)


info = plist("Resources-iPhone/Instacast-Info.plist")
ios_entitlements = plist("Instacast.entitlements")
mac_entitlements = plist("InstacastMac.entitlements")
project = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()
app_delegate = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()

require(
    ios_entitlements.get("com.apple.developer.siri") is True,
    "The iOS app must carry the Siri entitlement used by SiriKit media interactions.",
)
require(
    ios_entitlements.get("com.apple.developer.group-session") is True,
    "The iOS app must carry the Group Activities entitlement for SharePlay.",
)
require(
    mac_entitlements.get("com.apple.developer.group-session") is True,
    "The Catalyst app must carry the same Group Activities entitlement.",
)
require(
    "INPlayMediaIntent" in info.get("INIntentsSupported", []),
    "Info.plist must register the in-app Play Media handler.",
)
require(
    "INMediaCategoryPodcasts" in info.get("INSupportedMediaCategories", []),
    "Info.plist must identify InstacastPlus as a podcast media app.",
)
require(
    "com.iteconomy.instacastplus.playback" in info.get("NSUserActivityTypes", []),
    "Info.plist must register the playback Handoff activity type.",
)

definition_path = ROOT / "Resources-iPhone" / "Base.lproj" / "MediaSuggestions.intentdefinition"
require(definition_path.exists(), "The Play Media suggestions intent definition is missing.")
definition = plist("Resources-iPhone/Base.lproj/MediaSuggestions.intentdefinition")
require(definition.get("INIntentDefinitionSystem") is True, "The media definition must customize a system intent.")
intents = definition.get("INIntents", [])
require(
    len(intents) == 1 and intents[0].get("INIntentClassName") == "INPlayMediaIntent",
    "The suggestions definition must customize only INPlayMediaIntent.",
)
require(
    set(intents[0].get("INIntentParameterCombinations", {})) == {"mediaContainer"},
    "AirPods/Lock Screen suggestions require the mediaContainer-only supported combination.",
)
for token in [
    "Base.lproj/MediaSuggestions.intentdefinition",
    "en.lproj/MediaSuggestions.strings",
    "de.lproj/MediaSuggestions.strings",
    "ICSharePlayCoordinator.swift in Sources",
]:
    require(token in project, f"Xcode project missing iOS integration build entry: {token}")

for token in [
    "#import <Intents/Intents.h>",
    "INPlayMediaIntentHandling",
    "application:(UIApplication *)application handlerForIntent:(INIntent *)intent",
    "handlePlayMedia:(INPlayMediaIntent *)intent",
    "INMediaUserContext",
    "numberOfLibraryItems",
    "becomeCurrent",
]:
    require(token in app_delegate, f"The in-app Siri media integration is incomplete: {token}")

# ITMS-90626: every localization of the app must carry the intent's display strings.
# The App Store rejects a delivery whose custom intent has no localized title for a
# locale the app ships (seen for "de" in build 4.0 (37)).
definition_string_ids = set()


def collect_string_ids(node) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key.endswith("ID") and isinstance(value, str):
                definition_string_ids.add(value)
            collect_string_ids(value)
    elif isinstance(node, list):
        for item in node:
            collect_string_ids(item)


collect_string_ids(definition)
require(definition_string_ids, "The intent definition must expose localizable string IDs.")

for language in ("en", "de"):
    table_path = ROOT / "Resources-iPhone" / f"{language}.lproj" / "MediaSuggestions.strings"
    require(table_path.exists(), f"Missing {language} strings table for the media intent definition.")
    table = strings(f"Resources-iPhone/{language}.lproj/MediaSuggestions.strings")
    missing = sorted(definition_string_ids - set(table))
    require(not missing, f"Media intent strings for '{language}' miss: {missing}")
    empty = sorted(key for key, value in table.items() if not value.strip())
    require(not empty, f"Media intent strings for '{language}' are empty for: {empty}")

require(
    strings("Resources-iPhone/en.lproj/MediaSuggestions.strings")
    != strings("Resources-iPhone/de.lproj/MediaSuggestions.strings"),
    "The German media intent strings must be translated, not a copy of the English table.",
)

print("iOS integration metadata regression checks passed.")
