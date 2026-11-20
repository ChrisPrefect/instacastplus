#!/usr/bin/env python3
"""Exercise the actual report exporter in a disposable simulator or Catalyst app.

Keeps exact commands, actual app/source fingerprints and exported attachments.
Only the named disposable simulator may clear logs; Catalyst exports are read-only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--app',type=Path,required=True)
p.add_argument('--evidence',type=Path,required=True)
p.add_argument('--udid')
p.add_argument('--device-family',required=True,choices=['iPhone','iPad','Mac'])
args=p.parse_args()
out=args.evidence.resolve();out.mkdir(parents=True,exist_ok=True)
assert not (out/'checks.json').exists(),'Use a fresh evidence directory'
app=args.app.resolve()
mac=not args.udid
info=plistlib.loads((app/('Contents/Info.plist' if mac else 'Info.plist')).read_bytes())
bundle=info['CFBundleIdentifier']


def run(command,check=True,env=None):
    r=subprocess.run(command,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env)
    with (out/'commands.log').open('a') as log:log.write(shlex.join(command)+'\n'+r.stdout+'\n')
    if check and r.returncode:raise RuntimeError(r.stdout[-4500:])
    return r


source=ROOT/'Tools/fixtures/crash_log_mail_export_probe.m'
library=out/'MailExportProbe.dylib'
if not mac:
    sdk=run(['xcrun','--sdk','iphonesimulator','--show-sdk-path']).stdout.strip()
    run(['xcrun','clang','-dynamiclib','-fobjc-arc','-target','arm64-apple-ios17.0-simulator',
         '-isysroot',sdk,'-framework','UIKit',str(source),'-o',str(library)])
    run(['codesign','-s','-',str(library)])
binary=app/('Contents/MacOS' if mac else '')/info['CFBundleExecutable']
identity=dict(command=shlex.join([sys.executable,*sys.argv]),app=str(app),version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],
              binarySHA256={str(f.relative_to(app)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [binary,*binary.parent.glob('*.debug.dylib')]},
              sourceSHA256={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [source,Path(__file__).resolve(),ROOT/'Classes/TranscriptionEngine.swift']},
              expected=dict(deviceFamily=args.device_family,runtime='Mac Catalyst' if mac else 'simulator',freshMetadataAfterClearing=not mac))
process=None
if mac:
    assert run(['pgrep','-f',str(binary)],check=False).returncode!=0,'Keep an already-running app intact'
    stderr=(out/'stderr.log').open('w');stdout=(out/'stdout.log').open('w')
    # Keep hardened-runtime/library validation intact; use its existing Debug
    # debugger entitlement to call the production exporter on the real app.
    process=subprocess.Popen([str(binary)],stdout=stdout,stderr=stderr)
else:
    devices=json.loads(run(['xcrun','simctl','list','devices','-j']).stdout)['devices']
    device=next(d for ds in devices.values() for d in ds if d['udid']==args.udid)
    assert device['name'].startswith('Instacast Mail Metadata ') and device['state']=='Booted'
    identity['device']=device
    run(['xcrun','simctl','terminate',args.udid,bundle],check=False)
    run(['xcrun','simctl','install',args.udid,str(app)])
    run(['xcrun','simctl','launch','--stderr='+str(out/'stderr.log'),'--stdout='+str(out/'stdout.log'),args.udid,bundle],
        env=dict(os.environ,SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))
(out/'environment.json').write_text(json.dumps(identity,indent=2))
shutil.copy2(source,out/source.name);shutil.copy2(Path(__file__).resolve(),out/'driver.py')
result=None
try:
    deadline=time.monotonic()+120
    while time.monotonic()<deadline:
        log=(out/'stderr.log').read_text(errors='replace') if (out/'stderr.log').exists() else ''
        if mac and 'sceneDidBecomeActive' in log:
            directory=Path.home()/'Library/Containers'/bundle/'Data/Documents'/('MailExportProbe-'+str(uuid.uuid4()))
            directory.mkdir()
            result=dict(directory=str(directory),files=['normal.txt'])
            expression='(BOOL)[[[[[(id)NSClassFromString(@"InstacastPlus.ICDiagnosticLogger") performSelector:NSSelectorFromString(@"shared")] performSelector:NSSelectorFromString(@"crashLogMailAttachments")] firstObject] valueForKey:@"data"] writeToFile:@"'+str(directory/'normal.txt')+'" atomically:YES]'
            commands=out/'export.lldb'
            commands.write_text(f'process attach --pid {process.pid}\nthread select 1\nexpression -l objc -a true -t 10000000 -- @import Foundation;\nexpression -l objc -a true -t 10000000 -- '+expression+'\nprocess detach\nquit\n')
            run(['xcrun','lldb','--batch','-s',str(commands)])
            break
        if not mac:
            markers=[line.partition('IC_MAIL_EXPORT_PROBE=')[2] for line in log.splitlines() if 'IC_MAIL_EXPORT_PROBE=' in line]
            if markers:result=json.loads(markers[-1]);break
        if process and process.poll() is not None:raise AssertionError(log[-4000:])
        time.sleep(.1)
    assert result,log[-4000:]
    (out/'probe-result.json').write_text(json.dumps(result,indent=2))
    checks=[]
    for name in result['files']:
        destination=out/name;shutil.copy2(Path(result['directory'])/name,destination)
        command=['python3',str(ROOT/'Tools/crash_log_mail_export_artifact_test.py'),str(destination),
                 '--device-family',args.device_family,'--runtime','Mac Catalyst' if mac else 'simulator',
                 '--version',info['CFBundleShortVersionString'],'--build',info['CFBundleVersion']]
        check=run(command,check=False)
        checks.append(dict(name=name,passed=check.returncode==0,observed=check.stdout))
        print(check.stdout,flush=True)
    (out/'checks.json').write_text(json.dumps(checks,indent=2))
    assert all(c['passed'] for c in checks)
finally:
    if process:
        if process.poll() is None:process.terminate();process.wait(timeout=20)
        stdout.close();stderr.close()
    else:run(['xcrun','simctl','terminate',args.udid,bundle],check=False)
    if result:
        directory=Path(result['directory'])
        assert directory.name.startswith('MailExportProbe-')
        shutil.rmtree(directory)
