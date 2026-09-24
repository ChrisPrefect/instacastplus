# CLAUDE.md — InstacastPlus

Podcast-App für iOS, Mac Catalyst und watchOS in ObjC/Swift, v3.2, Deployment-Target iOS 17. Bundle `com.iteconomy.instacastplus`, Team `L95F4M2LHG`, App Store ID `6472283494`.

Diese Datei enthält nur Dinge, die man dem Code NICHT ansieht: Fallen, die schon einmal etwas kaputtgemacht haben, und Entscheide, die bewusst so gefallen sind. Alles andere steht im Code.

## Grundregeln

- **Nur der Stand auf der lokalen Platte zählt**, inklusive uncommitteter und ungetrackter Dateien. Git und GitHub sind Backup und niemals ein Beleg dafür, welcher Code in einem Build steckt.
- **Chris arbeitet parallel am selben Repo**, auch an pbxproj, Info.plists und Build-Nummer. Jede Datei deshalb unmittelbar vor der Analyse und nochmals vor der Änderung neu einlesen. Fremde Änderungen im Working Tree nie zurückdrehen, nur benennen.
- Vor einem Archiv den Plattenstand inventarisieren und nach dem Archiv vor dem Upload erneut prüfen. Hat sich etwas geändert, ist das Archiv veraltet und muss neu gebaut werden.
- Erst messen, dann fixen: DebugLog einbauen, Chris testen lassen, Logs auswerten. Keine Vermutungs-Fixes, keine Workarounds, keine `dispatch_after`-Kaschierung, und niemals Daten oder Verhalten umbiegen, damit ein Symptom verschwindet.
- Nichts eigenmächtig umbauen, was über den Auftrag hinausgeht; bei Unklarheit nachfragen.
- Eine scheinbar tote Datei vor dem Löschen repo-weit prüfen. Die Regressionstests in `Tools/` pinnen Dateien, die im App-Code unreferenziert aussehen (z.B. `Resources-iPad/`, `InstacastMac.entitlements`).
- Builds und Simulatoren sind jederzeit ohne Rückfrage erlaubt; bei kleinen Änderungen trotzdem lieber gezielt testen als voll bauen.

## Build

Es gibt vier Schemes: `Instacast` (iPhone und iPad kommen aus diesem einen Target), `InstacastWatch`, `InstacastWidgets`, `InstacastWatchWidgets`. Ein Scheme „Instacast HD" oder „InstacastMac" existiert nicht.

```bash
xcodebuild -project Instacast.xcodeproj -scheme Instacast build
xcodebuild -project Instacast.xcodeproj -scheme Instacast -destination 'platform=macOS,variant=Mac Catalyst' build
xcodebuild -project Instacast.xcodeproj -scheme InstacastWatch -destination 'generic/platform=watchOS' build
```

Testauswahl und Nachweise richten sich nach `AGENTS.md`, Abschnitt „Build And Test Policy“. Es gibt kein XCTest-Scheme; isolierte Laufzeit- und Artefaktprüfungen in `Tools/` ersetzen keinen E2E-Nachweis.

Der Mac-Build ist **Mac Catalyst** (`TARGET_OS_MACCATALYST` = 1), nicht „Designed for iPad".

Die iOS-App nie mit `CODE_SIGNING_ALLOWED=NO` für den Simulator bauen: Das entfernt alle Entitlements, `CKContainer.init` trapt dann beim Launch und die App Group fehlt.

**Transkriptions-Testbuilds auf Chris' iPhone brauchen auch bei Release die explizite Freigabe.** Ein normaler Release-Build blendet Transkriptions-Einstellungen und Aktionen absichtlich aus. Beim Testbuild `-configuration Release 'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) IC_TRANSCRIPTION_TESTFLIGHT_BUILD=1'` übergeben; die öffentlichen Release-Defaults unverändert lassen. Vor der Installation das tatsächliche optimierte iPhone-Bundle prüfen: `python3 Tools/transcription_build_availability_regression_test.py <InstacastPlus.app> --expected enabled`. Bei einem öffentlichen Release lautet die Erwartung `--expected disabled`. Ein erfolgreicher Build oder vorhandene Settings-Quelldateien belegen die Freigabe nicht.

## TestFlight

ASC API Key `7QUKV6MHZ2`, Issuer `69a6de70-cba8-47e3-e053-5b8c7c11a4d1`, Datei `/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8`.

```bash
agvtool new-version -all <build>
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Release -destination 'generic/platform=iOS' -archivePath build/TestFlight/InstacastPlus-<v>-<b>.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/TestFlight/InstacastPlus-<v>-<b>.xcarchive -exportOptionsPlist build/TestFlight/ExportOptionsUpload.plist -allowProvisioningUpdates
```

