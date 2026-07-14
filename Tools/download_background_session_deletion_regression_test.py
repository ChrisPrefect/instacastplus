#!/usr/bin/env python3
"""Pins iOS background-session completion behind terminal cache deletion."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = MANAGER.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = MANAGER.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if MANAGER.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


operation_end = body("- (void) cacheOperationDidEnd:")
pending_branch = operation_end.split("if (pendingRemoval)", 1)[1].split("return;", 1)[0]
require("_finishCancelledDownloadRemovalForIdentifier" in pending_branch and
        "_completeBackgroundSessionForIdentifier" not in pending_branch,
        "A cancelled terminal download must hand off to physical deletion instead of ending the background wake immediately.")

finish_cancelled = body("- (void)_finishCancelledDownloadRemovalForIdentifier:")
background = finish_cancelled.find("_completeBackgroundSessionForIdentifier:identifier")
for prerequisite in (
    "removeItemAtURL:localURL",
    "ICRemoveTranscriptCacheForEpisodeHashes",
    "saveReturningError",
    "CacheManagerDidDeleteCacheFilesNotification",
    "_completeCacheDeletionForIdentifier:identifier",
):
    prerequisite_index = finish_cancelled.find(prerequisite)
    require(prerequisite_index != -1 and background > prerequisite_index,
            f"The OS background completion must run after terminal deletion step: {prerequisite}")

print("Download background-session deletion regression checks passed")
