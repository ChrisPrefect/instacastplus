#!/usr/bin/env python3
"""Pins downloaded-files UI feedback to terminal cache deletion completion."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
MEDIA = (ROOT / "Classes" / "MediaFilesViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if source.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes\n                       automatic:(BOOL)automatic\n                      completion:" in HEADER and
        "removeCacheForFeed:(CDFeed*)feed\n                   automatic:(BOOL)automatic\n                  completion:" in HEADER,
        "Batch and feed deletion need terminal completion APIs for honest UI feedback.")

remove_batch = body(MANAGER, "- (void)_removeCacheForEpisodes:")
require("identifiersToWaitFor" in remove_batch and
        "remainingCompletions" in remove_batch and
        "_cacheDeletionCompletionsByIdentifier" in remove_batch,
        "One batch completion must aggregate new and already in-flight physical deletions.")

clear_action = body(MEDIA, "- (void) clearCacheAction:")
played = clear_action.split('actionWithTitle:@"Only Delete Played".ls', 1)[1].split('actionWithTitle:@"Delete All Content".ls', 1)[0]
completion = played.find("completion:^(NSError* error)")
close = played.find("[modelInfo close]")
require(completion != -1 and close > completion,
        "The played-download spinner must remain visible until every physical deletion reaches a terminal result.")

commit_delete = body(MEDIA, "commitEditingStyle:")
require("removeCacheForFeed:feed" in commit_delete and "completion:" in commit_delete and
        "removeCacheForEpisode:episode" in commit_delete,
        "Podcast and single-row deletion must refresh from terminal completion rather than an immediate stale snapshot.")

print("Media-files deletion-completion regression checks passed")
