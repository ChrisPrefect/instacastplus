#!/usr/bin/env python3
"""Pins one logical episode deletion to every physical file carrying its hash."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = SOURCE.find("@implementation CacheManager")
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if SOURCE.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


delete_files = body("- (void)_performCacheFileDeletionForItems:")
require(delete_files.count("contentsOfDirectoryAtPath") == 1,
        "A deletion batch must discover physical files in one directory scan.")
require("physicalURLsByHash" in delete_files and "addObject:fileURL" in delete_files,
        "The scan must retain every old/new filename for one episode hash, not overwrite a single URL.")
require("for (NSURL* physicalURL in physicalURLs)" in delete_files and
        "removedBytes +=" in delete_files,
        "Deletion and exact byte accounting must cover every physical duplicate.")
require("remainingURL" in delete_files and "needsRecalculation = YES" in delete_files,
        "A partial duplicate-file failure must restore a remaining URL and invalidate byte accounting.")

finish = body("- (void)_finishCacheFileDeletionForItems:")
require("needsRecalculation = needsRecalculation || [result[ICCacheDeletionNeedsRecalculationKey] boolValue]" in finish,
        "Partial physical deletion must trigger reconciliation even when logical deletion rolls back.")

startup = body("- (void)_buildCacheIndexInBackground")
require("indexedBytes +=" in startup,
        "Startup accounting must continue counting all physical bytes until deletion removes all duplicates.")

print("Download duplicate-physical-file regression checks passed")
