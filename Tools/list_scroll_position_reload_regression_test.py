#!/usr/bin/env python3
"""Pins that a list's episode-count change cannot throw the user back to the top.

Regression: ListEpisodesTableViewController pages its episodes. updateEpisodes drops
loadedEpisodes, resets nextPageOffset to 0 and calls reloadData — so the table is briefly
empty, contentSize collapses and UIKit clamps contentOffset to the top. That runs from the
"list.numberOfEpisodes" KVO, which fires whenever the count changes (feed refresh, a
finished episode, an applied iCloud state). While the user was scrolled into the list, the
list jumped back to its beginning on its own.

The existing gates did not cover this: suppressNextListReload is for swipe row updates,
userAction for explicit edits, _deferEpisodeReloadDuringInteraction only for swipe and
context-menu interactions, and the 1 s coalescing only while a feed refresh is running.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    require(signature in source, f"Missing method: {signature}")
    return source.split(signature, 1)[1].split("\n- (", 1)[0]


source = (ROOT / "Classes" / "ListEpisodesTableViewController.m").read_text()

# The reset that makes the jump possible must stay recognisable — if updateEpisodes ever
# stops discarding the pages, this whole guard can go.
update_episodes = method_body(source, "- (void) updateEpisodes")
require(
    "self.loadedEpisodes = [[NSMutableArray alloc] init];" in update_episodes
    and "self.nextPageOffset = 0;" in update_episodes,
    "updateEpisodes no longer resets the paging — re-check whether the scroll guard below "
    "is still needed.",
)

reload_after_count = method_body(source, "- (void) _reloadListAfterCountChange")

require(
    "self.tableView.dragging || self.tableView.decelerating" in reload_after_count,
    "A count-change reload must not empty the table while a scroll is running.",
)
require(
    "coalescedPerformSelector:@selector(_reloadListAfterCountChange) afterDelay:1.0"
    in reload_after_count,
    "The deferred reload must be retried once scrolling settled, not dropped.",
)

require(
    "self.nextPageOffset > EPISODE_PAGE_SIZE" in reload_after_count,
    "Only a list the user actually paged into needs its scroll position preserved.",
)
require(
    "[self _storeScrollPosition];" in reload_after_count
    and "_didRestoreScrollPosition = NO;" in reload_after_count,
    "The offset must be persisted and the restore re-armed before updateEpisodes wipes the "
    "pages, so the existing paging loop can walk back to it.",
)
require(
    reload_after_count.find("_didRestoreScrollPosition = NO;")
    < reload_after_count.find("[self updateEpisodes];"),
    "The scroll position has to be captured BEFORE updateEpisodes discards the pages.",
)

# The restore loop this leans on: it keeps paging until the content is tall enough and only
# then restores, so re-arming the flag is enough to walk back to a deep offset.
restore = method_body(source, "- (void) _restoreScrollPositionIfNeeded")
require(
    "if (_didRestoreScrollPosition) {" in restore
    and "[self _loadNextPage];" in restore
    and "ICRestoreScrollPositionForScrollView(key, self.tableView);" in restore,
    "The restore must still page up to the stored offset before restoring it.",
)

print("list scroll position reload regression checks passed")
