"""Deploy verified event notifications; require an unchanged source and idle queue."""
import base64
import json
from pathlib import Path
import shlex
import subprocess

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[2]
SOURCE = ROOT / ".codex/private/server-job-alerts-20261002"
manifest = json.loads((EVIDENCE / "deployment-manifest.json").read_text())
payload = {"manifest": manifest, "baseline": json.loads((EVIDENCE / "baseline-sha256.json").read_text()),
    "files": {name: base64.b64encode((SOURCE / name).read_bytes()).decode() for name in manifest}}
remote = r'''
import base64, hashlib, json, os, pwd, shutil, stat, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
root = Path("/home/instacast/domains/transcript.instacast.ch")
backup = root / "var/backups/transcription-job-alerts-20261002"
payload = json.load(sys.stdin)
assert set(payload["files"]) == {"app/alerts.py", "app/main.py", "app/worker.py", "tools/queue_admission_regression.py", "tools/transcription_alert_process_test.py"}
for name, expected in payload["baseline"].items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, "Production changed: " + name
for name, expected in payload["manifest"].items():
    assert hashlib.sha256(base64.b64decode(payload["files"][name])).hexdigest() == expected["after"]
unit = "transcript-instacast-monitor.service"
assert subprocess.check_output(["systemctl", "show", unit, "-p", "MainPID", "--value"], text=True).strip() == "0"
assert subprocess.run(["systemctl", "is-enabled", unit], capture_output=True, text=True).stdout.strip() == "disabled"
pid = subprocess.check_output(["systemctl", "show", "transcript-instacast-api.service", "-p", "MainPID", "--value"], text=True).strip()
environment = dict(item.decode().split("=", 1) for item in Path(f"/proc/{pid}/environ").read_bytes().split(b"\0") if b"=" in item)
account = pwd.getpwnam("instacast")
def demote():
    os.initgroups(account.pw_name, account.pw_gid)
    os.setgid(account.pw_gid)
    os.setuid(account.pw_uid)
check = "from app.db import connect\nwith connect() as con:\n print(con.execute(\"SELECT COUNT(*) AS n FROM jobs WHERE status IN ('queued','running','paused')\").fetchone()['n'])"
active = int(subprocess.check_output([str(root / ".venv/bin/python"), "-c", check], cwd=root, env=environment, preexec_fn=demote, text=True))
assert active == 0, "Queue is no longer idle"
backup.mkdir(mode=0o700, parents=True, exist_ok=False)
for name in payload["files"]:
    path = root / name
    saved = backup / name
    saved.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, saved)
    metadata = path.stat()
    temporary = path.with_name(path.name + ".job-alerts-20261002.tmp")
    with temporary.open("xb") as handle:
        handle.write(base64.b64decode(payload["files"][name]))
    os.chown(temporary, metadata.st_uid, metadata.st_gid)
    temporary.chmod(stat.S_IMODE(metadata.st_mode))
    temporary.replace(path)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == payload["manifest"][name]["after"]
subprocess.run(["systemctl", "restart", "transcript-instacast-api.service", "transcript-instacast-worker.service"], check=True, capture_output=True)
result = {"time_utc": datetime.now(timezone.utc).isoformat(), "backup": str(backup), "files": payload["manifest"],
    "active_jobs_before_restart": active, "restarted": ["api", "worker"], "monitor": "disabled"}
(backup / "deployment.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
'''
result = subprocess.run([str(ROOT / ".codex/private/ssh"), "sudo -n python3 -c " + shlex.quote(remote)],
    input=json.dumps(payload), capture_output=True, text=True)
if result.returncode:
    raise RuntimeError(result.stderr)
data = json.loads(result.stdout)
(EVIDENCE / "deployment-result.json").write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps(data, indent=2))
