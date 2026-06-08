# Analyse: iCloud-Sync-Stabilität & UI-Performance

Stand: 2026-06-06. Reine **Analyse**, noch **keine** Code-Änderung.
Ziel: Jede Optimierungsmöglichkeit zu 100 % eingrenzen, Belege nennen, Verifikationsplan
vor dem Fix festlegen. Konfidenz ist ehrlich angegeben (was aus dem Code beweisbar ist
vs. was erst per Log/Profiling bestätigt werden muss).

Legende Konfidenz:
- **BEWIESEN** – aus dem Code-Pfad zwingend ableitbar, kein Test nötig um zu wissen *dass* es passiert.
- **HOCH (Log-Bestätigung)** – Mechanismus klar, Auslösung/Umfang per vorhandenem Log bestätigbar.
- **OFFEN (Instrumentierung nötig)** – plausibel, aber Ursache erst per Messung sicher.

---

## A. iCloud-Sync (`Classes/ICiCloudSyncManager.swift`)

Die ganze Klasse ist `@MainActor` (Zeile 49–51). Der Observer `coreDataDidChange`
([ICiCloudSyncManager.swift:1877](Classes/ICiCloudSyncManager.swift:1877)) wird in `start()`
([:226](Classes/ICiCloudSyncManager.swift:226)) **unbedingt** auf
`NSManagedObjectContextObjectsDidChange` des **Main-Contexts** registriert — auch wenn Sync aus
ist (die teure Arbeit ist aber per `episodesSyncEnabled`/`subscriptionsSyncEnabled` gegated).
`start()` läuft beim App-Start ([InstacastAppDelegate.m:444](Classes/InstacastAppDelegate.m:444), iOS 17+).

### A1 — `pendingRecordZoneChangeKeys()` ist O(N) pro Einzel-Save → O(N²) beim Refresh-All  **[BEWIESEN]**

**Symptom:** „beim Aktualisieren aller Podcasts ruckelt das UI / friert einige Sekunden ein";
außerdem „kurz stockt beim Zurück/Seitenmenü", sobald ein Sync-Rückstau besteht.

**Mechanismus:**
- `coreDataDidChange` ruft für **jede** eingefügte/geänderte `CDEpisode`
  `markEpisodeObjectHashLocallyChanged` → `addPendingSave(...)`
  ([:1884–1892](Classes/ICiCloudSyncManager.swift:1884), [:1946](Classes/ICiCloudSyncManager.swift:1946)).
- Der Einzel-Pfad `addPendingSave` → `addPendingSaves([id])` baut **bei jedem Aufruf neu**
  `pendingRecordZoneChangeKeys()` = `Set(syncEngine.state.pendingRecordZoneChanges.map{...})`
  ([:824–831](Classes/ICiCloudSyncManager.swift:824), [:855](Classes/ICiCloudSyncManager.swift:855)).
- Bei N neuen Episoden eines Refreshs werden so N-mal alle bisher anstehenden Änderungen
  durchlaufen → **quadratisch** auf dem Main-Thread.
- Bei bestehendem Rückstau (z. B. 5 000 noch nicht hochgeladene Episoden) zahlt **jede einzelne**
  Core-Data-Mutation (Position speichern beim Player-Zurück, „gehört"-Markierung beim Scrollen
  in der Liste) einmal O(Rückstau). → erklärt das diffuse „UI stockt manchmal".

**Warum sicher:** Der Code-Pfad ist eindeutig; der Batch-Backfill umgeht das bewusst, indem er
`pendingKeys` per `inout` durchreicht ([:772–814](Classes/ICiCloudSyncManager.swift:772)) — der
Observer-Einzelpfad tut das nicht.

**Verifikation vor Fix:** Temporären DebugLog in `addPendingSaves(_:)` (Einzelpfad) mit
`pendingRecordZoneChanges.count` + verstrichener Zeit; Refresh-All mit aktiviertem Episoden-Sync
auslösen → Zahlen zeigen N und Wachstum.

**Fix-Richtung (später):** Pending-Key-Set inkrementell halten statt pro Aufruf neu bauen; Observer-
Arbeit pro Notification sammeln und gebündelt/debounced einreihen.

### A2 — Synchrone Platten-I/O pro Abo-Änderung im Observer  **[BEWIESEN]**

**Symptom:** Refresh-All-Freeze (additiv zu A1), v. a. mit „Abos synchronisieren".

