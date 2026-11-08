#!/usr/bin/env python3
"""E2E: real player presentation, UIKit scrolling, final-chapter hit testing and seeking.

Use a disposable simulator named Instacast Chapter Scroll Regression. An injected
driver creates a real Core Data episode with the customer's 14 chapter titles and
local WAV audio, calls production presentation/actions and UIKit scrollToRow.
No app methods are replaced. The pane-height fixture tests the post-appearance
public inset contract because the customer's intermittent trigger is unknown.
Native swipes and background/foreground are exercised by a standalone XCTest
runner, without modifying the app project or replacing app methods.
Commands, fixture, source/binary hashes, geometry, screenshots and logs are retained.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--skip-native', action='store_true', help='Focused geometry rerun; omits native gesture/background checks')
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

    runtime, device = next((r, d) for r, ds in json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].items()
                           for d in ds if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Chapter Scroll Regression' and device['state'] == 'Booted'
    source = ROOT / 'Tools/fixtures/chapter_scroll_probe.m'
    library = out / 'ChapterScrollProbe.dylib'
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
         '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'CoreGraphics', str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
    directory = container / 'Documents/ChapterScrollProbe'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ['command.json', 'reply.json']:
        (directory / name).unlink(missing_ok=True)
    with wave.open(str(directory / 'fixture.wav'), 'wb') as audio:
        audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        audio.writeframes(b'\0\0' * 8000 * 180)
    shutil.copy2(directory / 'fixture.wav', out / 'fixture.wav')
    files = [source, Path(__file__).resolve(), ROOT / 'Tools/fixtures/chapter_scroll_ui.swift',
             ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj',
             ROOT / 'Classes/PlayerController.m', ROOT / 'Classes/PlayerInfoViewController_v5.m']
    (out / 'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable, *sys.argv]), runtime=runtime, device=device, app=str(args.app.resolve()), sdk=sdk,
        fixture='180 second WAV, 14 Core Data feed chapters, 12 second chapter intervals; customer video chapter titles',
        expected='Last chapter fully above controls and receives hit test at the maximum UIKit scroll position; same after reopening',
        scope='Real app presentation, UIKit scrolling, hit test and chapter selection; native XCTest swipes/background unless --skip-native',
        boundaryFixture='Resize the visible controls to 194/334 pt and assign the public bottomScrollInset contract used by PlayerController. This seeds a post-appearance geometry change; the exact intermittent customer trigger is unknown.',
        sourceSHA256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        binarySHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.app.glob('InstacastPlus*') if p.is_file()}), indent=2))
    run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid, BUNDLE,
         '-AppleLanguages', '(de)'], env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

    def command(action='status', **params):
        request = dict(id=str(uuid.uuid4()), action=action, **params)
        temp = directory / 'command.tmp'
        temp.write_text(json.dumps(request))
        temp.replace(directory / 'command.json')
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if (directory / 'reply.json').exists():
                reply = json.loads((directory / 'reply.json').read_text())
                if reply['id'] == request['id']:
                    with (out / 'observations.jsonl').open('a') as log:
                        log.write(json.dumps(dict(request=request, reply=reply)) + '\n')
                    assert 'error' not in reply, reply
                    return reply['state']
            time.sleep(.05)
        raise AssertionError(f'No reply for {request}')

    def wait(predicate):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = command()
            if predicate(state):
                return state
            time.sleep(.1)
        raise AssertionError(f'Condition not reached: {state}')

    checks = []

    def record(name, passed, state):
        check = dict(name=name, passed=bool(passed), observed=state)
        checks.append(check)
        (out / 'checks.json').write_text(json.dumps(checks, indent=2))
        print(json.dumps(check), flush=True)

    def check_bottom(name):
        command('bottom')
        state = command('capture')
        shutil.copy2(directory / 'screen.png', out / f'{name}.png')
        record(name, state['rows'] == 14 and state['lastRowBottom'] <= state['controlsTop'] + 1 and state['lastRowHit'], state)
        record(name + ' applies requested scroll and indicator insets',
               abs(state['indicatorBottom'] - state['requestedBottom']) < 1 and abs(state['insetBottom'] - state['requestedBottom']) < 1, state)

    try:
        command('seed')
        command('open')
        wait(lambda s: s['presented'] and s['ready'] and not s['loading'] and s['rows'] == 14)
        check_bottom('first-presentation')
        command('paneHeight', height=194)
        check_bottom('smaller-pane-after-appearance')
        command('notes')
        wait(lambda s: not s['playerTop'] and not s['transitioning'])
        command('back')
        wait(lambda s: s['playerTop'] and not s['transitioning'])
        check_bottom('smaller-pane-after-return')
        position = command('middle')['offset']
        command('paneHeight', height=334)
        command('layout')
        state = command('layout')
        record('resizing and subsequent layouts preserve the reading position', abs(state['offset'] - position) < 1, state)
        check_bottom('larger-pane-after-appearance')
        if not args.skip_native:
            project = out / 'NativeScroll.xcodeproj'
            project.mkdir(exist_ok=True)
            shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
            shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui.swift', out / 'NativeScrollTests.swift')
            native_log = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests',
                              '-destination', 'platform=iOS Simulator,id=' + args.udid,
                              '-derivedDataPath', str(out / 'NativeDerived'), '-parallel-testing-enabled', 'NO',
                              '-resultBundlePath', str(out / 'native.xcresult'), 'test'], check=False)
            (out / 'native.log').write_text(native_log)
            record('native swipes reach last chapter after background/foreground', '** TEST SUCCEEDED **' in native_log, command())
            state = command('pause')
            record('native tap selects final chapter', abs(state['playbackTime'] - 156) < 5, state)
            command('capture')
            shutil.copy2(directory / 'screen.png', out / 'native-scroll.png')
        command('close')
        wait(lambda s: not s['presented'])
        command('open')
        wait(lambda s: s['presented'] and s['ready'] and not s['loading'] and s['rows'] == 14)
        check_bottom('reopened')
        command('selectLast')
        state = wait(lambda s: s['playbackTime'] >= 155)
        record('last chapter selection seeks to final chapter', abs(state['playbackTime'] - 156) < 2, state)
        command('pause')
    finally:
        for name in ['Diagnostics.jsonl', 'Application.Log']:
            candidates = list(container.rglob(name))
            if candidates:
                shutil.copy2(candidates[0], out / name)
    return 0 if checks and all(c['passed'] for c in checks) else 1


if __name__ == '__main__':
    sys.exit(main())
