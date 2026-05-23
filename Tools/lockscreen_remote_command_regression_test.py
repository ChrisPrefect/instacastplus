#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


source = (ROOT / "Classes" / "PlaybackManager.m").read_text()

setup = source.split("- (void) _setupRemotePlaybackCenterWithEpisode:(CDEpisode*)episode", 1)[1]
setup = setup.split("#if TARGET_OS_IPHONE", 1)[1]
setup = setup.split("#endif", 1)[0]

play_pause_handler = source.split("- (MPRemoteCommandHandlerStatus) _playPauseEvent:(MPRemoteCommandEvent*)event", 1)[1]
play_pause_handler = play_pause_handler.split("- (MPRemoteCommandHandlerStatus)_changePlaybackPositionEvent:", 1)[0]

explicit_play_uses_toggle_handler = "[playCommand addTarget:self action:@selector(_playPauseEvent:)];" in setup
explicit_pause_uses_toggle_handler = "[pauseCommand addTarget:self action:@selector(_playPauseEvent:)];" in setup
handler_only_toggles = "[self playPause];" in play_pause_handler and "event.command" not in play_pause_handler

require(
    not (explicit_play_uses_toggle_handler and explicit_pause_uses_toggle_handler and handler_only_toggles),
    "Lock-screen playCommand and pauseCommand must be idempotent. They must not both enter a blind playPause toggle handler.",
)

require(
    "[playCommand addTarget:self action:@selector(_playEvent:)];" in setup,
    "playCommand must use an idempotent play handler.",
)
require(
    "[pauseCommand addTarget:self action:@selector(_pauseEvent:)];" in setup,
    "pauseCommand must use an idempotent pause handler.",
)
require(
    "[togglePlayPauseCommand addTarget:self action:@selector(_playPauseEvent:)];" in setup,
    "togglePlayPauseCommand should remain the command that toggles play/pause.",
)
require(
    "- (MPRemoteCommandHandlerStatus) _playEvent:(MPRemoteCommandEvent*)event" in source
    and "[self play];" in source.split("- (MPRemoteCommandHandlerStatus) _playEvent:(MPRemoteCommandEvent*)event", 1)[1].split("- (MPRemoteCommandHandlerStatus) _pauseEvent:", 1)[0],
    "The play handler must start playback without toggling.",
)
require(
    "- (MPRemoteCommandHandlerStatus) _pauseEvent:(MPRemoteCommandEvent*)event" in source
    and "[self pause];" in source.split("- (MPRemoteCommandHandlerStatus) _pauseEvent:(MPRemoteCommandEvent*)event", 1)[1].split("- (MPRemoteCommandHandlerStatus)_changePlaybackPositionEvent:", 1)[0],
    "The pause handler must pause playback without toggling.",
)
