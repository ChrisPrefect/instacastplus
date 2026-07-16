#!/usr/bin/env python3
"""Pins News Mode recycling to background selection and bounded main-context batches."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
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


recycle = method_body("- (void) _recycleOldEpisodesInNewsModeFeed:")

plan_start = SOURCE.find("static ICNewsModeRecyclePlan* ICNewsModeRecyclePlanForFeedObjectID")
plan_end = SOURCE.find("static NSArray<NSDictionary*>* ICAutoDownloadCandidatesForFeedObjectIDs", plan_start)
require(plan_start != -1 and plan_end != -1, "Missing the background News Mode selection plan.")
selection_plan = SOURCE[plan_start:plan_end]
require(
    "startOfDayForDate" in selection_plan
    and "pubDate < %@ OR pubDate >= %@" in selection_plan
    and "pubDate >= %@ AND pubDate < %@" in selection_plan,
    "News Mode must keep every episode from the newest calendar day and classify all other publication dates as old.",
)
require(
    selection_plan.count("NSManagedObjectIDResultType") == 2,
    "The background News Mode scan must return thread-safe object IDs for both old and newest-day episodes.",
)

require(
    "QOS_CLASS_UTILITY" in recycle and "newBackgroundContext" in recycle,
    "News Mode must select the newest publication day and affected episode IDs in a utility-priority background context.",
)
require(
    "feed.episodes" not in recycle and "sortedArrayUsingDescriptors" not in recycle,
    "News Mode must not fault and sort the feed's complete episode relationship on the main thread.",
)
apply_batch = method_body("- (void) _applyNewsModeRecyclePlan:")
require(
    "markEpisode:" not in recycle and "markEpisode:" not in apply_batch,
    "News Mode must not use the per-episode mark-and-save API.",
)
require(
    "ICNewsModeRecycleBatchSize" in apply_batch
    and "dispatch_async(dispatch_get_main_queue()" in apply_batch,
    "News Mode changes must be applied in bounded batches separated by main-queue hops.",
)
require(
    "saveReturningError" in apply_batch,
    "Each bounded News Mode batch must be persisted once, not once per episode.",
)
require(
    "episode.consumed = YES" in apply_batch
    and "episode.position = 0" in apply_batch
    and "episode.consumed = NO" in apply_batch,
    "News Mode must mark older episodes played/reset and keep every episode from the newest publication day unplayed.",
)
require(
    "removeCacheForEpisodes:" in apply_batch and "removeCacheForEpisode:" not in apply_batch,
    "News Mode cache cleanup must use the bulk cache API for each bounded batch.",
)
require(
    "beginLocalOutboxBatch" in recycle and "endLocalOutboxBatch" in recycle,
    "The complete News Mode mutation must defer iCloud outbox draining until all batches are applied.",
)

refresh = method_body("- (void) refreshFeed:")
reload_feed = method_body("- (void) reloadContentOfFeed:")
require(
    "_recycleOldEpisodesInNewsModeFeed:feed completion:" in refresh,
    "Regular feed refresh must wait for asynchronous News Mode recycling before it finishes.",
)
require(
    "_recycleOldEpisodesInNewsModeFeed:feed completion:" in reload_feed,
    "Full feed reload must use the same asynchronous News Mode recycling path.",
)

print("News Mode background batch regression checks passed")
