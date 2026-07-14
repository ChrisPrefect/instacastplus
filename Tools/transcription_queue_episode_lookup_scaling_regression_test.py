#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "TranscriptionQueueViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


lookup = method_body("- (CDEpisode*)_episodeForHash:")
rebuild = method_body("- (void)_rebuildEpisodeCacheForCurrentItems")
queue_changed = method_body("- (void)_queueChanged")
view_will_appear = method_body("- (void)viewWillAppear:")
context_changed = method_body("- (void)_contextObjectsDidChange:")

require(
    "DMANAGER.feeds" not in lookup
    and "feed.episodes" not in lookup
    and "self.episodeCache[hash]" in lookup,
    "Per-row transcription episode lookup must be O(1), not scan every feed and episode.",
)
require(
    "episodesWithObjectHashes:hashes.allObjects" in rebuild
    and "episodeCacheHashes" in rebuild
    and "isEqualToSet" in rebuild,
    "Queue hashes must be resolved in one coalesced batch fetch and skipped when unchanged.",
)
require(
    "_rebuildEpisodeCacheForCurrentItems" in queue_changed
    and "_rebuildEpisodeCacheForCurrentItems" in view_will_appear,
    "The lookup snapshot must be ready before cells render and refresh when queue membership changes.",
)
require(
    "NSManagedObjectContextObjectsDidChangeNotification" in SOURCE
    and "NSDeletedObjectsKey" in context_changed
    and "_rebuildEpisodeCacheForCurrentItems" in context_changed,
    "Deleted episodes must invalidate the lookup snapshot instead of leaving retained deleted objects.",
)
require(
    "NSInsertedObjectsKey" in context_changed
    and "NSUpdatedObjectsKey" in context_changed
    and "episodeCacheHashes" in context_changed,
    "A matching episode inserted or updated after a negative lookup must invalidate the transcription snapshot.",
)


print("Transcription queue episode-lookup scaling regression checks passed")
