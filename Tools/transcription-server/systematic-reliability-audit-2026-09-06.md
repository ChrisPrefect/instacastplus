# Systematische Zuverlässigkeitsprüfung — 6. September 2026

Status: Die beschriebenen Korrekturen sind umgesetzt, gezielt getestet, auf dem Server eingespielt und als Release4.0(37) auf Chris’ iPhone17Pro installiert und gestartet. Die ausdrücklich offenen Geräte-, Last- und Modellqualitätsprüfungen bleiben offen. Dieser Bericht ist kein Nachweis allgemeiner Fehlerfreiheit.

## Prüfmethode und Zustandsmodell

App: lokal vorgemerkt → Aufnahme unbestätigt → serverseitig angenommen → wartend/aktiv/pausiert → Import → fertig; daneben abgelehnt, fehlgeschlagen und abgebrochen. Abbrüche besitzen eine getrennte persistente Outbox.
Server: Request reserviert → atomar zugeordnet → queued → running mit Claim/Lease → staged → published → done; daneben retry, paused, failed, canceled/deleted und Retention.
Player: Artefakt vorhanden → exakte Audio-/Transkriptgeneration geprüft → Timeline freigegeben → durch Quellen-/Artefaktänderung widerrufen.

An jeder Grenze werden Fehler vor/nach Dateiersetzung, DB-Commit, Netzwerkantwort und Prozessende geprüft. Quer dazu: identische und konkurrierende Aufträge, andere Besitzer, doppelte/verzögerte Antworten, Ressourcenverbrauch und Aufräumen. Bestehende Testzahlen ersetzen diese Übergangsprüfung nicht.

## Verbindliche Invarianten

1. Ein bestätigter oder möglicherweise bestätigter Auftrag behält Besitzer und UUID über Neustart; unklare Antworten schaffen keinen zweiten Auftrag.
2. Abbruch ist dauerhaft und dominiert verspätete Nachrichten derselben Request-Identität. Ein neuer Nutzerauftrag braucht eine neue Identität.
3. Kapazität wird von allen schreibenden Pfaden atomar geprüft: App25, Server250. Alle belegten Zustände zählen.
4. Ein nicht lesbarer Speicher ist nicht leer. Kein Überschreiben unbekannter Aufträge oder Abbruchabsichten.
5. Retry-Klasse, Versuchbudget und nächster Versuch überleben Neustart. Automatische Scans und Retention dürfen endgültige Fehler nicht aufheben.
6. Nur der aktuelle Claim darf Ergebnisse veröffentlichen. Wiederverwendung setzt vollständige Quellen-/Konfigurationsidentität voraus.
7. Sprünge benötigen die Identität der tatsächlich angezeigten Timeline, des Transkripts und der tatsächlich abgespielten Audiodatei. Eine alte Prüfung autorisiert keine neue Generation.
8. Jede externe Operation hat Speicher-/Grössen-/Zeitgrenzen; Aufräumen und Benachrichtigung dürfen einen fertigen Auftrag nicht zurücksetzen.
9. Angezeigter Status unterscheidet abgelehnt, unbestätigt, angenommen/pausiert, endgültig fehlgeschlagen und abgebrochen.

## Abgegrenzte Umsetzungspakete

