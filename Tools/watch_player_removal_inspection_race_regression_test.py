#!/usr/bin/env python3
"""Pins playback file-inspection results to the current Watch removal state.

Timeline: playback starts an off-main file inspection for a downloaded episode.
While it is suspended, a newer manifest marks that episode as removing and the
cleanup removes its file.  The stale inspection result must not turn the current
removing row back into queued or start playback.
"""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


play = function_body(PLAYER, "func play(_ episode: WatchEpisode) async -> Bool")
inspection = play.find("await WatchStorageManager.inspectLocalFile(")
current_lookup = play.find("let currentEpisode = WatchManifestStore.shared.episode", inspection)
current_removal = play.find("currentEpisode.status == .removing", current_lookup)
current_downloaded = play.find("currentEpisode.status == .downloaded", current_lookup)
missing_file = play.find("guard let localFileURL = inspection.resolvedURL", current_lookup)
queued_mutation = play.find("item.status = .queued", missing_file)

require(
    -1 not in (
        inspection,
        current_lookup,
        current_removal,
        current_downloaded,
        missing_file,
        queued_mutation,
    )
    and inspection < current_lookup < current_removal < missing_file
    and current_lookup < current_downloaded < missing_file,
    "After async inspection, playback must reject/finalize the current removing state and require "
    "the current downloaded state before any missing-file repair can queue the episode.",
)
require(
    "if episode.status == .removing" not in play,
    "The pre-await episode snapshot must not decide removal ownership after file inspection.",
)


@dataclass
class EpisodeState:
    status: str
    local_file: Optional[str]


def apply_missing_file_result(current: EpisodeState) -> str:
    if current.status == "removing":
        return "finalize-removal"
    if current.status != "downloaded":
        return "ignore"
    current.status = "queued"
    current.local_file = None
    return "repair-download"


episode = EpisodeState(status="downloaded", local_file="episode.mp3")
stale_pre_await_status = episode.status
episode.status = "removing"
episode.local_file = None
action = apply_missing_file_result(episode)

require(stale_pre_await_status == "downloaded", "The race fixture must start from a downloaded row.")
require(action == "finalize-removal", "A newer removal must own the stale missing-file result.")
require(episode.status == "removing", "Playback inspection must never resurrect removing as queued.")

print("Watch playback/removal inspection race regression checks passed")
