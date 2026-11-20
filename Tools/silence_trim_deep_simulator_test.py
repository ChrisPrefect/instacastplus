#!/usr/bin/env python3
"""Deeper real-app E2E for pause shortening: the cases next to plain playback.

Same command line and setup as Tools/silence_trim_simulator_test.py (shared below), then:

  P  pause, start and seek inside a long speech pause
  S  streaming and downloading at the same time:
       S1 stream without stream cache + separate download of the same episode
       S2 stream with stream cache + a manual download in parallel (exactly one switch)
       S3 another episode's download finishing while shortening plays (no switch)
       S4 the playing episode's download deleted (same outcome as with AVPlayer)
       S5 download finishing while paused (stays paused, resumes on the engine)
       S6 stream finished with the feature off, then turned on (switches to the file)
  R  settings changed from outside the UI, as the iCloud sync and a backup import write them:
       global switch, global level, the podcast's own level
  B  backup: export contains the settings, import restores them and the playing episode follows
  U  UI: waiting hint while streaming, real taps on the settings switch and level, dark mode
"""
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Everything before the scenarios of the base test: arguments, probe build, install, HTTP
# fixture server (paths starting with /stream are throttled), launch, command/check helpers.
_base = Path(__file__).resolve().parent / 'silence_trim_simulator_test.py'
_source = _base.read_text()
exec(compile(_source[:_source.index('\nDURATION = 6511')], str(_base), 'exec'))

import os
SCENARIOS = os.environ.get('SILENCE_TRIM_SCENARIOS', 'PSRBU')


def want(letter):
    return letter in SCENARIOS


DURATION = 6511
PAUSE_START, PAUSE_END = 573.33, 575.59   # 2.26 s pause in LNP564 (analyzer, medium)


def diagnostics():
    command('exportLogs')
    export = directory / 'export.txt'
    events = []
    if export.exists():
        for line in export.read_text(errors='replace').splitlines():
            if line.startswith('{') and '"silence-trim"' in line:
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return events


def switches(events, episode_hash, reason=None):
    return [e for e in events if e.get('message') == 'Engine-Wechsel'
            and e.get('metadata', {}).get('episodeHash') == episode_hash
            and (reason is None or e.get('metadata', {}).get('reason') == reason)]


def seed(name, path, title, mime='audio/mpeg', subscribed=False):
    return command('seed', name=name, title=title, feedTitle='Pausen Tief ' + name, url=f'{base}/{path}',
                   duration=DURATION, byteSize=len(fixture), mime=mime, subscribed=subscribed)


def settled(engine):
    """After an engine switch the episode reopens; wait until it is ready and playing again."""
    return lambda s: s['engine'] == engine and s['ready'] and s['playing']