| Paket | Eigentum | Nachgewiesene Probleme / Abnahmekriterium | Abhängigkeiten |
|---|---|---|---|
| S1 Serverzustände | app/main.py, service.py, worker.py, db.py und zugehörige Servertests | Alle Schreiber respektieren Tombstones und endgültige Fehler; Retention erhält Ursache; transiente Fehler haben dauerhaften Backoff; abgeschlossene Checkpoints korrekt gebunden; Abschluss/Webhook atomar | keine; RSS-Transport separat |
| S2 App-Dauerhaftigkeit | ServerTranscriptionManager.swift, TranscriptionQueue.swift, Queue-UI, DE/EN, neue Runtime-Tests | Kein fremder Server-ID-Erbe nach Retention; kein stiller Queue-/Outboxverlust; Besitzer im selben Snapshot; keine Timer-Überläufe | keine; Manager-Artefakt-Import-Schnittstelle erhalten |
| S3 Playback-Identität | ChapterGenerator.swift, TranscriptionEngine.swift, PlaybackManager, PlayerInfo, Widget-Kapitelaktion + Tests | Invalidierung während Hashprüfung widerruft Proof; Cue-Cache revisionsgebunden; persistierte Intervalle geprüft; veraltete Widget-Aktion abgelehnt | keine; bestehende SRT- und Analyse-Importmethoden erhalten |
| S4 Transport-/Artefaktvertrag | app/rss.py, config.py, artifact_contract.py, HTTP-Helper und neue Transporttests | Bestehendes Feed-Grössenlimit vor Vollpufferung durchsetzen; Gesamtablauf einschliesslich DNS/Discovery begrenzen und Kindprozess aufräumen | Worker-Hook nach S1 abstimmen |
| I Integration | Bericht, Vertragsprüfungen, Deployment, Build/Geräteinstallation | Endgültigen gemeinsamen Stand testen; echten Serverstand vergleichen; keine installierten Zwischenstände als fertig bezeichnen | S1–S4 |

Alle Produktionskorrekturen brauchen zuerst einen für die richtige Ursache fehlgeschlagenen Regressionstest. Änderungen bleiben auf diese Pakete begrenzt. Neue nachgewiesene Blocker werden explizit zugeordnet; unbekannte Geräte-/Modellqualität wird nicht als bestanden eingetragen.

## Noch nicht durch Geräte-/Langzeittests belegt

Echter iOS-Lock/Unlock an jedem Commitpunkt; BG-Expiration während jedes Importteils; voller Gerätespeicher mit anschliessender Wiederherstellung; lokale200h-ASR mit gemessenem Speicher-/Thermalprofil; reale Last mit250 gleichzeitigen unabhängigen Nutzern; semantische Sponsorqualität über Sprachen/Genres/dynamische Anzeigenvarianten. Ein Build, ein synthetischer E2E-Lauf und kontrollierte Zustandsprüfungen beweisen diese Eigenschaften nicht.


## Ergebnisstand der gezielten Korrekturen

| Invariante / Fehler | Ursache | Korrektur und konkreter Nachweis |
|---|---|---|
| App-Auftrag erbt falsche Server-ID | Retention entfernte Objekte, aber nicht deren ObjectIdentifier-Metadaten | Metadaten werden gemeinsam entfernt; echter Swift-Queue-Runtime-Test |
| Beschädigter/gesperrter Queue-Speicher löscht Outbox | Read-/Decodefehler wurde als leere Queue behandelt | Schreiben/Annahme bis erfolgreichem Load gesperrt, sichtbare Speicherwiederholung; Server- und Local-Storage-Runtime |
| Besitzer geht unabhängig von Request-UUID verloren | Client-ID war nur in UserDefaults, Queue separat | Owner im selben atomaren Snapshot; Defaults-Wechsel/Migration/fehlender Owner getestet |
| Riesiger Retry-Hinweis crasht Timer | Ungeprüfte Umwandlung Double→UInt64 | Vertrag1…86400s, ungültige Werte stoppen automatische Abfragen bei erhaltener UUID und sichtbarem Zustand; Grenzwert-Runtime |
| Prüfung autorisiert ersetzte Analyse/SRT | Herkunft vor await gespeichert, danach nicht erneut verglichen | Generation/Snapshot vor und nach Hash sowie vor Sprüngen geprüft; suspendierter echter Swift-Proof |
| Versteckter Player stellt alte Cues mit neuer Proof her | Cache nur nach Episode, keine Transkriptgeneration | Geladene Cue-Snapshotidentität muss exakt zur veröffentlichten Proof passen; Runtime-Guard plus Lifecycle-Source-Prüfung |
| Alter Widget-Button springt in neue Folge | Aktion trug nur Kapitelindex | Zufällige veröffentlichte Timeline-ID muss übereinstimmen; echter ObjC-Action-Zweig getestet |
| Kaputter Checkpoint/Analyse hat formal gültiges JSON | Keine semantische Intervall-/Resume-Prüfung | Finite, geordnete, nicht überlappende Bereiche und passende Resume-Marke; echte Swift-Validatoren |
| Feed-Limit greift erst nach Vollpufferung | requests.get ohne stream, nachträglicher content-Check | Decodierte Chunks vor Append begrenzt; Apple-Lookup ebenfalls; unbekannte Länge und Kompression getestet |
| DNS/Discovery/langsamer Feed blockiert über Request-Timeout hinaus | Inaktivitäts-Timeout war kein Gesamtzeitlimit | Frischer überwachter Prozess, Gesamtlimit60s, Kill+Reap bei Timeout/Abbruch; echte Prozesse und HTTP-Verbindungen |
| Übergrössen erreichen Artifact-Parser/App-Puffer | Grössenchecks nach Vollpufferung bzw. ohne Publikationslimit | Vorprüfung25MiB je öffentlichem Artefakt; App1MiB für Envelope und25MiB für Artefakt, decoded chunk cap,120s Gesamttransferlimit |
| Cue liegt nach gemessener Audiodauer | Dauer wurde nur bei Kapitel-/Sponsor-JSON geprüft | Server und App prüfen SRT-Ende gegen gemessene, kanonische Millisekundendauer vor Publikation/Import |

