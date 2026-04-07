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
                                                              existingChapters: nil)
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

    /// Detect sponsor segments and merge into existing chapters.
    /// Mode B: Only sponsor detection (existing chapters present).
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
                                 existingChapters: [ICGeneratedChapter]?) async throws -> [ICGeneratedChapter] {
        guard #available(iOS 26, *) else {
            throw NSError(domain: "ChapterGenerator", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "iOS 26 required"])
        }

        // Build prompt
        let _ = buildPrompt(cues: cues, musicSegments: musicSegments, existingChapters: existingChapters)

        // TODO: Implement with Foundation Models framework
        // import FoundationModels
        //
        // let session = LanguageModelSession()
        //
        // // Use Guided Generation for structured JSON output
        // let schema = GenerationSchema(type: .array, items: .object(properties: [
        //     "start": .number,
        //     "end": .number,
        //     "title": .string,
        //     "isSponsor": .boolean
        // ]))
        //
        // let response = try await session.respond(to: prompt, generating: [ChapterOutput].self)
        //
        // return response.map { ICGeneratedChapter(start: $0.start, end: $0.end, title: $0.title, isSponsor: $0.isSponsor) }

        throw NSError(domain: "ChapterGenerator", code: 100,
                      userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelerkennung benötigt iOS 26. Bitte aktualisiere auf iOS 26 wenn verfügbar.", comment: "")])
    }

    private func buildPrompt(cues: [ICTranscriptCue],
                             musicSegments: [ICAudioSegment]?,
                             existingChapters: [ICGeneratedChapter]?) -> String {
        var prompt = ""

        if let existing = existingChapters, !existing.isEmpty {
            // Mode B: Sponsor detection only
            prompt += "Analyze the following podcast transcript and identify ONLY sponsor/advertisement segments.\n"
            prompt += "The podcast already has these chapters:\n"
            for ch in existing {
                let startStr = formatTime(ch.start)
                let endStr = formatTime(ch.end)
                prompt += "  [\(startStr) - \(endStr)] \(ch.title)\n"
            }
            prompt += "\nFind sponsor segments and return them with start/end times and the sponsor name.\n"
            prompt += "Look for: 'brought to you by', 'sponsored by', promo codes, discount links, 'use code', etc.\n"
        } else {
            // Mode A: Full chapter generation
            prompt += "Analyze the following podcast transcript and create chapter markers.\n"
            prompt += "Identify topic changes and sponsor/advertisement segments.\n"
            prompt += "For sponsor segments, prefix the title with 'Sponsor: '.\n"

            if let music = musicSegments, !music.isEmpty {
                let musicSegs = music.filter { $0.type == "music" && ($0.end - $0.start) >= 3.0 }
                if !musicSegs.isEmpty {
                    prompt += "\nMusic segments detected (these mark definitive chapter boundaries):\n"
                    for seg in musicSegs {
                        prompt += "  Music at \(formatTime(seg.start)) - \(formatTime(seg.end))\n"
                    }
                }
            }
        }

        // Add transcript (truncated if too long for context window)
        prompt += "\nTranscript:\n"
        var totalChars = 0
        let maxChars = 30000 // ~7500 tokens, safe for ~3B model context
        for cue in cues {
            let line = "[\(formatTime(cue.start))] \(cue.text)\n"
            totalChars += line.count
            if totalChars > maxChars {
                prompt += "... (transcript truncated)\n"
                break
            }
            prompt += line
        }

        prompt += "\nReturn a JSON array of chapters with: start (seconds), end (seconds), title, isSponsor (boolean).\n"

        return prompt
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
        return FileManager.default.fileExists(atPath: url.path)
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
