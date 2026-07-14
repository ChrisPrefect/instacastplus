#!/usr/bin/env python3
"""Pins terminal handling for episodes without a usable playback URL."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()
AUDIO_SESSION = (ROOT / "Classes" / "AudioSession.m").read_text()
AUDIO_SESSION_IMPLEMENTATION = AUDIO_SESSION.split("@implementation AudioSession", 1)[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


play_episode = body(
    AUDIO_SESSION_IMPLEMENTATION,
    "- (void) _playEpisode:(CDEpisode*)anEpisode",
)
open_episode = body(
    PLAYBACK,
    "- (void) openWithEpisode:(CDEpisode*)anEpisode at:(NSTimeInterval)time autostart:(BOOL)autostart",
)

audio_guard = play_episode.find("playbackURL.absoluteString.length == 0")
require(audio_guard != -1 and audio_guard < play_episode.find("[self resetSession]"),
        "A play request without cached or remote media must be rejected before replacing the active AudioSession episode.")
require('showBackgroundErrorWithTitle:@"Media not loaded.".ls' in play_episode and
        '@"No media to play.".ls' in play_episode[audio_guard:play_episode.find("[self resetSession]")],
        "The rejected play request must explain the missing media instead of failing silently.")

playback_guard = open_episode.find("url.absoluteString.length == 0")
require(playback_guard != -1 and
        playback_guard < open_episode.find("if (self.player)") and
        playback_guard < open_episode.find("URLAssetWithURL"),
        "PlaybackManager must validate the resolved URL before mutating playback state or constructing AVURLAsset.")
require("closeAndSaveCurrentPosition:YES" in open_episode[playback_guard:open_episode.find("if (self.player)")] and
        'showBackgroundErrorWithTitle:@"Media not loaded.".ls' in open_episode[playback_guard:open_episode.find("if (self.player)")],
        "A URL disappearing between request validation and opening must terminate the old owner and surface a visible error.")

print("Playback missing-media regression checks passed")
