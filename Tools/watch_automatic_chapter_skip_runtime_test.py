#!/usr/bin/env python3
"""Execute Watch playback transitions with the production chapter model and methods.

State transitions use audio/service doubles. A separate silent AVFoundation
probe verifies normal end delivery after the production skip with real macOS
AVAudioPlayer. Neither test implies a watchOS hardware/audio test.
"""
from pathlib import Path
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "InstacastWatch/WatchPlayerController.swift").read_text()


def method(marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func", "func")


methods = "\n".join(method(marker) for marker in (
    "private func tickPlaybackPosition()", "private func reportPosition(finished:",
    "func seek(to position: TimeInterval)", "func seek(by seconds: TimeInterval)", "func pause()",
))
for marker in ("private func automaticChapterSkipRange(", "private func applyAutomaticChapterSkipping(",
               "private func seek(to position: TimeInterval, manualSelection:"):
    if marker in source:
        methods += "\n" + method(marker)
start_tail = method("func play(_ episode:").split("        let duration = player.duration", 1)[1]
start_tail = "let duration = player.duration" + start_tail.rsplit("}", 1)[0]

program = r'''
import Foundation
final class AVAudioPlayer {
    var currentTime = 0.0
    var duration = 100.0
    var isPlaying = true
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
}
@MainActor final class WatchManifestStore {
    static let shared = WatchManifestStore()
    var value: WatchEpisode!
    func episode(hash: String) -> WatchEpisode? { value?.episodeHash == hash ? value : nil }
    func updateEpisode(hash: String, mutate: (inout WatchEpisode) -> Void) { mutate(&value) }
}
struct Inspection { var fileExists = true; var fileSize: Int64? = 1 }
@MainActor final class WatchStorageManager {
    static let shared = WatchStorageManager()
    var latestFreeBytes: Int64? = nil
    static func inspectFile(at: URL) async -> Inspection { Inspection() }
}
enum Delivery { case reliable, current }
@MainActor final class WatchConnectivityController {
    static let shared = WatchConnectivityController()
    func send(type: String, payload: [String:Any], delivery: Delivery) {}
}
enum WatchDiagnostics {
    static func log(_ event: String, message: String, metadata: [String:String]) {}
}
@MainActor final class WatchPlayerController {
    var player: AVAudioPlayer? = AVAudioPlayer()
    var playingEpisodeHash: String? = "A"
    var isPlaying = true
    var currentPosition = 0.0
    var playbackGeneration = 0
    var manuallySelectedSkipRange: Range<TimeInterval>?
    var lastStallReportedPosition = -1.0
    var lastAutomaticReportDate: Date?
    let dateFormatter = ISO8601DateFormatter()
    func updateNowPlayingInfo() {}
    func updateNowPlayingInfo(for episode: WatchEpisode) {}
    func playbackMetadata(for episode: WatchEpisode, fileURL: URL, error: Error?) -> [String:String] { [:] }
    func markEpisodePlaybackFailed(_ episode: WatchEpisode, error: String) async {}
    func setPlaybackActiveMarker(for hash: String) {}
    func startTimer() {}
    func stopTimer() {}
    func clearPlaybackActiveMarker() {}
    func start(_ episode: WatchEpisode) async -> Bool {
        let player = self.player!
        let localFileURL = episode.localFileURL!
        START_TAIL
    }
    METHODS
}
func chapter(_ title: String, _ start: Int, _ end: Int?) -> WatchChapter {
    WatchChapter(title:title, startSeconds:start, endSeconds:end, imageFileName:nil)
}
func episode() -> WatchEpisode {
    let entry = WatchManifestEntry(episodeHash:"A", selectionIdentifier:"A", feedIdentifier:"feed", title:"A", podcastTitle:"Podcast", imageURL:nil, pubDate:Date(), durationHint:100, position:0, consumed:false, mediaURL:URL(string:"https://example.invalid/audio.mp3")!, selectionSource:.manual, watchAddedDate:Date(), playbackOrder:0, skipForwardSeconds:30, skipBackwardSeconds:30, expectedFileSize:100, skipChapterNames:[], autoSkipSponsors:true)
    var item = WatchEpisode(entry:entry, existing:nil, existingLocalFileWasValidated:false)
    item.status = .downloaded
    item.localFileURL = URL(fileURLWithPath:"/tmp/watch-skip-test.mp3")
    item.chapters = [chapter("Intro",0,10), chapter("Sponsor: A",10,20), chapter("Sponsor: B",20,30), chapter("Episode",30,100)]
    return item
}
@main struct Test {
    @MainActor static func main() async {
        var failures = 0
        func check(_ actual: Double, _ expected: Double, _ label: String) {
            if actual != expected { failures += 1; print("FAIL: \(label): \(actual) != \(expected)") }
        }
        func fresh(_ position: Double = 15) -> WatchPlayerController {
            WatchManifestStore.shared.value = episode()
            let p = WatchPlayerController(); p.player!.currentTime = position; return p
        }
        var p = fresh(); p.tickPlaybackPosition()
        check(p.player!.currentTime,30,"Natural playback skips consecutive sponsor chapters")
        check(p.currentPosition,30,"Published position follows skip")
        check(Double(WatchManifestStore.shared.value.lastPlaybackPosition),30,"Persisted position follows skip")
        p = fresh(); p.isPlaying = false; p.player!.isPlaying = false; p.tickPlaybackPosition()
        check(p.player!.currentTime,15,"Paused playback does not skip")
        p = fresh(); p.player!.isPlaying = false; p.tickPlaybackPosition()
        check(p.player!.currentTime,15,"Stalled playback does not skip")
        p = fresh(); WatchManifestStore.shared.value.autoSkipSponsors = false; p.tickPlaybackPosition()
        check(p.player!.currentTime,15,"Disabled policy preserves audio")
        WatchManifestStore.shared.value.skipChapterNames = ["SPONSOR: "]; p.tickPlaybackPosition()
        check(p.player!.currentTime,30,"Live case-insensitive named policy is applied")
        p = fresh(); p.seek(to:15); p.tickPlaybackPosition()
        check(p.player!.currentTime,15,"Explicit scrub can listen inside skipped chapter")
        p.player!.currentTime = 25; p.tickPlaybackPosition()
        check(p.player!.currentTime,25,"Explicit selection retains entire contiguous sponsor block")
        p.pause()
        _ = await p.start(WatchManifestStore.shared.value)
        check(p.player!.currentTime,25,"Pause/resume keeps explicit selection")
        p.player!.currentTime = 35; p.tickPlaybackPosition()
        p.player!.currentTime = 15; p.tickPlaybackPosition()
        check(p.player!.currentTime,30,"Leaving the block re-arms automatic skipping")
        p = fresh(0); p.seek(by:15); p.tickPlaybackPosition()
        check(p.player!.currentTime,30,"Skip button does not suppress automatic skipping")
        p = fresh(); p.player!.isPlaying = false
        WatchManifestStore.shared.value.lastPlaybackPosition = 15
        _ = await p.start(WatchManifestStore.shared.value)
        check(p.player!.currentTime,30,"Start/resume skips before playing audio")
        p = fresh(); WatchManifestStore.shared.value.chapters = [chapter("Sponsor: A",10,20),chapter("Sponsor: B",25,30),chapter("Content",30,100)]
        p.tickPlaybackPosition(); check(p.player!.currentTime,20,"Explicit gap remains audible")
        p = fresh(85); WatchManifestStore.shared.value.chapters = [chapter("Sponsor: A",80,90)]
        p.tickPlaybackPosition(); check(p.player!.currentTime,90,"Finite final chapter does not finish the episode")
        p = fresh(85); WatchManifestStore.shared.value.chapters = [chapter("Sponsor: A",80,nil)]
        p.tickPlaybackPosition(); check(p.player!.currentTime,100,"Missing last end uses measured duration")
        check(WatchManifestStore.shared.value.consumed ? 1 : 0,0,"Only actual finish delegate marks consumed")
        p = fresh(); WatchManifestStore.shared.value.chapters = [chapter("Sponsor: A",10,4_294_967),chapter("Content",30,100)]
        p.tickPlaybackPosition(); check(p.player!.currentTime,30,"Oversized metadata cannot skip later content")
        p = fresh(85); p.player!.duration = 92; WatchManifestStore.shared.value.chapters = [chapter("Sponsor: A",80,4_294_967)]
        p.tickPlaybackPosition(); check(p.player!.currentTime,92,"Skip never exceeds actual media duration")
        if failures > 0 { exit(1) }
        print("Watch automatic chapter skipping runtime checks passed")
    }
}
'''.replace("START_TAIL", start_tail).replace("METHODS", methods)

boundary = r'''
import Foundation
import AVFoundation
@MainActor final class WatchManifestStore {
    static let shared = WatchManifestStore()
    var value: WatchEpisode!
    func episode(hash: String) -> WatchEpisode? { value }
}
@MainActor final class WatchPlayerController {
    var player: AVAudioPlayer?
    var playingEpisodeHash: String? = "A"
    var manuallySelectedSkipRange: Range<TimeInterval>?
    METHODS
}
final class Completion: NSObject, AVAudioPlayerDelegate {
    var succeeded = false
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        succeeded = flag
    }
}
FIXTURE_EPISODE
@main struct Boundary {
    @MainActor static func main() throws {
        WatchManifestStore.shared.value = episode()
        WatchManifestStore.shared.value.chapters = [chapter("Sponsor: tail",0,nil)]
        for beforePlay in [true, false] {
            let p = WatchPlayerController()
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            p.player = player
            let completion = Completion(); player.delegate = completion
            if beforePlay { p.applyAutomaticChapterSkipping() }
            precondition(player.play(), "The silent AVFoundation boundary fixture must play")
            if !beforePlay { p.applyAutomaticChapterSkipping() }
            let deadline = Date().addingTimeInterval(2)
            while !completion.succeeded && deadline.timeIntervalSinceNow > 0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(completion.succeeded, "An automatic skip to measured duration must deliver the ordinary successful finish callback")
            player.stop()
        }
        print("Real AVAudioPlayer delivers ordinary finish after start/tick skip to duration")
    }
}
'''.replace("METHODS", "\n".join(method(marker) for marker in (
    "private func automaticChapterSkipRange(", "private func applyAutomaticChapterSkipping(",
)) if "private func applyAutomaticChapterSkipping(" in source else "func applyAutomaticChapterSkipping() {}")
boundary = boundary.replace("FIXTURE_EPISODE", "func chapter(" + program.split("func chapter(", 1)[1].split("@main struct Test", 1)[0])

with tempfile.TemporaryDirectory(prefix="watch-chapter-skip-") as temporary:
    directory = Path(temporary)
    (directory / "main.swift").write_text(program)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "InstacastWatch/WatchEpisode.swift"),
                    str(directory / "main.swift"), "-o", str(directory / "test")], check=True)
    subprocess.run([str(directory / "test")], check=True)
    new_episode = method("func play(_ episode:").split("if playingEpisodeHash != episode.episodeHash {", 1)[1]
    assert new_episode.index("manuallySelectedSkipRange = nil") < new_episode.index("AVAudioPlayer(contentsOf:"), "A new episode must not inherit manual skip suppression"
    with wave.open(str(directory / "silence.wav"), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(bytes(8000))
    (directory / "boundary.swift").write_text(boundary)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "InstacastWatch/WatchEpisode.swift"),
                    str(directory / "boundary.swift"), "-o", str(directory / "boundary")], check=True)
    subprocess.run([str(directory / "boundary"), str(directory / "silence.wav")], check=True, timeout=10)
