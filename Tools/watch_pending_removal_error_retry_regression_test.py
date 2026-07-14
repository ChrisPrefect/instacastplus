#!/usr/bin/env python3
"""Pins durable user-visible failure and explicit retry for Watch removals."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
EPISODE = (ROOT / "InstacastWatch" / "WatchEpisode.swift").read_text()
DE = (ROOT / "InstacastWatch" / "de.lproj" / "Localizable.strings").read_text()
EN = (ROOT / "InstacastWatch" / "en.lproj" / "Localizable.strings").read_text()


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


require(
    "var pendingRemovalRetryRequired: Bool" in EPISODE
    and "case pendingRemovalRetryRequired" in EPISODE
    and "forKey: .pendingRemovalRetryRequired" in EPISODE
    and ") ?? false" in EPISODE,
    "Pending-removal retry ownership needs a durable flag with a migration-safe false default.",
)
pending_error = function_body(EPISODE, "var hasPendingRemovalError: Bool")
require(
    "status == .removing" in pending_error
    and "pendingRemovalRetryRequired" in pending_error,
    "The model must expose a distinct user-visible error state only for exhausted removals, "
    "not for unrelated errors carried into `.removing`.",
)

process = function_body(DOWNLOAD, "private func processPendingRemovalBatch() async")
failure_increment = process.find("removalFailureCountByHash[hash, default: 0] += 1")
persist_failure = process.find("await persistPendingRemovalFailures(")
require(
    failure_increment != -1
    and persist_failure > failure_increment
    and ">= 2" in process[failure_increment:persist_failure],
    "The second physical deletion failure must cross an explicit terminal threshold and persist "
    "the removal error before cleanup ownership is released.",
)

failure_message = "Die Folge konnte nicht von der Watch entfernt werden. Tippe, um es erneut zu versuchen."
persist = function_body(DOWNLOAD, "private func persistPendingRemovalFailures(")
require(
    "try await WatchManifestStore.shared.updateEpisodes(" in persist
    and "item.status == .removing" in persist
    and "item.lastError = removalError" in persist
    and "item.pendingRemovalRetryRequired = true" in persist
    and "NSLocalizedString(" in persist
    and failure_message in persist,
    "Exhausted removals must durably store one localized error without changing `.removing`.",
)
require(
    failure_message in DE and failure_message in EN,
    "The durable pending-removal error must be localized in German and English.",
)
require(
    '"Entfernen erneut versuchen"' in DE and '"Entfernen erneut versuchen"' in EN,
    "The explicit removal-retry action must be localized in German and English.",
)

retry = function_body(DOWNLOAD, "func retryPendingRemoval(hash: String)")
clear_error = retry.find("item.lastError = nil")
clear_retry_flag = retry.find("item.pendingRemovalRetryRequired = false")
reset_budget = retry.find("removalFailureCountByHash[hash] = nil")
reenqueue = retry.find("enqueuePendingRemovalHashes([hash])")
require(
    "episode.hasPendingRemovalError" in retry
    and "WatchStorageEpisodeIdentity(episode: episode)" in retry
    and "try await WatchManifestStore.shared.updateEpisodeDurably" in retry
    and -1 not in (clear_error, clear_retry_flag, reset_budget, reenqueue)
    and clear_error < clear_retry_flag < reset_budget < reenqueue,
    "Explicit retry must durably clear the same removal generation's error, reset its retry "
    "budget, and only then enqueue the already `.removing` episode again.",
)
require(
    "identity.matches(currentEpisode)" in retry
    and "currentEpisode.status == .removing" in retry,
    "A suspended retry must revalidate removal identity and status before restarting file I/O.",
)


HARNESS = r"""
import Foundation

@main
struct PendingRemovalErrorHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        let entry = WatchManifestEntry(
            episodeHash: "episode",
            selectionIdentifier: "selection",
            feedIdentifier: "feed",
            title: "Episode",
            podcastTitle: "Podcast",
            imageURL: nil,
            pubDate: Date(timeIntervalSince1970: 1),
            durationHint: 3_600,
            position: 0,
            consumed: false,
            mediaURL: URL(string: "https://example.com/episode.mp3")!,
            selectionSource: .manual,
            watchAddedDate: Date(timeIntervalSince1970: 2),
            playbackOrder: 0,
            skipForwardSeconds: 30,
            skipBackwardSeconds: 15,
            expectedFileSize: 1_024,
            skipChapterNames: [],
            autoSkipSponsors: false
        )
        var episode = WatchEpisode(
            entry: entry,
            existing: nil,
            existingLocalFileWasValidated: false
        )
        episode.status = .removing
        episode.lastError = "Removal failed"
        require(!episode.hasPendingRemovalError, "unrelated error blocked pending removal")
        episode.pendingRemovalRetryRequired = true
        require(episode.hasPendingRemovalError, "removing error was not exposed")
        require(!episode.hasPlaybackFileRemovalError, "removing error was confused with playback cleanup")

        let data = try JSONEncoder().encode(episode)
        let restored = try JSONDecoder().decode(WatchEpisode.self, from: data)
        require(restored.status == .removing, "pending-removal status was not durable")
        require(restored.lastError == "Removal failed", "pending-removal error was not durable")
        require(restored.pendingRemovalRetryRequired, "pending-removal retry flag was not durable")
        require(restored.hasPendingRemovalError, "restored removal error was not actionable")

        episode.lastError = "   "
        require(!episode.hasPendingRemovalError, "blank errors must not create a retry state")
    }
}
"""

with tempfile.TemporaryDirectory(prefix="watch-pending-removal-") as temp_dir:
    temp = Path(temp_dir)
    harness = temp / "Harness.swift"
    executable = temp / "watch-pending-removal"
    harness.write_text(HARNESS)
    compile_result = subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            str(ROOT / "InstacastWatch" / "WatchEpisode.swift"),
            str(harness),
            "-o",
            str(executable),
        ],
        text=True,
        capture_output=True,
    )
    require(
        compile_result.returncode == 0,
        "Pending-removal model harness did not compile:\n"
        f"{compile_result.stdout}{compile_result.stderr}",
    )
    result = subprocess.run([str(executable)], text=True, capture_output=True)
    require(
        result.returncode == 0,
        "Pending-removal persistence scenario failed:\n"
        f"{result.stdout}{result.stderr}",
    )


print("Watch pending-removal error/retry regression checks passed")
