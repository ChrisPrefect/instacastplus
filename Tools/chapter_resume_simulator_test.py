#!/usr/bin/env python3
"""Exercise the real app's chapter table, AVPlayer, automatic skips and saved defaults.

The injected test driver supplies a 24-second PCM fixture and invokes the real
table-selection/control handlers. It neither replaces nor extracts production
methods. Run only on an explicitly selected disposable Simulator. Screenshots,
commands, observations, app diagnostics and checks are retained in --evidence.
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
BUNDLE = 'com.iteconomy.instacastplus'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--udid', required=True)
parser.add_argument('--app', type=Path, required=True)
parser.add_argument('--evidence', type=Path, required=True)
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


device = next(d for ds in json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values()
              for d in ds if d['udid'] == args.udid)
assert device['state'] == 'Booted'
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
library = out / 'ChapterResumeProbe.dylib'
run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
     '-isysroot', sdk, '-framework', 'UIKit', '-framework', 'AVFoundation', '-framework', 'CoreData',
     '-I', str(ROOT / 'Classes'), str(ROOT / 'Tools/fixtures/chapter_resume_probe.m'), '-o', str(library)])
run(['codesign', '-s', '-', str(library)])
run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
directory = container / 'Documents/ChapterResumeProbe'
directory.mkdir(parents=True, exist_ok=True)
with wave.open(str(directory / 'fixture.wav'), 'wb') as audio:
    audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
    audio.writeframes(b'\0\0' * (24 * 16000))
shutil.copy(directory / 'fixture.wav', out / 'fixture.wav')
app_info = plistlib.loads((args.app / 'Info.plist').read_bytes())
executable = app_info['CFBundleExecutable']
(out / 'environment.json').write_text(json.dumps({
    'command': shlex.join([sys.executable, *sys.argv]), 'device': device,
    'app': str(args.app.resolve()), 'sdk': sdk,
    'workspacePlaybackSourceSHA256': hashlib.sha256((ROOT / 'Classes/PlaybackManager.m').read_bytes()).hexdigest(),
    'appBinarySHA256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in [args.app / executable, args.app / (executable + '.debug.dylib')] if p.exists()},
    'fixture': {'duration': 24, 'chapterStarts': [0, 8, 16]},
    'scope': 'Real simulator app and selection handlers; no physical touch injection or hardware audio route test',
}, indent=2))
run(['xcrun', 'simctl', 'launch', args.udid, BUNDLE, '-AppleLanguages', '(de)'],
    env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
checks = []


def command(action='status', **parameters):
    request = dict(id=str(uuid.uuid4()), action=action, **parameters)
    temporary = directory / 'command.tmp'
    temporary.write_text(json.dumps(request))
    temporary.replace(directory / 'command.json')
    deadline = time.monotonic() + 20
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
        time.sleep(.05)
    raise AssertionError(f'No response: {request}')


def wait(predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = command()
        if predicate(state):
            return state
        time.sleep(.1)
    raise AssertionError(f'Playback condition not reached: {state}')


def check(name, actual, expected, tolerance=0):
    passed = abs(actual - expected) <= tolerance
    checks.append(dict(name=name, actual=actual, expected=expected, tolerance=tolerance, passed=passed))
    print(json.dumps(checks[-1]), flush=True)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))


def capture(name):
    (out / (name + '.json')).write_text(json.dumps(command('capture'), indent=2))
    shutil.copy(directory / 'screen.png', out / (name + '-app.png'))
    run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / (name + '.png'))])


def fixture(name, titles=None):
    command('fixture', name=name, **({'titles': titles} if titles else {}))
    command('open', time=0)
    wait(lambda s: s['ready'] and s['chapterCount'] == 3)
    command('show')
    wait(lambda s: s['screenVisible'])


def seek(second):
    command('pause')
    command('seek', time=second)
    wait(lambda s: abs(s['time'] - second) < .1)


def select(index):
    state = command('select', index=index)
    target = state['position']
    wait(lambda s: abs(s['time'] - target) < 1)
    command('pause')
    return target


try:
    # Save by a real chapter-row selection, return, then play across the boundary.
    fixture('Fertiggehörtes Kapitel')
    seek(4)
    select(2)
    check('Manual selection saves departure', command()['saved']['positions'].get('0', -1), 4, .2)
    check('Manual selection resumes departure', select(0), 4, .2)
    command('play')
    wait(lambda s: s['time'] >= 9)
    command('pause')
    check('Completed chapter starts again', select(0), 0, .2)
    capture('completed-chapter')

    # Returning by natural playback must also invalidate an older stored position.
    fixture('Natürlich erneut betretenes Kapitel')
    seek(12)
    select(0)
    seek(7)
    command('play')
    wait(lambda s: s['time'] >= 17)
    command('pause')
    check('Naturally revisited completed chapter starts again', select(1), 8, .2)

    for offset in [0, -2]:
        fixture(f'Automatischer Werbesprung {offset}')
        seek(3)
        select(2)
        select(0)
        command('configure', skipName='Werbung', offset=offset)
        command('play')
        state = wait(lambda s: s['time'] >= 16)
        command('pause')
        check(f'Automatic skip {offset} creates no departure position',
              '0' in command()['saved'].get('positions', {}), False)
        check(f'Automatic skip {offset} returns to chapter beginning', select(0), 0, .2)
        capture(f'auto-skip-{offset}')

    for kind in ['skipEnd', 'skipChapterEnd', 'naturalEnd']:
        fixture(kind, ['Erstes Kapitel', 'Mittelteil', 'Werbung'])
        seek(18)
        select(0)
        select(2)
        if kind == 'skipEnd':
            command('configure', skipEnd=4)
        elif kind == 'skipChapterEnd':
            command('configure', skipName='Werbung', offset=-2)
            seek(13)
        command('play')
        wait(lambda s: not s['loaded'])
        state = command()
        check(f'{kind} clears completed last chapter', '2' in state['saved'].get('positions', {}), False)
        capture(kind)

    for action in ['next', 'previous', 'forward']:
        fixture(f'Manuell {action}')
        start, target = (12, 0) if action == 'previous' else (4, 8)
        seek(start)
        if action == 'forward':
            command('configure', nearMode=1)
        command(action)
        wait(lambda s: abs(s['time'] - target) < .2)
        check(f'{action} remembers departure', select(1 if action == 'previous' else 0), start, .2)
finally:
    logs = container / 'Documents/Logs'
    if logs.exists():
        shutil.copytree(logs, out / 'Logs', dirs_exist_ok=True)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))
sys.exit(0 if checks and all(c['passed'] for c in checks) else 1)
