# Serverquelle ohne Download auf dem iPhone

Ausgangsstand: frischer produktiver Code vom 03.10.2026, dokumentiert in `baseline.json`. Der alte API-Vertrag lehnte jeden Auftrag ohne Geräte-SHA bereits vor der Annahme ab. Der Worker markierte außerdem sämtliche Anfragen ohne gebundenen Hash als ungeprüft. Damit war ein vollständig auf dem Server gestarteter Auftrag unmöglich.

Der neue additive Vertrag erlaubt `audio_source: "server"` mit dauerhafter Request-UUID und ohne `client_audio_sha256`. Die URL wird erst vom Worker heruntergeladen. Dabei bindet der Server den tatsächlich berechneten Audiohash einmalig an die Anfrage, bevor ASR starten darf. Modus, URL und bereits gewählte Quelle bleiben beim Wiederholen unverändert. Bestehende/default `audio_source: "client"`-Aufträge behalten ihre strikte Gerätehashprüfung. Abweichende Clientquellen werden auch bei gemeinsamer Serverarbeit separat abgewiesen.

Schema 2026-10-03.1 dokumentiert beide Modi und das neue `audio_source`-Echo im Annahmebeleg. Die Migration ergänzt nur `transcription_requests.audio_source VARCHAR(16) NOT NULL DEFAULT 'client'`. Historische Anfragen bleiben damit Clientquellen. Produktionsänderungen und Deployment gehören zum Root-Auftrag; die Tests unten ändern keine Produktionsdaten.

## Reproduktion und Endzustand

- `server-before.log`: 9 von 10 neuen Fällen scheitern vor der Korrektur am tatsächlichen HTTP 422 statt 202.
- `schema-before.log`: der neue Quellmodus im Annahmebeleg fehlt im veröffentlichten Antwortschema.
- `server-after.log`: alle 11 neuen SQLite-Fälle bestehen.
- `server-source-final-0.log`: dieselben 11 Fälle bestehen auf einer eigens angelegten, danach gelöschten MariaDB-Datenbank.
- `server-source-final-1.log`:88 SQLite--Zuverlässigkeitsfälle bestehen.
- `server-source-final-2.log`:56 Lifecycle--Fälle bestehen.
- `server-source-final-3.log`:51 MariaDB--Zuverlässigkeitsfälle bestehen.
- `server-source-final-4.log`: vier bestehende API-Vertragsprüfungen bestehen.
- `server-source-final-5.log`:14 Fortschritts-/Workerstatusfälle bestehen.
- `server-source-nearby-1.log` und `server-source-nearby-2.log`: die neun bisherigen Audioidentitätsfälle bestehen auf SQLite und MariaDB, einschließlich fehlendem Clienthash und Quellenabweichung vor ASR.

Eine bestehende vollständige Receipt-Assertion wurde um das additive Feld `audio_source: "client"` ergänzt. Identität, Abbruchzustand und Zugriffsverweigerung bleiben vollständig geprüft. Die vorhandene Schema-Revisionsassertion wurde auf den neuen veröffentlichten Vertrag aktualisiert. Keine Verhaltensassertion wurde entfernt oder abgeschwächt.

## Tatsächlich ausgeführter Ablauf

Die neue Prüfung ruft reale HTTP-Routen der ASGI-App auf und verwendet die echte Queue und Claimverwaltung. Eine echte WAV-Datei mit 16000 Samples wird über einen lokalen HTTP-Server angeboten. Die Annahme lädt keinerlei Audio. Nach dem Claim führt der Worker seinen normalen Download, SHA-256, die externe Decoder-Dauermessung und die Quellbindung aus. Erst der ASR-Aufruf selbst wird abgefangen, damit keine Modellkosten anfallen.

Danach wird ein neuer Workerclaim gestartet und die öffentliche Audioquelle absichtlich geändert. Die gespeicherte Quelle bleibt erhalten: kein zweiter Download, derselbe gebundene SHA, erneutes Erreichen der ASR-Grenze. Weitere Fälle prüfen unveränderte UUID bei Replay, verweigerten Moduswechsel, Clientmismatch bei geteilter Arbeit, spätes Beitreten, Abbruch vor POST und Migration historischer Anfragen.

Die HTTP-Anfragen und Antworten stehen in `server-source-before.jsonl`, `server-source-after.jsonl` und `server-source-final.jsonl`. Dies ist ein Backend-Integrationsnachweis mit realem Download und Worker-Neustart, kein neuer vollständiger Modelllauf und kein iPhone-Nachweis. Der Root-Auftrag prüft die tatsächliche App ohne gecachte Audiodatei separat.

