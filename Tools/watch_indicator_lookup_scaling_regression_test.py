#!/usr/bin/env python3
"""Pins the ordinary episode-cell Watch indicator to one canonical state snapshot."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CELL = (ROOT / "Classes" / "EpisodesTableViewCell.m").read_text()
MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
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


indicator = body(CELL, "- (void) updateWatchIndicatorState")
lookup = body(MANAGER, "- (BOOL)isEpisodeDownloadedOnWatch:")
invalidate = body(MANAGER, "- (void)_invalidateWatchTransferSnapshot")
rebuild = body(MANAGER, "- (void)_rebuildWatchTransferSnapshotIfNeeded")
downloaded_rebuild = body(MANAGER, "- (void)_rebuildWatchDownloadedEpisodeHashesIfNeeded")

require("isEpisodeDownloadedOnWatch:episode" in indicator,
        "The ordinary episode cell must still derive its Watch badge from the manager.")
require(
    "cachedWatchDownloadedEpisodeHashes" in MANAGER
    and "_rebuildWatchDownloadedEpisodeHashesIfNeeded" in lookup
    and "_rebuildWatchTransferSnapshotIfNeeded" not in lookup
    and "containsObject:episode.objectHash" in lookup
    and "stateForEpisodeHash" not in lookup,
    "A visible cell must use O(1) membership in the canonical Watch-state snapshot, not fetch Core Data.",
)
require(
    "cachedWatchDownloadedEpisodeHashes = nil" in invalidate,
    "Episode-state notifications must invalidate downloaded-hash membership with the transfer snapshot.",
)
require(
    "visibleEpisodeStates" in downloaded_rebuild
    and "state.downloadedOnWatch" in downloaded_rebuild
    and "addObject:state.episodeHash" in downloaded_rebuild,
    "Downloaded membership must be built lazily from canonical visible states so duplicate repairs stay correct.",
)
require(
    "_episodesByHashForEpisodeHashes" not in downloaded_rebuild
    and "_watchTransferContributionForState" not in downloaded_rebuild
    and "_liveDownloadProgressForState" not in downloaded_rebuild,
    "Ordinary cell rendering must not build transfer progress or hydrate episode metadata.",
)
require(
    "cachedWatchDownloadedEpisodeHashes = downloadedEpisodeHashes" in rebuild,
    "A full transfer rebuild should reuse its canonical states to refresh downloaded membership.",
)

print("Watch indicator lookup scaling regression checks passed")
