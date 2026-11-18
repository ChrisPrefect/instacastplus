#!/usr/bin/env python3
"""Real app/SQLite/HTTP refresh timing on a disposable simulator.

The input is a read-only device-store snapshot. A SQLite backup is installed only
in a dedicated simulator; feed URLs in that copy point at a local HTTP peer. No
app method is replaced. Timing instrumentation calls the original Core
Data APIs and records their stacks. Retains commands, hashes, inputs, screenshots,
display frames, fetch timings and app diagnostics. Never contacts private feeds.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
import uuid
from xml.sax.saxutils import escape
from datetime import datetime,timezone,timedelta
from email.utils import format_datetime

ROOT=Path(__file__).resolve().parents[1]
BUNDLE='com.iteconomy.instacastplus'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid',required=True)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--store-directory',type=Path,required=True)
    parser.add_argument('--evidence',type=Path,required=True)
    parser.add_argument('--sounds',choices=['YES','NO'],default='YES')
    parser.add_argument('--profile-stacks',action='store_true')
    parser.add_argument('--prepare-ui',action='store_true')
    parser.add_argument('--response',choices=['304','200'],default='304')
    parser.add_argument('--pending-changes',action='store_true')
    args=parser.parse_args()
    out=args.evidence.resolve();out.mkdir(parents=True,exist_ok=True)

    def run(command,check=True,env=None):
        r=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env)
        with (out/'commands.log').open('a') as log:log.write(shlex.join(command)+'\n'+r.stdout)
        if check and r.returncode:raise RuntimeError(r.stdout[-5000:])
        return r.stdout.strip()

    devices=json.loads(run(['xcrun','simctl','list','devices','-j']))['devices']
    runtime,device=next((r,d) for r,group in devices.items() for d in group if d['udid']==args.udid)
    assert device['name']=='Instacast Refresh Regression' and device['state']=='Booted'
    source=ROOT/'Tools/fixtures/refresh_responsiveness_probe.m'
    library=out/'RefreshResponsivenessProbe.dylib'
    run(['xcrun','clang','-dynamiclib','-fobjc-arc','-target','arm64-apple-ios17.0-simulator',
         '-isysroot',run(['xcrun','--sdk','iphonesimulator','--show-sdk-path']),'-framework','UIKit',
         '-framework','CoreData','-framework','QuartzCore',str(source),'-o',str(library)])
    run(['codesign','-s','-',str(library)])
    run(['xcrun','simctl','terminate',args.udid,BUNDLE],check=False)
    run(['xcrun','simctl','install',args.udid,str(args.app.resolve())])
    container=Path(run(['xcrun','simctl','get_app_container',args.udid,BUNDLE,'data']))
    data=container/'Documents/Data'
    if data.exists():shutil.rmtree(data)
    shutil.copytree(args.store_directory,data)
    # Consolidate WAL on the disposable copy; never mutate the device snapshot.
    with sqlite3.connect(data/'DataStore6.sqlite') as db:
        assert db.execute('pragma quick_check').fetchone()[0]=='ok'
        counts={table:db.execute('select count(*) from '+table).fetchone()[0] for table in ['ZFEED','ZEPISODE']}
        feeds=[r[0] for r in db.execute('select Z_PK from ZFEED')]
    requests=[]
    payloads={}
    if args.response=='200':
        with sqlite3.connect(data/'DataStore6.sqlite') as db:
            for key in feeds:
                title=db.execute('select ZTITLE from ZFEED where Z_PK=?',(key,)).fetchone()[0]
                items=[]
                for guid,title_ep,pub,fulltext,duration,image in db.execute('select ZGUID,ZTITLE,ZPUBDATE,ZFULLTEXT,ZDURATION,ZIMAGEURL_ from ZEPISODE where ZFEED=?',(key,)):
                    date=datetime(2001,1,1,tzinfo=timezone.utc)+timedelta(seconds=pub or 0)
                    artwork=f'<itunes:image href="{escape(image,{chr(34):"&quot;"})}"/>' if image else ''
                    items.append(f'<item><title>{escape(title_ep or "")}</title><guid isPermaLink="false">{escape(guid or "")}</guid>'
                                 f'<pubDate>{format_datetime(date)}</pubDate><description>{escape(fulltext or "")}</description>'
                                 f'<itunes:duration>{duration or 0}</itunes:duration>'
                                 +artwork+'<enclosure url="https://example.invalid/audio.mp3" length="2400000" type="audio/mpeg"/></item>')
                payloads[f'/feed-{key}.xml']=('<?xml version="1.0" encoding="UTF-8"?>'
                    '<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>'
                    f'<title>{escape(title or "")}</title><link>https://example.invalid/</link><description>Refresh fixture</description>'
                    +''.join(items)+'</channel></rss>').encode()

    class Peer(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(dict(time=time.time(),path=self.path,status=int(args.response)))
            self.send_response(int(args.response))
            body=payloads.get(self.path,b'')
            if args.response=='200':
                self.send_header('Content-Type','application/rss+xml; charset=utf-8')
                self.send_header('Content-Length',str(len(body)))
            self.end_headers()
            if body:self.wfile.write(body)
        def log_message(self,*unused):pass

    server=ThreadingHTTPServer(('127.0.0.1',0),Peer)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    with sqlite3.connect(data/'DataStore6.sqlite') as db:
        for key in feeds:
            db.execute('update ZFEED set ZSOURCEURL_=?, ZIMAGEURL_=NULL, ZUSERNAME=NULL where Z_PK=?',
                       (f'http://127.0.0.1:{server.server_port}/feed-{key}.xml',key))
    directory=container/'Documents/RefreshResponsivenessProbe';directory.mkdir(parents=True,exist_ok=True)
    for name in ['command.json','reply.json']:(directory/name).unlink(missing_ok=True)
    files=[source,Path(__file__).resolve(),ROOT/'Classes/Model/SubscriptionManager.m',
           ROOT/'Classes/Model/DatabaseManager.m',ROOT/'Classes/ListEpisodesTableViewController.m',ROOT/'Classes/Sound.m']
    for path in files:
        snapshot=out/'sources'/path.relative_to(ROOT)
        snapshot.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(path,snapshot)
    (out/'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable,*sys.argv]),device=device,runtime=runtime,counts=counts,
        sounds=args.sounds,http=f'All feeds return {args.response}; source URLs rewritten only in simulator copy',
        inputStoreSHA256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in args.store_directory.glob('DataStore6.sqlite*')},
        expected='Refresh handler and display gaps below 500ms; all requests complete',
        sourceSHA256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        binarySHA256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in args.app.glob('InstacastPlus*') if p.is_file()}),indent=2))
    launch=run(['xcrun','simctl','launch',f'--stdout={out/"stdout.log"}',f'--stderr={out/"stderr.log"}',
                args.udid,BUNDLE,'-UISoundEnabled',args.sounds,'-FTSIndexVersion','3','-AppleLanguages','(en)',
                '-RefreshProbePendingChanges','YES' if args.pending_changes else 'NO'],
               env=dict(os.environ,SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
    pid=int(launch.rsplit(':',1)[1])

    def command(action='status'):
        request=dict(id=str(uuid.uuid4()),action=action)
        (directory/'command.tmp').write_text(json.dumps(request));(directory/'command.tmp').replace(directory/'command.json')
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            try:
                reply=json.loads((directory/'reply.json').read_text())
                if reply['id']==request['id']:
                    with (out/'observations.jsonl').open('a') as log:log.write(json.dumps(dict(request=request,reply=reply))+'\n')
                    assert 'error' not in reply,reply
                    return reply
            except (FileNotFoundError,json.JSONDecodeError):pass
            time.sleep(.05)
        raise AssertionError(request)

    try:
        if args.prepare_ui:
            project=out/'Startup.xcodeproj';project.mkdir(exist_ok=True)
            shutil.copy2(ROOT/'Tools/fixtures/chapter_scroll_ui_project.pbxproj',project/'project.pbxproj')
            (out/'NativeScrollTests.swift').write_text('''import XCTest
final class NativeScrollTests: XCTestCase {
 func testDismissStartup() {
  let app=XCUIApplication(bundleIdentifier:"com.iteconomy.instacastplus")
  app.activate()
  let system=XCUIApplication(bundleIdentifier:"com.apple.springboard")
  for title in ["Nicht erlauben","Don’t Allow","Don't Allow"] {
   let button=system.alerts.buttons[title]
   if button.waitForExistence(timeout:1) {button.tap();break}
  }
  XCTAssertEqual(system.alerts.count,0,system.debugDescription)
 }
}
''')
            native=run(['xcodebuild','-project',str(project),'-scheme','NativeScrollTests',
                        '-destination','platform=iOS Simulator,id='+args.udid,'-derivedDataPath',str(out/'NativeDerived'),
                        '-parallel-testing-enabled','NO','-resultBundlePath',str(out/'startup.xcresult'),'test'],check=False)
            assert '** TEST SUCCEEDED **' in native,native[-3000:]
        command('open');time.sleep(3)
        def episode_state():
            with sqlite3.connect(data/'DataStore6.sqlite') as db:
                return db.execute('select ZOBJECTHASH,ZCONSUMED,ZSTARRED,ZPOSITION,ZLASTPLAYED from ZEPISODE order by ZOBJECTHASH,Z_PK').fetchall()
        original_episode_state=episode_state()
        before=command()
        sampler=None
        if args.profile_stacks:
            sample_log=(out/'sample-command.log').open('w')
            sampler=subprocess.Popen(['sample',str(pid),'5','1','-file',str(out/'main-thread.sample')],stdout=sample_log,stderr=subprocess.STDOUT)
        state=command('refresh')
        deadline=time.monotonic()+45
        while state['refreshing'] and time.monotonic()<deadline:time.sleep(.1);state=command()
        time.sleep(1)
        state=command('stop')
        if sampler:sampler.wait(timeout=10);sample_log.close()
        expected_state=original_episode_state
        if args.pending_changes:
            pending=state['pendingChanges']
            assert pending and pending['wasUnsaved'],pending
            expected_state=[r for r in expected_state if r[0]!=pending['edited'][0]]
            expected_state.extend([pending['edited'],pending['inserted']])
        state_matches=sorted([list(r) for r in episode_state()],key=lambda r:json.dumps(r))==sorted([list(r) for r in expected_state],key=lambda r:json.dumps(r))
        checks=[dict(name='Refresh handler yields within 500ms',passed=state['handlerMs']<500,observed=state['handlerMs']),
                dict(name='Main run loop remains within 500ms',passed=state['maximumHeartbeatGapMs']<500,observed=state['maximumHeartbeatGapMs']),
                dict(name='Displayed frames remain within 500ms',passed=state['maximumFrameGapMs']<500,observed=state['maximumFrameGapMs']),
                dict(name='Refresh preserves every episode and its playback/favorite state',passed=state_matches,observed=len(expected_state)),
                dict(name='Unchanged episode values do not create redundant database updates',passed=state['redundantEpisodeUpdates']==0,observed=dict(redundant=state['redundantEpisodeUpdates'],persistent=state['persistentEpisodeUpdates'])),
                dict(name='All eligible podcasts finish refreshing',passed=not state['refreshing'] and state['finished']>before['finished'] and len(requests)==state['expectedRequests'],observed=dict(state=state,requests=len(requests),expected=state['expectedRequests']))]
        (out/'checks.json').write_text(json.dumps(checks,indent=2))
        for check in checks:print(json.dumps(check),flush=True)
        for name in ['frames.json','fetches.json']:shutil.copy2(directory/name,out/name)
        run(['xcrun','simctl','io',args.udid,'screenshot',str(out/'refresh.png')])
        shutil.copytree(container/'Documents/Logs',out/'Logs',dirs_exist_ok=True)
        return 0 if all(c['passed'] for c in checks) else 1
    finally:
        server.shutdown()
        (out/'http.json').write_text(json.dumps(requests,indent=2))
        run(['xcrun','simctl','terminate',args.udid,BUNDLE],check=False)


if __name__=='__main__':sys.exit(main())
