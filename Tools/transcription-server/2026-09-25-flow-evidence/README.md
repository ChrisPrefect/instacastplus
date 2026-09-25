# Server-Transkription: Ablauf, Status und Fehlerbehandlung

Stand: 25.09.2026. Änderungen liegen lokal; kein Release und keine Serveränderung.

## Befund und Ursache

Nutzereingabe: IMG_2297.PNG, Another World (SF 26), Start im Flugmodus um
06:51:14 Europe/Zurich. Danach alle 30 Sekunden Audio-Prüfung und „Noch keine
Bestätigung vom Server“. Erwartet: Auftrag behalten, bei Internet automatisch
fortsetzen, verständliche Zustände und passende Aktionen ohne erfundene Zeiten.

Direkt auf Produktion geprüft: API und Worker liefen. Im Zeitraum 04:45–05:05 UTC
lieferten 21 POSTs HTTP 403 und 20 Abfragen HTTP 404. Der Auftrag
`c938666f-fd40-4b66-b1da-9d5de90b6734` blieb ohne Serverepisode. Der Client hatte
nach der lokalen Offline-Ablehnung einen erzwungenen Neustart angefordert. Diesen
lehnt die API für neue Episoden ab. Der Client deutete die dauerhafte Ablehnung
fälschlich als fehlende Bestätigung. Der Netzwerkmonitor startete wartende Arbeit
nicht wieder. Der Hintergrund-Schalter prüfte nicht, ob lokale Arbeit vorhanden war.

Die alte Detailansicht war ein technisches Log. Auch die erste Teilkorrektur zeigte
nur einen langen Statustext über dem Log; eine klare nächste Aktion fehlte.
`status-before/screen.png` zeigt den tatsächlichen UIKit-Controller vor der
weitergehenden Überarbeitung. Der zugehörige Test schlug fehl.

## Überarbeiteter Ablauf

| Situation | Sichtbarer Zustand und Verhalten |
| --- | --- |
| Manueller Start aus Liste, Swipe oder Episodendetails | Einheitliche Statusseite; Audio lokal prüfen und Auftrag dauerhaft speichern |
| Offline vor Versand | „Wartet auf Internet“, Auftrag bleibt erhalten und wird automatisch fortgesetzt |
| Antwort nach Versand verloren | Dieselbe Request-UUID abgleichen; keinen doppelten Auftrag erstellen |
| Server hat angenommen | Tatsächliche Phase anzeigen: Warten, Audiodownload, Transkript, Analyse, Bereitstellung |
| Server/Verbindung vorübergehend nicht verfügbar | Ursache und nächste geplante Abfrage; gespeicherten Auftrag erhalten |
| Unbekannte/ungültige Statusantwort | Automatische Versuche stoppen; „Gespeicherten Auftrag prüfen“, gleiche UUID |
| Verarbeitung fehlgeschlagen | Ursache und bewusster neuer Versuch; erzwungener Neustart nur bei bestätigtem Serverfehler/Abbruch |
| Ergebnis bereit | Strenger quellgebundener Import; erst danach „Fertig und verfügbar“ |
| Import fehlgeschlagen | „Ergebnis erneut laden“ ohne erneute Transkription |
| Abbruch | Absicht dauerhaft speichern; offene Serverabbrüche bleiben in der Transkriptionsliste sichtbar |

Die Statusseite trennt aktuellen Zustand, letzte Serverantwort, nächsten Schritt,
Aktion und den Ablauf Vorbereitung / Server / Übernahme. Diagnosemeldungen stehen
hinter einem eigenen Eintrag. Die Übersicht zeigt kurze Zustände statt wiederholter
Protokolltexte. DE/EN, automatische Zeilenhöhe und Dynamic-Type-Schriften in der
Statusseite. Keine erfundenen Prozentwerte oder Restzeiten. Der nächste Abfragezeitpunkt
ist ein geplanter Client-Termin, keine Fertigstellungsprognose.

Alle offenen Serveraufträge werden für die vorhandene netzgebundene Hintergrundplanung
berücksichtigt. iOS bestimmt den Ausführungszeitpunkt; das wird im UI erklärt.
„Im Hintergrund verarbeiten“ erscheint nur bei offenen lokalen Aufträgen.

## Test-first und Fehlergrenzen

Vor Produktionsänderungen dokumentierte Fehlermatrix: offline vor/nach POST,
verlorene oder unlesbare Antwort, dauerhafte Ablehnung, Neustart, Plattenfehler vor
Speicherung, Audioaustausch, Abbruch, Server-Pause, unbekannte Phase, Importfehler,
lokale/serverseitige/gemischte Queue, lange Übersetzungen und schmale Darstellung.

Isolierte Tests sind für gezielte Plattenfehler und genaue Netzunterbrechungen am
Commit erforderlich: Diese dürfen nicht an produktiven Aufträgen induziert werden.
Sie führen echte Manager-, Persistenz-, Import- und Darstellungsfunktionen aus;
Transport und Gerätegrenzen werden kontrolliert. Keine Quelltext-Schreibweisen oder
kopierte Zustandsmaschine als Nachweis. Vorher-Fehler sind in `before.txt`,
`whole-flow-before.txt`, `unknown-phase-before.txt`, `presentation-before.txt`,
`background-before.txt` und `status-before/` erhalten.

