import AVFoundation
import Foundation

@MainActor
final class WatchDownloadManager: NSObject, ObservableObject {
    static let shared = WatchDownloadManager()
    static let backgroundSessionIdentifier = "com.iteconomy.instacastplus.watch.downloads"

    private var activeTasksByHash: [String: URLSessionDownloadTask] = [:]
    private var lastProgressReportByHash: [String: Date] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.allowsCellularAccess = true
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    func replaceManifest(entries: [WatchManifestEntry]) {
        WatchDiagnostics.log("manifest-replace-received", message: "Watch empfaengt Replace-Manifest", metadata: [
            "entryCount": "\(entries.count)",
        ])
        let removed = WatchManifestStore.shared.applyManifest(entries: entries)
        for episode in removed {
            deleteRemovedManifestEpisode(episode)
        }
        WatchConnectivityController.shared.send(type: "watch.ackManifest", payload: [
            "episodeHashes": entries.map(\.episodeHash),
            "timestamp": timestamp(),
        ])
        startQueuedDownloads()
    }

    func upsertManifest(entries: [WatchManifestEntry]) {
        WatchDiagnostics.log("manifest-upsert-received", message: "Watch empfaengt Upsert-Manifest", metadata: [
            "entryCount": "\(entries.count)",
        ])
        WatchManifestStore.shared.upsert(entries: entries)
        WatchConnectivityController.shared.send(type: "watch.ackManifest", payload: [
            "episodeHashes": entries.map(\.episodeHash),
            "timestamp": timestamp(),
        ])
        startQueuedDownloads()
    }

    func startQueuedDownloads() {
        reattachDownloadTasks { [weak self] in
            self?.startQueuedDownloadsAfterReattach()
        }
    }

