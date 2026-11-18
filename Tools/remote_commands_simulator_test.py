#!/usr/bin/env python3
"""App E2E: persisted episode -> relaunch -> mini-player -> MediaPlayer commands.

No app methods are replaced. --stall-service reproduces a slow MediaPlayer service
at its real API boundary. All original framework methods still run. It verifies
that the mini-player action returns while that boundary is blocked, configuration
changes arrive in order, closing disables commands, and iOS never writes macOS
playbackState. Evidence includes exact inputs, hashes, commands, app logs and PNGs.
Use a disposable simulator named Instacast Remote Commands Regression.
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
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--stall-service', action='store_true')
    parser.add_argument('--prepare-ui', action='store_true')
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(command, check=True, env=None):
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(command) + '\n' + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout)
        return result.stdout.strip()

    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
    runtime, device = next((r, d) for r, group in devices.items() for d in group if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Remote Commands Regression' and device['state'] == 'Booted'
    source = ROOT / 'Tools/fixtures/remote_commands_probe.m'
    library = out / 'RemoteCommandsProbe.dylib'
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
         '-isysroot', run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']),
         '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'MediaPlayer',
         '-framework', 'QuartzCore', str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
    directory = container / 'Documents/RemoteCommandsProbe'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ['command.json', 'reply.json']:
        (directory / name).unlink(missing_ok=True)
    with wave.open(str(directory / 'fixture.wav'), 'wb') as wav:
        wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 8000 * 180)
    shutil.copy2(directory / 'fixture.wav', out / 'fixture.wav')
    files = [source, Path(__file__).resolve(), ROOT / 'Classes/PlaybackManager.m']
    (out / 'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable, *sys.argv]), device=device, runtime=runtime,
        app=str(args.app.resolve()), fixture='180s local PCM WAV, persisted PlaybackEpisode, PlayerControls=2, forward=45s',
        stallServiceSeconds=1.1 if args.stall_service else 0,
        expected='Mini-player handler <500ms; service stall off main; correct commands/intervals; close disables; zero iOS playbackState writes',
        sourceSHA256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        binarySHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.app.glob('InstacastPlus*') if p.is_file()}), indent=2))

    def launch(name):
        run(['xcrun', 'simctl', 'launch', f'--stdout={out / (name+"-stdout.log")}',
             f'--stderr={out / (name+"-stderr.log")}', args.udid, BUNDLE,
             '-AppleLanguages', '(en)', '-PlaybackVolume', '0', '-UISoundEnabled', 'NO'],
            env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

    def command(action='status', **params):
        request = dict(id=str(uuid.uuid4()), action=action, **params)
        (directory / 'command.tmp').write_text(json.dumps(request))
        (directory / 'command.tmp').replace(directory / 'command.json')
        deadline = time.monotonic() + 30
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
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            state = command()
            if predicate(state):
                return state
            time.sleep(.05)
        raise AssertionError(state)

    checks = []

    def check(name, passed, observed):
        item = dict(name=name, passed=bool(passed), observed=observed)
        checks.append(item)
        (out / 'checks.json').write_text(json.dumps(checks, indent=2))
        print(json.dumps(item), flush=True)

    launch('seed')
    command('seed')
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
  XCTAssertEqual(system.alerts.count,0,system.debugDescription)
 }
}
''')
        native = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests',
                      '-destination', 'platform=iOS Simulator,id=' + args.udid,
                      '-derivedDataPath', str(out / 'NativeDerived'), '-parallel-testing-enabled', 'NO',
                      '-resultBundlePath', str(out / 'startup.xcresult'), 'test'], check=False)
        assert '** TEST SUCCEEDED **' in native, native[-3000:]
    time.sleep(1)  # Allow the fixture defaults to persist before a real cold launch.
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE])
    (directory / 'command.json').unlink(missing_ok=True)
    launch('cold')
    command()
    time.sleep(1)
    tapped = command('tap', stall=args.stall_service)
    state = wait(lambda s: s['ready'] and s['presented'] and s['playEnabled']
                 and (not args.stall_service or s['serviceCalls']))
    check('mini-player returns promptly', tapped['actionMs'] < 500, tapped['actionMs'])
    if args.stall_service:
        check('slow command service keeps main thread free',
              all(not c['main'] and c['durationMs'] >= 1100 for c in state['serviceCalls']), state['serviceCalls'])
    check('restored player configures skip controls', state['skipEnabled'] and not state['seekEnabled']
          and state['intervals'] == [45] and state['pauseEnabled'], state)
    run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / 'player.png')])
    command('configure', mode=0)
    state = wait(lambda s: s['seekEnabled'] and not s['skipEnabled'])
    check('changed control mode arrives', state['playEnabled'] and state['pauseEnabled'], state)
    command('configure', mode=2, stall=args.stall_service)
    command('close')
    state = wait(lambda s: not s['playEnabled'] and not s['pauseEnabled'] and not s['skipEnabled'] and not s['seekEnabled']
                 and (not args.stall_service or len(s['serviceCalls']) == 2))
    check('close wins over pending control changes', not state['ready'], state)
    check('iOS does not write macOS playbackState', state['playbackStateWrites'] == 0, state['playbackStateWrites'])
    shutil.copytree(container / 'Documents/Logs', out / 'Logs', dirs_exist_ok=True)
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE])
    return 0 if all(c['passed'] for c in checks) else 1


if __name__ == '__main__':
    sys.exit(main())