Root-Transportprüfungen laufen auf tatsächlichem Server-Python3.10 in einem isolierten Verzeichnis. Sie erzeugen keine produktiven Aufträge und brauchen keine ASR-/KI-Aufrufe. Der Swift-HTTP-Test verwendet einen kontrollierten echten HTTP-Peer und prüft Grössen, Gesamtfrist, Abbruchrennen und25 gleichzeitige kleine gültige Antworten; das ist ausdrücklich kein Lasttest mit250 realen Nutzern oder grossen Artefakten.

Die vollständigen Backend-Übergänge und die zusätzlich nachgewiesenen Serverdefekte stehen in [der Backend-Matrix](2026-09-06-systematic-backend-audit.md). Die abschliessenden Detailberichte stehen unter [App](2026-09-06-systematic-app.md), [Playback/Import](2026-09-06-systematic-playback.md) und [Backend](2026-09-06-systematic-backend.md).


## Abschluss und Abnahme

- Echte Servermigration mit gestoppten API-/Worker-Prozessen und vollständiger Zieldatenbanksicherung nach `var/backups/systematic-reliability-20260906`.18 ausgelieferte Dateien entsprechen den dokumentierten SHA256-Werten. Alle bisherigen Spalteninhalte und Zeilen der sieben geprüften Tabellen sind unverändert; neue Herkunfts-/Retry-/Fehlerfelder und drei vollständige URL-Indizes sind verifiziert. Siehe [Deployment-Beleg](2026-09-06-systematic-deployment-verification.json) und [Dateimanifest](2026-09-06-systematic-reliability-manifest.json).
- Echte API liefert Schema2026-09-06.1,25/250-Grenzen,25MiB-Artefaktgrenze und neun explizit begrenzte numerische Retry-Schemafelder. API und Worker aktiv; Provider und Ressourcen im echten Dienstbenutzerkontext bereit. Bekannter Abbruch bleibt abgebrochen; unbekannte UUID liefert404. Keine Testjobs im produktiven Dienst erstellt. [API-Beleg](2026-09-06-systematic-live-verification.json).
- Alle28 aktuell fertigen Episoden bestehen die neuen Artefakt-/Dauerprüfungen beim lesenden Zugriff auf den echten Server. [Bestandsprüfung](2026-09-06-systematic-existing-artifacts.json).
-84 gemeinsame App-Scripts sind nach Integration grün. Neun anfängliche Fehler wurden gezielt geprüft: veraltete Harness-/Source-Annahmen aktualisiert; die tatsächliche Regression im gewöhnlichen Neustartdialog wurde korrigiert. Zusätzliche S3b-Tests führen die tatsächlichen Parser-/Analyse-/Dateicommit-Funktionen aus. Keine blosse Addition wiederholter/ererbter Tests als vermeintliche Vollabdeckung. [Einzelergebnisse](2026-09-06-systematic-app-checks.json).
- Ein-Millisekunden-SRT-Überlappung wurde mit tatsächlichem App-Parser reproduziert und im strikten Serverparser behoben; das reale vierteilige Server-Fixture wird angenommen, zehn gezielte Vertragskorruptionen werden abgelehnt. Die neue zweite Analyse-await-Grenze erhielt nach rotem Runtime-Proof eine zusätzliche Prüfung auf inzwischen gelöschte Episode, bevor beide Dateien geschrieben werden.
- Grössenmessung mit4.308.894 Bytes/43.200 Cues: vorher257,7ms MainActor-Blockade; danach Parser/JSON und Analyse im Utility-Task. MainActor-Heartbeat im Parserfall etwa30ms, im Analysefall2,05ms; tatsächlicher synchroner SRT-/Analyse-Dateicommit zuletzt11,25ms. Das sind optimierte Desktop-Harness-Messungen mit tatsächlichen Methoden, keine auf dem iPhone gemessenen Latenzgarantien.
- Release-Gerätebuild erfolgreich, Signatur und eingebettete Watch-Audio-Konfiguration geprüft.1380 relevante Build-/Quelldateien nach dem endgültigen Build unverändert. Release4.0(37) auf dem richtigen iPhone17Pro installiert und erfolgreich gestartet; kein TestFlight-Upload. [Build-/Installationsbeleg](2026-09-06-systematic-iphone-verification.json).

