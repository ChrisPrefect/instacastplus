#!/usr/bin/env python3
"""Pins fair background-feed scheduling and the configured cellular policy."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
SUBSCRIPTIONS_HEADER = (ROOT / "Classes" / "Model" / "SubscriptionManager.h").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
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
    raise AssertionError(f"Unterminated method: {signature}")


require(
    "canRefreshFeedsOnCurrentNetwork" in SUBSCRIPTIONS_HEADER,
    "Foreground and background refresh entry points need one authoritative network-policy check.",
)
network_policy = method_body(SUBSCRIPTIONS, "- (BOOL)canRefreshFeedsOnCurrentNetwork")
require(
    "kICNetworkAccessTechnlogyWIFI" in network_policy
    and "EnableRefreshingOver3G" in network_policy
    and "kICNetworkAccessTechnlogyGPRS" in network_policy,
    "Feed refresh must allow Wi-Fi and only configured usable cellular networks.",
)

background_fetch = method_body(
    APP,
    "- (void)application:(UIApplication *)application performFetchWithCompletionHandler:",
)
policy_check = background_fetch.find("canRefreshFeedsOnCurrentNetwork")
refresh_call = background_fetch.find("refreshFeeds:")
require(
    -1 < policy_check < refresh_call,
    "Background fetch must reject a disallowed network before scheduling feed requests.",
)
require(
    "MAX_SUBSCRIPTIONS_TO_FETCH 1" not in background_fetch
    and "ICBackgroundFeedRefreshBatchSize" in background_fetch,
    "A background fetch must use the parser's bounded batch capacity instead of permanently refreshing only one feed.",
)
require(
    "ICBackgroundFeedRefreshAttemptsKey" in APP
    and "backgroundRefreshAttempts" in background_fetch
    and "feed.uid" in background_fetch,
    "The scheduler must retain a stable per-feed attempt time so a failing oldest feed cannot starve the rest.",
)
candidate_loop = background_fetch.find("for (CDFeed* feed in subscriptions)")
candidate_add = background_fetch.find("[refreshCandidates addObject:feed]", candidate_loop)
parked_check = background_fetch.find("feed.parked", candidate_loop, candidate_add)
require(
    candidate_loop != -1 and candidate_add != -1 and parked_check != -1,
    "Parked podcasts must be excluded before fair-attempt ordering so they cannot consume a background batch slot.",
)
sort_attempt = background_fetch.find("backgroundRefreshAttempts")
mark_attempt = background_fetch.rfind("setObject:", 0, refresh_call)
require(
    sort_attempt != -1 and mark_attempt != -1 and mark_attempt < refresh_call,
    "Selected feeds must be marked attempted before network work, independent of success or process suspension.",
)

foreground_refresh = method_body(SCENE, "- (void) _autoRefreshFeedsIfNeeded")
foreground_policy = foreground_refresh.find("canRefreshFeedsOnCurrentNetwork")
cooldown_write = foreground_refresh.find("_lastAutoRefreshDate =")
require(
    -1 < foreground_policy < cooldown_write,
    "A prohibited cellular foreground attempt must not consume the 30-minute refresh cooldown.",
)

print("Background feed-refresh fairness regression checks passed")
