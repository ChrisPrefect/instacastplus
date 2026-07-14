#!/usr/bin/env python3
"""Pins an action label that matches active downloads versus failure-only rows."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "DownloadsViewController.m").read_text()
DE = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
EN = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("- (void) _updateToolbar")
end = SOURCE.find("\n}", start)
require(start >= 0 and end > start, "Missing toolbar update method.")
toolbar = SOURCE[start:end]
require('self.cancelItem.title = hasActiveDownloads ? @"Cancel All".ls : @"Clear Errors".ls;' in toolbar,
        "Failure-only rows must say Clear Errors; Cancel All is reserved for an active queue.")
require('"Clear Errors" = "Fehler löschen";' in DE
        and '"Clear Errors" = "Clear Errors";' in EN,
        "The failure-only toolbar action needs German and English labels.")

print("Download toolbar-label regression checks passed")
