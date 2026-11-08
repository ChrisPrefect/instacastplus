import os,sys,json,hashlib,io,wave,threading
from pathlib import Path
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
ROOT=Path('/tmp/instacast-server-source-20261003')
sys.path[:0]=[str(ROOT/'tools'),str(ROOT)]
from queue_admission_regression import AdmissionTests
from api_contract_v3_regression import valid_artifacts
from app import main,service,worker,config,security
from app.db import tx,upsert_artifact
from fastapi.testclient import TestClient

case=AdmissionTests('runTest');case.setUp()
case.contexts.enter_context(patch.object(main,'transcription_resource_status',return_value=None))
case.contexts.enter_context(patch.object(worker,'transcription_resource_status',return_value=None))
case.contexts.enter_context(patch.object(config,'ROOT',ROOT))
case.contexts.enter_context(patch.object(worker,'PYTHON',Path(sys.executable)))
main.app.dependency_overrides[main.require_api_token]=lambda:1
client=TestClient(main.app)
def output(name,**values):print(json.dumps({'probe':name,**values}),flush=True)
def ready(url):
    with tx() as con:
        eid=service.ensure_episode(con,url,title='Audit source A')
        con.execute("UPDATE episodes SET status='ready',audio_sha256=?,detected_duration_seconds=10 WHERE id=?",('a'*64,eid))
        directory=Path(case.temp.name)/str(eid);directory.mkdir()
        paths,rev=valid_artifacts(directory)
        for kind,path in paths.items():upsert_artifact(con,eid,kind,path,'text/plain' if kind=='transcript_srt' else 'application/json')
        assert service.has_required_client_artifacts(con,eid)
    return eid,paths
def post(url,rid,mode,sha=None,force=False):
    body={'episode_url':url,'title':'Audit request','client_duration_seconds':0,'audio_source':mode,'client_request_id':rid,'wait_seconds':0,'force':force}
    if sha:body['client_audio_sha256']=sha
    r=client.post('/api/v1/episodes',json=body,headers={'x-client':'audit-client'})
    result=r.json();e=result.get('episode') or {}
    with tx() as con:jobs=con.execute('SELECT COUNT(*) n FROM jobs').fetchone()['n']
    output('ready_reuse_or_retry',mode=mode,force=force,http=r.status_code,status=e.get('status'),server_sha=(e.get('media') or {}).get('audio_sha256'),error=result.get('error'),jobs=jobs)
    return r
try:
    url='https://example.org/changed-source.wav';eid,paths=ready(url)
    for n,mode,sha,force in [(1,'server',None,False),(2,'server',None,True),(3,'client','b'*64,False),(4,'client','b'*64,True)]:
        post(url,f'00000000-0000-4000-8000-{n:012d}',mode,sha,force)
    broken='https://example.org/broken-artifact.wav';eid,paths=ready(broken)
    paths['transcript_srt'].unlink()
    r=post(broken,'00000000-0000-4000-8000-000000000005','server')
    output('broken_artifact_advertised_error',error=r.json().get('episode',{}).get('error'))
    post(broken,'00000000-0000-4000-8000-000000000006','server',force=True)
    buffer=io.BytesIO()
    with wave.open(buffer,'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000);f.writeframes(b'\x00\x00'*32000)
    audio=buffer.getvalue();partial=audio[:32044];restart_source={'body':audio};observed=[]
    class Source(BaseHTTPRequestHandler):
        def do_GET(self):
            observed.append(self.path)
            body=restart_source['body'] if self.path=='/restart.wav' else partial if self.path=='/partial.wav' else audio
            status=200 if self.path in ['/full200.wav','/restart.wav'] else 206
            self.send_response(status)
            self.send_header('Content-Type','audio/wav');self.send_header('Content-Length',str(len(body)))
            if status==206:self.send_header('Content-Range',f'bytes 0-{len(body)-1}/{len(audio)}')
            self.end_headers();self.wfile.write(body)
        def log_message(self,*args):pass
    source=ThreadingHTTPServer(('127.0.0.1',0),Source);threading.Thread(target=source.serve_forever,daemon=True).start()
    try:
        with patch.object(security,'validate_public_url',side_effect=lambda url,*args,**kw:url):
            for name in ['full200','full206','partial']:
                target=Path(case.temp.name)/(name+'.wav')
                try:
                    path,meta=worker.download_audio(f'http://127.0.0.1:{source.server_port}/{name}.wav',target)
                    duration=worker.audio_duration(path)
                    output('http_download',fixture=name,accepted=True,expected_whole_bytes=len(audio),saved_bytes=path.stat().st_size,decoded_seconds=duration,metadata=meta)
                except Exception as exc:output('http_download',fixture=name,accepted=False,error=str(exc))
            crash_url=f'http://127.0.0.1:{source.server_port}/restart.wav'
            response=post(crash_url,'00000000-0000-4000-8000-000000000007','server')
            crash_eid=response.json()['episode']['id']
            class WorkerDeath(BaseException):pass
            with patch.object(worker,'transcription_provider_status',return_value=None),patch.object(worker,'transcribe_block_reason',return_value=None):
                job=worker.claim_job('audit-before-checkpoint')
                assert job['episode_id']==crash_eid
                with worker.job_claim(job),patch.object(worker,'audio_duration',side_effect=WorkerDeath):
                    try:worker.run_transcribe(job,{'source':'api_episode'})
                    except WorkerDeath:pass
                with tx() as con:
                    prior=dict(con.execute('SELECT * FROM jobs WHERE id=?',(job['id'],)).fetchone())
                    requestrow=dict(service.request_record(con,security.hash_token('audit-client'),'00000000-0000-4000-8000-000000000007'))
                    con.execute("UPDATE jobs SET lease_until='2000-01-01T00:00:00+00:00' WHERE id=?",(job['id'],))
                old_audio=list((Path(case.temp.name)/'storage').rglob(worker.safe_media_filename(crash_url)))
                output('source_crash_boundary',request_hash=requestrow['audio_sha256'],download_present=bool(old_audio),checkpoint_present=bool(old_audio and (old_audio[0].parent/'audio-checkpoint.json').exists()))
                restart_source['body']=audio[:-2]+b'\x01\x00'
                resumed=worker.claim_job('audit-after-checkpoint-crash')
                assert resumed['id']==job['id'] and resumed['claim_token']!=job['claim_token']
                with worker.job_claim(resumed),patch.object(worker,'run_command',side_effect=AssertionError('No ASR expected')):
                    try:worker.run_transcribe(resumed,{'source':'api_episode'})
                    except Exception as exc:output('source_crash_resume',error=str(exc),source_gets=observed.count('/restart.wav'))
                with tx() as con:requestrow=dict(service.request_record(con,security.hash_token('audit-client'),'00000000-0000-4000-8000-000000000007'))
                output('source_crash_request',state=requestrow['state'],request_hash=requestrow['audio_sha256'])
    finally:source.shutdown();source.server_close()
finally:main.app.dependency_overrides.clear();case.doCleanups()
