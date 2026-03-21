import Foundation

// MARK: - Episode DTO

struct WEpisode: Codable, Identifiable, Hashable, Sendable {
    let id: String              // objectHash
    let title: String
    let feedTitle: String
    let feedImageURL: String?   // remote URL (fallback)
    let localImagePath: String? // relative path in WidgetImages/
    let duration: Int32         // seconds
    let position: Int32         // seconds
    let consumed: Bool
    let starred: Bool
    let downloaded: Bool
    let pubDate: Date?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1.0, max(0.0, Double(position) / Double(duration)))
    }

    var formattedDuration: String {
        return WEpisode.formatTime(max(0, Int(duration)))
    }

    var formattedTimeLeft: String {
        let left = max(0, Int(duration) - Int(position))
        return WEpisode.formatTime(left)
    }

    /// Create a copy with a different position (used for projected timeline entries)
    func withPosition(_ newPosition: Int32) -> WEpisode {
        WEpisode(id: id, title: title, feedTitle: feedTitle, feedImageURL: feedImageURL,
                 localImagePath: localImagePath, duration: duration, position: newPosition,
                 consumed: consumed, starred: starred, downloaded: downloaded, pubDate: pubDate)
    }

    static func formatTime(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }
}

// MARK: - List DTO

struct WList: Codable, Identifiable, Hashable, Sendable {
    let id: String              // uid
    let name: String
    let type: String?           // "smart:unplayed", "smart:starred", "episode_list" etc.
    let episodeCount: Int
}

// MARK: - Chapter DTO

struct WChapter: Codable, Sendable {
    let title: String
    let startTime: TimeInterval
    let duration: TimeInterval
}

// MARK: - Now Playing Snapshot

struct WNowPlaying: Codable, Sendable {
    let episode: WEpisode?
    let chapterTitle: String?
    let chapterIndex: Int?
    let chapterCount: Int?
    let chapterArtPath: String?         // local path for chapter artwork in WidgetImages/
    let chapters: [WChapter]?           // chapter list for large widget
    let isPaused: Bool
    let sleepTimerRemaining: TimeInterval?  // nil = off
    let sleepTimerStopDate: Date?
    let skipForwardSeconds: Int?        // from feed settings (default 30)
    let skipBackwardSeconds: Int?       // from feed settings (default 30)
    let playbackSpeed: String?          // e.g. "1x", "1.5x", "2x"
    let hasPreviousEpisode: Bool?       // true if queue has a previous episode
    let hasNextEpisode: Bool?           // true if queue has a next episode
    let timestamp: Date

    var hasSleepTimer: Bool {
        if let stopDate = sleepTimerStopDate {
            return stopDate.timeIntervalSinceNow > 0
        }
        return false
    }

    var sleepTimerFormatted: String? {
        guard let stopDate = sleepTimerStopDate else { return nil }
        let remaining = max(0, Int(stopDate.timeIntervalSinceNow))
        let minutes = remaining / 60
        let seconds = remaining % 60
        if minutes > 0 {
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
        return "0:\(String(format: "%02d", seconds))"
    }

    /// Create a copy with a different episode (used for projected timeline entries)
    func withEpisode(_ newEpisode: WEpisode) -> WNowPlaying {
        WNowPlaying(episode: newEpisode, chapterTitle: chapterTitle, chapterIndex: chapterIndex,
                    chapterCount: chapterCount, chapterArtPath: chapterArtPath, chapters: chapters,
                    isPaused: isPaused, sleepTimerRemaining: sleepTimerRemaining,
                    sleepTimerStopDate: sleepTimerStopDate, skipForwardSeconds: skipForwardSeconds,
                    skipBackwardSeconds: skipBackwardSeconds, playbackSpeed: playbackSpeed,
                    hasPreviousEpisode: hasPreviousEpisode,
                    hasNextEpisode: hasNextEpisode,
                    timestamp: timestamp)
    }
}

// MARK: - List Episodes Snapshot

struct WListEpisodes: Codable, Sendable {
    let listId: String
    let listName: String
    let episodes: [WEpisode]
    let timestamp: Date
}

// MARK: - Settings Snapshot

struct WSettings: Codable, Sendable {
    let accentColorHex: String  // e.g. "#FF5300"
}

// MARK: - Stats Snapshot

struct WStats: Codable, Sendable {
    let listenedTodaySec: TimeInterval
    let listenedWeekSec: TimeInterval
    let downloadedCount: Int
    let downloadedSizeBytes: Int64       // total size of downloaded episodes in bytes
    let subscribedCount: Int
    let unplayedCount: Int
    let newEpisodesTodayCount: Int       // episodes published since start of today
    let sleepTimerUsedCount: Int         // number of sleep-timer sessions ever used
    let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case listenedTodaySec
        case listenedWeekSec
        case downloadedCount
        case downloadedSizeBytes
        case subscribedCount
        case unplayedCount
        case newEpisodesTodayCount
        case sleepTimerUsedCount
        case timestamp
    }

    init(
        listenedTodaySec: TimeInterval,
        listenedWeekSec: TimeInterval,
        downloadedCount: Int,
        downloadedSizeBytes: Int64,
        subscribedCount: Int,
        unplayedCount: Int,
        newEpisodesTodayCount: Int,
        sleepTimerUsedCount: Int,
        timestamp: Date
    ) {
        self.listenedTodaySec = listenedTodaySec
        self.listenedWeekSec = listenedWeekSec
        self.downloadedCount = downloadedCount
        self.downloadedSizeBytes = downloadedSizeBytes
        self.subscribedCount = subscribedCount
        self.unplayedCount = unplayedCount
        self.newEpisodesTodayCount = newEpisodesTodayCount
        self.sleepTimerUsedCount = sleepTimerUsedCount
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listenedTodaySec = try container.decode(TimeInterval.self, forKey: .listenedTodaySec)
        listenedWeekSec = try container.decode(TimeInterval.self, forKey: .listenedWeekSec)
        downloadedCount = try container.decode(Int.self, forKey: .downloadedCount)
        downloadedSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .downloadedSizeBytes) ?? 0
        subscribedCount = try container.decode(Int.self, forKey: .subscribedCount)
        unplayedCount = try container.decode(Int.self, forKey: .unplayedCount)
        newEpisodesTodayCount = try container.decodeIfPresent(Int.self, forKey: .newEpisodesTodayCount) ?? 0
        sleepTimerUsedCount = try container.decodeIfPresent(Int.self, forKey: .sleepTimerUsedCount) ?? 0
        timestamp = try container.decode(Date.self, forKey: .timestamp)
    }

    var listenedTodayFormatted: String {
        formatListeningTime(listenedTodaySec)
    }

    var listenedWeekFormatted: String {
        formatListeningTime(listenedWeekSec)
    }

    var downloadedSizeFormatted: String {
        let bytes = downloadedSizeBytes
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576)
        } else {
            return "\(bytes / 1024) KB"
        }
    }

    private func formatListeningTime(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }
}
