import Foundation
import FoundationModels

@available(iOS 26, *)
@Generable
struct GeneratedChapterStartsList {
    @Guide(description: "Chronologische Liste der Podcast-Kapitelstarts.")
    let chapters: [GeneratedChapterStart]
}

@available(iOS 26, *)
@Generable
struct GeneratedChapterStart {
    @Guide(description: "Startzeit des Kapitels in Sekunden ab Podcast-Anfang.")
    let startSeconds: Int

    @Guide(description: "Konkreter, fuer Hoerer nuetzlicher Kapitel-Titel in der Sprache des Podcasts.")
    let title: String

    @Guide(description: "true, wenn dieses Kapitel skip-wuerdige Promotion, Sponsoring, Eigenpromo, Abo, Shop, Spendenaufruf, Bewertungsaufruf oder Cross-Promotion ist.")
    let isSponsor: Bool
}

struct Cue {
    let start: Double
    let end: Double
    let text: String
}

struct GeneratedStart: Codable {
    let startSeconds: Int
    let title: String
    let isSponsor: Bool
}

struct Chapter: Codable {
    let startSeconds: Int
    let endSeconds: Int
    let title: String
    let isSponsor: Bool
}

struct BenchResult: Codable {
    let srt: String
    let durationSeconds: Double
    let cueCount: Int
    let promptCharacters: Int
    let estimatedPromptTokens: Int
    let contextTokens: Int
    let maxInputTokens: Int
    let elapsedSeconds: Double?
    let parseError: String?
    let chapterCount: Int
    let sponsorCount: Int
    let issues: [String]
    let generatedStarts: [GeneratedStart]
    let chapters: [Chapter]
}

struct Summary: Codable {
    let modelName: String
    let availability: String
    let contextTokens: Int
    let maxInputTokens: Int
    var results: [BenchResult]
}

