#!/usr/bin/env python3
"""Execute the actual final-ASR publication boundary; empty output is never success."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Classes/TranscriptionEngine.swift').read_text()
start = source.index('                // Merge: dedup based on timestamp overlap')
end = source.index('                // Save SRT file', start)
boundary = source[start:end]
queue = (ROOT / 'Classes/TranscriptionQueue.swift').read_text()
retry_start = queue.index('    private nonisolated static func isTransientPipelineError(')
retry_end = queue.index('    @discardableResult', retry_start)
retry_classifier = queue[retry_start:retry_end].replace('private nonisolated static func', 'static func')
fixture = '''
import Foundation
struct ICTranscriptCue { let start: Double; let end: Double; let text: String }
struct Engine {
RETRY_CLASSIFIER
 func postProcessCues(_ cues: [ICTranscriptCue]) -> [ICTranscriptCue] { cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
 func finish(existingCues: [ICTranscriptCue], newCues: [ICTranscriptCue], startOffset: Double) throws -> [ICTranscriptCue] {
BOUNDARY
 return allCues
 }
}
@main struct Test {
 static func main() throws {
 let engine = Engine()
 for cues in [[], [ICTranscriptCue(start: 0, end: 1, text: "   ")]] {
  do { _ = try engine.finish(existingCues: [], newCues: cues, startOffset: 0); fatalError("Empty ASR was published as successful transcription") }
  catch { precondition((error as NSError).userInfo["transcriptionErrorCode"] as? String == "no_speech"); precondition(!Engine.isTransientPipelineError(error), "Empty ASR must not automatically retry") }
 }
 let prior = ICTranscriptCue(start: 0, end: 10, text: "Previously checkpointed speech")
 precondition(try engine.finish(existingCues: [prior], newCues: [], startOffset: 10).count == 1)
 precondition(try engine.finish(existingCues: [], newCues: [prior], startOffset: 0).count == 1)
 print("Final ASR boundary: empty/blank fail; restored/new speech survives")
 }
}
'''.replace('BOUNDARY', boundary).replace('RETRY_CLASSIFIER', retry_classifier)
# Swift precondition uses a nonthrowing autoclosure.
fixture = fixture.replace('precondition(try engine.finish', 'precondition(try! engine.finish')
with tempfile.TemporaryDirectory(prefix='instacast-input-errors-') as d:
 path = Path(d)
 (path / 'main.swift').write_text(fixture)
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(path/'main.swift'),'-o',str(path/'test')], check=True)
 result = subprocess.run([str(path/'test')], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
 assert result.returncode == 0, result.stderr.splitlines()[0] if result.stderr else result.stdout
print('Transcription input runtime checks passed')
