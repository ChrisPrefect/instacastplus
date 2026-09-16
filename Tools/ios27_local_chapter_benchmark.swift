// Build as a macOS command-line tool or as the isolated iPhone benchmark app.
import Foundation
import FoundationModels
#if os(iOS)
import SwiftUI
#endif

struct ChapterBenchmarkInput: Decodable {
    let title: String
    let prompt: String
    let instructions: String
    let transcript_sha256: String
}

struct LocalChapterBenchmarkResult: Codable {
    var status: String
    var os: String = ProcessInfo.processInfo.operatingSystemVersionString
    var transcript_sha256: String
    var context_tokens: Int
    var input_tokens: Int?
    var maximum_response_tokens: Int = 1024
    var elapsed_seconds: Double?
    var response: String?
    var error: String?
}

enum LocalChapterBenchmark {
    static func run(inputURL: URL, outputURL: URL) async throws -> String {
        let input = try JSONDecoder().decode(ChapterBenchmarkInput.self, from: Data(contentsOf: inputURL))
        let model = SystemLanguageModel.default
        var result = LocalChapterBenchmarkResult(status: String(describing: model.availability),
                                                 transcript_sha256: input.transcript_sha256,
                                                 context_tokens: model.contextSize)
        func save(_ result: LocalChapterBenchmarkResult) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(result)
            try data.write(to: outputURL, options: .atomic)
            return String(decoding: data, as: UTF8.self)
        }
        guard model.availability == .available else { return try save(result) }
        do {
            let session = LanguageModelSession(model: model, instructions: input.instructions)
            let entries = Array(session.transcript) + [Transcript.Entry.prompt(.init(
                segments: [.text(.init(content: input.prompt))]))]
            let tokens = try await model.tokenCount(for: entries)
            result.input_tokens = tokens
            guard tokens + result.maximum_response_tokens <= model.contextSize else {
                result.status = "input_exceeds_context"
                return try save(result)
            }
            result.status = "generating"
            _ = try save(result)
            let start = ProcessInfo.processInfo.systemUptime
            let response = try await session.respond(to: input.prompt, options: GenerationOptions(
                temperature: 0.6, maximumResponseTokens: result.maximum_response_tokens))
            result.elapsed_seconds = ProcessInfo.processInfo.systemUptime - start
            result.response = response.content
            // Retain malformed output for evaluation; never repair or silently discard it.
            _ = try JSONSerialization.jsonObject(with: Data(response.content.utf8))
            result.status = "completed"
        } catch {
            result.status = "failed"
            result.error = String(describing: error)
        }
        return try save(result)
    }
}

#if os(iOS)
@main
struct ChapterBenchmarkApp: App {
    @State private var result = "Lokales Apple-Modell wird geprüft …"
    var body: some Scene {
        WindowGroup {
            ScrollView { Text(result).font(.system(.footnote, design: .monospaced)).padding() }
                .task {
                    do {
                        result = try await LocalChapterBenchmark.run(
                            inputURL: Bundle.main.url(forResource: "input", withExtension: "json")!,
                            outputURL: URL.documentsDirectory.appendingPathComponent("local.json"))
                    } catch { result = String(describing: error) }
                }
        }
    }
}
#else
@main
struct ChapterBenchmarkCLI {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            print("usage: benchmark INPUT.json OUTPUT.json")
            exit(2)
        }
        print(try await LocalChapterBenchmark.run(
            inputURL: URL(fileURLWithPath: CommandLine.arguments[1]),
            outputURL: URL(fileURLWithPath: CommandLine.arguments[2])))
    }
}
#endif
