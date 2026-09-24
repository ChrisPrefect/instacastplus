#!/usr/bin/env python3
"""Run the real Watch finish/toggle and navigation-change logic in native Swift.

The extracted SwiftUI onChange closure executes through a small state host.
Audio/session operations are stubs; production episode values and the finish,
next-episode, toggle, position-report, and navigation code execute unchanged.
"""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
player = (ROOT / "InstacastWatch/WatchPlayerController.swift").read_text()
views = (ROOT / "InstacastWatch/WatchEpisodeViews.swift").read_text()
manifest = (ROOT / "InstacastWatch/WatchManifestStore.swift").read_text()


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


marker = ".onChange(of: playbackSummary.playingEpisodeHash)"
# The pre-fix view has no playback observer: its actual reaction is a no-op.
on_change = block(views, marker).split("{", 1)[1].rsplit("}", 1)[0] if marker in views else "hash in"
parameter, reaction = on_change.split(" in", 1)
assert parameter.strip() == "hash", "Keep the native host bound to the actual onChange parameter."
assert "NavigationStack(path: $playerPath)" in views
assert "WatchPlayerView(episode: episode, accentColor: accentColor)" in views
assert "player.togglePlayback(for: episode)" in views
assert 'Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")' in views

methods = "\n".join(block(player, marker).replace("private func", "func") for marker in (
    "func togglePlayback(for episode:",
    "nonisolated func audioPlayerDidFinishPlaying(",
    "private func reportPosition(finished:",
))
next_episode = block(manifest, "func nextPlayableEpisode(after episodeHash:")
pop_unavailable = block(views, "private func popUnavailablePlayerIfNeeded()").replace("private func", "func")

