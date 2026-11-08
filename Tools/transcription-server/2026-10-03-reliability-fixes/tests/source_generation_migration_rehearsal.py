#!/usr/bin/env python3
"""Rehearse the production MariaDB migration in a disposable database only."""
import argparse
from contextlib import ExitStack
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import uuid
from unittest.mock import patch
import pymysql
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from app import config,db

parser=argparse.ArgumentParser()
parser.add_argument('--baseline-db-module',required=True)
parser.add_argument('--admin-config',default='/etc/webmin/mysql/config')
args=parser.parse_args()
# Load definitions from the verified pre-migration source; no db.env is loaded.
spec=importlib.util.spec_from_file_location('app.source_generation_baseline',args.baseline_db_module)
before=importlib.util.module_from_spec(spec);spec.loader.exec_module(before)
auth=dict(line.split('=',1) for line in Path(args.admin_config).read_text().splitlines() if '=' in line)
name='instacast_generation_migration_'+uuid.uuid4().hex[:12]
admin=pymysql.connect(unix_socket='/run/mysqld/mysqld.sock',user=auth['login'],password=auth['pass'],autocommit=True)
created=False
try:
    with admin.cursor() as cursor:cursor.execute(f'CREATE DATABASE `{name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
    created=True
    with tempfile.TemporaryDirectory() as temp,ExitStack() as contexts:
        for key,value in dict(DB_BACKEND='mysql',MYSQL_DATABASE=name,MYSQL_USER=auth['login'],MYSQL_PASSWORD=auth['pass'],MYSQL_UNIX_SOCKET='/run/mysqld/mysqld.sock',VAR_DIR=Path(temp)/'var',STORAGE_DIR=Path(temp)/'storage').items():contexts.enter_context(patch.object(config,key,value))
        before.init_db()
        with db.connect() as con:
            assert con.execute('SELECT DATABASE() name').fetchone()['name']==name
            con.execute("INSERT INTO episodes(id,episode_url,title,slug,created_at,updated_at,audio_sha256,status) VALUES(41,'https://example.org/migration.wav','Original','original','now','now',?,'ready')",('a'*64,))
            con.execute("INSERT INTO jobs(id,job_type,status,episode_id,created_at,updated_at) VALUES(42,'transcribe','done',41,'now','now')")
            con.execute("INSERT INTO transcription_requests(client_hash,request_id,episode_id,state,audio_source,audio_sha256,created_at,updated_at) VALUES(?,'original-uuid',41,'active','server',?,'now','now')",('b'*64,'a'*64))
            before.ensure_state_columns(con)
            preserved={table:[dict(row) for row in con.execute('SELECT * FROM '+table).fetchall()] for table in ['episodes','jobs','transcription_requests']}
            indexes=[row['Key_name'] for row in con.execute('SHOW INDEX FROM episodes').fetchall()]
            assert 'uniq_episodes_full_url' in indexes
            try:con.execute("INSERT INTO episodes(episode_url,title,slug,created_at,updated_at) VALUES('https://example.org/migration.wav','Duplicate','duplicate','now','now')")
            except pymysql.err.IntegrityError:pass
            else:raise AssertionError('Baseline did not enforce single URL')
        print(json.dumps({'phase':'before','rows':{k:len(v) for k,v in preserved.items()},'unique_full_url':True}),flush=True)
        db.init_db();db.init_db()
        with db.connect() as con:
            for table,rows in preserved.items():
                current=[dict(row) for row in con.execute('SELECT * FROM '+table).fetchall()]
                if table=='episodes':
                    assert all(row.pop('source_generation')==0 for row in current)
                assert rows==current,(table,'existing values changed')
            con.execute("INSERT INTO episodes(episode_url,source_generation,title,slug,created_at,updated_at) VALUES('https://example.org/migration.wav',1,'Version B','version-b','now','now')")
            try:con.execute("INSERT INTO episodes(episode_url,source_generation,title,slug,created_at,updated_at) VALUES('https://example.org/migration.wav',1,'Duplicate B','duplicate-b','now','now')")
            except pymysql.err.IntegrityError:pass
            else:raise AssertionError('Same generation duplicate accepted')
            assert con.execute('SELECT episode_id FROM jobs WHERE id=42').fetchone()['episode_id']==41
            assert con.execute("SELECT episode_id FROM transcription_requests WHERE request_id='original-uuid'").fetchone()['episode_id']==41
        db.init_db()
        print(json.dumps({'phase':'after','existing_rows_unchanged':True,'old_generation':0,'new_generation':1,'duplicate_generation_rejected':True,'idempotent':True}),flush=True)
finally:
    if created:
        with admin.cursor() as cursor:cursor.execute(f'DROP DATABASE `{name}`')
        print(json.dumps({'temporary_database_removed':True}),flush=True)
    admin.close()
