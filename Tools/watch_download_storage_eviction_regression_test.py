#!/usr/bin/env python3
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


episode = read("InstacastWatch/WatchEpisode.swift")
storage = read("InstacastWatch/WatchStorageManager.swift")
download = read("InstacastWatch/WatchDownloadManager.swift")
views = read("InstacastWatch/WatchEpisodeViews.swift")
de_strings = read("InstacastWatch/de.lproj/Localizable.strings")
en_strings = read("InstacastWatch/en.lproj/Localizable.strings")

cleanup = function_body(storage, "func cleanupIfNeeded(")
start_download = function_body(download, "func startDownload(")
queue_runner = function_body(download, "private func startQueuedDownloadsAfterReattach(")
prioritize = function_body(download, "func prioritizeEpisode(")

require(
    "case evicted" in episode,
    "Watch episodes need a distinct evicted status for downloads removed because of storage pressure.",
)

require(
    "item.status = .evicted" in cleanup
    and "item.status = .queued" not in cleanup,
    "Storage cleanup must not put evicted downloads back into the automatic queued state.",
)

require(
    "projectedFreeBytes" in cleanup
    and "guard projectedFreeBytes >= minimumFreeBytes else" in cleanup
    and "return nil" in cleanup
    and "let reclaimableBytes = localFileSize(for: episode)" in cleanup
    and "max(expectedBytes, localFileSize(for: episode))" not in cleanup
    and "for selectedCandidate in selectedCandidates" in cleanup
    and "for episode in candidates where freeBytes() < minimumFreeBytes" not in cleanup,
    "Storage cleanup must prove projected capacity from actual local file sizes before deleting existing downloads.",
)

require(
    "guard let removed = WatchStorageManager.shared.cleanupIfNeeded" in start_download
    and "download-storage-insufficient" in start_download
    and "item.status = .evicted" in start_download,
    "A new Watch download must not start, or evict existing files, when storage cannot be made sufficient.",
)

require(
    "for episode in WatchManifestStore.shared.sortedEpisodes where episode.status == .queued" in queue_runner
    and ".evicted" not in queue_runner,
    "The automatic Watch queue runner must not restart storage-evicted episodes.",
)

require(
    "episode.status == .failed || episode.status == .evicted" in prioritize
    and "item.status = .queued" in prioritize,
    "Only an explicit user retry should move failed or storage-evicted episodes back to queued.",
)

require(
    "abortDownloadForInsufficientStorage" in download
    and "WatchStorageManager.minimumReserveBytes" in download,
    "A running Watch download must abort when free space falls to the reserve, so a download whose "
    "size the feed never declared cannot starve the watch (storage pressure suspends playback).",
)

require(
    "case .evicted" in views
    and "Speicher voll" in views,
    "The Watch UI must show storage eviction separately from generic download errors.",
)

require(
    '"Speicher voll"' in de_strings
    and '"Speicher voll" = "Storage Full";' in en_strings,
    "Storage eviction status must be localized for German and English.",
)

print("Watch storage eviction regression checks passed.")
