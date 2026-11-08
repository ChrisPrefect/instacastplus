# Weitere Zuverlässigkeitslücken – 3. Oktober 2026

**Nachtrag:** Die folgenden Befunde wurden anschließend korrigiert. App-/Serverprüfungen und produktive Serverauslieferung stehen im [Korrekturbericht](../2026-10-03-reliability-fixes/README.md). Der ursprüngliche Befundstand bleibt unten als Vorher-Nachweis erhalten.

Zusätzliche Prüfung auf die Nutzerfrage nach weiteren Fehlannahmen. Dies ist ein
Befundbericht, keine Behauptung, dass die folgenden Produktfehler bereits behoben
sind. Sieben Fehlerbilder wurden mit tatsächlichen Produktionsmethoden
reproduziert; zwei weitere sind durch die konkurrierenden Codepfade belegt und
benötigen noch einen tatsächlichen App-E2E-Nachweis.

Der frische Live-Abgleich um 13:40 Uhr Schweizer Zeit bestätigt alle 17
Server-Quelldateien gegen `.codex/private/server-source-20261003`, Schema
`2026-10-03.1`, gesunde API/Worker und keine laufenden/wartenden Jobs. Separat wurde
die produktive Einstellung `ALLOW_API_FORCE=False` gelesen. Es wurden keine
Produktionsaufträge erzeugt oder verändert. Beleg: `live-server.json`.

## Durch ausgeführte Produktionsmethoden reproduziert

1. **P1: Ergebnisabruf verlangt nach Cache-Löschung wieder Geräteaudio.**
   Ein beim Start vollständig gecachter Download erzeugt einen `client`-Auftrag.
   Wird die Datei nach Annahme gelöscht, verweigert `verifiedImportAudio`
   (`Classes/ServerTranscriptionManager.swift:1655`) den fertigen Text mit Fehler
   55. Gespeicherter Start-SHA und Ergebnis-SHA sind identisch; trotzdem werden
   keine Artefakte abgerufen. Die aktuelle Geräteaudio darf das Lesen nicht
   blockieren; ihre Identität ist für Zeitsprünge separat zu prüfen.
   Beleg: `app-boundaries/evidence/result.json`, zweiter Fall.

2. **P1: Gespeicherter wartender Auftrag wird nach Neustart aufgegeben.**
   `loadPersistedQueue` (`Classes/ServerTranscriptionManager.swift:2112`) setzt
   jeden verbliebenen `.pending`-Auftrag auf rejected/failed. Die Probe hält den
   ersten POST, speichert einen zweiten URL-only-Auftrag fehlerfrei und lädt die
   Queue neu. Die UUID bleibt erhalten, aber der zweite Auftrag wird nicht mehr
   automatisch gesendet. „Noch nicht gesendet“ wurde mit „nicht weiterführen“
   gleichgesetzt. Beleg: `app-boundaries/evidence/result.json`, erster Fall.

3. **P1: Ein Audio-Teilbereich wird als vollständige Quelle akzeptiert.**
   `app/worker.py:646` und `:711`: Die echte HTTP-Probe liefert
   `Content-Range: bytes 0-32043/64044`. Der Worker speichert 32044 Bytes als
   vollständig; der echte Decoder erkennt 1 statt 2 Sekunden. Vollständige
   HTTP-200- und HTTP-206-Kontrollen liefern 2 Sekunden. Ein erfolgreich
   decodierbarer Ausschnitt kann dadurch Grundlage einer unvollständigen
   Transkription werden. Keine ASR-Inferenz wurde ausgeführt.
   Beleg: `backend-probe.log`, `http_download`.

4. **P1: Neue Audioversion an gleicher URL lässt sich nicht neu beauftragen.**
   `app/main.py:1573`, `app/service.py:279`: Bei bereits vorhandenem Ergebnis A
   liefert eine neue Server-UUID auch mit `force=true` weiter A. Eine neue
   Client-UUID mit anderem Start-SHA B erhält auch mit `force=true` HTTP 409.
   Es entstehen jeweils null neue Jobs. Der Quellenvergleich verhindert falsche
   Zeitmarken, bietet dem betroffenen Nutzer aber keinen funktionierenden
   erneuten Versuch für seine Audioversion.
   Beleg: `backend-probe.log`, `ready_reuse_or_retry`.

5. **P2: Beschädigtes fertiges Ergebnis lässt sich über den App-Retry nicht reparieren.**
   `app/service.py:1006`, `app/main.py:1572` und
   `Classes/ServerTranscriptionManager.swift:745`: Ein fehlendes SRT wird nach
   außen als failed/retryable gemeldet, intern bleibt die Episode ready. Die App
   sendet neue UUID plus force; mit der produktiven Einstellung antwortet der
   Server HTTP 403, ohne einen Reparaturjob anzulegen. Der vorhandene gesonderte
   Retry-Endpunkt wird von diesem App-Pfad nicht verwendet.
   Beleg: `backend-probe.log`, `broken_artifact_advertised_error` und folgender POST.

