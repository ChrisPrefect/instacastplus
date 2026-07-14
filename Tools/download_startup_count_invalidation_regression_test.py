#!/usr/bin/env python3
"""Pins download-state changes to download-only feed count invalidation."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EPISODE_SOURCE = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()
FEED_SOURCE = (ROOT / "Classes" / "Model" / "CDFeed.m").read_text()
FEED_HEADER = (ROOT / "Classes" / "Model" / "CDFeed.h").read_text()


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


set_downloaded = body(EPISODE_SOURCE, "- (void) setDownloaded:")
require("invalidateDownloadedCount" in set_downloaded and "invalidateCounts" not in set_downloaded,
        "Changing download state must not invalidate episode and unplayed counts for every cached episode.")
require("- (void) invalidateDownloadedCount;" in FEED_HEADER,
        "CDFeed must expose a download-only count invalidation API.")

invalidate_downloaded = body(FEED_SOURCE, "- (void) invalidateDownloadedCount")
require('willChangeValueForKey:@"downloadedCount"' in invalidate_downloaded and
        'didChangeValueForKey:@"downloadedCount"' in invalidate_downloaded,
        "Download-only invalidation must still publish the changed downloaded count.")
require("unplayedCount" not in invalidate_downloaded and
        "episodesCount" not in invalidate_downloaded and
        "countForFetchRequest" not in invalidate_downloaded,
        "Download-only invalidation must never trigger unrelated feed SQL counts.")

print("Download startup count invalidation regression checks passed")
