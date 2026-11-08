#!/usr/bin/env python3
"""Measure the unmodified, uninjected simulator app from macOS libproc.

Calls the app's real episode URL route, backgrounds it with native app switching,
and retains cumulative CPU (converted with mach_timebase_info), physical footprint,
RSS, lifecycle/playback logs and exact inputs. No app-side sampling timers run.
"""
import argparse
import ctypes
from datetime import datetime,timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import uuid

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid',required=True)
p.add_argument('--hash',required=True)
p.add_argument('--evidence',type=Path,required=True)
args=p.parse_args();out=args.evidence.resolve();out.mkdir(parents=True,exist_ok=True)
bundle='com.iteconomy.instacastplus'


def sim(*command,check=True):
    env={key:value for key,value in os.environ.items() if key!='SIMCTL_CHILD_DYLD_INSERT_LIBRARIES'}
    result=subprocess.run(['xcrun','simctl',*command],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    with (out/'commands.log').open('a') as log:log.write(shlex.join(['xcrun','simctl',*command])+'\n'+result.stdout)
    if check and result.returncode:raise RuntimeError(result.stdout)
    return result.stdout.strip()


devices=json.loads(sim('list','devices','-j'))['devices']
device=next(d for group in devices.values() for d in group if d['udid']==args.udid)
assert device['name'].startswith('Instacast Stress ') and device['state']=='Booted'
sim('terminate',args.udid,bundle,check=False)
container=Path(sim('get_app_container',args.udid,bundle,'data'))
probe_telemetry=container/'Documents/LifecycleStress/telemetry.jsonl'
probe_bytes_before=probe_telemetry.stat().st_size if probe_telemetry.exists() else None
directory=container/'Documents/ResourceBaseline';directory.mkdir(parents=True,exist_ok=True)
for name in ['request.json','reply.json','ready.json']:(directory/name).unlink(missing_ok=True)
project=out/'Native.xcodeproj';project.mkdir(exist_ok=True)
shutil.copy2(Path(__file__).resolve().parent/'fixtures/chapter_scroll_ui_project.pbxproj',project/'project.pbxproj')
(out/'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests:XCTestCase {
 func testResources() throws {
  let directory=URL(fileURLWithPath:DIRECTORY)
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard")
  XCUIDevice.shared.orientation = .portrait
  app.launchArguments=["-PlaybackVolume","0","-UISoundEnabled","NO","-AutoCacheNewAudioEpisodes","NO"]
  app.launchEnvironment=[:]
  app.launch()
  try Data("{}".utf8).write(to:directory.appendingPathComponent("ready.json"))
  let deadline=Date().addingTimeInterval(600)
  while Date()<deadline {
   let path=directory.appendingPathComponent("request.json")
   guard let data=try? Data(contentsOf:path),let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:String],let id=request["id"] else {Thread.sleep(forTimeInterval:0.1);continue}
   try? FileManager.default.removeItem(at:path)
   let action=request["action"] ?? ""
   if action=="finish" {return}
   if action=="home" {
    if BACKGROUND_WITH_SETTINGS {XCUIApplication(bundleIdentifier:"com.apple.Preferences").activate()}
    else {XCUIDevice.shared.press(.home)}
    XCTAssertTrue(app.wait(for:.runningBackground,timeout:10) || app.state == .runningBackgroundSuspended)
   }
   if action=="acceptURL" {
    let preferences=XCUIApplication(bundleIdentifier:"com.apple.Preferences")
    for _ in 0..<5 {
     var accepted=false
     for button in [spring.alerts.buttons["Öffnen"],spring.alerts.buttons["Open"],preferences.alerts.buttons["Öffnen"],preferences.alerts.buttons["Open"]] {
      if button.waitForExistence(timeout:1) {button.tap();accepted=true;break}
     }
     if !accepted || spring.alerts.count==0 {break}
    }
    XCTAssertEqual(spring.alerts.count,0)
    app.activate()
    XCTAssertTrue(app.wait(for:.runningForeground,timeout:10))
   }
   if action=="pause" {
    app.activate()
    let button=app.buttons["Pause"].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout:10));button.tap()
   }
   try JSONSerialization.data(withJSONObject:["id":id,"state":app.state.rawValue]).write(to:directory.appendingPathComponent("reply.json"),options:.atomic)
  }
 }
}
'''.replace('DIRECTORY',json.dumps(str(directory))).replace('BACKGROUND_WITH_SETTINGS','true' if device['name'].endswith('Duo') else 'false'))
native_log=(out/'native-ui.log').open('w')
native=subprocess.Popen(['xcodebuild','-project',str(project),'-scheme','NativeScrollTests',
    '-destination','platform=iOS Simulator,id='+args.udid,'-derivedDataPath',str(out/'NativeDerived'),
    '-parallel-testing-enabled','NO','-resultBundlePath',str(out/'Native.xcresult'),'test'],stdout=native_log,stderr=subprocess.STDOUT)
deadline=time.monotonic()+150
while not (directory/'ready.json').exists():
    if native.poll() is not None or time.monotonic()>deadline:raise RuntimeError('Native baseline startup failed')
    time.sleep(.2)
pid=int(sim('launch',args.udid,bundle,'-PlaybackVolume','0','-UISoundEnabled','NO','-AutoCacheNewAudioEpisodes','NO').rsplit(':',1)[1])


def ui(action):
    request=dict(id=str(uuid.uuid4()),action=action)
    temp=directory/'request.tmp';temp.write_text(json.dumps(request));temp.replace(directory/'request.json')
    deadline=time.monotonic()+40
    while time.monotonic()<deadline:
        try:
            reply=json.loads((directory/'reply.json').read_text())
            if reply['id']==request['id']:return reply
        except (FileNotFoundError,json.JSONDecodeError):pass
        time.sleep(.1)
    raise RuntimeError('Native action failed: '+action)


class Usage(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_ubyte*16)]+[(key,ctypes.c_uint64) for key in
        ['user','system','idleWakeups','interruptWakeups','pageins','wired','resident','footprint','start','exit']]


class Timebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]


base=Timebase();system=ctypes.CDLL('/usr/lib/libSystem.B.dylib');system.mach_timebase_info(ctypes.byref(base))
lib=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
started=time.time();samples=[];markers=[]
(out/'environment.json').write_text(json.dumps(dict(command=shlex.join([sys.executable,*sys.argv]),device=device,
    started=datetime.now(timezone.utc).isoformat(),pid=pid,episodeHash=args.hash,
    instrumentation='External proc_pid_rusage RUSAGE_INFO_V0 only; no custom injected probe, profiler or app-side sampling timers. Native XCTest switches UI; Apple UI automation/AX support is present.',
    machTimebase=dict(numer=base.numer,denom=base.denom),limits='Simulator process CPU/physical footprint; no hardware energy or jetsam claim'),indent=2))


def measure(name,seconds):
    print('PHASE '+name,flush=True);markers.append(dict(name=name,timestamp=time.time()))
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        usage=Usage()
        if lib.proc_pid_rusage(pid,0,ctypes.byref(usage))!=0:raise OSError(ctypes.get_errno(),'proc_pid_rusage failed')
        sample=dict(timestamp=time.time(),cpuSeconds=(usage.user+usage.system)*base.numer/base.denom/1e9,
            footprintBytes=usage.footprint,residentBytes=usage.resident,state=dict(phase=name,applicationState=None))
        samples.append(sample)
        with (out/'telemetry.jsonl').open('a') as log:log.write(json.dumps(sample)+'\n')
        time.sleep(1)


try:
    measure('uninjected-foreground-paused',25)
    ui('home');measure('uninjected-background-paused',40)
    sim('openurl',args.udid,f'instacastplus://episode/{args.hash}?action=openplay')
    ui('acceptURL')
    measure('uninjected-foreground-playback',25)
    ui('home');measure('uninjected-background-playback',75)
    ui('pause')
    measure('uninjected-paused-after-playback',15)
finally:
    logs=container/'Documents/Logs'
    if logs.exists():shutil.copytree(logs,out/'Logs',dirs_exist_ok=True)
    sim('terminate',args.udid,bundle,check=False);sim('terminate',args.udid,'com.apple.Preferences',check=False)
    request=dict(id=str(uuid.uuid4()),action='finish');(directory/'request.json').write_text(json.dumps(request))
    try:native.wait(timeout=40)
    except subprocess.TimeoutExpired:native.terminate();native.wait(timeout=10)
    native_log.close()
    (out/'phases.json').write_text(json.dumps(markers,indent=2))
events=[]
path=out/'Logs/Diagnostics.jsonl'
if path.exists():
    for line in path.read_text().splitlines():
        try:event=json.loads(line);timestamp=datetime.fromisoformat(event['timestamp'].replace('Z','+00:00')).timestamp()
        except (ValueError,KeyError,json.JSONDecodeError):continue
        if timestamp>=started:events.append(event)
background=[e for e in events if e.get('category')=='background-playback' and e.get('metadata',{}).get('episodeHash')==args.hash
            and e.get('metadata',{}).get('playbackPaused') in ['false','0']]
probe_bytes_after=probe_telemetry.stat().st_size if probe_telemetry.exists() else None
result=dict(passed=bool(background) and native.returncode==0 and probe_bytes_after==probe_bytes_before,
    customProbeTelemetryUnchanged=probe_bytes_after==probe_bytes_before,customProbeBytesBefore=probe_bytes_before,customProbeBytesAfter=probe_bytes_after,
    nativeExitCode=native.returncode,backgroundPlaybackCheckpoints=background,
    lifecycle=[e for e in events if e.get('category')=='lifecycle'],samples=len(samples),
    expected='Normal app background playback is confirmed by production logs; resources are measured externally')
(out/'result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print('PASS uninjected production background checkpoints' if result['passed'] else 'FAIL no production background playback checkpoint',flush=True)
if not result['passed']:raise SystemExit(1)
