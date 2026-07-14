#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FEED = (ROOT / "Classes" / "Model" / "CDFeed.m").read_text()
CELL = (ROOT / "Classes" / "SubscriptionTableViewCell.m").read_text()
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


episodes_getter = body(FEED, "- (NSInteger) episodesCount")
unplayed_getter = body(FEED, "- (NSInteger) unplayedCount")
load = body(FEED, "- (void)calculateCountsWithCompletion:")
batch = body(FEED, "+ (void)_loadPendingCountBatch")
invalidate = body(FEED, "- (void)invalidateCountsAwaitingSave:")
cell_refresh = body(CELL, "- (void)_refreshCounts")
carplay = body(SCENE, "- (CPListItem*)carPlayListItemForFeed:")

require("countForFetchRequest" not in episodes_getter and "countForFetchRequest" not in unplayed_getter,
        "Feed count property getters must never execute SQL on the UI/KVO path.")
require("newBackgroundContext" in batch and "propertiesToGroupBy" in FEED
        and "ICFeedCountBatchSize" in batch,
        "Feed counts must use bounded aggregate SQL on one background context per coalesced batch.")
require("_countsGeneration" in batch and "_countsGeneration" in invalidate,
        "An invalidation generation must prevent an older background result from restoring stale counts.")
require("_countsLoadInProgress" in load and "_countCompletionBlocks" in load
        and "gFeedsPendingCountLoad" in load,
        "Concurrent count requests for one feed must coalesce instead of issuing duplicate SQL queries.")
require("countError" in batch and "completionBlock(-1, -1)" in batch,
        "Count failures must remain unavailable instead of being reported as false zero counts.")
require("unplayedCount = -1" in invalidate and "episodesCount = -1" in invalidate
        and "self.unplayedCount = -1" not in invalidate and "self.episodesCount = -1" not in invalidate,
        "Invalidation must publish one deliberate KVO event without recursively invoking cached getters.")
require("countsLoaded" in cell_refresh and "calculateCountsWithCompletion" in cell_refresh
        and "countLoadPending" in cell_refresh,
        "Subscription cells must show only loaded snapshots and coalesce their refresh request.")
require("countsLoaded" in carplay and "calculateCountsWithCompletion" not in carplay,
        "A CarPlay podcast item must use only an existing snapshot; the list performs the batched refresh.")


print("Feed count async-generation regression checks passed")
