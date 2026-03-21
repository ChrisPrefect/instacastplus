# CLAUDE.md — Instacast+

Podcast-App iOS/macOS, Objective-C. v2.9, min iOS 13.0. CarPlay, AVFoundation, OPML, Podlove Chapters.

## Build — NICHT automatisch builden!

```bash
xcodebuild -project Instacast.xcodeproj -scheme Instacast build          # iPhone
xcodebuild -project Instacast.xcodeproj -scheme "Instacast HD" build     # iPad
xcodebuild -project Instacast.xcodeproj -scheme InstacastMac build       # macOS
xcodebuild -project Instacast.xcodeproj -scheme "Instacast Tests" test   # Tests
```

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

### Scroll Edge Effect

`scrollView.bottomEdgeEffect.hidden = YES` (iOS 26+). Angewendet: `SubscriptionsTableVC`, `FeedEpisodesTableVC`, `DirectoryFeedVC`, `EpisodeVC`, `WebController`, `FeedVC`.

## Apple Podcast Charts

Neue API: `rss.marketingtools.apple.com/api/v2/{country}/podcasts/top/{limit}/podcasts.json` (max 100, kein Genre).
Alte API: `itunes.apple.com/{country}/rss/toppodcasts/limit={limit}/genre={genreId}/json` (max 200, Genre per URL).
Lookup: `itunes.apple.com/lookup?id={id}&entity=podcast`.
Impl: `ApplePodcastChartsClient` — Phase 1 neue(50), Phase 2 alte(20/Genre parallel), Merge+Dedup. Sub-Kategorien haben eigene Charts.

## UITextView Non-Contiguous Layout

`scrollEnabled=YES` → geschätzte Zeilenhöhen. `textStorage beginEditing/endEditing` an entfernten Stellen → partielle `ensureLayoutForCharacterRange` lässt Lücken → `contentSize` springt → Scroll-Position zerstört. **Fix:** Immer `ensureLayoutForCharacterRange:NSMakeRange(0, textStorage.length)`.

## Bug-Hunt Erkenntnisse

### Singleton: KEIN dispatch_once!

`gShared = [self alloc]; gShared = [gShared init];` — `init` greift rekursiv via `DMANAGER` zu. `dispatch_once` deadlockt bei Reentrancy. Split-Pattern setzt `gShared` nach `alloc`, rekursiver Aufruf bekommt teilinitialisierte Instanz.

### Bekannte Patterns (gefixt)

- **NSTimer Retain Cycle:** `strong` Timer + `target:self` + `repeats:YES` → `[timer invalidate]` in `dealloc`. Gefixt: `CircleProgressView`, `EpisodePlayComboButton`, `ICBackupImportProgressView`, `PlayerController`
- **Observer ohne dealloc:** Gefixt: `PlaybackControlsViewController`, `DirectorySearchViewController`
- **Block-Observer Token verworfen:** `addObserverForName:usingBlock:` nicht gespeichert. Gefixt: `AudioSession._observeEpisodeCacheBeingDeleted`
- **Core Data Threading:** `DMANAGER.objectContext` = `NSMainQueueConcurrencyType`, NUR Main Thread. Parser-Callbacks auf `parserQueue` → `dispatch_async(main)`. Gefixt: `SubscriptionManager._importURLs:completion:`
- **`WEAK_SELF` Scope:** Prüfen ob schon deklariert → Redefinition-Error

### False Positives (NICHT fixen)

Singleton Observer-Leaks (leben ewig). `_savingInterruption` unsync read (Main Thread only). `refreshingFeedURLs` (Main Thread only). `performBlockAndWait` in `mergeQueue` (Background-Queue). `reloadData` in `viewDidAppear` (`tableView.window` gesetzt; `window && !transitionCoordinator` nur für `updateAppearance`). `dispatch_after` Import-Completion (bewusstes UX).

## Icon-Referenz (KONSISTENT halten!)

Alle Stellen (Swipe-Aktionen, Context-Menüs, Popup-Menüs, Toolbars) MÜSSEN identische Icons verwenden.

| Aktion | SF Symbol | Asset-Alternative | Farbe |
|---|---|---|---|
| Download | `square.and.arrow.down` | `Toolbar Download` / `Multitoolbar Download` | Akzentfarbe |
| Download löschen / abbrechen | `trash` | — | Rot |
| Datei löschen | `trash` | — | Rot |
| Episode löschen (aus Liste) | `trash` | — | Rot |
| Favorit markieren | `star` | — | Akzentfarbe |
| Favorit entfernen | `star.slash` | — | Grau |
| Als gehört markieren | `circle` | — | Grau |
| Als ungehört markieren | `circle.fill` | — | Akzentfarbe |
| Zur Abspielliste hinzufügen | `text.badge.plus` | — | Akzentfarbe |
| Aus Abspielliste entfernen | `text.badge.minus` | — | Grau |
| Episoden Info | `info.circle` | — | Akzentfarbe |
| Play Next (Seitenmenü/Context) | `list.bullet.indent` | — | — |
| Abspielen | `play.fill` | — | — |

Stellen: `_imageForSwipeAction:episode:`, `_contextMenuForIndexPath:` (EpisodesTableViewController), Popup-Menü (EpisodeViewController), Toolbar/Glass Buttons, CarPlay (InstacastSceneDelegate).

## macOS "Designed for iPad"

NICHT Mac Catalyst → `#if TARGET_OS_MACCATALYST` = 0. Runtime: `isiOSAppOnMac` (iOS 14+).

TCC-Trigger: (1) `requestAuthorizationWithOptions:` → gegated in AppDelegate. (2) `application-groups` Entitlement → `Instacast.entitlements`(iOS, mit groups) vs `InstacastMac.entitlements`(Mac, ohne) via `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`. KEIN Trigger: AVAudioSession, Reachability, registerForRemoteNotifications.

Mac-Gates (`isiOSAppOnMac`): `requestAuthorizationWithOptions`(AppDelegate), `CTTelephonyNetworkInfo/CTServiceRadio.../CMMotionManager`(Application.m), `WidgetDataExporter.sharedExporter→nil`, `WidgetKitHelper`(reloadTimelines/startListening), Window-Größe 402×874(SceneDelegate).

Nicht gegated (funktioniert): AVAudioSession Volume KVO, Reachability, UNUserNotificationCenter.delegate, registerForRemoteNotifications.

Widget: `InstacastWidgets.appex` → `platformFilter=ios`, nicht in Mac-Builds.
