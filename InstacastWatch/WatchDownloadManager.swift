import AVFoundation
import Foundation

@MainActor
final class WatchDownloadManager: NSObject, ObservableObject {
    static let shared = WatchDownloadManager()
    static let backgroundSessionIdentifier = "com.iteconomy.instacastplus.watch.downloads"

    private var activeTasksByHash: [String: URLSessionDownloadTask] = [:]
    private var lastProgressReportByHash: [String: Date] = [:]
    private var lastStorageStatusSendDate: Date?
    // Staged files handed from didFinishDownloadingTo to didCompleteWithError (both on the
    // serial URLSession delegate queue, hence the plain lock instead of actor isolation).
    nonisolated(unsafe) private var stagedLocationsByHash: [String: URL] = [:]
    nonisolated(unsafe) private let stagedLocationsLock = NSLock()

    private lazy var session: URLSession = {
#if targetEnvironment(simulator)
        // The watchOS simulator has no working nsurlsessiond for app background sessions —
        // every background download task fails instantly with NSURLError -1 (XPC 4097,
        // "remote session is unavailable"). A default session drives the exact same delegate
        // callbacks, so all validation/storage paths behave identically for simulator tests.
        let configuration = URLSessionConfiguration.default
#else
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
#endif
        configuration.allowsCellularAccess = true
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

        guard let removed = WatchStorageManager.shared.cleanupIfNeeded(bytesNeeded: episode.expectedBytes, excluding: episode.episodeHash) else {
            WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                item.status = .evicted
                item.localFileURL = nil
                item.actualFileSize = 0
                item.downloadedBytes = 0
                item.expectedBytes = max(item.expectedBytes, episode.expectedBytes)
                item.lastError = NSLocalizedString("Nicht genügend Speicher auf der Watch.", comment: "")
            }

            var metadata = WatchDiagnostics.metadata(for: episode)
            metadata["freeBytes"] = "\(WatchStorageManager.shared.freeBytes())"
            metadata["expectedBytes"] = "\(episode.expectedBytes)"
            WatchDiagnostics.log("download-storage-insufficient", message: "Watch-Speicher reicht nicht fuer Download", metadata: metadata)
            sendStorageEviction(hash: episode.episodeHash)
            WatchConnectivityController.shared.sendStorageStatus()
            return
        }
        for removedEpisode in removed {
            sendStorageEviction(hash: removedEpisode.episodeHash)
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
        if episode.status == .failed || episode.status == .evicted {
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
        // Removing an episode freed space — try to backfill the next evicted one that now fits.
        autoFillEvictedEpisodes()
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
        startNextQueuedDownloadIfIdle()
        autoFillEvictedEpisodes()
        WatchConnectivityController.shared.sendStorageStatus()
    }

    // Sequential download policy (User-Entscheid 06.07.): one episode at a time, in playback
    // order. Three parallel downloads competed for the watch's slow radio and none finished —
    // sequential makes the first episode playable as early as possible. A user tap
    // (prioritizeEpisode) still starts immediately and may run alongside the queue download.
    private func startNextQueuedDownloadIfIdle() {
        guard activeTasksByHash.isEmpty else { return }
        guard let next = WatchManifestStore.shared.sortedEpisodes.first(where: { $0.status == .queued && $0.localFileURL == nil }) else { return }
        startDownload(for: next)
    }

    // Keeps the watch as full as possible: pulls storage-evicted episodes back onto the watch when
    // space becomes available. Strictly anti-thrash by construction — it re-downloads ONLY into
    // genuinely free space (file size + the same reserve the rest of the code honors), highest
    // priority first, and NEVER evicts another episode to make room. It runs only while the queue is
    // idle, so it can't race or undo an in-flight download. Episodes whose size is still unknown
    // (expectedBytes == 0, never successfully probed) are left for an explicit tap rather than guessed.
    private func autoFillEvictedEpisodes() {
        guard activeTasksByHash.isEmpty else { return }
        let reserve = WatchStorageManager.minimumReserveBytes
        var projectedFree = WatchStorageManager.shared.freeBytes()
        for episode in WatchManifestStore.shared.sortedEpisodes
        where episode.status == .evicted && episode.localFileURL == nil && episode.expectedBytes > 0 {
            guard projectedFree - episode.expectedBytes >= reserve else { continue }
            projectedFree -= episode.expectedBytes
            WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                item.status = .queued
                item.lastError = nil
            }
            guard let queued = WatchManifestStore.shared.episode(hash: episode.episodeHash) else { continue }
            var metadata = WatchDiagnostics.metadata(for: queued)
            metadata["projectedFreeAfter"] = "\(projectedFree)"
            WatchDiagnostics.log("storage-autofill", message: "Watch laedt evictierte Folge bei freiem Speicher nach", metadata: metadata)
        }
        // Re-queued episodes download one at a time like everything else.
        startNextQueuedDownloadIfIdle()
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

    private func downloadValidationError(for task: URLSessionDownloadTask, fileURL: URL, feedExpectedBytes: Int64) -> String? {
        let hash = task.taskDescription ?? ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if let httpResponse = task.response as? HTTPURLResponse {
            if !(200..<300).contains(httpResponse.statusCode) {
                WatchDiagnostics.log("download-validation-failed", message: "Watch-Download HTTP-Fehler", metadata: [
                    "episodeHash": hash,
                    "httpStatus": "\(httpResponse.statusCode)",
                ])
                return String(format: NSLocalizedString("Download fehlgeschlagen: HTTP %ld.", comment: ""), httpResponse.statusCode)
            }
            if httpResponse.statusCode == 206, !isCompletePartialContentResponse(httpResponse, actualSize: size) {
                WatchDiagnostics.log("download-validation-failed", message: "Watch-Download ist HTTP 206 Partial Content", metadata: [
                    "episodeHash": hash,
                    "httpStatus": "\(httpResponse.statusCode)",
                ])
                return NSLocalizedString("Download unvollständig: HTTP 206 Partial Content.", comment: "")
            }
        }

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
        // A cleanly closed connection without Content-Length looks like a SUCCESSFUL download to
        // URLSession even when only a prefix arrived (proven with megaphone-style mp3 streams:
        // a 120 KB prefix of a 14 MB file passes every check above and AVFoundation's isPlayable,
        // then plays for exactly 7.5 seconds — the customer's "stops after 6-8 seconds"). When the
        // transport declared no size, fall back to the feed's enclosure length: anything below half
        // the declared size is a truncated body, not a complete file.
        if expectedSize <= 0, feedExpectedBytes > 0, size < feedExpectedBytes / 2 {
            WatchDiagnostics.log("download-validation-failed", message: "Watch-Downloaddatei ist deutlich kleiner als im Feed deklariert", metadata: [
                "episodeHash": hash,
                "actualBytes": "\(size)",
                "feedExpectedBytes": "\(feedExpectedBytes)",
            ])
            return NSLocalizedString("Geladene Datei ist unvollständig.", comment: "")
        }
        return nil
    }

    private func isCompletePartialContentResponse(_ response: HTTPURLResponse, actualSize: Int64) -> Bool {
        guard
            actualSize > 0,
            let contentRange = response.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        let components = contentRange.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count == 2, components[0].lowercased() == "bytes" else {
            return false
        }

        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard
            rangeAndTotal.count == 2,
            let totalSize = Int64(rangeAndTotal[1])
        else {
            return false
        }

        // URLSession reassembles the complete file even when the final response is a *resumed*
        // 206 whose Content-Range starts at an offset > 0 — the usual case after a background
        // download is interrupted and continued (the customer's failing downloads showed partial
        // bytes before the 206). The range bounds describe only the last network segment, not the
        // file on disk, so requiring the range to start at byte 0 would reject every resumed
        // download. Completeness is proven by the staged file matching the resource's declared
        // total size; a truncated file has actualSize < totalSize and stays rejected, and the
        // downstream AVURLAsset playability check guards against a same-size-but-corrupt file.
        return totalSize == actualSize
    }

    // Stops a running download that is about to breach the free-space reserve, marks the episode as
    // storage-evicted ("Speicher voll"), and tells the phone so its list/warning stays in sync.
    private func abortDownloadForInsufficientStorage(hash: String, totalBytesExpectedToWrite: Int64) {
        let episode = WatchManifestStore.shared.episode(hash: hash)
        activeTasksByHash[hash]?.cancel()
        activeTasksByHash[hash] = nil
        lastProgressReportByHash[hash] = nil
        WatchManifestStore.shared.updateEpisode(hash: hash) { item in
            item.status = .evicted
            item.localFileURL = nil
            item.actualFileSize = 0
            item.downloadedBytes = 0
            if totalBytesExpectedToWrite > 0 {
                item.expectedBytes = max(item.expectedBytes, totalBytesExpectedToWrite)
            }
            item.lastError = NSLocalizedString("Nicht genügend Speicher auf der Watch.", comment: "")
        }
        var metadata = episode.map { WatchDiagnostics.metadata(for: $0) } ?? ["episodeHash": hash]
        metadata["freeBytes"] = "\(WatchStorageManager.shared.freeBytes())"
        metadata["totalBytesExpected"] = "\(totalBytesExpectedToWrite)"
        WatchDiagnostics.log("download-storage-aborted", message: "Watch-Download wegen Speichermangel abgebrochen", metadata: metadata)
        sendStorageEviction(hash: hash)
        WatchConnectivityController.shared.sendStorageStatus()
    }

    // Single channel for "this episode is storage-evicted / Speicher voll" so the phone applies one
    // consistent status regardless of which path (pre-check, make-room eviction, or live abort) hit it.
    private func sendStorageEviction(hash: String) {
        WatchConnectivityController.shared.send(type: "watch.downloadEvicted", payload: [
            "episodeHash": hash,
            "reason": "storageFull",
            "timestamp": timestamp(),
        ])
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

    // Maps the transport's MIME type to a file extension so AVFoundation can identify the
    // container when the media URL itself carries no extension (tracking redirects).
    nonisolated static func fileExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType = mimeType?.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        switch mimeType {
        case "audio/mpeg", "audio/mp3", "audio/mpeg3":
            return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/mp4a-latm":
            return "m4a"
        case "audio/aac", "audio/x-aac", "audio/aacp":
            return "aac"
        case "audio/ogg", "application/ogg":
            return "ogg"
        case "audio/wav", "audio/x-wav":
            return "wav"
        default:
            return nil
        }
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

        // Only stage here. Validation/registration runs from didCompleteWithError, which the
        // serial delegate queue delivers strictly AFTER this callback: a detached MainActor task
        // started here raced didCompleteWithError's task — the next queued download began while
        // the finished episode was still unregistered (file on disk but not yet an eviction
        // candidate), so a tight-storage start was wrongly refused with "Speicher voll"
        // (proven in the simulator with a 51 MB budget).
        stagedLocationsLock.lock()
        stagedLocationsByHash[hash] = stagedLocation
        stagedLocationsLock.unlock()
    }

    @MainActor
    private func processFinishedDownload(hash: String, stagedLocation: URL, downloadTask: URLSessionDownloadTask) async {
            guard let episode = WatchManifestStore.shared.episode(hash: hash) else {
                try? FileManager.default.removeItem(at: stagedLocation)
                return
            }
            if let error = downloadValidationError(for: downloadTask, fileURL: stagedLocation, feedExpectedBytes: episode.expectedBytes) {
                try? FileManager.default.removeItem(at: stagedLocation)
                markDownloadFailed(hash: hash, error: error)
                return
            }

            let mimeExtension = Self.fileExtension(forMIMEType: downloadTask.response?.mimeType)
            let destination = WatchStorageManager.shared.localFileURL(for: episode, temporaryURL: stagedLocation, fallbackExtension: mimeExtension)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: stagedLocation, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: stagedLocation)
                markDownloadFailed(hash: hash, error: error.localizedDescription)
                return
            }

