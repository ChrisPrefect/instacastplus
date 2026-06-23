#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


storage = read("InstacastWatch/WatchStorageManager.swift")
store = read("InstacastWatch/WatchManifestStore.swift")
episode = read("InstacastWatch/WatchEpisode.swift")
download = read("InstacastWatch/WatchDownloadManager.swift")
player = read("InstacastWatch/WatchPlayerController.swift")
connectivity = read("InstacastWatch/WatchConnectivityController.swift")
manager = read("Classes/AppleWatchSyncManager.m")


require(
    "func resolvedLocalFileURL(for episode: WatchEpisode) -> URL?" in storage
    and "localFileURL?.lastPathComponent" in storage
    and "downloadsDirectory.appendingPathComponent(fileName)" in storage
    and "FileManager.default.fileExists(atPath: currentURL.path)" in storage,
    "WatchStorageManager must re-root persisted localFileURL filenames into the current watch container before checking file existence.",
)

require(
    "normalizeStoredLocalFileURLs(reason:" in store
    and "normalizeStoredLocalFileURLs(reason: \"load\")" in store
    and "normalizeStoredLocalFileURLs(reason: \"manifest.replace-before\")" in store
    and "normalizeStoredLocalFileURLs(reason: \"manifest.upsert-before\")" in store,
    "WatchManifestStore must normalize stale persisted local file URLs on load and before manifest merge/upsert.",
)

require(
    "FileManager.default.fileExists(atPath: localFileURL.path)" not in episode,
    "WatchEpisode merge must not check the stale persisted absolute localFileURL path directly.",
)

require(
    "WatchStorageManager.shared.resolvedLocalFileURL(for: episode)" in download
    and "pathRerooted" in download
    and "localFileMissing" in download,
    "WatchDownloadManager reconcile must use resolved local file URLs and log reroot/missing-file decisions.",
)

require(
    "WatchStorageManager.shared.resolvedLocalFileURL(for: episode)" in player
    and "playback-start" in player
    and "audioPlayerDidFinishPlaying" in player
    and "audioPlayerDecodeErrorDidOccur" in player,
    "WatchPlayerController must resolve stale local file URLs and log playback start, finish, and decode errors.",
)

require(
    "enum WatchDiagnostics" in connectivity
    and 'send(type: "watch.diagnostic"' in connectivity
    and "stableHash" in connectivity
    and "NSLog(\"[InstacastWatch]" in connectivity,
    "Watch diagnostics must be logged locally and forwarded to the iPhone as watch.diagnostic.",
)

require(
    '#import "InstacastPlus-Swift.h"' in manager
    and 'isEqualToString:@"watch.diagnostic"' in manager
    and 'logEvent:@"apple-watch"' in manager,
    "iPhone AppleWatchSyncManager must persist watch.diagnostic payloads into the crash-log mail diagnostics export.",
)
