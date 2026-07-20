# Auftrag: Transcript-API für InstacastPlus prüfen und clientfertig machen

## Ziel dieses Auftrags

Prüfe die produktive API unter `https://transcript.instacast.ch` gegen den unten
festgelegten Vertrag. Teste zuerst die tatsächlichen Antworten der laufenden API.
Ändere nur Punkte, die nachweislich fehlen oder vom Vertrag abweichen.

Das Ergebnis muss so vollständig dokumentiert und getestet sein, dass der
InstacastPlus-iOS-Client anschließend ohne Annahmen implementiert werden kann.

Keine Ersatzlogik, keine Heuristik-Fallbacks und keine künstlichen Delays einbauen.
Bei Fehlern muss die echte Ursache und ein eindeutiger API-Status zurückgegeben
werden.

## Verbindliche Produktentscheidungen

Diese Entscheidungen sind bereits getroffen und müssen nicht erneut diskutiert
werden:

1. **Ein statischer Bearer-Token in der iOS-App ist akzeptiert.**
   - Der vorhandene Client-Token darf verwendet werden.
   - Den Token niemals in Dokumentation, Git, Testausgaben oder Logs schreiben.
   - Den Token nicht ungefragt rotieren, weil vorhandene Clients sonst ausfallen.
   - Am Ende nur den Serverpfad nennen, an dem der Token lesbar liegt, und einen
     sicheren Weg beschreiben, wie der App-Entwickler ihn lokal beziehen kann.

2. **Der Server ist ein gemeinsamer, öffentlicher Transkriptbestand.**
   - Ein Podcast beziehungsweise eine Episode wird serverseitig nur einmal
     verarbeitet.
   - Alle App-Installationen dürfen dasselbe fertige Ergebnis laden.
   - `X-Instacast-Client-ID` dient nur Statistik, Rate-Limits und Blocklisten. Sie
     erzeugt keine private Kopie einer Episode.

3. **Die Audio-URL ist der vom Client verfügbare Episodenschlüssel.**
   - Der Client besitzt für diesen Vertrag nur `episode_url` und optional
     `podcast_url`, nicht zwingend eine identische RSS-GUID.
   - Keine GUID als neue Clientpflicht einführen.
   - Falls der Server beim Feed-Scan intern eine GUID findet, darf er sie intern
     zur Deduplizierung verwenden. Der Client darf davon aber nicht abhängig sein.
   - Bekannte URL-Aliase und normalisierte URLs sollen weiterhin auf dieselbe
     Serverepisode zeigen.

4. **Das serverseitig ausgewählte KI-Modell ist unabhängig von lokalen
   App-Modellen.**
   - Kimi/OpenAI/Anthropic auf dem Server ist eine interne Serverentscheidung.
   - Für diesen Auftrag weder Provider noch ASR-Modell eigenmächtig wechseln.
   - Die bestehende Pipeline mit faster-whisper und der vorhandenen serverseitigen
     KI-Konfiguration bleibt bestehen, sofern die Tests keinen konkreten Fehler
     belegen.

5. **Servertranskription ist für App-Nutzer aktuell kostenlos.**
   - Keine Abrechnung, Kaufabwicklung oder Kosten-API implementieren.
   - Spätere Bezahlmodelle sind nicht Teil dieses Auftrags.

6. **Serververarbeitung läuft unabhängig von der App weiter.**
   - Nach dem Einreihen verarbeitet der Server die Episode bis `ready` oder
     `failed`, auch wenn die App beendet oder suspendiert ist.
   - Ein iOS-Client hat keine öffentliche Webhook-URL. `callback_url` ist für
     InstacastPlus nicht erforderlich.
   - Die App fragt Status und Ergebnisse später erneut per Episode-URL oder
     Episode-ID ab.

7. **Vorhandene Kapitel werden clientseitig erhalten.**
   - Der Server liefert Sponsorsegmente separat in `ads.json`.
   - Hat die App bereits Feed-, Podlove- oder eingebettete Kapitel, fügt der
     Client nur die Sponsorsegmente dynamisch in diese Kapitel ein.
   - Hat die App keine vorhandenen Kapitel, übernimmt sie die serverseitig
     generierten finalen Kapitel aus `chapters.json`.
   - Sponsor-Kapiteltitel beginnen verbindlich mit `Sponsor: `.
   - Die vorhandene Sponsor-Skip-Logik der App verwendet dieses Präfix; es wird
     keine zweite Sponsor-Erkennung im Player gebaut.