**Vor jedem Upload das CloudKit-Schema diffen.** Debug-Builds legen neue Record-Typen automatisch in der Development-Umgebung an, TestFlight läuft gegen Production. Ein dort fehlender Typ killt den Sync aller Nutzer komplett (`CKError 12`) und ist im eigenen Log nie sichtbar:

```bash
for env in production development; do xcrun cktool export-schema --team-id L95F4M2LHG --container-id iCloud.com.iteconomy.instacastplus --environment $env --output-file /tmp/$env.ckdb; done; diff /tmp/production.ckdb /tmp/development.ckdb
```

Deployen lässt sich das nur über die CloudKit Console, `cktool` kann Production nicht schreiben.

Bei Änderungen an Watch, Playback, Downloads oder Info.plists immer das **Archiv** prüfen statt der Source-Plist — Xcode verändert eingebettete Bundles beim Processing:

```bash
plutil -p <archive>/Products/Applications/InstacastPlus.app/Watch/InstacastWatch.app/Info.plist   # UIBackgroundModes = (audio)
```

`What to Test` selbst auf Deutsch schreiben, Tester benachrichtigen. Build `3.4 (10)` ist seit 23.05.2026 extern freigegeben und darf nicht erneut freigegeben werden.

**Signing (Stand 04.09.2026):** Die alten Certs `PR86VDJCFA` (Distribution) und `7S8JJ2YT5H` (Development) laufen am 03.10.2026 ab. Die Nachfolger `S8VYW5G5P4` und `VPRJ8FVF28` sind angelegt und bis 03.09.2027 gültig, die neuen App-Store-Profile liegen als `build/TestFlight/*_2026-09-04.mobileprovision`. Drei Dinge, die dabei nicht offensichtlich waren:

- Ein Profil enthält seine Zertifikate unveränderlich. Ein ablaufendes Cert erzwingt deshalb immer auch neue Profile, nicht nur ein neues Cert. Enthält ein Profil mehrere Certs, erbt es das spätere Ablaufdatum.
- Ein `signingCertificate`-Eintrag in einer ExportOptions-Plist überlebt keinen Zertifikatswechsel. Entweder aktuellen SHA1 eintragen oder `signingStyle = automatic` verwenden (`build/TestFlight/ExportOptionsUpload-manual.plist`).
- Per API erzeugte Certs laufen auf die Identität des API-Keys (`Apple Development: Created via API (7QUKV6MHZ2)`). Xcode bevorzugt sie bei automatischem Signing, und danach muss jedes von Xcode verwaltete Profil einmal mit `-allowProvisioningUpdates` aufgefrischt werden, sonst bricht der Build mit „doesn't include signing certificate".

## Fallen im Kern

**Singletons ohne `dispatch_once`.** `DMANAGER`, CacheManager und SubscriptionManager verwenden bewusst getrenntes `alloc` und `init`, weil `init` rekursiv über `DMANAGER` zurückgreift und `dispatch_once` dabei deadlockt. Nie auf `dispatch_once` umstellen.

**Core Data ist Main-Thread-gebunden.** `DMANAGER.objectContext` läuft auf der Main Queue; Parser-Callbacks kommen auf `parserQueue` und müssen hoppen. NSManagedObject-Subklassen haben `NS_REQUIRES_PROPERTY_DEFINITIONS`: nicht modellierte Properties brauchen ein explizites `@synthesize`, sonst fehlen die Accessoren zur Laufzeit — der Compiler warnt nur, der Build bleibt grün.

**`CDEpisode.downloaded` ist transient** und existiert nicht als Spalte im Store. SQL-Prädikate darauf matchen nie; Listen filtern stattdessen über `objectHash IN cachedEpisodes`.

**Änderungs-Dictionaries synchron lesen.** `changedValuesForCurrentEvent` muss direkt in der Notification ausgewertet werden; in einem async-Block ist es leer. Das betrifft sowohl den iCloud-Observer als auch den Widget-Export.

## Playback

**`episode.duration` ist die gemessene Mediendauer, nicht `itunes:duration`** (Entscheid 02.09.). Bei Feeds mit dynamischer Werbung ist die Datei länger als die Feed-Angabe. Die Folge war: Restzeit 0, Neustart bei 0:00, aber `consumed == NO` — die Folge klebte für immer in „Ungespielt". Der Player schreibt die Dauer bei `AVPlayerItemStatusReadyToPlay` diff-gated, und der Feed-Merge setzt `itunes:duration` nur noch, solange `lastPlayed == nil` ist. Die Dauer ist nicht Teil des iCloud-Payloads. Bewusste Folge: Bei einer schon geöffneten Folge wird eine spätere Feed-Korrektur ignoriert.

