#!/usr/bin/env python3
"""Unchanged server polls must retain the actual pending iOS request."""
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / "Classes/TranscriptionQueue.swift").read_text()
start = source.index("private func scheduleAutomaticBackgroundProcessing(")
end = source.index("private nonisolated static func isTransientPipelineError", start)
body = source[start:end]
for token in ["getPendingTaskRequests", "automaticSchedulingInFlight", "automaticSchedulingNeedsUpdate",
              "pendingDate <= requestedDate", "automaticSchedulingRevision"]:
    assert token in body, f"Scheduler does not yet enforce: {token}"
assert body.index("getPendingTaskRequests") < body.index("BGTaskScheduler.shared.submit(request)")
print("Transcription scheduler deduplication checks passed")