**Mechanismus:** Im Abo-Zweig von `coreDataDidChange` ([:1894–1909](Classes/ICiCloudSyncManager.swift:1894))
wird pro aktualisiertem `CDFeed`/`CDFeedProperty` aufgerufen:
- `setSubscriptionRecordURL` ([:2278](Classes/ICiCloudSyncManager.swift:2278)) und
- `markSubscriptionLocallyChanged` → `setSubscriptionLocalModifiedDate` ([:2346](Classes/ICiCloudSyncManager.swift:2346)).

Beide Schlüssel sind **datei-gestützt** (`subscriptionRecordURLsKey`, `subscriptionLocalModifiedDatesKey`
in `fileBackedSyncMetadataKeys`, [:88–99](Classes/ICiCloudSyncManager.swift:88)). Jeder Aufruf macht:
voll-Dict **von Platte lesen** + voll-Dict als Binär-Plist **atomar zurückschreiben**
(`writeSyncMetadataValue` → `data.write(.atomic)`, [:2623–2627](Classes/ICiCloudSyncManager.swift:2623))
+ ein synchrones `NSLog` ([:2724](Classes/ICiCloudSyncManager.swift:2724)). Ein Refresh berührt jeden
Feed (`localFeed.lastUpdate = now`, etag/contentHash) → bei vielen Abos Hunderte voll-Dict-Schreibvorgänge
nacheinander, das Dict wächst dabei mit.

**Verifikation:** Existierendes Log `[iCloudSync metadata] write key=… storage=file …` schon vorhanden
([:2724](Classes/ICiCloudSyncManager.swift:2724)) — Häufigkeit/Bytes während eines Refreshs auswerten.

**Fix-Richtung:** In-Memory-Cache + debounced Flush (wie es A für Episoden via
`episodeLocalModifiedDatesCache`/`scheduleEpisodeLocalModifiedDatesWrite` bereits macht,
[:2304–2335](Classes/ICiCloudSyncManager.swift:2304)); `NSLog` aus dem Hot-Path entfernen.

### A3 — `coreDataDidChange` läuft vermutlich auf einem Hintergrund-Thread → Data-Race auf `@MainActor`-State  **[HOCH — Log-Bestätigung]**

**Symptom:** „beim Aktivieren … beendet sich sofort" (intermittierender Crash), und allgemeine
Unzuverlässigkeit bei aktivem Sync.

**Mechanismus / Hypothese:** Der Feed-Merge speichert in einem **Child-Context** auf der
`mergeQueue` (Hintergrund): `[mergeContext save:]` in `performBlockAndWait`
([SubscriptionManager.m:902–948](Classes/Model/SubscriptionManager.m:902)). Wenn ein Child-Context in
den Main-Parent-Context speichert, wird `NSManagedObjectContextObjectsDidChange` des Parents
synchron **auf dem speichernden (Hintergrund-)Thread** gepostet. Damit liefe `coreDataDidChange`
außerhalb des Main-Threads und mutiert `@MainActor`-Zustand (`syncEngine.state.add(...)`,
`episodeLocalModifiedDatesCache`) ohne Synchronisation → Data-Race → sporadischer Crash.
Dass das Team weiß, dass der Merge-Block im Hintergrund läuft, zeigt der explizite
`dispatch_async(main)` direkt danach ([:950](Classes/Model/SubscriptionManager.m:950)).

**Warum noch nicht „bewiesen":** Das genaue Posting-Thread-Verhalten des Parent-Contexts muss
bestätigt werden (Apple dokumentiert es nicht hart). Das ist **billig prüfbar**: die vorhandenen
Logs schreiben bereits `mainThread`/`threadID`. Sehe ich beim Refresh-All (Abo-Sync an) ein
`[iCloudSync metadata] … mainThread=0`, ist die Gefahr bestätigt.

**Fix-Richtung:** Observer-Eintritt auf Main hoppen (bzw. `assert(Thread.isMainThread)` zuerst zur
Diagnose), Mutationen serialisiert ausführen.

### A4 — Neu eingefügte Episoden ohne Status werden unnötig zum Upload eingereiht  **[BEWIESEN]**

**Symptom:** Sync-Rückstau bläht sich bei jedem Refresh auf → verschärft A1; CloudKit-Last/Quota.

