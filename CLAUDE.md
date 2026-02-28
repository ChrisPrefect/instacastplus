# CLAUDE.md

## Project Overview

Instacast+ — Podcast-App für iOS/macOS in Objective-C. Feed-Parsing, Playback, Chapters, Bookmarks.

**Version:** 2.9 · **Min iOS:** 13.0

## Build Commands

**WICHTIG: Nicht automatisch builden!** Der Entwickler buildet selbst.

```bash
xcodebuild -project Instacast.xcodeproj -scheme Instacast build          # iPhone
xcodebuild -project Instacast.xcodeproj -scheme "Instacast HD" build     # iPad
xcodebuild -project Instacast.xcodeproj -scheme InstacastMac build       # macOS
xcodebuild -project Instacast.xcodeproj -scheme "Instacast Tests" test   # Tests
```

## Architecture

### Data Layer: Core Data + SQLite Hybrid

- **CD*-Prefix** = Core Data Entities: `CDFeed`, `CDEpisode`, `CDMedia`, `CDChapter`, `CDBookmark`, `CDPlaylist`, `CDSmartPlaylist`, `CDEpisodeList`
- **IC*-Prefix** = Parser Objects (immutable): `ICFeed`, `ICEpisode`, `ICMedia`, `ICChapter`, `ICCategory`
- **VM*-Prefix** = VemedioKit Utilities

### Manager Singletons

`DMANAGER` (DatabaseManager), `CacheManager.sharedCacheManager`, `AudioSession.sharedAudioSession`, `PlaybackManager.playbackManager`, `SubscriptionManager.shared`, `UIManager.shared`, `ImageCacheManager`

### Key Directories

`Classes/Model/` (Core Data), `Classes/Parser/` (Feed-Parsing), `Classes/Metadata/` (Chapters), `VemedioKit/` (Extensions), `VemedioDatabase/` (SQLite/FMDB)

### App Flow

`main.m → Application → InstacastAppDelegate → MainViewController_4`

### Important Macros (Instacast_Prefix.pch)

`DMANAGER`, `USER_DEFAULTS`, `DebugLog(format, ...)`, `WEAK_SELF / STRONG_SELF`

## Debugging Rules

- **NEVER use fallbacks or workarounds.** Immer die echte Ursache finden und fixen.
- **NIEMALS Verzögerungen (dispatch_after, delays) einbauen um Probleme zu kaschieren!**
- **KEINE Kurzschluss-Lösungen!** Nicht eigenmächtig Code umbauen, UI-Elemente verschieben oder Layouts ändern die nicht verlangt wurden. Erst analysieren, debuggen, loggen, testen und NACHFRAGEN bis das Problem wirklich verstanden ist. Dann eine saubere, minimal-invasive Lösung vorschlagen die NUR das eigentliche Problem behebt.
- **NIEMALS Vermutungs-Fixes!** Wenn die Ursache unklar ist: SOFORT DebugLogs einbauen, User testen lassen, Log-Daten analysieren. Erst wenn Messdaten die Ursache belegen, einen Fix implementieren. NICHT "mal ausprobieren ob es daran liegt".

## Localization

Alle UI-Texte immer **zweisprachig** (Deutsch + Englisch) in `Localizable.strings`.

## Coding Conventions

- `DMANAGER` für alle DB-Operationen
- `NSNotifications` für State-Kommunikation zwischen Komponenten
- Categories extensiv für Foundation/UIKit-Erweiterungen
- `#if TARGET_OS_IPHONE` für plattformspezifischen Code
- Separate Resources: `Resources-iPhone/`, `Resources-iPad/`

## URL Schemes

`podcast://`, `itpc://`, `instacast3://`, `instacast://`, `instacast-subscribe://`, `podcast-subscribe://`

## Player Controls Pane Height

Berechnung in `Classes/PlayerController.m`: `MAX(windowHeight - statusBarHeight - 44 - windowWidth - OFFSET, MINIMUM)`. OFFSET (70) steuert Überlappung mit Chapter Art, MINIMUM (194) aus `PlayerControlView.xib`.

## Dark Mode / Appearance Handling

`ICAppearanceManager` für Theme-Wechsel. Kernregeln:

