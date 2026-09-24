#!/usr/bin/env python3
"""Exercise production WatchEpisode file-reuse rules across 4,500 entries."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WATCH_EPISODE = ROOT / "InstacastWatch" / "WatchEpisode.swift"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


HARNESS = r"""
import Foundation

@main
struct WatchManifestReuseHarness {
    static func entry(_ index: Int, mediaURL: URL? = nil) -> WatchManifestEntry {
        WatchManifestEntry(
            episodeHash: "episode-\(index)",
            selectionIdentifier: "selection-\(index)",
            feedIdentifier: "feed",
            title: "Episode \(index)",
            podcastTitle: "Podcast",
            imageURL: nil,
            pubDate: Date(timeIntervalSince1970: Double(index)),
            durationHint: 3_600,
            position: 0,
            consumed: false,
            mediaURL: mediaURL ?? URL(string: "https://example.com/\(index).mp3")!,
            selectionSource: .manual,
            watchAddedDate: Date(timeIntervalSince1970: Double(index)),
            playbackOrder: index,
            skipForwardSeconds: 30,
            skipBackwardSeconds: 15,
            expectedFileSize: 1_024,
            skipChapterNames: [],
            autoSkipSponsors: false
        )
    }

    static func existing(_ index: Int, status: WatchEpisodeStatus = .downloaded) -> WatchEpisode {
        var episode = WatchEpisode(
            entry: entry(index),
            existing: nil,
            existingLocalFileWasValidated: false
        )
        episode.status = status
        episode.localFileURL = URL(fileURLWithPath: "/prevalidated/episode-\(index).mp3")
        episode.actualFileSize = 1_024
        episode.actualDuration = 3_600
        return episode
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() {
        for index in 0..<4_500 {
            let oldEpisode = existing(index, status: index.isMultiple(of: 2) ? .downloaded : .removing)
            let merged = WatchEpisode(
                entry: entry(index),
                existing: oldEpisode,
                existingLocalFileWasValidated: true
            )
            require(merged.status == .downloaded, "prevalidated download was not reused")
            require(merged.localFileURL == oldEpisode.localFileURL, "prevalidated local URL was discarded")
            require(merged.actualFileSize == oldEpisode.actualFileSize, "prevalidated file metadata was discarded")
        }

        let oldEpisode = existing(9_001)
        let notValidated = WatchEpisode(
            entry: entry(9_001),
            existing: oldEpisode,
            existingLocalFileWasValidated: false
        )
        require(notValidated.status == .queued && notValidated.localFileURL == nil,
                "an unvalidated local file was reused")

        let changedMedia = WatchEpisode(
            entry: entry(9_001, mediaURL: URL(string: "https://example.com/replaced.mp3")!),
            existing: oldEpisode,
            existingLocalFileWasValidated: true
        )
        require(changedMedia.status == .queued && changedMedia.localFileURL == nil,
                "a prevalidated file was reused for a different media URL")

        var emptyFile = oldEpisode
        emptyFile.actualFileSize = 0
        let zeroSized = WatchEpisode(
            entry: entry(9_001),
            existing: emptyFile,
            existingLocalFileWasValidated: true
        )
        require(zeroSized.status == .queued && zeroSized.localFileURL == nil,
                "a zero-sized prevalidated file was reused")
    }
}
"""


with tempfile.TemporaryDirectory(prefix="watch-manifest-reuse-") as temp_dir:
    temp = Path(temp_dir)
    harness = temp / "Harness.swift"
    executable = temp / "watch-manifest-reuse"
    harness.write_text(HARNESS)
    compile_result = subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            str(WATCH_EPISODE),
            str(harness),
            "-o",
            str(executable),
        ],
        text=True,
        capture_output=True,
    )
    require(
        compile_result.returncode == 0,
        f"Watch manifest reuse harness did not compile:\n{compile_result.stdout}{compile_result.stderr}",
    )
    result = subprocess.run([str(executable)], text=True, capture_output=True)
    require(
        result.returncode == 0,
        f"Watch manifest 4,500-entry reuse scenario failed:\n{result.stdout}{result.stderr}",
    )


print("Watch manifest prevalidated reuse MainActor-I/O regression checks passed")
