import AVFoundation
import Foundation
import MediaPlayer
import UIKit

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
    private var playbackGeneration = 0
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkURL: URL?
    private var nowPlayingArtworkEpisodeHash: String?

    private override init() {
        super.init()
        dateFormatter.formatOptions = [.withInternetDateTime]
        configureRemoteCommands()
    }

    func togglePlayback(for episode: WatchEpisode) {
        if playingEpisodeHash == episode.episodeHash, isPlaying {
            pause()
        } else {
            Task { @MainActor in
                _ = await play(episode)
            }
        }
    }

    @discardableResult
    func play(_ episode: WatchEpisode) async -> Bool {
        guard let localFileURL = WatchStorageManager.shared.resolvedLocalFileURL(for: episode) else {
            var metadata = WatchDiagnostics.metadata(for: episode)
            metadata["localFileMissing"] = "true"
            WatchDiagnostics.log("playback-start-failed", message: "Watch-Playback ohne lokale Datei", metadata: metadata)
            WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                item.status = .queued
                item.localFileURL = nil
                item.actualFileSize = 0
                item.actualDuration = 0
                item.downloadedBytes = 0
                item.expectedBytes = 0
                item.chapters = []
                item.chapterArtworkBaseURL = nil
            }
            WatchDownloadManager.shared.startQueuedDownloads()
            return false
        }

        if localFileURL != episode.localFileURL {
            WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                item.localFileURL = localFileURL
            }
            var metadata = WatchDiagnostics.metadata(for: episode)
            metadata["pathRerooted"] = "true"
            metadata["resolvedFileName"] = localFileURL.lastPathComponent
            WatchDiagnostics.log("playback-pathRerooted", message: "Watch-Playbackpfad auf aktuellen Container normalisiert", metadata: metadata)
        }

        playbackGeneration += 1
        let generation = playbackGeneration

        if playingEpisodeHash != episode.episodeHash {
            reportPosition(finished: false)
            player?.stop()
            do {
                WatchDiagnostics.log("playback-start", message: "Watch-Playback startet", metadata: playbackMetadata(for: episode, fileURL: localFileURL, error: nil))
                player = try AVAudioPlayer(contentsOf: localFileURL)
            } catch {
                WatchDiagnostics.log("playback-start-failed", message: "Watch-Playback konnte Datei nicht oeffnen", metadata: playbackMetadata(for: episode, fileURL: localFileURL, error: error))
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
            try await activateLongFormAudioSession()
        } catch {
            WatchDiagnostics.log("playback-audio-session-failed", message: "Watch-Audiositzung konnte nicht aktiviert werden", metadata: playbackMetadata(for: episode, fileURL: localFileURL, error: error))
            markEpisodePlaybackFailed(episode, error: error.localizedDescription)
            return false
        }

        guard generation == playbackGeneration, playingEpisodeHash == episode.episodeHash else {
            return false
        }

        let duration = player.duration
        let startPosition = min(TimeInterval(episode.lastPlaybackPosition), max(0, duration - 1))
        if startPosition > 0, player.isPlaying != true {
            player.currentTime = startPosition
        }
        guard player.play() else {
            WatchDiagnostics.log("playback-start-failed", message: "AVAudioPlayer.play() fehlgeschlagen", metadata: playbackMetadata(for: episode, fileURL: localFileURL, error: nil))
            markEpisodePlaybackFailed(episode, error: NSLocalizedString("Audiodatei konnte nicht abgespielt werden.", comment: ""))
            return false
        }
        isPlaying = true
        currentPosition = player.currentTime
        startTimer()
        updateNowPlayingInfo(for: episode)
        reportPosition(finished: false)
        return true
    }

    func pause() {
        playbackGeneration += 1
        player?.pause()
        isPlaying = false
        stopTimer()
        reportPosition(finished: false)
        updateNowPlayingInfo()
    }

    func seek(to position: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, position), player.duration)
        currentPosition = player.currentTime
        reportPosition(finished: false)
        updateNowPlayingInfo()
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
        let finishedTime = player.currentTime
        let finishedDuration = player.duration
        Task { @MainActor in
            let finishedHash = playingEpisodeHash
            let currentEpisode = finishedHash.flatMap { WatchManifestStore.shared.episode(hash: $0) }
            var metadata: [String: String]
            if let currentEpisode, let localFileURL = currentEpisode.localFileURL {
                metadata = playbackMetadata(for: currentEpisode, fileURL: localFileURL, error: nil)
            } else {
                metadata = ["episodeHash": finishedHash ?? ""]
            }
            metadata["successfully"] = flag ? "true" : "false"
            metadata["currentTime"] = "\(finishedTime)"
            metadata["duration"] = "\(finishedDuration)"
            WatchDiagnostics.log("audioPlayerDidFinishPlaying", message: "Watch-Playback beendet", metadata: metadata)
            isPlaying = false
            stopTimer()
            if flag {
                reportPosition(finished: true)
            } else {
                reportPosition(finished: false)
            }
            self.player = nil
            playingEpisodeHash = nil
            currentPosition = 0
            clearNowPlayingInfo()

            if flag, let finishedHash, let nextEpisode = WatchManifestStore.shared.nextPlayableEpisode(after: finishedHash) {
                _ = await play(nextEpisode)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            let hash = playingEpisodeHash
            let currentEpisode = hash.flatMap { WatchManifestStore.shared.episode(hash: $0) }
            var metadata: [String: String]
            if let currentEpisode, let localFileURL = currentEpisode.localFileURL {
                metadata = playbackMetadata(for: currentEpisode, fileURL: localFileURL, error: error)
            } else {
                metadata = ["episodeHash": hash ?? ""]
                if let error {
                    metadata["error"] = error.localizedDescription
                }
            }
            WatchDiagnostics.log("audioPlayerDecodeErrorDidOccur", message: "Watch-Playback Decode-Fehler", metadata: metadata)
        }
    }

    private func activateLongFormAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { activated, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if activated {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WatchPlayerError.audioSessionNotActivated)
                }
            }
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.toggleCurrentPlayback()
            }
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                await self?.playCurrentEpisode()
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.pauseCurrentEpisode()
            }
            return .success
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.seek(to: event.positionTime)
            }
            return .success
        }

        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.seekUsingCurrentEpisode(forward: true)
            }
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.seekUsingCurrentEpisode(forward: false)
            }
            return .success
        }
    }

    private func toggleCurrentPlayback() async {
        if isPlaying {
            pause()
        } else {
            await playCurrentEpisode()
        }
    }

    private func playCurrentEpisode() async {
        guard
            let hash = playingEpisodeHash,
            let episode = WatchManifestStore.shared.episode(hash: hash)
        else {
            return
        }
        _ = await play(episode)
    }

    private func pauseCurrentEpisode() {
        if isPlaying {
            pause()
        } else {
            updateNowPlayingInfo()
        }
    }

    private func seekUsingCurrentEpisode(forward: Bool) {
        guard let episode = currentEpisode() else { return }
        let seconds = forward ? episode.skipForwardSeconds : episode.skipBackwardSeconds
        seek(by: forward ? Double(seconds) : -Double(seconds))
    }

    private func updateNowPlayingInfo(for episode: WatchEpisode? = nil) {
        guard
            let player,
            let episode = episode ?? currentEpisode()
        else {
            clearNowPlayingInfo()
            return
        }

        let chapterTitle = episode.currentChapter(at: player.currentTime)?.title
        let albumTitle: String
        if let chapterTitle, !chapterTitle.isEmpty {
            albumTitle = chapterTitle
        } else {
            albumTitle = episode.podcastTitle
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcastTitle,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if !albumTitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        if let artwork = nowPlayingArtwork,
           nowPlayingArtworkEpisodeHash == episode.episodeHash,
           nowPlayingArtworkURL == episode.imageURL {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: episode.skipForwardSeconds)]
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: episode.skipBackwardSeconds)]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let imageURL = episode.imageURL {
            loadNowPlayingArtwork(from: imageURL, episodeHash: episode.episodeHash)
        } else {
            clearNowPlayingArtwork()
        }
    }

    private func currentEpisode() -> WatchEpisode? {
        guard let hash = playingEpisodeHash else { return nil }
        return WatchManifestStore.shared.episode(hash: hash)
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        clearNowPlayingArtwork()
    }

    private func loadNowPlayingArtwork(from url: URL, episodeHash: String) {
        if nowPlayingArtworkURL == url, nowPlayingArtworkEpisodeHash == episodeHash {
            return
        }

        nowPlayingArtworkTask?.cancel()
        nowPlayingArtwork = nil
        nowPlayingArtworkURL = url
        nowPlayingArtworkEpisodeHash = episodeHash
        nowPlayingArtworkTask = Task { [weak self] in
            guard let image = await Self.image(from: url), !Task.isCancelled else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard
                    let self,
                    self.playingEpisodeHash == episodeHash,
                    self.nowPlayingArtworkURL == url
                else {
                    return
                }
                self.nowPlayingArtwork = artwork
                self.updateNowPlayingInfo()
            }
        }
    }

    private func clearNowPlayingArtwork() {
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkTask = nil
        nowPlayingArtwork = nil
        nowPlayingArtworkURL = nil
        nowPlayingArtworkEpisodeHash = nil
    }

    private static func image(from url: URL) async -> UIImage? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }
            return UIImage(data: data)
        } catch {
            return nil
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
        updateNowPlayingInfo()

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

    private func playbackMetadata(for episode: WatchEpisode, fileURL: URL, error: Error?) -> [String: String] {
        var metadata = WatchDiagnostics.metadata(for: episode)
        metadata["fileName"] = fileURL.lastPathComponent
        metadata["filePathHash"] = WatchDiagnostics.stableHash(fileURL.path)
        metadata["fileExists"] = FileManager.default.fileExists(atPath: fileURL.path) ? "true" : "false"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? NSNumber {
            metadata["fileBytes"] = "\(size.int64Value)"
        }
        if let player {
            metadata["playerCurrentTime"] = "\(player.currentTime)"
            metadata["playerDuration"] = "\(player.duration)"
            metadata["playerIsPlaying"] = player.isPlaying ? "true" : "false"
        }
        if let error {
            metadata["error"] = error.localizedDescription
            metadata["errorDomain"] = (error as NSError).domain
            metadata["errorCode"] = "\((error as NSError).code)"
        }
        return metadata
    }

    private func markEpisodePlaybackFailed(_ episode: WatchEpisode, error: String) {
        playbackGeneration += 1
        stopTimer()
        player?.stop()
        player = nil
        playingEpisodeHash = nil
        isPlaying = false
        currentPosition = 0
        clearNowPlayingInfo()

        WatchStorageManager.shared.removeLocalFile(for: episode)
        WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
            item.status = .failed
            item.localFileURL = nil
            item.actualFileSize = 0
            item.actualDuration = 0
            item.downloadedBytes = 0
            item.expectedBytes = 0
            item.chapters = []
            item.chapterArtworkBaseURL = nil
            item.lastError = error
        }

        WatchConnectivityController.shared.send(type: "watch.downloadFailed", payload: [
            "episodeHash": episode.episodeHash,
            "error": error,
            "timestamp": dateFormatter.string(from: Date()),
        ])
    }
}

private enum WatchPlayerError: LocalizedError {
    case audioSessionNotActivated

    var errorDescription: String? {
        NSLocalizedString("Audiositzung konnte nicht aktiviert werden.", comment: "")
    }
}