try:
    command('defaults', values={'PlayerSilenceTrimEnabled': True, 'PlayerSilenceTrimLevel': 2,
                                'AutoDownloadWhileStreaming': False, 'ScreenTimerAlwaysActive': False,
                                'EnableStreamingOver3G': True, 'EnableCachingOver3G': True,
                                'ReplayAfterPause': False, 'DefaultPlaybackSpeed': 0})
    command('speed', control=0)
    seed('local', 'local.mp3', 'LNP564 lokal', subscribed=True)
    command('cache', name='local')
    s = wait(lambda s: s.get('cached'), 120)
    check('setup: local episode downloaded', s.get('cached'), s)

    if want('P'):
        # ---------------- P: pause / start / seek inside a long pause
        command('present', name='local', at=int(PAUSE_START) - 4, autostart=False)
        s = wait(lambda s: s['ready'] and s['engine'] == 'silence-trim', 20)
        mid = (PAUSE_START + PAUSE_END) / 2
        command('seek', time=mid)
        time.sleep(0.5)
        s = command()
        check('P seek into the middle of a pause while paused', abs(s['time'] - mid) < 0.6 and s['paused'], s, target=mid)
        command('play')
        time.sleep(0.25)
        s = command('pause')
        time.sleep(0.6)
        s = command()
        t_paused = s['time']
        check('P start and pause again inside the pause', s['paused'] and mid < t_paused < PAUSE_END + 0.5, s)
        check('P position saved while paused inside the pause', abs(s['episodePosition'] - int(t_paused)) <= 1, s)
        time.sleep(1.5)
        s = command()
        check('P time stands still while paused inside the pause', abs(s['time'] - t_paused) < 0.01, s)
        command('play')
        s = wait(lambda s: s['time'] > PAUSE_END + 2, 8)
        check('P resume leaves the pause and continues into speech', s['playing'] and s['time'] > PAUSE_END + 2, s)
        command('seek', time=PAUSE_START - 1)
        s = wait(lambda s: s['time'] > PAUSE_END + 1, 8)
        elapsed_ok = s['time'] > PAUSE_END + 1
        check('P playing through the whole pause works after a seek right before it', elapsed_ok and s['playing'], s)
        command('close')

    if want('S'):
        # ---------------- S1: stream without stream cache, separate download of the same episode
        seed('s1', 'stream1.mp3', 'Stream ohne Cache')
        command('present', name='s1', at=300, autostart=True)
        s = wait(lambda s: s['ready'] and s['playing'], 30)
        check('S1 stream plays on AVPlayer from HTTP', s['engine'] == 'avplayer' and s['assetURL'].startswith('http'), s)
        check('S1 menu tells why shortening waits', s.get('statusText') == 'Startet, sobald die Folge geladen ist', s)
        ui_ok = ui_test('waiting-hint', '''
     func testWaitingHint() {
      let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
      app.activate()
      let button=app.buttons["Wiedergabegeschwindigkeit"].firstMatch
      XCTAssertTrue(button.waitForExistence(timeout:5))
      button.tap()
      let hint=app.descendants(matching: .any).matching(NSPredicate(format:"label CONTAINS %@", "Startet, sobald")).firstMatch
      XCTAssertTrue(hint.waitForExistence(timeout:3))
      let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name="waiting-hint"; shot.lifetime = .keepAlways; add(shot)
      app.coordinate(withNormalizedOffset: CGVector(dx:0.9, dy:0.12)).tap()
     }''')
        check('S1 (UI) the menu shows the waiting hint', ui_ok, command())
        before = command()
        command('cache', name='s1')
        s = wait(settled('silence-trim'), 150)
        check('S1 the separate download completes and the engine takes over', s['engine'] == 'silence-trim' and s['playing'], s)
        check('S1 position kept across the switch', before['time'] - 1 < s['time'] < before['time'] + 150, s, before=before['time'])
        s1_hash = s['episodeHash']
        command('close')

        # ---------------- S2: stream with stream cache + manual download in parallel
        command('defaults', values={'AutoDownloadWhileStreaming': True})
        seed('s2', 'stream2.mp3', 'Stream mit Cache und Download')
        command('present', name='s2', at=600, autostart=True)
        s = wait(lambda s: s['ready'] and s['playing'], 30)
        check('S2 stream with stream cache plays on AVPlayer', s['engine'] == 'avplayer', s)
        command('cache', name='s2')
        s = wait(lambda s: settled('silence-trim')(s) and s['cached'], 150)
        check('S2 engine takes over once the episode is complete', s['engine'] == 'silence-trim' and s['playing'], s)
        s2_hash = s['episodeHash']
        time.sleep(3)
        events = diagnostics()
        s2_switches = switches(events, s2_hash)
        check('S2 exactly one engine switch for two parallel downloads', len(s2_switches) == 1,
              command(), switches=[e['metadata'] for e in s2_switches])

        # ---------------- S3: another download finishes while shortening plays
        seed('s3', 'stream3.mp3', 'Anderer Download')
        t_before = command(name='s2')['time']
        command('cache', name='s3')
        deadline = time.time() + 150
        while time.time() < deadline and not command(name='s3').get('cached'):
            time.sleep(1)
        s = command(name='s2')
        check('S3 other download completed', command(name='s3').get('cached'), s)
        events = diagnostics()
        check('S3 no engine switch for the playing episode', s['engine'] == 'silence-trim' and len(switches(events, s2_hash)) == 1, s)
        check('S3 playback kept running', s['playing'] and s['time'] > t_before, s, before=t_before)

        # ---------------- S4: the playing episode's download is deleted (baseline AVPlayer vs engine)
        outcomes = {}
        for label, enabled in (('avplayer', False), ('silence-trim', True)):
            command('defaults', values={'PlayerSilenceTrimEnabled': enabled})
            name = 's4' + label
            seed(name, f'local4{label}.mp3', 'Löschen ' + label)
            command('cache', name=name)
            wait(lambda s: s.get('cached'), 120)
            command('present', name=name, at=900, autostart=True)
            s = wait(lambda s: s['ready'] and s['playing'], 20)
            engine_before = s['engine']
            command('removeCache', name=name)
            time.sleep(4)
            s = command(name=name)
            outcomes[label] = dict(engineBefore=engine_before, engine=s['engine'], playing=s['playing'], cached=s['cached'])
            command('close')
        check('S4 deleting the download behaves like AVPlayer',
              outcomes['avplayer']['engineBefore'] == 'avplayer' and outcomes['silence-trim']['engineBefore'] == 'silence-trim'
              and outcomes['avplayer']['playing'] == outcomes['silence-trim']['playing']
              and (outcomes['avplayer']['engine'] == 'none') == (outcomes['silence-trim']['engine'] == 'none'),
              command(), outcomes=outcomes)
        command('defaults', values={'PlayerSilenceTrimEnabled': True})

        # ---------------- S5: download finishes while paused
        seed('s5', 'stream5.mp3', 'Fertig während Pause')
        command('present', name='s5', at=1200, autostart=True)
        wait(lambda s: s['ready'] and s['playing'], 30)
        time.sleep(2)
        command('pause')
        time.sleep(0.5)
        t_paused = command()['time']
        s = wait(lambda s: s['engine'] == 'silence-trim' and s['ready'], 150)
        check('S5 engine takes over while paused and stays paused', s['engine'] == 'silence-trim' and s['paused'], s)
        check('S5 paused position kept', abs(s['time'] - t_paused) < 1.5, s, before=t_paused)
        command('play')
        s = wait(lambda s: s['playing'] and s['time'] > t_paused + 1, 8)
        check('S5 resume plays on the engine', s['playing'] and s['engine'] == 'silence-trim', s)
        command('close')

        # ---------------- S6: stream finishes while the feature is off, then it is turned on
        command('defaults', values={'PlayerSilenceTrimEnabled': False})
        seed('s6', 'stream6.mp3', 'Aus während Download')
        command('present', name='s6', at=1500, autostart=True)
        wait(lambda s: s['ready'] and s['playing'], 30)
        s = wait(lambda s: s.get('cached'), 150)
        time.sleep(1)
        s = command()
        check('S6 feature off: still AVPlayer after the download completed', s['engine'] == 'avplayer' and s['cached'], s)
        command('settings', enabled=True)
        s = wait(settled('silence-trim'), 10)
        check('S6 turning it on switches to the downloaded file and keeps playing', s['engine'] == 'silence-trim' and s['playing'] and s['assetURL'].startswith('file:'), s)
        command('close')

    if want('R'):
        # ---------------- R: settings written from outside the UI (iCloud apply, backup import)
        command('present', name='local', at=2000, autostart=True)
        s = wait(lambda s: s['ready'] and s['playing'] and s['engine'] == 'silence-trim', 20)
        check('R setup engine active', s['engine'] == 'silence-trim', s)
        command('defaults', values={'PlayerSilenceTrimEnabled': False})
        s = wait(settled('avplayer'), 8)
        check('R1 switch turned off by sync: playing episode goes back to AVPlayer', s['engine'] == 'avplayer' and s['playing'], s)
        command('defaults', values={'PlayerSilenceTrimEnabled': True})
        s = wait(settled('silence-trim'), 8)
        check('R2 switch turned on by sync: playing episode switches to the engine', s['engine'] == 'silence-trim' and s['playing'], s)
        command('defaults', values={'PlayerSilenceTrimLevel': 3})
        s = wait(lambda s: s.get('trimLevel') == 3, 5)
        check('R3 global level from sync applies to the playing episode', s.get('trimLevel') == 3, s)
        command('feedLevelRaw', name='local', level=0)
        s = wait(settled('avplayer'), 8)
        check('R4 podcast level "off" from sync applies at once', s['engine'] == 'avplayer' and s['playing'], s)
        command('feedLevelRaw', name='local', level=1)
        s = wait(lambda s: s['engine'] == 'silence-trim' and s.get('trimLevel') == 1, 5)
        check('R5 podcast level from sync turns it back on with that level', s['engine'] == 'silence-trim' and s.get('trimLevel') == 1, s)
        command('feedLevelRaw', name='local', level=None)
        s = wait(lambda s: s.get('trimLevel') == 3, 5)
        check('R6 podcast override removed by sync: global level again', s.get('trimLevel') == 3, s)

    if want('B'):
        # ---------------- B: backup export and import
        command('defaults', values={'PlayerSilenceTrimEnabled': True, 'PlayerSilenceTrimLevel': 3})
        command('feedLevel', name='local', level=1)
        s = command('exportBackup')
        xml = Path(s['backupPath']).read_text(errors='replace')
        shutil.copy2(s['backupPath'], out / 'backup.xml')
        check('B1 backup contains the global switch', '<silenceTrimEnabled>true</silenceTrimEnabled>' in xml, s)
        check('B1 backup contains the global level', '<silenceTrimLevel>3</silenceTrimLevel>' in xml, s)
        # By the seeded feed's own URL: earlier runs on the same simulator leave podcasts with the
        # same title behind.
        feed_url = command('status', name='local')['feedURL']
        podcast = re.search(r'<podcast url="' + re.escape(feed_url) + r'"[^>]*>(.*?)</podcast>', xml, re.S)
        check('B1 backup contains the podcast level as integer', bool(podcast) and
              '<setting key="PlayerSilenceTrimLevel" type="integer" value="1"/>' in podcast.group(1), s)
        command('defaults', values={'PlayerSilenceTrimEnabled': False, 'PlayerSilenceTrimLevel': 0})
        command('feedLevelRaw', name='local', level=None)
        s = wait(lambda s: s['engine'] == 'avplayer', 5)
        check('B2 settings cleared before the import (engine off)', s['engine'] == 'avplayer' and s['defaultsLevel'] == 0, s)
        command('importBackup', categories=(1 << 7) | (1 << 2))
        done = directory / 'import-done.json'
        deadline = time.time() + 60
        while time.time() < deadline and not done.exists():
            time.sleep(0.5)
        result = json.loads(done.read_text()) if done.exists() else {'error': 'timeout'}
        s = wait(lambda s: s['engine'] == 'silence-trim' and s.get('trimLevel') == 1, 10)
        check('B2 import finished without error', not result.get('error'), s, result=result)
        check('B2 import restores switch, global level and podcast level', s['defaultsEnabled'] and s['defaultsLevel'] == 3 and s['feedOverride'] == 1, s)
        check('B2 the playing episode follows the imported settings', s['engine'] == 'silence-trim' and s.get('trimLevel') == 1, s)
        command('feedLevel', name='local', level=None)

    if want('U'):
        # ---------------- U: real taps in the settings, dark mode
        command('feedLevel', name='local', level=None)
        command('present', name='local', at=2600, autostart=True)
        command('settings', enabled=False, level=1)
        wait(settled('avplayer'), 8)
        # As in the app: the settings open from the main screen while the mini player plays.
        command('dismissPlayer')
        time.sleep(1)
        command('showSettings', screen='playback')
        time.sleep(1)
        ui_ok = ui_test('settings-taps', '''
     func testSettingsTaps() {
      let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
      app.activate()
      let row=app.staticTexts["Sprechpausen kürzen"].firstMatch
      var tries=0
      while !(row.exists && row.isHittable) && tries<10 { app.tables.firstMatch.swipeUp(velocity: .slow); tries+=1 }
      let toggle=app.cells.containing(.staticText, identifier:"Sprechpausen kürzen").switches.firstMatch
      XCTAssertTrue(toggle.waitForExistence(timeout:3))
      toggle.tap()
      sleep(1)
      let level=app.staticTexts["Standardstärke"].firstMatch
      var more=0
      while !(level.exists && level.isHittable) && more<6 { app.tables.firstMatch.swipeUp(velocity: .slow); more+=1 }
      XCTAssertTrue(level.waitForExistence(timeout:3))
      level.tap()
      let strong=app.staticTexts["Stark"].firstMatch
      XCTAssertTrue(strong.waitForExistence(timeout:3))
      strong.tap()
      sleep(1)
      let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name="level-picker"; shot.lifetime = .keepAlways; add(shot)
     }''')
        s = wait(lambda s: s.get('trimLevel') == 3 and s['engine'] == 'silence-trim', 8)
        check('U1 (UI) tapping the switch and "Stark" in the settings turns the playing episode to level 3',
              ui_ok and s['defaultsEnabled'] and s['defaultsLevel'] == 3 and s['engine'] == 'silence-trim' and s.get('trimLevel') == 3, s)
        dismiss_top()
        time.sleep(0.5)
        command('present', name='local', at=2700, autostart=True)
        time.sleep(1.5)
        run(['xcrun', 'simctl', 'ui', args.udid, 'appearance', 'dark'])
        time.sleep(1.5)
        ui_test('dark-menu', '''
     func testDarkMenu() {
      let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
      app.activate()
      let button=app.buttons["Wiedergabegeschwindigkeit"].firstMatch
      XCTAssertTrue(button.waitForExistence(timeout:5))
      button.tap()
      sleep(1)
      let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name="dark-menu"; shot.lifetime = .keepAlways; add(shot)
      app.coordinate(withNormalizedOffset: CGVector(dx:0.9, dy:0.12)).tap()
     }''')
        command('dismissPlayer')
        time.sleep(1)
        command('showSettings', screen='playback')
        time.sleep(1)
        ui_test('dark-settings', '''
     func testDarkSettings() {
      let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
      app.activate()
      let row=app.staticTexts["Standardstärke"].firstMatch
      var tries=0
      while !(row.exists && row.isHittable) && tries<10 { app.tables.firstMatch.swipeUp(velocity: .slow); tries+=1 }
      let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name="dark-settings"; shot.lifetime = .keepAlways; add(shot)
     }''')
        dismiss_top()
        run(['xcrun', 'simctl', 'ui', args.udid, 'appearance', 'light'])
        command('close')
    events = diagnostics()
    (out / 'silence-trim-events.json').write_text(json.dumps(events, indent=1, ensure_ascii=False))
finally:
    for result in out.glob('*.xcresult'):
        run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(out / ('attachments-' + result.stem))], check=False)
    (out / 'http-requests.json').write_text(json.dumps(requests[:3000], indent=1))
    server.shutdown()

failed = [c['name'] for c in checks if not c['passed']]
print(f'{len(checks) - len(failed)}/{len(checks)} checks passed')
if failed:
    print('FAILED:', *failed, sep='\n  ')
    sys.exit(1)
