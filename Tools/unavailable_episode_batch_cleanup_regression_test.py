#!/usr/bin/env python3
"""Pins unavailable-feed cleanup to bounded saves and one terminal Up Next update."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
DATABASE_H = (ROOT / "Classes" / "Model" / "DatabaseManager.h").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    implementation = source.find("@implementation")
    start = source.find(signature, implementation if implementation != -1 else 0)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


cleanup = body(SUBSCRIPTIONS, "- (void) _deleteUnavailableEpisodesFromFeed:")
require("unavailableEpisodes" in cleanup and
        "deleteEpisodes:unavailableEpisodes" in cleanup and
        "deleteEpisode:episode" not in cleanup,
        "A large feed refresh must submit one deletion batch instead of starting one database transaction per missing episode.")

require("- (void) deleteEpisodes:(NSArray<CDEpisode*>*)episodes" in DATABASE_H and
        "completion:(void (^)(NSError* error))completion" in DATABASE_H,
        "DatabaseManager needs one explicit asynchronous batch-delete contract.")

delete_many = body(DATABASE, "- (void) deleteEpisodes:")
delete_batches = body(DATABASE, "- (void)_deleteEpisodeObjectIDs:")
finish_delete = body(DATABASE, "- (void)_finishDeletingEpisodes:")
require("removeCacheForEpisodes:uniqueEpisodes" in delete_many and
        "clearDownloadErrorsForEpisodes:uniqueEpisodes" in delete_many,
        "The whole unavailable set must finish one cache and failed-state lifecycle before Core Data deletion.")
require("kEpisodeDeletionBatchSize" in delete_batches and
        "saveReturningError" in delete_batches and
        "dispatch_async(dispatch_get_main_queue()" in delete_batches,
        "Thousands of unavailable rows must commit in bounded batches with a main-runloop yield.")
require("successfullyDeletedEpisodes" in delete_batches and
        finish_delete.count("eraseEpisodesFromUpNext:successfullyDeletedEpisodes") == 1,
        "Up Next must be filtered and persisted once after all successfully committed batches.")

print("Unavailable episode batch-cleanup regression checks passed")
