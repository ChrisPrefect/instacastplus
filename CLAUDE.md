# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Instacast+ is a professional podcast management and playback application for iOS and macOS, written in Objective-C. It supports feed parsing, episode management, audio/video playback, chapters, bookmarks, and rich metadata handling.

**Current Version:** 2.9 (Config/Version.xcconfig)
**Minimum iOS:** 13.0

## Build Commands

**WICHTIG: Nicht automatisch builden!** Der Entwickler buildet selbst für den Simulator. Automatische Builds verzögern nur das Testen.

```bash
# Build iOS (iPhone)
xcodebuild -project Instacast.xcodeproj -scheme Instacast build

# Build iOS (iPad)
xcodebuild -project Instacast.xcodeproj -scheme "Instacast HD" build

# Build macOS
xcodebuild -project Instacast.xcodeproj -scheme InstacastMac build

# Run tests
xcodebuild -project Instacast.xcodeproj -scheme "Instacast Tests" test
```

## Architecture

### Data Layer: Core Data + SQLite Hybrid

**Core Data Entities (CD* prefix):**
- `CDFeed` - Subscribed podcast
- `CDEpisode` - Individual episode
- `CDMedia` - Media URLs for episodes
- `CDChapter` - Chapter markers
- `CDBookmark` - User bookmarks
- `CDPlaylist/CDSmartPlaylist` - Playlists
- `CDEpisodeList` - Episode collections (e.g., "Unplayed")

**Parser Objects (IC* prefix) - immutable parsed data:**
- `ICFeed`, `ICEpisode`, `ICMedia`, `ICChapter`, `ICCategory`

### Manager Singletons

| Manager | Access Macro/Method | Purpose |
|---------|---------------------|---------|
| DatabaseManager | `DMANAGER` | Core Data operations, feed/episode management |
| CacheManager | `CacheManager.sharedCacheManager` | Episode downloads, disk cache |
| AudioSession | `AudioSession.sharedAudioSession` | Audio playback, route detection |
| PlaybackManager | `PlaybackManager.playbackManager` | High-level playback control |
| SubscriptionManager | `SubscriptionManager.shared` | Feed subscription service |
| UIManager | `UIManager.shared` | Platform-specific UI coordination |
| ImageCacheManager | Direct reference | In-memory image caching |

### Key Source Directories

- `Classes/Model/` - Core Data entities and DatabaseManager
- `Classes/Parser/` - Feed parsing (ICFeedParser, NSXMLParser-based)
- `Classes/Metadata/` - Chapter and asset parsing
- `VemedioKit/` - Foundation/UI extensions, utilities
- `VemedioDatabase/` - SQLite abstraction via FMDB/FCModel

### Application Flow

```
main.m → Application (custom UIApplication) → InstacastAppDelegate → MainViewController_4
```

## Important Macros (Instacast_Prefix.pch)

```objc
DMANAGER                    // [DatabaseManager sharedDatabaseManager]
USER_DEFAULTS               // [NSUserDefaults standardUserDefaults]
DebugLog(format, args...)   // Conditional debug logging
WEAK_SELF / STRONG_SELF     // Memory management helpers
```

## Debugging Rules

- **NEVER use fallbacks or workarounds.** Always find and fix the real root cause of bugs.
- Understand WHY something is broken before attempting to fix it.
- **NIEMALS Verzögerungen (dispatch_after, delays) einbauen um Probleme zu kaschieren!** Immer die Ursache finden und sauber lösen.
- **KEINE Kurzschluss-Lösungen!** Nicht eigenmächtig Code umbauen, UI-Elemente verschieben oder Layouts ändern die nicht verlangt wurden. Erst analysieren, debuggen, loggen, testen und NACHFRAGEN bis das Problem wirklich verstanden ist. Dann eine saubere, minimal-invasive Lösung vorschlagen die NUR das eigentliche Problem behebt und nichts anderes anfasst.

## Localization

- **Alle UI-Texte immer zweisprachig übersetzen** (Deutsch + Englisch). Jeder String der im UI angezeigt wird muss in beiden Sprachen vorhanden sein.

## Coding Conventions

