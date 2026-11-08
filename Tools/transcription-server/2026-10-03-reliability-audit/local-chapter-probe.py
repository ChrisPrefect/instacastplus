from pathlib import Path
import subprocess
root=Path('/Users/prefect/Developer/instacastplus')
g=(root/'Classes/ChapterGenerator.swift').read_text(); e=(root/'Classes/TranscriptionEngine.swift').read_text()
def extract(s,sig):
 a=s.index(sig); b=s.index('{',a); depth=0
 for i in range(b,len(s)):
  depth+=(s[i]=='{')-(s[i]=='}')
  if not depth:return s[a:i+1]
types='\n'.join(extract(g,s) for s in ['@objc class ICGeneratedChapter:','private struct ChaptersFile:','private struct AnalysisFile:'])
methods='\n'.join(extract(g,s) for s in ['func saveChaptersThrowing(', '@objc func loadChapters(', 'private static func validatePersistedChapterIntervals(', 'func verifyPlaybackAudio(', '@objc func cancelGeneratedAudioVerification()', '@objc func invalidateChaptersCache('])
identity=extract(e,'enum ICAudioIdentity {')
snapshot=extract(e,'@objc nonisolated static func artifactSnapshotIdentifier(')
# Read-only investigation. Concrete failures: local chapter saves lack identity;
# cold loading must retain identity; matched complete audio must enable only its
# timeline. Normal E2E currently uses server AnalysisFile exclusively, so a
# native production persistence/proof probe isolates the untested local format.
fixture=r'''import Foundation
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
 static let root=URL(fileURLWithPath:"/tmp/instacast-local-chapter-proof-files")
 static func chaptersJSONURL(for hash:String)->URL {root.appendingPathComponent(hash+"_chapters.json")}
 static func analysisJSONURL(for hash:String)->URL {root.appendingPathComponent(hash+"_analysis.json")}
}
@MainActor final class TranscriptionEngine:NSObject {
 static let shared=TranscriptionEngine(); var source:String?
 func transcriptSourceAudioSHA256(for hash:String)->String? {source}
 func transcriptSnapshotIdentifier(for hash:String)->String? {"same-unchanged-srt"}
 SNAPSHOT
}
@MainActor private final class ChapterGenerator:NSObject {
 var _chaptersCache:[String:Bool]=[:]
 var _loadedChaptersCache:[String:[ICGeneratedChapter]]=[:]
 var _summaryCache:[String:String]=[:]
 var _analysisAudioSHA256Cache:[String:String]=[:]
 var _analysisTranscriptSnapshotCache:[String:String]=[:]
 var _analysisSnapshotCache:[String:String]=[:]
 var audioVerificationTask:Task<Void,Never>?
 func validateAnalysisTranscriptRevision(_ file:AnalysisFile,episodeHash:String) throws {}
 METHODS
}
@main struct Probe {
 @MainActor static func main() async throws {
  let root=ICTranscriptionPaths.root
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  let audio=root.appendingPathComponent("audio.bin")
  try Data("Complete unchanged source used by local speech recognition".utf8).write(to:audio,options:.atomic)
  let sha=try await ICAudioIdentity.sha256(of:audio)
  TranscriptionEngine.shared.source=sha
  let writer=ChapterGenerator()
  try writer.saveChaptersThrowing([ICGeneratedChapter(start:0,end:10,title:"Locally generated",isSponsor:false)],for:"local")
  let payload=try String(contentsOf:ICTranscriptionPaths.chaptersJSONURL(for:"local"),encoding:.utf8)
  print("actual_local_persisted_file="+payload)
  var failed=0
  for (name,reader) in [("same session",writer),("fresh generator after restart",ChapterGenerator())] {
   let loaded=reader.loadChapters(for:"local") ?? []
   precondition(loaded.count==1)
   let result=await withCheckedContinuation { continuation in
    reader.verifyPlaybackAudio(forEpisodeHash:"local",audioURL:audio) { a,t in continuation.resume(returning:[a,t]) }
   }
   print("\(name): actual chaptersVerified=\(result[0]), transcriptVerified=\(result[1]); expected chaptersVerified=true for saved chapters from unchanged proven local source")
   if result != [true,true] {failed+=1}
  }
  exit(failed == 0 ? 0 : 1)
 }
}
'''.replace('TYPES',types).replace('IDENTITY',identity).replace('SNAPSHOT',snapshot).replace('METHODS',methods)
p=Path('/tmp/instacast-local-chapter-identity-review.swift');p.write_text(fixture)
subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(p),'-o','/tmp/instacast-local-chapter-identity-review'],check=True)
raise SystemExit(subprocess.run(['/tmp/instacast-local-chapter-identity-review']).returncode)
