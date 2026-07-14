#!/usr/bin/env python3
"""Pins O(1) Watch list derivation for progress/position-only episode mutations."""

from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple


ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
VIEWS = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()
COLLECTION = (ROOT / "InstacastWatch" / "WatchEpisodeCollectionState.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require("@Published private(set) var episodes:" not in STORE,
        "A byte/position-only mutation must not publish the complete episode collection.")
runtime_update = body(COLLECTION, "func updateRuntimeEpisode(")
require("structuralRevision" not in runtime_update and "objectWillChange.send" not in runtime_update,
        "A runtime row mutation must not publish structural collection state.")

update_one = body(STORE, "func updateEpisode(hash:")
require("recordEpisodeMutation(previous:" in update_one,
        "Single-episode mutations must update derived caches from the actual old/new values.")
record_mutation = body(STORE, "private func recordEpisodeMutation(")
require("episodeSortKeyChanged" in record_mutation,
        "Only an actual playback-order/sort-date change may invalidate sortedEpisodes.")
require("sortedEpisodeIndexByHash" in record_mutation and "sortedEpisodesCache[" in record_mutation,
        "A value-only change must patch the cached row in O(1), not sort 4,500 values again.")
require("downloadedEpisodeCount" in STORE and "hasEvictedEpisodes" in STORE,
        "Storage summary counts must be cached in the model instead of filtering all rows in body.")
require("episodeMembershipGeneration" in STORE,
        "Navigation invalidation needs one scalar membership generation instead of a 4,500-hash array.")

list_start = VIEWS.find("struct WatchEpisodeListView")
list_end = VIEWS.find("private struct WatchEpisodeRow", list_start)
require(list_start >= 0 and list_end > list_start, "Missing WatchEpisodeListView")
list_view = VIEWS[list_start:list_end]
require("store.episodes.filter" not in list_view,
        "The Watch list body must not rescan all episodes for downloaded/evicted counts.")
require("sortedEpisodes.map(\\.episodeHash)" not in list_view,
        "The Watch list body must not allocate every episode hash on each progress tick.")
require("store.downloadedEpisodeCount" in list_view
        and "store.hasEvictedEpisodes" in list_view
        and "store.episodeMembershipGeneration" in list_view,
        "The view must consume the store's O(1) derived summary and membership signal.")
require("episode.hasPendingRemovalError" in list_view
        and "retryPendingRemoval(hash:" in list_view,
        "A durable pending-removal error needs an explicit, user-triggered retry in the list.")

status_text = body(VIEWS, "private var statusText: String")
removal_status = status_text[status_text.find("case .removing:"):]
removal_status = removal_status[:removal_status.find("case .queued:")]
require("return reason" in removal_status and '"\\(reason) · \\(retry)"' not in removal_status,
        "The durable removal error already contains retry guidance and must be shown only once.")


@dataclass(frozen=True)
class Episode:
    playback_order: Optional[int]
    sort_date: int
    status: str
    downloaded_bytes: int
    position: int


def cache_effect(previous: Episode, updated: Episode) -> Tuple[bool, bool, int]:
    order_changed = (previous.playback_order, previous.sort_date) != (
        updated.playback_order,
        updated.sort_date,
    )
    membership_changed = False
    downloaded_delta = int(updated.status == "downloaded") - int(previous.status == "downloaded")
    return order_changed, membership_changed, downloaded_delta


before = Episode(3, 100, "downloading", 1024, 20)
progress = Episode(3, 100, "downloading", 2048, 25)
require(cache_effect(before, progress) == (False, False, 0),
        "Progress/position-only changes must patch one row without order, membership, or count work.")
reordered = Episode(1, 100, "downloading", 2048, 25)
require(cache_effect(progress, reordered)[0],
        "A real playback-order change must still rebuild sorted order.")

print("Watch runtime UI-cache regression checks passed")
