#!/usr/bin/env python3
"""Pins batched, durable episode-list actions for large libraries."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature, SOURCE.find("@implementation EpisodesTableViewController"))
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


consume = body("- (void) _setEpisodeObjectIDs:")
require(
    "removeCacheForEpisode:" not in consume
    and "cacheEpisodes:" in consume
    and "previousConsumed" in consume
    and "previousPosition" in consume
    and "processPendingChanges" in consume,
    "Mark-all must collect one cache batch and restore the failed Core Data batch before returning.",
)
require(
    consume.find("processPendingChanges") < consume.find("enableUndoRegistration"),
    "A failed mark-all save must restore the batch while undo registration is still disabled.",
)

archive = body("- (void)_archivePlayedEpisodeObjectIDs:")
require(
    "removeCacheForEpisode:" not in archive
    and "cacheEpisodes:" in archive
    and "previousArchived" in archive
    and "processPendingChanges" in archive,
    "Archive-all must collect one cache batch and restore unsaved archived flags on failure.",
)
require(
    archive.find("processPendingChanges") < archive.find("enableUndoRegistration"),
    "A failed archive-all save must restore the batch while undo registration is still disabled.",
)

finish_mutation = body("- (void)_finishBulkEpisodeMutationWithCacheEpisodes:")
require(
    "removeCacheForEpisodes:cacheEpisodes.array" in finish_mutation
    and "completion:finishUI" in finish_mutation
    and finish_mutation.count("[modalInfo close]") == 1,
    "The progress UI may close only from the single bulk file-deletion completion.",
)

clear = body("- (void)_clearPlayedCacheForEpisodeObjectIDs:")
finish_clear = body("- (void)_finishClearPlayedCacheWithEpisodes:")
require(
    "removeCacheForEpisode:" not in clear
    and "episodesToClear" in clear
    and "removeCacheForEpisodes:episodesToClear.array" in finish_clear
    and "completion:finishUI" in finish_clear
    and finish_clear.count("[modalInfo close]") == 1,
    "Delete-played-content must yield while selecting, then submit one file batch and wait for it.",
)

require(
    "kBulkEpisodeMutationBatchSize" in consume
    and "dispatch_async(dispatch_get_main_queue()" in consume
    and "kBulkEpisodeMutationBatchSize" in archive
    and "dispatch_async(dispatch_get_main_queue()" in archive,
    "Large Core Data mutations must remain bounded and yield between batches.",
)

print("Episode bulk-action transaction regression checks passed")
