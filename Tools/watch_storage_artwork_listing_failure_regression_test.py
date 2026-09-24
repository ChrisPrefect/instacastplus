#!/usr/bin/env python3
"""Proves artwork-index failures do not suppress production Watch audio removal."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WATCH_EPISODE = ROOT / "InstacastWatch" / "WatchEpisode.swift"
WATCH_STORAGE = ROOT / "InstacastWatch" / "WatchStorageManager.swift"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


STUBS = r"""
import Foundation

@MainActor
enum WatchDiagnostics {
    static func log(_ event: String, message: String, metadata: [String: String] = [:]) {}
}
"""


HARNESS = r"""
import Foundation

@main
struct WatchStorageArtworkListingFailureHarness {
    static func entry(hash: String) -> WatchManifestEntry {
        WatchManifestEntry(
            episodeHash: hash,
            selectionIdentifier: "selection-\(hash)",
            feedIdentifier: "feed",
            title: hash,
            podcastTitle: "Podcast",
            imageURL: nil,
            pubDate: Date(timeIntervalSince1970: 1),
            durationHint: 3_600,
            position: 0,
            consumed: false,
            mediaURL: URL(string: "https://example.com/\(hash).mp3")!,
            selectionSource: .manual,
            watchAddedDate: Date(timeIntervalSince1970: 1),
            playbackOrder: nil,
            skipForwardSeconds: 30,
            skipBackwardSeconds: 15,
            expectedFileSize: 4,
            skipChapterNames: [],
            autoSkipSponsors: false
        )
    }

    static func episode(hash: String, audioURL: URL, artworkBaseURL: URL) -> WatchEpisode {
        var episode = WatchEpisode(
            entry: entry(hash: hash),
            existing: nil,
            existingLocalFileWasValidated: false
        )
        episode.status = .downloaded
        episode.localFileURL = audioURL
        episode.actualFileSize = 4
        episode.chapters = [WatchChapter(
            title: "Chapter",
            startSeconds: 0,
            endSeconds: 10,
            imageFileName: "\(hash)-explicit.jpg"
        )]
        episode.chapterArtworkBaseURL = artworkBaseURL
        return episode
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor
    static func main() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("watch-storage-listing-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        let explicitArtwork = root.appendingPathComponent("explicit-artwork", isDirectory: true)
        let protectedDirectory = root.appendingPathComponent("protected", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: explicitArtwork, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: protectedDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDirectory.path)
            try? fileManager.removeItem(at: root)
        }

        let brokenArtworkDirectory = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: brokenArtworkDirectory)

        let removableAudio = downloads.appendingPathComponent("removable.mp3")
        let removableArtwork = explicitArtwork.appendingPathComponent("removable-explicit.jpg")
        try Data([1, 2, 3, 4]).write(to: removableAudio)
        try Data([5]).write(to: removableArtwork)

        let protectedAudio = protectedDirectory.appendingPathComponent("protected.mp3")
        try Data([1, 2, 3, 4]).write(to: protectedAudio)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedDirectory.path)

        let episodes = [
            episode(hash: "removable", audioURL: removableAudio, artworkBaseURL: explicitArtwork),
            episode(hash: "protected", audioURL: protectedAudio, artworkBaseURL: explicitArtwork),
        ]
        let preparation = await WatchStorageManager.removalContext(
            downloadsDirectory: downloads,
            chapterArtworkDirectory: brokenArtworkDirectory,
            episodeHashes: Set(episodes.map(\.episodeHash))
        )
        let result = await WatchStorageManager.removeLocalFiles(
            for: episodes,
            context: preparation.context
        )

        require(result.removedHashes == Set(["removable"]),
                "only the episode whose audio was removed may be confirmed")
        require(!fileManager.fileExists(atPath: removableAudio.path),
                "artwork listing failure suppressed valid audio removal")
        require(!fileManager.fileExists(atPath: removableArtwork.path),
                "explicit chapterArtworkBaseURL file was not attempted after listing failure")
        require(fileManager.fileExists(atPath: protectedAudio.path),
                "the failed audio removal unexpectedly disappeared")
        require(preparation.issues.contains { $0.event == "storage-artwork-index-failed" },
                "artwork listing failure was silently swallowed")
        require(result.issues.contains {
            $0.event == "storage-audio-remove-failed" && $0.episodeHash == "protected"
        }, "audio removal failure was not reported independently")
    }
}
"""


with tempfile.TemporaryDirectory(prefix="watch-storage-listing-failure-") as temp_dir:
    temp = Path(temp_dir)
    stubs = temp / "Stubs.swift"
    harness = temp / "Harness.swift"
    executable = temp / "watch-storage-listing-failure"
    stubs.write_text(STUBS)
    harness.write_text(HARNESS)
    compile_result = subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            str(stubs),
            str(WATCH_EPISODE),
            str(WATCH_STORAGE),
            str(harness),
            "-o",
            str(executable),
        ],
        text=True,
        capture_output=True,
    )
    require(
        compile_result.returncode == 0,
        f"Watch storage listing-failure harness did not compile:\n{compile_result.stdout}{compile_result.stderr}",
    )
    result = subprocess.run([str(executable)], text=True, capture_output=True)
    require(
        result.returncode == 0,
        f"Watch storage listing-failure scenario failed:\n{result.stdout}{result.stderr}",
    )


print("Watch storage artwork-listing failure regression checks passed")
