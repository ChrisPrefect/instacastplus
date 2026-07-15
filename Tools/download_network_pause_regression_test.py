#!/usr/bin/env python3
"""Pins durable user pause and transient connectivity suspension semantics."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
OPERATION = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()


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


network = method_body(MANAGER, "- (void) _handleNetworkStatusChanged")
require("cancelCachingEpisode" not in network,
        "Losing an allowed network must not erase durable queue jobs as if the user cancelled them.")
require("operation.suspended =" in network and "[self canDownload]" in network,
        "Connectivity changes must suspend and later resume the existing operations in place.")
require("_manuallySuspendedDownloadIdentifiers" in network and "self.suspended" in network,
        "Network recovery must not override either global or per-episode user pause.")
policy = method_body(MANAGER, "- (BOOL) _networkAllowsDownloadOperation:")
require("operation.overwriteCellularLock" in policy and "kICNetworkAccessTechnlogyNone" in policy,
        "An explicit user cellular override must survive later network-policy reevaluation.")

require("ICDownloadQueueSuspended" in MANAGER,
        "The user's global queue pause must survive process death.")
require("_manuallySuspendedDownloadIdentifiers" in MANAGER,
        "Per-episode user pause must be separate from transient network suspension.")

persist = method_body(MANAGER, "- (void) _persistCachingOperation:")
require('"suspended"' in persist and "_manuallySuspendedDownloadIdentifiers" in persist,
        "Each queued job must persist its explicit per-episode pause bit.")
restore = method_body(MANAGER, "- (void) restoreCachingEpisodes")
require('info[@"suspended"]' in restore and "_manuallySuspendedDownloadIdentifiers" in restore,
        "Restart must restore per-episode pause before an operation can be scheduled.")

pause_all = method_body(MANAGER, "- (void) pauseCaching")
resume_all = method_body(MANAGER, "- (void) resumeCaching")
require("setBool:YES" in pause_all and "ICDownloadQueueSuspended" in pause_all,
        "Global Pause must be durable.")
require("setBool:NO" in resume_all and "ICDownloadQueueSuspended" in resume_all and "_networkAllowsDownloadOperation" in resume_all,
        "Global Resume must remain suspended when current connectivity is still disallowed.")

pause_one = method_body(MANAGER, "- (void) pauseCachingEpisode:")
resume_one = method_body(MANAGER, "- (void) resumeCachingEpisode:")
for body, action in ((pause_one, "Pause"), (resume_one, "Resume")):
    require("_manuallySuspendedDownloadIdentifiers" in body and "_persistCachingOperation" in body,
            f"Per-episode {action} must update both runtime and durable state.")

scheduler = method_body(MANAGER, "- (void) _startNextDownloadOperations")
scheduled_add = scheduler.find("[_downloadQueue addOperation:nextOperation]")
paused_filter = scheduler.find("!operation.suspended")
require(paused_filter != -1 and paused_filter < scheduled_add,
        "Persisted or network-blocked per-episode pauses must not consume the three runnable queue slots.")
require("[self _startNextDownloadOperations]" in resume_one,
        "Resuming a previously unscheduled paused job must run the bounded scheduler again.")

cache_episode = method_body(
    MANAGER,
    "deferDuringSubscriptionCleanup:(BOOL)deferDuringSubscriptionCleanup",
)
require("_networkAllowsDownloadOperation:cacheOperation" in cache_episode and "cacheOperation.suspended" in cache_episode,
        "A newly queued offline job must start suspended without losing its queue intent.")
auto_cache = method_body(MANAGER, "- (BOOL) autoCacheEpisode:")
require("if ([self canDownload])" not in auto_cache and "_cacheEpisode:episode" in auto_cache,
        "Automatic downloads discovered offline must enter the durable suspended queue.")

getter = method_body(OPERATION, "- (BOOL) suspended")
setter = method_body(OPERATION, "- (void) setSuspended:")
require("_shouldBeSuspended" in getter,
        "A not-yet-created URLSession task must still expose its requested suspension state.")
require(setter.find("_shouldBeSuspended = suspended") < setter.find("downloadTask.state"),
        "Resume before task creation must clear the requested pause instead of leaving a future task stuck.")

print("Download network/pause regression checks passed")