- **DMANAGER** for all database operations
- **NSNotifications** for state communication between components (e.g., `DatabaseManagerDidUpdateObservedFeedNotification`)
- **Categories** extensively used for extending Foundation/UIKit classes
- Platform-specific code uses `#if TARGET_OS_IPHONE`
- Separate resources exist for iPhone (`Resources-iPhone/`) and iPad (`Resources-iPad/`)

## Naming Conventions

| Prefix | Meaning |
|--------|---------|
| `CD*` | Core Data entity |
| `IC*` | Instacast parser/data structure |
| `VM*` | VemedioKit utility class |
| `*ViewController` | View controller |
| `*Manager` | Singleton manager |

## Supported URL Schemes

`podcast://`, `itpc://`, `instacast3://`, `instacast://`, `instacast-subscribe://`, `podcast-subscribe://`

## Player Controls Pane Height

The player controls pane height directly affects how much of the chapter art is visible. The calculation is in `Classes/PlayerController.m`:

```objc
CGFloat controllerHeight = MAX(windowHeight - statusBarHeight - 44 - windowWidth - OFFSET, MINIMUM);
```

**Key factors:**
- `windowWidth` is used as the chapter art height (square artwork)
- `44` is the navigation bar height
- `OFFSET` (currently 70): Reduces pane height to prevent overlap with chapter art. Increase this value if the pane covers the chapter art.
- `MINIMUM` (currently 194): Base height defined in `PlayerControlView.xib`

**To adjust chapter art visibility:**
- Pane covers chapter art → Increase the OFFSET value (e.g., -70 → -80)
- Gap between chapter art and pane → Decrease the OFFSET value (e.g., -70 → -60)

**Internal layout** (`Resources-iPhone/Nibs/PlayerControlView.xib`):
- Scrubber (seek bar + time labels): top of pane, y=15 padding from top
- Controls (play/back/forward): y=37
- Volume buttons: y=92
- Toolbar: y=144

## Dark Mode / Appearance Handling

Die App verwendet `ICAppearanceManager` für Theme-Wechsel (Light/Dark Mode). **Häufige Fehlerquellen:**

### 1. Timing beim App-Start

**Problem:** `ICAppearanceManager.updateAppearance` wird in `+initialize` aufgerufen, bevor das Window existiert. Zu diesem Zeitpunkt ist `[(InstacastAppDelegate*)App.delegate window]` noch `nil`.

**Lösung:** Nach dem Erstellen des Windows in `InstacastSceneDelegate` nochmals `[[ICAppearanceManager sharedManager] updateAppearance]` aufrufen.

### 2. Dynamische Farben vs. explizite Farben

**Problem:** `[UIColor labelColor]` und andere dynamische Farben werden zum Zeitpunkt des Aufrufs mit der aktuellen Trait Collection aufgelöst. Wenn die Trait Collection noch nicht korrekt ist, werden falsche Farben verwendet.

**Lösung:** In `ICNightAppearance` explizite Farben verwenden (z.B. `[UIColor whiteColor]` statt `[UIColor labelColor]`), um Timing-Probleme zu vermeiden.

### 3. Hardcodierte Farben

**Problem:** Views mit `backgroundColor = [UIColor whiteColor]` respektieren Dark Mode nicht.

**Lösung:** Immer `ICBackgroundColor`, `ICTextColor`, etc. aus `ICAppearanceManager.h` verwenden.

### 4. Notification Observer Lifecycle

**Problem:** Observer für `ICAppearanceManagerDidUpdateAppearanceNotification` wird in `viewWillAppear` registriert und in `viewDidDisappear` entfernt. Wenn ein ViewController in der Navigation-Hierarchie bleibt (z.B. Settings-Hauptmenü), aber nicht sichtbar ist, erhält er keine Theme-Updates.

**Lösung:** Observer in `viewDidLoad` registrieren und nur in `dealloc` entfernen:
```objc
- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
```

### 5. reloadData und Navigation Stack

**Problem A:** `[self.tableView reloadData]` in `updateAppearance` während `viewWillAppear` blockiert die Einfahranimation.

