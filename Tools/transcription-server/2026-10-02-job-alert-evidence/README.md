# Fehlermails ohne periodische Prüfungen – 2. Oktober 2026

Der separat aktivierte 60-Sekunden-Monitor ist gestoppt und dauerhaft deaktiviert.
Die Benachrichtigung nutzt jetzt Fehler aus tatsächlichen Auftragsversuchen und
Jobs: abgewiesene Annahme, blockierter Jobstart, Anbieter-/Ressourcenpause,
Retry, endgültiger Fehler und abgelaufener Worker-Claim. Für den Mailversand
erfolgt keine zusätzliche Anbieter-, Kontingent-, Health- oder Modellabfrage.

Ursache der bisherigen Lücke: Der Sammelmonitor war der einzige Mailauslöser;
eine vor Annahme abgewiesene Anfrage legt keinen fehlgeschlagenen Job an. Die
Benachrichtigung gehört daher an den bereits vorhandenen Fehlerpfad.
HTTP-Mails laufen nach der Antwort, Worker-Mails nach dem Datenbank-Commit.
Empfänger bleibt `info@instacast.ch`, Cooldown 3600 Sekunden pro Fehlerart.
Ein Mailversandfehler setzt den Cooldown nicht; der nächste tatsächliche
Fehler kann erneut melden. Es gibt keinen eigenen Retry-Timer für Mails.

## Reproduktion und Grenzen

Vor der Implementierung wurde ein echtes ASGI-POST mit kontrolliertem
Anmeldefehler abgewiesen: HTTP 503, null Jobs, aber **0 statt 1 Mail**.
[Vorher-Ergebnis](evidence-before-result.json). Die isolierte Prüfung ist in der
[vorab geschriebenen Fehleranalyse](failure-analysis.md) begründet.

Die Tests verwenden Python 3.10 und die produktive virtuelle Umgebung auf dem
Linux-Server, echten API-/Worker-Code, eine eigene SQLite-Datenbank pro Fall und
einen separaten Sendmail-Prozess, der RFC-Mails aufzeichnet. Authentifizierung,
externe Providerantworten und Ressourcen werden gezielt kontrolliert. Zusätzliche
Providerabfragen durch die Benachrichtigung würden den Test fehlschlagen lassen.

Eine ergänzende Prüfung zeigte vor der Korrektur drei konkrete Probleme:
fehlender Diagnosewortlaut in API-/Jobmails und eine Ausnahme bei einem leeren
Fehlertext. [Fehlerlog](diagnostics-before.log). Auch diese Prüfungen bestehen
nach der Korrektur, ohne Änderungen am bisherigen Job-/Retryzustand.

**19 Mailfälle bestanden:** Annahmefehler (Anmeldung, Worker, Ressourcen), gesunde
Annahme, leere Queue/Schema-GET, Retry samt konkretem Fehlertext, leere Ausnahme,
terminaler Fehler, Anbieterpause, Plattenfehler, verlorener Claim, normaler
Shutdown, abgelaufener Claim, blockierter Jobstart, Cooldown, deaktivierte Mails,
fehlgeschlagene Mailübergabe, unerwarteter Annahmefehler und ressourcenbezogener
Sammler ohne Providerabfrage. [Ergebnis](evidence-final-result.json),
[Laufprotokoll](tests-final.log), [Beispielmail](authentication-example.eml).

[Testartefakte](test-artifacts.tar.gz) enthalten die Verzeichnisse
`evidence-before`, `evidence-diagnostics-before` und `evidence-final` mit
Eingaben, Antworten, SQLite-Datenbanken, Sendmail-Fixture und erzeugten Mails.
Die Felder in `input.json` dokumentieren die gemeinsame POST-/Provider-Fixture;
Workerfälle verwenden die jeweils benannte Testmethode des ausgelieferten Tests.

```sh
.codex/private/ssh 'sudo -n -H -u instacast /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/var/checks/job-alerts-20261002/tools/transcription_alert_process_test.py --output /home/instacast/domains/transcript.instacast.ch/var/checks/job-alerts-20261002/evidence-final'
.codex/private/ssh 'sudo -n -H -u instacast /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/var/checks/job-alerts-20261002/tools/server_reliability_regression.py ReliabilityTests'
.codex/private/ssh 'sudo -n -H -u instacast /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/var/checks/job-alerts-20261002/tools/admission_latency_regression.py AdmissionLatencyTests'
```

Zur Wiederholung ein neues `--output`-Verzeichnis wählen. Für den ursprünglichen
Fehler wurde `--case test_event_admission_authentication_uses_observed_error`
mit dem unveränderten Produktionscode ausgeführt. Der neue Test ist zusätzlich
unter dem produktiven `tools/transcription_alert_process_test.py` installiert;
auch dort verwendet er ausschließlich eigene Testdaten.

Angrenzend bestanden **51 Zuverlässigkeits-/Lifecyclefälle**, **22 Annahmefälle**
und **2 Ressourcenfälle**; siehe `tests-reliability.log`, `tests-admission.log`
und `tests-resources.log`. Die Ressourcenprüfung lief mit `AdmissionTests.setUp()`
als isolierter Datenbank-Fixture und `resource_alert_regression.main()`.

Dies ist ein HTTP-/Worker-Fehler-bis-Mail-Nachweis, kein vollständiger
iPhone-/Audio-/Import-E2E-Lauf. Es wurden keine Modelle aufgerufen und keine
Produktions-Testjobs angelegt. Die unveränderte reale Mailtransportstrecke wurde
zuvor am selben Tag bis zur lokalen Zustellung geprüft; die jetzigen Fälle
zeichnen Mails auf und versenden keine weiteren Prüfmeldungen an den Empfänger.

## Auslieferung

[Patch](server.patch) und [Manifest](deployment-manifest.json) dokumentieren fünf
Dateien: drei Produktionsmodule, den Ereignistest und dessen gemeinsame
Test-Fixture. Letztere deaktiviert echte Mails für angrenzende Tests; der Mailtest
aktiviert ausschließlich seinen eigenen aufzeichnenden Sender. Der veraltete
Adminhinweis auf Messpunkte alle 60 Sekunden wurde an Messungen während Jobs
angepasst.

```sh
.codex/private/ssh 'sudo -n systemctl disable --now transcript-instacast-monitor.service'
python3 Tools/transcription-server/2026-10-02-job-alert-evidence/deploy.py
python3 Tools/transcription-server/2026-10-02-job-alert-evidence/verify-production.py production-after.json
git diff --check
```

Der Deploymentbefehl verweigert eine Wiederholung bei verändertem Ausgangsstand
oder aktiven Aufträgen. [Auslieferung](deployment-result.json): 13:51:16
Europe/Zurich, Backup `var/backups/transcription-job-alerts-20261002`, API und
Worker bei leerer Queue neu gestartet. Worker 2 bleibt unverändert inaktiv.

[Vorher](production-before.json) und [nachher](production-after.json) bestätigen
identische Jobdaten-Prüfsummen und Zähler (2340 fertig, 78 abgebrochen, 1 früherer
Fehler, keine aktiven Aufträge), passende Quellprüfsummen, API/Worker aktiv ohne
Neustartschleife und Monitor `disabled`/`inactive`/PID 0. Die vorhandene
Bereitschaftsprüfung bei Annahme/Start bleibt erhalten; die leere Workerqueue
löst keine Anbieterprüfung aus. [Öffentliche HTTP-Prüfung](http-after.json):
Schema-Endpunkt antwortet erwartungsgemäß mit 401 ohne Bearer-Token, ohne dabei
den KI-Anbieter zu prüfen.
