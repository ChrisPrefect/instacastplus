#!/usr/bin/env python3
"""Pins the O(1) iPhone UI path for two-second Watch progress events.

Live ``watch.downloadProgress`` is transport telemetry, not durable episode state.
Persisting its event revision/seen date triggers a Core Data save and observer cascade;
re-fetching/sorting/remapping thousands of selected episodes for every sample then makes
the iPhone UI stutter. Terminal and queue state changes remain ordered and durable.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "AppleWatchSyncManager.h").read_text()
MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
CONTROLLER = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()


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
    "ICAppleWatchLiveStatusDidChangeNotification" in HEADER
    and "ICAppleWatchChangedEpisodeHashesUserInfoKey" in HEADER,
    "Live progress/storage notifications must be separate from durable episode-state changes "
    "and identify affected episode hashes.",
)

incoming = method_body(MANAGER, "- (void)_handleIncomingPayloadOnMainThread:")
progress_route = incoming.split('[@"watch.downloadProgress"]', 1)
if len(progress_route) == 1:
    progress_route = incoming.split('isEqualToString:@"watch.downloadProgress"', 1)
require(len(progress_route) == 2, "Missing watch.downloadProgress route.")
progress_route = progress_route[1].split("else if", 1)[0]
require(
    "_applyTransientDownloadProgressPayload:" in progress_route
    and "_postLiveStatusChangedForEpisodeHashes:" in progress_route
    and "return;" in progress_route,
    "Progress must use the transient live-status path and return before the durable save/state "
    "notification tail.",
)
require(
    "_updateStateForPayload:" not in progress_route
    and "ICAppleWatchStatusDownloading" not in progress_route
    and "[DMANAGER save]" not in progress_route
    and "_postEpisodeStatesChanged" not in progress_route,
    "Two-second progress must not mutate/save durable status or trigger the full episode-state "
    "observer cascade.",
)

transient = method_body(MANAGER, "- (AppleWatchEpisodeState*)_applyTransientDownloadProgressPayload:")
require(
    "advanceDurableState:NO" in transient
    and "watchDownloadProgressByHash" in transient
    and "_updateCachedWatchTransferContribution" in transient,
    "Accepted live progress must keep ordering/progress in memory and update the cached aggregate "
    "incrementally.",
)
require(
    "state.watchStatus" not in transient
    and "state.watchLastEventRevision" not in transient
    and "state.watchLastSeenDate" not in transient,
    "Transient progress must not dirty the Core Data episode state.",
)

ordering = method_body(MANAGER, "- (int64_t)_acceptedWatchEventRevisionForPayload:")
require(
    "advanceDurableState" in ordering
    and "_liveDownloadProgressForState:" in ordering
    and "state.watchLastEventRevision" in ordering,
    "Transient and durable Watch events need one ordering gate so a delayed terminal event cannot "
    "overwrite newer live progress.",
)

aggregate = method_body(MANAGER, "- (ICAppleWatchTransferPhase)watchDownloadProgressLoadedBytes:")
require(
    "_rebuildWatchTransferSnapshotIfNeeded" in aggregate
    and "cachedWatchTransferLoadedBytes" in aggregate,
    "The public header-status read must return the cached transfer snapshot.",
)
require(
    "visibleEpisodeStates" not in aggregate
    and "_episodesByHashForEpisodeHashes:" not in aggregate
    and "executeFetchRequest" not in aggregate,
    "A two-second header refresh must not fetch, sort, or scan the full Watch selection.",
)

current = method_body(MANAGER, "- (void)_updateCurrentWatchDownloadFromPayload:")
require(
    "currentWatchDownloadHash" in current
    and "isEqualToString" in current
    and current.find("isEqualToString") < current.find("episodeWithObjectHash:"),
    "The current download title may be fetched once when the hash changes, not once per progress "
    "sample.",
)

require(
    "ICAppleWatchLiveStatusDidChangeNotification" in CONTROLLER,
    "The Apple Watch page must observe the lightweight live-status notification.",
)
live_handler = method_body(CONTROLLER, "- (void)_liveStatusDidChange:")
require(
    "_updateHeaderText" in live_handler
    and "_reloadDataFromManager" not in live_handler
    and "_reloadVisibleRowsForEpisodeHashes:" in live_handler
    and "reloadData" not in live_handler,
    "Live progress/storage changes must update the header and only reconfigure affected visible "
    "rows, never reload the Watch episode snapshot or whole table.",
)

context_changed = method_body(CONTROLLER, "- (void)_contextObjectsDidChange:")
require(
    "stateIndexByHash" in context_changed
    and "_reloadVisibleRowsForEpisodeHashes:" in context_changed
    and "_episodesByHashForStates:" not in context_changed,
    "A changed selected CDEpisode must update its cached mapping and visible row directly instead "
    "of rebuilding all episode metadata.",
)


print("Watch progress incremental UI regression checks passed")
