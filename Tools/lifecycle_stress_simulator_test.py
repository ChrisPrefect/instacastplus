#!/usr/bin/env python3
"""Real app/HTTP/native-UI lifecycle and resource E2E on a disposable simulator.

No app methods, network framework, account identity or lifecycle events are mocked.
Remote podcast feeds/media remain live. A separate local peer supplies repeatable
slow/failing media and 1,000 subscriptions. Optimized app CPU seconds, physical
footprint, RSS, actual lifecycle, HTTP, screenshots and user log exports are retained.
Simulator measurements do not establish hardware energy or jetsam behavior.
"""
import argparse
import atexit
import ctypes
from datetime import datetime, timezone, timedelta
import email.utils
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import threading
import time
import uuid
import wave
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = 'com.iteconomy.instacastplus'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--udid', required=True)
p.add_argument('--app', required=True, type=Path)
p.add_argument('--feeds', required=True, type=Path)
p.add_argument('--evidence', required=True, type=Path)
p.add_argument('--bulk', type=int, default=0)
p.add_argument('--bulk-only', action='store_true', help='Focused failing/verification flow for large OPML import and refresh responsiveness')
p.add_argument('--profile-stacks', action='store_true', help='Capture intrusive stack samples in a separate diagnostic run')
p.add_argument('--scroll-during-bulk', action='store_true', help='Exercise native tracking gestures during the focused bulk run')
p.add_argument('--resume-bulk', type=Path, help='Continue a completed import after an infrastructure timeout, retaining that run and its store')
p.add_argument('--allow-upgraded-test-build', action='store_true', help='Verify a corrected build against the retained disposable-store fixture; retain both binary fingerprints')
p.add_argument('--rank-boundary-only', action='store_true', help='Focused saved-rank maintenance/performance E2E in a retained thousand-feed library')
p.add_argument('--duration-scale', type=float, default=1)
args = p.parse_args()
out = args.evidence.resolve(); out.mkdir(parents=True, exist_ok=True)
checks = []; host_samples = []; markers = []; peer_state = {'revision': 0, 'media_mode': {}}
seed_observations=[];peer_port=0
if args.resume_bulk:
    seed_environment=json.loads((args.resume_bulk/'environment.json').read_text())
    assert seed_environment['device']['udid']==args.udid
    assert args.allow_upgraded_test_build or seed_environment['binarySHA256']=={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in args.app.glob('InstacastPlus*') if f.is_file()}
    seed_checks=json.loads((args.resume_bulk/'checks.json').read_text())
    assert any(c['passed'] and c['name']=='1,000 subscriptions import while player remains live' for c in seed_checks)
    seed_observations=[json.loads(line) for line in (args.resume_bulk/'observations.jsonl').read_text().splitlines()]
    seed_aac=next(o['reply']['episodes'][0] for o in seed_observations
        if o['request'].get('action')=='episodes' and any('/aac.xml' in url for url in o['request'].get('urls',[])))
    seed_url=next(o['request']['url'] for o in seed_observations if o['request'].get('action')=='subscribe' and o['request'].get('url','').endswith('/aac.xml'))
    peer_port=int(seed_url.split(':')[2].split('/')[0]);peer_state['revision']=3
did_complete = False
stop_sampler = threading.Event()
native = None
pid = None


def run(command, check=True, env=None):
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    with (out / 'commands.log').open('a') as log:
        log.write(shlex.join(command) + '\n' + result.stdout)
    if check and result.returncode: raise RuntimeError(result.stdout[-5000:])
    return result.stdout.strip()


def sim(*command, check=True, env=None):
    return run(['xcrun', 'simctl', *command], check=check, env=env)


def record(name, passed, **observed):
    result = dict(name=name, passed=bool(passed), observed=observed)
    checks.append(result); (out / 'checks.json').write_text(json.dumps(checks, ensure_ascii=False, indent=2))
    print(('PASS ' if passed else 'FAIL ') + name, flush=True)


device = next(d for group in json.loads(sim('list', 'devices', '-j'))['devices'].values() for d in group if d['udid'] == args.udid)
assert device['name'].startswith('Instacast Stress ') and device['state'] == 'Booted'
source = ROOT / 'Tools/fixtures/lifecycle_stress_probe.m'
shutil.copy2(Path(__file__).resolve(), out / 'driver.py')
shutil.copy2(source, out / 'probe.m')
library = out / 'LifecycleStressProbe.dylib'
sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
     '-I', str(ROOT / 'Classes'), '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'AVFoundation',
     '-framework', 'CloudKit', '-framework', 'QuartzCore', str(source), '-o', str(library)])
run(['codesign', '-s', '-', str(library)])
sim('terminate', args.udid, BUNDLE, check=False)
if not args.resume_bulk:sim('uninstall', args.udid, BUNDLE, check=False)
sim('install', args.udid, str(args.app.resolve()))
container = Path(sim('get_app_container', args.udid, BUNDLE, 'data'))
directory = container / 'Documents/LifecycleStress'; directory.mkdir(parents=True, exist_ok=True)
for name in ['command.json', 'reply.json', 'native-command.json', 'native-reply.json', 'telemetry.jsonl', 'events.jsonl', 'export.txt']:
    (directory / name).unlink(missing_ok=True)
env = dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library))


def emergency_cleanup():
    stop_sampler.set()
    if native is not None and native.poll() is None:
        sim('terminate', args.udid, 'com.iteconomy.instacastplus.ChapterScrollTests.xctrunner', check=False)
        native.terminate()
    if pid is not None: sim('terminate', args.udid, BUNDLE, check=False)


atexit.register(emergency_cleanup)
audio=io.BytesIO()
with wave.open(audio,'wb') as wav:
    wav.setparams((1,2,8000,0,'NONE','not compressed'));wav.writeframes(b'\0\0'*8000*900)
wav_bytes=audio.getvalue()
(out/'fixture.wav').write_bytes(wav_bytes)
run(['/usr/bin/afconvert','-f','m4af','-d','aac@44100','-b','64000',str(out/'fixture.wav'),str(out/'fixture.m4a')])
media={'wav':wav_bytes,'aac':(out/'fixture.m4a').read_bytes()}
short_audio=io.BytesIO()
with wave.open(short_audio,'wb') as wav:
    wav.setparams((1,2,8000,0,'NONE','not compressed'));wav.writeframes(b'\0\0'*8000*2)


def launch():
    result = sim('launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid,
                 BUNDLE, '-AppleLanguages', '(en)', '-PlaybackVolume', '0', '-UISoundEnabled', 'NO', '-AutoCacheNewAudioEpisodes', 'NO',
                 '-AutoCacheNewVideoEpisodes', 'NO', env=env)
    return int(result.rsplit(':', 1)[1].strip())


