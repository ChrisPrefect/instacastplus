//
//  TranscriptionEngine.swift
//  Instacast
//
//  On-device speech-to-text via WhisperKit or Apple SpeechAnalyzer.
//  Produces SRT files stored in Application Support/TranscriptCache/.
//

import Foundation
import AVFoundation
#if canImport(Speech)
import Speech
#endif

// MARK: - Engine Type

@objc enum ICTranscriptionEngineType: Int {
    case whisperKit = 0
    case apple = 1
}

// MARK: - Transcript Cue

@objc class ICTranscriptCue: NSObject, @unchecked Sendable {
    @objc let start: Double
    @objc let end: Double
    @objc let text: String

    @objc init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    @objc var dictionary: NSDictionary {
        return ["start": start, "end": end, "text": text]
    }
}

// MARK: - Checkpoint

private struct TranscriptionCheckpoint: Codable {
    var lastTimestamp: Double
    var cues: [CuePersist]
    var engineType: Int
    var consecutiveFailures: Int

    struct CuePersist: Codable {
        let start: Double
        let end: Double
        let text: String
    }
}

// MARK: - TranscriptionEngine

@MainActor
@objc class TranscriptionEngine: NSObject {

    private static let _shared = TranscriptionEngine()
    @objc static var shared: TranscriptionEngine { _shared }

