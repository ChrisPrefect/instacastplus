//
//  ChapterGenerator.swift
//  Instacast
//
//  Auto-generates chapters and detects sponsor segments from transcripts
//  using Apple Foundation Models or downloaded local GGUF models via llama.cpp.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Foundation Models Generable Types

#if canImport(FoundationModels)

/// Structured output schema for Foundation Models chapter generation.
/// Using @Generable gives the LLM a typed response format — no fragile JSON parsing.
@available(iOS 26, *)
@Generable
struct GeneratedChaptersList {
    @Guide(description: "Liste aller Kapitel, sortiert nach Startzeit.")
    let chapters: [GeneratedChapterOut]
}

@available(iOS 26, *)
@Generable
struct GeneratedChapterOut {
    @Guide(description: "Startzeit des Kapitels in Sekunden ab Podcast-Anfang (Ganzzahl).")
    let startSeconds: Int

    @Guide(description: "Endzeit des Kapitels in Sekunden ab Podcast-Anfang (Ganzzahl). Das end eines Kapitels ist der start des nächsten Kapitels.")
    let endSeconds: Int

    @Guide(description: "Kurzer beschreibender Kapitel-Titel in der Sprache des Podcasts. Bei Werbe- und Sponsoring-Kapiteln als 'Sponsor: MARKENNAME'.")
    let title: String

    @Guide(description: "true wenn dieses Kapitel ein Werbe- oder Sponsoring-Segment ist (brought to you by, sponsored by, presented by, powered by, Rabattcode, Promo-Code, URL/Link, kostenlos testen).")
    let isSponsor: Bool
}

/// Pass 1 output: structured topic markers extracted from a transcript segment.
@available(iOS 26, *)
@Generable
struct GeneratedTopicMarkersList {
    @Guide(description: "Liste aller Themenwechsel in diesem Abschnitt, chronologisch sortiert.")
    let markers: [GeneratedTopicMarker]
}

@available(iOS 26, *)
@Generable
struct GeneratedTopicMarker {
    @Guide(description: "Zeitpunkt des Themenwechsels in Sekunden ab Podcast-Anfang (Ganzzahl).")
    let timeSeconds: Int

    @Guide(description: "Kurzer Titel des Themas in der Sprache des Podcasts. Bei Werbe-/Sponsoring-Segmenten als 'Sponsor: MARKENNAME'.")
    let title: String
}

#endif

// MARK: - Generated Chapter

@objc class ICGeneratedChapter: NSObject, @unchecked Sendable {
    @objc let start: Double
    @objc let end: Double
    @objc let title: String
    @objc let isSponsor: Bool

    @objc init(start: Double, end: Double, title: String, isSponsor: Bool) {
        self.start = start
        self.end = end
        self.title = title
        self.isSponsor = isSponsor
    }
}

// MARK: - Persisted Chapters

private struct ChaptersFile: Codable {
    let chapters: [ChapterEntry]

    struct ChapterEntry: Codable {
        let start: Double
        let end: Double
        let title: String
        let isSponsor: Bool
    }
}

// MARK: - ChapterGenerator

@MainActor
@objc class ChapterGenerator: NSObject {

    private static let _shared = ChapterGenerator()
    @objc static var shared: ChapterGenerator { _shared }
    private typealias TopicMarker = (time: Double, title: String)
    private static let maximumTopicExtractionSegmentDuration: Double = 300
    private static let maximumTopicExtractionCueCount = 45
    private static let localGenerationTimeoutNanoseconds: UInt64 = 600 * 1_000_000_000

    private final class ChapterDebugTrace {
        private let episodeHash: String?
        private let startedAt = Date()
        private let modelIdentifier: String
        private let modelTitle: String
        private let cueCount: Int
        private let existingChapterCount: Int
        private let musicSegments: [[String: Any]]
        private var engine = ""
        private var totalDuration: Double = 0
        private var segmentCount = 0
        private var pass1Segments: [[String: Any]] = []
        private var markerCountBeforeDedup = 0
        private var markerCountAfterDedup = 0
        private var finalMarkerCount = 0
        private var localFinalOutput: String?
        private var rawChapters: [[String: Any]] = []
        private var finalChapters: [[String: Any]] = []
        private var validation: [String: Any] = [:]
        private var performanceEvents: [[String: Any]] = []

        init(episodeHash: String?,
             model: ICDownloadableModel,
             cueCount: Int,
             musicSegments: [ICAudioSegment]?,
             existingChapters: [ICGeneratedChapter]?) {
            self.episodeHash = episodeHash
            self.modelIdentifier = model.identifier
            self.modelTitle = model.title
            self.cueCount = cueCount
            self.existingChapterCount = existingChapters?.count ?? 0
            self.musicSegments = (musicSegments ?? []).map { $0.dictionary }
        }

        func recordPreparation(engine: String, totalDuration: Double, segmentCount: Int) {
            self.engine = engine
            self.totalDuration = totalDuration
            self.segmentCount = segmentCount
            write(reason: "prepared")
        }

        func recordPass1Segment(index: Int,
                                start: Double,
                                end: Double,
                                cueCount: Int,
                                prompt: String,
                                promptCharacters: Int,
                                markerCount: Int,
                                markers: [TopicMarker],
                                rawOutput: String? = nil) {
            var entry: [String: Any] = [
                "index": index,
                "state": "completed",
                "completedAt": Self.timestampString(Date()),
                "start": start,
                "end": end,
                "cueCount": cueCount,
                "promptCharacters": promptCharacters,
                "promptPreview": Self.limited(prompt),
                "markerCount": markerCount,
                "markers": markers.map { ["time": $0.time, "title": $0.title] },
            ]
            if let rawOutput {
                entry["rawOutput"] = Self.limited(rawOutput)
            }
            if let existingIndex = pass1Segments.firstIndex(where: { ($0["index"] as? Int) == index }),
               let startedAt = pass1Segments[existingIndex]["startedAt"] {
                entry["startedAt"] = startedAt
            }
            upsertPass1Segment(entry, index: index)
            write(reason: "pass1-\(index)")
        }

        func recordPass1SegmentStarted(index: Int,
                                       start: Double,
                                       end: Double,
                                       cueCount: Int,
                                       prompt: String,
                                       promptCharacters: Int) {
            let entry: [String: Any] = [
                "index": index,
                "state": "started",
                "startedAt": Self.timestampString(Date()),
                "start": start,
                "end": end,
                "cueCount": cueCount,
                "promptCharacters": promptCharacters,
                "promptPreview": Self.limited(prompt),
                "markerCount": 0,
                "markers": [],
            ]
            upsertPass1Segment(entry, index: index)
            write(reason: "pass1-\(index)-started")
        }

        func recordMarkers(beforeDedup: Int, afterDedup: Int) {
            markerCountBeforeDedup = beforeDedup
            markerCountAfterDedup = afterDedup
            write(reason: "markers")
        }

        func recordFinalPrompt(markerCount: Int) {
            finalMarkerCount = markerCount
            write(reason: "final-prompt")
        }

        func recordLocalFinalOutput(_ output: String) {
            localFinalOutput = Self.limited(output)
            write(reason: "local-final-output")
        }

        func recordChapters(raw: [ICGeneratedChapter], final: [ICGeneratedChapter]) {
            rawChapters = raw.map(Self.chapterDictionary)
            finalChapters = final.map(Self.chapterDictionary)
            write(reason: "chapters")
        }

        func recordValidation(issue: String?, chapterCount: Int, topicMarkerCount: Int) {
            validation = [
                "passed": issue == nil,
                "issue": issue ?? "",
                "chapterCount": chapterCount,
                "topicMarkerCount": topicMarkerCount,
            ]
            recordPerformance(issue == nil ? "chapter-validation-passed" : "chapter-validation-failed",
                              metadata: [
                                "chapterCount": chapterCount,
                                "topicMarkerCount": topicMarkerCount,
                                "issue": issue ?? "",
                              ],
                              writeTrace: false)
            write(reason: issue == nil ? "validation-passed" : "validation-failed")
        }

        func recordPerformance(_ name: String, metadata: [String: Any], writeTrace: Bool = true) {
            var entry = metadata
            entry["name"] = name
            entry["timestamp"] = Self.timestampString(Date())
            performanceEvents.append(entry)

            var diagnosticMetadata: [String: Any] = metadata
            diagnosticMetadata["event"] = name
            if let episodeHash, !episodeHash.isEmpty {
                diagnosticMetadata["episodeHash"] = episodeHash
            }
            ICDiagnosticLogger.shared.logEvent("chapter-performance",
                                               message: name,
                                               metadata: diagnosticMetadata as NSDictionary)
            if writeTrace {
                write(reason: "performance-\(name)")
            }
        }

