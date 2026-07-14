#!/usr/bin/env python3
"""Pins scalable, durable manual-download failure persistence."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
DOWNLOADS = (ROOT / "Classes" / "DownloadsViewController.m").read_text()


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


require("_failedDownloadPersistenceQueue" in MANAGER and "DISPATCH_QUEUE_SERIAL" in MANAGER,
        "Failure files need one ordered off-main persistence queue.")
require("FailedEpisodeDownloads" in MANAGER and "failed-download" in MANAGER,
        "Each manual failure needs its own independently addressable state file.")
require("NSDataWritingAtomic" in MANAGER and "AddSkipBackupAttributeToFile" in MANAGER,
        "Failure state must be atomically replaced and excluded from backups.")
require("_failedDownloadEpisodeHashes" in MANAGER,
        "Visible failure membership must be O(1), not a growing array scan per failure.")

record = method_body(MANAGER, "- (void)_recordDownloadError:")
require("_persistFailedDownloadMetadata" in record and "_persistFailedDownloads" not in record,
        "Recording one failure must upsert only that identifier's file.")
require("_failedDownloadEpisodeHashes" in record and "indexOfObjectPassingTest" not in record,
        "Recording F failures must not perform 1+...+F visibility scans.")

clear_one = method_body(
    MANAGER,
    "- (void) clearDownloadErrorForEpisode:(CDEpisode*)episode\n"
    "                            completion:",
)
require("_deletePersistedFailedDownloadForIdentifier" in clear_one and "_persistFailedDownloads" not in clear_one,
        "Clearing one failure must delete only its keyed file.")
require("_failedDownloadEpisodeHashes" in clear_one and "indexOfObjectPassingTest" not in clear_one,
        "Clearing one failure must use direct membership.")
require(clear_one.find("_deletePersistedFailedDownloadForIdentifier") < clear_one.find("_failedDownloadMetadataByEpisodeHash removeObjectForKey") and
        "mutationGeneration" in clear_one,
        "Clearing one failure must durably delete first and reject a stale completion after a newer failure generation.")

restore = method_body(MANAGER, "- (void)_restoreFailedDownloads")
require("dispatch_async(_failedDownloadPersistenceQueue" in restore,
        "Failure-file enumeration and plist parsing must stay off main.")
require("episodesWithObjectHashes" in restore and "episodeWithObjectHash:" not in restore,
        "Restore must resolve all failed episodes in one Core Data fetch.")
require("failedDownloadRestoreGeneration" in restore,
        "A delayed startup restore must not re-add failures after the user already cleared all.")

require("clearAllDownloadErrors" in HEADER,
        "Bulk clear needs one explicit API instead of N single-row persistence calls.")
clear_all = method_body(MANAGER, "- (void) clearAllDownloadErrorsWithCompletion:")
require("_deletePersistedFailedDownloadsForIdentifiers" in clear_all and
        "successfulIdentifiers" in clear_all,
        "Bulk clear must use one ordered persistence job and retain records whose deletion failed.")
cancel_all = method_body(DOWNLOADS, "- (void) cancelAllDownloads:")
require("clearAllDownloadErrorsWithCompletion" in cancel_all and "failedDownloadEpisodes copy" not in cancel_all,
        "Downloads UI clear-all must use the bulk store operation.")

finish = method_body(MANAGER, "- (void)_finishCacheOperationDidEnd:")
require("failurePersistenceCompletion" in finish and
        "persistenceError" in finish and
        "_completeBackgroundSessionForIdentifier" in finish,
        "A background failure must release iOS only after its keyed failure record is durable.")

require("- (void)_persistFailedDownloads" not in MANAGER,
        "The obsolete whole-dictionary rewrite path must be removed.")

print("Download failure-store scaling regression checks passed")
