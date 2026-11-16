#!/usr/bin/env python3
"""Real Watch download -> HTTP failure -> retry -> playback -> persistence -> removal.

Creates and deletes its own watchOS simulator, and never installs on a user's
device. Retains commands, fixtures, HTTP requests, app observations and images.
The additional native row-render artifact detects visual truncation at both
Watch widths. Accessibility exposes untruncated source labels, so it cannot
reliably detect this failure; OCR checks pixels from the production SwiftUI row,
rendered on watchOS (not a copied implementation). The row can fail through
column width, line limits, font/environment or proposed-size constraints.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus.watchkitapp'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence', required=True, type=Path)
    p.add_argument('--locale', choices=['de', 'en'], default='de')
    p.add_argument('--app', type=Path, help='Reuse an instrumented app from an earlier run of this test')
    args = p.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(cmd, check=True, env=None):
        result = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(cmd) + '\n' + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout[-6000:])
        return result.stdout.strip()

    shadow = out / 'Source'
    shadow.mkdir(exist_ok=True)
    for source in ROOT.iterdir():
        target = shadow / source.name
        if source.name in ('build', 'InstacastWatch', 'Instacast.xcodeproj', '.git') or target.exists():
            continue
        target.symlink_to(source, target_is_directory=source.is_dir())
    for name in ['Instacast.xcodeproj', 'InstacastWatch']:
        shutil.copytree(ROOT / name, shadow / name, dirs_exist_ok=True)
    views = shadow / 'InstacastWatch/WatchEpisodeViews.swift'
    views.write_text(views.read_text() + '\n' + (ROOT / 'Tools/fixtures/watch_download_review_probe.swift').read_text())
    entry = shadow / 'InstacastWatch/InstacastWatchApp.swift'
    entry.write_text(entry.read_text().replace('await WatchManifestStore.shared.load()',
        'await WatchManifestStore.shared.load()\n            WatchDownloadReviewProbe.start()'))
    products = out / 'Products'
    build = ['xcodebuild', '-project', str(shadow / 'Instacast.xcodeproj'), '-target', 'InstacastWatch',
             '-configuration', 'Debug', '-sdk', 'watchsimulator', 'ARCHS=arm64',
             f'SYMROOT={products}', f'OBJROOT={out / "Intermediates"}',
             'CODE_SIGNING_ALLOWED=NO', 'build']
    if args.app:
        app = args.app.resolve()
    else:
        with (out / 'build.log').open('w') as log:
            result = subprocess.run(build, stdout=log, stderr=subprocess.STDOUT)
        assert result.returncode == 0, f'Build failed: {out / "build.log"}'
        app = products / 'Debug-watchsimulator/InstacastWatch.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    assert info['UIBackgroundModes'] == ['audio'], info
    audio = out / 'fixture.wav'
    with wave.open(str(audio), 'wb') as w:
        w.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        w.writeframes(b'\0\0' * 8000 * 180)
    state = {'available': False}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            with (out / 'http.jsonl').open('a') as log:
                log.write(json.dumps({'path': self.path, 'available': state['available']}) + '\n')
            if not state['available']:
                self.send_error(503)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Content-Length', str(audio.stat().st_size))
            self.end_headers()
            self.wfile.write(audio.read_bytes())

        def log_message(self, *_):
            pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    udid = run(['xcrun', 'simctl', 'create', 'Instacast Watch Download Review',
                'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-42mm',
                'com.apple.CoreSimulator.SimRuntime.watchOS-27-2'])
    checks = []
    directory = None

    def check(name, passed, observed):
        checks.append({'name': name, 'passed': bool(passed), 'observed': observed})
        (out / 'checks.json').write_text(json.dumps(checks, indent=2))
        print(name, 'PASS' if passed else 'FAIL', flush=True)

    try:
        run(['xcrun', 'simctl', 'boot', udid])
        run(['xcrun', 'simctl', 'bootstatus', udid, '-b'])
        run(['xcrun', 'simctl', 'install', udid, str(app)])
        container = Path(run(['xcrun', 'simctl', 'get_app_container', udid, BUNDLE, 'data']))
        directory = container / 'Documents/DownloadReview'
        directory.mkdir(parents=True, exist_ok=True)
        (out / 'environment.json').write_text(json.dumps({
            'command': shlex.join([sys.executable, *sys.argv]), 'udid': udid, 'locale': args.locale,
            'build': shlex.join(build) if not args.app else 'Reused instrumented app: ' + str(app), 'info': info,
            'binarySHA256': hashlib.sha256((app / info['CFBundleExecutable']).read_bytes()).hexdigest(),
            'sourceSHA256': hashlib.sha256((ROOT / 'InstacastWatch/WatchEpisodeViews.swift').read_bytes()).hexdigest(),
            'fixture': '180-second mono 8 kHz PCM WAV, HTTP 503 then 200 at same URL',
            'expected': 'Full error and retry readable at both Watch widths; successful retry, play, seek, pause, durable relaunch and removal.',
            'scope': 'Real watchOS app/store/download/player/rendering. Commands invoke production handlers. No physical WatchConnectivity or hardware audio test.',
        }, indent=2))

        def launch():
            run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}',
                 f'--stderr={out / "stderr.log"}', udid, BUNDLE, '-AppleLanguages', f'({args.locale})'])

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
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(.1)
            raise AssertionError(f'No reply: {request}')

        def wait(predicate):
            deadline = time.monotonic() + 50
            while time.monotonic() < deadline:
                reply = command()
                if predicate(reply):
                    return reply
                time.sleep(.2)
            raise AssertionError(f'Unmet condition: {reply}')

        launch()
        ocr = out / 'ocr.swift'
        ocr.write_text('''import Foundation
import Vision
for path in CommandLine.arguments.dropFirst() {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["de-DE", "en-US"]
    try VNImageRequestHandler(url: URL(fileURLWithPath: path)).perform([request])
    print((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
}
''')
        def capture_error(label, reason):
            command('render')
            shutil.copytree(directory, out / label, dirs_exist_ok=True)
            run(['xcrun', 'simctl', 'io', udid, 'screenshot', str(out / f'{label}-screen.png')])
            for width in [160, 184]:
                recognized = run(['swift', str(ocr), str(out / f'{label}/row-{width}.png')])
                # SwiftUI hyphenates German words at a line break. Join only
                # those visible word continuations; an ellipsis still fails.
                unhyphenated = re.sub(r'(?<=\w)[-\u00ad]\s+(?=\w)', '', recognized)
                visible = re.sub(r'\W', '', unhyphenated).casefold()
                expected_reason = re.sub(r'\W', '', reason).casefold()
                expected_retry = 'tippenzumwiederholen' if args.locale == 'de' else 'taptoretry'
                check(f'{label}: error and retry remain readable at width {width}',
                      expected_reason in visible and expected_retry in visible, recognized)

        command('fixture', url='https://example.invalid/episode.wav', bytes=audio.stat().st_size)
        failed = wait(lambda r: r.get('episode', {}).get('status') == 'failed')
        check('Reported DNS failure reaches failed state', bool(failed['episode'].get('lastError')), failed)
        capture_error('dns-failed', failed['episode']['lastError'])
        command('fixture', url=f'http://127.0.0.1:{server.server_port}/episode.wav', bytes=audio.stat().st_size)
        command('retry')
        failed = wait(lambda r: r.get('episode', {}).get('status') == 'failed' and
                      '503' in r['episode'].get('lastError', ''))
        check('Real HTTP error reaches failed state', '503' in failed['episode']['lastError'], failed)
        capture_error('http-failed', failed['episode']['lastError'])
        state['available'] = True
        command('retry')
        downloaded = wait(lambda r: r.get('episode', {}).get('status') == 'downloaded')
        check('Retry downloads and validates complete audio', downloaded['fileExists'] and
              downloaded['episode']['actualFileSize'] == audio.stat().st_size and
              downloaded['episode']['actualDuration'] == 180 and downloaded['downloadedCount'] == 1, downloaded)
        played = command('play')
        check('Downloaded episode plays from stored position', played['started'] and played['isPlaying'] and
              abs(played['currentPosition'] - downloaded['episode']['lastPlaybackPosition']) < 1, played)
        progressed = wait(lambda r: r['currentPosition'] > 61)
        check('Real audio playback advances', progressed['isPlaying'], progressed)
        command('seek')
        paused = command('pause')
        check('Seek and pause persist actual position', not paused['isPlaying'] and
              90 <= paused['episode']['lastPlaybackPosition'] <= 92, paused)
        command('render')
        shutil.copytree(directory, out / 'downloaded', dirs_exist_ok=True)
        run(['xcrun', 'simctl', 'terminate', udid, BUNDLE])
        launch()
        restored = command()
        check('Relaunch restores file and progress', restored['fileExists'] and
              restored['episode']['status'] == 'downloaded' and
              restored['episode']['lastPlaybackPosition'] == paused['episode']['lastPlaybackPosition'], restored)
        command('remove')
        pending = wait(lambda r: r.get('episode', {}).get('status') == 'removing' and not r['fileExists'])
        check('Remove deletes audio and retains pending acknowledgement', pending['downloadedCount'] == 0 and
              not list((container / 'Documents/Episodes').glob('*')), pending)
        # Simulator WatchConnectivity cannot send. Deliver the phone acknowledgement
        # through the real handler after verifying the durable offline tombstone.
        command('ackRemoval')
        removed = wait(lambda r: 'episode' not in r)
        check('Phone acknowledgement clears manifest entry', removed['downloadedCount'] == 0 and
              not list((container / 'Documents/Episodes').glob('*')), removed)
    finally:
        server.shutdown()
        server.server_close()
        run(['xcrun', 'simctl', 'shutdown', udid], check=False)
        run(['xcrun', 'simctl', 'delete', udid])
        (out / 'cleanup.json').write_text(json.dumps({'deletedSimulator': udid, 'httpServerClosed': True}))
    return 0 if checks and all(c['passed'] for c in checks) else 1


if __name__ == '__main__':
    sys.exit(main())
