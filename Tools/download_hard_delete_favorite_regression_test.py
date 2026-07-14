#!/usr/bin/env python3
"""Pins physical cache removal when a favorited episode is hard-deleted."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = DATABASE.find(signature, DATABASE.find("@implementation DatabaseManager"))
    require(start != -1, f"Missing method: {signature}")
    brace = DATABASE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(DATABASE)):
        if DATABASE[index] == "{":
            depth += 1
        elif DATABASE[index] == "}":
            depth -= 1
            if depth == 0:
                return DATABASE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


remove_references = body("- (void) _removeEpisodeReferences:(CDEpisode*)episode")
archive = body("- (void) setEpisode:(CDEpisode *)episode archived:")
delete = body("- (void) deleteEpisode:(CDEpisode*)episode")
delete_many = body("- (void) deleteEpisodes:(NSArray<CDEpisode*>*)episodes")
delete_batches = body("- (void)_deleteEpisodeObjectIDs:")
compact_database = " ".join(DATABASE.split())
compact_remove_references = " ".join(remove_references.split())

require("automatic:(BOOL)automatic completion:(void (^)(NSError* error))completion" in compact_database and
        "automatic:automatic completion:^" in compact_remove_references and
        "clearDownloadErrorForEpisode:episode completion:^" in compact_remove_references,
        "Reference cleanup must explicitly distinguish automatic retention from hard deletion.")
require("_removeEpisodeReferences:episode automatic:YES completion:nil" in archive,
        "Archiving may keep the existing automatic favorite protection.")
require("deleteEpisodes:episode ? @[episode] : @[]" in delete,
        "Single hard deletion must use the same terminal batch transaction as feed cleanup.")
require("episodeObjectIDs = [uniqueEpisodes valueForKey:@\"objectID\"]" in delete_many and
        delete_many.find("episodeObjectIDs = [uniqueEpisodes valueForKey:@\"objectID\"]")
        < delete_many.find("removeCacheForEpisodes:uniqueEpisodes"),
        "Hard deletion must retain only stable Core Data identity before asynchronous cleanup starts.")
require("removeCacheForEpisodes:uniqueEpisodes automatic:NO completion:^" in delete_many and
        "clearDownloadErrorsForEpisodes:uniqueEpisodes completion:^" in delete_many and
        "if (cacheError)" in delete_many and
        "if (failureStateError)" in delete_many and
        delete_many.find("if (failureStateError)") < delete_many.find("_deleteEpisodeObjectIDs:episodeObjectIDs"),
        "A failed physical deletion must keep the database row so cleanup can be retried.")
require("existingObjectWithID:episodeObjectIDs[index]" in delete_batches and
        "deleteObject:episode" in delete_batches and
        delete_batches.find("existingObjectWithID:episodeObjectIDs[index]") < delete_batches.find("deleteObject:episode"),
        "The episode may be resolved and deleted only after the cache/download lifecycle is terminal.")

print("Download hard-delete favorite regression checks passed")
