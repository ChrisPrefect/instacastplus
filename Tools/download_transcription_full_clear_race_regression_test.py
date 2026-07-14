#!/usr/bin/env python3
"""Pins transcription queue behavior across full-cache-clear preparation and commit."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("cacheClearInProgress" in SOURCE,
        "The transcription queue must model the full-clear interval explicitly.")

enqueue_start = SOURCE.index("@objc func enqueue(")
enqueue_end = SOURCE.index("/// Remove an episode", enqueue_start)
require("cacheClearInProgress" in SOURCE[enqueue_start:enqueue_end],
        "A new transcription job must not enter after full-clear Will and before its terminal outcome.")

process_start = SOURCE.index("private func processNext()")
process_end = SOURCE.index("// Iteratively skip failed items", process_start)
require("cacheClearInProgress" in SOURCE[process_start:process_end],
        "No queued job may begin while full-cache deletion is preparing or running.")

will_start = SOURCE.index("@objc private func cacheFilesWillBeDeleted")
deleted_start = SOURCE.index("@objc private func cacheFilesWereDeleted", will_start)
restore_start = SOURCE.index("@objc private func cacheDeletionWasRestored", deleted_start)
require('notification.userInfo?["all"]' in SOURCE[will_start:deleted_start] and
        "cacheClearInProgress = true" in SOURCE[will_start:deleted_start],
        "Full-clear Will must close the enqueue/process gate synchronously.")
require("items.removeAll()" in SOURCE[deleted_start:restore_start] and
        "cacheClearInProgress = false" in SOURCE[deleted_start:restore_start],
        "A successful full clear must remove every job, including any lifecycle-race residue.")
require("cacheClearInProgress = false" in SOURCE[restore_start:],
        "An aborted full clear must reopen processing after Restore(all).")

print("Transcription full-clear race regression checks passed")
