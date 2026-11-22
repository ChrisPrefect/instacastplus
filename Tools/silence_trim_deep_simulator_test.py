#!/usr/bin/env python3
"""Deeper real-app E2E for pause shortening: the cases next to plain playback.

Same command line and setup as Tools/silence_trim_simulator_test.py (shared below), then:

  P  pause, start and seek inside a long speech pause
  S  streaming and downloading at the same time:
       S1 stream without stream cache (the engine's own source, temporary file deleted on close)
          + separate download of the same episode (the engine moves to the file)
       S2 stream with stream cache on the engine + a manual download in parallel (no switch,
          the engine moves to the file)
       S3 another episode's download finishing while shortening plays (no switch)
       S4 the playing episode's download deleted (same outcome as with AVPlayer)
       S5 download finishing while paused (stays paused, resumes and moves to the file)
       S6 stream finished with the feature off, then turned on (switches to the file)
       S7 a stream slower than its bitrate: the clock waits, playback goes on, a seek into a
          part not downloaded plays there
       S8 the same without stream cache (own source)
       S9-S11 the fallback is always "shortening off", never "stream stops": the engine loses
          the stream (with and without stream cache) and AVPlayer plays on at the position; a
          single dropped connection is retried by the own source and the engine keeps going
  R  settings changed from outside the UI, as the iCloud sync and a backup import write them:
       global switch, global level, the podcast's own level, the pause detection
  B  backup: export contains the settings, import restores them and the playing episode follows
  W  switching shortening off and on while playing: no gap or jump in the audio, the chapter
       artwork stays, no "episode changed" notification
  T  transfer: bytes the server actually sent while streaming with seeks, with and without pause
       shortening and stream caching; every byte must cross the network once
  U  UI: saved time while streaming, real taps on the settings switch and level, dark mode
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


def switch_trace(label, at, actions, seconds=10.0, name='local'):
    """Plays `name` from `at`, records 10 ms samples and applies (delay, command kwargs) pairs."""
    command('present', name=name, at=at, autostart=True)
    wait(lambda s: s['ready'] and s['playing'], 30)
    time.sleep(3)
    trace_file = directory / f'trace-{label}.json'
    trace_file.unlink(missing_ok=True)
    command('trace', seconds=seconds, file=trace_file.name)
    for delay, kwargs in actions:
        time.sleep(delay)
        command(**kwargs)
    deadline = time.time() + seconds + 10
    while time.time() < deadline and not trace_file.exists():
        time.sleep(0.2)
    trace = json.loads(trace_file.read_text())
    samples = trace['samples']
    stalls, jumps, artwork, engines = [], [], [], []
    plateau_start = None
    for a, b in zip(samples, samples[1:]):
        dt, dpos = b['t'] - a['t'], b['time'] - a['time']
        if a['playing'] and b['playing'] and abs(dpos) < 1e-6:
            plateau_start = plateau_start if plateau_start is not None else a['t']
        else:
            if plateau_start is not None and a['t'] - plateau_start > 0.05:
                stalls.append(round(a['t'] - plateau_start, 3))
            plateau_start = None
        if dpos < -0.02 or dpos > max(0.3, dt * 8):
            jumps.append(dict(at=round(a['t'], 2), by=round(dpos, 3)))
        if not artwork or artwork[-1] != b['artwork']:
            artwork.append(b['artwork'])
        if not engines or engines[-1] != b['engine']:
            engines.append(b['engine'])
    command('close')
    return dict(stalls=stalls, jumps=jumps, artwork=artwork, engines=engines,
                episodeChanges=len(trace['notes']), samples=len(samples))


def transfer(path):
    """Bytes the fixture server sent for one path: total, distinct file bytes, bytes sent more
    than once, and the part fetched by AVFoundation's own loader (User-Agent AppleCoreMedia)."""
    entries = [r for r in requests if r['method'] == 'GET' and r['path'] == path and r.get('sent')]
    intervals = sorted((r['start'], r['start'] + r['sent']) for r in entries)
    total = sum(b - a for a, b in intervals)
    unique, current = 0, None
    for a, b in intervals:
        if current is None or a > current[1]:
            if current:
                unique += current[1] - current[0]
            current = [a, b]
        else:
            current[1] = max(current[1], b)
    if current:
        unique += current[1] - current[0]
    return dict(requests=len(entries), sent=total, unique=unique, duplicate=total - unique,
                avfoundation=sum(r['sent'] for r in entries if r['avfoundation']), file=len(fixture))