8. **Die vorhandenen SSRF-Prüfungen bleiben bestehen.**
   - DNS-Zielprüfung und erneute Prüfung nach Redirects sind korrekt, weil der
     Server fremde Feed-, Audio- und Callback-URLs abruft.
   - Das ist kein DNS-Pinning und soll nicht entfernt werden.

## Zuerst auszuführende Ist-Prüfung

Teste die laufende produktive API mit dem echten Client-Token. Verwende in allen
gespeicherten Befehlen nur eine Shellvariable wie `$TOKEN`; der Tokenwert darf in
keiner Ausgabe erscheinen.

Mindestens prüfen:

```bash
BASE_URL=https://transcript.instacast.ch
TOKEN="$(<PFAD_ZUR_TOKEN_DATEI)"

curl --fail-with-body \
  -H "Authorization: Bearer $TOKEN" \
  "$BASE_URL/api/v1/episodes/1"
```

Prüfe danach jeden unten beschriebenen Erfolgs- und Fehlerfall. Wenn die
existierende API den Vertrag bereits erfüllt, ändere keinen Produktionscode,
sondern ergänze nur Dokumentation und Regressionstests.

## Verbindlicher HTTP-Vertrag

### Gemeinsame Request-Header

```http
Authorization: Bearer <client-api-token>
X-Instacast-Client-ID: <persistente Installations-UUID>
X-Instacast-App-Version: <CFBundleShortVersionString>
X-Instacast-Platform: iOS
Accept: application/json
```

`X-Instacast-Client-ID` ist die einzige Client-ID im InstacastPlus-Vertrag. Falls
aus Kompatibilitätsgründen noch ein `client_id` im JSON-Body unterstützt wird,
muss dokumentiert sein, welcher Wert bei einer Abweichung gewinnt. Für neue
InstacastPlus-Requests soll der Header verwendet werden.

### Episode einreichen

```http
POST /api/v1/episodes
Content-Type: application/json
```

```json
{
  "episode_url": "https://example.com/episode.mp3",
  "podcast_url": "https://example.com/feed.xml",
  "title": "Optionale Folge",
  "client_duration_seconds": 8560.2,
  "client_audio_bytes": 137421500,
  "client_audio_etag": "\"abc123\"",
  "wait_seconds": 0,
  "force": false
}
```

Nur `episode_url` ist für eine einzelne Episode zwingend. Alle anderen Felder sind
optional. `force=true` bleibt für normale Client-Tokens verboten.

Der Endpoint muss idempotent sein:

- Derselbe Clientrequest für eine bekannte Audio-URL erzeugt keinen zweiten Job.
- Wiederholte Requests während `queued` oder `running` liefern dieselbe
  `episode.id`.
- Wiederholte Requests nach `ready` liefern dieselbe fertige Episode und ihre
  Artefakte.
- Bekannte URL-Aliase dürfen auf dieselbe Episode aufgelöst werden.

Antwort:

- `200 OK`, wenn die Episode bereits fertig ist oder innerhalb von
  `wait_seconds` fertig wurde.
- `202 Accepted`, wenn sie eingereiht ist oder verarbeitet wird.
- Bei `202` müssen der HTTP-Header `Retry-After` und das JSON-Feld
  `retry_after_seconds` vorhanden und inhaltlich konsistent sein.

### Podcast global aktivieren

```http
POST /api/v1/podcasts
Content-Type: application/json
```

```json
{
  "feed_url": "https://example.com/feed.xml",
  "latest_limit": 3,
  "auto_enabled": true,
  "enqueue_latest": true
}
```

Ein durch irgendeine Installation aktivierter Podcast darf für alle
Installationen serverseitig weiterverarbeitet werden. Bereits vorhandene
Transkripte werden gemeinsam verwendet.

**Wichtige Berechtigungsregel:** Ein normaler Client-Token darf einen globalen
Podcast aktivieren, aber nicht für alle Installationen deaktivieren. Deshalb gilt
eine dieser beiden sauberen Lösungen:

- `auto_enabled` aus dem Clientvertrag entfernen und Einreichungen immer als
  Aktivierung behandeln; oder
- `auto_enabled=false` für Client-Tokens eindeutig mit `403 Forbidden` und einem
  strukturierten Fehler ablehnen.

Globales Deaktivieren bleibt eine Admin-Aktion. `false` darf nicht stillschweigend
ignoriert werden.

