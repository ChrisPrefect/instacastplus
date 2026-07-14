#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "BookmarksTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("- (void) _reloadBookmarks")
end = SOURCE.find("\n- (void)", start + 1)
require(start != -1 and end != -1, "Missing bookmark reload method.")
reload_body = SOURCE[start:end]

require(
    "NSArray* bookmarks = bookmarkIndex[episodeHash];" in reload_body
    and "[myBookmarks setObject:bookmarks forKey:episodeHash]" in reload_body,
    "Bookmark sections must reuse the already-built hash group instead of rescanning all bookmarks.",
)
require(
    "_bookmarksWithEpisodeHash" not in SOURCE,
    "The per-section full bookmark scan must be removed after grouping becomes linear.",
)


print("Bookmark grouping scaling regression checks passed")
