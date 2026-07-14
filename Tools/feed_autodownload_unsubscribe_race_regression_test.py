#!/usr/bin/env python3
"""Pins asynchronous auto-download to the feed's current subscription state."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
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


asynchronous = body("- (void)_autoDownloadEpisodesInFeedAsynchronously:")
main_handoff = asynchronous.split("dispatch_async(dispatch_get_main_queue(), ^{", 1)[1]
start_download = main_handoff.find("[self _autoDownloadEpisode:nil sortedEpisodes:thisSortedEpisodes]")
revalidate_feed = main_handoff.find("existingObjectWithID:feedObjectID")
revalidate_subscription = main_handoff.find("!currentFeed.subscribed")
require(revalidate_feed != -1 and revalidate_subscription != -1 and
        revalidate_feed < revalidate_subscription < start_download,
        "The main-thread handoff must re-fetch and revalidate the feed after an unsubscribe can race the background scan.")
require("currentFeed.parked" in main_handoff[:start_download] and
        "episode.feed isEqual:currentFeed" in main_handoff[:start_download],
        "Only episodes that still belong to the active subscribed feed may enter auto-download.")

print("Feed auto-download unsubscribe race regression checks passed")
