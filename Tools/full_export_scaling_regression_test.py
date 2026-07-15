#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


builder = body("- (NSURL *)createEverythingBackupWithContext:")

require("ICBackupFetchBatchSize" in builder and "fetchBatchSize = ICBackupFetchBatchSize" in builder,
        "Large backup fetches must use a bounded Core Data batch size.")
require("stateEpisodesByFeedObjectID" in builder and "cachedEpisodeHashes" in builder,
        "Podcast export must pre-index only stateful/downloaded episodes by feed.")
require("for (CDEpisode* episode in feed.episodes)" not in builder,
        "Full backup must not materialize every episode relationship for every podcast.")
require("watchEpisodesByHash" in builder and "objectHash IN" in builder,
        "Watch episode metadata must be resolved in bounded bulk fetches.")
watch_loop = builder.split("BOOL hasAppleWatchEpisodes", 1)[1].split("// Playlists", 1)[0]
require("executeFetchRequest" not in watch_loop,
        "Apple Watch export must not execute one Core Data fetch per state.")

# `newExportBackgroundContext` starts cold. Fetching the abstract List entity and then
# touching subtype-only relationships makes every playlist/list fire its own SQL faults.
# Warm each concrete subtype and every relationship the XML loop reads before iterating.
lists_section = builder.split("// Playlists", 1)[1].split("// Settings", 1)[0]
require(
    'initWithEntityName:@"Playlist"' in lists_section,
    "Cold full export must fetch Playlist directly instead of faulting each subtype from List.",
)
for key_path in [
    "playlistEpisodes",
    "playlistEpisodes.episode",
    "playlistEpisodes.episode.feed",
    "playlistEpisodes.episode.media",
]:
    require(
        f'@"{key_path}"' in lists_section,
        f"Cold playlist export must prefetch {key_path} before serializing memberships.",
    )
require(
    'initWithEntityName:@"EpisodeList"' in lists_section
    and '@"includedFeeds"' in lists_section,
    "Cold EpisodeList export must prefetch includedFeeds instead of faulting once per list.",
)
require(
    'initWithEntityName:@"List"' not in lists_section,
    "The abstract List fetch must not remain as the cold N+1 source after concrete subtype prefetching.",
)


print("Full-export scaling regression checks passed")
