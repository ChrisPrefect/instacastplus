#!/usr/bin/env python3
"""Pins downloaded-file podcast sections to feed identity, not display title."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "MediaFilesViewController.m").read_text()


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


apply_content = body("- (void) _applyContentEpisodes:")
podcast_mode = apply_content.split("case kSortByPodcast:", 1)[1]
require("episode.feed.objectID.URIRepresentation.absoluteString" in podcast_mode,
        "Podcast sections must use the permanent feed identity so equal display titles remain separate.")
require("grouped[feedTitle]" not in podcast_mode and "feedMap[feedTitle]" not in podcast_mode,
        "A mutable display title must never be the grouping or destructive-action identity.")
require("localizedCaseInsensitiveCompare" in podcast_mode and "compare:secondIdentifier" in podcast_mode,
        "Sections with equal titles need a deterministic identity tie-breaker.")

print("Media-files feed identity regression checks passed")
