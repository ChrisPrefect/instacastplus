# Transkriptions-Fehlermails, 2. Oktober 2026

## Beobachtung und Ursache

Der produktive Mail-Monitor `transcript-instacast-monitor.service` ist deaktiviert
und läuft nicht. Mail-Alerts sind in der Datenbank eingeschaltet, Empfänger ist
`info@instacast.ch`, Cooldown 3600 Sekunden. `app.monitor.main` ist der vorhandene
Aufrufer von `send_operational_alerts`. Dessen Sammler prüft Ressourcen, Queue,
fehlgeschlagene Jobs und API-Budget, aber weder die tatsächliche
KI-Anbieterverfügbarkeit noch den Workerzustand. Ein abgewiesener Auftrag wegen
fehlender KI-Anmeldung erzeugt keinen fehlgeschlagenen Job und damit keine Mail.

## Fehlerfälle vor der Implementierung

- Fehlende oder widerrufene Anmeldung, ausgeschöpftes Kontingent, ungültige
  Anbieter-Konfiguration und während der Verarbeitung beobachtete Anbietersperren
  müssen auch bei leerer Queue eine verständliche Betreiber-Mail erzeugen.
- Ohne laufenden konfigurierten Worker muss eine Mail ausgelöst werden; ein
  absichtlich inaktiver zweiter Worker bei laufendem erstem ist kein Fehler.
- Bestehende Meldungen für fehlgeschlagene Verarbeitung müssen weiterhin kommen.
- Gesunder Betrieb und abgeschaltete Mail-Alerts dürfen keine Mail auslösen.
- Wiederholte Monitorzyklen dürfen während des bestehenden Cooldowns keine
  Duplikate schicken; fehlgeschlagene Mailübergaben dürfen keinen Erfolg speichern.
- Der ressourcenbezogene Aufruf im Verarbeitungspfad darf keine zusätzliche
  Anbieterprüfung oder Anbieter-Mail auslösen.

## Nachweisgrenze

Der automatisierte Prozess-Test startet den echten `app.monitor.main` mit eigener
SQLite-Datenbank. Nur externe Prozesse (`codex`, `systemctl`, `sendmail`) liefern
kontrollierte Fehlerantworten beziehungsweise speichern die erzeugten RFC-Mails.
Sammler, Anbieterklassifikation, Datenbank, Cooldown und Mailserialisierung sind
Produktionscode. Das ermöglicht wiederholbare Ausfälle, ohne die wiederhergestellte
Produktionsanmeldung zu widerrufen, Worker anzuhalten oder Testaufträge in die
Produktionsqueue zu schreiben. Erhalten bleiben Eingaben, Befehle, Prozesslogs,
Datenbank und `.eml`-Dateien. Dies ist ein durchgängiger Monitor-Test, kein
vollständiger iPhone/Audio/Import-E2E-Test.

Zusätzlich wird nach der Bereitstellung der echte Monitor mit dem noch vorhandenen
fehlgeschlagenen Auftrag geprüft. Eine ausdrücklich markierte Prüfmail mit dem
Inhalt des simulierten Anmeldefehlers prüft den produktiven Mailversand separat.
Die Zustellungen werden im Mailserver-Log nachgewiesen. Produktionsdienste werden
dafür nicht in einen Fehlerzustand versetzt und Produktionsaufträge nicht verändert.
