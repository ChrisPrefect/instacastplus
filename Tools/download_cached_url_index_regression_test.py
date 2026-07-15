#!/usr/bin/env python3
"""Pins _cachedURLIndex as evidence of a real or actively written file, not a path factory."""

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
        require(brace != -1, f"Missing body: {signature}")
        semicolon = SOURCE.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


cached_url = body("- (NSURL*) URLForCachedEpisode:")
remove_batch = body(
    "- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes\n"
    "                       automatic:(BOOL)automatic\n"
    "             physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot\n"
    "                      completion:"
)
perform_import = body("- (void)_importFileAtURL:")

candidate_start = cached_url.find("// Return new-style path")
candidate_section = cached_url[candidate_start:]
require(candidate_start != -1 and "_cachedURLIndex" not in candidate_section,
        "A nonexistent download destination must not be registered as an existing cached file.")
require("indexedFile" in remove_batch and "importInFlight" in remove_batch and
        "wasCached || indexedFile || importInFlight || episode.downloaded || episode.lastDownloaded" in remove_batch,
        "Logical deletion may trust the now-evidentiary URL index and explicit import state, never a speculative path.")
require("_cacheImportTokensByIdentifier[identifier] = importToken" in perform_import and
        "_cachedURLIndex[identifier] = cachedURL" in perform_import,
        "An import must explicitly publish its protected in-flight destination for queued deletion.")

print("Download cached-URL index regression checks passed")
