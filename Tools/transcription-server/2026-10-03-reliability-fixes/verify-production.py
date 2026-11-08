"""Read-only verification; run with the production db.env and virtualenv."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import uuid
import requests

root = Path('/home/instacast/domains/transcript.instacast.ch')
sys.path.insert(0, str(root))
from app import config, db

assert config.DB_BACKEND == 'mysql'
manifest = json.loads((root / 'var/backups/transcription-reliability-20261003/manifest.json').read_text())
for entry in manifest['files']:
    assert hashlib.sha256((root / entry['path']).read_bytes()).hexdigest() == entry['after_sha256'], entry['path']
headers = {'Authorization': 'Bearer ' + (root / 'var/app/client-api-token.txt').read_text().strip(),
           'Accept': 'application/json', 'X-Instacast-Client-ID': str(uuid.uuid4()),
           'X-Instacast-App-Version': '4.0', 'X-Instacast-Platform': 'iOS'}
base = 'https://transcript.instacast.ch'
health = requests.get(base + '/health', timeout=30)
schema = requests.get(base + '/api/v1/schema', headers=headers, timeout=30)
assert health.status_code == 200 and health.json()['ok'], health.status_code
assert schema.status_code == 200, schema.status_code
assert config.ALLOW_API_FORCE is False
schema_data = schema.json()
assert schema_data['schema_revision'] == '2026-10-03.2'
assert schema_data['schemas']['SubmitEpisodeRequest']['properties']['audio_source']['enum'] == ['client', 'server']
assert 'audio_source' in schema_data['schemas']['ClientRequestReceipt']['required']
existing = requests.get(base + '/api/v1/episodes/30', headers=headers, timeout=30)
assert existing.status_code == 200, existing.status_code
with db.connect() as con:
    modes = [dict(row) for row in con.execute('SELECT audio_source,COUNT(*) AS n FROM transcription_requests GROUP BY audio_source').fetchall()]
    jobs = [dict(row) for row in con.execute('SELECT id,status,episode_id FROM jobs ORDER BY id').fetchall()]
    generations = [dict(row) for row in con.execute('SELECT source_generation,COUNT(*) AS n FROM episodes GROUP BY source_generation').fetchall()]
    indexes = [dict(row) for row in con.execute("SHOW INDEX FROM episodes WHERE Key_name='uniq_episodes_source_generation'").fetchall()]
    assert len(indexes) == 2 and {r['Column_name'] for r in indexes} == {'episode_url_sha256','source_generation'}
before = json.loads((root / 'var/backups/transcription-reliability-20261003/state-before.json').read_text())['jobs']
assert jobs == before, 'Unexpected production job state change'
units = {}
for service in ['transcript-instacast-api.service', 'transcript-instacast-worker.service', 'transcript-instacast-worker-2.service']:
    units[service] = subprocess.run(['systemctl', 'is-active', service], capture_output=True, text=True).stdout.strip()
assert units['transcript-instacast-api.service'] == units['transcript-instacast-worker.service'] == 'active'
print(json.dumps({'checked_at': datetime.now(timezone.utc).isoformat(), 'files_verified': len(manifest['files']),
                  'health_http_status': health.status_code, 'health': health.json(), 'schema_revision': schema_data['schema_revision'],
                  'request_source_modes': modes, 'source_generations': generations, 'allow_api_force': config.ALLOW_API_FORCE, 'job_states_unchanged': True, 'production_test_jobs_created': False,
                  'existing_episode_status': existing.json()['episode']['status'], 'units': units}, indent=2))
