#!/usr/bin/env python3
"""Pins partial-download remaining size to saturating unsigned arithmetic."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "EpisodeViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("- (UIMenu*) _buildDownloadMenu")
end = SOURCE.find("\n- (", start + 1)
menu = SOURCE[start:end if end != -1 else len(SOURCE)]
require("downloadedBytes >= totalBytes ? 0 : totalBytes - downloadedBytes" in menu,
        "A stale partial file larger than the feed size must show 0 remaining, not an unsigned exabyte underflow.")

print("Download remaining-size underflow regression checks passed")