## Vollständige App mit kontrolliertem HTTP-Gegenüber

`app-flow/result.json` belegt auf einem eigenen iPhone-18-Pro-Simulator (iOS 27):

1. Die vollständige App legt eine synthetische Testepisode an und lädt die WAV-Datei
   über ihren echten CacheManager per HTTP herunter.
2. Die gemeinsame Startaktion öffnet die echte Statusseite. Die App hasht das Audio,
   speichert die Request-Identität und sendet genau einen POST ohne `force`.
3. Jede Serverphase läuft über echte HTTP-Antworten durch den Produktionsmanager.
4. Die App lädt alle vier echten Ergebnisartefakte, prüft Größe, Typ, ETag, Hash,
   Audioidentität und Transkriptbezug und speichert Transkript und Analyse.
5. `app-flow/import.json` enthält die importierten Kapitel einschließlich des
   Sponsorabschnitts. Der Queue-Zustand ist `completed`.

Audio und Artefakte gehören zum selben realen synthetischen Whisper/OpenAI-Durchlauf
vom 06.09.2026. Die Inferenz wird hier wiedergegeben, nicht erneut ausgeführt.
Audio-SHA: `92747209c31b54463fa69e40d7b29b15894a13ff00664e86ca8066112984b6d0`.

Die Testinfrastruktur ist auf DEBUG + iOS-Simulator + ausdrücklich übergebenen
Loopback-Endpunkt beschränkt. Sie verwendet einen Test-Token; Produktionszugang und
Produktionsdatenbank werden nicht verwendet. Der Treiber verlangt einen eigenen
Simulator namens `Server transcription flow` und ersetzt dort ausschließlich die
Testinstallation. Das ist ein App/HTTP/Import-Durchlauf, kein erneuter produktiver
Audio-zu-KI-Durchlauf und kein automatisierter Fingertipp-Test.

## Wiederholbare Befehle

Arbeitsverzeichnis: `/Users/Chris/Developer/instacastplus`. Umgebung: macOS 27 arm64,
Xcode mit iOS-27-SDK. Fixture: `Tools/fixtures/server-sponsor-e2e/fixture.wav` und die
vier benachbarten Artefakte.

```sh
python3 Tools/server_transcription_admission_runtime_test.py
python3 Tools/server_transcription_cancellation_runtime_test.py
python3 Tools/server_transcription_errors_runtime_test.py
python3 Tools/server_transcription_storage_runtime_test.py
python3 Tools/server_transcription_retry_interval_runtime_test.py
python3 Tools/server_poll_lifecycle_runtime_test.py
python3 Tools/server_transcription_presentation_runtime_test.py
python3 Tools/server_sponsor_e2e_client_runtime_test.py
python3 Tools/localization_coverage_regression_test.py
python3 Tools/server_transcription_status_screen_runtime_test.py --scenario offline --output /tmp/server-status-offline
python3 Tools/server_transcription_status_screen_runtime_test.py --scenario running --output /tmp/server-status-running
python3 Tools/server_transcription_status_screen_runtime_test.py --scenario failed --locale en --width 320 --output /tmp/server-status-failed
python3 Tools/server_transcription_layout_runtime_test.py --device 675CC86D-C1EA-41D7-A244-0318E0EE1121 --locale de --width 393 --output /tmp/server-layout
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=675CC86D-C1EA-41D7-A244-0318E0EE1121' -derivedDataPath build/SimDD build
python3 Tools/server_transcription_app_flow_test.py --device 79C6B540-E8DC-4E2A-8171-25BB70F7E5D1 --output /tmp/server-app-flow
git diff --check
```

Ergebnis: Build, gezielte Laufzeittests, sieben deutsche Statuszustände, fünf englische
Zustände bei 320 pt, gemessene Queue-Zellen und der vollständige App/HTTP/Import-Durchlauf
bestanden. `status-*/screen.png`, `status-*/result.json` und die einzelnen Logs sind
beigefügt. Screenshot-Erzeugung erfolgt nach `viewDidAppear`, ohne feste Wartezeit.
`production-health-final.json` enthält die abschließende lesende Prüfung des echten Servers.

## Genaue Prüfgrenzen

Der echte Flugmodus, die NWPathMonitor-Zustellung und von iOS gewährte Hintergrundzeit
auf einem physischen iPhone sind nicht geprüft. Die Laufzeittests prüfen die zugehörigen
Produktionsübergänge gezielt einschließlich Wiederanlauf und Persistenz.

Device Hub ließ sich wiederholt nicht über Computer Use bedienen (`-10005 timeoutReached`).
Im frischen Simulator blieb daher der iOS-Mitteilungsdialog offen. Die Screenshots unter
`app-flow/` behalten diesen Systemdialog sichtbar; der App/HTTP/Import-Durchlauf lief
nachweislich darunter durch. Die unbedeckte Darstellung wurde separat mit dem echten
UIKit-Controller für alle genannten Zustände geprüft (`status-*/`). Menügesten, Bestätigung
des Abbruchs und der Sprung im Player sind damit nicht als durchgeklicktes E2E bewiesen.
