#!/usr/bin/env python3
"""Full simulator app → controlled HTTP peer → real artifact import → status screen.

Uses the retained synthetic audio and matching real ASR artifacts from September 6.
Inference is replayed, not rerun. Never contacts the production transcription service.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--device', required=True, help='Dedicated disposable simulator UDID')
parser.add_argument('--audio', type=Path, default=ROOT / 'Tools/fixtures/server-sponsor-e2e/fixture.wav')
parser.add_argument('--app', type=Path, default=ROOT / 'build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--preserve-installation', action='store_true', help='Keep the dedicated simulator app and its previously answered system permission dialog')
parser.add_argument('--scenario', choices=['happy', 'recovery', 'server_source', 'server_source_recovery', 'ownership', 'cache_removed', 'pending_restart', 'import_concurrency'], default='happy')
args = parser.parse_args()
server_source = args.scenario.startswith('server_source') or args.scenario in ['ownership', 'pending_restart', 'import_concurrency']
recovery = args.scenario.endswith('recovery')
args.output.mkdir(parents=True, exist_ok=True)
(args.output / 'run.json').write_text(json.dumps({
    'command': sys.argv, 'started_at': datetime.now(timezone.utc).isoformat(),
    'device': args.device, 'app': str(args.app.resolve()),
    'binary_uuid': subprocess.check_output(['xcrun', 'dwarfdump', '--uuid', str(args.app / 'InstacastPlus.debug.dylib')], text=True).strip(),
    'fixture': str(args.audio.resolve()), 'inference': 'Retained real fixture results replayed over controlled HTTP',
}, indent=2))
audio = args.audio.read_bytes()
audio_hash = hashlib.sha256(audio).hexdigest()
assert audio_hash == '92747209c31b54463fa69e40d7b29b15894a13ff00664e86ca8066112984b6d0'
fixture = ROOT / 'Tools/fixtures/server-sponsor-e2e'
payloads = [(fixture / name).read_bytes() for name in ['transcript.srt', 'chapters.json', 'ads.json', 'summary.json']]
revision = 'sha256:' + hashlib.sha256(payloads[0]).hexdigest()
state = {'phase': 'queued', 'request': None, 'posts': [], 'events': [], 'paused': False, 'connection_error': False, 'requests': {}, 'deletes': []}
post_release = threading.Event()
artifact_release = threading.Event()
artifact_entered = threading.Event()


class Peer(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, code, data, content_type='application/json', etag=None):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Retry-After', '1')
        if etag:
            self.send_header('ETag', etag)
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def envelope(self, request_id=None):
        phase = state['phase']
        artifacts = []
        for i, (kind, data) in enumerate(zip(['transcript_srt', 'chapters_json', 'ads_json', 'summary_json'], payloads)):
            sha = hashlib.sha256(data).hexdigest()
            artifacts.append({'id': i + 1, 'kind': kind, 'url': base + 'artifacts/' + str(i + 1), 'content_type': 'application/x-subrip' if i == 0 else 'application/json', 'byte_size': len(data), 'sha256': sha, 'transcript_revision': revision, 'etag': '"' + sha + '"'})
        now = datetime.now(timezone.utc).isoformat()
        # A provider outage defers the real worker job to queued; paused is an explicit administrative pause.
        work = {'phase': phase, 'activity': 'queued' if state['paused'] else ('complete' if phase == 'ready' else ('queued' if phase == 'queued' else 'running')), 'updated_at': now, 'phase_started_at': now,
                'completed': 30 if phase == 'transcribing' else (len(audio)//2 if phase == 'downloading_audio' else None),
                'total': 114.835875 if phase == 'transcribing' else (len(audio) if phase == 'downloading_audio' else None),
                'unit': 'audio_seconds' if phase == 'transcribing' else ('bytes' if phase == 'downloading_audio' else None),
                'estimated_phase_remaining_seconds': 45 if phase == 'transcribing' and not state['paused'] else None,
                'queue_position': 1 if phase == 'queued' else None}
        envelope = {'api_version': 'v1', 'episode': {'id': 1, 'status': 'ready' if phase == 'ready' else ('queued' if phase == 'queued' else 'running'), 'phase': phase, 'progress': None, 'work': work, 'server_duration_seconds': 114.835875, 'warnings': [], 'artifacts': artifacts if phase == 'ready' else [], 'media': {'audio_sha256': audio_hash}}, 'client_request': {'id': request_id or state['request'], 'episode_id': 1, 'state': 'active'}, 'retry_after_seconds': 1}
        envelope['client_request']['audio_source'] = 'server' if server_source else 'client'
        if state['paused']:
            envelope['service_status'] = {'available': False, 'code': 'provider_unavailable', 'message': 'operator-only diagnostic', 'retry_after_seconds': 1}
        return json.dumps(envelope).encode()

    def do_GET(self):
        state['events'].append(['GET', self.path])
        if self.path == '/fixture.wav':
            if state.get('deny_audio'):
                return self.send(503, b'Audio unavailable during the transcript-reading check', 'text/plain')
            return self.send(200, audio, 'audio/wav')
        if self.path.startswith('/api/v1/artifacts/'):
            if args.scenario == 'import_concurrency' and self.path.endswith('/1'):
                artifact_entered.set()
                assert artifact_release.wait(25), 'Test did not release held artifact'
            i = int(self.path.rsplit('/', 1)[1]) - 1
            data = payloads[i]
            return self.send(200, data, 'application/x-subrip' if i == 0 else 'application/json', '"' + hashlib.sha256(data).hexdigest() + '"')
        if self.path.startswith('/api/v1/client-requests/') and self.path.rsplit('/', 1)[-1] in state['requests']:
            if state['connection_error']:
                return self.send(503, b'{"api_version":"v1","error":{"code":"temporarily_unavailable","message":"Temporary connection error","retryable":true}}')
            return self.send(200, self.envelope(self.path.rsplit('/', 1)[-1]))
        self.send(404, b'{}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert body.get('client_audio_sha256') == (None if server_source else audio_hash)
        assert body['audio_source'] == ('server' if server_source else 'client')
        assert not body['force']
        state['request'] = body['client_request_id']
        state['requests'][body['client_request_id']] = body
        state['posts'].append(body)
        state['events'].append(['POST', self.path])
        if recovery and len(state['posts']) == 1:
            # The receipt is durable, but the POST acknowledgement is lost at the HTTP boundary.
            return self.send(503, b'{"api_version":"v1","error":{"code":"temporarily_unavailable","message":"Response lost after admission","retryable":true}}')
        if args.scenario == 'pending_restart' and len(state['posts']) == 1:
            assert post_release.wait(25), 'Test did not release held POST'
        self.send(200, self.envelope(body['client_request_id']))

    def do_DELETE(self):
        request_id = self.path.rsplit('/', 1)[-1]
        state['deletes'].append(request_id)
        state['events'].append(['DELETE', self.path])
        self.send(200, json.dumps({'api_version': 'v1', 'client_request': {'id': request_id, 'state': 'canceled', 'episode_id': 1}}).encode())


peer = ThreadingHTTPServer(('127.0.0.1', 0), Peer)
base = f'http://127.0.0.1:{peer.server_port}/api/v1/'
threading.Thread(target=peer.serve_forever, daemon=True).start()
bundle = 'com.iteconomy.instacastplus'


def sim(*command):
    if command[0] == 'launch':
        # Mute only the disposable test app, including process-recovery launches.
        command = (*command, '-PlaybackVolume', '0')
    return subprocess.check_output(['xcrun', 'simctl', *command], text=True).strip()


devices = json.loads(sim('list', 'devices', '-j'))['devices']
assert any(d['udid'] == args.device and d['name'] == 'Server transcription flow' for group in devices.values() for d in group), 'Use the dedicated disposable Server transcription flow simulator'
if not args.preserve_installation:
    subprocess.run(['xcrun', 'simctl', 'uninstall', args.device, bundle], capture_output=True)
sim('install', args.device, str(args.app))
container = Path(sim('get_app_container', args.device, bundle, 'data'))
directory = container / 'Documents/TranscriptionAutomation'
directory.mkdir(parents=True, exist_ok=True)
sim('launch', '--terminate-running-process', args.device, bundle, '--server-flow-test-url', base, '-AppleLanguages', '(de)', '-LocalTranscriptionEnabled', 'YES')


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


def wait_item(predicate, description, timeout=40):
    deadline = time.monotonic() + timeout
    item = None
    while time.monotonic() < deadline:
        item = next((i for i in command('status')['queue'] if i['episodeHash'] == episode_hash), None)
        if item and predicate(item):
            return item
    raise AssertionError(f'{description}: {item}')


def start_and_wait_for_status():
    command('serverFlowStart', episodeHash=episode_hash)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        snapshot = command('status')
        if snapshot.get('statusScreenPresented'):
            return
    raise AssertionError(f'The real status view must be attached to the visible window: {snapshot}')


try:
    prepared = command('serverFlowFixture', download='false' if server_source else 'true')
    episode_hash = prepared['episodeHash']
    episodes = command('listEpisodes')['episodes']
    if server_source:
        assert not prepared['downloadStarted']
        assert any(e['episodeHash'] == episode_hash and not e['cached'] for e in episodes), episodes
    deadline = time.monotonic() + 30
    while not server_source and time.monotonic() < deadline:
        episodes = command('listEpisodes')['episodes']
        if any(e['episodeHash'] == episode_hash and e['cached'] for e in episodes):
            break
    if not server_source and not any(e['episodeHash'] == episode_hash and e['cached'] for e in episodes):
        raise AssertionError('Actual CacheManager download did not complete')
    start_and_wait_for_status()
    if args.scenario == 'pending_restart':
        deadline = time.monotonic() + 10
        while len(state['posts']) < 1 and time.monotonic() < deadline:
            command('status')
        assert len(state['posts']) == 1
        first_hash = episode_hash
        prepared_second = command('serverFlowFixture', download='false')
        episode_hash = prepared_second['episodeHash']
        start_and_wait_for_status()
        deadline = time.monotonic() + 10
        persisted = None
        while time.monotonic() < deadline:
            for path in container.rglob('ServerTranscriptionQueue.json'):
                candidate = json.loads(path.read_text())
                if any(i['episodeHash'] == episode_hash and i['admissionState'] == 'pending' for i in candidate['items']):
                    persisted = candidate
                    break
            if persisted:
                break
            command('status')
        assert persisted, 'Second request must be durably pending before the process dies'
        (args.output / 'pending-before-restart.json').write_text(json.dumps(persisted, indent=2))
        sim('terminate', args.device, bundle)
        post_release.set()
        sim('launch', args.device, bundle, '--server-flow-test-url', base, '-AppleLanguages', '(de)')
        wait_item(lambda i: i.get('serverAdmissionConfirmed'), 'Durable unsent request must resume automatically')
        capture('pending-resumed')
        assert len(state['posts']) == 2 and len({p['client_request_id'] for p in state['posts']}) == 2, state['posts']
        result = {'passed': True, 'command': sys.argv, 'expected': 'Durable pending request sends after restart; first request is reconciled without duplicate POST', 'persisted': persisted, 'posts': state['posts'], 'events': state['events']}
        (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(0)
    if args.scenario == 'import_concurrency':
        wait_item(lambda i: i.get('serverAdmissionConfirmed'), 'First server job must be accepted')
        first_hash = episode_hash
        state['phase'] = 'ready'
        assert artifact_entered.wait(12), 'First result download must be held'
        prepared_second = command('serverFlowFixture', download='false')
        episode_hash = prepared_second['episodeHash']
        start_and_wait_for_status()
        wait_item(lambda i: i.get('serverPhase') == 'awaiting_import', 'Second POST must finish while the first artifact is blocked', timeout=10)
        capture('second-result-waiting')
        second_request = state['posts'][-1]['client_request_id']
        command('serverFlowCancel', episodeHash=episode_hash)
        deadline = time.monotonic() + 8
        while second_request not in state['deletes'] and time.monotonic() < deadline:
            command('status')
        assert second_request in state['deletes'], 'DELETE must reach server while another result download is blocked'
        assert not artifact_release.is_set()
        artifact_release.set()
        canceled_hash = episode_hash
        episode_hash = first_hash
        wait_item(lambda i: i.get('statusName') == 'completed', 'First import must finish after release')
        snapshot = command('status')
        assert not any(i['episodeHash'] == canceled_hash for i in snapshot['queue']), snapshot
        capture('first-import-complete')
        result = {'passed': True, 'command': sys.argv, 'expected': 'Independent POST/DELETE; one import; canceled result stays absent', 'posts': state['posts'], 'deletes': state['deletes'], 'events': state['events'], 'observed': snapshot}
        (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(0)
    if args.scenario == 'ownership':
        wait_item(lambda i: i.get('serverAdmissionConfirmed'), 'Server job must own the episode')
        attempted = command('enqueue', episodeHash=episode_hash)
        capture('competing-local-start')
        result = {'passed': attempted['started'] is False, 'command': sys.argv, 'device': args.device,
                  'scope': 'Real app server admission followed by local admission for the same episode',
                  'expected': 'Reject the second writer and preserve the accepted server job',
                  'observed': attempted, 'posts': state['posts'], 'events': state['events']}
        (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        assert not attempted['started'], 'Local work was admitted while the server already owns the same episode'
        assert len(state['posts']) == 1
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(0)
    for phase in ['queued', 'downloading_audio', 'transcribing', 'analyzing', 'finalizing', 'ready']:
        state['phase'] = phase
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            snapshot = command('status')['queue']
            item = next((i for i in snapshot if i['episodeHash'] == episode_hash), None)
            if item and (item.get('serverPhase') == phase if phase != 'ready' else item['statusName'] == 'completed'):
                break
            if item and item['statusName'] == 'failed':
                capture('failure')
                raise AssertionError(item)
        else:
            raise AssertionError(f'No transition to {phase}: {snapshot}')
        capture(phase)
        assert item.get('serverAdmissionConfirmed') is True, f'Server receipt must be explicitly available to presentation: {item}'
        if phase == 'transcribing':
            if args.scenario == 'cache_removed':
                command('serverFlowRemoveCache', episodeHash=episode_hash)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if any(e['episodeHash'] == episode_hash and not e['cached'] for e in command('listEpisodes')['episodes']):
                        break
                else:
                    raise AssertionError('CacheManager did not remove device audio')
                capture('cache-removed-before-result')
            assert item.get('serverWorkCompleted') == 30 and item.get('serverWorkTotal') == 114.835875, item
            assert item.get('serverWorkUnit') == 'audio_seconds', item
            assert item.get('serverEstimatedPhaseRemainingSeconds') == 45, item
            if recovery:
                sim('terminate', args.device, bundle)
                sim('launch', args.device, bundle, '--server-flow-test-url', base, '-AppleLanguages', '(de)')
                restored = wait_item(lambda i: i.get('serverAdmissionConfirmed') is True, 'Accepted request lost after restart')
                assert restored['serverWorkCompleted'] == 30, restored
                start_and_wait_for_status()
                capture('restored')
                state['paused'] = True
                paused = wait_item(lambda i: i.get('serverPhase') == 'paused', 'Pause not visible')
                assert paused['serverAdmissionConfirmed'] is True, paused
                assert 'operator' not in str(paused).lower() and 'betreiber' not in str(paused).lower(), paused
                capture('paused')
                paused_view = command('status')
                steps = paused_view['serverStatusProcess']
                assert steps[1]['detail'] == 'Abgeschlossen', steps
                assert steps[2]['detail'] == 'Verarbeitung pausiert', steps
                assert steps[3]['detail'] == 'Noch nicht begonnen', steps
                assert not paused_view['serverStatusAnimating'], paused_view
                state['paused'] = False
                wait_item(lambda i: i.get('serverPhase') == 'transcribing', 'Worker did not resume')
                state['connection_error'] = True
                interrupted = wait_item(lambda i: i.get('serverConnectionIssue') is True, 'Connection interruption not visible')
                assert interrupted['serverAdmissionConfirmed'] is True, interrupted
                capture('connection-interrupted')
                state['connection_error'] = False
                wait_item(lambda i: i.get('serverPhase') == 'transcribing' and not i.get('serverConnectionIssue'), 'Connection did not recover')
    inspected = command('inspect', episodeHash=episode_hash)
    (args.output / 'import.json').write_text(json.dumps(inspected, ensure_ascii=False, indent=2))
    assert len(state['posts']) == 1, state['posts']
    if server_source:
        assert ['GET', '/fixture.wav'] not in state['events'], 'Server transcription must not download the audio on this device'
        episodes = command('listEpisodes')['episodes']
        assert any(e['episodeHash'] == episode_hash and not e['cached'] for e in episodes), episodes
    artifacts = inspected['inspection']['artifacts']
    srt_path = Path(artifacts['srt']['path'])
    analysis_path = Path(artifacts['analysis']['path'])
    source_hash = subprocess.check_output(['xattr', '-p', 'com.iteconomy.instacastplus.source-audio-sha256', str(srt_path)], text=True).strip()
    analysis = json.loads(analysis_path.read_text())
    assert source_hash == audio_hash == analysis['sourceAudioSHA256'], analysis
    assert srt_path.read_bytes() == payloads[0]
    assert analysis['summary'] == json.loads(payloads[3])['summary']
    # Local analysis binds the decoded cues, while the wire revision binds SRT bytes.
    # Golden cue revision of the unchanged 28-cue September 6 fixture.
    assert analysis['transcriptRevision'] == 'e5455cda271c7499fcefc3f440aadabe902c04827eddb1007f21de887cab4ffc'
    shutil.copyfile(srt_path, args.output / 'imported.srt')
    shutil.copyfile(analysis_path, args.output / 'imported-analysis.json')
    assert any('/artifacts/1' in e[1] for e in state['events'])
    transcription_events = list(state['events'])
    if server_source:
        # Reading an imported transcript must work even while playback cannot
        # fetch the source. Keep its timing proof false through the real player.
        state['deny_audio'] = True
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            transcript = command('serverFlowTranscript', episodeHash=episode_hash)
            if transcript['playbackFailed'] and transcript['transcriptAvailable'] and transcript['transcriptVisible'] and transcript['cueCount'] == 28:
                break
        capture('transcript-reading')
        transcript = command('serverFlowTranscript', episodeHash=episode_hash)
        (args.output / 'transcript-view.json').write_text(json.dumps(transcript, ensure_ascii=False, indent=2))
        assert transcript['transcriptAvailable'] and transcript['transcriptVisible'], transcript
        assert transcript['playerPresented'], 'The actual player must remain visible when the audio source cannot load'
        assert transcript['cueCount'] == 28 and 'Stadtbibliothek' in transcript['text'], transcript
        assert transcript['playbackFailed'] and transcript['playEnabled'], transcript
        assert not transcript['timingVerified'] and not transcript['audioVerified'], transcript
        assert transcript['notice'], 'Explain why reading is available but timeline actions are not'
        state['deny_audio'] = False
        assert command('serverFlowRetryPlayback')['retryStarted']
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            retried = command('serverFlowTranscript', episodeHash=episode_hash)
            if retried['playbackReady'] and retried['audioVerified'] and retried['timingVerified']:
                break
        capture('playback-retry')
        retried = command('serverFlowTranscript', episodeHash=episode_hash)
        (args.output / 'playback-retry-view.json').write_text(json.dumps(retried, ensure_ascii=False, indent=2))
        assert retried['playbackReady'] and not retried['playbackFailed'] and retried['playerPresented'], retried
        assert retried['audioVerified'] and retried['timingVerified'], 'The unchanged, fully cached source must enable transcript timing after playback retry'
    result = {'passed': True, 'scenario': args.scenario, 'command': sys.argv, 'scope': 'Full simulator app, HTTP, persisted request, all server phases, strict artifact import/source binding and status screen; inference replayed from matching real artifacts', 'device': args.device, 'audio_sha256': audio_hash, 'imported_source_audio_sha256': source_hash, 'device_audio_download_before_result': not server_source, 'episodeHash': episode_hash, 'posts': state['posts'], 'events': state['events']}
    result['transcription_events'] = transcription_events
    (args.output / 'result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False))
finally:
    post_release.set()
    artifact_release.set()
    (args.output / 'http.json').write_text(json.dumps(state, ensure_ascii=False, indent=2))
    peer.shutdown()
    subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle], capture_output=True)
