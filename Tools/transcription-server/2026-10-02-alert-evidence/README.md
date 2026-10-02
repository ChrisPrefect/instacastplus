# Transkriptions-Fehlermails – 2. Oktober 2026

## Ergebnis

Die vorhandenen Betreiber-Mails an `info@instacast.ch` erfassen jetzt zusätzlich
KI-Anmeldeprobleme, Kontingent-/Konfigurations-/Anbieterstörungen und fehlende
Worker. Der bereits vorhandene Monitor ist dauerhaft aktiviert und prüft im
60-Sekunden-Intervall. Der bestehende Cooldown verhindert Wiederholungen derselben
Fehlerart innerhalb von 3600 Sekunden. Fehlgeschlagene Mailübergaben setzen den
Cooldown nicht. Die bisherigen Meldungen für fehlgeschlagene Jobs und Ressourcen
bleiben erhalten; die ressourcenbezogene Prüfung löst keine Anbieterabfragen aus.

Ursache: Der Monitor war deaktiviert; außerdem prüfte `collect_alerts` keine
Provider- oder Worker-Verfügbarkeit. Bereits bei Aufnahme abgewiesene Aufträge
erzeugen keinen fehlgeschlagenen Job und blieben deshalb unsichtbar.
[Beobachtung, Fehlermöglichkeiten und Testgrenze](failure-analysis.md).

## Vorher-/Nachher-Nachweis

Der Test startet den echten Monitorprozess und führt pro Fall drei Messzyklen
aus. Eigene SQLite-Datenbank, kontrollierte Antworten der externen Prozesse und
gespeicherte RFC-Mails machen den Ausfall wiederholbar. Produktionscode übernimmt
Anbieterklassifikation, Prüfung, Datenbank, Cooldown und Mailserialisierung.

Vor der Änderung schlug der Anmeldefehler wie erwartet fehl: **0 statt 1 Mail**.
[Ergebnis](evidence-before/result.json),
[Befehl und Eingaben](evidence-before/authentication/input.json).

Nach der Änderung bestehen **10 Fälle**: Anmeldung, Kontingent, Konfiguration,
Anbietersperre, Worker-Ausfall, fehlgeschlagener Auftrag, gesunder Betrieb,
deaktivierte Mails, fehlgeschlagene erste Mailübergabe und Ressourcenprüfung.
[Ergebnisse](evidence-after-fixtures/result.json). Die Fallverzeichnisse enthalten
Prozesslog, Aufrufe, Eingaben, SQLite-Datenbank und erzeugte `.eml`-Dateien.

Ausgeführter Prüfbefehl auf der isolierten Serverkopie:

```sh
.codex/private/ssh 'sudo -n -H -u instacast /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/var/checks/alerts-20261002/tools/transcription_alert_process_test.py --output /home/instacast/domains/transcript.instacast.ch/var/checks/alerts-20261002/evidence-after-fixtures'
```

Zur Wiederholung ein neues, noch nicht vorhandenes `--output`-Verzeichnis wählen.
Der Test ist auch unter `tools/transcription_alert_process_test.py` installiert.
Er erzeugt keine Produktionsaufträge. Die vorhandenen beiden Fälle in
`tools/resource_alert_regression.py` wurden mit frisch initialisierter eigener
SQLite-Datenbank ausgeführt und bestanden ebenfalls. Keine App-Dateien verändert;
ein App-Build war für diese Serveränderung nicht erforderlich.

## Auslieferung und tatsächliche Zustellung

Nur `app/alerts.py` und der neue Prozess-Test wurden nach exakt passendem
Produktions-Prüfsummenvergleich übertragen. [Patch](server.patch),
[Manifest](deployment-manifest.json), [Auslieferung](deployment-result.json).
Der vorherige Quellstand ist auf dem Server unter
`var/backups/transcription-alerts-20261002` gesichert.

```sh
python3 Tools/transcription-server/2026-10-02-alert-evidence/deploy.py
python3 Tools/transcription-server/2026-10-02-alert-evidence/verify-delivery.py
curl -sS https://transcript.instacast.ch/health
```

Der Deploymentbefehl ist ein Nachweis des ausgeführten Eingriffs und verweigert
erneute Anwendung bei geändertem Ausgangsstand. Der Zustellbefehl sendet eine
ausdrücklich markierte Prüfmail über den produktiven Mailversand; deren Inhalt
stammt aus dem bestandenen Anmeldefehler-Test.

- **13:08:32 Europe/Zurich:** Der echte Monitor meldete den noch vorhandenen
  fehlgeschlagenen Auftrag automatisch. Postfix-Queue `005DF168BBC8`,
  `dsn=2.0.0`, `status=sent`, lokale Zustellung per Procmail bestätigt.
  [Zustelllog](automatic-delivery-result.json).
- **13:08:44 Europe/Zurich:** Die markierte Prüfmail wurde ebenfalls zugestellt,
  Queue `AD286168BBC8`, `dsn=2.0.0`, `status=sent`.
  [Zustelllog](delivery-result.json).
- [Produktionszustand](production-after.json): Monitor enabled/active, keine
  Neustarts oder Mailfehler, neue Ressourcenmessungen, unveränderte Auftragszahlen,
  HTTP 200 mit `ok=true`. API und Worker wurden nicht neu gestartet.

Die Mailstrecke ist damit bis zur lokalen Zustellung geprüft, nicht das Lesen
durch den Empfänger. Der Monitor-Prozess-Test ersetzt keinen vollständigen
iPhone-/Audio-/Import-Durchlauf; dieser ist für die reine Betreiber-Mailänderung
nicht ausgeführt worden.
