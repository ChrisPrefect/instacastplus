#!/usr/bin/env python3
"""Execute the local queue's actual decode and write-admission boundaries."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
local=(ROOT/'Classes/TranscriptionQueue.swift').read_text()
server=(ROOT/'Classes/ServerTranscriptionManager.swift').read_text()
def declaration(s,signature):
 start=s.index(signature);brace=s.index('{',start);depth=0
 for end in range(brace,len(s)):
  depth+=(s[end]=='{')-(s[end]=='}')
  if depth==0:return s[start:end+1]
 raise AssertionError(signature)
model=declaration(local,'private struct PersistedQueue:')
reader=declaration(server,'enum ICQueueSnapshotStorage {')
load=declaration(local,'private func loadPersistedQueue()')
load=load[load.index('{')+1:load.index('        pendingCacheDeletionHashes =')]
persist=declaration(local,'private func persistQueue(')
persist=persist[persist.index('{')+1:persist.index('        let now = Date()')]
fixture='''
import Foundation
MODEL
READER
final class Preparation { var error:NSError?;func finishPreparation(withError value:NSError?) { error=value } }
final class Local {
 let queueFileURL:URL;var queueLoadError:NSError?;fileprivate var loaded:PersistedQueue?
 init(_ url:URL) {queueFileURL=url}
 func load() { LOAD;loaded=persisted }
 func save(cacheDeletionPreparation:Preparation?, completion:((NSError?)->Void)?) throws {
 PERSIST
 try Data("replacement".utf8).write(to:queueFileURL,options:.atomic)
 }
}
@main struct Test {
 static func main() throws {
 let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
 try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
 defer {try? FileManager.default.removeItem(at:directory)}
 let file=directory.appendingPathComponent("queue.json")
 let broken=Data(#"{"items":"broken","pendingCacheDeletionHashes":["owned-cache-intent"]}"#.utf8)
 try broken.write(to:file)
 let local=Local(file);local.load()
 precondition(local.queueLoadError != nil && local.loaded == nil)
 let preparation=Preparation();var callbackError:NSError?
 try local.save(cacheDeletionPreparation:preparation) {callbackError=$0}
 precondition(preparation.error != nil && callbackError != nil)
 precondition(try! Data(contentsOf:file)==broken,"Failed local restore must never clobber snapshot or cache deletion intent")
 let repaired=Data(#"{"items":[],"pendingCacheDeletionHashes":["owned-cache-intent"]}"#.utf8)
 try repaired.write(to:file,options:.atomic);local.load()
 precondition(local.queueLoadError == nil && local.loaded?.pendingCacheDeletionHashes == ["owned-cache-intent"])
 let missing=Local(directory.appendingPathComponent("missing.json"));missing.load();precondition(missing.queueLoadError == nil)
 let unreadable=Local(directory);unreadable.load();precondition(unreadable.queueLoadError != nil)
 print("PASS: local no-clobber, deletion preparation receives error, full recovery, missing vs unreadable path")
 }
}
'''.replace('MODEL',model).replace('READER',reader).replace('LOAD',load).replace('PERSIST',persist)
with tempfile.TemporaryDirectory(prefix='local-queue-storage-') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
