#!/usr/bin/env python3
"""Pins Watch storage-directory accounting off MainActor.

``sendStorageStatus`` is called periodically while downloads run.  Walking every
downloaded file and loading its resource values from the MainActor makes the Watch UI
stall as the library grows.  The physical byte count must remain exact, but the scan
must run at utility priority with concurrent status requests coalesced.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
STORAGE = (ROOT / "InstacastWatch" / "WatchStorageManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


send_status = function_body(CONNECTIVITY, "func sendStorageStatus()")
require(
    "await WatchStorageManager.measureStatus" in send_status
    and "WatchStorageManager.shared.downloadsDirectory" not in send_status,
    "Periodic storage status must await one off-main disk/capacity snapshot without opening or "
    "walking the downloads directory synchronously on MainActor.",
)
require(
    "storageStatusScanInFlight" in send_status
    and "storageStatusResendRequested" in send_status,
    "Repeated storage-status requests must coalesce while a scan is active so large directories "
    "cannot accumulate overlapping enumerations.",
)

require(
    "struct WatchStorageStatusMeasurements: Sendable" in STORAGE,
    "The detached storage snapshot must return one immutable Sendable value.",
)
measure = function_body(STORAGE, "nonisolated static func measureStatus")
require(
    "Task.detached(priority: .utility)" in measure
    and "downloadBytes(in: downloadsDirectory)" in measure
    and "int64VolumeResourceValue" in measure
    and "volumeAvailableCapacityKey" in measure
    and "volumeTotalCapacityKey" in measure,
    "The exact directory total and every potentially blocking volume-capacity read must execute "
    "inside the same utility-priority detached task.",
)

finish = function_body(CONNECTIVITY, "private func finishStorageStatus")
require(
    '"instacastWatchDownloadBytes": measurements.downloadBytes' in finish
    and "sendStorageStatus()" in finish,
    "The measured physical byte count must still be reported, and a request received during the "
    "scan must trigger one fresh follow-up snapshot.",
)
for forbidden in (
    "WatchStorageManager.shared.freeBytes()",
    "WatchStorageManager.shared.rawAvailableBytes()",
    "WatchStorageManager.shared.usedBytes()",
    "WatchStorageManager.shared.totalBytes()",
    "FileManager",
):
    require(
        forbidden not in finish,
        f"Storage-status completion still performs synchronous MainActor I/O: {forbidden}",
    )


print("Watch storage-status MainActor scan regression checks passed")
