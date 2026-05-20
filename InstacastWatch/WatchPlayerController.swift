import AVFoundation
import Foundation

@MainActor
final class WatchPlayerController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = WatchPlayerController()

    @Published private(set) var playingEpisodeHash: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentPosition: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var lastAutomaticReportDate: Date?
    private let dateFormatter = ISO8601DateFormatter()

    private override init() {
        super.init()
        dateFormatter.formatOptions = [.withInternetDateTime]
    }

    func togglePlayback(for episode: WatchEpisode) {
        if playingEpisodeHash == episode.episodeHash, isPlaying {
            pause()
        } else {
            _ = play(episode)
        }
    }

    @discardableResult
    func play(_ episode: WatchEpisode) -> Bool {
        guard let localFileURL = episode.localFileURL else { return false }

        if playingEpisodeHash != episode.episodeHash {
            reportPosition(finished: false)
            player?.stop()
            do {
                player = try AVAudioPlayer(contentsOf: localFileURL)
            } catch {
                markEpisodePlaybackFailed(episode, error: error.localizedDescription)
                return false
            }
            playingEpisodeHash = episode.episodeHash
        }

        guard let player else {
            markEpisodePlaybackFailed(episode, error: NSLocalizedString("Audiodatei konnte nicht abgespielt werden.", comment: ""))
            return false
        }

        player.delegate = self

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            markEpisodePlaybackFailed(episode, error: error.localizedDescription)
            return false
        }

        let duration = player.duration
        let startPosition = min(TimeInterval(episode.lastPlaybackPosition), max(0, duration - 1))
        if startPosition > 0, player.isPlaying != true {
            player.currentTime = startPosition
        }
        guard player.play() else {
            markEpisodePlaybackFailed(episode, error: NSLocalizedString("Audiodatei konnte nicht abgespielt werden.", comment: ""))
            return false
        }
        isPlaying = true
        currentPosition = player.currentTime
        startTimer()
        reportPosition(finished: false)
        return true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        reportPosition(finished: false)
    }

    func seek(to position: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, position), player.duration)
        currentPosition = player.currentTime
        reportPosition(finished: false)
    }

    func seek(by seconds: TimeInterval) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    func flushPlaybackState() {
        reportPosition(finished: false)
    }

    func applyPhoneState(_ payload: [String: Any]) {
        guard
            let hash = payload["episodeHash"] as? String,
            let timestampString = payload["timestamp"] as? String,
            let timestamp = dateFormatter.date(from: timestampString)
        else {
            return
        }

        let position = (payload["position"] as? NSNumber)?.intValue ?? 0
        let consumed = (payload["consumed"] as? NSNumber)?.boolValue ?? false
        WatchManifestStore.shared.updateEpisode(hash: hash) { episode in
            if let localDate = episode.lastPlaybackDate, localDate > timestamp {
                return
            }
            episode.lastPlaybackPosition = max(0, position)
            episode.lastPlaybackDate = timestamp
            episode.consumed = consumed
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let finishedHash = playingEpisodeHash
            isPlaying = false
            stopTimer()
            reportPosition(finished: true)
            self.player = nil
            playingEpisodeHash = nil
            currentPosition = 0

            if flag, let finishedHash, let nextEpisode = WatchManifestStore.shared.nextPlayableEpisode(after: finishedHash) {
                _ = play(nextEpisode)
            }
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickPlaybackPosition()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tickPlaybackPosition() {
        guard let player, playingEpisodeHash != nil else { return }
        currentPosition = player.currentTime

        let now = Date()
        if let lastAutomaticReportDate, now.timeIntervalSince(lastAutomaticReportDate) < 5 {
            return
        }
        reportPosition(finished: false)
    }

    private func reportPosition(finished: Bool) {
        guard let hash = playingEpisodeHash, let player else { return }
        let position = max(0, Int(player.currentTime.rounded()))
        currentPosition = player.currentTime
        lastAutomaticReportDate = Date()

        WatchManifestStore.shared.updateEpisode(hash: hash) { episode in
            episode.lastPlaybackPosition = finished ? episode.displayDuration : position
            episode.lastPlaybackDate = Date()
            if finished {
                episode.consumed = true
            }
        }

        let payload: [String: Any] = [
            "episodeHash": hash,
            "position": finished ? Int(player.duration.rounded()) : position,
            "consumed": finished,
            "timestamp": dateFormatter.string(from: Date()),
        ]
        if finished {
            WatchConnectivityController.shared.send(type: "playback.watchFinished", payload: payload, delivery: .reliable)
        } else {
            WatchConnectivityController.shared.send(type: "playback.watchPosition", payload: payload, delivery: .current)
        }
    }

    private func markEpisodePlaybackFailed(_ episode: WatchEpisode, error: String) {
        stopTimer()
        player?.stop()
        player = nil
        playingEpisodeHash = nil
        isPlaying = false
        currentPosition = 0

        WatchStorageManager.shared.removeLocalFile(for: episode)
        WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
            item.status = .failed
            item.localFileURL = nil
            item.actualFileSize = 0
            item.actualDuration = 0
            item.downloadedBytes = 0
            item.expectedBytes = 0
            item.lastError = error
        }

        WatchConnectivityController.shared.send(type: "watch.downloadFailed", payload: [
            "episodeHash": episode.episodeHash,
            "error": error,
            "timestamp": dateFormatter.string(from: Date()),
        ])
    }
}
