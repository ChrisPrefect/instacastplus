#!/usr/bin/env python3
"""Pins bounded pull-to-refresh dispatch around iCloud stub hydration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes/Model/SubscriptionManager.m").read_text()
CONTROLLER = (ROOT / "Classes/SubscriptionsTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


refresh_start = SOURCE.index(
    "- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:"
)
refresh_end = SOURCE.index("\n// Initial number of episodes", refresh_start)
refresh_body = SOURCE[refresh_start:refresh_end]

require(
    "refreshAllFeedsForce:YES etagHandling:YES completion:nil" in CONTROLLER,
    "Pull to refresh must dispatch a forced refresh of all subscribed feeds.",
)
require(
    "(!feed.lastUpdate && feed.episodes.count == 0)" in refresh_body,
    "An iCloud subscription stub must remain on the bounded hydration path instead of entering the full feed merge.",
)
require(
    "[[EpisodeLoadingManager sharedManager] isLoadingFeed:feed]" in refresh_body,
    "Pull to refresh must not duplicate a feed whose episode backlog is already loading.",
)
stub_guard = refresh_body.index("(!feed.lastUpdate && feed.episodes.count == 0)")
duration_check = refresh_body.index("[self _feedNeedsDurationMetadataRefresh:feed]")
parser_enqueue = refresh_body.index("[self.parserQueue addOperation:feedParser];")
require(
    stub_guard < duration_check < parser_enqueue,
    "Stub/loading rejection must happen before the synchronous duration query and parser dispatch; normal feeds must still reach the parser queue.",
)
require(
    "completion(YES, @[], nil);" in refresh_body[:duration_check],
    "A skipped hydration-owned feed must complete its batch slot without leaving pull-to-refresh hanging.",
)

print("Pull-to-refresh feed dispatch regression checks passed")