### Status abfragen

```http
GET /api/v1/episodes/{episode_id}
GET /api/v1/episodes/by-url?episode_url=<percent-encoded-url>
```

Beide Varianten müssen dieselbe Response-Struktur liefern. `by-url` ist für den
iOS-Client zwingend, weil die lokale Queue nach einem App-Neustart möglicherweise
noch keine Server-ID gespeichert hat.

### Einheitlicher Response-Envelope

Feldnamen dürfen vom folgenden Beispiel nur abweichen, wenn die tatsächlich
verwendeten Namen vollständig dokumentiert und durch ein JSON-Schema festgelegt
sind. Alle semantischen Informationen sind verpflichtend:

```json
{
  "api_version": "v1",
  "episode": {
    "id": 123,
    "episode_url": "https://example.com/episode.mp3",
    "podcast_url": "https://example.com/feed.xml",
    "title": "Folgentitel",
    "status": "running",
    "phase": "transcribing",
    "progress": 0.42,
    "created_at": "2026-07-20T12:00:00Z",
    "updated_at": "2026-07-20T12:10:00Z",
    "completed_at": null,
    "client_duration_seconds": 8560.2,
    "server_duration_seconds": 8560.0,
    "warnings": [],
    "error": null,
    "artifacts": []
  },
  "retry_after_seconds": 30
}
```

### Status und Phase

Stabile, dokumentierte Maschinenwerte verwenden. Empfohlener Vertrag:

- `status`: `queued`, `running`, `ready`, `failed`, `canceled`
- `phase`: `queued`, `downloading_audio`, `transcribing`, `analyzing`,
  `finalizing`, `ready`, `failed`, `canceled`

Falls die existierende API andere Werte nutzt, diese nicht unnötig umbenennen,
sondern vollständig auflisten und ihre Übergänge dokumentieren.

`progress`:

- Zahl zwischen `0.0` und `1.0`, wenn für die aktuelle Phase ehrlich messbar.
- `null`, wenn kein belastbarer Fortschritt berechnet werden kann.
- Niemals erfundene Fortschrittswerte liefern.
- `phase` und `updated_at` müssen auch bei `progress: null` aktuell sein, damit die
  App einen verständlichen Status anzeigen kann.

### Warnungen

Warnungen müssen maschinenlesbar sein, insbesondere bei Dynamic Ad Insertion:

```json
{
  "code": "audio_duration_mismatch",
  "severity": "warning",
  "message": "Client- und Serveraudio unterscheiden sich um 12.4 Sekunden.",
  "client_value": 8560.2,
  "server_value": 8547.8
}
```

Mindestens dokumentieren:

- alle möglichen `code`-Werte;
- Schwellen bei 2 und 10 Sekunden;
- ob Kapitel-/Transkriptzeiten dadurch möglicherweise verschoben sind.

### Fehler

Terminale und vorübergehende Fehler müssen strukturiert sein:

```json
{
  "code": "audio_download_failed",
  "message": "Die Audiodatei konnte nicht vollständig geladen werden.",
  "retryable": true
}
```

`episode.error` ist bei `failed` verpflichtend und sonst `null`. Dokumentiere alle
Fehlercodes und ihre Retry-Semantik.

Verbindliche HTTP-Semantik:

- `400` oder `422`: ungültiger Request, nicht automatisch erneut versuchen.
- `401`: Token fehlt oder ist ungültig.
- `403`: Installation blockiert oder verbotene Clientaktion.
- `404`: Episode beziehungsweise Artefakt existiert nicht.
- `429`: Rate-Limit, immer mit `Retry-After`.
- `503`: Queue nimmt momentan keine Jobs an, immer mit `Retry-After` und
  `retryable: true`.
- Unerwartete `5xx`: keine internen Details leaken; für den Client als temporär
  dokumentieren.

## Artefaktvertrag

Eine Episode darf erst `ready` werden, wenn alle für die App notwendigen
Artefakte atomar und abrufbar vorliegen:

- SRT-Transkript;
- finale Kapitel;
- separate Sponsorsegmente, auch wenn die Liste leer ist;
- Summary, auch wenn sie nach dem fachlichen Vertrag leer sein darf.

Wenn ein notwendiger AI-Aufruf fehlschlägt oder vom Monatslimit blockiert wird,
bleibt der Job `failed`. Keine scheinbar fertigen Ersatzartefakte erzeugen.

