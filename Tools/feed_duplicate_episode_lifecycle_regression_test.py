#!/usr/bin/env python3
"""Pins duplicate feed episodes to a state-aware, terminal deletion path."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


preserve = body("- (BOOL)_episodeHasLocalStateWorthPreserving:")
require("episodeIsCached:episode" in preserve and
        "isCachingEpisode:episode" in preserve and
        "downloadErrorForEpisode:episode" in preserve and
        "playingEpisode.objectHash" in preserve,
        "Duplicate canonicalization must retain active/cached/failed user state instead of blindly keeping the newest row.")

prefer = body("- (BOOL)_shouldPreferEpisode:")
require("_episodeHasLocalStateWorthPreserving" in prefer and "pubDate" in prefer,
        "When local-state priority ties, duplicate selection must remain deterministically newest-first.")

update = body("- (void) updateLocalFeedInfo:")
require("_shouldPreferEpisode:episode overEpisode:canonicalEpisode" in update and
        "duplicateEpisodes" in update and
        "deleteEpisodes:duplicateEpisodes" in update,
        "The canonical row used for remote metadata must also own duplicate cleanup through DatabaseManager's terminal batch API.")
require("deleteObject:episode" not in update,
        "Feed merge must never invalidate a CDEpisode while download/cache callbacks can still reference it.")

print("Feed duplicate episode lifecycle regression checks passed")
