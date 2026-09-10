from pathlib import Path
import tempfile,subprocess
R=Path(__file__).resolve().parents[1]
s=(R/'Classes/ChapterGenerator.swift').read_text();e=(R/'Classes/TranscriptionEngine.swift').read_text();manager=(R/'Classes/ServerTranscriptionManager.swift').read_text()
def extract(src,sig):
 if sig not in src: sig=sig.replace('@objc func','@objc nonisolated func')
 a=src.index(sig);b=src.index('{',a);d=0
 for z in range(b,len(src)):
  d+=(src[z]=='{')-(src[z]=='}')
  if not d:return src[a:z+1]
types='\n'.join(extract(s,x) for x in ['@objc class ICGeneratedChapter:', '@objc class ICSponsorSegment:', '@objc class EpisodeAnalysisResult:','private struct AnalysisFile:'])+'\n'+extract(e,'@objc class ICTranscriptCue:')
names=['@objc func evidenceCueIDs(', '@objc func transcriptRevision(', '@objc func validateSponsorSegments(', '@objc func makeAnalysisResult(', 'func makeServerAnalysis(', 'private static func sameCanonicalMillisecond(', 'private static func makeTranscriptRevision(', 'private static func appendUInt64(', 'private static func sponsorValidationError(', 'private static func isValidSponsorChapterTitle(', '@objc func chaptersByOverlayingSponsors(', 'private static func coalescedSponsorOverlayChapters(', 'private static func mergedSponsorIntervals(']
methods='\n'.join(extract(s,x) for x in names)
for n in ['sameCanonicalMillisecond','makeTranscriptRevision','appendUInt64','sponsorValidationError','isValidSponsorChapterTitle','coalescedSponsorOverlayChapters','mergedSponsorIntervals']:
 if 'nonisolated private static func '+n in s: methods=methods.replace('private static func '+n,'nonisolated private static func '+n)
if 'nonisolated func makeServerAnalysis' in s: methods=methods.replace('func makeServerAnalysis','nonisolated func makeServerAnalysis')
if 'private func buildServerAnalysis(' in manager:
 build=extract(manager,'private func buildServerAnalysis(').replace('private func','func',1)
else:
 build='''func buildServerAnalysis(_ chapters:[ICGeneratedChapter], sponsorSegments:[ICSponsorSegment], summary:String, transcriptCues:[ICTranscriptCue]) async throws -> EpisodeAnalysisResult { try ChapterGenerator.shared.makeServerAnalysis(chapters,sponsorSegments:sponsorSegments,summary:summary,transcriptCues:transcriptCues) }'''
# Persistence serializes precisely this real value and performs one canonical revision check.
a=s.index('        let file = AnalysisFile(',s.index('@objc func saveAnalysisResult('));b=s.index('        try validateAnalysisTranscriptRevision',a)
serialize=s[a:b].replace('TranscriptionEngine.shared.transcriptSourceAudioSHA256(for: episodeHash)','String(repeating:"a",count:64)')+'\n        let data = try JSONEncoder().encode(file)\n        return data\n'
fixture='''import Foundation
import CryptoKit
TYPES
final class ICDiagnosticLogger: @unchecked Sendable { static let shared=ICDiagnosticLogger();func logEvent(_ event:String,message:String,metadata:NSDictionary){} }
@MainActor private final class ChapterGenerator:NSObject {
static let shared=ChapterGenerator()
METHODS
func serialize(_ result:EpisodeAnalysisResult) throws->Data { let summary=result.summary
SERIALIZE
}
}
@MainActor private final class Manager { BUILD }
@main struct Test {
 @MainActor static func main() async throws {
  let cues=(0..<43200).map { ICTranscriptCue(start:Double($0*2),end:Double($0*2+2),text:String(repeating:"s",count:62)) }
  let g=ChapterGenerator.shared, clock=ContinuousClock();var mark:ContinuousClock.Instant?
  let heartbeat=Task { @MainActor in try? await Task.sleep(for:.milliseconds(1));mark = .now }
  await Task.yield();let begin=clock.now
  let analysis=try await Manager().buildServerAnalysis([ICGeneratedChapter(start:0,end:86400,title:"Content",isSponsor:false)],sponsorSegments:[ICSponsorSegment(start:100,end:140,title:"Sponsor: Synthetic",evidenceCueIDs:[])],summary:"Synthetic",transcriptCues:cues)
  let made=clock.now
  await heartbeat.value
  precondition(g.transcriptRevision(for:cues)==analysis.transcriptRevision)
  let checked=clock.now
  let data=try g.serialize(analysis)
  let serialized=clock.now
  let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try data.write(to:url,options:.atomic);try FileManager.default.removeItem(at:url)
  let message="analysis=\\(begin.duration(to:made)); heartbeat=\\(begin.duration(to:mark!)); revisionCheck=\\(made.duration(to:checked)); JSON=\\(checked.duration(to:serialized))\\n"
  try FileHandle.standardError.write(contentsOf:Data(message.utf8))
  precondition(begin.duration(to:mark!) < .milliseconds(16), "Analysis preparation blocked the MainActor")
 }
}
'''.replace('TYPES',types).replace('METHODS',methods).replace('SERIALIZE',serialize).replace('BUILD',build)
with tempfile.TemporaryDirectory(prefix='instacast-analysis-tail-') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['swiftc','-O','-swift-version','6','-parse-as-library',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
