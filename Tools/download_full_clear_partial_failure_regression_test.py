#!/usr/bin/env python3
"""Pins truthful cache/model reconciliation after a partial full-clear failure."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method/function: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = SOURCE.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method/function: {signature}")


clear_transcripts = body("static NSError* ICClearAllTranscriptCache(")
delete_files = body("- (NSError*) _deleteAllCacheFilesNow")
finish_clear = body("- (NSError*) _finishDestructiveCacheClear")

require("_cacheClearRemainingURLsByHash" in SOURCE and
        "_cacheClearRemainingBytes" in SOURCE and
        "_cacheClearSnapshotValid" in SOURCE,
        "Full clear must carry a value snapshot of files that actually remain.")
require("remainingURLsByHash" in delete_files and
        "contentsOfDirectoryAtPath" in delete_files and
        "_cacheClearSnapshotValid" in delete_files,
        "The I/O phase must rescan remaining files after any partial removal.")
require("return error" in clear_transcripts,
        "Transcript-directory deletion errors must participate in the public full-clear result.")

require("episodesWithObjectHashes" in finish_clear and
        "_cacheClearRemainingURLsByHash" in finish_clear and
        "_cacheClearRemainingBytes" in finish_clear,
        "The main-context state must be rebuilt from remaining files, not blindly emptied.")
require("remainingURLs.count == 0" in finish_clear and '@"all"' in finish_clear and
        '@"episodeHashes"' in finish_clear,
        "Observers must receive all=YES only for a truly empty cache and exact hashes after partial success.")
require("[self _setDownloadedBytes:0 known:YES]" not in finish_clear,
        "A partial clear must never report zero bytes while files remain.")

print("Download full-clear partial-failure regression checks passed")
