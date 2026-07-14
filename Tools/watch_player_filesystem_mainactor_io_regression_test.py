#!/usr/bin/env python3
"""Pins Watch playback file resolution and diagnostics off MainActor."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORAGE = (ROOT / "InstacastWatch" / "WatchStorageManager.swift").read_text()
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
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


require(
    "struct WatchStorageLocalFileInspection: Sendable" in STORAGE,
    "Playback file resolution must cross executors as one immutable Sendable inspection.",
)
inspect_episode = body(STORAGE, "nonisolated static func inspectLocalFile(")
inspect_url = body(STORAGE, "nonisolated static func inspectFile(")
for name, method in (("episode resolution", inspect_episode), ("diagnostic stat", inspect_url)):
    require(
        "Task.detached(priority: .utility)" in method,
        f"Watch playback {name} must run in detached utility work.",
    )

play = body(PLAYER, "func play(_ episode:")
inspection_await = play.find("await WatchStorageManager.inspectLocalFile(")
generation = play.find("playbackGeneration += 1")
reclaim = play.find("claimPlaybackBeforeStorageEviction", inspection_await)
identity = play.find("episodeIdentity.matches(currentEpisode)", inspection_await)
require(
    -1 not in (inspection_await, generation, reclaim, identity)
    and generation < inspection_await < reclaim
    and inspection_await < identity,
    "Playback must invalidate older requests before off-main resolution, then reclaim/revalidate the exact episode before opening it.",
)

forbidden = ("FileManager", "WatchStorageManager.shared.resolvedLocalFileURL")
for token in forbidden:
    require(token not in PLAYER, f"WatchPlayerController still performs synchronous filesystem work: {token}")

unexpected = body(PLAYER, "func checkForUnexpectedTermination()")
stall = body(PLAYER, "private func tickPlaybackPosition()")
require(
    "await WatchStorageManager.inspectLocalFile(" in unexpected
    and "await WatchStorageManager.inspectFile(" in stall,
    "Unexpected-termination and stall diagnostics must enrich their logs asynchronously.",
)

print("Watch player filesystem MainActor I/O regression checks passed")