        func write(reason: String) {
            guard let episodeHash, !episodeHash.isEmpty else { return }
            let payload: [String: Any] = [
                "reason": reason,
                "startedAt": Self.timestampString(startedAt),
                "updatedAt": Self.timestampString(Date()),
                "episodeHash": episodeHash,
                "engine": engine,
                "modelIdentifier": modelIdentifier,
                "modelTitle": modelTitle,
                "cueCount": cueCount,
                "existingChapterCount": existingChapterCount,
                "totalDuration": totalDuration,
                "segmentCount": segmentCount,
                "musicSegments": musicSegments,
                "pass1Segments": pass1Segments,
                "markerCountBeforeDedup": markerCountBeforeDedup,
                "markerCountAfterDedup": markerCountAfterDedup,
                "finalMarkerCount": finalMarkerCount,
                "localFinalOutput": localFinalOutput ?? "",
                "rawChapters": rawChapters,
                "finalChapters": finalChapters,
                "validation": validation,
                "performanceEvents": performanceEvents,
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
                return
            }
            let url = ICTranscriptionPaths.transcriptCacheDirectory()
                .appendingPathComponent("\(episodeHash)_chapter_debug.json")
            do {
                try data.write(to: url, options: .atomic)
                ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                       message: "Chapter-Debug geschrieben",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "reason": reason,
                                                       ] as NSDictionary)
            } catch {
                ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                       message: "Chapter-Debug konnte nicht geschrieben werden",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "reason": reason,
                                                        "error": error.localizedDescription,
                                                       ] as NSDictionary)
            }
        }

        private static func chapterDictionary(_ chapter: ICGeneratedChapter) -> [String: Any] {
            [
                "start": chapter.start,
                "end": chapter.end,
                "title": chapter.title,
                "isSponsor": chapter.isSponsor,
            ]
        }

        private func upsertPass1Segment(_ entry: [String: Any], index: Int) {
            if let existingIndex = pass1Segments.firstIndex(where: { ($0["index"] as? Int) == index }) {
                pass1Segments[existingIndex] = entry
            } else {
                pass1Segments.append(entry)
            }
        }

        private static func limited(_ string: String) -> String {
            String(string.prefix(20_000))
        }

        private static func timestampString(_ date: Date) -> String {
            ISO8601DateFormatter().string(from: date)
        }
    }

    // MARK: - Availability

    /// Check if Apple Intelligence is available for chapter generation
    @objc static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Returns a description of why chapters are unavailable
    @objc static func unavailabilityReason() -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return NSLocalizedString("Apple Intelligence ist nicht aktiviert. Aktiviere es in Einstellungen > Apple Intelligence & Siri.", comment: "")
                case .deviceNotEligible:
                    return NSLocalizedString("Dieses Gerät unterstützt Apple Intelligence nicht.", comment: "")
                case .modelNotReady:
                    return NSLocalizedString("Apple Intelligence wird vorbereitet...", comment: "")
                @unknown default:
                    return NSLocalizedString("Apple Intelligence nicht verfügbar.", comment: "")
                }
            @unknown default:
                return NSLocalizedString("Apple Intelligence nicht verfügbar.", comment: "")
            }
        }
        #endif
        return NSLocalizedString("Dieses Gerät unterstützt die Kapitelerkennung nicht.", comment: "")
    }

    // MARK: - Chapter Generation

    /// Generate chapters from transcript cues and optional music timeline.
    /// Mode A: Full chapter generation (no existing chapters).
    @objc func generateChapters(fromCues cues: [ICTranscriptCue],
                                musicSegments: [ICAudioSegment]?,
                                status: ((String) -> Void)? = nil,
                                progress: ((Float, Int, Int) -> Void)? = nil,
                                completion: @escaping ([ICGeneratedChapter]?, Error?) -> Void) {
        Task {
            do {
                let chapters = try await self.generateChaptersAsync(
                    fromCues: cues,
                    musicSegments: musicSegments,
                    status: status,
                    progress: progress
                )
                await MainActor.run {
                    completion(chapters, nil)
                }
            } catch {
                await MainActor.run {
                    completion(nil, error)
                }
            }
        }
    }

    func generateChaptersAsync(fromCues cues: [ICTranscriptCue],
                               musicSegments: [ICAudioSegment]?,
                               status: ((String) -> Void)? = nil,
                               progress: ((Float, Int, Int) -> Void)? = nil,
                               debugEpisodeHash: String? = nil) async throws -> [ICGeneratedChapter] {
        guard !cues.isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No transcript cues provided"])
        }

        let selectedModel = ICDownloadableModelStore.selectedModel(for: .textToChapters)
        let debugTrace = ChapterDebugTrace(episodeHash: debugEpisodeHash,
                                           model: selectedModel,
                                           cueCount: cues.count,
                                           musicSegments: musicSegments,
                                           existingChapters: nil)
        if selectedModel.identifier == "apple-foundation-models" {
            guard ChapterGenerator.isAvailable() else {
                throw NSError(domain: "ChapterGenerator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"])
            }
            return try await self.generateWithLLM(cues: cues, musicSegments: musicSegments,
                                                  existingChapters: nil, status: status, progress: progress,
                                                  debugTrace: debugTrace)
        }

        return try await self.generateWithLocalGGUF(model: selectedModel,
                                                    cues: cues,
                                                    musicSegments: musicSegments,
                                                    existingChapters: nil,
                                                    status: status,
                                                    progress: progress,
                                                    debugTrace: debugTrace)
    }

    /// Detect sponsor segments from transcript using existing chapters as context.
    /// Returns only the detected sponsor chapters — caller must merge via `mergeSponsors(_:into:)`.
    @objc func detectSponsors(fromCues cues: [ICTranscriptCue],
                              existingChapters: [ICGeneratedChapter],
                              completion: @escaping ([ICGeneratedChapter]?, Error?) -> Void) {
        Task {
            do {
                let selectedModel = ICDownloadableModelStore.selectedModel(for: .textToChapters)
                let chapters: [ICGeneratedChapter]
                if selectedModel.identifier == "apple-foundation-models" {
                    guard ChapterGenerator.isAvailable() else {
                        throw NSError(domain: "ChapterGenerator", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"])
                    }
                    chapters = try await self.generateWithLLM(cues: cues, musicSegments: nil,
                                                              existingChapters: existingChapters,
                                                              debugTrace: nil)
                } else {
                    chapters = try await self.generateWithLocalGGUF(model: selectedModel,
                                                                    cues: cues,
                                                                    musicSegments: nil,
                                                                    existingChapters: existingChapters,
                                                                    debugTrace: nil)
                }
                await MainActor.run {
                    completion(chapters, nil)
                }
            } catch {
                await MainActor.run {
                    completion(nil, error)
                }
            }
        }
    }

    // MARK: - LLM Integration

    private func generateWithLLM(cues: [ICTranscriptCue],
                                 musicSegments: [ICAudioSegment]?,
                                 existingChapters: [ICGeneratedChapter]?,
                                 status: ((String) -> Void)? = nil,
                                 progress: ((Float, Int, Int) -> Void)? = nil,
                                 debugTrace: ChapterDebugTrace?) async throws -> [ICGeneratedChapter] {
        guard #available(iOS 26, *) else {
            throw NSError(domain: "ChapterGenerator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "iOS 26 required"])
        }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        let contextSize = model.contextSize
        // Reserve half for response
        let maxInputTokens = contextSize / 2

        NSLog("[ChapterGenerator] Context window: %d tokens, max input: %d tokens", contextSize, maxInputTokens)

        // Split transcript into segments that each fit the actual model context window.
        // The token check is the guardrail; character counts alone undercount Whisper markup
        // and non-English text badly enough to overflow Foundation Models.
        let segments = try await splitTranscriptIntoModelChunks(cues,
                                                                model: model,
                                                                maxInputTokens: maxInputTokens)
        let totalSegments = segments.count
        let totalDuration = max(cues.last?.end ?? 0, 1)
        debugTrace?.recordPreparation(engine: "foundation-models",
                                      totalDuration: totalDuration,
                                      segmentCount: totalSegments)

        NSLog("[ChapterGenerator] %d cues → %d segment(s), total duration %.0fs", cues.count, totalSegments, totalDuration)
        await MainActor.run {
            status?(NSLocalizedString("Transkript wird in verarbeitbare Abschnitte aufgeteilt.", comment: ""))
        }
        await MainActor.run { progress?(0.05, 0, totalSegments + 1) }

        // Pass 1: Extract topic markers via @Generable structured output.
        // The LLM returns a typed GeneratedTopicMarkersList — no string parsing needed.
        var topicMarkers: [TopicMarker] = []

        for (index, segment) in segments.enumerated() {
            guard !Task.isCancelled else { throw CancellationError() }

            let segStart = segment.first?.start ?? 0
            let segEnd = segment.last?.end ?? 0
            let prompt = buildTopicExtractionPrompt(cues: segment, segStart: segStart, segEnd: segEnd)

            NSLog("[ChapterGenerator] Pass 1 %d/%d [%@–%@]: %d cues, %d chars",
                  index + 1, totalSegments, formatTime(segStart), formatTime(segEnd), segment.count, prompt.count)
            await MainActor.run {
                status?(String(format: NSLocalizedString("Pass 1/2: Themenwechsel in Abschnitt %d von %d werden extrahiert.", comment: ""), index + 1, totalSegments))
            }
            guard await promptFitsContext(prompt, model: model, maxInputTokens: maxInputTokens) else {
                throw NSError(domain: "ChapterGenerator", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — ein Transkriptabschnitt passt nicht in das Kontextfenster."])
            }

            debugTrace?.recordPass1SegmentStarted(index: index + 1,
                                                  start: segStart,
                                                  end: segEnd,
                                                  cueCount: segment.count,
                                                  prompt: prompt,
                                                  promptCharacters: prompt.count)
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: GeneratedTopicMarkersList.self)
            NSLog("[ChapterGenerator] Pass 1 %d returned %d markers", index + 1, response.content.markers.count)

            var segmentMarkers: [TopicMarker] = []
            for m in response.content.markers {
                var t = Double(m.timeSeconds)
                // Clamp — the LLM occasionally hallucinates timestamps outside the segment range
                if t < segStart { t = segStart }
                if t > segEnd { t = segEnd }
                let title = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    let marker = (time: t, title: title)
                    topicMarkers.append(marker)
                    segmentMarkers.append(marker)
                }
            }
            debugTrace?.recordPass1Segment(index: index + 1,
                                           start: segStart,
                                           end: segEnd,
                                           cueCount: segment.count,
                                           prompt: prompt,
                                           promptCharacters: prompt.count,
                                           markerCount: segmentMarkers.count,
                                           markers: segmentMarkers)

            let p = Float(index + 1) / Float(totalSegments + 1) * 0.9 + 0.05
            await MainActor.run { progress?(p, index + 1, totalSegments + 1) }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        if topicMarkers.isEmpty {
            NSLog("[ChapterGenerator] Pass 1 produced no usable markers — aborting")
            throw NSError(domain: "ChapterGenerator", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — keine Themen erkannt."])
        }

        let markerCountBeforeDedup = topicMarkers.count
        topicMarkers.sort { $0.time < $1.time }
        topicMarkers = Self.deduplicatedMarkers(topicMarkers)
        debugTrace?.recordMarkers(beforeDedup: markerCountBeforeDedup,
                                  afterDedup: topicMarkers.count)

        // Pass 2: Consolidate topic markers into final chapter structure via @Generable.
        let finalMarkers = try await markersFittingFinalPrompt(markers: topicMarkers,
                                                               totalDuration: totalDuration,
                                                               musicSegments: musicSegments,
                                                               existingChapters: existingChapters,
                                                               model: model,
                                                               maxInputTokens: maxInputTokens,
                                                               status: status,
                                                               progress: progress,
                                                               progressTotal: totalSegments + 1)
        let finalPrompt = buildFinalChaptersPrompt(
            markers: finalMarkers, totalDuration: totalDuration,
            musicSegments: musicSegments, existingChapters: existingChapters)
        debugTrace?.recordFinalPrompt(markerCount: finalMarkers.count)

        NSLog("[ChapterGenerator] Pass 2: prompt %d chars from %d marker(s)", finalPrompt.count, finalMarkers.count)
        await MainActor.run {
            status?(NSLocalizedString("Pass 2/2: Kapitelmodell erstellt die finale JSON-Struktur. Das kann mehrere Minuten dauern.", comment: ""))
        }
        await MainActor.run { progress?(0.95, totalSegments, totalSegments + 1) }

        let session = LanguageModelSession()
        let response = try await session.respond(to: finalPrompt, generating: GeneratedChaptersList.self)
        NSLog("[ChapterGenerator] Pass 2 returned %d chapters", response.content.chapters.count)

        let rawChapters: [ICGeneratedChapter] = response.content.chapters
            .map { ICGeneratedChapter(start: Double($0.startSeconds),
                                      end: Double($0.endSeconds),
                                      title: $0.title,
                                      isSponsor: $0.isSponsor) }
        var chapters = Self.normalizedChapters(rawChapters,
                                               totalDuration: totalDuration,
                                               forceContinuousBoundaries: existingChapters == nil)
        if existingChapters == nil {
            chapters = Self.chaptersByAddingMusicBoundaryChapters(chapters,
                                                                  musicSegments: musicSegments,
                                                                  transcriptCues: cues,
                                                                  transcriptDuration: totalDuration)
        }
        debugTrace?.recordChapters(raw: rawChapters, final: chapters)
        chapters = try Self.validatedGeneratedChapters(chapters,
                                                       totalDuration: totalDuration,
                                                       topicMarkerCount: topicMarkers.count,
                                                       musicSegments: musicSegments,
                                                       transcriptCues: cues,
                                                       existingChapters: existingChapters,
                                                       debugTrace: debugTrace)

        NSLog("[ChapterGenerator] Final: %d chapters", chapters.count)

        await MainActor.run { progress?(1.0, totalSegments + 1, totalSegments + 1) }
        return chapters
        #else
        throw NSError(domain: "ChapterGenerator", code: 100,
                      userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelerkennung benötigt iOS 26. Bitte aktualisiere auf iOS 26 wenn verfügbar.", comment: "")])
        #endif
    }

    // MARK: - Local GGUF Integration

    private struct LocalTopicMarkersResponse: Decodable {
        let markers: [LocalTopicMarker]
    }

    private struct LocalTopicMarker: Decodable {
        let timeSeconds: Int
        let title: String
    }

    private struct LocalChaptersResponse: Decodable {
        let chapters: [LocalChapter]
    }

    private struct LocalChapter: Decodable {
        let startSeconds: Int
        let endSeconds: Int
        let title: String
        let isSponsor: Bool
    }

    private static let localChapterSystemPrompt = """
    Du bist ein praeziser Podcast-Kapitelgenerator. Arbeite nur mit den angegebenen Zeiten und Texten. Erfinde keine Inhalte. Antworte ausschliesslich mit validem JSON, ohne Markdown und ohne Erklaertext.
    """

    private func generateWithLocalGGUF(model: ICDownloadableModel,
                                       cues: [ICTranscriptCue],
                                       musicSegments: [ICAudioSegment]?,
                                       existingChapters: [ICGeneratedChapter]?,
                                       status: ((String) -> Void)? = nil,
                                       progress: ((Float, Int, Int) -> Void)? = nil,
                                       debugTrace: ChapterDebugTrace?) async throws -> [ICGeneratedChapter] {
        guard ICDownloadableModelStore.isDownloaded(model: model),
              let modelURL = ICDownloadableModelStore.modelFileURL(for: model),
              FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NSError(domain: "ChapterGenerator", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: "")])
        }

        status?(String(format: NSLocalizedString("%@ wird geladen.", comment: ""), model.title))
        progress?(0.01, 0, 1)

        let modelLoadStart = Date()
        let runner = try await Task.detached(priority: .userInitiated) {
            try LocalGGUFModelRunner.create(modelURL: modelURL)
        }.value
        let maxInputTokens = await runner.maxInputTokens
        NSLog("[ChapterGenerator] Local GGUF context max input: %d tokens", maxInputTokens)
        debugTrace?.recordPerformance("local-model-loaded",
                                      metadata: [
                                        "modelIdentifier": model.identifier,
                                        "modelTitle": model.title,
                                        "durationSeconds": String(format: "%.3f", -modelLoadStart.timeIntervalSinceNow),
                                        "maxInputTokens": maxInputTokens,
                                      ])

        let segments = try await splitTranscriptIntoLocalChunks(cues,
                                                                runner: runner,
                                                                maxInputTokens: maxInputTokens)
        let totalSegments = segments.count
        let totalDuration = max(cues.last?.end ?? 0, 1)
        debugTrace?.recordPreparation(engine: "local-gguf",
                                      totalDuration: totalDuration,
                                      segmentCount: totalSegments)
        debugTrace?.recordPerformance("local-chapter-started",
                                      metadata: [
                                        "cueCount": cues.count,
                                        "musicSegmentCount": musicSegments?.count ?? 0,
                                        "segmentCount": totalSegments,
                                        "totalDurationSeconds": String(format: "%.3f", totalDuration),
                                        "maxInputTokens": maxInputTokens,
                                        "existingChapterCount": existingChapters?.count ?? 0,
                                      ])
        var topicMarkers: [TopicMarker] = []

        status?(NSLocalizedString("Themenmarker werden aus Transkript und Musik abgeleitet.", comment: ""))
        progress?(0.05, 0, totalSegments + 1)

        for (index, segment) in segments.enumerated() {
            guard !Task.isCancelled else {
                await runner.cancel()
                throw CancellationError()
            }

            let segStart = segment.first?.start ?? 0
            let segEnd = segment.last?.end ?? 0
            let prompt = buildDeterministicMarkerDebugText(cues: segment, segStart: segStart, segEnd: segEnd)
            let segmentStart = Date()
            debugTrace?.recordPass1SegmentStarted(index: index + 1,
                                                  start: segStart,
                                                  end: segEnd,
                                                  cueCount: segment.count,
                                                  prompt: prompt,
                                                  promptCharacters: prompt.count)
            let segmentMarkers = deterministicLocalTopicMarkers(cues: segment,
                                                                musicSegments: musicSegments,
                                                                segmentStart: segStart,
                                                                segmentEnd: segEnd,
                                                                totalDuration: totalDuration)
            topicMarkers.append(contentsOf: segmentMarkers)
            debugTrace?.recordPass1Segment(index: index + 1,
                                           start: segStart,
                                           end: segEnd,
                                           cueCount: segment.count,
                                           prompt: prompt,
                                           promptCharacters: prompt.count,
                                           markerCount: segmentMarkers.count,
                                           markers: segmentMarkers)
            debugTrace?.recordPerformance("local-pass1-segment-derived",
                                          metadata: [
                                            "index": index + 1,
                                            "segmentCount": totalSegments,
                                            "cueCount": segment.count,
                                            "promptCharacters": prompt.count,
                                            "markerCount": segmentMarkers.count,
                                            "durationSeconds": String(format: "%.3f", -segmentStart.timeIntervalSinceNow),
                                          ])

            let p = Float(index + 1) / Float(totalSegments + 1) * 0.9 + 0.05
            progress?(p, index + 1, totalSegments + 1)
        }

        guard !Task.isCancelled else {
            await runner.cancel()
            throw CancellationError()
        }

        if topicMarkers.isEmpty {
            throw NSError(domain: "ChapterGenerator", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — keine Themen erkannt."])
        }

        let markerCountBeforeDedup = topicMarkers.count
        topicMarkers = Self.deduplicatedMarkers(topicMarkers)
        debugTrace?.recordMarkers(beforeDedup: markerCountBeforeDedup,
                                  afterDedup: topicMarkers.count)
        debugTrace?.recordPerformance("local-deterministic-markers",
                                      metadata: [
                                        "markerCountBeforeDedup": markerCountBeforeDedup,
                                        "markerCountAfterDedup": topicMarkers.count,
                                      ])
        let finalMarkers = try await localMarkersFittingFinalPrompt(markers: topicMarkers,
                                                                    totalDuration: totalDuration,
                                                                    musicSegments: musicSegments,
                                                                    existingChapters: existingChapters,
                                                                    runner: runner,
                                                                    maxInputTokens: maxInputTokens,
                                                                    status: status,
                                                                    progress: progress,
                                                                    progressTotal: totalSegments + 1)
        let finalPrompt = buildLocalFinalChaptersPrompt(markers: finalMarkers,
                                                        totalDuration: totalDuration,
                                                        musicSegments: musicSegments,
                                                        existingChapters: existingChapters)
        debugTrace?.recordFinalPrompt(markerCount: finalMarkers.count)

        NSLog("[ChapterGenerator] Local pass 2: prompt %d chars from %d marker(s)", finalPrompt.count, finalMarkers.count)
        let finalGenerationStart = Date()
        status?(NSLocalizedString("Pass 2/2: Kapitelmodell erstellt die finale JSON-Struktur. Das kann mehrere Minuten dauern.", comment: ""))
        progress?(0.95, totalSegments, totalSegments + 1)
        debugTrace?.recordPerformance("local-pass2-started",
                                      metadata: [
                                        "finalMarkerCount": finalMarkers.count,
                                        "promptCharacters": finalPrompt.count,
                                      ])

        let output: String
        do {
            output = try await generateLocalJSONObject(runner: runner,
                                                       prompt: finalPrompt,
                                                       grammar: .chapters,
                                                       maxNewTokens: existingChapters == nil ? 1_536 : 768)
        } catch {
            debugTrace?.recordPerformance("local-pass2-failed",
                                          metadata: [
                                            "finalMarkerCount": finalMarkers.count,
                                            "promptCharacters": finalPrompt.count,
                                            "durationSeconds": String(format: "%.3f", -finalGenerationStart.timeIntervalSinceNow),
                                            "error": error.localizedDescription,
                                          ])
            throw error
        }
        debugTrace?.recordLocalFinalOutput(output)
        let response = try decodeLocalJSON(LocalChaptersResponse.self, from: output)
        let rawChapters = response.chapters.map {
            ICGeneratedChapter(start: Double($0.startSeconds),
                               end: Double($0.endSeconds),
                               title: $0.title,
                               isSponsor: $0.isSponsor)
        }

        var chapters = Self.normalizedChapters(rawChapters,
                                               totalDuration: totalDuration,
                                               forceContinuousBoundaries: existingChapters == nil)
        if existingChapters == nil {
            chapters = Self.chaptersByAddingMusicBoundaryChapters(chapters,
                                                                  musicSegments: musicSegments,
                                                                  transcriptCues: cues,
                                                                  transcriptDuration: totalDuration)
        }
        debugTrace?.recordChapters(raw: rawChapters, final: chapters)
        debugTrace?.recordPerformance("local-pass2-completed",
                                      metadata: [
                                        "finalMarkerCount": finalMarkers.count,
                                        "promptCharacters": finalPrompt.count,
                                        "outputCharacters": output.count,
                                        "rawChapterCount": rawChapters.count,
                                        "finalChapterCount": chapters.count,
                                        "sponsorChapterCount": chapters.filter { $0.isSponsor }.count,
                                        "durationSeconds": String(format: "%.3f", -finalGenerationStart.timeIntervalSinceNow),
                                      ])
        chapters = try Self.validatedGeneratedChapters(chapters,
                                                       totalDuration: totalDuration,
                                                       topicMarkerCount: topicMarkers.count,
                                                       musicSegments: musicSegments,
                                                       transcriptCues: cues,
                                                       existingChapters: existingChapters,
                                                       debugTrace: debugTrace)

        guard !chapters.isEmpty || existingChapters != nil else {
            throw NSError(domain: "ChapterGenerator", code: 18,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — das Kapitelmodell hat keine Kapitel erzeugt."])
        }

        debugTrace?.recordPerformance("local-chapter-completed",
                                      metadata: [
                                        "chapterCount": chapters.count,
                                        "sponsorChapterCount": chapters.filter { $0.isSponsor }.count,
                                        "topicMarkerCount": topicMarkers.count,
                                        "segmentCount": totalSegments,
                                      ])
        progress?(1.0, totalSegments + 1, totalSegments + 1)
        return chapters
    }

    private func buildLocalTopicExtractionPrompt(cues: [ICTranscriptCue], segStart: Double, segEnd: Double) -> String {
        var prompt = buildTopicExtractionPrompt(cues: cues, segStart: segStart, segEnd: segEnd)
        prompt += "\nRegeln fuer lokale Erkennung:\n"
        prompt += "- Maximal 6 Marker pro Abschnitt.\n"
        prompt += "- Nur klare neue Themen, keine Detailwechsel innerhalb desselben Themas.\n"
        prompt += "- Nutze nur Zeitpunkte aus dem Transkript oder den Abschnittsanfang.\n"
        prompt += "\n\nAntworte ausschliesslich mit JSON in diesem Schema:\n"
        prompt += "{\"markers\":[{\"timeSeconds\":123,\"title\":\"Kurzer Titel\"}]}\n"
        prompt += "Nutze timeSeconds als Ganzzahl ab Podcast-Anfang."
        return prompt
    }

    private func buildDeterministicMarkerDebugText(cues: [ICTranscriptCue], segStart: Double, segEnd: Double) -> String {
        var text = "Deterministische Themenmarker (\(formatTime(segStart))-\(formatTime(segEnd))):\n"
        for cue in cues {
            text += "[\(formatTime(cue.start))] \(cue.text)\n"
        }
        return text
    }

    private func deterministicLocalTopicMarkers(cues: [ICTranscriptCue],
                                                musicSegments: [ICAudioSegment]?,
                                                segmentStart: Double,
                                                segmentEnd: Double,
                                                totalDuration: Double) -> [TopicMarker] {
        var markers: [TopicMarker] = []
        let speechCues = cues
            .filter { !Self.isMusicOnlyCue($0) }
            .sorted { $0.start < $1.start }
        var lastSpeechMarker = -Double.infinity
        let markerInterval = 90.0

        for cue in speechCues {
            let title = cue.start >= totalDuration - 70 || Self.isOutroCueText(cue.text)
                ? "Outro"
                : Self.deterministicMarkerTitle(from: cue.text)
            guard !title.isEmpty else { continue }
            if markers.isEmpty || cue.start - lastSpeechMarker >= markerInterval {
                markers.append((time: max(cue.start, segmentStart), title: title))
                lastSpeechMarker = cue.start
            }
        }

        let earlyIntroWindow = 90.0
        for segment in (musicSegments ?? []) where segment.type == "music" && segment.end > segment.start {
            guard segment.end >= segmentStart && segment.start <= segmentEnd else { continue }
            let duration = segment.end - segment.start
            let title: String
            if segment.start <= earlyIntroWindow && duration >= 4 {
                title = "Intro"
            } else if segment.end >= totalDuration - 20 && duration >= 4 {
                title = "Outro"
            } else if duration >= 4 {
                title = "Jingle"
            } else {
                continue
            }
            markers.append((time: max(segment.start, segmentStart), title: title))
        }

        return Self.deduplicatedMarkers(markers)
    }

    private static func deterministicMarkerTitle(from text: String) -> String {
        let leadingMusicCuePrefixPattern = #"(?i)^(musik|music|musica|música|musique)\s+"#
        let cleaned = text.replacingOccurrences(
            of: #"<\|[^>]+\|>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Spektrum produced mixed cues like "Musik Ja, ..."; keep the speech and remove only the leading marker word.
        .replacingOccurrences(of: leadingMusicCuePrefixPattern, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let prefix = isSponsorCueText(cleaned) ? "Sponsor: " : ""
        let words = cleaned.split(separator: " ")
        let snippet = words.prefix(16).joined(separator: " ")
        return String((prefix + snippet).prefix(140))
    }

    private static func isSponsorCueText(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        let compact = normalized.replacingOccurrences(of: #"[^a-z0-9]+"#,
                                                       with: " ",
                                                       options: .regularExpression)
        let explicitTerms = [
            "sponsor",
            "sponsoring",
            "werbepartner",
            "werbung fuer",
            "werbung fur",
            "anzeige von",
            "praesentiert von",
            "prasentiert von",
            "presented by",
            "ad break",
            "rabattcode",
            "gutscheincode",
        ]
        return explicitTerms.contains { compact.contains($0) }
    }

    private static func isOutroCueText(_ text: String) -> Bool {
        let normalized = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        let phrases = [
            "das war",
            "vielen dank fürs zuhoren",
            "vielen dank euch fürs zuhoren",
            "bis dahin",
            "macht's gut",
            "macht es gut",
            "tschuss",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private func buildLocalFinalChaptersPrompt(markers: [TopicMarker],
                                               totalDuration: Double,
                                               musicSegments: [ICAudioSegment]?,
                                               existingChapters: [ICGeneratedChapter]?) -> String {
        var prompt = buildFinalChaptersPrompt(markers: markers,
                                              totalDuration: totalDuration,
                                              musicSegments: musicSegments,
                                              existingChapters: existingChapters)
        prompt += "\n\nAntworte ausschliesslich mit JSON in diesem Schema:\n"
        prompt += "{\"chapters\":[{\"startSeconds\":0,\"endSeconds\":123,\"title\":\"Kurzer Titel\",\"isSponsor\":false}]}\n"
        prompt += "Bei Intro-/Outro-Musik ohne Sprache sollen Titel exakt \"Intro\" oder \"Outro\" sein."
        return prompt
    }

    private func buildLocalMarkerConsolidationPrompt(markers: [TopicMarker],
                                                     totalDuration: Double,
                                                     round: Int) -> String {
        var prompt = buildMarkerConsolidationPrompt(markers: markers,
                                                    totalDuration: totalDuration,
                                                    round: round)
        prompt += "\n\nAntworte ausschliesslich mit JSON in diesem Schema:\n"
        prompt += "{\"markers\":[{\"timeSeconds\":123,\"title\":\"Kurzer Titel\"}]}"
        return prompt
    }

    private func localMarkersFittingFinalPrompt(markers: [TopicMarker],
                                                totalDuration: Double,
                                                musicSegments: [ICAudioSegment]?,
                                                existingChapters: [ICGeneratedChapter]?,
                                                runner: LocalGGUFModelRunner,
                                                maxInputTokens: Int,
                                                status: ((String) -> Void)?,
                                                progress: ((Float, Int, Int) -> Void)?,
                                                progressTotal: Int) async throws -> [TopicMarker] {
        var current = markers
        var round = 1

        while true {
            guard !Task.isCancelled else {
                await runner.cancel()
                throw CancellationError()
            }

            let finalPrompt = buildLocalFinalChaptersPrompt(markers: current,
                                                            totalDuration: totalDuration,
                                                            musicSegments: musicSegments,
                                                            existingChapters: existingChapters)
            if try await localPromptFitsContext(finalPrompt, runner: runner, maxInputTokens: maxInputTokens) {
                return current
            }

            guard existingChapters == nil else {
                throw NSError(domain: "ChapterGenerator", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "Sponsor-Erkennung ist für diese lange Folge zu umfangreich."])
            }

            var groups = splitMarkersIntoConsolidationChunks(current, maxPromptChars: max(maxInputTokens * 2, 500))
            NSLog("[ChapterGenerator] Local reducing %d marker(s) in round %d using %d group(s)",
                  current.count, round, groups.count)

            var reduced: [TopicMarker] = []
            var groupIndex = 0
            while groupIndex < groups.count {
                guard !Task.isCancelled else {
                    await runner.cancel()
                    throw CancellationError()
                }

                let group = groups[groupIndex]
                let prompt = buildLocalMarkerConsolidationPrompt(markers: group,
                                                                 totalDuration: totalDuration,
                                                                 round: round)
                if !(try await localPromptFitsContext(prompt, runner: runner, maxInputTokens: maxInputTokens)) {
                    guard group.count > 1 else {
                            throw NSError(domain: "ChapterGenerator", code: 15,
                                          userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — die Folge ist zu lang für dieses Kapitelmodell."])
                    }
                    let midpoint = group.count / 2
                    groups.replaceSubrange(groupIndex...groupIndex, with: [
                        Array(group[..<midpoint]),
                        Array(group[midpoint...])
                    ])
                    continue
                }

                status?(String(format: NSLocalizedString("Pass 2/2: Themenmarker werden verdichtet (Runde %d, Gruppe %d von %d).", comment: ""), round, groupIndex + 1, groups.count))
                progress?(0.95, max(0, progressTotal - 1), progressTotal)

                let output = try await generateLocalJSONObject(runner: runner,
                                                               prompt: prompt,
                                                               grammar: .markers,
                                                               maxNewTokens: 384)
                let response = try decodeLocalJSON(LocalTopicMarkersResponse.self, from: output)
                let groupStart = group.first?.time ?? 0
                let groupEnd = group.last?.time ?? totalDuration
                let groupMarkers = response.markers.compactMap { marker -> TopicMarker? in
                    let title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    let time = min(max(Double(marker.timeSeconds), groupStart), groupEnd)
                    return (time: time, title: title)
                }
                guard !groupMarkers.isEmpty else {
                    throw NSError(domain: "ChapterGenerator", code: 13,
                                  userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — Themen konnten nicht zusammengefasst werden."])
                }
                reduced.append(contentsOf: groupMarkers)
                groupIndex += 1
            }

            let next = Self.deduplicatedMarkers(reduced)
            guard next.count < current.count else {
                throw NSError(domain: "ChapterGenerator", code: 14,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — das Kapitelmodell konnte die Folge nicht verlässlich zusammenfassen."])
            }
            current = next
            round += 1
        }
    }

    private func splitTranscriptIntoLocalChunks(_ cues: [ICTranscriptCue],
                                                runner: LocalGGUFModelRunner,
                                                maxInputTokens: Int) async throws -> [[ICTranscriptCue]] {
        guard !cues.isEmpty else { return [] }

        var chunks: [[ICTranscriptCue]] = []
        var current: [ICTranscriptCue] = []

        for cue in cues {
            guard !Task.isCancelled else {
                await runner.cancel()
                throw CancellationError()
            }

            let candidate = current + [cue]
            let segStart = candidate.first?.start ?? 0
            let segEnd = candidate.last?.end ?? 0
            if !current.isEmpty,
               current.count >= Self.maximumTopicExtractionCueCount || segEnd - segStart > Self.maximumTopicExtractionSegmentDuration {
                chunks.append(current)
                current = [cue]
                let singlePrompt = buildLocalTopicExtractionPrompt(cues: current, segStart: cue.start, segEnd: cue.end)
                guard try await localPromptFitsContext(singlePrompt, runner: runner, maxInputTokens: maxInputTokens) else {
                    throw NSError(domain: "ChapterGenerator", code: 16,
                                  userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — die Folge ist zu lang für dieses Kapitelmodell."])
                }
                continue
            }

            let prompt = buildLocalTopicExtractionPrompt(cues: candidate, segStart: segStart, segEnd: segEnd)
            if try await localPromptFitsContext(prompt, runner: runner, maxInputTokens: maxInputTokens) {
                current = candidate
                continue
            }

            if current.isEmpty {
                throw NSError(domain: "ChapterGenerator", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — die Folge ist zu lang für dieses Kapitelmodell."])
            }

            chunks.append(current)
            current = [cue]
            let singlePrompt = buildLocalTopicExtractionPrompt(cues: current, segStart: cue.start, segEnd: cue.end)
            guard try await localPromptFitsContext(singlePrompt, runner: runner, maxInputTokens: maxInputTokens) else {
                throw NSError(domain: "ChapterGenerator", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — die Folge ist zu lang für dieses Kapitelmodell."])
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        NSLog("[ChapterGenerator] Local token split: %d cues -> %d segment(s)", cues.count, chunks.count)
        return chunks
    }

    private func localPromptFitsContext(_ prompt: String,
                                        runner: LocalGGUFModelRunner,
                                        maxInputTokens: Int) async throws -> Bool {
        let promptTokens = try await runner.tokenCount(system: Self.localChapterSystemPrompt, user: prompt)
        NSLog("[ChapterGenerator] Local context check: %d token(s), limit %d", promptTokens, maxInputTokens)
        return promptTokens <= maxInputTokens
    }

    private func generateLocalJSONObject(runner: LocalGGUFModelRunner,
                                         prompt: String,
                                         grammar: LocalGGUFJSONGrammar,
                                         maxNewTokens: Int) async throws -> String {
        let timeoutNanoseconds = Self.localGenerationTimeoutNanoseconds
        let timeoutDescription = "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat nicht rechtzeitig geantwortet."
        let systemPrompt = Self.localChapterSystemPrompt
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await runner.generate(system: systemPrompt,
                                              user: prompt,
                                              maxNewTokens: maxNewTokens,
                                              grammar: grammar,
                                              stopAfterFirstJSONObject: true)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    runner.requestCancel()
                    throw NSError(domain: "ChapterGenerator", code: 22,
                                  userInfo: [NSLocalizedDescriptionKey: timeoutDescription])
                }

                guard let output = try await group.next() else {
                    throw Self.localGenerationTimeoutError()
                }
                group.cancelAll()
                return output
            }
        } catch {
            runner.requestCancel()
            await runner.cancel()
            throw error
        }
    }

    private static func localGenerationTimeoutError() -> NSError {
        NSError(domain: "ChapterGenerator", code: 22,
                userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat nicht rechtzeitig geantwortet."])
    }

    private func decodeLocalJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        guard let json = Self.firstJSONObject(in: output) else {
            throw NSError(domain: "ChapterGenerator", code: 19,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelmodell konnte keine lesbaren Kapitel liefern."])
        }

        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            let snippet = String(output.prefix(240))
            NSLog("[ChapterGenerator] Local model returned invalid JSON: %@", snippet)
            throw NSError(domain: "ChapterGenerator", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelmodell konnte keine lesbaren Kapitel liefern."])
        }
    }

    private static func firstJSONObject(in text: String) -> String? {
        var objectStart: String.Index?
        var depth = 0
        var inString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 {
                    objectStart = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let start = objectStart {
                    return String(text[start...index])
                }
            }
        }

        return nil
    }

    /// Pass 1 prompt: Identify topic changes in a transcript segment.
    /// Output is produced via @Generable GeneratedTopicMarkersList — no format instructions in prompt.
    private func buildTopicExtractionPrompt(cues: [ICTranscriptCue], segStart: Double, segEnd: Double) -> String {
        var prompt = "Identifiziere Themenwechsel in diesem Podcast-Abschnitt.\n"
        prompt += "Für jeden klaren Themenwechsel einen Marker mit Zeitpunkt (in Sekunden) und kurzem Titel.\n"
        prompt += "Wenn Werbung/Sponsoring erkannt wird, beginne Titel mit 'Sponsor: MARKENNAME'.\n"
        prompt += "Titel in der Sprache des Transkripts.\n\n"
        prompt += "Transkript (\(formatTime(segStart))–\(formatTime(segEnd))):\n"
        for cue in cues {
            prompt += "[\(formatTime(cue.start))] \(cue.text)\n"
        }
        return prompt
    }

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private func markersFittingFinalPrompt(markers: [TopicMarker],
                                           totalDuration: Double,
                                           musicSegments: [ICAudioSegment]?,
                                           existingChapters: [ICGeneratedChapter]?,
                                           model: SystemLanguageModel,
                                           maxInputTokens: Int,
                                           status: ((String) -> Void)?,
                                           progress: ((Float, Int, Int) -> Void)?,
                                           progressTotal: Int) async throws -> [TopicMarker] {
        var current = markers
        var round = 1

        while true {
            guard !Task.isCancelled else { throw CancellationError() }
            let finalPrompt = buildFinalChaptersPrompt(
                markers: current,
                totalDuration: totalDuration,
                musicSegments: musicSegments,
                existingChapters: existingChapters)
            if await promptFitsContext(finalPrompt, model: model, maxInputTokens: maxInputTokens) {
                return current
            }

            guard existingChapters == nil else {
                throw NSError(domain: "ChapterGenerator", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "Sponsor-Erkennung ist für diese lange Folge zu umfangreich."])
            }

            var groups = splitMarkersIntoConsolidationChunks(current, maxPromptChars: max(maxInputTokens * 2, 500))
            NSLog("[ChapterGenerator] Reducing %d marker(s) in round %d using %d group(s)",
                  current.count, round, groups.count)

            var reduced: [TopicMarker] = []
            var groupIndex = 0
            while groupIndex < groups.count {
                guard !Task.isCancelled else { throw CancellationError() }
                let group = groups[groupIndex]
                let prompt = buildMarkerConsolidationPrompt(markers: group, totalDuration: totalDuration, round: round)
                if !(await promptFitsContext(prompt, model: model, maxInputTokens: maxInputTokens)) {
                    guard group.count > 1 else {
                        throw NSError(domain: "ChapterGenerator", code: 15,
                                      userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — ein Themenmarker passt nicht in das Kontextfenster."])
                    }
                    let midpoint = group.count / 2
                    groups.replaceSubrange(groupIndex...groupIndex, with: [
                        Array(group[..<midpoint]),
                        Array(group[midpoint...])
                    ])
                    continue
                }

                await MainActor.run {
                    status?(String(format: NSLocalizedString("Pass 2/2: Themenmarker werden verdichtet (Runde %d, Gruppe %d von %d).", comment: ""), round, groupIndex + 1, groups.count))
                    progress?(0.95, max(0, progressTotal - 1), progressTotal)
                }

                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt, generating: GeneratedTopicMarkersList.self)
                let groupStart = group.first?.time ?? 0
                let groupEnd = group.last?.time ?? totalDuration
                let groupMarkers = response.content.markers.compactMap { marker -> TopicMarker? in
                    let title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    let time = min(max(Double(marker.timeSeconds), groupStart), groupEnd)
                    return (time: time, title: title)
                }
                guard !groupMarkers.isEmpty else {
                    throw NSError(domain: "ChapterGenerator", code: 13,
                                  userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — Themenmarker konnten nicht verdichtet werden."])
                }
                reduced.append(contentsOf: groupMarkers)
                groupIndex += 1
            }

            let next = Self.deduplicatedMarkers(reduced)
            guard next.count < current.count else {
                throw NSError(domain: "ChapterGenerator", code: 14,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — die Folge ist zu lang für eine verlässliche Kapitelstruktur."])
            }
            current = next
            round += 1
        }
    }

    @available(iOS 26, *)
    private func promptFitsContext(_ prompt: String,
                                   model: SystemLanguageModel,
                                   maxInputTokens: Int) async -> Bool {
        var promptTokens = max(prompt.count / 2, 1)
        if #available(iOS 26.4, *) {
            promptTokens = (try? await model.tokenCount(for: prompt)) ?? promptTokens
        }
        NSLog("[ChapterGenerator] Context check: %d token(s), limit %d", promptTokens, maxInputTokens)
        return promptTokens <= maxInputTokens
    }
    #endif

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private func splitTranscriptIntoModelChunks(_ cues: [ICTranscriptCue],
                                                model: SystemLanguageModel,
                                                maxInputTokens: Int) async throws -> [[ICTranscriptCue]] {
        guard !cues.isEmpty else { return [] }

        var chunks: [[ICTranscriptCue]] = []
        var current: [ICTranscriptCue] = []

        for cue in cues {
            guard !Task.isCancelled else { throw CancellationError() }

            let candidate = current + [cue]
            let segStart = candidate.first?.start ?? 0
            let segEnd = candidate.last?.end ?? 0
            if !current.isEmpty,
               current.count >= Self.maximumTopicExtractionCueCount || segEnd - segStart > Self.maximumTopicExtractionSegmentDuration {
                chunks.append(current)
                current = [cue]

                let singlePrompt = buildTopicExtractionPrompt(cues: current, segStart: cue.start, segEnd: cue.end)
                guard await promptFitsContext(singlePrompt, model: model, maxInputTokens: maxInputTokens) else {
                    throw NSError(domain: "ChapterGenerator", code: 16,
                                  userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — ein einzelner Transkriptabschnitt passt nicht in das Kontextfenster."])
                }
                continue
            }

            let prompt = buildTopicExtractionPrompt(cues: candidate, segStart: segStart, segEnd: segEnd)

            if await promptFitsContext(prompt, model: model, maxInputTokens: maxInputTokens) {
                current = candidate
                continue
            }

            if current.isEmpty {
                throw NSError(domain: "ChapterGenerator", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — ein einzelner Transkriptabschnitt passt nicht in das Kontextfenster."])
            }

            chunks.append(current)
            current = [cue]

            let singlePrompt = buildTopicExtractionPrompt(cues: current, segStart: cue.start, segEnd: cue.end)
            guard await promptFitsContext(singlePrompt, model: model, maxInputTokens: maxInputTokens) else {
                throw NSError(domain: "ChapterGenerator", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — ein einzelner Transkriptabschnitt passt nicht in das Kontextfenster."])
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        NSLog("[ChapterGenerator] Token split: %d cues → %d segment(s)", cues.count, chunks.count)
        return chunks
    }
    #endif

    private func splitMarkersIntoConsolidationChunks(_ markers: [TopicMarker], maxPromptChars: Int) -> [[TopicMarker]] {
        var chunks: [[TopicMarker]] = []
        var current: [TopicMarker] = []
        var currentChars = 700

        for marker in markers {
            let lineChars = "\(Int(marker.time)) - \(marker.title)\n".count
            if !current.isEmpty && currentChars + lineChars > maxPromptChars {
                chunks.append(current)
                current = []
                currentChars = 700
            }
            current.append(marker)
            currentChars += lineChars
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func buildMarkerConsolidationPrompt(markers: [TopicMarker],
                                                totalDuration: Double,
                                                round: Int) -> String {
        var prompt = "Konsolidiere diese chronologischen Themenmarker zu Kapitel-Kandidaten.\n"
        prompt += "Runde: \(round)\n"
        prompt += "Gesamtdauer: \(formatTime(totalDuration)) (\(Int(totalDuration)) Sekunden)\n\n"
        prompt += "Regeln:\n"
        prompt += "- Betrachte jeden Marker; erfinde keine Themen außerhalb dieser Liste.\n"
        prompt += "- Fasse direkt benachbarte Marker zusammen, wenn sie zum selben zusammenhängenden Themenblock gehören.\n"
        prompt += "- Behalte den frühesten Zeitpunkt des zusammengefassten Themenblocks.\n"
        prompt += "- Behalte Sponsoren/Werbung als eigene Marker mit Titel 'Sponsor: MARKENNAME'.\n"
        prompt += "- Gib weniger Marker zurück, wenn Zusammenfassungen inhaltlich möglich sind.\n\n"
        prompt += "Marker:\n"
        for marker in markers {
            prompt += "\(Int(marker.time)) - \(marker.title)\n"
        }
        return prompt
    }

    /// Pass 2 prompt: Consolidate topic markers into final chapter structure.
    /// The LLM sees a context-bounded full-podcast outline and produces chapter boundaries.
    private func buildFinalChaptersPrompt(
        markers: [TopicMarker],
        totalDuration: Double,
        musicSegments: [ICAudioSegment]?,
        existingChapters: [ICGeneratedChapter]?
    ) -> String {
        var prompt = ""
        let durationStr = formatTime(totalDuration)

        if let chapters = existingChapters, !chapters.isEmpty {
            // Mode B: Sponsor detection — return only sponsor chapters
            prompt += "Finde Werbe- und Sponsoring-Segmente in diesem Podcast.\n"
            prompt += "Gesamtdauer: \(durationStr) (\(Int(totalDuration)) Sekunden)\n\n"
            prompt += "Gib NUR die erkannten Sponsor-Kapitel zurück (Titel als 'Sponsor: MARKENNAME', isSponsor: true).\n"
            prompt += "Falls keine Werbung erkennbar ist, gib eine leere Liste zurück.\n\n"

            prompt += "Bestehende Kapitel:\n"
            for ch in chapters {
                let marker = ch.isSponsor ? " [Sponsor]" : ""
                prompt += "[\(formatTime(ch.start))-\(formatTime(ch.end))] \(ch.title)\(marker)\n"
            }
            prompt += "\n"
        } else {
            // Mode A: Chapter generation
            prompt += "Erstelle die finale Kapitel-Liste aus diesen erkannten Themen.\n"
            prompt += "Gesamtdauer: \(durationStr) (\(Int(totalDuration)) Sekunden)\n\n"
            prompt += "Regeln:\n"
            prompt += "- Verwandte/ähnliche aufeinanderfolgende Themen zusammenfassen.\n"
            prompt += "- Gib kein einzelnes Gesamtkapitel zurueck, wenn mehrere Themenmarker vorhanden sind.\n"
            let minimumChapters = minimumExpectedChapterCount(totalDuration: totalDuration,
                                                              markerCount: markers.count,
                                                              musicSegments: musicSegments)
            prompt += "- Du MUSST mindestens \(minimumChapters) Kapitel liefern; weniger ist ungueltig.\n"
            prompt += "- Nutze die Markerzeiten als Kapitelstarts; ueberspringe keine langen Abschnitte zwischen Markern.\n"
            prompt += "- Normale Inhaltskapitel duerfen nicht laenger als 240 Sekunden sein, ausser die Marker enthalten wirklich kein neues Thema.\n"
            prompt += "- Musik am Anfang oder Ende als eigenes Kapitel mit Titel exakt 'Intro' oder 'Outro' verwenden.\n"
            prompt += "- Ein Intro darf nach einem kurzen gesprochenen Teaser beginnen.\n"
            prompt += "- Musik/Jingles in der Mitte als eigenes kurzes Kapitel mit Titel 'Jingle' verwenden, wenn das Musiksegment ein klarer Trenner ist.\n"
            prompt += "- Die Titel 'Intro', 'Jingle' und 'Outro' sind nur fuer die gelisteten Musik-Segmente reserviert, nicht fuer gesprochenen Teaser oder normale Inhaltsabschnitte.\n"
            prompt += "- Titel kurz und beschreibend, in der Sprache des Podcasts.\n"
            prompt += "- startSeconds und endSeconds als Sekunden ab Podcast-Anfang (Ganzzahl).\n"
            prompt += "- end eines Kapitels = start des nächsten Kapitels.\n"
            prompt += "- Letztes Kapitel end = Gesamtdauer (\(Int(totalDuration))).\n"
            prompt += "- Sponsor-Segmente als 'Sponsor: MARKENNAME' (isSponsor: true).\n\n"
        }

        if let music = musicSegments?.filter({ $0.type == "music" }), !music.isEmpty {
            prompt += "Musik-Segmente:\n"
            for seg in music {
                prompt += "[\(Int(seg.start))-\(Int(seg.end))]\n"
            }
            prompt += "\n"
        }

        prompt += "Erkannte Themen:\n"
        for m in markers {
            prompt += "\(Int(m.time)) - \(m.title)\n"
        }

        return prompt
    }

    private func minimumExpectedChapterCount(totalDuration: Double,
                                             markerCount: Int,
                                             musicSegments: [ICAudioSegment]?) -> Int {
        let boundaryCount = (musicSegments ?? []).filter { $0.type == "music" }.prefix(1).count
            + ((musicSegments ?? []).filter { $0.type == "music" }.count > 1 ? 1 : 0)
        let durationBased = Int(totalDuration / 150) + 1
        let markerBased = Int((Double(markerCount) * 0.6).rounded(.down))
        return min(max(4, min(markerCount, max(durationBased + boundaryCount, markerBased))), 12)
    }

    private static func deduplicatedMarkers(_ markers: [TopicMarker]) -> [TopicMarker] {
        let cleaned = markers
            .map { (time: $0.time, title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.title.isEmpty }
            .sorted { $0.time < $1.time }

        var deduped: [TopicMarker] = []
        for marker in cleaned {
            if let previous = deduped.last, abs(previous.time - marker.time) < 1.0 {
                continue
            }
            deduped.append(marker)
        }
        return deduped
    }

    private static func validatedGeneratedChapters(_ chapters: [ICGeneratedChapter],
                                                   totalDuration: Double,
                                                   topicMarkerCount: Int,
                                                   musicSegments: [ICAudioSegment]?,
                                                   transcriptCues: [ICTranscriptCue],
                                                   existingChapters: [ICGeneratedChapter]?,
                                                   debugTrace: ChapterDebugTrace?) throws -> [ICGeneratedChapter] {
        let issue = chapterQualityIssue(chapters,
                                        totalDuration: totalDuration,
                                        topicMarkerCount: topicMarkerCount,
                                        musicSegments: musicSegments,
                                        transcriptCues: transcriptCues,
                                        existingChapters: existingChapters)
        debugTrace?.recordValidation(issue: issue,
                                     chapterCount: chapters.count,
                                     topicMarkerCount: topicMarkerCount)
        guard let issue else { return chapters }
        NSLog("[ChapterGenerator] Chapter quality validation failed: %@", issue)
        throw NSError(domain: "ChapterGenerator", code: 21,
                      userInfo: [NSLocalizedDescriptionKey: issue])
    }

    private static func chapterQualityIssue(_ chapters: [ICGeneratedChapter],
                                            totalDuration: Double,
                                            topicMarkerCount: Int,
                                            musicSegments: [ICAudioSegment]?,
                                            transcriptCues: [ICTranscriptCue],
                                            existingChapters: [ICGeneratedChapter]?) -> String? {
        guard existingChapters == nil else { return nil }
        guard totalDuration >= 300, transcriptCues.count >= 20 else { return nil }

        if chapters.count == 1,
           let only = chapters.first,
           only.start <= 1,
           only.end >= totalDuration * 0.85,
           isGenericChapterTitle(only.title) {
            return "Kapitelerkennung fehlgeschlagen - Kapitelmodell lieferte nur ein generisches Gesamtkapitel."
        }

        let boundaryChapters = musicBoundaryChapters(from: musicSegments,
                                                     transcriptCues: transcriptCues,
                                                     transcriptDuration: totalDuration)
        if let issue = missingMusicBoundaryIssue(chapters, boundaryChapters: boundaryChapters) {
            return issue
        }

        if let issue = invalidStructuralChapterIssue(chapters,
                                                     boundaryChapters: boundaryChapters,
                                                     transcriptCues: transcriptCues) {
            return issue
        }

        let contentChapters = chapters.filter {
            !["intro", "outro"].contains($0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }

        if totalDuration >= 600, topicMarkerCount >= 4, contentChapters.count < 2 {
            return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat erkannte Themen zu stark zusammengefasst."
        }

        let musicBoundaryCount = boundaryChapters.count
        let minimumChapterCount = max(3, min(8, Int(totalDuration / 360) + 1 + musicBoundaryCount))
        if topicMarkerCount >= minimumChapterCount, chapters.count < minimumChapterCount {
            return "Kapitelerkennung fehlgeschlagen - Kapitelmodell lieferte zu wenige Kapitel fuer die erkannten Themen."
        }

        return nil
    }

    private static func invalidStructuralChapterIssue(_ chapters: [ICGeneratedChapter],
                                                      boundaryChapters: [ICGeneratedChapter],
                                                      transcriptCues: [ICTranscriptCue]) -> String? {
        for chapter in chapters {
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = title
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
                .lowercased()
            if isGenericChapterTitle(title) {
                return "Kapitelerkennung fehlgeschlagen - Kapitelmodell lieferte einen generischen Kapiteltitel."
            }
            if normalized == "jingle", chapter.end - chapter.start > 30 {
                return "Kapitelerkennung fehlgeschlagen - Jingle-Kapitel ist laenger als das erkannte Musiksegment."
            }
            if isStructuralChapterTitle(title),
               matchingMusicBoundary(chapter, in: boundaryChapters) == nil,
               !(normalized == "outro" && hasOutroCueEvidence(for: chapter, transcriptCues: transcriptCues)) {
                return "Kapitelerkennung fehlgeschlagen - Strukturkapitel ohne passende Musikgrenze."
            }
            if chapter.isSponsor && isStructuralChapterTitle(title) {
                return "Kapitelerkennung fehlgeschlagen - Musikstruktur wurde faelschlich als Werbung markiert."
            }
        }

        for pair in zip(chapters, chapters.dropFirst()) {
            let lhs = pair.0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rhs = pair.1.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lhs == rhs && ["intro", "outro", "jingle"].contains(lhs) {
                return "Kapitelerkennung fehlgeschlagen - strukturelles Kapitel wurde doppelt erzeugt."
            }
        }
        return nil
    }

    private static func isStructuralChapterTitle(_ title: String) -> Bool {
        normalizedStructuralChapterTitle(title) != nil
    }

    private static func normalizedStructuralChapterTitle(_ title: String) -> String? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        return ["intro", "outro", "jingle"].contains(normalized) ? normalized : nil
    }

    private static func matchingMusicBoundary(_ chapter: ICGeneratedChapter,
                                              in boundaryChapters: [ICGeneratedChapter]) -> ICGeneratedChapter? {
        guard let title = normalizedStructuralChapterTitle(chapter.title) else { return nil }
        let tolerance = 2.0
        return boundaryChapters.first { boundary in
            normalizedStructuralChapterTitle(boundary.title) == title
                && abs(boundary.start - chapter.start) <= tolerance
                && abs(boundary.end - chapter.end) <= tolerance
        }
    }

    private static func hasOutroCueEvidence(for chapter: ICGeneratedChapter,
                                            transcriptCues: [ICTranscriptCue]) -> Bool {
        let tolerance = 2.0
        return transcriptCues.contains { cue in
            cue.end > chapter.start - tolerance
                && cue.start < chapter.end + tolerance
                && isOutroCueText(cue.text)
        }
    }

    private static func isGenericChapterTitle(_ title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        let exact: Set<String> = [
            "erste themenbeschreibung",
            "themenbeschreibung",
            "kurzer titel",
            "kapitel",
            "thema",
            "podcast",
            "episode",
            "folge",
            "gesamtdauer",
            "ende",
        ]
        if exact.contains(normalized) { return true }
        return normalized.hasPrefix("kapitel ")
            || normalized.hasPrefix("thema ")
            || normalized.hasPrefix("abschnitt ")
            || normalized.hasPrefix("topic ")
            || normalized.hasPrefix("chapter ")
    }

    private static func missingMusicBoundaryIssue(_ chapters: [ICGeneratedChapter],
                                                  boundaryChapters: [ICGeneratedChapter]) -> String? {
        guard !boundaryChapters.isEmpty else { return nil }
        let tolerance = 2.0
        for boundary in boundaryChapters {
            let title = boundary.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let hasMatchingChapter = chapters.contains { chapter in
                chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == title
                    && abs(chapter.start - boundary.start) <= tolerance
                    && abs(chapter.end - boundary.end) <= tolerance
            }
            if !hasMatchingChapter {
                return "Kapitelerkennung fehlgeschlagen - Intro-/Outro-Musik wurde nicht als eigenes Kapitel erkannt."
            }
        }
        return nil
    }

    private static func normalizedChapters(_ chapters: [ICGeneratedChapter],
                                           totalDuration: Double,
                                           forceContinuousBoundaries: Bool) -> [ICGeneratedChapter] {
        let cleaned = chapters.compactMap { chapter -> ICGeneratedChapter? in
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }

            let start = min(max(chapter.start, 0), totalDuration)
            let end = min(max(chapter.end, 0), totalDuration)
            guard start < totalDuration else { return nil }
            if !forceContinuousBoundaries && end <= start {
                return nil
            }
            return ICGeneratedChapter(start: start, end: end, title: title, isSponsor: chapter.isSponsor)
        }
        .sorted { $0.start < $1.start }

        guard forceContinuousBoundaries else {
            return cleaned
        }

        var deduped: [ICGeneratedChapter] = []
        for chapter in cleaned {
            if let previous = deduped.last, abs(previous.start - chapter.start) < 1.0 {
                continue
            }
            deduped.append(chapter)
        }

        guard !deduped.isEmpty else { return [] }

        var normalized: [ICGeneratedChapter] = []
        for index in deduped.indices {
            let rawStart = index == deduped.startIndex ? 0 : deduped[index].start
            let nextStart = index < deduped.index(before: deduped.endIndex) ? deduped[deduped.index(after: index)].start : totalDuration
            let start = min(max(rawStart, 0), totalDuration)
            let end = min(max(nextStart, 0), totalDuration)
            guard end > start else { continue }
            normalized.append(ICGeneratedChapter(start: start,
                                                 end: end,
                                                 title: deduped[index].title,
                                                 isSponsor: deduped[index].isSponsor))
        }
        return normalized
    }

    private static func chaptersByAddingMusicBoundaryChapters(_ chapters: [ICGeneratedChapter],
                                                              musicSegments: [ICAudioSegment]?,
                                                              transcriptCues: [ICTranscriptCue],
                                                              transcriptDuration: Double) -> [ICGeneratedChapter] {
        let boundaryChapters = musicBoundaryChapters(from: musicSegments,
                                                     transcriptCues: transcriptCues,
                                                     transcriptDuration: transcriptDuration)
        guard !chapters.isEmpty else { return chapters }

        var result = chapters
        var added = 0
        if !boundaryChapters.isEmpty {
            for boundary in boundaryChapters {
                let outcome: ([ICGeneratedChapter], Bool)
                if boundary.start == 0 {
                    outcome = chaptersByAddingIntro(boundary, to: result)
                } else if boundary.title == "Outro" {
                    outcome = chaptersByAddingOutro(boundary, to: result)
                } else {
                    outcome = chaptersByInsertingMusicChapter(boundary, to: result)
                }
                result = outcome.0
                if outcome.1 {
                    added += 1
                }
            }

            if added > 0 {
                NSLog("[ChapterGenerator] Kapitel aus Musikgrenzen ergänzt: %d", added)
            }
        }

        let sanitized = sanitizeUnevidencedStructuralChapters(result,
                                                              boundaryChapters: boundaryChapters,
                                                              transcriptCues: transcriptCues)
        return chaptersByRemovingTerminalGenericChapters(sanitized,
                                                         transcriptDuration: transcriptDuration)
    }

    private static func sanitizeUnevidencedStructuralChapters(_ chapters: [ICGeneratedChapter],
                                                              boundaryChapters: [ICGeneratedChapter],
                                                              transcriptCues: [ICTranscriptCue]) -> [ICGeneratedChapter] {
        let introBoundary = boundaryChapters.first {
            normalizedStructuralChapterTitle($0.title) == "intro"
        }
        var changed = false
        let sanitized = chapters.map { chapter -> ICGeneratedChapter in
            guard let structuralTitle = normalizedStructuralChapterTitle(chapter.title) else {
                return chapter
            }
            if let boundary = matchingMusicBoundary(chapter, in: boundaryChapters) {
                if chapter.isSponsor || chapter.title != boundary.title {
                    changed = true
                }
                return ICGeneratedChapter(start: chapter.start,
                                          end: chapter.end,
                                          title: boundary.title,
                                          isSponsor: false)
            }
            if structuralTitle == "outro",
               hasOutroCueEvidence(for: chapter, transcriptCues: transcriptCues) {
                if chapter.isSponsor {
                    changed = true
                }
                return ICGeneratedChapter(start: chapter.start,
                                          end: chapter.end,
                                          title: chapter.title,
                                          isSponsor: false)
            }
            guard var title = contentTitleForChapter(chapter, transcriptCues: transcriptCues) else {
                return chapter
            }
            if structuralTitle == "intro",
               let introBoundary,
               chapter.end <= introBoundary.start + 2.0,
               !title.hasPrefix("Teaser:") {
                title = "Teaser: \(title)"
            }
            changed = true
            return ICGeneratedChapter(start: chapter.start,
                                      end: chapter.end,
                                      title: title,
                                      isSponsor: title.hasPrefix("Sponsor: "))
        }

        if changed {
            NSLog("[ChapterGenerator] Strukturkapitel ohne Musikgrenze normalisiert")
        }
        return sanitized
    }

    private static func contentTitleForChapter(_ chapter: ICGeneratedChapter,
                                               transcriptCues: [ICTranscriptCue]) -> String? {
        let overlappingSpeech = transcriptCues
            .filter {
                $0.end > chapter.start
                    && $0.start < chapter.end
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !isMusicOnlyCue($0)
            }
            .sorted { $0.start < $1.start }
        let titles = overlappingSpeech.compactMap { cue -> String? in
            let title = deterministicMarkerTitle(from: cue.text)
            guard !title.isEmpty,
                  !isStructuralChapterTitle(title),
                  !isGenericChapterTitle(title) else {
                return nil
            }
            return title
        }
        return titles.first { !isWeakChapterTitle($0) } ?? titles.first
    }

    private static func isWeakChapterTitle(_ title: String) -> Bool {
        var normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        if normalized.hasPrefix("sponsor:") {
            normalized = normalized
                .replacingOccurrences(of: #"^sponsor:\s*"#, with: "", options: .regularExpression)
        }
        let weakPrefixes = [
            "ja ",
            "ja,",
            "also ",
            "genau ",
            "nun ",
            "okay ",
            "ok ",
            "und ",
            "aber ",
            "oder ",
            "egal ob",
            "die sache ist",
        ]
        return weakPrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func chaptersByRemovingTerminalGenericChapters(_ chapters: [ICGeneratedChapter],
                                                                  transcriptDuration: Double) -> [ICGeneratedChapter] {
        var result = chapters
        var removed = 0
        while let last = result.last,
              last.start >= transcriptDuration - 90,
              isGenericChapterTitle(last.title) {
            result.removeLast()
            removed += 1
        }
        if removed > 0, let last = result.last {
            result[result.count - 1] = ICGeneratedChapter(start: last.start,
                                                          end: transcriptDuration,
                                                          title: last.title,
                                                          isSponsor: last.isSponsor)
            NSLog("[ChapterGenerator] Generische Schlusskapitel entfernt: %d", removed)
        }
        return result
    }

    private static func musicBoundaryChapters(from musicSegments: [ICAudioSegment]?,
                                              transcriptCues: [ICTranscriptCue],
                                              transcriptDuration: Double) -> [ICGeneratedChapter] {
        let validSegments = (musicSegments ?? [])
            .filter { $0.end > $0.start && $0.end > 0 }
            .sorted { $0.start < $1.start }
        let music = validSegments.filter { $0.type == "music" }
        guard !music.isEmpty, let speechBoundaries = speechBoundaries(from: transcriptCues) else { return [] }

        let tolerance = 2.0
        let firstSpeechStart = speechBoundaries.firstSpeechStart
        let lastSpeechEnd = speechBoundaries.lastSpeechEnd
        let timelineEnd = max(transcriptDuration, validSegments.map { $0.end }.max() ?? transcriptDuration)
        let hasFullTimeline = validSegments.contains { $0.type != "music" }
        let earlyIntroWindow = 90.0
        let standaloneMusicDuration = 4.0

        var chapters: [ICGeneratedChapter] = []
        if let earlyIntro = music.first(where: { $0.start <= earlyIntroWindow && $0.end - $0.start >= standaloneMusicDuration }) {
            chapters.append(ICGeneratedChapter(start: max(0, earlyIntro.start),
                                               end: min(earlyIntro.end, timelineEnd),
                                               title: "Intro",
                                               isSponsor: false))
        } else if let firstMusic = music.first {
            let isFirstNonSilence = hasFullTimeline
                && sameSegment(validSegments.first { $0.type != "silence" }, as: firstMusic, tolerance: tolerance)
            let startsAtBeginning = !hasFullTimeline && firstMusic.start <= tolerance
            if isFirstNonSilence || startsAtBeginning {
                let leadingMusicEnd = min(firstMusic.end, timelineEnd)
                let end = firstSpeechStart <= tolerance ? leadingMusicEnd : min(leadingMusicEnd, firstSpeechStart)
                if end > 0 {
                    chapters.append(ICGeneratedChapter(start: 0, end: end, title: "Intro", isSponsor: false))
                }
            }
        }

        let middleMusic = music.filter { segment in
            segment.end - segment.start >= standaloneMusicDuration
                && segment.start > earlyIntroWindow
                && segment.end < transcriptDuration - 20
        }
        for segment in middleMusic {
            chapters.append(ICGeneratedChapter(start: segment.start,
                                               end: segment.end,
                                               title: "Jingle",
                                               isSponsor: false))
        }

        if let lastMusic = music.last {
            let isLastNonSilence = hasFullTimeline
                && sameSegment(validSegments.last { $0.type != "silence" }, as: lastMusic, tolerance: tolerance)
            let endsAtKnownEnd = !hasFullTimeline && lastMusic.end >= transcriptDuration - tolerance
            if isLastNonSilence || endsAtKnownEnd {
                let speechEnd = min(lastSpeechEnd, timelineEnd)
                let trailingMusicStart = speechEnd <= lastMusic.start + tolerance ? lastMusic.start : max(lastMusic.start, speechEnd, 0)
                let start = trailingMusicStart
                let overlapsExistingBoundary = chapters.contains { start < $0.end && timelineEnd > $0.start }
                if timelineEnd > start && !overlapsExistingBoundary {
                    chapters.append(ICGeneratedChapter(start: start, end: timelineEnd, title: "Outro", isSponsor: false))
                }
            }
        }

        return chapters
    }

    private static func speechBoundaries(from cues: [ICTranscriptCue]) -> (firstSpeechStart: Double, lastSpeechEnd: Double)? {
        let spokenCues = cues
            .filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !isMusicOnlyCue($0)
            }
            .sorted { $0.start < $1.start }
        guard let first = spokenCues.first, let last = spokenCues.last else { return nil }
        return (first.start, last.end)
    }

    private static func isMusicOnlyCue(_ cue: ICTranscriptCue) -> Bool {
        let normalized = cue.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        let tokenText = normalized.replacingOccurrences(of: #"[^a-z]+"#,
                                                        with: " ",
                                                        options: .regularExpression)
        let tokens = tokenText.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return false }
        let musicTokens: Set<String> = ["musik", "music", "musica", "musique"]
        return tokens.allSatisfy { musicTokens.contains($0) }
    }

    private static func chaptersByAddingIntro(_ intro: ICGeneratedChapter,
                                              to chapters: [ICGeneratedChapter]) -> ([ICGeneratedChapter], Bool) {
        var result = [intro]
        for chapter in chapters {
            let start = max(chapter.start, intro.end)
            guard chapter.end > start else { continue }
            result.append(ICGeneratedChapter(start: start,
                                             end: chapter.end,
                                             title: chapter.title,
                                             isSponsor: chapter.isSponsor))
        }
        return (result, true)
    }

    private static func chaptersByAddingOutro(_ outro: ICGeneratedChapter,
                                              to chapters: [ICGeneratedChapter]) -> ([ICGeneratedChapter], Bool) {
        var result: [ICGeneratedChapter] = []
        for chapter in chapters {
            guard chapter.start < outro.start else { continue }
            let end = min(chapter.end, outro.start)
            guard end > chapter.start else { continue }
            result.append(ICGeneratedChapter(start: chapter.start,
                                             end: end,
                                             title: chapter.title,
                                             isSponsor: chapter.isSponsor))
        }

        if let last = result.last, last.end < outro.start {
            result[result.count - 1] = ICGeneratedChapter(start: last.start,
                                                          end: outro.start,
                                                          title: last.title,
                                                          isSponsor: last.isSponsor)
        }
        result.append(outro)
        return (result, true)
    }

    private static func chaptersByInsertingMusicChapter(_ music: ICGeneratedChapter,
                                                        to chapters: [ICGeneratedChapter]) -> ([ICGeneratedChapter], Bool) {
        let tolerance = 2.0
        if chapters.contains(where: {
            $0.title == music.title
                && abs($0.start - music.start) <= tolerance
                && abs($0.end - music.end) <= tolerance
        }) {
            return (chapters, false)
        }

        var result: [ICGeneratedChapter] = []
        var inserted = false
        for chapter in chapters {
            if chapter.end <= music.start || chapter.start >= music.end {
                if !inserted && chapter.start >= music.end {
                    result.append(music)
                    inserted = true
                }
                result.append(chapter)
                continue
            }

            if chapter.start < music.start {
                result.append(ICGeneratedChapter(start: chapter.start,
                                                 end: music.start,
                                                 title: chapter.title,
                                                 isSponsor: chapter.isSponsor))
            }
            if !inserted {
                result.append(music)
                inserted = true
            }
            if chapter.end > music.end {
                result.append(ICGeneratedChapter(start: music.end,
                                                 end: chapter.end,
                                                 title: chapter.title,
                                                 isSponsor: chapter.isSponsor))
            }
        }

        if !inserted {
            result.append(music)
            inserted = true
        }
        return (result.filter { $0.end > $0.start }, inserted)
    }

    private static func sameSegment(_ segment: ICAudioSegment?,
                                    as other: ICAudioSegment,
                                    tolerance: Double) -> Bool {
        guard let segment else { return false }
        return segment.type == other.type
            && abs(segment.start - other.start) <= tolerance
            && abs(segment.end - other.end) <= tolerance
    }

    // MARK: - Transcript Chunking

    /// Split transcript into non-overlapping segments that each fit the LLM context window.
    /// Every cue is included in exactly one segment — no sampling, no data loss.
    private static func splitTranscriptIntoChunks(_ cues: [ICTranscriptCue], maxTranscriptChars: Int) -> [[ICTranscriptCue]] {
        guard !cues.isEmpty else { return [] }

        let totalChars = cues.reduce(0) { $0 + $1.text.count + 15 }
        if totalChars <= maxTranscriptChars {
            return [cues]
        }

        let avgCharsPerCue = max(totalChars / cues.count, 1)
        let cuesPerChunk = max(maxTranscriptChars / avgCharsPerCue, 20)

        var chunks: [[ICTranscriptCue]] = []
        var startIndex = 0

        while startIndex < cues.count {
            let endIndex = min(startIndex + cuesPerChunk, cues.count)
            chunks.append(Array(cues[startIndex..<endIndex]))
            startIndex = endIndex
        }

        NSLog("[ChapterGenerator] Split: %d cues → %d segments of ~%d cues", cues.count, chunks.count, cuesPerChunk)
        return chunks
    }

    private func formatTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Persistence

    // Cache for hasChapters results
    private var _chaptersCache: [String: Bool] = [:]

    @objc func saveChapters(_ chapters: [ICGeneratedChapter], for episodeHash: String) {
        try? saveChaptersThrowing(chapters, for: episodeHash)
    }

    func saveChaptersThrowing(_ chapters: [ICGeneratedChapter], for episodeHash: String) throws {
        let file = ChaptersFile(
            chapters: chapters.map {
                .init(start: $0.start, end: $0.end, title: $0.title, isSponsor: $0.isSponsor)
            }
        )
        let url = ICTranscriptionPaths.chaptersJSONURL(for: episodeHash)
        let data = try JSONEncoder().encode(file)
        do {
            try data.write(to: url, options: .atomic)
            _chaptersCache[episodeHash] = true
            NSLog("[ChapterGenerator] Saved %d chapters for %@", chapters.count, episodeHash)
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: "Kapiteldatei geschrieben",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "chapterCount": chapters.count,
                                                   ] as NSDictionary)
            ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "chapters-saved")
        } catch {
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: "Kapiteldatei konnte nicht geschrieben werden",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "chapterCount": chapters.count,
                                                    "error": error.localizedDescription,
                                                   ] as NSDictionary)
            throw error
        }
    }

    @objc func loadChapters(for episodeHash: String) -> [ICGeneratedChapter]? {
        let url = ICTranscriptionPaths.chaptersJSONURL(for: episodeHash)
        guard FileManager.default.fileExists(atPath: url.path) else {
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Kapiteldatei fehlt",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                   ] as NSDictionary)
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(ChaptersFile.self, from: data)
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Kapiteldatei geladen",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "chapterCount": file.chapters.count,
                                                   ] as NSDictionary)
            return file.chapters.map {
                ICGeneratedChapter(start: $0.start, end: $0.end, title: $0.title, isSponsor: $0.isSponsor)
            }
        } catch {
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Kapiteldatei konnte nicht geladen werden",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "error": error.localizedDescription,
                                                   ] as NSDictionary)
            return nil
        }
    }

    @objc func hasChapters(for episodeHash: String) -> Bool {
        if let cached = _chaptersCache[episodeHash] { return cached }
        let url = ICTranscriptionPaths.chaptersJSONURL(for: episodeHash)
        let exists = FileManager.default.fileExists(atPath: url.path)
        _chaptersCache[episodeHash] = exists
        return exists
    }

    /// Invalidate cached hasChapters result.
    @objc func invalidateChaptersCache(for episodeHash: String) {
        _chaptersCache.removeValue(forKey: episodeHash)
    }

    @objc(removeGeneratedChaptersForEpisodeHash:)
    func removeGeneratedChapters(forEpisodeHash episodeHash: String) {
        guard !episodeHash.isEmpty else { return }
        removeGeneratedChapters(forEpisodeHash: episodeHash, episode: findEpisode(hash: episodeHash))
    }

    @objc func removeGeneratedChapters(for episode: CDEpisode) {
        guard let episodeHash = episode.objectHash, !episodeHash.isEmpty else { return }
        removeGeneratedChapters(forEpisodeHash: episodeHash, episode: episode)
    }

    private func removeGeneratedChapters(forEpisodeHash episodeHash: String, episode: CDEpisode?) {
        let generated = loadChapters(for: episodeHash) ?? []
        let url = ICTranscriptionPaths.chaptersJSONURL(for: episodeHash)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "Kapiteldatei entfernt",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "chapterCount": generated.count,
                                                       ] as NSDictionary)
            } catch {
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "Kapiteldatei konnte nicht entfernt werden",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "chapterCount": generated.count,
                                                        "error": error.localizedDescription,
                                                       ] as NSDictionary)
            }
        } else {
            ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                   message: "Kapiteldatei fehlte beim Entfernen",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                   ] as NSDictionary)
        }
        _chaptersCache[episodeHash] = false
        removeChapterDebug(for: episodeHash)

        guard let episode, !generated.isEmpty else {
            ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "chapters-removed")
            return
        }
        let generatedMatches = generated.map { generatedChapter in
            (start: generatedChapter.start, title: generatedChapter.title)
        }

        var deletedChapterCount = 0
        for case let chapter as CDChapter in (episode.chapters ?? []) {
            let matchesGenerated = generatedMatches.contains { match in
                abs(chapter.timecode - match.start) < 0.5 && chapter.title == match.title
            }
            if matchesGenerated {
                DatabaseManager.shared()?.objectContext.delete(chapter)
                deletedChapterCount += 1
            }
        }
        DatabaseManager.shared()?.save()
        ICDiagnosticLogger.shared.logEvent("chapters",
                                           message: "Generierte Kapitel aus Datenbank entfernt",
                                           metadata: [
                                            "episodeHash": episodeHash,
                                            "deletedDatabaseChapters": deletedChapterCount,
                                           ] as NSDictionary)
        ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "chapters-removed")
    }

    private func removeChapterDebug(for episodeHash: String) {
        let url = ICTranscriptionPaths.transcriptCacheDirectory()
            .appendingPathComponent("\(episodeHash)_chapter_debug.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "Chapter-Debug entfernt",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                       ] as NSDictionary)
            } catch {
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "Chapter-Debug konnte nicht entfernt werden",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "error": error.localizedDescription,
                                                       ] as NSDictionary)
            }
        }
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

    // MARK: - Sponsor Skip Integration

    /// Write "Sponsor:" as skip keyword for a feed if sponsor-skip is enabled.
    @objc func applySponsorSkipKeywords(for feedUID: String, chapters: [ICGeneratedChapter]) {
        let hasSponsorChapters = chapters.contains { $0.isSponsor }
        guard hasSponsorChapters else { return }

        // Check if sponsor-skip is enabled (global or per-feed)
        let globalEnabled = UserDefaults.standard.bool(forKey: "AutoSkipSponsors")
        guard globalEnabled else { return }

        // The existing auto-skip mechanism uses feed property "{uid}_auto_skip_chapter_name"
        // We add "Sponsor:" to the skip keywords list
        // This is handled by the calling code since we need the CDFeed object
        // (which requires Core Data context on main thread)
    }

    // MARK: - Sponsor Merge Logic

    /// Merge sponsor chapters into existing chapter list.
    /// Adjusts boundaries of adjacent chapters.
    @objc func mergeSponsors(_ sponsors: [ICGeneratedChapter],
                            into chapters: [ICGeneratedChapter]) -> [ICGeneratedChapter] {
        guard !sponsors.isEmpty else { return chapters }
        guard !chapters.isEmpty else { return sponsors }

        var result = chapters
        let sponsorsSorted = sponsors.sorted { $0.start < $1.start }

        for sponsor in sponsorsSorted {
            var inserted = false

            for i in 0..<result.count {
                let ch = result[i]

                // Sponsor falls between this chapter and the next
                if sponsor.start >= ch.start && sponsor.start <= ch.end {
                    // Split or trim the current chapter
                    if sponsor.end <= ch.end {
                        // Sponsor inside chapter → split
                        let before = ICGeneratedChapter(start: ch.start, end: sponsor.start,
                                                        title: ch.title, isSponsor: ch.isSponsor)
                        let after = ICGeneratedChapter(start: sponsor.end, end: ch.end,
                                                       title: "\(ch.title) (Forts.)", isSponsor: ch.isSponsor)

                        result[i] = before
                        result.insert(sponsor, at: i + 1)
                        if sponsor.end < ch.end {
                            result.insert(after, at: i + 2)
                        }
                        inserted = true
                        break
                    } else {
                        // Sponsor extends beyond chapter → trim chapter end
                        result[i] = ICGeneratedChapter(start: ch.start, end: sponsor.start,
                                                        title: ch.title, isSponsor: ch.isSponsor)
                        // Trim next chapter start if needed
                        if i + 1 < result.count {
                            let next = result[i + 1]
                            if sponsor.end > next.start {
                                result[i + 1] = ICGeneratedChapter(start: sponsor.end, end: next.end,
                                                                    title: next.title, isSponsor: next.isSponsor)
                            }
                        }
                        result.insert(sponsor, at: i + 1)
                        inserted = true
                        break
                    }
                }
            }

            if !inserted {
                // Sponsor falls at the end
                result.append(sponsor)
            }
        }

        return result.sorted { $0.start < $1.start }
    }
}
