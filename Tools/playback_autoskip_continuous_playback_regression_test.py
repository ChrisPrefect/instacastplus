#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def source_between(source, start, end):
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


def method_body(source, signature):
    require(signature in source, f"{signature} is missing.")
    return source.split(signature, 1)[1].split("\n- (", 1)[0]


def require_autoskip_completion_advances(block, label):
    require("nextPlayableEpisode" in block, f"{label} must ask AudioSession for a next playable episode before closing playback.")
    require("playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES" in block, f"{label} must start the next episode when continuous playback has one.")
    require("closeAndSaveCurrentPosition:NO" in block, f"{label} may close only when no next episode is available.")
    require("[weakSelf close];" not in block and "[self close];" not in block, f"{label} must not close unconditionally before checking continuous playback.")
    require("[weakSelf.player pause];" not in block and "[self.player pause];" not in block, f"{label} must not pause unconditionally before checking continuous playback.")


PLAYBACK = read("Classes/PlaybackManager.m")

auto_skip_end = source_between(PLAYBACK, "// Handle auto skip end", "\n        \n        if (weakSelf.player.rate > 0)")
require_autoskip_completion_advances(auto_skip_end, "Auto-skip end")

chapter_skip_finish = method_body(PLAYBACK, "- (void)_finishEpisodeDueToSkip:")
require_autoskip_completion_advances(chapter_skip_finish, "Chapter skip episode finish")
