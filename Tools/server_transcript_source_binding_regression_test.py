#!/usr/bin/env python3
"""An import must prove its local audio before downloading or committing results."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/ServerTranscriptionManager.swift").read_text()
def method(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if not depth: return source[start:end + 1]
    raise AssertionError(signature)

methods = "\n".join(method(s) for s in ["private func verifiedImportAudio(", "private func importAudioIsCurrent("])
fixture = '''import Foundation
@MainActor class Episode {}
@MainActor class CacheManager {
 static let instance=CacheManager();var cached=true;var audioURL:URL?=URL(fileURLWithPath:"/audio")
 static func shared()->CacheManager? {instance}
 func episodeIsCached(_ episode:Episode)->Bool {cached}
 func url(forCachedEpisode episode:Episode)->URL? {audioURL}
}
@MainActor class TranscriptionEngine {
 static var snapshot:String?="file-A"
 static func artifactSnapshotIdentifier(at url:URL?)->String? {snapshot}
}
@MainActor enum ICAudioIdentity {
 static var hash=String(repeating:"a",count:64);static var calls=0;static var changeDuringRead=false
 static func sha256(of url:URL) async throws -> String {
  calls+=1;if changeDuringRead {TranscriptionEngine.snapshot="file-B"};return hash
 }
}
struct Item {let episodeHash="episode"}
@MainActor final class Manager {
 func findEpisode(hash:String)->Episode? {Episode()}
 func serverContractError(code:Int,message:String)->NSError {NSError(domain:"test",code:code,userInfo:[NSLocalizedDescriptionKey:message])}
METHODS
 func run() async throws {
  let item=Item(), expected=String(repeating:"a",count:64)
  for hash in [nil,"",String(repeating:"x",count:64)] as [String?] {
   do {_ = try await verifiedImportAudio(for:item,sourceAudioSHA256:hash);fatalError("Missing/invalid proof accepted")} catch {precondition((error as NSError).code==54)}
  }
  precondition(ICAudioIdentity.calls==0)
  CacheManager.instance.cached=false
  do {_ = try await verifiedImportAudio(for:item,sourceAudioSHA256:expected);fatalError("Absent audio accepted")} catch {precondition((error as NSError).code==55)}
  precondition(ICAudioIdentity.calls==0);CacheManager.instance.cached=true
  ICAudioIdentity.hash=String(repeating:"b",count:64)
  do {_ = try await verifiedImportAudio(for:item,sourceAudioSHA256:expected);fatalError("Mismatched audio accepted")} catch {precondition((error as NSError).code==56)}
  ICAudioIdentity.hash=expected
  let proof=try await verifiedImportAudio(for:item,sourceAudioSHA256:expected)
  precondition(importAudioIsCurrent(proof,for:item))
  TranscriptionEngine.snapshot="file-B";precondition(!importAudioIsCurrent(proof,for:item))
  TranscriptionEngine.snapshot="file-A";CacheManager.instance.audioURL=URL(fileURLWithPath:"/different")
  precondition(!importAudioIsCurrent(proof,for:item));CacheManager.instance.audioURL=URL(fileURLWithPath:"/audio")
  ICAudioIdentity.changeDuringRead=true
  do {_ = try await verifiedImportAudio(for:item,sourceAudioSHA256:expected);fatalError("Mutation during hashing accepted")} catch {precondition((error as NSError).code==57)}
  print("Missing identity, missing audio, mismatched audio, current audio, source replacement and mutation during hashing checked")
 }
}
@main struct Test { @MainActor static func main() async throws {try await Manager().run()} }
'''.replace("METHODS",methods.replace("ICTranscriptionQueueItem","Item"))
with tempfile.TemporaryDirectory(prefix="instacast-import-audio-") as directory:
    tmp=Path(directory)
    (tmp/"main.swift").write_text(fixture)
    subprocess.run(["xcrun","swiftc","-swift-version","6","-parse-as-library",str(tmp/"main.swift"),"-o",str(tmp/"test")],check=True)
    subprocess.run([str(tmp/"test")],check=True)
