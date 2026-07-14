#!/usr/bin/env python3
"""Pins the Watch player/chapter-list separation from the 11.07.2026 screenshots.

The controls page must fill one screen when its content fits, but it must be
allowed to grow for long episode and chapter titles. A fixed viewport height
lets the controls draw outside their reported layout bounds and over the
following chapter heading.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


watch_views = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()
player_view = watch_views.split("private struct WatchPlayerView", 1)[1].split(
    "private struct WatchPlayerHeader", 1
)[0]

require(
    ".frame(height: proxy.size.height" not in player_view,
    "The Watch player controls must not be forced to the viewport height: long titles then "
    "overflow their reported bounds and overlap the following chapter list.",
)
require(
    ".frame(minHeight: proxy.size.height, alignment: .top)" in player_view,
    "The Watch player controls must use the viewport as a minimum height so the player remains "
    "one screen tall when it fits and grows before the chapter list when it does not.",
)

print("watch player chapter layout regression test passed")
