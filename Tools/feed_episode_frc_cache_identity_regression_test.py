#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "FeedEpisodesTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
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


for signature in (
    "- (void) _updateFetchControllerWithEpisodeGuids:",
    "- (void) _filterFavoriteEpisode",
    "- (void) _filterUnlistenedEpisode",
    "- (void) _filterUnfinishedEpisode",
    "- (void) _filterUnplayedAndStartedEpisode",
):
    body = method_body(signature)
    require(
        "self.feed.title" not in body,
        f"{signature} must not derive a persistent Core Data cache identity from a non-unique feed title.",
    )
    require(
        "sectionNameKeyPath:nil cacheName:nil" in body,
        f"{signature} must use an uncached FRC because the screen has no stable section-cache contract.",
    )


print("Feed episode FRC cache identity regression checks passed")
