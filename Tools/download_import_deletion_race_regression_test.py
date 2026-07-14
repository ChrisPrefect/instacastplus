#!/usr/bin/env python3
"""Pins import publication against episode deletion and destructive cache clear."""

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


perform_import = body("- (void)_importFileAtURL:")
start_import = body("- (void) importFileAtURL:")
remove_batch = body("- (void)_removeCacheForEpisodes:")
perform_delete = body("- (void)_performCacheFileDeletionForItems:")
cache_episode = body(
    "- (BOOL) _cacheEpisode:(CDEpisode*)episode\n"
    "             autoCache:(BOOL)autoCache\n"
    "overwriteCellularLock:(BOOL)overwriteCellularLock\n"
    "reportsFailureToUser:(BOOL)reportsFailureToUser\n"
    "             queueRank:(NSNumber*)queueRank"
)
cached_url = body("- (NSURL*) URLForCachedEpisode:")

require("_cacheImportTokensByIdentifier" in SOURCE and
        "_cacheImportTokensByIdentifier" in cache_episode and
        "_cacheImportTokensByIdentifier" in cached_url,
        "An in-flight import must be invisible to UI lookups and block a competing network download.")
require("dispatch_async(_cacheDeletionQueue" in perform_import,
        "Import writes and deletions must share one serial file-mutation queue.")
require("_clearingAllCache" in start_import and
        start_import.find("_clearingAllCache") < start_import.find("_cacheImportTokensByIdentifier"),
        "A new import must be rejected while destructive cache clearing is active.")
require("importGeneration" in perform_import and "importToken" in perform_import and
        "_cacheIndexGeneration" in perform_import and "_cacheDeletionTokensByIdentifier" in perform_import and
        "_clearingAllCache" in perform_import,
        "An obsolete import callback must never republish a file after delete or full clear.")
require("[self->_cachedURLIndex removeObjectForKey:identifier]" in perform_import,
        "A failed import must not leave a nonexistent destination registered as cached.")

require("ICCacheDeletionWasAccountedKey" in remove_batch and
        "ICCacheDeletionWasAccountedKey" in perform_delete,
        "Deleting an unpublished imported file must not subtract bytes that were never added.")

print("Download import/deletion race regression checks passed")
