#!/usr/bin/env python3
"""Pins row-scoped Watch progress publication without a 4,500-row collection diff."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COLLECTION_PATH = ROOT / "InstacastWatch" / "WatchEpisodeCollectionState.swift"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


HARNESS = r'''
import Combine
import Foundation

@main
struct WatchRowPublicationProof {
    @MainActor
    static func makeEpisode(index: Int) -> WatchEpisode {
        let entry = WatchManifestEntry(
            episodeHash: "episode-\(index)",
            selectionIdentifier: "selection-\(index)",
            feedIdentifier: "feed",
            title: "Episode \(index)",
            podcastTitle: "Podcast",
            imageURL: nil,
            pubDate: Date(timeIntervalSince1970: TimeInterval(index)),
            durationHint: 3_600,
            position: 0,
            consumed: false,
            mediaURL: URL(string: "https://example.com/\(index).mp3")!,
            selectionSource: .latestRule,
            watchAddedDate: Date(timeIntervalSince1970: 1_000 + TimeInterval(index)),
            playbackOrder: index,
            skipForwardSeconds: 30,
            skipBackwardSeconds: 15,
            expectedFileSize: 10_000,
            skipChapterNames: [],
            autoSkipSponsors: false
        )
        var episode = WatchEpisode(
            entry: entry,
            existing: nil,
            existingLocalFileWasValidated: true
        )
        episode.status = .downloading
        return episode
    }

    @MainActor
    static func main() {
        let collection = WatchEpisodeCollectionState()
        collection.replace(with: (0..<4_500).map(makeEpisode))
        guard let originalRow = collection.rowState(forEpisodeHash: "episode-42") else {
            fatalError("missing row state")
        }
        let originalIdentity = ObjectIdentifier(originalRow)

        var collectionPublications = 0
        var rowPublications = 0
        let collectionToken = collection.objectWillChange.sink {
            collectionPublications += 1
        }
        let rowToken = originalRow.objectWillChange.sink {
            rowPublications += 1
        }

        var progress = collection.episodes[42]
        progress.downloadedBytes = 5_000
        progress.lastPlaybackPosition = 120
        collection.updateRuntimeEpisode(at: 42, with: progress)

        precondition(collectionPublications == 0,
                     "runtime tick published the entire episode collection")
        precondition(rowPublications == 1,
                     "runtime tick did not publish exactly one affected row")
        precondition(collection.episodes[42].downloadedBytes == 5_000,
                     "runtime tick did not update canonical storage")
        precondition(ObjectIdentifier(collection.rowState(forEpisodeHash: "episode-42")!) == originalIdentity,
                     "runtime tick replaced stable row identity")

        var terminalEpisodes = collection.episodes
        terminalEpisodes[42].status = .downloaded
        collection.replace(with: terminalEpisodes)

        precondition(collectionPublications == 1,
                     "terminal mutation did not publish the episode collection")
        precondition(ObjectIdentifier(collection.rowState(forEpisodeHash: "episode-42")!) == originalIdentity,
                     "structural refresh replaced an unchanged hash row identity")
        withExtendedLifetime((collectionToken, rowToken)) {}
        print("Watch row-scoped runtime publication proof passed")
    }
}
'''

with tempfile.TemporaryDirectory() as temporary_directory:
    temp = Path(temporary_directory)
    harness_path = temp / "main.swift"
    executable_path = temp / "watch-row-publication-proof"
    harness_path.write_text(HARNESS)
    compile_result = subprocess.run(
        [
            "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
            str(ROOT / "InstacastWatch" / "WatchEpisode.swift"),
            str(COLLECTION_PATH),
            str(harness_path),
            "-o", str(executable_path),
        ],
        capture_output=True,
        text=True,
    )
    require(compile_result.returncode == 0,
            "Swift row-publication proof did not compile:\n" + compile_result.stderr)
    run_result = subprocess.run([str(executable_path)], capture_output=True, text=True)
    require(run_result.returncode == 0,
            "Swift row-publication proof failed:\n" + run_result.stderr)
    require("Watch row-scoped runtime publication proof passed" in run_result.stdout,
            "Swift row-publication proof did not complete.")

print("Watch row-scoped runtime publication regression checks passed")
