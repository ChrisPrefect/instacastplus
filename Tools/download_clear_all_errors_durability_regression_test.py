#!/usr/bin/env python3
"""Pins durable, race-safe bulk clearing of persisted download failures."""

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


require("clearAllDownloadErrorsWithCompletion:" in HEADER,
        "Bulk failure clearing must expose its durable terminal result.")

delete_batch = method_body(
    MANAGER,
    "- (void)_deletePersistedFailedDownloadsForIdentifiers:",
)
require("_failedDownloadPersistenceQueue" in delete_batch and
        "removeItemAtPath" in delete_batch and
        "error:&" in delete_batch,
        "Failure files must be deleted on the ordered persistence queue with observed I/O errors.")
require("successfulIdentifiers" in delete_batch,
        "A partial filesystem failure must identify exactly which failure records became durable deletions.")
require("removeItemAtPath:directoryPath" not in delete_batch,
        "Bulk clear must not remove the shared directory that a newly queued failure will write into.")

clear_all = method_body(
    MANAGER,
    "- (void) clearAllDownloadErrorsWithCompletion:",
)
require("mutationGenerationsByIdentifier" in clear_all and
        "_failedDownloadMutationGenerationsByEpisodeHash" in clear_all,
        "Bulk clear must snapshot per-episode generations so a newer failure survives an old completion.")
require(clear_all.find("_deletePersistedFailedDownloadsForIdentifiers") <
        clear_all.find("_failedDownloadMetadataByEpisodeHash removeObjectForKey"),
        "Visible failures must remain until their persisted records are durably deleted.")
require("successfulIdentifiers" in clear_all and "completion(error)" in clear_all,
        "Bulk clear must preserve failed deletions and return the filesystem error to its caller.")

cancel_all = method_body(DOWNLOADS, "- (void) cancelAllDownloads:")
require("clearAllDownloadErrorsWithCompletion" in cancel_all and "presentError:error" in cancel_all,
        "Downloads UI must wait for bulk deletion and explain a terminal persistence failure.")
require(cancel_all.find("clearAllDownloadErrorsWithCompletion") <
        cancel_all.find("dismissViewControllerAnimated"),
        "Downloads UI must not dismiss before failure deletion completes.")

full_clear = method_body(MANAGER, "- (void)cancelDownloadsAndClearCacheWithCompletion:")
require("clearAllDownloadErrorsWithCompletion" in full_clear and
        "fileError ?: stateError ?: historyError ?: failureStateError" in full_clear,
        "Destructive cache clear must wait for and propagate failed-download-state deletion errors.")

print("Download clear-all failure durability regression checks passed")
