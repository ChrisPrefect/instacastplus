#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "AppleWatchEpisodesViewController.m").read_text()


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


require(
    "episodeWithObjectHash" not in SOURCE,
    "Watch rows, heights, swipes, and menus must not execute a Core Data fetch per access.",
)
snapshot = method_body("- (NSDictionary<NSString*, CDEpisode*>*)_episodesByHashForStates:")
reload = method_body("- (void)_reloadDataFromManager")
lookup = method_body("- (CDEpisode*)_episodeForState:")
require(
    "episodesWithObjectHashes:batch" in snapshot
    and "ICAppleWatchEpisodeLookupBatchSize" in snapshot,
    "Watch UI episode metadata must be fetched once in bounded batches.",
)
require(
    "self.episodesByHash = [self _episodesByHashForStates:newStates]" in reload
    and "episodeHashesChanged" in reload,
    "The metadata snapshot must rebuild when the visible Watch state identity changes.",
)
require(
    "self.episodesByHash[state.episodeHash]" in lookup,
    "All row paths need one O(1) state-to-episode lookup.",
)
require(
    "NSManagedObjectContextObjectsDidChangeNotification" in SOURCE
    and "NSDeletedObjectsKey" in SOURCE,
    "Local episode deletion must invalidate the Watch UI snapshot so orphan rows remain safe.",
)
context_changed = method_body("- (void)_contextObjectsDidChange:")
require(
    "NSInsertedObjectsKey" in context_changed
    and "NSUpdatedObjectsKey" in context_changed
    and "stateIndexByHash" in context_changed
    and "_reloadVisibleRowsForEpisodeHashes:" in context_changed
    and "_episodesByHashForStates:" not in context_changed,
    "A matching episode insert/update/delete must patch its cached mapping and visible row without "
    "rebuilding metadata for the whole Watch selection.",
)

live_status = method_body("- (void)_liveStatusDidChange:")
require(
    "_updateHeaderText" in live_status
    and "_reloadVisibleRowsForEpisodeHashes:" in live_status
    and "_reloadDataFromManager" not in live_status,
    "Two-second Watch progress may update the header and affected visible rows, never the full state snapshot.",
)


print("Watch episode UI lookup scaling regression checks passed")
