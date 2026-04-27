//
//  TranscriptionQueue.swift
//  Instacast
//
//  Manages the queue of episodes to be transcribed.
//  Sequential processing (one at a time). Persists across app restarts.
//  Automatic resume on app launch. Background processing via BGTasks.
//

import Foundation
import UIKit
import BackgroundTasks

let ICTranscriptionInternalStatusDetailNotification = Notification.Name("ICTranscriptionInternalStatusDetailNotification")

// MARK: - Log Entry

/// One line in the per-episode transcription log. Entries are appended from queue and
/// engine code, persisted to disk, and rendered in TranscriptionLogViewController.
@objc class ICTranscriptionLogEntry: NSObject, @unchecked Sendable {
    @objc let timestamp: Date
    @objc let phase: String        // "queued", "download", "music", "model", "transcribe", "chapters", "done", "error"
    @objc let message: String
    @objc let detailText: String?  // free-form extras: "632 MB", "12 cues", "25.3 s"

    @objc init(timestamp: Date, phase: String, message: String, detailText: String?) {
        self.timestamp = timestamp
        self.phase = phase
        self.message = message
        self.detailText = detailText
    }
}

/// Persistent per-episode log of everything the transcription pipeline did. Flushed to
/// `{hash}_log.json` in the transcript cache directory. Accessible via TranscriptionLogger.shared.
@MainActor
@objc class TranscriptionLogger: NSObject {
    private static let _shared = TranscriptionLogger()
    @objc static var shared: TranscriptionLogger { _shared }

    private var cache: [String: [ICTranscriptionLogEntry]] = [:]

    private struct StoredEntry: Codable {
        let timestamp: Date
        let phase: String
        let message: String
        let detailText: String?
    }

    private func fileURL(for episodeHash: String) -> URL {
        return TranscriptionEngine.shared.transcriptCacheDirectory()
            .appendingPathComponent("\(episodeHash)_log.json")
    }

    @objc func append(episodeHash: String, phase: String, message: String, detailText: String? = nil) {
        let entry = ICTranscriptionLogEntry(timestamp: Date(), phase: phase, message: message, detailText: detailText)
        var entries = load(episodeHash: episodeHash)
        entries.append(entry)
        cache[episodeHash] = entries
        persist(episodeHash: episodeHash)
        NSLog("[TranscriptionLog][%@] %@: %@%@", episodeHash, phase, message, detailText.map { " (\($0))" } ?? "")
        var metadata: [String: String] = [
            "episodeHash": episodeHash,
            "phase": phase,
        ]
        if let detailText, !detailText.isEmpty {
            metadata["detailText"] = detailText
        }
        ICDiagnosticLogger.shared.logEvent("transcription-log", message: message, metadata: metadata as NSDictionary)
    }

    @objc func entries(episodeHash: String) -> [ICTranscriptionLogEntry] {
        return load(episodeHash: episodeHash)
    }

    @objc func clearLog(episodeHash: String) {
        cache.removeValue(forKey: episodeHash)
        try? FileManager.default.removeItem(at: fileURL(for: episodeHash))
        ICDiagnosticLogger.shared.logEvent("transcription-log", message: "Per-Episode-Log entfernt", metadata: [
            "episodeHash": episodeHash,
            "logPath": fileURL(for: episodeHash).path,
        ] as NSDictionary)
    }

    /// Ensure the log for a newly queued episode starts from scratch.
    @objc func resetLog(episodeHash: String) {
        cache[episodeHash] = []
        try? FileManager.default.removeItem(at: fileURL(for: episodeHash))
        ICDiagnosticLogger.shared.logEvent("transcription-log", message: "Per-Episode-Log zurückgesetzt", metadata: [
            "episodeHash": episodeHash,
            "logPath": fileURL(for: episodeHash).path,
        ] as NSDictionary)
    }

    private func load(episodeHash: String) -> [ICTranscriptionLogEntry] {
        if let cached = cache[episodeHash] { return cached }
        guard let data = try? Data(contentsOf: fileURL(for: episodeHash)),
              let stored = try? JSONDecoder().decode([StoredEntry].self, from: data) else {
            return []
        }
        let entries = stored.map { ICTranscriptionLogEntry(timestamp: $0.timestamp, phase: $0.phase, message: $0.message, detailText: $0.detailText) }
        cache[episodeHash] = entries
        return entries
    }

    private func persist(episodeHash: String) {
        guard let entries = cache[episodeHash] else { return }
        let stored = entries.map { StoredEntry(timestamp: $0.timestamp, phase: $0.phase, message: $0.message, detailText: $0.detailText) }
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL(for: episodeHash), options: .atomic)
        }
    }
}

// MARK: - Queue Item

@objc class ICTranscriptionQueueItem: NSObject, @unchecked Sendable {
    @objc let episodeHash: String
    @objc let episodeTitle: String
    @objc let feedTitle: String
    @objc var audioURL: URL?
    @objc let language: String?
    @objc var status: ICTranscriptionStatus
    @objc var progress: Float
    @objc var error: String?
    @objc var statusDetail: String?
    @objc var statusStartedAt: Date?
    @objc var completedAt: Date?
    @objc var chapterOnly = false

    @objc init(episodeHash: String, episodeTitle: String, feedTitle: String,
               audioURL: URL?, language: String?) {
        self.episodeHash = episodeHash
        self.episodeTitle = episodeTitle
        self.feedTitle = feedTitle
        self.audioURL = audioURL
        self.language = language
        self.status = .queued
        self.progress = 0
        self.error = nil
        self.statusDetail = nil
        self.statusStartedAt = nil
        self.completedAt = nil
    }
}

// MARK: - Persisted Queue

private struct PersistedQueue: Codable {
    var items: [PersistedItem]

    struct PersistedItem: Codable {
        let episodeHash: String
        let episodeTitle: String
        let feedTitle: String
        let language: String?
        let statusRawValue: Int?
        let completedAt: Date?
        let chapterOnly: Bool?
        let error: String?
    }
}

// MARK: - TranscriptionQueue

@MainActor
@objc class TranscriptionQueue: NSObject {

    private static let _shared = TranscriptionQueue()
    @objc static var shared: TranscriptionQueue { _shared }
    private static let backgroundTaskEnabledKey = "TranscriptionBackgroundTaskActive"
    private static let continuedGPUBackgroundActiveKey = "TranscriptionBackgroundContinuedGPUActive"
    private static let backgroundExecutionPathKey = "TranscriptionBackgroundExecutionPath"
    private static let completedItemRetentionInterval: TimeInterval = 30 * 60

    @objc private(set) var items: [ICTranscriptionQueueItem] = []
    @objc private(set) var isProcessing = false

