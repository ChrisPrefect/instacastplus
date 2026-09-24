#!/usr/bin/env python3
"""Execute the real timer bridge and Siri dialog with an accepting/rejecting session."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if not depth:
            return source[start:end + 1]
    raise ValueError(signature)

bridge = (root / 'Classes/AppIntents/ICIntentBridge.swift').read_text()
intent = (root / 'Classes/AppIntents/ICPlaybackIntents.swift').read_text().split('struct ICSetSleepTimerIntent:', 1)[1]
probe = r'''
import Foundation
@MainActor final class AudioSession {
    static let session = AudioSession()
    static func shared() -> AudioSession? { session }
    var disabled = false
    var timerRemainingTime = 0.0
    func setTimerWithDuration(_ seconds: Double) {timerRemainingTime = disabled ? 0 : seconds}
}
@MainActor enum ICIntentBridge {
BRIDGE
ACTIVE
}
protocol IntentResult {}
protocol ProvidesDialog {}
struct DialogResult: IntentResult, ProvidesDialog {let dialog: String}
extension IntentResult where Self == DialogResult {
    static func result(dialog: String) -> DialogResult {DialogResult(dialog: dialog)}
}
func ICLocalizedIntentDialog(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: key, arguments: arguments)
}
struct TestIntent {
    var minutes: Int
    PERFORM
}
@main struct Probe {
    @MainActor static func main() async throws {
        let session = AudioSession.session
        for disabled in [false, true] {
            session.disabled = disabled
            let result = try await TestIntent(minutes: 15).perform() as! DialogResult
            if disabled {
                precondition(session.timerRemainingTime == 0)
                precondition(result.dialog == "While CarPlay is active, the Sleep Timer stays disabled.",
                             "Siri must not report success for a rejected timer")
            } else {
                precondition(session.timerRemainingTime == 900)
                precondition(result.dialog == "Sleep timer set for 15 minutes.")
            }
        }
        print("Sleep timer Siri result checks passed")
    }
}
'''.replace('BRIDGE', method(bridge, 'static func setSleepTimer(')).replace(
    'ACTIVE', method(bridge, 'static var sleepTimerActive:')).replace(
    'PERFORM', method(intent, 'func perform()'))

with tempfile.TemporaryDirectory(prefix='instacast-timer-intent-') as directory:
    path = Path(directory)
    file = path / 'probe.swift'
    file.write_text(probe)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(file), '-o', str(path / 'probe')], check=True)
    subprocess.run([str(path / 'probe')], check=True)

key = '"While CarPlay is active, the Sleep Timer stays disabled." = '
for language in ['de', 'en']:
    assert key in (root / f'Resources/{language}.lproj/Localizable.strings').read_text()