1. **App-Start:** `updateAppearance` nochmals nach Window-Erstellung in `InstacastSceneDelegate` aufrufen (Window ist bei `+initialize` noch nil)
2. **Farben:** Immer `ICBackgroundColor`, `ICTextColor`, `ICTintColor` etc. verwenden, nie hardcodierte Farben. In `ICNightAppearance` explizite Farben statt dynamischer System-Farben.
3. **Observer:** In `viewDidLoad` registrieren, in `dealloc` entfernen (nicht viewWillAppear/viewDidDisappear)
4. **reloadData:** Hauptmenüs → immer reloaden. Detail-Views → nur wenn `self.tableView.window && !self.transitionCoordinator`

## iOS 26 Liquid Glass

- Glass-Artefakte durch Content hinter NavBar → `edgesForExtendedLayout = UIRectEdgeBottom` setzen (NICHT `UIRectEdgeNone`!)
- Opake NavBar: `UINavigationBarAppearance` mit `backgroundImage` verwenden (nicht nur `backgroundColor`)
- **NICHT** `hidesSharedBackground`, `UIButtonTypeCustom` als customView, oder opake Views hinter die Bar als Workaround

## iOS 26 Floating Toolbar — Touch-Blocking & Custom Floating Buttons

iOS 26 rendert `UINavigationController.toolbar` als Floating Bar über einer `FloatingBarContainerView` (SwiftUI-basiert).

### Touch-Blocking Problem

Die `FloatingBarHostingView` fängt Touches in einer **86pt Zone** über der sichtbaren Toolbar-Pill (48pt) ab. Content darunter (Tabellen-Zellen, WebView-Links, Cookie-Banner) ist nicht antippbar. Es gibt **keine öffentliche API** um die Hit-Area zu verkleinern. Runtime-Swizzling auf privaten Views (`method_setImplementation`) bricht System-Gesten — NIEMALS machen.

### Lösung: Custom Floating Glass Buttons (iOS 26 only)

System-Toolbar verstecken (`toolbarHidden = YES`), stattdessen eigene `UIButton`s mit `UIButtonConfiguration.glassButtonConfiguration` und `buttonSize = UIButtonConfigurationSizeLarge`. Buttons werden auf `self.navigationController.view` gelegt (über dem TableView, scrollt nicht mit). Nur der Button-Frame selbst blockiert Touches.

**KRITISCH:** `toolbarHidden` auf iOS 26 **NIEMALS** von YES auf NO und zurück togglen! Das Setzen von `toolbarHidden = NO` erzeugt eine `FloatingBarContainerView` die nach `toolbarHidden = YES` im View-Hierarchy bestehen bleibt und dauerhaft Touches auf den Floating Buttons blockiert. `bringSubviewToFront` hilft NICHT. Stattdessen eigene `UIToolbar` für temporäre Toolbars (z.B. Editing-Mode) verwenden.

**Zwei Code-Pfade:** iOS ≤25 nutzt weiterhin die System-Toolbar (`_updateToolbarItemsAnimated:`). iOS 26 nutzt Floating Glass Buttons. Unterscheidung via `@available(iOS 26.0, *)`.

**Lifecycle-Pattern für jeden VC:**
- `viewDidLoad`: `toolbarHidden = YES`, Floating Buttons erstellen und auf `navigationController.view` layouten
- `viewWillAppear`: `toolbarHidden = YES`, Buttons `.hidden = NO`, `bringSubviewToFront:`
- `viewWillDisappear`: `toolbarHidden = NO` (für nächsten VC), Buttons `.hidden = YES`

**Theme-Handling:** Glass Buttons erben `overrideUserInterfaceStyle` nicht zuverlässig bei modaler Präsentation (Window noch nicht verbunden in `viewDidLoad`). Daher bei Erstellung und in `updateAppearance` explizit `overrideUserInterfaceStyle` basierend auf `[ICAppearanceManager sharedManager].nightSettingMode` setzen.

**Bereits umgestellt:** `SubscriptionsTableViewController` (2 Buttons: Add+Sort), `EpisodesTableViewController` (1 Button: Edit/pencil; Editing-Mode nutzt eigene UIToolbar statt System-Toolbar), `DirectoryFeedViewController` (1 Button: Action/Share), `WebController` (3 Buttons: Back+Forward dynamisch via KVO, Safari), `FeedViewController` (3 Buttons: Reload+Share+Settings).

### Layout-Regeln (weiterhin gültig)

- **`edgesForExtendedLayout = UIRectEdgeBottom`** auf allen VCs mit Toolbar/Floating Buttons (NICHT `UIRectEdgeNone`!)
- **Ausnahme:** `PlayerController` nutzt `UIRectEdgeNone` bewusst — die Höhenberechnung der Controls-Pane basiert darauf (`size.height ≈ window height - statusbar - navbar`). Der PlayerController hat keine System-Toolbar und keine Floating Buttons, sondern eigenes Custom-Layout.
- Die Fläche erscheint nach Theme-Wechsel und verschwindet nach Navigation.