**Kapitel-Kaskade:** generierte Kapitel vor eingebetteten vor Feed-Kapiteln (`CDChapter`/Podlove). Ohne den Feed-Fallback zeigt die Player-UI Kapitel an (sie liest `episode.sortedChapters`), während Kapitelende-Skip und Auto-Skip leer laufen, weil `PlaybackManager.chapters` weniger als zwei Einträge hat. Der CDChapter-Snapshot muss vor dem asynchronen Parser-Callback gebaut werden.

**Der Arm für die Quell-Liste muss immer konsumiert werden.** `notePlaybackSourceEpisodeList:` wird vor der Player-Präsentation gesetzt, aber nur in `AudioSession._playEpisode:` verbraucht. Tippt man Play auf einer bereits geladenen Episode, läuft die Präsentation über den reinen `[pman play]`-Zweig, der Arm überlebt und wird auf die nächste irgendwo gestartete Episode angewendet — die Liste klebte dauerhaft. Die Präsentation ruft deshalb immer `applyPendingPlaybackSourceToCurrentEpisode`.

**`AVRoutePickerView` skaliert seinen Glyph mit den eigenen Bounds** (etwa `0.83 × Bounds − 17`, unterhalb ~42 pt auf ~18 pt geklemmt) und bietet keine Bild-API. Deshalb ist `ICVolumeView` ein `UIView`-Container, der den Picker mittig auf 50 pt legt und `hitTest:` auf den vollen 84-pt-Slot durchreicht. Icon-Grössen in solchen Fällen im Simulator ausmessen statt schätzen.

## Listen und Swipe

**Es gibt nur ein Swipe-System:** UIKits `UISwipeActionsConfiguration`. Der Legacy-Pan in `EpisodesTableViewCell` ist über `cell.usesNativeSwipeActions = YES` abgeschaltet, das in jedem `cellForRow` gesetzt werden muss — sonst kollidiert er mit UIKit.

**Während eine Swipe-Aktion offen ist, gehört das Zell-Layout UIKit.** Jedes `reloadData` und jeder Durchlauf über `visibleCells` reisst die Geste mitten im Ziehen ab. Alle Episodenlisten setzen deshalb in `willBeginEditingRowAtIndexPath:` ein Gate, sammeln die stärkste Aktualisierung und spielen sie in `didEndEditingRowAtIndexPath:` nach; die Action-Handler geben das Gate zusätzlich explizit frei, weil UIKit `didEndEditing` nicht zuverlässig vorher liefert.

**Die iOS-26-Geste `interactiveContentPopGestureRecognizer` kollidiert mit Zell-Swipes** und poppt die ganze View statt die Row-Action zu zeigen. Auf Episodenlisten in `viewWillAppear` deaktivieren und in `viewWillDisappear` wieder aktivieren; Edge-Swipe (`interactivePopGestureRecognizer`) und Back-Button bleiben unangetastet.

**Die Liste sprang beim Scrollen an den Anfang.** `updateEpisodes` leerte die paginierte Tabelle (25 pro Seite) kurz komplett, wodurch `contentSize` kollabierte und UIKit `contentOffset` auf 0 klemmte. Ausgelöst wurde das vom KVO auf `list.numberOfEpisodes`, der bei jeder Zähleränderung feuert. Während `dragging` oder `decelerating` wird der Reload deshalb verschoben, und ab der zweiten geladenen Seite vorher die Scroll-Position gesichert.

**Swipe- und Scroll-Performance nur im Release-Build ohne Debugger beurteilen.** In Debug ist `DebugLog` ein synchrones `NSLog` und am Debugger nochmal rund zehnmal teurer; die App wirkt dort unbenutzbar, während der Release-Build flüssig läuft.

## Refresh

Der Merge-Context ist ein Child des Main-Contexts, also ist jeder Merge-Fetch Main-Thread-Zeit (nachvollziehbar über `feed-refresh-profile`-Events). Während eines Refresh darf deshalb nichts zusätzlich synchron auf Main laufen:

- Feed-Setter nur über den Diff-Check `ICFeedValueDiffers` schreiben. Core Data markiert Objekte auch bei identischem Wert als geändert, und jeder dirty Feed löst die Kaskade aus FRC-Reload, Widget-Export, Spotlight und FTS aus.
- `ICSpotlightIndexer` macht nur den Roh-Snapshot synchron, alles Teure läuft auf `indexQueue`. Der Feed-Trigger ignoriert bewusst `lastUpdate`, sonst re-indexiert jeder Pull die ganze Abo-Liste.
- `ICFTSController`: `FMDatabaseQueue inDatabase:` ist synchron, deshalb laufen Writes und HTML-Stripping über die serielle `writeQueue`.
- `_feedNeedsDurationMetadataRefresh` darf pro Feed nur einmal einen Voll-Parse erzwingen (`kFeedPropertyDurationRefreshAttempted`), sonst verlieren alle Feeds ohne `itunes:duration` dauerhaft ihr etag-Caching. Der Check ist ein SQL-Count und nie eine Iteration über `feed.episodes`, die alle Faults auf Main feuert.
- Reloads koaleszieren: Widget-Export 2 s, Listen- und Abo-Reloads 1 s.