## Wiederholen

Quellstand: `.codex/private/server-source-20261003`; Testkopie: `/tmp/instacast-server-source-20261003` auf dem Server. Die Quellen lassen sich über `server-source.patch` und die Vorher-/Nachher-Prüfsummen in `server-source-manifest.json` prüfen. Die Tests laden niemals `var/app/db.env`; sie erzwingen temporäre SQLite- oder eigene MariaDB-Datenbanken.

```sh
cd /tmp/instacast-server-source-20261003
sudo env INSTACAST_DB_BACKEND=sqlite SERVER_SOURCE_EVIDENCE=/tmp/server-source-http.jsonl /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/server_audio_source_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/queue_admission_mysql_regression.py --server-audio-source
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/audio_admission_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/queue_admission_mysql_regression.py --audio-admission
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/server_reliability_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/lifecycle_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/queue_admission_mysql_regression.py --reliability
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/api_contract_v3_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/work_status_regression.py
```

Lesender Live-Nachweis vor Deployment um 09:35 UTC: `/health` antwortet 200 mit `ok:true`, null wartenden und laufenden Aufträgen; API und erster Worker laufen. Anmeldung des Dienstbenutzers meldet `Logged in using ChatGPT`. Belege: `live-health-before.json`, `live-auth-before.txt`.

## Tatsächlicher App-Ablauf und erkannte Lücken

Der vorherige App-Test lud die Folge immer zuerst herunter. Der normale Start
ohne Geräteaudio fehlte damit in der Prüfung. Die neue Variante `server_source`
erzeugt dieselbe Folge ohne Download und startet über die gemeinsame produktive
UI-Aktion. Vor der Korrektur scheiterte sie vor jedem HTTP-POST mit der gemeldeten
Downloadaufforderung. `app-before` enthält Queuezustand, Log und Screenshots,
einschließlich eines Screenshots ohne Systemdialog.

Die App speichert den Quellenmodus dauerhaft pro UUID, prüft das entsprechende
Server-Echo und importiert servergebundene Ergebnisse ohne lokale Audiodatei.
Die vorhandenen SHA-, Revisions- und Inhaltsprüfungen bleiben erhalten. Gezielte
Boundarytests prüfen verlorene Antworten, Neustart, einen späteren Gerätedownload,
historische Snapshots und Quellenfehler. Ein endgültiger Quellenfehler wird beim
ausdrücklichen Neustart mit neuer UUID erneut angefragt. Dokumentation und rote/
grüne Belege: `client-contract-test-plan.md`, `client-validation.json` und
`client-source-error-validation.json`.

Die reine Transkriptansicht konnte zunächst weiterhin keinen Text ohne
Audiofreigabe anzeigen. Die Korrektur trennt aktuelle Textartefakte von geprüften
Zeitmarken. `player-text` enthält die zuvor fehlgeschlagenen und anschließend
bestandenen nativen Laufzeittests. Der zusätzliche vollständige Player-E2E fand
anschließend eine weitere reale Lebenszykluslücke: Ein HTTP-503-Medienfehler
löschte die Episode und schloss den Player samt lesbarem Text. Dieser rote
Nachweis samt tatsächlicher Buttonbedienung ist in `app-player-before` erhalten.

Der Fehlerpfad gibt jetzt die gescheiterten Medienressourcen frei und behält die
ausgewählte Episode. Der Player lädt vorhandenen Text unabhängig von der
Audiobereitschaft, zeigt den tatsächlichen Wiedergabefehler einmal und ermöglicht
einen ausdrücklichen neuen Wiedergabestart. Zeitinteraktionen bleiben bis zur
Audiobereitschaft und bei generierten Texten zusätzlich bis zur Quellenprüfung
gesperrt. Absichtliches Beenden behält seinen bisherigen vollständigen
Aufräumpfad. Rote/grüne Ressourcen-, Benachrichtigungs- und Steuerungsprüfungen
sind in `player-failure-test-plan.md` und `player-text/README.md` dokumentiert.

Der anschließende echte Wiedergabestart fand eine unabhängige, bereits vorhandene
Formatlücke im Streaming-Loader: Für `audio/wav`/`audio/x-wav` fehlte die
AVFoundation-Typangabe. Die identische WAV war lokal abspielbar und wurde über
HTTP vollständig übertragen; im Custom-URL-Loader scheiterte sie mit
`AVFoundationErrorDomain -11828` / `OSStatus -12847`. Ein Vergleich mit dem
unveränderten vollständigen Produktionsloader und ausschließlich korrigierter
WAV-Typangabe bewies die Ursache. Der rote App-Nachweis liegt in
`app-player-retry-before`. Die Testdatei und die Erfolgsbedingungen bleiben
unverändert.