harness = r'''
import Foundation
final class AVAudioPlayer {
    var currentTime = 0.0
    var duration = 100.0
    var isPlaying = true
}
@MainActor final class WatchManifestStore {
    static let shared = WatchManifestStore()
    var sortedEpisodes: [WatchEpisode] = []
    func episode(hash: String) -> WatchEpisode? { sortedEpisodes.first { $0.episodeHash == hash } }
    func updateEpisode(hash: String, mutate: (inout WatchEpisode) -> Void) {
        guard let i = sortedEpisodes.firstIndex(where: { $0.episodeHash == hash }) else { return }
        mutate(&sortedEpisodes[i])
    }
NEXT_EPISODE
}
@MainActor final class WatchDownloadManager {
    static let shared = WatchDownloadManager()
    func removePlaybackFile(for episode: WatchEpisode, expectedStatus: WatchEpisodeStatus,
        disposition: WatchEpisodeStatus, error: String, stillCurrentPlayback: () -> Bool) async -> Bool { false }
    func startQueuedDownloads() {}
    func finalizePendingRemoval(hash: String) {}
}
enum Delivery { case reliable, current }
@MainActor final class WatchConnectivityController {
    static let shared = WatchConnectivityController()
    func send(type: String, payload: [String: Any], delivery: Delivery) {}
}
enum WatchDiagnostics {
    static func log(_ event: String, message: String, metadata: [String: String]) {}
}
@MainActor final class NavigationHost {
    let store = WatchManifestStore.shared
    var playerPath = ["A"]
    func playbackHashChanged(_ hash: String?) {
REACTION
    }
POP_UNAVAILABLE
}
@MainActor final class WatchPlayerController {
    var player: AVAudioPlayer?
    var onPlaybackHashChange: ((String?) -> Void)?
    var playingEpisodeHash: String? {
        didSet {
            if playingEpisodeHash != oldValue { onPlaybackHashChange?(playingEpisodeHash) }
        }
    }
    var isPlaying = false
    var currentPosition = 0.0
    var playbackGeneration = 0
    var lastAutomaticReportDate: Date?
    let dateFormatter = ISO8601DateFormatter()
    func play(_ episode: WatchEpisode) async -> Bool {
        player = AVAudioPlayer()
        playingEpisodeHash = episode.episodeHash
        isPlaying = true
        return true
    }
    func pause() { isPlaying = false; player?.isPlaying = false }
    func playbackMetadata(for episode: WatchEpisode, fileURL: URL, error: Error?) -> [String: String] { [:] }
    func stopTimer() {}
    func clearPlaybackActiveMarker() {}
    func clearNowPlayingInfo() {}
METHODS
}
func episode(_ hash: String) -> WatchEpisode {
    let entry = WatchManifestEntry(episodeHash: hash, selectionIdentifier: hash, feedIdentifier: "feed",
        title: hash, podcastTitle: "podcast", imageURL: nil, pubDate: Date(), durationHint: 100,
        position: 0, consumed: false, mediaURL: URL(string: "https://example.invalid/episode.mp3")!,
        selectionSource: .manual, watchAddedDate: Date(), playbackOrder: 0, skipForwardSeconds: 30,
        skipBackwardSeconds: 30, expectedFileSize: 100, skipChapterNames: [], autoSkipSponsors: false)
    var result = WatchEpisode(entry: entry, existing: nil, existingLocalFileWasValidated: false)
    result.status = .downloaded
    result.localFileURL = URL(fileURLWithPath: "/tmp/episode.mp3")
    return result
}
@main struct Checks {
    @MainActor static func main() async {
        var failures = 0
        func require(_ pass: Bool, _ description: String) {
            if !pass { failures += 1; print("FAIL: \(description)") }
        }
        let a = episode("A"), b = episode("B")
        WatchManifestStore.shared.sortedEpisodes = [a, b]
        let navigation = NavigationHost()
        let controller = WatchPlayerController()
        controller.onPlaybackHashChange = { navigation.playbackHashChanged($0) }
        _ = await controller.play(a)
        let finishedPlayer = controller.player!
        finishedPlayer.currentTime = 100
        controller.audioPlayerDidFinishPlaying(finishedPlayer, successfully: true)
        for _ in 0..<1000 where controller.playingEpisodeHash != "B" { await Task.yield() }
        require(controller.playingEpisodeHash == "B", "The actual finish handler must advance A to B")
        require(navigation.playerPath == ["B"], "An already visible player must follow automatic A-to-B playback")
        let visibleEpisode = WatchManifestStore.shared.episode(hash: navigation.playerPath.last!)!
        controller.togglePlayback(for: visibleEpisode)
        for _ in 0..<20 { await Task.yield() }
        require(controller.playingEpisodeHash == "B" && !controller.isPlaying,
            "The visible pause button must pause B instead of restarting A")

        navigation.playerPath = []
        navigation.playbackHashChanged("A")
        require(navigation.playerPath.isEmpty, "Going Back must keep the list open during subsequent playback changes")
        navigation.playerPath = ["A"]
        navigation.playbackHashChanged(nil)
        require(navigation.playerPath == ["A"], "Temporary nil between episodes must not pop the player")
        navigation.playbackHashChanged("unavailable")
        require(navigation.playerPath == ["A"], "An unknown playback hash must not replace a valid destination")
        navigation.playbackHashChanged("B")
        navigation.playbackHashChanged("B")
        require(navigation.playerPath == ["B"], "The next valid hash must replace, never append to, the visible player")
        navigation.playerPath = ["B"]
        WatchManifestStore.shared.sortedEpisodes = [a]
        navigation.popUnavailablePlayerIfNeeded()
        require(navigation.playerPath.isEmpty, "Removing the visible episode must retain the existing navigation cleanup")
        print("Watch continuation navigation runtime checks: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
'''.replace("NEXT_EPISODE", next_episode).replace("REACTION", reaction).replace(
    "POP_UNAVAILABLE", pop_unavailable
).replace("METHODS", methods)

with tempfile.TemporaryDirectory(prefix="watch-navigation-regression-") as temporary:
    directory = Path(temporary)
    (directory / "checks.swift").write_text(harness)
    subprocess.run([
        "swiftc", "-parse-as-library", str(ROOT / "InstacastWatch/WatchEpisode.swift"),
        str(directory / "checks.swift"), "-o", str(directory / "checks")
    ], check=True)
    subprocess.run([str(directory / "checks")], check=True)
