#!/usr/bin/env python3
"""Pins batched cache/error/Core-Data deletion for many episodes."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
CACHE_HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    implementation = source.find("@implementation DatabaseManager")
    if implementation == -1:
        implementation = source.find("@implementation CacheManager")
    start = source.find(signature, implementation)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


delete = body(DATABASE, "- (void) deleteEpisodes:")
require(
    "removeCacheForEpisodes:uniqueEpisodes" in delete
    and "removeCacheForEpisode:" not in delete,
    "Deleting many episodes must use one cache-removal transaction instead of one directory scan/save per row.",
)
require(
    "clearDownloadErrorsForEpisodes:uniqueEpisodes" in delete
    and "clearDownloadErrorForEpisode:" not in delete
    and "_deleteEpisodeObjectIDs:" in delete,
    "Failure metadata and Core Data rows must also use their batch paths.",
)

delete_batches = body(DATABASE, "- (void)_deleteEpisodeObjectIDs:")
require(
    "kEpisodeDeletionBatchSize" in delete_batches
    and "saveReturningError" in delete_batches
    and "dispatch_async(dispatch_get_main_queue()" in delete_batches,
    "Core Data deletion must save bounded batches and yield to the UI between them.",
)
require(
    "refreshObject:episode mergeChanges:NO" in delete_batches
    and "processPendingChanges" in delete_batches
    and delete_batches.find("refreshObject:episode mergeChanges:NO")
    < delete_batches.find("_finishDeletingEpisodes:successfullyDeletedEpisodes error:saveError"),
    "A failed delete save must discard that unsaved batch before reporting the partial failure.",
)

require(
    "clearDownloadErrorsForEpisodes:" in CACHE_HEADER
    and "_deletePersistedFailedDownloadFilesForIdentifiers" in CACHE,
    "Batch deletion needs one durable failed-download metadata operation, not one file job per episode.",
)
failure_file_batch = body(CACHE, "- (void)_deletePersistedFailedDownloadFilesForIdentifiers:")
failure_file_loop = failure_file_batch.find("for (NSString* identifier")
require(
    failure_file_loop != -1
    and failure_file_batch.find("_failedDownloadsStateDirectoryPath") < failure_file_loop
    and "identifier MD5Hash" in failure_file_batch[failure_file_loop:],
    "The failed-state batch must resolve its directory once instead of repeating filesystem setup for every episode.",
)

print("Database episode-delete batch regression checks passed")
