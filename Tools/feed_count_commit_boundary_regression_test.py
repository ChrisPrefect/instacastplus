#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FEED = (ROOT / "Classes" / "Model" / "CDFeed.m").read_text()
EPISODE = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


load = body(FEED, "- (void)calculateCountsWithCompletion:")
batch = body(FEED, "+ (void)_loadPendingCountBatch")
database_changes = body(DATABASE, "- (void) managedObjectContextObjectsDidChangeNotification:")
database_save = body(DATABASE, "- (NSError*) saveReturningError")
archived = body(EPISODE, "- (void) setArchived:")
consumed = body(EPISODE, "- (void) setConsumed:")
starred = body(EPISODE, "- (void) setStarred:")
set_feed = body(EPISODE, "- (void) setFeed:")
carplay_sections = body(SCENE, "- (NSArray<CPListSection*>*)carPlayPodcastSections")
carplay_bulk = body(SCENE, "- (void)carPlayRefreshPodcastCountsForFeeds:")

require("_countsRequireSave" in load and "invalidateCountsAwaitingSave:" in FEED
        and "feedCountChangesDidSave" in FEED,
        "A feed count requested from a dirty view context must wait for the successful save boundary.")
require("feedCountChangesDidSave" in database_save and "_feedsAwaitingCountSave" in database_save,
        "DatabaseManager must release only relevant feed-count waits after a successful persistent save.")
require("managedObjectContext.hasChanges" not in load,
        "Unrelated transient Core Data changes must not leave visible feed counts waiting forever.")
require("invalidateCounts" in database_changes and "changedValuesForCurrentEvent" in database_changes,
        "Main-context inserts, deletes, and background merges must invalidate the affected feed snapshots.")
require("ICFeedPropertyAffectsEpisodeCount" in database_changes
        and "kFeedPropertyEpisodeLoadingComplete" in DATABASE
        and "kFeedPropertyTotalExpectedEpisodes" in DATABASE,
        "Lazy-loading metadata changes must invalidate the displayed episode count.")
require("invalidateCounts" not in archived and "invalidateCounts" not in consumed
        and "invalidateCounts" not in starred and "invalidateCounts" not in set_feed,
        "Episode setters must not race the centralized save/merge-aware invalidation path.")
require("wasArchived" in archived and "wasConsumed" in consumed and "wasStarred" in starred,
        "Idempotent episode assignments must not emit redundant Core Data/KVO changes.")
require("episodeLoadingComplete" in batch and "!episodeLoadingComplete" in batch,
        "Expected remote totals may override the local count only while lazy loading is incomplete.")
require("carPlayRefreshPodcastCountsForFeeds" in carplay_sections,
        "CarPlay must request one grouped podcast-count snapshot instead of one load per feed.")
require("calculateCountsWithCompletion" in carplay_bulk and "newBackgroundContext" not in carplay_bulk,
        "CarPlay must reuse CDFeed's coalesced count batch instead of starting a second aggregate engine.")


print("Feed count commit-boundary regression checks passed")
