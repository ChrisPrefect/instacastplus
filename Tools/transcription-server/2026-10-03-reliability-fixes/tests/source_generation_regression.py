#!/usr/bin/env python3
"""Immutable source generations through real API, DB and artifact contracts."""
import concurrent.futures
import json
import sqlite3
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parent))
import server_audio_source_regression as source_tests
from api_contract_v3_regression import valid_artifacts
from app import config,main,service,worker
from app.db import tx,init_db,upsert_artifact,connect,SQLITE_SCHEMA,is_mysql

class SourceGenerationTests(unittest.TestCase):
    setUp=source_tests.ServerAudioSourceTests.setUp
    def request(self,n,mode='server',sha=None,force=False):
        body={'episode_url':self.url,'title':'Generation fixture','client_duration_seconds':0,'wait_seconds':0,
              'audio_source':mode,'client_request_id':f'00000000-0000-4000-8000-{n:012d}','force':force}
        if sha:body['client_audio_sha256']=sha
        return self.client.post('/api/v1/episodes',json=body,headers={'x-client':'client-a'})
    def ready(self,sha='a'*64):
        response=self.request(1);self.assertEqual(202,response.status_code,response.text)
        eid=response.json()['episode']['id']
        directory=Path(self.temp.name)/str(eid);directory.mkdir()
        paths,_=valid_artifacts(directory)
        with tx() as con:
            con.execute("UPDATE episodes SET status='ready',audio_sha256=?,detected_duration_seconds=10 WHERE id=?",(sha,eid))
            con.execute("UPDATE jobs SET status='done' WHERE episode_id=?",(eid,))
            service.verify_requested_audio(con,eid,sha)
            for kind,path in paths.items():upsert_artifact(con,eid,kind,path,'text/plain' if kind=='transcript_srt' else 'application/json')
            self.assertTrue(service.has_required_client_artifacts(con,eid))
        return eid,paths
    def test_new_explicit_source_preserves_old_uuid_artifacts_and_cancel(self):
        original,paths=self.ready()
        before=self.client.get('/api/v1/client-requests/00000000-0000-4000-8000-000000000001',headers={'x-client':'client-a'}).json()
        response=self.request(2,force=True);self.assertEqual(202,response.status_code,response.text)
        new=response.json()['episode']['id'];self.assertNotEqual(original,new)
        with tx() as con:
            old=dict(con.execute('SELECT * FROM episodes WHERE id=?',(original,)).fetchone())
            current=dict(con.execute('SELECT * FROM episodes WHERE id=?',(new,)).fetchone())
            self.assertEqual(self.url,current['episode_url']);self.assertEqual(1,current['source_generation'])
            self.assertEqual(0,old['source_generation']);self.assertEqual('ready',old['status'])
        self.assertEqual(before,self.client.get('/api/v1/client-requests/00000000-0000-4000-8000-000000000001',headers={'x-client':'client-a'}).json())
        replay=self.request(2,force=True);self.assertEqual(new,replay.json()['episode']['id'])
        canceled=self.client.delete('/api/v1/client-requests/00000000-0000-4000-8000-000000000001',headers={'x-client':'client-a'})
        self.assertEqual(200,canceled.status_code)
        self.assertEqual(410,self.request(1).status_code)
        self.assertEqual(202,self.request(2,force=True).status_code)
        self.assertTrue(all(path.exists() for path in paths.values()))
        with tx() as con:self.assertEqual(1,con.execute("SELECT COUNT(*) n FROM jobs WHERE status='queued'").fetchone()['n'])
    def test_changed_client_hash_gets_generation_without_overwriting_original(self):
        original,_=self.ready()
        response=self.request(2,mode='client',sha='b'*64)
        self.assertEqual(202,response.status_code,response.text)
        new=response.json()['episode']['id'];self.assertNotEqual(original,new)
        with tx() as con:self.assertTrue(service.verify_requested_audio(con,new,'b'*64))
        self.assertEqual(202,self.request(2,mode='client',sha='b'*64).status_code)
        self.assertEqual(409,self.request(2,mode='client',sha='a'*64).status_code)
        matching=self.request(3,mode='client',sha='a'*64)
        self.assertEqual(200,matching.status_code,matching.text)
        self.assertEqual(original,matching.json()['episode']['id'])
    def test_parallel_restarts_deduplicate_current_generation(self):
        original,_=self.ready()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:responses=list(pool.map(lambda n:self.request(n,force=True),[2,3,4,5]))
        self.assertTrue(all(r.status_code==202 for r in responses),[r.text for r in responses])
        ids={r.json()['episode']['id'] for r in responses};self.assertEqual(1,len(ids));self.assertNotIn(original,ids)
        with tx() as con:self.assertEqual(1,con.execute("SELECT COUNT(*) n FROM jobs WHERE status='queued'").fetchone()['n'])
    def test_first_admission_race_keeps_different_hashes_separate(self):
        import threading
        from contextlib import contextmanager
        barrier=threading.Barrier(2);counter=threading.local();original=main.queue_admission_transaction
        @contextmanager
        def synchronized_admission():
            counter.value=getattr(counter,'value',0)+1
            if counter.value==3:barrier.wait(timeout=10)
            with original() as con:yield con
        with patch.object(main,'queue_admission_transaction',synchronized_admission),concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            responses=list(pool.map(lambda args:self.request(args[0],mode='client',sha=args[1]),[(2,'b'*64),(3,'c'*64)]))
        self.assertTrue(all(r.status_code==202 for r in responses),[r.status_code for r in responses])
        self.assertNotEqual(responses[0].json()['episode']['id'],responses[1].json()['episode']['id'])

    def test_first_lookup_race_does_not_force_overwrite_matching_ready(self):
        from contextlib import contextmanager
        original=main.queue_admission_transaction;calls=0;created=[]
        @contextmanager
        def another_client_completed():
            nonlocal calls
            calls+=1
            if calls==3:created.append(self.ready()[0])
            with original() as con:yield con
        with patch.object(main,'queue_admission_transaction',another_client_completed):
            response=self.request(2,mode='client',sha='a'*64,force=True)
        self.assertEqual(200,response.status_code,response.text)
        self.assertEqual(created[0],response.json()['episode']['id'])
        with tx() as con:self.assertEqual(0,con.execute("SELECT COUNT(*) n FROM jobs WHERE status='queued'").fetchone()['n'])

    def test_podcast_discovery_returns_current_generation_once(self):
        original,_=self.ready()
        with tx() as con:
            podcast=service.ensure_podcast(con,'https://example.org/feed.xml',title='Generations')
            con.execute('UPDATE episodes SET podcast_id=? WHERE id=?',(podcast,original))
        new=self.request(2,force=True).json()['episode']['id']
        self.assertEqual([new],main.get_podcast(podcast,1)['episode_ids'])
        self.assertEqual(original,self.request(1).json()['episode']['id'])

    def test_distinct_requested_hashes_have_distinct_pending_generations(self):
        self.ready()
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            responses=list(pool.map(lambda args:self.request(args[0],mode='client',sha=args[1]),[(2,'b'*64),(3,'c'*64),(4,'b'*64)]))
        self.assertTrue(all(r.status_code==202 for r in responses),[r.status_code for r in responses])
        ids=[r.json()['episode']['id'] for r in responses]
        self.assertEqual(ids[0],ids[2]);self.assertNotEqual(ids[0],ids[1])
        with tx() as con:
            self.assertTrue(service.verify_requested_audio(con,ids[0],'b'*64))
            self.assertTrue(service.verify_requested_audio(con,ids[1],'c'*64))
            self.assertEqual(3,con.execute("SELECT COUNT(*) n FROM transcription_requests WHERE state='active' AND audio_sha256 IN (?,?)",('b'*64,'c'*64)).fetchone()['n'])

    def test_cancel_old_generation_does_not_cancel_unbound_new_uuid(self):
        import hashlib
        original,_=self.ready()
        pending='00000000-0000-4000-8000-000000000002'
        from app.security import hash_token
        with tx() as con:
            service.store_client_request(con,hash_token('client-a'),pending,None,'unconfirmed',hashlib.sha256(self.url.encode()).hexdigest())
            service.cancel_request_interest(con,hash_token('client-a'),'00000000-0000-4000-8000-000000000001')
            self.assertEqual('unconfirmed',service.request_record(con,hash_token('client-a'),pending)['state'])

    def test_broken_ready_can_be_repaired_without_global_force(self):
        original,paths=self.ready();paths['transcript_srt'].unlink()
        failure=self.request(2);self.assertEqual('failed',failure.json()['episode']['status'])
        self.assertEqual('artifact_contract_invalid',failure.json()['episode']['error']['code'])
        with patch.object(config,'ALLOW_API_FORCE',False):
            response=self.request(3,force=True)
        self.assertEqual(202,response.status_code,response.text)
        self.assertNotEqual(original,response.json()['episode']['id'])
    def test_matching_ready_is_reused_and_admin_force_stays_disabled(self):
        original,_=self.ready()
        self.assertEqual(original,self.request(2).json()['episode']['id'])
        with patch.object(config,'ALLOW_API_FORCE',False):
            response=self.client.post('/api/v1/episodes',json={'episode_url':self.url,'title':'Legacy force','wait_seconds':0,'client_duration_seconds':0,'client_audio_sha256':'a'*64,'force':True},headers={'x-client':'client-a'})
        self.assertEqual(403,response.status_code,response.text)
    def test_feed_alias_resolves_current_generation_without_rebinding_original(self):
        original,_=self.ready()
        with tx() as con:
            service.add_episode_alias(con,original,'https://example.org/alias.wav','feed')
        new=self.request(2,force=True).json()['episode']['id']
        self.assertNotEqual(original,new)
        with tx() as con:
            self.assertEqual(new,main.find_episode_row_by_url(con,self.url)['id'])
            self.assertEqual(new,main.find_episode_row_by_url(con,'https://example.org/alias.wav')['id'])
            self.assertEqual(new,service.ensure_episode(con,'https://example.org/alias.wav'))
        self.assertEqual(original,self.request(1).json()['episode']['id'])
    def test_existing_sqlite_schema_migration_preserves_foreign_keys(self):
        if is_mysql():self.skipTest('SQLite table migration is SQLite-specific')
        with patch.object(config,'DB_PATH',Path(self.temp.name)/'legacy.sqlite'):
            legacy=SQLITE_SCHEMA.replace('episode_url TEXT NOT NULL,\n    source_generation INTEGER NOT NULL DEFAULT 0,','episode_url TEXT NOT NULL UNIQUE,')
            with connect() as con:
                con.executescript(legacy)
                con.execute("INSERT INTO episodes(id,episode_url,title,slug,created_at,updated_at) VALUES(41,?,'old','old','now','now')",(self.url,))
                con.execute("INSERT INTO jobs(id,job_type,status,episode_id,created_at,updated_at) VALUES(42,'transcribe','queued',41,'now','now')")
            init_db();init_db()
            with connect() as con:
                self.assertEqual(0,con.execute('SELECT source_generation FROM episodes WHERE id=41').fetchone()['source_generation'])
                self.assertEqual(41,con.execute('SELECT episode_id FROM jobs WHERE id=42').fetchone()['episode_id'])
                self.assertEqual([],con.execute('PRAGMA foreign_key_check').fetchall())
                con.execute("INSERT INTO episodes(episode_url,source_generation,title,slug,created_at,updated_at) VALUES(?,1,'new','new','now','now')",(self.url,))
                with self.assertRaises(sqlite3.IntegrityError):
                    con.execute("INSERT INTO episodes(episode_url,source_generation,title,slug,created_at,updated_at) VALUES(?,1,'dup','dup','now','now')",(self.url,))

    def test_generation_schema_is_idempotent_and_unique(self):
        original,_=self.ready();new=self.request(2,force=True).json()['episode']['id']
        self.assertNotEqual(original,new)
        init_db();init_db()
        with tx() as con:
            rows=con.execute('SELECT id,source_generation FROM episodes ORDER BY id').fetchall()
            self.assertEqual([(original,0),(new,1)],[(r['id'],r['source_generation']) for r in rows])
            with self.assertRaises(Exception):
                con.execute('UPDATE episodes SET source_generation=0 WHERE id=?',(new,))

if __name__=='__main__':unittest.main(verbosity=2)
