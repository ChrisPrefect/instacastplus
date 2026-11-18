#!/usr/bin/env python3
"""Real player menu/countdown and system Now Playing sleep-timer regression.

Retains commands, environment, hashes, observations, XCTest screenshots and logs.
The additional direct-handler matrix is adapter coverage, not headset transport.
Use a disposable simulator named Instacast Sleep Activity.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'

UI_TEST = r'''
import XCTest
final class NativeScrollTests: XCTestCase {
 func request(_ action: String) -> [String:Any] {
  let done = expectation(description: action)
  var result: [String:Any] = [:]
  let url = URL(string: "http://127.0.0.1:PORT/" + action)!
  URLSession.shared.dataTask(with: url) { data, _, error in
   if let data { result = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:] }
   done.fulfill()
  }.resume()
  wait(for:[done],timeout:20)
  return result
 }
 func capture(_ name: String) {
  let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
  attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
 }
 func testMenuAndRemoteActivity() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let system=XCUIApplication(bundleIdentifier:"com.apple.springboard")
  for title in ["Don’t Allow","Don't Allow","Nicht erlauben"] {
   if system.alerts.buttons[title].waitForExistence(timeout:1) {system.alerts.buttons[title].tap();break}
  }
  for title in ["Got it!","Verstanden!","Verstanden"] {
   if app.buttons[title].waitForExistence(timeout:1) {app.buttons[title].tap();break}
  }
  let coach=app.staticTexts.matching(NSPredicate(format:"label CONTAINS[c] %@","to add podcasts")).firstMatch
  if coach.waitForExistence(timeout:2) {
   app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)).tap()
   XCTAssertTrue(coach.waitForNonExistence(timeout:5),app.debugDescription)
  }
  _ = request("open")
  let timer=app.buttons["Sleep Timer"].firstMatch
  XCTAssertTrue(timer.waitForExistence(timeout:25),app.debugDescription)
  timer.tap()
  app.buttons["10 Minutes"].firstMatch.tap()
  capture("10-minute-selection")
  _ = request("menu-selected")
  let until=Date().addingTimeInterval(4)
  while Date()<until {RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
  _ = request("menu-counted-down")
  capture("10-minute-countdown")
  _ = request("arm-keyboard")
  let keyAge=Date().addingTimeInterval(3)
  while Date()<keyAge {RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
  _ = request("before-keyboard-command")
  app.typeKey("k",modifierFlags:[])
  _ = request("after-keyboard-command")
  // The system's notification-screen player uses the headphone command transport.
  // Simulator Control Center omits the system media tile, so use Now Playing here.
  let top=app.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.01))
  top.press(forDuration:0.1,thenDragTo:app.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.8)))
  capture("system-now-playing")
  print("SYSTEM_NOW_PLAYING_TREE\n"+system.debugDescription)
  let forward=system.buttons["UIA.MediaControls.NowPlaying.RightButton"]
  XCTAssertTrue(forward.waitForExistence(timeout:10),system.debugDescription)
  guard forward.exists else {return}
  _ = request("arm-system")
  let age=Date().addingTimeInterval(4)
  while Date()<age {RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
  _ = request("before-system-command")
  forward.tap()
  capture("after-system-command")
  let state=request("after-system-command")
  XCTAssertEqual(state["systemCommandReset"] as? Bool,true,"Actual system Now Playing command failed to extend the countdown")
 }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(cmd, check=True, env=None):
        result = subprocess.run(cmd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(cmd) + '\n' + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout)
        return result

    device = next(d for ds in json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']).stdout)['devices'].values()
                  for d in ds if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Sleep Activity' and device['state'] == 'Booted'
    source = ROOT / 'Tools/fixtures/sleep_timer_activity_probe.m'
    library = out / 'SleepActivityProbe.dylib'
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).stdout.strip()
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
         '-isysroot', sdk, '-I', str(ROOT / 'Classes'), '-framework', 'UIKit', '-framework', 'CoreData',
         '-framework', 'AVFoundation', '-framework', 'MediaPlayer', str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']).stdout.strip())
    directory = container / 'Documents/SleepActivityProbe'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ('command.json', 'reply.json'):
        (directory / name).unlink(missing_ok=True)
    with wave.open(str(directory / 'fixture.wav'), 'wb') as wav:
        wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        for _ in range(2400):
            wav.writeframes(b'\0\0' * 8000)
    files = [Path(__file__).resolve(), source, ROOT / 'Classes/PlaybackManager.m', ROOT / 'Classes/AudioSession.m',
             ROOT / 'Classes/Application.m', ROOT / 'Classes/PlayerTimerButton.m']
    (out / 'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable, *sys.argv]), device=device, app=str(args.app.resolve()),
        fixture='2400-second silent 8 kHz mono PCM WAV; actual player UI; 10-minute menu selection; 18-second accelerated system command scenario',
        expected='Menu shows 10:00 and counts down; system Now Playing skip extends active smart timer; disabled and cancelled timers stay unchanged',
        sourceSHA256={str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        binarySHA256={f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in args.app.glob('InstacastPlus*') if f.is_file()}), indent=2))
    run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}',
         args.udid, BUNDLE, '-AppleLanguages', '(en)', '-PlaybackVolume', '0', '-UISoundEnabled', 'NO'],
        env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

    def command(action='status', **params):
        request = dict(id=str(uuid.uuid4()), action=action, **params)
        temp = directory / 'command.tmp'
        temp.write_text(json.dumps(request))
        temp.replace(directory / 'command.json')
        end = time.monotonic() + 20
        while time.monotonic() < end:
            try:
                response = json.loads((directory / 'reply.json').read_text())
                if response['id'] == request['id']:
                    with (out / 'observations.jsonl').open('a') as log:
                        log.write(json.dumps(dict(request=request, response=response)) + '\n')
                    assert not response.get('error'), response
                    return response
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(.05)
        raise AssertionError(f'No reply: {request}')

    checks = []

    def check(name, passed, state):
        checks.append(dict(name=name, passed=bool(passed), observed=state))
        (out / 'checks.json').write_text(json.dumps(checks, indent=2))
        print(('PASS ' if passed else 'FAIL ') + name, flush=True)

    states = {}

    class Peer(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            action = urlparse(self.path).path.removeprefix('/')
            try:
                if action == 'open':
                    state = command('open')
                elif action in ('arm-system', 'arm-keyboard'):
                    state = command('arm', seconds=18)
                else:
                    state = command()
                states[action] = state
                if action == 'menu-selected':
                    check('E2E: menu selection stores and displays ten minutes',
                          state['timerValue'] == state['defaultMinutes'] == state['lastSelectedMinutes'] == 10
                          and state['title'] in ('10:00', '09:59', '09:58') and state['title'] == state['accessibilityValue'], state)
                elif action == 'menu-counted-down':
                    check('E2E: visible ten-minute countdown advances',
                          state['remaining'] < states['menu-selected']['remaining'] - 2
                          and state['title'].startswith('09:') and state['rate'] > 0, state)
                elif action == 'after-system-command':
                    before = states['before-system-command']
                    passed = (state['stopDate'] > before['stopDate'] + 2 and state['remaining'] > 15
                              and state['rate'] > 0 and state['time'] > before['time'] + 20)
                    check('E2E: actual system Now Playing forward command resets timer', passed, state)
                    state['systemCommandReset'] = passed
                elif action == 'after-keyboard-command':
                    before = states['before-keyboard-command']
                    check('E2E: physical keyboard input resets timer', state['stopDate'] > before['stopDate'] + 2, state)
                payload = json.dumps(state).encode()
                self.send_response(200)
            except Exception as error:
                payload = json.dumps(dict(error=str(error))).encode()
                self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = HTTPServer(('127.0.0.1', 0), Peer)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    project = out / 'Native.xcodeproj'
    project.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
    (out / 'NativeScrollTests.swift').write_text(UI_TEST.replace('PORT', str(server.server_port)))
    try:
        native = run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests',
                      '-destination', 'platform=iOS Simulator,id=' + args.udid, '-derivedDataPath', str(out / 'NativeDerived'),
                      '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(out / 'native.xcresult'), 'test'], check=False)
        (out / 'native.log').write_text(native.stdout)
        check('E2E: native UI test completed', native.returncode == 0, dict(exitCode=native.returncode))
        # All existing transport adapters run against the real player and AudioSession.
        for selector, event_type in [('_skipForwardEvent:', 0), ('_skipBackwardEvent:', 0),
                                     ('_nextChapterEvent:', 0), ('_previousChapterEvent:', 0),
                                     ('_seekForwardEvent:', 0), ('_seekForwardEvent:', 1),
                                     ('_seekBackwardEvent:', 0), ('_seekBackwardEvent:', 1),
                                     ('_changePlaybackPositionEvent:', 0), ('_playEvent:', 0),
                                     ('_pauseEvent:', 0), ('_playPauseEvent:', 0)]:
            armed = command('arm', seconds=60)
            time.sleep(.5)
            state = command('remote', selector=selector, type=event_type)
            extended = state['stopDate'] > armed['stopDate'] + .25 if not state['paused'] else state['remaining'] > 59.9
            check(f'Adapter: {selector} type={event_type} resets timer', extended, state)
        armed = command('arm', seconds=60, smart=False)
        state = command('remote', selector='_skipForwardEvent:')
        check('Adapter: smart disabled preserves deadline', state['stopDate'] == armed['stopDate'], state)
        command('arm', seconds=60)
        command('cancel')
        state = command('remote', selector='_skipForwardEvent:')
        check('Adapter: remote command never enables cancelled timer', state['timerValue'] == 0 and state['remaining'] == 0, state)
        return 0 if checks and all(c['passed'] for c in checks) else 1
    finally:
        server.shutdown()
        if (container / 'Documents/Logs').exists():
            shutil.copytree(container / 'Documents/Logs', out / 'Logs', dirs_exist_ok=True)


if __name__ == '__main__':
    sys.exit(main())