    @objc static func supportsContinuedGPUBackgroundProcessing() -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        return BGTaskScheduler.supportedResources.contains(.gpu)
    }

    private var engine: TranscriptionEngine { TranscriptionEngine.shared }
    private var analyzer: AudioAnalyzer { AudioAnalyzer.shared }
    private var chapterGen: ChapterGenerator { ChapterGenerator.shared }

    private var currentTask: Task<Void, Never>?
    private var currentProcessingRunID: UUID?
    private var chapterTask: Task<Void, Never>?  // Tracked separately so cancelAll/dequeue can stop it
    private var pendingDownloadHashes: Set<String> = [] // Tracks episodes being auto-downloaded
    private var backgroundContinuationTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundPausedEpisodeHashes: Set<String> = []
    private var completedPruneScheduled = false

    private func beginProcessingRun() -> UUID {
        let runID = UUID()
        currentProcessingRunID = runID
        return runID
    }

    private func processingRunIsCurrent(_ runID: UUID) -> Bool {
        currentProcessingRunID == runID
    }

    private func clearProcessingRun(_ runID: UUID) {
        if currentProcessingRunID == runID {
            currentProcessingRunID = nil
        }
    }

    private func invalidateProcessingRun() {
        currentProcessingRunID = nil
    }

    // Crash-loop protection: set before model loading, cleared on success/normal failure.
    // If still set on next launch → app was killed during model loading → don't auto-resume.
    private static let crashGuardKey = "TranscriptionQueue_ModelLoadingInProgress"

    override init() {
        super.init()
        loadPersistedQueue()

        // Cancel transcription when episode cache is removed
        NotificationCenter.default.addObserver(forName: NSNotification.Name("CacheManagerDidRemoveCacheNotification"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self,
                  let episode = notification.userInfo?["episode"] as? NSObject,
                  let hash = episode.value(forKey: "objectHash") as? String else { return }
            Task { @MainActor in self.handleEpisodeDeleted(episodeHash: hash) }
        }

        // Single observer for download completion (registered ONCE, not per-download)
        NotificationCenter.default.addObserver(forName: NSNotification.Name("CacheManagerDidEndCachingNotification"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self._handleDownloadCompletion() }
        }

        // Release WhisperKit model on memory warning (frees ~200-600 MB)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if !self.isProcessing {
                    await WhisperKitBackend.shared.releaseModel()
                    NSLog("[TranscriptionQueue] Released WhisperKit model due to memory warning")
                }
            }
        }

        NotificationCenter.default.addObserver(forName: ICTranscriptionInternalStatusDetailNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let episodeHash = note.userInfo?["episodeHash"] as? String,
                  let detail = note.userInfo?["detail"] as? String else { return }
            Task { @MainActor in
                self.updateStatusDetail(for: episodeHash, detail: detail)
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.pauseWhisperKitForBackgroundIfNeeded()
                self?.refreshBackgroundContinuation(reason: "applicationDidEnterBackground")
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBackgroundContinuation(reason: "applicationWillEnterForeground")
                self?.resumeIfNeeded()
            }
        }

        NSLog("[TranscriptionQueue] Initialized. Queue items: %d", items.count)
    }

    // MARK: - Public API

    /// Add an episode to the transcription queue.
    /// Returns false if already queued or already transcribed.
    @objc func enqueue(episodeHash: String, episodeTitle: String, feedTitle: String,
                       audioURL: URL?, language: String?) -> Bool {
        // Don't add if already in queue
        guard !items.contains(where: { $0.episodeHash == episodeHash }) else { return false }

        // Don't add if already transcribed
        guard !engine.hasSRT(for: episodeHash) else { return false }

        if engine.engineType == .whisperKit {
            UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskEnabledKey)
        }

        let item = ICTranscriptionQueueItem(
            episodeHash: episodeHash,
            episodeTitle: episodeTitle,
            feedTitle: feedTitle,
            audioURL: audioURL,
            language: language
        )
        items.append(item)
        persistQueue()
        postQueueChangeNotification()

        // Start a fresh per-episode log so the user sees this run, not the previous one.
        TranscriptionLogger.shared.resetLog(episodeHash: episodeHash)
        let audioSizeDetail: String? = {
            guard let url = audioURL,
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return nil }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }()
        TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "queued",
                                          message: "In Warteschlange aufgenommen",
                                          detailText: audioSizeDetail)
        ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "queued", audioURL: audioURL)

        // Auto-start if not already processing
        if !isProcessing {
            processNext()
        }

        return true
    }

    /// Remove an episode from the queue. Cancels transcription if currently processing.
    @objc func dequeue(episodeHash: String) {
        // If dequeuing the currently processing item, cancel its transcription
        var needsProcessNext = false
        var didCancelCurrent = false
        var shouldCleanupBrokenArtifacts = false
        var cleanupAsChapterArtifacts = false
        if let item = items.first(where: { $0.episodeHash == episodeHash }) {
            shouldCleanupBrokenArtifacts = item.status == .failed || (item.status == .queued && item.error != nil)
            cleanupAsChapterArtifacts = item.chapterOnly || engine.hasSRT(for: item.episodeHash)
            if item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel {
                invalidateProcessingRun()
                currentTask?.cancel()
                currentTask = nil
                engine.cancelTranscription()
                isProcessing = false
                needsProcessNext = true
                didCancelCurrent = true
            } else if item.status == .generatingChapters {
                // Chapter generation can run inside currentTask (auto after transcription)
                // OR in chapterTask (standalone via generateChapters API). Cancel both
                // because we can't tell from here which one owns the active step.
                invalidateProcessingRun()
                currentTask?.cancel()
                currentTask = nil
                chapterTask?.cancel()
                chapterTask = nil
                isProcessing = false
                needsProcessNext = true
                didCancelCurrent = true
            }
        }
        pendingDownloadHashes.remove(episodeHash)
        items.removeAll { $0.episodeHash == episodeHash }
        // If the user explicitly cancelled the active run, drop the crash guard now —
        // the abort was deliberate, not a kill, so we mustn't show "previous run was
        // aborted" on next launch.
        if didCancelCurrent {
            analyzer.cancelAnalysis()
            UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
            refreshBackgroundContinuation(reason: "dequeue-cancelled-active-item")
        }
        if shouldCleanupBrokenArtifacts {
            cleanupBrokenArtifacts(episodeHash: episodeHash, chapterOnly: cleanupAsChapterArtifacts)
        }
        persistQueue()
        postQueueChangeNotification()
        // Defer processNext to avoid modifying items during UIKit row-delete animation
        if needsProcessNext && items.contains(where: { $0.status == .queued }) {
            DispatchQueue.main.async { [weak self] in
                self?.processNext()
            }
        }
    }

    /// Remove all items from the queue and cancel current transcription.
    @objc func cancelAll() {
        invalidateProcessingRun()
        currentTask?.cancel()
        currentTask = nil
        chapterTask?.cancel()
        chapterTask = nil
        engine.cancelTranscription()
        analyzer.cancelAnalysis()
        items.removeAll()
        isProcessing = false
        chapterTask = nil
        // Explicit user cancel — drop the crash guard so the next launch isn't
        // misclassified as crash-recovery.
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
        refreshBackgroundContinuation(reason: "cancelAll")
        persistQueue()
        postQueueChangeNotification()
        releaseModelIfIdle(reason: "cancelAll")
    }

    @objc func enqueueExistingEpisode(episodeHash: String) -> Bool {
        guard let episode = findEpisode(hash: episodeHash) else {
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Episode fuer Transkription nicht gefunden",
                                               metadata: ["episodeHash": episodeHash] as NSDictionary)
            return false
        }
        return enqueue(episodeHash: episodeHash,
                       episodeTitle: episode.title ?? episodeHash,
                       feedTitle: episode.feed?.title ?? "",
                       audioURL: resolveAudioURL(for: episodeHash),
                       language: episode.feed?.language)
    }

    @objc func generateChaptersForExistingEpisode(episodeHash: String) -> Bool {
        guard let episode = findEpisode(hash: episodeHash) else {
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Episode fuer Kapitelerstellung nicht gefunden",
                                               metadata: ["episodeHash": episodeHash] as NSDictionary)
            return false
        }
        guard engine.hasSRT(for: episodeHash) else {
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "SRT fuer Kapitelerstellung fehlt",
                                               metadata: ["episodeHash": episodeHash] as NSDictionary)
            return false
        }
        guard ICDownloadableModelStore.selectedChapterModelIsReady() else {
            TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                              phase: "chapters",
                                              message: "Kapitelerstellung nicht gestartet",
                                              detailText: NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: ""))
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Kapitelmodell fuer Kapitelerstellung nicht bereit",
                                               metadata: [
                                                "episodeHash": episodeHash,
                                                "reason": NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: ""),
                                               ] as NSDictionary)
            return false
        }
        guard ICDownloadableModelStore.selectedChapterModelCanGenerate() else {
            let reason = ICDownloadableModelStore.selectedChapterModelUnavailableReason()
            TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                              phase: "chapters",
                                              message: "Kapitelerstellung nicht gestartet",
                                              detailText: reason)
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Kapitelmodell fuer Kapitelerstellung nicht verfuegbar",
                                               metadata: [
                                                "episodeHash": episodeHash,
                                                "reason": reason,
                                               ] as NSDictionary)
            return false
        }
        return generateChapters(episodeHash: episodeHash,
                                episodeTitle: episode.title ?? episodeHash,
                                feedTitle: episode.feed?.title ?? "")
    }

    @objc func debugQueueSnapshot() -> NSArray {
        let snapshot = items.map { item -> NSDictionary in
            [
                "episodeHash": item.episodeHash,
                "episodeTitle": item.episodeTitle,
                "feedTitle": item.feedTitle,
                "status": item.status.rawValue,
                "statusName": Self.debugStatusName(item.status),
                "progress": item.progress,
                "error": item.error ?? "",
                "statusDetail": item.statusDetail ?? "",
                "statusStartedAt": item.statusStartedAt.map(Self.debugTimestampString) ?? "",
                "completedAt": item.completedAt.map(Self.debugTimestampString) ?? "",
                "chapterOnly": item.chapterOnly,
            ] as NSDictionary
        }
        return snapshot as NSArray
    }

    @objc func debugInspection(episodeHash: String) -> NSDictionary {
        let srtURL = ICTranscriptionPaths.srtURL(for: episodeHash)
        let chaptersURL = ICTranscriptionPaths.chaptersJSONURL(for: episodeHash)
        let musicURL = ICTranscriptionPaths.musicTimelineURL(for: episodeHash)
        let checkpointURL = ICTranscriptionPaths.checkpointURL(for: episodeHash)
        let logURL = TranscriptionEngine.shared.transcriptCacheDirectory()
            .appendingPathComponent("\(episodeHash)_log.json")
        let chapterDebugURL = TranscriptionEngine.shared.transcriptCacheDirectory()
            .appendingPathComponent("\(episodeHash)_chapter_debug.json")
        let chapters = ChapterGenerator.shared.loadChapters(for: episodeHash) ?? []
        let logEntries = TranscriptionLogger.shared.entries(episodeHash: episodeHash).map { entry -> NSDictionary in
            [
                "timestamp": Self.debugTimestampString(entry.timestamp),
                "phase": entry.phase,
                "message": entry.message,
                "detailText": entry.detailText ?? "",
            ] as NSDictionary
        }

        return [
            "episodeHash": episodeHash,
            "queue": debugQueueSnapshot(),
            "artifacts": [
                "srt": Self.debugFileSnapshot(srtURL),
                "chapters": Self.debugFileSnapshot(chaptersURL),
                "music": Self.debugFileSnapshot(musicURL),
                "checkpoint": Self.debugFileSnapshot(checkpointURL),
                "episodeLog": Self.debugFileSnapshot(logURL),
                "chapterDebug": Self.debugFileSnapshot(chapterDebugURL),
            ],
            "chapters": chapters.map { chapter -> NSDictionary in
                [
                    "start": chapter.start,
                    "end": chapter.end,
                    "title": chapter.title,
                    "isSponsor": chapter.isSponsor,
                ] as NSDictionary
            },
            "log": logEntries,
        ] as NSDictionary
    }

    /// Generate chapters for an episode that already has a transcript.
    @objc func generateChapters(episodeHash: String, episodeTitle: String, feedTitle: String) -> Bool {
        guard ICDownloadableModelStore.selectedChapterModelIsReady() else {
            NSLog("[TranscriptionQueue] Cannot generate chapters: chapter model is not downloaded")
            return false
        }

        guard ICDownloadableModelStore.selectedChapterModelCanGenerate() else {
            NSLog("[TranscriptionQueue] Cannot generate chapters: %@", ICDownloadableModelStore.selectedChapterModelUnavailableReason())
            return false
        }

        let activeStatuses: Set<ICTranscriptionStatus> = [.queued, .analyzingMusic, .downloadingModel, .transcribing, .generatingChapters]
        guard !items.contains(where: { $0.episodeHash == episodeHash && activeStatuses.contains($0.status) }) else {
            NSLog("[TranscriptionQueue] Episode %@ already in queue, skipping chapter generation", episodeHash)
            return false
        }
        items.removeAll { $0.episodeHash == episodeHash && ($0.status == .completed || $0.status == .failed) }

        // Load transcript cues from SRT
        let srtURL = TranscriptionEngine.shared.srtURL(for: episodeHash)
        guard FileManager.default.fileExists(atPath: srtURL.path) else {
            NSLog("[TranscriptionQueue] No SRT for %@, chapter generation from RSS not yet supported", episodeHash)
            return false
        }

        // Add to queue with special "chapters only" status
        let item = ICTranscriptionQueueItem(
            episodeHash: episodeHash,
            episodeTitle: episodeTitle,
            feedTitle: feedTitle,
            audioURL: nil,
            language: nil
        )
        item.chapterOnly = true
        items.append(item)
        persistQueue()
        postQueueChangeNotification()

        if !isProcessing && chapterTask == nil && !shouldPauseWhisperKitForBackground {
            startChapterGenerationTask(for: item, srtURL: srtURL, startReason: "chapter-task-enqueued")
        }
        return true
    }

    private func startChapterGenerationTask(for item: ICTranscriptionQueueItem, srtURL: URL, startReason: String) {
        let episodeHash = item.episodeHash
        beginStep(for: item,
                  status: .generatingChapters,
                  detail: NSLocalizedString("Transkript wird für die Kapitel-Erstellung vorbereitet.", comment: ""))
        postQueueChangeNotification()
        refreshBackgroundContinuation(reason: startReason)

        chapterTask = Task {
            await MainActor.run {
                self.postQueueChangeNotification()
                self.refreshBackgroundContinuation(reason: "chapter-task-started")
            }

            // Load cues from SRT file
            let cues = self.loadCuesFromSRT(url: srtURL)
            guard !cues.isEmpty else {
                await MainActor.run {
                    self.chapterTask = nil
                    item.status = .failed
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.error = NSLocalizedString("Transkript konnte nicht geladen werden.", comment: "")
                    self.persistQueue()
                    self.postQueueChangeNotification()
                    self.refreshBackgroundContinuation(reason: "chapter-task-no-cues")
                    self.releaseModelIfIdle(reason: "chapter-task-no-cues")
                }
                return
            }

            // Load cached music timeline if available (no re-analysis needed)
            var musicSegments: [ICAudioSegment]? = nil
            if AudioAnalyzer.shared.hasCachedTimeline(for: episodeHash) {
                // hasCachedTimeline checks the cache, analyze() returns cached result immediately
                // We need a real audio URL for the API, but since cached data exists it won't be used
                if let resolvedURL = self.resolveAudioURL(for: episodeHash) {
                    do {
                        musicSegments = try await AudioAnalyzer.shared.analyzeAsync(audioURL: resolvedURL, episodeHash: episodeHash)
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            await MainActor.run {
                                self.chapterTask = nil
                                self.items.removeAll { $0 === item }
                                self.persistQueue()
                                self.postQueueChangeNotification()
                                self.refreshBackgroundContinuation(reason: "chapter-task-cancelled")
                                self.releaseModelIfIdle(reason: "chapter-task-cancelled")
                            }
                            return
                        }
                        NSLog("[TranscriptionQueue] Cached music timeline load failed: %@", error.localizedDescription)
                        musicSegments = nil
                    }
                }
            }

            NSLog("[TranscriptionQueue] Generating chapters for %@ (%d cues)", episodeHash, cues.count)

            let detailUpdater: (String) -> Void = { detail in
                NotificationCenter.default.post(
                    name: ICTranscriptionInternalStatusDetailNotification,
                    object: nil,
                    userInfo: ["episodeHash": episodeHash, "detail": detail]
                )
            }
            var chapterError: Error? = nil
            let chapters: [ICGeneratedChapter]?
            do {
                chapters = try await self.chapterGen.generateChaptersAsync(
                    fromCues: cues,
                    musicSegments: musicSegments,
                    status: detailUpdater,
                    progress: { [weak self] progress, chunkIndex, totalChunks in
                        item.progress = progress
                        self?.postProgressNotification(episodeHash: episodeHash, progress: progress, status: .generatingChapters)
                    },
                    debugEpisodeHash: episodeHash
                )
            } catch {
                chapterError = error
                chapters = nil
                NSLog("[TranscriptionQueue] Chapter generation error: %@", error.localizedDescription)
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    self.chapterTask = nil
                    self.items.removeAll { $0 === item }
                    self.persistQueue()
                    self.postQueueChangeNotification()
                    self.refreshBackgroundContinuation(reason: "chapter-task-cancelled-after-generation")
                    self.releaseModelIfIdle(reason: "chapter-task-cancelled-after-generation")
                }
                return
            }

            await MainActor.run {
                self.chapterTask = nil
                if let chapters = chapters, !chapters.isEmpty {
                    do {
                        try self.chapterGen.saveChaptersThrowing(chapters, for: episodeHash)
                        item.status = .completed
                        item.progress = 1.0
                        item.statusDetail = nil
                        item.statusStartedAt = nil
                        item.completedAt = Date()
                        NSLog("[TranscriptionQueue] Generated %d chapters", chapters.count)
                    } catch {
                        item.status = .failed
                        item.statusDetail = nil
                        item.statusStartedAt = nil
                        item.error = TranscriptionQueue.detailedErrorMessage(for: error)
                    }
                } else {
                    item.status = .failed
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.error = chapterError.map { TranscriptionQueue.detailedErrorMessage(for: $0) } ?? NSLocalizedString("Kapitelerkennung fehlgeschlagen.", comment: "")
                }
                self.persistQueue()
                self.postQueueChangeNotification()
                self.refreshBackgroundContinuation(reason: "chapter-task-finished")
                NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])
                self.scheduleCompletedItemPrune()
                self.releaseModelIfIdle(reason: "chapter-task-finished")
            }
        }
    }

    /// Parse SRT file into transcript cues
    private func loadCuesFromSRT(url: URL) -> [ICTranscriptCue] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var cues: [ICTranscriptCue] = []
        let blocks = content.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }
            // Line 0: index, Line 1: timestamps, Line 2+: text
            let timeLine = lines[1]
            let parts = timeLine.components(separatedBy: " --> ")
            guard parts.count == 2 else { continue }
            let start = parseSRTTime(parts[0])
            let end = parseSRTTime(parts[1])
            let text = lines[2...].joined(separator: " ")
            cues.append(ICTranscriptCue(start: start, end: end, text: text))
        }
        return cues
    }

    private func parseSRTTime(_ str: String) -> Double {
        // Format: HH:MM:SS,mmm
        let cleaned = str.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3 else { return 0 }
        let hours = Double(parts[0]) ?? 0
        let minutes = Double(parts[1]) ?? 0
        let seconds = Double(parts[2]) ?? 0
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Reorder queue items (for drag & drop in UI).
    @objc func reorderItems(_ newOrder: [ICTranscriptionQueueItem]) {
        items = newOrder
        persistQueue()
    }

    /// Resume processing (called on app launch or foreground).
    @objc func resumeIfNeeded() {
        guard !items.isEmpty else { return }

        if isProcessing && currentTask == nil {
            NSLog("[TranscriptionQueue] Resetting stuck isProcessing flag")
            isProcessing = false
        }

        guard !isProcessing else {
            ICDiagnosticLogger.shared.logEvent("queue", message: "resumeIfNeeded übersprungen (aktiver Lauf lebt noch)", metadata: [
                "queueCount": items.count,
            ] as NSDictionary)
            return
        }
        guard chapterTask == nil else {
            ICDiagnosticLogger.shared.logEvent("queue", message: "resumeIfNeeded übersprungen (Kapitelerstellung läuft)", metadata: [
                "queueCount": items.count,
            ] as NSDictionary)
            return
        }

        if UserDefaults.standard.bool(forKey: TranscriptionQueue.crashGuardKey) {
            if ICDiagnosticLogger.shared.previousSessionEndedUnexpectedly {
                NSLog("[TranscriptionQueue] Crash guard active — last run was killed before completing")
                ICDiagnosticLogger.shared.logEvent("queue", message: "Crash-Guard aktiv", metadata: [
                    "queueCount": items.count,
                    "previousSessionState": ICDiagnosticLogger.shared.previousSessionState ?? "",
                ] as NSDictionary)
                for item in items {
                    if item.status == .queued || item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel || item.status == .generatingChapters {
                        TranscriptionLogger.shared.append(episodeHash: item.episodeHash, phase: "error",
                                                          message: "Vorheriger Durchlauf wurde abgebrochen (App-Beendigung oder Crash)", detailText: nil)
                        item.status = .queued
                        item.progress = 0
                        item.statusDetail = nil
                        item.statusStartedAt = nil
                        item.error = NSLocalizedString("Unterbrochen. Tippe zum Fortsetzen.", comment: "")
                    }
                }
                // Guard stays SET so duplicate resumeIfNeeded calls can't bypass it.
                // Cleared by explicit user retry via retryProcessing().
                postQueueChangeNotification()
                return
            }

            UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
            ICDiagnosticLogger.shared.logEvent("queue", message: "Crash-Guard nach erwartetem Lifecycle-Ende ignoriert", metadata: [
                "queueCount": items.count,
                "previousSessionState": ICDiagnosticLogger.shared.previousSessionState ?? "",
            ] as NSDictionary)
        }

        // Reset any stuck items back to queued
        for item in items {
            if item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel || item.status == .generatingChapters {
                NSLog("[TranscriptionQueue] Resetting stuck item %@ from status %ld to queued", item.episodeHash, item.status.rawValue)
                item.status = .queued
                item.progress = 0
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.error = nil
            }
            if engine.hasCheckpoint(for: item.episodeHash) {
                NSLog("[TranscriptionQueue] Found interrupted transcription for %@, resuming", item.episodeHash)
                item.status = .queued
            }
        }

        processNext()
    }

    /// Manual retry from queue UI. Clears crash guard and starts processing.
    @objc func retryProcessing() {
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
        guard !isProcessing else { return }
        for item in items where item.status == .queued {
            item.error = nil
            item.statusDetail = nil
            item.statusStartedAt = nil
            engine.resetCheckpointFailureCounter(for: item.episodeHash)
        }
        processNext()
    }

    @objc func retry(episodeHash: String) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash }) else { return }
        guard item.status == .failed || item.status == .queued else { return }

        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
        backgroundPausedEpisodeHashes.remove(episodeHash)
        cleanupBrokenArtifacts(for: item)
        engine.resetCheckpointFailureCounter(for: episodeHash)
        if item.chapterOnly || engine.hasSRT(for: episodeHash) {
            item.chapterOnly = true
            item.audioURL = nil
        } else {
            item.chapterOnly = false
        }
        item.status = .queued
        item.progress = 0
        item.error = nil
        item.statusDetail = nil
        item.statusStartedAt = nil
        item.completedAt = nil
        persistQueue()
        postQueueChangeNotification()

        if !isProcessing {
            processNext()
        }
    }

    private func cleanupBrokenArtifacts(for item: ICTranscriptionQueueItem) {
        cleanupBrokenArtifacts(episodeHash: item.episodeHash,
                               chapterOnly: item.chapterOnly || engine.hasSRT(for: item.episodeHash))
    }

    private func cleanupBrokenArtifacts(episodeHash: String) {
        cleanupBrokenArtifacts(episodeHash: episodeHash,
                               chapterOnly: engine.hasSRT(for: episodeHash))
    }

    private func cleanupBrokenArtifacts(episodeHash: String, chapterOnly: Bool) {
        if chapterOnly {
            ChapterGenerator.shared.removeGeneratedChapters(forEpisodeHash: episodeHash)
            return
        }
        engine.removeSRT(for: episodeHash)
    }

    /// Number of items currently queued (including active)
    @objc var count: Int { items.count }

    @objc var activeItemCount: Int {
        items.filter { $0.status != .completed && $0.status != .failed }.count
    }

    @objc(modelMutationBlockReasonForRole:)
    func modelMutationBlockReason(for role: ICDownloadableModelRole) -> String? {
        let blocksRole = items.contains { item in
            guard item.status != .completed && item.status != .failed else { return false }
            switch role {
            case .voiceToText:
                return !item.chapterOnly && (
                    item.status == .queued ||
                    item.status == .analyzingMusic ||
                    item.status == .downloadingModel ||
                    item.status == .transcribing
                )
            case .textToChapters:
                return item.chapterOnly ||
                    item.status == .queued ||
                    item.status == .analyzingMusic ||
                    item.status == .downloadingModel ||
                    item.status == .transcribing ||
                    item.status == .generatingChapters
            @unknown default:
                return false
            }
        }
        guard blocksRole else { return nil }
        return NSLocalizedString("Ein laufender Transkriptions- oder Kapitel-Job verwendet diesen Modellbereich. Beende oder brich den Job ab, bevor du das Modell änderst.", comment: "")
    }

    @objc(modelDeletionBlockReasonForModel:)
    func modelDeletionBlockReason(for model: ICDownloadableModel) -> String? {
        guard model.requiresDownload else { return nil }
        return modelMutationBlockReason(for: model.role)
    }

    @objc var hasVisibleItems: Bool {
        pruneExpiredCompletedItems()
        return !items.isEmpty
    }

    /// Currently processing item
    @objc var currentItem: ICTranscriptionQueueItem? {
        items.first { $0.status != .completed && $0.status != .failed && $0.status != .queued }
            ?? items.first { $0.status == .queued }
    }

    private var backgroundProcessingEnabled: Bool {
        UserDefaults.standard.bool(forKey: TranscriptionQueue.backgroundTaskEnabledKey)
    }

    private var continuedGPUBackgroundActive: Bool {
        UserDefaults.standard.bool(forKey: TranscriptionQueue.continuedGPUBackgroundActiveKey)
    }

    private var hasLifecycleManagedWork: Bool {
        isProcessing || chapterTask != nil
    }

    private func refreshBackgroundContinuation(reason: String) {
        let shouldContinueInBackground = backgroundProcessingEnabled &&
            hasLifecycleManagedWork &&
            engine.engineType != .whisperKit &&
            UIApplication.shared.applicationState == .background

        if shouldContinueInBackground {
            beginBackgroundContinuationIfNeeded(reason: reason)
        } else {
            endBackgroundContinuationIfNeeded(reason: reason)
        }
    }

    private func beginBackgroundContinuationIfNeeded(reason: String) {
        guard backgroundContinuationTask == .invalid else { return }

        let taskID = UIApplication.shared.beginBackgroundTask(withName: "InstacastPlus.TranscriptionQueue") { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundzeit abgelaufen", metadata: [
                    "reason": reason,
                    "queueCount": self.items.count,
                ] as NSDictionary)
                self.endBackgroundContinuationIfNeeded(reason: "expired")
            }
        }

        guard taskID != .invalid else {
            ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundtask konnte nicht gestartet werden", metadata: [
                "reason": reason,
                "queueCount": items.count,
            ] as NSDictionary)
            return
        }

        backgroundContinuationTask = taskID
        ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundtask gestartet", metadata: [
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    private func endBackgroundContinuationIfNeeded(reason: String) {
        guard backgroundContinuationTask != .invalid else { return }
        let taskID = backgroundContinuationTask
        backgroundContinuationTask = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundtask beendet", metadata: [
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    private func releaseModelIfIdle(reason: String) {
        guard engine.engineType == .whisperKit else { return }
        guard !hasLifecycleManagedWork else { return }
        guard !items.contains(where: {
            $0.status == .queued ||
            $0.status == .analyzingMusic ||
            $0.status == .downloadingModel ||
            $0.status == .transcribing ||
            $0.status == .generatingChapters
        }) else { return }

        let queueCount = items.count
        Task {
            await WhisperKitBackend.shared.releaseModel()
            ICDiagnosticLogger.shared.logEvent("model", message: "Whisper-Modell wegen Idle-Queue freigegeben", metadata: [
                "reason": reason,
                "queueCount": queueCount,
            ] as NSDictionary)
        }
    }

    @discardableResult
    private func pruneExpiredCompletedItems(now: Date = Date()) -> Bool {
        let beforeCount = items.count
        items.removeAll { item in
            guard item.status == .completed else { return false }
            guard let completedAt = item.completedAt else { return true }
            return now.timeIntervalSince(completedAt) >= Self.completedItemRetentionInterval
        }
        return items.count != beforeCount
    }

    private func scheduleCompletedItemPrune() {
        guard !completedPruneScheduled else { return }
        completedPruneScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completedItemRetentionInterval) { [weak self] in
            guard let self = self else { return }
            self.completedPruneScheduled = false
            if self.pruneExpiredCompletedItems() {
                self.persistQueue()
                self.postQueueChangeNotification()
                self.releaseModelIfIdle(reason: "completed-item-pruned")
            }
            if self.items.contains(where: { $0.status == .completed }) {
                self.scheduleCompletedItemPrune()
            }
        }
    }

    @discardableResult
    private func pauseWhisperKitForBackgroundIfNeeded() -> Bool {
        return pauseWhisperKitForBackgroundIfNeeded(reason: "applicationDidEnterBackground")
    }

    @discardableResult
    private func pauseWhisperKitForBackgroundIfNeeded(reason: String) -> Bool {
        guard shouldPauseWhisperKitForBackground else { return false }
        guard isProcessing else { return false }
        guard let item = items.first(where: {
            $0.status == .analyzingMusic ||
            $0.status == .downloadingModel ||
            $0.status == .transcribing
        }) else { return false }

        let task = currentTask
        finishBackgroundPause(for: item, reason: reason)
        task?.cancel()
        analyzer.cancelAnalysis()
        engine.cancelTranscription()
        return true
    }

    private var shouldPauseWhisperKitForBackground: Bool {
        engine.engineType == .whisperKit &&
            UIApplication.shared.applicationState == .background &&
            !continuedGPUBackgroundActive
    }

    @objc(activateBackgroundExecutionPathWithPath:detail:)
    func activateBackgroundExecutionPath(path: String, detail: String) {
        UserDefaults.standard.set(true, forKey: TranscriptionQueue.backgroundTaskEnabledKey)
        UserDefaults.standard.set(path, forKey: TranscriptionQueue.backgroundExecutionPathKey)
        UserDefaults.standard.set(path == "continued-gpu", forKey: TranscriptionQueue.continuedGPUBackgroundActiveKey)

        let activeItems = items.filter {
            $0.status == .queued ||
            $0.status == .analyzingMusic ||
            $0.status == .downloadingModel ||
            $0.status == .transcribing ||
            $0.status == .generatingChapters
        }
        for item in activeItems {
            TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                              phase: "background",
                                              message: "Hintergrundpfad aktiviert",
                                              detailText: "\(path): \(detail)")
        }

        ICDiagnosticLogger.shared.logEvent("background-task", message: "Hintergrundpfad aktiviert", metadata: [
            "path": path,
            "detail": detail,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    @objc(completeBackgroundExecutionPathWithSuccess:reason:)
    func completeBackgroundExecutionPath(success: Bool, reason: String) {
        let path = UserDefaults.standard.string(forKey: TranscriptionQueue.backgroundExecutionPathKey) ?? "unknown"
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.continuedGPUBackgroundActiveKey)
        if !success {
            UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskEnabledKey)
        }
        ICDiagnosticLogger.shared.logEvent("background-task", message: "Hintergrundpfad beendet", metadata: [
            "path": path,
            "reason": reason,
            "success": success,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    @objc(deactivateBackgroundExecutionPathWithReason:)
    func deactivateBackgroundExecutionPath(reason: String) {
        let path = UserDefaults.standard.string(forKey: TranscriptionQueue.backgroundExecutionPathKey) ?? "unknown"
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskEnabledKey)
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.continuedGPUBackgroundActiveKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionQueue.backgroundExecutionPathKey)
        ICDiagnosticLogger.shared.logEvent("background-task", message: "Hintergrundpfad deaktiviert", metadata: [
            "path": path,
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    @objc(expireContinuedGPUBackgroundExecutionWithReason:)
    func expireContinuedGPUBackgroundExecution(reason: String) {
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.continuedGPUBackgroundActiveKey)
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskEnabledKey)
        ICDiagnosticLogger.shared.logEvent("background-task", message: "BGContinuedProcessingTask abgelaufen", metadata: [
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
        _ = pauseWhisperKitForBackgroundIfNeeded(reason: reason)
    }

    private func finishBackgroundPause(for item: ICTranscriptionQueueItem, reason: String, error: Error? = nil) {
        backgroundPausedEpisodeHashes.insert(item.episodeHash)
        item.status = .queued
        item.progress = 0
        item.statusDetail = nil
        item.statusStartedAt = nil
        item.error = NSLocalizedString("Transkription im Hintergrund pausiert. Wird beim Zurückkehren automatisch fortgesetzt.", comment: "")
        invalidateProcessingRun()
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskEnabledKey)
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.continuedGPUBackgroundActiveKey)
        isProcessing = false
        currentTask = nil
        refreshBackgroundContinuation(reason: reason)
        persistQueue()
        postQueueChangeNotification()

        TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                          phase: "error",
                                          message: "Transkription im Hintergrund pausiert",
                                          detailText: error.map { TranscriptionQueue.detailedErrorMessage(for: $0) })
        ICDiagnosticLogger.shared.logEvent("queue", message: "Transkription im Hintergrund pausiert", metadata: [
            "episodeHash": item.episodeHash,
            "reason": reason,
        ] as NSDictionary)
    }

    // MARK: - Processing

    private func processNext() {
        guard !isProcessing else { return }
        guard currentProcessingRunID == nil else { return }
        guard chapterTask == nil else { return }
        guard !shouldPauseWhisperKitForBackground else { return }

        // Iteratively skip failed items (no recursion, no stack growth)
        var item: ICTranscriptionQueueItem?
        var resolvedAudioURL: URL?

        while true {
            // Find next queued item
            guard let candidate = items.first(where: { $0.status == .queued }) else {
                let didPrune = pruneExpiredCompletedItems()
                persistQueue()
                if didPrune {
                    postQueueChangeNotification()
                }
                refreshBackgroundContinuation(reason: "queue-idle")
                releaseModelIfIdle(reason: "queue-idle")
                return
            }

            if candidate.chapterOnly {
                let srtURL = TranscriptionEngine.shared.srtURL(for: candidate.episodeHash)
                guard FileManager.default.fileExists(atPath: srtURL.path) else {
                    candidate.status = .failed
                    candidate.statusDetail = nil
                    candidate.statusStartedAt = nil
                    candidate.error = NSLocalizedString("Transkript konnte nicht geladen werden.", comment: "")
                    persistQueue()
                    postQueueChangeNotification()
                    continue
                }
                guard ICDownloadableModelStore.selectedChapterModelIsReady(),
                      ICDownloadableModelStore.selectedChapterModelCanGenerate() else {
                    candidate.status = .failed
                    candidate.statusDetail = nil
                    candidate.statusStartedAt = nil
                    candidate.error = ICDownloadableModelStore.selectedChapterModelUnavailableReason()
                    persistQueue()
                    postQueueChangeNotification()
                    continue
                }
                startChapterGenerationTask(for: candidate, srtURL: srtURL, startReason: "chapter-task-resumed")
                return
            }

            // Resolve audio URL
            if let url = candidate.audioURL, FileManager.default.fileExists(atPath: url.path) {
                resolvedAudioURL = url
            } else if let resolved = resolveAudioURL(for: candidate.episodeHash) {
                resolvedAudioURL = resolved
                candidate.audioURL = resolved
            } else {
                // Audio not available — try auto-downloading
                NSLog("[TranscriptionQueue] Audio not cached for %@, attempting auto-download", candidate.episodeHash)
                if autoDownloadEpisode(hash: candidate.episodeHash) {
                    candidate.statusDetail = NSLocalizedString("Automatischer Download wurde gestartet.", comment: "")
                    candidate.error = NSLocalizedString("Episode wird heruntergeladen...", comment: "")
                    TranscriptionLogger.shared.append(episodeHash: candidate.episodeHash, phase: "download",
                                                      message: "Automatischer Download gestartet", detailText: nil)
                    postQueueChangeNotification()
                    return // Will resume in _handleDownloadCompletion
                }
                candidate.status = .failed
                candidate.statusDetail = nil
                candidate.statusStartedAt = nil
                candidate.error = NSLocalizedString("Audiodatei nicht verfügbar.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // Check failure counter for OOM loop protection
            if let failures = loadCheckpointFailures(for: candidate.episodeHash), failures >= 6 {
                candidate.status = .failed
                candidate.statusDetail = nil
                candidate.statusStartedAt = nil
                candidate.error = NSLocalizedString("Transkription auf diesem Gerät nicht möglich.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // Check if WhisperKit model is downloaded
            if engine.engineType == .whisperKit && !WhisperKitBackend.shared.isModelDownloadedSync() {
                candidate.status = .failed
                candidate.statusDetail = nil
                candidate.statusStartedAt = nil
                candidate.error = NSLocalizedString("Sprachmodell nicht installiert. Bitte in Einstellungen > Transkription herunterladen.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // All checks passed — process this item
            item = candidate
            break
        }

        guard let item = item, let audioURL = resolvedAudioURL else { return }

        backgroundPausedEpisodeHashes.remove(item.episodeHash)
        isProcessing = true
        refreshBackgroundContinuation(reason: "pipeline-started")
        let episodeHash = item.episodeHash
        let detailUpdater: @Sendable (String) -> Void = { detail in
            NotificationCenter.default.post(
                name: ICTranscriptionInternalStatusDetailNotification,
                object: nil,
                userInfo: ["episodeHash": episodeHash, "detail": detail]
            )
        }

        // Crash-loop protection covers the whole pipeline. If the app is killed any time
        // between here and the final cleanup block, the next launch sees the flag still
        // set, marks the items as interrupted, and refuses to auto-resume — the user
        // must explicitly tap to retry.
        UserDefaults.standard.set(true, forKey: TranscriptionQueue.crashGuardKey)

        let runID = beginProcessingRun()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline gestartet", metadata: [
                "episodeHash": episodeHash,
                "episodeTitle": item.episodeTitle,
                "feedTitle": item.feedTitle,
                "audioPath": audioURL.path,
            ] as NSDictionary)
            ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "pipeline-start", audioURL: audioURL)

            // Step 1: Music Analysis (SoundAnalysis, < 1 min)
            await MainActor.run {
                self.beginStep(for: item,
                               status: .analyzingMusic,
                               detail: NSLocalizedString("Erkenne Musik, Sprache und Stille für spätere Kapitelgrenzen.", comment: ""))
                self.postQueueChangeNotification()
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "music",
                                                  message: "Audioanalyse gestartet (SoundAnalysis)", detailText: nil)
            }

            let musicStart = Date()
            let musicSegments: [ICAudioSegment]?
            do {
                musicSegments = try await self.analyzer.analyzeAsync(audioURL: audioURL, episodeHash: episodeHash)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        self.clearProcessingRun(runID)
                        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-cancelled-during-audio-analysis")
                        self.postQueueChangeNotification()
                        self.processNext()
                    }
                    ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline abgebrochen während Audioanalyse", metadata: [
                        "episodeHash": episodeHash,
                    ] as NSDictionary)
                    return
                }
                NSLog("[TranscriptionQueue] Music analysis error: %@", error.localizedDescription)
                musicSegments = nil
            }
            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                let elapsed = -musicStart.timeIntervalSinceNow
                let musicCount = (musicSegments ?? []).filter { $0.type == "music" }.count
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "music",
                                                  message: "Audioanalyse abgeschlossen",
                                                  detailText: String(format: "%.1f s, %d Musiksegmente", elapsed, musicCount))
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    self.clearProcessingRun(runID)
                    UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                    self.isProcessing = false
                    self.refreshBackgroundContinuation(reason: "pipeline-cancelled-after-audio-analysis")
                    self.processNext()
                }
                return
            }

            let pausedBeforeModelLoad = await MainActor.run { () -> Bool in
                guard self.processingRunIsCurrent(runID) else { return true }
                guard self.shouldPauseWhisperKitForBackground else { return false }
                self.finishBackgroundPause(for: item, reason: "pipeline-background-before-model-load")
                return true
            }
            if pausedBeforeModelLoad {
                return
            }

            // Step 2: Pre-load WhisperKit model at low priority (utility QoS).
            // Model loading is CPU-heavy (CoreML) and must not compete with UI work.
            // Task.detached ensures it runs off MainActor at lower priority.
            if self.engine.engineType == .whisperKit {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    self.beginStep(for: item,
                                   status: .downloadingModel,
                                   detail: NSLocalizedString("Modell wird vorbereitet.", comment: ""))
                    self.postQueueChangeNotification()
                    let sizeBytes = WhisperKitBackend.shared.modelSizeOnDiskSync()
                    let sizeDetail = sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : nil
                    TranscriptionLogger.shared.append(
                        episodeHash: episodeHash, phase: "model",
                        message: "WhisperKit-Modell wird geladen (\(TranscriptionEngine.resolvedModelName()))",
                        detailText: sizeDetail)
                }

                let modelStart = Date()
                do {
                    try await Task.detached(priority: .utility) {
                        try await WhisperKitBackend.shared.prepareModel(statusUpdate: detailUpdater)
                    }.value
                } catch {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        if TranscriptionEngine.isBackgroundGPUExecutionError(error) {
                            self.finishBackgroundPause(for: item, reason: "model-load-background-gpu-error", error: error)
                            return
                        }
                        let errMsg = TranscriptionQueue.detailedErrorMessage(for: error)
                        TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                          message: "Modell-Ladefehler", detailText: errMsg)
                        item.status = .failed
                        item.statusDetail = nil
                        item.statusStartedAt = nil
                        item.error = errMsg
                        // Normal error path — the pipeline terminates cleanly so clear the guard.
                        self.clearProcessingRun(runID)
                        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-model-load-failed")
                        self.postQueueChangeNotification()
                        self.processNext()
                    }
                    return
                }

                guard await MainActor.run(body: { self.processingRunIsCurrent(runID) }) else { return }
                await MainActor.run {
                    let elapsed = -modelStart.timeIntervalSinceNow
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "model",
                                                      message: "Modell geladen",
                                                      detailText: String(format: "%.1f s", elapsed))
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        self.clearProcessingRun(runID)
                        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-cancelled-during-model-load")
                        self.processNext()
                    }
                    ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline abgebrochen während Modell-Load", metadata: [
                        "episodeHash": episodeHash,
                    ] as NSDictionary)
                    return
                }
            }

            let pausedBeforeTranscription = await MainActor.run { () -> Bool in
                guard self.processingRunIsCurrent(runID) else { return true }
                guard self.shouldPauseWhisperKitForBackground else { return false }
                self.finishBackgroundPause(for: item, reason: "pipeline-background-before-transcription")
                return true
            }
            if pausedBeforeTranscription {
                return
            }

            // Step 3: Transcription — model is already in memory, this starts immediately
            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                self.beginStep(for: item,
                               status: .transcribing,
                               detail: NSLocalizedString("Warte auf das erste erkannte Transkriptsegment.", comment: ""))
                self.postQueueChangeNotification()
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "transcribe",
                                                  message: "Transkription gestartet", detailText: nil)
            }
            let transcribeStart = Date()

            let transcriptionOutcome = await withCheckedContinuation { (continuation: CheckedContinuation<(cues: [ICTranscriptCue]?, error: Error?), Never>) in
                self.engine.transcribe(
                    audioURL: audioURL,
                    episodeHash: episodeHash,
                    language: item.language,
                    statusDetail: detailUpdater,
                    progress: { [weak self] progress, status in
                        NSLog("[TranscriptionQueue] Progress received: %.1f%% status=%ld", progress * 100, status.rawValue)
                        DispatchQueue.main.async {
                            guard self?.processingRunIsCurrent(runID) == true else { return }
                            item.progress = progress
                            item.status = status
                            self?.postProgressNotification(episodeHash: episodeHash, progress: progress, status: status)
                        }
                    },
                    completion: { cues, error in
                        if let error = error {
                            NSLog("[TranscriptionQueue] Transcription error: %@", error.localizedDescription)
                        }
                        continuation.resume(returning: (cues, error))
                    }
                )
            }

            guard await MainActor.run(body: { self.processingRunIsCurrent(runID) }) else {
                await MainActor.run {
                    _ = self.backgroundPausedEpisodeHashes.remove(episodeHash)
                }
                return
            }
            if let error = transcriptionOutcome.error {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    if TranscriptionEngine.isBackgroundGPUExecutionError(error) {
                        self.finishBackgroundPause(for: item, reason: "transcription-background-gpu-error", error: error)
                        return
                    }
                    if self.backgroundPausedEpisodeHashes.remove(episodeHash) != nil {
                        self.clearProcessingRun(runID)
                        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                        self.isProcessing = false
                        self.currentTask = nil
                        self.refreshBackgroundContinuation(reason: "pipeline-background-paused")
                        self.postQueueChangeNotification()
                        return
                    }

                    let errMsg = TranscriptionQueue.detailedErrorMessage(for: error)
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                      message: "Transkriptions-Fehler", detailText: errMsg)
                    item.status = .failed
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.error = errMsg
                    self.clearProcessingRun(runID)
                    UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                    self.isProcessing = false
                    self.currentTask = nil
                    self.refreshBackgroundContinuation(reason: "pipeline-transcription-error")
                    self.postQueueChangeNotification()
                    self.processNext()
                }
                return
            }

            guard let transcriptCues = transcriptionOutcome.cues, !Task.isCancelled else {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    if self.backgroundPausedEpisodeHashes.remove(episodeHash) != nil {
                        self.clearProcessingRun(runID)
                        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                        self.isProcessing = false
                        self.currentTask = nil
                        self.refreshBackgroundContinuation(reason: "pipeline-background-paused")
                        self.postQueueChangeNotification()
                        return
                    }
                    if item.status != .failed {
                        item.status = .failed
                        item.statusDetail = nil
                        item.statusStartedAt = nil
                        item.error = NSLocalizedString("Transkription fehlgeschlagen.", comment: "")
                    }
                    // Normal error/cancel path — pipeline terminated cleanly.
                    self.clearProcessingRun(runID)
                    UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                    self.isProcessing = false
                    self.refreshBackgroundContinuation(reason: "pipeline-transcription-failed")
                    self.postQueueChangeNotification()
                    self.processNext()
                }
                return
            }

            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                let elapsed = -transcribeStart.timeIntervalSinceNow
                let charCount = transcriptCues.reduce(0) { $0 + $1.text.count }
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "transcribe",
                                                  message: "Transkription abgeschlossen",
                                                  detailText: String(format: "%.1f s, %d Segmente, %d Zeichen",
                                                                     elapsed, transcriptCues.count, charCount))
            }

            // Step 4: Chapter Generation (Foundation Models, ~10-30 sec)
            // Auto-generate chapters if:
            // - Apple Intelligence is available
            // - Episode doesn't already have podcast-provided chapters
            let shouldGenerateChapters: Bool
            if !ICDownloadableModelStore.selectedChapterModelIsReady() {
                shouldGenerateChapters = false
                NSLog("[TranscriptionQueue] Chapter model is not downloaded")
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: "Kapitelerstellung übersprungen",
                                                      detailText: NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: ""))
                }
            } else if ICDownloadableModelStore.selectedChapterModelCanGenerate() {
                // Check if episode has existing chapters from the podcast
                if let episode = self.findEpisode(hash: episodeHash) {
                    let hasExistingChapters = (episode.chapters?.count ?? 0) > 0
                    shouldGenerateChapters = !hasExistingChapters
                    if hasExistingChapters {
                        NSLog("[TranscriptionQueue] Episode has %d existing chapters, skipping generation", episode.chapters?.count ?? 0)
                        await MainActor.run {
                            guard self.processingRunIsCurrent(runID) else { return }
                            TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                              message: "Kapitelerstellung übersprungen",
                                                              detailText: NSLocalizedString("Folge hat bereits Kapitel.", comment: ""))
                        }
                    }
                } else {
                    shouldGenerateChapters = true
                }
            } else {
                shouldGenerateChapters = false
                NSLog("[TranscriptionQueue] ChapterGenerator not available: %@", ICDownloadableModelStore.selectedChapterModelUnavailableReason())
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: "Kapitelerstellung übersprungen",
                                                      detailText: ICDownloadableModelStore.selectedChapterModelUnavailableReason())
                }
            }

            var chapterGenerationError: Error?

            if shouldGenerateChapters {
                await WhisperKitBackend.shared.releaseModel()
                ICDiagnosticLogger.shared.logEvent("model",
                                                   message: "Whisper-Modell vor Kapitelerstellung freigegeben",
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "reason": "before-chapter-generation",
                                                   ] as NSDictionary)
                let musicCount = (musicSegments ?? []).filter { $0.type == "music" }.count
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    self.beginStep(for: item,
                                   status: .generatingChapters,
                                   detail: NSLocalizedString("Transkript wird für die Kapitel-Erstellung vorbereitet.", comment: ""))
                    self.postQueueChangeNotification()
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: "Kapitelerstellung gestartet",
                                                      detailText: "\(transcriptCues.count) Cues, \(musicCount) Musiksegmente")
                }
                NSLog("[TranscriptionQueue] Generating chapters from %d cues + %d music segments",
                      transcriptCues.count, musicCount)

                let chapterStart = Date()
                let chapters: [ICGeneratedChapter]?
                do {
                    chapters = try await self.chapterGen.generateChaptersAsync(
                        fromCues: transcriptCues,
                        musicSegments: musicSegments,
                        status: detailUpdater,
                        progress: { [weak self] progress, chunkIndex, totalChunks in
                            guard self?.processingRunIsCurrent(runID) == true else { return }
                            item.progress = progress
                            self?.postProgressNotification(episodeHash: episodeHash, progress: progress, status: .generatingChapters)
                        },
                        debugEpisodeHash: episodeHash
                    )
                    NSLog("[TranscriptionQueue] Generated %d chapters", chapters?.count ?? 0)
                } catch {
                    chapters = nil
                    if error is CancellationError || Task.isCancelled {
                        await MainActor.run {
                            guard self.processingRunIsCurrent(runID) else { return }
                            self.clearProcessingRun(runID)
                            UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                            self.isProcessing = false
                            self.refreshBackgroundContinuation(reason: "pipeline-cancelled-during-chapter-generation")
                            self.postQueueChangeNotification()
                            self.processNext()
                        }
                        ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline abgebrochen während Kapitelerstellung", metadata: [
                            "episodeHash": episodeHash,
                        ] as NSDictionary)
                        return
                    }
                    chapterGenerationError = error
                    NSLog("[TranscriptionQueue] Chapter generation error: %@", error.localizedDescription)
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                          message: "Kapitelerstellung fehlgeschlagen",
                                                          detailText: TranscriptionQueue.detailedErrorMessage(for: error))
                    }
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        self.clearProcessingRun(runID)
                        UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-cancelled-after-chapter-generation")
                        self.postQueueChangeNotification()
                        self.processNext()
                    }
                    return
                }

                var savedChapters: [ICGeneratedChapter] = []
                if let chapters = chapters, !chapters.isEmpty {
                    do {
                        try self.chapterGen.saveChaptersThrowing(chapters, for: episodeHash)
                        savedChapters = chapters
                        NSLog("[TranscriptionQueue] Saved %d chapters for %@", chapters.count, episodeHash)
                    } catch {
                        chapterGenerationError = error
                        await MainActor.run {
                            guard self.processingRunIsCurrent(runID) else { return }
                            TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                              message: "Kapitel konnten nicht gespeichert werden",
                                                              detailText: TranscriptionQueue.detailedErrorMessage(for: error))
                        }
                    }
                }
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    let elapsed = -chapterStart.timeIntervalSinceNow
                    let count = savedChapters.count
                    let sponsors = savedChapters.filter { $0.isSponsor }.count
                    let message: String
                    if count > 0 {
                        message = "Kapitel gespeichert"
                    } else if let chapters = chapters, !chapters.isEmpty {
                        message = "Keine Kapitel gespeichert"
                    } else {
                        message = "Keine Kapitel erzeugt"
                    }
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: message,
                                                      detailText: String(format: "%.1f s, %d Kapitel, %d Sponsor", elapsed, count, sponsors))
                }
                ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "chapters-finished", audioURL: audioURL)
            }

            // Done!
            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                // Success — pipeline completed cleanly, drop the crash guard.
                self.clearProcessingRun(runID)
                UserDefaults.standard.set(false, forKey: TranscriptionQueue.crashGuardKey)
                if let chapterGenerationError {
                    let headline = NSLocalizedString("Transkription abgeschlossen, Kapitel fehlgeschlagen.", comment: "")
                    let detail = TranscriptionQueue.detailedErrorMessage(for: chapterGenerationError)
                    item.status = .failed
                    item.progress = 1.0
                    item.error = [headline, detail].filter { !$0.isEmpty }.joined(separator: "\n")
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.completedAt = nil
                    self.isProcessing = false
                    self.refreshBackgroundContinuation(reason: "pipeline-chapters-failed")
                    self.postQueueChangeNotification()
                    self.postFinishNotification(episodeHash: episodeHash)
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "done",
                                                      message: headline, detailText: detail)
                    NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])
                    if !UserDefaults.standard.bool(forKey: "TranscriptionEverActivated") {
                        UserDefaults.standard.set(true, forKey: "TranscriptionEverActivated")
                    }
                    self.processNext()
                    return
                }
                item.status = .completed
                item.progress = 1.0
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.completedAt = Date()
                self.isProcessing = false
                self.refreshBackgroundContinuation(reason: "pipeline-finished")
                self.postQueueChangeNotification()
                self.postFinishNotification(episodeHash: episodeHash)
                self.scheduleCompletedItemPrune()
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "done",
                                                  message: "Gesamter Durchlauf abgeschlossen", detailText: nil)
                // Notify player + cells that transcript is available
                NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])

                // Mark that transcription has been used at least once
                if !UserDefaults.standard.bool(forKey: "TranscriptionEverActivated") {
                    UserDefaults.standard.set(true, forKey: "TranscriptionEverActivated")
                    // Auto-transcription defaults stay OFF — user enables manually
                }

                // Process next item
                self.processNext()
            }
            ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "pipeline-finished", audioURL: audioURL)
        }
    }

    // MARK: - Checkpoint Failures (OOM Protection)

    private func loadCheckpointFailures(for episodeHash: String) -> Int? {
        let url = engine.transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_checkpoint.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let failures = json["consecutiveFailures"] as? Int else {
            return nil
        }
        return failures
    }

    // MARK: - Audio URL Resolution (via ObjC bridged classes)

    private func resolveAudioURL(for episodeHash: String) -> URL? {
        guard let dmanager = DatabaseManager.shared() else { return nil }
        guard let cman = CacheManager.shared() else { return nil }

        for feed in dmanager.feeds as? [CDFeed] ?? [] {
            for episode in feed.episodes as? Set<CDEpisode> ?? [] {
                if episode.objectHash == episodeHash && cman.episodeIsCached(episode) {
                    let url = cman.url(forCachedEpisode: episode)
                    if let url = url, FileManager.default.fileExists(atPath: url.path) {
                        return url
                    }
                }
            }
        }
        return nil
    }

    private func findEpisode(hash: String) -> CDEpisode? {
        guard let dmanager = DatabaseManager.shared() else { return nil }
        for feed in dmanager.feeds as? [CDFeed] ?? [] {
            for episode in feed.episodes as? Set<CDEpisode> ?? [] {
                if episode.objectHash == hash {
                    return episode
                }
            }
        }
        return nil
    }

    private static func debugStatusName(_ status: ICTranscriptionStatus) -> String {
        switch status {
        case .none: return "none"
        case .queued: return "queued"
        case .downloadingModel: return "downloadingModel"
        case .analyzingMusic: return "analyzingMusic"
        case .transcribing: return "transcribing"
        case .generatingChapters: return "generatingChapters"
        case .completed: return "completed"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private static func debugTimestampString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func debugFileSnapshot(_ url: URL) -> NSDictionary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        return [
            "path": url.path,
            "exists": FileManager.default.fileExists(atPath: url.path),
            "bytes": size,
            "modifiedAt": modified.map(debugTimestampString) ?? "",
        ] as NSDictionary
    }

    private func autoDownloadEpisode(hash: String) -> Bool {
        guard let episode = findEpisode(hash: hash) else { return false }
        guard let cman = CacheManager.shared() else { return false }

        if cman.episodeIsCached(episode) { return false }

        pendingDownloadHashes.insert(hash)
        cman.cacheEpisode(episode, overwriteCellularLock: true)
        return true
    }

    /// Called when ANY download completes — checks if it was a pending auto-download
    private func _handleDownloadCompletion() {
        guard !pendingDownloadHashes.isEmpty else { return }

        var hashesToRemove: [String] = []
        for hash in pendingDownloadHashes {
            // Check if item is still in queue
            guard let item = items.first(where: { $0.episodeHash == hash && $0.status == .queued }) else {
                // Item was removed from queue — clean up pending hash
                hashesToRemove.append(hash)
                continue
            }

            if let url = resolveAudioURL(for: hash) {
                item.audioURL = url
                item.error = nil
                item.statusDetail = nil
                hashesToRemove.append(hash)
                NSLog("[TranscriptionQueue] Episode downloaded, resuming transcription for %@", hash)
                // Remove processed hashes before calling processNext
                for h in hashesToRemove { pendingDownloadHashes.remove(h) }
                if !isProcessing {
                    processNext()
                }
                return
            }
            // resolveAudioURL returned nil — download might still be in progress or failed
            // Don't remove yet, will retry on next notification
        }
        // Clean up orphaned hashes
        for h in hashesToRemove { pendingDownloadHashes.remove(h) }
    }

    // MARK: - Episode Deletion Handling

    @objc func handleEpisodeDeleted(episodeHash: String) {
        if let item = items.first(where: { $0.episodeHash == episodeHash }) {
            if item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel {
                invalidateProcessingRun()
                currentTask?.cancel()
                currentTask = nil
                engine.cancelTranscription()
                analyzer.cancelAnalysis()
                isProcessing = false
            }
            if item.status == .generatingChapters {
                chapterTask?.cancel()
                chapterTask = nil
            }
            dequeue(episodeHash: episodeHash)
            NSLog("[TranscriptionQueue] Cancelled transcription for deleted episode %@", episodeHash)
        }
    }

    // MARK: - Persistence

    private var queueFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TranscriptionQueue.json")
    }

    private func persistQueue() {
        let now = Date()
        let persistable = PersistedQueue(
            items: items.compactMap { item -> PersistedQueue.PersistedItem? in
                let shouldResumeAsChapterOnly = item.chapterOnly || (item.status == .generatingChapters && engine.hasSRT(for: item.episodeHash))
                if item.status == .failed {
                    return .init(episodeHash: item.episodeHash,
                                 episodeTitle: item.episodeTitle,
                                 feedTitle: item.feedTitle,
                                 language: item.language,
                                 statusRawValue: item.status.rawValue,
                                 completedAt: item.completedAt ?? now,
                                 chapterOnly: shouldResumeAsChapterOnly,
                                 error: item.error)
                }
                if item.status == .completed {
                    guard let completedAt = item.completedAt,
                          now.timeIntervalSince(completedAt) < Self.completedItemRetentionInterval else { return nil }
                    return .init(episodeHash: item.episodeHash,
                                 episodeTitle: item.episodeTitle,
                                 feedTitle: item.feedTitle,
                                 language: item.language,
                                 statusRawValue: item.status.rawValue,
                                 completedAt: completedAt,
                                 chapterOnly: item.chapterOnly,
                                 error: nil)
                }
                return .init(episodeHash: item.episodeHash,
                             episodeTitle: item.episodeTitle,
                             feedTitle: item.feedTitle,
                             language: item.language,
                             statusRawValue: item.status.rawValue,
                             completedAt: nil,
                             chapterOnly: shouldResumeAsChapterOnly,
                             error: item.error)
            }
        )
        if let data = try? JSONEncoder().encode(persistable) {
            try? data.write(to: queueFileURL, options: .atomic)
        }
    }

    private func loadPersistedQueue() {
        guard let data = try? Data(contentsOf: queueFileURL),
              let persisted = try? JSONDecoder().decode(PersistedQueue.self, from: data) else {
            return
        }

        // Reconstruct items - audio URLs need to be resolved from CacheManager
        for pItem in persisted.items {
            if pItem.statusRawValue == ICTranscriptionStatus.failed.rawValue {
                guard let failedAt = pItem.completedAt,
                      Date().timeIntervalSince(failedAt) < Self.completedItemRetentionInterval else { continue }
                let item = ICTranscriptionQueueItem(
                    episodeHash: pItem.episodeHash,
                    episodeTitle: pItem.episodeTitle,
                    feedTitle: pItem.feedTitle,
                    audioURL: nil,
                    language: pItem.language
                )
                item.status = .failed
                item.progress = 0
                item.completedAt = failedAt
                item.chapterOnly = pItem.chapterOnly == true
                item.error = pItem.error
                items.append(item)
                continue
            }

            if pItem.statusRawValue == ICTranscriptionStatus.completed.rawValue {
                guard let completedAt = pItem.completedAt,
                      Date().timeIntervalSince(completedAt) < Self.completedItemRetentionInterval else { continue }
                let item = ICTranscriptionQueueItem(
                    episodeHash: pItem.episodeHash,
                    episodeTitle: pItem.episodeTitle,
                    feedTitle: pItem.feedTitle,
                    audioURL: nil,
                    language: pItem.language
                )
                item.status = .completed
                item.progress = 1.0
                item.completedAt = completedAt
                item.chapterOnly = pItem.chapterOnly == true
                items.append(item)
                continue
            }

            if pItem.chapterOnly == true {
                guard engine.hasSRT(for: pItem.episodeHash) else {
                    ICDiagnosticLogger.shared.logEvent("queue", message: "Persistierter Kapitel-Job ohne Transkript übersprungen", metadata: [
                        "episodeHash": pItem.episodeHash,
                    ] as NSDictionary)
                    continue
                }
                let item = ICTranscriptionQueueItem(
                    episodeHash: pItem.episodeHash,
                    episodeTitle: pItem.episodeTitle,
                    feedTitle: pItem.feedTitle,
                    audioURL: nil,
                    language: pItem.language
                )
                item.chapterOnly = true
                item.status = .queued
                items.append(item)
                continue
            }

            // Skip if already transcribed
            guard !engine.hasSRT(for: pItem.episodeHash) else { continue }

            let item = ICTranscriptionQueueItem(
                episodeHash: pItem.episodeHash,
                episodeTitle: pItem.episodeTitle,
                feedTitle: pItem.feedTitle,
                audioURL: nil, // Will be resolved when processing starts
                language: pItem.language
            )
            item.status = .queued
            items.append(item)
        }
        if items.contains(where: { $0.status == .completed }) {
            scheduleCompletedItemPrune()
        }
    }

    // MARK: - Notifications (throttled to avoid UI spam)

    private var lastProgressNotificationDate: Date?

    private func beginStep(for item: ICTranscriptionQueueItem,
                           status: ICTranscriptionStatus,
                           detail: String?) {
        let didChangeStatus = item.status != status
        item.status = status
        item.progress = 0
        item.statusDetail = detail
        item.error = nil
        item.completedAt = nil
        if didChangeStatus || item.statusStartedAt == nil {
            item.statusStartedAt = Date()
        }
        ICDiagnosticLogger.shared.logEvent("queue-step", message: "Queue-Schritt gewechselt", metadata: [
            "episodeHash": item.episodeHash,
            "status": "\(status.rawValue)",
            "detail": detail ?? "",
        ] as NSDictionary)
        persistQueue()
    }

    private func updateStatusDetail(for episodeHash: String, detail: String) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash }) else { return }
        guard item.statusDetail != detail else { return }
        item.statusDetail = detail
        ICDiagnosticLogger.shared.logEvent("queue-detail", message: detail, metadata: [
            "episodeHash": episodeHash,
            "status": "\(item.status.rawValue)",
        ] as NSDictionary)
        postProgressNotification(episodeHash: episodeHash, progress: item.progress, status: item.status, force: true)
    }

    private nonisolated static func detailedErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = []

        func appendIfNeeded(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  !parts.contains(text) else { return }
            parts.append(text)
        }

        appendIfNeeded(nsError.localizedDescription)
        appendIfNeeded(nsError.localizedFailureReason)
        appendIfNeeded(nsError.localizedRecoverySuggestion)

        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = underlying {
            appendIfNeeded(current.localizedDescription)
            appendIfNeeded(current.localizedFailureReason)
            appendIfNeeded(current.localizedRecoverySuggestion)
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return parts.isEmpty ? NSLocalizedString("Unbekannter Fehler.", comment: "") : parts.joined(separator: "\n")
    }

    private func postQueueChangeNotification() {
        NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionQueueDidChangeNotification"), object: nil)
    }

    private func postProgressNotification(episodeHash: String, progress: Float, status: ICTranscriptionStatus, force: Bool = false) {
        // Throttle: max once per 0.5 seconds
        let now = Date()
        if !force, let last = lastProgressNotificationDate, now.timeIntervalSince(last) < 0.5 {
            return
        }
        lastProgressNotificationDate = now
        NotificationCenter.default.post(
            name: NSNotification.Name("ICTranscriptionDidProgressNotification"),
            object: nil,
            userInfo: ["episodeHash": episodeHash, "progress": progress, "status": status.rawValue]
        )
    }

    private func postFinishNotification(episodeHash: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ICTranscriptionDidFinishNotification"),
            object: nil,
            userInfo: ["episodeHash": episodeHash]
        )
    }
}
