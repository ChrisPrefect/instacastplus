# Transkriptionszuverlässigkeit: Korrekturen vom 3. Oktober 2026

Die neun Befunde aus der [vorangegangenen Prüfung](../2026-10-03-reliability-audit/README.md)
sind korrigiert. Die App ist gebaut und geprüft; die vier Serverdateien und die
Quellgenerationen-Migration sind produktiv ausgeliefert. Dieser Bericht trennt
vollständige App-Abläufe, isolierte Grenzprüfungen und Live-Verifikation.

## Ursachen und Korrekturen

1. **Ergebnisabruf nach Cache-Löschung:** Textimport benötigt in keinem Quellenmodus
   aktuelle Geräteaudio. Client-Ergebnisse müssen weiterhin dem unveränderlich
   gespeicherten Start-SHA entsprechen. Wiedergabe-Zeitmarken und Auto-Skip werden
   unabhängig gegen die tatsächlich abgespielten Bytes geprüft.
2. **Neustart vor Versand:** Dauerhaft gespeicherte pending-Aufträge werden mit
   derselben UUID automatisch fortgesetzt. Speicherfehler verhindern weiterhin
   HTTP-Anfragen vor erfolgreicher Persistenz; abgelehnte und abgebrochene
   Aufträge bleiben beendet.
3. **Unvollständiger HTTP206-Download:** Bereich, Gesamtgröße und empfangene Bytes
   müssen eine vollständige Audioquelle belegen. Teilantworten werden verworfen.
4. **Neue Audiofassung derselben URL:** Ein ausdrücklich neuer Versuch oder ein
   anderer Client-SHA erhält eine eigene Quellgeneration. Alte UUIDs, Episode-IDs
   und Ergebnisdateien werden nicht umgebunden. Passende Ergebnisse bleiben
   wiederverwendbar; parallele passende Anfragen teilen Serverarbeit.
5. **Beschädigtes fertiges Ergebnis:** Der App-Wiederholungsweg erstellt eine neue
   Generation ohne globale administrative Force-Freigabe. Ein neuer App-Versuch
   übernimmt keinen alten Zustand für einen reinen Ergebnisabruf.
6. **Worker-Absturz vor Audio-Checkpoint:** Der vollständige Quellen-Checkpoint
   wird vor der dauerhaften Quellenbindung publiziert. Ein neuer Claim verwendet
   nach dem Absturz die ursprüngliche Audiofassung trotz zwischenzeitlich
   veränderter URL-Inhalte.
7. **Lokale Kapitel:** Gespeicherte Kapitel erhalten vor der Generierung erfasste
   Transkriptrevision und Audioidentität. Ein ersetztes oder gelöschtes Transkript
   verhindert den Commit. Playback prüft den tatsächlich geladenen Kapiteldatei-
   Snapshot, auch ohne separate Analyse-Datei.
8. **Konkurrierende lokale und Serveraufträge:** Eine gemeinsame Aufnahmeprüfung
   verhindert zwei offene Transkriptions-/Kapitelaufträge derselben Folge. Die
   Ablehnung nennt den tatsächlichen Grund; terminale Historie bleibt erlaubt.
9. **Langsamer Import blockiert andere Aktionen:** Ergebnisabruf, Annahme/Status
   und Abbruch besitzen getrennte begrenzte Abläufe. Ein gehaltener Import
   blockiert fremde POSTs/DELETEs nicht; ein fremdes DELETE blockiert keinen POST.
   Dieselbe Episode wartet weiterhin auf ihre gespeicherte Abbruchbestätigung.

Weitere fertige Ergebnisse zeigen konkret „Ergebnis wartet auf Abruf“ und warten
auf den einen Importslot. Die Gegenprüfung fand zusätzlich eine sofortige
Scheduler-Schleife und Erstaufnahme-Races mit unterschiedlichen Client-SHAs.
Auch diese wurden zuerst rot belegt und korrigiert. Der Scheduler führt in der
50-ms-Grenzprobe jetzt 1 statt 2934 processNext-Aufrufe aus.

## Tatsächliche App-E2E-Prüfung

Build: `app-build-final.log`; Quellenbindung: `app-build-manifest.json` und
`app-source-before-build.json`. Alle 609 erfassten Produktionsquelldateien blieben
während und nach dem finalen Build unverändert. Debug-dylib UUID:
`60F00567-1772-3FB7-8F2B-B961FDB3845C` (arm64).

Umgebung: macOS, Xcode 27, iOS-27-Simulator
`79C6B540-E8DC-4E2A-8171-25BB70F7E5D1` („Server transcription flow“).
Eingabe: unveränderte WAV und zugehörige echte, bereits erzeugte Modellartefakte
unter `Tools/fixtures/server-sponsor-e2e`. Audio-SHA:
`92747209c31b54463fa69e40d7b29b15894a13ff00664e86ca8066112984b6d0`.
Der kontrollierte HTTP-Peer spielt diese Ergebnisse ab; keine neue Inferenz.

