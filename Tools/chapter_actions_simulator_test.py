#!/usr/bin/env python3
"""Native long-press E2E on a disposable simulator; retain commands, fixture, screenshots and xcresult."""
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
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(cmd, check=True, env=None):
        result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(cmd) + '\n' + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout[-6000:])
        return result.stdout

    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
    runtime, device = next((r, d) for r, ds in devices.items() for d in ds if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Chapter Actions Regression' and device['state'] == 'Booted'
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
    source = ROOT / 'Tools/fixtures/chapter_actions_probe.m'
    library = out / 'ChapterActionsProbe.dylib'
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
         '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'CoreGraphics', '-I', str(ROOT / 'Classes'), str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'uninstall', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']).strip())
    directory = container / 'Documents/ChapterActionsProbe'
    directory.mkdir(parents=True)
    with wave.open(str(directory / 'fixture.wav'), 'wb') as audio:
        audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        audio.writeframes(b'\0\0' * 8000 * 96)
    shutil.copy2(directory / 'fixture.wav', out / 'fixture.wav')
    sources = [source, Path(__file__).resolve(), ROOT / 'Tools/fixtures/chapter_actions_ui.swift',
               ROOT / 'Classes/PlayerInfoViewController_v5.m', ROOT / 'Classes/PlaybackManager.m']
    (out / 'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable, *sys.argv]), runtime=runtime, device=device, app=str(args.app.resolve()),
        fixture='96s WAV; two episodes in one feed, each eight chapters every 12s; duplicate Intro at 12s and 60s',
        expected='Long press menu offers episode skip or named feed rule; strike, skip, reactivate without menu; episode isolation',
        scope='Native XCTest press and menu tap; actual UIKit rows/Core Data/AVPlayer, no replaced production methods',
        sourceSHA256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        binarySHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.app.glob('InstacastPlus*') if p.is_file()}), indent=2))
    run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid,
         BUNDLE, '-AppleLanguages', '(de)', '-AppleLocale', 'de_CH'],
        env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

    def command(action):
        request = dict(id=str(uuid.uuid4()), action=action)
        temp = directory / 'command.tmp'
        temp.write_text(json.dumps(request))
        temp.replace(directory / 'command.json')
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if (directory / 'reply.json').exists():
                reply = json.loads((directory / 'reply.json').read_text())
                if reply['id'] == request['id']:
                    assert 'error' not in reply, reply
                    return reply['state']
            time.sleep(.1)
        raise AssertionError(f'No reply for {request}')

    try:
        command('seed')
        command('open')
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            state = command('status')
            if state['presented'] and state['ready'] and not state['loading'] and state['rows'] == 8:
                break
            time.sleep(.2)
        else:
            raise AssertionError(state)
        command('showFirst')
        project = out / 'NativeScroll.xcodeproj'
        project.mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
        (out / 'NativeScrollTests.swift').write_text((ROOT / 'Tools/fixtures/chapter_actions_ui.swift').read_text().replace('__PROBE_DIRECTORY__', str(directory)))
        native_log = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests', '-destination',
                          'platform=iOS Simulator,id=' + args.udid, '-derivedDataPath', str(out / 'NativeDerived'),
                          '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(out / 'native.xcresult'), 'test'], check=False)
        passed = '** TEST SUCCEEDED **' in native_log
        if passed:
            command('roundtrip')
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                state = command('status')
                if state['backupStatus'] == 'complete':
                    break
                time.sleep(.1)
            else:
                raise AssertionError(state)
            assert state['strikes'].get('Intro') is True and state['strikes'].get('Sponsor Special') is True, state
            run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE])
            run(['xcrun', 'simctl', 'launch', args.udid, BUNDLE, '-AppleLanguages', '(de)'],
                env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
            command('restore')
            command('open')
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                state = command('status')
                if state['presented'] and state['ready'] and not state['loading'] and state['rows'] == 8:
                    break
                time.sleep(.1)
            command('showFirst')
            state = command('status')
            assert state['strikes'].get('Intro') is True and state['strikes'].get('Sponsor Special') is True, state
        (out / 'result.json').write_text(json.dumps(dict(passed=passed, observed=command('status')), indent=2))
        print(native_log[-7000:])
        return 0 if passed else 1
    finally:
        for path in directory.glob('*'):
            if path.suffix in ('.json', '.jsonl', '.png', '.xml'):
                shutil.copy2(path, out / path.name)
        for name in ['Diagnostics.jsonl', 'Application.Log']:
            candidates = list(container.rglob(name))
            if candidates:
                shutil.copy2(candidates[0], out / name)
        run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)


if __name__ == '__main__':
    sys.exit(main())
