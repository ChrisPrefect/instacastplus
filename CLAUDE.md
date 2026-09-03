# CLAUDE.md — InstacastPlus

App-Name: **InstacastPlus** (ein Wort, kein Leerzeichen, kein Bindestrich). Website: `https://instacast.ch`. App Store: `https://apps.apple.com/app/id6472283494`. Bundle ID: `com.iteconomy.instacastplus`. Team ID: `L95F4M2LHG`.

Podcast-App iOS/macOS, Objective-C. v3.2. Aktuelles iOS-Deployment-Target: 17.0. Ein vollständiger Kompatibilitäts-Build bis iOS 16.4 ist mit Availability-Gating der iOS-17-iCloud-Oberfläche möglich; iOS 13 wird von den eingebundenen Transkriptionsabhängigkeiten nicht unterstützt. CarPlay, AVFoundation, OPML, Podlove Chapters.

## Lokaler Dateistand ist die einzige Versionsquelle

- Für Analyse, Tests, Builds und Releases zählt ausschliesslich der aktuelle Inhalt der Dateien auf der lokalen Platte. Dazu gehören ausdrücklich alle uncommittierten und ungetrackten Dateien.
- **Am Repo wird parallel gearbeitet.** Chris bearbeitet mehrere Bugs gleichzeitig, Dateien ändern sich also während einer laufenden Session von aussen — ebenso Build-Nummer, pbxproj und Info.plists. Vor jeder Analyse und vor jeder Änderung die betroffene Datei NEU einlesen, nie auf einen früher im Gespräch gelesenen Stand verlassen. Fremde Änderungen im Working Tree nie zurückdrehen, nur benennen.
- Git-Commits, Branches, Tags, Remotes und GitHub definieren in diesem Projekt niemals einen Versions- oder Release-Stand. GitHub dient nur als Backup. Commit-IDs dürfen nicht als Beleg dafür verwendet werden, welcher Code in einem Build enthalten ist.
- `git status` und Git-Diffs dürfen nur helfen, lokale Dateien zu inventarisieren; sie dürfen den Plattenstand weder einschränken noch ersetzen.
- Unmittelbar vor einem Archiv müssen alle relevanten lokalen Quell-, Konfigurations- und Ressourcendateien inventarisiert werden. Nach dem Archiv und vor dem Upload muss geprüft werden, ob sich dieser Plattenstand geändert hat. Bei Änderungen ist das Archiv veraltet und muss aus dem neuesten lokalen Dateistand neu erstellt werden.

## Build — nicht immer automatisch builden! nur bei grösseren änderungen selbst test-builden.

Nutzerfreigabe: Builds sowie das Booten und Benutzen vorhandener Simulatoren sind jederzeit und ohne erneute Rückfrage erlaubt. Diese Freigabe hebt nicht die Vorgabe auf, bei kleinen Änderungen fokussierte Tests statt unnötiger Vollbuilds zu bevorzugen.

Vorhandene Targets/Schemes (`xcodebuild -list`): `Instacast`, `InstacastWatch`, `InstacastWidgets`, `InstacastWatchWidgets`. Es gibt KEIN Scheme „Instacast HD" und keines namens „InstacastMac" — iPhone und iPad kommen aus demselben `Instacast`-Target.

```bash
xcodebuild -project Instacast.xcodeproj -scheme Instacast build           # iPhone + iPad (ein Target)
xcodebuild -project Instacast.xcodeproj -scheme Instacast \
  -destination 'platform=macOS,variant=Mac Catalyst' build                # macOS (Catalyst)
xcodebuild -project Instacast.xcodeproj -scheme InstacastWatch \
  -destination 'generic/platform=watchOS' build                           # Watch
for t in Tools/*regression_test*.py; do python3 "$t"; done                # Tests (kein XCTest-Scheme im Projekt)
```

**Der Mac-Build ist Mac Catalyst** (`SUPPORTS_MACCATALYST = YES`), NICHT „Designed for iPad" (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO`). `xcodebuild -showdestinations` listet als einzige macOS-Ziele `{ platform:macOS, variant:Mac Catalyst, name:My Mac / Any Mac }`. `SUPPORTED_PLATFORMS = "iphonesimulator iphoneos"` widerspricht dem nicht — Catalyst wird als iOS-Platform-Variante gebaut. Zum Zustand der Mac-spezifischen Gates siehe Abschnitt „macOS (Mac Catalyst)".

