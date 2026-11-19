#!/usr/bin/env python3
"""Verify customer icons in a built app and through native Settings UI on a disposable simulator.

Retains the exact command, app hash, environment, compiler renditions, screenshots
and XCTest results. Requires a booted simulator named Instacast Customer Icons.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'
NAMES = ['Creme', 'Espresso', 'Glow']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)
    app = args.app.resolve()

    def run(command, check=True):
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(command) + '\n' + result.stdout + '\n')
        if check:
            assert result.returncode == 0, result.stdout[-8000:]
        return result.stdout.strip()

    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
    runtime, device = next((r, d) for r, group in devices.items() for d in group if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Customer Icons' and device['state'] == 'Booted', device
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    (out / 'environment.json').write_text(json.dumps({
        'command': shlex.join([sys.executable, *sys.argv]), 'runtime': runtime, 'device': device,
        'app': str(app), 'appSHA256': hashlib.sha256((app / info['CFBundleExecutable']).read_bytes()).hexdigest(),
        'expected': 'All three icons are compiled, selectable, acknowledged by iOS, selected after relaunch and visible on the Home Screen.',
        'renditions': 'Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark via Apple Icon Composer; Home Screen appearance customization is not automated.',
    }, indent=2))
    for key in ['CFBundleIcons', 'CFBundleIcons~ipad']:
        alternates = info[key]['CFBundleAlternateIcons']
        for name in NAMES:
            assert f'InstacastPlus_Icon_{name}' in alternates, f'{key}: missing compiled {name}'

    ictool = Path(run(['xcode-select', '-p'])).parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'
    renders = out / 'renditions'
    renders.mkdir(exist_ok=True)
    for name in NAMES:
        for rendition in ['Default', 'Dark', 'TintedLight', 'TintedDark', 'ClearLight', 'ClearDark']:
            run([str(ictool), str(ROOT / f'Resources/AppIcons/InstacastPlus_Icon_{name}.icon'),
                 '--export-image', '--output-file', str(renders / f'{name}-{rendition}.png'),
                 '--platform', 'iOS', '--rendition', rendition, '--width', '256', '--height', '256', '--scale', '1'])
        assert (renders / f'{name}-Default.png').read_bytes() != (renders / f'{name}-Dark.png').read_bytes(), name
    run(['xcrun', 'simctl', 'uninstall', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(app)])
    project = out / 'CustomerIcons.xcodeproj'
    project.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
    shutil.copyfile(ROOT / 'Tools/fixtures/customer_app_icons_ui.swift', out / 'NativeScrollTests.swift')
    run(['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests',
         '-destination', 'platform=iOS Simulator,id=' + args.udid,
         '-derivedDataPath', str(out / 'NativeDerived'), '-parallel-testing-enabled', 'NO',
         '-resultBundlePath', str(out / 'ui.xcresult'), 'test'])
    print('PASS: compiled customer icons, six native renditions each, Settings selection, Home Screen and relaunch')


if __name__ == '__main__':
    main()
