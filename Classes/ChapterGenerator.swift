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

    @Guide(description: "Kurzer beschreibender Kapitel-Titel in der Sprache des Podcasts. Skip-wuerdige Werbe-, Sponsoring-, Eigenpromo-, Abo-/Mitgliedschafts-, Shop-, Spenden-, Bewertungs- oder Cross-Promo-Segmente mit 'Sponsor: ...' betiteln. Bei belegten Audio-Kapiteln exakt 'Jingle' oder 'Sound-Sample'.")
    let title: String

    @Guide(description: "true, wenn dieses Kapitel semantisch ein skip-wuerdiges Werbe-, Sponsoring-, Eigenpromo-, Abo-/Mitgliedschafts-, Shop-, Spenden-, Bewertungs- oder Cross-Promo-Segment ist; unabhaengig von Sprache oder konkreter Formulierung.")
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

    @Guide(description: "Kurzer Titel des Themas in der Sprache des Podcasts. Skip-wuerdige Werbe-, Sponsoring-, Eigenpromo-, Abo-/Mitgliedschafts-, Shop-, Spenden-, Bewertungs- oder Cross-Promo-Segmente mit 'Sponsor: ...' betiteln. Bei belegten Audiohinweisen exakt 'Jingle' oder 'Sound-Sample'.")
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
    private struct TranscriptContextWindow {
        let cues: [ICTranscriptCue]

        var start: Double { cues.first?.start ?? 0 }
        var end: Double { cues.last?.end ?? 0 }
    }

    private static let minimumSplitChapterDuration: Double = 45
    private static let minimumAudioContextDuration: Double = 3
    private static let maximumAudioInterludeChapterDuration: Double = 90
    private static let transcriptPromptBlockDuration: Double = 30
    private static let targetContextWindowOverlapDuration: Double = 45 * 60
    private static let targetInputContextRatio = 0.85
    private static let localGenerationTimeoutNanoseconds: UInt64 = 600 * 1_000_000_000
    private static let sponsorRecognitionRule = "- Behandle isSponsor als skip-wuerdige Promotion, nicht nur als externe Werbung: Sponsoring, Eigenpromo, bezahlte Angebote, Mitgliedschaften/Abos, Shops/Merch, Spenden/Support, Bewertungs-/Follow-Aufrufe, Cross-Promotion sowie kommerzielle oder monetaere Calls-to-Action fuer eigene Produkte, Events oder Services. Wenn ein Abschnitt hauptsaechlich dazu auffordert, ausserhalb des redaktionellen Inhalts etwas zu kaufen, zu abonnieren, zu unterstuetzen, zu bewerten/folgen, ein Event zu besuchen, einen Shop/Link zu nutzen oder ein anderes Angebot zu konsumieren, ist er Promotion. Bezahlter oder limitierter Zugang zu einem eigenen Angebot, ein Link in Shownotes zu diesem Angebot oder die Aufforderung, ein eigenes Event, Produkt, Abo oder anderes eigenes Format zu nutzen, ist Promotion auch dann, wenn es informativ formuliert ist. Kapitel, die nur Details eines eigenen Angebots, Events, Produkts, Abos oder anderen eigenen Formats liefern, sind ebenfalls Promotion, auch wenn der konkrete Kauf- oder Nutzungsaufruf erst in einem benachbarten Kapitel steht. Mehrere benachbarte Kapitel eines zusammenhaengenden Unterstuetzungs-, Abo-, Spenden-, Preis-, Zahlungs- oder Mitgliedschaftsblocks sind alle Promotion; markiere nicht nur den konkreten Zahlungsanbieter, Rabatt oder Werbeabsatz innerhalb dieses Blocks. Veranstaltungshinweise, Ticketverfuegbarkeit, Buchpraesentationen, Workshop-Angebote und Empfehlungen fuer andere Podcasts, Buecher oder Shows sind Promotion, wenn ihr Zweck Teilnahme, Kauf, Buchung oder Konsum dieses Angebots ist; persoenliche Beziehung, redaktioneller Ton oder wissenschaftlich-kultureller Kontext aendert das nicht. Neutrale Erwaehnungen von Plattformen, Tools, Apps, Diensten oder Anbietern sind keine Promotion, wenn sie nur erklaert werden und nicht dazu auffordern, sie zu kaufen, zu abonnieren, zu unterstuetzen oder zu nutzen. Reine Servicehinweise zum bestehenden Podcast, Feed, Archiv, technischen Problem oder zur Abrufbarkeit sind keine Promotion, solange sie nicht primaer einen Kauf, Support, ein anderes Angebot oder eine andere Sendung bewerben; trenne solche Servicehinweise von direkt anschliessender Cross-Promotion. Behandle eigene Angebote, eigene Events und andere eigene Podcasts genauso als Promotion; sie sind nicht redaktionell, nur weil sie vom Podcast selbst stammen. Erkenne das semantisch in jeder Sprache; Titel dafuer 'Sponsor: ...' und isSponsor true, auch wenn der Promo-Abschnitt am Anfang, Ende oder ueber fast die ganze kurze Folge laeuft. isSponsor false ist nur fuer redaktionellen Inhalt ohne solches Call-to-Action-Ziel erlaubt.\n"
    private static let timelineCoverageRule = "- Kapitel muessen die komplette Zeitachse lueckenlos abdecken: keine Sekundenluecken zwischen endSeconds und dem naechsten startSeconds, auch nicht fuer Pausen, Musik oder Stille.\n"
    private static let promotionSegmentationRule = "- Wenn redaktioneller Inhalt in Promotion, Eigenpromo oder einen Call-to-Action uebergeht, beginne dort ein eigenes Sponsor-Kapitel. Wenn Promotion wieder in redaktionellen Inhalt uebergeht, beginne dort ein eigenes redaktionelles Kapitel. Mische redaktionellen Inhalt und Promotion in keiner Richtung im selben Kapitel.\n"
    private static let promotionAuditRule = "- Pruefe vor der Ausgabe jeden Kapitelkandidaten noch einmal nach seinem Hauptzweck: Wenn der Abschnitt primaer ein Angebot, Produkt, Event, Kurs, Buch, Mitgliedschaft, Spende, Shop, Ticket, Newsletter, Account, Bewertungs-/Follow-Handlung, Link oder einen anderen externen Nutzungsschritt bewirbt, ist er Promotion. Das gilt auch fuer eigene Angebote und auch dann, wenn die Ansage wie eine normale Information klingt. Wenn eine Ankuendigung dazu dient, Tickets, Teilnahme, Buchung, Kauf, Support oder Konsum eines anderen Angebots auszuloesen, ist sie Promotion und nicht redaktioneller Inhalt. Wenn mehrere direkte Nachbarkapitel denselben Support-, Abo-, Spenden-, Preis-, Zahlungs- oder Mitgliedschaftsaufruf ausfuehren, muessen alle diese Nachbarkapitel isSponsor true bleiben. Dann muss isSponsor true sein und der Titel mit 'Sponsor: ' beginnen. Wenn der Abschnitt primaer Serviceinformation zum laufenden Podcast ist, bleibt isSponsor false; nur ein klar abtrennbarer Bewerbungs- oder Nutzungsaufruf wird Promotion.\n"

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
        private var localSponsorOutput: String?
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

        func recordLocalSponsorOutput(_ output: String) {
            localSponsorOutput = Self.limited(output)
            write(reason: "local-sponsor-output")
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
                "localSponsorOutput": localSponsorOutput ?? "",
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
                               debugEpisodeHash: String? = nil,
                               episodeTitle: String? = nil,
                               feedTitle: String? = nil) async throws -> [ICGeneratedChapter] {
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
        switch selectedModel.chapterProvider {
        case .appleFoundation:
            guard ChapterGenerator.isAvailable() else {
                throw NSError(domain: "ChapterGenerator", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"])
            }
            return try await self.generateWithLLM(cues: cues, musicSegments: musicSegments,
                                                  existingChapters: nil, status: status, progress: progress,
                                                  debugTrace: debugTrace,
                                                  episodeTitle: episodeTitle,
                                                  feedTitle: feedTitle)
        case .openAIAPI, .openAICodexOAuth, .anthropicAPI, .kimiAPI:
            return try await self.generateWithRemoteChapterModel(model: selectedModel,
                                                                 cues: cues,
                                                                 musicSegments: musicSegments,
                                                                 existingChapters: nil,
                                                                 status: status,
                                                                 progress: progress,
                                                                 debugTrace: debugTrace,
                                                                 episodeTitle: episodeTitle,
                                                                 feedTitle: feedTitle)
        case .localGGUF:
            break
        }

        return try await self.generateWithLocalGGUF(model: selectedModel,
                                                    cues: cues,
                                                    musicSegments: musicSegments,
                                                    existingChapters: nil,
                                                    status: status,
                                                    progress: progress,
                                                    debugTrace: debugTrace,
                                                    episodeTitle: episodeTitle,
                                                    feedTitle: feedTitle)
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
                switch selectedModel.chapterProvider {
                case .appleFoundation:
                    guard ChapterGenerator.isAvailable() else {
                        throw NSError(domain: "ChapterGenerator", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"])
                    }
                    chapters = try await self.generateWithLLM(cues: cues, musicSegments: nil,
                                                              existingChapters: existingChapters,
                                                              debugTrace: nil)
                case .openAIAPI, .openAICodexOAuth, .anthropicAPI, .kimiAPI:
                    chapters = try await self.generateWithRemoteChapterModel(model: selectedModel,
                                                                             cues: cues,
                                                                             musicSegments: nil,
                                                                             existingChapters: existingChapters,
                                                                             debugTrace: nil)
                case .localGGUF:
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
                                 debugTrace: ChapterDebugTrace?,
                                 episodeTitle: String? = nil,
                                 feedTitle: String? = nil) async throws -> [ICGeneratedChapter] {
        guard #available(iOS 26, *) else {
            throw NSError(domain: "ChapterGenerator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "iOS 26 required"])
        }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        let contextSize = model.contextSize
        let maxInputTokens = max(1, Int(Double(contextSize) * Self.targetInputContextRatio))

        NSLog("[ChapterGenerator] Context window: %d tokens, max input: %d tokens", contextSize, maxInputTokens)

        // The chapter model must see the full transcript to avoid local chunk boundaries
        // becoming artificial chapter boundaries.
        let totalDuration = max(cues.last?.end ?? 0, 1)
        let windows = try await transcriptContextWindowsForModel(cues,
                                                                 musicSegments: musicSegments,
                                                                 totalDuration: totalDuration,
                                                                 model: model,
                                                                 maxInputTokens: maxInputTokens,
                                                                 episodeTitle: episodeTitle,
                                                                 feedTitle: feedTitle)
        let totalSegments = windows.count
        debugTrace?.recordPreparation(engine: "foundation-models",
                                      totalDuration: totalDuration,
                                      segmentCount: totalSegments)

        NSLog("[ChapterGenerator] %d cues → %d context window(s), total duration %.0fs", cues.count, totalSegments, totalDuration)
        await MainActor.run {
            status?(NSLocalizedString("Transkript wird mit maximalem Kontext für das Kapitelmodell vorbereitet.", comment: ""))
        }
        await MainActor.run { progress?(0.05, 0, totalSegments + 1) }

        // Pass 1: Extract topic markers via @Generable structured output.
        // The LLM returns a typed GeneratedTopicMarkersList — no string parsing needed.
        var topicMarkers: [TopicMarker] = []

        for (index, window) in windows.enumerated() {
            let segment = window.cues
            guard !Task.isCancelled else { throw CancellationError() }

            let segStart = window.start
            let segEnd = window.end
            let prompt = buildTopicExtractionPrompt(cues: segment,
                                                    allCues: cues,
                                                    musicSegments: musicSegments,
                                                    segStart: segStart,
                                                    segEnd: segEnd,
                                                    totalDuration: totalDuration,
                                                    episodeTitle: episodeTitle,
                                                    feedTitle: feedTitle)

            NSLog("[ChapterGenerator] Pass 1 %d/%d [%@–%@]: %d cues, %d chars",
                  index + 1, totalSegments, formatTime(segStart), formatTime(segEnd), segment.count, prompt.count)
            await MainActor.run {
                status?(String(format: NSLocalizedString("Pass 1/2: Themenwechsel in Kontextfenster %d von %d werden extrahiert.", comment: ""), index + 1, totalSegments))
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

            var rawSegmentMarkers: [TopicMarker] = []
            for m in response.content.markers {
                var t = Double(m.timeSeconds)
                // Clamp — the LLM occasionally hallucinates timestamps outside the segment range
                if t < segStart { t = segStart }
                if t > segEnd { t = segEnd }
                let title = m.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    rawSegmentMarkers.append((time: t, title: title))
                }
            }
            let segmentMarkers = Self.normalizedTopicMarkers(rawSegmentMarkers,
                                                             segmentStart: segStart,
                                                             segmentEnd: segEnd)
            topicMarkers.append(contentsOf: segmentMarkers)
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
                                                               existingChapters: existingChapters,
                                                               transcriptCues: cues,
                                                               model: model,
                                                               maxInputTokens: maxInputTokens,
                                                               status: status,
                                                               progress: progress,
                                                               progressTotal: totalSegments + 1)
        let finalPrompt = buildFinalChaptersPrompt(
            markers: finalMarkers, totalDuration: totalDuration,
            existingChapters: existingChapters,
            transcriptCues: cues)
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
        try Self.validateRawGeneratedChapterTiming(rawChapters,
                                                   totalDuration: totalDuration,
                                                   existingChapters: existingChapters,
                                                   debugTrace: debugTrace)
        var chapters = Self.normalizedChapters(rawChapters,
                                               totalDuration: totalDuration,
                                               forceContinuousBoundaries: existingChapters == nil)
        if existingChapters == nil {
            chapters = Self.chaptersByAddingMusicBoundaryChapters(chapters,
                                                                  musicSegments: musicSegments,
                                                                  transcriptCues: cues,
                                                                  transcriptDuration: totalDuration)
            chapters = Self.chaptersByMergingTerminalFragmentsIntoOutro(chapters,
                                                                        transcriptDuration: totalDuration)
            chapters = Self.chaptersByMergingShortFragmentsAroundStructuralChapters(chapters,
                                                                                   totalDuration: totalDuration)
            chapters = Self.chaptersByMergingShortFragmentsBeforeStructuralChapters(chapters,
                                                                                   totalDuration: totalDuration)
            chapters = Self.chaptersByApplyingEpisodeTitleToSingleContentChapter(chapters,
                                                                                 episodeTitle: episodeTitle,
                                                                                 transcriptCues: cues)
            chapters = Self.chaptersByReplacingGenericContentTitles(chapters,
                                                                    transcriptCues: cues)
            chapters = Self.chaptersByReplacingVerboseContentTitles(chapters,
                                                                    transcriptCues: cues)
        }
        debugTrace?.recordChapters(raw: rawChapters, final: chapters)
        chapters = try Self.validatedGeneratedChapters(chapters,
                                                       totalDuration: totalDuration,
                                                       topicMarkerCount: topicMarkers.count,
                                                       topicMarkers: finalMarkers,
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

    private struct LocalChapterStartsResponse: Decodable {
        let chapters: [LocalChapterStart]
    }

    private struct LocalChapterStart: Decodable {
        let startSeconds: Int
        let title: String
        let isSponsor: Bool
        let evidenceText: String?
    }

    private static let localChapterSystemPrompt = """
    Du bist ein praeziser Podcast-Kapitelgenerator. Arbeite sprachunabhaengig nur mit den angegebenen Zeiten, Texten und Audiohinweisen. Nutze den ganzen gelieferten Kontext. Erfinde keine Inhalte, Sprecher, Marken, Intros, Outros, Jingles, Sponsoren oder Themen. Audiohinweise sind nur Hinweise auf SoundAnalysis-Zeitbereiche; verwende sie nur, wenn das Transkript in der Umgebung ihre Bedeutung stuetzt. Erkenne skip-wuerdige Promotion semantisch in jeder Sprache und trenne sie als eigenes Sponsor-Kapitel. Kapitel-Titel muessen fuer Hoerer konkret genug sein, um die Auswahl oder das Ueberspringen zu entscheiden. Antworte ausschliesslich mit validem JSON, ohne Markdown und ohne Erklaertext.
    """

    private static let remoteChapterStartsSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["chapters"],
        "properties": [
            "chapters": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["startSeconds", "title", "isSponsor", "evidenceText"],
                    "properties": [
                        "startSeconds": ["type": "integer"],
                        "title": ["type": "string"],
                        "isSponsor": ["type": "boolean"],
                        "evidenceText": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    private func generateWithRemoteChapterModel(model: ICDownloadableModel,
                                                cues: [ICTranscriptCue],
                                                musicSegments: [ICAudioSegment]?,
                                                existingChapters: [ICGeneratedChapter]?,
                                                status: ((String) -> Void)? = nil,
                                                progress: ((Float, Int, Int) -> Void)? = nil,
                                                debugTrace: ChapterDebugTrace?,
                                                episodeTitle: String? = nil,
                                                feedTitle: String? = nil) async throws -> [ICGeneratedChapter] {
        let totalDuration = max(cues.last?.end ?? 0, 1)
        debugTrace?.recordPreparation(engine: "remote-\(model.identifier)",
                                      totalDuration: totalDuration,
                                      segmentCount: 1)

        if let existingChapters {
            let prompt = buildLocalSponsorClassificationPrompt(chapters: existingChapters,
                                                               cues: cues,
                                                               totalDuration: totalDuration,
                                                               episodeTitle: episodeTitle,
                                                               feedTitle: feedTitle)
            status?(String(format: NSLocalizedString("%@ prüft Sponsor- und Eigenpromo-Segmente.", comment: ""), model.title))
            progress?(0, 0, 1)
            let output = try await generateRemoteJSONObject(model: model, prompt: prompt, responseShape: .chapters)
            let response = try decodeLocalJSON(LocalChaptersResponse.self, from: output)
            let chapters = response.chapters.map {
                ICGeneratedChapter(start: Double($0.startSeconds),
                                   end: Double($0.endSeconds),
                                   title: $0.title,
                                   isSponsor: $0.isSponsor)
            }
            progress?(1.0, 1, 1)
            return chapters
        }

        let prompt = buildRemoteDirectChaptersPrompt(cues: cues,
                                                     allCues: cues,
                                                     musicSegments: musicSegments,
                                                     totalDuration: totalDuration,
                                                     episodeTitle: episodeTitle,
                                                     feedTitle: feedTitle)
        let started = Date()
        status?(String(format: NSLocalizedString("%@ erstellt Kapitel aus dem vollständigen Transkript.", comment: ""), model.title))
        progress?(0, 0, 1)
        debugTrace?.recordPerformance("remote-chapter-started",
                                      metadata: [
                                        "modelIdentifier": model.identifier,
                                        "modelTitle": model.title,
                                        "provider": model.chapterProvider.rawValue,
                                        "promptCharacters": prompt.count,
                                        "cueCount": cues.count,
                                        "musicSegmentCount": musicSegments?.count ?? 0,
                                      ])

        var output = try await generateRemoteJSONObject(model: model, prompt: prompt, responseShape: .chapterStarts)
        var response = try decodeLocalJSON(LocalChapterStartsResponse.self, from: output)
        if let evidenceIssue = Self.rawChapterStartEvidenceIssue(response.chapters, transcriptCues: cues) {
            debugTrace?.recordPerformance("remote-chapter-evidence-validation-failed",
                                          metadata: [
                                            "issue": evidenceIssue,
                                            "chapterCount": response.chapters.count,
                                            "outputCharacters": output.count,
                                            "durationSeconds": String(format: "%.3f", -started.timeIntervalSinceNow),
                                          ])
            let retryPrompt = buildRemoteEvidenceRetryPrompt(originalPrompt: prompt, evidenceIssue: evidenceIssue)
            status?(String(format: NSLocalizedString("%@ korrigiert Kapitelstarts anhand der Belegstellen.", comment: ""), model.title))
            debugTrace?.recordPerformance("remote-chapter-evidence-retry-started",
                                          metadata: [
                                            "modelIdentifier": model.identifier,
                                            "promptCharacters": retryPrompt.count,
                                          ])
            output = try await generateRemoteJSONObject(model: model, prompt: retryPrompt, responseShape: .chapterStarts)
            response = try decodeLocalJSON(LocalChapterStartsResponse.self, from: output)
        }
        debugTrace?.recordLocalFinalOutput(output)
        try Self.validateRemoteChapterStartEvidence(response.chapters,
                                                    transcriptCues: cues,
                                                    debugTrace: debugTrace)
        let rawChapters = Self.chaptersFromGeneratedStarts(response.chapters, totalDuration: totalDuration)
        try Self.validateRawGeneratedChapterTiming(rawChapters,
                                                   totalDuration: totalDuration,
                                                   existingChapters: nil,
                                                   debugTrace: debugTrace)
        let markers = rawChapters.map { (time: $0.start, title: $0.title) }
        var chapters = Self.normalizedChapters(rawChapters,
                                               totalDuration: totalDuration,
                                               forceContinuousBoundaries: true)
        chapters = try Self.validatedGeneratedChapters(chapters,
                                                       totalDuration: totalDuration,
                                                       topicMarkerCount: markers.count,
                                                       topicMarkers: markers,
                                                       musicSegments: nil,
                                                       transcriptCues: cues,
                                                       existingChapters: nil,
                                                       debugTrace: debugTrace)
        chapters = try await remoteChaptersByClassifyingSponsors(chapters,
                                                                 model: model,
                                                                 cues: cues,
                                                                 totalDuration: totalDuration,
                                                                 status: status,
                                                                 progress: progress,
                                                                 episodeTitle: episodeTitle,
                                                                 feedTitle: feedTitle,
                                                                 debugTrace: debugTrace)
        guard !chapters.isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 18,
                          userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — das Kapitelmodell hat keine Kapitel erzeugt."])
        }

        debugTrace?.recordChapters(raw: rawChapters, final: chapters)
        debugTrace?.recordPerformance("remote-chapter-completed",
                                      metadata: [
                                        "modelIdentifier": model.identifier,
                                        "chapterCount": chapters.count,
                                        "sponsorChapterCount": chapters.filter { $0.isSponsor }.count,
                                        "outputCharacters": output.count,
                                        "durationSeconds": String(format: "%.3f", -started.timeIntervalSinceNow),
                                      ])
        progress?(1.0, 1, 1)
        return chapters
    }

    private enum RemoteResponseShape {
        case chapterStarts
        case chapters
    }

    private func generateRemoteJSONObject(model: ICDownloadableModel,
                                          prompt: String,
                                          responseShape: RemoteResponseShape) async throws -> String {
        let modelName = model.remoteModelName ?? model.identifier
        switch model.chapterProvider {
        case .openAIAPI:
            guard let apiKey = ICRemoteChapterCredentialStore.openAIAPIKey(), !apiKey.isEmpty else {
                throw NSError(domain: "ChapterGenerator", code: 30,
                              userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("OpenAI API-Key fehlt.", comment: "")])
            }
            return try await generateOpenAIAPIJSONObject(modelName: modelName,
                                                         apiKey: apiKey,
                                                         prompt: prompt,
                                                         responseShape: responseShape)
        case .openAICodexOAuth:
            return try await generateOpenAICodexOAuthJSONObject(modelName: modelName,
                                                                prompt: prompt,
                                                                responseShape: responseShape)
        case .anthropicAPI:
            guard let apiKey = ICRemoteChapterCredentialStore.anthropicAPIKey(), !apiKey.isEmpty else {
                throw NSError(domain: "ChapterGenerator", code: 31,
                              userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Anthropic API-Key fehlt.", comment: "")])
            }
            return try await generateAnthropicJSONObject(modelName: modelName,
                                                         apiKey: apiKey,
                                                         prompt: prompt,
                                                         responseShape: responseShape)
        case .kimiAPI:
            guard let apiKey = ICRemoteChapterCredentialStore.kimiAPIKey(), !apiKey.isEmpty else {
                throw NSError(domain: "ChapterGenerator", code: 40,
                              userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kimi Zugang fehlt.", comment: "")])
            }
            return try await generateKimiJSONObject(modelName: modelName,
                                                    apiKey: apiKey,
                                                    prompt: prompt,
                                                    responseShape: responseShape)
        default:
            throw NSError(domain: "ChapterGenerator", code: 32,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Remote-Kapitelmodell ist ungültig.", comment: "")])
        }
    }

    private func generateOpenAIAPIJSONObject(modelName: String,
                                             apiKey: String,
                                             prompt: String,
                                             responseShape: RemoteResponseShape) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: openAIResponsesBody(modelName: modelName,
                                                                                          prompt: prompt,
                                                                                          stream: false,
                                                                                          responseShape: responseShape))

        let (data, statusCode) = try await remoteDataAndStatusCode(for: request)
        guard (200..<300).contains(statusCode) else {
            throw remoteHTTPError(statusCode: statusCode, data: data, provider: "OpenAI")
        }
        return try Self.openAIOutputText(from: data)
    }

    private func generateOpenAICodexOAuthJSONObject(modelName: String,
                                                    prompt: String,
                                                    responseShape: RemoteResponseShape) async throws -> String {
        let token = try await ICRemoteChapterCredentialStore.refreshedOpenAIOAuthAccessToken()
        do {
            return try await generateOpenAICodexOAuthJSONObject(modelName: modelName,
                                                                token: token,
                                                                prompt: prompt,
                                                                responseShape: responseShape)
        } catch let error as NSError where error.domain == "ChapterGenerator.RemoteHTTP" && error.code == 401 {
            let refreshedToken = try await ICRemoteChapterCredentialStore.refreshOpenAIOAuthAccessToken()
            return try await generateOpenAICodexOAuthJSONObject(modelName: modelName,
                                                                token: refreshedToken,
                                                                prompt: prompt,
                                                                responseShape: responseShape)
        }
    }

    private func generateOpenAICodexOAuthJSONObject(modelName: String,
                                                    token: String,
                                                    prompt: String,
                                                    responseShape: RemoteResponseShape) async throws -> String {
        guard let accountID = ICRemoteChapterCredentialStore.openAIOAuthAccountID(), !accountID.isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 33,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Codex Login enthält keine Account-ID.", comment: "")])
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        if ICRemoteChapterCredentialStore.openAIOAuthIsFedRAMPAccount() {
            request.setValue("true", forHTTPHeaderField: "X-OpenAI-Fedramp")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: openAIResponsesBody(modelName: modelName,
                                                                                          prompt: prompt,
                                                                                          stream: true,
                                                                                          responseShape: responseShape))

        let (data, statusCode) = try await remoteDataAndStatusCode(for: request)
        guard (200..<300).contains(statusCode) else {
            throw remoteHTTPError(statusCode: statusCode, data: data, provider: "ChatGPT")
        }
        return try Self.openAIOutputText(fromSSEData: data)
    }

    private func generateAnthropicJSONObject(modelName: String,
                                             apiKey: String,
                                             prompt: String,
                                             responseShape: RemoteResponseShape) async throws -> String {
        let userPrompt = prompt + anthropicJSONResponseInstruction(responseShape)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "max_tokens": 8192,
            "temperature": 0,
            "system": Self.localChapterSystemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": userPrompt,
                ],
            ],
        ])

        let (data, statusCode) = try await remoteDataAndStatusCode(for: request)
        guard (200..<300).contains(statusCode) else {
            throw remoteHTTPError(statusCode: statusCode, data: data, provider: "Anthropic")
        }
        return try Self.anthropicOutputText(from: data)
    }

    private func generateKimiJSONObject(modelName: String,
                                        apiKey: String,
                                        prompt: String,
                                        responseShape: RemoteResponseShape) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.moonshot.ai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: kimiChatCompletionsBody(modelName: modelName,
                                                                                              prompt: prompt,
                                                                                              responseShape: responseShape))

        let (data, statusCode) = try await remoteDataAndStatusCode(for: request)
        guard (200..<300).contains(statusCode) else {
            throw remoteHTTPError(statusCode: statusCode, data: data, provider: "Kimi")
        }
        return try Self.openAIChatCompletionOutputText(from: data, provider: "Kimi")
    }

    private func openAIResponsesBody(modelName: String,
                                     prompt: String,
                                     stream: Bool,
                                     responseShape: RemoteResponseShape) -> [String: Any] {
        return [
            "model": modelName,
            "instructions": Self.localChapterSystemPrompt,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": prompt,
                        ],
                    ],
                ],
            ],
            "tools": [],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "stream": stream,
            "include": [],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": responseShape == .chapterStarts ? "podcast_chapter_starts" : "podcast_chapters",
                    "strict": true,
                    "schema": responseShape == .chapterStarts ? Self.remoteChapterStartsSchema : Self.remoteChaptersSchema,
                ],
            ],
        ]
    }

    private func kimiChatCompletionsBody(modelName: String,
                                         prompt: String,
                                         responseShape: RemoteResponseShape) -> [String: Any] {
        return [
            "model": modelName,
            "messages": [
                [
                    "role": "system",
                    "content": Self.localChapterSystemPrompt,
                ],
                [
                    "role": "user",
                    "content": prompt,
                ],
            ],
            "max_tokens": 8192,
            "stream": false,
            "thinking": ["type": "disabled"],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": responseShape == .chapterStarts ? "podcast_chapter_starts" : "podcast_chapters",
                    "strict": true,
                    "schema": responseShape == .chapterStarts ? Self.remoteChapterStartsSchema : Self.remoteChaptersSchema,
                ],
            ],
        ]
    }

    private static let remoteChaptersSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["chapters"],
        "properties": [
            "chapters": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["startSeconds", "endSeconds", "title", "isSponsor"],
                    "properties": [
                        "startSeconds": ["type": "integer"],
                        "endSeconds": ["type": "integer"],
                        "title": ["type": "string"],
                        "isSponsor": ["type": "boolean"],
                    ],
                ],
            ],
        ],
    ]

    private func anthropicJSONResponseInstruction(_ responseShape: RemoteResponseShape) -> String {
        switch responseShape {
        case .chapterStarts:
            return "\n\nAntworte nur mit JSON im Format {\"chapters\":[{\"startSeconds\":0,\"title\":\"...\",\"isSponsor\":false,\"evidenceText\":\"kurzer Beleg direkt nach startSeconds\"}]}. Keine Markdown-Blöcke."
        case .chapters:
            return "\n\nAntworte nur mit JSON im Format {\"chapters\":[{\"startSeconds\":0,\"endSeconds\":60,\"title\":\"...\",\"isSponsor\":false}]}. Keine Markdown-Blöcke."
        }
    }

    private func remoteDataAndStatusCode(for request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5 * 60
        configuration.timeoutIntervalForResource = 30 * 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ChapterGenerator", code: 34,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Remote-Kapitelmodell lieferte keine HTTP-Antwort.", comment: "")])
        }
        return (data, http.statusCode)
    }

    private func remoteHTTPError(statusCode: Int, data: Data, provider: String) -> NSError {
        let body = String(data: data, encoding: .utf8) ?? ""
        let snippet = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)
        let message = snippet.isEmpty
            ? String(format: NSLocalizedString("%@ Kapitelmodell fehlgeschlagen. HTTP %d", comment: ""), provider, statusCode)
            : String(format: NSLocalizedString("%@ Kapitelmodell fehlgeschlagen. HTTP %d: %@", comment: ""), provider, statusCode, String(snippet))
        return NSError(domain: "ChapterGenerator.RemoteHTTP", code: statusCode,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func openAIOutputText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = openAIOutputText(fromJSONObject: object),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 35,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("OpenAI Kapitelmodell lieferte keinen Text.", comment: "")])
        }
        return text
    }

    private static func openAIOutputText(fromSSEData data: Data) throws -> String {
        guard let sse = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "ChapterGenerator", code: 36,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("ChatGPT Kapitelmodell lieferte keine lesbare Antwort.", comment: "")])
        }

        var output = ""
        var completedResponse: [String: Any]?
        for rawLine in sse.components(separatedBy: .newlines) {
            guard rawLine.hasPrefix("data: ") else { continue }
            let payload = String(rawLine.dropFirst(6))
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if event["type"] as? String == "response.output_text.delta",
               let delta = event["delta"] as? String {
                output += delta
            } else if event["type"] as? String == "response.completed",
                      let response = event["response"] as? [String: Any] {
                completedResponse = response
            } else if event["type"] as? String == "response.output_item.done",
                      let item = event["item"] as? [String: Any],
                      let text = openAIOutputText(fromJSONObject: ["output": [item]]) {
                output += text
            }
        }

        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let completedResponse,
           let text = openAIOutputText(fromJSONObject: completedResponse) {
            output = text
        }

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 37,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("ChatGPT Kapitelmodell lieferte keinen Text.", comment: "")])
        }
        return output
    }

    private static func openAIOutputText(fromJSONObject object: [String: Any]) -> String? {
        if let text = object["output_text"] as? String {
            return text
        }
        guard let output = object["output"] as? [[String: Any]] else { return nil }
        var text = ""
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for contentItem in content {
                if let value = contentItem["text"] as? String {
                    text += value
                }
            }
        }
        return text.isEmpty ? nil : text
    }

    private static func openAIChatCompletionOutputText(from data: Data, provider: String) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw NSError(domain: "ChapterGenerator", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("%@ Kapitelmodell lieferte keine lesbare Antwort.", comment: ""), provider)])
        }

        let text: String
        if let content = message["content"] as? String {
            text = content
        } else if let content = message["content"] as? [[String: Any]] {
            text = content.compactMap { item in
                if let value = item["text"] as? String { return value }
                if let value = item["content"] as? String { return value }
                return nil
            }.joined()
        } else {
            text = ""
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("%@ Kapitelmodell lieferte keinen Text.", comment: ""), provider)])
        }
        return text
    }

    private static func anthropicOutputText(from data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else {
            throw NSError(domain: "ChapterGenerator", code: 38,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Anthropic Kapitelmodell lieferte keine lesbare Antwort.", comment: "")])
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 39,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Anthropic Kapitelmodell lieferte keinen Text.", comment: "")])
        }
        return text
    }

    private func generateWithLocalGGUF(model: ICDownloadableModel,
                                       cues: [ICTranscriptCue],
                                       musicSegments: [ICAudioSegment]?,
                                       existingChapters: [ICGeneratedChapter]?,
                                       status: ((String) -> Void)? = nil,
                                       progress: ((Float, Int, Int) -> Void)? = nil,
                                       debugTrace: ChapterDebugTrace?,
                                       episodeTitle: String? = nil,
                                       feedTitle: String? = nil) async throws -> [ICGeneratedChapter] {
        guard ICDownloadableModelStore.isDownloaded(model: model),
              let modelURL = ICDownloadableModelStore.modelFileURL(for: model),
              FileManager.default.fileExists(atPath: modelURL.path) else {
            throw NSError(domain: "ChapterGenerator", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: "")])
        }

        let totalDuration = max(cues.last?.end ?? 0, 1)
        let fullPrompt = buildLocalTopicExtractionPrompt(cues: cues,
                                                         allCues: cues,
                                                         musicSegments: musicSegments,
                                                         segStart: cues.first?.start ?? 0,
                                                         segEnd: cues.last?.end ?? totalDuration,
                                                         totalDuration: totalDuration,
                                                         episodeTitle: episodeTitle,
                                                         feedTitle: feedTitle)
        let requestedContextTokens = Self.localContextTokens(forPromptCharacters: fullPrompt.count)

        status?(String(format: NSLocalizedString("%@ wird geladen.", comment: ""), model.title))
        progress?(0.01, 0, 1)

        let modelLoadStart = Date()
        let runner = try await Task.detached(priority: .userInitiated) {
            try LocalGGUFModelRunner.create(modelURL: modelURL, contextTokens: requestedContextTokens)
        }.value
        let contextWindowTokens = await runner.contextWindowTokens
        let maxInputTokens = await runner.maxInputTokens
        NSLog("[ChapterGenerator] Local GGUF context window: %d tokens, max input: %d tokens", contextWindowTokens, maxInputTokens)
        debugTrace?.recordPerformance("local-model-loaded",
                                      metadata: [
                                        "modelIdentifier": model.identifier,
                                        "modelTitle": model.title,
                                        "durationSeconds": String(format: "%.3f", -modelLoadStart.timeIntervalSinceNow),
                                        "requestedContextTokens": requestedContextTokens,
                                        "contextWindowTokens": contextWindowTokens,
                                        "maxInputTokens": maxInputTokens,
                                      ])

        let windows = try await transcriptContextWindowsForLocalModel(cues,
                                                                      musicSegments: musicSegments,
                                                                      totalDuration: totalDuration,
                                                                      runner: runner,
                                                                      maxInputTokens: maxInputTokens,
                                                                      episodeTitle: episodeTitle,
                                                                      feedTitle: feedTitle)
        let totalSegments = windows.count
        debugTrace?.recordPreparation(engine: "local-gguf",
                                      totalDuration: totalDuration,
                                      segmentCount: totalSegments)
        debugTrace?.recordPerformance("local-chapter-started",
                                      metadata: [
                                        "cueCount": cues.count,
                                        "musicSegmentCount": musicSegments?.count ?? 0,
                                        "segmentCount": totalSegments,
                                        "totalDurationSeconds": String(format: "%.3f", totalDuration),
                                        "requestedContextTokens": requestedContextTokens,
                                        "contextWindowTokens": contextWindowTokens,
                                        "maxInputTokens": maxInputTokens,
                                        "existingChapterCount": existingChapters?.count ?? 0,
                                      ])

        if existingChapters == nil, totalSegments == 1, let window = windows.first {
            let directPrompt = buildLocalDirectChaptersPrompt(cues: window.cues,
                                                              allCues: cues,
                                                              musicSegments: musicSegments,
                                                              totalDuration: totalDuration,
                                                              episodeTitle: episodeTitle,
                                                              feedTitle: feedTitle)
            if try await localPromptFitsContext(directPrompt, runner: runner, maxInputTokens: maxInputTokens) {
                let directStart = Date()
                status?(NSLocalizedString("Pass 1/1: Kapitelmodell erstellt Kapitel aus dem vollstaendigen Transkript.", comment: ""))
                progress?(0.05, 0, 1)
                debugTrace?.recordPass1SegmentStarted(index: 1,
                                                      start: window.start,
                                                      end: window.end,
                                                      cueCount: window.cues.count,
                                                      prompt: directPrompt,
                                                      promptCharacters: directPrompt.count)
                debugTrace?.recordPerformance("local-direct-chapters-started",
                                              metadata: [
                                                "cueCount": window.cues.count,
                                                "promptCharacters": directPrompt.count,
                                              ])
                let output = try await generateLocalJSONObject(runner: runner,
                                                               prompt: directPrompt,
                                                               grammar: .chapterStarts,
                                                               maxNewTokens: localDirectChapterMaxNewTokens(duration: totalDuration))
                debugTrace?.recordLocalFinalOutput(output)
                let response = try decodeLocalJSON(LocalChapterStartsResponse.self, from: output)
                let rawChapters = Self.chaptersFromGeneratedStarts(response.chapters, totalDuration: totalDuration)
                try Self.validateRawGeneratedChapterTiming(rawChapters,
                                                           totalDuration: totalDuration,
                                                           existingChapters: existingChapters,
                                                           debugTrace: debugTrace)
                let directMarkers = rawChapters.map { (time: $0.start, title: $0.title) }
                debugTrace?.recordPass1Segment(index: 1,
                                               start: window.start,
                                               end: window.end,
                                               cueCount: window.cues.count,
                                               prompt: directPrompt,
                                               promptCharacters: directPrompt.count,
                                               markerCount: directMarkers.count,
                                               markers: directMarkers,
                                               rawOutput: output)
                debugTrace?.recordMarkers(beforeDedup: directMarkers.count,
                                          afterDedup: directMarkers.count)
                debugTrace?.recordFinalPrompt(markerCount: directMarkers.count)

                var chapters = Self.normalizedChapters(rawChapters,
                                                       totalDuration: totalDuration,
                                                       forceContinuousBoundaries: true)
                chapters = Self.chaptersByAddingMusicBoundaryChapters(chapters,
                                                                      musicSegments: musicSegments,
                                                                      transcriptCues: cues,
                                                                      transcriptDuration: totalDuration)
                chapters = Self.chaptersByMergingTerminalFragmentsIntoOutro(chapters,
                                                                            transcriptDuration: totalDuration)
                chapters = Self.chaptersByMergingShortFragmentsAroundStructuralChapters(chapters,
                                                                                       totalDuration: totalDuration)
                chapters = Self.chaptersByMergingShortFragmentsBeforeStructuralChapters(chapters,
                                                                                       totalDuration: totalDuration)
                chapters = Self.chaptersByApplyingEpisodeTitleToSingleContentChapter(chapters,
                                                                                     episodeTitle: episodeTitle,
                                                                                     transcriptCues: cues)
                chapters = Self.chaptersByReplacingGenericContentTitles(chapters,
                                                                        transcriptCues: cues)
                chapters = Self.chaptersByReplacingVerboseContentTitles(chapters,
                                                                        transcriptCues: cues)
                chapters = try await localChaptersByClassifyingSponsors(chapters,
                                                                        cues: cues,
                                                                        totalDuration: totalDuration,
                                                                        runner: runner,
                                                                        maxInputTokens: maxInputTokens,
                                                                        status: status,
                                                                        progress: progress,
                                                                        episodeTitle: episodeTitle,
                                                                        feedTitle: feedTitle,
                                                                        debugTrace: debugTrace)
                debugTrace?.recordChapters(raw: rawChapters, final: chapters)
                debugTrace?.recordPerformance("local-direct-chapters-completed",
                                              metadata: [
                                                "promptCharacters": directPrompt.count,
                                                "outputCharacters": output.count,
                                                "rawChapterCount": rawChapters.count,
                                                "finalChapterCount": chapters.count,
                                                "sponsorChapterCount": chapters.filter { $0.isSponsor }.count,
                                                "durationSeconds": String(format: "%.3f", -directStart.timeIntervalSinceNow),
                                              ])
                chapters = try Self.validatedGeneratedChapters(chapters,
                                                               totalDuration: totalDuration,
                                                               topicMarkerCount: directMarkers.count,
                                                               topicMarkers: directMarkers,
                                                               musicSegments: musicSegments,
                                                               transcriptCues: cues,
                                                               existingChapters: existingChapters,
                                                               debugTrace: debugTrace)

                guard !chapters.isEmpty else {
                    throw NSError(domain: "ChapterGenerator", code: 18,
                                  userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — das Kapitelmodell hat keine Kapitel erzeugt."])
                }

                debugTrace?.recordPerformance("local-chapter-completed",
                                              metadata: [
                                                "chapterCount": chapters.count,
                                                "sponsorChapterCount": chapters.filter { $0.isSponsor }.count,
                                                "topicMarkerCount": directMarkers.count,
                                                "segmentCount": totalSegments,
                                                "mode": "direct-full-transcript",
                                              ])
                progress?(1.0, 1, 1)
                return chapters
            }
        }

        var topicMarkers: [TopicMarker] = []

        status?(NSLocalizedString("Pass 1/2: Kapitelmodell liest das Transkript mit maximalem Kontext und erkennt Themenwechsel.", comment: ""))
        progress?(0.05, 0, totalSegments + 1)

        for (index, window) in windows.enumerated() {
            let segment = window.cues
            guard !Task.isCancelled else {
                await runner.cancel()
                throw CancellationError()
            }

            let segStart = window.start
            let segEnd = window.end
            let prompt = buildLocalTopicExtractionPrompt(cues: segment,
                                                         allCues: cues,
                                                         musicSegments: musicSegments,
                                                         segStart: segStart,
                                                         segEnd: segEnd,
                                                         totalDuration: totalDuration,
                                                         episodeTitle: episodeTitle,
                                                         feedTitle: feedTitle)
            let segmentStart = Date()
            status?(String(format: NSLocalizedString("Pass 1/2: Themenwechsel in Kontextfenster %d von %d werden extrahiert.", comment: ""), index + 1, totalSegments))
            debugTrace?.recordPass1SegmentStarted(index: index + 1,
                                                  start: segStart,
                                                  end: segEnd,
                                                  cueCount: segment.count,
                                                  prompt: prompt,
                                                  promptCharacters: prompt.count)
            let output = try await generateLocalJSONObject(runner: runner,
                                                           prompt: prompt,
                                                           grammar: .markers,
                                                           maxNewTokens: localMarkerMaxNewTokens(cueCount: segment.count,
                                                                                                 duration: segEnd - segStart))
            let response = try decodeLocalJSON(LocalTopicMarkersResponse.self, from: output)
            let rawSegmentMarkers = response.markers.compactMap { marker -> TopicMarker? in
                let title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let time = min(max(Double(marker.timeSeconds), segStart), segEnd)
                return (time: time, title: title)
            }
            let segmentMarkers = Self.normalizedTopicMarkers(rawSegmentMarkers,
                                                             segmentStart: segStart,
                                                             segmentEnd: segEnd)
            topicMarkers.append(contentsOf: segmentMarkers)
            debugTrace?.recordPass1Segment(index: index + 1,
                                           start: segStart,
                                           end: segEnd,
                                           cueCount: segment.count,
                                           prompt: prompt,
                                           promptCharacters: prompt.count,
                                           markerCount: segmentMarkers.count,
                                           markers: segmentMarkers)
            debugTrace?.recordPerformance("local-pass1-segment-generated",
                                          metadata: [
                                            "index": index + 1,
                                            "segmentCount": totalSegments,
                                            "cueCount": segment.count,
                                            "promptCharacters": prompt.count,
                                            "outputCharacters": output.count,
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
        debugTrace?.recordPerformance("local-pass1-markers",
                                      metadata: [
                                        "markerCountBeforeDedup": markerCountBeforeDedup,
                                        "markerCountAfterDedup": topicMarkers.count,
                                      ])

        let finalMarkers: [TopicMarker]
        let rawChapters: [ICGeneratedChapter]
        let finalGenerationStart = Date()
        var pass2CompletionMetadata: [String: Any]

        if existingChapters == nil {
            finalMarkers = topicMarkers
            debugTrace?.recordFinalPrompt(markerCount: finalMarkers.count)
            status?(NSLocalizedString("Pass 2/2: Kapitelstruktur wird aus den erkannten Themenmarkern erstellt.", comment: ""))
            progress?(0.95, totalSegments, totalSegments + 1)
            debugTrace?.recordPerformance("local-pass2-started",
                                          metadata: [
                                            "mode": "topic-markers",
                                            "finalMarkerCount": finalMarkers.count,
                                            "promptCharacters": 0,
                                          ])
            rawChapters = Self.chaptersFromTopicMarkers(finalMarkers,
                                                        totalDuration: totalDuration)
            pass2CompletionMetadata = [
                "mode": "topic-markers",
                "finalMarkerCount": finalMarkers.count,
                "promptCharacters": 0,
                "outputCharacters": 0,
                "rawChapterCount": rawChapters.count,
            ]
        } else {
            finalMarkers = try await localMarkersFittingFinalPrompt(markers: topicMarkers,
                                                                    totalDuration: totalDuration,
                                                                    existingChapters: existingChapters,
                                                                    transcriptCues: cues,
                                                                    runner: runner,
                                                                    maxInputTokens: maxInputTokens,
                                                                    status: status,
                                                                    progress: progress,
                                                                    progressTotal: totalSegments + 1)
            let finalPrompt = buildLocalFinalChaptersPrompt(markers: finalMarkers,
                                                            totalDuration: totalDuration,
                                                            existingChapters: existingChapters,
                                                            transcriptCues: cues)
            debugTrace?.recordFinalPrompt(markerCount: finalMarkers.count)

            NSLog("[ChapterGenerator] Local pass 2: prompt %d chars from %d marker(s)", finalPrompt.count, finalMarkers.count)
            status?(NSLocalizedString("Pass 2/2: Kapitelmodell erstellt die finale JSON-Struktur. Das kann mehrere Minuten dauern.", comment: ""))
            progress?(0.95, totalSegments, totalSegments + 1)
            debugTrace?.recordPerformance("local-pass2-started",
                                          metadata: [
                                            "mode": "local-json",
                                            "finalMarkerCount": finalMarkers.count,
                                            "promptCharacters": finalPrompt.count,
                                          ])

            let output: String
            do {
                output = try await generateLocalJSONObject(runner: runner,
                                                           prompt: finalPrompt,
                                                           grammar: .chapters,
                                                           maxNewTokens: localChapterMaxNewTokens(markerCount: finalMarkers.count,
                                                                                                  existingChapters: existingChapters))
            } catch {
                debugTrace?.recordPerformance("local-pass2-failed",
                                              metadata: [
                                                "mode": "local-json",
                                                "finalMarkerCount": finalMarkers.count,
                                                "promptCharacters": finalPrompt.count,
                                                "durationSeconds": String(format: "%.3f", -finalGenerationStart.timeIntervalSinceNow),
                                                "error": error.localizedDescription,
                                              ])
                throw error
            }
            debugTrace?.recordLocalFinalOutput(output)
            let response = try decodeLocalJSON(LocalChaptersResponse.self, from: output)
            rawChapters = response.chapters.map {
                ICGeneratedChapter(start: Double($0.startSeconds),
                                   end: Double($0.endSeconds),
                                   title: $0.title,
                                   isSponsor: $0.isSponsor)
            }
            pass2CompletionMetadata = [
                "mode": "local-json",
                "finalMarkerCount": finalMarkers.count,
                "promptCharacters": finalPrompt.count,
                "outputCharacters": output.count,
                "rawChapterCount": rawChapters.count,
            ]
        }

        try Self.validateRawGeneratedChapterTiming(rawChapters,
                                                   totalDuration: totalDuration,
                                                   existingChapters: existingChapters,
                                                   debugTrace: debugTrace)
        var chapters = Self.normalizedChapters(rawChapters,
                                               totalDuration: totalDuration,
                                               forceContinuousBoundaries: existingChapters == nil)
        let preserveTopicMarkerTitles = existingChapters == nil
            && (pass2CompletionMetadata["mode"] as? String) == "topic-markers"
        if existingChapters == nil {
            chapters = Self.chaptersByAddingMusicBoundaryChapters(chapters,
                                                                  musicSegments: musicSegments,
                                                                  transcriptCues: cues,
                                                                  transcriptDuration: totalDuration)
            chapters = Self.chaptersByMergingTerminalFragmentsIntoOutro(chapters,
                                                                        transcriptDuration: totalDuration)
            chapters = Self.chaptersByMergingShortFragmentsAroundStructuralChapters(chapters,
                                                                                   totalDuration: totalDuration)
            chapters = Self.chaptersByMergingShortFragmentsBeforeStructuralChapters(chapters,
                                                                                   totalDuration: totalDuration)
                chapters = Self.chaptersByApplyingEpisodeTitleToSingleContentChapter(chapters,
                                                                                 episodeTitle: episodeTitle,
                                                                                 transcriptCues: cues)
            if !preserveTopicMarkerTitles {
                chapters = Self.chaptersByReplacingGenericContentTitles(chapters,
                                                                        transcriptCues: cues)
                chapters = Self.chaptersByReplacingVerboseContentTitles(chapters,
                                                                        transcriptCues: cues)
            }
            chapters = try await localChaptersByClassifyingSponsors(chapters,
                                                                    cues: cues,
                                                                    totalDuration: totalDuration,
                                                                    runner: runner,
                                                                    maxInputTokens: maxInputTokens,
                                                                    status: status,
                                                                    progress: progress,
                                                                    episodeTitle: episodeTitle,
                                                                    feedTitle: feedTitle,
                                                                    debugTrace: debugTrace)
        }
        debugTrace?.recordChapters(raw: rawChapters, final: chapters)
        pass2CompletionMetadata["finalChapterCount"] = chapters.count
        pass2CompletionMetadata["sponsorChapterCount"] = chapters.filter { $0.isSponsor }.count
        pass2CompletionMetadata["durationSeconds"] = String(format: "%.3f", -finalGenerationStart.timeIntervalSinceNow)
        debugTrace?.recordPerformance("local-pass2-completed",
                                      metadata: pass2CompletionMetadata)
        chapters = try Self.validatedGeneratedChapters(chapters,
                                                       totalDuration: totalDuration,
                                                       topicMarkerCount: topicMarkers.count,
                                                       topicMarkers: finalMarkers,
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

    private func buildLocalTopicExtractionPrompt(cues: [ICTranscriptCue],
                                                 allCues: [ICTranscriptCue],
                                                 musicSegments: [ICAudioSegment]?,
                                                 segStart: Double,
                                                 segEnd: Double,
                                                 totalDuration: Double,
                                                 episodeTitle: String?,
                                                 feedTitle: String?) -> String {
        var prompt = buildTopicExtractionPrompt(cues: cues,
                                                allCues: allCues,
                                                musicSegments: musicSegments,
                                                segStart: segStart,
                                                segEnd: segEnd,
                                                totalDuration: totalDuration,
                                                episodeTitle: episodeTitle,
                                                feedTitle: feedTitle)
        prompt += "\nRegeln fuer lokale Erkennung:\n"
        prompt += "- Ein zusammenhaengendes Thema darf sehr lang sein; unterteile nie nur wegen der Dauer.\n"
        prompt += "- Nutze nur Zeitpunkte aus dem Transkript oder den Abschnittsanfang.\n"
        prompt += "\n\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"markers\" als Array. Jeder Eintrag enthaelt \"timeSeconds\" als Ganzzahl ab Podcast-Anfang und \"title\" als nicht leeren String. Verwende keine Beispielwerte.\n"
        return prompt
    }

    private func buildLocalDirectChaptersPrompt(cues: [ICTranscriptCue],
                                                allCues: [ICTranscriptCue],
                                                musicSegments: [ICAudioSegment]?,
                                                totalDuration: Double,
                                                episodeTitle: String?,
                                                feedTitle: String?) -> String {
        var prompt = buildDirectChaptersPrompt(cues: cues,
                                               allCues: allCues,
                                               musicSegments: musicSegments,
                                               totalDuration: totalDuration,
                                               episodeTitle: episodeTitle,
                                               feedTitle: feedTitle)
        prompt += "\n\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"chapters\" als Array. Jeder Eintrag enthaelt nur \"startSeconds\" als Ganzzahl ab Podcast-Anfang, \"title\" als nicht leeren String und \"isSponsor\" als Boolean. Erzeuge kein \"endSeconds\"-Feld; Kapitelenden werden aus dem naechsten startSeconds berechnet. Verwende keine Beispielwerte.\n"
        return prompt
    }

    private func buildRemoteDirectChaptersPrompt(cues: [ICTranscriptCue],
                                                 allCues: [ICTranscriptCue],
                                                 musicSegments: [ICAudioSegment]?,
                                                 totalDuration: Double,
                                                 episodeTitle: String?,
                                                 feedTitle: String?) -> String {
        var prompt = buildDirectChaptersPrompt(cues: cues,
                                               allCues: allCues,
                                               musicSegments: musicSegments,
                                               totalDuration: totalDuration,
                                               episodeTitle: episodeTitle,
                                               feedTitle: feedTitle)
        prompt += "\n\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"chapters\" als Array. Jeder Eintrag enthaelt \"startSeconds\" als Ganzzahl ab Podcast-Anfang, \"title\" als nicht leeren String, \"isSponsor\" als Boolean und \"evidenceText\" als kurzes Textfragment mit 6 bis 25 Woertern aus dem Block direkt nach startSeconds. Der Titel muss den Inhalt direkt ab startSeconds beschreiben, nicht ein spaeteres Thema. Wenn keine passende Belegstelle direkt nach startSeconds existiert, verschiebe startSeconds auf den belegten Themenbeginn oder aendere den Titel. Erzeuge kein \"endSeconds\"-Feld; Kapitelenden werden aus dem naechsten startSeconds berechnet. Verwende keine Beispielwerte.\n"
        prompt += "Pruefe vor der Ausgabe fuer jedes Kapitel: Passt evidenceText zum Titel und liegt diese Belegstelle direkt nach startSeconds? Wenn nicht, korrigiere Startzeit oder Titel. Ein Sponsor-Kapitel darf nie vor der ersten Sponsor-Belegstelle beginnen; wenn vorher redaktioneller Inhalt laeuft, braucht dieser einen eigenen nicht-Sponsor-Kapitelstart.\n"
        return prompt
    }

    private func buildRemoteEvidenceRetryPrompt(originalPrompt: String,
                                                evidenceIssue: String) -> String {
        var prompt = originalPrompt
        prompt += "\n\nDie vorige Kapitel-Liste wurde verworfen: \(evidenceIssue)\n"
        prompt += "Erstelle die komplette Kapitel-Liste neu. evidenceText muss im Transkript direkt beim angegebenen startSeconds vorkommen, nicht spaeter im selben Kapitel. Wenn die Belegstelle zu einem spaeteren Thema gehoert, beginne dort ein neues Kapitel und lasse den vorherigen Abschnitt mit einem eigenen passenden Titel stehen. Sponsor-Kapitel beginnen exakt dort, wo die Sponsor-, Eigenpromo- oder Call-to-Action-Belegstelle beginnt.\n"
        prompt += "Wenn zwei verschiedene Promotion-Segmente nacheinander vorkommen, darf das fruehere Sponsor-Kapitel nie Titel, Marke oder evidenceText aus dem spaeteren Sponsor-Segment uebernehmen. Benenne jedes Promo-Segment nur nach dem Angebot, das direkt an seinem eigenen startSeconds belegt ist; verschiebe spaetere Sponsoren auf deren eigene Startzeit.\n"
        return prompt
    }

    private static func localContextTokens(forPromptCharacters _: Int) -> Int32 {
        return LocalGGUFModelRunner.recommendedContextTokens()
    }

    private static func transcriptCueTitle(from text: String) -> String {
        let cleaned = transcriptCueTextForTitle(text)
        guard !cleaned.isEmpty else { return "" }

        if let concise = conciseContentTitle(from: cleaned, preserveTeaserPrefix: false),
           isUsableConciseContentTitle(concise) {
            return String(concise.prefix(140))
        }
        let words = cleaned.split(separator: " ")
        let snippet = words.prefix(16).joined(separator: " ")
        return String(snippet.prefix(140))
    }

    private func transcriptPromptBlockLines(cues: [ICTranscriptCue],
                                            totalDuration: Double) -> [String] {
        let sortedCues = cues.sorted { $0.start < $1.start }
        guard !sortedCues.isEmpty else { return [] }

        let blockDuration = Self.transcriptPromptBlockDuration
        var lines: [String] = []
        var blockStart = 0.0
        var cueIndex = 0

        while blockStart < totalDuration {
            let blockEnd = min(blockStart + blockDuration, totalDuration)
            while cueIndex < sortedCues.count && sortedCues[cueIndex].end <= blockStart {
                cueIndex += 1
            }

            var blockTexts: [String] = []
            var scanIndex = cueIndex
            while scanIndex < sortedCues.count && sortedCues[scanIndex].start < blockEnd {
                let cue = sortedCues[scanIndex]
                if cue.end > blockStart {
                    let text = Self.transcriptCueTextForPrompt(cue.text)
                    if !text.isEmpty {
                        blockTexts.append(text)
                    }
                }
                scanIndex += 1
            }

            let text = blockTexts.joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                lines.append("[\(formatModelSecondRange(blockStart, blockEnd))] \(text)")
            }

            blockStart += blockDuration
        }
        return lines
    }

    private static func transcriptCueTextForPrompt(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<\|[^>]+\|>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func audioContextMarkers(musicSegments: [ICAudioSegment]?,
                                            transcriptCues: [ICTranscriptCue],
                                            segmentStart: Double,
                                            segmentEnd: Double,
                                            totalDuration: Double) -> [TopicMarker] {
        let boundaryChapters = standaloneIntroOutroMusicChapters(from: musicSegments,
                                                                 transcriptCues: transcriptCues,
                                                                 transcriptDuration: totalDuration)
        let music = (musicSegments ?? [])
            .filter {
                $0.type == "music"
                    && $0.end > $0.start
                    && $0.end - $0.start >= minimumAudioContextDuration
                    && $0.start >= segmentStart - 20.0
                    && $0.start <= segmentEnd + 20.0
            }
            .sorted { $0.start < $1.start }

        return music.compactMap { segment -> TopicMarker? in
            let start = max(segment.start, 0)
            let end = min(segment.end, totalDuration)
            guard end - start >= minimumAudioContextDuration else { return nil }
            let overlapsBoundary = boundaryChapters.contains {
                overlapDuration(start, end, $0.start, $0.end) >= minimumAudioContextDuration
            }
            guard !overlapsBoundary else { return nil }

            let before = previousSpeechSnippet(before: start, transcriptCues: transcriptCues) ?? "-"
            let after = nextSpeechSnippet(after: end, transcriptCues: transcriptCues) ?? "-"
            let title = "Audiohinweis: Musik/Sound \(Int(start))-\(Int(end)); davor: \(before); danach: \(after)"
            return (time: start, title: String(title.prefix(180)))
        }
    }

    private static func previousSpeechSnippet(before time: Double,
                                              transcriptCues: [ICTranscriptCue]) -> String? {
        meaningfulSpeechCues(from: transcriptCues)
            .last { $0.end <= time + 1.0 }
            .flatMap { audioContextSnippet(from: $0.text) }
    }

    private static func nextSpeechSnippet(after time: Double,
                                          transcriptCues: [ICTranscriptCue]) -> String? {
        meaningfulSpeechCues(from: transcriptCues)
            .first { $0.start >= time - 1.0 }
            .flatMap { audioContextSnippet(from: $0.text) }
    }

    private static func audioContextSnippet(from text: String) -> String? {
        if let concise = conciseContentTitle(from: text, preserveTeaserPrefix: false),
           isUsableConciseContentTitle(concise) {
            return concise
        }
        let cleaned = transcriptCueTextForTitle(text)
        guard !cleaned.isEmpty else { return nil }
        let words = cleaned.split(separator: " ").prefix(7).joined(separator: " ")
        return words.isEmpty ? nil : words
    }

    private static func transcriptCueTextForTitle(_ text: String) -> String {
        let leadingMusicCuePrefixPattern = #"(?i)^(musik|music|musica|música|musique)\b[\s,;:.-]*"#
        return text.replacingOccurrences(
            of: #"<\|[^>]+\|>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Spektrum produced mixed cues like "Musik Ja, ..."; keep the speech and remove only the leading marker word.
        .replacingOccurrences(of: leadingMusicCuePrefixPattern, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildLocalFinalChaptersPrompt(markers: [TopicMarker],
                                               totalDuration: Double,
                                               existingChapters: [ICGeneratedChapter]?,
                                               transcriptCues: [ICTranscriptCue]?) -> String {
        var prompt = buildFinalChaptersPrompt(markers: markers,
                                              totalDuration: totalDuration,
                                              existingChapters: existingChapters,
                                              transcriptCues: transcriptCues)
        prompt += "\n\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"chapters\" als Array. Jeder Eintrag enthaelt \"startSeconds\" und \"endSeconds\" als Ganzzahlen ab Podcast-Anfang, \"title\" als nicht leeren String und \"isSponsor\" als Boolean. Verwende keine Beispielwerte.\n"
        return prompt
    }

    private func buildLocalSponsorClassificationPrompt(chapters: [ICGeneratedChapter],
                                                       cues: [ICTranscriptCue],
                                                       totalDuration: Double,
                                                       episodeTitle: String?,
                                                       feedTitle: String?) -> String {
        var prompt = "Klassifiziere die bestehenden Podcast-Kapitel semantisch als skip-wuerdige Promotion oder redaktionellen Inhalt.\n"
        prompt += "Gesamtdauer: \(Int(totalDuration)) Sekunden.\n\n"
        prompt += "Regeln:\n"
        prompt += "- Aendere keine Kapitelgrenzen und lasse die Anzahl der Kapitel exakt gleich.\n"
        prompt += "- Nutze startSeconds und endSeconds exakt wie in der bestehenden Kapitel-Liste.\n"
        prompt += "- Nutze das Transkript als Kontext; erfinde keine Inhalte.\n"
        prompt += Self.sponsorRecognitionRule
        prompt += Self.promotionAuditRule
        prompt += "- Fuer Promotion: isSponsor true und Titel mit 'Sponsor: ...'.\n"
        prompt += "- Fuer redaktionellen Inhalt: isSponsor false und keinen Sponsor-Prefix.\n"
        prompt += "- Audio-Kapitel wie Intro, Jingle oder Sound-Sample bleiben isSponsor false, ausser der umgebende Transkript-Kontext macht sie selbst zur Promotion.\n\n"

        let cleanEpisodeTitle = episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFeedTitle = feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEpisodeTitle?.isEmpty == false || cleanFeedTitle?.isEmpty == false {
            prompt += "Podcast-Kontext:\n"
            if let cleanFeedTitle, !cleanFeedTitle.isEmpty {
                prompt += "Podcast: \(cleanFeedTitle)\n"
            }
            if let cleanEpisodeTitle, !cleanEpisodeTitle.isEmpty {
                prompt += "Episode: \(cleanEpisodeTitle)\n"
            }
            prompt += "Nutze diesen Kontext nur, wenn der Transkriptabschnitt ihn stuetzt.\n\n"
        }

        prompt += "Bestehende Kapitel:\n"
        for chapter in chapters {
            prompt += "[\(formatModelSecondRange(chapter.start, chapter.end))] \(chapter.title), isSponsor: \(chapter.isSponsor)\n"
        }

        prompt += "\nTranskript-Bloecke (0s-\(formatModelSecond(totalDuration))):\n"
        for line in transcriptPromptBlockLines(cues: cues, totalDuration: totalDuration) {
            prompt += "\(line)\n"
        }

        prompt += "\n\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"chapters\" als Array. Jeder Eintrag enthaelt \"startSeconds\" und \"endSeconds\" unveraendert aus der bestehenden Kapitel-Liste, \"title\" als nicht leeren String und \"isSponsor\" als Boolean. Verwende keine Beispielwerte.\n"
        return prompt
    }

    private func remoteChaptersByClassifyingSponsors(_ chapters: [ICGeneratedChapter],
                                                     model: ICDownloadableModel,
                                                     cues: [ICTranscriptCue],
                                                     totalDuration: Double,
                                                     status: ((String) -> Void)?,
                                                     progress: ((Float, Int, Int) -> Void)?,
                                                     episodeTitle: String?,
                                                     feedTitle: String?,
                                                     debugTrace: ChapterDebugTrace?) async throws -> [ICGeneratedChapter] {
        guard !chapters.isEmpty else { return chapters }

        let prompt = buildLocalSponsorClassificationPrompt(chapters: chapters,
                                                           cues: cues,
                                                           totalDuration: totalDuration,
                                                           episodeTitle: episodeTitle,
                                                           feedTitle: feedTitle)
        let start = Date()
        status?(NSLocalizedString("Sponsor- und Eigenpromo-Segmente werden semantisch geprueft.", comment: ""))
        progress?(0, 0, 1)
        debugTrace?.recordPerformance("remote-sponsor-classification-started",
                                      metadata: [
                                        "modelIdentifier": model.identifier,
                                        "chapterCount": chapters.count,
                                        "promptCharacters": prompt.count,
                                      ])

        let output = try await generateRemoteJSONObject(model: model,
                                                        prompt: prompt,
                                                        responseShape: .chapters)
        let response = try decodeLocalJSON(LocalChaptersResponse.self, from: output)
        let classified = response.chapters.map {
            ICGeneratedChapter(start: Double($0.startSeconds),
                               end: Double($0.endSeconds),
                               title: $0.title,
                               isSponsor: $0.isSponsor)
        }
        let result = try Self.chaptersByApplyingSponsorClassification(classified,
                                                                      to: chapters,
                                                                      debugTrace: debugTrace,
                                                                      start: start,
                                                                      eventPrefix: "remote-sponsor-classification",
                                                                      changedCountCode: 43,
                                                                      changedBoundaryCode: 44)
        debugTrace?.recordPerformance("remote-sponsor-classification-completed",
                                      metadata: [
                                        "chapterCount": result.count,
                                        "sponsorChapterCount": result.filter { $0.isSponsor }.count,
                                        "outputCharacters": output.count,
                                        "durationSeconds": String(format: "%.3f", -start.timeIntervalSinceNow),
                                      ])
        return result
    }

    private func localChaptersByClassifyingSponsors(_ chapters: [ICGeneratedChapter],
                                                    cues: [ICTranscriptCue],
                                                    totalDuration: Double,
                                                    runner: LocalGGUFModelRunner,
                                                    maxInputTokens: Int,
                                                    status: ((String) -> Void)?,
                                                    progress: ((Float, Int, Int) -> Void)?,
                                                    episodeTitle: String?,
                                                    feedTitle: String?,
                                                    debugTrace: ChapterDebugTrace?) async throws -> [ICGeneratedChapter] {
        guard !chapters.isEmpty else { return chapters }

        let prompt = buildLocalSponsorClassificationPrompt(chapters: chapters,
                                                           cues: cues,
                                                           totalDuration: totalDuration,
                                                           episodeTitle: episodeTitle,
                                                           feedTitle: feedTitle)
        guard try await localPromptFitsContext(prompt, runner: runner, maxInputTokens: maxInputTokens) else {
            throw NSError(domain: "ChapterGenerator", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: "Sponsor-Klassifizierung fehlgeschlagen - das Transkript passt nicht in das Kontextfenster des Kapitelmodells."])
        }

        let start = Date()
        status?(NSLocalizedString("Sponsor- und Eigenpromo-Segmente werden semantisch geprueft.", comment: ""))
        progress?(0.97, 1, 2)
        debugTrace?.recordPerformance("local-sponsor-classification-started",
                                      metadata: [
                                        "chapterCount": chapters.count,
                                        "promptCharacters": prompt.count,
                                      ])
        let output = try await generateLocalJSONObject(runner: runner,
                                                       prompt: prompt,
                                                       grammar: .chapters,
                                                       maxNewTokens: localSponsorClassificationMaxNewTokens(chapterCount: chapters.count))
        debugTrace?.recordLocalSponsorOutput(output)
        let response = try decodeLocalJSON(LocalChaptersResponse.self, from: output)
        let classified = response.chapters.map {
            ICGeneratedChapter(start: Double($0.startSeconds),
                               end: Double($0.endSeconds),
                               title: $0.title,
                               isSponsor: $0.isSponsor)
        }
        let result = try Self.chaptersByApplyingSponsorClassification(classified,
                                                                      to: chapters,
                                                                      debugTrace: debugTrace,
                                                                      start: start,
                                                                      eventPrefix: "local-sponsor-classification",
                                                                      changedCountCode: 23,
                                                                      changedBoundaryCode: 24)

        debugTrace?.recordPerformance("local-sponsor-classification-completed",
                                      metadata: [
                                        "chapterCount": result.count,
                                        "sponsorChapterCount": result.filter { $0.isSponsor }.count,
                                        "outputCharacters": output.count,
                                        "durationSeconds": String(format: "%.3f", -start.timeIntervalSinceNow),
                                      ])
        return result
    }

    private static func chaptersByApplyingSponsorClassification(_ classified: [ICGeneratedChapter],
                                                               to chapters: [ICGeneratedChapter],
                                                               debugTrace: ChapterDebugTrace?,
                                                               start: Date,
                                                               eventPrefix: String,
                                                               changedCountCode: Int,
                                                               changedBoundaryCode: Int) throws -> [ICGeneratedChapter] {
        guard classified.count == chapters.count else {
            debugTrace?.recordPerformance("\(eventPrefix)-failed",
                                          metadata: [
                                            "reason": "chapter-count-changed",
                                            "expectedChapterCount": chapters.count,
                                            "actualChapterCount": classified.count,
                                            "durationSeconds": String(format: "%.3f", -start.timeIntervalSinceNow),
                                          ])
            throw NSError(domain: "ChapterGenerator", code: changedCountCode,
                          userInfo: [NSLocalizedDescriptionKey: "Sponsor-Klassifizierung fehlgeschlagen - das Kapitelmodell hat die Kapitelanzahl veraendert."])
        }

        var result: [ICGeneratedChapter] = []
        for (original, candidate) in zip(chapters, classified) {
            guard abs(original.start - candidate.start) <= 1.0,
                  abs(original.end - candidate.end) <= 1.0 else {
                debugTrace?.recordPerformance("\(eventPrefix)-failed",
                                              metadata: [
                                                "reason": "chapter-boundaries-changed",
                                                "expectedStart": String(format: "%.3f", original.start),
                                                "expectedEnd": String(format: "%.3f", original.end),
                                                "actualStart": String(format: "%.3f", candidate.start),
                                                "actualEnd": String(format: "%.3f", candidate.end),
                                                "durationSeconds": String(format: "%.3f", -start.timeIntervalSinceNow),
                                              ])
                throw NSError(domain: "ChapterGenerator", code: changedBoundaryCode,
                              userInfo: [NSLocalizedDescriptionKey: "Sponsor-Klassifizierung fehlgeschlagen - das Kapitelmodell hat Kapitelgrenzen veraendert."])
            }

            let candidateTitle = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSponsor = candidate.isSponsor || candidateTitle.hasPrefix("Sponsor: ")
            let title: String
            if isSponsor {
                if candidateTitle.hasPrefix("Sponsor: ") {
                    title = candidateTitle
                } else if original.title.hasPrefix("Sponsor: ") {
                    title = original.title
                } else {
                    title = "Sponsor: \(original.title)"
                }
            } else if original.title.hasPrefix("Sponsor: ") {
                title = String(original.title.dropFirst("Sponsor: ".count))
            } else {
                title = original.title
            }
            result.append(ICGeneratedChapter(start: original.start,
                                             end: original.end,
                                             title: title,
                                             isSponsor: isSponsor))
        }
        return result
    }

    private func buildLocalMarkerConsolidationPrompt(markers: [TopicMarker],
                                                     totalDuration: Double,
                                                     round: Int) -> String {
        var prompt = buildMarkerConsolidationPrompt(markers: markers,
                                                    totalDuration: totalDuration,
                                                    round: round)
        prompt += "\n\nAntworte ausschliesslich mit einem JSON-Objekt. Es enthaelt genau ein Feld \"markers\" als Array. Jeder Eintrag enthaelt \"timeSeconds\" als Ganzzahl ab Podcast-Anfang und \"title\" als nicht leeren String. Verwende keine Beispielwerte."
        return prompt
    }

    private func localChapterMaxNewTokens(markerCount: Int,
                                          existingChapters: [ICGeneratedChapter]?) -> Int {
        guard existingChapters == nil else { return 1_024 }
        return min(4_096, max(2_048, markerCount * 180))
    }

    private func localDirectChapterMaxNewTokens(duration: Double) -> Int {
        4_096
    }

    private func localSponsorClassificationMaxNewTokens(chapterCount: Int) -> Int {
        min(2_048, max(512, chapterCount * 120))
    }

    private func localMarkerMaxNewTokens(cueCount _: Int, duration: Double) -> Int {
        2_048
    }

    private static func isTerminalOnlyMarker(time: Double, segmentStart: Double, segmentEnd: Double) -> Bool {
        return time >= segmentEnd - 1.0 && time > segmentStart + 10.0
    }

    private static func normalizedTopicMarkers(_ markers: [TopicMarker],
                                               segmentStart: Double,
                                               segmentEnd: Double) -> [TopicMarker] {
        let cleaned = markers
            .map { (time: min(max($0.time, segmentStart), segmentEnd),
                    title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.title.isEmpty }
            .sorted { $0.time < $1.time }
        guard !cleaned.isEmpty else { return [] }

        let nonTerminal = cleaned.filter {
            !isTerminalOnlyMarker(time: $0.time, segmentStart: segmentStart, segmentEnd: segmentEnd)
        }
        if !nonTerminal.isEmpty {
            return nonTerminal
        }

        guard let first = cleaned.first,
              isContentTopicMarkerTitle(first.title) else {
            return []
        }
        return [(time: segmentStart, title: first.title)]
    }

    private static func isContentTopicMarkerTitle(_ title: String) -> Bool {
        !isGenericChapterTitle(title)
            && !isStructuralChapterTitle(title)
            && normalizedAudioInterludeTitle(title) == nil
    }

    private func localMarkersFittingFinalPrompt(markers: [TopicMarker],
                                                totalDuration: Double,
                                                existingChapters: [ICGeneratedChapter]?,
                                                transcriptCues: [ICTranscriptCue]?,
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
                                                            existingChapters: existingChapters,
                                                            transcriptCues: transcriptCues)
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

    private func transcriptContextWindowsForLocalModel(_ cues: [ICTranscriptCue],
                                                       musicSegments: [ICAudioSegment]?,
                                                       totalDuration: Double,
                                                       runner: LocalGGUFModelRunner,
                                                       maxInputTokens: Int,
                                                       episodeTitle: String?,
                                                       feedTitle: String?) async throws -> [TranscriptContextWindow] {
        guard !cues.isEmpty else { return [] }
        guard !Task.isCancelled else {
            await runner.cancel()
            throw CancellationError()
        }

        let segStart = cues.first?.start ?? 0
        let segEnd = cues.last?.end ?? totalDuration
        let prompt = buildLocalTopicExtractionPrompt(cues: cues,
                                                     allCues: cues,
                                                     musicSegments: musicSegments,
                                                     segStart: segStart,
                                                     segEnd: segEnd,
                                                     totalDuration: totalDuration,
                                                     episodeTitle: episodeTitle,
                                                     feedTitle: feedTitle)
        if try await localPromptFitsContext(prompt, runner: runner, maxInputTokens: maxInputTokens) {
            NSLog("[ChapterGenerator] Local full-context transcript: %d cues -> 1 context window", cues.count)
            return [TranscriptContextWindow(cues: cues)]
        }

        var windows: [TranscriptContextWindow] = []
        var startIndex = 0
        while startIndex < cues.count {
            guard !Task.isCancelled else {
                await runner.cancel()
                throw CancellationError()
            }

            var low = startIndex + 1
            var high = cues.count
            var bestEndIndex: Int?
            while low <= high {
                let mid = (low + high) / 2
                let candidate = Array(cues[startIndex..<mid])
                let candidatePrompt = buildLocalTopicExtractionPrompt(cues: candidate,
                                                                      allCues: cues,
                                                                      musicSegments: musicSegments,
                                                                      segStart: candidate.first?.start ?? 0,
                                                                      segEnd: candidate.last?.end ?? totalDuration,
                                                                      totalDuration: totalDuration,
                                                                      episodeTitle: episodeTitle,
                                                                      feedTitle: feedTitle)
                if try await localPromptFitsContext(candidatePrompt, runner: runner, maxInputTokens: maxInputTokens) {
                    bestEndIndex = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            guard let endIndex = bestEndIndex, endIndex > startIndex else {
                throw NSError(domain: "ChapterGenerator", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — ein einzelner Transkriptbereich passt nicht in das Kontextfenster dieses Kapitelmodells."])
            }

            let windowCues = Array(cues[startIndex..<endIndex])
            windows.append(TranscriptContextWindow(cues: windowCues))
            guard endIndex < cues.count else { break }

            startIndex = Self.nextContextWindowStartIndex(cues: cues,
                                                          currentStartIndex: startIndex,
                                                          currentEndIndex: endIndex)
        }

        NSLog("[ChapterGenerator] Local overlapping context windows: %d cues -> %d window(s)", cues.count, windows.count)
        return windows
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

    private func buildDirectChaptersPrompt(cues: [ICTranscriptCue],
                                           allCues: [ICTranscriptCue],
                                           musicSegments: [ICAudioSegment]?,
                                           totalDuration: Double,
                                           episodeTitle: String?,
                                           feedTitle: String?) -> String {
        var prompt = "Erstelle die finale Kapitel-Liste aus dem vollstaendigen Podcast-Transkript.\n"
        prompt += "Gesamtdauer: \(Int(totalDuration)) Sekunden.\n\n"
        prompt += "Regeln:\n"
        prompt += "- Nutze das gesamte Transkript als Kontext; erfinde keine Inhalte.\n"
        prompt += "- Das Transkript ist in 30-Sekunden-Bloecke gruppiert. Ein Kapitelstart muss zu dem Block passen, dessen Inhalt direkt danach beschrieben wird.\n"
        prompt += "- Ein Kapitel darf sehr lang sein, auch 40 Minuten oder laenger, wenn der Inhalt wirklich ein zusammenhaengender Themenblock ist.\n"
        prompt += "- Unterteile nicht nach Dauer, sondern nur bei echten, fuer Hoerer nuetzlichen Themen-, Segment- oder Skip-Wechseln.\n"
        prompt += "- Erzeuge keine eigenen Kapitelstarts fuer kurze Begruessungen, Meta-Einleitungen, Ueberleitungen, Fuellsaetze oder einzelne Service-Details, wenn sie zum selben Nutzenthema gehoeren.\n"
        prompt += "- Ein einzelnes Kapitel ueber fast die ganze Folge ist nur erlaubt, wenn das Transkript wirklich keinen eigenen Nutzensprung, keine neue Hauptfrage, kein Fazit und kein skip-wuerdiges Segment enthaelt.\n"
        prompt += "- Wenn ein Gespraech mehrere Hauptfragen, Argumente, Methoden, Studien, konkrete Beispiele, Empfehlungen oder ein Schlusssegment behandelt, muessen die Kapitelstarts diese Wechsel sichtbar machen.\n"
        prompt += "- Ein Oberthema reicht nicht als Kapitel, wenn darunter mehrere klar benannte eigenstaendige Gegenstaende, Projekte, Produkte, Dienste, Picks, Fragen oder Entscheidungen nacheinander behandelt werden. Beginne dann beim Wechsel ein eigenes Kapitel, damit Hoerer den Abschnitt gezielt auswaehlen oder ueberspringen koennen.\n"
        prompt += "- Vermeide Sammelkapitel, deren Titel mehrere unabhaengige Gegenstaende, Projekte oder Handlungen zusammenbindet. Wenn der Titel sonst mit mehreren verbundenen Themen formuliert werden muesste, setze die belegten Themenwechsel als eigene Kapitelstarts.\n"
        prompt += Self.sponsorRecognitionRule
        prompt += Self.promotionSegmentationRule
        prompt += Self.promotionAuditRule
        prompt += "- Audiohinweise sind neutrale SoundAnalysis-Zeitbereiche. Erzeuge daraus nur dann ein Kapitel mit Titel exakt 'Jingle' oder 'Sound-Sample', wenn der umgebende Transkript-Kontext das belegt. Erzeuge daraus nie geratenes Intro oder Outro.\n"
        prompt += "- Titel in der Sprache des Transkripts.\n"
        prompt += "- Titel muessen fuer Hoerer bei der Kapitelauswahl nuetzlich sein: konkrete Sache, Person, Ort, Frage, Messwert, Methode oder zentrale These nennen.\n"
        prompt += "- Keine reinen Kategorie-, Schlagwort- oder Oberbegriff-Titel; der Titel muss erkennen lassen, welche konkrete Frage, Behauptung, Ursache, Folge oder Entscheidung im Abschnitt behandelt wird.\n"
        prompt += "- Beschreibe nicht den Sprechakt wie Begruessung, Einleitung, Ankuendigung, Ueberblick oder Diskussion, wenn der Abschnitt konkrete Inhalte nennt; benenne dann die angekuendigte Sache selbst.\n"
        prompt += "- Keine vagen Meta-Titel und keine einzelnen Satzfragmente.\n"
        prompt += "- startSeconds als Sekunden ab Podcast-Anfang (Ganzzahl).\n"
        prompt += "- Das erste Kapitel beginnt bei 0; das letzte Kapitel endet automatisch bei der Gesamtdauer \(Int(totalDuration)).\n"
        prompt += "- Gib nur Kapitelstarts aus; Endzeiten werden deterministisch aus dem naechsten startSeconds berechnet.\n\n"

        let cleanEpisodeTitle = episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFeedTitle = feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEpisodeTitle?.isEmpty == false || cleanFeedTitle?.isEmpty == false {
            prompt += "Podcast-Kontext:\n"
            if let cleanFeedTitle, !cleanFeedTitle.isEmpty {
                prompt += "Podcast: \(cleanFeedTitle)\n"
            }
            if let cleanEpisodeTitle, !cleanEpisodeTitle.isEmpty {
                prompt += "Episode: \(cleanEpisodeTitle)\n"
            }
            prompt += "Nutze diesen Kontext nur, wenn der Transkriptabschnitt ihn stuetzt.\n\n"
        }

        prompt += "Transkript-Bloecke (0s-\(formatModelSecond(totalDuration))):\n"
        for line in transcriptPromptBlockLines(cues: cues, totalDuration: totalDuration) {
            prompt += "\(line)\n"
        }

        let audioMarkers = Self.audioContextMarkers(musicSegments: musicSegments,
                                                    transcriptCues: allCues,
                                                    segmentStart: 0,
                                                    segmentEnd: totalDuration,
                                                    totalDuration: totalDuration)
        if !audioMarkers.isEmpty {
            prompt += "\nAudiohinweise:\n"
            for marker in audioMarkers {
                prompt += "[\(formatModelSecond(marker.time))] \(marker.title)\n"
            }
        }
        return prompt
    }

    /// Pass 1 prompt: Identify topic changes in a transcript segment.
    /// Output is produced via @Generable GeneratedTopicMarkersList — no format instructions in prompt.
    private func buildTopicExtractionPrompt(cues: [ICTranscriptCue],
                                            allCues: [ICTranscriptCue],
                                            musicSegments: [ICAudioSegment]?,
                                            segStart: Double,
                                            segEnd: Double,
                                            totalDuration: Double,
                                            episodeTitle: String?,
                                            feedTitle: String?) -> String {
        var prompt = "Identifiziere Themenwechsel in diesem Podcast-Abschnitt.\n"
        prompt += "Erzeuge Marker mit Zeitpunkt (in Sekunden) und kurzem Titel nur dort, wo der Transkriptinhalt einen echten Themen-, Segment- oder Skip-Wechsel belegt.\n"
        prompt += "Marker sind Startpunkte von Themenbloecken, keine Zusammenfassung am Abschnittsende.\n"
        prompt += "Der erste Marker muss am Abschnittsanfang \(Int(segStart.rounded())) liegen, wenn dort ein neues oder fortlaufendes Thema beschrieben wird.\n"
        prompt += "Setze timeSeconds nie ans Abschnittsende, nur weil der Text dort endet.\n"
        prompt += "Ein zusammenhaengendes Thema darf sehr lang sein, auch 40 Minuten oder laenger. Erzwinge keine Unterteilung nach Dauer.\n"
        prompt += "Vermeide Sammelmarker, deren Titel mehrere unabhaengige Gegenstaende, Projekte oder Handlungen zusammenbindet. Wenn der Titel sonst mit mehreren verbundenen Themen formuliert werden muesste, setze die belegten Themenwechsel als eigene Marker.\n"
        prompt += Self.sponsorRecognitionRule
        prompt += Self.promotionSegmentationRule
        prompt += Self.promotionAuditRule
        prompt += "Audiohinweise sind neutrale SoundAnalysis-Zeitbereiche. Erzeuge daraus nur dann einen Marker mit Titel exakt 'Jingle' oder 'Sound-Sample', wenn der umgebende Transkript-Kontext das belegt. Erzeuge daraus nie Intro oder Outro.\n"
        prompt += "Titel in der Sprache des Transkripts.\n"
        prompt += "Titel muessen fuer Hoerer bei der Kapitelauswahl nuetzlich sein: konkrete Sache, Person, Ort, Frage oder These nennen.\n"
        prompt += "Keine reinen Kategorie-, Schlagwort- oder Oberbegriff-Titel; der Titel muss erkennen lassen, welche konkrete Frage, Behauptung, Ursache, Folge oder Entscheidung im Abschnitt behandelt wird.\n"
        prompt += "Beschreibe nicht den Sprechakt wie Begruessung, Einleitung, Ankuendigung, Ueberblick oder Diskussion, wenn der Abschnitt konkrete Inhalte nennt; benenne dann die angekuendigte Sache selbst mit Namen, Datum, Ort, Angebot oder zentraler These.\n"
        prompt += "Keine vagen Meta-Titel und keine einzelnen Satzfragmente.\n\n"
        let cleanEpisodeTitle = episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFeedTitle = feedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanEpisodeTitle?.isEmpty == false || cleanFeedTitle?.isEmpty == false {
            prompt += "Podcast-Kontext:\n"
            if let cleanFeedTitle, !cleanFeedTitle.isEmpty {
                prompt += "Podcast: \(cleanFeedTitle)\n"
            }
            if let cleanEpisodeTitle, !cleanEpisodeTitle.isEmpty {
                prompt += "Episode: \(cleanEpisodeTitle)\n"
            }
            prompt += "Nutze diesen Kontext, um kurze oder mehrdeutige Transkriptstellen zu deuten; Kapiteltitel muessen trotzdem durch den Transkriptabschnitt gedeckt sein.\n\n"
        }
        prompt += "Transkript (\(formatModelSecond(segStart))-\(formatModelSecond(segEnd))):\n"
        for cue in cues {
            prompt += "[\(formatModelSecond(cue.start))] \(cue.text)\n"
        }
        let audioMarkers = Self.audioContextMarkers(musicSegments: musicSegments,
                                                    transcriptCues: allCues,
                                                    segmentStart: segStart,
                                                    segmentEnd: segEnd,
                                                    totalDuration: totalDuration)
        if !audioMarkers.isEmpty {
            prompt += "\nAudiohinweise:\n"
            for marker in audioMarkers {
                prompt += "[\(formatModelSecond(marker.time))] \(marker.title)\n"
            }
        }
        return prompt
    }

    #if canImport(FoundationModels)
    @available(iOS 26, *)
    private func markersFittingFinalPrompt(markers: [TopicMarker],
                                           totalDuration: Double,
                                           existingChapters: [ICGeneratedChapter]?,
                                           transcriptCues: [ICTranscriptCue]?,
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
                existingChapters: existingChapters,
                transcriptCues: transcriptCues)
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
    private func transcriptContextWindowsForModel(_ cues: [ICTranscriptCue],
                                                  musicSegments: [ICAudioSegment]?,
                                                  totalDuration: Double,
                                                  model: SystemLanguageModel,
                                                  maxInputTokens: Int,
                                                  episodeTitle: String?,
                                                  feedTitle: String?) async throws -> [TranscriptContextWindow] {
        guard !cues.isEmpty else { return [] }
        guard !Task.isCancelled else { throw CancellationError() }

        let segStart = cues.first?.start ?? 0
        let segEnd = cues.last?.end ?? totalDuration
        let prompt = buildTopicExtractionPrompt(cues: cues,
                                                allCues: cues,
                                              musicSegments: musicSegments,
                                              segStart: segStart,
                                              segEnd: segEnd,
                                              totalDuration: totalDuration,
                                              episodeTitle: episodeTitle,
                                              feedTitle: feedTitle)
        if await promptFitsContext(prompt, model: model, maxInputTokens: maxInputTokens) {
            NSLog("[ChapterGenerator] Full-context transcript: %d cues -> 1 context window", cues.count)
            return [TranscriptContextWindow(cues: cues)]
        }

        var windows: [TranscriptContextWindow] = []
        var startIndex = 0
        while startIndex < cues.count {
            guard !Task.isCancelled else { throw CancellationError() }

            var low = startIndex + 1
            var high = cues.count
            var bestEndIndex: Int?
            while low <= high {
                let mid = (low + high) / 2
                let candidate = Array(cues[startIndex..<mid])
                let candidatePrompt = buildTopicExtractionPrompt(cues: candidate,
                                                                 allCues: cues,
                                                                  musicSegments: musicSegments,
                                                                  segStart: candidate.first?.start ?? 0,
                                                                  segEnd: candidate.last?.end ?? totalDuration,
                                                                  totalDuration: totalDuration,
                                                                  episodeTitle: episodeTitle,
                                                                  feedTitle: feedTitle)
                if await promptFitsContext(candidatePrompt, model: model, maxInputTokens: maxInputTokens) {
                    bestEndIndex = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            guard let endIndex = bestEndIndex, endIndex > startIndex else {
                throw NSError(domain: "ChapterGenerator", code: 16,
                              userInfo: [NSLocalizedDescriptionKey: "Kapitelerkennung fehlgeschlagen — ein einzelner Transkriptbereich passt nicht in das Kontextfenster dieses Kapitelmodells."])
            }

            let windowCues = Array(cues[startIndex..<endIndex])
            windows.append(TranscriptContextWindow(cues: windowCues))
            guard endIndex < cues.count else { break }

            startIndex = Self.nextContextWindowStartIndex(cues: cues,
                                                          currentStartIndex: startIndex,
                                                          currentEndIndex: endIndex)
        }

        NSLog("[ChapterGenerator] Overlapping context windows: %d cues -> %d window(s)", cues.count, windows.count)
        return windows
    }
    #endif

    private static func nextContextWindowStartIndex(cues: [ICTranscriptCue],
                                                    currentStartIndex: Int,
                                                    currentEndIndex: Int) -> Int {
        guard currentEndIndex > currentStartIndex + 1 else {
            return min(currentStartIndex + 1, cues.count)
        }

        let windowStart = cues[currentStartIndex].start
        let windowEnd = cues[currentEndIndex - 1].end
        let windowDuration = max(1, windowEnd - windowStart)
        let overlapDuration = min(targetContextWindowOverlapDuration, windowDuration * 0.75)
        let desiredStartTime = max(windowStart + 1, windowEnd - overlapDuration)

        if let timedIndex = cues.indices[currentStartIndex + 1..<currentEndIndex].first(where: { cues[$0].start >= desiredStartTime }) {
            return timedIndex
        }

        let halfWindowIndex = currentStartIndex + max(1, (currentEndIndex - currentStartIndex) / 2)
        return min(max(currentStartIndex + 1, halfWindowIndex), currentEndIndex - 1)
    }

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
        prompt += "Gesamtdauer: \(Int(totalDuration)) Sekunden.\n\n"
        prompt += "Regeln:\n"
        prompt += "- Betrachte jeden Marker; erfinde keine Themen außerhalb dieser Liste.\n"
        prompt += "- Fasse direkt benachbarte Marker zusammen, wenn sie zum selben zusammenhängenden Themenblock gehören.\n"
        prompt += "- Behalte den frühesten Zeitpunkt des zusammengefassten Themenblocks.\n"
        prompt += "- Behalte Sponsoren/Werbung als eigene Marker mit Titel 'Sponsor: MARKENNAME'.\n"
        prompt += "- Gib weniger Marker zurück, wenn Zusammenfassungen inhaltlich möglich sind.\n\n"
        prompt += "Marker:\n"
        for marker in markers {
            prompt += "\(Int(marker.time))s - \(marker.title)\n"
        }
        return prompt
    }

    /// Pass 2 prompt: Consolidate topic markers into final chapter structure.
    /// The LLM sees a context-bounded full-podcast outline and produces chapter boundaries.
    private func buildFinalChaptersPrompt(
        markers: [TopicMarker],
        totalDuration: Double,
        existingChapters: [ICGeneratedChapter]?,
        transcriptCues: [ICTranscriptCue]? = nil
    ) -> String {
        var prompt = ""
        if let chapters = existingChapters, !chapters.isEmpty {
            // Mode B: Sponsor detection — return only sponsor chapters
            prompt += "Finde Werbe- und Sponsoring-Segmente in diesem Podcast.\n"
            prompt += "Gesamtdauer: \(Int(totalDuration)) Sekunden.\n\n"
            prompt += "Gib NUR die erkannten Sponsor-Kapitel zurück (Titel als 'Sponsor: MARKENNAME', isSponsor: true).\n"
            prompt += "Falls keine Werbung erkennbar ist, gib eine leere Liste zurück.\n\n"

            prompt += "Bestehende Kapitel:\n"
            for ch in chapters {
                let marker = ch.isSponsor ? " [Sponsor]" : ""
                prompt += "[\(formatModelSecondRange(ch.start, ch.end))] \(ch.title)\(marker)\n"
            }
            prompt += "\n"
        } else {
            // Mode A: Chapter generation
            prompt += "Erstelle die finale Kapitel-Liste aus diesen erkannten Themen.\n"
            prompt += "Gesamtdauer: \(Int(totalDuration)) Sekunden.\n\n"
            prompt += "Regeln:\n"
            prompt += "- Erzeuge nur Inhaltskapitel aus den erkannten Themenmarkern.\n"
            prompt += "- Verwende Intro und Outro nicht; Randmusik wird separat aus der Audioanalyse eingefuegt.\n"
            prompt += "- Audiohinweis-Marker sind neutrale Zeitbereiche aus der Audioanalyse, keine Kapitelvorgaben.\n"
            prompt += "- Erzeuge ein eigenes Audio-Kapitel nur, wenn ein Audiohinweis-Marker plus umgebender Transkript-Kontext einen echten Trenner oder ein abgespieltes Sample belegt.\n"
            prompt += "- Titel solcher Audio-Kapitel exakt 'Jingle' oder 'Sound-Sample'; isSponsor dafuer false.\n"
            prompt += "- Verwandte/ähnliche aufeinanderfolgende Themen zusammenfassen.\n"
            prompt += "- Ein Kapitel darf sehr lang sein, auch 40 Minuten oder laenger, wenn der Transkriptkontext ein zusammenhaengendes Thema bildet.\n"
            prompt += "- Unterteile nur bei echten, fuer Hoerer nuetzlichen Themen-, Segment- oder Skip-Wechseln.\n"
            prompt += "- Gib kein einzelnes Gesamtkapitel zurueck, wenn mehrere Themenmarker klar unterschiedliche Themen oder skip-wuerdige Segmente belegen.\n"
            let allowedStarts = Self.allowedChapterStartSeconds(from: markers)
            prompt += "- Nutze die Markerzeiten als Kapitelstarts; ueberspringe keine langen Abschnitte zwischen Markern.\n"
            prompt += "- Erlaubte startSeconds: \(allowedStarts.map(String.init).joined(separator: ", ")). Nutze keine anderen Startwerte.\n"
            prompt += "- Erlaubte endSeconds sind jeweils der naechste erlaubte startSeconds-Wert oder die Gesamtdauer \(Int(totalDuration)); endSeconds darf nie groesser als \(Int(totalDuration)) sein.\n"
            prompt += "- Wenn zwei benachbarte erlaubte Startwerte unterschiedliche konkrete Themen benennen, muessen daraus getrennte Kapitel entstehen.\n"
            prompt += "- Titel kurz, konkret und beschreibend, in der Sprache des Podcasts.\n"
            prompt += "- Jeder Titel muss mindestens einen konkreten Namen, Gegenstand, Messwert, Methode oder die zentrale Aussage aus dem jeweiligen Transkriptabschnitt nennen.\n"
            prompt += "- Uebernimm Marker-Titel nur, wenn sie bereits konkret genug sind; sonst formuliere mit dem Transkriptkontext neu.\n"
            prompt += "- Folgennummern, Podcasttitel oder Meta-Einleitungen duerfen nicht der Haupttitel sein; benenne stattdessen das eigentliche Thema des Abschnitts.\n"
            prompt += "- Keine reinen Oberbegriffe; schreibe konkret, welche Sache betroffen ist und warum sie relevant ist.\n"
            prompt += "- Titel muessen bei der Kapitelauswahl erkennen lassen, worum es geht; keine vagen Satzfragmente oder Meta-Titel.\n"
            prompt += "- Nutze den Transkriptkontext unten, um konkrete Kapitel-Titel zu formulieren; kopiere keine vagen Marker-Titel.\n"
            prompt += "- Der Transkriptkontext pro Marker umfasst den Abschnitt bis zum naechsten Marker mit Grenzkontext und ist massgeblich fuer den Titel.\n"
            prompt += "- startSeconds und endSeconds als Sekunden ab Podcast-Anfang (Ganzzahl).\n"
            prompt += "- end eines Kapitels = start des nächsten Kapitels.\n"
            prompt += "- Letztes Kapitel end = Gesamtdauer (\(Int(totalDuration))).\n"
            prompt += Self.sponsorRecognitionRule + "\n"
            prompt += Self.timelineCoverageRule
            prompt += Self.promotionSegmentationRule + "\n"
        }

        prompt += "Erkannte Themen:\n"
        for m in markers {
            prompt += "\(Int(m.time))s - \(m.title)\n"
        }

        if let transcriptCues, !transcriptCues.isEmpty {
            prompt += "\nTranskriptkontext zu den Themen:\n"
            for (index, marker) in markers.enumerated() {
                let nextMarkerTime = index + 1 < markers.count ? markers[index + 1].time : totalDuration
                if let context = Self.transcriptContextSnippet(from: marker.time,
                                                               to: nextMarkerTime,
                                                               transcriptCues: transcriptCues) {
                    prompt += "[\(formatModelSecond(marker.time))] \(marker.title): \(context)\n"
                }
            }
        }

        return prompt
    }

    private static func allowedChapterStartSeconds(from markers: [TopicMarker]) -> [Int] {
        let starts = ([0] + markers.map { Int($0.time.rounded()) })
            .filter { $0 >= 0 }
            .sorted()
        var result: [Int] = []
        for start in starts where result.last != start {
            result.append(start)
        }
        return result
    }

    private static func chaptersFromTopicMarkers(_ markers: [TopicMarker],
                                                 totalDuration: Double) -> [ICGeneratedChapter] {
        let cleaned = deduplicatedMarkers(markers)
            .filter { $0.time < totalDuration - 1.0 }
        guard !cleaned.isEmpty else { return [] }

        var chapters: [ICGeneratedChapter] = []
        for index in cleaned.indices {
            let marker = cleaned[index]
            let nextIndex = cleaned.index(after: index)
            let nextStart = nextIndex < cleaned.endIndex ? cleaned[nextIndex].time : totalDuration
            let start = min(max(marker.time, 0), totalDuration)
            let end = min(max(nextStart, 0), totalDuration)
            let title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard end > start, !title.isEmpty else { continue }
            chapters.append(ICGeneratedChapter(start: start,
                                               end: end,
                                               title: title,
                                               isSponsor: title.hasPrefix("Sponsor: ")))
        }
        return chapters
    }

    private static func transcriptContextSnippet(from startTime: Double,
                                                 to endTime: Double,
                                                 transcriptCues: [ICTranscriptCue]) -> String? {
        let windowStart = max(0, startTime - 20)
        let resolvedEnd = endTime > startTime ? endTime : startTime + 90
        let windowEnd = max(resolvedEnd, startTime + 20)
        let cues = transcriptCues
            .filter { $0.end >= windowStart && $0.start <= windowEnd }
        let text = cues
            .map { transcriptCueTextForTitle($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text
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

    private static func chaptersFromGeneratedStarts(_ starts: [LocalChapterStart],
                                                    totalDuration: Double) -> [ICGeneratedChapter] {
        starts.enumerated().map { index, chapter in
            let end = index + 1 < starts.count ? Double(starts[index + 1].startSeconds) : totalDuration
            return ICGeneratedChapter(start: Double(chapter.startSeconds),
                                      end: end,
                                      title: chapter.title,
                                      isSponsor: chapter.isSponsor)
        }
    }

    private static func validateRawGeneratedChapterTiming(_ rawChapters: [ICGeneratedChapter],
                                                          totalDuration: Double,
                                                          existingChapters: [ICGeneratedChapter]?,
                                                          debugTrace: ChapterDebugTrace?) throws {
        guard let issue = rawGeneratedChapterTimingIssue(rawChapters,
                                                         totalDuration: totalDuration,
                                                         existingChapters: existingChapters) else {
            return
        }
        debugTrace?.recordPerformance("chapter-raw-validation-failed",
                                      metadata: [
                                        "issue": issue,
                                        "rawChapterCount": rawChapters.count,
                                        "totalDurationSeconds": String(format: "%.3f", totalDuration),
                                      ])
        NSLog("[ChapterGenerator] Raw chapter timing validation failed: %@", issue)
        throw NSError(domain: "ChapterGenerator", code: 23,
                      userInfo: [NSLocalizedDescriptionKey: issue])
    }

    private static func validateRemoteChapterStartEvidence(_ starts: [LocalChapterStart],
                                                           transcriptCues: [ICTranscriptCue],
                                                           debugTrace: ChapterDebugTrace?) throws {
        guard let issue = rawChapterStartEvidenceIssue(starts, transcriptCues: transcriptCues) else {
            return
        }
        debugTrace?.recordPerformance("remote-chapter-evidence-validation-failed",
                                      metadata: [
                                        "issue": issue,
                                        "chapterCount": starts.count,
                                      ])
        NSLog("[ChapterGenerator] Remote chapter evidence validation failed: %@", issue)
        throw NSError(domain: "ChapterGenerator", code: 45,
                      userInfo: [NSLocalizedDescriptionKey: issue])
    }

    private static func rawChapterStartEvidenceIssue(_ starts: [LocalChapterStart],
                                                     transcriptCues: [ICTranscriptCue]) -> String? {
        guard transcriptCues.count >= 20 else { return nil }

        for chapter in starts {
            let evidence = chapter.evidenceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !evidence.isEmpty else {
                return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat keine Belegstelle fuer startSeconds \(chapter.startSeconds) geliefert."
            }

            let start = Double(chapter.startSeconds)
            let context = transcriptContextSnippet(from: max(0, start - 90),
                                                   to: start + 90,
                                                   transcriptCues: transcriptCues) ?? ""
            guard evidenceText(evidence, matchesTranscriptContext: context) else {
                return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat eine Belegstelle nicht am Kapitelstart \(chapter.startSeconds)s geliefert."
            }
        }

        return nil
    }

    private static func evidenceText(_ evidence: String,
                                     matchesTranscriptContext context: String) -> Bool {
        let evidenceTokens = Self.evidenceTokens(from: evidence)
        guard evidenceTokens.count >= 4 else { return false }
        let contextTokens = Set(Self.evidenceTokens(from: context))
        guard !contextTokens.isEmpty else { return false }

        let checkedTokens = Array(evidenceTokens.prefix(18))
        let requiredMatches = max(4, Int(ceil(Double(checkedTokens.count) * 0.65)))
        let matchCount = checkedTokens.reduce(0) { count, token in
            contextTokens.contains(token) ? count + 1 : count
        }
        return matchCount >= requiredMatches
    }

    private static func evidenceTokens(from text: String) -> [String] {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 }
    }

    private static func rawGeneratedChapterTimingIssue(_ rawChapters: [ICGeneratedChapter],
                                                       totalDuration: Double,
                                                       existingChapters: [ICGeneratedChapter]?) -> String? {
        guard existingChapters == nil else { return nil }
        guard !rawChapters.isEmpty else { return nil }

        let boundaryTolerance = max(2.0, min(6.0, totalDuration * 0.0025))
        let sorted = rawChapters.sorted { $0.start < $1.start }

        guard let first = sorted.first, first.start <= boundaryTolerance else {
            return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat den Anfang der Folge nicht abgedeckt."
        }

        for chapter in sorted {
            if chapter.start < -boundaryTolerance || chapter.end > totalDuration + boundaryTolerance {
                return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat Kapitelzeiten ausserhalb der Transkriptdauer geliefert."
            }
            if chapter.end <= chapter.start {
                return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat ungueltige Kapitelzeiten geliefert."
            }
        }

        for pair in zip(sorted, sorted.dropFirst()) {
            if abs(pair.0.end - pair.1.start) > boundaryTolerance {
                return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat nicht zusammenhaengende Kapitelgrenzen geliefert."
            }
        }

        if let last = sorted.last,
           abs(last.end - totalDuration) > boundaryTolerance {
            return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat die Folge nicht bis zum Ende abgedeckt."
        }

        return nil
    }

    private static func validatedGeneratedChapters(_ chapters: [ICGeneratedChapter],
                                                   totalDuration: Double,
                                                   topicMarkerCount: Int,
                                                   topicMarkers: [TopicMarker],
                                                   musicSegments: [ICAudioSegment]?,
                                                   transcriptCues: [ICTranscriptCue],
                                                   existingChapters: [ICGeneratedChapter]?,
                                                   debugTrace: ChapterDebugTrace?) throws -> [ICGeneratedChapter] {
        let issue = chapterQualityIssue(chapters,
                                        totalDuration: totalDuration,
                                        topicMarkerCount: topicMarkerCount,
                                        topicMarkers: topicMarkers,
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
                                            topicMarkers: [TopicMarker],
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

        if let issue = singleChapterUndersegmentationIssue(chapters,
                                                           totalDuration: totalDuration,
                                                           transcriptCues: transcriptCues) {
            return issue
        }

        let boundaryChapters = standaloneIntroOutroMusicChapters(from: musicSegments,
                                                                 transcriptCues: transcriptCues,
                                                                 transcriptDuration: totalDuration)
        if let issue = missingMusicBoundaryIssue(chapters, boundaryChapters: boundaryChapters) {
            return issue
        }

        if let issue = invalidStructuralChapterIssue(chapters,
                                                     boundaryChapters: boundaryChapters) {
            return issue
        }

        if let issue = invalidAudioInterludeChapterIssue(chapters,
                                                         musicSegments: musicSegments) {
            return issue
        }

        if let issue = repeatedAdjacentContentTitleIssue(chapters) {
            return issue
        }

        return nil
    }

    private static func singleChapterUndersegmentationIssue(_ chapters: [ICGeneratedChapter],
                                                            totalDuration: Double,
                                                            transcriptCues: [ICTranscriptCue]) -> String? {
        guard chapters.count == 1,
              let only = chapters.first,
              !only.isSponsor,
              normalizedStructuralChapterTitle(only.title) == nil,
              normalizedAudioInterludeTitle(only.title) == nil,
              totalDuration >= 600,
              transcriptCues.count >= 50,
              only.start <= 1,
              only.end >= totalDuration * 0.85 else {
            return nil
        }

        let questionCueCount = transcriptCues.reduce(0) { count, cue in
            transcriptCueTextForTitle(cue.text).contains("?") ? count + 1 : count
        }
        if questionCueCount >= 3 {
            return "Kapitelerkennung fehlgeschlagen - Kapitelmodell hat ein dialogisches Transkript zu einem einzelnen Gesamtkapitel reduziert."
        }
        return nil
    }

    private static func repeatedAdjacentContentTitleIssue(_ chapters: [ICGeneratedChapter]) -> String? {
        for pair in zip(chapters, chapters.dropFirst()) {
            let lhs = pair.0
            let rhs = pair.1
            guard !lhs.isSponsor,
                  !rhs.isSponsor,
                  normalizedStructuralChapterTitle(lhs.title) == nil,
                  normalizedStructuralChapterTitle(rhs.title) == nil else {
                continue
            }
            let lhsSignature = contentTitleSignature(lhs.title)
            let rhsSignature = contentTitleSignature(rhs.title)
            guard lhsSignature.count >= 2, rhsSignature.count >= 2 else { continue }
            let overlap = lhsSignature.intersection(rhsSignature).count
            let union = lhsSignature.union(rhsSignature).count
            if union > 0, Double(overlap) / Double(union) >= 0.75 {
                return "Kapitelerkennung fehlgeschlagen - benachbarte Inhaltskapitel haben zu aehnliche Titel."
            }
        }
        return nil
    }

    private static func contentTitleSignature(_ title: String) -> Set<String> {
        let normalized = title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        return Set(normalized
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 })
    }

    private static func invalidStructuralChapterIssue(_ chapters: [ICGeneratedChapter],
                                                      boundaryChapters: [ICGeneratedChapter]) -> String? {
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
               coveringMusicBoundary(chapter, in: boundaryChapters) == nil {
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

    private static func invalidAudioInterludeChapterIssue(_ chapters: [ICGeneratedChapter],
                                                          musicSegments: [ICAudioSegment]?) -> String? {
        for chapter in chapters {
            guard normalizedAudioInterludeTitle(chapter.title) != nil else { continue }
            let duration = chapter.end - chapter.start
            if duration > maximumAudioInterludeChapterDuration {
                return "Kapitelerkennung fehlgeschlagen - Audio-Kapitel ist laenger als das erkannte Musik-/Soundsegment."
            }
            if !audioChapterHasMatchingMusicSegment(chapter, musicSegments: musicSegments) {
                return "Kapitelerkennung fehlgeschlagen - Audio-Kapitel ohne passende Audioanalyse-Grenze."
            }
            if chapter.isSponsor {
                return "Kapitelerkennung fehlgeschlagen - Audio-Kapitel wurde faelschlich als Werbung markiert."
            }
        }
        return nil
    }

    private static func audioChapterHasMatchingMusicSegment(_ chapter: ICGeneratedChapter,
                                                            musicSegments: [ICAudioSegment]?) -> Bool {
        let chapterDuration = max(0, chapter.end - chapter.start)
        guard chapterDuration > 0 else { return false }
        let requiredOverlap = min(3.0, max(1.0, chapterDuration * 0.35))
        return (musicSegments ?? []).contains { segment in
            guard segment.type == "music", segment.end > segment.start else { return false }
            return overlapDuration(chapter.start, chapter.end, segment.start, segment.end) >= requiredOverlap
        }
    }

    private static func isStructuralChapterTitle(_ title: String) -> Bool {
        normalizedStructuralChapterTitle(title) != nil
    }

    private static func normalizedStructuralChapterTitle(_ title: String) -> String? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        return ["intro", "outro"].contains(normalized) ? normalized : nil
    }

    private static func normalizedAudioInterludeTitle(_ title: String) -> String? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#,
                                  with: " ",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "jingle" {
            return "jingle"
        }
        if ["sound sample", "soundsample", "audio sample", "sample"].contains(normalized) {
            return "sound-sample"
        }
        return nil
    }

    private static func overlapDuration(_ startA: Double,
                                        _ endA: Double,
                                        _ startB: Double,
                                        _ endB: Double) -> Double {
        max(0, min(endA, endB) - max(startA, startB))
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

    private static func coveringMusicBoundary(_ chapter: ICGeneratedChapter,
                                              in boundaryChapters: [ICGeneratedChapter]) -> ICGeneratedChapter? {
        guard let title = normalizedStructuralChapterTitle(chapter.title) else { return nil }
        let tolerance = 2.0
        return boundaryChapters.first { boundary in
            chapterCoversMusicBoundary(chapter, boundary: boundary, title: title, tolerance: tolerance)
        }
    }

    private static func chapterCoversMusicBoundary(_ chapter: ICGeneratedChapter,
                                                   boundary: ICGeneratedChapter,
                                                   title: String,
                                                   tolerance: Double) -> Bool {
        let maxAbsorbedFragmentDuration = 20.0
        return normalizedStructuralChapterTitle(chapter.title) == title
            && normalizedStructuralChapterTitle(boundary.title) == title
            && chapter.start <= boundary.start + tolerance
            && chapter.start >= boundary.start - maxAbsorbedFragmentDuration
            && chapter.end >= boundary.end - tolerance
            && chapter.end <= boundary.end + maxAbsorbedFragmentDuration
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
            "erste themen",
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
            || normalized.hasPrefix("musiksegment")
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
                chapterCoversMusicBoundary(chapter, boundary: boundary, title: title, tolerance: tolerance)
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

    private static func chaptersByMergingTerminalFragmentsIntoOutro(_ chapters: [ICGeneratedChapter],
                                                                    transcriptDuration: Double) -> [ICGeneratedChapter] {
        guard chapters.count >= 2 else { return chapters }
        var result = chapters
        let lastIndex = result.index(before: result.endIndex)
        let previousIndex = result.index(before: lastIndex)
        let last = result[lastIndex]
        let previous = result[previousIndex]
        guard normalizedStructuralChapterTitle(previous.title) == "outro",
              normalizedStructuralChapterTitle(last.title) == nil,
              !last.isSponsor,
              last.end >= transcriptDuration - 2,
              last.end - last.start <= minimumSplitChapterDuration else {
            return chapters
        }
        result[previousIndex] = ICGeneratedChapter(start: previous.start,
                                                   end: last.end,
                                                   title: "Outro",
                                                   isSponsor: false)
        result.remove(at: lastIndex)
        NSLog("[ChapterGenerator] Kurzes Schlussfragment in Outro zusammengefuehrt")
        return result
    }

    private static func chaptersByMergingShortFragmentsAroundStructuralChapters(_ chapters: [ICGeneratedChapter],
                                                                               totalDuration: Double) -> [ICGeneratedChapter] {
        guard chapters.count >= 2 else { return chapters }
        let shortFragmentDuration = 15.0
        var result: [ICGeneratedChapter] = []
        var mergeCount = 0

        for chapter in chapters {
            let duration = chapter.end - chapter.start
            let isShortContentFragment = duration <= shortFragmentDuration
                && !chapter.isSponsor
                && normalizedStructuralChapterTitle(chapter.title) == nil

            if isShortContentFragment,
               let previous = result.last,
               normalizedStructuralChapterTitle(previous.title) != nil {
                result[result.count - 1] = ICGeneratedChapter(start: previous.start,
                                                              end: chapter.end,
                                                              title: previous.title,
                                                              isSponsor: previous.isSponsor)
                mergeCount += 1
                continue
            }

            result.append(chapter)
        }

        if mergeCount > 0 {
            NSLog("[ChapterGenerator] Kurze Fragmente an Strukturkapitel angefuegt: %d", mergeCount)
        }
        return normalizedChapters(result,
                                  totalDuration: totalDuration,
                                  forceContinuousBoundaries: true)
    }

    private static func chaptersByMergingShortFragmentsBeforeStructuralChapters(_ chapters: [ICGeneratedChapter],
                                                                               totalDuration: Double) -> [ICGeneratedChapter] {
        guard chapters.count >= 3 else { return chapters }
        let shortFragmentDuration = 20.0
        let maximumMergedDuration = 30.0
        var result: [ICGeneratedChapter] = []
        var index = chapters.startIndex
        var mergeCount = 0

        while index < chapters.endIndex {
            let chapter = chapters[index]
            let duration = chapter.end - chapter.start
            let isShortContentFragment = duration <= shortFragmentDuration
                && !chapter.isSponsor
                && normalizedStructuralChapterTitle(chapter.title) == nil

            guard isShortContentFragment else {
                result.append(chapter)
                index = chapters.index(after: index)
                continue
            }

            var runEnd = index
            var mergedEnd = chapter.end
            while chapters.index(after: runEnd) < chapters.endIndex {
                let nextIndex = chapters.index(after: runEnd)
                let next = chapters[nextIndex]
                let nextDuration = next.end - next.start
                guard nextDuration <= shortFragmentDuration,
                      !next.isSponsor,
                      normalizedStructuralChapterTitle(next.title) == nil else {
                    break
                }
                runEnd = nextIndex
                mergedEnd = next.end
            }

            let afterRun = chapters.index(after: runEnd)
            let runContainsMultipleFragments = runEnd != index
            if runContainsMultipleFragments,
               afterRun < chapters.endIndex,
               normalizedStructuralChapterTitle(chapters[afterRun].title) != nil,
               mergedEnd - chapter.start <= maximumMergedDuration {
                result.append(ICGeneratedChapter(start: chapter.start,
                                                 end: mergedEnd,
                                                 title: chapter.title,
                                                 isSponsor: false))
                mergeCount += 1
                index = afterRun
                continue
            }

            result.append(chapter)
            index = chapters.index(after: index)
        }

        if mergeCount > 0 {
            NSLog("[ChapterGenerator] Kurze Fragmente vor Strukturkapiteln zusammengefuehrt: %d", mergeCount)
        }
        return normalizedChapters(result,
                                  totalDuration: totalDuration,
                                  forceContinuousBoundaries: true)
    }

    private static func chaptersByReplacingGenericContentTitles(_ chapters: [ICGeneratedChapter],
                                                                transcriptCues: [ICTranscriptCue]) -> [ICGeneratedChapter] {
        var replacementCount = 0
        let repaired = chapters.map { chapter -> ICGeneratedChapter in
            guard !chapter.isSponsor,
                  normalizedStructuralChapterTitle(chapter.title) == nil,
                  (isGenericChapterTitle(chapter.title) || isWeakChapterTitle(chapter.title)),
                  let replacement = contentTitleForChapter(chapter, transcriptCues: transcriptCues) else {
                return chapter
            }
            replacementCount += 1
            return ICGeneratedChapter(start: chapter.start,
                                      end: chapter.end,
                                      title: replacement,
                                      isSponsor: replacement.hasPrefix("Sponsor: "))
        }
        if replacementCount > 0 {
            NSLog("[ChapterGenerator] Generische Kapiteltitel durch Transkriptinhalt ersetzt: %d", replacementCount)
        }
        return repaired
    }

    private static func chaptersByReplacingVerboseContentTitles(_ chapters: [ICGeneratedChapter],
                                                                transcriptCues: [ICTranscriptCue]) -> [ICGeneratedChapter] {
        let contentChapterCount = chapters.filter {
            !$0.isSponsor
                && normalizedStructuralChapterTitle($0.title) == nil
                && normalizedAudioInterludeTitle($0.title) == nil
        }.count
        guard contentChapterCount > 1 else { return chapters }

        var replacementCount = 0
        let repaired = chapters.map { chapter -> ICGeneratedChapter in
            guard !chapter.isSponsor,
                  normalizedStructuralChapterTitle(chapter.title) == nil,
                  isVerboseContentTitle(chapter.title),
                  let replacement = conciseContentTitleForChapter(chapter, transcriptCues: transcriptCues),
                  replacement != chapter.title else {
                return chapter
            }
            replacementCount += 1
            return ICGeneratedChapter(start: chapter.start,
                                      end: chapter.end,
                                      title: replacement,
                                      isSponsor: replacement.hasPrefix("Sponsor: "))
        }
        if replacementCount > 0 {
            NSLog("[ChapterGenerator] Lange Kapiteltitel durch kurze Inhaltsueberschriften ersetzt: %d", replacementCount)
        }
        return repaired
    }

    private static func chaptersByAddingMusicBoundaryChapters(_ chapters: [ICGeneratedChapter],
                                                              musicSegments: [ICAudioSegment]?,
                                                              transcriptCues: [ICTranscriptCue],
                                                              transcriptDuration: Double) -> [ICGeneratedChapter] {
        let boundaryChapters = standaloneIntroOutroMusicChapters(from: musicSegments,
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
                    outcome = chaptersByInsertingMusicChapter(boundary, to: result, transcriptCues: transcriptCues)
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
            let title = transcriptCueTitle(from: cue.text)
            guard !title.isEmpty,
                  !isStructuralChapterTitle(title),
                  !isGenericChapterTitle(title) else {
                return nil
            }
            return title
        }
        return titles.first { !isWeakChapterTitle($0) }
    }

    private static func conciseContentTitleForChapter(_ chapter: ICGeneratedChapter,
                                                      transcriptCues: [ICTranscriptCue]) -> String? {
        let preserveTeaserPrefix = chapter.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
            .hasPrefix("teaser:")
        let candidates = transcriptCues
            .filter {
                $0.end > chapter.start
                    && $0.start < chapter.end
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !isMusicOnlyCue($0)
            }
            .sorted { $0.start < $1.start }
            .compactMap { conciseContentTitle(from: $0.text, preserveTeaserPrefix: preserveTeaserPrefix) }
        return candidates.first { isUsableConciseContentTitle($0) }
            ?? candidates.first { !isWeakChapterTitle($0) && !isGenericChapterTitle($0) && !isVerboseContentTitle($0) }
    }

    private static func conciseContentTitle(from text: String, preserveTeaserPrefix: Bool) -> String? {
        let cleaned = transcriptCueTextForTitle(text)
        guard !cleaned.isEmpty else { return nil }

        let title = shortTranscriptTitle(from: cleaned)

        guard !title.isEmpty else { return nil }
        return preserveTeaserPrefix && !title.hasPrefix("Teaser:") ? "Teaser: \(title)" : title
    }

    private static func shortTranscriptTitle(from text: String) -> String {
        let fragments = text
            .components(separatedBy: CharacterSet(charactersIn: ".?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { hasMeaningfulTitleCharacter($0) }
        let source = fragments.first ?? text
        let words = source.split { $0.isWhitespace || $0.isNewline }
        return words.prefix(8).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUsableConciseContentTitle(_ title: String) -> Bool {
        guard hasMeaningfulTitleCharacter(title) else { return false }
        if isWeakChapterTitle(title) || isGenericChapterTitle(title) || isVerboseContentTitle(title) {
            return false
        }
        let wordCount = title.split { $0.isWhitespace || $0.isNewline }.count
        return wordCount > 1 || title.count >= 7
    }

    private static func hasMeaningfulTitleCharacter(_ title: String) -> Bool {
        title.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isVerboseContentTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }
        if words.count > 14 { return true }
        if trimmed.contains("?") { return true }
        if words.count > 4 && trimmed.contains(",") { return true }
        if words.count > 4 && trimmed.contains(".") { return true }
        return isWeakChapterTitle(trimmed)
    }

    private static func isWeakChapterTitle(_ title: String) -> Bool {
        var normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        guard hasMeaningfulTitleCharacter(normalized) else { return true }
        if normalized.hasPrefix("sponsor:") {
            normalized = normalized
                .replacingOccurrences(of: #"^sponsor:\s*"#, with: "", options: .regularExpression)
        }
        return isLowInformationContentTitle(normalized)
    }

    private static func isLowInformationContentTitle(_ title: String) -> Bool {
        let words = title
            .split { !$0.isLetter && !$0.isNumber }
            .map { word in
                String(word)
                    .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    .lowercased()
            }
        guard !words.isEmpty, words.count <= 4 else { return false }
        let letterOrNumberCount = words.joined().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        return letterOrNumberCount < 7
    }

    private static func chaptersByApplyingEpisodeTitleToSingleContentChapter(_ chapters: [ICGeneratedChapter],
                                                                             episodeTitle: String?,
                                                                             transcriptCues: [ICTranscriptCue]) -> [ICGeneratedChapter] {
        guard let episodeTitle = episodeTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !episodeTitle.isEmpty,
              !isGenericChapterTitle(episodeTitle),
              !isWeakChapterTitle(episodeTitle) else {
            return chapters
        }
        let contentIndices = chapters.indices.filter { index in
            let chapter = chapters[index]
            return !chapter.isSponsor
                && normalizedStructuralChapterTitle(chapter.title) == nil
                && normalizedAudioInterludeTitle(chapter.title) == nil
        }
        guard contentIndices.count == 1,
              let contentIndex = contentIndices.first else {
            return chapters
        }

        let episodeSignals = episodeTitleNumberSignals(in: episodeTitle)
        guard !episodeSignals.isEmpty else { return chapters }

        let transcriptText = transcriptCues.map(\.text).joined(separator: " ")
        let transcriptSignals = episodeTitleNumberSignals(in: transcriptText)
        guard !episodeSignals.isDisjoint(with: transcriptSignals) else { return chapters }

        let currentSignals = episodeTitleNumberSignals(in: chapters[contentIndex].title)
        guard episodeSignals.count > currentSignals.count else { return chapters }

        var result = chapters
        let chapter = result[contentIndex]
        result[contentIndex] = ICGeneratedChapter(start: chapter.start,
                                                  end: chapter.end,
                                                  title: episodeTitle,
                                                  isSponsor: chapter.isSponsor)
        return result
    }

    private static func episodeTitleNumberSignals(in text: String) -> Set<String> {
        Set(text
            .split { !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty })
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

    private static func standaloneIntroOutroMusicChapters(from musicSegments: [ICAudioSegment]?,
                                                          transcriptCues: [ICTranscriptCue],
                                                          transcriptDuration: Double) -> [ICGeneratedChapter] {
        let validSegments = (musicSegments ?? [])
            .filter { $0.end > $0.start && $0.end > 0 }
            .sorted { $0.start < $1.start }
        let music = validSegments.filter { $0.type == "music" }
        guard !music.isEmpty,
              let speechBoundaries = speechBoundaries(from: transcriptCues,
                                                      excludingMusicSegments: music) else { return [] }

        let tolerance = 2.0
        let firstSpeechStart = speechBoundaries.firstSpeechStart
        let lastSpeechEnd = speechBoundaries.lastSpeechEnd
        let timelineEnd = transcriptDuration
        let hasFullTimeline = validSegments.contains { $0.type != "music" }
        let earlyIntroWindow = 90.0
        let standaloneMusicDuration = 4.0

        var chapters: [ICGeneratedChapter] = []
        if let earlyIntro = music.first(where: { $0.start <= earlyIntroWindow && $0.end - $0.start >= standaloneMusicDuration }) {
            if let intro = trimmedStandaloneMusicChapter(earlyIntro,
                                                         title: "Intro",
                                                         transcriptCues: transcriptCues,
                                                         timelineEnd: timelineEnd,
                                                         excludingMusicSegments: music,
                                                         minimumDuration: standaloneMusicDuration) {
                chapters.append(intro)
            }
        } else if let firstMusic = music.first {
            let isFirstNonSilence = hasFullTimeline
                && sameSegment(validSegments.first { $0.type != "silence" }, as: firstMusic, tolerance: tolerance)
            let startsAtBeginning = !hasFullTimeline && firstMusic.start <= tolerance
            if isFirstNonSilence || startsAtBeginning {
                let leadingMusicEnd = min(firstMusic.end, timelineEnd)
                let end = firstSpeechStart <= tolerance ? leadingMusicEnd : min(leadingMusicEnd, firstSpeechStart)
                let segment = ICAudioSegment(type: "music", start: 0, end: end, confidence: firstMusic.confidence)
                if let intro = trimmedStandaloneMusicChapter(segment,
                                                             title: "Intro",
                                                             transcriptCues: transcriptCues,
                                                             timelineEnd: timelineEnd,
                                                             excludingMusicSegments: music,
                                                             minimumDuration: standaloneMusicDuration) {
                    chapters.append(intro)
                }
            }
        }

        if let lastMusic = music.last {
            let isLastNonSilence = hasFullTimeline
                && sameSegment(validSegments.last { $0.type != "silence" }, as: lastMusic, tolerance: tolerance)
            let endsAtKnownEnd = !hasFullTimeline && lastMusic.end >= transcriptDuration - tolerance
            if isLastNonSilence || endsAtKnownEnd {
                let speechEnd = min(lastSpeechEnd, timelineEnd)
                let trailingMusicStart = max(lastMusic.start, speechEnd, 0)
                let segment = ICAudioSegment(type: "music",
                                             start: trailingMusicStart,
                                             end: timelineEnd,
                                             confidence: lastMusic.confidence)
                let overlapsExistingBoundary = chapters.contains { segment.start < $0.end && segment.end > $0.start }
                if !overlapsExistingBoundary,
                   let outro = trimmedStandaloneMusicChapter(segment,
                                                             title: "Outro",
                                                             transcriptCues: transcriptCues,
                                                             timelineEnd: timelineEnd,
                                                             excludingMusicSegments: music,
                                                             minimumDuration: standaloneMusicDuration) {
                    chapters.append(outro)
                }
            }
        }

        return chapters
    }

    private static func speechBoundaries(from cues: [ICTranscriptCue],
                                         excludingMusicSegments musicSegments: [ICAudioSegment]? = nil) -> (firstSpeechStart: Double, lastSpeechEnd: Double)? {
        let spokenCues = meaningfulSpeechCues(from: cues,
                                              excludingMusicSegments: musicSegments)
        guard let first = spokenCues.first, let last = spokenCues.last else { return nil }
        return (first.start, last.end)
    }

    private static func meaningfulSpeechCues(from cues: [ICTranscriptCue],
                                             excludingMusicSegments musicSegments: [ICAudioSegment]? = nil) -> [ICTranscriptCue] {
        cues
            .filter {
                isMeaningfulSpeechText($0.text)
                    && !isMusicOnlyCue($0)
                    && !isDominatedByMusic($0, musicSegments: musicSegments)
            }
            .sorted { $0.start < $1.start }
    }

    private static func isDominatedByMusic(_ cue: ICTranscriptCue,
                                           musicSegments: [ICAudioSegment]?) -> Bool {
        guard let musicSegments,
              !musicSegments.isEmpty else { return false }
        let duration = cue.end - cue.start
        guard duration > 0 else { return false }
        let musicOverlap = musicSegments.reduce(0.0) { total, segment in
            guard segment.type == "music",
                  segment.end > segment.start else { return total }
            return total + overlapDuration(cue.start, cue.end, segment.start, segment.end)
        }
        return musicOverlap / duration >= 0.5
    }

    private static func trimmedStandaloneMusicChapter(_ segment: ICAudioSegment,
                                                      title: String,
                                                      transcriptCues: [ICTranscriptCue],
                                                      timelineEnd: Double,
                                                      excludingMusicSegments musicSegments: [ICAudioSegment],
                                                      minimumDuration: Double) -> ICGeneratedChapter? {
        var start = max(0, segment.start)
        var end = min(segment.end, timelineEnd)
        let overlappingSpeech = meaningfulSpeechCues(from: transcriptCues,
                                                     excludingMusicSegments: musicSegments)
            .filter { $0.end > start && $0.start < end }
        if let firstSpeech = overlappingSpeech.first,
           firstSpeech.start <= start + 1.0 {
            return nil
        }
        if let firstSpeech = overlappingSpeech.first {
            end = min(end, firstSpeech.start)
        }
        if let lastSpeech = overlappingSpeech.last,
           lastSpeech.end >= end - 1.0 {
            start = max(start, lastSpeech.end)
        }
        guard end - start >= minimumDuration else { return nil }
        guard meaningfulSpeechOverlapDuration(start: start,
                                              end: end,
                                              transcriptCues: transcriptCues,
                                              excludingMusicSegments: musicSegments) <= 1.0 else {
            return nil
        }
        return ICGeneratedChapter(start: start, end: end, title: title, isSponsor: false)
    }

    private static func meaningfulSpeechOverlapDuration(start: Double,
                                                        end: Double,
                                                        transcriptCues: [ICTranscriptCue],
                                                        excludingMusicSegments musicSegments: [ICAudioSegment]? = nil) -> Double {
        meaningfulSpeechCues(from: transcriptCues,
                             excludingMusicSegments: musicSegments).reduce(0.0) { total, cue in
            let overlapStart = max(start, cue.start)
            let overlapEnd = min(end, cue.end)
            return total + max(0, overlapEnd - overlapStart)
        }
    }

    private static func isMeaningfulSpeechText(_ text: String) -> Bool {
        let cleaned = transcriptCueTextForTitle(text)
        guard !cleaned.isEmpty else { return false }
        let alphanumericCount = cleaned.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.count
        return alphanumericCount >= 3
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
        if let firstToken = tokens.first,
           musicTokens.contains(firstToken),
           tokens.count <= 12 {
            return true
        }
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
                                                        to chapters: [ICGeneratedChapter],
                                                        transcriptCues: [ICTranscriptCue]) -> ([ICGeneratedChapter], Bool) {
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
                result.append(titleForBoundarySplitFragment(chapter,
                                                            start: chapter.start,
                                                            end: music.start,
                                                            transcriptCues: transcriptCues,
                                                            prefixTeaser: music.title == "Intro",
                                                            preferSourceTitle: false))
            }
            if !inserted {
                result.append(music)
                inserted = true
            }
            if chapter.end > music.end {
                result.append(titleForBoundarySplitFragment(chapter,
                                                            start: music.end,
                                                            end: chapter.end,
                                                            transcriptCues: transcriptCues,
                                                            prefixTeaser: false,
                                                            preferSourceTitle: true))
            }
        }

        if !inserted {
            result.append(music)
            inserted = true
        }
        return (result.filter { $0.end > $0.start }, inserted)
    }

    private static func titleForBoundarySplitFragment(_ source: ICGeneratedChapter,
                                                      start: Double,
                                                      end: Double,
                                                      transcriptCues: [ICTranscriptCue],
                                                      prefixTeaser: Bool,
                                                      preferSourceTitle: Bool = false) -> ICGeneratedChapter {
        let fragment = ICGeneratedChapter(start: start,
                                          end: end,
                                          title: source.title,
                                          isSponsor: source.isSponsor)
        var title = (preferSourceTitle ? usableSourceTitleForBoundarySplit(source) : nil)
            ?? conciseContentTitleForChapter(fragment, transcriptCues: transcriptCues)
            ?? contentTitleForChapter(fragment, transcriptCues: transcriptCues)
            ?? source.title
        if prefixTeaser && !title.hasPrefix("Teaser:") && !title.hasPrefix("Sponsor:") {
            title = "Teaser: \(title)"
        }
        return ICGeneratedChapter(start: start,
                                  end: end,
                                  title: title,
                                  isSponsor: source.isSponsor || title.hasPrefix("Sponsor: "))
    }

    private static func usableSourceTitleForBoundarySplit(_ source: ICGeneratedChapter) -> String? {
        let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !source.isSponsor,
              !title.hasPrefix("Sponsor: "),
              normalizedStructuralChapterTitle(title) == nil,
              normalizedAudioInterludeTitle(title) == nil,
              !isGenericChapterTitle(title),
              !isWeakChapterTitle(title),
              !isVerboseContentTitle(title) else {
            return nil
        }
        return title
    }

    private static func sameSegment(_ segment: ICAudioSegment?,
                                    as other: ICAudioSegment,
                                    tolerance: Double) -> Bool {
        guard let segment else { return false }
        return segment.type == other.type
            && abs(segment.start - other.start) <= tolerance
            && abs(segment.end - other.end) <= tolerance
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

    private func formatModelSecond(_ seconds: Double) -> String {
        "\(Int(seconds.rounded()))s"
    }

    private func formatModelSecondRange(_ start: Double, _ end: Double) -> String {
        "\(formatModelSecond(start))-\(formatModelSecond(end))"
    }

    // MARK: - Persistence

    // Cache for hasChapters results
    private var _chaptersCache: [String: Bool] = [:]
    private var _loadedChaptersCache: [String: [ICGeneratedChapter]] = [:]

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
            _loadedChaptersCache[episodeHash] = chapters
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
        if let cached = _loadedChaptersCache[episodeHash] {
            return cached
        }

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
            let chapters = file.chapters.map {
                ICGeneratedChapter(start: $0.start, end: $0.end, title: $0.title, isSponsor: $0.isSponsor)
            }
            _loadedChaptersCache[episodeHash] = chapters
            _chaptersCache[episodeHash] = true
            return chapters
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
        _loadedChaptersCache.removeValue(forKey: episodeHash)
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
        _loadedChaptersCache.removeValue(forKey: episodeHash)
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