Am 03.09. entfernt (alles nachweislich in keinem Target und von keinem Code referenziert): das Aggregate-Target `MergeLocalizations` samt Script (rief `${vemedio_tools}/wincent-strings-util` auf — Variable nirgends definiert, Binary war ein nicht mehr ausführbares ppc/i386-Mach-O, und ein Merge hätte die kuratierten `Localizable.strings` überschrieben), `Tools/wincent-strings-util`, der Ordner `InstacastMac/` (zwei tote Xcode-Vorlagen-Gerüste; `InstacastMac.entitlements` im Repo-Root bleibt, wird beim Catalyst-Build aber gar nicht verwendet — siehe „macOS (Mac Catalyst), die nirgends geladenen Nibs `DirectoryViewController.xib` + `PlayerInfoController.xib` (wurden mit ausgeliefert) und `Classes/EpisodesTableViewController.xib`. **`Resources-iPad/` bleibt** — die iPad-`Defaults.plist`, `Instacast HD-Info.plist` und `Settings.bundle` sind kein Müll, sondern von 8 Regressionstests gepinnt (sie halten die iPad-Defaults mit den iPhone-Defaults synchron).

Simulator-Smoke-Test: iOS-App NIE mit `CODE_SIGNING_ALLOWED=NO` für den Simulator bauen — das entfernt alle Entitlements, `CKContainer.init` trapt dann beim Launch (EXC_BREAKPOINT in `ICiCloudSyncManager.init`) und die App Group fehlt (Widget-Exporte no-op). Normale Simulator-Destination ohne Flags signiert lokal automatisch.

## TestFlight / App Store Connect

App Store ID: `6472283494`. Bundle ID: `com.iteconomy.instacastplus`. Team ID: `L95F4M2LHG`.

ASC API Key:
- Key ID: `7QUKV6MHZ2`
- Issuer ID: `69a6de70-cba8-47e3-e053-5b8c7c11a4d1`
- Private Key lokal: `/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8`

Private-Key-Inhalt NIEMALS ins Repo, in Logs oder in Chat-Ausgaben kopieren.

Release-Regeln:
- Vor Upload Build-Nummer erhöhen, z.B. `agvtool new-version -all <next-build>`.
- Archivieren mit `xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Release -destination 'generic/platform=iOS' -archivePath build/TestFlight/InstacastPlus-<version>-<build>.xcarchive -allowProvisioningUpdates archive`.
- Upload mit `xcodebuild -exportArchive -archivePath build/TestFlight/InstacastPlus-<version>-<build>.xcarchive -exportOptionsPlist build/TestFlight/ExportOptionsUpload.plist -allowProvisioningUpdates`.
- Für externe TestFlight-Freigaben ASC API Key verwenden, Verarbeitung abwarten/pollen und erst nach App-Store-Connect-Status bestätigen.
- **Vor jedem Upload CloudKit-Schema prüfen** (Debug-Builds legen neue Record-Typen automatisch in Development an, Production bleibt zurück — der Fehler ist im eigenen Log NIE sichtbar und killt den Sync aller Nutzer komplett):
  ```bash
  for env in production development; do xcrun cktool export-schema --team-id L95F4M2LHG --container-id iCloud.com.iteconomy.instacastplus --environment $env --output-file /tmp/$env.ckdb; done; diff /tmp/production.ckdb /tmp/development.ckdb
  ```
  Bei Unterschieden: CloudKit Console → Container `iCloud.com.iteconomy.instacastplus` → *Deploy Schema Changes…* (`cktool` kann Production nicht schreiben).
- Tester immer benachrichtigen.
- `What to Test` jeweils selbst auf Deutsch setzen; kurz und konkret die nutzerrelevanten Änderungen dieser Version beschreiben.
- Bei Watch-, Playback-, Download- oder Info.plist-Änderungen vor TestFlight IMMER das gebaute/archivierte Watch-Bundle prüfen: `plutil -p <archive-or-build>/Products/Applications/InstacastPlus.app/Watch/InstacastWatch.app/Info.plist` muss `UIBackgroundModes = (audio)` enthalten. Nicht aus Source-Plist oder einem grünen String-Test auf das Archiv schließen.
- Build `3.4 (10)` wurde am 23.05.2026 bereits vom User für externe Tester freigegeben; nicht erneut freigeben.

## Architecture

Prefixes: `CD*` = Core Data (`CDFeed/CDEpisode/CDMedia/CDChapter/CDBookmark/CDPlaylist/CDSmartPlaylist/CDEpisodeList`), `IC*` = Parser immutable (`ICFeed/ICEpisode/ICMedia/ICChapter/ICCategory`), `VM*` = VemedioKit.

Singletons: `DMANAGER`, `CacheManager.sharedCacheManager`, `AudioSession.sharedAudioSession`, `PlaybackManager.playbackManager`, `SubscriptionManager.shared`, `UIManager.shared`, `ImageCacheManager`.

Dirs: `Classes/Model/` (CD), `Classes/Parser/`, `Classes/Metadata/` (Chapters), `VemedioKit/` (Extensions), `VemedioDatabase/` (FMDB).

Flow: `main.m → Application → InstacastAppDelegate → MainViewController_4`

Macros (pch): `DMANAGER`, `USER_DEFAULTS`, `DebugLog(format, ...)`, `WEAK_SELF/STRONG_SELF`

URL Schemes: `podcast:// itpc:// instacast3:// instacast:// instacast-subscribe:// podcast-subscribe://`

Conventions: `DMANAGER` für DB. `NSNotifications` für State. Categories für Foundation/UIKit. `#if TARGET_OS_IPHONE` für Plattform. Resources: `Resources-iPhone/`, `Resources-iPad/`. UI-Texte zweisprachig (DE+EN) in `Localizable.strings`.

## Debugging

- Keine Workarounds/Fallbacks — echte Ursache fixen
- Keine `dispatch_after`/delays zum Kaschieren
- Keine eigenmächtigen Umbauten — erst analysieren, loggen, NACHFRAGEN
- Keine Vermutungs-Fixes — DebugLogs → User testen → Logs analysieren → dann erst Fix
- Jede Änderung dokumentieren: Problem, Grund, Lösung

## Dark Mode

`ICAppearanceManager`. `updateAppearance` nochmals nach Window-Erstellung in SceneDelegate (Window bei `+initialize` nil). Farben: immer `ICBackgroundColor/ICTextColor/ICTintColor`, nie hardcodiert. `ICNightAppearance`: explizite statt dynamischer Farben. Observer: `viewDidLoad` registrieren, `dealloc` entfernen. reloadData: Hauptmenüs immer, Detail-Views nur wenn `tableView.window && !transitionCoordinator`.

## Player Controls Height

`PlayerController.m`: `MAX(windowHeight - statusBarHeight - 44 - windowWidth - 70, 194)`. 70=Überlappung Chapter Art, 194 aus `PlayerControlView.xib`.

## Apple Watch / watchOS Playback

Watch-Playback darf nicht mehr durch falsche Projektannahmen brechen. Bekannte Regression: Eine spätere Änderung erzwang `WKBackgroundModes/audio`; App Store Connect lehnt diesen Wert für Watch-Audio mit 90362 ab. Für Long-Form-Audio muss das Watch-Bundle `UIBackgroundModes/audio` enthalten und der Player eine Long-Form-`AVAudioSession` aktivieren.

Regeln:
- Das ausführbare Watch-App-Bundle (`InstacastWatch.app`, NICHT die iOS-App) MUSS `UIBackgroundModes` mit `audio` enthalten. `WKBackgroundModes/audio` ist für Watch-Audio kein gültiger App-Store-Connect-Wert.
- `WatchPlayerController` muss vor Playback `AVAudioSession` mit `.playback`, `mode: .default`, `policy: .longFormAudio` konfigurieren und per `activate(options: [])` asynchron aktivieren. Kein Rückbau auf `setActive(true)` oder foreground-artige Session.
- `WatchDownloadManager` darf eine Datei erst als `.downloaded` markieren, wenn HTTP-Status, Dateigröße und AVFoundation-Playability stimmen. HTTP 206 Partial Content, leere Dateien und Dateien kleiner als `countOfBytesExpectedToReceive` müssen fehlschlagen; sonst entstehen kurze/trunkierte Dateien, die nur ein paar Sekunden spielen.
- **Trunkierte Downloads ohne Content-Length (Ursache „bricht nach 6–8 s ab", bewiesen 05.07. im watchOS-26.5-Simulator):** Sauberer Connection-Close ohne Content-Length gilt für URLSession als Erfolg; ein 120-KB-Prefix einer 90-min-MP3 besteht alle HTTP-Checks UND `isPlayable`, spielt exakt 7,5 s, „endet erfolgreich" und markierte die Folge als komplett gehört (inkl. Propagation an iPhone/iCloud). Drei Schichten müssen bleiben: (1) Download-Validierung fällt ohne Transport-Größe auf die Feed-Enclosure-Größe zurück (< 50 % = fail), (2) gemessene AVFoundation-Dauer < 50 % eines `durationHint` ≥ 600 s = fail, (3) `audioPlayerDidFinishPlaying` mit `flag=true` aber Dauer < 50 % des Hints = trunkierte Datei → NICHT consumed, Datei löschen + requeuen (heilt Bestandsdateien auf Kunden-Watches — deren `expectedBytes` wurde beim „erfolgreichen" Download mit der Ist-Größe überschrieben, nur der `durationHint` zeigt die Trunkierung noch). Schicht 1 bleibt nur scharf, wenn `didWriteData` `expectedBytes` NIE mit `max(0, -1) = 0` überschreibt (ohne Content-Length meldet der Transport -1; der erste Progress-Callback löschte sonst die Feed-Enclosure-Größe, bevor die Validierung sie braucht) — nur bei `totalBytesExpectedToWrite > 0` schreiben; auch der Truncated-Requeue im Player behält `expectedBytes`. Festgepinnt: `Tools/watch_truncated_download_regression_test.py`. Aggregierter iOS-Downloadstatus (`watchDownloadProgressLoadedBytes`) überspringt `evicted` UND `failed` — sonst bleibt „Watch lädt Podcasts (x von y)" bei einer fehlgeschlagenen Folge für immer stehen.
- **Freier Watch-Speicher über `volumeAvailableCapacityKey` als raw `NSNumber.int64Value` lesen** (`WatchStorageManager.freeBytes()`, clamp `max(0,…)`). Nicht `URLResourceValues.volumeAvailableCapacity` verwenden: Der Swift-Typ ist auf watchOS `arm64_32` `Int`-groß und wird bei Multi-GB-Werten NEGATIV (gemessen ~−755 MB bei real ~18 GB frei, Kunden-Log 26.06.) → Speicher-Sperre lehnt JEDEN Download ab („Speicher voll · 0 geladen"). `volumeAvailableCapacityForImportantUsageKey` ist auf watchOS unavailable. Den alten typed Wert nur für Diagnose (`rawAvailableBytes()`/`rawFreeBytes`) loggen, NIE zum Gaten. Festgepinnt: `Tools/watch_download_storage_eviction_regression_test.py`.
- **Swift-6-Callback-Isolation (Play-Crash, bewiesen via symbolisierte .ips 05.07.):** Das Watch-Target läuft mit `SWIFT_VERSION = 6.0`. Closures, die in `@MainActor`-Kontext gebildet und an NICHT-`NS_SWIFT_SENDABLE`-annotierte ObjC-APIs übergeben werden, erben MainActor-Isolation — ruft das Framework sie auf seiner eigenen Queue auf, trapt die Runtime mit `EXC_BREAKPOINT`. Betroffen waren: `WCSession.sendMessage`-errorHandler (jeder fehlgeschlagene reliable-Send crashte die App), alle `MPRemoteCommandCenter.addTarget`-Handler (Crash ~2 s nach Play-Start, sobald Kopfhörer verbunden — MediaRemote feuert dann die Commands), `MPMediaItemArtwork`-requestHandler, `AVAudioSession.activate`-Completion. JEDER solche Closure MUSS `@Sendable` sein und für Actor-State explizit per `Task { @MainActor in … }` hoppen. Zusätzlich: Fehlgeschlagene Session-Aktivierung (keine Kopfhörer) darf NIE die Download-Datei löschen. Festgepinnt: `Tools/watch_swift6_callback_isolation_regression_test.py`.
- **Watch-Downloads laufen SEQUENTIELL** (User-Entscheid 06.07.): immer nur ein Download, in Abspielreihenfolge (`startNextQueuedDownloadIfIdle`), der nächste startet in `didCompleteWithError`. Drei parallele Downloads kämpften ums langsame Watch-Funk und keiner wurde fertig. Nutzer-Tap (`prioritizeEpisode`) startet weiterhin sofort. Festgepinnt in `Tools/watch_download_storage_eviction_regression_test.py`.
- **iOS-Downloadstatus ist AGGREGIERT** (User-Entscheid 06.07.): `watchDownloadProgressLoadedBytes:totalBytes:` summiert über den gesamten gewollten Bestand („x MB von TOTAL MB"), nie den flackernden Einzel-Download anzeigen. Watch sendet während Downloads alle 10 s `watch.storageStatus`, damit Speicherbalken live mitlaufen; das Manifest-`persist()` läuft hinter der 2-s-Progress-Drossel (vorher voller JSON-Write pro didWriteData-Callback).
- **Phone-Handler-Kosten:** `watch.diagnostic` wird VOR dem Save/Notify-Tail behandelt (nur Logging) — Diagnostik ist die volumenstärkste Message-Klasse und kam nach Unreachable-Phasen als Burst (transferUserInfo-Queue) → Main-Thread-Freeze. `[DMANAGER save]` im Handler nur bei `objectContext.hasChanges`; `_playbackDidUpdate` (feuert 1×/s!) sendet/speichert nur bei tatsächlich geänderter Position/consumed.
- **Skip-Regeln im Watch-Manifest:** `skipChapterNames` (Feed-Property `{uid}_auto_skip_chapter_name`, Split „.  ") + `autoSkipSponsors` (per-Feed „yes"/„no", sonst global) gehen pro Episode mit; die Watch markiert Kapitel per case-insensitivem `contains` + „Sponsor:"-Prefix als „Wird übersprungen" (gleiche Semantik wie `matchingSkipNameForChapter`). KI-generierte Sponsor-Kapitel existieren nur auf dem iPhone und erscheinen nicht in der Watch-Kapitelliste (Watch extrahiert Kapitel aus der Mediendatei).
- **Delegate-Ordnung Download-Abschluss (Race, bewiesen 06.07. im Simulator):** `didFinishDownloadingTo` staged die Datei nur (Lock-Map `stagedLocationsByTaskIdentifier`; Hash-Keying vermischt alte und neue Tasks derselben Folge); Validierung/Registrierung + Queue-Fortschaltung laufen aus `didCompleteWithError` (kommt auf der seriellen Delegate-Queue garantiert danach). Vorher startete der nächste Download, bevor die fertige Folge als `.downloaded` registriert war → sie belegte Platz, war aber kein Eviction-Kandidat → neue Folge bei knappem Speicher fälschlich „Speicher voll".
- **Download-Validierung braucht Datei-Extension:** Media-URLs ohne Path-Extension (Tracking-Redirects) → AVFoundation kann Container nicht sniffen → `isPlayable` liefert optimistisch true und Dauer 0 (bewiesen: 300 KB Zufallsbytes passierten als „downloaded"). Deshalb: Extension-Fallback aus Response-MIME-Type (`fileExtension(forMIMEType:)`) UND `duration <= 0` = harter Validierungsfehler.
- **Simulator-Tests Watch (Setup 06.07.):** Harness in Scratchpad `watchtest/` (server.py mit Fehlerfall-Endpoints, manifest.py injiziert `Library/Application Support/WatchManifest/manifest.json` in den App-Container, run_round.sh). Background-URLSessions funktionieren im watchOS-Sim NICHT (nsurlsessiond-XPC 4097) → `#if targetEnvironment(simulator)` nutzt Default-Session (identische Delegate-Pfade). Das Watch-Target hat KEIN `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG` — Swift-`#if DEBUG` ist dort nie aktiv; für Sim-Builds `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG` ans xcodebuild übergeben. Speicher-Szenarien über DEBUG-Seam: Datei `WatchManifest/simulated-free-bytes.txt` im Container = virtuelles Disk-Budget (UserDefaults/Launch-Args erreichen die sandboxed Watch-App nicht). Verifiziert: 404/leer/Garbage/206/Trunkierung (beide Schichten), Pre-Check-Block unter Reserve, Eviction nach Abspielreihenfolge, Live-Guard-Abbruch (~10 MB in Reserve), AutoFill nach Platzfreigabe.
- Ein Source-Test reicht bei Watch-Lifecycle-Themen nie allein. Immer das gebaute Produkt prüfen, weil Xcode/Archive-Processing Plists und eingebettete Watch-Bundles verändern kann.

Pflichtchecks bei Änderungen an `InstacastWatch/`, `AppleWatchSyncManager`, Watch-Widgets, Watch-Downloads, Playback oder Watch-Info.plist:
```bash
python3 Tools/apple_watch_integration_regression_test.py
python3 Tools/watch_audio_now_playing_regression_test.py
xcodebuild -project Instacast.xcodeproj -scheme InstacastWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
WATCH_PLIST=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug-iphoneos/InstacastPlus.app/Watch/InstacastWatch.app/Info.plist' -print -quit); plutil -p "$WATCH_PLIST"
```

## iOS 26

### Liquid Glass

`edgesForExtendedLayout = UIRectEdgeBottom` (NICHT `UIRectEdgeNone`!). Opake NavBar: `UINavigationBarAppearance` mit `backgroundImage`. NICHT: `hidesSharedBackground`, `UIButtonTypeCustom` customView, opake Views hinter Bar.

### Floating Toolbar → Custom Glass Buttons

`FloatingBarHostingView` blockiert 86pt Touch-Zone über Toolbar-Pill. Kein API-Fix. Swizzling NIEMALS.

**Lösung:** `toolbarHidden=YES`, eigene `UIButton`s mit `glassButtonConfiguration` + `buttonSize=Large` auf `navigationController.view`.

**KRITISCH: `toolbarHidden` NIEMALS toggeln (YES→NO→YES)!** `NO` erzeugt `FloatingBarContainerView` die nach erneutem `YES` bestehen bleibt, Touches blockiert. Für temp. Toolbars (Editing) eigene `UIToolbar`.

Zwei Pfade: iOS ≤25 → System-Toolbar (`_updateToolbarItemsAnimated:`), iOS 26 → Glass Buttons (`@available`).

Lifecycle: `viewDidLoad` → `toolbarHidden=YES`, Buttons erstellen. `viewWillAppear` → `toolbarHidden=YES`, `.hidden=NO`, `bringSubviewToFront:`. `viewWillDisappear` → `toolbarHidden=NO`, `.hidden=YES`.

Theme: Glass Buttons erben `overrideUserInterfaceStyle` nicht zuverlässig bei modaler Präsentation → explizit setzen bei Erstellung + `updateAppearance` basierend auf `nightSettingMode`.

Umgestellt: `SubscriptionsTableViewController`(Add+Sort), `EpisodesTableViewController`(Edit; Editing nutzt eigene UIToolbar), `DirectoryFeedViewController`(Share), `WebController`(Back+Forward KVO, Safari), `FeedViewController`(Reload+Share+Settings).

Layout: `UIRectEdgeBottom` auf allen VCs mit Toolbar/Buttons. **Ausnahme:** `PlayerController` nutzt `UIRectEdgeNone` (Höhenberechnung, keine Toolbar).

### Zell-Swipe: Debug-Build ≠ Release-Performance

Swipe-Performance IMMER im Release-Build ohne Debugger beurteilen. In Debug ist `DebugLog` = synchrones `NSLog` (pch), am Xcode-Debugger nochmal ~10× teurer — Swipes/Scrolling wirken dort „unbenutzbar" (1fps, verschluckte Gesten), obwohl der Release-Build (TestFlight/Nutzer) flüssig ist. Ein Debug-Build vom Homescreen (ohne Debugger) ist nur „leicht besser": weiterhin unoptimiert + `os_log`. Erst wenn ein RELEASE-Build ohne Debugger ruckelt, im Code nach echtem Main-Thread-Stall suchen (nicht am Debug-Symptom raten).

Zell-Swipe nutzt EIN System: UIKits `UISwipeActionsConfiguration` (`leading/trailingSwipeActionsConfigurationForRowAtIndexPath`, liest `EpisodeSwipeLeft/RightAction`). Der Legacy-Custom-Pan (`EpisodesTableViewCell.handlePan:`/`panRecognizer`) ist per `setUsesNativeSwipeActions:YES` (in JEDEM `cellForRow`: EpisodesTVC, UpNext, Watch, PlayerInfo) deaktiviert. Bei neuen Listen mit `EpisodesTableViewCell` immer `cell.usesNativeSwipeActions = YES` setzen, sonst wäre der Legacy-Pan aktiv und kollidierte mit UIKit.

iOS-26-Content-Pop-Geste („Swipe-Back von überall", `interactiveContentPopGestureRecognizer`): kollidiert MIT den Zell-Swipe-Aktionen (belegt 09.07.) — während die Zurück-Animation einer Zelle noch nachläuft, wird ein Swipe auf eine andere Zeile von der Content-Pop-Geste gegriffen und poppt die GANZE View zurück statt die Row-Action zu zeigen. Deshalb auf Episodenlisten in `viewWillAppear` `interactiveContentPopGestureRecognizer.enabled = NO`, in `viewWillDisappear` wieder `= YES`. Edge-Swipe (`interactivePopGestureRecognizer`) + Back-Button bleiben für Navigation.

### Scroll Edge Effect

`scrollView.bottomEdgeEffect.hidden = YES` (iOS 26+). Angewendet: `SubscriptionsTableVC`, `FeedEpisodesTableVC`, `DirectoryFeedVC`, `EpisodeVC`, `WebController`, `FeedVC`.

## TODO iOS 27 Siri / Apple Intelligence

Erst umsetzen, wenn lokal ein iOS-27-SDK/Xcode-Beta verfügbar ist; keine Stub-Typen oder Kompatibilitäts-Workarounds einbauen:
- App-Intents auf die neuen Apple-App-Schemas für Audio/Podcasts mappen (`AppSchema.AudioEntity.podcastEpisode` / Podcast-Show, `AppSchema.AudioIntent.playAudio`).
- Podcast-, Episode-, Kapitel- und Transkript-Metadaten als iOS-27-`IndexedEntity`/semantische Spotlight-Daten bereitstellen, damit die neue Siri Episoden inhaltlich findet und passende Playback-Intents ausführen kann.
- Relevante Views mit iOS-27-View-Annotations versehen, sobald die API stabil ist.
- Siri/App-Intent-Verhalten mit `AppIntentsTesting` gegen echte Podcast-/Episoden-Parameter absichern.

## Apple Podcast Charts

Neue API: `rss.marketingtools.apple.com/api/v2/{country}/podcasts/top/{limit}/podcasts.json` (max 100, kein Genre).
Alte API: `itunes.apple.com/{country}/rss/toppodcasts/limit={limit}/genre={genreId}/json` (max 200, Genre per URL).
Lookup: `itunes.apple.com/lookup?id={id}&entity=podcast`.
Impl: `ApplePodcastChartsClient` — Phase 1 neue(50), Phase 2 alte(20/Genre parallel), Merge+Dedup. Sub-Kategorien haben eigene Charts.

## Pull-to-Refresh Performance (Stotter-Fixes 06.07.)

Der Merge-Context ist ein CHILD des Main-Contexts — alle Merge-Fetches/Faults sind Main-Thread-Zeit (`feed-refresh-profile`-Events loggen mergeSeconds/mainSeconds). Deshalb darf während des Refresh NICHTS zusätzlich synchron auf dem Main Thread laufen:

- **Spotlight (`ICSpotlightIndexer`):** Raw-Snapshot (nur CD-Reads) auf dem aufrufenden Thread, alles Teure (HTML-Stripping, SRT-/chapters.json-Reads, CSSearchableItem-Bau) auf der seriellen `indexQueue`. Feed-Trigger in `DatabaseManager` bewusst OHNE `lastUpdate` — der wird bei JEDEM Feed bei JEDEM Refresh geschrieben und re-indexte sonst die ganze Abo-Liste pro Pull.
- **FTS (`ICFTSController`):** `FMDatabaseQueue inDatabase:` ist dispatch_SYNC. Einzel-Writes laufen async über die serielle `writeQueue`; HTML-Stripping in `_replaceEpisodeSnapshot` auf der DB-Queue, nie beim Snapshot auf Main.
- **`updateLocalFeedInfo` newer-Branch diff-gated:** Core Data markiert Objekte auch bei identischem Wert als updated → jede dirty Episode feuert die Observer-Kaskade (FRC, Widget, Spotlight, FTS).
- **`WidgetDataExporter _episodesAdded` debounced (2s):** feuert 1×/Feed; Stats+Lists-Export + 2 Timeline-XPC pro Feed liefen sonst parallel zu den Merges (Store-Lock-Contention).
- **`ListEpisodesTableViewController`:** `list.numberOfEpisodes`-KVO-Reload während `refreshing` per `coalescedPerformSelector` 1s gebündelt; der Coalesced-Pfad konsumiert `suppressNextListReload` (gepinnt in `Tools/episode_swipe_actions_regression_test.py`).

Historie: Stottern begann mit der Duration-Regression 25.04. (Voll-Merge aller Feeds pro Refresh), 03.06. etag-seitig gefixt. Feeds mit rotierenden Tracking-URLs (contentHash ändert sich jedes Mal) laufen weiterhin bei jedem Refresh durch den vollen Merge — obige Regeln halten das UI trotzdem flüssig.

## Duration-Metadata-Refresh (Pull-to-Refresh-Regression 25.04.)

`_feedNeedsDurationMetadataRefresh` (für Transkript-Feature) darf pro Feed nur EINMAL einen Voll-Parse erzwingen (`kFeedPropertyDurationRefreshAttempted`, internal-FeedProperty, nach Erfolg gesetzt) — sonst verliert jeder Feed mit dauerlosen Episoden (viele liefern nie `itunes:duration`) PERMANENT sein etag-Caching → Refresh 3-4× langsamer + Voll-Merges. Der Check ist ein SQL-Count (`countForFetchRequest`), NIE eine `feed.episodes`-Iteration — die feuerte beim Refresh-Start 53× alle Episoden-Faults auf Main (~5s-Freeze beim Pull).

## UITextView Non-Contiguous Layout

`scrollEnabled=YES` → geschätzte Zeilenhöhen. `textStorage beginEditing/endEditing` an entfernten Stellen → partielle `ensureLayoutForCharacterRange` lässt Lücken → `contentSize` springt → Scroll-Position zerstört. **Fix:** Immer `ensureLayoutForCharacterRange:NSMakeRange(0, textStorage.length)`.

## Bug-Hunt Erkenntnisse

### Singleton: KEIN dispatch_once!

`gShared = [self alloc]; gShared = [gShared init];` — `init` greift rekursiv via `DMANAGER` zu. `dispatch_once` deadlockt bei Reentrancy. Split-Pattern setzt `gShared` nach `alloc`, rekursiver Aufruf bekommt teilinitialisierte Instanz.

### Bekannte Patterns (gefixt)

- **`AVRoutePickerView` skaliert seinen Glyph mit den Bounds (AirPlay-Icon doppelt so gross, 03.09.):** Beim Wechsel `ICVolumeView : MPVolumeView` → `AVRoutePickerView` fiel die einzige Grössenangabe weg (`setRouteButtonImage:ICPlayerToolSymbol(@"airplayaudio", 26.f)`); die neue Klasse hat KEINE Bild-API. Im 84-pt-Werkzeug-Slot der Player-Toolbar rendert sie dadurch einen 52.7-pt-Glyph neben ~25-pt-Nachbarn. Im Simulator gemessen: `Glyph ≈ 0.83 × Bounds − 17`, unterhalb ~42 pt Bounds bei ~18 pt geklemmt (deshalb wirken kleine Werte scheinbar gar nicht). Lösung: `ICVolumeView` ist ein `UIView`-Container, der den Picker mittig auf 50 pt legt (→ 23.3 pt) und `hitTest:` auf den vollen Slot durchreicht, damit das Tap-Ziel 84 pt bleibt. Messmethode für solche Fälle: Simulator-Screenshot + Spaltenscan (Swift/CoreGraphics), nicht schätzen. Festgepinnt: `Tools/player_control_icon_regression_test.py`, `Tools/ios_airplay_sharing_regression_test.py`.

- **Liste springt beim Scrollen von alleine an den Anfang (Kundenbug 02.09.):** `ListEpisodesTableViewController` paginiert (25/Seite). `updateEpisodes` verwirft `loadedEpisodes`, setzt `nextPageOffset = 0` und ruft `reloadData` — die Tabelle ist kurz LEER, `contentSize` kollabiert, UIKit klemmt `contentOffset` auf 0. Aufgerufen wird das aus dem KVO auf `list.numberOfEpisodes`, und der feuert bei JEDER Zähleränderung (Feed-Refresh, fertig gehörte Folge, angewendeter iCloud-Status). Die vorhandenen Gates greifen dort nicht: `suppressNextListReload` ist für Swipe-Row-Updates, `userAction` für explizite Edits, `_deferEpisodeReloadDuringInteraction` nur für Swipe/Context-Menü, die 1-s-Koaleszenz nur während `refreshing`. Fix: während `dragging`/`decelerating` wird der Reload per `coalescedPerformSelector` verschoben, und ab der zweiten geladenen Seite wird vorher `_storeScrollPosition` + `_didRestoreScrollPosition = NO` gesetzt — die bestehende Restore-Schleife blättert dann bis zur Zielposition zurück. Diagnose: `list-scroll`/„Listen-Neuaufbau nach Zähleränderung". Festgepinnt: `Tools/list_scroll_position_reload_regression_test.py`.

- **Quell-Liste für fortlaufendes Abspielen: der Arm muss immer konsumiert werden (bewiesen 02.09. aus Kundenlog + Code):** `ListEpisodesTableViewController` armt `notePlaybackSourceEpisodeList:` VOR der Player-Präsentation, konsumiert wird der Arm aber nur in `AudioSession._playEpisode:`. Tippt man Play auf der Episode, die bereits geladen ist (in „Zuletzt gespielt" ist die oberste Zeile per Definition genau diese Episode), nimmt `PlaybackViewController._presentFromParentViewController:` den reinen `[pman play]`-Zweig — der Arm überlebt und wird auf die NÄCHSTE irgendwo gestartete Episode angewendet. Da „Zuletzt gespielt" jede kürzlich gespielte Folge matcht, klebte die Liste danach dauerhaft (`preservingPlaybackSource:YES` bei jeder Fortsetzung). Deshalb ruft die Präsentation immer `applyPendingPlaybackSourceToCurrentEpisode` auf. Festgepinnt: `Tools/playback_source_ownership_regression_test.py`. Diagnose: `playback-continuation`/„Folgeepisode bestimmt" nennt `source` (`upnext`/`source-list`/`feed`/`none`) + `sourceListUID`.
- **„Gehört" und „Restzeit 0" haben ZWEI verschiedene Dauern (Kundenbug 02.09.):** Die Zelle rechnet `episode.duration - episode.position` (Feed-`itunes:duration`), `playerItemDidPlayToEndTimeNotification` prüft `[self time] > [self duration] - 10` (AVAsset-Dauer), und `_continueOpeningAsset` startet bei `position >= episode.duration - 5` wieder bei 0. Bei Feeds mit dynamischer Werbung (Acast u.a.) ist die Mediendatei länger als die Feed-Angabe — im selben Kundenlog lieferte dieselbe Folge 1442 s im iPhone-Stream und 1486 s im Watch-Download. Folge: Ring voll, keine Restzeit, Neustart bei 0:00 — aber `consumed == NO`, die Folge bleibt für immer in „Ungespielt". Beweis in der Zelle: kein Restzeit-Label UND heller Titel/orangener Play-Button (`consumed` färbt beide grau). **Fix (Entscheid 02.09.): `episode.duration` ist die GEMESSENE Mediendauer.** Der Player schreibt sie bei `AVPlayerItemStatusReadyToPlay` neben `lastPlayed` (diff-gated, `[self duration]` als Quelle), und der Feed-Merge in `SubscriptionManager` darf `itunes:duration` nur noch bei `localEpisode.lastPlayed == nil` setzen — sonst überschreibt der nächste Refresh die Messung wieder. `duration` ist NICHT Teil des iCloud-Episode-Payloads, von dort kommt also nichts zurück. Bewusste Folge: bei einer Folge, die schon einmal geöffnet wurde, wird eine spätere Feed-Korrektur der Laufzeit ignoriert. Festgepinnt: `Tools/playback_measured_duration_regression_test.py`.

- **BGContinuedProcessingTask: Wildcard-Registrierung wird abgelehnt (Crash, bewiesen 21.07.):** `registerForTaskWithIdentifier:@"…continued.*"` liefert auf iOS 26.5.2 in JEDER Session `NO`, obwohl der Wildcard-Eintrag im gebauten `Info.plist` steht. Der Wildcard-Eintrag bleibt in der Plist, der Launch-Handler wird aber direkt für den davon abgedeckten konkreten Identifier `…continued.session` registriert; die bekannte Wildcard-Ablehnung darf beim Start nicht mehr absichtlich ausgelöst werden. Das Registrierungsergebnis MUSS gespeichert und geprüft werden (`InstacastAppDelegate.transcriptionContinuedTasksAvailable` / `newTranscriptionContinuedTaskIdentifier`), sonst Fallback auf `BGProcessingTask`. Festgepinnt: `Tools/transcription_background_regression_test.py`, `Tools/debug_launch_warnings_regression_test.py`.
- **Transkriptions-Queue ist ZWEIGETEILT:** `TranscriptionQueue.items` (lokal) + `ServerTranscriptionManager.items` (Server), zusammengeführt nur in `displayItems`. Jeder abgeleitete Zustand (`hasVisibleItems` → Sidebar-Eintrag, `activeItemCount` → Badge, Toolbar-Sichtbarkeit) MUSS `displayItems` lesen. Vorher war der Sidebar-Eintrag bei reinen Server-Aufträgen unsichtbar → Queue und ihre Fehler unerreichbar. Ebenso: ein `completed`/`failed`-Eintrag ist KEIN Besitz der Episode — `enqueueEpisode` darf nur bei laufendem Auftrag ablehnen, sonst ist die Folge dauerhaft nicht mehr einreichbar. Abgelehnte Anfragen brauchen UI-Feedback mit Weg in die Liste.
- **Server-SRT wird strikt und alles-oder-nichts geprüft** (`TranscriptionEngine.parsePersistedSRTDetailed`): LF-only (CRLF = komplette Ablehnung), genau ein `-->` pro Zeitzeile, `HH:MM:SS,mmm` mit Pflicht-Stunden, `end > start`, keine Überlappung (`start >= previousEnd - 0.001`), kein leerer Cue-Text. Der Parser wird NICHT aufgeweicht — er benennt die Verletzung (Zeile, Regel, Inhalt) im `transcript-parse`-Log, damit der Server gefixt werden kann.
- **Swipe-Gate in Listen (Ruckler-Ursache, 21.07.):** Während eine Swipe-Aktion offen ist, gehört das Zell-Layout UIKit. JEDES `reloadData` und jeder Durchlauf über `visibleCells` (Download-Fortschritt, Playback-Wechsel, Watch-Live-Status, Transkriptions-Queue, Appearance) reißt die Geste mitten im Ziehen ab. Alle Episodenlisten setzen deshalb in `willBeginEditingRowAtIndexPath:` ein Gate, sammeln die stärkste Aktualisierung und spielen sie in `didEndEditingRowAtIndexPath:` nach; die Swipe-Action-Handler geben das Gate zusätzlich explizit frei (UIKit liefert `didEndEditing` nicht zuverlässig vorher). Umgesetzt in `EpisodesTableViewController` (Basis für Feed- und Smart-Listen), `UpNextTableViewController`, `AppleWatchEpisodesViewController`, `TranscriptionQueueViewController`. Festgepinnt: `Tools/list_swipe_update_gate_regression_test.py`.
- **Appearance-Farben: kein Write im Lesepfad.** `ic_colorFromDefaults:` wurde aus `ICTintColor` heraus (also aus `layoutSubviews`) aufgerufen und schrieb dabei in NSUserDefaults (`removeObjectForKey:` immer, `setObject:` bei nicht-kanonischem Hex): gemessen 123 µs/Aufruf statt 0,2 µs. Der Lesepfad ist jetzt rein, die Kanonisierung läuft einmalig beim Start (`ic_normalizeStoredColorInDefaults:`), und `ICTintColor` liefert eine gecachte Farbe (`ICResolvedThemeTintColor`, invalidiert in `updateAppearance`/`updateThemeTintColor`).
- **`ICRefreshControl` clippt.** UIKit skaliert das Refresh-Control auf die aktuelle Zugdistanz; der fixe 37-pt-Block ragte darunter heraus und malte über die ersten Episodenzeilen. `clipsToBounds = YES` + Block am unteren Rand verankert, solange die Höhe nicht reicht.
- **Kapitel-Quellen im Playback (gefixt 07.07.):** `PlaybackManager.chapters` lädt generierte Kapitel > eingebettete Medien-Kapitel > Feed-Kapitel (`CDChapter`/Podlove) als Fallback. Vorher fehlte der Fallback: Bei Podcasts, deren Kapitel nur aus dem Feed kommen, zeigte der Player Kapitel (Player-UI liest `episode.sortedChapters`), aber Kapitelende-Skip/Auto-Skip/Kapiteltitel im Control liefen ins Leere (`chapters.count < 2`). CDChapter-Snapshot MUSS vor dem async Parser-Callback gebaut werden (Core-Data-Threading). Forward-Button zeigt via `forwardSkipJumpsToNextChapter` + `ICSkipToNextChapterImage` (SF `forward.end`) an, wenn der nächste Tap ans Kapitelende springt. Festgepinnt: `Tools/playback_feed_chapter_fallback_regression_test.py`.
- **NSManagedObject-Subklassen: KEINE Auto-Synthesis** (`NS_REQUIRES_PROPERTY_DEFINITIONS`): Non-modelled Properties brauchen explizites `@synthesize prop = _prop;`, sonst fehlen die Accessoren zur Laufzeit → „unrecognized selector" (Compiler WARNT nur, Build bleibt grün!). Gefixt: `CDEpisodeList.pendingCountCompletions`. Nach Edits an CD-Klassen Build-Warnungen der Datei prüfen.
- **NSTimer Retain Cycle:** `strong` Timer + `target:self` + `repeats:YES` → `[timer invalidate]` in `dealloc`. Gefixt: `CircleProgressView`, `EpisodePlayComboButton`, `ICBackupImportProgressView`, `PlayerController`
- **Observer ohne dealloc:** Gefixt: `PlaybackControlsViewController`, `DirectorySearchViewController`
- **Block-Observer Token verworfen:** `addObserverForName:usingBlock:` nicht gespeichert. Gefixt: `AudioSession._observeEpisodeCacheBeingDeleted`
- **Core Data Threading:** `DMANAGER.objectContext` = `NSMainQueueConcurrencyType`, NUR Main Thread. Parser-Callbacks auf `parserQueue` → `dispatch_async(main)`. Gefixt: `SubscriptionManager._importURLs:completion:`
- **`WEAK_SELF` Scope:** Prüfen ob schon deklariert → Redefinition-Error

### False Positives (NICHT fixen)

Singleton Observer-Leaks (leben ewig). `_savingInterruption` unsync read (Main Thread only). `refreshingFeedURLs` (Main Thread only). `performBlockAndWait` in `mergeQueue` (Background-Queue). `reloadData` in `viewDidAppear` (`tableView.window` gesetzt; `window && !transitionCoordinator` nur für `updateAppearance`). `dispatch_after` Import-Completion (bewusstes UX).

## Lokalisierung DE/EN (vier getrennte Mechanismen, 03.09.)

Auslöser: App Store Connect meldete zu Build 4.0 (37) `ITMS-90626 — Localized title for custom intent: 'PlayMedia' not found for locale: de`. Der Audit danach fand drei weitere Lücken. Alle vier Mechanismen sind in `Tools/localization_coverage_regression_test.py` + `Tools/ios_integration_metadata_regression_test.py` festgepinnt.

- **`.ls` STRIPPT ein abschliessendes „…" oder „:" vor dem Lookup** (`NSBundle preflightTokenOfLocalizationKey:` in `VemedioKit/Foundation+Localization.m`) und hängt es danach wieder an. Ein Eintrag, dessen KEY auf „…"/„:" endet, wird deshalb NIE gefunden — `localizedStringForKey:value:` liefert dann das Quell-Literal zurück und der englische bzw. deutsche Originaltext leckt ins UI. 13 Einträge waren so tot (u.a. „Watch lädt Podcasts…" auf Englisch, „Waiting for WiFi…" auf Deutsch). Regel: Key ohne Token speichern, Wert darf den Token behalten. Achtung: `NSLocalizedString(...)` (ObjC UND Swift) macht das NICHT — dort ist der Key exakt, inklusive „…". Beide Formen können also nebeneinander nötig sein.
- **Siri-Sätze der App Shortcuts liegen in `AppShortcuts.strings`, nicht in `Localizable.strings`.** Der Key ist die Phrase mit `${applicationName}` / `${podcast}` / `${episode}` — NICHT mit der Swift-Interpolation `\(.applicationName)`. Solche Keys in `Localizable.strings` sind wirkungslos (waren es 19 Stück). Beweis-Werkzeug: `<App>.app/Metadata.appintents/root.ssu.yaml` listet pro `locale:` die trainierten Utterances; vor dem Fix standen unter `locale: de` die englischen Sätze. Fehlt die Datei ganz, ruft Xcode `appintentsmetadataprocessor` mit `--no-app-shortcuts-localization` auf (im Buildlog prüfbar).
- **`.intentdefinition` muss lokalisiert sein**, sonst ITMS-90626. Layout: `Resources-iPhone/Base.lproj/MediaSuggestions.intentdefinition` + `Resources-iPhone/{en,de}.lproj/MediaSuggestions.strings`, als `PBXVariantGroup` im Projekt. Die Strings-Keys sind die `*ID`-Werte aus der Definition (`INIntentTitleID` = `G3J6fP` usw.), ALLE 22 müssen in jeder Sprache stehen. `intentbuilderc` kennt keine Lokalisierungsoption — das läuft rein über die Variant Group. Kontrolle am gebauten Bundle: `Base.lproj/MediaSuggestions.intentdefinition` + `de.lproj/MediaSuggestions.strings`.
- **Info.plist-Berechtigungstexte brauchen `InfoPlist.strings` je Sprache.** `NSSpeechRecognitionUsageDescription` stand nur auf Deutsch in `Resources-iPhone/Instacast-Info.plist` — englische Nutzer bekamen den deutschen Systemdialog. Basiswert in der Plist = Englisch, Übersetzungen in `Resources/{en,de}.lproj/InfoPlist.strings`.
- **Doppelte Keys in einer `.strings`-Datei: der LETZTE gewinnt** (gegen Foundation verifiziert, nicht nur `plutil`). Frühere Zeilen sind wirkungslos und haben abweichende Übersetzungen versteckt — deutsch stand `"Off"` zweimal drin (`Deaktivieren` / `Aus`), `"Up Next"` als `Nächste Folgen` / `Als Nächstes`, `"1 Episode"` als `1 Folge` / `1 Episode`. 46 (EN) bzw. 49 (DE) solcher Zeilen wurden entfernt; der Test lehnt neue Doppel-Keys ab.
- **Jedes Target hat seine EIGENE Tabelle.** Ein Key, den die Widget-Extension nachschlägt, muss in `InstacastWidgets/Resources/*.lproj/Localizable.strings` stehen (der App-Eintrag hilft nicht). Gleiches für `InstacastWatch/` und `InstacastWatchWidgets/`. AppIntents-Metadaten (`LocalizedStringResource`, `IntentDescription`, `@Parameter/@Property(title:)`, `DisplayRepresentation(title:)`) laufen über die Localizable-Tabelle des jeweiligen Bundles.

## Icon-Referenz (KONSISTENT halten!)

Alle Stellen (Swipe-Aktionen, Context-Menüs, Popup-Menüs, Toolbars) MÜSSEN identische Icons verwenden.

| Aktion | SF Symbol | Asset-Alternative | Farbe |
|---|---|---|---|
| Download | `square.and.arrow.down` | `Toolbar Download` / `Multitoolbar Download` | Akzentfarbe (`ICTintColor`) |
| Download löschen / abbrechen | `trash` | — | Rot (`systemRedColor`) |
| Episode löschen (aus Liste) | `trash` | — | Rot (`systemRedColor`) |
| Favorit markieren | `star` | — | Akzentfarbe |
| Favorit entfernen | `star.slash` | — | Grau |
| Als gehört markieren | `circle` | — | Grau |
| Als ungehört markieren | `circle.fill` | — | Akzentfarbe |
| Zur Abspielliste hinzufügen | `list.bullet.indent` | — | Akzentfarbe |
| Aus Abspielliste entfernen | `list.bullet.indent` | — | Grau |
| Episoden Info | `info.circle` | — | Akzentfarbe |
| Play Next (Seitenmenü/Tab) | `list.bullet.indent` | — | — |
| Abspielen | `play.fill` | — | — |

Stellen die IDENTISCH sein müssen:
- `_imageForSwipeAction:episode:` + `_tintColorForSwipeAction:episode:` (EpisodesTableViewController — Swipe-Aktionen)
- `_contextMenuForIndexPath:` (EpisodesTableViewController — Long-Press Menü)
- Popup-Menü (EpisodeViewController — More-Button)
- Toolbar/Glass Buttons (EpisodesTableViewController)
- CarPlay (InstacastSceneDelegate)
- Seitenmenü-Tab-Icons (MainViewController_4)

Farben: Immer `ICTintColor` für Akzentfarbe (passt sich an Appearance an), `[UIColor systemRedColor]` für destruktive Aktionen, `[UIColor colorWithWhite:0.5f alpha:1.0f]` für Grau. NIEMALS hardcodierte RGB-Werte für Rot.

VoiceOver: Jeder Icon-only-Button (Glass Buttons, Toolbar-Items, Player-Controls) braucht ein `accessibilityLabel` mit Localizable-Key (`.ls`), gleiche Wortwahl wie das Context-Menü. Swipe-Aktionen (`UIContextualAction`, title:nil) haben kein Label-API — stattdessen `image.accessibilityLabel` setzen (siehe `_accessibilityLabelForSwipeAction:episode:`). Dekorative Icons (Volume-Min/Max): `isAccessibilityElement = NO`.

Haptik: IMMER `PlayHapticFeedback(ICHapticFeedbackLight/Medium)` (Sound.h, respektiert `UIHapticsEnabled`-Setting, Default an, Schalter unter Darstellung neben „Interfacetöne"), NIE `AudioServicesPlaySystemSound(1519)` direkt. Light = Toggles/Skip, Medium = Play/Pause. Die Funktion nutzt statische, per `prepare()` warmgehaltene Generatoren — NIE pro Event einen `UIImpactFeedbackGenerator` allozieren (kalte Taptic-Engine = Main-Thread-Latenz mitten im Gesten-Commit; verursachte extremes Swipe-Ruckeln, 07/2026). **Swipe-Aktionen bekommen KEINE App-Haptik**: UIKit spielt bei Full-Swipe/destruktiven Actions und beim Öffnen von Context-Menüs eine per API nicht abschaltbare System-Haptik — App-Haptik dort wäre ein Doppel-Tap. App-Haptik nur an Stellen ohne System-Pendant (Context-Menü-ITEM-Handler, Player-Buttons); nicht zusätzlich in gemeinsam genutzten Helpern wie `_togglePlayNextForEpisode` (würde doppelt feuern).

## Auto-Refresh

`_autoRefreshFeedsIfNeeded` in SceneDelegate: Beim App-Start und Foreground-Wechsel werden alle Feeds refreshed, wenn der letzte Refresh > 30 Minuten her ist. Non-blocking, kein UI-Feedback. Statische `_lastAutoRefreshDate` als Cooldown. ACHTUNG: Auf iOS ignoriert `refreshAllFeedsForce:` das force-Flag — alle nicht-geparkten Feeds werden immer refreshed; die per-Feed-AutoRefresh-Intervalle existieren nur im alten Nicht-iOS-Pfad und haben kein iOS-UI.

Refresh-Merge: Feed-Setter (etag/title/linkURL/paymentURL/imageURL/contentHash) NUR via `ICFeedValueDiffers`-Diff-Check schreiben — Core Data markiert Objekte auch bei identischem Wert als updated. Unveränderte Feeds dürfen nur durch `lastUpdate` dirty werden, sonst feuern FRC-Reload-Kaskade + iCloud-Sync-Observer pro Feed. Reload-Coalescing in `SubscriptionsTableViewController` während `refreshing`: 1s statt 0.2s.

## iCloud Sync (`ICiCloudSyncManager`, iOS 17+)

Aufgeteilt (06.07., reine Code-Verschiebung): `ICiCloudSyncManager.swift` (Kern: Properties, Start/Enable, Backfill-Maschinerie), `ICiCloudSyncTypes.swift` (DeviceInfo/Counts/Inventory-Typen), `+EngineRecords.swift` (Delegate-Callbacks + Record-Builder), `+RemoteApply.swift` (Fetched-Events + applyRemote*), `+LocalChanges.swift` (Defaults-/Core-Data-Observer + Stub-Hydration), `+Metadata.swift` (Metadata-Storage, Status, Diagnose). Member sind `internal` statt `private` (Swift-private ist file-scoped; Extensions in anderen Dateien brauchen Zugriff) — die Test-Helper in `Tools/` extrahieren Methoden-Bodies deshalb per Brace-Matching, NIE über „nächstes `private`"-Marker. Neue Dateien müssen in allen 13 iCloud-Tests in der Dateiliste stehen (Konkatenations-Read).

**Schema-Deployment ist Pflicht vor jedem TestFlight-Build:** Debug-Builds laufen gegen die CloudKit-**Development**-Umgebung und legen neue Record-Typen automatisch an — TestFlight/App Store laufen gegen **Production**. Ein dort fehlender Typ killt den kompletten Sync (`CKError 12`, „Cannot create new type <X> in production schema"), nicht nur den einen Record: im Kundenlog vom 02.09. schlugen ALLE 435 Send-Batches fehl, `"iCloud Sync abgeschlossen"` kam 0×, die betroffenen Records hingen dauerhaft in `pendingRecordZoneChanges` und die App versuchte es alle 30 s neu. Betroffen war `ICSubscriptionTombstone`. Nach jedem neuen Record-Typ/Feld: CloudKit Console → *Deploy Schema Changes to Production*, und im eigenen Debug-Log ist der Fehler NIE sichtbar. `xcrun cktool` kann das NICHT: `export-schema --environment production` geht, aber `import-schema`/`validate-schema` antworten dort mit „endpoint not applicable in the environment 'production'" — Deployment nur über die Web-Console. Schema-Diff prüfen: `xcrun cktool export-schema --team-id L95F4M2LHG --container-id iCloud.com.iteconomy.instacastplus --environment production|development` und diffen. App-seitig abgesichert: `.invalidArguments` (CKError 12) gilt in `handleFailedRecordSave` als dauerhaft und wird verworfen statt neu eingereiht (`dropPermanentlyRejectedRecordSave`), sonst blockiert ein einziger nicht speicherbarer Record dauerhaft ALLE anderen Record-Typen. Festgepinnt: `Tools/icloud_sync_save_failure_regression_test.py`.

CKSyncEngine mit `automaticallySync=false` → synct NIE von selbst. Fetch/Send: Push, lokale Änderung, manuell, `performForegroundSyncIfNeeded` (SceneDelegate bei Launch+Foreground, 15-min-Throttle).

Regeln (alle waren mal Bugs):
- **Engine-Callbacks:** Episoden UND Abos batch-weise materialisieren — EIN Fetch pro Send-Batch (`objectHash IN`/`sourceURL_ IN`, properties-Prefetch). NIEMALS Context+Fetch pro Record (SQLite-Lock-Contention → UI-Freeze beim Toggle).
- **Echo-Prävention:** Remote-Applies tracken tatsächlich mutierte ObjectIDs (`remoteAppliedObjectIDs`), Observer konsumiert sie. Zeitfenster-Flags reichen NICHT — ObjectsDidChange wird gebatcht zugestellt, oft nach Flag-Reset. Direkt nach einem Send zurückgelieferte eigene Records werden nur für die großen Episode-/Abo-Typen übersprungen und nur, wenn recordName + exakter CloudKit-`recordChangeTag` dieses Prozesses UND das top-level `deviceID` übereinstimmen. `deviceID` kann per Backup auf zwei Geräten gleich sein; Name+Device allein darf deshalb NIE einen Fetch verwerfen. Settings laufen immer durch Apply, damit Re-enable die Cloud/Local-Wahl nicht umgeht. Der ACK-Versionscache bleibt absichtlich nur im Speicher.
- **Observer-Filter:** `coreDataDidChange` filtert synchron zur Notification per `changedValuesForCurrentEvent` (Episoden: consumed/starred/position; Feeds: sync-relevante Keys; FeedProperty: nicht-internal; Rest: drop). Später ist das Change-Dictionary leer.
- **Apply:** Immer Gleichheits-Checks (nur echte Diffs schreiben) + Fingerprint nachführen: Abo-Payload-Hash nach Apply UND beim Backfill-Queueing; Settings-Hash-Baseline persistent (`ICiCloudSyncSettingsSyncedHash`) — In-Memory-Baseline → Re-Upload bei jedem Start mit frischem updatedAt → bricht Last-Writer-Wins.
- **FeedProperty-Apply:** Alle 4 Wertfelder direkt schreiben (`propertyForKey:insertOnDemand:`), NIE Typ raten — uid-präfixte Keys haben keine UserDefaults-Defaults, die Typ-Heuristik lieferte "bool" für Doubles.
- **Podcast-spezifische Settings sind dauerhafte `CDFeedProperty`:** Neue FeedSettings-Keys dürfen nicht verloren gehen. Sie müssen über Backup-Export/Import (`podcast/settings`) und iCloud-Subscription-Sync (`subscriptionPayload`/`applyFeedPropertyPayload`) mitlaufen und dürfen nicht in `internalFeedPropertyKeys`. Aktuell festgenagelt: `PlayerNearChapterEndForwardSkipMode` und `PlayerNearChapterEndForwardSkipWindow` in `Tools/podcast_near_chapter_end_forward_skip_regression_test.py`.
- **Toggle-OFF / Participation:** Device-Record final senden (`sendFinalDeviceRecordUpdate`) — `scheduleLowPrioritySync` läuft mit allem-aus nicht mehr an. Kategorie aus = EINGEFROREN: nichts wird mehr angewendet (applyRemote* UND applyPending* enabled-gated); Pendings bleiben liegen (Engine liefert gefetchte Records nie erneut — NIE löschen). `*HasParticipated` ist NUR das OFF-/Offline-Outbox-Capture-Gate und kein Completion-Beweis (historisch wurde es schon beim Enable gesetzt). Backfill-Start und -Completion sind separat an die verifizierte CloudKit-Account-ID gebunden; Completion wird ausschließlich beim final bestätigten Cursor gesetzt und bei Account-/Zonenreset invalidiert. Same-account OFF→ON resumed einen vorhandenen Cursor bzw. leert nur die Outbox; anderer Account, gelöschte Zone oder historisch `participated=true` + Cursor=nil ohne Completion-Marker startet sicher bei 0. Jede Optionänderung queued außerdem den kleinen aktuellen Device-Record, auch wenn kein Backfill nötig ist.
- **Abo-Löschungen nur live:** Einschalten des Abo-Syncs darf NIE Abos löschen — `suppressSubscriptionDeletionsKey` wird beim Enable gesetzt und erst nach dem ersten vollständigen Fetch (`didFetchChanges`, nicht markSyncCompleted — Backfill-Läufe sind send-only!) gelöscht. Nachhol-Deletions aus der Aus-Phase werden verworfen; die lokale Kopie gewinnt (Vereinigungs-Semantik), Backfill lädt sie wieder hoch.
- **Status:** Während Backfill durchgängig „Lädt hoch… X / Y", kein „vollständig"-Flipping pro Page. X kommt aus dauerhaft bestätigten Seiten plus den ACKs der gerade laufenden Seite und steigt monoton; die Größe eines einzelnen Fetch-Callbacks ist NIE ein globaler Nenner (sonst entstehen Angaben wie 3506/198).
- **Stub-Hydration NIE über `refreshFeed:`:** `_mergeLocalFeed` kennt kein Limit → legt bei leerem Feed ALLE Episoden in einem Main-Context-Push an (iPad unbenutzbar). Stattdessen `hydrateStubFeed:` (SubscriptionManager): Initial-50 + Rest via `EpisodeLoadingManager`. Sync-Hydration wartet pro Feed auf `EpisodeLoadingManagerDidFinishLoading` (+120s-Failsafe) — mehrere Feeds gleichzeitig im Loader = quadratische Plist-Writes bei jedem Feed-Finish. `refreshFeed:` skipt Stubs (`lastUpdate==nil && episodes.count==0`) und Loader-aktive Feeds, sonst Voll-Merge durch Auto-Refresh. Hydration ist NICHT subscriptionsSyncEnabled-gated (Stubs füllen = lokales Aufräumen).
- **Auto-Retry:** CKSyncEngine (`automaticallySync=false`) wiederholt NICHTS von selbst — jeder Fehlerpfad (lowPrioritySync-catch, failedZoneSaves, failedRecordSaves/Deletes inkl. re-queued Konflikt-Repairs, Fetch-Zone-Error) muss `scheduleSyncRetryAfterFailure` aufrufen (Backoff 15s→300s bzw. Server-retryAfter, Reset in markSyncCompleted; nicht-transiente Codes wie notAuthenticated/quotaExceeded: kein Retry). Ohne das blieb „konnte nicht abgeschlossen werden" nach dem Einschalten bis zum manuellen Sync stehen.
- **Settings-Enable ist fetch-gated + User-Wahl (Entscheid 12.06.):** Einschalten published NIE sofort. Flow: Marker `initialSettingsBackfillPendingKey` → erster Fetch. Kommen Cloud-Settings: Payload wird GEPARKT (`pendingInitialSettingsPayloadKey`, persistent) + Notification `initialSettingsChoiceNeededNotification` → Settings-VC fragt „Einstellungen aus iCloud übernehmen / Meine für alle verwenden / Später" (`resolveInitialSettingsAdoptingCloud` / `resolveInitialSettingsPublishingLocal`; „Später" = Dialog kommt beim nächsten Öffnen wieder, nichts wird angewendet/published — der didFetchChanges-Publish wartet auf `!hasPendingInitialSettingsChoice`). Kommt NICHTS: didFetchChanges published die lokalen und der laufende Low-Priority-Cycle sendet dieses Record sofort, ohne dafür einen zweiten Send+Fetch-Cycle zu starten. Apply-Kern ist `adoptSettingsPayload` (von Apply + Adopt-Wahl geteilt). Settings zählen nicht zu hasInitialUploadBackfillWork.
- **Folgen-Erstabgleich = inhaltliches Merging (Entscheid 12.06.):** Eine Folge OHNE episodeLocalModifiedDate war nie Teil des Syncs → beim ersten Apply wird inhaltlich gemerged statt Zeitstempel: gehört>ungehört, größere position gewinnt, Favorit>nicht-Favorit. Gewinnt lokal etwas, wird das Merge-Ergebnis mit frischem Datum zurückgepusht (Gegenseite übernimmt per Recency). Sobald ein Sync-Datum existiert: reines LWW (bewusste Edits wie „als ungehört markieren" müssen propagieren).
- **Cloud-Inventar:** Change-Stream-Fetch (nil-Token) kann Records DOPPELT liefern und streamt Deletions → IMMER per recordName-Set deduplizieren (`ICCloudInventoryCountsBox`), nie zählen (Phantom „ICDevice=3"). Kategorien zählen NUR Nutzer-Objekte: Abos=ICSubscription, Folgen=ICEpisodeState, Einstellungen=ICAppSettings — Hilfsrecords (ScrollPositions, SubscriptionListSettings, Devices) nie einrechnen. Nach „iCloud-Daten löschen" sofort `storeCloudInventory([:])`. Die ICDevice-Records werden nach dem Inventar-Lauf per CKFetchRecordsOperation mit Payload geladen → Geräteliste stimmt schon VOR dem Einschalten.
- **Stub-Hydration Failed-Set:** `hydrationFailedFeedIDs` überlebt den Lauf (Reset nur bei Foreground/App-Start) und failed Stubs zählen nicht in die Status-Summe — sonst loopt jeder Fetch-Trigger tote Feeds im 10s-Takt („Lade Podcast-Folgen… 0/3" endlos). `applyPendingEpisodeStates` am Hydration-Ende nur bei completed>0. Stub-Predicate enthält `parked == NO` — der per-Feed-Stopp-Schalter (`feed.parked`, synct im Abo-Payload) wird wie beim normalen Refresh gewürdigt (tote Feeds parkt der User an der Quelle).
- **KEINE fixen Pacing-Delays** (User-Vorgabe): `EpisodeLoadingManager` skaliert die Batch-Größe adaptiv an der GEMESSENEN Main-Thread-Dauer (Ziel 0.1s/Batch, min 10/max 200, geglättet) — schnelle Geräte laufen volle Geschwindigkeit, langsame schützt die Batch-Größe statt eines Sleeps. Zwischen Batches nur Queue-Hops (Background-Prep → Main), kein dispatch_after. Hydration-Feeds folgen ohne Delay aufeinander (Netz-Parse ist die natürliche Pause).
- **Settings-Seite Refresh-Trigger:** Cloud-Inventar + Geräte aktualisieren bei: Seite öffnen (viewWillAppear), JEDEM Schalter-Umlegen, manuellem Sync (Completion) und alle 30s (Timer).
- **Status:** Aktivität ohne bewegte Records zeigt NICHTS (leerer Fetch-Pass blitzte „lädt herunter…" obwohl iCloud leer); während hasInitialUploadBackfillWork gewinnt der stabile „Lädt hoch… X/Y"-Text über den per-Batch-Zähler.
- **`setConsumed:` ruft Transcript-Cache-Cleanup pro Episode** — Log-Event nur bei tatsächlich entfernten Dateien (States-Apply markiert tausende in einem Pass; je ein Log mit Disk/Memory-Snapshot flutete Log+Main-Thread).
- **Abspielposition synct LIVE (User-Entscheid 12.06.), NIE wieder drosseln:** Der Player schreibt position alle ~30s, jeder Tick lädt sofort EINEN kleinen Record hoch. Die frühere Defer-Drosselung (`deferredPlayingPositionHashes`, 5-min-Flush) war eine Fehlattribution und wurde entfernt: Die nächtlichen cpu_resource-Kills kamen aus `WidgetDataExporter→CDEpisodeList numberOfEpisodes` (Voll-Fetch pro Save, gefixt via SQL-Count + 60s-Exportdrossel), NICHT vom Upload. Tick-Kosten heute: Observer-Filter (µs) + 1 existingObject + gecachtes Dates-Dict (Write 0.8s-debounced) + 1 Record send/fetch async; Watchdog loggt Observer-Pässe ≥100ms. Wird der Tick-Pfad je wieder teuer: Ursache fixen, nicht die Sync-Frequenz.
- **CDEpisode.`downloaded` ist TRANSIENT** (keine Store-Spalte!): SQL-Prädikate darauf matchen NIE (leere „Heruntergeladen"-Liste seit dem Listen-Umbau 02.06.). Listen-Filter läuft über `objectHash IN cachedEpisodes-Hashes` (wie der Count-Pfad); der CacheManager-Startup restauriert die Flags für Zellen-UI. setDownloaded: willCHANGEValueForKey (war willAccess — unbalanciertes KVO).
- **CDEpisodeList-Counts auf Background-Contexts = SQL-Count** (`_countEpisodesViaStore`, teilt `_episodesMainPredicate` mit dem Fetch): Der frühere Fallback `[[self sortedEpisodes] count]` lief im WidgetDataExporter pro Liste bei jedem Save — zwei Voll-Fetches über die ganze Episode-Tabelle, Dauer-CPU >80% im Hintergrund-Playback → `cpu_resource_fatal`-Kills im Minutentakt (12.06., symbolisiert via InstacastPlus.debug.dylib!). Zusätzlich: `_debouncedListsReload` (Core-Data-Kanal des Widget-Exports) max. 1×/min — der Positions-Save retriggert ihn sonst alle 30s endlos.
- **Widget-Exporte NIE im Hintergrund-Playback (Regression 26.06., Fix 27.06.):** Der 12.06-Fix deckte nur den Count + EINEN Trigger (`_debouncedListsReload`). Aber `exportListsSnapshot` selbst ist teuer (pro Liste 1 SQL-Count + 1 sortierter Fetch über den ganzen Store + Bildkopien) und wurde weiter ungedrosselt aus `sceneDidEnterBackground→exportAllSnapshots`, `_feedsDidRefresh`/`_episodesAdded` (mehrfach gepostet → serieller Queue-Stau) aufgerufen. Bei aktiver Wiedergabe bleibt die App im Background am Leben → ein Lauf (oder der Stau) brennt 48s CPU/49s → erneuter `cpu_resource_fatal` (Build 3.5(20), iPhone16Pro, iOS 26.5.1; bewiesen via Microstackshot `.ips` + DerivedData-dSYM, UUID-Match statt Archiv). **Gate:** `exportListsSnapshot` und der wiederkehrende `_refreshStatsDuringPlaybackIfNeeded`-Stats-Scan prüfen `applicationState != Active && playingEpisode && !isPaused` → aufschieben (`pendingListsExport`/`pendingStatsRefresh`), Flush bei `WillEnterForeground`/`DidBecomeActive`. Now-Playing/Position bleiben live (Lock-Screen, MQTT, iCloud). **Inkrementeller Listen-Export (User-Vorgabe 08.07., minimaler Widget-Overhead):** Eine geänderte Episode re-exportiert NUR die betroffenen Listen (`_exportListsAffectedByEpisodeHashes`: pro Liste 1 SQL-Count + 1 limit-14-Fetch; betroffen = Episode im aktuellen Snapshot-File ODER matcht jetzt den Listen-Filter via `CDEpisodeList evaluatesEpisodeNow:` — in-memory-Prädikat, kein Store-Scan). Nutzer: Playback-Transitionen (`_episodeDidFinish`/`_playbackDidChangeEpisode`, bewusst UNGEGATED im Background — die Ungespielt-/Zuletzt-gespielt-Widgets müssen die beendete Folge sofort zeigen) und kleine consumed/starred-Toggles aus dem Core-Data-Kanal (≤8 Episoden, sonst Voll-Reload). Smart-Playlist-NEUzugänge kommen erst mit der Bereinigung (by design). Der VOLL-Export (`exportListsSnapshot`) ist nur noch periodische Bereinigung (Startup, Backgrounding, Feed-Refresh, Foreground-Flush) und bleibt im Background-Playback gated. `_buildSnapshotForList:` MUSS mit der Voll-Pass-Schleife synchron bleiben (Test pinnt beides). Watchdog beißt nur im Background → im Foreground läuft der Export unverändert. Verifikation: `widget-export`-Events im Diagnostics.jsonl (`aufgeschoben` / `fertig` mit `seconds`+`lists`). Gefixt 07.07.: `_coreDataDidChange:` filtert jetzt via `_coreDataChangeAffectsLists:` synchron nach geänderten Keys (Episoden: nur consumed/starred/archived/feed/episodeLists; Inserts/Deletes von Episode/Feed/List; NICHT `position`) — der Positions-Tick triggert keinen Listen-Export mehr. `changedValuesForCurrentEvent` MUSS synchron zur Notification gelesen werden (im async-Block schon leer, wie beim iCloud-Manager).
- **Widget-Export darf das UI NIE blockieren — Komplett-Redesign (Fix 08.07.):** Belegt via Diagnostics.jsonl auf großer Bibliothek: `exportListsSnapshot` brauchte `total_s ~12.8` (`count_s 7.6` = 157× `numberOfEpisodes`-SQL-Count, `fetch_s 4.2`), „inkrementeller" Export bei 1 Episode `9.3s`/129 Listen. Lief auf `listsExportQueue`, aber `newBackgroundContext` teilte den **Main-Coordinator** → lange Read-Query hielt den Store-Lock → Main-Thread-Core-Data (Liste laden, Zell-Faults) blockierte → UI-Freeze, verworfene Touches („System gesture gate timed out"), erst nach ~1min flüssig. Vier Ebenen:
  1. **Eigener Store-Coordinator** `DMANAGER.newExportBackgroundContext` (zweiter `NSPersistentStoreCoordinator` auf dieselbe SQLite/WAL-Datei — App+Extension-Pattern, gleichzeitige Leser, NIE Main-Lock-Contention). ALLE Export-Background-Blöcke nutzen ihn read-only (nie `save`). Das ist die Garantie „Background blockiert UI nie", unabhängig von Laufzeit.
  2. **Gate pro Widget-Art:** `WidgetKitHelper.isNowPlayingWidgetInstalled`/`isSmartListWidgetInstalled`/`isStatsWidgetInstalled` (gecachte `getCurrentConfigurations`-Kinds, persistent `ICWidgetInstalledKindsCache`, refresh Init+Foreground; unbekannt→true, damit Erstlauf exportiert). Jede Export-Methode exportiert NUR was ein installiertes Widget liest. Nur Last-Played-Widget → Listen-/Stats-Export laufen NIE.
  3. **Dedupe nach uid:** Der Store enthält viele Duplikat-/Waisen-`List`-Rows (Migrationen/iCloud über Jahre) — „157 Listen" statt ~6. `exportListsSnapshot` UND `_exportListsAffectedByEpisodeHashes` deduplizieren jetzt nach `uid` (leere/doppelte uid überspringen) = dieselbe Menge wie `DMANAGER.lists`/das „Listen"-Menü. Sonst blähen die Duplikate Arbeit UND den Widget-Picker (`SmartListConfigIntent`) auf.
  4. **Kein Vollcount, nur Änderungen schreiben:** `numberOfEpisodes`-SQL-Count entfernt — `episodeCount` = Anzahl der tatsächlich exportierten (max. `kMaxEpisodesPerList`=14) Episoden. Voll-Pass schreibt pro Liste nur, wenn sich die Episoden-Payload wirklich geändert hat (`_listSnapshotEpisodesUnchanged:file:`, ignoriert den `timestamp`); `changed`-Feld im `widget-export`-Log. `_buildSnapshotForList:` MUSS mit dem Voll-Pass synchron bleiben (beide ohne Count, gekappt — Test pinnt das).
- **Listen-Widget: Podcasts als Optionen (09.07.):** Der SmartList-Widget-Picker listet die dedup. „Listen"-Menü-Listen ZUERST, dann alle abonnierten Podcasts (rank-Reihenfolge, `id="feed:<uid>"`, `type:"podcast"` im `widget_lists.json`). Effizienz-Prinzip (User-Wahl): Episoden werden NUR für die Podcast+Filter-Kombis exportiert, die ein installiertes Widget tatsächlich zeigt — NICHT für alle 45×Filter. Mechanik ohne Cross-Target-Typ-Sharing: der Widget-Provider schreibt seine konfigurierte Kombi (`{uid,filter}`) in App-Group-Defaults (`ICWidgetConstants.requestedPodcastKeysDefaultsKey`); `WidgetDataExporter._exportConfiguredPodcastSnapshots` liest sie und exportiert je 14 Episoden (`widget_list_feed.<uid>.<filter>.json`, Prädikat `_predicateForPodcastFilter:` spiegelt CDEpisodeList-Filter). Filter-Enum `SmartListPodcastFilter` (default `unplayed`) im Config-Intent; Provider-Key via `snapshotKey(entityId:filter:)`. Neu gewählter Podcast ohne Daten → „App öffnen"-Empty-State, App exportiert beim nächsten Lauf.
- **Widget-Init & Empty-State (Fix 09.07.):** WidgetKit weckt die App NICHT für einen Core-Data-Export. Neu hinzugefügte Widget-Art → `WidgetKitHelper.refreshInstalledWidgets` (Init+Foreground) erkennt die neue Kind-Menge und postet `ICWidgetInstalledKindsDidChange`; der Exporter füllt dann sofort. Fehlt die Snapshot-Datei ganz (App seit Widget-Hinzufügen nie gelaufen), zeigt das Widget selbst „App öffnen, um Daten zu laden" (`widget.needsdata`) via `SharedContainerReader.snapshotExists(...)` in den Providern; `.widgetURL(ICWidgetConstants.refreshWidgetsURL())` (Host `refresh-widgets`) öffnet die App, die im SceneDelegate-Handler sofort alle Snapshots exportiert. Duplikat-/Waisen-`List`-Rows werden bei jedem Start via `_migrateRemoveDuplicateLists` (DatabaseManager) entfernt (behält 1 pro `uid`, löscht nil-uid) — selbstheilend, verhindert erneute Ansammlung.
- **Crash-Forensik Debug-Builds:** devicectl-Installs behalten die TestFlight-Receipt → `distributor_id=com.apple.AppStore` ist KEIN Build-Indikator, nur die slice_uuid. Der App-Code steckt in `InstacastPlus.debug.dylib` (eigene UUID!) — Microstackshot-Frames `<UUID> + offset` mit `atos -o InstacastPlus.debug.dylib -l 0 <hex-offset>` symbolisieren. cpu_resource-Kills erzeugen NICHT pro Kill einen .ips (gedrosselt) — „Minutentakt-Abstürze" können 3 Reports/Tag bedeuten.
- **Geräteliste:** Jede (Neu-)Installation registriert eine frische Device-UUID → verwaiste Einträge. `deleteDevice(withID:)` löscht das ICDevice-Record (eigenes Gerät nie); Swipe in der Devices-Sektion des Settings-VC. Remote-Device-Deletions bereinigen den Cache; wird das EIGENE Gerät gelöscht, meldet es sich per `queueDeviceRecord()` selbst neu an.
- Settings-VC cached `devices` (`deviceList`) — der Manager-Getter liest pro Aufruf die Cache-Datei von Disk.

## macOS (Mac Catalyst)

**Korrigiert 03.09.** Der frühere Titel „Designed for iPad" und der Satz „NICHT Mac Catalyst → `#if TARGET_OS_MACCATALYST` = 0" waren FALSCH. Gemessen mit `xcodebuild -showdestinations` und `-showBuildSettings -destination 'platform=macOS,variant=Mac Catalyst'`:

- Der Mac-Build IST Mac Catalyst, also **`TARGET_OS_MACCATALYST` = 1**. Die `#if TARGET_OS_MACCATALYST`-Zweige in `AudioSession.m`, `PlaybackManager.m`, `InstacastSceneDelegate.m`, `AppleWatchSyncManager.m` und `SleepTimerSettingsViewController.m` sind aktiv, nicht tot.
- **`isiOSAppOnMac` ist bei Catalyst immer `false`** (es meldet nur „Designed for iPad"-Apps). Jedes Gate, das nur darauf prüft, greift auf dem Mac NICHT: `requestAuthorizationWithOptions:`(AppDelegate), `WidgetDataExporter.sharedExporter→nil`, `WidgetKitHelper`(reloadTimelines/startListening), Fenstergröße 402×874(SceneDelegate). Für ein echtes Mac-Gate `TARGET_OS_MACCATALYST` bzw. `ProcessInfo.isMacCatalystApp` prüfen. **Ungeklärt: ob das Absicht ist** — vor einer Umstellung mit Chris klären.
- **Die `[sdk=macosx*]`-Einstellungen greifen NICHT**, weil ein Catalyst-Build `SDKROOT = iPhoneOS.sdk` verwendet. Beim Mac-Build wird aufgelöst: `CODE_SIGN_ENTITLEMENTS = Instacast.entitlements` (also MIT App Groups, NICHT `InstacastMac.entitlements`) und `PRODUCT_BUNDLE_IDENTIFIER = com.iteconomy.instacastplus` (nicht `….mac`). `InstacastMac.entitlements` ist damit wirkungslos, wird aber weiter von `Tools/ios_integration_metadata_regression_test.py` gepinnt.
- **Der Catalyst-Build war kaputt und ist am 03.09. repariert** (drei unabhängige Blocker, alle verifiziert durch `xcodebuild -destination 'platform=macOS,variant=Mac Catalyst' build`):
  1. `Frameworks/llama.xcframework` hat nur `ios-arm64` + `ios-arm64_x86_64-simulator`, keine maccatalyst-Slice → beide llama-Build-Files (Link + Embed) tragen jetzt `platformFilters = (ios, )`. `LocalGGUFModelRunner.swift` fällt damit auf seinen `#else`-Stub zurück; **auf dem Mac gibt es also kein lokales GGUF-Kapitelmodell** (Fehlertext „Kapitelmodell ist in dieser App-Version nicht verfügbar."). Dessen `#else`-Enum war veraltet (`chapterStarts` fehlte) und wurde angeglichen — der Stub-Zweig wird sonst nie gebaut und driftet unbemerkt. **Betroffen ist NUR das lokale GGUF-Kapitelmodell** — gemessen für `arm64-apple-ios-macabi`: `canImport(FoundationModels)` = JA, `canImport(Speech)` = JA, WhisperKit wird für maccatalyst gebaut (`WhisperKit.o` in `Build/Products/Debug-maccatalyst`), nur `canImport(llama)` = NEIN. Lokale Transkription, Apple Intelligence und die Server-Modelle laufen auf dem Mac also. Damit die App dort keinen 2,6-GB-Download anbietet, der danach nur den Fehlertext liefert, filtert `TranscriptionEngine` den Katalog: `definedModels` ist die Vollliste, `models` lässt unter `#if !canImport(llama)` alle `.textToChapters`-Einträge mit `chapterProvider == .localGGUF` weg — das greift automatisch in Modellbibliothek, Auswahl-Dialogen und Podcast-Einstellungen. **`defaultChapterModelIdentifier` MUSS mitgezogen werden** (ohne llama `apple-foundation-models` statt `gemma-4-e2b-it-q4-k`): `selectedModel(for:)` endet auf `model(identifier: defaultChapterModelIdentifier)!` und würde sonst auf dem fehlenden Default trappen; ein per iCloud vom iPhone gesyncter Gemma-Eintrag fällt über denselben Pfad sauber zurück. Festgepinnt in `Tools/model_library_settings_regression_test.py`.
  2. `BGContinuedProcessingTask` (iOS 26) ist auf Catalyst nicht verfügbar → 7 Stellen in `InstacastAppDelegate.m` (Registrierung, Task-Typ-Erkennung, Handler-Methode, Replay-Dispatch) und `_submitContinuedBackgroundTask` in `TranscriptionQueueViewController.m` liegen unter `#if !TARGET_OS_MACCATALYST`. Auf dem Mac läuft der schon vorhandene `BGProcessingTask`-Pfad. Der iOS-Pfad ist unverändert.
  3. Das eingebettete `InstacastWatch.app` darf nicht in den Mac-Build → `platformFilter = ios` auf dem „Embed Watch Content"-Build-File, gleiches Muster wie beim `InstacastWidgets.appex`. Kontrolliert: iOS-Build enthält weiterhin `Watch/InstacastWatch.app` (mit `UIBackgroundModes = (audio)`), `PlugIns/InstacastWidgets.appex` und `Frameworks/llama.framework`; im Mac-Bundle ist `Contents/Watch/` leer und llama fehlt.

TCC-Trigger: (1) `requestAuthorizationWithOptions:` → nur per `isiOSAppOnMac` gegated, greift bei Catalyst also nicht. (2) `application-groups`: beim Catalyst-Build ist `Instacast.entitlements` MIT Groups aktiv. KEIN Trigger: AVAudioSession, Reachability, registerForRemoteNotifications.

Weitere `isiOSAppOnMac`-Stellen: `CTTelephonyNetworkInfo/CTServiceRadio.../CMMotionManager`(Application.m).

Nicht gegated (funktioniert): AVAudioSession Volume KVO, Reachability, UNUserNotificationCenter.delegate, registerForRemoteNotifications.

Widget: `InstacastWidgets.appex` → `platformFilter=ios`, nicht in Mac-Builds.

# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
