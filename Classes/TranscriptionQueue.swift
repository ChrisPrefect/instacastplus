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

    @objc init(episodeHash: String, episodeTitle: String, feedTitle: String,
               audioURL: URL?, language: String?) {
        self.episodeHash = episodeHash
        self.episodeTitle = episodeTitle
        self.feedTitle = feedTitle
        self.audioURL = audioURL
        self.language = language
        self.status = .queued
        self.progress = 0
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
    }
}

// MARK: - TranscriptionQueue

@MainActor
@objc class TranscriptionQueue: NSObject {

    private static let _shared = TranscriptionQueue()
    @objc static var shared: TranscriptionQueue { _shared }

    @objc private(set) var items: [ICTranscriptionQueueItem] = []
    @objc private(set) var isProcessing = false

    private var engine: TranscriptionEngine { TranscriptionEngine.shared }
    private var analyzer: AudioAnalyzer { AudioAnalyzer.shared }
    private var chapterGen: ChapterGenerator { ChapterGenerator.shared }

    private var currentTask: Task<Void, Never>?
    private var pendingDownloadHashes: Set<String> = [] // Tracks episodes being auto-downloaded

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
        if let item = items.first(where: { $0.episodeHash == episodeHash }),
           item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel {
            currentTask?.cancel()
            currentTask = nil
            engine.cancelTranscription()
            isProcessing = false
            needsProcessNext = true
        }
        pendingDownloadHashes.remove(episodeHash)
        items.removeAll { $0.episodeHash == episodeHash }
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
        currentTask?.cancel()
        currentTask = nil
        engine.cancelTranscription()
        items.removeAll()
        isProcessing = false
        persistQueue()
        postQueueChangeNotification()
    }

    /// Generate chapters for an episode that already has a transcript.
    @objc func generateChapters(episodeHash: String, episodeTitle: String, feedTitle: String) {
        guard ChapterGenerator.isAvailable() else {
            NSLog("[TranscriptionQueue] Cannot generate chapters: Apple Intelligence not available")
            return
        }

        // Don't add if already in queue (dedup)
        guard !items.contains(where: { $0.episodeHash == episodeHash }) else {
            NSLog("[TranscriptionQueue] Episode %@ already in queue, skipping chapter generation", episodeHash)
            return
        }

        // Load transcript cues from SRT
        let srtURL = TranscriptionEngine.shared.srtURL(for: episodeHash)
        guard FileManager.default.fileExists(atPath: srtURL.path) else {
            NSLog("[TranscriptionQueue] No SRT for %@, chapter generation from RSS not yet supported", episodeHash)
            return
        }

        // Add to queue with special "chapters only" status
        let item = ICTranscriptionQueueItem(
            episodeHash: episodeHash,
            episodeTitle: episodeTitle,
            feedTitle: feedTitle,
            audioURL: nil,
            language: nil
        )
        item.status = .generatingChapters
        item.progress = 0
        items.append(item)
        postQueueChangeNotification()

        Task {
            await MainActor.run {
                self.postQueueChangeNotification()
            }

            // Load cues from SRT file
            let cues = self.loadCuesFromSRT(url: srtURL)
            guard !cues.isEmpty else {
                await MainActor.run {
                    item.status = .failed
                    item.error = NSLocalizedString("Transkript konnte nicht geladen werden.", comment: "")
                    self.postQueueChangeNotification()
                }
                return
            }

            // Load cached music timeline if available (no re-analysis needed)
            var musicSegments: [ICAudioSegment]? = nil
            if AudioAnalyzer.shared.hasCachedTimeline(for: episodeHash) {
                // hasCachedTimeline checks the cache, analyze() returns cached result immediately
                // We need a real audio URL for the API, but since cached data exists it won't be used
                if let resolvedURL = self.resolveAudioURL(for: episodeHash) {
                    musicSegments = await withCheckedContinuation { cont in
                        AudioAnalyzer.shared.analyze(audioURL: resolvedURL, episodeHash: episodeHash) { segs, _ in
                            cont.resume(returning: segs)
                        }
                    }
                }
            }

            NSLog("[TranscriptionQueue] Generating chapters for %@ (%d cues)", episodeHash, cues.count)

            var chapterError: Error? = nil
            let chapters = await withCheckedContinuation { (continuation: CheckedContinuation<[ICGeneratedChapter]?, Never>) in
                self.chapterGen.generateChapters(fromCues: cues, musicSegments: musicSegments) { chapters, error in
                    if let error = error {
                        chapterError = error
                        NSLog("[TranscriptionQueue] Chapter generation error: %@", error.localizedDescription)
                    }
                    continuation.resume(returning: chapters)
                }
            }

            await MainActor.run {
                if let chapters = chapters, !chapters.isEmpty {
                    self.chapterGen.saveChapters(chapters, for: episodeHash)
                    item.status = .completed
                    item.progress = 1.0
                    NSLog("[TranscriptionQueue] Generated %d chapters", chapters.count)
                } else {
                    item.status = .failed
                    item.error = chapterError?.localizedDescription ?? NSLocalizedString("Kapitelerkennung fehlgeschlagen.", comment: "")
                }
                self.postQueueChangeNotification()
                NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])

                // Auto-remove this specific chapter-generation item after a short delay
                let itemToRemove = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.items.removeAll { $0 === itemToRemove }
                    self?.postQueueChangeNotification()
                }
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

        // Reset stuck processing state (e.g. after app kill during transcription)
        if isProcessing && currentTask == nil {
            NSLog("[TranscriptionQueue] Resetting stuck isProcessing flag")
            isProcessing = false
        }

        guard !isProcessing else { return }

        // Reset any stuck items back to queued
        for item in items {
            if item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel || item.status == .generatingChapters {
                NSLog("[TranscriptionQueue] Resetting stuck item %@ from status %ld to queued", item.episodeHash, item.status.rawValue)
                item.status = .queued
                item.progress = 0
                item.error = nil
            }
            if engine.hasCheckpoint(for: item.episodeHash) {
                NSLog("[TranscriptionQueue] Found interrupted transcription for %@, resuming", item.episodeHash)
                item.status = .queued
            }
        }

        processNext()
    }

    /// Number of items currently queued (including active)
    @objc var count: Int { items.count }

    /// Currently processing item
    @objc var currentItem: ICTranscriptionQueueItem? {
        items.first { $0.status != .completed && $0.status != .failed && $0.status != .queued }
            ?? items.first { $0.status == .queued }
    }

    // MARK: - Processing

    private func processNext() {
        guard !isProcessing else { return }

        // Iteratively skip failed items (no recursion, no stack growth)
        var item: ICTranscriptionQueueItem?
        var resolvedAudioURL: URL?

        while true {
            // Find next queued item
            guard let candidate = items.first(where: { $0.status == .queued }) else {
                // Queue empty, remove completed items
                items.removeAll { $0.status == .completed }
                persistQueue()
                postQueueChangeNotification()
                // Release WhisperKit model from memory when queue is done
                Task { await WhisperKitBackend.shared.releaseModel() }
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
                    candidate.error = NSLocalizedString("Episode wird heruntergeladen...", comment: "")
                    postQueueChangeNotification()
                    return // Will resume in _handleDownloadCompletion
                }
                candidate.status = .failed
                candidate.error = NSLocalizedString("Audiodatei nicht verfügbar.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // Check failure counter for OOM loop protection
            if let failures = loadCheckpointFailures(for: candidate.episodeHash), failures >= 6 {
                candidate.status = .failed
                candidate.error = NSLocalizedString("Transkription auf diesem Gerät nicht möglich.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // Check if WhisperKit model is downloaded
            let engineRaw = UserDefaults.standard.string(forKey: "TranscriptionEngine") ?? "WhisperKit"
            if engineRaw == "WhisperKit" && !WhisperKitBackend.shared.isModelDownloadedSync() {
                candidate.status = .failed
                candidate.error = NSLocalizedString("Sprachmodell nicht installiert. Bitte in Einstellungen > Transkription herunterladen.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // All checks passed — process this item
            item = candidate
            break
        }

        guard let item = item, let audioURL = resolvedAudioURL else { return }

        isProcessing = true
        let episodeHash = item.episodeHash

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            // Step 1: Music Analysis (SoundAnalysis, < 1 min)
            await MainActor.run {
                item.status = .analyzingMusic
                self.postQueueChangeNotification()
            }

            let musicSegments = await withCheckedContinuation { (continuation: CheckedContinuation<[ICAudioSegment]?, Never>) in
                self.analyzer.analyze(audioURL: audioURL, episodeHash: episodeHash) { segments, error in
                    if let error = error {
                        NSLog("[TranscriptionQueue] Music analysis error: %@", error.localizedDescription)
                    }
                    continuation.resume(returning: segments)
                }
            }

            // Check cancellation
            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isProcessing = false
                    self.processNext()
                }
                return
            }

            // Step 2: Transcription (WhisperKit/Apple)
            await MainActor.run {
                item.status = .transcribing
                item.progress = 0
                self.postQueueChangeNotification()
            }

            let cues = await withCheckedContinuation { (continuation: CheckedContinuation<[ICTranscriptCue]?, Never>) in
                self.engine.transcribe(
                    audioURL: audioURL,
                    episodeHash: episodeHash,
                    language: item.language,
                    progress: { [weak self] progress, status in
                        DispatchQueue.main.async {
                            item.progress = progress
                            item.status = status
                            self?.postProgressNotification(episodeHash: episodeHash, progress: progress, status: status)
                        }
                    },
                    completion: { cues, error in
                        if let error = error {
                            NSLog("[TranscriptionQueue] Transcription error: %@", error.localizedDescription)
                            item.status = .failed
                            item.error = error.localizedDescription
                        }
                        continuation.resume(returning: cues)
                    }
                )
            }

            guard let transcriptCues = cues, !Task.isCancelled else {
                await MainActor.run {
                    if item.status != .failed {
                        item.status = .failed
                        item.error = NSLocalizedString("Transkription fehlgeschlagen.", comment: "")
                    }
                    self.isProcessing = false
                    self.postQueueChangeNotification()
                    self.processNext()
                }
                return
            }

            // Step 3: Chapter Generation (Foundation Models, ~10-30 sec)
            // Auto-generate chapters if:
            // - Apple Intelligence is available
            // - Episode doesn't already have podcast-provided chapters
            let shouldGenerateChapters: Bool
            if ChapterGenerator.isAvailable() {
                // Check if episode has existing chapters from the podcast
                if let episode = self.findEpisode(hash: episodeHash) {
                    let hasExistingChapters = (episode.chapters?.count ?? 0) > 0
                    shouldGenerateChapters = !hasExistingChapters
                    if hasExistingChapters {
                        NSLog("[TranscriptionQueue] Episode has %d existing chapters, skipping generation", episode.chapters?.count ?? 0)
                    }
                } else {
                    shouldGenerateChapters = true
                }
            } else {
                shouldGenerateChapters = false
                NSLog("[TranscriptionQueue] ChapterGenerator not available (Apple Intelligence not active)")
            }

            if shouldGenerateChapters {
                await MainActor.run {
                    item.status = .generatingChapters
                    item.progress = 0.95
                    self.postQueueChangeNotification()
                }
                NSLog("[TranscriptionQueue] Generating chapters from %d cues + %d music segments",
                      transcriptCues.count, musicSegments?.count ?? 0)

                let chapters = await withCheckedContinuation { (continuation: CheckedContinuation<[ICGeneratedChapter]?, Never>) in
                    self.chapterGen.generateChapters(fromCues: transcriptCues, musicSegments: musicSegments) { chapters, error in
                        if let error = error {
                            NSLog("[TranscriptionQueue] Chapter generation error: %@", error.localizedDescription)
                        } else {
                            NSLog("[TranscriptionQueue] Generated %d chapters", chapters?.count ?? 0)
                        }
                        continuation.resume(returning: chapters)
                    }
                }

                if let chapters = chapters, !chapters.isEmpty {
                    self.chapterGen.saveChapters(chapters, for: episodeHash)
                    NSLog("[TranscriptionQueue] Saved %d chapters for %@", chapters.count, episodeHash)
                }
            }

            // Done!
            await MainActor.run {
                item.status = .completed
                item.progress = 1.0
                self.isProcessing = false
                self.postQueueChangeNotification()
                self.postFinishNotification(episodeHash: episodeHash)
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
            if item.status == .transcribing || item.status == .analyzingMusic {
                currentTask?.cancel()
                currentTask = nil
                engine.cancelTranscription()
                isProcessing = false
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
        let persistable = PersistedQueue(
            items: items.filter { $0.status == .queued || $0.status == .transcribing || $0.status == .analyzingMusic || $0.status == .generatingChapters }
                .map { .init(episodeHash: $0.episodeHash, episodeTitle: $0.episodeTitle,
                            feedTitle: $0.feedTitle, language: $0.language) }
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
    }

    // MARK: - Notifications (throttled to avoid UI spam)

    private var lastProgressNotificationDate: Date?

    private func postQueueChangeNotification() {
        NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionQueueDidChangeNotification"), object: nil)
    }

    private func postProgressNotification(episodeHash: String, progress: Float, status: ICTranscriptionStatus) {
        // Throttle: max once per 0.5 seconds
        let now = Date()
        if let last = lastProgressNotificationDate, now.timeIntervalSince(last) < 0.5 {
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