Auto-Refresh läuft bei Start und Foreground mit 30-Minuten-Cooldown. Auf iOS ignoriert `refreshAllFeedsForce:` das force-Flag; die per-Feed-Intervalle existieren nur im alten Nicht-iOS-Pfad.

## Apple Watch

- Das ausführbare Bundle `InstacastWatch.app` (nicht die iOS-App) braucht `UIBackgroundModes = audio`. `WKBackgroundModes/audio` lehnt App Store Connect mit Fehler 90362 ab.
- `WatchPlayerController` muss die `AVAudioSession` als `.playback` mit `policy: .longFormAudio` konfigurieren und asynchron per `activate(options: [])` aktivieren. Scheitert die Aktivierung (keine Kopfhörer), darf die Download-Datei nicht gelöscht werden.
- `WatchDownloadManager` markiert eine Datei erst nach HTTP-Status, Grösse und AVFoundation-Playability als `.downloaded`. HTTP 206, leere Dateien und Dateien kleiner als `countOfBytesExpectedToReceive` müssen fehlschlagen.
- **Trunkierte Downloads ohne Content-Length** waren die Ursache für „bricht nach 6–8 s ab": Ein 120-KB-Prefix einer 90-Minuten-Datei besteht alle HTTP-Checks und `isPlayable`, spielt kurz, endet „erfolgreich" und markierte die Folge als gehört. Drei Schichten müssen bestehen bleiben: ohne Transport-Grösse gegen die Feed-Enclosure-Grösse prüfen (unter 50 % fehlschlagen), gemessene Dauer unter 50 % eines `durationHint` ab 600 s fehlschlagen, und ein `audioPlayerDidFinishPlaying` mit zu kurzer Dauer als trunkiert behandeln statt als gehört. Die erste Schicht hält nur, wenn `didWriteData` `expectedBytes` ausschliesslich bei `totalBytesExpectedToWrite > 0` schreibt — der Transport meldet sonst -1 und löscht die Enclosure-Grösse, bevor die Validierung sie braucht.
- Ohne Datei-Extension (Tracking-Redirects) kann AVFoundation den Container nicht erkennen: `isPlayable` liefert dann optimistisch true bei Dauer 0. Deshalb Extension aus dem Response-MIME-Type ableiten und `duration <= 0` als harten Fehler werten.
- **Freien Speicher als roher `NSNumber.int64Value` aus `volumeAvailableCapacityKey` lesen.** Der typisierte Swift-Wert ist auf watchOS (`arm64_32`) Int-gross und wird bei Multi-GB negativ, was jeden Download blockiert. `volumeAvailableCapacityForImportantUsageKey` ist auf watchOS nicht verfügbar. Pin `Tools/watch_download_storage_eviction_regression_test.py`.
- **Swift 6 im Watch-Target:** Closures, die in `@MainActor`-Kontext gebildet und an nicht als sendable annotierte ObjC-APIs übergeben werden, erben MainActor-Isolation und trappen, sobald das Framework sie auf seiner eigenen Queue aufruft. Das betraf den `WCSession.sendMessage`-errorHandler, alle `MPRemoteCommandCenter`-Handler, `MPMediaItemArtwork` und die `AVAudioSession`-Aktivierung. Jeder solche Closure muss `@Sendable` sein und für Actor-State explizit auf den MainActor hoppen. Pin `Tools/watch_swift6_callback_isolation_regression_test.py`.
- **Downloads laufen sequentiell** in Abspielreihenfolge (Entscheid 06.07.); parallel kämpften sie um das langsame Watch-Funk und keiner wurde fertig. Ein Nutzer-Tap startet weiterhin sofort. `didFinishDownloadingTo` staged die Datei nur, nach Task-Identifier statt nach Hash; Validierung und Queue-Fortschaltung laufen aus `didCompleteWithError`, sonst startet der nächste Download, bevor die fertige Folge registriert ist, und blockiert Speicher als Nicht-Eviction-Kandidat.
- Der Downloadstatus auf dem iPhone ist bewusst aggregiert („x MB von total") und überspringt sowohl `evicted` als auch `failed`, sonst bleibt die Anzeige bei einer fehlgeschlagenen Folge für immer stehen.
- Auf der Phone-Seite: `watch.diagnostic` vor dem Save/Notify-Tail behandeln (nach Unreachable-Phasen kommt ein Burst, der den Main-Thread einfriert), speichern nur bei `hasChanges`, und der Playback-Tick (1×/s) sendet nur bei tatsächlich geänderter Position.
- Im watchOS-Simulator funktionieren Background-URLSessions nicht, deshalb nutzt der Simulator-Pfad die Default-Session. Das Watch-Target hat kein `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`, das muss man beim Sim-Build mitgeben.
- Bei Watch-Themen nie nur Source-Tests: immer das gebaute Bundle prüfen.

```bash
python3 Tools/apple_watch_integration_regression_test.py
xcodebuild -project Instacast.xcodeproj -scheme InstacastWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
```

## iOS 26 Liquid Glass

- `edgesForExtendedLayout` muss `UIRectEdgeBottom` sein, nicht `UIRectEdgeNone`; einzige Ausnahme ist `PlayerController` wegen seiner Höhenberechnung. Opake Navigation Bars über `UINavigationBarAppearance` mit `backgroundImage`, nicht über opake Views hinter der Bar.
- `FloatingBarHostingView` blockiert eine 86 pt hohe Touch-Zone über der Toolbar-Pill. Dafür gibt es keinen API-Fix und Swizzling ist ausgeschlossen. Lösung: `toolbarHidden = YES` und eigene `UIButton` mit `glassButtonConfiguration` auf `navigationController.view`.
- **`toolbarHidden` darf niemals getoggelt werden (YES→NO→YES).** Ein `NO` erzeugt eine `FloatingBarContainerView`, die nach erneutem `YES` bestehen bleibt und Touches blockiert. Temporäre Toolbars (z.B. beim Editieren) als eigene `UIToolbar` bauen.
- Lifecycle der Glass Buttons: in `viewDidLoad` erstellen und `toolbarHidden = YES` setzen, in `viewWillAppear` erneut verstecken, einblenden und nach vorn holen, in `viewWillDisappear` umgekehrt. Bei modaler Präsentation erben sie `overrideUserInterfaceStyle` nicht zuverlässig, das muss explizit gesetzt werden.
- Für iOS 25 und älter bleibt der System-Toolbar-Pfad parallel bestehen.

## iCloud Sync (`ICiCloudSyncManager`, iOS 17+)

Die Engine läuft mit `automaticallySync = false`. Sie synct also nie von selbst und wiederholt vor allem **nichts** von selbst: Jeder Fehlerpfad muss `scheduleSyncRetryAfterFailure` aufrufen (Backoff 15 s bis 300 s, kein Retry bei notAuthenticated oder quotaExceeded). Getriggert wird über Push, lokale Änderungen, manuellen Sync und den Foreground-Sync mit 15-Minuten-Throttle. Der Manager ist auf mehrere Dateien verteilt; seine Member sind bewusst `internal`, weil Swift-`private` file-scoped ist.

- **Pro Send-Batch nur ein Fetch** (`objectHash IN` bzw. `sourceURL_ IN`, mit properties-Prefetch). Ein Context plus Fetch pro Record erzeugt SQLite-Lock-Contention und friert beim Umschalten das UI ein.
- **Echo-Prävention über die tatsächlich mutierten ObjectIDs.** Zeitfenster-Flags reichen nicht, weil ObjectsDidChange gebatcht zugestellt wird, oft erst nach dem Flag-Reset. Eigene, direkt nach einem Send zurückkommende Records dürfen nur verworfen werden, wenn recordName, der exakte `recordChangeTag` dieses Prozesses und das `deviceID` übereinstimmen — ein `deviceID` kann per Backup auf zwei Geräten identisch sein. Settings laufen immer durch den Apply-Pfad.
- **Beim Apply nur echte Diffs schreiben** und den Fingerprint nachführen. Die Settings-Hash-Baseline muss persistent sein (`ICiCloudSyncSettingsSyncedHash`), sonst lädt jeder App-Start die Settings mit frischem Datum hoch und bricht Last-Writer-Wins. FeedProperty-Applies schreiben alle vier Wertfelder direkt und raten nie den Typ; uid-präfixte Keys haben keine UserDefaults-Defaults, und die Heuristik lieferte „bool" für Doubles.
- **Podcast-spezifische Settings sind dauerhafte `CDFeedProperty`.** Neue Keys müssen durch Backup-Export/Import und den Subscription-Sync laufen und dürfen nicht in `internalFeedPropertyKeys` stehen. Dazu gehören `PlayerNearChapterEndForwardSkipMode` und `PlayerNearChapterEndForwardSkipWindow`.
- **Eine ausgeschaltete Kategorie ist eingefroren:** Es wird nichts mehr angewendet, und Pendings bleiben liegen, weil die Engine bereits gefetchte Records nie erneut liefert. Beim Ausschalten wird der Device-Record final gesendet. Backfill-Start und -Completion hängen an der verifizierten CloudKit-Account-ID und am final bestätigten Cursor.
- **Das Einschalten des Abo-Syncs darf niemals Abos löschen.** Deletions werden bis zum ersten vollständigen Fetch unterdrückt (an `didFetchChanges` gebunden, nicht an den Abschluss eines Backfill-Laufs, der send-only ist); Nachhol-Deletions aus der Aus-Phase werden verworfen, die lokale Kopie gewinnt.
- **Das Einschalten des Settings-Syncs published nie sofort.** Kommen Cloud-Settings, wird der Payload geparkt und der Nutzer gefragt („aus iCloud übernehmen / meine für alle verwenden / später"). Kommt nichts, werden die lokalen published.
- **Der Erstabgleich einer Folge merged inhaltlich** statt nach Zeitstempel: gehört schlägt ungehört, die grössere Position gewinnt, Favorit schlägt nicht-Favorit; ein lokaler Gewinn wird mit frischem Datum zurückgepusht. Sobald ein Sync-Datum existiert, gilt reines Last-Writer-Wins, damit bewusste Edits propagieren.
- **Das Cloud-Inventar muss per recordName-Set dedupliziert werden**, weil ein Change-Stream-Fetch Records doppelt liefert. Gezählt werden nur Nutzer-Objekte (Abos, Folgenstatus, Settings), nie Hilfsrecords.
- **Stub-Feeds nie über `refreshFeed:` füllen.** Der Merge kennt kein Limit und legt bei leerem Feed alle Episoden in einem Main-Context-Push an, was das iPad unbenutzbar macht. Stattdessen `hydrateStubFeed:` mit initialen 50 Episoden und dem Rest über den `EpisodeLoadingManager`, pro Feed auf dessen Abschluss warten. Fehlgeschlagene Stubs müssen im Fehler-Set bleiben, sonst loopen tote Feeds endlos.
- **Keine fixen Pacing-Delays** (Vorgabe): Der `EpisodeLoadingManager` skaliert die Batch-Grösse an der gemessenen Main-Thread-Dauer, zwischen Batches gibt es nur Queue-Hops.
- **Die Abspielposition synct live und wird nie wieder gedrosselt** (Entscheid 12.06.). Die früher dafür verantwortlich gemachten CPU-Kills kamen aus dem Widget-Export. Wird dieser Pfad je wieder teuer, ist die Ursache zu fixen, nicht die Sync-Frequenz.
- Beim Statustext gilt: Aktivität ohne bewegte Records zeigt nichts an, und während eines Backfills bleibt „Lädt hoch… X/Y" stabil und monoton — die Grösse eines einzelnen Fetch-Callbacks ist nie der Nenner.
- `.invalidArguments` gilt beim Speichern als dauerhaft und wird verworfen, sonst blockiert ein einziger nicht speicherbarer Record dauerhaft alle anderen Typen.

## Widget-Export

Der Export war zweimal die Ursache für `cpu_resource_fatal`-Kills im Hintergrund-Playback und einmal für UI-Freezes. Vier Dinge halten das in Schach:

- **Ein eigener `NSPersistentStoreCoordinator`** (`DMANAGER.newExportBackgroundContext`) auf dieselbe SQLite-Datei, read-only benutzt. Ein normaler `newBackgroundContext` teilt den Main-Coordinator, hält bei langen Reads den Store-Lock und blockiert damit jede Core-Data-Operation auf Main.
- **Ein Gate pro Widget-Art:** Exportiert wird nur, was ein installiertes Widget auch liest (Cache über `WidgetKitHelper`, refresh bei Init und Foreground, unbekannt gilt als installiert).
- **Ein Background-Gate:** Voll-Export und Stats-Scan werden aufgeschoben, solange die App im Hintergrund abspielt, und beim Foreground geflusht. Playback-Transitionen bleiben bewusst ungegated, damit die Widgets die beendete Folge sofort zeigen.
- **Dedupe nach `uid`.** Der Store enthält historisch Duplikat- und Waisen-Listen (157 statt rund 6); ohne Dedupe bläht das sowohl den Export als auch den Widget-Picker auf. Beim Start räumt eine Migration auf.

Ausserdem: kein Vollcount pro Liste (der gezählte Wert ist die Anzahl tatsächlich exportierter Episoden, gekappt bei 14), und der Voll-Pass schreibt eine Datei nur bei echter Änderung der Episoden-Payload. WidgetKit weckt die App nicht für einen Export — fehlt die Snapshot-Datei, zeigt das Widget selbst einen Hinweis, dessen URL die App öffnet und den Export auslöst. Nachvollziehen lässt sich alles über die `widget-export`-Events im Diagnostics.jsonl.

## Transkription

- **End-to-End ist die Prüfeinheit (Vorgabe 06.09.).** Vor Änderungen den vollständigen Nutzerablauf und seine Zustandsübergänge prüfen: vollständige lokale Audiodatei → unveränderlicher Nutzerauftrag mit Audiohash → Serverdownload → Hashvergleich vor ASR → Verarbeitung → quellgebundener Import → Anzeige und Sprünge. Abweichende Dateien dürfen keine kostenpflichtige Verarbeitung für diesen Auftrag auslösen. Gemeinsame Serverarbeit muss passende und abweichende Nutzeraufträge getrennt behandeln. Abbruch, Dateiaustausch, Offlinephasen, Neustart und verlorene Antworten an jedem asynchronen Übergang berücksichtigen. Ein bestandener Importtest oder Build ist kein End-to-End-Nachweis; Abschluss braucht Tests der Übergänge und die tatsächlich geprüfte Geräte-/Serverdarstellung. Offene Teile ausdrücklich als offen benennen.
- **Playergesten hängen nicht vom Transkriptstatus ab.** Cover-Aufziehen, Scrollen, Schließen und Wiedergabesteuerung müssen während Download, Hashprüfung, Parsing, Import und Fehlerzuständen bedienbar bleiben. Keine synchrone Datei-/Analysearbeit in Gesten-, Layout- oder Darstellungspfaden; Hänger mit dem tatsächlichen UI-Pfad reproduzieren und messen.
- Serverzugriff, produktive Pfade, Queue-Limits und Prüfungen: `Tools/transcription-server.md`. Zugangsdaten liegen nur im Git-ignorierten `.codex/private/`; vor Serveränderungen immer den aktuellen Produktivstand prüfen.
- **Die Queue ist zweigeteilt** in lokale und Server-Aufträge; jeder abgeleitete Zustand (Sidebar-Eintrag, Badge, Toolbar) muss `displayItems` lesen, sonst sind reine Server-Aufträge und deren Fehler unerreichbar. Ein abgeschlossener oder fehlgeschlagener Eintrag bedeutet keinen Besitz der Episode: abgelehnt werden darf nur bei laufendem Auftrag, und die Ablehnung braucht UI-Feedback.
- **Server-SRT wird strikt und alles-oder-nichts geparst** (LF-only, genau ein `-->` pro Zeitzeile, Pflicht-Stunden, keine Überlappung, kein leerer Cue). Der Parser wird nicht aufgeweicht; er benennt die Verletzung im `transcript-parse`-Log, damit der Server gefixt wird.
- **Die Wildcard-Registrierung von `BGContinuedProcessingTask` wird abgelehnt**, obwohl der Eintrag im gebauten Info.plist steht. Registriert wird deshalb direkt der konkrete Identifier, und das Ergebnis muss geprüft werden, sonst fehlt der Fallback auf `BGProcessingTask`.

## Lokalisierung DE/EN

Vier voneinander unabhängige Mechanismen, alle gepinnt in `Tools/localization_coverage_regression_test.py` und `Tools/ios_integration_metadata_regression_test.py`:

- **`.ls` strippt ein abschliessendes „…" oder „:" vor dem Lookup** (`VemedioKit/Foundation+Localization.m`) und hängt es danach wieder an. Ein Key, der auf eines dieser Zeichen endet, wird deshalb nie gefunden, und der Originaltext leckt ins UI. Key ohne das Zeichen speichern, der Wert darf es behalten. `NSLocalizedString` verhält sich anders, dort ist der Key exakt — beide Formen können nebeneinander nötig sein.
- **Siri-Phrasen der App Shortcuts gehören in `AppShortcuts.strings`**, mit `${applicationName}`-Platzhaltern statt Swift-Interpolation. In `Localizable.strings` sind solche Keys wirkungslos. Prüfen lässt sich das an der `root.ssu.yaml` im gebauten Bundle, die je Locale die trainierten Sätze listet.
- **Die `.intentdefinition` muss über eine Variant Group lokalisiert sein**, sonst lehnt App Store Connect mit ITMS-90626 ab. Die Strings-Keys sind die ID-Werte aus der Definition, und alle 22 müssen in jeder Sprache stehen.
- **Bei doppelten Keys in einer `.strings`-Datei gewinnt der letzte** (gegen Foundation verifiziert, nicht nur mit `plutil`). Frühere Zeilen sind wirkungslos und verstecken abweichende Übersetzungen.
- Jedes Target hat seine eigene Tabelle: Keys für Widgets oder Watch müssen im jeweiligen Bundle liegen, das gilt auch für AppIntents-Metadaten. Berechtigungstexte brauchen `InfoPlist.strings` je Sprache, der Basiswert in der Plist ist englisch.

## Icons und Haptik

Swipe-Aktionen, Context-Menüs, Popup-Menüs, Toolbars, CarPlay und die Tab-Icons müssen für dieselbe Aktion dasselbe Symbol und dieselbe Farbe verwenden; die Wahrheit dazu steht in `_imageForSwipeAction:episode:` und `_tintColorForSwipeAction:episode:`. Destruktive Aktionen sind `systemRedColor`, inaktive Zustände `[UIColor colorWithWhite:0.5f alpha:1.0f]`, alles andere `ICTintColor` — nie hardcodiertes RGB.

Icon-only-Buttons brauchen ein `accessibilityLabel` mit demselben Wortlaut wie das Context-Menü. Swipe-Aktionen haben dafür kein API, dort wird das Label am Image gesetzt.

Haptik immer über `PlayHapticFeedback` (respektiert die Einstellung), leicht für Toggles und Skip, mittel für Play und Pause. Die Generatoren sind statisch und werden warm gehalten; pro Event einen zu allozieren bedeutet eine kalte Taptic-Engine mitten im Gesten-Commit und verursachte extremes Ruckeln. **Swipe-Aktionen bekommen keine App-Haptik**, weil UIKit dort bereits eine nicht abschaltbare System-Haptik spielt — auch nicht indirekt über geteilte Helper.

## macOS (Mac Catalyst)

- **`isiOSAppOnMac` ist bei Catalyst immer `false`**, es meldet nur „Designed for iPad"-Apps. Jedes Gate, das nur darauf prüft, greift auf dem Mac nicht — betroffen sind unter anderem `requestAuthorizationWithOptions:`, der Widget-Exporter und die Fenstergrösse. Ein echtes Mac-Gate prüft `TARGET_OS_MACCATALYST` bzw. `ProcessInfo.isMacCatalystApp`. **Ob der aktuelle Zustand Absicht ist, ist ungeklärt — vor einer Umstellung mit Chris klären.**
- **`[sdk=macosx*]`-Einstellungen greifen nicht**, weil ein Catalyst-Build das iPhoneOS-SDK verwendet. Es gilt deshalb `Instacast.entitlements` inklusive App Groups, und `InstacastMac.entitlements` ist wirkungslos.
- `llama.xcframework` hat keine Catalyst-Slice, weshalb die Build-Files auf iOS gefiltert sind: **auf dem Mac gibt es kein lokales GGUF-Kapitelmodell.** `TranscriptionEngine` blendet diese Modelle deshalb aus dem Katalog aus und muss dabei den Default-Kapitelmodell-Identifier mitziehen, sonst trappt die Modellauswahl auf einem fehlenden Default. WhisperKit, FoundationModels und Speech laufen auf dem Mac.
- `BGContinuedProcessingTask` gibt es auf Catalyst nicht; die betroffenen Stellen sind ausgeklammert und der Mac nutzt den normalen `BGProcessingTask`-Pfad.
- Watch-App und Widget-Extension werden über Platform-Filter aus dem Mac-Build gehalten.

## iOS 27 Siri / Apple Intelligence

- `ICAudioIntents.swift` bildet Podcasts/Episoden auf `AppSchema.AudioEntity.podcastShow` / `AppSchema.AudioEntity.podcastEpisode` und Wiedergabe auf `AppSchema.AudioIntent.playAudio` ab. Alle Schema-Typen sind ab iOS 27 verfügbar; die alten Entity-Typen bleiben für gespeicherte Kurzbefehle erhalten.
- Dieselben Core-Spotlight-Einträge sind ab iOS 27 mit den Audio-`IndexedEntity`-Typen verknüpft, inklusive vorhandener Kapitel-/Transkript-Metadaten. Die versionsgebundene Neuindizierung liest über den separaten Export-Coordinator und markiert erst nach erfolgreicher Indexbestätigung den Abschluss.
- Zell- und Detailansicht-Annotationen setzen nur IDs; bei Wiederverwendung/Leeren muss auch die Annotation gelöscht werden. Keine Fetches oder Bild-/Transkriptarbeit in diesem UI-Pfad.
- `python3 Tools/ios27_audio_schema_regression_test.py <InstacastPlus.app>` prüft die exportierten App-Intents-Metadaten des gebauten Bundles; für den Laufzeittest dient Apples `AppIntentsTesting`. Die Verfügbarkeit der neuen Siri hängt zusätzlich von Apples Sprach-/Regionsfreigabe ab.

## Nicht fixen (False Positives)

Observer-Leaks in Singletons (die leben ohnehin ewig), unsynchronisierte Reads, die nur auf Main passieren, `performBlockAndWait` in der `mergeQueue`, `reloadData` in `viewDidAppear` und das bewusste `dispatch_after` in der Import-Completion.

## Crash-Forensik

Über devicectl installierte Debug-Builds behalten die TestFlight-Receipt, `distributor_id` sagt also nichts über den Build aus — nur die slice_uuid zählt. Der App-Code liegt in `InstacastPlus.debug.dylib` mit eigener UUID, Frames werden mit `atos` gegen dieses dylib und das dSYM aus DerivedData symbolisiert. CPU-Kills erzeugen nicht pro Kill einen Report, drei Reports pro Tag können also viel mehr Kills bedeuten.
