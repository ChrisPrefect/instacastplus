"""Deploy the reviewed manifest with services quiescent and a complete DB backup.

Run as root on the production host, with its db.env loaded. The staging directory
must contain server-reliability-manifest.json and every declared file.
"""
from pathlib import Path
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

root = Path('/home/instacast/domains/transcript.instacast.ch')
staged = Path(sys.argv[1]).resolve()
manifest = json.loads((staged / 'server-reliability-manifest.json').read_text())
backup = root / 'var/backups/transcription-reliability-20261003'
assert os.geteuid() == 0 and not backup.exists()
sys.path.insert(0, str(root))
from app import config, db
assert config.DB_BACKEND == 'mysql'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

def snapshot():
    with db.connect() as con:
        return {table: [dict(row) for row in con.execute(query).fetchall()] for table, query in {
            'episodes': 'SELECT id,episode_url,status,audio_sha256 FROM episodes ORDER BY id',
            'jobs': 'SELECT id,status,episode_id FROM jobs ORDER BY id',
            'requests': 'SELECT client_hash,request_id,episode_id,state,audio_sha256,audio_source FROM transcription_requests ORDER BY client_hash,request_id',
            'artifacts': 'SELECT id,episode_id,kind,path FROM artifacts ORDER BY id',
        }.items()}

def assert_idle():
    with db.connect() as con:
        assert con.execute("SELECT COUNT(*) AS n FROM jobs WHERE status IN ('queued','running')").fetchone()['n'] == 0, 'Active jobs; no deployment performed'

for entry in manifest['files']:
    assert sha(root / entry['path']) == entry['before_sha256'], 'Live source changed: ' + entry['path']
    assert sha(staged / entry['path']) == entry['after_sha256'], 'Staging mismatch: ' + entry['path']
assert_idle()
assert subprocess.run(['systemctl','is-active','--quiet','transcript-instacast-worker-2.service']).returncode != 0
backup.mkdir(mode=0o700)
shutil.copy2(staged / 'server-reliability-manifest.json', backup / 'manifest.json')
services = ['transcript-instacast-api.service', 'transcript-instacast-worker.service']
copied = []
owner = (root / 'app/main.py').stat()
try:
    subprocess.run(['systemctl', 'stop', services[0]], check=True)
    assert_idle()
    subprocess.run(['systemctl', 'stop', services[1]], check=True)
    assert_idle()
    before = snapshot()
    (backup / 'state-before.json').write_text(json.dumps(before))
    with tempfile.NamedTemporaryFile(mode='w', prefix='instacast-backup-', suffix='.cnf') as credentials:
        values = {'user': config.MYSQL_USER, 'password': config.MYSQL_PASSWORD,
                  'host': config.MYSQL_HOST, 'port': config.MYSQL_PORT}
        if config.MYSQL_UNIX_SOCKET:
            values['socket'] = config.MYSQL_UNIX_SOCKET
        credentials.write('[client]\n')
        for key, value in values.items():
            escaped = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
            credentials.write(f'{key}="{escaped}"\n')
        credentials.flush()
        with gzip.open(backup / 'database.sql.gz', 'wb') as destination:
            dump = subprocess.Popen(['mariadb-dump', '--defaults-extra-file=' + credentials.name,
                                     '--single-transaction', '--no-tablespaces', '--databases', config.MYSQL_DATABASE], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            shutil.copyfileobj(dump.stdout, destination)
            _, error = dump.communicate()
            if dump.returncode:
                (backup / 'backup-error.txt').write_bytes(error)
                raise RuntimeError('Database backup failed; no source changed')
    for entry in manifest['files']:
        source, target = staged / entry['path'], root / entry['path']
        assert sha(target) == entry['before_sha256'], 'Live file changed during deployment'
        saved = backup / 'source' / entry['path']
        if target.exists():
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, saved)
        temporary = target.with_name('.' + target.name + '.reliability-update')
        shutil.copy2(source, temporary)
        os.chown(temporary, owner.st_uid, owner.st_gid)
        temporary.replace(target)
        copied.append(entry)
        assert sha(target) == entry['after_sha256']
    # A fresh process must load the new schema code, not this script's backup imports.
    subprocess.run([str(root / '.venv/bin/python'), '-B', '-c', 'from app.db import init_db; init_db()'], cwd=root, check=True)
    assert before == snapshot(), 'Existing episode, request, job or artifact identity changed'
    with db.connect() as con:
        assert con.execute('SELECT COUNT(*) AS n FROM episodes WHERE source_generation<>0').fetchone()['n'] == 0
        assert con.execute("SHOW INDEX FROM episodes WHERE Key_name='uniq_episodes_source_generation'").fetchone()
        assert not con.execute("SHOW INDEX FROM episodes WHERE Key_name='uniq_episodes_full_url'").fetchone()
except Exception:
    for entry in reversed(copied):
        target = root / entry['path']
        saved = backup / 'source' / entry['path']
        if saved.exists():
            shutil.copy2(saved, target)
            os.chown(target, owner.st_uid, owner.st_gid)
        else:
            target.unlink()
    raise
finally:
    subprocess.run(['systemctl', 'start', *services], check=True)
result = {'deployed': True, 'backup': str(backup), 'files_verified': len(copied),
          'existing_identity_and_states_unchanged': True,
          'migration': 'episodes.source_generation; unique(full URL hash, source_generation)',
          'counts': {table: len(rows) for table, rows in before.items()}}
(backup / 'result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
