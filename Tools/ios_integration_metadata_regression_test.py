#!/usr/bin/env python3
"""Pins system metadata and capabilities for Siri media, SharePlay, and Handoff."""

import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def plist(path: str):
    with (ROOT / path).open("rb") as handle:
        return plistlib.load(handle)


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

definition_path = ROOT / "Resources-iPhone" / "MediaSuggestions.intentdefinition"
require(definition_path.exists(), "The Play Media suggestions intent definition is missing.")
definition = plist("Resources-iPhone/MediaSuggestions.intentdefinition")
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
    "MediaSuggestions.intentdefinition",
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

print("iOS integration metadata regression checks passed.")
