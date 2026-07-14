#!/usr/bin/env python3
"""Pins feed auto-download scans to one bounded Core Data pipeline."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing function or method: {signature}")
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
    raise AssertionError(f"Unterminated body: {signature}")


def constant_value(name: str) -> int:
    match = re.search(rf"static const NSUInteger {name}\s*=\s*(\d+)\s*;", SOURCE)
    require(match is not None, f"Missing fixed bound: {name}")
    return int(match.group(1))


feed_batch_size = constant_value("ICAutoDownloadFeedScanBatchSize")
candidate_batch_size = constant_value("ICAutoDownloadCandidateDeliveryBatchSize")
require(1 <= feed_batch_size <= 32, "The background scan must use a small fixed feed batch.")
require(1 <= candidate_batch_size <= 64, "Main-thread candidate delivery must use a small fixed batch.")

interface = SOURCE[SOURCE.find("@interface SubscriptionManager ()"):SOURCE.find("@end", SOURCE.find("@interface SubscriptionManager ()"))]
require("autoDownloadFeedScanQueue" in interface and "autoDownloadFeedScanInFlight" in interface,
        "The manager must own one serial scan queue and an explicit one-scan-in-flight gate.")

initializer = body("- (id) init")
require("dispatch_queue_create" in initializer and "DISPATCH_QUEUE_SERIAL" in initializer,
        "Feed scans must run through one dedicated serial queue.")

scan = body("static NSArray<NSDictionary*>* ICAutoDownloadCandidatesForFeedObjectIDs")
require(scan.count("executeFetchRequest") >= 2,
        "The scan must ask Core Data for the latest eligible day and then only that day's candidates.")
require("propertiesToGroupBy" in scan and 'expressionForFunction:@"max:"' in scan,
        "Latest-day selection must happen in the persistent-store query, not by materializing every episode.")
latest_day_predicate_start = scan.find("latestDatesRequest.predicate")
latest_day_predicate_end = scan.find("latestDatesRequest.resultType", latest_day_predicate_start)
require(latest_day_predicate_start >= 0 and latest_day_predicate_end > latest_day_predicate_start,
        "The latest publication-day query is missing.")
latest_day_predicate = scan[latest_day_predicate_start:latest_day_predicate_end]
require("consumed" not in latest_day_predicate and "archived" not in latest_day_predicate,
        "The newest calendar day must come from every dated episode; filtering it to eligible rows downloads progressively older days.")
require('sortDescriptorWithKey:@"feed.uid"' in scan and 'sortDescriptorWithKey:@"pubDate"' in scan,
        "Candidate rows must be stably grouped by feed and ordered newest-first by Core Data.")
require("consumed == NO" in scan and "archived == NO" in scan,
        "The SQL candidate scan must retain the existing unconsumed/unarchived semantics.")
require("chronologicallySortedEpisodes" not in scan,
        "The bounded scan must not fetch and sort every feed relationship independently.")

start = body("- (void)_startPendingAutoDownloads")
require("_autoDownloadEpisodesInFeedAsynchronously:nil" in start and "for (" not in start,
        "Draining retained work must enter the single pipeline once, not fan out once per feed.")
require("removeAllObjects" not in start,
        "Starting a scan must not discard every retained feed intent at once.")

asynchronous = body("- (void)_autoDownloadEpisodesInFeedAsynchronously:")
require("pendingAutoDownloadFeedObjectIDs" in asynchronous and "autoDownloadFeedScanInFlight" in asynchronous,
        "Direct per-feed requests must enqueue into and share the same in-flight-gated pipeline.")
require("ICAutoDownloadFeedScanBatchSize" in asynchronous and "subarrayWithRange" in asynchronous,
        "Each scan must remove only a fixed-size feed batch from the pending set.")
require("dispatch_async(self.autoDownloadFeedScanQueue" in asynchronous,
        "The selected batch must run on the manager's serial utility queue.")
require(asynchronous.count("newBackgroundContext") == 1,
        "One pipeline batch must create exactly one background Core Data context.")
require("ICAutoDownloadCandidatesForFeedObjectIDs" in asynchronous,
        "The pipeline must use the bounded SQL/Core Data candidate scan.")
require("chronologicallySortedEpisodes" not in asynchronous and "dispatch_get_global_queue" not in asynchronous,
        "The asynchronous path must not retain the old per-feed full scan/global-task fan-out.")
require("ICAutoDownloadCandidateDeliveryBatchSize" in asynchronous,
        "Candidate objects must reach the main context in fixed-size batches.")
require(asynchronous.count("dispatch_async(dispatch_get_main_queue(), ^{") >= 2,
        "Each main-context candidate batch must yield with an asynchronous queue hop.")
require("dispatch_after" not in asynchronous and "NSTimer" not in asynchronous,
        "Pipeline yielding must not be implemented with pacing delays or timers.")

main_handoff = asynchronous.split("dispatch_async(dispatch_get_main_queue(), ^{", 1)[1]
start_download = main_handoff.find("[self _autoDownloadEpisode:nil sortedEpisodes:thisSortedEpisodes]")
revalidate_feed = main_handoff.find("existingObjectWithID:feedObjectID")
require(revalidate_feed != -1 and "!currentFeed.subscribed" in main_handoff[:start_download]
        and "currentFeed.parked" in main_handoff[:start_download],
        "Every delivered batch must revalidate that the feed is still active.")
require("episode.feed isEqual:currentFeed" in main_handoff[:start_download],
        "Every candidate must still belong to the feed that produced it before download starts.")

error_start = main_handoff.find("if (scanError)")
delivery_start = main_handoff.find("__block NSUInteger candidateIndex")
require(error_start != -1 and delivery_start > error_start,
        "A real background scan error needs an explicit path before candidate delivery.")
error_path = main_handoff[error_start:delivery_start]
require("addObjectsFromArray:feedObjectIDs" in error_path,
        "A failed scan must retain its complete feed intent for a later real trigger.")
require("_startPendingAutoDownloads" not in error_path,
        "A failed scan must not immediately spin on the same persistent error.")

all_feeds = body("- (void) autoDownloadAllFeedsAsynchronously")
for forbidden in ("initWithConcurrencyType", "newBackgroundContext", "performBlockAndWait",
                  "chronologicallySortedEpisodes", "dispatch_get_main_queue"):
    require(forbidden not in all_feeds,
            "All-feeds auto-download must only enqueue feed IDs into the shared bounded pipeline.")
require("pendingAutoDownloadFeedObjectIDs" in all_feeds and "_startPendingAutoDownloads" in all_feeds,
        "All-feeds auto-download must route through the same retained pipeline.")

print("Bounded feed auto-download pipeline regression checks passed")
