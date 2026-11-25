#!/usr/bin/env python3
"""Player E2E: notes/link returns, miniplayer layout, and expanded play hit area.

The injected UIKit driver seeds Core Data and local audio, calls real navigation
actions, samples display frames, and inspects window hit testing. No production
methods are replaced. Optional XCTest sends native taps above/below the glyph.
Use a disposable simulator named Instacast Player Regression.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import threading
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--volume-lifecycle', action='store_true', help='Exercise late iOS framework slider layout at the unavailable simulator hardware boundary')
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(cmd, check=True, env=None):
        result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(cmd) + '\n' + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout)
        return result.stdout.strip()

    device = next(d for ds in json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values()
                  for d in ds if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Player Regression' and device['state'] == 'Booted'
    source = ROOT / 'Tools/fixtures/player_return_probe.m'
    library = out / 'PlayerReturnProbe.dylib'
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
         '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'CoreGraphics', '-framework', 'QuartzCore', '-framework', 'MediaPlayer', str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
    directory = container / 'Documents/PlayerReturnProbe'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ['command.json', 'reply.json']:
        (directory / name).unlink(missing_ok=True)
    with wave.open(str(directory / 'fixture.wav'), 'wb') as wav:
        wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 8000 * 180)
    shutil.copy2(directory / 'fixture.wav', out / 'fixture.wav')
    files = [source, Path(__file__).resolve(), ROOT / 'Tools/fixtures/player_return_ui.swift',
             ROOT / 'Classes/PlayerInfoViewController_v5.m', ROOT / 'Classes/PlaybackControlsViewController.m',
             ROOT / 'Resources-iPhone/Nibs/PlayerControlView.xib']
    (out / 'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable, *sys.argv]), device=device, sdk=sdk,
        fixture='180s local WAV, 14 real Core Data chapters with HTTP links',
        expected='Same chapter rows and screen positions after notes/web return; speaker glyphs centered; play receives +/-48pt taps',
        scope='Actual production navigation and rendered UIKit geometry; native finger events when --native. Simulator has no system audio route.',
        volumeBoundaryFixture='With --volume-lifecycle: actual iOS MPVolumeSlider with app thumb image, supplied after parent appearance at the measured iPhone track baseline of 9pt. This exercises production layout and rendering; it does not verify physical volume changes.',
        sourceSHA256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        binarySHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.app.glob('InstacastPlus*') if p.is_file()}), indent=2))
    run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}',
         args.udid, BUNDLE, '-AppleLanguages', '(de)'],
        env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

    def command(action='status', **params):
        request = dict(id=str(uuid.uuid4()), action=action, **params)
        temp = directory / 'command.tmp'
        temp.write_text(json.dumps(request))
        temp.replace(directory / 'command.json')
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                reply = json.loads((directory / 'reply.json').read_text())
                if reply['id'] == request['id']:
                    with (out / 'observations.jsonl').open('a') as log:
                        log.write(json.dumps(dict(request=request, reply=reply)) + '\n')
                    assert 'error' not in reply, reply
                    return reply['state']
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(.05)
        raise AssertionError(f'No reply: {request}')

    def wait(predicate):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = command()
            if predicate(state):
                # Include subsequent layouts beyond the transition completion.
                time.sleep(.3)
                return command()
            time.sleep(.1)
        raise AssertionError(f'Condition not reached: {state}')

    checks = []

    def record(name, passed, **observed):
        item = dict(name=name, passed=bool(passed), **observed)
        checks.append(item)
        (out / 'checks.json').write_text(json.dumps(checks, indent=2))
        print(json.dumps(item), flush=True)

    def capture(name):
        state = command('capture')
        shutil.copy2(directory / 'screen.png', out / (name + '.png'))
        (out / (name + '.json')).write_text(json.dumps(state, indent=2))
        return state

    def controls(name):
        state = capture(name)
        speakers = {k: state['geometry'][k] for k in ['volumeMinButton', 'volumeMaxButton']}
        record(name + ' speaker images centered', all(abs(g['boxY'] - g['iconY']) < 1 for g in speakers.values()), geometry=speakers)
        record(name + ' play +/-48pt target', all(h['play'] for h in state['playHits']), hits=state['playHits'])

    class WebFixture(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = b'<html><title>Chapter link fixture</title><body>Player chapter link</body></html>'
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *values):
            with (out / 'http.log').open('a') as log:
                log.write((fmt % values) + '\n')

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 18765), WebFixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    def native(name, method):
        project = out / 'NativeScroll.xcodeproj'
        project.mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
        shutil.copy2(ROOT / 'Tools/fixtures/player_return_ui.swift', out / 'NativeScrollTests.swift')
        log = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests', '-destination',
                   'platform=iOS Simulator,id=' + args.udid, '-derivedDataPath', str(out / 'NativeDerived'),
                   '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(out / (name + '.xcresult')),
                   '-only-testing:NativeScrollTests/PlayerReturnTests/' + method, 'test'], check=False)
        (out / (name + '.log')).write_text(log)
        passed = '** TEST SUCCEEDED **' in log
        record(name, passed)
        return passed

    assert native('startup', 'testDismissStartup'), 'Complete the actual startup UI before measuring the player'
    command('seed')
    command('open')
    wait(lambda s: s['presented'] and s['ready'] and not s['loading'] and s['rows'] == 14)
    controls('first-presentation')
    def late_volume_layout(name):
        command('lateNativeVolumeSlider', trackCenterY=9)
        time.sleep(.3)
        state = capture(name)
        assert len(state['tracks']) == 1 and state['tracks'][0]['width'] > 80 and not state['tracks'][0]['hidden'], state['tracks']
        record(name + ' speaker artwork follows late iOS slider layout', all(
            abs(state['geometry'][key]['iconY'] - state['tracks'][0]['y']) < .5
            for key in ['volumeMinButton', 'volumeMaxButton']), tracks=state['tracks'], geometry=state['geometry'])
        command('layoutPlayerControls')
        state = capture(name + '-after-parent-layout')
        record(name + ' parent layout preserves alignment', all(
            abs(state['geometry'][key]['iconY'] - state['tracks'][0]['y']) < .5
            for key in ['volumeMinButton', 'volumeMaxButton']), tracks=state['tracks'], geometry=state['geometry'])

    if args.volume_lifecycle:
        late_volume_layout('late-native-volume-slider')
    for destination in ['notes', 'chapterLink']:
        for position in ['chapters', 'middle']:
            command(position)
            time.sleep(.6)
            before = capture(destination + '-' + position + '-before')
            command(destination)
            wait(lambda s: s['web'] if destination == 'chapterLink' else not s['playerTop'])
            capture(destination + '-' + position + '-destination')
            command('monitor')
            command('webBack' if destination == 'chapterLink' else 'back')
            after = wait(lambda s: s['playerTop'] and not s['web'] and not s['transitioning'])
            command('stop')
            shutil.copy2(directory / 'frames.json', out / (destination + '-' + position + '-frames.json'))
            capture(destination + '-' + position + '-after')
            record(destination + ' preserves ' + position, before['visibleRows'] == after['visibleRows']
                   and abs(before['offset'] - after['offset']) < 1,
                   before=before['visibleRows'], after=after['visibleRows'], offsets=[before['offset'], after['offset']])
    for i in range(3):
        command('close')
        wait(lambda s: not s['presented'])
        command('mini')
        wait(lambda s: s['presented'] and s['ready'] and not s['loading'])
        controls('miniplayer-' + str(i))
        if args.volume_lifecycle:
            late_volume_layout('miniplayer-' + str(i) + '-late-volume')
    if args.native:
        native('native-play-taps', 'testExpandedPlayPauseTouches')
    command('pause')
    server.shutdown()
    server.server_close()
    return 0 if all(c['passed'] for c in checks) else 1


if __name__ == '__main__':
    sys.exit(main())