# Start the UI runner before launching the app: an already-present notification
# permission alert can prevent SpringBoard from launching the runner itself.
class ProcessUsage(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_ubyte*16)]+[(key,ctypes.c_uint64) for key in
        ['user','system','idleWakeups','interruptWakeups','pageins','wired','resident','footprint','start','exit']]
class MachTimebase(ctypes.Structure):
    _fields_=[('numer',ctypes.c_uint32),('denom',ctypes.c_uint32)]
mach_timebase=MachTimebase()
ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(mach_timebase))
libproc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
(out / 'environment.json').write_text(json.dumps(dict(command=shlex.join([os.sys.executable, *os.sys.argv]),
    started=datetime.now(timezone.utc).isoformat(), device=device, app=str(args.app.resolve()), sdk=sdk,
    sourceSHA256={str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in
                  [source, Path(__file__).resolve(), ROOT / 'Classes/PlaybackManager.m', ROOT / 'Classes/AudioSession.m', ROOT / 'Classes/TranscriptionQueue.swift', ROOT / 'Classes/Model/SubscriptionManager.m', ROOT / 'Classes/PlayerController.m',
                   ROOT / 'Classes/Model/DatabaseManager.m', ROOT / 'Classes/InstacastBackupData.h', ROOT / 'Classes/InstacastBackupParser.m', ROOT / 'Classes/InstacastBackupImporter.m', ROOT / 'Classes/ICiCloudSyncManager+Metadata.swift']},
    binarySHA256={f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in args.app.glob('InstacastPlus*') if f.is_file()},
    expected='Valid transitions, responsive UI, silent audio, durable downloads/recovery, background timer expiry, bounded steady-state resources',
    continuationOf=str(args.resume_bulk.resolve()) if args.resume_bulk else None,
    seedBinarySHA256=seed_environment['binarySHA256'] if args.resume_bulk else None,
    instrumentation='200 ms common-run-loop-modes main heartbeat/command reader, 1 s rusage/task_vm_info telemetry and independent host ps RSS/CPU. Background suspension stops in-process telemetry.',
    externalCPUClock=dict(numer=mach_timebase.numer,denom=mach_timebase.denom,source='proc_pid_rusage RUSAGE_INFO_V0, Mach absolute ticks'),
    limits='Simulator resource/lifecycle measurements; CloudKit account availability reported, never forged; live feeds may vary.'), indent=2))


def command(action='status', timeout=40, **parameters):
    request = dict(id=str(uuid.uuid4()), action=action, **parameters)
    temporary = directory / 'command.tmp'; temporary.write_text(json.dumps(request)); temporary.replace(directory / 'command.json')
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            reply = json.loads((directory / 'reply.json').read_text())
            if reply['id'] == request['id']:
                with (out / 'observations.jsonl').open('a') as log: log.write(json.dumps(dict(request=request, reply=reply)) + '\n')
                assert not reply.get('error'), reply
                return reply
        except (FileNotFoundError, json.JSONDecodeError): pass
        time.sleep(.1)
    raise AssertionError(f'App did not answer {request}; pid={pid}')


def wait(predicate, seconds=60, **parameters):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = command(**parameters)
        if predicate(state): return state
        time.sleep(.4)
    raise AssertionError(f'Condition not reached: {state}')


def phase(name):
    markers.append(dict(name=name, timestamp=time.time()))
    (out / 'phases.json').write_text(json.dumps(markers, indent=2))
    command('phase', name=name)
    print('PHASE ' + name, flush=True)


def hold(seconds):
    # A measured workload interval, not a delay or retry added to production.
    deadline = time.monotonic() + seconds * args.duration_scale
    while time.monotonic() < deadline: time.sleep(min(1, max(.01, deadline-time.monotonic())))


def sample_host():
    while not stop_sampler.wait(1):
        r = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,state=,%cpu=,rss=,time='], text=True, capture_output=True)
        if r.returncode == 0:
            sample = dict(timestamp=time.time(), pid=pid, ps=r.stdout.strip())
            usage=ProcessUsage()
            if libproc.proc_pid_rusage(pid,0,ctypes.byref(usage))==0:
                sample.update(cpuSeconds=(usage.user+usage.system)*mach_timebase.numer/mach_timebase.denom/1e9,
                              footprintBytes=usage.footprint,residentBytes=usage.resident)
            host_samples.append(sample)
            with (out / 'host-resources.jsonl').open('a') as log: log.write(json.dumps(sample)+'\n')


