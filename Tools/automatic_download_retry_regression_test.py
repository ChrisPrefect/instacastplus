#!/usr/bin/env python3
"""Pins bounded, classified, one-shot scheduled retries for automatic downloads."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
CACHE_HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = source.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require(
    "retryFailedAutomaticDownloadsIfPossible" in CACHE_HEADER,
    "Feed and connectivity lifecycle code needs one public event-driven retry entry point.",
)

for token in (
    "ICAutomaticDownloadRetryScanBatchSize",
    "ICAutomaticDownloadRetryTrackedCapacity",
    "ICAutomaticDownloadRetryInitialBackoff",
    "ICAutomaticDownloadRetryMaximumBackoff",
    "ICAutomaticDownloadRetryClassificationKey",
    "ICAutomaticDownloadRetryAttemptKey",
    "ICAutomaticDownloadRetryNextEligibleTimestampKey",
    "ICAutomaticDownloadRetryTransient",
    "ICAutomaticDownloadRetryPermanent",
):
    require(token in CACHE, f"Missing bounded retry state: {token}")

require(
    "NSMutableOrderedSet<NSString*>*" in CACHE
    and "_pendingAutomaticRetryEpisodeHashes" in CACHE
    and "NSMutableSet<NSString*>*" in CACHE
    and "_automaticRetryInFlightEpisodeHashes" in CACHE,
    "Pending and active automatic retries must retain stable episode hashes, not managed episode objects.",
)

classification = method_body(CACHE, "- (NSString*)_automaticRetryClassificationForError:")
require(
    "NSURLErrorDomain" in classification
    and "NSURLErrorTimedOut" in classification
    and "NSURLErrorNetworkConnectionLost" in classification
    and "NSURLErrorNotConnectedToInternet" in classification,
    "Offline, timeout, and connection-loss errors must be classified as transient.",
)
require(
    "NSURLErrorUserAuthenticationRequired" in classification
    and "NSURLErrorUserCancelledAuthentication" in classification
    and "NSURLErrorBadURL" in classification,
    "Authentication and invalid-request URL errors must never enter an automatic retry storm.",
)
require(
    "error.code == 5" in classification
    and "statusCode == 408" in classification
    and "statusCode == 425" in classification
    and "statusCode == 429" in classification
    and "statusCode >= 500" in classification
    and "statusCode >= 400" in classification,
    "Truncation, retryable HTTP statuses, server errors, and permanent 4xx responses need explicit classifications.",
)
require(
    "NSUnderlyingErrorKey" in classification,
    "Wrapped transport failures must be classified from their concrete underlying error.",
)

record = method_body(CACHE, "- (void)_recordDownloadError:")
require(
    'if (!reportsFailureToUser)' not in record
    and '@"automatic": @(automatic)' in record
    and '@"reportsFailureToUser": @(reportsFailureToUser)' in record,
    "Automatic failures must remain visible without presenting a modal error.",
)
require(
    "ICAutomaticDownloadRetryClassificationKey" in record
    and "ICAutomaticDownloadRetryAttemptKey" in record
    and "ICAutomaticDownloadRetryNextEligibleTimestampKey" in record
    and "_automaticRetryBackoffForAttempt:" in record,
    "Every automatic failure must durably store its classification, attempt count, and exponential next-eligible time.",
)
require(
    "_scheduleAutomaticRetryWakeAtTimestamp:nextEligibleTimestamp" in record,
    "A transient automatic failure must schedule a wake for its persisted next-eligible time.",
)

backoff = method_body(CACHE, "- (NSTimeInterval)_automaticRetryBackoffForAttempt:")
require(
    "ICAutomaticDownloadRetryInitialBackoff" in backoff
    and "ICAutomaticDownloadRetryMaximumBackoff" in backoff,
    "Automatic retry backoff must be exponential and capped.",
)

policy = method_body(CACHE, "- (BOOL)_automaticRetryFailureIsStaleForEpisode:")
for token in (
    "episode.isDeleted",
    "feed.isDeleted",
    "!feed.subscribed",
    "feed.parked",
    "episode.consumed",
    "episode.archived",
    "automaticCachingDisabledForEpisode",
    "AutoCacheNewAudioEpisodes",
    "AutoCacheNewVideoEpisodes",
):
    require(token in policy, f"Automatic failure cleanup is missing policy state: {token}")

retry_automatic = method_body(CACHE, "- (void)retryFailedAutomaticDownloadsIfPossible")
require(
    "_cacheIndexReady" in retry_automatic
    and "self.cacheHistory.isLoaded" in retry_automatic
    and "_clearingAllCache" in retry_automatic,
    "Automatic retry cleanup must wait for durable cache/history state without depending on connectivity.",
)
require(
    "_automaticRetryScanInProgress" in retry_automatic
    and "_automaticRetryRescanRequested" in retry_automatic
    and "_processAutomaticRetryScanChunk" in retry_automatic,
    "Repeated external events must coalesce into a bounded eligibility scan.",
)
require(
    "for (CDEpisode* episode in [_failedDownloadEpisodes copy])" not in retry_automatic,
    "The public retry trigger must not synchronously scan every failed episode on the main thread.",
)

scan = method_body(CACHE, "- (void)_processAutomaticRetryScanChunk")
require(
    "ICAutomaticDownloadRetryScanBatchSize" in scan
    and "subarrayWithRange:" in scan
    and "dispatch_async(dispatch_get_main_queue()" in scan,
    "Large failure lists must be scanned in fixed-size main-turn chunks with an asynchronous yield.",
)
require(
    "_pendingAutomaticRetryEpisodeHashes addObject:identifier" in scan
    and "ICAutomaticDownloadRetryTransient" in scan
    and "ICAutomaticDownloadRetryNextEligibleTimestampKey" in scan,
    "Only currently eligible transient failures may enter the hash-only pending queue.",
)
require(
    "_automaticRetryNextWakeTimestamp" in scan
    and "_scheduleAutomaticRetryWakeAtTimestamp:" in scan,
    "A restore or early external scan must retain the earliest future eligibility as the next wake.",
)

schedule_wake = method_body(CACHE, "- (void)_scheduleAutomaticRetryWakeAtTimestamp:")
require(
    "if (timestamp <= 0) {\n"
    "        return;\n"
    "    }" in schedule_wake,
    "The zero sentinel means there is no future retry and must not start another eligibility scan.",
)
require(
    "dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER" in schedule_wake
    and "dispatch_source_set_timer" in schedule_wake
    and "DISPATCH_TIME_FOREVER" in schedule_wake,
    "Automatic retries need one one-shot dispatch timer, not a repeating poll.",
)
require(
    "_automaticRetryWakeSource" in schedule_wake
    and "_automaticRetryWakeTimestamp" in schedule_wake
    and "_cancelAutomaticRetryWake" in schedule_wake,
    "Scheduling must keep at most one wake and replace it only when an earlier retry becomes eligible.",
)
require(
    "retryFailedAutomaticDownloadsIfPossible" in schedule_wake,
    "The one-shot wake must re-enter the bounded eligibility scan when its deadline arrives.",
)
require(
    "if (timestamp <= [NSDate date].timeIntervalSince1970) {\n"
    "        [self retryFailedAutomaticDownloadsIfPossible];\n"
    "        return;\n"
    "    }" in schedule_wake,
    "A deadline that expires during a chunked scan must immediately start a fresh eligibility scan instead of being dropped.",
)

cancel_wake = method_body(CACHE, "- (void)_cancelAutomaticRetryWake")
require(
    "dispatch_source_cancel" in cancel_wake
    and "_automaticRetryWakeSource = nil" in cancel_wake
    and "_automaticRetryWakeTimestamp = 0" in cancel_wake,
    "The one-shot retry wake must have one explicit cancellation path that clears all scheduler state.",
)

drain = method_body(CACHE, "- (void)_drainPendingAutomaticRetries")
require(
    "ICAutomaticDownloadRetryTrackedCapacity" in drain
    and "_downloadOperationsByIdentifier.count" in drain
    and "_automaticRetryInFlightEpisodeHashes.count" in drain
    and "[self canDownload]" in drain
    and "self.suspended" in drain,
    "Retry creation must wait for an active network queue and stop at a small fixed tracked-download capacity.",
)
require(
    "firstObject" in drain
    and "removeObjectAtIndex:0" in drain
    and "episodeWithObjectHash:identifier" in drain
    and "_automaticRetryFailureIsStaleForEpisode:episode" in drain,
    "Pending retries must resolve managed objects just in time and revalidate policy before starting.",
)
require(
    "processedCount < ICAutomaticDownloadRetryScanBatchSize" in drain
    and "dispatch_async(dispatch_get_main_queue()" in drain,
    "Synchronous start rejections and stale hashes must also yield instead of draining an unbounded queue in one main turn.",
)

terminal = method_body(CACHE, "- (void)_automaticRetryOperationDidFinishWithIdentifier:")
require(
    "_automaticRetryInFlightEpisodeHashes removeObject:identifier" in terminal
    and "_drainPendingAutomaticRetries" in terminal
    and "_pendingAutomaticRetryEpisodeHashes addObject" not in terminal,
    "Terminal completion must free capacity and drain the next hash without immediately re-adding the failed item.",
)
finish = method_body(CACHE, "- (void)_finishCacheOperationDidEnd:")
require(
    "_automaticRetryOperationDidFinishWithIdentifier:operation.identifier" in finish,
    "Every terminal download outcome must release automatic-retry capacity.",
)
cancel = method_body(CACHE, "- (void)_cancelTrackedDownloadOperationAfterDurableIntent:")
require(
    "_automaticRetryOperationDidFinishWithIdentifier:operation.identifier" in cancel,
    "A queued retry cancelled before execution must also release its retry capacity.",
)

retry_source = "\n".join((retry_automatic, scan, schedule_wake, cancel_wake, drain, terminal, backoff))
require(
    "dispatch_after" not in retry_source and "NSTimer" not in retry_source,
    "Retry correctness must use persisted eligibility and a single deadline source, never polling or ad-hoc delays.",
)

clear_all = method_body(CACHE, "- (void) clearAllDownloadErrorsWithCompletion:")
require(
    "_cancelAutomaticRetryWake" in clear_all,
    "Clearing every failed download must cancel the obsolete scheduled wake.",
)

network_change = method_body(CACHE, "- (void) _handleNetworkStatusChanged")
history_ready = method_body(CACHE, "- (void)_restoreCachingEpisodesWhenHistoryReady")
restore_failures = method_body(CACHE, "- (void)_restoreFailedDownloads")
refresh_finish = method_body(SUBSCRIPTIONS, "- (void) checkRefreshOperationsTimer:")
for body, event in (
    (network_change, "an allowed network change"),
    (history_ready, "cache-history readiness"),
    (restore_failures, "restored failure-state readiness"),
    (refresh_finish, "a successful feed-refresh batch"),
):
    require(
        "retryFailedAutomaticDownloadsIfPossible" in body,
        f"Failed automatic downloads must be reconsidered after {event}, without a polling timer.",
    )

manual_retry = method_body(CACHE, "- (BOOL)retryFailedDownloadForEpisode:")
require(
    'metadata[@"automatic"]' in manual_retry
    and "autoCache:automatic" in manual_retry
    and "_automaticRetryAttemptsByActiveEpisodeHash" in manual_retry,
    "A user-triggered retry must preserve automatic semantics and carry its durable attempt count into the new operation.",
)
require(
    "downloadErrorForEpisode:episode" in manual_retry,
    "A user-triggered retry must return the concrete start failure for the UI.",
)

print("Automatic download retry regression checks passed")
