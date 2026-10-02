"""Deploy the two verified files after an exact production-baseline check."""
import base64
import json
from pathlib import Path
import shlex
import subprocess

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[2]
SOURCE = ROOT / ".codex/private/server-alerts-20261002"
manifest = json.loads((EVIDENCE / "deployment-manifest.json").read_text())
payload = {"manifest": manifest, "files": {
    name: base64.b64encode((SOURCE / name).read_bytes()).decode() for name in manifest}}
remote = r'''
import base64, hashlib, json, os, shutil, stat, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
root = Path("/home/instacast/domains/transcript.instacast.ch")
backup = root / "var/backups/transcription-alerts-20261002"
payload = json.load(sys.stdin)
assert set(payload["files"]) == {"app/alerts.py", "tools/transcription_alert_process_test.py"}
for name, expected in payload["manifest"].items():
    path = root / name
    actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
    assert actual == expected["before"], "Production changed: " + name
    assert hashlib.sha256(base64.b64decode(payload["files"][name])).hexdigest() == expected["after"]
backup.mkdir(mode=0o700, parents=True, exist_ok=False)
unit = "transcript-instacast-monitor.service"
before = subprocess.run(["systemctl", "is-enabled", unit], capture_output=True, text=True).stdout.strip()
for name in payload["files"]:
    path = root / name
    if path.exists():
        saved = backup / name
        saved.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, saved)
    metadata = path.stat() if path.exists() else (root / "app/alerts.py").stat()
    temporary = path.with_name(path.name + ".alerts-20261002.tmp")
    with temporary.open("xb") as handle:
        handle.write(base64.b64decode(payload["files"][name]))
    os.chown(temporary, metadata.st_uid, metadata.st_gid)
    temporary.chmod(stat.S_IMODE(metadata.st_mode))
    temporary.replace(path)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == payload["manifest"][name]["after"]
subprocess.run(["systemctl", "enable", "--now", unit], check=True, capture_output=True)
result = {"time_utc": datetime.now(timezone.utc).isoformat(), "backup": str(backup),
    "files": payload["manifest"], "monitor_enabled_before": before,
    "monitor_enabled_after": subprocess.check_output(["systemctl", "is-enabled", unit], text=True).strip(),
    "monitor_state": subprocess.check_output(["systemctl", "show", unit, "-p", "ActiveState", "-p", "SubState", "-p", "MainPID"], text=True),
    "api_or_worker_restarted": False}
(backup / "deployment.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
'''
result = subprocess.run([str(ROOT / ".codex/private/ssh"), "sudo -n python3 -c " + shlex.quote(remote)],
    input=json.dumps(payload), capture_output=True, text=True, check=True)
data = json.loads(result.stdout)
(EVIDENCE / "deployment-result.json").write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps(data, indent=2))
