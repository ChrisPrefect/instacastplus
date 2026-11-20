#!/usr/bin/env python3
"""E2E for Olaf's mixed normal/selection rows (TestFlight 20 November 2026).

Runs the real app, Core Data smart list and UIKit edit action, then selects rows,
recycles cells by scrolling, reloads rows and returns from background. Evidence
retains exact commands, fixtures, source/binary hashes, snapshots and screenshots.
The probe observes live cell geometry; it does not replace production behavior.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid', required=True)
p.add_argument('--app', required=True, type=Path)
p.add_argument('--evidence', required=True, type=Path)
p.add_argument('--require-diagnostics', action='store_true', help='Require production selection-state records in the exported diagnostic log')
args = p.parse_args()
out = args.evidence.resolve(); out.mkdir(parents=True, exist_ok=True)


def run(command, check=True, env=None):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    with (out / 'commands.log').open('a') as log:
        log.write(shlex.join(command) + '\n' + result.stdout)
    if check and result.returncode:
        raise RuntimeError(result.stdout)
    return result.stdout.strip()


devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
runtime, device = next((r,d) for r,ds in devices.items() for d in ds if d['udid'] == args.udid)
assert device['name'] == 'Instacast Selection Regression' and device['state'] == 'Booted'
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
probe = ROOT / 'Tools/fixtures/selection_editing_probe.m'; library = out / 'SelectionEditingProbe.dylib'
run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
     '-isysroot', sdk, '-framework', 'UIKit', '-framework', 'CoreData', str(probe), '-o', str(library)])
run(['codesign', '-s', '-', str(library)])
run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
run(['xcrun', 'simctl', 'uninstall', args.udid, BUNDLE], check=False)
run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
directory = container / 'Documents/SelectionEditingProbe'; directory.mkdir(parents=True, exist_ok=True)
with wave.open(str(out/'fixture.wav'),'wb') as audio:
    audio.setparams((1,2,8000,0,'NONE','not compressed'))
    audio.writeframes(b'\0\0'*8000*60)
shutil.copy2(out/'fixture.wav',directory/'fixture.wav')
run(['xcrun','simctl','ui',args.udid,'appearance','dark'])
for name in ['command.json', 'reply.json']:
    (directory / name).unlink(missing_ok=True)
files = [probe, Path(__file__).resolve(), ROOT / 'Classes/EpisodesTableViewCell.m', ROOT / 'Classes/EpisodesTableViewController.m']
shutil.copy2(probe,out/probe.name)
shutil.copy2(Path(__file__).resolve(),out/Path(__file__).name)
(out / 'environment.json').write_text(json.dumps(dict(
    command=shlex.join(['python3', *os.sys.argv]), device=device, runtime=runtime,
    fixture='80 unplayed episodes with different title/description lengths and row heights in the real neue Episoden smart list; select rows 1 and 3; add three new episodes during selection; paused 60-second WAV player',
    expected='Every visible row shows the editing layout and keeps its cover; no Play button in selection mode; normal layout returns on exit',
    sourceSHA256={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
    binarySHA256={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in args.app.glob('InstacastPlus*') if f.is_file()}), indent=2))
run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}',
     args.udid, BUNDLE, '-AppleLanguages', '(de)'], env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
project=out/'Startup.xcodeproj';project.mkdir(exist_ok=True)
shutil.copy2(ROOT/'Tools/fixtures/chapter_scroll_ui_project.pbxproj',project/'project.pbxproj')
(out/'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests:XCTestCase {
 func testStartup() {
  XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus").activate()
  let system=XCUIApplication(bundleIdentifier:"com.apple.springboard")
  for title in ["Nicht erlauben","Don't Allow","Don’t Allow"] {
   let button=system.alerts.buttons[title]
   if button.waitForExistence(timeout:1) {button.tap();break}
  }
  XCTAssertEqual(system.alerts.count,0,system.debugDescription)
 }
}
''')
native=run(['xcodebuild','-project',str(project),'-scheme','NativeScrollTests','-destination','platform=iOS Simulator,id='+args.udid,
            '-derivedDataPath',str(out/'NativeDerived'),'-parallel-testing-enabled','NO','-resultBundlePath',str(out/'startup.xcresult'),'test'],check=False)
assert '** TEST SUCCEEDED **' in native,native[-3500:]


def command(action='status', **params):
    request = dict(id=str(uuid.uuid4()), action=action, **params)
    (directory / 'command.tmp').write_text(json.dumps(request)); (directory / 'command.tmp').replace(directory / 'command.json')
    deadline = time.monotonic()+30
    while time.monotonic()<deadline:
        try:
            reply=json.loads((directory / 'reply.json').read_text())
            if reply.get('id')==request['id']:
                with (out / 'observations.jsonl').open('a') as log: log.write(json.dumps(dict(request=request,reply=reply))+'\n')
                assert 'error' not in reply, reply
                return reply
        except (FileNotFoundError,json.JSONDecodeError): pass
        time.sleep(.05)
    raise AssertionError(request)


def wait(predicate):
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        state=command()
        if predicate(state): return state
        time.sleep(.05)
    raise AssertionError(state)


checks=[]


def native_phase(name, body):
    (out/'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests:XCTestCase {
 func testTransition() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
''' + body + '''
  let evidence=XCTAttachment(screenshot:app.screenshot());evidence.lifetime = .keepAlways;add(evidence)
 }
}
''')
    native=run(['xcodebuild','-project',str(project),'-scheme','NativeScrollTests','-destination','platform=iOS Simulator,id='+args.udid,
                '-derivedDataPath',str(out/'NativeDerived'),'-parallel-testing-enabled','NO','-resultBundlePath',str(out/(name+'.xcresult')),'test'],check=False)
    assert '** TEST SUCCEEDED **' in native,native[-3500:]


def check(name, editing=True):
    state=command()
    cells=state['visible']
    passed=bool(cells) and all(c['editing']==editing and c['playHidden']==editing and c['imageWidth']>0
                              and (c['contentX']>=40 if editing else abs(c['contentX'])<1) for c in cells)
    checks.append(dict(name=name,passed=passed,observed=state))
    (out / 'checks.json').write_text(json.dumps(checks,indent=2))
    run(['xcrun','simctl','io',args.udid,'screenshot',str(out/(name+'.png'))])
    print(name, 'PASS' if passed else 'FAIL',json.dumps(cells),flush=True)


try:
    command('seed');state=wait(lambda s:s['rows']>=25 and bool(s['visible']) and s['playerReady'])
    command('scroll',row=0)
    command('toggle');wait(lambda s:s['editing'])
    command('select',row=1);command('select',row=3)
    check('enter-selection')
    while state['rows']<80:
        count=state['rows'];command('scroll',row=count-1);state=wait(lambda s:s['rows']>count)
        check('page-in-selection-'+str(count))
    for row in [25,55,0]:
        command('scroll',row=row);check('scroll-'+str(row))
    command('reload');check('reload-in-selection')
    command('refresh');wait(lambda s:not s['loading'] and not s['replacing']);check('refresh-in-selection')
    native_phase('selection-lifecycle', '''
  app.tables.firstMatch.swipeUp()
  app.tables.firstMatch.swipeDown()
  XCUIDevice.shared.orientation = .landscapeLeft
  XCUIDevice.shared.orientation = .portrait
  XCUIDevice.shared.press(.home)
  app.activate()
  XCTAssertTrue(app.buttons["Fertig"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
''')
    check('selection-after-lifecycle')
    command('toggle');wait(lambda s:not s['editing']);check('exit-selection',editing=False)
    command('scroll',row=0)
    native_phase('swipe-to-selection', '''
  app.tables.firstMatch.cells.element(boundBy:1).swipeLeft()
  app.buttons["Bearbeiten"].firstMatch.tap()
  // The first tap closes an open UIKit swipe; the next enters multi-selection.
  if !app.buttons["Fertig"].firstMatch.exists {app.buttons["Bearbeiten"].firstMatch.tap()}
  XCTAssertTrue(app.buttons["Fertig"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
  app.buttons["alle"].firstMatch.tap()
  for row in [0,1,3] {app.tables.firstMatch.cells.element(boundBy:row).tap()}
''')
    check('selection-after-swipe')
    command('arrivals');wait(lambda s:not s['loading'] and not s['replacing']);check('selection-after-arrivals')
    for cycle in range(12):
        command('toggle');command('refresh');command('toggle')
        wait(lambda s:not s['loading'] and not s['replacing'])
        command('scroll',row=25 if cycle%2==0 else 0)
        check('reenter-during-refresh-'+str(cycle))
finally:
    shutil.copytree(container/'Documents/Logs',out/'Logs',dirs_exist_ok=True)
    run(['xcrun','simctl','terminate',args.udid,BUNDLE],check=False)
if args.require_diagnostics:
    events=[json.loads(line) for line in (out/'Logs/Diagnostics.jsonl').read_text().splitlines()]
    selection=[event for event in events if event.get('category')=='episode-selection']
    reasons={event.get('metadata',{}).get('reason') for event in selection}
    required={'editing-requested','editing-applied','selected','deselected','reload-completed','cell-transition'}
    passed=required.issubset(reasons)
    checks.append(dict(name='selection-diagnostics',passed=passed,observed=selection))
    (out/'checks.json').write_text(json.dumps(checks,indent=2))
    print('selection-diagnostics','PASS' if passed else 'FAIL',sorted(str(r) for r in reasons),flush=True)
raise SystemExit(0 if all(c['passed'] for c in checks) else 1)
