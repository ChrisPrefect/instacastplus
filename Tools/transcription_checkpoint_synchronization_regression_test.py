#!/usr/bin/env python3
"""Regression guard for thread-safe live transcription checkpoints."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text(encoding="utf-8")
QUEUE_SOURCE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


require(
    "private final class ICTranscriptCheckpointAccumulator: @unchecked Sendable" in SOURCE,
    "Live checkpoint cues still have no explicit cross-executor synchronization owner.",
)
require(
    "private let lock = NSLock()" in SOURCE
    and "func appendAndCheckpointSnapshot" in SOURCE,
    "The checkpoint accumulator does not atomically append and create a value snapshot.",
)
require(
    "nonisolated(unsafe) var accumulatedCues" not in SOURCE
    and "nonisolated(unsafe) var lastCheckpointProg" not in SOURCE,
    "Checkpoint state is still exposed as unsafely shared local mutable state.",
)
require(
    "cues: checkpointCues" in SOURCE,
    "Checkpoint persistence does not consume the immutable synchronized cue snapshot.",
)
require(
    "func snapshot() -> [ICTranscriptCue]" in SOURCE
    and "func persistCurrentCheckpointForInterruption() -> Bool" in SOURCE
    and "currentCheckpointAccumulator?.snapshot()" in SOURCE,
    "A short lifecycle interruption still cannot flush the latest recognized segment before cancellation.",
)
require(
    "private func writeCheckpoint(_ checkpoint: TranscriptionCheckpoint, episodeHash: String, message: String) -> Bool" in SOURCE
    and "return true" in SOURCE.split("private func writeCheckpoint", 1)[1].split("private func saveCheckpoint", 1)[0]
    and "return false" in SOURCE.split("private func writeCheckpoint", 1)[1].split("private func saveCheckpoint", 1)[0]
    and "return saveCheckpointWithCues(" in SOURCE.split("func persistCurrentCheckpointForInterruption() -> Bool", 1)[1].split("@objc func cancelTranscription", 1)[0],
    "Checkpoint write failures are still swallowed instead of reaching the lifecycle handoff.",
)
require(
    QUEUE_SOURCE.count("guard persistCheckpointBeforeInterruption(for: item, reason: reason) else") >= 2
    and "Fortschritt konnte nicht gespeichert werden. Die Verarbeitung wird nicht abgebrochen." in QUEUE_SOURCE,
    "The queue can still cancel transcription after the final interruption checkpoint failed.",
)

print("Transcription checkpoint synchronization regression checks passed.")
