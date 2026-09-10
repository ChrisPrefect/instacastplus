#!/usr/bin/env python3
"""Execute the actual post-analysis-await commit tail with a deleted CoreData surrogate."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Classes/ServerTranscriptionManager.swift').read_text()
start=s.index('        try checkCurrentAttempt(item, requestID: requestID)',s.index('let analysis = try await buildServerAnalysis'))
end=s.index('\n    }',start)
tail=s[start:end]
fixture='''import Foundation
@MainActor final class TranscriptionEngine {
 static let shared=TranscriptionEngine(); var writes=0
 func saveValidatedServerSRTData(_ data:Data,cues:[Int],for hash:String,sourceAudioSHA256:String) throws {writes+=1}
}
@MainActor final class ChapterGenerator {
 static let shared=ChapterGenerator();var writes=0
 func saveAnalysisResult(_ analysis:String,for hash:String) throws {writes+=1}
}
struct Episode {let isDeleted:Bool}
struct Item {let episodeHash="test"}
@MainActor final class Manager {
 func checkCurrentAttempt(_ item:Item,requestID:String) throws {}
 func serverContractError(code:Int,message:String)->NSError {NSError(domain:"test",code:code,userInfo:[:])}
 func importAudioIsCurrent(_ proof:Bool,for item:Item)->Bool {proof}
 func commit(deleted:Bool,audioCurrent:Bool=true) throws {
  let audioProof=audioCurrent
  let episode=Episode(isDeleted:deleted), item=Item(), requestID="same-request"
  let srtData=Data(),cues=[1],sourceAudioSHA256="sha",analysis="analysis"
TAIL
 }
}
@main struct Test {
 @MainActor static func main() throws {
  let manager=Manager()
  do {try manager.commit(deleted:true);fatalError("Deleted episode still committed artifacts after async analysis")}
  catch {precondition((error as NSError).code==11)}
  precondition(TranscriptionEngine.shared.writes==0 && ChapterGenerator.shared.writes==0)
  do {try manager.commit(deleted:false,audioCurrent:false);fatalError("Replaced audio still committed artifacts")}
  catch {precondition((error as NSError).code==57)}
  precondition(TranscriptionEngine.shared.writes==0 && ChapterGenerator.shared.writes==0)
  try manager.commit(deleted:false)
  precondition(TranscriptionEngine.shared.writes==1 && ChapterGenerator.shared.writes==1)
  print("Deleted episode blocked at actual post-await commit boundary; live episode committed both artifacts")
 }
}
'''.replace('TAIL',tail)
with tempfile.TemporaryDirectory() as directory:
 p=Path(directory);(p/'test.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(p/'test.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