6. **P2: Worker-Neustart ignoriert vorhandene Originalaudio an einer Checkpoint-Grenze.**
   `app/worker.py:6881–6905` und `:6733`: Der Quellhash wird vor Dauerprüfung und
   Audio-Checkpoint gebunden. Kontrollierter Workerabbruch in dieser Lücke,
   Lease-Ablauf und neuer Claim führen zu einem zweiten Download, obwohl die
   ursprüngliche Datei noch existiert. Hat sich die Quelle geändert, endet der
   Auftrag mit audio_mismatch. Die Probe bestätigt Originaldatei vorhanden,
   Checkpoint fehlend, zwei GETs und terminalen Requestzustand.
   Beleg: `backend-probe.log`, `source_crash_*`.

7. **P2: Reine lokale Kapitel bleiben trotz passender Audioquelle gesperrt.**
   `Classes/ChapterGenerator.swift:140`, `:6146`, `:6665` und
   `Classes/PlaybackManager.m:4254`: Der lokale Kapitelpfad speichert eine
   Kapiteldatei ohne Quellhash/Transkriptrevision; die spätere Freigabe erwartet
   diese Informationen ausschließlich in einer Analyse-Datei. Echtes Speichern,
   Laden und Hashen ergeben bei passenden Bytes chaptersVerified=false und
   transcriptVerified=true – direkt und nach einem frischen Generator.
   Beleg: `local-chapter-probe.log`. Kein App-E2E des lokalen Modellpfads.

## Konkrete Codebefunde; noch kein App-E2E dieser Kombination

8. **P1: Lokale und Serverarbeit können gleichzeitig dieselben Dateien besitzen.**
   Beide Aufnahmen prüfen nur ihre eigene Queue
   (`ServerTranscriptionManager.swift:629`, `TranscriptionQueue.swift:784`);
   `admitQueueItem` prüft Kapazität, keinen gemeinsamen Episodenbesitz. Beide
   Menüaktionen sind erreichbar (`EpisodeViewController.m:1435–1463`). Beide
   Abschlusswege schreiben in denselben SRT-/Analyse-Namensraum
   (`TranscriptionEngine.swift:1101`, `:1446`). Nötiger E2E-Beweis: lokalen Lauf
   halten, Serverimport abschließen, lokalen Lauf freigeben, Ergebnisrevision
   und beide Queue-Einträge vergleichen.

9. **P2: Langsamer Ergebnisabruf blockiert Starts und Abbrüche anderer Aufträge.**
   `ServerTranscriptionManager.swift:921`, `:993`, `:1604`: Ein einziger
   `currentTask` umfasst auch alle Ergebnisdownloads. Solange er läuft, starten
   weder andere POSTs noch deren DELETE-Abbrüche. Transportgrenzen liegen bei
   30 Sekunden Request-/120 Sekunden Resource-Timeout; die tatsächliche
   Verzögerung ist verbindungsabhängig. Nötiger E2E-Beweis: Artefaktabruf A halten,
   C abbrechen und B hinzufügen; ausgehende DELETE/POST-Zeitpunkte prüfen.

## Reproduktion und Grenzen

Umgebung: macOS 27.0 arm64, Xcode 27 / Swift 6.4; Backendprobe unter der
produktiven Python-3.10-Umgebung mit isolierter SQLite-Datenbank und Dateien,
gegen den vorab identischen `/tmp/instacast-server-source-20261003`-Snapshot.
Die Backendprobe lädt keine produktive `db.env`, erzeugt keine Produktionsjobs
und führt keine kostenpflichtige Modellinferenz aus.

```sh
python3 Tools/transcription-server/2026-10-03-reliability-audit/app-boundaries/probe.py
python3 Tools/transcription-server/2026-10-03-reliability-audit/local-chapter-probe.py
.codex/private/ssh 'sudo -n env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python -B -' < Tools/transcription-server/2026-10-03-reliability-audit/backend-probe.py
```

Die ersten beiden Befehle enden auf dem geprüften Stand erwartungsgemäß mit
Exit 1, weil gewünschtes Verhalten verletzt wird; die Backendprobe protokolliert
die tatsächlichen Werte. `app-boundaries/manifest.json` bewahrt den ursprünglichen
Aufruf und Quellhashes, `reviewed-source.json` den geprüften App-Stand. Die
Vorab-Fehlermatrizen begründen die isolierten kontrollierten Grenzen. Das ersetzt
keinen vollständigen neuen App-/Produktionsserver-E2E mit Modellinferenz.

Bestehende Admission-, Artefaktfrische-, Transkript-/Timing-, Audioidentitäts- und
Snapshotcache-Prüfungen sind grün. Das ist kein Gegenbeweis: Die bisherigen
Admission-/Importtests schreiben teils die falschen Pending- und Downloadannahmen
selbst fest. Deshalb müssen neue Regressionen vom gewünschten Nutzerablauf
ausgehen und diese Kombinationen tatsächlich ausführen.

Ein einziger veralteter Testfixture-Typ wurde in dieser Prüfrunde korrigiert:
`Tools/server_transcription_import_episode_deletion_runtime_test.py:26` verwendet
jetzt ein Optional passend zur Produktion. Alle Assertions bleiben erhalten;
dieser Test und `git diff --check` sind grün. Die oben genannten Produktfehler
wurden in dieser zusätzlichen Prüfung noch nicht korrigiert oder ausgeliefert.
