from pathlib import Path
import subprocess,tempfile
source=(Path(__file__).resolve().parents[1]/'Classes/ChapterGenerator.swift').read_text()
def extract(signature):
 start=source.index(signature);brace=source.index('{',start);depth=0
 for end in range(brace,len(source)):
  depth+=(source[end]=='{')-(source[end]=='}')
  if not depth:return source[start:end+1]
methods='\n'.join(extract(s) for s in ['func verifyPlaybackAudio(', '@objc func cancelGeneratedAudioVerification()', '@objc func invalidateAnalysisCache(', '@objc func invalidateChaptersCache('])
swift='''import Foundation
final class ICDiagnosticLogger: Sendable {
 static let shared = ICDiagnosticLogger()
 func logEvent(_ category:String,message:String,metadata:NSDictionary) {}
}
@MainActor enum ICAudioIdentity {
 static var pending: CheckedContinuation<String,Never>?
 static func sha256(of url: URL) async throws -> String { await withCheckedContinuation { pending=$0 } }
}
enum ICTranscriptionPaths { static func analysisJSONURL(for hash:String)->URL { URL(fileURLWithPath:"/analysis") } }
@MainActor final class TranscriptionEngine {
 static let shared=TranscriptionEngine();var source:String?
 func transcriptSourceAudioSHA256(for episodeHash:String)->String? { source }
 func transcriptSnapshotIdentifier(for episodeHash:String)->String? { source }
 static func artifactSnapshotIdentifier(at url:URL)->String? { "analysis" }
}
@MainActor final class Generator:NSObject {
 var audioVerificationTask:Task<Void,Never>?
 var _analysisSnapshotCache: [String:String] = ["episode":"analysis"]
 var _analysisTranscriptSnapshotCache: [String:String] = [:]
 var _analysisAudioSHA256Cache:[String:String]=[:]
 var _summaryCache:[String:String]=[:]
 var _loadedChaptersCache:[String:Int]=[:]
 var _chaptersCache:[String:Bool]=[:]
METHODS
}
@main struct Test {
 @MainActor static func main() async {
  let g=Generator();let old=String(repeating:"a",count:64);let new=String(repeating:"b",count:64)
  g._analysisAudioSHA256Cache["episode"]=old;TranscriptionEngine.shared.source=old;g._analysisTranscriptSnapshotCache["episode"]=old
  let result=Task { @MainActor in await withCheckedContinuation { c in
   g.verifyPlaybackAudio(forEpisodeHash:"episode",audioURL:URL(fileURLWithPath:"/audio")){a,t in c.resume(returning:[a,t])}
  }}
  while ICAudioIdentity.pending == nil { await Task.yield() }
  g.invalidateAnalysisCache(for:"episode")
  TranscriptionEngine.shared.source=new
  ICAudioIdentity.pending?.resume(returning:old);ICAudioIdentity.pending=nil
  let verdict=await result.value
  print("actual_verdict_after_source_changed=\\(verdict); expected=[false,false]")
  if verdict != [false,false] { exit(1) }
 }
}
'''.replace('METHODS',methods)
with tempfile.TemporaryDirectory() as d:
 p=Path(d);(p/'main.swift').write_text(swift)
 subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