**Mechanismus:** Der Backfill lädt nur Episoden mit echtem Status hoch
(Prädikat `consumed == YES OR starred == YES OR position > 0`,
[:591](Classes/ICiCloudSyncManager.swift:591)). Der Observer reiht dagegen **jede** neu eingefügte
Episode ein (`inserted.contains(object)`, [:1888](Classes/ICiCloudSyncManager.swift:1888)) — auch
frische, ungehörte ohne jeden Status. Inkonsistent mit der Backfill-Logik und unnötig.

**Verifikation:** Log in `markEpisodeLocallyChanged`: wie viele der eingereihten Episoden
`consumed==NO && !starred && position==0` sind.

**Fix-Richtung:** Im Observer beim *Insert* dieselbe Status-Bedingung wie im Backfill anwenden.

### A5 — Erst-Download wendet alle Remote-Records auf dem MainActor an  **[OFFEN — bei großem Datenbestand]**

**Mechanismus:** `handleFetchedRecordZoneChanges` iteriert Modifikationen und ruft
`applyRemoteRecord` je Record, dann `databaseManager.save()` — alles `@MainActor`
([:1456–1484](Classes/ICiCloudSyncManager.swift:1456)). Beim Erst-Sync eines neuen Geräts, das
Tausende Episode-States zieht, kann das den Main-Thread blockieren.

**Verifikation:** Zeit/Record-Anzahl in `handleFetchedRecordZoneChanges` loggen; Szenario „neues
Gerät, großer Bestand" testen. (Tritt nur beim Erst-Download auf, daher OFFEN priorisiert.)

### A6 — Die „Regressionstests" testen kein Laufzeitverhalten  **[BEWIESEN — Faktenlage]**

Alle 7 `Tools/icloud_sync_*_regression_test.py` sind **reine Source-String-Grep-Skripte**
(`read_text()` + `split`/`require`), keines startet App, Sync-Engine oder CloudKit; kein
`xcodebuild`/`XCTest`/`simctl`. Sie prüfen *Code-Form*, nicht *Verhalten*. Konfliktauflösung,
Account-Wechsel, große Datenmengen, Netzfehler sind damit **nicht** funktional abgedeckt.
Das deckt sich mit „nicht robust und nicht zuverlässig getestet". → Empfehlung: echte
Integrationstests gegen die CloudKit-Sandbox bzw. eine abstrahierte Engine-Schicht.

---

## B. UI-Performance außerhalb des Syncs

### B1 — Zurück-Button (Player/Episodenliste) & Seitenmenü stocken  **[OFFEN — Instrumentierung nötig]**

**Ehrliche Einordnung:** Hier habe ich **keinen** beweisbaren Einzelverursacher gefunden. Zwei
plausible, sich nicht ausschließende Quellen:
1. **Kopplung an A1/A3:** Player-Zurück speichert Wiedergabeposition → Core-Data-Save → bei aktivem
   Sync greift der O(N)-Observer-Pfad (siehe A1). Wenn die Stocker **nur bei aktiviertem Sync**
   auftreten, ist das die Ursache.
2. **Sync-unabhängig:** teures `reloadData`/`updateAppearance`/Layout in `viewWillAppear`/Transition.

**Verifikation (sauber, vor jedem Fix):** `os_signpost`/`CFAbsoluteTimeGetCurrent`-Marker um
`viewWillAppear`/`viewWillDisappear` der betroffenen VCs **und** Gegentest mit komplett
deaktiviertem Sync. Ergebnis entscheidet, ob B1 = A1 ist oder ein eigener Befund. Erst danach Fix.

### B2 — Transkript-Fokus nutzt partielles Layout — Abweichung zur dokumentierten Lösung  **[HOCH — Code-Diskrepanz]**

