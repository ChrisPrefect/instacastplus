#!/usr/bin/env python3
"""Pins rollback of CacheManager's own state after a logical-removal save failure."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing method body: {signature}")
        if SOURCE.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


remove_batch = body("- (void)_removeCacheForEpisodes:")
save_failure = remove_batch.split("if (saveError)", 1)[1].split("return;", 1)[0]
require(
    "ICCacheDeletionDownloadedKey" in save_failure
    and "ICCacheDeletionLastDownloadedKey" in save_failure
    and "_cachedEpisodes addObject" in save_failure
    and "_cachedURLIndex[identifier] = cachedURL" in save_failure,
    "A failed logical-removal save must restore every in-memory/model cache field owned by the operation.",
)
require(
    "processPendingChanges" in save_failure
    and save_failure.find("processPendingChanges") < save_failure.find("_completeCacheDeletionForIdentifier"),
    "The restored values must be processed before callbacks so they cannot linger as this operation's pending changes.",
)
require(
    "rollback]" not in save_failure,
    "Cache rollback must remain surgical and preserve unrelated pending user changes in the shared main context.",
)

public_remove_batch = body(
    "- (void) removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes\n"
    "                       automatic:(BOOL)automatic\n"
    "                      completion:"
)
require(
    public_remove_batch.find("isKindOfClass:[CDEpisode class]")
    < public_remove_batch.find("episode.objectHash"),
    "The public batch boundary must reject invalid array members before reading episode properties.",
)

print("Cache bulk save-failure regression checks passed")
