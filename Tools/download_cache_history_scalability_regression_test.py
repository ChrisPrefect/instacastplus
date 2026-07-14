#!/usr/bin/env python3
"""Pins incremental, off-main, terminal auto-download history persistence."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "ICCacheHistory.h").read_text()
HISTORY = (ROOT / "Classes" / "ICCacheHistory.m").read_text()
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if source.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


for selector in (
    "setEpisode:(CDEpisode*)episode\n didAutoDownload:(BOOL)autoDownload\n      completion:",
    "resetValuesForEpisodes:(NSArray<CDEpisode*>*)episodes\n                    completion:",
    "clearWithCompletion:",
    "reloadIfNeededWithCompletion:",
):
    require(selector.replace("\\n", "\n") in HEADER,
            f"Cache history is missing terminal async API: {selector}")

require("#import <sqlite3.h>" in HISTORY and
        "CREATE TABLE IF NOT EXISTS" in HISTORY and "auto_downloaded_episode" in HISTORY,
        "Auto-download history must use an indexed SQLite set, not whole-file rewrites.")
require("DISPATCH_QUEUE_SERIAL" in HISTORY and "QOS_CLASS_UTILITY" in HISTORY,
        "All history database work must be ordered off the UI thread.")
require("INSERT OR IGNORE INTO" in HISTORY and "DELETE FROM" in HISTORY and
        "episode_hash = ?" in HISTORY,
        "Single episode mutations must stay O(1).")
require("BEGIN IMMEDIATE TRANSACTION" in HISTORY and "resetValuesForEpisodes" in HISTORY,
        "Feed-wide history resets must use one bounded transaction instead of N commits.")

set_episode = body(
    HISTORY,
    "- (void)setEpisode:(CDEpisode*)episode\n didAutoDownload:(BOOL)autoDownload\n      completion:",
)
require("dispatch_async(self.persistenceQueue" in set_episode and
        "dispatch_async(dispatch_get_main_queue()" in set_episode,
        "History mutations must perform SQLite work off-main and return terminal state on main.")
require("mutationGenerations" in set_episode and "pendingValues" in set_episode,
        "An older mutation completion must not overwrite a newer value for the same episode.")

load = body(HISTORY, "- (void)reloadIfNeededWithCompletion:")
require("dispatch_async(self.persistenceQueue" in load and "self.loaded = YES" in load,
        "Startup/protected-data loading must be asynchronous and publish one main-thread snapshot.")
require("NSPropertyListSerialization" in HISTORY and "PRAGMA user_version" in HISTORY,
        "The existing plist must migrate exactly once into the incremental store.")

finish = body(MANAGER, "- (void) cacheOperationDidEnd:")
require("_persistSuccessfulDownloadForOperation" in finish,
        "Download completion must enter the terminal async metadata/history transaction.")
persist_success = body(MANAGER, "- (void)_persistSuccessfulDownloadForOperation:")
require("setEpisode:operation.userInfo" in persist_success and "completion:^(NSError* historyError)" in persist_success,
        "An automatic download must await the exact history INSERT result.")
require("[DMANAGER saveReturningError]" in persist_success and
        "historyError" in persist_success and
        persist_success.find("[DMANAGER saveReturningError]") < persist_success.find("setEpisode:operation.userInfo"),
        "Core Data must commit before history, with explicit rollback if the second store fails.")

terminal = body(MANAGER, "- (void)_finishCacheOperationDidEnd:")
require("claimFinalizedDownload" in terminal and "CacheManagerDidFinishCachingEpisodeNotification" in terminal,
        "Final file ownership and success publication belong only to the terminal continuation.")

full_clear = body(MANAGER, "- (void)cancelDownloadsAndClearCacheWithCompletion:")
require("clearWithCompletion" in full_clear and "historyError" in full_clear,
        "Full cache clear must await and propagate history-store deletion failures.")

print("Download cache-history scalability regression checks passed")