| Szenario | Erwartung und bestätigtes Ergebnis | Beleg |
| --- | --- | --- |
| ownership | Serverannahme bleibt erhalten, lokaler Start derselben Folge wird abgelehnt. | `app-ownership/result.json` |
| pending_restart | Zweite UUID dauerhaft pending, Prozess beendet. Nach Neustart erste UUID abgeglichen und zweite automatisch gesendet: exakt zwei POSTs für zwei UUIDs. | `app-pending_restart/result.json` und gespeicherter Vorherzustand |
| cache_removed | Echter CacheManager entfernt Geräteaudio nach Annahme; anschließend alle vier Ergebnisse korrekt importiert. | `app-cache_removed/result.json`, importierte Dateien |
| import_concurrency | Erster Artefaktabruf gehalten, zweiter Auftrag angenommen und wieder abgebrochen, bevor der erste Abruf freigegeben wird. Kein späterer Commit des entfernten Eintrags. | `app-import_concurrency/result.json`, HTTP-Ereignisse |
| server_source_recovery | Kein Geräteaudio-GET bis Import. Verlorene Annahmeantwort, Neustart, Dienstpause und Verbindungsunterbrechung ergeben genau einen POST. Lesen trotz Playback-HTTP503, erfolgreicher ausdrücklicher Playback-Retry und erst danach geprüfte Zeitmarken. | `app-server_source_recovery/result.json`, Playerzustände |
| recovery | Wiederanlauf mit ursprünglich vorhandener Clientaudio, genau ein POST und passende Quellenbindung beim Import. | `app-recovery/result.json` |

Auftragskonflikt, Pending-Neustart und blockierter Import wurden außerdem vor der
Korrektur im tatsächlichen alten App-Binary reproduziert: `ownership-before`,
`pending-restart-before.log`, `import-concurrency-before.log`. Vorher-UUID im
früheren `../2026-10-03-server-source-evidence/app-tested-source.json`.

```sh
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=79C6B540-E8DC-4E2A-8171-25BB70F7E5D1' -derivedDataPath build/ServerStatusDD build
python3 Tools/server_transcription_app_flow_test.py --device 79C6B540-E8DC-4E2A-8171-25BB70F7E5D1 --app build/ServerStatusDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --scenario import_concurrency --output /tmp/instacast-import-concurrency
```

Nur diesen wegwerfbaren Simulator verwenden: Der Standardlauf installiert neu.
Szenario aus der Tabelle wählen. Jeder neue Lauf speichert `run.json`, Zustand,
HTTP-Ereignisse, Screenshots und bei Erfolg `result.json`. Ein iOS-Mitteilungsdialog
kann Screenshots überdecken. Nach „Nicht erlauben“ ermöglicht
`--preserve-installation` eine Wiederholung mit beantwortetem Dialog.
Die unverdeckte Darstellung wurde separat gesehen und geprüft:

- `app-ownership-visible/competing-local-start.png`: konkrete Ablehnung des zweiten Auftrags.
- `app-import-concurrency-unobscured/second-result-waiting.png`: bestätigte Annahme, fertiger Server und konkreter Wartegrund.
- `awaiting-import-after` und `awaiting-import-en`: echter UIKit-Statuscontroller in Deutsch/Englisch mit Timeline-Assertions.

## Ergänzende Grenzprüfungen

Diese führen Produktionsmethoden mit kontrollierten Fehlergrenzen aus; sie
ersetzen keinen App-E2E:

- [Manager: acht Suiten, Befehle und Quellenhashes](../2026-10-03-reliability-audit/app-boundaries/fix-validation.md).
- [Lokale Kapitel: 15 Fälle, negative Quellen-/Revisionsfälle und angrenzende Prüfungen](../2026-10-03-reliability-audit/local-chapter-identity.md).
- [Backend: exakte Befehle, 13 SQLite-/12 MariaDB-Generationsfälle, je vier Recoveryfälle, Migration und angrenzende Suiten](backend-validation.md).
- `python3 Tools/localization_coverage_regression_test.py`, `plutil -lint Resources/de.lproj/Localizable.strings Resources/en.lproj/Localizable.strings` und `git diff --check` bestanden.

## Produktive Auslieferung

`deployment.log` bestätigt vier geprüfte Dateien (`app/db.py`, `main.py`,
`service.py`, `worker.py`) und die Migration zu `episodes.source_generation` mit
Eindeutigkeit aus vollständigem URL-SHA und Generation. Vollständige DB- und
Quellensicherung:
`/home/instacast/domains/transcript.instacast.ch/var/backups/transcription-reliability-20261003`.

Die Auslieferung prüft die Ausgangshashes, stoppt die Annahme, prüft erneut die
leere Queue und stoppt dann den Worker. Nach Migration wurden vor Dienststart
alle bisherigen Episode-, Job-, Request- und Artefaktzuordnungen verglichen:
**110 Episoden, 2419 Jobs, 86 Requests und 333 Artefakte unverändert**.
Keine Produktions-Testjobs wurden angelegt.

Live geprüft am 3. Oktober 2026, 14:40 Schweizer Zeit (`live-verification.json`):
Health HTTP200/ok, API und Worker aktiv, Warteschlange leer, Schema
`2026-10-03.2`, alle vier Datei-Hashes passend. Alle 110 bisherigen Episoden
haben Generation0; der neue Composite-Index ist vorhanden und
`ALLOW_API_FORCE` bleibt false. Historischer abgebrochener Auftrag bleibt
abgebrochen. `server-reliability-manifest.json`, `server-reliability.patch`,
`tests/`, `deploy-server.py`, `deployment-command.json` und
`verify-production.py` halten Quellstand und Verfahren nachvollziehbar fest.

Prüfgrenzen: kein neuer vollständiger Modell-Inferenzlauf, kein physischer
Flugmodus-/Hintergrundtest und kein lokaler Kapitelmodell-E2E im Simulator.
Dieser Arbeitsgang erstellt keinen TestFlight-Upload und installiert nichts auf
Chris' iPhone. Der Simulator-Build belegt die App-Korrektur, nicht ihre Verteilung.
