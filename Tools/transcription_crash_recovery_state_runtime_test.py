#!/usr/bin/env python3
"""Run the production crash-guard recovery block with real queue items.

Failure: termination after a completed snapshot reaches disk but before the
crash marker is cleared must not quarantine or zero a completed result. A real
process-kill E2E cannot reliably hit that atomic-write/marker interval. The
production recovery branch is therefore executed with that persisted contract.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
s = (ROOT / 'Classes/TranscriptionQueue.swift').read_text()


def block(signature):
    start = s.index(signature)
    brace = s.index('{', start)
    depth = 0
    for end in range(brace, len(s)):
        depth += (s[end] == '{') - (s[end] == '}')
        if not depth:
            return s[start:end + 1]
    raise AssertionError(signature)


program = r'''
import Foundation
@objc enum ICTranscriptionStatus:Int { case none,queued,downloadingModel,analyzingMusic,transcribing,generatingChapters,completed,failed,canceled }
enum ICServerAudioSource { case client,server }
struct ICServerTranscriptionWork {
 var activity:String?;var activityUpdatedAt:Date?;var startedAt:Date?;var completed:Double?;var total:Double?
 var unit:String?;var estimatedPhaseRemainingSeconds:Double?;var queuePosition:Int?
}
final class ICDiagnosticLogger {
 static let shared=ICDiagnosticLogger()
 let previousSessionEndedUnexpectedly=true
 var previousSessionState:String? {"background"}
 func logEvent(_ category:String,message:String,metadata:NSDictionary) {}
}
class TranscriptionLogger {
 static let shared=TranscriptionLogger()
 func append(episodeHash:String,phase:String,message:String,detailText:String?=nil) {}
}
ITEM
class Engine {func hasCheckpoint(for hash:String)->Bool {true}}
class TranscriptionQueue {
 static let crashGuardKey="TransitionTest.CrashGuard"
 static let crashGuardEpisodeHashKey="TransitionTest.CrashGuardHash"
 static let crashGuardProtectedStatuses:Set<ICTranscriptionStatus> = [.analyzingMusic,.downloadingModel,.transcribing,.generatingChapters]
 var items:[ICTranscriptionQueueItem]=[]
 let engine=Engine()
 func clearCrashGuard(){UserDefaults.standard.removeObject(forKey:Self.crashGuardKey)}
 func canAutoResumeRemoteChapterJobAfterUnexpectedTermination(_ item:ICTranscriptionQueueItem)->Bool {false}
 func backgroundInterruptionError(reason:String)->NSError {NSError(domain:reason,code:1)}
 func scheduleRetry(for item:ICTranscriptionQueueItem,error:Error,stage:String)->Bool {false}
 func persistQueue(){}
 func postQueueChangeNotification(){}
 func recover(){ RECOVERY }
}
@main struct Test {
 static func main() {
  defer {
   UserDefaults.standard.removeObject(forKey:TranscriptionQueue.crashGuardKey)
   UserDefaults.standard.removeObject(forKey:TranscriptionQueue.crashGuardEpisodeHashKey)
  }
  for status in [ICTranscriptionStatus.completed,.failed,.canceled,.transcribing] {
   let item=ICTranscriptionQueueItem(episodeHash:"guarded",episodeTitle:"Fixture",feedTitle:"Test",audioURL:nil,language:nil)
   item.restoreStatus(status)
   item.progress=status == .completed ? 1 : 0.4
   item.error=status == .failed ? "Retained failure" : nil
   let progress=item.progress,error=item.error
   let queue=TranscriptionQueue();queue.items=[item]
   UserDefaults.standard.set(true,forKey:TranscriptionQueue.crashGuardKey)
   UserDefaults.standard.set(item.episodeHash,forKey:TranscriptionQueue.crashGuardEpisodeHashKey)
   queue.recover()
   if status == .transcribing {
    precondition(item.status == .queued && item.requiresExplicitRetryAfterCrash,"Interrupted active work remains explicitly resumable")
   } else {
    precondition(item.status == status && item.progress == progress && item.error == error && !item.requiresExplicitRetryAfterCrash,
                 "Durable terminal history was changed by crash recovery")
   }
   precondition(!UserDefaults.standard.bool(forKey:TranscriptionQueue.crashGuardKey),"Recovery must retire its marker")
  }
  print("PASS: completed/failed/canceled history survives stale crash markers; active interrupted work is quarantined")
 }
}
'''.replace('ITEM', block('@objc class ICTranscriptionQueueItem:')).replace(
    'RECOVERY', block('if UserDefaults.standard.bool(forKey: TranscriptionQueue.crashGuardKey)'))
with tempfile.TemporaryDirectory(prefix='instacast-crash-recovery-state-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
