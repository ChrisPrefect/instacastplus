#!/usr/bin/env python3
"""Real HTTP audio completeness and fenced source recovery, without inference."""
import errno
import hashlib
import io
import sys
import threading
import unittest
import wave
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
import server_audio_source_regression as source_tests
from app import config,security,service,worker
from app.db import tx

class WorkerDeath(BaseException):pass
class ASRReached(Exception):pass

class SourceRecoveryTests(unittest.TestCase):
    setUp=source_tests.ServerAudioSourceTests.setUp
    post=source_tests.ServerAudioSourceTests.post
    admitted=source_tests.ServerAudioSourceTests.admitted
    request_row=source_tests.ServerAudioSourceTests.request_row

    def source(self,mode='full200'):
        data=io.BytesIO()
        with wave.open(data,'wb') as wav:
            wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(16000);wav.writeframes(b'\x00\x00'*32000)
        state={'audio':data.getvalue(),'gets':0}
        class Source(BaseHTTPRequestHandler):
            def do_GET(self):
                state['gets']+=1
                complete=state['audio'];body=complete[:32044] if mode=='partial' else complete
                self.send_response(200 if mode in {'full200','truncated200'} else 206)
                self.send_header('Content-Type','audio/wav')
                self.send_header('Content-Length',str(len(body)+(10 if mode=='truncated200' else 0)))
                if mode not in {'full200','truncated200'}:
                    value='malformed' if mode=='malformed' else f'bytes 0-{len(body)-1}/{len(complete)+(10 if mode=="badsize" else 0)}'
                    self.send_header('Content-Range',value)
                self.end_headers();self.wfile.write(body)
            def log_message(self,*args):pass
        source=ThreadingHTTPServer(('127.0.0.1',0),Source)
        threading.Thread(target=source.serve_forever,daemon=True).start()
        self.addCleanup(source.server_close);self.addCleanup(source.shutdown)
        self.contexts.enter_context(patch.object(security,'validate_public_url',side_effect=lambda url,*a,**kw:url))
        self.url=f'http://127.0.0.1:{source.server_port}/audio.wav'
        return state

    def test_full_http_200_and_206_are_complete(self):
        for mode in ['full200','full206']:
            state=self.source(mode)
            target=Path(self.temp.name)/(mode+'.wav')
            path,meta=worker.download_audio(self.url,target)
            self.assertEqual(state['audio'],path.read_bytes())
            self.assertEqual(2.0,worker.audio_duration(path))

    def test_partial_or_invalid_range_never_becomes_source(self):
        for mode in ['partial','malformed','badsize','truncated200']:
            with self.subTest(mode=mode):
                self.source(mode)
                target=Path(self.temp.name)/(mode+'.wav')
                with self.assertRaises((RuntimeError,OSError)):worker.download_audio(self.url,target)
                self.assertFalse(target.exists())
                self.assertFalse(target.with_suffix('.wav.part').exists())

    def test_crash_before_duration_keeps_first_download_for_new_claim(self):
        state=self.source();episode=self.admitted();first_hash=hashlib.sha256(state['audio']).hexdigest()
        job=worker.claim_job('source-before-crash')
        with worker.job_claim(job),patch.object(worker,'audio_duration',side_effect=WorkerDeath):
            with self.assertRaises(WorkerDeath):worker.run_transcribe(job,{'source':'api_episode'})
        self.assertEqual(first_hash,self.request_row()['audio_sha256'])
        state['audio']=state['audio'][:-2]+b'\x01\x00'
        with tx() as con:con.execute("UPDATE jobs SET lease_until='2000-01-01T00:00:00+00:00' WHERE id=?",(job['id'],))
        resumed=worker.claim_job('source-after-crash')
        self.assertNotEqual(job['claim_token'],resumed['claim_token'])
        with worker.job_claim(resumed),patch.object(worker,'run_command',side_effect=ASRReached):
            with self.assertRaises(ASRReached):worker.run_transcribe(resumed,{'source':'api_episode'})
        self.assertEqual(1,state['gets'])
        self.assertEqual('active',self.request_row()['state'])
        self.assertEqual(first_hash,self.request_row()['audio_sha256'])

    def test_failed_audio_checkpoint_does_not_bind_unrecoverable_source(self):
        self.source();self.admitted();job=worker.claim_job('source-marker-failed')
        real_write=worker.write_json_atomic
        def write(path,payload):
            if path.name=='audio-checkpoint.json':raise OSError(errno.ENOSPC,'fixture full')
            return real_write(path,payload)
        with worker.job_claim(job),patch.object(worker,'write_json_atomic',side_effect=write):
            with self.assertRaises(OSError):worker.run_transcribe(job,{'source':'api_episode'})
        self.assertIsNone(self.request_row()['audio_sha256'])
        self.assertEqual('active',self.request_row()['state'])

if __name__=='__main__':unittest.main(verbosity=2)
