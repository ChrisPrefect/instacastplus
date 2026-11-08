#!/usr/bin/env python3
"""Server-source import needs a source hash; client-bound import also proves local audio."""
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
fixture = r'''import Foundation
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
enum ICServerAudioSource: String {case client, server}
class Item {let episodeHash="episode";var serverAudioSource = ICServerAudioSource.client}
@MainActor final class Manager {
 func findEpisode(hash:String)->Episode? {Episode()}
 func serverContractError(code:Int,message:String)->NSError {NSError(domain:"test",code:code,userInfo:[NSLocalizedDescriptionKey:message])}
METHODS
 func run() async throws {
  let item=Item(), expected=String(repeating:"a",count:64)
  var failures:[String]=[]
  CacheManager.instance.cached=false;item.serverAudioSource = .server
  do {
   let proof:(url:URL,snapshot:String)? = try await verifiedImportAudio(for:item,sourceAudioSHA256:expected)
   if proof != nil {failures.append("Server-source import must not claim device audio verification")}
  } catch {failures.append("Server-source import must accept absent device audio when server source identity is valid")}
  if ICAudioIdentity.calls != 0 {failures.append("Server-source import must not hash a device file")}
  item.serverAudioSource = .client;CacheManager.instance.cached=true
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
  let optionalProof:(url:URL,snapshot:String)? = try await verifiedImportAudio(for:item,sourceAudioSHA256:expected)
  let proof=optionalProof!
  precondition(importAudioIsCurrent(proof,for:item))
  TranscriptionEngine.snapshot="file-B";precondition(!importAudioIsCurrent(proof,for:item))
  TranscriptionEngine.snapshot="file-A";CacheManager.instance.audioURL=URL(fileURLWithPath:"/different")
  precondition(!importAudioIsCurrent(proof,for:item));CacheManager.instance.audioURL=URL(fileURLWithPath:"/audio")
  ICAudioIdentity.changeDuringRead=true
  do {_ = try await verifiedImportAudio(for:item,sourceAudioSHA256:expected);fatalError("Mutation during hashing accepted")} catch {precondition((error as NSError).code==57)}
  if !failures.isEmpty {FileHandle.standardError.write(Data((failures.joined(separator:"\n")+"\n").utf8));fatalError("Server-source import contract failed")}
  print("Server source without local audio; client source missing identity, missing audio, mismatch, source replacement and mutation checked")
 }
}
@main struct Test { @MainActor static func main() async throws {try await Manager().run()} }
'''.replace("METHODS",methods.replace("ICTranscriptionQueueItem","Item"))
with tempfile.TemporaryDirectory(prefix="instacast-import-audio-") as directory:
    tmp=Path(directory)
    (tmp/"main.swift").write_text(fixture)
    subprocess.run(["xcrun","swiftc","-swift-version","6","-parse-as-library",str(tmp/"main.swift"),"-o",str(tmp/"test")],check=True)
    subprocess.run([str(tmp/"test")],check=True)
