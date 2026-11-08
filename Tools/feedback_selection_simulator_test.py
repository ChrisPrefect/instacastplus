#!/usr/bin/env python3
"""Verify multi-selection removes downloaded files and preserves episode entries.

Seeds real episodes, opens a smart list, selects nonadjacent rows, invokes the
actual action-sheet handler, and retains screenshots, SQLite store and logs.
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
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid', required=True)
p.add_argument('--app', required=True, type=Path)
p.add_argument('--evidence', required=True, type=Path)
p.add_argument('--watch-udid', help='Also exercise handoff with the real watch probe app installed by watch_position_resume_simulator_test.py')
args = p.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)


def run(command, check=True, env=None):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    with (out / 'commands.log').open('a') as log:
        log.write(shlex.join(command) + '\n' + result.stdout)
    if check and result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
library = out / 'FeedbackReviewProbe.dylib'
run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
    '-framework', 'UIKit', '-framework', 'AVFoundation', '-framework', 'CoreData', '-I', str(ROOT / 'Classes'),
    str(ROOT / 'Tools/fixtures/feedback_review_probe.m'), '-o', str(library)])
run(['codesign', '-s', '-', str(library)])
run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
directory = container / 'Documents/FeedbackReviewProbe'
directory.mkdir(parents=True, exist_ok=True)
for name in ('command.json', 'reply.json'):
    (directory / name).unlink(missing_ok=True)
with wave.open(str(directory / 'fixture.wav'), 'wb') as audio:
    audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
    audio.writeframes(b'\0\0' * 8000 * 4800)
with wave.open(str(directory / 'download.wav'), 'wb') as audio:
    audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
    audio.writeframes(b'\0\0' * 8000 * 24)
info = plistlib.loads((args.app / 'Info.plist').read_bytes())
(out / 'environment.json').write_text(json.dumps({
    'command': shlex.join([sys.executable, *sys.argv]), 'udid': args.udid, 'sdk': sdk, 'app': str(args.app.resolve()),
    'fixture': 'Four episodes; import real WAV downloads for 0, 1, 2; 3 has no download. Select 0, 2, 3. Episode 0 is a favorite; 2 is unplayed at 2147 seconds.',
    'expected': 'Download löschen removes only selected local files; all episode entries, played states, favorites and positions remain unchanged; unselected download remains.',
    'sourceSHA256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [ROOT / 'Classes/EpisodesTableViewController.m', ROOT / 'Classes/ListEpisodesTableViewController.m']},
    'binarySHA256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in
        [args.app / info['CFBundleExecutable'], args.app / (info['CFBundleExecutable'] + '.debug.dylib')] if path.exists()},
    'scope': 'Real UIKit selection and action handler, database persistence and list reload; no finger automation. Optional handoff bridges the actual watch payload through a file, not the radio.',
}, indent=2))
run(['xcrun', 'simctl', 'launch', args.udid, BUNDLE, '-AppleLanguages', '(de)'],
    env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
checks = []


def command(action='status', **params):
    request = dict(id=str(uuid.uuid4()), action=action, **params)
    tmp = directory / 'command.tmp'
    tmp.write_text(json.dumps(request))
    tmp.replace(directory / 'command.json')
    deadline = time.monotonic() + 30
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


def wait(predicate):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        state = command()
        if predicate(state):
            return state
        time.sleep(.1)
    raise AssertionError(f'Condition not reached: {state}')


def check(name, passed, state):
    checks.append(dict(name=name, passed=bool(passed), observed=state))
    print(name, 'PASS' if passed else 'FAIL', flush=True)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))


def capture(name):
    command('capture')
    shutil.copy(directory / 'screen.png', out / (name + '.png'))


try:
    command('fixture')
    state = wait(lambda s: len(s['loadedHashes']) >= 4)
    hashes = [e['hash'] for e in state['episodes']]
    command('cacheFixture')
    baseline = wait(lambda s: s['operation'] == 'imported' and all(e['cached'] and e['fileExists'] for e in s['episodes'][:3]))
    command('menu', indices=[0, 2, 3])
    state = wait(lambda s: len(s['actions']) >= 4)
    capture('selection-menu')
    check('Action explicitly says Download löschen', 'Download löschen' in state['actions'] or 'Delete Download' in state['actions'], state)
    if any(title in state['actions'] for title in ('Löschen', 'Delete', 'Download löschen', 'Delete Download')):
        command('invokeDelete')
        state = wait(lambda s: all(not s['episodes'][i]['fileExists'] for i in (0, 2)) and not s['editing'])
        check('Selected download files are physically removed', all(not state['episodes'][i]['cached'] for i in (0, 2)), state)
        check('Unselected download remains available', state['episodes'][1]['fileExists'] and state['episodes'][1]['cached'], state)
        command('reload')
        time.sleep(.5)
        state = command()
        check('Episode entries and listening state are preserved', all(
            e[k] == baseline['episodes'][i][k] for i, e in enumerate(state['episodes'])
            for k in ('hash', 'archived', 'consumed', 'position', 'starred')), state)
        check('All episode rows remain visible', all(h in state['loadedHashes'] for h in hashes), state)
        capture('after-delete')
    if args.watch_udid:
        # Both apps execute their production playback and synchronization paths.
        # The simulator transport is bridged at the message boundary, unchanged.
        watch_bundle = 'com.iteconomy.instacastplus.watchkitapp'
        run(['xcrun', 'simctl', 'launch', args.watch_udid, watch_bundle])
        watch_container = Path(run(['xcrun', 'simctl', 'get_app_container', args.watch_udid, watch_bundle, 'data']))
        watch_directory = watch_container / 'Documents/PositionProbe'

        def watch(action='status', **params):
            request = dict(id=str(uuid.uuid4()), action=action, **params)
            tmp = watch_directory / 'command.tmp'
            tmp.write_text(json.dumps(request))
            tmp.replace(watch_directory / 'command.json')
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                try:
                    reply = json.loads((watch_directory / 'reply.json').read_text())
                    if reply['id'] == request['id']:
                        with (out / 'watch-observations.jsonl').open('a') as log:
                            log.write(json.dumps({'request': request, 'reply': reply}) + '\n')
                        assert 'error' not in reply, reply
                        return reply
                except FileNotFoundError:
                    pass
                time.sleep(.1)
            raise AssertionError(f'Watch did not reply: {request}')

        watch('fixture')
        # The probe may retain the previous fixture player: release its active audio
        # through the ordinary pause and seek controls before simulating this stop.
        watch('seek', position=3319)
        state = watch('play')
        assert state['started'], state
        watch('stall')
        time.sleep(2)
        old_watch_position = json.loads((watch_directory / 'outbound.json').read_text())['position']
        command('fixture')
        command('watchFixture')
        wait(lambda s: s['ready'] and abs(s['time'] - 4200) < 1)
        watch('phone', position=4200)
        time.sleep(1.1)
        watch('seek', position=old_watch_position)
        control = json.loads((watch_directory / 'outbound.json').read_text())
        assert control['selectionIdentifier'] == 'position-probe' and control['watchEventRevision'] > 0, control
        command('watchPayload', payload=control)
        state = wait(lambda s: abs(s['time'] - old_watch_position) < 1)
        check('A new deliberate watch seek reaches the iPhone through the same message handler',
              state['episodes'][0]['position'] == old_watch_position, state)
        command('seek', position=4200)
        wait(lambda s: abs(s['time'] - 4200) < 1)
        command('play')
        time.sleep(2)
        phone_state = command('pause')
        phone_position = phone_state['episodes'][0]['position']
        assert phone_position >= 4200, phone_state
        watch('phone', position=phone_position)
        time.sleep(6)
        watch('flush')
        payload = json.loads((watch_directory / 'outbound.json').read_text())
        (out / 'actual-watch-handoff-payload.json').write_text(json.dumps(payload, indent=2))
        assert payload['position'] < 3340, payload
        command('watchPayload', payload=payload)
        time.sleep(1)
        state = command()
        check('Old watch report cannot rewind the paused iPhone from over 70 minutes',
              abs(state['time'] - phone_position) < 1 and state['episodes'][0]['position'] == phone_position, state)
        command('play')
        time.sleep(2)
        state = command('pause')
        check('iPhone resumes at the newer saved listening position', state['time'] >= phone_position + 1, state)
        capture('handoff-after-resume')
        saved_position = state['episodes'][0]['position']
        run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE])
        run(['xcrun', 'simctl', 'launch', args.udid, BUNDLE, '-AppleLanguages', '(de)'],
            env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
        state = wait(lambda s: s['restoredEpisodeHash'] == 'position-probe')
        check('App restart restores the newer position from persistent storage',
              state['restoredEpisodePosition'] == saved_position, state)
        command('resume')
        state = wait(lambda s: s['ready'] and not s['paused'])
        check('Restored episode starts at the saved position after restart',
              saved_position - 1 <= state['time'] <= saved_position + 3, state)
        command('pause')
        run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / 'after-restart.png')])
        shutil.copytree(watch_container / 'Library/Application Support/WatchManifest', out / 'WatchManifest', dirs_exist_ok=True)
finally:
    for name in ('Logs', 'Data'):
        if (container / 'Documents' / name).exists():
            shutil.copytree(container / 'Documents' / name, out / name, dirs_exist_ok=True)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))
sys.exit(0 if checks and all(c['passed'] for c in checks) else 1)
