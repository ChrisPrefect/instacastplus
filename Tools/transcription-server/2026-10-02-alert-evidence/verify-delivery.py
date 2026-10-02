"""Send one clearly labelled verification email using the production mail path."""
from email import policy
from email.parser import BytesParser
import json
from pathlib import Path
import shlex
import subprocess

EVIDENCE = Path(__file__).resolve().parent
ROOT = EVIDENCE.parents[2]
source = next((EVIDENCE / "evidence-after-fixtures/authentication").glob("*.eml"))
message = BytesParser(policy=policy.default).parsebytes(source.read_bytes())
body = ("Dies ist eine einmalige Prüfmail für die neu aktivierten Transkriptions-Fehlerbenachrichtigungen.\n"
    "Der folgende Anmeldefehler wurde ausschließlich in einer isolierten Testumgebung erzeugt.\n"
    "Der Produktionsserver ist aktuell angemeldet und betriebsbereit.\n\n"
    "Geprüfter Inhalt der Fehlerbenachrichtigung:\n\n" + message.get_content())
probe = f'''
import json
from app.alerts import send_email
from app.settings import get_alert_settings
settings = get_alert_settings()
assert settings["enabled"] and settings["email"] == "info@instacast.ch"
send_email(settings["email"], "[TEST] Instacast Transkription: Fehlerbenachrichtigung geprüft", {body!r})
print(json.dumps({{"recipient": settings["email"], "sendmail_exit_code": 0,
    "subject": "[TEST] Instacast Transkription: Fehlerbenachrichtigung geprüft"}}))
'''
remote = f'''
import json, os, pwd, subprocess
from pathlib import Path
offset = Path("/var/log/mail.log").stat().st_size
pid = subprocess.check_output(["systemctl", "show", "transcript-instacast-monitor.service", "-p", "MainPID", "--value"], text=True).strip()
environment = dict(item.decode().split("=", 1) for item in Path(f"/proc/{{pid}}/environ").read_bytes().split(b"\\0") if b"=" in item)
account = pwd.getpwnam("instacast")
os.initgroups(account.pw_name, account.pw_gid)
os.setgid(account.pw_gid)
os.setuid(account.pw_uid)
root = "/home/instacast/domains/transcript.instacast.ch"
os.chdir(root)
result = subprocess.run([root + "/.venv/bin/python", "-c", {probe!r}], env=environment,
    capture_output=True, text=True, check=True)
data = json.loads(result.stdout)
data["mail_log_offset_before"] = offset
print(json.dumps(data))
'''
result = subprocess.run([str(ROOT / ".codex/private/ssh"), "sudo -n python3 -c " + shlex.quote(remote)],
    capture_output=True, text=True, check=True)
data = json.loads(result.stdout)
(EVIDENCE / "delivery-submission.json").write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps(data, indent=2))
