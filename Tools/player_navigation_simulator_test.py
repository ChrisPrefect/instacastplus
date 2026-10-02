#!/usr/bin/env python3
"""Real UIKit E2E: title -> podcast -> subscriptions, preserving both scroll positions.

Use a dedicated simulator named Instacast Navigation Regression. The test-only
injected driver creates 45 podcasts/144 episodes and local WAV audio, invokes the
production row/player actions, and records every CADisplayLink frame. It replaces
no app methods. This tests production navigation, not native finger recognition.
Evidence includes commands, inputs, hashes, logs, screenshots and transition video.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
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

    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
    runtime, device = next((r, d) for r, group in devices.items() for d in group if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Navigation Regression' and device['state'] == 'Booted'
    source = ROOT / 'Tools/fixtures/player_navigation_probe.m'
    library = out / 'PlayerNavigationProbe.dylib'
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
         '-isysroot', run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']),
         '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'QuartzCore', str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
    directory = container / 'Documents/PlayerNavigationProbe'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ['command.json', 'reply.json']:
        (directory / name).unlink(missing_ok=True)
    with wave.open(str(directory / 'fixture.wav'), 'wb') as wav:
        wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 8000 * 180)
    shutil.copy2(directory / 'fixture.wav', out / 'fixture.wav')
    files = [source, Path(__file__).resolve(), *[ROOT / 'Classes' / p for p in [
        'PlayerController.m', 'MainViewController_4.m', 'SubscriptionsTableViewController.m',
        'FeedEpisodesTableViewController.m', 'EpisodesTableViewCell.h', 'EpisodesTableViewCell.m', 'Defines.h', 'Defines.m']]]
    (out / 'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable, *sys.argv]), device=device, runtime=runtime,
        app=str(args.app.resolve()), fixtures='45 feeds; feed 25 has 100 episodes; scroll rows 22 and 35',
        driver='Production actions, Core Data, local WAV, CADisplayLink; no method replacements or native finger events',
        expected='Podcast behind every revealed player-dismiss frame; both tables at their saved offset from their first visible frame',
        sourceSHA256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        binarySHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.app.glob('InstacastPlus*') if p.is_file()}), indent=2))
    run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid, BUNDLE],
        env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

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
        raise AssertionError(f'No reply: {request}')

    def wait(predicate):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = command()
            if predicate(state):
                return state
            time.sleep(.05)
        raise AssertionError(f'Condition not reached: {state}')

    def capture(name):
        command('capture')
        shutil.copy2(directory / 'app.png', out / f'{name}-app.png')
        run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / f'{name}.png')])

    def transition(action, name):
        command('monitor')
        command(action)
        # Test observation window covers the native transition and late restoration.
        time.sleep(1.2)
        state = command('stop')
        data = json.loads((directory / 'frames.json').read_text())
        shutil.copy2(directory / 'frames.json', out / f'{name}-frames.json')
        capture(name)
        return data, state

    checks = []

    def record(name, passed, **details):
        item = dict(name=name, passed=bool(passed), **details)
        checks.append(item)
        (out / 'checks.json').write_text(json.dumps(checks, indent=2))
        print(json.dumps(item), flush=True)

    command('seed')
    wait(lambda s: s.get('subscriptions', {}).get('rows', 0) >= 45)
    time.sleep(1)
    command('scroll', row=22)
    subscriptions = command()['subscriptions']
    capture('subscriptions-reference')
    command('selectFeed')
    wait(lambda s: s.get('episodes', {}).get('rows') == 100)
    time.sleep(.7)
    command('scroll', row=35)
    episodes = command()['episodes']
    capture('episodes-reference')
    assert subscriptions['offset'] > 500 and episodes['offset'] > 500
    command('player')
    wait(lambda s: s['playerPresented'] and not s['playerTransition'])
    close_frames, _ = transition('closePlayer', 'ordinary-close')
    visible = [f['episodes'] for f in close_frames if f.get('episodes', {}).get('inWindow')]
    record('ordinary player close preserves the visible episode and position', visible and all(
        f['firstRow'] == episodes['firstRow'] and abs(f['firstRowY'] - episodes['firstRowY']) < 1
        and abs(f['offset'] - episodes['offset']) < 1 for f in visible))
    transition('back', 'original-back')
    command('player')
    wait(lambda s: s['playerPresented'] and not s['playerTransition'])
    capture('player')
    video_cmd = ['xcrun', 'simctl', 'io', args.udid, 'recordVideo', '--codec=h264', '--force', str(out / 'transitions.mp4')]
    (out / 'commands.log').open('a').write(shlex.join(video_cmd) + '\n')
    with (out / 'video.log').open('w') as log:
        video = subprocess.Popen(video_cmd, stdout=log, stderr=log)
        try:
            time.sleep(.3)
            frames, after = transition('title', 'title-to-podcast')
            revealed = [f for f in frames if not f['playerPresented'] or f['playerY'] > 1]
            wrong = [f for f in revealed if f['top'] != 'FeedEpisodesTableViewController']
            record('title goes directly to podcast in every revealed frame', len(revealed) > 2 and not wrong,
                   frames=len(revealed), wrongFrames=len(wrong), firstWrong=wrong[0] if wrong else None)
            visible = [f['episodes'] for f in revealed if f.get('episodes', {}).get('inWindow')]
            drift = [abs(f['offset'] - episodes['offset']) for f in visible]
            record('podcast episodes restore before their first visible frame', bool(drift) and max(drift) < 1,
                   expected=episodes['offset'], maxDrift=max(drift, default=None))
            record('podcast restores the same visible episode and screen position', visible and all(
                f['firstRow'] == episodes['firstRow'] and abs(f['firstRowY'] - episodes['firstRowY']) < 1 for f in visible),
                expectedRow=episodes['firstRow'], expectedY=episodes['firstRowY'])
            final_episodes = after['episodes']
            frames, after = transition('back', 'back-to-subscriptions')
            visible = [f['subscriptions'] for f in frames if f.get('subscriptions', {}).get('inWindow')]
            drift = [abs(f['offset'] - subscriptions['offset']) for f in visible]
            record('subscriptions restore before their first visible frame', bool(drift) and max(drift) < 1,
                   expected=subscriptions['offset'], maxDrift=max(drift, default=None))
            record('both destinations finish at their saved position',
                   abs(after['subscriptions']['offset'] - subscriptions['offset']) < 1
                   and abs(final_episodes['offset'] - episodes['offset']) < 1)
        finally:
            video.send_signal(signal.SIGINT)
            video.wait(timeout=20)
    return 0 if all(c['passed'] for c in checks) else 1


if __name__ == '__main__':
    sys.exit(main())
