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

## Key Integrations

- CloudKit (iCloud sync)
- CarPlay (media player)
- AVFoundation (audio/video)
- OPML import/export
- Podlove Standard Chapters
