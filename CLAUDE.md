# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Instacast+ is a professional podcast management and playback application for iOS and macOS, written in Objective-C. It supports feed parsing, episode management, audio/video playback, chapters, bookmarks, and rich metadata handling.

**Current Version:** 2.9 (Config/Version.xcconfig)
**Minimum iOS:** 13.0

## Build Commands

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

## Key Integrations

- CloudKit (iCloud sync)
- CarPlay (media player)
- AVFoundation (audio/video)
- OPML import/export
- Podlove Standard Chapters
