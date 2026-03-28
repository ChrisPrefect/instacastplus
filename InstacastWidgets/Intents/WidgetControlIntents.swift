import Foundation
@preconcurrency import AppIntents

// MARK: - Darwin Notification Helper

/// Posts Darwin notifications to the main app for playback control.
/// Darwin notifications are system-wide and reach the main app even in background
/// (as long as the app has an active audio session).
@available(iOS 17.0, *)
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

/// Persists a pending widget action in the shared container so the main app can
/// consume it after launch/foreground transition when Darwin delivery is missed.
@available(iOS 17.0, *)
enum PendingWidgetActionStore {
    private static let filename = "widget_pending_action.json"

    static func enqueue(action: String, chapterIndex: Int? = nil) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID
        ) else {
            return
        }

        var payload: [String: Any] = [
            "action": action,
            "timestamp": Date().timeIntervalSince1970
        ]
        if let chapterIndex {
            payload["chapterIndex"] = chapterIndex
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        let fileURL = container.appendingPathComponent(filename)
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Widget Diagnostic Log

/// Writes diagnostic info to the shared container so the main app can read and log it.
/// This gives visibility into the widget extension process (which has its own separate console).
@available(iOS 17.0, *)
enum WidgetDiagnostics {
    private static let filename = "widget_diagnostics.json"

    static func log(_ event: String, details: [String: Any] = [:]) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID
        ) else { return }

        var entry = details
        entry["event"] = event
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        entry["pid"] = ProcessInfo.processInfo.processIdentifier

        // Read existing log, append, keep last 20 entries
        let fileURL = container.appendingPathComponent(filename)
        var entries: [[String: Any]] = []
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            entries = existing
        }
        entries.append(entry)
        if entries.count > 20 { entries = Array(entries.suffix(20)) }

        if let data = try? JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Optimistic JSON Update

/// Reads the now-playing JSON from the shared container, applies a mutation, and writes it back.
/// This gives the widget immediate visual feedback because WidgetKit automatically calls
/// getTimeline after an AppIntent returns — and getTimeline reads the updated JSON.
/// The main app then catches up asynchronously via Darwin notification.
@available(iOS 17.0, *)
enum OptimisticNowPlayingUpdate {
    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID)
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Toggle isPaused in the JSON. Returns the new isPaused value, or nil if the update failed.
    @discardableResult
    static func togglePaused() -> Bool? {
        guard let container = containerURL else { return nil }
        let fileURL = container.appendingPathComponent(ICWidgetConstants.nowPlayingFile)
        guard let data = try? Data(contentsOf: fileURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["episode"] != nil else {
            return nil
        }

        let wasPaused = json["isPaused"] as? Bool ?? true
        json["isPaused"] = !wasPaused
        json["timestamp"] = isoFormatter.string(from: Date())

        if let updated = try? JSONSerialization.data(withJSONObject: json) {
            try? updated.write(to: fileURL, options: .atomic)
        }
        return !wasPaused
    }

    /// Update the playback speed string in the JSON.
    static func cycleSpeed() {
        guard let container = containerURL else { return }
        let fileURL = container.appendingPathComponent(ICWidgetConstants.nowPlayingFile)
        guard let data = try? Data(contentsOf: fileURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let currentSpeed = json["playbackSpeed"] as? String ?? "1x"
        let speeds = ["0.5x", "0.75x", "1x", "1.25x", "1.5x", "1.75x", "2x", "2.5x", "3x"]
        let currentIdx = speeds.firstIndex(of: currentSpeed) ?? 2
        let nextIdx = (currentIdx + 1) % speeds.count
        json["playbackSpeed"] = speeds[nextIdx]
        json["timestamp"] = isoFormatter.string(from: Date())

        if let updated = try? JSONSerialization.data(withJSONObject: json) {
            try? updated.write(to: fileURL, options: .atomic)
        }
    }

    /// Toggle sleep timer in the JSON.
    static func toggleSleepTimer() {
        guard let container = containerURL else { return }
        let fileURL = container.appendingPathComponent(ICWidgetConstants.nowPlayingFile)
        guard let data = try? Data(contentsOf: fileURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if json["sleepTimerStopDate"] != nil {
            json.removeValue(forKey: "sleepTimerRemaining")
            json.removeValue(forKey: "sleepTimerStopDate")
        } else {
            let stopDate = Date().addingTimeInterval(15 * 60)
            json["sleepTimerRemaining"] = 15 * 60
            json["sleepTimerStopDate"] = isoFormatter.string(from: stopDate)
        }
        json["timestamp"] = isoFormatter.string(from: Date())

        if let updated = try? JSONSerialization.data(withJSONObject: json) {
            try? updated.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Playback Control Intents
//
// AppIntent runs in the widget extension process.
// WidgetKit GUARANTEES getTimeline is called after perform() returns → immediate visual update.
//
// openAppWhenRun = true ensures the app is ALWAYS launched/foregrounded after the intent.
// This guarantees the pending action is consumed — no silent failures.
// When the app is already alive in background, the Darwin notification arrives first
// (before the app comes to foreground), so the action is processed immediately.
// The pending action file is cleared by the Darwin handler, preventing double execution.
// When the app is not alive, it launches and _consumePendingWidgetActionIfNeeded fires.

@available(iOS 17.0, *)
struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    static let description = IntentDescription("Toggle playback.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("PlayPauseIntent.perform()")
        OptimisticNowPlayingUpdate.togglePaused()
        PendingWidgetActionStore.enqueue(action: "playpause")
        DarwinNotificationHelper.post("playpause")
        return .result()
    }
}

@available(iOS 17.0, *)
struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("SkipForwardIntent.perform()")
        PendingWidgetActionStore.enqueue(action: "skipforward")
        DarwinNotificationHelper.post("skipforward")
        return .result()
    }
}

@available(iOS 17.0, *)
struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Backward"
    static let description = IntentDescription("Skip backward.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("SkipBackwardIntent.perform()")
        PendingWidgetActionStore.enqueue(action: "skipbackward")
        DarwinNotificationHelper.post("skipbackward")
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Go to next chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("NextChapterIntent.perform()")
        PendingWidgetActionStore.enqueue(action: "nextchapter")
        DarwinNotificationHelper.post("nextchapter")
        return .result()
    }
}

@available(iOS 17.0, *)
struct PrevChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription("Go to previous chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("PrevChapterIntent.perform()")
        PendingWidgetActionStore.enqueue(action: "prevchapter")
        DarwinNotificationHelper.post("prevchapter")
        return .result()
    }
}

