#!/usr/bin/env python3
import plistlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


DEFINES_H = read("Classes/Defines.h")
DEFINES_M = read("Classes/Defines.m")
SCENE_DELEGATE = read("Classes/InstacastSceneDelegate.m")
FEED_OPTIONS = read("Classes/FeedOptionsViewController.m")
FEED_SETTINGS = read("Classes/FeedSettingsViewController.m")
EXPORTER = read("Classes/ImportExportSettingsViewController.m")
IMPORTER = read("Classes/InstacastBackupImporter.m")
EN_STRINGS = read("Resources/en.lproj/Localizable.strings")
DE_STRINGS = read("Resources/de.lproj/Localizable.strings")

DEFAULTS = plistlib.loads((ROOT / "Resources/Defaults.plist").read_bytes())
IPAD_DEFAULTS = plistlib.loads((ROOT / "Resources-iPad/Defaults.plist").read_bytes())


require("extern NSString* PodcastRefreshOnAppStart;" in DEFINES_H, "Podcast refresh startup key is missing from Defines.h.")
require(
    'NSString* PodcastRefreshOnAppStart = @"PodcastRefreshOnAppStart";' in DEFINES_M,
    "Podcast refresh startup key is missing from Defines.m.",
)
require(DEFAULTS.get("PodcastRefreshOnAppStart") is False, "PodcastRefreshOnAppStart must default off in Resources/Defaults.plist.")
require(
    IPAD_DEFAULTS.get("PodcastRefreshOnAppStart") is False,
    "PodcastRefreshOnAppStart must default off in Resources-iPad/Defaults.plist.",
)

require("kRefreshSection" in FEED_OPTIONS and "kFeedsSection" in FEED_OPTIONS, "Podcast settings must keep the refresh switch above the feed list.")
require('"Podcast-Refresh bei App-Start".ls' in FEED_OPTIONS, "Podcast settings must show the startup refresh switch.")
require(
    "[USER_DEFAULTS boolForKey:PodcastRefreshOnAppStart]" in FEED_OPTIONS
    and "[USER_DEFAULTS setBool:switchControl.on forKey:PodcastRefreshOnAppStart]" in FEED_OPTIONS,
    "Startup refresh switch must read and write PodcastRefreshOnAppStart.",
)
require(
    "Automatically refresh podcasts when opening the app or returning to it. Manual refreshes, push updates, and iOS background fetch are unaffected." in FEED_OPTIONS,
    "Startup refresh switch needs a footer explaining its exact scope.",
)

auto_refresh_block = SCENE_DELEGATE.split("- (void) _autoRefreshFeedsIfNeeded", 1)[1].split("- (void)sceneDidEnterBackground", 1)[0]
require(
    "if (![USER_DEFAULTS boolForKey:PodcastRefreshOnAppStart])" in auto_refresh_block,
    "App-start/foreground refresh must be gated by PodcastRefreshOnAppStart.",
)
require(
    auto_refresh_block.index("PodcastRefreshOnAppStart") < auto_refresh_block.index("_lastAutoRefreshDate = [NSDate date];"),
    "Disabled startup refresh must not consume the 30-minute auto-refresh cooldown.",
)

news_mode_footer = "News Mode keeps only episodes from the newest publishing day as unplayed. Older episodes are marked as played and downloaded files are deleted automatically."
require(news_mode_footer in FEED_SETTINGS, "News Mode footer must describe the actual retention behavior.")
require(news_mode_footer in EN_STRINGS, "English localization must include the News Mode explanation.")
require(news_mode_footer in DE_STRINGS, "German localization must include the News Mode explanation key.")
require("Der News Mode hält nur Folgen vom neuesten Veröffentlichungstag als ungespielt." in DE_STRINGS, "German News Mode explanation is missing.")

refresh_footer = "Automatically refresh podcasts when opening the app or returning to it. Manual refreshes, push updates, and iOS background fetch are unaffected."
require('"Podcast-Refresh bei App-Start" = "Podcast Refresh on App Start";' in EN_STRINGS, "English startup refresh title is missing.")
require('"Podcast-Refresh bei App-Start" = "Podcast-Refresh bei App-Start";' in DE_STRINGS, "German startup refresh title is missing.")
require(refresh_footer in EN_STRINGS and refresh_footer in DE_STRINGS, "Startup refresh footer must be localized in English and German.")

require("<podcastRefreshOnAppStart>" in EXPORTER, "Backup export must include podcastRefreshOnAppStart.")
require('"podcastRefreshOnAppStart": PodcastRefreshOnAppStart' in IMPORTER, "Backup import must map podcastRefreshOnAppStart.")
require('"podcastRefreshOnAppStart"' in IMPORTER.split("NSSet *boolKeys", 1)[1], "Backup import must restore podcastRefreshOnAppStart as a boolean.")
