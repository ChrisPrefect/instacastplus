#!/usr/bin/env python3
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "AppIntents" / "ICPlaybackIntents.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


struct_protocols = {
    match.group(1): [part.strip() for part in match.group(2).split(",")]
    for match in re.finditer(r"^struct\s+(IC\w+Intent)\s*:\s*([^{]+)\{", SOURCE, re.MULTILINE)
}

playback_intents = {
    "ICPlayIntent",
    "ICPauseIntent",
    "ICPlayPauseIntent",
    "ICSkipForwardIntent",
    "ICSkipBackwardIntent",
    "ICNextEpisodeIntent",
    "ICPreviousEpisodeIntent",
    "ICNextChapterIntent",
    "ICPreviousChapterIntent",
    "ICSetPlaybackSpeedIntent",
    "ICCyclePlaybackSpeedIntent",
    "ICSetSleepTimerIntent",
    "ICCancelSleepTimerIntent",
    "ICMarkPlayedIntent",
    "ICToggleStarIntent",
}

missing = sorted(playback_intents - struct_protocols.keys())
require(not missing, f"Missing playback App Intents: {', '.join(missing)}")

plain_app_intents = sorted(
    name
    for name in playback_intents
    if "AudioPlaybackIntent" not in struct_protocols[name]
)
require(
    not plain_app_intents,
    "Shortcuts actions that use the active playback context must conform to "
    f"AudioPlaybackIntent, not plain AppIntent: {', '.join(plain_app_intents)}",
)
