#!/usr/bin/env python3
"""The exact saved SRT snapshot reuses validated cues; replaced bytes must reparse."""
from pathlib import Path
import subprocess,tempfile
R=Path(__file__).resolve().parents[1];s=(R/'Classes/TranscriptionEngine.swift').read_text()
def extract(signature):
 start=s.index(signature);brace=s.index('{',start);depth=0
 for end in range(brace,len(s)):
  depth+=(s[end]=='{')-(s[end]=='}')
  if not depth:return s[start:end+1]
methods=extract('func persistedTranscriptCues(')+'\n'+extract('@objc nonisolated static func artifactSnapshotIdentifier')
fixture='''import Foundation
import Darwin
struct ICTranscriptCue { let text:String }
final class Engine:NSObject {
 var url:URL;var parseCalls=0
 var validatedServerTranscript:(episodeHash:String,snapshot:String,cues:[ICTranscriptCue])?
 init(url:URL) { self.url=url }
 func srtURL(for hash:String)->URL { url }
 func parsePersistedSRT(_ content:String) throws->[ICTranscriptCue] { parseCalls+=1;return [.init(text:content)] }
METHODS
}
let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at:url) }
try Data("old".utf8).write(to:url)
let engine=Engine(url:url)
engine.validatedServerTranscript=("episode",Engine.artifactSnapshotIdentifier(at:url)!,[.init(text:"validated")])
let cached=try engine.persistedTranscriptCues(for:"episode")!
precondition(engine.parseCalls==0 && cached[0].text=="validated", "Already validated exact SRT was parsed again on UI thread")
try Data("new".utf8).write(to:url,options:.atomic)
let changed=try engine.persistedTranscriptCues(for:"episode")!
precondition(engine.parseCalls==1 && changed[0].text=="new", "Replaced SRT must not reuse old cues")
_ = try engine.persistedTranscriptCues(for:"other")
precondition(engine.parseCalls==2)
print("Exact validated snapshot reuse and replacement invalidation passed")
'''.replace('METHODS',methods)
with tempfile.TemporaryDirectory(prefix='instacast-validated-snapshot-') as d:
 p=Path(d);(p/'main.swift').write_text(fixture)
 subprocess.run(['swiftc','-swift-version','6',str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
