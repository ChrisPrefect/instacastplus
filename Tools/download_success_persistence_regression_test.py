#!/usr/bin/env python3
"""Pins durable metadata/history before publishing a successful background download."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
HISTORY_H = (ROOT / "Classes" / "ICCacheHistory.h").read_text()
HISTORY_M = (ROOT / "Classes" / "ICCacheHistory.m").read_text()


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


require("completion:(void (^)(NSError* error))completion;" in HISTORY_H,
        "Auto-download history needs an explicit asynchronous durable error contract.")
history_save = body(HISTORY_M, "- (void)setEpisode:(CDEpisode*)episode\n didAutoDownload:(BOOL)autoDownload\n      completion:")
require("dispatch_async(self.persistenceQueue" in history_save and
        "_setEpisodeHash" in history_save and
        "completion(error)" in history_save,
        "History persistence must return the real incremental SQLite result off-main.")

finish = body(MANAGER, "- (void) cacheOperationDidEnd:")
require("_persistSuccessfulDownloadForOperation" in finish and
        "_finishCacheOperationDidEnd" in finish,
        "A successful operation must await the metadata/history transaction before terminal publication.")

success = body(MANAGER, "- (void)_persistSuccessfulDownloadForOperation:")
database_persist = success.find("[DMANAGER saveReturningError]")
history_persist = success.find("setEpisode:operation.userInfo")
require(database_persist != -1 and history_persist != -1 and database_persist < history_persist,
        "Core Data must be durable before the async history insert starts.")
require("episode.lastDownloaded =" in success and success.find("episode.lastDownloaded =") < database_persist,
        "lastDownloaded must be part of the unconditional terminal Core Data save.")
require("[DMANAGER save];" not in success,
        "Credential changes must not be the accidental condition that decides whether success metadata is saved.")
require("historyError" in success and "restorePreviousValues" in success and
        success.rfind("[DMANAGER saveReturningError]") > history_persist,
        "A history failure must durably roll Core Data back before reporting terminal failure.")

terminal = body(MANAGER, "- (void)_finishCacheOperationDidEnd:")
claim_file = terminal.find("[operation claimFinalizedDownload]")
publish_index = terminal.find("_cachedURLIndex[episode.objectHash]")
notification = terminal.find("CacheManagerDidFinishCachingEpisodeNotification")
background = terminal.rfind("_completeBackgroundSessionForIdentifier:operation.identifier")
require(claim_file != -1 and publish_index != -1 and claim_file < publish_index < notification,
        "The final file/index may become visible only inside the durable terminal continuation.")
require(background > notification,
        "Success notification and iOS background completion must remain behind the durable success transaction.")

print("Download success-persistence regression checks passed")