def stream_temp_files():
    """Temporary files of the engine's own stream source (ICSilenceTrimHTTPSource)."""
    return sorted(p.name for p in (container / 'tmp').glob('SilenceTrimStream-*'))


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
        # ---------------- S1: stream without stream cache (engine's own source) + separate download
        seed('s1', 'stream1.mp3', 'Stream ohne Cache')
        command('present', name='s1', at=300, autostart=True)
        s = wait(lambda s: s['ready'] and s['playing'], 30)
        check('S1 stream without stream cache plays on the engine with its own source',
              s['engine'] == 'silence-trim' and s.get('trimOwnSource') and s['assetURL'].startswith('instacast-silencetrim-metadata:'), s)
        check('S1 a temporary file holds the stream', len(stream_temp_files()) == 1, s, files=stream_temp_files())
        s = wait(lambda s: s.get('trimSaved', 0) > 1.2, 40)
        check('S1 pauses are shortened while streaming', s.get('trimSaved', 0) > 1.2 and s.get('statusText', '').endswith('gespart'), s)
        ui_ok = ui_test('saved-while-streaming', '''
     func testSavedWhileStreaming() {
      let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
      app.activate()
      let button=app.buttons["Wiedergabegeschwindigkeit"].firstMatch
      XCTAssertTrue(button.waitForExistence(timeout:5))
      button.tap()
      let saved=app.descendants(matching: .any).matching(NSPredicate(format:"label CONTAINS %@", "gespart")).firstMatch
      XCTAssertTrue(saved.waitForExistence(timeout:3))
      let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name="saved-while-streaming"; shot.lifetime = .keepAlways; add(shot)
      app.coordinate(withNormalizedOffset: CGVector(dx:0.9, dy:0.12)).tap()
     }''')
        check('S1 (UI) the menu shows the saved time while streaming', ui_ok, command())
        before = command()
        command('cache', name='s1')
        s = wait(lambda s: s.get('cached') and s.get('trimDecodesFile'), 150)
        check('S1 the separate download completes and the engine reads the file, still playing',
              s['engine'] == 'silence-trim' and s.get('trimDecodesFile') and s['playing'], s)
        check('S1 position kept', before['time'] - 1 < s['time'] < before['time'] + 150, s, before=before['time'])
        time.sleep(2)
        events = diagnostics()
        check('S1 no engine switch', len(switches(events, s['episodeHash'])) == 0, command())
        command('close')
        time.sleep(1)
        check('S1 the temporary stream file is deleted on close', not stream_temp_files(), command(), files=stream_temp_files())

        # ---------------- S2: stream with stream cache + manual download in parallel
        command('defaults', values={'AutoDownloadWhileStreaming': True})
        seed('s2', 'stream2.mp3', 'Stream mit Cache und Download')
        command('present', name='s2', at=600, autostart=True)
        s = wait(lambda s: s['ready'] and s['playing'], 30)
        check('S2 stream with stream cache plays on the engine', s['engine'] == 'silence-trim' and s.get('trimStream'), s)
        command('cache', name='s2')
        s = wait(lambda s: s['cached'] and s.get('trimDecodesFile') and s['playing'], 150)
        check('S2 once complete the engine reads the file, still playing', s['engine'] == 'silence-trim' and s.get('trimDecodesFile') and s['playing'], s)
        s2_hash = s['episodeHash']
        time.sleep(3)
        events = diagnostics()
        s2_switches = switches(events, s2_hash)
        check('S2 no engine switch for two parallel downloads', len(s2_switches) == 0,
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
        check('S3 no engine switch for the playing episode', s['engine'] == 'silence-trim' and len(switches(events, s2_hash)) == 0, s)
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
        s = wait(lambda s: s['ready'] and s['playing'], 30)
        check('S5 stream plays on the engine', s['engine'] == 'silence-trim' and s.get('trimStream'), s)
        time.sleep(2)
        command('pause')
        time.sleep(0.5)
        t_paused = command()['time']
        s = wait(lambda s: s.get('cached'), 150)
        time.sleep(1)
        s = command()
        check('S5 download completes while paused: still paused on the engine', s['engine'] == 'silence-trim' and s['paused'] and s['cached'], s)
        check('S5 paused position kept', abs(s['time'] - t_paused) < 0.05, s, before=t_paused)
        command('play')
        s = wait(lambda s: s['playing'] and s['time'] > t_paused + 1, 8)
        check('S5 resume plays on the engine', s['playing'] and s['engine'] == 'silence-trim', s)
        s = wait(lambda s: s.get('trimDecodesFile'), 40)
        check('S5 after resuming the engine moves to the file', s.get('trimDecodesFile') and s['playing'], s)
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
        check('S6 turning it on hands the downloaded file to the engine and keeps playing', s['engine'] == 'silence-trim' and s['playing'] and s.get('trimStream') is False, s)
        command('close')
        command('defaults', values={'PlayerSilenceTrimEnabled': True})

        # ---------------- S7: a stream slower than its bitrate through the real stream cache
        seed('s7', 'slow7.mp3', 'Langsamer Stream')
        command('present', name='s7', at=2400, autostart=True)
        s = wait(lambda s: s['ready'] and s['engine'] == 'silence-trim', 60)
        check('S7 slow stream opens on the engine', s['engine'] == 'silence-trim' and s.get('trimStream'), s)
        s = wait(lambda s: s.get('trimWaits', 0) >= 1, 90)
        check('S7 the clock waits for missing data', s.get('trimWaits', 0) >= 1 and s['engine'] == 'silence-trim', s)
        t_wait = s['time']
        time.sleep(25)
        s = command()
        check('S7 playback goes on between the waits', s['engine'] == 'silence-trim' and s['time'] > t_wait + 5 and not s['error'], s, before=t_wait)
        withdrawn_before = s.get('trimWithdrawn', 0)
        command('seek', time=4000)
        s = wait(lambda s: s['time'] > 4001, 60)
        check('S7 a seek into a part not downloaded plays there on the engine', s['time'] > 4001 and s['engine'] == 'silence-trim', s)
        check('S7 the stream cache withdrew the replaced decoder\'s waiting request', s.get('trimWithdrawn', 0) > withdrawn_before, s, before=withdrawn_before)
        events = diagnostics()
        failures = [e['metadata'] for e in events if e.get('message', '').startswith('Pausen-Engine fehlgeschlagen')
                    and e.get('metadata', {}).get('episodeHash') == s['episodeHash']]
        waits = [e for e in events if e.get('message') == 'Stream wartet auf Daten' and e.get('metadata', {}).get('episodeHash') == s['episodeHash']]
        check('S7 no engine failure, the waits are logged', not failures and len(waits) >= 1, command(), failures=failures, waits=len(waits))
        command('close')

        # ---------------- S8: the same without stream cache: the engine's own source
        command('defaults', values={'AutoDownloadWhileStreaming': False})
        seed('s8', 'slow8.mp3', 'Langsam ohne Cache')
        command('present', name='s8', at=2400, autostart=True)
        s = wait(lambda s: s['ready'] and s['engine'] == 'silence-trim', 60)
        check('S8 slow stream without cache opens on the engine with its own source', s['engine'] == 'silence-trim' and s.get('trimOwnSource'), s)
        s = wait(lambda s: s.get('trimWaits', 0) >= 1, 90)
        check('S8 the clock waits for missing data', s.get('trimWaits', 0) >= 1 and s['engine'] == 'silence-trim', s)
        t_wait = s['time']
        time.sleep(25)
        s = command()
        check('S8 playback goes on between the waits', s['engine'] == 'silence-trim' and s['time'] > t_wait + 5 and not s['error'], s, before=t_wait)
        withdrawn_before = s.get('trimWithdrawn', 0)
        command('seek', time=4000)
        s = wait(lambda s: s['time'] > 4001, 60)
        check('S8 a seek into a part not downloaded plays there on the engine', s['time'] > 4001 and s['engine'] == 'silence-trim', s)
        check('S8 the replaced decoder\'s waiting request was withdrawn', s.get('trimWithdrawn', 0) > withdrawn_before, s, before=withdrawn_before)
        events = diagnostics()
        failures = [e['metadata'] for e in events if e.get('message', '').startswith('Pausen-Engine fehlgeschlagen')
                    and e.get('metadata', {}).get('episodeHash') == s['episodeHash']]
        check('S8 no engine failure', not failures, command(), failures=failures)
        command('close')
        time.sleep(1)
        check('S8 the temporary stream file is deleted on close', not stream_temp_files(), command(), files=stream_temp_files())

        def engine_failures(episode_hash):
            return [e['metadata'] for e in diagnostics() if e.get('message', '').startswith('Pausen-Engine fehlgeschlagen')
                    and e.get('metadata', {}).get('episodeHash') == episode_hash]

        # ---------------- S9: stream cache on, the connection drops: the engine gives up, AVPlayer plays on
        command('defaults', values={'AutoDownloadWhileStreaming': True})
        seed('s9', 'failonce9.mp3', 'Abbruch mit Cache')
        command('present', name='s9', at=1800, autostart=True)
        s = wait(lambda s: s['engine'] == 'avplayer' and s['ready'] and s['playing'], 60)
        failures = engine_failures(s['episodeHash'])
        check('S9 the engine lost the stream and handed it to AVPlayer', len(failures) == 1 and str(failures[0].get('code')) == '3', s, failures=failures)
        t_fallback = s['time']
        time.sleep(4)
        s = command()
        check('S9 the stream plays on without shortening', s['engine'] == 'avplayer' and s['playing'] and s['time'] > t_fallback + 2
              and 1795 < s['time'] < 1900 and not s['error'], s, before=t_fallback)
        check('S9 the menu says shortening is off for this stream', s.get('statusText') == 'Für diesen Stream ausgeschaltet', s)
        command('close')

        # ---------------- S10: no stream cache, the server refuses the engine's own requests
        command('defaults', values={'AutoDownloadWhileStreaming': False})
        seed('s10', 'enginefail10.mp3', 'Engine-Fehler ohne Cache')
        command('present', name='s10', at=1800, autostart=True)
        s = wait(lambda s: s['engine'] == 'avplayer' and s['ready'] and s['playing'], 60)
        failures = engine_failures(s['episodeHash'])
        check('S10 the engine gave up on the stream and handed it to AVPlayer', len(failures) == 1 and str(failures[0].get('code')) == '3', s, failures=failures)
        t_fallback = s['time']
        time.sleep(4)
        s = command()
        check('S10 the stream plays on without shortening', s['engine'] == 'avplayer' and s['playing'] and s['time'] > t_fallback + 2
              and 1795 < s['time'] < 1900 and not s['error'], s, before=t_fallback)
        check('S10 the menu says shortening is off for this stream', s.get('statusText') == 'Für diesen Stream ausgeschaltet', s)
        command('close')
        time.sleep(1)
        check('S10 the temporary stream file is deleted', not stream_temp_files(), command(), files=stream_temp_files())

        # ---------------- S11: no stream cache, one dropped connection: the own source asks again
        seed('s11', 'failonce11.mp3', 'Einmal abgebrochen ohne Cache')
        command('present', name='s11', at=1800, autostart=True)
        s = wait(lambda s: s['ready'] and s['playing'] and s['time'] > 1803, 60)
        time.sleep(3)
        s = command()
        failures = engine_failures(s['episodeHash'])
        check('S11 a single dropped connection keeps the engine', s['engine'] == 'silence-trim' and s['playing'] and not failures, s, failures=failures)
        command('close')

    if want('T'):
        # ---------------- T: transfer per byte. Same steps for all four: start at 20:00, seek to
        # 50:00, back to 21:40; with stream caching until the download is complete.
        results = {}
        for label, enabled, caching in (('T1', True, True), ('T2', False, True), ('T3', True, False), ('T4', False, False)):
            command('defaults', values={'PlayerSilenceTrimEnabled': enabled, 'AutoDownloadWhileStreaming': caching})
            path = f'/stream{label}.mp3'
            seed(label.lower(), path[1:], f'Transfer {label}')
            command('present', name=label.lower(), at=1200, autostart=True)
            s = wait(lambda s: s['ready'] and s['playing'], 30)
            engine = s['engine']
            time.sleep(6)
            command('seek', time=3000)
            wait(lambda s: s['time'] > 3001, 30)
            time.sleep(4)
            command('seek', time=1300)
            wait(lambda s: s['time'] > 1301 and s['playing'], 30)
            if caching:
                s = wait(lambda s: s.get('cached'), 150)
            else:
                time.sleep(10)
            s = command()
            chapters = s.get('chapterCount', 0)
            command('close')
            time.sleep(2)
            results[label] = dict(transfer(path), engine=engine, cached=s.get('cached'), chapters=chapters)
            print(label, results[label], flush=True)
        command('defaults', values={'PlayerSilenceTrimEnabled': True, 'AutoDownloadWhileStreaming': False})
        for label in ('T1', 'T2'):
            r = results[label]
            check(f'{label} stream with stream cache: the file crossed the network once', r['cached'] and r['unique'] == r['file']
                  and r['duplicate'] <= r['file'] // 100, command(), **r)
        # Without stream caching only what is played (plus read-ahead) is fetched. Pieces already
        # on the wire when a seek cancels them count as sent twice; AVPlayer alone (T4) is the
        # measure. The engine must not open a second connection through AVFoundation.
        check('T3 stream without stream cache: one connection, no more sent twice than AVPlayer alone',
              results['T3']['avfoundation'] == 0 and results['T3']['duplicate'] <= max(results['T4']['duplicate'], 512 * 1024),
              command(), engine=results['T3'], avplayer=results['T4'])
        check('T chapters arrive the same with the engine as with AVPlayer, with and without stream cache',
              results['T2']['chapters'] > 0 and results['T1']['chapters'] == results['T2']['chapters'] and results['T3']['chapters'] == results['T4']['chapters'] == results['T2']['chapters'],
              command(), chapters={k: v['chapters'] for k, v in results.items()})
        check('T1/T3 the engine streams (pause shortening on)', results['T1']['engine'] == 'silence-trim' and results['T3']['engine'] == 'silence-trim', command(), results=results)

    if want('R'):
        # ---------------- R: settings written from outside the UI (iCloud apply, backup import)
        command('present', name='local', at=2000, autostart=True)
        s = wait(lambda s: s['ready'] and s['playing'] and s['engine'] == 'silence-trim', 20)
        check('R setup engine active', s['engine'] == 'silence-trim', s)
        s = wait(lambda s: s.get('trimSaved', 0) > 1.0, 60)
        saved_before = s.get('episodeSaved', 0)
        check('R0 the episode counter shows the engine\'s saved time', saved_before > 1.0 and abs(saved_before - s.get('trimSaved', 0)) < 0.1, s)
        command('defaults', values={'PlayerSilenceTrimEnabled': False})
        s = wait(lambda s: settled('silence-trim')(s) and s.get('trimLevel') == 0, 8)
        check('R1 switch turned off by sync: the playing episode goes on without shortening', s['engine'] == 'silence-trim' and s.get('trimLevel') == 0 and s['playing'], s)
        command('defaults', values={'PlayerSilenceTrimEnabled': True})
        s = wait(lambda s: settled('silence-trim')(s) and s.get('trimLevel') == 2, 8)
        check('R2 switch turned on by sync: shortening again', s['engine'] == 'silence-trim' and s.get('trimLevel') == 2 and s['playing'], s)
        check('R2 saved time of the episode continues after turning it off and on', s.get('episodeSaved', 0) >= saved_before - 0.05, s)
        s = wait(lambda s: s.get('episodeSaved', 0) > saved_before + 0.5, 60)
        check('R2 the episode counter keeps growing in the new engine instance', s.get('episodeSaved', 0) > saved_before + 0.5, s)
        command('defaults', values={'PlayerSilenceTrimLevel': 3})
        s = wait(lambda s: s.get('trimLevel') == 3, 5)
        check('R3 global level from sync applies to the playing episode', s.get('trimLevel') == 3, s)
        command('feedLevelRaw', name='local', level=0)
        s = wait(lambda s: s.get('trimLevel') == 0, 8)
        check('R4 podcast level "off" from sync applies at once', s.get('trimLevel') == 0 and s['playing'], s)
        command('feedLevelRaw', name='local', level=1)
        s = wait(lambda s: s['engine'] == 'silence-trim' and s.get('trimLevel') == 1, 5)
        check('R5 podcast level from sync turns it back on with that level', s['engine'] == 'silence-trim' and s.get('trimLevel') == 1, s)
        command('feedLevelRaw', name='local', level=None)
        s = wait(lambda s: s.get('trimLevel') == 3, 5)
        check('R6 podcast override removed by sync: global level again', s.get('trimLevel') == 3, s)
        check('R7 speech detection is the default and runs', s.get('defaultsDetection') == 1 and s.get('trimSpeechDetection') is True, s)
        command('defaults', values={'PlayerSilenceTrimDetection': 0})
        s = wait(lambda s: settled('silence-trim')(s) and s.get('trimSpeechDetection') is False, 8)
        check('R7 detection "loudness" from sync switches the playing engine without speech detection',
              s['engine'] == 'silence-trim' and s['playing'] and s.get('trimSpeechDetection') is False and s.get('trimLevel') == 3, s)
        command('defaults', values={'PlayerSilenceTrimDetection': 1})
        s = wait(lambda s: settled('silence-trim')(s) and s.get('trimSpeechDetection') is True, 8)
        check('R7 detection "speech" from sync turns speech detection back on', s['playing'] and s.get('trimSpeechDetection') is True, s)

    if want('B'):
        # ---------------- B: backup export and import
        command('defaults', values={'PlayerSilenceTrimEnabled': True, 'PlayerSilenceTrimLevel': 3, 'PlayerSilenceTrimDetection': 0})
        command('feedLevel', name='local', level=1)
        s = command('exportBackup')
        xml = Path(s['backupPath']).read_text(errors='replace')
        shutil.copy2(s['backupPath'], out / 'backup.xml')
        check('B1 backup contains the global switch', '<silenceTrimEnabled>true</silenceTrimEnabled>' in xml, s)
        check('B1 backup contains the global level', '<silenceTrimLevel>3</silenceTrimLevel>' in xml, s)
        check('B1 backup contains the pause detection', '<silenceTrimDetection>0</silenceTrimDetection>' in xml, s)
        # By the seeded feed's own URL: earlier runs on the same simulator leave podcasts with the
        # same title behind.
        feed_url = command('status', name='local')['feedURL']
        podcast = re.search(r'<podcast url="' + re.escape(feed_url) + r'"[^>]*>(.*?)</podcast>', xml, re.S)
        check('B1 backup contains the podcast level as integer', bool(podcast) and
              '<setting key="PlayerSilenceTrimLevel" type="integer" value="1"/>' in podcast.group(1), s)
        command('defaults', values={'PlayerSilenceTrimEnabled': False, 'PlayerSilenceTrimLevel': 0, 'PlayerSilenceTrimDetection': 1})
        command('feedLevelRaw', name='local', level=None)
        s = wait(lambda s: s.get('trimLevel') == 0, 5)
        check('B2 settings cleared before the import (shortening off, same player)', s.get('trimLevel') == 0 and s['defaultsLevel'] == 0, s)
        command('importBackup', categories=(1 << 7) | (1 << 2))
        done = directory / 'import-done.json'
        deadline = time.time() + 60
        while time.time() < deadline and not done.exists():
            time.sleep(0.5)
        result = json.loads(done.read_text()) if done.exists() else {'error': 'timeout'}
        s = wait(lambda s: s['engine'] == 'silence-trim' and s.get('trimLevel') == 1, 10)
        check('B2 import finished without error', not result.get('error'), s, result=result)
        check('B2 import restores switch, global level and podcast level', s['defaultsEnabled'] and s['defaultsLevel'] == 3 and s['feedOverride'] == 1, s)
        check('B2 import restores the pause detection and the engine follows it', s.get('defaultsDetection') == 0 and s.get('trimSpeechDetection') is False, s)
        command('defaults', values={'PlayerSilenceTrimDetection': 1})
        wait(lambda s: s.get('trimSpeechDetection') is True, 8)
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
        ui_ok = ui_test('detection-taps', '''
     func testDetectionTaps() {
      let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
      app.activate()
      app.navigationBars.buttons.element(boundBy:0).tap()
      sleep(1)
      let row=app.staticTexts["Pausen erkennen"].firstMatch
      var tries=0
      while !(row.exists && row.isHittable) && tries<6 { app.tables.firstMatch.swipeUp(velocity: .slow); tries+=1 }
      XCTAssertTrue(row.waitForExistence(timeout:3))
      XCTAssertTrue(app.staticTexts["Sprache (Silero)"].firstMatch.exists)
      row.tap()
      let loudness=app.staticTexts["Lautstärke"].firstMatch
      XCTAssertTrue(loudness.waitForExistence(timeout:3))
      let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot()); shot.name="detection-picker"; shot.lifetime = .keepAlways; add(shot)
      loudness.tap()
      sleep(1)
     }''')
        s = wait(lambda s: settled('silence-trim')(s) and s.get('trimSpeechDetection') is False, 8)
        check('U2 (UI) choosing "Lautstärke" under "Pausen erkennen" switches the playing engine without speech detection',
              ui_ok and s.get('defaultsDetection') == 0 and s.get('trimSpeechDetection') is False and s['playing'], s)
        command('defaults', values={'PlayerSilenceTrimDetection': 1})
        wait(lambda s: s.get('trimSpeechDetection') is True, 8)
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
    if want('W'):
        # ---------------- W: switching while playing never reopens the episode. Run it with a
        # fixture that has chapter artwork, e.g. LNP 564 with an image per minute.
        def switch_checks(label, result, engines):
            print(label, result, flush=True)
            art = result['artwork']
            check(f'{label} no "episode changed" notification', result['episodeChanges'] == 0, command(), **result)
            if 'avplayer' in engines:
                # A hand-over happens at a silent point (+-60 ms silent) at the same source time;
                # the engine's output starts about 80 ms later, which only lengthens that pause.
                events = [e for e in diagnostics() if e.get('message', '').startswith('Übergabe an')]
                planned = [e['metadata'] for e in events if e['message'] == 'Übergabe an stiller Stelle geplant']
                done = [e['metadata'] for e in events if e['message'] == 'Übergabe an die Pausen-Engine']
                exact = bool(done) and abs(float(done[-1]['avplayerTime']) - float(done[-1]['engineTime'])) < 0.002
                check(f'{label} the hand-over happens at a silent point at the same source time',
                      bool(planned) and planned[-1].get('silent') == '1' and exact, command(), planned=planned[-1:], done=done[-1:])
                check(f'{label} the audio keeps running: at most the hand-over pause (<= 150 ms), no jump',
                      len(result['stalls']) <= 1 and all(x <= 0.15 for x in result['stalls']) and not result['jumps'], command(), **result)
            else:
                check(f'{label} the audio keeps running: no stall over 50 ms, no jump', not result['stalls'] and not result['jumps'], command(), **result)
            check(f'{label} the chapter artwork stays (never back to the episode image)',
                  -1 not in art and art == sorted(art), command(), **result)
            check(f'{label} players: {" -> ".join(engines)}', result['engines'] == engines, command(), **result)

        command('defaults', values={'PlayerSilenceTrimEnabled': True, 'PlayerSilenceTrimLevel': 2, 'PlayerSilenceTrimDetection': 1,
                                    'AutoDownloadWhileStreaming': False})
        switch_checks('W1 engine: off and on again', switch_trace('w1', 1500, [
            (2.0, dict(action='menuLevel', level=0)), (3.0, dict(action='menuLevel', level=2))]), ['silence-trim'])
        command('defaults', values={'PlayerSilenceTrimLevel': 0})
        switch_checks('W2 AVPlayer: on (hand-over at a silent point), then off', switch_trace('w2', 1500, [
            (1.0, dict(action='menuLevel', level=2)), (6.0, dict(action='menuLevel', level=0))], seconds=12.0),
            ['avplayer', 'silence-trim'])
        command('defaults', values={'PlayerSilenceTrimLevel': 0, 'AutoDownloadWhileStreaming': True})
        seed('w3', 'streamW3.mp3', 'Umschalten im Stream')
        switch_checks('W3 stream with stream cache: on while AVPlayer streams', switch_trace('w3', 1500, [
            (1.0, dict(action='menuLevel', level=2))], seconds=12.0, name='w3'), ['avplayer', 'silence-trim'])
        command('defaults', values={'PlayerSilenceTrimLevel': 2, 'AutoDownloadWhileStreaming': False})
        switch_checks('W4 engine: pause detection Silero -> level -> Silero', switch_trace('w4', 1500, [
            (2.0, dict(action='defaults', values={'PlayerSilenceTrimDetection': 0})),
            (3.0, dict(action='defaults', values={'PlayerSilenceTrimDetection': 1}))]), ['silence-trim'])

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
