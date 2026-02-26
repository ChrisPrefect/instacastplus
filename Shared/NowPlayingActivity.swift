import ActivityKit
import Foundation

// MARK: - Chapter DTO for Live Activity

/// A single chapter entry passed in the Live Activity ContentState.
/// Only non-past chapters are included (current + future).
struct WLAChapter: Codable, Hashable, Sendable {
    let title: String
    let startTime: Int       // seconds from episode start
    let absoluteIndex: Int   // index in pm.chapters — used by SkipToChapterIntent
}

// MARK: - Live Activity Attributes

/// ActivityAttributes for the Now Playing live activity.
/// Static context = what doesn't change during playback of an episode.
/// Dynamic content = what changes in real-time (position, pause state, speed, etc.)
struct NowPlayingAttributes: ActivityAttributes {
    // Static context (set once when activity starts)
    let episodeTitle: String
    let feedTitle: String
    let episodeImagePath: String?  // relative path in WidgetImages/
    let duration: Int32            // total seconds
    let skipForwardSeconds: Int    // from feed settings (default 30)
    let skipBackwardSeconds: Int   // from feed settings (default 30)

    // Dynamic content (updated via push or content state)
    struct ContentState: Codable, Hashable {
        let position: Int32
        let isPaused: Bool
        let playbackSpeed: String       // e.g. "1x", "1.5x"
        let chapterTitle: String?
        let chapterArtPath: String?     // relative path in WidgetImages/ (nil = use episode art)
        let chapterIndex: Int?          // absolute index of current chapter in pm.chapters
        let chapterList: [WLAChapter]?  // current + future (non-past) chapters for lock screen

        let hasSleepTimer: Bool
        let sleepTimerStopDate: Date?

        var progress: Double {
            guard duration > 0 else { return 0 }
            return min(1.0, max(0.0, Double(position) / Double(duration)))
        }

        // Duration is needed for progress calculation but stored in attributes
        // We pass it through a computed property pattern
        private let duration: Int32

        init(position: Int32, isPaused: Bool, playbackSpeed: String,
             chapterTitle: String?, chapterArtPath: String?,
             chapterIndex: Int?, chapterList: [WLAChapter]?,
             hasSleepTimer: Bool, sleepTimerStopDate: Date?, duration: Int32) {
            self.position = position
            self.isPaused = isPaused
            self.playbackSpeed = playbackSpeed
            self.chapterTitle = chapterTitle
            self.chapterArtPath = chapterArtPath
            self.chapterIndex = chapterIndex
            self.chapterList = chapterList
            self.hasSleepTimer = hasSleepTimer
            self.sleepTimerStopDate = sleepTimerStopDate
            self.duration = duration
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

        var formattedTimeLeft: String {
            let left = max(0, Int(duration) - Int(position))
            let hours = left / 3600
            let minutes = (left % 3600) / 60
            if hours > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(minutes) min"
        }
    }
}
