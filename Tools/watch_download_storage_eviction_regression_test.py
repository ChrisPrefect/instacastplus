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

free_bytes = function_body(storage, "func freeBytes(")
total_bytes = function_body(storage, "func totalBytes(")
int64_volume_resource_value = function_body(storage, "private nonisolated static func int64VolumeResourceValue(")
cleanup_plan = function_body(storage, "nonisolated static func makeCleanupPlan(")
cleanup_execution = function_body(storage, "nonisolated static func executeCleanup(")
cleanup_removal = function_body(
    storage,
    "nonisolated static func removeLocalFiles(\n"
    "        for episodes: [WatchEpisode],\n"
    "        downloadsDirectory: URL,",
)
start_download = function_body(download, "func startDownload(")
prepare_download = function_body(download, "private func preparePendingDownloadStart(")
commit_evictions = function_body(download, "private func commitStorageEvictions(")
persist_insufficient = function_body(download, "private func persistInsufficientStorageState(")
queue_runner = function_body(download, "private func startQueuedDownloadsAfterReattach(")
prioritize = function_body(download, "func prioritizeEpisode(")
autofill = function_body(download, "private func autoFillEvictedEpisodes(")

require(
    "case evicted" in episode,
    "Watch episodes need a distinct evicted status for downloads removed because of storage pressure.",
)

require(
    "volumeAvailableCapacityForImportantUsageKey" not in storage
    and "int64VolumeResourceValue(for: .volumeAvailableCapacityKey)" in free_bytes
    and "volumeAvailableCapacity ??" not in free_bytes
    and "max(0," in free_bytes,
    "freeBytes() must read volumeAvailableCapacityKey as the underlying NSNumber Int64. "
    "On watchOS arm64_32 the typed URLResourceValues.volumeAvailableCapacity is Int-sized and "
    "truncated multi-GB values into negatives, making every storage check refuse downloads "
    "('Speicher voll', 0 loaded). volumeAvailableCapacityForImportantUsageKey is unavailable on watchOS.",
)

require(
    "int64VolumeResourceValue(for: .volumeTotalCapacityKey)" in total_bytes
    and "getResourceValue" in int64_volume_resource_value
    and "NSNumber" in int64_volume_resource_value
    and ".int64Value" in int64_volume_resource_value,
    "Watch storage capacity must be read from NSURL resource values as NSNumber.int64Value, not "
    "through Swift URLResourceValues Int properties that truncate on watchOS arm64_32.",
)

require(
    "item.status = .evicted" in commit_evictions
    and "item.status = .queued" not in commit_evictions,
    "Storage cleanup must not put evicted downloads back into the automatic queued state.",
)

require(
    "projectedFreeBytes" in cleanup_plan
    and "hasSufficientCapacity: projectedFreeBytes >= minimumFreeBytes" in cleanup_plan
    and "let reclaimableBytes = cleanupLocalFileSize" in cleanup_plan
    and "max(expectedBytes, cleanupLocalFileSize" not in cleanup_plan
    and "for episode in candidates where projectedFreeBytes < minimumFreeBytes" in cleanup_plan
    and "WatchStorageManager.executeCleanup" in prepare_download
    and "await removeLocalFiles(" in cleanup_execution
    and "Task.detached(priority: .utility)" in cleanup_removal,
    "Storage cleanup must prove projected capacity from actual local file sizes before deleting existing downloads.",
)

require(
    "enqueuePendingDownloadStart" in start_download
    and "WatchStorageManager.makeCleanupPlan" in prepare_download
    and "persistInsufficientStorageState" in prepare_download
    and "download-storage-insufficient" in persist_insufficient
    and "item.status = .evicted" in persist_insufficient,
    "A new Watch download must not start, or evict existing files, when storage cannot be made sufficient.",
)

require(
    "startNextQueuedDownloadIfIdle()" in queue_runner
    and ".evicted" not in queue_runner,
    "The automatic Watch queue runner must start only queued episodes directly; storage-evicted "
    "episodes are restarted exclusively through the controlled auto-fill path.",
)

# Sequential download policy (User-Entscheid 06.07.): downloads run one at a time in playback
# order so the first episode becomes playable as early as possible.
sequential_starter = function_body(download, "private func startNextQueuedDownloadIfIdle(")
require(
    "guard activeTasksByHash.isEmpty" in sequential_starter
    and "$0.status == .queued" in sequential_starter
    and ".evicted" not in sequential_starter,
    "Automatic Watch downloads must run sequentially: start the next queued episode only while "
    "no download is active, never touching evicted episodes directly.",
)

require(
    "guard activeTasksByHash.isEmpty" in autofill
    and "status == .evicted" in autofill
    and "episode.expectedBytes > 0" in autofill
    and "WatchStorageManager.minimumReserveBytes" in autofill
    and "projectedFree -= episode.expectedBytes" in autofill,
    "Auto-fill must re-download evicted episodes only into free space above the reserve (never by "
    "evicting another episode) and only while the queue is idle, so it cannot reintroduce the thrash.",
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
