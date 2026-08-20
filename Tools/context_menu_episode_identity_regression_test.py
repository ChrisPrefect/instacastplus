#!/usr/bin/env python3
"""Keep an open episode context menu bound to the selected episode.

When a completed download disappears from a filtered list, every later row gets
a new index path.  The context menu must therefore capture the episode identity,
not the original row, and list reloads must wait until the menu has dismissed.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EPISODES = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
EPISODES_HEADER = (ROOT / "Classes" / "EpisodesTableViewController.h").read_text()
LIST_EPISODES = (ROOT / "Classes" / "ListEpisodesTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body for method: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise SystemExit(f"Unterminated method: {signature}")


configuration = method_body(
    EPISODES,
    "contextMenuConfigurationForRowAtIndexPath:",
)
require(
    "CDEpisode* episode" in configuration
    and "self.episodes[indexPath.row]" in configuration,
    "The context-menu configuration must capture the selected episode before the row can move.",
)
require(
    "configurationWithIdentifier:episode.objectHash" in configuration,
    "The context-menu configuration identifier must be the stable episode hash, not nil.",
)
require(
    "_contextMenuForEpisode:episode" in configuration
    and "_contextMenuForIndexPath:indexPath" not in configuration,
    "The deferred action provider must build the menu from the captured episode identity.",
)

menu = method_body(EPISODES, "- (UIMenu *) _contextMenuForEpisode:(CDEpisode*)episode")
require(
    "_indexPathForEpisode:episode" in menu,
    "The identity-bound menu builder must resolve the episode's current row.",
)

index_menu = method_body(
    EPISODES,
    "- (UIMenu *) _contextMenuForIndexPath:(NSIndexPath *)indexPath",
)
require(
    "toggleFavoriteAtIndexPath:currentIndexPath" in index_menu
    and "_removeEpisodeFromDisplayedListIfNeededAfterMutation:episode atIndexPath:currentIndexPath"
        in index_menu
    and "[strongSelf.episodes objectAtIndex:indexPath.row]" not in index_menu,
    "Context-menu actions must never re-read an episode through the original index path.",
)

require(
    "- (BOOL) _deferEpisodeReloadDuringInteraction;" in EPISODES_HEADER,
    "Filtered-list controllers need a shared gate for reloads while an episode interaction is open.",
)
defer_reload = method_body(EPISODES, "- (BOOL) _deferEpisodeReloadDuringInteraction")
require(
    "contextMenuInteractionActive" in defer_reload
    and "ICEpisodeListDeferredUpdateEpisodeReload" in defer_reload,
    "The interaction gate must remember a full episode refetch while the context menu is open.",
)

will_display = method_body(EPISODES, "willDisplayContextMenuWithConfiguration:")
will_end = method_body(EPISODES, "willEndContextMenuInteractionWithConfiguration:")
require(
    "contextMenuInteractionActive = YES" in will_display,
    "The table must enter its update gate when UIKit displays the context menu.",
)
require(
    "addCompletion:" in will_end
    and "contextMenuInteractionActive = NO" in will_end
    and "_flushDeferredEpisodeInteractionUpdate" in will_end,
    "Deferred list changes must flush only after the context-menu dismissal animation completes.",
)

count_reload = method_body(LIST_EPISODES, "- (void) _reloadListAfterCountChange")
require(
    "_deferEpisodeReloadDuringInteraction" in count_reload
    and count_reload.find("_deferEpisodeReloadDuringInteraction")
        < count_reload.find("updateEpisodes"),
    "A filtered-list count change must be deferred before it mutates the episode array or table.",
)

print("Context-menu episode identity regression checks passed")
