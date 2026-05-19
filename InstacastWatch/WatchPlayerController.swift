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
    private let dateFormatter = ISO8601DateFormatter()

    private override init() {
        super.init()
        dateFormatter.formatOptions = [.withInternetDateTime]
    }

    func togglePlayback(for episode: WatchEpisode) {
        if playingEpisodeHash == episode.episodeHash, isPlaying {
            pause()
        } else {
            play(episode)
        }
    }

    func play(_ episode: WatchEpisode) {
        guard let localFileURL = episode.localFileURL else { return }

        if playingEpisodeHash != episode.episodeHash {
            reportPosition(finished: false)
            player?.stop()
            do {
                player = try AVAudioPlayer(contentsOf: localFileURL)
            } catch {
                markEpisodePlaybackFailed(episode, error: error.localizedDescription)
                return
            }
            playingEpisodeHash = episode.episodeHash
        }

        guard let player else {
            markEpisodePlaybackFailed(episode, error: NSLocalizedString("Audiodatei konnte nicht abgespielt werden.", comment: ""))
            return
        }

        player.delegate = self

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            markEpisodePlaybackFailed(episode, error: error.localizedDescription)
            return
        }

        let duration = player.duration
        let startPosition = min(TimeInterval(episode.lastPlaybackPosition), max(0, duration - 1))
        if startPosition > 0, player.isPlaying != true {
            player.currentTime = startPosition
        }
        guard player.play() else {
            markEpisodePlaybackFailed(episode, error: NSLocalizedString("Audiodatei konnte nicht abgespielt werden.", comment: ""))
            return
        }
        isPlaying = true
        startTimer()
        reportPosition(finished: false)
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
            isPlaying = false
            stopTimer()
            reportPosition(finished: true)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reportPosition(finished: false)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func reportPosition(finished: Bool) {
        guard let hash = playingEpisodeHash, let player else { return }
        let position = max(0, Int(player.currentTime.rounded()))
        currentPosition = player.currentTime

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
