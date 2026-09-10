#!/usr/bin/env python3
"""Source-extracted SHA-256 runtime checks and publication/claim ownership guards."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
engine = (ROOT / "Classes/TranscriptionEngine.swift").read_text()
generator = (ROOT / "Classes/ChapterGenerator.swift").read_text()
playback = (ROOT / "Classes/PlaybackManager.m").read_text()

def method(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if not depth:
            return source[start:end + 1]
    raise AssertionError(signature)

helper = method(generator, "func verifyPlaybackAudio(")
helper += "\n" + method(generator, "@objc func cancelGeneratedAudioVerification()")
start = engine.find("enum ICAudioIdentity {")
assert start >= 0, "Missing verified audio-byte identity; episode URL cannot identify a dynamic ad variant"
brace = engine.index("{", start)
depth = 0
for end in range(brace, len(engine)):
    depth += (engine[end] == "{") - (engine[end] == "}")
    if not depth:
        identity = engine[start:end + 1]
        break
fixture = r'''
import Foundation
import CryptoKit
@MainActor final class ICDiagnosticLogger {
 static let shared = ICDiagnosticLogger()
 func logEvent(_ category: String, message: String, metadata: NSDictionary) {}
}
IDENTITY
enum ICTranscriptionPaths { static func analysisJSONURL(for hash:String)->URL { URL(fileURLWithPath:"/analysis") } }
@MainActor final class TranscriptionEngine {
 static let shared = TranscriptionEngine()
 var source: String?
 func transcriptSourceAudioSHA256(for episodeHash: String) -> String? { source }
 func transcriptSnapshotIdentifier(for episodeHash:String)->String? { source }
 static func artifactSnapshotIdentifier(at url:URL)->String? { "analysis" }
}
@MainActor final class ChapterGenerator: NSObject {
 var _analysisSnapshotCache: [String:String] = ["episode":"analysis"]
 var _analysisTranscriptSnapshotCache: [String:String] = [:]
 var _analysisAudioSHA256Cache: [String: String] = [:]
 var audioVerificationTask: Task<Void, Never>?
HELPER
}
@main struct Test {
 @MainActor static func main() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let audio = directory.appendingPathComponent("same-url.mp3")
  try Data("first audio representation".utf8).write(to: audio)
  let first = try await ICAudioIdentity.sha256(of: audio)
  let matching = try await ICAudioIdentity.sha256(of: audio)
  precondition(first == matching)
  try Data("other audio representation".utf8).write(to: audio)
  let changed = try await ICAudioIdentity.sha256(of: audio)
  precondition(first != changed, "same URL must not imply same audio")
  precondition(ICAudioIdentity.canResume(checkpointSHA256: first, sourceSHA256: changed) == false)
  precondition(ICAudioIdentity.canResume(checkpointSHA256: nil, sourceSHA256: first) == false)
  precondition(ICAudioIdentity.canResume(checkpointSHA256: first, sourceSHA256: matching))
  let generator = ChapterGenerator()
  generator._analysisAudioSHA256Cache["episode"] = changed
  TranscriptionEngine.shared.source = first
  generator._analysisTranscriptSnapshotCache["episode"] = first
  let analysisOnly = await withCheckedContinuation { continuation in
   generator.verifyPlaybackAudio(forEpisodeHash: "episode", audioURL: audio) { a, t in continuation.resume(returning: [a, t]) }
  }
  precondition(analysisOnly == [true, false], "Chapter identity cannot authorize a different transcript source")
  generator._analysisAudioSHA256Cache = [:]
  TranscriptionEngine.shared.source = changed
  let transcriptOnly = await withCheckedContinuation { continuation in
   generator.verifyPlaybackAudio(forEpisodeHash: "episode", audioURL: audio) { a, t in continuation.resume(returning: [a, t]) }
  }
  precondition(transcriptOnly == [false, true], "SRT-only playback must be independently verifiable")
  do { _ = try await ICAudioIdentity.sha256(of: URL(string: "https://example.invalid/audio.mp3")!); fatalError("streaming has no complete byte identity") } catch {}
  print("Audio byte identity runtime checks passed")
 }
}
'''.replace("IDENTITY", identity).replace("HELPER", helper)
assert "Task.detached(priority: .utility)" in identity, "Hashing must not run on the main actor"
assert "read(upToCount:" in identity and "Data(contentsOf:" not in identity, "Hash complete audio incrementally"
assert "ICAudioIdentity.canResume(checkpointSHA256:" in engine, "Checkpoint cues must be gated by actual source audio"
assert "sourceAudioSHA256: sourceAudioSHA256" in engine, "Final SRT must publish the captured source hash"
assert "try setTranscriptSourceAudioSHA256(sourceAudioSHA256, at: temporaryURL)" in engine, "Source identity must commit atomically with SRT"
assert "sourceAudioSHA256: TranscriptionEngine.shared.transcriptSourceAudioSHA256" in generator
assert "self.generatedChapterAudioVerified" in playback and "chapterLoadGeneration" in playback
with tempfile.TemporaryDirectory(prefix="instacast-audio-") as directory:
    path = Path(directory)
    (path / "main.swift").write_text(fixture)
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
