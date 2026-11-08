"""Run as root on the server, with its db.env loaded, after isolated tests pass."""
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
manifest = json.loads((staged / 'server-source-manifest.json').read_text())
backup = root / 'var/backups/server-source-20261003'
assert os.geteuid() == 0 and not backup.exists()
sys.path.insert(0, str(root))
from app import config, db
assert config.DB_BACKEND == 'mysql'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

for entry in manifest['files']:
    assert sha(root / entry['path']) == entry['before_sha256'], 'Live source changed: ' + entry['path']
    assert sha(staged / entry['path']) == entry['after_sha256'], 'Staging mismatch: ' + entry['path']
with db.connect() as con:
    assert con.execute("SELECT COUNT(*) AS n FROM jobs WHERE status IN ('queued','running')").fetchone()['n'] == 0

backup.mkdir(mode=0o700)
shutil.copy2(staged / 'server-source-manifest.json', backup / 'manifest.json')
services = ['transcript-instacast-api.service', 'transcript-instacast-worker.service']
subprocess.run(['systemctl', 'stop', *services], check=True)
copied = []
try:
    with db.connect() as con:
        jobs_before = [dict(row) for row in con.execute('SELECT id,status,episode_id FROM jobs ORDER BY id').fetchall()]
        assert not any(row['status'] == 'running' for row in jobs_before)
    (backup / 'jobs-before.json').write_text(json.dumps(jobs_before))
    # Use the configured database account, never put its password in argv/logs.
    with tempfile.NamedTemporaryFile(mode='w', prefix='instacast-backup-', suffix='.cnf') as credentials:
        values = {'user':config.MYSQL_USER, 'password':config.MYSQL_PASSWORD,
                  'host':config.MYSQL_HOST, 'port':config.MYSQL_PORT}
        if config.MYSQL_UNIX_SOCKET:
            values['socket'] = config.MYSQL_UNIX_SOCKET
        credentials.write('[client]\n')
        for key, value in values.items():
            escaped = str(value).replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
            credentials.write(f'{key}="{escaped}"\n')
        credentials.flush()
        with gzip.open(backup / 'database.sql.gz', 'wb') as destination:
            dump = subprocess.Popen(['mariadb-dump', '--defaults-extra-file='+credentials.name,
                                     '--single-transaction', '--no-tablespaces', '--databases', config.MYSQL_DATABASE], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            shutil.copyfileobj(dump.stdout, destination)
            _, error = dump.communicate()
            if dump.returncode:
                (backup / 'backup-error.txt').write_bytes(error)
                raise RuntimeError('Database backup failed; no source changed')
    owner = (root / 'app/main.py').stat()
    with db.connect() as con:
        db.ensure_column(con, 'transcription_requests', 'audio_source', "VARCHAR(16) NOT NULL DEFAULT 'client'")
    for entry in manifest['files']:
        source, target = staged / entry['path'], root / entry['path']
        assert sha(target) == entry['before_sha256'], 'Live file changed during deployment'
        saved = backup / 'source' / entry['path']
        if target.exists():
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, saved)
        temporary = target.with_name('.' + target.name + '.server-source-update')
        shutil.copy2(source, temporary)
        os.chown(temporary, owner.st_uid, owner.st_gid)
        temporary.replace(target)
        copied.append(entry)
        assert sha(target) == entry['after_sha256']
    with db.connect() as con:
        jobs_after = [dict(row) for row in con.execute('SELECT id,status,episode_id FROM jobs ORDER BY id').fetchall()]
        assert jobs_before == jobs_after, 'Job states changed unexpectedly'
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
          'migration': "transcription_requests.audio_source VARCHAR(16) NOT NULL DEFAULT 'client'", 'job_states_unchanged': True}
(backup / 'result.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result))
