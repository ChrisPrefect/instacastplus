#!/usr/bin/env python3
"""Pins AVAudioPlayer delegate callbacks to the player that owns Watch playback.

Timeline: player A finishes and its delegate callback is queued. Player B takes
over before the callback reaches MainActor. A's stale finish must be a complete
no-op; otherwise A's result can consume B, delete B as truncated, clear B's Now
Playing state, acknowledge B's pending removal, or start another episode.
"""
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Set


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


finish = block_body(PLAYER, "nonisolated func audioPlayerDidFinishPlaying(")
finish_task_position = finish.find("Task { @MainActor in")
finish_identifier_position = finish.find("let callbackPlayerIdentifier = ObjectIdentifier(player)")
require(
    0 <= finish_identifier_position < finish_task_position,
    "The non-Sendable AVAudioPlayer must be reduced to a sendable ObjectIdentifier before "
    "the nonisolated delegate hops to MainActor.",
)
finish_on_main = block_body(finish, "Task { @MainActor in")
finish_on_main = finish_on_main.split("@MainActor in", 1)[1]
finish_guard = re.match(
    r"\s*guard\s+let\s+currentPlayer\s*=\s*self\.player\s*,\s*"
    r"ObjectIdentifier\(currentPlayer\)\s*==\s*callbackPlayerIdentifier\s*else\s*"
    r"\{\s*return\s*\}\s*"
    r"let\s+finishedHash\s*=\s*playingEpisodeHash",
    finish_on_main,
)
require(
    finish_guard is not None,
    "audioPlayerDidFinishPlaying must compare the callback's sendable player identity as the "
    "first MainActor operation, then snapshot the hash paired with that current player.",
)
require(
    "self.player === player" not in finish_on_main,
    "A nonisolated AVAudioPlayer must not be captured directly by the MainActor task under Swift 6.",
)

finish_side_effects = (
    "WatchManifestStore.shared.episode(hash:",
    "WatchDiagnostics.log(",
    "isPlaying = false",
    "stopTimer()",
    "reportPosition(finished:",
    "await WatchDownloadManager.shared.removePlaybackFile(",
    "nextPlayableEpisode(after:",
    "self.player = nil",
    "playingEpisodeHash = nil",
    "clearPlaybackActiveMarker()",
    "clearNowPlayingInfo()",
    "finalizePendingRemoval(hash:",
    "startQueuedDownloads()",
    "await play(nextEpisode)",
)
for side_effect in finish_side_effects:
    position = finish_on_main.find(side_effect)
    require(position != -1, f"The genuine finish contract lost `{side_effect}`.")
    require(
        finish_guard.end() < position,
        f"Stale finish callback can reach `{side_effect}` before player/hash ownership is proven.",
    )

require(
    "truncatedFile" in finish_on_main
    and "reportPosition(finished: true)" in finish_on_main
    and "pendingRemoval" in finish_on_main,
    "The current player's consumed, truncation, and pending-removal finish contracts must remain intact.",
)

decode = block_body(PLAYER, "nonisolated func audioPlayerDecodeErrorDidOccur(")
decode_task_position = decode.find("Task { @MainActor in")
decode_identifier_position = decode.find("let callbackPlayerIdentifier = ObjectIdentifier(player)")
require(
    0 <= decode_identifier_position < decode_task_position,
    "The decode delegate must capture only a sendable player identity before hopping actors.",
)
decode_on_main = block_body(decode, "Task { @MainActor in")
decode_on_main = decode_on_main.split("@MainActor in", 1)[1]
decode_guard = re.match(
    r"\s*guard\s+let\s+currentPlayer\s*=\s*self\.player\s*,\s*"
    r"ObjectIdentifier\(currentPlayer\)\s*==\s*callbackPlayerIdentifier\s*else\s*"
    r"\{\s*return\s*\}",
    decode_on_main,
)
require(
    decode_guard is not None
    and decode_guard.end() < decode_on_main.find("playingEpisodeHash")
    and decode_guard.end() < decode_on_main.find("WatchDiagnostics.log("),
    "A stale decode callback must not attribute player A's error to the current player B episode.",
)


@dataclass(frozen=True)
class Attempt:
    player: object
    episode_hash: str


@dataclass
class PlaybackState:
    player: Optional[object] = None
    episode_hash: Optional[str] = None
    now_playing_hash: Optional[str] = None
    is_playing: bool = False
    consumed_hashes: Set[str] = field(default_factory=set)
    deleted_hashes: Set[str] = field(default_factory=set)
    removal_ack_hashes: Set[str] = field(default_factory=set)
    next_play_count: int = 0
    finish_log_count: int = 0

    def begin(self, episode_hash: str) -> Attempt:
        attempt = Attempt(object(), episode_hash)
        self.player = attempt.player
        self.episode_hash = episode_hash
        self.now_playing_hash = episode_hash
        self.is_playing = True
        return attempt

    def finish(self, attempt: Attempt, successful: bool, truncated: bool) -> bool:
        if attempt.player is not self.player or self.episode_hash is None:
            return False
        owned_hash = self.episode_hash
        self.finish_log_count += 1
        self.is_playing = False
        if truncated:
            self.deleted_hashes.add(owned_hash)
        elif successful:
            self.consumed_hashes.add(owned_hash)
            self.next_play_count += 1
        self.player = None
        self.episode_hash = None
        self.now_playing_hash = None
        return True


state = PlaybackState()
attempt_a = state.begin("A")
attempt_b = state.begin("B")
state_before_stale_finish = (
    state.player,
    state.episode_hash,
    state.now_playing_hash,
    state.is_playing,
    set(state.consumed_hashes),
    set(state.deleted_hashes),
    set(state.removal_ack_hashes),
    state.next_play_count,
    state.finish_log_count,
)

require(
    not state.finish(attempt_a, successful=True, truncated=True),
    "A must no longer own the finish callback after B starts.",
)
require(
    (
        state.player,
        state.episode_hash,
        state.now_playing_hash,
        state.is_playing,
        state.consumed_hashes,
        state.deleted_hashes,
        state.removal_ack_hashes,
        state.next_play_count,
        state.finish_log_count,
    )
    == state_before_stale_finish,
    "A finishing after B starts must not log, consume/delete/ack B, clear B, or start another episode.",
)
require(
    state.finish(attempt_b, successful=True, truncated=False),
    "The current owning player's genuine finish must still run.",
)
require(
    state.consumed_hashes == {"B"}
    and state.player is None
    and state.episode_hash is None
    and state.now_playing_hash is None
    and state.next_play_count == 1,
    "The current player's normal consumed/cleanup/next-play finish contract must remain intact.",
)

print("Watch stale AVAudioPlayer finish regression checks passed")
