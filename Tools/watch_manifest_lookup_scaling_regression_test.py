#!/usr/bin/env python3
"""Pins indexed Watch manifest lookup and one cached list order per mutation/render."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
VIEWS = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


episode_lookup = function_body(STORE, "func episode(hash:")
sorted_episodes = function_body(STORE, "var sortedEpisodes:")
require("episodeIndexByHash" in STORE and "episodeIndexByHash[hash]" in episode_lookup and
        "episodes.first" not in episode_lookup,
        "Removal and navigation lookups must be O(1), not scan all 4,500 episodes per hash.")
require("sortedEpisodesCache" in STORE and "sortedEpisodesCache" in sorted_episodes and
        ".sorted" not in sorted_episodes,
        "The Watch list order must be cached once per store mutation, not sorted on every property read.")

list_view_start = VIEWS.find("struct WatchEpisodeListView")
list_view_end = VIEWS.find("struct ", list_view_start + len("struct WatchEpisodeListView"))
list_view = VIEWS[list_view_start:list_view_end if list_view_end != -1 else len(VIEWS)]
require("let sortedEpisodeRows = store.sortedEpisodeRows" in list_view and
        list_view.count("store.sortedEpisodeRows") == 1,
        "One SwiftUI render must reuse one ordered stable-row snapshot for emptiness and rows.")

print("Watch manifest lookup scaling regression checks passed")
