#!/usr/bin/env python3
"""Pins audio-authoritative Watch download-removal semantics.

Chapter artwork is auxiliary.  If audio deletion succeeds but one artwork deletion
fails, the episode must still stop being reported as downloaded; otherwise the
manifest points at an audio file that no longer exists.  Conversely, any surviving
audio file must prevent deletion acknowledgement.  Both failure classes remain
independently diagnosable and all artwork candidates are still attempted.
"""

from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "InstacastWatch"
    / "WatchStorageManager.swift"
).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


removal = function_body(
    "private nonisolated static func removeLocalFilesOffMain(\n"
    "        for episodes: [WatchEpisode],\n"
    "        context: WatchStorageRemovalContext"
)

require(
    "audioRemovalError" in removal
    and "artworkRemovalError" in removal
    and "removalError" not in removal,
    "Audio and chapter-artwork deletion failures must be tracked independently.",
)
require(
    '"storage-audio-remove-failed"' in removal
    and '"storage-artwork-remove-failed"' in removal,
    "Audio and artwork failures need distinct diagnostics.",
)

audio_result = removal.find("if let audioRemovalError")
confirm = removal.find("removedHashes.insert(episode.episodeHash)")
artwork_result = removal.find("if let artworkRemovalError")
require(
    -1 not in (audio_result, confirm, artwork_result)
    and audio_result < confirm < artwork_result,
    "Only successful audio removal may confirm the episode hash; artwork failure handling must "
    "run independently after that logical result is decided.",
)
require(
    removal.count("for fileURL in episodeArtworkURLs where") == 1
    and "break" not in removal[removal.find("for fileURL in episodeArtworkURLs where"):artwork_result],
    "An artwork error must not stop cleanup of the remaining chapter images.",
)


print("Watch partial storage-cleanup regression checks passed")