`_focusTranscriptCueAtIndex` ruft `ensureLayoutForCharacterRange:cueRange` (nur Cue-Bereich) und
liest danach `contentSize.height` ([PlayerInfoViewController_v5.m:1819–1829](Classes/PlayerInfoViewController_v5.m:1819)).
CLAUDE.md/Memory schreiben für Scroll-Stabilität ausdrücklich **vollen** Bereich
`NSMakeRange(0, textStorage.length)` vor („contentSize springt → Scroll-Position zerstört").
Der aktuelle Code widerspricht dem. Es ist ein echter Zielkonflikt (volles Layout = stabil aber
teuer; partiell = schnell aber instabil). **Nicht selbst entscheiden** — beim User rückfragen, ob
das eine bewusste Performance-Umstellung oder eine Regression ist.

---

## Priorisierung (Eingrenzung → dann Fix, einzeln, mit Build/Test)

| # | Befund | Erklärt | Konfidenz | Nächster Schritt |
|---|--------|---------|-----------|------------------|
| A1 | O(N²) Pending-Keys im Observer | Refresh-Freeze, diffuses Stocken | BEWIESEN | Log Pending-Count → Fix inkrementell |
| A3 | Observer evtl. off-main → Data-Race | „beendet sich sofort" | HOCH | `mainThread=`-Logs beim Refresh prüfen |
| A2 | Synchrone Platten-I/O pro Abo | Refresh-Freeze | BEWIESEN | Vorhandene Metadaten-Logs auswerten → Cache+Debounce |
| A4 | Status-lose Episoden eingereiht | Rückstau wächst | BEWIESEN | Bedingung an Backfill angleichen |
| B1 | Zurück/Seitenmenü-Stocker | Navigations-Stocken | OFFEN | signpost + Sync-Aus-Gegentest |
| A6 | Tests prüfen nur Source | „nicht getestet" | BEWIESEN | echte Integrationstests planen |
| A5 | Erst-Download auf MainActor | Freeze bei Erst-Sync | OFFEN | Zeit/Count loggen |
| B2 | Transkript-Layout-Diskrepanz | Scroll-Instabilität? | HOCH | Beim User rückfragen |

**Wichtig:** A1, A2, A3, A4 teilen sich denselben Hot-Path (`coreDataDidChange`) und sind die
wahrscheinlichste gemeinsame Wurzel für Aktivierungs-Freeze, Crash und Refresh-Ruckeln. Reihenfolge
der Fixes: erst A3 verifizieren (Thread), dann A1/A2/A4 zusammen entschärfen, jeweils Build + ein
realer Refresh-Test mit aktiviertem Sync dazwischen.

---

## UMSETZUNG (2026-06-06) — A1–A5 implementiert, B1/B2/A6 nicht verfolgt (Auftrag)

Alle Änderungen ausschließlich in [ICiCloudSyncManager.swift](Classes/ICiCloudSyncManager.swift).
`AGENTS.md`/`CLAUDE.md`/UI nicht angefasst.

**Crash-Log-Auswertung (`InstacastPlus-CrashLogs-1.txt`):** Kein Stacktrace enthalten
(Application.Log leer). Crash-Session `ADBD2317`: letztes Event „Initiale iCloud-Queue geplant"
um 09:52:08, direkt nach Aktivieren des **Episoden**-Syncs. Intermittent (andere Sessions
überlebten denselben Pfad). Lifecycle: Vordergrund 09:51:53 (letzter Hintergrund 08:22 → >30 min →
Auto-Refresh löst aus) + 15 s später Schalter umgelegt → **Refresh-Merge überlappt Sync-Aktivierung**.
Das ist exakt das A3-Szenario (Observer feuert auf dem Merge-Hintergrund-Thread). Stark, aber ohne
Stack **unbestätigt**.

| # | Umsetzung | Datei-Stelle |
|---|-----------|--------------|
| A3 | `coreDataDidChange` läuft nur noch auf Main; Off-Main-Zustellung wird mit stabilen `NSManagedObjectID`s nach Main umgeleitet (`processSyncObjectIDs`). Diagnose-Log „…vom Hintergrund-Thread auf Main umgeleitet". | `coreDataDidChange`, `processSyncObjectIDs`, `processSyncObjects` |
| A1 | Observer sammelt alle Änderungen und ruft die Batch-`addPendingSaves(_:pendingKeys:…)` **einmal** mit einmal gebautem Key-Set → O(N) statt O(N²). | `processSyncObjects` |
| A4 | Nur Episoden mit `consumed‖starred‖position>0` werden eingereiht (ungehört = Default, nicht gesynct). Zusatz: bereits gesyncte Episoden (`episodeLocalModifiedDate != nil`) werden weiter berücksichtigt, damit ein **Zurücksetzen** auf ungehört zwischen Geräten propagiert. | `processSyncObjects` |
| A2 | Payload-Hash-Gate: Abo wird nur eingereiht, wenn sich der **synchronisierte** Payload (Titel/rank/parked/Credentials/Properties) ändert. Ein Refresh ändert nur lastUpdate/etag/contentHash → kein Hash-Change → kein Schreibvorgang. Hash-Cache + Batch-Write. | `subscriptionPayloadHash`, `applySubscriptionLocalChanges`, `*PayloadHashes*` |
| A5 | Großer Remote-Download yieldet alle 50 Records → Main-Thread blockiert nicht am Stück. | `handleFetchedRecordZoneChanges` |

**Verifikation bisher:** `swiftc -parse` 0 Syntaxfehler; 6/7 Source-Grep-Tests grün (der 7. prüft
`AGENTS.md`-Text, von mir nicht berührt — vorbestehend). **Voller Xcode-Build + Geräte-Test steht aus.**

**Noch offen für 100-%-Crash-Bestätigung:** iOS-`.ips`-Crashreport (Xcode Organizer → Crashes, oder
Gerät → Einstellungen → Datenschutz → Analysedaten → „InstacastPlus-…"). Erscheint nach einem Repro
das neue Log „…vom Hintergrund-Thread auf Main umgeleitet", ist A3 als reale Ursache bestätigt.

**Semantik (vom User bestätigt):** „Ungehört" als Default wird nicht en masse gesynct, aber ein
*erneutes* Markieren als ungehört IST ein Marker und wird propagiert (über die „bereits gesynct"-
Bedingung `episodeLocalModifiedDate != nil`).

### KORREKTUR Crash-Ursache (nach echtem Stacktrace)

Der erste Fix war **strukturell unvollständig**. Echter Stack (iPhone 17 Pro, Thread 23 „c…d serial"):
`_dispatch_assert_queue_fail` → `EXC_BREAKPOINT` mit „Block was expected to execute on queue".
Das ist die **Main-Actor-Executor-Assertion**, die die Swift-Runtime am **Eintritt** jeder
`@MainActor`-isolierten `@objc`-Methode einfügt. `coreDataDidChange` war (als Member einer
`@MainActor`-Klasse) isoliert → wird vom Core-Data-Merge-Hintergrund-Thread aufgerufen → Assertion
feuert im Methoden-Prolog → Crash, **bevor** der `if !Thread.isMainThread`-Guard läuft. Mein Guard
saß zu spät.

**Echter Fix:** `coreDataDidChange` ist jetzt `@objc private nonisolated` → keine Executor-Assertion.
Sie liest nur thread-sicheres (Object-IDs) und springt per `Task { @MainActor }` auf den Main-Actor
für die eigentliche Arbeit (`processSyncObjectIDs` → `processSyncObjects`). `managedObjectIDs` ist
ebenfalls `nonisolated static`. Die drei anderen Observer (`defaultsDidChange`, `listScrollPositions…`,
`episodesWereAdded`) werden ausschließlich auf Main gepostet → bleiben isoliert.

**Freeze vor dem Crash:** im Code statisch nicht eindeutig lokalisierbar. Der neue Observer-Pfad ist
asynchron + gebündelt + billig (kein Disk, kein O(N²)), trägt also nicht bei. Falls nach dem Crash-Fix
ein Hänger bleibt → mit Main-Thread-Hang-Instrumentierung (os_signpost) gezielt messen, nicht raten.

**Build-Fix:** `databaseManager.objectContext` ist optional → `guard let context` in `processSyncObjectIDs`.

### Zusatz-Feature: Sync-Zähler in den Einstellungen

Neue Sektion „Auf iCloud" im iCloud-Sync-Screen zeigt pro Kategorie (Folgen/Abonnements/
Einstellungen), wie viele Records aktuell auf iCloud liegen und wie viele gerade ausstehen (`+N`).
- Swift: `ICiCloudSyncCounts`-Datenklasse + `@objc var syncCounts` auf dem Manager
  (`pendingChangeCountsByCategory`, `syncedSettingsValueCount`). „Auf iCloud" = lokale, nach einem
  Sync server-akkurate Proxys (`episodeLocalModifiedDates`/`subscriptionRecordURLs`/gesyncte
  Settings-Keys), „ausstehend" = `syncEngine.state.pendingRecordZoneChanges` nach Präfix.
- ObjC: `ICiCloudSyncSettingsViewController` — Sektion + Zeilen, `cachedCounts` (einmal pro Reload
  berechnet, kein Mehraufwand pro Sync-Statusänderung).
- Neuer Localizable-Key `"On iCloud"` (DE/EN).