## iOS 26 Scroll Edge Effect

Dunkler Verlauf am unteren ScrollView-Rand unter Floating-Toolbar → `scrollView.bottomEdgeEffect.hidden = YES` (iOS 26+). Nur relevant für VCs mit Toolbar/Floating Buttons. Bereits angewendet auf: `SubscriptionsTableViewController`, `FeedEpisodesTableViewController`, `DirectoryFeedViewController`, `EpisodeViewController`, `WebController`, `FeedViewController`. Toolbar-Appearance-Änderungen haben keinen Effekt darauf.

## Apple Podcast Charts APIs

- **Neue API (v2):** `rss.marketingtools.apple.com/api/v2/{country}/podcasts/top/{limit}/podcasts.json` — max 100, kein Genre-Filter
- **Alte iTunes RSS:** `itunes.apple.com/{country}/rss/toppodcasts/limit={limit}/genre={genreId}/json` — max 200, Genre-Filter per URL
- **Lookup:** `itunes.apple.com/lookup?id={id}&entity=podcast`
- Implementierung: `ApplePodcastChartsClient` — Phase 1 neue API (50), Phase 2 alte API (20/Genre parallel), Merge mit Deduplizierung
- Sub-Kategorien haben **eigene Charts** — lohnt sich separat zu fetchen
- Genre-IDs: Siehe `ApplePodcastChartsClient` Implementierung

## UITextView Non-Contiguous Layout

UITextView mit `scrollEnabled=YES` verwendet Non-Contiguous Layout (geschätzte Zeilenhöhen für nicht-sichtbaren Text).

**Kritisches Problem:** Wenn `textStorage beginEditing/endEditing` Attribute an zwei entfernten Stellen ändert, invalidiert der LayoutManager die gesamte Union-Range. `ensureLayoutForCharacterRange` nur bis zum Ziel-Cue lässt eine Lücke mit geschätzten Höhen. UITextView berechnet diese nach, `contentSize` springt, `contentOffset` wird automatisch angepasst → programmatische Scroll-Position zerstört.

**Lösung:** `ensureLayoutForCharacterRange:NSMakeRange(0, textStorage.length)` — immer gesamten Text layouten. Gilt generell: bei programmatischem Scrollen in UITextView nach Attribut-Änderungen nie nur partielle Ranges layouten.

## Bug-Hunt Erkenntnisse (für zukünftige Audits)

### Singleton-Pattern: KEIN dispatch_once verwenden!

Die Singletons (`DatabaseManager`, `CacheManager`, `SubscriptionManager`) nutzen bewusst das Split-Pattern:
```objc
if (!gShared) {
    gShared = [self alloc];
    gShared = [gShared init];
}
```
**NICHT** durch `dispatch_once` ersetzen! Der `init`-Aufruf greift rekursiv via `DMANAGER` auf `sharedDatabaseManager` zu. `dispatch_once` deadlockt bei Reentrancy. Das Split-Pattern setzt `gShared` nach `alloc` (vor `init`), sodass der rekursive Aufruf die teilweise initialisierte Instanz zurückgibt.

### Häufige Bug-Patterns in dieser Codebasis

1. **NSTimer Retain Cycles:** `@property (strong) NSTimer*` + `target:self` + `repeats:YES` → Timer retains self, self retains timer. **Immer** `dealloc` mit `[timer invalidate]` prüfen. Betroffene Klassen (gefixt): `CircleProgressView`, `EpisodePlayComboButton`, `ICBackupImportProgressView`, `PlayerController`.

2. **NSNotification Observer ohne dealloc:** `addObserver:` in `viewDidLoad` ohne `removeObserver:` in `dealloc`. Betroffene Klassen (gefixt): `PlaybackControlsViewController`, `DirectorySearchViewController`.

3. **Block-basierte Observer-API Token verworfen:** `addObserverForName:usingBlock:` Rückgabewert nicht gespeichert → Observer kann nie entfernt werden, Block captured self stark. Betroffene Klasse (gefixt): `AudioSession._observeEpisodeCacheBeingDeleted`.

4. **Core Data Threading:** `DMANAGER.objectContext` ist `NSMainQueueConcurrencyType` — darf NUR auf dem Main Thread benutzt werden. Parser-Callbacks (`didParseFeedBlock`, `didEndWithError`) laufen auf der `parserQueue` (Background). Immer `dispatch_async(dispatch_get_main_queue())` wrappen. Betroffene Methode (gefixt): `SubscriptionManager._importURLs:completion:`.

