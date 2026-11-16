#!/usr/bin/env python3
"""Send a real XCTest simulator gesture to adaptive_layout_ui_tests.swift.

The evidence directory contains Native.xcodeproj, its exact xcodebuild command,
directory.txt (the app probe directory), and Native.xcresult. Run the UI fixture
there, then use this client for native orientation/tap/drag/status/finish steps.
"""
import argparse
import json
from pathlib import Path
import shlex
import shutil
import sys
import time
import uuid

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--evidence', required=True, type=Path)
p.add_argument('--action', default='{"action":"status"}')
p.add_argument('--label', default='native')
args = p.parse_args()
out = args.evidence.resolve()
directory = Path((out / 'directory.txt').read_text())
request = dict(json.loads(args.action), id=str(uuid.uuid4()))
temp = directory / 'native-command.tmp'
temp.write_text(json.dumps(request))
temp.replace(directory / 'native-command.json')
with (out / 'commands.log').open('a') as f:
    f.write(shlex.join([sys.executable, *sys.argv]) + '\n')
if request['action'] == 'finish':
    sys.exit(0)
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    try:
        reply = json.loads((directory / 'native-reply.json').read_text())
        if reply.get('id') == request['id']:
            break
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    time.sleep(.1)
else:
    raise AssertionError('Native XCTest did not reply; inspect native-ui.log')
(out / (args.label + '.json')).write_text(json.dumps({'command': request, 'observed': reply}, indent=2))
shutil.copy2(directory / 'native-screen.png', out / (args.label + '.png'))
print(json.dumps({'frame': reply['frame'], 'artifact': str(out / (args.label + '.png'))}))