## Produktive Auslieferung

`deploy-server.py` verglich alle sieben Ausgangsdateien mit dem frisch gelesenen
Produktivstand, prüfte die leere aktive Queue, sicherte die komplette Datenbank
und Quellen und ergänzte die neue Spalte. Sicherung:
`var/backups/server-source-20261003`. `deployment-result.log` bestätigt die
Auslieferung und unveränderte Jobzustände.

`verify-production.py` prüfte danach lesend alle sieben Datei-Hashes, das echte
öffentliche Schema, einen vorhandenen Auftrag und die Dienste. Ergebnis in
`production-verification.json`: HTTP 200, `ok:true`, API/Worker aktiv,
Schema `2026-10-03.1`, alle 86 bestehenden Anfragen weiterhin `client`, unveränderte
Jobs und keine Produktions-Testaufträge.

## App-Prüfung wiederholen

Umgebung: macOS 27.0 (26A428), Xcode 27.0 (27A266a), iOS-27.0-Simulator
`Server transcription flow`, deutsche App-Sprache. Ausschließlich den genannten
wegwerfbaren Testsimulator verwenden: Das Skript installiert die App darin neu.
Den systemseitigen Benachrichtigungsdialog gegebenenfalls mit „Nicht erlauben“
schließen. Die Screenshots werden während des tatsächlichen Ablaufs gespeichert.

```sh
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=79C6B540-E8DC-4E2A-8171-25BB70F7E5D1' -derivedDataPath build/ServerStatusDD build
python3 Tools/server_transcription_app_flow_test.py --device 79C6B540-E8DC-4E2A-8171-25BB70F7E5D1 --app build/ServerStatusDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --scenario server_source_recovery --output Tools/transcription-server/2026-10-03-server-source-evidence/app-server-source-recovery-final
python3 Tools/server_transcription_app_flow_test.py --device 79C6B540-E8DC-4E2A-8171-25BB70F7E5D1 --app build/ServerStatusDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --scenario recovery --output Tools/transcription-server/2026-10-03-server-source-evidence/app-client-recovery-final
git diff --check
plutil -lint Resources/de.lproj/Localizable.strings Resources/en.lproj/Localizable.strings
```

Eingaben: unveränderte WAV und echte, bereits erzeugte ASR-Artefakte unter
`Tools/fixtures/server-sponsor-e2e`. Der lokale HTTP-Peer spielt die
Serverantworten kontrolliert ab. Er verliert die erste POST-Antwort nach
Annahme, unterbricht die Verbindung und meldet eine Dienstpause; das Skript
beendet und startet außerdem den tatsächlichen App-Prozess neu. Erwartet:
eine UUID, genau ein POST, weiterhin sichtbare Annahme, alle Phasen,
unveränderte importierte SRT-Bytes und passende Quellen-/Revisionsbindung.
Im Servermodus darf bis zum abgeschlossenen Ergebnis kein Geräte-Audio-GET
auftreten. Erst die anschließende Player-Prüfung fordert Audio an: HTTP 503
muss lesbaren Text und einen bedienbaren Play-Button erhalten, der ausdrückliche
neue Start muss nach Wiederherstellung der Quelle abspielbereit werden.
Danach muss die unveränderte, vollständig gecachte Audioquelle auch die
Zeitmarken freigeben. Diese zusätzliche Assertion wurde nach dem sichtbaren
Wiedergabenachweis ergänzt und scheiterte reproduzierbar
(`app-timing-before/full-flow/run.log`), obwohl die Diagnostik eine zuvor
erfolgreiche Audioidentitätsprüfung meldete. Die Schutzprüfung wird dabei
nicht abgeschwächt; Ersetzung von Audio oder Text muss sie weiterhin verwerfen.
Der instrumentierte Lauf `app-timing-before/snapshot-flow` grenzt die Differenz
auf `st_ctime` der Audioquelle ein: Gerät, Inode, Größe, Änderungszeit und Bytes
bleiben identisch. Eine unabhängige Ausführung des vollständigen Loaders im
Simulator-Dokumentordner reproduziert das nachträgliche Systemflag `UF_TRACKED`
(Dokumentkennung). Weder Playback-UI noch Kapitelcode müssen dafür laufen.
Die Korrektur prüft nach dieser Metadatenänderung die Audioquelle erneut
asynchron gegen dieselben unveränderten Artefakte. Eine beim Öffnen verankerte
Dateigeneration verhindert, dass währenddessen andere Bytes zur Quelle werden.
Auch ein Metadatenwechsel vor oder während der ersten Hashprüfung wird geprüft;
der zweite instabile Hash bleibt gesperrt. Gleicher Inode, gleiche Größe und
exakt zurückgesetzte Änderungszeit können eine echte Inhaltsänderung nicht
freigeben. Der tatsächliche App-Lauf und die deterministischen roten/grünen
Grenzfälle sind in `timing-revalidation-validation.json` dokumentiert.