**Problem B:** Views die im Navigation Stack bleiben (z.B. Settings-Hauptmenü → Darstellungsoptionen) aktualisieren sich nicht, wenn nur `backgroundColor` gesetzt wird. Die Zellen behalten ihre alten Farben.

**Lösung - je nach ViewController-Typ:**

**Für Views die im Navigation Stack bleiben können (z.B. Hauptmenüs):**
```objc
- (void)updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.view.backgroundColor = ICBackgroundColor;
    // IMMER reloaden - auch wenn nicht sichtbar, damit beim Zurück-Navigieren alles stimmt
    [self.tableView reloadData];
}
```

**Für Views am Ende der Navigation (z.B. Detail-Views, modale Views):**
```objc
- (void)updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    // Nur reloaden wenn sichtbar UND keine Animation läuft
    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}
```

### Checkliste für neue ViewControllers

1. ✅ Keine hardcodierten Farben (`[UIColor whiteColor]`, etc.)
2. ✅ `ICBackgroundColor`, `ICTextColor`, `ICTintColor` etc. verwenden
3. ✅ Notification Observer in `viewDidLoad` registrieren, in `dealloc` entfernen
4. ✅ Für Hauptmenüs: `reloadData` immer aufrufen (ohne Checks)
5. ✅ Für Detail-Views: `reloadData` mit Window-Check und TransitionCoordinator-Check

## iOS 26 Liquid Glass

Ab iOS 26 verwenden `UINavigationBar`, `UIToolbar` und `UITabBar` den neuen **Liquid Glass** Effekt. Bar Button Items bekommen automatisch kreisförmige Glass-Hintergründe, die den darunterliegenden Content durchscheinen lassen.

### Liquid Glass Button APIs

| Property | Zweck |
|----------|-------|
| `barButtonItem.hidesSharedBackground = YES` | Entfernt den Glass-Hintergrund komplett (Button wird zum flachen Icon) |
| `barButtonItem.sharesBackground = NO` | Verhindert Gruppierung mit benachbarten Buttons (Glass bleibt aber erhalten) |
| `[UIBarButtonItem fixedSpace]` | Visueller Separator zwischen Button-Gruppen |

### Content hinter der Navigation Bar = Glass-Artefakte

**Problem:** Wenn Content (z.B. Chapter Art, Bilder) hinter der Navigation Bar scrollt, reagieren die Liquid Glass Buttons darauf - sie ändern ihre Farbe/Helligkeit je nach darunterliegendem Content.

**Ursache:** `contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever` + fehlende `edgesForExtendedLayout` Einschränkung → Content scrollt hinter die Bar → Liquid Glass samplet diesen Content.

**Lösung:** `edgesForExtendedLayout = UIRectEdgeNone` auf dem ViewController setzen. Damit startet die View UNTER der Navigation Bar - kein Content hinter der Bar, Liquid Glass sieht nur die opake Bar-Farbe.

```objc
- (void)viewDidLoad {
    [super viewDidLoad];
    self.edgesForExtendedLayout = UIRectEdgeNone;  // Content nicht hinter die Bar
}
```

**Vergleich der Screens:**

| Eigenschaft | Player (vorher, Bug) | Podcast-/Episodenliste (korrekt) |
|-------------|---------------------|----------------------------------|
| `contentInsetAdjustmentBehavior` | `Never` (manuell) | `Automatic` (default) |
| `edgesForExtendedLayout` | nicht gesetzt (default `All`) | `UIRectEdgeNone` |
| Content hinter Bar | Ja → Glass-Artefakte | Nein → Glass stabil |

### Navigation Bar Appearance Pattern

Für opake Navigation Bars mit `UINavigationBarAppearance` immer `backgroundImage` verwenden (nicht nur `backgroundColor`):

```objc
UIImage *backgroundImage = [[ICAppearanceManager sharedManager] navigationBarBackgroundImage];
UINavigationBarAppearance *navAppearance = [[UINavigationBarAppearance alloc] init];
[navAppearance configureWithOpaqueBackground];
navAppearance.backgroundImage = backgroundImage;
navAppearance.shadowImage = [[UIImage alloc] init];
navAppearance.shadowColor = nil;
navAppearance.titleTextAttributes = @{ NSForegroundColorAttributeName : ICTextColor };
navBar.standardAppearance = navAppearance;
navBar.scrollEdgeAppearance = navAppearance;
navBar.compactAppearance = navAppearance;
```

