#!/usr/bin/env python3
"""Pins the downloaded statistic label to the current-cache value it displays."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "DataSettingsViewController.m").read_text()
EN = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
DE = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


statistics_case = SOURCE.split("case 5: {", 1)[1].split("case 6: {", 1)[0]
require('cell.textLabel.text = @"Downloaded Episodes".ls;' in statistics_case and
        ".cachedEpisodes count" in statistics_case,
        "The current cache count must be labelled as downloaded episodes, not a lifetime 'Total Downloaded' value.")
require('"Downloaded Episodes" = "Downloaded Episodes";' in EN,
        "English downloaded-episode statistics label is missing.")
require('"Downloaded Episodes" = "Geladene Folgen";' in DE,
        "German downloaded-episode statistics label is missing or misleading.")

print("Data settings downloaded-label regression checks passed")
