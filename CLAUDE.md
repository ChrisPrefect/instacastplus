# CLAUDE.md

## Project Overview

Instacast+ — Podcast-App für iOS/macOS in Objective-C. Feed-Parsing, Playback, Chapters, Bookmarks, Sync.

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

- Glass-Artefakte durch Content hinter NavBar → `edgesForExtendedLayout = UIRectEdgeNone` setzen
- Opake NavBar: `UINavigationBarAppearance` mit `backgroundImage` verwenden (nicht nur `backgroundColor`)
- **NICHT** `hidesSharedBackground`, `UIButtonTypeCustom` als customView, oder opake Views hinter die Bar als Workaround

## iOS 26 Scroll Edge Effect

Dunkler Verlauf am unteren ScrollView-Rand unter Floating-Toolbar → `scrollView.bottomEdgeEffect.hidden = YES` (iOS 26+). Bereits angewendet auf: `SubscriptionsTableViewController`, `FeedEpisodesTableViewController`, `DirectoryFeedViewController`, `EpisodeViewController`. Toolbar-Appearance-Änderungen haben keinen Effekt darauf.

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

## Key Integrations

CloudKit (iCloud sync), CarPlay, AVFoundation, OPML import/export, Podlove Standard Chapters