5. **`WEAK_SELF` Scope beachten:** Vor Hinzufügen prüfen ob `WEAK_SELF` schon weiter oben in derselben Methode deklariert ist — sonst Redefinition-Compilerfehler.

### False Positives die NICHT gefixt werden müssen

- **Singleton Observer-Leaks** (AudioSession, Application, SmarthomeManager): Singletons leben ewig, Observer-Cleanup irrelevant.
- **`_savingInterruption` unsynchronized read:** Alle Caller auf Main Thread.
- **`refreshingFeedURLs` Thread-Safety:** Alle Mutationen auf Main Thread (verifiziert).
- **`performBlockAndWait` in `mergeQueue`:** Wird von Background-Queue aufgerufen, kein Main-Thread-Deadlock.
- **`reloadData` in `viewDidAppear`/`viewWillAppear`:** `tableView.window` ist dort immer gesetzt. Das `if (window && !transitionCoordinator)` Pattern ist nur für `updateAppearance`-Notifications relevant.
- **`dispatch_after` in Import-Completion:** Bewusstes UX-Pattern (User soll "Import Complete" lesen können).

## macOS "Designed for iPad" — TCC Dialog & Runtime Guards

Die App läuft auf macOS als "Designed for iPad" (NICHT Mac Catalyst). `#if TARGET_OS_MACCATALYST` ist daher immer `0` — stattdessen Runtime-Check: `NSProcessInfo.processInfo.isiOSAppOnMac` (ab iOS 14).

### TCC Dialog "möchte auf Daten aus anderen Apps zugreifen"

**Zwei unabhängige Trigger (beide beheben!):**

1. **`UNUserNotificationCenter requestAuthorizationWithOptions:`** — Fix: mit `isiOSAppOnMac` gegated in `InstacastAppDelegate.m`. Push-Notifications funktionieren auf Mac ohnehin nicht sinnvoll.

2. **`com.apple.security.application-groups` Entitlement** — Das Entitlement allein (ohne Code-Zugriff) löst TCC aus. Fix: SDK-spezifische Entitlements per `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`. `Instacast.entitlements` (iOS, mit `application-groups` → Widgets funktionieren) vs. `InstacastMac.entitlements` (Mac, ohne `application-groups` → kein TCC). Selbes Pattern wie bereits für `PRODUCT_BUNDLE_IDENTIFIER[sdk=macosx*]` genutzt.

**NICHT der Trigger:** `AVAudioSession`, `Reachability`, `registerForRemoteNotifications`.

**Aufgeräumt:** `InstacastHD.entitlements` war eine tote Datei (nirgends im pbxproj referenziert, Relikt aus der Zeit separater iPad-Apps). Gelöscht.

### Gegated auf Mac (via `isiOSAppOnMac`):

| Wo | Was | Grund |
|---|---|---|
| `InstacastAppDelegate.m` | `requestAuthorizationWithOptions` | TCC-Dialog-Trigger |
| `Application.m` | `CTTelephonyNetworkInfo` | Existiert nicht auf Mac |
| `Application.m` | `CTServiceRadioAccessTechnologyDidChangeNotification` | Existiert nicht auf Mac |
| `Application.m` | `CMMotionManager` (deviceMotionDetection) | Existiert nicht auf Mac |
| `WidgetDataExporter.m` | `sharedExporter` returniert `nil` | iOS-Widgets funktionieren nicht auf Mac |
| `WidgetKitHelper.swift` | `reloadAllTimelines`, `startListeningForWidgetActions` | iOS-Widgets funktionieren nicht auf Mac |
| `InstacastSceneDelegate.m` | Window-Größe (402×874pt Start) | iPhone-Proportionen auf Mac |

### NICHT gegated (läuft auch auf Mac):

- `AVAudioSession` Volume KVO — funktioniert, kein TCC-Trigger
- `Reachability` — funktioniert auf Mac
- `UNUserNotificationCenter.delegate` Assignment — kein TCC-Trigger
- `registerForRemoteNotifications` — kein TCC-Trigger

### Widget-Embedding auf Mac

`InstacastWidgets.appex` hat `platformFilter = ios` im pbxproj → wird nicht in Mac-Builds eingebettet (vermeidet Build-Fehler "embedded content built for iOS platform").

## Key Integrations

CarPlay, AVFoundation, OPML import/export, Podlove Standard Chapters
