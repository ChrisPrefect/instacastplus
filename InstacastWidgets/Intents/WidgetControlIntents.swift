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

// MARK: - Playback Control Intents

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    static let description = IntentDescription("Toggle playback.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("playpause")
        return .result()
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("skipforward")
        return .result()
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Backward"
    static let description = IntentDescription("Skip backward.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("skipbackward")
        return .result()
    }
}

struct NextChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Go to next chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("nextchapter")
        return .result()
    }
}

struct PrevChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription("Go to previous chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("prevchapter")
        return .result()
    }
}

struct NextEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Episode"
    static let description = IntentDescription("Play next episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("nextepisode")
        return .result()
    }
}

struct PrevEpisodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Episode"
    static let description = IntentDescription("Play previous episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("previousepisode")
        return .result()
    }
}

struct CycleSpeedIntent: AppIntent {
    static let title: LocalizedStringResource = "Cycle Speed"
    static let description = IntentDescription("Cycle through playback speeds.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("cyclespeed")
        return .result()
    }
}

struct ToggleSleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Sleep Timer"
    static let description = IntentDescription("Start or cancel sleep timer.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        DarwinNotificationHelper.post("togglesleeptimer")
        return .result()
    }
}

struct SkipToChapterIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip to Chapter"
    static let description = IntentDescription("Jump directly to a specific chapter.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Chapter Index")
    var chapterIndex: Int

    init() {}
    init(chapterIndex: Int) { self.chapterIndex = chapterIndex }

    func perform() async throws -> some IntentResult {
        // Write the target chapter index to the shared container so the main app can read it
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
