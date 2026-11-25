#!/usr/bin/env python3
"""Launch the actual signed Catalyst app and retain startup/window geometry evidence.

The test-only UIKit driver calls production navigation handlers. It never replaces
methods or window geometry. Resize the real window between --action invocations.
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
import shutil

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--setup', action='store_true')
p.add_argument('--action', default='{"action":"status"}')
p.add_argument('--label', default='startup')
p.add_argument('--sweep', action='store_true')
p.add_argument('--verify-player', action='store_true')
p.add_argument('--verify-control-rows', action='store_true')
p.add_argument('--verify-bottom-spacing', action='store_true')
p.add_argument('--verify-list-expanded', action='store_true')
p.add_argument('--verify-cover-at-top', action='store_true')
p.add_argument('--verify-disclosure', action='store_true')
p.add_argument('--verify-list-headers', action='store_true')
p.add_argument('--verify-system-volume', action='store_true')
p.add_argument('--verify-native-volume-position', action='store_true')
p.add_argument('--verify-tools', action='store_true')
p.add_argument('--verify-tool-glyphs', action='store_true')
p.add_argument('--verify-player-glyphs', action='store_true')
p.add_argument('--verify-transcript', action='store_true')
args = p.parse_args()
out = args.evidence.resolve()
out.mkdir(parents=True, exist_ok=True)


def run(command):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    with (out / 'commands.log').open('a') as f:
        f.write(shlex.join(command) + '\n' + result.stdout)
    if result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


with (out / 'commands.log').open('a') as f:
    f.write(shlex.join([sys.executable, *sys.argv]) + '\n')
directory = Path.home() / 'Library/Containers/com.iteconomy.instacastplus.mac/Data/Documents/AdaptiveLayoutProbe'
directory.mkdir(parents=True, exist_ok=True)
if not (directory / 'fixture.wav').exists():
    with wave.open(str(directory / 'fixture.wav'), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(8000)
        w.writeframes(b'\0\0' * 8000 * 180)
process = None
if args.setup:
    sdk = run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    library = out / 'AdaptiveLayoutProbe.dylib'
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-macabi',
         '-isysroot', sdk, '-iframework', sdk + '/System/iOSSupport/System/Library/Frameworks',
         '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'CoreData', '-framework', 'CoreGraphics',
         str(ROOT / 'Tools/fixtures/adaptive_layout_probe.m'), '-o', str(library)])
    run(['codesign', '-s', 'Apple Development', str(library)])
    (out / 'environment.json').write_text(json.dumps({
        'command': shlex.join([sys.executable, *sys.argv]),
        'app': str(args.app.resolve()), 'sdk': sdk,
        'expected': 'Signed production app stays running and returns real window geometry; no startup crash.',
        'signing': run(['codesign', '-d', '--entitlements', ':-', str(args.app.resolve())]),
        'sourceSHA256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in [
            Path(__file__).resolve(), ROOT / 'Tools/fixtures/adaptive_layout_probe.m',
            ROOT / 'Classes/PlaybackControlsViewController.m', ROOT / 'Classes/PlayerInfoViewController_v5.m']},
        'binarySHA256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in (args.app / 'Contents/MacOS').glob('InstacastPlus*') if path.is_file()},
    }, indent=2))
    # LaunchServices keeps subsequent native-app inspection attached to this
    # same instrumented instance instead of starting a second executable.
    run(['open', '-a', str(args.app.resolve()), '--stdout', str(out / 'stdout.log'),
         '--stderr', str(out / 'stderr.log'), '--env', 'DYLD_INSERT_LIBRARIES=' + str(library),
         '--args', '-AppleLanguages', '(de)'])
if args.sweep:
    def command(action):
        request = dict(action, id=str(uuid.uuid4()))
        temp = directory / 'command.tmp'
        temp.write_text(json.dumps(request))
        temp.replace(directory / 'command.json')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                reply = json.loads((directory / 'reply.json').read_text())
                if reply.get('id') == request['id']:
                    assert 'error' not in reply, reply.get('error')
                    return reply
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(.1)
        raise AssertionError('No Mac response: ' + str(action))

    def capture(label, action):
        command(action)
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
        state = command({'action': 'status', 'capture': True})
        shutil.copy2(directory / 'screen.png', out / (name + '.png'))
        (out / (name + '.json')).write_text(json.dumps(state, indent=2))
        print(json.dumps({'screen': name, 'top': state['top'], 'window': state['window']}), flush=True)

    command({'action': 'dismiss'})
    command({'action': 'fixture'})
    for tag, name in [(2, 'podcasts'), (11, 'favorites'), (9, 'unplayed'), (12, 'started'),
                      (3, 'lists'), (7, 'up-next'), (4, 'bookmarks'), (6, 'downloads'), (8, 'settings')]:
        capture(name, {'action': 'select', 'tag': tag})
    for row in range(10):
        command({'action': 'select', 'tag': 8})
        capture('settings-' + str(row), {'action': 'settingsRow', 'row': row})
    command({'action': 'select', 'tag': 2})
    capture('episode', {'action': 'episode'})
    capture('player', {'action': 'player'})
    sys.exit(0)
request = dict(json.loads(args.action), id=str(uuid.uuid4()))
temp = directory / 'command.tmp'
temp.write_text(json.dumps(request))
temp.replace(directory / 'command.json')
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    if process and process.poll() is not None:
        result = {'passed': False, 'exitCode': process.returncode, 'expected': 'App remains running', 'observed': 'Startup process exited'}
        (out / (args.label + '-checks.json')).write_text(json.dumps(result, indent=2))
        raise AssertionError(result)
    try:
        reply = json.loads((directory / 'reply.json').read_text())
        if reply.get('id') == request['id']:
            break
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    time.sleep(.1)
else:
    raise AssertionError('No response from Catalyst app')
previous = None
stable = 0
deadline = time.monotonic() + 15
while time.monotonic() < deadline and stable < 6:
    signature = (reply.get('top'), str(reply.get('controllers')), str(reply.get('window')))
    tools_ready = not args.verify_tools or any(c.get('transcriptAvailable') for c in reply.get('controllers', []))
    stable = stable + 1 if signature == previous and tools_ready else 0
    previous = signature
    status = {'action': 'status', 'id': str(uuid.uuid4())}
    temp.write_text(json.dumps(status))
    temp.replace(directory / 'command.json')
    response_deadline = time.monotonic() + 5
    while time.monotonic() < response_deadline:
        time.sleep(.1)
        current = json.loads((directory / 'reply.json').read_text())
        if current.get('id') == status['id']:
            reply = current
            break
if request.get('capture'):
    # Render after navigation and geometry have settled, not at the start of
    # a presentation animation when the command was first handled.
    capture = {'action': 'status', 'capture': True, 'id': str(uuid.uuid4())}
    temp.write_text(json.dumps(capture))
    temp.replace(directory / 'command.json')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        time.sleep(.1)
        current = json.loads((directory / 'reply.json').read_text())
        if current.get('id') == capture['id']:
            reply = current
            break
    else:
        raise AssertionError('No settled screenshot from Catalyst app')
    shutil.copy2(directory / 'screen.png', out / (args.label + '.png'))
    for glyph in directory.glob('glyph-*.png'):
        shutil.copy2(glyph, out / (args.label + '-' + glyph.name))
(out / (args.label + '.json')).write_text(json.dumps(reply, indent=2))
assert 'error' not in reply, reply.get('error')
failures = []
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
if args.verify_tool_glyphs:
    controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
    glyph = controls['transcriptGlyph']
    source, rendered = glyph['imageSize'], glyph['renderedSize']
    scale_x, scale_y = rendered[0] / source[0], rendered[1] / source[1]
    if not glyph['visible'] or abs(scale_x - scale_y) > .01:
        failures.append(f'Transcript symbol is hidden or distorted: {glyph}')
if args.verify_control_rows:
    controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
    frames = controls['controlFrames']
    bottom = controls['frame'][1] + controls['frame'][3] - controls['safeArea'][2]
    if any(b['frame'][3] < 44 or b['frame'][1] + b['frame'][3] > bottom + .5 for b in controls['tools']):
        failures.append('Tool targets extend into the bottom safe area')
    transport_bottom = max(frames[k][1] + frames[k][3] for k in ['playButton', 'backButton', 'forwardButton'])
    volume_top = min(frames[k][1] for k in ['volumeMinButton', 'volumeMaxButton'])
    volume_bottom = max(frames[k][1] + frames[k][3] for k in ['volumeMinButton', 'volumeMaxButton'])
    if transport_bottom > volume_top + .5 or volume_bottom > min(b['frame'][1] for b in controls['tools']) + .5:
        failures.append('Playback, volume and bottom tool touch rows overlap')
if args.verify_system_volume or args.verify_native_volume_position:
    controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
    sliders = [s for s in controls['systemVolume']['children'] if 'Slider' in s['class'] and not s['hidden'] and s['alpha'] > .01]
    if not sliders or sliders[0]['trackFrame'][2] < 80:
        failures.append('The real system volume slider is not visible')
    else:
        track = sliders[0]['trackFrame']
        frames = controls['controlFrames']
        low, high = frames['volumeMinButton'], frames['volumeMaxButton']
        if track[0] < low[0] + low[2] - .5 or track[0] + track[2] > high[0] + .5:
            failures.append('The volume track overlaps its speaker buttons')
        if args.verify_native_volume_position:
            shift = controls['systemVolume']['frame'][1] - frames['volumeHitView'][1]
            if abs(shift) > .5:
                failures.append(f'The native volume view was shifted down by {shift} points')
            for glyph in controls['playerGlyphs']:
                if glyph['key'] in ['volumeMinButton', 'volumeMaxButton']:
                    frame = glyph['frame']
                    if abs(frame[1] + frame[3] / 2 - track[1] - track[3] / 2) > .5:
                        failures.append(f'{glyph["key"]} is not aligned with the native volume track')
if failures:
    (out / (args.label + '-checks.json')).write_text(json.dumps({'passed': False, 'failures': failures}, indent=2))
    raise AssertionError(failures)
if args.verify_player:
    info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
    controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
    artwork = info['artworkFrame']
    assert artwork[1] + artwork[3] <= controls['frame'][1] + 1, f'Artwork is clipped by controls: {artwork} versus {controls["frame"]}'
if args.verify_tools:
    controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
    tools = sorted(controls['tools'], key=lambda t: t['frame'][0])
    assert controls['transcriptAvailable'] and len(tools) == 4, f'Transcript replaces AirPlay in the four available tool slots: {tools}'
    assert [tool['class'] for tool in tools] == ['UIButton', 'PlayerSpeedButton', 'PlayerTimerButton', 'UIButton'], f'Player tool order changed during resizing: {tools}'
    assert tools[0]['frame'][0] >= 0 and tools[-1]['frame'][0] + tools[-1]['frame'][2] <= reply['window'][2], tools
    for left, right in zip(tools, tools[1:]):
        assert left['frame'][0] + left['frame'][2] <= right['frame'][0], f'Tool targets overlap: {left} / {right}'
if args.verify_transcript:
    info = next(c for c in reply['controllers'] if c['class'] == 'PlayerInfoViewController_v5')
    assert info['transcriptVisible'] and 'Beispieltranskript' in info['transcriptText'], info
    controls = next(c for c in reply['controllers'] if c['class'] == 'PlaybackControlsViewController')
    frame = info['transcriptFrame']
    assert frame[0] >= 0 and frame[0] + frame[2] <= reply['window'][2] + 1 and frame[1] + frame[3] <= controls['frame'][1] + 1, info
result = {'passed': True, 'window': reply['window'], 'minimum': reply['sizeMinimum'], 'top': reply['top']}
(out / (args.label + '-checks.json')).write_text(json.dumps(result, indent=2))
print(json.dumps(result))
