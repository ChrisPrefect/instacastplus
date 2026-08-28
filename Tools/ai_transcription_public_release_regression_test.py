#!/usr/bin/env python3
"""Pins the public-release gate for AI transcription and chapter generation."""

from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


defines_h = read("Classes/Defines.h")
defines_m = read("Classes/Defines.m")
options = read("Classes/OptionsViewController.m")
feed_settings = read("Classes/FeedSettingsViewController.m")
transcription_settings = read("Classes/TranscriptionSettingsViewController.m")
appearance = read("Classes/AppearanceSettingsViewController.m")
episode_list = read("Classes/EpisodesTableViewController.m")
episode_detail = read("Classes/EpisodeViewController.m")
episode_cell = read("Classes/EpisodesTableViewCell.m")
sidebar = read("Classes/MainViewController_4.m")
queue = read("Classes/TranscriptionQueue.swift")
server_queue = read("Classes/ServerTranscriptionManager.swift")
changelog = read("Classes/ChangeLogViewController.m")
player = read("Classes/PlayerInfoViewController_v5.m")
scheme = ET.parse(ROOT / "Instacast.xcodeproj/xcshareddata/xcschemes/Instacast.xcscheme").getroot()

launch_action = scheme.find("LaunchAction")
archive_action = scheme.find("ArchiveAction")
require(
    launch_action is not None
    and launch_action.get("buildConfiguration") == "Debug",
    "The shared Xcode Run action must use Debug so device development builds expose transcription.",
)
require(
    archive_action is not None
    and archive_action.get("buildConfiguration") == "Release",
    "The shared Xcode Archive action must remain Release so App Store builds hide transcription by default.",
)

for relative in ("Resources/Defaults.plist", "Resources-iPad/Defaults.plist"):
    with (ROOT / relative).open("rb") as handle:
        defaults = plistlib.load(handle)
    require(defaults.get("LocalTranscriptionEnabled") is False,
            f"{relative} must default local AI transcription to off.")
    require(defaults.get("ServerTranscriptionEnabled") is False,
            f"{relative} must default server AI transcription to off.")
    require(defaults.get("TranscriptionAutoDefault") is False,
            f"{relative} must explicitly default automatic transcription to off.")
    require(defaults.get("ChapterAutoDefault") is False,
            f"{relative} must explicitly default automatic chapter generation to off.")

require(
    "BOOL ICAITranscriptionFeaturesAvailable(void);" in defines_h
    and "BOOL ICAITranscriptionFeaturesEnabled(void);" in defines_h
    and "BOOL ICAITranscriptionFeaturesAvailable(void)" in defines_m
    and "BOOL ICAITranscriptionFeaturesEnabled(void)" in defines_m
    and "#if defined(CONFIGURATION_Release) && !defined(IC_TRANSCRIPTION_TESTFLIGHT_BUILD)" in defines_m
    and "return NO;" in defines_m
    and "return YES;" in defines_m,
    "AI transcription needs shared availability and user-enabled feature gates.",
)

require(
    "boolForKey:kLocalTranscriptionEnabled" in defines_m
    and "boolForKey:kServerTranscriptionEnabled" in defines_m,
    "The user-enabled AI gate must require at least one active transcription backend.",
)

require(
    "if (!ICAITranscriptionFeaturesAvailable() && row >= kRowTranscription)" in options
    and "if (!ICAITranscriptionFeaturesAvailable())" in options,
    "The public Settings list still exposes Transcription and Chapters.",
)
require(
    "case kTranscriptionSection:\n            return ICAITranscriptionFeaturesEnabled() ? 3 : 0;" in feed_settings
    and "case kTranscriptionSection:\n            return ICAITranscriptionFeaturesEnabled()" in feed_settings,
    "Per-podcast AI transcription settings are still visible when transcription is disabled.",
)
require(
    "if (ICAITranscriptionFeaturesEnabled())" in appearance
    and "case ICEpisodeSwipeActionTranscribe:" in appearance
    and 'return @"Disabled".ls;' in appearance,
    "The configurable Transcribe swipe action is still exposed when transcription is disabled.",
)
require(
    episode_list.count("ICAITranscriptionFeaturesEnabled()") >= 3
    and episode_detail.count("ICAITranscriptionFeaturesEnabled()") >= 1,
    "Episode swipe, long-press, or detail menus still expose AI actions in public releases or when both backends are disabled.",
)
require(
    "if (!ICAITranscriptionFeaturesAvailable())" in episode_cell,
    "Self-generated transcript indicators remain visible in public episode lists.",
)
require(
    "ICAITranscriptionFeaturesEnabled() && [TranscriptionQueue shared].hasVisibleItems" in sidebar
    and "if (!ICAITranscriptionFeaturesEnabled())" in sidebar,
    "The transcription queue remains reachable from the sidebar when transcription is disabled.",
)
require(
    "ICTranscriptionSettingsDidChangeNotification" in defines_h
    and "ICTranscriptionSettingsDidChangeNotification" in defines_m
    and transcription_settings.count("ICTranscriptionSettingsDidChangeNotification") >= 2
    and "name:ICTranscriptionSettingsDidChangeNotification" in sidebar,
    "The sidebar does not update immediately when a transcription backend setting changes.",
)
require(
    "savedMainSidebarItemTag > 0 && [self _selectMainSidebarItemWithTag:savedMainSidebarItemTag]" in sidebar,
    "A saved transcription sidebar selection does not fall back to Podcasts when the public gate hides it.",
)
require(
    queue.count("ICAITranscriptionFeaturesAvailable()") >= 4
    and server_queue.count("ICAITranscriptionFeaturesAvailable()") >= 4,
    "Hidden AI queues can still enqueue or resume work in a public release.",
)
require(
    "if (ICAITranscriptionFeaturesAvailable())" in changelog,
    "The public changelog still advertises hidden AI transcription features.",
)

# Publisher-provided transcripts and their player search are deliberately outside
# the AI gate and must remain available.
require(
    "episode.transcripts" in player
    and "_transcriptSearchTextChanged:" in player
    and "ICAITranscriptionFeaturesAvailable" not in player,
    "Publisher transcripts or in-player transcript search were coupled to the AI gate.",
)

print("AI transcription public-release regression checks passed.")
