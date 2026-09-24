# Transkriptionsserver

## Zugriff

Produktiv: `https://transcript.instacast.ch`, Host `195.201.108.172`, SSH-Port `5000`, Benutzer `sshuser`. Der Dienst gehört zum separaten Virtualmin-Benutzer `instacast`; Änderungen nur im unten genannten Projekt und seinen Diensten durchführen.

Die benötigten SSH-Zugangsdaten liegen ausschließlich lokal in `.codex/private/transcription-server-login.json` (Modus `0600`, Verzeichnis `0700`). Andere Zugangsdaten aus dem beigefügten Dokument wurden nicht dauerhaft ins Projekt übernommen. Das ganze Verzeichnis ist über `.git/info/exclude` von Git ausgeschlossen. Niemals Zugangsdaten in Logs, Commits oder diese Dokumentation kopieren.

```sh
.codex/private/ssh 'sudo -n systemctl status transcript-instacast-api.service transcript-instacast-worker.service --no-pager'
```

Der lokale SSH-Wrapper benutzt den lokalen Askpass-Helper und eine eigene `known_hosts`. Das Passwort steht weder im Kommando noch in der Prozessliste. Bei einer Passwortänderung die private JSON-Datei aktualisieren; bei Änderungen an Host, Port oder Benutzer zusätzlich den SSH-Wrapper anpassen.

## Produktiver Code und Betrieb

- Projekt: `/home/instacast/domains/transcript.instacast.ch`
- Python: `.venv/bin/python`; API: `app/main.py`; Verarbeitung: `app/worker.py`; gemeinsame Queue: `app/service.py`
- API: `transcript-instacast-api.service`, zwei Uvicorn-Prozesse hinter Apache, intern Port `8765`
- Worker: `transcript-instacast-worker.service`; optionaler zweiter Dienst `transcript-instacast-worker-2.service`. Ein laufender Worker genügt bei der derzeitigen Grenze von einem gleichzeitig verarbeiteten Auftrag.
- MariaDB-Konfiguration: `var/app/db.env`, ausschließlich serverintern laden, niemals ausgeben.
- Read-only Status: `GET /health`; HTTP 503 bedeutet unter anderem, dass kein konfigurierter Worker läuft. `GET /api/v1/schema` beschreibt den API-Vertrag und benötigt Authentifizierung.

Die lokale Arbeitskopie unter `.codex/private/server-src` ist eine Momentaufnahme. Vor jeder späteren Änderung den aktuellen Serverstand neu abgleichen. Regressionstests mit temporärer SQLite-Datenbank bzw. einer eigenen temporären MariaDB-Datenbank ausführen; niemals Testaufträge in die Produktionsqueue schreiben.

## Gemeinsamer Queue-Vertrag

Die App nimmt maximal **25 offene Aufträge insgesamt** an, über lokale und serverseitige Verarbeitung hinweg. Fertige, fehlgeschlagene und abgebrochene Einträge sind Verlauf und belegen keinen offenen Platz. Vorhandene ältere Queues über dem Limit bleiben sichtbar; neue Aufträge werden erst unterhalb des Limits aufgenommen.

Der Server begrenzt offene Transkriptionsaufträge zusätzlich auf **25 je Client** und **250 insgesamt**. Wiederholte Abfragen eigener bestehender Aufträge und bereits fertige Ergebnisse bleiben möglich. Die Aufnahme samt Zählung und Client-Zuordnung muss über alle API-Prozesse atomar bleiben. Neue Aufträge benötigen einen tatsächlich laufenden Worker, einen verfügbaren KI-Anbieter und ausreichende Serverressourcen. `queued`, `running` und `paused` zählen gegen das Limit; laufende Worker werden unter derselben Datenbanksperre wie die Aufnahme gezählt und beansprucht.

Bei voller App-Queue erhält eine manuelle Aktion einen Dialog. Automatisch nicht aufgenommene Episoden erscheinen als Anzahl im Queue-Hinweis und können später manuell hinzugefügt werden; es wird keine weitere versteckte Warteliste angelegt. `TranscriptionQueueCapacitySkippedEpisodeHashes` speichert nur eindeutige Identitäten für diesen bestätigbaren lokalen Hinweis, keine Arbeitsaufträge und keine synchronisierte oder gesicherte Benutzereinstellung. Wiederholte Discovery-/Checkpoint-Verarbeitung zählt dieselbe Episode nicht erneut.

Status-Polls verändern nur sichtbare Statusinformationen. Unveränderte Antworten dürfen weder Tabellenzellen ersetzen noch identische Hintergrundaufträge erneut einreichen. Queue-Dateien werden seriell außerhalb des Main-Threads geschrieben; eine Discovery-Bestätigung darf erst nach erfolgreicher dauerhafter Speicherung erfolgen.

## Prüfung der App

Die isolierten Laufzeittests prüfen ihre jeweiligen Produktionspfade. Ein Build
oder ein erfolgreicher Lauf ist kein vollständiger App-/Server-E2E-Nachweis.
Für wiederholbare E2E-Artefakte gilt `AGENTS.md`.