### NICHT tun

- **NICHT** `hidesSharedBackground = YES` verwenden um Glass-Artefakte zu lösen - das entfernt das Button-Styling komplett
- **NICHT** `UIButtonTypeCustom` als `customView` verwenden - umgeht das gesamte iOS 26 Design
- **NICHT** opake Views hinter die Bar legen als Workaround - löst das Problem nicht zuverlässig
- **NICHT** `configureWithOpaqueBackground` allein nutzen - reicht in iOS 26 nicht aus, `backgroundImage` ist nötig

## iOS 26 Scroll Edge Effect (Bottom-Verlauf bei Listen)

Ab iOS 26 rendert UIKit automatisch einen **Scroll Edge Effect** (`_UIScrollPocket`) am unteren Rand von ScrollViews die unter einer Floating-Toolbar liegen. Dieser dunkle Verlauf (`darkeningAlpha = 0.85`) soll die Lesbarkeit der Toolbar-Buttons verbessern.

**Lösung:** `bottomEdgeEffect.hidden = YES` auf der ScrollView setzen:

```objc
if (@available(iOS 26.0, *)) {
    self.tableView.bottomEdgeEffect.hidden = YES;       // UITableView
    self.webView.scrollView.bottomEdgeEffect.hidden = YES; // WKWebView
}
```

**Bereits angewendet auf:**
- `SubscriptionsTableViewController` (Podcast-Liste)
- `FeedEpisodesTableViewController` (Episoden-Liste)
- `DirectoryFeedViewController` (Podcast-WebView)
- `EpisodeViewController` (Show Notes WebView)

**Was NICHT funktioniert (nicht nochmal versuchen!):**
- `[UIToolbar appearance] setBackgroundImage:` ändern → Hat keinen Effekt auf den Edge Effect
- `UIToolbarAppearance` mit `configureWithTransparentBackground` → Betrifft nur den Toolbar-Hintergrund, nicht den Edge Effect
- `_UIScrollPocket` per View-Hierarchie-Suche verstecken → Extrem langsam und unzuverlässig

**API-Referenz:** `UIScrollView.bottomEdgeEffect` (iOS 26+), `UIScrollEdgeEffect.hidden`, Styles: `.automaticStyle`, `.softStyle`, `.hardStyle`

## Apple Podcast Charts APIs

### Zwei APIs verfügbar (beide aktuell, mehrmals täglich aktualisiert)

**Neue API (v2):** `https://rss.marketingtools.apple.com/api/v2/{country}/podcasts/top/{limit}/podcasts.json`
- Max 100 Ergebnisse, KEIN Genre-Filter, kein Paging
- JSON-Schema: `feed.results[]` mit `name`, `artistName`, `artworkUrl100`, `id`, `url`, `genres[].genreId/name`
- Jeder Podcast hat mehrere Genres

**Alte iTunes RSS API:** `https://itunes.apple.com/{country}/rss/toppodcasts/limit={limit}/genre={genreId}/json`
- Max 200 Ergebnisse, **Genre-Filter per URL-Parameter**, kein Paging
- JSON-Schema: `feed.entry[]` mit `im:name.label`, `im:artist.label`, `im:image[].label`, `id.attributes.im:id`, `category.attributes.im:id/label`
- Jeder Podcast hat nur EINE Kategorie
- Nicht offiziell dokumentiert, funktioniert aber einwandfrei

**iTunes Lookup API** (Podcast-ID → Feed-URL): `https://itunes.apple.com/lookup?id={id}&entity=podcast`

### Implementierung (ApplePodcastChartsClient)
- Phase 1: 50 von neuer API (schnell, 1 Request)
- Phase 2: 20 pro Genre von alter API (19 Requests parallel)
- Merge mit Deduplizierung nach Podcast-ID
- Stale-while-revalidate Caching (Memory + Disk, 30min TTL)

### Genre-IDs (alle funktionieren mit alter iTunes RSS API)

