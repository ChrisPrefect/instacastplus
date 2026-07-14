#!/usr/bin/env python3
"""Pins unreadable auto-download history to fail closed without overwriting it."""

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


require("getter=isLoaded" in HEADER and "reloadIfNeededWithCompletion" in HEADER,
        "Cache history must expose whether the durable file was read and support retry after protected data unlock.")

read_history = body(HISTORY, "- (NSError*)_migrateLegacyPlistIfNeeded")
require("dataWithContentsOfFile:self.legacyFilePath options:0 error:&readError" in read_history and
        "fileExistsAtPath:self.legacyFilePath" in read_history and
        "error:&parseError" in read_history,
        "Missing, unreadable, and malformed history files must be distinguished with real read/parse errors.")

set_history = body(HISTORY, "- (void)setEpisode:(CDEpisode*)episode\n didAutoDownload:(BOOL)autoDownload\n      completion:")
require("!self.loaded" in set_history and "self.loadError" in set_history,
        "An unreadable existing history store must reject mutations instead of overwriting unknown state.")

did_auto_download = body(HISTORY, "- (BOOL)episodeDidAutoDownload:")
require("!self.loaded" in did_auto_download and "return YES" in did_auto_download,
        "Unknown history must fail closed so thousands of episodes are not automatically downloaded again.")

retry = body(MANAGER, "- (void)_retryCacheIndexIfNeeded:")
restore_when_ready = body(MANAGER, "- (void)_restoreCachingEpisodesWhenHistoryReady")
require("_restoreCachingEpisodesWhenHistoryReady" in retry and
        "reloadIfNeededWithCompletion" in restore_when_ready,
        "Protected-data availability must retry the history read even when the cache file index is already ready.")
require("_cachingEpisodesRestored" in restore_when_ready and
        "restoreCachingEpisodes" in restore_when_ready,
        "Persisted downloads must not start until the fail-closed history snapshot is available.")

clear = body(HISTORY, "- (void)clearWithCompletion:")
require("_replaceStoreWithEmptyDatabase" in clear and "self.loaded = YES" in clear,
        "An explicit full clear must recover even from a malformed legacy or SQLite history store.")

print("Download cache-history read-failure regression checks passed")