            let attributes = await downloadedFileAttributes(for: destination)
            // duration <= 0 is a hard failure too: for a file AVFoundation cannot read (random
            // bytes, unknown container) isPlayable still answers an optimistic true while the
            // measured duration collapses to 0 — proven in the watch simulator. A finished
            // podcast download always has a measurable duration.
            if attributes.size <= 0 || !attributes.isPlayable || attributes.duration <= 0 {
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
            // Transport-independent truncation check: a truncated mp3/aac prefix is "playable" for
            // AVFoundation, but its measured duration collapses to the received fraction (120 KB of
            // a 90-minute episode measure as 7.5 s). The feed's duration hint is in the manifest —
            // a file measuring under half of a substantial hint is a truncated body. The 10-minute
            // floor keeps wrong hints on short episodes from rejecting good files.
            if episode.durationHint >= 600, attributes.duration > 0, attributes.duration < episode.durationHint / 2 {
                try? FileManager.default.removeItem(at: destination)
                WatchDiagnostics.log("download-validation-failed", message: "Watch-Audiodatei ist deutlich kuerzer als im Feed deklariert", metadata: [
                    "episodeHash": hash,
                    "actualBytes": "\(attributes.size)",
                    "actualDuration": "\(attributes.duration)",
                    "durationHint": "\(episode.durationHint)",
                ])
                markDownloadFailed(hash: hash, error: NSLocalizedString("Geladene Datei ist unvollständig.", comment: ""))
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

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let hash = task.taskDescription ?? ""
        stagedLocationsLock.lock()
        let stagedLocation = stagedLocationsByHash.removeValue(forKey: hash)
        stagedLocationsLock.unlock()
        let downloadTask = task as? URLSessionDownloadTask

        Task { @MainActor in
            // Success path: validate + register the staged file FIRST, then advance the queue.
            // The episode must be fully registered (localFileURL, .downloaded) before the next
            // download's storage pre-check runs, otherwise it occupies disk space without being
            // an eviction candidate.
            if error == nil, let stagedLocation, let downloadTask {
                await processFinishedDownload(hash: hash, stagedLocation: stagedLocation, downloadTask: downloadTask)
            } else if let stagedLocation {
                try? FileManager.default.removeItem(at: stagedLocation)
            }

            activeTasksByHash[hash] = nil
            if let error, (error as NSError).code != NSURLErrorCancelled {
                let nsError = error as NSError
                WatchDiagnostics.log("download-transport-error", message: "Watch-Download Transportfehler", metadata: [
                    "episodeHash": hash,
                    "errorDomain": nsError.domain,
                    "errorCode": "\(nsError.code)",
                    "errorDescription": nsError.localizedDescription,
                ])
                markDownloadFailed(hash: hash, error: error.localizedDescription)
            }
            // Sequential queue: this download is done (success or failure) — start the next one,
            // then backfill any evicted episodes that fit the freed/leftover space.
            startNextQueuedDownloadIfIdle()
            autoFillEvictedEpisodes()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let hash = downloadTask.taskDescription ?? ""
        Task { @MainActor in
            // A late progress callback after the storage guard aborted (.evicted) or the task failed
            // must not resurrect the episode back to .downloading.
            let currentStatus = WatchManifestStore.shared.episode(hash: hash)?.status
            if currentStatus == .evicted || currentStatus == .failed { return }

            let now = Date()
            if let last = lastProgressReportByHash[hash], now.timeIntervalSince(last) < 2 {
                return
            }
            lastProgressReportByHash[hash] = now

            // Behind the 2 s throttle: updateEpisode persists the whole manifest JSON to disk —
            // running it on EVERY didWriteData callback burned disk writes several times a second.
            WatchManifestStore.shared.updateEpisode(hash: hash) { item in
                item.status = .downloading
                item.downloadedBytes = totalBytesWritten
                // Without Content-Length the transport reports -1. Overwriting with max(0, -1) = 0
                // erased the feed's enclosure size on the FIRST progress callback — which is exactly
                // the value the truncation validation falls back to when the transport declared no
                // size. Keep the feed value unless the transport actually knows better.
                if totalBytesExpectedToWrite > 0 {
                    item.expectedBytes = totalBytesExpectedToWrite
                }
            }

            // Live storage guard: a download whose size the feed never declared (expectedBytes == 0,
            // e.g. megaphone) slips past the pre-download capacity check, which could only reserve the
            // 50 MB floor. If it now threatens that reserve, stop it before the watch is starved —
            // storage pressure is what suspends the app and cuts playback. Runs at the same 2s cadence
            // as the progress report, so it costs one extra volume stat every couple of seconds.
            if WatchStorageManager.shared.freeBytes() < WatchStorageManager.minimumReserveBytes {
                abortDownloadForInsufficientStorage(hash: hash, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
                return
            }

            WatchConnectivityController.shared.send(type: "watch.downloadProgress", payload: [
                "episodeHash": hash,
                "downloadedBytes": totalBytesWritten,
                "expectedBytes": max(0, totalBytesExpectedToWrite),
                "timestamp": timestamp(),
            ], delivery: .live)

            // Keep the storage displays (watch header and iOS storage bar) moving while a
            // download runs — previously the phone only got a storage status after completion.
            if lastStorageStatusSendDate.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                lastStorageStatusSendDate = now
                WatchConnectivityController.shared.sendStorageStatus()
            }
        }
    }
}