### Artefaktbeschreibung in der Episodenantwort

```json
{
  "id": 456,
  "kind": "ads_json",
  "url": "/api/v1/artifacts/456",
  "content_type": "application/json",
  "byte_size": 1234,
  "sha256": "<64 lowercase hex characters>",
  "schema_version": 1,
  "etag": "\"optional-http-etag\""
}
```

Für jeden tatsächlich angebotenen `kind` einen stabilen Wert dokumentieren, zum
Beispiel:

- `transcript_srt`
- `transcript_vtt`
- `transcript_json`
- `chapters_json`
- `chapters_original_json`
- `ads_json`
- `summary_json`
- `pipeline_log`

Der Artefakt-Endpoint muss Bearer-Authentifizierung prüfen und korrekte Header
liefern:

- `Content-Type`
- `Content-Length`
- `ETag`, falls im Descriptor vorhanden
- optional `Content-Disposition`

Der SHA-256-Wert muss den tatsächlich ausgelieferten Bytes entsprechen.

### `chapters.json`

Das Schema muss mindestens diese Informationen enthalten:

```json
{
  "schema_version": 1,
  "transcript_revision": "sha256:<hash>",
  "audio_duration_seconds": 8560.0,
  "chapters": [
    {
      "start": 0.0,
      "end": 143.2,
      "title": "Begrüßung und Themenübersicht",
      "is_sponsor": false
    },
    {
      "start": 143.2,
      "end": 211.7,
      "title": "Sponsor: Beispielanbieter",
      "is_sponsor": true
    }
  ]
}
```

Regeln:

- Zeiten sind Sekunden ab Beginn der serverseitig analysierten Audiodatei.
- Zahlen sind endlich, nicht negativ und chronologisch.
- `end > start`.
- Sponsor-Kapitel haben `is_sponsor: true` und Titel mit `Sponsor: `.
- Keine identischen, direkt aufeinanderfolgenden Sponsor-Kapitel für denselben
  durchgehenden Sponsor-Read.

### `ads.json`

Dieses Artefakt ist für InstacastPlus zwingend und unabhängig von
`chapters.json`:

```json
{
  "schema_version": 1,
  "transcript_revision": "sha256:<hash>",
  "audio_duration_seconds": 8560.0,
  "segments": [
    {
      "start": 143.2,
      "end": 211.7,
      "title": "Sponsor: Beispielanbieter",
      "evidence_group_ids": [17, 18, 19]
    }
  ]
}
```

Regeln:

- Keine Sponsorsegmente ist ein gültiges Ergebnis mit `"segments": []`.
- Angrenzende oder überlappende Teilstücke desselben durchgehenden Sponsor-Reads
  werden zu genau einem Segment zusammengeführt.
- Bestehende Publisher-Kapitelgrenzen dürfen einen durchgehenden Sponsor-Read
  nicht in zwei identische Sponsorsegmente teilen.
- Grenzen liegen auf vollständigen Satz-/Absatzgruppen; kein zeitliches Padding.
- Jeder Titel beginnt mit `Sponsor: `.

### Summary

Bevorzugtes Schema:

```json
{
  "schema_version": 1,
  "transcript_revision": "sha256:<hash>",
  "language": "de",
  "summary": "Zusammenfassung der Episode …",
  "topics": ["Thema 1", "Thema 2"]
}
```

Falls die bestehende API Summary als Plain Text liefert, darf das beibehalten
werden, muss aber über `kind` und `content_type` eindeutig erkennbar und exakt
dokumentiert sein.

### SRT

- Gültiges UTF-8-SRT mit chronologischen, nicht überlappenden Zeitmarken.
- Abschnitte möglichst an vollständigen Sätzen beziehungsweise Sprecherwechseln
  trennen; keine einzelnen Wörter des nächsten Satzes an den vorherigen Abschnitt
  hängen.
- Die im JSON angegebene `transcript_revision` soll deterministisch vom
  kanonischen Transkript abgeleitet werden, vorzugsweise SHA-256.

## Verhalten des späteren iOS-Clients

Der Server-Agent muss hierfür keinen App-Code schreiben. Dieses Verhalten erklärt,
warum die Artefakte getrennt benötigt werden:

1. Nutzer aktiviert „Serverbasierte Transkription“ in InstacastPlus.
2. Für konfigurierte Podcasts reicht die App den Feed global beim Server ein.
3. Für eine Episode verwendet die App `POST /episodes` idempotent und speichert die
   Server-ID zusätzlich zur Audio-URL in ihrer persistenten Queue.
