#!/usr/bin/env python3
"""Pins row-scoped Watch progress publication without a 4,500-row collection diff."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
COLLECTION_PATH = ROOT / "InstacastWatch" / "WatchEpisodeCollectionState.swift"
STORE_PATH = ROOT / "InstacastWatch" / "WatchManifestStore.swift"
VIEWS_PATH = ROOT / "InstacastWatch" / "WatchEpisodeViews.swift"
PLAYER_PATH = ROOT / "InstacastWatch" / "WatchPlayerController.swift"
APP_PATH = ROOT / "InstacastWatch" / "InstacastWatchApp.swift"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, "Missing source declaration: " + signature)
    brace = source.find("{", start)
    require(brace >= 0, "Missing source body: " + signature)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError("Unterminated source body: " + signature)


require(COLLECTION_PATH.exists(),
        "Runtime episode changes need a separately observable row-state collection.")

collection_source = COLLECTION_PATH.read_text()
store_source = STORE_PATH.read_text()
views_source = VIEWS_PATH.read_text()
player_source = PLAYER_PATH.read_text()
app_source = APP_PATH.read_text()

require("final class WatchEpisodeRowState: ObservableObject" in collection_source,
        "Each episode hash needs one stable ObservableObject row identity.")
require("final class WatchEpisodeCollectionState: ObservableObject" in collection_source,
        "Structural list publication needs a separate collection owner.")
runtime_update = body(collection_source, "func updateRuntimeEpisode(")
require("updateRowState" in runtime_update,
        "A progress tick must publish the affected row.")
require("structuralRevision" not in runtime_update and "objectWillChange.send" not in runtime_update,
        "A progress tick must not publish the 4,500-row collection.")

require("@Published private(set) var episodes" not in store_source,
        "The canonical 4,500-row array itself must not publish runtime-only subscript writes.")
update_one = body(store_source, "func updateEpisode(hash:")
require("episodeCollection.updateRuntimeEpisode" in update_one,
        "The store's runtime-only branch must use the row-scoped mutation path.")
require("episodes[index] = updatedEpisode" not in update_one,
        "The runtime path must not mutate a collection-published array before classification.")

list_start = views_source.find("struct WatchEpisodeListView")
list_end = views_source.find("private struct WatchStorageSummaryView", list_start)
require(list_start >= 0 and list_end > list_start, "Missing row-scoped Watch list item view.")
list_parent = views_source[list_start:list_end]
require("@EnvironmentObject private var player" not in list_parent,
        "The list parent must not observe per-second WatchPlayerController position changes.")
require("@ObservedObject private var storageManager" not in list_parent,
        "Download capacity measurements must refresh only the storage summary, not ForEach.")
require("player.currentPosition" not in list_parent,
        "The list parent must not read the live playback position.")
require("ForEach(sortedEpisodeRows)" in list_parent,
        "ForEach must iterate stable row-state identities, not copied episode values.")
require("@ObservedObject private var playbackSummary" in list_parent,
        "Playing-hash transitions need a low-frequency list summary publisher.")

row_item = body(views_source, "private struct WatchEpisodeListItemView")
require("@ObservedObject var state: WatchEpisodeRowState" in row_item,
        "Only the changed episode row should observe runtime progress.")
require("WatchActiveEpisodeRow" in row_item,
        "The current row must isolate the per-second playback position observer.")
active_row = body(views_source, "private struct WatchActiveEpisodeRow")
require("@ObservedObject var playbackPosition" in active_row,
        "Only the active row may observe the live position publisher.")
storage_summary = body(views_source, "private struct WatchStorageSummaryView")
require("@ObservedObject private var storageManager" in storage_summary,
        "The small storage summary must own its capacity observation boundary.")

require("final class WatchListPlaybackSummary: ObservableObject" in player_source and
        "final class WatchListPlaybackPosition: ObservableObject" in player_source,
        "List membership/play-state and per-second position require separate publishers.")
require("listPlaybackPosition.update" in player_source,
        "WatchPlayerController must forward position changes to the active-row publisher.")
require("@StateObject private var player" not in app_source and
        ".environmentObject(player)" not in app_source and
        "private let player = WatchPlayerController.shared" in app_source,
        "The app root must inject/use the singleton without observing every position tick.")


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
