#!/usr/bin/env python3
"""Exercise persisted Watch removal errors and legacy retry-flag defaults."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


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