    @objc var engineType: ICTranscriptionEngineType {
        get {
            let raw = UserDefaults.standard.integer(forKey: "TranscriptionEngine")
            return ICTranscriptionEngineType(rawValue: raw) ?? .whisperKit
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "TranscriptionEngine")
        }
    }

    @objc private(set) var isTranscribing = false
    @objc private(set) var currentProgress: Float = 0
    @objc private(set) var currentStatus: ICTranscriptionStatus = .none

    private var currentTask: Task<Void, Never>?
    private var currentCompletion: (([ICTranscriptCue]?, Error?) -> Void)?

    // MARK: - Public API

    @objc func transcribe(audioURL: URL, episodeHash: String, language: String?,
                          progress: @escaping @Sendable (Float, ICTranscriptionStatus) -> Void,
                          completion: @escaping @Sendable ([ICTranscriptCue]?, Error?) -> Void) {
        guard !isTranscribing else {
            completion(nil, NSError(domain: "TranscriptionEngine", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Already transcribing"]))
            return
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(nil, NSError(domain: "TranscriptionEngine", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "Audio file not found"]))
            return
        }

        // Check available disk space
        guard hasSufficientDiskSpace() else {
            completion(nil, NSError(domain: "TranscriptionEngine", code: 3,
                                   userInfo: [NSLocalizedDescriptionKey: "Not enough disk space"]))
            return
        }

        isTranscribing = true
        currentProgress = 0
        currentCompletion = completion

        // Load checkpoint if exists
        let checkpoint = loadCheckpoint(for: episodeHash)
        let startOffset = checkpoint?.lastTimestamp ?? 0
        let existingCues = checkpoint?.cues.map { ICTranscriptCue(start: $0.start, end: $0.end, text: $0.text) } ?? []

        // Get audio duration for progress calculation
        let asset = AVURLAsset(url: audioURL)

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let duration = try await asset.load(.duration)
                let totalDuration = CMTimeGetSeconds(duration)
                guard totalDuration > 0 else {
                    throw NSError(domain: "TranscriptionEngine", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid audio duration"])
                }

                // Determine effective engine based on failure counter
                let effectiveEngine = self.effectiveEngine(for: episodeHash, checkpoint: checkpoint)

                await MainActor.run {
                    self.currentStatus = .transcribing
                    progress(Float(startOffset / totalDuration), .transcribing)
                }

                var newCues: [ICTranscriptCue] = []

                // WhisperKit reports p as 0..1 fraction of the audio it was asked to process.
                // When resuming, it starts from startOffset, so map p back to absolute position.
                let sendableProgress: @Sendable (Float) -> Void = { [weak self] p in
                    let absoluteProgress = Float(startOffset / totalDuration) + p * Float((totalDuration - startOffset) / totalDuration)
                    NSLog("[TranscriptionEngine] Progress callback: raw=%.1f%% absolute=%.1f%%", p * 100, absoluteProgress * 100)
                    DispatchQueue.main.async {
                        self?.currentProgress = absoluteProgress
                        progress(absoluteProgress, .transcribing)
                    }
                }

                // Segment callback: fine-grained progress + periodic checkpoint saves.
                // Accumulate cues so checkpoints contain all transcribed text for crash recovery.
                nonisolated(unsafe) var lastCheckpointProg: Float = 0
                nonisolated(unsafe) var accumulatedCues: [ICTranscriptCue] = existingCues
                let segmentCb: @Sendable (ICTranscriptCue) -> Void = { [weak self] cue in
                    accumulatedCues.append(cue)
                    let cueEnd = cue.end
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Update progress per segment (much more frequent than per-window callback)
                        let segProgress = Float(cueEnd / totalDuration)
                        self.currentProgress = segProgress
                        progress(segProgress, .transcribing)

                        // Checkpoint every ~10%
                        if segProgress - lastCheckpointProg >= 0.1 {
                            lastCheckpointProg = segProgress
                            self.saveCheckpointWithCues(episodeHash: episodeHash, cues: accumulatedCues, engineType: effectiveEngine.rawValue)
                        }
                    }
                }

                switch effectiveEngine {
                case .whisperKit:
                    newCues = try await self.transcribeWithWhisperKit(
                        audioURL: audioURL,
                        startOffset: startOffset,
                        totalDuration: totalDuration,
                        language: language,
                        progress: sendableProgress,
                        segmentCallback: segmentCb
                    )

                case .apple:
                    newCues = try await self.transcribeWithApple(
                        audioURL: audioURL,
                        startOffset: startOffset,
                        totalDuration: totalDuration,
                        language: language,
                        progress: sendableProgress,
                        segmentCallback: segmentCb
                    )
                }

                // Merge: dedup based on timestamp overlap
                let rawCues: [ICTranscriptCue]
                if startOffset > 0 && !newCues.isEmpty {
                    let deduped = newCues.filter { $0.start >= startOffset }
                    rawCues = existingCues + deduped
                } else if startOffset > 0 {
                    rawCues = existingCues
                } else {
                    rawCues = newCues
                }

                // Post-process: merge short fragments, split long segments
                let allCues = self.postProcessCues(rawCues)

                // Save SRT file
                let srtURL = self.srtURL(for: episodeHash)
                try self.writeSRT(cues: allCues, to: srtURL)

                // Remove checkpoint
                self.removeCheckpoint(for: episodeHash)

                // Reset failure counter
                self.resetFailureCounter(for: episodeHash)

                await MainActor.run {
                    self.isTranscribing = false
                    self.currentStatus = .completed
                    self.currentProgress = 1.0
                    self.currentCompletion = nil
                    progress(1.0, .completed)
                    completion(allCues, nil)
                }

            } catch {
                await MainActor.run {
                    let wasCancelled = (self.currentCompletion == nil) || error is CancellationError || Task.isCancelled
                    // Increment failure counter only for real errors, not cancellation
                    if !wasCancelled {
                        self.incrementFailureCounter(for: episodeHash)
                    }

                    self.isTranscribing = false
                    self.currentStatus = wasCancelled ? .none : .failed
                    // Only call completion if not already called by cancelTranscription()
                    if self.currentCompletion != nil {
                        self.currentCompletion = nil
                        completion(nil, error)
                    }
                }
            }
        }
    }

    @objc func cancelTranscription() {
        let cb = currentCompletion
        currentCompletion = nil
        currentTask?.cancel()
        currentTask = nil
        isTranscribing = false
        currentStatus = .none
        // Call completion so withCheckedContinuation in the queue doesn't hang
        cb?(nil, NSError(domain: "TranscriptionEngine", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
    }

    // MARK: - Model Management

    @objc func isModelDownloaded() -> Bool {
        return WhisperKitBackend.shared.isModelDownloadedSync()
    }

    /// Pre-load WhisperKit model in background. Called at app launch so the model
    /// is ready in memory when the user starts transcribing.
    @objc func preloadModel() {
        guard engineType == .whisperKit && isModelDownloaded() else { return }
        Task.detached {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try await WhisperKitBackend.shared.prepareModel()
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                NSLog("[TranscriptionEngine] Model pre-loaded in %.1fs", elapsed)
            } catch {
                NSLog("[TranscriptionEngine] Model pre-load failed: %@", error.localizedDescription)
            }
        }
    }

    @objc var modelSizeOnDisk: Int64 {
        return WhisperKitBackend.shared.modelSizeOnDiskSync()
    }

    @objc func downloadModel(progress: @escaping (Float) -> Void,
                             completion: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let cb = completion
        Task.detached {
            do {
                try await WhisperKitBackend.shared.downloadModel()
                await MainActor.run { cb(nil) }
            } catch {
                await MainActor.run { cb(error) }
            }
        }
    }

    @objc func deleteModel() {
        Task.detached {
            await WhisperKitBackend.shared.deleteModel()
        }
    }

    @objc static func recommendedEngine() -> ICTranscriptionEngineType {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        // 8GB+ → WhisperKit (better accuracy), < 8GB → Apple (no download needed)
        return physicalMemory >= 8 * 1024 * 1024 * 1024 ? .whisperKit : .apple
    }

    @objc static func resolvedModelName() -> String {
        return WhisperKitBackend.resolvedModelName()
    }

    @objc nonisolated static func recommendedWhisperModel() -> String {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return physicalMemory >= 8 * 1024 * 1024 * 1024
            ? "openai_whisper-large-v3-v20240930_turbo_632MB"
            : "openai_whisper-small_216MB"
    }

    // MARK: - File Paths

    private static var _cachedTranscriptDir: URL?

    @objc func transcriptCacheDirectory() -> URL {
        if let cached = TranscriptionEngine._cachedTranscriptDir {
            return cached
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("TranscriptCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(resourceValues)
        TranscriptionEngine._cachedTranscriptDir = dir
        return dir
    }

    @objc func srtURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash).srt")
    }

    @objc func hasSRT(for episodeHash: String) -> Bool {
        return FileManager.default.fileExists(atPath: srtURL(for: episodeHash).path)
    }

    @objc func hasCheckpoint(for episodeHash: String) -> Bool {
        return FileManager.default.fileExists(atPath: checkpointURL(for: episodeHash).path)
    }

    @objc func removeSRT(for episodeHash: String) {
        try? FileManager.default.removeItem(at: srtURL(for: episodeHash))
        removeCheckpoint(for: episodeHash)
        removeChaptersJSON(for: episodeHash)
        removeMusicTimeline(for: episodeHash)
    }

    // MARK: - WhisperKit Backend

    private func transcribeWithWhisperKit(audioURL: URL, startOffset: Double, totalDuration: Double,
                                          language: String?,
                                          progress: @escaping @Sendable (Float) -> Void,
                                          segmentCallback: @escaping @Sendable (ICTranscriptCue) -> Void) async throws -> [ICTranscriptCue] {
        return try await WhisperKitBackend.shared.transcribe(
            audioURL: audioURL,
            startOffset: startOffset,
            totalDuration: totalDuration,
            language: language,
            progress: progress,
            segmentCallback: segmentCallback
        )
    }

    // MARK: - Apple SpeechAnalyzer Backend

    private func transcribeWithApple(audioURL: URL, startOffset: Double, totalDuration: Double,
                                     language: String?,
                                     progress: @escaping (Float) -> Void,
                                     segmentCallback: @escaping (ICTranscriptCue) -> Void) async throws -> [ICTranscriptCue] {
        guard #available(iOS 26, *) else {
            throw NSError(domain: "TranscriptionEngine", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "Apple-Spracherkennung benötigt iOS 26."])
        }

        #if canImport(Speech)
        return try await transcribeWithSpeechAnalyzer(
            audioURL: audioURL, startOffset: startOffset, totalDuration: totalDuration,
            language: language, progress: progress, segmentCallback: segmentCallback)
        #else
        throw NSError(domain: "TranscriptionEngine", code: 103,
                      userInfo: [NSLocalizedDescriptionKey: "Speech-Framework nicht verfügbar."])
        #endif
    }

    #if canImport(Speech)
    @available(iOS 26, *)
    private func transcribeWithSpeechAnalyzer(
        audioURL: URL, startOffset: Double, totalDuration: Double,
        language: String?,
        progress: @escaping (Float) -> Void,
        segmentCallback: @escaping (ICTranscriptCue) -> Void
    ) async throws -> [ICTranscriptCue] {

        // 1. Resolve locale from language code (BCP-47: "de", "en-US", etc.)
        let locale: Locale
        if let lang = language, !lang.isEmpty {
            locale = Locale(identifier: lang)
        } else {
            locale = Locale.current
        }

        // 2. Check locale support (compare at language-code level: "de" matches "de_DE")
        let supported = await SpeechTranscriber.supportedLocales
        let langCode = locale.language.languageCode
        guard supported.contains(where: { $0.language.languageCode == langCode }) else {
            let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            throw NSError(domain: "TranscriptionEngine", code: 104,
                          userInfo: [NSLocalizedDescriptionKey:
                              String(format: NSLocalizedString("Sprache '%@' wird von Apple-Spracherkennung nicht unterstützt.", comment: ""), name)])
        }

        // 3. Create transcriber with timestamps (no volatile results — we only need finals)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        NSLog("[TranscriptionEngine] Apple SpeechAnalyzer: locale=%@, file=%@", locale.identifier, audioURL.lastPathComponent)

        // 4. Collect results concurrently while analyzer processes the file
        nonisolated(unsafe) let unsafeTranscriber = transcriber
        nonisolated(unsafe) let unsafeTotalDuration = totalDuration
        nonisolated(unsafe) let unsafeStartOffset = startOffset
        nonisolated(unsafe) let unsafeProgress = progress
        nonisolated(unsafe) let unsafeSegmentCallback = segmentCallback

        async let resultsFuture: [ICTranscriptCue] = {
            var cues: [ICTranscriptCue] = []
            for try await result in unsafeTranscriber.results {
                if Task.isCancelled { throw CancellationError() }
                guard result.isFinal else { continue }

                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }

                // Extract time range from AttributedString runs
                var segStart: Double = 0
                var segEnd: Double = 0
                for run in result.text.runs {
                    if let timeRange = run.audioTimeRange {
                        let runStart = CMTimeGetSeconds(timeRange.start)
                        let runEnd = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))
                        if segStart == 0 || runStart < segStart { segStart = runStart }
                        if runEnd > segEnd { segEnd = runEnd }
                    }
                }

                // Skip if no time range was found (would produce a broken 0,0 cue)
                if segEnd == 0 { continue }

                // Skip segments before the resume offset
                if unsafeStartOffset > 0 && segEnd < unsafeStartOffset { continue }

                let cue = ICTranscriptCue(start: segStart, end: segEnd, text: text)
                cues.append(cue)
                unsafeSegmentCallback(cue)

                // Report progress
                if unsafeTotalDuration > 0 {
                    let p = min(Float(segEnd / unsafeTotalDuration), 0.99)
                    unsafeProgress(p)
                }
            }
            return cues
        }()

        // 5. Feed the audio file to the analyzer
        let audioFile = try AVAudioFile(forReading: audioURL)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
            throw NSError(domain: "TranscriptionEngine", code: 105,
                          userInfo: [NSLocalizedDescriptionKey: "SpeechAnalyzer konnte die Audiodatei nicht verarbeiten."])
        }

        // 6. Await collected results
        let cues = try await resultsFuture
        progress(1.0)
        NSLog("[TranscriptionEngine] Apple transcription done: %d cues", cues.count)
        return cues
    }
    #endif

    // MARK: - Post-Processing

    /// Clean up WhisperKit segments: merge short fragments, split overly long segments at sentence boundaries.
    private func postProcessCues(_ cues: [ICTranscriptCue]) -> [ICTranscriptCue] {
        guard !cues.isEmpty else { return cues }

        var result: [ICTranscriptCue] = []

        // Step 1: Merge very short fragments (< 2 seconds or < 10 chars) into adjacent cues
        var merged: [ICTranscriptCue] = []
        var pendingText = ""
        var pendingStart: Double = 0
        var pendingEnd: Double = 0

        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            if pendingText.isEmpty {
                pendingText = text
                pendingStart = cue.start
                pendingEnd = cue.end
            } else {
                let duration = pendingEnd - pendingStart
                // Merge if current pending segment is very short
                if duration < 2.0 || pendingText.count < 10 {
                    pendingText += " " + text
                    pendingEnd = cue.end
                } else {
                    merged.append(ICTranscriptCue(start: pendingStart, end: pendingEnd, text: pendingText))
                    pendingText = text
                    pendingStart = cue.start
                    pendingEnd = cue.end
                }
            }
        }
        if !pendingText.isEmpty {
            merged.append(ICTranscriptCue(start: pendingStart, end: pendingEnd, text: pendingText))
        }

        // Step 2: Split overly long segments (> 60 seconds) at sentence boundaries
        let sentenceEnders: CharacterSet = CharacterSet(charactersIn: ".!?")

        for cue in merged {
            let duration = cue.end - cue.start
            if duration <= 60.0 || cue.text.count < 200 {
                result.append(cue)
                continue
            }

            // Find sentence boundaries and split
            let text = cue.text
            var sentences: [String] = []
            var currentSentence = ""

            for char in text {
                currentSentence.append(char)
                if let scalar = char.unicodeScalars.first, sentenceEnders.contains(scalar), currentSentence.count > 20 {
                    sentences.append(currentSentence.trimmingCharacters(in: .whitespaces))
                    currentSentence = ""
                }
            }
            let remaining = currentSentence.trimmingCharacters(in: .whitespaces)
            if !remaining.isEmpty {
                sentences.append(remaining)
            }

            if sentences.count <= 1 {
                result.append(cue)
                continue
            }

            // Distribute time proportionally by character count
            let totalChars = sentences.reduce(0) { $0 + $1.count }
            var currentTime = cue.start
            for sentence in sentences {
                let fraction = Double(sentence.count) / Double(max(totalChars, 1))
                let segDuration = duration * fraction
                result.append(ICTranscriptCue(start: currentTime, end: currentTime + segDuration, text: sentence))
                currentTime += segDuration
            }
        }

        return result
    }

    // MARK: - SRT Writing

    private func writeSRT(cues: [ICTranscriptCue], to url: URL) throws {
        var srt = ""
        for (index, cue) in cues.enumerated() {
            srt += "\(index + 1)\n"
            srt += "\(formatSRTTime(cue.start)) --> \(formatSRTTime(cue.end))\n"
            srt += "\(cue.text)\n\n"
        }
        try srt.write(to: url, atomically: true, encoding: .utf8)
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    // MARK: - Checkpoint Persistence

    private func checkpointURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_checkpoint.json")
    }

    private func saveCheckpoint(episodeHash: String, cues: [ICTranscriptCue], engineType: Int) {
        let checkpoint = TranscriptionCheckpoint(
            lastTimestamp: cues.last?.end ?? 0,
            cues: cues.map { .init(start: $0.start, end: $0.end, text: $0.text) },
            engineType: engineType,
            consecutiveFailures: loadCheckpoint(for: episodeHash)?.consecutiveFailures ?? 0
        )
        if let data = try? JSONEncoder().encode(checkpoint) {
            try? data.write(to: checkpointURL(for: episodeHash), options: .atomic)
        }
    }

    private func loadCheckpoint(for episodeHash: String) -> TranscriptionCheckpoint? {
        guard let data = try? Data(contentsOf: checkpointURL(for: episodeHash)) else { return nil }
        return try? JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)
    }

    /// Save checkpoint with accumulated cues for crash recovery.
    /// Called periodically (~every 10%) during transcription.
    func saveCheckpointWithCues(episodeHash: String, cues: [ICTranscriptCue], engineType: Int) {
        let existing = loadCheckpoint(for: episodeHash)
        let checkpoint = TranscriptionCheckpoint(
            lastTimestamp: cues.last?.end ?? 0,
            cues: cues.map { .init(start: $0.start, end: $0.end, text: $0.text) },
            engineType: engineType,
            consecutiveFailures: existing?.consecutiveFailures ?? 0
        )
        if let data = try? JSONEncoder().encode(checkpoint) {
            try? data.write(to: checkpointURL(for: episodeHash), options: .atomic)
        }
    }

    private func removeCheckpoint(for episodeHash: String) {
        try? FileManager.default.removeItem(at: checkpointURL(for: episodeHash))
    }

    // MARK: - Failure Counter (OOM-Loop Protection)

    private func incrementFailureCounter(for episodeHash: String) {
        var checkpoint = loadCheckpoint(for: episodeHash) ?? TranscriptionCheckpoint(
            lastTimestamp: 0, cues: [], engineType: engineType.rawValue, consecutiveFailures: 0
        )
        checkpoint.consecutiveFailures += 1
        if let data = try? JSONEncoder().encode(checkpoint) {
            try? data.write(to: checkpointURL(for: episodeHash), options: .atomic)
        }
    }

    private func resetFailureCounter(for episodeHash: String) {
        // Checkpoint is removed on success, so counter is implicitly reset
    }

    private func effectiveEngine(for episodeHash: String, checkpoint: TranscriptionCheckpoint?) -> ICTranscriptionEngineType {
        guard let checkpoint = checkpoint else { return engineType }
        let failures = checkpoint.consecutiveFailures

        if engineType == .whisperKit {
            // After 2 failures with current model, try smaller model
            let model = UserDefaults.standard.string(forKey: "TranscriptionWhisperModel") ?? TranscriptionEngine.recommendedWhisperModel()
            if failures >= 2 && model.contains("large") {
                // Auto-downgrade to small
                UserDefaults.standard.set("openai_whisper-small_216MB", forKey: "TranscriptionWhisperModel")
                NSLog("[TranscriptionEngine] Auto-downgraded to small model after %d failures", failures)
                return .whisperKit
            }
            // After 4 failures with WhisperKit, fall back to Apple SpeechAnalyzer (iOS 26+)
            if failures >= 4 {
                if #available(iOS 26, *) {
                    NSLog("[TranscriptionEngine] Falling back to Apple engine after %d WhisperKit failures", failures)
                    return .apple
                } else {
                    NSLog("[TranscriptionEngine] Giving up after %d failures (Apple engine requires iOS 26)", failures)
                    return .whisperKit // Will be caught by failure counter >= 6 in TranscriptionQueue
                }
            }
        }

        if failures >= 6 {
            // Give up
            NSLog("[TranscriptionEngine] Giving up on episode after %d failures", failures)
        }

        return engineType
    }

    // MARK: - Disk Space

    private func hasSufficientDiskSpace() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeSpace = attrs[.systemFreeSize] as? Int64 else { return true }
        return freeSpace > 50 * 1024 * 1024 // 50 MB minimum
    }

    // MARK: - Chapter/Music file helpers

    @objc func chaptersJSONURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_chapters.json")
    }

    @objc func musicTimelineURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_music.json")
    }

    private func removeChaptersJSON(for episodeHash: String) {
        try? FileManager.default.removeItem(at: chaptersJSONURL(for: episodeHash))
    }

    private func removeMusicTimeline(for episodeHash: String) {
        try? FileManager.default.removeItem(at: musicTimelineURL(for: episodeHash))
    }
}
