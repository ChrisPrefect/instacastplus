#!/usr/bin/env python3
"""Real-device E2E: a crash-log mail draft survives Home and Photos.

Uses the installed app, native MessageUI account, Photos and XCTest input. Never
sends mail. Retains exact command, device/app identity, native UI and screenshots,
and the app's actual diagnostics. Native mode requires an unlocked paired device.
Screenshot mode validates the retained native Device Hub flow if XCTest cannot
install its runner on the target. Capture the draft before and after the switch;
--text-marker additionally verifies unsent body text survives.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--device', required=True)
p.add_argument('--evidence', type=Path, required=True)
p.add_argument('--before-screenshot', type=Path, help='Verify actual Device Hub screenshots when XCTest runner installation is unavailable')
p.add_argument('--after-screenshot', type=Path)
p.add_argument('--transition', choices=['home','photos'], default='home')
p.add_argument('--text-marker', help='Require this unsent body text to survive along with the draft')
args = p.parse_args()
out = args.evidence.resolve(); out.mkdir(parents=True, exist_ok=True)
assert args.before_screenshot or not (out/'result.xcresult').exists(), 'Use a fresh evidence directory'


def run(command, check=True):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    with (out/'commands.log').open('a') as log:
        log.write(shlex.join(command)+'\n'+result.stdout+'\n')
    if check and result.returncode:
        raise RuntimeError(result.stdout[-4500:])
    return result


if args.before_screenshot:
    # Failure: the real MessageUI title/subject disappears and Settings replaces it.
    # If XCTest cannot install its runner, validate the native E2E's retained
    # screenshots instead, without UI doubles.
    assert args.after_screenshot
    swift=out/('Recognize-'+args.transition+'.swift')
    swift.write_text('''import AppKit
import Vision
import Foundation
var results:[[String:Any]]=[]
for path in CommandLine.arguments.dropFirst() {
 let image=NSImage(contentsOfFile:path)!
 var rect=NSRect(origin:.zero,size:image.size)
 let bitmap=image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!
 let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
 request.recognitionLanguages=["en-US","de-DE"]
 try VNImageRequestHandler(cgImage:bitmap).perform([request])
 let text=request.results!.compactMap{$0.topCandidates(1).first?.string}
 results.append(["file":path,"text":text,"composerVisible":text.contains{$0.contains("Crash Logs InstacastPlus")}])
}
let data=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
print(String(data:data,encoding:.utf8)!)
''')
    executable=out/('Recognize-'+args.transition)
    run(['swiftc',str(swift),'-o',str(executable)])
    observed=json.loads(run([str(executable),str(args.before_screenshot.resolve()),str(args.after_screenshot.resolve())]).stdout)
    executable.unlink()
    assert observed[0]['composerVisible'], 'Invalid initial state: no real crash-log mail draft'
    marker_present=lambda state: not args.text_marker or args.text_marker.casefold() in '\n'.join(state['text']).casefold()
    assert marker_present(observed[0]), 'Invalid initial state: test text missing'
    passed=observed[1]['composerVisible'] and marker_present(observed[1])
    (out/('screenshot-check-'+args.transition+'.json')).write_text(json.dumps(dict(
        command=shlex.join([sys.executable,*sys.argv]), transition=args.transition,
        expected='The existing crash-log mail draft remains visible after returning from '+args.transition,
        textMarker=args.text_marker,observed=observed,passed=passed),indent=2))
    print('PASS: draft survived' if passed else 'FAIL: crash-log mail draft disappeared after '+args.transition)
    raise SystemExit(0 if passed else 1)


run(['xcrun','devicectl','device','info','apps','--device',args.device,'--json-output',str(out/'apps.json')])
run(['xcrun','devicectl','device','info','details','--device',args.device,'--json-output',str(out/'device.json')])
project = out/'MailLifecycle.xcodeproj'; project.mkdir(exist_ok=True)
template=(ROOT/'Tools/fixtures/chapter_scroll_ui_project.pbxproj').read_text()
template=template.replace('SDKROOT = iphonesimulator;', 'SDKROOT = iphoneos;')
template=template.replace('com.iteconomy.instacastplus.ChapterScrollTests','com.iteconomy.instacastplus.MailLifecycleTests')
(project/'project.pbxproj').write_text(template)
(out/'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests:XCTestCase {
 func capture(_ app:XCUIApplication,_ name:String) {
  let image=XCTAttachment(screenshot:app.screenshot());image.name=name;image.lifetime = .keepAlways;add(image)
  let tree=XCTAttachment(string:app.debugDescription);tree.name=name+"-accessibility";tree.lifetime = .keepAlways;add(tree)
 }
 func testCrashLogDraftSurvivesHomeAndPhotos() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let title=app.descendants(matching:.any).matching(NSPredicate(format:"label CONTAINS %@","Crash Logs InstacastPlus")).firstMatch
  if !title.exists {
   let row=app.staticTexts["Crash Logs per Mail schicken"].firstMatch
   XCTAssertTrue(row.waitForExistence(timeout:10),app.debugDescription)
   row.tap()
  }
  XCTAssertTrue(title.waitForExistence(timeout:10),app.debugDescription)
  capture(app,"draft-before-switch")
  XCUIDevice.shared.press(.home)
  app.activate()
  capture(app,"draft-after-home")
  XCTAssertTrue(title.waitForExistence(timeout:8),"Crash-log mail draft disappeared after Home: "+app.debugDescription)
  let photos=XCUIApplication(bundleIdentifier:"com.apple.mobileslideshow")
  photos.activate()
  capture(photos,"photos-foreground")
  app.activate()
  capture(app,"draft-after-return")
  XCTAssertTrue(title.waitForExistence(timeout:8),"Crash-log mail draft disappeared after Photos: "+app.debugDescription)
 }
}
''')
files=[Path(__file__).resolve(), ROOT/'Classes/OptionsViewController.m', ROOT/'Classes/ICAppearanceManager.m',ROOT/'Classes/InstacastSceneDelegate.m']
(out/'environment.json').write_text(json.dumps(dict(
    command=shlex.join([sys.executable,*sys.argv]), device=args.device,
    input='Open Settings > Crash Logs per Mail schicken; Home and return; Photos and return; never press Send',
    expected='The same MessageUI draft remains visible after both Home and Photos',
    sourceSHA256={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in files}),indent=2))
shutil.copy2(Path(__file__).resolve(),out/'driver.py')
result=run(['xcodebuild','-project',str(project),'-scheme','NativeScrollTests',
            '-destination','platform=iOS,id='+args.device,'-derivedDataPath',str(out/'NativeDerived'),
            '-parallel-testing-enabled','NO','-allowProvisioningUpdates','-resultBundlePath',str(out/'result.xcresult'),'test'],check=False)
run(['xcrun','devicectl','device','copy','from','--device',args.device,
     '--domain-type','appDataContainer','--domain-identifier',BUNDLE,'--source','Documents/Logs',
     '--destination',str(out/'Logs')],check=False)
passed=result.returncode==0 and '** TEST SUCCEEDED **' in result.stdout
(out/'result.json').write_text(json.dumps(dict(passed=passed,commandExitCode=result.returncode),indent=2))
print(result.stdout[-4500:])
raise SystemExit(0 if passed else 1)
