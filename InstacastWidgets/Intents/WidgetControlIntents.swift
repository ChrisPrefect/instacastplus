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

// MARK: - Playback Control Intents

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    static let description = IntentDescription("Toggle playback.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "playpause")
        DarwinNotificationHelper.post("playpause")
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "skipforward")
        DarwinNotificationHelper.post("skipforward")
        return .result()
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Backward"
    static let description = IntentDescription("Skip backward.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "skipbackward")
        DarwinNotificationHelper.post("skipbackward")
        return .result()
    }
}

struct NextChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Go to next chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "nextchapter")
        DarwinNotificationHelper.post("nextchapter")
        return .result()
    }
}

struct PrevChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription("Go to previous chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "prevchapter")
        DarwinNotificationHelper.post("prevchapter")
        return .result()
    }
}

struct NextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Episode"
    static let description = IntentDescription("Play next episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "nextepisode")
        DarwinNotificationHelper.post("nextepisode")
        return .result()
    }
}

struct PrevEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Episode"
    static let description = IntentDescription("Play previous episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "previousepisode")
        DarwinNotificationHelper.post("previousepisode")
        return .result()
    }
}

struct CycleSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Cycle Speed"
    static let description = IntentDescription("Cycle through playback speeds.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "cyclespeed")
        DarwinNotificationHelper.post("cyclespeed")
        return .result()
    }
}

struct ToggleSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Sleep Timer"
    static let description = IntentDescription("Start or cancel sleep timer.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "togglesleeptimer")
        DarwinNotificationHelper.post("togglesleeptimer")
        return .result()
    }
}

struct SkipToChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip to Chapter"
    static let description = IntentDescription("Jump directly to a specific chapter.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Chapter Index")
    var chapterIndex: Int

    init() {}
    @Parameter(title: "Chapter Timeline")
    var chapterTimelineIdentifier: String?

    init(chapterIndex: Int, chapterTimelineIdentifier: String) {
        self.chapterIndex = chapterIndex
        self.chapterTimelineIdentifier = chapterTimelineIdentifier
    }

    func perform() async throws -> some IntentResult {
        try PendingWidgetActionStore.enqueue(action: "skipchapter", chapterIndex: chapterIndex,
                                        chapterTimelineIdentifier: chapterTimelineIdentifier)

        DarwinNotificationHelper.post("skipchapter")
        return .result()
    }
}
