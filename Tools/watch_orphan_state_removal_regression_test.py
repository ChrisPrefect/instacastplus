#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "AppleWatchSyncManager.h").read_text()
MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
VIEW = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
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


require(
    "removeEpisodeStateFromWatch:" in HEADER,
    "Watch removal needs a state-identity API that does not require the local episode to exist.",
)
state_remove = method_body(MANAGER, "- (void)removeEpisodeStateFromWatch:")
require(
    "state.episodeHash" in state_remove
    and "ICAppleWatchManifestRemoveEpisodes" in state_remove
    and "CDEpisode" not in state_remove,
    "State removal must persist and transport the hash tombstone without resolving CDEpisode.",
)

commit = method_body(VIEW, "commitEditingStyle:")
trailing = method_body(VIEW, "trailingSwipeActionsConfigurationForRowAtIndexPath:")
context_menu = method_body(VIEW, "contextMenuConfigurationForRowAtIndexPath:")
for name, body in (("edit delete", commit), ("trailing swipe", trailing)):
    require(
        "removeEpisodeStateFromWatch:state" in body
        and "episodeWithObjectHash" not in body,
        f"{name} must remain available for an orphaned Watch state.",
    )
require(
    "removeEpisodeStateFromWatch:state" in context_menu
    and "if (!episode)" not in context_menu,
    "The context menu must still offer removal when local episode metadata is unavailable.",
)


print("Watch orphan-state removal regression checks passed")