@available(iOS 17.0, *)
struct NextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Episode"
    static let description = IntentDescription("Play next episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("NextEpisodeIntent.perform()")
        PendingWidgetActionStore.enqueue(action: "nextepisode")
        DarwinNotificationHelper.post("nextepisode")
        return .result()
    }
}

@available(iOS 17.0, *)
struct PrevEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Episode"
    static let description = IntentDescription("Play previous episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("PrevEpisodeIntent.perform()")
        PendingWidgetActionStore.enqueue(action: "previousepisode")
        DarwinNotificationHelper.post("previousepisode")
        return .result()
    }
}

@available(iOS 17.0, *)
struct CycleSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Cycle Speed"
    static let description = IntentDescription("Cycle through playback speeds.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("CycleSpeedIntent.perform()")
        OptimisticNowPlayingUpdate.cycleSpeed()
        PendingWidgetActionStore.enqueue(action: "cyclespeed")
        DarwinNotificationHelper.post("cyclespeed")
        return .result()
    }
}

@available(iOS 17.0, *)
struct ToggleSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Sleep Timer"
    static let description = IntentDescription("Start or cancel sleep timer.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("ToggleSleepTimerIntent.perform()")
        OptimisticNowPlayingUpdate.toggleSleepTimer()
        PendingWidgetActionStore.enqueue(action: "togglesleeptimer")
        DarwinNotificationHelper.post("togglesleeptimer")
        return .result()
    }
}

@available(iOS 17.0, *)
struct SkipToChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip to Chapter"
    static let description = IntentDescription("Jump directly to a specific chapter.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Chapter Index")
    var chapterIndex: Int

    init() {}
    init(chapterIndex: Int) { self.chapterIndex = chapterIndex }

    func perform() async throws -> some IntentResult {
        WidgetDiagnostics.log("SkipToChapterIntent.perform()", details: ["chapterIndex": chapterIndex])
        PendingWidgetActionStore.enqueue(action: "skipchapter", chapterIndex: chapterIndex)

        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID
        ) {
            let data = "\(chapterIndex)".data(using: .utf8)
            let fileURL = container.appendingPathComponent("widget_skip_chapter.txt")
            try? data?.write(to: fileURL)
        }
        DarwinNotificationHelper.post("skipchapter")
        return .result()
    }
}
