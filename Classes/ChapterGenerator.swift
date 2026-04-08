//
//  ChapterGenerator.swift
//  Instacast
//
//  Auto-generates chapters and detects sponsor segments from transcripts
//  using Apple Foundation Models (on-device LLM, requires Apple Intelligence).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
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
                                progress: ((Float, Int, Int) -> Void)? = nil,
                                completion: @escaping ([ICGeneratedChapter]?, Error?) -> Void) {
        guard ChapterGenerator.isAvailable() else {
            completion(nil, NSError(domain: "ChapterGenerator", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"]))
            return
        }

        guard !cues.isEmpty else {
            completion(nil, NSError(domain: "ChapterGenerator", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "No transcript cues provided"]))
            return
        }

        Task {
            do {
                let chapters = try await self.generateWithLLM(cues: cues, musicSegments: musicSegments,
                                                              existingChapters: nil, progress: progress)
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

    /// Detect sponsor segments from transcript using existing chapters as context.
    /// Returns only the detected sponsor chapters — caller must merge via `mergeSponsors(_:into:)`.
    @objc func detectSponsors(fromCues cues: [ICTranscriptCue],
                              existingChapters: [ICGeneratedChapter],
                              completion: @escaping ([ICGeneratedChapter]?, Error?) -> Void) {
        guard ChapterGenerator.isAvailable() else {
            completion(nil, NSError(domain: "ChapterGenerator", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence not available"]))
            return
        }

        Task {
            do {
                let chapters = try await self.generateWithLLM(cues: cues, musicSegments: nil,
                                                              existingChapters: existingChapters)
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
                                 progress: ((Float, Int, Int) -> Void)? = nil) async throws -> [ICGeneratedChapter] {
        guard #available(iOS 26, *) else {
            throw NSError(domain: "ChapterGenerator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "iOS 26 required"])
        }

        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        let contextSize = model.contextSize
        // Reserve half for response — the LLM needs room to generate a full chapter list
        let maxInputTokens = contextSize / 2

        NSLog("[ChapterGenerator] Context window: %d tokens, max input: %d tokens", contextSize, maxInputTokens)
        await MainActor.run { progress?(0.1, 0, 1) }

        // Iteratively condense until the prompt fits the token budget.
        // Start with generous char estimate, measure actual tokens, reduce if needed.
        // ~3 chars/token is a reasonable starting estimate for mixed German/English text.
        var charBudget = maxInputTokens * 3
        var finalPrompt: String = ""

        for attempt in 1...5 {
            let condensed = Self.condenseTranscript(cues, maxChars: charBudget)
            let prompt = buildPrompt(cues: condensed, musicSegments: musicSegments, existingChapters: existingChapters)

            var promptTokens = prompt.count / 2 // conservative fallback
            if #available(iOS 26.4, *) {
                promptTokens = (try? await model.tokenCount(for: prompt)) ?? promptTokens
            }

            NSLog("[ChapterGenerator] Attempt %d: %d samples, %d chars, %d tokens (limit: %d)",
                  attempt, condensed.count, prompt.count, promptTokens, maxInputTokens)

            if promptTokens <= maxInputTokens {
                finalPrompt = prompt
                break
            }

            // Reduce char budget proportionally based on actual measurement
            charBudget = charBudget * maxInputTokens / max(promptTokens, 1)
            charBudget = max(charBudget, 500) // minimum
        }

        guard !finalPrompt.isEmpty else {
            throw NSError(domain: "ChapterGenerator", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Transkript zu lang für Kapitelerkennung."])
        }

        await MainActor.run { progress?(0.3, 0, 1) }

        let session = LanguageModelSession()
        let response = try await session.respond(to: finalPrompt)
        let text = response.content
        NSLog("[ChapterGenerator] Response (%d chars): %@", text.count, String(text.prefix(500)))

        await MainActor.run { progress?(0.9, 1, 1) }

        let chapters = parseChaptersFromLLMResponse(text)
        NSLog("[ChapterGenerator] Parsed %d chapters", chapters.count)

        await MainActor.run { progress?(1.0, 1, 1) }
        return chapters
        #else
        throw NSError(domain: "ChapterGenerator", code: 100,
                      userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelerkennung benötigt iOS 26. Bitte aktualisiere auf iOS 26 wenn verfügbar.", comment: "")])
        #endif
    }

    /// Parse the LLM response text into chapter objects.
    /// Expects JSON array with objects containing: start, end, title, isSponsor
    private func parseChaptersFromLLMResponse(_ text: String) -> [ICGeneratedChapter] {
        // Extract JSON from the response (LLM may wrap it in markdown code blocks)
        var jsonString = text
        if let startRange = text.range(of: "[", options: .literal),
           let endRange = text.range(of: "]", options: .backwards) {
            jsonString = String(text[startRange.lowerBound...endRange.lowerBound])
        }

        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            NSLog("[ChapterGenerator] Failed to parse JSON from LLM response: %@", text.prefix(200).description)
            return []
        }

        var chapters: [ICGeneratedChapter] = []
        for item in array {
            guard let title = item["title"] as? String else { continue }
            // Flexibly parse start/end — LLM may return Int, Double, or String
            guard let start = Self.parseNumber(item["start"]) else { continue }
            let end = Self.parseNumber(item["end"]) ?? start
            let isSponsor = item["isSponsor"] as? Bool ?? (item["is_sponsor"] as? Bool ?? false)
            chapters.append(ICGeneratedChapter(start: start, end: end, title: title, isSponsor: isSponsor))
        }
        if chapters.isEmpty {
            NSLog("[ChapterGenerator] No chapters parsed from %d items. First item: %@", array.count, array.first.map { String(describing: $0) } ?? "nil")
        }
        return chapters.sorted { $0.start < $1.start }
    }

    private static func parseNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func buildPrompt(cues: [ICTranscriptCue],
                             musicSegments: [ICAudioSegment]?,
                             existingChapters: [ICGeneratedChapter]?) -> String {
        var prompt = ""

        let totalDuration = max((cues.last?.end ?? 0) - (cues.first?.start ?? 0), 1)
        let durationStr = formatTime(totalDuration)

        if let chapters = existingChapters, !chapters.isEmpty {
            // Mode B: Sponsor detection with existing chapters
            prompt += "Finde Werbe- und Sponsoring-Segmente in diesem Podcast-Transkript.\n"
            prompt += "Gesamtdauer: \(durationStr)\n\n"
            prompt += "Bestehende Kapitel NICHT verändern. Nur neue Sponsor-Segmente zurückgeben.\n\n"

            prompt += "Typische Sponsoring-Merkmale:\n"
            prompt += "- \"brought to you by\", \"sponsored by\", \"presented by\", \"powered by\"\n"
            prompt += "- Promo-Codes, Rabattcodes, Gutscheine (\"code\", \"coupon\", \"% off\", \"Rabatt\")\n"
            prompt += "- URLs/Links zu Produkten (\"slash\", \".com/\", \"link in der Beschreibung\")\n"
            prompt += "- \"kostenlos testen\", \"free trial\", \"Angebot\"\n"
            prompt += "- Abrupter Themenwechsel zu einem Produkt/Dienst, dann Rückkehr zum eigentlichen Thema\n\n"

            prompt += "Antwort NUR als JSON: [{\"start\":SEKUNDEN,\"end\":SEKUNDEN,\"title\":\"Sponsor: MARKENNAME\",\"isSponsor\":true}]\n"
            prompt += "Falls keine Werbung: leeres Array [] zurückgeben.\n\n"

            prompt += "Bestehende Kapitel:\n"
            for ch in chapters {
                let marker = ch.isSponsor ? " [Sponsor]" : ""
                prompt += "[\(formatTime(ch.start))-\(formatTime(ch.end))] \(ch.title)\(marker)\n"
            }
            prompt += "\n"
        } else {
            // Mode A: Full chapter generation
            prompt += "Teile dieses Podcast-Transkript in sinnvolle Kapitel auf.\n"
            prompt += "Gesamtdauer: \(durationStr)\n\n"

            prompt += "Regeln:\n"
            prompt += "- Erstelle so viele oder wenige Kapitel wie der Inhalt erfordert.\n"
            prompt += "- Jeder klare Themenwechsel ist eine Kapitelgrenze.\n"
            prompt += "- Kapitel können sehr kurz (30s Einschub) oder lang (30min Themenblock) sein.\n"
            prompt += "- Titel kurz und beschreibend, in der Sprache des Transkripts.\n\n"

            prompt += "Sponsoring/Werbung erkennen und als \"Sponsor: MARKENNAME\" kennzeichnen (isSponsor: true):\n"
            prompt += "- \"brought to you by\", \"sponsored by\", \"presented by\", \"powered by\"\n"
            prompt += "- Promo-Codes, Rabattcodes, Gutscheine (\"code\", \"coupon\", \"% off\", \"Rabatt\")\n"
            prompt += "- URLs/Links zu Produkten (\"slash\", \".com/\", \"link in der Beschreibung\")\n"
            prompt += "- \"kostenlos testen\", \"free trial\", \"Angebot\"\n"
            prompt += "- Abrupter Themenwechsel zu einem Produkt/Dienst, dann Rückkehr zum Thema\n\n"

            prompt += "Antwort NUR als JSON: [{\"start\":SEKUNDEN,\"end\":SEKUNDEN,\"title\":\"TITEL\",\"isSponsor\":false}]\n\n"
        }

        // Music segments — the model should interpret their meaning from context
        if let music = musicSegments?.filter({ $0.type == "music" }), !music.isEmpty {
            prompt += "Musik-Segmente (können Intro-Theme, Outro-Theme, Jingles zwischen Themen, oder Werbe-Jingles sein — aus dem Kontext erschließen):\n"
            for seg in music {
                prompt += "[\(formatTime(seg.start))-\(formatTime(seg.end))]\n"
            }
            prompt += "\n"
        }

        prompt += "Transkript:\n"
        for cue in cues {
            prompt += "[\(formatTime(cue.start))] \(cue.text)\n"
        }

        return prompt
    }

    // MARK: - Transcript Condensing

    /// Condense a full transcript to fit the on-device LLM context window.
    /// Keeps full cue text (no truncation!) so the model sees complete sentences.
    /// Reduces density by sampling at wider intervals when needed.
    private static func condenseTranscript(_ cues: [ICTranscriptCue], maxChars: Int) -> [ICTranscriptCue] {
        guard !cues.isEmpty else { return [] }

        // Check if full transcript fits — best case, send everything
        let totalChars = cues.reduce(0) { $0 + $1.text.count + 15 }
        if totalChars <= maxChars {
            return cues
        }

        let totalDuration = (cues.last?.end ?? 0) - (cues.first?.start ?? 0)
        guard totalDuration > 0 else { return cues }

        // Calculate sampling interval from actual average cue size (not a hardcoded guess)
        let avgCharsPerCue = max(totalChars / cues.count, 1)
        let targetSamples = max(maxChars / avgCharsPerCue, 10)
        let interval = totalDuration / Double(targetSamples)

        var sampled: [ICTranscriptCue] = []
        var nextSampleTime = cues.first?.start ?? 0
        var totalCharsUsed = 0

        for cue in cues {
            if cue.start >= nextSampleTime {
                let lineChars = cue.text.count + 12 // timestamp overhead
                if totalCharsUsed + lineChars > maxChars { break }
                sampled.append(cue) // Full text — no truncation
                totalCharsUsed += lineChars
                nextSampleTime = cue.start + interval
            }
        }

        NSLog("[ChapterGenerator] Condensed: %d cues → %d samples (interval %.0fs, ~%d chars)",
              cues.count, sampled.count, interval, totalCharsUsed)
        return sampled
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

    @objc func saveChapters(_ chapters: [ICGeneratedChapter], for episodeHash: String) {
        let file = ChaptersFile(
            chapters: chapters.map {
                .init(start: $0.start, end: $0.end, title: $0.title, isSponsor: $0.isSponsor)
            }
        )
        let url = TranscriptionEngine.shared.chaptersJSONURL(for: episodeHash)
        if let data = try? JSONEncoder().encode(file) {
            try? data.write(to: url, options: .atomic)
            NSLog("[ChapterGenerator] Saved %d chapters to %@, exists: %d", chapters.count, url.path, FileManager.default.fileExists(atPath: url.path) ? 1 : 0)
        }
    }

    @objc func loadChapters(for episodeHash: String) -> [ICGeneratedChapter]? {
        let url = TranscriptionEngine.shared.chaptersJSONURL(for: episodeHash)
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ChaptersFile.self, from: data) else {
            return nil
        }
        return file.chapters.map {
            ICGeneratedChapter(start: $0.start, end: $0.end, title: $0.title, isSponsor: $0.isSponsor)
        }
    }

    @objc func hasChapters(for episodeHash: String) -> Bool {
        let url = TranscriptionEngine.shared.chaptersJSONURL(for: episodeHash)
        let exists = FileManager.default.fileExists(atPath: url.path)
        NSLog("[ChapterGenerator] hasChapters(%@) = %d, path: %@", episodeHash, exists ? 1 : 0, url.path)
        return exists
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
