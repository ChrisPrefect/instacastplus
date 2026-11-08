#!/usr/bin/env python3
"""No ASR for a source that matches none of the requesting devices."""
import json
import hashlib
import concurrent.futures
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent))
import queue_admission_regression as admission
from app import main, service, worker
from app.db import tx
from app.security import hash_token
from starlette.requests import Request


class AudioAdmissionTests(unittest.TestCase):
    setUp = admission.AdmissionTests.setUp
    assert_error = admission.AdmissionTests.assert_error

    def request(self, client='a'):
        return Request({'type': 'http', 'headers': [(b'x-client', client.encode())]})

    def submit(self, audio='a'*64, client='a', rid=None):
        data = dict(episode_url='https://example.org/episode.mp3', title='Episode',
                    client_duration_seconds=0.0, wait_seconds=0, force=False,
                    client_request_id=rid or ('11111111-1111-4111-8111-111111111111' if client == 'a' else '22222222-2222-4222-8222-222222222222'))
        if audio is not None:
            data['client_audio_sha256'] = audio
        return main.submit_episode(main.EpisodeRequest(**data), self.request(client), 1)

    def test_missing_hash_rejected_before_job(self):
        self.assert_error(lambda: self.submit(None), 422, 'audio_identity_required')
        with tx() as con:
            self.assertEqual(0, con.execute('SELECT COUNT(*) AS n FROM jobs').fetchone()['n'])

    def test_request_hash_is_durable_and_immutable(self):
        episode = json.loads(self.submit().body)['episode']['id']
        with tx() as con:
            row = service.request_record(con, hash_token('a'), '11111111-1111-4111-8111-111111111111')
            self.assertEqual('a'*64, row['audio_sha256'])
        self.assert_error(lambda: self.submit('b'*64), 409, 'request_conflict')
        self.assertEqual(episode, json.loads(self.submit().body)['episode']['id'])

    def test_all_mismatched_requests_stop_before_duration_or_asr(self):
        episode = json.loads(self.submit().body)['episode']['id']
        with patch.object(worker, 'transcription_provider_status', return_value=None), patch.object(worker, 'transcribe_block_reason', return_value=None):
            job = worker.claim_job('test')
        audio = Path(self.temp.name)/'audio.mp3'
        audio.write_bytes(b'different audio')
        with worker.job_claim(job), patch.object(worker, 'transcription_language_status', return_value=None), \
             patch.object(worker, 'prepare_claim_directory', return_value=audio.parent), \
             patch.object(worker, 'set_episode_status'), \
             patch.object(worker, 'download_audio', return_value=(audio, {})), \
             patch.object(worker, 'audio_duration') as duration, patch.object(worker, 'run_command') as asr:
            with self.assertRaisesRegex(service.TranscriptionJobError, 'audio_source_mismatch'):
                worker.run_transcribe(job, {'source': 'api_episode'})
            duration.assert_not_called()
            asr.assert_not_called()
        self.assert_error(lambda: main.get_client_request('11111111-1111-4111-8111-111111111111', self.request(), 1), 409, 'audio_source_mismatch')

    def test_distinct_requested_sources_preserve_both_clients(self):
        episode=json.loads(self.submit().body)['episode']['id']
        other=json.loads(self.submit('b'*64,'b').body)['episode']['id']
        self.assertNotEqual(episode,other)
        with tx() as con:
            self.assertTrue(service.verify_requested_audio(con,episode,'a'*64))
            self.assertTrue(service.verify_requested_audio(con,other,'b'*64))
        self.assertEqual(202,main.get_client_request('11111111-1111-4111-8111-111111111111',self.request(),1).status_code)
        self.assertEqual(202,main.get_client_request('22222222-2222-4222-8222-222222222222',self.request('b'),1).status_code)

    def test_late_join_with_different_known_source_gets_new_generation(self):
        episode=json.loads(self.submit().body)['episode']['id']
        with tx() as con:
            con.execute("UPDATE episodes SET status='transcribing',audio_sha256=? WHERE id=?",('a'*64,episode))
            con.execute("UPDATE jobs SET verified_audio_sha256=? WHERE episode_id=?",('a'*64,episode))
        other=json.loads(self.submit('b'*64,'b').body)['episode']['id']
        self.assertNotEqual(episode,other)
        with tx() as con:
            self.assertEqual(2,con.execute('SELECT COUNT(*) AS n FROM jobs').fetchone()['n'])
            self.assertEqual('a'*64,con.execute('SELECT audio_sha256 FROM episodes WHERE id=?',(episode,)).fetchone()['audio_sha256'])

    def test_ready_result_keeps_its_source_when_new_source_is_requested(self):
        episode=json.loads(self.submit().body)['episode']['id']
        with tx() as con:
            con.execute("UPDATE jobs SET status='done' WHERE episode_id=?",(episode,))
            con.execute("UPDATE episodes SET status='ready',audio_sha256=? WHERE id=?",('a'*64,episode))
        with patch.object(main,'has_required_client_artifacts',return_value=True),patch.object(service,'has_required_client_artifacts',return_value=True):
            other=json.loads(self.submit('b'*64,'b').body)['episode']['id']
        self.assertNotEqual(episode,other)
        with tx() as con:
            row=service.request_record(con,hash_token('b'),'22222222-2222-4222-8222-222222222222')
            self.assertEqual('active',row['state']);self.assertEqual(other,row['episode_id'])
            self.assertEqual('a'*64,con.execute('SELECT audio_sha256 FROM episodes WHERE id=?',(episode,)).fetchone()['audio_sha256'])
        self.assertEqual(202,main.get_client_request('22222222-2222-4222-8222-222222222222',self.request('b'),1).status_code)

    def test_parallel_clients_keep_distinct_source_identities(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results=list(pool.map(lambda client:self.submit(client*64,client),['a','b']))
        self.assertTrue(all(r.status_code==202 for r in results))
        self.assertEqual(2,len({json.loads(r.body)['episode']['id'] for r in results}))
        with tx() as con:
            self.assertEqual(2,con.execute('SELECT COUNT(*) AS n FROM jobs').fetchone()['n'])
            self.assertEqual({'a'*64,'b'*64},{r['audio_sha256'] for r in con.execute('SELECT audio_sha256 FROM transcription_requests').fetchall()})

    def test_matching_download_reaches_duration_stage(self):
        audio = Path(self.temp.name)/'audio.mp3'
        audio.write_bytes(b'identical source')
        self.submit(hashlib.sha256(audio.read_bytes()).hexdigest())
        with patch.object(worker, 'transcription_provider_status', return_value=None), patch.object(worker, 'transcribe_block_reason', return_value=None):
            job = worker.claim_job('test')
        with worker.job_claim(job), patch.object(worker, 'transcription_language_status', return_value=None), \
             patch.object(worker, 'prepare_claim_directory', return_value=audio.parent), \
             patch.object(worker, 'set_episode_status'), \
             patch.object(worker, 'download_audio', return_value=(audio, {})), \
             patch.object(worker, 'audio_duration', side_effect=RuntimeError('duration reached')) as duration:
            with self.assertRaisesRegex(RuntimeError, 'duration reached'):
                worker.run_transcribe(job, {'source':'api_episode'})
            duration.assert_called_once_with(audio)

    def test_legacy_missing_identity_is_not_reported_as_mismatch(self):
        episode = json.loads(self.submit().body)['episode']['id']
        with tx() as con:
            con.execute('UPDATE transcription_requests SET audio_sha256=NULL WHERE episode_id=?', (episode,))
            self.assertFalse(service.verify_requested_audio(con, episode, 'a'*64))
        self.assert_error(lambda: main.get_client_request('11111111-1111-4111-8111-111111111111', self.request(), 1), 409, 'audio_identity_required')


if __name__ == '__main__':
    unittest.main()
