#!/usr/bin/env python3
"""Check the actual exported attachment, including its fresh export metadata.

The latest mail-preparation record must stand on its own: startup records can
have been rotated or cleared. This verifies the production output contract,
without inferring device identity from a mail subject or copying its logic.
"""
import argparse
import json
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('attachment',type=Path)
p.add_argument('--device-family',required=True,choices=['iPhone','iPad','Mac'])
p.add_argument('--runtime',required=True)
p.add_argument('--model')
p.add_argument('--version')
p.add_argument('--build')
args=p.parse_args()
events=[]
for line in args.attachment.read_text().splitlines():
    try: event=json.loads(line)
    except json.JSONDecodeError: continue
    if isinstance(event,dict):events.append(event)
prepared=[event for event in events if event.get('category')=='diagnostics' and event.get('message')=='Crash-Log-Mail vorbereitet']
assert prepared,'Export has no mail-preparation record'
metadata=prepared[-1]['metadata']
required={'appVersion','build','systemVersion','systemName','deviceFamily','deviceModelIdentifier','runtimeEnvironment',
          'previousSessionEndedUnexpectedly','previousSessionEndedInBackground','previousSessionState'}
assert required.issubset(metadata),f'Fresh export metadata missing: {sorted(required-set(metadata))}'
for key in required-{'previousSessionState'}:
    assert metadata[key] not in ['', 'unknown'],(key,metadata[key])
assert metadata['deviceFamily']==args.device_family,metadata
assert metadata['runtimeEnvironment']==args.runtime,metadata
assert metadata['systemName']=={'iPhone':'iOS','iPad':'iPadOS','Mac':'macOS'}[args.device_family],metadata
if args.model:assert metadata['deviceModelIdentifier']==args.model,metadata
if args.version:assert metadata['appVersion']==args.version,metadata
if args.build:assert metadata['build']==args.build,metadata
print('PASS:',json.dumps({key:metadata[key] for key in sorted(required)},ensure_ascii=False))
