#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "WidgetDataExporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
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


require("lastNowPlayingReloadSignature" not in SOURCE
        and "_currentNowPlayingReloadSignature" not in SOURCE,
        "The unread reload signature must not perform duplicate navigation scans.")

export = method_body("- (void)exportNowPlayingSnapshot")
require(export.count("_hasNextEpisodeForPlaybackManager") == 1,
        "One snapshot may resolve next-episode availability only once.")

debounced = method_body("- (void)_debouncedNowPlayingExport")
require("exportNowPlayingSnapshot" in debounced and "nextPlayableEpisode" not in debounced,
        "A debounced playback tick must reuse the snapshot result, not scan navigation again.")

has_next = method_body("- (BOOL)_hasNextEpisodeForPlaybackManager:")
cache_check = has_next.find("hasCachedNowPlayingNavigationState")
expensive_lookup = has_next.find("[as nextPlayableEpisode]")
require(cache_check != -1 and expensive_lookup != -1 and cache_check < expensive_lookup,
        "Next-episode availability must hit a generation cache before the potentially unbounded list/feed lookup.")
require("cachedNowPlayingNavigationGeneration" in has_next
        and "nowPlayingNavigationGeneration" in has_next
        and "cachedNowPlayingEpisodeHash" in has_next,
        "The cache must be scoped to both the playing episode and an explicit navigation generation.")

require("- (void)_invalidateNowPlayingNavigationCache" in SOURCE,
        "Navigation changes need one central cache invalidation method.")
for signature in [
    "- (void)_playbackDidStart:",
    "- (void)_playbackDidEnd:",
    "- (void)_playbackDidChangeEpisode:",
    "- (void)_episodeDidFinish:",
    "- (void)_playlistDidChange:",
    "- (void)_cacheDidFinish:",
    "- (void)_cacheDidClear:",
]:
    require("_invalidateNowPlayingNavigationCache" in method_body(signature),
            f"{signature} must invalidate cached navigation availability.")

playlist_observer = SOURCE.split('forKeyPath:@"playlist"', 1)[1].split("];", 1)[0]
require("_invalidateNowPlayingNavigationCache" in playlist_observer,
        "An in-place Up Next queue mutation must invalidate navigation availability.")

core_data = method_body("- (void)_coreDataDidChange:")
require("_coreDataChangeAffectsLists" in core_data
        and core_data.find("_coreDataChangeAffectsLists") < core_data.find("_invalidateNowPlayingNavigationCache"),
        "Only list-affecting Core Data changes may invalidate the cache; playback-position saves must remain cheap.")

print("Now Playing widget navigation performance regression checks passed")