**Wichtig:** Sub-Kategorien haben **eigene, unabhängige Charts**. Podcasts aus Sub-Kategorien erscheinen NICHT zwingend in der Hauptkategorie. Fetching von Sub-Kategorien liefert zusätzliche, einzigartige Podcasts.

| ID | Kategorie | Sub von |
|----|-----------|---------|
| 1301 | Arts | — |
| 1482 | Books | Arts |
| 1402 | Design | Arts |
| 1459 | Fashion & Beauty | Arts |
| 1306 | Food | Arts |
| 1405 | Performing Arts | Arts |
| 1303 | Comedy | — |
| 1496 | Comedy Interviews | Comedy |
| 1495 | Improv | Comedy |
| 1497 | Stand-Up | Comedy |
| 1304 | Education | — |
| 1501 | Courses | Education |
| 1499 | How To | Education |
| 1498 | Language Learning | Education |
| 1500 | Self-Improvement | Education |
| 1305 | Kids & Family | — |
| 1519 | Education for Kids | Kids & Family |
| 1520 | Stories for Kids | Kids & Family |
| 1521 | Parenting | Kids & Family |
| 1522 | Pets & Animals | Kids & Family |
| 1309 | TV & Film | — |
| 1562 | After Shows | TV & Film |
| 1564 | Film History | TV & Film |
| 1565 | Film Interviews | TV & Film |
| 1563 | Film Reviews | TV & Film |
| 1561 | TV Reviews | TV & Film |
| 1310 | Music | — |
| 1523 | Music Commentary | Music |
| 1524 | Music History | Music |
| 1525 | Music Interviews | Music |
| 1314 | Religion & Spirituality | — |
| 1438 | Buddhism | Religion |
| 1439 | Christianity | Religion |
| 1463 | Hinduism | Religion |
| 1440 | Islam | Religion |
| 1441 | Judaism | Religion |
| 1318 | Technology | — |
| 1321 | Business | — |
| 1410 | Careers | Business |
| 1493 | Entrepreneurship | Business |
| 1412 | Investing | Business |
| 1491 | Management | Business |
| 1492 | Marketing | Business |
| 1494 | Non-Profit | Business |
| 1324 | Society & Culture | — |
| 1543 | Documentary | Society & Culture |
| 1302 | Personal Journals | Society & Culture |
| 1443 | Philosophy | Society & Culture |
| 1320 | Places & Travel | Society & Culture |
| 1544 | Relationships | Society & Culture |
| 1483 | Fiction | — |
| 1486 | Comedy Fiction | Fiction |
| 1484 | Drama | Fiction |
| 1485 | Science Fiction | Fiction |
| 1487 | History | — |
| 1488 | True Crime | — |
| 1489 | News | — |
| 1526 | Daily News | News |
| 1490 | Business News | News |
| 1531 | Entertainment News | News |
| 1530 | News Commentary | News |
| 1527 | Politics | News |
| 1529 | Sports News | News |
| 1528 | Tech News | News |
| 1502 | Leisure | — |
| 1510 | Animation & Manga | Leisure |
| 1503 | Automotive | Leisure |
| 1504 | Aviation | Leisure |
| 1506 | Crafts | Leisure |
| 1507 | Games | Leisure |
| 1511 | Government | — |
| 1512 | Health & Fitness | — |
| 1513 | Alternative Health | Health & Fitness |
| 1514 | Fitness | Health & Fitness |
| 1518 | Medicine | Health & Fitness |
| 1517 | Mental Health | Health & Fitness |
| 1533 | Science | — |
| 1538 | Astronomy | Science |
| 1539 | Chemistry | Science |
| 1540 | Earth Sciences | Science |
| 1541 | Life Sciences | Science |
| 1536 | Mathematics | Science |
| 1545 | Sports | — |
| 1547 | Football | Sports |
| 1548 | Basketball | Sports |
| 1546 | Soccer | Sports |
| 1550 | Hockey | Sports |
| 1560 | Fantasy Sports | Sports |

## Key Integrations

- CloudKit (iCloud sync)
- CarPlay (media player)
- AVFoundation (audio/video)
- OPML import/export
- Podlove Standard Chapters
