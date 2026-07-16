#!/usr/bin/env python3
"""Pins user refresh dispatch while episode hydration is in progress."""

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
    "An iCloud subscription stub must be detected for bounded hydration.",
)
require(
    "[self hydrateStubFeed:feed completion:" in refresh_body,
    "A user refresh must actively hydrate an iCloud subscription stub instead of silently skipping it.",
)
stub_guard = refresh_body.index("(!feed.lastUpdate && feed.episodes.count == 0)")
tracking_start = refresh_body.index("[self.refreshingFeedURLs addObject:url]")
hydration_start = refresh_body.index("[self hydrateStubFeed:feed completion:")
parser_enqueue = refresh_body.index("[self.parserQueue addOperation:feedParser];")
require(
    tracking_start < stub_guard < hydration_start < parser_enqueue,
    "Stub hydration must be owned by refresh tracking so the control stays active until network work finishes.",
)
require(
    "_finishRefreshingURL:url" in refresh_body[hydration_start:parser_enqueue],
    "Stub hydration completion must finish its tracked refresh slot.",
)
require(
    "[[EpisodeLoadingManager sharedManager] isLoadingFeed:feed]" not in refresh_body[:tracking_start],
    "An episode backlog must not silently suppress the feed network refresh.",
)

merge_start = SOURCE.index("- (NSArray*) _mergeLocalFeed:")
merge_end = SOURCE.index("\n- (void) _deleteUnavailableEpisodesFromFeed:", merge_start)
merge_body = SOURCE[merge_start:merge_end]
require(
    "kFeedPropertyEpisodeLoadingComplete" in merge_body
    and "kFeedPropertyTotalExpectedEpisodes" in merge_body
    and "reachedExistingEpisode" in merge_body,
    "Only a feed with a real bounded-load backlog may limit refresh to the new head before its first existing episode.",
)
require(
    "if (hasIncompleteEpisodeBacklog &&" in merge_body
    and "![newHeadEpisodes containsObject:remoteEpisode]" in merge_body,
    "Refresh must not bulk-insert the historical backlog while its bounded loader owns that work.",
)

print("Pull-to-refresh feed dispatch regression checks passed")
