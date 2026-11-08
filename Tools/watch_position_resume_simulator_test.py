#!/usr/bin/env python3
"""Run real watch app playback/stall/phone-handoff flows on a disposable simulator.

A shadow project appends a command driver to a copy of the player source. No
production method is replaced. Keep red/green evidence in separate directories.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid', required=True)
p.add_argument('--evidence', required=True, type=Path)
args = p.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)


def run(command, check=True):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    with (out / 'commands.log').open('a') as log:
        log.write(shlex.join(command) + '\n' + result.stdout)
    if check and result.returncode:
        raise RuntimeError(result.stdout[-5000:])
    return result.stdout.strip()


shadow = out / 'Source'
shadow.mkdir(exist_ok=True)
for source in ROOT.iterdir():
    target = shadow / source.name
    if source.name in ('build', 'InstacastWatch', 'Instacast.xcodeproj', '.git') or target.exists():
        continue
    target.symlink_to(source, target_is_directory=source.is_dir())
shutil.copytree(ROOT / 'Instacast.xcodeproj', shadow / 'Instacast.xcodeproj', dirs_exist_ok=True)
shutil.copytree(ROOT / 'InstacastWatch', shadow / 'InstacastWatch', dirs_exist_ok=True)
player = shadow / 'InstacastWatch/WatchPlayerController.swift'
player.write_text(player.read_text() + '\n' + (ROOT / 'Tools/fixtures/watch_position_probe.swift').read_text())
entry = shadow / 'InstacastWatch/InstacastWatchApp.swift'
entry.write_text(entry.read_text().replace('await WatchManifestStore.shared.load()',
    'await WatchManifestStore.shared.load()\n            WatchPlayerController.startPositionProbe()'))
# Observe the exact outbound payload without replacing the transport or handler.
connectivity = shadow / 'InstacastWatch/WatchConnectivityController.swift'
marker = 'message["watchEventRevision"] = NSNumber(value: nextWatchEventRevision())'
availability = 'guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }'
source = connectivity.read_text()
assert marker in source and availability in source
# Simulator WatchConnectivity cannot activate. Move only that transport gate
# after serialization in the shadow copy so we can retain the real wire message;
# the original availability check still prevents any unavailable radio send.
source = source.replace(availability, '', 1)
connectivity.write_text(source.replace(marker, marker + '''
        if type.hasPrefix("playback.") {
            let target = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PositionProbe/outbound.json")
            try? JSONSerialization.data(withJSONObject: message).write(to: target, options: .atomic)
        }
''' + '\n        ' + availability, 1))
dd = out.parent / 'WatchPositionDerivedData'
build_command = ['xcodebuild', '-project', str(shadow / 'Instacast.xcodeproj'), '-target', 'InstacastWatch',
    '-configuration', 'Debug', '-sdk', 'watchsimulator', 'ARCHS=arm64',
    f'SYMROOT={dd / "Build/Products"}', f'OBJROOT={dd / "Build/Intermediates.noindex"}',
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG', 'CODE_SIGNING_ALLOWED=NO', 'build']
with (out / 'build.log').open('w') as log:
    result = subprocess.run(build_command, stdout=log, stderr=subprocess.STDOUT)
assert result.returncode == 0, f'Build failed: {out / "build.log"}'
app = dd / 'Build/Products/Debug-watchsimulator/InstacastWatch.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
bundle = info['CFBundleIdentifier']
assert info['UIBackgroundModes'] == ['audio'], info
run(['xcrun', 'simctl', 'terminate', args.udid, bundle], check=False)
run(['xcrun', 'simctl', 'install', args.udid, str(app)])
container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, bundle, 'data']))
directory = container / 'Documents/PositionProbe'
directory.mkdir(parents=True, exist_ok=True)
for name in ('command.json', 'reply.json', 'outbound.json'):
    (directory / name).unlink(missing_ok=True)
with wave.open(str(directory / 'fixture.wav'), 'wb') as audio:
    audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
    audio.writeframes(b'\0\0' * (4800 * 8000))
(out / 'environment.json').write_text(json.dumps({
    'command': shlex.join([sys.executable, *sys.argv]), 'udid': args.udid, 'app': str(app),
    'buildCommand': shlex.join(build_command), 'info': info,
    'sourceSHA256': hashlib.sha256((ROOT / 'InstacastWatch/WatchPlayerController.swift').read_bytes()).hexdigest(),
    'binarySHA256': hashlib.sha256((app / info['CFBundleExecutable']).read_bytes()).hexdigest(),
    'fixture': '4800-second mono 8 kHz PCM silence, initial position 3319 seconds',
    'scope': 'Real watch app, audio player, timer, manifest and phone-state handler; OS stop injected. Shadow copy moves unavailable transport gate after actual message serialization for file bridging. No hardware audio route or radio transport test.',
}, indent=2, default=str))
run(['xcrun', 'simctl', 'launch', args.udid, bundle])
checks = []


def command(action='status', **parameters):
    request = dict(id=str(uuid.uuid4()), action=action, **parameters)
    tmp = directory / 'command.tmp'
    tmp.write_text(json.dumps(request))
    tmp.replace(directory / 'command.json')
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        try:
            reply = json.loads((directory / 'reply.json').read_text())
            if reply['id'] == request['id']:
                with (out / 'observations.jsonl').open('a') as log:
                    log.write(json.dumps({'request': request, 'reply': reply}) + '\n')
                assert 'error' not in reply, reply
                return reply
        except FileNotFoundError:
            pass
        time.sleep(.1)
    raise AssertionError(f'No response: {request}')


def check(name, passed, state):
    checks.append(dict(name=name, passed=bool(passed), observed=state))
    print(name, 'PASS' if passed else 'FAIL', flush=True)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))


try:
    command('fixture')
    state = command('play')
    assert state['started'] and state['audioPlaying'] and abs(state['time'] - 3319) < 1, state
    command('stall')
    time.sleep(2)
    state = command()
    check('Stopped audio updates visible playback state and releases timer/active marker',
          not state['isPlaying'] and not state['timerValid'] and not state['activeMarker'], state)
    baseline = state['storedDate']
    time.sleep(6)
    state = command()
    check('Stopped watch position does not acquire a newer mutation timestamp', state['storedDate'] == baseline, state)
    state = command('phone', position=4200)
    phone_date = state['storedDate']
    time.sleep(6)
    command('flush')
    command('flush')
    state = command()
    check('Phone progress survives stalled watch timer and lifecycle flushes',
          state['storedPosition'] == 4200 and state['storedDate'] == phone_date, state)
    payload = json.loads((directory / 'outbound.json').read_text())
    assert 3318 <= payload['position'] <= 3322, payload
    (out / 'handoff-payload.json').write_text(json.dumps(payload, indent=2))
    # Even seeking to the previously reported second is a new user choice after
    # the phone has moved the canonical position ahead.
    previous_position = payload['position']
    state = command('seek', position=previous_position)
    check('A deliberate seek to the old watch position overrides newer phone progress', state['storedPosition'] == previous_position, state)
    command('play')
    time.sleep(6)
    state = command('pause')
    check('Resumed audio records actual forward progress', state['storedPosition'] > previous_position, state)
    paused_date = state['storedDate']
    time.sleep(2)
    state = command('flush')
    check('Paused lifecycle flush keeps the last real mutation date', state['storedDate'] == paused_date, state)
    run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / 'watch-final.png')])
finally:
    shutil.copytree(container / 'Library/Application Support/WatchManifest', out / 'WatchManifest', dirs_exist_ok=True)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))
sys.exit(0 if checks and all(c['passed'] for c in checks) else 1)
