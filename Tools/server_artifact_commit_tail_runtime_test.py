from pathlib import Path
import subprocess,tempfile
p=Path(__file__).resolve().parent/'server_analysis_responsiveness_runtime_test.py';source=p.read_text();ns={'__file__':str(p.resolve())};exec(source.split("fixture='''")[0],ns)
e=ns['e'];g=ns['s'];ex=ns['extract']
engine='\n'.join(ex(e,x) for x in ['private enum TranscriptOrigin:', '@objc nonisolated static func artifactSnapshotIdentifier(', 'func transcriptSnapshotIdentifier(', 'func persistedTranscriptCues(', 'func saveValidatedServerSRTData(', 'private func invalidateSRTCache(', 'private func replaceSRT(', 'private func setTranscriptOrigin(', 'private func setTranscriptSourceAudioSHA256(', 'func transcriptSourceAudioSHA256('])
generator=ns['methods']+'\n'+ex(g,'private func validateAnalysisTranscriptRevision(')+'\n'+ex(g,'@objc func saveAnalysisResult(')
fixture='''import Foundation
import CryptoKit
import Darwin
TYPES
final class ICDiagnosticLogger: @unchecked Sendable {
 static let shared=ICDiagnosticLogger()
 func logEvent(_ event:String,message:String,metadata:NSDictionary){}
 func logFileEvent(_ event:String,message:String,path:String,metadata:NSDictionary){}
 func logEpisodeArtifacts(episodeHash:String,reason:String){}
}
@MainActor enum ICTranscriptionPaths {
 static let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 static func srtURL(for hash:String)->URL { root.appendingPathComponent(hash+".srt") }
 static func analysisJSONURL(for hash:String)->URL { root.appendingPathComponent(hash+".json") }
 static func chaptersJSONURL(for hash:String)->URL { root.appendingPathComponent(hash+"_chapters.json") }
}
@MainActor final class TranscriptionEngine:NSObject {
 static let shared=TranscriptionEngine()
 static let transcriptOriginAttributeName="com.iteconomy.instacastplus.transcript-origin"
 static let transcriptAudioAttributeName="com.iteconomy.instacastplus.source-audio-sha256"
 var validatedServerTranscript:(episodeHash:String,snapshot:String,cues:[ICTranscriptCue])?
 var _srtCache:[String:Bool]=[:]
 func srtURL(for hash:String)->URL { ICTranscriptionPaths.srtURL(for:hash) }
 func parsePersistedSRT(_ text:String) throws -> [ICTranscriptCue] { fatalError("duplicate parser reached") }
ENGINE
}
@MainActor private final class ChapterGenerator:NSObject {
 static let shared=ChapterGenerator()
 var _chaptersCache:[String:Bool]=[:]
 var _loadedChaptersCache:[String:[ICGeneratedChapter]]=[:]
 var _summaryCache:[String:String]=[:]
 var _analysisAudioSHA256Cache:[String:String]=[:]
 var _analysisSnapshotCache:[String:String]=[:]
 var _analysisTranscriptSnapshotCache:[String:String]=[:]
 func invalidateAnalysisCache(for hash:String){}
GENERATOR
}
@MainActor private final class Manager { BUILD }
@main struct Test {
 @MainActor static func main() async throws {
  let cues=(0..<43200).map { ICTranscriptCue(start:Double($0*2),end:Double($0*2+2),text:String(repeating:"s",count:62)) }
  func timestamp(_ second:Int)->String { String(format:"%02d:%02d:%02d,000",second/3600,(second/60)%60,second%60) }
  let text=cues.enumerated().map { "\\($0.offset+1)\\n\\(timestamp(Int($0.element.start))) --> \\(timestamp(Int($0.element.end)))\\n\\($0.element.text)\\n\\n" }.joined()
  let data=Data(text.utf8)
  try FileManager.default.createDirectory(at:ICTranscriptionPaths.root,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:ICTranscriptionPaths.root) }
  let analysis=try await Manager().buildServerAnalysis([ICGeneratedChapter(start:0,end:86400,title:"Content",isSponsor:false)],sponsorSegments:[ICSponsorSegment(start:100,end:140,title:"Sponsor: Synthetic",evidenceCueIDs:[])],summary:"Synthetic",transcriptCues:cues)
  let start=ContinuousClock.now
  try TranscriptionEngine.shared.saveValidatedServerSRTData(data,cues:cues,for:"episode",sourceAudioSHA256:String(repeating:"a",count:64))
  let savedSRT=ContinuousClock.now
  try ChapterGenerator.shared.saveAnalysisResult(analysis,for:"episode")
  let end=ContinuousClock.now
  precondition(start.duration(to:end) < .milliseconds(100), "The synchronous publication tail blocks the UI")
  print("actualSaveSRTAndSnapshotCheck=\\(start.duration(to:savedSRT)); actualSaveAnalysisWithRevisionAndJSON=\\(savedSRT.duration(to:end)); synchronousCommitTail=\\(start.duration(to:end))")
 }
}
'''.replace('TYPES',ns['types']).replace('ENGINE',engine).replace('GENERATOR',generator).replace('BUILD',ns['build'])
with tempfile.TemporaryDirectory(prefix='instacast-commit-tail-') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['swiftc','-O','-swift-version','6','-parse-as-library',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
