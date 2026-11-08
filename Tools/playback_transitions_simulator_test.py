#!/usr/bin/env python3
"""Real app/player/HTTP E2E for intent changes before AVPlayerItem readiness.

The controlled HTTP peer withholds audio until the test has issued Pause/Play.
No production methods are replaced. Evidence includes commands, source/binary
hashes, every observation, HTTP requests, checks, screenshots and application logs.
Use a disposable simulator named Instacast State Transitions.
Pass --prepare-ui on a fresh simulator to dismiss startup prompts through XCTest.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid', required=True)
p.add_argument('--app', required=True, type=Path)
p.add_argument('--evidence', required=True, type=Path)
p.add_argument('--prepare-ui', action='store_true')
p.add_argument('--check-rejection-logging', action='store_true')
args = p.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)


def run(cmd, check=True, env=None):
    r = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    with (out / 'commands.log').open('a') as log:
        log.write(shlex.join(cmd) + '\n' + r.stdout)
    if check and r.returncode:
        raise RuntimeError(r.stdout)
    return r.stdout.strip()


device = next(d for ds in json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values()
              for d in ds if d['udid'] == args.udid)
assert (device['name'] == 'Instacast State Transitions' or device['name'].startswith('Instacast Stress ')) and device['state'] == 'Booted'
source = ROOT / 'Tools/fixtures/playback_transition_probe.m'
library = out / 'PlaybackTransitionProbe.dylib'
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
     '-isysroot', sdk, '-I', str(ROOT / 'Classes'), '-framework', 'UIKit', '-framework', 'CoreData',
     '-framework', 'AVFoundation', str(source), '-o', str(library)])
run(['codesign', '-s', '-', str(library)])
run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
directory = container / 'Documents/PlaybackTransitionProbe'
directory.mkdir(parents=True, exist_ok=True)
for name in ('command.json', 'reply.json'):
    (directory / name).unlink(missing_ok=True)
audio = io.BytesIO()
with wave.open(audio, 'wb') as wav:
    wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
    wav.writeframes(b'\0\0' * 8000 * 120)
payload = audio.getvalue()
gates = {}
requests = []


class Peer(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        requests.append(dict(path=self.path, range=self.headers.get('Range')))
        gate = gates[self.path]
        if not gate.wait(25):
            return
        start, end = 0, len(payload) - 1
        if self.headers.get('Range'):
            lo, hi = self.headers['Range'].removeprefix('bytes=').split('-', 1)
            start, end = int(lo), min(int(hi) if hi else end, end)
        data = payload[start:end + 1]
        self.send_response(206 if self.headers.get('Range') else 200)
        self.send_header('Content-Type', 'audio/wav')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Accept-Ranges', 'bytes')
        if self.headers.get('Range'):
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(payload)}')
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
threading.Thread(target=server.serve_forever, daemon=True).start()
files = [source, Path(__file__).resolve(), ROOT / 'Classes/PlaybackManager.m', ROOT / 'Classes/AudioSession.m']
(out / 'environment.json').write_text(json.dumps(dict(
    command=shlex.join([sys.executable, *sys.argv]),
    device=device, app=str(args.app.resolve()),
    fixture='120 seconds 8 kHz mono PCM WAV, HTTP body and headers held until explicit release',
    expected='Pause before readiness preserves initialization; latest Play/Pause intent wins; Close retires the load',
    sourceSHA256={str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
    binarySHA256={f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in args.app.glob('InstacastPlus*') if f.is_file()}), indent=2))
run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid,
     BUNDLE, '-AppleLanguages', '(en)', '-PlaybackVolume', '0', '-UISoundEnabled', 'NO'], env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
if args.prepare_ui:
    # A native test runner also works on the headless simulator installation.
    # No app methods or notification state databases are replaced.
    project = out / 'Startup.xcodeproj'
    project.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
    (out / 'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests: XCTestCase {
 func testDismissStartup() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let system=XCUIApplication(bundleIdentifier:"com.apple.springboard")
  for title in ["Nicht erlauben","Don’t Allow","Don't Allow"] {
   let button=system.alerts.buttons[title]
   if button.waitForExistence(timeout:1) {button.tap();break}
  }
  for title in ["Got it!","Verstanden!","Verstanden"] {
   let button=app.buttons[title]
   if button.waitForExistence(timeout:1) {button.tap();break}
  }
  XCTAssertEqual(system.alerts.count,0,system.debugDescription)
 }
}
''')
    native = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests',
                  '-destination', 'platform=iOS Simulator,id=' + args.udid,
                  '-derivedDataPath', str(out / 'NativeDerived'), '-parallel-testing-enabled', 'NO',
                  '-resultBundlePath', str(out / 'startup.xcresult'), 'test'], check=False)
    (out / 'startup.log').write_text(native)
    assert '** TEST SUCCEEDED **' in native, 'Native startup preparation failed'


def command(action='status', **params):
    request = dict(id=str(uuid.uuid4()), action=action, **params)
    temp = directory / 'command.tmp'
    temp.write_text(json.dumps(request))
    temp.replace(directory / 'command.json')
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        try:
            response = json.loads((directory / 'reply.json').read_text())
            if response['id'] == request['id']:
                with (out / 'observations.jsonl').open('a') as log:
                    log.write(json.dumps(dict(request=request, response=response)) + '\n')
                assert not response.get('error'), response
                return response
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.05)
    raise AssertionError(f'No reply: {request}')


checks = []


def check(name, passed, observed):
    if observed['rate'] > 0:
        passed = passed and observed['volume'] == 0
    checks.append(dict(name=name, passed=bool(passed), observed=observed))
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))
    print(('PASS ' if passed else 'FAIL ') + name, flush=True)


def wait(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        s = command()
        if predicate(s):
            return s
        time.sleep(.1)
    return s


try:
    for name, initial, actions, should_play in [
        ('pause-during-open', True, ['pause'], False),
        ('play-during-paused-open', False, ['play'], True),
        ('latest-pause-wins', True, ['pause', 'play', 'pause'], False),
        ('close-during-open', True, ['close'], False),
    ]:
        path = '/' + name + '.wav'
        gates[path] = threading.Event()
        s = command('open', url=f'http://127.0.0.1:{server.server_port}{path}', autostart=initial)
        check(name + ': fixture is loading', s['selected'] and not s['ready'] and not s['failed'], s)
        for action in actions:
            s = command(action)
        gates[path].set()
        if 'close' in actions:
            s = wait(lambda s: not s['selected'] and not s['ready'])
            check(name + ': closed load cannot resume', not s['selected'] and not s['ready'] and s['paused'] and s['rate'] == 0, s)
        else:
            s = wait(lambda s: s['ready'] and ((s['rate'] > 0) if should_play else s['paused']))
            check(name + ': ready with latest intent', s['ready'] and not s['failed'] and
                  ((s['rate'] > 0 and not s['paused']) if should_play else (s['paused'] and s['rate'] == 0)), s)
            if not should_play and s['ready']:
                command('play')
                s = wait(lambda s: s['rate'] > 0)
                check(name + ': explicit resume works', s['ready'] and s['rate'] > 0, s)
                command('pause')
        run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / (name + '.png'))])
        command('close')
    for should_play in [False, True]:
        name = 'replace-pending-load-' + ('playing' if should_play else 'paused')
        old_path, new_path = '/' + name + '-old.wav', '/' + name + '-new.wav'
        gates[old_path], gates[new_path] = threading.Event(), threading.Event()
        command('open', url=f'http://127.0.0.1:{server.server_port}{old_path}', autostart=True)
        deadline = time.monotonic() + 10
        while not any(r['path'] == old_path for r in requests) and time.monotonic() < deadline:
            time.sleep(.05)
        assert any(r['path'] == old_path for r in requests), 'Old request must actually be in flight'
        command('pause')
        new = command('open', url=f'http://127.0.0.1:{server.server_port}{new_path}', autostart=should_play)
        gates[old_path].set()
        # The old response is released while the new source is still held.
        s = wait(lambda s: s['ready'] or s['failed'], seconds=1)
        check(name + ': old response cannot initialize the selected replacement',
              s['episodeHash'] == new['episodeHash'] and not s['ready'] and not s['failed'], s)
        gates[new_path].set()
        s = wait(lambda s: s['ready'] and ((s['rate'] > 0) if should_play else s['paused']))
        check(name + ': replacement owns readiness and playback intent',
              s['episodeHash'] == new['episodeHash'] and s['ready'] and
              ((s['rate'] > 0 and not s['paused']) if should_play else (s['rate'] == 0 and s['paused'])), s)
        run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / (name + '.png'))])
        command('close')
    if args.check_rejection_logging:
        command('play')  # An unopened player must reject Play and explain it in the user export.
        command('exportLogs')
        shutil.copy2(directory / 'export.txt', out / 'InstacastPlus-CrashLogs.txt')
        exported = [json.loads(line) for line in (directory / 'export.txt').read_text().splitlines() if line.startswith('{')]
        rejected = [line for line in exported if line.get('category') == 'playback-transition'
                    and line.get('metadata', {}).get('event') == 'play'
                    and line.get('metadata', {}).get('fromState') == 'idle']
        assert rejected, 'The actual user log export must explain rejected Play from idle'
        (out / 'rejected-transitions.json').write_text(json.dumps(rejected, indent=2))
finally:
    for gate in gates.values():
        gate.set()
    server.shutdown()
    (out / 'http.json').write_text(json.dumps(requests, indent=2))
    if (directory / 'closing-stacks.json').exists():
        shutil.copy2(directory / 'closing-stacks.json',out / 'closing-stacks.json')
    logs = container / 'Documents/Logs'
    if logs.exists():
        shutil.copytree(logs, out / 'Logs', dirs_exist_ok=True)
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
raise SystemExit(0 if checks and all(c['passed'] for c in checks) else 1)
