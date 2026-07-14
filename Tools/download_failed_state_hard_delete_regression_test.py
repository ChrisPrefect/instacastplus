#!/usr/bin/env python3
"""Pins durable failed-download cleanup before a hard-deleted episode row disappears."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


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


require("clearDownloadErrorForEpisode:(CDEpisode*)episode" in CACHE_H and
        "completion:(void (^)(NSError* error))completion" in CACHE_H,
        "Hard deletion needs a durable failed-state cleanup contract, not a fire-and-forget UI clear.")

persist_failed = body(CACHE, "- (void)_persistFailedDownloadMetadata:")
require("completion:(void (^)(NSError* error))completion" in CACHE and
        "persistenceError" in persist_failed and
        "completion(persistenceError)" in persist_failed,
        "A failed keyed metadata write must reach its terminal caller as an error.")

clear_durable = body(
    CACHE,
    "- (void) clearDownloadErrorForEpisode:(CDEpisode*)episode\n"
    "                            completion:",
)
delete_call = clear_durable.find("_deletePersistedFailedDownloadForIdentifier")
memory_clear = clear_durable.find("_failedDownloadMetadataByEpisodeHash removeObjectForKey")
require(delete_call != -1 and memory_clear != -1 and delete_call < memory_clear and
        "if (error)" in clear_durable,
        "Failed state may disappear from memory only after its keyed file was durably removed.")

delete_many = body(DATABASE, "- (void) deleteEpisodes:(NSArray<CDEpisode*>*)episodes")
cache_completion = delete_many.find("removeCacheForEpisodes:uniqueEpisodes")
failure_cleanup = delete_many.find("clearDownloadErrorsForEpisodes:uniqueEpisodes")
database_delete = delete_many.find("_deleteEpisodeObjectIDs:episodeObjectIDs")
require(cache_completion != -1 and failure_cleanup != -1 and database_delete != -1 and
        cache_completion < failure_cleanup < database_delete and
        "if (cacheError)" in delete_many and
        "if (failureStateError)" in delete_many,
        "The episode row may be deleted only after both physical cache cleanup and failed-state cleanup are terminal.")

print("Download failed-state hard-delete regression checks passed")
