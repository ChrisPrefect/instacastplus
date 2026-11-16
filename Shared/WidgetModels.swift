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
    var chapterTimelineIdentifier: String? = nil
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
    // Time anchor: exact position at `positionTimestamp` (seconds since 1970) and the rate media
    // time advanced at (0 while paused or stalled). Missing in snapshots of older app versions.
    var positionSeconds: Double? = nil
    var positionTimestamp: Double? = nil
    var playbackRate: Double? = nil

    /// The app exports at least every 10 s while it plays. An older anchor means the app no longer
    /// runs (terminated during playback): the position is then not projected any further.
    static let maximumAnchorAge: TimeInterval = 120

    private var anchorDate: Date? {
        positionTimestamp.map { Date(timeIntervalSince1970: $0) }
    }

    /// Rate the position advances at, at `date`; 0 when nothing can be projected.
    func liveRate(at date: Date) -> Double {
        guard !isPaused, let rate = playbackRate, rate > 0, positionSeconds != nil,
              let anchor = anchorDate, date.timeIntervalSince(anchor) < Self.maximumAnchorAge,
              let episode, episode.duration > 0 else { return 0 }
        return rate
    }

    /// Media position at `date`, projected from the time anchor while playback runs.
    func projectedPosition(at date: Date) -> Double? {
        guard let episode, let position = positionSeconds, let anchor = anchorDate else { return nil }
        let elapsed = max(0, date.timeIntervalSince(anchor))
        var projected = position + liveRate(at: date) * elapsed
        if episode.duration > 0 {
            projected = min(projected, Double(episode.duration))
        }
        return max(0, projected)
    }

    /// Wall-clock interval over which a `ProgressView(timerInterval:)` fills exactly like the
    /// episode progresses at the current rate; nil while paused (static bar).
    func liveProgressInterval(at date: Date) -> ClosedRange<Date>? {
        let rate = liveRate(at: date)
        guard rate > 0, let episode, let position = positionSeconds, let anchor = anchorDate else { return nil }
        let start = anchor.addingTimeInterval(-position / rate)
        let end = start.addingTimeInterval(Double(episode.duration) / rate)
        guard start < end, end > date else { return nil }
        return start...end
    }

    /// When the minute-resolution texts (elapsed, remaining) or the current chapter next change
    /// while playback runs; nil while nothing moves.
    func nextDisplayChange(after date: Date) -> Date? {
        let rate = liveRate(at: date)
        guard rate > 0, let episode, let position = projectedPosition(at: date) else { return nil }
        let remaining = Double(episode.duration) - position
        guard remaining > 0 else { return nil }
        var mediaSeconds = [60 - position.truncatingRemainder(dividingBy: 60)]
        let remainingToFlip = remaining.truncatingRemainder(dividingBy: 60)
        mediaSeconds.append(remainingToFlip > 0 ? remainingToFlip : 60)
        if let nextChapter = chapters?.first(where: { $0.startTime > position + 0.5 }) {
            mediaSeconds.append(nextChapter.startTime - position)
        }
        let wallSeconds = (mediaSeconds.min() ?? 60) / rate
        // A little past the boundary so the projection lands on the new value.
        return date.addingTimeInterval(max(1, wallSeconds + 0.5))
    }

    /// Copy whose episode position is the projected position at `date` (static texts, chapter).
    func projected(at date: Date) -> WNowPlaying {
        guard let episode, let position = projectedPosition(at: date) else { return self }
        return withEpisode(episode.withPosition(Int32(position.rounded(.down))))
    }

    var hasSleepTimer: Bool {
        if isPaused {
            return (sleepTimerRemaining ?? 0) > 0
        }
        if let stopDate = sleepTimerStopDate {
            return stopDate.timeIntervalSinceNow > 0
        }
        return false
    }

    var sleepTimerFormatted: String? {
        let interval = isPaused ? sleepTimerRemaining : sleepTimerStopDate?.timeIntervalSinceNow
        guard let interval else { return nil }
        let remaining = max(0, Int(ceil(interval)))
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
                    chapterTimelineIdentifier: chapterTimelineIdentifier,
                    chapterCount: chapterCount, chapterArtPath: chapterArtPath, chapters: chapters,
                    isPaused: isPaused, sleepTimerRemaining: sleepTimerRemaining,
                    sleepTimerStopDate: sleepTimerStopDate, skipForwardSeconds: skipForwardSeconds,
                    skipBackwardSeconds: skipBackwardSeconds, playbackSpeed: playbackSpeed,
                    hasPreviousEpisode: hasPreviousEpisode,
                    hasNextEpisode: hasNextEpisode,
                    timestamp: timestamp,
                    positionSeconds: positionSeconds,
                    positionTimestamp: positionTimestamp,
                    playbackRate: playbackRate)
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