```sh
python3 Tools/server_transcription_admission_runtime_test.py
python3 Tools/server_poll_lifecycle_runtime_test.py
python3 Tools/server_transcription_storage_runtime_test.py
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

Nach Serveränderungen die fokussierten Backendtests ausführen, nur die geprüften Dateien nach einem Abgleich mit dem Ausgangsstand und einer Sicherung übertragen, den API-Dienst neu starten und den öffentlichen Health-Endpunkt sowie echten Auftragsfortschritt prüfen. Einen laufenden Transkriptionsworker bei reinen API-Änderungen nicht unterbrechen.

## Serveränderung vom 5. September 2026

Die acht ausgelieferten Dateien sind mit Vorher-/Nachher-Prüfsummen in `transcription-server/2026-09-05-manifest.json` dokumentiert. `transcription-server/2026-09-05-queue-reliability.patch` enthält den vollständigen Patch inklusive Backendtests, ohne Zugangsdaten. Der Patch ist ein Änderungsnachweis; vor späteren Änderungen zuerst den dann aktuellen Serverstand lesen.

Die produktive Sicherung liegt unter `var/backups/queue-reliability-20260905`. Sie enthält die ursprünglichen Dateien samt Besitz-/Rechtemetadaten und die gesicherten Datenbankzeilen der drei wegen HTTP 402 fehlgeschlagenen Aufträge 2400–2402. Diese Aufträge wurden wieder in die Queue aufgenommen. Andere historische oder pausierte Aufträge wurden nicht verändert.

Der Worker prüft vor der Übernahme neuer Transkriptionen die tatsächliche Dienstverfügbarkeit. Für DeepSeek dient der offizielle lesende [Guthaben-Endpunkt](https://api-docs.deepseek.com/api/get-user-balance/); die Antwort wird je Prozess für höchstens 30 Sekunden gecacht. Fehlendes Guthaben blockiert neue Annahmen und Verarbeitung. Eine erst während der Verarbeitung auftretende HTTP 402 erhält Auftrag und Zwischenstände, ohne einen Fehlversuch zu verbrauchen. Nach Wiederherstellung der Verfügbarkeit arbeitet der laufende Worker automatisch weiter. Die API informiert wartende Clients über `service_status` mit einem erneuten Prüfzeitpunkt von 300 Sekunden.

Beim ersten Eingriff am 5. September wurde live verifiziert: API und Worker liefen, 75 bestehende Transkriptionsaufträge warteten ohne neue Fehlversuche bei fehlendem DeepSeek-Guthaben. `/health` antwortete dabei korrekt mit HTTP 503 und `provider_unavailable`. Dieser Zwischenstand wurde anschließend durch die unten beschriebene Lifecycle-/OAuth-Änderung abgelöst.

Backendtests, jeweils mit isolierten Testdaten (MariaDB legt eine eigene Datenbank an und entfernt sie anschließend):

```sh
.codex/private/ssh 'sudo -n /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/tools/queue_admission_regression.py'
.codex/private/ssh 'sudo -n /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/tools/queue_admission_mysql_regression.py'
.codex/private/ssh 'sudo -n /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/tools/podcast_contract_regression.py'
.codex/private/ssh 'sudo -n /home/instacast/domains/transcript.instacast.ch/.venv/bin/python /home/instacast/domains/transcript.instacast.ch/tools/api_contract_v3_regression.py'
```

Validiert: 19 SQLite-, 19 MariaDB-, 2 Podcast- und 4 API-Vertragstests. Der App-Simulator-Build und die fokussierten Queue-, Persistenz-, Gesten- und Lokalisierungsprüfungen bestehen ebenfalls.

## Dauerhafter Auftrag und Abbruch

Neue App-Versionen speichern eine Request-UUID dauerhaft **vor** dem POST. Ein verlorenes HTTP-Ergebnis verwendet beim nächsten Versuch dieselbe UUID. Der Server bindet sie an den vollständigen Hash der Client-Identität und die Episoden-URL. Eine andere URL unter derselben UUID ergibt `409 request_conflict`.

- `GET /api/v1/client-requests/{uuid}` liefert den eigenen Auftrag. `404 request_not_found` erlaubt eine erneute Übermittlung derselben UUID.
- `DELETE /api/v1/client-requests/{uuid}` liefert eine idempotente Abbruchbestätigung. Auch ein noch unbekannter Request erhält einen dauerhaften Abbruch-Eintrag, der einen verspäteten POST verhindert.
- `410 request_canceled` bzw. `request_deleted` sind endgültig. Automatische Discovery, Feed-Scans und Wiederholungen dürfen diese Zustände nicht reaktivieren.
- Die App speichert unbestätigte Abbrüche dauerhaft und sendet sie nach Netzrückkehr oder Neustart erneut. Erst eine passende Serverbestätigung erledigt diese Absicht. Ein ausdrücklicher neuer Versuch erhält eine neue UUID, nachdem der alte Abbruch bestätigt wurde.
- Ein einzelner Client beendet nur seinen eigenen Auftrag. Nutzen andere Clients dieselbe Episode, läuft deren gemeinsame Verarbeitung weiter. Ein Betreiberabbruch beendet alle zugehörigen Interessen.

Für alte App-Aufträge gibt es `DELETE /api/v1/episodes/{id}/client-request`. Historische verkürzte Client-Anzeigenamen werden nur bei eindeutigem Bezug zur vollständigen gespeicherten Identität migriert; mehrdeutige Besitzverhältnisse werden ausdrücklich abgelehnt. Abbruch-Einträge müssen dauerhaft erhalten bleiben, auch wenn Episodendaten später gelöscht werden.

Jede Worker-Übernahme besitzt einen eigenen Claim. Fortschritt, Ergebnisse und Endzustand dürfen nur vom weiterhin berechtigten Claim geschrieben werden. Ausgaben liegen pro Claim getrennt, damit ein alter Prozess keine Dateien des neu gestarteten Auftrags überschreiben kann. `jobs.checkpoint_claim_token` merkt sich unabhängig davon das vollständig vorbereitete Checkpoint-Verzeichnis: Ein Absturz zwischen neuer Übernahme und Kopie verliert dadurch nicht die bisherigen Ergebnisse. Die Audioquelle wird mit Größe und SHA-256 geprüft und unverändert übernommen; eine erneut heruntergeladene dynamische Werbevariante darf nicht mit einem alten Transkript kombiniert werden. Alt-Checkpoints ohne erhaltene Audioquelle erfordern einen ausdrücklichen neuen Auftrag.

Die Regressionen prüfen unter anderem Abbruch während HTTP-Anfragen und Downloads, verlorene Bestätigungen, Offline-Abbruch, App-Neustart, gemeinsame Episoden, Absturz während der Checkpoint-Übernahme und verspätete Ergebnisschreibvorgänge.

## OpenAI-Inklusivvolumen und Kosten

Der temporäre OpenAI-Standard ist `openai_codex` mit `gpt-5.6-sol`. Die offizielle Codex CLI läuft unter dem eigenen Dienstbenutzer `instacast` und dessen separat bestätigter ChatGPT-Anmeldung. Die OAuth-Dateien bleiben im geschützten Home-Verzeichnis dieses Dienstbenutzers und werden weder ins Projekt noch in andere Konten kopiert. Neue Anmeldung bei Bedarf über `sudo -n -H -u instacast codex login --device-auth`.

Geprüfte CLI-Version: `0.154.0` (15.09.2026). Der Text-Modellkatalog liegt unter `var/app/codex-models.json`; er wird aus dem tatsächlichen Modellkatalog des angemeldeten Kontos abgeleitet. Die Integration deaktiviert sämtliche Tools und führt jede Anfrage ohne Projektkontext in einem eigenen temporären Verzeichnis aus. Ein Test gegen einen lokalen Mock-Endpunkt prüft tatsächlich `tools=[]`. Andere CLI-Versionen oder ein ungeprüfter Katalog stoppen die Verarbeitung mit einem Konfigurationshinweis.

Vor der Annahme bzw. Verarbeitung werden die tatsächliche Anmeldung und die offiziellen Kontingentgrenzen gelesen. Fehlendes Inklusivvolumen, fehlende Anmeldung, API-Guthabenmangel oder ein unzureichendes konfiguriertes API-Monatsbudget pausieren die Verarbeitung mit einer sichtbaren Begründung. Sie verbrauchen keine Fehlversuche der Episode. Es gibt keinen automatischen Wechsel zu einem kostenpflichtigen API-Anbieter. Die Integration kauft weder Credits noch Nutzungs-Resets.

OpenAI-Nutzung wird mit Tokens, Job-ID und `billing_mode=chatgpt_subscription` erfasst; der Einzelpreis ist unbekannt und erscheint als „Inklusivvolumen“. API-Kosten bleiben ausdrücklich Schätzungen. Auch inhaltlich ungültige bezahlte Antworten behalten ihre gemeldeten Tokens. Details zu den ursprünglichen 10 USD, historischen Kosten und verfügbaren Modellen: [Kostenprüfung](transcription-server/cost-audit-2026-09-05.md).

Zusätzliche App-Prüfungen:

```sh
python3 Tools/server_transcription_cancellation_runtime_test.py
```

Zusätzliche Backend-Prüfungen mit isolierten Datenbanken, aus dem Serverprojekt:

```sh
.venv/bin/python tools/lifecycle_regression.py
sudo .venv/bin/python tools/queue_admission_mysql_regression.py --lifecycle
.venv/bin/python tools/atomic_publication_regression.py
.venv/bin/python tools/ai_budget_regression.py
.venv/bin/python tools/ai_usage_accounting_regression.py
.venv/bin/python tools/codex_provider_regression.py
.venv/bin/python tools/provider_polling_regression.py
```

## Verifizierte Auslieferung der Lifecycle-/OAuth-Änderung

Am 5. September 2026 wurden **17 geprüfte Dateien** nach Abgleich aller Ausgangs-Prüfsummen ausgeliefert. Änderungsnachweis: `transcription-server/2026-09-05-lifecycle-oauth.patch` und `transcription-server/2026-09-05-lifecycle-oauth-manifest.json`. Vor späteren Änderungen immer den dann aktuellen Serverstand neu prüfen.

Sicherung: `var/backups/lifecycle-oauth-20260905`, nur für den Administrator zugänglich. Sie enthält einen vollständigen komprimierten SQL-Dump der App-Datenbank vor dem Eingriff, die vorherigen Quelldateien, Dateimetadaten, Manifest und Abbruch-/Prüfprotokolle. `init_db()` wurde bei gestoppten API-Prozessen und Workern einmal ausgeführt; danach wurden 77 offene Transkriptionsaufträge einschließlich der zwei pausierten Aufträge atomar abgebrochen. Es entstanden 76 Abbruch-Einträge für belegte Client-Interessen; ein Auftrag hatte kein solches Interesse. Die 46 fertigen Jobs blieben erhalten.

Live geprüft nach Dienststart:

- 17 produktive Datei-Prüfsummen entsprechen dem ausgelieferten Manifest.
- API und ein Worker laufen; kein offener oder laufender Auftrag, keine automatisch aktivierten Podcasts.
- `/health`: HTTP 200, `ok: true`, `queued_jobs: 0`, `running_jobs: 0`.
- Authentifiziertes `GET /api/v1/episodes/30`: HTTP 200, `status: canceled`.
- Neuer Request-Endpunkt: für eine unbekannte UUID HTTP 404 mit `request_not_found`; die Schema-Antwort enthält die Abbruch-Endpunkte.
- Tatsächliche OpenAI-Anmeldung und Kontingentabfrage unter `instacast` erfolgreich. Beim Abschluss 10 % Wochenkontingent verbraucht; diese Zahl ist eine Momentaufnahme des geteilten Kontos.

Validierung: 56 SQLite-Lifecycle-, 37 MariaDB-Lifecycle-, 1 Atomic-Publication-, 4 API-, 2 Podcast-, 12 Pipeline-Resume-, 4 Budget-, 5 Nutzungsabrechnungs-, 14 Codex-Adapter- und 2 Provider-Polling-Tests bestanden. Der isolierte Servermodell-Statustest besteht. Der vollständige historische Servermodell-Test benötigt zusätzlich archivierte Produktionsartefakte, die in der isolierten Testumgebung fehlen. Der Tool-Inventartest bestätigt `tools=[]` ohne Inferenz.

Ein echter OAuth-Test durch den Worker erzeugte und speicherte eine deutsche Zusammenfassung samt 3.860 Eingabe- und 101 Ausgabetokens in einer isolierten Datenbank. Nachweis: `transcription-server/2026-09-05-openai-smoke.json`. Das prüft den realen KI-/Buchhaltungspfad, keinen vollständigen neuen Audio-zu-Episode-Durchlauf. Ein solcher wurde nicht durch Wiederaufnahme der vom Nutzer ausdrücklich abgebrochenen Aufträge ausgelöst.

Der iOS-Simulator-Build und die fokussierten App-Regressionen inklusive acht ausführbaren Swift-Abbruchszenarien bestehen. Die App-Änderungen liegen lokal im Projekt; mit diesem Eingriff wurde kein neuer TestFlight-Build hochgeladen. Für den vollständigen automatischen Abbruchabgleich und die neuen Queue-Hinweise benötigen Kunden diese App-Version.


## Annahme und Fehlerzustände – 6. September 2026

Die App unterscheidet dauerhaft `pending` (noch nicht gesendet), `unconfirmed` (Annahme nach Versand unklar), `accepted` und `rejected`. Erst eine gültige Serverbestätigung zeigt einen angenommenen Auftrag an. Die Prüfung einer Annahme reserviert einen der 25 Plätze, damit gleichzeitige Bedienaktionen das App-Limit nicht überschreiten.

| Ereignis | Verhalten |
| --- | --- |
| Kein Internet vor dem POST, lokaler Speicherfehler | Keine HTTP-Anfrage; keine Annahme, verständliche Fehlermeldung, Platz wieder frei. |
| Server/Worker/Provider nicht bereit, kein Guthaben oder Kontingent, zu wenig Ressourcen, Queue voll | Server bestätigt `error.admitted: false`; App lehnt ab und zeigt den konkreten Grund. Keine versteckte Wiederaufnahme. |
| Antwort nach POST verloren, Proxyfehler oder ungültige Erfolgsmeldung | Annahme bleibt ausdrücklich unbestätigt. Abgleich derselben UUID vor erneutem POST verhindert doppelte Aufträge. Ein bloßer Verbindungsfehler beweist keine Ablehnung. |
| App-Neustart | Angenommene/unbestätigte Aufträge werden abgeglichen. Ein lediglich lokal vorbereitetes `pending` wird als nicht hinzugefügt wiederhergestellt und braucht einen ausdrücklichen neuen Versuch. |
| Ausfall nach bestätigter Annahme | Identität und Zwischenstände bleiben erhalten; sichtbarer Wartegrund. Ein langer Offline-Zeitraum allein beendet keinen Auftrag. |
| Serverabbruch oder Löschung | Dauerhafte Abbruch-Einträge führen beim nächsten erfolgreichen Abgleich zum Abbruch in der App. Offline ist ein sofortiger Abgleich technisch unmöglich. |
| App-Abbruch während Offlinephase | Lokale Abbruchabsicht bleibt dauerhaft gespeichert und wird nach Netzrückkehr bestätigt; verspätete Ergebnisse dürfen sie nicht überschreiben. |
| Worker abgestürzt oder Verarbeitung hängt | Abgelaufene Claims werden periodisch und gegen parallele Erneuerung gesichert übernommen. Begrenzte Fehlversuche; Unterprozesse haben 6 Stunden Höchstdauer und 30 Minuten ohne Fortschritt als Stillstandsgrenze. Ein Dienststopp beendet den Prozessbaum. |
| Anbieter fällt während Verarbeitung aus | Gemeinsame Pause über alle Worker/API-Prozesse; Authentifizierungs-/Kontingentfehler verbrauchen keine Episodenversuche. Tatsächliche Verarbeitungszeitüberschreitungen bleiben begrenzt wiederholbar. |

Statusabfragen, neue Aufträge und Abbrüche besitzen getrennte begrenzte Anfragebudgets. Ein voller Lesebudget-Zähler blockiert keinen authentifizierten Abbruch. Standard pro Client: 250 Leseanfragen/Minute, 50 Abbrüche/Minute und 240 neue Anfragen/Stunde; IP- und Tokenbudgets werden separat geprüft. Zähler werden auch beim parallelen ersten Zugriff atomar angelegt. Identische Statusantworten erzeugen keine sichtbaren Queue-Änderungen; Hintergrundarbeit erhält dafür getrennte Aktivitätsmeldungen.

## Sponsor-Ergebnisse und die tatsächlich abgespielte Audiodatei

Die analysierte Audioquelle besitzt einen serverseitig gemessenen SHA-256-Wert, der in `episode.media.audio_sha256` nach dem Löschen temporärer Audiofiles erhalten bleibt. Lokale Zwischenstände, Transkripte und generierte Analyseergebnisse sind ebenfalls an die konkrete Audioquelle gebunden. Hashlose oder abweichende Zwischenstände dürfen keine alten Cues in eine neue dynamische Werbevariante mischen.

Automatisches Überspringen anhand generierter Zeitmarken ist erst erlaubt, wenn die vollständigen aktuellen Audiodaten mit dieser Quelle übereinstimmen. Generierte Transkripte werden ebenfalls erst nach erfolgreicher Audioprüfung geladen; ungeprüfte Ergebnisse werden auch aus dem Cache nicht angezeigt. Beim Streaming kann die Prüfung nach erfolgreichem Abschluss des eigenen Cache-Imports erfolgen; ein alter Import darf keinen neuen Player freischalten. Eine noch laufende Prüfung erzeugt keine Fehlermeldung; eine fehlgeschlagene abgeschlossene Prüfung gibt keine generierten Zeitmarken frei.

Änderungen der effektiven Skip-Einstellungen gelten beim nächsten Abspielen einer Marke unmittelbar. Ein manueller Sprung in ein Sponsorsegment am Episodenende darf die Episode nicht automatisch als gehört abschließen.

Ein vollständiger isolierter Test lief durch Whisper, echte OpenAI-Inferenz, Sponsor-/Kapitelanalyse und Veröffentlichung aller vier App-Artefakte. Die synthetische deutsche Audiofolge dauert 114,84 Sekunden. Referenzwerbung: **44,269524–71,829252 Sekunden**; erkannt: **44,31–71,69 Sekunden**, „Sponsor: Beispiel Kaffee“. Die zwölf KI-Aufrufe wurden als Inklusivvolumen erfasst. Nachweis: [Audio-End-to-End-Protokoll](transcription-server/2026-09-06-sponsor-e2e.json). Es wurden keine abgebrochenen Kundenaufträge wieder aktiviert.

Die tatsächlichen Swift-Decoder und App-Validatoren akzeptieren diese vier Artefakte mit 28 Cues, zwei Kapiteln und einem Sponsorsegment. Fünf gezielte Beschädigungen werden abgelehnt: falsche Revision, falsche Dauer, Sponsorüberlappung, ungültige SRT-Zeitzeile und überlappende Cues. Weitere native Laufzeittests prüfen Audioidentität, Live-Einstellungen und Skip-Grenzen. Ein einzelner erfolgreicher Audiofall beweist keine fehlerfreie KI-Erkennung für beliebige Podcasts; 14 vorhandene historische Referenzfälle wurden zusätzlich lesend geprüft, sie sind kein Benchmark des neuen OpenAI-Modells.

Aktuelle fokussierte App-Prüfungen:

```sh
python3 Tools/server_transcription_admission_runtime_test.py
python3 Tools/server_transcription_cancellation_runtime_test.py
python3 Tools/server_poll_lifecycle_runtime_test.py
python3 Tools/server_sponsor_e2e_client_runtime_test.py
python3 Tools/transcription_audio_identity_runtime_test.py
python3 Tools/playback_autoskip_live_settings_runtime_test.py
```

Der abschließende iOS-Simulator-Build besteht; die App wurde auf dem vorhandenen iOS-26.3-Simulator installiert und gestartet. Damit ist das Verhalten auf der gemeldeten iOS-27-Beta noch nicht vollständig am Gerät geprüft. Kein TestFlight-Upload wurde ausgeführt.

## Verifizierte Auslieferung vom 6. September 2026

**12 geprüfte Dateien** wurden nach vollständigem Abgleich ihrer produktiven Ausgangs-Prüfsummen atomar ersetzt. Patch und Manifest liegen unter `transcription-server/2026-09-06-capacity-sponsor.patch` bzw. `transcription-server/2026-09-06-capacity-sponsor-manifest.json`. Die Sicherung `var/backups/capacity-sponsor-20260906` enthält den vollständigen komprimierten SQL-Dump, bisherige Quelldateien, Besitz-/Rechtemetadaten und Migrationsprüfung.

API und Worker waren während `init_db()` gestoppt. Die neue Audiospalte und alle zwölf Datei-Prüfsummen wurden überprüft. Die Jobzahlen blieben unverändert: 77 Transkriptionsjobs abgebrochen, 46 fertig, keine offenen Transkriptionen. Beide Dienste wurden erfolgreich gestartet.

Der öffentliche authentifizierte API-Vertrag bestätigt tatsächlich **250 insgesamt und 25 je Client**, einschließlich pausierter Jobs, sowie die getrennten Anfragebudgets. `/health` antwortet mit HTTP 200 und null wartenden/laufenden Aufträgen. Episode 30 bleibt `canceled`; eine unbekannte Request-UUID liefert korrekt `404 request_not_found`. Nachweis: [Live-Prüfung](transcription-server/2026-09-06-live-verification.json). Die Prüfung legte keine Produktionsjobs an.

Die finalen Backendtests bestehen: 88 SQLite- und 51 MariaDB-Zuverlässigkeitsfälle, je vier zusätzliche SQLite-/MariaDB-Rate-Limit-Fälle, vier API-, zwei Podcast-, ein Veröffentlichungs-, vier Budget-, fünf Nutzungsabrechnungs-, zwei Provider-Polling- und 14 Codex-Adapterfälle. MariaDB-Tests verwenden eigene kurzlebige Datenbanken, die danach entfernt werden.

```sh
# Aus dem Serverprojekt; Regressionstests isolieren ihre Daten selbst.
.venv/bin/python tools/server_capacity_policy_regression.py
.venv/bin/python tools/server_reliability_regression.py
sudo .venv/bin/python tools/queue_admission_mysql_regression.py --reliability
.venv/bin/python tools/rate_limit_regression.py
sudo .venv/bin/python tools/queue_admission_mysql_regression.py --rates
```

Die breitere lokale Prüfung umfasste 73 Transkriptions-/Kapitel-/Sponsor-/Playback-Testskripte. 72 bestanden unmittelbar; ein veralteter Quellcode-Test erwartete die frühere direkte Hintergrundscheduler-Zuweisung. Nach Prüfung des tatsächlichen Datenflusses wurde diese Testannahme korrigiert und der Test erfolgreich wiederholt. Anschließend bestanden die finalen ausführbaren Annahme-, Polling-, Audioidentitäts-, Sponsorartefakt- und Playback-Prüfungen sowie der vollständige iOS-Simulator-Build und der App-Start.

Die abschließende lesende Abfrage des echten OpenAI-Kontos zeigte 40 % verbrauchtes Wochenkontingent, also 60 % verbleibend. Das ist der aktuelle Stand des geteilten Kontos und keine Zuordnung dieses Verbrauchs zum Server-Test. Es wurden weder Guthaben noch Resets gekauft oder eingelöst.


## Zusätzliche Grenzfälle und Audio-Zeitmarken

Die erneute Prüfung der konkret angefragten Grenzfälle fand weitere echte Lücken: fehlende Dauergrenze, keine harte Gesamtdauer für Download/ffprobe, generische Wiederholungen dauerhafter Quellfehler, unzureichende Behandlung von ENOSPC während laufender Arbeit, ein gemeinsam beschreibbarer ASR-Chunkordner und ungeprüfte manuelle Kapitel-/Transkriptsprünge. Die früheren erfolgreichen Prüfungen deckten diese Wege noch nicht vollständig ab.

Die Serververarbeitung unterstützt jetzt höchstens **24 Stunden gemessene Audiodauer** und **750 MiB Audiodaten**. Der Wert von 24 Stunden ist die vorläufige Betriebsentscheidung aus dieser Aufgabe, keine technische Whisper-Grenze. Die optionale Rückfrage dazu blieb zunächst unbeantwortet. Die App verwendet für Fehlermeldungen die tatsächlich vom Server gemeldete Grenze. Falsche Feed-/Client-Dauern werden nicht zur Wahrheit erklärt; die verbindliche Prüfung erfolgt an der heruntergeladenen Datei vor ASR. Ein 200-Stunden-Ergebnis wird daher nicht erzeugt. Damit ist auch die zuvor mögliche Inkonsistenz zwischen beliebig langen Server-SRT-Stunden und dem zweistelligen kanonischen App-Import ausgeschlossen.

Der Audio-Download besitzt eine harte Gesamtdauer von einer Stunde einschließlich blockierter Netzwerkoperationen; ein separater, beaufsichtigter Prozess erlaubt den tatsächlichen Abbruch. `ffprobe` hat 60 Sekunden. Die bisherigen Zeitgrenzen für Verarbeitungsschritte bleiben zusätzlich bestehen. Bytefortschritt und Abbruchfähigkeit bleiben erhalten.

HTTP404/410 der Audioquelle ergeben `source_audio_unavailable`, einen finalen Verarbeitungsfehler ohne drei automatische Wiederholungen. Das ist kein Abbruch des Client-Auftrags durch den Betreiber. Zu große Dateien, zu lange/ungültige Audiodauer, leere Sprachergebnisse und ausdrücklich nicht unterstützte konfigurierte Sprachen erhalten eigene Fehlercodes und DE/EN-Texte. Eine akzeptierte Episode kann erst während dieser inhaltlichen Prüfung scheitern; Annahme bestätigt die Aufnahme, nicht die erfolgreiche Verarbeitbarkeit einer noch unbekannten Datei.

Während Download, Prozessüberwachung, Checkpoint-Kopie und Veröffentlichung wird der Speicherzustand erneut geprüft. ENOSPC und EDQUOT werden als Ressourcenpause behandelt und verbrauchen keine Episodenversuche. Aktive Verarbeitung wird nicht wegen ihrer eigenen normalen CPU-/RAM-Belegung immer wieder neu gestartet. Scheitert wegen eines vollständigen Speicherausfalls auch die Datenbank selbst, kann kein Dienst noch zuverlässig einen neuen Status speichern; die App muss den bereits angenommenen Auftrag bei Verbindungs-/Serverfehlern behalten und nach Wiederherstellung abgleichen.

ASR-Teilresultate liegen nun im privaten Claimverzeichnis unter `asr-work`. Nur atomar vollständig geschriebene Chunk-JSONs werden in einen Nachfolger kopiert. Vor Wiederverwendung werden Audio-SHA, Pipeline-Revision, Modell, Sprache, Decodierungsparameter und Chunk-Geometrie verglichen. Ein alter Worker schreibt ausschließlich in sein altes Verzeichnis. Pausierte aktive Quellen und Chunk-Zwischenstände sind vor der Aufräumroutine geschützt. Legacy-Teilresultate ohne nachweisbare Quellbindung werden nicht blind übernommen.

Die zusätzliche Prozessprüfung startet echte Worker-Unterprozesse mit isolierter SQLite-Datenbank, unterbricht sie per SIGTERM beziehungsweise SIGKILL und startet einen Nachfolger. Sie prüft dieselbe Job-ID, neuen Claim, erhaltene Audio-/Analyse-Checkpoints, Fortschritt, Versuchszähler und verweigerte Veröffentlichung durch den alten Claim. ASR/Netzwerk/Modellinferenz sind in diesem Lebenszyklustest nicht beteiligt. Die Chunk-Tests prüfen die darunterliegende Wiederverwendung separat.

Die Quellbindung gilt jetzt auch für **angezeigte generierte Kapitel, manuelles Kapitel-Antippen, Kapitelende-Sprünge sowie Antippen und Mitlaufen von Transkriptzeilen**. Generierte Kapitel bleiben bis zur passenden Audioprüfung zurückgehalten; SRT und Kapitel werden getrennt gegen denselben tatsächlich berechneten Audiohash geprüft. Auch das Laden und Anzeigen des generierten Transkripttexts setzt die aktuelle Audioprüfung voraus. Ein fehlender/abweichender Hash, ein Neustart, ein Episodenwechsel oder eine ersetzte SRT-Datei dürfen keinen alten Nachweis übernehmen. Gleichnamige asynchrone Ladevorgänge sind zusätzlich durch eine Generation getrennt. Originale Publisher-/eingebettete Kapitel behalten ihren bisherigen unabhängigen Quellpfad.

Bei dynamisch eingefügter Werbung gibt es keine belastbare allgemeine Zeitverschiebung zwischen zwei Fassungen. Die App behauptet daher nicht, ungeprüfte Server-Zeitmarken passten zur Kundendatei. Die sichere Sperre allein erzeugt noch keine neue Analyse der abweichenden Kundendatei; dafür ist eine Analyse genau dieser Audiodaten nötig.

**Spracherkennung bleibt eine Modellgrenze:** Eine ausdrücklich ungültige Spracheinstellung und ein leeres Ergebnis lassen sich zuverlässig ablehnen. Eine unbekannte gesprochene Sprache kann Whisper jedoch einer unterstützten Sprache zuordnen und trotzdem falschen plausiblen Text liefern. Es wurde kein willkürlicher Konfidenzschwellwert eingeführt, der eine sichere Erkennung vortäuschen würde. OpenAI dokumentiert ungleichmäßige Sprachqualität und mögliche Halluzinationen in der [Whisper-Modellkarte](https://github.com/openai/whisper/blob/main/model-card.md). Auch mit korrekter Audioidentität ist KI-Sponsorerkennung keine mathematisch sichere Inhaltsprüfung.

Die 24-Stunden-Grenze betrifft die Serververarbeitung. Lokales Whisper verarbeitet Audio in begrenzten Blöcken; die gesamte Cue-/Checkpointliste wächst jedoch mit der Aufnahmedauer. Es wurde kein lokaler 200-Stunden-End-to-End-Test ausgeführt und keine entsprechende Garantie abgeleitet.

Zusätzliche App-Prüfungen:

```sh
python3 Tools/transcription_input_errors_runtime_test.py
python3 Tools/transcription_whisper_language_regression_test.py
python3 Tools/server_transcription_errors_runtime_test.py
python3 Tools/transcription_audio_identity_runtime_test.py
python3 Tools/playback_autoskip_live_settings_runtime_test.py
```

Zusätzliche Backend-Prüfungen mit isolierten Datenbanken:

```sh
.venv/bin/python tools/worker_edge_cases_regression.py
sudo .venv/bin/python tools/queue_admission_mysql_regression.py --edge-cases
.venv/bin/python tools/worker_restart_process_regression.py
.venv/bin/python tools/pipeline_resume_regression.py
```


### Auslieferung und tatsächlicher Neustartnachweis

Die zehn Dateien der Grenzfallkorrektur wurden nach Quellcode-Abgleich und vollständigem SQL-Backup unter `var/backups/edge-cases-20260906` ausgeliefert. Patch/Prüfsummen: `transcription-server/2026-09-06-edge-cases.patch` und `transcription-server/2026-09-06-edge-cases-manifest.json`. Es war keine Datenbankmigration nötig. Die Aufträge blieben unverändert: 77 abgebrochen, 46 fertig sowie der neue reguläre Auftrag 2475. Vor dem Stopp wurde dessen vollständiger Rohtranskript-Checkpoint abgewartet.

Beim echten systemd-Stopp wurde zusätzlich ein bisher nicht abgedecktes Rennen zwischen Worker-SIGTERM und dem gleichzeitig beendeten Codex-Unterprozess sichtbar. Der Unterprozess konnte aus `communicate()` zurückkehren, bevor die Schleife den gesetzten Abbruchstatus erneut prüfte. Sein Exit wurde dadurch fälschlich als Anbieterausfall mit fünf Minuten Pause behandelt. Der Auftrag blieb mit null verbrauchten Versuchen und vollständigem Checkpoint erhalten. Eine separate offizielle Providerprüfung bestätigte gültige Anmeldung und verfügbares Kontingent.

Zwei neue Tests reproduzierten zuerst genau diese Fehlklassifizierung, darunter echte SIGTERM-Signale an Worker und CLI. Der Provideradapter prüft den Abbruchstatus jetzt unmittelbar nach `communicate()` und vor der Auswertung des Exit-Codes. Alle 16 Adapter- und fünf Usage-Tests bestehen. Die zwei Dateien wurden separat unter `var/backups/provider-stop-20260906` gesichert und ausgeliefert; Nachweis: `transcription-server/2026-09-06-provider-stop.patch` und zugehöriges Manifest. Die bereits entstandene kurzzeitige Sperre wurde nicht durch einen pauschalen manuellen Eingriff übergangen.

Finale Grenzfallvalidierung: 19 gezielte Edge-Tests, 38 MariaDB-Edge-/Basisprüfungen, 88 SQLite- und 51 MariaDB-Zuverlässigkeitsprüfungen, zwölf Pipeline-, vier API- sowie echte SIGTERM-/SIGKILL-Neustartprüfungen. Die breitere App-Prüfung umfasste 78 Skripte; 74 bestanden unmittelbar. Vier Tests enthielten veraltete Source-Pins für die ausgelagerte Kapitelveröffentlichung bzw. die getrennte Processing-Notification. Ihre fachlichen Invarianten wurden beibehalten und erweitert; alle vier sowie die angrenzenden Runtime-Tests bestehen nach der reinen Testkorrektur. Der erfolgreiche integrierte iOS-Simulator-Build blieb dabei unverändert und wurde anschließend installiert und gestartet.

Live nach Ablauf der korrekt begrenzten Pause bestätigt: Auftrag **2475** läuft unter neuem Claim mit **Versuchszähler 1** in der Nachverarbeitung weiter. Alle vier kopierten Rohtranskript-Dateien entsprechen exakt den gesicherten Prüfsummen; die Audioidentität ist unverändert und das neue Prozesslog enthält keinen erneuten ASR-Aufruf. Nachweis: [Tatsächliche Fortsetzung nach Neustart](transcription-server/2026-09-06-live-job-resume.json). Der öffentliche API-Vertrag und der gesunde Health-Zustand sind in [Live-Grenzfallprüfung](transcription-server/2026-09-06-edge-live-verification.json) dokumentiert. Die neuen App-Funktionen sind lokal gebaut und getestet; ein TestFlight-Upload gehört weiterhin nicht zu diesem Eingriff.


## Systematische Zustandsprüfung und Deployment — 6. September 2026

Nach den vorigen Einzelkorrekturen wurden App, Server und Playback anhand gemeinsamer Zustandsinvarianten und Fehlergrenzen geprüft. Ergebnis, Belege, konkrete Nachprüfungen und ausdrücklich offene Freigabegrenzen: [systematic-reliability-audit-2026-09-06.md](transcription-server/systematic-reliability-audit-2026-09-06.md).

Serverstand: Schema2026-09-06.1, Backup `var/backups/systematic-reliability-20260906`,18 verifizierte ausgelieferte Dateien. Neue dauerhafte Fehler-/Retry-/Quellenfelder sowie volle SHA256-URL-Indizes; alte Dateninhalte unverändert. Neue Annahme weiterhin App25/Server250 aktive Aufträge. Feed25MiB/60s, öffentliches Artefakt25MiB; App-Envelope1MiB/Transfer120s. Schema-Retrymaximum86400s begrenzt nur einen Abfragehinweis, nicht die Lebenszeit angenommener Aufträge.

App: atomarer Queue-Owner, kein Überschreiben unbekannter Queue-/Outbox-Dateien, klare Storage-Recovery, exakte Artefakt-/Timelinebindung bis zur Navigation, Importauswertung im Utility-Task mit erneuter Besitzer-/Episodenprüfung vor Commit. Release4.0(37) direkt auf Chris’ iPhone17Pro installiert und gestartet; kein TestFlight-Upload. Die Detailmatrix unterscheidet gezielte Runtime-Nachweise, echte Infrastrukturprüfung und noch ungetestete Last-/Geräte-/Modellqualität.

## Korrekte Fortschrittsanzeige — 6. September 2026

Die bisher öffentlich gelieferten Zahlen waren gewichtete Pipelinewerte, keine messbaren Gesamtprozente. Schema `2026-09-06.2` liefert bei aktiven Aufträgen `progress: null` und weiterhin die tatsächliche `phase`; nur ein vollständig geprüftes Ergebnis hat `progress: 1.0`. Die App zeigt vier benannte Schritte (Download, Transkription, Analyse, Ergebnisvorbereitung) ohne Prozentbalken. Die Schritte können unterschiedlich lange dauern und nach einem Neustart erneut durchlaufen werden. Alte Testclients, die numerischen aktiven Fortschritt erzwingen, benötigen das zugehörige App-Update.

Die Meldungen zur Bestätigung verwenden verständliche DE/EN-Texte. Der normale Versand wird nicht mehr mit „Serveraufnahme unbestätigt“ überschrieben. Fehlende Bestätigungen werden weiterhin über dieselbe Request-ID abgefragt, ohne den Nutzer zur Vermeidung doppelter Aufträge aufzufordern. Beim Wiederherstellen werden alte gewichtete Zahlen verworfen und der alte Hinweis für unbestätigte Anfragen erneuert.

Nachweis des gemeldeten iPhone-Auftrags: Anfrage um 02:18:36, fehlende Bestätigung um 02:19:32, bestätigte Transkription um 02:20:23, abgeschlossen und importiert um 02:23:08 (Europe/Zurich). Der damalige Log enthält keine zugrunde liegende Fehlerkennung für die fehlende erste Bestätigung; die konkrete Transportursache ist daher nicht belegt.

Validierung: App-Präsentation, kompilierte Annahme-/Wiederherstellungsfälle (einschließlich aller vier Phasen mit `progress: null`), Abbruch und Retry; DE/EN-Lokalisierung. Backend: 32 Kombinationen aus Zustand und alten Zahlenwerten, vier API-Vertragstests sowie Worker-Status/Neustart-Test mit isolierter Datenbank. Neue Tests vor der jeweiligen Korrektur mit dem beabsichtigten Fehler reproduziert. Auf dem Server wurden sieben Dateien nach Prüfsummenabgleich gesichert und aktualisiert; nur die API wurde neu gestartet, der Workerprozess blieb unverändert. Backup: `var/backups/progress-presentation-20260906`.

Artefakte: [Serverpatch](transcription-server/2026-09-06-progress-presentation.patch), [Manifest](transcription-server/2026-09-06-progress-presentation-manifest.json), [API- und iPhone-Prüfung](transcription-server/2026-09-06-progress-presentation-verification.json). Korrigierter Release-Testbuild 4.0 (37) mit aktivierter Transkription direkt installiert und gestartet; kein TestFlight-Upload.

## Audioidentität und MP3-Dauer — 6. September 2026

Vor dem Server-Artefaktabruf prüft die App die vollständige gecachte Audiodatei gegen den Server-SHA-256. Fehlende oder abweichende Quellen werden nicht importiert; Dateiaustausch während des Imports wird vor dem Schreiben erneut geprüft. Fehlgeschlagene Importe fertiger Ergebnisse werden beim Queue-Retry mit derselben Anfrage erneut abgerufen, auch nach App-Neustart. Seit Schema 2026-09-06.3 wird die Client-Prüfsumme zusätzlich vor POST dauerhaft gespeichert und nach dem Serverdownload vor einer neuen Geräte-ASR verglichen.

Die Serverdauer wird aus präsentierten decodierten Samples gemessen. Die Containerdauer enthielt bei Sternengeschichten MP3-Endpadding und blockierte trotz identischer Audioquelle alle Kapitel. Worker und Chunkplanung verwenden jetzt denselben Decoder-Zeitbezug; die bestehende strikte App-Prüfung bleibt erhalten. Folge 1414 ist quellverifiziert repariert und auf Chris’ iPhone mit vier sichtbaren Kapiteln geprüft. [Ursache, Auslieferung und Tests](transcription-server/2026-09-06-missing-chapters-investigation.md).

## Gerätequelle vor ASR — Schema 2026-09-06.3

Neue Episodenaufträge benötigen `client_audio_sha256` der vollständigen Geräte-Datei. Der Hash gehört unveränderlich zur Request-UUID. Nach dem Download prüft der Worker jeden Nutzerauftrag separat: abweichende Quellen werden terminal abgelehnt; ohne passenden Geräteauftrag beginnt keine Geräte-ASR. Spätere Nutzer werden gegen die bestätigte Jobquelle geprüft. Alte Aufträge ohne Hash erhalten einen gezielten Hinweis zum erneuten Start statt einer unbelegten Behauptung dynamischer Werbung. App-Import und Wiedergabe prüfen die aktuelle Quelle weiterhin.

Das Player-Cover bleibt auch bei laufender oder fehlgeschlagener Prüfung scrollbar; seine Geste hängt nicht von der Existenz bereits freigegebener Kapitel ab. [Ablauf, Tests und Auslieferungsstand](transcription-server/2026-09-06-audio-admission.md).

## CLI-Freigabe vom 15. September 2026

Der Health-Endpunkt war mit `provider_unavailable` gesperrt: installiert war CLI 0.154.0, der Adapter erlaubte ausschließlich die zuvor geprüfte Version 0.152.1. Der aktualisierte Regressionstest reproduzierte die Ablehnung zuerst. Nach isolierter Prüfung der realen 0.154.0-Anfragen gegen den lokalen Mock (`tools=[]`, keine Inferenz) wurde die Versionsbindung aktualisiert. Unbekannte Versionen bleiben gesperrt.

17 Adaptertests, fünf Usage-Tests und der echte CLI-Inventartest bestanden. Die drei betroffenen Dateien wurden nach SHA256-Abgleich und Quellsicherung unter `var/backups/codex-cli-20260915` ausgeliefert; beide Dienste wurden bei leerer Queue neu gestartet. Danach bestätigte `/health` wieder `ok:true`. Patch und Prüfsummen: `transcription-server/2026-09-15-codex-cli.patch` und `2026-09-15-codex-cli-manifest.json`. Keine Aufträge oder Ergebnisartefakte wurden verändert.

Der isolierte Kapitelbenchmark verwendet `Tools/ios27_chapter_comparison.py`, den tatsächlichen Server-Prompt und dieselbe Transkription für beide Modelle. Die Originalkapitel werden ausschließlich zur Auswertung verwendet. Benchmark-Ergebnisse und Verbrauch werden in separaten Dateien statt in der Produktionsqueue gespeichert.
