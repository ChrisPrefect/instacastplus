#!/usr/bin/env python3
"""Verify real feed refresh preserves the visible Ungespielt episode and its position.

Uses a disposable booted simulator, a localhost RSS server and the app's real
subscribe/parser/merge/sidebar/paging paths. A test-only injected driver calls
production handlers and records CADisplayLink geometry; no method is replaced.
The default cases use UIKit scrolling; --case native also runs a supplied
NativeScroll XCTest UI project with genuine drag events. --evidence retains the
exact command, environment, inputs, HTTP traffic, frames, screenshots and checks.
"""
import argparse
import datetime
import email.utils
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--case', choices=['all', 'first25', 'deep', 'paging', 'mutation', 'native'], default='all')
    parser.add_argument('--native-ui-project', type=Path, help='Built NativeScroll XCTest UI project for --case native')
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)
    checks = []
    cases = ['first25', 'deep', 'paging', 'mutation'] if args.case == 'all' else [args.case]
    if args.case == 'native' and not args.native_ui_project:
        parser.error('--case native requires --native-ui-project')

    def run(command, check=True, env=None):
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(command) + '\n' + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout)
        return result.stdout.strip()

    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
    runtime, device = next((runtime, d) for runtime, group in devices.items() for d in group if d['udid'] == args.udid)
    assert device['state'] == 'Booted', 'Boot the disposable simulator first'
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    library = out / 'ListRefreshScrollProbe.dylib'
    source = ROOT / 'Tools/fixtures/list_refresh_scroll_probe.m'
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
         '-isysroot', sdk, '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'QuartzCore', '-framework', 'CoreGraphics',
         str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
    directory = container / 'Documents/ListRefreshScrollProbe'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ['command.json', 'reply.json']:
        (directory / name).unlink(missing_ok=True)
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    executable = info['CFBundleExecutable']
    environment = {
        'command': shlex.join([sys.executable, *sys.argv]), 'device': device, 'runtime': runtime,
        'sdk': sdk, 'app': str(args.app.resolve()), 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'cases': cases,
        'appBinarySHA256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in [args.app / executable, args.app / (executable + '.debug.dylib')] if p.exists()},
        'sourceSHA256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [source, Path(__file__).resolve(), ROOT / 'Classes/ListEpisodesTableViewController.m']},
        'expected': ('Refresh waits for the native gesture, keeps the list populated and preserves the current visible episode and screen Y at replacement'
                     if args.case == 'native' else 'Same visible episode hash and screen Y (within 1 point) in every displayed frame and after real refresh completion'),
        'scope': ('Real app, HTTP parser, Core Data merge, list KVO, sidebar and UIKit scrolling; '
                  + ('XCTest finger gestures' if args.case == 'native' else 'programmatic UIKit scrolling')
                  + '; no customer device reproduction'),
    }
    (out / 'environment.json').write_text(json.dumps(environment, indent=2))

    fixture = {'body': b'', 'case': '', 'count': 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.split('?')[0] != '/feed.xml':
                self.send_error(404)
                return
            body = fixture['body']
            with (out / 'http.jsonl').open('a') as log:
                log.write(json.dumps({'time': time.time(), 'path': self.path, 'case': fixture['case'],
                                      'count': fixture['count'], 'sha256': hashlib.sha256(body).hexdigest()}) + '\n')
            self.send_response(200)
            self.send_header('Content-Type', 'application/rss+xml; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *unused):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f'http://127.0.0.1:{server.server_port}'
    run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}',
         args.udid, BUNDLE, '-AppleLanguages', '(de)'],
        env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

    def command(action='status', **parameters):
        request = dict(id=str(uuid.uuid4()), action=action, **parameters)
        temporary = directory / 'command.tmp'
        temporary.write_text(json.dumps(request))
        temporary.replace(directory / 'command.json')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                reply = json.loads((directory / 'reply.json').read_text())
                if reply['id'] == request['id']:
                    with (out / 'observations.jsonl').open('a') as log:
                        log.write(json.dumps({'request': request, 'reply': reply}) + '\n')
                    assert 'error' not in reply, reply
                    assert not reply.get('operationError'), reply
                    return reply
            except FileNotFoundError:
                pass
            time.sleep(.05)
        raise AssertionError(f'No app response: {request}')

    def wait(predicate, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = command()
            if predicate(state):
                return state
            time.sleep(.05)
        raise AssertionError(f'App condition not reached: {state}')

    def settle(predicate=lambda s: True):
        # Observe beyond the production one-second coalescing deadline. This is a
        # test settling window, never a delay inserted into the app implementation.
        deadline = time.monotonic() + 30
        stable_since = None
        signature = None
        while time.monotonic() < deadline:
            state = command()
            current = (state['generation'], state['loaded'], state['listCount'], state['offsetY'], state['countChangeCount'])
            valid = predicate(state) and not state['loadingPage'] and not state['refreshing'] and state['statisticsLoaded']
            if not valid or current != signature:
                stable_since = time.monotonic() if valid else None
                signature = current
            elif stable_since and time.monotonic() - stable_since >= 1.5:
                return state
            time.sleep(.1)
        raise AssertionError(f'List never settled: {state}')

    def publish(case, count, seed):
        items = []
        for index in reversed(range(count)):
            date = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(hours=index)
            items.append(f'<item><title>Folge {index:03d} — Scrollposition</title><guid isPermaLink="false">{seed}-{index}</guid>'
                         f'<pubDate>{email.utils.format_datetime(date)}</pubDate><description>Deterministische Folge {index}.</description>'
                         f'<itunes:duration>600</itunes:duration><enclosure url="{base}/audio-{seed}-{index}.mp3" length="2400000" type="audio/mpeg"/></item>')
        body = ('<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">'
                f'<channel><title>Scroll Refresh Regression</title><link>{base}/</link><description>Scroll fixture</description>'
                '<language>de</language>' + ''.join(items) + '</channel></rss>').encode()
        fixture.update(body=body, case=case, count=count)
        (out / f'{case}-{count}.xml').write_bytes(body)

    def capture(name):
        state = command('capture')
        (out / f'{name}.json').write_text(json.dumps(state, indent=2))
        shutil.copy(directory / 'screen.png', out / f'{name}-app.png')
        run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / f'{name}.png')])

    def record(name, passed, **details):
        item = dict(name=name, passed=bool(passed), **details)
        checks.append(item)
        (out / 'checks.json').write_text(json.dumps(checks, indent=2))
        print(json.dumps(item), flush=True)

    def refresh_check(case, count, seed, label, paging_row=None):
        publish(case, count, seed)
        before = command('monitor') if paging_row is None else command()
        capture(f'{case}-{label}-before')
        completion = before['completionCount']
        finishes = before['finishCount']
        start = command('refresh', **({'row': paging_row} if paging_row is not None else {}))
        if paging_row is not None:
            record(f'{case}-{label}: page request overlaps refresh start', start.get('pagingInFlightAtRefresh'), start=start)
        wait(lambda s: s['completionCount'] > completion and s['finishCount'] > finishes and s['feedEpisodes'] == count)
        after = settle(lambda s: s['listCount'] == count)
        command('stop')
        frames = json.loads((directory / 'frames.json').read_text())
        shutil.copy(directory / 'frames.json', out / f'{case}-{label}-frames.json')
        shutil.copy(directory / 'events.json', out / f'{case}-{label}-events.json')
        capture(f'{case}-{label}-after')
        reference = frames[0]
        missing = [frame for frame in frames if not frame['anchorPresent'] or not frame['screenVisible']]
        drift = [abs(frame['anchorScreenY'] - reference['anchorScreenY']) for frame in frames if frame['anchorPresent']]
        record(f'{case}-{label}: visible episode and pixel position survive every frame',
               len(frames) > 2 and not missing and max(drift, default=99999) <= 1,
               anchorHash=reference['anchorHash'], frames=len(frames), missingFrames=len(missing),
               maxDriftPoints=max(drift, default=None), before=reference, after=after)
        record(f'{case}-{label}: original episode stays visible after refresh',
               after['anchorPresent'] and abs(after['anchorScreenY'] - reference['anchorScreenY']) <= 1,
               expectedScreenY=reference['anchorScreenY'], observedScreenY=after.get('anchorScreenY'))
        if label != 'unchanged':
            record(f'{case}-{label}: production list KVO observed new count', after['countChangeCount'] > before['countChangeCount'])

    def mutation_check(count, seed):
        publish('mutation', count + 1, seed)
        before = command('monitor')
        target = command('armMutation', row=10)
        capture('mutation-before')
        command('refresh')
        wait(lambda s: s['completionCount'] > before['completionCount']
             and s['finishCount'] > before['finishCount'] and s['feedEpisodes'] == count + 1
             and s['mutationTriggered'])
        after = settle(lambda s: s['listCount'] == count)
        command('stop')
        shutil.copy(directory / 'frames.json', out / 'mutation-frames.json')
        shutil.copy(directory / 'events.json', out / 'mutation-events.json')
        capture('mutation-after')
        result = after['mutationResult']
        record('mutation: real played action runs after target enters replacement first page',
               result.get('stagedContainsEpisode') and result.get('visibleCell')
               and result.get('stagedCount') == 25 and result.get('actionCompleted')
               and result.get('removedImmediately') and after['mutationConsumed'], result=result)
        record('mutation: played episode remains absent after refresh replacement',
               target['mutationHash'] not in after['loadedHashes'],
               removedHash=target['mutationHash'], observedHashes=after['loadedHashes'])
        frames = json.loads((directory / 'frames.json').read_text())
        mutation_frames = [frame for frame in frames if frame['mutationTriggered']]
        record('mutation: played episode never reappears in an intermediate frame',
               mutation_frames and not any(frame['mutationPresent'] for frame in mutation_frames),
               observedFrames=len(mutation_frames),
               reappearedFrames=sum(frame['mutationPresent'] for frame in mutation_frames))
        # Continue via UIKit scrolling to verify replacement offsets did not skip
        # or duplicate any episode when the backing query lost the played row.
        for _ in range(10):
            state = command()
            if state['reachedListEnd']:
                break
            command('scroll', row=state['loaded'] - 1)
            wait(lambda s: (s['loaded'] > state['loaded'] or s['reachedListEnd']) and not s['loadingPage'])
        complete = settle()
        membership = command('membership')
        expected = membership['expectedHashes']
        actual = membership['loadedHashes']
        record('mutation: full displayed membership and paging match the production list',
               complete['reachedListEnd'] and len(expected) == count and actual == expected
               and len(actual) == len(set(actual)) and target['mutationHash'] not in actual,
               expectedHashes=expected, observedHashes=actual, reachedListEnd=complete['reachedListEnd'])
        capture('mutation-all-pages')

    def native_check(count, seed):
        publish('native', count + 1, seed)
        before = command('monitor')
        capture('native-before')
        command('refreshDuringDrag')
        project = args.native_ui_project.resolve()
        run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScroll',
             '-destination', 'platform=iOS Simulator,id=' + args.udid,
             '-derivedDataPath', str(project.parent / 'DerivedData'), '-parallel-testing-enabled', 'NO',
             '-resultBundlePath', str(out / 'NativeOverlap.xcresult'), 'test-without-building'])
        after = settle(lambda s: s['completionCount'] > before['completionCount'] and s['listCount'] == count + 1)
        command('stop')
        frames = json.loads((directory / 'frames.json').read_text())
        events = json.loads((directory / 'events.json').read_text())
        shutil.copy(directory / 'frames.json', out / 'native-frames.json')
        shutil.copy(directory / 'events.json', out / 'native-events.json')
        capture('native-after')
        starts = [event for event in events if event['event'] == 'native-refresh-start']
        completions = [event for event in events if event['event'] == 'refresh-completion'
                       and event['clock'] > starts[0]['state']['clock']] if starts else []
        completion_frame = min(frames, key=lambda frame: abs(frame['clock'] - completions[0]['clock'])) if completions else None
        active = [frame for frame in frames if frame['dragging'] or frame['decelerating']]
        changes = [(a, b) for a, b in zip(frames, frames[1:]) if a['loaded'] != b['loaded']]
        record('native: HTTP refresh overlaps real finger scrolling and waits for the gesture',
               len(starts) == 1 and starts[0]['state']['dragging'] and completion_frame
               and completion_frame['dragging'] and completions[0]['success']
               and active and max(frame['offsetY'] for frame in active) - min(frame['offsetY'] for frame in active) > 100
               and changes and not any(frame['dragging'] or frame['decelerating'] for pair in changes for frame in pair),
               starts=starts, completionFrame=completion_frame, activeFrames=len(active))
        record('native: list remains populated throughout real scrolling and refresh',
               frames and all(frame['loaded'] > 0 for frame in frames), frames=len(frames))
        swaps = [(a, b) for a, b in changes
                 if not any(f['dragging'] or f['decelerating'] for f in [a, b])]
        record('native: completed replacement preserves the episode at the end of scrolling',
               swaps and all(a.get('topVisibleHash') == b.get('topVisibleHash')
                             and abs(a['topVisibleY'] - b['topVisibleY']) <= 1 for a, b in swaps),
               swaps=swaps, finalOffset=after['offsetY'])

    try:
        for _ in range(10):
            startup = command('dismissOnboarding')
            if not startup['presentedController']:
                break
            time.sleep(.3)
        assert not command()['presentedController'], 'Dismiss the actual startup modal before measuring the list'
        for case in cases:
            command('cleanup')
            wait(lambda s: s['operation'] == 'cleanup-done' and s['subscribedFeeds'] == 0)
            count = 20 if case == 'first25' else 80
            seed = str(uuid.uuid4())
            publish(case, count, seed)
            command('subscribe', url=base + '/feed.xml?case=' + seed)
            wait(lambda s: s['operation'] == 'subscribe-done' and s['feedEpisodes'] == count)
            command('open')
            settle(lambda s: s['screenVisible'] and s['loaded'] >= min(count, 25) and s['listCount'] == count)
            if case in ['deep', 'mutation']:
                while command()['loaded'] <= 55:
                    previous = command()['loaded']
                    command('scroll', row=previous - 5)
                    wait(lambda s: s['loaded'] > previous and not s['loadingPage'])
                command('scroll', row=8 if case == 'mutation' else 55)
                settle()
            elif case in ['first25', 'native']:
                command('scroll', row=8)
                settle()
            if case == 'native':
                native_check(count, seed)
            elif case == 'mutation':
                mutation_check(count, seed)
            elif case == 'paging':
                refresh_check(case, count + 1, seed, 'insert', paging_row=command()['loaded'] - 5)
            else:
                refresh_check(case, count + 1, seed, 'insert')
                refresh_check(case, count + 1, seed, 'unchanged')
                refresh_check(case, count + 2, seed, 'repeat')
    except Exception as error:
        record('Harness completed all requested flows', False, error=repr(error))
        raise
    finally:
        server.shutdown()
        if (container / 'Documents/Logs').exists():
            shutil.copytree(container / 'Documents/Logs', out / 'Logs', dirs_exist_ok=True)
        report = {'passed': bool(checks) and all(check['passed'] for check in checks), 'checks': checks,
                  'environment': environment, 'fixtures': sorted(p.name for p in out.glob('*.xml'))}
        (out / 'report.json').write_text(json.dumps(report, indent=2))
    return 0 if all(check['passed'] for check in checks) else 1


if __name__ == '__main__':
    sys.exit(main())
