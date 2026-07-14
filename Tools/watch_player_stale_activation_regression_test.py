#!/usr/bin/env python3
"""Pins ownership of async Watch audio-session activation failures.

Timeline: play(A) creates player A and awaits AVAudioSession activation. Before
that completion arrives, play(B) replaces the global player/hash/Now Playing.
If A then fails, its stale catch must leave every piece of B state untouched.
"""
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def block_body(source: str, marker: str) -> str:
    start = source.find(marker)
    require(start != -1, f"Missing block marker: {marker}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing block body: {marker}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated block: {marker}")


play = block_body(PLAYER, "func play(_ episode: WatchEpisode) async -> Bool")
activation = play.find("try await activateLongFormAudioSession()")
require(activation != -1, "Watch playback must activate the long-form audio session asynchronously.")
activation_catch = block_body(play[activation:], "catch")

ownership_guard = re.search(
    r"guard\s+generation\s*==\s*playbackGeneration\s*,\s*"
    r"self\.player\s*===\s*player\s*,\s*"
    r"playingEpisodeHash\s*==\s*episode\.episodeHash\s*else\s*\{\s*return false\s*\}",
    activation_catch,
)
require(
    ownership_guard is not None,
    "The activation catch must require its original generation, exact AVAudioPlayer identity, "
    "and episode hash before it can clean up shared playback state.",
)
guard_position = ownership_guard.start()

cleanup_mutations = (
    "playbackGeneration += 1",
    "player.stop()",
    "self.player = nil",
    "playingEpisodeHash = nil",
    "isPlaying = false",
    "currentPosition = 0",
    "clearPlaybackActiveMarker()",
    "clearNowPlayingInfo()",
    "finalizePendingRemoval(hash:",
)
for mutation in cleanup_mutations:
    position = activation_catch.find(mutation)
    require(position != -1, f"The current activation-failure cleanup lost `{mutation}`.")
    require(
        guard_position < position,
        f"Activation-failure cleanup `{mutation}` must run only after the owning-generation/player/hash guard.",
    )


@dataclass(frozen=True)
class Attempt:
    generation: int
    player: object
    episode_hash: str


@dataclass
class PlaybackState:
    generation: int = 0
    player: Optional[object] = None
    episode_hash: Optional[str] = None
    now_playing_hash: Optional[str] = None

    def begin(self, episode_hash: str) -> Attempt:
        self.generation += 1
        attempt = Attempt(self.generation, object(), episode_hash)
        self.player = attempt.player
        self.episode_hash = episode_hash
        self.now_playing_hash = episode_hash
        return attempt

    def fail_activation(self, attempt: Attempt) -> bool:
        owns_state = (
            attempt.generation == self.generation
            and attempt.player is self.player
            and attempt.episode_hash == self.episode_hash
        )
        if not owns_state:
            return False
        self.generation += 1
        self.player = None
        self.episode_hash = None
        self.now_playing_hash = None
        return True


state = PlaybackState()
attempt_a = state.begin("A")
attempt_b = state.begin("B")
state_before_stale_failure = (
    state.generation,
    state.player,
    state.episode_hash,
    state.now_playing_hash,
)

require(not state.fail_activation(attempt_a), "A must no longer own playback after B starts.")
require(
    (
        state.generation,
        state.player,
        state.episode_hash,
        state.now_playing_hash,
    )
    == state_before_stale_failure,
    "A failing after B starts must not clear B's player, hash, generation, or Now Playing state.",
)
require(state.fail_activation(attempt_b), "The current owning attempt must retain normal failure cleanup.")
require(
    state.player is None and state.episode_hash is None and state.now_playing_hash is None,
    "A genuine current activation failure must still clear its own playback state.",
)

print("Watch stale audio-session activation regression checks passed")