threading.Thread(target=sample_host, daemon=True).start()
# A native UI runner supplies real Home/foreground, rotation, gestures and taps.
project = out / 'Native.xcodeproj'; project.mkdir(exist_ok=True)
shutil.copy2(ROOT / 'Tools/fixtures/chapter_scroll_ui_project.pbxproj', project / 'project.pbxproj')
(out / 'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests:XCTestCase {
 func testLifecycle() throws {
  executionTimeAllowance=3600
  let directory=URL(fileURLWithPath:DIRECTORY)
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  let spring=XCUIApplication(bundleIdentifier:"com.apple.springboard")
  XCUIDevice.shared.orientation = .portrait
  app.launchArguments=["-AppleLanguages","(en)","-PlaybackVolume","0","-UISoundEnabled","NO","-AutoCacheNewAudioEpisodes","NO","-AutoCacheNewVideoEpisodes","NO"]
  app.launchEnvironment=["DYLD_INSERT_LIBRARIES":LIBRARY]
  app.launch()
  let deadline=Date().addingTimeInterval(3600)
  while Date()<deadline {
   let path=directory.appendingPathComponent("native-command.json")
   guard let data=try? Data(contentsOf:path),let request=(try? JSONSerialization.jsonObject(with:data)) as? [String:String],let id=request["id"] else {Thread.sleep(forTimeInterval:0.1);continue}
   try? FileManager.default.removeItem(at:path)
   let started=Date()
   let action=request["action"] ?? "status"
   var extra=[String:Any]()
   if action=="dismiss" {
    app.activate()
    for title in ["Don’t Allow","Don't Allow","Nicht erlauben"] {
     let button=spring.alerts.buttons[title];if button.waitForExistence(timeout:1) {button.tap();break}
    }
    for title in ["Got it!","Verstanden!","Verstanden"] {let button=app.buttons[title];if button.waitForExistence(timeout:1) {button.tap();break}}
    let coach=app.staticTexts.matching(NSPredicate(format:"label CONTAINS[c] %@","to add podcasts")).firstMatch
    if coach.waitForExistence(timeout:2) {
     app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.4)).tap()
     XCTAssertTrue(coach.waitForNonExistence(timeout:5),app.debugDescription)
    }
    extra["systemAlerts"]=spring.alerts.count
    if spring.alerts.count>0 {extra["alertHierarchy"]=spring.debugDescription}
   } else if action=="home" {
    if BACKGROUND_WITH_SETTINGS {XCUIApplication(bundleIdentifier:"com.apple.Preferences").activate()}
    else {XCUIDevice.shared.press(.home)}
   }
   else if action=="activate" {app.activate()}
   else if action=="portrait" {XCUIDevice.shared.orientation = .portrait}
   else if action=="landscape" {XCUIDevice.shared.orientation = .landscapeLeft}
   else if action=="scroll" {
    let start=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.65))
    let end=app.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.3))
    start.press(forDuration:0.05,thenDragTo:end)
   } else if action=="tap" {
    let button=app.buttons[request["label"] ?? "Pause"]
    extra["hittable"]=button.isHittable
    if button.isHittable {button.tap()}
   } else if action=="capture" {
    let image=XCTAttachment(screenshot:app.screenshot());image.lifetime = .keepAlways;add(image)
    extra["hierarchy"]=app.debugDescription
   }
   var reply:[String:Any] = ["id":id,"state":app.state.rawValue,"seconds":Date().timeIntervalSince(started)]
   reply.merge(extra){_,new in new}
   try JSONSerialization.data(withJSONObject:reply).write(to:directory.appendingPathComponent("native-reply.json"),options:.atomic)
   if action=="finish" {return}
  }
  XCTFail("Driver did not finish")
 }
}
'''.replace('DIRECTORY', json.dumps(str(directory))).replace('LIBRARY',json.dumps(str(library))).replace('BACKGROUND_WITH_SETTINGS','true' if device['name'].endswith('Duo') else 'false'))
native_build = ['xcodebuild', '-project', str(project), '-scheme', 'NativeScrollTests', '-destination', 'platform=iOS Simulator,id='+args.udid,
                '-derivedDataPath', str(out/'NativeDerived'), '-parallel-testing-enabled', 'NO']
run([*native_build, 'build-for-testing'])
sim('install', args.udid, str(out/'NativeDerived/Build/Products/Debug-iphonesimulator/NativeScrollTests-Runner.app'))
native_log=(out/'native-ui.log').open('w')
native = subprocess.Popen([*native_build, '-resultBundlePath', str(out/'Native.xcresult'), '-test-timeouts-enabled','YES',
                           '-default-test-execution-time-allowance','3600','-maximum-test-execution-time-allowance','3600','test-without-building'],stdout=native_log,stderr=subprocess.STDOUT)
native_registration_retried=False
native_has_answered=False


def ui(action, **parameters):
    global native,native_log,native_registration_retried,native_has_answered
    request=dict(id=str(uuid.uuid4()),action=action,**parameters)
    temporary=directory/'native-command.tmp';temporary.write_text(json.dumps(request));temporary.replace(directory/'native-command.json')
    deadline=time.monotonic()+(240 if args.bulk_only else 80)
    while time.monotonic()<deadline:
        try:
            reply=json.loads((directory/'native-reply.json').read_text())
            if reply['id']==request['id']:
                native_has_answered=True
                with (out/'native-observations.jsonl').open('a') as log:log.write(json.dumps(dict(request=request,reply=reply))+'\n')
                if action=='home':wait(lambda s:s['state']['applicationState']==2,seconds=15)
                return reply
        except (FileNotFoundError,json.JSONDecodeError):pass
        if native.poll() is not None:
            native_log.flush()
            registration_error='Unknown application display identifier' in (out/'native-ui.log').read_text()
            if not native_has_answered and not native_registration_retried and registration_error:
                # A fresh simulator can report install success before SpringBoard
                # registers the UI runner. Verify the installed bundle, retain the
                # failed startup, then retry only this infrastructure startup once.
                sim('appinfo',args.udid,'com.iteconomy.instacastplus.ChapterScrollTests.xctrunner')
                native_log.close();native_log=(out/'native-ui-registration-retry.log').open('w')
                native=subprocess.Popen([*native_build,'-resultBundlePath',str(out/'NativeRegistrationRetry.xcresult'),
                    '-test-timeouts-enabled','YES','-maximum-test-execution-time-allowance','3600','test-without-building'],stdout=native_log,stderr=subprocess.STDOUT)
                native_registration_retried=True;deadline=time.monotonic()+80
            else:raise AssertionError('Native UI runner exited; see native-ui.log')
        time.sleep(.15)
    raise AssertionError('Native UI did not answer '+action)


def capture(name):
    sim('io',args.udid,'screenshot','--display=1',str(out/(name+'.png')))
    if device['name'].endswith('Duo'):
        sim('io',args.udid,'screenshot','--display=3',str(out/(name+'-second-display.png')))
    (out/(name+'.json')).write_text(json.dumps(command(details=True),indent=2))


class Peer(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*_):pass
    def handle(self):
        try:super().handle()
        except (ConnectionResetError,BrokenPipeError):pass  # Expected cancellation/fault traffic.
    def do_GET(self):
        path=self.path.split('?')[0]
        if path.endswith('.xml'):
            name=path.strip('/').removesuffix('.xml');bulk=name.startswith('bulk-')
            count=(5 if bulk else 30)+peer_state['revision']
            if name=='large':count=1200+peer_state['revision']
            items=[]
            for i in reversed(range(count)):
                kind='aac' if name=='aac' else 'wav'
                date=datetime(2026,1,1,tzinfo=timezone.utc)+timedelta(hours=i)
                items.append(f'<item><title>{escape(name)} episode {i}</title><guid isPermaLink="false">{name}-{i}</guid>'
                    f'<pubDate>{email.utils.format_datetime(date)}</pubDate><itunes:duration>900</itunes:duration>'
                    f'<description>Controlled lifecycle fixture</description><enclosure url="{base}/media/{name}-{i}.{kind}" length="{len(media[kind])}" type="'+('audio/mp4' if kind=='aac' else 'audio/wav')+'"/></item>')
            payload=('<?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
                f'<title>Lifecycle {escape(name)}</title><link>{base}/</link><description>Repeatable simulator test</description>'+''.join(items)+'</channel></rss>').encode()
            if peer_state['media_mode'].get(name)=='feed-error':self.reply(503,b'Unavailable','text/plain');return
            self.reply(200,payload,'application/rss+xml');return
        if path.startswith('/media/'):
            kind=path.rsplit('.',1)[1];data=media.get(kind,wav_bytes)
            name=path.split('/')[-1].rsplit('-',1)[0];mode=peer_state['media_mode'].get(name,'normal')
            if mode=='unavailable':self.reply(503,b'Unavailable','text/plain');return
            if mode=='invalid':self.reply(200,b'<html>not audio</html>','audio/wav');return
            if mode=='short':self.reply(200,short_audio.getvalue(),'audio/wav');return
            start,end=0,len(data)-1
            if self.headers.get('Range'):
                lo,hi=self.headers['Range'].removeprefix('bytes=').split('-',1)
                start=int(lo);end=min(int(hi) if hi else end,end)
            payload=data[start:end+1];self.send_response(206 if self.headers.get('Range') else 200)
            self.send_header('Content-Type','audio/mp4' if kind=='aac' else 'audio/wav');self.send_header('Content-Length',str(len(payload)))
            self.send_header('Accept-Ranges','bytes')
            if self.headers.get('Range'):self.send_header('Content-Range',f'bytes {start}-{end}/{len(data)}')
            self.end_headers()
            with (out/'http.jsonl').open('a') as log:log.write(json.dumps(dict(timestamp=time.time(),path=path,mode=mode,range=self.headers.get('Range'),bytes=len(payload)))+'\n')
            try:
                if mode=='truncated':self.wfile.write(payload[:2048]);self.wfile.flush();self.close_connection=True;return
                for offset in range(0,len(payload),65536):
                    self.wfile.write(payload[offset:offset+65536]);self.wfile.flush()
                    if mode=='slow':time.sleep(.06)
            except (BrokenPipeError,ConnectionResetError):pass
            return
        self.reply(404,b'Not found','text/plain')
    def reply(self,status,payload,kind):
        self.send_response(status);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(payload)));self.end_headers()
        try:self.wfile.write(payload)
        except (BrokenPipeError,ConnectionResetError):pass
        with (out/'http.jsonl').open('a') as log:log.write(json.dumps(dict(timestamp=time.time(),path=self.path,status=status,bytes=len(payload)))+'\n')


peer=ThreadingHTTPServer(('127.0.0.1',peer_port),Peer);base=f'http://127.0.0.1:{peer.server_port}'
threading.Thread(target=peer.serve_forever,daemon=True).start()


def subscribe(url,label):
    command('subscribe',url=url,operation=label)
    state=wait(lambda s:s['operations'].get(label,{}).get('done'),seconds=150)
    result=state['operations'][label];record(label+': subscribe through production parser',not result.get('error'),result=result)
    if result.get('error'):return []
    return command('episodes',urls=[result.get('url') or url],limit=6)['episodes']


try:
    prepared=ui('dismiss');assert prepared.get('systemAlerts')==0,prepared
    pid=command(timeout=90)['state']['pid']
    if args.rank_boundary_only:
        assert args.resume_bulk
        record('Rank-boundary fixture contains a thousand durable subscriptions',command(details=True)['feedCount']>=1000)
        command('open',hash=seed_aac['hash'],autostart=True);wait(lambda s:s['state']['ready'] and s['state']['rate']>0);command('pause')
        phase('rank-boundary-warmup');hold(5)
        phase('saved-rank-maintenance')
        url=next(o['request']['url'] for o in seed_observations if o['request'].get('action')=='subscribe' and o['request'].get('url','').endswith('/wav.xml'))
        xml=f'<instacast version="1"><podcasts><podcast url="{url}" rank="-2147483648"/></podcasts></instacast>'
        (directory/'backup-ranks.xml').write_text(xml);(out/'boundary-rank-backup.xml').write_text(xml)
        command('backupRanks',operation='boundary-rank');boundary=wait(lambda s:s['operations'].get('boundary-rank',{}).get('done'),seconds=150)
        before=command('feedOrder')['feedOrder']
        record('Real backup restores the lower signed-rank bound in the large library',not boundary['operations']['boundary-rank'].get('error') and before[0]['url']==url and before[0]['rank']==-2147483648,feedOrder=before)
        name='rank-boundary-'+hashlib.sha256(out.name.encode()).hexdigest()[:8]
        subscribe(base+'/'+name+'.xml','subscribe-rank-boundary')
        after=command('feedOrder')['feedOrder'];state=command()['state']
        record('Rank-space maintenance preserves every existing visible position',
            [f['url'] for f in after]==[base+'/'+name+'.xml']+[f['url'] for f in before] and all(-2147483648<=f['rank']<=2147483647 for f in after),feedOrder=after)
        record('Large rank-space maintenance yields the main run loop within 500 ms',state['heartbeatMaximumGapSeconds']<.5,maximumGapSeconds=state['heartbeatMaximumGapSeconds'])
        phase('saturated-rank-prefix')
        prefix_urls=[f['url'] for f in after[:3]]
        xml='<instacast version="1"><podcasts>'+''.join(f'<podcast url="{url}" rank="{-2147483648+i}"/>' for i,url in enumerate(prefix_urls))+'</podcasts></instacast>'
        (directory/'backup-ranks.xml').write_text(xml);(out/'prefix-rank-backup.xml').write_text(xml)
        command('backupRanks',operation='prefix-rank');prefix=wait(lambda s:s['operations'].get('prefix-rank',{}).get('done'),seconds=150)
        before_prefix=command('feedOrder')['feedOrder']
        record('Real backup establishes three consecutive saturated ranks',not prefix['operations']['prefix-rank'].get('error') and [f['rank'] for f in before_prefix[:3]]==[-2147483648,-2147483647,-2147483646],feedOrder=before_prefix)
        subscribe(base+'/'+name+'-prefix.xml','subscribe-rank-prefix')
        after_prefix=command('feedOrder')['feedOrder'];state=command()['state']
        record('Opening space for a saturated prefix preserves every existing position',
            [f['url'] for f in after_prefix]==[base+'/'+name+'-prefix.xml']+[f['url'] for f in before_prefix],feedOrder=after_prefix)
        record('Saturated-prefix maintenance yields the main run loop within 500 ms',state['heartbeatMaximumGapSeconds']<.5,maximumGapSeconds=state['heartbeatMaximumGapSeconds'])
        capture('rank-maintenance-after');command('exportLogs');shutil.copy2(directory/'export.txt',out/'InstacastPlus-CrashLogs.txt');did_complete=True
        raise SystemExit(0 if all(c['passed'] for c in checks) else 1)
    if args.resume_bulk:
        aac=seed_aac
        before=command(details=True)
        record('Completed thousand-feed import is durable after driver restart',before['feedCount']>=1000,state=before)
        record('Original completed download remains durable',command(hash=aac['hash'])['download']['cached'])
        command('open',hash=aac['hash'],autostart=True);wait(lambda s:s['state']['rate']>0)
        command('seek',time=0);wait(lambda s:s['state']['time']<1)
        before_order=command('feedOrder')['feedOrder']
        tracking_sampler=None
        if args.profile_stacks:
            tracking_sample_log=(out/'tracking-sample-command.log').open('w')
            tracking_sampler=subprocess.Popen(['sample',str(pid),'10','10','-file',str(out/'tracking-main-thread.sample')],stdout=tracking_sample_log,stderr=subprocess.STDOUT)
        phase('tracking-baseline');ui('scroll');ui('scroll')
        baseline=command()['state']
        record('Native baseline gestures complete in the same playing view',baseline['rate']>0,maximumGapSeconds=baseline['heartbeatMaximumGapSeconds'])
        phase('resumed-import-with-tracking')
        namespace=hashlib.sha256(out.name.encode()).hexdigest()[:8]
        outlines=''.join(f'<outline type="rss" xmlUrl="{base}/bulk-tracking-{namespace}-{i}.xml"/>' for i in range(20))
        (directory/'subscriptions.opml').write_text('<opml version="2.0"><head/><body>'+outlines+'</body></opml>')
        command('import',operation='tracking-import');ui('scroll');ui('scroll')
        imported=wait(lambda s:s['operations'].get('tracking-import',{}).get('done'),seconds=150)
        counts=command(details=True)
        if tracking_sampler is not None:tracking_sampler.wait(timeout=20);tracking_sample_log.close()
        record('New subscriptions commit in the thousand-feed library during native gestures',
            not imported['operations']['tracking-import'].get('error') and counts['feedCount']==before['feedCount']+20 and counts['state']['rate']>0,state=counts)
        record('Common-mode import heartbeat remains below 500 ms during tracking',counts['state']['heartbeatMaximumGapSeconds']<.5,maximumGapSeconds=counts['state']['heartbeatMaximumGapSeconds'])
        tracking_urls=[f'{base}/bulk-tracking-{namespace}-{i}.xml' for i in range(20)]
        phase('rank-and-outbox-contract')
        ordered=command('feedOrder')['feedOrder']
        record('New subscriptions prepend in reverse import order and preserve the existing visible order',
            [f['url'] for f in ordered]==tracking_urls[::-1]+[f['url'] for f in before_order],feedOrder=ordered)
        outbox_names=[prefix+hashlib.sha256(url.encode()).hexdigest() for url in tracking_urls
            for prefix in ['subscription_','subscriptionTombstone_']]
        outbox=command('outbox',recordNames=outbox_names,urls=tracking_urls)['outboxEntries']
        outbox_valid=len(outbox)==40
        for url in tracking_urls:
            pair=[row for row in outbox if row['feedURL']==url]
            outbox_valid=outbox_valid and len(pair)==2 and {row['operation'] for row in pair}=={'save','delete'}
            outbox_valid=outbox_valid and len({row['revision'] for row in pair})==1 and len({row['changedAt'] for row in pair})==1
            outbox_valid=outbox_valid and all(row['category']=='subscription' and not row['acknowledged'] and row['accountRecordName'] and row['propertiesArrayPresent'] and row['payloadRank']==row['savedRank'] for row in pair)
        record('Fresh store reader finds complete durable paired cloud intents for every new subscription',outbox_valid,entries=outbox)
        rank_before={f['url']:f['rank'] for f in ordered}
        xml='<instacast version="1"><podcasts>'+f'<podcast url="{tracking_urls[0]}" rank="-2000"/>'+f'<podcast url="{tracking_urls[1]}" rank="0"/>'+f'<podcast url="{tracking_urls[2]}"/>'+'</podcasts></instacast>'
        (directory/'backup-ranks.xml').write_text(xml);(out/'backup-ranks.xml').write_text(xml)
        command('backupRanks',operation='rank-restore');backup=wait(lambda s:s['operations'].get('rank-restore',{}).get('done'),seconds=150)
        restored_order=command('feedOrder')['feedOrder'];rank_after={f['url']:f['rank'] for f in restored_order}
        record('Backup restores negative and zero ranks while an absent rank preserves the existing order',
            not backup['operations']['rank-restore'].get('error') and rank_after[tracking_urls[0]]==-2000 and rank_after[tracking_urls[1]]==0 and rank_after[tracking_urls[2]]==rank_before[tracking_urls[2]],operation=backup['operations']['rank-restore'],feedOrder=restored_order)
        missing_url=f'{base}/backup-absent-rank-{namespace}.xml'
        xml=f'<instacast version="1"><podcasts><podcast url="{missing_url}"/></podcasts></instacast>'
        (directory/'backup-ranks.xml').write_text(xml);(out/'backup-absent-new-rank.xml').write_text(xml)
        command('backupRanks',operation='new-missing-rank',newPodcasts=True)
        missing=wait(lambda s:s['operations'].get('new-missing-rank',{}).get('done'),seconds=150)
        missing_order=command('feedOrder')['feedOrder']
        record('A new podcast from a legacy backup keeps its normal insertion order when rank is absent',
            not missing['operations']['new-missing-rank'].get('error') and [f['url'] for f in missing_order]==[missing_url]+[f['url'] for f in restored_order],operation=missing['operations']['new-missing-rank'],feedOrder=missing_order)
        if args.bulk_only:
            capture('tracking-after');command('pause');command('exportLogs');did_complete=True
            raise SystemExit(0 if all(c['passed'] for c in checks) else 1)
        phase('resumed-thousand-feed-refresh');command('refresh',all=True,operation='resumed-refresh')
        command('openList');ui('scroll');ui('home');hold(30);ui('activate')
        refreshed=wait(lambda s:s['operations'].get('resumed-refresh',{}).get('done'),seconds=900)
        record('Thousand-feed refresh completes across scrolling and background',refreshed['operations']['resumed-refresh'].get('success') and refreshed['state']['rate']>0,state=refreshed)
        record('Common-mode refresh heartbeat remains below 500 ms',refreshed['state']['heartbeatMaximumGapSeconds']<.5,maximumGapSeconds=refreshed['state']['heartbeatMaximumGapSeconds'])
        capture('resumed-bulk-after');phase('resumed-process-recovery');command('pause');saved=command(details=True)
        sim('terminate',args.udid,BUNDLE);pid=launch();ui('activate');restored=command(timeout=90,details=True)
        record('Process restart preserves the thousand-feed library without autoplay',restored['feedCount']==saved['feedCount'] and restored['state']['paused'] and restored['state']['rate']==0,saved=saved,restored=restored)
        record('Completed audio survives process restart',command(hash=aac['hash'])['download']['cached'])
        phase('final-background-playback');command('open',hash=aac['hash'],autostart=True);wait(lambda s:s['state']['rate']>0);ui('home');hold(60);ui('activate');command('pause')
        phase('post-stress-idle');hold(30);capture('final');command('exportLogs')
        shutil.copy2(directory/'export.txt',out/'InstacastPlus-CrashLogs.txt')
        did_complete=True
        raise SystemExit(0 if all(c['passed'] for c in checks) else 1)
    if args.bulk_only:
        items=subscribe(base+'/aac.xml','subscribe-aac')
        aac=items[0]
        command('download',hash=aac['hash']);wait(lambda s:s['download']['cached'],hash=aac['hash'])
        command('open',hash=aac['hash'],autostart=True);wait(lambda s:s['state']['rate']>0)
        tapped=ui('tap',label='Pause');record('Native Pause is reachable after onboarding',tapped.get('hittable') and command()['state']['paused'])
        tapped=ui('tap',label='Play');record('Native Play resumes after onboarding',tapped.get('hittable') and command()['state']['rate']>0)
        phase('bulk-import-'+str(args.bulk))
        outlines=''.join(f'<outline type="rss" text="Stress {i}" xmlUrl="{base}/bulk-{i}.xml"/>' for i in range(args.bulk))
        (directory/'subscriptions.opml').write_text('<?xml version="1.0"?><opml version="2.0"><head><title>Lifecycle load</title></head><body>'+outlines+'</body></opml>')
        command('import',operation='bulk-import',timeout=240)
        if args.scroll_during_bulk:ui('scroll')
        sampler=None
        if args.profile_stacks:
            sample_log=(out/'sample-command.log').open('w')
            sampler=subprocess.Popen(['sample',str(pid),'5','10','-file',str(out/'main-thread.sample')],stdout=sample_log,stderr=subprocess.STDOUT)
        imported=wait(lambda s:s['operations'].get('bulk-import',{}).get('done'),seconds=900,timeout=240)
        if sampler is not None:sampler.wait(timeout=20);sample_log.close()
        counts=command(details=True,timeout=240)
        record('All OPML subscriptions commit while playback continues',not imported['operations']['bulk-import'].get('error') and counts['feedCount']>=args.bulk and counts['state']['rate']>0,state=counts)
        gap=counts['state']['heartbeatMaximumGapSeconds']
        record('Bulk OPML import yields the foreground main run loop within 500 ms',gap<.5,maximumGapSeconds=gap)
        capture('bulk-import-after')
        phase('bulk-refresh-'+str(args.bulk));peer_state['revision']+=1
        refresh_sampler=None
        if args.profile_stacks:
            refresh_sample_log=(out/'refresh-sample-command.log').open('w')
            refresh_sampler=subprocess.Popen(['sample',str(pid),'5','10','-file',str(out/'refresh-main-thread.sample')],stdout=refresh_sample_log,stderr=subprocess.STDOUT)
        command('refresh',all=True,operation='bulk-refresh',timeout=240)
        refreshed=wait(lambda s:s['operations'].get('bulk-refresh',{}).get('done'),seconds=900,timeout=240)
        if refresh_sampler is not None:refresh_sampler.wait(timeout=20);refresh_sample_log.close()
        record('Every feed refresh completes without losing playback',refreshed['operations']['bulk-refresh'].get('success') and refreshed['state']['rate']>0,state=refreshed)
        gap=refreshed['state']['heartbeatMaximumGapSeconds']
        record('Bulk refresh yields the foreground main run loop within 500 ms',gap<.5,maximumGapSeconds=gap)
        capture('bulk-refresh-after');command('pause');command('exportLogs')
        did_complete=True
        raise SystemExit(0 if all(c['passed'] for c in checks) else 1)
    phase('foreground-idle');hold(30);capture('baseline')
    phase('background-idle');ui('home');hold(45);ui('activate')
    real=[]
    phase('live-feed-subscription')
    for feed in json.loads(args.feeds.read_text()):
        if feed.get('episodes'):
            episodes=subscribe(feed['url'],'subscribe-'+feed['name'])
            if episodes:real.append(episodes[0])
    (out/'real-podcast-inputs.json').write_text(json.dumps(real,ensure_ascii=False,indent=2))
    for index,item in enumerate(real):
        phase('real-stream-'+str(index));command('open',hash=item['hash'],autostart=True)
        s=wait(lambda s:s['state']['ready'] and s['state']['rate']>0,seconds=90)
        record(item['feedTitle']+': real muted streaming starts',not s['state']['failed'] and s['state']['volume']==0,state=s['state'])
        hold(12);phase('real-background-'+str(index));before=command()['state'];ui('home');hold(25)
        after=command()['state'];record(item['feedTitle']+': continues in actual background',after['applicationState']==2 and after['time']>before['time']+10,state=after)
        ui('activate');command('seek',time=60);hold(3)
        command('pause');record(item['feedTitle']+': pause works after background/seek',command()['state']['paused'])
    phase('controlled-feed-subscription');controlled={}
    for name in ['wav','aac','broken','slow','large']:
        items=subscribe(base+'/'+name+'.xml','subscribe-'+name)
        if items:controlled[name]=items
    record('Both controlled codecs and fault fixtures are available',all(x in controlled for x in ['wav','aac','broken','slow']))
    phase('opml-error-recovery')
    feed_count=command(details=True)['feedCount']
    peer_state['media_mode']['opml-rejected']='feed-error'
    urls=[base+'/bulk-edge-first.xml',base+'/opml-rejected.xml',base+'/bulk-edge-last.xml']
    outlines=''.join(f'<outline type="rss" xmlUrl="{url}"/>' for url in urls)
    (directory/'subscriptions.opml').write_text('<opml version="2.0"><head/><body>'+outlines+'</body></opml>')
    command('import',operation='partial-import')
    partial=wait(lambda s:s['operations'].get('partial-import',{}).get('done'),seconds=90)
    count=command(details=True)['feedCount']
    items=command('episodes',urls=[urls[0],urls[2]],limit=1)['episodes']
    record('OPML continues after a feed failure and reports the partial error',
        bool(partial['operations']['partial-import'].get('error')) and count==feed_count+2 and len(items)==2,
        operation=partial['operations']['partial-import'],feedCountBefore=feed_count,feedCountAfter=count,episodes=items)
    for name,payload in [('empty','<opml version="2.0"><head/><body/></opml>'),('malformed','<opml><body><outline')]:
        (directory/'subscriptions.opml').write_text(payload);command('import',operation=name+'-import')
        rejected=wait(lambda s:s['operations'].get(name+'-import',{}).get('done'))
        record(name+' OPML reports an error and terminates',bool(rejected['operations'][name+'-import'].get('error')),
            operation=rejected['operations'][name+'-import'])
    (directory/'subscriptions.opml').write_text('<opml version="2.0"><head/><body><outline type="rss" xmlUrl="'+urls[0]+'"/></body></opml>')
    command('import',operation='duplicate-import')
    duplicate=wait(lambda s:s['operations'].get('duplicate-import',{}).get('done'))
    record('Import recovers after malformed input and does not duplicate existing subscriptions',
        not duplicate['operations']['duplicate-import'].get('error') and command(details=True)['feedCount']==count,
        operation=duplicate['operations']['duplicate-import'])
    wav=controlled['wav'][0];aac=controlled['aac'][0];slow=controlled['slow'][0];broken=controlled['broken'][0]
    phase('background-download-and-playback');peer_state['media_mode']['slow']='slow'
    command('open',hash=wav['hash'],autostart=True);wait(lambda s:s['state']['rate']>0)
    accepted=command('download',hash=slow['hash'])['accepted'];ui('home')
    downloaded=wait(lambda s:s['download']['cached'],seconds=90,hash=slow['hash'])
    state=downloaded['state'];record('Slow download completes during actual background playback',accepted and state['applicationState']==2 and state['rate']>0,download=downloaded['download'],state=state)
    cached=Path(downloaded['download']['path']);record('Downloaded bytes exactly match HTTP fixture',cached.exists() and hashlib.sha256(cached.read_bytes()).digest()==hashlib.sha256(wav_bytes).digest())
    ui('activate');command('open',hash=slow['hash'],autostart=True);wait(lambda s:s['state']['ready'] and s['state']['rate']>0)
    command('download',hash=aac['hash']);wait(lambda s:s['download']['cached'],hash=aac['hash'])
    command('open',hash=aac['hash'],autostart=True);s=wait(lambda s:s['state']['ready'] and s['state']['rate']>0)
    record('Downloaded AAC is playable',s['state']['duration']>850 and s['state']['volume']==0,state=s['state'])
    phase('download-cancel-retry');cancel=controlled['slow'][1]
    command('download',hash=cancel['hash']);hold(2);command('cancelDownload',hash=cancel['hash']);hold(2)
    s=command(hash=cancel['hash']);record('Canceled download has no committed cache',not s['download']['cached'] and not s['download']['caching'],download=s['download'])
    command('download',hash=cancel['hash']);wait(lambda s:s['download']['cached'],seconds=90,hash=cancel['hash'])
    record('Explicit retry completes the canceled download',True)
    phase('download-pause-resume');pausable=controlled['slow'][2]
    command('download',hash=pausable['hash']);hold(2);command('pauseDownload',hash=pausable['hash']);hold(2)
    before=command(hash=pausable['hash'])['download'];hold(4);after=command(hash=pausable['hash'])['download']
    record('Paused download does not commit or advance',not after['cached'] and abs(after['progress']-before['progress'])<.02,before=before,after=after)
    command('resumeDownload',hash=pausable['hash']);wait(lambda s:s['download']['cached'],seconds=90,hash=pausable['hash'])
    record('Paused download resumes to completion',True)
    phase('truncated-download');peer_state['media_mode']['broken']='truncated'
    command('download',hash=broken['hash']);hold(10);s=command(hash=broken['hash'])
    # iOS's background URLSession owns connection-loss retries (observed exponential
    # retries). It must never publish the partial file as a completed download.
    record('Connection-loss retries never commit a partial cache',not s['download']['cached'] and s['download']['progress']<1,download=s['download'])
    command('cancelDownload',hash=broken['hash']);wait(lambda s:not s['download']['caching'],hash=broken['hash'])
    peer_state['media_mode']['broken']='normal';command('download',hash=broken['hash']);wait(lambda s:s['download']['cached'],hash=broken['hash'])
    record('Failed download recovers when source returns',True)
    for mode,index in [('invalid',1),('short',2)]:
        phase('download-content-'+mode);bad=controlled['broken'][index];peer_state['media_mode']['broken']=mode
        command('download',hash=bad['hash']);s=wait(lambda s:bool(s['download']['error']) or s['download']['cached'],hash=bad['hash'])
        record(mode+': complete HTTP response with unusable/too-short media is rejected',not s['download']['cached'] and bool(s['download']['error']),download=s['download'])
    peer_state['media_mode']['broken']='normal'
    phase('stream-outage-and-recovery');outage=controlled['wav'][1];peer_state['media_mode']['wav']='unavailable'
    command('open',hash=outage['hash'],autostart=True);failed=wait(lambda s:s['state']['failed'])['state']
    record('HTTP outage preserves selected episode and exposes playback failure',failed['episodeHash']==outage['hash'] and failed['paused'] and bool(failed['playbackError']),state=failed)
    ui('home');hold(4);ui('activate');peer_state['media_mode']['wav']='normal'
    command('open',hash=outage['hash'],autostart=True);recovered=wait(lambda s:s['state']['ready'] and s['state']['rate']>0)['state']
    record('Explicit playback retry recovers after source outage',not recovered['failed'] and recovered['volume']==0,state=recovered)
    phase('background-sleep-expiry');command('open',hash=aac['hash'],autostart=True);wait(lambda s:s['state']['rate']>0)
    command('sleep',seconds=15);ui('home');hold(22);ui('activate');s=command()['state']
    events=[json.loads(line) for line in (directory/'events.jsonl').read_text().splitlines()]
    expirations=[e for e in events if e['phase']=='background-sleep-expiry' and e['event']=='AudioSessionSleepTimerDidExpireNotification']
    record('Sleep timer expires in background and foreground cannot resume it',s['paused'] and s['rate']==0 and any(e['applicationState']==2 for e in expirations),state=s,expiryEvents=expirations)
    phase('paused-timer-freeze');command('sleep',seconds=18);before=command()['state']['timer'];ui('home');hold(12);ui('activate');after=command()['state']['timer']
    record('Paused sleep timer preserves remaining duration across background',abs(float(after.get('pausedRemainingSeconds',0))-float(before.get('pausedRemainingSeconds',0)))<1,before=before,after=after)
    command('play');hold(3);command('sleep',seconds=0)
    phase('mixed-refresh-download-sync');peer_state['revision']+=1;mix=controlled['slow'][3]
    command('download',hash=mix['hash']);command('refresh',all=True,operation='mixed-refresh')
    command('cloud',background=True,operation='cloud-background');command('sleep',seconds=20)
    ui('home');hold(28);ui('activate')
    s=wait(lambda s:s['operations'].get('mixed-refresh',{}).get('done'),seconds=150)
    record('Concurrent real/synthetic refresh completes',s['operations']['mixed-refresh'].get('success'),operation=s['operations']['mixed-refresh'])
    record('Sleep wins over refresh/download/sync completions',s['state']['paused'] and s['state']['rate']==0,state=s['state'])
    cloud=wait(lambda s:s['operations'].get('cloud-background',{}).get('done'),seconds=45)
    record('No-account background sync completes without remaining busy',not cloud['state']['iCloudSyncInProgress'],operation=cloud['operations']['cloud-background'],state=cloud['state'])
    capture('mixed-after')
    phase('background-automatic-download');peer_state['revision']+=1
    command('automaticDownloads',urls=[base+'/aac.xml'],enabled=True)
    command('open',hash=wav['hash'],autostart=True);wait(lambda s:s['state']['rate']>0)
    ui('home');command('refresh',urls=[base+'/aac.xml'],operation='automatic-refresh')
    wait(lambda s:s['operations'].get('automatic-refresh',{}).get('done'))
    automatic=command('episodes',urls=[base+'/aac.xml'],limit=1)['episodes'][0]
    auto=wait(lambda s:s['download']['cached'],hash=automatic['hash'])
    record('Feed refresh automatically downloads new audio in background',auto['state']['applicationState']==2,download=auto['download'],state=auto['state'])
    ui('activate');command('automaticDownloads',urls=[base+'/aac.xml'],enabled=False)
    phase('appearance-rotation-ui');sim('ui',args.udid,'appearance','dark');sim('ui',args.udid,'content_size','accessibility-large')
    ui('landscape');ui('scroll');ui('portrait');capture('large-dark-text')
    sim('ui',args.udid,'content_size','large');sim('ui',args.udid,'appearance','light')
    phase('native-transport-controls');command('open',hash=aac['hash'],autostart=True);wait(lambda s:s['state']['rate']>0)
    tapped=ui('tap',label='Pause');s=command()['state']
    record('Native Pause button remains usable after layout/state changes',tapped.get('hittable') and s['paused'] and s['rate']==0,state=s)
    tapped=ui('tap',label='Play');s=wait(lambda s:s['state']['rate']>0)['state']
    record('Native Play button resumes the same episode',tapped.get('hittable') and s['episodeHash']==aac['hash'],state=s)
    phase('repeated-open-close');command('sleep',seconds=0)
    for iteration in range(30):
        item=[aac,wav,slow][iteration%3];command('open',hash=item['hash'],autostart=False)
        wait(lambda s:s['state']['ready']);command('play');command('pause');command('close')
    record('30 alternating codec/player lifecycles complete',command()['state']['paused'])
    if args.bulk:
        phase('bulk-import-'+str(args.bulk));command('open',hash=aac['hash'],autostart=True);wait(lambda s:s['state']['rate']>0)
        outlines=''.join(f'<outline type="rss" text="Stress {i}" xmlUrl="{base}/bulk-{i}.xml"/>' for i in range(args.bulk))
        (directory/'subscriptions.opml').write_text('<?xml version="1.0"?><opml version="2.0"><head><title>Lifecycle load</title></head><body>'+outlines+'</body></opml>')
        command('import',operation='bulk-import')
        ui('scroll');ui('home');hold(15);ui('activate')
        imported=wait(lambda s:s['operations'].get('bulk-import',{}).get('done'),seconds=900)
        counts=command(details=True)
        record('1,000 subscriptions import while player remains live',not imported['operations']['bulk-import'].get('error') and counts['feedCount']>=args.bulk and counts['state']['rate']>0,state=counts)
        phase('bulk-refresh-'+str(args.bulk));peer_state['revision']+=1;command('refresh',all=True,operation='bulk-refresh')
        command('openList');ui('scroll');ui('home');hold(30);ui('activate')
        refreshed=wait(lambda s:s['operations'].get('bulk-refresh',{}).get('done'),seconds=900)
        record('1,000-feed refresh completes without losing playback',refreshed['operations']['bulk-refresh'].get('success') and refreshed['state']['rate']>0,state=refreshed)
        capture('bulk-after')
    phase('process-recovery');command('pause');saved=command(details=True)
    sim('terminate',args.udid,BUNDLE);pid=launch();ui('activate');restored=command(timeout=90,details=True)
    record('Process restart preserves subscriptions and cache without autoplay',restored['feedCount']==saved['feedCount'] and restored['state']['paused'] and restored['state']['rate']==0,saved=saved,restored=restored)
    record('Completed download survives process restart',command(hash=aac['hash'])['download']['cached'])
    phase('final-background-playback');command('open',hash=aac['hash'],autostart=True);wait(lambda s:s['state']['rate']>0);ui('home');hold(60);ui('activate');command('pause')
    phase('post-stress-idle');hold(30);capture('final')
    phase('saved-rank-boundary')
    boundary_url=base+'/wav.xml'
    xml=f'<instacast version="1"><podcasts><podcast url="{boundary_url}" rank="-2147483648"/></podcasts></instacast>'
    (directory/'backup-ranks.xml').write_text(xml);(out/'boundary-rank-backup.xml').write_text(xml)
    command('backupRanks',operation='boundary-rank');boundary=wait(lambda s:s['operations'].get('boundary-rank',{}).get('done'),seconds=150)
    before_boundary=command('feedOrder')['feedOrder']
    record('Backup restores the signed rank lower bound',not boundary['operations']['boundary-rank'].get('error') and before_boundary[0]['url']==boundary_url and before_boundary[0]['rank']==-2147483648,feedOrder=before_boundary)
    subscribe(base+'/rank-boundary-new.xml','subscribe-rank-boundary')
    after_boundary=command('feedOrder')['feedOrder']
    record('Subscribing at the signed rank boundary preserves the complete visible order',
        [f['url'] for f in after_boundary]==[base+'/rank-boundary-new.xml']+[f['url'] for f in before_boundary]
        and all(-2147483648<=f['rank']<=2147483647 for f in after_boundary),feedOrder=after_boundary)
    command('exportLogs');shutil.copy2(directory/'export.txt',out/'InstacastPlus-CrashLogs.txt')
    account=command()['state'];record('CloudKit account availability is captured',account['accountStatus']!=0 or bool(account['accountError']),accountStatus=account['accountStatus'],error=account['accountError'],status=account['iCloudStatus'])
    did_complete = True
except Exception as error:
    record('Full workload reaches completion',False,error=repr(error))
    raise
finally:
    try:ui('finish')
    except Exception as error:(out/'native-cleanup-error.txt').write_text(str(error))
    stop_sampler.set();peer.shutdown()
    for file in ['telemetry.jsonl','events.jsonl','export.txt']:
        if (directory/file).exists():shutil.copy2(directory/file,out/file)
    logs=container/'Documents/Logs'
    if logs.exists():shutil.copytree(logs,out/'Logs',dirs_exist_ok=True)
    sim('terminate',args.udid,BUNDLE,check=False)
    try:native.wait(timeout=40)
    except subprocess.TimeoutExpired:native.terminate();native.wait(timeout=10)
    native_log.close()
    (out/'result.json').write_text(json.dumps(dict(passed=did_complete and bool(checks) and all(c['passed'] for c in checks) and native.returncode==0,fullRunComplete=did_complete,continuationOf=str(args.resume_bulk.resolve()) if args.resume_bulk else None,checks=len(checks),failed=[c['name'] for c in checks if not c['passed']],nativeExitCode=native.returncode,finished=datetime.now(timezone.utc).isoformat()),indent=2))
if any(not c['passed'] for c in checks):raise SystemExit(1)
