#!/usr/bin/env python3
"""Execute production local-chapter persistence and audio proof against real files.

Failure matrix / isolation rationale: transcription-server/2026-10-03-reliability-audit/local-chapter-identity.md
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
generator = (ROOT / 'Classes/ChapterGenerator.swift').read_text()
engine = (ROOT / 'Classes/TranscriptionEngine.swift').read_text()

def extract(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if not depth:
            return source[start:end + 1]
    raise AssertionError(signature)

types = '\n'.join(extract(generator, signature) for signature in [
    '@objc class ICGeneratedChapter:', 'private struct ChaptersFile:', 'private struct AnalysisFile:'
]) + '\n' + extract(engine, '@objc class ICTranscriptCue:')
engine_methods = '\n'.join(extract(engine, signature) for signature in [
    '@objc nonisolated static func artifactSnapshotIdentifier(', 'func transcriptSnapshotIdentifier(',
    'func transcriptSourceAudioSHA256(', 'func persistedTranscriptCues(',
    'private func parsePersistedSRT(', 'nonisolated private func parsePersistedSRTDetailed(',
    'nonisolated private func isCanonicalServerSRTTimeLine(', 'nonisolated private func parsePersistedSRTTime(',
    'struct ICSRTRejection {'
])
methods = '\n'.join(extract(generator, signature) for signature in [
    'func saveChaptersThrowing(', '@objc func loadChapters(',
    'private static func validatePersistedChapterIntervals(', 'func verifyPlaybackAudio(',
    '@objc func cancelGeneratedAudioVerification()', '@objc func invalidateChaptersCache(',
    'private func validateAnalysisTranscriptRevision(', '@objc nonisolated func transcriptRevision(',
    'nonisolated private static func makeTranscriptRevision(', 'nonisolated private static func appendUInt64('
])
# Keep the same behavioral probe executable against the pre-fix API too.
for signature in ['private func validateChapterTranscriptRevision(', '@objc func chapterArtifactSnapshotIdentifier(']:
    if signature in generator:
        methods += '\n' + extract(generator, signature)
if 'transcriptSnapshot: String' in extract(generator, 'func saveChaptersThrowing('):
    save = 'try generator.saveChaptersThrowing(chapters, for: hash, transcriptRevision: revision, transcriptSnapshot: snapshot, sourceAudioSHA256: source)'
else:
    save = 'try generator.saveChaptersThrowing(chapters, for: hash)'
fixture = r'''
import Foundation
import CryptoKit
import Darwin
TYPES
IDENTITY
final class ICDiagnosticLogger: @unchecked Sendable {
 static let shared=ICDiagnosticLogger()
 func logEvent(_ event:String,message:String,metadata:NSDictionary){}
 func logFileEvent(_ event:String,message:String,path:String,metadata:NSDictionary){}
 func logEpisodeArtifacts(episodeHash:String,reason:String){}
}
@MainActor enum ICTranscriptionPaths {
 static var root=URL(fileURLWithPath:CommandLine.arguments[1])
 static func srtURL(for hash:String)->URL {root.appendingPathComponent(hash+".srt")}
 static func chaptersJSONURL(for hash:String)->URL {root.appendingPathComponent(hash+"_chapters.json")}
 static func analysisJSONURL(for hash:String)->URL {root.appendingPathComponent(hash+"_analysis.json")}
}
@MainActor final class TranscriptionEngine:NSObject {
 static let shared=TranscriptionEngine()
 static let transcriptAudioAttributeName="com.iteconomy.instacastplus.source-audio-sha256"
 var validatedServerTranscript:(episodeHash:String,snapshot:String,cues:[ICTranscriptCue])?
 func srtURL(for hash:String)->URL {ICTranscriptionPaths.srtURL(for:hash)}
 ENGINE
}
@MainActor private final class ChapterGenerator:NSObject {
 var _chaptersCache:[String:Bool]=[:]
 var _loadedChaptersCache:[String:[ICGeneratedChapter]]=[:]
 var _summaryCache:[String:String]=[:]
 var _analysisAudioSHA256Cache:[String:String]=[:]
 var _analysisTranscriptSnapshotCache:[String:String]=[:]
 var _analysisSnapshotCache:[String:String]=[:]
 var audioVerificationTask:Task<Void,Never>?
 METHODS
}
@main struct Test {
 @MainActor static func main() async throws {
  let engine=TranscriptionEngine.shared, root=ICTranscriptionPaths.root
  let audio=root.appendingPathComponent("audio.bin"), other=root.appendingPathComponent("other.bin")
  try Data("original complete audio".utf8).write(to:audio)
  try Data("different complete audio".utf8).write(to:other)
  let source=try await ICAudioIdentity.sha256(of:audio), changedSource=try await ICAudioIdentity.sha256(of:other)
  let hash="local"
  var failures=0
  func expect(_ condition:Bool,_ label:String) {print("\(condition ? "PASS" : "FAIL") \(label)");if !condition {failures+=1}}
  func transcript(_ text:String="original text", source:String?) throws {
   let url=ICTranscriptionPaths.srtURL(for:hash)
   try Data("1\n00:00:00,000 --> 00:00:10,000\n\(text)\n\n".utf8).write(to:url,options:.atomic)
   if let source {
    let rc=Array(source.utf8).withUnsafeBytes {setxattr(url.path,TranscriptionEngine.transcriptAudioAttributeName,$0.baseAddress,$0.count,0,0)}
    precondition(rc==0)
   }
  }
  func capture(_ generator:ChapterGenerator) throws -> (String,String,String?) {
   (generator.transcriptRevision(for:try engine.persistedTranscriptCues(for:hash)!),engine.transcriptSnapshotIdentifier(for:hash)!,engine.transcriptSourceAudioSHA256(for:hash))
  }
  func save(_ generator:ChapterGenerator,_ identity:(String,String,String?)) throws {
   let (revision,snapshot,source)=identity
   let chapters=[ICGeneratedChapter(start:0,end:10,title:"Locally generated",isSponsor:false)]
   SAVE
  }
  func proof(_ generator:ChapterGenerator,_ file:URL) async -> [Bool] {
   await withCheckedContinuation { continuation in
    generator.verifyPlaybackAudio(forEpisodeHash:hash,audioURL:file) {a,t in continuation.resume(returning:[a,t])}
   }
  }
  try transcript(source:source)
  let writer=ChapterGenerator(); let identity=try capture(writer)
  try save(writer,identity)
  for (label,reader) in [("same session",writer),("fresh generator / relaunch",ChapterGenerator())] {
   expect(reader.loadChapters(for:hash)?.count==1,"local chapters load in \(label)")
   expect(await proof(reader,audio)==[true,true],"matching complete source verifies chapters and transcript in \(label)")
   expect(await proof(reader,other)==[false,false],"different audio is rejected in \(label)")
  }
  let cold=ChapterGenerator();_ = cold.loadChapters(for:hash)
  let originalBytes=try Data(contentsOf:audio)
  try Data(contentsOf:other).write(to:audio,options:.atomic)
  expect(await proof(cold,audio)==[false,false],"different bytes at the same URL are rejected")
  try originalBytes.write(to:audio,options:.atomic)
  try transcript("new transcript text",source:source)
  expect(cold.loadChapters(for:hash)==nil,"replacement transcript invalidates cached local chapters")
  expect(ChapterGenerator().loadChapters(for:hash)==nil,"replacement transcript invalidates persisted local chapters after restart")
  try transcript(source:changedSource)
  expect(ChapterGenerator().loadChapters(for:hash)==nil,"identical cue text with different source cannot inherit chapter identity")
  let prior=try Data(contentsOf:ICTranscriptionPaths.chaptersJSONURL(for:hash))
  do {try save(writer,identity);expect(false,"generation result with replaced SRT snapshot rejected")} catch {expect(true,"generation result with replaced SRT snapshot rejected")}
  expect(try Data(contentsOf:ICTranscriptionPaths.chaptersJSONURL(for:hash))==prior,"rejected commit preserves prior artifact")
  try transcript(source:source)
  let beforeDelete=try capture(writer)
  try FileManager.default.removeItem(at:ICTranscriptionPaths.srtURL(for:hash))
  do {try save(writer,beforeDelete);expect(false,"SRT deletion before commit rejected")} catch {expect(true,"SRT deletion before commit rejected")}
  try transcript(source:source)
  try save(writer,try capture(writer))
  try FileManager.default.removeItem(at:ICTranscriptionPaths.srtURL(for:hash))
  let retained=ChapterGenerator();_ = retained.loadChapters(for:hash)
  expect(await proof(retained,audio)==[true,false],"deliberately retained chapters keep original proof after only SRT is deleted")
  try transcript(source:source)
  let legacy=Data(#"{"chapters":[{"start":0,"end":10,"title":"Old unbound chapters","isSponsor":false}]}"#.utf8)
  try legacy.write(to:ICTranscriptionPaths.chaptersJSONURL(for:hash),options:.atomic)
  let legacyReader=ChapterGenerator();_ = legacyReader.loadChapters(for:hash)
  expect(await proof(legacyReader,audio)==[false,true],"legacy chapters never gain current audio identity")
  exit(failures==0 ? 0 : 1)
 }
}
'''.replace('TYPES', types).replace('IDENTITY', extract(engine, 'enum ICAudioIdentity {')).replace('ENGINE', engine_methods).replace('METHODS', methods).replace('SAVE', save)
with tempfile.TemporaryDirectory(prefix='instacast-local-chapter-identity-') as directory:
    path=Path(directory)
    (path/'main.swift').write_text(fixture)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(path/'main.swift'),'-o',str(path/'probe')],check=True)
    raise SystemExit(subprocess.run([str(path/'probe'), directory]).returncode)
