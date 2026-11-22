#!/usr/bin/env python3
"""Trace cached foreground playback, seek callers, time discontinuities and decoded audio.

Uses the existing silence-trim driver solely for fixture setup and public playback
actions. No production methods are replaced. Run on a disposable simulator.
"""
import argparse
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
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

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid', required=True)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--fixture', type=Path, required=True)
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--start', type=float, default=4937)
p.add_argument('--seconds', type=float, default=110)
p.add_argument('--prepare-ui', action='store_true')
p.add_argument('--capture-pcm', action='store_true', help='capture the unchanged decoded audio with an audio processing tap')
p.add_argument('--settings', type=Path, help='filtered playback settings captured from the device')
p.add_argument('--touch', choices=['backward-outside', 'forward-outside', 'backward-tap', 'forward-tap'])
args = p.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)


def run(cmd, check=True, env=None):
    r = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    with (out / 'commands.log').open('a') as log:
        log.write(shlex.join(cmd) + '\n' + r.stdout + '\n')
    if check and r.returncode:
        raise RuntimeError(r.stdout)
    return r.stdout.strip()


device = next(d for ds in json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values()
              for d in ds if d['udid'] == args.udid)
assert device['name'] == 'Instacast Running Rewind' and device['state'] == 'Booted', device
monitor = ROOT / 'Tools/fixtures/playback_running_trace.m'
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
library = out / 'RewindProbe.dylib'
source = ROOT / 'Tools/fixtures/silence_trim_probe.m'
run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
     '-isysroot', sdk, '-I', str(ROOT / 'Classes'), '-framework', 'UIKit', '-framework', 'CoreData',
     '-framework', 'AVFoundation', '-framework', 'CoreMedia', '-framework', 'MediaPlayer', '-framework', 'MediaToolbox', str(source), str(monitor), '-o', str(library)])
run(['codesign', '-s', '-', str(library)])
run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
directory = container / 'Documents/SilenceTrimProbe'
directory.mkdir(parents=True, exist_ok=True)
for name in ('command.json', 'reply.json', 'trace-stop.json', 'trace-stopped.json', 'fixture-setup.json', 'fixture-ready.json'):
    (directory / name).unlink(missing_ok=True)
(out / 'environment.json').write_text(json.dumps(dict(
    command=shlex.join([sys.executable, *sys.argv]), device=device, sdk=sdk,
    fixture=dict(path=str(args.fixture.resolve()), sha256=hashlib.sha256(args.fixture.read_bytes()).hexdigest()),
    settings=json.loads(args.settings.read_text()) if args.settings else None,
    touch=args.touch,
    expected='Foreground playback must not seek backward or repeat decoded audio without a position request.',
    sourceSHA256={str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest()
                  for f in [Path(__file__), source, monitor, ROOT / 'Classes/PlaybackManager.m', ROOT / 'Classes/PlaybackControlsViewController.m', ROOT / 'Resources-iPhone/Nibs/PlayerControlView.xib']},
    binarySHA256={f.name: hashlib.sha256(f.read_bytes()).hexdigest()
                  for f in args.app.glob('InstacastPlus*') if f.is_file()},
    bundleResourceSHA256={str(f.relative_to(args.app)): hashlib.sha256(f.read_bytes()).hexdigest()
                          for f in args.app.rglob('*') if f.is_file() and ('PlayerControlView.nib' in f.parts or f.name == 'CodeResources')}), indent=2))
def launch():
    return run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid,
                BUNDLE, '-AppleLanguages', '(de)', '-PlaybackVolume', '0', '-UISoundEnabled', 'NO'],
               env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library), SIMCTL_CHILD_IC_RUNNING_CAPTURE_PCM='1' if args.capture_pcm else '0'))


launch_result = launch()

if args.prepare_ui:
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
    assert '** TEST SUCCEEDED **' in native, native[-4000:]


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


