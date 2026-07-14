#!/usr/bin/env python3
"""Pins the truncated-download protection on the watch.

Background (measured 05.07.2026, watchOS 26.5 simulator): a download whose
connection closes cleanly WITHOUT a Content-Length header looks successful to
URLSession even when only a prefix of the file arrived. A 120 KB prefix of a
90-minute mp3 passes the HTTP checks and AVFoundation's isPlayable, then plays
for exactly 7.5 seconds, finishes "successfully" and used to mark the whole
episode as consumed on watch, phone and iCloud — the customer's "episodes stop
after 6-8 seconds" report.

Three layers must stay in place:
1. Download validation falls back to the feed's declared enclosure size when
   the transport declared none.
2. Download validation rejects files whose measured duration collapses far
   below the feed's duration hint.
3. The player treats a "successful" finish far below the duration hint as a
   truncated file: no consumed-marking, file dropped and re-queued. This also
   heals truncated files that are already on customer watches (their manifest
   expectedBytes were overwritten at download time, the duration hint was not).
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


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
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


download = read("InstacastWatch/WatchDownloadManager.swift")
player = read("InstacastWatch/WatchPlayerController.swift")
manifest_store = read("InstacastWatch/WatchManifestStore.swift")

validation = function_body(download, "private nonisolated static func downloadValidationError(")

# Layer 1: feed-size fallback when the transport declared no expected size.
require(
    "feedExpectedBytes: Int64" in download,
    "downloadValidationError must take the feed-declared enclosure size as fallback "
    "for responses without Content-Length.",
)
require(
    "expectedSize <= 0" in validation
    and "feedExpectedBytes > 0" in validation
    and "actualSize < feedExpectedBytes / 2" in validation,
    "Validation must reject files below half the feed-declared size when the "
    "transport declared no size (clean close without Content-Length = truncated body).",
)
require(
    "feedExpectedBytes: episode.expectedBytes" in download
    and "await Self.prepareFinishedDownloadFile(" in download,
    "The didFinishDownloadingTo path must pass the episode's expectedBytes into validation.",
)

# Layer 2: duration plausibility at download completion.
require(
    "episode.durationHint >= 600" in download
    and "attributes.duration < episode.durationHint / 2" in download,
    "Download completion must reject playable-but-truncated files whose measured "
    "duration is under half of a substantial feed duration hint.",
)

# Layer 1 stays armed: the didWriteData progress handler must NOT overwrite the
# feed-declared expectedBytes with max(0, -1) == 0 when the transport reports no
# Content-Length (totalBytesExpectedToWrite == -1). That wipe happened on the FIRST
# progress callback and disabled the feed-size fallback in exactly its target case.
progress = function_body(
    download,
    "nonisolated func urlSession(_ session: URLSession,\n"
    "                                downloadTask: URLSessionDownloadTask,\n"
    "                                didWriteData bytesWritten: Int64,",
)
require(
    "if totalBytesExpectedToWrite > 0 {" in progress
    and "item.expectedBytes = totalBytesExpectedToWrite" in progress,
    "didWriteData may only overwrite expectedBytes with a real transport size; "
    "an unknown size (-1) must keep the feed-declared enclosure size.",
)
require(
    "item.expectedBytes = max(0, totalBytesExpectedToWrite)" not in progress,
    "didWriteData must not clamp an unknown transport size to 0 into expectedBytes.",
)

# The truncated-finish requeue must keep the feed-declared size for the re-download.
require(
    "item.expectedBytes = 0" not in function_body(player, "nonisolated func audioPlayerDidFinishPlaying("),
    "The truncated-finish requeue must not zero expectedBytes — the re-download's "
    "validation falls back to it.",
)

# expectedBytes originates in the remote enclosure metadata (or a positive HTTP
# Content-Length). Reconciliation and local-file cleanup may reset local progress,
# but must never erase that independent validation input.
for source, label in [
    (download, "WatchDownloadManager"),
    (player, "WatchPlayerController"),
    (manifest_store, "WatchManifestStore"),
]:
    require(
        "expectedBytes = 0" not in source,
        f"{label} must preserve feed/transport expectedBytes while resetting local file state.",
    )

# Layer 3: player finish guard (heals existing truncated files on customer watches).
finish = function_body(player, "nonisolated func audioPlayerDidFinishPlaying(")
require(
    "durationHint ?? 0) >= 600" in finish
    and "/ 2" in finish
    and "truncatedFile" in finish,
    "audioPlayerDidFinishPlaying must detect a successful finish far below the "
    "duration hint as a truncated file.",
)
require(
    "playback-finished-truncated" in finish,
    "The truncated-finish path must log a diagnostics event so field logs show it.",
)
require(
    "reportPosition(finished: true)" in finish
    and "} else if flag {" in finish,
    "Only a genuine finish may report finished:true (which marks the episode "
    "consumed on watch, phone and iCloud).",
)
require(
    "await WatchDownloadManager.shared.removePlaybackFile(" in finish
    and "disposition: .queued" in finish
    and "removeLocalFile(for:" not in finish
    and "removalCommitted" in finish
    and "startQueuedDownloads()" in finish,
    "A truncated file must be asynchronously deleted, durably re-queued only after "
    "successful removal, and never marked as played.",
)

print("watch truncated-download regression test passed")
