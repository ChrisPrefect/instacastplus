#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WATCH_VIEW = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()
PHONE_VIEW = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
CELL_HEADER = (ROOT / "Classes" / "EpisodesTableViewCell.h").read_text()
CELL = (ROOT / "Classes" / "EpisodesTableViewCell.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("episode.lastError" in WATCH_VIEW and 'NSLocalizedString("Tippen zum Wiederholen"' in WATCH_VIEW,
        "The Watch row must show the concrete stored failure reason and retry guidance.")
failed_block = WATCH_VIEW.split("case .failed:", 1)[1].split("case .evicted:", 1)[0]
require("lineLimit(3)" in failed_block and "fixedSize(horizontal: false, vertical: true)" in failed_block,
        "Watch download errors must be fully readable instead of truncated to one generic line.")
require('Label("Download erneut versuchen", systemImage: "arrow.clockwise")' in WATCH_VIEW,
        "The Watch list must expose an explicit retry action backed by the existing prioritize path.")

require("supplementalStatusText" in CELL_HEADER and "supplementalStatusTextColor" in CELL_HEADER,
        "The reusable iPhone episode cell needs an explicit, resettable status override.")
require("summaryOverride" in CELL_HEADER and "summaryOverride" in CELL,
        "The iPhone row height must be measured from the visible error text, not the episode subtitle.")
require("watchLastError" in PHONE_VIEW and '"Nach rechts wischen, um erneut zu laden.".ls' in PHONE_VIEW,
        "The iPhone Watch list must show the concrete failure and explain the retry gesture.")
require("supplementalStatusText = failureGuidance" in PHONE_VIEW
        and "supplementalStatusTextColor = UIColor.systemOrangeColor" in PHONE_VIEW,
        "The iPhone Watch row must render the failure guidance visibly.")
require('title = [state.watchStatus' in PHONE_VIEW and '@"Wiederholen".ls' in PHONE_VIEW,
        "A failed iPhone Watch row must label its existing leading action as Retry.")

for language in ["de", "en"]:
    strings = (ROOT / "InstacastWatch" / f"{language}.lproj" / "Localizable.strings").read_text()
    require('"Tippen zum Wiederholen"' in strings,
            f"Watch retry guidance is missing from {language} localization.")

print("Watch download error guidance regression checks passed")
