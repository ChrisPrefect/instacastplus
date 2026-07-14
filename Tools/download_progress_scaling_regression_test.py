#!/usr/bin/env python3
"""Pins bounded main-thread work for high-throughput download progress."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OPERATION = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()
HEADER = (ROOT / "Classes" / "CacheOperation_iOS7.h").read_text()
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()


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


require("drainLoadedBytesSinceLastUpdate" in HEADER,
        "CacheManager needs a pull API for bytes accumulated between UI ticks.")
require("unreportedLoadedBytes" in OPERATION and "progressLock" in OPERATION,
        "Chunk callbacks need a lock-protected accumulator instead of one main dispatch each.")

write_progress = method_body(OPERATION, "didWriteData:(int64_t)bytesWritten")
require("unreportedLoadedBytes += bytesWritten" in write_progress,
        "Every transport chunk must contribute exactly once to the accumulator.")
require("dispatch_get_main_queue" not in write_progress and "_notifyDidLoadBytesOnMainThread" not in write_progress,
        "A network chunk must never enqueue main-thread work directly.")

drain = method_body(OPERATION, "- (int64_t)drainLoadedBytesSinceLastUpdate")
require("progressLock" in drain and "unreportedLoadedBytes = 0" in drain,
        "The UI-tick drain must atomically take and reset accumulated bytes.")

update = method_body(MANAGER, "- (void) _postDidUpdateNotification")
require("_scheduledDownloadOperationIdentifiers" in update and
        "drainLoadedBytesSinceLastUpdate" in update,
        "The existing 0.5-second UI tick must drain only the at-most-three scheduled operations.")
require("_downloadOperationsByIdentifier.allValues" not in update,
        "One UI tick must not scan thousands of pending queue entries.")
require("_notifyDidLoadBytesOnMainThread" not in OPERATION,
        "The obsolete per-chunk main-dispatch path must be removed completely.")

print("Download progress scaling regression checks passed")
