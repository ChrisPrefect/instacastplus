#!/usr/bin/env python3
"""Pins crash-safe, bounded recovery of feed auto-download handoffs."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUBSCRIPTION_H = (ROOT / "Classes" / "Model" / "SubscriptionManager.h").read_text()
SUBSCRIPTION_M = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE_M = (ROOT / "Classes" / "CacheManager.m").read_text()
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
ICLOUD = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
BACKUP_EXPORT = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
BACKUP_IMPORT = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    if source is SUBSCRIPTION_M:
        implementation = source.find("@implementation SubscriptionManager")
    elif source is CACHE_M:
        implementation = source.find("@implementation CacheManager")
    elif source is APP_DELEGATE:
        implementation = source.find("@implementation InstacastAppDelegate")
    else:
        implementation = 0
    start = source.find(signature, max(0, implementation))
    require(start != -1, f"Missing function or method: {signature}")
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
    raise AssertionError(f"Unterminated body: {signature}")


pending_key = "ICPendingAutoDownloadFeedUIDs"

require("recoverPendingAutoDownloadsAfterDatabaseStartup" in SUBSCRIPTION_H,
        "SubscriptionManager must expose the post-database-start recovery trigger.")
require(pending_key in SUBSCRIPTION_M,
        "The post-save handoff needs one durable device-local feed-UID queue.")

retain = body(SUBSCRIPTION_M, "- (void)_retainPendingAutoDownloadFeedUIDs:")
require("NSMutableOrderedSet" in retain and "setObject:" in retain and "synchronize" in retain,
        "Retaining an intent must deduplicate it and durably flush it before Core Data can be saved.")

finish_parse = body(SUBSCRIPTION_M, "- (void) _finishParsingFeed:")
require("pendingAutoDownloadFeedObjectIDs addObject" in finish_parse,
        "A parsed feed must retain its post-save handoff until the refresh batch commits.")

refresh_finish = body(SUBSCRIPTION_M, "- (void) checkRefreshOperationsTimer:")
retain_position = refresh_finish.find("_retainPendingAutoDownloadFeedObjectIDs:")
save_position = refresh_finish.find("saveReturningError")
drain_position = refresh_finish.find("_startPendingAutoDownloads")
require(retain_position != -1 and retain_position < save_position < drain_position,
        "A refresh batch must flush all retained feed IDs once before saving, then deliver only after the save.")
require(refresh_finish.count("_retainPendingAutoDownloadFeedObjectIDs:") == 1,
        "A large refresh must persist its whole handoff batch once, not rewrite defaults for every podcast.")

for signature in ("- (void) hydrateStubFeed:", "- (void) reloadContentOfFeed:"):
    ingestion = body(SUBSCRIPTION_M, signature)
    require(ingestion.find("_retainPendingAutoDownloadFeedUIDs:") < ingestion.find("saveReturningError") <
            ingestion.find("_autoDownloadEpisodesInFeedAsynchronously"),
            f"{signature} must persist intent before its save and start delivery afterwards.")

require("CacheManagerDidBecomeReadyForAutomaticDownloadsNotification" in CACHE_H and
        "isReadyForAutomaticDownloads" in CACHE_H,
        "Startup recovery needs an explicit cache-index plus download-history readiness contract.")
readiness = body(CACHE_M, "- (BOOL)isReadyForAutomaticDownloads")
for token in ("_cacheIndexReady", "cacheHistory.isLoaded", "_cachingEpisodesRestored"):
    require(token in readiness, f"Automatic-download readiness is missing {token}.")
history_ready = body(CACHE_M, "- (void)_restoreCachingEpisodesWhenHistoryReady")
restore_position = history_ready.find("restoreCachingEpisodes")
ready_notification_position = history_ready.find(
    "CacheManagerDidBecomeReadyForAutomaticDownloadsNotification", restore_position
)
require(restore_position != -1 and ready_notification_position > restore_position,
        "History readiness must be published only after persisted download jobs are restored.")

asynchronous = body(SUBSCRIPTION_M, "- (void)_autoDownloadEpisodesInFeedAsynchronously:")
require("isReadyForAutomaticDownloads" in asynchronous and
        asynchronous.find("isReadyForAutomaticDownloads") < asynchronous.find("autoDownloadFeedScanInFlight = YES"),
        "The durable queue must not be scanned or acknowledged before cache history is authoritative.")
download_position = asynchronous.find("[self _autoDownloadEpisode:nil sortedEpisodes:thisSortedEpisodes]")
ack_position = asynchronous.find("_removePendingAutoDownloadFeedUIDs:", download_position)
require(download_position != -1 and ack_position > download_position,
        "A feed intent may be acknowledged only after every candidate was handed to CacheManager.")
next_recovery_position = asynchronous.find(
    "recoverPendingAutoDownloadsAfterDatabaseStartup", ack_position
)
require(next_recovery_position > ack_position,
        "Acknowledging one feed batch must explicitly start recovery of the next persisted batch.")
scan_error = asynchronous[asynchronous.find("if (scanError)"):asynchronous.find("__block NSUInteger candidateIndex")]
require("_removePendingAutoDownloadFeedUIDs:" not in scan_error and
        "addObjectsFromArray:feedObjectIDs" in scan_error,
        "A failed Core Data scan must preserve both durable and in-memory intent for a real later trigger.")

recover = body(SUBSCRIPTION_M, "- (void)recoverPendingAutoDownloadsAfterDatabaseStartup")
for token in ("ICAutoDownloadFeedScanBatchSize", "subarrayWithRange:", "fetchLimit"):
    require(token in recover, f"Startup recovery is not demonstrably bounded: missing {token}.")
require("for (NSString* feedUID in recoveryFeedUIDs)" in recover and
        'uid == %@ AND subscribed == YES AND parked == NO' in recover and
        "request.fetchLimit = 1" in recover,
        "Each of the at most 20 UIDs needs one active-feed lookup; legacy duplicate UIDs must not crowd another UID out of a limited IN fetch.")
require("visibleFeeds" not in recover and "autoDownloadAllFeedsAsynchronously" not in recover,
        "Startup recovery must target only persisted UIDs, never scan the full subscription library.")
for token in ("!feed.subscribed", "feed.parked", "staleFeedUIDs", "_removePendingAutoDownloadFeedUIDs:"):
    require(token in recover, f"Recovery does not clean stale missing/unsubscribed/parked work: missing {token}.")
stale_ack = recover.find("_removePendingAutoDownloadFeedUIDs:")
stale_next = recover.find("recoverPendingAutoDownloadsAfterDatabaseStartup", stale_ack)
require(stale_ack != -1 and stale_next > stale_ack and "dispatch_async(dispatch_get_main_queue()" in recover[stale_ack:stale_next],
        "More than one stale UID batch must continue on a yielded main turn until the durable queue is empty.")

startup = body(APP_DELEGATE, "- (void) _startUpApplicationWithLaunchOptions:")
state_ready = startup.find("ICDatabaseStartupStateReady")
recovery_start = startup.find("_recoverPendingAutoDownloadsIfReady")
require(state_ready != -1 and recovery_start > state_ready,
        "App startup must begin recovery only after the production database is ready.")
require("CacheManagerDidBecomeReadyForAutomaticDownloadsNotification" in APP_DELEGATE and
        "recoverPendingAutoDownloadsAfterDatabaseStartup" in APP_DELEGATE,
        "AppDelegate must bridge the real cache/history-ready event to SubscriptionManager.")

valid_settings = body(ICLOUD, "nonisolated static func isValidSettingsValueForSyncEngineCallback")
require("case is String, is NSNumber, is Date:" in valid_settings and
        "case let array" not in valid_settings and "is NSArray" not in valid_settings,
        "The operational UID array must remain excluded from iCloud settings payloads and hashes.")
require(pending_key not in BACKUP_EXPORT and pending_key not in BACKUP_IMPORT,
        "The operational recovery queue must not enter the explicit settings backup/restore schema.")

print("Feed auto-download handoff durability regression checks passed")
