# Fehlermails aus tatsächlichen Aufträgen

Vorgabe vom 2. Oktober 2026: kein periodischer Mail-/Anbieter-Monitor. Prüfungen
gehören zur tatsächlichen Auftragsannahme bzw. zum Jobstart; gemeldet werden die
dort oder während der Verarbeitung bereits aufgetretenen Fehler.

Der Monitor wurde sofort mit `systemctl disable --now
transcript-instacast-monitor.service` gestoppt. Der vorhandene Worker bleibt für
die Abarbeitung von Aufträgen aktiv. `claim_job` prüft die Anbieterbereitschaft
bereits nur, wenn tatsächlich ein fälliger Transkriptionsauftrag wartet.

Vor Änderungen zu prüfende Fehlerfälle:

- Ein tatsächliches POST wird wegen Anmeldung/Kontingent/Worker/Ressourcen
  abgewiesen: die bereits ermittelte Fehlerantwort löst eine Mail aus.
- Ein laufender Job scheitert oder wird wegen Anbieter-/Ressourcenfehlern
  zurückgestellt: die Mail enthält Job-/Episodenbezug und den tatsächlichen Fehler.
- Ein abgelaufener Worker-Claim wird als Fehler behandelt und gemeldet.
- Ein normaler Shutdown, ein abgebrochener oder überholter Claim, gesunde Anfragen,
  Status-GETs und eine leere Queue lösen keine Mail oder zusätzliche
  Anbieterprüfung für den Mailversand aus.
- Cooldown und ausgeschaltete Benachrichtigungen werden eingehalten; eine
  fehlgeschlagene Mailübergabe verändert den Job-/HTTP-Fehler nicht.

Der Regressionstest verwendet den echten HTTP-ASGI-Pfad sowie die tatsächlichen
Worker-Zustandsübergänge mit eigener Datenbank und einem aufzeichnenden
Sendmail-Prozess. Nur externe Anbieterantworten und Ressourcen werden gezielt
gesetzt. So lassen sich Fehler und verlorene Claims zuverlässig prüfen, ohne
Produktionszugänge zu widerrufen oder echte Nutzeraufträge zu beschädigen.
Ein vollständiger Audio-/iPhone-E2E-Lauf kann diese Fehler nicht reproduzierbar
auslösen und würde unnötige Verarbeitung verursachen. Die Prüfungen bleiben
ausdrücklich auf HTTP/Worker-Fehler bis zur erzeugten Mail begrenzt.

Die Fehlermail muss den tatsächlichen Diagnosewortlaut behalten (öffentliche
Clientmeldungen allein sind dafür zu allgemein). Python-Ausnahmen wie
`TimeoutError()` können einen leeren Text haben; auch dann muss der bestehende
Jobübergang erhalten bleiben und die Mail erzeugt werden. Diese Fälle werden
vor der entsprechenden Korrektur mit den echten Fehlerpfaden geprüft.
