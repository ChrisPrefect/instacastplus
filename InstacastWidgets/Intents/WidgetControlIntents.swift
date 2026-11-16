import Foundation
import AppIntents

// MARK: - Darwin Notification Helper

/// Posts Darwin notifications to the main app for playback control.
/// Darwin notifications are system-wide and reach the main app even in background
/// (as long as the app has an active audio session).
enum DarwinNotificationHelper {
    static let prefix = "com.iteconomy.instacastplus.widget."

    static func post(_ action: String) {
        let name = (prefix + action) as CFString
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name), nil, nil, true)
    }
}

// MARK: - Pending Action Queue

/// Each tap owns an immutable file so rapid taps survive delayed Darwin delivery.
enum PendingWidgetActionStore {
    private static let directoryName = "widget_pending_actions"

    static func enqueue(action: String, chapterIndex: Int? = nil, chapterTimelineIdentifier: String? = nil) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let timestamp = Date().timeIntervalSince1970
        var payload: [String: Any] = [
            "action": action,
            "timestamp": timestamp
        ]
        if let chapterIndex {
            payload["chapterIndex"] = chapterIndex
        }
        if let chapterTimelineIdentifier {
            payload["chapterTimelineIdentifier"] = chapterTimelineIdentifier
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        let filename = String(format: "%020.0f", timestamp * 1_000_000) + "-" + UUID().uuidString + ".json"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}

// MARK: - Widget-process fallback

/// Widget-extension side of the Now Playing widget buttons (the intents themselves live in
/// Shared/WidgetPlaybackIntents.swift). They are AudioPlaybackIntents that are also compiled
/// into the app, so the system normally runs them in the app process, launching the app in
/// the background when needed; the app's counterpart calls WidgetDataExporter directly.
/// This path only runs if the system executes an intent in the widget process: it queues the
/// tap for a running app and wakes it via Darwin notification.
enum WidgetControlActionPerformer {
    // The system performs the AudioPlaybackIntents in the app; the episode and start time of a
    // chapter row are only used there.
    static func perform(_ action: String, chapterIndex: Int? = nil, chapterTimelineIdentifier: String? = nil,
                        episodeID: String? = nil, chapterStartTime: Double? = nil) async throws {
        try PendingWidgetActionStore.enqueue(action: action, chapterIndex: chapterIndex,
                                             chapterTimelineIdentifier: chapterTimelineIdentifier)
        DarwinNotificationHelper.post(action)
    }
}
