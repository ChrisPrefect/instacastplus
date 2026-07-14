#!/usr/bin/env python3
"""Pins every feed-ingestion path to a durable, post-save auto-download handoff."""

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


finish_parse = method_body("- (void) _finishParsingFeed:")
refresh_finish = method_body("- (void) checkRefreshOperationsTimer:")
hydrate = method_body("- (void) hydrateStubFeed:")
reload_feed = method_body("- (void) reloadContentOfFeed:")

require(
    "pendingAutoDownloadFeedObjectIDs" in finish_parse
    and "_autoDownloadEpisodesInFeedAsynchronously" not in finish_parse,
    "A parsed feed must retain post-save auto-download intent instead of scanning a sibling store context before the batch is durable.",
)
save = refresh_finish.find("saveReturningError")
drain = refresh_finish.find("_startPendingAutoDownloads")
require(
    save != -1 and drain != -1 and save < drain,
    "The refresh batch must save the main context before starting its retained auto-download work.",
)

hydrate_save = hydrate.find("saveReturningError")
hydrate_download = hydrate.find("_autoDownloadEpisodesInFeedAsynchronously")
require(
    hydrate_save != -1 and hydrate_download != -1 and hydrate_save < hydrate_download,
    "A successfully hydrated iCloud stub must start auto-download only after its initial episodes are durable.",
)

reload_save = reload_feed.find("saveReturningError")
reload_download = reload_feed.find("_autoDownloadEpisodesInFeedAsynchronously")
require(
    reload_save != -1 and reload_download != -1 and reload_save < reload_download,
    "Full feed reloads, including the remote-push reload path, must use the same post-save auto-download handoff.",
)

print("Feed auto-download delivery regression checks passed")