Wichtigste reproduzierbare lokale Prüfungen:

```sh
python3 Tools/server_transcription_storage_runtime_test.py
python3 Tools/transcription_local_storage_runtime_test.py
python3 Tools/server_transcription_retry_interval_runtime_test.py
python3 Tools/server_transcription_http_runtime_test.py
python3 Tools/server_transcription_import_episode_deletion_runtime_test.py
python3 Tools/server_sponsor_e2e_client_runtime_test.py
python3 Tools/playback_artifact_freshness_runtime_test.py
python3 Tools/playback_artifact_semantics_runtime_test.py
python3 Tools/server_artifact_validation_responsiveness_runtime_test.py
python3 Tools/server_analysis_responsiveness_runtime_test.py
python3 Tools/server_artifact_commit_tail_runtime_test.py
```

Serverprüfungen sind vollständig im Backend-Bericht aufgeführt und dürfen nur in isolierten Testverzeichnissen/-datenbanken ausgeführt werden. Letzter kombinierter finaler Serverstand: Feed9, Artefakt2, systematische Zustände22 (davon zwei MariaDB-spezifische Auslassungen), API4 grün; tatsächliche MariaDB57 plus beide abschliessenden HTTP-Klassifikationsfälle sowie die angrenzenden Restart-/Pipeline-/Reliability-Prüfungen gesondert grün.

## Verbleibende Freigabegrenzen

Technische Herkunfts- und Zustandsprüfungen beweisen nicht, dass ein probabilistisches Modell jedes Sponsoring in jeder Sprache korrekt erkennt. Offen bleiben echte Geräte-Lock/BG-/Speicherknappheitsprüfungen an allen Commitpunkten, ein gemessener250-Nutzer-Lasttest, lokale200h-Verarbeitung und eine repräsentative semantische Sponsor-Auswertung. Ein vollständiger Maschinen-Stromausfall und jeder denkbare DB-Verbindungsabbruch sind nicht durch SIGTERM-/SIGKILL-Tests abgedeckt. Eine erfolgreiche Provider-Antwort vor dauerhaftem Checkpoint/Usage-Commit kann ohne externe Idempotenzunterstützung nach einem Crash einen weiteren kostenpflichtigen Aufruf erfordern. Diese Grenzen sind ausdrücklich keine bestandenen Prüfungen und keine Zusage „keine Bugreports“.
