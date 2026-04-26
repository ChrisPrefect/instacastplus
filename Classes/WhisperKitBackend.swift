//
//  WhisperKitBackend.swift
//  Instacast
//
//  WhisperKit integration for on-device speech-to-text.
//  Lifecycle: download model → load → transcribe.
//
//  Model storage: Application Support / huggingface (NOT Documents).
//  Reason: CoreML's specialized-model cache is keyed by .mlmodelc path + file metadata.
//  Models in Documents are iCloud-backed and user-visible; file metadata can shift
//  between launches, invalidating the cache and triggering 3-4 min recompile.
//  Application Support is the Apple-documented location for runtime-downloaded
//  .mlmodelc files (see "Downloading and Compiling a Model on the User's Device").
//

import Foundation
import AVFoundation
import WhisperKit

actor WhisperKitBackend {

    static let shared = WhisperKitBackend()

    private var whisperKit: WhisperKit?

    // MARK: - Model Name

    nonisolated static func resolvedModelName() -> String {
        let stored = UserDefaults.standard.string(forKey: "TranscriptionWhisperModel") ?? ""
        if stored.isEmpty {
            return TranscriptionEngine.recommendedWhisperModel()
        }
        // Migration from old names
        switch stored {
        case "openai_whisper-large-v3-v20240930_turbo": return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case "openai_whisper-small", "small": return "openai_whisper-small_216MB"
        default: return stored
        }
    }

    // MARK: - Paths

    /// Base directory for downloaded HuggingFace models. Application Support, not Documents.
    /// Passed as `downloadBase` to WhisperKit's HubApi so new downloads land here.
    private nonisolated static func whisperDownloadBase() -> URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = appSupport.appendingPathComponent("huggingface", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        // Exclude from iCloud / iTunes backups — ~600 MB that can be re-downloaded.
        var mutableBase = base
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableBase.setResourceValues(resourceValues)
        return base
    }

    private nonisolated static func modelRoot(in hub: URL) -> URL {
        hub.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    nonisolated static func modelFolderURL(modelName: String = WhisperKitBackend.resolvedModelName()) -> URL {
        modelRoot(in: whisperDownloadBase()).appendingPathComponent(modelName, isDirectory: true)
    }

    private nonisolated static func documentsModelFolderURL(modelName: String = WhisperKitBackend.resolvedModelName()) -> URL {
        let docsHub = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("huggingface", isDirectory: true)
        return modelRoot(in: docsHub).appendingPathComponent(modelName, isDirectory: true)
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var totalSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                }
            }
        }
        return totalSize
    }

    private nonisolated static func hasCompiledModelFiles(in folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "mlmodelc" {
                return true
            }
        }
        return false
    }

    private nonisolated static func originalModelSourceFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return []
        }
        var sourceFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            switch fileURL.pathExtension {
            case "mlmodelc":
                enumerator.skipDescendants()
            case "mlpackage":
                sourceFiles.append(fileURL)
                enumerator.skipDescendants()
            case "mlmodel":
                sourceFiles.append(fileURL)
            default:
                break
            }
        }
        return sourceFiles
    }

    private nonisolated static func removeOriginalModelSources(in folder: URL) {
        let sourceFiles = originalModelSourceFiles(in: folder)
        guard !sourceFiles.isEmpty else { return }

        guard hasCompiledModelFiles(in: folder) else {
            NSLog("[WhisperKitBackend] Keeping %d original model source file(s); no compiled .mlmodelc files remain",
                  sourceFiles.count)
            return
        }

        var removedCount = 0
        for sourceFile in sourceFiles {
            do {
                try FileManager.default.removeItem(at: sourceFile)
                removedCount += 1
            } catch {
                NSLog("[WhisperKitBackend] Failed to remove original model source %@: %@",
                      sourceFile.path, error.localizedDescription)
            }
        }

        if removedCount > 0 {
            NSLog("[WhisperKitBackend] Removed %d original model source file(s)", removedCount)
            ICDiagnosticLogger.shared.logEvent("model", message: "Whisper-Modell-Quelldateien entfernt", metadata: [
                "modelFolder": folder.path,
                "removedCount": removedCount,
            ] as NSDictionary)
        }
    }

    /// One-time migration: move any model previously downloaded to Documents/huggingface
    /// over to Application Support/huggingface. Migration is per model directory; an
    /// already-migrated small model must not cause an old large model to be deleted.
    /// Called lazily from `localModelFolder()`.
    private nonisolated static func migrateFromDocumentsIfNeeded() {
        let fm = FileManager.default
        let docsHub = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("huggingface", isDirectory: true)
        guard fm.fileExists(atPath: docsHub.path) else { return }

        let newHub = whisperDownloadBase()
        let oldRoot = modelRoot(in: docsHub)
        let newRoot = modelRoot(in: newHub)
        guard fm.fileExists(atPath: oldRoot.path) else {
            return
        }

        do {
            try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
            let modelNames = try fm.contentsOfDirectory(atPath: oldRoot.path)
            var movedCount = 0
            var removedDuplicateCount = 0
            for name in modelNames {
                let src = oldRoot.appendingPathComponent(name, isDirectory: true)
                let dst = newRoot.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: src)
                    removedDuplicateCount += 1
                } else {
                    try fm.moveItem(at: src, to: dst)
                    movedCount += 1
                }
            }
            try? fm.removeItem(at: docsHub)
            NSLog("[WhisperKitBackend] Migrated %d model(s), removed %d duplicate(s) from Documents → Application Support",
                  movedCount, removedDuplicateCount)
        } catch {
            NSLog("[WhisperKitBackend] Migration failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Model State (synchronous, no actor hop)

    nonisolated func isModelDownloadedSync() -> Bool {
        return localModelFolder() != nil
    }

    nonisolated func isModelDownloadedSync(modelName: String) -> Bool {
        return localModelFolder(modelName: modelName) != nil
    }

    nonisolated func modelSizeOnDiskSync() -> Int64 {
        return modelSizeOnDiskSync(modelName: WhisperKitBackend.resolvedModelName())
    }

    nonisolated func modelSizeOnDiskSync(modelName: String) -> Int64 {
        if let folder = localModelFolder(modelName: modelName) {
            return WhisperKitBackend.directorySize(at: URL(fileURLWithPath: folder))
        }
        // During download the final .mlmodelc may not exist yet, but the settings UI still
        // needs to show byte progress for the partially-populated model directory.
        return WhisperKitBackend.directorySize(at: WhisperKitBackend.modelFolderURL(modelName: modelName))
    }

    private nonisolated func localModelFolder(modelName: String = WhisperKitBackend.resolvedModelName()) -> String? {
        WhisperKitBackend.migrateFromDocumentsIfNeeded()
        let modelDir = WhisperKitBackend.modelFolderURL(modelName: modelName)
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path),
              contents.contains(where: { $0.hasSuffix(".mlmodelc") }) else {
            return nil
        }
        return modelDir.path
    }

    // MARK: - Compute Options

    /// Compute options for inference. Text decoder uses ANE (fastest for autoregressive
    /// decoding), audio encoder uses GPU (fastest per-window encode). Mel is small enough
    /// that GPU is fine. Prefill is tiny and runs on CPU.
    ///
    /// First-time model load takes 3-4 minutes for large-v3-turbo because CoreML does
    /// Metal kernel AOT compilation. The compiled artifacts are then cached by CoreML
    /// in a system directory (purgeable) and restored on subsequent loads — provided the
    /// .mlmodelc file metadata does not change. This is why we store models in
    /// Application Support (stable metadata, not iCloud-backed) rather than Documents.
    private static func inferenceComputeOptions() -> ModelComputeOptions {
        return ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: .cpuAndGPU,
            textDecoderCompute: .cpuAndNeuralEngine,
            prefillCompute: .cpuOnly
        )
    }

    private nonisolated static func wrappedModelLoadError(_ error: Error) -> NSError {
        let underlyingDescription = modelLoadErrorDescription(error)
        let description: String
        if underlyingDescription.contains("Unable to mmap file") || underlyingDescription.contains("weight.bin") {
            description = NSLocalizedString("Core ML konnte die Modellgewichte nicht in den Speicher einblenden. Das deutet auf ein mmap-, Speicher- oder Datei-Leseproblem hin.", comment: "")
        } else {
            description = NSLocalizedString("Sprachmodell konnte nicht geladen werden. Bitte Modell löschen und neu herunterladen.", comment: "")
        }
        return NSError(
            domain: "WhisperKitBackend",
            code: 5,
            userInfo: [
                NSLocalizedDescriptionKey: description,
                NSUnderlyingErrorKey: error,
            ]
        )
    }

    private nonisolated static func modelLoadErrorDescription(_ error: Error) -> String {
        var descriptions = [error.localizedDescription]
        var underlyingError = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        while let current = underlyingError {
            descriptions.append(current.localizedDescription)
            underlyingError = (current as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        }
        return descriptions.joined(separator: "\n")
    }

    private nonisolated static func userVisibleStatus(fromWhisperLog message: String) -> String? {
        if message.contains("Loading feature extractor") {
            return NSLocalizedString("Modell wird vorbereitet.", comment: "")
        }
        if message.contains("Loading text decoder prefill data") {
            return NSLocalizedString("Modell wird vorbereitet.", comment: "")
        }
        if message.contains("Loading text decoder") {
            return NSLocalizedString("Modell wird vorbereitet.", comment: "")
        }
        if message.contains("Loading audio encoder") {
            return NSLocalizedString("Modell wird vorbereitet.", comment: "")
        }
        if message.contains("Loading tokenizer") {
            return NSLocalizedString("Modell wird vorbereitet.", comment: "")
        }
        if message.contains("Starting pipeline at") {
            return NSLocalizedString("Transkription läuft.", comment: "")
        }
        if message.contains("Decoding Seek:") { return nil }
        if message.contains("Found first token at") {
            return nil
        }
        return nil
    }

    private func installStatusLogger(on wk: WhisperKit,
                                     statusUpdate: @escaping @Sendable (String) -> Void) {
        wk.loggingCallback { message in
            if let status = WhisperKitBackend.userVisibleStatus(fromWhisperLog: message) {
                statusUpdate(status)
            }
        }
    }

    /// Overwrite the per-instance logging callback with a no-op so a stale closure
    /// (capturing a cancelled episode's detail sink) can't keep firing notifications
    /// between operations. The next call to installStatusLogger(on:) replaces this.
    private func clearStatusLogger(on wk: WhisperKit) {
        wk.loggingCallback { _ in }
    }

    private func ensureModelLoaded(_ wk: WhisperKit,
                                   statusUpdate: @escaping @Sendable (String) -> Void) async throws -> WhisperKit {
        guard wk.modelState != .loaded else {
            return wk
        }

        NSLog("[WhisperKitBackend] Existing WhisperKit instance in state %@, loading models now",
              String(describing: wk.modelState))
        statusUpdate(NSLocalizedString("Modell wird vorbereitet.", comment: ""))
        installStatusLogger(on: wk, statusUpdate: statusUpdate)
        do {
            nonisolated(unsafe) let whisper = wk
            try await whisper.loadModels()
        } catch {
            throw WhisperKitBackend.wrappedModelLoadError(error)
        }

        return wk
    }

    private nonisolated static func transcriptCue(from segment: TranscriptionSegment,
                                                  clipStart: Double) -> ICTranscriptCue? {
        let text = cleanedSegmentText(segment.text)
        // Skip empty or hallucinated segments (WhisperKit sometimes produces these during music)
        if text.isEmpty { return nil }
        // Skip segments that are just punctuation or whitespace artifacts
        if text.count <= 1 && !text.first!.isLetter { return nil }

        return ICTranscriptCue(
            start: Double(segment.start) + clipStart,
            end: Double(segment.end) + clipStart,
            text: text
        )
    }

    private nonisolated static func cleanedSegmentText(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<\|[^>]+\|>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func deliveredSegmentKey(for cue: ICTranscriptCue) -> String {
        let startMilliseconds = Int64((cue.start * 1000).rounded())
        let endMilliseconds = Int64((cue.end * 1000).rounded())
        return "\(startMilliseconds)-\(endMilliseconds)-\(cue.text)"
    }

    // MARK: - Download (includes CoreML compilation via WhisperKit init)

    func downloadModel(statusUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try await downloadModel(modelName: WhisperKitBackend.resolvedModelName(), statusUpdate: statusUpdate)
    }

    func downloadModel(modelName: String,
                       statusUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let base = WhisperKitBackend.whisperDownloadBase()
        NSLog("[WhisperKitBackend] Downloading and preparing model: %@ → %@", modelName, base.path)
        ICDiagnosticLogger.shared.logEvent("model", message: "Whisper-Modell-Download gestartet", metadata: [
            "modelName": modelName,
            "downloadBase": base.path,
        ] as NSDictionary)
        statusUpdate(NSLocalizedString("Whisper-Modell wird heruntergeladen und geöffnet.", comment: ""))
        let previousLogger = Logging.shared.loggingCallback
        Logging.shared.loggingCallback = { message in
            if let status = WhisperKitBackend.userVisibleStatus(fromWhisperLog: message) {
                statusUpdate(status)
            }
        }
        defer {
            Logging.shared.loggingCallback = previousLogger
        }
        let wk = try await WhisperKit(
            model: modelName,
            downloadBase: base,
            computeOptions: WhisperKitBackend.inferenceComputeOptions(),
            verbose: true,
            logLevel: .debug,
            prewarm: true,
            load: false
        )
        statusUpdate(NSLocalizedString("Whisper-Modell vorgewärmt.", comment: ""))
        WhisperKitBackend.removeOriginalModelSources(in: WhisperKitBackend.modelFolderURL(modelName: modelName))
        installStatusLogger(on: wk, statusUpdate: statusUpdate)
        nonisolated(unsafe) let whisper = wk
        try await whisper.loadModels()
        whisperKit = wk // keep the ready instance
        // Drop the per-instance callback now that loading is done — the closure captures
        // this caller's statusUpdate, and if we leave it in place WhisperKit's internal
        // log lines between operations would keep firing notifications for an already-
        // finished download context.
        clearStatusLogger(on: wk)
        NSLog("[WhisperKitBackend] Model ready: %@", modelName)
        ICDiagnosticLogger.shared.logEvent("model", message: "Whisper-Modell bereit", metadata: [
            "modelName": modelName,
            "downloadBase": base.path,
            "bytesOnDisk": WhisperKitBackend.directorySize(at: WhisperKitBackend.modelFolderURL(modelName: modelName)),
        ] as NSDictionary)
    }

    // MARK: - Get Instance (fast if model already downloaded)

    func getOrCreateWhisperKit(statusUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws -> WhisperKit {
        if let existing = whisperKit {
            return try await ensureModelLoaded(existing, statusUpdate: statusUpdate)
        }
        guard let folder = localModelFolder() else {
            throw NSError(domain: "WhisperKitBackend", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Sprachmodell nicht installiert. Bitte in Einstellungen herunterladen."])
        }
        // Log folder contents and file mtimes — if the mtime changes between launches,
        // CoreML treats the .mlmodelc as "new" and re-specializes it.
        let folderURL = URL(fileURLWithPath: folder)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let memBefore = ProcessInfo.processInfo.physicalMemory
        let freeDisk = (try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()))?[.systemFreeSize] as? Int64 ?? 0
        NSLog("[WhisperKitBackend] Loading model from: %@ (%d files)", folder, contents.count)
        NSLog("[WhisperKitBackend] Device RAM: %llu MB, free disk: %lld MB",
              memBefore / 1024 / 1024, freeDisk / 1024 / 1024)
        statusUpdate(NSLocalizedString("Modell wird vorbereitet.", comment: ""))
        // Print mtime for each .mlmodelc so we can see if it's stable between launches.
        for file in contents where file.hasSuffix(".mlmodelc") {
            let fileURL = folderURL.appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date {
                NSLog("[WhisperKitBackend]   %@ mtime=%@", file, mtime as NSDate)
            }
        }
        let startTime = CFAbsoluteTimeGetCurrent()
        ICDiagnosticLogger.shared.logEvent("model", message: "Whisper-Modell-Load gestartet", metadata: [
            "modelFolder": folder,
            "fileCount": contents.count,
            "freeDiskBytes": freeDisk,
            "physicalMemoryBytes": memBefore,
        ] as NSDictionary)

        NSLog("[WhisperKitBackend] Starting WhisperKit init...")
        let previousLogger = Logging.shared.loggingCallback
        Logging.shared.loggingCallback = { message in
            if let status = WhisperKitBackend.userVisibleStatus(fromWhisperLog: message) {
                statusUpdate(status)
            }
        }
        defer {
            Logging.shared.loggingCallback = previousLogger
        }
        let wk: WhisperKit
        do {
            wk = try await WhisperKit(
                modelFolder: folder,
                computeOptions: WhisperKitBackend.inferenceComputeOptions(),
                verbose: true,
                logLevel: .debug,
                prewarm: true,
                load: false
            )
            statusUpdate(NSLocalizedString("Whisper-Modell vorgewärmt.", comment: ""))
            WhisperKitBackend.removeOriginalModelSources(in: folderURL)
            installStatusLogger(on: wk, statusUpdate: statusUpdate)
            nonisolated(unsafe) let whisper = wk
            try await whisper.loadModels()
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            NSLog("[WhisperKitBackend] Model loading FAILED after %.1fs: %@", elapsed, error.localizedDescription)
            throw WhisperKitBackend.wrappedModelLoadError(error)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        NSLog("[WhisperKitBackend] Model loaded in %.1fs", elapsed)
        ICDiagnosticLogger.shared.logEvent("model", message: "WhisperKit-Load beendet", metadata: [
            "modelFolder": folder,
            "elapsedSeconds": String(format: "%.1f", elapsed),
        ] as NSDictionary)
        whisperKit = wk
        return wk
    }

    func prepareModel(statusUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        ICDiagnosticLogger.shared.logEvent("model", message: "prepareModel aufgerufen", metadata: [
            "modelName": WhisperKitBackend.resolvedModelName(),
        ] as NSDictionary)
        let wk = try await getOrCreateWhisperKit(statusUpdate: statusUpdate)
        // Release the per-instance callback so a stale closure (capturing this episode's
        // detail sink) can't keep firing between prepareModel and the next transcribe.
        clearStatusLogger(on: wk)
    }

    func prepareModel(modelName: String,
                      statusUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let oldModelName = UserDefaults.standard.string(forKey: "TranscriptionWhisperModel")
        if oldModelName != modelName {
            whisperKit = nil
            UserDefaults.standard.set(modelName, forKey: "TranscriptionWhisperModel")
        }
        defer {
            if let oldModelName, oldModelName != modelName {
                UserDefaults.standard.set(oldModelName, forKey: "TranscriptionWhisperModel")
                whisperKit = nil
            }
        }

        ICDiagnosticLogger.shared.logEvent("model", message: "prepareModel aufgerufen", metadata: [
            "modelName": modelName,
        ] as NSDictionary)
        let wk = try await getOrCreateWhisperKit(statusUpdate: statusUpdate)
        clearStatusLogger(on: wk)
    }

    // MARK: - Memory Management

    /// Release the in-memory WhisperKit instance to free ~200-600 MB.
    /// Called after transcription queue completes or on memory warning.
    func releaseModel() {
        if whisperKit != nil {
            whisperKit = nil
            NSLog("[WhisperKitBackend] Model released from memory")
        }
    }

    // MARK: - Delete

    func deleteModel() {
        whisperKit = nil
        deleteModel(modelName: WhisperKitBackend.resolvedModelName())
    }

    func deleteModel(modelName: String) {
        whisperKit = nil
        try? FileManager.default.removeItem(at: WhisperKitBackend.modelFolderURL(modelName: modelName))
        // Also clean up any stale Documents copy (pre-migration).
        try? FileManager.default.removeItem(at: WhisperKitBackend.documentsModelFolderURL(modelName: modelName))
        NSLog("[WhisperKitBackend] Model deleted")
        ICDiagnosticLogger.shared.logEvent("model", message: "Whisper-Modell gelöscht", metadata: [
            "modelName": modelName,
            "applicationSupportPath": WhisperKitBackend.modelFolderURL(modelName: modelName).path,
            "legacyDocumentsPath": WhisperKitBackend.documentsModelFolderURL(modelName: modelName).path,
        ] as NSDictionary)
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL, startOffset: Double, totalDuration: Double,
                    language: String?,
                    statusUpdate: @escaping @Sendable (String) -> Void = { _ in },
                    progress: @escaping @Sendable (Float) -> Void,
                    segmentCallback: @escaping @Sendable (ICTranscriptCue) -> Void) async throws -> [ICTranscriptCue] {

        let wk = try await getOrCreateWhisperKit(statusUpdate: statusUpdate)
        installStatusLogger(on: wk, statusUpdate: statusUpdate)
        defer {
            // Clear the per-instance callback once transcription finishes so it can't
            // outlive the episode's detail sink and fire notifications for a stale context.
            clearStatusLogger(on: wk)
        }

        var options = DecodingOptions()
        if let lang = language, !lang.isEmpty {
            options.language = lang
        }

        // Resume: trim audio samples to the range [startOffset-5s, end] and pass
        // them as a raw float array. clipTimestamps is NOT a seek — WhisperKit's
        // audio encoder still processes the full file when clipTimestamps is set.
        // Loading only the needed slice is the only way to actually save time.
        let clipStart = max(0.0, startOffset - 5.0)
        let audioArray: [Float]
        do {
            statusUpdate(NSLocalizedString("Transkription wird vorbereitet.", comment: ""))
            audioArray = try AudioProcessor.loadAudioAsFloatArray(
                fromPath: audioURL.path,
                startTime: clipStart,
                endTime: nil
            )
        } catch {
            throw NSError(domain: "WhisperKitBackend", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Audiodatei konnte nicht geladen werden: \(error.localizedDescription)"])
        }

        let loadedDuration = Double(audioArray.count) / Double(WhisperKit.sampleRate)
        NSLog("[WhisperKitBackend] Transcribing %.0fs audio (clip start %.0fs, loaded %.0fs of samples)",
              totalDuration, clipStart, loadedDuration)
        ICDiagnosticLogger.shared.logEvent("whisper", message: "Whisper-Transkription gestartet", metadata: [
            "audioPath": audioURL.path,
            "clipStartSeconds": String(format: "%.1f", clipStart),
            "loadedDurationSeconds": String(format: "%.1f", loadedDuration),
            "totalDurationSeconds": String(format: "%.1f", totalDuration),
        ] as NSDictionary)
        statusUpdate(NSLocalizedString("Transkription läuft.", comment: ""))

        // Progress is reported per segment below. WindowId-based progress would be
        // unreliable when audio was trimmed, so we don't use the window callback for UI.
        // `segment.start` / `segment.end` are relative to the trimmed audio's t=0 —
        // we add clipStart to get absolute time within the original audio.
        let callback: TranscriptionCallback = { tp in
            NSLog("[WhisperKitBackend] Window %d complete", tp.windowId)
            return nil
        }

        var deliveredSegmentKeys = Set<String>()
        func deliverSegmentIfNeeded(_ cue: ICTranscriptCue) {
            let key = WhisperKitBackend.deliveredSegmentKey(for: cue)
            guard deliveredSegmentKeys.insert(key).inserted else { return }

            segmentCallback(cue)

            // Report absolute progress from the segment end position.
            if totalDuration > 0 {
                let p = min(Float(cue.end / totalDuration), 0.99)
                progress(p)
            }
        }

        let liveSegmentCallback: SegmentDiscoveryCallback = { segments in
            for segment in segments {
                if let cue = WhisperKitBackend.transcriptCue(from: segment, clipStart: clipStart) {
                    deliverSegmentIfNeeded(cue)
                }
            }
        }

        // WhisperKit is a non-Sendable class. Calling its async `transcribe` from this
        // actor would require sending `wk` across the isolation boundary, which Swift 6
        // flags as a data-race risk. We only use one WhisperKit instance per actor and
        // serialize all access through the actor, so the transfer is safe in practice.
        nonisolated(unsafe) let whisper = wk
        let results = try await whisper.transcribe(
            audioArray: audioArray,
            decodeOptions: options,
            callback: callback,
            segmentCallback: liveSegmentCallback
        )

        var cues: [ICTranscriptCue] = []
        for result in results {
            for segment in result.segments {
                if let cue = WhisperKitBackend.transcriptCue(from: segment, clipStart: clipStart) {
                    cues.append(cue)
                    deliverSegmentIfNeeded(cue)
                }
            }
        }
        progress(1.0)
        NSLog("[WhisperKitBackend] Done: %d cues", cues.count)
        ICDiagnosticLogger.shared.logEvent("whisper", message: "Whisper-Transkription abgeschlossen", metadata: [
            "audioPath": audioURL.path,
            "cueCount": cues.count,
        ] as NSDictionary)
        return cues
    }
}
