"""Read service, source and queue state without querying any AI provider."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[2]
probe = r'''
import hashlib, json
from app.db import connect
from app.settings import get_alert_settings, get_setting
with connect() as con:
    counts = [dict(row) for row in con.execute("SELECT status, COUNT(*) AS count FROM jobs GROUP BY status").fetchall()]
    rows = [dict(row) for row in con.execute("SELECT id,status,attempts,locked_by,claim_token,error,updated_at FROM jobs ORDER BY id").fetchall()]
print(json.dumps({"job_counts": counts, "jobs_sha256": hashlib.sha256(json.dumps(rows,sort_keys=True,default=str).encode()).hexdigest(),
    "alert_settings": get_alert_settings(), "last_mail_error": get_setting("alert_last_error", "")}))
'''
remote = f'''
import hashlib, json, os, pwd, subprocess
from datetime import datetime, timezone
from pathlib import Path
root = Path("/home/instacast/domains/transcript.instacast.ch")
services = {{}}
for name in ["api", "worker", "worker-2", "monitor"]:
    unit = "transcript-instacast-" + name + ".service"
    values = subprocess.check_output(["systemctl", "show", unit, "-p", "ActiveState", "-p", "SubState", "-p", "MainPID", "-p", "NRestarts", "-p", "UnitFileState"], text=True)
    services[name] = dict(line.split("=", 1) for line in values.splitlines())
pid = services["api"]["MainPID"]
environment = dict(item.decode().split("=", 1) for item in Path(f"/proc/{{pid}}/environ").read_bytes().split(b"\\0") if b"=" in item)
files = ["app/alerts.py", "app/main.py", "app/worker.py", "tools/queue_admission_regression.py", "tools/transcription_alert_process_test.py"]
hashes = {{name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files}}
account = pwd.getpwnam("instacast")
os.initgroups(account.pw_name, account.pw_gid)
os.setgid(account.pw_gid)
os.setuid(account.pw_uid)
os.chdir(root)
data = json.loads(subprocess.check_output([str(root / ".venv/bin/python"), "-c", {probe!r}], env=environment, text=True))
print(json.dumps({{"time_utc": datetime.now(timezone.utc).isoformat(), "services": services, "sha256": hashes, "data": data}}))
'''
result = subprocess.run([str(ROOT / ".codex/private/ssh"), "sudo -n python3 -c " + shlex.quote(remote)],
    capture_output=True, text=True, check=True)
data = json.loads(result.stdout)
output = EVIDENCE / sys.argv[1]
output.write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps(data, indent=2))
