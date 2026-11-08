#!/usr/bin/env python3
from pathlib import Path
import ast
import hashlib
import json
import platform
import subprocess
import sys

ROOT = Path('/Users/prefect/Developer/instacastplus')
OUT = Path(__file__).resolve().parent
source_path = ROOT / 'Classes/ServerTranscriptionManager.swift'
source = source_path.read_text()
generator_path = ROOT / 'Tools/server_transcription_admission_runtime_test.py'
signatures = None
for node in ast.parse(generator_path.read_text()).body:
    if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'signatures' for t in node.targets):
        signatures = ast.literal_eval(node.value)
assert signatures

def declaration(signature):
    start = source.index(signature)
    if source[max(0, start-len('nonisolated ')):start] == 'nonisolated ':
        start -= len('nonisolated ')
    brace = source.index('{',start)
    depth = 0
    for end in range(brace,len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end+1]
    raise AssertionError(signature)

fixture_path = ROOT / 'Tools/fixtures/server_transcription_cancellation_harness.swift'
fixture = fixture_path.read_text()
start = fixture.index(' static func run(in dir:URL)')
end = fixture.index('\n}\n@main',start)
fixture = fixture[:start] + (OUT/'cases.swift').read_text() + fixture[end:]
queue_path = ROOT / 'Classes/TranscriptionQueue.swift'
queue_source = queue_path.read_text()
queue_item = queue_source.split('@objc class ICTranscriptionQueueItem:',1)[1].split('// MARK: - Persisted Queue',1)[0]
start = fixture.index('class ICTranscriptionQueueItem:')
end = fixture.index('@MainActor class TranscriptionQueue',start)
fixture = fixture[:start]+'@objc class ICTranscriptionQueueItem:'+queue_item+fixture[end:]
fixture = fixture.replace('enum ICTranscriptionStatus:', '@objc enum ICTranscriptionStatus:')
fixture = fixture.replace('// PRODUCTION_TYPES',source.split('@MainActor\n@objc class ServerTranscriptionManager',1)[0])
fixture = fixture.replace('// PRODUCTION_METHODS','\n'.join(('@discardableResult\n' if signature == 'private func schedulePoll(' else '') + declaration(signature) for signature in signatures))
# Keep the real atomic production snapshot writer. No disk errors are injected.
fixture = fixture.replace('let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)', 'let dir=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)')
fixture = fixture.replace('  defer {try? FileManager.default.removeItem(at:dir)}\n','')
(OUT/'main.swift').write_text(fixture)
compile_command = ['xcrun','swiftc','-swift-version','6','-parse-as-library',str(OUT/'main.swift'),'-o',str(OUT/'run')]
run_command = [str(OUT/'run'),str(OUT/'evidence')]
manifest = {
 'command':f'python3 {OUT}/probe.py',
 'compile_command':compile_command,
 'run_command':run_command,
 'platform':platform.platform(),
 'swift_version':subprocess.check_output(['xcrun','swiftc','--version'],text=True).strip(),
 'sources_sha256':{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in [source_path,queue_path,generator_path,fixture_path,OUT/'probe.py',OUT/'cases.swift',OUT/'failure-analysis.md',OUT/'main.swift']},
 'production_behavior':'unmodified extracted production methods; existing FakeServer/cache/hash/artifact boundary harness',
}
compiled = subprocess.run(compile_command,text=True,capture_output=True)
(OUT/'compile.log').write_text(compiled.stdout+compiled.stderr)
manifest['compile_exit_code'] = compiled.returncode
if compiled.returncode == 0:
    result = subprocess.run(run_command,text=True,capture_output=True,timeout=30)
    (OUT/'runtime.log').write_text(result.stdout+result.stderr)
    manifest['runtime_exit_code'] = result.returncode
    print(result.stdout,end='')
    print(result.stderr,end='',file=sys.stderr)
else:
    print(compiled.stdout+compiled.stderr)
(OUT/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
sys.exit(manifest.get('runtime_exit_code',compiled.returncode))
