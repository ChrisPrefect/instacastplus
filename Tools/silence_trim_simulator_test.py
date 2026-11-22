#!/usr/bin/env python3
"""Real app E2E for pause shortening (ICSilenceTrimPlayer) in the iOS simulator.

The test injects Tools/fixtures/silence_trim_probe.m into the unchanged app, serves a real
podcast MP3 over local HTTP (with Range support), downloads it through CacheManager and drives
playback through PlaybackManager / AudioSession / PlaybackViewController. It checks:

  A  feature off: AVPlayer plays, the speed button has no menu (old behaviour)
  B  enabling the feature while playing switches to the engine without losing the position
  C  the engine shortens pauses (episode time runs ahead of wall-clock time)
  D  pause stores the episode position, resume continues
  E  seek lands on the requested source time
  F  playback speed is applied on top of pause shortening
  G  level changes from the menu keep the engine; "off" hands back to AVPlayer at the position
  H  a podcast's own level overrides the global one (off for the podcast -> AVPlayer)
  I  lock screen info: elapsed time follows the episode, rate = speed x speed-up factor
  J  audio session interruption pauses and resumes
  K  end of episode marks it played
  L  a streamed episode plays on the engine at once and moves to the file once it is complete
  M  video media stays on AVPlayer and reports why
  N  disabling the feature restores AVPlayer and the tap-cycling speed button

Evidence: commands.log, observations.jsonl, checks.json, screenshots, app diagnostics export.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid', required=True)
p.add_argument('--app', required=True, type=Path)
p.add_argument('--fixture', required=True, type=Path, help='real podcast MP3')
p.add_argument('--evidence', required=True, type=Path)
p.add_argument('--prepare-ui', action='store_true')
args = p.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)
for stale in ('observations.jsonl', 'commands.log', 'checks.json'):
    (out / stale).unlink(missing_ok=True)


def run(cmd, check=True, env=None):
    r = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    with (out / 'commands.log').open('a') as log:
        log.write(shlex.join(cmd) + '\n' + r.stdout + '\n')
    if check and r.returncode:
        raise RuntimeError(r.stdout)
    return r.stdout.strip()


device = next(d for ds in json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices'].values()
              for d in ds if d['udid'] == args.udid)
assert device['state'] == 'Booted', device
fixture = args.fixture.resolve().read_bytes()
source = ROOT / 'Tools/fixtures/silence_trim_probe.m'
library = out / 'SilenceTrimProbe.dylib'
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
     '-isysroot', sdk, '-I', str(ROOT / 'Classes'), '-framework', 'UIKit', '-framework', 'CoreData',
     '-framework', 'AVFoundation', '-framework', 'MediaPlayer', str(source), '-o', str(library)])
run(['codesign', '-s', '-', str(library)])
run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
directory = container / 'Documents/SilenceTrimProbe'
directory.mkdir(parents=True, exist_ok=True)
for name in ('command.json', 'reply.json'):
    (directory / name).unlink(missing_ok=True)

requests = []


class Peer(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def _send(self, body, throttle=False, entry=None):
        start, end = 0, len(fixture) - 1
        ranged = self.headers.get('Range')
        if ranged:
            lo, hi = ranged.removeprefix('bytes=').split('-', 1)
            start, end = int(lo), min(int(hi) if hi else end, end)
        # Failure fixtures for the fallback checks (deep test S9-S11), from the middle of the file:
        # /failonce... breaks the first such response off after 64 KB (a connection closed before
        # any response is retried by CFNetwork itself and never reaches the app); /enginefail...
        # answers 500 to every request that does not come from AVPlayer's own loader (User-Agent
        # AppleCoreMedia).
        break_off = body and start >= 1 << 20 and self.path.startswith('/failonce') and self.path not in dropped
        if break_off:
            dropped.add(self.path)
        if body and start >= 1 << 20 and self.path.startswith('/enginefail') and 'AppleCoreMedia' not in self.headers.get('User-Agent', ''):
            self.send_error(500)
            return
        self.send_response(206 if ranged else 200)
        self.send_header('Content-Type', 'audio/mpeg')
        self.send_header('Content-Length', str(end - start + 1))
        self.send_header('Accept-Ranges', 'bytes')
        if ranged:
            self.send_header('Content-Range', f'bytes {start}-{end}/{len(fixture)}')
        self.end_headers()
        if body:
            view = memoryview(fixture)[start:end + 1]
            step = 4096 if throttle == 'slow' else 1 << 16
            try:
                for offset in range(0, len(view), step):
                    if break_off and offset >= 1 << 16:
                        self.close_connection = True
                        return
                    self.wfile.write(view[offset:offset + step])
                    self.wfile.flush()
                    if entry is not None:
                        # Bytes that reached the socket, for the transfer checks (deep test T).
                        entry['start'] = start
                        entry['sent'] = entry.get('sent', 0) + len(view[offset:offset + step])
                    if throttle == 'slow' and start + offset >= 1 << 20:
                        # 7 KB/s, below the fixture's 10 KB/s; the header comes at full speed
                        time.sleep(len(view[offset:offset + step]) / 7000)
                    elif throttle:
                        time.sleep(0.025)  # about 2.6 MB/s, so the stream phase is observable
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_HEAD(self):
        requests.append(dict(method='HEAD', path=self.path, range=self.headers.get('Range')))
        self._send(False)

    def do_GET(self):
        entry = dict(method='GET', path=self.path, range=self.headers.get('Range'),
                     avfoundation='AppleCoreMedia' in self.headers.get('User-Agent', ''))
        requests.append(entry)
        self._send(True, throttle='slow' if self.path.startswith('/slow') else self.path.startswith(('/stream', '/failonce', '/enginefail')),
                   entry=entry)


dropped = set()
server = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{server.server_port}'
files = [source, Path(__file__).resolve(), ROOT / 'Classes/PlaybackManager.m', ROOT / 'Classes/PlayerSpeedButton.m',
         *sorted((ROOT / 'Classes/SilenceTrim').glob('*.swift'))]
(out / 'environment.json').write_text(json.dumps(dict(
    command=shlex.join([sys.executable, *sys.argv]),
    device=device, app=str(args.app.resolve()),
    fixture=dict(path=str(args.fixture), bytes=len(fixture), sha256=hashlib.sha256(fixture).hexdigest()),
    sourceSHA256={str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
    binarySHA256={f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in args.app.glob('InstacastPlus*') if f.is_file()}), indent=2))
run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid,
     BUNDLE, '-AppleLanguages', '(de)', '-PlaybackVolume', '0', '-UISoundEnabled', 'NO'],
    env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))


def ui_test(name, body):
    """Runs one XCUITest method against the installed app (no app code is replaced)."""
    project = out / f'{name}.xcodeproj'
    project.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
    (out / 'NativeScrollTests.swift').write_text('import XCTest\nfinal class NativeScrollTests: XCTestCase {\n' + body + '\n}\n')
    # xcodebuild refuses to write over a result bundle of an earlier run into the same folder.
    shutil.rmtree(out / f'{name}.xcresult', ignore_errors=True)
    # All test projects link the same bundle into the shared products folder. A project whose
    # own build record is unchanged since an earlier run skips the link and would run the bundle
    # another test linked last; without the products every test links its own body.
    shutil.rmtree(out / 'NativeDerived' / 'Build' / 'Products', ignore_errors=True)
    log = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests',
               '-destination', 'platform=iOS Simulator,id=' + args.udid,
               '-derivedDataPath', str(out / 'NativeDerived'), '-parallel-testing-enabled', 'NO',
               '-resultBundlePath', str(out / f'{name}.xcresult'), 'test'], check=False)
    (out / f'{name}.log').write_text(log)
    return '** TEST SUCCEEDED **' in log


if args.prepare_ui:
    shutil.rmtree(out / 'startup.xcresult', ignore_errors=True)
    assert ui_test('startup', '''
 func testDismissStartup() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let system=XCUIApplication(bundleIdentifier:"com.apple.springboard")
  for title in ["Nicht erlauben","Don’t Allow","Don't Allow"] {
   let button=system.alerts.buttons[title]
   if button.waitForExistence(timeout:2) {button.tap();break}
  }
  for title in ["Got it!","Verstanden!","Verstanden"] {
   let button=app.buttons[title]
   if button.waitForExistence(timeout:1) {button.tap();break}
  }
 }'''), 'startup preparation failed'


def command(action='status', timeout=30, **params):
    request = dict(id=str(uuid.uuid4()), action=action, **params)
    temp = directory / 'command.tmp'
    temp.write_text(json.dumps(request))
    temp.replace(directory / 'command.json')
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            response = json.loads((directory / 'reply.json').read_text())
            if response['id'] == request['id']:
                response['wall'] = time.time()
                with (out / 'observations.jsonl').open('a') as log:
                    log.write(json.dumps(dict(request=request, response=response)) + '\n')
                assert not response.get('error'), response
                return response
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.05)
    raise AssertionError(f'No reply: {request}')


checks = []


def check(name, passed, observed, **extra):
    entry = dict(name=name, passed=bool(passed), observed=observed, **extra)
    checks.append(entry)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2))
    print(('PASS ' if passed else 'FAIL ') + name + ('  ' + json.dumps(extra) if extra else ''), flush=True)


def wait(predicate, seconds=20):
    s = command()
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate(s):
            return s
        time.sleep(.2)
        s = command()
    return s


def dismiss_top():
    """Dismisses the topmost sheet and waits until UIKit finished: presenting the next sheet
    while the previous one is still being dismissed puts it on that sheet, and both disappear."""
    before = len(command().get('presented', []))
    command('dismissTop')
    return wait(lambda s: len(s.get('presented', [])) < before, 5)


def advance(seconds):
    """Episode time advanced over `seconds` of wall-clock time."""
    a = command()
    time.sleep(seconds)
    b = command()
    return b['time'] - a['time'], b['wall'] - a['wall'], b


def screenshot(name):
    run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / (name + '.png'))])


DURATION = 6511
try:
    command('defaults', values={'PlayerSilenceTrimEnabled': False, 'AutoDownloadWhileStreaming': False,
                                'ScreenTimerAlwaysActive': False, 'EnableStreamingOver3G': True,
                                'EnableCachingOver3G': True, 'ReplayAfterPause': False})
    command('settings', enabled=False, level=2)
    command('defaults', values={'DefaultPlaybackSpeed': 0})
    command('speed', control=0)
    command('seed', name='local', title='LNP564 lokal', feedTitle='Pausen E2E', url=f'{base}/local.mp3', duration=DURATION, byteSize=len(fixture))
    command('cache', name='local')
    s = wait(lambda s: s.get('cached'), 120)
    check('setup: episode downloaded through CacheManager', s.get('cached'), s)

    # A: feature off -> AVPlayer, speed button cycles (no menu).
    command('present', name='local', at=600, autostart=True)
    s = wait(lambda s: s['ready'] and s['playing'], 20)
    time.sleep(1.5)
    s = command()
    check('A feature off plays with AVPlayer', s['engine'] == 'avplayer' and s['playing'] and abs(s['time'] - 601) < 3, s)
    check('A speed button keeps tap cycling (no menu)', s['speedButtonFound'] and not s['speedButtonMenu'] and not s['speedButtonMenuPrimary'], s)
    d, w, s = advance(5)
    check('A AVPlayer runs in real time', abs(d - w) < 0.6, s, advance=d, wall=w)
    screenshot('A-player-feature-off')

    # B: enable while playing.
    before = command()
    switched_at = time.time()
    s = command('settings', enabled=True)
    s = wait(lambda s: s['engine'] == 'silence-trim' and s['playing'], 15)
    check('B enabling switches to the engine while playing', s['engine'] == 'silence-trim' and s['playing'] and s['trimLevel'] == 2, s)
    # AVPlayer plays on until the engine takes over at a silent point: the position keeps running.
    expected = before['time'] + (time.time() - switched_at)
    check('B position runs on across the switch', expected - 1.5 < s['time'] < expected + 1.5, s, before=before['time'], expected=expected)
    check('B speed button became a menu', s['speedButtonMenu'] and s['speedButtonMenuPrimary'], s)

    # B (UI): the real button opens the menu; choosing "Stark" goes through the menu action.
    ui_ok = ui_test('speed-menu', '''
 func testSpeedMenu() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let button=app.buttons["Wiedergabegeschwindigkeit"].firstMatch
  XCTAssertTrue(button.waitForExistence(timeout:5))
  button.tap()
  // The selected level carries the saved time as subtitle, which becomes part of its label.
  for title in ["Sanft","Mittel","Stark","1x"] {
   XCTAssertTrue(app.buttons.matching(NSPredicate(format:"label BEGINSWITH %@", title)).firstMatch.waitForExistence(timeout:3), title)
  }
  let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
  shot.name="speed-menu"; shot.lifetime = .keepAlways; add(shot)
  app.buttons["Stark"].firstMatch.tap()
  sleep(1)
 }''')
    s = wait(lambda s: s.get('trimLevel') == 3, 10)
    check('B (UI) speed button opens the menu with both sections and "Stark" applies level 3',
          ui_ok and s['engine'] == 'silence-trim' and s['trimLevel'] == 3, s)
    command('menuLevel', level=2)
    s = wait(lambda s: s.get('trimLevel') == 2, 10)

    # C: shortening. 35 s: the reported speed-up factor must survive the pruning of old map
    # points (it fell back to 1.0 after about 24 s before the 20.11. fix).
    d, w, s = advance(35)
    check('C episode time runs ahead of wall time (pauses shortened)', d > w * 1.02 and d < w * 3, s, advance=d, wall=w, factor=d / w)
    check('C saved time is reported', s['trimSaved'] > 0.2, s)
    check('C speed-up factor stays above 1 after 35 s and matches the measured advance',
          s['trimFactor'] > 1.01 and abs(s['trimFactor'] - d / w) < 0.08, s, measured=d / w)
    screenshot('C-player-shortening')

    # D: pause / resume.
    s = command('pause')
    time.sleep(0.8)
    s = command()
    check('D pause stops the engine', s['paused'] and not s['playing'] and s['trimRate'] == 0, s)
    check('D pause stores the episode position', abs(s['episodePosition'] - int(s['time'])) <= 1, s)
    t_paused = s['time']
    time.sleep(1.5)
    s = command()
    check('D time stands still while paused', abs(s['time'] - t_paused) < 0.05, s)
    command('play')
    s = wait(lambda s: s['playing'] and s['time'] > t_paused + 0.5, 10)
    check('D resume continues from the paused position', s['playing'] and t_paused < s['time'] < t_paused + 5, s)

    # E: seek.
    command('seek', time=3000)
    time.sleep(0.6)
    s = command()
    check('E seek lands on the requested time', 3000 <= s['time'] < 3003, s)

    # F: speed 1.5x (PlaybackSpeedControlPlusHalfSpeed).
    command('speed', control=3)
    time.sleep(1)
    d, w, s = advance(10)
    check('F speed 1.5x applied on top of shortening', s['trimRequestedRate'] == 1.5 and d > w * 1.5, s, advance=d, wall=w, factor=d / w)
    command('speed', control=0)

    # G: menu level changes.
    s = command('menuLevel', level=3)
    time.sleep(0.5)
    s = command()
    check('G menu "strong" keeps the engine with level 3', s['engine'] == 'silence-trim' and s['trimLevel'] == 3 and s['defaultsLevel'] == 3, s)
    d, w, s = advance(12)
    check('G strong level keeps playing and shortening', s['playing'] and d > w, s, advance=d, wall=w, factor=d / w)
    before = command()
    command('menuLevel', level=0)
    s = wait(lambda s: s['engine'] == 'silence-trim' and s.get('trimLevel') == 0 and s['playing'], 15)
    # Switching off while playing keeps the player (no reopen): the engine passes the audio through.
    check('G menu "off" keeps playing without shortening, same player', s['engine'] == 'silence-trim' and s.get('trimLevel') == 0 and s['playing'], s)
    check('G position kept when switching off', abs(s['time'] - before['time']) < 2.5, s, before=before['time'])
    time.sleep(2)  # the ~1.5 s already enqueued keep the old level
    d, w, s = advance(4)
    check('G playback runs in real time again', abs(d - w) < 0.6, s, advance=d, wall=w)
    command('menuLevel', level=2)
    s = wait(lambda s: s['engine'] == 'silence-trim' and s['playing'], 15)
    check('G menu "medium" switches back to the engine', s['engine'] == 'silence-trim' and s['playing'] and s['trimLevel'] == 2, s)

    # H: podcast override.
    command('feedLevel', name='local', level=0)
    s = wait(lambda s: s.get('trimLevel') == 0, 15)
    check('H podcast set to off overrides the global level', s.get('trimLevel') == 0 and s['levelForEpisode'] == 0 and s['defaultsLevel'] == 2, s)
    command('feedLevel', name='local', level=3)
    s = wait(lambda s: s['engine'] == 'silence-trim', 15)
    check('H podcast level 3 is used', s['engine'] == 'silence-trim' and s['trimLevel'] == 3 and s['levelForEpisode'] == 3, s)
    command('menuLevel', level=1)
    s = command()
    check('H menu writes the podcast override, global untouched', s['levelForEpisode'] == 1 and s['defaultsLevel'] == 2 and s['trimLevel'] == 1, s)
    command('menuLevel', level=2)  # equal to the global value -> override removed
    command('feedLevel', name='local', level=None)
    s = command()
    check('H back on the global level', s['levelForEpisode'] == 2 and s['trimLevel'] == 2, s)

    # I: lock screen info. The system extrapolates the elapsed time with the rate between the
    # app's updates (every 10 s); right after an update the stored value is the episode time.
    anchor = command()['nowPlayingElapsed']
    s = wait(lambda s: s['nowPlayingElapsed'] != anchor, 15)
    check('I lock screen elapsed time follows the episode', abs(s['nowPlayingElapsed'] - s['time']) < 1.0, s)
    check('I lock screen rate = speed x speed-up factor', s['nowPlayingRate'] >= 1.0 and abs(s['nowPlayingRate'] - s['trimFactor'] * s['trimRequestedRate']) < 0.15, s)

    # J: interruption.
    command('interruption', type='began')
    s = wait(lambda s: s['paused'], 5)
    check('J interruption pauses', s['paused'] and s['trimRate'] == 0, s)
    command('interruption', type='ended')
    s = wait(lambda s: s['playing'], 5)
    check('J interruption end resumes', s['playing'] and s['engine'] == 'silence-trim', s)

    # K: end of episode.
    command('seek', time=s['duration'] - 6)
    s = wait(lambda s: s['episodeConsumed'] or s['engine'] == 'none', 25)
    check('K end of episode marks it played', s['episodeConsumed'], s)
    s = command()
    check('K player closed after the last episode', s['engine'] == 'none', s)

    # L: a streamed episode (stream cache on) plays on the engine at once; once its download is
    # complete the engine reads the file, without switching engines.
    command('defaults', values={'AutoDownloadWhileStreaming': True})
    command('seed', name='stream', title='LNP564 Stream', feedTitle='Pausen E2E Stream', url=f'{base}/stream.mp3', duration=DURATION, byteSize=len(fixture))
    command('present', name='stream', at=1200, autostart=True)
    s = wait(lambda s: s['ready'] and s['playing'], 20)
    check('L stream plays on the engine right away', s['engine'] == 'silence-trim' and s.get('trimStream') and not s['assetURL'].startswith('file:'), s)
    s = wait(lambda s: s.get('trimSaved', 0) > 0.5, 30)
    check('L pauses are shortened while streaming', s.get('trimSaved', 0) > 0.5 and s.get('trimStream') and not s.get('trimDecodesFile'), s)
    s = wait(lambda s: s.get('cached') and s.get('trimDecodesFile'), 120)
    check('L after the download the engine reads the file, still playing', s['engine'] == 'silence-trim' and s.get('trimDecodesFile') and s['playing'] and s['cached'], s)
    check('L position kept across the move to the file', 1195 < s['time'] < 1400, s)
    command('close')

    # M: video media.
    command('seed', name='video', title='Video', feedTitle='Pausen E2E Video', url=f'{base}/video.mp3', duration=DURATION, byteSize=len(fixture), mime='video/mp4')
    command('cache', name='video')
    wait(lambda s: s.get('cached'), 120)
    command('present', name='video', at=100, autostart=True)
    s = wait(lambda s: s['ready'] and s['playing'], 20)
    check('M video stays on AVPlayer', s['engine'] == 'avplayer', s)
    check('M menu explains why', s['statusText'] == 'Nicht bei Videos', s)
    command('close')

    # N: feature disabled -> old behaviour.
    command('present', name='local', at=500, autostart=True)
    s = wait(lambda s: s['ready'] and s['playing'] and s['engine'] == 'silence-trim', 20)
    check('N engine active before disabling', s['engine'] == 'silence-trim', s)
    command('settings', enabled=False)
    s = wait(lambda s: s.get('trimLevel') == 0 and s['playing'], 15)
    check('N disabling while playing keeps playing without shortening', s['engine'] == 'silence-trim' and s.get('trimLevel') == 0 and s['playing'], s)
    command('close')
    command('present', name='local', at=500, autostart=True)
    s = wait(lambda s: s['ready'] and s['playing'], 20)
    time.sleep(0.5)
    s = command()
    check('N the next opening plays with AVPlayer again', s['engine'] == 'avplayer' and s['playing'], s)
    check('N speed button cycles again (no menu)', not s['speedButtonMenu'] and not s['speedButtonMenuPrimary'], s)
    screenshot('N-player-feature-off-again')
    speed_before = s['speedControl']
    ui_ok = ui_test('speed-tap', '''
 func testSpeedTapCycles() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let button=app.buttons["Wiedergabegeschwindigkeit"].firstMatch
  XCTAssertTrue(button.waitForExistence(timeout:5))
  button.tap()
  sleep(1)
  XCTAssertFalse(app.buttons["Mittel"].firstMatch.exists)
 }''')
    s = command()
    check('N (UI) tapping the speed button cycles the speed again', ui_ok and s['speedControl'] != speed_before, s, before=speed_before)
    command('speed', control=0)
    command('settings', enabled=True)
    command('showSettings', screen='playback')
    time.sleep(1.5)
    screenshot('settings-playback')
    dismiss_top()
    command('showSettings', screen='feed', name='local')
    time.sleep(1.5)
    ui_ok = ui_test('feed-settings-scroll', '''
 func testScrollToPauseRow() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let row=app.staticTexts["Sprechpausen kürzen"].firstMatch
  var tries=0
  while !row.isHittable && tries<12 { app.swipeUp(); tries+=1 }
  XCTAssertTrue(row.exists)
 }''')
    check('O (UI) the podcast settings show the pause row', ui_ok and 'FeedSettingsViewController' in command().get('presented', []), command())
    screenshot('settings-podcast')
    dismiss_top()
    command('settings', enabled=False)
    command('close')
    command('exportLogs')
    export = directory / 'export.txt'
    if export.exists():
        shutil.copy2(export, out / 'diagnostics-export.txt')
finally:
    for result in out.glob('*.xcresult'):
        run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(out / ('attachments-' + result.stem))], check=False)
    (out / 'http-requests.json').write_text(json.dumps(requests[:5000], indent=1))
    server.shutdown()

failed = [c['name'] for c in checks if not c['passed']]
print(f'{len(checks) - len(failed)}/{len(checks)} checks passed')
if failed:
    print('FAILED:', *failed, sep='\n  ')
    sys.exit(1)