class Peer(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(args.fixture.resolve().parent), **kw)

    def log_message(self, *_):
        pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    values = json.loads(args.settings.read_text()) if args.settings else dict(PlayerSilenceTrimEnabled=True, PlayerSilenceTrimLevel=0, PlayerSkipBackPeriod=10)
    values.update(AutoDownloadWhileStreaming=False, EnableStreamingOver3G=True)
    command('defaults', values=values)
    seeded = command('seed', name='replay', subscribed=True, feedTitle='Bits und so', title='Bits und so #1032 (Tigersuppe)',
            duration=10535, byteSize=args.fixture.stat().st_size,
            url=f'http://127.0.0.1:{server.server_port}/{args.fixture.name}')
    (directory / 'fixture-setup.json').write_text(json.dumps(dict(episodeHash=seeded['episodeHash'],feedProperties={
        '__UID___auto_skip_chapter_name':'Sponsor:.  bitsundso.plus.  Mehr Bits und so mit Plus.  Intro', 'AutoSkipSponsors':'no'})))
    deadline = time.monotonic() + 10
    while not (directory / 'fixture-ready.json').exists():
        assert time.monotonic() < deadline, 'Feed fixture setup failed'
        time.sleep(.05)
    assert json.loads((directory / 'fixture-ready.json').read_text())['saved']
    command('cache', name='replay')
    deadline = time.monotonic() + 40
    while not command(name='replay')['cached']:
        assert time.monotonic() < deadline, 'Fixture download timed out'
        time.sleep(.2)
    command('present', name='replay', at=args.start, autostart=True)
    deadline = time.monotonic() + 15
    while not (s := command())['playing']:
        assert time.monotonic() < deadline, s
        time.sleep(.1)
    assert s['engine'] == 'avplayer', s
    print('PLAYING', s['time'], flush=True)
    (directory / 'inspect.json').write_text(json.dumps(dict(file='view-tree-start.json')))
    if args.touch:
        backward = args.touch.startswith('backward')
        label = 'Rückwärts 10 Sekunden' if backward else 'Vorwärts 10 Sekunden'
        gesture = 'button.tap()'
        if args.touch.endswith('outside'):
            # Leave UIButton's native tracking tolerance, not merely its visual bounds.
            start_x, end_x = (.85, 1.85) if backward else (.15, -.85)
            gesture = f'''let start = button.coordinate(withNormalizedOffset:CGVector(dx:{start_x},dy:0.5))
  let end = button.coordinate(withNormalizedOffset:CGVector(dx:{end_x},dy:0.5))
  start.press(forDuration:0.02,thenDragTo:end,withVelocity:.fast,thenHoldForDuration:0)'''
        project = out / 'Touch.xcodeproj'
        project.mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
        (out / 'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests: XCTestCase {
 func testPlayerTouch() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let button=app.buttons["LABEL"]
  XCTAssertTrue(button.waitForExistence(timeout:10),app.debugDescription)
  XCTAssertTrue(button.isHittable,app.debugDescription)
  print("PLAYER BEFORE TOUCH",app.debugDescription)
  GESTURE
  print("PLAYER AFTER TOUCH",app.debugDescription)
  let attachment=XCTAttachment(screenshot:app.screenshot())
  attachment.lifetime = .keepAlways
  add(attachment)
 }
}
'''.replace('LABEL',label).replace('GESTURE',gesture))
        native = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests',
                      '-destination', 'platform=iOS Simulator,id=' + args.udid,
                      '-derivedDataPath', str(out / 'TouchDerived'), '-parallel-testing-enabled', 'NO',
                      '-resultBundlePath', str(out / 'touch.xcresult'), 'test'], check=False)
        assert '** TEST SUCCEEDED **' in native, native[-4000:]
    start = time.monotonic()
    while time.monotonic() - start < args.seconds:
        time.sleep(.5)
    command('pause')
    run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / 'player.png')])
    command('exportLogs')
    (directory / 'trace-stop.json').write_text('{}')
    deadline = time.monotonic() + 10
    while not (directory / 'trace-stopped.json').exists():
        assert time.monotonic() < deadline, 'Trace did not finish writing'
        time.sleep(.05)
    for f in directory.glob('*'):
        if f.name not in ('command.json', 'reply.json', 'command.tmp') and f.is_file():
            shutil.copy2(f, out / f.name)
    rows = [json.loads(line) for line in (out / 'running-trace.jsonl').read_text().splitlines()]
    samples = [r for r in rows if r['event'] == 'sample' and r.get('time', 0) >= args.start - 1]
    backwards = [dict(before=a, after=b) for a, b in zip(samples, samples[1:]) if b['raw'] < a['raw'] - .1]
    advanced = samples[-1]['raw'] - samples[0]['raw']
    seeks = [r for r in rows if r.get('key') == 'seekingPositionChangeDate']
    running_seeks = [r for r in seeks if r['time'] >= args.start - 20]
    should_seek = bool(args.touch and args.touch.endswith('-tap'))
    controls = [r for r in rows if r['event'] == 'control' and r['label'] in ('Rückwärts 10 Sekunden','Vorwärts 10 Sekunden')]
    fixture_valid = not args.touch or should_seek or any(r['kind'] in ('up-outside','cancel') for r in controls)
    expected_step = -10 if args.touch and args.touch.startswith('backward') else 10
    valid_seek = len(running_seeks) == 1 and abs(running_seeks[0]['target'] - running_seeks[0]['time'] - expected_step) < 1.1
    audio = [r for r in rows if r['event'] == 'audio' and r['start'] >= args.start - 1]
    audio_backwards = [dict(before=a, after=b) for a, b in zip(audio, audio[1:])
                       if b['start'] < a['start'] + a['duration'] - .1]
    result = dict(passed=fixture_valid and (valid_seek if should_seek else not backwards and not running_seeks and not audio_backwards)
                  and advanced >= args.seconds - 1 and (bool(audio) if args.capture_pcm else True),
                  backwards=backwards, advanced=advanced, first=samples[0], last=samples[-1],
                  seeks=seeks, runningSeeks=running_seeks, touch=args.touch, fixtureValid=fixture_valid, controls=controls, audioBackwards=audio_backwards,
                  audioFormats=[r for r in rows if r['event'] == 'audio-format'],
                  timeJumps=[r for r in rows if r['event'] == 'time-jumped'])
    (out / 'checks.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k not in ('timeJumps','seeks','runningSeeks')}, indent=2), flush=True)
    assert result['passed'], 'Running playback moved backward, repeated decoded audio, or stalled'
finally:
    server.shutdown()
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
