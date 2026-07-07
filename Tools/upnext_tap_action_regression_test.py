#!/usr/bin/env python3
"""Pins the play-next list tap behavior (TestFlight feedback 13.06.2026).

Tapping a row in the Abspielliste (UpNextTableViewController) did nothing at all —
no selection style, no didSelectRowAtIndexPath. Rows must honor the user's
TapOnEpisodeAction setting exactly like every other episode list
(EpisodesTableViewController): show notes / context menu / play.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


source = (ROOT / "Classes" / "UpNextTableViewController.m").read_text()

require(
    "didSelectRowAtIndexPath" in source,
    "UpNextTableViewController must handle row taps.",
)
require(
    "cell.selectionStyle = UITableViewCellSelectionStyleNone;" not in source,
    "Play-next rows must be selectable (no UITableViewCellSelectionStyleNone).",
)

select_body = source.split("didSelectRowAtIndexPath", 1)[1].split("\n- (", 1)[0]
require(
    "TapOnEpisodeAction" in select_body,
    "Row taps must honor the user's TapOnEpisodeAction setting.",
)
require(
    "ICTapOnEpisodeActionShowNotes" in select_body and "_pushShowNotesOfEpisode" in select_body,
    "The show-notes tap action must push the episode view.",
)
require(
    "presentFromParentViewController" in select_body,
    "The default tap action must present playback like other episode lists.",
)
require(
    "indexPath.row >= " in select_body,
    "Row taps must bounds-check against the live playlist (it mutates during playback).",
)

push_body = source.split("- (void) _pushShowNotesOfEpisode:", 1)[1].split("\n- (", 1)[0]
require(
    "EpisodeViewController" in push_body and "pushViewController" in push_body,
    "_pushShowNotesOfEpisode must push an EpisodeViewController.",
)

print("up-next tap action regression checks passed")