Die Pauseansicht hatte außerdem bereits bestätigte Transkription fälschlich
wieder als „Noch nicht begonnen“ angezeigt. Die zuletzt bestätigte Arbeitsphase
wird nun separat gespeichert und über einen App-Neustart erhalten. Die Ansicht
zeigt den entsprechenden Schritt als pausiert, ohne laufende Aktivität oder
erfundenen Fortschritt. Der UIKit-Nachweis in `player-text` prüft Deutsch,
Englisch und eine Pause ohne bekannte Vorphase. Der App-Recovery-Test prüft
zusätzlich die tatsächlich erzeugten Tabellenzeilen und das Aktivitätssymbol.

Die explizite Swift-Benennung des Playback-Singletons erforderte eine Anpassung
des bestehenden App-Intent-Zugriffs. Der native Bridge-Test reproduziert zuvor
eine zusätzliche Instanz und wirkungslose Wiedergabestarts nach Medienfehlern.
Siri-/Kurzbefehle verwenden jetzt denselben Player und den bestehenden manuellen
Wiederholungspfad wie der Play-Button; laufende und pausierte Wiedergabe behalten
ihr Verhalten. Die Prüfung führt den produktiven Swift-Zugriff und die
ObjC-Singleton-Methode aus; sie ist kein gesprochener Siri-E2E-Test.

```sh
python3 Tools/playback_autoskip_live_settings_runtime_test.py
python3 Tools/server_transcription_admission_runtime_test.py
python3 Tools/app_intent_playback_bridge_runtime_test.py
```

`app-tested-source.json` bindet den App-Nachweis an Quellprüfsummen und die UUID
des gebauten App-Binaries; `app-build.log` enthält den Build. Die jeweiligen
Szenarioordner enthalten Queuezustände, Screenshots, importierte Dateien,
Playerzustände und bei Erfolg `result.json` mit HTTP-Ereignissen und exaktem
Aufruf. Die DEBUG-Steuerung prüft den tatsächlich sichtbaren vollständigen
Player und liest den produktiven PlaybackManager-Singleton aus.

Abschlusslauf am 03.10.2026: Build erfolgreich; `server_source_recovery` und
`recovery` mit demselben unveränderten Binary erfolgreich. Beide senden genau
einen Auftrag trotz verlorener Annahmeantwort, App-Neustart, Dienstpause und
Verbindungsunterbrechung. Im Serverquellenlauf gibt es bis zum fertigen Import
keinen Geräte-Audioabruf. Danach bleiben alle 28 Textpassagen bei HTTP 503 im
vollständigen Player lesbar; Play ist bedienbar. Nach ausdrücklichem Wiederholen
sind Wiedergabe und geprüfte Zeitmarken verfügbar. `playback-stable-view.json`
bestätigt dies erneut während laufender Wiedergabe, mit leerem Fehlerhinweis.
Die Pausezeilen bestätigen abgeschlossenen Serverdownload, pausierte
Transkription und noch nicht begonnene Analyse; kein Aktivitätssymbol läuft.
`restored.png` zeigt die ungestörte tatsächliche Transkriptionsansicht nach dem
Neustart, `paused.png` die korrigierte Pauseansicht und `playback-running.png`
die laufende Wiedergabe mit hervorgehobener Textstelle. Einige frühere
Screenshots enthalten den während des Laufs geschlossenen Systemdialog;
die späteren genannten Screenshots sind unverdeckt.

Grenzen: kein neuer Modell-Inferenzlauf, kein physischer Flugmodus-/Hintergrund-
Test und keine Installation auf Chris' iPhone oder TestFlight-Auslieferung.
CarPlay-/Widget-Retry ist durch ausgeführte Produktionsmethoden geprüft, nicht
durch ein physisches CarPlay-Gerät oder eine Widget-Erweiterung.