@available(iOS 26, *)
@main
struct AppleAIChapterBenchmark {
    static let modelName = "apple-foundation-models-direct-fullctx"
    static let targetInputContextRatio = 0.85

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            fputs("usage: apple_ai_chapter_benchmark <out-dir> <srt> [<srt> ...]\n", stderr)
            Foundation.exit(2)
        }

        let outRoot = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
        let outputDir = outRoot.appendingPathComponent(modelName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            fputs("failed to create output directory: \(error)\n", stderr)
            Foundation.exit(1)
        }

        let model = SystemLanguageModel.default
        let contextSize = model.contextSize
        let maxInputTokens = max(1, Int(Double(contextSize) * targetInputContextRatio))
        var summary = Summary(modelName: modelName,
                              availability: String(describing: model.availability),
                              contextTokens: contextSize,
                              maxInputTokens: maxInputTokens,
                              results: [])

        for srt in args {
            writeLine("RUN \(modelName) \(URL(fileURLWithPath: srt).lastPathComponent)")
            let result = await run(srtPath: srt,
                                   outputDir: outputDir,
                                   model: model,
                                   contextSize: contextSize,
                                   maxInputTokens: maxInputTokens)
            summary.results.append(result)
            printJSON(result)
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(summary)
            try data.write(to: outputDir.appendingPathComponent("summary.json"))
        } catch {
            fputs("failed to write summary: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func run(srtPath: String,
                    outputDir: URL,
                    model: SystemLanguageModel,
                    contextSize: Int,
                    maxInputTokens: Int) async -> BenchResult {
        let url = URL(fileURLWithPath: srtPath)
        let cues: [Cue]
        do {
            cues = try parseSRT(url)
        } catch {
            return BenchResult(srt: srtPath,
                               durationSeconds: 0,
                               cueCount: 0,
                               promptCharacters: 0,
                               estimatedPromptTokens: 0,
                               contextTokens: contextSize,
                               maxInputTokens: maxInputTokens,
                               elapsedSeconds: nil,
                               parseError: "SRT parse failed: \(error)",
                               chapterCount: 0,
                               sponsorCount: 0,
                               issues: ["SRT parse failed"],
                               generatedStarts: [],
                               chapters: [])
        }

        let duration = cues.last?.end ?? 0
        let prompt = buildPrompt(cues: cues)
        let estimatedPromptTokens = max(prompt.count / 2, 1)
        let stem = url.deletingPathExtension().lastPathComponent
        try? prompt.write(to: outputDir.appendingPathComponent("\(stem).prompt.txt"),
                          atomically: true,
                          encoding: .utf8)

        guard String(describing: model.availability) == "available" else {
            let result = BenchResult(srt: srtPath,
                                     durationSeconds: duration,
                                     cueCount: cues.count,
                                     promptCharacters: prompt.count,
                                     estimatedPromptTokens: estimatedPromptTokens,
                                     contextTokens: contextSize,
                                     maxInputTokens: maxInputTokens,
                                     elapsedSeconds: nil,
                                     parseError: "Apple Foundation Models unavailable: \(model.availability)",
                                     chapterCount: 0,
                                     sponsorCount: 0,
                                     issues: ["model unavailable"],
                                     generatedStarts: [],
                                     chapters: [])
            writeResult(result, to: outputDir, stem: stem)
            return result
        }

        guard estimatedPromptTokens <= maxInputTokens else {
            let result = BenchResult(srt: srtPath,
                                     durationSeconds: duration,
                                     cueCount: cues.count,
                                     promptCharacters: prompt.count,
                                     estimatedPromptTokens: estimatedPromptTokens,
                                     contextTokens: contextSize,
                                     maxInputTokens: maxInputTokens,
                                     elapsedSeconds: nil,
                                     parseError: "context overflow: estimated \(estimatedPromptTokens) input tokens > \(maxInputTokens)",
                                     chapterCount: 0,
                                     sponsorCount: 0,
                                     issues: ["context overflow"],
                                     generatedStarts: [],
                                     chapters: [])
            writeResult(result, to: outputDir, stem: stem)
            return result
        }

        let started = DispatchTime.now()
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: GeneratedChapterStartsList.self)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
            let generated = response.content.chapters.map {
                GeneratedStart(startSeconds: $0.startSeconds,
                               title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               isSponsor: $0.isSponsor)
            }
            let chapters = chaptersFromStarts(generated, duration: duration)
            let result = BenchResult(srt: srtPath,
                                     durationSeconds: duration,
                                     cueCount: cues.count,
                                     promptCharacters: prompt.count,
                                     estimatedPromptTokens: estimatedPromptTokens,
                                     contextTokens: contextSize,
                                     maxInputTokens: maxInputTokens,
                                     elapsedSeconds: elapsed,
                                     parseError: nil,
                                     chapterCount: chapters.count,
                                     sponsorCount: chapters.filter { $0.isSponsor }.count,
                                     issues: validate(chapters: chapters, duration: duration),
                                     generatedStarts: generated,
                                     chapters: chapters)
            writeResult(result, to: outputDir, stem: stem)
            return result
        } catch {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
            let result = BenchResult(srt: srtPath,
                                     durationSeconds: duration,
                                     cueCount: cues.count,
                                     promptCharacters: prompt.count,
                                     estimatedPromptTokens: estimatedPromptTokens,
                                     contextTokens: contextSize,
                                     maxInputTokens: maxInputTokens,
                                     elapsedSeconds: elapsed,
                                     parseError: "\(error)",
                                     chapterCount: 0,
                                     sponsorCount: 0,
                                     issues: ["generation failed"],
                                     generatedStarts: [],
                                     chapters: [])
            writeResult(result, to: outputDir, stem: stem)
            return result
        }
    }

    static func parseSRT(_ url: URL) throws -> [Cue] {
        let raw = try String(contentsOf: url, encoding: .utf8)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let parts = lines[timeIndex].components(separatedBy: "-->").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1]) else {
                continue
            }
            let text = lines.dropFirst(timeIndex + 1)
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                cues.append(Cue(start: start, end: end, text: text))
            }
        }
        return cues
    }

    static func parseTime(_ value: String) -> Double? {
        let parts = value.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        let secondsParts = parts[2].components(separatedBy: ",")
        guard secondsParts.count == 2,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(secondsParts[0]),
              let milliseconds = Double(secondsParts[1]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds + milliseconds / 1000
    }

    static func buildPrompt(cues: [Cue]) -> String {
        let duration = cues.last?.end ?? 0
        var prompt = "Erstelle die finale Kapitel-Liste aus dem vollstaendigen Podcast-Transkript.\n"
        prompt += "Gesamtdauer: \(Int(duration)) Sekunden.\n\n"
        prompt += "Regeln:\n"
        prompt += "- Nutze das gesamte Transkript als Kontext; erfinde keine Inhalte.\n"
        prompt += "- Ein Kapitel darf sehr lang sein, auch 40 Minuten oder laenger, wenn der Inhalt wirklich ein zusammenhaengender Themenblock ist.\n"
        prompt += "- Unterteile nicht nach Dauer, sondern nur bei echten, fuer Hoerer nuetzlichen Themen-, Segment- oder Skip-Wechseln.\n"
        prompt += "- Erzeuge keine eigenen Kapitelstarts fuer kurze Begruessungen, Meta-Einleitungen, Ueberleitungen, Fuellsaetze oder einzelne Service-Details, wenn sie zum selben Nutzenthema gehoeren.\n"
        prompt += "- Ein einzelnes Kapitel ueber fast die ganze Folge ist nur erlaubt, wenn das Transkript wirklich keinen eigenen Nutzensprung, keine neue Hauptfrage, kein Fazit und kein skip-wuerdiges Segment enthaelt.\n"
        prompt += "- Wenn ein Gespraech mehrere Hauptfragen, Argumente, Methoden, Studien, konkrete Beispiele, Empfehlungen oder ein Schlusssegment behandelt, muessen die Kapitelstarts diese Wechsel sichtbar machen.\n"
        prompt += sponsorRule()
        prompt += "- Wenn redaktioneller Inhalt in Promotion, Eigenpromo oder einen Call-to-Action uebergeht, beginne dort ein eigenes Sponsor-Kapitel; mische redaktionellen Inhalt und Promotion nicht im selben Kapitel.\n"
        prompt += "- Titel in der Sprache des Transkripts.\n"
        prompt += "- Titel muessen fuer Hoerer bei der Kapitelauswahl nuetzlich sein: konkrete Sache, Person, Ort, Frage, Messwert, Methode oder zentrale These nennen.\n"
        prompt += "- Keine reinen Kategorie-, Schlagwort- oder Oberbegriff-Titel; der Titel muss erkennen lassen, welche konkrete Frage, Behauptung, Ursache, Folge oder Entscheidung im Abschnitt behandelt wird.\n"
        prompt += "- Beschreibe nicht den Sprechakt wie Begruessung, Einleitung, Ankuendigung, Ueberblick oder Diskussion, wenn der Abschnitt konkrete Inhalte nennt; benenne dann die angekuendigte Sache selbst.\n"
        prompt += "- Keine vagen Meta-Titel und keine einzelnen Satzfragmente.\n"
        prompt += "- startSeconds als Sekunden ab Podcast-Anfang (Ganzzahl).\n"
        prompt += "- Das erste Kapitel beginnt bei 0; das letzte Kapitel endet automatisch bei der Gesamtdauer \(Int(duration)).\n"
        prompt += "- Gib nur Kapitelstarts aus; Endzeiten werden deterministisch aus dem naechsten startSeconds berechnet.\n\n"
        prompt += "Transkript (0s-\(formatSecond(duration))):\n"
        for cue in cues {
            prompt += "[\(formatSecond(cue.start))] \(cue.text)\n"
        }
        return prompt
    }

    static func sponsorRule() -> String {
        "- Behandle isSponsor als skip-wuerdige Promotion, nicht nur als externe Werbung: Sponsoring, Eigenpromo, bezahlte Angebote, Mitgliedschaften/Abos, Shops/Merch, Spenden/Support, Bewertungs-/Follow-Aufrufe, Cross-Promotion sowie kommerzielle oder monetaere Calls-to-Action fuer eigene Produkte, Events oder Services. Wenn ein Abschnitt hauptsaechlich dazu auffordert, ausserhalb des redaktionellen Inhalts etwas zu kaufen, zu abonnieren, zu unterstuetzen, zu bewerten/folgen, ein Event zu besuchen, einen Shop/Link zu nutzen oder ein anderes Angebot zu konsumieren, ist er Promotion. Bezahlter oder limitierter Zugang zu einem eigenen Angebot, ein Link in Shownotes zu diesem Angebot oder die Aufforderung, ein eigenes Event, Produkt, Abo, Netzwerk oder anderes Format zu nutzen, ist Promotion auch dann, wenn es informativ formuliert ist. Kapitel, die nur Details eines eigenen Angebots, Events, Produkts, Abos oder anderen eigenen Formats liefern, sind ebenfalls Promotion, auch wenn der konkrete Kauf- oder Nutzungsaufruf erst in einem benachbarten Kapitel steht. Neutrale Erwaehnungen von Plattformen, Tools, Apps, Diensten oder Anbietern sind keine Promotion, wenn sie nur erklaert werden und nicht dazu auffordern, sie zu kaufen, zu abonnieren, zu unterstuetzen oder zu nutzen. Behandle eigene Angebote, eigene Events und andere eigene Podcasts genauso als Promotion; sie sind nicht redaktionell, nur weil sie vom Podcast selbst stammen. Erkenne das semantisch in jeder Sprache; Titel dafuer 'Sponsor: ...' und isSponsor true, auch wenn der Promo-Abschnitt am Anfang, Ende oder ueber fast die ganze kurze Folge laeuft. isSponsor false ist nur fuer redaktionellen Inhalt ohne solches Call-to-Action-Ziel erlaubt.\n"
    }

    static func formatSecond(_ seconds: Double) -> String {
        "\(Int(seconds.rounded()))s"
    }

    static func chaptersFromStarts(_ starts: [GeneratedStart], duration: Double) -> [Chapter] {
        starts.enumerated().map { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].startSeconds : Int(duration)
            return Chapter(startSeconds: start.startSeconds,
                           endSeconds: end,
                           title: start.title,
                           isSponsor: start.isSponsor)
        }
    }

    static func validate(chapters: [Chapter], duration: Double) -> [String] {
        var issues: [String] = []
        if chapters.isEmpty {
            return ["no chapters"]
        }
        let tolerance = max(2.0, min(6.0, duration * 0.0025))
        if abs(Double(chapters[0].startSeconds)) > tolerance {
            issues.append("first chapter does not start at 0")
        }
        if abs(Double(chapters.last?.endSeconds ?? 0) - Double(Int(duration))) > tolerance {
            issues.append("last chapter does not end at duration")
        }
        if chapters.contains(where: { $0.endSeconds <= $0.startSeconds }) {
            issues.append("non-positive chapter duration")
        }
        if chapters.contains(where: { $0.title.split(separator: " ").count > 14 }) {
            issues.append("verbose title")
        }
        if chapters.count == 1 && duration >= 600 {
            issues.append("single full-episode chapter")
        }
        return issues
    }

    static func writeResult(_ result: BenchResult, to outputDir: URL, stem: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(result)
            try data.write(to: outputDir.appendingPathComponent("\(stem).result.json"))
        } catch {
            fputs("failed to write result for \(stem): \(error)\n", stderr)
        }
    }

    static func printJSON<T: Encodable>(_ value: T) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            if let text = String(data: data, encoding: .utf8) {
                writeLine(text)
            }
        } catch {
            fputs("failed to encode JSON: \(error)\n", stderr)
        }
    }

    static func writeLine(_ text: String) {
        if let data = "\(text)\n".data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }
}
