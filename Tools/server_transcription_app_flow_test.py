#!/usr/bin/env python3
"""Full simulator app → controlled HTTP peer → real artifact import → status screen.

Uses the retained synthetic audio and matching real ASR artifacts from September 6.
Inference is replayed, not rerun. Never contacts the production transcription service.
"""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True, help='Dedicated disposable simulator UDID')
parser.add_argument('--audio', type=Path, default=ROOT / 'Tools/fixtures/server-sponsor-e2e/fixture.wav')
parser.add_argument('--app', type=Path, default=ROOT / 'build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
audio = args.audio.read_bytes()
audio_hash = hashlib.sha256(audio).hexdigest()
assert audio_hash == '92747209c31b54463fa69e40d7b29b15894a13ff00664e86ca8066112984b6d0'
fixture = ROOT / 'Tools/fixtures/server-sponsor-e2e'
payloads = [(fixture / name).read_bytes() for name in ['transcript.srt', 'chapters.json', 'ads.json', 'summary.json']]
revision = 'sha256:' + hashlib.sha256(payloads[0]).hexdigest()
state = {'phase': 'queued', 'request': None, 'posts': [], 'events': []}


class Peer(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, code, data, content_type='application/json', etag=None):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        if etag:
            self.send_header('ETag', etag)
        self.end_headers()
        self.wfile.write(data)

    def envelope(self):
        phase = state['phase']
        artifacts = []
        for i, (kind, data) in enumerate(zip(['transcript_srt', 'chapters_json', 'ads_json', 'summary_json'], payloads)):
            sha = hashlib.sha256(data).hexdigest()
            artifacts.append({'id': i + 1, 'kind': kind, 'url': base + 'artifacts/' + str(i + 1), 'content_type': 'application/x-subrip' if i == 0 else 'application/json', 'byte_size': len(data), 'sha256': sha, 'transcript_revision': revision, 'etag': '"' + sha + '"'})
        return json.dumps({'api_version': 'v1', 'episode': {'id': 1, 'status': 'ready' if phase == 'ready' else ('queued' if phase == 'queued' else 'running'), 'phase': phase, 'progress': None, 'server_duration_seconds': 114.835875, 'warnings': [], 'artifacts': artifacts if phase == 'ready' else [], 'media': {'audio_sha256': audio_hash}}, 'client_request': {'id': state['request'], 'episode_id': 1, 'state': 'active'}, 'retry_after_seconds': 1}).encode()

    def do_GET(self):
        state['events'].append(['GET', self.path])
        if self.path == '/fixture.wav':
            return self.send(200, audio, 'audio/wav')
        if self.path.startswith('/api/v1/artifacts/'):
            i = int(self.path.rsplit('/', 1)[1]) - 1
            data = payloads[i]
            return self.send(200, data, 'application/x-subrip' if i == 0 else 'application/json', '"' + hashlib.sha256(data).hexdigest() + '"')
        if self.path == '/api/v1/client-requests/' + str(state['request']):
            return self.send(200, self.envelope())
        self.send(404, b'{}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body['client_audio_sha256'] == audio_hash
        assert not body['force']
        state['request'] = body['client_request_id']
        state['posts'].append(body)
        state['events'].append(['POST', self.path])
        self.send(200, self.envelope())


peer = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
base = f'http://127.0.0.1:{peer.server_port}/api/v1/'
threading.Thread(target=peer.serve_forever, daemon=True).start()
bundle = 'com.iteconomy.instacastplus'


def sim(*command):
    return subprocess.check_output(['xcrun', 'simctl', *command], text=True).strip()


devices = json.loads(sim('list', 'devices', '-j'))['devices']
assert any(d['udid'] == args.device and d['name'] == 'Server transcription flow' for group in devices.values() for d in group), 'Use the dedicated disposable Server transcription flow simulator'
subprocess.run(['xcrun', 'simctl', 'uninstall', args.device, bundle], capture_output=True)
sim('install', args.device, str(args.app))
container = Path(sim('get_app_container', args.device, bundle, 'data'))
directory = container / 'Documents/TranscriptionAutomation'
directory.mkdir(parents=True, exist_ok=True)
sim('launch', '--terminate-running-process', args.device, bundle, '--server-flow-test-url', base, '-AppleLanguages', '(de)')


def command(action, **params):
    identifier = str(uuid.uuid4())
    content = {'id': identifier, 'action': action, **params}
    temp = directory / 'command.tmp'
    temp.write_text(json.dumps(content))
    temp.replace(directory / 'command.json')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            reply = json.loads((directory / 'latest.json').read_text())
            if reply.get('commandID') == identifier:
                assert reply['ok'], reply
                return reply
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(.1)
    raise AssertionError(f'No reply: {action}')


def capture(name):
    # Includes system overlays; the separate UIKit artifact verifies the unobscured layout.
    sim('io', args.device, 'screenshot', str(args.output / (name + '.png')))
    reply = command('status')
    (args.output / (name + '.json')).write_text(json.dumps(reply, ensure_ascii=False, indent=2))


try:
    prepared = command('serverFlowFixture')
    episode_hash = prepared['episodeHash']
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        episodes = command('listEpisodes')['episodes']
        if any(e['episodeHash'] == episode_hash and e['cached'] for e in episodes):
            break
    else:
        raise AssertionError('Actual CacheManager download did not complete')
    command('serverFlowStart', episodeHash=episode_hash)
    for phase in ['queued', 'downloading_audio', 'transcribing', 'analyzing', 'finalizing', 'ready']:
        state['phase'] = phase
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            snapshot = command('status')['queue']
            item = next((i for i in snapshot if i['episodeHash'] == episode_hash), None)
            if item and (item.get('serverPhase') == phase if phase != 'ready' else item['statusName'] == 'completed'):
                break
            if item and item['statusName'] == 'failed':
                raise AssertionError(item)
        else:
            raise AssertionError(f'No transition to {phase}: {snapshot}')
        capture(phase)
    inspected = command('inspect', episodeHash=episode_hash)
    (args.output / 'import.json').write_text(json.dumps(inspected, ensure_ascii=False, indent=2))
    assert len(state['posts']) == 1, state['posts']
    assert any('/artifacts/1' in e[1] for e in state['events'])
    result = {'passed': True, 'scope': 'Full simulator app, real media download/hash, HTTP, persisted request, all server phases, strict artifact import and status screen; inference replayed from matching real artifacts', 'device': args.device, 'audio_sha256': audio_hash, 'episodeHash': episode_hash, 'posts': state['posts'], 'events': state['events']}
    (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False))
finally:
    peer.shutdown()