    func startDownload(for episode: WatchEpisode) {
        guard activeTasksByHash[episode.episodeHash] == nil, episode.localFileURL == nil else { return }

        let removed = WatchStorageManager.shared.cleanupIfNeeded(bytesNeeded: episode.expectedBytes, excluding: episode.episodeHash)
        for removedEpisode in removed {
            WatchConnectivityController.shared.send(type: "watch.downloadEvicted", payload: [
                "episodeHash": removedEpisode.episodeHash,
                "timestamp": timestamp(),
            ])
        }

        var request = URLRequest(url: episode.mediaURL)
        request.allowsCellularAccess = true
        var metadata = WatchDiagnostics.metadata(for: episode)
        metadata["freeBytes"] = "\(WatchStorageManager.shared.freeBytes())"
        metadata["expectedBytes"] = "\(episode.expectedBytes)"
        WatchDiagnostics.log("download-start", message: "Watch-Download startet", metadata: metadata)
        let task = session.downloadTask(with: request)
        task.taskDescription = episode.episodeHash
        task.priority = URLSessionTask.defaultPriority
        activeTasksByHash[episode.episodeHash] = task

        WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
            item.status = .downloading
            item.lastError = nil
        }
        WatchConnectivityController.shared.send(type: "watch.downloadQueued", payload: [
            "episodeHash": episode.episodeHash,
            "timestamp": timestamp(),
        ])
        task.resume()
    }

    func prioritizeEpisode(hash: String) {
        if let task = activeTasksByHash[hash] {
            task.priority = URLSessionTask.highPriority
            return
        }
        guard let episode = WatchManifestStore.shared.episode(hash: hash) else { return }
        if episode.status == .failed {
            WatchManifestStore.shared.updateEpisode(hash: hash) { item in
                item.status = .queued
                item.lastError = nil
            }
        }
        startDownload(for: episode)
        activeTasksByHash[hash]?.priority = URLSessionTask.highPriority
    }

    func cancelEpisode(hash: String) {
        activeTasksByHash[hash]?.cancel()
        activeTasksByHash[hash] = nil
        WatchManifestStore.shared.updateEpisode(hash: hash) { item in
            item.status = .queued
        }
    }

    func removeEpisode(hash: String) {
        activeTasksByHash[hash]?.cancel()
        activeTasksByHash[hash] = nil
        guard let episode = WatchManifestStore.shared.removeEpisode(hash: hash) else { return }
        deleteRemovedManifestEpisode(episode)
    }

    private func deleteRemovedManifestEpisode(_ episode: WatchEpisode) {
        if WatchPlayerController.shared.playingEpisodeHash == episode.episodeHash {
            WatchDiagnostics.log("manifest-remove-deferred-playing", message: "Watch-Datei wird wegen laufender Wiedergabe nicht geloescht", metadata: WatchDiagnostics.metadata(for: episode))
            return
        }
        activeTasksByHash[episode.episodeHash]?.cancel()
        activeTasksByHash[episode.episodeHash] = nil
        WatchStorageManager.shared.removeLocalFile(for: episode)
        WatchConnectivityController.shared.send(type: "watch.deleted", payload: [
            "episodeHash": episode.episodeHash,
            "timestamp": timestamp(),
        ])
        WatchConnectivityController.shared.sendStorageStatus()
    }

    func handleBackgroundEvents() async {
        reattachDownloadTasks { [weak self] in
            self?.startQueuedDownloadsAfterReattach()
        }
    }

    private func startQueuedDownloadsAfterReattach() {
        for episode in WatchManifestStore.shared.sortedEpisodes where episode.status == .queued {
            startDownload(for: episode)
        }
        WatchConnectivityController.shared.sendStorageStatus()
    }

    private func reattachDownloadTasks(completion: @escaping @MainActor () -> Void) {
        let currentSession = session
        currentSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                self.reconcileManifestWithDownloadTasks(tasks.compactMap { $0 as? URLSessionDownloadTask })
                completion()
            }
        }
    }

    private func reconcileManifestWithDownloadTasks(_ tasks: [URLSessionDownloadTask]) {
        var taskHashes = Set<String>()
        for task in tasks {
            guard let hash = task.taskDescription, !hash.isEmpty else {
                continue
            }
            guard WatchManifestStore.shared.episode(hash: hash) != nil else {
                task.cancel()
                continue
            }

            taskHashes.insert(hash)
            activeTasksByHash[hash] = task
            WatchManifestStore.shared.updateEpisode(hash: hash) { item in
                if item.localFileURL == nil {
                    item.status = .downloading
                }
            }
            if task.state == .suspended {
                task.resume()
            }
        }

        for episode in WatchManifestStore.shared.episodes {
            if episode.localFileURL != nil, let resolvedURL = WatchStorageManager.shared.resolvedLocalFileURL(for: episode) {
                if resolvedURL != episode.localFileURL {
                    WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                        item.localFileURL = resolvedURL
                    }
                    var metadata = WatchDiagnostics.metadata(for: episode)
                    metadata["resolvedFileName"] = resolvedURL.lastPathComponent
                    metadata["pathRerooted"] = "true"
                    WatchDiagnostics.log("download-reconcile-pathRerooted", message: "Watch-Downloadpfad beim Reconcile normalisiert", metadata: metadata)
                }
            } else if episode.localFileURL != nil {
                var metadata = WatchDiagnostics.metadata(for: episode)
                metadata["localFileMissing"] = "true"
                WatchDiagnostics.log("download-reconcile-localFileMissing", message: "Watch-Datei fehlt beim Reconcile", metadata: metadata)
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
            } else if episode.status == .downloading && !taskHashes.contains(episode.episodeHash) {
                WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                    item.status = .queued
                    item.downloadedBytes = 0
                    item.expectedBytes = 0
                }
            }
        }
    }

    private func downloadedFileAttributes(for fileURL: URL) async -> (size: Int64, duration: Int, isPlayable: Bool) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let asset = AVURLAsset(url: fileURL)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        let durationTime = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(durationTime)
        let duration = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        return (size, duration, isPlayable)
    }

    private func downloadValidationError(for task: URLSessionDownloadTask, fileURL: URL) -> String? {
        let hash = task.taskDescription ?? ""
        if let httpResponse = task.response as? HTTPURLResponse {
            if !(200..<300).contains(httpResponse.statusCode) {
                WatchDiagnostics.log("download-validation-failed", message: "Watch-Download HTTP-Fehler", metadata: [
                    "episodeHash": hash,
                    "httpStatus": "\(httpResponse.statusCode)",
                ])
                return String(format: NSLocalizedString("Download fehlgeschlagen: HTTP %ld.", comment: ""), httpResponse.statusCode)
            }
            if httpResponse.statusCode == 206 {
                WatchDiagnostics.log("download-validation-failed", message: "Watch-Download ist HTTP 206 Partial Content", metadata: [
                    "episodeHash": hash,
                    "httpStatus": "\(httpResponse.statusCode)",
                ])
                return NSLocalizedString("Download unvollständig: HTTP 206 Partial Content.", comment: "")
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 {
            WatchDiagnostics.log("download-validation-failed", message: "Watch-Downloaddatei ist leer", metadata: [
                "episodeHash": hash,
                "actualBytes": "\(size)",
            ])
            return NSLocalizedString("Geladene Datei ist leer.", comment: "")
        }
        let expectedSize = task.countOfBytesExpectedToReceive
        if expectedSize > 0, size < expectedSize {
            WatchDiagnostics.log("download-validation-failed", message: "Watch-Downloaddatei ist unvollstaendig", metadata: [
                "episodeHash": hash,
                "actualBytes": "\(size)",
                "expectedBytes": "\(expectedSize)",
            ])
            return NSLocalizedString("Geladene Datei ist unvollständig.", comment: "")
        }
        return nil
    }

    private func markDownloadFailed(hash: String, error: String) {
        WatchManifestStore.shared.updateEpisode(hash: hash) { item in
            item.status = .failed
            item.lastError = error
        }
        WatchConnectivityController.shared.send(type: "watch.downloadFailed", payload: [
            "episodeHash": hash,
            "error": error,
            "timestamp": timestamp(),
        ])
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

extension WatchDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let hash = downloadTask.taskDescription ?? ""
        let stagedLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstacastWatchDownload-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stagedLocation)
        } catch {
            Task { @MainActor in
                markDownloadFailed(hash: hash, error: error.localizedDescription)
            }
            return
        }

        Task { @MainActor in
            guard let episode = WatchManifestStore.shared.episode(hash: hash) else {
                try? FileManager.default.removeItem(at: stagedLocation)
                return
            }
            if let error = downloadValidationError(for: downloadTask, fileURL: stagedLocation) {
                try? FileManager.default.removeItem(at: stagedLocation)
                markDownloadFailed(hash: hash, error: error)
                return
            }

            let destination = WatchStorageManager.shared.localFileURL(for: episode, temporaryURL: stagedLocation)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: stagedLocation, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: stagedLocation)
                markDownloadFailed(hash: hash, error: error.localizedDescription)
                return
            }

            let attributes = await downloadedFileAttributes(for: destination)
            if attributes.size <= 0 || !attributes.isPlayable {
                try? FileManager.default.removeItem(at: destination)
                WatchDiagnostics.log("download-validation-failed", message: "Watch-Audiodatei ist nicht spielbar", metadata: [
                    "episodeHash": hash,
                    "actualBytes": "\(attributes.size)",
                    "actualDuration": "\(attributes.duration)",
                    "isPlayable": attributes.isPlayable ? "true" : "false",
                ])
                markDownloadFailed(hash: hash, error: NSLocalizedString("Geladene Audiodatei konnte nicht validiert werden.", comment: ""))
                return
            }

            let chapterMetadata = await WatchChapterExtractor.shared.extractChapters(
                from: destination,
                episodeHash: hash,
                artworkDirectory: WatchStorageManager.shared.chapterArtworkDirectory
            )

            WatchManifestStore.shared.updateEpisode(hash: hash) { item in
                item.status = .downloaded
                item.localFileURL = destination
                item.actualFileSize = attributes.size
                item.actualDuration = attributes.duration
                item.downloadedBytes = attributes.size
                item.expectedBytes = attributes.size
                item.lastError = nil
                item.chapters = chapterMetadata.chapters
                item.chapterArtworkBaseURL = chapterMetadata.artworkBaseURL
            }
            WatchDiagnostics.log("download-finished", message: "Watch-Download abgeschlossen", metadata: [
                "episodeHash": hash,
                "actualBytes": "\(attributes.size)",
                "actualDuration": "\(attributes.duration)",
                "isPlayable": attributes.isPlayable ? "true" : "false",
                "fileName": destination.lastPathComponent,
            ])
            WatchConnectivityController.shared.send(type: "watch.downloaded", payload: [
                "episodeHash": hash,
                "actualFileSize": attributes.size,
                "actualDuration": attributes.duration,
                "timestamp": timestamp(),
            ])
            WatchConnectivityController.shared.sendStorageStatus()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let hash = task.taskDescription ?? ""
        Task { @MainActor in
            activeTasksByHash[hash] = nil
            guard let error else { return }
            if (error as NSError).code == NSURLErrorCancelled {
                return
            }
            markDownloadFailed(hash: hash, error: error.localizedDescription)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let hash = downloadTask.taskDescription ?? ""
        Task { @MainActor in
            WatchManifestStore.shared.updateEpisode(hash: hash) { item in
                item.status = .downloading
                item.downloadedBytes = totalBytesWritten
                item.expectedBytes = max(0, totalBytesExpectedToWrite)
            }

            let now = Date()
            if let last = lastProgressReportByHash[hash], now.timeIntervalSince(last) < 2 {
                return
            }
            lastProgressReportByHash[hash] = now
            WatchConnectivityController.shared.send(type: "watch.downloadProgress", payload: [
                "episodeHash": hash,
                "downloadedBytes": totalBytesWritten,
                "expectedBytes": max(0, totalBytesExpectedToWrite),
                "timestamp": timestamp(),
            ], delivery: .live)
        }
    }
}
