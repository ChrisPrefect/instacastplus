#!/usr/bin/env python3
"""Pins empty unsubscribe cleanup to retain its terminal block until invocation."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = CACHE_MANAGER.index("__block void (^processNextChunk)(void) = nil;")
end = CACHE_MANAGER.index("            processNextChunk();", start)
chunk_loop = CACHE_MANAGER[start:end]

finish_call = chunk_loop.index("finishTranscriptCleanup();")
self_release = chunk_loop.index("processNextChunk = nil;")

require(
    finish_call < self_release,
    "Empty unsubscribe cleanup must invoke its captured terminal block before releasing "
    "the currently executing recursive block; releasing first deallocates the capture "
    "under ARC and crashes at the terminal block call.",
)

print("CacheManager empty-unsubscribe block lifetime regression checks passed")
