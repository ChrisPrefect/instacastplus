//
//  WhisperKitBackend.swift
//  Instacast
//
//  WhisperKit integration for on-device speech-to-text.
//  Simple lifecycle: download model → ready to transcribe.
//  CoreML compilation is handled automatically by the system and cached.
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

    // MARK: - Model State (synchronous, no actor hop)

    nonisolated func isModelDownloadedSync() -> Bool {
        return localModelFolder() != nil
    }

    nonisolated func modelSizeOnDiskSync() -> Int64 {
        guard let folder = localModelFolder() else { return 0 }
        let url = URL(fileURLWithPath: folder)
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

    private nonisolated func localModelFolder() -> String? {
        let modelName = WhisperKitBackend.resolvedModelName()
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelDir = docsDir.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(modelName)")
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path),
              contents.contains(where: { $0.hasSuffix(".mlmodelc") }) else {
            return nil
        }
        return modelDir.path
    }

    // MARK: - Download (includes CoreML compilation via WhisperKit init)

    func downloadModel() async throws {
        let modelName = WhisperKitBackend.resolvedModelName()
        NSLog("[WhisperKitBackend] Downloading and preparing model: %@", modelName)
        let wk = try await WhisperKit(model: modelName, verbose: false, logLevel: .none)
        whisperKit = wk // keep the ready instance
        NSLog("[WhisperKitBackend] Model ready: %@", modelName)
    }

    // MARK: - Get Instance (fast if model already downloaded)

    func getOrCreateWhisperKit() async throws -> WhisperKit {
        if let existing = whisperKit {
            return existing
        }
        guard let folder = localModelFolder() else {
            throw NSError(domain: "WhisperKitBackend", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Sprachmodell nicht installiert. Bitte in Einstellungen herunterladen."])
        }
        NSLog("[WhisperKitBackend] Loading model from: %@", folder)
        let wk = try await WhisperKit(modelFolder: folder, verbose: false, logLevel: .none)
        whisperKit = wk
        return wk
    }

    func prepareModel() async throws {
        let _ = try await getOrCreateWhisperKit()
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
        let modelName = WhisperKitBackend.resolvedModelName()
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelDir = docsDir.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(modelName)")
        try? FileManager.default.removeItem(at: modelDir)
        NSLog("[WhisperKitBackend] Model deleted")
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL, startOffset: Double, totalDuration: Double,
                    language: String?,
                    progress: @escaping @Sendable (Float) -> Void,
                    segmentCallback: @escaping @Sendable (ICTranscriptCue) -> Void) async throws -> [ICTranscriptCue] {

        let wk = try await getOrCreateWhisperKit()

        var options = DecodingOptions()
        if let lang = language, !lang.isEmpty {
            options.language = lang
        }
        // Always start from the beginning or resume point
        // clipTimestamps = [0] ensures WhisperKit processes from the start
        if startOffset > 5.0 {
            options.clipTimestamps = [Float(startOffset - 5.0)]
        } else {
            options.clipTimestamps = [0]
        }

        NSLog("[WhisperKitBackend] Transcribing %.0fs audio", totalDuration)

        nonisolated(unsafe) let whisper = wk
        let callback: TranscriptionCallback = { [progress, totalDuration] tp in
            let estimatedTime = Double(tp.windowId + 1) * 30.0
            if totalDuration > 0 {
                progress(min(Float(estimatedTime / totalDuration), 0.99))
            }
            return nil
        }

        let results = await whisper.transcribe(
            audioPaths: [audioURL.path],
            decodeOptions: options,
            callback: callback
        )

        var cues: [ICTranscriptCue] = []
        for resultArray in results {
            guard let transcriptionResults = resultArray else { continue }
            for result in transcriptionResults {
                for segment in result.segments {
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Skip empty or hallucinated segments (WhisperKit sometimes produces these during music)
                    if text.isEmpty { continue }
                    // Skip segments that are just punctuation or whitespace artifacts
                    if text.count <= 1 && !text.first!.isLetter { continue }
                    let cue = ICTranscriptCue(
                        start: Double(segment.start),
                        end: Double(segment.end),
                        text: text
                    )
                    cues.append(cue)
                    segmentCallback(cue)
                }
            }
        }
        progress(1.0)
        NSLog("[WhisperKitBackend] Done: %d cues", cues.count)
        return cues
    }
}