4. Bei `202` zeigt sie `phase` und echten `progress` an und plant die nächste
   Abfrage exakt nach `Retry-After`.
5. Nach App-Neustart kann sie über Server-ID oder `by-url` fortsetzen.
6. Bei `ready` lädt sie die Artefakte, prüft Länge und SHA-256 und speichert sie
   atomar.
7. Existieren lokale Kapitel, werden `ads.json`-Segmente dynamisch dort eingefügt.
8. Existieren keine lokalen Kapitel, wird `chapters.json` verwendet.
9. Sponsor-Kapitel werden durch die bestehende `Sponsor:`-Skip-Regel automatisch
   übersprungen, wenn der vorhandene Sponsor-Schalter aktiv ist.
10. Die Summary erscheint oberhalb der Shownotes.

## Pflicht-Abnahmetests auf dem Server

Lege reproduzierbare automatisierte Tests an. Mindestens:

1. Fehlender und ungültiger Bearer-Token ergeben `401` mit JSON-Fehler.
2. Gültiger Token und ungültiger Request ergeben `400/422`, nicht `500`.
3. Eine bekannte Episode zweimal einreichen ergibt dieselbe Episode-ID und nur
   einen Job.
4. Eine laufende Episode ergibt `202`, aktuellen Status/Phase und konsistentes
   `Retry-After` in Header und Body.
5. `GET` per ID und `GET by-url` liefern dieselbe Episode.
6. `ready` wird erst gesetzt, wenn SRT, Kapitel, Ads und Summary abrufbar sind.
7. Alle Descriptors stimmen mit Content-Type, Byteanzahl und SHA-256 der
   ausgelieferten Artefakte überein.
8. `ads.json` mit keinem Sponsor liefert eine leere Liste, nicht `404`.
9. Ein durchgehender Host-Read über einer vorhandenen Kapitelgrenze ergibt genau
   ein Sponsorsegment.
10. Sponsorsegmente beginnen mit `Sponsor: ` und schneiden keine Satzgruppe.
11. DAI-Abweichungen über 2 beziehungsweise 10 Sekunden erzeugen die
   dokumentierten strukturierten Warnungen.
12. `429` und Queue-Vollzustand liefern `Retry-After` und einen strukturierten,
   wiederholbaren Fehler.
13. `auto_enabled=false` wird für normale Client-Tokens eindeutig abgelehnt, wenn
   globale Deaktivierung Admin-only ist.
14. Zwei verschiedene Installations-IDs erhalten für dieselbe fertige Episode
   dieselbe Episode-ID und dieselben Artefakte.

Nutze für Sponsor-Regressionen weiterhin reale, bekannte Fixtures wie ATP 696 und
The Talk Show 451 sowie die vorhandenen Checks unter `checks/sponsor_detection/`.

## Erwartete Lieferung des Server-Agenten

Am Ende bereitstellen:

1. Aktualisierte API-Dokumentation mit vollständigen Erfolgs- und Fehlerbeispielen.
2. Maschinenlesbare JSON-Schemas oder eine aktivierte, nicht geheime
   OpenAPI-Spezifikation für alle Client-Endpunkte und Artefakte.
3. Liste aller tatsächlich vorgenommenen Serveränderungen im Format:
   **Problem – Ursache – Lösung**.
4. Ausgaben der fokussierten Regressionstests ohne Token, Zugangsdaten oder
   private Daten.
5. Bestätigung der produktiven Response-Header und Statuscodes nach Deployment.
6. Pfad zur bestehenden Token-Datei und einen sicheren Befehl/Prozess, mit dem der
   App-Entwickler den Token lokal beziehen kann. Den Tokenwert selbst nicht in die
   Dokumentation schreiben.
7. Je ein anonymisiertes reales JSON-Beispiel für:
   - `POST /episodes` mit `202`;
   - fertige Episode mit `200`;
   - `chapters.json`;
   - `ads.json`;
   - Summary;
   - retriable Fehlerantwort;
   - terminale Fehlerantwort.

Keine Änderungen an ASR-Modell, KI-Provider, Monatsbudget, Retention oder
Serverhardware vornehmen, sofern ein dafür relevanter Fehler nicht mit einem Test
belegt und vorab ausdrücklich freigegeben wurde.
