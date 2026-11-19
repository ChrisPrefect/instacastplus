#!/usr/bin/env python3
"""E2E: Appearance's icon suggestion opens the actual default mail app.

Requires agent-desktop and a configured default email application. Runs the real
button through native mouse input and reads real Accessibility trees; no UIKit
or Mail doubles. Never sends mail. Leaves only its new draft open for attachment
verification / cleanup. Refuses to use an existing draft with the same subject.
Retains exact commands, app/OS identity, real UI trees and screenshots.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SUBJECTS = {'de': 'App-Icon-Vorschlag', 'en': 'App Icon Suggestion'}
BODIES = {
    'de': 'Bitte hängen Sie Ihre Icon-Dateien an oder fügen Sie einen Link zu Ihrem Entwurf ein.',
    'en': 'Please attach your icon files or include a link to your design.',
}


def nodes(tree):
    yield tree
    for child in tree.get('children', []):
        yield from nodes(child)


def label(node):
    return node.get('AXDescription') or node.get('AXTitle') or node.get('AXValue', '')


def center(node):
    x, y = node['AXPosition']
    width, height = node['AXSize']
    return x + width / 2, y + height / 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--language', choices=SUBJECTS, default='de', help='Current app language; does not change settings')
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)
    assert not (out / 'result.json').exists(), 'Use a fresh evidence directory'
    app = args.app.resolve()
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    bundle = info['CFBundleIdentifier']
    subject = SUBJECTS[args.language]
    body = BODIES[args.language]

    def run(command):
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(command) + '\n' + result.stdout + '\n')
        assert result.returncode == 0, result.stdout[-5000:]
        return result.stdout

    def desktop(*arguments):
        return run(['agent-desktop', *map(str, arguments)])

    def click(node):
        x, y = center(node)
        desktop('--headed', 'mouse-click', '--xy', f'{x},{y}')

    def screenshot(node, name):
        x, y = node['AXPosition']
        width, height = node['AXSize']
        run(['screencapture', '-x', '-R' + ','.join(str(round(v)) for v in (x, y, width, height)), str(out / (name + '.png'))])

    environment = {
        'command': shlex.join([sys.executable, *sys.argv]), 'os': run(['sw_vers']),
        'app': str(app), 'bundle': bundle, 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'language': args.language,
        'binarySHA256': hashlib.sha256((app / 'Contents/MacOS' / info['CFBundleExecutable']).read_bytes()).hexdigest(),
        'debugCodeSHA256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in (app / 'Contents/MacOS').glob('*.debug.dylib')},
        'sourceSHA256': hashlib.sha256((ROOT / 'Classes/AppearanceSettingsViewController.m').read_bytes()).hexdigest(),
        'expected': {'recipient': 'info@instacast.ch', 'subject': subject, 'body': body,
                     'externalDefaultMailApp': True, 'embeddedComposer': False},
        'precondition': 'An existing user profile with Settings available and a configured default mail application; no existing draft with the test subject.',
    }
    (out / 'environment.json').write_text(json.dumps(environment, indent=2))
    observed = {}
    try:
        with tempfile.TemporaryDirectory(prefix='instacast-icon-mail-') as temp:
            probe = str(Path(temp) / 'probe')
            run(['swiftc', str(ROOT / 'Tools/fixtures/icon_suggestion_mail_ui_probe.swift'), '-o', probe])

            def state(target, title=None):
                return json.loads(run([probe, target, *([title] if title else [])]))

            assert not state('default-mail', subject)['windows'], 'An existing draft uses the test subject; preserve it and close it before running this test.'
            run(['open', str(app)])
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                current = state(bundle)
                if current['windows']:
                    break
                time.sleep(0.2)
            else:
                raise AssertionError('App did not show a window')
            assert not any(w.get('AXTitle') == 'Mail' for w in current['windows']), 'Close the existing embedded draft before running the test'
            main_window = next(w for w in current['windows'] if w.get('AXIdentifier') == 'SceneWindow')
            for attempt in range(14):
                current = state(bundle)
                flat = [n for w in current['windows'] for n in nodes(w)]
                suggestion = next((n for n in flat if label(n) in ('App Icon vorschlagen', 'Suggest App Icon')), None)
                if suggestion:
                    break
                appearance = next((n for n in flat if n.get('AXRole') == 'AXButton' and label(n) in ('Darstellung', 'Appearance')), None)
                settings = next((n for n in flat if label(n) in ('Einstellungen', 'Settings') and n.get('AXRole') != 'AXHeading'), None)
                sidebar = next((n for n in flat if label(n) == 'Sidebar Item'), None)
                title = next((n for n in flat if n.get('AXRole') == 'AXHeading' and label(n) in ('Darstellung', 'Appearance')), None)
                if appearance:
                    click(appearance)
                elif not title and settings:
                    click(settings)
                elif not title and sidebar:
                    click(sidebar)
                else:
                    x, y = center(main_window)
                    desktop('--headed', 'mouse-wheel', '--x', x, '--y', y, '--dy', -8)
                time.sleep(0.2)
            else:
                raise AssertionError('Could not reach Appearance > Suggest App Icon')
            (out / 'before-app.json').write_text(json.dumps(current, indent=2))
            screenshot(main_window, 'before-app')
            click(suggestion)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                current = state(bundle)
                mail = state('default-mail', subject)
                observed = {'app': current, 'defaultMail': mail}
                (out / 'after-ui.json').write_text(json.dumps(observed, indent=2))
                embedded = next((w for w in current['windows'] if w.get('AXTitle') == 'Mail'), None)
                if embedded:
                    screenshot(main_window, 'embedded-composer-failure')
                    raise AssertionError('The icon suggestion still presents an embedded mail composer instead of handing off to the default mail app')
                if mail['windows'] and mail['frontmostBundle'] == mail['defaultMailBundle']:
                    compose = mail['windows'][0]
                    values = '\n'.join(str(n.get(k, '')) for n in nodes(compose)
                                       for k in ('AXValue', 'AXTitle', 'AXDescription'))
                    # Mail creates its window before its editable web content is ready.
                    if all(expected in values for expected in ['info@instacast.ch', subject, body]):
                        break
                time.sleep(0.2)
            else:
                raise AssertionError('The default mail app did not show the correctly prefilled draft')
            compose = mail['windows'][0]
            values = '\n'.join(str(n.get(k, '')) for n in nodes(compose) for k in ('AXValue', 'AXTitle', 'AXDescription'))
            for expected in ['info@instacast.ch', subject, body]:
                assert expected in values, f'Missing or incorrectly encoded mail field: {expected}'
            screenshot(compose, 'default-mail-draft')
            environment['defaultMailPath'] = mail['defaultMailPath']
            (out / 'environment.json').write_text(json.dumps(environment, indent=2))
            (out / 'result.json').write_text(json.dumps({'passed': True, 'observed': observed, 'sent': False}, indent=2))
            print('PASS: actual default mail app opened with recipient and localized subject/body; no embedded composer. No email sent.')
    except Exception as error:
        (out / 'result.json').write_text(json.dumps({'passed': False, 'error': str(error), 'observed': observed, 'sent': False}, indent=2))
        raise


if __name__ == '__main__':
    main()
