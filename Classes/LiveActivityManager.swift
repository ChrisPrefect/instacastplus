import Foundation
import ActivityKit

/// Manages the Now Playing Live Activity lifecycle.
/// Called from Objective-C code (PlaybackManager, WidgetDataExporter).
@available(iOS 16.2, *)
@objc public final class LiveActivityManager: NSObject, @unchecked Sendable {

    @objc public static let shared = LiveActivityManager()

    private var currentActivity: Activity<NowPlayingAttributes>?

    private override init() {
        super.init()
    }

    // MARK: - Public API (called from ObjC)

    /// Start a new live activity for the given episode.
    /// Call when playback starts.
    @objc public func startActivity(
        episodeTitle: String,
        feedTitle: String,
        episodeImagePath: String?,
        duration: Int32,
        skipForwardSeconds: Int,
        skipBackwardSeconds: Int,
        position: Int32,
        isPaused: Bool,
        playbackSpeed: String,
        chapterTitle: String?,
        chapterArtPath: String?,
        chapterIndex: Int,
        chapterListData: NSArray?,   // [{title, startTime, absoluteIndex}] from ObjC
        hasSleepTimer: Bool,
        sleepTimerStopDate: Date?
    ) {
        // Check if live activities are enabled in settings
        guard UserDefaults.standard.bool(forKey: "LiveActivityEnabled") else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // End existing activity first
        endActivity()

        let attributes = NowPlayingAttributes(
            episodeTitle: episodeTitle,
            feedTitle: feedTitle,
            episodeImagePath: episodeImagePath,
            duration: duration,
            skipForwardSeconds: skipForwardSeconds,
            skipBackwardSeconds: skipBackwardSeconds
        )

        let wlaChapters = Self.parseChapterList(chapterListData)

        let state = NowPlayingAttributes.ContentState(
            position: position,
            isPaused: isPaused,
            playbackSpeed: playbackSpeed,
            chapterTitle: chapterTitle,
            chapterArtPath: chapterArtPath,
            chapterIndex: chapterIndex >= 0 ? chapterIndex : nil,
            chapterList: wlaChapters.isEmpty ? nil : wlaChapters,
            hasSleepTimer: hasSleepTimer,
            sleepTimerStopDate: sleepTimerStopDate,
            duration: duration
        )

        let content = ActivityContent(state: state, staleDate: nil)

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            NSLog("LiveActivityManager: failed to start activity: %@", error.localizedDescription)
        }
    }

    /// Update the live activity with new state.
    /// Call on position changes, play/pause, chapter changes, etc.
    @objc public func updateActivity(
        position: Int32,
        duration: Int32,
        isPaused: Bool,
        playbackSpeed: String,
        chapterTitle: String?,
        chapterArtPath: String?,
        chapterIndex: Int,
        chapterListData: NSArray?,   // [{title, startTime, absoluteIndex}] from ObjC
        hasSleepTimer: Bool,
        sleepTimerStopDate: Date?
    ) {
        guard let activity = currentActivity else { return }

        let wlaChapters = Self.parseChapterList(chapterListData)

        let state = NowPlayingAttributes.ContentState(
            position: position,
            isPaused: isPaused,
            playbackSpeed: playbackSpeed,
            chapterTitle: chapterTitle,
            chapterArtPath: chapterArtPath,
            chapterIndex: chapterIndex >= 0 ? chapterIndex : nil,
            chapterList: wlaChapters.isEmpty ? nil : wlaChapters,
            hasSleepTimer: hasSleepTimer,
            sleepTimerStopDate: sleepTimerStopDate,
            duration: duration
        )

        let content = ActivityContent(state: state, staleDate: nil)

        Task {
            await activity.update(content)
        }
    }

    /// End the live activity.
    /// Call when playback stops or episode finishes.
    @objc public func endActivity() {
        guard let activity = currentActivity else { return }

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        currentActivity = nil
    }

    /// Check if a live activity is currently running.
    @objc public var isActivityRunning: Bool {
        currentActivity != nil
    }

    // MARK: - Private Helpers

    /// Converts an NSArray of NSDictionary (from ObjC) into [WLAChapter].
    private static func parseChapterList(_ data: NSArray?) -> [WLAChapter] {
        guard let arr = data as? [NSDictionary] else { return [] }
        return arr.compactMap { dict in
            guard let title = dict["title"] as? String,
                  let startTime = (dict["startTime"] as? NSNumber)?.intValue,
                  let absoluteIndex = (dict["absoluteIndex"] as? NSNumber)?.intValue
            else { return nil }
            return WLAChapter(title: title, startTime: startTime, absoluteIndex: absoluteIndex)
        }
    }
}

// MARK: - Fallback for iOS < 16.2

/// No-op manager for older iOS versions.
/// This class is never instantiated on iOS 16.2+.
@objc public final class LiveActivityManagerCompat: NSObject {

    @objc public static func startActivityIfAvailable(
        episodeTitle: String,
        feedTitle: String,
        episodeImagePath: String?,
        duration: Int32,
        skipForwardSeconds: Int,
        skipBackwardSeconds: Int,
        position: Int32,
        isPaused: Bool,
        playbackSpeed: String,
        chapterTitle: String?,
        chapterArtPath: String?,
        chapterIndex: Int,
        chapterListData: NSArray?,
        hasSleepTimer: Bool,
        sleepTimerStopDate: Date?
    ) {
        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.startActivity(
                episodeTitle: episodeTitle,
                feedTitle: feedTitle,
                episodeImagePath: episodeImagePath,
                duration: duration,
                skipForwardSeconds: skipForwardSeconds,
                skipBackwardSeconds: skipBackwardSeconds,
                position: position,
                isPaused: isPaused,
                playbackSpeed: playbackSpeed,
                chapterTitle: chapterTitle,
                chapterArtPath: chapterArtPath,
                chapterIndex: chapterIndex,
                chapterListData: chapterListData,
                hasSleepTimer: hasSleepTimer,
                sleepTimerStopDate: sleepTimerStopDate
            )
        }
    }

    @objc public static func updateActivityIfAvailable(
        position: Int32,
        duration: Int32,
        isPaused: Bool,
        playbackSpeed: String,
        chapterTitle: String?,
        chapterArtPath: String?,
        chapterIndex: Int,
        chapterListData: NSArray?,
        hasSleepTimer: Bool,
        sleepTimerStopDate: Date?
    ) {
        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.updateActivity(
                position: position,
                duration: duration,
                isPaused: isPaused,
                playbackSpeed: playbackSpeed,
                chapterTitle: chapterTitle,
                chapterArtPath: chapterArtPath,
                chapterIndex: chapterIndex,
                chapterListData: chapterListData,
                hasSleepTimer: hasSleepTimer,
                sleepTimerStopDate: sleepTimerStopDate
            )
        }
    }

    @objc public static func endActivityIfAvailable() {
        if #available(iOS 16.2, *) {
            LiveActivityManager.shared.endActivity()
        }
    }
}
