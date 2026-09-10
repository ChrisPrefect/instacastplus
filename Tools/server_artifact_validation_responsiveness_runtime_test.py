#!/usr/bin/env python3
"""Actual server validation on 4.3MB SRT must leave the MainActor heartbeat runnable."""
from pathlib import Path
import subprocess,tempfile
R=Path(__file__).resolve().parents[1]
s=(R/'Classes/ServerTranscriptionManager.swift').read_text();e=(R/'Classes/TranscriptionEngine.swift').read_text()
def declaration(source, signature):
 start=source.index(signature);brace=source.index('{',start);depth=0
 for end in range(brace,len(source)):
  depth+=(source[end]=='{')-(source[end]=='}')
  if not depth:return source[start:end+1]
types='\n'.join(declaration(s, x) for x in ['private struct ICServerChaptersArtifact:','private struct ICServerAdsArtifact:','private struct ICServerSummaryArtifact:'])
types+='\n'+declaration(e,'@objc class ICTranscriptCue:')
engine='\n'.join(declaration(e,x) for x in ['struct ICSRTRejection','private func parsePersistedSRTDetailed(','private func parsePersistedSRTTime(','private func isCanonicalServerSRTTimeLine(','func validateServerSRTData('])
# Include isolation modifiers when present; extraction signatures intentionally survive additive nonisolated.
for name in ['parsePersistedSRTDetailed','parsePersistedSRTTime','isCanonicalServerSRTTimeLine']:
 if 'nonisolated private func '+name in e: engine=engine.replace('private func '+name,'nonisolated private func '+name)
if 'nonisolated func validateServerSRTData' in e:engine=engine.replace('func validateServerSRTData','nonisolated func validateServerSRTData')
methods='\n'.join(declaration(s,x) for x in ['private func validateServerArtifacts(','private func validateServerTranscriptBounds(','private func sameMillisecond(','private func serverContractError('])
for name in ['validateServerArtifacts','validateServerTranscriptBounds','sameMillisecond','serverContractError']:
 if 'nonisolated private func '+name in s:methods=methods.replace('private func '+name,'nonisolated private func '+name)
if 'private func validateDownloadedArtifacts(' in s:
 helper=declaration(s,'private func validateDownloadedArtifacts(').replace('private func','func',1)
else:
 start=s.index('        let cues = try TranscriptionEngine.shared.validateServerSRTData(srtData, for: item.episodeHash)')
 end=s.index('        guard let episode = findEpisode',start)
 helper='''func validateDownloadedArtifacts(srtData:Data, chaptersData:Data, adsData:Data, summaryData:Data, episodeHash:String, transcriptRevision:String, serverDuration:Double?) async throws -> ([ICTranscriptCue], ICServerChaptersArtifact, ICServerAdsArtifact, ICServerSummaryArtifact) {\n'''+s[start:end].replace('item.episodeHash','episodeHash')+'\nreturn (cues, chaptersArtifact, adsArtifact, summaryArtifact)\n}'
if 'private func validateDownloadedArtifacts(' in s:
 region=s[s.index('let (cues, chaptersArtifact, adsArtifact, summaryArtifact) = try await validateDownloadedArtifacts'):s.index('private func buildServerAnalysis(')]
 assert region.index('try checkCurrentAttempt(item, requestID: requestID)') < region.index('guard let episode = findEpisode')
 tail=region[region.index('let analysis = try await buildServerAnalysis'):]
 assert tail.index('try checkCurrentAttempt(item, requestID: requestID)') < tail.index('saveValidatedServerSRTData')
fixture='''import Foundation
import CryptoKit
TYPES
final class ICDiagnosticLogger: @unchecked Sendable { static let shared=ICDiagnosticLogger();func logEvent(_ event:String,message:String,metadata:[String:String]){} }
@MainActor final class TranscriptionEngine { static let shared=TranscriptionEngine()
ENGINE
}
@MainActor private final class Validator {
METHODS
HELPER
}
@main struct Test {
 @MainActor static func main() async throws {
  func timestamp(_ second:Int)->String { String(format:"%02d:%02d:%02d,000",second/3600,(second/60)%60,second%60) }
  var text=""
  for i in 0..<43200 { text += "\\(i+1)\\n\\(timestamp(i*2)) --> \\(timestamp(i*2+2))\\n" + String(repeating:"s",count:62) + "\\n\\n" }
  let data=Data(text.utf8);let v=Validator();var mark:ContinuousClock.Instant?
  let chapterData=Data(#"{"schema_version":1,"transcript_revision":"revision","audio_duration_seconds":86400,"chapters":[{"start":0,"end":86400,"title":"Content","is_sponsor":false}]}"#.utf8)
  let adsData=Data(#"{"schema_version":1,"transcript_revision":"revision","audio_duration_seconds":86400,"segments":[]}"#.utf8)
  let summaryData=Data(#"{"schema_version":1,"transcript_revision":"revision","audio_duration_seconds":86400,"summary":"Synthetic","topic_titles":[]}"#.utf8)
  let heartbeat=Task { @MainActor in try? await Task.sleep(for:.milliseconds(20));mark = .now }
  await Task.yield();let start=ContinuousClock.now
  let result=try await v.validateDownloadedArtifacts(srtData:data,chaptersData:chapterData,adsData:adsData,summaryData:summaryData,episodeHash:"perf",transcriptRevision:"revision",serverDuration:86400)
  let end=ContinuousClock.now;await heartbeat.value
  print("bytes=\\(data.count) cues=\\(result.0.count) parser_elapsed=\\(start.duration(to:end)) heartbeat=\\(start.duration(to:mark!)) expected=20ms")
  precondition(start.duration(to:mark!) < .milliseconds(150), "Server validation blocked the MainActor heartbeat")
  let canceled = Task { try await v.validateDownloadedArtifacts(srtData:data,chaptersData:chapterData,adsData:adsData,summaryData:summaryData,episodeHash:"canceled",transcriptRevision:"revision",serverDuration:86400) }
  await Task.yield()
  canceled.cancel()
  do { _ = try await canceled.value; fatalError("Canceled parser returned a publishable value") } catch is CancellationError {}
 }
}
'''.replace('TYPES',types).replace('ENGINE',engine).replace('METHODS',methods).replace('HELPER',helper)
with tempfile.TemporaryDirectory(prefix='instacast-parser-responsive-') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-O','-swift-version','6','-parse-as-library',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
