#!/usr/bin/env python3
"""Pins unsubscribe cleanup to release its recursive block only after it returns."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = CACHE_MANAGER.index("__block void (^processNextChunk)(void) = nil;")
end = CACHE_MANAGER.index("            processNextChunk();", start)
chunk_loop = CACHE_MANAGER[start:end]

require(
    """finishTranscriptCleanup();
                    dispatch_async(dispatch_get_main_queue(), ^{
                        processNextChunk = nil;
                    });""" in chunk_loop,
    "Unsubscribe cleanup must release its self-referential recursive block on the next "
    "main-queue turn. Clearing it inside its own invocation deallocates the executing "
    "block under ARC and crashes while returning.",
)

print("CacheManager empty-unsubscribe block lifetime regression checks passed")
