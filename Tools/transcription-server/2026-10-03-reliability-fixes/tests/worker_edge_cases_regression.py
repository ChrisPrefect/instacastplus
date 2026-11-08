#!/usr/bin/env python3
"""Isolated duration, source, disk, subprocess and immutable resume proofs."""
import errno
import json
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
from queue_admission_regression import AdmissionTests
from app import config, service, worker
from app.db import tx
import transcribe_podcast_parallel as parallel

class EdgeCasesTests(AdmissionTests):
    def claim(self):
        self.seed(1)
        with patch.object(worker,'transcription_provider_status',return_value=None),patch.object(worker,'transcribe_block_reason',return_value=None):
            return worker.claim_job('edge-test')

    def run_until_asr(self, duration, raw=None):
        job=self.claim()
        def download(url,target,**kwargs):
            target.write_bytes(b'test audio');return target,{'audio_bytes':10}
        def command(cmd,*args,**kwargs):
            if raw is None:raise AssertionError('ASR was started')
            output=Path(cmd[cmd.index('--output-dir')+1])/'transcript-raw.json'
            output.write_text(json.dumps(raw))
        with worker.job_claim(job),patch.object(worker,'download_audio',side_effect=download),patch.object(worker,'audio_duration',return_value=duration),patch.object(worker,'run_command',side_effect=command):
            worker.run_transcribe(job,{})

    def test_200_hours_rejected_before_asr(self):
        with self.assertRaisesRegex(RuntimeError,'audio_duration_exceeded'):
            self.run_until_asr(200*3600)

    def test_nonfinite_duration_has_explicit_terminal_code(self):
        with self.assertRaisesRegex(RuntimeError,'audio_duration_invalid'):
            self.run_until_asr(float('nan'))

    def test_empty_asr_stops_before_ai_or_raw_checkpoint(self):
        with self.assertRaisesRegex(RuntimeError,'no_speech'):
            self.run_until_asr(10,{'segments':[]})

    def test_permanent_source_failure_does_not_consume_three_attempts(self):
        job=self.claim()
        with worker.job_claim(job):
            state=worker.fail_job(job,json.dumps({'code':'source_audio_unavailable','message':'Audio unavailable','retryable':False,'source_status':410}))
        self.assertEqual('failed',state)
        with tx() as con:row=dict(con.execute('SELECT * FROM jobs').fetchone())
        error=service.job_error(row)
        self.assertEqual('source_audio_unavailable',error['code'])
        self.assertFalse(error['retryable'])
        self.assertEqual(410,error['source_status'])

    def test_source_404_has_stable_error_without_url(self):
        response=worker.requests.Response();response.status_code=404;response.url='https://example.org/private-token.mp3'
        exc=worker.requests.HTTPError(response=response)
        with patch.object(worker,'guarded_get',side_effect=exc):
            with self.assertRaisesRegex(RuntimeError,'source_audio_unavailable') as caught:
                worker.download_audio('https://example.org/private-token.mp3',Path(self.temp.name)/'source.mp3')
        self.assertNotIn('private-token',str(caught.exception))

    def test_probe_hard_deadline_terminates_child(self):
        script=Path(self.temp.name)/'duration-probe'
        script.write_text('#!/bin/sh\nsleep 30\n');script.chmod(0o755)
        started=time.monotonic()
        with patch.object(worker,'PYTHON',script),patch.object(config,'AUDIO_PROBE_TIMEOUT_SECONDS',0.15,create=True):
            with self.assertRaisesRegex(RuntimeError,'processing_timeout'):
                worker.audio_duration(Path('audio.mp3'))
        self.assertLess(time.monotonic()-started,2)

    def test_download_total_deadline_covers_blocked_stream(self):
        class Response:
            status_code=200
            headers={}
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def iter_content(self,**kwargs):
                time.sleep(30);yield b'a'
        started=time.monotonic()
        with patch.object(worker,'guarded_get',return_value=Response()),patch.object(config,'AUDIO_DOWNLOAD_TIMEOUT_SECONDS',0.15,create=True):
            with self.assertRaisesRegex(RuntimeError,'processing_timeout'):
                worker.download_audio('https://example.org/audio.mp3',Path(self.temp.name)/'source.mp3')
        self.assertLess(time.monotonic()-started,2)

    def test_snapshot_enospc_preserves_resource_error(self):
        previous=Path(self.temp.name)/'previous';previous.mkdir()
        destination=Path(self.temp.name)/'new';destination.mkdir()
        (previous/'audio.mp3').write_bytes(b'a')
        marker={'name':'audio.mp3','audio_bytes':1,'sha256':worker.hashlib.sha256(b'a').hexdigest()}
        real_open=Path.open
        def opened(path,*args,**kwargs):
            if str(path).endswith('.snapshot-part'):raise OSError(errno.ENOSPC,'disk full')
            return real_open(path,*args,**kwargs)
        with patch.object(Path,'open',opened):
            with self.assertRaises(OSError) as caught:worker.snapshot_checkpoint_audio(previous,destination,marker)
        self.assertEqual(errno.ENOSPC,caught.exception.errno)

    def test_disk_pressure_interrupts_running_command(self):
        with patch.object(worker,'transcription_resource_status',return_value={'code':'resources_unavailable','message':'disk full','available':False}),patch.object(config,'COMMAND_MAX_SECONDS',0.15):
            with self.assertRaisesRegex(RuntimeError,'resources_unavailable'):
                worker.run_command([sys.executable,'-c','import time; time.sleep(30)'],Path(self.temp.name)/'cmd.log')

    def test_explicit_unsupported_language_rejected_before_download(self):
        with patch.object(config,'WHISPER_LANGUAGE','definitely-not-a-language'):
            with self.assertRaisesRegex(RuntimeError,'unsupported_language'):
                self.run_until_asr(10)

    def test_asr_work_files_belong_to_current_claim(self):
        job=self.claim()
        def download(url,target,**kwargs):
            target.write_bytes(b'a');return target,{'audio_bytes':1}
        def command(cmd,*args,**kwargs):
            self.assertIn('--work-dir',cmd)
            directory=Path(cmd[cmd.index('--work-dir')+1])
            self.assertIn(job['claim_token'],str(directory))
            raise RuntimeError('checked private directory')
        with worker.job_claim(job),patch.object(worker,'download_audio',side_effect=download),patch.object(worker,'audio_duration',return_value=10),patch.object(worker,'run_command',side_effect=command):
            with self.assertRaisesRegex(RuntimeError,'checked private directory'):worker.run_transcribe(job,{})

    def test_enospc_defers_same_job_without_attempt_and_is_visible(self):
        job=self.claim()
        with worker.job_claim(job):
            self.assertEqual('queued',worker.record_job_exception(job,OSError(errno.ENOSPC,'disk full')))
        with tx() as con:row=dict(con.execute('SELECT * FROM jobs').fetchone())
        self.assertEqual('queued',row['status']);self.assertEqual(0,row['attempts'])
        self.assertEqual('resources_unavailable',service.job_error(row)['code'])
        self.assertEqual('resources_unavailable',service.transcription_resource_status()['code'])

    def test_changed_source_or_language_invalidates_chunks(self):
        directory=Path(self.temp.name)/'work';directory.mkdir()
        chunks=parallel.build_chunks(duration=20,chunk_seconds=600,min_chunk_seconds=5,silence_intervals=[],boundary_search_seconds=60,preferred_silence_seconds=.8,overlap_seconds=0)
        self.assertFalse(parallel.prepare_chunk_plan(directory,chunks,{'audio_sha256':'a','language':'de'}))
        self.assertTrue(parallel.prepare_chunk_plan(directory,chunks,{'audio_sha256':'a','language':'de'}))
        self.assertFalse(parallel.prepare_chunk_plan(directory,chunks,{'audio_sha256':'b','language':'de'}))
        self.assertFalse(parallel.prepare_chunk_plan(directory,chunks,{'audio_sha256':'b','language':'en'}))

    def test_late_old_claim_cannot_change_copied_chunks(self):
        previous=Path(self.temp.name)/'old';destination=Path(self.temp.name)/'new'
        results=previous/'asr-work'/'chunk-results';results.mkdir(parents=True);destination.mkdir()
        (previous/'asr-work'/'chunk-plan.json').write_text(json.dumps({'identity':{'audio_sha256':'a'},'chunks':[]}))
        result=results/'chunk-000.json';result.write_text(json.dumps({'segments':[{'text':'original'}]}))
        worker.snapshot_completed_checkpoints(previous,destination)
        result.write_text(json.dumps({'segments':[{'text':'stale overwrite'}]}))
        copied=json.loads((destination/'asr-work'/'chunk-results'/'chunk-000.json').read_text())
        self.assertEqual('original',copied['segments'][0]['text'])

    def test_retention_preserves_paused_source_and_completed_chunks(self):
        job=self.claim()
        result=Path(self.temp.name)/'storage'/'episode';result.mkdir(parents=True)
        with worker.job_claim(job):run=worker.prepare_claim_directory(job,result)
        chunk=run/'asr-work'/'chunk-results'/'chunk-000.json';chunk.parent.mkdir(parents=True)
        chunk.write_text('{"segments":[{"text":"keep"}]}')
        audio=run/'audio.mp3';audio.write_bytes(b'keep source')
        old=time.time()-2*86400
        for path in [result,run,chunk,audio]:worker.os.utime(path,(old,old))
        with tx() as con:
            con.execute("UPDATE episodes SET result_dir=?",(str(result),))
            con.execute("UPDATE jobs SET status='paused'")
        with patch.object(worker,'delete_audio_after_transcribe',return_value=True):worker.cleanup_retention()
        self.assertTrue(chunk.is_file());self.assertTrue(audio.is_file())

    def test_schema_exposes_real_limits_and_error_details(self):
        from app import main
        schema=main.api_schema(1)
        limits=schema['audio_processing_contract']
        self.assertEqual(config.MAX_AUDIO_DURATION_SECONDS,limits['max_duration_seconds'])
        self.assertEqual(config.MAX_AUDIO_BYTES,limits['max_audio_bytes'])
        for key in ['max_audio_bytes','max_duration_seconds','source_status']:
            self.assertIn(key,schema['schemas']['EpisodeError']['properties'])

    def test_download_reports_received_byte_progress(self):
        class Response:
            status_code=200
            headers={'content-length':'10'}
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def iter_content(self,**kwargs):
                yield b'12345';time.sleep(.35);yield b'67890'
        original=time.monotonic
        with patch.object(worker,'guarded_get',return_value=Response()),patch.object(worker.time,'monotonic',side_effect=lambda:original()*100),patch.object(worker,'set_episode_progress') as progress:
            worker.download_audio('https://example.org/source.mp3',Path(self.temp.name)/'source.mp3',episode_id=1)
        self.assertTrue(any(call.args[2] > .03 for call in progress.call_args_list))

    def test_stop_interrupts_blocked_download_and_reaps_child(self):
        import threading
        class Response:
            status_code=200
            headers={}
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def iter_content(self,**kwargs):time.sleep(30);yield b'a'
        started=time.monotonic()
        with patch.object(worker,'STOP',False),patch.object(worker,'guarded_get',return_value=Response()):
            timer=threading.Timer(.1,lambda:setattr(worker,'STOP',True));timer.start()
            try:
                with self.assertRaises(service.TranscriptionProviderUnavailable):
                    worker.download_audio('https://example.org/source.mp3',Path(self.temp.name)/'source.mp3')
            finally:timer.cancel();timer.join()
        self.assertLess(time.monotonic()-started,2)
        self.assertEqual([],worker.multiprocessing.active_children())

    def test_real_parallel_export_preserves_empty_asr_for_no_speech_error(self):
        source=Path(self.temp.name)/'source.mp3';source.write_bytes(b'a')
        output=Path(self.temp.name)/'output'
        result={'index':0,'start':0,'duration':10,'segments':[],'total_seconds':0}
        argv=['parallel',str(source),'--name','raw','--output-dir',str(output),'--work-dir',str(Path(self.temp.name)/'work'),'--no-silence-boundaries']
        with patch.object(sys,'argv',argv),patch.object(parallel,'audio_duration',return_value=10),patch.object(parallel,'run_chunk',return_value=result):
            self.assertEqual(0,parallel.main())
        self.assertEqual([],json.loads((output/'raw.json').read_text())['segments'])

def load_tests(loader, tests, pattern):
    return unittest.TestSuite(EdgeCasesTests(name) for name in EdgeCasesTests.__dict__ if name.startswith('test_'))

if __name__=='__main__':unittest.main()
