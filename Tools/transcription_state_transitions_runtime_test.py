#!/usr/bin/env python3
"""Exercise the actual queue item and progress handler, not a copied state model.

Isolation justification: an app E2E cannot reliably enumerate late provider
callbacks at every native ASR/semantic phase boundary. This exhausts the public
status boundary and directly executes the production callback handler.
Failure cases: terminal resurrection, phase regression, progress changing the
phase, a late callback after suspension, unknown/none status, and retry/restore
accidentally using ordinary processing transitions. Normal forward stages and
server polling must continue to work. Full app server E2E covers integration.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Classes/TranscriptionQueue.swift').read_text()


def declaration(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(signature)


item = declaration('@objc class ICTranscriptionQueueItem:')
progress = declaration('private func recordProgressSample(')
extra = ''
if 'func restoreStatus(' in item:
    extra = '''
        let restored = fresh()
        check(restored.restoreStatus(.completed), "Restore accepts a persisted terminal state")
        check(!restored.restoreStatus(.transcribing), "Restore cannot be repeated on a live item")
        check(restored.restart(), "Explicit retry opens a new attempt")
        check(restored.status == .queued, "Retry returns to the queue")
        restored.status = .transcribing
        check(!restored.restoreStatus(.completed), "Restore cannot bypass a running attempt")
        restored.status = .failed
        check(restored.restart(), "Failed work permits explicit retry")
        restored.status = .generatingChapters
        check(restored.requeue(), "An active phase can explicitly checkpoint/requeue")
        check(restored.status == .queued, "Checkpoint requeue preserves an active job")
    '''
program = '''
import Foundation
@objc enum ICTranscriptionStatus:Int { case none,queued,downloadingModel,analyzingMusic,transcribing,generatingChapters,completed,failed,canceled }
enum ICServerAudioSource { case client,server }
struct ICServerTranscriptionWork {
 var activity:String?;var activityUpdatedAt:Date?;var startedAt:Date?;var completed:Double?;var total:Double?
 var unit:String?;var estimatedPhaseRemainingSeconds:Double?;var queuePosition:Int?
}
final class ICDiagnosticLogger {
 static let shared=ICDiagnosticLogger()
 var events = [[String:Any]]()
 func logEvent(_ category:String,message:String,metadata:NSDictionary) {
  events.append(["category":category,"message":message,"metadata":metadata])
 }
}
ITEM
final class ProgressOwner {
 PROGRESS
 func sample(_ item:ICTranscriptionQueueItem, _ status:ICTranscriptionStatus, _ progress:Float) {
  _ = recordProgressSample(for:item,progress:progress,status:status)
 }
}
func fresh()->ICTranscriptionQueueItem {
 ICTranscriptionQueueItem(episodeHash:UUID().uuidString,episodeTitle:"Fixture",feedTitle:"Test",audioURL:nil,language:nil)
}
@main struct Test {
 static func main() {
  var failures=[String]()
  func check(_ passed:Bool,_ name:String) { if !passed { failures.append(name);print("FAIL: "+name) } }
  let active:[ICTranscriptionStatus] = [.queued,.analyzingMusic,.downloadingModel,.transcribing,.generatingChapters]
  let owner=ProgressOwner()
  for terminal in [ICTranscriptionStatus.completed,.failed,.canceled] {
   for next in active + [.none] {
    let item=fresh();item.status = .transcribing;item.status=terminal;item.status=next
    check(item.status == terminal,"Terminal \\(terminal) rejects ordinary \\(next)")
   }
  }
  for phase in active {
   for callback in [ICTranscriptionStatus.analyzingMusic,.downloadingModel,.transcribing,.generatingChapters] where callback != phase {
    let item=fresh();item.status=phase;item.progress=0.4
    owner.sample(item,callback,0.8)
    check(item.status == phase && item.progress == 0.4,"Late \\(callback) progress cannot change \\(phase)")
   }
  }
  let item=fresh();item.status = .analyzingMusic;item.status = .downloadingModel;item.status = .transcribing
  owner.sample(item,.transcribing,0.5)
  check(item.progress == 0.5 && item.status == .transcribing,"Current-phase progress remains accepted")
  item.status = .generatingChapters
  item.status = .transcribing
  check(item.status == .generatingChapters,"Ordinary processing cannot move chapters back to ASR")
  item.status = .completed
  check(item.status == .completed,"Forward pipeline completes")
  EXTRA
  let history=fresh();_ = history.restoreStatus(.completed)
  ICDiagnosticLogger.shared.events=[]
  _ = history.transition(to:.queued)
  _ = history.requeue()
  _ = history.restoreStatus(.transcribing)
  _ = history.transition(to:.none)
  let rejected=ICDiagnosticLogger.shared.events
  check(rejected.count == 4,"Every rejected owner/phase event leaves one diagnostic record")
  for record in rejected {
   let metadata=record["metadata"] as? NSDictionary ?? [:]
   check(record["category"] as? String == "queue-transition" && metadata["episodeHash"] as? String == history.episodeHash,
         "Rejected queue records identify their lifecycle")
   check(metadata["event"] != nil && metadata["fromState"] != nil && metadata["toState"] != nil && metadata["reason"] != nil,
         "Rejected queue records explain the event, states and reason")
   check(metadata["fromState"] as? String == "completed","Exported queue state names are readable without enum decoding")
  }
  let late=fresh();_ = late.transition(to:.transcribing);_ = late.transition(to:.generatingChapters)
  ICDiagnosticLogger.shared.events=[]
  for _ in 0..<100 { owner.sample(late,.transcribing,0.9) }
  check(ICDiagnosticLogger.shared.events.count == 1,"Repeated stale progress is diagnosed once per rejection signature")
  if !failures.isEmpty { fflush(stdout);exit(1) }
  print("PASS: terminal states, forward stages, late progress, explicit retry/requeue/restore")
 }
}
'''.replace('ITEM', item).replace('PROGRESS', progress).replace('EXTRA', extra)
# The same behavioral checks use the read-only model's owner-event API once it
# exists. The pre-change run exercised the original freely writable property.
if 'func transition(to ' in item:
    program = re.sub(r'(\b(?:item|restored)\b)\.status\s*=\s*(\.[A-Za-z]+|terminal|next|phase)(?![A-Za-z])',
                     r'\1.transition(to: \2)', program)
with tempfile.TemporaryDirectory(prefix='instacast-transcription-transitions-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path / 'main.swift'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
