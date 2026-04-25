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
                               progress: ((Float, Int, Int) -> Void)? = nil) async throws -> [ICGeneratedChapter] {
        guard !cues.isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No transcript cues provided"])
        }

        let selectedModel = ICDownloadableModelStore.selectedModel(for: .textToChapters)
        if selectedModel.identifier == "apple-foundation-models" {
            guard ChapterGenerator.isAvailable() else {
                throw NSError(domain: "ChapterGenerator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"])
            }
            return try await self.generateWithLLM(cues: cues, musicSegments: musicSegments,
                                                  existingChapters: nil, status: status, progress: progress)
        }

        return try await self.generateWithLocalGGUF(model: selectedModel,
                                                    cues: cues,
                                                    musicSegments: musicSegments,
                                                    existingChapters: nil,
                                                    status: status,
                                                    progress: progress)
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
                                                              existingChapters: existingChapters)
                } else {
                    chapters = try await self.generateWithLocalGGUF(model: selectedModel,
                                                                    cues: cues,
                                                                    musicSegments: nil,
                                                                    existingChapters: existingChapters)
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
                                 progress: ((Float, Int, Int) -> Void)? = nil) async throws -> [ICGeneratedChapter] {
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

            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: GeneratedTopicMarkersList.self)
            NSLog("[ChapterGenerator] Pass 1 %d returned %d markers", index + 1, response.content.markers.count)

            for m in response.content.markers {
                var t = Double(m.timeSeconds)
                // Clamp — the LLM occasionally hallucinates timestamps outside the segment range
                if t < segStart { t = segStart }
                if t > segEnd { t = segEnd }
                let title = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    topicMarkers.append((time: t, title: title))
                }
            }

            let p = Float(index + 1) / Float(totalSegments + 1) * 0.9 + 0.05
            await MainActor.run { progress?(p, index + 1, totalSegments + 1) }
        }

        guard !Task.isCancelled else { throw CancellationError() }

        if topicMarkers.isEmpty {
            NSLog("[ChapterGenerator] Pass 1 produced no usable markers — aborting")
            throw NSError(domain: "ChapterGenerator", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — keine Themen erkannt."])
        }

        topicMarkers.sort { $0.time < $1.time }
        topicMarkers = Self.deduplicatedMarkers(topicMarkers)

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

        NSLog("[ChapterGenerator] Pass 2: prompt %d chars from %d marker(s)", finalPrompt.count, finalMarkers.count)
        await MainActor.run {
            status?(NSLocalizedString("Pass 2/2: Finale Kapitelstruktur wird erstellt.", comment: ""))
        }
        await MainActor.run { progress?(0.98, totalSegments, totalSegments + 1) }

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
                                       progress: ((Float, Int, Int) -> Void)? = nil) async throws -> [ICGeneratedChapter] {
        guard ICDownloadableModelStore.isDownloaded(model: model),
              let modelURL = ICDownloadableModelStore.modelFileURL(for: model),
              FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NSError(domain: "ChapterGenerator", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: "")])
        }

        status?(String(format: NSLocalizedString("%@ wird geladen.", comment: ""), model.title))
        progress?(0.01, 0, 1)

        let runner = try await Task.detached(priority: .userInitiated) {
            try LocalGGUFModelRunner.create(modelURL: modelURL)
        }.value
        let maxInputTokens = await runner.maxInputTokens
        NSLog("[ChapterGenerator] Local GGUF context max input: %d tokens", maxInputTokens)

        let segments = try await splitTranscriptIntoLocalChunks(cues,
                                                                runner: runner,
                                                                maxInputTokens: maxInputTokens)
        let totalSegments = segments.count
        let totalDuration = max(cues.last?.end ?? 0, 1)
        var topicMarkers: [TopicMarker] = []

        status?(NSLocalizedString("Transkript wird in verarbeitbare Abschnitte aufgeteilt.", comment: ""))
        progress?(0.05, 0, totalSegments + 1)

        for (index, segment) in segments.enumerated() {
            guard !Task.isCancelled else {
                await runner.cancel()
                throw CancellationError()
            }

            let segStart = segment.first?.start ?? 0
            let segEnd = segment.last?.end ?? 0
            let prompt = buildLocalTopicExtractionPrompt(cues: segment, segStart: segStart, segEnd: segEnd)
            guard try await localPromptFitsContext(prompt, runner: runner, maxInputTokens: maxInputTokens) else {
                    throw NSError(domain: "ChapterGenerator", code: 16,
                                  userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — die Folge ist zu lang für dieses Kapitelmodell."])
            }

            NSLog("[ChapterGenerator] Local pass 1 %d/%d [%@-%@]: %d cues, %d chars",
                  index + 1, totalSegments, formatTime(segStart), formatTime(segEnd), segment.count, prompt.count)
            status?(String(format: NSLocalizedString("Pass 1/2: Themenwechsel in Abschnitt %d von %d werden extrahiert.", comment: ""), index + 1, totalSegments))

            let output = try await runner.generate(system: Self.localChapterSystemPrompt,
                                                   user: prompt,
                                                   maxNewTokens: 1_536)
            let response = try decodeLocalJSON(LocalTopicMarkersResponse.self, from: output)
            for marker in response.markers {
                var time = Double(marker.timeSeconds)
                if time < segStart { time = segStart }
                if time > segEnd { time = segEnd }
                let title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    topicMarkers.append((time: time, title: title))
                }
            }

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

        topicMarkers = Self.deduplicatedMarkers(topicMarkers)
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

        NSLog("[ChapterGenerator] Local pass 2: prompt %d chars from %d marker(s)", finalPrompt.count, finalMarkers.count)
        status?(NSLocalizedString("Pass 2/2: Finale Kapitelstruktur wird erstellt.", comment: ""))
        progress?(0.98, totalSegments, totalSegments + 1)

        let output = try await runner.generate(system: Self.localChapterSystemPrompt,
                                               user: finalPrompt,
                                               maxNewTokens: existingChapters == nil ? 3_072 : 1_536)
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

        guard !chapters.isEmpty || existingChapters != nil else {
            throw NSError(domain: "ChapterGenerator", code: 18,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — das Kapitelmodell hat keine Kapitel erzeugt."])
        }

        progress?(1.0, totalSegments + 1, totalSegments + 1)
        return chapters
    }

    private func buildLocalTopicExtractionPrompt(cues: [ICTranscriptCue], segStart: Double, segEnd: Double) -> String {
        var prompt = buildTopicExtractionPrompt(cues: cues, segStart: segStart, segEnd: segEnd)
        prompt += "\n\nAntworte ausschliesslich mit JSON in diesem Schema:\n"
        prompt += "{\"markers\":[{\"timeSeconds\":123,\"title\":\"Kurzer Titel\"}]}\n"
        prompt += "Nutze timeSeconds als Ganzzahl ab Podcast-Anfang."
        return prompt
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

                let output = try await runner.generate(system: Self.localChapterSystemPrompt,
                                                       user: prompt,
                                                       maxNewTokens: 1_536)
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
        guard !chapters.isEmpty, !boundaryChapters.isEmpty else { return chapters }

        var result = chapters
        var added = 0
        for boundary in boundaryChapters {
            let outcome: ([ICGeneratedChapter], Bool)
            if boundary.start == 0 {
                outcome = chaptersByAddingIntro(boundary, to: result)
            } else {
                outcome = chaptersByAddingOutro(boundary, to: result)
            }
            result = outcome.0
            if outcome.1 {
                added += 1
            }
        }

        if added > 0 {
            NSLog("[ChapterGenerator] Kapitel aus Musikgrenzen ergänzt: %d", added)
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

        let tolerance = 1.0
        let firstSpeechStart = speechBoundaries.firstSpeechStart
        let lastSpeechEnd = speechBoundaries.lastSpeechEnd
        let timelineEnd = max(transcriptDuration, validSegments.map { $0.end }.max() ?? transcriptDuration)
        let hasFullTimeline = validSegments.contains { $0.type != "music" }

        var chapters: [ICGeneratedChapter] = []
        if let firstMusic = music.first {
            let isFirstNonSilence = hasFullTimeline
                && sameSegment(validSegments.first { $0.type != "silence" }, as: firstMusic, tolerance: tolerance)
            let startsAtBeginning = !hasFullTimeline && firstMusic.start <= tolerance
            if isFirstNonSilence || startsAtBeginning {
                let end = min(firstMusic.end, firstSpeechStart, timelineEnd)
                if end > 0 {
                    chapters.append(ICGeneratedChapter(start: 0, end: end, title: "Intro", isSponsor: false))
                }
            }
        }

        if let lastMusic = music.last {
            let isLastNonSilence = hasFullTimeline
                && sameSegment(validSegments.last { $0.type != "silence" }, as: lastMusic, tolerance: tolerance)
            let endsAtKnownEnd = !hasFullTimeline && lastMusic.end >= transcriptDuration - tolerance
            if isLastNonSilence || endsAtKnownEnd {
                let start = max(lastMusic.start, lastSpeechEnd, 0)
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
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard let first = spokenCues.first, let last = spokenCues.last else { return nil }
        return (first.start, last.end)
    }

    private static func chaptersByAddingIntro(_ intro: ICGeneratedChapter,
                                              to chapters: [ICGeneratedChapter]) -> ([ICGeneratedChapter], Bool) {
        guard !hasChapterBoundary(chapters, at: intro.end) else {
            return (chapters, false)
        }

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
        guard !hasChapterBoundary(chapters, at: outro.start) else {
            return (chapters, false)
        }

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

    private static func hasChapterBoundary(_ chapters: [ICGeneratedChapter], at time: Double) -> Bool {
        let tolerance = 1.0
        return chapters.contains {
            abs($0.start - time) <= tolerance || abs($0.end - time) <= tolerance
        }
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

    @objc func removeGeneratedChapters(for episode: CDEpisode) {
        guard let episodeHash = episode.objectHash, !episodeHash.isEmpty else { return }
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

        guard !generated.isEmpty else { return }
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
