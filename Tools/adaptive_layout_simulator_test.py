#!/usr/bin/env python3
"""Drive the real app's navigation and retain layout evidence on a booted simulator.

Use --setup once, then --action with a JSON command (menu, select/tag, row/section,
back, dismiss, scrollMenu/end, or status). Native fold/rotation/window operations
are performed in Device Hub between invocations, never by faking view bounds.
--verify-menu checks safe-area containment, vertical balance and scroll reachability.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--udid', required=True)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--evidence', type=Path, required=True)
    p.add_argument('--setup', action='store_true')
    p.add_argument('--skip-install', action='store_true', help='Recompile/relaunch the probe while keeping the installed app and its container')
    p.add_argument('--action', default='{"action":"status"}')
    p.add_argument('--label', default='status')
    p.add_argument('--display', default='1')
    p.add_argument('--verify-menu', action='store_true')
    p.add_argument('--verify-content', action='store_true')
    p.add_argument('--verify-rotation', action='store_true')
    p.add_argument('--expected-orientation', type=int, choices=[1, 2, 3, 4], help='Scene UIInterfaceOrientation after a native fold/rotation; inner display axes differ from UIDevice.orientation')
    p.add_argument('--verify-tablet-window', action='store_true')
    p.add_argument('--verify-player', action='store_true')
    p.add_argument('--verify-player-safe-content', action='store_true')
    p.add_argument('--verify-control-rows', action='store_true')
    p.add_argument('--verify-bottom-spacing', action='store_true')
    p.add_argument('--verify-list-expanded', action='store_true')
    p.add_argument('--verify-cover-at-top', action='store_true')
    p.add_argument('--verify-disclosure', action='store_true')
    p.add_argument('--verify-list-headers', action='store_true')
    p.add_argument('--verify-tools', action='store_true')
    p.add_argument('--verify-tool-glyphs', action='store_true')
    p.add_argument('--verify-player-glyphs', action='store_true')
    p.add_argument('--verify-fold', action='store_true')
    p.add_argument('--verify-rows', action='store_true')
    p.add_argument('--verify-transcript', action='store_true')
    p.add_argument('--expected-top')
    p.add_argument('--sweep', action='store_true', help='Capture all main destinations, settings sections, episode and player')
    args = p.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(cmd, check=True, env=None):
        r = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        with (out / 'commands.log').open('a') as f:
            f.write(shlex.join(cmd) + '\n' + r.stdout)
        if check and r.returncode:
            raise RuntimeError(r.stdout)
        return r.stdout.strip()

    with (out / 'commands.log').open('a') as f:
        f.write(shlex.join([sys.executable, *sys.argv]) + '\n')
    lib = out / 'AdaptiveLayoutProbe.dylib'
    if args.setup:
        sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
        source = ROOT / 'Tools/fixtures/adaptive_layout_probe.m'
        run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
             '-isysroot', sdk, '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'CoreGraphics', str(source), '-o', str(lib)])
        run(['codesign', '-s', '-', str(lib)])
        run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
        if not args.skip_install:
            run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
        (out / 'environment.json').write_text(json.dumps({
            'devices': json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j'])),
            'app': str(args.app.resolve()), 'sdk': sdk,
            'binarySHA256': {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
                             for f in args.app.glob('InstacastPlus*') if f.is_file()},
            'expected': 'All menu rows inside safe area when they fit; balanced free space; all rows reachable when scrolling.',
            'scope': 'Real app navigation and UIKit rendering; native geometry changes via Device Hub. No replaced methods.'
        }, indent=2))
        run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid, BUNDLE,
             '-AppleLanguages', '(de)'], env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(lib)))
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
    directory = container / 'Documents/AdaptiveLayoutProbe'
    directory.mkdir(parents=True, exist_ok=True)
    audio = directory / 'fixture.wav'
    if not audio.exists():
        with wave.open(str(audio), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(8000)
            w.writeframes(b'\0\0' * 8000 * 180)
    if args.sweep:
        def command(action):
            request = dict(action, id=str(uuid.uuid4()))
            tmp = directory / 'command.tmp'
            tmp.write_text(json.dumps(request))
            tmp.replace(directory / 'command.json')
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                try:
                    reply = json.loads((directory / 'reply.json').read_text())
                    if reply.get('id') == request['id']:
                        assert 'error' not in reply, reply.get('error')
                        return reply
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(.1)
            raise AssertionError('No app response: ' + str(action))

        def capture(label, action):
            applied = command(action)
            if applied.get('selectionApplied') is False:
                (out / (args.label + '-' + label + '-unavailable.json')).write_text(json.dumps(applied, indent=2))
                return
            previous = None
            stable = 0
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and stable < 6:
                state = command({'action': 'status'})
                signature = (state['top'], str(state['controllers']), str(state['window']))
                stable = stable + 1 if signature == previous else 0
                previous = signature
                time.sleep(.1)
            name = args.label + '-' + label
            (out / (name + '.json')).write_text(json.dumps({'action': action, 'observed': state}, indent=2))
            run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', '--display=' + args.display, str(out / (name + '.png'))])
            print(json.dumps({'screen': name, 'top': state['top'], 'window': state['window']}), flush=True)

        command({'action': 'dismiss'})
        command({'action': 'fixture'})
        for tag, name in [(2, 'podcasts'), (11, 'favorites'), (9, 'unplayed'), (12, 'started'),
                          (3, 'lists'), (7, 'up-next'), (4, 'bookmarks'), (6, 'downloads'), (13, 'transcription'), (14, 'watch'), (8, 'settings')]:
            capture(name, {'action': 'select', 'tag': tag})
        for row in range(10):
            command({'action': 'select', 'tag': 8})
            capture('settings-' + str(row), {'action': 'settingsRow', 'row': row})
        command({'action': 'select', 'tag': 2})
        capture('episode', {'action': 'episode'})
        capture('player', {'action': 'player'})
        return
    request = dict(json.loads(args.action), id=str(uuid.uuid4()))
    tmp = directory / 'command.tmp'
    tmp.write_text(json.dumps(request))
    tmp.replace(directory / 'command.json')
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        try:
            reply = json.loads((directory / 'reply.json').read_text())
            if reply.get('id') == request['id']:
                break
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.1)
    else:
        raise AssertionError('App probe did not reply')
    # Presentation and transcript loading finish asynchronously. Observe actual
    # UIKit state until geometry settles before checking the rendered result.
    previous = None
    stable = 0
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and stable < 6:
        signature = (reply.get('top'), str(reply.get('controllers')), str(reply.get('window')))
        tools_ready = not args.verify_tools or any(c.get('transcriptAvailable') for c in reply.get('controllers', []))
        stable = stable + 1 if signature == previous and tools_ready else 0
        previous = signature
        status = {'action': 'status', 'id': str(uuid.uuid4())}
        tmp.write_text(json.dumps(status))
        tmp.replace(directory / 'command.json')
        response_deadline = time.monotonic() + 5
        while time.monotonic() < response_deadline:
            time.sleep(.1)
            current = json.loads((directory / 'reply.json').read_text())
            if current.get('id') == status['id']:
                reply = current
                break
    (out / (args.label + '.json')).write_text(json.dumps({'request': request, 'observed': reply}, indent=2))
    run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', '--display=' + args.display, str(out / (args.label + '.png'))])
    assert 'error' not in reply, reply.get('error')
    failures = []
    if args.verify_list_headers:
        info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        left, right = info['frame'][0] + info['safeArea'][1], info['frame'][0] + info['frame'][2] - info['safeArea'][3]
        top, bottom = info['frame'][1] + info['safeArea'][0], controls['frame'][1]
        for header in info['listHeaders']:
            for visual in header['visuals']:
                f = visual['frame']
                if f[1] < bottom and f[1] + f[3] > top and (f[0] < left - .5 or f[0] + f[2] > right + .5):
                    failures.append(f'List header {visual["key"]} overlaps side controls: {f}, safe interval [{left}, {right}]')
    if args.verify_disclosure:
        info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
        if not info['chevronInteractive'] or not info['chevronHittable'] or min(info['chevronFrame'][2:]) < 44:
            failures.append(f'Chapter disclosure needs a reachable 44-point target: {info["chevronFrame"]}, hittable={info["chevronHittable"]}')
    if args.verify_cover_at_top:
        info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
        if abs(info['offset'][1] + info['adjustedInset'][0]) > 1:
            failures.append(f'Cover did not return to the top after manual scrolling: offset {info["offset"]}, inset {info["adjustedInset"]}')
    if args.verify_bottom_spacing:
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        bottom = controls['frame'][1] + controls['frame'][3] - controls['safeArea'][2]
        gap = bottom - max(b['frame'][1] + b['frame'][3] for b in controls['tools'])
        if gap < 12 - .5:
            failures.append(f'Bottom tool row needs 12 points of breathing room above the safe area, observed {gap}')
    if args.verify_list_expanded:
        info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
        top = info['frame'][1] + info['safeArea'][0]
        if abs(info['listHeaderFrame'][1] - top) > 1:
            failures.append(f'Chapter list did not reach usable top {top}: {info["listHeaderFrame"]}, offset {info["offset"]}')
    if args.expected_orientation is not None:
        if reply['orientation']['interface'] != args.expected_orientation:
            failures.append(f'Expected native display orientation {args.expected_orientation}, observed {reply["orientation"]}')
    if args.verify_tool_glyphs:
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        glyph = controls['transcriptGlyph']
        source, rendered = glyph['imageSize'], glyph['renderedSize']
        scale_x, scale_y = rendered[0] / source[0], rendered[1] / source[1]
        if not glyph['visible'] or abs(scale_x - scale_y) > .01:
            failures.append(f'Transcript symbol is hidden or distorted: source={source}, rendered={rendered}, scale=[{scale_x}, {scale_y}]')
    if args.verify_player_glyphs:
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        for glyph in controls['playerGlyphs']:
            source, rendered = glyph['imageSize'], glyph['renderedSize']
            sx, sy = rendered[0] / source[0], rendered[1] / source[1]
            if abs(sx / sy - 1) > .02:
                failures.append(f'{glyph["key"]} stretches its image: source={source}, rendered={rendered}')
            if 'referenceAlphaSize' in glyph:
                a, b = glyph['sourceAlphaSize'], glyph['referenceAlphaSize']
                if abs((a[0] / a[1]) / (b[0] / b[1]) - 1) > .03:
                    failures.append(f'{glyph["key"]} artwork distorts the native SF symbol: actual alpha={a}, reference alpha={b}')
    if args.verify_player_safe_content:
        info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
        art = info['artworkFrame']
        left = info['frame'][0] + info['safeArea'][1]
        right = info['frame'][0] + info['frame'][2] - info['safeArea'][3]
        if art[0] < left - .5 or art[0] + art[2] > right + .5:
            failures.append(f'Cover lies behind side navigation: {art}, usable horizontal interval [{left}, {right}]')
    if args.verify_control_rows:
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        frames = controls['controlFrames']
        bottom = controls['frame'][1] + controls['frame'][3] - controls['safeArea'][2]
        for button in controls['tools']:
            f = button['frame']
            if f[3] < 44 or f[1] + f[3] > bottom + .5:
                failures.append(f'Tool target extends into bottom safe area or is below 44 points: {f}, usable bottom {bottom}')
        transport_bottom = max(frames[key][1] + frames[key][3] for key in ['playButton', 'backButton', 'forwardButton'])
        volume_top = min(frames[key][1] for key in ['volumeMinButton', 'volumeMaxButton'])
        volume_bottom = max(frames[key][1] + frames[key][3] for key in ['volumeMinButton', 'volumeMaxButton'])
        volume_hit = frames['volumeHitView']
        if volume_hit[1] < volume_top - .5 or volume_hit[1] + volume_hit[3] > volume_bottom + .5:
            failures.append(f'Volume gesture area extends into adjacent touch rows: {volume_hit}')
        tools_top = min(b['frame'][1] for b in controls['tools'])
        if transport_bottom > volume_top + .5:
            failures.append(f'Playback and volume touch rows overlap: {transport_bottom} > {volume_top}')
        if volume_bottom > tools_top + .5:
            failures.append(f'Volume and bottom tool touch rows overlap: {volume_bottom} > {tools_top}')
    if args.expected_top and reply['top'] != args.expected_top:
        failures.append(f'Expected {args.expected_top}, observed {reply["top"]}')
    if args.verify_transcript:
        info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        frame = info['transcriptFrame']
        if not info['transcriptVisible'] or 'Beispieltranskript' not in info['transcriptText']:
            failures.append('The real SRT fixture is not readable in the transcript view')
        if frame[0] < 0 or frame[0] + frame[2] > reply['window'][2] + 1 or frame[1] + frame[3] > controls['frame'][1] + 1:
            failures.append('Transcript is clipped by the window or player controls')
        search = info.get('transcriptSearchFrame')
        if search and (search[0] < info['safeArea'][1] - .5 or search[0] + search[2] > reply['window'][2] - info['safeArea'][3] + .5):
            failures.append(f'Transcript search is under the side navigation: {search}, safe area {info["safeArea"]}')
    if args.verify_tools:
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        tools = sorted(controls['tools'], key=lambda t: t['frame'][0])
        if not controls['transcriptAvailable'] or len(tools) != 4:
            failures.append('Transcript fixture must replace AirPlay in the four available tool slots')
        if [tool['class'] for tool in tools] != ['UIButton', 'PlayerSpeedButton', 'PlayerTimerButton', 'UIButton']:
            failures.append(f'Player tool order changed during resizing: {tools}')
        if tools[0]['frame'][0] < 0 or tools[-1]['frame'][0] + tools[-1]['frame'][2] > reply['window'][2]:
            failures.append('Player tools extend beyond the window')
        if any(a['frame'][0] + a['frame'][2] > b['frame'][0] + .01 for a, b in zip(tools, tools[1:])):
            failures.append('Player tool targets overlap')
    if args.verify_fold:
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        play = controls['playFrame']
        for region in controls['divisionRegions']:
            if max(play[0], region[0]) < min(play[0] + play[2], region[0] + region[2]) and max(play[1], region[1]) < min(play[1] + play[3], region[1] + region[3]):
                failures.append(f'Play target crosses the active fold: {play} versus {region}')
    if args.verify_rows:
        table = next(c for c in reply['controllers'] if c['class'] == reply['top'])
        for row in table['rows']:
            if row.get('cellClass') not in ['EpisodesTableViewCell', 'BookmarksTableViewCell', 'SubscriptionTableViewCell', 'PlayerBookmarksTableViewCell', 'ChaptersTableViewCell']:
                continue
            visuals = {v['key']: v['frame'] for v in row.get('visuals', [])}
            for name, frame in visuals.items():
                if frame[0] < table['frame'][0] + table['safeArea'][1] - .5 or frame[0] + frame[2] > table['frame'][0] + table['frame'][2] - table['safeArea'][3] + .5:
                    failures.append(f'{row["cellClass"]} {name} is clipped horizontally: {frame}')
            if 'titleLabel' in visuals and 'dateLabel' in visuals and visuals['titleLabel'][1] + visuals['titleLabel'][3] > visuals['dateLabel'][1] + .5:
                failures.append(f'Episode title overlaps its date: {visuals}')
    if args.verify_player:
        info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
        controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
        artwork = info['artworkFrame']
        if artwork[0] < -.5 or artwork[0] + artwork[2] > reply['window'][2] + .5:
            failures.append(f'Artwork extends beyond the window: {artwork} versus {reply["window"]}')
        for cell in info.get('artworkCells', []):
            if cell[0] < -.5 or cell[0] + cell[2] > reply['window'][2] + .5:
                failures.append(f'Visible artwork page is clipped horizontally: {cell} versus {reply["window"]}')
        if artwork[1] + artwork[3] > controls['frame'][1] + 1:
            failures.append(f'Artwork is clipped by controls: {artwork} versus {controls["frame"]}')
    if args.verify_tablet_window:
        if reply['sizeMinimum'][0] > 320 or reply['sizeMinimum'][1] > 480:
            failures.append(f'Tablet window minimum excludes compact split/window sizes: {reply["sizeMinimum"]}')
    if args.verify_content:
        container = next(c for c in reply['controllers'] if c['class'] == 'StatusBarFixingViewController')
        navigation = next(c for c in reply['controllers'] if c['class'] == 'PortraitNavigationController')
        if container['frame'] != navigation['frame']:
            failures.append(f'Navigation does not fill its container: {navigation["frame"]} versus {container["frame"]}')
    if args.verify_rotation:
        for c in reply['controllers']:
            if not (c['orientations'] & 24):
                failures.append(f'{c["class"]} rejects landscape')
    if args.verify_menu:
        menu = next(c for c in reply['controllers'] if c['class'] == 'MainSidebarController')
        rows = menu['rows']
        top = menu['frame'][1] + menu['safeArea'][0]
        bottom = menu['frame'][1] + menu['frame'][3] - menu['safeArea'][2]
        content_height = sum(r['frame'][3] for r in rows)
        first_y = rows[0]['frame'][1]
        last_y = rows[-1]['frame'][1] + rows[-1]['frame'][3]
        if content_height + 32 <= bottom - top:
            if first_y < top - 1 or last_y > bottom + 1:
                failures.append(f'Menu clipped: first={first_y}, last={last_y}, safe=[{top},{bottom}]')
            if abs((first_y - top) - (bottom - last_y)) > 3:
                failures.append(f'Menu unbalanced: top gap={first_y-top}, bottom gap={bottom-last_y}')
        elif not menu['scrollEnabled']:
            failures.append('Overflowing menu cannot scroll')
        if request['action'] == 'scrollMenu' and request.get('end') and last_y > bottom + 1:
            failures.append(f'Last menu row is clipped at scroll end: {last_y} > {bottom}')
        if request['action'] == 'scrollMenu' and request.get('end') and not rows[-1]['hitInCell']:
            failures.append(f'Last menu row is covered by {rows[-1]["hitClass"]}')
        if first_y < top - 1 and request['action'] == 'menu':
            failures.append('First menu item starts above safe area')
    result = {'label': args.label, 'window': reply.get('window'), 'top': reply.get('top'), 'failures': failures}
    (out / (args.label + '-checks.json')).write_text(json.dumps(result, indent=2))
    print(json.dumps(result))
    assert not failures, failures


if __name__ == '__main__':
    main()
